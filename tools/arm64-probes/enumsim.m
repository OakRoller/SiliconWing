// enumsim.m: enumerate Metal devices and exercise the one our plugin made. Run through run_enumsim.sh.
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>
int main(int argc, char **argv) {
    @autoreleasepool {
        NSArray<id<MTLDevice>> *devs = MTLCopyAllDevices();
        printf("MTLCopyAllDevices -> %lu device(s)\n", (unsigned long)devs.count);
        id<MTLDevice> ours = nil;
        for (id<MTLDevice> d in devs) {
            Class c = object_getClass(d); NSMutableString *chain = [NSMutableString new];
            for (Class k = c; k; k = class_getSuperclass(k)) [chain appendFormat:@"%s%s", chain.length ? " -> " : "", class_getName(k)];
            printf("  %s  [%s]\n", d.name.UTF8String, chain.UTF8String);
            if (!strcmp(class_getName(c), "NVMTLDevice")) ours = d;
        }
        if (!ours) { printf("no NVMTLDevice came out of the enumeration\n"); return 1; }
        id<MTLDevice> d = ours;
        printf("NVMTLDevice:\n");
        printf("  registryID 0x%llx  headless %d  lowPower %d  removable %d  location %lu/%lu  maxTransferRate %llu\n",
               (unsigned long long)d.registryID, d.isHeadless, d.isLowPower, d.isRemovable, (unsigned long)d.location, (unsigned long)d.locationNumber,
               (unsigned long long)d.maxTransferRate);
        printf("  hasUnifiedMemory %d  recommendedMaxWorkingSetSize %llu  maxBufferLength %lu  peer %llu/%u/%u\n",
               d.hasUnifiedMemory, (unsigned long long)d.recommendedMaxWorkingSetSize, (unsigned long)d.maxBufferLength,
               (unsigned long long)d.peerGroupID, d.peerIndex, d.peerCount);
        printf("  supportsFamily Mac2 %d  Apple7 %d  Common3 %d  Metal3 %d\n", [d supportsFamily:MTLGPUFamilyMac2], [d supportsFamily:MTLGPUFamilyApple7],
               [d supportsFamily:MTLGPUFamilyCommon3], [d supportsFamily:MTLGPUFamilyMetal3]);
        printf("  architecture %s\n", d.architecture.name.UTF8String ?: "(nil)");
        id<MTLCommandQueue> q = [d newCommandQueue];
        printf("  newCommandQueue -> %s (expected nil without NVK)\n", q ? "queue" : "nil");
        // Shader path without a GPU: MSL -> AIR (Apple's compiler service) -> SPIR-V (our translator, arm64 build)
        NSError *err = nil;
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
                         "kernel void add1(device float *b [[buffer(0)]], uint i [[thread_position_in_grid]]) { b[i] += 1.0f; }\n"
                         "struct V { float4 p [[position]]; };\n"
                         "vertex V vmain(uint vid [[vertex_id]]) { V o; o.p = float4(float(vid), 0, 0, 1); return o; }\n"
                         "fragment float4 fmain(V in [[stage_in]]) { return float4(1, 0, 0, 1); }\n";
        id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
        printf("newLibraryWithSource -> %s%s\n", lib ? "library" : "nil", err ? [[NSString stringWithFormat:@" (%@)", err.localizedDescription] UTF8String] : "");
        if (lib) {
            printf("  functionNames: %s\n", [[lib.functionNames componentsJoinedByString:@", "] UTF8String]);
            id<MTLFunction> f = [lib newFunctionWithName:@"add1"];
            printf("  newFunctionWithName:add1 -> %s (type %lu)\n", f ? "function" : "nil", f ? (unsigned long)f.functionType : 0UL);
        }
        id<MTLDevice> def = MTLCreateSystemDefaultDevice();
        printf("MTLCreateSystemDefaultDevice -> %s\n", def ? def.name.UTF8String : "(nil)");
    }
    return 0;
}
