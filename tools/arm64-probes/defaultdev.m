// defaultdev.m: prints what MTLCreateSystemDefaultDevice and the display's device answer (to check usenv).
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>
int main(void) { @autoreleasepool {
    id<MTLDevice> a = MTLCreateSystemDefaultDevice(); id<MTLDevice> b = CGDirectDisplayCopyCurrentMetalDevice(CGMainDisplayID());
    printf("MTLCreateSystemDefaultDevice -> %s\nCGDirectDisplayCopyCurrentMetalDevice -> %s\nMTLCopyAllDevices[0] -> %s\n", a.name.UTF8String, b.name.UTF8String, MTLCopyAllDevices().firstObject.name.UTF8String);
    return 0; } }
