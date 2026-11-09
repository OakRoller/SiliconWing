// nv_xnu_memfuncs.cpp: alignment-safe replacements for the libkern memory routines the kext would otherwise import.
//
// On Apple Silicon every PCI BAR is Device-type memory whatever cache mode the mapping asked for (XNU's arm64 pmap
// never gives a non-DRAM address a Normal mapping), and Device memory faults on any access that is not aligned to
// its own width. The RM's memcpy/memset already go through os_mem_copy/os_mem_set (gcc_helper.c) and so through
// nv_xnu_memcpy/nv_xnu_memset, which only ever issue naturally aligned 8-byte or byte accesses. Compiler-generated
// calls (struct copies, `= {0}` initialisers, memcmp) resolved to libkern's memmove/bzero/memcmp instead, whose arm64
// implementations use overlapping unaligned loads and `dc zva`, both of which abort on a BAR mapping. These
// definitions take precedence over the kernel's exports for references inside this kext. x86 keeps libkern's.
#include <stdint.h>
#include <string.h>
#include <sys/types.h>
#include "nv-xnu-arch.h"

#if NV_XNU_ARM64
extern "C" {

void *memmove(void *d, const void *s, size_t n)
{
    uint8_t *dp = (uint8_t *)d; const uint8_t *sp = (const uint8_t *)s;
    if (dp == sp || n == 0) return d;
    if (dp < sp || dp >= sp + n) { nv_xnu_memcpy(d, s, n); return d; }
    // overlapping with the destination above the source: copy from the end
    volatile uint8_t *de = dp + n; const volatile uint8_t *se = sp + n;
    if (!(((uintptr_t)de | (uintptr_t)se) & 7)) {
        volatile uint64_t *dq = (volatile uint64_t *)de; const volatile uint64_t *sq = (const volatile uint64_t *)se;
        for (; n >= 8; n -= 8) *--dq = *--sq;
        de = (volatile uint8_t *)dq; se = (const volatile uint8_t *)sq;
    }
    while (n--) *--de = *--se;
    return d;
}

void bzero(void *d, size_t n) { nv_xnu_memset(d, 0, n); }

int memcmp(const void *a, const void *b, size_t n)
{
    const volatile uint8_t *p = (const volatile uint8_t *)a, *q = (const volatile uint8_t *)b;
    for (; n; n--, p++, q++) { const int x = *p, y = *q; if (x != y) return x - y; }
    return 0;
}

// fortified variants the kernel headers may route calls through
void *__memmove_chk(void *d, const void *s, size_t n, size_t) { return memmove(d, s, n); }
void *__memcpy_chk(void *d, const void *s, size_t n, size_t) { nv_xnu_memcpy(d, s, n); return d; }
void *__memset_chk(void *d, int c, size_t n, size_t) { nv_xnu_memset(d, c, n); return d; }

} // extern "C"
#endif
