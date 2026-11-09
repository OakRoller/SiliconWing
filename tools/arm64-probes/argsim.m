// argsim.m: bindless / argument-buffer paths on the NVMTLDevice, checked on the CPU.
//   A. MTLArgumentEncoder: texture [[id(0)]] + sampler [[id(1)]] in an argument buffer, sampled by a fragment shader.
//   B. Metal 3 resource IDs: the app writes texture.gpuResourceID and sampler.gpuResourceID into a plain buffer
//      (struct of MTLResourceID), the shader declares `texture2d<float> t; sampler s;` in a device struct.
//   C. Same as B from a compute kernel, plus a texture_buffer read and a storage texture write through resource IDs.
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
static int fails = 0;
#define CHECK(cond, ...) do { if (cond) printf("PASS: " __VA_ARGS__); else { fails++; printf("FAIL: " __VA_ARGS__); } printf("\n"); } while (0)
static id<MTLDevice> pick(void) { for (id<MTLDevice> x in MTLCopyAllDevices()) if ([NSStringFromClass([x class]) isEqualToString:@"NVMTLDevice"]) return x; return nil; }
static NSData *readback(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLTexture> t) {
    NSUInteger bpr = t.width * 4, len = bpr * t.height; id<MTLBuffer> buf = [d newBufferWithLength:len options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(t.width,t.height,1) toBuffer:buf destinationOffset:0 destinationBytesPerRow:bpr destinationBytesPerImage:len];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; return [NSData dataWithBytes:buf.contents length:len]; }
static uint32_t px(NSData *i, NSUInteger w, NSUInteger x, NSUInteger y) { return ((const uint32_t *)i.bytes)[y * w + x]; }
int main(void) { @autoreleasepool {
    id<MTLDevice> d = pick(); if (!d) { printf("no NVMTLDevice\n"); return 99; }
    printf("device: %s  argumentBuffersSupport %ld\n", d.name.UTF8String, (long)d.argumentBuffersSupport);
    id<MTLCommandQueue> q = [d newCommandQueue]; NSError *err = nil;
    // source texture: R = 4x, G = 4y
    const NSUInteger W = 64, H = 64;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeManaged;
    id<MTLTexture> tex = [d newTextureWithDescriptor:td];
    uint32_t *src = malloc(W*H*4); for (NSUInteger y = 0; y < H; y++) for (NSUInteger x = 0; x < W; x++) src[y*W+x] = 0xFF000000u | ((uint32_t)(y*4) << 8) | (uint32_t)(x*4);
    [tex replaceRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0 withBytes:src bytesPerRow:W*4];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest; sd.supportArgumentBuffers = YES;
    id<MTLSamplerState> smp = [d newSamplerStateWithDescriptor:sd];
    NSString *src_ = @"#include <metal_stdlib>\nusing namespace metal;\n"
      "struct V { float4 pos [[position]]; float2 uv; };\n"
      "vertex V vtx(uint vid [[vertex_id]]) { float2 p = float2((vid << 1) & 2, vid & 2); V o; o.pos = float4(p * 2 - 1, 0, 1); o.uv = p; return o; }\n"
      "struct Args { texture2d<float> t [[id(0)]]; sampler s [[id(1)]]; };\n"
      "fragment float4 frag_ab(V in [[stage_in]], constant Args &a [[buffer(0)]]) { return a.t.sample(a.s, in.uv); }\n"
      "struct Res { texture2d<float> t; sampler s; };\n"
      "fragment float4 frag_rid(V in [[stage_in]], device const Res *r [[buffer(0)]]) { return r->t.sample(r->s, in.uv); }\n"
      "struct CRes { texture2d<float> t; sampler s; texture_buffer<float> tb; texture2d<float, access::write> out; };\n"
      "kernel void k_rid(device const CRes *r [[buffer(0)]], device float4 *o [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {\n"
      "  float4 c = r->t.sample(r->s, (float2(g) + 0.5) / 64.0); o[g.y * 64 + g.x] = c + float4(r->tb.read(g.x).x, 0, 0, 0); r->out.write(c, g); }\n";
    id<MTLLibrary> lib = [d newLibraryWithSource:src_ options:nil error:&err];
    CHECK(lib != nil, "compile%s", err ? err.localizedDescription.UTF8String : "");
    if (!lib) return fails;
    MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:256 height:256 mipmapped:NO];
    rd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; rd.storageMode = MTLStorageModePrivate;
    id<MTLTexture> rt = [d newTextureWithDescriptor:rd];
    // A. argument encoder
    {
        id<MTLFunction> f = [lib newFunctionWithName:@"frag_ab"];
        id<MTLArgumentEncoder> enc = [f newArgumentEncoderWithBufferIndex:0];
        id<MTLBuffer> ab = [d newBufferWithLength:enc.encodedLength options:MTLResourceStorageModeShared];
        [enc setArgumentBuffer:ab offset:0]; [enc setTexture:tex atIndex:0]; [enc setSamplerState:smp atIndex:1];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vtx"]; pd.fragmentFunction = f; pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> pso = [d newRenderPipelineStateWithDescriptor:pd error:&err];
        CHECK(pso != nil, "A: pipeline with argument buffer%s", err ? err.localizedDescription.UTF8String : "");
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(0,0,1,1);
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:pso]; [e setFragmentBuffer:ab offset:0 atIndex:0]; [e useResource:tex usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
        NSData *img = readback(d, q, rt); uint32_t p = px(img, 256, 100, 40), p2 = px(img, 256, 200, 200);
        printf("  A: (100,40) 0x%08x (200,200) 0x%08x  want R=x&~3, A=255, B=0\n", p, p2);
        CHECK((p & 0xFF) == 100 && (p >> 24) == 0xFF && ((p >> 16) & 0xFF) == 0 && (p2 & 0xFF) == 200, "A: argument-encoder texture sampled");
    }
    // B. resource IDs written by the app
    {
        struct { MTLResourceID t, s; } res = { tex.gpuResourceID, smp.gpuResourceID };
        printf("  B: texture gpuResourceID 0x%llx sampler 0x%llx\n", (unsigned long long)res.t._impl, (unsigned long long)res.s._impl);
        id<MTLBuffer> rb = [d newBufferWithBytes:&res length:sizeof res options:MTLResourceStorageModeShared];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vtx"]; pd.fragmentFunction = [lib newFunctionWithName:@"frag_rid"]; pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> pso = [d newRenderPipelineStateWithDescriptor:pd error:&err];
        CHECK(pso != nil, "B: pipeline reading resource IDs%s", err ? err.localizedDescription.UTF8String : "");
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(0,0,1,1);
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:pso]; [e setFragmentBuffer:rb offset:0 atIndex:0]; [e useResource:tex usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
        NSData *img = readback(d, q, rt); uint32_t p = px(img, 256, 100, 40), p2 = px(img, 256, 200, 200);
        printf("  B: (100,40) 0x%08x (200,200) 0x%08x\n", p, p2);
        CHECK((p & 0xFF) == 100 && (p >> 24) == 0xFF && ((p >> 16) & 0xFF) == 0 && (p2 & 0xFF) == 200, "B: gpuResourceID texture sampled in a fragment shader");
    }
    // C. compute with resource IDs, texture buffer and storage texture
    {
        MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO]; od.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead; od.storageMode = MTLStorageModePrivate;
        id<MTLTexture> out = [d newTextureWithDescriptor:od];
        float tbdata[64]; for (int i = 0; i < 64; i++) tbdata[i] = i * 0.01f;
        id<MTLBuffer> tbb = [d newBufferWithBytes:tbdata length:sizeof tbdata options:MTLResourceStorageModeShared];
        MTLTextureDescriptor *tbd = [MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:MTLPixelFormatR32Float width:64 resourceOptions:MTLResourceStorageModeShared usage:MTLTextureUsageShaderRead];
        id<MTLTexture> tb = [tbb newTextureWithDescriptor:tbd offset:0 bytesPerRow:256];
        CHECK(tb != nil, "C: texture buffer created");
        struct { MTLResourceID t, s, tb, out; } res = { tex.gpuResourceID, smp.gpuResourceID, tb ? tb.gpuResourceID : (MTLResourceID){0}, out.gpuResourceID }; printf("  C: tb gpuResourceID 0x%llx out 0x%llx\n", (unsigned long long)res.tb._impl, (unsigned long long)res.out._impl);
        id<MTLBuffer> rb = [d newBufferWithBytes:&res length:sizeof res options:MTLResourceStorageModeShared];
        id<MTLBuffer> ob = [d newBufferWithLength:64*64*16 options:MTLResourceStorageModeShared];
        id<MTLComputePipelineState> pso = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k_rid"] error:&err];
        CHECK(pso != nil, "C: compute pipeline with resource IDs, texture buffer, storage texture%s", err ? err.localizedDescription.UTF8String : "");
        if (pso) {
            id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            [e setComputePipelineState:pso]; [e setBuffer:rb offset:0 atIndex:0]; [e setBuffer:ob offset:0 atIndex:1];
            [e useResource:tex usage:MTLResourceUsageRead]; if (tb) [e useResource:tb usage:MTLResourceUsageRead]; [e useResource:out usage:MTLResourceUsageWrite];
            [e dispatchThreads:MTLSizeMake(64,64,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
            const float *o = ob.contents; NSUInteger bad = 0;
            for (NSUInteger y = 0; y < 64; y++) for (NSUInteger x = 0; x < 64; x++) { const float *v = o + (y*64+x)*4; float wantR = (x*4)/255.0f + x*0.01f, wantG = (y*4)/255.0f; if (fabsf(v[0]-wantR) > 0.02f || fabsf(v[1]-wantG) > 0.01f || fabsf(v[3]-1) > 0.01f) bad++; }
            printf("  C: texel (1,2) -> %g %g %g %g (want %g %g 0 1)\n", o[(2*64+1)*4], o[(2*64+1)*4+1], o[(2*64+1)*4+2], o[(2*64+1)*4+3], 4/255.0+0.01, 8/255.0);
            CHECK(cb.status == MTLCommandBufferStatusCompleted && bad == 0, "C: compute sampled the texture and read the texture buffer through resource IDs (%lu wrong)", (unsigned long)bad);
            NSData *img = readback(d, q, out); uint32_t p = px(img, 64, 1, 2);
            printf("  C: storage texture (1,2) 0x%08x (want 0xFF000804)\n", p);
            CHECK(p == 0xFF000804u, "C: storage texture written through a resource ID");
        }
    }
    printf("%d failure(s)\n", fails); return fails; } }
