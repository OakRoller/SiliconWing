// tinypass.m: the GPU cost of many tiny render passes (one draw of one triangle on a WxH RGBA8 sRGB target each), one
// render encoder per pass, all in one command buffer; GPU time from GPUStartTime/GPUEndTime divided by the pass count.
//   tinypass [passes=200] [w=20] [h=38] [device substring] [texture w] [texture h]  (render area w x h inside the texture)
// Prints per-pass microseconds for: load=DontCare, load=Clear, load=Load, and the same draws in ONE encoder (no pass
// boundaries) for comparison.
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *src =
    "#include <metal_stdlib>\n using namespace metal;\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint i [[vertex_id]]) { V o; float2 t = float2((i << 1) & 2, i & 2); o.p = float4(t * 2 - 1, 0, 1); return o; }\n"
    "fragment float4 fs(V in [[stage_in]]) { return float4(0.25, 0.5, 0.75, 1); }\n"
    "fragment float4 fsc(V in [[stage_in]], constant uint *b [[buffer(0)]], constant uint &depth [[buffer(1)]]) {\n"
    "  uint k = 0; for (uint i = 0; i < depth; i++) k = b[k]; return float4(float(k & 255) / 255.0, 0.5, 0.75, 1); }\n";
// TP_CHAIN=shared|private [TP_DEPTH=8]: the fragment shader follows a chain of dependent loads through a buffer of that
// storage mode, each pass in a 4 KB region of its own (cold in the GPU caches), as a draw reading constants the CPU
// wrote this frame would

int main(int argc, char **argv) { @autoreleasepool {
    const int n = argc > 1 ? atoi(argv[1]) : 200, w = argc > 2 ? atoi(argv[2]) : 20, h = argc > 3 ? atoi(argv[3]) : 38;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (argc > 4) for (id<MTLDevice> d in MTLCopyAllDevices()) if ([d.name rangeOfString:@(argv[4])].location != NSNotFound) { dev = d; break; }
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@(src) options:nil error:&err];
    if (!lib) { printf("library: %s\n", err.localizedDescription.UTF8String); return 1; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    const char *chain = getenv("TP_CHAIN"); const uint32_t depth = getenv("TP_DEPTH") ? (uint32_t)atoi(getenv("TP_DEPTH")) : 8;
    pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:chain ? @"fsc" : @"fs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm_sRGB;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!ps) { printf("pipeline: %s\n", err.localizedDescription.UTF8String); return 1; }
    const int tw = argc > 5 ? atoi(argv[5]) : w, th = argc > 6 ? atoi(argv[6]) : h;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB width:tw height:th mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModePrivate;
    NSMutableArray *tex = [NSMutableArray new]; for (int i = 0; i < 25; i++) [tex addObject:[dev newTextureWithDescriptor:td]];
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLBuffer> cbuf = nil;
    if (chain) {
        const NSUInteger len = (NSUInteger)n * 4096;
        id<MTLBuffer> up = [dev newBufferWithLength:len options:MTLResourceStorageModeShared];
        uint32_t *u = up.contents; for (NSUInteger i = 0; i < len / 4; i++) u[i] = (uint32_t)((i % 1024) + 32) % 1024;   // b[k] = k + 32 (a new 128-byte line each load) inside each 4 KB region
        if (!strcmp(chain, "private")) {
            cbuf = [dev newBufferWithLength:len options:MTLResourceStorageModePrivate];
            id<MTLCommandBuffer> c = [q commandBuffer]; id<MTLBlitCommandEncoder> bl = [c blitCommandEncoder];
            [bl copyFromBuffer:up sourceOffset:0 toBuffer:cbuf destinationOffset:0 size:len]; [bl endEncoding]; [c commit]; [c waitUntilCompleted];
        } else cbuf = up;
        printf("fragment shader: %u dependent loads from a %s buffer, a 4 KB region per pass\n", depth, chain);
    }
    printf("device %s | %d passes of %dx%d in a %dx%d texture\n", dev.name.UTF8String, n, w, h, tw, th);
    const char *names[] = { "load DontCare", "load Clear", "load Load", "one encoder, all draws" };
    for (int mode = 0; mode < 4; mode++) {
        double best = 1e9;
        for (int rep = 0; rep < 4; rep++) {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            if (mode == 3) {
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
                rp.colorAttachments[0].texture = tex[0]; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
                [e setRenderPipelineState:ps];
                for (int i = 0; i < n; i++) {
                    if (cbuf) { [e setFragmentBuffer:cbuf offset:(NSUInteger)i * 4096 atIndex:0]; [e setFragmentBytes:&depth length:4 atIndex:1]; }
                    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; }
                [e endEncoding];
            } else for (int i = 0; i < n; i++) {
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
                rp.colorAttachments[0].texture = tex[i % 25];
                rp.colorAttachments[0].loadAction = mode == 0 ? MTLLoadActionDontCare : mode == 1 ? MTLLoadActionClear : MTLLoadActionLoad;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                if (tw != w || th != h) { rp.renderTargetWidth = w; rp.renderTargetHeight = h; }
                id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
                [e setRenderPipelineState:ps];
                if (cbuf) { [e setFragmentBuffer:cbuf offset:(NSUInteger)i * 4096 atIndex:0]; [e setFragmentBytes:&depth length:4 atIndex:1]; }
                [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [e endEncoding];
            }
            [cb commit]; [cb waitUntilCompleted];
            const double us = (cb.GPUEndTime - cb.GPUStartTime) * 1e6;
            if (rep && us < best) best = us;   // rep 0 warms up
        }
        printf("  %-24s %8.1f us total, %6.2f us per %s\n", names[mode], best, best / n, mode == 3 ? "draw" : "pass");
    }
    return 0;
} }
