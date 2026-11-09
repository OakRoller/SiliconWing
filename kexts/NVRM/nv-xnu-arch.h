/*
 * NullMoth NVIDIA driver for macOS
 * Copyright (c) 2026 NullMoth Systems.
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 *
 * Architecture shims for the XNU port. x86_64 keeps the inline assembly the driver shipped with; arm64e (Apple
 * Silicon) gets equivalents built on libkern and ARM barriers. Everything that only exists on an Intel Mac or a PC
 * (ACPI, port I/O, CPUID, the EFI firmware console, BAR placement by hand) is behind NV_XNU_ACPI / NV_XNU_ARM64 so
 * each site states what it assumes about the machine.
 */

#pragma once
#include <sys/types.h>
#include <string.h>

#if defined(__x86_64__)
#define NV_XNU_X86   1
#define NV_XNU_ARM64 0
#define NV_XNU_ACPI  1   // IOACPIFamily exists: host bridge _CRS, GPU _DSM/_DOD
#elif defined(__arm64__) || defined(__aarch64__)
#define NV_XNU_X86   0
#define NV_XNU_ARM64 1
#define NV_XNU_ACPI  0   // Apple Silicon has a device tree, no ACPI, no IOACPIFamily kext to link against
#else
#error "nv-xnu-arch.h: unsupported architecture"
#endif

// Byte fills and copies that are safe on device memory (BAR windows). x86 uses the string instructions the driver
// always used. arm64 avoids libkern's memcpy/memset, which may issue unaligned or paired accesses that fault on
// Device-type mappings: 8-byte stores when both sides allow it, bytes otherwise.
static inline void nv_xnu_memset(void *d, int c, size_t n)
{
#if NV_XNU_X86
    __asm__ __volatile__("rep stosb" : "+D"(d), "+c"(n) : "a"(c) : "memory");
#else
    volatile uint8_t *p = (volatile uint8_t *)d;
    if (!((uintptr_t)p & 7) && n >= 8) {
        uint64_t v = (uint8_t)c; v |= v << 8; v |= v << 16; v |= v << 32;
        volatile uint64_t *q = (volatile uint64_t *)p;
        for (; n >= 8; n -= 8) *q++ = v;
        p = (volatile uint8_t *)q;
    }
    while (n--) *p++ = (uint8_t)c;
#endif
}
static inline void nv_xnu_memcpy(void *d, const void *s, size_t n)
{
#if NV_XNU_X86
    __asm__ __volatile__("rep movsb" : "+D"(d), "+S"(s), "+c"(n) : : "memory");
#else
    volatile uint8_t *dp = (volatile uint8_t *)d; const volatile uint8_t *sp = (const volatile uint8_t *)s;
    if (!(((uintptr_t)dp | (uintptr_t)sp) & 7) && n >= 8) {
        volatile uint64_t *dq = (volatile uint64_t *)dp; const volatile uint64_t *sq = (const volatile uint64_t *)sp;
        for (; n >= 8; n -= 8) *dq++ = *sq++;
        dp = (volatile uint8_t *)dq; sp = (const volatile uint8_t *)sq;
    }
    while (n--) *dp++ = *sp++;
#endif
}

// Write-combining buffers must reach the device before the doorbell: sfence on x86, a store barrier on arm64.
static inline void nv_xnu_wc_flush(void)
{
#if NV_XNU_X86
    __asm__ __volatile__("sfence" ::: "memory");
#else
    __asm__ __volatile__("dsb st" ::: "memory");
#endif
}
// Full barrier for register handshakes (mfence on x86).
static inline void nv_xnu_full_barrier(void)
{
#if NV_XNU_X86
    __asm__ __volatile__("mfence" ::: "memory");
#else
    __asm__ __volatile__("dsb sy" ::: "memory");
#endif
}

// Legacy x86 port I/O. The RM asks for it only on VBIOS/legacy paths; Apple Silicon has no I/O port space.
static inline void nv_xnu_outb(uint16_t port, uint8_t v)  {
#if NV_XNU_X86
    __asm__ __volatile__("outb %0, %1" :: "a"(v), "d"(port));
#else
    (void)port; (void)v;
#endif
}
static inline void nv_xnu_outw(uint16_t port, uint16_t v) {
#if NV_XNU_X86
    __asm__ __volatile__("outw %0, %1" :: "a"(v), "d"(port));
#else
    (void)port; (void)v;
#endif
}
static inline void nv_xnu_outl(uint16_t port, uint32_t v) {
#if NV_XNU_X86
    __asm__ __volatile__("outl %0, %1" :: "a"(v), "d"(port));
#else
    (void)port; (void)v;
#endif
}
static inline uint8_t nv_xnu_inb(uint16_t port) {
#if NV_XNU_X86
    uint8_t v; __asm__ __volatile__("inb %1, %0" : "=a"(v) : "d"(port)); return v;
#else
    (void)port; return 0xff;
#endif
}
static inline uint16_t nv_xnu_inw(uint16_t port) {
#if NV_XNU_X86
    uint16_t v; __asm__ __volatile__("inw %1, %0" : "=a"(v) : "d"(port)); return v;
#else
    (void)port; return 0xffff;
#endif
}
static inline uint32_t nv_xnu_inl(uint16_t port) {
#if NV_XNU_X86
    uint32_t v; __asm__ __volatile__("inl %1, %0" : "=a"(v) : "d"(port)); return v;
#else
    (void)port; return 0xffffffffu;
#endif
}

// The lowest kernel virtual address: pointers below it are not kernel pointers (page-table sentinel sanity checks).
#if NV_XNU_X86
#define NV_XNU_KERNEL_VA_MIN 0xffffff8000000000ULL
#else
#define NV_XNU_KERNEL_VA_MIN 0xfffffe0000000000ULL
#endif
