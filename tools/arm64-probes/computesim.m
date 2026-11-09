// computesim.m: the first real work on the card. Picks the NVMTLDevice out of MTLCopyAllDevices, compiles a trivial
// MSL kernel, runs it over a buffer and checks the result on the CPU. Exit 0 only when every element is right.
//   xcrun clang -fobjc-arc -framework Metal -framework Foundation computesim.m -o computesim && ./computesim
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <mach/mach_time.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        const NSUInteger N = argc > 1 ? (NSUInteger)atoi(argv[1]) : 1 << 20;
        id<MTLDevice> d = nil;
        for (id<MTLDevice> x in MTLCopyAllDevices()) if ([NSStringFromClass([x class]) isEqualToString:@"NVMTLDevice"]) d = x;
        if (!d) { printf("no NVMTLDevice\n"); return 2; }
        printf("device: %s\n", d.name.UTF8String);
        NSError *err = nil;
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void add_mul(device const float *a [[buffer(0)]], device const float *b [[buffer(1)]], device float *out [[buffer(2)]],\n"
            "                    constant uint &n [[buffer(3)]], uint i [[thread_position_in_grid]]) { if (i < n) out[i] = a[i] * 2.0f + b[i]; }\n";
        id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
        if (!lib) { printf("newLibraryWithSource: %s\n", err.localizedDescription.UTF8String); return 3; }
        id<MTLFunction> fn = [lib newFunctionWithName:@"add_mul"];
        id<MTLComputePipelineState> pso = [d newComputePipelineStateWithFunction:fn error:&err];
        if (!pso) { printf("newComputePipelineState: %s\n", err.localizedDescription.UTF8String); return 4; }
        printf("pipeline: maxTotalThreadsPerThreadgroup %lu, threadExecutionWidth %lu\n",
               (unsigned long)pso.maxTotalThreadsPerThreadgroup, (unsigned long)pso.threadExecutionWidth);
        id<MTLBuffer> a = [d newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> b = [d newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> o = [d newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
        if (!a || !b || !o) { printf("buffer allocation failed (%p %p %p)\n", a, b, o); return 5; }
        float *pa = a.contents, *pb = b.contents, *po = o.contents;
        for (NSUInteger i = 0; i < N; i++) { pa[i] = (float)i; pb[i] = 1.0f; po[i] = -1.0f; }
        uint32_t n32 = (uint32_t)N;
        id<MTLCommandQueue> q = [d newCommandQueue];
        if (!q) { printf("newCommandQueue failed\n"); return 6; }
        uint64_t t0 = mach_absolute_time();
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pso];
        [enc setBuffer:a offset:0 atIndex:0]; [enc setBuffer:b offset:0 atIndex:1]; [enc setBuffer:o offset:0 atIndex:2];
        [enc setBytes:&n32 length:4 atIndex:3];
        NSUInteger tg = MIN(pso.maxTotalThreadsPerThreadgroup, (NSUInteger)256);
        [enc dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(tg, 1, 1)];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        uint64_t t1 = mach_absolute_time();
        mach_timebase_info_data_t tb; mach_timebase_info(&tb);
        printf("command buffer status %ld (4 = completed)%s%s; %.2f ms wall\n", (long)cb.status,
               cb.error ? ", error: " : "", cb.error ? cb.error.localizedDescription.UTF8String : "",
               (double)(t1 - t0) * tb.numer / tb.denom / 1e6);
        NSUInteger bad = 0, firstBad = 0;
        for (NSUInteger i = 0; i < N; i++) { float want = (float)i * 2.0f + 1.0f; if (po[i] != want) { if (!bad) firstBad = i; bad++; } }
        printf("checked %lu floats: %lu wrong%s\n", (unsigned long)N, (unsigned long)bad, bad ? "" : " -> THE CARD COMPUTED IT");
        if (bad) { printf("  first wrong at %lu: got %g want %g\n", (unsigned long)firstBad, po[firstBad], (float)firstBad * 2.0f + 1.0f); return 7; }
        return 0;
    }
}
