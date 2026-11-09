#!/bin/bash
# cp-shotrun.sh <run> [count]: cp-bench.sh, and 20 s into the benchmark segment (as cp-ptrun.sh) ask for <count> (default
# 12) consecutive presented frames (/tmp/nvmtl-shot-request); they land in ~/Library/Logs/nvmtl/shot-<pid>-<n>.raw and
# are moved to out/shots/<run>/. A lost device kills the game at once (as cp-guard.sh).
N=${1:?run}; C=${2:-12}; R="$(cd "$(dirname "$0")/../.." && pwd)"; L="$HOME/Library/Logs/nvmtl/cp-nvmtl$N.log"
( for i in $(seq 1 200); do P=$(pgrep -f '[M]acOS/Cyberpunk2077') && [ -f "$TMPDIR/nvmtl-fps-$P.log" ] && break; sleep 2; done
  k=0; while kill -0 "$P" 2>/dev/null; do
    grep -aq "DEVICE_LOST" "$L" 2>/dev/null && { pkill -f '[M]acOS/Cyberpunk2077'; break; }
    s=$(tail -1 "$TMPDIR/nvmtl-fps-$P.log" | awk '{for(i=1;i<=NF;i++) if($i=="submits/frame") print $(i+1)}')
    [ -n "$s" ] && awk "BEGIN{exit !($s>=30)}" && k=$((k+1)) || k=0
    [ $k -eq 10 ] && echo "$C" > /tmp/nvmtl-shot-request; sleep 2; done
  mkdir -p "$R/out/shots/$N"; mv "$HOME"/Library/Logs/nvmtl/shot-$P-*.raw "$R/out/shots/$N/" 2>/dev/null ) &
W=$!; bash "$R/tools/arm64-probes/cp-bench.sh" "$N"; wait $W
