#!/bin/bash
# build_nvk.sh: libvulkan_nouveau.dylib (NVK: Mesa's Vulkan driver with the NAK compiler) for the host architecture
# (arm64 on Apple Silicon), from a Mesa tree at nvk/MESA_BASE with nvk/nvk-macos.patch applied. Mirrors build263.sh
# minus its machine-specific paths. MESA points at the tree; the build goes to MESA/build-<arch>.
#   needs: meson, ninja, python3 (mako, pyyaml), rustc/cargo, bindgen, cbindgen, glslangValidator
set -uo pipefail
. "$(dirname "$0")/env.sh"
MESA=${MESA:-$REPO/../vendor/mesa}
HOSTARCH=$(uname -m); B="$MESA/build-$HOSTARCH"; L="$OUT/nvk"; mkdir -p "$L"
[ -f "$MESA/VERSION" ] || { echo "STOP: no Mesa tree at $MESA (set MESA)"; exit 2; }
grep -q 'nvkmd_nvrm' -r "$MESA/src/nouveau/vulkan/nvkmd" 2>/dev/null || { echo "STOP: nvk/nvk-macos.patch is not applied to $MESA"; exit 2; }
export PATH="$OUT/clc-prefix/bin:$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:$PATH"   # mesa_clc from build_mesa_clc.sh
grep -q '__aarch64__' "$MESA/src/nouveau/vulkan/nvkmd/nvrm/nvRmSemSurf.c" || { echo "STOP: build/arm64/patches/nvk-arm64.patch is not applied to $MESA"; exit 2; }
for t in meson ninja rustc cargo bindgen cbindgen glslangValidator mesa_clc vtn_bindgen2; do command -v "$t" >/dev/null || { echo "STOP: $t not found"; exit 2; }; done
BUILDTYPE=${BUILDTYPE:-release}
# the nvrm backend includes NVIDIA's RM control headers from a tree next to it; point it at the one build_rm.sh uses
ln -sfn "$OGKM" "$MESA/src/nouveau/vulkan/nvkmd/nvrm/open-gpu-kernel-modules"
# 615.78.08 dropped the Kepler class headers the nvrm backend still names (the driver was first built on 610.57.04).
# Mesa carries the same NVIDIA class headers under src/nouveau/headers/nvidia/classes; copy the missing ones over once.
for h in cla0c0 cla197 cla1c0 cla26f; do
  f="$OGKM/src/common/sdk/nvidia/inc/class/$h.h"
  [ -f "$f" ] || cp "$MESA/src/nouveau/headers/nvidia/classes/$h.h" "$f" || { echo "STOP: no $h.h in Mesa or the NVIDIA tree"; exit 2; }
done
if [ ! -f "$B/build.ninja" ]; then
  meson setup "$B" "$MESA" -Dbuildtype="$BUILDTYPE" -Db_ndebug=true -Dvulkan-drivers=nouveau -Dgallium-drivers= -Dplatforms= \
    -Degl=disabled -Dglx=disabled -Dglvnd=disabled -Dllvm=disabled -Dmesa-clc=system -Dshared-glapi=disabled \
    -Dvulkan-layers= -Dtools= -Dbuild-tests=false -Dexpat=disabled -Dzstd=disabled -Dlibunwind=disabled \
    -Dlmsensors=disabled -Dvalgrind=disabled -Dxlib-lease=disabled -Dgallium-rusticl=false -Dspirv-tools=disabled \
    > "$L/setup.log" 2>&1 || { echo "STOP: meson setup failed"; tail -30 "$L/setup.log"; exit 3; }
fi
ninja -C "$B" -k 0 src/nouveau/vulkan/libvulkan_nouveau.dylib > "$L/ninja.log" 2>&1; rc=$?
echo "ninja rc=$rc  errors=$(grep -c -E 'error(\[E[0-9]+\])?:' "$L/ninja.log")  FAILED=$(grep -c '^FAILED' "$L/ninja.log")"
[ $rc = 0 ] || { grep -E 'error(\[E[0-9]+\])?:' "$L/ninja.log" | head -20 | cut -c1-200; exit 4; }
D="$L/libvulkan_nouveau.dylib"; cp "$B/src/nouveau/vulkan/libvulkan_nouveau.dylib" "$D"
U=$(nm -m "$D" | grep '(undefined)' | grep -v weak | grep 'dynamically looked up'); [ -z "$U" ] || { echo "STOP: unresolved strong references:"; echo "$U"; exit 5; }
echo "built: $(lipo -archs "$D")  $(stat -f %z "$D") B  $D"
