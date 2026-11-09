#!/bin/bash
# cp-guard.sh <run> [cp-bench|cp-ptrun]: run the benchmark and kill the game as soon as its log reports a lost device
# (a game that lost its device keeps running without a picture until cp-bench's 10-minute limit)
N=${1:?run}; S=${2:-cp-bench}; R="$(cd "$(dirname "$0")/../.." && pwd)"; L="$HOME/Library/Logs/nvmtl/cp-nvmtl$N.log"
( for i in $(seq 1 400); do sleep 2; [ -f "$L" ] && grep -aq "DEVICE_LOST" "$L" && { sleep 3; pkill -f '[M]acOS/Cyberpunk2077'; echo "cp-guard: device lost - game killed" >&2; break; }; done ) &
G=$!; bash "$R/tools/arm64-probes/$S.sh" "$N"; kill $G 2>/dev/null; wait $G 2>/dev/null
