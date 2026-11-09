// nvrmctl go <pass>: ask the running NVRM.kext to run its bring-up pass again (selector 0 of its control client),
// `nvrmctl log` prints the kext's log ring (sysctl debug.nvrm_log), `nvrmctl allocs` the live RM sysmem allocations with
// their physical runs (debug.nvrm_allocs, root), `nvrmctl devctl` the card's PCIe Device Control as the kext last read it.
// Needs root for go and allocs.
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
int main(int argc, char **argv) {
    // log: the kext's log ring; allocs (root): live RM sysmem allocations with physical runs; devctl: PCIe Device Control
    const char *oid = NULL;
    if (argc >= 2 && !strcmp(argv[1], "log")) oid = "debug.nvrm_log";
    if (argc >= 2 && !strcmp(argv[1], "allocs")) oid = "debug.nvrm_allocs";
    if (oid) {
        size_t n = 0; if (sysctlbyname(oid, NULL, &n, NULL, 0) != 0) { perror(oid); return 1; }
        char *b = malloc(n + 1); if (sysctlbyname(oid, b, &n, NULL, 0) != 0) { perror(oid); return 1; }
        b[n] = 0; fputs(b, stdout); return 0;
    }
    if (argc >= 2 && !strcmp(argv[1], "devctl")) {
        int64_t v = 0, fixes = 0; size_t n = sizeof v;
        if (sysctlbyname("debug.nvrm_devctl", &v, &n, NULL, 0) != 0) { perror("debug.nvrm_devctl"); return 1; }
        n = sizeof fixes; sysctlbyname("debug.nvrm_devctl_fixes", &fixes, &n, NULL, 0);
        if (v < 0) { printf("devctl: not read yet (adapter not up)\n"); return 0; }
        printf("devctl 0x%04llx: No Snoop %s, Relaxed Ordering %s, MaxPayload %llu B, MaxReadReq %llu B; re-cleared %lld time(s)\n",
               (long long)v, (v & 0x0800) ? "ON" : "off", (v & 0x0010) ? "ON" : "off", 128ull << ((v >> 5) & 7), 128ull << ((v >> 12) & 7), (long long)fixes);
        return 0;
    }
    if (argc < 3 || strcmp(argv[1], "go")) { fprintf(stderr, "usage: nvrmctl go <pass> | nvrmctl log | nvrmctl allocs | nvrmctl devctl\n"); return 2; }
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NVRM"));
    if (!svc) { fprintf(stderr, "no NVRM service\n"); return 1; }
    io_connect_t c = 0; kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &c);
    if (kr) { fprintf(stderr, "IOServiceOpen(NVRM, 0) -> 0x%x\n", kr); return 1; }
    uint64_t pass = strtoull(argv[2], NULL, 0);
    kr = IOConnectCallScalarMethod(c, 0, &pass, 1, NULL, NULL);
    printf("go(%llu) -> 0x%x%s\n", (unsigned long long)pass, kr, kr == 0 ? " (success)" : "");
    IOServiceClose(c); return kr ? 1 : 0;
}
