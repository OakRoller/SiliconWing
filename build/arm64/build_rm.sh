#!/bin/bash
# build_rm.sh: compile NVIDIA's resource manager (src/nvidia) and modeset (src/nvidia-modeset) for a Darwin kernel and
# archive the objects as libnvkernel.a and libnvkms.a. NVIDIA's own makefiles do the compiling (TARGET_OS=Darwin);
# only the link step differs, since macOS has no GNU ld -r / objcopy. Idempotent: make only rebuilds what changed.
set -uo pipefail
. "$(dirname "$0")/env.sh"
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}
[ -d "$NV" ] || { echo "STOP: no open-gpu-kernel-modules tree at $OGKM (set OGKM)"; exit 2; }
# the Darwin build patch (nvUnixVersion.h accepts NV_DARWIN); applied once
if ! grep -q NV_DARWIN "$OGKM/src/common/inc/nvUnixVersion.h"; then
  git -C "$OGKM" apply "$HERE_ENV/patches/615-darwin-build.patch" || { echo "STOP: Darwin build patch does not apply"; exit 3; }
fi
mkdir -p "$OUT/rm"
for comp in nvidia nvidia-modeset; do
  make -C "$OGKM/src/$comp" -k -j"$JOBS" -f "$HERE_ENV/objs.mk" objs TARGET_OS=Darwin TARGET_ARCH="$RM_TARGET_ARCH" \
       CC="xcrun clang" CXX="xcrun clang++" EXTRA_CFLAGS="$RM_DARWIN_CFLAGS" > "$OUT/rm/$comp.log" 2>&1
  rc=$?; errs=$(grep -c 'error:' "$OUT/rm/$comp.log")
  n=$(ls "$OGKM/src/$comp/$RM_OUTDIR/"*.o 2>/dev/null | wc -l | tr -d ' ')
  echo "$comp: make rc=$rc errors=$errs objects=$n"
  [ "$rc" = 0 ] || { grep 'error:' "$OUT/rm/$comp.log" | head -10; exit 4; }
done
# paths may contain spaces: collect the objects into arrays, never through word splitting
RMOBJS=(); for f in "$NV/$RM_OUTDIR/"*.o; do RMOBJS+=("$f"); done
KMSOBJS=(); for f in "$KMS/$RM_OUTDIR/"*.o; do case "$f" in *_shaders.xz.o) ;; *) KMSOBJS+=("$f");; esac; done
rm -f "$OUT/rm/libnvkernel.a" "$OUT/rm/libnvkms.a"
xcrun libtool -static -o "$OUT/rm/libnvkernel.a" "${RMOBJS[@]}" 2>"$OUT/rm/libtool-rm.err" || { cat "$OUT/rm/libtool-rm.err"; exit 5; }
xcrun libtool -static -o "$OUT/rm/libnvkms.a" "${KMSOBJS[@]}" 2>"$OUT/rm/libtool-kms.err" || { cat "$OUT/rm/libtool-kms.err"; exit 5; }
echo "archived ${#RMOBJS[@]} RM objects, ${#KMSOBJS[@]} modeset objects"
echo "libnvkernel.a $(stat -f %z "$OUT/rm/libnvkernel.a") B, libnvkms.a $(stat -f %z "$OUT/rm/libnvkms.a") B  (NVIDIA $NV_VERSION, $ARCH)"
