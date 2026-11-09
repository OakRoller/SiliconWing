// biasprobe.m: depth bias on a Depth16Unorm target, as shadow map passes set it. A full-screen triangle at z 0.5 (and one
// tilted from 0.25 to 0.75 for the slope term) is drawn with setDepthBias:constant slopeScale: clamp:, then the depth is
// copied out. Prints the depth at the centre for each bias setting so two GPUs can be compared.
#import <Metal/Metal.h>
#include <stdio.h>

int main(void) { @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    printf("device: %s\n", d.name.UTF8String);
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint i [[vertex_id]], constant float &tilt [[buffer(0)]]) { V o; float2 q = float2((i << 1) & 2, i & 2);\n"
    "  float2 c = q * 2 - 1; o.p = float4(c, 0.5 + tilt * c.x * 0.25, 1); return o; }\n";
    NSError *err = nil;
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
    if (!lib) { printf("compile: %s\n", err.localizedDescription.UTF8String); return 1; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.depthAttachmentPixelFormat = MTLPixelFormatDepth16Unorm;
    id<MTLRenderPipelineState> ps = [d newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!ps) { printf("pipeline: %s\n", err.localizedDescription.UTF8String); return 1; }
    MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new]; dsd.depthCompareFunction = MTLCompareFunctionAlways; dsd.depthWriteEnabled = YES;
    id<MTLDepthStencilState> dss = [d newDepthStencilStateWithDescriptor:dsd];
    const int W = 64;
    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth16Unorm width:W height:W mipmapped:NO];
    dd.usage = MTLTextureUsageRenderTarget; dd.storageMode = MTLStorageModePrivate;
    id<MTLTexture> depth = [d newTextureWithDescriptor:dd];
    id<MTLBuffer> rb = [d newBufferWithLength:W * W * 2 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q = [d newCommandQueue];
    struct { float tilt, bias, slope, clamp; } cases[] = { {0, 0, 0, 0}, {0, 1000, 0, 0}, {0, -1000, 0, 0}, {1, 0, 0, 0}, {1, 0, 4, 0}, {1, 100, 2, 0.01f} };
    for (unsigned c = 0; c < sizeof cases / sizeof cases[0]; c++) {
        id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.depthAttachment.texture = depth; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.clearDepth = 1;
        rp.depthAttachment.storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:ps]; [e setDepthStencilState:dss];
        [e setVertexBytes:&cases[c].tilt length:4 atIndex:0];
        [e setDepthBias:cases[c].bias slopeScale:cases[c].slope clamp:cases[c].clamp];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:depth sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1)
                  toBuffer:rb destinationOffset:0 destinationBytesPerRow:W * 2 destinationBytesPerImage:W * W * 2];
        [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
        const uint16_t *z = (const uint16_t *)rb.contents;
        printf("tilt %g bias %g slope %g clamp %g: depth centre %.5f (raw %u) left %.5f right %.5f\n", cases[c].tilt, cases[c].bias, cases[c].slope,
               cases[c].clamp, z[W / 2 * W + W / 2] / 65535.0, z[W / 2 * W + W / 2], z[W / 2 * W + 4] / 65535.0, z[W / 2 * W + W - 5] / 65535.0);
    }
    return 0;
} }
