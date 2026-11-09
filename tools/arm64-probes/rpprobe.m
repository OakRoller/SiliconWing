// rpprobe.m: what one small render pass with one draw costs on a Metal device, timed with the command buffer's GPU times.
//   rpprobe nvidia|apple [width height]
// 500 render passes on a WxH (default 20x38) RGBA8 sRGB target, one full-screen triangle each, in one command buffer:
//   1. the fragment shader writes a constant
//   2. it adds a value read from a Shared buffer (setFragmentBuffer)
//   3. it also samples a 256x256 texture
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
    const NSUInteger W = argc > 3 ? (NSUInteger)atoi(argv[2]) : 20, H = argc > 3 ? (NSUInteger)atoi(argv[3]) : 38;
    id<MTLDevice> d = pick(which); if (!d) { printf("no %s device\n", which); return 2; }
    printf("device: %s, %lux%lu target\n", d.name.UTF8String, (unsigned long)W, (unsigned long)H);
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; float2 uv; };\n"
    "vertex V vs(uint i [[vertex_id]]) { V o; float2 q = float2((i << 1) & 2, i & 2); o.p = float4(q * 2 - 1, 0, 1); o.uv = q; return o; }\n"
    "fragment float4 fs_const(V v [[stage_in]]) { return float4(v.uv, 0.5, 1); }\n"
    "fragment float4 fs_buf(V v [[stage_in]], constant float4 &c [[buffer(0)]]) { return float4(v.uv, 0.5, 1) + c; }\n"
    "fragment float4 fs_tex(V v [[stage_in]], constant float4 &c [[buffer(0)]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return t.sample(s, v.uv) + c; }\n";
    NSError *err = nil;
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
    if (!lib) { printf("compile: %s\n", err.localizedDescription.UTF8String); return 1; }
    const char *names[3] = { "fs_const", "fs_buf", "fs_tex" };
    id<MTLRenderPipelineState> ps[3];
    for (int k = 0; k < 3; k++) {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"];
        pd.fragmentFunction = [lib newFunctionWithName:[NSString stringWithUTF8String:names[k]]];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm_sRGB;
        ps[k] = [d newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!ps[k]) { printf("pipeline %s: %s\n", names[k], err.localizedDescription.UTF8String); return 1; }
    }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> rt = [d newTextureWithDescriptor:td];
    MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:256 height:256 mipmapped:NO];
    sd.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [d newTextureWithDescriptor:sd];
    { uint32_t *px = malloc(256 * 256 * 4); for (int i = 0; i < 256 * 256; i++) px[i] = 0xff000000u | (uint32_t)i;
      [tex replaceRegion:MTLRegionMake2D(0, 0, 256, 256) mipmapLevel:0 withBytes:px bytesPerRow:1024]; free(px); }
    id<MTLSamplerState> smp = [d newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
    id<MTLBuffer> cb4 = [d newBufferWithLength:256 options:MTLResourceStorageModeShared];
    ((float *)cb4.contents)[0] = 0.25f;
    id<MTLCommandQueue> q = [d newCommandQueue];
    const int N = 500;
    for (int pass = 0; pass < 3; pass++) {
        for (int k = 0; k < 3; k++) {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            for (int i = 0; i < N; i++) {
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
                id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
                [e setRenderPipelineState:ps[k]];
                if (k >= 1) [e setFragmentBuffer:cb4 offset:0 atIndex:0];
                if (k == 2) { [e setFragmentTexture:tex atIndex:0]; [e setFragmentSamplerState:smp atIndex:0]; }
                [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [e endEncoding];
            }
            [cb commit]; [cb waitUntilCompleted];
            printf("pass %d: %-8s %.1f us per render pass\n", pass, names[k], (cb.GPUEndTime - cb.GPUStartTime) * 1e6 / N);
        }
    }
    return 0;
} }
