// surfstress.m: which GPU access of CPU-cached memory trips the Apple fabric (AMCC UNEXP_RT_HIT_DIR, a non-coherent
// read of a line a CPU holds)? Five panics on 2026-11-04 happened at Cyberpunk's menu, where the plugin pins the app's
// own pages (IOSurface planes, newBufferWithBytesNoCopy) and lets the copy engine read/write them, while the game's
// pushbuffers and UBOs (NVK system memory, also CPU-cached) are read all the time without a panic. This drives each
// path alone, thousands of times, with the CPU dirtying the lines right before the GPU touches them:
//   in    IOSurface plane -> CPU writes -> blit from the IOSurface texture (surface-in: the CE reads the pinned pages)
//   out   blit into the IOSurface texture (surface-out: the CE writes the pinned pages), CPU reads it back
//   nocopy newBufferWithBytesNoCopy (pinned malloc pages) -> CPU writes -> blit to a private texture
//   shared control: a shared MTLBuffer (NVK system memory) -> CPU writes -> blit to a private texture
// A mode that panics within seconds names the path; one that runs clean for a minute is exonerated.
// Build: clang -fobjc-arc -framework Metal -framework Foundation -framework IOSurface -o out/rendersim/surfstress tools/arm64-probes/surfstress.m
// Run (same injection as cp-run.sh): surfstress <in|out|nocopy|shared> [seconds] [--nocpu]
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#include <sys/mman.h>

static id<MTLDevice> pick(void) { for (id<MTLDevice> x in MTLCopyAllDevices()) if ([NSStringFromClass([x class]) isEqualToString:@"NVMTLDevice"]) return x; return nil; }

int main(int argc, char **argv) { @autoreleasepool {
    const char *mode = argc > 1 ? argv[1] : "in";
    double seconds = argc > 2 ? atof(argv[2]) : 30;
    bool cpu = true; for (int i = 3; i < argc; i++) if (!strcmp(argv[i], "--nocpu")) cpu = false;
    id<MTLDevice> dev = pick();
    if (!dev) { fprintf(stderr, "no NVMTLDevice (inject usenv+enumsim with NVMTL_SIM_PLUGIN/NVMTL_ICD_LIB)\n"); return 2; }
    const NSUInteger W = 1280, H = 800, ROW = W * 4, BYTES = ROW * H;
    id<MTLCommandQueue> q = [dev newCommandQueue];
    MTLTextureDescriptor *pd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    pd.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget; pd.storageMode = MTLStorageModePrivate;
    id<MTLTexture> priv = [dev newTextureWithDescriptor:pd];

    IOSurfaceRef surf = NULL; id<MTLTexture> stex = nil; id<MTLBuffer> buf = nil; void *pages = NULL;
    if (!strcmp(mode, "in") || !strcmp(mode, "out")) {
        // NVMTL_SURF_CACHE=4 asks for a write-combined CPU mapping (what CoreAnimation gives display surfaces, which
        // the display's real-time agent reads non-coherently): the 2026-11-04 21:11 AMCC panic hit a pinned 1280x800
        // drawable plane, while this probe's default-cached surfaces never did
        const char *cm = getenv("NVMTL_SURF_CACHE");
        NSMutableDictionary *props = [@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4,
                                 (id)kIOSurfaceBytesPerRow: @(ROW), (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') } mutableCopy];
        if (cm) { props[(id)kIOSurfaceCacheMode] = @(atoi(cm)); printf("IOSurfaceCacheMode %d\n", atoi(cm)); }
        surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        if (!surf) { fprintf(stderr, "IOSurfaceCreate failed\n"); return 2; }
        MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
        sd.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget; sd.storageMode = MTLStorageModeShared;
        stex = [dev newTextureWithDescriptor:sd iosurface:surf plane:0];
        if (!stex) { fprintf(stderr, "newTextureWithDescriptor:iosurface: failed\n"); return 2; }
        printf("IOSurface %u: %lux%lu, row %zu, alloc %zu, base %p\n", IOSurfaceGetID(surf), (unsigned long)W, (unsigned long)H,
               IOSurfaceGetBytesPerRow(surf), IOSurfaceGetAllocSize(surf), IOSurfaceGetBaseAddress(surf));
    } else if (!strcmp(mode, "nocopy")) {
        pages = mmap(NULL, BYTES, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        memset(pages, 0x11, BYTES);
        buf = [dev newBufferWithBytesNoCopy:pages length:BYTES options:MTLResourceStorageModeShared deallocator:nil];
        if (!buf) { fprintf(stderr, "newBufferWithBytesNoCopy failed\n"); return 2; }
        printf("nocopy buffer: %lu bytes at %p (contents %p)\n", (unsigned long)BYTES, pages, buf.contents);
    } else if (!strcmp(mode, "shared")) {
        buf = [dev newBufferWithLength:BYTES options:MTLResourceStorageModeShared];
        pages = buf.contents;
        printf("shared buffer: %lu bytes, contents %p\n", (unsigned long)BYTES, pages);
    } else { fprintf(stderr, "mode in|out|nocopy|shared\n"); return 2; }

    NSDate *t0 = [NSDate date]; unsigned iter = 0; uint32_t pat = 0x01020304;
    printf("mode %s for %.0f s, CPU dirtying %s\n", mode, seconds, cpu ? "on" : "off"); fflush(stdout);
    while ([[NSDate date] timeIntervalSinceDate:t0] < seconds) {
        pat = pat * 1664525u + 1013904223u;
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
        if (!strcmp(mode, "in")) {
            if (cpu) { IOSurfaceLock(surf, 0, NULL); uint32_t *p = IOSurfaceGetBaseAddress(surf);
                       for (NSUInteger i = 0; i < BYTES / 4; i += 32) p[i] = pat + (uint32_t)i;   // one store per 128-byte line
                       IOSurfaceUnlock(surf, 0, NULL); }
            [bl copyFromTexture:stex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
                      toTexture:priv destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        } else if (!strcmp(mode, "out")) {
            [bl copyFromTexture:priv sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
                      toTexture:stex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        } else {
            if (cpu) { uint32_t *p = pages; for (NSUInteger i = 0; i < BYTES / 4; i += 32) p[i] = pat + (uint32_t)i; }
            [bl copyFromBuffer:buf sourceOffset:0 sourceBytesPerRow:ROW sourceBytesPerImage:BYTES sourceSize:MTLSizeMake(W, H, 1)
                     toTexture:priv destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        }
        [bl endEncoding];
        [cb commit]; [cb waitUntilCompleted];
        if (!strcmp(mode, "out") && cpu) { IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL); volatile uint32_t s = 0; const uint32_t *p = IOSurfaceGetBaseAddress(surf);
                                           for (NSUInteger i = 0; i < BYTES / 4; i += 32) s += p[i]; IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL); }
        if (++iter % 200 == 0) { printf("  %u iterations, %.1f s, status %ld\n", iter, [[NSDate date] timeIntervalSinceDate:t0], (long)cb.status); fflush(stdout); }
    }
    printf("DONE: %u iterations of %s in %.1f s without a panic\n", iter, mode, [[NSDate date] timeIntervalSinceDate:t0]);
    return 0;
} }
