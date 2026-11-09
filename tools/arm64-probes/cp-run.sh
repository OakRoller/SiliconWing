#!/bin/bash
# cp-run.sh <run-number> [trace] (CP_ARGS="-benchmark" passes game arguments): launch Cyberpunk 2077 on the NVIDIA GPU with the newest out/package-arm64 plugin + NVK
# injected, logging to ~/Library/Logs/nvmtl (survives a reboot, unlike /tmp). "trace" turns the plugin call trace on.
set -u
N=${1:?run number}; TR=${2:-}
R="$(cd "$(dirname "$0")/../.." && pwd)"; LOGD=~/Library/Logs/nvmtl; mkdir -p "$LOGD"
L="$R/out/enumsim-arm64/libenumsim.dylib"; B="$R/out/package-arm64/Library/GPUBundles/NVMTLDriver.bundle"
NVKL="$R/out/package-arm64/Library/GPUBundles/nvmtl/libvulkan_nouveau.dylib"; U="$R/out/usenv/libusenv.dylib"
A="$HOME/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/Cyberpunk2077.app"; X="$A/Contents/MacOS/Cyberpunk2077"
rm -f "$LOGD/cp-nvmtl$N.log" "$LOGD/cp-stdout$N.txt"
[ "$TR" = trace ] && touch /tmp/nvmtl-trace-request
cd "$A/Contents/MacOS" && SteamAppId=1091500 SteamGameId=1091500 DYLD_INSERT_LIBRARIES="$U:$L" NVMTL_SIM_PLUGIN="$B" NVMTL_ICD_LIB="$NVKL" \
  NVMTL_LOG_PATH="$LOGD/cp-nvmtl$N.log" "$X" ${CP_ARGS:-} > "$LOGD/cp-stdout$N.txt" 2>&1 &
echo "launched run $N (pid $!), log $LOGD/cp-nvmtl$N.log"
