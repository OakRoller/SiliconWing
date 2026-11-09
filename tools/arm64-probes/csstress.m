// csstress.m: correctness of serial compute chains, setBytes constants and indirect dispatch, checked on the CPU.
//   csstress nvidia|apple [rounds]
// Each round, in several command buffers in flight at once:
//   A. a serial encoder of 64 dispatches over 4096 uints, x = x * 3 + k_i with k_i from setBytes (order and constants)
//   B. a dispatch writes an indirect argument buffer, a second dispatch is launched from it (indirect path)
//   C. a concurrent encoder of 64 dispatches over disjoint slices, each with its own setBytes constant
// Exit 0 only when every element of every round matches.
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

int main(int argc, char **argv) { @autoreleasepool {
    const char *which = argc > 1 ? argv[1] : "nvidia";
    const int rounds = argc > 2 ? atoi(argv[2]) : 20;
    id<MTLDevice> d = pick(which); if (!d) { printf("no %s device\n", which); return 2; }
    printf("device: %s, %d rounds\n", d.name.UTF8String, rounds);
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct K { uint k; uint pad[15]; };\n"
    "kernel void step_k(device uint *x [[buffer(0)]], constant K &c [[buffer(1)]], uint g [[thread_position_in_grid]]) { x[g] = x[g] * 3u + c.k + g; }\n"
    "kernel void args_k(device uint *a [[buffer(0)]], constant uint &n [[buffer(1)]]) { a[0] = n; a[1] = 1; a[2] = 1; }\n"
    "kernel void fill_k(device uint *y [[buffer(0)]], constant uint &v [[buffer(1)]], uint g [[thread_position_in_grid]]) { y[g] = v ^ (g * 2654435761u); }\n"
    "kernel void slice_k(device uint *z [[buffer(0)]], constant K &c [[buffer(1)]], uint g [[thread_position_in_grid]]) { z[c.pad[0] + g] = c.k * 7u + g; }\n";
    NSError *err = nil;
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
    if (!lib) { printf("compile: %s\n", err.localizedDescription.UTF8String); return 1; }
    id<MTLComputePipelineState> ps = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"step_k"] error:&err];
    id<MTLComputePipelineState> pa = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"args_k"] error:&err];
    id<MTLComputePipelineState> pf = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fill_k"] error:&err];
    id<MTLComputePipelineState> pz = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"slice_k"] error:&err];
    if (!ps || !pa || !pf || !pz) { printf("pipeline: %s\n", err.localizedDescription.UTF8String); return 1; }
    id<MTLCommandQueue> q = [d newCommandQueue];
    const uint32_t N = 4096, STEPS = 64, CB = 4;
    unsigned long long bad = 0, checked = 0;
    for (int r = 0; r < rounds; r++) {
        id<MTLBuffer> xs[CB], ys[CB], zs[CB], as[CB]; id<MTLCommandBuffer> cbs[CB]; uint32_t tgs[CB], ns[CB];
        for (uint32_t b = 0; b < CB; b++) {
            xs[b] = [d newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
            ys[b] = [d newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
            zs[b] = [d newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
            as[b] = [d newBufferWithLength:64 options:MTLResourceStorageModePrivate];
            uint32_t *x = xs[b].contents; for (uint32_t i = 0; i < N; i++) x[i] = i ^ (r * 977u + b);
            memset(ys[b].contents, 0, N * 4); memset(zs[b].contents, 0, N * 4);
            tgs[b] = (uint32_t[]){ 32, 64, 128, 256 }[(r + b) & 3];
            ns[b] = 1 + ((r * 13u + b * 7u) % (N / tgs[b]));
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            [e setComputePipelineState:ps]; [e setBuffer:xs[b] offset:0 atIndex:0];
            for (uint32_t s = 0; s < STEPS; s++) {
                uint32_t k[16] = { s * 1009u + r * 31u + b }; [e setBytes:k length:sizeof k atIndex:1];
                [e dispatchThreadgroups:MTLSizeMake(N / tgs[b], 1, 1) threadsPerThreadgroup:MTLSizeMake(tgs[b], 1, 1)];
            }
            [e setComputePipelineState:pa]; [e setBuffer:as[b] offset:0 atIndex:0]; [e setBytes:&ns[b] length:4 atIndex:1];
            [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
            uint32_t v = 0x9e3779b9u ^ (r * 65537u + b);
            [e setComputePipelineState:pf]; [e setBuffer:ys[b] offset:0 atIndex:0]; [e setBytes:&v length:4 atIndex:1];
            [e dispatchThreadgroupsWithIndirectBuffer:as[b] indirectBufferOffset:0 threadsPerThreadgroup:MTLSizeMake(tgs[b], 1, 1)];
            [e endEncoding];
            e = [cb computeCommandEncoderWithDispatchType:MTLDispatchTypeConcurrent];
            [e setComputePipelineState:pz]; [e setBuffer:zs[b] offset:0 atIndex:0];
            for (uint32_t s = 0; s < 64; s++) {
                uint32_t k[16] = { s + r * 100u + b * 10000u, s * (N / 64) }; [e setBytes:k length:sizeof k atIndex:1];
                [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(N / 64, 1, 1)];
            }
            [e endEncoding];
            [cb commit]; cbs[b] = cb;
        }
        for (uint32_t b = 0; b < CB; b++) {
            [cbs[b] waitUntilCompleted];
            if (cbs[b].status != MTLCommandBufferStatusCompleted) { printf("round %d cb %u status %ld error %s\n", r, b, (long)cbs[b].status, cbs[b].error.localizedDescription.UTF8String); bad++; continue; }
            const uint32_t *x = xs[b].contents, *y = ys[b].contents, *z = zs[b].contents; unsigned long long bx = 0, by = 0, bz = 0;
            for (uint32_t i = 0; i < N; i++) {
                uint32_t e = i ^ (r * 977u + b);
                for (uint32_t s = 0; s < STEPS; s++) e = e * 3u + (s * 1009u + r * 31u + b) + i;
                bx += x[i] != e;
                const uint32_t v = 0x9e3779b9u ^ (r * 65537u + b);
                const uint32_t ey = i < ns[b] * tgs[b] ? (v ^ (i * 2654435761u)) : 0u;
                by += y[i] != ey;
                const uint32_t s = i / (N / 64), g = i % (N / 64);
                bz += z[i] != (s + r * 100u + b * 10000u) * 7u + g;
            }
            checked += 3ull * N;
            if (bx || by || bz) { printf("round %d cb %u tg %u n %u: serial chain %llu wrong, indirect %llu wrong, concurrent %llu wrong\n", r, b, tgs[b], ns[b], bx, by, bz); bad += bx + by + bz; }
        }
    }
    printf("%s: %llu of %llu elements wrong\n", bad ? "FAIL" : "PASS", bad, checked);
    return bad ? 1 : 0;
} }
