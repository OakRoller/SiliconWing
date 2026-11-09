/*
 * NullMoth NVIDIA driver for macOS
 * Copyright (c) 2026 NullMoth Systems.
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

void nvlog(const char *fmt, ...);

#import "NVMTLObjects.h"
#import <objc/runtime.h>
#import <objc/message.h>
static int nvmtl_trace_on(void);
static void nvtrace_emit(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
// Guard the call site: converting NSString arguments on every draw is expensive
// even when the trace writer immediately returns without emitting anything.
#define nvtrace(...) do { if (nvmtl_trace_on()) nvtrace_emit(__VA_ARGS__); } while (0)
// An object the app binds that this driver did not make (another device's buffer or texture, or something that is not a
// resource at all) must never be cast to our classes: reading _b/_i out of a foreign object produced a garbage VkBuffer
// handle that NVK dereferenced (Unreal Editor 5.8, SIGBUS in nvk_UpdateDescriptorSets, 2026-11-03). Such a binding is
// logged with its class and ignored, as Metal itself would reject a resource from another device.
static NVMTLBuffer *nvmtl_as_buffer(id b, const char *where) {
    if (!b || [b isKindOfClass:[NVMTLBuffer class]]) return (NVMTLBuffer *)b;
    static int said; if (said++ < 16) {
        id dev = [b respondsToSelector:@selector(device)] ? [b device] : nil;
        nvlog("%s: %s is not this driver's buffer (device %s) - IGNORED", where, object_getClassName(b), dev ? [[dev name] UTF8String] : "?"); }
    return nil;
}
static NVMTLTexture *nvmtl_as_texture(id t, const char *where) {
    if (!t || [t isKindOfClass:[NVMTLTexture class]]) return (NVMTLTexture *)t;
    static int said; if (said++ < 16) {
        id dev = [t respondsToSelector:@selector(device)] ? [t device] : nil;
        nvlog("%s: %s is not this driver's texture (device %s) - IGNORED", where, object_getClassName(t), dev ? [[dev name] UTF8String] : "?"); }
    return nil;
}

// A private lock, not @synchronized on the object: the object is the app's (a command buffer, an encoder), and an app that
// holds @synchronized on it while it waits for the scheduled handler deadlocked against the Metal HUD, which asks for the ID
// from that handler (Unity games with MetalForceHudEnabled: Soulstone Survivors hung on a black screen at start).
static unsigned long long nvmtl_global_trace_id(id o) {
    static char key; static unsigned long long next = 1; static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    NSNumber *n = objc_getAssociatedObject(o, &key);
    if (!n) { n = @(__atomic_fetch_add(&next, 1, __ATOMIC_RELAXED)); objc_setAssociatedObject(o, &key, n, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    const unsigned long long id = n.unsignedLongLongValue;
    os_unfair_lock_unlock(&lock);
    return id;
}
@protocol NVMTLFunctionConstantInit
- (instancetype)initWithName:(NSString *)name type:(NSUInteger)type index:(NSUInteger)index required:(BOOL)required;
@end
static MTLDataType nvmtl_air_fc_type(NSString *t) {
    static NSDictionary *base; static dispatch_once_t once;
    dispatch_once(&once, ^{ base = @{ @"float": @(MTLDataTypeFloat), @"half": @(MTLDataTypeHalf), @"bfloat": @(MTLDataTypeBFloat),
        @"int": @(MTLDataTypeInt), @"uint": @(MTLDataTypeUInt), @"short": @(MTLDataTypeShort), @"ushort": @(MTLDataTypeUShort),
        @"char": @(MTLDataTypeChar), @"uchar": @(MTLDataTypeUChar), @"bool": @(MTLDataTypeBool),
        @"long": @(MTLDataTypeLong), @"ulong": @(MTLDataTypeULong) }; });
    NSNumber *b = base[t];
    if (b) return (MTLDataType)b.unsignedIntegerValue;
    unichar last = t.length > 1 ? [t characterAtIndex:t.length - 1] : 0;
    if (last >= '2' && last <= '4' && (b = base[[t substringToIndex:t.length - 1]]))
        return (MTLDataType)(b.unsignedIntegerValue + (NSUInteger)(last - '1'));
    return MTLDataTypeNone;
}
#include <CommonCrypto/CommonDigest.h>

#define NVMTL_SET_VERTEX   0u
#define NVMTL_SET_FRAGMENT 1u

@class NVMTLBuffer;
static void nvmtl_buffer_sync_in(NVMTLBuffer *b);
@class NVMTLCommandBuffer;
static void nvmtl_buffer_sync_out(NVMTLBuffer *b);
static void nvbt(const char *tag, int *count, int max) {
    if (*count >= max) return; (*count)++;
    extern const char *nvmtl_log_path(void);
    FILE *f = fopen(nvmtl_log_path(), "a"); if (!f) return;
    NSArray *syms = [NSThread callStackSymbols];
    fprintf(f, "pid %d NVMTL: BT %s #%d (%lu frames)\n", getpid(), tag, *count, (unsigned long)syms.count);
    for (NSUInteger i = 1; i < syms.count && i < 14; i++) fprintf(f, "pid %d NVMTL:    %s\n", getpid(), [syms[i] UTF8String]);
    fclose(f);
}
static int g_bt_status, g_bt_enqueue, g_bt_handler, g_bt_release, g_bt_commit;
@class NVMTLCommandBuffer, NVMTLBuffer, NVMTLTexture;
static int nvmtl_upverify_live(void);
extern __thread const char *nvmtl_snap_name;
int nvmtl_probe_armed(void);
static uint32_t nvmtl_dl_fn(id fn);
static _Atomic unsigned g_cs_from = ~0u, g_cs_until; static FILE *g_cs_file; static os_unfair_lock g_cs_lock = OS_UNFAIR_LOCK_INIT;
extern _Atomic unsigned nvmtl_flick_frame;
static int nvmtl_census_on(unsigned *frOut)
{
    static _Atomic uint64_t nextCheck;
    const unsigned fr = atomic_load_explicit(&nvmtl_flick_frame, memory_order_relaxed); *frOut = fr;
    const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now >= atomic_load(&nextCheck)) {
        atomic_store(&nextCheck, now + 250000000ull);
        if (access("/tmp/nvmtl-census", F_OK) == 0) {
            int cnt = 600, delay = 0; FILE *pf = fopen("/tmp/nvmtl-census", "r"); if (pf) { if (fscanf(pf, "%d %d", &cnt, &delay) < 1) cnt = 600; fclose(pf); }
            unlink("/tmp/nvmtl-census");
            if (cnt < 1 || cnt > 5000) cnt = 600; if (delay < 0 || delay > 100000) delay = 0;
            os_unfair_lock_lock(&g_cs_lock);
            if (!g_cs_file) { char path[600]; snprintf(path, sizeof path, "%s/Library/Logs/nvmtl/census-%d.txt", getenv("HOME") ?: "/tmp", (int)getpid()); g_cs_file = fopen(path, "a"); }
            os_unfair_lock_unlock(&g_cs_lock);
            atomic_store(&g_cs_from, fr + (unsigned)delay); atomic_store(&g_cs_until, fr + (unsigned)delay + (unsigned)cnt);
            nvlog_diag("census: armed at frame %u - every draw and dispatch of frames %u..%u -> census-%d.txt", fr, fr + (unsigned)delay, fr + (unsigned)delay + (unsigned)cnt, (int)getpid());
        }
    }
    const int on = g_cs_file && fr >= atomic_load(&g_cs_from) && fr < atomic_load(&g_cs_until);
    if (!on && g_cs_file && fr >= atomic_load(&g_cs_until) && atomic_load(&g_cs_until)) { os_unfair_lock_lock(&g_cs_lock); if (g_cs_file) fflush(g_cs_file); os_unfair_lock_unlock(&g_cs_lock); }
    return on;
}
static void nvmtl_census_line(const char *line)
{
    os_unfair_lock_lock(&g_cs_lock); if (g_cs_file) fputs(line, g_cs_file); os_unfair_lock_unlock(&g_cs_lock);
}
static void nvmtl_probe_name_kernel(id ps)
{
    { unsigned fr; if (nvmtl_census_on(&fr)) {
        NVMTLComputePipelineState *k = (NVMTLComputePipelineState *)ps; char line[200];
        snprintf(line, sizeof line, "K f%u ks %08x %s\n", fr, k ? nvmtl_dl_fn(k->_function) : 0u, k && k->_function ? (k->_function->_fname.UTF8String ?: "-") : "-");
        nvmtl_census_line(line); } }
    if (!nvmtl_probe_armed()) return;
    static __thread char nm[160];
    NVMTLComputePipelineState *k = (NVMTLComputePipelineState *)ps;
    snprintf(nm, sizeof nm, "kernel %s | %s", k ? (k.label.UTF8String ?: "-") : "-", k && k->_function ? (k->_function->_fname.UTF8String ?: "-") : "-");
    nvmtl_snap_name = nm;
}
static void nvmtl_upverify(NVMTLCommandBuffer *cb, NVMTLBuffer *src, size_t so, uint32_t row, NVMTLTexture *t, uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t level, uint32_t layer);
static int nvmtl_texverify_live(void);
static os_unfair_lock g_ab_lock = OS_UNFAIR_LOCK_INIT; static NSHashTable *g_ab_bufs;
static void nvmtl_ab_register(NVMTLBuffer *b) {
    if (b->_abReg) return; b->_abReg = YES;
    os_unfair_lock_lock(&g_ab_lock); if (!g_ab_bufs) g_ab_bufs = [NSHashTable weakObjectsHashTable]; [g_ab_bufs addObject:b]; os_unfair_lock_unlock(&g_ab_lock);
}
extern _Atomic unsigned nvmtl_flick_frame;
static _Atomic uint64_t g_h_uses, g_h_useheap, g_h_early, g_h_late, g_h_neverfilled;
static int nvmtl_h_on(void) { static int v = -1; if (v < 0) { const char *e = getenv("NVMTL_FILL_ORDER"); v = e && *e == '1'; } return v; }
static inline void nvmtl_histcb(NVMTLTexture *t, char kind, NVMTLCommandBuffer *cb) {
    if (!t) return; NVMTLTexture *r = t->_parent ? t->_parent : t; const unsigned f = atomic_load_explicit(&nvmtl_flick_frame, memory_order_relaxed);
    switch (kind) { case 'U': r->_hUp++; break; case 'C': r->_hCopyIn++; break; case 'R': r->_hRT++; break; case 'M': r->_hMips++; break; case 'W': r->_hRepl++; break; }
    r->_hLastFill = f; r->_hLastKind = kind; r->_wGen++;
    if (!nvmtl_h_on() || r->_hFillSeq0) return;
    if (!cb) { r->_hFillSeq0 = 1; return; }
    if (r->_hFillCB == (__bridge void *)cb) return;
    r->_hFillCB = (__bridge void *)cb;
    @synchronized (cb) { if (!cb->_hFillList) cb->_hFillList = [NSMutableArray new]; [cb->_hFillList addObject:r]; }
}
#define nvmtl_hist(t, k) nvmtl_histcb((t), (k), NULL)
static NSHashTable *g_w_set; static os_unfair_lock g_w_lock = OS_UNFAIR_LOCK_INIT;
static _Atomic uint64_t g_w_checked, g_w_wiped, g_w_captured, g_w_rounds;
static int nvmtl_w_on(void) { static int v = -1; if (v < 0) { const char *e = getenv("NVMTL_WIPE_WATCH"); v = e && *e == '1'; if (v) nvlog("wipe watch: ON - every uploaded read-only texture is re-read in small samples about every 2 s and compared with what its upload left (NVMTL_WIPE_WATCH=0 turns it off)"); } return v; }
static void nvmtl_w_capture(NVMTLCommandBuffer *cb, NVMTLTexture *t, uint32_t level, uint32_t layer, uint32_t x, uint32_t y, uint32_t w, uint32_t h)
{
    if (!nvmtl_w_on() || !t) return;
    NVMTLTexture *r = t->_parent ? t->_parent : t; nvk_image *im = [r nvi];
    if (!im || !im->img || r->_surf || im->samples > 1 || (r->_usage & ~(NSUInteger)MTLTextureUsagePixelFormatView) != MTLTextureUsageShaderRead) return;
    const uint32_t bw = im->bw ? im->bw : 1, bh = im->bh ? im->bh : 1, bpp = im->bpp ? im->bpp : 4;
    uint32_t cols = 64 / bpp; if (!cols) return;
    uint32_t ww = cols * bw; if (ww > w) ww = w; const uint32_t hh = h < bh ? h : bh;
    const uint32_t len = ((ww + bw - 1) / bw) * bpp; if (!len || len > 64) return;
    nvk_buffer *b = calloc(1, sizeof *b); if (!b) return;
    if (nvmtl_vk_buffer_create(64, 1, b) || !b->map) { free(b); return; }
    if (nvmtl_vk_cmd_copy_image_to_buffer_level_layer(&cb->_c, im, x, y, ww, hh, b, 0, len, level, layer)) { nvmtl_vk_buffer_destroy(b); free(b); return; }
    const uint32_t gen = r->_wGen; const unsigned fr = atomic_load(&nvmtl_flick_frame);
    os_unfair_lock_lock(&g_w_lock); if (!g_w_set) g_w_set = [NSHashTable weakObjectsHashTable]; [g_w_set addObject:r]; os_unfair_lock_unlock(&g_w_lock);
    __weak NVMTLTexture *wr = r;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        NVMTLTexture *rr = wr;
        if (rr && done.status == MTLCommandBufferStatusCompleted && rr->_wGen == gen) {
            memcpy(rr->_wExp, b->map, len); rr->_wLen = len; rr->_wLevel = level; rr->_wLayer = layer; rr->_wX = x; rr->_wY = y; rr->_wW = ww; rr->_wH = hh;
            rr->_wExpGen = gen; rr->_wUpFrame = fr; rr->_wValid = YES; atomic_fetch_add(&g_w_captured, 1);
        }
        nvmtl_vk_buffer_destroy(b); free(b);
    }];
}
static void nvmtl_w_check(NVMTLCommandBuffer *cb)
{
    if (!nvmtl_w_on()) return;
    static _Atomic uint64_t next; const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    uint64_t nx = atomic_load(&next); if (now < nx || !atomic_compare_exchange_strong(&next, &nx, now + 250000000ull)) return;
    NSArray *all; os_unfair_lock_lock(&g_w_lock); all = g_w_set ? g_w_set.allObjects : nil; os_unfair_lock_unlock(&g_w_lock);
    if (!all.count) return;
    static NSUInteger cursor; const NSUInteger N = MIN((NSUInteger)2048, all.count);
    NSMutableArray *pick = [NSMutableArray arrayWithCapacity:N]; uint32_t gens[2048];
    for (NSUInteger k = 0; k < all.count && pick.count < N; k++) {
        NVMTLTexture *r = all[(cursor + k) % all.count];
        if (!r->_wValid || r->_wReported || r->_wGen != r->_wExpGen) continue;
        gens[pick.count] = r->_wGen; [pick addObject:r];
    }
    cursor = (cursor + N) % all.count;
    if (!pick.count) return;
    nvk_buffer *b = calloc(1, sizeof *b); if (!b) return;
    if (nvmtl_vk_buffer_create(pick.count * 64, 1, b) || !b->map) { free(b); return; }
    memset(b->map, 0xA5, pick.count * 64);
    NSMutableArray *ok = [NSMutableArray arrayWithCapacity:pick.count]; uint32_t okGen[2048], okSlot[2048];
    for (NSUInteger k = 0; k < pick.count; k++) {
        NVMTLTexture *r = pick[k];
        if (nvmtl_vk_cmd_copy_image_to_buffer_level_layer(&cb->_c, [r nvi], r->_wX, r->_wY, r->_wW, r->_wH, b, k * 64, r->_wLen, r->_wLevel, r->_wLayer)) continue;
        okGen[ok.count] = gens[k]; okSlot[ok.count] = (uint32_t)k; [ok addObject:r];
    }
    const unsigned fr = atomic_load(&nvmtl_flick_frame); const size_t n = ok.count;
    uint32_t *g2 = malloc(n * sizeof *g2 * 2); if (!g2) { nvmtl_vk_buffer_destroy(b); free(b); return; }
    memcpy(g2, okGen, n * sizeof *g2); memcpy(g2 + n, okSlot, n * sizeof *g2);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (done.status == MTLCommandBufferStatusCompleted) {
            atomic_fetch_add(&g_w_checked, n);
            for (size_t k = 0; k < n; k++) {
                NVMTLTexture *r = ok[k];
                if (r->_wGen != g2[k] || r->_wExpGen != g2[k]) continue;
                const uint8_t *got = (const uint8_t *)b->map + (size_t)g2[n + k] * 64;
                if (!memcmp(got, r->_wExp, r->_wLen)) continue;
                int zero = 1; for (uint32_t j = 0; j < r->_wLen; j++) if (got[j]) { zero = 0; break; }
                r->_wReported = 1; const uint64_t wn = atomic_fetch_add(&g_w_wiped, 1) + 1;
                char ov[300] = ""; size_t ol = 0;
                if (r->_heap) {
                    NSArray *peers; os_unfair_lock_lock(&g_w_lock); peers = g_w_set.allObjects; os_unfair_lock_unlock(&g_w_lock);
                    const NSUInteger a0 = r->_heapOffset, a1 = a0 + MAX((NSUInteger)1, (NSUInteger)[r nvi]->alloc);
                    for (NVMTLTexture *q in peers) {
                        if (q == r || q->_heap != r->_heap) continue;
                        const NSUInteger b0 = q->_heapOffset, b1 = b0 + MAX((NSUInteger)1, (NSUInteger)[q nvi]->alloc);
                        if (b0 < a1 && a0 < b1 && ol < sizeof ov - 80)
                            ol += (size_t)snprintf(ov + ol, sizeof ov - ol, " [%p fmt %lu %ux%u @+%lu born %u up %u]", (__bridge void *)q, (unsigned long)q->_fmt, [q nvi]->w, [q nvi]->h, (unsigned long)q->_heapOffset, q->_hBornFrame, q->_wUpFrame);
                    }
                }
                if (wn <= 2000)
                    nvlog_diag("wipe watch: WIPED at frame %u (checked in the frame-%u command buffer): texture %p fmt %lu %ux%u mips %u layers %u heap %p+%lu alloc %llu, born frame %u, sample L%u S%u (%u,%u %ux%u) captured after its upload at frame %u; now %s (%02x%02x%02x%02x%02x%02x%02x%02x, was %02x%02x%02x%02x%02x%02x%02x%02x); history uploads %u copies %u genmips %u RT %u; same-heap overlapping watched textures:%s [%llu wiped]",
                               atomic_load(&nvmtl_flick_frame), fr, (__bridge void *)r, (unsigned long)r->_fmt, [r nvi]->w, [r nvi]->h, [r nvi]->mips, [r nvi]->layers,
                               (__bridge void *)r->_heap, (unsigned long)r->_heapOffset, (unsigned long long)[r nvi]->alloc, r->_hBornFrame, r->_wLevel, r->_wLayer, r->_wX, r->_wY, r->_wW, r->_wH,
                               r->_wUpFrame, zero ? "ALL ZERO" : "DIFFERENT", got[0], got[1], got[2], got[3], got[4], got[5], got[6], got[7],
                               r->_wExp[0], r->_wExp[1], r->_wExp[2], r->_wExp[3], r->_wExp[4], r->_wExp[5], r->_wExp[6], r->_wExp[7],
                               r->_hUp, r->_hCopyIn, r->_hMips, r->_hRT, ol ? ov : " none", (unsigned long long)wn);
            }
        }
        const uint64_t rd = atomic_fetch_add(&g_w_rounds, 1) + 1;
        if (!(rd % 40)) nvlog_diag("wipe watch: %llu rounds, %llu samples checked, %llu uploads captured, %llu textures wiped, frame %u",
                                   (unsigned long long)rd, (unsigned long long)atomic_load(&g_w_checked), (unsigned long long)atomic_load(&g_w_captured), (unsigned long long)atomic_load(&g_w_wiped), atomic_load(&nvmtl_flick_frame));
        free(g2); nvmtl_vk_buffer_destroy(b); free(b);
    }];
}
static inline void nvmtl_huse(NVMTLCommandBuffer *cb, id res) {
    if (!nvmtl_h_on() || ![res isKindOfClass:[NVMTLTexture class]]) return;
    atomic_fetch_add_explicit(&g_h_uses, 1, memory_order_relaxed);
    NVMTLTexture *t = (NVMTLTexture *)res, *r = t->_parent ? t->_parent : t;
    if (r->_hFillSeq0 || r->_hEarlySeq || r->_surf || (r->_usage & ~(NSUInteger)MTLTextureUsagePixelFormatView) != MTLTextureUsageShaderRead) return;
    if (r->_hEarlyCB == (__bridge void *)cb) return;
    r->_hEarlyCB = (__bridge void *)cb;
    @synchronized (cb) { if (!cb->_hEarlyList) cb->_hEarlyList = [NSMutableArray new]; [cb->_hEarlyList addObject:r]; }
}
static void nvmtl_h_commit(NVMTLCommandBuffer *cb)
{
    if (!nvmtl_h_on()) return;
    const unsigned f = atomic_load_explicit(&nvmtl_flick_frame, memory_order_relaxed);
    NSArray *fills, *early; @synchronized (cb) { fills = cb->_hFillList; early = cb->_hEarlyList; cb->_hFillList = nil; cb->_hEarlyList = nil; }
    for (NVMTLTexture *r in fills) {
        if (r->_hFillSeq0) continue;
        r->_hFillSeq0 = cb->_commitSeq ? cb->_commitSeq : 1;
        if (r->_hEarlySeq) {
            const uint64_t n = atomic_fetch_add(&g_h_late, 1) + 1;
            if (n <= 3000)
                nvlog_diag("fill order: LATE FILL - texture %p fmt %lu %ux%u mips %u was first used by commit %llu at frame %u and first filled ('%c') by commit %llu at frame %u: %llu commits, %u frames later [%llu late]",
                           (__bridge void *)r, (unsigned long)r->_fmt, r->_i.w, r->_i.h, r->_i.mips, (unsigned long long)r->_hEarlySeq, r->_hEarlyFrame,
                           r->_hLastKind ? r->_hLastKind : '?', (unsigned long long)r->_hFillSeq0, f, (unsigned long long)(r->_hFillSeq0 - r->_hEarlySeq), f - r->_hEarlyFrame, (unsigned long long)n);
        }
    }
    for (NVMTLTexture *r in early) {
        if (r->_hFillSeq0 || r->_hEarlySeq) continue;
        r->_hEarlySeq = cb->_commitSeq ? cb->_commitSeq : 1; r->_hEarlyFrame = f;
        const uint64_t n = atomic_fetch_add(&g_h_early, 1) + 1;
        if (n <= 3000)
            nvlog_diag("fill order: USED BEFORE ANY FILL - commit %llu at frame %u uses read-only texture %p '%s' fmt %lu %ux%u mips %u layers %u heap %p+%lu (born frame %u; encoded fills so far: uploads %u copies %u genmips %u) [%llu early]",
                       (unsigned long long)r->_hEarlySeq, f, (__bridge void *)r, r->_label.UTF8String ?: "", (unsigned long)r->_fmt, r->_i.w, r->_i.h, r->_i.mips, r->_i.layers,
                       (__bridge void *)r->_heap, (unsigned long)r->_heapOffset, r->_hBornFrame, r->_hUp, r->_hCopyIn, r->_hMips, (unsigned long long)n);
    }
    static _Atomic uint64_t commits; const uint64_t c = atomic_fetch_add(&commits, 1) + 1;
    if (!(c % 4096))
        nvlog_diag("fill order: %llu commits, %llu texture uses (useResource / binds), %llu useHeap calls, %llu read-only textures used before any fill, %llu of them filled later, frame %u",
                   (unsigned long long)c, (unsigned long long)atomic_load(&g_h_uses), (unsigned long long)atomic_load(&g_h_useheap), (unsigned long long)atomic_load(&g_h_early), (unsigned long long)atomic_load(&g_h_late), f);
}
static void nvmtl_texverify(NVMTLCommandBuffer *cb, NVMTLTexture *s, uint32_t sl, uint32_t ss, uint32_t sx, uint32_t sy, NVMTLTexture *d, uint32_t dl, uint32_t ds, uint32_t dx, uint32_t dy, uint32_t w, uint32_t h);
#include <sys/stat.h>

static dispatch_semaphore_t g_oneenc_sem; static dispatch_once_t g_oneenc_once;
static __thread int g_oneenc_depth, g_oneenc_held;
static _Atomic int g_enc_open, g_enc_open_max;
static _Atomic uint64_t g_oneenc_takes, g_oneenc_timeouts, g_oneenc_waitus;
_Atomic uint64_t nvmtl_enc_census[4];
static int nvmtl_oneenc_live(void)
{
    static _Atomic uint64_t next; static _Atomic int on;
    const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now >= atomic_load(&next)) {
        atomic_store(&next, now + 500000000ull);
        struct stat st; const int v = stat("/tmp/nvmtl-oneenc", &st) == 0;
        if (v != atomic_exchange(&on, v))
            nvlog("oneenc: %s (/tmp/nvmtl-oneenc %s) - %s", v ? "ON" : "OFF", v ? "exists" : "gone",
                  v ? "one encoder at a time across all threads (a thread waits up to 50 ms, then goes ahead); the GPU is not waited for" : "encoders on several threads at once again");
    }
    return atomic_load(&on);
}
static void nvmtl_enc_begin(void)
{
    const int o = atomic_fetch_add(&g_enc_open, 1) + 1;
    if (o > atomic_load(&g_enc_open_max)) atomic_store(&g_enc_open_max, o);
    nvmtl_enc_census[0] = (uint64_t)atomic_load(&g_enc_open_max);
    if (o > 1) nvmtl_enc_census[1]++;
    if (g_oneenc_depth > 0) { g_oneenc_depth++; return; }
    if (!nvmtl_oneenc_live()) return;
    dispatch_once(&g_oneenc_once, ^{ g_oneenc_sem = dispatch_semaphore_create(1); });
    const uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    g_oneenc_depth = 1;
    g_oneenc_held = dispatch_semaphore_wait(g_oneenc_sem, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) == 0;
    atomic_fetch_add(&g_oneenc_waitus, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1000);
    const uint64_t k = atomic_fetch_add(&g_oneenc_takes, 1) + 1;
    if (!g_oneenc_held) atomic_fetch_add(&g_oneenc_timeouts, 1);
    if (!(k & (k - 1)) && k >= 64) nvlog("oneenc: %llu encoders serialised, %llu ms waited, %llu went ahead after 50 ms", (unsigned long long)k,
                                       (unsigned long long)(atomic_load(&g_oneenc_waitus) / 1000), (unsigned long long)atomic_load(&g_oneenc_timeouts));
}
static void nvmtl_enc_end(void)
{
    atomic_fetch_sub(&g_enc_open, 1);
    if (g_oneenc_depth > 0 && --g_oneenc_depth == 0 && g_oneenc_held) { g_oneenc_held = 0; dispatch_semaphore_signal(g_oneenc_sem); }
}

#pragma mark - buffer
static NSArray *nvmtl_vertex_attributes_for(NVMTLFunction *fn);
#include <os/lock.h>
static os_unfair_lock gManagedLock = OS_UNFAIR_LOCK_INIT;
static NSHashTable *gManagedDirty;
static _Atomic int gManagedAny;
static __thread int gManagedInFlush;
static os_unfair_lock gPurgeLock = OS_UNFAIR_LOCK_INIT;
static NSHashTable *gPurgeVol;
static _Atomic uint64_t gPurgeAsks;
extern void (*nvmtl_purge_report_hook)(const char *why);
static void nvmtl_purge_report(const char *why);

static _Atomic uint64_t gRes2Tick;
static void nvmtl_res2_note_use(NVMTLTexture *t);
static uint64_t nvmtl_res2_evict(uint64_t want);
extern uint64_t (*nvmtl_res2_evict_hook)(uint64_t want);
__attribute__((constructor)) static void nvmtl_conf_knobs(void)
{
#if NVMTL_RELEASE
    { extern char **environ; char *names[256]; unsigned n = 0;
      for (char **e = environ; e && *e && n < 256; e++)
          if (!strncmp(*e, "NVMTL_", 6) || !strncmp(*e, "NVK_", 4) || !strncmp(*e, "NAK_", 4) || !strncmp(*e, "NVRM_", 5)) {
              // Preserve the GL uniform path's per-process override and diagnostics.
              if (!strncmp(*e, "NVMTL_UNIFORM_CBUF=", 19)
                  || !strncmp(*e, "NVMTL_UNIFORM_CBUF_STATS=", 25)) continue;
              // Keep the switch that restores inline presents.
              if (!strncmp(*e, "NVMTL_PRESENT_INLINE=", 21)) continue;
              const char *eq = strchr(*e, '='); if (!eq) continue;
              names[n] = strndup(*e, (size_t)(eq - *e)); if (names[n]) n++; }
      for (unsigned i = 0; i < n; i++) { unsetenv(names[i]); free(names[i]); } }
#endif
    unsigned forgot = 0;
    { const char *rec = getenv("NVMTL_CONF_SET");
      if (rec && *rec) { char *dup = strdup(rec), *save = NULL;
          for (char *kv = dup ? strtok_r(dup, ";", &save) : NULL; kv; kv = strtok_r(NULL, ";", &save)) {
              char *eq = strchr(kv, '='); if (!eq) continue; *eq = 0;
              const char *now = getenv(kv);
              if (now && !strcmp(now, eq + 1)) { unsetenv(kv); forgot++; }
          }
          free(dup); }
      unsetenv("NVMTL_CONF_SET"); }
    char recbuf[2048]; size_t recn = 0; recbuf[0] = 0;
    FILE *f = fopen("/Library/GPUBundles/nvmtl/nvrm610.conf", "r");
    if (!f) { if (forgot) nvlog("conf: forgot %u inherited knob(s); no conf file", forgot); return; }
    char line[512];
    unsigned took = 0;
    // The last line for a key wins: the installer keeps the user's own block ("my settings, kept on update") at the end
    // of the file, and the first match used to win, so a shipped value of the same key above it silently beat the
    // user's (#399). Keys set by an earlier line of this file may be replaced; the real environment still wins.
    char fromFile[64][48]; unsigned nFromFile = 0;
    while (fgets(line, sizeof line, f)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || !*p) continue;
        char *eq = strchr(p, '=');
        if (!eq) continue;
        *eq = 0;
        char *key = p, *val = eq + 1;
        char *end = key + strlen(key);
        while (end > key && (end[-1] == ' ' || end[-1] == '\t')) *--end = 0;
        end = val + strlen(val);
        while (end > val && (end[-1] == '\n' || end[-1] == '\r' || end[-1] == ' ' || end[-1] == '\t')) *--end = 0;
        if (strncmp(key, "NVMTL_", 6) && strncmp(key, "NVK_", 4) && strncmp(key, "NVRM_", 5)) continue;
        bool ours = false;
        for (unsigned i = 0; i < nFromFile; i++) if (!strcmp(fromFile[i], key)) { ours = true; break; }
        if (getenv(key) && !ours) continue;
        if (setenv(key, val, 1) == 0) { if (ours) { nvlog("conf: %s=%s (a later line of the file replaces an earlier one)", key, val); continue; }
            took++;
            if (nFromFile < 64 && strlen(key) < sizeof fromFile[0]) strcpy(fromFile[nFromFile++], key); }
    }
    fclose(f);
    // NVMTL_CONF_SET records the values this file set, as they stand after every line, so a child process forgets
    // exactly these (an override recorded at its first value would no longer match and be kept as if user-set)
    for (unsigned i = 0; i < nFromFile; i++) {
        const char *v = getenv(fromFile[i]); if (!v) continue;
        int k = snprintf(recbuf + recn, sizeof recbuf - recn, "%s%s=%s", recn ? ";" : "", fromFile[i], v);
        if (k > 0 && (size_t)k < sizeof recbuf - recn) recn += (size_t)k; else { recbuf[recn] = 0; break; }
    }
    if (recn) setenv("NVMTL_CONF_SET", recbuf, 1);
    if (took || forgot) nvlog("conf: %u knob(s) read from /Library/GPUBundles/nvmtl/nvrm610.conf, %u inherited conf knob(s) forgotten first (the environment still wins)", took, forgot);
}
static int nvmtl_dontcare_clears(void) {
    static int on = -1;
    if (on < 0) { const char *e = getenv("NVMTL_DONTCARE_CLEARS"); on = (e && *e && *e != '0') ? 1 : 0; }
    return on;
}
static inline int nvmtl_load_keeps(MTLLoadAction a) {
    return a == MTLLoadActionLoad || (a == MTLLoadActionDontCare && !nvmtl_dontcare_clears());
}
static void nvmtl_res3_note_use(NVMTLBuffer *b);
static uint64_t nvmtl_ep_now(void);
static inline void nvmtl_res3_wait_move(int *rs) { while (__atomic_load_n(rs, __ATOMIC_ACQUIRE) == 2) sched_yield(); }
static void nvmtl_res2_kick(int scan);
static _Atomic int gRes2Scan;
static Class gNVMTLTexClass;
static inline void nvmtl_resref(id o, int d) {
    if (!gNVMTLTexClass) gNVMTLTexClass = [NVMTLTexture class];
    if (![o isKindOfClass:gNVMTLTexClass]) {
        static Class BC; if (!BC) BC = [NVMTLBuffer class];
        if (object_getClass(o) != BC) return;
        NVMTLBuffer *b = o;
        const int v = __atomic_add_fetch(&b->_resRefs, d, __ATOMIC_ACQ_REL);
        if (d > 0) { __atomic_store_n(&b->_useEp, nvmtl_ep_now(), __ATOMIC_RELEASE); nvmtl_res3_wait_move(&b->_rstate); nvmtl_res3_note_use(b); }
        else if (v == 0 && __atomic_load_n(&b->_wantOn, __ATOMIC_ACQUIRE)) nvmtl_res2_kick(1);
        return;
    }
    NVMTLTexture *t = o; if (t->_parent) t = t->_parent;
    const int v = __atomic_add_fetch(&t->_resRefs, d, __ATOMIC_ACQ_REL);
    if (d > 0) { __atomic_store_n(&t->_useEp, nvmtl_ep_now(), __ATOMIC_RELEASE); nvmtl_res3_wait_move(&t->_rstate);
                 nvmtl_res2_note_use(t); }
    else if (v == 0 && __atomic_load_n(&t->_wantOn, __ATOMIC_ACQUIRE)) nvmtl_res2_kick(1);
}
@implementation NVMTLResSet
- (instancetype)init { if ((self = [super init])) _s = [NSMutableSet new]; return self; }
- (instancetype)initWithCapacity:(NSUInteger)n { if ((self = [super init])) _s = [[NSMutableSet alloc] initWithCapacity:n]; return self; }
// 10-07 (a user's crash report, RTX 5060 Ti): Hackintool died in -[__NSSetM member:] under -addObject:, called
// from setFragmentTexture on CoreAnimation's async-render workqueue thread. NSMutableSet is not thread-safe and nothing
// here serialised it, so every operation now holds _lk. Enumeration hands out a snapshot, never the live set.
- (NSUInteger)count { os_unfair_lock_lock(&_lk); NSUInteger n = _s.count; os_unfair_lock_unlock(&_lk); return n; }
- (id)member:(id)o { os_unfair_lock_lock(&_lk); id m = [_s member:o]; os_unfair_lock_unlock(&_lk); return m; }
- (NSArray *)nvmtlSnapshot { os_unfair_lock_lock(&_lk); NSArray *a = _s.allObjects; os_unfair_lock_unlock(&_lk); return a; }
- (NSEnumerator *)objectEnumerator { return [[self nvmtlSnapshot] objectEnumerator]; }
// for-in runs only over a command buffer part's own copy (one thread), never over a set still being encoded into
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)st objects:(id __unsafe_unretained [])b count:(NSUInteger)n {
    return [_s countByEnumeratingWithState:st objects:b count:n]; }
// _mru: objects added lately, each in the set until it is removed (the set retains it, so its address cannot be reused
// while it is listed). Encoders add the same few buffers, pipelines and samplers draw after draw (Apple's GL rebinds its
// vertex, index and uniform buffers for every draw), and a hit skips the set's hash lookup.
- (void)addObject:(id)o { if (!o) return; const void *p = (__bridge const void *)o; os_unfair_lock_lock(&_lk);
    for (unsigned k = 0; k < 8; k++) if (_mru[k] == p) { os_unfair_lock_unlock(&_lk); return; }
    id member = [_s member:o]; BOOL had = member != nil;
    if (!had) { [_s addObject:o]; member = o; }
    // An equal object need not be the object retained by NSMutableSet. Cache only the retained member's address.
    _mru[_mruNext++ & 7] = (__bridge const void *)member;
    os_unfair_lock_unlock(&_lk); if (!had) nvmtl_resref(o, 1); }
- (void)removeObject:(id)o { if (!o) return; os_unfair_lock_lock(&_lk); id member = [_s member:o];
    if (member) [_s removeObject:member];
    for (unsigned k = 0; k < 8; k++) if (_mru[k] == (__bridge const void *)member) _mru[k] = NULL;
    os_unfair_lock_unlock(&_lk); if (member) nvmtl_resref(member, -1); }
// Clearing, copying and sealing never go through -allObjects. That array is autoreleased into the CALLER's pool, and
// these run on the app's own commit thread: Geekbench 7 never drains that pool, so every resource a command buffer had
// ever touched stayed alive, and Super Resolution filled VRAM with 9 MB MPS buffers until allocations were refused.
// The sets below are owned (+1) and released at the end of scope.
- (void)removeAllObjects { NSMutableSet *fresh = [NSMutableSet new], *old;
    os_unfair_lock_lock(&_lk); old = _s; _s = fresh; memset(_mru, 0, sizeof _mru); os_unfair_lock_unlock(&_lk);
    for (id o in old) nvmtl_resref(o, -1); }
- (id)copyWithZone:(NSZone *)z { atomic_fetch_add(&gRes2Tick, 1);
    NVMTLResSet *c = [NVMTLResSet new];
    os_unfair_lock_lock(&_lk); NSMutableSet *m = [_s mutableCopy]; os_unfair_lock_unlock(&_lk);
    c->_s = m;
    for (id o in m) nvmtl_resref(o, 1);
    return c; }
- (id)mutableCopyWithZone:(NSZone *)z { return [self copyWithZone:z]; }
// Moves every member into a new set and empties this one in a single locked step. Sealing a submission part used to
// copy and then clear in two steps, so a resource another thread bound in between was released by the clear without
// being in the part: the command buffer stopped holding it while the GPU work still used it. Membership moves to one
// new owner, so each resource's residency count is unchanged; the new set's -dealloc gives it back.
- (NVMTLResSet *)nvmtlTakeAll { atomic_fetch_add(&gRes2Tick, 1);
    NVMTLResSet *taken = [NVMTLResSet new]; NSMutableSet *empty = taken->_s;
    os_unfair_lock_lock(&_lk); taken->_s = _s; _s = empty; memset(_mru, 0, sizeof _mru); os_unfair_lock_unlock(&_lk);
    return taken; }
- (void)dealloc { for (id o in _s) nvmtl_resref(o, -1); }
@end

static BOOL nvmtl_purge_eligible(NVMTLTexture *t) {
    return !t->_parent && !t->_viewParent && !t->_backBuf && !t->_heap && !t->_subHeap && !t->_surf && !t->_vramOn && !t->_ownView
        && !t->_shareable && !t->_resid && !__atomic_load_n(&t->_nviews, __ATOMIC_ACQUIRE) && t->_i.img && !t->_i.placed
        && t->_i.usage && !t->_i.vfl && t->_i.samples <= 1 && !(t->_i.usage & 0x20u )
        // a swizzled sampling view (MTLTextureDescriptor.swizzle) is made against this VkImage; re-homing the memory
        // recreates the image and would leave that view pointing at the destroyed one
        && !t->_swzView;
}
static uint64_t nvmtl_purge_reclaim(uint64_t need) {
    NSArray *all = nil;
    os_unfair_lock_lock(&gPurgeLock); all = gPurgeVol.count ? gPurgeVol.allObjects : nil; os_unfair_lock_unlock(&gPurgeLock);
    if (!all.count) return 0;
    uint64_t freed = 0; unsigned n = 0, busy = 0, inel = 0, fail = 0;
    for (int pass = 0; pass < 2 && freed < need; pass++)
        for (id o in all) {
            if (freed >= need) break;
            if (![o isKindOfClass:[NVMTLTexture class]]) continue;
            NVMTLTexture *t = o;
            uint32_t st = pass ? MTLPurgeableStateVolatile : MTLPurgeableStateEmpty;
            if (__atomic_load_n(&t->_purge, __ATOMIC_ACQUIRE) != st || t->_i.sysmem) continue;
            if (!nvmtl_purge_eligible(t)) { inel++; continue; }
            int z = 0; if (!__atomic_compare_exchange_n(&t->_rstate, &z, 2, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) continue;
            uint32_t want = st;
            if (!__atomic_compare_exchange_n(&t->_purge, &want, (uint32_t)MTLPurgeableStateEmpty, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
                __atomic_store_n(&t->_rstate, 0, __ATOMIC_RELEASE); continue; }
            if (__atomic_load_n(&t->_resRefs, __ATOMIC_ACQUIRE)) {
                busy++; uint32_t e = MTLPurgeableStateEmpty;
                __atomic_compare_exchange_n(&t->_purge, &e, st, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
                __atomic_store_n(&t->_rstate, 0, __ATOMIC_RELEASE); continue; }
            uint64_t was = t->_i.alloc;
            if (nvmtl_vk_image_reback(&t->_i, 1, t->_fmt == MTLPixelFormatA8Unorm) == 0) {
                freed += was; n++; __atomic_store_n(&t->_rstate, 1, __ATOMIC_RELEASE);
            } else {
                fail++; uint32_t e = MTLPurgeableStateEmpty;
                __atomic_compare_exchange_n(&t->_purge, &e, st, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
                __atomic_store_n(&t->_rstate, 0, __ATOMIC_RELEASE); }
        }
    uint64_t s[6]; nvmtl_vk_res1_stats(s);
    nvlog("residency (res1): the wall is %llu MB short -> purged %u textures, %llu MB of VRAM given back (Empty/Volatile -> system memory, "
          "contents discarded as Metal allows); %u in use by a command buffer, %u not movable, %u rebuild failed; ever: %llu purged "
          "(%llu MB), %llu paged back on (%llu MB), %llu page-ons refused, %llu wall calls",
          (unsigned long long)(need >> 20), n, (unsigned long long)(freed >> 20), busy, inel, fail,
          (unsigned long long)s[0], (unsigned long long)s[3], (unsigned long long)s[1], (unsigned long long)s[4],
          (unsigned long long)s[2], (unsigned long long)s[5]);
    return freed;
}
extern uint64_t (*nvmtl_reclaim_hook)(uint64_t need);
static int nvmtl_res1_on(void) {
    static int on = -1;
    // Opt-in since 2026-11-04: a purge frees backing the GPU may still reach through an argument buffer (gpuAddress,
    // bindless slot), which this driver cannot see; Cyberpunk 2077 faulted on such memory. NVMTL_PURGE_RECLAIM=1 turns it on.
    if (on < 0) { const char *e = getenv("NVMTL_PURGE_RECLAIM"); on = (e && e[0] == '1');
        nvlog("residency (res1): purge under VRAM pressure %s (NVMTL_PURGE_RECLAIM=%s)", on ? "ON" : "OFF (default)", e ? e : "unset"); }
    return on;
}

#define NVMTL_EPN 256
static _Atomic uint64_t gRes2Epoch = 1, gRes2Drained;
static _Atomic int gRes2EpLive[NVMTL_EPN];
static uint64_t nvmtl_ep_enter(void) { const uint64_t e = atomic_load(&gRes2Epoch); atomic_fetch_add(&gRes2EpLive[e % NVMTL_EPN], 1); return e; }
static _Atomic unsigned gGraveN;
static void nvmtl_res2_cb_done(NVMTLCommandBuffer *cb) {
    const uint64_t e = __atomic_exchange_n(&cb->_rep, 0, __ATOMIC_ACQ_REL);
    if (!e) return;
    atomic_fetch_sub(&gRes2EpLive[e % NVMTL_EPN], 1);
    if (atomic_load(&gGraveN) || atomic_load(&gRes2Scan)) nvmtl_res2_kick(0);
}
static void nvmtl_ep_drain(void) {
    const uint64_t cur = atomic_load(&gRes2Epoch); uint64_t d = atomic_load(&gRes2Drained);
    while (d + 1 < cur && atomic_load(&gRes2EpLive[(d + 1) % NVMTL_EPN]) == 0) d++;
    atomic_store(&gRes2Drained, d);
}
static uint64_t nvmtl_ep_now(void) { return atomic_load(&gRes2Epoch); }
static BOOL nvmtl_ep_room(void) { return atomic_load(&gRes2Epoch) + 2 - atomic_load(&gRes2Drained) < NVMTL_EPN; }
typedef struct { nvk_image img; uint64_t ep; } nvmtl_grave;
static os_unfair_lock gGraveLock = OS_UNFAIR_LOCK_INIT;
static nvmtl_grave *gGrave; static unsigned gGraveCap; static uint64_t gGraveBytes, gGraveVram, gGraveFreed;
static void nvmtl_res2_reap(void) {
    nvmtl_ep_drain();
    const uint64_t d = atomic_load(&gRes2Drained);
    os_unfair_lock_lock(&gGraveLock);
    unsigned n = atomic_load(&gGraveN), k = 0;
    for (unsigned j = 0; j < n; j++) {
        if (gGrave[j].ep <= d) {
            gGraveBytes -= gGrave[j].img.alloc; if (!gGrave[j].img.sysmem) gGraveVram -= gGrave[j].img.alloc;
            nvmtl_vk_image_free_backing(&gGrave[j].img); gGraveFreed++;
        } else gGrave[k++] = gGrave[j];
    }
    atomic_store(&gGraveN, k);
    os_unfair_lock_unlock(&gGraveLock);
}
static void nvmtl_grave_put(const nvk_image *old) {
    os_unfair_lock_lock(&gGraveLock);
    unsigned n = atomic_load(&gGraveN);
    if (n == gGraveCap) { unsigned c = gGraveCap ? gGraveCap * 2 : 64; nvmtl_grave *g = realloc(gGrave, c * sizeof *g); if (g) { gGrave = g; gGraveCap = c; } }
    if (n < gGraveCap) {
        gGrave[n].img = *old; gGrave[n].ep = atomic_load(&gRes2Epoch);
        gGraveBytes += old->alloc; if (!old->sysmem) gGraveVram += old->alloc;
        atomic_store(&gGraveN, n + 1);
    } else { nvk_image leak = *old; (void)leak;
        nvlog("residency (res2): graveyard realloc FAILED - an old %llu MB backing is LEAKED, not freed in use", (unsigned long long)(old->alloc >> 20)); }
    os_unfair_lock_unlock(&gGraveLock);
}
static int gRes2On = -1; static uint64_t gRes2Cold, gRes2Hot, gRes2Margin;
static int nvmtl_res2_on(void) {
    if (gRes2On < 0) {
        // Opt-in since 2026-11-04 (NVMTL_RES2=1): page-off judges a buffer cold by its setBuffer traffic, but a buffer an
        // argument buffer points at by gpuAddress is used without any; Cyberpunk 2077 faulted on pages this had unbound.
        const char *e = getenv("NVMTL_RES2"), *c = getenv("NVMTL_RES2_COLD"), *h = getenv("NVMTL_RES2_HOT"), *m = getenv("NVMTL_RES2_MARGIN_MB");
        gRes2Cold = c && *c ? strtoull(c, NULL, 10) : 600;
        gRes2Hot = h && *h ? strtoull(h, NULL, 10) : 120;
        gRes2Margin = (m && *m ? strtoull(m, NULL, 10) : 256) << 20;
        gRes2On = (e && e[0] == '1');
        nvlog("residency (res2): LRU page-off/page-on %s (NVMTL_RES2=%s) - cold %llu ticks, hot %llu ticks, margin %llu MB",
              gRes2On ? "ON" : "OFF", e ? e : "unset", (unsigned long long)gRes2Cold, (unsigned long long)gRes2Hot, (unsigned long long)(gRes2Margin >> 20));
    }
    return gRes2On;
}
static BOOL nvmtl_res2_movable(NVMTLTexture *t) {
    return !t->_parent && !t->_viewParent && !t->_backBuf && !t->_heap && !t->_subHeap && !t->_surf && !t->_vramOn && !t->_ownView
        && !t->_shareable && !__atomic_load_n(&t->_nviews, __ATOMIC_ACQUIRE) && t->_i.img && !t->_i.placed && t->_i.usage
        && !t->_i.vfl && t->_i.samples <= 1 && !(t->_i.usage & 0x20u );
}
static os_unfair_lock gRes2RegLock = OS_UNFAIR_LOCK_INIT;
static NSHashTable *gRes2Reg;
extern void (*nvmtl_res2_pressure_hook)(uint64_t want);
static _Atomic uint64_t gRes2Want;
static void nvmtl_res2_pressure(uint64_t want) {
    uint64_t w = atomic_load(&gRes2Want); while (want > w && !atomic_compare_exchange_weak(&gRes2Want, &w, want)) {}
    nvmtl_res2_kick(1);
}
static void nvmtl_res2_note_use(NVMTLTexture *t) {
    __atomic_store_n(&t->_lastUse, atomic_load(&gRes2Tick), __ATOMIC_RELAXED);
    if (!__atomic_load_n(&t->_lruReg, __ATOMIC_ACQUIRE)) {
        int z = 0;
        if (__atomic_compare_exchange_n(&t->_lruReg, &z, 1, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE) && nvmtl_res2_on() && nvmtl_res2_movable(t)) {
            os_unfair_lock_lock(&gRes2RegLock);
            if (!gRes2Reg) gRes2Reg = [NSHashTable weakObjectsHashTable];
            [gRes2Reg addObject:t];
            os_unfair_lock_unlock(&gRes2RegLock);
            if (!nvmtl_res2_pressure_hook) nvmtl_res2_pressure_hook = nvmtl_res2_pressure;
            if (!nvmtl_res2_evict_hook) nvmtl_res2_evict_hook = nvmtl_res2_evict;
        }
    }
    if (t->_i.sysmem && !__atomic_load_n(&t->_rstate, __ATOMIC_ACQUIRE) && !__atomic_load_n(&t->_wantOn, __ATOMIC_ACQUIRE)
        && __atomic_load_n(&t->_lruReg, __ATOMIC_ACQUIRE) && nvmtl_res2_on() && nvmtl_res2_movable(t))
        __atomic_store_n(&t->_wantOn, 1, __ATOMIC_RELEASE);
}
static dispatch_queue_t gRes2Q; static _Atomic int gRes2Pending, gRes2Scan; static _Atomic uint64_t gRes2LastNs;
static void nvmtl_res2_pass(void);
static os_unfair_lock gRes2PassLock = OS_UNFAIR_LOCK_INIT;
static __thread int gRes2InPass;
static uint64_t gRes2EvictCalls, gRes2EvictBytes;
static _Atomic int gRes2Force;
static void nvmtl_res2_pass_guarded(int from_worker) {
    if (gRes2InPass) return;
    if (!os_unfair_lock_trylock(&gRes2PassLock)) {
        if (from_worker) { nvmtl_res2_kick(1); return; }
        const uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW); int got = 0;
        while (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - t0 < 30000000ull) { usleep(200); if (os_unfair_lock_trylock(&gRes2PassLock)) { got = 1; break; } }
        if (!got) { static unsigned said; if (said++ < 4) nvlog("residency (res2): allocating thread waited 30 ms for the pager and gave up - this allocation spills"); return; }
    }
    gRes2InPass = 1;
    nvmtl_res2_pass();
    gRes2InPass = 0;
    os_unfair_lock_unlock(&gRes2PassLock);
}
static uint64_t nvmtl_res2_evict(uint64_t want) {
    const int force = (int)(want >> 63); want &= ~(1ull << 63);
    if (gRes2On != 1 || !want || gRes2InPass) return 0;
    if (force) atomic_store(&gRes2Force, 1);
    const uint64_t before = nvmtl_vk_vram_free_now();
    uint64_t w = atomic_load(&gRes2Want);
    do { if (want <= w) break; } while (!atomic_compare_exchange_weak(&gRes2Want, &w, want));
    atomic_store(&gRes2Scan, 1);
    @autoreleasepool { nvmtl_res2_pass_guarded(0); }
    uint64_t after = nvmtl_vk_vram_free_now();
    static _Atomic uint64_t blindUntil;
    if (after <= before && gGraveVram && clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) >= atomic_load(&blindUntil)) {
        const uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        while (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - t0 < 16000000ull) {
            usleep(1000); nvmtl_res2_reap(); after = nvmtl_vk_vram_free_now();
            if (after > before) break;
        }
        if (after <= before) { atomic_store(&blindUntil, clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + 250000000ull);
            static unsigned said; if (said++ < 4 || said % 256 == 0)
                nvlog("residency (res2): waited 16 ms for %llu MB of evicted VRAM to drain and it did not - this allocation spills (%u)",
                      (unsigned long long)(gGraveVram >> 20), said); }
    }
    const uint64_t freed = after > before ? after - before : 0;
    gRes2EvictCalls++; gRes2EvictBytes += freed;
    return freed;
}
static void nvmtl_res2_kick(int scan) {
    if (gRes2On != 1) return;
    if (scan) atomic_store(&gRes2Scan, 1);
    int z = 0; if (!atomic_compare_exchange_strong(&gRes2Pending, &z, 1)) return;
    static dispatch_once_t once; dispatch_once(&once, ^{ gRes2Q = dispatch_queue_create("nvmtl.residency", DISPATCH_QUEUE_SERIAL); });
    const uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW), last = atomic_load(&gRes2LastNs);
    const int64_t wait = last && now - last < 16000000ull ? (int64_t)(16000000ull - (now - last)) : 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, wait), gRes2Q, ^{
        atomic_store(&gRes2Pending, 0);
        @autoreleasepool { nvmtl_res2_pass_guarded(1); }
        atomic_store(&gRes2LastNs, clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW));
    });
}
extern int nvmtl_vk_mig_batch_begin(void); extern int nvmtl_vk_mig_batch_end(void);
static int gRes2Batching;
typedef struct { __unsafe_unretained NVMTLTexture *t; nvk_image old; } nvmtl_pend_t;
static nvmtl_pend_t *gPend; static unsigned gPendN, gPendCap; static uint64_t gBatchN, gBatchMoves;
static void nvmtl_grave_put(const nvk_image *old);
static void nvmtl_res2_batch_end(void);
static void nvmtl_res2_pend(NVMTLTexture *t, const nvk_image *old) {
    if (gPendN == gPendCap) { unsigned c = gPendCap ? gPendCap * 2 : 128; nvmtl_pend_t *n = realloc(gPend, c * sizeof *n); if (n) { gPend = n; gPendCap = c; } }
    if (gPendN < gPendCap) { gPend[gPendN].t = t; gPend[gPendN].old = *old; gPendN++; }
    else { nvmtl_res2_batch_end(); nvmtl_grave_put(old); __atomic_store_n(&t->_rstate, 0, __ATOMIC_RELEASE); }
    if (gPendN >= 128) { nvmtl_res2_batch_end(); nvmtl_vk_mig_batch_begin(); }
}
static void nvmtl_res2_batch_end(void) {
    (void)nvmtl_vk_mig_batch_end();
    for (unsigned k = 0; k < gPendN; k++) { nvmtl_grave_put(&gPend[k].old); __atomic_store_n(&gPend[k].t->_rstate, 0, __ATOMIC_RELEASE); }
    if (gPendN) { gBatchN++; gBatchMoves += gPendN;
        static unsigned said; if (said++ < 4 || said % 256 == 0) nvlog("residency (res2): evict-batch %llu: %u textures copied in ONE submission (%llu moves in %llu batches)",
            (unsigned long long)gBatchN, gPendN, (unsigned long long)gBatchMoves, (unsigned long long)gBatchN); }
    gPendN = 0;
}
static int nvmtl_res2_move(NVMTLTexture *t, int to_sys) {
    int z = 0; if (!__atomic_compare_exchange_n(&t->_rstate, &z, 2, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) return 1;
    int r = 1, held = 0;
    @synchronized (t) {
        if (!__atomic_load_n(&t->_resRefs, __ATOMIC_ACQUIRE) && __atomic_load_n(&t->_useEp, __ATOMIC_ACQUIRE) <= atomic_load(&gRes2Drained)) {
            nvk_image old; memset(&old, 0, sizeof old);
            r = nvmtl_vk_image_migrate(&t->_i, to_sys, t->_fmt == MTLPixelFormatA8Unorm, &old);
            if (r == 0) {
                if (t->_resid & (1ull << 62)) nvmtl_vk_bindless_rewrite_full((uint32_t)(t->_resid & 0xffffffffu), t->_i.view, nvmtl_vk_image_self_storage(&t->_i) ? t->_i.view : NULL, t->_tbView, t->_tbStorage ? 1 : 0);
                if (gRes2Batching) { nvmtl_res2_pend(t, &old); held = 1; }
                else nvmtl_grave_put(&old);
            }
        }
    }
    if (!held) __atomic_store_n(&t->_rstate, 0, __ATOMIC_RELEASE);
    return r;
}
static Class gNVMTLBufClass;
static BOOL nvmtl_res3_movable(NVMTLBuffer *b) {
    if (!gNVMTLBufClass) gNVMTLBufClass = [NVMTLBuffer class];
    return object_getClass(b) == gNVMTLBufClass && b->_storage == MTLStorageModePrivate && b->_b.sparse && b->_b.buf && b->_b.mem
        && !b->_b.map && !b->_heap && !b->_subHeap && !b->_hostPtr && !b->_shadow.buf && !b->_texSeen && !b->_nbpk && !b->_subPlaced
        && !b->_b.pool && !b->_b.placed && !b->_b.imported && !b->_b.bar1 && !b->_b.moff;
}
static void nvmtl_res3_note_use(NVMTLBuffer *b) {
    __atomic_store_n(&b->_lastUse, atomic_load(&gRes2Tick), __ATOMIC_RELAXED);
    if (!b->_b.sparse) return;
    if (!__atomic_load_n(&b->_lruReg, __ATOMIC_ACQUIRE)) {
        int z = 0;
        if (__atomic_compare_exchange_n(&b->_lruReg, &z, 1, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE) && nvmtl_res2_on() && nvmtl_res3_movable(b)) {
            os_unfair_lock_lock(&gRes2RegLock);
            if (!gRes2Reg) gRes2Reg = [NSHashTable weakObjectsHashTable];
            [gRes2Reg addObject:b];
            os_unfair_lock_unlock(&gRes2RegLock);
            if (!nvmtl_res2_pressure_hook) nvmtl_res2_pressure_hook = nvmtl_res2_pressure;
            if (!nvmtl_res2_evict_hook) nvmtl_res2_evict_hook = nvmtl_res2_evict;
        }
    }
    if (b->_b.sysmem && !__atomic_load_n(&b->_rstate, __ATOMIC_ACQUIRE) && !__atomic_load_n(&b->_wantOn, __ATOMIC_ACQUIRE)
        && __atomic_load_n(&b->_lruReg, __ATOMIC_ACQUIRE) && nvmtl_res2_on() && nvmtl_res3_movable(b))
        __atomic_store_n(&b->_wantOn, 1, __ATOMIC_RELEASE);
}
static int nvmtl_res3_move(NVMTLBuffer *b, int to_sys) {
    int z = 0; if (!__atomic_compare_exchange_n(&b->_rstate, &z, 2, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) return 1;
    int r = 1;
    if (!__atomic_load_n(&b->_resRefs, __ATOMIC_ACQUIRE) && __atomic_load_n(&b->_useEp, __ATOMIC_ACQUIRE) <= atomic_load(&gRes2Drained))
        r = nvmtl_vk_buffer_migrate(&b->_b, to_sys);
    __atomic_store_n(&b->_rstate, 0, __ATOMIC_RELEASE);
    return r;
}
static inline BOOL r2_tex(id o) { return [o isKindOfClass:gNVMTLTexClass]; }
static inline int *r2_rst(id o)  { if (r2_tex(o)) { NVMTLTexture *t = o; return &t->_rstate; }  NVMTLBuffer *b = o; return &b->_rstate; }
static inline int *r2_refs(id o) { if (r2_tex(o)) { NVMTLTexture *t = o; return &t->_resRefs; } NVMTLBuffer *b = o; return &b->_resRefs; }
static inline int *r2_want(id o) { if (r2_tex(o)) { NVMTLTexture *t = o; return &t->_wantOn; }  NVMTLBuffer *b = o; return &b->_wantOn; }
static inline uint64_t *r2_useEp(id o) { if (r2_tex(o)) { NVMTLTexture *t = o; return &t->_useEp; } NVMTLBuffer *b = o; return &b->_useEp; }
static inline uint64_t *r2_last(id o) { if (r2_tex(o)) { NVMTLTexture *t = o; return &t->_lastUse; } NVMTLBuffer *b = o; return &b->_lastUse; }
static inline uint32_t r2_purge(id o) { if (r2_tex(o)) { NVMTLTexture *t = o; return __atomic_load_n(&t->_purge, __ATOMIC_ACQUIRE); }
                                        NVMTLBuffer *b = o; return __atomic_load_n(&b->_purge, __ATOMIC_ACQUIRE); }
static inline int r2_sys(id o) { if (r2_tex(o)) { NVMTLTexture *t = o; return t->_i.sysmem != 0; } NVMTLBuffer *b = o; return b->_b.sysmem != 0; }
static inline uint64_t r2_alloc(id o) { if (r2_tex(o)) { NVMTLTexture *t = o; return t->_i.alloc; } NVMTLBuffer *b = o; return b->_b.alloc; }
static inline BOOL r2_movable(id o) { return r2_tex(o) ? (((NVMTLTexture *)o)->_i.img && nvmtl_res2_movable(o)) : nvmtl_res3_movable(o); }
static inline int r2_move(id o, int to_sys) { return r2_tex(o) ? nvmtl_res2_move(o, to_sys) : nvmtl_res3_move(o, to_sys); }
static void nvmtl_res2_pass(void) {
    nvmtl_res2_reap();
    if (!atomic_exchange(&gRes2Scan, 0)) return;
    NSArray *all = nil;
    os_unfair_lock_lock(&gRes2RegLock); all = gRes2Reg.count ? gRes2Reg.allObjects : nil; os_unfair_lock_unlock(&gRes2RegLock);
    const uint64_t want = atomic_exchange(&gRes2Want, 0);
    if (!all.count) return;
    if (!gNVMTLTexClass) gNVMTLTexClass = [NVMTLTexture class];
    if (!nvmtl_ep_room()) { nvlog("residency (res2): PAUSED - a command buffer from %llu epochs ago has not completed; nothing moves until it does",
                                  (unsigned long long)(atomic_load(&gRes2Epoch) - atomic_load(&gRes2Drained))); return; }
    const uint64_t tick = atomic_load(&gRes2Tick);
    NSMutableArray *cold = [NSMutableArray new], *hot = [NSMutableArray new];
    const uint64_t drained = atomic_load(&gRes2Drained); unsigned undrained = 0;
    for (id o in all) {
        if (__atomic_load_n(r2_rst(o), __ATOMIC_ACQUIRE) || !r2_movable(o)) continue;
        if (__atomic_load_n(r2_useEp(o), __ATOMIC_ACQUIRE) > drained) { undrained++; continue; }
        const uint32_t ps = r2_purge(o);
        const uint64_t lu = __atomic_load_n(r2_last(o), __ATOMIC_RELAXED);
        if (!r2_sys(o)) {
            if (lu + (want ? 0 : gRes2Cold) <= tick && (ps == 0 || ps == MTLPurgeableStateNonVolatile) && !__atomic_load_n(r2_refs(o), __ATOMIC_ACQUIRE)) [cold addObject:o];
        } else if (__atomic_load_n(r2_want(o), __ATOMIC_ACQUIRE) || lu + gRes2Hot >= tick) [hot addObject:o];
    }
    [cold sortUsingComparator:^NSComparisonResult(id a, id b) { uint64_t x = *r2_last(a), y = *r2_last(b); return x < y ? NSOrderedAscending : x > y ? NSOrderedDescending : NSOrderedSame; }];
    [hot sortUsingComparator:^NSComparisonResult(id a, id b) { uint64_t x = *r2_last(a), y = *r2_last(b); return x > y ? NSOrderedAscending : x < y ? NSOrderedDescending : NSOrderedSame; }];
    unsigned on = 0, off = 0, onB = 0, offB = 0, busy = 0, noroom = 0; uint64_t onM = 0, offM = 0;
    const uint64_t coldest = cold.count ? tick - *r2_last(cold[0]) : 0;
    NSUInteger ci = 0;
    for (id t in (want ? @[] : hot)) {
        if (__atomic_load_n(r2_refs(t), __ATOMIC_ACQUIRE)) { busy++; continue; }
        const uint64_t need = r2_alloc(t);
        if (!nvmtl_vk_vram_room(need)) {
            uint64_t pending = 0;
            while (ci < cold.count && pending < need + gRes2Margin) {
                id v = cold[ci++];
                if (*r2_last(v) + gRes2Cold > *r2_last(t)) continue;
                const uint64_t a = r2_alloc(v); const BOOL vb = !r2_tex(v);
                if (r2_move(v, 1) == 0) { off++; offB += vb; offM += a; pending += a; }
            }
            noroom++;
            continue;
        }
        const uint64_t a = r2_alloc(t); const BOOL tb = !r2_tex(t);
        if (r2_move(t, 0) == 0) { on++; onB += tb; onM += a; __atomic_store_n(r2_want(t), 0, __ATOMIC_RELEASE); }
    }
    if (want) {
        const uint64_t target = nvmtl_vk_vram_headroom() + gRes2Margin + want;
        if (nvmtl_vk_mig_batch_begin() == 0) gRes2Batching = 1;
        { static unsigned said; if (said++ < 16 || said % 1024 == 0)
            nvlog("residency (res2): pressure pass wants %llu MB - registry %lu, victims left %lu of %lu, "
                  "stranded %lu, undrained %u, in use %u, free %llu MB + graveyard %llu MB vs target %llu MB",
                  (unsigned long long)(want >> 20), (unsigned long)all.count,
                  (unsigned long)(cold.count > ci ? cold.count - ci : 0), (unsigned long)cold.count,
                  (unsigned long)hot.count, undrained, busy,
                  (unsigned long long)(nvmtl_vk_vram_free_now() >> 20),
                  (unsigned long long)(gGraveVram >> 20), (unsigned long long)(target >> 20)); }
        const int force = atomic_exchange(&gRes2Force, 0);
        const uint64_t f0 = nvmtl_vk_vram_free_now() + gGraveVram, cap = force ? want + gRes2Margin : (target > f0 ? target - f0 : 0); uint64_t movedM = 0;
        while (ci < cold.count && movedM < cap && (force || nvmtl_vk_vram_free_now() + gGraveVram < target)) {
            id v = cold[ci++]; const uint64_t a = r2_alloc(v); const BOOL vb = !r2_tex(v);
            if (r2_move(v, 1) == 0) { off++; offB += vb; offM += a; movedM += a; }
        }
        if (gRes2Batching) { nvmtl_res2_batch_end(); gRes2Batching = 0; }
    }
    if (on || off) {
        if (nvmtl_ep_room()) atomic_fetch_add(&gRes2Epoch, 1);
        uint64_t s[5], s3[6]; nvmtl_vk_res2_stats(s); nvmtl_vk_res3_stats(s3);
        nvlog("residency (res2): paged ON %u (%llu MB, %u buffers), paged OFF %u (%llu MB, %u buffers, coldest idle %llu ticks); %u in use, %u waiting for room; "
              "graveyard %u (%llu MB, %llu MB VRAM) freed %llu; free VRAM %llu MB; ever: textures off %llu (%llu MB) on %llu (%llu MB), %llu copy failures; "
              "buffers off %llu (%llu MB) on %llu (%llu MB), %llu stable-address buffers made (%llu in system memory at birth)",
              on, (unsigned long long)(onM >> 20), onB, off, (unsigned long long)(offM >> 20), offB, (unsigned long long)coldest, busy, noroom,
              atomic_load(&gGraveN), (unsigned long long)(gGraveBytes >> 20), (unsigned long long)(gGraveVram >> 20), (unsigned long long)gGraveFreed,
              (unsigned long long)(nvmtl_vk_vram_free_now() >> 20),
              (unsigned long long)s[0], (unsigned long long)s[2], (unsigned long long)s[1], (unsigned long long)s[3], (unsigned long long)s[4],
              (unsigned long long)s3[2], (unsigned long long)s3[4], (unsigned long long)s3[3], (unsigned long long)s3[5],
              (unsigned long long)s3[0], (unsigned long long)s3[1]);
    }
    if (noroom) { atomic_store(&gRes2Scan, 1); if (off) nvmtl_res2_kick(1); }
    if (undrained) { if (!(on || off) && nvmtl_ep_room()) atomic_fetch_add(&gRes2Epoch, 1); atomic_store(&gRes2Scan, 1); }
}

static void nvmtl_purge_track(id r, MTLPurgeableState s) {
    if (s != MTLPurgeableStateVolatile && s != MTLPurgeableStateEmpty && s != MTLPurgeableStateNonVolatile) return;
    os_unfair_lock_lock(&gPurgeLock);
    if (s == MTLPurgeableStateNonVolatile) { [gPurgeVol removeObject:r]; }
    else {
        if (!gPurgeVol) gPurgeVol = [NSHashTable weakObjectsHashTable];
        [gPurgeVol addObject:r];
        atomic_fetch_add(&gPurgeAsks, 1);
        nvmtl_purge_report_hook = nvmtl_purge_report;
        if (!nvmtl_reclaim_hook && nvmtl_res1_on()) nvmtl_reclaim_hook = nvmtl_purge_reclaim;
    }
    os_unfair_lock_unlock(&gPurgeLock);
}

static void nvmtl_purge_report(const char *why) {
    uint64_t nvol = 0, nemp = 0, bvol = 0, bemp = 0;
    NSArray *all = nil;
    os_unfair_lock_lock(&gPurgeLock);
    all = gPurgeVol.allObjects;
    os_unfair_lock_unlock(&gPurgeLock);
    for (id r in all) {
        uint32_t st = 0; uint64_t bytes = 0;
        if ([r isKindOfClass:[NVMTLTexture class]]) { NVMTLTexture *t = r; st = t->_purge; bytes = t->_i.alloc; }
        else if ([r isKindOfClass:[NVMTLBuffer class]]) { NVMTLBuffer *b = r; st = b->_purge; bytes = b->_b.alloc; }
        else continue;
        if (st == MTLPurgeableStateEmpty) { nemp++; bemp += bytes; }
        else if (st == MTLPurgeableStateVolatile) { nvol++; bvol += bytes; }
    }
    nvlog("purgeable at the %s spill: %llu Volatile holding %llu MB, %llu Empty holding %llu MB, of %llu asks ever"
          " - still marked after the res1 consumer ran (buffers, views, bindless or in-use textures): %llu MB Empty",
          why, (unsigned long long)nvol, (unsigned long long)(bvol >> 20),
          (unsigned long long)nemp, (unsigned long long)(bemp >> 20),
          (unsigned long long)atomic_load(&gPurgeAsks), (unsigned long long)(bemp >> 20));
}
static void nvmtl_pre_release(void *held) { @autoreleasepool { (void)CFBridgingRelease(held); } }
static void nvmtl_managed_flush(void) {
    if (!atomic_load(&gManagedAny) || gManagedInFlush) return;
    gManagedInFlush = 1;
    NSMutableArray *todo = [NSMutableArray new];
    os_unfair_lock_lock(&gManagedLock);
    for (NVMTLBuffer *b in gManagedDirty.allObjects) {
        if (b->_dirtyHi > b->_dirtyLo) [todo addObject:@[b, @(b->_dirtyLo), @(b->_dirtyHi)]];
        b->_dirtyLo = b->_dirtyHi = 0;
    }
    [gManagedDirty removeAllObjects]; atomic_store(&gManagedAny, 0);
    os_unfair_lock_unlock(&gManagedLock);
    if (todo.count && nvmtl_vk_pre_open()) {
        for (NSArray *t in todo) {
            NVMTLBuffer *b = t[0]; NSUInteger lo = [t[1] unsignedIntegerValue], n = [t[2] unsignedIntegerValue] - lo;
            if (nvmtl_vk_pre_copy(&b->_shadow, lo, &b->_b, lo, n))
                nvlog("managed: upload of %lu bytes at %lu FAILED - the GPU keeps the old bytes", (unsigned long)n, (unsigned long)lo);
        }
        nvmtl_pre_release_hook = nvmtl_pre_release;
        nvmtl_vk_pre_hold((__bridge_retained void *)todo);
    } else
    for (NSArray *t in todo) {
        NVMTLBuffer *b = t[0]; NSUInteger lo = [t[1] unsignedIntegerValue], n = [t[2] unsignedIntegerValue] - lo;
        if (nvmtl_vk_copy_buffer(nvmtl_device_queue(), &b->_shadow, lo, &b->_b, lo, n))
            nvlog("managed: upload of %lu bytes at %lu FAILED - the GPU keeps the old bytes", (unsigned long)n, (unsigned long)lo);
    }
    gManagedInFlush = 0;
}
static void nvmtl_presubmit(void);
static void nvmtl_managed_mark(NVMTLBuffer *b, NSUInteger lo, NSUInteger hi) {
    os_unfair_lock_lock(&gManagedLock);
    if (!gManagedDirty) gManagedDirty = [NSHashTable weakObjectsHashTable];
    if (b->_dirtyHi <= b->_dirtyLo) { b->_dirtyLo = lo; b->_dirtyHi = hi; }
    else { b->_dirtyLo = MIN(b->_dirtyLo, lo); b->_dirtyHi = MAX(b->_dirtyHi, hi); }
    @autoreleasepool { [gManagedDirty addObject:b]; } atomic_store(&gManagedAny, 1);
    nvmtl_pre_submit_hook = nvmtl_presubmit;
    os_unfair_lock_unlock(&gManagedLock);
}
static os_unfair_lock gZeroLock = OS_UNFAIR_LOCK_INIT;
static NSHashTable *gZeroOwed;
static _Atomic int gZeroAny;
static __thread int gZeroInFlush;
static _Atomic unsigned long long gZeroHostN, gZeroHostB, gZeroGpuN, gZeroGpuB, gZeroTail;
static int nvmtl_zero_mode(void) {
    static int m = -1;
    if (m < 0) { const char *e = getenv("NVMTL_ZERO_FILL");
        m = !e ? 2 : (e[0] == '0' ? 0 : (strcmp(e, "host") == 0 ? 1 : 2));
        nvlog("zero-fill: new buffers %s (NVMTL_ZERO_FILL=%s)", m == 2 ? "are cleared - CPU-mapped by memset, Private by a GPU fill before the next submission"
              : m == 1 ? "are cleared only where the CPU maps them - Private keeps what VRAM held" : "are NOT cleared - they hold what the memory held", e ? e : "unset"); }
    return m;
}
static void nvmtl_zero_census(void) {
    nvlog("zero-fill census: %llu CPU-mapped buffers (%llu bytes) cleared by memset, %llu Private (%llu bytes) by the GPU, %llu tail bytes left (length not a multiple of 4)",
          (unsigned long long)gZeroHostN, (unsigned long long)gZeroHostB, (unsigned long long)gZeroGpuN, (unsigned long long)gZeroGpuB, (unsigned long long)gZeroTail);
}
static void nvmtl_zero_flush(void) {
    if (!atomic_load(&gZeroAny) || gZeroInFlush) return;
    gZeroInFlush = 1;
    os_unfair_lock_lock(&gZeroLock);
    NSArray *todo = gZeroOwed.allObjects; [gZeroOwed removeAllObjects]; atomic_store(&gZeroAny, 0);
    os_unfair_lock_unlock(&gZeroLock);
    nvk_cmdbuf c; unsigned n = 0; size_t bytes = 0;
    if (todo.count && nvmtl_vk_pre_open()) {
        for (NVMTLBuffer *b in todo) { const size_t w = b->_b.size & ~(size_t)3;
            if (b->_b.buf && w && nvmtl_vk_pre_fill(&b->_b, 0, w, 0) == 0) { n++; bytes += w; gZeroTail += b->_b.size - w; } }
        nvmtl_pre_release_hook = nvmtl_pre_release;
        nvmtl_vk_pre_hold((__bridge_retained void *)todo);
        const unsigned long long k = atomic_fetch_add(&gZeroGpuN, n); gZeroGpuB += bytes;
        if (!k || (k >> 12) != ((k + n) >> 12)) nvmtl_zero_census();
    } else if (todo.count && nvmtl_vk_cmd_begin(nvmtl_device_queue(), &c) == 0) {
        for (NVMTLBuffer *b in todo) { const size_t w = b->_b.size & ~(size_t)3;
            if (b->_b.buf && w && nvmtl_vk_cmd_fill_buffer(&c, &b->_b, 0, w, 0) == 0) { n++; bytes += w; gZeroTail += b->_b.size - w; } }
        if (nvmtl_vk_submit_wait(&c)) nvlog("zero-fill: GPU clear of %u Private buffers (%zu bytes) FAILED - they hold what VRAM held", n, bytes);
        else { const unsigned long long k = atomic_fetch_add(&gZeroGpuN, n); gZeroGpuB += bytes;
               if (!k || (k >> 12) != ((k + n) >> 12)) nvmtl_zero_census(); }
    } else if (todo.count) nvlog("zero-fill: no command buffer for %lu Private clears - they hold what VRAM held", (unsigned long)todo.count);
    gZeroInFlush = 0;
}
void nvmtl_twin_flush(void);
void nvmtl_shm_prologue(void);
void nvmtl_shw_reclaim(void);
static void nvmtl_presubmit(void) { @autoreleasepool { nvmtl_zero_flush(); } @autoreleasepool { nvmtl_managed_flush(); } nvmtl_twin_flush(); nvmtl_shw_reclaim(); nvmtl_shm_prologue(); }
static int nvmtl_mzero_on(void) {
    static int on = -1;
    if (on < 0) { const char *e = getenv("NVMTL_MANAGED_EAGER_ZERO"); on = !(e && e[0] == '1');
        nvlog("zero-fill: managed buffers %s (NVMTL_MANAGED_EAGER_ZERO=%s)", on ? "clear their VRAM copy on the GPU before the next submit and their CPU copy on first CPU touch"
              : "memset their CPU copy at creation and upload it (old)", e ? e : "unset"); }
    return on;
}
static void nvmtl_zero_new_buffer(NVMTLBuffer *b, NSUInteger len) {
    const int m = nvmtl_zero_mode();
    if (!m || !b || !len) return;
    const int mz = b->_shadow.map && m >= 2 && b->_b.buf && !b->_b.map && nvmtl_mzero_on();
    if (mz) __atomic_store_n(&b->_zshadow, 1, __ATOMIC_RELEASE);
    if (b->_shadow.map && !mz) {
        memset(b->_shadow.map, 0, len); nvmtl_managed_mark(b, 0, MIN((NSUInteger)b->_b.size, len));
    } else if (b->_b.map && !mz) {
        memset(b->_b.map, 0, len);
    } else {
        if (m < 2 || !b->_b.buf) return;
        os_unfair_lock_lock(&gZeroLock);
        if (!gZeroOwed) gZeroOwed = [NSHashTable weakObjectsHashTable];
        @autoreleasepool { [gZeroOwed addObject:b]; }
        atomic_store(&gZeroAny, 1);
        nvmtl_pre_submit_hook = nvmtl_presubmit;
        os_unfair_lock_unlock(&gZeroLock);
        return;
    }
    const unsigned long long k = atomic_fetch_add(&gZeroHostN, 1); gZeroHostB += len;
    if (!k || ((k + 1) & 0xFFF) == 0) nvmtl_zero_census();
}
#define NVMTL_BUFPARK 4
static _Atomic uint64_t gBTNew, gBTRecycled, gBTParked, gBTEvicted;
static void nvmtl_buftex_census(const char *what) {
    const uint64_t n = atomic_load(&gBTNew) + atomic_load(&gBTRecycled);
    if (n & (n - 1)) return;
    nvlog("buffer texture (%s): %llu new, %llu recycled, %llu parked, %llu evicted", what,
          (unsigned long long)atomic_load(&gBTNew), (unsigned long long)atomic_load(&gBTRecycled),
          (unsigned long long)atomic_load(&gBTParked), (unsigned long long)atomic_load(&gBTEvicted));
}
static int nvmtl_bpark_take(NVMTLBuffer *b, const uint32_t *key, nvk_image *out) {
    int got = -1;
    os_unfair_lock_lock(&b->_bpl);
    for (uint32_t k = b->_nbpk; k-- > 0; ) {
        nvmtl_park_t *p = &b->_bpk[k];
        if (memcmp(p->key, key, sizeof p->key)) continue;
        *out = p->img; memmove(p, p + 1, (size_t)(b->_nbpk - k - 1) * sizeof *p); b->_nbpk--; got = 0; break;
    }
    os_unfair_lock_unlock(&b->_bpl);
    return got;
}
static void nvmtl_bpark_put(NVMTLBuffer *b, nvk_image *img, const uint32_t *key) {
    nvk_image ev; int evict = 0, parked = 0;
    os_unfair_lock_lock(&b->_bpl);
    if (!b->_bpk) b->_bpk = calloc(NVMTL_BUFPARK, sizeof *b->_bpk);
    if (b->_bpk) {
        if (b->_nbpk == NVMTL_BUFPARK) { ev = b->_bpk[0].img; evict = 1;
            memmove(&b->_bpk[0], &b->_bpk[1], (NVMTL_BUFPARK - 1) * sizeof *b->_bpk); b->_nbpk--; }
        nvmtl_park_t *p = &b->_bpk[b->_nbpk++]; p->img = *img; memcpy(p->key, key, sizeof p->key); p->off = p->len = 0;
        parked = 1;
    }
    os_unfair_lock_unlock(&b->_bpl);
    if (parked) { memset(img, 0, sizeof *img); atomic_fetch_add(&gBTParked, 1); }
    if (evict) { nvmtl_vk_image_destroy(&ev); atomic_fetch_add(&gBTEvicted, 1); }
}
static NVMTLTexture *nvmtl_texbuf_make(NVMTLBuffer *b, MTLTextureDescriptor *d, NSUInteger offset)
{
    extern int nvmtl_pixfmt_public(MTLPixelFormat f, uint32_t *vk, uint32_t *bpp, int *a8);
    extern nvk_queue *nvmtl_device_queue(void);
    uint32_t vkf = 0, bpp = 0; int a8 = 0;
    if (!b || !d || !d.width || nvmtl_pixfmt_public(d.pixelFormat, &vkf, &bpp, &a8) || a8 || !bpp) {
        nvlog("texture buffer: format %lu width %lu is not carried -> nil", (unsigned long)d.pixelFormat, (unsigned long)d.width); return nil; }
    const size_t range = (size_t)d.width * bpp;
    NVMTLTexture *t = [NVMTLTexture new]; int st = 0;
    if (nvmtl_vk_texel_view_create(&b->_b, offset, range, vkf, NVMTL_USAGE_WRITES(d.usage), &t->_tbAlias, &t->_tbView, &st)) {
        nvlog("texture buffer: %lu x fmt %lu at offset %lu of a %zu-byte buffer -> nil (reason above)", (unsigned long)d.width,
              (unsigned long)d.pixelFormat, (unsigned long)offset, b->_b.size); return nil; }
    t->_tbStorage = st != 0;
    if ((d.usage & 0x20) && !(d.usage & MTLTextureUsageShaderWrite)) {
        static _Atomic unsigned said; unsigned k = atomic_fetch_add(&said, 1);
        if (k < 4 || (k & (k - 1)) == 0) nvlog("texture buffer: %lu x fmt %lu with ShaderAtomic but not ShaderWrite (usage 0x%lx) -> storage texel view %s (%u such so far)",
                                               (unsigned long)d.width, (unsigned long)d.pixelFormat, (unsigned long)d.usage, st ? "YES" : "NO", k + 1);
    }
    t->_i.w = (uint32_t)d.width; t->_i.h = 1; t->_i.fmt = vkf; t->_i.bpp = bpp; t->_i.mtl_type = 9; t->_i.mips = 1; t->_i.layers = 1; t->_i.samples = 1;
    t->_q = nvmtl_device_queue(); t->_fmt = d.pixelFormat; t->_mips = 1; t->_usage = d.usage; t->_stex = NO;
    t->_backBuf = b; t->_backOff = offset; t->_backBPR = range;
    { extern void nvmtl_shm_note_buftex(const nvk_buffer *, size_t, size_t, unsigned);
      if (b->_b.shm && (d.usage == MTLTextureUsageUnknown || NVMTL_USAGE_WRITES(d.usage))) nvmtl_shm_note_buftex(&b->_b, offset, range, (unsigned)d.usage); }
    b->_texSeen = YES;
    nvlog("texture buffer: %lu texels fmt %lu (VkFormat %u, %s) at offset %lu -> %p", (unsigned long)d.width, (unsigned long)d.pixelFormat, vkf,
          st ? "read/write" : "read", (unsigned long)offset, (__bridge void *)t);
    return t;
}
// Every buffer object, weakly, so a GPU address found inside another buffer (an argument table written by the app) can be
// resolved back to the buffer it points into: /tmp/nvmtl-trace-peek (with the trace on) prints what a Metal Shader
// Converter descriptor table holds at draw time (diagnostic, 2026-11-04).
static NSHashTable *gBufReg; static os_unfair_lock gBufRegLock = OS_UNFAIR_LOCK_INIT;
static void nvmtl_bufreg_add(id b) { os_unfair_lock_lock(&gBufRegLock); if (!gBufReg) gBufReg = [NSHashTable weakObjectsHashTable]; [gBufReg addObject:b]; os_unfair_lock_unlock(&gBufRegLock); }
static NVMTLBuffer *nvmtl_bufreg_find(uint64_t addr, uint64_t *off) {
    NVMTLBuffer *hit = nil; os_unfair_lock_lock(&gBufRegLock);
    for (NVMTLBuffer *b in gBufReg) { if (!b->_b.buf || !b->_b.size) continue; uint64_t base = nvmtl_vk_buffer_address(&b->_b);
        if (base && addr >= base && addr < base + b->_b.size) { hit = b; if (off) *off = addr - base; break; } }
    os_unfair_lock_unlock(&gBufRegLock); return hit;
}
// every live NVMTLBuffer, so a GPU address read out of an argument buffer can be turned back into the object
static NSHashTable *nvmtl_buf_registry; static os_unfair_lock nvmtl_buf_registry_lock = OS_UNFAIR_LOCK_INIT;
static NVMTLBuffer *nvmtl_buffer_for_va(uint64_t va, uint64_t *base_out)
{
    NVMTLBuffer *hit = nil; uint64_t base = 0;
    os_unfair_lock_lock(&nvmtl_buf_registry_lock);
    for (NVMTLBuffer *b in nvmtl_buf_registry) {
        if (!b->_b.buf) continue;
        uint64_t a = nvmtl_vk_buffer_address(&b->_b);
        if (a && va >= a && va < a + b->_b.size) { hit = b; base = a; break; }
    }
    os_unfair_lock_unlock(&nvmtl_buf_registry_lock);
    if (base_out) *base_out = base;
    return hit;
}
@implementation NVMTLBuffer
- (instancetype)init {
    if ((self = [super init])) {
        os_unfair_lock_lock(&nvmtl_buf_registry_lock);
        if (!nvmtl_buf_registry) nvmtl_buf_registry = [NSHashTable weakObjectsHashTable];
        [nvmtl_buf_registry addObject:self];
        os_unfair_lock_unlock(&nvmtl_buf_registry_lock);
    }
    return self;
}
+ (instancetype)alloc { id o = [super alloc]; nvmtl_bufreg_add(o); return o; }
- (IOSurfaceRef)iosurface { return NULL; }
- (id<MTLTexture>)newTiledTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bpr {
    id<MTLTexture> t = [self newTextureWithDescriptor:d offset:offset bytesPerRow:bpr];
    if (t || !d) return t;
    void *base = [self contents];
    if (!base || d.textureType != MTLTextureType2D || offset + bpr * d.height > _b.size) {
        nvlog("newTiledTextureWithDescriptor: %lux%lu bpr %lu off %lu: no linear view and no CPU copy (buffer %lu B) -> nil",
              (unsigned long)d.width, (unsigned long)d.height, (unsigned long)bpr, (unsigned long)offset, (unsigned long)_b.size);
        return nil; }
    MTLTextureDescriptor *cd = [d copy]; cd.storageMode = MTLStorageModeShared;
    id<MTLTexture> c = [[self device] newTextureWithDescriptor:cd];
    if (c) [c replaceRegion:MTLRegionMake2D(0, 0, d.width, d.height) mipmapLevel:0 withBytes:(char *)base + offset bytesPerRow:bpr];
    { static int said; if (!said++) nvlog("newTiledTextureWithDescriptor: linear view refused -> copied texture (%lux%lu bpr %lu; said once)",
                                          (unsigned long)d.width, (unsigned long)d.height, (unsigned long)bpr); }
    return c;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bpr {
    extern int nvmtl_pixfmt_public(MTLPixelFormat f, uint32_t *vk, uint32_t *bpp, int *a8);
    if (!d) return nil;
    if (d.textureType == MTLTextureTypeTextureBuffer) return nvmtl_texbuf_make(self, d, offset);
    size_t w = d.width, h = d.height;
    if (d.textureType != MTLTextureType2D || d.mipmapLevelCount > 1 || d.sampleCount > 1 || d.arrayLength > 1 || d.depth > 1
        || !w || !h || w > UINT32_MAX || h > UINT32_MAX) {
        nvlog("buffer newTextureWithDescriptor:offset:%lu bytesPerRow:%lu: type %lu %zux%zu (mips %lu, samples %lu, array %lu, depth %lu) "
              "is not built - only a 2D single-level linear view -> nil", (unsigned long)offset, (unsigned long)bpr, (unsigned long)d.textureType,
              w, h, (unsigned long)d.mipmapLevelCount, (unsigned long)d.sampleCount, (unsigned long)d.arrayLength, (unsigned long)d.depth);
        return nil; }
    uint32_t vkf = 0, bpp = 0; int a8 = 0;
    if (nvmtl_pixfmt_public(d.pixelFormat, &vkf, &bpp, &a8)) {
        nvlog("buffer newTextureWithDescriptor: pixelFormat %lu has no VkFormat -> nil", (unsigned long)d.pixelFormat); return nil; }
    NVMTLTexture *t = [NVMTLTexture new];
    static int noRecycle = -1; if (noRecycle < 0) { noRecycle = getenv("NVMTL_NO_BUFTEX_RECYCLE") != NULL;
        nvlog("buffer texture: dres R3 recycle %s", noRecycle ? "OFF (NVMTL_NO_BUFTEX_RECYCLE)" : "ON"); }
    const uint32_t bkey[12] = { 2, (uint32_t)w, (uint32_t)h, vkf, bpp, (uint32_t)a8, NVMTL_USAGE_WRITES(d.usage),
        (d.usage & MTLTextureUsageRenderTarget) != 0, (uint32_t)offset, (uint32_t)((uint64_t)offset >> 32), (uint32_t)bpr, (uint32_t)((uint64_t)bpr >> 32) };
    const BOOL brec = !noRecycle && _nbpk && nvmtl_bpark_take(self, bkey, &t->_i) == 0;
    if (!brec && nvmtl_vk_image_create_buffer_alias((uint32_t)w, (uint32_t)h, vkf, bpp, a8, NVMTL_USAGE_WRITES(d.usage),
                                           (d.usage & MTLTextureUsageRenderTarget) != 0, &_b, offset, bpr, &t->_i)) {
        nvlog("buffer newTextureWithDescriptor:offset:%lu bytesPerRow:%lu (%zux%zu fmt %lu, buffer %lu B, storage %lu) -> nil (reason above)",
              (unsigned long)offset, (unsigned long)bpr, w, h, (unsigned long)d.pixelFormat, (unsigned long)_b.size, (unsigned long)_storage);
        return nil; }
    t->_q = nvmtl_device_queue();
    t->_fmt = d.pixelFormat; t->_mips = 1;
    t->_stex = nvmtl_vk_image_self_storage(&t->_i) != 0;
    t->_ropt |= (MTLResourceOptions)d.storageMode << MTLResourceStorageModeShift;
    t->_usage = d.usage;
    _texSeen = YES;
    t->_backBuf = self; t->_backOff = offset; t->_backBPR = bpr;
    { extern void nvmtl_shm_note_buftex(const nvk_buffer *, size_t, size_t, unsigned);
      if (_b.shm && (d.usage == MTLTextureUsageUnknown || NVMTL_USAGE_WRITES(d.usage) || (d.usage & MTLTextureUsageRenderTarget))) nvmtl_shm_note_buftex(&_b, offset, (size_t)bpr * h, (unsigned)d.usage); }
    t->_bparkable = !noRecycle; memcpy(t->_pkey, bkey, sizeof bkey);
    atomic_fetch_add(brec ? &gBTRecycled : &gBTNew, 1); nvmtl_buftex_census(brec ? "recycled" : "new");
    nvmtl_texture_desc_swizzle(t, d);
    nvlog("buffer %p newTextureWithDescriptor:offset:%lu bytesPerRow:%lu -> %p (%zux%zu fmt %lu usage 0x%lx, storage %lu)", (__bridge void *)self,
          (unsigned long)offset, (unsigned long)bpr, (__bridge void *)t, w, h, (unsigned long)d.pixelFormat, (unsigned long)d.usage, (unsigned long)_storage);
    return t; }
- (void)setResponsibleProcess:(int)pid { static int said; if (!said++) nvlog("setResponsibleProcess: pid %d on a buffer - per-process attribution is not kept; nothing to set (said once)", pid); }
- (instancetype)initStandinWithDevice:(id)device bytesNoCopy:(void *)bytes length:(NSUInteger)length deallocator:(void (^)(void *, NSUInteger))deallocator {
    id d = device ? device : (id)gNVMTLMainDevice;
    id buf = [d newBufferWithBytesNoCopy:bytes length:length options:MTLResourceStorageModeShared deallocator:deallocator];
    { static int said; if (!said++) nvlog("initStandin: %lu-byte client-storage stand-in -> %s (said once)", (unsigned long)length,
                                          buf ? "a no-copy buffer over the caller's pages" : "nil (newBufferWithBytesNoCopy refused, reason above)"); }
    return buf;
}
- (NSUInteger)allocatedSize { return (NSUInteger)_b.size; }
- (id<MTLDevice>)device { return (id<MTLDevice>)gNVMTLMainDevice; }
- (MTLCPUCacheMode)cpuCacheMode { NVMTLBuffer *r = self; return nvmtl_res_cache(r->_heap ? r->_heap : r->_subHeap, r->_ropt); }
- (MTLHazardTrackingMode)hazardTrackingMode { NVMTLBuffer *r = self; return nvmtl_res_hazard(r->_heap ? r->_heap : r->_subHeap, r->_ropt); }
- (MTLResourceOptions)resourceOptions { return ((MTLResourceOptions)[self storageMode] << MTLResourceStorageModeShift) | (MTLResourceOptions)[self cpuCacheMode]
                                            | ((MTLResourceOptions)[self hazardTrackingMode] << MTLResourceHazardTrackingModeShift); }
- (BOOL)isAliasable { @synchronized (self) { return _aliased; } }
- (void)makeAliasable {
    NVMTLHeap *h = nil; NSUInteger c = 0, o = 0; BOOL p = NO;
    @synchronized (self) {
        if (!_subHeap || _aliased) return;
        h = _subHeap; c = _subCharge; _subCharge = 0; _aliased = YES;
        p = _subPlaced; o = _heapOffset; _subPlaced = NO;
    }
    if (c) { if (p) [h nvmtlGiveRange:o length:c]; [h nvmtlReleaseSubAllocation:c]; }
}
- (id<MTLBuffer>)remoteStorageBuffer { return nil; }
- (id<MTLBuffer>)newRemoteBufferViewForDevice:(id<MTLDevice>)d { return nil; }
- (kern_return_t)setOwnerWithIdentity:(task_id_token_t)t { return nvmtl_owner_check(t); }
- (uint64_t)gpuAddress { nvmtl_ab_register(self); return nvmtl_vk_buffer_address(&_b); }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)s {
    if (_heap || _subHeap || _hostPtr) return MTLPurgeableStateNonVolatile;
    MTLPurgeableState prev = nvmtl_purge(&_purge, s);
    nvmtl_purge_track(self, s);
    return prev;
}
- (void)addDebugMarker:(NSString *)m range:(NSRange)r {}
- (void)removeAllDebugMarkers {}
void nvmtl_vk_buffer_retire(nvk_buffer *b);
- (void)dealloc {
    if (_b.buf && nvmtl_trace_on()) nvtrace("BUFFREE 0x%llx len %zu", (unsigned long long)nvmtl_vk_buffer_address(&_b), _b.size);
    for (uint32_t k = 0; k < _nbpk; k++) nvmtl_vk_image_destroy(&_bpk[k].img);
    free(_bpk); _bpk = NULL; _nbpk = 0;
    nvmtl_vk_buffer_retire(&_b); if (_shadow.buf) nvmtl_vk_buffer_retire(&_shadow);
    if (_subHeap) { NVMTLHeap *h = _subHeap; NSUInteger c = _subCharge; _subHeap = nil; _subCharge = 0;
                    if (_subPlaced && c) { _subPlaced = NO; [h nvmtlGiveRange:_heapOffset length:c]; }
                    [h nvmtlReleaseSubAllocation:c]; }
    if (_hostDealloc) { void (^d)(void *, NSUInteger) = _hostDealloc; _hostDealloc = nil;
                        d(_hostPtr ?: _b.map, (NSUInteger)(_hostLen ?: _b.size)); } }
- (MTLStorageMode)storageMode { return _storage; }
- (void *)contents { nvmtl_buf_settle(self); return _shadow.map ? _shadow.map : (_hostPtr ? _hostPtr : _b.map); }
- (id<MTLHeap>)heap { return _heap ?: _subHeap; }
- (NSUInteger)heapOffset { return _heapOffset; }
- (NSUInteger)length { return _b.size; }
- (void)didModifyRange:(NSRange)r {
    nvmtl_buf_settle(self);
    if (_shadow.map) {
        if (r.location >= _b.size) return;
        NSUInteger n = MIN(r.length, _b.size - r.location);
        if (n) nvmtl_managed_mark(self, r.location, r.location + n);
        return;
    }
    nvmtl_buffer_sync_in(self); }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { _label = [l copy]; }
@end

#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
static void nvmtl_surf_dirty(NVMTLCommandBuffer *cb, NVMTLTexture *t) {
    if (!cb || !t) return;
    NVMTLTexture *r = t->_parent ? t->_parent : t;
    if (!r->_surf) return;
    if (!cb->_surfDirty) cb->_surfDirty = [NSMutableSet new];
    [cb->_surfDirty addObject:r];
}
// A texture a kernel writes through a storage binding although NVK cannot make it a storage image - an IOSurface in a
// pitch-linear layout (ImageIO's RGBA16Unorm HDR / gain-map output), or a format NVK refuses linear storage for. The
// binding fell back to the dummy image and every write vanished: HDR photos decoded black. The kernel now writes a
// storage twin of the same VkFormat in optimal tiling, filled from the texture when this encoder first binds it and
// copied back after every dispatch (nvmtl_storage_twins_out), the IOSurface marked dirty as for a direct write.
static void nvmtl_retain_resource(NVMTLCommandBuffer *cb, id resource);
// `writes`: the shader declares a storage binding there. A texture made with MTLTextureUsageUnknown (0) may be used
// any way Metal allows - ImageIO makes its HDR output IOSurface textures that way and writes them.
static void *nvmtl_storage_view_for(NVMTLCommandBuffer *cb, NVMTLTexture *t, BOOL writes) {
    if (!t) return NULL;
    if (t->_stex) return [t nvview];
    const MTLTextureUsage usage = (MTLTextureUsage)t->_usage;   // not -usage, which answers ShaderRead for Unknown
    if (!writes || !cb || cb->_c.in_rp || t->_parent || (usage && !NVMTL_USAGE_WRITES(usage))) return NULL;
    nvk_image *im = [t nvi];
    if (!im || !im->img || !im->w || !im->h || (im->mips ? im->mips : 1) > 1 || (im->layers ? im->layers : 1) > 1
        || im->mtl_type != 2 || (im->samples ? im->samples : 1) > 1 || im->bw > 1) return NULL;
    // Created once per texture; two command buffers may encode the same texture on different threads at once.
    @synchronized (t) {
        if (!t->_stTwin.img) {
            if (t->_stTwinTried) return NULL;
            t->_stTwinTried = YES;
            // An sRGB format cannot be a storage image in Vulkan at all. Its twin is half float, filled and written back by
            // blits that decode and encode sRGB, so a kernel writes linear values and the texture ends up sRGB-encoded,
            // as a write to an sRGB texture does on Apple GPUs (Blender's edit-mode overlay wrote RGBA8Unorm_sRGB).
            const int srgb = nvmtl_vk_srgb_format(im->fmt);
            if (nvmtl_vk_image_create_typed(im->w, im->h, srgb ? 97u : im->fmt, srgb ? 8u : im->bpp, 0, 1, 1, 2, 1, &t->_stTwin) || !t->_stTwin.storage) {
                if (t->_stTwin.img) nvmtl_vk_image_destroy(&t->_stTwin);
                memset(&t->_stTwin, 0, sizeof t->_stTwin);
                nvlog("storage twin: VkFormat %u %ux%u cannot be a storage image in optimal tiling either - shader writes to it are LOST", im->fmt, im->w, im->h);
                return NULL;
            }
            static int said; if (said++ < 4) nvlog("storage twin: %ux%u VkFormat %u%s is written through an optimal-tiled storage copy", im->w, im->h, im->fmt, t->_surf ? " (IOSurface)" : "");
        }
    }
    if (!cb->_stTwins) cb->_stTwins = [NSMutableSet new];
    if (![cb->_stTwins containsObject:t]) {
        if (t->_stTwin.fmt != im->fmt ? nvmtl_vk_cmd_blit_image_2d(&cb->_c, im, &t->_stTwin, im->w, im->h)
                                      : nvmtl_vk_cmd_copy_image_sub(&cb->_c, im, 0, 0, 0, 0, &t->_stTwin, 0, 0, 0, 0, im->w, im->h)) return NULL;
        [cb->_stTwins addObject:t];
        nvmtl_retain_resource(cb, t);
    }
    nvmtl_vk_cmd_prepare_sampled_image(&cb->_c, &t->_stTwin, 1);
    return t->_stTwin.view;
}
NSDictionary *nvmtl_function_reflection(NVMTLFunction *function);
static BOOL nvmtl_function_writes_texture(NVMTLFunction *fn, NSUInteger index) {
    NSArray *bindings = fn ? nvmtl_function_reflection(fn)[@"bindings"] : nil;
    if (![bindings isKindOfClass:[NSArray class]]) return NO;
    for (NSDictionary *b in bindings) {
        if (![b isKindOfClass:[NSDictionary class]] || [b[@"metal_index"] unsignedLongValue] != index) continue;
        NSString *kind = b[@"kind"], *access = b[@"access"];
        if (![kind isKindOfClass:[NSString class]] || [kind hasPrefix:@"Embedded"] || [kind isEqualToString:@"Buffer"] || [kind isEqualToString:@"Sampler"]
            || [kind isEqualToString:@"StaticSampler"]) continue;
        if ([kind isEqualToString:@"StorageImage"] || ([access isKindOfClass:[NSString class]] && ([access isEqualToString:@"Storage"] || [access isEqualToString:@"ReadWrite"] || [access isEqualToString:@"WriteOnly"]))) return YES;
    }
    return NO;
}
static void nvmtl_storage_twins_out(NVMTLCommandBuffer *cb) {
    for (NVMTLTexture *t in cb->_stTwins) {
        nvk_image *im = [t nvi];
        if (t->_stTwin.fmt != im->fmt ? nvmtl_vk_cmd_blit_image_2d(&cb->_c, &t->_stTwin, im, im->w, im->h)
                                      : nvmtl_vk_cmd_copy_image_sub(&cb->_c, &t->_stTwin, 0, 0, 0, 0, im, 0, 0, 0, 0, im->w, im->h)) {
            nvlog("storage twin: copy back to the %ux%u texture FAILED", im->w, im->h); continue; }
        nvmtl_vk_cmd_prepare_sampled_image(&cb->_c, &t->_stTwin, 1);
        nvmtl_surf_dirty(cb, t);
    }
}
static int g_trace_lines;
static int g_trace_bigonly, g_trace_mute;
static int nvmtl_trace_on(void) {
#if NVMTL_RELEASE
    return 0;   // the request files are refused in release builds (nvmtl_rel_access), so tracing never turns on
#endif
    // The request files are polled every 250 ms by a timer on a utility queue; this check only reads the flags. WAS: a
    // CLOCK_MONOTONIC_RAW read on every call to rate-limit the poll - nvtrace() guards sit on every draw and bind, and
    // those clock reads were 31 % of Cyberpunk 2077's on-CPU time (sample, 2026-11-08), starving submission.
    static _Atomic int on; static _Atomic int cap = 2500; static dispatch_once_t once;
    dispatch_once(&once, ^{
        static dispatch_source_t t;   // static: under ARC a local source is released, and cancelled, when the block returns
        t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), 250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(t, ^{
            const int was = atomic_load(&on), now_on = access("/tmp/nvmtl-trace-request", F_OK) == 0;
            g_trace_bigonly = now_on && access("/tmp/nvmtl-trace-big", F_OK) == 0; if (!g_trace_bigonly) g_trace_mute = 0;
            if (now_on && !was) { g_trace_lines = 0; atomic_store(&cap, access("/tmp/nvmtl-trace-huge", F_OK) == 0 ? 600000 : access("/tmp/nvmtl-trace-long", F_OK) == 0 ? 20000 : 2500); }
            atomic_store(&on, now_on);
        });
        dispatch_resume(t);
    });
    return atomic_load_explicit(&on, memory_order_relaxed) && !g_trace_mute && g_trace_lines < atomic_load_explicit(&cap, memory_order_relaxed);
}
static int nvtrace_scope(uint32_t w, uint32_t h) { int was = g_trace_mute; g_trace_mute = 0; (void)nvmtl_trace_on();
    g_trace_mute = g_trace_bigonly && (w < 1000 || h < 100); return was; }
static void nvtrace_emit(const char *fmt, ...) {
    if (!nvmtl_trace_on()) return;
    char p[96]; snprintf(p, sizeof p, "/tmp/nvmtl-trace-%d.txt", (int)getpid());
    int fd = open(p, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) { static int said; if (!said++) nvlog("G15 trace: cannot open %s (errno %d)", p, errno); return; }
    char b[700]; va_list a; va_start(a, fmt); int n = vsnprintf(b, sizeof b - 1, fmt, a); va_end(a);
    if (n < 0) n = 0; if (n > (int)sizeof b - 2) n = (int)sizeof b - 2;
    b[n++] = '\n'; if (write(fd, b, (size_t)n) != n) { static int said2; if (!said2++) nvlog("G15 trace: short write (errno %d)", errno); }
    close(fd); g_trace_lines++;
}
static void nvtrace_floats(const char *what, unsigned long idx, unsigned long off, const void *map, int nf) {
    if (!nvmtl_trace_on()) return;
    if (!map) { nvtrace("%s[%lu] off %lu (not CPU-visible)", what, idx, off); return; }
    const float *f = (const float *)((const char *)map + off); char s[420]; int k = 0;
    for (int i = 0; i < nf && k < (int)sizeof s - 16; i++) k += snprintf(s + k, sizeof s - (size_t)k, " %.3g", f[i]);
    nvtrace("%s[%lu] off %lu:%s", what, idx, off, s);
    if ((what[0] != 'F' && what[0] != 'K') || access("/tmp/nvmtl-trace-peek", F_OK)) return;
    // PEEK: every 8-byte word of the first 256 bytes that looks like a GPU address is resolved to the buffer it points into,
    // and the first descriptor-table entries there (IRDescriptorTableEntry: gpuVA, textureViewID, metadata) are decoded
    const uint64_t *w = (const uint64_t *)((const char *)map + off);
    for (int i = 0; i < 32; i++) {
        const uint64_t v = w[i]; if (v < (1ull << 32) || v >= (1ull << 40)) continue;
        uint64_t boff = 0; NVMTLBuffer *b = nvmtl_bufreg_find(v, &boff);
        if (!b) { nvtrace("  PEEK w%d 0x%llx -> no buffer of ours holds this address", i, (unsigned long long)v); continue; }
        const char *hm = b->_b.map ? (const char *)b->_b.map : (b->_shadow.map ? (const char *)b->_shadow.map : NULL);
        nvtrace("  PEEK w%d 0x%llx -> buffer %p len %zu +%llu %s%s", i, (unsigned long long)v, (__bridge void *)b, b->_b.size, (unsigned long long)boff,
                hm ? "host-visible" : "NOT host-visible", b->_shadow.map ? " (shadowed)" : "");
        if (!hm || boff + 72 > b->_b.size) continue;
        const uint64_t *e = (const uint64_t *)(hm + boff); const uint32_t next = nvmtl_vk_bindless_next();
        {   // the whole table region after the pointer (up to 1 MB): how many entries carry anything, and the first ones that do
            const uint64_t span = b->_b.size - boff; const uint32_t nent = (uint32_t)((span > (1u << 20) ? (1u << 20) : span) / 24);
            uint32_t nz = 0, tagged = 0, untagged = 0, vaOnly = 0; char first[200] = ""; int fl = 0;
            for (uint32_t k = 0; k < nent; k++) {
                const uint64_t va = e[3*k], id = e[3*k+1];
                if (!va && !id) continue;
                nz++; if (id) { if ((id >> 62) & 1) tagged++; else untagged++; } else vaOnly++;
                if (fl < (int)sizeof first - 60 && (id || tagged + untagged + vaOnly <= 2))
                    fl += snprintf(first + fl, sizeof first - (size_t)fl, " [%u: va 0x%llx id 0x%llx]", k, (unsigned long long)va, (unsigned long long)id);
            }
            nvtrace("    SCAN %u entries: %u non-empty (ids: %u heap-tagged, %u untagged; %u va-only)%s", nent, nz, tagged, untagged, vaOnly, first);
            extern id nvmtl_resid_resource(uint64_t token); int shown = 0;
            for (uint32_t k = 0; k < nent && shown < 4; k++) {
                const uint64_t rid = e[3*k+1]; if (!rid || !((rid >> 62) & 1)) continue;
                id obj = nvmtl_resid_resource(rid); shown++;
                if (!obj || ![obj isKindOfClass:[NVMTLTexture class]]) { nvtrace("    OBJ [%u] id 0x%llx -> %s", k, (unsigned long long)rid, obj ? object_getClassName(obj) : "GONE (released)"); continue; }
                NVMTLTexture *t = obj; nvk_image *im = [t nvi];
                // TEXDUMP: the first 12 distinct large textures the tables resolve to are read back (level 0, slice 0) once
                // their command buffer completes, to /tmp/nvmtl-obj-<ptr>-WxH-fmt<vk>-bpp<b>.raw, so what the shaders
                // sample can be looked at (passdump2png.py renders R8 / RGBA8 / RGBA16F; BC stays raw)
                if (im && im->w >= 512 && im->bw <= 1 && im->samples <= 1 && (im->bpp == 1 || im->bpp == 2 || im->bpp == 4 || im->bpp == 8) && !t->_viewParent) {
                    static NSMutableSet *dumped; static int ndumped; if (!dumped) dumped = [NSMutableSet new];
                    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)t];
                    if (ndumped < 12 && ![dumped containsObject:key]) { [dumped addObject:key]; ndumped++;
                        // read now, on this thread, as the G17 blit dump does: the content is whatever earlier command buffers left
                        const uint32_t w = im->w, h = im->h, bpp = im->bpp, fmt = im->fmt; const size_t row = (size_t)w * bpp; void *px = malloc(row * h);
                        if (px) { if (t->_q && nvmtl_vk_image_read(t->_q, im, px, row)) nvlog("texdump: readback FAILED for %p", (__bridge void *)t);
                                  else { char path[256]; snprintf(path, sizeof path, "/tmp/nvmtl-obj-%p-%ux%u-fmt%u-bpp%u.raw", (__bridge void *)t, w, h, fmt, bpp);
                                         int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600); if (fd >= 0) { ssize_t wr = write(fd, px, row * h); (void)wr; close(fd); nvlog("texdump: %s", path); } }
                                  free(px); } } }
                nvtrace("    OBJ [%u] id 0x%llx -> %s %p(img %p parent %p heap %p+%lu usage 0x%lx stex %d vkusage 0x%x vkflags 0x%x) textureType %lu %lux%lu mips %lu layers %lu fmt %lu | image mtl_type %u %ux%u mips %u layers %u vkfmt %u | base level %u slice %u, view slices %u, view type %u, heap-placed %d",
                        k, (unsigned long long)rid, t->_viewParent ? "VIEW" : "texture", (__bridge void *)t, im ? im->img : NULL, (__bridge void *)t->_viewParent, (__bridge void *)t->_heap, (unsigned long)t->_heapOffset,
                        (unsigned long)t->_usage, (int)t->_stex, im ? im->usage : 0u, im ? im->vkflags : 0u, (unsigned long)t.textureType, (unsigned long)t.width, (unsigned long)t.height,
                        (unsigned long)t.mipmapLevelCount, (unsigned long)t.arrayLength, (unsigned long)t.pixelFormat, im ? im->mtl_type : 0, im ? im->w : 0, im ? im->h : 0,
                        im ? im->mips : 0, im ? im->layers : 0, im ? im->fmt : 0, t->_baseLevel, t->_baseSlice, t->_viewSlices, t->_viewType, im ? im->placed : 0);
            }
        }
        for (int k = 0; k < 3; k++) {
            const uint64_t va = e[3*k], id = e[3*k+1], meta = e[3*k+2]; const uint32_t slot = (uint32_t)(id & 131071u), sslot = (uint32_t)(va & 2047u);
            nvtrace("    e%d va 0x%llx id 0x%llx meta 0x%llx | as texture: %s slot %u %s | as sampler: va low %u", k, (unsigned long long)va, (unsigned long long)id,
                    (unsigned long long)meta, (id >> 62) & 1 ? "HEAP-tagged" : "untagged", slot, slot && slot < next ? "issued" : "NOT ISSUED", sslot);
        }
    }
}
static void nvmtl_nonzero(const void *base, size_t row, size_t rowValid, uint32_t h, unsigned *nz, unsigned *n) {
    *nz = *n = 0; if (!base || !rowValid || !h) return;
    size_t take = rowValid < 256 ? rowValid : 256; uint32_t step = h > 16 ? h / 16 : 1;
    for (uint32_t y = 0; y < h; y += step) { const unsigned char *p = (const unsigned char *)base + (size_t)y * row;
        for (size_t x = 0; x < take; x++) { *nz += p[x] != 0; (*n)++; } }
}
// A full overwrite of a single 8-bit RGBA/BGRA subresource cannot consume the previous CPU contents.
// Keep all partial updates, views, arrays, volumes, compressed and multisample images
// on SurfaceIn: their untouched bytes still have to be preserved.
static BOOL nvmtl_surface_full_overwrite(NVMTLTexture *t, MTLRegion r, NSUInteger level, NSUInteger slice) {
    if (!t || !t->_surf || t->_parent || t->_viewParent || t->_tbView || t->_baseLevel || t->_baseSlice || level || slice)
        return NO;
    const nvk_image *i = &t->_i;
    if (i->bpp != 4 || (t->_fmt != MTLPixelFormatBGRA8Unorm && t->_fmt != MTLPixelFormatBGRA8Unorm_sRGB
        && t->_fmt != MTLPixelFormatRGBA8Unorm && t->_fmt != MTLPixelFormatRGBA8Unorm_sRGB)) return NO;
    return i->mtl_type == MTLTextureType2D && i->mips == 1 && i->layers == 1 && i->samples <= 1
        && i->bw <= 1 && i->bh <= 1 && !r.origin.x && !r.origin.y && !r.origin.z
        && r.size.width == i->w && r.size.height == i->h && r.size.depth == 1;
}
// A recorded overwrite only defines contents for subsequent commands in this
// command buffer. Do not promote global Seed/generation state before it executes:
// an abandoned command buffer must leave SurfaceIn able to restore CPU contents.
static void nvmtl_surface_overwrite_recorded(NVMTLCommandBuffer *cb, NVMTLTexture *t) {
    if (!cb || !t) return;
    NVMTLTexture *r = t->_parent ? t->_parent : t;
    if (!r->_surf) return;
    if (!cb->_surfOverwrites) cb->_surfOverwrites = [NSMutableSet new];
    [cb->_surfOverwrites addObject:r];
}
static BOOL nvmtl_surface_pending_write(NVMTLCommandBuffer *cb, NVMTLTexture *t);
static void nvmtl_surface_in_for_cb(NVMTLCommandBuffer *cb, NVMTLTexture *t) {
    if (!t) return;
    NVMTLTexture *r = t->_parent ? t->_parent : t;
    if (cb && r->_surf && [cb->_surfOverwrites containsObject:r]) return;
    // A prior committed buffer defines this GPU backing's contents.
    // Importing the old CPU surface here would run ahead of this buffer and
    // overwrite that earlier GPU write. Queue order or the application's event supplies the dependency.
    if (nvmtl_surface_pending_write(cb, r)) return;
    [t nvmtlSurfaceIn];
}
static unsigned nvmtl_surf_id(NVMTLTexture *t) { NVMTLTexture *r = (t && t->_parent) ? t->_parent : t; return (r && r->_surf) ? (unsigned)IOSurfaceGetID(r->_surf) : 0u; }
static int nvmtl_noseed(void) { static uint64_t next; static int on; uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    if (now >= next) { next = now + 250000000ull; int was = on; on = access("/tmp/nvmtl-noseed", F_OK) == 0;
        if (on && !was) nvlog("G17 EXPERIMENT ON: surface-out writes under a read-only lock, the IOSurface seed does not move");
        if (!on && was) nvlog("G17 experiment off: surface-out bumps the seed again"); }
    return on; }
static void nvmtl_census(const char *what, uint32_t w, uint32_t h, int surf) {
    static struct { const char *what; uint32_t w, h; int surf; } seen[48]; static int n; static os_unfair_lock lk = OS_UNFAIR_LOCK_INIT;
    if (__atomic_load_n(&n, __ATOMIC_RELAXED) == 48) return;   // full: every later pass skips the lock
    os_unfair_lock_lock(&lk);
    for (int i = 0; i < n; i++) if (seen[i].what == what && seen[i].w == w && seen[i].h == h && seen[i].surf == surf) { os_unfair_lock_unlock(&lk); return; }
    if (n == 48) { os_unfair_lock_unlock(&lk); return; }
    seen[n].what = what; seen[n].w = w; seen[n].h = h; seen[n].surf = surf; __atomic_store_n(&n, n + 1, __ATOMIC_RELAXED);
    os_unfair_lock_unlock(&lk);
    nvlog("G14 census: %s %ux%u iosurface=%d (first time in this process)", what, w, h, surf);
}
static void nvmtl_frame_dump(const char *tag, const void *base, size_t row, uint32_t w, uint32_t h);
static void nvmtl_surface_cpu_dump(NVMTLTexture *rt) {
    static uint64_t next; static int on;
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    if (now >= next) { next = now + 250000000ull; on = access("/tmp/nvmtl-dump-request", F_OK) == 0; }
    if (!on || !rt || !rt->_surf || IOSurfaceGetBytesPerElement(rt->_surf) != 4 || IOSurfaceGetPlaneCount(rt->_surf) > 1) return;
    if (IOSurfaceLock(rt->_surf, kIOSurfaceLockReadOnly, NULL) != kIOReturnSuccess) { static int said; if (!said++) nvlog("G16 cpu dump: IOSurfaceLock failed"); return; }
    char tag[24]; snprintf(tag, sizeof tag, "cpu%u-", (unsigned)IOSurfaceGetID(rt->_surf));
    nvmtl_frame_dump(tag, IOSurfaceGetBaseAddress(rt->_surf), IOSurfaceGetBytesPerRow(rt->_surf), (uint32_t)IOSurfaceGetWidth(rt->_surf), (uint32_t)IOSurfaceGetHeight(rt->_surf));
    IOSurfaceUnlock(rt->_surf, kIOSurfaceLockReadOnly, NULL);
}
static void nvmtl_frame_dump(const char *tag, const void *base, size_t row, uint32_t w, uint32_t h) {
    if ((uint64_t)w * h < 1024 || access("/tmp/nvmtl-dump-request", F_OK)) return;
    static struct { char tag[24]; uint32_t w, h; uint64_t last; } slot[32]; static int nslot;
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW); int k, go = 0;
    @synchronized([NSObject class]) {
        for (k = 0; k < nslot; k++) if (slot[k].w == w && slot[k].h == h && !strncmp(slot[k].tag, tag, sizeof slot[k].tag - 1)) break;
        if (k == nslot && nslot < 32) { snprintf(slot[k].tag, sizeof slot[k].tag, "%s", tag); slot[k].w = w; slot[k].h = h; slot[k].last = 0; nslot++; }
        if (k < nslot && (!slot[k].last || now - slot[k].last >= 2000000000ull)) { slot[k].last = now; go = 1; }
    }
    if (!go) return;
    char dst[400], tmp[416]; const char *dir = "/tmp"; int fd = -1;
    for (int pass = 0; pass < 2 && fd < 0; pass++) {
        if (pass) { const char *t = getenv("TMPDIR"); if (!t || !*t || (errno != EPERM && errno != EACCES)) break; dir = t; }
        size_t dl = strlen(dir); const char *sep = (dl && dir[dl - 1] == '/') ? "" : "/";
        snprintf(dst, sizeof dst, "%s%snvmtl-frame-%d-%.23s%ux%u.bgra", dir, sep, (int)getpid(), tag, w, h); snprintf(tmp, sizeof tmp, "%s.tmp", dst);
        fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    }
    if (fd < 0) { static int said; if (!said++) nvlog("G13 frame dump: cannot open %s (errno %d)", tmp, errno); return; }
    uint32_t hdr[4] = { 0x3146564e , w, h, (uint32_t)row };
    int ok = write(fd, hdr, sizeof hdr) == (ssize_t)sizeof hdr && write(fd, base, row * h) == (ssize_t)(row * h);
    close(fd);
    if (ok && rename(tmp, dst) == 0) { static int told; if (!told++) nvlog("G13 frame dump: %ux%u written to %s", w, h, dst); }
    else { unlink(tmp); static int said2; if (!said2++) nvlog("G13 frame dump: write FAILED (errno %d)", errno); }
}
static void nvmtl_blit_dump(NVMTLTexture *d) {
    nvk_image *i = [d nvi]; if (!i || i->w < 1000 || i->h < 100 || i->bpp != 4) return;
    static uint64_t last; uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    if ((last && now - last < 2000000000ull) || access("/tmp/nvmtl-dump-request", F_OK)) return;
    last = now; size_t row = (size_t)i->w * 4; void *px = malloc(row * i->h);
    if (!px) { nvlog("G17 blit dump: malloc FAILED"); return; }
    if (nvmtl_vk_image_read(d->_q, i, px, row)) nvlog("G17 blit dump: readback FAILED");
    else { char tag[24]; snprintf(tag, sizeof tag, "blit%u-", nvmtl_surf_id(d)); nvmtl_frame_dump(tag, px, row, i->w, i->h); }
    free(px);
}
#pragma mark - texture
static _Atomic unsigned long long nvmtl_tex_objs_made, nvmtl_tex_objs_gone;
unsigned long long nvmtl_tex_objs_live(void) {
    unsigned long long made = nvmtl_tex_objs_made, gone = nvmtl_tex_objs_gone;
    return made > gone ? made - gone : 0;
}
unsigned long long nvmtl_tex_objs_released(void) { return nvmtl_tex_objs_gone; }
@implementation NVMTLTexture
+ (instancetype)alloc { nvmtl_tex_objs_made++; return [super alloc]; }
- (instancetype)init { if ((self = [super init])) _hBornFrame = atomic_load_explicit(&nvmtl_flick_frame, memory_order_relaxed); return self; }
- (void)setResponsibleProcess:(int)pid { static int said; if (!said++) nvlog("setResponsibleProcess: pid %d on a texture - per-process attribution is not kept; nothing to set (said once)", pid); }
- (unsigned long long)protectionOptions { return 0; }
- (NSUInteger)allocatedSize { nvk_image *i = [self nvi]; if (i->alloc) return (NSUInteger)i->alloc;
    NSUInteger l = i->layers ? i->layers : 1, m = i->mips ? i->mips : 1, bpp = i->bpp ? i->bpp : 4, bw = i->bw ? i->bw : 1, bh = i->bh ? i->bh : 1, tot = 0;
    for (NSUInteger k = 0; k < m; k++) { NSUInteger w = i->w >> k ? i->w >> k : 1, h = i->h >> k ? i->h >> k : 1; tot += ((w + bw - 1) / bw) * ((h + bh - 1) / bh) * bpp; }
    return tot * l; }
- (MTLResourceID)gpuResourceID {
    @synchronized (self) { if (!_resid) _resid = nvmtl_resid_for_texture(self); }
    MTLResourceID rid; rid._impl = _resid; return rid;
}
extern int nvmtl_depthfmt_public(MTLPixelFormat, uint32_t *, uint32_t *);
- (nvk_image *)nvi { return _parent ? [_parent nvi] : &_i; }
- (void *)nvview {
    nvk_image *image = [self nvi];
    if (image->fmt == VK_FORMAT_D16_UNORM_S8_UINT || image->fmt == VK_FORMAT_D24_UNORM_S8_UINT || image->fmt == VK_FORMAT_D32_SFLOAT_S8_UINT) {
        uint32_t format = 0, aspect = 0;
        nvmtl_depthfmt_public(self.pixelFormat, &format, &aspect);
        if (aspect != VK_IMAGE_ASPECT_STENCIL_BIT) {
            @synchronized(self) {
                if (!_sampledDepthView && nvmtl_vk_image_view_create_range_aspect(image, image->fmt, 0, VK_IMAGE_ASPECT_DEPTH_BIT, _baseLevel, (uint32_t)self.mipmapLevelCount, _baseSlice, _parent ? _viewSlices : image->layers, (uint32_t)self.textureType, &_sampledDepthView)) return NULL;
                return _sampledDepthView;
            }
        }
    }
    return _ownView ? _ownView : image->view;
}
- (void *)nvsampleview { return _swzView ? _swzView : [self nvview]; }
/* MTLTextureDescriptor.swizzle applies when the texture is sampled or read, not to attachments or shader writes, so it
 * gets a view of its own for the sampled binds and the identity view stays for everything else. IconServices hands
 * gray + alpha image layers over as RG8 with swizzle (r, r, r, g); with the swizzle dropped, alpha landed in green. */
void nvmtl_texture_desc_swizzle(NVMTLTexture *t, MTLTextureDescriptor *d) {
    { extern int nvmtl_vk_mark_on(void); extern int nvmtl_vk_image_mark(nvk_image *im);
      if (t && d && !t->_parent && !t->_surf && !t->_tbView && nvmtl_vk_mark_on() && d.storageMode == MTLStorageModePrivate
          && (d.usage & ~(NSUInteger)MTLTextureUsagePixelFormatView) == MTLTextureUsageShaderRead) nvmtl_vk_image_mark(&t->_i); }
    if (!t || !d || ![d respondsToSelector:@selector(swizzle)]) return;
    const MTLTextureSwizzleChannels sw = d.swizzle;
    if (sw.red == MTLTextureSwizzleRed && sw.green == MTLTextureSwizzleGreen && sw.blue == MTLTextureSwizzleBlue && sw.alpha == MTLTextureSwizzleAlpha) return;
    t->_swz = sw; t->_hasSwz = YES;
    if (d.textureType == MTLTextureTypeTextureBuffer || d.sampleCount > 1 || t->_tbView) {
        nvlog("texture swizzle %u,%u,%u,%u on texture type %lu (samples %lu) is not applied", sw.red, sw.green, sw.blue, sw.alpha,
              (unsigned long)d.textureType, (unsigned long)d.sampleCount); return; }
    extern int nvmtl_pixfmt_public(MTLPixelFormat f, uint32_t *vk, uint32_t *bpp, int *a8);
    uint32_t vkf = 0, bpp = 0; int a8 = 0;
    const uint8_t s4[4] = { (uint8_t)sw.red, (uint8_t)sw.green, (uint8_t)sw.blue, (uint8_t)sw.alpha };
    if (nvmtl_pixfmt_public(d.pixelFormat, &vkf, &bpp, &a8) ||
        nvmtl_vk_image_view_create_range_swz([t nvi], vkf, a8, 0, 0, 0, 0, (uint32_t)d.textureType, s4, &t->_swzView)) {
        t->_swzView = NULL;
        nvlog("texture swizzle FAILED: no swizzled view for format %lu - samples keep the identity mapping", (unsigned long)d.pixelFormat); return; }
    { static int said; if (said++ < 8) nvlog("texture swizzle: format %lu samples r,g,b,a <- %u,%u,%u,%u", (unsigned long)d.pixelFormat, s4[0], s4[1], s4[2], s4[3]); }
}
- (id<MTLHeap>)heap { return _heap ?: _subHeap; }
- (NSUInteger)heapOffset { return _heapOffset; }
- (void)dealloc {
    nvmtl_tex_objs_gone++;
    if (_resid) nvmtl_resid_texture_gone(_resid);   // heap slots back to the dummies before anything behind them goes
    if (_parent) {
        atomic_fetch_add(&nvmtl_fm_views_gone, 1);
        static int now = -1;
        if (now < 0) { const char *e = getenv("NVMTL_VIEW_GRAVE"); now = e && e[0] == '0';
            nvlog("texture views: %s (NVMTL_VIEW_GRAVE=%s)", now ? "destroyed at release (old rule)"
                  : "a released view's VkImageViews wait in the graveyard like a texture's - on NVK a view descriptor is a slot in the device image table, freed and handed to the next view at destroy",
                  e ? e : "unset"); }
        if (now) {
            if (_sampledDepthView) nvmtl_vk_image_view_destroy(_sampledDepthView);
            if (_tbView || _tbAlias) nvmtl_vk_texel_view_destroy(_tbAlias, _tbView);
            if (_ownView) nvmtl_vk_image_view_destroy(_ownView);
            if (_swzView) nvmtl_vk_image_view_destroy(_swzView);
        } else if (_sampledDepthView || _ownView || _swzView || _tbView || _tbAlias) {
            nvmtl_vk_image_retire(NULL, _sampledDepthView, _ownView, _swzView, _tbAlias, _tbView);
            static _Atomic uint64_t n; const uint64_t k = atomic_fetch_add(&n, 1) + 1;
            if (!(k & (k - 1)) && k >= 16) nvlog("texture views: %llu released views kept their VkImageViews until the GPU work committed before them completed", (unsigned long long)k);
        }
        _sampledDepthView = _ownView = _swzView = NULL; _tbView = _tbAlias = NULL;
    } else {
        if (_parkable && _subHeap && _i.img) nvmtl_heap_park(_subHeap, &_i, _pkey, _heapOffset, _pkLen);
        if (_bparkable && _backBuf && _i.img) nvmtl_bpark_put(_backBuf, &_i, _pkey);
        // the image and its views wait in the graveyard until the GPU work committed so far has completed
        nvmtl_vk_image_retire(&_i, _sampledDepthView, _ownView, _swzView, _tbAlias, _tbView);
        _tbView = _tbAlias = NULL;
    }
    if (_stTwin.img) nvmtl_vk_image_retire(&_stTwin, NULL, NULL, NULL, NULL, NULL);
    if (!_parent && _vramOn) { nvmtl_vk_buffer_destroy(&_vramBuf); _vramOn = NO; }
    if (!_parent) nvmtl_vk_host_pages_drop(&_hostPages);
    if (_surfOwned && _surf) CFRelease(_surf);
    if (_subHeap) { NVMTLHeap *h = _subHeap; NSUInteger c = _subCharge; _subHeap = nil; _subCharge = 0;
                    if (_subPlaced && c) { _subPlaced = NO; [h nvmtlGiveRange:_heapOffset length:c]; }
                    [h nvmtlReleaseSubAllocation:c]; }
}
- (BOOL)nvmtlSurfaceCopyable {
    size_t rowBytes = (size_t)_i.w * _i.bpp;
    size_t surfaceBytes = IOSurfaceGetWidthOfPlane(_surf, (uint32_t)_plane)
                        * IOSurfaceGetBytesPerElementOfPlane(_surf, (uint32_t)_plane);
    // The copy must also end inside the surface's allocation. Two Tahoe machines crashed in the row copy at a page
    // boundary while width, height and bytes per row all passed; the plane's rows can describe more memory than the
    // surface owns.
    const size_t bpr = IOSurfaceGetBytesPerRowOfPlane(_surf, (uint32_t)_plane);
    const uintptr_t b0 = (uintptr_t)IOSurfaceGetBaseAddress(_surf), bp = (uintptr_t)IOSurfaceGetBaseAddressOfPlane(_surf, (uint32_t)_plane);
    const size_t alloc = IOSurfaceGetAllocSize(_surf);
    const BOOL inAlloc = b0 && bp >= b0 && _i.h && bp - b0 <= alloc
        && (size_t)(_i.h - 1) <= (alloc - (bp - b0) - MIN(rowBytes, alloc - (bp - b0))) / (bpr ? bpr : 1)
        && rowBytes <= alloc - (bp - b0);
    if (_i.bpp && rowBytes <= surfaceBytes
        && IOSurfaceGetHeightOfPlane(_surf, (uint32_t)_plane) >= _i.h
        && bpr >= rowBytes && inAlloc) return YES;
    if (_i.bpp && !inAlloc) {
        static int saidAlloc; if (saidAlloc++ < 4) nvlog("G13 surface %p plane %lu NOT synced: %u rows of %zu B from plane offset %zu pass the surface's %zu-byte allocation",
            (void *)_surf, (unsigned long)_plane, _i.h, bpr, (size_t)(bp - b0), alloc);
        return NO;
    }
    static int said; if (said++ < 4) nvlog("G13 surface %p plane %lu NOT synced: image %ux%u bpp %u, surface bytesPerElement %zu — its pixels stay on one side",
        (void *)_surf, (unsigned long)_plane, _i.w, _i.h, _i.bpp, IOSurfaceGetBytesPerElementOfPlane(_surf, (uint32_t)_plane));
    return NO;
}
// IOSurface locking wires memory and updates its seed; it does not serialize
// this process's GPU readback and CPU import. Every wrapper of one plane must
// use the same monitor, including wrappers of shared family VRAM.
static id nvmtl_surface_sync(NVMTLTexture *t) {
    static char key;
    static NSMapTable *monitors;
    @synchronized ([NVMTLTexture class]) {
        id monitor = objc_getAssociatedObject(t, &key);
        if (!monitor) {
            if (!monitors) monitors = [NSMapTable strongToWeakObjectsMapTable];
            NSArray *surface = @[@(IOSurfaceGetID(t->_surf)), @(t->_plane)];
            monitor = [monitors objectForKey:surface];
            if (!monitor) { monitor = [NSObject new]; [monitors setObject:monitor forKey:surface]; }
            objc_setAssociatedObject(t, &key, monitor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return monitor;
    }
}
// NVMTL_SURFIN_UPLOAD=cpu: surface-in copies with the CPU (nvmtl_vk_image_write) instead of importing the pages.
// On Apple Silicon the CPU copy is the DEFAULT (NVMTL_SURFIN_UPLOAD=import opts back into pinning): the seventh AMCC
// UNEXP_RT_HIT_DIR panic of 2026-11-04 was the first with an allocation snapshot beside the game, and its address
// was inside a pinned 1280x800 drawable plane (docs/ARM64-PORT-NOTES.md item 30). The card's access to a
// CoreAnimation drawable's own pages is treated as non-coherent by the fabric, and a CPU holding one of those
// lines (WindowServer, a screenshot, anything) is a kernel panic; a staging copy through NVK memory never is.
static bool nvmtl_arm64_host(void) {
#if defined(__arm64__)
    return true;
#else
    return false;
#endif
}
static bool nvmtl_surfin_import(void) {
    static int on = -1;
    if (on < 0) { const char *u = getenv("NVMTL_SURFIN_UPLOAD");
        on = u ? !strcmp(u, "import") : !nvmtl_arm64_host();
        nvlog("surface-in: %s (NVMTL_SURFIN_UPLOAD=%s)", on ? "the GPU reads the surface's own pages" : "CPU copy through staging", u ? u : "unset"); }
    return on;
}
// NVMTL_SURFOUT_READBACK=cpu: surface-out reads back through the staging buffer and a CPU copy (nvmtl_vk_image_read)
// instead of the GPU writing the surface's own pages; the default on Apple Silicon, see above (=import opts back in)
static bool nvmtl_surfout_import(void) {
    static int on = -1;
    if (on < 0) { const char *u = getenv("NVMTL_SURFOUT_READBACK");
        on = u ? !strcmp(u, "import") : !nvmtl_arm64_host();
        nvlog("surface-out: %s (NVMTL_SURFOUT_READBACK=%s)", on ? "the GPU writes the surface's own pages" : "CPU copy through staging", u ? u : "unset"); }
    return on;
}
- (void)nvmtlSurfaceIn {
    NVMTLTexture *r = _parent ? _parent : self;
    if (!r->_surf) return;
    @synchronized (nvmtl_surface_sync(r)) {
    if (r->_clientWritten) nvmtl_busy_wait(r->_surf, r->_plane);
    const uint32_t vgen = r->_vramOn ? 0 : nvmtl_vram_gen(r->_surf, r->_plane);
    if (r->_surfSynced && IOSurfaceGetSeed(r->_surf) == r->_surfSeed && (r->_vramOn || vgen == r->_surfGen)) return;
    if (!r->_clientWritten && nvmtl_busy_foreign(r->_surf, r->_plane)) { r->_clientWritten = YES; nvmtl_busy_wait(r->_surf, r->_plane); }
    if (![r nvmtlSurfaceCopyable]) return;
    { uint32_t now = IOSurfaceGetSeed(r->_surf);
      if (r->_vramOn && nvmtl_vram_tag_current(r->_surf, r->_plane, now)) {
          r->_surfSeed = now; r->_surfSynced = YES; g_surfin_skip++;
          static unsigned ns; if (ns++ < 6 || ns % 2000 == 0) nvlog("item 7: surface-in SKIPPED (shared VRAM current at seed %u): %llu skipped, %llu copied", now, g_surfin_skip, g_surfin_copy);
          return; } }
    uint32_t seed = 0;
    if (IOSurfaceLock(r->_surf, kIOSurfaceLockReadOnly, &seed) != kIOReturnSuccess) { nvlog("G13 surface-in: IOSurfaceLock FAILED"); return; }
    void *base = IOSurfaceGetBaseAddressOfPlane(r->_surf, (uint32_t)r->_plane);
    size_t row = IOSurfaceGetBytesPerRowOfPlane(r->_surf, (uint32_t)r->_plane);
    int rc = -1;
    if (base && row && nvmtl_surfin_import()) {
        const size_t off = (size_t)((uint8_t *)base - (uint8_t *)IOSurfaceGetBaseAddress(r->_surf));
        rc = nvmtl_vk_image_write_host(r->_q, &r->_i, base, row, IOSurfaceGetAllocSize(r->_surf) - off, &r->_hostPages);
    }
    if (rc) rc = (base && row) ? nvmtl_vk_image_write(r->_q, &r->_i, base, row) : -1;
    if (!rc && r->_i.bpp == 4) { char tag[24]; snprintf(tag, sizeof tag, "in%u-", (unsigned)IOSurfaceGetID(r->_surf)); nvmtl_frame_dump(tag, base, row, r->_i.w, r->_i.h); }
    IOSurfaceUnlock(r->_surf, kIOSurfaceLockReadOnly, NULL);
    if (rc) { nvlog("G13 surface-in: upload FAILED (%ux%u) — retried at the next use", r->_i.w, r->_i.h); return; }
    r->_surfSeed = seed; r->_surfSynced = YES; r->_surfGen = vgen;
    g_surfin_copy++; if (r->_vramOn) nvmtl_vram_tag_set(r->_surf, r->_plane, seed);
    static unsigned n; if (n++ < 6 || n % 2000 == 0) nvlog("G13 surface-in #%u: %ux%u surface %p seed %u uploaded", n, r->_i.w, r->_i.h, (void *)r->_surf, seed);
    }
}
- (BOOL)nvmtlSurfaceOut { return [self nvmtlSurfaceOutDirtied:NO]; }
// A re-mark after the commit's (nvmtlSurfaceOutDirtied:) that found the accelerator lock taken is retried here, off the
// completion thread: a CPU lock that paged the surface off between the commit's two marks would otherwise leave its
// unfinished copy current until the surface is drawn again. Each retry is again a try that never waits for the lock,
// right after checking that the seed has not moved (a CPU write, or a newer commit marked it again): a mark that waited
// for the lock could land after a CPU write that came in meanwhile and make the older VRAM current over it. 50 tries,
// 2 ms apart; the texture then follows the seed the mark left.
static void nvmtl_surface_remark_later(NVMTLTexture *r, uint32_t seed) {
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("nvmtl.surface-remark", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(queue, ^{
        int marked = 1;
        for (int i = 0; i < 50 && marked > 0; i++) {
            if (i) usleep(2000);
            if (IOSurfaceGetSeed(r->_surf) != seed) return;
            marked = nvmtl_vk_surface_dirty_try((uint32_t)IOSurfaceGetID(r->_surf), (uint32_t)r->_plane);
        }
        if (marked) return;
        @synchronized (nvmtl_surface_sync(r)) {
            if (r->_surfSeed != seed) return;
            const uint32_t now = IOSurfaceGetSeed(r->_surf);
            r->_surfSeed = now; r->_surfGen = nvmtl_vram_tag_bump(r->_surf, r->_plane, now);
        }
    });
}
// dirtied: the commit already marked this surface's shared VRAM newest in the kernel (WindowServer, with an accelerator
// whose page-off waits for the GPU). It is marked again in case a CPU lock paged it off since, but only if the accelerator
// lock is free: a page-off waiting for another surface's pending GPU write holds that lock until the write is released,
// by the same completion thread that would be blocked here. Taken, the commit's mark stands and the re-mark is retried
// off this thread (nvmtl_surface_remark_later).
- (BOOL)nvmtlSurfaceOutDirtied:(BOOL)dirtied {
    NVMTLTexture *r = _parent ? _parent : self;
    if (!r->_surf) return YES;
    @synchronized (nvmtl_surface_sync(r)) {
    if (![r nvmtlSurfaceCopyable]) { nvtrace("SURFOUT surf %u %ux%u NOT copyable", (unsigned)IOSurfaceGetID(r->_surf), r->_i.w, r->_i.h); return NO; }
    nvtrace("SURFOUT surf %u %ux%u vramOn %d t=%llu", (unsigned)IOSurfaceGetID(r->_surf), r->_i.w, r->_i.h, (int)r->_vramOn,
            (unsigned long long)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000));
    const int marked = !r->_vramOn ? -1 : dirtied ? nvmtl_vk_surface_dirty_try((uint32_t)IOSurfaceGetID(r->_surf), (uint32_t)r->_plane)
                                                   : nvmtl_vk_surface_dirty((uint32_t)IOSurfaceGetID(r->_surf), (uint32_t)r->_plane);
    if (r->_vramOn && (dirtied || !marked)) {
        uint32_t seed = IOSurfaceGetSeed(r->_surf);
        r->_surfSeed = seed; r->_surfSynced = YES;
        r->_surfGen = nvmtl_vram_tag_bump(r->_surf, r->_plane, seed);
        if (dirtied && marked > 0) nvmtl_surface_remark_later(r, seed);
        static unsigned nd; if (nd++ < 6 || nd % 5000 == 0) nvlog("surface-out -> dirty, no copy (%ux%u surface %u seed %u, #%u)", r->_i.w, r->_i.h, (unsigned)IOSurfaceGetID(r->_surf), seed, nd);
        return YES;
    }
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    uint32_t lockopt = nvmtl_noseed() ? kIOSurfaceLockReadOnly : 0;
    if (IOSurfaceLock(r->_surf, lockopt, NULL) != kIOReturnSuccess) { nvlog("G13 surface-out: IOSurfaceLock FAILED"); return NO; }
    void *base = IOSurfaceGetBaseAddressOfPlane(r->_surf, (uint32_t)r->_plane);
    size_t row = IOSurfaceGetBytesPerRowOfPlane(r->_surf, (uint32_t)r->_plane);
    int rc = -1;
    if (base && row && nvmtl_surfout_import()) {
        const size_t off = (size_t)((uint8_t *)base - (uint8_t *)IOSurfaceGetBaseAddress(r->_surf));
        rc = nvmtl_vk_image_read_host(r->_q, &r->_i, base, row, IOSurfaceGetAllocSize(r->_surf) - off, &r->_hostPages);
    }
    if (rc) rc = (base && row) ? nvmtl_vk_image_read(r->_q, &r->_i, base, row) : -1;
    if (!rc && r->_i.bpp == 4) { char tag[24]; snprintf(tag, sizeof tag, "out%u-", (unsigned)IOSurfaceGetID(r->_surf)); nvmtl_frame_dump(tag, base, row, r->_i.w, r->_i.h); }
    uint32_t seed = 0; IOReturn unlocked = IOSurfaceUnlock(r->_surf, lockopt, &seed); if (lockopt) seed = IOSurfaceGetSeed(r->_surf);
    if (rc || unlocked != kIOReturnSuccess) { nvlog("G13 surface-out: readback FAILED (%ux%u)", r->_i.w, r->_i.h); return NO; }
    r->_surfSeed = seed; r->_surfSynced = YES;
    r->_surfGen = r->_vramOn ? r->_surfGen : nvmtl_vram_gen(r->_surf, r->_plane);
    if (r->_vramOn && !lockopt) nvmtl_vram_tag_set(r->_surf, r->_plane, seed);
    static unsigned n; if (n++ < 6 || n % 2000 == 0) nvlog("G13 surface-out #%u: %ux%u surface %p seed %u, %.2f ms", n, r->_i.w, r->_i.h,
        (void *)r->_surf, seed, (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - t0) / 1e6);
    return YES;
    }
}
- (NSUInteger)width  { return MAX(1u, [self nvi]->w >> _baseLevel); }
- (NSUInteger)height { return MAX(1u, [self nvi]->h >> _baseLevel); }
- (NSUInteger)depth  { nvk_image *i = [self nvi]; return i->mtl_type == 7 ? MAX(1u, i->layers >> _baseLevel) : 1; }
- (NSUInteger)mipmapLevelCount { if (_parent) return _mips ? _mips : 1; uint32_t m = [self nvi]->mips; return m ? m : 1; }
- (id<MTLTexture>)parentTexture { return _viewParent; }
- (id<MTLResource>)rootResource { return _viewParent ? (id<MTLResource>)_viewParent : (id<MTLResource>)_backBuf; }
- (kern_return_t)setOwnerWithIdentity:(task_id_token_t)t { return nvmtl_owner_check(t); }
- (NSUInteger)parentRelativeLevel { return _relativeLevel; }
- (NSUInteger)parentRelativeSlice { return _relativeSlice; }
- (NSUInteger)arrayLength { uint32_t l = _parent ? _viewSlices : ([self nvi]->layers ?: 1), t = (uint32_t)[self textureType]; return t == 6 ? l / 6 : (t == 1 || t == 3 || t == 8) ? l : 1; }
- (NSUInteger)sampleCount { return [self nvi]->samples > 1 ? [self nvi]->samples : 1; }
- (MTLTextureType)textureType { return (MTLTextureType)(_parent ? _viewType : [self nvi]->mtl_type); }
- (MTLPixelFormat)pixelFormat { return _fmt ? _fmt : MTLPixelFormatRGBA8Unorm; }
- (IOSurfaceRef)iosurface { return _shareable ? NULL : _surf; }
- (NSUInteger)iosurfacePlane { return _plane; }
- (MTLStorageMode)storageMode { NVMTLTexture *r = _parent ? _parent : self; if (r->_shareable) return MTLStorageModePrivate;
    NVMTLHeap *hp = r->_heap ? r->_heap : r->_subHeap; return hp ? hp->_storage : (MTLStorageMode)((r->_ropt >> MTLResourceStorageModeShift) & 0xF); }
- (BOOL)isFramebufferOnly { NVMTLTexture *r = _parent ? _parent : self; return r->_fbo; }
- (id<MTLDevice>)device { return (id<MTLDevice>)gNVMTLMainDevice; }
- (MTLCPUCacheMode)cpuCacheMode { NVMTLTexture *r = _parent ? _parent : self; return nvmtl_res_cache(r->_heap ? r->_heap : r->_subHeap, r->_ropt); }
- (MTLHazardTrackingMode)hazardTrackingMode { NVMTLTexture *r = _parent ? _parent : self; return nvmtl_res_hazard(r->_heap ? r->_heap : r->_subHeap, r->_ropt); }
- (MTLResourceOptions)resourceOptions { return ((MTLResourceOptions)[self storageMode] << MTLResourceStorageModeShift) | (MTLResourceOptions)[self cpuCacheMode]
                                            | ((MTLResourceOptions)[self hazardTrackingMode] << MTLResourceHazardTrackingModeShift); }
- (BOOL)isAliasable { @synchronized (self) { return _aliased; } }
- (void)makeAliasable {
    NVMTLHeap *h = nil; NSUInteger c = 0, o = 0; BOOL p = NO;
    @synchronized (self) {
        if (!_subHeap || _aliased) return;
        h = _subHeap; c = _subCharge; _subCharge = 0; _aliased = YES;
        p = _subPlaced; o = _heapOffset; _subPlaced = NO;
    }
    if (c) { if (p) [h nvmtlGiveRange:o length:c]; [h nvmtlReleaseSubAllocation:c]; }
}
- (MTLTextureUsage)usage { if (_usage) return (MTLTextureUsage)_usage; if (_parent) return [_parent usage]; return MTLTextureUsageShaderRead; }
- (id<MTLBuffer>)buffer { return _backBuf ? _backBuf : _parent ? [_parent buffer] : nil; }
- (NSUInteger)bufferOffset { return _backBuf ? _backOff : _parent ? [_parent bufferOffset] : 0; }
- (NSUInteger)bufferBytesPerRow { return _backBuf ? _backBPR : _parent ? [_parent bufferBytesPerRow] : 0; }
- (BOOL)isShareable { return _parent ? NO : _shareable; }
- (MTLTextureSwizzleChannels)swizzle { return _hasSwz ? _swz : MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha); }
- (BOOL)isSparse { NVMTLTexture *r = _parent ? _parent : self; return (r->_heap && r->_heap->_type == MTLHeapTypeSparse) || (r->_subHeap && r->_subHeap->_type == MTLHeapTypeSparse); }
- (uint32_t)swizzleKey { MTLTextureSwizzleChannels c = [self swizzle]; return (uint32_t)c.red | (uint32_t)c.green << 8 | (uint32_t)c.blue << 16 | (uint32_t)c.alpha << 24; }
- (BOOL)allowGPUOptimizedContents { return YES; }
- (MTLTextureCompressionType)compressionType { return MTLTextureCompressionTypeLossless; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { _label = [l copy]; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)s {
    if (_parent || _viewParent || _backBuf || _heap || _subHeap) return MTLPurgeableStateNonVolatile;
    MTLPurgeableState prev = nvmtl_purge(&_purge, s);
    nvmtl_purge_track(self, s);
    if (s == MTLPurgeableStateNonVolatile) {
        int one = 1;
        if (__atomic_compare_exchange_n(&_rstate, &one, 2, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
            int r = __atomic_load_n(&_resRefs, __ATOMIC_ACQUIRE) ? 1 : nvmtl_vk_image_reback(&_i, 0, _fmt == MTLPixelFormatA8Unorm);
            nvlog("residency (res1): a purged %ux%u texture was made NonVolatile -> %s", _i.w, _i.h,
                  r == 0 ? "paged back onto the card" : r == 1 ? "stays in system memory (the wall or a command buffer said no)" : "rebuild FAILED - stays in system memory");
            __atomic_store_n(&_rstate, 0, __ATOMIC_RELEASE);
        }
    }
    return prev;
}
- (void)addDebugMarker:(NSString *)m range:(NSRange)r {}
- (void)removeAllDebugMarkers {}
- (id)newSharedTextureHandle {
    if (_parent || !_shareable || !_surf) return nil;
    if (![MTLSharedTextureHandle instancesRespondToSelector:@selector(initWithIOSurface:label:)]) {
        static int said; if (!said++) nvlog("newSharedTextureHandle: MTLSharedTextureHandle has no -initWithIOSurface:label: on this OS - nil (apps1)");
        return nil; }
    MTLSharedTextureHandle *h = [[MTLSharedTextureHandle alloc] initWithIOSurface:_surf label:_label];
    if (!h) { static int said; if (said++ < 4) nvlog("newSharedTextureHandle: Metal refused surface %u (its kMetalRegistryID names no live device) - nil (apps1)",
                                                   IOSurfaceGetID(_surf)); }
    return h;
}
- (id<MTLTexture>)remoteStorageTexture { return nil; }
- (id<MTLTexture>)newRemoteTextureViewForDevice:(id<MTLDevice>)d {
    return nil; }
// An app's region, level and slice are 64-bit; the copy path below takes 32-bit. A value that does not fit
// describes no texture, and narrowing it produces a DIFFERENT region that then passes every bounds check that
// follows: an origin of 2^32 reads as 0, so the copy lands at the start of the texture instead of being
// refused. The texture-buffer paths also add origin and width together, which wraps for an origin near 2^64
// and would memcpy far outside the buffer. Apple raises an exception on a region like this; refuse it here,
// before anything is narrowed.
static BOOL nvmtl_region_fits(MTLRegion r, NSUInteger level, NSUInteger slice) {
    return r.origin.x <= UINT32_MAX && r.origin.y <= UINT32_MAX && r.origin.z <= UINT32_MAX
        && r.size.width <= UINT32_MAX && r.size.height <= UINT32_MAX && r.size.depth <= UINT32_MAX
        && level <= UINT32_MAX && slice <= UINT32_MAX;
}
- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)row fromRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level {
    if (!nvmtl_region_fits(region, level, 0)) { nvlog("getBytes: the region does not fit the copy path — REFUSED"); return; }
    if (level >= [self mipmapLevelCount]) { nvlog("getBytes: mip level %lu — this texture has %lu", (unsigned long)level, (unsigned long)[self mipmapLevelCount]); return; }
    [self nvmtlSurfaceIn];
    nvmtl_census("getBytes", (uint32_t)region.size.width, (uint32_t)region.size.height, _surf != NULL);
    if (nvmtl_vk_image_read_region_level_layer(_q, [self nvi], (uint8_t *)bytes, row, (uint32_t)region.origin.x, (uint32_t)region.origin.y,
                                               (uint32_t)region.size.width, (uint32_t)region.size.height, (uint32_t)level + _baseLevel, _baseSlice))
        nvlog("texture getBytes: readback FAILED");
}
- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)row bytesPerImage:(NSUInteger)img
      fromRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice {
    if (!nvmtl_region_fits(region, level, slice)) { nvlog("getBytes:slice: the region does not fit the copy path — REFUSED"); return; }
    if (_tbView) {
        uint8_t *src = (uint8_t *)[(id<MTLBuffer>)_backBuf contents];
        if (!src || region.origin.x > _i.w || region.size.width > _i.w - region.origin.x) { nvlog("getBytes: texture buffer is not CPU-visible or the region is outside it"); return; }
        memcpy(bytes, src + _backOff + region.origin.x * _i.bpp, region.size.width * _i.bpp); return; }
    if (level >= [self mipmapLevelCount]) { nvlog("getBytes: mip level %lu — this texture has %lu", (unsigned long)level, (unsigned long)[self mipmapLevelCount]); return; }
    [self nvmtlSurfaceIn];
    nvk_image *im = [self nvi]; BOOL vol = im->mtl_type == 7; NSUInteger nz = vol ? (region.size.depth ? region.size.depth : 1) : 1;
    NSUInteger per = img ? img : row * region.size.height; int rc = 0;
    for (NSUInteger zi = 0; zi < nz && !rc; zi++)
        rc = nvmtl_vk_image_read_region_level_layer(_q, im, (uint8_t *)bytes + zi * per, row, (uint32_t)region.origin.x, (uint32_t)region.origin.y,
                                                    (uint32_t)region.size.width, (uint32_t)region.size.height, (uint32_t)level + _baseLevel, (uint32_t)(vol ? region.origin.z + zi : slice + _baseSlice));
    if (rc) nvlog("texture getBytes:slice: readback FAILED");
}

static void nvmtl_replace_verify(NVMTLTexture *t, const void *bytes, size_t row, uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t level, uint32_t layer)
{
    static int on = -1;
    if (on < 0) { const char *e = getenv("NVMTL_REPLACE_VERIFY"); on = e && e[0] == '1';
        if (on) nvlog("replaceRegion verify: ON - every replaceRegion is read back and compared with the caller's bytes"); }
    static _Atomic uint64_t calls, bad, zero, logged;
    const uint64_t c = atomic_fetch_add(&calls, 1) + 1;
    nvk_image *im = [t nvi];
    if (c <= 40 || !(c & (c - 1)))
        nvlog("replaceRegion #%llu: mtl fmt %lu vk %u %ux%u mips %u level %u layer %u region (%u,%u %ux%u) row %zu", (unsigned long long)c,
              (unsigned long)t->_fmt, im ? im->fmt : 0, im ? im->w : 0, im ? im->h : 0, im ? im->mips : 0, level, layer, x, y, w, h, row);
    if (!on || !im || !bytes || !row) return;
    const uint32_t bw = im->bw ? im->bw : 1, bh = im->bh ? im->bh : 1, bpp = im->bpp ? im->bpp : 4;
    const uint32_t rows = (h + bh - 1) / bh, tight = ((w + bw - 1) / bw) * bpp;
    if (tight > row) return;
    uint8_t *rb = malloc((size_t)rows * row); if (!rb) return;
    if (nvmtl_vk_image_read_region_level_layer(t->_q, im, rb, row, x, y, w, h, level, layer)) { free(rb); return; }
    int b = 0, z = 1; uint32_t first = 0;
    for (uint32_t k = 0; k < rows; k++) {
        if (memcmp((const uint8_t *)bytes + (size_t)k * row, rb + (size_t)k * row, tight)) { if (!b) first = k; b = 1; }
        for (uint32_t j = 0; j < tight && z; j++) if (rb[(size_t)k * row + j]) z = 0;
    }
    free(rb);
    if (b) { atomic_fetch_add(&bad, 1); if (z) atomic_fetch_add(&zero, 1);
        if (atomic_fetch_add(&logged, 1) < 60)
            nvlog("replaceRegion verify: MISMATCH mtl fmt %lu vk %u %ux%u mips %u level %u layer %u region (%u,%u %ux%u) row %zu block %ux%u bpp %u: first bad row %u of %u, readback %s",
                  (unsigned long)t->_fmt, im->fmt, im->w, im->h, im->mips, level, layer, x, y, w, h, row, bw, bh, bpp, first, rows, z ? "ALL ZERO" : "non-zero"); }
    if (!(c & (c - 1)) && c >= 16) nvlog("replaceRegion verify: %llu calls, %llu mismatched (%llu read back all zero)", (unsigned long long)c, (unsigned long long)atomic_load(&bad), (unsigned long long)atomic_load(&zero));
}
// CoreAnimation uploads only level 0 of the mipmapped texture it draws a Dock badge digit into and samples it trilinear,
// so the levels nobody wrote need filling; a write to a higher level or generateMipmaps sets _mipsWritten and ends that.
static void nvmtl_mip_autofill(NVMTLTexture *t, const void *bytes, size_t row, MTLRegion region, NSUInteger level) {
    NVMTLTexture *r = t->_parent ?: t;
    if (level + t->_baseLevel > 0) { r->_mipsWritten = YES; return; }
    NSUInteger mips = t.mipmapLevelCount; if (mips <= 1 || r->_mipsWritten || t->_parent || !bytes || !row) return;
    nvk_image *im = [t nvi]; if (!im) return; uint32_t w = im->w, h = im->h;
    if (im->mtl_type != 2 || im->bw > 1 || (im->layers ? im->layers : 1) > 1 || w > 2048 || h > 2048) return;
    if (region.origin.x || region.origin.y || region.size.width != w || region.size.height != h) return;
    unsigned bpp; switch (t.pixelFormat) {
        case MTLPixelFormatA8Unorm: case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Unorm_sRGB: bpp = 1; break;
        case MTLPixelFormatRG8Unorm: case MTLPixelFormatRG8Unorm_sRGB: bpp = 2; break;
        case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB: bpp = 4; break;
        default: return; }
    if (bpp != im->bpp) return;
    size_t cap = (size_t)((w + 1) / 2) * ((h + 1) / 2) * bpp; uint8_t *cur = malloc(cap), *nxt = malloc(cap);
    if (!cur || !nxt) { free(cur); free(nxt); return; }
    const uint8_t *src = bytes; size_t srow = row; uint32_t sw = w, sh = h;
    for (NSUInteger l = 1; l < mips; l++) {
        uint32_t dw = sw > 1 ? sw / 2 : 1, dh = sh > 1 ? sh / 2 : 1;
        for (uint32_t y = 0; y < dh; y++) for (uint32_t x = 0; x < dw; x++) {
            uint32_t x0 = 2 * x, x1 = 2 * x + 1 < sw ? 2 * x + 1 : x0, y0 = 2 * y, y1 = 2 * y + 1 < sh ? 2 * y + 1 : y0;
            const uint8_t *p00 = src + (size_t)y0 * srow + (size_t)x0 * bpp, *p01 = src + (size_t)y0 * srow + (size_t)x1 * bpp;
            const uint8_t *p10 = src + (size_t)y1 * srow + (size_t)x0 * bpp, *p11 = src + (size_t)y1 * srow + (size_t)x1 * bpp;
            uint8_t *d = nxt + ((size_t)y * dw + x) * bpp;
            for (unsigned c = 0; c < bpp; c++) d[c] = (uint8_t)((p00[c] + p01[c] + p10[c] + p11[c] + 2) / 4); }
        if (nvmtl_vk_image_write_region_level_layer(t->_q, im, nxt, (size_t)dw * bpp, 0, 0, dw, dh, (uint32_t)l, t->_baseSlice)) break;
        uint8_t *tmp = cur; cur = nxt; nxt = tmp; src = cur; srow = (size_t)dw * bpp; sw = dw; sh = dh;
    }
    free(cur); free(nxt);
}
- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level withBytes:(const void *)bytes bytesPerRow:(NSUInteger)row {
    nvmtl_hist(self, 'W');
    if (!nvmtl_region_fits(region, level, 0)) { nvlog("replaceRegion: the region does not fit the copy path — REFUSED"); return; }
    if (level >= [self mipmapLevelCount]) { nvlog("replaceRegion: mip level %lu — this texture has %lu", (unsigned long)level, (unsigned long)[self mipmapLevelCount]); return; }
    if (region.size.depth > 1 || region.origin.z) { [self replaceRegion:region mipmapLevel:level slice:0 withBytes:bytes bytesPerRow:row bytesPerImage:row * region.size.height]; return; }
    { int was = nvtrace_scope([self nvi]->w, [self nvi]->h);
      if (nvmtl_trace_on()) { unsigned nz, nn; size_t valid = (size_t)region.size.width * [self nvi]->bpp; if (row && valid > row) valid = row;
        nvmtl_nonzero(bytes, row, valid, (uint32_t)region.size.height, &nz, &nn);
        nvtrace("REPLACE %lux%lu at %lu,%lu level %lu row %lu -> tex %ux%u surf %u | nonzero %u/%u sampled bytes", (unsigned long)region.size.width,
            (unsigned long)region.size.height, (unsigned long)region.origin.x, (unsigned long)region.origin.y, (unsigned long)level, (unsigned long)row,
            [self nvi]->w, [self nvi]->h, nvmtl_surf_id(self), nz, nn); }
      g_trace_mute = was; }
    if (!bytes || row < (size_t)_i.w * (_i.bpp ? _i.bpp : 4) || !nvmtl_surface_full_overwrite(self, region, level, 0)) [self nvmtlSurfaceIn];
    if (nvmtl_vk_image_write_region_level_layer(_q, [self nvi], (const uint8_t *)bytes, row, (uint32_t)region.origin.x, (uint32_t)region.origin.y,
                                                (uint32_t)region.size.width, (uint32_t)region.size.height, (uint32_t)level + _baseLevel, _baseSlice))
        nvlog("replaceRegion: upload FAILED");
    else { nvmtl_replace_verify(self, bytes, row, (uint32_t)region.origin.x, (uint32_t)region.origin.y, (uint32_t)region.size.width, (uint32_t)region.size.height, (uint32_t)level + _baseLevel, _baseSlice);
           [self nvmtlSurfaceOut]; nvmtl_mip_autofill(self, bytes, row, region, level); }
}
- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice
            withBytes:(const void *)bytes bytesPerRow:(NSUInteger)row bytesPerImage:(NSUInteger)img {
    if (!nvmtl_region_fits(region, level, slice)) { nvlog("replaceRegion:slice: the region does not fit the copy path — REFUSED"); return; }
    if (_tbView) {
        id<MTLBuffer> bb = (id<MTLBuffer>)_backBuf; uint8_t *dst = (uint8_t *)[bb contents];
        if (!dst || region.origin.x > _i.w || region.size.width > _i.w - region.origin.x) { nvlog("replaceRegion: texture buffer is not CPU-visible or the region is outside it"); return; }
        const NSUInteger at = _backOff + region.origin.x * _i.bpp, len = region.size.width * _i.bpp; memcpy(dst + at, bytes, len);
        if (bb.storageMode == MTLStorageModeManaged) [bb didModifyRange:NSMakeRange(at, len)];
        return; }
    if (level >= [self mipmapLevelCount]) { nvlog("replaceRegion: mip level %lu — this texture has %lu", (unsigned long)level, (unsigned long)[self mipmapLevelCount]); return; }
    if (!bytes || row < (size_t)_i.w * (_i.bpp ? _i.bpp : 4) || !nvmtl_surface_full_overwrite(self, region, level, slice)) [self nvmtlSurfaceIn];
    nvk_image *im = [self nvi]; BOOL vol = im->mtl_type == 7; NSUInteger nz = vol ? (region.size.depth ? region.size.depth : 1) : 1;
    if (!vol && (region.size.depth > 1 || region.origin.z)) { nvlog("replaceRegion:slice: depth %lu@z%lu on a non-3D texture — REFUSED", (unsigned long)region.size.depth, (unsigned long)region.origin.z); return; }
    NSUInteger per = img ? img : row * region.size.height; int rc = 0;
    for (NSUInteger zi = 0; zi < nz && !rc; zi++)
        rc = nvmtl_vk_image_write_region_level_layer(_q, im, (const uint8_t *)bytes + zi * per, row, (uint32_t)region.origin.x, (uint32_t)region.origin.y,
                                                     (uint32_t)region.size.width, (uint32_t)region.size.height, (uint32_t)level + _baseLevel, (uint32_t)(vol ? region.origin.z + zi : slice + _baseSlice));
    if (rc) nvlog("replaceRegion:slice: upload FAILED");
    else { if (!vol) nvmtl_replace_verify(self, bytes, row, (uint32_t)region.origin.x, (uint32_t)region.origin.y, (uint32_t)region.size.width, (uint32_t)region.size.height, (uint32_t)level + _baseLevel, (uint32_t)(slice + _baseSlice));
           [self nvmtlSurfaceOut]; if (!vol) nvmtl_mip_autofill(self, bytes, row, region, level); }
}
// A view of a texture buffer is another texel-buffer view of the same bytes. Apple's GL asks for one whenever a buffer
// texture is sampled through a sampler of another type (Minecraft 26's R8Sint/R32Float buffer textures), every draw
// until it gets one.
static NVMTLTexture *nvmtl_texbuf_view(NVMTLTexture *t, MTLPixelFormat f) {
    extern int nvmtl_pixfmt_public(MTLPixelFormat f, uint32_t *vk, uint32_t *bpp, int *a8);
    uint32_t vkf = 0, bpp = 0; int a8 = 0;
    if (!t->_backBuf || nvmtl_pixfmt_public(f, &vkf, &bpp, &a8) || a8 || !bpp || !t->_backBPR || t->_backBPR % bpp) {
        nvlog("newTextureView: texture-buffer view as format %lu is not carried -> nil", (unsigned long)f); return nil; }
    MTLTextureDescriptor *d = [MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:f width:t->_backBPR / bpp
                                                                            resourceOptions:[t->_backBuf resourceOptions] usage:t->_usage];
    return nvmtl_texbuf_make(t->_backBuf, d, t->_backOff);
}
- (id<MTLTexture>)nvmtlViewWithFormat:(MTLPixelFormat)f levels:(NSRange)levels {
    if (!levels.length || levels.location >= self.mipmapLevelCount || levels.length > self.mipmapLevelCount - levels.location) return nil;
    if ([self nvi]->mtl_type == 9) return nvmtl_texbuf_view(self, f);
    NVMTLTexture *v = [NVMTLTexture new];
    { NVMTLTexture *vp_ = _parent ? _parent : self; __atomic_fetch_add(&vp_->_nviews, 1, __ATOMIC_ACQ_REL); }  v->_parent = _parent ? _parent : self; v->_usage = [self usage];
    v->_q = _q; v->_fmt = f; v->_surf = _surf; v->_plane = _plane;
    v->_mips = (uint32_t)levels.length;
    v->_viewParent = self; v->_relativeLevel = (uint32_t)levels.location;
    v->_viewType = (uint32_t)self.textureType;
    v->_viewSlices = _parent ? _viewSlices : (v->_viewType == 7 ? 1 : ([self nvi]->layers ?: 1));
    v->_baseSlice = _baseSlice; v->_baseLevel = _baseLevel + (uint32_t)levels.location;
    extern int nvmtl_pixfmt_public(MTLPixelFormat f, uint32_t *vk, uint32_t *bpp, int *a8);
    extern int nvmtl_depthfmt_public(MTLPixelFormat f, uint32_t *vk, uint32_t *aspect);
    uint32_t dvk = 0, dasp = 0;
    if (nvmtl_depthfmt_public(f, &dvk, &dasp) == 0) {
        if (nvmtl_vk_image_view_create_range_aspect([v nvi], dvk, 0, dasp, v->_baseLevel, v->_mips, v->_baseSlice, v->_viewSlices, v->_viewType, &v->_ownView)) { nvlog("newTextureView: depth/stencil view FAILED (format %lu)", (unsigned long)f); return nil; }
        v->_stex = NO;
        nvlog("newTextureView: depth/stencil view format %lu aspect %u -> %p", (unsigned long)f, dasp, (__bridge void *)v);
        return v;
    }
    uint32_t vkf = 0, bpp = 0; int a8 = 0;
    if (nvmtl_pixfmt_public(f, &vkf, &bpp, &a8)) return nil;
    if (vkf != [v nvi]->fmt && bpp != [v nvi]->bpp) {
        nvlog("newTextureView: pixel format %lu is %u B per element, its texture's is %u B - nil", (unsigned long)f, bpp, [v nvi]->bpp); return nil; }
    if (nvmtl_vk_image_view_create_range([v nvi], vkf, a8, v->_baseLevel, v->_mips, v->_baseSlice, v->_viewSlices, v->_viewType, &v->_ownView)) {
        nvlog("newTextureView: view create FAILED"); return nil;
    }
    v->_stex = [v nvi]->storage && !a8 && nvmtl_vk_format_is_storage(vkf);
    return v;
}
int nvmtl_vk_cmd_attachment_view_fmt(nvk_cmdbuf *c, nvk_image *img, int depth, uint32_t level, uint32_t slice, uint32_t vkfmt, int a8,
                                     void **out, uint32_t *w, uint32_t *h);
static uint32_t nvmtl_tex_attach_vkfmt(NVMTLTexture *t, int *a8) {
    extern int nvmtl_pixfmt_public(MTLPixelFormat f, uint32_t *vk, uint32_t *bpp, int *a8);
    uint32_t vk = 0, bpp = 0; *a8 = 0;
    if (!t->_fmt || nvmtl_pixfmt_public(t->_fmt, &vk, &bpp, a8)) { *a8 = 0; return 0; }
    return vk;
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)f {
    return [self nvmtlViewWithFormat:f levels:NSMakeRange(0, [self mipmapLevelCount])];
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)f textureType:(MTLTextureType)tt
                                         levels:(NSRange)levels slices:(NSRange)slices {
    NSUInteger availableSlices = self.textureType == MTLTextureTypeCube ? 6 : self.textureType == MTLTextureTypeCubeArray ? self.arrayLength * 6 : self.arrayLength;
    if (!levels.length || levels.location >= self.mipmapLevelCount || levels.length > self.mipmapLevelCount - levels.location ||
        !slices.length || slices.location >= availableSlices || slices.length > availableSlices - slices.location) return nil;
    { static _Atomic int n; if (atomic_fetch_add(&n, 1) < 24) nvlog("newTextureView(4): base type %lu %lux%lu mips %lu layers %lu fmt %lu -> type %lu fmt %lu levels %lu+%lu slices %lu+%lu",
          (unsigned long)self.textureType, (unsigned long)self.width, (unsigned long)self.height, (unsigned long)self.mipmapLevelCount, (unsigned long)self.arrayLength, (unsigned long)self.pixelFormat,
          (unsigned long)tt, (unsigned long)f, (unsigned long)levels.location, (unsigned long)levels.length, (unsigned long)slices.location, (unsigned long)slices.length); }
    if (tt == MTLTextureType2D && !slices.location && slices.length <= 1 && [self nvi]->mtl_type == 2) return [self nvmtlViewWithFormat:f levels:levels];
    if (tt == MTLTextureType2DMultisample && !slices.location && slices.length <= 1 && [self nvi]->mtl_type == 4) return [self nvmtlViewWithFormat:f levels:levels];
    if (tt == MTLTextureTypeTextureBuffer || [self nvi]->mtl_type == 9)
        return tt == MTLTextureTypeTextureBuffer && [self nvi]->mtl_type == 9 ? nvmtl_texbuf_view(self, f) : nil;
    if (tt == MTLTextureType3D && [self nvi]->mtl_type == 7 && !slices.location) slices = NSMakeRange(0, 1);
    if (((tt == MTLTextureType1D || tt == MTLTextureType1DArray) && [self nvi]->mtl_type != (uint32_t)tt) || (tt == MTLTextureType2DMultisample && ([self nvi]->mtl_type != 4 && [self nvi]->mtl_type != 8)) || (tt == MTLTextureType2DMultisampleArray && [self nvi]->mtl_type != 8) || (([self nvi]->mtl_type == 4 || [self nvi]->mtl_type == 8) && tt != MTLTextureType2DMultisample && tt != MTLTextureType2DMultisampleArray) || (tt == MTLTextureType3D && [self nvi]->mtl_type != 7)) { nvlog("newTextureView: textureType %lu of a %u-typed texture — not carried", (unsigned long)tt, [self nvi]->mtl_type); return nil; }
    NVMTLTexture *v = [NVMTLTexture new];
    { NVMTLTexture *vp_ = _parent ? _parent : self; __atomic_fetch_add(&vp_->_nviews, 1, __ATOMIC_ACQ_REL); }  v->_parent = _parent ? _parent : self; v->_usage = [self usage];  v->_q = _q; v->_fmt = f; v->_surf = _surf; v->_plane = _plane; v->_mips = (uint32_t)levels.length;
    v->_viewParent = self; v->_relativeLevel = (uint32_t)levels.location; v->_relativeSlice = (uint32_t)slices.location;
    v->_viewType = (uint32_t)tt; v->_viewSlices = (uint32_t)slices.length;
    v->_baseSlice = _baseSlice + (uint32_t)slices.location; v->_baseLevel = _baseLevel + (uint32_t)levels.location;
    extern int nvmtl_pixfmt_public(MTLPixelFormat f, uint32_t *vk, uint32_t *bpp, int *a8);
    extern int nvmtl_depthfmt_public(MTLPixelFormat f, uint32_t *vk, uint32_t *aspect);
    uint32_t depthFormat = 0, depthAspect = 0;
    if (!nvmtl_depthfmt_public(f, &depthFormat, &depthAspect)) {
        if (depthFormat != [v nvi]->fmt || nvmtl_vk_image_view_create_range_aspect([v nvi], depthFormat, 0, depthAspect, v->_baseLevel, v->_mips, v->_baseSlice, v->_viewSlices, (uint32_t)tt, &v->_ownView)) return nil;
        v->_stex = NO;
        return v;
    }
    uint32_t vkf = 0, bpp = 0; int a8 = 0;
    if (nvmtl_pixfmt_public(f, &vkf, &bpp, &a8)) return nil;
    if (vkf != [v nvi]->fmt && bpp != [v nvi]->bpp) {
        nvlog("newTextureView: pixel format %lu is %u B per element, its texture's is %u B - nil", (unsigned long)f, bpp, [v nvi]->bpp); return nil; }
    uint32_t nslices = (uint32_t)slices.length;
    if (nvmtl_vk_image_view_create_range([v nvi], vkf, a8, v->_baseLevel, v->_mips, v->_baseSlice, nslices, (uint32_t)tt, &v->_ownView)) { nvlog("newTextureView: typed view FAILED"); return nil; }
    v->_stex = [v nvi]->storage && !a8 && nvmtl_vk_format_is_storage(vkf);
    return v;
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)f textureType:(MTLTextureType)tt
                                         levels:(NSRange)levels slices:(NSRange)slices
                                        swizzle:(MTLTextureSwizzleChannels)sw {
    atomic_fetch_add(&nvmtl_fm_views_made, 1);
    const BOOL identity = sw.red == MTLTextureSwizzleRed && sw.green == MTLTextureSwizzleGreen && sw.blue == MTLTextureSwizzleBlue && sw.alpha == MTLTextureSwizzleAlpha;
    if (!identity && [self nvi]->mtl_type == 9) {   // a Vulkan texel buffer has no component mapping
        static int said; if (!said++) nvlog("newTextureView:swizzle: a texture buffer cannot be swizzled -> nil (said once)");
        return nil; }
    NVMTLTexture *v = (NVMTLTexture *)[self newTextureViewWithPixelFormat:f textureType:tt levels:levels slices:slices];
    if (!v || identity) return v;
    extern int nvmtl_pixfmt_public(MTLPixelFormat f, uint32_t *vk, uint32_t *bpp, int *a8);
    uint32_t vkf = 0, bpp = 0; int a8 = 0; void *nv = NULL;
    const uint8_t s4[4] = { (uint8_t)sw.red, (uint8_t)sw.green, (uint8_t)sw.blue, (uint8_t)sw.alpha };
    if (nvmtl_pixfmt_public(f, &vkf, &bpp, &a8) ||
        nvmtl_vk_image_view_create_range_swz([v nvi], vkf, a8, v->_baseLevel, v->_mips, v->_baseSlice, v->_viewSlices, v->_viewType, s4, &nv)) {
        nvlog("newTextureView:swizzle: par1 the swizzled view could not be built (format %lu) — the view keeps the identity mapping", (unsigned long)f);
        return v; }
    if (v->_ownView) nvmtl_vk_image_view_destroy(v->_ownView);
    v->_ownView = nv; v->_stex = NO;
    v->_swz = sw; v->_hasSwz = YES;
    nvlog("newTextureView:swizzle: par1 view %p maps r,g,b,a <- %u,%u,%u,%u", (__bridge void *)v, s4[0], s4[1], s4[2], s4[3]);
    return v;
}
@end

NSArray<NSDictionary *> *nvmtl_argbuf_fields(NVMTLFunction *function, NSUInteger ownerBufferIndex);
NSArray<NSDictionary *> *nvmtl_air_argbuf_layout(NVMTLFunction *fn, NSUInteger bufferIndex, NSUInteger *size, NSUInteger *align);
BOOL nvmtl_needs_visible_link(NSString *air, NSString *why);
void nvmtl_fc_expect_link(int on);
NSData *nvmtl_translate_with_fc(NSString *air, NSString *stage, const uint32_t *idx, const uint32_t *sizes,
                                const uint8_t *const *payloads, size_t n, NSString **err);
NSData *nvmtl_translate_with_fc_cached(NSString *air, NSString *stage, NSString *name, NSDictionary *constants,
                                       const uint32_t *idx, const uint32_t *sizes,
                                       const uint8_t *const *payloads, size_t n, NSString **err);

#pragma mark - library / function
id gNVMTLMainDevice = nil;

extern NSData *nvmtl_translate_samplers(NVMTLFunction *, NSDictionary *, uint32_t, NSString **);
extern NSData *nvmtl_translate_variant(NVMTLFunction *, NSDictionary *, NSDictionary *, NSString **);
// facts about a module's text that newFunctionWithName asks for on every call; kept on the text (NVMTLLibraryLoad.m)
enum { NVMTL_AIRF_KNOWN = 1, NVMTL_AIRF_DYLD_TABLE = 2, NVMTL_AIRF_ISECT_TABLE = 4 };
uint32_t nvmtl_air_text_flags(NSString *ll);
static char gNVMTLEntrySpvAssoc;
@interface NVMTLCIBinding : NSObject { @public NSString *_name; NVMTLType *_t; } @end
@implementation NVMTLCIBinding
- (NSString *)name { return _name ?: @""; }
- (NSUInteger)type { return 18; }
- (MTLBindingAccess)access { return MTLBindingAccessReadOnly; }
- (NSUInteger)index { return 0; }
- (BOOL)isUsed { return YES; }
- (BOOL)isActive { return YES; }
- (BOOL)isArgument { return NO; }
- (NSUInteger)arrayLength { return 1; }
- (id)dataTypeDescription { return _t; }
- (MTLDataType)dataType { return _t ? _t->_dataType : MTLDataTypeNone; }
- (NSString *)description { return [NSString stringWithFormat:@"<CI binding %@ dataType %lu>", _name, (unsigned long)self.dataType]; }
@end
@interface NVMTLCIStructType : NVMTLStructType { @public NSString *_typeName; } @end
@implementation NVMTLCIStructType
- (NSString *)typeName { return _typeName ?: @""; }
@end
static NSString *nvmtl_ci_trim(NSString *t) { return [t stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"!\" "]]; }
static NSString *nvmtl_ci_wtrim(NSString *t) { return [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]; }
@interface NVMTLCIStitchBinding : NVMTLCIBinding { @public NSUInteger _bt; } @end
@implementation NVMTLCIStitchBinding
- (NSUInteger)type { return _bt; }
- (BOOL)isUsed { return NO; }
- (BOOL)isActive { return NO; }
@end
static MTLDataType nvmtl_datatype_for_air_name(NSString *t);
static char nvmtl_ci_key;
static NSString *nvmtl_ci_body(NSDictionary *nodes, NSString *ref) { return [ref isKindOfClass:[NSString class]] ? nodes[ref] : nil; }
static NSString *nvmtl_ci_quoted(NSString *body, NSString *tag) {
    NSString *needle = [NSString stringWithFormat:@"!\"%@\", !\"", tag];
    NSRange r = [body rangeOfString:needle]; if (r.location == NSNotFound) return nil;
    NSUInteger from = NSMaxRange(r);
    NSRange q = [body rangeOfString:@"\"" options:0 range:NSMakeRange(from, body.length - from)];
    return q.location == NSNotFound ? nil : [body substringWithRange:NSMakeRange(from, q.location - from)];
}
static NSArray *nvmtl_ci_refs(NSString *body) {
    NSMutableArray *out = [NSMutableArray new];
    for (NSString *p in [body componentsSeparatedByString:@","]) {
        NSString *t = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([t hasPrefix:@"!"] && ![t hasPrefix:@"!\""]) [out addObject:t];
    }
    return out;
}
static NSDictionary *nvmtl_ci_entry(NVMTLFunction *fn)
{
    if (!fn || ![fn->_stage isEqualToString:@"visible"]) return nil;
    @synchronized (fn) {
        id have = objc_getAssociatedObject(fn, &nvmtl_ci_key);
        if (have) return have == [NSNull null] ? nil : have;
        NSDictionary *found = nil;
        NSString *ll = fn->_air, *fname = fn->_fname;
        if (ll.length && fname.length && [ll rangeOfString:@"\n!air.ci = "].location != NSNotFound) {
            NSMutableDictionary *nodes = [NSMutableDictionary new]; NSString *list = nil;
            for (NSString *line in [ll componentsSeparatedByString:@"\n"]) {
                if (![line hasPrefix:@"!"]) continue;
                NSRange eq = [line rangeOfString:@" = !{"]; if (eq.location == NSNotFound || ![line hasSuffix:@"}"]) continue;
                NSString *body = [line substringWithRange:NSMakeRange(NSMaxRange(eq), line.length - NSMaxRange(eq) - 1)];
                NSString *key = [line substringToIndex:eq.location];
                if ([key isEqualToString:@"!air.ci"]) list = body; else nodes[key] = body;
            }
            NSString *head = [NSString stringWithFormat:@"ptr @%@,", fname];
            for (NSString *ref in nvmtl_ci_refs(list ?: @"")) {
                NSString *entry = nodes[ref]; if (![entry hasPrefix:head]) continue;
                NSArray *parts = nvmtl_ci_refs([entry substringFromIndex:head.length]);
                if (parts.count < 2) break;
                NSString *retBody = nvmtl_ci_body(nodes, parts[0]);
                if (retBody && !nvmtl_ci_quoted(retBody, @"air.arg_type_name")) retBody = nvmtl_ci_body(nodes, nvmtl_ci_refs(retBody).firstObject);
                NVMTLType *ret = [NVMTLType new];
                NSString *rtn = retBody ? nvmtl_ci_quoted(retBody, @"air.arg_type_name") : nil;
                ret->_dataType = rtn ? nvmtl_datatype_for_air_name(rtn) : MTLDataTypeFloat4;
                NSMutableArray *args = [NSMutableArray new]; NSMutableString *say = [NSMutableString new];
                for (NSString *aref in nvmtl_ci_refs(nvmtl_ci_body(nodes, parts[1]) ?: @"")) {
                    NSString *ab = nodes[aref]; if (!ab) continue;
                    NSString *tn = nvmtl_ci_quoted(ab, @"air.arg_type_name") ?: @"";
                    BOOL builtin = [ab rangeOfString:@"!\"air.ci_builtin\""].location != NSNotFound;
                    NVMTLCIBinding *b = [NVMTLCIBinding new]; b->_t = [NVMTLType new];
                    b->_name = nvmtl_ci_quoted(ab, @"air.arg_name") ?: [NSString stringWithFormat:@"arg%lu", (unsigned long)args.count];
                    MTLDataType dt = nvmtl_datatype_for_air_name(tn);
                    if (!builtin && dt != MTLDataTypeTexture && dt != MTLDataTypeSampler) dt = MTLDataTypePointer;
                    b->_t->_dataType = dt;
                    [args addObject:b]; [say appendFormat:@" %@:%@=%lu", b->_name, tn, (unsigned long)dt];
                }
                found = @{ @"args": args, @"ret": ret };
                nvlog("CI REFL %s: functionType 4, returns %lu, %lu argument(s)%s", fname.UTF8String, (unsigned long)ret->_dataType, (unsigned long)args.count, say.UTF8String);
                break;
            }
        }
        objc_setAssociatedObject(fn, &nvmtl_ci_key, found ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return found;
    }
}
static MTLDataType nvmtl_ci_air_dtype(NSDictionary *nodes, NSString *ref) {
    NSString *b = ref ? nodes[ref] : nil; if (!b) return MTLDataTypeNone;
    NSArray *p = [b componentsSeparatedByString:@", "];
    NSUInteger n = 1; NSString *el = b;
    if ([b hasPrefix:@"!\"air.vector_type\""] && p.count >= 6) { n = (NSUInteger)[[p[5] stringByReplacingOccurrencesOfString:@"i32 " withString:@""] integerValue]; el = nodes[nvmtl_ci_wtrim(p[4])] ?: @""; }
    NSArray *q = [el componentsSeparatedByString:@", "];
    NSInteger sz = q.count > 1 ? [[q[1] stringByReplacingOccurrencesOfString:@"i32 " withString:@""] integerValue] : 0;
    if (n < 1 || n > 4) return MTLDataTypeNone;
    if ([el hasPrefix:@"!\"air.float_type\""]) return (MTLDataType)((sz == 2 ? MTLDataTypeHalf : MTLDataTypeFloat) + n - 1);
    return MTLDataTypeNone;
}
static char nvmtl_ci_stitch_key;
static NSDictionary *nvmtl_ci_stitch_entry(NVMTLFunction *fn)
{
    if (!fn || ![fn->_stage isEqualToString:@"visible"]) return nil;
    @synchronized (fn) {
        id have = objc_getAssociatedObject(fn, &nvmtl_ci_stitch_key);
        if (have) return have == [NSNull null] ? nil : have;
        NSDictionary *found = nil;
        NSString *ll = fn->_air, *fname = fn->_fname;
        if (ll.length && fname.length && [ll rangeOfString:@"\n!air.visible = "].location != NSNotFound
            && [ll rangeOfString:@"!\"air.stitching_info\""].location != NSNotFound) {
            NSMutableDictionary *nodes = [NSMutableDictionary new]; NSString *list = nil;
            for (NSString *line in [ll componentsSeparatedByString:@"\n"]) {
                if (![line hasPrefix:@"!"]) continue;
                NSRange eq = [line rangeOfString:@" = !{"]; if (eq.location == NSNotFound || ![line hasSuffix:@"}"]) continue;
                NSString *body = [line substringWithRange:NSMakeRange(NSMaxRange(eq), line.length - NSMaxRange(eq) - 1)];
                NSString *key = [line substringToIndex:eq.location];
                if ([key isEqualToString:@"!air.visible"]) list = body; else nodes[key] = body;
            }
            NSString *head = [NSString stringWithFormat:@"ptr @%@,", fname];
            for (NSString *ref in nvmtl_ci_refs(list ?: @"")) {
                NSString *entry = nodes[ref]; if (![entry hasPrefix:head]) continue;
                NSArray *parts = nvmtl_ci_refs([entry substringFromIndex:head.length]);
                if (parts.count < 3) break;
                NSString *outs = nvmtl_ci_body(nodes, parts[0]), *ins = nvmtl_ci_body(nodes, parts[1]), *si = nvmtl_ci_body(nodes, parts[2]);
                if (![si hasPrefix:@"!\"air.stitching_info\""]) break;
                NSString *ob = nvmtl_ci_body(nodes, nvmtl_ci_refs(outs ?: @"").firstObject);
                NVMTLType *ret = [NVMTLType new];
                NSString *rtn = ob ? nvmtl_ci_quoted(ob, @"air.arg_type_name") : nil;
                ret->_dataType = rtn ? nvmtl_datatype_for_air_name(rtn) : MTLDataTypeFloat4;
                NSArray *inRefs = nvmtl_ci_refs(ins ?: @""), *siRefs = nvmtl_ci_refs(si);
                NSMutableArray *args = [NSMutableArray new]; NSMutableString *say = [NSMutableString new];
                for (NSUInteger k = 1; k < siRefs.count; k++) {
                    NSString *sa = nvmtl_ci_body(nodes, siRefs[k]);
                    if (![sa hasPrefix:@"!\"air.stitching_argument\""]) continue;
                    NSArray *sp = [sa componentsSeparatedByString:@", "];
                    NSString *nm = sp.count >= 3 ? [sp[2] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"!\" "]] : nil;
                    NSString *st = nvmtl_ci_body(nodes, sp.count >= 2 ? [sp[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : nil);
                    NSString *tt = nvmtl_ci_body(nodes, nvmtl_ci_refs(st ?: @"").firstObject);
                    NVMTLCIStitchBinding *b = [NVMTLCIStitchBinding new]; b->_t = [NVMTLType new];
                    b->_name = nm.length ? nm : [NSString stringWithFormat:@"arg%lu", (unsigned long)args.count];
                    if ([tt hasPrefix:@"!\"air.struct_type\""]) {
                        b->_bt = 29;
                        NVMTLCIStructType *T = [NVMTLCIStructType new]; T->_dataType = MTLDataTypeStruct;
                        NSArray *tp = [tt componentsSeparatedByString:@", "];
                        T->_typeName = tp.count >= 5 ? nvmtl_ci_trim(tp[4]) : @"";
                        NSString *fl = tp.count >= 6 ? nvmtl_ci_body(nodes, nvmtl_ci_wtrim(tp[5])) : nil;
                        NSMutableArray *ms = [NSMutableArray array];
                        for (NSString *fr in nvmtl_ci_refs(fl ?: @"")) {
                            NSString *fb = nvmtl_ci_body(nodes, fr); if (![fb hasPrefix:@"!\"air.record_field\""]) continue;
                            NSArray *fp = [fb componentsSeparatedByString:@", "];
                            NVMTLStructMember *m = [NVMTLStructMember new];
                            m->_offset = fp.count > 1 ? (NSUInteger)[[fp[1] stringByReplacingOccurrencesOfString:@"i32 " withString:@""] integerValue] : 0;
                            m->_name = fp.count > 4 ? nvmtl_ci_trim(fp[4]) : @"";
                            m->_dataType = nvmtl_ci_air_dtype(nodes, fp.count > 3 ? nvmtl_ci_wtrim(fp[3]) : nil);
                            m->_argIndex = ms.count; [ms addObject:m];
                        }
                        T->_members = ms; b->_t = T;
                    }
                    else {
                        NSUInteger pos = args.count;
                        NSString *ib = pos < inRefs.count ? nvmtl_ci_body(nodes, inRefs[pos]) : nil;
                        NSString *tn = ib ? nvmtl_ci_quoted(ib, @"air.arg_type_name") : nil;
                        b->_bt = 18; b->_t->_dataType = tn ? nvmtl_datatype_for_air_name(tn) : MTLDataTypeNone;
                    }
                    [args addObject:b]; [say appendFormat:@" %@:%lu/%lu", b->_name, (unsigned long)b->_bt, (unsigned long)b->_t->_dataType];
                }
                found = @{ @"args": args, @"ret": ret };
                nvlog("CI STITCH REFL %s: functionType 5, returns %lu, %lu argument(s)%s", fname.UTF8String, (unsigned long)ret->_dataType, (unsigned long)args.count, say.UTF8String);
                break;
            }
        }
        objc_setAssociatedObject(fn, &nvmtl_ci_stitch_key, found ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return found;
    }
}
@implementation NVMTLFunction
- (NSDictionary<NSString *, MTLFunctionConstant *> *)functionConstantsDictionary {
    static char key;
    NSDictionary *cached = objc_getAssociatedObject(self, &key);
    if (cached) return cached;
    NSMutableDictionary *d = [NSMutableDictionary new];
    Class ci = NSClassFromString(@"MTLFunctionConstantInternal");
    if (!_air.length) {
        static int said; if (!said++) nvlog("functionConstantsDictionary: \"%s\" has no retained AIR - answering EMPTY (said once)", _fname.UTF8String ?: "?");
    } else if (!ci || ![ci instancesRespondToSelector:@selector(initWithName:type:index:required:)]) {
        static int said; if (!said++) nvlog("functionConstantsDictionary: this Metal has no MTLFunctionConstantInternal initWithName:type:index:required: - answering EMPTY (said once)");
    } else {
        static NSRegularExpression *row, *any; static dispatch_once_t once;
        dispatch_once(&once, ^{
            row = [NSRegularExpression regularExpressionWithPattern:@"^![0-9]+ = !\\{[^\\n]*\\.MTL_FC_INIT_[^\\n]*, !\"([^\"]+)\", !\"([^\"]+)\", i32 ([0-9]+), i1 (true|false)\\}$" options:NSRegularExpressionAnchorsMatchLines error:NULL];
            any = [NSRegularExpression regularExpressionWithPattern:@"^![0-9]+ = !\\{[^\\n]*\\.MTL_FC_INIT_" options:NSRegularExpressionAnchorsMatchLines error:NULL];
        });
        NSRange all = NSMakeRange(0, _air.length);
        NSArray<NSTextCheckingResult *> *ms = [row matchesInString:_air options:0 range:all];
        NSUInteger rows = [any numberOfMatchesInString:_air options:0 range:all];
        if (rows != ms.count) { static int said; if (!said++) nvlog("functionConstantsDictionary: \"%s\" has %lu MTL_FC_INIT rows, %lu in the measured shape - the AIR row moved; the rest are NOT answered (said once)", _fname.UTF8String ?: "?", (unsigned long)rows, (unsigned long)ms.count); }
        for (NSTextCheckingResult *r in ms) {
            NSString *ty = [_air substringWithRange:[r rangeAtIndex:1]], *nm = [_air substringWithRange:[r rangeAtIndex:2]];
            NSUInteger ix = (NSUInteger)[[_air substringWithRange:[r rangeAtIndex:3]] longLongValue];
            BOOL req = [[_air substringWithRange:[r rangeAtIndex:4]] isEqualToString:@"true"];
            MTLDataType dt = nvmtl_air_fc_type(ty);
            if (dt == MTLDataTypeNone) { static int said; if (!said++) nvlog("functionConstantsDictionary: AIR type \"%s\" (constant %s) has no MTLDataType mapping - answered as None (said once)", ty.UTF8String, nm.UTF8String); }
            id c = [(id<NVMTLFunctionConstantInit>)[ci alloc] initWithName:nm type:(NSUInteger)dt index:ix required:req];
            if (c) d[nm] = c;
        }
    }
    NSDictionary *out = [d copy];
    objc_setAssociatedObject(self, &key, out, OBJC_ASSOCIATION_RETAIN);
    return out;
}
- (MTLFunctionOptions)options { return MTLFunctionOptionNone; }
- (id<MTLDevice>)device { return (id<MTLDevice>)gNVMTLMainDevice; }
- (const void *)bitCodeHash {
    if (!_bcHashed) {
        NSMutableData *d = [NSMutableData data];
        [d appendData:[(_fname ?: @"") dataUsingEncoding:NSUTF8StringEncoding]];
        if (_air.length)         [d appendData:[_air dataUsingEncoding:NSUTF8StringEncoding]];
        else if (_spirv.length)  [d appendData:_spirv];
        if (_fc.count)           [d appendData:[[_fc description] dataUsingEncoding:NSUTF8StringEncoding]];
        CC_SHA256(d.bytes, (CC_LONG)d.length, _bcHash);
        _bcHashed = YES;
    }
    return _bcHash;
}
- (id<MTLArgumentEncoder>)newArgumentEncoderWithBufferIndex:(NSUInteger)index {
    // The AIR layout names every member (constants and nested structs too) with Metal's [[id]] and offset; the
    // translator's fields add any resource the AIR walk did not reach.
    NSUInteger airSize = 0, airAlign = 0;
    NSMutableArray *fields = [nvmtl_air_argbuf_layout(self, index, &airSize, &airAlign) mutableCopy];
    NSMutableSet *ids = [NSMutableSet set]; for (NSDictionary *f in fields) [ids addObject:f[@"argument_index"]];
    for (NSDictionary *f in nvmtl_argbuf_fields(self, index)) if (![ids containsObject:@([f[@"argument_index"] unsignedLongValue])]) [fields addObject:f];
    if (!fields.count && !airSize) { nvlog("newArgumentEncoderWithBufferIndex:%lu — %s declares no argument buffer there", (unsigned long)index, _fname.UTF8String); return nil; }
    NVMTLArgumentEncoder *e = [NVMTLArgumentEncoder new];
    e->_fields = fields; e->_fieldByIndex = nvmtl_index_argument_fields(fields);
    e->_airSize = airSize; e->_airAlign = airAlign;
    return e;
}
- (NSArray<MTLVertexAttribute *> *)vertexAttributes { return (NSArray<MTLVertexAttribute *> *)nvmtl_vertex_attributes_for(self); }
- (NSArray<MTLAttribute *> *)stageInputAttributes { return (NSArray<MTLAttribute *> *)nvmtl_vertex_attributes_for(self); }
- (MTLPatchType)patchType { uint32_t pt = 0, n = 0; return nvmtl_spirv_tess_info(_spirv.bytes, _spirv.length, &pt, &n) ? (MTLPatchType)pt : MTLPatchTypeNone; }
- (NSInteger)patchControlPointCount {
    uint32_t pt = 0, n = 0; if (!nvmtl_spirv_tess_info(_spirv.bytes, _spirv.length, &pt, &n)) return -1;
    NSDictionary *tr = nvmtl_function_reflection(self)[@"tessellation"];
    NSNumber *k = [tr isKindOfClass:[NSDictionary class]] && [tr[@"control_point_count"] isKindOfClass:[NSNumber class]] ? tr[@"control_point_count"] : nil;
    return k.integerValue > 0 ? k.integerValue : (NSInteger)n;
}
- (id<MTLArgumentEncoder>)newArgumentEncoderWithBufferIndex:(NSUInteger)index reflection:(MTLAutoreleasedArgument *)reflection {
    if (reflection) *reflection = (MTLArgument *)nvmtl_argument_for_buffer(self, index);
    id<MTLArgumentEncoder> e = [self newArgumentEncoderWithBufferIndex:index];
    nvlog("newArgumentEncoderWithBufferIndex:%lu reflection: -> %p (%s)", (unsigned long)index, (__bridge void *)e, _fname.UTF8String);
    return e;
}
- (NSString *)name { return _specName.length ? _specName : _fname; }
- (MTLFunctionType)functionType {
    if ([_stage isEqualToString:@"visible"] && _air.length && [_air rangeOfString:@"!air.intersection = "].location != NSNotFound) {
        __block BOOL isect = NO; NSString *key = [NSString stringWithFormat:@"ptr @%@,", _fname];
        [_air enumerateLinesUsingBlock:^(NSString *l, BOOL *stop) {
            if ([l hasPrefix:@"!"] && [l rangeOfString:key].location != NSNotFound &&
                ([l rangeOfString:@"!\"air.bounding_box\""].location != NSNotFound || [l rangeOfString:@"!\"air.triangle\""].location != NSNotFound)) { isect = YES; *stop = YES; } }];
        if (isect) return MTLFunctionTypeIntersection;
    }
    if ([_stage isEqualToString:@"visible"]) return nvmtl_ci_entry(self) ? (MTLFunctionType)4 : MTLFunctionTypeVisible;
    if ([_stage isEqualToString:@"kernel"] || [_stage isEqualToString:@"compute"]) return MTLFunctionTypeKernel;
    if ([_stage isEqualToString:@"fragment"]) return MTLFunctionTypeFragment;
    if ([_stage isEqualToString:@"mesh"]) return MTLFunctionTypeMesh;
    if ([_stage isEqualToString:@"object"]) return MTLFunctionTypeObject;
    return MTLFunctionTypeVertex;
}
- (NSArray *)arguments { return (nvmtl_ci_entry(self) ?: nvmtl_ci_stitch_entry(self))[@"args"]; }
- (id)returnType { return (nvmtl_ci_entry(self) ?: nvmtl_ci_stitch_entry(self))[@"ret"]; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { _label = [l copy]; }
@end
static MTLDataType nvmtl_datatype_for_air_name(NSString *t);
@implementation NVMTLType
- (MTLDataType)dataType { return _dataType; }
@end
@implementation NVMTLVertexAttribute
- (NSString *)name { return _name ?: @""; }
- (NSUInteger)attributeIndex { return _index; }
- (MTLDataType)attributeType { return _dataType; }
- (BOOL)isActive { return YES; }
- (BOOL)isPatchData { return NO; }
- (BOOL)isPatchControlPointData { return NO; }
@end
static NSArray *nvmtl_vertex_attributes_for(NVMTLFunction *fn) {
    NSDictionary *refl = nvmtl_function_reflection(fn);
    NSMutableArray *out = [NSMutableArray new];
    for (NSDictionary *a in refl[@"vertex_attributes"]) {
        if (![a isKindOfClass:[NSDictionary class]]) continue;
        NVMTLVertexAttribute *v = [NVMTLVertexAttribute new];
        v->_index = [a[@"location"] unsignedLongValue];
        v->_name = [a[@"name"] isKindOfClass:[NSString class]] ? a[@"name"] : [NSString stringWithFormat:@"attribute%lu", (unsigned long)v->_index];
        v->_dataType = [a[@"type_name"] isKindOfClass:[NSString class]] ? nvmtl_datatype_for_air_name(a[@"type_name"]) : MTLDataTypeFloat4;
        [out addObject:v];
    }
    return out;
}
@implementation NVMTLTextureReferenceType
- (MTLDataType)textureDataType { return _texDataType; }
- (MTLTextureType)textureType { return _texType; }
- (MTLBindingAccess)access { return _access; }
- (BOOL)isDepthTexture { return _depth; }
@end
@implementation NVMTLStructType
- (NSArray *)members { return _members ?: @[]; }
- (id)memberByName:(NSString *)n { for (NVMTLStructMember *m in _members) if ([m->_name isEqualToString:n]) return m; return nil; }
@end
@implementation NVMTLArrayType
- (MTLDataType)elementType { return _elem; }
- (NSUInteger)arrayLength { return _len; }
- (NSUInteger)stride { return _stride; }
- (NSUInteger)argumentIndexStride { return 0; }
- (id)elementStructType { return nil; }
- (id)elementArrayType { return nil; }
- (id)elementTextureReferenceType { return nil; }
- (id)elementPointerType { return nil; }
@end
@implementation NVMTLPointerType
- (MTLDataType)elementType { return _elem; }
- (MTLBindingAccess)access { return _access; }
- (NSUInteger)alignment { return _align ?: 16; }
- (NSUInteger)dataSize { return _size; }
- (BOOL)elementIsArgumentBuffer { return _isArgBuf; }
- (id)elementStructType { return _elemStruct; }
- (id)elementArrayType { return nil; }
@end
@implementation NVMTLStructMember
- (NSString *)name { return _name ?: @""; }
- (NSUInteger)offset { return _offset; }
- (MTLDataType)dataType { return _dataType; }
- (NSUInteger)argumentIndex { return _argIndex; }
- (id)structType { return _struct; }
- (id)arrayType { return _arr; }
- (id)textureReferenceType { return _texRef; }
- (id)pointerType { return _ptr; }
- (NSString *)description { return [NSString stringWithFormat:@"<member %@ id %lu off %lu type %lu>", _name, (unsigned long)_argIndex, (unsigned long)_offset, (unsigned long)_dataType]; }
@end
@implementation NVMTLArgument
- (NSString *)name { return _name ?: @""; }
- (MTLArgumentType)type { return _type; }
- (MTLBindingAccess)access { return _access; }
- (NSUInteger)index { return _index; }
- (BOOL)isActive { return _active; }
- (BOOL)isUsed { return _active; }
- (BOOL)isArgument { return YES; }
- (NSUInteger)arrayLength { return _arrayLength ?: 1; }
- (NSUInteger)bufferAlignment { return _bufAlign ?: 16; }
- (NSUInteger)bufferDataSize { return _bufSize; }
- (MTLDataType)bufferDataType { return _bufDataType; }
- (id)bufferStructType { return _bufStruct; }
- (id)bufferPointerType { return _bufPtr; }
- (MTLTextureType)textureType { return _texType; }
- (MTLDataType)textureDataType { return _texDataType; }
- (BOOL)isDepthTexture { return _depth; }
- (NSUInteger)threadgroupMemoryAlignment { return 16; }
- (NSUInteger)threadgroupMemoryDataSize { return 0; }
- (NSString *)description { return [NSString stringWithFormat:@"<arg %@ type %lu index %lu size %lu members %lu>", _name, (unsigned long)_type, (unsigned long)_index, (unsigned long)_bufSize, (unsigned long)_bufStruct->_members.count]; }
@end
@interface NVMTLBufferArgument : NVMTLArgument <MTLBufferBinding> @end
@implementation NVMTLBufferArgument @end
@interface NVMTLTextureArgument : NVMTLArgument <MTLTextureBinding> @end
@implementation NVMTLTextureArgument @end
@interface NVMTLStageInArgument : NVMTLBufferArgument @end
@implementation NVMTLStageInArgument
- (BOOL)isArgument { return NO; }
@end
@implementation NVMTLRenderPipelineReflection
- (NSArray *)vertexArguments { return _v ?: @[]; }
- (NSArray *)fragmentArguments { return _f ?: @[]; }
- (NSArray *)tileArguments { return @[]; }
- (NSArray *)vertexBindings { return _v ?: @[]; }
- (NSArray *)fragmentBindings { return _f ?: @[]; }
- (NSArray *)tileBindings { return @[]; }
- (NSArray *)objectBindings { return _o ?: @[]; }
- (NSArray *)meshBindings { return _m ?: @[]; }
@end
@implementation NVMTLComputePipelineReflection
- (NSArray *)arguments { return _a ?: @[]; }
- (NSArray *)bindings { return _a ?: @[]; }
@end

static MTLDataType nvmtl_datatype_for_air_name(NSString *t) {
    if (!t.length) return MTLDataTypeNone;
    if ([t hasPrefix:@"texture"] || [t hasPrefix:@"depth"]) return MTLDataTypeTexture;
    if ([t isEqualToString:@"sampler"]) return MTLDataTypeSampler;
    static NSDictionary *tab; static dispatch_once_t once;
    dispatch_once(&once, ^{ tab = @{
        @"float": @(MTLDataTypeFloat), @"float2": @(MTLDataTypeFloat2), @"float3": @(MTLDataTypeFloat3), @"float4": @(MTLDataTypeFloat4),
        @"float2x2": @(MTLDataTypeFloat2x2), @"float3x3": @(MTLDataTypeFloat3x3), @"float4x4": @(MTLDataTypeFloat4x4), @"float3x4": @(MTLDataTypeFloat3x4), @"float4x3": @(MTLDataTypeFloat4x3),
        @"half": @(MTLDataTypeHalf), @"half2": @(MTLDataTypeHalf2), @"half3": @(MTLDataTypeHalf3), @"half4": @(MTLDataTypeHalf4),
        @"int": @(MTLDataTypeInt), @"int2": @(MTLDataTypeInt2), @"int3": @(MTLDataTypeInt3), @"int4": @(MTLDataTypeInt4),
        @"uint": @(MTLDataTypeUInt), @"uint2": @(MTLDataTypeUInt2), @"uint3": @(MTLDataTypeUInt3), @"uint4": @(MTLDataTypeUInt4),
        @"short": @(MTLDataTypeShort), @"ushort": @(MTLDataTypeUShort), @"char": @(MTLDataTypeChar), @"uchar": @(MTLDataTypeUChar), @"bool": @(MTLDataTypeBool),
        @"long": @(MTLDataTypeLong), @"ulong": @(MTLDataTypeULong) }; });
    NSNumber *n = tab[t];
    if (n) return (MTLDataType)n.integerValue;
    if ([t hasSuffix:@"*"] || [t hasPrefix:@"device "] || [t hasPrefix:@"constant "]) return MTLDataTypePointer;
    return MTLDataTypeStruct;
}
static MTLBindingAccess nvmtl_access_for(id a) {
    NSString *s = [a isKindOfClass:[NSString class]] ? a : nil;
    if ([s isEqualToString:@"ReadWrite"] || [s isEqualToString:@"Storage"]) return MTLBindingAccessReadWrite;
    if ([s isEqualToString:@"WriteOnly"]) return MTLBindingAccessWriteOnly;
    return MTLBindingAccessReadOnly;
}
static MTLTextureType nvmtl_textype_for_shape(id shape) {
    NSString *s = [shape isKindOfClass:[NSString class]] ? shape : [shape description];
    if (!s.length) return MTLTextureType2D;
    if ([s rangeOfString:@"CubeArray"].location != NSNotFound) return MTLTextureTypeCubeArray;
    if ([s rangeOfString:@"Cube"].location != NSNotFound) return MTLTextureTypeCube;
    if ([s rangeOfString:@"3D"].location != NSNotFound || [s rangeOfString:@"3d"].location != NSNotFound || [s rangeOfString:@"Three"].location != NSNotFound) return MTLTextureType3D;
    if ([s rangeOfString:@"1D"].location != NSNotFound || [s rangeOfString:@"1d"].location != NSNotFound || [s rangeOfString:@"One"].location != NSNotFound)
        return [s rangeOfString:@"Array"].location != NSNotFound ? MTLTextureType1DArray : MTLTextureType1D;
    if ([s rangeOfString:@"Multisample"].location != NSNotFound || [s rangeOfString:@"MS"].location != NSNotFound) return MTLTextureType2DMultisample;
    return [s rangeOfString:@"Array"].location != NSNotFound ? MTLTextureType2DArray : MTLTextureType2D;
}
// texture2d<uint, sample> -> UInt, <int ...> -> Int, <half ...> -> Half, anything else (float, depth, unknown) -> Float
static MTLDataType nvmtl_texdatatype_for_air_name(NSString *tn) {
    if (![tn isKindOfClass:[NSString class]]) return MTLDataTypeFloat;
    if ([tn rangeOfString:@"<uint"].location != NSNotFound || [tn rangeOfString:@"<ushort"].location != NSNotFound) return MTLDataTypeUInt;
    if ([tn rangeOfString:@"<int"].location != NSNotFound || [tn rangeOfString:@"<short"].location != NSNotFound) return MTLDataTypeInt;
    if ([tn rangeOfString:@"<half"].location != NSNotFound) return MTLDataTypeHalf;
    return MTLDataTypeFloat;
}
static BOOL nvmtl_binding_active(NSDictionary *b) { id acc = b[@"access"]; return !([acc isKindOfClass:[NSString class]] && [acc isEqualToString:@"Unused"]); }
static NVMTLArgument *nvmtl_build_buffer_argument(NVMTLFunction *fn, NSUInteger index, NSDictionary *binding, NSDictionary *refl, NSDictionary *names) {
    NVMTLArgument *a = [NVMTLBufferArgument new];
    a->_type = MTLArgumentTypeBuffer; a->_index = index; a->_active = nvmtl_binding_active(binding); a->_arrayLength = 1; a->_bufAlign = 16;
    NSString *key = [NSString stringWithFormat:@"buffer:%lu", (unsigned long)index];
    a->_name = names[@"args"][key] ?: [NSString stringWithFormat:@"buffer%lu", (unsigned long)index];
    a->_access = nvmtl_access_for(binding[@"access"]);
    id ds = binding[@"declared_size"]; a->_bufSize = [ds isKindOfClass:[NSNumber class]] ? [ds unsignedLongValue] : 0;
    NSMutableArray *members = [NSMutableArray new];
    NSDictionary *memberNames = names[@"members"], *types = names[@"types"];
    NSString *bufKeyPrefix = [NSString stringWithFormat:@"%lu:", (unsigned long)index];
    NSMutableDictionary *kindAt = [NSMutableDictionary new];
    for (NSDictionary *b in refl[@"bindings"]) {
        NSDictionary *src = b[@"embedded_source"]; if (![src isKindOfClass:[NSDictionary class]]) continue;
        if ([src[@"buffer_index"] unsignedLongValue] != index) continue;
        // only embedded textures and samplers decide the member kind here; an EmbeddedArgBufferBuffer is a pointer and
        // falls through to resource_buffer_index below. WAS: every non-sampler kind became "texture", so a constant
        // buffer pointer at offset 0 reflected as a texture (Steel Nomad ButterflySLM_FFT_CS, 2026-11-08)
        NSString *bk = b[@"kind"];
        if ([bk isEqualToString:@"EmbeddedArgBufferSampler"]) kindAt[src[@"field_offset"]] = @"sampler";
        else if ([bk isEqualToString:@"EmbeddedArgBufferTexture"]) kindAt[src[@"field_offset"]] = @"texture";
    }
    NSUInteger end = 0, abfHere = 0;
    for (NSDictionary *f0 in refl[@"argument_buffer_fields"]) {
        if ([f0[@"buffer_index"] unsignedLongValue] != index) continue;
        abfHere++;
        NVMTLStructMember *m = [NVMTLStructMember new];
        m->_offset = [f0[@"field_offset"] unsignedLongValue]; m->_argIndex = [f0[@"argument_index"] unsignedLongValue];
        NSString *mk = [bufKeyPrefix stringByAppendingFormat:@"%lu", (unsigned long)m->_argIndex];
        m->_name = memberNames[mk] ?: [NSString stringWithFormat:@"field%lu", (unsigned long)m->_argIndex];
        NSString *tn = types[mk]; NSString *kind = kindAt[f0[@"field_offset"]];
        if ([kind isEqualToString:@"sampler"]) m->_dataType = MTLDataTypeSampler;
        else if ([kind isEqualToString:@"texture"]) m->_dataType = MTLDataTypeTexture;
        else if ([f0[@"resource_buffer_index"] isKindOfClass:[NSNumber class]]) m->_dataType = MTLDataTypePointer;
        else m->_dataType = tn ? nvmtl_datatype_for_air_name(tn) : MTLDataTypePointer;
        if (m->_dataType == MTLDataTypeTexture) { m->_texRef = [NVMTLTextureReferenceType new]; m->_texRef->_dataType = MTLDataTypeTexture; m->_texRef->_texDataType = MTLDataTypeFloat;
            m->_texRef->_texType = [tn rangeOfString:@"cube"].location != NSNotFound ? MTLTextureTypeCube : [tn rangeOfString:@"3d"].location != NSNotFound ? MTLTextureType3D
                                 : [tn rangeOfString:@"2d_array"].location != NSNotFound ? MTLTextureType2DArray : MTLTextureType2D;
            m->_texRef->_depth = [tn hasPrefix:@"depth"]; }
        if (m->_dataType == MTLDataTypePointer) { m->_ptr = [NVMTLPointerType new]; m->_ptr->_dataType = MTLDataTypePointer; m->_ptr->_elem = MTLDataTypeStruct; m->_ptr->_align = 16;
            // the pointee's size, alignment and members from the AIR (Apple reports them; engines size the constant data
            // they place behind the pointer from dataSize). WAS: size 0 and no struct - harmless only while the member was
            // misreported as a texture (see kindAt above).
            NSDictionary *pe = [names[@"pointees"] isKindOfClass:[NSDictionary class]] ? names[@"pointees"][mk] : nil;
            if (pe) {
                if (pe[@"size"]) m->_ptr->_size = [pe[@"size"] unsignedLongValue];
                if (pe[@"align"]) m->_ptr->_align = [pe[@"align"] unsignedLongValue];
                m->_ptr->_access = [pe[@"write"] boolValue] ? MTLBindingAccessReadWrite : MTLBindingAccessReadOnly;
                NSArray *pm = pe[@"members"];
                if ([pm isKindOfClass:[NSArray class]] && pm.count) {
                    NSMutableArray *sm = [NSMutableArray new]; NSUInteger j = 0;
                    for (NSDictionary *am in pm) {
                        NVMTLStructMember *x = [NVMTLStructMember new];
                        x->_offset = [am[@"off"] unsignedLongValue]; x->_argIndex = j++; x->_name = am[@"name"];
                        x->_dataType = nvmtl_datatype_for_air_name(am[@"type"]); if (x->_dataType == MTLDataTypeNone) x->_dataType = MTLDataTypeStruct;
                        NSUInteger cnt = [am[@"count"] unsignedLongValue], sz = [am[@"size"] unsignedLongValue];
                        if (cnt > 1) { NVMTLArrayType *at = [NVMTLArrayType new]; at->_dataType = MTLDataTypeArray; at->_elem = x->_dataType; at->_len = cnt; at->_stride = sz;
                            x->_arr = at; x->_dataType = MTLDataTypeArray; }
                        [sm addObject:x];
                    }
                    m->_ptr->_elemStruct = [NVMTLStructType new]; m->_ptr->_elemStruct->_dataType = MTLDataTypeStruct; m->_ptr->_elemStruct->_members = sm;
                } else if (!pe[@"members"]) { NSString *et = types[mk]; MTLDataType d = et ? nvmtl_datatype_for_air_name(et) : MTLDataTypeStruct; if (d != MTLDataTypeNone && d != MTLDataTypePointer) m->_ptr->_elem = d; }
            } }
        NSUInteger e = m->_offset + (m->_dataType == MTLDataTypeFloat4x4 ? 64 : m->_dataType == MTLDataTypeFloat3x3 ? 48 : 8);
        if (e > end) end = e;
        [members addObject:m];
    }
    NSArray *airPlain = [names[@"plain"] isKindOfClass:[NSDictionary class]] ? names[@"plain"][@(index)] : nil;
    if (!members.count && [airPlain isKindOfClass:[NSArray class]] && airPlain.count) {
        NSUInteger i = 0;
        for (NSDictionary *am in airPlain) {
            NVMTLStructMember *m = [NVMTLStructMember new];
            m->_offset = [am[@"off"] unsignedLongValue]; m->_argIndex = i++; m->_name = am[@"name"];
            m->_dataType = nvmtl_datatype_for_air_name(am[@"type"]);
            if (m->_dataType == MTLDataTypeNone) m->_dataType = MTLDataTypeStruct;
            // struct_type_info gives the element size and an element count (0 = not an array). An array is reported as
            // Apple does, MTLDataTypeArray with its MTLArrayType: engines size their uniform copies from it. WAS: the element
            // alone, so Hades (The Forge) copied one float4x4 of its float4x4[2] and every screen-space sprite read zeros.
            NSUInteger cnt = [am[@"count"] unsignedLongValue], sz = [am[@"size"] unsignedLongValue];
            if (cnt > 1) { NVMTLArrayType *at = [NVMTLArrayType new]; at->_dataType = MTLDataTypeArray; at->_elem = m->_dataType; at->_len = cnt; at->_stride = sz;
                m->_arr = at; m->_dataType = MTLDataTypeArray; }
            NSUInteger e = m->_offset + sz * (cnt > 1 ? cnt : 1); if (e > end) end = e;
            [members addObject:m];
        }
    }
    if (!members.count && [binding[@"type_layout"] isKindOfClass:[NSDictionary class]]) {
        NSArray *ms = binding[@"type_layout"][@"Struct"];
        NSUInteger i = 0;
        for (NSDictionary *am in ms) {
            if (![am isKindOfClass:[NSDictionary class]]) continue;
            NVMTLStructMember *m = [NVMTLStructMember new];
            m->_offset = [am[@"offset"] unsignedLongValue]; m->_argIndex = i;
            NSString *mk = [bufKeyPrefix stringByAppendingFormat:@"%lu", (unsigned long)i];
            m->_name = memberNames[mk] ?: [NSString stringWithFormat:@"m%lu", (unsigned long)i];
            NSString *tn = types[mk]; m->_dataType = tn ? nvmtl_datatype_for_air_name(tn) : MTLDataTypeFloat;
            [members addObject:m]; i++;
        }
    }
    if (members.count) {
        [members sortUsingComparator:^NSComparisonResult(NVMTLStructMember *x, NVMTLStructMember *y) { return x->_offset < y->_offset ? NSOrderedAscending : x->_offset > y->_offset ? NSOrderedDescending : NSOrderedSame; }];
        a->_bufDataType = MTLDataTypeStruct;
        a->_bufStruct = [NVMTLStructType new]; a->_bufStruct->_dataType = MTLDataTypeStruct; a->_bufStruct->_members = members;
        if (!a->_bufSize) a->_bufSize = end;
    } else {
        NSString *tn = names[@"types"][key];
        a->_bufDataType = tn ? nvmtl_datatype_for_air_name(tn) : MTLDataTypeStruct;
        if (a->_bufDataType == MTLDataTypeTexture || a->_bufDataType == MTLDataTypeSampler) a->_bufDataType = MTLDataTypeStruct;
    }
    a->_bufPtr = [NVMTLPointerType new]; a->_bufPtr->_dataType = MTLDataTypePointer; a->_bufPtr->_elem = a->_bufDataType; a->_bufPtr->_access = a->_access;
    a->_bufPtr->_align = 16; a->_bufPtr->_size = a->_bufSize; a->_bufPtr->_isArgBuf = kindAt.count > 0 || abfHere > 0; a->_bufPtr->_elemStruct = a->_bufStruct;
    return a;
}
NSArray<NVMTLArgument *> *nvmtl_arguments_for_function(NVMTLFunction *fn)
{
    if (!fn) return @[];
    @synchronized (fn) {
        if (fn->_arguments) return fn->_arguments;
        NSDictionary *refl = nvmtl_function_reflection(fn);
        NSDictionary *names = nvmtl_air_names(fn) ?: @{ @"args": @{}, @"members": @{}, @"types": @{} };
        NSMutableArray *out = [NSMutableArray new];
        NSMutableSet *seenBuf = [NSMutableSet new];
        for (NSDictionary *b in refl[@"bindings"]) {
            if (![b isKindOfClass:[NSDictionary class]]) continue;
            if (![b[@"param_index"] isKindOfClass:[NSNumber class]]) continue;
            NSString *kind = b[@"kind"]; NSUInteger idx = [b[@"metal_index"] unsignedLongValue];
            if ([kind isEqualToString:@"Buffer"]) {
                if ([seenBuf containsObject:@(idx)]) continue;
                [seenBuf addObject:@(idx)];
                [out addObject:nvmtl_build_buffer_argument(fn, idx, b, refl, names)];
            } else if ([kind isEqualToString:@"Texture"] || [kind isEqualToString:@"TextureArray"] || [kind isEqualToString:@"StorageImage"]) {
                NVMTLArgument *a = [NVMTLTextureArgument new]; a->_type = MTLArgumentTypeTexture; a->_index = idx; a->_active = nvmtl_binding_active(b);
                a->_name = names[@"args"][[NSString stringWithFormat:@"texture:%lu", (unsigned long)idx]] ?: [NSString stringWithFormat:@"texture%lu", (unsigned long)idx];
                a->_access = [kind isEqualToString:@"StorageImage"] ? MTLBindingAccessReadWrite : nvmtl_access_for(b[@"access"]);
                a->_texType = nvmtl_textype_for_shape(b[@"texture_shape"]);
                // The AIR type name says what MTLArgument does: depth2d/depthcube/... is a depth texture, <uint>/<int>/<half>
                // the component type. Apple's GL picks a texture unit's sampler type from these two: with isDepthTexture NO
                // a sampler2DShadow unit counts as Float and its shader-side compare swizzle (texInfo) stays all Zero, so
                // every shadow lookup returned 0 (Unity's screen-space shadows, Northgard's lit ground: black).
                NSString *ttn = names[@"types"][[NSString stringWithFormat:@"texture:%lu", (unsigned long)idx]];
                a->_depth = [ttn isKindOfClass:[NSString class]] && [ttn rangeOfString:@"depth"].location != NSNotFound;
                a->_texDataType = nvmtl_texdatatype_for_air_name(ttn);
                id loc = b[@"descriptor"]; a->_arrayLength = [loc isKindOfClass:[NSDictionary class]] && [loc[@"count"] unsignedLongValue] > 1 ? [loc[@"count"] unsignedLongValue] : 1;
                [out addObject:a];
            } else if ([kind isEqualToString:@"Sampler"]) {
                NVMTLArgument *a = [NVMTLArgument new]; a->_type = MTLArgumentTypeSampler; a->_index = idx; a->_active = nvmtl_binding_active(b); a->_arrayLength = 1;
                a->_name = names[@"args"][[NSString stringWithFormat:@"sampler:%lu", (unsigned long)idx]] ?: [NSString stringWithFormat:@"sampler%lu", (unsigned long)idx];
                [out addObject:a];
            }
        }
        [out sortUsingComparator:^NSComparisonResult(NVMTLArgument *x, NVMTLArgument *y) {
            if (x->_type != y->_type) return x->_type < y->_type ? NSOrderedAscending : NSOrderedDescending;
            return x->_index < y->_index ? NSOrderedAscending : x->_index > y->_index ? NSOrderedDescending : NSOrderedSame; }];
        NSMutableString *s = [NSMutableString new];
        for (NVMTLArgument *a in out) [s appendFormat:@" %@(%lu)=%@%@", a->_type == MTLArgumentTypeBuffer ? @"buffer" : a->_type == MTLArgumentTypeTexture ? @"texture" : @"sampler",
                                       (unsigned long)a->_index, a->_name, a->_bufStruct ? [NSString stringWithFormat:@"[%lu members, %lu B]", (unsigned long)a->_bufStruct->_members.count, (unsigned long)a->_bufSize] : @""];
        nvlog("REFL %s (%s): %lu argument(s)%s", fn->_fname.UTF8String ?: "?", fn->_stage.UTF8String ?: "?", (unsigned long)out.count, s.UTF8String);
        fn->_arguments = out;
        return out;
    }
}
NVMTLArgument *nvmtl_argument_for_buffer(NVMTLFunction *fn, NSUInteger index)
{
    for (NVMTLArgument *a in nvmtl_arguments_for_function(fn)) if (a->_type == MTLArgumentTypeBuffer && a->_index == index) return a;
    return nil;
}
static NSArray *nvmtl_stage_in_arguments(MTLRenderPipelineDescriptor *d)
{
    MTLVertexDescriptor *vd = d.vertexDescriptor; if (!vd || !d.vertexFunction) return @[];
    NSMutableSet *used = [NSMutableSet set];
    for (NSDictionary *va in nvmtl_function_reflection((NVMTLFunction *)d.vertexFunction)[@"vertex_attributes"])
        if ([va isKindOfClass:[NSDictionary class]] && [va[@"location"] isKindOfClass:[NSNumber class]]) [used addObject:va[@"location"]];
    NSMutableIndexSet *bufs = [NSMutableIndexSet indexSet], *live = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < 31; i++) {
        MTLVertexAttributeDescriptor *at = vd.attributes[i]; if (at.format == MTLVertexFormatInvalid) continue;
        [bufs addIndex:at.bufferIndex]; if ([used containsObject:@(i)]) [live addIndex:at.bufferIndex];
    }
    NSMutableArray *out = [NSMutableArray array]; __block NSUInteger n = 0;
    [bufs enumerateIndexesUsingBlock:^(NSUInteger bi, BOOL *stop) {
        NVMTLStageInArgument *a = [NVMTLStageInArgument new];
        a->_type = MTLArgumentTypeBuffer; a->_index = bi; a->_active = [live containsIndex:bi]; a->_arrayLength = 1; a->_bufAlign = 4;
        a->_access = MTLBindingAccessReadOnly; a->_bufSize = vd.layouts[bi].stride; a->_bufDataType = MTLDataTypeStruct;
        a->_name = [NSString stringWithFormat:@"vertexBuffer.%lu", (unsigned long)n++];
        [out addObject:a];
    }];
    return out;
}
id nvmtl_render_reflection(MTLRenderPipelineDescriptor *d)
{
    NVMTLRenderPipelineReflection *r = [NVMTLRenderPipelineReflection new];
    r->_v = [nvmtl_stage_in_arguments(d) arrayByAddingObjectsFromArray:nvmtl_arguments_for_function((NVMTLFunction *)d.vertexFunction)];
    r->_f = nvmtl_arguments_for_function((NVMTLFunction *)d.fragmentFunction);
    return r;
}
void nvmtl_gl_tag_compute_reflection(id r, id fn);
id nvmtl_compute_reflection(id<MTLFunction> fn)
{
    NVMTLComputePipelineReflection *r = [NVMTLComputePipelineReflection new];
    r->_a = nvmtl_arguments_for_function((NVMTLFunction *)fn);
    nvmtl_gl_tag_compute_reflection(r, fn);
    return r;
}

NSDictionary *nvmtl_index_argument_fields(NSArray *fields) {
    NSMutableDictionary *index = [NSMutableDictionary new];
    for (NSDictionary *field in fields) {
        NSNumber *key = @([field[@"argument_index"] unsignedLongValue]);
        if (!index[key]) index[key] = field;
    }
    return [index copy];
}
@implementation NVMTLArgumentEncoder
- (id<MTLDevice>)device { return (id<MTLDevice>)gNVMTLMainDevice; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { _label = [l copy]; }
- (NSUInteger)encodedLength {
    NSUInteger end = 0;
    for (NSDictionary *f in _fields) {
        NSUInteger e = [f[@"field_offset"] unsignedLongValue] + 8;
        if (e > end) end = e;
    }
    return MAX(end, _airSize) ?: 8;
}
- (NSUInteger)alignment { return _airAlign ?: 8; }
- (void)setArgumentBuffer:(id<MTLBuffer>)b offset:(NSUInteger)off { _dst = nvmtl_as_buffer(b, "argument encoder setArgumentBuffer"); _dstOffset = off; nvtrace("AE argbuf %p off %lu (%lu fields)", (__bridge void *)b, (unsigned long)off, (unsigned long)_fields.count); }
- (void)setArgumentBuffer:(id<MTLBuffer>)b startOffset:(NSUInteger)off arrayElement:(NSUInteger)i {
    [self setArgumentBuffer:b offset:off + i * [self encodedLength]];
}
- (void)dealloc { free(_offAt); _offAt = NULL; }
- (NSDictionary *)nvmtlFieldAt:(NSUInteger)index {
    return _fieldByIndex[@(index)];
}
- (void)setBuffer:(id<MTLBuffer>)b offset:(NSUInteger)off atIndex:(NSUInteger)index {
    NVMTLBuffer *nb = nvmtl_as_buffer(b, "argument encoder setBuffer"); if (b && !nb) return;
    if (!_dst || !nvmtl_buf_cpu(_dst)) { nvlog("argument encoder: no argument buffer set (or it is not host-visible)"); return; }
    NSDictionary *f = [self nvmtlFieldAt:index];
    if (!f) { nvlog("argument encoder: this function has no [[id(%lu)]] field — REFUSED", (unsigned long)index); return; }
    // The binding path checks the offset against the buffer length (nvmtl_vk_bind_buffer); this path
    // computes an address the shader will dereference, so it has to check the same thing.
    if (nb && off > nb->_b.size) {
        nvlog("argument encoder: offset %lu is past the %zu-byte buffer at [[id(%lu)]] - REFUSED",
              (unsigned long)off, nb->_b.size, (unsigned long)index);
        return;
    }
    uint64_t addr = nb ? nvmtl_vk_buffer_address(&nb->_b) + off : 0;
    const NSUInteger fieldOffset = [f[@"field_offset"] unsignedLongValue];
    const size_t size = _dst->_b.size;
    if (_dstOffset > size || fieldOffset > size - _dstOffset || 8 > size - _dstOffset - fieldOffset) {
        nvlog("argument encoder: field offset %lu+%lu does not fit %zu bytes — REFUSED", (unsigned long)_dstOffset, (unsigned long)fieldOffset, size); return;
    }
    NSUInteger at = _dstOffset + fieldOffset;
    if (at + 8 > _dst->_b.size) { nvlog("argument encoder: field at %lu is past the argument buffer (%zu bytes)", (unsigned long)at, _dst->_b.size); return; }
    memcpy((uint8_t *)nvmtl_buf_cpu(_dst) + at, &addr, 8);
}
- (void)setAccelerationStructure:(id<MTLAccelerationStructure>)as atIndex:(NSUInteger)index { [self setBuffer:(id<MTLBuffer>)as offset:0 atIndex:index]; }
- (void)setBuffers:(const id<MTLBuffer> __unsafe_unretained [])bs offsets:(const NSUInteger *)offs withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) [self setBuffer:bs[k] offset:offs ? offs[k] : 0 atIndex:r.location + k];
}
- (void)setTexture:(id<MTLTexture>)t atIndex:(NSUInteger)index {
    if (!_dst || !nvmtl_buf_cpu(_dst)) { nvlog("argument encoder: setTexture: no argument buffer set (or it is not host-visible)"); return; }
    NSDictionary *f = [self nvmtlFieldAt:index];
    if (!f) { nvlog("argument encoder: setTexture:atIndex:%lu — this function has no [[id(%lu)]] field — REFUSED", (unsigned long)index, (unsigned long)index); return; }
    uint64_t handle = t ? [t gpuResourceID]._impl : 0;
    const NSUInteger fieldOffset = [f[@"field_offset"] unsignedLongValue];
    const size_t size = _dst->_b.size;
    if (_dstOffset > size || fieldOffset > size - _dstOffset || 8 > size - _dstOffset - fieldOffset) {
        nvlog("argument encoder: field offset %lu+%lu does not fit %zu bytes — REFUSED", (unsigned long)_dstOffset, (unsigned long)fieldOffset, size); return;
    }
    NSUInteger at = _dstOffset + fieldOffset;
    if (at + 8 > _dst->_b.size) { nvlog("argument encoder: texture field at %lu is past the argument buffer (%zu bytes)", (unsigned long)at, _dst->_b.size); return; }
    memcpy((uint8_t *)nvmtl_buf_cpu(_dst) + at, &handle, 8);
    nvtrace("AE tex id %lu -> %p+%lu handle 0x%llx", (unsigned long)index, (__bridge void *)_dst, (unsigned long)at, (unsigned long long)handle);
}
- (void)setTextures:(const id<MTLTexture> __unsafe_unretained [])t withRange:(NSRange)r { for (NSUInteger k = 0; k < r.length; k++) [self setTexture:t ? t[k] : nil atIndex:r.location + k]; }
- (void)setSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)index {
    if (!_dst || !nvmtl_buf_cpu(_dst)) { nvlog("argument encoder: setSamplerState: no argument buffer set (or it is not host-visible)"); return; }
    NSDictionary *f = [self nvmtlFieldAt:index];
    if (!f) { nvlog("argument encoder: setSamplerState:atIndex:%lu — this function has no [[id(%lu)]] field — REFUSED", (unsigned long)index, (unsigned long)index); return; }
    uint64_t handle = s ? [s gpuResourceID]._impl : 0;
    const NSUInteger fieldOffset = [f[@"field_offset"] unsignedLongValue];
    const size_t size = _dst->_b.size;
    if (_dstOffset > size || fieldOffset > size - _dstOffset || 8 > size - _dstOffset - fieldOffset) {
        nvlog("argument encoder: field offset %lu+%lu does not fit %zu bytes — REFUSED", (unsigned long)_dstOffset, (unsigned long)fieldOffset, size); return;
    }
    NSUInteger at = _dstOffset + fieldOffset;
    if (at + 8 > _dst->_b.size) { nvlog("argument encoder: sampler field at %lu is past the argument buffer (%zu bytes)", (unsigned long)at, _dst->_b.size); return; }
    memcpy((uint8_t *)nvmtl_buf_cpu(_dst) + at, &handle, 8);
    nvtrace("AE samp id %lu -> %p+%lu handle 0x%llx", (unsigned long)index, (__bridge void *)_dst, (unsigned long)at, (unsigned long long)handle);
}
- (void)setSamplerStates:(const id<MTLSamplerState> __unsafe_unretained [])s withRange:(NSRange)r { for (NSUInteger k = 0; k < r.length; k++) [self setSamplerState:s ? s[k] : nil atIndex:r.location + k]; }
- (void)nvmtlPutHandle:(uint64_t)h atIndex:(NSUInteger)index what:(const char *)what {
    if (!_dst || !nvmtl_buf_cpu(_dst)) { nvlog("argument encoder: set%s: no argument buffer set (or it is not host-visible)", what); return; }
    NSDictionary *f = [self nvmtlFieldAt:index];
    if (!f) { nvlog("argument encoder: set%s:atIndex:%lu — this function has no [[id(%lu)]] field — REFUSED", what, (unsigned long)index, (unsigned long)index); return; }
    const size_t size = _dst->_b.size; const NSUInteger fo = [f[@"field_offset"] unsignedLongValue];
    if (_dstOffset > size || fo > size - _dstOffset || 8 > size - _dstOffset - fo) {
        nvlog("argument encoder: %s field at %lu+%lu is past the argument buffer (%zu bytes)", what, (unsigned long)_dstOffset, (unsigned long)fo, size); return; }
    memcpy((uint8_t *)nvmtl_buf_cpu(_dst) + _dstOffset + fo, &h, 8);
    nvtrace("AE %s id %lu -> %p+%lu handle 0x%llx", what, (unsigned long)index, (__bridge void *)_dst, (unsigned long)(_dstOffset + fo), (unsigned long long)h);
}
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)p atIndex:(NSUInteger)i { [self nvmtlPutHandle:p ? p.gpuResourceID._impl : 0 atIndex:i what:"RenderPipelineState"]; }
- (void)setRenderPipelineStates:(const id<MTLRenderPipelineState> __unsafe_unretained [])p withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) [self setRenderPipelineState:p ? p[k] : nil atIndex:r.location + k]; }
- (void)setComputePipelineState:(id<MTLComputePipelineState>)p atIndex:(NSUInteger)i { [self nvmtlPutHandle:p ? p.gpuResourceID._impl : 0 atIndex:i what:"ComputePipelineState"]; }
- (void)setComputePipelineStates:(const id<MTLComputePipelineState> __unsafe_unretained [])p withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) [self setComputePipelineState:p ? p[k] : nil atIndex:r.location + k]; }
- (void)setIndirectCommandBuffer:(id<MTLIndirectCommandBuffer>)icb atIndex:(NSUInteger)index {
    { static int said; if (icb && !said++) nvlog("argument encoder: setIndirectCommandBuffer: writes the ICB's gpuResourceID; GPU-side ICB "
                                             "execution and encoding stay UNSUPPORTED (this ICB is a CPU replay list) (said once)"); }
    [self nvmtlPutHandle:icb ? icb.gpuResourceID._impl : 0 atIndex:index what:"IndirectCommandBuffer"];
}
- (void)setIndirectCommandBuffers:(const id<MTLIndirectCommandBuffer> __unsafe_unretained [])b withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) [self setIndirectCommandBuffer:b ? b[k] : nil atIndex:r.location + k]; }
- (void *)constantDataAtIndex:(NSUInteger)index {
    if (!_offAt) {
        NSUInteger mx = 0; for (NSDictionary *fd in _fields) { NSUInteger a = [fd[@"argument_index"] unsignedLongValue]; if (a > mx) mx = a; }
        int64_t *o = (int64_t *)malloc((mx + 1) * sizeof *o);
        if (o) { for (NSUInteger k = 0; k <= mx; k++) o[k] = -1;
                 for (NSDictionary *fd in _fields) { NSUInteger a = [fd[@"argument_index"] unsignedLongValue]; if (o[a] < 0) o[a] = (int64_t)[fd[@"field_offset"] unsignedLongValue]; }
                 _offN = mx + 1; _offAt = o; }
    }
    if (!_offAt || index >= _offN || _offAt[index] < 0 || !_dst || !nvmtl_buf_cpu(_dst)) return NULL;
    const NSUInteger fieldOffset = (NSUInteger)_offAt[index];
    const size_t size = _dst->_b.size;
    if (_dstOffset >= size || fieldOffset >= size - _dstOffset) return NULL;
    return (uint8_t *)nvmtl_buf_cpu(_dst) + _dstOffset + fieldOffset;
}
@end

extern NSData *nvmtl_compile_library_entry(NSData *, NSString *, NSString *, NSString *, NSString **);
@implementation NVMTLLibrary
- (MTLLibraryType)type { return MTLLibraryTypeExecutable; }
- (NSString *)installName { return nil; }
- (NSData *)nvmtlEntrySpirv:(NSString *)name error:(NSError **)error {
    @synchronized(self) {
        NSData *cached = _compiledFns[name];
        if (cached) return cached;
    }

    NSData *air = _fns[name];
    NSString *ll = _airs[name], *stage = _stages[name];
    // The library index hands every library made from the same file the same bitcode objects, so the entry's SPIR-V is
    // kept on its bitcode: a library made again (VideoToolbox makes one per transfer) neither hashes nor reads it again.
    NSData *known = air ? objc_getAssociatedObject(air, &gNVMTLEntrySpvAssoc) : nil;
    NSString *why = nil;
    NSData *spv = known ?: nvmtl_compile_library_entry(air, ll, stage, name, &why);
    if (!spv) {
        if (error) *error = [NSError errorWithDomain:@"NVMTL" code:3
                                           userInfo:@{NSLocalizedDescriptionKey:why ?: @"entry translation failed"}];
        return nil;
    }
    if (!known && air) objc_setAssociatedObject(air, &gNVMTLEntrySpvAssoc, spv, OBJC_ASSOCIATION_RETAIN);

    @synchronized(self) {
        NSData *won = _compiledFns[name];
        if (won) return won;
        if (!_compiledFns) _compiledFns = [NSMutableDictionary new];
        _compiledFns[name] = spv;
    }
    return spv;
}
- (id<MTLDevice>)device { return (id<MTLDevice>)gNVMTLMainDevice; }
- (id<MTLFunction>)newFunctionWithName:(NSString *)name {
    NSData *spv = [_fns objectForKey:name];
    if (!spv && !_airs[name]) { nvlog("library: no function \"%s\" (this library holds %lu, externs %lu)", name.UTF8String, (unsigned long)(_fns.count + _airs.count), (unsigned long)_externs.count); return nil; }
    if (spv && ([_stages[name] isEqualToString:@"mesh"] || [_stages[name] isEqualToString:@"object"])) {
        NVMTLFunction *f = [NVMTLFunction new]; f->_spirv = nil; f->_fname = name; f->_stage = _stages[name];
        f->_air = _airs[name]; f->_lib = self; return f;
    }
    const uint32_t af = spv ? nvmtl_air_text_flags(_airs[name]) : 0;
    if (spv && (af & NVMTL_AIRF_DYLD_TABLE)) {
        nvlog("library: \"%s\" was compiled against a dynamic library - DEFERRED to pipeline creation", name.UTF8String);
        NVMTLFunction *f = [NVMTLFunction new]; f->_spirv = nil; f->_fname = name; f->_stage = (_stages[name] ?: @"");
        f->_air = _airs[name]; f->_lib = self; f->_needsLink = YES; return f;
    }
    if (spv && (af & NVMTL_AIRF_ISECT_TABLE)) {
        nvlog("library: \"%s\" takes an intersection function table - DEFERRED to pipeline creation", name.UTF8String);
        NVMTLFunction *f = [NVMTLFunction new]; f->_spirv = nil; f->_fname = name; f->_stage = (_stages[name] ?: @"");
        f->_air = _airs[name]; f->_lib = self; f->_needsLink = YES; return f;
    }
    if (spv) { NSError *te = nil; NSData *es = [self nvmtlEntrySpirv:name error:&te];
        if (!es && _airs[name] && nvmtl_needs_visible_link(_airs[name], te.localizedDescription)) {
            nvlog("library: \"%s\" calls a visible function (by reference or table) - DEFERRED to pipeline creation", name.UTF8String);
            NVMTLFunction *f = [NVMTLFunction new]; f->_spirv = nil; f->_fname = name; f->_stage = (_stages[name] ?: @"");
            f->_air = _airs[name]; f->_lib = self; f->_needsLink = YES; return f;
        }
        if (!es && _airs[name] && ([te.localizedDescription rangeOfString:@"`air.constant`"].location != NSNotFound || [name hasPrefix:@"__entry_"])) {
            nvlog("library: \"%s\" has a by-value (air.constant) parameter - DEFERRED to newFunctionWithPluginData (OpenCL via AMOGL)", name.UTF8String);
            NVMTLFunction *f = [NVMTLFunction new]; f->_spirv = nil; f->_fname = name; f->_stage = (_stages[name] ?: @"kernel");
            f->_air = _airs[name]; f->_lib = self; return f;
        }
        spv = es; if (!spv) return nil; }
    NVMTLFunction *f = [NVMTLFunction new]; f->_spirv = spv; f->_fname = name; f->_stage = (_stages[name] ?: @""); f->_air = _airs[name]; f->_lib = self; return f;
}
static size_t nvmtl_fc_width(NSUInteger dataType)
{
    const struct { NSUInteger base; size_t bytes; } families[] = {
        {MTLDataTypeFloat,4},{MTLDataTypeHalf,2},{MTLDataTypeInt,4},{MTLDataTypeUInt,4},
        {MTLDataTypeShort,2},{MTLDataTypeUShort,2},{MTLDataTypeChar,1},{MTLDataTypeUChar,1},
        {MTLDataTypeBool,1},{MTLDataTypeLong,8},{MTLDataTypeULong,8}};
    for(size_t i=0;i<sizeof(families)/sizeof(families[0]);i++)
        if(dataType>=families[i].base && dataType<=families[i].base+3)
            return families[i].bytes*(dataType-families[i].base+1);
    switch (dataType) {
        case MTLDataTypeBool:  case MTLDataTypeChar:  case MTLDataTypeUChar:  return 1;
        case MTLDataTypeShort: case MTLDataTypeUShort: case MTLDataTypeHalf:  return 2;
        case MTLDataTypeInt:   case MTLDataTypeUInt:  case MTLDataTypeFloat:  return 4;
        case MTLDataTypeLong:  case MTLDataTypeULong:                          return 8;
        default: return 0;
    }
}
- (id<MTLFunction>)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)cv error:(NSError **)error {
    if (error) *error = nil;
    NSData *spv = [_fns objectForKey:name];
    if (!spv && _airs[name]) {
        if (cv) nvlog("library: visible function \"%s\" asked with constant values — carried on the function",
                      name.UTF8String);
        id<MTLFunction> vf = [self newFunctionWithName:name];
        if (cv && [(id)vf isKindOfClass:[NVMTLFunction class]]) ((NVMTLFunction *)vf)->_fcv = cv;
        return vf;
    }
    if (!spv) { nvlog("library: no function \"%s\" (this library holds %lu, externs %lu)", name.UTF8String,
                      (unsigned long)(_fns.count + _airs.count), (unsigned long)_externs.count);
        if (error) *error = [NSError errorWithDomain:@"NVMTL" code:1 userInfo:@{NSLocalizedDescriptionKey: @"no such function"}];
        return nil; }
    NSArray *vals = nil;
    SEL sel = NSSelectorFromString(@"newIndexedConstantArray");
    if (cv && [cv respondsToSelector:sel]) vals = ((id (*)(id, SEL))objc_msgSend)(cv, sel);
    SEL namedSel=NSSelectorFromString(@"newNamedConstantArray");
    NSArray *named=(cv && [cv respondsToSelector:namedSel]) ? ((id(*)(id,SEL))objc_msgSend)(cv,namedSel) : nil;
    if(named.count) {
        NSString *air=_airs[name];
        if(!air){if(error)*error=[NSError errorWithDomain:@"NVMTL" code:4 userInfo:@{NSLocalizedDescriptionKey:@"named constants require retained AIR"}];return nil;}
        NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:@"^![0-9]+ = !\\{[^\\n]*\\.MTL_FC_INIT_[^\\n]*, !\"[^\"]+\", !\"([^\"]+)\", i32 ([0-9]+), i1 (?:true|false)\\}$" options:NSRegularExpressionAnchorsMatchLines error:NULL];
        NSMutableDictionary *indices=[NSMutableDictionary new];
        for(NSTextCheckingResult *m in [re matchesInString:air options:0 range:NSMakeRange(0,air.length)])
            indices[[air substringWithRange:[m rangeAtIndex:1]]]=@([[air substringWithRange:[m rangeAtIndex:2]] longLongValue]);
        MTLFunctionConstantValues *merged=[MTLFunctionConstantValues new];
        NSUInteger applied=0;
        for(id v in named) {
            Ivar ni=class_getInstanceVariable([v class],"_name"),ti=class_getInstanceVariable([v class],"_dataType"),di=class_getInstanceVariable([v class],"_data");
            if(!ni || !ti || !di){if(error)*error=[NSError errorWithDomain:@"NVMTL" code:4 userInfo:@{NSLocalizedDescriptionKey:@"unrecognized named-constant representation"}];return nil;}
            NSString *key=object_getIvar(v,ni);NSNumber *index=indices[key];
            if(!index)continue;
            const uint8_t *base=(const uint8_t *)(__bridge void *)v;
            NSUInteger type=*(const NSUInteger *)(base+ivar_getOffset(ti));
            const void *data=*(const void *const *)(base+ivar_getOffset(di));
            if(!data || !nvmtl_fc_width(type)){if(error)*error=[NSError errorWithDomain:@"NVMTL" code:4 userInfo:@{NSLocalizedDescriptionKey:@"unsupported named-constant type"}];return nil;}
            [merged setConstantValue:data type:type atIndex:index.unsignedIntegerValue];applied++;
        }
        for(id v in vals) {
            Ivar ii=class_getInstanceVariable([v class],"_index"),ti=class_getInstanceVariable([v class],"_dataType"),di=class_getInstanceVariable([v class],"_data");
            if(!ii || !ti || !di){if(error)*error=[NSError errorWithDomain:@"NVMTL" code:4 userInfo:@{NSLocalizedDescriptionKey:@"unrecognized indexed-constant representation"}];return nil;}
            const uint8_t *base=(const uint8_t *)(__bridge void *)v;
            [merged setConstantValue:*(const void *const *)(base+ivar_getOffset(di)) type:*(const NSUInteger *)(base+ivar_getOffset(ti)) atIndex:*(const NSUInteger *)(base+ivar_getOffset(ii))];
        }
        vals=((id(*)(id,SEL))objc_msgSend)(merged,sel);
        nvlog("named constants: %s applied %lu of %lu, merged %lu",name.UTF8String,(unsigned long)applied,(unsigned long)named.count,(unsigned long)vals.count);
    }
    if (vals.count == 0 && ([_stages[name] isEqualToString:@"mesh"] || [_stages[name] isEqualToString:@"object"]) && _airs[name]) {
        nvlog("newFunctionWithName:constantValues: \"%s\" is a %s function - %zu constant(s) DEFERRED to the mesh pipeline",
              name.UTF8String, [_stages[name] UTF8String], (size_t)0);
        if (error) *error = nil;
        NVMTLFunction *f = [NVMTLFunction new]; f->_spirv = nil; f->_fc = nil; f->_fname = name; f->_stage = _stages[name];
        f->_air = _airs[name]; f->_lib = self; f->_fcv = cv; return f;
    }
    if (vals.count == 0) {
        spv = [self nvmtlEntrySpirv:name error:error]; if (!spv) return nil;
        NVMTLFunction *f0 = [NVMTLFunction new];
        f0->_spirv = spv; f0->_fname = name; f0->_stage = (_stages[name] ?: @""); f0->_air = _airs[name]; f0->_lib = self; f0->_fcv = cv;
        nvlog("newFunctionWithName:constantValues: \"%s\" - no constants, unspecialized module (%lu B)",
              name.UTF8String, (unsigned long)spv.length);
        return f0;
    }
    NSUInteger capacity = vals.count;
        __attribute__((objc_precise_lifetime)) NSMutableData *packed = nvmtl_fc_storage(capacity);
        uint32_t *idx = packed.mutableBytes, *sz = idx ? idx + capacity : NULL;
        const uint8_t **pay = sz ? (const uint8_t **)(sz + capacity) : NULL;
        (void)pay; size_t n = 0;
    if (!packed) { if(error)*error=[NSError errorWithDomain:@"NVMTL" code:4 userInfo:@{NSLocalizedDescriptionKey:@"function constant storage allocation failed"}]; return nil; }
    for (id v in vals) {
        Ivar ii = class_getInstanceVariable([v class], "_index");
        Ivar it = class_getInstanceVariable([v class], "_dataType");
        Ivar id_ = class_getInstanceVariable([v class], "_data");
        if (!ii || !it || !id_) { nvlog("function constants: MTLIndexedConstantValue has no _index/_dataType/_data"); vals = nil; break; }
        const uint8_t *base = (const uint8_t *)(__bridge void *)v;
        NSUInteger index = *(const NSUInteger *)(base + ivar_getOffset(ii));
        NSUInteger dtype = *(const NSUInteger *)(base + ivar_getOffset(it));
        const uint8_t *data = *(const uint8_t *const *)(base + ivar_getOffset(id_));
        size_t w = nvmtl_fc_width(dtype);
        if (!w || !data) { nvlog("function constants: index %lu has data type %lu, which this driver does not encode", (unsigned long)index, (unsigned long)dtype);
            if (error) *error = [NSError errorWithDomain:@"NVMTL" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"function constant %lu: unsupported data type %lu", (unsigned long)index, (unsigned long)dtype]}];
            return nil; }
        idx[n] = (uint32_t)index; sz[n] = (uint32_t)w; pay[n] = data; n++;
    }
    NSString *e = nil;
    NSMutableDictionary *constants=[NSMutableDictionary new];
    for(size_t k=0;k<n;k++){NSMutableArray *bytes=[NSMutableArray new];for(uint32_t j=0;j<sz[k];j++)[bytes addObject:@(pay[k][j])];constants[[@(idx[k]) stringValue]]=bytes;}
    if (([_stages[name] isEqualToString:@"mesh"] || [_stages[name] isEqualToString:@"object"]) && _airs[name]) {
        nvlog("newFunctionWithName:constantValues: \"%s\" is a %s function - %zu constant(s) DEFERRED to the mesh pipeline",
              name.UTF8String, [_stages[name] UTF8String], n);
        if (error) *error = nil;
        NVMTLFunction *f = [NVMTLFunction new]; f->_spirv = nil; f->_fc = [constants copy]; f->_fname = name; f->_stage = _stages[name];
        f->_air = _airs[name]; f->_lib = self; f->_fcv = cv; return f;
    }
    nvmtl_fc_expect_link(1);
    NSData *spec = nvmtl_translate_with_fc_cached(_airs[name], _stages[name], name, constants, idx, sz, pay, n, &e);
    nvmtl_fc_expect_link(0);
    if (!spec && _airs[name] && nvmtl_needs_visible_link(_airs[name], e)) {
        nvlog("newFunctionWithName:constantValues: \"%s\" has visible-function references - DEFERRED to pipeline creation (%zu constant(s))", name.UTF8String, n);
        if (error) *error = nil;
        NVMTLFunction *f = [NVMTLFunction new]; f->_spirv = nil; f->_fc = [constants copy]; f->_fname = name; f->_stage = (_stages[name] ?: @"");
        f->_air = _airs[name]; f->_lib = self; f->_fcv = cv; f->_needsLink = YES; return f;
    }
    if (!spec) {
        nvlog("newFunctionWithName:constantValues: \"%s\" — %s", name.UTF8String, e.UTF8String ?: "specialization failed");
        if (error) *error = [NSError errorWithDomain:@"NVMTL" code:3 userInfo:@{NSLocalizedDescriptionKey: e ?: @"specialization failed"}];
        return nil;
    }
    nvlog("newFunctionWithName:constantValues: \"%s\" specialized with %zu constant(s)", name.UTF8String, n);
    NVMTLFunction *f = [NVMTLFunction new]; f->_spirv = spec; f->_fc = [constants copy]; f->_fname = name; f->_stage = (_stages[name] ?: @""); f->_air = _airs[name]; f->_lib = self; f->_fcv = cv; return f;
}
- (void)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)cv
          completionHandler:(void (^)(id<MTLFunction>, NSError *))handler {
    if (!handler) return;
    NSError *err = nil;
    id<MTLFunction> f = [self newFunctionWithName:name constantValues:cv error:&err];
    handler(f, err);
}
- (id<MTLFunction>)newFunctionWithDescriptor:(id)desc error:(NSError **)error {
    if (error) *error = nil;
    if (!desc) {
        if (error) *error = [NSError errorWithDomain:@"NVMTL" code:1
                             userInfo:@{NSLocalizedDescriptionKey: @"newFunctionWithDescriptor: nil descriptor"}];
        nvlog("newFunctionWithDescriptor: nil descriptor");
        return nil;
    }
    NSString *name = [desc respondsToSelector:@selector(name)] ? [desc name] : nil;
    NSString *spec = [desc respondsToSelector:@selector(specializedName)] ? [desc specializedName] : nil;
    id cv = [desc respondsToSelector:@selector(constantValues)] ? [desc constantValues] : nil;
    if (![name isKindOfClass:[NSString class]] || !name.length) {
        if (error) *error = [NSError errorWithDomain:@"NVMTL" code:2
                             userInfo:@{NSLocalizedDescriptionKey: @"newFunctionWithDescriptor: descriptor has no name"}];
        nvlog("newFunctionWithDescriptor: %s has no usable name", object_getClassName(desc));
        return nil;
    }
    nvlog("newFunctionWithDescriptor: \"%s\"%s%s%s", name.UTF8String,
          spec.length ? " specializedName \"" : "", spec.length ? spec.UTF8String : "", spec.length ? "\"" : "");
    id<MTLFunction> f = cv ? [self newFunctionWithName:name constantValues:(MTLFunctionConstantValues *)cv error:error]
                           : [self newFunctionWithName:name];
    if (spec.length && [(id)f isKindOfClass:[NVMTLFunction class]]) ((NVMTLFunction *)f)->_specName = [spec copy];
    if (cv) return f;
    if (!f && error)
        *error = [NSError errorWithDomain:@"NVMTL" code:3
                  userInfo:@{NSLocalizedDescriptionKey:
                             [NSString stringWithFormat:@"this library has no function named %@", name]}];
    return f;
}
- (void)newFunctionWithDescriptor:(id)desc completionHandler:(void (^)(id<MTLFunction>, NSError *))handler {
    if (!handler) return;
    NSError *err = nil;
    id<MTLFunction> f = [self newFunctionWithDescriptor:desc error:&err];
    handler(f, err);
}
- (NSArray<NSString *> *)externFunctionNames {
    NSSet<NSString *> *x = nvmtl_mtlb_extern_names(_raw);
    return x.count ? x.allObjects : (_externs ?: @[]);
}

- (NSArray<NSString *> *)functionNames {
    NSMutableSet<NSString *> *s = [NSMutableSet setWithArray:_fns.allKeys];
    [s addObjectsFromArray:_airs.allKeys];
    [s minusSet:nvmtl_mtlb_extern_names(_raw)];
    return s.allObjects;
}

- (id)newExternFunctionWithName:(NSString *)name {
    if (![nvmtl_mtlb_extern_names(_raw) containsObject:name]) {
        nvlog("newExternFunctionWithName: \"%s\" is not an extern function of this library (%lu are)", name.UTF8String,
              (unsigned long)nvmtl_mtlb_extern_names(_raw).count);
        return nil;
    }
    id twin;
    @synchronized (self) { twin = [(id)gNVMTLMainDevice nvmtlAppleTwinOf:self]; }
    id f = [twin respondsToSelector:@selector(newExternFunctionWithName:)] ? [twin newExternFunctionWithName:name] : nil;
    if (!f) nvlog("newExternFunctionWithName: \"%s\" - the Apple twin %s it; answering nil (CI reports the kernel missing)",
                  name.UTF8String, twin ? "refused" : "could not be built for");
    return f;
}
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { _label = [l copy]; }
@end

#define NVMTL_RESID_PIPE (1ull << 61)
static uint64_t nvmtl_resid_pipe(id o, uint64_t *slot) {
    static uint64_t seq;
    @synchronized (o) { if (!*slot) *slot = __atomic_add_fetch(&seq, 1, __ATOMIC_RELAXED) | NVMTL_RESID_PIPE; }
    return *slot;
}

#pragma mark - pipeline state
@implementation NVMTLRenderPipelineState
- (void)dealloc { nvmtl_vk_pipeline_destroy(&_p); }
- (id<MTLDevice>)device { return (id<MTLDevice>)gNVMTLMainDevice; }
- (NSUInteger)maxTotalThreadsPerThreadgroup { return 1024; }
- (NSUInteger)threadExecutionWidth { return 32; }
- (BOOL)threadgroupSizeMatchesTileSize { return NO; }
- (NSString *)label { return _descriptor.label; }
- (BOOL)supportIndirectCommandBuffers { return _descriptor.supportIndirectCommandBuffers; }
- (MTLResourceID)gpuResourceID {
    MTLResourceID r; r._impl = _descriptor.supportIndirectCommandBuffers ? nvmtl_resid_pipe(self, &_resid) : 0; return r; }
- (NSUInteger)imageblockSampleLength { return 0; }
- (NSUInteger)imageblockMemoryLengthForDimensions:(MTLSize)d { return 0; }
- (MTLShaderValidation)shaderValidation { return MTLShaderValidationDisabled; }
@end

#pragma mark - encoder
// shmirror: a texture made on an adopted Shared buffer is written through image stores / render targets, which the
// store instrumentation does not see: every recording that binds such a writable texture copies its bytes back whole
void nvmtl_shm_note_vk_write(nvk_cmdbuf *c, const nvk_buffer *dst, size_t off, size_t len);
static void nvmtl_shm_texture_bound(NVMTLCommandBuffer *cb, NVMTLTexture *t)
{
    NVMTLTexture *r = t->_parent ? t->_parent : t; NVMTLBuffer *b = r->_backBuf;
    if (!b || !b->_b.shm) return;
    const MTLTextureUsage u = (MTLTextureUsage)r->_usage;
    if (u != MTLTextureUsageUnknown && !NVMTL_USAGE_WRITES(u) && !(u & MTLTextureUsageRenderTarget)) return;
    nvmtl_shm_note_vk_write(&cb->_c, &b->_b, r->_backOff, (size_t)r->_backBPR * (r->_i.h ? r->_i.h : 1));
    static int said; if (!said++) nvlog("shmirror: a writable texture on an adopted Shared buffer was bound - its bytes are copied back whole after each part that binds it");
}
static void nvmtl_retain_resource(NVMTLCommandBuffer *cb, id resource) {
    if (!resource) return;
    nvmtl_huse(cb, resource);
    if (!cb->_resources) cb->_resources = [NVMTLResSet new];
    [cb->_resources addObject:resource];
    if (nvmtl_shm_on() && [resource isKindOfClass:[NVMTLTexture class]]) nvmtl_shm_texture_bound(cb, (NVMTLTexture *)resource);
}

@implementation NVMTLCounter
- (NSString *)name { return MTLCommonCounterTimestamp; }
@end
@implementation NVMTLCounterSet
- (NSString *)name { return MTLCommonCounterSetTimestamp; }
- (NSArray *)counters { return _counters; }
@end
id<MTLCounterSet> nvmtl_timestamp_counter_set(void)
{
    static NVMTLCounterSet *set; static dispatch_once_t once;
    dispatch_once(&once, ^{ NVMTLCounterSet *s = [NVMTLCounterSet new]; s->_counters = @[[NVMTLCounter new]]; set = s; });
    return set;
}
@implementation NVMTLCounterSampleBuffer
- (id<MTLDevice>)device { return _dev; }
- (NSString *)label { return _label ?: @""; }
- (NSUInteger)sampleCount { return _count; }
- (NSData *)resolveCounterRange:(NSRange)r {
    if (!r.length || r.location > _count || r.length > _count - r.location) {
        nvlog("resolveCounterRange: %lu+%lu is outside this buffer's %lu samples - nil", (unsigned long)r.location, (unsigned long)r.length, (unsigned long)_count);
        return nil;
    }
    NSMutableData *d = [NSMutableData dataWithLength:r.length * 8];
    if (nvmtl_vk_ts_read(_pool, (uint32_t)r.location, (uint32_t)r.length, d.mutableBytes)) { nvlog("resolveCounterRange: read FAILED - nil"); return nil; }
    return d;
}
- (void)dealloc { nvmtl_vk_ts_pool_destroy(_pool); _pool = NULL; }
@end
static void nvmtl_counter_recording_failed(NVMTLCommandBuffer *cb)
{
    cb->_c.counter_error = 1;
    [cb nvmtlRecordEncodingError:[NSError errorWithDomain:MTLCommandBufferErrorDomain
        code:MTLCommandBufferErrorInternal userInfo:@{NSLocalizedDescriptionKey:@"Counter recording failed"}]];
}
static void nvmtl_sample_counter(NVMTLCommandBuffer *cb, id sb, NSUInteger i, id who, BOOL barrier)
{
    static int said_foreign, said_range, said_fail;
    if (![sb isKindOfClass:[NVMTLCounterSampleBuffer class]]) {
        if (said_foreign++ < 4) nvlog("%s sampleCountersInBuffer: %s is not a sample buffer this device made - not sampled", object_getClassName(who), sb ? object_getClassName(sb) : "nil");
        nvmtl_counter_recording_failed(cb); return;
    }
    NVMTLCounterSampleBuffer *b = sb;
    if (i >= b->_count) {
        if (said_range++ < 4) nvlog("%s sampleCountersInBuffer: index %lu is past the buffer's %lu samples - not sampled", object_getClassName(who), (unsigned long)i, (unsigned long)b->_count);
        nvmtl_counter_recording_failed(cb); return;
    }
    if (!cb->_resources) cb->_resources = [NVMTLResSet new];
    [cb->_resources addObject:b];
    if (nvmtl_vk_cmd_ts_write(&cb->_c, b->_pool, (uint32_t)i, barrier)) {
        nvmtl_counter_recording_failed(cb);
        if (said_fail++ < 4) nvlog("%s sampleCountersInBuffer: index %lu - recording failed", object_getClassName(who), (unsigned long)i);
    }
}

unsigned nvmtl_apps1_resolve_miss, nvmtl_apps1_resolve_extra, nvmtl_apps1_ds_resolve_miss;
@interface NVMTLRenderCommandEncoder () { unsigned _groupDepth, _dumpDepth; NSString *_dumpName; BOOL _dumpPso; }
- (void)nvmtlDumpBoundFragmentBuffers;
@end
@implementation NVMTLRenderCommandEncoder
- (NSUInteger)tileWidth { return 0; }
- (NSUInteger)tileHeight { return 0; }
- (unsigned long long)globalTraceObjectID { return nvmtl_global_trace_id(self); }
static NSMutableDictionary *g_sampvar; static pthread_mutex_t g_sampvar_lock = PTHREAD_MUTEX_INITIALIZER;
extern unsigned char *CC_SHA256(const void *data, uint32_t len, unsigned char *md);
static char kNVMTLSampvarAir;
static NSString *nvmtl_air_digest(NVMTLFunction *f) {
    if (!f) return @"-";
    NSString *h = objc_getAssociatedObject(f, &kNVMTLSampvarAir); if (h) return h;
    NSData *u = [f->_air dataUsingEncoding:NSUTF8StringEncoding]; unsigned char md[32];
    CC_SHA256(u.bytes, (uint32_t)u.length, md);
    NSMutableString *x = [NSMutableString stringWithCapacity:64]; for (int i = 0; i < 32; i++) [x appendFormat:@"%02x", md[i]];
    objc_setAssociatedObject(f, &kNVMTLSampvarAir, x, OBJC_ASSOCIATION_RETAIN_NONATOMIC); return x;
}
static NSString *nvmtl_sampvar_key(MTLRenderPipelineDescriptor *d, NVMTLFunction *vf, NVMTLFunction *ff, NSData *skey) {
    static int off = -1; if (off < 0) off = getenv("NVMTL_NO_SAMPVAR") != NULL;
    if (off || !d || !vf || !vf->_air || (ff && !ff->_air)) return nil;
    MTLRenderPipelineDescriptor *c = [d copy]; c.vertexFunction = nil; c.fragmentFunction = nil; c.label = @"";
    for (MTLLinkedFunctions *lf in @[c.vertexLinkedFunctions ?: (id)[NSNull null], c.fragmentLinkedFunctions ?: (id)[NSNull null]]) {
        if ((id)lf == [NSNull null]) continue;
        if (lf.functions.count || lf.binaryFunctions.count || lf.groups.count || lf.privateFunctions.count) return nil;
    }
    NSString *ds = c.description; NSRange nl = [ds rangeOfString:@"\n"];
    if (nl.location != NSNotFound) ds = [ds substringFromIndex:nl.location];
    static NSRegularExpression *addr; static dispatch_once_t once;
    dispatch_once(&once, ^{ addr = [NSRegularExpression regularExpressionWithPattern:@"0x[0-9a-fA-F]+" options:0 error:NULL]; });
    ds = [addr stringByReplacingMatchesInString:ds options:0 range:NSMakeRange(0, ds.length) withTemplate:@"@"];
    NSString *sk = [[NSString alloc] initWithData:skey encoding:NSUTF8StringEncoding] ?: @"";
    return [NSString stringWithFormat:@"%@|%@|%@|%@||%@|%@|%@|%@||%@||%@", nvmtl_air_digest(vf), vf->_fname, vf->_stage, vf->_fc ?: @{},
            nvmtl_air_digest(ff), ff ? ff->_fname : @"", ff ? ff->_stage : @"", ff ? (ff->_fc ?: @{}) : @{}, sk, ds];
}
static id nvmtl_sampvar_get(NSString *k) {
    if (!k) return nil;
    pthread_mutex_lock(&g_sampvar_lock); id e = g_sampvar[k]; pthread_mutex_unlock(&g_sampvar_lock);
    if (e) nvlog("sampvar: device cache HIT - a new pipeline state of the same shaders + samplers + descriptor reuses its variant");
    return e;
}
static void nvmtl_sampvar_put(NSString *k, id ps, NVMTLFunction *vf, NVMTLFunction *ff) {
    if (!k || !ps) return;
    pthread_mutex_lock(&g_sampvar_lock);
    if (!g_sampvar) g_sampvar = [NSMutableDictionary new];
    if (g_sampvar.count >= 1024) { [g_sampvar removeAllObjects]; nvlog("sampvar: device cache reached 1024 variants - cleared"); }
    g_sampvar[k] = ps;
    pthread_mutex_unlock(&g_sampvar_lock);
}
static NSDictionary *nvmtl_pixel_sampler_norm(NSDictionary *m) {
    static int off = -1; if (off < 0) off = getenv("NVMTL_NO_SAMPKEY") != NULL;
    if (off || !m.count) return m ?: @{};
    NSMutableDictionary *o = [NSMutableDictionary dictionaryWithCapacity:m.count];
    for (NSString *k in m) { NSMutableDictionary *st = [m[k] mutableCopy]; st[@"lod_max_clamp"] = @65504.0f; o[k] = st; }
    return o;
}
static BOOL nvmtl_pixel_sampler_update(NSMutableDictionary *states, NSString *index, NSDictionary *state) {
    NSDictionary *old = states[index];
    if (old == state || [old isEqual:state]) return NO;
    if (state) states[index] = state; else [states removeObjectForKey:index];
    return YES;
}
- (NVMTLRenderPipelineState *)nvmtlSamplerPipeline {
    NVMTLRenderPipelineState *selected=_ps;
    {
        NSDictionary *vS=nil,*fS=nil;
        if (!_pixelSamplerKey) {
            NSDictionary *vertex=_vertexSamplers ?: @{}, *fragment=_fragmentSamplers ?: @{};
            for (NSArray *entry in _pixelSamplerKeys) {
                if ([entry[0] isEqual:vertex] && [entry[1] isEqual:fragment]) { _pixelSamplerKey=entry[2]; break; }
            }
            if (!_pixelSamplerKey) {
                vS=nvmtl_pixel_sampler_norm(vertex); fS=nvmtl_pixel_sampler_norm(fragment);
                _pixelSamplerKey=[NSJSONSerialization dataWithJSONObject:@[vS,fS] options:NSJSONWritingSortedKeys error:NULL];
                if (!_pixelSamplerKeys) _pixelSamplerKeys=[NSMutableArray new];
                if (_pixelSamplerKeys.count == 8) [_pixelSamplerKeys removeObjectAtIndex:0];
                [_pixelSamplerKeys addObject:@[[vertex copy],[fragment copy],_pixelSamplerKey]];
            }
        }
        NSData *key=_pixelSamplerKey;
        @synchronized(_ps) {
            if(!_ps->_samplerVariants) _ps->_samplerVariants=[NSMutableDictionary new];
            id cached=_ps->_samplerVariants[key];
            if(cached==[NSNull null]) return nil;
            selected=cached;
            if(!selected) {
                // Reusing the key across pipelines still performs each pipeline's own variant lookup.
                if (!vS) vS=nvmtl_pixel_sampler_norm(_vertexSamplers);
                if (!fS) fS=nvmtl_pixel_sampler_norm(_fragmentSamplers);
                NVMTLFunction *vf=_ps->_linkedVert?:(id)_ps->_descriptor.vertexFunction,*ff=_ps->_linkedFrag?:(id)_ps->_descriptor.fragmentFunction;
                NSString *why=nil;
                NSString *gk=nvmtl_sampvar_key(_ps->_descriptor,vf,ff,key); selected=nvmtl_sampvar_get(gk);
                NSData *v=selected?nil:nvmtl_translate_samplers(vf,vS,0,&why),*f=(selected||!v)?nil:(ff?nvmtl_translate_samplers(ff,fS,_ps->_a8mask,&why):[NSData data]);
                if(v && f) {
                    NVMTLFunction *vs=[NVMTLFunction new],*fs=ff?[NVMTLFunction new]:nil;
                    vs->_spirv=v;vs->_fname=vf->_fname;vs->_stage=vf->_stage;
                    if(fs){fs->_spirv=f;fs->_fname=ff->_fname;fs->_stage=ff->_stage;}
                    nvmtl_gl_uniform_inherit(vs, vf);
                    nvmtl_gl_uniform_inherit(fs, ff);
                    MTLRenderPipelineDescriptor *desc=[_ps->_descriptor copy];desc.vertexFunction=vs;desc.fragmentFunction=fs;
                    NSError *error=nil;selected=(id)[(id<MTLDevice>)gNVMTLMainDevice newRenderPipelineStateWithDescriptor:desc error:&error];
                    if(!selected)why=error.description;
                    else nvmtl_sampvar_put(gk,selected,vf,ff);
                }
                if(!selected){nvlog("pixel sampler specialization REFUSED %s: %s",_ps->_fname.UTF8String,why.UTF8String);_ps->_samplerVariants[key]=[NSNull null];return nil;}
                _ps->_samplerVariants[key]=selected;
                nvlog("pixel sampler variant built: %s / %s",_ps->_vname.UTF8String,_ps->_fname.UTF8String);
            }
        }
    }
    return selected;
}
static uint32_t nvmtl_dl_hash(NVMTLBuffer *b, NSUInteger off)
{
    if (!b || !b->_b.map || off >= b->_b.size) return 0;
    const size_t n = MIN((size_t)256, b->_b.size - off); const uint8_t *p = (const uint8_t *)b->_b.map + off; uint32_t h = 2166136261u;
    for (size_t k = 0; k < n; k++) { h ^= p[k]; h *= 16777619u; }
    return h;
}
static uint32_t nvmtl_dl_fn(id fn)
{
    if (![(id)fn isKindOfClass:[NVMTLFunction class]]) return 0;
    const uint8_t *h = [(NVMTLFunction *)fn bitCodeHash]; return h ? (uint32_t)h[0] << 24 | (uint32_t)h[1] << 16 | (uint32_t)h[2] << 8 | h[3] : 0;
}
static void nvmtl_drawlog(NVMTLRenderCommandEncoder *e)
{
    static _Atomic unsigned from = ~0u, until; static _Atomic uint64_t nextCheck;
    const unsigned fr = atomic_load_explicit(&nvmtl_flick_frame, memory_order_relaxed);
    const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now >= atomic_load(&nextCheck)) {
        atomic_store(&nextCheck, now + 250000000ull);
        if (access("/tmp/nvmtl-drawlog", F_OK) == 0) {
            int cnt = 60, delay = 0; FILE *pf = fopen("/tmp/nvmtl-drawlog", "r"); if (pf) { if (fscanf(pf, "%d %d", &cnt, &delay) < 1) cnt = 60; fclose(pf); }
            unlink("/tmp/nvmtl-drawlog");
            if (cnt < 1 || cnt > 600) cnt = 60; if (delay < 0 || delay > 100000) delay = 0;
            atomic_store(&from, fr + (unsigned)delay); atomic_store(&until, fr + (unsigned)delay + (unsigned)cnt);
            nvlog_diag("drawlog: armed at frame %u - every G-buffer draw of frames %u..%u is logged", fr, fr + (unsigned)delay, fr + (unsigned)delay + (unsigned)cnt);
        }
    }
    if (fr < atomic_load(&from) || fr >= atomic_load(&until)) return;
    nvk_image *c0 = e->_pass.col[0];
    if (!c0 || !e->_pass.col[2] || c0->w < 800) return;
    NVMTLRenderPipelineState *ps = e->_ps; if (!ps) return;
    { static NSMutableSet *seen; static os_unfair_lock sl = OS_UNFAIR_LOCK_INIT;
      id fns[2] = { ps->_descriptor.vertexFunction, ps->_descriptor.fragmentFunction };
      for (int k = 0; k < 2; k++) {
          if (![(id)fns[k] isKindOfClass:[NVMTLFunction class]]) continue;
          NVMTLFunction *fn = (NVMTLFunction *)fns[k]; const uint32_t h = nvmtl_dl_fn(fn); NSNumber *key = @(h);
          os_unfair_lock_lock(&sl); if (!seen) seen = [NSMutableSet new]; const BOOL fresh = ![seen containsObject:key]; if (fresh) [seen addObject:key]; os_unfair_lock_unlock(&sl);
          if (!fresh) continue;
          { NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/nvmtl/fns"];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            if (fn->_air.length) [fn->_air writeToFile:[dir stringByAppendingFormat:@"/%08x.ll", h] atomically:NO encoding:NSUTF8StringEncoding error:nil];
            if (fn->_spirv.length) [fn->_spirv writeToFile:[dir stringByAppendingFormat:@"/%08x.spv", h] atomically:NO]; }
          NSMutableArray *kv = [NSMutableArray array];
          NSArray *keys = [fn->_fc.allKeys sortedArrayUsingComparator:^NSComparisonResult(id x, id y) { return [@([x integerValue]) compare:@([y integerValue])]; }];
          for (id ck in keys) { id v = fn->_fc[ck]; NSString *vs = [v isKindOfClass:[NSArray class]] ? [(NSArray *)v componentsJoinedByString:@","] : [v description];
                                [kv addObject:[NSString stringWithFormat:@"%@=%@", ck, vs]]; }
          NSString *fcs = [kv componentsJoinedByString:@" "];
          const char *u = fcs.UTF8String ?: ""; const size_t ul = strlen(u);
          for (size_t o = 0; o < ul || o == 0; o += 560)
              nvlog_diag("drawlog fn: %s %08x %s air %lu B fc[%lu]%s %.560s", k ? "fs" : "vs", h, fn->_fname.UTF8String ?: "?", (unsigned long)fn->_air.length, (unsigned long)fn->_fc.count, o ? " (cont)" : "", u + o);
      } }
    char line[700]; int n = snprintf(line, sizeof line, "drawlog: f%u e%p d%u c0fmt %u ps %p vs %08x fs %08x |V", fr, (__bridge void *)e, e->_passDraws, c0->fmt, (__bridge void *)ps,
                                     nvmtl_dl_fn(ps->_descriptor.vertexFunction), nvmtl_dl_fn(ps->_descriptor.fragmentFunction));
    for (int k = 0; k < 8 && k < NVMTL_NBUFAT && n < (int)sizeof line - 60; k++) if (e->_vbufAt[k])
        n += snprintf(line + n, sizeof line - n, " %d:%p+%lu#%08x", k, (__bridge void *)e->_vbufAt[k], (unsigned long)e->_vbufOff[k], nvmtl_dl_hash(e->_vbufAt[k], e->_vbufOff[k]));
    n += snprintf(line + n, sizeof line - n, " |F");
    for (int k = 0; k < 8 && k < NVMTL_NBUFAT && n < (int)sizeof line - 60; k++) if (e->_fbufAt[k])
        n += snprintf(line + n, sizeof line - n, " %d:%p+%lu#%08x", k, (__bridge void *)e->_fbufAt[k], (unsigned long)e->_fbufOff[k], nvmtl_dl_hash(e->_fbufAt[k], e->_fbufOff[k]));
    nvlog_diag("%s", line);
}
typedef struct { int32_t draw; uint32_t fs, frame; void *ps, *v6; uint64_t v6off, v7off; uint32_t kind, pad; uint64_t a[5];
                 void *v7, *heap; uint64_t v7size, srcoff, heapOff; uint32_t storage, stride, flags, cpulen; uint8_t cpu[192];
                 uint32_t vsh, sen, sf[6], sb[6], sref[2], swm[2], hasS, semu, dsw, dcmp; } nvmtl_pp_meta;
#define NVMTL_PP_CAP 400
#define NVMTL_PP_PTS 8
#define NVMTL_PP_ROWB (4 * 3 * 224 * 4 + 64 + 256 + 4 * 224 + 4 * 224 * 4)
static _Atomic unsigned g_pp_from = ~0u, g_pp_until; static int g_pp_x[NVMTL_PP_PTS], g_pp_y[NVMTL_PP_PTS], g_pp_n; static uint32_t g_pp_tgt[16]; static int g_pp_ntgt;
static int nvmtl_pp_active(void)
{
    static _Atomic uint64_t nextCheck;
    const unsigned fr = atomic_load_explicit(&nvmtl_flick_frame, memory_order_relaxed);
    const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now >= atomic_load(&nextCheck)) {
        atomic_store(&nextCheck, now + 250000000ull);
        if (access("/tmp/nvmtl-pixprobe", F_OK) == 0) {
            int cnt = 20, delay = 0, n = 0; FILE *pf = fopen("/tmp/nvmtl-pixprobe", "r");
            if (pf) { int np = 0; if (fscanf(pf, "%d %d %d", &cnt, &delay, &np) != 3) cnt = 20;
                      while (n < NVMTL_PP_PTS && n < np && fscanf(pf, "%d %d", &g_pp_x[n], &g_pp_y[n]) == 2) n++;
                      g_pp_ntgt = 0; unsigned th; while (g_pp_ntgt < 16 && fscanf(pf, "%x", &th) == 1) g_pp_tgt[g_pp_ntgt++] = th; fclose(pf); }
            unlink("/tmp/nvmtl-pixprobe"); g_pp_n = n;
            atomic_store(&g_pp_from, fr + (unsigned)delay); atomic_store(&g_pp_until, fr + (unsigned)delay + (unsigned)cnt);
            nvlog_diag("pixprobe: armed at frame %u for frames %u..%u, %d points", fr, fr + (unsigned)delay, fr + (unsigned)delay + (unsigned)cnt, n);
        }
    }
    return g_pp_n && fr >= atomic_load(&g_pp_from) && fr < atomic_load(&g_pp_until);
}
static void nvmtl_pp_take(NVMTLRenderCommandEncoder *e, int32_t drawIdx)
{
    nvk_image *c0 = e->_pass.col[0], *c1 = e->_pass.col[1];
    if (!c0 || !c1 || e->_ppN >= NVMTL_PP_CAP) return;
    if (!e->_ppBuf) {
        nvk_buffer *b = calloc(1, sizeof *b); if (!b) return;
        if (nvmtl_vk_buffer_create((size_t)NVMTL_PP_CAP * NVMTL_PP_ROWB, 1, b) || !b->map) { free(b); return; }
        memset(b->map, 0xEE, (size_t)NVMTL_PP_CAP * NVMTL_PP_ROWB);
        e->_ppBuf = b; e->_ppMeta = [NSMutableData data];
    }
    nvk_buffer *b = (nvk_buffer *)e->_ppBuf; const size_t base = (size_t)e->_ppN * NVMTL_PP_ROWB;
    nvk_image *att[3] = { c0, c1, e->_pass.col[2] };
    for (int k = 0; k < g_pp_n && k < 4; k++) {
        if ((uint32_t)g_pp_y[k] >= c0->h || (uint32_t)g_pp_x[k] + 224 > c0->w) continue;
        for (int a = 0; a < 3; a++) if (att[a] && att[a]->bpp == 4 && att[a]->w == c0->w && att[a]->h == c0->h)
            nvmtl_vk_cmd_copy_image_to_buffer_level_layer(&e->_cb->_c, att[a], (uint32_t)g_pp_x[k], (uint32_t)g_pp_y[k], 224, 1, b,
                                                          base + ((size_t)k * 3 + (size_t)a) * 224 * 4, 224 * 4, 0, 0);
    }
    if ((e->_ppKind == 3 || e->_ppKind == 4) && e->_ppInd)
        nvmtl_vk_cmd_copy_buffer(&e->_cb->_c, (nvk_buffer *)e->_ppInd, (size_t)e->_ppIndOff, b, base + 4 * 3 * 224 * 4, e->_ppKind == 4 ? 20 : 16);
    nvmtl_pp_meta m = { drawIdx, 0, atomic_load(&nvmtl_flick_frame), (__bridge void *)e->_ps, NULL, 0, 0, e->_ppKind, 0,
                        { e->_ppA[0], e->_ppA[1], e->_ppA[2], e->_ppA[3], e->_ppA[4] } };
    if (e->_ps && drawIdx >= 0) { static NSMutableSet *said; static os_unfair_lock sl = OS_UNFAIR_LOCK_INIT; BOOL first = NO;
        os_unfair_lock_lock(&sl); if (!said) said = [NSMutableSet set]; NSValue *key = [NSValue valueWithPointer:(__bridge void *)e->_ps];
        if (![said containsObject:key]) { [said addObject:key]; first = YES; } os_unfair_lock_unlock(&sl);
        if (first) nvlog_diag("pixvd ps %p fs %08x vin_mask 0x%x vin_dyn 0x%x vstride6 %u vstride7 %u vstride8 %u vbuf6 %p+%lu size %llu vbuf7 %p+%lu size %llu |%s", (__bridge void *)e->_ps,
                              nvmtl_dl_fn(e->_ps->_descriptor.fragmentFunction), e->_ps->_p.vin_mask, e->_ps->_p.vin_dyn, e->_vstride[6], e->_vstride[7], e->_vstride[8],
                              (__bridge void *)e->_vbufAt[6], (unsigned long)e->_vbufOff[6], e->_vbufAt[6] ? (unsigned long long)e->_vbufAt[6]->_b.size : 0ull,
                              (__bridge void *)e->_vbufAt[7], (unsigned long)e->_vbufOff[7], e->_vbufAt[7] ? (unsigned long long)e->_vbufAt[7]->_b.size : 0ull,
                              e->_ps->_vdesc.UTF8String ?: ""); }
    if (e->_pass.ds && (e->_pass.ds->fmt == 130 || e->_pass.ds->fmt == 129) && e->_pass.ds->w == c0->w) {
        extern void nvmtl_vk_copy_aspect_override(uint32_t, uint32_t);
        nvmtl_vk_copy_aspect_override(4u, 1u);
        for (int k = 0; k < g_pp_n && k < 4; k++) if ((uint32_t)g_pp_y[k] < c0->h && (uint32_t)g_pp_x[k] + 224 <= c0->w)
            nvmtl_vk_cmd_copy_image_to_buffer_level_layer(&e->_cb->_c, e->_pass.ds, (uint32_t)g_pp_x[k], (uint32_t)g_pp_y[k], 224, 1, b,
                                                          base + 4 * 3 * 224 * 4 + 64 + 256 + (size_t)k * 224, 224, 0, 0);
        nvmtl_vk_copy_aspect_override(2u, 4u);
        for (int k = 0; k < g_pp_n && k < 4; k++) if ((uint32_t)g_pp_y[k] < c0->h && (uint32_t)g_pp_x[k] + 224 <= c0->w)
            nvmtl_vk_cmd_copy_image_to_buffer_level_layer(&e->_cb->_c, e->_pass.ds, (uint32_t)g_pp_x[k], (uint32_t)g_pp_y[k], 224, 1, b,
                                                          base + 4 * 3 * 224 * 4 + 64 + 256 + 4 * 224 + (size_t)k * 224 * 4, 224 * 4, 0, 0);
        nvmtl_vk_copy_aspect_override(0u, 0u);
    }
    if (e->_ps) { NVMTLDepthStencilState *ds = e->_ds; m.vsh = nvmtl_dl_fn(e->_ps->_descriptor.vertexFunction); m.hasS = e->_ps->_p.has_stencil; m.semu = e->_cb->_c.semu_layout != NULL;
        m.sen = ds ? (uint32_t)ds->_stencil : 0; m.dsw = ds ? (uint32_t)ds->_write : 0; m.dcmp = ds ? (uint32_t)ds->_compare : 7;
        if (ds) { memcpy(m.sf, ds->_sf, sizeof m.sf); memcpy(m.sb, ds->_sb, sizeof m.sb); }
        m.sref[0] = e->_cb->_c.st_ref[0]; m.sref[1] = e->_cb->_c.st_ref[1]; m.swm[0] = e->_cb->_c.st_wmask[0]; m.swm[1] = e->_cb->_c.st_wmask[1]; }
    static int vbi = -1; if (vbi < 0) { const char *ev = getenv("NVMTL_PP_VB"); vbi = ev ? atoi(ev) : 6; if (vbi < 0 || vbi >= NVMTL_NBUFAT || vbi >= NVMTL_NVIN) vbi = 6; }
    NVMTLBuffer *vb = e->_vbufAt[vbi];
    if (vb && e->_ps && drawIdx >= 0) {
        const uint32_t st = (e->_ps->_p.vin_dyn & (1u << vbi)) ? e->_vstride[vbi] : e->_ps->_p.vin_stride[vbi];
        const uint64_t inst = e->_ppKind == 2 ? e->_ppA[3] : e->_ppKind == 1 ? e->_ppA[3] : 0, cnt = e->_ppKind == 2 ? e->_ppA[1] : e->_ppKind == 1 ? e->_ppA[2] : 1;
        const uint64_t so = (uint64_t)e->_vbufOff[vbi] + inst * st;
        uint64_t len = st ? MIN((uint64_t)192, (cnt ? cnt : 1) * st) : 64;
        m.v7 = (__bridge void *)vb; m.heap = (__bridge void *)vb->_heap; m.v7size = vb->_b.size; m.srcoff = so; m.heapOff = vb->_heapOffset;
        m.storage = (uint32_t)vb->_storage; m.stride = st; m.flags = (vb->_b.map ? 1u : 0u) | (vb->_shadow.map ? 2u : 0u) | (vb->_aliased ? 4u : 0u) | (vb->_subHeap ? 8u : 0u) | (vb->_hostPtr ? 16u : 0u);
        if (so + len <= vb->_b.size) {
            nvmtl_vk_cmd_copy_buffer(&e->_cb->_c, &vb->_b, (size_t)so, b, base + 4 * 3 * 224 * 4 + 64, (size_t)len);
            const uint8_t *cpu = (const uint8_t *)nvmtl_buf_cpu(vb);
            if (cpu) { memcpy(m.cpu, cpu + so, (size_t)len); m.cpulen = (uint32_t)len; }
        } else m.flags |= 0x100u;
    }
    if (e->_ps) m.fs = nvmtl_dl_fn(e->_ps->_descriptor.fragmentFunction);
    if (e->_vbufAt[6]) { m.v6 = (__bridge void *)e->_vbufAt[6]; m.v6off = e->_vbufOff[6]; }
    if (e->_vbufAt[7]) m.v7off = e->_vbufOff[7];
    [e->_ppMeta appendBytes:&m length:sizeof m]; e->_ppN++;
}
static void nvmtl_pp_flush(NVMTLRenderCommandEncoder *e)
{
    if (!e->_ppBuf) return;
    nvk_buffer *b = (nvk_buffer *)e->_ppBuf; NSData *meta = e->_ppMeta; const uint32_t n = e->_ppN; void *enc = (__bridge void *)e;
    e->_ppBuf = NULL; e->_ppMeta = nil; e->_ppN = 0;
    [e->_cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        const nvmtl_pp_meta *mm = meta.bytes;
        char dir[512]; snprintf(dir, sizeof dir, "%s/Library/Logs/nvmtl/pp-%d", getenv("HOME") ?: "/tmp", (int)getpid()); mkdir(dir, 0755);
        char path[600]; snprintf(path, sizeof path, "%s/f%06u-e%p.bin", dir, n ? mm[0].frame : 0, enc);
        FILE *fp = fopen(path, "wb");
        if (fp) { fwrite(&n, 4, 1, fp); fwrite(mm, sizeof *mm, n, fp); fwrite(b->map, NVMTL_PP_ROWB, n, fp); fclose(fp); }
        for (uint32_t k = 0; k < n; k++)
            nvlog_diag("pix f%u e%p k%u before-draw %d fs %08x ps %p mesh %p+%llu/%llu kind %u a %llu %llu %llu %llu %llu", mm[k].frame, enc, k, mm[k].draw, mm[k].fs, mm[k].ps, mm[k].v6, (unsigned long long)mm[k].v6off, (unsigned long long)mm[k].v7off,
                       mm[k].kind, (unsigned long long)mm[k].a[0], (unsigned long long)mm[k].a[1], (unsigned long long)mm[k].a[2], (unsigned long long)mm[k].a[3], (unsigned long long)mm[k].a[4]);
        for (uint32_t k = 0; k < n; k++) if (mm[k].v7 && mm[k].draw >= 0) {
            const uint8_t *g = (const uint8_t *)b->map + (size_t)k * NVMTL_PP_ROWB + 4 * 3 * 224 * 4 + 64;
            NVMTLBuffer *vb = (__bridge NVMTLBuffer *)mm[k].v7; const uint8_t *now = mm[k].cpulen ? (const uint8_t *)nvmtl_buf_cpu(vb) : NULL;
            const uint32_t L = mm[k].cpulen;
            const int gEq = L && !memcmp(g, mm[k].cpu, L), nEq = L && now && !memcmp(now + mm[k].srcoff, mm[k].cpu, L);
            char hg[200], hc[200], hn[200]; int o1 = 0, o2 = 0, o3 = 0;
            for (uint32_t j = 0; j < 48 && j < (L ? L : 48); j++) { o1 += snprintf(hg + o1, sizeof hg - o1, "%02x", g[j]); o2 += snprintf(hc + o2, sizeof hc - o2, "%02x", mm[k].cpu[j]);
                                                                  o3 += snprintf(hn + o3, sizeof hn - o3, "%02x", now ? now[mm[k].srcoff + j] : 0); }
            nvlog_diag("pixvb f%u k%u d%d vb %p size %llu storage %u heap %p+%llu stride %u srcoff %llu flags 0x%x len %u | gpu==encode %d done==encode %d | gpu %s | encode %s | done %s",
                       mm[k].frame, k, mm[k].draw, mm[k].v7, (unsigned long long)mm[k].v7size, mm[k].storage, mm[k].heap, (unsigned long long)mm[k].heapOff, mm[k].stride,
                       (unsigned long long)mm[k].srcoff, mm[k].flags, L, gEq, nEq, hg, hc, hn);
        }
        nvmtl_vk_buffer_destroy(b); free(b);
    }];
}
typedef struct { uint64_t va, off; int level, from, fromOff; uint32_t len; void *buf; unsigned long storage; size_t size; uint8_t cpu[64]; BOOL cpuOk; } nvmtl_ab_region;
static NVMTLBuffer *nvmtl_ab_find(NSArray *all, uint64_t va, uint64_t *off) {
    if (va < 0x100000ull) return nil;
    for (NVMTLBuffer *b in all) { const uint64_t a = nvmtl_vk_buffer_address(&b->_b); if (a && va >= a && va < a + b->_b.size) { *off = va - a; return b; } }
    return nil;
}
static void nvmtl_ab_dump(NVMTLRenderCommandEncoder *e, uint32_t fsHash)
{
    NVMTLBuffer *fb = e->_fbufAt[2]; if (!fb || !fb->_b.map) return;
    NSArray *all; os_unfair_lock_lock(&g_ab_lock); all = g_ab_bufs.allObjects; os_unfair_lock_unlock(&g_ab_lock); if (!all) all = @[];
    nvmtl_ab_region r[24]; int n = 0;
    r[n] = (nvmtl_ab_region){ nvmtl_vk_buffer_address(&fb->_b) + e->_fbufOff[2], e->_fbufOff[2], 0, -1, 0, 64, (__bridge void *)fb, fb.storageMode, fb->_b.size, {0}, NO };
    if (e->_fbufOff[2] + 64 <= fb->_b.size) { memcpy(r[n].cpu, (uint8_t *)fb->_b.map + e->_fbufOff[2], 64); r[n].cpuOk = YES; } n++;
    if (e->_fbufOff[2] + 128 <= fb->_b.size) {
        r[n] = (nvmtl_ab_region){ r[0].va + 64, e->_fbufOff[2] + 64, 0, -1, 64, 64, (__bridge void *)fb, fb.storageMode, fb->_b.size, {0}, YES };
        memcpy(r[n].cpu, (uint8_t *)fb->_b.map + e->_fbufOff[2] + 64, 64); n++; }
    NSMutableArray *keep = [NSMutableArray arrayWithObject:fb];
    for (int lvl = 0; lvl < 2; lvl++) {
        const int upto = n;
        for (int i = 0; i < upto; i++) {
            if (r[i].level != lvl || !r[i].cpuOk) continue;
            for (int q = 0; q < 8 && n < 24; q++) {
                uint64_t va; memcpy(&va, r[i].cpu + q * 8, 8); uint64_t off = 0;
                NVMTLBuffer *b = nvmtl_ab_find(all, va, &off); if (!b) continue;
                nvmtl_ab_region *x = &r[n]; *x = (nvmtl_ab_region){ va, off, lvl + 1, i, q * 8, (uint32_t)MIN((uint64_t)64, b->_b.size - off), (__bridge void *)b, b.storageMode, b->_b.size, {0}, NO };
                if (b->_b.map) { memcpy(x->cpu, (uint8_t *)b->_b.map + off, x->len); x->cpuOk = YES; }
                [keep addObject:b]; n++;
            }
        }
    }
    nvk_buffer *hb = calloc(1, sizeof *hb); if (!hb) return;
    if (nvmtl_vk_buffer_create(24 * 64, 1, hb) || !hb->map) { free(hb); return; }
    memset(hb->map, 0xCD, 24 * 64);
    for (int i = 0; i < n; i++) { NVMTLBuffer *b = (__bridge NVMTLBuffer *)r[i].buf; nvmtl_vk_cmd_copy_buffer(&e->_cb->_c, &b->_b, r[i].off, hb, (size_t)i * 64, r[i].len); }
    nvmtl_ab_region *rc = malloc(sizeof(nvmtl_ab_region) * (size_t)n); if (!rc) { nvmtl_vk_buffer_destroy(hb); free(hb); return; }
    memcpy(rc, r, sizeof(nvmtl_ab_region) * (size_t)n);
    const unsigned fr = atomic_load(&nvmtl_flick_frame); const uint32_t d = e->_passDraws; void *mesh = (__bridge void *)e->_vbufAt[6]; const uint64_t moff = e->_vbufOff[6]; const int nn = n;
    [e->_cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        (void)keep;
        for (int i = 0; i < nn; i++) {
            const uint8_t *g = (const uint8_t *)hb->map + (size_t)i * 64; char cx[140] = "-", gx[140]; int gz = 1, cz = 1;
            for (uint32_t k = 0; k < rc[i].len; k++) { if (g[k]) gz = 0; if (rc[i].cpuOk && rc[i].cpu[k]) cz = 0; }
            for (uint32_t k = 0; k < 32 && k < rc[i].len; k++) snprintf(gx + 2 * k, 3, "%02x", g[k]);
            if (rc[i].cpuOk) for (uint32_t k = 0; k < 32 && k < rc[i].len; k++) snprintf(cx + 2 * k, 3, "%02x", rc[i].cpu[k]);
            NVMTLBuffer *lb = (__bridge NVMTLBuffer *)rc[i].buf; char lx[140] = "-"; int late = 0, lateNZ = 0;
            if (lb->_b.map && rc[i].off + rc[i].len <= lb->_b.size) {
                const uint8_t *lm = (const uint8_t *)lb->_b.map + rc[i].off;
                for (uint32_t k = 0; k < 32 && k < rc[i].len; k++) snprintf(lx + 2 * k, 3, "%02x", lm[k]);
                for (uint32_t k = 0; k < rc[i].len; k += 8) { uint64_t gv, lv; memcpy(&gv, g + k, 8); memcpy(&lv, lm + k, 8); if (gv != lv) { late = 1; if (!gv && lv) lateNZ++; } }
            }
            nvlog_diag("abdump f%u d%u fs %08x mesh %p+%llu | r%d L%d from r%d+%d -> buf %p storage %lu size %zu +%llu | gpu%s %s | cpu%s %s%s | after%s %s",
                       fr, d, fsHash, mesh, (unsigned long long)moff, i, rc[i].level, rc[i].from, rc[i].fromOff, rc[i].buf, rc[i].storage, rc[i].size, (unsigned long long)rc[i].off,
                       gz ? "(ZERO)" : "", gx, cz ? "(ZERO)" : "", cx, (rc[i].cpuOk && memcmp(rc[i].cpu, g, rc[i].len)) ? " DIFFERS" : "",
                       late ? (lateNZ ? "(LATE: zero on the GPU, written after)" : "(CHANGED after the GPU read)") : "", lx);
        }
        free(rc); nvmtl_vk_buffer_destroy(hb); free(hb);
    }];
}
id nvmtl_resid_resource(uint64_t token);
static void nvmtl_decal_dump(NVMTLRenderCommandEncoder *e, uint32_t fsHash)
{
    NVMTLBuffer *fb = e->_fbufAt[2]; if (!fb || !fb->_b.map || e->_fbufOff[2] + 64 > fb->_b.size) return;
    NSArray *all; os_unfair_lock_lock(&g_ab_lock); all = g_ab_bufs.allObjects; os_unfair_lock_unlock(&g_ab_lock); if (!all) all = @[];
    const uint8_t *ab = (const uint8_t *)fb->_b.map + e->_fbufOff[2];
    uint64_t p0 = 0, p32 = 0, p56 = 0, p64 = 0, cb3 = 0, cb4 = 0, cb1 = 0, p8 = 0, p104 = 0, c5 = 0, maskTid = 0, noiseTid = 0, did = 0, nid = 0, rec = 0; uint32_t base = 0, maskIdx = 0, noiseIdx = 0;
    memcpy(&p0, ab, 8); memcpy(&p32, ab + 32, 8); memcpy(&p56, ab + 56, 8); memcpy(&p64, ab + 64, 8); memcpy(&p8, ab + 8, 8); if (e->_fbufOff[2] + 112 <= fb->_b.size) memcpy(&p104, ab + 104, 8);
    NSMutableArray *keep = [NSMutableArray arrayWithObject:fb];
    uint64_t o; NVMTLBuffer *b;
#define NVMTL_DD_RD(va, dst, n) do { b = nvmtl_ab_find(all, (va), &o); if (b && b->_b.map && o + (n) <= b->_b.size) memcpy(&(dst), (const uint8_t *)b->_b.map + o, (n)); } while (0)
    NVMTL_DD_RD(p0 + 3 * 24, cb3, 8); NVMTL_DD_RD(p32 + 4 * 24, cb4, 8); NVMTL_DD_RD(p56 + 24 + 8, did, 8); NVMTL_DD_RD(p56 + 13 * 24, rec, 8); NVMTL_DD_RD(p64 + 20 * 24 + 8, nid, 8); NVMTL_DD_RD(p0 + 1 * 24, cb1, 8); NVMTL_DD_RD(p8, c5, 8); NVMTL_DD_RD(c5, maskIdx, 4); NVMTL_DD_RD(c5 + 192, noiseIdx, 4);
    NVMTL_DD_RD(p104 + (uint64_t)maskIdx * 24 + 8, maskTid, 8); NVMTL_DD_RD(p104 + (uint64_t)noiseIdx * 24 + 8, noiseTid, 8);
    NVMTL_DD_RD(cb3 + 16, base, 4);
#undef NVMTL_DD_RD
    enum { DD_MAT = 0, DD_DESC = 64, DD_BASE = 96, DD_REC = 128, DD_DEPTH = 512, DD_ROW = 224 * 8, DD_NRM = 512 + 4 * 224 * 8, DD_NDESC = DD_NRM + 4 * 224 * 8, DD_VS = DD_NDESC + 64, DD_DA = DD_VS + 512, DD_UNI = DD_DA + 64, DD_C5 = DD_UNI + 64, DD_HEAP = DD_C5 + 256, DD_STEN = DD_HEAP + 64, DD_SIZE = DD_STEN + 4 * 224 };
    nvk_buffer *hb = calloc(1, sizeof *hb); if (!hb) return;
    if (nvmtl_vk_buffer_create(DD_SIZE, 1, hb) || !hb->map) { free(hb); return; }
    memset(hb->map, 0xCD, DD_SIZE);
    uint8_t cpuMat[64] = {0}, cpuDesc[24] = {0}; int cm = 0, cd = 0;
    static uint32_t hidx[2] = { 0, 0 }; static int hset = 0;
    if (!hset) { const char *ev = getenv("NVMTL_DD_HEAPIDX"); if (ev) sscanf(ev, "%u,%u", &hidx[0], &hidx[1]); hset = 1; }
    uint64_t cpuHeap[2] = { 0, 0 };
    for (int k = 0; k < 2; k++) { b = nvmtl_ab_find(all, p104 + (uint64_t)hidx[k] * 24, &o); if (b && o + 24 <= b->_b.size) { [keep addObject:b];
        nvmtl_vk_cmd_copy_buffer(&e->_cb->_c, &b->_b, (size_t)o, hb, DD_HEAP + k * 32, 24); if (b->_b.map) memcpy(&cpuHeap[k], (const uint8_t *)b->_b.map + o + 8, 8); } }
    const uint64_t ch0 = cpuHeap[0], ch1 = cpuHeap[1];
    struct { uint64_t va; uint32_t len, dst; } w[7] = { { c5, 256, DD_C5 }, { cb4 + 1104, 64, DD_MAT }, { p56 + 24, 24, DD_DESC }, { cb3 + 16, 4, DD_BASE }, { rec + (uint64_t)base * 160, 320, DD_REC }, { p64 + 20 * 24, 24, DD_NDESC },
                                                         { cb1 + 448, 384, DD_VS } };
    for (int k = 4; k <= 5; k++) { NVMTLBuffer *vb = e->_vbufAt[k]; if (vb && e->_vbufOff[k] + 20 <= vb->_b.size) { [keep addObject:vb];
        nvmtl_vk_cmd_copy_buffer(&e->_cb->_c, &vb->_b, (size_t)e->_vbufOff[k], hb, k == 4 ? DD_DA : DD_UNI, (size_t)MIN((uint64_t)64, vb->_b.size - e->_vbufOff[k])); } }
    const uint64_t realBase = e->_ppKind == 2 ? e->_ppA[3] : e->_ppKind == 1 ? e->_ppA[3] : 0, realInst = e->_ppKind == 2 ? e->_ppA[1] : e->_ppKind == 1 ? e->_ppA[2] : 0;
    for (int i = 0; i < 7; i++) { b = nvmtl_ab_find(all, w[i].va, &o); if (!b || o + w[i].len > b->_b.size) continue; [keep addObject:b];
        nvmtl_vk_cmd_copy_buffer(&e->_cb->_c, &b->_b, (size_t)o, hb, w[i].dst, w[i].len);
        if (b->_b.map && i == 0) { memcpy(cpuMat, (const uint8_t *)b->_b.map + o, 64); cm = 1; }
        if (b->_b.map && i == 1) { memcpy(cpuDesc, (const uint8_t *)b->_b.map + o, 24); cd = 1; } }
    id dob = nvmtl_resid_resource(did); NVMTLTexture *dt = [dob isKindOfClass:[NVMTLTexture class]] ? (NVMTLTexture *)dob : nil;
    nvk_image *dim = dt ? [dt nvi] : NULL; int isAtt = dim && e->_pass.ds == dim; uint32_t dbpp = dim ? (dim->bpp ? dim->bpp : 4) : 0;
    if (dim && dbpp <= 8) { [keep addObject:dt];
        for (int k = 0; k < g_pp_n && k < 4; k++) if ((uint32_t)g_pp_y[k] < dim->h && (uint32_t)g_pp_x[k] + 224 <= dim->w)
            nvmtl_vk_cmd_copy_image_to_buffer_level_layer(&e->_cb->_c, dim, (uint32_t)g_pp_x[k], (uint32_t)g_pp_y[k], 224, 1, hb, DD_DEPTH + (size_t)k * DD_ROW, 224 * dbpp, 0, 0);
        if (dim->fmt == 130 || dim->fmt == 129 || dim->fmt == 128) { extern void nvmtl_vk_copy_aspect_override(uint32_t, uint32_t);
            nvmtl_vk_copy_aspect_override(4u, 1u);
            for (int k = 0; k < g_pp_n && k < 4; k++) if ((uint32_t)g_pp_y[k] < dim->h && (uint32_t)g_pp_x[k] + 224 <= dim->w)
                nvmtl_vk_cmd_copy_image_to_buffer_level_layer(&e->_cb->_c, dim, (uint32_t)g_pp_x[k], (uint32_t)g_pp_y[k], 224, 1, hb, DD_STEN + (size_t)k * 224, 224, 0, 0);
            nvmtl_vk_copy_aspect_override(0u, 0u); } }
    NSData *cpuMatD = cm ? [NSData dataWithBytes:cpuMat length:64] : nil, *cpuDescD = cd ? [NSData dataWithBytes:cpuDesc length:24] : nil;
    id nob = nvmtl_resid_resource(nid); NVMTLTexture *nt = [nob isKindOfClass:[NVMTLTexture class]] ? (NVMTLTexture *)nob : nil;
    nvk_image *nim = nt ? [nt nvi] : NULL; int nAtt = -1; for (int a = 0; a < NVMTL_NCOL && nim; a++) if (e->_pass.col[a] == nim) nAtt = a;
    const uint32_t nbpp = nim ? (nim->bpp ? nim->bpp : 4) : 0;
    if (nim && nbpp <= 8) { [keep addObject:nt];
        for (int k = 0; k < g_pp_n && k < 4; k++) if ((uint32_t)g_pp_y[k] < nim->h && (uint32_t)g_pp_x[k] + 224 <= nim->w)
            nvmtl_vk_cmd_copy_image_to_buffer_level_layer(&e->_cb->_c, nim, (uint32_t)g_pp_x[k], (uint32_t)g_pp_y[k], 224, 1, hb, DD_NRM + (size_t)k * DD_ROW, 224 * nbpp, 0, 0); }
    const uint32_t nw = nim ? nim->w : 0, nh = nim ? nim->h : 0, nfmt = nim ? nim->fmt : 0; const unsigned nborn = nt ? nt->_hBornFrame : 0; void *nimg = nim ? nim->img : NULL;
    NSString *(^tdesc)(uint64_t) = ^NSString *(uint64_t tid) { id o = nvmtl_resid_resource(tid); if (![o isKindOfClass:[NVMTLTexture class]]) return [NSString stringWithFormat:@"obj %@", o ? NSStringFromClass([o class]) : @"nil"];
        NVMTLTexture *t = o; nvk_image *im = [t nvi];
        return [NSString stringWithFormat:@"tex %p img %p %ux%u layers %u mips %u vkfmt %u born f%u view %d base L%u", (__bridge void *)t, im ? im->img : NULL, im ? im->w : 0, im ? im->h : 0, im ? im->layers : 0, im ? im->mips : 0, im ? im->fmt : 0, t->_hBornFrame, t->_parent != nil || t->_viewParent != nil, t->_baseLevel]; };
    NSString *mdesc = tdesc(maskTid), *ndesc = tdesc(noiseTid);
    { NVMTLDepthStencilState *ds = e->_ds; const unsigned frs = atomic_load(&nvmtl_flick_frame);
      nvlog_diag("decal-state f%u d%u cull %d vp %s %.1f %.1f %.1f %.1f %.3f %.3f sc %s %u %u %u %u | ds %p write %d compare %d stencil %d sf %u %u %u %u %u %u sb %u %u %u %u %u %u | ref %u %u wmask %u %u | fsamp %lu vsamp %lu variants %lu | passDraws %u load 0x%x",
                 frs, e->_passDraws, e->_cull, e->_hasVP ? "set" : "unset", e->_vp[0], e->_vp[1], e->_vp[2], e->_vp[3], e->_vp[4], e->_vp[5], e->_hasSC ? "set" : "unset", e->_sc[0], e->_sc[1], e->_sc[2], e->_sc[3],
                 (__bridge void *)ds, ds ? ds->_write : -1, ds ? ds->_compare : -1, ds ? ds->_stencil : -1, ds ? ds->_sf[0] : 0, ds ? ds->_sf[1] : 0, ds ? ds->_sf[2] : 0, ds ? ds->_sf[3] : 0, ds ? ds->_sf[4] : 0, ds ? ds->_sf[5] : 0,
                 ds ? ds->_sb[0] : 0, ds ? ds->_sb[1] : 0, ds ? ds->_sb[2] : 0, ds ? ds->_sb[3] : 0, ds ? ds->_sb[4] : 0, ds ? ds->_sb[5] : 0,
                 e->_cb->_c.st_ref[0], e->_cb->_c.st_ref[1], e->_cb->_c.st_wmask[0], e->_cb->_c.st_wmask[1],
                 (unsigned long)e->_fragmentSamplers.count, (unsigned long)e->_vertexSamplers.count, (unsigned long)(e->_ps ? e->_ps->_samplerVariants.count : 0), e->_passDraws, e->_load); }
    const unsigned fr = atomic_load(&nvmtl_flick_frame); const uint32_t d = e->_passDraws;
    const uint32_t dw = dim ? dim->w : 0, dh = dim ? dim->h : 0, dfmt = dim ? dim->fmt : 0; const unsigned born = dt ? dt->_hBornFrame : 0;
    void *dimg = dim ? dim->img : NULL, *att = e->_pass.ds ? e->_pass.ds->img : NULL;
    [e->_cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        (void)keep; const uint8_t *g = (const uint8_t *)hb->map;
        float m[16]; memcpy(m, g + DD_MAT, 64); uint32_t gb; memcpy(&gb, g + DD_BASE, 4); float r[16]; memcpy(r, g + DD_REC, 64);
        uint64_t gid; memcpy(&gid, g + DD_DESC + 8, 8);
        char ds[4][96]; for (int k = 0; k < 4; k++) { double mn = 1e30, mx = -1e30, sum = 0; int nn = 0, cc = 0;
            for (int x = 0; x < 224 && dbpp; x++) { float v; memcpy(&v, g + DD_DEPTH + k * DD_ROW + x * dbpp, 4); uint32_t raw; memcpy(&raw, &v, 4); if (raw == 0xCDCDCDCDu) { cc++; continue; }
                if (v < mn) mn = v; if (v > mx) mx = v; sum += v; nn++; }
            snprintf(ds[k], sizeof ds[k], "row%d n%d min %.6f max %.6f mean %.6f%s", k, nn, nn ? mn : 0, nn ? mx : 0, nn ? sum / nn : 0, cc ? " (uncopied)" : ""); }
        { char path[600]; snprintf(path, sizeof path, "%s/Library/Logs/nvmtl/pp-%d/dd-f%06u-d%03u.bin", getenv("HOME") ?: "/tmp", (int)getpid(), fr, d);
          FILE *fp = fopen(path, "wb"); if (fp) { fwrite(g, 1, DD_SIZE, fp); fclose(fp); } }
        { uint32_t da[5]; memcpy(da, g + DD_DA, 20); uint16_t it; memcpy(&it, g + DD_UNI, 2); float vp[16]; memcpy(vp, g + DD_VS, 64); int32_t cam[3]; memcpy(cam, g + DD_VS + 160, 12);
          float pl[4]; memcpy(pl, g + DD_VS + 352, 16);
          nvlog_diag("decal-vs f%u d%u realBase %llu realInst %llu | DrawArgs %u %d %u %u %u index_type %u%s | cam %d %d %d | plane %.4g %.4g %.4g %.4g | vp0 %.4g %.4g %.4g %.4g", fr, d,
                     (unsigned long long)realBase, (unsigned long long)realInst, da[0], (int)da[1], da[2], da[3], da[4], it,
                     ((it == 0 ? da[3] : da[4]) != (uint32_t)realBase) ? " BASE-MISMATCH" : "", cam[0], cam[1], cam[2], pl[0], pl[1], pl[2], pl[3], vp[0], vp[1], vp[2], vp[3]); }
        { uint32_t gm, gn; memcpy(&gm, g + DD_C5, 4); memcpy(&gn, g + DD_C5 + 192, 4); float fade; memcpy(&fade, g + DD_C5 + 208, 4);
          uint64_t gh[2]; memcpy(&gh[0], g + DD_HEAP + 8, 8); memcpy(&gh[1], g + DD_HEAP + 32 + 8, 8);
          NSString *(^td)(uint64_t) = ^NSString *(uint64_t tid) { id o2 = nvmtl_resid_resource(tid); if (![o2 isKindOfClass:[NVMTLTexture class]]) return [NSString stringWithFormat:@"obj %@", o2 ? NSStringFromClass([o2 class]) : @"nil"];
              NVMTLTexture *t = o2; nvk_image *im = [t nvi];
              return [NSString stringWithFormat:@"tex %p img %p %ux%u layers %u mips %u vkfmt %u born f%u resid-mips %lu", (__bridge void *)t, im ? im->img : NULL, im ? im->w : 0, im ? im->h : 0, im ? im->layers : 0, im ? im->mips : 0, im ? im->fmt : 0, t->_hBornFrame, (unsigned long)t.mipmapLevelCount]; };
          { char sh[4][64]; for (int k = 0; k < 4; k++) { int hist[8] = {0}; const uint8_t *sr = g + DD_STEN + k * 224; int cdc = 0;
                for (int x = 0; x < 224; x++) { if (sr[x] == 0xCD) cdc++; uint8_t v = sr[x] & 31; hist[v > 11 ? 7 : v < 6 ? v : 6]++; }
                snprintf(sh[k], sizeof sh[k], "r%d[0..5:%d %d %d %d %d %d 6-11:%d >11:%d cd%d]", k, hist[0], hist[1], hist[2], hist[3], hist[4], hist[5], hist[6], hist[7], cdc); }
            nvlog_diag("decal-sten f%u d%u %s %s %s %s", fr, d, sh[0], sh[1], sh[2], sh[3]); }
          nvlog_diag("decal-heap f%u d%u slot%u gpu 0x%llx cpu-at-encode 0x%llx %s | slot%u gpu 0x%llx cpu-at-encode 0x%llx %s", fr, d, hidx[0], (unsigned long long)gh[0], (unsigned long long)ch0, td(gh[0]).UTF8String,
                     hidx[1], (unsigned long long)gh[1], (unsigned long long)ch1, td(gh[1]).UTF8String);
          nvlog_diag("decal-tex f%u d%u maskIdx cpu %u gpu %u tid 0x%llx %s | noiseIdx cpu %u gpu %u tid 0x%llx %s | fade %.4g", fr, d, maskIdx, gm, (unsigned long long)maskTid, mdesc.UTF8String,
                     noiseIdx, gn, (unsigned long long)noiseTid, ndesc.UTF8String, fade); }
        nvlog_diag("decal-nrm f%u d%u normalId 0x%llx tex %p img %p %ux%u vkfmt %u bpp %u born f%u pass-attachment %d", fr, d, (unsigned long long)nid, (__bridge void *)nt, nimg, nw, nh, nfmt, nbpp, nborn, nAtt);
        nvlog_diag("decal f%u d%u fs %08x | base cpu %u gpu %u | depthId cpu 0x%llx gpu 0x%llx%s tex %p img %p %ux%u vkfmt %u bpp %u born f%u %s att %p | mat%s %.4g %.4g %.4g %.4g / %.4g %.4g %.4g %.4g / %.4g %.4g %.4g %.4g / %.4g %.4g %.4g %.4g | rec %.4g %.4g %.4g %.4g %.4g %.4g %.4g %.4g | %s | %s | %s | %s",
                   fr, d, fsHash, base, gb, (unsigned long long)did, (unsigned long long)gid, cpuDescD && memcmp(cpuDescD.bytes, g + DD_DESC, 24) ? " DESC-DIFFERS" : "", (__bridge void *)dt, dimg, dw, dh, dfmt, dbpp, born,
                   isAtt ? "IS-ATTACHMENT" : "not-attachment", att, cpuMatD && memcmp(cpuMatD.bytes, m, 64) ? " DIFFERS" : "",
                   m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12], m[13], m[14], m[15],
                   r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], ds[0], ds[1], ds[2], ds[3]);
        nvmtl_vk_buffer_destroy(hb); free(hb);
    }];
}
static BOOL nvmtl_skipfs(NVMTLRenderPipelineState *ps)
{
    static _Atomic uint64_t nextCheck; static struct { uint32_t h; unsigned from, to; } rule[8]; static _Atomic int nrule;
    const unsigned fr = atomic_load_explicit(&nvmtl_flick_frame, memory_order_relaxed);
    const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now >= atomic_load(&nextCheck)) {
        atomic_store(&nextCheck, now + 250000000ull);
        if (access("/tmp/nvmtl-skipfs", F_OK) == 0) {
            FILE *pf = fopen("/tmp/nvmtl-skipfs", "r"); int n = 0;
            if (pf) { unsigned h, a, b; while (n < 8 && fscanf(pf, "%x %u %u", &h, &a, &b) == 3) { rule[n].h = h; rule[n].from = fr + a; rule[n].to = fr + b;
                          nvlog_diag("skipfs: draws with fragment shader %08x are SKIPPED in frames %u..%u", h, fr + a, fr + b); n++; } fclose(pf); }
            unlink("/tmp/nvmtl-skipfs"); atomic_store(&nrule, n);
        }
    }
    const int n = atomic_load(&nrule); if (!n) return NO;
    uint32_t h = 0; BOOL have = NO;
    for (int k = 0; k < n; k++) {
        if (fr < rule[k].from || fr > rule[k].to) continue;
        if (!have) { h = nvmtl_dl_fn(ps->_descriptor.fragmentFunction); have = YES; }
        if (h == rule[k].h) return YES;
    }
    return NO;
}
- (BOOL)nvmtlBindSamplerPipeline {
    if (!_ps) return NO;
    if (nvmtl_skipfs(_ps)) return NO;
    { unsigned fr; if (nvmtl_census_on(&fr)) {
        int ncol = 0; for (int ci = 0; ci < NVMTL_NCOL; ci++) if (_pass.col[ci]) ncol++;
        char line[240];
        snprintf(line, sizeof line, "R f%u e%p d%u fs %08x vs %08x mesh %p+%llu/%llu c0 %u n%d w%u\n", fr, (__bridge void *)self, _passDraws,
                 nvmtl_dl_fn(_ps->_descriptor.fragmentFunction), nvmtl_dl_fn(_ps->_descriptor.vertexFunction),
                 (__bridge void *)_vbufAt[6], (unsigned long long)_vbufOff[6], (unsigned long long)_vbufOff[7],
                 _pass.col[0] ? _pass.col[0]->fmt : 0u, ncol, _pass.col[0] ? _pass.col[0]->w : (_pass.ds ? _pass.ds->w : 0u));
        nvmtl_census_line(line); } }
    if (_begun && !_visActive && _pass.col[0] && _pass.col[2] && _pass.col[0]->fmt == 58 && _pass.col[0]->w >= 800 && nvmtl_pp_active()) {
        const uint32_t h = nvmtl_dl_fn(_ps->_descriptor.fragmentFunction); BOOL tgt = g_pp_ntgt == 0;
        for (int k = 0; k < g_pp_ntgt; k++) if (g_pp_tgt[k] == h) tgt = YES;
        if (tgt || _ppAfter) {
            nvmtl_vk_cmd_end_render(&_cb->_c);
            nvmtl_pp_take(self, tgt ? (int32_t)_passDraws : -2);
            if (tgt && g_pp_ntgt) { static int dd = -1; if (dd < 0) { const char *ev = getenv("NVMTL_PP_DECAL"); dd = ev && ev[0] == '1'; }
                if (dd) nvmtl_decal_dump(self, h); else nvmtl_ab_dump(self, h); }
            _ppAfter = tgt;
            if (![self nvmtlBeginPassLoad:NVMTL_LOAD_ALL]) { nvlog("pixprobe: pass restart FAILED - this draw is skipped"); return NO; }
            if (_hasVP) nvmtl_vk_cmd_set_viewport(&_cb->_c, _vp[0], _vp[1], _vp[2], _vp[3], _vp[4], _vp[5]);
            if (_hasSC) nvmtl_vk_cmd_set_scissor(&_cb->_c, (int32_t)_sc[0], (int32_t)_sc[1], _sc[2], _sc[3]);
        }
    }
    NVMTLRenderPipelineState *selected=_ps;
    if (_vertexSamplers.count || _fragmentSamplers.count) {
        selected=[self nvmtlSamplerPipeline];
        if (!selected) return NO;
    }
    if(!_cb->_resources)_cb->_resources=[NVMTLResSet new];[_cb->_resources addObject:selected];
    nvmtl_vk_cmd_bind_pipeline(&_cb->_c,&selected->_p);
    nvmtl_bind_embedded(_cb, NVMTL_SET_VERTEX,   (NVMTLFunction *)_ps->_descriptor.vertexFunction,   _vbufAt, _vbufOff);
    nvmtl_bind_embedded(_cb, NVMTL_SET_FRAGMENT, (NVMTLFunction *)_ps->_descriptor.fragmentFunction, _fbufAt, _fbufOff);
    if (nvmtl_probe_armed()) {
        static __thread char nm[160];
        snprintf(nm, sizeof nm, "render %s | vs %s | fs %s", _ps.label.UTF8String ?: "-", _ps->_vname.UTF8String ?: "-", _ps->_fname.UTF8String ?: "-");
        nvmtl_snap_name = nm;
    }
    nvmtl_vk_cmd_bind_set(&_cb->_c,&selected->_p);
    nvmtl_drawlog(self);
    return YES;
}
- (BOOL)nvmtlSamplePositionError:(NSString *)message {
    _refused = YES;
    nvlog("%s", message.UTF8String);
    [_cb nvmtlRecordEncodingError:[NSError errorWithDomain:MTLCommandBufferErrorDomain
        code:MTLCommandBufferErrorInternal userInfo:@{NSLocalizedDescriptionKey:message}]];
    return NO;
}
- (BOOL)nvmtlBuildPass:(MTLRenderPassDescriptor *)d {
    NVMTLCommandBuffer *cb = _cb;
    memset(&_pass, 0, sizeof _pass); cb->_c.depth_view = NULL;
    MTLSamplePosition sample[8];
    NSUInteger sampleCount = [d getSamplePositions:NULL count:0];
    if (sampleCount && sampleCount <= 8) [d getSamplePositions:sample count:sampleCount];
    if (sampleCount == 1) return [self nvmtlSamplePositionError:@"sample positions: custom single-sample pattern is not a Metal descriptor contract"];
    if (sampleCount > 8) return [self nvmtlSamplePositionError:@"sample positions: more than eight positions; pass refused"];
    if (sampleCount) {
        _pass.sample_pattern.count = (uint32_t)sampleCount;
        for (NSUInteger i = 0; i < sampleCount; ++i)
            _pass.sample_pattern.position[i] = (nvmtl_sample_position){ sample[i].x, sample[i].y };
        if (!nvmtl_sample_pattern_valid(&_pass.sample_pattern)) return [self nvmtlSamplePositionError:@"sample positions: invalid positions; pass refused"];
    }
    _pass.depth_store_options = (uint32_t)d.depthAttachment.storeActionOptions;
    if (d.depthAttachment.storeAction == MTLStoreActionCustomSampleDepthStore)
        _pass.depth_store_options |= MTLStoreActionOptionCustomSamplePositions;
    _pass.stencil_store_options = (uint32_t)d.stencilAttachment.storeActionOptions;
    if (d.stencilAttachment.texture && _pass.stencil_store_options)
        return [self nvmtlSamplePositionError:@"sample positions: stencil store options are illegal"];
    if ((_pass.depth_store_options | _pass.stencil_store_options) & ~MTLStoreActionOptionCustomSamplePositions)
        return [self nvmtlSamplePositionError:@"sample positions: unknown depth/stencil store options"];

    if (!cb->_resources) cb->_resources = [NVMTLResSet new];
    uint32_t load = 0, w = UINT32_MAX, h = UINT32_MAX; BOOL any = NO;
    const uint32_t NL = d.renderTargetArrayLength > 1 ? (uint32_t)d.renderTargetArrayLength : 1u;
    for (uint32_t i = 0; i < NVMTL_NCOL; i++) {
        MTLRenderPassColorAttachmentDescriptor *ca = d.colorAttachments[i];
        id<MTLTexture> tx = ca.texture, rx = ca.resolveTexture;
        if (!tx) continue;
        if (![(id)tx isKindOfClass:[NVMTLTexture class]]) { nvlog("encoder: apps2 colour %u is a %s, not our texture — pass REFUSED", i, object_getClassName(tx)); return NO; }
        NVMTLTexture *t = (NVMTLTexture *)tx; uint32_t cw = 0, ch = 0;
        uint32_t zslice = [t nvi]->mtl_type == 7 ? (uint32_t)ca.depthPlane : (uint32_t)ca.slice;
        if (ca.depthPlane && [t nvi]->mtl_type != 7) { static int said;
            if (said++ < 4) nvlog("encoder: apps2 colour %u sets depthPlane %lu on a texture of type %u, which is not 3D — depthPlane IGNORED, its slice %lu is used", i, (unsigned long)ca.depthPlane, [t nvi]->mtl_type, (unsigned long)ca.slice); }
        int ta8 = 0; uint32_t tvk = nvmtl_tex_attach_vkfmt(t, &ta8);
        if (nvmtl_vk_cmd_attachment_view_n(&cb->_c, [t nvi], 0, t->_baseLevel + (uint32_t)ca.level, t->_baseSlice + zslice, NL, tvk, ta8, &_pass.colview[i], &cw, &ch)) return NO;
        _pass.col[i] = [t nvi]; _pass.colw[i] = cw; _pass.colh[i] = ch;
        _pass.col_level[i] = t->_baseLevel + (uint32_t)ca.level; _pass.col_layer[i] = t->_baseSlice + zslice;
        if (_pass.col_level[i]) (t->_parent ?: t)->_mipsWritten = YES;
        _pass.colfmt[i] = tvk;
        MTLClearColor cc = ca.clearColor;   // an A8 target keeps Metal's alpha in its red lane, its clear too
        _pass.clear[i][0] = ta8 ? (float)cc.alpha : (float)cc.red; _pass.clear[i][1] = (float)cc.green; _pass.clear[i][2] = (float)cc.blue; _pass.clear[i][3] = (float)cc.alpha;
        if (ta8 == 2) { _pass.clear[i][0] = (float)cc.alpha; _pass.clear[i][1] = (float)cc.red; _pass.clear[i][2] = (float)cc.green; _pass.clear[i][3] = (float)cc.blue; }   // ARGB8 stored as RGBA8
        if (nvmtl_load_keeps(ca.loadAction)) load |= NVMTL_LOAD_COLOUR(i);
        if (cw < w) w = cw;
        if (ch < h) h = ch;
        any = YES;
        if (i) {
            [cb->_resources addObject:t];
            NVMTLTexture *sr = t->_parent ? t->_parent : t;
            if (sr->_surf) {
                if (ca.loadAction == MTLLoadActionClear) nvmtl_surface_overwrite_recorded(cb, sr);
                else nvmtl_surface_in_for_cb(cb, sr);
                nvmtl_surf_dirty(cb, sr); }
        }
        MTLStoreAction sa = ca.storeAction;
        if ((sa == MTLStoreActionMultisampleResolve || sa == MTLStoreActionStoreAndMultisampleResolve || sa == MTLStoreActionUnknown) && rx) {
            if (![(id)rx isKindOfClass:[NVMTLTexture class]]) { nvlog("encoder: apps2 resolve %u is a %s, not our texture — pass REFUSED", i, object_getClassName(rx)); return NO; }
            NVMTLTexture *r = (NVMTLTexture *)rx; uint32_t rw = 0, rh = 0;
            int ra8 = 0; uint32_t rvk = nvmtl_tex_attach_vkfmt(r, &ra8);
            if (nvmtl_vk_cmd_attachment_view_n(&cb->_c, [r nvi], 0, r->_baseLevel + (uint32_t)ca.resolveLevel, r->_baseSlice + (uint32_t)ca.resolveSlice, NL, rvk, ra8, &_pass.resview[i], &rw, &rh)) return NO;
            _pass.res[i] = [r nvi]; _pass.resw[i] = rw; _pass.resh[i] = rh;
            _pass.resfmt[i] = rvk;
            if (i) { [cb->_resources addObject:r]; NVMTLTexture *rs = r->_parent ? r->_parent : r; if (rs->_surf) nvmtl_surf_dirty(cb, rs); }
        }
    }
    MTLRenderPassDepthAttachmentDescriptor *da = d.depthAttachment; MTLRenderPassStencilAttachmentDescriptor *sa = d.stencilAttachment;
    id<MTLTexture> dtx = da.texture ? da.texture : sa.texture;
    if (dtx) {
        if (![(id)dtx isKindOfClass:[NVMTLTexture class]]) { nvlog("encoder: apps2 depth/stencil is a %s, not our texture — pass REFUSED", object_getClassName(dtx)); return NO; }
        if (da.texture && sa.texture && da.texture != sa.texture) { static int said; if (!said++) nvlog("encoder: apps2 separate depth and stencil textures — the stencil texture is NOT attached (one depth/stencil attachment)"); }
        MTLRenderPassAttachmentDescriptor *which = da.texture ? (MTLRenderPassAttachmentDescriptor *)da : (MTLRenderPassAttachmentDescriptor *)sa;
        NVMTLTexture *dt = (NVMTLTexture *)dtx; uint32_t dw = 0, dh = 0;
        if (nvmtl_vk_cmd_attachment_view_n(&cb->_c, [dt nvi], 1, dt->_baseLevel + (uint32_t)which.level, dt->_baseSlice + (uint32_t)which.slice, NL, 0, 0, &_pass.dsview, &dw, &dh)) return NO;
        {
            MTLStoreAction dsa = da.storeAction, ssa = sa.storeAction;
            BOOL dr = da.texture && da.resolveTexture && (dsa == MTLStoreActionMultisampleResolve || dsa == MTLStoreActionStoreAndMultisampleResolve || dsa == MTLStoreActionUnknown);
            BOOL sr = sa.texture && sa.resolveTexture && (ssa == MTLStoreActionMultisampleResolve || ssa == MTLStoreActionStoreAndMultisampleResolve || ssa == MTLStoreActionUnknown);
            id<MTLTexture> drx = dr ? da.resolveTexture : sr ? sa.resolveTexture : nil;
            if (drx && [(id)drx isKindOfClass:[NVMTLTexture class]]) {
                NVMTLTexture *r = (NVMTLTexture *)drx; uint32_t rw = 0, rh = 0;
                MTLRenderPassAttachmentDescriptor *rw_ = dr ? (MTLRenderPassAttachmentDescriptor *)da : (MTLRenderPassAttachmentDescriptor *)sa;
                if (nvmtl_vk_cmd_attachment_view_n(&cb->_c, [r nvi], 1, r->_baseLevel + (uint32_t)rw_.resolveLevel, r->_baseSlice + (uint32_t)rw_.resolveSlice, NL, 0, 0, &_pass.dresview, &rw, &rh)) return NO;
                _pass.dres = [r nvi];
                _pass.dresmode = dr ? 1u + (uint32_t)da.depthResolveFilter : 0u;
                _pass.sresmode = sr ? 1u + (uint32_t)sa.stencilResolveFilter : 0u;
                [cb->_resources addObject:r];
            } else if (drx) { nvlog("encoder: par1 depth/stencil resolve texture is a %s, not our texture — pass REFUSED", object_getClassName(drx)); return NO; }
        }
        _pass.ds = [dt nvi];
        _pass.ds_level = dt->_baseLevel + (uint32_t)which.level;
        _pass.ds_layer = dt->_baseSlice + (uint32_t)which.slice;
        if (sa.texture) [cb->_resources addObject:sa.texture];
        if (dw < w) w = dw;
        if (dh < h) h = dh;
        any = YES;
        if (da.texture && nvmtl_load_keeps(da.loadAction)) load |= NVMTL_LOAD_DEPTH;
        if (sa.texture && nvmtl_load_keeps(sa.loadAction)) load |= NVMTL_LOAD_STENCIL;
    }
    _pass.clear_depth = (float)da.clearDepth; _pass.clear_stencil = sa.clearStencil;
    if (!any) {
        // A pass with no attachments: the fragment shader writes through images or buffers only, sized by the descriptor's
        // renderTargetWidth/Height (Blender Eevee's shadow pages, 8192x8192 with image atomics). Vulkan draws it as a render
        // pass with no attachments and a framebuffer of that size. Refusing it crashed Blender on its first shadowed frame
        // (#152). Metal requires the size for such a pass, so a pass without one is still refused.
        if (!d.renderTargetWidth || !d.renderTargetHeight) {
            nvlog("encoder: apps2 a render pass with no attachments and no renderTargetWidth/Height — pass REFUSED"); return NO; }
        w = (uint32_t)d.renderTargetWidth; h = (uint32_t)d.renderTargetHeight;
        static int said; if (said++ < 4) nvlog("encoder: render pass with no attachments, %ux%u (writes through images/buffers only)", w, h);
    }
    if (d.renderTargetWidth && d.renderTargetWidth < w) w = (uint32_t)d.renderTargetWidth;
    if (d.renderTargetHeight && d.renderTargetHeight < h) h = (uint32_t)d.renderTargetHeight;
    _pass.load = _load = load; _pass.w = w; _pass.h = h; _pass.layers = NL;
    { static uint32_t seen[16]; static unsigned nseen;
      const uint32_t shape = (uint32_t)d.colorAttachments[0].loadAction
                           | ((uint32_t)(da.texture ? da.loadAction + 1 : 0) << 4)
                           | ((uint32_t)(sa.texture ? sa.loadAction + 1 : 0) << 8)
                           | (load << 12);
      unsigned k = 0; for (; k < nseen; k++) if (seen[k] == shape) break;
      if (k == nseen && nseen < 16) {
        seen[nseen++] = shape;
        nvlog("encoder: dontcare pass shape — colour0 load action %lu, depth %s action %lu, stencil %s action %lu, load bits 0x%x (DontCare %s)",
              (unsigned long)d.colorAttachments[0].loadAction,
              da.texture ? "present" : "absent", (unsigned long)da.loadAction,
              sa.texture ? "present" : "absent", (unsigned long)sa.loadAction,
              load, nvmtl_dontcare_clears() ? "CLEARS (old behaviour)" : "keeps, as on Apple");
      } }
    cb->_c.depth_view = _pass.dsview;
    return YES;
}
- (BOOL)nvmtlBeginPassLoad:(uint32_t)load {
    if (_refused || !_ps) return NO;
    uint32_t keep = _pass.load; _pass.load = load;
    int rc = nvmtl_vk_cmd_begin_pass(&_cb->_c, &_pass, &_ps->_p);
    _pass.load = keep;
    return rc == 0;
}
static int nvmtl_stencil_stale_on(void) {
    static int v = -1;
    if (v < 0) { const char *e = getenv("NVMTL_STENCIL_STALE"); v = e && e[0] == '1';
        nvlog("stencil: %s (NVMTL_STENCIL_STALE=%s)", v ? "a pipeline without a stencil format keeps the previous draw's stencil test (old rule)"
                                                        : "every draw in a pass with a stencil attachment gets its own depth-stencil state's stencil test", e ? e : "unset"); }
    return v;
}
// The stencil test, its ops and write mask are dynamic state: whatever the last draw set stays in force. A pipeline whose
// format names no stencil used to leave it alone, so it drew with the previous draw's test and wrote that draw's
// reference. Cyberpunk 2077's G-buffer pass marked stretches of floor with stencil 20 that way on some frames, depending on
// draw order, and its puddle decals (stencil test: low five bits <= 11) vanished there for a frame or two at a time.
- (void)nvmtlApplyDepthStencil {
    if (!_begun || !_ps) return;
    const int passStencil = _pass.ds && _pass.ds->fmt >= VK_FORMAT_S8_UINT && _pass.ds->fmt <= VK_FORMAT_D32_SFLOAT_S8_UINT;
    if (!_ps->_p.has_depth) {
        if (passStencil && !nvmtl_stencil_stale_on()) { static const uint32_t off[6] = { 7, 0, 0, 0, 0xff, 0xff }; nvmtl_vk_cmd_set_stencil(&_cb->_c, 0, off, off); }
        return;
    }
    // NVMTL_DEPTH_ALWAYS=1: every depth test passes (writes kept) - tells a wrong depth test from a black shader (diagnostic)
    static int always = -1; if (always < 0) { const char *e = getenv("NVMTL_DEPTH_ALWAYS"); always = e && *e && *e != '0'; if (always) nvlog("NVMTL_DEPTH_ALWAYS: depth compare forced to Always"); }
    nvmtl_vk_cmd_set_depth(&_cb->_c, _ds ? 1 : 0, _ds ? _ds->_write : 0, always ? 7 : (_ds ? _ds->_compare : 7));
    if (!_ps->_p.has_stencil && (!passStencil || nvmtl_stencil_stale_on())) return;
    static const uint32_t off[6] = { 7, 0, 0, 0, 0xff, 0xff };
    nvmtl_vk_cmd_set_stencil(&_cb->_c, _ds && _ds->_stencil, _ds ? _ds->_sf : off, _ds ? _ds->_sb : off);
    if (!_hasRef) { nvmtl_vk_cmd_set_stencil_ref(&_cb->_c, 0, 0); _hasRef = YES; }
}
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)ps {
    // NVMTL_DUMP_PSO=<text>: the first encoder that sets a pipeline whose label contains it has the fragment buffers bound
    // at its end dumped, as NVMTL_DUMP_GROUP does, for apps that label pipelines but push no debug groups (diagnostic)
    { static const char *want; static int once; static _Atomic int armed; if (!once) { once = 1; want = getenv("NVMTL_DUMP_PSO"); }
      NSString *lbl = ps.label;
      if (want && !strcmp(want, "?") && lbl) { static NSMutableSet *seen; static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
          pthread_mutex_lock(&mu); if (!seen) seen = [NSMutableSet new]; BOOL n = ![seen containsObject:lbl]; if (n) [seen addObject:lbl];
          pthread_mutex_unlock(&mu); if (n) nvlog("NVMTL_DUMP_PSO: pipeline label %s", lbl.UTF8String); }
      if (want && *want && lbl && strstr(lbl.UTF8String ?: "", want) && !atomic_exchange(&armed, 1)) { _dumpPso = YES; _dumpName = [lbl copy]; } }
    { NVMTLRenderPipelineState *p_ = (NVMTLRenderPipelineState *)ps;
      if (p_ && nvmtl_trace_on()) {
          extern int nvmtl_vk_pipeline_stats(void *pipe, char *out, size_t n);
          uint32_t hv = 0, hf = 0;
          for (int s = 0; s < 2; s++) {
              id f = s ? p_->_descriptor.fragmentFunction : p_->_descriptor.vertexFunction;
              if (![f isKindOfClass:[NVMTLFunction class]]) continue;
              NSData *d = ((NVMTLFunction *)f)->_spirv; if (!d.length) continue;
              uint32_t h = 2166136261u; const uint8_t *b = d.bytes; for (NSUInteger i = 0; i < d.length; i++) { h ^= b[i]; h *= 16777619u; }
              if (s) hf = h; else hv = h;
              static NSMutableSet *saved; static os_unfair_lock sl = OS_UNFAIR_LOCK_INIT; BOOL fresh = NO;
              os_unfair_lock_lock(&sl); if (!saved) saved = [NSMutableSet new]; if (![saved containsObject:@(h)]) { [saved addObject:@(h)]; fresh = YES; } os_unfair_lock_unlock(&sl);
              if (fresh) { NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/nvmtl/pstat"];
                  [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                  NSString *pth = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%08x.%s.spv", h, s ? "frag" : "vert"]];
                  if (![[NSFileManager defaultManager] fileExistsAtPath:pth]) [d writeToFile:pth atomically:YES]; }
          }
          char st[600]; nvmtl_vk_pipeline_stats(p_->_p.pipe, st, sizeof st);
          nvtrace("PSO %p %s / %s vs %08x fs %08x | %s", (__bridge void *)ps, p_->_vname.UTF8String ?: "?", p_->_fname.UTF8String ?: "?", hv, hf, st);
      } }
    NVMTLRenderPipelineState *p = (NVMTLRenderPipelineState *)ps;
    if (!p) { nvlog("encoder: nil render pipeline refused"); return; }
    BOOL subset = NO;   // the pipeline declares a subset of the pass's attachments: bound, with the depth ops it leaves out disabled
    if (_begun && !nvmtl_vk_pipeline_compatible(&_passSig, &p->_p)) {
        subset = nvmtl_vk_pipeline_subset(&_passSig, &p->_p) ? YES : NO;
        static int said; if (said++ < 16) {
            char a[160], b[160]; nvmtl_vk_rtsig_text(&_passSig, a, sizeof a); nvmtl_vk_pipeline_sig_text(&p->_p, b, sizeof b);
            char d[200]; int k = snprintf(d, sizeof d, "descriptor col [");
            for (uint32_t i = 0; i < NVMTL_NCOL && k > 0 && (size_t)k < sizeof d; i++) k += snprintf(d + k, sizeof d - k, "%s%u", i ? " " : "", _pass.col[i] ? _pass.col[i]->fmt : 0u);
            if (k > 0 && (size_t)k < sizeof d) snprintf(d + k, sizeof d - k, "] ds %u", _pass.ds ? _pass.ds->fmt : 0u);
            nvlog("encoder: render pipeline %s/%s does not match the pass in progress: pipeline %s | pass %s | %s -> %s",
                  p->_vname.UTF8String ?: "?", p->_fname.UTF8String ?: "?", b, a, d, subset ? "BOUND as a subset" : "REFUSED, draw state unchanged");
        }
        if (!subset) return;
    }
    _ps = p;
    nvmtl_retain_resource(_cb, p);
    if (!_begun) {
        if (_refused) return;
        if (nvmtl_vk_cmd_begin_pass(&_cb->_c, &_pass, &p->_p)) {
            nvlog("encoder: begin render FAILED — nothing is recorded for this pipeline");
            if (_pass.sample_pattern.count) [self nvmtlSamplePositionError:@"sample positions: cannot begin requested render pass"];
            return; }
        _begun = YES; [self nvmtlBeginVisibility]; _passFmt = p->_p.cfmt; _passDepth = p->_p.has_depth; _passSamples = p->_p.samples; nvmtl_vk_pipeline_sig(&p->_p, &_passSig);
        if (_resolve) { NVMTLTexture *rs = _resolve->_parent ? _resolve->_parent : _resolve; if (rs->_surf) nvmtl_surf_dirty(_cb, rs); }
        nvmtl_vk_cmd_set_cull(&_cb->_c, _cull);
        if (_hasVP) nvmtl_vk_cmd_set_viewport(&_cb->_c, _vp[0], _vp[1], _vp[2], _vp[3], _vp[4], _vp[5]);
        if (_hasSC) nvmtl_vk_cmd_set_scissor(&_cb->_c, (int32_t)_sc[0], (int32_t)_sc[1], _sc[2], _sc[3]);
        [self nvmtlApplyDepthStencil];
    } else if (subset) {
        nvmtl_vk_cmd_bind_pipeline(&_cb->_c, &p->_p);
        if (!p->_p.has_depth && _passDepth) {
            nvmtl_vk_cmd_set_depth(&_cb->_c, 0, 0, 7);   // no depth attachment declared: no depth test, no depth write
            [self nvmtlApplyDepthStencil];               // and no stencil test left over from the previous draw
        } else [self nvmtlApplyDepthStencil];
    } else if (!nvmtl_vk_pipeline_compatible(&_passSig, &p->_p)) {
        static int said; if (said++ < 8) nvlog("G12 setRenderPipelineState: pipeline (fmt %u depth %d) does NOT match the pass in progress "
            "(fmt %u depth %d) — NOT bound, the earlier pipeline keeps drawing", p->_p.cfmt, p->_p.has_depth, _passFmt, _passDepth);
    } else {
        nvmtl_vk_cmd_bind_pipeline(&_cb->_c, &p->_p);
        static int told; if (!told++) nvlog("G12 a second pipeline was bound inside one encoder (first time in this process)");
        if (!nvmtl_stencil_stale_on()) [self nvmtlApplyDepthStencil];
    }
    if (_cb->_c.pt_open && _cb->_c.pt_pool) {
        static const char kPtHash = 0; NSNumber *hn = objc_getAssociatedObject(p, &kPtHash);
        if (!hn) {
            uint32_t hv = 0, hf = 0;
            for (int s = 0; s < 2; s++) {
                id f = s ? p->_descriptor.fragmentFunction : p->_descriptor.vertexFunction;
                if (![f isKindOfClass:[NVMTLFunction class]]) continue;
                NSData *d = ((NVMTLFunction *)f)->_spirv; if (!d.length) continue;
                uint32_t h = 2166136261u; const uint8_t *b = d.bytes; for (NSUInteger i = 0; i < d.length; i++) { h ^= b[i]; h *= 16777619u; }
                if (s) hf = h; else hv = h;
                NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/nvmtl/pstat"];
                NSString *pth = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%08x.%s.spv", h, s ? "frag" : "vert"]];
                if (![[NSFileManager defaultManager] fileExistsAtPath:pth]) {
                    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                    [d writeToFile:pth atomically:YES]; }
            }
            hn = @(((uint64_t)hv << 32) | hf);
            objc_setAssociatedObject(p, &kPtHash, hn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            extern int nvmtl_vk_pipeline_stats(void *pipe, char *out, size_t n);
            char st[600]; nvmtl_vk_pipeline_stats(p->_p.pipe, st, sizeof st);
            nvlog("ptpso: vs %08x fs %08x | %s", hv, hf, st);
        }
        extern void nvmtl_vk_pt_note(nvk_cmdbuf *c, uint32_t fs);
        nvmtl_vk_pt_note(&_cb->_c, (uint32_t)(hn.unsignedLongLongValue & 0xffffffffu));
    }
}
- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)off atIndex:(NSUInteger)i {
    NVMTLBuffer *nb = nvmtl_as_buffer(b, "setVertexBuffer"); if (b && !nb) return;
    if (!nb) { nvlog("setVertexBuffer: nil at index %lu", (unsigned long)i); return; }
    if (!_cb->_resources) _cb->_resources = [NVMTLResSet new];
    [_cb->_resources addObject:nb];
    if (i < NVMTL_NBUFAT) { _vbufAt[i] = nb; _vbufOff[i] = off; }
    nvtrace_floats("VB", (unsigned long)i, (unsigned long)off, nb->_b.map, 24);
    nvmtl_lw_note(_cb, nb, off);
    if (nvmtl_vk_bind_buffer(&_cb->_c, NVMTL_SET_VERTEX, (uint32_t)i, &nb->_b, off)) nvlog("setVertexBuffer: bind FAILED");
}
- (void)setVertexAccelerationStructure:(id<MTLAccelerationStructure>)as atBufferIndex:(NSUInteger)i { [self setVertexBuffer:(id<MTLBuffer>)as offset:0 atIndex:i];
    NVMTLAccelerationStructure *a = (NVMTLAccelerationStructure *)as;
    if (a && [(id)a isKindOfClass:[NVMTLAccelerationStructure class]] && a->_uid.buf && _cb) nvmtl_vk_bind_buffer(&_cb->_c, NVMTL_SET_VERTEX, 31, &a->_uid, 0); }
- (void)setFragmentAccelerationStructure:(id<MTLAccelerationStructure>)as atBufferIndex:(NSUInteger)i { [self setFragmentBuffer:(id<MTLBuffer>)as offset:0 atIndex:i];
    NVMTLAccelerationStructure *a = (NVMTLAccelerationStructure *)as;
    if (a && [(id)a isKindOfClass:[NVMTLAccelerationStructure class]] && a->_uid.buf && _cb) nvmtl_vk_bind_buffer(&_cb->_c, NVMTL_SET_FRAGMENT, 31, &a->_uid, 0); }
- (void)setFragmentBuffer:(id<MTLBuffer>)b offset:(NSUInteger)off atIndex:(NSUInteger)i {
    NVMTLBuffer *nb = nvmtl_as_buffer(b, "setFragmentBuffer"); if (b && !nb) return;
    if (!nb) { nvlog("setFragmentBuffer: nil at index %lu", (unsigned long)i); return; }
    if (!_cb->_resources) _cb->_resources = [NVMTLResSet new];
    [_cb->_resources addObject:nb];
    if (i < NVMTL_NBUFAT) { _fbufAt[i] = nb; _fbufOff[i] = off; }
    nvtrace_floats("FB", (unsigned long)i, (unsigned long)off, nb->_b.map, 16);
    nvmtl_lw_note(_cb, nb, off);
    if (nvmtl_vk_bind_buffer(&_cb->_c, NVMTL_SET_FRAGMENT, (uint32_t)i, &nb->_b, off)) nvlog("setFragmentBuffer: bind FAILED");
}

static NVMTLBuffer *nvmtl_bytes_ring(NVMTLCommandBuffer *cb, NSUInteger len, size_t *off);
- (void)nvmtlBindBytes:(const void *)bytes length:(NSUInteger)len atIndex:(NSUInteger)i set:(uint32_t)set {
    size_t roff = 0;
    NVMTLBuffer *nb = nvmtl_bytes_ring(_cb, len, &roff);
    const BOOL ring = nb != nil;
    if (!ring) {
        nb = [NVMTLBuffer new];
        if (nvmtl_vk_buffer_create(len < 16 ? 16 : len, 1, &nb->_b)) { nvlog("setBytes: buffer create FAILED"); return; }
    }
    if (nb->_b.map) nvmtl_devcpy((uint8_t *)nb->_b.map + roff, bytes, len);
    if (nvmtl_vk_bind_buffer(&_cb->_c, set, (uint32_t)i, &nb->_b, roff)) nvlog("setBytes: bind FAILED");
    nvtrace_floats(set == NVMTL_SET_VERTEX ? "VBYTES" : "FBYTES", (unsigned long)i, 0, len >= 4 ? bytes : NULL, (int)(len / 4 > 24 ? 24 : len / 4));
    if (!ring) {
        if (!_cb->_scratch) _cb->_scratch = [NSMutableArray new];
        [_cb->_scratch addObject:nb];
    }
    if (i < NVMTL_NBUFAT && set == NVMTL_SET_VERTEX)        { _vbufAt[i] = nb; _vbufOff[i] = roff; }
    else if (i < NVMTL_NBUFAT && set == NVMTL_SET_FRAGMENT) { _fbufAt[i] = nb; _fbufOff[i] = roff; }
}
- (void)setVertexBytes:(const void *)b length:(NSUInteger)l atIndex:(NSUInteger)i { [self nvmtlBindBytes:b length:l atIndex:i set:NVMTL_SET_VERTEX]; }
- (void)setFragmentBytes:(const void *)b length:(NSUInteger)l atIndex:(NSUInteger)i { [self nvmtlBindBytes:b length:l atIndex:i set:NVMTL_SET_FRAGMENT]; }
- (void)setVertexTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i {
    NVMTLTexture *nt = nvmtl_as_texture(t, "setVertexTexture"); if (t && !nt) return;
    if (!nt) { nvlog("setVertexTexture: nil at index %lu", (unsigned long)i); return; }
    nvmtl_retain_resource(_cb, nt);
    nvmtl_surface_in_for_cb(_cb, nt);
    if (nt->_tbView) nvmtl_vk_bind_texel_view(&_cb->_c, NVMTL_SET_VERTEX, (uint32_t)i, nt->_tbView, nt->_tbStorage);
    else {
    if (nvmtl_vk_bind_texture_view(&_cb->_c, NVMTL_SET_VERTEX, (uint32_t)i, [nt nvsampleview])) nvlog("setVertexTexture: bind FAILED");
    nvmtl_vk_bind_storage_view(&_cb->_c, NVMTL_SET_VERTEX, (uint32_t)i, nt->_stex ? [nt nvview] : NULL);
    }
}
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i {
    NVMTLSamplerState *ns = (NVMTLSamplerState *)s;
    if (i >= 16 || nvmtl_vk_bind_sampler(&_cb->_c, NVMTL_SET_FRAGMENT, (uint32_t)i, ns ? &ns->_s : NULL)) {
        nvlog("setFragmentSamplerState: invalid index or bind failure"); return;
    }
    if (!_fragmentSamplers) _fragmentSamplers=[NSMutableDictionary new];
    NSString *key=[@(i) stringValue];
    if (nvmtl_pixel_sampler_update(_fragmentSamplers,key,ns ? ns->_pixelState : nil)) _pixelSamplerKey=nil;
    nvtrace("FRAGMENT SAMPLER[%lu] pixel=%d bound=%d",(unsigned long)i,ns && ns->_pixelState!=nil,ns!=nil);
    if(ns) { if (!_cb->_resources) _cb->_resources=[NVMTLResSet new];[_cb->_resources addObject:ns]; }
}
- (void)setVertexSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i {
    NVMTLSamplerState *ns = (NVMTLSamplerState *)s;
    if (i >= 16 || nvmtl_vk_bind_sampler(&_cb->_c, NVMTL_SET_VERTEX, (uint32_t)i, ns ? &ns->_s : NULL)) {
        nvlog("setVertexSamplerState: invalid index or bind failure"); return;
    }
    if (!_vertexSamplers) _vertexSamplers=[NSMutableDictionary new];
    NSString *key=[@(i) stringValue];
    if (nvmtl_pixel_sampler_update(_vertexSamplers,key,ns ? ns->_pixelState : nil)) _pixelSamplerKey=nil;
    nvtrace("VERTEX SAMPLER[%lu] pixel=%d bound=%d",(unsigned long)i,ns && ns->_pixelState!=nil,ns!=nil);
    if(ns) { if (!_cb->_resources) _cb->_resources=[NVMTLResSet new];[_cb->_resources addObject:ns]; }
}
- (void)setFragmentTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i {
    NVMTLTexture *nt = nvmtl_as_texture(t, "setFragmentTexture"); if (t && !nt) return;
    if (!nt) { nvlog("setFragmentTexture: nil at index %lu", (unsigned long)i); return; }
    nvmtl_retain_resource(_cb, nt);
    nvmtl_surface_cpu_dump(nt->_parent ? nt->_parent : nt);
    nvmtl_surface_in_for_cb(_cb, nt);
    { NVMTLTexture *rt = nt->_parent ? nt->_parent : nt; nvtrace("FTEX[%lu] %p(img %p parent %p) %ux%u surf %u view %d", (unsigned long)i, (__bridge void *)nt, [nt nvi]->img,
        (__bridge void *)nt->_parent, [nt nvi]->w, [nt nvi]->h, rt->_surf ? (unsigned)IOSurfaceGetID(rt->_surf) : 0u, nt->_parent != nil); }
    if (nt->_tbView) nvmtl_vk_bind_texel_view(&_cb->_c, NVMTL_SET_FRAGMENT, (uint32_t)i, nt->_tbView, nt->_tbStorage);
    else {
    if (nvmtl_vk_bind_texture_view(&_cb->_c, NVMTL_SET_FRAGMENT, (uint32_t)i, [nt nvsampleview])) nvlog("setFragmentTexture: bind FAILED");
    nvmtl_vk_bind_storage_view(&_cb->_c, NVMTL_SET_FRAGMENT, (uint32_t)i, nt->_stex ? [nt nvview] : NULL);
    if (!nt->_stex && NVMTL_USAGE_WRITES(nt.usage)) {
        // a fragment shader writing a texture that has no storage view writes the dummy: say which texture, once per shape
        static NSMutableSet *seen; static os_unfair_lock sl = OS_UNFAIR_LOCK_INIT;
        NSString *k = [NSString stringWithFormat:@"%lu/%lu/%lu", (unsigned long)nt.pixelFormat, (unsigned long)nt.usage, (unsigned long)nt.textureType];
        os_unfair_lock_lock(&sl); if (!seen) seen = [NSMutableSet new]; BOOL fresh = ![seen containsObject:k]; if (fresh) [seen addObject:k]; os_unfair_lock_unlock(&sl);
        if (fresh) nvlog("setFragmentTexture: texture %lu is ShaderWrite but has no storage view (pixelFormat %lu, usage 0x%lx, type %lu, image storage %u) - a fragment write to it goes to the dummy",
                         (unsigned long)i, (unsigned long)nt.pixelFormat, (unsigned long)nt.usage, (unsigned long)nt.textureType, [nt nvi]->storage);
    }
    }
}
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count
         instanceCount:(NSUInteger)instances baseInstance:(NSUInteger)baseInstance {
    if (!_begun) { nvlog("encoder: draw with no pipeline set"); return; }
    _ppKind = 1; _ppA[0] = start; _ppA[1] = count; _ppA[2] = instances; _ppA[3] = baseInstance; _ppA[4] = 0;
    if (![self nvmtlBindSamplerPipeline]) return;
    nvtrace("DRAW type %u | vs %s | fs %s | blend %s", (unsigned)type, _ps ? _ps->_vname.UTF8String : "-", _ps ? _ps->_fname.UTF8String : "-", _ps ? _ps->_blend.UTF8String : "-");
    if (nvmtl_trace_on()) { char bufs_[600]; nvmtl_vk_trace_buffers(&_cb->_c, bufs_, sizeof bufs_); nvtrace("  BUFS%s", bufs_); }
    if (nvmtl_vk_cmd_set_topology(&_cb->_c, (unsigned)type)) return;
    if ([self nvmtlVertexInputs]) return;
    nvtrace("  direct start %lu count %lu instances %lu", (unsigned long)start, (unsigned long)count, (unsigned long)instances);
    nvmtl_vk_cmd_draw(&_cb->_c, (uint32_t)start, (uint32_t)count, (uint32_t)instances, (uint32_t)baseInstance);
}
- (int)nvmtlVertexInputs {
    _passDraws++;
    if (_ps && _ps->_p.tess) { static int said; if (said++ < 8) nvlog("tess: a primitive draw on a tessellation pipeline (%s) — NOT drawn "
        "(Metal requires drawPatches:)", _ps->_vname.UTF8String ?: "?"); return -1; }
    if (!_ps || !_ps->_p.vin_mask) return 0;
    nvtrace("  VIN%s", _ps->_vdesc.UTF8String ?: " ?");
    int r = nvmtl_vk_cmd_vertex_inputs(&_cb->_c, &_ps->_p, _vstride, _vstrideSet);
    if (r) nvtrace("  NOT DRAWN: a vertex buffer the descriptor names is not bound, or its dynamic stride is unset or too large");
    return r;
}
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)c instanceCount:(NSUInteger)i {
    [self drawPrimitives:t vertexStart:s vertexCount:c instanceCount:i baseInstance:0];
}
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)c {
    [self drawPrimitives:t vertexStart:s vertexCount:c instanceCount:1 baseInstance:0];
}
- (void)setTessellationFactorBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset instanceStride:(NSUInteger)instanceStride {
    NVMTLBuffer *nb = (NVMTLBuffer *)buffer;
    if (nb && ![(id)nb isKindOfClass:[NVMTLBuffer class]]) { nvlog("setTessellationFactorBuffer: not our buffer (%s) — ignored", object_getClassName(buffer)); nb = nil; }
    if (nb) nvmtl_retain_resource(_cb, nb);
    _tfb = nb; _tfbOff = offset; _tfbStride = instanceStride;
}
- (void)setTessellationFactorScale:(float)scale { _tfScale = scale; _tfScaleSet = YES; }
- (BOOL)nvmtlTessAddress:(id<MTLBuffer>)buf offset:(NSUInteger)off align:(uint64_t)al what:(const char *)what out:(uint64_t *)out {
    *out = 0; if (!buf) return YES;
    if (![(id)buf isKindOfClass:[NVMTLBuffer class]]) { nvlog("tess draw: the %s is not our buffer (%s) — NOT drawn", what, object_getClassName(buf)); return NO; }
    NVMTLBuffer *nb = (NVMTLBuffer *)buf;
    if (off >= nb->_b.size) { nvlog("tess draw: %s offset %lu is outside its %zu bytes — NOT drawn", what, (unsigned long)off, nb->_b.size); return NO; }
    nvmtl_retain_resource(_cb, nb);
    uint64_t a = nvmtl_vk_buffer_address(&nb->_b);
    if (!a) { nvlog("tess draw: the %s has no device address — NOT drawn", what); return NO; }
    a += off;
    if (a & (al - 1)) { nvlog("tess draw: the %s at offset %lu is not %llu-byte aligned — NOT drawn", what, (unsigned long)off, (unsigned long long)al); return NO; }
    *out = a; return YES;
}
- (void)nvmtlPatches:(NSUInteger)n start:(NSUInteger)start count:(NSUInteger)count pib:(id<MTLBuffer>)pib pibOff:(NSUInteger)pibOff
                cpib:(id<MTLBuffer>)cpib cpibOff:(NSUInteger)cpibOff indexed:(BOOL)indexed instances:(NSUInteger)instances
                base:(NSUInteger)base indirect:(id<MTLBuffer>)ind indOff:(NSUInteger)indOff {
    if (!_begun) { nvlog("encoder: patch draw with no pipeline set"); return; }
    if (!_ps || !_ps->_p.tess) { nvlog("tess draw: the pipeline (%s) has no post-tessellation vertex function — NOT drawn", _ps ? _ps->_vname.UTF8String : "-"); return; }
    if (n != _ps->_p.tess_n) { nvlog("tess draw: %lu control points per patch, %s takes %u — NOT drawn", (unsigned long)n, _ps->_vname.UTF8String ?: "?", _ps->_p.tess_n); return; }
    if (!_tfb) { nvlog("tess draw: no tessellation factor buffer is set — NOT drawn"); return; }
    if (indexed != (_ps->_p.tess_cpidx != 0)) { nvlog("tess draw: a%s draw on a pipeline whose tessellationControlPointIndexType is %u — NOT drawn",
        indexed ? "n indexed" : " non-indexed", _ps->_p.tess_cpidx); return; }
    if (indexed && !cpib) { nvlog("tess draw: drawIndexedPatches: with no control-point index buffer — NOT drawn"); return; }
    if (_tfbStride & 3) { nvlog("tess draw: factor instanceStride %lu is not a multiple of 4 — NOT drawn", (unsigned long)_tfbStride); return; }
    uint64_t fac = 0, cpx = 0, pix = 0, ia = 0;
    if (![self nvmtlTessAddress:_tfb offset:_tfbOff align:4 what:"tessellation factor buffer" out:&fac] ||
        ![self nvmtlTessAddress:pib offset:pibOff align:4 what:"patch index buffer" out:&pix] ||
        ![self nvmtlTessAddress:cpib offset:cpibOff align:(_ps->_p.tess_cpidx == 1 ? 2 : 4) what:"control-point index buffer" out:&cpx] ||
        ![self nvmtlTessAddress:ind offset:indOff align:4 what:"indirect patch-draw buffer" out:&ia]) return;
    if (![self nvmtlBindSamplerPipeline]) return;
    nvtrace("DRAW patches %lu cp | vs %s | fs %s | blend %s", (unsigned long)n, _ps->_vname.UTF8String, _ps->_fname.UTF8String, _ps->_blend.UTF8String);
    if (nvmtl_trace_on()) { char bufs_[600]; nvmtl_vk_trace_buffers(&_cb->_c, bufs_, sizeof bufs_); nvtrace("  BUFS%s", bufs_); }
    if (ind) nvtrace("  indirect patches @%lu, pib %s", (unsigned long)indOff, pib ? "yes" : "no");
    else nvtrace("  patches start %lu count %lu instances %lu base %lu, pib %s", (unsigned long)start, (unsigned long)count,
                 (unsigned long)instances, (unsigned long)base, pib ? "yes" : "no");
    if (nvmtl_vk_cmd_draw_patches(&_cb->_c, &_ps->_p, fac, (uint32_t)_tfbStride, _tfScaleSet ? _tfScale : 1.0f, cpx, pix, (uint32_t)start,
                                  (uint32_t)count, (uint32_t)instances, (uint32_t)base, ind ? &((NVMTLBuffer *)ind)->_b : NULL, indOff))
        nvtrace("  NOT DRAWN: a vertex buffer the tessellation pipeline pulls is not bound");
}
- (void)drawPatches:(NSUInteger)n patchStart:(NSUInteger)start patchCount:(NSUInteger)count patchIndexBuffer:(id<MTLBuffer>)pib
    patchIndexBufferOffset:(NSUInteger)pibOff instanceCount:(NSUInteger)instances baseInstance:(NSUInteger)base {
    [self nvmtlPatches:n start:start count:count pib:pib pibOff:pibOff cpib:nil cpibOff:0 indexed:NO instances:instances base:base indirect:nil indOff:0];
}
- (void)drawPatches:(NSUInteger)n patchIndexBuffer:(id<MTLBuffer>)pib patchIndexBufferOffset:(NSUInteger)pibOff
     indirectBuffer:(id<MTLBuffer>)ind indirectBufferOffset:(NSUInteger)indOff {
    if (!ind) { nvlog("drawPatches:indirectBuffer: nil"); return; }
    [self nvmtlPatches:n start:0 count:0 pib:pib pibOff:pibOff cpib:nil cpibOff:0 indexed:NO instances:0 base:0 indirect:ind indOff:indOff];
}
- (void)drawIndexedPatches:(NSUInteger)n patchStart:(NSUInteger)start patchCount:(NSUInteger)count patchIndexBuffer:(id<MTLBuffer>)pib
    patchIndexBufferOffset:(NSUInteger)pibOff controlPointIndexBuffer:(id<MTLBuffer>)cpib controlPointIndexBufferOffset:(NSUInteger)cpibOff
             instanceCount:(NSUInteger)instances baseInstance:(NSUInteger)base {
    [self nvmtlPatches:n start:start count:count pib:pib pibOff:pibOff cpib:cpib cpibOff:cpibOff indexed:YES instances:instances base:base indirect:nil indOff:0];
}
- (void)drawIndexedPatches:(NSUInteger)n patchIndexBuffer:(id<MTLBuffer>)pib patchIndexBufferOffset:(NSUInteger)pibOff
    controlPointIndexBuffer:(id<MTLBuffer>)cpib controlPointIndexBufferOffset:(NSUInteger)cpibOff
             indirectBuffer:(id<MTLBuffer>)ind indirectBufferOffset:(NSUInteger)indOff {
    if (!ind) { nvlog("drawIndexedPatches:indirectBuffer: nil"); return; }
    [self nvmtlPatches:n start:0 count:0 pib:pib pibOff:pibOff cpib:cpib cpibOff:cpibOff indexed:YES instances:0 base:0 indirect:ind indOff:indOff];
}
- (void)nvmtlVisibilityError:(NSString *)message {
    nvlog("%s", message.UTF8String);
    [_cb nvmtlRecordEncodingError:[NSError errorWithDomain:MTLCommandBufferErrorDomain
        code:MTLCommandBufferErrorInternal userInfo:@{NSLocalizedDescriptionKey: message}]];
}
- (void)nvmtlCloseVisibility {
    if (_visActive) {
        nvmtl_vk_cmd_end_occlusion(&_cb->_c, _visSlot);
        if (!_visRecords) _visRecords = [NSMutableArray new];
        [_visRecords addObject:@[@(_visSlot), @(_visOffset)]];
        _visActive = NO;
    } else if (_visPending) {
        if (!_visRecords) _visRecords = [NSMutableArray new];
        [_visRecords addObject:@[@(UINT32_MAX), @(_visOffset)]];
    }
    _visPending = NO;
}
- (void)nvmtlBeginVisibility {
    if (!_visPending || !_begun) return;
    uint32_t query;
    if (nvmtl_vk_cmd_alloc_occlusion(&_cb->_c, &query) ||
        nvmtl_vk_cmd_begin_occlusion(&_cb->_c, query)) {
        [self nvmtlVisibilityError:[NSString stringWithFormat:@"visibility: query allocation failed at offset %zu - pass refused", (size_t)_visOffset]];
        _refused = YES; return;
    }
    _visSlot = query; _visActive = YES; _visPending = NO;
}
- (void)setVisibilityResultMode:(MTLVisibilityResultMode)mode offset:(NSUInteger)offset {
    [self nvmtlCloseVisibility];
    if (mode == MTLVisibilityResultModeDisabled) return;
    if (!_visBuf || (offset & 7) || offset > _visBuf->_b.size ||
        _visBuf->_b.size - offset < sizeof(uint64_t) || offset > 262144) {
        [self nvmtlVisibilityError:[NSString stringWithFormat:@"visibility: invalid byte offset %zu", (size_t)offset]]; return;
    }
    _visOffset = offset; _visPending = YES;
    [self nvmtlBeginVisibility];
}
_Atomic uint64_t nvmtl_fm_views_made, nvmtl_fm_views_gone, nvmtl_fm_blit2tex;
static _Atomic int g_fm_on, g_fm_all, g_fm_final;
static void nvmtl_fm_stats_px(const uint8_t *px, uint32_t w, uint32_t h, uint32_t bpp, uint32_t fmt, unsigned frame, int kind, int att, const char *label, uint32_t draws, uint64_t ord, uint64_t cbseq);
static _Atomic uint64_t g_fm_ord;
// /tmp/nvmtl-passdump-request (consumed when seen): the next 96 render passes that drew have their colour attachment 0
// read back once their command buffer completes, to /tmp/nvmtl-pass-<pid>-<seq>-<w>x<h>-fmt<VkFormat>-bpp<b>.raw (rows
// packed, w*bpp bytes each), with one "passdump #seq" log line per pass giving its shape, so a black frame can be
// followed pass by pass (tools/arm64-probes/passdump2png.py renders them). Diagnostic: the readback's layout change on
// the image is not seen by the encoding thread, so the frames after a dump may glitch (2026-11-04).
// /tmp/nvmtl-flicker-request (consumed when seen): every render pass of the next NVMTL_FLICK_FRAMES presented frames has
// each colour attachment (and a 32-bit depth) read back after its command buffer completes - without disturbing its
// layout (nvmtl_vk_image_read_keep) - and reduced to statistics plus an 80x50 thumbnail, written to
// ~/Library/Logs/nvmtl/flick-<pid>/ with an index (index.txt: frame, pass sequence, label, attachment, format, the
// fraction of all-zero texels and the mean of each of the first four channels decoded from UNORM8 / FP16 / FP32 /
// R11G11B10). Comparing a black frame with a correct one finds the first pass where they part (2026-11-05: textures
// flickering between black and correct in Cyberpunk 2077's benchmark).
_Atomic unsigned nvmtl_flick_frame;
_Atomic int g_flk_armed; _Atomic unsigned g_flk_from, g_flk_seq;
// the compute side of the flicker capture: inside the armed window, a compute encoder's written textures (setTexture,
// useResource with a write usage) get the same statistics as a render pass's attachments, labelled with the encoder
// label and the last kernel
int nvmtl_flick_window(unsigned *frameOut);
void nvmtl_flick_compute(NVMTLCommandBuffer *cb, NSArray *textures, NSString *label, unsigned dispatches);
int nvmtl_flick_window(unsigned *frameOut)
{
    if (!atomic_load(&g_flk_armed)) return 0;
    const unsigned f = atomic_load(&nvmtl_flick_frame), s = atomic_load(&g_flk_from);
    if (f < s || f >= s + 6) return 0;
    *frameOut = f; return 1;
}
static void nvmtl_flick_record(nvk_queue *q, nvk_image *im, uint32_t frame, unsigned seq, int which, const char *label, uint32_t draws);
void nvmtl_flick_compute(NVMTLCommandBuffer *cb, NSArray *textures, NSString *label, unsigned dispatches)
{
    unsigned frame; if (!cb || !textures.count || !nvmtl_flick_window(&frame)) return;
    nvk_queue *q = cb->_queue ? &cb->_queue->_q : NULL; if (!q) return;
    NSMutableSet *seen = [NSMutableSet new]; int idx = 0;
    for (NVMTLTexture *t in textures) {
        nvk_image *im = [t nvi]; if (!im || [seen containsObject:[NSValue valueWithPointer:im]]) continue;
        [seen addObject:[NSValue valueWithPointer:im]];
        if (im->samples > 1 || !im->bpp || im->bpp > 16 || im->bw > 1 || (uint64_t)im->w * im->h < 16) continue;
        const unsigned s = atomic_fetch_add(&g_flk_seq, 1); const int wh = 1 + idx++; NSString *lbl = [label copy] ?: @""; NVMTLTexture *keep = t;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            (void)done; (void)keep;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ nvmtl_flick_record(q, im, frame, s, wh, lbl.UTF8String, dispatches); });
        }];
    }
}
static float nvmtl_h2f(uint16_t h) { uint32_t s = (h >> 15) & 1, e = (h >> 10) & 31, m = h & 1023; float v;
    if (!e) v = ldexpf((float)m, -24); else if (e == 31) v = m ? NAN : INFINITY; else v = ldexpf((float)(m | 1024), (int)e - 25); return s ? -v : v; }
static void nvmtl_flick_texel(const uint8_t *p, uint32_t fmt, uint32_t bpp, float out[4])
{
    out[0] = out[1] = out[2] = out[3] = 0;
    if (bpp == 8 && (fmt == 97 || fmt == 91)) { for (int i = 0; i < 4; i++) { uint16_t h; memcpy(&h, p + 2 * i, 2); out[i] = nvmtl_h2f(h); } return; }
    if (bpp == 16 && fmt == 109) { memcpy(out, p, 16); return; }
    if (bpp == 2 && fmt == 124) { uint16_t v; memcpy(&v, p, 2); out[0] = v / 65535.0f; return; }
    if (bpp == 4 && fmt == 122) { uint32_t v; memcpy(&v, p, 4);   // B10G11R11 UFLOAT
        uint32_t r = v & 0x7ff, g = (v >> 11) & 0x7ff, b = (v >> 22) & 0x3ff;
        out[0] = nvmtl_h2f((uint16_t)(r << 4)); out[1] = nvmtl_h2f((uint16_t)(g << 4)); out[2] = nvmtl_h2f((uint16_t)(b << 5)); return; }
    if (bpp == 4 && (fmt == 100 || fmt == 126)) { memcpy(out, p, 4); return; }
    if (bpp == 4 && fmt == 83) { for (int i = 0; i < 2; i++) { uint16_t h; memcpy(&h, p + 2 * i, 2); out[i] = nvmtl_h2f(h); } return; }
    if (bpp == 2 && fmt == 76) { uint16_t h; memcpy(&h, p, 2); out[0] = nvmtl_h2f(h); return; }
    for (uint32_t i = 0; i < bpp && i < 4; i++) out[i] = p[i] / 255.0f;
}
static void nvmtl_flick_record(nvk_queue *q, nvk_image *im, uint32_t frame, unsigned seq, int which, const char *label, uint32_t draws)
{
    const uint32_t w = im->w, h = im->h, bpp = im->bpp, fmt = im->fmt;
    const size_t row = (size_t)w * bpp; uint8_t *px = malloc(row * h); if (!px) return;
    if (nvmtl_vk_image_read_keep(q, im, px, row)) { free(px); return; }
    uint64_t zero = 0, nonfinite = 0; double sum[4] = { 0, 0, 0, 0 }; uint64_t n = 0;
    for (uint32_t y = 0; y < h; y += 2) for (uint32_t x = 0; x < w; x += 2) {
        const uint8_t *t = px + (size_t)y * row + (size_t)x * bpp; int z = 1;
        for (uint32_t b = 0; b < bpp; b++) if (t[b]) { z = 0; break; }
        zero += z; float f[4]; nvmtl_flick_texel(t, fmt, bpp, f);
        int bad = 0;
        for (int i = 0; i < 4; i++) { if (isfinite(f[i])) sum[i] += f[i]; else bad = 1; }
        nonfinite += bad;
        n++;
    }
    char dir[512]; snprintf(dir, sizeof dir, "%s/Library/Logs/nvmtl/flick-%d", getenv("HOME") ?: "/tmp", (int)getpid());
    mkdir(dir, 0755);
    char path[700]; snprintf(path, sizeof path, "%s/f%04u-%05u-%s%d-%ux%u-fmt%u-bpp%u.thumb", dir, frame, seq, which ? "c" : "ds", which ? which - 1 : 0, w, h, fmt, bpp);
    // full-size targets get a 320x200 thumbnail (a flickering object is a few dozen texels of it), the rest 80x50
    const uint32_t TW = w >= 1000 ? 320 : 80, TH = w >= 1000 ? 200 : 50;
    FILE *f = fopen(path, "wb");
    if (f) { fwrite(&TW, 4, 1, f); fwrite(&TH, 4, 1, f);
             for (uint32_t ty = 0; ty < TH; ty++) for (uint32_t tx = 0; tx < TW; tx++) {
                 const uint32_t x = (uint32_t)((uint64_t)tx * w / TW), y = (uint32_t)((uint64_t)ty * h / TH);
                 fwrite(px + (size_t)y * row + (size_t)x * bpp, 1, bpp, f); }
             fclose(f); }
    snprintf(path, sizeof path, "%s/index.txt", dir);
    f = fopen(path, "a");
    if (f) { fprintf(f, "frame %u seq %u '%s' draws %u %s%d %ux%u fmt %u bpp %u zero %.4f mean %.4f %.4f %.4f %.4f nonfinite %.4f\n", frame, seq, label, draws,
                     which ? "c" : "ds", which ? which - 1 : 0, w, h, fmt, bpp, n ? (double)zero / n : 0, n ? sum[0] / n : 0, n ? sum[1] / n : 0, n ? sum[2] / n : 0, n ? sum[3] / n : 0,
                     n ? (double)nonfinite / n : 0);
             fclose(f); }
    free(px);
}
static void nvmtl_fm_copy(NVMTLCommandBuffer *cb, nvk_image *im, unsigned frame, int kind, int att, NSString *label, uint32_t draws)
{
    if (!im || !im->img || im->samples > 1 || !im->bpp || im->bpp > 16 || im->bw > 1) return;
    const uint32_t w = im->w, h = im->h, bpp = im->bpp, fmt = im->fmt;
    nvk_buffer *b = calloc(1, sizeof *b); if (!b) return;
    if (nvmtl_vk_buffer_create((size_t)w * h * bpp, 1, b) || !b->map) { free(b); return; }
    if (nvmtl_vk_cmd_copy_image_to_buffer_layer(&cb->_c, im, 0, 0, w, h, b, 0, w * bpp, 0)) { nvmtl_vk_buffer_destroy(b); free(b); return; }
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        const BOOL ok = done.status == MTLCommandBufferStatusCompleted;
        const uint64_t ord = atomic_fetch_add(&g_fm_ord, 1), cbseq = ((NVMTLCommandBuffer *)done)->_commitSeq;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (ok) nvmtl_fm_stats_px((const uint8_t *)b->map, w, h, bpp, fmt, frame, kind, att, label.UTF8String, draws, ord, cbseq);
            nvmtl_vk_buffer_destroy(b); free(b);
        });
    }];
}
// The G-buffer is filled by several passes (the first clears it, later ones load and add); it is complete when the
// first full-width B10G11R11 (lighting) pass has run, so the latest 3+-attachment pass's images are copied right after
// that pass, inside the same command buffer.
- (void)nvmtlFlickMonitor {
    if (atomic_load(&g_fm_all)) {
        static _Atomic unsigned allFrame = ~0u, allPass;
        const unsigned fr = atomic_load(&nvmtl_flick_frame);
        if (atomic_exchange(&allFrame, fr) != fr) atomic_store(&allPass, 0);
        if (!_pass.col[0] || _pass.col[0]->w < 800 || !_passDraws) return;
        if (atomic_load(&g_fm_final)) {
            if (_pass.col[0]->fmt != 44) return;
            nvmtl_fm_copy(_cb, _pass.col[0], fr, 200, 0, [_label copy] ?: @"", _passDraws);
            return;
        }
        const unsigned k = atomic_fetch_add(&allPass, 1); if (k > 90) return;
        static int anyFmt = -1; if (anyFmt < 0) { const char *e = getenv("NVMTL_PASSCAP_ALLFMT"); anyFmt = e && e[0] == '1'; }
        if (!anyFmt && _pass.col[0]->fmt != 58 && _pass.col[0]->fmt != 44) return;
        NSString *label = [_label copy] ?: @"";
        for (int i = 0, n = 0; i < NVMTL_NCOL && n < 4; i++) if (_pass.col[i]) { n++;
            if (anyFmt && (_pass.col[i]->fmt == 9 || _pass.col[i]->fmt == 98)) continue;
            nvmtl_fm_copy(_cb, _pass.col[i], fr, 100 + (int)k, i, label, _passDraws); }
        return;
    }
    static _Atomic unsigned curFrame = ~0u, litTaken;
    static nvk_image *_Atomic gb[3]; static _Atomic uint32_t gbDraws;
    const unsigned frame = atomic_load(&nvmtl_flick_frame);
    if (atomic_exchange(&curFrame, frame) != frame) atomic_store(&litTaken, 0);
    if (!_pass.col[0] || _pass.col[0]->w < 800) return;
    unsigned ncol = 0; for (unsigned i = 0; i < NVMTL_NCOL; i++) if (_pass.col[i]) ncol++;
    if (ncol >= 3) {
        for (int i = 0, n = 0; i < NVMTL_NCOL && n < 3; i++) if (_pass.col[i]) atomic_store(&gb[n++], _pass.col[i]);
        atomic_fetch_add(&gbDraws, _passDraws);
        return;
    }
    if (_pass.col[0]->fmt != 122 || _passDraws < 1 || atomic_exchange(&litTaken, 1)) return;
    NSString *label = [_label copy] ?: @"";
    nvmtl_fm_copy(_cb, _pass.col[0], frame, 1, 0, label, _passDraws);
    const uint32_t gd = atomic_exchange(&gbDraws, 0);
    for (int i = 0; i < 3; i++) nvmtl_fm_copy(_cb, atomic_load(&gb[i]), frame, 0, i, @"gbuffer at lighting", gd);
}
- (void)nvmtlFlickerCapture {
    enum { NVMTL_FLICK_FRAMES = 6 };
    _Atomic int *const armed_ = &g_flk_armed; _Atomic unsigned *const from_ = &g_flk_from; static uint64_t next; _Atomic unsigned *const seq_ = &g_flk_seq;
#define armed (*armed_)
#define from (*from_)
#define seq (*seq_)
    const uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    if (now >= next) { next = now + 250000000ull;
        if (!armed && access("/tmp/nvmtl-flicker-request", F_OK) == 0) { unlink("/tmp/nvmtl-flicker-request");
            atomic_store(&from, atomic_load(&nvmtl_flick_frame) + 1); atomic_store(&armed, 1);
            nvlog("flicker capture: armed for frames %u..%u", atomic_load(&from), atomic_load(&from) + NVMTL_FLICK_FRAMES - 1); } }
    if (!armed) return;
    const unsigned frame = atomic_load(&nvmtl_flick_frame);
    if (frame < atomic_load(&from)) return;
    if (frame >= atomic_load(&from) + NVMTL_FLICK_FRAMES) { atomic_store(&armed, 0); nvlog("flicker capture: done"); return; }
    nvk_queue *q = _cb && _cb->_queue ? &_cb->_queue->_q : NULL; if (!q) return;
    const unsigned s = atomic_fetch_add(&seq, 1);
    NSString *label = [_label copy] ?: @""; const uint32_t draws = _passDraws; NVMTLTexture *keep = _target;
    for (int which = 0; which < 1 + NVMTL_NCOL; which++) {
        nvk_image *im = which ? _pass.col[which - 1] : _pass.ds; if (!im) continue;
        if (!which && im->fmt != 126 && im->fmt != 124 && im->fmt != 129 && im->fmt != 130) continue;
        if (im->samples > 1 || !im->bpp || im->bpp > 16 || im->bw > 1 || (uint64_t)im->w * im->h < 16) continue;
        if (!which && im->bpp != 4 && !(im->bpp == 2 && im->fmt == 124)) continue;
        const int wh = which;
        [_cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            (void)done; (void)keep;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ nvmtl_flick_record(q, im, frame, s, wh, label.UTF8String, draws); });
        }];
    }
}
#undef armed
#undef from
#undef seq
- (void)nvmtlPassDump {
    static _Atomic int left; static uint64_t next; static _Atomic unsigned seq;
    const uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    if (now >= next) { next = now + 250000000ull;
        if (left <= 0 && access("/tmp/nvmtl-passdump-request", F_OK) == 0) { unlink("/tmp/nvmtl-passdump-request"); left = 96; nvlog("passdump: armed for the next 96 drawing passes"); } }
    if (left <= 0) return;
    left--;
    const unsigned n = atomic_fetch_add(&seq, 1);
    nvk_image *img = _pass.col[0]; NVMTLTexture *t = _target;
    unsigned ncol = 0; for (unsigned i = 0; i < NVMTL_NCOL; i++) if (_pass.col[i]) ncol++;
    nvk_image *ds = _pass.ds;
    char rec[512]; snprintf(rec, sizeof rec,
          "passdump #%u '%s' pass %ux%u ncol %u load 0x%x draws %u col0 %ux%u fmt %u bpp %u samples %u | ds %ux%u fmt %u bpp %u clear %.3f | "
          "dss %s write %d compare %d | pso %s | vp %s%.0f,%.0f %.0fx%.0f z %.3f..%.3f | sc %s%u,%u %ux%u | cull %d",
          n, _label.UTF8String ?: "", _pass.w, _pass.h, ncol, _pass.load, _passDraws, img ? img->w : 0, img ? img->h : 0, img ? img->fmt : 0,
          img ? img->bpp : 0, img ? img->samples : 0, ds ? ds->w : 0, ds ? ds->h : 0, ds ? ds->fmt : 0, ds ? ds->bpp : 0, _pass.clear_depth,
          _ds ? "set" : "none", _ds ? _ds->_write : 0, _ds ? _ds->_compare : 7, _ps ? ([_ps respondsToSelector:@selector(label)] && [(id)_ps label] ? [[(id)_ps label] UTF8String] : "unlabelled") : "none",
          _hasVP ? "" : "(default) ", _vp[0], _vp[1], _vp[2], _vp[3], _vp[4], _vp[5], _hasSC ? "" : "(default) ", _sc[0], _sc[1], _sc[2], _sc[3], _cull);
    if (n < 8) nvlog("%s", rec);   // the log rate-limits bursts; the whole list goes to /tmp/nvmtl-passdump-<pid>.txt
    { char path[128]; snprintf(path, sizeof path, "/tmp/nvmtl-passdump-%d.txt", (int)getpid());
      FILE *f = fopen(path, "a"); if (f) { fprintf(f, "%s\n", rec); fclose(f); } }
    nvk_queue *q = _cb && _cb->_queue ? &_cb->_queue->_q : NULL; NVMTLTexture *keep = t; if (!q) return;
    for (int which = 0; which < 1 + NVMTL_NCOL; which++) {   // 0: depth, 1..: colour attachments 0..
        nvk_image *im = which ? _pass.col[which - 1] : ds; if (!im) continue;
        // depth: only the 32-bit-per-texel depth formats (D32F, X8_D24, D24S8 / D32S8's depth aspect) read back as rows of 4 B texels
        if (!which && im->fmt != 126 && im->fmt != 124 && im->fmt != 129 && im->fmt != 130) continue;
        if (im->samples > 1 || !im->bpp || im->bpp > 16 || im->bw > 1 || (uint64_t)im->w * im->h < 16) continue;
        if (!which && im->bpp != 4) continue;
        const uint32_t w = im->w, h = im->h, bpp = im->bpp, fmt = im->fmt; const int isds = !which; const int ci = which ? which - 1 : 0;
        [_cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            (void)done;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                (void)keep; const size_t row = (size_t)w * bpp; void *px = malloc(row * h); if (!px) return;
                if (nvmtl_vk_image_read(q, im, px, row)) nvlog("passdump #%u%s: readback FAILED", n, isds ? " depth" : "");
                else {
                    char path[256]; snprintf(path, sizeof path, "/tmp/nvmtl-pass-%d-%03u%s%d-%ux%u-fmt%u-bpp%u.raw", (int)getpid(), n, isds ? "ds" : "c", isds ? 0 : ci, w, h, fmt, bpp);
                    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
                    if (fd >= 0) { ssize_t wr = write(fd, px, row * h); (void)wr; close(fd); }
                    else nvlog("passdump #%u: open %s failed (errno %d)", n, path, errno);
                }
                free(px);
            });
        }];
    }
}
- (void)endEncoding {
    nvmtl_enc_end();
    _cb->_nEnd++;
    if (_dumpPso) { _dumpPso = NO; [self nvmtlDumpBoundFragmentBuffers]; }
    [self nvmtlCloseVisibility];
    if (_begun) nvmtl_vk_cmd_end_render(&_cb->_c);
    if (_begun && _ppBuf) { if (_ppAfter) nvmtl_pp_take(self, -2); _ppAfter = NO; nvmtl_pp_flush(self); }
    if (_begun && _pass.ds && (_pass.ds->fmt == 130 || _pass.ds->fmt == 129) && _pass.ds->w >= 800 && nvmtl_pp_active()) {
        nvk_image *dsi = _pass.ds; nvk_buffer *sb = calloc(1, sizeof *sb);
        if (sb && !nvmtl_vk_buffer_create(4 * 224, 1, sb) && sb->map) {
            memset(sb->map, 0xCD, 4 * 224);
            extern void nvmtl_vk_copy_aspect_override(uint32_t, uint32_t);
            nvmtl_vk_copy_aspect_override(4u, 1u);
            for (int k = 0; k < g_pp_n && k < 4; k++) if ((uint32_t)g_pp_y[k] < dsi->h && (uint32_t)g_pp_x[k] + 224 <= dsi->w)
                nvmtl_vk_cmd_copy_image_to_buffer_level_layer(&_cb->_c, dsi, (uint32_t)g_pp_x[k], (uint32_t)g_pp_y[k], 224, 1, sb, (size_t)k * 224, 224, 0, 0);
            nvmtl_vk_copy_aspect_override(0u, 0u);
            const unsigned fr = atomic_load(&nvmtl_flick_frame); const uint32_t draws = _passDraws, ld = _load, cs = _pass.clear_stencil, ncol = (_pass.col[0] ? 1u : 0u) + (_pass.col[1] ? 1u : 0u) + (_pass.col[2] ? 1u : 0u) + (_pass.col[3] ? 1u : 0u);
            const uint32_t c0f = _pass.col[0] ? _pass.col[0]->fmt : 0u, hs = _ps ? _ps->_p.has_stencil : 9u, df = _ps ? _ps->_p.dfmt : 0u; void *img = dsi->img;
            NSString *lbl = [_label copy] ?: @""; static _Atomic unsigned seqn; const unsigned sq = atomic_fetch_add(&seqn, 1);
            [_cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
                const uint8_t *g = (const uint8_t *)sb->map; char out[4][96];
                for (int k = 0; k < 4; k++) { int z = 0, t20 = 0, lo = 0, hi = 0, cd = 0, oth = 0; uint8_t ov = 0;
                    for (int x = 0; x < 224; x++) { uint8_t v = g[k * 224 + x]; if (v == 0xCD) cd++; else if (!v) z++; else if (v == 20) t20++; else if ((v & 31) <= 11) lo++; else { hi++; ov = v; } (void)oth; }
                    snprintf(out[k], sizeof out[k], "r%d[0:%d 20:%d lo:%d hi:%d(e.g.%u) cd:%d]", k, z, t20, lo, hi, ov, cd); }
                nvlog_diag("stenpass f%u #%u img %p '%s' draws %u ncol %u c0fmt %u load 0x%x clearS %u lastPipe hasS %u dfmt %u | %s %s %s %s", fr, sq, img, lbl.UTF8String, draws, ncol, c0f, ld, cs, hs, df, out[0], out[1], out[2], out[3]);
                nvmtl_vk_buffer_destroy(sb); free(sb); }];
        } else if (sb) free(sb);
    }
    if (_begun) [self nvmtlPassDump];
    // NVMTL_PASSLIST=<n>: one log line for each of the first n render passes that began (label, size, attachments with
    // their layer, draws), to see which passes a frame has and where a texture array is written (diagnostic)
    { static int lim = -1; static _Atomic int done; if (lim < 0) { const char *e = getenv("NVMTL_PASSLIST"); lim = e ? atoi(e) : 0; }
      if (lim > 0 && _begun && atomic_fetch_add(&done, 1) < lim) {
          char at[512]; int k = 0;
          for (unsigned i = 0; i < NVMTL_NCOL && k < (int)sizeof at - 64; i++) if (_pass.col[i])
              k += snprintf(at + k, sizeof at - k, " c%u %ux%ux%u fmt %u L%u", i, _pass.col[i]->w, _pass.col[i]->h, _pass.col[i]->layers, _pass.col[i]->fmt, _pass.col_layer[i]);
          if (_pass.ds) k += snprintf(at + k, sizeof at - k, " ds %ux%ux%u fmt %u L%u", _pass.ds->w, _pass.ds->h, _pass.ds->layers, _pass.ds->fmt, _pass.ds_layer);
          nvlog_diag("passlist f%u '%s' %ux%u draws %u load 0x%x%s", atomic_load(&nvmtl_flick_frame), _label.UTF8String ?: "", _pass.w, _pass.h, _passDraws, _pass.load, at);
      } }
    if (_begun) [self nvmtlFlickerCapture];
    if (_begun && atomic_load(&g_fm_on)) [self nvmtlFlickMonitor];
    NSMutableDictionary *groups = [NSMutableDictionary new];
    BOOL needScratch = NO;
    for (NSArray *record in _visRecords) {
        NSNumber *offset = record[1];
        NSMutableArray *queries = groups[offset];
        if (!queries) { queries = [NSMutableArray new]; groups[offset] = queries; }
        [queries addObject:record[0]];
        if (queries.count > 1) needScratch = YES;
    }
    NVMTLBuffer *scratch = nil;
    if (needScratch) {
        scratch = [NVMTLBuffer new];
        if (nvmtl_vk_buffer_create(_visRecords.count * 8, 0, &scratch->_b)) {
            [self nvmtlVisibilityError:[NSString stringWithFormat:@"visibility: accumulation scratch allocation failed"]]; scratch = nil;
        } else {
            if (!_cb->_scratch) _cb->_scratch = [NSMutableArray new];
            [_cb->_scratch addObject:scratch];
        }
    }
    size_t cursor = 0;
    for (NSNumber *key in groups) {
        NSArray *queries = groups[key]; size_t offset = key.unsignedLongLongValue;
        if (queries.count > 1 && !scratch) continue;
        nvk_buffer *dst = queries.count > 1 ? &scratch->_b : &_visBuf->_b;
        size_t first = cursor;
        for (NSNumber *value in queries) {
            uint32_t query = value.unsignedIntValue;
            size_t out = queries.count > 1 ? cursor++ * 8 : offset;
            if (query == UINT32_MAX) {
                if (nvmtl_vk_cmd_write_word(&_cb->_c, dst, out, 0) ||
                    nvmtl_vk_cmd_write_word(&_cb->_c, dst, out + 4, 0))
                    [self nvmtlVisibilityError:[NSString stringWithFormat:@"visibility: empty result write failed at offset %zu", out]];
            } else if (nvmtl_vk_cmd_copy_occlusion(&_cb->_c, query, 1, dst, out))
                [self nvmtlVisibilityError:[NSString stringWithFormat:@"visibility: result copy failed at offset %zu", out]];
        }
        if (queries.count > 1 && nvmtl_vk_cmd_sum_occlusion(&_cb->_c, &scratch->_b, first,
                                                          (uint32_t)queries.count, &_visBuf->_b, offset))
            [self nvmtlVisibilityError:[NSString stringWithFormat:@"visibility: accumulation failed at offset %zu", offset]];
    }
    _visRecords = nil;
    if (_begun) return;
    if (_refused) return;
    switch (nvmtl_vk_pass_kind(&_pass)) {
        case 1: { static int said; if (!said++) nvlog("encoder: apps2 a pass with no draws loads everything and resolves nothing — left untouched"); return; }
        case 2:
            if (nvmtl_vk_cmd_empty_pass(&_cb->_c, &_pass)) nvlog("encoder: apps2 empty pass FAILED — its clears and resolves are NOT applied");
            else { static int said; if (said++ < 4) nvlog("encoder: apps2 empty pass (the clears/resolves of a pass with no draws)"); }
            if (_resolve) { NVMTLTexture *rs = _resolve->_parent ? _resolve->_parent : _resolve; if (rs->_surf) nvmtl_surf_dirty(_cb, rs); }
            return;
        default: break;
    }
    if (_load & 1u) { static int said; if (!said++) nvlog("encoder: a Load pass with no draws — target left untouched"); return; }
    if (_target && nvmtl_vk_cmd_clear_image(&_cb->_c, [_target nvi], _clear))
        nvlog("encoder: clear-only pass FAILED");
    else if (_target)
        nvlog("encoder: clear-only pass (%.2f %.2f %.2f %.2f)", _clear[0], _clear[1], _clear[2], _clear[3]);
}
- (void)setViewport:(MTLViewport)v {
    nvtrace("VP %.4g %.4g %.4g %.4g z %.3g %.3g", v.originX, v.originY, v.width, v.height, v.znear, v.zfar);
    _vp[0] = (float)v.originX; _vp[1] = (float)v.originY; _vp[2] = (float)v.width; _vp[3] = (float)v.height; _vp[4] = (float)v.znear; _vp[5] = (float)v.zfar; _hasVP = YES;
    if (_begun) nvmtl_vk_cmd_set_viewport(&_cb->_c, _vp[0], _vp[1], _vp[2], _vp[3], _vp[4], _vp[5]);
}
- (void)setViewports:(const MTLViewport *)v count:(NSUInteger)n { if (v && n) [self setViewport:v[0]]; }
- (void)setScissorRects:(const MTLScissorRect *)r count:(NSUInteger)n { if (r && n) [self setScissorRect:r[0]]; }
- (void)setScissorRect:(MTLScissorRect)r {
    nvtrace("SC %lu %lu %lu %lu", (unsigned long)r.x, (unsigned long)r.y, (unsigned long)r.width, (unsigned long)r.height);
    _sc[0] = (uint32_t)r.x; _sc[1] = (uint32_t)r.y; _sc[2] = (uint32_t)r.width; _sc[3] = (uint32_t)r.height; _hasSC = YES;
    if (!_begun) return;
    nvmtl_vk_cmd_set_scissor(&_cb->_c, (int32_t)r.x, (int32_t)r.y, (uint32_t)r.width, (uint32_t)r.height);
}
- (void)setCullMode:(MTLCullMode)mode {
    _cull = (_cull & 4) | (mode == MTLCullModeFront ? 1 : mode == MTLCullModeBack ? 2 : 0);
    if (_begun) nvmtl_vk_cmd_set_cull(&_cb->_c, _cull);
}
- (void)setFrontFacingWinding:(MTLWinding)w {
    _cull = (_cull & 3) | (w == MTLWindingCounterClockwise ? 4 : 0);
    if (_begun) nvmtl_vk_cmd_set_cull(&_cb->_c, _cull);
}
- (void)executeCommandsInBuffer:(id<MTLIndirectCommandBuffer>)icb withRange:(NSRange)r {
    NVMTLIndirectCommandBuffer *b = (NVMTLIndirectCommandBuffer *)icb;
    if (!b) { nvlog("executeCommandsInBuffer: nil"); return; }
    NSUInteger n = 0;
    for (NSUInteger i = r.location; i < r.location + r.length && i < b->_cmds.count; i++) {
        NVMTLIndirectCommand *c = b->_cmds[i];
        if (!c->_armed || c->_isCompute) continue;
        if (c->_ps) [self setRenderPipelineState:c->_ps];
        if (c->_hasCull) [self setCullMode:c->_cull];
        if (c->_hasWinding) [self setFrontFacingWinding:c->_winding];
        if (c->_hasFill) [self setTriangleFillMode:c->_fill];
        if (c->_hasClip) [self setDepthClipMode:c->_clip];
        if (c->_ds) [self setDepthStencilState:c->_ds];
        if (c->_hasBias) [self setDepthBias:c->_bias slopeScale:c->_slope clamp:c->_clamp];
        for (NSArray *e in c->_vbufs) {
            if (e.count > 3) [self setVertexBuffer:e[0] offset:[e[1] unsignedLongValue] attributeStride:[e[3] unsignedLongValue] atIndex:[e[2] unsignedLongValue]];
            else [self setVertexBuffer:e[0] offset:[e[1] unsignedLongValue] atIndex:[e[2] unsignedLongValue]]; }
        for (NSArray *e in c->_fbufs) [self setFragmentBuffer:e[0] offset:[e[1] unsignedLongValue] atIndex:[e[2] unsignedLongValue]];
        if (c->_indexed)
            [self drawIndexedPrimitives:c->_type indexCount:c->_count indexType:c->_itype indexBuffer:c->_ibuf
                      indexBufferOffset:c->_ioff instanceCount:c->_instances baseVertex:c->_baseVertex baseInstance:c->_baseInstance];
        else
            [self drawPrimitives:c->_type vertexStart:c->_start vertexCount:c->_count
                   instanceCount:c->_instances baseInstance:c->_baseInstance];
        n++;
    }
    nvlog("executeCommandsInBuffer: replayed %lu of %lu slot(s)", (unsigned long)n, (unsigned long)r.length);
}
- (void)setDepthClipMode:(MTLDepthClipMode)mode {
    if (nvmtl_vk_cmd_set_depth_clip(&_cb->_c, mode == MTLDepthClipModeClip))
        nvlog("setDepthClipMode:%lu REFUSED — VK_EXT_depth_clip_enable is not enabled on this device",
              (unsigned long)mode);
}
- (void)setTriangleFillMode:(MTLTriangleFillMode)mode {
    if (nvmtl_vk_cmd_set_polygon_mode(&_cb->_c, mode == MTLTriangleFillModeLines))
        nvlog("setTriangleFillMode:%lu REFUSED — VK_EXT_extended_dynamic_state3 is not enabled on this device",
              (unsigned long)mode);
}
- (void)setDepthStencilState:(id<MTLDepthStencilState>)s {
    _ds = (NVMTLDepthStencilState *)s;
    [self nvmtlApplyDepthStencil];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexCount:(NSUInteger)count indexType:(MTLIndexType)it
                  indexBuffer:(id<MTLBuffer>)ib indexBufferOffset:(NSUInteger)off
                instanceCount:(NSUInteger)instances baseVertex:(NSInteger)baseVertex baseInstance:(NSUInteger)baseInstance {
    if (!_begun) { nvlog("drawIndexedPrimitives with no pipeline set"); return; }
    NVMTLBuffer *b = (NVMTLBuffer *)ib;
    if (!b) { nvlog("drawIndexedPrimitives with no index buffer"); return; }
    nvmtl_retain_resource(_cb, b);
    _ppKind = 2; _ppA[0] = count; _ppA[1] = instances; _ppA[2] = (uint64_t)baseVertex; _ppA[3] = baseInstance; _ppA[4] = off;
    if (![self nvmtlBindSamplerPipeline]) return;
    nvtrace("DRAW type %u | vs %s | fs %s | blend %s", (unsigned)type, _ps ? _ps->_vname.UTF8String : "-", _ps ? _ps->_fname.UTF8String : "-", _ps ? _ps->_blend.UTF8String : "-");
    if (nvmtl_trace_on()) { char bufs_[600]; nvmtl_vk_trace_buffers(&_cb->_c, bufs_, sizeof bufs_); nvtrace("  BUFS%s", bufs_); }
    if (nvmtl_vk_cmd_set_topology(&_cb->_c, (unsigned)type)) return;
    if ([self nvmtlVertexInputs]) return;
    nvtrace("  indexed count %lu u32 %d off %lu instances %lu baseVertex %ld", (unsigned long)count, it == MTLIndexTypeUInt32, (unsigned long)off, (unsigned long)instances, (long)baseVertex);
    nvmtl_vk_cmd_draw_indexed(&_cb->_c, &b->_b, off, (uint32_t)count, it == MTLIndexTypeUInt32,
                              (uint32_t)instances, (int32_t)baseVertex, (uint32_t)baseInstance);
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexCount:(NSUInteger)n indexType:(MTLIndexType)it
                  indexBuffer:(id<MTLBuffer>)ib indexBufferOffset:(NSUInteger)off instanceCount:(NSUInteger)i {
    [self drawIndexedPrimitives:t indexCount:n indexType:it indexBuffer:ib indexBufferOffset:off
                  instanceCount:i baseVertex:0 baseInstance:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexCount:(NSUInteger)n indexType:(MTLIndexType)it
                  indexBuffer:(id<MTLBuffer>)ib indexBufferOffset:(NSUInteger)off {
    [self drawIndexedPrimitives:t indexCount:n indexType:it indexBuffer:ib indexBufferOffset:off
                  instanceCount:1 baseVertex:0 baseInstance:0];
}

- (void)setStencilReferenceValue:(uint32_t)ref { nvmtl_vk_cmd_set_stencil_ref(&_cb->_c, ref, ref); _hasRef = YES; }
- (void)setStencilFrontReferenceValue:(uint32_t)f backReferenceValue:(uint32_t)b { nvmtl_vk_cmd_set_stencil_ref(&_cb->_c, f, b); _hasRef = YES; }
- (void)setDepthBias:(float)bias slopeScale:(float)slope clamp:(float)clamp { nvmtl_vk_cmd_set_depth_bias(&_cb->_c, bias, slope, clamp); }
- (void)setBlendColorRed:(float)r green:(float)g blue:(float)b alpha:(float)a {
    float rgba[4] = { r, g, b, a }; nvmtl_vk_cmd_set_blend_color(&_cb->_c, rgba);
}
- (void)setVertexBufferOffset:(NSUInteger)off atIndex:(NSUInteger)i {
    nvtrace("VBOFF[%lu] -> %lu", (unsigned long)i, (unsigned long)off);
    if (i < NVMTL_NBUFAT && _vbufAt[i]) { _vbufOff[i] = off; nvmtl_lw_note(_cb, _vbufAt[i], off); }
    if (nvmtl_vk_bind_buffer_offset(&_cb->_c, NVMTL_SET_VERTEX, (uint32_t)i, off))
        nvlog("setVertexBufferOffset: nothing bound at vertex index %lu", (unsigned long)i);
}
- (void)nvmtlVertexStride:(NSUInteger)st atIndex:(NSUInteger)i {
    if (i >= NVMTL_NVIN) { nvlog("apps-dyn: attributeStride at vertex buffer index %lu is outside [0,%d) — ignored", (unsigned long)i, NVMTL_NVIN); return; }
    if (st == MTLAttributeStrideStatic) { _vstrideSet &= ~(1u << i); return; }
    if (st > UINT32_MAX) { nvlog("apps-dyn: attributeStride %lu at vertex buffer index %lu does not fit — the index keeps NO stride", (unsigned long)st, (unsigned long)i);
        _vstrideSet &= ~(1u << i); return; }
    _vstride[i] = (uint32_t)st; _vstrideSet |= 1u << i;
    nvtrace("VBSTRIDE[%lu] -> %lu", (unsigned long)i, (unsigned long)st);
}
- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)off attributeStride:(NSUInteger)st atIndex:(NSUInteger)i {
    [self setVertexBuffer:b offset:off atIndex:i]; [self nvmtlVertexStride:st atIndex:i]; }
- (void)setVertexBufferOffset:(NSUInteger)off attributeStride:(NSUInteger)st atIndex:(NSUInteger)i {
    [self setVertexBufferOffset:off atIndex:i]; [self nvmtlVertexStride:st atIndex:i]; }
- (void)setVertexBuffers:(const id<MTLBuffer> __unsafe_unretained [])bufs offsets:(const NSUInteger *)offs
        attributeStrides:(const NSUInteger *)sts withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) if (bufs[k])
        [self setVertexBuffer:bufs[k] offset:offs ? offs[k] : 0 attributeStride:sts ? sts[k] : MTLAttributeStrideStatic atIndex:r.location + k]; }
- (void)setVertexBytes:(const void *)b length:(NSUInteger)l attributeStride:(NSUInteger)st atIndex:(NSUInteger)i {
    [self setVertexBytes:b length:l atIndex:i]; [self nvmtlVertexStride:st atIndex:i]; }
- (void)setFragmentBufferOffset:(NSUInteger)off atIndex:(NSUInteger)i {
    nvtrace("FBOFF[%lu] -> %lu", (unsigned long)i, (unsigned long)off);
    if (i < NVMTL_NBUFAT && _fbufAt[i]) { _fbufOff[i] = off; nvmtl_lw_note(_cb, _fbufAt[i], off); }
    if (nvmtl_vk_bind_buffer_offset(&_cb->_c, NVMTL_SET_FRAGMENT, (uint32_t)i, off))
        nvlog("setFragmentBufferOffset: nothing bound at fragment index %lu", (unsigned long)i);
}
- (void)setVertexBuffers:(const id<MTLBuffer> __unsafe_unretained [])bufs offsets:(const NSUInteger *)offs withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) if (bufs[k]) [self setVertexBuffer:bufs[k] offset:offs ? offs[k] : 0 atIndex:r.location + k];
}
- (void)setFragmentBuffers:(const id<MTLBuffer> __unsafe_unretained [])bufs offsets:(const NSUInteger *)offs withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) if (bufs[k]) [self setFragmentBuffer:bufs[k] offset:offs ? offs[k] : 0 atIndex:r.location + k];
}
- (void)setVertexTextures:(const id<MTLTexture> __unsafe_unretained [])t withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) if (t[k]) [self setVertexTexture:t[k] atIndex:r.location + k];
}
- (void)setFragmentTextures:(const id<MTLTexture> __unsafe_unretained [])t withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) if (t[k]) [self setFragmentTexture:t[k] atIndex:r.location + k];
}
- (void)setVertexSamplerStates:(const id<MTLSamplerState> __unsafe_unretained [])ss withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) [self setVertexSamplerState:ss[k] atIndex:r.location + k];
}
- (void)setFragmentSamplerStates:(const id<MTLSamplerState> __unsafe_unretained [])ss withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) [self setFragmentSamplerState:ss[k] atIndex:r.location + k];
}
- (void)setFragmentSamplerState:(id<MTLSamplerState>)ss lodMinClamp:(float)lo lodMaxClamp:(float)hi atIndex:(NSUInteger)i {
    [self setFragmentSamplerState:ss atIndex:i];
    NSString *key=[@(i) stringValue];
    if(_fragmentSamplers[key]) {
        NSMutableDictionary *state=[_fragmentSamplers[key] mutableCopy];
        state[@"lod_min_clamp"]=@(lo);state[@"lod_max_clamp"]=@(hi);
        if (nvmtl_pixel_sampler_update(_fragmentSamplers,key,state)) _pixelSamplerKey=nil;
    }
}
- (void)setVertexSamplerState:(id<MTLSamplerState>)ss lodMinClamp:(float)lo lodMaxClamp:(float)hi atIndex:(NSUInteger)i {
    [self setVertexSamplerState:ss atIndex:i];
    NSString *key=[@(i) stringValue];
    if(_vertexSamplers[key]) {
        NSMutableDictionary *state=[_vertexSamplers[key] mutableCopy];
        state[@"lod_min_clamp"]=@(lo);state[@"lod_max_clamp"]=@(hi);
        if (nvmtl_pixel_sampler_update(_vertexSamplers,key,state)) _pixelSamplerKey=nil;
    }
}
- (void)setFragmentSamplerStates:(const id<MTLSamplerState> __unsafe_unretained [])ss lodMinClamps:(const float *)lo lodMaxClamps:(const float *)hi withRange:(NSRange)r {
    for(NSUInteger k=0;k<r.length;k++) [self setFragmentSamplerState:ss[k] lodMinClamp:lo[k] lodMaxClamp:hi[k] atIndex:r.location+k];
}
- (void)setVertexSamplerStates:(const id<MTLSamplerState> __unsafe_unretained [])ss lodMinClamps:(const float *)lo lodMaxClamps:(const float *)hi withRange:(NSRange)r {
    for(NSUInteger k=0;k<r.length;k++) [self setVertexSamplerState:ss[k] lodMinClamp:lo[k] lodMaxClamp:hi[k] atIndex:r.location+k];
}
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u { nvmtl_retain_resource(_cb, r); }
- (void)useHeaps:(const id<MTLHeap> __unsafe_unretained [])h count:(NSUInteger)n { atomic_fetch_add(&g_h_useheap, n); }
- (void)useHeaps:(const id<MTLHeap> __unsafe_unretained [])h count:(NSUInteger)n stages:(MTLRenderStages)st { atomic_fetch_add(&g_h_useheap, n); nvtrace("USEHEAPS %lu stages %lu", (unsigned long)n, (unsigned long)st); }
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u stages:(MTLRenderStages)st { nvmtl_retain_resource(_cb, r);
    if ([r isKindOfClass:[NVMTLTexture class]]) { NVMTLTexture *t = (NVMTLTexture *)r; nvk_image *im = [t nvi];
        nvtrace("USERES NVMTLTexture %p(img %p parent %p heap %p+%lu) %lux%lu mips %lu fmt %lu placed %d usage %lu stages %lu", (__bridge void *)r, im ? im->img : NULL, (__bridge void *)t->_viewParent,
                (__bridge void *)t->_heap, (unsigned long)t->_heapOffset, (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.mipmapLevelCount, (unsigned long)t.pixelFormat, im ? im->placed : 0, (unsigned long)u, (unsigned long)st); }
    else nvtrace("USERES %s %p usage %lu stages %lu", object_getClassName(r), (__bridge void *)r, (unsigned long)u, (unsigned long)st); }
- (void)useResources:(const id<MTLResource> __unsafe_unretained [])r count:(NSUInteger)n usage:(MTLResourceUsage)u { for (NSUInteger i=0;i<n;i++) nvmtl_retain_resource(_cb,r[i]); }
- (void)useResources:(const id<MTLResource> __unsafe_unretained [])r count:(NSUInteger)n usage:(MTLResourceUsage)u stages:(MTLRenderStages)st { for (NSUInteger i=0;i<n;i++) nvmtl_retain_resource(_cb,r[i]); nvtrace("USERES x%lu usage %lu stages %lu", (unsigned long)n, (unsigned long)u, (unsigned long)st); }
- (void)useHeap:(id<MTLHeap>)h { atomic_fetch_add(&g_h_useheap, 1); }
- (void)useHeap:(id<MTLHeap>)h stages:(MTLRenderStages)st { atomic_fetch_add(&g_h_useheap, 1); }
- (void)sampleCountersInBuffer:(id)sb atSampleIndex:(NSUInteger)i withBarrier:(BOOL)b { nvmtl_sample_counter(_cb, sb, i, self, b); }
- (void)textureBarrier { nvmtl_vk_cmd_barrier(&_cb->_c); }
- (void)updateFence:(id<MTLFence>)f afterStages:(MTLRenderStages)st {}
- (void)waitForFence:(id<MTLFence>)f beforeStages:(MTLRenderStages)st { nvmtl_vk_cmd_barrier(&_cb->_c); }
- (void)memoryBarrierWithScope:(MTLBarrierScope)scope afterStages:(MTLRenderStages)a beforeStages:(MTLRenderStages)b { nvmtl_vk_cmd_barrier(&_cb->_c); }
- (void)memoryBarrierWithResources:(const id<MTLResource> __unsafe_unretained [])r count:(NSUInteger)n afterStages:(MTLRenderStages)a beforeStages:(MTLRenderStages)b { nvmtl_vk_cmd_barrier(&_cb->_c); }
- (void)drawPrimitives:(MTLPrimitiveType)type indirectBuffer:(id<MTLBuffer>)buf indirectBufferOffset:(NSUInteger)off {
    NVMTLBuffer *nb = nvmtl_as_buffer(buf, "drawPrimitives:indirectBuffer");
    if (!nb) { nvlog("drawPrimitives:indirectBuffer: nil"); return; }
    nvmtl_retain_resource(_cb, nb);
    if (!_begun) { nvlog("drawPrimitives:indirectBuffer: no render pass"); return; }
    _ppKind = 3; _ppInd = &nb->_b; _ppIndOff = off; _ppA[0] = off; _ppA[1] = _ppA[2] = _ppA[3] = _ppA[4] = 0;
    if (![self nvmtlBindSamplerPipeline]) return;
    nvtrace("DRAW type %u | vs %s | fs %s | blend %s", (unsigned)type, _ps ? _ps->_vname.UTF8String : "-", _ps ? _ps->_fname.UTF8String : "-", _ps ? _ps->_blend.UTF8String : "-");
    if (nvmtl_trace_on()) { char bufs_[600]; nvmtl_vk_trace_buffers(&_cb->_c, bufs_, sizeof bufs_); nvtrace("  BUFS%s", bufs_); }
    if (nvmtl_vk_cmd_set_topology(&_cb->_c, (unsigned)type)) return;
    if ([self nvmtlVertexInputs]) return;
    nvmtl_vk_cmd_draw_indirect(&_cb->_c, &nb->_b, off);
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexType:(MTLIndexType)it indexBuffer:(id<MTLBuffer>)idx
          indexBufferOffset:(NSUInteger)ioff indirectBuffer:(id<MTLBuffer>)buf indirectBufferOffset:(NSUInteger)off {
    NVMTLBuffer *ni = nvmtl_as_buffer(idx, "drawIndexedPrimitives:indirectBuffer index"), *nb = nvmtl_as_buffer(buf, "drawIndexedPrimitives:indirectBuffer");
    if (!ni || !nb) { nvlog("drawIndexedPrimitives:indirectBuffer: nil"); return; }
    nvmtl_retain_resource(_cb, ni);
    nvmtl_retain_resource(_cb, nb);
    if (!_begun) { nvlog("drawIndexedPrimitives:indirectBuffer: no render pass"); return; }
    _ppKind = 4; _ppInd = &nb->_b; _ppIndOff = off; _ppA[0] = off; _ppA[1] = ioff; _ppA[2] = _ppA[3] = _ppA[4] = 0;
    if (![self nvmtlBindSamplerPipeline]) return;
    nvtrace("DRAW type %u | vs %s | fs %s | blend %s", (unsigned)type, _ps ? _ps->_vname.UTF8String : "-", _ps ? _ps->_fname.UTF8String : "-", _ps ? _ps->_blend.UTF8String : "-");
    if (nvmtl_trace_on()) { char bufs_[600]; nvmtl_vk_trace_buffers(&_cb->_c, bufs_, sizeof bufs_); nvtrace("  BUFS%s", bufs_); }
    if (nvmtl_vk_cmd_set_topology(&_cb->_c, (unsigned)type)) return;
    if ([self nvmtlVertexInputs]) return;
    nvmtl_vk_cmd_draw_indexed_indirect(&_cb->_c, &ni->_b, ioff, it == MTLIndexTypeUInt32, &nb->_b, off);
}
- (void)pushDebugGroup:(NSString *)g {
    nvtrace("GROUP %s", g.UTF8String ?: "?");
    // NVMTL_SKIP_GROUP=<text>: draws inside a debug group whose name contains it are not recorded (finds a hanging shader)
    static const char *skip; static int once; if (!once) { once = 1; skip = getenv("NVMTL_SKIP_GROUP"); }
    _groupDepth++;
    if (skip && *skip && !_cb->_c.skip_group && strstr(g.UTF8String ?: "", skip)) { _cb->_c.skip_group = _groupDepth; nvlog("NVMTL_SKIP_GROUP: skipping %s", g.UTF8String); }
    // NVMTL_DUMP_GROUP=<text>: the first time a debug group containing it opens, the fragment buffers bound at that moment
    // are copied out after this command buffer completes, up to 64 KB each, to $TMPDIR/dump-f<index>.bin (diagnostic)
    static const char *dump; static int donce; static _Atomic int dumped; if (!donce) { donce = 1; dump = getenv("NVMTL_DUMP_GROUP"); }
    if (dump && *dump && strstr(g.UTF8String ?: "", dump) && !atomic_exchange(&dumped, 1)) { _dumpDepth = _groupDepth; _dumpName = [g copy]; }
}
- (void)nvmtlDumpBoundFragmentBuffers {
    {
        NSMutableDictionary *bound = [NSMutableDictionary new]; NSString *name = _dumpName;
        for (NSUInteger i = 0; i < NVMTL_NBUFAT; i++) if (_fbufAt[i]) bound[@(i)] = @[_fbufAt[i], @(_fbufOff[i])];
        [_cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                id<MTLDevice> dev = done.device; id<MTLCommandQueue> q = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder]; NSMutableDictionary *outs = [NSMutableDictionary new];
                for (NSNumber *k in bound) { NVMTLBuffer *b = bound[k][0]; NSUInteger off = [bound[k][1] unsignedLongValue];
                    if (off >= b.length) continue; NSUInteger n = MIN(b.length - off, (NSUInteger)65536);
                    id<MTLBuffer> o = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
                    [be copyFromBuffer:b sourceOffset:off toBuffer:o destinationOffset:0 size:n]; outs[k] = o; }
                [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
                for (NSNumber *k in outs) { id<MTLBuffer> o = outs[k];
                    NSString *path = [NSTemporaryDirectory() stringByAppendingFormat:@"dump-f%@.bin", k];
                    [[NSData dataWithBytes:o.contents length:o.length] writeToFile:path atomically:YES]; }
                nvlog("NVMTL_DUMP_GROUP: %lu fragment buffer(s) of '%s' written to %s (command buffer status %ld)", (unsigned long)outs.count,
                      name.UTF8String, NSTemporaryDirectory().UTF8String, (long)done.status);
            });
        }];
    }
}
- (void)popDebugGroup { if (_dumpDepth && _dumpDepth == _groupDepth) { [self nvmtlDumpBoundFragmentBuffers]; _dumpDepth = 0; }
    if (_cb->_c.skip_group == _groupDepth) _cb->_c.skip_group = 0; if (_groupDepth) _groupDepth--; }
- (void)insertDebugSignpost:(NSString *)s {}
- (void)setLabel:(NSString *)l { _label = [l copy]; }
- (NSString *)label { return _label; }
- (id<MTLDevice>)device { id<MTLDevice> d = _cb ? [_cb device] : nil; return d ? d : (id<MTLDevice>)gNVMTLMainDevice; }
// -commandBuffer is SPI on Apple's encoders (_MTLCommandEncoder), not in the MTLCommandEncoder protocol, but apps call it:
// Hades asks every render encoder for its command buffer each frame; the forwarding stub answered nil and messages to the
// nil command buffer did nothing. The encoder keeps _cb after endEncoding, so it answers then too, as Apple's does.
- (id<MTLCommandBuffer>)commandBuffer { return (id<MTLCommandBuffer>)_cb; }
- (void)setColorStoreAction:(MTLStoreAction)a atIndex:(NSUInteger)i {
    BOOL resolve = a == MTLStoreActionMultisampleResolve || a == MTLStoreActionStoreAndMultisampleResolve;
    BOOL planned = i < NVMTL_NCOL && _pass.res[i] != NULL;
    if (resolve && !planned) { nvmtl_apps1_resolve_miss++; static int said; if (said++ < 4)
        nvlog("encoder: apps1 setColorStoreAction:%lu atIndex:%lu — the pass began with no resolve texture on that slot: resolve NOT applied (apps3)", (unsigned long)a, (unsigned long)i); }
    else if (!resolve && planned) { nvmtl_apps1_resolve_extra++; static int said; if (said++ < 4)
        nvlog("encoder: apps1 setColorStoreAction:%lu atIndex:%lu — the resolve planned for MTLStoreActionUnknown stays: the resolve texture IS written", (unsigned long)a, (unsigned long)i); }
}
- (void)setDepthStoreAction:(MTLStoreAction)a {
    if (a == MTLStoreActionCustomSampleDepthStore) _pass.depth_store_options |= MTLStoreActionOptionCustomSamplePositions;
    if (a == MTLStoreActionMultisampleResolve || a == MTLStoreActionStoreAndMultisampleResolve) { nvmtl_apps1_ds_resolve_miss++; static int said;
        if (said++ < 4) nvlog("encoder: apps1 setDepthStoreAction:%lu — depth resolve is not built: depth is stored, NOT resolved (apps3)", (unsigned long)a); }
}
- (void)setStencilStoreAction:(MTLStoreAction)a {
    if (a == MTLStoreActionMultisampleResolve || a == MTLStoreActionStoreAndMultisampleResolve) { nvmtl_apps1_ds_resolve_miss++; static int said;
        if (said++ < 4) nvlog("encoder: apps1 setStencilStoreAction:%lu — stencil resolve is not built: stencil is stored, NOT resolved (apps3)", (unsigned long)a); }
}
- (void)setColorStoreActionOptions:(MTLStoreActionOptions)x atIndex:(NSUInteger)i {
    if (x & ~MTLStoreActionOptionCustomSamplePositions) [self nvmtlSamplePositionError:@"unknown color store options"];
    (void)i;
}
- (void)setDepthStoreActionOptions:(MTLStoreActionOptions)x {
    _pass.depth_store_options = (uint32_t)x;
    if (x & ~MTLStoreActionOptionCustomSamplePositions) [self nvmtlSamplePositionError:@"unknown depth store options"];
}
- (void)setStencilStoreActionOptions:(MTLStoreActionOptions)x {
    _pass.stencil_store_options = (uint32_t)x;
    if (x) [self nvmtlSamplePositionError:@"stencil store options are illegal"];
}
@end

@implementation NVMTLFence
- (id<MTLDevice>)device { return _dev; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { _label = [l copy]; }
@end

static _Atomic uint64_t gHAPlaced, gHAGiven, gHALive, gHAFallback, gHABacked, gHABackedBytes, gHAHiwP, gHAHiwS, gHABackedP;
static int nvmtl_heap_grow(NVMTLHeap *h) {
    if (h->_nfr < h->_cfr) return 0;
    uint32_t nc = h->_cfr ? h->_cfr * 2 : 8;
    NSUInteger *n = realloc(h->_fr, (size_t)nc * 2 * sizeof(NSUInteger));
    if (!n) return -1;
    h->_fr = n; h->_cfr = nc; return 0;
}
static _Atomic uint64_t gHDDeferred, gHDDeferredBytes, gHDReleased, gHDEarlyShared, gHDEarlyPrivate, gHDTakeFailPending;
static int nvmtl_heap_defer_on(void) {
    static int v = -1;
    if (v < 0) { const char *e = getenv("NVMTL_HEAP_DEFER"); v = !(e && e[0] == '0');
        nvlog("heap defer: %s (NVMTL_HEAP_DEFER=%s)", v ? "ON - a Shared heap's released range is reused only after the command buffer committed next has completed"
                                                    : "OFF - released ranges are reused at once", e ? e : "unset"); }
    return v;
}
static void nvmtl_heap_defer_census(void) {
    const uint64_t k = atomic_load(&gHDDeferred) + atomic_load(&gHDEarlyPrivate);
    if (!k || (k & (k - 1))) return;
    nvlog("heap defer: %llu Shared ranges held (%llu MB), %llu handed back; reuses of a range whose last user may still be in flight: "
          "%llu Shared (would have been, without the hold), %llu Private (allowed: GPU-ordered); %llu takes failed while ranges were held",
          (unsigned long long)atomic_load(&gHDDeferred), (unsigned long long)(atomic_load(&gHDDeferredBytes) >> 20), (unsigned long long)atomic_load(&gHDReleased),
          (unsigned long long)atomic_load(&gHDEarlyShared), (unsigned long long)atomic_load(&gHDEarlyPrivate), (unsigned long long)atomic_load(&gHDTakeFailPending));
}
static const char *nvmtl_heap_give(NVMTLHeap *h, NSUInteger o, NSUInteger n);
static void nvmtl_heap_note_recent(NVMTLHeap *h, NSUInteger o, NSUInteger n, uint64_t seq) {
    os_unfair_lock_lock(&h->_fl);
    h->_recent[h->_nrecent++ % 64] = (nvmtl_heap_pend_t){ o, n, seq };
    os_unfair_lock_unlock(&h->_fl);
}
static int nvmtl_heap_recent_hit(NVMTLHeap *h, NSUInteger o, NSUInteger n, uint64_t wm) {
    int hit = 0;
    os_unfair_lock_lock(&h->_fl);
    const uint32_t m = h->_nrecent < 64 ? h->_nrecent : 64;
    for (uint32_t k = 0; k < m && !hit; k++) { const nvmtl_heap_pend_t *r = &h->_recent[k];
        if (r->n && r->seq + 1 > wm && o < r->o + r->n && r->o < o + n) hit = 1; }
    os_unfair_lock_unlock(&h->_fl);
    return hit;
}
static void nvmtl_heap_drain(NVMTLHeap *h, int all) {
    if (!h->_npend) return;
    const uint64_t wm = nvmtl_vk_seq_done();
    nvmtl_heap_pend_t ready[64]; uint32_t nr;
    do {
        nr = 0;
        os_unfair_lock_lock(&h->_fl);
        uint32_t w = 0;
        for (uint32_t k = 0; k < h->_npend; k++) {
            if (nr < 64 && (all || h->_pend[k].seq + 1 <= wm)) ready[nr++] = h->_pend[k]; else h->_pend[w++] = h->_pend[k];
        }
        h->_npend = w;
        os_unfair_lock_unlock(&h->_fl);
        for (uint32_t k = 0; k < nr; k++) {
            const char *why = nvmtl_heap_give(h, ready[k].o, ready[k].n);
            if (why) nvlog("heap defer: range %lu+%lu NOT handed back - %s", (unsigned long)ready[k].o, (unsigned long)ready[k].n, why);
            else { atomic_fetch_add(&gHDReleased, 1); atomic_fetch_sub(&gHALive, ready[k].n); }
        }
    } while (nr == 64);
}
static NSUInteger nvmtl_heap_take_raw(NVMTLHeap *h, NSUInteger size, NSUInteger al) {
    NSUInteger got = NSUIntegerMax;
    if (!al) al = 1;
    os_unfair_lock_lock(&h->_fl);
    for (uint32_t i = 0; i < h->_nfr; i++) {
        NSUInteger ro = h->_fr[2 * i], rl = h->_fr[2 * i + 1], o = (ro + al - 1) / al * al;
        if (h->_hm.lazy && o >= ro) {   // chunk-backed: a resource stays inside one chunk, or starts one if it is bigger
            const NSUInteger CK = (NSUInteger)NVMTL_HEAP_CK;
            if (size > CK) o = (o + CK - 1) / CK * CK;
            else if (size && o / CK != (o + size - 1) / CK) o = (o / CK + 1) * CK;
        }
        if (o < ro || o + size < o || o + size > ro + rl) continue;
        NSUInteger lo = o - ro, hi = ro + rl - (o + size);
        if (lo && hi) {
            if (nvmtl_heap_grow(h)) break;
            memmove(&h->_fr[2 * (i + 1)], &h->_fr[2 * i], (size_t)(h->_nfr - i) * 2 * sizeof(NSUInteger));
            h->_fr[2 * i + 1] = lo; h->_fr[2 * (i + 1)] = o + size; h->_fr[2 * (i + 1) + 1] = hi; h->_nfr++;
        } else if (lo) h->_fr[2 * i + 1] = lo;
        else if (hi) { h->_fr[2 * i] = o + size; h->_fr[2 * i + 1] = hi; }
        else { memmove(&h->_fr[2 * i], &h->_fr[2 * (i + 1)], (size_t)(h->_nfr - i - 1) * 2 * sizeof(NSUInteger)); h->_nfr--; }
        got = o; break;
    }
    os_unfair_lock_unlock(&h->_fl);
    return got;
}
static NSUInteger nvmtl_heap_take(NVMTLHeap *h, NSUInteger size, NSUInteger al) {
    nvmtl_heap_drain(h, 0);
    NSUInteger got = nvmtl_heap_take_raw(h, size, al);
    if (got != NSUIntegerMax && h->_backed) {   // census: what chunked backing would have needed (first fit: [0, high-water))
        const NSUInteger CK = 32u << 20, e = MIN((got + size + CK - 1) / CK * CK, h->_size);
        os_unfair_lock_lock(&h->_fl); const NSUInteger was = h->_hiw; if (e > was) h->_hiw = e; os_unfair_lock_unlock(&h->_fl);
        if (e > was) atomic_fetch_add(h->_storage == MTLStorageModeShared ? &gHAHiwS : &gHAHiwP, e - was);
    }
    if (got == NSUIntegerMax && h->_npend) atomic_fetch_add(&gHDTakeFailPending, 1);
    if (got != NSUIntegerMax && h->_nrecent && nvmtl_heap_recent_hit(h, got, size, nvmtl_vk_seq_done())) {
        atomic_fetch_add(h->_storage == MTLStorageModeShared ? &gHDEarlyShared : &gHDEarlyPrivate, 1); nvmtl_heap_defer_census(); }
    return got;
}
static const char *nvmtl_heap_give(NVMTLHeap *h, NSUInteger o, NSUInteger n) {
    const char *why = NULL;
    os_unfair_lock_lock(&h->_fl);
    uint32_t i = 0; while (i < h->_nfr && h->_fr[2 * i] < o) i++;
    int hasP = i > 0, hasN = i < h->_nfr;
    if (!n || o + n < o || o + n > h->_size) why = "outside the heap";
    else if (hasP && h->_fr[2 * (i - 1)] + h->_fr[2 * (i - 1) + 1] > o) why = "overlaps the free range before it (a double give)";
    else if (hasN && o + n > h->_fr[2 * i]) why = "overlaps the free range after it (a double give)";
    else {
        int mP = hasP && h->_fr[2 * (i - 1)] + h->_fr[2 * (i - 1) + 1] == o, mN = hasN && o + n == h->_fr[2 * i];
        if (mP && mN) { h->_fr[2 * (i - 1) + 1] += n + h->_fr[2 * i + 1];
                        memmove(&h->_fr[2 * i], &h->_fr[2 * (i + 1)], (size_t)(h->_nfr - i - 1) * 2 * sizeof(NSUInteger)); h->_nfr--; }
        else if (mP) h->_fr[2 * (i - 1) + 1] += n;
        else if (mN) { h->_fr[2 * i] = o; h->_fr[2 * i + 1] += n; }
        else if (nvmtl_heap_grow(h)) why = "the free list could not grow (the range stays out of circulation)";
        else { memmove(&h->_fr[2 * (i + 1)], &h->_fr[2 * i], (size_t)(h->_nfr - i) * 2 * sizeof(NSUInteger));
               h->_fr[2 * i] = o; h->_fr[2 * i + 1] = n; h->_nfr++; }
    }
    os_unfair_lock_unlock(&h->_fl);
    return why;
}
static int nvmtl_heap_take_at_locked(NVMTLHeap *h, NSUInteger o, NSUInteger size) {
    if (!size || o + size < o) return -1;
    for (uint32_t i = 0; i < h->_nfr; i++) {
        NSUInteger ro = h->_fr[2 * i], rl = h->_fr[2 * i + 1];
        if (ro > o) break;
        if (o + size > ro + rl) continue;
        NSUInteger lo = o - ro, hi = ro + rl - (o + size);
        if (lo && hi) {
            if (nvmtl_heap_grow(h)) return -1;
            memmove(&h->_fr[2 * (i + 1)], &h->_fr[2 * i], (size_t)(h->_nfr - i) * 2 * sizeof(NSUInteger));
            h->_fr[2 * i + 1] = lo; h->_fr[2 * (i + 1)] = o + size; h->_fr[2 * (i + 1) + 1] = hi; h->_nfr++;
        } else if (lo) h->_fr[2 * i + 1] = lo;
        else if (hi) { h->_fr[2 * i] = o + size; h->_fr[2 * i + 1] = hi; }
        else { memmove(&h->_fr[2 * i], &h->_fr[2 * (i + 1)], (size_t)(h->_nfr - i - 1) * 2 * sizeof(NSUInteger)); h->_nfr--; }
        return 0;
    }
    return -1;
}
#define NVMTL_HEAPPARK 8
static _Atomic uint64_t gHTPlaced, gHTRecycled, gHTParked, gHTEvicted, gHTFallback, gHTMisfit;
static void nvmtl_heaptex_census(const char *what) {
    const uint64_t n = atomic_load(&gHTPlaced) + atomic_load(&gHTRecycled) + atomic_load(&gHTFallback);
    if (n & (n - 1)) return;
    nvlog("heap texture (%s): %llu placed new, %llu recycled, %llu parked, %llu evicted, %llu took the legacy fresh path, %llu misfit",
          what, (unsigned long long)atomic_load(&gHTPlaced), (unsigned long long)atomic_load(&gHTRecycled),
          (unsigned long long)atomic_load(&gHTParked), (unsigned long long)atomic_load(&gHTEvicted),
          (unsigned long long)atomic_load(&gHTFallback), (unsigned long long)atomic_load(&gHTMisfit));
}
static int nvmtl_heap_unpark(NVMTLHeap *h, const uint32_t *key, nvk_image *out, NSUInteger *off, NSUInteger *len) {
    int got = -1;
    os_unfair_lock_lock(&h->_fl);
    for (uint32_t k = h->_npk; k-- > 0; ) {
        nvmtl_park_t *p = &h->_pk[k];
        if (memcmp(p->key, key, sizeof p->key) || nvmtl_heap_take_at_locked(h, p->off, p->len)) continue;
        *out = p->img; *off = p->off; *len = p->len;
        memmove(p, p + 1, (size_t)(h->_npk - k - 1) * sizeof *p); h->_npk--; got = 0; break;
    }
    os_unfair_lock_unlock(&h->_fl);
    return got;
}
static void nvmtl_heap_park(NVMTLHeap *h, nvk_image *img, const uint32_t *key, NSUInteger off, NSUInteger len) {
    nvk_image ev; int evict = 0, parked = 0;
    os_unfair_lock_lock(&h->_fl);
    if (!h->_pk) h->_pk = calloc(NVMTL_HEAPPARK, sizeof *h->_pk);
    if (h->_pk) {
        if (h->_npk == NVMTL_HEAPPARK) { ev = h->_pk[0].img; evict = 1;
            memmove(&h->_pk[0], &h->_pk[1], (NVMTL_HEAPPARK - 1) * sizeof *h->_pk); h->_npk--; }
        nvmtl_park_t *p = &h->_pk[h->_npk++]; p->img = *img; memcpy(p->key, key, sizeof p->key); p->off = off; p->len = len;
        parked = 1;
    }
    os_unfair_lock_unlock(&h->_fl);
    if (parked) { memset(img, 0, sizeof *img); atomic_fetch_add(&gHTParked, 1); }
    if (evict) { nvmtl_vk_image_destroy(&ev); atomic_fetch_add(&gHTEvicted, 1); }
}
static void nvmtl_heap_census(const char *what) {
    nvlog("heap alias (%s): %llu placed, %llu given back, %llu live = %llu MB bound in %llu backed heaps of %llu MB;"
          " %llu took the legacy fresh path; high-water (32 MB chunks) private %llu of %llu MB, shared %llu MB", what,
          (unsigned long long)atomic_load(&gHAPlaced), (unsigned long long)atomic_load(&gHAGiven),
          (unsigned long long)(atomic_load(&gHAPlaced) - atomic_load(&gHAGiven)), (unsigned long long)(atomic_load(&gHALive) >> 20),
          (unsigned long long)atomic_load(&gHABacked), (unsigned long long)(atomic_load(&gHABackedBytes) >> 20),
          (unsigned long long)atomic_load(&gHAFallback), (unsigned long long)(atomic_load(&gHAHiwP) >> 20),
          (unsigned long long)(atomic_load(&gHABackedP) >> 20), (unsigned long long)(atomic_load(&gHAHiwS) >> 20));
}
void nvmtl_heap_back(NVMTLHeap *h, NSUInteger size, int shared) {
    if (shared ? nvmtl_vk_heap_create(size, 1, &h->_hm) : nvmtl_vk_heap_create_lazy(size, &h->_hm)) {
        nvlog("heap alias: an automatic %s heap of %lu bytes got no memory of its own - its resources take the legacy fresh path",
              shared ? "shared" : "private", (unsigned long)size);
        return;
    }
    h->_fl = OS_UNFAIR_LOCK_INIT; h->_nfr = 0; h->_cfr = 0; h->_fr = NULL;
    if (nvmtl_heap_grow(h)) { nvmtl_vk_heap_destroy(&h->_hm); nvlog("heap alias: no free list for a %lu-byte heap - legacy path", (unsigned long)size); return; }
    h->_fr[0] = 0; h->_fr[1] = size; h->_nfr = 1; h->_backed = YES;
    atomic_fetch_add(&gHABacked, 1); atomic_fetch_add(&gHABackedBytes, size); if (!shared) atomic_fetch_add(&gHABackedP, size);
}
@implementation NVMTLHeap
- (void)nvmtlGiveRange:(NSUInteger)off length:(NSUInteger)len {
    const uint64_t seq = nvmtl_vk_seq_now();
    nvmtl_heap_note_recent(self, off, len, seq);
    if (_storage == MTLStorageModeShared && nvmtl_heap_defer_on()) {
        os_unfair_lock_lock(&_fl);
        if (_npend == _cpend) { uint32_t nc = _cpend ? _cpend * 2 : 64; nvmtl_heap_pend_t *n = realloc(_pend, nc * sizeof *n); if (n) { _pend = n; _cpend = nc; } }
        const int held = _npend < _cpend;
        if (held) _pend[_npend++] = (nvmtl_heap_pend_t){ off, len, seq };
        os_unfair_lock_unlock(&_fl);
        if (held) { atomic_fetch_add(&gHAGiven, 1); atomic_fetch_add(&gHDDeferred, 1); atomic_fetch_add(&gHDDeferredBytes, len); nvmtl_heap_defer_census(); return; }
    }
    const char *why = nvmtl_heap_give(self, off, len);
    if (why) { nvlog("heap alias: range %lu+%lu NOT given back - %s", (unsigned long)off, (unsigned long)len, why); return; }
    atomic_fetch_add(&gHAGiven, 1); atomic_fetch_sub(&gHALive, len);
}
// NVMTL_ZERO_HEAP=1: buffers sub-allocated from a heap are zero-filled as device buffers are. Metal leaves their
// contents undefined, but Apple's heaps come from freshly zeroed pages and a game can depend on that: Cyberpunk 2077's
// benchmark reads a light count from a 16-byte heap buffer it never writes in that scene; a recycled VRAM range held
// garbage, the loop read millions of records past a 196 KB buffer, and the channel faulted (2026-11-05).
static int nvmtl_zero_heap_on(void) { static int v = -1; if (v < 0) { const char *e = getenv("NVMTL_ZERO_HEAP"); v = e && *e && *e != '0'; nvlog("zero-fill: heap buffers %s (NVMTL_ZERO_HEAP=%s)", v ? "ARE cleared" : "keep what the memory held", e ? e : "unset"); } return v; }
- (id<MTLBuffer>)nvmtlPlacedBuffer:(NSUInteger)len options:(MTLResourceOptions)opt charge:(NSUInteger)charge {
    MTLStorageMode sm = (MTLStorageMode)((opt >> MTLResourceStorageModeShift) & 0xF);
    if (sm != _storage) {
        static int said; if (said++ < 2) nvlog("heap alias: a storage-%d buffer from a storage-%d heap - legacy path", (int)sm, (int)_storage);
        return nil;
    }
    NSUInteger al = [_dev heapBufferSizeAndAlignWithLength:len options:opt].align;
    NSUInteger off = nvmtl_heap_take(self, charge, al);
    if (off == NSUIntegerMax) {
        nvlog("heap alias: no free range of %lu (align %lu) in a %lu-byte heap with %lu charged - legacy path",
              (unsigned long)charge, (unsigned long)al, (unsigned long)_size, (unsigned long)_used);
        return nil;
    }
    NVMTLBuffer *b = [NVMTLBuffer new];
    b->_storage = sm;
    b->_ropt = opt & ((MTLResourceOptions)0xF | ((MTLResourceOptions)0x3 << MTLResourceHazardTrackingModeShift));
    if (nvmtl_vk_buffer_create_placed(len, &_hm, off, &b->_b)) {
        const char *why = nvmtl_heap_give(self, off, charge);
        nvlog("heap alias: bind of %lu at %lu FAILED - legacy path%s%s", (unsigned long)len, (unsigned long)off, why ? "; range kept out: " : "", why ? why : "");
        return nil;
    }
    b->_subHeap = self; b->_subCharge = charge; b->_subPlaced = YES; b->_heapOffset = off; _used += charge;
    { extern void nvmtl_shm_note_place(void *, size_t, size_t, unsigned, unsigned); if (_hm.shm) nvmtl_shm_note_place(_hm.mem, off, len, 1, 0); }
    atomic_fetch_add(&gHAPlaced, 1); atomic_fetch_add(&gHALive, charge);
    nvmtl_heap_census("placed");
    if (nvmtl_zero_heap_on()) nvmtl_zero_new_buffer(b, len);
    return b;
}
- (unsigned long long)protectionOptions { return 0; }
- (id<MTLDevice>)device { return _dev; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { _label = [l copy]; }
- (NSUInteger)size { return _size; }
- (NSUInteger)usedSize { return _used; }
- (NSUInteger)currentAllocatedSize { return _size; }
- (MTLStorageMode)storageMode { return _storage; }
- (MTLCPUCacheMode)cpuCacheMode { return _cache; }
- (MTLHeapType)type { return _type; }
- (MTLHazardTrackingMode)hazardTrackingMode { return _hazard == MTLHazardTrackingModeTracked ? MTLHazardTrackingModeTracked : MTLHazardTrackingModeUntracked; }
- (MTLResourceOptions)resourceOptions { return ((MTLResourceOptions)_storage << MTLResourceStorageModeShift) | (MTLResourceOptions)_cache
                                            | ((MTLResourceOptions)[self hazardTrackingMode] << MTLResourceHazardTrackingModeShift); }
- (NSUInteger)allocatedSize { return _size; }
- (void)dealloc { for (uint32_t k = 0; k < _npk; k++) nvmtl_vk_image_destroy(&_pk[k].img);
                  free(_pk); _pk = NULL; _npk = 0;
                  if (_backed) { atomic_fetch_sub(_storage == MTLStorageModeShared ? &gHAHiwS : &gHAHiwP, _hiw);
                                 atomic_fetch_sub(&gHABacked, 1); atomic_fetch_sub(&gHABackedBytes, _size); if (_storage != MTLStorageModeShared) atomic_fetch_sub(&gHABackedP, _size); }
                  nvmtl_vk_heap_destroy(&_hm); free(_fr); _fr = NULL; free(_pend); _pend = NULL; _npend = 0; }
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)len options:(MTLResourceOptions)opt offset:(NSUInteger)off {
    if (_type != MTLHeapTypePlacement) { nvlog("heap newBufferWithLength:offset: on a non-placement heap"); return nil; }
    NVMTLBuffer *b = [NVMTLBuffer new];
    b->_storage = (MTLStorageMode)((opt >> MTLResourceStorageModeShift) & 0xF);
    if (nvmtl_vk_buffer_create_placed(len, &_hm, off, &b->_b)) { nvlog("heap newBufferWithLength:%lu offset:%lu FAILED", (unsigned long)len, (unsigned long)off); return nil; }
    b->_heap = self; b->_heapOffset = off; if (off + len > _used) _used = off + len;
    { extern void nvmtl_shm_note_place(void *, size_t, size_t, unsigned, unsigned); if (_hm.shm) nvmtl_shm_note_place(_hm.mem, off, len, 1, 0); }
    nvlog("heap newBufferWithLength:%lu offset:%lu -> %p", (unsigned long)len, (unsigned long)off, (__bridge void *)b);
    return b;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)off {
    extern int nvmtl_pixfmt_public(MTLPixelFormat f, uint32_t *vk, uint32_t *bpp, int *a8);
    extern int nvmtl_depthfmt_public(MTLPixelFormat f, uint32_t *vk, uint32_t *aspect);
    extern nvk_queue *nvmtl_device_queue(void);
    if (_type != MTLHeapTypePlacement) { nvlog("heap newTextureWithDescriptor:offset: on a non-placement heap"); return nil; }
    if (!d) return nil;
    NVMTLTexture *t = [NVMTLTexture new];
    t->_fmt = d.pixelFormat; t->_mips = (uint32_t)(d.mipmapLevelCount ? d.mipmapLevelCount : 1);
    t->_usage = d.usage;
    uint32_t dvk = 0, dasp = 0;
    if (nvmtl_depthfmt_public(d.pixelFormat, &dvk, &dasp) == 0) {
        if (nvmtl_vk_depth_create_ex_placed((uint32_t)d.width, (uint32_t)d.height, dvk, dasp, &_hm, off, &t->_i)) { nvlog("heap depth texture FAILED (format %lu offset %lu)", (unsigned long)d.pixelFormat, (unsigned long)off); return nil; }
        t->_q = nvmtl_device_queue(); t->_heap = self; t->_heapOffset = off;
        { extern void nvmtl_shm_note_place(void *, size_t, size_t, unsigned, unsigned); if (_hm.shm) nvmtl_shm_note_place(_hm.mem, off, t->_i.alloc, 3, (unsigned)d.usage); }
        nvlog("heap newTextureWithDescriptor: %lux%lu DEPTH offset:%lu -> %p", (unsigned long)d.width, (unsigned long)d.height, (unsigned long)off, (__bridge void *)t);
        return t;
    }
    uint32_t vkf = 0, bpp = 0; int a8 = 0;
    if (nvmtl_pixfmt_public(d.pixelFormat, &vkf, &bpp, &a8)) return nil;
    int wantStex = NVMTL_USAGE_WRITES(d.usage);
    if (nvmtl_vk_image_create_typed_placed((uint32_t)d.width, (uint32_t)d.height, vkf, bpp, a8, (uint32_t)d.mipmapLevelCount, wantStex,
                                            (uint32_t)d.textureType, nvmtl_vk_layers_for_desc((uint32_t)d.textureType, (uint32_t)d.arrayLength, (uint32_t)d.depth), &_hm, off, &t->_i)) {
        nvlog("heap newTextureWithDescriptor: %lux%lu offset:%lu FAILED", (unsigned long)d.width, (unsigned long)d.height, (unsigned long)off); return nil; }
    t->_q = nvmtl_device_queue(); t->_stex = nvmtl_vk_image_self_storage(&t->_i) != 0; t->_heap = self; t->_heapOffset = off;
    { extern void nvmtl_shm_note_place(void *, size_t, size_t, unsigned, unsigned); if (_hm.shm) nvmtl_shm_note_place(_hm.mem, off, t->_i.alloc, 2, (unsigned)d.usage); }
    nvmtl_texture_desc_swizzle(t, d);
    nvlog("heap newTextureWithDescriptor: %lux%lu%s offset:%lu -> %p", (unsigned long)d.width, (unsigned long)d.height, t->_stex ? " +storage" : "", (unsigned long)off, (__bridge void *)t);
    return t;
}
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)s { return nvmtl_purge(&_purge, s); }
- (void)nvmtlReleaseSubAllocation:(NSUInteger)bytes {
    if (bytes > _used) {
        nvlog("heap release %lu but only %lu charged - accounting underflow, clamped to 0", (unsigned long)bytes, (unsigned long)_used);
        _used = 0; return;
    }
    _used -= bytes;
}
- (NSUInteger)maxAvailableSizeWithAlignment:(NSUInteger)a {
    NSUInteger left = _size > _used ? _size - _used : 0;
    return (a > 1 && left % a) ? left - (left % a) : left;
}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)len options:(MTLResourceOptions)opt {
    NSUInteger charge = [_dev heapBufferSizeAndAlignWithLength:len options:opt].size;
    if (charge < len) charge = len;
    if (charge > [self maxAvailableSizeWithAlignment:0]) { nvlog("heap newBufferWithLength:%lu (charge %lu) — only %lu left of %lu", (unsigned long)len, (unsigned long)charge, (unsigned long)(_size > _used ? _size - _used : 0), (unsigned long)_size); return nil; }
    if (_backed) { id<MTLBuffer> pb = [self nvmtlPlacedBuffer:len options:opt charge:charge]; if (pb) return pb;
                   atomic_fetch_add(&gHAFallback, 1); nvmtl_heap_census("fallback"); }
    gZeroSkip = !nvmtl_zero_heap_on(); id<MTLBuffer> b = [_dev newBufferWithLength:len options:opt]; gZeroSkip = 0;
    if (!b) return nil;
    if (![(id)b isKindOfClass:[NVMTLBuffer class]]) {
        static int said; if (said++ < 2) nvlog("heap sub-allocation is a %s, not ours — UNCHARGED, usedSize will under-report", [NSStringFromClass([(id)b class]) UTF8String]);
        return b;
    }
    NVMTLBuffer *nb = (NVMTLBuffer *)b; nb->_subHeap = self; nb->_subCharge = charge; _used += charge;
    return b;
}
- (id<MTLAccelerationStructure>)newAccelerationStructureWithSize:(NSUInteger)size {
    NSUInteger charge = [_dev heapAccelerationStructureSizeAndAlignWithSize:size].size;
    if (charge < size) charge = size;
    if (charge > [self maxAvailableSizeWithAlignment:0]) { nvlog("heap newAccelerationStructureWithSize:%lu (charge %lu) - only %lu left of %lu", (unsigned long)size, (unsigned long)charge, (unsigned long)(_size > _used ? _size - _used : 0), (unsigned long)_size); return nil; }
    id<MTLAccelerationStructure> as = [_dev newAccelerationStructureWithSize:size];
    if (!as) return nil;
    if (![(id)as isKindOfClass:[NVMTLAccelerationStructure class]]) {
        static int said; if (said++ < 2) nvlog("heap structure is a %s, not ours - UNCHARGED, usedSize will under-report", [NSStringFromClass([(id)as class]) UTF8String]);
        return as;
    }
    NVMTLAccelerationStructure *na = (NVMTLAccelerationStructure *)as; na->_subHeap = self; na->_subCharge = charge; _used += charge;
    nvlog("heap newAccelerationStructureWithSize:%lu (charge %lu) -> %p", (unsigned long)size, (unsigned long)charge, (__bridge void *)na);
    return as;
}
- (id<MTLAccelerationStructure>)newAccelerationStructureWithDescriptor:(MTLAccelerationStructureDescriptor *)desc {
    MTLAccelerationStructureSizes s = [_dev accelerationStructureSizesWithDescriptor:desc];
    return s.accelerationStructureSize ? [self newAccelerationStructureWithSize:s.accelerationStructureSize] : nil;
}
- (id<MTLAccelerationStructure>)newAccelerationStructureWithSize:(NSUInteger)size offset:(NSUInteger)off {
    if (_type != MTLHeapTypePlacement) { nvlog("heap newAccelerationStructureWithSize:offset: on a non-placement heap"); return nil; }
    if (nvmtl_vk_init() || !nvmtl_vk_rt_available()) { nvlog("heap newAccelerationStructureWithSize:offset: no ray tracing on this NVK"); return nil; }
    if (off & 255) { nvlog("heap newAccelerationStructureWithSize:%lu offset:%lu - offset is not 256-aligned (heapAccelerationStructureSizeAndAlign says 256) - REFUSED", (unsigned long)size, (unsigned long)off); return nil; }
    const size_t len = size < 256 ? 256 : size;
    NVMTLAccelerationStructure *a = [NVMTLAccelerationStructure new];
    a->_storage = MTLStorageModePrivate;
    if (nvmtl_vk_buffer_create_placed(len, &_hm, off, &a->_b)) { nvlog("heap newAccelerationStructureWithSize:%lu offset:%lu FAILED", (unsigned long)size, (unsigned long)off); return nil; }
    a->_heap = self; a->_heapOffset = off; if (off + len > _used) _used = off + len;
    nvlog("heap newAccelerationStructureWithSize:%lu offset:%lu -> %p", (unsigned long)size, (unsigned long)off, (__bridge void *)a);
    return a;
}
- (id<MTLAccelerationStructure>)newAccelerationStructureWithDescriptor:(MTLAccelerationStructureDescriptor *)desc offset:(NSUInteger)off {
    MTLAccelerationStructureSizes s = [_dev accelerationStructureSizesWithDescriptor:desc];
    return s.accelerationStructureSize ? [self newAccelerationStructureWithSize:s.accelerationStructureSize offset:off] : nil;
}
- (id<MTLTexture>)nvmtlPlacedTexture:(MTLTextureDescriptor *)d charge:(NSUInteger)charge align:(NSUInteger)al {
    extern int nvmtl_pixfmt_public(MTLPixelFormat f, uint32_t *vk, uint32_t *bpp, int *a8);
    extern int nvmtl_depthfmt_public(MTLPixelFormat f, uint32_t *vk, uint32_t *aspect);
    extern nvk_queue *nvmtl_device_queue(void);
    static int noPlace = -1, noRecycle = -1;
    if (noPlace < 0) { noPlace = getenv("NVMTL_NO_HEAPTEX_PLACE") != NULL; noRecycle = getenv("NVMTL_NO_HEAPTEX_RECYCLE") != NULL;
        nvlog("heap texture: dres R1 placement %s, recycle %s", noPlace ? "OFF (NVMTL_NO_HEAPTEX_PLACE)" : "ON",
              noRecycle ? "OFF (NVMTL_NO_HEAPTEX_RECYCLE)" : "ON"); }
    if (noPlace) return nil;
    if (_storage != MTLStorageModePrivate || d.storageMode != MTLStorageModePrivate
        || d.textureType == MTLTextureType2DMultisample || d.sampleCount > 1
        || !d.width || !d.height || d.width > UINT32_MAX || d.height > UINT32_MAX) return nil;
    uint32_t dvk = 0, dasp = 0, vkf = 0, bpp = 0; int a8 = 0;
    if (nvmtl_depthfmt_public(d.pixelFormat, &dvk, &dasp) == 0 || nvmtl_pixfmt_public(d.pixelFormat, &vkf, &bpp, &a8)) return nil;
    const uint32_t w = (uint32_t)d.width, hh = (uint32_t)d.height, mips = (uint32_t)(d.mipmapLevelCount ? d.mipmapLevelCount : 1);
    const uint32_t type = (uint32_t)d.textureType, layers = nvmtl_vk_layers_for_desc(type, (uint32_t)d.arrayLength, (uint32_t)d.depth);
    const int wantStex = NVMTL_USAGE_WRITES(d.usage);
    const uint32_t key[12] = { 1, w, hh, vkf, bpp, (uint32_t)a8, mips, (uint32_t)wantStex, type, layers, 0, 0 };
    NVMTLTexture *t = [NVMTLTexture new];
    NSUInteger off = 0, len = charge; BOOL rec = NO;
    if (!noRecycle && _npk && nvmtl_heap_unpark(self, key, &t->_i, &off, &len) == 0) {
        rec = YES; t->_i.layout = 0;
    } else {
        off = nvmtl_heap_take(self, charge, al);
        if (off == NSUIntegerMax) {
            static int said; if (said++ < 4) nvlog("heap texture: no free range of %lu (align %lu) in a %lu-byte heap with %lu charged - legacy path",
                                                   (unsigned long)charge, (unsigned long)al, (unsigned long)_size, (unsigned long)_used);
            return nil; }
        if (nvmtl_vk_image_create_typed_placed(w, hh, vkf, bpp, a8, mips, wantStex, type, layers, &_hm, off, &t->_i)
            || !nvmtl_vk_image_placed_fits(&t->_i, charge)) {
            if (t->_i.img) { nvmtl_vk_image_destroy(&t->_i); atomic_fetch_add(&gHTMisfit, 1); }
            const char *why = nvmtl_heap_give(self, off, charge);
            nvlog("heap texture: %ux%u fmt %lu at %lu NOT placed - legacy path%s%s", w, hh, (unsigned long)d.pixelFormat, (unsigned long)off,
                  why ? "; range kept out: " : "", why ? why : "");
            return nil; }
    }
    t->_ropt = (MTLResourceOptions)d.cpuCacheMode | ((MTLResourceOptions)d.hazardTrackingMode << MTLResourceHazardTrackingModeShift)
             | ((MTLResourceOptions)d.storageMode << MTLResourceStorageModeShift);
    t->_fmt = d.pixelFormat; t->_mips = mips; t->_usage = d.usage;
    t->_q = nvmtl_device_queue(); t->_stex = nvmtl_vk_image_self_storage(&t->_i) != 0;
    t->_subHeap = self; t->_subCharge = len; t->_subPlaced = YES; t->_heapOffset = off;
    { extern void nvmtl_shm_note_place(void *, size_t, size_t, unsigned, unsigned); if (_hm.shm) nvmtl_shm_note_place(_hm.mem, off, len, 2, (unsigned)d.usage); }
    t->_parkable = !noRecycle; memcpy(t->_pkey, key, sizeof key); t->_pkLen = len;
    _used += len;
    atomic_fetch_add(&gHAPlaced, 1); atomic_fetch_add(&gHALive, len);
    atomic_fetch_add(rec ? &gHTRecycled : &gHTPlaced, 1); nvmtl_heaptex_census(rec ? "recycled" : "placed");
    // automatic heaps land here, not in -newTextureWithDescriptor:offset:; without this the descriptor's swizzle was lost
    nvmtl_texture_desc_swizzle(t, d);
    return t;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d {
    if (!d) return nil;
    MTLSizeAndAlign sa = [_dev heapTextureSizeAndAlignWithDescriptor:d];
    NSUInteger charge = sa.size;
    if (_backed && charge) { id<MTLTexture> pt = [self nvmtlPlacedTexture:d charge:charge align:sa.align]; if (pt) return pt;
                             atomic_fetch_add(&gHTFallback, 1); nvmtl_heaptex_census("fallback"); }
    if (!charge) charge = d.width * d.height * 4;
    id<MTLTexture> t = [_dev newTextureWithDescriptor:d];
    if (!t) return nil;
    if (![(id)t isKindOfClass:[NVMTLTexture class]]) {
        static int said; if (said++ < 2) nvlog("heap sub-allocation is a %s, not ours — UNCHARGED, usedSize will under-report", [NSStringFromClass([(id)t class]) UTF8String]);
        return t;
    }
    NVMTLTexture *nt = (NVMTLTexture *)t; nt->_subHeap = self; nt->_subCharge = charge; _used += charge;
    return t;
}
@end

@implementation NVMTLDepthStencilState
- (NSString *)label { return _label; }
- (id<MTLDevice>)device { return (id<MTLDevice>)gNVMTLMainDevice; }
- (void)setLabel:(NSString *)l {}
- (BOOL)readsDepth { return _compare != 7 || _write; }
- (BOOL)writesDepth { return _write != 0; }
- (BOOL)readsStencil { return _stencil != 0; }
- (BOOL)writesStencil { if (!_stencil) return NO; for (int k = 1; k <= 3; k++) if ((_sf[k] && _sf[5]) || (_sb[k] && _sb[5])) return YES; return NO; }
@end

@implementation NVMTLSamplerState
- (MTLResourceID)gpuResourceID {
    @synchronized (self) { if (!_resid) _resid = nvmtl_resid_for_sampler(self); }
    MTLResourceID rid; rid._impl = _resid; return rid;
}
- (void)dealloc { nvmtl_vk_sampler_destroy(&_s); }
- (NSString *)label { return _label; }
- (id<MTLDevice>)device { return (id<MTLDevice>)gNVMTLMainDevice; }
@end

#pragma mark - compute / blit
@implementation NVMTLComputePipelineState
- (void)dealloc { nvmtl_vk_pipeline_destroy(&_p); }
- (BOOL)supportIndirectCommandBuffers { return _icb; }
- (MTLResourceID)gpuResourceID {
    MTLResourceID r; r._impl = _icb ? nvmtl_resid_pipe(self, &_resid) : 0; return r; }
- (NSUInteger)imageblockMemoryLengthForDimensions:(MTLSize)d { return 0; }
- (id<MTLDevice>)device { return (id<MTLDevice>)gNVMTLMainDevice; }
- (MTLShaderValidation)shaderValidation { return MTLShaderValidationDisabled; }
static NSUInteger nvmtl_env_uint(NSString *k, NSUInteger dflt) {
    NSString *s = [[NSProcessInfo processInfo] environment][k];
    return s.length ? (NSUInteger)s.integerValue : dflt;
}
static NSUInteger nvmtl_compute_maxt(void) { static NSUInteger v; if (!v) v = nvmtl_env_uint(@"NVMTL_MAXT", 1024); return v; }
- (NSUInteger)maxTotalThreadsPerThreadgroup { NSUInteger v = nvmtl_compute_maxt(), n = _attrT ?: _askT; return n && n < v ? n : v; }
- (NSUInteger)threadExecutionWidth { static NSUInteger v; if (!v) v = nvmtl_env_uint(@"NVMTL_TEW", 32); return v; }
- (NSUInteger)staticThreadgroupMemoryLength { return 0; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l {}
@end

@implementation NVMTLIndirectCommand
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)ps { _ps = ps; }
- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i {
    if (!_vbufs) _vbufs = [NSMutableArray new];
    if (b) [_vbufs addObject:@[b, @(o), @(i)]];
}
- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o attributeStride:(NSUInteger)st atIndex:(NSUInteger)i {
    if (!_vbufs) _vbufs = [NSMutableArray new];
    if (b) [_vbufs addObject:@[b, @(o), @(i), @(st)]];
}
- (void)setFragmentBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i {
    if (!_fbufs) _fbufs = [NSMutableArray new];
    if (b) [_fbufs addObject:@[b, @(o), @(i)]];
}
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)s vertexCount:(NSUInteger)c
         instanceCount:(NSUInteger)n baseInstance:(NSUInteger)bi {
    _type = type; _start = s; _count = c; _instances = n; _baseInstance = bi; _indexed = NO; _armed = YES;
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexCount:(NSUInteger)c indexType:(MTLIndexType)it
                  indexBuffer:(id<MTLBuffer>)ib indexBufferOffset:(NSUInteger)io
                instanceCount:(NSUInteger)n baseVertex:(NSInteger)bv baseInstance:(NSUInteger)bi {
    _type = type; _count = c; _itype = it; _ibuf = ib; _ioff = io;
    _instances = n; _baseVertex = bv; _baseInstance = bi; _indexed = YES; _armed = YES;
}
- (void)setComputePipelineState:(id<MTLComputePipelineState>)ps { _cps = ps; _isCompute = YES; }
- (void)setKernelBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i {
    if (!_kbufs) _kbufs = [NSMutableArray new];
    if (b) [_kbufs addObject:@[b, @(o), @(i)]];
}
- (void)concurrentDispatchThreadgroups:(MTLSize)grid threadsPerThreadgroup:(MTLSize)tg {
    _grid = grid; _tg = tg; _isCompute = YES; _armed = YES;
}
- (void)concurrentDispatchThreads:(MTLSize)threads threadsPerThreadgroup:(MTLSize)tg {
    MTLSize g = { (threads.width + tg.width - 1) / tg.width,
                  (threads.height + tg.height - 1) / tg.height,
                  (threads.depth + tg.depth - 1) / tg.depth };
    [self concurrentDispatchThreadgroups:g threadsPerThreadgroup:tg];
}
- (void)setBarrier {}
- (void)clearBarrier {}
- (void)setThreadgroupMemoryLength:(NSUInteger)len atIndex:(NSUInteger)i {
    if (len) nvlog("indirect command setThreadgroupMemoryLength:%lu — dynamic threadgroup memory is not wired; IGNORED", (unsigned long)len);
}
- (void)setStageInRegion:(MTLRegion)r {}
- (void)setCullMode:(MTLCullMode)m { _cull = m; _hasCull = YES; }
- (void)setFrontFacingWinding:(MTLWinding)w { _winding = w; _hasWinding = YES; }
- (void)setTriangleFillMode:(MTLTriangleFillMode)f { _fill = f; _hasFill = YES; }
- (void)setDepthClipMode:(MTLDepthClipMode)c { _clip = c; _hasClip = YES; }
- (void)setDepthStencilState:(id<MTLDepthStencilState>)d { _ds = d; }
- (void)setDepthBias:(float)b slopeScale:(float)s clamp:(float)c { _bias = b; _slope = s; _clamp = c; _hasBias = YES; }
- (void)nvmtlCopyFrom:(NVMTLIndirectCommand *)o {
    if (!o || o == self) return;
    _ps = o->_ps; _vbufs = [o->_vbufs mutableCopy]; _fbufs = [o->_fbufs mutableCopy];
    _type = o->_type; _start = o->_start; _count = o->_count; _instances = o->_instances; _baseInstance = o->_baseInstance;
    _ibuf = o->_ibuf; _ioff = o->_ioff; _itype = o->_itype; _baseVertex = o->_baseVertex; _indexed = o->_indexed; _armed = o->_armed;
    _cull = o->_cull; _hasCull = o->_hasCull; _winding = o->_winding; _hasWinding = o->_hasWinding; _fill = o->_fill; _hasFill = o->_hasFill;
    _clip = o->_clip; _hasClip = o->_hasClip; _ds = o->_ds; _bias = o->_bias; _slope = o->_slope; _clamp = o->_clamp; _hasBias = o->_hasBias;
    _cps = o->_cps; _kbufs = [o->_kbufs mutableCopy]; _grid = o->_grid; _tg = o->_tg; _isCompute = o->_isCompute;
}
- (void)reset {
    _ps = nil; [_vbufs removeAllObjects]; [_fbufs removeAllObjects]; _ibuf = nil; _armed = NO;
    _hasCull = _hasWinding = _hasFill = _hasClip = _hasBias = NO; _ds = nil;
    _cps = nil; [_kbufs removeAllObjects]; _isCompute = NO;
}
@end

@implementation NVMTLIndirectCommandBuffer
- (id<MTLDevice>)device { return _dev; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { _label = [l copy]; }
- (NSUInteger)size { return _cmds.count; }
- (MTLResourceID)gpuResourceID { MTLResourceID r; r._impl = nvmtl_resid_pipe(self, &_resid); return r; }
- (MTLStorageMode)storageMode { return (MTLStorageMode)((_opts >> MTLResourceStorageModeShift) & 0xF); }
- (MTLCPUCacheMode)cpuCacheMode { return (MTLCPUCacheMode)(_opts & 0xF); }
- (MTLHazardTrackingMode)hazardTrackingMode { return nvmtl_res_hazard(nil, _opts); }
- (MTLResourceOptions)resourceOptions { return ((MTLResourceOptions)[self storageMode] << MTLResourceStorageModeShift) | (MTLResourceOptions)[self cpuCacheMode]
                                            | ((MTLResourceOptions)[self hazardTrackingMode] << MTLResourceHazardTrackingModeShift); }
- (id<MTLHeap>)heap { return nil; }
- (NSUInteger)heapOffset { return 0; }
- (BOOL)isAliasable { return NO; }
- (void)makeAliasable {}
- (NSUInteger)allocatedSize { return 0; }
- (kern_return_t)setOwnerWithIdentity:(task_id_token_t)t { return nvmtl_owner_check(t); }
- (id<MTLIndirectComputeCommand>)indirectComputeCommandAtIndex:(NSUInteger)i {
    if (i >= _cmds.count) { nvlog("indirectComputeCommandAtIndex:%lu — this buffer holds %lu", (unsigned long)i, (unsigned long)_cmds.count); return nil; }
    return _cmds[i];
}
- (id<MTLIndirectRenderCommand>)indirectRenderCommandAtIndex:(NSUInteger)i {
    if (i >= _cmds.count) { nvlog("indirectRenderCommandAtIndex:%lu — this buffer holds %lu", (unsigned long)i, (unsigned long)_cmds.count); return nil; }
    return _cmds[i];
}
- (void)resetWithRange:(NSRange)r {
    for (NSUInteger i = r.location; i < r.location + r.length && i < _cmds.count; i++) [_cmds[i] reset];
}
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)s { return nvmtl_purge(&_purge, s); }
@end

enum { NVMTL_E78_H3 = 1, NVMTL_E78_H4 = 2, NVMTL_E78_H5 = 4, NVMTL_E78_P1 = 8, NVMTL_E78_H7 = 16 };
enum { E78C_ENC, E78C_DISP, E78C_FULL, E78C_NARROW, E78C_NONE, E78C_ENDFULL, E78C_SETNEW, E78C_SETREUSE, E78C_WRITES,
       E78C_RING, E78C_RINGBYTES, E78C_RINGCHUNK, E78C_BYTESOLD, E78C_VARHIT, E78C_VARMISS, E78C_CONC, E78C_N };
static uint64_t g_e78c[E78C_N];
static int g_e78_off = -1, g_e78_census = -1;
static int nvmtl_bar_abab_full(void) {
    static int n = -1;
    if (n < 0) { const char *e = getenv("NVMTL_BAR_ABAB"); n = e ? atoi(e) : 0; if (n < 0) n = 0;
        if (n) nvlog_diag("barriers: NVMTL_BAR_ABAB=%d - frames f with (f/%d) odd run every compute barrier full, even windows use the relaxed rules", n, n); }
    return n && ((atomic_load_explicit(&nvmtl_flick_frame, memory_order_relaxed) / (unsigned)n) & 1u);
}
static int nvmtl_enc78_on(int row) {
    int off = __atomic_load_n(&g_e78_off, __ATOMIC_RELAXED);
    if (off < 0) {
        const char *e = getenv("NVMTL_ENC78_OFF"); off = 0;
        if (e) {
            if (strstr(e, "all")) off = 31;
            if (strstr(e, "h3")) off |= NVMTL_E78_H3;
            if (strstr(e, "h4")) off |= NVMTL_E78_H4;
            if (strstr(e, "h5")) off |= NVMTL_E78_H5;
            if (strstr(e, "p1")) off |= NVMTL_E78_P1;
            if (strstr(e, "h7")) off |= NVMTL_E78_H7;
            nvlog("denc: NVMTL_ENC78_OFF=%s -> rows off 0x%x", e, off);
        }
        __atomic_store_n(&g_e78_off, off, __ATOMIC_RELAXED);
    }
    if ((row & (NVMTL_E78_H7 | NVMTL_E78_P1)) && nvmtl_bar_abab_full()) return 0;
    return !(off & row);
}
static void nvmtl_enc78_count(int k, uint64_t n) { if (k >= 0 && k < E78C_N) __atomic_fetch_add(&g_e78c[k], n, __ATOMIC_RELAXED); }
static void nvmtl_enc78_census(void) {
    if (g_e78_census < 0) { const char *e = getenv("NVMTL_ENC78_CENSUS"); g_e78_census = e ? atoi(e) : 0; }
    uint64_t n = __atomic_add_fetch(&g_e78c[E78C_ENC], 1, __ATOMIC_RELAXED);
    if (!g_e78_census || (g_e78_census < 2 && (n & (n - 1)))) return;
    uint64_t v[E78C_N]; for (int k = 0; k < E78C_N; k++) v[k] = __atomic_load_n(&g_e78c[k], __ATOMIC_RELAXED);
    fprintf(stderr, "ENC78 enc %llu disp %llu full %llu narrow %llu none %llu endfull %llu setnew %llu setreuse %llu writes %llu "
            "ring %llu ringbytes %llu ringchunk %llu bytesold %llu varhit %llu varmiss %llu conc %llu rowsoff 0x%x\n",
            v[E78C_ENC], v[E78C_DISP], v[E78C_FULL], v[E78C_NARROW], v[E78C_NONE], v[E78C_ENDFULL], v[E78C_SETNEW],
            v[E78C_SETREUSE], v[E78C_WRITES], v[E78C_RING], v[E78C_RINGBYTES], v[E78C_RINGCHUNK], v[E78C_BYTESOLD],
            v[E78C_VARHIT], v[E78C_VARMISS], v[E78C_CONC], g_e78_off < 0 ? 0 : g_e78_off);
}
void nvmtl_vk_cmd_barrier_c2c(nvk_cmdbuf *c);
@interface NVMTLCommandBuffer () { @public NVMTLBuffer *_e78Ring; size_t _e78RingOff; } @end
@interface NVMTLCommandBuffer () { @public BOOL _g79Owed, _g79C2C; NSMutableArray *_g79Sig, *_g79Promised; } @end
enum { NVMTL_G79_DUPIDX = 32, NVMTL_G79_DUPMAX = 64 };
@interface NVMTLCommandBuffer () { @public __unsafe_unretained NVMTLBuffer *_g79BRing[NVMTL_G79_DUPIDX]; size_t _g79BOff[NVMTL_G79_DUPIDX];
    uint32_t _g79BLen[NVMTL_G79_DUPIDX]; uint8_t _g79B[NVMTL_G79_DUPIDX][NVMTL_G79_DUPMAX]; } @end
enum { NVMTL_G79_BAR = 1, NVMTL_G79_ENC = 2, NVMTL_G79_EV = 4, NVMTL_G79_DUP = 8, NVMTL_G79_WFOLD = 16, NVMTL_G79_SUB = 32 };
enum { G79C_ENCNARROW, G79C_ENCFULL, G79C_BARLAZY, G79C_BARFOLD, G79C_OWEDPAID, G79C_SIGRIDE, G79C_WAITSELF, G79C_WAITHELD, G79C_WAITSPLIT, G79C_BYTESDUP, G79C_WAITFOLD, G79C_ENDS, G79C_N };
static uint64_t g_g79c[G79C_N];
static int g_g79_off = -1;
static int nvmtl_g79_on(int row) {
    int off = __atomic_load_n(&g_g79_off, __ATOMIC_RELAXED);
    if (off < 0) {
        const char *e = getenv("NVMTL_G79_OFF"); off = 0;
        if (e) {
            if (strstr(e, "all")) off = 63;
            if (strstr(e, "bar")) off |= NVMTL_G79_BAR;
            if (strstr(e, "enc")) off |= NVMTL_G79_ENC;
            if (strstr(e, "ev")) off |= NVMTL_G79_EV;
            if (strstr(e, "dup")) off |= NVMTL_G79_DUP;
            if (strstr(e, "wfold")) off |= NVMTL_G79_WFOLD;
            if (strstr(e, "sub")) off |= NVMTL_G79_SUB;
            nvlog("gsub: NVMTL_G79_OFF=%s -> rows off 0x%x", e, off);
        }
        __atomic_store_n(&g_g79_off, off, __ATOMIC_RELAXED);
    }
    if ((row & (NVMTL_G79_BAR | NVMTL_G79_ENC)) && nvmtl_bar_abab_full()) return 0;
    return !(off & row);
}
static void nvmtl_g79_count(int k) { __atomic_fetch_add(&g_g79c[k], 1, __ATOMIC_RELAXED); }
static void nvmtl_g79_census(void) {
    static int on = -1; if (on < 0) { const char *e = getenv("NVMTL_G79_CENSUS"); on = e ? atoi(e) : 0; }
    uint64_t n = __atomic_add_fetch(&g_g79c[G79C_ENDS], 1, __ATOMIC_RELAXED);
    if (!on || (on < 2 && (n & (n - 1)))) return;
    fprintf(stderr, "G79 ends %llu encnarrow %llu encfull %llu barlazy %llu barfold %llu owedpaid %llu sigride %llu waitself %llu "
            "waitheld %llu waitsplit %llu bytesdup %llu waitfold %llu rowsoff 0x%x\n",
            n, g_g79c[G79C_ENCNARROW], g_g79c[G79C_ENCFULL], g_g79c[G79C_BARLAZY], g_g79c[G79C_BARFOLD], g_g79c[G79C_OWEDPAID],
            g_g79c[G79C_SIGRIDE], g_g79c[G79C_WAITSELF], g_g79c[G79C_WAITHELD], g_g79c[G79C_WAITSPLIT],
            g_g79c[G79C_BYTESDUP], g_g79c[G79C_WAITFOLD], g_g79_off < 0 ? 0 : g_g79_off);
}
// A compute encoder's dispatches carry their barriers BEFORE them, so after its last dispatch nothing orders its writes
// against what comes next. The next compute encoder's first dispatch brings its own (compute-to-compute) barrier; a
// render, blit or acceleration-structure encoder brings none, so it pays a full one here whenever compute ran last.
// WAS: only when a loose (compute-only) barrier was owed - a render pass after a compute encoder whose dispatches all had
// full barriers read the compute results unordered: GPU-culled draw lists and indirect arguments from the previous
// frame, so objects that had just come into view were missing for a frame (Cyberpunk 2077 flashing black while moving).
static int nvmtl_c2r_barrier_on(void) {
    static int v = -1;
    if (v < 0) { const char *e = getenv("NVMTL_G79_RENDER_BARRIER"); v = !(e && e[0] == '0');
        nvlog("encoders: %s (NVMTL_G79_RENDER_BARRIER=%s)", v ? "a render/blit/AS encoder after compute work starts with a full barrier"
                                                     : "a render/blit/AS encoder after compute work is ordered only when a loose barrier was owed (old rule)", e ? e : "unset"); }
    return v;
}
static _Atomic uint64_t g_c2r_paid;
static void nvmtl_g79_flush(NVMTLCommandBuffer *cb) {
    if (!cb) return;
    if (cb->_g79Owed || (cb->_g79C2C && nvmtl_c2r_barrier_on())) {
        if (!cb->_g79Owed) { const uint64_t k = atomic_fetch_add(&g_c2r_paid, 1) + 1;
            if (!(k & (k - 1)) && k >= 64) nvlog("encoders: %llu compute-to-render/blit barriers added that the old rule skipped", (unsigned long long)k); }
        nvmtl_vk_cmd_barrier(&cb->_c); cb->_g79Owed = NO; nvmtl_g79_count(G79C_OWEDPAID);
    }
    cb->_g79C2C = NO;
}
@interface NVMTLComputeCommandEncoder () {
@public
    NSMutableArray *_flkTex;
    NSData *_e78Key;
    NVMTLComputePipelineState *_e78VarFor, *_e78VarSel;
    NSUInteger _e78NDisp; BOOL _e78Concurrent, _e78Loose;
    BOOL _g79Bar;
}
@end
enum { NVMTL_E78_RING = 64 * 1024, NVMTL_E78_RING_ALIGN = 256, NVMTL_E78_RING_MAX = 16 * 1024 };
static NVMTLBuffer *nvmtl_bytes_ring(NVMTLCommandBuffer *cb, NSUInteger len, size_t *off) {
    size_t need = len < 16 ? 16 : len;
    if (!cb || need > NVMTL_E78_RING_MAX || !nvmtl_enc78_on(NVMTL_E78_H4)) return nil;
    size_t at = (cb->_e78RingOff + NVMTL_E78_RING_ALIGN - 1) & ~(size_t)(NVMTL_E78_RING_ALIGN - 1);
    if (!cb->_e78Ring || at + need > cb->_e78Ring->_b.size) {
        NVMTLBuffer *r = [NVMTLBuffer new];
        if (nvmtl_vk_buffer_create_tables(NVMTL_E78_RING, &r->_b, 1) || !r->_b.map) {
            static int said; if (!said++) nvlog("denc: setBytes ring chunk create failed - per-call buffers instead");
            return nil;
        }
        if (!cb->_scratch) cb->_scratch = [NSMutableArray new];
        [cb->_scratch addObject:r];
        cb->_e78Ring = r; at = 0;
        nvmtl_enc78_count(E78C_RINGCHUNK, 1);
    }
    cb->_e78RingOff = at + need; *off = at;
    return cb->_e78Ring;
}

#include "nvconv_lib.h"
@interface NVMTLComputeCommandEncoder () { @public uint8_t _nvcKP[528]; uint32_t _nvcKPLen; uint8_t _nvcCP[272]; uint32_t _nvcCPLen; BOOL _nvcIn; } @end
static id<MTLComputePipelineState> g_nvc_ps[7];
#define NVC_CMP 6
#define NVC_NVAR 5
static NSMutableDictionary *g_nvc_state;
static pthread_mutex_t g_nvc_lk = PTHREAD_MUTEX_INITIALIZER;
static _Atomic unsigned long g_nvc_ran, g_nvc_verified, g_nvc_refused, g_nvc_skips;
#define NVC_SKIP(why) do { const unsigned long k_ = ++g_nvc_skips; if (k_ <= 16) nvlog("nvconv: not taken - %s (%lu)", why, k_); return 0; } while (0)
static BOOL nvmtl_nvconv_ready(id<MTLDevice> dev) {
    static int on = -1;
    if (on >= 0) return on;
    pthread_mutex_lock(&g_nvc_lk);
    if (on < 0) {
        const char *e = getenv("NVMTL_NVCONV"); on = !(e && e[0] == '0');
        if (on) {
            NSError *err = nil;
            dispatch_data_t dd = dispatch_data_create(nvconv_metallib, nvconv_metallib_len, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            id<MTLLibrary> lib = [dev newLibraryWithData:dd error:&err];
            NSString *names[7] = { @"nvconv3_b", @"nvconv3_s", @"nvconv4_b", @"nvconv4_s", @"nvconv5_b", @"nvconv5_s", @"nvconv_cmp" };
            for (int i = 0; i < 7 && on; i++) {
                id<MTLFunction> f = [lib newFunctionWithName:names[i]];
                g_nvc_ps[i] = f ? [dev newComputePipelineStateWithFunction:f error:&err] : nil;
                if (!g_nvc_ps[i]) { on = 0; nvlog("nvconv: %s did not build (%s) - MPS's conv stays everywhere", names[i].UTF8String, err.description.UTF8String); }
            }
            g_nvc_state = [NSMutableDictionary new];
        }
        nvlog("nvconv: verified MPS-conv fast path %s (NVMTL_NVCONV=%s)", on ? "ON" : "OFF", e ? e : "unset");
    }
    pthread_mutex_unlock(&g_nvc_lk);
    return on;
}
static void nvmtl_nvconv_run(NVMTLComputeCommandEncoder *e, id<MTLComputePipelineState> ps, MTLSize grid, uint32_t variant) {
    NVMTLComputePipelineState *saved = e->_ps; NSMutableDictionary *savedTG = e->_tgLen;
    e->_ps = (NVMTLComputePipelineState *)ps; e->_tgLen = nil; e->_nvcIn = YES;
    [e setBytes:&variant length:4 atIndex:30];
    [e dispatchThreadgroups:grid threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
    e->_nvcIn = NO; e->_ps = saved; e->_tgLen = savedTG;
}
static int nvmtl_nvconv_try(NVMTLComputeCommandEncoder *e, MTLSize grid, MTLSize tg) {
    if (e->_nvcIn || !e->_ps || !e->_ps->_function || ![e->_ps->_function->_fname isEqualToString:@"ndArrayConvolution2D"]) return 0;
    const uint32_t nar = e->_nvcKPLen == 368 ? 3 : e->_nvcKPLen == 448 ? 4 : e->_nvcKPLen == 528 ? 5 : 0;
    if (!nar || e->_nvcCPLen != 272) {
        char why[200]; const uint32_t *w = (const uint32_t *)e->_nvcKP;
        snprintf(why, sizeof why, "parameter blocks %u / %u bytes (first array sizes %u,%u,%u,%u, second %u,%u,%u,%u)", e->_nvcKPLen, e->_nvcCPLen,
                 w[4], w[5], w[6], w[7], w[24], w[25], w[26], w[27]);
        NVC_SKIP(why);
    }
    id<MTLDevice> dev = [e->_cb device];
    if (!nvmtl_nvconv_ready(dev)) return 0;
    const uint32_t *kp = (const uint32_t *)e->_nvcKP, *cp = (const uint32_t *)e->_nvcCP;
    const uint32_t cin = cp[32], cout = cp[33], kw = cp[34], kh = cp[35], groups = cp[36], batch = cp[37], sw = cp[38], sh = cp[39], dw = cp[40], dh = cp[41];
    if (groups != 1 || !cin || !cout || !kw || !kh || !batch || !sw || !sh || !dw || !dh) NVC_SKIP("groups/dims");
    for (uint32_t a = 0; a < nar; a++) if (kp[a * 20] | kp[a * 20 + 1] | kp[a * 20 + 2] | kp[a * 20 + 3]) NVC_SKIP("array offset");
    const uint32_t ob = (nar - 1) * 20;
    if (kp[4] != cin || kp[5] != sw || kp[6] != sh || kp[7] != batch || kp[8] != 1) NVC_SKIP("input descriptor");
    if (kp[24] != cout || kp[25] != cin || kp[26] != kw || kp[27] != kh || kp[28] != 1) NVC_SKIP("weights descriptor");
    if (kp[ob + 4] != cout || kp[ob + 5] != dw || kp[ob + 6] != dh || kp[ob + 7] != batch) NVC_SKIP("output sizes");
    if (kp[ob + 8] != 1 || (dw > 1 && kp[ob + 9] != cout) || (dh > 1 && kp[ob + 10] != cout * dw) || (batch > 1 && kp[ob + 11] != cout * dw * dh)) {
        char why[160]; snprintf(why, sizeof why, "output strides %u,%u,%u,%u for cout %u x %u x %u (sizes %u,%u,%u,%u)",
                                kp[ob + 8], kp[ob + 9], kp[ob + 10], kp[ob + 11], cout, dw, dh, kp[ob + 4], kp[ob + 5], kp[ob + 6], kp[ob + 7]);
        NVC_SKIP(why); }
    if (nar >= 4 && (kp[44] != cout || kp[48] != 1)) NVC_SKIP("bias descriptor");
    if (nar == 5 && (kp[64] != cout || kp[65] != dw || kp[66] != dh || kp[67] != batch || kp[68] != 1 || (dw > 1 && kp[69] != cout) || (dh > 1 && kp[70] != cout * dw)))
        NVC_SKIP("residual descriptor");
    NSArray *bi = e->_bufAt[@0], *bw = e->_bufAt[@1], *bo = e->_bufAt[@(nar - 1)], *bb = nar >= 4 ? e->_bufAt[@2] : nil, *br = nar == 5 ? e->_bufAt[@3] : nil;
    if (!bi || !bw || !bo || (nar >= 4 && !bb) || (nar == 5 && !br)) NVC_SKIP("buffer slot unbound");
    #define NVC_ROOM(arr, need) ([(id<MTLBuffer>)arr[0] length] >= [arr[1] unsignedLongValue] + (uint64_t)(need) * 4)
    const uint64_t nin = (uint64_t)(cin - 1) * kp[8] + (uint64_t)(sw - 1) * kp[9] + (uint64_t)(sh - 1) * kp[10] + (uint64_t)(batch - 1) * kp[11] + 1;
    const uint64_t nwt = (uint64_t)(cout - 1) * kp[28] + (uint64_t)(cin - 1) * kp[29] + (uint64_t)(kw - 1) * kp[30] + (uint64_t)(kh - 1) * kp[31] + 1;
    const uint64_t nout = (uint64_t)cout * dw * dh * batch;
    if (!NVC_ROOM(bi, nin) || !NVC_ROOM(bw, nwt) || !NVC_ROOM(bo, nout) || (bb && !NVC_ROOM(bb, cout)) || (br && !NVC_ROOM(br, nout)) || nout > 0xffffffffull) NVC_SKIP("buffer too short for f32");
    #undef NVC_ROOM
    const uint64_t M = (uint64_t)batch * dh * dw;
    const BOOL small = ((M + 127) / 128) * ((cout + 63) / 64) < 60;
    id<MTLComputePipelineState> ours = g_nvc_ps[(nar - 3) * 2 + (small ? 1 : 0)];
    const MTLSize og = small ? MTLSizeMake((M + 63) / 64, (cout + 31) / 32, 1) : MTLSizeMake((M + 127) / 128, (cout + 63) / 64, 1);
    NSMutableData *key = [NSMutableData dataWithBytes:&e->_ps length:sizeof(void *)];
    for (uint32_t a = 0; a < nar; a++) [key appendBytes:kp + a * 20 + 4 length:8 * 4];
    [key appendBytes:cp + 32 length:18 * 4];
    pthread_mutex_lock(&g_nvc_lk); NSNumber *st = g_nvc_state[key]; if (!st) g_nvc_state[key] = @0; pthread_mutex_unlock(&g_nvc_lk);
    if (st.intValue > 0) { nvmtl_nvconv_run(e, ours, og, (uint32_t)(st.intValue - 1)); g_nvc_ran++; return 1; }
    if (st) { static _Atomic unsigned long pend; if (st.intValue == 0 && ++pend <= 8) nvlog("nvconv: still pending (%lu)", (unsigned long)pend); return 0; }
    e->_nvcIn = YES; [e dispatchThreadgroups:grid threadsPerThreadgroup:tg]; e->_nvcIn = NO;
    id<MTLBuffer> outBuf = bo[0]; const NSUInteger outOff = [bo[1] unsignedLongValue];
    id<MTLBuffer> res = [dev newBufferWithLength:32 + 48 options:MTLResourceStorageModeShared];
    memset(res.contents, 0, 32 + 48);
    const uint32_t n = (uint32_t)nout;
    for (uint32_t v = 0; v < NVC_NVAR; v++) {
        id<MTLBuffer> scratch = [dev newBufferWithLength:(NSUInteger)nout * 4 options:MTLResourceStorageModePrivate];
        [e setBuffer:scratch offset:0 atIndex:nar - 1];
        nvmtl_nvconv_run(e, ours, og, v);
        NVMTLComputePipelineState *saved = e->_ps; NSMutableDictionary *savedTG = e->_tgLen;
        e->_ps = (NVMTLComputePipelineState *)g_nvc_ps[NVC_CMP]; e->_tgLen = nil; e->_nvcIn = YES;
        [e setBuffer:outBuf offset:outOff atIndex:5]; [e setBuffer:scratch offset:0 atIndex:6]; [e setBuffer:res offset:v * 4 atIndex:7];
        [e setBytes:&n length:4 atIndex:8]; [e setBuffer:res offset:32 atIndex:9];
        [e dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
        e->_nvcIn = NO; e->_ps = saved; e->_tgLen = savedTG;
    }
    [e setBuffer:outBuf offset:outOff atIndex:nar - 1];
    char shape[96]; snprintf(shape, sizeof shape, "%ux%ux%u -> %u k%ux%u s%u,%u form %u", sw, sh, cin, cout, kw, kh, cp[46], cp[47], nar);
    NSString *sh_ = @(shape);
    { static _Atomic unsigned long issued; const unsigned long k = ++issued; if (k <= 96) nvlog("nvconv: verifying %s (%lu issued)", shape, k); }
    [e->_cb addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        const uint32_t *r = (const uint32_t *)res.contents; int pick = 0;
        for (int v = 0; v < NVC_NVAR && !pick; v++) if (r[v] == 0) pick = v + 1;
        pthread_mutex_lock(&g_nvc_lk); g_nvc_state[key] = @(pick ? pick : -1); pthread_mutex_unlock(&g_nvc_lk);
        if (pick) { const unsigned long k = ++g_nvc_verified; if (k <= 64 || !(k & (k - 1))) nvlog("nvconv: VERIFIED %s epilogue %d (%lu so far)", sh_.UTF8String, pick - 1, k); }
        else { const unsigned long k = ++g_nvc_refused; const float *sp = (const float *)(r + 8);
            if (k <= 64 || !(k & (k - 1))) nvlog("nvconv: REFUSED %s - mismatches %u/%u/%u/%u/%u of %u, MPS keeps it (%lu so far); MPS/ours(prelu) %g/%g %g/%g %g/%g %g/%g", sh_.UTF8String,
                                                  r[0], r[1], r[2], r[3], r[4], n, k, sp[0], sp[1], sp[2], sp[3], sp[4], sp[5], sp[6], sp[7]); }
    }];
    return 1;
}

@interface NVMTLCommandBuffer (EventSubmissionSeal)
- (void)nvmtlSealPartWithSignal:(id)event value:(uint64_t)value restart:(BOOL)restart;
@end

// NVMTL_LASTK_WATCH=all (or <hash>[,<hash>...]): every dispatch of the watched kernels records every bound buffer
// (index, GPU VA, offset, length) and, through the Metal Shader Converter top-level argument buffer bound at index 2,
// the gpuVA of the first 8 entries of the descriptor tables its root slots +8 and +40 point at. 4096 records, written
// out with the device-loss record with the VkCommandBuffer and ordinal of each dispatch, so the writers, clearers
// and readers of a buffer (a counter, a list) can be listed offline in the order the GPU ran them.
static uint32_t nvmtl_spv_hash(NSData *d);
enum { NVMTL_WATCH_N = 4096, NVMTL_WATCH_B = 10 };
typedef struct { uint32_t hash; const void *vkcb; uint32_t ordinal, nb; uint32_t t[3]; uint32_t crumb;
                 struct { uint32_t index; uint64_t va, off, size; uint8_t head[16]; int has_head; } b[NVMTL_WATCH_B];
                 uint64_t tab[2], ent[2][8], vid[2][8]; } nvmtl_watch_rec;
static nvmtl_watch_rec *nvmtl_watch;
static _Atomic unsigned nvmtl_watch_next;
static __thread nvmtl_watch_rec *nvmtl_watch_last;   // the record of the dispatch being encoded; its crumb id is set after vkCmdDispatch
static void nvmtl_lastk_watch_crumb(void) { if (nvmtl_watch_last) { nvmtl_watch_last->crumb = nvmtl_vk_crumb_now(); nvmtl_watch_last = NULL; } }
static int nvmtl_lastk_watched(uint32_t h)
{
    static int v = -1, all; static uint32_t hs[8]; static unsigned n;
    if (v < 0) { v = 1; const char *e = getenv("NVMTL_LASTK_WATCH");
        if (e && !strcmp(e, "all")) all = 1;
        else while (e && *e && n < 8) { char *end; hs[n] = (uint32_t)strtoul(e, &end, 16); if (end == e) break; n++; e = (*end == ',') ? end + 1 : end; } }
    if (all) return 1;
    for (unsigned i = 0; i < n; i++) if (hs[i] == h) return 1;
    return 0;
}
static int nvmtl_watch_on(void) { static int v = -1; if (v < 0) v = getenv("NVMTL_LASTK_WATCH") != NULL; return v; }
// the buffer holding a GPU VA, with a one-entry cache: the descriptor tables of a frame live in one or two buffers
static const uint8_t *nvmtl_watch_cpu_at(uint64_t va, size_t need)
{
    static __thread uint64_t cb_base, cb_size; static __thread const uint8_t *cb_cpu; static __thread void *cb_obj;
    if (!(cb_cpu && va >= cb_base && va + need <= cb_base + cb_size)) {
        uint64_t base = 0; NVMTLBuffer *b = nvmtl_buffer_for_va(va, &base);
        if (!b) return NULL;
        cb_base = base; cb_size = b->_b.size; cb_cpu = nvmtl_buf_cpu(b); cb_obj = (__bridge void *)b;
        if (!cb_cpu || va + need > cb_base + cb_size) { cb_cpu = NULL; return NULL; }
    }
    return cb_cpu + (va - cb_base);
}
static void nvmtl_lastk_watch(NVMTLComputeCommandEncoder *e, NVMTLComputePipelineState *ps, const uint32_t t[3])
{
    if (!nvmtl_watch_on() || !ps || !ps->_function || !e->_cb) return;
    if (!ps->_spvHash && ps->_function->_spirv.length) ps->_spvHash = nvmtl_spv_hash(ps->_function->_spirv);
    if (!nvmtl_lastk_watched(ps->_spvHash)) return;
    if (!nvmtl_watch) { static dispatch_once_t once; dispatch_once(&once, ^{ nvmtl_watch = calloc(NVMTL_WATCH_N, sizeof *nvmtl_watch); }); if (!nvmtl_watch) return; }
    unsigned k = atomic_fetch_add(&nvmtl_watch_next, 1u) % NVMTL_WATCH_N;
    nvmtl_watch_rec *r = &nvmtl_watch[k]; memset(r, 0, sizeof *r); nvmtl_watch_last = r;
    r->hash = ps->_spvHash; r->vkcb = e->_cb->_c.cb; r->ordinal = e->_cb->_c.lastk_n ? e->_cb->_c.lastk_n - 1 : 0;
    if (t) memcpy(r->t, t, sizeof r->t);
    const uint8_t *ab = NULL;
    for (NSNumber *key in e->_bufAt) {
        if (r->nb >= NVMTL_WATCH_B) break;
        NSArray *a = e->_bufAt[key]; if (![a isKindOfClass:[NSArray class]] || a.count < 2) continue;
        NVMTLBuffer *nb = a[0]; if (![nb isKindOfClass:[NVMTLBuffer class]]) continue;
        const unsigned q = r->nb++;
        r->b[q].index = key.unsignedIntValue; r->b[q].va = nvmtl_vk_buffer_address(&nb->_b); r->b[q].off = [a[1] unsignedLongLongValue]; r->b[q].size = nb->_b.size;
        { const uint8_t *c = nvmtl_buf_cpu(nb); if (c && r->b[q].off + 16 <= nb->_b.size) { memcpy(r->b[q].head, c + r->b[q].off, 16); r->b[q].has_head = 1; } }
        if (key.unsignedIntValue == 2) { const uint8_t *c = nvmtl_buf_cpu(nb); if (c && r->b[q].off + 48 <= nb->_b.size) ab = c + r->b[q].off; }
    }
    if (!ab) return;
    const unsigned slots[2] = { 8, 40 };
    for (unsigned s = 0; s < 2; s++) {
        uint64_t tv; memcpy(&tv, ab + slots[s], 8); r->tab[s] = tv;
        const uint8_t *tc = tv ? nvmtl_watch_cpu_at(tv, 8 * 24) : NULL;
        if (!tc) continue;
        for (unsigned q = 0; q < 8; q++) { memcpy(&r->ent[s][q], tc + 24 * q, 8); memcpy(&r->vid[s][q], tc + 24 * q + 8, 8); }
    }
}
static void nvmtl_lastk_watch_dump(FILE *fp)
{
    unsigned n = atomic_load(&nvmtl_watch_next), k = n < NVMTL_WATCH_N ? n : NVMTL_WATCH_N;
    if (!n || !nvmtl_watch) return;
    fprintf(fp, "# %u watched dispatch(es), the last %u (oldest first); W <hash> <VkCommandBuffer> #<ordinal> threads | b<index>=VA+off/len ... | t8=<table> [entries] t40=<table> [entries]\n", n, k);
    for (unsigned j = 0; j < k; j++) {
        const nvmtl_watch_rec *r = &nvmtl_watch[(n - k + j) % NVMTL_WATCH_N];
        fprintf(fp, "W %08x %p #%u %ux%ux%u crumb %u |", r->hash, r->vkcb, r->ordinal, r->t[0], r->t[1], r->t[2], r->crumb);
        for (unsigned q = 0; q < r->nb; q++) {
            fprintf(fp, " b%u=0x%llx+0x%llx/0x%llx", r->b[q].index, (unsigned long long)r->b[q].va, (unsigned long long)r->b[q].off, (unsigned long long)r->b[q].size);
            if (r->b[q].has_head) { uint32_t v[4]; memcpy(v, r->b[q].head, 16); fprintf(fp, "{%x,%x,%x,%x}", v[0], v[1], v[2], v[3]); }
        }
        for (unsigned s = 0; s < 2; s++) {
            fprintf(fp, " | t%u=0x%llx [", s ? 40 : 8, (unsigned long long)r->tab[s]);
            for (unsigned q = 0; q < 8; q++) fprintf(fp, "%s%llx", q ? " " : "", (unsigned long long)r->ent[s][q]);
            fprintf(fp, "]");
        }
        fprintf(fp, "\n");
        // every texture entry: the token, its heap slot, what the slot holds now, and the object behind the token
        if (j + 600 >= k) for (unsigned s = 0; s < 2; s++) for (unsigned q = 0; q < 8; q++) {
            const uint64_t v = r->vid[s][q]; if (!v) continue;
            extern id nvmtl_resid_resource(uint64_t token);
            const uint32_t slot = (v >> 62) & 1 ? (uint32_t)(v & 0xffffffffu) : 0;
            void *sv = NULL, *ss = NULL, *st = NULL; uint32_t sts = 0, sw = 0;
            if (slot) nvmtl_vk_bindless_shadow(slot, &sv, &ss, &st, &sts, &sw);
            id obj = nvmtl_resid_resource(v);
            fprintf(fp, "   t%u[%u] gpuVA 0x%llx view 0x%llx slot %u: slot holds view %p storage %p texel %p%s texelStorage %u (%u writes) |",
                    s ? 40 : 8, q, (unsigned long long)r->ent[s][q], (unsigned long long)v, slot, sv, ss, st, st && st == nvmtl_vk_dummy_texel_view() ? " (DUMMY)" : "", sts, sw);
            if ([obj isKindOfClass:[NVMTLTexture class]]) {
                NVMTLTexture *t = obj;
                fprintf(fp, " object %p type %lu fmt %lu usage 0x%lx %lux%lu tbView %p tbStorage %d backBuf VA 0x%llx+0x%lx\n", (__bridge void *)t,
                        (unsigned long)t.textureType, (unsigned long)t->_fmt, (unsigned long)t->_usage, (unsigned long)t.width, (unsigned long)t.height,
                        t->_tbView, (int)t->_tbStorage, t->_backBuf ? (unsigned long long)nvmtl_vk_buffer_address(&t->_backBuf->_b) : 0ull, (unsigned long)t->_backOff);
            } else fprintf(fp, " object %s\n", obj ? object_getClassName(obj) : "GONE (released)");
        }
    }
}
@implementation NVMTLComputeCommandEncoder
- (unsigned long long)globalTraceObjectID { return nvmtl_global_trace_id(self); }
static void nvmtl_stride_dropped(NSUInteger st) { static BOOL said; if (!said && st) { said = YES;
    nvlog("compute: attributeStride %lu dropped (dynamic strides not implemented) - buffer bound", (unsigned long)st); } }
- (void)setBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o attributeStride:(NSUInteger)st atIndex:(NSUInteger)i {
    nvmtl_stride_dropped(st); [self setBuffer:b offset:o atIndex:i]; }
- (void)setBufferOffset:(NSUInteger)o attributeStride:(NSUInteger)st atIndex:(NSUInteger)i {
    nvmtl_stride_dropped(st); [self setBufferOffset:o atIndex:i]; }
- (void)setBuffers:(const id<MTLBuffer> __unsafe_unretained [])bs offsets:(const NSUInteger *)offs attributeStrides:(const NSUInteger *)sts withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) [self setBuffer:bs ? bs[k] : nil offset:offs ? offs[k] : 0 attributeStride:sts ? sts[k] : 0 atIndex:r.location + k]; }
- (void)setBytes:(const void *)bytes length:(NSUInteger)len attributeStride:(NSUInteger)st atIndex:(NSUInteger)i {
    nvmtl_stride_dropped(st); [self setBytes:bytes length:len atIndex:i]; }
- (void)useHeaps:(const id<MTLHeap> __unsafe_unretained [])hs count:(NSUInteger)n { (void)hs; atomic_fetch_add(&g_h_useheap, n); }
- (void)setSamplerStates:(const id<MTLSamplerState> __unsafe_unretained [])s lodMinClamps:(const float *)lo lodMaxClamps:(const float *)hi withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++)
        [self setSamplerState:s ? s[k] : nil lodMinClamp:lo ? lo[k] : 0.0f lodMaxClamp:hi ? hi[k] : FLT_MAX atIndex:r.location + k]; }
- (MTLDispatchType)dispatchType { return _e78Concurrent ? MTLDispatchTypeConcurrent : MTLDispatchTypeSerial; }
- (NVMTLComputePipelineState *)nvmtlSamplerPipeline {
    if (!_ps) return nil;
    NVMTLComputePipelineState *selected = _ps;
    if ((_samplers.count || _tgLen.count) && _e78VarSel && _e78VarFor == _ps && nvmtl_enc78_on(NVMTL_E78_H5)) {
        selected = _e78VarSel; nvmtl_enc78_count(E78C_VARHIT, 1);
    } else if (_samplers.count || _tgLen.count) {
        if (!_e78Key || !nvmtl_enc78_on(NVMTL_E78_H5))
            _e78Key = [NSJSONSerialization dataWithJSONObject:@{@"s": _samplers ?: @{}, @"tg": _tgLen ?: @{}} options:NSJSONWritingSortedKeys error:NULL];
        NSData *key = _e78Key;
        nvmtl_enc78_count(E78C_VARMISS, 1);
        @synchronized (_ps) {
            if (!_ps->_samplerVariants) _ps->_samplerVariants = [NSMutableDictionary new];
            id cached = _ps->_samplerVariants[key];
            if (cached == [NSNull null]) return nil;
            selected = cached;
            if (!selected) {
                NSString *why = nil;
                NSData *spirv = nvmtl_translate_variant(_ps->_function, _samplers, _tgLen, &why);
                if (spirv) {
                    selected = [NVMTLComputePipelineState new];
                    if (nvmtl_vk_compute_pipeline_create(spirv.bytes, spirv.length, &selected->_p)) {
                        selected = nil; why = @"Vulkan compute pipeline creation failed";
                    }
                }
                if (!selected) {
                    nvlog("compute pixel sampler specialization REFUSED %s: %s", _ps->_function->_fname.UTF8String, why.UTF8String);
                    _ps->_samplerVariants[key] = [NSNull null];
                    return nil;
                }
                _ps->_samplerVariants[key] = selected;
                nvlog("compute pixel sampler variant built: %s", _ps->_function->_fname.UTF8String);
            }
        }
        _e78VarFor = _ps; _e78VarSel = selected;
    }
    nvmtl_retain_resource(_cb, selected);
    nvmtl_bind_embedded_dict(_cb, NVMTL_SET_VERTEX, _ps->_function, _bufAt);
    return selected;
}
static int nvmtl_zprobe_on(void);
- (void)setComputePipelineState:(id<MTLComputePipelineState>)ps { _ps = (NVMTLComputePipelineState *)ps; nvmtl_retain_resource(_cb, ps);
    { NVMTLFunction *kf = _ps ? _ps->_function : nil; NSData *kd = kf ? kf->_spirv : nil; uint32_t kh = 2166136261u;
      if (kd.length) { const uint8_t *b = kd.bytes; for (NSUInteger i = 0; i < kd.length; i++) { kh ^= b[i]; kh *= 16777619u; } }
      nvtrace("KPSO %p %s cs %08x", (__bridge void *)ps, kf ? kf->_fname.UTF8String : "?", kd.length ? kh : 0u); }
    if (ps && nvmtl_zprobe_on())
        nvlog("ZENC setPipeline %s  tew=%lu maxT=%lu staticTG=%lu",
              _ps && _ps->_function ? _ps->_function->_fname.UTF8String : "?",
              (unsigned long)[ps threadExecutionWidth], (unsigned long)[ps maxTotalThreadsPerThreadgroup],
              (unsigned long)[ps staticThreadgroupMemoryLength]);
}
- (void)setBuffer:(id<MTLBuffer>)b offset:(NSUInteger)off atIndex:(NSUInteger)i {
    NVMTLBuffer *nb = nvmtl_as_buffer(b, "compute setBuffer"); if (b && !nb) return;
    if (!nb) {
        [_bufAt removeObjectForKey:@(i)];   // the binding table must not keep the previous resource
        size_t zoff = 0;
        NVMTLBuffer *zb = nvmtl_bytes_ring(_cb, 16, &zoff);
        const BOOL zring = zb != nil;
        if (!zring) {
            zb = [NVMTLBuffer new];
            if (nvmtl_vk_buffer_create(16, 1, &zb->_b)) { nvlog("compute setBuffer: nil at %lu - zero buffer create FAILED", (unsigned long)i); return; }
        }
        if (zb->_b.map) nvmtl_devset0((uint8_t *)zb->_b.map + zoff, 16);
        if (nvmtl_vk_bind_buffer(&_cb->_c, NVMTL_SET_VERTEX, (uint32_t)i, &zb->_b, zoff)) nvlog("compute setBuffer: nil at %lu - bind FAILED", (unsigned long)i);
        if (!zring) {
            if (!_cb->_scratch) _cb->_scratch = [NSMutableArray new];
            [_cb->_scratch addObject:zb];
        }
        if (nvmtl_zprobe_on()) nvlog("ZENC setBuffer  idx %-3lu len 0        off 0  (nil -> zero-filled)", (unsigned long)i);
        return;
    }
    if (!_cb->_resources) _cb->_resources = [NVMTLResSet new];
    [_cb->_resources addObject:nb];
    if (!_bufAt) _bufAt = [NSMutableDictionary new];
    _bufAt[@(i)] = @[nb, @(off)];
    nvtrace_floats("KB", (unsigned long)i, (unsigned long)off, nb->_b.map, 16);
    nvmtl_lw_note(_cb, nb, off);
    if (nvmtl_vk_bind_buffer(&_cb->_c, NVMTL_SET_VERTEX, (uint32_t)i, &nb->_b, off)) nvlog("compute setBuffer: bind FAILED");
    if (nvmtl_zprobe_on()) {
        static const char *ZH = "0123456789abcdef";
        char hx[96]; size_t hn = 0;
        size_t cap = nb->_b.size < 32 ? nb->_b.size : 32;
        if (nb->_b.map) for (size_t k = 0; k < cap; k++) {
            uint8_t byte = ((const uint8_t *)nb->_b.map)[k];
            hx[hn++] = ZH[byte >> 4]; hx[hn++] = ZH[byte & 15];
        }
        hx[hn] = 0;
        nvlog("ZENC setBuffer  idx %-3lu len %-8lu off %lu  %s%s", (unsigned long)i,
              (unsigned long)[(id<MTLBuffer>)b length], (unsigned long)off,
              nb->_b.map ? "bytes " : "NO HOST MAP (private - bytes unreadable from here)", hx);
    }
}
- (void)setAccelerationStructure:(id<MTLAccelerationStructure>)as atBufferIndex:(NSUInteger)i {
    [self setBuffer:(id<MTLBuffer>)as offset:0 atIndex:i];
    NVMTLAccelerationStructure *a = (NVMTLAccelerationStructure *)as;
    if (a && [(id)a isKindOfClass:[NVMTLAccelerationStructure class]] && a->_uid.buf && _cb)
        nvmtl_vk_bind_buffer(&_cb->_c, NVMTL_SET_VERTEX, 31, &a->_uid, 0);
}
- (void)setBytes:(const void *)bytes length:(NSUInteger)len atIndex:(NSUInteger)i {
    if (i == 23 && len <= sizeof _nvcKP && bytes) { memcpy(_nvcKP, bytes, len); _nvcKPLen = (uint32_t)len; }
    else if (i == 29 && len == sizeof _nvcCP && bytes) { memcpy(_nvcCP, bytes, len); _nvcCPLen = (uint32_t)len; }
    size_t roff = 0;
    const BOOL dupable = _cb && bytes && len && len <= NVMTL_G79_DUPMAX && i < NVMTL_G79_DUPIDX && nvmtl_g79_on(NVMTL_G79_DUP);
    if (dupable && _cb->_g79BRing[i] && _cb->_g79BLen[i] == len && !memcmp(_cb->_g79B[i], bytes, len)) {
        if (nvmtl_vk_bind_buffer(&_cb->_c, NVMTL_SET_VERTEX, (uint32_t)i, &_cb->_g79BRing[i]->_b, _cb->_g79BOff[i])) nvlog("compute setBytes: bind FAILED");
        // The binding table follows the binding: kernels run from compiled machine code read their buffer
        // addresses from it, and a stale entry hands the GPU an address that belongs to nothing.
        if (!_bufAt) _bufAt = [NSMutableDictionary new];
        _bufAt[@(i)] = @[_cb->_g79BRing[i], @(_cb->_g79BOff[i]), @(len), @(_cb->_g79BOff[i])];
        nvmtl_g79_count(G79C_BYTESDUP);
        return;
    }
    NVMTLBuffer *nb = nvmtl_bytes_ring(_cb, len, &roff);
    BOOL ring = nb != nil;
    if (!ring) {
        nb = [NVMTLBuffer new];
        if (nvmtl_vk_buffer_create(len < 16 ? 16 : len, 1, &nb->_b)) { nvlog("compute setBytes: create FAILED"); return; }
        nvmtl_enc78_count(E78C_BYTESOLD, 1);
    } else { nvmtl_enc78_count(E78C_RING, 1); nvmtl_enc78_count(E78C_RINGBYTES, len); }
    if (nb->_b.map) nvmtl_devcpy((uint8_t *)nb->_b.map + roff, bytes, len);
    if (dupable) {
        _cb->_g79BRing[i] = ring && nb->_b.map ? nb : nil; _cb->_g79BOff[i] = roff; _cb->_g79BLen[i] = (uint32_t)len;
        memcpy(_cb->_g79B[i], bytes, len);
    }
    if (!_bufAt) _bufAt = [NSMutableDictionary new];
    _bufAt[@(i)] = @[nb, @(roff), @(len), @(roff)];   // buffer, offset, inline length, base
    if (nvmtl_vk_bind_buffer(&_cb->_c, NVMTL_SET_VERTEX, (uint32_t)i, &nb->_b, roff)) nvlog("compute setBytes: bind FAILED");
    if (nvmtl_zprobe_on()) {
        const uint32_t *zw = (const uint32_t *)bytes; char zb[220]; int zo = 0;
        for (NSUInteger k = 0; (k + 1) * 4 <= len && k < 13 && zo < 190; k++)
            zo += snprintf(zb + zo, sizeof zb - (size_t)zo, "%08x ", zw[k]);
        zb[zo] = 0;
        nvlog("ZENC setBytes   idx %-3lu len %-4lu map %s words: %s", (unsigned long)i,
              (unsigned long)len, nb->_b.map ? "yes" : "NO", zb);
    }
    if (ring) return;
    if (!_cb->_scratch) _cb->_scratch = [NSMutableArray new];
    [_cb->_scratch addObject:nb];
}

#define NVMTL_ZPROBE_MAX 64
#define NVMTL_ZDISP_MAX 400
static NSMutableArray *g_zprobe;
static int nvmtl_zprobe_on(void) {
    static int on = -1;
    if (on < 0) on = NVMTL_RELEASE ? 0 : ([[NSProcessInfo processInfo] environment][@"NVMTL_ZPROBE"] ? 1 : 0);
    return on;
}
static void nvmtl_zprobe_dispatch(const char *kernel, const uint32_t *t, const uint32_t *l) {
    if (!nvmtl_zprobe_on()) return;
    static unsigned seq = 0;
    if (seq >= NVMTL_ZDISP_MAX) return;
    seq++;
    nvlog("ZDISP #%u %s threads %ux%ux%u local %ux%ux%u", seq, kernel ? kernel : "(no pipeline set)",
          t[0], t[1], t[2], l[0], l[1], l[2]);
}
static void nvmtl_zprobe_record(NVMTLTexture *t, const char *kernel, unsigned idx, unsigned stex) {
    if (!nvmtl_zprobe_on() || !t) return;
    @synchronized ([NVMTLTexture class]) {
        if (!g_zprobe) g_zprobe = [NSMutableArray new];
        if (g_zprobe.count >= NVMTL_ZPROBE_MAX) return;
        [g_zprobe addObject:@[t, @(kernel ?: "(no pipeline set)"), @(idx), @(stex)]];
    }
}
static void nvmtl_zprobe_drain(void) {
    if (!nvmtl_zprobe_on()) return;
    NSArray *snap = nil;
    @synchronized ([NVMTLTexture class]) { snap = g_zprobe; g_zprobe = nil; }
    for (NSArray *e in snap) {
        NVMTLTexture *t = e[0];
        const char *kn = [e[1] UTF8String];
        unsigned idx = [e[2] unsignedIntValue], stex = [e[3] unsignedIntValue];
        nvk_image *im = [t nvi];
        if (!im || !im->w || !im->h || !im->bpp) { nvlog("ZPROBE %s tex(%u) stex=%u: %p has no image - SKIPPED (a fact about the probe, not about the pixels)", kn, idx, stex, (__bridge void *)t); continue; }
        uint32_t rw = im->w > 256 ? 256 : im->w, rh = im->h > 256 ? 256 : im->h;
        size_t row = (size_t)rw * im->bpp;
        NSMutableData *md = [NSMutableData dataWithLength:row * rh];
        if (!md) continue;
        [t getBytes:md.mutableBytes bytesPerRow:row fromRegion:MTLRegionMake2D(0, 0, rw, rh) mipmapLevel:0];
        unsigned nz = 0, nn = 0;
        nvmtl_nonzero(md.mutableBytes, row, row, rh, &nz, &nn);
        nvlog("ZPROBE %s tex(%u) stex=%u: %p %ux%u x%u slice(s) bpp %u storage %u -> NONZERO %u/%u bytes in %ux%u of slice 0",
              kn, idx, stex, (__bridge void *)t, im->w, im->h, im->layers, im->bpp, im->storage, nz, nn, rw, rh);
    }
}
- (void)setTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i {
    NVMTLTexture *nt = nvmtl_as_texture(t, "compute setTexture"); if (t && !nt) return;
    if (nvmtl_sass_tables_wanted()) {
        if (!_sassTextures) _sassTextures = [NSMutableDictionary new];
        if (nt) _sassTextures[@(i)] = nt; else [_sassTextures removeObjectForKey:@(i)];
    }
    if (!nt) { nvlog("compute setTexture: nil at %lu", (unsigned long)i); return; }
    { unsigned fw; if (nvmtl_flick_window(&fw)) { if (!_flkTex) _flkTex = [NSMutableArray new]; [_flkTex addObject:nt]; } }
    if (nt->_parent && nt->_baseLevel) nt->_parent->_mipsWritten = YES;
    nvmtl_zprobe_record(nt, _ps && _ps->_function ? _ps->_function->_fname.UTF8String : NULL, (unsigned)i, nt->_stex ? 1u : 0u);
    nvmtl_retain_resource(_cb, nt);
    nvtrace("KTEX[%lu] %p(img %p parent %p) %ux%u mips %u fmt %lu storage %d", (unsigned long)i, (__bridge void *)nt, [nt nvi]->img, (__bridge void *)nt->_parent,
            [nt nvi]->w, [nt nvi]->h, [nt nvi]->mips, (unsigned long)nt->_fmt, nt->_stex);
    nvmtl_surface_in_for_cb(_cb, nt); if (nt->_stex) nvmtl_surf_dirty(_cb, nt);
    if (nt->_tbView) nvmtl_vk_bind_texel_view(&_cb->_c, NVMTL_SET_VERTEX, (uint32_t)i, nt->_tbView, nt->_tbStorage);
    else {
    if (nvmtl_vk_cmd_prepare_sampled_image(&_cb->_c, [nt nvi], nt->_stex)) { nvlog("compute setTexture: image layout preparation refused"); return; }
    if (nvmtl_vk_bind_texture_view(&_cb->_c, NVMTL_SET_VERTEX, (uint32_t)i, [nt nvsampleview])) nvlog("compute setTexture: bind FAILED");
    nvmtl_vk_bind_storage_view(&_cb->_c, NVMTL_SET_VERTEX, (uint32_t)i, nvmtl_storage_view_for(_cb, nt, nt->_stex || nvmtl_function_writes_texture(_ps ? _ps->_function : nil, i)));
    }
}
static int nvmtl_dsp_mode(void) { static int v = -1; if (v < 0) { const char *e = getenv("NVMTL_PT_DISPATCH"); v = e && e[0] == '1'; } return v; }
static int nvmtl_dsp_begin(NVMTLComputeCommandEncoder *e)
{
    if (!nvmtl_dsp_mode() || !e->_cb) return 0;
    extern void nvmtl_vk_pt_seg_begin(nvk_cmdbuf *c, uint32_t kind);
    nvk_cmdbuf *c = &e->_cb->_c; const unsigned n = c->pt_n;
    nvmtl_vk_pt_seg_begin(c, 9003u);
    return c->pt_open && c->pt_n == n && c->pt_f[n] == 9003u;
}
static void nvmtl_dsp_end(NVMTLComputeCommandEncoder *e, NVMTLComputePipelineState *ps, const uint32_t t[3], const uint32_t l[3])
{
    extern void nvmtl_vk_pt_seg_end(nvk_cmdbuf *c, uint32_t kind, uint32_t count);
    nvk_cmdbuf *c = &e->_cb->_c; const unsigned n = c->pt_n;
    uint32_t sh = 0, shHeap = 0, bound = 0; unsigned long long shBytes = 0;
    for (NSArray *v in e->_bufAt.allValues) {
        NVMTLBuffer *b = v.count ? v[0] : nil; if (![b isKindOfClass:[NVMTLBuffer class]]) continue;
        bound++;
        if (b->_storage == MTLStorageModeShared && b->_b.map) { sh++; if (b->_heap || b->_subHeap || b->_b.size >= (64u << 20)) shHeap++; shBytes += b->_b.size; }
    }
    nvmtl_vk_pt_seg_end(c, 9003u, l[0] * l[1] * l[2]);
    if (c->pt_n != n + 1) return;
    NVMTLFunction *f = ps ? ps->_function : nil;
    uint32_t h = ps ? ps->_spvHash : 0;
    if (!h && f) h = (uint32_t)(uintptr_t)(__bridge void *)ps;
    c->pt_h[n] = h;
    c->pt_fs[n][0] = t[0] * t[1] * t[2]; c->pt_fs[n][1] = sh; c->pt_fs[n][2] = shHeap; c->pt_fs[n][3] = bound;
    static NSMutableSet *named; static os_unfair_lock lk = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lk); if (!named) named = [NSMutableSet new];
    const BOOL fresh = ![named containsObject:@(h)]; if (fresh) [named addObject:@(h)];
    os_unfair_lock_unlock(&lk);
    if (fresh) { extern int nvmtl_vk_pipeline_stats(void *pipe, char *out, size_t n); char st[400] = "";
        if (ps) nvmtl_vk_pipeline_stats(ps->_p.pipe, st, sizeof st);
        nvlog_diag("dispatch kernel %08x = %s (tg %ux%ux%u) | %s", h, f ? (f->_fname.UTF8String ?: "?") : "?", l[0], l[1], l[2], st); }
}
- (void)nvmtlE78Barrier:(BOOL)indirect {
    { extern void nvmtl_vk_pt_seg_begin(nvk_cmdbuf *c, uint32_t kind); if (!_e78NDisp && !nvmtl_dsp_mode()) nvmtl_vk_pt_seg_begin(&_cb->_c, 9001u); }
    int kind;
    if (indirect) kind = 0;
    else if (!_e78NDisp) {
        kind = _cb->_g79C2C && nvmtl_g79_on(NVMTL_G79_ENC) ? 1 : 0;
        nvmtl_g79_count(kind ? G79C_ENCNARROW : G79C_ENCFULL);
    }
    else if (_e78Concurrent && nvmtl_enc78_on(NVMTL_E78_H7)) {
        kind = _g79Bar ? 1 : 2;
        if (_g79Bar) nvmtl_g79_count(G79C_BARFOLD);
    }
    else if (nvmtl_enc78_on(NVMTL_E78_P1)) kind = 1;
    else kind = 0;
    _g79Bar = NO;
    _e78NDisp++;
    if (kind == 0) nvmtl_vk_cmd_barrier(&_cb->_c);
    else if (kind == 1) nvmtl_vk_cmd_barrier_c2c(&_cb->_c);
    if (kind) _e78Loose = YES;
    nvmtl_enc78_count(E78C_DISP, 1); nvmtl_enc78_count(E78C_FULL + kind, 1);
    if (_e78Concurrent) nvmtl_enc78_count(E78C_CONC, 1);
}
// The last compute dispatches and commits encoded in this process, written to ~/Library/Logs/nvmtl/lastk-<pid>.txt
// when the device is lost (nvmtl_vk.c), with the AIR of the distinct kernels among them beside it: an MMU fault names
// only "compute shader" and a VA, and the kernels of the last few submitted command buffers are the suspects.
// Cyberpunk 2077's benchmark killed the channel (FAULT_PDE) seconds after its scene loaded, twice at different VAs.
enum { NVMTL_LASTK_N = 192 };
static struct { char kind; char name[40]; uint32_t hash; const void *ps; uint32_t t[3], l[3]; uint64_t cb; uint64_t submits; uint32_t h[48], nh; } nvmtl_lastk[NVMTL_LASTK_N];
static _Atomic unsigned nvmtl_lastk_next;
static NSMutableDictionary *nvmtl_lastk_air;   // hash -> AIR text of the kernels seen lately (bounded)
static uint32_t nvmtl_spv_hash(NSData *d) { uint32_t h = 2166136261u; const uint8_t *b = d.bytes; for (NSUInteger i = 0; i < d.length; i++) { h ^= b[i]; h *= 16777619u; } return h; }
static void nvmtl_lastk_put(char kind, NVMTLComputePipelineState *ps, const uint32_t t[3], const uint32_t l[3], NVMTLCommandBuffer *cb)
{
    unsigned i = atomic_fetch_add(&nvmtl_lastk_next, 1u) % NVMTL_LASTK_N;
    NVMTLFunction *f = ps ? ps->_function : nil;
    if (ps && !ps->_spvHash && f && f->_spirv.length) {
        ps->_spvHash = nvmtl_spv_hash(f->_spirv);
        if (f->_air.length) @synchronized ([NVMTLComputePipelineState class]) {
            if (!nvmtl_lastk_air) nvmtl_lastk_air = [NSMutableDictionary new];
            if (nvmtl_lastk_air.count > 256) [nvmtl_lastk_air removeAllObjects];
            nvmtl_lastk_air[@(ps->_spvHash)] = f->_air;
        }
    }
    nvmtl_lastk[i].kind = kind;
    strlcpy(nvmtl_lastk[i].name, f ? f->_fname.UTF8String : "-", sizeof nvmtl_lastk[i].name);
    nvmtl_lastk[i].hash = ps ? ps->_spvHash : 0; nvmtl_lastk[i].ps = (__bridge void *)ps;
    if (t) memcpy(nvmtl_lastk[i].t, t, sizeof nvmtl_lastk[i].t); else memset(nvmtl_lastk[i].t, 0, sizeof nvmtl_lastk[i].t);
    if (l) memcpy(nvmtl_lastk[i].l, l, sizeof nvmtl_lastk[i].l); else memset(nvmtl_lastk[i].l, 0, sizeof nvmtl_lastk[i].l);
    nvmtl_lastk[i].cb = cb ? (uint64_t)(uintptr_t)&cb->_c : 0;
    nvmtl_lastk[i].submits = nvmtl_vk_queue_submits(); nvmtl_lastk[i].nh = 0;
    // the kernels ride in the command buffer's nvk_cmdbuf, which becomes a submission part (NVMTLEventSync.m) the submit records
    if (kind == 'D' && cb && ps && cb->_c.lastk_n < 48) cb->_c.lastk_h[cb->_c.lastk_n++] = ps->_spvHash;
}
static void nvmtl_lastk_note(NVMTLComputePipelineState *ps, const uint32_t t[3], const uint32_t l[3], NVMTLCommandBuffer *cb) {
    nvmtl_lastk_put('D', ps, t, l, cb);
    // the census also records every dispatch's grid and threadgroup (t is threads, or groups for dispatchThreadgroups)
    unsigned fr; if (nvmtl_census_on(&fr)) { char line[240];
        snprintf(line, sizeof line, "D f%u %s grid %ux%ux%u tg %ux%ux%u\n", fr, ps && ps->_function ? (ps->_function->_fname.UTF8String ?: "-") : "-", t[0], t[1], t[2], l[0], l[1], l[2]);
        nvmtl_census_line(line); }
}
// NVMTL_SPLIT_ENCODERS=1: a submission part per compute encoder; =2: one per dispatch (the pipeline and bindings are
// re-recorded at every dispatch, so a fresh Vulkan command buffer mid-encoder carries on). Diagnostics only.
static int nvmtl_split_encoders(void) { static int v = -1; if (v < 0) { const char *e = getenv("NVMTL_SPLIT_ENCODERS"); v = e && *e ? atoi(e) : 0; } return v; }
static void nvmtl_split_after_dispatch(NVMTLCommandBuffer *cb) { if (nvmtl_split_encoders() >= 2 && cb && !cb->_committed) [cb nvmtlSealPartWithSignal:nil value:0 restart:YES]; }
// nvmtl_vk.c, right after vkQueueSubmit: the NVK sequence this submission signals ("channel FAULTED at sem N of M")
void nvmtl_lastk_submit(const void *c, uint64_t seq)
{
    unsigned i = atomic_fetch_add(&nvmtl_lastk_next, 1u) % NVMTL_LASTK_N;
    nvmtl_lastk[i].kind = 'S'; strlcpy(nvmtl_lastk[i].name, "submit", sizeof nvmtl_lastk[i].name);
    nvmtl_lastk[i].hash = 0; nvmtl_lastk[i].ps = ((const nvk_cmdbuf *)c)->cb; memset(nvmtl_lastk[i].t, 0, sizeof nvmtl_lastk[i].t); memset(nvmtl_lastk[i].l, 0, sizeof nvmtl_lastk[i].l);   // ps = the VkCommandBuffer (NVK's dispatch crumbs name it)
    nvmtl_lastk[i].cb = (uint64_t)(uintptr_t)c; nvmtl_lastk[i].submits = seq;
    const nvk_cmdbuf *k = c; nvmtl_lastk[i].nh = k->lastk_n < 48 ? k->lastk_n : 48; memcpy(nvmtl_lastk[i].h, k->lastk_h, nvmtl_lastk[i].nh * sizeof (uint32_t));
}
void nvmtl_lastk_dump(void)
{
    unsigned n = atomic_load(&nvmtl_lastk_next), k = n < NVMTL_LASTK_N ? n : NVMTL_LASTK_N;
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/nvmtl"];
    NSString *path = [dir stringByAppendingFormat:@"/lastk-%d.txt", getpid()];
    FILE *fp = fopen(path.UTF8String, "w");
    if (!fp) { nvlog("last dispatches: cannot write %s", path.UTF8String); return; }
    fprintf(fp, "# last %u record(s) before the device was lost, oldest first: D dispatch (cb = nvk_cmdbuf, submits = vkQueueSubmit calls so far), C commit, S vkQueueSubmit of cb (submits = the NVK sequence it signals: 'channel FAULTED at sem N of M' names cb with S M)\n", k);
    NSMutableSet *hashes = [NSMutableSet new];
    for (unsigned j = 0; j < k; j++) {
        unsigned i = (n - k + j) % NVMTL_LASTK_N;
        fprintf(fp, "#%u %c %s hash %08x ps %p cb %llx submits %llu threads %ux%ux%u tg %ux%ux%u\n", n - k + j, nvmtl_lastk[i].kind, nvmtl_lastk[i].name,
                nvmtl_lastk[i].hash, nvmtl_lastk[i].ps, (unsigned long long)nvmtl_lastk[i].cb, (unsigned long long)nvmtl_lastk[i].submits,
                nvmtl_lastk[i].t[0], nvmtl_lastk[i].t[1], nvmtl_lastk[i].t[2], nvmtl_lastk[i].l[0], nvmtl_lastk[i].l[1], nvmtl_lastk[i].l[2]);
        if (nvmtl_lastk[i].hash) [hashes addObject:@(nvmtl_lastk[i].hash)];
        if (nvmtl_lastk[i].kind == 'S' && nvmtl_lastk[i].nh) {
            fprintf(fp, "    kernels:");
            for (unsigned q = 0; q < nvmtl_lastk[i].nh; q++) { fprintf(fp, " %08x", nvmtl_lastk[i].h[q]); [hashes addObject:@(nvmtl_lastk[i].h[q])]; }
            fprintf(fp, "\n");
        }
    }
    nvmtl_lastk_watch_dump(fp);
    { extern void nvmtl_resid_dump_near(FILE *fp, uint64_t va); nvmtl_resid_dump_near(fp, nvmtl_vk_last_fault_addr()); }
    fclose(fp);
    unsigned written = 0;
    @synchronized ([NVMTLComputePipelineState class]) {
        for (NSNumber *h in hashes) { NSString *air = nvmtl_lastk_air[h]; if (!air) continue;
            [air writeToFile:[dir stringByAppendingFormat:@"/lastk-%d-%08x.ll", getpid(), h.unsignedIntValue] atomically:YES encoding:NSUTF8StringEncoding error:NULL]; written++; }
    }
    nvlog("last dispatches: %u record(s) in %s, AIR of %u distinct kernel(s) beside it", k, path.UTF8String, written);
    nvmtl_vk_explain_fault_host();
}
- (void)dispatchThreadgroups:(MTLSize)grid threadsPerThreadgroup:(MTLSize)tg {
    if (_ps && _ps->_sassKernel && !nvmtl_shm_on()) {   // shmirror: machine code is not instrumented
        int ran = nvmtl_sass_dispatch(self, grid, tg, 0, !_ps->_sassOnly);
        if (ran) { if (ran > 0 && _cb->_stTwins.count) nvmtl_storage_twins_out(_cb); return; }
    }
    if (!_nvcIn && nvmtl_nvconv_try(self, grid, tg)) return;
    NVMTLComputePipelineState *selected = [self nvmtlSamplerPipeline];
    if (!selected) { nvlog("dispatch with no valid compute sampler pipeline"); return; }
    uint32_t l[3] = { (uint32_t)tg.width, (uint32_t)tg.height, (uint32_t)tg.depth };
    uint32_t t[3] = { (uint32_t)(grid.width * tg.width), (uint32_t)(grid.height * tg.height), (uint32_t)(grid.depth * tg.depth) };
    nvmtl_lastk_note(_ps, t, l, _cb); nvmtl_lastk_watch(self, _ps, t);
    if (nvmtl_vk_tg_reject(l, t, _ps && _ps->_function ? _ps->_function->_fname.UTF8String : NULL, selected->_p.lin)) return;
    nvmtl_zprobe_dispatch(_ps && _ps->_function ? _ps->_function->_fname.UTF8String : NULL, t, l);
    if (nvmtl_trace_on()) { char bufs_[600]; nvmtl_vk_trace_buffers(&_cb->_c, bufs_, sizeof bufs_);
        nvtrace("DISPATCH %s | threads %ux%ux%u tg %ux%ux%u", (_ps && _ps->_function ? _ps->_function->_fname.UTF8String : NULL) ?: "-", t[0], t[1], t[2], l[0], l[1], l[2]);
        nvtrace("  BUFS%s", bufs_); }
    [self nvmtlE78Barrier:NO];
    const int dsp = nvmtl_dsp_begin(self);
    nvmtl_probe_name_kernel(_ps); if (nvmtl_shm_on() || nvmtl_vendor_dispatch_sass(selected, &_cb->_c, t, l) != 0) nvmtl_vk_cmd_dispatch_threads(&_cb->_c, &selected->_p, t, l);
    if (dsp) nvmtl_dsp_end(self, _ps, t, l);
    nvmtl_lastk_watch_crumb();
    if (_cb->_stTwins.count) nvmtl_storage_twins_out(_cb);
    nvmtl_split_after_dispatch(_cb);
}
- (void)dispatchThreads:(MTLSize)threads threadsPerThreadgroup:(MTLSize)tg {
    if (_ps && _ps->_sassKernel && !nvmtl_shm_on()) {   // shmirror: machine code is not instrumented
        int ran = nvmtl_sass_dispatch(self, threads, tg, 1, !_ps->_sassOnly);
        if (ran) { if (ran > 0 && _cb->_stTwins.count) nvmtl_storage_twins_out(_cb); return; }
    }
    NVMTLComputePipelineState *selected = [self nvmtlSamplerPipeline];
    if (!selected) { nvlog("dispatch with no valid compute sampler pipeline"); return; }
    uint32_t l[3] = { (uint32_t)tg.width, (uint32_t)tg.height, (uint32_t)tg.depth };
    uint32_t t[3] = { (uint32_t)threads.width, (uint32_t)threads.height, (uint32_t)threads.depth };
    nvmtl_lastk_note(_ps, t, l, _cb); nvmtl_lastk_watch(self, _ps, t);
    if (nvmtl_vk_tg_reject(l, t, _ps && _ps->_function ? _ps->_function->_fname.UTF8String : NULL, selected->_p.lin)) return;
    nvmtl_zprobe_dispatch(_ps && _ps->_function ? _ps->_function->_fname.UTF8String : NULL, t, l);
    if (nvmtl_trace_on()) { char bufs_[600]; nvmtl_vk_trace_buffers(&_cb->_c, bufs_, sizeof bufs_);
        nvtrace("DISPATCH %s | threads %ux%ux%u tg %ux%ux%u", (_ps && _ps->_function ? _ps->_function->_fname.UTF8String : NULL) ?: "-", t[0], t[1], t[2], l[0], l[1], l[2]);
        nvtrace("  BUFS%s", bufs_); }
    [self nvmtlE78Barrier:NO];
    const int dsp = nvmtl_dsp_begin(self);
    nvmtl_probe_name_kernel(_ps); if (nvmtl_shm_on() || nvmtl_vendor_dispatch_sass(selected, &_cb->_c, t, l) != 0) nvmtl_vk_cmd_dispatch_threads(&_cb->_c, &selected->_p, t, l);
    if (dsp) nvmtl_dsp_end(self, _ps, t, l);
    nvmtl_lastk_watch_crumb();
    if (_cb->_stTwins.count) nvmtl_storage_twins_out(_cb);
    nvmtl_split_after_dispatch(_cb);
}
- (void)setBufferOffset:(NSUInteger)off atIndex:(NSUInteger)i {
    { NSArray *b = _bufAt[@(i)]; if (b) { _bufAt[@(i)] = @[b[0], @(off)]; nvmtl_lw_note(_cb, b[0], off); } }
    if (nvmtl_vk_bind_buffer_offset(&_cb->_c, NVMTL_SET_VERTEX, (uint32_t)i, off))
        nvlog("compute setBufferOffset: nothing bound at index %lu", (unsigned long)i);
}
// MPS (Lanczos scale, used by video players) sets an imageblock size on compute encoders.
// The translator keeps a kernel's imageblock cells in per-thread private memory and derives
// the block extent from the threadgroup size, so no encoder state is needed; without this
// method the call is an unrecognized selector and the app aborts.
- (void)setImageblockWidth:(NSUInteger)w height:(NSUInteger)h {
    static int logged;
    if (!logged++) nvlog("compute setImageblockWidth:%lu height:%lu (imageblock lives in thread-private memory)",
                         (unsigned long)w, (unsigned long)h);
}
- (void)setThreadgroupMemoryLength:(NSUInteger)len atIndex:(NSUInteger)i {
    if (!_tgLen) _tgLen = [NSMutableDictionary new];
    if (nvmtl_zprobe_on()) nvlog("ZENC tgMemory   idx %-3lu length %lu", (unsigned long)i, (unsigned long)len);
    NSUInteger was = [_tgLen[@(i).stringValue] unsignedIntegerValue];
    if (len) _tgLen[@(i).stringValue] = @(len);
    else     [_tgLen removeObjectForKey:@(i).stringValue];
    if (was != len) { _e78Key = nil; _e78VarSel = nil; }
}
- (void)executeCommandsInBuffer:(id<MTLIndirectCommandBuffer>)icb withRange:(NSRange)r {
    NVMTLIndirectCommandBuffer *b = (NVMTLIndirectCommandBuffer *)icb;
    if (!b) { nvlog("compute executeCommandsInBuffer: nil"); return; }
    NSUInteger n = 0;
    for (NSUInteger i = r.location; i < r.location + r.length && i < b->_cmds.count; i++) {
        NVMTLIndirectCommand *c = b->_cmds[i];
        if (!c->_armed || !c->_isCompute) continue;
        if (c->_cps) [self setComputePipelineState:c->_cps];
        for (NSArray *e in c->_kbufs) [self setBuffer:e[0] offset:[e[1] unsignedLongValue] atIndex:[e[2] unsignedLongValue]];
        [self dispatchThreadgroups:c->_grid threadsPerThreadgroup:c->_tg];
        n++;
    }
    nvlog("compute executeCommandsInBuffer: replayed %lu of %lu slot(s)", (unsigned long)n, (unsigned long)r.length);
}
- (void)setSamplerState:(id<MTLSamplerState>)ss atIndex:(NSUInteger)i {
    NVMTLSamplerState *ns = (NVMTLSamplerState *)ss;
    if (nvmtl_sass_tables_wanted()) {
        if (!_sassSamplers) _sassSamplers = [NSMutableDictionary new];
        if (ns) _sassSamplers[@(i)] = ns; else [_sassSamplers removeObjectForKey:@(i)];
    }
    if (!_samplers) _samplers = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%lu", (unsigned long)i];
    id was = _samplers[key], now = ns ? ns->_pixelState : nil;
    if (ns && ns->_pixelState) _samplers[key] = ns->_pixelState;
    else [_samplers removeObjectForKey:key];
    if (was != now && ![was isEqual:now]) { _e78Key = nil; _e78VarSel = nil; }
    nvmtl_retain_resource(_cb, ns);
    if (nvmtl_vk_bind_sampler(&_cb->_c, NVMTL_SET_VERTEX, (uint32_t)i, ns ? &ns->_s : NULL)) nvlog("compute setSamplerState: bind FAILED");
}
- (void)setSamplerState:(id<MTLSamplerState>)ss lodMinClamp:(float)lo lodMaxClamp:(float)hi atIndex:(NSUInteger)i {
    [self setSamplerState:ss atIndex:i];
}
- (void)setBuffers:(const id<MTLBuffer> __unsafe_unretained [])b offsets:(const NSUInteger *)offs withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) if (b[k]) [self setBuffer:b[k] offset:offs ? offs[k] : 0 atIndex:r.location + k];
}
- (void)setTextures:(const id<MTLTexture> __unsafe_unretained [])t withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) if (t[k]) [self setTexture:t[k] atIndex:r.location + k];
}
- (void)setSamplerStates:(const id<MTLSamplerState> __unsafe_unretained [])ss withRange:(NSRange)r {
    for (NSUInteger k = 0; k < r.length; k++) [self setSamplerState:ss[k] atIndex:r.location + k];
}
- (void)dispatchThreadgroupsWithIndirectBuffer:(id<MTLBuffer>)buf indirectBufferOffset:(NSUInteger)off
                         threadsPerThreadgroup:(MTLSize)tg {
    NVMTLBuffer *nb = nvmtl_as_buffer(buf, "dispatchThreadgroupsWithIndirectBuffer");
    if (!nb) { nvlog("dispatchThreadgroupsWithIndirectBuffer: nil"); return; }
    nvmtl_retain_resource(_cb, nb);
    // a pipeline with only compiled machine code has no Vulkan pipeline to run an indirect dispatch on
    if (_ps && _ps->_sassOnly) {
        [_cb nvmtlRecordEncodingError:[NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorInternal
            userInfo:@{ NSLocalizedDescriptionKey: @"Indirect dispatch is not available for this kernel" }]];
        return;
    }
    NVMTLComputePipelineState *selected = [self nvmtlSamplerPipeline];
    if (!selected) { nvlog("indirect dispatch with no valid compute sampler pipeline"); return; }
    uint32_t l[3] = { (uint32_t)tg.width, (uint32_t)tg.height, (uint32_t)tg.depth };
    if (nvmtl_vk_tg_reject(l, NULL, _ps && _ps->_function ? _ps->_function->_fname.UTF8String : NULL, selected->_p.lin)) return;
    [self nvmtlE78Barrier:YES];
    nvmtl_probe_name_kernel(_ps);
    nvmtl_vk_cmd_dispatch_indirect_tg(&_cb->_c, &selected->_p, &nb->_b, off, l);
    if (_cb->_stTwins.count) nvmtl_storage_twins_out(_cb);
}
- (void)nvmtlFlickNote:(id<MTLResource>)r usage:(MTLResourceUsage)u {
    unsigned fw; if (!(u & MTLResourceUsageWrite) || ![(id)r isKindOfClass:[NVMTLTexture class]] || !nvmtl_flick_window(&fw)) return;
    if (!_flkTex) _flkTex = [NSMutableArray new]; [_flkTex addObject:r];
}
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u { nvmtl_retain_resource(_cb, r); [self nvmtlFlickNote:r usage:u]; }
- (void)useResources:(const id<MTLResource> __unsafe_unretained [])r count:(NSUInteger)n usage:(MTLResourceUsage)u { for (NSUInteger i=0;i<n;i++) { nvmtl_retain_resource(_cb,r[i]); [self nvmtlFlickNote:r[i] usage:u]; } }
- (void)useHeap:(id<MTLHeap>)h { atomic_fetch_add(&g_h_useheap, 1); }
- (void)sampleCountersInBuffer:(id)sb atSampleIndex:(NSUInteger)i withBarrier:(BOOL)b { nvmtl_sample_counter(_cb, sb, i, self, b); }
- (void)memoryBarrierWithScope:(MTLBarrierScope)scope {
    if (nvmtl_g79_on(NVMTL_G79_BAR)) { _g79Bar = YES; nvmtl_g79_count(G79C_BARLAZY); } else nvmtl_vk_cmd_barrier(&_cb->_c); }
- (void)updateFence:(id<MTLFence>)f {}
- (void)waitForFence:(id<MTLFence>)f { nvmtl_vk_cmd_barrier(&_cb->_c); }
- (void)memoryBarrierWithResources:(const id<MTLResource> __unsafe_unretained [])r count:(NSUInteger)n {
    if (nvmtl_g79_on(NVMTL_G79_BAR)) { _g79Bar = YES; nvmtl_g79_count(G79C_BARLAZY); } else nvmtl_vk_cmd_barrier(&_cb->_c); }
- (void)pushDebugGroup:(NSString *)g { nvtrace("GROUP %s", g.UTF8String ?: "?"); }
- (void)popDebugGroup {}
- (void)insertDebugSignpost:(NSString *)sp {}
- (void)endEncoding {
    nvmtl_enc_end();
    { extern void nvmtl_vk_pt_seg_end(nvk_cmdbuf *c, uint32_t kind, uint32_t count); if (_cb && _e78NDisp) nvmtl_vk_pt_seg_end(&_cb->_c, 9001u, (uint32_t)_e78NDisp); }
    if (nvmtl_g79_on(NVMTL_G79_ENC)) {
        if (_e78NDisp) { _cb->_g79C2C = YES; if (_e78Loose || _g79Bar) _cb->_g79Owed = YES; }
        _e78Loose = NO; _g79Bar = NO;
    } else if (_e78Loose || _g79Bar || (_e78NDisp && nvmtl_c2r_barrier_on())) { nvmtl_vk_cmd_barrier(&_cb->_c); _e78Loose = NO; _g79Bar = NO; nvmtl_enc78_count(E78C_ENDFULL, 1); }
    nvmtl_g79_census();
    if (_flkTex.count) {
        NSString *k = _ps && _ps->_function ? _ps->_function->_fname : @"?";
        nvmtl_flick_compute(_cb, _flkTex, [NSString stringWithFormat:@"CS %@/%@", _label ?: @"", k], (unsigned)_e78NDisp);
        _flkTex = nil;
    }
    [_cb->_stTwins removeAllObjects];   // the next encoder copies each twin in again
    _cb->_nEnd++; nvmtl_enc78_census();
    // The command buffer holds every resource until the GPU is done; the encoder's own binding tables are dead after
    // this point, as in Apple's encoders. WAS: kept until dealloc, which MPS defers to the completion handler; by then
    // Espresso had recycled the objects they named and .cxx_destruct released freed memory (mediaanalysisd, issue #107).
    _bufAt = nil; _samplers = nil; _tgLen = nil; _e78Key = nil;
    // NVMTL_SPLIT_ENCODERS=1: every compute encoder ends a submission part of its own (what an event wait does), so a
    // GPU fault's "channel FAULTED at sem N" (nvkmd_nvrm) names one encoder's dispatches in the device-loss record
    // rather than a whole frame's. Diagnostics only: many small submits.
    if (nvmtl_split_encoders() && _cb && !_cb->_committed && _e78NDisp) [_cb nvmtlSealPartWithSignal:nil value:0 restart:YES];
}
- (void)setLabel:(NSString *)l { _label = [l copy]; }
- (NSString *)label { return _label; }
- (id<MTLDevice>)device { id<MTLDevice> d = _cb ? [_cb device] : nil; return d ? d : (id<MTLDevice>)gNVMTLMainDevice; }
- (id<MTLCommandBuffer>)commandBuffer { return (id<MTLCommandBuffer>)_cb; }   // SPI, see the render encoder
@end

static NSUInteger nvmtl_texture_slice_count(NVMTLTexture *t) {
    MTLTextureType type = t.textureType;
    return type == MTLTextureTypeCube ? 6 : type == MTLTextureTypeCubeArray ? t.arrayLength * 6 : t.arrayLength;
}
static void nvmtl_blit_tally(NVMTLCommandBuffer *cb, int kind, unsigned long long bytes, int sys)
{
    if (!cb) return;
    nvk_cmdbuf *c = &cb->_c;
    if (!c->pt_open || c->pt_n >= NVMTL_PT_MAX || c->pt_f[c->pt_n] != 9002u) return;
    const uint32_t kb = (uint32_t)((bytes + 1023) >> 10);
    c->pt_fs[c->pt_n][kind] += kb; if (sys) c->pt_fs[c->pt_n][3] += kb;
}
static int nvmtl_buf_sys(id<MTLBuffer> b) { NVMTLBuffer *x = (NVMTLBuffer *)b; return x && [x isKindOfClass:[NVMTLBuffer class]] && (x->_b.map || x->_hostPtr); }
@implementation NVMTLBlitCommandEncoder
- (unsigned long long)globalTraceObjectID { return nvmtl_global_trace_id(self); }
- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)so toBuffer:(id<MTLBuffer>)dst
     destinationOffset:(NSUInteger)dof size:(NSUInteger)size {
    NVMTLBuffer *s = (NVMTLBuffer *)src, *d = (NVMTLBuffer *)dst;
    if (!s || !d) { nvlog("blit copyFromBuffer: nil"); return; }
    nvmtl_blit_tally(_cb, 0, size, nvmtl_buf_sys(src));
    if (!_cb->_resources) _cb->_resources = [NVMTLResSet new];
    [_cb->_resources addObject:s];
    [_cb->_resources addObject:d];
    if (nvmtl_vk_cmd_copy_buffer_batched(&_cb->_c, &s->_b, so, &d->_b, dof, size)) nvlog("blit copyFromBuffer: FAILED");
}
- (void)fillBuffer:(id<MTLBuffer>)buf range:(NSRange)range value:(uint8_t)value { if (_cb) nvmtl_vk_cmd_blit_settle(&_cb->_c);
    NVMTLBuffer *b = nvmtl_as_buffer(buf, "blit fillBuffer");
    if (!b) { nvlog("blit fillBuffer: nil buffer"); return; }
    nvmtl_blit_tally(_cb, 0, range.length, 0);
    if (!_cb->_resources) _cb->_resources = [NVMTLResSet new];
    [_cb->_resources addObject:b];
    if (nvmtl_vk_cmd_fill_buffer(&_cb->_c, &b->_b, range.location, range.length, value))
        nvlog("blit fillBuffer: FAILED");
}
- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl
           sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dst
       destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dof { if (_cb) nvmtl_vk_cmd_blit_settle(&_cb->_c);
    NVMTLTexture *s = (NVMTLTexture *)src, *d = (NVMTLTexture *)dst;
    if (s) { const uint32_t bpp = [s nvi]->bpp ? [s nvi]->bpp : 4; nvmtl_blit_tally(_cb, 2, (unsigned long long)size.width * size.height * MAX(size.depth, 1u) * bpp, 0); }
    if (d && dl + d->_baseLevel > 0) (d->_parent ?: d)->_mipsWritten = YES;
    nvmtl_histcb(d, 'C', _cb);
    if (!s || !d) { nvlog("blit copyFromTexture: nil"); return; }
    if (sl >= s.mipmapLevelCount || dl >= d.mipmapLevelCount || ss >= nvmtl_texture_slice_count(s) || ds >= nvmtl_texture_slice_count(d)) {
        nvlog("blit copyFromTexture: subresource outside view"); return;
    }
    if (!_cb->_resources) _cb->_resources = [NVMTLResSet new];
    [_cb->_resources addObject:s];
    [_cb->_resources addObject:d];
    { int was = nvtrace_scope([d nvi]->w, [d nvi]->h);
      nvtrace("BLIT tex %p(img %p heap %p+%lu) %ux%u surf %u (%lu,%lu %lux%lu) L%lu/S%lu -> tex %p(img %p heap %p+%lu) %ux%u surf %u (%lu,%lu) L%lu/S%lu", (__bridge void *)s, (void *)[s nvi]->img, (__bridge void *)s->_heap, (unsigned long)s->_heapOffset,
          [s nvi]->w, [s nvi]->h, nvmtl_surf_id(s), (unsigned long)so.x, (unsigned long)so.y, (unsigned long)size.width, (unsigned long)size.height,
          (unsigned long)sl, (unsigned long)ss, (__bridge void *)d, (void *)[d nvi]->img, (__bridge void *)d->_heap, (unsigned long)d->_heapOffset, [d nvi]->w, [d nvi]->h, nvmtl_surf_id(d), (unsigned long)dof.x, (unsigned long)dof.y,
          (unsigned long)dl, (unsigned long)ds);
      g_trace_mute = was; }
    nvmtl_surface_in_for_cb(_cb, s);
    const BOOL overwrite = [s nvi] != [d nvi] && (!s->_surf || !d->_surf || IOSurfaceGetID(s->_surf) != IOSurfaceGetID(d->_surf))
        && nvmtl_surface_full_overwrite(d, (MTLRegion){dof, size}, dl, ds);
    if (!overwrite) nvmtl_surface_in_for_cb(_cb, d);
    nvmtl_surf_dirty(_cb, d);
    if (nvmtl_vk_cmd_copy_image_sub3(&_cb->_c, [s nvi], (uint32_t)sl + s->_baseLevel, (uint32_t)ss + s->_baseSlice, (uint32_t)so.x, (uint32_t)so.y, (uint32_t)so.z,
                                [d nvi], (uint32_t)dl + d->_baseLevel, (uint32_t)ds + d->_baseSlice, (uint32_t)dof.x, (uint32_t)dof.y, (uint32_t)dof.z,
                                (uint32_t)size.width, (uint32_t)size.height, (uint32_t)(size.depth ? size.depth : 1)))
        nvlog("blit copyFromTexture: FAILED");
    else {
        if (overwrite) nvmtl_surface_overwrite_recorded(_cb, d);
        if ((size.depth ? size.depth : 1) == 1 && [s nvi]->mtl_type != 7 && nvmtl_texverify_live())
            nvmtl_texverify(_cb, s, (uint32_t)sl + s->_baseLevel, (uint32_t)ss + s->_baseSlice, (uint32_t)so.x, (uint32_t)so.y,
                            d, (uint32_t)dl + d->_baseLevel, (uint32_t)ds + d->_baseSlice, (uint32_t)dof.x, (uint32_t)dof.y, (uint32_t)size.width, (uint32_t)size.height);
    }
}
- (void)sampleCountersInBuffer:(id)sb atSampleIndex:(NSUInteger)i withBarrier:(BOOL)b { if (_cb) nvmtl_vk_cmd_blit_settle(&_cb->_c); nvmtl_sample_counter(_cb, sb, i, self, b); }
- (void)resolveCounters:(id)sb inRange:(NSRange)r destinationBuffer:(id<MTLBuffer>)dst destinationOffset:(NSUInteger)off { if (_cb) nvmtl_vk_cmd_blit_settle(&_cb->_c);
    NVMTLBuffer *b = (NVMTLBuffer *)dst;
    if (!b || !r.length) { nvlog("resolveCounters: no destination buffer or empty range"); nvmtl_counter_recording_failed(_cb); return; }
    if (!_cb->_resources) _cb->_resources = [NVMTLResSet new];
    [_cb->_resources addObject:b];
    NVMTLCounterSampleBuffer *s = [sb isKindOfClass:[NVMTLCounterSampleBuffer class]] ? sb : nil;
    if (!s || r.location > s->_count || r.length > s->_count - r.location) {
        nvlog("resolveCounters: %s, range %lu+%lu of %lu samples - not resolved", s ? "range outside the buffer" : "not a sample buffer this device made",
              (unsigned long)r.location, (unsigned long)r.length, s ? (unsigned long)s->_count : 0ul);
        nvmtl_counter_recording_failed(_cb); return;
    }
    [_cb->_resources addObject:s];
    if (nvmtl_vk_cmd_ts_resolve(&_cb->_c, s->_pool, (uint32_t)r.location, (uint32_t)r.length, &b->_b, off))
        nvmtl_counter_recording_failed(_cb);
}
- (void)generateMipmapsForTexture:(id<MTLTexture>)tex { if (_cb) nvmtl_vk_cmd_blit_settle(&_cb->_c);
    NVMTLTexture *t = nvmtl_as_texture(tex, "blit generateMipmaps");
    if (!t) { nvlog("generateMipmapsForTexture: nil"); return; }
    if (!_cb->_resources) _cb->_resources = [NVMTLResSet new];
    [_cb->_resources addObject:t];
    { int was = nvtrace_scope([t nvi]->w, [t nvi]->h); nvtrace("MIPS tex %ux%u surf %u", [t nvi]->w, [t nvi]->h, nvmtl_surf_id(t)); g_trace_mute = was; }
    (t->_parent ?: t)->_mipsWritten = YES;
    nvmtl_surface_in_for_cb(_cb, t); nvmtl_surf_dirty(_cb, t);
    nvmtl_histcb(t, 'M', _cb);
    if (nvmtl_vk_cmd_image_gen_mipmaps(&_cb->_c, [t nvi])) nvlog("generateMipmapsForTexture: FAILED");
}
- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl toTexture:(id<MTLTexture>)dst
       destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl sliceCount:(NSUInteger)nslices levelCount:(NSUInteger)nlevels { if (_cb) nvmtl_vk_cmd_blit_settle(&_cb->_c);
    NVMTLTexture *s = (NVMTLTexture *)src, *d = (NVMTLTexture *)dst;
    if (!s || !d) { nvlog("blit copyFromTexture:sliceCount: nil"); return; }
    if (!_cb->_resources) _cb->_resources = [NVMTLResSet new];
    [_cb->_resources addObject:s]; [_cb->_resources addObject:d];
    for (NSUInteger k = 0; k < (nslices ? nslices : 1); k++)
        for (NSUInteger l = 0; l < (nlevels ? nlevels : 1); l++) {
            if (sl + l >= s.mipmapLevelCount || dl + l >= d.mipmapLevelCount) { nvlog("blit sliceCount: mip outside view"); return; }
            NSUInteger w = MAX((NSUInteger)1, s.width >> (sl + l)), h = MAX((NSUInteger)1, s.height >> (sl + l));
            NSUInteger dp = s.textureType == MTLTextureType3D ? MAX((NSUInteger)1, s.depth >> (sl + l)) : 1;
            [self copyFromTexture:s sourceSlice:ss + k sourceLevel:sl + l sourceOrigin:MTLOriginMake(0,0,0)
                      sourceSize:MTLSizeMake(w,h,dp) toTexture:d destinationSlice:ds + k destinationLevel:dl + l destinationOrigin:MTLOriginMake(0,0,0)];
        }
}
- (void)optimizeContentsForGPUAccess:(id<MTLTexture>)t {}
- (void)optimizeContentsForGPUAccess:(id<MTLTexture>)t slice:(NSUInteger)s level:(NSUInteger)l {}
- (void)optimizeContentsForCPUAccess:(id<MTLTexture>)t {}
- (void)optimizeContentsForCPUAccess:(id<MTLTexture>)t slice:(NSUInteger)s level:(NSUInteger)l {}
- (void)resetCommandsInBuffer:(id<MTLIndirectCommandBuffer>)icb withRange:(NSRange)r { if (_cb) nvmtl_vk_cmd_blit_settle(&_cb->_c);
    if ([(id)icb isKindOfClass:[NVMTLIndirectCommandBuffer class]]) [(NVMTLIndirectCommandBuffer *)icb resetWithRange:r];
    else nvlog("blit resetCommandsInBuffer: a %s is not our indirect command buffer — ignored", object_getClassName(icb));
}
- (void)copyIndirectCommandBuffer:(id<MTLIndirectCommandBuffer>)src sourceRange:(NSRange)r destination:(id<MTLIndirectCommandBuffer>)dst destinationIndex:(NSUInteger)di { if (_cb) nvmtl_vk_cmd_blit_settle(&_cb->_c);
    if (![(id)src isKindOfClass:[NVMTLIndirectCommandBuffer class]] || ![(id)dst isKindOfClass:[NVMTLIndirectCommandBuffer class]]) {
        nvlog("blit copyIndirectCommandBuffer: not our indirect command buffers — ignored"); return; }
    NVMTLIndirectCommandBuffer *s = (NVMTLIndirectCommandBuffer *)src, *d = (NVMTLIndirectCommandBuffer *)dst;
    if (r.location + r.length > s->_cmds.count || di + r.length > d->_cmds.count) {
        nvlog("blit copyIndirectCommandBuffer: range [%lu,+%lu) -> %lu is outside the buffers (%lu / %lu slots) — ignored", (unsigned long)r.location,
              (unsigned long)r.length, (unsigned long)di, (unsigned long)s->_cmds.count, (unsigned long)d->_cmds.count); return; }
    for (NSUInteger k = 0; k < r.length; k++) [d->_cmds[di + k] nvmtlCopyFrom:s->_cmds[r.location + k]];
}
- (void)optimizeIndirectCommandBuffer:(id<MTLIndirectCommandBuffer>)icb withRange:(NSRange)r {}
- (void)copyFromTexture:(id<MTLTexture>)src toTexture:(id<MTLTexture>)dst { if (_cb) nvmtl_vk_cmd_blit_settle(&_cb->_c);
    NVMTLTexture *s = (NVMTLTexture *)src, *d = (NVMTLTexture *)dst;
    if (!s || !d) { nvlog("blit copyFromTexture:toTexture: nil"); return; }
    const char *e = getenv("NVMTL_WHOLE_COPY_ALL");
    const NSUInteger levels = MIN(s.mipmapLevelCount, d.mipmapLevelCount), slices = MIN(nvmtl_texture_slice_count(s), nvmtl_texture_slice_count(d));
    { static _Atomic uint64_t n; const uint64_t k = atomic_fetch_add(&n, 1) + 1;
      if (k <= 12 || !(k & (k - 1)))
          nvlog("blit copyFromTexture:toTexture: %lux%lu fmt %lu mips %lu->%lu slices %lu->%lu - %s [%llu so far]", (unsigned long)s.width, (unsigned long)s.height,
                (unsigned long)s.pixelFormat, (unsigned long)s.mipmapLevelCount, (unsigned long)d.mipmapLevelCount,
                (unsigned long)nvmtl_texture_slice_count(s), (unsigned long)nvmtl_texture_slice_count(d),
                (e && *e == '0') ? "ONLY level 0 slice 0 copied (NVMTL_WHOLE_COPY_ALL=0)" : "every level and slice copied", (unsigned long long)k); }
    if (s.width != d.width || s.height != d.height || s.mipmapLevelCount != d.mipmapLevelCount || nvmtl_texture_slice_count(s) != nvmtl_texture_slice_count(d)) {
        static int said; if (said++ < 8) nvlog("blit copyFromTexture:toTexture: the textures differ (%lux%lu mips %lu slices %lu -> %lux%lu mips %lu slices %lu) - the overlapping levels and slices are copied",
            (unsigned long)s.width, (unsigned long)s.height, (unsigned long)s.mipmapLevelCount, (unsigned long)nvmtl_texture_slice_count(s),
            (unsigned long)d.width, (unsigned long)d.height, (unsigned long)d.mipmapLevelCount, (unsigned long)nvmtl_texture_slice_count(d)); }
    if (e && *e == '0') {
        [self copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(s.width, s.height, s.textureType == MTLTextureType3D ? s.depth : 1) toTexture:dst
             destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        return;
    }
    [self copyFromTexture:src sourceSlice:0 sourceLevel:0 toTexture:dst destinationSlice:0 destinationLevel:0 sliceCount:slices levelCount:levels];
}
- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)so sourceBytesPerRow:(NSUInteger)row
   sourceBytesPerImage:(NSUInteger)img sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dst
      destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dof { if (_cb) nvmtl_vk_cmd_blit_settle(&_cb->_c);
    atomic_fetch_add(&nvmtl_fm_blit2tex, 1);
    nvmtl_blit_tally(_cb, 1, img ? (unsigned long long)img * MAX(size.depth, 1u) : (unsigned long long)row * size.height * MAX(size.depth, 1u), nvmtl_buf_sys(src));
    NVMTLBuffer *b = (NVMTLBuffer *)src; NVMTLTexture *t = (NVMTLTexture *)dst;
    if (!b || !t) { nvlog("blit copyFromBuffer:toTexture: nil"); return; }
    nvmtl_histcb(t, 'U', _cb);
    if (!_cb->_resources) _cb->_resources = [NVMTLResSet new];
    [_cb->_resources addObject:b];
    [_cb->_resources addObject:t];
    { nvk_image *ti = [t nvi]; uint32_t tl = (uint32_t)nvmtl_texture_slice_count(t), tm = (uint32_t)t.mipmapLevelCount; BOOL vol = ti->mtl_type == 7;
      if (ds >= tl || dl >= tm || (vol ? (dof.z + size.depth > MAX((NSUInteger)1, t.depth >> dl)) : (size.depth != 1 || dof.z))) {
          nvlog("blit copyFromBuffer:toTexture: slice %lu/%u level %lu/%u depth %lu@z%lu — outside this texture", (unsigned long)ds, tl, (unsigned long)dl, tm, (unsigned long)size.depth, (unsigned long)dof.z); return; } }
    { int was = nvtrace_scope([t nvi]->w, [t nvi]->h);
      if (nvmtl_trace_on()) { unsigned nz = 0, nn = 0; size_t valid = (size_t)size.width * [t nvi]->bpp; if (row && valid > row) valid = row;
        if (b->_b.map && size.height && so + (size_t)(size.height - 1) * row + valid <= b->_b.size)
            nvmtl_nonzero((const char *)b->_b.map + so, row, valid, (uint32_t)size.height, &nz, &nn);
        nvtrace("BLIT buf len %lu off %lu row %lu (%lux%lu) -> tex %ux%u surf %u (%lu,%lu) | nonzero %u/%u sampled bytes", (unsigned long)b->_b.size, (unsigned long)so,
            (unsigned long)row, (unsigned long)size.width, (unsigned long)size.height, [t nvi]->w, [t nvi]->h, nvmtl_surf_id(t), (unsigned long)dof.x, (unsigned long)dof.y, nz, nn); }
      g_trace_mute = was; }
    nvk_buffer *zsrc = NULL;
    { static int zon = -1, zmark = -1;
      if (zon < 0) { const char *e = getenv("NVMTL_ZERO_UPLOAD"); zon = (e && *e == '1') || getenv("NVMTL_ZERO_UPLOAD_MARK"); const char *m = getenv("NVMTL_ZERO_UPLOAD_MARK"); zmark = m && *m == '1';
                     nvlog("zero upload census: %s; marking %s (NVMTL_ZERO_UPLOAD_MARK=1 copies a magenta/white BC marker instead of an all-zero BC upload)", zon ? "ON" : "OFF", zmark ? "ON" : "off"); }
      nvk_image *zi = [t nvi];
      if (zon && zi && zi->mtl_type != 7 && row && size.width && size.height) {
          static _Atomic uint64_t nUp, nCpu, nZero, nLate, nPriv;
          const uint32_t bw = zi->bw ? zi->bw : 1, bh = zi->bh ? zi->bh : 1, bpp = zi->bpp ? zi->bpp : 4;
          const size_t rows = (size.height + bh - 1) / bh, tight = ((size.width + bw - 1) / bw) * (size_t)bpp;
          atomic_fetch_add(&nUp, 1);
          if (!b->_b.map) atomic_fetch_add(&nPriv, 1);
          else if (tight <= row && so + (rows - 1) * row + tight <= b->_b.size) {
              atomic_fetch_add(&nCpu, 1);
              const uint8_t *src = (const uint8_t *)b->_b.map + so; int zero = 1;
              for (size_t r = 0; r < rows && zero; r++) { const uint64_t *q = (const uint64_t *)(src + r * row); size_t k = 0;
                  for (; k + 8 <= tight; k += 8) if (*(const uint64_t *)(src + r * row + k)) { zero = 0; break; }
                  for (; zero && k < tight; k++) if (src[r * row + k]) zero = 0; (void)q; }
              if (zero) {
                  const uint64_t zn = atomic_fetch_add(&nZero, 1) + 1; const unsigned fr = atomic_load(&nvmtl_flick_frame);
                  NVMTLTexture *rt = t->_parent ?: t;
                  if (zn <= 4000)
                      nvlog_diag("zero upload: ALL-ZERO source at frame %u: buffer %p len %zu storage %lu off %lu row %lu -> texture %p fmt %lu %ux%u mips %u layers %u level %lu slice %lu region (%lu,%lu %lux%lu) heap %p born %u uploads-so-far %u [%llu zero of %llu CPU-visible, %llu from GPU-only buffers]",
                                 fr, (__bridge void *)b, b->_b.size, (unsigned long)b.storageMode, (unsigned long)so, (unsigned long)row, (__bridge void *)rt, (unsigned long)rt->_fmt, zi->w, zi->h, zi->mips, zi->layers,
                                 (unsigned long)(dl + t->_baseLevel), (unsigned long)(ds + t->_baseSlice), (unsigned long)dof.x, (unsigned long)dof.y, (unsigned long)size.width, (unsigned long)size.height,
                                 (__bridge void *)rt->_heap, rt->_hBornFrame, rt->_hUp, (unsigned long long)zn, (unsigned long long)atomic_load(&nCpu), (unsigned long long)atomic_load(&nPriv));
                  NVMTLBuffer *keep = b; const size_t so_ = so, row_ = row, rows_ = rows, tight_ = tight;
                  [_cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
                      const uint8_t *s2 = (const uint8_t *)keep->_b.map + so_; int z2 = 1;
                      for (size_t r = 0; r < rows_ && z2; r++) for (size_t k = 0; k < tight_; k++) if (s2[r * row_ + k]) { z2 = 0; break; }
                      if (!z2) { const uint64_t ln = atomic_fetch_add(&nLate, 1) + 1;
                          if (ln <= 2000) nvlog_diag("zero upload: LATE DATA - the source of a copy encoded at frame %u was all zero then and holds data at completion (frame %u): buffer %p off %zu - the app wrote it after the copy was encoded [%llu late]",
                                                     fr, atomic_load(&nvmtl_flick_frame), (__bridge void *)keep, so_, (unsigned long long)ln); }
                  }];
                  if (zmark) { extern nvk_buffer *nvmtl_vk_mark_source(uint32_t vkfmt, uint32_t *block_bytes); uint32_t bb = 0;
                               nvk_buffer *ms = nvmtl_vk_mark_source(zi->fmt, &bb);
                               if (ms && rows * row <= ms->size) zsrc = ms; }
              }
          }
          const uint64_t u = atomic_load(&nUp);
          if (!(u % 8192)) nvlog_diag("zero upload census: %llu uploads, %llu from CPU-visible buffers, %llu of those ALL ZERO, %llu filled late, %llu from GPU-only buffers, frame %u",
                                      (unsigned long long)u, (unsigned long long)atomic_load(&nCpu), (unsigned long long)atomic_load(&nZero), (unsigned long long)atomic_load(&nLate), (unsigned long long)atomic_load(&nPriv), atomic_load(&nvmtl_flick_frame));
      } }
    const BOOL overwrite = nvmtl_surface_full_overwrite(t, (MTLRegion){dof, size}, dl, ds);
    if (!overwrite) nvmtl_surface_in_for_cb(_cb, t);
    nvmtl_surf_dirty(_cb, t);
    { BOOL vol = [t nvi]->mtl_type == 7; NSUInteger nz = vol ? (size.depth ? size.depth : 1) : 1; NSUInteger per = img ? img : row * size.height; int rc = 0;
      for (NSUInteger zi = 0; zi < nz && !rc; zi++)
          rc = nvmtl_vk_cmd_copy_buffer_to_image_level_layer(&_cb->_c, zsrc ? zsrc : &b->_b, zsrc ? 0 : so + zi * per, (uint32_t)row, [t nvi],
                                      (uint32_t)dof.x, (uint32_t)dof.y, (uint32_t)size.width, (uint32_t)size.height, (uint32_t)dl + t->_baseLevel, (uint32_t)(vol ? dof.z + zi : ds + t->_baseSlice));
      if (rc) nvlog("blit copyFromBuffer:toTexture: FAILED (level %lu slice %lu)", (unsigned long)dl, (unsigned long)ds);
      else if (overwrite) nvmtl_surface_overwrite_recorded(_cb, t);
      if (!rc && !vol && !nvmtl_vk_copy_aspect_active())
          nvmtl_w_capture(_cb, t, (uint32_t)dl + t->_baseLevel, (uint32_t)(ds + t->_baseSlice), (uint32_t)dof.x, (uint32_t)dof.y, (uint32_t)size.width, (uint32_t)size.height);
      if (!rc && !vol && nvmtl_upverify_live() && !nvmtl_vk_copy_aspect_active())
          nvmtl_upverify(_cb, b, so, (uint32_t)row, t, (uint32_t)dof.x, (uint32_t)dof.y, (uint32_t)size.width, (uint32_t)size.height, (uint32_t)dl + t->_baseLevel, (uint32_t)(ds + t->_baseSlice));
      { NVMTLTexture *r = t->_parent ?: t;
        if (dl + t->_baseLevel > 0) r->_mipsWritten = YES;
        else if (!rc && !vol && !t->_parent && !r->_mipsWritten && t.mipmapLevelCount > 1 && !dof.x && !dof.y && size.width == [t nvi]->w && size.height == [t nvi]->h && [t nvi]->bw <= 1
                 && nvmtl_vk_cmd_image_gen_mipmaps(&_cb->_c, [t nvi])) nvlog("blit copyFromBuffer:toTexture: mip generation FAILED"); } }
}
- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)so sourceBytesPerRow:(NSUInteger)row
   sourceBytesPerImage:(NSUInteger)img sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dst
      destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dof
               options:(MTLBlitOption)opt { if (_cb) nvmtl_vk_cmd_blit_settle(&_cb->_c);
    atomic_fetch_add(&nvmtl_fm_blit2tex, 1);
    const uint32_t asp = (opt & MTLBlitOptionDepthFromDepthStencil) ? 2u : (opt & MTLBlitOptionStencilFromDepthStencil) ? 4u : 0u;
    if (opt & ~(MTLBlitOptionDepthFromDepthStencil | MTLBlitOptionStencilFromDepthStencil))
        nvlog("blit copyFromBuffer:toTexture:options:%lu — only the depth/stencil options are implemented", (unsigned long)opt);
    nvmtl_vk_copy_aspect_override(asp, asp == 2u ? 4u : asp == 4u ? 1u : 0u);
    [self copyFromBuffer:src sourceOffset:so sourceBytesPerRow:row sourceBytesPerImage:img sourceSize:size
               toTexture:dst destinationSlice:ds destinationLevel:dl destinationOrigin:dof];
    nvmtl_vk_copy_aspect_override(0, 0);
}
- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl
           sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)size toBuffer:(id<MTLBuffer>)dst
      destinationOffset:(NSUInteger)dof destinationBytesPerRow:(NSUInteger)row
destinationBytesPerImage:(NSUInteger)img { if (_cb) nvmtl_vk_cmd_blit_settle(&_cb->_c);
    nvmtl_blit_tally(_cb, 2, img ? (unsigned long long)img * MAX(size.depth, 1u) : (unsigned long long)row * size.height * MAX(size.depth, 1u), 0);
    NVMTLTexture *t = (NVMTLTexture *)src; NVMTLBuffer *b = (NVMTLBuffer *)dst;
    if (!t || !b) { nvlog("blit copyFromTexture:toBuffer: nil"); return; }
    if (!_cb->_resources) _cb->_resources = [NVMTLResSet new];
    [_cb->_resources addObject:t];
    [_cb->_resources addObject:b];
    { nvk_image *ti = [t nvi]; uint32_t tl = (uint32_t)nvmtl_texture_slice_count(t), tm = (uint32_t)t.mipmapLevelCount; BOOL vol = ti->mtl_type == 7;
      if (ss >= tl || sl >= tm || (vol ? (so.z + size.depth > MAX((NSUInteger)1, t.depth >> sl)) : (size.depth != 1 || so.z))) {
          nvlog("blit copyFromTexture:toBuffer: slice %lu/%u level %lu/%u depth %lu@z%lu — outside this texture", (unsigned long)ss, tl, (unsigned long)sl, tm, (unsigned long)size.depth, (unsigned long)so.z); return; } }
    nvmtl_surface_in_for_cb(_cb, t);
    nvmtl_census("copy texture->buffer", [t nvi]->w, [t nvi]->h, t->_surf != NULL);
    { int was = nvtrace_scope([t nvi]->w, [t nvi]->h);
      nvtrace("BLIT tex %ux%u surf %u (%lu,%lu %lux%lu) -> buf len %lu off %lu row %lu", [t nvi]->w, [t nvi]->h, nvmtl_surf_id(t), (unsigned long)so.x, (unsigned long)so.y,
          (unsigned long)size.width, (unsigned long)size.height, (unsigned long)b->_b.size, (unsigned long)dof, (unsigned long)row);
      g_trace_mute = was; }
    { BOOL vol = [t nvi]->mtl_type == 7; NSUInteger nz = vol ? (size.depth ? size.depth : 1) : 1; NSUInteger per = img ? img : row * size.height; int rc = 0;
      for (NSUInteger zi = 0; zi < nz && !rc; zi++)
          rc = nvmtl_vk_cmd_copy_image_to_buffer_level_layer(&_cb->_c, [t nvi], (uint32_t)so.x, (uint32_t)so.y,
                                      (uint32_t)size.width, (uint32_t)size.height, &b->_b, dof + zi * per, (uint32_t)row, (uint32_t)sl + t->_baseLevel, (uint32_t)(vol ? so.z + zi : ss + t->_baseSlice));
      if (rc) nvlog("blit copyFromTexture:toBuffer: FAILED (level %lu slice %lu)", (unsigned long)sl, (unsigned long)ss); }
}
- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl
           sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)size toBuffer:(id<MTLBuffer>)dst
      destinationOffset:(NSUInteger)dof destinationBytesPerRow:(NSUInteger)row
destinationBytesPerImage:(NSUInteger)img options:(MTLBlitOption)opt { if (_cb) nvmtl_vk_cmd_blit_settle(&_cb->_c);
    const uint32_t asp = (opt & MTLBlitOptionDepthFromDepthStencil) ? 2u : (opt & MTLBlitOptionStencilFromDepthStencil) ? 4u : 0u;
    if (opt & ~(MTLBlitOptionDepthFromDepthStencil | MTLBlitOptionStencilFromDepthStencil))
        nvlog("blit copyFromTexture:toBuffer:options:%lu — only the depth/stencil options are implemented", (unsigned long)opt);
    nvmtl_vk_copy_aspect_override(asp, asp == 2u ? 4u : asp == 4u ? 1u : 0u);
    [self copyFromTexture:src sourceSlice:ss sourceLevel:sl sourceOrigin:so sourceSize:size toBuffer:dst
        destinationOffset:dof destinationBytesPerRow:row destinationBytesPerImage:img];
    nvmtl_vk_copy_aspect_override(0, 0);
}
- (void)updateFence:(id<MTLFence>)f { if (_cb) nvmtl_vk_cmd_blit_settle(&_cb->_c);}
- (void)waitForFence:(id<MTLFence>)f { if (_cb) nvmtl_vk_cmd_blit_settle(&_cb->_c); nvmtl_vk_cmd_barrier(&_cb->_c); }
- (void)pushDebugGroup:(NSString *)g { nvtrace("GROUP %s", g.UTF8String ?: "?"); }
- (void)popDebugGroup {}
- (void)insertDebugSignpost:(NSString *)s {}
- (void)synchronizeResource:(id<MTLResource>)r { if (_cb) nvmtl_vk_cmd_blit_settle(&_cb->_c);
    if (!r) return;
    if (!_cb->_resources) _cb->_resources = [NVMTLResSet new];
    [_cb->_resources addObject:r];
    if ([(id)r isKindOfClass:[NVMTLBuffer class]] && ((NVMTLBuffer *)r)->_shadow.map) {
        NVMTLBuffer *b = (NVMTLBuffer *)r;
        __atomic_store_n(&b->_zshadow, 0, __ATOMIC_RELEASE);
        if (nvmtl_vk_cmd_copy_buffer(&_cb->_c, &b->_b, 0, &b->_shadow, 0, b->_b.size))
            [_cb nvmtlRecordEncodingError:[NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorInternal
                userInfo:@{NSLocalizedDescriptionKey:@"Cannot encode managed buffer synchronization"}]];
    }
    if ([(id)r isKindOfClass:[NVMTLTexture class]]) {
        NVMTLTexture *t = (NVMTLTexture *)r;
        NVMTLBuffer *bb = t->_backBuf ? t->_backBuf : (t->_parent ? t->_parent->_backBuf : nil);
        if (bb && bb->_shadow.map) {
            [_cb->_resources addObject:bb];
            __atomic_store_n(&bb->_zshadow, 0, __ATOMIC_RELEASE);
            if (nvmtl_vk_cmd_copy_buffer(&_cb->_c, &bb->_b, 0, &bb->_shadow, 0, bb->_b.size))
                [_cb nvmtlRecordEncodingError:[NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorInternal
                    userInfo:@{NSLocalizedDescriptionKey:@"Cannot encode managed buffer-texture synchronization"}]];
        }
    }
}
- (void)synchronizeTexture:(id<MTLTexture>)t slice:(NSUInteger)s level:(NSUInteger)l { if (_cb) nvmtl_vk_cmd_blit_settle(&_cb->_c); [self synchronizeResource:t]; }
// The encoder lets go of its command buffer when encoding ends, as Metal's own encoders do. An app's autorelease pool
// can keep an ended encoder alive for a long time (a benchmark loop that never drains), and a strong reference here kept
// every such command buffer, and every buffer it used, alive with it: VRAM filled until allocations were refused.
- (void)endEncoding { nvmtl_enc_end(); if (_cb) { nvmtl_vk_cmd_blit_settle(&_cb->_c); { extern void nvmtl_vk_pt_seg_end(nvk_cmdbuf *c, uint32_t kind, uint32_t count); nvmtl_vk_pt_seg_end(&_cb->_c, 9002u, _cb->_c.bl_ops ? _cb->_c.bl_ops : 1u); _cb->_c.bl_ops = 0; } _cb->_nEnd++; _cb = nil; } }
- (void)setLabel:(NSString *)l { _label = [l copy]; }
- (NSString *)label { return _label; }
- (id<MTLDevice>)device { id<MTLDevice> d = _cb ? [_cb device] : nil; return d ? d : (id<MTLDevice>)gNVMTLMainDevice; }
- (id<MTLCommandBuffer>)commandBuffer { return (id<MTLCommandBuffer>)(_cb ? _cb : _owner); }   // SPI, see the render encoder; _cb is gone after endEncoding
@end

#pragma mark - command buffer / queue
#import "NVMTLEventSync.m"
@implementation NVMTLCommandBuffer
// Never a lock on the command buffer itself: apps may hold @synchronized(commandBuffer) around -waitUntilCompleted
// (Unity 6 does), and this runs on the execution queue that completes it. Vampire Survivors hung on its first frame
// (1.14.2-1.14.4, sample from a user: the execution queue in objc_sync_enter here, Unity's thread in waitUntilCompleted).
- (void)nvmtlReleaseCapacity {
    if (__atomic_exchange_n(&_capacityHeld, NO, __ATOMIC_ACQ_REL)) dispatch_semaphore_signal(_queue->_capacity);
}
- (void)nvmtlRecordEncodingError:(NSError *)error { if (!_cbError) _cbError = error; }
- (void)setProtectionOptions:(unsigned long long)o { if (o) { static int said; if (!said++) nvlog("setProtectionOptions: 0x%llx asked - no protected-content path; protectionOptions stays 0 (said once)", o); } }
- (unsigned long long)globalTraceObjectID { return nvmtl_global_trace_id(self); }
- (BOOL)retainedReferences { return YES; }
- (MTLCommandBufferErrorOption)errorOptions { return MTLCommandBufferErrorOptionNone; }
- (id<MTLLogContainer>)logs { return nil; }
- (unsigned long long)protectionOptions { return 0; }
- (instancetype)init {
    if ((self = [super init])) {
        _completionCondition = [NSCondition new];
        // Made here, never lazily: two threads encoding into one command buffer could each find it nil and store
        // their own set, and the set that lost was freed with the resources only it held (and under the other
        // thread's addObject:).
        _resources = [NVMTLResSet new];
        _callbackGroup = dispatch_group_create(); _scheduledGroup = dispatch_group_create();
    }
    return self;
}
- (void)useResidencySet:(id<MTLResidencySet>)r {}
- (void)useResidencySets:(const id<MTLResidencySet> __unsafe_unretained [])r count:(NSUInteger)n {}
- (NSMutableDictionary *)userDictionary {
    @synchronized ([NVMTLCommandBuffer class]) { if (!_userDictionary) _userDictionary = [NSMutableDictionary new]; return _userDictionary; }
}
- (id<MTLParallelRenderCommandEncoder>)parallelRenderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d {
    nvmtl_enc_begin();
    nvmtl_g79_flush(self);
    NVMTLParallelRenderCommandEncoder *p = [NVMTLParallelRenderCommandEncoder new];
    _nEnc++;
    p->_cb = self; p->_desc = [d copy]; p->_subs = [NSMutableArray new]; p->_lock = [NSLock new];
    {   // NVMTL_PAR_DIRECT=1 (opt-in; off by default: every sub-encoder becomes its own render pass and part, attachments reloaded and stored behind a full barrier - Cyberpunk 2077 27.98 fps against 29.40 with the replay, 2026-11-08): sub-encoders record straight into their own recordings on their own threads
        // (see -renderCommandEncoder); not for passes this cannot express per sub-encoder: resolves, a visibility buffer, an
        // IOSurface attachment (drawable / shared surface bookkeeping)
        static int on = -1; if (on < 0) { const char *e = getenv("NVMTL_PAR_DIRECT"); on = e && e[0] == '1'; }
        BOOL ok = on && !d.visibilityResultBuffer && !d.depthAttachment.resolveTexture && !d.stencilAttachment.resolveTexture;
        for (NSUInteger ci = 0; ok && ci < 8; ci++) {
            NVMTLTexture *t = (NVMTLTexture *)d.colorAttachments[ci].texture; if (!t) continue;
            if (d.colorAttachments[ci].resolveTexture || (t->_parent ? t->_parent : t)->_surf) ok = NO;
        }
        NVMTLTexture *dt = (NVMTLTexture *)d.depthAttachment.texture; if (ok && dt && (dt->_parent ? dt->_parent : dt)->_surf) ok = NO;
        p->_direct = ok; if (ok) p->_shadows = [NSMutableArray new];
    }
    MTLSamplePosition copiedSample[8]; NSUInteger copiedCount = [d getSamplePositions:NULL count:0];
    if (copiedCount && copiedCount <= 8) [d getSamplePositions:copiedSample count:copiedCount];
    if (copiedCount <= 8) [p->_desc setSamplePositions:copiedSample count:copiedCount];

    nvlog("parallelRenderCommandEncoderWithDescriptor: -> %p (sub-encoders record, endEncoding replays into one pass)", (__bridge void *)p);
    return p;
}
- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d {
    { static int on = -1; if (on < 0) { const char *e = getenv("NVMTL_GBUF_CLEAR_MARK"); on = e && *e == '1'; if (on) nvlog("gbuffer clear mark: ON - a pass with 3+ colour targets whose first is BGR10A2/RGB10A2 and is cleared clears it to magenta, not to what the app asked"); }
      if (on && d) {
          static __weak id gb0; static os_unfair_lock gbl = OS_UNFAIR_LOCK_INIT;
          id<MTLTexture> c0 = d.colorAttachments[0].texture; int ncol = 0;
          for (NSUInteger ci = 0; ci < 8; ci++) if (d.colorAttachments[ci].texture) ncol++;
          if (c0 && ncol >= 3 && (c0.pixelFormat == MTLPixelFormatBGR10A2Unorm || c0.pixelFormat == MTLPixelFormatRGB10A2Unorm)) {
              NVMTLTexture *r0 = (NVMTLTexture *)c0; r0 = r0->_parent ? r0->_parent : r0;
              os_unfair_lock_lock(&gbl); gb0 = r0; os_unfair_lock_unlock(&gbl); }
          os_unfair_lock_lock(&gbl); id g = gb0; os_unfair_lock_unlock(&gbl);
          for (NSUInteger ci = 0; g && ci < 8; ci++) {
              NVMTLTexture *t = (NVMTLTexture *)d.colorAttachments[ci].texture; if (!t) continue;
              if ((t->_parent ? t->_parent : t) != g || d.colorAttachments[ci].loadAction != MTLLoadActionClear) continue;
              d = [d copy]; d.colorAttachments[ci].clearColor = MTLClearColorMake(1.0, 0.0, 1.0, 1.0);
              static _Atomic uint64_t n; const uint64_t k = atomic_fetch_add(&n, 1) + 1;
              if (!(k & (k - 1))) nvlog_diag("gbuffer clear mark: %llu albedo clears turned magenta (attachment %lu of %d, %lux%lu)", (unsigned long long)k, (unsigned long)ci, ncol, (unsigned long)t.width, (unsigned long)t.height);
              break;
          } } }
    nvmtl_enc_begin();
    nvmtl_g79_flush(self);
    nvmtl_w_check(self);
    NVMTLRenderCommandEncoder *e = [NVMTLRenderCommandEncoder new];
    _nEnc++;
    e->_cb = self; e->_target = (NVMTLTexture *)d.colorAttachments[0].texture;
    for (NSUInteger ci = 0; ci < 8; ci++) { id<MTLTexture> at = d.colorAttachments[ci].texture; if (at) nvmtl_histcb((NVMTLTexture *)at, 'R', self); }
    if (d.depthAttachment.texture) nvmtl_histcb((NVMTLTexture *)d.depthAttachment.texture, 'R', self);
    if (!_resources) _resources = [NVMTLResSet new];
    if (e->_target) [_resources addObject:e->_target];
    if (d.depthAttachment.texture) [_resources addObject:d.depthAttachment.texture];
    { MTLStoreAction sa = d.colorAttachments[0].storeAction;
      if ((sa == MTLStoreActionMultisampleResolve || sa == MTLStoreActionStoreAndMultisampleResolve || sa == MTLStoreActionUnknown) && d.colorAttachments[0].resolveTexture) {
          e->_resolve = (NVMTLTexture *)d.colorAttachments[0].resolveTexture; [_resources addObject:e->_resolve]; } }
    if (d.visibilityResultBuffer) [_resources addObject:d.visibilityResultBuffer];
    if (nvmtl_shm_on()) {   // render targets on adopted Shared buffers (see nvmtl_shm_texture_bound)
        for (NSUInteger ci = 0; ci < 8; ci++) { NVMTLTexture *at = (NVMTLTexture *)d.colorAttachments[ci].texture; if ([at isKindOfClass:[NVMTLTexture class]]) nvmtl_shm_texture_bound(self, at); }
        NVMTLTexture *dt = (NVMTLTexture *)d.depthAttachment.texture; if ([dt isKindOfClass:[NVMTLTexture class]]) nvmtl_shm_texture_bound(self, dt);
    }
    if (e->_target) { NVMTLTexture *sr = e->_target->_parent ? e->_target->_parent : e->_target;
        nvmtl_census("render target", [sr nvi]->w, [sr nvi]->h, sr->_surf != NULL);
        (void)nvtrace_scope([sr nvi]->w, [sr nvi]->h);
        nvtrace("PASS target %p(img %p heap %p+%lu mips %u fmt %lu)%s %ux%u surf %u view %d load %lu store %lu clear (%.3g %.3g %.3g %.3g) depth %d", (__bridge void *)sr, (void *)[sr nvi]->img,
            (__bridge void *)sr->_heap, (unsigned long)sr->_heapOffset, [sr nvi]->mips, (unsigned long)sr->_fmt, e->_target != sr ? " via view" : "", [sr nvi]->w, [sr nvi]->h,
            sr->_surf ? (unsigned)IOSurfaceGetID(sr->_surf) : 0u, e->_target->_parent != nil, (unsigned long)d.colorAttachments[0].loadAction,
            (unsigned long)d.colorAttachments[0].storeAction, d.colorAttachments[0].clearColor.red, d.colorAttachments[0].clearColor.green,
            d.colorAttachments[0].clearColor.blue, d.colorAttachments[0].clearColor.alpha, d.depthAttachment.texture != nil);
        if (sr->_surf) {
            if (d.colorAttachments[0].loadAction == MTLLoadActionClear) nvmtl_surface_overwrite_recorded(self, sr);
            else nvmtl_surface_in_for_cb(self, sr);
            nvmtl_surf_dirty(self, sr); } }
    const float defaultBlend[4] = { 0, 0, 0, 0 };
    nvmtl_vk_cmd_set_blend_color(&_c, defaultBlend);
    nvmtl_vk_cmd_set_line_width(&_c, 1.0f);
    (void)nvmtl_vk_cmd_set_polygon_mode(&_c, 0);
    // Metal encoder state starts fresh even when the command buffer also contains an earlier GL render pass.
    _c.restart_off = 0;
    nvmtl_vk_cmd_set_depth_bias(&_c, 0.0f, 0.0f, 0.0f);
    nvmtl_vk_cmd_set_provoking_last(&_c, 0);
    (void)nvmtl_vk_cmd_set_depth_clip(&_c, 1);
    e->_visBuf = (NVMTLBuffer *)d.visibilityResultBuffer;
    MTLClearColor cc = d.colorAttachments[0].clearColor;
    BOOL ca8 = d.colorAttachments[0].texture && d.colorAttachments[0].texture.pixelFormat == MTLPixelFormatA8Unorm;   // alpha lives in the red lane
    e->_clear[0] = ca8 ? (float)cc.alpha : (float)cc.red; e->_clear[1] = (float)cc.green; e->_clear[2] = (float)cc.blue; e->_clear[3] = (float)cc.alpha;
    if (![e nvmtlBuildPass:d]) e->_refused = YES;
    return e;
}
- (void)nvmtlRecordDrawable:(id<MTLDrawable>)drawable presentation:(dispatch_block_t)action {
    if (!drawable || _committed) return;
    {
        static int off = -1;
        if (off < 0) { const char *e = getenv("NVMTL_NO_FPS"); off = NVMTL_RELEASE ? 1 : (e && *e && *e != '0') ? 1 : 0; }
        if (!off) {
            static _Atomic uint64_t frames, t0, lastn, lastwns, lastwaits, lastbusy;
            const uint64_t n = atomic_fetch_add(&frames, 1) + 1;
            const uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
            uint64_t t = atomic_load(&t0);
            if (!t) atomic_store(&t0, now);
            else if (now - t >= 2000000000ull) {
                uint64_t wns = 0, waits = 0;
                nvmtl_vk_submit_wait_stats(&wns, &waits);
                const uint64_t dn = n - atomic_load(&lastn);
                const uint64_t dwns = wns - atomic_load(&lastwns);
                const uint64_t dwaits = waits - atomic_load(&lastwaits);
                const double secs = (double)(now - t) / 1e9;
                const uint64_t busy = nvmtl_vk_gpu_busy_ns(), dbusy = busy - atomic_load(&lastbusy); atomic_store(&lastbusy, busy);
                nvlog("fps: %.2f over %.1f s (%llu frames, %llu total); GPU busy %.1f%% of wall (%.1f ms per frame); CPU blocked on the GPU %.1f%% of wall "
                      "across %llu submits (%.2f ms each, %.1f submits per frame)",
                      (double)dn / secs, secs, (unsigned long long)dn, (unsigned long long)n, 100.0 * (double)dbusy / (double)(now - t), dn ? (double)dbusy / dn / 1e6 : 0.0,
                      100.0 * (double)dwns / (double)(now - t), (unsigned long long)dwaits,
                      dwaits ? (double)dwns / (double)dwaits / 1e6 : 0.0,
                      dn ? (double)dwaits / (double)dn : 0.0);
                {
                    static FILE *ff; static long fbytes;
                    if (!ff) { char fp[512]; const char *td = getenv("TMPDIR"); snprintf(fp, sizeof fp, "%s/nvmtl-fps-%d.log", td && *td ? td : "/tmp", (int)getpid()); ff = fopen(fp, "a"); }
                    if (ff && fbytes < (1 << 20)) {
                        time_t tt = time(NULL); struct tm lt; localtime_r(&tt, &lt);
                        fbytes += fprintf(ff, "%02d:%02d:%02d fps %.2f frames %llu gpuwait %.1f%% submits/frame %.1f gpubusy %.1f%%\n", lt.tm_hour, lt.tm_min, lt.tm_sec,
                                          (double)dn / secs, (unsigned long long)dn, 100.0 * (double)dwns / (double)(now - t), dn ? (double)dwaits / (double)dn : 0.0,
                                          100.0 * (double)dbusy / (double)(now - t));
                        fflush(ff);
                    }
                }
                atomic_store(&t0, now); atomic_store(&lastn, n);
                atomic_store(&lastwns, wns); atomic_store(&lastwaits, waits);
            }
        }
    }
    if ([drawable respondsToSelector:@selector(texture)]) {
        _present = (NVMTLTexture *)[(id<CAMetalDrawable>)drawable texture];
        nvmtl_surf_dirty(self, _present);
        // /tmp/nvmtl-shot-request: the next presented drawable is copied, in this command buffer, into a host buffer and
        // written to ~/Library/Logs/nvmtl/shot-<pid>-<n>.raw (header: magic, w, h, row bytes, VkFormat, then rows) once
        // the command buffer completes - the frame as presented (diagnostic)
        // the request file may hold a count: that many consecutive presented frames (flicker hunting)
        static uint64_t shotNext; static _Atomic int shotLeft; const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (now >= shotNext && atomic_load(&shotLeft) <= 0) { shotNext = now + 200000000ull;
            if (access("/tmp/nvmtl-shot-request", F_OK) == 0) { int cnt = 1; FILE *rf = fopen("/tmp/nvmtl-shot-request", "r");
                if (rf) { if (fscanf(rf, "%d", &cnt) != 1 || cnt < 1 || cnt > 64) cnt = 1; fclose(rf); }
                unlink("/tmp/nvmtl-shot-request"); atomic_store(&shotLeft, cnt); } }
        if (atomic_load(&shotLeft) > 0) {
            if (atomic_fetch_sub(&shotLeft, 1) > 0) {
                NVMTLTexture *t = _present->_parent ? _present->_parent : _present; nvk_image *im = [t nvi];
                nvk_buffer *b = im && im->bpp && im->bpp <= 8 && im->samples <= 1 ? calloc(1, sizeof *b) : NULL;
                if (b && !nvmtl_vk_buffer_create((size_t)im->w * im->h * im->bpp, 1, b) && b->map &&
                    !nvmtl_vk_cmd_copy_image_to_buffer_layer(&_c, im, 0, 0, im->w, im->h, b, 0, im->w * im->bpp, 0)) {
                    const uint32_t w = im->w, h = im->h, bpp = im->bpp, fmt = im->fmt; NVMTLTexture *keep = t; static _Atomic unsigned shots;
                    [self addCompletedHandler:^(id<MTLCommandBuffer> done) { (void)done; (void)keep;
                        char path[512]; snprintf(path, sizeof path, "%s/Library/Logs/nvmtl/shot-%d-%u.raw", getenv("HOME") ?: "/tmp", (int)getpid(), atomic_fetch_add(&shots, 1));
                        FILE *f = fopen(path, "wb");
                        if (f) { const uint32_t hdr[5] = { 0x544f4853u, w, h, w * bpp, fmt }; fwrite(hdr, sizeof hdr, 1, f); fwrite(b->map, (size_t)w * h * bpp, 1, f); fclose(f);
                                 nvlog_diag("shot: %ux%u fmt %u -> %s", w, h, fmt, path); }
                        nvmtl_vk_buffer_destroy(b); free(b); }];
                } else if (b) { nvmtl_vk_buffer_destroy(b); free(b); }
            } }
    }
    if (!_presentations) _presentations = [NSMutableArray new];
    [_presentations addObject:[action copy]];
    _nPresent++;
    { extern _Atomic unsigned nvmtl_flick_frame; const unsigned fr = atomic_fetch_add(&nvmtl_flick_frame, 1); extern void nvmtl_fm_frame(unsigned); nvmtl_fm_frame(fr); }
}
- (void)presentDrawable:(id<MTLDrawable>)drawable {
    [self nvmtlRecordDrawable:drawable presentation:^{ [drawable present]; }];
}
- (void)presentDrawable:(id<MTLDrawable>)drawable atTime:(CFTimeInterval)t {
    [self nvmtlRecordDrawable:drawable presentation:^{ [drawable presentAtTime:t]; }];
}
- (void)presentDrawable:(id<MTLDrawable>)drawable afterMinimumDuration:(CFTimeInterval)d {
    [self nvmtlRecordDrawable:drawable presentation:^{ [drawable presentAfterMinimumDuration:d]; }];
}

- (void)pushDebugGroup:(NSString *)g { nvtrace("GROUP %s", g.UTF8String ?: "?"); }
- (void)popDebugGroup {}
- (void)encodeSignalEvent:(id<MTLEvent>)e value:(uint64_t)v { [self nvmtlRecordSignal:e value:v]; }
- (void)encodeWaitForEvent:(id<MTLEvent>)e value:(uint64_t)v { [self nvmtlRecordWait:e value:v]; }
// The display-pipe swap follows this call immediately in WindowServer. NVAccel
// cannot order that swap after an NVK fence, so wait for the pixels to finish
// before allowing the surface to become scanout. Other applications keep the
// normal submission-only contract.
- (BOOL)commitAndWaitUntilSubmitted {
    static int ws = -1;
    if (ws < 0) ws = (getprogname() && !strcmp(getprogname(), "WindowServer")) ? 1 : 0;
    [self commit];
    // nvmtl_ws_kernel_waits: the swap waits for this composite in NVAccel instead (nvmtl_ws_mark_pending at commit)
    if (ws && !nvmtl_ws_kernel_waits()) [self waitUntilCompleted]; else [self waitUntilScheduled];
    return self.status != MTLCommandBufferStatusError;
}

_Atomic uint64_t nvmtl_sync_use[9];
typedef struct { __unsafe_unretained NVMTLBuffer *b; uint32_t off, len; uint64_t h, q[4]; uint8_t head[16]; } nvmtl_lw_t;
static _Atomic uint64_t gLwRanges, gLwChanged, gLwChangedCpu, gLwChangedCpuSure, gLwChangedWait, gLwCbs, gLwCbsHit, gLwLogged;
static int nvmtl_lw_on(void)
{
    static int v = -1;
    if (v < 0) { const char *e = getenv("NVMTL_LATEWRITE"); v = !(e && e[0] == '0');
        nvlog("late-write check: %s (NVMTL_LATEWRITE=%s) - every Shared buffer range bound in a command buffer is hashed at commit and again just before the GPU starts it",
              v ? "ON" : "off", e ? e : "unset"); }
    return v;
}
static uint64_t nvmtl_lw_hash(const uint8_t *p, uint32_t n)
{
    uint64_t h = 1469598103934665603ull;
    for (uint32_t k = 0; k < n; k++) { h ^= p[k]; h *= 1099511628211ull; }
    return h;
}
void nvmtl_lw_note(NVMTLCommandBuffer *cb, NVMTLBuffer *nb, NSUInteger off)
{
    if (!cb || !nb || cb->_committed || !nvmtl_lw_on() || nb->_storage != MTLStorageModeShared || !nb->_b.map || off >= nb->_b.size) return;
    if (!cb->_lw) cb->_lw = [NSMutableData new];
    const NSUInteger n = cb->_lw.length / sizeof(nvmtl_lw_t);
    if (n >= 8192) return;
    if (n) { const nvmtl_lw_t *last = (const nvmtl_lw_t *)cb->_lw.bytes + n - 1; if (last->b == nb && last->off == off) return; }
    const size_t room = nb->_b.size - off;
    nvmtl_lw_t e; memset(&e, 0, sizeof e); e.b = nb; e.off = (uint32_t)off; e.len = (uint32_t)(room < 32 ? room : 32);
    [cb->_lw appendBytes:&e length:sizeof e];
}
void nvmtl_lw_commit(NVMTLCommandBuffer *cb)
{
    if (!cb || !cb->_lw) return;
    nvmtl_lw_t *e = (nvmtl_lw_t *)cb->_lw.mutableBytes; const NSUInteger n = cb->_lw.length / sizeof *e;
    for (NSUInteger k = 0; k < n; k++) {
        const uint8_t *p = (const uint8_t *)e[k].b->_b.map + e[k].off;
        e[k].h = nvmtl_lw_hash(p, e[k].len); memcpy(e[k].head, p, e[k].len < 16 ? e[k].len : 16);
        for (uint32_t q = 0; q < 4; q++) { const uint32_t a = q * 8; e[k].q[q] = a < e[k].len ? nvmtl_lw_hash(p + a, e[k].len - a < 8 ? e[k].len - a : 8) : 0; }
    }
    cb->_lwCommitNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}
static int nvmtl_shcensus_on(void)
{
    static int v = -1;
    if (v < 0) { const char *e = getenv("NVMTL_SHARED_CENSUS"); v = e && e[0] == '1';
        nvlog("shared census: %s (NVMTL_SHARED_CENSUS=%s) - every second, the Shared buffers completed command buffers used, by size", v ? "ON" : "off", e ? e : "unset"); }
    return v;
}
static NSArray *g_shbig;
static os_unfair_lock g_shbig_lk = OS_UNFAIR_LOCK_INIT;
static uint64_t nvmtl_page_hash(const uint64_t *p, size_t n)
{
    uint64_t h = 0x9e3779b97f4a7c15ull;
    for (size_t k = 0; k < n; k++) { h ^= p[k]; h *= 0xff51afd7ed558ccdull; h ^= h >> 29; }
    return h;
}
static void nvmtl_shpages_scan(NSArray *bufs, NSMutableData *out)
{
    out.length = 0;
    for (NVMTLBuffer *b in bufs) {
        const size_t sz = b->_b.size & ~(size_t)16383;
        const uint64_t *base = (const uint64_t *)b->_b.map;
        if (!base) continue;
        for (size_t off = 0; off < sz; off += 16384) { const uint64_t h = nvmtl_page_hash(base + off / 8, 2048); [out appendBytes:&h length:8]; }
    }
}
static unsigned long long nvmtl_shpages_diff(NSData *a, NSData *b)
{
    const size_t n = MIN(a.length, b.length) / 8; const uint64_t *x = a.bytes, *y = b.bytes; unsigned long long d = 0;
    for (size_t k = 0; k < n; k++) d += x[k] != y[k];
    return d;
}
#include <signal.h>
#include <sys/mman.h>
enum { NVMTL_SHW_MAX = 16 };
typedef struct { uintptr_t base; size_t len; volatile uint8_t *dirty; volatile uint8_t *read; } nvmtl_shw_range;
static nvmtl_shw_range g_shw[NVMTL_SHW_MAX];
static volatile int g_shw_n;
static struct sigaction g_shw_old_bus, g_shw_old_segv;
static _Atomic unsigned long long g_shw_faults;
static struct sigaction g_shw_orig_bus, g_shw_orig_segv;   // what was installed before our first handler
static int g_shw_installed;
static void nvmtl_shw_handler(int sig, siginfo_t *si, void *uc);
static inline void (*nvmtl_shw_forward_target(void))(int, siginfo_t *, void *) { return nvmtl_shw_handler; }
static void nvmtl_shw_forward(int sig, siginfo_t *si, void *uc)
{
    // the handler we chain to may itself chain back to ours (it was installed after us and we took the signal back,
    // nvmtl_shw_reclaim): the same fault coming round again goes to what was there before us
    static __thread uintptr_t fwd_addr; static __thread int fwd_in;
    const uintptr_t a = (uintptr_t)si->si_addr;
    const int again = fwd_in && fwd_addr == a;
    struct sigaction *o = again ? (sig == SIGBUS ? &g_shw_orig_bus : &g_shw_orig_segv) : (sig == SIGBUS ? &g_shw_old_bus : &g_shw_old_segv);
    fwd_in = 1; fwd_addr = a;
    if (o->sa_flags & SA_SIGINFO) { if (o->sa_sigaction && o->sa_sigaction != nvmtl_shw_forward_target()) { o->sa_sigaction(sig, si, uc); fwd_in = 0; return; } }
    else if (o->sa_handler != SIG_DFL && o->sa_handler != SIG_IGN) { o->sa_handler(sig); fwd_in = 0; return; }
    fwd_in = 0;
    signal(sig, SIG_DFL); raise(sig);
}
typedef struct { uintptr_t base; size_t len; uint64_t va, shadow; volatile uint8_t *dirty; uint8_t *snap; int first; } nvmtl_twin_t;
enum { NVMTL_TWIN_MAX = 8 };
static nvmtl_twin_t g_twin[NVMTL_TWIN_MAX];
static volatile int g_twin_n;
static _Atomic unsigned long long g_twin_faults, g_twin_bytes, g_twin_flushes, g_twin_runs;
int nvmtl_shm_fault(uintptr_t a); void nvmtl_shm_prologue(void); int nvmtl_shm_on(void);
static void nvmtl_shw_handler(int sig, siginfo_t *si, void *uc)
{
    const uintptr_t a = (uintptr_t)si->si_addr;
    if (nvmtl_shm_fault(a)) return;   // a CPU write to shmirror memory (nvmtl_shm.c)
    const int tn = g_twin_n;
    for (int i = 0; i < tn; i++) {
        if (a >= g_twin[i].base && a < g_twin[i].base + g_twin[i].len) {
            const size_t pg = (a - g_twin[i].base) >> 14;
            g_twin[i].dirty[pg] = 1;
            mprotect((void *)(g_twin[i].base + (pg << 14)), 16384, PROT_READ | PROT_WRITE);
            atomic_fetch_add(&g_twin_faults, 1);
            return;
        }
    }
    const int n = g_shw_n;
    for (int i = 0; i < n; i++) {
        if (a >= g_shw[i].base && a < g_shw[i].base + g_shw[i].len) {
            const size_t pg = (a - g_shw[i].base) >> 14;
#if defined(__arm64__)
            const int wnr = uc ? (int)((((ucontext_t *)uc)->uc_mcontext->__es.__esr >> 6) & 1) : 1;
#else
            const int wnr = 1;
#endif
            if (!wnr && g_shw[i].read) { g_shw[i].read[pg] = 1; mprotect((void *)(g_shw[i].base + (pg << 14)), 16384, PROT_READ); atomic_fetch_add(&g_shw_faults, 1); return; }
            g_shw[i].dirty[pg] = 1;
            mprotect((void *)(g_shw[i].base + (pg << 14)), 16384, PROT_READ | PROT_WRITE);
            atomic_fetch_add(&g_shw_faults, 1);
            return;
        }
    }
    nvmtl_shw_forward(sig, si, uc);
}
static int nvmtl_shwatch_on(void)
{
    static int v = -1;
    if (v < 0) { const char *e = getenv("NVMTL_SHWATCH"); v = e && e[0] == '1';
        if (v) nvlog("shwatch: ON - large Shared buffers are write-protected for 1 s windows; CPU writes are counted by fault, GPU writes by page hash"); }
    return v;
}
static int nvmtl_twin_on(void)
{
    static int v = -1;
    if (v < 0) { const char *e = getenv("NVMTL_TWIN"); v = e ? atoi(e) : 0; if (v < 0 || v > 2) v = 0;
        if (v) nvlog("twin: ON (NVMTL_TWIN=1, experiment) - Shared buffers >= 16 MB the GPU uses get a VRAM copy behind their GPU address; CPU-written pages are copied in before each submission, GPU writes are NOT copied back"); }
    return v;
}
static void nvmtl_shw_install(void)
{
    static int installed;
    if (!installed) {
        struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_sigaction = nvmtl_shw_handler; sa.sa_flags = SA_SIGINFO | SA_NODEFER; sigemptyset(&sa.sa_mask);
        sigaction(SIGBUS, &sa, &g_shw_old_bus); sigaction(SIGSEGV, &sa, &g_shw_old_segv); installed = 1;
        g_shw_orig_bus = g_shw_old_bus; g_shw_orig_segv = g_shw_old_segv; g_shw_installed = 1;
        nvlog("shwatch: handlers installed (previous SIGBUS handler %s, SIGSEGV %s)",
              (g_shw_old_bus.sa_flags & SA_SIGINFO) ? (g_shw_old_bus.sa_sigaction ? "siginfo" : "none") : (g_shw_old_bus.sa_handler == SIG_DFL ? "default" : "plain"),
              (g_shw_old_segv.sa_flags & SA_SIGINFO) ? (g_shw_old_segv.sa_sigaction ? "siginfo" : "none") : (g_shw_old_segv.sa_handler == SIG_DFL ? "default" : "plain"));
    }
}
// An app (an engine's crash handler, a managed runtime) may install its own SIGBUS/SIGSEGV handler after ours: then
// shmirror's write faults would reach it first and look like crashes. Before each submission (at most every 100 ms)
// ours is put back in front, chaining to theirs.
void nvmtl_shw_reclaim(void)
{
    if (!g_shw_installed) return;
    static _Atomic uint64_t next; static _Atomic unsigned long long taken;
    const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now < atomic_load(&next)) return;
    atomic_store(&next, now + 100000000ull);
    const int sigs[2] = { SIGBUS, SIGSEGV };
    for (int k = 0; k < 2; k++) {
        struct sigaction cur; if (sigaction(sigs[k], NULL, &cur)) continue;
        if ((cur.sa_flags & SA_SIGINFO) && cur.sa_sigaction == nvmtl_shw_handler) continue;
        struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_sigaction = nvmtl_shw_handler; sa.sa_flags = SA_SIGINFO | SA_NODEFER; sigemptyset(&sa.sa_mask);
        sigaction(sigs[k], &sa, k ? &g_shw_old_segv : &g_shw_old_bus);
        const unsigned long long t = atomic_fetch_add(&taken, 1) + 1;
        if (t <= 8 || !(t & (t - 1))) nvlog("shwatch: %s handler was replaced by the app - ours put back in front, chaining to the app's (%llu times)", k ? "SIGSEGV" : "SIGBUS", t);
    }
}
static void nvmtl_twin_consider(NSArray *bufs)
{
    static NSMutableArray *keep; static NSHashTable *tried;
    if (!keep) { keep = [NSMutableArray new]; tried = [NSHashTable hashTableWithOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality]; }
    for (NVMTLBuffer *b in bufs) {
        if (g_twin_n >= NVMTL_TWIN_MAX || [tried containsObject:b]) continue;
        [tried addObject:b];
        if (b->_b.size < (16u << 20) || !b->_b.map || ((uintptr_t)b->_b.map & 16383)) continue;
        NVMTLHeap *hp = b->_subHeap ? b->_subHeap : b->_heap;
        nvlog("twin: candidate %zu bytes mem %p placed %d pool %p heap %p (%zu bytes, map %p) moff %zu", b->_b.size, b->_b.mem, b->_b.placed,
              b->_b.pool, (__bridge void *)hp, hp ? hp->_hm.size : 0, hp ? hp->_hm.map : NULL, b->_b.moff);
        uint64_t va = 0, shadow = 0; uintptr_t base = 0; size_t len = 0; id owner = nil;
        if (hp && b->_b.placed) {
            BOOL dup = NO; for (int k = 0; k < g_twin_n; k++) if (g_twin[k].base == (uintptr_t)hp->_hm.map) dup = YES;
            if (dup || !hp->_hm.map || ((uintptr_t)hp->_hm.map & 16383) || nvmtl_vk_heap_twin(&hp->_hm, &va, &shadow)) continue;
            base = (uintptr_t)hp->_hm.map; len = hp->_hm.size & ~(size_t)16383; owner = hp;
        } else {
            if (nvmtl_vk_buffer_twin(&b->_b, &va, &shadow)) continue;
            base = (uintptr_t)b->_b.map; len = b->_b.size & ~(size_t)16383; owner = b;
        }
        nvmtl_shw_install();
        uint8_t *d = malloc(len >> 14); memset(d, 1, len >> 14);
        uint8_t *snap = nvmtl_twin_on() == 2 ? malloc(len) : NULL;
        const int i = g_twin_n;
        g_twin[i] = (nvmtl_twin_t){ base, len, va, shadow, d, snap, 1 };
        [keep addObject:owner];
        __atomic_store_n(&g_twin_n, i + 1, __ATOMIC_RELEASE);
        nvmtl_pre_submit_hook = nvmtl_presubmit;
    }
}
void nvmtl_twin_flush(void)
{
    const int n = g_twin_n;
    if (!n || !nvmtl_vk_pre_open()) return;
    unsigned long long bytes = 0;
    for (int i = 0; i < n; i++) {
        volatile uint8_t *d = g_twin[i].dirty; const size_t pages = g_twin[i].len >> 14;
        size_t k = 0;
        while (k < pages) {
            if (!__atomic_exchange_n(&d[k], 0, __ATOMIC_ACQ_REL)) { k++; continue; }
            size_t e = k + 1;
            while (e < pages && __atomic_exchange_n(&d[e], 0, __ATOMIC_ACQ_REL)) e++;
            mprotect((void *)(g_twin[i].base + (k << 14)), (e - k) << 14, PROT_READ);
            const uint64_t off = (uint64_t)k << 14, sz = (uint64_t)(e - k) << 14;
            uint8_t *snap = g_twin[i].snap;
            if (!snap || g_twin[i].first) {
                if (nvmtl_vk_pre_copy_va(g_twin[i].shadow + off, g_twin[i].va + off, sz) == 0) bytes += sz;
                if (snap) memcpy(snap + off, (const void *)(g_twin[i].base + off), sz);
            } else {
                const uint8_t *cur = (const uint8_t *)(g_twin[i].base + off); uint8_t *old = snap + off;
                size_t c = 0; const size_t chunks = sz / 16;
                while (c < chunks) {
                    if (!memcmp(cur + c * 16, old + c * 16, 16)) { c++; continue; }
                    size_t ce = c + 1;
                    while (ce < chunks && memcmp(cur + ce * 16, old + ce * 16, 16)) ce++;
                    const uint64_t ro = (uint64_t)c * 16, rl = (uint64_t)(ce - c) * 16;
                    memcpy(old + ro, cur + ro, rl);
                    if (nvmtl_vk_pre_copy_va(g_twin[i].shadow + off + ro, g_twin[i].va + off + ro, rl) == 0) { bytes += rl; atomic_fetch_add(&g_twin_runs, 1); }
                    c = ce;
                }
            }
            k = e;
        }
    }
    for (int i = 0; i < n; i++) g_twin[i].first = 0;
    atomic_fetch_add(&g_twin_bytes, bytes);
    const unsigned long long f = atomic_fetch_add(&g_twin_flushes, 1) + 1;
    if (!(f & (f - 1)) || f % 8192 == 0)
        nvlog_diag("twin: %llu submissions, %llu MB copied into VRAM copies (%llu diff runs), %llu CPU write faults (%d buffers)", f,
                   atomic_load(&g_twin_bytes) >> 20, atomic_load(&g_twin_runs), atomic_load(&g_twin_faults), n);
}
static void nvmtl_shwatch_window(NSArray *bufs)
{
    nvmtl_shw_install();
    NSMutableArray *use = [NSMutableArray new];
    for (NVMTLBuffer *b in bufs) if (b->_b.map && !((uintptr_t)b->_b.map & 16383) && b->_b.size >= 16384 && use.count < NVMTL_SHW_MAX) [use addObject:b];
    if (!use.count) return;
    NSMutableArray *h0 = [NSMutableArray new];
    for (NVMTLBuffer *b in use) { NSMutableData *h = [NSMutableData new]; nvmtl_shpages_scan(@[b], h); [h0 addObject:h]; }
    uint8_t *maps[NVMTL_SHW_MAX] = {0}, *rmaps[NVMTL_SHW_MAX] = {0};
    int n = 0;
    for (NVMTLBuffer *b in use) {
        const size_t len = b->_b.size & ~(size_t)16383; maps[n] = calloc(len >> 14, 1); rmaps[n] = calloc(len >> 14, 1);
        g_shw[n].base = (uintptr_t)b->_b.map; g_shw[n].len = len; g_shw[n].dirty = maps[n]; g_shw[n].read = rmaps[n]; n++;
    }
    __atomic_store_n(&g_shw_n, n, __ATOMIC_RELEASE);
    int prot_ok = 0;
    for (int i = 0; i < n; i++) prot_ok += mprotect((void *)g_shw[i].base, g_shw[i].len, PROT_NONE) == 0;
    const unsigned long long f0 = atomic_load(&g_shw_faults);
    usleep(1000000);
    for (int i = 0; i < n; i++) mprotect((void *)g_shw[i].base, g_shw[i].len, PROT_READ | PROT_WRITE);
    __atomic_store_n(&g_shw_n, 0, __ATOMIC_RELEASE);
    char line[700]; size_t w = 0;
    for (int i = 0; i < n; i++) {
        NSMutableData *h1 = [NSMutableData new]; nvmtl_shpages_scan(@[use[i]], h1);
        const uint64_t *a = ((NSData *)h0[i]).bytes, *b = h1.bytes; const size_t pages = MIN(((NSData *)h0[i]).length, h1.length) / 8;
        unsigned long long cpu = 0, changed = 0, gpuOnly = 0, cpuChanged = 0;
        for (size_t k = 0; k < pages; k++) { const int c = a[k] != b[k], d = maps[i][k]; cpu += d; changed += c; gpuOnly += c && !d; cpuChanged += c && d; }
        { static NSMapTable *uni; if (!uni) uni = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality valueOptions:NSPointerFunctionsStrongMemory];
          NSMutableData *u = [uni objectForKey:use[i]]; if (!u) { u = [NSMutableData dataWithLength:pages]; [uni setObject:u forKey:use[i]]; }
          uint8_t *ub = u.mutableBytes; unsigned long long un = 0, runs = 0, newp = 0;
          unsigned long long rd = 0, rdOnly = 0, rdGpu = 0;
          for (size_t k = 0; k < pages && k < u.length; k++) { const int g = a[k] != b[k] && !maps[i][k]; if (g && !ub[k]) { ub[k] = 1; newp++; } un += ub[k];
              rd += rmaps[i][k]; rdOnly += rmaps[i][k] && !maps[i][k]; rdGpu += rmaps[i][k] && ub[k]; }
          nvlog_diag("shwatch cpu reads %zuMB: %llu pages read by the CPU (%llu read without being written), %llu of them in GPU-written pages (union)",
                     ((NVMTLBuffer *)use[i])->_b.size >> 20, rd, rdOnly, rdGpu);
          char rl[400]; size_t rw = 0; for (size_t k = 0; k < u.length; ) { if (!ub[k]) { k++; continue; } size_t e = k; while (e < u.length && ub[e]) e++; runs++;
              if (rw < sizeof rl - 40) { int q = snprintf(rl + rw, sizeof rl - rw, " %zu+%zu", k, e - k); if (q > 0) rw += (size_t)q; } k = e; }
          rl[rw < sizeof rl ? rw : sizeof rl - 1] = 0;
          nvlog_diag("shwatch gpu pages %zuMB (heap offset %zu): union %llu pages in %llu runs, %llu new this window; runs (page+count):%s",
                     ((NVMTLBuffer *)use[i])->_b.size >> 20, ((NVMTLBuffer *)use[i])->_b.moff, un, runs, newp, rl); }
        int k2 = snprintf(line + w, sizeof line - w, " | %zuMB: cpu-written %llu pages (%llu changed), gpu-only changed %llu", ((NVMTLBuffer *)use[i])->_b.size >> 20, cpu, cpuChanged, gpuOnly);
        if (k2 > 0 && (size_t)k2 < sizeof line - w) w += (size_t)k2;
        free(maps[i]); free(rmaps[i]);
    }
    nvlog_diag("shwatch 1 s: %d buffers protected (%d mprotect ok), %llu write faults%s", n, prot_ok, atomic_load(&g_shw_faults) - f0, line);
}
// NVMTL_HEAPWATCH=1 (diagnostic): every 3 s, a 1 s window over each Shared heap of 16 MB or more - the whole mapping
// made inaccessible, so the first CPU access to a page faults: reads mark it read (then readable), writes mark it
// written (then writable). Pages hashed before and after give the GPU's changes. Counts are per frame of the window.
static struct { uintptr_t base; size_t len; } g_hw[8]; static _Atomic int g_hw_n;
static uint64_t nvmtl_hw_page_hash(const uint64_t *p) { uint64_t h = 1469598103934665603ull; for (int i = 0; i < 2048; i++) { h ^= p[i]; h *= 1099511628211ull; } return h; }
void nvmtl_heapwatch_note(void *map, size_t size)
{
    static int on = -1; if (on < 0) { const char *e = getenv("NVMTL_HEAPWATCH"); on = e && e[0] == '1'; }
    if (!on || !map || ((uintptr_t)map & 16383) || size < (16u << 20)) return;
    const int i = atomic_fetch_add(&g_hw_n, 1); if (i >= 8) return;
    g_hw[i].base = (uintptr_t)map; g_hw[i].len = size & ~(size_t)16383;
    nvlog("heapwatch: ON for a %zu MB Shared heap at %p (1 s windows every 3 s)", size >> 20, map);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            extern _Atomic unsigned nvmtl_flick_frame;
            for (;;) { @autoreleasepool {
                sleep(2);
                nvmtl_shw_install();
                const int n = MIN(atomic_load(&g_hw_n), 8);
                for (int k = 0; k < n; k++) {
                    const size_t pages = g_hw[k].len >> 14;
                    uint64_t *h0 = malloc(pages * 8), *h1 = malloc(pages * 8); uint8_t *wm = calloc(pages, 1), *rm = calloc(pages, 1);
                    for (size_t q = 0; q < pages; q++) h0[q] = nvmtl_hw_page_hash((const uint64_t *)(g_hw[k].base + (q << 14)));
                    const int sn = g_shw_n < NVMTL_SHW_MAX ? g_shw_n : NVMTL_SHW_MAX - 1;
                    g_shw[sn].base = g_hw[k].base; g_shw[sn].len = g_hw[k].len; g_shw[sn].dirty = wm; g_shw[sn].read = rm;
                    __atomic_store_n(&g_shw_n, sn + 1, __ATOMIC_RELEASE);
                    const unsigned f0 = atomic_load(&nvmtl_flick_frame); const unsigned long long x0 = atomic_load(&g_shw_faults);
                    const int pr = mprotect((void *)g_hw[k].base, g_hw[k].len, PROT_NONE);
                    usleep(1000000);
                    mprotect((void *)g_hw[k].base, g_hw[k].len, PROT_READ | PROT_WRITE);
                    __atomic_store_n(&g_shw_n, sn, __ATOMIC_RELEASE);
                    const unsigned fr = atomic_load(&nvmtl_flick_frame) - f0; const unsigned long long faults = atomic_load(&g_shw_faults) - x0;
                    for (size_t q = 0; q < pages; q++) h1[q] = nvmtl_hw_page_hash((const uint64_t *)(g_hw[k].base + (q << 14)));
                    unsigned long long w = 0, r = 0, ronly = 0, changed = 0, gpu = 0, runs = 0; size_t lo = pages, hi = 0;
                    for (size_t q = 0; q < pages; q++) {
                        w += wm[q]; r += rm[q]; ronly += rm[q] && !wm[q];
                        const int c = h0[q] != h1[q]; changed += c; gpu += c && !wm[q];
                        if (wm[q]) { if (q < lo) lo = q; if (q > hi) hi = q; if (!q || !wm[q - 1]) runs++; }
                    }
                    const double nf = fr ? fr : 1;
                    nvlog_diag("heapwatch %zu MB (mprotect %d): %u frames | CPU wrote %llu pages (%.1f/frame, %.2f MB/frame of pages) in %llu runs, span %zu-%zu | "
                               "CPU read first %llu pages (%llu never written) | changed %llu pages, %llu not CPU-written (GPU) | %llu faults (%.0f/frame)",
                               g_hw[k].len >> 20, pr, fr, w, w / nf, w * 16384.0 / 1048576.0 / nf, runs, lo == pages ? 0 : lo, hi, r, ronly, changed, gpu, faults, faults / nf);
                    free(h0); free(h1); free(wm); free(rm);
                    sleep(1);
                }
            } }
        });
    });
}
static void nvmtl_shpages_start(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSMutableData *h0 = [NSMutableData new], *h1 = [NSMutableData new], *h2 = [NSMutableData new];
            for (;;) { @autoreleasepool {
                sleep(2);
                NSArray *bufs; os_unfair_lock_lock(&g_shbig_lk); bufs = g_shbig; os_unfair_lock_unlock(&g_shbig_lk);
                if (!bufs.count) continue;
                if (nvmtl_shwatch_on()) { nvmtl_shwatch_window(bufs); continue; }
                unsigned long long bytes = 0; for (NVMTLBuffer *b in bufs) bytes += b->_b.size;
                const uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
                nvmtl_shpages_scan(bufs, h0);
                const uint64_t t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
                usleep(45000);
                nvmtl_shpages_scan(bufs, h1);
                const uint64_t t2 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
                usleep(500000);
                nvmtl_shpages_scan(bufs, h2);
                const uint64_t t3 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
                const unsigned long long pages = h0.length / 8, d1 = nvmtl_shpages_diff(h0, h1), d2 = nvmtl_shpages_diff(h0, h2);
                nvlog_diag("shared pages: %lu buffers %.1f MB, %llu pages of 16 KB; changed %llu (%.1f MB) in %.0f ms, %llu (%.1f MB) in %.0f ms; scan %.0f ms",
                      (unsigned long)bufs.count, bytes / 1048576.0, pages, d1, d1 / 64.0, (t2 - t0) / 1e6, d2, d2 / 64.0, (t3 - t0) / 1e6, (t1 - t0) / 1e6);
            } }
        });
    });
}
static void nvmtl_shcensus(NSArray *used)
{
    static os_unfair_lock lk = OS_UNFAIR_LOCK_INIT; static NSMapTable *seen; static uint64_t t0, cbs, refs;
    const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    NSArray *twinNow = nil;
    os_unfair_lock_lock(&lk);
    if (!seen) { seen = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality valueOptions:NSPointerFunctionsStrongMemory]; t0 = now; }
    cbs++;
    static NSMutableSet *bigAcc; if (!bigAcc) bigAcc = [NSMutableSet new];
    for (NVMTLBuffer *b in used) {
        refs++;
        if (b->_b.size >= (1u << 20)) [bigAcc addObject:b];
        NSMutableArray *v = [seen objectForKey:(__bridge id)(__bridge void *)b];
        if (!v) { v = [NSMutableArray arrayWithObjects:@((unsigned long long)b->_b.size), @0, b->_label ?: @"", @(b->_heap != nil || b->_subHeap), nil]; [seen setObject:v forKey:(__bridge id)(__bridge void *)b]; }
        v[1] = @([v[1] unsignedLongLongValue] + 1);
    }
    if (now - t0 >= 1000000000ull) {
        unsigned long long tot = 0, nb = 0, cls[6] = {0}, clb[6] = {0}, heap = 0;
        NSMutableArray *rows = [NSMutableArray new];
        for (id k in seen) {
            NSArray *v = [seen objectForKey:k]; const unsigned long long sz = [v[0] unsignedLongLongValue];
            tot += sz; nb++; if ([v[3] boolValue]) heap++;
            const int c = sz < 4096 ? 0 : sz < 65536 ? 1 : sz < (1u << 20) ? 2 : sz < (8u << 20) ? 3 : sz < (64u << 20) ? 4 : 5;
            cls[c]++; clb[c] += sz; [rows addObject:v];
        }
        [rows sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[0] compare:a[0]]; }];
        { os_unfair_lock_lock(&g_shbig_lk); g_shbig = bigAcc.allObjects; os_unfair_lock_unlock(&g_shbig_lk); [bigAcc removeAllObjects];
          if (nvmtl_twin_on()) twinNow = g_shbig; else nvmtl_shpages_start(); }
        NSMutableString *top = [NSMutableString new];
        for (NSUInteger i = 0; i < rows.count && i < 10; i++) [top appendFormat:@" | %lluKB x%llu%s '%@'", [rows[i][0] unsignedLongLongValue] >> 10, [rows[i][1] unsignedLongLongValue], [rows[i][3] boolValue] ? " heap" : "", rows[i][2]];
        const char *topc = top.UTF8String;
        nvlog_diag("shared census %.1f s: %llu command buffers, %llu buffer uses, %llu distinct Shared buffers %.1f MB (%llu heap/sub-heap) | <4K %llu %.2fMB, <64K %llu %.2fMB, <1M %llu %.2fMB, <8M %llu %.2fMB, <64M %llu %.2fMB, >=64M %llu %.2fMB | largest:%s",
              (double)(now - t0) / 1e9, cbs, refs, nb, tot / 1048576.0, heap, cls[0], clb[0] / 1048576.0, cls[1], clb[1] / 1048576.0, cls[2], clb[2] / 1048576.0,
              cls[3], clb[3] / 1048576.0, cls[4], clb[4] / 1048576.0, cls[5], clb[5] / 1048576.0, topc);
        [seen removeAllObjects]; t0 = now; cbs = refs = 0;
    }
    os_unfair_lock_unlock(&lk);
    if (twinNow.count) nvmtl_twin_consider(twinNow);
}
void nvmtl_lw_done(NVMTLCommandBuffer *cb)
{
    NVMTLResSet *rs = (NVMTLResSet *)cb->_resources;
    if (!rs || !nvmtl_lw_on()) return;
    const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    os_unfair_lock_lock(&rs->_lk);
    for (id r in rs->_s) if ([r isKindOfClass:[NVMTLBuffer class]]) atomic_store(&((NVMTLBuffer *)r)->_lwDoneNs, now);
    os_unfair_lock_unlock(&rs->_lk);
}
static void nvmtl_lw_hex(char *out, const uint8_t *p, uint32_t n) { for (uint32_t k = 0; k < n; k++) sprintf(out + 2 * k, "%02x", p[k]); out[2 * n] = 0; }
void nvmtl_lw_check(NVMTLCommandBuffer *cb, int hasWait)
{
    if (!cb || cb->_lwChecked) return;
    cb->_lwChecked = YES;
    if (!cb->_lw || !cb->_lwCommitNs) { cb->_lw = nil; return; }
    const nvmtl_lw_t *e = (const nvmtl_lw_t *)cb->_lw.bytes; const NSUInteger n = cb->_lw.length / sizeof *e;
    const uint64_t lagSeq = nvmtl_vk_seq_now() - cb->_commitSeq, lagUs = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - cb->_lwCommitNs) / 1000;
    unsigned hit = 0;
    const int prevDone = nvmtl_vk_seq_done() + 1 >= cb->_commitSeq;
    for (NSUInteger k = 0; k < n; k++) {
        if (!e[k].b->_b.map) continue;
        const uint8_t *p = (const uint8_t *)e[k].b->_b.map + e[k].off;
        if (nvmtl_lw_hash(p, e[k].len) == e[k].h) continue;
        hit++;
        const int gpu = atomic_load(&e[k].b->_lwDoneNs) > cb->_lwCommitNs;
        if (hasWait) atomic_fetch_add(&gLwChangedWait, 1);
        else if (!gpu) { atomic_fetch_add(&gLwChangedCpu, 1); if (prevDone) atomic_fetch_add(&gLwChangedCpuSure, 1); }
        char qs[8] = "----"; for (uint32_t q = 0; q < 4; q++) { const uint32_t a = q * 8;
            if (a < e[k].len && nvmtl_lw_hash(p + a, e[k].len - a < 8 ? e[k].len - a : 8) != e[k].q[q]) qs[q] = (char)('0' + q); }
        if (atomic_fetch_add(&gLwLogged, 1) < 96) {
            char was[33], now[33]; const uint32_t hn = e[k].len < 16 ? e[k].len : 16;
            nvmtl_lw_hex(was, e[k].head, hn); nvmtl_lw_hex(now, p, hn);
            if (atomic_load(&gLwLogged) <= 24) nvlog("late-write: cb seq %llu is %s", (unsigned long long)cb->_commitSeq, nvmtl_cb_describe(cb).UTF8String);
            nvlog("late-write: cb seq %llu (%llu committed since, %llu us after commit, CPU %u frames ahead of the GPU): Shared buffer %p '%s' %zu bytes gpuVA 0x%llx, range %u+%u CHANGED (8-byte quarters %s) before the GPU read it - %s; head %s -> %s",
                  (unsigned long long)cb->_commitSeq, (unsigned long long)lagSeq, (unsigned long long)lagUs, nvmtl_frames_ahead(), (__bridge void *)e[k].b,
                  e[k].b->_label.UTF8String ?: "", e[k].b->_b.size, (unsigned long long)nvmtl_vk_buffer_address(&e[k].b->_b), e[k].off, e[k].len, qs,
                  hasWait ? "LEGAL HAND-OFF? (this command buffer waits on an event, the CPU may write until it signals)" : gpu ? "GPU-POSSIBLE (a command buffer using it finished after this commit)" : prevDone ? "CPU WRITE (every earlier command buffer had finished; none using it finished since this commit)" : "CPU WRITE? (earlier command buffers still in flight)", was, now);
        }
    }
    if (nvmtl_shcensus_on()) {
        NSMutableArray *used = [NSMutableArray new]; NSHashTable *dup = [NSHashTable hashTableWithOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality];
        for (NSUInteger k = 0; k < n; k++) if (![dup containsObject:e[k].b]) { [dup addObject:e[k].b]; [used addObject:e[k].b]; }
        nvmtl_shcensus(used);
    }
    atomic_fetch_add(&gLwRanges, n); atomic_fetch_add(&gLwChanged, hit);
    const uint64_t c = atomic_fetch_add(&gLwCbs, 1) + 1; if (hit) atomic_fetch_add(&gLwCbsHit, 1);
    if (!(c & (c - 1)) && c >= 64)
        nvlog("late-write census: %llu of %llu bound Shared ranges changed between commit and the GPU start (%llu by the CPU, %llu of them certain; %llu in command buffers that wait on an event), in %llu of %llu command buffers (this one: %llu committed since, %llu us)",
              (unsigned long long)atomic_load(&gLwChanged), (unsigned long long)atomic_load(&gLwRanges), (unsigned long long)atomic_load(&gLwChangedCpu),
              (unsigned long long)atomic_load(&gLwChangedCpuSure), (unsigned long long)atomic_load(&gLwChangedWait), (unsigned long long)atomic_load(&gLwCbsHit), (unsigned long long)c,
              (unsigned long long)lagSeq, (unsigned long long)lagUs);
    if (!(c & (c - 1)) && c >= 64)
        nvlog("encoders: up to %llu open at once across threads; %llu encoders began while another was open", (unsigned long long)nvmtl_enc_census[0], (unsigned long long)nvmtl_enc_census[1]);
        nvlog("sync use: completedHandler %llu scheduledHandler %llu waitUntilCompleted %llu waitUntilScheduled %llu status %llu | event signaledValue %llu notifyListener %llu waitUntilSignaled %llu setSignaledValue %llu",
              (unsigned long long)nvmtl_sync_use[0], (unsigned long long)nvmtl_sync_use[1], (unsigned long long)nvmtl_sync_use[2], (unsigned long long)nvmtl_sync_use[3],
              (unsigned long long)nvmtl_sync_use[4], (unsigned long long)nvmtl_sync_use[5], (unsigned long long)nvmtl_sync_use[6], (unsigned long long)nvmtl_sync_use[7],
              (unsigned long long)nvmtl_sync_use[8]);
    cb->_lw = nil;
}

static _Atomic unsigned nvmtl_frames_completed, nvmtl_frames_committed;
static pthread_mutex_t g_fa_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_fa_cond = PTHREAD_COND_INITIALIZER;
static _Atomic uint64_t gFaWaits, gFaWaitUs, gFaTimeouts, gFaMax;
unsigned nvmtl_frames_ahead(void)
{
    const unsigned rec = atomic_load(&nvmtl_frames_committed), done = atomic_load(&nvmtl_frames_completed);
    return rec > done ? rec - done : 0;
}
void nvmtl_frames_done(unsigned n)
{
    if (!n) return;
    pthread_mutex_lock(&g_fa_lock); atomic_fetch_add(&nvmtl_frames_completed, n); pthread_cond_broadcast(&g_fa_cond); pthread_mutex_unlock(&g_fa_lock);
}
static int nvmtl_max_frames_ahead(void)
{
    static int v = -2;
    if (v == -2) { const char *e = getenv("NVMTL_MAX_FRAMES_AHEAD"); v = !e ? 2 : !strcmp(e, "off") ? -1 : atoi(e); if (v < -1) v = -1;
        if (v >= 0) nvlog("frame pacing: a commit that presents waits (up to 250 ms) until at most %d frame(s) are still on the GPU - Apple's drawable pool throttles the same way (NVMTL_MAX_FRAMES_AHEAD=%s; off disables)", v, e ? e : "unset");
        else nvlog("frame pacing: OFF - the CPU may run any number of frames ahead (NVMTL_MAX_FRAMES_AHEAD=off)"); }
    return v;
}
static int nvmtl_sync_abab_zero(void)
{
    static int n = -1;
    if (n < 0) { const char *e = getenv("NVMTL_SYNC_ABAB"); n = e ? atoi(e) : 0; if (n < 0) n = 0;
        if (n) nvlog_diag("frame pacing: NVMTL_SYNC_ABAB=%d - frames f with (f/%d) odd wait at present until the GPU has finished every earlier frame, even windows use the normal limit", n, n); }
    return n && ((atomic_load_explicit(&nvmtl_flick_frame, memory_order_relaxed) / (unsigned)n) & 1u);
}
static void nvmtl_frames_throttle(void)
{
    int kk = nvmtl_max_frames_ahead();
    if (nvmtl_sync_abab_zero()) kk = 0;
    if (kk < 0) return;
    const unsigned k = (unsigned)kk;
    unsigned ahead = nvmtl_frames_ahead();
    if (ahead > atomic_load(&gFaMax)) atomic_store(&gFaMax, ahead);
    if (ahead <= k) return;
    const uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    struct timespec dl; clock_gettime(CLOCK_REALTIME, &dl); dl.tv_nsec += 250000000; if (dl.tv_nsec >= 1000000000) { dl.tv_sec++; dl.tv_nsec -= 1000000000; }
    int timedOut = 0;
    pthread_mutex_lock(&g_fa_lock);
    while (nvmtl_frames_ahead() > k) if (pthread_cond_timedwait(&g_fa_cond, &g_fa_lock, &dl) == ETIMEDOUT) { timedOut = 1; break; }
    pthread_mutex_unlock(&g_fa_lock);
    const uint64_t us = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1000;
    atomic_fetch_add(&gFaWaitUs, us); if (timedOut) atomic_fetch_add(&gFaTimeouts, 1);
    const uint64_t w = atomic_fetch_add(&gFaWaits, 1) + 1;
    if (!(w & (w - 1)) && w >= 16)
        nvlog("frame pacing: %llu presenting commits waited, %llu ms in all, %llu timed out at 250 ms; the CPU was up to %llu frames ahead before pacing",
              (unsigned long long)w, (unsigned long long)(atomic_load(&gFaWaitUs) / 1000), (unsigned long long)atomic_load(&gFaTimeouts), (unsigned long long)atomic_load(&gFaMax));
}

static _Atomic uint64_t g_uv_checked, g_uv_bad, g_uv_zero, g_uv_logged;
static int nvmtl_upverify_live(void)
{
    static _Atomic uint64_t next; static _Atomic int on;
    const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now >= atomic_load(&next)) {
        atomic_store(&next, now + 500000000ull);
        struct stat st; const int v = stat("/tmp/nvmtl-upverify", &st) == 0;
        if (v != atomic_exchange(&on, v))
            nvlog("upload verify: %s (/tmp/nvmtl-upverify) - every buffer-to-texture copy is read back in the same command buffer and compared with its source", v ? "ON" : "OFF");
    }
    return atomic_load(&on);
}
static void nvmtl_upverify(NVMTLCommandBuffer *cb, NVMTLBuffer *src, size_t so, uint32_t row, NVMTLTexture *t, uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t level, uint32_t layer)
{
    nvk_image *im = [t nvi];
    if (!im || !src->_b.map || !row || !w || !h) return;
    const uint32_t bw = im->bw ? im->bw : 1, bh = im->bh ? im->bh : 1, bpp = im->bpp ? im->bpp : 4;
    const uint32_t rows = (h + bh - 1) / bh, tight = ((w + bw - 1) / bw) * bpp;
    if (tight > row || row % bpp || so + (size_t)(rows - 1) * row + tight > src->_b.size) return;
    nvk_buffer *vb = calloc(1, sizeof *vb); if (!vb) return;
    if (nvmtl_vk_buffer_create((size_t)rows * row, 1, vb) || !vb->map) { free(vb); return; }
    if (nvmtl_vk_cmd_copy_image_to_buffer_level_layer(&cb->_c, im, x, y, w, h, vb, 0, row, level, layer)) { nvmtl_vk_buffer_destroy(vb); free(vb); return; }
    NVMTLBuffer *keep = src; const uint32_t fmt = im->fmt, iw = im->w, ih = im->h, mips = im->mips; const MTLPixelFormat mfmt = t->_fmt;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (done.status != MTLCommandBufferStatusCompleted) { nvmtl_vk_buffer_destroy(vb); free(vb); return; }
        const uint8_t *a = (const uint8_t *)keep->_b.map + so, *r = (const uint8_t *)vb->map;
        int bad = 0, allzero = 1, srczero = 1; uint32_t firstRow = 0;
        for (uint32_t k = 0; k < rows; k++) {
            if (memcmp(a + (size_t)k * row, r + (size_t)k * row, tight)) { if (!bad) firstRow = k; bad = 1; }
            for (uint32_t j = 0; j < tight && allzero; j++) if (r[(size_t)k * row + j]) allzero = 0;
            for (uint32_t j = 0; j < tight && srczero; j++) if (a[(size_t)k * row + j]) srczero = 0;
        }
        const uint64_t c = atomic_fetch_add(&g_uv_checked, 1) + 1;
        if (bad) {
            atomic_fetch_add(&g_uv_bad, 1); if (allzero) atomic_fetch_add(&g_uv_zero, 1);
            if (atomic_fetch_add(&g_uv_logged, 1) < 60)
                nvlog("upload verify: MISMATCH mtl fmt %lu vk %u %ux%u mips %u -> level %u layer %u region (%u,%u %ux%u) row %u block %ux%u bpp %u src off %zu: first bad block-row %u of %u, readback %s, source %s",
                      (unsigned long)mfmt, fmt, iw, ih, mips, level, layer, x, y, w, h, row, bw, bh, bpp, so, firstRow, rows,
                      allzero ? "ALL ZERO" : "non-zero", srczero ? "all zero" : "non-zero");
        }
        if (!(c & (c - 1)) && c >= 64)
            nvlog("upload verify: %llu copies checked, %llu differ from their source (%llu read back all zero)", (unsigned long long)c,
                  (unsigned long long)atomic_load(&g_uv_bad), (unsigned long long)atomic_load(&g_uv_zero));
        nvmtl_vk_buffer_destroy(vb); free(vb);
    }];
}
static _Atomic uint64_t g_tv_checked, g_tv_bad, g_tv_dzero, g_tv_szero, g_tv_logged;
static int nvmtl_texverify_live(void)
{
    static _Atomic uint64_t next; static _Atomic int on;
    const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now >= atomic_load(&next)) {
        atomic_store(&next, now + 500000000ull);
        struct stat st; const int v = stat("/tmp/nvmtl-texverify", &st) == 0;
        if (v != atomic_exchange(&on, v))
            nvlog("texture copy verify: %s at frame %u (/tmp/nvmtl-texverify) - every texture-to-texture copy reads back its source and destination regions in the same command buffer and compares them",
                  v ? "ON" : "OFF", atomic_load(&nvmtl_flick_frame));
    }
    return atomic_load(&on);
}
static void nvmtl_texverify(NVMTLCommandBuffer *cb, NVMTLTexture *s, uint32_t sl, uint32_t ss, uint32_t sx, uint32_t sy, NVMTLTexture *d, uint32_t dl, uint32_t ds, uint32_t dx, uint32_t dy, uint32_t w, uint32_t h)
{
    nvk_image *si = [s nvi], *di = [d nvi];
    if (!si || !di || !w || !h || si->bpp != di->bpp) return;
    const uint32_t bw = si->bw ? si->bw : 1, bh = si->bh ? si->bh : 1, bpp = si->bpp ? si->bpp : 4;
    const uint32_t rows = (h + bh - 1) / bh, row = ((w + bw - 1) / bw) * bpp;
    nvk_buffer *sb = calloc(1, sizeof *sb), *db = calloc(1, sizeof *db);
    if (!sb || !db) { free(sb); free(db); return; }
    if (nvmtl_vk_buffer_create((size_t)rows * row, 1, sb) || !sb->map || nvmtl_vk_buffer_create((size_t)rows * row, 1, db) || !db->map) {
        if (sb->buf) nvmtl_vk_buffer_destroy(sb); if (db->buf) nvmtl_vk_buffer_destroy(db); free(sb); free(db); return; }
    if (nvmtl_vk_cmd_copy_image_to_buffer_level_layer(&cb->_c, si, sx, sy, w, h, sb, 0, row, sl, ss) ||
        nvmtl_vk_cmd_copy_image_to_buffer_level_layer(&cb->_c, di, dx, dy, w, h, db, 0, row, dl, ds)) {
        nvmtl_vk_buffer_destroy(sb); nvmtl_vk_buffer_destroy(db); free(sb); free(db); return; }
    const uint32_t sfmt = si->fmt, siw = si->w, sih = si->h, smips = si->mips, diw = di->w, dih = di->h, dmips = di->mips;
    const MTLPixelFormat mfmt = d->_fmt; const unsigned frame = atomic_load(&nvmtl_flick_frame);
    const int sameImg = si == di, srcSurf = s->_surf != NULL, dstSurf = d->_surf != NULL;
    NVMTLTexture *sroot = s->_parent ? s->_parent : s, *droot = d->_parent ? d->_parent : d;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (done.status != MTLCommandBufferStatusCompleted) { nvmtl_vk_buffer_destroy(sb); nvmtl_vk_buffer_destroy(db); free(sb); free(db); return; }
        const uint8_t *a = (const uint8_t *)sb->map, *r = (const uint8_t *)db->map; const size_t n = (size_t)rows * row;
        const int bad = memcmp(a, r, n) != 0; int dz = 1, sz = 1;
        for (size_t k = 0; k < n && (dz || sz); k++) { if (r[k]) dz = 0; if (a[k]) sz = 0; }
        size_t firstBad = 0; if (bad) while (firstBad < n && a[firstBad] == r[firstBad]) firstBad++;
        const uint64_t c = atomic_fetch_add(&g_tv_checked, 1) + 1;
        if (sz) {
            const uint64_t zn = atomic_fetch_add(&g_tv_szero, 1) + 1;
            NVMTLTexture *sr = sroot;
            static struct { uint64_t key; uint32_t n; } sig[256]; static uint32_t nsig; static os_unfair_lock sl_ = OS_UNFAIR_LOCK_INIT;
            const uint64_t key = ((uint64_t)sr->_fmt << 48) ^ ((uint64_t)siw << 32) ^ ((uint64_t)sih << 16) ^ ((uint64_t)smips << 8) ^ ((uint64_t)(sr->_usage & 0xf) << 4)
                               ^ (sr->_hUp ? 1 : 0) ^ (sr->_hRT ? 2 : 0) ^ (sr->_hCopyIn ? 4 : 0) ^ (sr->_hMips ? 8 : 0);
            uint32_t seen = 0; os_unfair_lock_lock(&sl_);
            { uint32_t k = 0; for (; k < nsig; k++) if (sig[k].key == key) break;
              if (k == nsig && nsig < 256) { sig[nsig].key = key; sig[nsig].n = 0; nsig++; }
              if (k < 256) seen = ++sig[k].n; }
            os_unfair_lock_unlock(&sl_);
            if (seen <= 2 || (sr->_hUp && zn < 100000) || !(seen & (seen - 1)))
                nvlog("texture copy verify: ZERO SOURCE%s at frame %u: src %p '%s' mtl fmt %lu %ux%u mips %u usage 0x%lx heap %p+%lu%s L%u S%u (%u,%u %ux%u) -> dst %p %ux%u mips %u L%u (%u,%u) | src history: uploads %u copies-in %u render-target %u genmips %u replaceRegion %u, last fill '%c' at frame %u [%llu zero sources, %u of this kind]",
                      sr->_hUp ? " (UPLOADED TEXTURE)" : "", frame, (__bridge void *)sr, sr->_label.UTF8String ?: "", (unsigned long)sr->_fmt, siw, sih, smips, (unsigned long)sr->_usage, (__bridge void *)sr->_heap, (unsigned long)sr->_heapOffset, sr->_aliased ? " ALIASED" : "",
                      sl, ss, sx, sy, w, h, (__bridge void *)droot, diw, dih, dmips, dl, dx, dy,
                      sr->_hUp, sr->_hCopyIn, sr->_hRT, sr->_hMips, sr->_hRepl, sr->_hLastKind ? sr->_hLastKind : '-', sr->_hLastFill, (unsigned long long)zn, seen);
        }
        if (bad) {
            atomic_fetch_add(&g_tv_bad, 1); if (dz) atomic_fetch_add(&g_tv_dzero, 1);
            if (atomic_fetch_add(&g_tv_logged, 1) < 80)
                nvlog("texture copy verify: MISMATCH at frame %u: mtl fmt %lu vk %u %ux%u mips %u L%u S%u (%u,%u) -> %ux%u mips %u L%u S%u (%u,%u) size %ux%u block %ux%u bpp %u%s%s: first differing byte %zu of %zu, destination %s, source %s",
                      frame, (unsigned long)mfmt, sfmt, siw, sih, smips, sl, ss, sx, sy, diw, dih, dmips, dl, ds, dx, dy, w, h, bw, bh, bpp,
                      sameImg ? " SAME IMAGE" : "", (srcSurf || dstSurf) ? " iosurface" : "", firstBad, n, dz ? "ALL ZERO" : "non-zero", sz ? "all zero" : "non-zero");
        }
        if (!(c & (c - 1)) && c >= 16)
            nvlog("texture copy verify: %llu copies checked, %llu differ (%llu destinations all zero), %llu copied an all-zero source region; last at frame %u",
                  (unsigned long long)c, (unsigned long long)atomic_load(&g_tv_bad), (unsigned long long)atomic_load(&g_tv_dzero), (unsigned long long)atomic_load(&g_tv_szero), frame);
        nvmtl_vk_buffer_destroy(sb); nvmtl_vk_buffer_destroy(db); free(sb); free(db);
    }];
}
#include <sys/stat.h>
static int nvmtl_serialize_live(void)
{
    static _Atomic uint64_t next; static _Atomic int on;
    const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now >= atomic_load(&next)) {
        atomic_store(&next, now + 500000000ull);
        struct stat st; const int v = stat("/tmp/nvmtl-serialize", &st) == 0;
        if (v != atomic_exchange(&on, v))
            nvlog("serialize: %s at frame %u (/tmp/nvmtl-serialize %s) - %s", v ? "ON" : "OFF", atomic_load(&nvmtl_flick_frame), v ? "exists" : "gone",
                  v ? "every commit waits up to 250 ms for its command buffer to finish, the CPU never runs ahead of the GPU" : "commits return at once again");
    }
    return atomic_load(&on);
}
- (void)commit {
    nvmtl_lastk_put('C', nil, NULL, NULL, self);
    if (!_commitSeq) _commitSeq = nvmtl_vk_commit_seq_bump();   // the graveyards reap below the oldest unfinished one
    nvmtl_h_commit(self);
    nvmtl_lw_commit(self);
    const unsigned presents = (unsigned)_presentations.count;
    if (presents) atomic_fetch_add(&nvmtl_frames_committed, presents);
    [self nvmtlSubmitWithEvents];
    if (presents) nvmtl_frames_throttle();
    if (nvmtl_serialize_live() || nvmtl_sync_abab_zero()) {
        static _Atomic unsigned long waited, gaveUp;
        NSDate *dl = [NSDate dateWithTimeIntervalSinceNow:0.25]; BOOL ok = YES;
        [_completionCondition lock];
        while (!_completionReady && (ok = [_completionCondition waitUntilDate:dl])) {}
        [_completionCondition unlock];
        const unsigned long w = atomic_fetch_add(&waited, 1) + 1, g = ok ? atomic_load(&gaveUp) : atomic_fetch_add(&gaveUp, 1) + 1;
        if (!(w & (w - 1)) && w >= 64) nvlog("serialize: %lu commits waited for their command buffers, %lu gave up after 250 ms", w, g);
    }
    // NVMTL_DEBUG_WAIT_EACH=1: every command buffer is waited for and its completion traced, so a GPU hang is pinned to
    // the command buffer (and the debug groups traced before it) that never finished. A diagnostic: it serialises the app.
    static int each = -1; if (each < 0) { const char *e = getenv("NVMTL_DEBUG_WAIT_EACH"); each = e && e[0] == '1'; }
    if (each) { static _Atomic unsigned long n; const unsigned long k = ++n; nvtrace("CB commit #%lu %s", k, _label.UTF8String ?: "");
        [self waitUntilCompleted]; nvtrace("CB done #%lu status %ld", k, (long)self.status); }
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoder {
    nvmtl_enc_begin();
    NVMTLComputeCommandEncoder *e = [NVMTLComputeCommandEncoder new]; e->_cb = self; _nEnc++; return e;
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDispatchType:(MTLDispatchType)t {
    NVMTLComputeCommandEncoder *e = (NVMTLComputeCommandEncoder *)[self computeCommandEncoder];
    e->_e78Concurrent = t == MTLDispatchTypeConcurrent; return e; }
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDescriptor:(MTLComputePassDescriptor *)d {
    return [self computeCommandEncoderWithDispatchType:d ? d.dispatchType : MTLDispatchTypeSerial]; }
- (id<MTLBlitCommandEncoder>)blitCommandEncoderWithDescriptor:(MTLBlitPassDescriptor *)d { return [self blitCommandEncoder]; }
- (id<MTLResourceStateCommandEncoder>)resourceStateCommandEncoder { return nil; }
- (id<MTLResourceStateCommandEncoder>)resourceStateCommandEncoderWithDescriptor:(MTLResourceStatePassDescriptor *)d { return nil; }
- (id<MTLBlitCommandEncoder>)blitCommandEncoder {
    nvmtl_enc_begin();
    nvmtl_g79_flush(self);
    _c.bl_ops = 0; { extern void nvmtl_vk_pt_seg_begin(nvk_cmdbuf *c, uint32_t kind); nvmtl_vk_pt_seg_begin(&_c, 9002u); }
    NVMTLBlitCommandEncoder *e = [NVMTLBlitCommandEncoder new]; e->_cb = self; e->_owner = self; _nEnc++; return e;
}
- (id<MTLAccelerationStructureCommandEncoder>)accelerationStructureCommandEncoder {
    nvmtl_enc_begin();
    nvmtl_g79_flush(self);
    NVMTLAccelerationStructureCommandEncoder *e = [NVMTLAccelerationStructureCommandEncoder new]; e->_cb = self; e->_owner = self; _nEnc++; return e;
}
- (id<MTLAccelerationStructureCommandEncoder>)accelerationStructureCommandEncoderWithDescriptor:(MTLAccelerationStructurePassDescriptor *)d { return [self accelerationStructureCommandEncoder]; }
- (void)addCompletedHandler:(MTLCommandBufferHandler)h {
    nvmtl_sync_use[0]++;
    if (!h) return;
    [_completionCondition lock];
    if (!_handlers) _handlers = [NSMutableArray new];
    [_handlers addObject:[h copy]]; _nHandlers++;
    [_completionCondition unlock];
}
- (void)addScheduledHandler:(MTLCommandBufferHandler)h {
    nvmtl_sync_use[1]++;
    if (!h) return;
    [_completionCondition lock];
    if (!_scheduledHandlers) _scheduledHandlers = [NSMutableArray new];
    [_scheduledHandlers addObject:[h copy]];
    [_completionCondition unlock];
}
- (void)enqueue {
    @synchronized ([NVMTLCommandBuffer class]) {
        _nEnqueue++; [self nvmtlReserveQueue];
        [_completionCondition lock];
        if (_cbstatus == MTLCommandBufferStatusNotEnqueued) _cbstatus = MTLCommandBufferStatusEnqueued;
        [_completionCondition unlock];
    }
}
- (void)dealloc {
    nvmtl_res2_cb_done(self);
    if (!_committed && _c.cb) nvmtl_vk_cmd_abandon(&_c);
    [self nvmtlReleaseCapacity];
    @synchronized ([NVMTLCommandBuffer class]) {
        [self nvmtlReleaseReservation];
        nvmtl_pump_buffers();
    }
}
- (CFTimeInterval)GPUStartTime {
    [_completionCondition lock];
    CFTimeInterval value = _executionDone && !_cbError ? _gpuStart : 0;
    [_completionCondition unlock]; return value;
}
- (CFTimeInterval)GPUEndTime {
    [_completionCondition lock];
    CFTimeInterval value = _executionDone && !_cbError ? _gpuEnd : 0;
    [_completionCondition unlock]; return value;
}
- (CFTimeInterval)kernelStartTime { return _legacyKernelStart; }
- (CFTimeInterval)kernelEndTime { return _legacyKernelEnd; }
- (void)waitUntilCompleted {
    nvmtl_sync_use[2]++;
    _nWait++; [_completionCondition lock];
    while (!_completionReady) [_completionCondition wait];
    [_completionCondition unlock];
    dispatch_group_wait(_callbackGroup, DISPATCH_TIME_FOREVER);
}
- (void)waitUntilScheduled {
    nvmtl_sync_use[3]++;
    _nWait++; [_completionCondition lock];
    while (!_wasScheduled && !_executionDone) [_completionCondition wait];
    [_completionCondition unlock];
    dispatch_group_wait(_scheduledGroup, DISPATCH_TIME_FOREVER);
}
- (MTLCommandBufferStatus)status { nvmtl_sync_use[4]++; [_completionCondition lock]; MTLCommandBufferStatus s = _cbstatus; [_completionCondition unlock]; return s; }
- (NSError *)error { return _cbError; }
- (id<MTLCommandQueue>)commandQueue { return _queue; }
- (id<MTLDevice>)device { return _queue ? [_queue device] : nil; }
- (void)setLabel:(NSString *)l { _nLabel++; _label = [l copy]; }
- (NSString *)label { return _label; }
@end

@implementation NVMTLCommandQueue
- (NSUInteger)getGPUPriority { return 1; }
- (NSUInteger)getBackgroundGPUPriority { return 2; }
- (void)setSubmissionQueue:(id)q { static int said; if (!said++) nvlog("setSubmissionQueue: %s ignored - this backend has no submission queue (said once)", q ? "a queue" : "nil"); }
- (BOOL)setGPUPriority:(NSUInteger)priority {
    nvlog("queue: GPU priority hint %lu unavailable; retaining fixed backend priority", (unsigned long)priority);
    return NO;
}
- (BOOL)setBackgroundGPUPriority:(NSUInteger)priority {
    nvlog("queue: background GPU priority hint %lu unavailable; retaining fixed backend priority", (unsigned long)priority);
    return NO;
}
- (void)addResidencySet:(id<MTLResidencySet>)r {}
- (void)addResidencySets:(const id<MTLResidencySet> __unsafe_unretained [])r count:(NSUInteger)n {}
- (void)removeResidencySet:(id<MTLResidencySet>)r {}
- (void)removeResidencySets:(const id<MTLResidencySet> __unsafe_unretained [])r count:(NSUInteger)n {}
- (void)dealloc { nvmtl_vk_queue_destroy(&_q); }
- (id<MTLCommandBuffer>)commandBuffer {
    dispatch_semaphore_t cap = nil;
    if (nvmtl_async_commit_on()) {
        @synchronized ([NVMTLCommandQueue class]) { if (!_capacity) _capacity = dispatch_semaphore_create(_capacityCount ? _capacityCount : 64); cap = _capacity; }
        dispatch_semaphore_wait(cap, DISPATCH_TIME_FOREVER);
    }
    NVMTLCommandBuffer *cb = [NVMTLCommandBuffer new];
    if (!cb) { if (cap) dispatch_semaphore_signal(cap); return nil; }
    cb->_queue = self; cb->_capacityHeld = cap != nil;
    // The resource set exists from the start. Every encoder used to create it on first use
    // (`if (!cb->_resources) cb->_resources = [NVMTLResSet new]`), and encoders of one command buffer run on several
    // threads (parallel render encoders, CoreAnimation's async render queue): two threads both saw nil, the second
    // store released the set the first was adding to, and the app died in -[NVMTLResSet addObject:] (__rehash on a freed
    // member) or in its -dealloc - about 14 Macs from 1.15 to 2.0.1 (NotificationCenter, Music, mediaanalysisd, games).
    // The set itself takes a lock for every operation; only its creation was unguarded. The first-use checks now never fire.
    cb->_resources = [NVMTLResSet new];
    if (nvmtl_vk_cmd_begin(&_q, &cb->_c)) {
        // WindowServer asserts on this nil ("Failed to get a MTLCommandBuffer"); the cause is the "vk: command buffer
        // refused" line just above, and for a disabled backend the "disabling backend" line before it.
        nvlog("queue: command buffer begin FAILED in %s - the caller gets nil", getprogname());
        return nil;
    }
    return cb;
}
- (id<MTLCommandBuffer>)commandBufferWithUnretainedReferences { return [self commandBuffer]; }
- (id<MTLCommandBuffer>)commandBufferWithDescriptor:(MTLCommandBufferDescriptor *)d { return [self commandBuffer]; }
- (void)insertDebugCaptureBoundary {}
- (void)setLabel:(NSString *)l { _label = [l copy]; }
- (NSString *)label { return _label; }
- (id<MTLDevice>)device { return _dev; }
- (id)completionQueue { return _completionQueue; }
- (void)setCompletionQueue:(id)q { _completionQueue = q; }
- (NSUInteger)maxCommandBufferCount { return nvmtl_async_commit_on() && _capacityCount ? _capacityCount : 64; }
@end

#pragma mark - residency + events (2026-09-21, honest no-op objects)
@implementation NVMTLResidencySet
- (id<MTLDevice>)device { return _dev; }
- (NSString *)label { return _label; }
- (uint64_t)allocatedSize { uint64_t s = 0; for (id<MTLAllocation> a in _allocs) s += [a allocatedSize]; return s; }
- (void)requestResidency {}
- (void)endResidency {}
- (void)addAllocation:(id<MTLAllocation>)a { if (a) [_allocs addObject:a]; }
- (void)addAllocations:(const id<MTLAllocation> __unsafe_unretained [])a count:(NSUInteger)n { for (NSUInteger i = 0; i < n; i++) if (a[i]) [_allocs addObject:a[i]]; }
- (void)removeAllocation:(id<MTLAllocation>)a { if (a) [_allocs removeObject:a]; }
- (void)removeAllocations:(const id<MTLAllocation> __unsafe_unretained [])a count:(NSUInteger)n { for (NSUInteger i = 0; i < n; i++) if (a[i]) [_allocs removeObject:a[i]]; }
- (void)removeAllAllocations { [_allocs removeAllObjects]; }
- (BOOL)containsAllocation:(id<MTLAllocation>)a { return a && [_allocs containsObject:a]; }
- (NSArray<id<MTLAllocation>> *)allAllocations { return [_allocs copy]; }
- (NSUInteger)allocationCount { return _allocs.count; }
- (void)commit {}
@end
@implementation NVMTLEvent
- (instancetype)init { if ((self = [super init])) _condition = [NSCondition new]; return self; }
- (id<MTLDevice>)device { return _dev; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { _label = [l copy]; }
- (uint64_t)signaledValue { nvmtl_sync_use[5]++; return nvmtl_event_read(_condition, &_value); }
- (void)setSignaledValue:(uint64_t)v { nvmtl_sync_use[8]++; nvmtl_event_signal(self, _condition, &_value, nil, v); }
@end
@implementation NVMTLSharedEvent
- (instancetype)init { if ((self = [super init])) { _condition = [NSCondition new]; _notifications = [NSMutableArray new]; } return self; }
- (id<MTLDevice>)device { return _dev; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { _label = [l copy]; }
- (uint64_t)signaledValue { nvmtl_sync_use[5]++; return nvmtl_event_read(_condition, &_value); }
- (void)setSignaledValue:(uint64_t)v { nvmtl_sync_use[8]++; nvmtl_event_signal(self, _condition, &_value, _notifications, v); }
- (MTLSharedEventHandle *)newSharedEventHandle {
    static int said; if (!said++) nvlog("newSharedEventHandle: -> nil (cross-process event sharing is not built; this event lives in pid %d only)", getpid());
    return nil; }
- (void)notifyListener:(MTLSharedEventListener *)l atValue:(uint64_t)v block:(MTLSharedEventNotificationBlock)b {
    nvmtl_sync_use[6]++;
    nvmtl_event_notify(self, _condition, &_value, _notifications, l, v, b);
}
- (BOOL)waitUntilSignaledValue:(uint64_t)v timeoutMS:(uint64_t)ms {
    nvmtl_sync_use[7]++;
    return nvmtl_event_wait(_condition, &_value, v, ms);
}
@end

typedef enum : uint8_t {
    NVP_INV = 0, NVP_PIPE, NVP_DS, NVP_VBUF, NVP_FBUF, NVP_VTEX, NVP_FTEX, NVP_VSAMP, NVP_FSAMP,
    NVP_CULL, NVP_WIND, NVP_FILL, NVP_SREF, NVP_SREF2, NVP_VIEWPORT, NVP_SCISSOR, NVP_DEPTHBIAS, NVP_BLENDCOL,
    NVP_DRAWIDX, NVP_DRAWIDX5, NVP_DRAW, NVP_DRAW3, NVP_USERES, NVP_USERES3, NVP_VBYTES, NVP_FBYTES,
    NVP_VOFF, NVP_FOFF, NVP_DEPTHCLIP, NVP_VBUFSTRIDE
} nvp_kind;
typedef struct {
    nvp_kind kind;
    uint32_t i0, i1, i2;
    uint64_t u0, u1, u2, u3, u4, u5;
    double   f0, f1, f2, f3, f4, f5;
    void    *o0;
    const void *p0;
} nvp_cmd;
@interface NVMTLDeferredRenderCommandEncoder : NSProxy { @public __weak NVMTLParallelRenderCommandEncoder *_owner; NSMutableArray *_inv, *_keep; BOOL _ended; NSString *_label; nvp_cmd *_cmds; uint32_t _ncmd, _capcmd; }
@end
@implementation NVMTLDeferredRenderCommandEncoder
static int nvp_fast_off(void) {
    static int off = -1;
    if (off < 0) { const char *e = getenv("NVMTL_NO_PARFAST"); off = (e && *e && *e != '0') ? 1 : 0; }
    return off;
}
- (nvp_cmd *)nvpPush:(nvp_kind)k {
    if (_ncmd == _capcmd) {
        uint32_t cap = _capcmd ? _capcmd * 2 : 256;
        nvp_cmd *p = (nvp_cmd *)realloc(_cmds, (size_t)cap * sizeof(nvp_cmd));
        if (!p) return NULL;
        _cmds = p; _capcmd = cap;
    }
    nvp_cmd *c = &_cmds[_ncmd++];
    memset(c, 0, sizeof *c);
    c->kind = k;
    return c;
}
- (void)nvpKeep:(id)o {
    if (!o) return;
    if (!_keep) _keep = [NSMutableArray new];
    [_keep addObject:o];
}
#define NVP_BEGIN(K) if (nvp_fast_off()) { [(id)self nvpForwardSlow:_cmd]; return; } \
                     @synchronized (self) { nvp_cmd *c = [self nvpPush:(K)]; if (!c) return;
#define NVP_END      }
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)p {
    if (nvp_fast_off()) { [self nvpSlowObj:@selector(setRenderPipelineState:) obj:p]; return; }
    @synchronized (self) { nvp_cmd *c = [self nvpPush:NVP_PIPE]; if (!c) return; [self nvpKeep:p]; c->o0 = (__bridge void *)p; }
}
- (void)setDepthStencilState:(id<MTLDepthStencilState>)d {
    if (nvp_fast_off()) { [self nvpSlowObj:@selector(setDepthStencilState:) obj:d]; return; }
    @synchronized (self) { nvp_cmd *c = [self nvpPush:NVP_DS]; if (!c) return; [self nvpKeep:d]; c->o0 = (__bridge void *)d; }
}
- (void)nvpBind:(nvp_kind)k obj:(id)o u0:(uint64_t)u0 idx:(uint64_t)i {
    @synchronized (self) { nvp_cmd *c = [self nvpPush:k]; if (!c) return; [self nvpKeep:o]; c->o0 = (__bridge void *)o; c->u0 = u0; c->u1 = i; }
}
- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { [self nvpBind:NVP_VBUF obj:b u0:o idx:i]; }
- (void)setFragmentBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { [self nvpBind:NVP_FBUF obj:b u0:o idx:i]; }
// the stride variant Cyberpunk 2077 calls before every draw: it went through NSInvocation (built on the worker, invoked
// again in the serial replay at the parallel encoder's endEncoding)
- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o attributeStride:(NSUInteger)st atIndex:(NSUInteger)i {
    @synchronized (self) { nvp_cmd *c = [self nvpPush:NVP_VBUFSTRIDE]; if (!c) return; [self nvpKeep:b]; c->o0 = (__bridge void *)b; c->u0 = o; c->u1 = i; c->u2 = st; }
}
- (void)setVertexBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i { [self nvpBind:NVP_VOFF obj:nil u0:o idx:i]; }
- (void)setFragmentBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i { [self nvpBind:NVP_FOFF obj:nil u0:o idx:i]; }
- (void)setVertexTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { [self nvpBind:NVP_VTEX obj:t u0:0 idx:i]; }
- (void)setFragmentTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { [self nvpBind:NVP_FTEX obj:t u0:0 idx:i]; }
- (void)setVertexSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { [self nvpBind:NVP_VSAMP obj:s u0:0 idx:i]; }
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { [self nvpBind:NVP_FSAMP obj:s u0:0 idx:i]; }
- (void)nvpScalar:(nvp_kind)k u0:(uint64_t)a u1:(uint64_t)b {
    @synchronized (self) { nvp_cmd *c = [self nvpPush:k]; if (!c) return; c->u0 = a; c->u1 = b; }
}
- (void)setCullMode:(MTLCullMode)m { [self nvpScalar:NVP_CULL u0:(uint64_t)m u1:0]; }
- (void)setFrontFacingWinding:(MTLWinding)w { [self nvpScalar:NVP_WIND u0:(uint64_t)w u1:0]; }
- (void)setTriangleFillMode:(MTLTriangleFillMode)f { [self nvpScalar:NVP_FILL u0:(uint64_t)f u1:0]; }
- (void)setDepthClipMode:(MTLDepthClipMode)m { [self nvpScalar:NVP_DEPTHCLIP u0:(uint64_t)m u1:0]; }
- (void)setStencilReferenceValue:(uint32_t)r { [self nvpScalar:NVP_SREF u0:r u1:0]; }
- (void)setStencilFrontReferenceValue:(uint32_t)f backReferenceValue:(uint32_t)b { [self nvpScalar:NVP_SREF2 u0:f u1:b]; }
- (void)setViewport:(MTLViewport)v {
    @synchronized (self) { nvp_cmd *c = [self nvpPush:NVP_VIEWPORT]; if (!c) return;
        c->f0 = v.originX; c->f1 = v.originY; c->f2 = v.width; c->f3 = v.height; c->f4 = v.znear; c->f5 = v.zfar; }
}
- (void)setScissorRect:(MTLScissorRect)r {
    @synchronized (self) { nvp_cmd *c = [self nvpPush:NVP_SCISSOR]; if (!c) return;
        c->u0 = r.x; c->u1 = r.y; c->u2 = r.width; c->u3 = r.height; }
}
- (void)setDepthBias:(float)b slopeScale:(float)s clamp:(float)cl {
    @synchronized (self) { nvp_cmd *c = [self nvpPush:NVP_DEPTHBIAS]; if (!c) return; c->f0 = b; c->f1 = s; c->f2 = cl; }
}
- (void)setBlendColorRed:(float)r green:(float)g blue:(float)b alpha:(float)a {
    @synchronized (self) { nvp_cmd *c = [self nvpPush:NVP_BLENDCOL]; if (!c) return; c->f0 = r; c->f1 = g; c->f2 = b; c->f3 = a; }
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexCount:(NSUInteger)n indexType:(MTLIndexType)it
                  indexBuffer:(id<MTLBuffer>)ib indexBufferOffset:(NSUInteger)ibo instanceCount:(NSUInteger)ic
                   baseVertex:(NSInteger)bv baseInstance:(NSUInteger)bi {
    @synchronized (self) { nvp_cmd *c = [self nvpPush:NVP_DRAWIDX]; if (!c) return; [self nvpKeep:ib];
        c->i0 = (uint32_t)t; c->i1 = (uint32_t)it; c->o0 = (__bridge void *)ib;
        c->u0 = n; c->u1 = ibo; c->u2 = ic; c->u3 = (uint64_t)bv; c->u4 = bi; }
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexCount:(NSUInteger)n indexType:(MTLIndexType)it
                  indexBuffer:(id<MTLBuffer>)ib indexBufferOffset:(NSUInteger)ibo {
    @synchronized (self) { nvp_cmd *c = [self nvpPush:NVP_DRAWIDX5]; if (!c) return; [self nvpKeep:ib];
        c->i0 = (uint32_t)t; c->i1 = (uint32_t)it; c->o0 = (__bridge void *)ib; c->u0 = n; c->u1 = ibo; }
}
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n
         instanceCount:(NSUInteger)ic baseInstance:(NSUInteger)bi {
    @synchronized (self) { nvp_cmd *c = [self nvpPush:NVP_DRAW]; if (!c) return;
        c->i0 = (uint32_t)t; c->u0 = s; c->u1 = n; c->u2 = ic; c->u3 = bi; }
}
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n {
    @synchronized (self) { nvp_cmd *c = [self nvpPush:NVP_DRAW3]; if (!c) return; c->i0 = (uint32_t)t; c->u0 = s; c->u1 = n; }
}
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u {
    @synchronized (self) { nvp_cmd *c = [self nvpPush:NVP_USERES]; if (!c) return; [self nvpKeep:r]; c->o0 = (__bridge void *)r; c->u0 = u; }
}
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u stages:(MTLRenderStages)st {
    @synchronized (self) { nvp_cmd *c = [self nvpPush:NVP_USERES3]; if (!c) return; [self nvpKeep:r]; c->o0 = (__bridge void *)r; c->u0 = u; c->u1 = st; }
}
- (void)nvmtlRecordBytes:(SEL)sel bytes:(const void *)b length:(NSUInteger)l index:(NSUInteger)i {
    NSData *d = [NSData dataWithBytes:b length:l];
    @synchronized (self) {
        [self nvpKeep:d];
        nvp_cmd *c = [self nvpPush:(sel == @selector(setVertexBytes:length:atIndex:)) ? NVP_VBYTES : NVP_FBYTES];
        if (!c) return;
        c->p0 = d.bytes; c->u0 = l; c->u1 = i;
    }
}
- (void)setVertexBytes:(const void *)b length:(NSUInteger)l atIndex:(NSUInteger)i { [self nvmtlRecordBytes:@selector(setVertexBytes:length:atIndex:) bytes:b length:l index:i]; }
- (void)setFragmentBytes:(const void *)b length:(NSUInteger)l atIndex:(NSUInteger)i { [self nvmtlRecordBytes:@selector(setFragmentBytes:length:atIndex:) bytes:b length:l index:i]; }
- (void)setVertexBytes:(const void *)b length:(NSUInteger)l attributeStride:(NSUInteger)st atIndex:(NSUInteger)i {
    SEL sel = @selector(setVertexBytes:length:attributeStride:atIndex:); NSData *d = [NSData dataWithBytes:b length:l];
    NSMethodSignature *m = [NVMTLRenderCommandEncoder instanceMethodSignatureForSelector:sel]; if (!m) return;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:m]; inv.selector = sel;
    const void *p = d.bytes; [inv setArgument:&p atIndex:2]; [inv setArgument:&l atIndex:3]; [inv setArgument:&st atIndex:4]; [inv setArgument:&i atIndex:5];
    @synchronized (self) { if (!_keep) _keep = [NSMutableArray new]; [_keep addObject:d]; [_inv addObject:inv]; }
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s {
    NSMethodSignature *m = [NVMTLRenderCommandEncoder instanceMethodSignatureForSelector:s];
    if (!m) { nvlog("parallel sub-encoder: %s is not a render-encoder selector — recorded as a no-op", sel_getName(s)); m = [NSMethodSignature signatureWithObjCTypes:"v@:"]; }
    return m;
}
- (void)forwardInvocation:(NSInvocation *)inv {
    if (![NVMTLRenderCommandEncoder instancesRespondToSelector:inv.selector]) return;
    [inv retainArguments];
    @synchronized (self) {
        [_inv addObject:inv];
        nvp_cmd *c = [self nvpPush:NVP_INV]; (void)c;
        if (inv.selector == @selector(endEncoding)) _ended = YES;
    }
    { static const char *seen[48]; static unsigned n; const char *s = sel_getName(inv.selector);
      unsigned k = 0; for (; k < n; k++) if (seen[k] == s) break;
      if (k == n && n < 48) { seen[n++] = s; nvlog("parallel sub-encoder: %s still goes through NSInvocation", s); } }
}
- (void)nvpSlowObj:(SEL)sel obj:(id)o {
    NSMethodSignature *m = [NVMTLRenderCommandEncoder instanceMethodSignatureForSelector:sel]; if (!m) return;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:m]; inv.selector = sel;
    [inv setArgument:&o atIndex:2];
    [self forwardInvocation:inv];
}
- (void)dealloc { free(_cmds); _cmds = NULL; }
- (BOOL)respondsToSelector:(SEL)s { return [NVMTLRenderCommandEncoder instancesRespondToSelector:s]; }
- (BOOL)conformsToProtocol:(Protocol *)p { return [NVMTLRenderCommandEncoder conformsToProtocol:p]; }
- (id<MTLDevice>)device { return gNVMTLMainDevice; }
- (NSString *)label { return _label; }
- (id<MTLCommandBuffer>)commandBuffer { NVMTLParallelRenderCommandEncoder *p = _owner; return p ? (id<MTLCommandBuffer>)p->_cb : nil; }   // SPI; answered here, not recorded for replay
- (void)setLabel:(NSString *)l { _label = [l copy]; }
- (void)setVertexBuffers:(const id<MTLBuffer> __unsafe_unretained [])b offsets:(const NSUInteger *)o withRange:(NSRange)r { for (NSUInteger k = 0; k < r.length; k++) if (b[k]) [(id)self setVertexBuffer:b[k] offset:o ? o[k] : 0 atIndex:r.location + k]; }
- (void)setVertexBuffers:(const id<MTLBuffer> __unsafe_unretained [])b offsets:(const NSUInteger *)o attributeStrides:(const NSUInteger *)s withRange:(NSRange)r { for (NSUInteger k = 0; k < r.length; k++) if (b[k]) [(id)self setVertexBuffer:b[k] offset:o ? o[k] : 0 attributeStride:s ? s[k] : MTLAttributeStrideStatic atIndex:r.location + k]; }
- (void)setFragmentBuffers:(const id<MTLBuffer> __unsafe_unretained [])b offsets:(const NSUInteger *)o withRange:(NSRange)r { for (NSUInteger k = 0; k < r.length; k++) if (b[k]) [(id)self setFragmentBuffer:b[k] offset:o ? o[k] : 0 atIndex:r.location + k]; }
- (void)setVertexTextures:(const id<MTLTexture> __unsafe_unretained [])t withRange:(NSRange)r { for (NSUInteger k = 0; k < r.length; k++) if (t[k]) [(id)self setVertexTexture:t[k] atIndex:r.location + k]; }
- (void)setFragmentTextures:(const id<MTLTexture> __unsafe_unretained [])t withRange:(NSRange)r { for (NSUInteger k = 0; k < r.length; k++) if (t[k]) [(id)self setFragmentTexture:t[k] atIndex:r.location + k]; }
- (void)setVertexSamplerStates:(const id<MTLSamplerState> __unsafe_unretained [])s withRange:(NSRange)r { for (NSUInteger k = 0; k < r.length; k++) [(id)self setVertexSamplerState:s[k] atIndex:r.location + k]; }
- (void)setFragmentSamplerStates:(const id<MTLSamplerState> __unsafe_unretained [])s withRange:(NSRange)r { for (NSUInteger k = 0; k < r.length; k++) [(id)self setFragmentSamplerState:s[k] atIndex:r.location + k]; }
- (void)useResources:(const id<MTLResource> __unsafe_unretained [])r count:(NSUInteger)n usage:(MTLResourceUsage)u { for (NSUInteger i = 0; i < n; i++) [(id)self useResource:r[i] usage:u]; }
- (void)useResources:(const id<MTLResource> __unsafe_unretained [])r count:(NSUInteger)n usage:(MTLResourceUsage)u stages:(MTLRenderStages)st { for (NSUInteger i = 0; i < n; i++) [(id)self useResource:r[i] usage:u stages:st]; }
- (void)useHeaps:(const id<MTLHeap> __unsafe_unretained [])h count:(NSUInteger)n { atomic_fetch_add(&g_h_useheap, n); }
- (void)useHeaps:(const id<MTLHeap> __unsafe_unretained [])h count:(NSUInteger)n stages:(MTLRenderStages)st {}
@end
@implementation NVMTLParallelRenderCommandEncoder
- (id<MTLRenderCommandEncoder>)renderCommandEncoder {
    if (_direct) {
        // A shadow command buffer of the same queue holds this sub-encoder's recording; the app gets a real render
        // encoder on it and records on its own thread. The first sub-encoder keeps the pass's load actions, the others
        // load what the one before stored; every one stores (resolves are not taken here, see the factory).
        [_lock lock];
        const NSUInteger idx = _shadows.count;
        MTLRenderPassDescriptor *sd = [_desc copy];
        for (NSUInteger ci = 0; ci < 8; ci++) if (sd.colorAttachments[ci].texture) {
            if (idx) sd.colorAttachments[ci].loadAction = MTLLoadActionLoad;
            sd.colorAttachments[ci].storeAction = MTLStoreActionStore; }
        if (sd.depthAttachment.texture) { if (idx) sd.depthAttachment.loadAction = MTLLoadActionLoad; sd.depthAttachment.storeAction = MTLStoreActionStore; }
        if (sd.stencilAttachment.texture) { if (idx) sd.stencilAttachment.loadAction = MTLLoadActionLoad; sd.stencilAttachment.storeAction = MTLStoreActionStore; }
        NVMTLCommandBuffer *sh = [NVMTLCommandBuffer new];
        sh->_queue = _cb->_queue; sh->_resources = [NVMTLResSet new];
        id<MTLRenderCommandEncoder> e = nil;
        if (!nvmtl_vk_cmd_begin(&sh->_queue->_q, &sh->_c)) {
            e = [sh renderCommandEncoderWithDescriptor:sd];
            [_shadows addObject:@[sh, e]];
        } else [_cb nvmtlRecordEncodingError:[NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorOutOfMemory
                                                 userInfo:@{NSLocalizedDescriptionKey:@"Could not allocate a parallel sub-encoder recording"}]];
        [_lock unlock];
        return e;
    }
    NVMTLDeferredRenderCommandEncoder *s = [NVMTLDeferredRenderCommandEncoder alloc];
    s->_owner = self; s->_inv = [NSMutableArray new];
    [_lock lock]; [_subs addObject:s]; [_lock unlock];
    return (id<MTLRenderCommandEncoder>)s;
}
- (void)endEncoding {
    nvmtl_enc_end();
    if (_ended) { nvlog("parallel encoder: endEncoding twice"); return; }
    _ended = YES;
    if (_direct) {
        [_lock lock]; NSArray *list = [_shadows copy]; [_shadows removeAllObjects]; [_lock unlock];
        if (!list.count) {   // no sub-encoder: the pass's clears still happen
            id<MTLRenderCommandEncoder> e = [_cb renderCommandEncoderWithDescriptor:_desc]; [e endEncoding]; return;
        }
        NSMutableArray *shadows = [NSMutableArray arrayWithCapacity:list.count]; unsigned unended = 0;
        for (NSArray *x in list) {
            NVMTLCommandBuffer *sh = x[0];
            if (!sh->_nEnd) { [(id<MTLRenderCommandEncoder>)x[1] endEncoding]; unended++; }   // Metal requires each sub-encoder to be ended
            [shadows addObject:sh];
        }
        [_cb nvmtlSpliceShadows:shadows];
        static _Atomic uint64_t encs; const uint64_t k = atomic_fetch_add(&encs, 1) + 1;
        if (k <= 2 || !(k & (k - 1)) || unended)
            nvlog("parallel encoder %p: %lu sub-encoder(s) recorded on their own threads and spliced as parts (%llu so far)%s", (__bridge void *)self,
                  (unsigned long)list.count, (unsigned long long)k, unended ? " - some were never ended by the app" : "");
        return;
    }
    const uint64_t parT0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    { static int us = -1; if (us < 0) { const char *e = getenv("NVMTL_PAR_DELAY_US"); us = e ? atoi(e) : 0; }   // sensitivity test: is the replay on the critical path?
      if (us > 0) { const uint64_t until = parT0 + (uint64_t)us * 1000u; while (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < until) {} } }
    [_lock lock]; NSArray *subs = [_subs copy]; [_subs removeAllObjects]; [_lock unlock];
    NVMTLRenderCommandEncoder *real = (NVMTLRenderCommandEncoder *)[_cb renderCommandEncoderWithDescriptor:_desc];
    NSUInteger n = 0, dropped = 0;
    // Each sub-encoder of a parallel encoder starts from Metal's default state; they are replayed one after another into
    // one encoder here, so whatever the previous sub-encoder set would otherwise carry into the next. Cyberpunk 2077's
    // G-buffer pass left stencil reference 20 ("no decals") behind, the next sub-encoder drew a floor tile with it,
    // relying on the default 0, and puddle decals on that floor vanished for a frame or two. NVMTL_PAR_NORESET=1: old rule.
    static int noReset = -1;
    if (noReset < 0) { const char *e = getenv("NVMTL_PAR_NORESET"); noReset = e && e[0] == '1';
        nvlog("parallel encoder: %s (NVMTL_PAR_NORESET=%s)", noReset ? "sub-encoders inherit the previous one's state (old rule)" : "each sub-encoder starts from Metal's default state", e ? e : "unset"); }
    BOOL firstSub = YES;
    for (NVMTLDeferredRenderCommandEncoder *s in subs) {
        if (!s->_ended) dropped++;
        if (!firstSub && !noReset) {
            [real setStencilFrontReferenceValue:0 backReferenceValue:0];
            [real setDepthBias:0 slopeScale:0 clamp:0];
            [real setCullMode:MTLCullModeNone];
            [real setFrontFacingWinding:MTLWindingClockwise];
            [real setBlendColorRed:0 green:0 blue:0 alpha:0];
            [real setDepthStencilState:nil];
            if (real->_pass.w && real->_pass.h) {
                [real setViewport:(MTLViewport){ 0, 0, (double)real->_pass.w, (double)real->_pass.h, 0, 1 }];
                [real setScissorRect:(MTLScissorRect){ 0, 0, real->_pass.w, real->_pass.h }];
            }
        }
        firstSub = NO;
        @synchronized (s) {
            NSUInteger invi = 0;
            @autoreleasepool {
                for (uint32_t ci = 0; ci < s->_ncmd; ci++) {
                    const nvp_cmd *c = &s->_cmds[ci];
                    switch (c->kind) {
                    case NVP_INV: {
                        if (invi >= s->_inv.count) break;
                        NSInvocation *inv = s->_inv[invi++];
                        if (inv.selector == @selector(endEncoding)) break;
                        [inv invokeWithTarget:real]; inv.target = nil; n++;
                        break; }
                    case NVP_PIPE:   [real setRenderPipelineState:(__bridge id)c->o0]; n++; break;
                    case NVP_DS:     [real setDepthStencilState:(__bridge id)c->o0]; n++; break;
                    case NVP_VBUF:   [real setVertexBuffer:(__bridge id)c->o0 offset:(NSUInteger)c->u0 atIndex:(NSUInteger)c->u1]; n++; break;
                    case NVP_VBUFSTRIDE: [real setVertexBuffer:(__bridge id)c->o0 offset:(NSUInteger)c->u0 attributeStride:(NSUInteger)c->u2 atIndex:(NSUInteger)c->u1]; n++; break;
                    case NVP_FBUF:   [real setFragmentBuffer:(__bridge id)c->o0 offset:(NSUInteger)c->u0 atIndex:(NSUInteger)c->u1]; n++; break;
                    case NVP_VOFF:   [real setVertexBufferOffset:(NSUInteger)c->u0 atIndex:(NSUInteger)c->u1]; n++; break;
                    case NVP_FOFF:   [real setFragmentBufferOffset:(NSUInteger)c->u0 atIndex:(NSUInteger)c->u1]; n++; break;
                    case NVP_VTEX:   [real setVertexTexture:(__bridge id)c->o0 atIndex:(NSUInteger)c->u1]; n++; break;
                    case NVP_FTEX:   [real setFragmentTexture:(__bridge id)c->o0 atIndex:(NSUInteger)c->u1]; n++; break;
                    case NVP_VSAMP:  [real setVertexSamplerState:(__bridge id)c->o0 atIndex:(NSUInteger)c->u1]; n++; break;
                    case NVP_FSAMP:  [real setFragmentSamplerState:(__bridge id)c->o0 atIndex:(NSUInteger)c->u1]; n++; break;
                    case NVP_CULL:   [real setCullMode:(MTLCullMode)c->u0]; n++; break;
                    case NVP_WIND:   [real setFrontFacingWinding:(MTLWinding)c->u0]; n++; break;
                    case NVP_FILL:   [real setTriangleFillMode:(MTLTriangleFillMode)c->u0]; n++; break;
                    case NVP_DEPTHCLIP: [real setDepthClipMode:(MTLDepthClipMode)c->u0]; n++; break;
                    case NVP_SREF:   [real setStencilReferenceValue:(uint32_t)c->u0]; n++; break;
                    case NVP_SREF2:  [real setStencilFrontReferenceValue:(uint32_t)c->u0 backReferenceValue:(uint32_t)c->u1]; n++; break;
                    case NVP_VIEWPORT: {
                        MTLViewport v = { c->f0, c->f1, c->f2, c->f3, c->f4, c->f5 };
                        [real setViewport:v]; n++; break; }
                    case NVP_SCISSOR: {
                        MTLScissorRect r = { (NSUInteger)c->u0, (NSUInteger)c->u1, (NSUInteger)c->u2, (NSUInteger)c->u3 };
                        [real setScissorRect:r]; n++; break; }
                    case NVP_DEPTHBIAS: [real setDepthBias:(float)c->f0 slopeScale:(float)c->f1 clamp:(float)c->f2]; n++; break;
                    case NVP_BLENDCOL:  [real setBlendColorRed:(float)c->f0 green:(float)c->f1 blue:(float)c->f2 alpha:(float)c->f3]; n++; break;
                    case NVP_DRAWIDX:
                        [real drawIndexedPrimitives:(MTLPrimitiveType)c->i0 indexCount:(NSUInteger)c->u0
                                          indexType:(MTLIndexType)c->i1 indexBuffer:(__bridge id)c->o0
                                  indexBufferOffset:(NSUInteger)c->u1 instanceCount:(NSUInteger)c->u2
                                         baseVertex:(NSInteger)c->u3 baseInstance:(NSUInteger)c->u4]; n++; break;
                    case NVP_DRAWIDX5:
                        [real drawIndexedPrimitives:(MTLPrimitiveType)c->i0 indexCount:(NSUInteger)c->u0
                                          indexType:(MTLIndexType)c->i1 indexBuffer:(__bridge id)c->o0
                                  indexBufferOffset:(NSUInteger)c->u1]; n++; break;
                    case NVP_DRAW:
                        [real drawPrimitives:(MTLPrimitiveType)c->i0 vertexStart:(NSUInteger)c->u0
                                 vertexCount:(NSUInteger)c->u1 instanceCount:(NSUInteger)c->u2
                                baseInstance:(NSUInteger)c->u3]; n++; break;
                    case NVP_DRAW3:
                        [real drawPrimitives:(MTLPrimitiveType)c->i0 vertexStart:(NSUInteger)c->u0
                                 vertexCount:(NSUInteger)c->u1]; n++; break;
                    case NVP_USERES:  [real useResource:(__bridge id)c->o0 usage:(MTLResourceUsage)c->u0]; n++; break;
                    case NVP_USERES3: [real useResource:(__bridge id)c->o0 usage:(MTLResourceUsage)c->u0 stages:(MTLRenderStages)c->u1]; n++; break;
                    case NVP_VBYTES:  [real setVertexBytes:c->p0 length:(NSUInteger)c->u0 atIndex:(NSUInteger)c->u1]; n++; break;
                    case NVP_FBYTES:  [real setFragmentBytes:c->p0 length:(NSUInteger)c->u0 atIndex:(NSUInteger)c->u1]; n++; break;
                    }
                    if ((ci & 0xff) == 0xff) {  }
                }
            }
            free(s->_cmds); s->_cmds = NULL; s->_ncmd = s->_capcmd = 0;
            [s->_inv removeAllObjects]; [s->_keep removeAllObjects]; s->_owner = nil;
        }
    }
    [real endEncoding];
    {   // replay cost: every 2 s, the time spent here (one thread, serial) per second and per call
        static _Atomic uint64_t ns, calls, encs, last; const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        atomic_fetch_add(&ns, now - parT0); atomic_fetch_add(&calls, n); atomic_fetch_add(&encs, 1);
        uint64_t l = atomic_load(&last); if (!l) atomic_compare_exchange_strong(&last, &l, now);
        else if (now - l >= 2000000000ull && atomic_compare_exchange_strong(&last, &l, now)) {
            const uint64_t t = atomic_exchange(&ns, 0), c = atomic_exchange(&calls, 0), e = atomic_exchange(&encs, 0);
            nvlog_diag("parallel encoder replay: %.1f ms/s over %llu encoder(s), %llu call(s), %.0f ns/call", t / 1e6 / ((now - l) / 1e9),
                       (unsigned long long)e, (unsigned long long)c, c ? (double)t / c : 0.0);
        }
    }
    nvlog("parallel encoder %p: replayed %lu call(s) from %lu sub-encoder(s)%s", (__bridge void *)self, (unsigned long)n, (unsigned long)subs.count,
          dropped ? " (some sub-encoders were never ended)" : "");
}
- (id<MTLDevice>)device { return gNVMTLMainDevice; }
- (NSString *)label { return _label; }
- (id<MTLCommandBuffer>)commandBuffer { return (id<MTLCommandBuffer>)_cb; }   // SPI, see the render encoder
- (void)setLabel:(NSString *)l { _label = [l copy]; }
- (void)setColorStoreAction:(MTLStoreAction)a atIndex:(NSUInteger)i { _desc.colorAttachments[i].storeAction = a; }
- (void)setDepthStoreAction:(MTLStoreAction)a { _desc.depthAttachment.storeAction = a; }
- (void)setStencilStoreAction:(MTLStoreAction)a { _desc.stencilAttachment.storeAction = a; }
- (void)setColorStoreActionOptions:(MTLStoreActionOptions)o atIndex:(NSUInteger)i { _desc.colorAttachments[i].storeActionOptions = o; }
- (void)setDepthStoreActionOptions:(MTLStoreActionOptions)o { _desc.depthAttachment.storeActionOptions = o; }
- (void)setStencilStoreActionOptions:(MTLStoreActionOptions)o {
    if (o) [_cb nvmtlRecordEncodingError:[NSError errorWithDomain:MTLCommandBufferErrorDomain
        code:MTLCommandBufferErrorInternal userInfo:@{NSLocalizedDescriptionKey:@"stencil store options are illegal"}]];
    _desc.stencilAttachment.storeActionOptions = o;
}
- (void)insertDebugSignpost:(NSString *)s {}
- (void)pushDebugGroup:(NSString *)g { nvtrace("GROUP %s", g.UTF8String ?: "?"); }
- (void)popDebugGroup {}
@end

uint32_t nvmtl_geoms_from_descriptor(id desc, nvmtl_geom *out, uint32_t max, int *instance, uint32_t *instance_count, NSMutableSet *track)
{
    *instance = 0; *instance_count = 0;
    if ([desc isKindOfClass:[MTLInstanceAccelerationStructureDescriptor class]]) {
        *instance = 1; *instance_count = (uint32_t)((MTLInstanceAccelerationStructureDescriptor *)desc).instanceCount; return 0;
    }
    if (![desc isKindOfClass:[MTLPrimitiveAccelerationStructureDescriptor class]]) {
        nvlog("acceleration structure: %s is not carried (primitive and instance descriptors are)", NSStringFromClass([desc class]).UTF8String); return 0;
    }
    NSArray *gs = ((MTLPrimitiveAccelerationStructureDescriptor *)desc).geometryDescriptors; uint32_t n = 0;
    for (MTLAccelerationStructureGeometryDescriptor *g in gs) {
        if (n >= max) { nvlog("acceleration structure: more than %u geometries — the rest are dropped", max); break; }
        nvmtl_geom *o = &out[n]; memset(o, 0, sizeof *o); o->opaque = g.opaque ? 1 : 0;
        if ([g isKindOfClass:[MTLAccelerationStructureTriangleGeometryDescriptor class]]) {
            MTLAccelerationStructureTriangleGeometryDescriptor *t = (MTLAccelerationStructureTriangleGeometryDescriptor *)g;
            NVMTLBuffer *vb = (NVMTLBuffer *)t.vertexBuffer;
            if (!vb) { nvlog("acceleration structure: triangle geometry without a vertex buffer — dropped"); continue; }
            if (track) [track addObject:vb];
            o->vertices = nvmtl_vk_buffer_address(&vb->_b) + t.vertexBufferOffset; o->stride = (uint32_t)(t.vertexStride ? t.vertexStride : 12);
            o->count = (uint32_t)t.triangleCount;
            MTLAttributeFormat f = [t respondsToSelector:@selector(vertexFormat)] ? t.vertexFormat : MTLAttributeFormatFloat3;
            switch (f) {
            case MTLAttributeFormatFloat3: o->vertex_format = 106; break;
            case MTLAttributeFormatHalf3:  o->vertex_format = 90; break;
            case MTLAttributeFormatFloat2: o->vertex_format = 103; break;
            case MTLAttributeFormatHalf2:  o->vertex_format = 83; break;
            default: nvlog("acceleration structure: vertex format %lu is not carried — read as float3", (unsigned long)f); o->vertex_format = 106; break;
            }
            NVMTLBuffer *ib = (NVMTLBuffer *)t.indexBuffer;
            if (ib) { if (track) [track addObject:ib]; o->indices = nvmtl_vk_buffer_address(&ib->_b) + t.indexBufferOffset;
                      o->index_type = t.indexType == MTLIndexTypeUInt16 ? 0 : 1; o->max_vertex = 0xFFFFFF; }
            else { o->index_type = 1000165000u ; o->max_vertex = o->count ? o->count * 3 - 1 : 0; }
        } else if ([g isKindOfClass:[MTLAccelerationStructureBoundingBoxGeometryDescriptor class]]) {
            MTLAccelerationStructureBoundingBoxGeometryDescriptor *b = (MTLAccelerationStructureBoundingBoxGeometryDescriptor *)g;
            NVMTLBuffer *bb = (NVMTLBuffer *)b.boundingBoxBuffer;
            if (!bb) { nvlog("acceleration structure: box geometry without a buffer — dropped"); continue; }
            if (track) [track addObject:bb];
            o->is_boxes = 1; o->boxes = nvmtl_vk_buffer_address(&bb->_b) + b.boundingBoxBufferOffset;
            o->box_stride = (uint32_t)(b.boundingBoxStride ? b.boundingBoxStride : 24); o->count = (uint32_t)b.boundingBoxCount;
        } else {
            nvlog("acceleration structure: geometry %s is not carried (motion / curves) — dropped", NSStringFromClass([g class]).UTF8String); continue;
        }
        n++;
    }
    return n;
}

@implementation NVMTLAccelerationStructure
- (NSUInteger)size { return _b.size; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)s { return MTLPurgeableStateNonVolatile; }
- (MTLResourceID)gpuResourceID { MTLResourceID r; r._impl = _as.addr ? _as.addr : nvmtl_vk_buffer_address(&_b); return r; }
- (BOOL)nvmtlEnsureCreated:(int)instance {
    if (_as.as) {
        if (_as.instance != instance) { nvlog("acceleration structure: built as %s before, now as %s — REFUSED", _as.instance ? "instances" : "primitives", instance ? "instances" : "primitives"); return NO; }
        return YES;
    }
    if (nvmtl_vk_accel_create(&_b, _b.size, instance, &_as)) { nvlog("acceleration structure: create FAILED"); return NO; }
    nvlog("acceleration structure %p: %s, %zu bytes at %llx", (__bridge void *)self, instance ? "instances" : "primitives", _b.size, (unsigned long long)_as.addr);
    return YES;
}
- (void)dealloc {
    nvmtl_vk_accel_destroy(&_as);
    if (_uid.buf) nvmtl_vk_buffer_destroy(&_uid);
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}
@end

@implementation NVMTLAccelerationStructureCommandEncoder
- (id<MTLDevice>)device { return _cb->_queue->_dev; }
- (id<MTLCommandBuffer>)commandBuffer { return (id<MTLCommandBuffer>)(_cb ? _cb : _owner); }   // SPI, see the render encoder
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { _label = [l copy]; }
- (void)endEncoding { nvmtl_enc_end(); if (_cb) { _cb->_nEnd++; _cb = nil; } }   // lets go of the command buffer, as the blit encoder does
- (void)nvmtlTrack:(id)r { if (!r) return; if (!_cb->_resources) _cb->_resources = [NVMTLResSet new]; [_cb->_resources addObject:r]; }
- (void)buildAccelerationStructure:(id<MTLAccelerationStructure>)as descriptor:(MTLAccelerationStructureDescriptor *)desc
                     scratchBuffer:(id<MTLBuffer>)scratch scratchBufferOffset:(NSUInteger)soff {
    NVMTLAccelerationStructure *dst = (NVMTLAccelerationStructure *)as; NVMTLBuffer *sc = (NVMTLBuffer *)scratch;
    if (!dst || !sc) { nvlog("build acceleration structure: nil %s", dst ? "scratch" : "structure"); return; }
    [self nvmtlTrack:dst]; [self nvmtlTrack:sc];
    if (!_cb->_resources) _cb->_resources = [NVMTLResSet new];
    static nvmtl_geom geoms[NVMTL_MAX_GEOMS]; int instance = 0; uint32_t icount = 0;
    uint32_t n = nvmtl_geoms_from_descriptor(desc, geoms, NVMTL_MAX_GEOMS, &instance, &icount, _cb->_resources);
    uint64_t scratch_addr = (nvmtl_vk_buffer_address(&sc->_b) + soff + 255ull) & ~255ull;
    if (![dst nvmtlEnsureCreated:instance]) return;
    if (!instance && [desc isKindOfClass:[MTLPrimitiveAccelerationStructureDescriptor class]]) {
        NSArray *gd = ((MTLPrimitiveAccelerationStructureDescriptor *)desc).geometryDescriptors; uint32_t add = 0;
        if (gd.count) {
            const NSUInteger o0 = [(MTLAccelerationStructureGeometryDescriptor *)gd[0] intersectionFunctionTableOffset]; BOOL same = YES, affine = YES;
            for (NSUInteger g = 0; g < gd.count; g++) {
                const NSUInteger o = [(MTLAccelerationStructureGeometryDescriptor *)gd[g] intersectionFunctionTableOffset];
                same = same && o == o0; affine = affine && o == o0 + g; }
            if (o0 > 0x7FFFFF || (!same && !affine))
                nvlog("build acceleration structure: geometry intersection function table offsets (first %lu, %lu geometries) are neither equal nor base + index - the slot reads the instance offset alone", (unsigned long)o0, (unsigned long)gd.count);
            else add = (uint32_t)o0 | (same ? 0u : 0x800000u);
        }
        dst->_iftAdd = add;
    }
    uint64_t inst_addr = 0;
    if (instance) {
        MTLInstanceAccelerationStructureDescriptor *idesc = (MTLInstanceAccelerationStructureDescriptor *)desc;
        NVMTLBuffer *ib = (NVMTLBuffer *)idesc.instanceDescriptorBuffer;
        if (!ib || !nvmtl_buf_cpu(ib)) { nvlog("build acceleration structure: instance descriptors %s", ib ? "not host-visible" : "nil"); return; }
        const MTLAccelerationStructureInstanceDescriptorType itype = idesc.instanceDescriptorType;
        if (itype != MTLAccelerationStructureInstanceDescriptorTypeDefault && itype != MTLAccelerationStructureInstanceDescriptorTypeUserID &&
            itype != MTLAccelerationStructureInstanceDescriptorTypeIndirect) {
            nvlog("build acceleration structure: instance descriptor type %lu is not carried (Default, UserID and Indirect are)", (unsigned long)itype); return; }
        const uint32_t natural = itype == MTLAccelerationStructureInstanceDescriptorTypeDefault ? 64 : itype == MTLAccelerationStructureInstanceDescriptorTypeUserID ? 68 : 72;
        NSArray *blases = idesc.instancedAccelerationStructures; static uint64_t addrs[4096]; uint32_t nas = 0;
        static uint32_t iftAdds[4096];
        for (NVMTLAccelerationStructure *b in blases) { if (nas < 4096) { iftAdds[nas] = b->_iftAdd; addrs[nas++] = b->_as.addr; } [self nvmtlTrack:b]; }
        NVMTLBuffer *vk = [NVMTLBuffer new];
        size_t bytes = (size_t)(icount ? icount : 1) * (64 + 4);
        if (nvmtl_vk_buffer_create(bytes, 1, &vk->_b) || !vk->_b.map) { nvlog("build acceleration structure: instance conversion buffer FAILED"); return; }
        uint32_t stride = (uint32_t)(idesc.instanceDescriptorStride ? idesc.instanceDescriptorStride : natural);
        if (stride < natural || idesc.instanceDescriptorBufferOffset + (size_t)(icount ? icount - 1 : 0) * stride + natural > ib->_b.size) {
            nvlog("build acceleration structure: %u instances of stride %u at %lu overrun the %zu-byte descriptor buffer - REFUSED", icount, stride,
                  (unsigned long)idesc.instanceDescriptorBufferOffset, ib->_b.size); return; }
        const size_t uidOff = (size_t)(icount ? icount : 1) * 64, uidBytes = (size_t)(icount ? icount : 1) * 4;
        memset((uint8_t *)vk->_b.map + uidOff, 0, uidBytes);
        nvmtl_vk_convert_instances((const uint8_t *)nvmtl_buf_cpu(ib) + idesc.instanceDescriptorBufferOffset, stride, icount, addrs, nas, vk->_b.map,
                                   itype == MTLAccelerationStructureInstanceDescriptorTypeIndirect ? 3u : (uint32_t)itype,
                                   (uint32_t *)((uint8_t *)vk->_b.map + uidOff), iftAdds);
        if (dst->_uid.size < uidBytes) {
            if (dst->_uid.buf) { NVMTLBuffer *old = [NVMTLBuffer new]; old->_b = dst->_uid; if (!_cb->_scratch) _cb->_scratch = [NSMutableArray new]; [_cb->_scratch addObject:old]; }
            memset(&dst->_uid, 0, sizeof dst->_uid);
            if (nvmtl_vk_buffer_create(uidBytes, 0, &dst->_uid)) { nvlog("build acceleration structure: userID side table (%zu B) FAILED - user_instance_id reads 0", uidBytes); memset(&dst->_uid, 0, sizeof dst->_uid); }
        }
        if (dst->_uid.buf && nvmtl_vk_cmd_copy_buffer(&_cb->_c, &vk->_b, uidOff, &dst->_uid, 0, uidBytes))
            nvlog("build acceleration structure: userID side table copy FAILED");
        if (!_cb->_scratch) _cb->_scratch = [NSMutableArray new];
        [_cb->_scratch addObject:vk];
        [self nvmtlTrack:ib]; inst_addr = nvmtl_vk_buffer_address(&vk->_b);
    }
    if (nvmtl_vk_cmd_build_accel(&_cb->_c, &dst->_as, geoms, n, inst_addr, icount, scratch_addr)) nvlog("build acceleration structure: FAILED");
    else nvlog("build acceleration structure %p: %s (%u %s)", (__bridge void *)dst, instance ? "instances" : "primitives", instance ? icount : n, instance ? "instances" : "geometries");
}
- (void)refitAccelerationStructure:(id<MTLAccelerationStructure>)src descriptor:(MTLAccelerationStructureDescriptor *)d
                       destination:(id<MTLAccelerationStructure>)dst scratchBuffer:(id<MTLBuffer>)s scratchBufferOffset:(NSUInteger)o {
    [self buildAccelerationStructure:(dst ? dst : src) descriptor:d scratchBuffer:s scratchBufferOffset:o];
}
- (void)refitAccelerationStructure:(id<MTLAccelerationStructure>)src descriptor:(MTLAccelerationStructureDescriptor *)d
                       destination:(id<MTLAccelerationStructure>)dst scratchBuffer:(id<MTLBuffer>)s scratchBufferOffset:(NSUInteger)o
                           options:(MTLAccelerationStructureRefitOptions)opts {
    [self buildAccelerationStructure:(dst ? dst : src) descriptor:d scratchBuffer:s scratchBufferOffset:o];
}
- (void)copyAccelerationStructure:(id<MTLAccelerationStructure>)src toAccelerationStructure:(id<MTLAccelerationStructure>)dst {
    NVMTLAccelerationStructure *s = (NVMTLAccelerationStructure *)src, *d = (NVMTLAccelerationStructure *)dst;
    if (!s || !d || !s->_as.as) { nvlog("copy acceleration structure: %s", s && d ? "source never built" : "nil"); return; }
    if (![d nvmtlEnsureCreated:s->_as.instance]) return;
    [self nvmtlTrack:s]; [self nvmtlTrack:d];
    if (nvmtl_vk_cmd_copy_accel(&_cb->_c, &s->_as, &d->_as)) nvlog("copy acceleration structure: FAILED");
    if (s->_uid.buf) {
        if (d->_uid.size < s->_uid.size) {
            if (d->_uid.buf) { NVMTLBuffer *old = [NVMTLBuffer new]; old->_b = d->_uid; if (!_cb->_scratch) _cb->_scratch = [NSMutableArray new]; [_cb->_scratch addObject:old]; }
            memset(&d->_uid, 0, sizeof d->_uid);
            if (nvmtl_vk_buffer_create(s->_uid.size, 0, &d->_uid)) { nvlog("copy acceleration structure: side table FAILED"); memset(&d->_uid, 0, sizeof d->_uid); }
        }
        if (d->_uid.buf && nvmtl_vk_cmd_copy_buffer(&_cb->_c, &s->_uid, 0, &d->_uid, 0, s->_uid.size)) nvlog("copy acceleration structure: side table copy FAILED");
    }
}
- (void)copyAndCompactAccelerationStructure:(id<MTLAccelerationStructure>)src toAccelerationStructure:(id<MTLAccelerationStructure>)dst {
    [self copyAccelerationStructure:src toAccelerationStructure:dst];
}
- (void)writeCompactedAccelerationStructureSize:(id<MTLAccelerationStructure>)as toBuffer:(id<MTLBuffer>)buf offset:(NSUInteger)off {
    [self writeCompactedAccelerationStructureSize:as toBuffer:buf offset:off sizeDataType:MTLDataTypeUInt];
}
- (void)writeCompactedAccelerationStructureSize:(id<MTLAccelerationStructure>)as toBuffer:(id<MTLBuffer>)buf offset:(NSUInteger)off sizeDataType:(MTLDataType)t {
    NVMTLAccelerationStructure *a = (NVMTLAccelerationStructure *)as; NVMTLBuffer *b = (NVMTLBuffer *)buf;
    if (!a || !b) { nvlog("writeCompactedAccelerationStructureSize: nil"); return; }
    const uint64_t v = a->_b.size; const size_t n = t == MTLDataTypeULong ? 8 : 4;
    if (off > b->_b.size || b->_b.size - off < n) { nvlog("writeCompactedAccelerationStructureSize: %zu bytes at %lu is past the %zu-byte buffer - REFUSED", n, (unsigned long)off, b->_b.size); return; }
    if (off & 3) {
        if (!nvmtl_buf_cpu(b)) { nvlog("writeCompactedAccelerationStructureSize: offset %lu is not 4-aligned and the buffer is not host-visible - REFUSED", (unsigned long)off); return; }
        static int said; if (said++ < 2) nvlog("writeCompactedAccelerationStructureSize: offset %lu is not 4-aligned - written from the CPU at encode time (unordered)", (unsigned long)off);
        memcpy((uint8_t *)nvmtl_buf_cpu(b) + off, &v, n);
        if (b->_shadow.map) [b didModifyRange:NSMakeRange(off, n)];
        return;
    }
    [self nvmtlTrack:b];
    if (nvmtl_vk_cmd_write_word(&_cb->_c, &b->_b, off, (uint32_t)v) ||
        (n == 8 && nvmtl_vk_cmd_write_word(&_cb->_c, &b->_b, off + 4, (uint32_t)(v >> 32))))
        nvlog("writeCompactedAccelerationStructureSize: GPU write at %lu FAILED", (unsigned long)off);
}
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u { [self nvmtlTrack:r]; }
- (void)useResources:(const id<MTLResource> __unsafe_unretained [])rs count:(NSUInteger)n usage:(MTLResourceUsage)u { for (NSUInteger i = 0; i < n; i++) [self nvmtlTrack:rs[i]]; }
- (void)useHeap:(id<MTLHeap>)h { atomic_fetch_add(&g_h_useheap, 1); }
- (void)useHeaps:(const id<MTLHeap> __unsafe_unretained [])hs count:(NSUInteger)n {}
- (void)updateFence:(id<MTLFence>)f {}
- (void)waitForFence:(id<MTLFence>)f {}
- (void)insertDebugSignpost:(NSString *)s {}
- (void)pushDebugGroup:(NSString *)s {}
- (void)popDebugGroup {}
- (void)sampleCountersInBuffer:(id<MTLCounterSampleBuffer>)b atSampleIndex:(NSUInteger)i withBarrier:(BOOL)w { nvmtl_sample_counter(_cb, b, i, self, w); }
@end

static void nvmtl_buffer_sync_in(NVMTLBuffer *b)
{
    if (!b || !b->_hostPtr || !b->_b.map || !b->_hostLen) return;
    const uint64_t t0 = nvmtl_perf_now();
    memcpy(b->_b.map, b->_hostPtr, b->_hostLen);
    nvmtl_perf_note(NVP_SYNCIN, t0, b->_hostLen);
}

static void nvmtl_buffer_sync_out(NVMTLBuffer *b)
{
    if (b && b->_shadow.map) {
        if (b->_syncOut) { b->_syncOut = 0; __atomic_store_n(&b->_zshadow, 0, __ATOMIC_RELEASE);
            if (nvmtl_vk_copy_buffer(nvmtl_device_queue(), &b->_b, 0, &b->_shadow, 0, b->_b.size)) nvlog("commit: managed sync-out of %zu bytes FAILED", b->_b.size); }
        return;
    }
    if (!b || !b->_hostPtr || !b->_b.map || !b->_hostLen) return;
    const uint64_t t0 = nvmtl_perf_now();
    memcpy(b->_hostPtr, b->_b.map, b->_hostLen);
    nvmtl_perf_note(NVP_SYNCOUT, t0, b->_hostLen);
}


extern _Atomic uint64_t nvmtl_fm_slot_puts, nvmtl_fm_slot_reaps;
static FILE *nvmtl_fm_file(void)
{
    static char path[600];
    if (!path[0]) snprintf(path, sizeof path, "%s/Library/Logs/nvmtl/flickmon-%d.txt", getenv("HOME") ?: "/tmp", (int)getpid());
    return fopen(path, "a");
}
// /tmp/nvmtl-flickmon (consumed when seen): for the next 1200 presented frames, every frame's G-buffer pass (first
// full-width pass with 3+ colour attachments; attachments 0-2) and its first full-width B10G11R11 pass are read back
// after their command buffer completes and reduced to the fraction of all-zero texels and per-channel means, with an
// 80x50 thumbnail, next to a per-frame line of plugin events (textures, heap reuse, views, bindless slots, uploads).
// A black flash is a one- or two-frame spike in the zero fraction; the events of that frame say what came with it.
void nvmtl_fm_frame(unsigned frame)
{
    static _Atomic unsigned until; static _Atomic uint64_t next;
    static _Atomic unsigned pendStart, pendCnt;
    if (atomic_load(&pendCnt) && frame >= atomic_load(&pendStart)) {
        const unsigned cnt = atomic_exchange(&pendCnt, 0);
        atomic_store(&until, frame + cnt); atomic_store(&g_fm_all, 1); atomic_store(&g_fm_on, 1);
        nvlog("pass capture: delayed start - every full-width pass of frames %u..%u", frame + 1, frame + cnt);
    }
    static uint64_t last[9];
    const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (!atomic_load(&g_fm_on) && now >= atomic_load(&next)) {
        atomic_store(&next, now + 500000000ull);
        if (access("/tmp/nvmtl-finalcap", F_OK) == 0) {
            int cnt = 2000; FILE *pf = fopen("/tmp/nvmtl-finalcap", "r"); if (pf) { if (fscanf(pf, "%d", &cnt) != 1) cnt = 2000; fclose(pf); }
            if (cnt < 1 || cnt > 5000) cnt = 2000;
            unlink("/tmp/nvmtl-finalcap");
            atomic_store(&until, frame + (unsigned)cnt); atomic_store(&g_fm_final, 1); atomic_store(&g_fm_all, 1); atomic_store(&g_fm_on, 1);
            nvlog("final capture: the presented image of frames %u..%u -> ~/Library/Logs/nvmtl/flickmon-%d/", frame + 1, frame + cnt, (int)getpid());
        } else if (access("/tmp/nvmtl-passcap", F_OK) == 0) {
            int cnt = 40, delay = 0; FILE *pf = fopen("/tmp/nvmtl-passcap", "r"); if (pf) { if (fscanf(pf, "%d %d", &cnt, &delay) < 1) cnt = 40; fclose(pf); }
            if (cnt < 1 || cnt > 400) cnt = 40;
            if (delay < 0 || delay > 100000) delay = 0;
            unlink("/tmp/nvmtl-passcap");
            if (delay) { atomic_store(&pendStart, frame + (unsigned)delay); atomic_store(&pendCnt, (unsigned)cnt);
                         nvlog("pass capture: armed to start %d frames from now (frame %u), %d frames", delay, frame + (unsigned)delay, cnt); return; }
            atomic_store(&until, frame + (unsigned)cnt); atomic_store(&g_fm_all, 1); atomic_store(&g_fm_on, 1);
            nvlog("pass capture: every full-width pass of frames %u..%u -> ~/Library/Logs/nvmtl/flickmon-%d/ (pNN = pass order in the frame)", frame + 1, frame + cnt, (int)getpid());
        } else if (access("/tmp/nvmtl-flickmon", F_OK) == 0) {
            unlink("/tmp/nvmtl-flickmon");
            atomic_store(&until, frame + 1200); atomic_store(&g_fm_on, 1);
            nvlog("flick monitor: ON for frames %u..%u -> ~/Library/Logs/nvmtl/flickmon-%d.txt", frame + 1, frame + 1200, (int)getpid());
        }
    }
    if (!atomic_load(&g_fm_on)) return;
    const uint64_t cur[9] = { nvmtl_tex_objs_made, nvmtl_tex_objs_gone, atomic_load(&gHTPlaced), atomic_load(&gHTRecycled),
                              atomic_load(&nvmtl_fm_views_made), atomic_load(&nvmtl_fm_views_gone), atomic_load(&nvmtl_fm_blit2tex),
                              atomic_load(&nvmtl_fm_slot_puts), atomic_load(&nvmtl_fm_slot_reaps) };
    static int primed;
    if (primed) {
        FILE *f = nvmtl_fm_file();
        if (f) { fprintf(f, "E frame %u texobj+ %llu texobj- %llu heaptex+ %llu heaptex-recycled %llu views+ %llu views- %llu blit2tex %llu slots+ %llu slots-reaped %llu\n", frame,
                         (unsigned long long)(cur[0] - last[0]), (unsigned long long)(cur[1] - last[1]), (unsigned long long)(cur[2] - last[2]),
                         (unsigned long long)(cur[3] - last[3]), (unsigned long long)(cur[4] - last[4]), (unsigned long long)(cur[5] - last[5]),
                         (unsigned long long)(cur[6] - last[6]), (unsigned long long)(cur[7] - last[7]), (unsigned long long)(cur[8] - last[8]));
                 fclose(f); }
    }
    memcpy(last, cur, sizeof last); primed = 1;
    if (frame >= atomic_load(&until)) { atomic_store(&g_fm_on, 0); atomic_store(&g_fm_all, 0); atomic_store(&g_fm_final, 0); primed = 0; nvlog("flick monitor: done"); }
}
static void nvmtl_fm_stats_px(const uint8_t *px, uint32_t w, uint32_t h, uint32_t bpp, uint32_t fmt, unsigned frame, int kind, int att, const char *label, uint32_t draws, uint64_t ord, uint64_t cbseq)
{
    const size_t row = (size_t)w * bpp;
    uint64_t zero = 0, n = 0; double sum[4] = { 0, 0, 0, 0 };
    for (uint32_t y = 0; y < h; y += 2) for (uint32_t x = 0; x < w; x += 2) {
        const uint8_t *t = px + (size_t)y * row + (size_t)x * bpp; int z = 1;
        for (uint32_t b = 0; b < bpp; b++) if (t[b]) { z = 0; break; }
        zero += z; float c[4]; nvmtl_flick_texel(t, fmt, bpp, c);
        for (int i = 0; i < 4; i++) if (isfinite(c[i])) sum[i] += c[i];
        n++;
    }
    char dir[600]; snprintf(dir, sizeof dir, "%s/Library/Logs/nvmtl/flickmon-%d", getenv("HOME") ?: "/tmp", (int)getpid()); mkdir(dir, 0755);
    char kn[16]; if (kind == 200) snprintf(kn, sizeof kn, "fin"); else if (kind >= 100) snprintf(kn, sizeof kn, "p%02d", kind - 100); else snprintf(kn, sizeof kn, "%s", kind ? "lit" : "gbuf");
    char path[700]; snprintf(path, sizeof path, "%s/o%06llu-f%05u-%s-c%d-%ux%u-fmt%u-bpp%u.thumb", dir, (unsigned long long)ord, frame, kn, att, w, h, fmt, bpp);
    const uint32_t TW = kind == 200 ? 320 : kind >= 100 ? 256 : att == 0 ? 320 : 80, TH = kind == 200 ? 200 : kind >= 100 ? 160 : att == 0 ? 200 : 50;
    FILE *f = fopen(path, "wb");
    if (f) { fwrite(&TW, 4, 1, f); fwrite(&TH, 4, 1, f);
             for (uint32_t ty = 0; ty < TH; ty++) for (uint32_t tx = 0; tx < TW; tx++) {
                 const uint32_t x = (uint32_t)((uint64_t)tx * w / TW), y = (uint32_t)((uint64_t)ty * h / TH);
                 fwrite(px + (size_t)y * row + (size_t)x * bpp, 1, bpp, f); }
             fclose(f); }
    f = nvmtl_fm_file();
    if (f) { fprintf(f, "P frame %u %s c%d '%s' draws %u %ux%u fmt %u zero %.5f mean %.4f %.4f %.4f %.4f ord %llu cb %llu\n", frame, kn, att, label, draws, w, h, fmt,
                     n ? (double)zero / n : 0, n ? sum[0] / n : 0, n ? sum[1] / n : 0, n ? sum[2] / n : 0, n ? sum[3] / n : 0,
                     (unsigned long long)ord, (unsigned long long)cbseq);
             fclose(f); }
}
