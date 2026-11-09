// cohprobe.m: CPU/GPU coherence of Shared (and Managed) memory as unified-memory apps rely on it. Each test prints PASS or
// FAIL with the first mismatch. Run on the Apple GPU for reference and on the NVIDIA one through the plugin.
//   cohprobe [device substring] [rounds=1]
// T1 cpu->gpu->cpu        CPU writes, a kernel reads and writes another part of the same buffer, CPU reads after completion
// T2 atomics              64K threads atomic_fetch_add into counters in a Shared buffer
// T3 same page            CPU and GPU write different words of one 16 KB page, the CPU also after commit while the GPU runs
// T4 ring                 CPU fills slot k and commits without waiting, 3 command buffers in flight, results checked k-2
// T5 blit                 fillBuffer and copyFromBuffer into Shared memory
// T6 fragment stores      a fragment shader writes device memory per pixel
// T7 argument pointer     a kernel writes through a gpuAddress the CPU put in an argument buffer
// T8 heap + small         a Shared heap's buffer, and 200 small (256 B) Shared buffers, written by kernels
// T9 shared event         the GPU writes, signals an event, then spins; the CPU waits for the event and reads before completion
// T10 managed             Managed buffer: didModifyRange, kernel, synchronizeResource, CPU read
// T11 ping-pong           100 rounds of CPU increments then GPU increments of the same words
// T12 buffer texture      a texture made on a Shared buffer, written by a kernel and as a render target; the CPU reads the buffer
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *src =
"#include <metal_stdlib>\n using namespace metal;\n"
"kernel void k_mul(device uint *b [[buffer(0)]], constant uint &n [[buffer(1)]], uint i [[thread_position_in_grid]]) { if (i < n) b[n + i] = b[i] * 3u + 1u; }\n"
"kernel void k_atom(device atomic_uint *c [[buffer(0)]], uint i [[thread_position_in_grid]]) { atomic_fetch_add_explicit(&c[i & 63], 1u, memory_order_relaxed); atomic_fetch_add_explicit(&c[64], i & 7, memory_order_relaxed); }\n"
"kernel void k_half(device uint *b [[buffer(0)]], uint i [[thread_position_in_grid]]) { if (i < 64) b[64 + i] = 0xA0000000u + i; }\n"
"kernel void k_sum(device const uint *slot [[buffer(0)]], device uint *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
"  if (i != 0) return; uint s = 0; for (uint k = 0; k < 1024; k++) s += slot[k]; out[0] = s; }\n"
"struct VO { float4 p [[position]]; };\n"
"vertex VO v_full(uint i [[vertex_id]]) { VO o; float2 t = float2((i << 1) & 2, i & 2); o.p = float4(t * 2 - 1, 0, 1); return o; }\n"
"fragment float4 f_store(VO in [[stage_in]], device uint *b [[buffer(0)]]) { uint x = uint(in.p.x), y = uint(in.p.y); b[y * 64 + x] = 0x51000000u + y * 64 + x; return float4(1); }\n"
"struct AB { device uint *p; };\n"
"kernel void k_argptr(constant AB &ab [[buffer(0)]], uint i [[thread_position_in_grid]]) { ab.p[i] = 0x77000000u + i; }\n"
"kernel void k_fill(device uint *b [[buffer(0)]], constant uint &tag [[buffer(1)]], uint i [[thread_position_in_grid]]) { if (i < 64) b[i] = tag + i; }\n"
"kernel void k_event_spin(device uint *b [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
"  if (i != 0) return; uint x = 1; for (uint k = 0; k < 20000000; k++) x = x * 1664525u + 1013904223u; b[1] = x; }\n"
"kernel void k_inc(device uint *b [[buffer(0)]], uint i [[thread_position_in_grid]]) { if (i < 1024) b[i] += 1000u; }\n"
"kernel void k_tex(texture2d<float, access::write> t [[texture(0)]], uint2 p [[thread_position_in_grid]]) { t.write(float4(float(p.x) / 255.0, float(p.y) / 255.0, 0.5, 1.0), p); }\n"
"fragment float4 f_red(VO in [[stage_in]]) { return float4(1, 0, 0, 1); }\n";

static id<MTLDevice> dev; static id<MTLCommandQueue> q; static id<MTLLibrary> lib;
static NSMutableDictionary *pso;
static int fails;
static id<MTLComputePipelineState> K(NSString *n) {
    if (!pso[n]) { NSError *e = nil; pso[n] = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:n] error:&e]; if (!pso[n]) { printf("pipeline %s: %s\n", n.UTF8String, e.localizedDescription.UTF8String); exit(1); } }
    return pso[n];
}
static void report(const char *t, int ok, const char *fmt, ...) {
    char m[300] = ""; va_list a; va_start(a, fmt); vsnprintf(m, sizeof m, fmt, a); va_end(a);
    printf("%-22s %s %s\n", t, ok ? "PASS" : "FAIL", ok ? "" : m); if (!ok) fails++;
}
static void dispatch1(id<MTLComputeCommandEncoder> e, NSUInteger n) {
    [e dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(MIN(n, (NSUInteger)64), 1, 1)];
}
static id<MTLBuffer> SB(NSUInteger len) { return [dev newBufferWithLength:len options:MTLResourceStorageModeShared]; }

static void t1(void) {
    const uint32_t n = 1 << 20; id<MTLBuffer> b = SB(2 * n * 4); uint32_t *p = b.contents;
    for (uint32_t i = 0; i < n; i++) { p[i] = i ^ 0x5a5a; p[n + i] = 0; }
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:K(@"k_mul")]; [e setBuffer:b offset:0 atIndex:0]; [e setBytes:&n length:4 atIndex:1]; dispatch1(e, n); [e endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    for (uint32_t i = 0; i < n; i++) if (p[n + i] != (i ^ 0x5a5a) * 3u + 1u) { report("T1 cpu->gpu->cpu", 0, "at %u: %u want %u", i, p[n + i], (i ^ 0x5a5a) * 3u + 1u); return; }
    report("T1 cpu->gpu->cpu", 1, "");
}
static void t2(void) {
    id<MTLBuffer> b = SB(65 * 4); memset(b.contents, 0, 65 * 4);
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:K(@"k_atom")]; [e setBuffer:b offset:0 atIndex:0]; dispatch1(e, 65536); [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    const uint32_t *c = b.contents;
    for (int i = 0; i < 64; i++) if (c[i] != 1024) { report("T2 atomics", 0, "counter %d = %u want 1024", i, c[i]); return; }
    report("T2 atomics", c[64] == 65536u / 8 * 28, "sum %u want %u", c[64], 65536u / 8 * 28);
}
static void t3(void) {
    id<MTLBuffer> b = SB(65536); uint32_t *p = b.contents; memset(p, 0, 65536);
    for (int i = 0; i < 64; i++) p[i] = 0xC0000000u + i;   // CPU words 0..63 before commit
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:K(@"k_half")]; [e setBuffer:b offset:0 atIndex:0]; dispatch1(e, 64); [e endEncoding];
    e = [cb computeCommandEncoder]; [e setComputePipelineState:K(@"k_event_spin")]; [e setBuffer:b offset:16384 atIndex:0]; dispatch1(e, 1); [e endEncoding];
    [cb commit];
    for (int i = 0; i < 64; i++) p[128 + i] = 0xD0000000u + i;   // CPU words 128..191 while the GPU runs (same page)
    [cb waitUntilCompleted];
    for (int i = 0; i < 64; i++) {
        if (p[i] != 0xC0000000u + i) { report("T3 same page", 0, "cpu word %d lost: %08x", i, p[i]); return; }
        if (p[64 + i] != 0xA0000000u + i) { report("T3 same page", 0, "gpu word %d: %08x", 64 + i, p[64 + i]); return; }
        if (p[128 + i] != 0xD0000000u + i) { report("T3 same page", 0, "cpu word %d (written during GPU) lost: %08x", 128 + i, p[128 + i]); return; }
    }
    report("T3 same page", 1, "");
}
static void t4(void) {
    enum { SLOTS = 16, ITER = 64, INFL = 3 };
    id<MTLBuffer> ring = SB(SLOTS * 4096), out = SB(ITER * 4); memset(out.contents, 0xff, ITER * 4);
    uint32_t *r = ring.contents, *o = out.contents; uint32_t want[ITER]; id<MTLCommandBuffer> cbs[ITER];
    for (int k = 0; k < ITER; k++) {
        if (k >= INFL) { [cbs[k - INFL] waitUntilCompleted]; if (o[k - INFL] != want[k - INFL]) { report("T4 ring", 0, "iteration %d: sum %u want %u", k - INFL, o[k - INFL], want[k - INFL]); return; } }
        uint32_t *s = r + (k % SLOTS) * 1024, sum = 0; for (int i = 0; i < 1024; i++) { s[i] = (uint32_t)(k * 7919 + i); sum += s[i]; } want[k] = sum;
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:K(@"k_sum")]; [e setBuffer:ring offset:(k % SLOTS) * 4096 atIndex:0]; [e setBuffer:out offset:k * 4 atIndex:1]; dispatch1(e, 1); [e endEncoding];
        [cb commit]; cbs[k] = cb;
    }
    for (int k = ITER - INFL; k < ITER; k++) { [cbs[k] waitUntilCompleted]; if (o[k] != want[k]) { report("T4 ring", 0, "iteration %d: sum %u want %u", k, o[k], want[k]); return; } }
    report("T4 ring", 1, "");
}
// T13 heap ring: T4 with the ring and the results in a 32 MB Shared heap (large enough for shmirror to adopt it with
// NVMTL_SHM_HEAPS=1), each iteration's slot further into the heap, several command buffers in flight
static void t13(void) {
    enum { SLOTS = 512, ITER = 256, INFL = 6 };
    MTLHeapDescriptor *hd = [MTLHeapDescriptor new]; hd.size = 32 << 20; hd.storageMode = MTLStorageModeShared; hd.type = MTLHeapTypeAutomatic;
    id<MTLHeap> h = [dev newHeapWithDescriptor:hd];
    id<MTLBuffer> ring = [h newBufferWithLength:SLOTS * 16384 options:MTLResourceStorageModeShared], out = [h newBufferWithLength:ITER * 4 options:MTLResourceStorageModeShared];
    if (!ring || !out) { report("T13 heap ring", 0, "heap buffer nil"); return; }
    memset(out.contents, 0xff, ITER * 4);
    uint32_t *r = ring.contents, *o = out.contents; uint32_t want[ITER]; id<MTLCommandBuffer> cbs[ITER];
    for (int k = 0; k < ITER; k++) {
        if (k >= INFL) { [cbs[k - INFL] waitUntilCompleted]; if (o[k - INFL] != want[k - INFL]) { report("T13 heap ring", 0, "iteration %d: sum %u want %u", k - INFL, o[k - INFL], want[k - INFL]); return; } }
        uint32_t *sl = r + (k % SLOTS) * 4096, sum = 0; for (int i = 0; i < 1024; i++) { sl[i] = (uint32_t)(k * 7919 + i); sum += sl[i]; } want[k] = sum;
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:K(@"k_sum")]; [e setBuffer:ring offset:(k % SLOTS) * 16384 atIndex:0]; [e setBuffer:out offset:k * 4 atIndex:1]; dispatch1(e, 1); [e endEncoding];
        [cb commit]; cbs[k] = cb;
    }
    for (int k = ITER - INFL; k < ITER; k++) { [cbs[k] waitUntilCompleted]; if (o[k] != want[k]) { report("T13 heap ring", 0, "iteration %d: sum %u want %u", k, o[k], want[k]); return; } }
    report("T13 heap ring", 1, "");
}
static void t5(void) {
    id<MTLBuffer> a = SB(1 << 20), b = SB(1 << 20); uint8_t *pa = a.contents, *pb = b.contents;
    for (int i = 0; i < (1 << 20); i++) { pa[i] = (uint8_t)(i * 13); pb[i] = 0; }
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    [bl fillBuffer:b range:NSMakeRange(0, 4096) value:0x3c];
    [bl copyFromBuffer:a sourceOffset:8192 toBuffer:b destinationOffset:65536 size:100000];
    [bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
    for (int i = 0; i < 4096; i++) if (pb[i] != 0x3c) { report("T5 blit", 0, "fill at %d: %02x", i, pb[i]); return; }
    for (int i = 0; i < 100000; i++) if (pb[65536 + i] != (uint8_t)((8192 + i) * 13)) { report("T5 blit", 0, "copy at %d", i); return; }
    report("T5 blit", pb[4096] == 0 && pb[65535] == 0, "bytes outside the fill/copy changed");
}
static void t6(void) {
    NSError *err = nil; MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"v_full"]; pd.fragmentFunction = [lib newFunctionWithName:@"f_store"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> rp = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!rp) { report("T6 fragment stores", 0, "pipeline: %s", err.localizedDescription.UTF8String); return; }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td]; id<MTLBuffer> b = SB(64 * 64 * 4); memset(b.contents, 0, 64 * 64 * 4);
    MTLRenderPassDescriptor *r = [MTLRenderPassDescriptor new]; r.colorAttachments[0].texture = t; r.colorAttachments[0].loadAction = MTLLoadActionClear;
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:r];
    [e setRenderPipelineState:rp]; [e setFragmentBuffer:b offset:0 atIndex:0]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    const uint32_t *p = b.contents;
    for (uint32_t i = 0; i < 64 * 64; i++) if (p[i] != 0x51000000u + i) { report("T6 fragment stores", 0, "pixel %u: %08x", i, p[i]); return; }
    report("T6 fragment stores", 1, "");
}
static void t7(void) {
    id<MTLBuffer> target = SB(4096 * 4), ab = SB(16); memset(target.contents, 0, 4096 * 4);
    *(uint64_t *)ab.contents = target.gpuAddress + 4096;   // the pointer starts 1024 words in
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:K(@"k_argptr")]; [e setBuffer:ab offset:0 atIndex:0]; [e useResource:target usage:MTLResourceUsageWrite]; dispatch1(e, 1024); [e endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    const uint32_t *p = target.contents;
    for (int i = 0; i < 1024; i++) if (p[1024 + i] != 0x77000000u + i || p[i] != 0) { report("T7 argument pointer", 0, "word %d: %08x / %08x", i, p[1024 + i], p[i]); return; }
    report("T7 argument pointer", 1, "");
}
static void t8(void) {
    MTLHeapDescriptor *hd = [MTLHeapDescriptor new]; hd.size = 8 << 20; hd.storageMode = MTLStorageModeShared; hd.type = MTLHeapTypeAutomatic;
    id<MTLHeap> h = [dev newHeapWithDescriptor:hd]; id<MTLBuffer> hb = [h newBufferWithLength:1 << 20 options:MTLResourceStorageModeShared];
    NSMutableArray *small = [NSMutableArray new]; for (int i = 0; i < 200; i++) [small addObject:SB(256)];
    if (!hb) { report("T8 heap + small", 0, "heap buffer nil"); return; }
    memset(hb.contents, 0, 1 << 20);
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:K(@"k_fill")];
    uint32_t tag = 0x11000000; [e setBuffer:hb offset:65536 atIndex:0]; [e setBytes:&tag length:4 atIndex:1]; dispatch1(e, 64);
    for (int i = 0; i < 200; i++) { uint32_t tg = 0x20000000u + (uint32_t)i * 256; [e setBuffer:small[i] offset:0 atIndex:0]; [e setBytes:&tg length:4 atIndex:1]; dispatch1(e, 64); }
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    const uint32_t *p = hb.contents;
    for (int i = 0; i < 64; i++) if (p[16384 + i] != 0x11000000u + i) { report("T8 heap + small", 0, "heap word %d: %08x", i, p[16384 + i]); return; }
    for (int s = 0; s < 200; s++) { const uint32_t *q2 = ((id<MTLBuffer>)small[s]).contents;
        for (int i = 0; i < 64; i++) if (q2[i] != 0x20000000u + (uint32_t)s * 256 + i) { report("T8 heap + small", 0, "small buffer %d word %d: %08x", s, i, q2[i]); return; } }
    report("T8 heap + small", 1, "");
}
static void t9(void) {
    id<MTLSharedEvent> ev = [dev newSharedEvent]; id<MTLBuffer> b = SB(65536); uint32_t *p = b.contents; memset(p, 0, 65536);
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    uint32_t tag = 0x99000000; [e setComputePipelineState:K(@"k_fill")]; [e setBuffer:b offset:0 atIndex:0]; [e setBytes:&tag length:4 atIndex:1]; dispatch1(e, 64); [e endEncoding];
    [cb encodeSignalEvent:ev value:1];
    e = [cb computeCommandEncoder]; [e setComputePipelineState:K(@"k_event_spin")]; [e setBuffer:b offset:32768 atIndex:0]; dispatch1(e, 1); [e endEncoding];
    [cb commit];
    for (int spin = 0; spin < 5000 && ev.signaledValue < 1; spin++) usleep(1000);
    const int before = cb.status < MTLCommandBufferStatusCompleted;
    int ok = ev.signaledValue >= 1; for (int i = 0; ok && i < 64; i++) ok = p[i] == 0x99000000u + i;
    [cb waitUntilCompleted];
    report("T9 shared event", ok, "event %llu, word0 %08x, read %s completion", ev.signaledValue, p[0], before ? "before" : "after");
}
static void t10(void) {
    id<MTLBuffer> b = [dev newBufferWithLength:4096 options:MTLResourceStorageModeManaged]; uint32_t *p = b.contents;
    for (int i = 0; i < 64; i++) p[i] = 7;
    [b didModifyRange:NSMakeRange(0, 256)];
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:K(@"k_inc")]; [e setBuffer:b offset:0 atIndex:0]; dispatch1(e, 64); [e endEncoding];
    id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder]; [bl synchronizeResource:b]; [bl endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    for (int i = 0; i < 64; i++) if (p[i] != 1007) { report("T10 managed", 0, "word %d: %u", i, p[i]); return; }
    report("T10 managed", 1, "");
}
static void t12(void) {
    id<MTLBuffer> b = SB(64 * 256 * 2); memset(b.contents, 0, 64 * 256 * 2);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
    td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    id<MTLTexture> t = [b newTextureWithDescriptor:td offset:0 bytesPerRow:256];
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> rt = [b newTextureWithDescriptor:td offset:64 * 256 bytesPerRow:256];
    if (!t || !rt) { report("T12 buffer texture", 0, "texture on a buffer: nil"); return; }
    NSError *err = nil; MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"v_full"]; pd.fragmentFunction = [lib newFunctionWithName:@"f_red"]; pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> rps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:K(@"k_tex")]; [e setTexture:t atIndex:0]; [e dispatchThreads:MTLSizeMake(64, 64, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)]; [e endEncoding];
    MTLRenderPassDescriptor *r = [MTLRenderPassDescriptor new]; r.colorAttachments[0].texture = rt; r.colorAttachments[0].loadAction = MTLLoadActionClear;
    r.colorAttachments[0].clearColor = MTLClearColorMake(0, 1, 0, 1); r.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:r]; [re setRenderPipelineState:rps];
    [re setScissorRect:(MTLScissorRect){ 0, 0, 32, 64 }]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    const uint8_t *p = b.contents;
    for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) {
        const uint8_t *q2 = p + y * 256 + x * 4;
        if (abs((int)q2[0] - x) > 1 || abs((int)q2[1] - y) > 1 || q2[2] < 126 || q2[2] > 129 || q2[3] != 255) { report("T12 buffer texture", 0, "kernel texel (%d,%d) = %u %u %u %u", x, y, q2[0], q2[1], q2[2], q2[3]); return; }
        const uint8_t *r2 = p + 64 * 256 + y * 256 + x * 4; const int red = x < 32;
        if (r2[0] != (red ? 255 : 0) || r2[1] != (red ? 0 : 255) || r2[3] != 255) { report("T12 buffer texture", 0, "render target texel (%d,%d) = %u %u %u %u", x, y, r2[0], r2[1], r2[2], r2[3]); return; }
    }
    report("T12 buffer texture", 1, "");
}
static void t11(void) {
    id<MTLBuffer> b = SB(4096); uint32_t *p = b.contents; memset(p, 0, 4096);
    for (int r = 0; r < 100; r++) {
        for (int i = 0; i < 1024; i++) p[i] += 1;
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:K(@"k_inc")]; [e setBuffer:b offset:0 atIndex:0]; dispatch1(e, 1024); [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
        for (int i = 0; i < 1024; i++) if (p[i] != (uint32_t)(r + 1) * 1001u) { report("T11 ping-pong", 0, "round %d word %d: %u want %u", r, i, p[i], (uint32_t)(r + 1) * 1001u); return; }
    }
    report("T11 ping-pong", 1, "");
}
int main(int argc, char **argv) { @autoreleasepool {
    dev = MTLCreateSystemDefaultDevice();
    if (argc > 1) for (id<MTLDevice> d in MTLCopyAllDevices()) if ([d.name rangeOfString:@(argv[1])].location != NSNotFound) { dev = d; break; }
    const int rounds = argc > 2 ? atoi(argv[2]) : 1;
    NSError *err = nil; lib = [dev newLibraryWithSource:@(src) options:nil error:&err];
    if (!lib) { printf("library: %s\n", err.localizedDescription.UTF8String); return 1; }
    q = [dev newCommandQueue]; pso = [NSMutableDictionary new];
    printf("device %s, hasUnifiedMemory %d\n", dev.name.UTF8String, dev.hasUnifiedMemory);
    for (int r = 0; r < rounds; r++) { t1(); t2(); t3(); t4(); t5(); t6(); t7(); t8(); t9(); t10(); t11(); t12(); t13(); }
    printf("%s: %d failure(s)\n", fails ? "FAILED" : "ALL PASS", fails);
    return fails ? 1 : 0;
} }
