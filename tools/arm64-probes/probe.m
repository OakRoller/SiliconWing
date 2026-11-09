#import <Metal/Metal.h>
#import <objc/runtime.h>
int main(void) {
    const char *names[] = {"MTLIOAccelDevice","MTLIOAccelResourcePool","MTLIOAccelPooledResource","MTLIOAccelCommandQueue","MTLIOAccelTexture",
                           "MTLIOAccelBuffer","MTLIOGPUDevice","_MTLDevice","MTLIOAccelRenderCommandEncoder","MTLIOAccelHeap","MTLIOAccelFence", NULL};
    for (int i = 0; names[i]; i++) printf("%-34s %s\n", names[i], objc_getClass(names[i]) ? "present" : "MISSING");
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    Class c = object_getClass(d); printf("default device: %s", class_getName(c));
    while ((c = class_getSuperclass(c))) printf(" -> %s", class_getName(c));
    printf("\n");
    unsigned n = 0; Class *all = objc_copyClassList(&n); int k = 0;
    for (unsigned i = 0; i < n && k < 40; i++) { const char *nm = class_getName(all[i]); if (!strncmp(nm, "MTLIOAccel", 10) || !strncmp(nm, "MTLIOGPU", 8)) { printf("  %s\n", nm); k++; } }
    return 0;
}
