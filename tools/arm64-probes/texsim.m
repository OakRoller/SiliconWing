// texsim.m: texture paths a game uses that argsim does not, each sampled through Metal 3 resource IDs (gpuResourceID in a
// plain buffer) and checked on the CPU. Written for Cyberpunk 2077 on the arm64 port, whose G-buffer albedo and UI came
// out black while vertex normals and depth were right (2026-11-04): every texture the game samples read as zero.
//   1  managed texture + replaceRegion (the argsim baseline)
//   2  private texture uploaded with a blit from a shared buffer
//   3  texture from an automatic MTLHeap, blit upload
//   4  texture from a placement heap (newTextureWithDescriptor:offset:), then a second one aliased at the same offset
//   5  BC1 compressed, private, blit upload
//   6  4-level mip chain sampled with level(1), and with a sampler whose lodMinClamp is 2
//   7  RGBA8Unorm texture sampled through an RGBA8Unorm_sRGB view
//   8  texture2d<half> sampled by a fragment shader returning half4
//   9  resource table indexed dynamically: r[idx].t with idx from a buffer
//  10  texture and sampler copied into locals before sampling
//  11  texture2d_array slice 1, 12 texturecube +Z face
//  13  resource table in a private buffer filled by a blit from a shared one
//  14  resource table in the constant address space (constant Res &)
//  15  sampler with anisotropy 16, linear mips, lodMinClamp 0
// Build: clang -fobjc-arc -framework Metal -framework Foundation -o out/rendersim/texsim tools/arm64-probes/texsim.m
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
static int fails = 0;
#define CHECK(cond, ...) do { if (cond) printf("PASS: " __VA_ARGS__); else { fails++; printf("FAIL: " __VA_ARGS__); } printf("\n"); } while (0)
static id<MTLDevice> pick(void) { for (id<MTLDevice> x in MTLCopyAllDevices()) if ([NSStringFromClass([x class]) isEqualToString:@"NVMTLDevice"]) return x; return nil; }
static id<MTLDevice> D; static id<MTLCommandQueue> Q; static id<MTLLibrary> LIB; static id<MTLTexture> RT;
static NSData *readback(id<MTLTexture> t) {
    NSUInteger bpr = t.width * 4, len = bpr * t.height; id<MTLBuffer> buf = [D newBufferWithLength:len options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [Q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(t.width,t.height,1) toBuffer:buf destinationOffset:0 destinationBytesPerRow:bpr destinationBytesPerImage:len];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; return [NSData dataWithBytes:buf.contents length:len]; }
static uint32_t px(NSData *i, NSUInteger w, NSUInteger x, NSUInteger y) { return ((const uint32_t *)i.bytes)[y * w + x]; }
static uint32_t rgba(unsigned r, unsigned g, unsigned b) { return 0xFF000000u | (b << 16) | (g << 8) | r; }
static int close3(uint32_t got, uint32_t want, int tol) {
    for (int k = 0; k < 24; k += 8) { int a = (got >> k) & 0xFF, b = (want >> k) & 0xFF; if (abs(a - b) > tol) return 0; } return (got >> 24) == 0xFF; }
static void *solid(NSUInteger w, NSUInteger h, uint32_t v) { uint32_t *p = malloc(w * h * 4); for (NSUInteger i = 0; i < w * h; i++) p[i] = v; return p; }
// upload bytes (bpr per row) into level/slice of t with a blit from a shared buffer
static void blit_upload(id<MTLTexture> t, NSUInteger level, NSUInteger slice, const void *bytes, NSUInteger bpr, NSUInteger w, NSUInteger h, NSUInteger bytesPerImage) {
    id<MTLBuffer> src = [D newBufferWithBytes:bytes length:bytesPerImage options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [Q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:bpr sourceBytesPerImage:bytesPerImage sourceSize:MTLSizeMake(w, h, 1) toTexture:t destinationSlice:slice destinationLevel:level destinationOrigin:MTLOriginMake(0,0,0)];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
}
static MTLTextureDescriptor *desc(MTLPixelFormat f, NSUInteger w, NSUInteger h, BOOL mips) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:mips];
    td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModePrivate; return td; }
static id<MTLSamplerState> sampler(MTLSamplerMipFilter mip, float lodMin, NSUInteger aniso) {
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear; sd.mipFilter = mip;
    sd.lodMinClamp = lodMin; sd.maxAnisotropy = aniso ? aniso : 1; sd.supportArgumentBuffers = YES; return [D newSamplerStateWithDescriptor:sd]; }
// draw a fullscreen triangle with fragment fn, buffer 0 = table, buffer 1 = extra (may be nil); returns the pixel at (128,128)
static NSUInteger g_tableOffset = 0;   // offset passed to setFragmentBuffer for buffer 0
static uint32_t draw(NSString *fn, id<MTLBuffer> table, id<MTLBuffer> extra, NSArray *res, MTLPixelFormat rtfmt) {
    NSError *err = nil; MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [LIB newFunctionWithName:@"vtx"]; pd.fragmentFunction = [LIB newFunctionWithName:fn]; pd.colorAttachments[0].pixelFormat = rtfmt;
    id<MTLRenderPipelineState> pso = [D newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!pso) { printf("  pipeline %s: %s\n", fn.UTF8String, err.localizedDescription.UTF8String); return 0xDEADBEEF; }
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = RT;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(0.5, 0.5, 0.5, 0.5);
    id<MTLCommandBuffer> cb = [Q commandBuffer]; id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:pso]; [e setFragmentBuffer:table offset:g_tableOffset atIndex:0]; if (extra) [e setFragmentBuffer:extra offset:0 atIndex:1];
    for (id r in res) { if ([r conformsToProtocol:@protocol(MTLHeap)]) [e useHeap:r stages:MTLRenderStageFragment]; else [e useResource:r usage:MTLResourceUsageRead stages:MTLRenderStageFragment]; }
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    return px(readback(RT), 256, 128, 128);
}
typedef struct { MTLResourceID t, s; } Res;
static id<MTLBuffer> table(id<MTLTexture> t, id<MTLSamplerState> s) { Res r = { t.gpuResourceID, s.gpuResourceID }; return [D newBufferWithBytes:&r length:sizeof r options:MTLResourceStorageModeShared]; }
int main(void) { @autoreleasepool {
    D = pick(); if (!D) { printf("no NVMTLDevice\n"); return 99; }
    printf("device: %s\n", D.name.UTF8String);
    Q = [D newCommandQueue]; NSError *err = nil;
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
      "struct V { float4 pos [[position]]; float2 uv; };\n"
      "vertex V vtx(uint vid [[vertex_id]]) { float2 p = float2((vid << 1) & 2, vid & 2); V o; o.pos = float4(p * 2 - 1, 0, 1); o.uv = p; return o; }\n"
      "struct Res { texture2d<float> t; sampler s; };\n"
      "fragment float4 f_rid(V in [[stage_in]], device const Res *r [[buffer(0)]]) { return r->t.sample(r->s, in.uv); }\n"
      "fragment float4 f_const(V in [[stage_in]], constant Res &r [[buffer(0)]]) { return r.t.sample(r.s, in.uv); }\n"
      "fragment float4 f_idx(V in [[stage_in]], device const Res *r [[buffer(0)]], constant uint &idx [[buffer(1)]]) { return r[idx].t.sample(r[idx].s, in.uv); }\n"
      "fragment float4 f_lod(V in [[stage_in]], device const Res *r [[buffer(0)]], constant float &lod [[buffer(1)]]) { return r->t.sample(r->s, in.uv, level(lod)); }\n"
      "fragment float4 f_local(V in [[stage_in]], device const Res *r [[buffer(0)]]) { texture2d<float> t = r->t; sampler s = r->s; return t.sample(s, in.uv); }\n"
      "struct ResH { texture2d<half> t; sampler s; };\n"
      "fragment half4 f_half(V in [[stage_in]], device const ResH *r [[buffer(0)]]) { return r->t.sample(r->s, in.uv); }\n"
      "struct ResA { texture2d_array<float> t; sampler s; };\n"
      "fragment float4 f_arr(V in [[stage_in]], device const ResA *r [[buffer(0)]], constant uint &slice [[buffer(1)]]) { return r->t.sample(r->s, in.uv, slice); }\n"
      "struct ResC { texturecube<float> t; sampler s; };\n"
      "fragment float4 f_arr0(V in [[stage_in]], device const ResA *r [[buffer(0)]]) { return r->t.sample(r->s, in.uv, 0); }\n"
      "fragment float4 f_qsize(V in [[stage_in]], device const ResA *r [[buffer(0)]]) { return float4(r->t.get_width() / 4096.0, r->t.get_height() / 4096.0, r->t.get_array_size() / 16.0, 1); }\n"
      "fragment float4 f_aread(V in [[stage_in]], device const ResA *r [[buffer(0)]]) { uint2 c = uint2(in.uv * float2(r->t.get_width(), r->t.get_height())); return r->t.read(c, 0); }\n"
      "struct Ptr { uint lo; uint hi; uint idx; uint pad; };\n"
      "struct PtrT { device const Res *r; uint idx; uint pad; };\n"
      "fragment float4 f_ptr(V in [[stage_in]], device const PtrT *p [[buffer(0)]]) { return p->r[p->idx].t.sample(p->r[p->idx].s, in.uv); }\n"
      "struct PtrW { device const uint *w; uint idx; uint pad; };\n"
      "struct PtrD { device const float4 *c; uint idx; uint pad; };\n"
      "struct ResA1 { texture2d_array<float> t; uint64_t pad; sampler s; };\n"
      "struct PtrC { constant const ResA1 *r; constant const uint *w; uint idx; uint pad; };\n"
      "struct TexEnt { uint64_t va; texture2d_array<float> t; uint64_t meta; };\n"
      "struct SmpEnt { sampler s; uint64_t pad0; uint64_t pad1; };\n"
      "struct Heaps { constant const TexEnt *tex; constant const SmpEnt *smp; uint idx; uint pad; };\n"
      "fragment float4 f_heap(V in [[stage_in]], constant Heaps &h [[buffer(0)]]) { constant const TexEnt *e = h.tex + h.idx; return e->t.sample(h.smp[0].s, in.uv, 0); }\n"
      "fragment float4 f_heap1(V in [[stage_in]], constant Heaps &h [[buffer(0)]]) { return h.tex[h.idx].t.sample(h.smp[0].s, in.uv, 0); }\n"
      "fragment float4 f_cptr(V in [[stage_in]], constant PtrC &p [[buffer(0)]]) { return p.r[p.idx].t.sample(p.r[p.idx].s, in.uv, 0); }\n"
      "fragment float4 f_cptrd(V in [[stage_in]], device const PtrC *p [[buffer(0)]]) { return p->r[p->idx].t.sample(p->r[p->idx].s, in.uv, 0); }\n"
      "fragment float4 f_data(V in [[stage_in]], device const PtrD *p [[buffer(0)]]) { return p->c[p->idx]; }\n"
      "fragment float4 f_ptrw(V in [[stage_in]], device const PtrW *p [[buffer(0)]]) { device const Res *r = (device const Res *)(p->w + 2); return r[p->idx].t.sample(r[p->idx].s, in.uv); }\n"
      "fragment float4 f_addr(V in [[stage_in]], device const Ptr *p [[buffer(0)]]) { device const Res *r = (device const Res *)(((ulong)p->hi << 32) | p->lo); return r[p->idx].t.sample(r[p->idx].s, in.uv); }\n"
      "fragment float4 f_addr2(V in [[stage_in]], device const Ptr *p [[buffer(0)]]) { device const uint *w = (device const uint *)(((ulong)p->hi << 32) | p->lo); device const Res *r = (device const Res *)(w + 2); return r[p->idx].t.sample(r[p->idx].s, in.uv); }\n"
      "fragment float4 f_cube(V in [[stage_in]], device const ResC *r [[buffer(0)]]) { return r->t.sample(r->s, float3(in.uv * 2 - 1, 1)); }\n";
    LIB = [D newLibraryWithSource:src options:nil error:&err];
    CHECK(LIB != nil, "compile%s", err ? err.localizedDescription.UTF8String : ""); if (!LIB) return fails;
    MTLTextureDescriptor *rd = desc(MTLPixelFormatRGBA8Unorm, 256, 256, NO); rd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; RT = [D newTextureWithDescriptor:rd];
    id<MTLSamplerState> smp = sampler(MTLSamplerMipFilterNotMipmapped, 0, 0);
    const NSUInteger W = 64, H = 64;
    // 1
    { MTLTextureDescriptor *td = desc(MTLPixelFormatRGBA8Unorm, W, H, NO); td.storageMode = MTLStorageModeManaged; id<MTLTexture> t = [D newTextureWithDescriptor:td];
      void *p = solid(W, H, rgba(10, 20, 30)); [t replaceRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0 withBytes:p bytesPerRow:W*4]; free(p);
      uint32_t got = draw(@"f_rid", table(t, smp), nil, @[t], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, rgba(10,20,30), 1), "1 managed + replaceRegion: 0x%08x want 0x%08x", got, rgba(10,20,30)); }
    // 2
    { id<MTLTexture> t = [D newTextureWithDescriptor:desc(MTLPixelFormatRGBA8Unorm, W, H, NO)];
      void *p = solid(W, H, rgba(40, 50, 60)); blit_upload(t, 0, 0, p, W*4, W, H, W*H*4); free(p);
      uint32_t got = draw(@"f_rid", table(t, smp), nil, @[t], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, rgba(40,50,60), 1), "2 private + blit upload: 0x%08x want 0x%08x", got, rgba(40,50,60)); }
    // 3
    { MTLHeapDescriptor *hd = [MTLHeapDescriptor new]; hd.size = 4 << 20; hd.storageMode = MTLStorageModePrivate; hd.type = MTLHeapTypeAutomatic;
      id<MTLHeap> heap = [D newHeapWithDescriptor:hd]; id<MTLTexture> t = [heap newTextureWithDescriptor:desc(MTLPixelFormatRGBA8Unorm, W, H, NO)];
      CHECK(heap && t, "3 automatic heap texture created");
      if (t) { void *p = solid(W, H, rgba(70, 80, 90)); blit_upload(t, 0, 0, p, W*4, W, H, W*H*4); free(p);
        uint32_t got = draw(@"f_rid", table(t, smp), nil, @[heap], MTLPixelFormatRGBA8Unorm);
        CHECK(close3(got, rgba(70,80,90), 1), "3 automatic heap + blit: 0x%08x want 0x%08x", got, rgba(70,80,90)); } }
    // 4
    { MTLHeapDescriptor *hd = [MTLHeapDescriptor new]; hd.size = 8 << 20; hd.storageMode = MTLStorageModePrivate; hd.type = MTLHeapTypePlacement;
      id<MTLHeap> heap = [D newHeapWithDescriptor:hd]; MTLTextureDescriptor *td = desc(MTLPixelFormatRGBA8Unorm, W, H, NO);
      MTLSizeAndAlign sa = [D heapTextureSizeAndAlignWithDescriptor:td]; NSUInteger off = (1 << 20) / sa.align * sa.align;
      id<MTLTexture> t = [heap newTextureWithDescriptor:td offset:off];
      CHECK(heap && t, "4 placement heap texture created at offset %lu (size %lu align %lu)", (unsigned long)off, (unsigned long)sa.size, (unsigned long)sa.align);
      if (t) { void *p = solid(W, H, rgba(100, 110, 120)); blit_upload(t, 0, 0, p, W*4, W, H, W*H*4); free(p);
        uint32_t got = draw(@"f_rid", table(t, smp), nil, @[heap], MTLPixelFormatRGBA8Unorm);
        CHECK(close3(got, rgba(100,110,120), 1), "4a placement heap + blit: 0x%08x want 0x%08x", got, rgba(100,110,120));
        id<MTLTexture> t2 = [heap newTextureWithDescriptor:td offset:off];
        void *p2 = solid(W, H, rgba(130, 140, 150)); blit_upload(t2, 0, 0, p2, W*4, W, H, W*H*4); free(p2);
        got = draw(@"f_rid", table(t2, smp), nil, @[heap], MTLPixelFormatRGBA8Unorm);
        CHECK(close3(got, rgba(130,140,150), 1), "4b aliased placement texture at the same offset: 0x%08x want 0x%08x", got, rgba(130,140,150)); } }
    // 5 BC1: every 4x4 block = colour0 = colour1 = yellow (565 0xFFE0), indices 0 -> colour0
    { id<MTLTexture> t = [D newTextureWithDescriptor:desc(MTLPixelFormatBC1_RGBA, W, H, NO)];
      CHECK(t != nil, "5 BC1 texture created");
      if (t) { NSUInteger blocks = (W/4) * (H/4); uint8_t *p = malloc(blocks * 8);
        for (NSUInteger i = 0; i < blocks; i++) { uint8_t *b = p + i*8; b[0] = 0xE0; b[1] = 0xFF; b[2] = 0xE0; b[3] = 0xFF; b[4] = b[5] = b[6] = b[7] = 0; }
        blit_upload(t, 0, 0, p, (W/4) * 8, W, H, blocks * 8); free(p);
        uint32_t got = draw(@"f_rid", table(t, smp), nil, @[t], MTLPixelFormatRGBA8Unorm);
        CHECK(close3(got, rgba(255,255,0), 4), "5 BC1 + blit: 0x%08x want ~0x%08x", got, rgba(255,255,0)); } }
    // 6 mips
    { id<MTLTexture> t = [D newTextureWithDescriptor:desc(MTLPixelFormatRGBA8Unorm, W, H, YES)];
      uint32_t cols[4] = { rgba(200,0,0), rgba(0,200,0), rgba(0,0,200), rgba(200,200,0) };
      for (NSUInteger l = 0; l < 4; l++) { NSUInteger w = W >> l, h = H >> l; void *p = solid(w, h, cols[l]); blit_upload(t, l, 0, p, w*4, w, h, w*h*4); free(p); }
      float lod = 1; id<MTLBuffer> lb = [D newBufferWithBytes:&lod length:4 options:MTLResourceStorageModeShared];
      uint32_t got = draw(@"f_lod", table(t, sampler(MTLSamplerMipFilterLinear, 0, 0)), lb, @[t], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, cols[1], 2), "6a mip chain, sample level(1): 0x%08x want 0x%08x", got, cols[1]);
      got = draw(@"f_rid", table(t, sampler(MTLSamplerMipFilterLinear, 2, 0)), nil, @[t], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, cols[2], 2), "6b mip chain, lodMinClamp 2 (ordinary sample): 0x%08x want 0x%08x", got, cols[2]); }
    // 7 sRGB view: stored 128 -> linear 0.2158 -> 55
    { MTLTextureDescriptor *td = desc(MTLPixelFormatRGBA8Unorm, W, H, NO); td.usage |= MTLTextureUsagePixelFormatView; id<MTLTexture> t = [D newTextureWithDescriptor:td];
      void *p = solid(W, H, rgba(128,128,128)); blit_upload(t, 0, 0, p, W*4, W, H, W*H*4); free(p);
      id<MTLTexture> v = [t newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB]; CHECK(v != nil, "7 sRGB view created");
      if (v) { uint32_t got = draw(@"f_rid", table(v, smp), nil, @[t], MTLPixelFormatRGBA8Unorm);
        CHECK(close3(got, rgba(55,55,55), 3), "7 sampled through sRGB view: 0x%08x want ~0x%08x", got, rgba(55,55,55)); } }
    // 8 half
    { id<MTLTexture> t = [D newTextureWithDescriptor:desc(MTLPixelFormatRGBA8Unorm, W, H, NO)];
      void *p = solid(W, H, rgba(10, 20, 30)); blit_upload(t, 0, 0, p, W*4, W, H, W*H*4); free(p);
      uint32_t got = draw(@"f_half", table(t, smp), nil, @[t], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, rgba(10,20,30), 1), "8 texture2d<half> + half4 output: 0x%08x want 0x%08x", got, rgba(10,20,30)); }
    // 9 dynamic index
    { Res r[3]; uint32_t cols[3] = { rgba(1,2,3), rgba(60,70,80), rgba(90,100,110) }; NSMutableArray *ts = [NSMutableArray new];
      for (int i = 0; i < 3; i++) { id<MTLTexture> t = [D newTextureWithDescriptor:desc(MTLPixelFormatRGBA8Unorm, W, H, NO)]; void *p = solid(W, H, cols[i]); blit_upload(t, 0, 0, p, W*4, W, H, W*H*4); free(p);
        r[i].t = t.gpuResourceID; r[i].s = smp.gpuResourceID; [ts addObject:t]; }
      id<MTLBuffer> tb = [D newBufferWithBytes:r length:sizeof r options:MTLResourceStorageModeShared];
      uint32_t idx = 2; id<MTLBuffer> ib = [D newBufferWithBytes:&idx length:4 options:MTLResourceStorageModeShared];
      uint32_t got = draw(@"f_idx", tb, ib, ts, MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, cols[2], 1), "9 r[idx] dynamic index (idx 2): 0x%08x want 0x%08x", got, cols[2]);
      // 10 locals, 14 constant address space, 13 private table
      got = draw(@"f_local", tb, nil, ts, MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, cols[0], 1), "10 texture/sampler copied to locals: 0x%08x want 0x%08x", got, cols[0]);
      got = draw(@"f_const", tb, nil, ts, MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, cols[0], 1), "14 table in constant address space: 0x%08x want 0x%08x", got, cols[0]);
      id<MTLBuffer> priv = [D newBufferWithLength:sizeof r options:MTLResourceStorageModePrivate];
      { id<MTLCommandBuffer> cb = [Q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder]; [b copyFromBuffer:tb sourceOffset:0 toBuffer:priv destinationOffset:0 size:sizeof r]; [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; }
      got = draw(@"f_idx", priv, ib, ts, MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, cols[2], 1), "13 table in a private buffer (blit copy), idx 2: 0x%08x want 0x%08x", got, cols[2]); }
    // 16/17/18: the resource table reached through MTLBuffer.gpuAddress stored in a constant block (shared, private, heap)
    { Res r[3]; uint32_t cols[3] = { rgba(5,6,7), rgba(61,71,81), rgba(91,101,111) }; NSMutableArray *ts = [NSMutableArray new];
      for (int i = 0; i < 3; i++) { id<MTLTexture> t = [D newTextureWithDescriptor:desc(MTLPixelFormatRGBA8Unorm, W, H, NO)]; void *p = solid(W, H, cols[i]); blit_upload(t, 0, 0, p, W*4, W, H, W*H*4); free(p);
        r[i].t = t.gpuResourceID; r[i].s = smp.gpuResourceID; [ts addObject:t]; }
      id<MTLBuffer> tb = [D newBufferWithBytes:r length:sizeof r options:MTLResourceStorageModeShared];
      struct { uint32_t lo, hi, idx, pad; } ptr = { (uint32_t)tb.gpuAddress, (uint32_t)(tb.gpuAddress >> 32), 2, 0 };
      printf("  16: shared table gpuAddress 0x%llx\n", (unsigned long long)tb.gpuAddress);
      id<MTLBuffer> pb = [D newBufferWithBytes:&ptr length:sizeof ptr options:MTLResourceStorageModeShared];
      uint32_t got = draw(@"f_addr", pb, nil, [ts arrayByAddingObject:tb], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, cols[2], 1), "16 table via gpuAddress of a shared buffer, idx 2: 0x%08x want 0x%08x", got, cols[2]);
      struct { uint64_t addr; uint32_t idx, pad; } pt = { tb.gpuAddress, 2, 0 };
      id<MTLBuffer> pbt = [D newBufferWithBytes:&pt length:sizeof pt options:MTLResourceStorageModeShared];
      got = draw(@"f_ptr", pbt, nil, [ts arrayByAddingObject:tb], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, cols[2], 1), "16b table through a pointer-typed member (device const Res *), idx 2: 0x%08x want 0x%08x", got, cols[2]);
      struct { uint64_t addr; uint32_t idx, pad; } pw = { tb.gpuAddress - 8, 2, 0 };
      id<MTLBuffer> pbw = [D newBufferWithBytes:&pw length:sizeof pw options:MTLResourceStorageModeShared];
      got = draw(@"f_ptrw", pbw, nil, [ts arrayByAddingObject:tb], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, cols[2], 1), "16c table through a device const uint * member (+2 words), idx 2: 0x%08x want 0x%08x", got, cols[2]);
      id<MTLBuffer> priv = [D newBufferWithLength:sizeof r + 8 options:MTLResourceStorageModePrivate];
      { id<MTLBuffer> st = [D newBufferWithLength:sizeof r + 8 options:MTLResourceStorageModeShared]; memcpy((char *)st.contents + 8, r, sizeof r);
        id<MTLCommandBuffer> cb = [Q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder]; [b copyFromBuffer:st sourceOffset:0 toBuffer:priv destinationOffset:0 size:sizeof r + 8]; [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; }
      struct { uint32_t lo, hi, idx, pad; } ptr2 = { (uint32_t)priv.gpuAddress, (uint32_t)(priv.gpuAddress >> 32), 1, 0 };
      printf("  17: private table gpuAddress 0x%llx\n", (unsigned long long)priv.gpuAddress);
      id<MTLBuffer> pb2 = [D newBufferWithBytes:&ptr2 length:sizeof ptr2 options:MTLResourceStorageModeShared];
      got = draw(@"f_addr2", pb2, nil, [ts arrayByAddingObject:priv], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, cols[1], 1), "17 table (+8 B header) via gpuAddress of a private buffer, idx 1: 0x%08x want 0x%08x", got, cols[1]);
      MTLHeapDescriptor *hd = [MTLHeapDescriptor new]; hd.size = 1 << 20; hd.storageMode = MTLStorageModeShared; hd.type = MTLHeapTypeAutomatic;
      id<MTLHeap> heap = [D newHeapWithDescriptor:hd]; id<MTLBuffer> hb = [heap newBufferWithLength:sizeof r options:MTLResourceStorageModeShared];
      if (hb) { memcpy(hb.contents, r, sizeof r);
        struct { uint32_t lo, hi, idx, pad; } ptr3 = { (uint32_t)hb.gpuAddress, (uint32_t)(hb.gpuAddress >> 32), 0, 0 };
        printf("  18: heap buffer gpuAddress 0x%llx\n", (unsigned long long)hb.gpuAddress);
        id<MTLBuffer> pb3 = [D newBufferWithBytes:&ptr3 length:sizeof ptr3 options:MTLResourceStorageModeShared];
        got = draw(@"f_addr", pb3, nil, [ts arrayByAddingObject:heap], MTLPixelFormatRGBA8Unorm);
        CHECK(close3(got, cols[0], 1), "18 table via gpuAddress of a shared heap buffer, idx 0: 0x%08x want 0x%08x", got, cols[0]); }
      else printf("  18: heap newBufferWithLength returned nil\n"); }
    // 19: plain data (no textures) through a pointer member: the colour array only made resident, then also bound at index 1
    { float cols[3][4] = { {0.1f,0.2f,0.3f,1}, {0.4f,0.5f,0.6f,1}, {0.7f,0.8f,0.9f,1} };
      id<MTLBuffer> cb = [D newBufferWithBytes:cols length:sizeof cols options:MTLResourceStorageModeShared];
      struct { uint64_t addr; uint32_t idx, pad; } pd = { cb.gpuAddress, 2, 0 };
      id<MTLBuffer> pbd = [D newBufferWithBytes:&pd length:sizeof pd options:MTLResourceStorageModeShared];
      uint32_t got = draw(@"f_data", pbd, nil, @[cb], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, rgba(179,204,230), 2), "19a float4 array through a device pointer, buffer only useResource'd: 0x%08x want ~0x%08x", got, rgba(179,204,230));
      got = draw(@"f_data", pbd, cb, @[cb], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, rgba(179,204,230), 2), "19b same, with the array also bound at fragment index 1: 0x%08x want ~0x%08x", got, rgba(179,204,230));
      id<MTLBuffer> cpriv = [D newBufferWithLength:sizeof cols options:MTLResourceStorageModePrivate];
      { id<MTLCommandBuffer> c = [Q commandBuffer]; id<MTLBlitCommandEncoder> b = [c blitCommandEncoder]; [b copyFromBuffer:cb sourceOffset:0 toBuffer:cpriv destinationOffset:0 size:sizeof cols]; [b endEncoding]; [c commit]; [c waitUntilCompleted]; }
      struct { uint64_t addr; uint32_t idx, pad; } pd2 = { cpriv.gpuAddress, 1, 0 };
      id<MTLBuffer> pbd2 = [D newBufferWithBytes:&pd2 length:sizeof pd2 options:MTLResourceStorageModeShared];
      got = draw(@"f_data", pbd2, nil, @[cpriv], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, rgba(102,128,153), 2), "19c float4 array in a PRIVATE buffer through a device pointer, useResource'd: 0x%08x want ~0x%08x", got, rgba(102,128,153)); }
    // 20: texture views the way Metal Shader Converter makes SRVs: newTextureViewWithPixelFormat:textureType:levels:slices:swizzle:
    { id<MTLTexture> t = [D newTextureWithDescriptor:desc(MTLPixelFormatRGBA8Unorm, W, H, YES)];
      uint32_t cols[4] = { rgba(201,1,1), rgba(1,201,1), rgba(1,1,201), rgba(201,201,1) };
      for (NSUInteger l = 0; l < 4; l++) { NSUInteger w = W >> l, h = H >> l; void *p = solid(w, h, cols[l]); blit_upload(t, l, 0, p, w*4, w, h, w*h*4); free(p); }
      MTLTextureSwizzleChannels ident = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha);
      id<MTLTexture> v1 = [t newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureType2D levels:NSMakeRange(0, 4) slices:NSMakeRange(0, 1) swizzle:ident];
      CHECK(v1 != nil, "20 full-range identity view created (resid 0x%llx)", v1 ? (unsigned long long)v1.gpuResourceID._impl : 0ull);
      uint32_t got = v1 ? draw(@"f_rid", table(v1, smp), nil, @[t], MTLPixelFormatRGBA8Unorm) : 0;
      CHECK(close3(got, cols[0], 2), "20a full-range identity view sampled: 0x%08x want 0x%08x", got, cols[0]);
      id<MTLTexture> v2 = [t newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureType2D levels:NSMakeRange(1, 2) slices:NSMakeRange(0, 1) swizzle:ident];
      got = v2 ? draw(@"f_rid", table(v2, smp), nil, @[t], MTLPixelFormatRGBA8Unorm) : 0;
      CHECK(close3(got, cols[1], 2), "20b levels 1..2 view sampled (base level 1): 0x%08x want 0x%08x (resid 0x%llx)", got, cols[1], v2 ? (unsigned long long)v2.gpuResourceID._impl : 0ull);
      MTLTextureSwizzleChannels bgra = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleBlue, MTLTextureSwizzleGreen, MTLTextureSwizzleRed, MTLTextureSwizzleAlpha);
      id<MTLTexture> v3 = [t newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureType2D levels:NSMakeRange(0, 4) slices:NSMakeRange(0, 1) swizzle:bgra];
      got = v3 ? draw(@"f_rid", table(v3, smp), nil, @[t], MTLPixelFormatRGBA8Unorm) : 0;
      CHECK(close3(got, rgba(1,1,201), 2), "20c swizzled (bgra) view sampled: 0x%08x want 0x%08x", got, rgba(1,1,201));
      id<MTLTexture> v4 = [t newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB textureType:MTLTextureType2D levels:NSMakeRange(0, 4) slices:NSMakeRange(0, 1) swizzle:ident];
      got = v4 ? draw(@"f_rid", table(v4, smp), nil, @[t], MTLPixelFormatRGBA8Unorm) : 0;
      CHECK(v4 && (got >> 24) == 0xFF && (got & 0xFF) > 140, "20d sRGB view via the 5-argument API: 0x%08x (R should be ~155)", got);
      // the same on a placement-heap texture
      MTLHeapDescriptor *hd = [MTLHeapDescriptor new]; hd.size = 8 << 20; hd.storageMode = MTLStorageModePrivate; hd.type = MTLHeapTypePlacement;
      id<MTLHeap> heap = [D newHeapWithDescriptor:hd]; MTLTextureDescriptor *td = desc(MTLPixelFormatRGBA8Unorm, W, H, YES);
      id<MTLTexture> ht = [heap newTextureWithDescriptor:td offset:0];
      if (ht) { for (NSUInteger l = 0; l < 4; l++) { NSUInteger w = W >> l, h = H >> l; void *p = solid(w, h, cols[l]); blit_upload(ht, l, 0, p, w*4, w, h, w*h*4); free(p); }
        id<MTLTexture> v5 = [ht newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureType2D levels:NSMakeRange(0, 4) slices:NSMakeRange(0, 1) swizzle:ident];
        got = v5 ? draw(@"f_rid", table(v5, smp), nil, @[heap], MTLPixelFormatRGBA8Unorm) : 0;
        CHECK(close3(got, cols[0], 2), "20e identity view of a placement-heap texture: 0x%08x want 0x%08x (resid 0x%llx)", got, cols[0], v5 ? (unsigned long long)v5.gpuResourceID._impl : 0ull); }
      // a 2D view of one slice of a 2D array
      MTLTextureDescriptor *ad = desc(MTLPixelFormatRGBA8Unorm, W, H, NO); ad.textureType = MTLTextureType2DArray; ad.arrayLength = 3; id<MTLTexture> at = [D newTextureWithDescriptor:ad];
      for (NSUInteger k = 0; k < 3; k++) { void *p = solid(W, H, rgba(10*k+3, 10*k+4, 10*k+5)); blit_upload(at, 0, k, p, W*4, W, H, W*H*4); free(p); }
      id<MTLTexture> v6 = [at newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureType2D levels:NSMakeRange(0, 1) slices:NSMakeRange(2, 1) swizzle:ident];
      got = v6 ? draw(@"f_rid", table(v6, smp), nil, @[at], MTLPixelFormatRGBA8Unorm) : 0;
      CHECK(close3(got, rgba(23,24,25), 2), "20f 2D view of slice 2 of a 2D array: 0x%08x want 0x%08x (resid 0x%llx)", got, rgba(23,24,25), v6 ? (unsigned long long)v6.gpuResourceID._impl : 0ull); }
    // 21: a plain 2D texture viewed as a 2D ARRAY of one slice and sampled with texture2d_array (what Metal Shader Converter's SRVs do)
    { id<MTLTexture> t = [D newTextureWithDescriptor:desc(MTLPixelFormatRGBA8Unorm, W, H, YES)];
      uint32_t cols[4] = { rgba(77,88,99), rgba(1,2,3), rgba(4,5,6), rgba(7,8,9) };
      for (NSUInteger l = 0; l < 4; l++) { NSUInteger w = W >> l, h = H >> l; void *p = solid(w, h, cols[l]); blit_upload(t, l, 0, p, w*4, w, h, w*h*4); free(p); }
      MTLTextureSwizzleChannels ident = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha);
      id<MTLTexture> v = [t newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureType2DArray levels:NSMakeRange(0, 4) slices:NSMakeRange(0, 1) swizzle:ident];
      CHECK(v != nil, "21 2D texture viewed as 2DArray (1 slice): %s, textureType %lu, arrayLength %lu", v ? "created" : "nil", v ? (unsigned long)v.textureType : 0ul, v ? (unsigned long)v.arrayLength : 0ul);
      uint32_t got = v ? draw(@"f_arr0", table(v, smp), nil, @[t], MTLPixelFormatRGBA8Unorm) : 0;
      CHECK(close3(got, cols[0], 2), "21a sampled with texture2d_array slice 0: 0x%08x want 0x%08x", got, cols[0]);
      id<MTLTexture> v2 = [t newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureType2DArray levels:NSMakeRange(0, 4) slices:NSMakeRange(0, 1)];
      got = v2 ? draw(@"f_arr0", table(v2, smp), nil, @[t], MTLPixelFormatRGBA8Unorm) : 0;
      CHECK(close3(got, cols[0], 2), "21b same through the 4-argument view API: 0x%08x want 0x%08x", got, cols[0]);
      // and a texture CREATED as a 1-slice 2D array sampled as texture2d_array (the valid-on-both-sides control)
      MTLTextureDescriptor *ad = desc(MTLPixelFormatRGBA8Unorm, W, H, NO); ad.textureType = MTLTextureType2DArray; ad.arrayLength = 1; id<MTLTexture> at = [D newTextureWithDescriptor:ad];
      void *p = solid(W, H, rgba(31,32,33)); blit_upload(at, 0, 0, p, W*4, W, H, W*H*4); free(p);
      got = draw(@"f_arr0", table(at, smp), nil, @[at], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, rgba(31,32,33), 2), "21c 1-slice 2D array texture sampled as texture2d_array: 0x%08x want 0x%08x", got, rgba(31,32,33)); }
    // 22: what the game does: every texture a 1-layer 2D ARRAY, mipmapped, BC1 or RGBA8, placed in a heap, uploaded by blit,
    //     sampled with texture2d_array; then the same after ~1000 other textures took heap slots (high slot numbers)
    { MTLHeapDescriptor *hd = [MTLHeapDescriptor new]; hd.size = 64 << 20; hd.storageMode = MTLStorageModePrivate; hd.type = MTLHeapTypeAutomatic;
      id<MTLHeap> heap = [D newHeapWithDescriptor:hd];
      MTLTextureDescriptor *ad = desc(MTLPixelFormatRGBA8Unorm, 256, 256, YES); ad.textureType = MTLTextureType2DArray; ad.arrayLength = 1;
      id<MTLTexture> a = [heap newTextureWithDescriptor:ad];
      uint32_t cols[9] = { rgba(120,30,40), rgba(1,2,3), rgba(4,5,6), rgba(7,8,9), rgba(10,11,12), rgba(13,14,15), rgba(16,17,18), rgba(19,20,21), rgba(22,23,24) };
      for (NSUInteger l = 0; l < 9; l++) { NSUInteger w = 256 >> l, h = 256 >> l; void *p = solid(w, h, cols[l]); blit_upload(a, l, 0, p, w*4, w, h, w*h*4); free(p); }
      uint32_t got = draw(@"f_arr0", table(a, sampler(MTLSamplerMipFilterLinear, 0, 16)), nil, @[heap], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, cols[0], 3), "22a heap 2D-array(1) RGBA8 9 mips, texture2d_array + aniso mip sampler: 0x%08x want ~0x%08x", got, cols[0]);
      MTLTextureDescriptor *bd = desc(MTLPixelFormatBC1_RGBA_sRGB, 256, 256, YES); bd.textureType = MTLTextureType2DArray; bd.arrayLength = 1;
      id<MTLTexture> b = [heap newTextureWithDescriptor:bd];
      CHECK(b != nil, "22b heap BC1_sRGB 2D-array(1) mipmapped created (mips %lu)", b ? (unsigned long)b.mipmapLevelCount : 0ul);
      if (b) { for (NSUInteger l = 0; l < b.mipmapLevelCount; l++) { NSUInteger w = MAX(256 >> l, 1), h = MAX(256 >> l, 1), bw = (w + 3) / 4, bh = (h + 3) / 4; uint8_t *p = malloc(bw * bh * 8);
          for (NSUInteger i = 0; i < bw * bh; i++) { uint8_t *q = p + i*8; q[0] = 0xE0; q[1] = 0xFF; q[2] = 0xE0; q[3] = 0xFF; q[4] = q[5] = q[6] = q[7] = 0; }
          blit_upload(b, l, 0, p, bw * 8, w, h, bw * bh * 8); free(p); }
        got = draw(@"f_arr0", table(b, sampler(MTLSamplerMipFilterLinear, 0, 16)), nil, @[heap], MTLPixelFormatRGBA8Unorm);
        CHECK(close3(got, rgba(255,255,0), 6), "22c heap BC1_sRGB 2D-array(1) sampled as texture2d_array: 0x%08x want ~0x%08x", got, rgba(255,255,0)); }
      // fill ~1000 heap slots, then sample a fresh texture with a high slot number
      NSMutableArray *keep = [NSMutableArray new]; MTLTextureDescriptor *sd = desc(MTLPixelFormatRGBA8Unorm, 4, 4, NO); sd.textureType = MTLTextureType2DArray; sd.arrayLength = 1;
      for (int i = 0; i < 1000; i++) { id<MTLTexture> t = [D newTextureWithDescriptor:sd]; (void)t.gpuResourceID; [keep addObject:t]; }
      id<MTLTexture> hi = [heap newTextureWithDescriptor:ad]; void *hp = solid(256, 256, rgba(200,100,50)); blit_upload(hi, 0, 0, hp, 256*4, 256, 256, 256*256*4); free(hp);
      got = draw(@"f_arr0", table(hi, sampler(MTLSamplerMipFilterNotMipmapped, 0, 0)), nil, @[heap], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, rgba(200,100,50), 3), "22d texture with a high heap slot (resid 0x%llx) sampled: 0x%08x want 0x%08x", (unsigned long long)hi.gpuResourceID._impl, got, rgba(200,100,50)); }
    // 23: the table in the CONSTANT address space (the game's argument buffers are constant-space pointer chains)
    { MTLTextureDescriptor *ad = desc(MTLPixelFormatRGBA8Unorm, W, H, NO); ad.textureType = MTLTextureType2DArray; ad.arrayLength = 1;
      struct { MTLResourceID t; uint64_t pad; MTLResourceID s; } r[3]; uint32_t cols[3] = { rgba(9,8,7), rgba(66,77,88), rgba(99,111,122) }; NSMutableArray *ts = [NSMutableArray new];
      for (int i = 0; i < 3; i++) { id<MTLTexture> t = [D newTextureWithDescriptor:ad]; void *p = solid(W, H, cols[i]); blit_upload(t, 0, 0, p, W*4, W, H, W*H*4); free(p);
        r[i].t = t.gpuResourceID; r[i].pad = 0; r[i].s = smp.gpuResourceID; [ts addObject:t]; }
      id<MTLBuffer> tb = [D newBufferWithBytes:r length:sizeof r options:MTLResourceStorageModeShared];
      struct { uint64_t r, w; uint32_t idx, pad; } pc = { tb.gpuAddress, tb.gpuAddress, 2, 0 };
      id<MTLBuffer> pb = [D newBufferWithBytes:&pc length:sizeof pc options:MTLResourceStorageModeShared];
      uint32_t got = draw(@"f_cptr", pb, nil, [ts arrayByAddingObject:tb], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, cols[2], 1), "23a constant-space table pointer (constant PtrC &), idx 2: 0x%08x want 0x%08x", got, cols[2]);
      got = draw(@"f_cptrd", pb, nil, [ts arrayByAddingObject:tb], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, cols[2], 1), "23b constant-space table pointer inside a device struct, idx 2: 0x%08x want 0x%08x", got, cols[2]); }
    // 24: Metal Shader Converter's exact layout: IRDescriptorTableEntry {gpuVA, textureViewID, metadata} tables in constant space,
    //     texture loaded as a single field (no aggregate copy), sampler from a second table
    { MTLTextureDescriptor *ad = desc(MTLPixelFormatRGBA8Unorm, W, H, NO); ad.textureType = MTLTextureType2DArray; ad.arrayLength = 1;
      struct { uint64_t va; MTLResourceID t; uint64_t meta; } te[4]; struct { MTLResourceID s; uint64_t p0, p1; } se[2];
      uint32_t cols[4] = { rgba(3,2,1), rgba(44,55,66), rgba(77,88,99), rgba(111,122,133) }; NSMutableArray *ts = [NSMutableArray new];
      for (int i = 0; i < 4; i++) { id<MTLTexture> t = [D newTextureWithDescriptor:ad]; void *p = solid(W, H, cols[i]); blit_upload(t, 0, 0, p, W*4, W, H, W*H*4); free(p);
        te[i].va = 0; te[i].t = t.gpuResourceID; te[i].meta = 0; [ts addObject:t]; }
      se[0].s = smp.gpuResourceID; se[0].p0 = se[0].p1 = 0; se[1] = se[0];
      id<MTLBuffer> tt = [D newBufferWithBytes:te length:sizeof te options:MTLResourceStorageModeShared];
      id<MTLBuffer> st = [D newBufferWithBytes:se length:sizeof se options:MTLResourceStorageModeShared];
      struct { uint64_t tex, smp; uint32_t idx, pad; } hp = { tt.gpuAddress, st.gpuAddress, 3, 0 };
      id<MTLBuffer> hb = [D newBufferWithBytes:&hp length:sizeof hp options:MTLResourceStorageModeShared];
      NSArray *res = [ts arrayByAddingObjectsFromArray:@[tt, st]];
      uint32_t got = draw(@"f_heap", hb, nil, res, MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, cols[3], 1), "24a MSC-style descriptor tables (pointer arithmetic), idx 3: 0x%08x want 0x%08x", got, cols[3]);
      got = draw(@"f_heap1", hb, nil, res, MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, cols[3], 1), "24b MSC-style descriptor tables (subscript), idx 3: 0x%08x want 0x%08x", got, cols[3]); }
    // 25: the table bound at a large offset inside a big shared buffer (the game binds its argument buffer 30 MB into a 192 MB ring)
    { Res r[3]; uint32_t cols[3] = { rgba(12,34,56), rgba(78,90,12), rgba(34,56,78) }; NSMutableArray *ts = [NSMutableArray new];
      for (int i = 0; i < 3; i++) { id<MTLTexture> t = [D newTextureWithDescriptor:desc(MTLPixelFormatRGBA8Unorm, W, H, NO)]; void *p = solid(W, H, cols[i]); blit_upload(t, 0, 0, p, W*4, W, H, W*H*4); free(p);
        r[i].t = t.gpuResourceID; r[i].s = smp.gpuResourceID; [ts addObject:t]; }
      id<MTLBuffer> big = [D newBufferWithLength:64 << 20 options:MTLResourceStorageModeShared];
      NSUInteger offs[4] = { 256, 70144, 1 << 20, (33u << 20) + 30675200 % (1 << 20) };
      for (int k = 0; k < 4; k++) { memcpy((char *)big.contents + offs[k], r, sizeof r); g_tableOffset = offs[k];
        uint32_t idx = 1; id<MTLBuffer> ib = [D newBufferWithBytes:&idx length:4 options:MTLResourceStorageModeShared];
        uint32_t got = draw(@"f_idx", big, ib, ts, MTLPixelFormatRGBA8Unorm);
        CHECK(close3(got, cols[1], 1), "25%c table bound at offset %lu of a 64 MB shared buffer, idx 1: 0x%08x want 0x%08x", 'a' + k, (unsigned long)offs[k], got, cols[1]); }
      g_tableOffset = 0; }
    // 26: two draws in ONE encoder; the second changes only the bound offset with setFragmentBufferOffset:atIndex:
    { Res ra[2], rb[2]; uint32_t ca = rgba(21,22,23), cb = rgba(121,122,123); NSMutableArray *ts = [NSMutableArray new];
      id<MTLTexture> ta = [D newTextureWithDescriptor:desc(MTLPixelFormatRGBA8Unorm, W, H, NO)]; void *pa = solid(W, H, ca); blit_upload(ta, 0, 0, pa, W*4, W, H, W*H*4); free(pa);
      id<MTLTexture> tb2 = [D newTextureWithDescriptor:desc(MTLPixelFormatRGBA8Unorm, W, H, NO)]; void *pb = solid(W, H, cb); blit_upload(tb2, 0, 0, pb, W*4, W, H, W*H*4); free(pb);
      [ts addObject:ta]; [ts addObject:tb2];
      for (int i = 0; i < 2; i++) { ra[i].t = ta.gpuResourceID; ra[i].s = smp.gpuResourceID; rb[i].t = tb2.gpuResourceID; rb[i].s = smp.gpuResourceID; }
      id<MTLBuffer> big = [D newBufferWithLength:4 << 20 options:MTLResourceStorageModeShared];
      memcpy((char *)big.contents + 4096, ra, sizeof ra); memcpy((char *)big.contents + (1 << 20), rb, sizeof rb);
      NSError *err = nil; MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
      pd.vertexFunction = [LIB newFunctionWithName:@"vtx"]; pd.fragmentFunction = [LIB newFunctionWithName:@"f_rid"]; pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
      id<MTLRenderPipelineState> pso = [D newRenderPipelineStateWithDescriptor:pd error:&err];
      MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = RT; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
      id<MTLCommandBuffer> cb0 = [Q commandBuffer]; id<MTLRenderCommandEncoder> e = [cb0 renderCommandEncoderWithDescriptor:rp];
      [e setRenderPipelineState:pso]; for (id t in ts) [e useResource:t usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
      [e setFragmentBuffer:big offset:4096 atIndex:0]; [e setViewport:(MTLViewport){0, 0, 128, 256, 0, 1}]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      [e setFragmentBufferOffset:(1 << 20) atIndex:0]; [e setViewport:(MTLViewport){128, 0, 128, 256, 0, 1}]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      [e endEncoding]; [cb0 commit]; [cb0 waitUntilCompleted];
      NSData *img = readback(RT); uint32_t left = px(img, 256, 60, 128), right = px(img, 256, 200, 128);
      CHECK(close3(left, ca, 1), "26a first draw (offset 4096): 0x%08x want 0x%08x", left, ca);
      CHECK(close3(right, cb, 1), "26b second draw after setFragmentBufferOffset: 0x%08x want 0x%08x", right, cb);
      // 26c: the same with the buffer re-bound by setFragmentBuffer:offset: for the second draw
      cb0 = [Q commandBuffer]; e = [cb0 renderCommandEncoderWithDescriptor:rp]; [e setRenderPipelineState:pso]; for (id t in ts) [e useResource:t usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
      [e setFragmentBuffer:big offset:4096 atIndex:0]; [e setViewport:(MTLViewport){0, 0, 128, 256, 0, 1}]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      [e setFragmentBuffer:big offset:(1 << 20) atIndex:0]; [e setViewport:(MTLViewport){128, 0, 128, 256, 0, 1}]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      [e endEncoding]; [cb0 commit]; [cb0 waitUntilCompleted];
      img = readback(RT); right = px(img, 256, 200, 128);
      CHECK(close3(right, cb, 1), "26c second draw after setFragmentBuffer:offset: re-bind: 0x%08x want 0x%08x", right, cb); }
    // 27: the GPU reads a shared buffer region, the CPU then overwrites it, the GPU reads it again (stale GPU cache?)
    { uint32_t ca = rgba(31,41,59), cb = rgba(26,53,58), cc = rgba(97,93,23); NSMutableArray *ts = [NSMutableArray new]; Res r[2];
      id<MTLTexture> t[3]; uint32_t cols[3] = { ca, cb, cc };
      for (int i = 0; i < 3; i++) { t[i] = [D newTextureWithDescriptor:desc(MTLPixelFormatRGBA8Unorm, W, H, NO)]; void *px_ = solid(W, H, cols[i]); blit_upload(t[i], 0, 0, px_, W*4, W, H, W*H*4); free(px_); [ts addObject:t[i]]; }
      id<MTLBuffer> big = [D newBufferWithLength:8 << 20 options:MTLResourceStorageModeShared];
      const NSUInteger off = 3 << 20; r[0].t = t[0].gpuResourceID; r[0].s = smp.gpuResourceID; r[1] = r[0];
      memcpy((char *)big.contents + off, r, sizeof r); g_tableOffset = off;
      uint32_t got = draw(@"f_rid", big, nil, ts, MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, ca, 1), "27a first read of the region: 0x%08x want 0x%08x", got, ca);
      r[0].t = t[1].gpuResourceID; r[1] = r[0]; memcpy((char *)big.contents + off, r, sizeof r);
      got = draw(@"f_rid", big, nil, ts, MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, cb, 1), "27b CPU overwrote the same bytes, GPU re-read: 0x%08x want 0x%08x (stale if 0x%08x)", got, cb, ca);
      // the same, with a GPU write (blit) touching a neighbouring line in between, and with the texture handle also changed via a second table copy
      r[0].t = t[2].gpuResourceID; r[1] = r[0]; memcpy((char *)big.contents + off, r, sizeof r);
      for (int k = 0; k < 3; k++) { got = draw(@"f_rid", big, nil, ts, MTLPixelFormatRGBA8Unorm); }
      CHECK(close3(got, cc, 1), "27c third overwrite, read three times: 0x%08x want 0x%08x", got, cc);
      // 27d: the first-ever read happens while the region is still ZERO (as the game's tables are at bind time), then the CPU fills it
      const NSUInteger off2 = 5 << 20; g_tableOffset = off2;
      got = draw(@"f_rid", big, nil, ts, MTLPixelFormatRGBA8Unorm);
      printf("  27d: read of a zero table -> 0x%08x (dummy)\n", got);
      r[0].t = t[1].gpuResourceID; r[1] = r[0]; memcpy((char *)big.contents + off2, r, sizeof r);
      got = draw(@"f_rid", big, nil, ts, MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, cb, 1), "27d region first read as zeros, then filled by the CPU, read again: 0x%08x want 0x%08x", got, cb);
      g_tableOffset = 0; }
    // 28: the 16-byte block formats and the float formats, each a 1-layer 2D array (as the game makes them), blit-uploaded
    { struct { const char *name; MTLPixelFormat f; NSUInteger bpb, bw; uint8_t blk[16]; uint32_t want; int tol; } cases[] = {
        // BC7 mode 6, endpoints (200,100,50,255) with p-bits 1, all indices 0 -> solid (201,101,51)
        { "BC7", MTLPixelFormatBC7_RGBAUnorm, 16, 4, {0}, rgba(201,101,51), 3 },
        // BC3: alpha block a0=a1=255 idx 0 + BC1 block yellow
        { "BC3", MTLPixelFormatBC3_RGBA, 16, 4, {0xFF,0xFF,0,0,0,0,0,0, 0xE0,0xFF,0xE0,0xFF,0,0,0,0}, rgba(255,255,0), 4 },
        // BC4: r0=r1=120, idx 0 -> red 120
        { "BC4", MTLPixelFormatBC4_RUnorm, 8, 4, {120,120,0,0,0,0,0,0}, rgba(120,0,0), 2 },
        // BC5: r 120, g 60
        { "BC5", MTLPixelFormatBC5_RGUnorm, 16, 4, {120,120,0,0,0,0,0,0, 60,60,0,0,0,0,0,0}, rgba(120,60,0), 2 },
    };
    // BC7 mode 6 block: bit 6 = mode; then R0 R1 G0 G1 B0 B1 A0 A1 (7 bits each), P0 P1, 63 index bits (0)
    { uint64_t lo = 0, hi = 0; int bit = 0; 
      #define PUT(v,n) do { for (int k = 0; k < (n); k++, bit++) { uint64_t b = ((uint64_t)(v) >> k) & 1; if (bit < 64) lo |= b << bit; else hi |= b << (bit - 64); } } while (0)
      PUT(1u << 6, 7); PUT(100, 7); PUT(100, 7); PUT(50, 7); PUT(50, 7); PUT(25, 7); PUT(25, 7); PUT(127, 7); PUT(127, 7); PUT(1, 1); PUT(1, 1);
      #undef PUT
      memcpy(cases[0].blk, &lo, 8); memcpy(cases[0].blk + 8, &hi, 8); }
    for (unsigned k = 0; k < sizeof cases / sizeof cases[0]; k++) {
      MTLTextureDescriptor *td = desc(cases[k].f, 64, 64, NO); td.textureType = MTLTextureType2DArray; td.arrayLength = 1;
      id<MTLTexture> t = [D newTextureWithDescriptor:td]; if (!t) { CHECK(0, "28 %s texture created", cases[k].name); continue; }
      NSUInteger bw = 64 / cases[k].bw, nb = bw * bw; uint8_t *buf = malloc(nb * cases[k].bpb); for (NSUInteger i = 0; i < nb; i++) memcpy(buf + i * cases[k].bpb, cases[k].blk, cases[k].bpb);
      blit_upload(t, 0, 0, buf, bw * cases[k].bpb, 64, 64, nb * cases[k].bpb); free(buf);
      uint32_t got = draw(@"f_arr0", table(t, smp), nil, @[t], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, cases[k].want, cases[k].tol), "28 %s 2D-array(1) blit + texture2d_array sample: 0x%08x want ~0x%08x", cases[k].name, got, cases[k].want); }
    }
    // float formats: RGBA16F and R11G11B10F solid (0.5, 0.25, 0.125)
    { MTLTextureDescriptor *td = desc(MTLPixelFormatRGBA16Float, 64, 64, NO); td.textureType = MTLTextureType2DArray; td.arrayLength = 1; id<MTLTexture> t = [D newTextureWithDescriptor:td];
      uint16_t h[4] = { 0x3800, 0x3400, 0x3000, 0x3C00 }; uint16_t *buf = malloc(64*64*8); for (int i = 0; i < 64*64; i++) memcpy(buf + i*4, h, 8);
      blit_upload(t, 0, 0, buf, 64*8, 64, 64, 64*64*8); free(buf);
      uint32_t got = draw(@"f_arr0", table(t, smp), nil, @[t], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, rgba(128,64,32), 2), "28 RGBA16F 2D-array(1): 0x%08x want ~0x%08x", got, rgba(128,64,32));
      MTLTextureDescriptor *td2 = desc(MTLPixelFormatRG11B10Float, 64, 64, NO); td2.textureType = MTLTextureType2DArray; td2.arrayLength = 1; id<MTLTexture> t2 = [D newTextureWithDescriptor:td2];
      if (t2) { uint32_t v = (0x380u) | (0x340u << 11) | (0x180u << 22); uint32_t *b2 = malloc(64*64*4); for (int i = 0; i < 64*64; i++) b2[i] = v;   // 11-bit floats: 0.5, 0.25; 10-bit: 0.125
        blit_upload(t2, 0, 0, b2, 64*4, 64, 64, 64*64*4); free(b2);
        got = draw(@"f_arr0", table(t2, smp), nil, @[t2], MTLPixelFormatRGBA8Unorm);
        CHECK(close3(got, rgba(128,64,32), 3), "28 R11G11B10F 2D-array(1): 0x%08x want ~0x%08x", got, rgba(128,64,32)); } }
    // 29: video planes: R8 1920x1088 and 960x544 one-layer 2D arrays filled with replaceRegion (odd row sizes), sampled at 4 points
    { NSUInteger sizes[2][2] = { {1920, 1088}, {960, 544} };
      for (int k = 0; k < 2; k++) { NSUInteger w = sizes[k][0], h = sizes[k][1];
        MTLTextureDescriptor *td = desc(MTLPixelFormatR8Unorm, w, h, NO); td.textureType = MTLTextureType2DArray; td.arrayLength = 1; td.storageMode = MTLStorageModeShared;
        id<MTLTexture> t = [D newTextureWithDescriptor:td];
        uint8_t *p = malloc(w * h); for (NSUInteger y = 0; y < h; y++) for (NSUInteger x = 0; x < w; x++) p[y*w+x] = (uint8_t)((x * 255) / (w - 1) / 2 + (y < h/2 ? 0 : 128));   // left->right ramp, bottom half +128
        [t replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 slice:0 withBytes:p bytesPerRow:w bytesPerImage:w*h]; free(p);
        // sample the whole texture into the 256x256 target, then check 4 points
        uint32_t got = draw(@"f_arr0", table(t, sampler(MTLSamplerMipFilterNotMipmapped, 0, 0)), nil, @[t], MTLPixelFormatRGBA8Unorm);
        NSData *img = readback(RT);
        uint32_t tl = px(img, 256, 8, 8) & 0xFF, tr = px(img, 256, 247, 8) & 0xFF, bl = px(img, 256, 8, 247) & 0xFF, br = px(img, 256, 247, 247) & 0xFF;
        CHECK(tl < 12 && tr > 110 && tr < 135 && bl > 118 && bl < 142 && br > 240, "29 R8 %lux%lu replaceRegion: corners tl %u tr %u bl %u br %u (want ~0 ~124 ~128 ~251; centre 0x%08x)", (unsigned long)w, (unsigned long)h, tl, tr, bl, br, got); } }
    // 30: texture queries on a 1-layer 2D array (width/height/array size) and integer-coordinate reads
    { MTLTextureDescriptor *td = desc(MTLPixelFormatR8Unorm, 1920, 1088, NO); td.textureType = MTLTextureType2DArray; td.arrayLength = 1; td.storageMode = MTLStorageModeShared;
      id<MTLTexture> t = [D newTextureWithDescriptor:td]; uint8_t *p = malloc(1920*1088); for (int y = 0; y < 1088; y++) for (int x = 0; x < 1920; x++) p[y*1920+x] = (uint8_t)((x / 8) & 0xFF);
      [t replaceRegion:MTLRegionMake2D(0,0,1920,1088) mipmapLevel:0 slice:0 withBytes:p bytesPerRow:1920 bytesPerImage:1920*1088]; free(p);
      uint32_t got = draw(@"f_qsize", table(t, smp), nil, @[t], MTLPixelFormatRGBA8Unorm);
      unsigned w = (got & 0xFF) * 4096 / 255, h = ((got >> 8) & 0xFF) * 4096 / 255, a = ((got >> 16) & 0xFF) * 16 / 255;
      CHECK(w > 1900 && w < 1940 && h > 1070 && h < 1105 && a == 1, "30a get_width/get_height/get_array_size on 1920x1088x1: %u x %u x %u (0x%08x)", w, h, a, got);
      got = draw(@"f_aread", table(t, smp), nil, @[t], MTLPixelFormatRGBA8Unorm); NSData *img = readback(RT);
      uint32_t c128 = px(img, 256, 128, 128) & 0xFF, c200 = px(img, 256, 200, 128) & 0xFF;
      CHECK(c128 > 110 && c128 < 130 && c200 > 180 && c200 < 195, "30b read() with coords from get_width: x=128 -> %u (want ~120), x=200 -> %u (want ~187)", c128, c200); }
    // 11 array, 12 cube
    { MTLTextureDescriptor *td = desc(MTLPixelFormatRGBA8Unorm, W, H, NO); td.textureType = MTLTextureType2DArray; td.arrayLength = 2; id<MTLTexture> t = [D newTextureWithDescriptor:td];
      void *p0 = solid(W, H, rgba(11,12,13)), *p1 = solid(W, H, rgba(150,160,170)); blit_upload(t, 0, 0, p0, W*4, W, H, W*H*4); blit_upload(t, 0, 1, p1, W*4, W, H, W*H*4); free(p0); free(p1);
      uint32_t slice = 1; id<MTLBuffer> sb = [D newBufferWithBytes:&slice length:4 options:MTLResourceStorageModeShared];
      uint32_t got = draw(@"f_arr", table(t, smp), sb, @[t], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, rgba(150,160,170), 1), "11 texture2d_array slice 1: 0x%08x want 0x%08x", got, rgba(150,160,170));
      MTLTextureDescriptor *cd = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm size:W mipmapped:NO]; cd.usage = MTLTextureUsageShaderRead; cd.storageMode = MTLStorageModePrivate;
      id<MTLTexture> c = [D newTextureWithDescriptor:cd];
      for (NSUInteger f = 0; f < 6; f++) { void *p = solid(W, W, rgba(20*f+5, 20*f+6, 20*f+7)); blit_upload(c, 0, f, p, W*4, W, W, W*W*4); free(p); }
      got = draw(@"f_cube", table(c, smp), nil, @[c], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, rgba(85,86,87), 1), "12 texturecube +Z face (4): 0x%08x want 0x%08x", got, rgba(85,86,87)); }
    // 15 anisotropic sampler
    { id<MTLTexture> t = [D newTextureWithDescriptor:desc(MTLPixelFormatRGBA8Unorm, W, H, YES)];
      for (NSUInteger l = 0; l < 4; l++) { NSUInteger w = W >> l, h = H >> l; void *p = solid(w, h, rgba(33,44,55)); blit_upload(t, l, 0, p, w*4, w, h, w*h*4); free(p); }
      uint32_t got = draw(@"f_rid", table(t, sampler(MTLSamplerMipFilterLinear, 0, 16)), nil, @[t], MTLPixelFormatRGBA8Unorm);
      CHECK(close3(got, rgba(33,44,55), 1), "15 anisotropy 16 + linear mips: 0x%08x want 0x%08x", got, rgba(33,44,55)); }
    printf("%d failure(s)\n", fails); return fails; } }
