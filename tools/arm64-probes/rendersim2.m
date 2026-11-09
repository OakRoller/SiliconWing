// rendersim2.m: wider render coverage on the NVMTLDevice: depth test, indexed + instanced draw, mipmaps via blit,
// BGRA8 sRGB target, two colour attachments (MRT), alpha blending, scissor, a 4x MSAA pass with resolve.
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
static int fails = 0;
typedef struct { float off[2]; float z; float pad; float col[4]; } Inst;
#define CHECK(cond, ...) do { if (cond) printf("PASS: " __VA_ARGS__); else { fails++; printf("FAIL: " __VA_ARGS__); } printf("\n"); } while (0)
static id<MTLDevice> pickDevice(void) { for (id<MTLDevice> x in MTLCopyAllDevices()) if ([NSStringFromClass([x class]) isEqualToString:@"NVMTLDevice"]) return x; return nil; }
static NSData *readback(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLTexture> t, NSUInteger level) {
    NSUInteger w = MAX(1, t.width >> level), h = MAX(1, t.height >> level), bpp = (t.pixelFormat == MTLPixelFormatDepth32Float) ? 4 : 4;
    NSUInteger bpr = w * bpp, len = bpr * h;
    id<MTLBuffer> buf = [d newBufferWithLength:len options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:t sourceSlice:0 sourceLevel:level sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:buf destinationOffset:0 destinationBytesPerRow:bpr destinationBytesPerImage:len];
    [blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) { printf("  (readback status %ld %s)\n", (long)cb.status, cb.error ? cb.error.localizedDescription.UTF8String : ""); return nil; }
    return [NSData dataWithBytes:buf.contents length:len];
}
static uint32_t px(NSData *img, NSUInteger w, NSUInteger x, NSUInteger y) { return ((const uint32_t *)img.bytes)[y * w + x]; }
static id<MTLTexture> mkTarget(id<MTLDevice> d, MTLPixelFormat f, NSUInteger w, NSUInteger h, NSUInteger samples) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModePrivate;
    if (samples > 1) { td.textureType = MTLTextureType2DMultisample; td.sampleCount = samples; td.usage = MTLTextureUsageRenderTarget; }
    return [d newTextureWithDescriptor:td];
}
int main(void) { @autoreleasepool {
    id<MTLDevice> d = pickDevice(); if (!d) { printf("no NVMTLDevice\n"); return 99; }
    printf("device: %s\n", d.name.UTF8String);
    id<MTLCommandQueue> q = [d newCommandQueue]; NSError *err = nil;
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct V { float4 pos [[position]]; float4 col; };\n"
        "struct Inst { float2 off; float z; float pad; float4 col; };\n"
        "vertex V vtx(uint vid [[vertex_id]], uint iid [[instance_id]], const device float2 *pts [[buffer(0)]], const device Inst *inst [[buffer(1)]]) {\n"
        "  V o; o.pos = float4(pts[vid] * 0.5 + inst[iid].off, inst[iid].z, 1); o.col = inst[iid].col; return o; }\n"
        "fragment float4 frag(V in [[stage_in]]) { return in.col; }\n"
        "struct MRT { float4 a [[color(0)]]; float4 b [[color(1)]]; };\n"
        "fragment MRT frag_mrt(V in [[stage_in]]) { MRT o; o.a = in.col; o.b = float4(1 - in.col.rgb, 1); return o; }\n";
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
    CHECK(lib != nil, "compile shaders%s", err ? err.localizedDescription.UTF8String : "");
    if (!lib) return fails;
    // geometry: a quad (indexed) drawn twice by instancing, the second instance nearer (smaller z) and overlapping
    float quad[8] = { -1,-1, 1,-1, 1,1, -1,1 }; uint16_t idx[6] = { 0,1,2, 0,2,3 };
    Inst inst[2] = { { {-0.25f, 0}, 0.8f, 0, {1,0,0,1} }, { {0.25f, 0}, 0.2f, 0, {0,0,1,1} } };
    id<MTLBuffer> vb = [d newBufferWithBytes:quad length:sizeof quad options:MTLResourceStorageModeShared];
    id<MTLBuffer> ib = [d newBufferWithBytes:idx length:sizeof idx options:MTLResourceStorageModeShared];
    id<MTLBuffer> instb = [d newBufferWithBytes:inst length:sizeof inst options:MTLResourceStorageModeShared];
    const NSUInteger W = 128, H = 128;

    // 1. depth test + indexed instanced draw: red quad far (drawn second but behind), blue near
    {
        id<MTLTexture> rt = mkTarget(d, MTLPixelFormatRGBA8Unorm, W, H, 1);
        MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:W height:H mipmapped:NO];
        dd.usage = MTLTextureUsageRenderTarget; dd.storageMode = MTLStorageModePrivate;
        id<MTLTexture> depth = [d newTextureWithDescriptor:dd];
        CHECK(depth != nil, "Depth32Float texture");
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vtx"]; pd.fragmentFunction = [lib newFunctionWithName:@"frag"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm; pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        id<MTLRenderPipelineState> pso = [d newRenderPipelineStateWithDescriptor:pd error:&err];
        CHECK(pso != nil, "pipeline with depth attachment%s", err ? err.localizedDescription.UTF8String : "");
        MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new]; dsd.depthCompareFunction = MTLCompareFunctionLess; dsd.depthWriteEnabled = YES;
        id<MTLDepthStencilState> dss = [d newDepthStencilStateWithDescriptor:dsd];
        // instance order reversed so the far red quad is drawn AFTER the near blue one; depth must keep blue in the overlap
        Inst inst2[2] = { inst[1], inst[0] };
        id<MTLBuffer> instb2 = [d newBufferWithBytes:inst2 length:sizeof inst2 options:MTLResourceStorageModeShared];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1);
        rp.depthAttachment.texture = depth; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.clearDepth = 1.0; rp.depthAttachment.storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:pso]; [enc setDepthStencilState:dss]; [enc setVertexBuffer:vb offset:0 atIndex:0]; [enc setVertexBuffer:instb2 offset:0 atIndex:1];
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0 instanceCount:2];
        [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
        CHECK(cb.status == MTLCommandBufferStatusCompleted, "depth/indexed/instanced command buffer status %ld", (long)cb.status);
        NSData *img = readback(d, q, rt, 0);
        if (img) {
            uint32_t left = px(img, W, 20, 64), overlap = px(img, W, 64, 64), right = px(img, W, 108, 64), bg = px(img, W, 2, 2);
            printf("  left 0x%08x (red) overlap 0x%08x (blue wins by depth) right 0x%08x (blue) bg 0x%08x (black)\n", left, overlap, right, bg);
            CHECK(left == 0xFF0000FFu && overlap == 0xFFFF0000u && right == 0xFFFF0000u && bg == 0xFF000000u, "depth test keeps the nearer instance");
            NSData *dimg = readback(d, q, depth, 0);
            if (dimg) { const float *z = dimg.bytes; printf("  depth at overlap %g (want 0.2) at bg %g (want 1)\n", z[64 * W + 64], z[2 * W + 2]); CHECK(fabsf(z[64*W+64] - 0.2f) < 1e-3 && z[2*W+2] == 1.0f, "depth buffer readback"); }
            else CHECK(NO, "depth buffer readback (blit from Depth32Float)");
        } else CHECK(NO, "readback");
    }
    // 2. mipmaps: 64x64 checker, generateMipmaps, level 6 (1x1) must be the average
    {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:YES];
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite; td.storageMode = MTLStorageModeManaged;   // ShaderWrite: generateMipmaps may need it on some drivers
        id<MTLTexture> t = [d newTextureWithDescriptor:td];
        CHECK(t != nil && t.mipmapLevelCount == 7, "mipmapped 64x64 texture has %lu levels", (unsigned long)(t ? t.mipmapLevelCount : 0));
        uint32_t *p = malloc(64 * 64 * 4); for (int i = 0; i < 64 * 64; i++) p[i] = ((i & 1) ^ ((i >> 6) & 1)) ? 0xFFFFFFFFu : 0xFF000000u;
        [t replaceRegion:MTLRegionMake2D(0,0,64,64) mipmapLevel:0 withBytes:p bytesPerRow:256];
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder]; [blit generateMipmapsForTexture:t]; [blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
        CHECK(cb.status == MTLCommandBufferStatusCompleted, "generateMipmaps status %ld", (long)cb.status);
        NSData *l1 = readback(d, q, t, 1), *l6 = readback(d, q, t, 6);
        if (l1 && l6) { uint32_t a = px(l1, 32, 5, 7), b = px(l6, 1, 0, 0); printf("  level1 texel 0x%08x level6 texel 0x%08x (want grey ~0xFF7F7F7F/0xFF808080)\n", a, b);
            CHECK(((a & 0xFF) >= 0x7E && (a & 0xFF) <= 0x81) && ((b & 0xFF) >= 0x7E && (b & 0xFF) <= 0x81), "mip levels average the checkerboard"); }
        else CHECK(NO, "mip level readback");
    }
    // 3. BGRA8 sRGB target + alpha blending + scissor
    {
        id<MTLTexture> rt = mkTarget(d, MTLPixelFormatBGRA8Unorm_sRGB, W, H, 1);
        CHECK(rt != nil, "BGRA8Unorm_sRGB render target");
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vtx"]; pd.fragmentFunction = [lib newFunctionWithName:@"frag"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
        pd.colorAttachments[0].blendingEnabled = YES; pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha; pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        id<MTLRenderPipelineState> pso = [d newRenderPipelineStateWithDescriptor:pd error:&err];
        CHECK(pso != nil, "blending pipeline on sRGB target%s", err ? err.localizedDescription.UTF8String : "");
        Inst inst3[1] = { { {0, 0}, 0.5f, 0, {1, 1, 1, 0.5f} } };   // half-transparent white over black
        id<MTLBuffer> instb3 = [d newBufferWithBytes:inst3 length:sizeof inst3 options:MTLResourceStorageModeShared];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1);
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:pso]; [enc setVertexBuffer:vb offset:0 atIndex:0]; [enc setVertexBuffer:instb3 offset:0 atIndex:1];
        [enc setScissorRect:(MTLScissorRect){0, 0, W / 2, H}];
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0];
        [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
        CHECK(cb.status == MTLCommandBufferStatusCompleted, "blend/scissor command buffer status %ld", (long)cb.status);
        NSData *img = readback(d, q, rt, 0);
        if (img) { uint32_t in = px(img, W, 40, 64), out = px(img, W, 100, 64);
            // linear 0.5 encodes to sRGB ~0xBC; BGRA byte order means the raw word is A B G R little-endian = 0xFFBCBCBC either way
            printf("  inside scissor 0x%08x (want ~0xFFBCBCBC: 50%% white blended, sRGB-encoded) outside 0x%08x (want 0xFF000000)\n", in, out);
            CHECK((in & 0xFF) >= 0xB9 && (in & 0xFF) <= 0xBF && out == 0xFF000000u, "sRGB encode + alpha blend + scissor"); }
        else CHECK(NO, "readback");
    }
    // 4. MRT: two colour attachments
    {
        id<MTLTexture> a = mkTarget(d, MTLPixelFormatRGBA8Unorm, W, H, 1), b = mkTarget(d, MTLPixelFormatRGBA8Unorm, W, H, 1);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vtx"]; pd.fragmentFunction = [lib newFunctionWithName:@"frag_mrt"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm; pd.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> pso = [d newRenderPipelineStateWithDescriptor:pd error:&err];
        CHECK(pso != nil, "MRT pipeline%s", err ? err.localizedDescription.UTF8String : "");
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        for (int i = 0; i < 2; i++) { rp.colorAttachments[i].texture = i ? b : a; rp.colorAttachments[i].loadAction = MTLLoadActionClear; rp.colorAttachments[i].storeAction = MTLStoreActionStore; rp.colorAttachments[i].clearColor = MTLClearColorMake(0,0,0,1); }
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:pso]; [enc setVertexBuffer:vb offset:0 atIndex:0]; [enc setVertexBuffer:instb offset:0 atIndex:1];
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0 instanceCount:1];
        [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
        CHECK(cb.status == MTLCommandBufferStatusCompleted, "MRT command buffer status %ld", (long)cb.status);
        NSData *ia = readback(d, q, a, 0), *ib2 = readback(d, q, b, 0);
        if (ia && ib2) { uint32_t pa = px(ia, W, 40, 64), pb = px(ib2, W, 40, 64); printf("  attachment0 0x%08x (red) attachment1 0x%08x (cyan 0xFFFFFF00)\n", pa, pb); CHECK(pa == 0xFF0000FFu && pb == 0xFFFFFF00u, "both MRT attachments written"); }
        else CHECK(NO, "MRT readback");
    }
    // 5. 4x MSAA + resolve
    {
        id<MTLTexture> ms = mkTarget(d, MTLPixelFormatRGBA8Unorm, W, H, 4), res = mkTarget(d, MTLPixelFormatRGBA8Unorm, W, H, 1);
        CHECK(ms != nil, "4x multisample texture");
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vtx"]; pd.fragmentFunction = [lib newFunctionWithName:@"frag"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm; pd.rasterSampleCount = 4;
        id<MTLRenderPipelineState> pso = [d newRenderPipelineStateWithDescriptor:pd error:&err];
        CHECK(pso != nil, "MSAA pipeline%s", err ? err.localizedDescription.UTF8String : "");
        if (ms && pso) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = ms; rp.colorAttachments[0].resolveTexture = res; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve; rp.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1);
            id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
            [enc setRenderPipelineState:pso]; [enc setVertexBuffer:vb offset:0 atIndex:0]; [enc setVertexBuffer:instb offset:0 atIndex:1];
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0 instanceCount:2];
            [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
            CHECK(cb.status == MTLCommandBufferStatusCompleted, "MSAA command buffer status %ld", (long)cb.status);
            NSData *img = readback(d, q, res, 0);
            if (img) { uint32_t inside = px(img, W, 20, 64), edge = px(img, W, 16, 64); printf("  inside 0x%08x (red) edge x=16 0x%08x (partial coverage: red blended with black, or red/black)\n", inside, edge); CHECK(inside == 0xFF0000FFu, "MSAA resolve"); }
            else CHECK(NO, "resolve readback");
        }
    }
    printf("%d failure(s)\n", fails); return fails;
} }
