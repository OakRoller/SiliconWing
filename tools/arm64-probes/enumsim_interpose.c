// enumsim_interpose.c: make Metal.framework load OUR plugin for the accelerator this Mac already has (the AGX one), so
// the arm64 NVMTLDevice's enumeration and setup path runs on a Mac with no NVIDIA GPU. Two interpositions:
//   IORegistryEntryCreateCFProperty: MetalPluginName / MetalPluginClassName of any IOAccelerator answer with
//                                    $NVMTL_SIM_PLUGIN (absolute bundle path) / NVMTLDevice
//   gpu_bundle_find_trusted:         libsystem_sandbox's trust check accepts that absolute path as-is
// Everything else goes through untouched. Loaded with DYLD_INSERT_LIBRARIES by run_enumsim.sh.
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define LOG(...) do { fprintf(stderr, "[sim] " __VA_ARGS__); fprintf(stderr, "\n"); } while (0)
extern int gpu_bundle_find_trusted(const char *name, char *out, size_t n);
static const char *plugin_path(void) { return getenv("NVMTL_SIM_PLUGIN"); }
static CFTypeRef my_IORegistryEntryCreateCFProperty(io_registry_entry_t e, CFStringRef key, CFAllocatorRef a, IOOptionBits o) {
    const char *pp = plugin_path();
    if (pp && IOObjectConformsTo(e, "IOAccelerator")) {
        if (CFEqual(key, CFSTR("MetalPluginName"))) { LOG("MetalPluginName -> %s", pp); return CFStringCreateWithCString(NULL, pp, kCFStringEncodingUTF8); }
        if (CFEqual(key, CFSTR("MetalPluginClassName"))) { LOG("MetalPluginClassName -> NVMTLDevice"); return CFSTR("NVMTLDevice"); }
    }
    return IORegistryEntryCreateCFProperty(e, key, a, o);
}
static kern_return_t my_IORegistryEntryCreateCFProperties(io_registry_entry_t e, CFMutableDictionaryRef *props, CFAllocatorRef a, IOOptionBits o) {
    kern_return_t r = IORegistryEntryCreateCFProperties(e, props, a, o);
    const char *pp = plugin_path();
    if (r == KERN_SUCCESS && pp && props && *props && IOObjectConformsTo(e, "IOAccelerator") && CFDictionaryContainsKey(*props, CFSTR("MetalPluginName"))) {
        CFStringRef s = CFStringCreateWithCString(NULL, pp, kCFStringEncodingUTF8);
        CFDictionarySetValue(*props, CFSTR("MetalPluginName"), s); CFRelease(s);
        CFDictionarySetValue(*props, CFSTR("MetalPluginClassName"), CFSTR("NVMTLDevice"));
        LOG("CreateCFProperties: MetalPluginName -> %s", pp);
    }
    return r;
}
static CFTypeRef my_IORegistryEntrySearchCFProperty(io_registry_entry_t e, const io_name_t plane, CFStringRef key, CFAllocatorRef a, IOOptionBits o) {
    const char *pp = plugin_path();
    if (pp && IOObjectConformsTo(e, "IOAccelerator")) {
        if (CFEqual(key, CFSTR("MetalPluginName"))) { LOG("SearchCFProperty: MetalPluginName -> %s", pp); return CFStringCreateWithCString(NULL, pp, kCFStringEncodingUTF8); }
        if (CFEqual(key, CFSTR("MetalPluginClassName"))) return CFSTR("NVMTLDevice");
    }
    return IORegistryEntrySearchCFProperty(e, plane, key, a, o);
}
static int my_gpu_bundle_find_trusted(const char *name, char *out, size_t n) {
    if (name && name[0] == '/') { strlcpy(out, name, n); LOG("gpu_bundle_find_trusted(%s) -> accepted as-is", name); return 0; }
    int r = gpu_bundle_find_trusted(name, out, n);
    LOG("gpu_bundle_find_trusted(%s) -> %d %s", name ? name : "(null)", r, r == 0 ? out : "");
    return r;
}
typedef struct { const void *replacement, *original; } interpose_t;
__attribute__((used, section("__DATA,__interpose"))) static const interpose_t interposers[] = {
    { my_IORegistryEntryCreateCFProperty, IORegistryEntryCreateCFProperty },
    { my_gpu_bundle_find_trusted, gpu_bundle_find_trusted },
    { my_IORegistryEntryCreateCFProperties, IORegistryEntryCreateCFProperties },
    { my_IORegistryEntrySearchCFProperty, IORegistryEntrySearchCFProperty },
};
