/*
 * NullMoth NVIDIA driver for macOS
 * Copyright (c) 2026 NullMoth Systems.
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 *
 * NVAccelArm: the accelerator for Apple Silicon. Apple Silicon has no IOAcceleratorFamily2 (the AGX driver sits on
 * IOGPUFamily), so the x86 NVAccel, a subclass of IOGraphicsAccelerator2, cannot be ported. It does not need to be:
 * Metal.framework (measured on macOS 27 arm64e, see docs/ARM64-PORT-NOTES.md "Accelerator design") finds GPU drivers
 * by matching the IOAccelerator class, reads MetalPluginName / MetalPluginClassName off the service, and only asks the
 * plugin class to derive from _MTLDevice. On arm64 the Metal plugin does exactly that, and the compute path (NVK) talks
 * to NVRM through the RM user clients, not through the IOAccel ones. So this kext is a plain IOAccelerator
 * (IOGraphicsFamily, public header) that
 *   1. publishes the plugin the way the x86 accelerator does, under the class name NVAccel that the plugin
 *      (nvmtl_vk_set_accelerator: IOObjectConformsTo "NVAccel") and NVK (IOServiceMatching "NVAccel") look for;
 *   2. serves the NVIDIA RM user-client types (0x4E56xxxx) by asking NVRM for its bridge client, as the x86 NVAccel does;
 *   3. logs and refuses everything else (the IOAccelDevice2 / IOAccelSharedUserClient2 types nothing opens any more).
 *
 * A second personality, NVAccelSim, matches IOResources and is gated by the boot-arg nvaccelsim=1: it publishes the
 * same plugin on a Mac without an NVIDIA GPU so Metal's enumeration and the plugin's device setup can be exercised
 * before the hardware is there (the plugin then has no NVRM and refuses to be a device, which is the expected end).
 */

#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/graphics/IOAccelerator.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <libkern/c++/OSSymbol.h>
#include <pexpert/pexpert.h>
#include <mach/kmod.h>
#include <libkern/OSKextLib.h>

#define ALOG(fmt, ...) do { kprintf("NVAccel(arm64): " fmt "\n", ##__VA_ARGS__); IOLog("NVAccel(arm64): " fmt "\n", ##__VA_ARGS__); } while (0)

static bool nvBootArg(const char *name, int dflt)
{
    int v = dflt;
    return (PE_parse_boot_argn(name, &v, sizeof v) ? v : dflt) != 0;
}

// Named NVAccel on purpose: user space matches the class name, not the bundle (see the header comment).
class NVAccel : public IOAccelerator {
    OSDeclareDefaultStructors(NVAccel)
    IOService *fNVRM = nullptr;
    bool fSim = false;
    unsigned fUcLogged = 0;
public:
    IOService *probe(IOService *provider, SInt32 *score) override;
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    IOReturn newUserClient(task_t owningTask, void *securityID, UInt32 type, OSDictionary *properties, IOUserClient **handler) override;
};
OSDefineMetaClassAndStructors(NVAccel, IOAccelerator)

IOService *NVAccel::probe(IOService *provider, SInt32 *score)
{
    if (!IOAccelerator::probe(provider, score)) return nullptr;
    const bool sim = OSDynamicCast(IOPCIDevice, provider) == nullptr;
    if (sim) {
        if (!nvBootArg("nvaccelsim", 0)) return nullptr;              // the no-GPU test personality is opt-in
        ALOG("probe: simulated accelerator on %s (nvaccelsim=1)", provider->getName());
        return this;
    }
    if (PE_parse_boot_argn("-nvoff", nullptr, 0)) { ALOG("probe: -nvoff, leaving the card alone"); return nullptr; }
    if (!nvBootArg("nvaccel", 1)) { ALOG("probe: nvaccel=0, no accelerator"); return nullptr; }
    return this;
}

bool NVAccel::start(IOService *provider)
{
    if (!IOAccelerator::start(provider)) return false;
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, provider);
    fSim = pci == nullptr;
    ALOG("start on %s (%04x:%04x)%s", provider->getName(), pci ? pci->configRead16(0x00) : 0, pci ? pci->configRead16(0x02) : 0,
         fSim ? " SIMULATED: no GPU behind this accelerator" : "");
    // What Metal reads off the accelerator before it loads the plugin. Values follow the x86 accelerator's Info.plist.
    setProperty("MetalPluginName", "../../../Library/GPUBundles/NVMTLDriver");
    setProperty("MetalPluginClassName", "NVMTLDevice");
    setProperty("IOGLBundleName", "AppleMetalOpenGLRenderer");
    setProperty("NVAccelArm", kOSBooleanTrue);
    if (fSim) setProperty("NVAccelSim", kOSBooleanTrue);
    registerService();
    return true;
}

void NVAccel::stop(IOService *provider)
{
    ALOG("stop");
    if (fNVRM) { fNVRM->release(); fNVRM = nullptr; }
    IOAccelerator::stop(provider);
}

IOReturn NVAccel::newUserClient(task_t owningTask, void *securityID, UInt32 type, OSDictionary *properties, IOUserClient **handler)
{
    (void)securityID; (void)properties;
    if ((type & 0xFFFF0000u) != 0x4E560000u) {
        // IOAccelDevice2 (5) / IOAccelSharedUserClient2 (6) and friends: the arm64 plugin never opens them. Logged so a
        // Metal change that starts to would show up at once.
        if (fUcLogged < 20) { fUcLogged++; ALOG("newUserClient(type %u / 0x%x): not an RM client type -- refused", (unsigned)type, (unsigned)type); }
        return kIOReturnUnsupported;
    }
    if (fSim) { ALOG("newUserClient(0x%x): simulated accelerator has no NVRM", (unsigned)type); return kIOReturnNotAttached; }
    if (!fNVRM) {
        OSDictionary *m = serviceMatching("NVRM");
        if (m) { fNVRM = waitForMatchingService(m, 100ULL * 1000 * 1000); m->release(); }
    }
    if (!fNVRM) { ALOG("newUserClient(0x%x): no NVRM service", (unsigned)type); return kIOReturnNotAttached; }

    const OSSymbol *fnSym = OSSymbol::withCStringNoCopy("nvNewAccelClient");
    if (!fnSym) return kIOReturnNoMemory;
    IOUserClient *uc = nullptr;
    // p4 = this: an NVRM that knows the argument attaches and starts the client itself and explains a failure in its
    // own log ring; an older NVRM ignores p4 and the client comes back unattached, handled below as before.
    IOReturn r = fNVRM->callPlatformFunction(fnSym, false, (void *)owningTask, (void *)(uintptr_t)(type & 0xFFFFu), &uc, (void *)this);
    fnSym->release();
    if (r != kIOReturnSuccess || !uc) { ALOG("newUserClient(0x%x): NVRM refused (0x%x)", (unsigned)type, (unsigned)r); return r ? r : kIOReturnNoResources; }
    if (uc->getProvider() != this) {
        // a client released here without being closed kept its slot in NVRM's client table and panicked a later open
        // (2026-11-04); close it first, which NVRM's own free() now also guarantees
        if (!uc->attach(this)) { ALOG("newUserClient(0x%x): attach failed", (unsigned)type); uc->clientClose(); uc->release(); return kIOReturnInternalError; }
        if (!uc->start(this)) { ALOG("newUserClient(0x%x): start failed", (unsigned)type); uc->detach(this); uc->clientClose(); uc->release(); return kIOReturnInternalError; }
    }
    if (fUcLogged < 20) { fUcLogged++; ALOG("newUserClient(0x%x) -> %s (rm type %u)", (unsigned)type, uc->getMetaClass()->getClassName(), (unsigned)(type & 0xFFFFu)); }
    *handler = uc;
    return kIOReturnSuccess;
}

// kmutil refuses a kext without a kmod_info symbol; the explicit declaration is what the x86 kexts use too
extern "C" kern_return_t NVAccelArm_start(kmod_info_t *, void *);
extern "C" kern_return_t NVAccelArm_stop(kmod_info_t *, void *);
extern "C" { KMOD_EXPLICIT_DECL(com.nullmoth.NVAccelArm, "0.1", NVAccelArm_start, NVAccelArm_stop) }
extern "C" kern_return_t NVAccelArm_start(kmod_info_t *, void *) { return KERN_SUCCESS; }
extern "C" kern_return_t NVAccelArm_stop(kmod_info_t *, void *) { return KERN_SUCCESS; }
