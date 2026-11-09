#!/usr/bin/env python3
"""passdump2png.py <out-dir> [raw files...]: render the plugin's /tmp/nvmtl-pass-*.raw per-pass dumps (see
NVMTLRenderCommandEncoder nvmtlPassDump) as PNGs, one per file, plus a line of statistics each. The VkFormat and bytes
per pixel are in the file name; formats are decoded by family (8-bit UNORM/SRGB, 16-bit float, 32-bit float, packed
10/11-bit), unknown ones are shown as raw bytes."""
import sys, os, re, struct, math
from PIL import Image
def half(u):
    s = -1.0 if u & 0x8000 else 1.0; e = (u >> 10) & 0x1f; f = u & 0x3ff
    if e == 0: return s * (f / 1024.0) * 2.0 ** -14
    if e == 31: return s * (float('inf') if f == 0 else float('nan'))
    return s * (1 + f / 1024.0) * 2.0 ** (e - 15)
def tonemap(v): v = 0 if v != v else max(v, 0.0); return int(255 * min(1.0, v / (1.0 + v) * 1.5))
def decode(fmt, bpp, data, w, h):
    px = []; n = w * h
    if fmt in (44, 50):            # B8G8R8A8 UNORM/SRGB
        for i in range(n): b, g, r, a = data[4*i:4*i+4]; px.append((r, g, b))
    elif fmt in (37, 43, 23, 29):  # R8G8B8A8 UNORM/SRGB
        for i in range(n): r, g, b, a = data[4*i:4*i+4]; px.append((r, g, b))
    elif fmt == 9:                 # R8_UNORM
        for i in range(n): v = data[i]; px.append((v, v, v))
    elif fmt == 16:                # R8G8_UNORM
        for i in range(n): px.append((data[2*i], data[2*i+1], 0))
    elif fmt in (64, 58):          # A2B10G10R10 / A2R10G10B10 UNORM_PACK32
        for i in range(n):
            v = struct.unpack_from('<I', data, 4*i)[0]; c0, c1, c2 = (v & 1023) >> 2, ((v >> 10) & 1023) >> 2, ((v >> 20) & 1023) >> 2
            px.append((c0, c1, c2) if fmt == 64 else (c2, c1, c0))
    elif fmt == 122:               # B10G11R11_UFLOAT_PACK32
        def uf11(u): e = (u >> 6) & 31; m = u & 63; return (m / 64.0) * 2.0 ** -14 if e == 0 else (1 + m / 64.0) * 2.0 ** (e - 15)
        def uf10(u): e = (u >> 5) & 31; m = u & 31; return (m / 32.0) * 2.0 ** -14 if e == 0 else (1 + m / 32.0) * 2.0 ** (e - 15)
        for i in range(n):
            v = struct.unpack_from('<I', data, 4*i)[0]; px.append((tonemap(uf11(v & 2047)), tonemap(uf11((v >> 11) & 2047)), tonemap(uf10(v >> 22))))
    elif fmt == 97:                # R16G16B16A16_SFLOAT
        for i in range(n): r, g, b, a = struct.unpack_from('<4H', data, 8*i); px.append((tonemap(half(r)), tonemap(half(g)), tonemap(half(b))))
    elif fmt == 83:                # R16G16_SFLOAT
        for i in range(n): r, g = struct.unpack_from('<2H', data, 4*i); px.append((tonemap(half(r)), tonemap(half(g)), 0))
    elif fmt == 76:                # R16_SFLOAT
        for i in range(n): v = tonemap(half(struct.unpack_from('<H', data, 2*i)[0])); px.append((v, v, v))
    elif fmt == 70:                # R16_UNORM
        for i in range(n): v = struct.unpack_from('<H', data, 2*i)[0] >> 8; px.append((v, v, v))
    elif fmt == 100:               # R32_SFLOAT
        for i in range(n): v = tonemap(struct.unpack_from('<f', data, 4*i)[0]); px.append((v, v, v))
    elif fmt == 109:               # R32G32B32A32_SFLOAT
        for i in range(n): r, g, b, a = struct.unpack_from('<4f', data, 16*i); px.append((tonemap(r), tonemap(g), tonemap(b)))
    elif fmt in (126, 130):        # D32_SFLOAT / D32_SFLOAT_S8 depth aspect (depth 0..1 -> grey)
        for i in range(n): v = struct.unpack_from('<f', data, 4*i)[0]; v = 0.0 if v != v else min(max(v, 0.0), 1.0); c = int(255 * v); px.append((c, c, c))
    elif fmt in (124, 129):        # X8_D24 / D24S8 depth aspect: 24-bit depth in the low bits
        for i in range(n): v = (struct.unpack_from('<I', data, 4*i)[0] & 0xffffff) >> 16; px.append((v, v, v))
    elif fmt == 98:                # R32_UINT
        for i in range(n): v = struct.unpack_from('<I', data, 4*i)[0] & 255; px.append((v, v, v))
    else:
        for i in range(n): c = data[bpp*i:bpp*i+3]; px.append((c[0], c[1] if len(c) > 1 else 0, c[2] if len(c) > 2 else 0))
    return px
def main():
    out = sys.argv[1]; files = sys.argv[2:] or sorted(f for f in os.listdir('/tmp') if f.startswith('nvmtl-pass-') and f.endswith('.raw'))
    os.makedirs(out, exist_ok=True)
    for f in files:
        p = f if os.path.isabs(f) else os.path.join('/tmp', f)
        m = re.search(r'-(\d+)(?:ds0|c\d|ds)?-(\d+)x(\d+)-fmt(\d+)-bpp(\d+)\.raw$', p)
        if not m: print('skip', p); continue
        seq, w, h, fmt, bpp = (int(x) for x in m.groups()); data = open(p, 'rb').read()
        if len(data) < w * h * bpp: print('short', p); continue
        px = decode(fmt, bpp, data, w, h)
        im = Image.new('RGB', (w, h)); im.putdata(px); im.save(os.path.join(out, os.path.basename(p)[:-4] + '.png'))
        nz = sum(1 for c in px if c != (0, 0, 0)); mean = [sum(c[k] for c in px) / len(px) for k in range(3)]
        print('#%03u%s %ux%u fmt %u bpp %u: %.1f%% non-black, mean %.1f %.1f %.1f' % (seq, (' depth' if 'ds' in os.path.basename(p).split('-')[3] else ' ' + os.path.basename(p).split('-')[3][3:]), w, h, fmt, bpp, 100.0 * nz / len(px), *mean))
if __name__ == '__main__': main()
