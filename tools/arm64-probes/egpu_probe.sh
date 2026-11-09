#!/bin/bash
# egpu_probe.sh: what macOS sees of a Thunderbolt eGPU BEFORE any NVIDIA driver is installed. Run it as soon as the
# enclosure is plugged in (no sudo needed for most of it; sudo adds the PCI config space dump). Everything goes into one
# directory so the output can be attached to an issue or read back later.
#   bash tools/arm64-probes/egpu_probe.sh [outdir]
set -u
OUT=${1:-"$HOME/Desktop/egpu-probe-$(date +%Y%m%d-%H%M%S)"}; mkdir -p "$OUT"
say() { printf '%s\n' "$*" | tee -a "$OUT/summary.txt"; }
say "egpu_probe $(date)  macOS $(sw_vers -productVersion) ($(uname -m)) kernel $(uname -r)"

# 1. Is there an NVIDIA (vendor 0x10de) PCI function at all?
ioreg -rc IOPCIDevice -l -w0 > "$OUT/ioreg-pci.txt" 2>&1
ioreg -l -w0 > "$OUT/ioreg-full.txt" 2>&1
ioreg -p IOService -w0 > "$OUT/ioreg-tree.txt" 2>&1
NV=$(grep -c '"vendor-id" = <de10' "$OUT/ioreg-pci.txt")
say "NVIDIA PCI functions seen: $NV"
[ "$NV" -gt 0 ] || say "  none: check the Thunderbolt link (System Information > Thunderbolt), the enclosure's power, and whether the card is seated"

# 2. For each NVIDIA function: the properties the driver port needs
python3 - "$OUT" 2>&1 <<'PY' | tee -a "$OUT/summary.txt"
import re, sys, plistlib, subprocess
out = sys.argv[1]
# ioreg -a gives the registry as a plist; walk it for vendor-id 0x10de
xml = subprocess.run(["ioreg", "-a", "-l", "-w0", "-r", "-c", "IOPCIDevice"], capture_output=True).stdout
try:
    nodes = plistlib.loads(xml)
except Exception as e:
    print("ioreg plist parse failed:", e); sys.exit(0)
def walk(n, path):
    yield n, path
    for c in n.get("IORegistryEntryChildren", []):
        yield from walk(c, path + [n.get("IORegistryEntryName", "?")])
def b2i(v):
    if isinstance(v, bytes): return int.from_bytes(v[:4], "little")
    return v
rows = []
for n, path in walk({"IORegistryEntryChildren": nodes}, []):
    if n.get("IORegistryEntryName") is None: continue
    if b2i(n.get("vendor-id", b"")) != 0x10de: continue
    name = n.get("IORegistryEntryName"); dev = b2i(n.get("device-id")); cls = b2i(n.get("class-code"))
    print(f"\n== {'/'.join(path)}/{name}  device-id 0x{dev:04x} class-code 0x{cls:06x}")
    for k in ("pcidebug", "reg", "assigned-addresses", "ranges", "IOPCIResourced", "IOPCIMSIMode", "IOPCIExpressLinkStatus",
              "IOPCIExpressLinkCapabilities", "IOPCIPrimaryMatch", "IOInterruptSpecifiers", "IOInterruptControllers",
              "IOPCITunnelled", "IOPCITunnelCompatible", "IOPCIExpressCapabilities", "subsystem-id", "subsystem-vendor-id",
              "revision-id", "iommu-parent", "dart-parent", "IODMA", "IOPCIEnabled", "acpi-path", "name", "compatible",
              "IOPCIDeviceMemoryArray", "IOPowerManagement"):
        if k in n:
            v = n[k]
            if isinstance(v, bytes): v = v.hex()
            print(f"  {k}: {v}")
    # BARs: IODeviceMemory is what IOPCIFamily actually mapped (assigned-addresses needs the bridge's cell format to decode)
    for i, dm in enumerate(n.get("IODeviceMemory", [])):
        for r in dm:
            print("  memory[%d]: addr 0x%x length 0x%x (%d MiB)" % (i, r.get("address", 0), r.get("length", 0), r.get("length", 0) >> 20))
    ls = n.get("IOPCIExpressLinkStatus", 0); print("  link: gen%d x%d" % (ls & 0xf, (ls >> 4) & 0x3f))
    mc = n.get("IOPCIMSIMessageControl")
    if mc is not None: print("  MSI: 64-bit %s, enabled %s" % (bool(mc & 0x80), bool(mc & 1)))
    print("  DART page size:", n.get("IOPCIDeviceMapperPageSize"))
    rows.append(name)
if not rows: print("(no NVIDIA PCI function in the registry)")
PY

# 3. The IOMMU: which DART (Apple's IOMMU) the Thunderbolt PCIe root sits behind, and the mapper that IODMACommand will use
grep -n -i "dart\|iommu\|IOMapper" "$OUT/ioreg-tree.txt" | grep -i "pci\|t8\|tb\|apcie" | head -40 > "$OUT/dart.txt"
say "DART / IOMMU lines (dart.txt): $(wc -l < "$OUT/dart.txt")"

# 4. Thunderbolt link: generation, speed, the whole chain
system_profiler SPThunderboltDataType SPPCIDataType SPDisplaysDataType > "$OUT/system_profiler.txt" 2>&1
grep -A30 -i "nvidia" "$OUT/system_profiler.txt" | head -60 >> "$OUT/summary.txt"

# 5. Kernel messages about the hot-plug (last 10 minutes)
log show --last 10m --predicate 'process == "kernel"' --style compact 2>/dev/null | grep -i -E "pci|thunderbolt|apcie|dart|10de|nvidia|eGPU|tunnel" > "$OUT/kernel-log.txt"
say "kernel log lines mentioning PCI/Thunderbolt in the last 10 min: $(wc -l < "$OUT/kernel-log.txt")"

# 6. Security policy (needed later to load kexts) -- read only
{ csrutil status; echo; bputil -d 2>/dev/null | head -40; echo; nvram boot-args 2>/dev/null; } > "$OUT/security.txt" 2>&1

# 7. Page size, memory, the DMA-relevant sysctls
{ sysctl hw.pagesize hw.memsize vm.pages hw.model machdep.cpu.brand_string; } > "$OUT/sysctl.txt" 2>&1
say "written to $OUT"
