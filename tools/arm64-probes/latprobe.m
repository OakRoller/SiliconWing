// latprobe.m: what one dispatch and one dependent load cost on a Metal device, timed with the command buffer's GPU times.
//   latprobe nvidia|apple
//   1. empty kernel, 1 thread, 1000 dispatches in one serial encoder          -> us per dispatch
//   2. the same with 64 bytes of setBytes constants read by the kernel        -> us per dispatch
//   3. one thread chasing 2000 dependent pointers through a Shared buffer     -> ns per load (system memory on an eGPU)
//   4. the same chain in a Private buffer                                     -> ns per load (VRAM)
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>

static id<MTLDevice> pick(const char *which) {
    for (id<MTLDevice> d in MTLCopyAllDevices()) {
        BOOL nv = [NSStringFromClass([d class]) isEqualToString:@"NVMTLDevice"];
        if ((!strcmp(which, "nvidia") && nv) || (!strcmp(which, "apple") && !nv)) return d;
    }
    return nil;
}
static double gpu_us(id<MTLCommandBuffer> cb) { return (cb.GPUEndTime - cb.GPUStartTime) * 1e6; }

int main(int argc, char **argv) { @autoreleasepool {
    const char *which = argc > 1 ? argv[1] : "nvidia";
    id<MTLDevice> d = pick(which); if (!d) { printf("no %s device\n", which); return 2; }
    printf("device: %s\n", d.name.UTF8String);
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void empty_k(device uint *o [[buffer(0)]], uint gid [[thread_position_in_grid]]) { if (gid == 0xffffffffu) o[0] = 1; }\n"
    "struct C { uint4 v[4]; };\n"
    "kernel void const_k(device uint *o [[buffer(0)]], constant C &c [[buffer(1)]], uint gid [[thread_position_in_grid]]) { if (c.v[3].w == 0xdeadbeefu + gid) o[0] = 1; }\n"
    "kernel void bcast_k(device const uint *p [[buffer(0)]], device uint *o [[buffer(1)]], uint g [[thread_position_in_grid]]) {\n"
    "  uint a = 0; for (uint k = 0; k < 64; k++) a += p[(k + g) & 63]; o[g] = a; }\n"
    "kernel void chase_k(device const uint *p [[buffer(0)]], device uint *o [[buffer(1)]], constant uint &n [[buffer(2)]]) {\n"
    "  uint i = 0; for (uint k = 0; k < n; k++) i = p[i]; o[0] = i; }\n";
    NSError *err = nil;
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
    if (!lib) { printf("compile: %s\n", err.localizedDescription.UTF8String); return 1; }
    id<MTLComputePipelineState> pe = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"empty_k"] error:&err];
    id<MTLComputePipelineState> pc = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"const_k"] error:&err];
    id<MTLComputePipelineState> px = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"chase_k"] error:&err];
    id<MTLComputePipelineState> pbc = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"bcast_k"] error:&err];
    if (!pe || !pc || !px) { printf("pipeline: %s\n", err.localizedDescription.UTF8String); return 1; }
    id<MTLCommandQueue> q = [d newCommandQueue];
    id<MTLBuffer> out = [d newBufferWithLength:4096 options:MTLResourceStorageModeShared];

    for (int pass = 0; pass < 3; pass++) {
        const int N = 1000;
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:pe]; [e setBuffer:out offset:0 atIndex:0];
        for (int i = 0; i < N; i++) [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
        const double a = gpu_us(cb);
        cb = [q commandBuffer]; e = [cb computeCommandEncoder];
        [e setComputePipelineState:pc]; [e setBuffer:out offset:0 atIndex:0];
        uint32_t c[16] = {0};
        for (int i = 0; i < N; i++) { c[0] = i; [e setBytes:c length:sizeof c atIndex:1]; [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; }
        [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
        const double b = gpu_us(cb);
        cb = [q commandBuffer]; e = [cb computeCommandEncoderWithDispatchType:MTLDispatchTypeConcurrent];
        [e setComputePipelineState:pe]; [e setBuffer:out offset:0 atIndex:0];
        for (int i = 0; i < N; i++) [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
        const double cc = gpu_us(cb);
        cb = [q commandBuffer]; e = [cb computeCommandEncoder];
        [e setComputePipelineState:pe]; [e setBuffer:out offset:0 atIndex:0];
        for (int i = 0; i < N; i++) [e dispatchThreadgroups:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
        const double big = gpu_us(cb);
        printf("pass %d: empty dispatch %.2f us each, with 64 B setBytes %.2f us each, concurrent encoder %.2f us each, serial 4096 threads %.2f us each\n", pass, a / N, b / N, cc / N, big / N);
    }

    const uint32_t words = 64u << 20 >> 2, stride = 4096 / 4 * 3 + 16, n = 2000;
    id<MTLBuffer> sh = [d newBufferWithLength:(NSUInteger)words * 4 options:MTLResourceStorageModeShared];
    uint32_t *p = sh.contents; uint32_t at = 0;
    for (uint32_t k = 0; k < n + 8; k++) { uint32_t nx = (at + stride * (1 + (k * 7919u) % 13u)) % words; p[at] = nx; at = nx; }
    id<MTLBuffer> pv = [d newBufferWithLength:sh.length options:MTLResourceStorageModePrivate];
    { id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
      [bl copyFromBuffer:sh sourceOffset:0 toBuffer:pv destinationOffset:0 size:sh.length]; [bl endEncoding]; [cb commit]; [cb waitUntilCompleted]; }
    for (int pass = 0; pass < 3; pass++) {
        for (int which2 = 0; which2 < 2; which2++) {
            id<MTLBuffer> src2 = which2 ? pv : sh;
            double t[2];
            for (int m = 0; m < 2; m++) {
                uint32_t cnt = m ? n : 1;
                id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
                [e setComputePipelineState:px]; [e setBuffer:src2 offset:0 atIndex:0]; [e setBuffer:out offset:0 atIndex:1];
                [e setBytes:&cnt length:4 atIndex:2];
                [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
                t[m] = gpu_us(cb);
            }
            printf("pass %d: %s chain of %u dependent loads: %.1f us (1 load %.1f us) -> %.0f ns per load\n", pass,
                   which2 ? "Private (VRAM)  " : "Shared (sysmem) ", n, t[1], t[0], (t[1] - t[0]) * 1000.0 / (n - 1));
        }
    }
    {
        id<MTLBuffer> bs = [d newBufferWithLength:4096 options:MTLResourceStorageModeShared];
        id<MTLBuffer> bp = [d newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
        id<MTLBuffer> bo = [d newBufferWithLength:(1u << 20) * 4 options:MTLResourceStorageModePrivate];
        for (int i = 0; i < 1024; i++) ((uint32_t *)bs.contents)[i] = i;
        { id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
          [bl copyFromBuffer:bs sourceOffset:0 toBuffer:bp destinationOffset:0 size:4096]; [bl endEncoding]; [cb commit]; [cb waitUntilCompleted]; }
        for (int pass = 0; pass < 3; pass++) for (int w = 0; w < 2; w++) {
            id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            [e setComputePipelineState:pbc]; [e setBuffer:w ? bp : bs offset:0 atIndex:0]; [e setBuffer:bo offset:0 atIndex:1];
            [e dispatchThreadgroups:MTLSizeMake((1u << 20) / 256, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
            printf("pass %d: broadcast read, 1M threads x 64 loads of one 256 B %s buffer: %.1f us\n", pass, w ? "Private" : "Shared ", gpu_us(cb));
        }
    }
    return 0;
} }
