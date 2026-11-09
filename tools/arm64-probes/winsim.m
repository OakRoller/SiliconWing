// winsim.m: the presentation path. A window whose CAMetalLayer uses the NVMTLDevice; every frame clears to a colour
// that cycles and draws a triangle, presents, waits, then reads the drawable's IOSurface from the CPU: that surface is
// what WindowServer composites on the Apple GPU, so its pixels being right means the picture reaches the screen.
//   xcrun clang -fobjc-arc -framework Metal -framework QuartzCore -framework AppKit -framework IOSurface winsim.m -o winsim && ./winsim [seconds]
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <IOSurface/IOSurfaceRef.h>

int main(int argc, char **argv) { @autoreleasepool {
    double seconds = argc > 1 ? atof(argv[1]) : 8;
    id<MTLDevice> d = nil;
    for (id<MTLDevice> x in MTLCopyAllDevices()) if ([NSStringFromClass([x class]) isEqualToString:@"NVMTLDevice"]) d = x;
    if (!d) { printf("no NVMTLDevice\n"); return 99; }
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    const NSUInteger W = 512, H = 512;
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, W, H) styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable) backing:NSBackingStoreBuffered defer:NO];
    win.title = [NSString stringWithFormat:@"NVMTL on %@", d.name];
    NSView *v = win.contentView; v.wantsLayer = YES;
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = d; layer.pixelFormat = MTLPixelFormatBGRA8Unorm; layer.framebufferOnly = NO; layer.drawableSize = CGSizeMake(W, H);
    layer.frame = v.bounds; v.layer = layer;
    [win makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    printf("layer device: %s  drawableSize %gx%g\n", layer.device.name.UTF8String, layer.drawableSize.width, layer.drawableSize.height);

    NSError *err = nil;
    id<MTLLibrary> lib = [d newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct V { float4 pos [[position]]; float4 col; };\n"
        "vertex V vtx(uint vid [[vertex_id]], constant float &t [[buffer(0)]]) { float a = t + vid * 2.0944; V o; o.pos = float4(0.6 * cos(a), 0.6 * sin(a), 0, 1);\n"
        "  o.col = float4(vid == 0, vid == 1, vid == 2, 1); return o; }\n"
        "fragment float4 frag(V in [[stage_in]]) { return in.col; }\n" options:nil error:&err];
    if (!lib) { printf("library: %s\n", err.localizedDescription.UTF8String); return 3; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vtx"]; pd.fragmentFunction = [lib newFunctionWithName:@"frag"]; pd.colorAttachments[0].pixelFormat = layer.pixelFormat;
    id<MTLRenderPipelineState> pso = [d newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!pso) { printf("pipeline: %s\n", err.localizedDescription.UTF8String); return 4; }
    id<MTLCommandQueue> q = [d newCommandQueue];

    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    unsigned frames = 0, surfOk = 0, surfBad = 0, noDrawable = 0, cbBad = 0; double t0 = CACurrentMediaTime();
    while ([end timeIntervalSinceNow] > 0) {
        @autoreleasepool {
            NSEvent *e; while ((e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:nil inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:e];
            id<CAMetalDrawable> dr = [layer nextDrawable];
            if (!dr) { noDrawable++; [NSThread sleepForTimeInterval:0.016]; continue; }
            float t = (float)(CACurrentMediaTime() - t0);
            float r = 0.5f + 0.5f * sinf(t), g = 0.5f + 0.5f * sinf(t + 2.1f), b = 0.5f + 0.5f * sinf(t + 4.2f);
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = dr.texture; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, 1);
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
            [enc setRenderPipelineState:pso]; [enc setVertexBytes:&t length:4 atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [enc endEncoding];
            [cb presentDrawable:dr]; [cb commit]; [cb waitUntilCompleted];
            frames++;
            if (cb.status != MTLCommandBufferStatusCompleted) { cbBad++; if (cbBad < 4) printf("frame %u: status %ld %s\n", frames, (long)cb.status, cb.error ? cb.error.localizedDescription.UTF8String : ""); continue; }
            // what WindowServer will see: the drawable's IOSurface, read from the CPU
            IOSurfaceRef s = dr.texture.iosurface;
            if (s && IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL) == kIOReturnSuccess) {
                const uint8_t *base = IOSurfaceGetBaseAddress(s); size_t row = IOSurfaceGetBytesPerRow(s);
                const uint8_t *p = base + 4 * row + 4 * 4;   // pixel (4,4): background, BGRA
                int wb = (int)(b * 255 + 0.5f), wg = (int)(g * 255 + 0.5f), wr = (int)(r * 255 + 0.5f);
                int ok = abs(p[0] - wb) <= 2 && abs(p[1] - wg) <= 2 && abs(p[2] - wr) <= 2 && p[3] == 255;
                if (ok) surfOk++; else { surfBad++; if (surfBad < 4) printf("frame %u: surface pixel (4,4) = %u %u %u %u, cleared to B%d G%d R%d\n", frames, p[0], p[1], p[2], p[3], wb, wg, wr); }
                if (frames == 1 || frames == 60) {
                    // any triangle pixel near the centre must differ from the clear colour
                    const uint8_t *c = base + (H / 2) * row + (W / 2) * 4;
                    printf("frame %u: centre pixel B%u G%u R%u (clear B%d G%d R%d) -> %s; surface %ux%u id %u\n", frames, c[0], c[1], c[2], wb, wg, wr,
                           (abs(c[0] - wb) > 8 || abs(c[1] - wg) > 8 || abs(c[2] - wr) > 8) ? "triangle drawn" : "NO triangle", (unsigned)IOSurfaceGetWidth(s), (unsigned)IOSurfaceGetHeight(s), (unsigned)IOSurfaceGetID(s));
                }
                IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
            } else { surfBad++; if (surfBad < 4) printf("frame %u: drawable texture has no readable IOSurface (%p)\n", frames, s); }
        }
    }
    double fps = frames / seconds;
    printf("%u frames in %.0f s (%.1f fps, present+wait each frame), surface pixels right %u wrong %u, no-drawable %u, bad status %u\n", frames, seconds, fps, surfOk, surfBad, noDrawable, cbBad);
    return (frames > 0 && surfBad == 0 && cbBad == 0) ? 0 : 1;
} }
