#!/bin/bash
# build_nvrm.sh: NVRM.kext for ARCH (default arm64e) from kexts/NVRM, linked against the libnvkernel.a / libnvkms.a
# that build_rm.sh produced. Prints the unresolved symbols on a link failure: those are OS-interface functions the
# XNU layer still has to provide.
set -uo pipefail
. "$(dirname "$0")/env.sh"
SRC="$REPO/kexts/NVRM"; K="$OUT/NVRM.kext/Contents/MacOS"; B="$OUT/nvrm-objs"
[ -f "$OUT/rm/libnvkernel.a" ] || { echo "STOP: run build_rm.sh first"; exit 2; }
rm -rf "$OUT/NVRM.kext" "$B"; mkdir -p "$K" "$B"
fail=0
for f in NVRM.cpp os-xnu.cpp os-xnu2.cpp nv_xnu_dma.cpp nv_xnu_stubs.cpp os-nvkms-xnu.cpp nv_xnu_power.cpp nvrm_fbinfo.cpp nvrm_gpuva.cpp nvrm_surfshare.cpp nvkms_shaders.cpp nv_xnu_memfuncs.cpp; do
  xcrun clang++ "${KEXT_CXXFLAGS[@]}" -I"$SRC" "${RMINC[@]}" "${KMSINC[@]}" "${RMDEFS[@]}" -c "$SRC/$f" -o "$B/${f%.cpp}.o" 2>"$B/${f%.cpp}.err" \
    || { echo "COMPILE FAILED: $f"; grep 'error:' "$B/${f%.cpp}.err" | head -8; fail=1; }
done
# RM-internal C files: compiled with RM's own flags so they see RM's structs as libnvkernel.a did (rmcc.py's job)
for f in nvrm_pageoff.c nvrm_kapi_fields.c; do
  xcrun clang $RM_DARWIN_CFLAGS -nostdinc -isystem "$RESOURCE_INC" -include "$OGKM/src/common/sdk/nvidia/inc/cpuopsys.h" "${RMINC[@]}" "${KMSINC[@]}" \
    -D_LANGUAGE_C -D__NO_CTYPE -DNVRM "${RMDEFS[@]}" -ffreestanding -fno-common -fno-stack-protector -std=gnu11 -O2 -w \
    -c "$SRC/$f" -o "$B/${f%.c}.o" 2>"$B/${f%.c}.err" || { echo "COMPILE FAILED: $f"; grep 'error:' "$B/${f%.c}.err" | head -8; fail=1; }
done
[ $fail = 0 ] || exit 4
xcrun clang++ "${KEXT_LDFLAGS[@]}" "$B"/*.o "$OUT/rm/libnvkernel.a" "$OUT/rm/libnvkms.a" -o "$K/NVRM" 2>"$B/link.err"
if [ $? != 0 ]; then
  echo "LINK FAILED. Undefined symbols:"; grep -E '^\s+"?_' "$B/link.err" | sed -E 's/^\s+//; s/", referenced from:.*//; s/^"//' | sort -u | head -80
  echo "(full log: $B/link.err)"; exit 5
fi
# Info.plist: on Apple Silicon there is no IOACPIFamily to depend on
cp "$SRC/Info.plist" "$OUT/NVRM.kext/Contents/Info.plist"
# kernelmanagerd keeps the first binary it staged for a given CFBundleVersion, so every build gets its own number
# (0.<day of year>.<minute of day>: a kext version allows at most four digits per component, and 0.1.441400 was refused
# as "must be a valid kext version"); a reinstall of the same "0.1" silently kept running the old code (2026-11-03).
BUILDNO=$(( 10#$(date +%j) )).$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
plutil -replace CFBundleVersion -string "0.$BUILDNO" "$OUT/NVRM.kext/Contents/Info.plist" >/dev/null
plutil -replace CFBundleShortVersionString -string "0.$BUILDNO" "$OUT/NVRM.kext/Contents/Info.plist" >/dev/null
[ "$ARCH" = arm64e ] && plutil -remove 'OSBundleLibraries.com\.apple\.iokit\.IOACPIFamily' "$OUT/NVRM.kext/Contents/Info.plist" >/dev/null
# On Apple Silicon the card is always behind Thunderbolt: IOPCIFamily matches a tunnelled device only to personalities
# that declare IOPCITunnelCompatible (tinygrad's tinygpu dext carries the same key for the same reason).
if [ "$ARCH" = arm64e ]; then
  plutil -insert 'IOKitPersonalities.NVRM.IOPCITunnelCompatible' -bool true "$OUT/NVRM.kext/Contents/Info.plist" >/dev/null 2>&1 \
    || echo "NOTE: could not set IOPCITunnelCompatible on the NVRM personality (check the personality name)"
fi
echo "NVRM.kext ($ARCH): $(stat -f %z "$K/NVRM") B  $(otool -hv "$K/NVRM" | tail -1 | awk '{print $2, $3, $4}')"
