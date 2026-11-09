// xlate.c: translate one AIR text file (.ll, as the plugin's aircache stores them) with the driver's own translator
// library, the way the plugin does (nvmtl_translate), and write the SPIR-V. Set METAL2VULKAN_UNMODELED_WHY=1 etc. in
// the environment to get the translator's diagnostics on stderr.
//   xlate <libnvmtl_translate.dylib> <in.ll> <stage: vertex|fragment|kernel> <out.spv>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
typedef int (*xl_fn)(const char *ll, const char *stage, uint8_t **out, size_t *out_len, char *err, size_t err_len);
typedef void (*fr_fn)(uint8_t *p, size_t len);
int main(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "usage: xlate <dylib> <in.ll> <stage> <out.spv>\n"); return 2; }
    void *h = dlopen(argv[1], RTLD_NOW); if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    xl_fn xl = (xl_fn)dlsym(h, "nvmtl_translate"); fr_fn fr = (fr_fn)dlsym(h, "nvmtl_translate_free");
    if (!xl) { fprintf(stderr, "no nvmtl_translate\n"); return 1; }
    void (*setcaps)(uint32_t) = (void (*)(uint32_t))dlsym(h, "nvmtl_translate_set_caps"); if (setcaps) setcaps(3u);   // as the plugin does
    FILE *f = fopen(argv[2], "rb"); if (!f) { perror(argv[2]); return 1; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET); char *ll = malloc(n + 1); fread(ll, 1, n, f); ll[n] = 0; fclose(f);
    uint8_t *spv = NULL; size_t len = 0; char err[4096] = "";
    int rc = xl(ll, argv[3], &spv, &len, err, sizeof err);
    if (rc) { fprintf(stderr, "translate failed (%d): %s\n", rc, err); return 1; }
    FILE *o = fopen(argv[4], "wb"); fwrite(spv, 1, len, o); fclose(o);
    fprintf(stderr, "ok: %zu bytes of SPIR-V -> %s%s%s\n", len, argv[4], err[0] ? " | " : "", err);
    if (fr) fr(spv, len); return 0;
}
