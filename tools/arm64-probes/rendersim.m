// rendersim.m: textures and render passes on the NVMTLDevice, each step checked on the CPU.
//   1. texture upload (replaceRegion) and readback through a blit to a shared buffer
//   2. a compute kernel sampling that texture
//   3. a render pass: clear + one triangle into a render-target texture, read back, check pixels
//   4. a render pass drawing a textured quad with a sampler
// Each step prints PASS/FAIL and the program keeps going so one failure does not hide the rest. Exit = number of failures.
//   xcrun clang -fobjc-arc -framework Metal -framework Foundation rendersim.m -o rendersim && ./rendersim
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

static int fails = 0;
#define CHECK(cond, ...) do { if (cond) printf("PASS: " __VA_ARGS__); else { fails++; printf("FAIL: " __VA_ARGS__); } printf("\n"); } while (0)

static id<MTLDevice> pickDevice(void) {
    for (id<MTLDevice> x in MTLCopyAllDevices()) if ([NSStringFromClass([x class]) isEqualToString:@"NVMTLDevice"]) return x;
    return nil;
}
static NSData *readback(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLTexture> t) {
    NSUInteger bpr = t.width * 4, len = bpr * t.height;
    id<MTLBuffer> buf = [d newBufferWithLength:len options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(t.width, t.height, 1)
               toBuffer:buf destinationOffset:0 destinationBytesPerRow:bpr destinationBytesPerImage:len];
    [blit endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) { printf("  (readback command buffer status %ld%s%s)\n", (long)cb.status, cb.error ? ": " : "", cb.error ? cb.error.localizedDescription.UTF8String : ""); return nil; }
    return [NSData dataWithBytes:buf.contents length:len];
}
static uint32_t px(NSData *img, NSUInteger w, NSUInteger x, NSUInteger y) { return ((const uint32_t *)img.bytes)[y * w + x]; }

int main(void) {
    @autoreleasepool {
        id<MTLDevice> d = pickDevice();
        if (!d) { printf("no NVMTLDevice\n"); return 99; }
        printf("device: %s\n", d.name.UTF8String);
        id<MTLCommandQueue> q = [d newCommandQueue];
        NSError *err = nil;

        // 1. texture upload + readback
        const NSUInteger W = 64, H = 64;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:H mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> tex = [d newTextureWithDescriptor:td];
        CHECK(tex != nil, "newTextureWithDescriptor 64x64 RGBA8 managed -> %p", tex);
        uint32_t *src = malloc(W * H * 4);
        for (NSUInteger y = 0; y < H; y++) for (NSUInteger x = 0; x < W; x++) src[y * W + x] = 0xFF000000u | ((uint32_t)(y * 4) << 8) | (uint32_t)(x * 4);   // R = 4x, G = 4y, A = 255
        if (tex) {
            [tex replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:src bytesPerRow:W * 4];
            NSData *img = readback(d, q, tex);
            NvOk: ;
            BOOL ok = img && memcmp(img.bytes, src, W * H * 4) == 0;
            if (img && !ok) { NSUInteger i = 0; const uint32_t *p = img.bytes; while (i < W * H && p[i] == src[i]) i++; printf("  first mismatch at %lu: got 0x%08x want 0x%08x\n", (unsigned long)i, i < W*H ? p[i] : 0, i < W*H ? src[i] : 0); }
            CHECK(ok, "replaceRegion upload + blit readback round-trips 64x64");
        }

        // 2. compute kernel sampling the texture
        NSString *csrc = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void samp(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], device float4 *out [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {\n"
            "  float2 uv = (float2(gid) + 0.5) / 64.0; out[gid.y * 64 + gid.x] = t.sample(s, uv); }\n";
        id<MTLLibrary> clib = [d newLibraryWithSource:csrc options:nil error:&err];
        CHECK(clib != nil, "compile texture-sampling compute kernel%s%s", err ? ": " : "", err ? err.localizedDescription.UTF8String : "");
        if (clib && tex) {
            id<MTLComputePipelineState> pso = [d newComputePipelineStateWithFunction:[clib newFunctionWithName:@"samp"] error:&err];
            CHECK(pso != nil, "compute pipeline with texture argument%s%s", err ? ": " : "", err ? err.localizedDescription.UTF8String : "");
            if (pso) {
                MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = MTLSamplerMinMagFilterNearest; sd.magFilter = MTLSamplerMinMagFilterNearest;
                id<MTLSamplerState> ss = [d newSamplerStateWithDescriptor:sd];
                id<MTLBuffer> out = [d newBufferWithLength:W * H * 16 options:MTLResourceStorageModeShared];
                id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                [enc setComputePipelineState:pso]; [enc setTexture:tex atIndex:0]; [enc setSamplerState:ss atIndex:0]; [enc setBuffer:out offset:0 atIndex:0];
                [enc dispatchThreads:MTLSizeMake(W, H, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
                [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
                const float *o = out.contents; NSUInteger bad = 0;
                for (NSUInteger y = 0; y < H; y++) for (NSUInteger x = 0; x < W; x++) {
                    const float *v = o + (y * W + x) * 4;
                    if (fabsf(v[0] - (x * 4) / 255.0f) > 0.01f || fabsf(v[1] - (y * 4) / 255.0f) > 0.01f || fabsf(v[2]) > 0.01f || fabsf(v[3] - 1.0f) > 0.01f) bad++;
                }
                if (bad) printf("  texel (1,2) sampled as %g %g %g %g, want %g %g 0 1\n", o[(2*W+1)*4], o[(2*W+1)*4+1], o[(2*W+1)*4+2], o[(2*W+1)*4+3], 4/255.0, 8/255.0);
                CHECK(cb.status == MTLCommandBufferStatusCompleted && bad == 0, "compute sample of every texel (%lu wrong, status %ld)", (unsigned long)bad, (long)cb.status);
            }
        }

        // 3. render pass: clear red, draw a green triangle
        const NSUInteger RW = 256, RH = 256;
        MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:RW height:RH mipmapped:NO];
        rd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; rd.storageMode = MTLStorageModePrivate;
        id<MTLTexture> rt = [d newTextureWithDescriptor:rd];
        CHECK(rt != nil, "render-target texture 256x256 private -> %p", rt);
        NSString *rsrc = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct VOut { float4 pos [[position]]; float2 uv; };\n"
            "vertex VOut vtx(uint vid [[vertex_id]], const device float2 *pts [[buffer(0)]]) { VOut o; o.pos = float4(pts[vid], 0, 1); o.uv = pts[vid] * 0.5 + 0.5; return o; }\n"
            "fragment float4 frag_green(VOut in [[stage_in]]) { return float4(0, 1, 0, 1); }\n"
            "fragment float4 frag_tex(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return t.sample(s, in.uv); }\n";
        id<MTLLibrary> rlib = [d newLibraryWithSource:rsrc options:nil error:&err];
        CHECK(rlib != nil, "compile vertex + fragment shaders%s%s", err ? ": " : "", err ? err.localizedDescription.UTF8String : "");
        id<MTLRenderPipelineState> psoGreen = nil, psoTex = nil;
        if (rlib) {
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
            pd.vertexFunction = [rlib newFunctionWithName:@"vtx"]; pd.fragmentFunction = [rlib newFunctionWithName:@"frag_green"];
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
            psoGreen = [d newRenderPipelineStateWithDescriptor:pd error:&err];
            CHECK(psoGreen != nil, "render pipeline (green)%s%s", err ? ": " : "", err ? err.localizedDescription.UTF8String : "");
            pd.fragmentFunction = [rlib newFunctionWithName:@"frag_tex"];
            psoTex = [d newRenderPipelineStateWithDescriptor:pd error:&err];
            CHECK(psoTex != nil, "render pipeline (textured)%s%s", err ? ": " : "", err ? err.localizedDescription.UTF8String : "");
        }
        if (rt && psoGreen) {
            float tri[6] = { -0.8f, -0.8f,  0.8f, -0.8f,  0.0f, 0.8f };
            id<MTLBuffer> vb = [d newBufferWithBytes:tri length:sizeof tri options:MTLResourceStorageModeShared];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1);
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
            CHECK(enc != nil, "render command encoder -> %p", enc);
            if (enc) {
                [enc setRenderPipelineState:psoGreen]; [enc setVertexBuffer:vb offset:0 atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [enc endEncoding];
            }
            [cb commit]; [cb waitUntilCompleted];
            CHECK(cb.status == MTLCommandBufferStatusCompleted, "triangle command buffer status %ld%s%s", (long)cb.status, cb.error ? ": " : "", cb.error ? cb.error.localizedDescription.UTF8String : "");
            NSData *img = readback(d, q, rt);
            if (img) {
                uint32_t corner = px(img, RW, 2, 2), center = px(img, RW, RW / 2, RH / 2), top = px(img, RW, RW / 2, 2);
                printf("  corner 0x%08x (want 0xFF0000FF red) center 0x%08x (want 0xFF00FF00 green) top-middle 0x%08x (want red: the apex is at y=0.8)\n", corner, center, top);
                CHECK(corner == 0xFF0000FFu && center == 0xFF00FF00u, "clear + green triangle pixels");
            } else CHECK(NO, "readback of the render target");
        }

        // 4. textured quad
        if (rt && psoTex && tex) {
            float quad[12] = { -1,-1, 1,-1, -1,1,  1,-1, 1,1, -1,1 };
            id<MTLBuffer> vb = [d newBufferWithBytes:quad length:sizeof quad options:MTLResourceStorageModeShared];
            MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = MTLSamplerMinMagFilterNearest; sd.magFilter = MTLSamplerMinMagFilterNearest;
            id<MTLSamplerState> ss = [d newSamplerStateWithDescriptor:sd];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 1);
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
            [enc setRenderPipelineState:psoTex]; [enc setVertexBuffer:vb offset:0 atIndex:0];
            [enc setFragmentTexture:tex atIndex:0]; [enc setFragmentSamplerState:ss atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
            CHECK(cb.status == MTLCommandBufferStatusCompleted, "textured quad command buffer status %ld", (long)cb.status);
            NSData *img = readback(d, q, rt);
            if (img) {
                // pixel (x, y) of the 256 target samples texel (x/4, y/4) when uv maps the full quad; expect R = 4*(x/4) = x & ~3, G = y & ~3 (up to the texture's row orientation)
                uint32_t p = px(img, RW, 100, 40), p2 = px(img, RW, 200, 200);
                printf("  pixel (100,40) 0x%08x  pixel (200,200) 0x%08x  (want R=x&~3, G=y&~3 or flipped in y, A=255, B=0)\n", p, p2);
                BOOL ok1 = (p & 0xFF) == 100 && (p >> 24) == 0xFF && ((p >> 16) & 0xFF) == 0;
                BOOL ok2 = (p2 & 0xFF) == 200 && (p2 >> 24) == 0xFF && ((p2 >> 16) & 0xFF) == 0;
                CHECK(ok1 && ok2, "textured quad samples the uploaded texture (G channel orientation not checked)");
            } else CHECK(NO, "readback of the textured quad");
        }
        printf("%d failure(s)\n", fails);
        return fails;
    }
}
