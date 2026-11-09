// usenv_interpose.c: make an app that asks for the system default Metal device get the NVIDIA one instead.
// Apple Silicon Macs answer MTLCreateSystemDefaultDevice / CGDirectDisplayCopyCurrentMetalDevice with the Apple GPU,
// and most apps and games never look further. This dylib, inserted with DYLD_INSERT_LIBRARIES (ad-hoc or unsigned
// apps only; a hardened runtime ignores it), answers those with the NVMTLDevice and lists it first in
// MTLCopyAllDevices. Build universal: Rosetta games need the x86_64 slice.
//   xcrun clang -arch arm64 -arch x86_64 -dynamiclib -fobjc-arc -framework Metal -framework CoreGraphics -framework Foundation usenv_interpose.m -o libusenv.dylib
//   DYLD_INSERT_LIBRARIES=/path/libusenv.dylib /path/to/Game.app/Contents/MacOS/Game
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <stdlib.h>

// Children must not inherit the insertion: a helper the game spawns (an arm64e system binary, say) would be killed by
// dyld when it cannot load this dylib. The override applies to this process only.
__attribute__((constructor)) static void usenv_scrub_env(void) { unsetenv("DYLD_INSERT_LIBRARIES"); }

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } _interpose_##_replacee \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

static id<MTLDevice> usenv_pick(void) {
    static id<MTLDevice> dev; static int tried;
    if (!tried) { tried = 1;
        for (id<MTLDevice> d in MTLCopyAllDevices()) if ([NSStringFromClass([d class]) isEqualToString:@"NVMTLDevice"]) { dev = d; break; }
        const char *q = getenv("USENV_QUIET");
        if (!(q && *q)) fprintf(stderr, "usenv: default Metal device -> %s\n", dev ? dev.name.UTF8String : "(NVMTLDevice NOT found, leaving Apple's)");
    }
    return dev;
}
// The originals are declared NS_RETURNS_RETAINED / CF_RETURNS_RETAINED (Create, Copy): callers release what they get, so
// the replacements must hand back +1 too, or the app over-releases (SIGSEGV in objc_autoreleasePoolPop under Rosetta).
static id<MTLDevice> my_MTLCreateSystemDefaultDevice(void) NS_RETURNS_RETAINED;
static id<MTLDevice> my_CGDirectDisplayCopyCurrentMetalDevice(CGDirectDisplayID disp) NS_RETURNS_RETAINED;
static NSArray<id<MTLDevice>> *my_MTLCopyAllDevices(void) NS_RETURNS_RETAINED;
static id<MTLDevice> my_MTLCreateSystemDefaultDevice(void) {
    id<MTLDevice> d = usenv_pick();
    return d ? d : MTLCreateSystemDefaultDevice();
}
static id<MTLDevice> my_CGDirectDisplayCopyCurrentMetalDevice(CGDirectDisplayID disp) {
    id<MTLDevice> d = usenv_pick();
    return d ? d : CGDirectDisplayCopyCurrentMetalDevice(disp);
}
static NSArray<id<MTLDevice>> *my_MTLCopyAllDevices(void) {
    NSArray *all = MTLCopyAllDevices();
    id<MTLDevice> d = usenv_pick();
    if (!d) return all;
    NSMutableArray *r = [NSMutableArray arrayWithObject:d];
    for (id x in all) if (x != d) [r addObject:x];
    return r;
}
DYLD_INTERPOSE(my_MTLCreateSystemDefaultDevice, MTLCreateSystemDefaultDevice)
DYLD_INTERPOSE(my_CGDirectDisplayCopyCurrentMetalDevice, CGDirectDisplayCopyCurrentMetalDevice)
DYLD_INTERPOSE(my_MTLCopyAllDevices, MTLCopyAllDevices)
