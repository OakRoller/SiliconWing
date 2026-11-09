#!/bin/bash
# cp-auditrun.sh <run> [shots]: cp-shotrun.sh with shmirror audits (and the verifier) triggered every 4 s only once the
# benchmark is running (10 fps-log lines with submits/frame >= 30) - audits during loading stall the main thread long
# enough for Cyberpunk's engine watchdog (runs 434, 437).
N=${1:?run}; C=${2:-12}; R="$(cd "$(dirname "$0")/../.." && pwd)"
( for i in $(seq 1 200); do P=$(pgrep -f '[M]acOS/Cyberpunk2077') && [ -f "$TMPDIR/nvmtl-fps-$P.log" ] && break; sleep 2; done
  k=0; while kill -0 "$P" 2>/dev/null; do
    s=$(tail -1 "$TMPDIR/nvmtl-fps-$P.log" | awk '{for(i=1;i<=NF;i++) if($i=="submits/frame") print $(i+1)}')
    [ -n "$s" ] && awk "BEGIN{exit !($s>=30)}" && k=$((k+1)) || k=0
    [ $k -ge 12 ] && touch /tmp/nvmtl-shm-audit; sleep 2; done ) >/dev/null 2>&1 &
A=$!; bash "$R/tools/arm64-probes/cp-shotrun.sh" "$N" "$C"; kill $A 2>/dev/null
