// abprobe.m: SPIRV-Cross style argument buffer access, as 3DMark Steel Nomad's shaders do it: a constant buffer pointer in
// an argument buffer, offset by spvDynamicOffsets[0] (buffer 19), and a gather from a Depth32Float texture through an
// argument-buffer sampler. One fragment draws to a 1x1 RGBA32Float target; the host prints what the shader read.
//   abprobe            default device (the NVIDIA one under cp-run.sh's environment, the Apple GPU without it)
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) { @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    printf("device: %s\n", d.name.UTF8String);
    NSString *src0 = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct C { float2 a; float2 b; float2 unpack; float2 pad; };\n"
    "struct Set0 { constant C *g [[id(0)]]; sampler s [[id(1)]]; depth2d<float> t [[id(2)]]; texture2d<float> rt [[id(3)]]; };\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint i [[vertex_id]]) { V o; float2 q = float2((i << 1) & 2, i & 2); o.p = float4(q * 2 - 1, 0, 1); return o; }\n"
    "fragment float4 fs(constant Set0 &set0 [[buffer(0)]], constant uint *spvDynamicOffsets [[buffer(19)]]) {\n"
    "  constant C *c = (constant C *)((constant char *)set0.g + spvDynamicOffsets[0]);\n"
    "  float4 dg = set0.t.gather(set0.s, float2(0.5), int2(1, 1));\n"
    "  float4 tg = set0.rt.gather(set0.s, float2(0.5), int2(1, 1));\n"
    "  return float4(c->unpack.x, c->unpack.y, set0.g->unpack.x, dg.w + tg.w);\n"
    "}\n";
    NSString *src = src0;
    if (getenv("PROBE_DEVICE")) src = [[src0 stringByReplacingOccurrencesOfString:@"constant C *g" withString:@"device const C *g"]
        stringByReplacingOccurrencesOfString:@"constant C *c = (constant C *)((constant char *)set0.g" withString:@"device const C *c = (device const C *)((device const char *)set0.g"];
    NSError *err = nil;
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
    if (!lib) { printf("compile: %s\n", err.localizedDescription.UTF8String); return 1; }
    id<MTLFunction> fs = [lib newFunctionWithName:@"fs"];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = fs;
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    id<MTLRenderPipelineState> ps = [d newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!ps) { printf("pipeline: %s\n", err.localizedDescription.UTF8String); return 1; }

    const char *mode = getenv("PROBE_MODE") ?: "shared";
    id<MTLBuffer> cbuf = [d newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    float *cf = (float *)cbuf.contents; for (int i = 0; i < 1024; i++) cf[i] = -1;
    cf[256 / 4 + 4] = 3.0f; cf[256 / 4 + 5] = 7.0f; cf[4] = 5.0f;
    if (!strcmp(mode, "private")) {
        id<MTLBuffer> pb = [d newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
        id<MTLCommandBuffer> c0 = [[d newCommandQueue] commandBuffer]; id<MTLBlitCommandEncoder> b0 = [c0 blitCommandEncoder];
        [b0 copyFromBuffer:cbuf sourceOffset:0 toBuffer:pb destinationOffset:0 size:4096]; [b0 endEncoding]; [c0 commit]; [c0 waitUntilCompleted];
        cbuf = pb;
    }
    printf("mode %s\n", mode);

    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:16 height:16 mipmapped:NO];
    dd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; dd.storageMode = MTLStorageModePrivate;
    id<MTLTexture> depth = [d newTextureWithDescriptor:dd];
    MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:16 height:16 mipmapped:NO];
    rd.usage = MTLTextureUsageShaderRead; rd.storageMode = MTLStorageModeShared;
    id<MTLTexture> rtex = [d newTextureWithDescriptor:rd];
    { float px[256]; for (int i = 0; i < 256; i++) px[i] = 0.25f;
      [rtex replaceRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0 withBytes:px bytesPerRow:64]; }
    MTLSamplerDescriptor *sdsc = [MTLSamplerDescriptor new]; sdsc.supportArgumentBuffers = YES;
    id<MTLSamplerState> smp = [d newSamplerStateWithDescriptor:sdsc];

    id<MTLArgumentEncoder> ae = [fs newArgumentEncoderWithBufferIndex:0];
    id<MTLBuffer> ab = [d newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];
    [ae setArgumentBuffer:ab offset:0];
    [ae setBuffer:cbuf offset:0 atIndex:0]; [ae setSamplerState:smp atIndex:1]; [ae setTexture:depth atIndex:2]; [ae setTexture:rtex atIndex:3];

    { const uint64_t *w = (const uint64_t *)ab.contents; printf("argbuf %lu bytes: [0]=0x%llx [1]=0x%llx [2]=0x%llx [3]=0x%llx | cbuf gpuAddress 0x%llx\n",
        (unsigned long)ae.encodedLength, w[0], w[1], w[2], w[3], (unsigned long long)cbuf.gpuAddress); }
    MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:1 height:1 mipmapped:NO];
    od.usage = MTLTextureUsageRenderTarget; od.storageMode = MTLStorageModePrivate;
    id<MTLTexture> out = [d newTextureWithDescriptor:od];
    id<MTLBuffer> rb = [d newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q = [d newCommandQueue];
    for (int variant = 0; variant < 2; variant++) {
        id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLRenderPassDescriptor *zp = [MTLRenderPassDescriptor renderPassDescriptor];
        zp.depthAttachment.texture = depth; zp.depthAttachment.loadAction = MTLLoadActionClear;
        zp.depthAttachment.clearDepth = 0.75; zp.depthAttachment.storeAction = MTLStoreActionStore;
        [[cb renderCommandEncoderWithDescriptor:zp] endEncoding];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = out; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(-9, -9, -9, -9); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:ps];
        [e setFragmentBuffer:ab offset:0 atIndex:0];
        uint32_t off = 256;
        id<MTLBuffer> ob = nil;
        if (variant == 0) [e setFragmentBytes:&off length:4 atIndex:19];
        else { ob = [d newBufferWithBytes:&off length:4 options:MTLResourceStorageModeShared]; [e setFragmentBuffer:ob offset:0 atIndex:19]; }
        [e useResource:cbuf usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
        if (!strcmp(mode, "bind")) [e setFragmentBuffer:cbuf offset:0 atIndex:5];
        [e useResource:depth usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
        [e useResource:rtex usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:out sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(1, 1, 1)
                  toBuffer:rb destinationOffset:0 destinationBytesPerRow:16 destinationBytesPerImage:16];
        [b endEncoding];
        [cb commit]; [cb waitUntilCompleted];
        float *r = (float *)rb.contents;
        printf("%s: offset read (%g, %g) want (3, 7) | direct read %g want 5 | depth+R32F gather %g want 1 | status %ld %s\n",
               variant ? "setFragmentBuffer" : "setFragmentBytes ", r[0], r[1], r[2], r[3], (long)cb.status,
               cb.error ? cb.error.localizedDescription.UTF8String : "");
    }
    return 0;
} }
