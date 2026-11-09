#!/bin/bash
# cp-m1run.sh <run>: Cyberpunk 2077's benchmark on the Mac's own GPU (no usenv, no plugin) with libmtltime.dylib inserted:
# the GPU timeline of an 8 s window 20 s into the benchmark goes to out/mtltime/m1-<run>.log. Waits for the game to quit
# (the benchmark ends it), then prints the game's own summary.
N=${1:?run}; R="$(cd "$(dirname "$0")/../.." && pwd)"; LOGD=~/Library/Logs/nvmtl; mkdir -p "$LOGD" "$R/out/mtltime"
A="$HOME/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/Cyberpunk2077.app"; X="$A/Contents/MacOS/Cyberpunk2077"
pgrep -f '[M]acOS/Cyberpunk2077' >/dev/null && { echo "cp-m1run: the game is already running"; exit 1; }
( cd "$A/Contents/MacOS" && SteamAppId=1091500 SteamGameId=1091500 DYLD_INSERT_LIBRARIES="$R/out/mtltime/libmtltime.dylib" \
  MTLTIME_OUT="$R/out/mtltime/m1-$N.log" "$X" -benchmark > "$LOGD/m1-stdout$N.txt" 2>&1 ) &
sleep 5; t0=$(date +%s)
while pgrep -f '[M]acOS/Cyberpunk2077' >/dev/null; do [ $(( $(date +%s) - t0 )) -gt 600 ] && { pkill -f '[M]acOS/Cyberpunk2077'; echo "cp-m1run: timeout"; }; sleep 3; done
D="$HOME/Library/Application Support/CD Projekt Red/Cyberpunk 2077/benchmarkResults"; f=$(ls -t "$D" | head -1)
python3 -c "
import json,os,sys
p=sys.argv[1]; p=os.path.join(p,[x for x in os.listdir(p) if x.endswith('.json')][0]) if os.path.isdir(p) else p
d=json.load(open(p))['Data']; print('m1 run', sys.argv[2], 'game summary avg %.2f min %.2f (%s)' % (d['averageFps'], d['minFps'], os.path.basename(sys.argv[1])))" "$D/$f" "$N"
grep -a "mtltime:" "$LOGD/m1-stdout$N.txt" | head -3
