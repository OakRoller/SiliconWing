#!/bin/bash
# nvrun.sh <timeout-seconds> <program> [args...]: run a probe on the RTX 3070 through the newest out/package-arm64 plugin and
# NVK (enumsim + usenv injected), killed after the timeout. Do NOT wrap probes in `perl -e alarm`: /usr/bin/perl is a
# protected binary, so DYLD_* is stripped and the probe silently gets the INSTALLED /Library/GPUBundles plugin.
T=${1:?timeout}; shift
R="$(cd "$(dirname "$0")/../.." && pwd)"
# the injection goes to the probe only: system binaries (sleep, kill) are arm64e and refuse these arm64 dylibs
env DYLD_INSERT_LIBRARIES="$R/out/usenv/libusenv.dylib:$R/out/enumsim-arm64/libenumsim.dylib" \
    NVMTL_SIM_PLUGIN="$R/out/package-arm64/Library/GPUBundles/NVMTLDriver.bundle" \
    NVMTL_ICD_LIB="$R/out/package-arm64/Library/GPUBundles/nvmtl/libvulkan_nouveau.dylib" \
    NVMTL_LOG_PATH="${NVMTL_LOG_PATH:-$HOME/Library/Logs/nvmtl/nvrun-$$.log}" "$@" & P=$!
( sleep "$T"; kill -9 $P 2>/dev/null ) >/dev/null 2>&1 & W=$!   # its output detached: a $(nvrun.sh ...) caller must not wait for the timer
wait $P; rc=$?; kill $W 2>/dev/null
exit $rc
