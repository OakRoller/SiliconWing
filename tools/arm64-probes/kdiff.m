// kdiff.m: run one compute kernel from a metallib on the default Metal device with deterministic synthetic inputs and
// dump every resource it can write, so the same kernel can be compared between the Apple GPU and the NVIDIA one.
//   kdiff <lib.metallib> <outdir> [gridX gridY gridZ] [tgX tgY tgZ]
// Bindings come from the pipeline's reflection: argument buffers are filled member by member through an argument
// encoder (textures of the reflected type and data type, samplers, buffer pointers), plain buffers get a pattern except
// ones named spvDynamicOffsets / *Offsets (zeros). Floats are a hash of (resource, element) in [0.05, 1.0]; textures are
// RGBA32 of the reflected data type, depth textures Depth32Float. KDIFF_BUF=int fills buffers with small integers
// (0..15) instead, for kernels that take loop counts from them. Output: <outdir>/r<N>.bin per resource plus
// <outdir>/index.txt (one line per resource: kind, size, mean, non-finite count).
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static float pat(unsigned res, unsigned i) { uint32_t h = res * 2654435761u ^ (i + 0x9e3779b9u) * 2246822519u; h ^= h >> 15; h *= 2654435761u; h ^= h >> 13;
    return 0.05f + 0.95f * (float)(h & 0xffffff) / (float)0xffffff; }

typedef struct { const char *kind; id res; unsigned w, h, d, bpp; MTLDataType dt; } Res;
static Res g_res[256]; static unsigned g_nres;

static id<MTLTexture> make_texture(id<MTLDevice> dev, id<MTLCommandQueue> q, MTLTextureType tt, MTLDataType dt, BOOL depth, unsigned W, unsigned H, unsigned D) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = tt == MTLTextureType2DMultisample ? MTLTextureType2D : tt;
    td.width = W; td.height = (tt == MTLTextureType1D) ? 1 : H;
    td.depth = tt == MTLTextureType3D ? D : 1;
    td.arrayLength = (tt == MTLTextureType2DArray || tt == MTLTextureTypeCubeArray) ? D : 1;
    if (tt == MTLTextureTypeCube || tt == MTLTextureTypeCubeArray) td.height = td.width;
    td.pixelFormat = depth ? MTLPixelFormatDepth32Float : dt == MTLDataTypeUInt ? MTLPixelFormatRGBA32Uint : dt == MTLDataTypeInt ? MTLPixelFormatRGBA32Sint : MTLPixelFormatRGBA32Float;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite; td.storageMode = MTLStorageModePrivate;
    if (depth) td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    if (!t) return nil;
    const unsigned slices = (unsigned)(td.arrayLength * ((tt == MTLTextureTypeCube || tt == MTLTextureTypeCubeArray) ? 6 : 1));
    const unsigned bpp = depth ? 4 : 16, w = (unsigned)td.width, h = (unsigned)td.height, d = (unsigned)td.depth;
    const size_t plane = (size_t)w * h * bpp;
    id<MTLBuffer> src = [dev newBufferWithLength:plane * d * slices options:MTLResourceStorageModeShared];
    const unsigned rid = g_nres;
    if (depth) { float *f = src.contents; for (size_t i = 0; i < plane * d * slices / 4; i++) f[i] = pat(rid, (unsigned)i); }
    else if (dt == MTLDataTypeUInt || dt == MTLDataTypeInt) { uint32_t *u = src.contents; for (size_t i = 0; i < plane * d * slices / 4; i++) u[i] = (uint32_t)(pat(rid, (unsigned)i) * 64.0f); }
    else { float *f = src.contents; for (size_t i = 0; i < plane * d * slices / 4; i++) f[i] = pat(rid, (unsigned)i); }
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    for (unsigned s = 0; s < slices; s++)
        [b copyFromBuffer:src sourceOffset:plane * d * s sourceBytesPerRow:w * bpp sourceBytesPerImage:plane sourceSize:MTLSizeMake(w, h, d)
                toTexture:t destinationSlice:s destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
    g_res[g_nres++] = (Res){ "tex", t, w, h, d * slices, bpp, dt };
    return t;
}

static id<MTLBuffer> make_buffer(id<MTLDevice> dev, NSUInteger len, BOOL zero) {
    if (len < 256) len = 256;
    id<MTLBuffer> b = [dev newBufferWithLength:len options:MTLResourceStorageModeShared];
    const unsigned rid = g_nres; float *f = b.contents;
    static int ints = -1; if (ints < 0) { const char *e = getenv("KDIFF_BUF"); ints = e && !strcmp(e, "int"); }
    for (NSUInteger i = 0; i < len / 4; i++) {
        if (zero) f[i] = 0.0f;
        else if (ints) ((uint32_t *)f)[i] = (uint32_t)(pat(rid, (unsigned)i) * 16.0f);
        else f[i] = pat(rid, (unsigned)i);
    }
    g_res[g_nres++] = (Res){ "buf", b, (unsigned)len, 1, 1, 1, MTLDataTypeFloat };
    return b;
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: kdiff lib.metallib outdir [gx gy gz] [tx ty tz]\n"); return 2; }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    // KDIFF_DEVICE=<substring>: pick that device from MTLCopyAllDevices (the default one follows the main display)
    const char *want = getenv("KDIFF_DEVICE");
    if (want && *want) {
        id<MTLDevice> pick = nil;
        for (id<MTLDevice> d in MTLCopyAllDevices()) if ([d.name rangeOfString:@(want)].location != NSNotFound) { pick = d; break; }
        if (!pick) { printf("no device matching '%s'\n", want); return 1; }
        dev = pick;
    }
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&err];
    if (!lib) { printf("library: %s\n", err.localizedDescription.UTF8String); return 1; }
    id<MTLFunction> fn = nil;
    for (NSString *n in lib.functionNames) { id<MTLFunction> f = [lib newFunctionWithName:n]; if (f.functionType == MTLFunctionTypeKernel) { fn = f; break; } }
    if (!fn) { printf("no kernel in library\n"); return 1; }
    MTLAutoreleasedComputePipelineReflection refl = nil;
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:fn options:MTLPipelineOptionArgumentInfo reflection:&refl error:&err];
    if (!ps) { printf("pipeline: %s\n", err.localizedDescription.UTF8String); return 1; }
    id<MTLCommandQueue> q = [dev newCommandQueue];
    const unsigned W = 64, H = 64, D = 8;
    NSMutableArray *bindBuf = [NSMutableArray new], *bindTex = [NSMutableArray new], *bindSmp = [NSMutableArray new];
    NSMutableArray *used = [NSMutableArray new];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = sd.tAddressMode = sd.rAddressMode = MTLSamplerAddressModeClampToEdge; sd.supportArgumentBuffers = YES;
    id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:sd];
    if (getenv("KDIFF_REFL")) for (MTLArgument *a in refl.arguments) {
        printf("arg '%s' type %ld index %lu active %d", a.name.UTF8String, (long)a.type, (unsigned long)a.index, a.active);
        if (a.type == MTLArgumentTypeBuffer) {
            printf(" dataSize %lu elemArgBuf %d\n", (unsigned long)a.bufferDataSize, a.bufferPointerType.elementIsArgumentBuffer);
            for (MTLStructMember *m in a.bufferStructType.members)
            {
                printf("   member '%s' dataType %ld argIndex %lu offset %lu\n", m.name.UTF8String, (long)m.dataType, (unsigned long)m.argumentIndex, (unsigned long)m.offset);
                MTLPointerType *pt = m.dataType == MTLDataTypePointer ? m.pointerType : nil;
                if (pt) {
                    printf("      ptr elem %ld access %ld align %lu dataSize %lu elemIsArgBuf %d struct %s\n", (long)pt.elementType, (long)pt.access, (unsigned long)pt.alignment,
                           (unsigned long)pt.dataSize, pt.elementIsArgumentBuffer, pt.elementStructType ? "yes" : "nil");
                    for (MTLStructMember *e in pt.elementStructType.members)
                        printf("        '%s' type %ld offset %lu\n", e.name.UTF8String, (long)e.dataType, (unsigned long)e.offset);
                }
            }
        } else printf("\n");
    }
    for (MTLArgument *a in refl.arguments) {
        if (!a.active && a.type != MTLArgumentTypeBuffer) continue;
        if (a.type == MTLArgumentTypeBuffer) {
            MTLPointerType *pt = a.bufferPointerType;
            if (pt.elementIsArgumentBuffer) {
                id<MTLArgumentEncoder> ae = [fn newArgumentEncoderWithBufferIndex:a.index];
                id<MTLBuffer> ab = [dev newBufferWithLength:MAX(ae.encodedLength, 16) options:MTLResourceStorageModeShared];
                [ae setArgumentBuffer:ab offset:0];
                for (MTLStructMember *m in a.bufferStructType.members) {
                    if (m.dataType == MTLDataTypeTexture) {
                        MTLTextureReferenceType *tr = m.textureReferenceType;
                        id<MTLTexture> t = make_texture(dev, q, tr.textureType, tr.textureDataType, tr.isDepthTexture, W, H, D);
                        if (t) { [ae setTexture:t atIndex:m.argumentIndex]; [used addObject:t]; }
                    } else if (m.dataType == MTLDataTypeSampler) {
                        [ae setSamplerState:smp atIndex:m.argumentIndex];
                    } else if (m.dataType == MTLDataTypePointer) {
                        NSUInteger len = m.pointerType.dataSize ? m.pointerType.dataSize * 4 : 65536; if (len < 65536) len = 65536;
                        id<MTLBuffer> b = make_buffer(dev, len, NO);
                        [ae setBuffer:b offset:0 atIndex:m.argumentIndex]; [used addObject:b];
                    }
                }
                [bindBuf addObject:@[@(a.index), ab]];
            } else {
                const char *nm = a.name.UTF8String ?: "";
                BOOL zero = strstr(nm, "Offsets") != NULL;
                [bindBuf addObject:@[@(a.index), make_buffer(dev, MAX(a.bufferDataSize, (NSUInteger)65536), zero)]];
            }
        } else if (a.type == MTLArgumentTypeTexture) {
            id<MTLTexture> t = make_texture(dev, q, a.textureType, a.textureDataType, a.isDepthTexture, W, H, D);
            if (t) [bindTex addObject:@[@(a.index), t]];
        } else if (a.type == MTLArgumentTypeSampler) {
            [bindSmp addObject:@[@(a.index), smp]];
        }
    }
    MTLSize grid = MTLSizeMake(argc > 5 ? atoi(argv[3]) : W, argc > 5 ? atoi(argv[4]) : H, argc > 5 ? atoi(argv[5]) : 1);
    NSUInteger tw = ps.threadExecutionWidth, th = MAX((NSUInteger)1, ps.maxTotalThreadsPerThreadgroup / tw);
    MTLSize tg = argc > 8 ? MTLSizeMake(atoi(argv[6]), atoi(argv[7]), atoi(argv[8])) : MTLSizeMake(MIN(tw, (NSUInteger)8), MIN(th, (NSUInteger)8), 1);
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:ps];
    for (NSArray *b in bindBuf) [e setBuffer:b[1] offset:0 atIndex:[b[0] unsignedIntegerValue]];
    for (NSArray *t in bindTex) [e setTexture:t[1] atIndex:[t[0] unsignedIntegerValue]];
    for (NSArray *s in bindSmp) [e setSamplerState:s[1] atIndex:[s[0] unsignedIntegerValue]];
    for (id r in used) [e useResource:r usage:MTLResourceUsageRead | MTLResourceUsageWrite];
    [e dispatchThreads:grid threadsPerThreadgroup:tg];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    printf("device %s | kernel %s | grid %lux%lux%lu tg %lux%lux%lu | status %ld %s\n", dev.name.UTF8String, fn.name.UTF8String,
           (unsigned long)grid.width, (unsigned long)grid.height, (unsigned long)grid.depth, (unsigned long)tg.width, (unsigned long)tg.height,
           (unsigned long)tg.depth, (long)cb.status, cb.error ? cb.error.localizedDescription.UTF8String : "");
    NSString *od = @(argv[2]); [[NSFileManager defaultManager] createDirectoryAtPath:od withIntermediateDirectories:YES attributes:nil error:nil];
    FILE *ix = fopen([od stringByAppendingPathComponent:@"index.txt"].UTF8String, "w");
    for (unsigned r = 0; r < g_nres; r++) {
        NSData *data = nil;
        if (!strcmp(g_res[r].kind, "buf")) { id<MTLBuffer> b = g_res[r].res; data = [NSData dataWithBytes:b.contents length:b.length]; }
        else {
            id<MTLTexture> t = g_res[r].res; const unsigned slices = (unsigned)(t.arrayLength * (t.textureType == MTLTextureTypeCube || t.textureType == MTLTextureTypeCubeArray ? 6 : 1));
            const size_t plane = (size_t)t.width * t.height * g_res[r].bpp, total = plane * t.depth * slices;
            id<MTLBuffer> rb = [dev newBufferWithLength:total options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> c2 = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [c2 blitCommandEncoder];
            for (unsigned s = 0; s < slices; s++)
                [b copyFromTexture:t sourceSlice:s sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(t.width, t.height, t.depth)
                          toBuffer:rb destinationOffset:plane * t.depth * s destinationBytesPerRow:t.width * g_res[r].bpp destinationBytesPerImage:plane];
            [b endEncoding]; [c2 commit]; [c2 waitUntilCompleted];
            data = [NSData dataWithBytes:rb.contents length:total];
        }
        [data writeToFile:[od stringByAppendingPathComponent:[NSString stringWithFormat:@"r%u.bin", r]] atomically:YES];
        const float *f = data.bytes; size_t n = data.length / 4, bad = 0; double sum = 0;
        for (size_t i = 0; i < n; i++) { if (isfinite(f[i])) sum += f[i]; else bad++; }
        fprintf(ix, "r%u %s %ux%ux%u bytes %lu mean %.6g nonfinite %lu\n", r, g_res[r].kind, g_res[r].w, g_res[r].h, g_res[r].d, (unsigned long)data.length, n ? sum / n : 0, (unsigned long)bad);
    }
    fclose(ix);
    return 0;
} }
