// interpose.c: log the IOKit calls Metal.framework's MTLIOAccelDevice makes while it attaches to an IOAccelerator.
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
static int fake(void) { static int f = -1; if (f < 0) f = getenv("FAKE") ? 1 : 0; return f; }
#define LOG(...) do { fprintf(stderr, "[io] " __VA_ARGS__); fprintf(stderr, "\n"); } while (0)
static void cfdesc(CFTypeRef v, char *buf, size_t n) {
    buf[0] = 0; if (!v) { strlcpy(buf, "(null)", n); return; }
    CFStringRef d = CFCopyDescription(v); if (d) { CFStringGetCString(d, buf, n, kCFStringEncodingUTF8); CFRelease(d); }
    for (char *p = buf; *p; p++) if (*p == '\n') *p = ' ';
}
kern_return_t my_IOServiceOpen(io_service_t s, task_port_t t, uint32_t type, io_connect_t *c) {
    io_name_t cls = ""; IOObjectGetClass(s, cls);
    kern_return_t r = IOServiceOpen(s, t, type, c);
    LOG("IOServiceOpen(%s, type %u) -> 0x%x connect %u", cls, type, r, c ? *c : 0);
    if (r != 0 && fake() && type != 5) {   // no such client on AGX: borrow a type-5 connect so the caller walks on; its calls are still logged
        r = IOServiceOpen(s, t, 5, c);
        LOG("  (faked: type %u served by a type-5 connect %u -> 0x%x)", type, c ? *c : 0, r);
    }
    return r;
}
kern_return_t my_IOConnectCallMethod(mach_port_t c, uint32_t sel, const uint64_t *in, uint32_t inCnt, const void *inS, size_t inSz,
                                     uint64_t *out, uint32_t *outCnt, void *outS, size_t *outSz) {
    kern_return_t r = IOConnectCallMethod(c, sel, in, inCnt, inS, inSz, out, outCnt, outS, outSz);
    if (r == 0xe00002c2 && fake()) { if (out && outCnt) memset(out, 0, *outCnt * 8); if (outS && outSz) memset(outS, 0, *outSz); r = 0; LOG("  (faked success)"); }
    LOG("IOConnectCallMethod(connect %u, sel %u, in %u scalars/%zu B, out %u scalars/%zu B) -> 0x%x", c, sel, inCnt, inSz, outCnt ? *outCnt : 0, outSz ? *outSz : 0, r); return r;
}
kern_return_t my_IOConnectCallStructMethod(mach_port_t c, uint32_t sel, const void *inS, size_t inSz, void *outS, size_t *outSz) {
    kern_return_t r = IOConnectCallStructMethod(c, sel, inS, inSz, outS, outSz);
    if (r == 0xe00002c2 && fake()) { if (outS && outSz) memset(outS, 0, *outSz); r = 0; LOG("  (faked success)"); }
    LOG("IOConnectCallStructMethod(connect %u, sel %u, in %zu B, out %zu B) -> 0x%x", c, sel, inSz, outSz ? *outSz : 0, r); return r;
}
kern_return_t my_IOConnectCallScalarMethod(mach_port_t c, uint32_t sel, const uint64_t *in, uint32_t inCnt, uint64_t *out, uint32_t *outCnt) {
    kern_return_t r = IOConnectCallScalarMethod(c, sel, in, inCnt, out, outCnt);
    if (r == 0xe00002c2 && fake()) { if (out && outCnt) memset(out, 0, *outCnt * 8); r = 0; LOG("  (faked success)"); }
    LOG("IOConnectCallScalarMethod(connect %u, sel %u, in %u, out %u) -> 0x%x", c, sel, inCnt, outCnt ? *outCnt : 0, r); return r;
}
kern_return_t my_IOConnectMapMemory64(io_connect_t c, uint32_t type, task_port_t t, mach_vm_address_t *addr, mach_vm_size_t *size, IOOptionBits opt) {
    kern_return_t r = IOConnectMapMemory64(c, type, t, addr, size, opt);
    if (r != 0 && fake() && addr) { mach_vm_size_t sz = (size && *size) ? *size : 65536; if (mach_vm_allocate(mach_task_self(), addr, sz, VM_FLAGS_ANYWHERE) == 0) { if (size) *size = sz; r = 0; LOG("  (faked mapping %llu B)", (unsigned long long)sz); } }
    LOG("IOConnectMapMemory64(connect %u, type %u, options 0x%x) -> 0x%x size %llu", c, type, opt, r, size ? (unsigned long long)*size : 0ULL); return r;
}
kern_return_t my_IOConnectSetNotificationPort(io_connect_t c, uint32_t type, mach_port_t port, uintptr_t ref) {
    kern_return_t r = IOConnectSetNotificationPort(c, type, port, ref);
    LOG("IOConnectSetNotificationPort(connect %u, type %u) -> 0x%x", c, type, r); return r;
}
kern_return_t my_IOConnectAddClient(io_connect_t c, io_connect_t other) {
    kern_return_t r = IOConnectAddClient(c, other); LOG("IOConnectAddClient(%u, %u) -> 0x%x", c, other, r); return r;
}
CFTypeRef my_IORegistryEntryCreateCFProperty(io_registry_entry_t e, CFStringRef key, CFAllocatorRef a, IOOptionBits o) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(e, key, a, o);
    char k[128] = "", d[160]; CFStringGetCString(key, k, sizeof k, kCFStringEncodingUTF8); cfdesc(v, d, sizeof d);
    io_name_t cls = ""; IOObjectGetClass(e, cls);
    LOG("property %s[%s] = %.150s", cls, k, d); return v;
}
CFMutableDictionaryRef my_IORegistryEntryCreateCFProperties_wrap(io_registry_entry_t e, CFMutableDictionaryRef *props, CFAllocatorRef a, IOOptionBits o) {
    kern_return_t r = IORegistryEntryCreateCFProperties(e, props, a, o); io_name_t cls = ""; IOObjectGetClass(e, cls);
    LOG("properties(%s) -> 0x%x", cls, r); return (CFMutableDictionaryRef)(uintptr_t)r;
}
typedef struct { const void *replacement, *original; } interpose_t;
__attribute__((used, section("__DATA,__interpose"))) static const interpose_t interposers[] = {
    { my_IOServiceOpen, IOServiceOpen }, { my_IOConnectCallMethod, IOConnectCallMethod },
    { my_IOConnectCallStructMethod, IOConnectCallStructMethod }, { my_IOConnectCallScalarMethod, IOConnectCallScalarMethod },
    { my_IOConnectMapMemory64, IOConnectMapMemory64 }, { my_IOConnectSetNotificationPort, IOConnectSetNotificationPort },
    { my_IOConnectAddClient, IOConnectAddClient }, { my_IORegistryEntryCreateCFProperty, IORegistryEntryCreateCFProperty },
};
