// mtltime.m: GPU timeline of a Metal app on Apple's own GPU, to compare with the plugin's passtime "rec" / "cb" lines.
// Inserted with DYLD_INSERT_LIBRARIES (non-hardened apps). Every command buffer's commit gets a completed handler that
// records GPUStartTime / GPUEndTime; presentDrawable: calls count frames. A window of MTLTIME_WIN_S seconds (default 8)
// opens once 10 consecutive 2-second buckets had >= 30 command buffers per presented frame (the same trigger as
// cp-ptrun.sh: the benchmark is running). The window's records go to $MTLTIME_OUT (default /tmp/mtltime-<pid>.log):
//   cb <gpuStart s> <gpuEnd s>        (CACurrentMediaTime clock)
//   frame <present call time s>
// MTLTIME_ENC=1 (per-encoder timing): encoders made in the window get counter samples at stage boundaries (Apple GPUs
// sample there, not between draws) and are written when their command buffer completes, keyed as passtime keys them:
//   enc r <w> <h> <vkfmt> 0 <vs0> <vs1> <fs0> <fs1>   render: colour 0's VkFormat (plugin mapping), else 1000 + depth's;
//                                                      vertex and fragment stage start/end (raw GPU timestamps)
//   enc c 0 0 9001 <dispatches> <t0> <t1>             compute encoder
//   enc b 0 0 9002 <ops> <t0> <t1>                    blit encoder
//   cal <CACurrentMediaTime s> <GPU timestamp>        calibration pairs (sampleTimestamps:gpuTimestamp:)
// MTLTIME_OPEN_AFTER_S=<s> (tests): open the window <s> seconds after the first commit instead.
// Build: tools/arm64-probes/mkmtltime.sh (regenerates mtlfmt.inc from plugin/NVMTLDevice.m)
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <unistd.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <vulkan/vulkan_core.h>
#include "mtlfmt.inc"

static FILE *g_out; static double g_win_start = -1, g_win_end = -1, g_win_len = 8;
static _Atomic unsigned g_cbs, g_frames; static double g_bucket_t0; static int g_good;
static os_unfair_lock g_lk = OS_UNFAIR_LOCK_INIT;
static int g_enc; static id<MTLCounterSet> g_tset; static os_unfair_lock g_plk = OS_UNFAIR_LOCK_INIT;
static _Atomic unsigned long long g_nenc, g_nlost;
static __thread int t_in;   // inside one of our hooks: calls into the originals pass straight through

static void mt_write(const char *s)
{
    os_unfair_lock_lock(&g_lk);
    if (g_out) { fputs(s, g_out); }
    os_unfair_lock_unlock(&g_lk);
}
static double mach_s(uint64_t t) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)t * tb.numer / tb.denom / 1e9; }
static void mt_cal(id<MTLDevice> dev)
{
    MTLTimestamp c = 0, g = 0; [dev sampleTimestamps:&c gpuTimestamp:&g];
    char line[96]; snprintf(line, sizeof line, "cal %.9f %llu\n", mach_s(c), (unsigned long long)g); mt_write(line);
}
static int in_window(void) { const double now = CACurrentMediaTime(); return g_win_start >= 0 && now >= g_win_start && now < g_win_end; }

static void mt_tick(double now)
{
    // 2-second buckets of command buffers per presented frame, until the window opens
    if (g_win_start >= 0) return;
    static double after = -2, first; if (after == -2) { const char *e = getenv("MTLTIME_OPEN_AFTER_S"); after = e ? atof(e) : -1; }
    if (!first) first = now;
    if (after >= 0) { if (now - first >= after) { g_win_start = now; g_win_end = now + g_win_len; fprintf(stderr, "mtltime: window open for %.0f s (MTLTIME_OPEN_AFTER_S)\n", g_win_len); } return; }
    if (g_bucket_t0 == 0) { g_bucket_t0 = now; return; }
    if (now - g_bucket_t0 < 2.0) return;
    const unsigned c = atomic_exchange(&g_cbs, 0), f = atomic_exchange(&g_frames, 0);
    g_bucket_t0 = now;
    g_good = (f && c >= 30u * f) ? g_good + 1 : 0;
    if (g_good >= 10) { g_win_start = now; g_win_end = now + g_win_len; fprintf(stderr, "mtltime: window open for %.0f s\n", g_win_len); }
}

// ---- per-encoder records ------------------------------------------------------------------------------------------------
#define MT_MAXE 256
typedef struct { char kind; uint32_t w, h, fmt, ops, s0; } mt_enc;
typedef struct { uint32_t used, n; mt_enc e[MT_MAXE]; } mt_cbrec;
@interface MTRec : NSObject { @public mt_cbrec r; id<MTLCounterSampleBuffer> sb; } @end
@implementation MTRec @end
@interface MTEncTag : NSObject { @public MTRec *rec; uint32_t idx; } @end
@implementation MTEncTag @end
static char k_rec, k_tag;

// one ring of samples for every command buffer (Metal allows only a few sample buffers per process): an encoder claims
// consecutive samples; the ring is long enough that a slot is resolved long before it comes round again
static id<MTLCounterSampleBuffer> g_ring; static uint32_t g_ring_n, g_ring_at;
static id<MTLCounterSampleBuffer> ring_get(id<MTLDevice> dev)
{
    os_unfair_lock_lock(&g_plk);
    if (!g_ring) for (uint32_t n = 32768; n >= 2048 && !g_ring; n /= 2) {
        MTLCounterSampleBufferDescriptor *d = [MTLCounterSampleBufferDescriptor new];
        d.counterSet = g_tset; d.storageMode = MTLStorageModeShared; d.sampleCount = n;
        NSError *err = nil; g_ring = [dev newCounterSampleBufferWithDescriptor:d error:&err];
        if (g_ring) { g_ring_n = n; fprintf(stderr, "mtltime: sample ring of %u\n", n); }
        else if (n == 2048) fprintf(stderr, "mtltime: counter sample buffer FAILED: %s\n", err.localizedDescription.UTF8String);
    }
    os_unfair_lock_unlock(&g_plk);
    return g_ring;
}
static int ring_claim(uint32_t n)
{
    os_unfair_lock_lock(&g_plk);
    if (g_ring_at + n > g_ring_n) g_ring_at = 0;
    const int s = (int)g_ring_at; g_ring_at += n;
    os_unfair_lock_unlock(&g_plk);
    return s;
}

// a slot of n samples for a new encoder of command buffer cb, or -1 (no sampling for it)
static int enc_slot(id<MTLCommandBuffer> cb, uint32_t n, MTRec **out)
{
    if (!g_enc || !in_window()) return -1;
    if (!ring_get(cb.device)) return -1;
    MTRec *rec = objc_getAssociatedObject(cb, &k_rec);
    if (!rec) { rec = [MTRec new]; rec->sb = g_ring; objc_setAssociatedObject(cb, &k_rec, rec, OBJC_ASSOCIATION_RETAIN); }
    if (rec->r.n >= MT_MAXE) { atomic_fetch_add(&g_nlost, 1); return -1; }
    *out = rec; rec->r.used += n; return ring_claim(n);
}
static void enc_tag(id enc, MTRec *rec, char kind, uint32_t w, uint32_t h, uint32_t fmt, uint32_t s0)
{
    mt_enc *e = &rec->r.e[rec->r.n]; e->kind = kind; e->w = w; e->h = h; e->fmt = fmt; e->ops = 0; e->s0 = s0;
    MTEncTag *t = [MTEncTag new]; t->rec = rec; t->idx = rec->r.n++;
    objc_setAssociatedObject(enc, &k_tag, t, OBJC_ASSOCIATION_RETAIN);
    atomic_fetch_add(&g_nenc, 1);
}
static void enc_op(id enc)
{
    if (!g_enc) return;
    MTEncTag *t = objc_getAssociatedObject(enc, &k_tag);
    if (t) t->rec->r.e[t->idx].ops++;
}
static uint32_t render_key(MTLRenderPassDescriptor *d, uint32_t *w, uint32_t *h)
{
    id<MTLTexture> t = d.colorAttachments[0].texture; uint32_t vk = 0, bpp = 0, asp = 0; int a8 = 0; NSUInteger lvl = d.colorAttachments[0].level;
    if (t) { if (nvmtl_pixfmt(t.pixelFormat, &vk, &bpp, &a8)) vk = 100000 + (uint32_t)t.pixelFormat; }
    else { t = d.depthAttachment.texture ? d.depthAttachment.texture : d.stencilAttachment.texture; lvl = t == d.depthAttachment.texture ? d.depthAttachment.level : d.stencilAttachment.level;
           if (t) vk = 1000 + (nvmtl_depthfmt(t.pixelFormat, &vk, &asp) ? 99000 + (uint32_t)t.pixelFormat : vk); }
    *w = t ? (uint32_t)MAX(t.width >> lvl, 1) : (uint32_t)d.renderTargetWidth; *h = t ? (uint32_t)MAX(t.height >> lvl, 1) : (uint32_t)d.renderTargetHeight;
    return vk;
}

static IMP o_rdesc, o_prdesc, o_comp, o_compt, o_compd, o_blit, o_blitd;
static id mt_rdesc_x(id self, SEL _cmd, MTLRenderPassDescriptor *d, IMP orig)
{
    MTRec *rec = nil; int s;
    if (t_in || !d || (s = enc_slot(self, 4, &rec)) < 0) return ((id (*)(id, SEL, id))orig)(self, _cmd, d);
    MTLRenderPassDescriptor *c = [d copy];
    MTLRenderPassSampleBufferAttachmentDescriptor *a = c.sampleBufferAttachments[0];
    a.sampleBuffer = rec->sb; a.startOfVertexSampleIndex = s; a.endOfVertexSampleIndex = s + 1;
    a.startOfFragmentSampleIndex = s + 2; a.endOfFragmentSampleIndex = s + 3;
    t_in = 1; id enc = ((id (*)(id, SEL, id))orig)(self, _cmd, c); t_in = 0;
    if (enc) { uint32_t w = 0, h = 0, f = render_key(d, &w, &h); enc_tag(enc, rec, 'r', w, h, f, (uint32_t)s); }
    return enc;
}
static id mt_rdesc(id self, SEL _cmd, MTLRenderPassDescriptor *d) { return mt_rdesc_x(self, _cmd, d, o_rdesc); }
static id mt_prdesc(id self, SEL _cmd, MTLRenderPassDescriptor *d) { return mt_rdesc_x(self, _cmd, d, o_prdesc); }
static id mt_compute_with(id self, MTLDispatchType type, MTLComputePassDescriptor *given)
{
    MTRec *rec = nil; const int s = enc_slot(self, 2, &rec);
    if (s < 0) return nil;
    MTLComputePassDescriptor *c = given ? [given copy] : [MTLComputePassDescriptor computePassDescriptor];
    if (!given) c.dispatchType = type;
    MTLComputePassSampleBufferAttachmentDescriptor *a = c.sampleBufferAttachments[0];
    a.sampleBuffer = rec->sb; a.startOfEncoderSampleIndex = s; a.endOfEncoderSampleIndex = s + 1;
    t_in = 1; id enc = ((id (*)(id, SEL, id))o_compd)(self, @selector(computeCommandEncoderWithDescriptor:), c); t_in = 0;
    if (enc) enc_tag(enc, rec, 'c', 0, 0, 9001, (uint32_t)s);
    return enc;
}
static id mt_comp(id self, SEL _cmd) { id e = t_in ? nil : mt_compute_with(self, MTLDispatchTypeSerial, nil); return e ? e : ((id (*)(id, SEL))o_comp)(self, _cmd); }
static id mt_compt(id self, SEL _cmd, MTLDispatchType t) { id e = t_in ? nil : mt_compute_with(self, t, nil); return e ? e : ((id (*)(id, SEL, MTLDispatchType))o_compt)(self, _cmd, t); }
static id mt_compd(id self, SEL _cmd, MTLComputePassDescriptor *d) { id e = (t_in || !d) ? nil : mt_compute_with(self, 0, d); return e ? e : ((id (*)(id, SEL, id))o_compd)(self, _cmd, d); }
static id mt_blit_with(id self, MTLBlitPassDescriptor *given)
{
    MTRec *rec = nil; const int s = enc_slot(self, 2, &rec);
    if (s < 0) return nil;
    MTLBlitPassDescriptor *c = given ? [given copy] : [MTLBlitPassDescriptor blitPassDescriptor];
    MTLBlitPassSampleBufferAttachmentDescriptor *a = c.sampleBufferAttachments[0];
    a.sampleBuffer = rec->sb; a.startOfEncoderSampleIndex = s; a.endOfEncoderSampleIndex = s + 1;
    t_in = 1; id enc = ((id (*)(id, SEL, id))o_blitd)(self, @selector(blitCommandEncoderWithDescriptor:), c); t_in = 0;
    if (enc) enc_tag(enc, rec, 'b', 0, 0, 9002, (uint32_t)s);
    return enc;
}
static id mt_blit(id self, SEL _cmd) { id e = t_in ? nil : mt_blit_with(self, nil); return e ? e : ((id (*)(id, SEL))o_blit)(self, _cmd); }
static id mt_blitd(id self, SEL _cmd, MTLBlitPassDescriptor *d) { id e = (t_in || !d) ? nil : mt_blit_with(self, d); return e ? e : ((id (*)(id, SEL, id))o_blitd)(self, _cmd, d); }

// op counters: swizzled per selector, the original IMP kept in a small table keyed by selector
#define MT_NOPS 16
static SEL g_opsel[MT_NOPS]; static IMP g_opimp[MT_NOPS]; static int g_nops;
static IMP op_orig(SEL s) { for (int i = 0; i < g_nops; i++) if (g_opsel[i] == s) return g_opimp[i]; return NULL; }
static void op1(id self, SEL s, id a) { enc_op(self); ((void (*)(id, SEL, id))op_orig(s))(self, s, a); }
static void op_d2(id self, SEL s, MTLSize a, MTLSize b) { enc_op(self); ((void (*)(id, SEL, MTLSize, MTLSize))op_orig(s))(self, s, a, b); }
static void op_ind(id self, SEL s, id b, NSUInteger o, MTLSize t) { enc_op(self); ((void (*)(id, SEL, id, NSUInteger, MTLSize))op_orig(s))(self, s, b, o, t); }
static void op_bb(id self, SEL s, id a, NSUInteger ao, id b, NSUInteger bo, NSUInteger n) { enc_op(self); ((void (*)(id, SEL, id, NSUInteger, id, NSUInteger, NSUInteger))op_orig(s))(self, s, a, ao, b, bo, n); }
static void op_fill(id self, SEL s, id b, NSRange r, uint8_t v) { enc_op(self); ((void (*)(id, SEL, id, NSRange, uint8_t))op_orig(s))(self, s, b, r, v); }
static void op_tt(id self, SEL s, id a, id b) { enc_op(self); ((void (*)(id, SEL, id, id))op_orig(s))(self, s, a, b); }
static void op_tt8(id self, SEL s, id a, NSUInteger as, NSUInteger al, MTLOrigin ao, MTLSize sz, id b, NSUInteger bs, NSUInteger bl, MTLOrigin bo)
{ enc_op(self); ((void (*)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, MTLOrigin))op_orig(s))(self, s, a, as, al, ao, sz, b, bs, bl, bo); }
static void op_bt(id self, SEL s, id a, NSUInteger ao, NSUInteger rb, NSUInteger ib, MTLSize sz, id b, NSUInteger bs, NSUInteger bl, MTLOrigin bo)
{ enc_op(self); ((void (*)(id, SEL, id, NSUInteger, NSUInteger, NSUInteger, MTLSize, id, NSUInteger, NSUInteger, MTLOrigin))op_orig(s))(self, s, a, ao, rb, ib, sz, b, bs, bl, bo); }
static void op_tb(id self, SEL s, id a, NSUInteger as, NSUInteger al, MTLOrigin ao, MTLSize sz, id b, NSUInteger bo, NSUInteger rb, NSUInteger ib)
{ enc_op(self); ((void (*)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, NSUInteger))op_orig(s))(self, s, a, as, al, ao, sz, b, bo, rb, ib); }
static void swz_op(Class c, SEL s, IMP mine)
{
    Method m = class_getInstanceMethod(c, s);
    if (!m || g_nops >= MT_NOPS) return;
    g_opsel[g_nops] = s; g_opimp[g_nops++] = method_setImplementation(m, mine);
}

static void mt_flush(MTRec *rec)
{
    if (!rec || !rec->sb || !rec->r.n) return;
    char line[192];
    for (uint32_t i = 0; i < rec->r.n; i++) {
        const mt_enc *e = &rec->r.e[i]; const uint32_t k = e->kind == 'r' ? 4 : 2;
        NSData *d = [rec->sb resolveCounterRange:NSMakeRange(e->s0, k)];
        const MTLCounterResultTimestamp *ts = (const MTLCounterResultTimestamp *)d.bytes - e->s0;
        if (d.length < k * sizeof *ts) continue;
        if (k == 4) snprintf(line, sizeof line, "enc r %u %u %u 0 %llu %llu %llu %llu\n", e->w, e->h, e->fmt,
                             (unsigned long long)ts[e->s0].timestamp, (unsigned long long)ts[e->s0 + 1].timestamp,
                             (unsigned long long)ts[e->s0 + 2].timestamp, (unsigned long long)ts[e->s0 + 3].timestamp);
        else snprintf(line, sizeof line, "enc %c 0 0 %u %u %llu %llu\n", e->kind, e->fmt, e->ops,
                      (unsigned long long)ts[e->s0].timestamp, (unsigned long long)ts[e->s0 + 1].timestamp);
        mt_write(line);
    }
    rec->r.n = 0;
}

static IMP g_orig_commit, g_orig_present;
static void mt_commit(id self, SEL _cmd)
{
    const double now = CACurrentMediaTime();
    atomic_fetch_add(&g_cbs, 1); mt_tick(now);
    if (g_win_start >= 0 && now >= g_win_start && now < g_win_end) {
        static double last_cal; if (now - last_cal > 0.5) { last_cal = now; mt_cal([(id<MTLCommandBuffer>)self device]); }
        MTRec *rec = objc_getAssociatedObject(self, &k_rec);
        [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> cb) {
            const double a = cb.GPUStartTime, b = cb.GPUEndTime;
            if (a > 0 && b > 0) { char line[96]; snprintf(line, sizeof line, "cb %.9f %.9f\n", a, b); mt_write(line); }
            mt_flush(rec);
        }];
    } else if (g_win_start >= 0 && now >= g_win_end) {
        static int closed; if (!closed) { closed = 1; mt_cal([(id<MTLCommandBuffer>)self device]);
            os_unfair_lock_lock(&g_lk); if (g_out) fflush(g_out); os_unfair_lock_unlock(&g_lk);
            fprintf(stderr, "mtltime: window closed (%llu encoders timed, %llu not)\n", (unsigned long long)g_nenc, (unsigned long long)g_nlost); }
        MTRec *rec = objc_getAssociatedObject(self, &k_rec);   // encoders begun in the window, committed after it
        if (rec) [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> cb) { mt_flush(rec); }];
    }
    ((void (*)(id, SEL))g_orig_commit)(self, _cmd);
}
static void mt_present(id self, SEL _cmd, id drawable)
{
    const double now = CACurrentMediaTime();
    atomic_fetch_add(&g_frames, 1);
    if (g_win_start >= 0 && now >= g_win_start && now < g_win_end) { char line[64]; snprintf(line, sizeof line, "frame %.9f\n", now); mt_write(line); }
    ((void (*)(id, SEL, id))g_orig_present)(self, _cmd, drawable);
}
static IMP swz(Class c, SEL s, IMP mine) { Method m = class_getInstanceMethod(c, s); return m ? method_setImplementation(m, mine) : NULL; }
__attribute__((constructor)) static void mt_init(void)
{
    unsetenv("DYLD_INSERT_LIBRARIES");   // children (system helpers) must not inherit it
    const char *w = getenv("MTLTIME_WIN_S"); if (w && atof(w) > 0) g_win_len = atof(w);
    char path[512]; const char *o = getenv("MTLTIME_OUT");
    if (o && *o) snprintf(path, sizeof path, "%s", o); else snprintf(path, sizeof path, "/tmp/mtltime-%d.log", (int)getpid());
    g_out = fopen(path, "w");
    // the concrete command-buffer class is private (AGX...CommandBuffer): make one and swizzle the methods it resolves to
    // (only those: a [super commit] inside reaches the superclass's own, untouched method)
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
    Class c = object_getClass(cb);
    g_orig_commit = swz(c, @selector(commit), (IMP)mt_commit);
    g_orig_present = swz(c, @selector(presentDrawable:), (IMP)mt_present);
    const char *e = getenv("MTLTIME_ENC");
    if (e && e[0] == '1') {
        for (id<MTLCounterSet> s in dev.counterSets) if ([s.name isEqualToString:MTLCommonCounterSetTimestamp]) g_tset = s;
        if (!g_tset || ![dev supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) fprintf(stderr, "mtltime: no timestamp counters at stage boundaries - encoders not timed\n");
        else {
            o_rdesc = swz(c, @selector(renderCommandEncoderWithDescriptor:), (IMP)mt_rdesc);
            o_prdesc = swz(c, @selector(parallelRenderCommandEncoderWithDescriptor:), (IMP)mt_prdesc);
            o_compd = swz(c, @selector(computeCommandEncoderWithDescriptor:), (IMP)mt_compd);
            o_comp = swz(c, @selector(computeCommandEncoder), (IMP)mt_comp);
            o_compt = swz(c, @selector(computeCommandEncoderWithDispatchType:), (IMP)mt_compt);
            o_blitd = swz(c, @selector(blitCommandEncoderWithDescriptor:), (IMP)mt_blitd);
            o_blit = swz(c, @selector(blitCommandEncoder), (IMP)mt_blit);
            // op counters on the concrete encoder classes (made through the originals, never committed)
            id<MTLCommandBuffer> cb2 = [q commandBuffer];
            t_in = 1;
            id<MTLComputeCommandEncoder> ce = [cb2 computeCommandEncoderWithDispatchType:MTLDispatchTypeConcurrent]; Class cc = object_getClass(ce); [ce endEncoding];
            id<MTLBlitCommandEncoder> be = [cb2 blitCommandEncoder]; Class bc = object_getClass(be); [be endEncoding];
            t_in = 0;
            swz_op(cc, @selector(dispatchThreadgroups:threadsPerThreadgroup:), (IMP)op_d2);
            swz_op(cc, @selector(dispatchThreads:threadsPerThreadgroup:), (IMP)op_d2);
            swz_op(cc, @selector(dispatchThreadgroupsWithIndirectBuffer:indirectBufferOffset:threadsPerThreadgroup:), (IMP)op_ind);
            swz_op(bc, @selector(copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:), (IMP)op_bb);
            swz_op(bc, @selector(fillBuffer:range:value:), (IMP)op_fill);
            swz_op(bc, @selector(copyFromTexture:toTexture:), (IMP)op_tt);
            swz_op(bc, @selector(generateMipmapsForTexture:), (IMP)op1);
            swz_op(bc, @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:), (IMP)op_tt8);
            swz_op(bc, @selector(copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:), (IMP)op_bt);
            swz_op(bc, @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:), (IMP)op_tb);
            g_enc = o_rdesc && o_compd && o_blitd;
            fprintf(stderr, "mtltime: per-encoder timing %s (%d op counters; compute %s, blit %s)\n", g_enc ? "ON" : "UNAVAILABLE", g_nops,
                    class_getName(cc), class_getName(bc));
        }
    }
    fprintf(stderr, "mtltime: %s on %s - commit %s, presentDrawable: %s, output %s\n", class_getName(c), dev.name.UTF8String,
            g_orig_commit ? "hooked" : "MISSING", g_orig_present ? "hooked" : "MISSING", path);
}
