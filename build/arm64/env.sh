# env.sh: shared settings for the Apple Silicon (arm64e) build. Source it from the other scripts.
#   OGKM   NVIDIA open-gpu-kernel-modules tree (tag 615.78.08) with build/arm64/patches applied
#   ARCH   kext architecture (arm64e on Apple Silicon; x86_64 still builds the Intel driver)
#   OUT    where products go
set -u
HERE_ENV=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE_ENV/../.." && pwd)
OGKM=${OGKM:-$REPO/../vendor/ogkm}
ARCH=${ARCH:-arm64e}
OUT=${OUT:-$REPO/out/$ARCH}
SDK=$(xcrun --show-sdk-path)
KHDR="$SDK/System/Library/Frameworks/Kernel.framework/Headers"
NV="$OGKM/src/nvidia"; KMS="$OGKM/src/nvidia-modeset"
case "$ARCH" in
  arm64e) RM_TARGET_ARCH=arm64; RM_OUTDIR=_out/Darwin_arm64;;
  x86_64) RM_TARGET_ARCH=x86_64; RM_OUTDIR=_out/Darwin_x86_64;;
  *) echo "ARCH must be arm64e or x86_64" >&2; exit 2;;
esac
NV_VERSION=$(sed -n 's/^#define NV_VERSION_STRING *"\(.*\)"/\1/p' "$OGKM/src/common/inc/nvUnixVersion.h")
# What the RM's own makefiles add on top of utils.mk for a Darwin kernel object (EXTRA_CFLAGS). On arm64 these mirror
# NVIDIA's aarch64 Linux flags (general regs only, x18 reserved) plus the Darwin kernel code model.
# -mstrict-align: XNU maps PCI BARs as Device memory whatever cache mode a kext asks for (its arm64 pmap gives non-DRAM
# addresses Device-GRE at best, never Normal), and Device memory faults on any unaligned access. Without the flag clang
# merges adjacent 32-bit stores into one 64-bit store at a 4-byte offset (the video-engine trace header through BAR2:
# four alignment-abort panics on 2026-11-03). With it every access is naturally aligned for its own width.
RM_DARWIN_CFLAGS_arm64e="-arch arm64e -mkernel -mgeneral-regs-only -ffixed-x18 -mno-outline-atomics -mstrict-align -mmacosx-version-min=15.0"
RM_DARWIN_CFLAGS_x86_64="-arch x86_64 -mkernel -mmacosx-version-min=15.0"
eval "RM_DARWIN_CFLAGS=\${RM_DARWIN_CFLAGS_$ARCH}"
RM_DARWIN_CFLAGS="$RM_DARWIN_CFLAGS -DNV_UNIX -DNV_DARWIN -DNV_VERSION_STRING=\\\"$NV_VERSION\\\" -Wno-sign-conversion -Wno-unused-but-set-variable -Wno-unused-function -Wno-format-nonliteral -Wno-unknown-warning-option"
# Include paths and defines the kext sources need to see RM's structs exactly as libnvkernel.a saw them.
RMINC=( -I"$NV/arch/nvalloc/unix/include" -I"$NV/arch/nvalloc/common/inc" -I"$NV/arch/nvalloc/common/inc/gsp" -I"$NV/arch/nvalloc/common/inc/deprecated"
  -I"$OGKM/src/common/sdk/nvidia/inc" -I"$OGKM/src/common/sdk/nvidia/inc/hw" -I"$OGKM/src/common/inc" -I"$OGKM/src/common/shared/inc"
  -I"$NV/inc" -I"$NV/inc/os" -I"$NV/inc/kernel" -I"$NV/kernel/inc" -I"$NV/interface" -I"$OGKM/src/common/nvlink/interface"
  -I"$OGKM/src/common/inc/swref" -I"$OGKM/src/common/inc/swref/published" -I"$NV/inc/libraries" -I"$NV/src/libraries" -I"$NV/generated"
  -I"$NV/src/mm/uvm/interface" -I"$OGKM/src/common/uproc/os/libos-v2.0.0/include" -I"$OGKM/src/common/uproc/os/common/include"
  -I"$OGKM/src/common/inc/displayport" -I"$OGKM/src/common/nvlink/inband/interface"
  -I"$OGKM/src/common/nvswitch/kernel/inc" -I"$OGKM/src/common/nvswitch/interface" -I"$OGKM/src/common/nvswitch/common/inc"
  -I"$OGKM/src/common/mbedtls/3.6.2/include" -I"$OGKM/src/common/mbedtls/3.6.2/nvidia" )
KMSINC=( -I"$KMS/os-interface/include" -I"$KMS/kapi/interface" -I"$KMS/kapi/include" -I"$OGKM/src/common/unix/nvidia-push/interface"
  -I"$KMS/interface" -I"$KMS/include" -I"$OGKM/src/common/unix/common/inc" -I"$OGKM/src/common/modeset" -I"$OGKM/src/common/unix/common/utils/interface" )
RMDEFS=( -DNV_UNIX -DNV_DARWIN -DLOCK_VAL_ENABLED=0 -DPORT_ATOMIC_64_BIT_SUPPORTED=1 -DPORT_IS_KERNEL_BUILD=1 -DPORT_IS_CHECKED_BUILD=0
  -DPORT_MODULE_atomic=1 -DPORT_MODULE_core=1 -DPORT_MODULE_cpu=1 -DPORT_MODULE_crypto=1 -DPORT_MODULE_debug=1 -DPORT_MODULE_memory=1
  -DPORT_MODULE_safe=1 -DPORT_MODULE_string=1 -DPORT_MODULE_sync=1 -DPORT_MODULE_thread=1 -DPORT_MODULE_time=1 -DPORT_MODULE_util=1
  -DPORT_MODULE_example=0 -DPORT_MODULE_mmio=0 -DRS_STANDALONE=0 -DRS_STANDALONE_TEST=0 -DRS_COMPATABILITY_MODE=1 -DRS_PROVIDES_API_STATE=0
  -DNV_CONTAINERS_NO_TEMPLATES -DINCLUDE_NVLINK_LIB -DINCLUDE_NVSWITCH_LIB -DNV_PRINTF_STRINGS_ALLOWED=1 -DNV_ASSERT_FAILED_USES_STRINGS=1
  -DPORT_ASSERT_FAILED_USES_STRINGS=1 -D"MBEDTLS_USER_CONFIG_FILE=<nvrm_mbedtls_config.h>" )
KEXT_CXXFLAGS=( -arch "$ARCH" -fapple-kext -mkernel -nostdinc -I"$KHDR" -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT
  -std=c++17 -fno-rtti -fno-exceptions -fno-builtin -fno-common -O2 -Wall -Wno-unused-parameter -Wno-inconsistent-missing-override -Wno-unused-function )
[ "$ARCH" = arm64e ] && KEXT_CXXFLAGS+=( -mstrict-align )   # same reason as RM_DARWIN_CFLAGS_arm64e
KEXT_LDFLAGS=( -arch "$ARCH" -fapple-kext -nostdlib -Xlinker -kext -lkmodc++ -lkmod -lcc_kext )
RESOURCE_INC="$(xcrun clang -print-resource-dir)/include"
