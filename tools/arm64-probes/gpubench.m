// gpubench.m: the same four workloads on either Metal device, wall-clock timed, best of three.
//   gpubench nvidia|apple [seconds-per-present-test]
//   1. FMA throughput (compute)            -> TFLOPS
//   2. device memory copy (compute)        -> GB/s
//   3. ALU-heavy fragment fill, offscreen  -> Mpixel/s at 2048x2048
//   4. present path: CAMetalLayer 3024x1898, display sync off, frames completed per second (the eGPU's copy-out wall)
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <mach/mach_time.h>

static double now(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * (double)tb.numer / tb.denom / 1e9; }
static id<MTLDevice> pick(const char *which) {
    for (id<MTLDevice> d in MTLCopyAllDevices()) {
        BOOL nv = [NSStringFromClass([d class]) isEqualToString:@"NVMTLDevice"];
        if ((!strcmp(which, "nvidia") && nv) || (!strcmp(which, "apple") && !nv)) return d;
    }
    return nil;
}
int main(int argc, char **argv) { @autoreleasepool {
    const char *which = argc > 1 ? argv[1] : "nvidia"; double presentSecs = argc > 2 ? atof(argv[2]) : 5;
    id<MTLDevice> d = pick(which); if (!d) { printf("no %s device\n", which); return 2; }
    printf("device: %s\n", d.name.UTF8String);
    NSError *err = nil;
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void fma_k(device float4 *out [[buffer(0)]], constant uint &iters [[buffer(1)]], uint gid [[thread_position_in_grid]]) {\n"
    "  float4 a = float4(gid * 1e-7f, 0.5f, 0.25f, 0.125f), b = float4(0.9999f), c = float4(1e-6f);\n"
    "  for (uint i = 0; i < iters; i++) { a = fma(a, b, c); a = fma(a, b, c); a = fma(a, b, c); a = fma(a, b, c); a = fma(a, b, c); a = fma(a, b, c); a = fma(a, b, c); a = fma(a, b, c); }\n"
    "  out[gid] = a; }\n"
    "kernel void copy_k(device const float4 *s [[buffer(0)]], device float4 *t [[buffer(1)]], uint gid [[thread_position_in_grid]]) { t[gid] = s[gid]; }\n"
    "struct V { float4 pos [[position]]; };\n"
    "vertex V fs_vtx(uint vid [[vertex_id]]) { V o; float2 p = float2((vid << 1) & 2, vid & 2); o.pos = float4(p * 2 - 1, 0, 1); return o; }\n"
    "fragment float4 heavy_frag(V in [[stage_in]], constant uint &iters [[buffer(0)]]) {\n"
    "  float2 uv = in.pos.xy * 0.001f; float acc = 0;\n"
    "  for (uint i = 0; i < iters; i++) { uv = float2(sin(uv.x * 1.7f + uv.y), cos(uv.y * 1.3f - uv.x)); acc += uv.x * uv.y; }\n"
    "  return float4(acc * 0.01f, uv, 1); }\n"
    "fragment float4 flat_frag(V in [[stage_in]]) { return float4(0.2, 0.4, 0.6, 1); }\n";
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
    if (!lib) { printf("compile: %s\n", err.localizedDescription.UTF8String); return 3; }
    id<MTLCommandQueue> q = [d newCommandQueue];
    id<MTLComputePipelineState> fmaP = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fma_k"] error:&err];
    id<MTLComputePipelineState> copyP = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"copy_k"] error:&err];
    if (!fmaP || !copyP) { printf("compute pipelines: %s\n", err.localizedDescription.UTF8String); return 4; }

    // 1. FMA
    { const NSUInteger threads = 1 << 20; uint32_t iters = 2048; const int reps = 10;
      id<MTLBuffer> out = [d newBufferWithLength:threads * 16 options:MTLResourceStorageModePrivate];
      double best = 1e9;
      for (int t = 0; t < 3; t++) {
        id<MTLCommandBuffer> cb = [q commandBuffer];
        for (int r = 0; r < reps; r++) { id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder]; [e setComputePipelineState:fmaP]; [e setBuffer:out offset:0 atIndex:0]; [e setBytes:&iters length:4 atIndex:1];
          [e dispatchThreads:MTLSizeMake(threads, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)]; [e endEncoding]; }
        double t0 = now(); [cb commit]; [cb waitUntilCompleted]; double dt = now() - t0; if (cb.status != MTLCommandBufferStatusCompleted) { printf("fma: status %ld\n", (long)cb.status); return 5; } if (dt < best) best = dt; }
      double flops = (double)threads * iters * 8 * 2 * 4 * reps;
      printf("1. FMA throughput:      %7.2f TFLOPS  (%.0f GFLOP in %.3f s)\n", flops / best / 1e12, flops / 1e9, best); }
    // 2. copy bandwidth
    { const NSUInteger bytes = 256u << 20; const int reps = 8;
      id<MTLBuffer> s = [d newBufferWithLength:bytes options:MTLResourceStorageModePrivate], t2 = [d newBufferWithLength:bytes options:MTLResourceStorageModePrivate];
      double best = 1e9;
      for (int t = 0; t < 3; t++) {
        id<MTLCommandBuffer> cb = [q commandBuffer];
        for (int r = 0; r < reps; r++) { id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder]; [e setComputePipelineState:copyP]; [e setBuffer:(r & 1) ? t2 : s offset:0 atIndex:0]; [e setBuffer:(r & 1) ? s : t2 offset:0 atIndex:1];
          [e dispatchThreads:MTLSizeMake(bytes / 16, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)]; [e endEncoding]; }
        double t0 = now(); [cb commit]; [cb waitUntilCompleted]; double dt = now() - t0; if (cb.status != MTLCommandBufferStatusCompleted) { printf("copy: status %ld\n", (long)cb.status); return 5; } if (dt < best) best = dt; }
      printf("2. device memory copy:  %7.1f GB/s    (read+write %.1f GB in %.3f s)\n", 2.0 * bytes * reps / best / 1e9, 2.0 * bytes * reps / 1e9, best); }
    // 3. fragment fill, ALU heavy and flat
    { const NSUInteger W = 2048, H = 2048; const int reps = 20;
      MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:H mipmapped:NO]; td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
      id<MTLTexture> rt = [d newTextureWithDescriptor:td];
      for (int mode = 0; mode < 2; mode++) {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"fs_vtx"]; pd.fragmentFunction = [lib newFunctionWithName:mode ? @"flat_frag" : @"heavy_frag"]; pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> pso = [d newRenderPipelineStateWithDescriptor:pd error:&err]; if (!pso) { printf("render pipeline: %s\n", err.localizedDescription.UTF8String); return 4; }
        uint32_t iters = 64; double best = 1e9;
        for (int t = 0; t < 3; t++) {
          id<MTLCommandBuffer> cb = [q commandBuffer];
          for (int r = 0; r < reps; r++) { MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp]; [e setRenderPipelineState:pso]; if (!mode) [e setFragmentBytes:&iters length:4 atIndex:0]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding]; }
          double t0 = now(); [cb commit]; [cb waitUntilCompleted]; double dt = now() - t0; if (cb.status != MTLCommandBufferStatusCompleted) { printf("fill: status %ld\n", (long)cb.status); return 5; } if (dt < best) best = dt; }
        double px = (double)W * H * reps;
        if (!mode) printf("3a. ALU-heavy fill:     %7.0f Mpixel/s (64 sin/cos iterations per pixel, %.3f s)\n", px / best / 1e6, best);
        else       printf("3b. flat fill:          %7.0f Mpixel/s (%.3f s)\n", px / best / 1e6, best); } }
    // 4. present path
    { [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
      const NSUInteger W = 3024, H = 1898;
      NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 480, 300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
      win.title = [NSString stringWithFormat:@"gpubench %s", which]; NSView *v = win.contentView; v.wantsLayer = YES;
      CAMetalLayer *layer = [CAMetalLayer layer]; layer.device = d; layer.pixelFormat = MTLPixelFormatBGRA8Unorm; layer.drawableSize = CGSizeMake(W, H); layer.displaySyncEnabled = NO; layer.maximumDrawableCount = 3; layer.frame = v.bounds; v.layer = layer;
      [win orderFront:nil];
      MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"fs_vtx"]; pd.fragmentFunction = [lib newFunctionWithName:@"flat_frag"]; pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
      id<MTLRenderPipelineState> pso = [d newRenderPipelineStateWithDescriptor:pd error:&err];
      __block unsigned done = 0; unsigned submitted = 0, noDrawable = 0; double t0 = now();
      while (now() - t0 < presentSecs) { @autoreleasepool {
        NSEvent *ev; while ((ev = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:nil inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:ev];
        id<CAMetalDrawable> dr = [layer nextDrawable]; if (!dr) { noDrawable++; continue; }
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = dr.texture; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.2, 0.3, 1);
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp]; [e setRenderPipelineState:pso]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
        [cb presentDrawable:dr]; [cb addCompletedHandler:^(id<MTLCommandBuffer> c) { __sync_fetch_and_add(&done, 1); }]; [cb commit]; submitted++; } }
      double dt = now() - t0;
      printf("4. present 3024x1898:   %7.1f frames/s (display sync off; %u submitted, %u completed, %u no-drawable, %.1f s)\n", done / dt, submitted, done, noDrawable, dt); }
    return 0; } }
