// nvmtl_shm.c - "shmirror": the app's Shared memory lives in VRAM for the GPU, with the coherence a unified-memory app
// expects (docs/ARM64-PORT-NOTES.md item 66). Included at the end of nvmtl_vk.c; NVMTL_SHMIRROR=1 turns it on.
//
// An app Shared allocation (a mirror-pool block, or a large Shared buffer of its own) is "adopted" when it is made, before
// the GPU has used it: nvmtl_nvk_memory_twin moves its GPU VA to a VRAM copy and gives its system pages a shadow VA.
// - CPU writes: the system pages are write-protected; a write fault marks its 16 KB page dirty and unprotects it.
//   The pre-submit prologue re-protects every dirty page and copies it whole into VRAM (copy engine). Whole pages are
//   safe because the one graphics queue runs parts in order, so the copy-back of every earlier part has run first.
// - GPU writes: shaders are instrumented (translator store_note.rs) to mark 16-byte chunks in this range's bitmap and a
//   summary bit per 512 KB; the epilogue of every part runs shm_copyback.comp, which copies marked chunks to the system
//   pages and clears the marks, then a barrier makes them visible to the host before the part's fence. Writes the plugin
//   records itself (blit copies, fills, query results into a Shared buffer) are copied back by explicit range.
// - The table the shaders read (store_note.rs layout) is BAR1 VRAM the CPU writes directly; adding a range writes new
//   slots only, so the GPU may read while it is updated.
#include "shm_copyback.spv.h"
#include "shm_scatter.spv.h"
#include <sched.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <mach-o/dyld.h>

#define SHM_PAGE 16384u
#define SHM_MAX_RANGES 4096
#define SHM_TAB_L1 4096u
#define SHM_ENTRY 64u
#define SHM_L2 65536u
#define SHM_MAX_L2 96u
#define SHM_TAB_SIZE (SHM_TAB_L1 + SHM_MAX_RANGES * SHM_ENTRY + SHM_MAX_L2 * SHM_L2)

typedef struct {
    uintptr_t cpu; size_t len;            // the system pages as the app maps them (16 KB aligned) and their length
    uint64_t va, shadow;                  // GPU address (now VRAM) and the system pages' GPU address
    volatile uint8_t *dirty;              // per 16 KB page: written by the CPU since its last upload
    uint32_t *stamp;                      // per page: 1 + the frame of its last fault (cost census)
    uint64_t *uphash;                     // per page: hash of the bytes at its last upload (NVMTL_SHM_VERIFY_MS diagnostic)
    uint8_t *snap;                        // the bytes as last uploaded (NVMTL_SHM_SNAP diagnostic)
    uint8_t *snapped;                     // per page: snap holds a previous upload
    size_t sys_lo, sys_hi;                // pages the GPU reads from the system pages again (bisection): never protected or uploaded
    nvk_buffer touched; volatile uint32_t *tmap;   // per page, 1 once the GPU has written it (set by the copy-back kernel / plugin writes)
    uint8_t *dsnap, *dsnapped;            // the bytes as the VRAM copy holds them, for pages the GPU never wrote (diff uploads)
    nvk_buffer bitmap, summary; size_t bitmap_len, summary_len;
    void *mem; int zero_owed; _Atomic int live;
} shm_range;
static shm_range g_shm[SHM_MAX_RANGES];
static _Atomic int g_shm_n;
static pthread_mutex_t g_shm_lock = PTHREAD_MUTEX_INITIALIZER;
static VkBuffer g_shm_tab_buf; static VkDeviceMemory g_shm_tab_mem; static uint64_t g_shm_tab_va; static volatile uint8_t *g_shm_tmap;
static uint32_t g_shm_l2_used; static int g_shm_ready;
static void shm_audit_start(void);       // 1 table + pipeline ready, -1 failed
static VkPipeline g_shm_pipe, g_shm_scatter_pipe; static VkPipelineLayout g_shm_playout; static uint32_t g_shm_max_granules;
// handle sets: shader modules with store sites, pipelines built from them, command buffers that bound one (cleared by
// the epilogue). Open addressing, 0 = empty, 1 = removed; a stale handle reused by a new object only costs an epilogue.
typedef struct { uint64_t *k; uint32_t cap, n; os_unfair_lock lk; } shm_set;
static shm_set g_shm_wmods, g_shm_wpipes, g_shm_wcbs;
static uint32_t shm_hash(uint64_t k) { k ^= k >> 33; k *= 0xff51afd7ed558ccdull; k ^= k >> 33; return (uint32_t)k; }
static void shm_set_add(shm_set *s, uint64_t k)
{
    if (k <= 1) return;
    os_unfair_lock_lock(&s->lk);
    if (!s->k) { s->cap = 1u << 16; s->k = calloc(s->cap, 8); }
    if (s->k && s->n < s->cap / 2) {
        uint32_t i = shm_hash(k) & (s->cap - 1), tomb = UINT32_MAX;
        for (;; i = (i + 1) & (s->cap - 1)) {
            if (s->k[i] == k) break;
            if (s->k[i] == 1 && tomb == UINT32_MAX) tomb = i;
            if (!s->k[i]) { s->k[tomb != UINT32_MAX ? tomb : i] = k; s->n++; break; }
        }
    }
    os_unfair_lock_unlock(&s->lk);
}
static int shm_set_has(shm_set *s, uint64_t k, int remove)
{
    if (k <= 1 || !s->k) return 0;
    int hit = 0;
    os_unfair_lock_lock(&s->lk);
    for (uint32_t i = shm_hash(k) & (s->cap - 1), c = 0; s->k[i] && c < s->cap; i = (i + 1) & (s->cap - 1), c++)
        if (s->k[i] == k) { hit = 1; if (remove) s->k[i] = 1; break; }
    os_unfair_lock_unlock(&s->lk);
    return hit;
}
static _Atomic int g_shm_dirty_any;   // a CPU write fault or an adoption since the last prologue scan
static _Atomic unsigned long long g_shm_epi_skipped;
static PFN_vkCmdBindPipeline g_shm_real_bind;
static PFN_vkCreateShaderModule g_shm_real_csm; static PFN_vkCreateGraphicsPipelines g_shm_real_cgp; static PFN_vkCreateComputePipelines g_shm_real_ccp;
int (*nvmtl_shm_instrument_fn)(const uint8_t *, size_t, uint8_t **, size_t *, uint32_t *, char *, size_t);   // set by NVMTLLibraryLoad.m
void (*nvmtl_shm_free_fn)(uint8_t *, size_t);
uint32_t nvmtl_shm_spec_id = 0x4E565301u;
static _Atomic unsigned long long g_shm_faults, g_shm_up_bytes, g_shm_up_runs, g_shm_epis, g_shm_sites, g_shm_modules, g_shm_wb, g_shm_adopted, g_shm_adopt_bytes;
// copy-queue uploads (see shm_async_setup)
#define SHM_UCB 32
static int g_shm_async;
static VkSemaphore g_shm_semG, g_shm_semU;
static VkSemaphore g_shm_semC; static uint64_t g_shm_cval; static int g_stg_used;   // staged uploads (see stg_ready)
static _Atomic uint64_t g_shm_upub;                                      // g_shm_uval, for nvmtl_shm_forget
static _Atomic int g_shm_scanning;                                       // a prologue is between its range scan and its submit
static _Atomic unsigned long long g_shm_async_batches, g_shm_async_gwaits, g_shm_async_uwaits, g_shm_async_reuse_waits, g_shm_async_fail, g_shm_gsigs;
static void shm_async_setup(void);
static _Atomic int g_shm_evicted_any; static _Atomic unsigned long long g_shm_evict_bytes, g_shm_evict_n, g_shm_evict_pending;
static __thread int t_shm_in_prologue;   // this thread is inside nvmtl_shm_prologue: its pending uploads name live ranges
// NVMTL_SHM_DIFF (default on): a page the GPU has never written is uploaded as the words the CPU changed since its
// last upload, in a batch that does not wait for writer parts - it starts at once and overlaps the GPU work queued
// ahead. Pages the GPU wrote (and first uploads) go whole, after the last writer part, as before.
// OFF by default (run 432: 12.8 fps against 32): the changed words go up as ~1000 small copy-engine copies a frame, each
// paying ~50 us of launch and Thunderbolt latency - far slower than whole pages merged into a few large copies.
static int shm_diff_on(void) { static int v = -1; if (v < 0) { const char *e = getenv("NVMTL_SHM_DIFF"); v = e && e[0] == '1';
    nvlog("shmirror: %s (NVMTL_SHM_DIFF=%s)", v ? "pages the GPU never wrote go up as changed words without waiting for writer parts" : "every upload is whole pages after the last writer part", e ? e : "unset"); } return v; }
// NVMTL_SHM_SCATTER (default on; =0 back to copy-engine uploads): uploads become compute dispatches at the head of the part (its prologue, graphics
// queue): ordered after every earlier part, so no writer wait and no copy queue; pages the GPU never wrote send only the
// words the CPU changed, the rest whole pages, from a list in host-visible memory.
static int shm_scatter_on(void) { static int v = -1; if (v < 0) { const char *e = getenv("NVMTL_SHM_SCATTER"); v = !(e && e[0] == '0');
    nvlog("shmirror: uploads %s (NVMTL_SHM_SCATTER=%s)", v ? "by a compute scatter at the head of each part" : "by the copy engine", e ? e : "unset"); } return v; }
#define SHM_LIST_BYTES (16u << 20)
static nvk_buffer g_shm_list; static uint32_t g_shm_list_at;   // entries of 32 bytes, a ring, under nvmtl_submit_mutex
static _Atomic unsigned long long g_shm_sc_entries, g_shm_sc_bytes, g_shm_sc_whole, g_shm_sc_disp;
static _Atomic unsigned long long g_shm_dA_bytes, g_shm_dA_pages, g_shm_dB_bytes, g_shm_dB_pages, g_shm_dA_batches, g_shm_dB_batches;
static long shm_verify_ms(void) { static long v = -2; if (v == -2) { const char *e = getenv("NVMTL_SHM_VERIFY_MS"); v = e ? atol(e) : 0; } return v; }
static uint64_t shm_page_hash(const uint64_t *p) { uint64_t h = 1469598103934665603ull; for (int i = 0; i < 2048; i++) { h ^= p[i]; h *= 1099511628211ull; } return h; }
// what the app placed in an adopted heap (diagnostic, for the audit): the latest placement covering a page names it
typedef struct { void *mem; uint64_t off, len; uint32_t kind, usage; } shm_place;   // kind 1 buffer, 2 texture, 3 depth texture
static shm_place *g_shm_pl; static size_t g_shm_pl_n, g_shm_pl_cap; static os_unfair_lock g_shm_pl_lk = OS_UNFAIR_LOCK_INIT;
static _Atomic unsigned long long g_shm_pl_tex, g_shm_lost_gpu, g_shm_diff_pages, g_shm_diff_bytes, g_shm_diff_runs;
void nvmtl_shm_note_place(void *mem, size_t off, size_t len, unsigned kind, unsigned usage)
{
    if (g_shm_ready != 1 || !mem) return;
    int found = 0; const int n = atomic_load(&g_shm_n);
    for (int i = 0; i < n; i++) if (g_shm[i].mem == mem && atomic_load(&g_shm[i].live)) { found = 1; break; }
    if (!found) return;
    if (kind != 1) { const unsigned long long k = atomic_fetch_add(&g_shm_pl_tex, 1) + 1;
        if (k <= 16 || !(k & (k - 1))) nvlog("shmirror: %s placed in an adopted heap at +%zu, %zu bytes, usage 0x%x (%llu so far) - GPU writes to it are NOT tracked",
                                          kind == 3 ? "depth texture" : "texture", off, len, usage, k); }
    os_unfair_lock_lock(&g_shm_pl_lk);
    if (g_shm_pl_n == g_shm_pl_cap) { size_t nc = g_shm_pl_cap ? g_shm_pl_cap * 2 : 4096; shm_place *nv = realloc(g_shm_pl, nc * sizeof *nv); if (nv) { g_shm_pl = nv; g_shm_pl_cap = nc; } }
    if (g_shm_pl_n < g_shm_pl_cap) g_shm_pl[g_shm_pl_n++] = (shm_place){ mem, off, len, kind, usage };
    os_unfair_lock_unlock(&g_shm_pl_lk);
}
static int shm_place_find(void *mem, uint64_t at, shm_place *out)
{
    int r = 0; os_unfair_lock_lock(&g_shm_pl_lk);
    for (size_t k = g_shm_pl_n; k-- > 0; ) { const shm_place *p = &g_shm_pl[k]; if (p->mem == mem && at >= p->off && at < p->off + p->len) { *out = *p; r = 1; break; } }
    os_unfair_lock_unlock(&g_shm_pl_lk); return r;
}
// every NVMTL_SHM_VERIFY_MS: a page that is clean (not marked, write-protected) must still hold what was uploaded; one
// that does not was written by the CPU without a fault (or by a GPU copy-back) - the write the VRAM copy never got
static void shm_verify(void)
{
    enum { MAXF = 256 };
    static struct { int i; size_t q; } fl[MAXF]; int nf = 0;
    unsigned long long checked = 0, changed = 0;
    const int n = atomic_load(&g_shm_n);
    for (int i = 0; i < n; i++) {
        shm_range *r = &g_shm[i];
        if (!atomic_load(&r->live) || !r->uphash || !r->dirty) continue;
        const size_t pages = r->len / SHM_PAGE;
        for (size_t q = 0; q < pages; q++) {
            if (!r->uphash[q] || __atomic_load_n(&r->dirty[q], __ATOMIC_ACQUIRE)) continue;
            const uint64_t h = shm_page_hash((const uint64_t *)(r->cpu + q * SHM_PAGE)) | 1;
            checked++;
            if (h == r->uphash[q] || __atomic_load_n(&r->dirty[q], __ATOMIC_ACQUIRE)) continue;
            changed++; r->uphash[q] = h;
            if (nf < MAXF) { fl[nf].i = i; fl[nf].q = q; nf++; }
        }
    }
    // a changed clean page is benign when the VRAM copy holds the same bytes (a GPU write copied back); a page whose VRAM
    // copy differs was written by the CPU without a fault: the write the GPU never sees
    unsigned long long lost = 0, benign = 0; int said = 0;
    if (nf) {
        pthread_mutex_lock(&nvmtl_submit_mutex);
        pvkDeviceWaitIdle(g_dev);
        nvk_buffer st; memset(&st, 0, sizeof st);
        if (!nvmtl_vk_buffer_create((size_t)nf * SHM_PAGE, 1, &st) && st.map) {
            const uint64_t sva = nvmtl_vk_buffer_address(&st);
            nvk_cmdbuf c;
            if (!nvmtl_vk_cmd_begin(NULL, &c)) {
                for (int k = 0; k < nf; k++) { shm_range *r = &g_shm[fl[k].i]; uint64_t src = r->va + fl[k].q * SHM_PAGE, dst = sva + (uint64_t)k * SHM_PAGE, sz = SHM_PAGE; pnvk_cmd_copy_va(c.cb, 1, &src, &dst, &sz); }
                if (!nvmtl_vk_submit_wait(&c))
                    for (int k = 0; k < nf; k++) {
                        shm_range *r = &g_shm[fl[k].i];
                        if (__atomic_load_n(&r->dirty[fl[k].q], __ATOMIC_ACQUIRE)) continue;
                        const uint8_t *v = (const uint8_t *)st.map + (size_t)k * SHM_PAGE, *sy = (const uint8_t *)(r->cpu + fl[k].q * SHM_PAGE);
                        if (!memcmp(v, sy, SHM_PAGE)) { benign++; continue; }
                        lost++;
                        if (said++ < 16) {
                            unsigned dc = 0, first = UINT32_MAX; for (unsigned o = 0; o < SHM_PAGE; o += 16) if (memcmp(v + o, sy + o, 16)) { dc++; if (first == UINT32_MAX) first = o; }
                            shm_place pl; const int hit = shm_place_find(r->mem, (uint64_t)fl[k].q * SHM_PAGE + first, &pl);
                            const uint32_t *vv = (const uint32_t *)(v + first), *ss = (const uint32_t *)(sy + first);
                            nvlog_diag("shmirror verify: LOST WRITE entry %d (%zu MB) page %zu: %u chunks differ, first +%u VRAM %08x %08x | system %08x %08x | %s%s",
                                       fl[k].i, r->len >> 20, fl[k].q, dc, first, vv[0], vv[1], ss[0], ss[1], hit ? (pl.kind == 1 ? "buffer" : "texture") : "no placement recorded",
                                       hit ? [[NSString stringWithFormat:@" at +%llu, %llu bytes", pl.off, pl.len] UTF8String] : "");
                        }
                    }
            }
            nvmtl_vk_buffer_destroy(&st);
        }
        pthread_mutex_unlock(&nvmtl_submit_mutex);
    }
    nvlog_diag("shmirror verify: %llu clean pages checked, %llu changed without a fault: %llu GPU write-backs (VRAM agrees), %llu LOST (VRAM differs)", checked, changed, benign, lost);
}
// cost census (shm_cost_tick, every 5 s): what the write tracking costs the app's threads and the submit path
extern _Atomic unsigned nvmtl_flick_frame;
static _Atomic unsigned long long g_shm_fault_ns, g_shm_fault_pages, g_shm_pro_ns, g_shm_prot_ns, g_shm_prot_calls, g_shm_scans;
#define SHM_TH 8
static struct { _Atomic uintptr_t id; _Atomic unsigned long long n; } g_shm_th[SHM_TH];
static char *g_shm_probe; static _Atomic int g_shm_probe_faults;   // self-test pages: one complete fault, as the app's threads take it
static int shm_diag(const char *name)   // diagnostic switches, read once
{
    static const char *names[4]; static int vals[4], nn;
    for (int i = 0; i < nn; i++) if (names[i] == name) return vals[i];
    const char *e = getenv(name); const int v = e && e[0] == '1';
    if (nn < 4) { names[nn] = name; vals[nn] = v; nn++; }
    if (v) nvlog("shmirror: DIAGNOSTIC %s=1 - rendering is not correct in this run", name);
    return v;
}

// Default (NVMTL_SHMIRROR unset): ON for native Apple Silicon apps - the arm64 slice, not translated by Rosetta, not an
// Apple system binary, not WindowServer. OFF for x86_64 processes (Rosetta, CrossOver/Wine: their own fault handlers
// and translated code are untested with the write tracking) and on Intel Macs. =1 / =0 force it either way.
static const char *shm_default_why(void)
{
#if !defined(__arm64__)
    return "x86_64 process (Rosetta, CrossOver or an Intel Mac)";
#else
    int tr = 0; size_t tn = sizeof tr;
    if (sysctlbyname("sysctl.proc_translated", &tr, &tn, NULL, 0) == 0 && tr) return "translated process";
    const char *me = getprogname();
    if (me && !strcmp(me, "WindowServer")) return "WindowServer";
    char path[1024]; uint32_t pn = sizeof path;
    if (_NSGetExecutablePath(path, &pn) == 0 && (!strncmp(path, "/System/", 8) || !strncmp(path, "/usr/", 5) || !strncmp(path, "/bin/", 5) ||
                                                 !strncmp(path, "/sbin/", 6) || !strncmp(path, "/Library/Apple/", 15))) return "an Apple system binary";
    return NULL;
#endif
}
int nvmtl_shm_on(void)
{
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("NVMTL_SHMIRROR"), *why = NULL;
        if (e && *e) on = e[0] == '1';
        else { why = shm_default_why(); on = why == NULL; }
        nvlog("shmirror: %s (NVMTL_SHMIRROR=%s%s%s)", on ? "ON - the app's Shared memory lives in VRAM with CPU/GPU coherence (item 66)" : "off",
              e ? e : "unset", e ? "" : on ? ", default for a native Apple Silicon app" : ", default off: ", e || on ? "" : why);
    }
    return on;
}
int nvmtl_shm_active(void) { return g_shm_ready == 1; }

static void shm_w32(uint64_t off, uint32_t v) { *(volatile uint32_t *)(g_shm_tmap + off) = v; }
static void shm_w64(uint64_t off, uint64_t v) { *(volatile uint32_t *)(g_shm_tmap + off) = (uint32_t)v; *(volatile uint32_t *)(g_shm_tmap + off + 4) = (uint32_t)(v >> 32); }

// ---- table and copy-back pipeline -------------------------------------------------------------------------------
static int shm_table_create(void)
{
    VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, NULL, 0, SHM_TAB_SIZE,
        VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT, VK_SHARING_MODE_EXCLUSIVE, 0, NULL };
    if (pvkCreateBuffer(g_dev, &bci, NULL, &g_shm_tab_buf) != VK_SUCCESS) return -1;
    VkMemoryRequirements mr; pvkGetBufferMemoryRequirements(g_dev, g_shm_tab_buf, &mr);
    int mt = bar1_memtype_force(mr.memoryTypeBits, mr.size), bar = mt >= 0;
    if (mt < 0) mt = memtype(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (mt < 0) return -1;
    VkMemoryAllocateFlagsInfo fi = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO, NULL, VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT, 0 };
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, &fi, mr.size, (uint32_t)mt };
    void *map = NULL;
    if (pvkAllocateMemory(g_dev, &ai, NULL, &g_shm_tab_mem) != VK_SUCCESS || pvkMapMemory(g_dev, g_shm_tab_mem, 0, VK_WHOLE_SIZE, 0, &map) != VK_SUCCESS
        || pvkBindBufferMemory(g_dev, g_shm_tab_buf, g_shm_tab_mem, 0) != VK_SUCCESS || !map) return -1;
    g_shm_tmap = map;
    for (uint64_t o = 0; o < SHM_TAB_SIZE; o += 4) shm_w32(o, 0);   // BAR1 is Device memory to the CPU: aligned stores only
    VkBufferDeviceAddressInfo di = { VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO, NULL, g_shm_tab_buf };
    g_shm_tab_va = pvkGetBufferDeviceAddress(g_dev, &di);
    nvlog("shmirror: table %u KB in %s at GPU 0x%llx", SHM_TAB_SIZE >> 10, bar ? "VRAM through BAR1" : "system memory (no BAR1 type)", (unsigned long long)g_shm_tab_va);
    return g_shm_tab_va ? 0 : -1;
}
static int shm_pipeline_create(void)
{
    VkShaderModuleCreateInfo smi = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0, sizeof shm_copyback_spv, shm_copyback_spv };
    VkShaderModule mod = VK_NULL_HANDLE;
    if (g_shm_real_csm(g_dev, &smi, NULL, &mod) != VK_SUCCESS) return -1;
    VkPushConstantRange pr = { VK_SHADER_STAGE_COMPUTE_BIT, 0, 16 };
    VkPipelineLayoutCreateInfo li = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0, 0, NULL, 1, &pr };
    if (pvkCreatePipelineLayout(g_dev, &li, NULL, &g_shm_playout) != VK_SUCCESS) { pvkDestroyShaderModule(g_dev, mod, NULL); return -1; }
    VkComputePipelineCreateInfo ci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, NULL, 0,
        { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_COMPUTE_BIT, mod, "main", NULL }, g_shm_playout, VK_NULL_HANDLE, -1 };
    VkResult r = g_shm_real_ccp(g_dev, VK_NULL_HANDLE, 1, &ci, NULL, &g_shm_pipe);
    pvkDestroyShaderModule(g_dev, mod, NULL);
    if (r != VK_SUCCESS) return -1;
    // the scatter upload (same push-constant layout: u64 list, u32 count, u32 pad)
    VkShaderModuleCreateInfo smi2 = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0, sizeof shm_scatter_spv, shm_scatter_spv };
    VkShaderModule mod2 = VK_NULL_HANDLE;
    if (g_shm_real_csm(g_dev, &smi2, NULL, &mod2) == VK_SUCCESS) {
        VkComputePipelineCreateInfo ci2 = ci; ci2.stage.module = mod2;
        if (g_shm_real_ccp(g_dev, VK_NULL_HANDLE, 1, &ci2, NULL, &g_shm_scatter_pipe) != VK_SUCCESS) g_shm_scatter_pipe = VK_NULL_HANDLE;
        pvkDestroyShaderModule(g_dev, mod2, NULL);
    }
    return 0;
}

// ---- instrumentation and the table address as a specialization constant ------------------------------------------
static VKAPI_ATTR VkResult VKAPI_CALL shm_CreateShaderModule(VkDevice d, const VkShaderModuleCreateInfo *ci, const VkAllocationCallbacks *a, VkShaderModule *out)
{
    if (g_shm_ready != 1 || !nvmtl_shm_instrument_fn || !ci || !ci->pCode) return g_shm_real_csm(d, ci, a, out);
    uint8_t *o = NULL; size_t n = 0; uint32_t sites = 0; char err[256] = { 0 };
    if (nvmtl_shm_instrument_fn((const uint8_t *)ci->pCode, ci->codeSize, &o, &n, &sites, err, sizeof err)) {
        static int said; if (said++ < 16) nvlog("shmirror: a shader could not be instrumented (%s) - its device stores are NOT copied back", err);
        return g_shm_real_csm(d, ci, a, out);
    }
    VkShaderModuleCreateInfo c2 = *ci; c2.codeSize = n; c2.pCode = (const uint32_t *)o;
    VkResult r = g_shm_real_csm(d, &c2, a, out);
    if (nvmtl_shm_free_fn) nvmtl_shm_free_fn(o, n);
    if (r == VK_SUCCESS && sites && out) shm_set_add(&g_shm_wmods, (uint64_t)(uintptr_t)*out);
    if (sites) { atomic_fetch_add(&g_shm_sites, sites); const unsigned long long k = atomic_fetch_add(&g_shm_modules, 1) + 1;
        if (!(k & (k - 1))) nvlog("shmirror: %llu shader modules instrumented, %llu store sites", k, (unsigned long long)atomic_load(&g_shm_sites)); }
    return r;
}
// one stage: its specialization plus the table address at SpecId nvmtl_shm_spec_id (an id the module does not use is
// ignored by Vulkan, so every stage gets it)
typedef struct { VkSpecializationInfo si; VkSpecializationMapEntry *e; uint8_t *data; } shm_spec;
static void shm_spec_make(const VkSpecializationInfo *in, shm_spec *s)
{
    const uint32_t n = in ? in->mapEntryCount : 0; const size_t dsz = in ? in->dataSize : 0, at = (dsz + 7) & ~(size_t)7;
    s->e = calloc(n + 1, sizeof *s->e); s->data = calloc(at + 8, 1);
    if (n) memcpy(s->e, in->pMapEntries, n * sizeof *s->e);
    if (dsz) memcpy(s->data, in->pData, dsz);
    memcpy(s->data + at, &g_shm_tab_va, 8);
    s->e[n] = (VkSpecializationMapEntry){ nvmtl_shm_spec_id, (uint32_t)at, 8 };
    s->si = (VkSpecializationInfo){ n + 1, s->e, at + 8, s->data };
}
static VKAPI_ATTR VkResult VKAPI_CALL shm_CreateGraphicsPipelines(VkDevice d, VkPipelineCache pc, uint32_t n, const VkGraphicsPipelineCreateInfo *ci, const VkAllocationCallbacks *a, VkPipeline *out)
{
    if (g_shm_ready != 1 || n != 1 || !ci || ci->stageCount > 8) return g_shm_real_cgp(d, pc, n, ci, a, out);
    VkGraphicsPipelineCreateInfo c = *ci; VkPipelineShaderStageCreateInfo st[8]; shm_spec sp[8];
    for (uint32_t i = 0; i < ci->stageCount; i++) { st[i] = ci->pStages[i]; shm_spec_make(st[i].pSpecializationInfo, &sp[i]); st[i].pSpecializationInfo = &sp[i].si; }
    c.pStages = st;
    VkResult r = g_shm_real_cgp(d, pc, 1, &c, a, out);
    int writes = 0; for (uint32_t i = 0; i < ci->stageCount; i++) writes |= shm_set_has(&g_shm_wmods, (uint64_t)(uintptr_t)ci->pStages[i].module, 0);
    if (r == VK_SUCCESS && writes && out) shm_set_add(&g_shm_wpipes, (uint64_t)(uintptr_t)*out);
    for (uint32_t i = 0; i < ci->stageCount; i++) { free(sp[i].e); free(sp[i].data); }
    return r;
}
static VKAPI_ATTR VkResult VKAPI_CALL shm_CreateComputePipelines(VkDevice d, VkPipelineCache pc, uint32_t n, const VkComputePipelineCreateInfo *ci, const VkAllocationCallbacks *a, VkPipeline *out)
{
    if (g_shm_ready != 1 || n != 1 || !ci) return g_shm_real_ccp(d, pc, n, ci, a, out);
    VkComputePipelineCreateInfo c = *ci; shm_spec sp; shm_spec_make(ci->stage.pSpecializationInfo, &sp); c.stage.pSpecializationInfo = &sp.si;
    VkResult r = g_shm_real_ccp(d, pc, 1, &c, a, out);
    free(sp.e); free(sp.data);
    if (r == VK_SUCCESS && out && shm_set_has(&g_shm_wmods, (uint64_t)(uintptr_t)ci->stage.module, 0)) shm_set_add(&g_shm_wpipes, (uint64_t)(uintptr_t)*out);
    return r;
}

// a command buffer that binds a pipeline with store sites needs the copy-back epilogue
static VKAPI_ATTR void VKAPI_CALL shm_CmdBindPipeline(VkCommandBuffer cb, VkPipelineBindPoint bp, VkPipeline p)
{
    g_shm_real_bind(cb, bp, p);
    if (shm_set_has(&g_shm_wpipes, (uint64_t)(uintptr_t)p, 0)) shm_set_add(&g_shm_wcbs, (uint64_t)(uintptr_t)cb);
}
// after the device functions are loaded (nvmtl_vk.c): table, pipeline, and the wrappers
static void nvmtl_shm_vk_loaded(void)
{
    if (!nvmtl_shm_on() || g_shm_ready) return;
    g_shm_real_csm = pvkCreateShaderModule; g_shm_real_cgp = pvkCreateGraphicsPipelines; g_shm_real_ccp = pvkCreateComputePipelines; g_shm_real_bind = pvkCmdBindPipeline;
    if (!pnvk_memory_twin || !pnvk_cmd_copy_va || !pvkGetBufferDeviceAddress || shm_table_create() || shm_pipeline_create()) {
        g_shm_ready = -1;
        nvlog("shmirror: UNAVAILABLE (NVK twin %s, copy by VA %s, table/pipeline setup failed) - Shared memory stays in system memory",
              pnvk_memory_twin ? "yes" : "NO", pnvk_cmd_copy_va ? "yes" : "NO");
        return;
    }
    pvkCreateShaderModule = shm_CreateShaderModule; pvkCreateGraphicsPipelines = shm_CreateGraphicsPipelines; pvkCreateComputePipelines = shm_CreateComputePipelines;
    pvkCmdBindPipeline = shm_CmdBindPipeline;
    g_shm_ready = 1;
    shm_async_setup();
    shm_audit_start();
    nvlog("shmirror: ready - shader modules are instrumented, pipelines get the table address (SpecId 0x%08x)", nvmtl_shm_spec_id);
}

// ---- adopting an allocation ----------------------------------------------------------------------------------------
static void shm_census(const char *why)
{
    nvlog_diag("shmirror (%s): %llu allocations adopted (%llu MB), %llu CPU write faults, %llu MB uploaded in %llu runs, %llu epilogues (%llu skipped: no stores), %llu explicit write-backs",
               why, (unsigned long long)atomic_load(&g_shm_adopted), (unsigned long long)(atomic_load(&g_shm_adopt_bytes) >> 20),
               (unsigned long long)atomic_load(&g_shm_faults), (unsigned long long)(atomic_load(&g_shm_up_bytes) >> 20),
               (unsigned long long)atomic_load(&g_shm_up_runs), (unsigned long long)atomic_load(&g_shm_epis), (unsigned long long)atomic_load(&g_shm_epi_skipped),
               (unsigned long long)atomic_load(&g_shm_wb));
    if (g_shm_async || atomic_load(&g_shm_async_fail))
        nvlog_diag("shmirror (%s): copy queue - %llu upload batches (%llu waited for a writer part), %llu parts waited for a batch, %llu writer parts signalled, %llu command-buffer reuse waits, %llu failures",
                   why, (unsigned long long)atomic_load(&g_shm_async_batches), (unsigned long long)atomic_load(&g_shm_async_gwaits),
                   (unsigned long long)atomic_load(&g_shm_async_uwaits), (unsigned long long)atomic_load(&g_shm_gsigs),
                   (unsigned long long)atomic_load(&g_shm_async_reuse_waits), (unsigned long long)atomic_load(&g_shm_async_fail));
    if (atomic_load(&g_shm_sc_entries))
        nvlog_diag("shmirror (%s): scatter uploads - %llu entries (%llu MB, %llu whole pages) in %llu dispatches",
                   why, (unsigned long long)atomic_load(&g_shm_sc_entries), (unsigned long long)(atomic_load(&g_shm_sc_bytes) >> 20),
                   (unsigned long long)atomic_load(&g_shm_sc_whole), (unsigned long long)atomic_load(&g_shm_sc_disp));
    if (atomic_load(&g_shm_dA_pages) || atomic_load(&g_shm_dB_pages))
        nvlog_diag("shmirror (%s): diff uploads - %llu pages as changed words (%llu MB, %llu batches without a wait), %llu pages whole after the writers (%llu MB, %llu batches)",
                   why, (unsigned long long)atomic_load(&g_shm_dA_pages), (unsigned long long)(atomic_load(&g_shm_dA_bytes) >> 20), (unsigned long long)atomic_load(&g_shm_dA_batches),
                   (unsigned long long)atomic_load(&g_shm_dB_pages), (unsigned long long)(atomic_load(&g_shm_dB_bytes) >> 20), (unsigned long long)atomic_load(&g_shm_dB_batches));
}
static void nvmtl_presubmit(void);
static void nvmtl_shw_install(void);
// `mem` is a fresh system-memory VkDeviceMemory the GPU has not used, mapped at `map` for `len` bytes. 0 = adopted.
int nvmtl_shm_adopt(void *mem, void *map, size_t len)
{
    if (g_shm_ready != 1 || !mem || !map || ((uintptr_t)map & (SHM_PAGE - 1)) || len < SHM_PAGE) return -1;
    len &= ~(size_t)(SHM_PAGE - 1);
    if (atomic_load(&g_shm_evicted_any)) return -1;   // VRAM ran short once in this process: no new twins
    {   // a twin only with room to spare: the gate's headroom plus 1 GB stays free after it
        uint64_t fv = 0, bd = 0, us = 0; int ms = 0;
        nvmtl_vk_vram_wall0(len, &fv, &bd, &us, &ms);
        if (ms && fv < len + NVMTL_VRAM_HEADROOM + (1024ull << 20)) {
            static int said; if (said++ < 4) nvlog("shmirror: a %zu MB allocation NOT adopted - %llu MB of VRAM free, the app's resources come first", len >> 20, (unsigned long long)(fv >> 20));
            return -1;
        }
    }
    pthread_mutex_lock(&g_shm_lock);
    int idx = -1; const int n = atomic_load(&g_shm_n);
    for (int i = 0; i < n; i++) if (!atomic_load(&g_shm[i].live) && !g_shm[i].mem) { idx = i; break; }
    if (idx < 0) { if (n >= SHM_MAX_RANGES) { pthread_mutex_unlock(&g_shm_lock); static int said; if (!said++) nvlog("shmirror: range table full - later Shared memory stays in system memory"); return -1; } idx = n; }
    uint64_t va = 0, shadow = 0;
    if (pnvk_memory_twin(mem, &va, &shadow) || (va & 0xffff) || (va >> 40)) {
        pthread_mutex_unlock(&g_shm_lock);
        static int said; if (said++ < 8) nvlog("shmirror: twin of a %zu-byte allocation FAILED or unaligned (va 0x%llx) - it stays in system memory", len, (unsigned long long)va);
        return -1;
    }
    shm_range *r = &g_shm[idx];
    memset(r, 0, sizeof *r);
    r->cpu = (uintptr_t)map; r->len = len; r->va = va; r->shadow = shadow; r->mem = mem;
    const size_t pages = len / SHM_PAGE, chunks = len >> 2;   // 4-byte chunks (store_note.rs)
    uint8_t *d = malloc(pages); memset(d, 1, pages); r->stamp = calloc(pages, sizeof *r->stamp); r->dirty = d;                     // all of it goes up before first use
    r->bitmap_len = ((chunks + 31) / 32) * 4; r->summary_len = (((chunks + 131071) / 131072 + 31) / 32) * 4;   // summary: 512 KB granules
    if (nvmtl_vk_buffer_create(r->bitmap_len, 0, &r->bitmap) || nvmtl_vk_buffer_create(r->summary_len, 0, &r->summary)) {
        pthread_mutex_unlock(&g_shm_lock);
        nvlog("shmirror: no VRAM for the bitmaps of a %zu-byte allocation - this allocation is twinned but NOT tracked (unsafe)", len);
        return -1;
    }
    r->zero_owed = 1;
    const uint64_t e = SHM_TAB_L1 + (uint64_t)idx * SHM_ENTRY;
    shm_w64(e + 0, va); shm_w64(e + 8, len); shm_w64(e + 16, nvmtl_vk_buffer_address(&r->bitmap));
    shm_w64(e + 24, nvmtl_vk_buffer_address(&r->summary)); shm_w64(e + 32, shadow); shm_w64(e + 40, r->tmap ? nvmtl_vk_buffer_address(&r->touched) : 0);
    for (uint64_t a = va; a < va + len; a += SHM_L2) {
        const uint32_t g = (uint32_t)(a >> 30);
        uint32_t l1 = *(volatile uint32_t *)(g_shm_tmap + (uint64_t)g * 4);
        if (!l1) {
            if (g_shm_l2_used >= SHM_MAX_L2) { nvlog("shmirror: out of level-2 pages - part of an allocation is not tracked (unsafe)"); break; }
            l1 = SHM_TAB_L1 + SHM_MAX_RANGES * SHM_ENTRY + g_shm_l2_used++ * SHM_L2;
            shm_w32((uint64_t)g * 4, l1);
        }
        shm_w32(l1 + ((a >> 16) & 16383) * 4, (uint32_t)idx + 1);
    }
    const uint32_t gran = (uint32_t)((chunks + 131071) / 131072); if (gran > g_shm_max_granules) g_shm_max_granules = gran;
    atomic_store(&r->live, 1);
    if (idx == n) atomic_store(&g_shm_n, n + 1);
    atomic_store(&g_shm_dirty_any, 1);
    pthread_mutex_unlock(&g_shm_lock);
    nvmtl_shw_install();
    nvmtl_pre_submit_hook = nvmtl_presubmit;
    atomic_fetch_add(&g_shm_adopted, 1); atomic_fetch_add(&g_shm_adopt_bytes, len);
    const unsigned long long k = atomic_load(&g_shm_adopted);
    if (k <= 4 || !(k & (k - 1))) { nvlog("shmirror: adopted %zu bytes (GPU 0x%llx now VRAM, system pages at GPU 0x%llx, entry %d)", len, (unsigned long long)va, (unsigned long long)shadow, idx); shm_census("adopt"); }
    return 0;
}
// the allocation is being freed (no GPU work uses it any more)
// NVMTL_SHM_HEAP_DIAG=noslots: the heap's level-2 slots cleared (stores into it are not noted, nothing copied back);
// =nocopyback: noted as usual, but the copy-back kernel skips the entry (shadow 0)
static void shm_heap_diag(shm_range *r, int i)
{
    const char *e = getenv("NVMTL_SHM_HEAP_DIAG"); if (!e) return;
    if (!strcmp(e, "noslots")) {
        for (uint64_t a = r->va; a < r->va + r->len; a += SHM_L2) { const uint32_t l1 = *(volatile uint32_t *)(g_shm_tmap + (a >> 30) * 4); if (l1) shm_w32(l1 + ((a >> 16) & 16383) * 4, 0); }
        nvlog("shmirror: DIAGNOSTIC heap entry %d: level-2 slots cleared - stores into it are not noted", i);
    } else if (!strcmp(e, "nocopyback")) {
        shm_w64(SHM_TAB_L1 + (uint64_t)i * SHM_ENTRY + 32, 0);
        nvlog("shmirror: DIAGNOSTIC heap entry %d: shadow 0 - the copy-back kernel skips it", i);
    }
}
// ---- giving VRAM back --------------------------------------------------------------------------------------------------
// shmirror's VRAM copies are an optimisation; the app's own resources need the card first (run 439: 2560x1600 Cyberpunk
// fell to 3 fps when the twins took 512 MB and the gate sent Private buffers and textures to system memory). With the
// GPU idle every copy-back has landed, so the system pages hold everything: the GPU address goes back to them, the VRAM
// copy is freed, and the range is no longer tracked. Largest first; after the first eviction nothing more is adopted.
static uint64_t shm_evict(uint64_t need, const char *why)
{
    if (g_shm_ready != 1 || !pnvk_memory_untwin || !need) return 0;
    if (t_shm_in_prologue) { atomic_fetch_add(&g_shm_evict_pending, need); return 0; }   // its uploads still name these ranges
    pthread_mutex_lock(&nvmtl_submit_mutex);
    if (pthread_mutex_trylock(&g_shm_lock)) { pthread_mutex_unlock(&nvmtl_submit_mutex); return 0; }   // adopting right now (maybe on this thread)
    uint64_t freed = 0; int idled = 0;
    while (freed < need) {
        const int n = atomic_load(&g_shm_n); int best = -1; size_t bl = 0;
        for (int i = 0; i < n; i++) if (atomic_load(&g_shm[i].live) && g_shm[i].mem && g_shm[i].len > bl) { best = i; bl = g_shm[i].len; }
        if (best < 0) break;
        if (!idled) { pvkDeviceWaitIdle(g_dev); idled = 1; }
        shm_range *r = &g_shm[best];
        if (pnvk_memory_untwin(r->mem)) { nvlog("shmirror: could not release the VRAM copy of a %zu MB range - it stays", r->len >> 20); break; }
        // the GPU address is the system pages again: stop protecting before the fault handler stops answering for them
        mprotect((void *)r->cpu, r->len, PROT_READ | PROT_WRITE);
        atomic_store(&r->live, 0);
        for (uint64_t a = r->va; a < r->va + r->len; a += SHM_L2) {
            const uint32_t l1 = *(volatile uint32_t *)(g_shm_tmap + (a >> 30) * 4);
            if (l1) shm_w32(l1 + ((a >> 16) & 16383) * 4, 0);
        }
        shm_w64(SHM_TAB_L1 + (uint64_t)best * SHM_ENTRY + 8, 0);
        nvmtl_vk_buffer_destroy(&r->bitmap); nvmtl_vk_buffer_destroy(&r->summary);
        if (r->touched.buf) nvmtl_vk_buffer_destroy(&r->touched);
        r->tmap = NULL;
        if (r->dsnap) { munmap(r->dsnap, r->len); r->dsnap = NULL; } free(r->dsnapped); r->dsnapped = NULL;
        r->mem = NULL;   // the app still owns the memory; its destruction finds nothing to forget
        freed += r->len; atomic_fetch_add(&g_shm_evict_bytes, r->len); atomic_fetch_add(&g_shm_evict_n, 1);
        nvlog("shmirror: VRAM copy of a %zu MB range given back (%s) - %llu MB given back so far; nothing more is adopted",
              r->len >> 20, why, (unsigned long long)(atomic_load(&g_shm_evict_bytes) >> 20));
    }
    if (freed) { atomic_store(&g_shm_evicted_any, 1); g_budget_stale = 1; }
    pthread_mutex_unlock(&g_shm_lock); pthread_mutex_unlock(&nvmtl_submit_mutex);
    return freed;
}
// the timer (every 500 ms): give room back before the gate has to refuse anything
static void shm_vram_watch(void)
{
    if (g_shm_ready != 1 || !atomic_load(&g_shm_adopted)) return;
    uint64_t fv = 0, bd = 0, us = 0; int ms = 0;
    nvmtl_vk_vram_wall0(0, &fv, &bd, &us, &ms);
    {   // NVMTL_SHM_EVICT_AFTER_S=<s> (test): give every twin back <s> seconds after the first adoption
        static double after = -2; static uint64_t t0; if (after == -2) { const char *e = getenv("NVMTL_SHM_EVICT_AFTER_S"); after = e ? atof(e) : -1; }
        const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); if (!t0) t0 = now;
        if (after >= 0 && (now - t0) / 1e9 >= after && !atomic_load(&g_shm_evicted_any)) { shm_evict(~0ull >> 1, "NVMTL_SHM_EVICT_AFTER_S test"); return; }
    }
    // an eviction the gate asked for while a prologue ran on that thread (it could not happen there) is done here
    const uint64_t pend = atomic_exchange(&g_shm_evict_pending, 0);
    if (pend) shm_evict(pend, "deferred from a prologue");
}
// bisection: bytes [off, off+len) of an adopted allocation are read by the GPU from the system pages again
void nvmtl_shm_sysmem_window(void *mem, size_t off, size_t len)
{
    pthread_mutex_lock(&nvmtl_submit_mutex); pthread_mutex_lock(&g_shm_lock);
    const int n = atomic_load(&g_shm_n);
    for (int i = 0; i < n; i++) {
        shm_range *r = &g_shm[i];
        if (r->mem != mem) continue;
        r->sys_lo = off / SHM_PAGE; r->sys_hi = (off + len) / SHM_PAGE;
        for (size_t q = r->sys_lo; q < r->sys_hi; q++) __atomic_store_n(&r->dirty[q], 0, __ATOMIC_RELEASE);
        mprotect((void *)(r->cpu + r->sys_lo * SHM_PAGE), (r->sys_hi - r->sys_lo) * SHM_PAGE, PROT_READ | PROT_WRITE);
        nvlog("shmirror: pages %zu..%zu of entry %d are system memory for the GPU - not protected, not uploaded", r->sys_lo, r->sys_hi, i);
        shm_heap_diag(r, i);
    }
    pthread_mutex_unlock(&g_shm_lock); pthread_mutex_unlock(&nvmtl_submit_mutex);
}
void nvmtl_shm_forget(void *mem)
{
    if (g_shm_ready != 1 || !mem) return;
    pthread_mutex_lock(&g_shm_lock);
    const int n = atomic_load(&g_shm_n);
    for (int i = 0; i < n; i++) {
        shm_range *r = &g_shm[i];
        if (r->mem != mem) continue;
        atomic_store(&r->live, 0);
        while (atomic_load(&g_shm_scanning)) sched_yield();   // a prologue may still be reading this range's dirty marks
        if (g_shm_async) {   // an upload batch may still copy into this memory: it is freed when this returns
            uint64_t want = atomic_load(&g_shm_upub);
            if (want) { VkSemaphoreWaitInfo wi = { VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO, NULL, 0, 1, &g_shm_semU, &want }; pvkWaitSemaphores(g_dev, &wi, 5000000000ull); }
        }
        for (uint64_t a = r->va; a < r->va + r->len; a += SHM_L2) {
            const uint32_t l1 = *(volatile uint32_t *)(g_shm_tmap + (a >> 30) * 4);
            if (l1) shm_w32(l1 + ((a >> 16) & 16383) * 4, 0);
        }
        shm_w64(SHM_TAB_L1 + (uint64_t)i * SHM_ENTRY + 8, 0);   // length 0: the copy-back kernel skips it
        mprotect((void *)r->cpu, r->len, PROT_READ | PROT_WRITE);
        free((void *)r->dirty); r->dirty = NULL; free(r->stamp); r->stamp = NULL;
        // the bitmaps stay allocated: an in-flight epilogue may still read them; they are reused by the next adoption
        r->mem = NULL;
        break;
    }
    pthread_mutex_unlock(&g_shm_lock);
}

// ---- CPU writes ------------------------------------------------------------------------------------------------------
// called first by the SIGBUS/SIGSEGV handler; 1 = a CPU write to adopted memory, handled
int nvmtl_shm_fault(uintptr_t a)
{
    if (g_shm_probe && a >= (uintptr_t)g_shm_probe && a < (uintptr_t)g_shm_probe + 64 * SHM_PAGE) {
        mprotect((void *)(a & ~(uintptr_t)(SHM_PAGE - 1)), SHM_PAGE, PROT_READ | PROT_WRITE); atomic_fetch_add(&g_shm_probe_faults, 1); return 1;
    }
    const int n = atomic_load_explicit(&g_shm_n, memory_order_acquire);
    for (int i = 0; i < n; i++) {
        shm_range *r = &g_shm[i];
        if (a < r->cpu || a >= r->cpu + r->len || !atomic_load_explicit(&r->live, memory_order_acquire)) continue;
        const uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        const size_t pg = (a - r->cpu) / SHM_PAGE;
        // unprotect FIRST, then mark: the prologue takes the mark and then protects. Marked first, a prologue that took
        // the mark and protected the page in between left it writable and unmarked after this mprotect - every later
        // CPU write to it was lost (the audit found such pages in Cyberpunk: stale constants, frames drawn wrong).
        if (mprotect((void *)(r->cpu + pg * SHM_PAGE), SHM_PAGE, PROT_READ | PROT_WRITE)) return 0;
        __atomic_store_n(&r->dirty[pg], 1, __ATOMIC_RELEASE); atomic_store_explicit(&g_shm_dirty_any, 1, memory_order_release);
        atomic_fetch_add_explicit(&g_shm_faults, 1, memory_order_relaxed);
        const uint32_t f = atomic_load_explicit(&nvmtl_flick_frame, memory_order_relaxed) + 1;
        if (r->stamp && r->stamp[pg] != f) { r->stamp[pg] = f; atomic_fetch_add_explicit(&g_shm_fault_pages, 1, memory_order_relaxed); }
        const uintptr_t me = (uintptr_t)pthread_self();
        for (int k = 0; k < SHM_TH; k++) {
            uintptr_t cur = atomic_load_explicit(&g_shm_th[k].id, memory_order_relaxed);
            if (!cur && atomic_compare_exchange_strong(&g_shm_th[k].id, &cur, me)) cur = me;
            if (cur == me) { atomic_fetch_add_explicit(&g_shm_th[k].n, 1, memory_order_relaxed); break; }
        }
        atomic_fetch_add_explicit(&g_shm_fault_ns, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0, memory_order_relaxed);
        return 1;
    }
    return 0;
}
// ---- uploads on the copy-engine queue (NVMTL_SHM_ASYNC, default on) ----------------------------------------------------
// The dirty-page uploads used to head the next part on the graphics queue, which is in order: they started only once
// every part before them had finished, and the GPU stood still while they ran (3-5 ms a frame in Cyberpunk). They now go
// to the copy engine's own queue and overlap the graphics work still in flight. Two timeline semaphores keep the order:
//  G - a part that may write Shared memory (its epilogue copies GPU writes back to the system pages) signals
//      G = ++g_shm_gval. An upload batch first waits G >= g_shm_gval: the system pages it copies from hold every GPU
//      write by then, and a whole-page upload cannot overwrite a GPU write that is still being made.
//  U - an upload batch signals U = ++g_shm_uval; the next graphics part waits U >= g_shm_uval (the graphics queue is in
//      order, so only the first part after a batch waits).
// Parts submitted before a batch may still run while it copies: they only read the pages it writes (writers are waited
// for), and the bytes of a page the CPU did not write are the same on both sides - what such a part sees is what it
// would see on unified memory, where the CPU's write lands in the very memory the GPU reads.
static uint64_t g_shm_gval, g_shm_gwaited, g_shm_uval, g_shm_uwaited;   // under nvmtl_submit_mutex
static VkCommandPool g_shm_upool; static VkCommandBuffer g_shm_ucb[SHM_UCB]; static uint64_t g_shm_ucb_val[SHM_UCB]; static unsigned g_shm_ucb_next;
static void shm_async_setup(void)
{
    const char *e = getenv("NVMTL_SHM_ASYNC");
    if (e && e[0] == '0') { nvlog("shmirror: uploads on the graphics queue (NVMTL_SHM_ASYNC=0)"); return; }
    if (!atomic_load(&g_xon) || !g_timeline || !pvkCreateSemaphore || !pvkWaitSemaphores || !pvkGetSemaphoreCounterValue) {
        nvlog("shmirror: uploads on the graphics queue - copy-engine queue %s, timeline semaphores %s", atomic_load(&g_xon) ? "up" : "ABSENT", g_timeline ? "yes" : "NO");
        return;
    }
    VkSemaphoreTypeCreateInfo ti = { VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO, NULL, VK_SEMAPHORE_TYPE_TIMELINE, 0 };
    VkSemaphoreCreateInfo sci = { VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, &ti, 0 };
    VkCommandPoolCreateInfo pci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL, VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, g_xfam };
    VkCommandBufferAllocateInfo ai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, VK_NULL_HANDLE, VK_COMMAND_BUFFER_LEVEL_PRIMARY, SHM_UCB };
    VkResult r = pvkCreateSemaphore(g_dev, &sci, NULL, &g_shm_semG);
    if (r == VK_SUCCESS) r = pvkCreateSemaphore(g_dev, &sci, NULL, &g_shm_semU);
    if (r == VK_SUCCESS) r = pvkCreateCommandPool(g_dev, &pci, NULL, &g_shm_upool);
    if (r == VK_SUCCESS) { ai.commandPool = g_shm_upool; r = pvkAllocateCommandBuffers(g_dev, &ai, g_shm_ucb); }
    if (r != VK_SUCCESS) { nvlog("shmirror: copy-queue upload setup FAILED (%d) - uploads stay on the graphics queue", r); return; }
    g_shm_async = 1;
    nvlog("shmirror: uploads on the copy-engine queue (family %u), ordered by timeline semaphores", g_xfam);
}
static VkCommandBuffer shm_ucb_begin(unsigned *slot)
{
    const unsigned i = g_shm_ucb_next;
    if (g_shm_ucb_val[i]) {   // this command buffer's last batch must have finished
        uint64_t v = 0;
        if (pvkGetSemaphoreCounterValue(g_dev, g_shm_semU, &v) != VK_SUCCESS) return VK_NULL_HANDLE;
        if (v < g_shm_ucb_val[i]) {
            atomic_fetch_add(&g_shm_async_reuse_waits, 1);
            VkSemaphoreWaitInfo wi = { VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO, NULL, 0, 1, &g_shm_semU, &g_shm_ucb_val[i] };
            if (pvkWaitSemaphores(g_dev, &wi, 5000000000ull) != VK_SUCCESS) return VK_NULL_HANDLE;
        }
    }
    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    if (pvkResetCommandBuffer(g_shm_ucb[i], 0) != VK_SUCCESS || pvkBeginCommandBuffer(g_shm_ucb[i], &bi) != VK_SUCCESS) return VK_NULL_HANDLE;
    *slot = i; g_shm_ucb_next = (i + 1) % SHM_UCB;   // a prologue may have two open (diff and whole-page)
    return g_shm_ucb[i];
}
static int shm_ucb_submit(unsigned slot, int waitg)
{
    VkCommandBuffer cb = g_shm_ucb[slot];
    if (pvkEndCommandBuffer(cb) != VK_SUCCESS) return -1;
    const uint32_t wg = waitg && !shm_diag("NVMTL_SHM_DIAG_NOGWAIT") && g_shm_gval > g_shm_gwaited;   // diagnostic: no wait for writer parts (GPU writes in uploaded pages can be LOST)
    const uint64_t wv = g_shm_gval, sv = g_shm_uval + 1;
    const VkPipelineStageFlags ws = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    VkTimelineSemaphoreSubmitInfo ts = { VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO, NULL, wg, wg ? &wv : NULL, 1, &sv };
    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, &ts, wg, wg ? &g_shm_semG : NULL, wg ? &ws : NULL, 1, &cb, 1, &g_shm_semU };
    pthread_mutex_lock(&g_xqlock);
    const VkResult r = g_state == 1 ? pvkQueueSubmit(g_xqueue, 1, &si, VK_NULL_HANDLE) : VK_ERROR_DEVICE_LOST;
    pthread_mutex_unlock(&g_xqlock);
    if (r != VK_SUCCESS) { static int said; if (said++ < 8) nvlog("shmirror: copy-queue upload submit -> %d", r); return -1; }
    if (wg) { g_shm_gwaited = wv; atomic_fetch_add(&g_shm_async_gwaits, 1); }
    g_shm_uval = sv; atomic_store(&g_shm_upub, sv); g_shm_ucb_val[slot] = sv;
    atomic_fetch_add(&g_shm_async_batches, 1);
    return 0;
}
// submit_begin, under nvmtl_submit_mutex: the graphics part c waits for the latest upload batch and, if it may write
// Shared memory, signals G
void nvmtl_shm_part_sync(nvk_cmdbuf *c, nvmtl_shm_qsub *q, VkSubmitInfo *si)
{
    memset(q, 0, sizeof *q);
    const int writer = c->shm_writer; c->shm_writer = 0;
    if (!g_shm_async) return;
    q->wait = g_shm_uval > g_shm_uwaited; q->sig = writer; q->csig = g_stg_used && g_shm_semC;
    if (!q->wait && !q->sig && !q->csig) return;
    q->wv = g_shm_uval; q->sv = g_shm_gval + 1; q->cv = g_shm_cval + 1; q->ws = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    unsigned ns = 0;
    if (q->sig) { q->sems[ns] = g_shm_semG; q->svs[ns++] = q->sv; }
    if (q->csig) { q->sems[ns] = g_shm_semC; q->svs[ns++] = q->cv; }   // this part consumed staged uploads: their ring chunks free up with it
    q->ts = (VkTimelineSemaphoreSubmitInfo){ VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO, si->pNext, q->wait ? 1u : 0u, q->wait ? &q->wv : NULL,
                                             ns, ns ? q->svs : NULL };
    si->pNext = &q->ts;
    if (q->wait) { si->waitSemaphoreCount = 1; si->pWaitSemaphores = &g_shm_semU; si->pWaitDstStageMask = &q->ws; }
    if (ns) { si->signalSemaphoreCount = ns; si->pSignalSemaphores = q->sems; }
}
void nvmtl_shm_part_submitted(const nvmtl_shm_qsub *q, VkResult r)
{
    if (r != VK_SUCCESS) return;
    if (q->wait) { g_shm_uwaited = q->wv; atomic_fetch_add(&g_shm_async_uwaits, 1); }
    if (q->sig) { g_shm_gval = q->sv; atomic_fetch_add(&g_shm_gsigs, 1); }
    if (q->csig) { g_shm_cval = q->cv; g_stg_used = 0; }
}

// ---- staged scatter uploads (NVMTL_SHM_STAGE=1, experiment, OFF: notes item 91) -------------------------------------
// The scatter used to read every changed run across Thunderbolt from the system pages, in the part's prologue on the
// graphics queue: run 466 measured 4.7 ms a frame of prologue GPU time (3.5-6 MB, ~1 GB/s), the GPU doing nothing else.
// Runs of pages the GPU never wrote now go through a staging ring instead: the CPU copies them into host memory (the bytes
// it compared against its snapshot a moment ago), one copy-engine copy moves the span to a VRAM ring on the copy queue -
// overlapping the graphics work still queued - and the prologue's scatter reads VRAM. The part waits for the copy by
// semaphore U and signals C; a ring chunk is reused only once the part that read it signalled. Whole pages (the GPU wrote
// them: their system pages take earlier parts' copy-backs) still go from the system pages, ordered on the graphics queue.
#define SHM_STG_BYTES (64ull << 20)
#define SHM_STG_CHUNK (1ull << 20)
static nvk_buffer g_stg_h, g_stg_v; static uint64_t g_stg_va; static int g_stg_state;   // 0 untried, 1 ready, -1 off
static uint64_t g_stg_at, g_stg_b0; static VkBufferCopy g_stg_reg[2]; static unsigned g_stg_nreg;
static uint64_t g_stg_needC[SHM_STG_BYTES / SHM_STG_CHUNK];
static _Atomic unsigned long long g_stg_bytes, g_stg_batches, g_stg_waits, g_stg_fail;
static int stg_ready(void)
{
    if (g_stg_state) return g_stg_state > 0;
    g_stg_state = -1;
    const char *e = getenv("NVMTL_SHM_STAGE");
    if (!(e && e[0] == '1')) { nvlog("shmirror: staged uploads off (NVMTL_SHM_STAGE=1 turns them on: run 468, the prologue's GPU time fell 4.7 -> 1.4 ms a frame but the parts ran 2.6 ms longer beside the copy engine - no fps gain)"); return 0; }
    if (!g_shm_async) { nvlog("shmirror: staged uploads off - no copy-engine queue"); return 0; }
    VkSemaphoreTypeCreateInfo ti = { VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO, NULL, VK_SEMAPHORE_TYPE_TIMELINE, 0 };
    VkSemaphoreCreateInfo sci = { VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, &ti, 0 };
    if (pvkCreateSemaphore(g_dev, &sci, NULL, &g_shm_semC) != VK_SUCCESS) { g_shm_semC = VK_NULL_HANDLE; nvlog("shmirror: staged uploads off - no semaphore"); return 0; }
    if (nvmtl_vk_buffer_create(SHM_STG_BYTES, 1, &g_stg_h) || !g_stg_h.map || nvmtl_vk_buffer_create(SHM_STG_BYTES, 0, &g_stg_v) || g_stg_v.sysmem
        || !(g_stg_va = nvmtl_vk_buffer_address(&g_stg_v))) {
        if (g_stg_h.buf) nvmtl_vk_buffer_destroy(&g_stg_h);
        if (g_stg_v.buf) nvmtl_vk_buffer_destroy(&g_stg_v);
        nvlog("shmirror: staged uploads off - no %llu MB staging rings", SHM_STG_BYTES >> 20); return 0; }
    g_stg_state = 1;
    nvlog("shmirror: staged uploads ON - changed runs go host ring -> copy engine -> VRAM ring (%llu MB each) -> scatter (NVMTL_SHM_STAGE=%s)",
          SHM_STG_BYTES >> 20, e ? e : "unset");
    return 1;
}
// ring offset for n bytes of this prologue's span, ~0 when staging cannot take them (then they go the old way)
static uint64_t stg_claim(size_t n)
{
    n = (n + 15) & ~(size_t)15;
    if (n > SHM_STG_CHUNK) return ~0ull;
    if (g_stg_at + n > SHM_STG_BYTES) {
        if (g_stg_nreg >= 1) return ~0ull;   // a second wrap in one prologue (64 MB): the rest goes the old way
        if (g_stg_at > g_stg_b0) g_stg_reg[g_stg_nreg++] = (VkBufferCopy){ g_stg_b0, g_stg_b0, g_stg_at - g_stg_b0 };
        g_stg_at = g_stg_b0 = 0;
    }
    // only chunks the ring enters now: the one it is already in was checked when it entered (its mark is this lap's)
    for (uint64_t c = g_stg_at / SHM_STG_CHUNK + (g_stg_at % SHM_STG_CHUNK ? 1 : 0); c <= (g_stg_at + n - 1) / SHM_STG_CHUNK; c++) {
        if (!g_stg_needC[c]) continue;
        uint64_t v = 0; pvkGetSemaphoreCounterValue(g_dev, g_shm_semC, &v);
        if (v < g_stg_needC[c]) {   // the part that read this chunk last time round has not finished
            atomic_fetch_add(&g_stg_waits, 1);
            VkSemaphoreWaitInfo wi = { VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO, NULL, 0, 1, &g_shm_semC, &g_stg_needC[c] };
            if (pvkWaitSemaphores(g_dev, &wi, 2000000000ull) != VK_SUCCESS) return ~0ull;
        }
    }
    const uint64_t o = g_stg_at; g_stg_at += n; return o;
}
// end of a prologue: the copy-engine copy of its span(s); on failure the same copy heads the prologue on the graphics queue
static void stg_close(void)
{
    if (g_stg_at > g_stg_b0) g_stg_reg[g_stg_nreg++] = (VkBufferCopy){ g_stg_b0, g_stg_b0, g_stg_at - g_stg_b0 };
    if (!g_stg_nreg) return;
    unsigned long long tot = 0;
    for (unsigned i = 0; i < g_stg_nreg; i++) {
        tot += g_stg_reg[i].size;
        for (uint64_t c = g_stg_reg[i].srcOffset / SHM_STG_CHUNK; c <= (g_stg_reg[i].srcOffset + g_stg_reg[i].size - 1) / SHM_STG_CHUNK; c++) g_stg_needC[c] = g_shm_cval + 1;
    }
    unsigned slot = 0; VkCommandBuffer ucb = shm_ucb_begin(&slot);
    if (ucb) pvkCmdCopyBuffer(ucb, (VkBuffer)g_stg_h.buf, (VkBuffer)g_stg_v.buf, g_stg_nreg, g_stg_reg);
    if (!ucb || shm_ucb_submit(slot, 0)) {
        atomic_fetch_add(&g_stg_fail, 1);
        for (unsigned i = 0; i < g_stg_nreg; i++) nvmtl_vk_pre_copy(&g_stg_h, g_stg_reg[i].srcOffset, &g_stg_v, g_stg_reg[i].dstOffset, g_stg_reg[i].size);
        static int said; if (said++ < 4) nvlog("shmirror: staged upload copy FAILED on the copy queue - copied at the head of the part instead");
    }
    g_stg_used = 1; g_stg_nreg = 0; g_stg_b0 = g_stg_at;
    const unsigned long long b = atomic_fetch_add(&g_stg_bytes, tot) + tot, k = atomic_fetch_add(&g_stg_batches, 1) + 1;
    if (!(k & (k - 1)) && k >= 64) nvlog("shmirror: staged uploads - %llu batches, %llu MB, %llu waits for a ring chunk, %llu copy-queue failures",
                                          k, b >> 20, (unsigned long long)atomic_load(&g_stg_waits), (unsigned long long)atomic_load(&g_stg_fail));
}
// scatter list for this prologue: entries [g_shm_sc_first, g_shm_list_at) of the ring
static uint32_t g_shm_sc_first, g_shm_sc_n;
static void shm_scatter_flush(void);
static void shm_scatter_add(uint64_t src, uint64_t dst, uint32_t words)
{
    const uint32_t cap = SHM_LIST_BYTES / 32;
    if (g_shm_list_at >= cap) { shm_scatter_flush(); g_shm_list_at = 0; g_shm_sc_first = 0; }   // wrap: entries of parts long done
    volatile uint64_t *e = (volatile uint64_t *)((uint8_t *)g_shm_list.map + (size_t)g_shm_list_at * 32);
    e[0] = src; e[1] = dst; e[2] = words; e[3] = 0;
    g_shm_list_at++; g_shm_sc_n++;
    atomic_fetch_add(&g_shm_sc_entries, 1); atomic_fetch_add(&g_shm_sc_bytes, (unsigned long long)words * 4);
}
// a blit run's held copies (nvmtl_blq_flush) as one scatter dispatch in the recording itself; -1: copy them the old way.
// Their list goes to a ring of its own (4 MB, 131072 entries: hundreds of frames before it comes round).
static nvk_buffer g_blq; static uint32_t g_blq_at; static pthread_mutex_t g_blq_lock = PTHREAD_MUTEX_INITIALIZER;
static int shm_blit_scatter(nvk_cmdbuf *c)
{
    enum { BLQ_BYTES = 4u << 20, BLQ_N = BLQ_BYTES / 32 };
    if (g_shm_ready != 1 || !g_shm_scatter_pipe || !c->bl_nq || c->bl_nq > BLQ_N || c->in_rp) return -1;
    pthread_mutex_lock(&g_blq_lock);
    if (!g_blq.map && (nvmtl_vk_buffer_create(BLQ_BYTES, 1, &g_blq) || !g_blq.map)) { pthread_mutex_unlock(&g_blq_lock); return -1; }
    if (g_blq_at + c->bl_nq > BLQ_N) g_blq_at = 0;
    const uint32_t at = g_blq_at; g_blq_at += c->bl_nq;
    pthread_mutex_unlock(&g_blq_lock);
    volatile uint64_t *e = (volatile uint64_t *)((uint8_t *)g_blq.map + (size_t)at * 32);
    for (unsigned i = 0; i < c->bl_nq; i++, e += 4) { e[0] = c->bl_q[i][5]; e[1] = c->bl_q[i][6]; e[2] = c->bl_q[i][4] / 4; e[3] = 0; }
    g_shm_real_bind(c->cb, VK_PIPELINE_BIND_POINT_COMPUTE, g_shm_scatter_pipe);
    struct { uint64_t list; uint32_t count, pad; } pc = { nvmtl_vk_buffer_address(&g_blq) + (uint64_t)at * 32, c->bl_nq, 0 };
    pvkCmdPushConstants(c->cb, g_shm_playout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof pc, &pc);
    pvkCmdDispatch(c->cb, c->bl_nq, 1, 1);
    return 0;
}
// record the entries gathered so far as dispatches in this part's prologue command buffer
static void shm_scatter_flush(void)
{
    if (!g_shm_sc_n) return;
    nvmtl_prologue *p = g_pre_cur;
    if (!p || !p->begun) { g_shm_sc_n = 0; return; }   // cannot happen: the prologue was opened first
    VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_MEMORY_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT };
    pvkCmdPipelineBarrier(p->cb.cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
    g_shm_real_bind(p->cb.cb, VK_PIPELINE_BIND_POINT_COMPUTE, g_shm_scatter_pipe);
    const uint64_t base = nvmtl_vk_buffer_address(&g_shm_list);
    for (uint32_t done = 0; done < g_shm_sc_n; ) {
        const uint32_t n = MIN(g_shm_sc_n - done, 65535u);
        struct { uint64_t list; uint32_t count, pad; } pc = { base + (uint64_t)(g_shm_sc_first + done) * 32, n, 0 };
        pvkCmdPushConstants(p->cb.cb, g_shm_playout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof pc, &pc);
        pvkCmdDispatch(p->cb.cb, n, 1, 1);
        done += n; atomic_fetch_add(&g_shm_sc_disp, 1);
    }
    p->n++;   // the prologue's closing barrier (compute writes included) makes them visible to the part
    g_shm_sc_first = g_shm_list_at; g_shm_sc_n = 0;
}
// the pre-submit prologue (nvmtl_presubmit): clear new bitmaps, upload every page the CPU wrote
typedef struct { shm_range *r; uint64_t off, sz; } shm_run;
void nvmtl_shm_prologue(void)
{
    if (g_shm_ready != 1 || !atomic_load(&g_shm_n) || !atomic_exchange(&g_shm_dirty_any, 0)) return;   // nothing written since the last scan
    if (!nvmtl_vk_pre_open()) { atomic_store(&g_shm_dirty_any, 1); return; }
    const uint64_t pt0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); uint64_t prot_ns = 0, prot_calls = 0;
    t_shm_in_prologue = 1;
    static shm_run *runs_v; static size_t runs_cap;   // under nvmtl_submit_mutex
    size_t nrun = 0;
    VkCommandBuffer ucb = VK_NULL_HANDLE, ucbA = VK_NULL_HANDLE; unsigned uslot = 0, uslotA = 0;   // B: whole pages after the writers; A: changed words, no wait
    atomic_store(&g_shm_scanning, 1);
    const int n = atomic_load(&g_shm_n);
    unsigned long long bytes = 0, runs = 0;
    for (int i = 0; i < n; i++) {
        shm_range *r = &g_shm[i];
        if (!atomic_load(&r->live)) continue;
        if (r->zero_owed) { nvmtl_vk_pre_fill(&r->bitmap, 0, r->bitmap_len, 0); nvmtl_vk_pre_fill(&r->summary, 0, r->summary_len, 0); r->zero_owed = 0; }
        volatile uint8_t *d = r->dirty; const size_t pages = r->len / SHM_PAGE;
        for (size_t k = 0; k < pages; ) {
            if (k >= r->sys_lo && k < r->sys_hi) { k = r->sys_hi; continue; }
            if (!d[k] || !__atomic_exchange_n(&d[k], 0, __ATOMIC_ACQ_REL)) { k++; continue; }
            size_t e = k + 1;
            while (e < pages && d[e] && __atomic_exchange_n(&d[e], 0, __ATOMIC_ACQ_REL)) e++;
            const uint64_t m0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            const int mr = mprotect((void *)(r->cpu + k * SHM_PAGE), (e - k) * SHM_PAGE, PROT_READ);
            prot_ns += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - m0; prot_calls++;
            if (mr) {   // protect first: later writes fault again
                static int said; if (said++ < 8) nvlog("shmirror: mprotect(READ) of %zu pages FAILED (errno %d) - those pages are uploaded every time", e - k, errno);
                for (size_t q = k; q < e; q++) __atomic_store_n(&d[q], 1, __ATOMIC_RELEASE);
                atomic_store(&g_shm_dirty_any, 1);
            }
            const uint64_t off = (uint64_t)k * SHM_PAGE, sz = (uint64_t)(e - k) * SHM_PAGE;
            if (shm_diag("NVMTL_SHM_DIAG_NOUP")) { k = e; continue; }
            if (shm_diag("NVMTL_SHM_SNAP")) {   // diagnostic: the bytes as uploaded, to find GPU writes never copied back
                if (!r->snap) { void *m = mmap(NULL, r->len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); r->snap = m == MAP_FAILED ? NULL : m; }
                if (r->snap && !r->snapped) r->snapped = calloc(pages, 1);
                if (r->snap && r->snapped) for (size_t q = k; q < e; q++) {   // how much of a re-uploaded page really changed
                    const uint8_t *cur = (const uint8_t *)(r->cpu + q * SHM_PAGE), *old = r->snap + q * SHM_PAGE;
                    if (r->snapped[q]) {
                        unsigned long long ch = 0, runs = 0; unsigned last = 0; int in = 0;
                        for (unsigned o = 0; o < SHM_PAGE; o += 16) {
                            const int d = memcmp(cur + o, old + o, 16) != 0;
                            if (d) { ch += 16; if (!in && (runs == 0 || o - last > 256)) runs++; in = 1; last = o; } else in = 0;
                        }
                        atomic_fetch_add(&g_shm_diff_pages, 1); atomic_fetch_add(&g_shm_diff_bytes, ch); atomic_fetch_add(&g_shm_diff_runs, runs);
                    }
                    memcpy(r->snap + q * SHM_PAGE, cur, SHM_PAGE); r->snapped[q] = 1;
                }
            }
            if (shm_verify_ms() > 0) {   // diagnostic: remember what went up, to catch CPU writes that never faulted
                if (!r->uphash) r->uphash = calloc(pages, sizeof *r->uphash);
                if (r->uphash) for (size_t q = k; q < e; q++) r->uphash[q] = shm_page_hash((const uint64_t *)(r->cpu + q * SHM_PAGE)) | 1;
            }   // diagnostic: measure the upload cost (frames are WRONG)
            const int scat = shm_scatter_on() && g_shm_scatter_pipe && (g_shm_list.map || (!nvmtl_vk_buffer_create(SHM_LIST_BYTES, 1, &g_shm_list) && g_shm_list.map));
            if ((scat || (g_shm_async && shm_diff_on())) && !r->tmap && !r->touched.buf) {
                // the GPU-written marks, made here and not at adoption (which runs inside a buffer creation that holds the
                // allocator's lock): until a page has gone up whole once with the marks in place, it keeps going whole
                if (!nvmtl_vk_buffer_create(pages * 4, 1, &r->touched) && r->touched.map) {
                    memset(r->touched.map, 0, pages * 4); __atomic_thread_fence(__ATOMIC_SEQ_CST);
                    shm_w64(SHM_TAB_L1 + (uint64_t)i * SHM_ENTRY + 40, nvmtl_vk_buffer_address(&r->touched));
                    r->tmap = r->touched.map;
                }
            }
            if (scat) {   // compute scatter in this part's prologue: changed words of pages the GPU never wrote, else whole pages
                const int stg = stg_ready();
                if (!r->dsnap) { void *m = mmap(NULL, r->len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); r->dsnap = m == MAP_FAILED ? NULL : m; }
                if (r->dsnap && !r->dsnapped) r->dsnapped = calloc(pages, 1);
                for (size_t q = k; q < e; q++) {
                    uint32_t *cur = (uint32_t *)(r->cpu + q * SHM_PAGE), *old = r->dsnap ? (uint32_t *)(r->dsnap + q * SHM_PAGE) : NULL;
                    const int gpuw = !r->tmap || __atomic_load_n(&r->tmap[q], __ATOMIC_ACQUIRE);
                    if (old && r->dsnapped && r->dsnapped[q] && !gpuw) {
                        for (uint32_t w = 0; w < SHM_PAGE / 4; ) {
                            if (cur[w] == old[w]) { w++; continue; }
                            uint32_t x = w + 1, gap = 0;
                            while (x < SHM_PAGE / 4 && gap <= 16) { if (cur[x] != old[x]) gap = 0; else gap++; x++; }
                            x -= gap;
                            const uint64_t so = stg ? stg_claim((size_t)(x - w) * 4) : ~0ull;
                            if (so != ~0ull) { memcpy((uint8_t *)g_stg_h.map + so, cur + w, (size_t)(x - w) * 4);
                                               shm_scatter_add(g_stg_va + so, r->va + q * SHM_PAGE + (uint64_t)w * 4, x - w); }
                            else shm_scatter_add(r->shadow + q * SHM_PAGE + (uint64_t)w * 4, r->va + q * SHM_PAGE + (uint64_t)w * 4, x - w);
                            memcpy(old + w, cur + w, (size_t)(x - w) * 4);
                            bytes += (x - w) * 4; runs++; w = x;
                        }
                    } else {
                        shm_scatter_add(r->shadow + q * SHM_PAGE, r->va + q * SHM_PAGE, SHM_PAGE / 4);
                        atomic_fetch_add(&g_shm_sc_whole, 1); bytes += SHM_PAGE; runs++;
                        if (old && r->dsnapped && !gpuw) { memcpy(old, cur, SHM_PAGE); r->dsnapped[q] = 1; }
                    }
                }
                k = e; continue;
            }
            if (g_shm_async && shm_diff_on() && r->tmap) {   // per page: changed words (A) or the whole page (B)
                if (!r->dsnap) { void *m = mmap(NULL, r->len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); r->dsnap = m == MAP_FAILED ? NULL : m; }
                if (r->dsnap && !r->dsnapped) r->dsnapped = calloc(pages, 1);
                for (size_t q = k; q < e; q++) {
                    uint32_t *cur = (uint32_t *)(r->cpu + q * SHM_PAGE), *old = r->dsnap ? (uint32_t *)(r->dsnap + q * SHM_PAGE) : NULL;
                    if (old && r->dsnapped && r->dsnapped[q] && !__atomic_load_n(&r->tmap[q], __ATOMIC_ACQUIRE)) {
                        enum { MAXR = 64 }; uint32_t rs[MAXR], re_[MAXR]; unsigned nr = 0, ok = 1;
                        for (uint32_t w = 0; w < SHM_PAGE / 4; ) {
                            if (cur[w] == old[w]) { w++; continue; }
                            uint32_t x = w + 1, gap = 0;
                            while (x < SHM_PAGE / 4 && gap <= 16) { if (cur[x] != old[x]) gap = 0; else gap++; x++; }
                            x -= gap;   // end after the last changed word
                            if (nr == MAXR) { ok = 0; break; }
                            rs[nr] = w; re_[nr] = x; nr++; w = x;
                        }
                        // a copy-back that wrote this page meanwhile marked it first: then the page goes whole, after the writers
                        if (ok && !__atomic_load_n(&r->tmap[q], __ATOMIC_ACQUIRE)) {
                            if (nr && !ucbA) ucbA = shm_ucb_begin(&uslotA);
                            if (!nr || ucbA) {
                                for (unsigned t = 0; t < nr; t++) {
                                    uint64_t o2 = q * SHM_PAGE + (uint64_t)rs[t] * 4, z = (uint64_t)(re_[t] - rs[t]) * 4, s2 = r->shadow + o2, d2 = r->va + o2;
                                    pnvk_cmd_copy_va(ucbA, 1, &s2, &d2, &z);
                                    memcpy(old + rs[t], cur + rs[t], z);
                                    bytes += z; runs++; atomic_fetch_add(&g_shm_dA_bytes, z);
                                }
                                atomic_fetch_add(&g_shm_dA_pages, 1);
                                continue;
                            }
                        }
                    }
                    // whole page, after the last writer part (B); the snapshot follows it for pages the GPU has not written
                    if (!ucb) ucb = shm_ucb_begin(&uslot);
                    if (!ucb) { if (nvmtl_vk_pre_copy_va(r->shadow + q * SHM_PAGE, r->va + q * SHM_PAGE, SHM_PAGE) == 0) { bytes += SHM_PAGE; runs++; } }
                    else {
                        if (nrun == runs_cap) { size_t nc = runs_cap ? runs_cap * 2 : 256; shm_run *nv = realloc(runs_v, nc * sizeof *nv); if (nv) { runs_v = nv; runs_cap = nc; } }
                        if (nrun < runs_cap) runs_v[nrun++] = (shm_run){ r, q * SHM_PAGE, SHM_PAGE };
                        uint64_t s2 = r->shadow + q * SHM_PAGE, d2 = r->va + q * SHM_PAGE, z = SHM_PAGE; pnvk_cmd_copy_va(ucb, 1, &s2, &d2, &z);
                        bytes += SHM_PAGE; runs++;
                    }
                    atomic_fetch_add(&g_shm_dB_bytes, SHM_PAGE); atomic_fetch_add(&g_shm_dB_pages, 1);
                    if (old && r->dsnapped && !__atomic_load_n(&r->tmap[q], __ATOMIC_ACQUIRE)) { memcpy(old, cur, SHM_PAGE); r->dsnapped[q] = 1; }
                }
                k = e; continue;
            }
            if (g_shm_async && !ucb && !nrun) ucb = shm_ucb_begin(&uslot);
            if (ucb) {
                if (nrun == runs_cap) { size_t nc = runs_cap ? runs_cap * 2 : 256; shm_run *nv = realloc(runs_v, nc * sizeof *nv); if (nv) { runs_v = nv; runs_cap = nc; } }
                if (nrun < runs_cap) {
                    runs_v[nrun++] = (shm_run){ r, off, sz };
                    uint64_t s = r->shadow + off, dv = r->va + off, z = sz; pnvk_cmd_copy_va(ucb, 1, &s, &dv, &z);
                    bytes += sz; runs++; k = e; continue;
                }
            }
            if (nvmtl_vk_pre_copy_va(r->shadow + off, r->va + off, sz) == 0) { bytes += sz; runs++; }
            k = e;
        }
    }
    if (g_stg_state > 0) stg_close();   // before the dispatches: the copy that fills what they read
    shm_scatter_flush();
    // A (changed words, no wait) goes first: on the in-order copy queue it must not sit behind B's wait for the writers
    if (ucbA) {
        if (shm_ucb_submit(uslotA, 0) == 0) { nvmtl_vk_pre_barrier(); atomic_fetch_add(&g_shm_dA_batches, 1); }
        else {   // lost: its pages go up whole after the writers (B) - their snapshots already moved on, a whole page is exact
            atomic_fetch_add(&g_shm_async_fail, 1);
            nvlog("shmirror: copy-queue diff upload FAILED - this batch's pages are marked dirty again");
            for (int i = 0; i < n; i++) if (g_shm[i].dsnapped) { shm_range *r = &g_shm[i]; for (size_t q = 0; q < r->len / SHM_PAGE; q++) if (r->dsnapped[q]) { r->dsnapped[q] = 0; } }
            atomic_store(&g_shm_dirty_any, 1);
            for (int i = 0; i < n; i++) { shm_range *r = &g_shm[i]; if (atomic_load(&r->live) && r->dirty) for (size_t q = 0; q < r->len / SHM_PAGE; q++) __atomic_store_n(&r->dirty[q], 1, __ATOMIC_RELEASE); }
        }
    }
    if (ucb) {
        if (shm_ucb_submit(uslot, 1) == 0) { nvmtl_vk_pre_barrier(); atomic_fetch_add(&g_shm_dB_batches, 1); }   // the part that waits for it starts with a cache-invalidating barrier
        else {   // lost: copy the same runs at the head of this part instead, and stop using the copy queue
            atomic_fetch_add(&g_shm_async_fail, 1); g_shm_async = 0;
            nvlog("shmirror: copy-queue upload FAILED - %zu runs go on the graphics queue, and every later upload too", nrun);
            for (size_t q = 0; q < nrun; q++) nvmtl_vk_pre_copy_va(runs_v[q].r->shadow + runs_v[q].off, runs_v[q].r->va + runs_v[q].off, runs_v[q].sz);
        }
    }
    atomic_store(&g_shm_scanning, 0); t_shm_in_prologue = 0;
    atomic_fetch_add(&g_shm_pro_ns, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - pt0); atomic_fetch_add(&g_shm_prot_ns, prot_ns);
    atomic_fetch_add(&g_shm_prot_calls, prot_calls); atomic_fetch_add(&g_shm_scans, 1);
    if (runs) { atomic_fetch_add(&g_shm_up_bytes, bytes); atomic_fetch_add(&g_shm_up_runs, runs); }
}

// ---- GPU writes the plugin records itself -----------------------------------------------------------------------------
// dst (a buffer) bytes [off, off+len) are written by a command recorded into c: copy them back in its epilogue
void nvmtl_shm_note_vk_write(nvk_cmdbuf *c, const nvk_buffer *dst, size_t off, size_t len)
{
    if (g_shm_ready != 1 || !c || !dst || !dst->shm || !dst->buf || !len) return;
    VkBufferDeviceAddressInfo di = { VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO, NULL, (VkBuffer)dst->buf };
    const uint64_t va = pvkGetBufferDeviceAddress(g_dev, &di) + off;
    const int n = atomic_load(&g_shm_n);
    for (int i = 0; i < n; i++) {
        shm_range *r = &g_shm[i];
        if (!atomic_load(&r->live) || va < r->va || va >= r->va + r->len) continue;
        const uint64_t sh = r->shadow + (va - r->va), ln = MIN((uint64_t)len, r->va + r->len - va);
        if (r->tmap) for (uint64_t q = (va - r->va) / SHM_PAGE; q <= (va - r->va + ln - 1) / SHM_PAGE; q++) __atomic_store_n(&r->tmap[q], 1, __ATOMIC_RELEASE);
        // merge with the last range when it continues it; the list grows as needed (it used to overflow at 32 into a
        // copy-back of every adopted range whole, which put stale VRAM bytes over CPU writes - a 224 MB heap's ring
        // lost the argument data the CPU had just written: run 423, wild pointers in Cyberpunk)
        uint64_t (*last)[3] = c->shm_nwbx ? &c->shm_wbx[c->shm_nwbx - 1] : c->shm_nwb ? &c->shm_wb[c->shm_nwb - 1] : NULL;
        if (last && (*last)[0] + (*last)[2] == va && (*last)[1] + (*last)[2] == sh) { (*last)[2] += ln; return; }
        if (c->shm_nwb < NVMTL_SHM_WB && !c->shm_nwbx) { c->shm_wb[c->shm_nwb][0] = va; c->shm_wb[c->shm_nwb][1] = sh; c->shm_wb[c->shm_nwb][2] = ln; c->shm_nwb++; return; }
        if (c->shm_nwbx == c->shm_capx) {
            const unsigned nc = c->shm_capx ? c->shm_capx * 2 : 128; void *nv = realloc(c->shm_wbx, (size_t)nc * sizeof *c->shm_wbx);
            if (!nv) { c->shm_wb_over = 1; return; }
            c->shm_wbx = nv; c->shm_capx = nc;
        }
        c->shm_wbx[c->shm_nwbx][0] = va; c->shm_wbx[c->shm_nwbx][1] = sh; c->shm_wbx[c->shm_nwbx][2] = ln; c->shm_nwbx++;
        return;
    }
}
// writable textures made on adopted buffers (diagnostic NVMTL_SHM_TEXALL=1: copied back after every part, bound or not -
// a texture reached through bindless descriptors or useHeap: is never "bound" for nvmtl_shm_texture_bound)
static uint64_t g_shm_bt[1024][3]; static _Atomic int g_shm_bt_n;
void nvmtl_shm_note_buftex(const nvk_buffer *b, size_t off, size_t len, unsigned usage)
{
    if (g_shm_ready != 1 || !b || !b->shm || !b->buf || !len) return;
    VkBufferDeviceAddressInfo di = { VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO, NULL, (VkBuffer)b->buf };
    const uint64_t va = pvkGetBufferDeviceAddress(g_dev, &di) + off;
    const int n = atomic_load(&g_shm_n);
    for (int i = 0; i < n; i++) {
        shm_range *r = &g_shm[i];
        if (!atomic_load(&r->live) || va < r->va || va >= r->va + r->len) continue;
        const int k = atomic_fetch_add(&g_shm_bt_n, 1);
        if (k < 16 || !(k & (k - 1))) nvlog("shmirror: writable texture on an adopted %zu MB range at +%llu, %zu bytes, usage 0x%x (%d so far)", r->len >> 20, (unsigned long long)(va - r->va), len, usage, k + 1);
        if (k < 1024) { g_shm_bt[k][0] = va; g_shm_bt[k][1] = r->shadow + (va - r->va); g_shm_bt[k][2] = MIN((uint64_t)len, r->va + r->len - va); }
        return;
    }
}
// before vkEndCommandBuffer of every part (submit_begin)
void nvmtl_shm_epilogue(nvk_cmdbuf *c)
{
    if (g_shm_ready != 1 || !c || !c->cb || c->in_rp) return;
    if (shm_diag("NVMTL_SHM_DIAG_NOEPI")) return;   // diagnostic: measure the copy-back cost (GPU writes are LOST)
    const uint32_t n = (uint32_t)atomic_load(&g_shm_n);
    const int stores = shm_set_has(&g_shm_wcbs, (uint64_t)(uintptr_t)c->cb, 1);
    const int texall = shm_diag("NVMTL_SHM_TEXALL") && atomic_load(&g_shm_bt_n) > 0;
    if (!n || (!stores && !c->shm_nwb && !c->shm_nwbx && !c->shm_wb_over && !texall)) { if (n) atomic_fetch_add(&g_shm_epi_skipped, 1); return; }
    nvmtl_vk_pt_seg_begin(c, 9005u);   // passtime: the copy-back and both its barriers
    VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_MEMORY_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT | VK_ACCESS_TRANSFER_READ_BIT };
    pvkCmdPipelineBarrier(c->cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
    g_shm_real_bind(c->cb, VK_PIPELINE_BIND_POINT_COMPUTE, g_shm_pipe);
    struct { uint64_t table; uint32_t entries, pad; } pc = { g_shm_tab_va, n, 0 };
    pvkCmdPushConstants(c->cb, g_shm_playout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof pc, &pc);
    pvkCmdDispatch(c->cb, g_shm_max_granules ? g_shm_max_granules : 1, n, 1);
    if (c->shm_wb_over) {   // the list could not grow (out of memory): copy back every live range whole - unsafe for CPU writes in flight
        for (uint32_t i = 0; i < n; i++) { shm_range *r = &g_shm[i]; if (atomic_load(&r->live)) { uint64_t s = r->va, d = r->shadow, z = r->len; pnvk_cmd_copy_va(c->cb, 1, &s, &d, &z); } }
        static int said; if (said++ < 8) nvlog("shmirror: a part recorded more than %d plugin writes into Shared memory - every range copied back whole", NVMTL_SHM_WB);
    } else {
        // the writes were noted while recording; a range given back since (shm_evict) has no system-page address any more
        for (unsigned i = 0; i < c->shm_nwb + c->shm_nwbx; i++) {
            uint64_t *w = i < c->shm_nwb ? c->shm_wb[i] : c->shm_wbx[i - c->shm_nwb];
            int ok = 0; for (uint32_t k = 0; k < n; k++) { shm_range *r = &g_shm[k];
                if (atomic_load(&r->live) && w[0] >= r->va && w[0] + w[2] <= r->va + r->len && w[1] == r->shadow + (w[0] - r->va)) { ok = 1; break; } }
            if (ok) pnvk_cmd_copy_va(c->cb, 1, &w[0], &w[1], &w[2]);
        }
    }
    if (texall) { const int bn = MIN(atomic_load(&g_shm_bt_n), 1024); for (int i = 0; i < bn; i++) pnvk_cmd_copy_va(c->cb, 1, &g_shm_bt[i][0], &g_shm_bt[i][1], &g_shm_bt[i][2]); }
    atomic_fetch_add(&g_shm_wb, c->shm_nwb + c->shm_nwbx); c->shm_nwb = 0; c->shm_wb_over = 0;
    free(c->shm_wbx); c->shm_wbx = NULL; c->shm_nwbx = c->shm_capx = 0;
    c->shm_writer = 1;
    VkMemoryBarrier hb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_SHADER_WRITE_BIT | VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_HOST_READ_BIT | VK_ACCESS_MEMORY_READ_BIT };
    pvkCmdPipelineBarrier(c->cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT | VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 1, &hb, 0, NULL, 0, NULL);
    nvmtl_vk_pt_seg_end(c, 9005u, n);
    const unsigned long long k = atomic_fetch_add(&g_shm_epis, 1) + 1;
    if (!(k & (k - 1)) && k >= 64) shm_census("epilogue");
}

// at device loss: the table as the GPU sees it (read back through BAR1) against what each range should hold
void nvmtl_shm_dump_table(const char *why)
{
    static _Atomic int done; if (g_shm_ready != 1 || !g_shm_tmap || atomic_exchange(&done, 1)) return;
    const int n = atomic_load(&g_shm_n);
    nvlog("shmirror table at %s: %d entries, copy-back dispatch %u granules wide", why, n, g_shm_max_granules);
    for (int i = 0; i < n; i++) {
        const volatile uint32_t *e = (const volatile uint32_t *)(g_shm_tmap + SHM_TAB_L1 + (uint64_t)i * SHM_ENTRY);
        uint64_t f[5]; for (int k = 0; k < 5; k++) f[k] = (uint64_t)e[2 * k] | ((uint64_t)e[2 * k + 1] << 32);
        shm_range *r = &g_shm[i];
        const uint64_t bm = r->bitmap.buf ? nvmtl_vk_buffer_address(&r->bitmap) : 0, sm = r->summary.buf ? nvmtl_vk_buffer_address(&r->summary) : 0;
        const int ok = f[0] == r->va && (f[1] == r->len || f[1] == 0) && f[2] == bm && f[3] == sm && f[4] == r->shadow;
        nvlog("  entry %d %s: base 0x%llx len %llu bitmap 0x%llx summary 0x%llx shadow 0x%llx | expected base 0x%llx len %zu bitmap 0x%llx (%zu B) summary 0x%llx (%zu B) shadow 0x%llx live %d",
              i, ok ? "ok" : "MISMATCH", (unsigned long long)f[0], (unsigned long long)f[1], (unsigned long long)f[2], (unsigned long long)f[3], (unsigned long long)f[4],
              (unsigned long long)r->va, r->len, (unsigned long long)bm, r->bitmap_len, (unsigned long long)sm, r->summary_len, (unsigned long long)r->shadow, atomic_load(&r->live));
    }
}
// ---- audit (diagnostic): /tmp/nvmtl-shm-audit -------------------------------------------------------------------------
// With the queue idle every copy-back has run, and a page the CPU has not written since its last upload (dirty 0, write
// protected) must hold the same bytes in VRAM and in system memory. A page that differs means a write was lost on one
// side: a CPU write that did not fault, an upload that did not land, or a GPU write that was not copied back.
static void shm_audit(void)
{
    pthread_mutex_lock(&nvmtl_submit_mutex);
    pvkDeviceWaitIdle(g_dev);
    const size_t SZ = 16u << 20; nvk_buffer st; memset(&st, 0, sizeof st);
    if (nvmtl_vk_buffer_create(SZ, 1, &st) || !st.map) { pthread_mutex_unlock(&nvmtl_submit_mutex); nvlog("shmirror audit: no staging buffer"); return; }
    const uint64_t sva = nvmtl_vk_buffer_address(&st);
    unsigned long long pages = 0, clean = 0, bad = 0, badchunks = 0; int said = 0;
    const int n = atomic_load(&g_shm_n);
    for (int i = 0; i < n; i++) {
        shm_range *r = &g_shm[i];
        if (!atomic_load(&r->live)) continue;
        for (size_t off = 0; off < r->len; off += SZ) {
            uint64_t src = r->va + off, dst = sva, sz = MIN((size_t)SZ, r->len - off);
            nvk_cmdbuf c; if (nvmtl_vk_cmd_begin(NULL, &c)) continue;
            pnvk_cmd_copy_va(c.cb, 1, &src, &dst, &sz);
            if (nvmtl_vk_submit_wait(&c)) continue;
            for (size_t p = 0; p < sz; p += SHM_PAGE) {
                const size_t pg = (off + p) / SHM_PAGE; pages++;
                if (r->snap) {   // every page: a chunk where VRAM differs from the system pages while the system pages still hold what was uploaded is a GPU write nobody copied back
                    const uint8_t *v = (const uint8_t *)st.map + p, *s = (const uint8_t *)(r->cpu + off + p), *u = r->snap + off + p;
                    unsigned lostc = 0, firstl = UINT32_MAX;
                    for (unsigned q = 0; q < SHM_PAGE; q += 16) if (memcmp(v + q, s + q, 16) && !memcmp(s + q, u + q, 16)) { lostc++; if (firstl == UINT32_MAX) firstl = q; }
                    if (lostc) { atomic_fetch_add(&g_shm_lost_gpu, lostc);
                        static int lsaid; if (lsaid++ < 40) { shm_place pl; const int hit = shm_place_find(r->mem, (uint64_t)pg * SHM_PAGE + firstl, &pl);
                            const uint32_t *vv = (const uint32_t *)(v + firstl), *ss = (const uint32_t *)(s + firstl);
                            nvlog_diag("shmirror audit: UNTRACKED GPU WRITE entry %d (%zu MB) page %zu (+%zu): %u chunks, first +%u VRAM %08x %08x %08x %08x | system/uploaded %08x %08x %08x %08x | %s%s%s",
                                       i, r->len >> 20, pg, (size_t)pg * SHM_PAGE, lostc, firstl, vv[0], vv[1], vv[2], vv[3], ss[0], ss[1], ss[2], ss[3], r->dirty[pg] ? "dirty, " : "clean, ",
                                       hit ? (pl.kind == 1 ? "buffer" : "texture") : "no placement recorded",
                                       hit ? [[NSString stringWithFormat:@" at +%llu, %llu bytes", pl.off, pl.len] UTF8String] : ""); } }
                }
                if (r->dirty[pg]) continue;
                clean++;
                const uint8_t *v = (const uint8_t *)st.map + p, *s = (const uint8_t *)(r->cpu + off + p);
                if (!memcmp(v, s, SHM_PAGE)) continue;
                bad++; unsigned k = 0, first = UINT32_MAX;
                for (unsigned q = 0; q < SHM_PAGE; q += 16) if (memcmp(v + q, s + q, 16)) { k++; if (first == UINT32_MAX) first = q; }
                badchunks += k;
                if (said++ < 24) {
                    const uint32_t *vv = (const uint32_t *)(v + first), *ss = (const uint32_t *)(s + first);
                    shm_place pl; const int hit = shm_place_find(r->mem, (uint64_t)pg * SHM_PAGE + first, &pl);
                    nvlog_diag("shmirror audit: entry %d (%zu MB) page %zu differs in %u of 1024 chunks, first +%u: VRAM %08x %08x %08x %08x | system %08x %08x %08x %08x | %s%s",
                               i, r->len >> 20, pg, k, first, vv[0], vv[1], vv[2], vv[3], ss[0], ss[1], ss[2], ss[3],
                               hit ? (pl.kind == 1 ? "buffer" : pl.kind == 2 ? "texture" : "depth texture") : "no placement recorded",
                               hit ? [[NSString stringWithFormat:@" at +%llu, %llu bytes, usage 0x%x", pl.off, pl.len, pl.usage] UTF8String] : "");
                }
            }
        }
    }
    nvmtl_vk_buffer_destroy(&st);
    pthread_mutex_unlock(&nvmtl_submit_mutex);
    nvlog_diag("shmirror audit: %llu pages, %llu clean, %llu clean pages DIFFER (%llu 16-byte chunks); untracked GPU-written chunks so far %llu", pages, clean, bad, badchunks, (unsigned long long)atomic_load(&g_shm_lost_gpu));
}
// every 5 s: per-frame cost of the write tracking, and a self-test - 64 writes to protected pages of our own, timed
// from the store to its return, so the number includes whatever exception handling the app installed before ours
static void shm_cost_tick(void)
{
    static uint64_t last_ns; static unsigned long long l_f, l_pg, l_fns, l_pns, l_prns, l_prc, l_sc, l_up, l_th[SHM_TH]; static unsigned l_fr;
    const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now - last_ns < 5000000000ull) return;
    const int first = last_ns == 0; last_ns = now;
    if (!g_shm_probe) { g_shm_probe = mmap(NULL, 64 * SHM_PAGE, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (g_shm_probe == MAP_FAILED) g_shm_probe = NULL; else memset(g_shm_probe, 0, 64 * SHM_PAGE); }
    double probe_avg = 0, probe_max = 0;
    static int probe_on = -1; if (probe_on < 0) { const char *e = getenv("NVMTL_SHM_PROBE"); probe_on = e && e[0] == '1'; }
    {   // a task-level Mach exception handler (crash reporters) sees every write fault before our signal handler does
        static int said;
        exception_mask_t masks[EXC_TYPES_COUNT]; mach_port_t ports[EXC_TYPES_COUNT]; exception_behavior_t beh[EXC_TYPES_COUNT]; thread_state_flavor_t fl[EXC_TYPES_COUNT];
        mach_msg_type_number_t cnt = EXC_TYPES_COUNT;
        if (!said && task_get_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, masks, &cnt, ports, beh, fl) == KERN_SUCCESS) {
            int live = 0; for (unsigned k = 0; k < cnt; k++) if (MACH_PORT_VALID(ports[k])) live++;
            if (atomic_load(&g_shm_adopted) || live) { said = 1;
                nvlog("shmirror: task EXC_BAD_ACCESS handler %s (%u entries, %d with a port, behavior 0x%x) - %s", live ? "PRESENT" : "none", cnt, live, cnt ? (unsigned)beh[0] : 0,
                      live ? "every write fault is a Mach message to it before our signal handler runs" : "write faults go straight to the signal handler"); }
        }
    }
    if (probe_on && g_shm_probe && atomic_load(&g_shm_adopted) && !mprotect(g_shm_probe, 64 * SHM_PAGE, PROT_READ)) {   // adopted: our handler is installed
        for (int k = 0; k < 64; k++) {
            const uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            ((volatile char *)g_shm_probe)[(size_t)k * SHM_PAGE + 8] = (char)k;
            const double us = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1000.0;
            probe_avg += us / 64; if (us > probe_max) probe_max = us;
        }
    }
    const unsigned fr = atomic_load(&nvmtl_flick_frame);
    const unsigned long long f = atomic_load(&g_shm_faults), pg = atomic_load(&g_shm_fault_pages), fns = atomic_load(&g_shm_fault_ns), pns = atomic_load(&g_shm_pro_ns),
        prns = atomic_load(&g_shm_prot_ns), prc = atomic_load(&g_shm_prot_calls), sc = atomic_load(&g_shm_scans), up = atomic_load(&g_shm_up_bytes);
    unsigned long long th[SHM_TH]; for (int k = 0; k < SHM_TH; k++) th[k] = atomic_load(&g_shm_th[k].n);
    if (!first && fr > l_fr) {
        const double nf = fr - l_fr, df = (double)(f - l_f);
        char ths[200]; size_t o = 0;
        for (int k = 0; k < SHM_TH && o < sizeof ths - 16; k++) if (th[k] > l_th[k]) o += snprintf(ths + o, sizeof ths - o, " %.0f", (th[k] - l_th[k]) / nf);
        nvlog_diag("shmirror cost: %.0f frames/5s | faults/frame %.1f on %.1f pages | handler %.2f us/fault, self-test fault %.2f us (max %.1f) -> ~%.2f ms/frame of faults | "
                   "prologue %.2f ms/frame (%.1f scans, %.1f mprotect %.2f ms) | upload %.2f MB/frame | faults/frame by thread:%s",
                   nf, df / nf, (pg - l_pg) / nf, df ? (fns - l_fns) / 1000.0 / df : 0, probe_avg, probe_max, df / nf * probe_avg / 1000.0,
                   (pns - l_pns) / 1e6 / nf, (sc - l_sc) / nf, (prc - l_prc) / nf, (prns - l_prns) / 1e6 / nf, (up - l_up) / 1048576.0 / nf, ths);
        { static unsigned long long dp0, db0, dr0; const unsigned long long dp = atomic_load(&g_shm_diff_pages), db = atomic_load(&g_shm_diff_bytes), dr = atomic_load(&g_shm_diff_runs);
          if (dp > dp0) nvlog_diag("shmirror diff: %.0f re-uploaded pages/frame, %.1f%% of their bytes changed (%.2f MB/frame), %.1f runs/page (gaps > 256 B split)",
                                   (dp - dp0) / nf, 100.0 * (db - db0) / ((dp - dp0) * (double)SHM_PAGE), (db - db0) / 1048576.0 / nf, (double)(dr - dr0) / (dp - dp0));
          dp0 = dp; db0 = db; dr0 = dr; }
    }
    l_fr = fr; l_f = f; l_pg = pg; l_fns = fns; l_pns = pns; l_prns = prns; l_prc = prc; l_sc = sc; l_up = up; for (int k = 0; k < SHM_TH; k++) l_th[k] = th[k];
}
static void shm_audit_start(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static dispatch_source_t t;   // static: under ARC a local source is released, and cancelled, when the block returns
        t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), 500 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(t, ^{
            static long every = -2; static uint64_t last; if (every == -2) { const char *e = getenv("NVMTL_SHM_AUDIT_MS"); every = e ? atol(e) : 0; }
            const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            if (access("/tmp/nvmtl-shm-audit", F_OK) == 0) { unlink("/tmp/nvmtl-shm-audit"); shm_audit(); last = now; }
            else if (every > 0 && atomic_load(&g_shm_adopted) && now - last >= (uint64_t)every * 1000000ull) { shm_audit(); last = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
            shm_vram_watch();
            { static uint64_t vlast; if (shm_verify_ms() > 0 && atomic_load(&g_shm_adopted) && now - vlast >= (uint64_t)shm_verify_ms() * 1000000ull) { shm_verify(); vlast = now; } }
            shm_cost_tick(); });
        dispatch_resume(t);
    });
}
