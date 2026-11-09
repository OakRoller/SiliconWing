#!/bin/bash
# build_mesa_clc.sh: the host-side OpenCL C compiler NVK's build needs (-Dmesa-clc=system). Built from the same Mesa tree
# in its own build directory with LLVM enabled, installed to out/<arch>/clc-prefix/bin/mesa_clc. Dependencies from
# Homebrew: llvm (clang libs), spirv-llvm-translator, libclc.
set -uo pipefail
. "$(dirname "$0")/env.sh"
MESA=${MESA:-$REPO/../vendor/mesa}
HOSTARCH=$(uname -m); B="$MESA/build-clc-$HOSTARCH"; PREFIX="$OUT/clc-prefix"; L="$OUT/nvk"; mkdir -p "$L"
LLVM=${LLVM_PREFIX:-/opt/homebrew/opt/llvm}
export PATH="$LLVM/bin:$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:$PATH"
# Homebrew's clang is first in PATH for llvm-config, but it guesses a Command Line Tools SDK that is not installed;
# the programs themselves are compiled with Apple's toolchain against the Xcode SDK.
export CC=/usr/bin/cc CXX=/usr/bin/c++ OBJC=/usr/bin/clang OBJCXX=/usr/bin/clang++ SDKROOT="$SDK"
export PKG_CONFIG_PATH="/opt/homebrew/opt/spirv-llvm-translator/lib/pkgconfig:/opt/homebrew/opt/libclc/share/pkgconfig:/opt/homebrew/opt/libclc/lib/pkgconfig:/opt/homebrew/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
for t in meson ninja llvm-config pkg-config; do command -v "$t" >/dev/null || { echo "STOP: $t not found"; exit 2; }; done
pkg-config --exists LLVMSPIRVLib || { echo "STOP: SPIRV-LLVM-Translator not found by pkg-config (brew install spirv-llvm-translator)"; exit 2; }
pkg-config --exists libclc || { echo "STOP: libclc not found by pkg-config (brew install libclc)"; exit 2; }
if [ ! -f "$B/build.ninja" ]; then
  meson setup "$B" "$MESA" --prefix="$PREFIX" -Dbuildtype=release -Dmesa-clc=enabled -Dinstall-mesa-clc=true -Dllvm=enabled -Dshared-llvm=enabled \
    -Dvulkan-drivers= -Dgallium-drivers= -Dplatforms= -Degl=disabled -Dglx=disabled -Dglvnd=disabled -Dshared-glapi=disabled \
    -Dvulkan-layers= -Dtools= -Dbuild-tests=false -Dzstd=disabled -Dlibunwind=disabled -Dlmsensors=disabled -Dvalgrind=disabled \
    -Dxlib-lease=disabled -Dgallium-rusticl=false -Dspirv-tools=enabled > "$L/clc-setup.log" 2>&1 || { echo "STOP: meson setup failed"; tail -25 "$L/clc-setup.log"; exit 3; }
fi
# mesa_clc compiles OpenCL C to SPIR-V; vtn_bindgen2 turns that SPIR-V into the C tables NVK links. NVK's meson looks
# for both on the host when -Dmesa-clc=system.
ninja -C "$B" src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2 > "$L/clc-ninja.log" 2>&1 || { echo "STOP: mesa_clc/vtn_bindgen2 build failed"; grep -E 'error' "$L/clc-ninja.log" | head -10 | cut -c1-200; exit 4; }
mkdir -p "$PREFIX/bin" && cp "$B/src/compiler/clc/mesa_clc" "$PREFIX/bin/mesa_clc" && cp "$B/src/compiler/spirv/vtn_bindgen2" "$PREFIX/bin/vtn_bindgen2"
echo "mesa_clc: $PREFIX/bin/mesa_clc ($(stat -f %z "$PREFIX/bin/mesa_clc") B); vtn_bindgen2: $(stat -f %z "$PREFIX/bin/vtn_bindgen2") B"
