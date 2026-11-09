#!/bin/bash
# package.sh: assemble the Apple Silicon install tree that package/install.sh consumes, from the build products:
#   Library/Extensions/NVRM.kext, NVAccelArm.kext        (arm64e; build_nvrm.sh, build_nvaccel_arm.sh)
#   Library/GPUBundles/NVMTLDriver.bundle                (universal plugin + universal translator next to it)
#   Library/GPUBundles/nvmtl/libvulkan_nouveau.dylib     (universal NVK: build_nvk.sh + build_nvk_x86_64.sh), nvk_icd.json
#   Library/GPUBundles/nvmtl-allow.txt, VERSION, licenses/
#   Users/Shared/nvfw/nvidia/<ver>/gsp_*.bin             (from out/package-src, see the firmware note below)
# Output: out/package-arm64/ with install.sh and uninstall.sh beside it. Nothing here is signed beyond ad-hoc.
set -uo pipefail
. "$(dirname "$0")/env.sh"
PKG="$REPO/out/package-arm64"; SRC="$REPO/out/package-src"
rm -rf "$PKG"; mkdir -p "$PKG/Library/Extensions" "$PKG/Library/GPUBundles/nvmtl" "$PKG/Users/Shared/nvfw"
need() { [ -e "$1" ] || { echo "STOP: missing $1 ($2)"; exit 2; }; }
need "$OUT/NVRM.kext/Contents/MacOS/NVRM" "build/arm64/build_nvrm.sh"
need "$OUT/NVAccelArm.kext/Contents/MacOS/NVAccelArm" "build/arm64/build_nvaccel_arm.sh"
need "$REPO/out/plugin/NVMTLDriver-arm64" "build/arm64/build_plugin.sh universal"
need "$REPO/out/plugin/NVMTLDriver-x86_64" "build/arm64/build_plugin.sh universal"
need "$REPO/out/translator/release/libnvmtl_translate.dylib" "translator build (arm64)"
need "$REPO/out/translator/x86_64-apple-darwin/release/libnvmtl_translate.dylib" "translator build (x86_64)"
need "$OUT/nvk/libvulkan_nouveau.dylib" "build/arm64/build_nvk.sh"
need "$REPO/out/x86_64/nvk/libvulkan_nouveau.dylib" "build/arm64/build_nvk_x86_64.sh"
# kexts
# kexts: signed with the "NullMoth Dev Signing" identity (unattended/setup-signing.sh) when it exists, so that
# kernelmanagerd's one-time approval (per team id + bundle id) covers every later build; ad-hoc otherwise
KC="$HOME/nvdev/sign/nvdev.keychain-db"; SIGN=(-s -)
# the keychain locks at every reboot; its password lives next to it (setup-signing.sh), so no dialog ever appears
# (item 28: the identity did NOT make kernelmanagerd skip the approval - it is per binary for non-Apple signatures -
# so it is used only when the keychain opens without a dialog; otherwise ad-hoc, which never prompts)
if [ -f "$KC" ] && [ -f "$HOME/nvdev/sign/pw" ] && security unlock-keychain -p "$(cat "$HOME/nvdev/sign/pw")" "$KC" 2>/dev/null \
   && security find-identity -v -p codesigning "$KC" 2>/dev/null | grep -q "NullMoth Dev Signing"; then
  SIGN=(-s "NullMoth Dev Signing" --keychain "$KC"); fi
for k in NVRM NVAccelArm; do ditto "$OUT/$k.kext" "$PKG/Library/Extensions/$k.kext" || exit 1; codesign -f "${SIGN[@]}" "$PKG/Library/Extensions/$k.kext" 2>/dev/null || codesign -f -s - "$PKG/Library/Extensions/$k.kext" 2>/dev/null; done
echo "kexts signed: $(codesign -dvv "$PKG/Library/Extensions/NVRM.kext" 2>&1 | grep -E '^(TeamIdentifier|Signature)=' | tr '\n' ' ')"
# the Metal plugin bundle: universal executable, universal translator beside it (the plugin looks there first)
B="$PKG/Library/GPUBundles/NVMTLDriver.bundle/Contents"; mkdir -p "$B/MacOS"
lipo -create "$REPO/out/plugin/NVMTLDriver-arm64" "$REPO/out/plugin/NVMTLDriver-x86_64" -output "$B/MacOS/NVMTLDriver" || exit 1
lipo -create "$REPO/out/translator/release/libnvmtl_translate.dylib" "$REPO/out/translator/x86_64-apple-darwin/release/libnvmtl_translate.dylib" \
     -output "$B/MacOS/libnvmtl_translate.dylib" || exit 1
install_name_tool -id @rpath/libnvmtl_translate.dylib "$B/MacOS/libnvmtl_translate.dylib"   # cargo leaves the build path as the install name
cp "$REPO/build/arm64/NVMTLDriver-Info.plist" "$B/Info.plist"
# nested code first, then the bundle: codesign refuses a bundle whose dylib is unsigned
codesign -f -s - "$B/MacOS/libnvmtl_translate.dylib" || exit 1
codesign -f -s - "$PKG/Library/GPUBundles/NVMTLDriver.bundle" || exit 1
codesign -v "$PKG/Library/GPUBundles/NVMTLDriver.bundle" || exit 1
# NVK (the plugin opens the ICD directly; the json is for a Vulkan loader, kept for tools)
lipo -create "$OUT/nvk/libvulkan_nouveau.dylib" "$REPO/out/x86_64/nvk/libvulkan_nouveau.dylib" -output "$PKG/Library/GPUBundles/nvmtl/libvulkan_nouveau.dylib" || exit 1
codesign -f -s - "$PKG/Library/GPUBundles/nvmtl/libvulkan_nouveau.dylib" 2>/dev/null
cat > "$PKG/Library/GPUBundles/nvmtl/nvk_icd.json" <<'J'
{ "file_format_version": "1.0.0", "ICD": { "library_path": "./libvulkan_nouveau.dylib", "api_version": "1.3.0" } }
J
# NVIDIAShared.bundle carries NVIDIA's x86_64 NVVM libraries for the vendor SASS lane; there is no arm64 build of them.
# The installer copies the bundle unconditionally, so ship a placeholder: the plugin falls back to the NVK/NAK lane.
mkdir -p "$PKG/Library/GPUBundles/NVIDIAShared.bundle/Contents"
printf 'Placeholder for the Apple Silicon package: NVIDIA'"'"'s NVVM compiler libraries are x86_64 only, so the vendor compiler\nlane is absent here and every shader goes through NVK/NAK. See docs/ARM64-PORT-NOTES.md.\n' > "$PKG/Library/GPUBundles/NVIDIAShared.bundle/Contents/README.txt"
# allow-list: every process may get the device (WindowServer is excluded by the headless rule in the plugin itself)
printf '# NVMTL allow-list: one process name per line; * = all, !name = only when armed, -name = never\n*\n' > "$PKG/Library/GPUBundles/nvmtl-allow.txt"
# firmware: NVIDIA's GSP firmware for the RM version NVRM.kext was built with (not in the repo; see docs/ARM64-PORT-NOTES.md)
if [ -d "$SRC/Users/Shared/nvfw" ]; then ditto "$SRC/Users/Shared/nvfw" "$PKG/Users/Shared/nvfw" || exit 1
else echo "NOTE: no firmware at $SRC/Users/Shared/nvfw -- the package will install without GSP firmware and NVRM will not start"; fi
# version, licenses, installer
printf '%s-arm64\n' "$NV_VERSION" > "$PKG/VERSION"
[ -d "$REPO/licenses" ] && ditto "$REPO/licenses" "$PKG/licenses"
# the driver's own licence (PolyForm Noncommercial, with its required notices) and NOTICE go with every copy, and the
# translator's LGPL-3.0 (with the GPL-3.0 text it refers to) with the binary it is built into
cp "$REPO/LICENSE" "$PKG/LICENSE" && cp "$REPO/NOTICE" "$PKG/NOTICE" || exit 1
cp "$REPO/translator/LICENSE" "$PKG/licenses/metal2vulkan-translator-LGPL-3.0.txt" && cp "$REPO/translator/COPYING" "$PKG/licenses/metal2vulkan-translator-GPL-3.0.txt" || exit 1
cp "$REPO/package/install.sh" "$REPO/package/uninstall.sh" "$REPO/package/nullmoth-runtime-check.sh" "$PKG/"
chmod +x "$PKG/nullmoth-runtime-check.sh"
# the user-facing README and the per-game launcher (usenv: the NVIDIA card as one app's default Metal device)
# (the repository's README.md + README.zh-CN.md, the same files)
cp "$REPO/README.md" "$PKG/README.md" && cp "$REPO/README.zh-CN.md" "$PKG/README.zh-CN.md" || exit 1
mkdir -p "$PKG/launch" && cp "$REPO/tools/arm64-probes/usenv.sh" "$REPO/out/usenv/libusenv.dylib" "$REPO/out/usenv/defaultdev" "$PKG/launch/" || exit 1
chmod +x "$PKG/launch/usenv.sh" "$PKG/launch/defaultdev"
# the installer checks every file against SHA256SUMS before it copies anything (paths relative to the package root)
(cd "$PKG" && find . -type f ! -name SHA256SUMS -exec shasum -a 256 '{}' \; | sed 's|  \./|  |' | sort -k2 > SHA256SUMS) || exit 1
(cd "$PKG" && shasum -a 256 --strict -c SHA256SUMS --quiet) || { echo "STOP: the manifest does not verify"; exit 1; }
echo "package: $PKG"; du -sh "$PKG" | awk '{print "  " $1}'; find "$PKG" -type f | sed "s|$PKG/|  |" | sort | head -40
