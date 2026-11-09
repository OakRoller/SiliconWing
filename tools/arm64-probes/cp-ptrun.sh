#!/bin/bash
# cp-ptrun.sh <run-number>: cp-bench.sh with a passtime capture (NVMTL_PT_SEGS, default 20000) armed 20 s into the
# benchmark segment (10 fps-log lines with submits/frame >= 30), so runs with different settings sample the same scene.
# The capture lands in $TMPDIR/nvmtl-passtime-<pid>.log and is copied to out/cp-pt<run>.log.
N=${1:?run}; R="$(cd "$(dirname "$0")/../.." && pwd)"
export NVMTL_PT_SEGS=${NVMTL_PT_SEGS:-20000}
( for i in $(seq 1 200); do P=$(pgrep -f '[M]acOS/Cyberpunk2077') && [ -f "$TMPDIR/nvmtl-fps-$P.log" ] && break; sleep 2; done
  k=0; while kill -0 "$P" 2>/dev/null; do
    s=$(tail -1 "$TMPDIR/nvmtl-fps-$P.log" | awk '{for(i=1;i<=NF;i++) if($i=="submits/frame") print $(i+1)}')
    [ -n "$s" ] && awk "BEGIN{exit !($s>=30)}" && k=$((k+1)) || k=0
    [ $k -ge 10 ] && { touch /tmp/nvmtl-passtime-request; break; }; sleep 2; done
  while kill -0 "$P" 2>/dev/null; do sleep 2; done; cp "$TMPDIR/nvmtl-passtime-$P.log" "$R/out/cp-pt$N.log" 2>/dev/null ) &
W=$!
bash "$R/tools/arm64-probes/cp-bench.sh" "$N"
wait $W
