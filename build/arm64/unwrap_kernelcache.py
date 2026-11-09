#!/usr/bin/env python3
"""unwrap_kernelcache.py <kernelcache> <out>: pull the kernel collection (a Mach-O fileset) out of an Apple Silicon
kernelcache. The file is an IMG4/IM4P DER container whose payload is LZFSE ("bvx2") or LZSS ("complzss"); decompression
uses macOS's own libcompression through ctypes, so no third-party tool is needed. Read-only: used to list the symbols the
running kernel exports (nm) and to look at Apple's IOAcceleratorFamily2 classes for the arm64e accelerator build."""
import sys, ctypes, struct
data = open(sys.argv[1], "rb").read()
def der(buf, pos):
    tag = buf[pos]; pos += 1; l = buf[pos]; pos += 1
    if l & 0x80:
        n = l & 0x7f; l = int.from_bytes(buf[pos:pos+n], "big"); pos += n
    return tag, pos, l
def children(buf, pos, end):
    out = []
    while pos < end:
        tag, p, l = der(buf, pos); out.append((tag, p, l)); pos = p + l
    return out
tag, p, l = der(data, 0)                      # SEQUENCE IMG4 { "IMG4", SEQUENCE IM4P {...}, [0] IM4M } or a bare IM4P
items = children(data, p, p + l)
if data[items[0][1]:items[0][1]+4] == b"IMG4":
    t2, p2, l2 = items[1]                     # the IM4P sequence
    items = children(data, p2, p2 + l2)
assert data[items[0][1]:items[0][1]+4] == b"IM4P", "not an IM4P"
payload = None
for t, pp, ll in items:
    if t == 0x04 and ll > 1024: payload = data[pp:pp+ll]; break   # the big OCTET STRING
assert payload, "no payload"
if payload[:4] == b"bvx2" or payload[:4] == b"bvxn" or payload[:4] == b"bvx-":
    lib = ctypes.CDLL("/usr/lib/libcompression.dylib")
    COMPRESSION_LZFSE = 0x801
    size = 256 << 20
    while True:
        dst = ctypes.create_string_buffer(size)
        n = lib.compression_decode_buffer(dst, ctypes.c_size_t(size), payload, ctypes.c_size_t(len(payload)), None, COMPRESSION_LZFSE)
        if n < size: break
        size *= 2
    out = dst.raw[:n]; how = "lzfse"
elif payload[:8] == b"complzss":
    raise SystemExit("LZSS kernelcache: not handled yet")
else:
    out = payload; how = "raw"
open(sys.argv[2], "wb").write(out)
print(f"{how}: {len(payload)} -> {len(out)} bytes, magic {out[:4].hex()}")
