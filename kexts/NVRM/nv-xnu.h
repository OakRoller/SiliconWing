/*
 * NullMoth NVIDIA driver for macOS
 * Copyright (c) 2026 NullMoth Systems.
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#include <IOKit/IOLib.h>
#include <IOKit/IOLocks.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <libkern/libkern.h>
#include "nv-xnu-arch.h"
// Every kprintf in this kext also lands in the log ring that `sysctl -n debug.nvrm_log` reads: on Apple Silicon kprintf
// goes to a serial console nobody has and IOLog is dropped from the unified log, so the ring is the only way to read
// the bring-up (NVRM.cpp owns the ring; the real kprintf is still called through the parenthesised name).
#ifdef __cplusplus
extern "C" {
#endif
void nvrm_kprintf(const char *fmt, ...) __printflike(1, 2);
#ifdef __cplusplus
}
#endif
#define kprintf(...) nvrm_kprintf(__VA_ARGS__)

extern "C" {
enum UvmPmaGpuMemoryType_tag {};
#define NVRM 1
#include "cpuopsys.h"
#include "nv.h"
#include "os-interface.h"
#include "nv-kernel-rmapi-ops.h"
}
#undef NVRM

#define NV_XNU_STUB_HIT(name) do { static bool _hit = false; if (!_hit) { _hit = true; kprintf("NVRM-xnu: STUB %s\n", (name)); } } while (0)

struct nv_xnu_pci_slot {
    IOPCIDevice *pci;
    NvU32 domain; NvU8 bus, slot, function;
};
extern "C" {
void nv_xnu_register_pci(IOPCIDevice *pci, NvU32 domain, NvU8 bus, NvU8 slot, NvU8 function);
void nv_xnu_register_all_pci(void);
nv_dma_device_t *nv_xnu_dma_device_init(IOPCIDevice *pci);   // nv_xnu_dma.cpp: the GPU's IOMMU mapper, or identity on a PC
NvBool nvkms_xnu_backlight(NvBool set, NvU32 *percent);   // os-nvkms-xnu.cpp: laptop panel brightness
void *kern_os_malloc(size_t size);
void  kern_os_free(void *addr);
// System sleep gate (NVRM.cpp), the nv_system_pm_lock of nv.c: macOS does not freeze processes for sleep, so every
// call into RM made for a client waits here while the GPU is in standby. Returns whether the caller was counted.
int  nv_xnu_pm_enter(void);
void nv_xnu_pm_exit(int counted);
}
struct NvXnuPmUse {
    int counted;
    explicit NvXnuPmUse(bool use = true) : counted(use ? nv_xnu_pm_enter() : 0) {}
    ~NvXnuPmUse() { nv_xnu_pm_exit(counted); }
};
