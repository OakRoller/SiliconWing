#!/bin/bash
# build_nvaccel_arm.sh: NVAccelArm.kext (Apple Silicon accelerator, recording cut) for ARCH (default arm64e).
set -uo pipefail
. "$(dirname "$0")/env.sh"
SRC="$REPO/kexts/NVAccelArm"; K="$OUT/NVAccelArm.kext/Contents/MacOS"; B="$OUT/nvaccelarm-objs"
rm -rf "$OUT/NVAccelArm.kext" "$B"; mkdir -p "$K" "$B"
xcrun clang++ "${KEXT_CXXFLAGS[@]}" -c "$SRC/NVAccelArm.cpp" -o "$B/NVAccelArm.o" 2>"$B/cc.err" || { grep 'error' "$B/cc.err" | head; exit 4; }
xcrun clang++ "${KEXT_LDFLAGS[@]}" "$B/NVAccelArm.o" -o "$K/NVAccelArm" 2>"$B/link.err" || { grep -E '^\s+"?_|Undefined' "$B/link.err" | head -20; exit 5; }
cp "$SRC/Info.plist" "$OUT/NVAccelArm.kext/Contents/Info.plist"
# kernelmanagerd keeps the first binary it staged for a given CFBundleVersion, so every build gets its own number
# (0.<day of year>.<minute of day>: a kext version allows at most four digits per component, and 0.1.441400 was refused
# as "must be a valid kext version"); a reinstall of the same "0.1" silently kept running the old code (2026-11-03).
BUILDNO=$(( 10#$(date +%j) )).$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
plutil -replace CFBundleVersion -string "0.$BUILDNO" "$OUT/NVAccelArm.kext/Contents/Info.plist" >/dev/null
plutil -replace CFBundleShortVersionString -string "0.$BUILDNO" "$OUT/NVAccelArm.kext/Contents/Info.plist" >/dev/null
echo "NVAccelArm.kext ($ARCH): $(stat -f %z "$K/NVAccelArm") B  $(otool -hv "$K/NVAccelArm" | tail -1 | awk '{print $2, $3, $4}')"
