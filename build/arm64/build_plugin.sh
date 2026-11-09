#!/bin/bash
# build_plugin.sh [arm64|x86_64|universal]: NVMTLDriver (the Metal plugin bundle executable) from plugin/NVMTLDevice.m, which
# #includes the rest of plugin/. Default universal: the arm64 slice for native apps, the x86_64 slice for apps under
# Rosetta (those assume the Mac2 GPU family, which is what this driver exposes). Vulkan headers: VULKAN_HEADERS or
# ../vendor/Vulkan-Headers next to the repo.
set -uo pipefail
. "$(dirname "$0")/env.sh"
WHAT=${1:-universal}
VK=${VULKAN_HEADERS:-$REPO/../vendor/Vulkan-Headers/include}
[ -f "$VK/vulkan/vulkan.h" ] || { echo "STOP: no Vulkan headers at $VK (set VULKAN_HEADERS)"; exit 2; }
P="$REPO/out/plugin"; mkdir -p "$P"
RDEF=""; [ -n "${RELEASE:-}" ] && RDEF="-DNVMTL_RELEASE=1"
build_slice() {   # <arch>
  xcrun clang -arch "$1" -mmacosx-version-min=15.0 -bundle -fobjc-arc -O1 $RDEF -DNVMTL_APPLE_SILICON=1 -Wno-protocol -Wno-incomplete-implementation -w \
    -I"$VK" -o "$P/NVMTLDriver-$1" "$REPO/plugin/NVMTLDevice.m" \
    -framework Foundation -framework Metal -framework IOSurface -framework IOKit -framework CoreFoundation 2>"$P/NVMTLDriver-$1.err" \
    || { echo "STOP: $1 slice failed"; grep -E ': error: |Undefined symbols|referenced from' "$P/NVMTLDriver-$1.err" | head -20; return 1; }
  echo "$1: $(stat -f %z "$P/NVMTLDriver-$1") B"
}
case "$WHAT" in
  arm64|x86_64) build_slice "$WHAT" && cp "$P/NVMTLDriver-$WHAT" "$P/NVMTLDriver";;
  universal) build_slice arm64 && build_slice x86_64 && lipo -create "$P/NVMTLDriver-arm64" "$P/NVMTLDriver-x86_64" -output "$P/NVMTLDriver";;
  *) echo "usage: $0 [arm64|x86_64|universal]"; exit 2;;
esac || exit 1
codesign -f -s - "$P/NVMTLDriver" 2>/dev/null
echo "NVMTLDriver: $(lipo -archs "$P/NVMTLDriver")  $(stat -f %z "$P/NVMTLDriver") B  sha $(shasum -a 256 "$P/NVMTLDriver" | cut -c1-8)"
