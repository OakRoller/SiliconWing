#!/bin/bash
# build_nvk_x86_64.sh: the x86_64 slice of libvulkan_nouveau.dylib (NVK + NAK) cross-compiled on Apple Silicon, so
# Rosetta (x86_64) apps can load the driver. Same Mesa tree and -D options as build_nvk.sh; meson is driven by
# build/arm64/x86_64-apple-darwin.cross (Apple clang -arch x86_64, rustc --target x86_64-apple-darwin) and the build
# goes to MESA/build-x86_64. The host-only helpers mesa_clc and vtn_bindgen2 from build_mesa_clc.sh (out/arm64e/
# clc-prefix) are reused as-is: Mesa looks them up with native : true, so they run on the host.
#   needs: everything build_nvk.sh needs, the rustup target x86_64-apple-darwin, Rosetta (for meson's sanity checks)
set -uo pipefail
. "$(dirname "$0")/env.sh"
MESA=${MESA:-$REPO/../vendor/mesa}
XARCH=x86_64; B="$MESA/build-$XARCH"; XOUT="$REPO/out/$XARCH"; L="$XOUT/nvk"; mkdir -p "$L"
CROSS="$HERE_ENV/$XARCH-apple-darwin.cross"
[ -f "$CROSS" ] || { echo "STOP: no cross file at $CROSS"; exit 2; }
[ -f "$MESA/VERSION" ] || { echo "STOP: no Mesa tree at $MESA (set MESA)"; exit 2; }
grep -q 'nvkmd_nvrm' -r "$MESA/src/nouveau/vulkan/nvkmd" 2>/dev/null || { echo "STOP: nvk/nvk-macos.patch is not applied to $MESA"; exit 2; }
export PATH="$OUT/clc-prefix/bin:$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:$PATH"   # mesa_clc from build_mesa_clc.sh (host arch)
grep -q '__aarch64__' "$MESA/src/nouveau/vulkan/nvkmd/nvrm/nvRmSemSurf.c" || { echo "STOP: build/arm64/patches/nvk-arm64.patch is not applied to $MESA"; exit 2; }
for t in meson ninja rustc cargo bindgen cbindgen glslangValidator mesa_clc vtn_bindgen2; do command -v "$t" >/dev/null || { echo "STOP: $t not found"; exit 2; }; done
rustup target list --installed 2>/dev/null | grep -q "^$XARCH-apple-darwin$" || { echo "STOP: rustup target $XARCH-apple-darwin not installed (rustup target add $XARCH-apple-darwin)"; exit 2; }
arch -x86_64 /usr/bin/true 2>/dev/null || { echo "STOP: Rosetta is not installed (softwareupdate --install-rosetta); meson's cross sanity checks run x86_64 binaries"; exit 2; }
BUILDTYPE=${BUILDTYPE:-release}
# the nvrm backend includes NVIDIA's RM control headers from a tree next to it; point it at the one build_rm.sh uses
ln -sfn "$OGKM" "$MESA/src/nouveau/vulkan/nvkmd/nvrm/open-gpu-kernel-modules"
# 615.78.08 dropped the Kepler class headers the nvrm backend still names (the driver was first built on 610.57.04).
for h in cla0c0 cla197 cla1c0 cla26f; do
  f="$OGKM/src/common/sdk/nvidia/inc/class/$h.h"
  [ -f "$f" ] || cp "$MESA/src/nouveau/headers/nvidia/classes/$h.h" "$f" || { echo "STOP: no $h.h in Mesa or the NVIDIA tree"; exit 2; }
done
if [ ! -f "$B/build.ninja" ]; then
  meson setup "$B" "$MESA" --cross-file "$CROSS" -Dbuildtype="$BUILDTYPE" -Db_ndebug=true -Dvulkan-drivers=nouveau -Dgallium-drivers= -Dplatforms= \
    -Degl=disabled -Dglx=disabled -Dglvnd=disabled -Dllvm=disabled -Dmesa-clc=system -Dshared-glapi=disabled \
    -Dvulkan-layers= -Dtools= -Dbuild-tests=false -Dexpat=disabled -Dzstd=disabled -Dlibunwind=disabled \
    -Dlmsensors=disabled -Dvalgrind=disabled -Dxlib-lease=disabled -Dgallium-rusticl=false -Dspirv-tools=disabled \
    > "$L/setup.log" 2>&1 || { echo "STOP: meson setup failed"; tail -30 "$L/setup.log"; exit 3; }
fi
ninja -C "$B" -k 0 src/nouveau/vulkan/libvulkan_nouveau.dylib > "$L/ninja.log" 2>&1; rc=$?
echo "ninja rc=$rc  errors=$(grep -c -E 'error(\[E[0-9]+\])?:' "$L/ninja.log")  FAILED=$(grep -c '^FAILED' "$L/ninja.log")"
[ $rc = 0 ] || { grep -E 'error(\[E[0-9]+\])?:' "$L/ninja.log" | head -20 | cut -c1-200; exit 4; }
D="$L/libvulkan_nouveau.dylib"; cp "$B/src/nouveau/vulkan/libvulkan_nouveau.dylib" "$D"
[ "$(lipo -archs "$D")" = "$XARCH" ] || { echo "STOP: $D is $(lipo -archs "$D"), not $XARCH"; exit 5; }
U=$(nm -m "$D" | grep '(undefined)' | grep -v weak | grep 'dynamically looked up'); [ -z "$U" ] || { echo "STOP: unresolved strong references:"; echo "$U"; exit 5; }
echo "built: $(lipo -archs "$D")  $(stat -f %z "$D") B  $D"
