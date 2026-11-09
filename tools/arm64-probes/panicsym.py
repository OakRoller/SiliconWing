#!/usr/bin/env python3
"""panicsym.py <panic file> <NVRM binary>: print the panic string's first line and the backtrace with NVRM frames symbolicated."""
import sys, json, re, subprocess, bisect
raw = open(sys.argv[1], "rb").read().decode("utf-8", "replace"); nl = raw.find("\n")
try: body = json.loads(raw[nl+1:]); ps = body.get("panicString", "")
except Exception: ps = raw
lines = ps.split("\n"); print(lines[0][:300])
for l in lines:
    if "Panicked thread" in l or "Panicked task" in l or "Debugger message" in l: print(l[:200])
bt = [int(m, 16) for m in re.findall(r"lr: (0x[0-9a-f]+)", ps)]
kx = re.findall(r"(com\.nullmoth\.[A-Za-z]+)\(([0-9.]+)\)\[([0-9A-F-]+)\]@(0x[0-9a-f]+)->(0x[0-9a-f]+)", ps)
print("kexts:", [(k[0], k[1], k[2][:8]) for k in kx])
kext = sys.argv[2]
te = int(subprocess.run(["bash","-c","otool -l '%s' | awk '/segname __TEXT_EXEC/{f=1} f && /vmaddr/{print $2; exit}'" % kext], capture_output=True, text=True).stdout.strip(), 16)
syms = []
for l in subprocess.run(["nm", "-n", kext], capture_output=True, text=True).stdout.splitlines():
    t = l.split()
    if len(t) == 3 and t[1] in "tT": syms.append((int(t[0], 16), t[2]))
addrs = [a for a, _ in syms]
nv = [k for k in kx if k[0] == "com.nullmoth.NVRM"]
for fr in bt[:24]:
    if nv and int(nv[0][3], 16) <= fr < int(nv[0][4], 16):
        va = te + (fr - int(nv[0][3], 16)); i = bisect.bisect_right(addrs, va) - 1
        print("  0x%x  NVRM %s+0x%x" % (fr, syms[i][1], va - syms[i][0]))
    else: print("  0x%x" % fr)
# the registers / fault address if present
for l in lines:
    if re.match(r"\s*(x[0-9]+|far|esr|pc|lr):", l.strip()) and ("far" in l or "esr" in l or "pc:" in l): print(l[:200])
