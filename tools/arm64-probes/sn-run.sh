#!/bin/bash
# sn-run.sh <tag> nv|m1 [frames] : run 3DMark Steel Nomad's test child directly (the GUI strips DYLD_*, so its runs are
# always the Apple GPU). Needs out/3dm/setting.json, copied from dlc/steel-nomad-test while a GUI run's child is alive.
#   nv      the RTX 3070 through cp-run.sh's environment (enumsim + usenv, newest out/package-arm64 plugin and NVK)
#   m1      the Apple GPU (no injection)
#   frames  fixed-fps PNG output (1 frame per simulated second) into out/3dm/frames-<tag>/
# Extra environment passes through (NVMTL_DUMP_AIR_DIR, NVMTL_FLICK_FRAMES, ...). FLICK_AT="40 60" touches
# /tmp/nvmtl-flicker-request at those seconds; CENSUS_AT="45" (CENSUS_FRAMES, default 3) arms the draw/dispatch census. Prints status, score and the fps spread; result in out/3dm/Result-<tag>.json.
set -u
TAG=${1:?tag}; GPU=${2:?nv|m1}; FR=${3:-}
R="$(cd "$(dirname "$0")/../.." && pwd)"; W="$R/out/3dm"; LOGD=~/Library/Logs/nvmtl
D="$HOME/Library/Application Support/Steam/steamapps/common/3DMark Demo/dlc/steel-nomad-test"
[ -f "$W/setting.json" ] || { echo "sn-run: no $W/setting.json"; exit 1; }
IN="$W/setting-$TAG.json"
python3 - "$W/setting.json" "$IN" "$FR" "$W/frames-$TAG" <<'PY'
import json, sys, os
s = json.load(open(sys.argv[1]))
if sys.argv[3] == 'frames':
    os.makedirs(sys.argv[4], exist_ok=True)
    s.update({"enable_frame_output": True, "enable_fixed_fps": True, "frame_output_fixed_fps": 1,
              "frame_output_format": "png", "frame_output_file_name": sys.argv[4] + "/f"})
json.dump(s, open(sys.argv[2], 'w'), indent=1)
PY
rm -f "$W/Result-$TAG.json" /tmp/nvmtl-flicker-request
cd "$D" || exit 1
if [ "$GPU" = nv ]; then
    L="$R/out/enumsim-arm64/libenumsim.dylib"; B="$R/out/package-arm64/Library/GPUBundles/NVMTLDriver.bundle"
    NVKL="$R/out/package-arm64/Library/GPUBundles/nvmtl/libvulkan_nouveau.dylib"; U="$R/out/usenv/libusenv.dylib"
    SteamAppId=231350 SteamGameId=231350 NVMTL_SURFOUT_READBACK=cpu NVMTL_SURFIN_UPLOAD=cpu DYLD_INSERT_LIBRARIES="$U:$L" \
      NVMTL_SIM_PLUGIN="$B" NVMTL_ICD_LIB="$NVKL" NVMTL_LOG_PATH="$LOGD/sn-$TAG.log" \
      "$D/macos/bin/3DMarkSteelNomad" --in="$IN" --out="$W/Result-$TAG.json" > "$LOGD/sn-$TAG.txt" 2>&1 &
else
    SteamAppId=231350 SteamGameId=231350 "$D/macos/bin/3DMarkSteelNomad" --in="$IN" --out="$W/Result-$TAG.json" > "$LOGD/sn-$TAG.txt" 2>&1 &
fi
P=$!; t=0
while kill -0 $P 2>/dev/null && [ $t -lt 900 ]; do
    sleep 1; t=$((t+1))
    for a in ${FLICK_AT:-}; do [ "$a" = "$t" ] && touch /tmp/nvmtl-flicker-request; done
    for a in ${CENSUS_AT:-}; do [ "$a" = "$t" ] && echo "${CENSUS_FRAMES:-3} 0" > /tmp/nvmtl-census; done
done
echo "$TAG ($GPU): ended after $t s, pid $P"
python3 - "$W/Result-$TAG.json" <<'PY'
import json, sys
try: j = json.load(open(sys.argv[1]))
except Exception as e: print('no result:', e); sys.exit()
st = j.get('status', {}); score = [o.get('value') for o in j.get('outputs', []) if o.get('outputType') == 'TYPED_RESULT']
fps = [o for o in j.get('outputs', []) if o.get('outputName') == 'fps']
line = '%s score %s' % (st.get('statusCode'), ['%.2f fps' % v for v in score])
if fps:
    v = sorted(fps[0]['values']); line += ' | median %.1f p10 %.1f p90 %.1f' % (v[len(v)//2], v[len(v)//10], v[len(v)*9//10])
print(line)
if st.get('statusCode') != 'SUCCESS': print(st.get('detailedMessage', '')[:300])
PY
[ "$FR" = frames ] && echo "frames: $(ls "$W/frames-$TAG" | wc -l)"
[ -d "$LOGD/flick-$P" ] && echo "flicker: $LOGD/flick-$P/index.txt"
exit 0
