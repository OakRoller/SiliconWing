// cmpprobe.m: depth-compare sampling as a shadow map lookup does it. Slice 1 of a 3-slice Depth32Float array (the others
// cleared to 0) is read with
// sample_compare at reference 0.4 and 0.6 through a MTLCompareFunctionLess sampler (passes when ref < texel), the sampler
// either in an argument buffer (SPIRV-Cross style, as 3DMark Steel Nomad binds them) or bound directly.
// Expected: 0.4 -> 1, 0.6 -> 0 for both. Prints what the shader returned on the default device.
#import <Metal/Metal.h>
#include <stdio.h>

int main(void) { @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    printf("device: %s\n", d.name.UTF8String);
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct Set0 { sampler s [[id(0)]]; depth2d_array<float> t [[id(1)]]; };\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint i [[vertex_id]]) { V o; float2 q = float2((i << 1) & 2, i & 2); o.p = float4(q * 2 - 1, 0, 1); return o; }\n"
    "fragment float4 fs(constant Set0 &set0 [[buffer(0)]], depth2d_array<float> dt [[texture(0)]], sampler ds [[sampler(0)]]) {\n"
    "  return float4(set0.t.sample_compare(set0.s, float2(0.5), 1, 0.4), set0.t.sample_compare(set0.s, float2(0.5), 1, 0.6),\n"
    "                dt.sample_compare(ds, float2(0.5), 1, 0.4), dt.sample_compare(ds, float2(0.5), 1, 0.6));\n"
    "}\n";
    NSError *err = nil;
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
    if (!lib) { printf("compile: %s\n", err.localizedDescription.UTF8String); return 1; }
    id<MTLFunction> fs = [lib newFunctionWithName:@"fs"];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = fs;
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    id<MTLRenderPipelineState> ps = [d newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!ps) { printf("pipeline: %s\n", err.localizedDescription.UTF8String); return 1; }

    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:16 height:16 mipmapped:NO];
    dd.textureType = MTLTextureType2DArray; dd.arrayLength = 3;
    dd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; dd.storageMode = MTLStorageModePrivate;
    id<MTLTexture> depth = [d newTextureWithDescriptor:dd];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.compareFunction = MTLCompareFunctionLess; sd.minFilter = MTLSamplerMinMagFilterLinear; sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.supportArgumentBuffers = YES;
    id<MTLSamplerState> smp = [d newSamplerStateWithDescriptor:sd];

    id<MTLArgumentEncoder> ae = [fs newArgumentEncoderWithBufferIndex:0];
    id<MTLBuffer> ab = [d newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];
    [ae setArgumentBuffer:ab offset:0]; [ae setSamplerState:smp atIndex:0]; [ae setTexture:depth atIndex:1];

    MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:1 height:1 mipmapped:NO];
    od.usage = MTLTextureUsageRenderTarget; od.storageMode = MTLStorageModePrivate;
    id<MTLTexture> out = [d newTextureWithDescriptor:od];
    id<MTLBuffer> rb = [d newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q = [d newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    for (int sl = 0; sl < 3; sl++) {
        MTLRenderPassDescriptor *zp = [MTLRenderPassDescriptor renderPassDescriptor];
        zp.depthAttachment.texture = depth; zp.depthAttachment.slice = sl; zp.depthAttachment.loadAction = MTLLoadActionClear;
        zp.depthAttachment.clearDepth = sl == 1 ? 0.5 : 0.0; zp.depthAttachment.storeAction = MTLStoreActionStore;
        [[cb renderCommandEncoderWithDescriptor:zp] endEncoding];
    }
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = out; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(-9, -9, -9, -9); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:ps];
    [e setFragmentBuffer:ab offset:0 atIndex:0];
    [e setFragmentTexture:depth atIndex:0]; [e setFragmentSamplerState:smp atIndex:0];
    [e useResource:depth usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:out sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(1, 1, 1)
              toBuffer:rb destinationOffset:0 destinationBytesPerRow:16 destinationBytesPerImage:16];
    [b endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    float *r = (float *)rb.contents;
    printf("argument-buffer sampler: ref 0.4 -> %g, ref 0.6 -> %g | bound sampler: ref 0.4 -> %g, ref 0.6 -> %g | want 1 0 1 0 | status %ld\n",
           r[0], r[1], r[2], r[3], (long)cb.status);
    return 0;
} }
