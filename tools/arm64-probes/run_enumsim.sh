#!/bin/bash
# run_enumsim.sh: build the arm64 plugin as a bundle, build the harness, and run Metal's device enumeration against it on
# this Mac (no NVIDIA GPU needed). Needs a debug plugin build (NVMTL_SIM_NO_GPU is ignored by release builds).
# ARCH=x86_64 runs the same test under Rosetta with the x86_64 plugin slice and translator (what an Intel-only app sees).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
ARCH=${ARCH:-arm64}
P="$REPO/out/plugin"; B="$P/NVMTLDriver.bundle"; T="$REPO/out/enumsim-$ARCH"; mkdir -p "$T"
[ -f "$P/NVMTLDriver-$ARCH" ] || bash "$REPO/build/arm64/build_plugin.sh" "$ARCH" || exit 1
mkdir -p "$B/Contents/MacOS"
cp "$P/NVMTLDriver-$ARCH" "$B/Contents/MacOS/NVMTLDriver"
# the plugin looks for the translator next to its own executable first; with it, newLibraryWithSource: runs end to end
case "$ARCH" in arm64) X="$REPO/out/translator/release/libnvmtl_translate.dylib";; *) X="$REPO/out/translator/x86_64-apple-darwin/release/libnvmtl_translate.dylib";; esac
[ -f "$X" ] && cp "$X" "$B/Contents/MacOS/libnvmtl_translate.dylib"
cat > "$B/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleExecutable</key><string>NVMTLDriver</string>
	<key>CFBundleIdentifier</key><string>com.nullmoth.NVMTLDriver</string>
	<key>CFBundlePackageType</key><string>BNDL</string>
	<key>CFBundleName</key><string>NVMTLDriver</string>
	<key>CFBundleVersion</key><string>0.1</string>
	<key>NSPrincipalClass</key><string>NVMTLDevice</string>
</dict></plist>
PL
codesign -f -s - "$B" 2>/dev/null
xcrun clang -arch "$ARCH" -dynamiclib -framework IOKit -framework CoreFoundation "$HERE/enumsim_interpose.c" -o "$T/libenumsim.dylib" || exit 1
xcrun clang -arch "$ARCH" -w -fobjc-arc -framework Metal -framework Foundation "$HERE/enumsim.m" -o "$T/enumsim" || exit 1
echo "--- running $ARCH (plugin $B)"
DYLD_INSERT_LIBRARIES="$T/libenumsim.dylib" NVMTL_SIM_PLUGIN="$B" NVMTL_SIM_NO_GPU=1 NVMTL_ENABLE=1 NVMTL_LOG_PATH="$T/nvmtl.log" "$T/enumsim"
echo "--- plugin log: $T/nvmtl.log ($(wc -l < "$T/nvmtl.log") lines)"
