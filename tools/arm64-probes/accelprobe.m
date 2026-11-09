// accelprobe.m: hand Metal's MTLIOAccelDevice an IOAccelerator service (AGX, the only one on this Mac) and watch what it asks the kernel for.
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
int main(int argc, char **argv) {
    const char *cls = argc > 1 ? argv[1] : "IOAccelerator";
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(cls));
    io_name_t name = ""; IOObjectGetClass(s, name);
    fprintf(stderr, "accelerator service: %u (%s)\n", s, name);
    Class C = objc_getClass("MTLIOAccelDevice");
    fprintf(stderr, "MTLIOAccelDevice: %p\n", (__bridge void *)C);
    unsigned n = 0; Method *ms = class_copyMethodList(C, &n);
    fprintf(stderr, "--- %u methods on MTLIOAccelDevice\n", n);
    for (unsigned i = 0; i < n; i++) fprintf(stderr, "  %s\n", sel_getName(method_getName(ms[i])));
    id dev = [C alloc];
    fprintf(stderr, "--- calling initWithAcceleratorPort:\n");
    id r = ((id (*)(id, SEL, mach_port_t))objc_msgSend)(dev, sel_registerName("initWithAcceleratorPort:"), s);
    fprintf(stderr, "--- initWithAcceleratorPort: -> %p\n", (__bridge void *)r);
    return 0;
}
