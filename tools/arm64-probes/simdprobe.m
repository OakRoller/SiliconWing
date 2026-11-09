// simdprobe.m: the SIMD-group and atomic operations 3DMark Steel Nomad's compute shaders use (simd_prefix_exclusive_sum,
// simd_shuffle, quad_shuffle_xor, device atomic add / max), on 256 threads of one threadgroup. Prints a checksum per
// operation and the first mismatch against the value computed on the CPU, so two GPUs can be compared.
#import <Metal/Metal.h>
#include <stdio.h>

int main(void) { @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    printf("device: %s\n", d.name.UTF8String);
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device uint *o [[buffer(0)]], device atomic_uint *cnt [[buffer(1)]], device atomic_int *mx [[buffer(2)]],\n"
    "              uint t [[thread_position_in_grid]], uint lane [[thread_index_in_simdgroup]], uint w [[threads_per_simdgroup]]) {\n"
    "  uint v = t * 3u + 1u;\n"
    "  o[t * 6 + 0] = simd_prefix_exclusive_sum(v);\n"
    "  o[t * 6 + 1] = simd_shuffle(v, (lane + 5u) % w);\n"
    "  o[t * 6 + 2] = quad_shuffle_xor(v, 1u);\n"
    "  o[t * 6 + 3] = atomic_fetch_add_explicit(cnt, 1u, memory_order_relaxed) < 256u ? 1u : 0u;\n"
    "  atomic_fetch_max_explicit(mx, int(t) - 100, memory_order_relaxed);\n"
    "  o[t * 6 + 4] = w;\n"
    "  o[t * 6 + 5] = lane;\n"
    "}\n";
    NSError *err = nil;
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
    if (!lib) { printf("compile: %s\n", err.localizedDescription.UTF8String); return 1; }
    id<MTLComputePipelineState> ps = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    if (!ps) { printf("pipeline: %s\n", err.localizedDescription.UTF8String); return 1; }
    const int N = 256;
    id<MTLBuffer> o = [d newBufferWithLength:N * 6 * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> cnt = [d newBufferWithLength:4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> mx = [d newBufferWithLength:4 options:MTLResourceStorageModeShared];
    memset(o.contents, 0xff, N * 6 * 4); *(uint32_t *)cnt.contents = 0; *(int32_t *)mx.contents = -1000;
    id<MTLCommandQueue> q = [d newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:ps]; [e setBuffer:o offset:0 atIndex:0]; [e setBuffer:cnt offset:0 atIndex:1]; [e setBuffer:mx offset:0 atIndex:2];
    [e dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(N, 1, 1)];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    const uint32_t *r = (const uint32_t *)o.contents;
    const uint32_t W = r[4];
    const char *names[4] = { "simd_prefix_exclusive_sum", "simd_shuffle", "quad_shuffle_xor", "atomic add (fetch < 256)" };
    for (int op = 0; op < 4; op++) {
        int bad = -1; uint32_t want = 0;
        for (int t = 0; t < N && bad < 0; t++) {
            const uint32_t lane = r[t * 6 + 5], base = t - lane;
            switch (op) {
            case 0: want = 0; for (uint32_t j = 0; j < lane; j++) want += (base + j) * 3 + 1; break;
            case 1: want = (base + (lane + 5) % W) * 3 + 1; break;
            case 2: want = (t ^ 1) * 3 + 1; break;
            case 3: want = 1; break;
            }
            if (r[t * 6 + op] != want) bad = t;
        }
        if (bad < 0) printf("%-28s ok\n", names[op]);
        else printf("%-28s MISMATCH at thread %d: got %u want %u (lane %u)\n", names[op], bad, r[bad * 6 + op], want, r[bad * 6 + 5]);
    }
    printf("simd width %u | counter %u want 256 | atomic max %d want 155 | status %ld\n", W, *(uint32_t *)cnt.contents, *(int32_t *)mx.contents, (long)cb.status);
    return 0;
} }
