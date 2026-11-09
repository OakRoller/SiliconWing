#!/usr/bin/env python3
"""Count arm64 memory instructions whose immediate offset is not a multiple of the access width (a heuristic for
compiler-merged accesses that fault on Device-type mappings). Usage: unaligned_scan.py <Mach-O> [symbol-filter]"""
import re, subprocess, sys
binary = sys.argv[1]; flt = sys.argv[2] if len(sys.argv) > 2 else None
out = subprocess.run(["objdump", "-d", "--no-show-raw-insn", binary], capture_output=True, text=True).stdout
width = {"x": 8, "q": 16, "d": 8, "w": 4, "s": 4}
pat = re.compile(r"\t(stur|ldur|stp|ldp|str|ldr)\t(x|w|q|d|s)(?:zr|[0-9]+)(?:, [wxqds](?:zr|[0-9]+))?, \[x(?:[0-9]+|zr|sp), #(-?0x[0-9a-f]+|-?[0-9]+)\]")
total = 0; per = {}; fn = "?"
for line in out.splitlines():
    if line.endswith(":") and not line.startswith(" "): fn = line[:-1]; continue
    m = pat.search(line)
    if not m: continue
    off = int(m.group(3), 0)
    if off % width[m.group(2)] != 0:
        if flt and flt not in fn: continue
        total += 1; per[fn] = per.get(fn, 0) + 1
print(f"{total} immediate-offset accesses not aligned to their width in {len(per)} functions")
for f, n in sorted(per.items(), key=lambda kv: -kv[1])[:25]: print(f"{n:5d}  {f}")
