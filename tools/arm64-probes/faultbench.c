// faultbench: what one shmirror-style write fault costs on this Mac (trap + signal + mprotect(RW) + return), and what
// re-protecting costs, single-threaded and with several threads faulting at once (mprotect takes the VM map lock).
// cc -O2 -o out/probes/faultbench tools/arm64-probes/faultbench.c -lpthread ; out/probes/faultbench
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <pthread.h>
#include <sys/mman.h>
#include <time.h>
#define PG 16384
static char *g_base; static size_t g_len;
static void handler(int sig, siginfo_t *si, void *uc)
{
    (void)uc;
    uintptr_t a = (uintptr_t)si->si_addr;
    if (a >= (uintptr_t)g_base && a < (uintptr_t)g_base + g_len) { mprotect((void *)(a & ~(uintptr_t)(PG - 1)), PG, PROT_READ | PROT_WRITE); return; }
    signal(sig, SIG_DFL);
}
static uint64_t now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
typedef struct { char *p; size_t pages; int rounds; uint64_t ns; } job;
static void *writer(void *v)
{
    job *j = v; uint64_t t = 0;
    for (int r = 0; r < j->rounds; r++) {
        mprotect(j->p, j->pages * PG, PROT_READ);
        const uint64_t t0 = now();
        for (size_t k = 0; k < j->pages; k++) j->p[k * PG + 64] = (char)r;
        t += now() - t0;
    }
    j->ns = t; return NULL;
}
int main(void)
{
    const size_t pages = 4096; const int rounds = 20; const int maxth = 8;
    g_len = pages * PG * maxth;
    g_base = mmap(NULL, g_len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    memset(g_base, 1, g_len);
    struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_sigaction = handler; sa.sa_flags = SA_SIGINFO; sigemptyset(&sa.sa_mask);
    sigaction(SIGBUS, &sa, NULL); sigaction(SIGSEGV, &sa, NULL);
    // baseline: same writes, no protection
    uint64_t t0 = now();
    for (int r = 0; r < rounds; r++) for (size_t k = 0; k < pages; k++) g_base[k * PG + 64] = (char)r;
    printf("no protection: %.3f us per page write\n", (now() - t0) / 1000.0 / (pages * rounds));
    // re-protect cost: per-page mprotect(READ) calls vs one call over a run
    t0 = now(); for (size_t k = 0; k < pages; k++) mprotect(g_base + k * PG, PG, PROT_READ);
    printf("mprotect(READ) one page per call: %.3f us per call\n", (now() - t0) / 1000.0 / pages);
    mprotect(g_base, pages * PG, PROT_READ | PROT_WRITE);
    t0 = now(); mprotect(g_base, pages * PG, PROT_READ);
    printf("mprotect(READ) %zu pages in one call: %.1f us\n", pages, (now() - t0) / 1000.0);
    mprotect(g_base, g_len, PROT_READ | PROT_WRITE);
    for (int th = 1; th <= maxth; th *= 2) {
        pthread_t t[8]; job j[8];
        for (int i = 0; i < th; i++) { j[i] = (job){ g_base + (size_t)i * pages * PG, pages, rounds, 0 }; pthread_create(&t[i], NULL, writer, &j[i]); }
        uint64_t sum = 0; for (int i = 0; i < th; i++) { pthread_join(t[i], NULL); sum += j[i].ns; }
        printf("%d thread(s) faulting: %.2f us per fault (per thread)\n", th, sum / 1000.0 / ((double)pages * rounds * th));
    }
    return 0;
}
