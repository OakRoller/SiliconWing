#!/bin/bash
# cp-bench.sh <run-number>: launch Cyberpunk 2077 straight into its benchmark (-benchmark), wait for it to finish, print
# the average fps over the benchmark (fps-log samples with submits/frame >= 25 and fps < 45), then quit the game.
# Environment knobs (NVK_*, NVMTL_*) pass through to the game; NVMTL_SURFOUT/SURFIN default to cpu as in every run.
set -u
N=${1:?run number}; R="$(cd "$(dirname "$0")/../.." && pwd)"
pgrep -f '[M]acOS/Cyberpunk2077' >/dev/null && { echo "cp-bench: the game is already running"; exit 1; }
export NVMTL_SURFOUT_READBACK=${NVMTL_SURFOUT_READBACK:-cpu} NVMTL_SURFIN_UPLOAD=${NVMTL_SURFIN_UPLOAD:-cpu}
CP_ARGS="-benchmark" bash "$R/tools/arm64-probes/cp-run.sh" "$N" >/dev/null
sleep 5; P=$(pgrep -f '[M]acOS/Cyberpunk2077'); [ -z "$P" ] && { echo "cp-bench: run $N did not start"; exit 1; }
F="$TMPDIR/nvmtl-fps-$P.log"; inb=0; t0=$(date +%s); res=""
while kill -0 "$P" 2>/dev/null; do
  if [ -f "$F" ]; then L=$(tail -1 "$F")
    s=$(echo "$L" | awk '{for(i=1;i<=NF;i++){if($i=="submits/frame")print $(i+1)}}')
    if [ -n "$s" ]; then
      awk "BEGIN{exit !($s>=30)}" && inb=1
      [ $inb = 1 ] && awk "BEGIN{exit !($s<10)}" && { res=done; break; }
    fi
  fi
  [ $(( $(date +%s) - t0 )) -gt 600 ] && { res=timeout; break; }
  sleep 2
done
[ -z "$res" ] && res="exited ($(grep -c EngineWatchdog ~/Library/Logs/nvmtl/cp-stdout$N.txt) watchdog)"
python3 - "$F" "$N" "$res" <<'PY'
import sys
rows=[]
try:
    for l in open(sys.argv[1]):
        p=l.split(); d=dict(zip(p[1::2],p[2::2]))
        try: rows.append((p[0],float(d['fps']),int(d['frames']),float(d['submits/frame']),float(d['gpubusy'].rstrip('%'))))
        except: pass
except FileNotFoundError: pass
best=[];cur=[]
for r in rows:
    if r[3]>=25 and r[1]<45: cur.append(r)
    else:
        if len(cur)>len(best): best=cur
        cur=[]
if len(cur)>len(best): best=cur
if not best: print('run %s: %s, no benchmark segment'%(sys.argv[2],sys.argv[3])); sys.exit(0)
fps=sorted(r[1] for r in best); busy=[r for r in best if r[4]>=85]
print('run %s: %s | avg %.2f fps over %d s | p10 %.1f median %.1f | busy-only %.2f | stall samples %d'%(sys.argv[2],sys.argv[3],
      sum(r[2] for r in best)/(2*len(best)),2*len(best),fps[len(fps)//10],fps[len(fps)//2],
      sum(r[2] for r in busy)/(2*max(len(busy),1)),len(best)-len(busy)))
PY
pkill -f '[M]acOS/Cyberpunk2077'; for i in $(seq 1 20); do pgrep -f '[M]acOS/Cyberpunk2077' >/dev/null || break; sleep 1; done
