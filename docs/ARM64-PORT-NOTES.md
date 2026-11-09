# Apple Silicon (arm64e) port: working notes

Branch `arm64-port`. Target: render on the NVIDIA card over a Thunderbolt eGPU, display on the Apple screen through the
accelerator's headless mode (gNvHeadless in kexts/NVRM/accel/nvrm-accel.cpp). NVRMFB (IOFramebuffer display output) is not
a goal: Apple Silicon has no IOFramebuffer consumers (all displays are IOMobileFramebuffer / DCP).

Background and the full audit: `../arm64-port-audit.md` in the workspace root.

## State

Done, no hardware yet:

- **RM builds for Darwin arm64e from NVIDIA's own makefiles.** `build/arm64/build_rm.sh` runs `make -C src/nvidia` and
  `src/nvidia-modeset` with `TARGET_OS=Darwin TARGET_ARCH=arm64` and Darwin kernel flags, builds objects only
  (`objs.mk`, since macOS has no GNU `ld -r`/objcopy), and archives them as `libnvkernel.a` / `libnvkms.a`.
  1100 RM objects, 225 modeset objects, zero errors. Two one-line patches to the vendor tree
  (`build/arm64/patches/615-darwin-build.patch`): `nvUnixVersion.h` accepts `NV_DARWIN`; `cpuopsys.h` no longer takes
  an Apple Silicon Mac for a big-endian PowerPC Mac (`NV_MACINTOSH && !x86` → PPC). That second one would have
  byte-swapped everything.
- **NVRM.kext links for arm64e** (`build/arm64/build_nvrm.sh`, 17.5 MB). Compared with the x86_64 build of the same
  sources, the set of OS-interface functions still on weak stubs is identical except that the DMA functions are now
  real; the kernel imports differ only by the IODMACommand/IOMapper symbols the new DMA code uses.
- **x86 specifics behind `NV_XNU_X86` / `NV_XNU_ARM64` / `NV_XNU_ACPI`** (`kexts/NVRM/nv-xnu-arch.h`): string
  instructions, `sfence`/`mfence`, `cpuid`, port I/O, the IOACPIFamily dependency and `_CRS`/`_DSM`/`_DOD` code,
  `placeLargeBar1()` (returns "acceptable as is" on arm64), the EFI boot-screen copy, the root-port window restore after
  wake. x86 keeps the original code paths.
- **DMA through the DART** (`kexts/NVRM/nv_xnu_dma.cpp`): `nv_requires_dma_remap()` is true on arm64, so the RM keeps a
  per-GPU IOVA space; `nv_dma_map_alloc()` maps the physical pages with an IODMACommand on
  `IOMapper::copyMapperForDevice(fPCI)` and writes bus addresses back into the RM's array. Peer/MMIO mappings return
  NV_ERR_NOT_SUPPORTED (one eGPU, no peers). x86 keeps identity.
- Page size: the XNU layer already used `PAGE_SIZE` consistently for OS pages and `os_page_size = PAGE_SIZE`, which is
  the same contract NVIDIA's aarch64 Linux build uses with 64 KB pages. The `>> 12` hardcodes are all inside the
  `NVRM_PANIC_HUNT` diagnostics, which shipped builds leave out.

Verified against the running kernel: every one of the 482 symbols NVRM.kext imports exists in this Mac's kernel
collection (macOS 27.0.1, unwrapped from the Preboot kernelcache with `build/arm64/unwrap_kernelcache.py`).

## Finding: IOAcceleratorFamily2 does not exist on Apple Silicon

The boot kernel collection holds 345 kexts; `IOAcceleratorFamily2` is not one of them and it is not loaded. The AGX
driver depends on `com.apple.iokit.IOGPUFamily` instead (IOGPUDevice, IOGPUResource, IOGPUCommandQueue, ...). The
small `IOAccelerator` base class (createAccelID / retainAccelID / releaseAccelID, from IOGraphicsFamily) is present,
and Metal still finds GPU plugins by `MetalPluginName` / `MetalPluginClassName` on an `IOAccelerator` service.

Consequence for NVAccel: `kexts/NVRM/accel/` subclasses `IOGraphicsAccelerator2`, `IOAccelResource2`,
`IOAccelLegacySurface`, ... from reverse-engineered headers, and `tahoe_fwd.h` jumps through their vtables. None of
those classes exist here, so the x86 accelerator cannot be ported; an arm64 accelerator has to be a direct
`IOAccelerator` subclass with its own user clients (RM escapes, surface handles), and the kernel-side IOSurface
integration (`IOGraphicsAccelerator2::deviceCacheForIOSurface`, `nvrm_surfshare`) has no counterpart. The headless
route copies frames into IOSurfaces from user space, so it does not need that integration for a first version.

What Metal needs from that kext, measured (`tools/arm64-probes/`): on this macOS, `MTLIOAccelDevice
initWithAcceleratorPort:` opens the IOAccelerator service with user-client type 5 and calls struct selectors 9 (16 B in)
and 2 (600 B out) first; a device whose user client answers those the way IOAccelDevice2 did on Intel is the entry
ticket. The rest of the IOAccelDevice2 / IOAccelSharedUserClient2 / IOAccelContext2 selector ABI is what the x86
accelerator got for free by inheriting from IOGraphicsAccelerator2, and will have to be reimplemented; the client side
of that ABI is in Metal.framework (extractable from the dyld shared cache with Apple's dsc_extractor.bundle).

First cut of that kext: `kexts/NVAccelArm/` (`build/arm64/build_nvaccel_arm.sh`, 106 KB arm64e). A direct
`IOAccelerator` subclass that matches the NVIDIA PCI function, publishes `MetalPluginName` / `MetalPluginClassName`,
and serves user-client types 5 and 6 by logging every selector with its sizes; with boot-arg `nvaccelfake=1` it returns
zeroed success so Metal walks on and reveals the next call. Measured from user space so far (`tools/arm64-probes/`):
type 5 selectors 9 (16 B in), 2 (600 B out), 0 (64 B out), 7 (24 B out); then an IOSurfaceRoot handshake; then type 6
selectors 9 (16 B out), 10 (24 B out). On hardware this kext will extend that list; the real implementation follows.

## Accelerator design (decided, verified on this Mac without the GPU)

The question from the first cut was whether `MTLIOAccelDevice`'s own code paths work without an IOAcceleratorFamily2
kernel side. Read out of Metal.framework (macOS 27.0.1 arm64e, extracted from the dyld shared cache; disassembly with
llvm-objdump plus a small stub resolver, `tools/arm64-probes/README.md` says how):

- Device enumeration is one path for every GPU, Apple's included: `-[MTLIOAccelServiceGlobalContext init]` matches the
  `IOAccelerator` class (the AGX accelerator carries `MetalPluginName = AGXMetalG13X`, `MetalPluginClassName =
  AGXG13XDevice` and is found the same way), `_getMetalPluginClassForService` reads `MetalPluginName`, passes it through
  libsystem_sandbox's `gpu_bundle_find_trusted`, loads the bundle, reads `MetalPluginClassName` (else the principal
  class) and only checks `isSubclassOfClass:_MTLDevice`. `-[MTLIOAccelService initWithAcceleratorPort:deviceClass:]`
  refuses services conforming to `IOServiceCompatibility`, reads `Removable` (only when the process avoids removable
  GPUs) and `SafeEjectRequested`, then `[[deviceClass alloc] initWithAcceleratorPort:]`, `_setAcceleratorService:`,
  `_MTLAddDevice` (conformsToProtocol `MTLDevice` and `MTLDeviceSPI`, then `initLimits`, `initFeatureQueries`,
  `initWorkarounds`).
- `-[MTLIOAccelDevice initWithAcceleratorPort:]` is where IOAcceleratorFamily2 is needed: `IOAccelDeviceCreateWithAPIProperty`
  (user client type 5: selector 9 = set_api_property "Metal", 2 = 600-byte event machine data whose first word is a
  user-space address of mapped stamp memory, 0 = 64-byte config, 7 = device info), then `lazyInitialize` creates the
  type-6 shared client (selector 9 = shared info with two mapped addresses, 10 = dirty ring whose header must be mapped:
  the client reads `*(uint32 *)(ring + 4)`, which is why the recording skeleton's zeroed success crashed the probe),
  two `MTLIOAccelResourcePool`s and the command-buffer storage pool (new_resource with the 2440-byte args). The public
  properties come from the 64-byte config: `isHeadless` bit 11, `isLowPower` bit 10, `hasUnifiedMemory` bit 12,
  `isRemovable` bit 13; `registryID` is `IORegistryEntryGetRegistryEntryID` of the accelerator.
- Nothing else in the plugin needs that class: every NVMTL object is a plain NSObject on top of NVK, NVK reaches NVRM
  through the RM user clients (`IOServiceMatching("NVAccel")` with type `0x4E56xxxx`, falling back to `NVRM`), and
  `MTLIOAccelResourcePool` is only used when `NVMTL_HWPOOL` is set.

So the arm64 driver does not reimplement IOAccelDevice2 / IOAccelSharedUserClient2 at all:

- **Plugin**: with `NVMTL_APPLE_SILICON` (set by `build/arm64/build_plugin.sh` for both slices) `NVMTLDevice` derives
  from `_MTLDevice` and answers the driver surface itself (`plugin/NVMTLDevice.m`, "arm64 device" at the end:
  registryID, acceleratorPort, _setAcceleratorService:, isHeadless YES, isLowPower NO, isRemovable from the PCI
  parent's `IOPCITunnelled`, location External/Slot, maxTransferRate from `IOPCIExpressLinkStatus`, peer group none,
  hasUnifiedMemory NO). `nvmtl_install_hw_resource_pools` is skipped there.
- **Kext** `kexts/NVAccelArm/` (class name `NVAccel`, the name NVK and the plugin match): a plain `IOAccelerator` on the
  NVIDIA PCI function that publishes `MetalPluginName` / `MetalPluginClassName` / `IOGLBundleName`, forwards the RM
  user-client types to NVRM's `nvNewAccelClient` platform function exactly like the x86 accelerator, and refuses the
  IOAccel types with a log line. Boot-args: `nvaccel=0` disables it, `-nvoff` too. A second personality on
  `IOResources`, gated by `nvaccelsim=1`, publishes the plugin without a GPU (kernel-side counterpart of the harness
  below). 83 KB arm64e, `build/arm64/build_nvaccel_arm.sh`.
- **No-GPU harness** `tools/arm64-probes/run_enumsim.sh` (enumsim.m + enumsim_interpose.c): interposes
  `IORegistryEntryCreateCFProperty` so the AGX accelerator's `MetalPluginName` answers with our bundle, and
  `gpu_bundle_find_trusted` to accept the absolute path; `NVMTL_SIM_NO_GPU=1` (debug builds only) keeps the device
  although NVK is down. Result on this M1 Pro, both `ARCH=arm64` and `ARCH=x86_64` (Rosetta):
  `MTLCopyAllDevices` returns `NVMTLDevice -> _MTLDevice -> NSObject`, `_MTLAddDevice` ran `initLimits` (featureProfile
  10002: maxTextureWidth2D 16384, maxComputeTextures 128, maxComputeBuffers 31), the properties read back, and
  `newLibraryWithSource:` goes MSL -> AIR (Apple's compiler service) -> in-process bitcode read -> our translator ->
  SPIR-V (`add1 (kernel) -> 1200 bytes of SPIR-V`, `functionNames: add1, vmain, fmain`). `newCommandQueue` is nil
  because there is no NVK device, as expected.
- **AIR bitcode reader on Apple Silicon**: the release package's `air-runtime/libLLVM.dylib` is x86_64. With none
  bundled, `plugin/NVMTLLibraryLoad.m` now falls back to Apple's own
  `GPUCompiler.framework/Versions/32023/Libraries/libLLVM.dylib` (shared-cache resident, dlopen by path works, same C
  API; NVMTLGL.m already used it). It lacks the IR-walk API, so the simdgroup-matrix unroll pass stays off there.
- The plugin opens the NVK ICD directly (`vk_icdGetInstanceProcAddr`) and only falls back to a Vulkan loader, so no
  loader build is needed for Apple Silicon.

## Rosetta (x86_64 apps)

- `build/arm64/build_nvk_x86_64.sh` cross-compiles NVK with `build/arm64/x86_64-apple-darwin.cross` (host mesa_clc /
  vtn_bindgen2 reused; `rust_ld` must name a one-word linker, see the cross file) ->
  `out/x86_64/nvk/libvulkan_nouveau.dylib` (19.9 MB, no unresolved strong references). ~25 min from scratch.
- The translator already builds for `x86_64-apple-darwin`; the harness runs the x86_64 plugin slice under Rosetta
  through the same path as arm64 (see above).

## Installer

`package/install.sh` / `uninstall.sh` branch on `uname -m`: arm64 installs `NVRM.kext` + `NVAccelArm.kext` only,
inspects with `kmutil -a arm64e`, uses the Preboot kernelcache and `kernel.release.<chip>` for the test build, checks
the boot policy (`bputil -d`, `csrutil status`) and prints the recoveryOS instructions (Permissive Security) instead of
dying mysteriously, stages the kexts with `kmutil load -p` (the AuxKC on Apple Silicon is built by kernelmanagerd after
the user approves the kexts in System Settings), and the boot guard counts a start good when `com.nullmoth.NVRM` is
loaded and the PCI device carries `nvrm-gpu-profile`. The x86 path is byte-for-byte the old one. Boot-args on arm64:
only the three AMFI arguments matter (`nvfb=1` / `nvaccel=1` are read by x86 kexts only). Verified against the repo's
installer tests and a mocked arm64 dry run; the kmutil behaviour under each policy is untested on hardware.

Not done:

- NVAccel beyond the plugin-publishing kext above: nothing serves `IOAccelDevice2` / `IOAccelSharedUserClient2`, so a
  process that used Metal's `MTLIOAccel*` object classes directly (none known) would get no device. `tools/vtdump.py`
  and `accel/tahoe_fwd.h` stay x86-only and unused here.
- Package assembly: `build/arm64/package.sh` builds `out/package-arm64/` (kexts, universal `NVMTLDriver.bundle` with
  the universal translator beside it, universal `nvmtl/libvulkan_nouveau.dylib`, `nvk_icd.json`, `nvmtl-allow.txt`, a
  placeholder `NVIDIAShared.bundle`, the installer). The firmware (gsp_ga10x / gsp_tu10x / ucodes_ga10x / ucodes_tu10x,
  sha1s in `kexts/NVRM/os-xnu2.cpp`) is not in the repo: it is taken from `out/package-src/Users/Shared/nvfw`, filled
  from NVIDIA's own `NVIDIA-Linux-x86_64-615.78.08.run` (download.nvidia.com, archive sha256 checked; the firmware/
  directory extracted with zstd + tar, nothing from the archive executed). NVIDIA's driver licence allows redistributing
  the unmodified firmware with the licence text, worded around OSI-licensed kernels; `LICENSE-nvidia-firmware.txt`
  travels with the files and the question of whether that grant covers a macOS package is the maintainer's call.
  Installing has not been tried (needs sudo and Permissive Security).
- `NVIDIAShared.bundle` (NVIDIA's NVVM libraries for the vendor SASS lane) is x86_64 only; on Apple Silicon the NVK /
  NAK lane is the only compiler. Not needed for correctness.
- `NVCPU_IS_PCIE_CACHE_COHERENT` is 0 for aarch64 in NVIDIA's headers (Tegra). Apple's PCIe is IO-coherent; leaving it
  at 0 makes the RM pick uncached allocations for shared structures, which is safe but slower. Revisit after bring-up.
- Nothing has run on hardware. First test (once the eGPU arrives): `bash tools/arm64-probes/egpu_probe.sh` with no
  driver installed (BARs, MSI, the DART, Thunderbolt link, the security policy); then Permissive Security, install, and
  try loading NVRM.kext.

## Hardware measured (kernel log of the user's TinyGPU session on this M1 Pro)

The enclosure was attached to this MacBook Pro from 16:17 to 17:22 CST (not during the probe run, so `egpu_probe.sh`
saw nothing; its `out/egpu-probe-*/hotplug.txt` and `session.txt` hold the log excerpts). Measured:

- Card: `10de:2488` = **GA104 (GeForce RTX 3070 LHR)**, not a 3060 (`10de:2503/2504` would be GA106); audio
  function `10de:228b`. Both Ampere, so `gsp_ga10x.bin` / `ucodes_ga10x.bin` are the right firmware.
- Topology: apciec root `106b:100f` -> Titan Ridge `8086:15ef` (bus 1) -> bridges 2:1/2:2/2:4 -> GPU at **67:0:0**,
  the USB controller `8086:15f0` at 3:0:0. `IOPCIFamily [serializeLinkStatus()] 67:0:0 has linkStatus 0x1043` =
  **Gen3 x4 (8 GT/s)** as trained, the ceiling of a JHL7540.
- DART: `apciec::_mapRIDToSID created mapper for RID 0x4300(67:0:0) SID 2` (the audio function gets SID 3); the
  mapper is per device and is what `IOMapper::copyMapperForDevice` returns to `nv_xnu_dma.cpp`. Unplug unmaps it.
- DMA through that mapper (tinygpu's `IODMACommand`, 40 address bits): every `PrepareDMA` in the session returned
  **one segment**, including 16 MiB and 63.6 MiB buffers, so DART IOVA allocations are contiguous; the contiguous
  path in `nv_dma_map_alloc` will be the common case.
- 40 minutes of tinygrad with no DART fault, link timeout or AER line in the kernel log; the device went away cleanly
  on unplug (`_unmapRIDFromSID ... RID 0x4300`).
- TinyGPU's dext (`org.tinygrad.tinygpu`, match category `TinyGPUDriver`, class match `0x03000000&0xff000000`,
  `IOPCITunnelCompatible`) attaches on plug and opens the device with bus mastering. Its match category differs from
  NVRM's, so IOKit would attach both; **the dext must be deactivated before NVRM.kext is tested** on the same card.
- Read from `ioreg` with the card attached (17:54, no driver attached, TinyGPU inactive):

  | | |
  |---|---|
  | BAR0 | 16 MiB at 0x1201000000 (registers) |
  | BAR1 | 256 MiB at 0x1240000000 (VRAM window; resizable BAR not enabled by IOPCIFamily) |
  | BAR3 | 32 MiB at 0x1250000000 |
  | ROM | 512 KiB at 0x1202000000 |
  | Link | Gen3 x4 trained; the card advertises Gen1-4 (`IOPCIExpressLinkCapabilities2`), the TB3 bridge caps it |
  | MSI | capability at config 0x68, 64-bit, 1 vector, not enabled (`IOPCIMSIMessageControl 0x80`); no `IOInterruptSpecifiers` on the nub until a driver asks |
  | DART | `IOPCIDeviceMapperPageSize 16384`; mapper nub `mapper-apciec2-67-0-0` under `dart-apciec2`, created at plug |
  | Dext | `IODEXTMatchCount 1`: TinyGPU's personality matched the nub; it only attaches when its app activates it |

  NVRM tells the RM `os_page_size = PAGE_SIZE` = 16 KiB (`os-xnu.cpp`), the DART's granule, which is what the Linux
  driver does on 16 K/64 K-page aarch64 kernels; the RM splits OS pages into its 4 KiB pages itself. BAR1 at 256 MiB is
  the plain non-resizable layout `placeLargeBar1()` already leaves alone on arm64. The one thing still unmeasured is
  whether IOPCIFamily hands a kext an MSI interrupt source for a tunnelled device (NVRM refuses to start without one).

## First loads on hardware

SIP off (Permissive), boot-args set as in `ARM64-FIRST-BOOT.md`, package installed with `install.sh`, TinyGPU's dext
deactivated. Observed in the kernel log:

- Both kexts load from the AuxKC (`com.nullmoth.NVRM`, `com.nullmoth.NVAccelArm`), NVRM matches 67:0:0 and the nub
  gets `IOPCIMSIMode = Yes`: **IOPCIFamily does hand a kext an MSI for a tunnelled device**, the last open question.
- The Metal plugin loads in WindowServer and apps (`NVAccel(arm64): newUserClient(0x4e560000/1) -> IOAccelNVRMBridge`),
  so the accelerator and the RM client forwarding work.
- `rm_init_adapter` runs up to `kgspConstructEngine` -> `_kgspInitRpcInfrastructure` -> `GspMsgQueueInit`, where
  `memdescMap` of the shared message queue fails: `osMapSystemMemory: failed to create system memory kernel mapping!`,
  then `osInitNvMapping: *** Cannot attach gpu`. The boot guard logged "NVRM did not bring the card up within four
  minutes" three times. No panic, the device survived, unplug was clean.
- Root cause: `nv_pm_init()`'s self-test in `os-xnu2.cpp` used 4 KB page constants, failed on the 16 KB kernel, and
  `nv_pm_ok()` then refused every `nv_alloc_kernel_mapping`. Fixed to use PAGE_SIZE multiples. The remaining `>> 12`
  users are the PV-sentinel diagnostics (`nv_diag_on()` only), not on the normal path.
- Harmless so far: `_sysCreateOs: RM Access Sys Cap creation failed: 0x56` (NV_ERR_NOT_SUPPORTED).
- Three more things the same evening taught (this session):
  - **A reinstall with the same CFBundleVersion does not reach the kernel.** kernelmanagerd keeps the first binary it
    staged for a version; two reinstalls of "0.1" left UUID EC80B3F0 running while /Library/Extensions held newer
    code. `build_nvrm.sh` / `build_nvaccel_arm.sh` now stamp `0.<day of year>.<minute of day>` into every build
    (a kext version component may not exceed four digits, so a minutes-since-epoch stamp was rejected).
    `kmutil showloaded --bundle-identifier com.nullmoth.NVRM` prints the loaded UUID; compare with `dwarfdump --uuid`.
  - Earlier failures in order: `rm_is_supported_device -> 0xF` (GPU_IS_LOST) because the function came up with PCI
    command 0x0000 and BAR0 read all-ones (memory decoding is now enabled at the top of `go()`); before that the BAR
    table was empty because `readBARs()` compared CPU addresses with BAR register values, which differ behind apciec
    (now `getDeviceMemoryWithRegister`). `go()` opens the IOPCIDevice; without a `didTerminate()` that closes it an
    unplug left NVRM "inactive, busy 1" forever (fixed).
  - Neither kprintf nor IOLog from this kext reaches the unified log on this Mac; `nv_printf` lines (kernel printf)
    do, with a `[ seconds]:` prefix. Every kprintf now also lands in a 256 KB ring: `sudo ./nvrmctl log`
    (`sysctl -n debug.nvrm_log`); `sudo ./nvrmctl go 2` reruns the bring-up pass without a reboot.
  - The boot guard (`nvrm_off.h`, NVRAM `nullmoth-nv-starts`, limit 2) and the installer's fallback daemon were
    written for a card that drives the boot display. On Apple Silicon the card never is the boot display, every
    bring-up attempt that fails counts as a bad start, and two in a row would switch the driver off and restore the
    previous backup. The guard is now compiled out on arm64 (`nvrm_off.h`); `install.sh` still resets the counter.
  - `NOGPU=1 sudo bash install.sh` installs with the enclosure unplugged (skips the PCI presence and generation
    checks). Needed because a kext change only takes effect after a reboot, and a panic on plug-in would otherwise
    be the only way to find out.

### The panic series

With the mapping self-test fixed the adapter got much further, and each step ended in a panic that `.panic` files in
`/Library/Logs/DiagnosticReports` plus `tools/arm64-probes/panicsym.py` (symbolicates a backtrace against the NVRM
binary) explained:

1. `hwlock: thread recursively acquired` in NVRM's first `probe()` log line, three times. The kprintf log ring copied
   with `memcpy`, which the RM headers resolve to `os_mem_copy`, which kprintfs, which takes the ring's lock again.
   The ring now copies with plain byte loops and locks with interrupts disabled (the MSI filter kprintfs too).
2. `Unaligned kernel data abort` at `kvidengInitLogging_KERNEL+0xac` (`stur xzr, [x22, #4]`, ESR 0x96000061: an
   8-byte store at offset 4). Reached **after `gpuStateLoad` started, i.e. the GSP firmware had booted on the card
   over Thunderbolt with DART DMA and MSI under macOS**. The store is the video-engine trace ring header; the ring
   lives in `ADDR_FBMEM` and the RM writes it through BAR2 (`kbusMapRmAperture`), so the fault was never about
   system memory: two builds that made `nv_alloc_pages` / `os_map_kernel_space` cacheable for RAM (right in
   themselves: Apple PCIe DMA is coherent, and Device-typed RAM would fault the same way) faulted at the same
   instruction. On arm64 `kIOMapInhibitCache` is Device-nGnRnE memory, where unaligned accesses are architecturally
   faults; `os_map_kernel_space` now maps BAR1 (VRAM window) and BAR2 (RM aperture) with `kIOMapWriteCombineCache`,
   which XNU's arm64 pmap types as Normal non-cacheable (what Linux's `ioremap_wc` gives prefetchable BARs). BAR0
   keeps the Device mapping: registers are accessed aligned and must stay ordered. Build 0.307.1307 (UUID 592D2D2F)
   carried this and **panicked at the same instruction** (the fourth time), which settled the question: XNU's arm64
   pmap (`wimg_to_pte`) maps a non-DRAM address as Device-GRE for VM_WIMG_WCOMB and Device-nGnRnE otherwise, and on
   PPL systems `pmap_construct_io_pte` takes the attributes from the IO-range table, so no cache option a kext can
   pass yields a Normal mapping of a BAR. `osMapPciMemoryKernelOld` had in fact asked for WRITECOMBINED all along.
3. The fix is therefore on the code side, build 0.307.1329 (UUID 295E5780):
   - `-mstrict-align` for the RM libraries (`RM_DARWIN_CFLAGS_arm64e`) and the kext (`KEXT_CXXFLAGS`): clang then
     never widens two 32-bit stores into a 64-bit store at a 4-byte offset; the trace-header store became
     `stp w8, wzr, [x22]` (pairs of 32-bit elements only need 4-byte alignment on Device memory). `tools/arm64-probes/
     unaligned_scan.py` counts immediate-offset accesses not aligned to their width: 1328 before, 60 after, the rest
     in packed GSP structures in system memory.
   - `kexts/NVRM/nv_xnu_memfuncs.cpp` defines `memmove`, `bzero`, `memcmp` and the `__*_chk` variants with
     naturally aligned 8-byte or byte accesses, so compiler-generated struct copies and zero-initialisers no longer
     reach libkern's arm64 routines (overlapping unaligned loads, `dc zva`), which abort on a BAR. `memcpy`/`memset`
     already went through `os_mem_copy`/`os_mem_set` (NVIDIA's gcc_helper.c) and `nv_xnu_memcpy`/`nv_xnu_memset`.
     `nm -u` of NVRM now lists none of the libkern memory routines.
   - Accesses the RM makes through an explicit cast to a wider type at a misaligned BAR offset would still fault;
     none has shown up yet.
   - `os_map_kernel_space` keeps asking for write-combine on BAR1/BAR2 (harmless; Device-GRE lets the fabric gather
     the RM's bulk writes).
   **Booted without a panic** (22:18). The card is a GeForce RTX 3070 (10de:2488, GA104), not the 3060 the notes
   assumed. The log (`nvrmctl log`, 406 lines) shows BARs at 0x1201000000 / 0x1240000000 (256 MB) / 0x1250000000,
   DART page size 16 KB, `rm_init_rm OK`, the GSP firmware booting over DMA + MSI, `gpuStateLoad` running through
   video logging, and the first failure in the memory manager:
   `memmgrDeterminePageSize failed, status: 0x40` while the CE scrubber allocated its push buffer
   (`memmgrMemUtilsChannelInitialize_GM107`), which took `RmInitNvDevice` down (0x25:0x40:1327).
4. 16 KB OS pages are not a GPU page size. The RM takes `osGetPageSize()` as the sysmem GPU page size (Linux only
   runs on 4 KB and 64 KB kernels, both GMMU page sizes); 16 KB reaches `default: return 0` in
   `memmgrDeterminePageSize`, and would have reached the GMMU as an invalid page size through
   `memmgrSetMemDescPageSize_GM107` and `memdescGetAdjustedPageSize` next. `osGetPageSize()` itself must stay 16 KB
   (`osGetPagesInfo` derives the OS page count from it). The Darwin patch (`build/arm64/patches/615-darwin-build.patch`,
   regenerated from `git diff` of the vendor tree) now clamps a page size strictly between 4 KB and 64 KB to
   `RM_PAGE_SIZE` at those three sites: allocations still happen in whole OS pages, the GPU maps each as four RM
   pages (the page arrays are already inflated to 4 KB entries by `RmInflateOsToRmPageArray`). GSP is still told
   `HOST_PAGE_SIZE` 16 KB; it booted with that. Build 0.307.1344 (UUID AFB66DEE).
5. **22:28: `PASS 2 REACHED: the adapter is up — GSP-RM is running on the card under macOS`.** `RmInitAdapter
   succeeded!`, `rm_init_adapter -> OK` after 3.4 s, three MSIs handled during the boot, 8 GB VRAM published,
   110 engine classes (3d 0xc797, compute 0xc7c0, copy 0xc7b5), NVKMS loaded and probed the GPU, `nvrm-autogo = up`,
   NVAccel published with `MetalPluginName`/`MetalPluginClassName`. The display stack reports heads 0x0 (expected:
   nothing drives a head on Apple Silicon). Stubs hit on the way, all harmless: os_strtoul, os_get_smbios_header,
   nv_start_rc_timer, nv_i2c_add_adapter, nv_get_device_memory_config, nv_acpi_ddc_method.
6. First user-space contact: `enumsim` died with SIGILL inside NVK, `util_cache_granularity` reading `CTR_EL0`
   (`mrs x9, ctr_el0`, Mesa `src/util/cache_ops_aarch64.c`). macOS keeps SCTLR_EL1.UCT clear, so EL0 may not read
   the cache type register; the `dc` maintenance instructions by VA are allowed. Patched (vendor/mesa commit,
   `build/arm64/patches/nvk-arm64.patch` regenerated) to take `hw.cachelinesize` (128 on M1 Pro) from sysctl, step
   `dc` by 64 bytes. With the rebuilt NVK (`NVMTL_ICD_LIB` points the plugin at it without reinstalling):

       MTLCopyAllDevices -> 2 device(s)
         NVIDIA GeForce RTX 3070 (NVMTL over NVIDIA GeForce RTX 3070 (NVK GA104-A))  [NVMTLDevice -> _MTLDevice -> NSObject]
         Apple M1 Pro  [AGXG13XDevice -> ... -> _MTLDevice -> NSObject]
       NVMTLDevice: registryID 0x100001a51 headless 1 removable 1 recommendedMaxWorkingSetSize 8589934592
         supportsFamily Mac2 1 Common3 1 Metal3 1; newCommandQueue -> queue; newLibraryWithSource -> library

   so Metal enumerates the card next to the M1 Pro, NVK opened a context on it, and MSL compiled through the
   translator (AIR -> SPIR-V -> NAK). `MTLCreateSystemDefaultDevice` still answers the M1 Pro, as it should.
7. **22:35: the card computed.** `tools/arm64-probes/computesim.m` (shipped as `computesim` in the package) picks the
   NVMTLDevice, compiles `out[i] = a[i] * 2 + b[i]` from MSL source, dispatches it over 1 M floats in shared
   buffers, waits, and checks every element on the CPU:

       device: NVIDIA GeForce RTX 3070 (NVMTL over NVIDIA GeForce RTX 3070 (NVK GA104-A))
       pipeline: maxTotalThreadsPerThreadgroup 1024, threadExecutionWidth 32
       command buffer status 4 (4 = completed); 8.75 ms wall
       checked 1048576 floats: 0 wrong -> THE CARD COMPUTED IT

   Metal compute on an NVIDIA GPU under Apple Silicon, end to end: Metal -> NVMTLDriver -> translator -> NVK/NAK ->
   NVRM.kext (DART DMA, MSI) -> GSP-RM -> GA104, with the results back in CPU-visible shared memory. No kernel log
   noise during the run beyond the mapping lines. 22:45: reinstalled with the fixed NVK (card plugged in, no reboot
   needed for user-space files), `computesim 4194304` with no overrides: 4 M floats, 17.4 ms, 0 wrong; `enumsim`
   clean; the kernel log's only "failed" line is the harmless Sys Cap one.
8. **22:50-23:00: textures, render passes and presentation all pass unchanged.** The x86 plugin's rendering code runs
   as is on NVK/arm64. `tools/arm64-probes/rendersim.m` (texture upload + blit readback, compute sampling, clear +
   triangle, textured quad), `rendersim2.m` (Depth32Float + depth test, indexed instanced draw, generateMipmaps,
   BGRA8 sRGB target with alpha blend and scissor, two-attachment MRT, 4x MSAA with resolve): 0 failures each.
   `winsim.m`: an NSWindow whose CAMetalLayer uses the NVMTLDevice, clear + spinning triangle, present and wait
   every frame, then the drawable's IOSurface read from the CPU: 947 frames in 8 s (118 fps with a full wait per
   frame), every frame's background pixel equal to the clear colour, the triangle present. The plugin's existing
   "private image, copied in and out" path does the headless presentation on its own: the family-VRAM import of the
   surface is refused on this platform (NVRM SURF_VRAM -> VK_ERROR_INVALID_EXTERNAL_HANDLE, as expected without a
   scanout head), so the drawable is a VRAM image and the plugin copies it into the host IOSurface at present
   (`G13 surface-out`, ~1 ms for 512x512), which WindowServer composites on the Apple GPU. Known noise: the copy-class
   retry (`nvkmd_nvrm_ctx.c:747 VK_ERROR_UNKNOWN`, RM "bad class 0xc7b5", NVK's own fallback) and the absent
   x86-only nvdec/nvenc dylibs. Not yet measured: a full-screen 4K frame's copy-out over the TB3 link, and a
   screenshot (screencapture lacks permission from this shell; the IOSurface check is the proof).
9. **First real app, Unreal Editor 5.8 (23:09-23:35): SIGBUS in `nvk_UpdateDescriptorSets` 0.3 s after MetalRHI
   loads, four times in a row, reproducible from the shell.** UE's RHI uses our device (its "Apple M1 Pro" adapter
   line is its own IORegistry lookup; the SM6 -> SM5 fallback and the plugin trace of Slate's `fixed_vert_lph_spc`
   pass prove the draws come to us). The faulting pc is the same across runs, `nvk_UpdateDescriptorSets+0x994`
   (32-bit-truncated pc minus the dylib's base, consistent in three crash folders): `ldr x13, [x14, #0x58]`, the
   read of `nvk_buffer->addr` for a VkDescriptorBufferInfo, with x14 = 0x7b000b4000 / 0x76000483f0 / ... : the
   VkBuffer handle the plugin put in the write is garbage, not an alignment fault (the kext's user mappings of RAM are
   cacheable; NVK's CPU-mapped memory is system RAM by default, `nvrm_local_map_stays_vram` off). Every slot handle
   comes from `((NVMTLBuffer *)b)->_b.buf` with no class check at 13 encoder sites, so an object the app binds that is
   not ours (another device's, or not a resource) yields exactly this. The plugin now routes those casts through
   `nvmtl_as_buffer` / `nvmtl_as_texture` (NVMTLObjects.m), which log the foreign class and device and ignore the
   binding. Package refreshed (plugin sha 40339c7c); the next UE run under the reinstalled plugin either survives
   and names the foreign object in `/tmp/nvmtl.log`, or it still dies and the handle is a stale one of ours (then look
   at `nvmtl_keep_page_pop` and buffer retirement under UE's multi-threaded submission).
   Run with the guarded plugin injected through the test interposer (`DYLD_INSERT_LIBRARIES=libenumsim.dylib
   NVMTL_SIM_PLUGIN=<bundle>`, UE is ad-hoc signed, not hardened): no crash in 92 s, Slate drew and presented the
   1440x740 window (29 ms copy-out for the first frame), several hundred plugin log lines, **but the guard never
   fired**, so the foreign-object theory is unproven; the earlier crashes may be a race under UE's threaded
   submission. The run ended in UE's own dialog "Rendering support for Intel based Mac has been removed in this
   version of the engine": UE 5.8 refuses any GPU that is not an Apple family, which ours is not (Mac2/Common3 only).
   UE 5.8 is therefore not a target; projects built on UE <= 5.4 (which still render on Intel Macs) and other Metal
   apps are.
10. **Getting apps onto the card.** `MTLCopyAllDevices` lists the NVMTLDevice first (which is why UE took it), but
   `MTLCreateSystemDefaultDevice` and `CGDirectDisplayCopyCurrentMetalDevice` answer the M1 Pro, and that is what
   nearly every app and game asks. `tools/arm64-probes/usenv_interpose.m` -> `out/usenv/libusenv.dylib` (universal,
   arm64 + x86_64) interposes the three calls for one process via `DYLD_INSERT_LIBRARIES`: ad-hoc or unsigned apps
   only, a hardened runtime ignores it (Blender, PICO PARK 2, the Unity editor). Two lessons: the replacements must
   return +1 like the originals (`NS_RETURNS_RETAINED`; without it the Rosetta probe died in objc_autoreleasePoolPop),
   and the dylib unsets `DYLD_INSERT_LIBRARIES` in its constructor, or an arm64e helper the game spawns is killed by
   dyld for not finding an arm64e slice. Steam games run standalone with `SteamAppId`/`SteamGameId` in the environment
   and the Steam client running (`steam_appid.txt` in the executable's folder was not enough for Steamworks.NET).
11. **First game: The Past Within (Rusty Lake, Unity 2020.3, x86_64 under Rosetta, Steam 1515210), 23:55.** Unity
   logs "Using device NVIDIA GeForce RTX 3070 ... (high power, removable)" and initialises its Metal caps on it; the
   game ran its intro at 3024x1898 full screen for 75 s until killed: 628 NVK submits, 6 presented-surface log lines
   (rate-limited), copy-out ~10 ms per 3024x1898 frame after the first, no errors in the plugin log, no crash, Steam
   API loaded. The x86_64 slices of the plugin and NVK are therefore live too.
12. **The Stanley Parable: Ultra Deluxe (Crows Crows Crows, Unity 2019 HDRP-free 3D, x86_64 under Rosetta, Steam
   1703340), 23:54-23:56:** a real 3D game. "Using device NVIDIA GeForce RTX 3070", 100 s in its office menu scene
   at 3024x1898 until killed: 979 NVK submits, more than 2000 frames presented, no plugin error, no crash. The
   copy-out of a 3024x1898 frame into the host IOSurface measures 16 ms (23 MB per frame, ~1.4 GB/s through the TB3
   link): at native Retina resolution that alone caps the game near 60 fps and serialises with rendering; at
   1512x946 it is a quarter of that. The presentation path, not the GPU, is the first performance problem to solve
   (overlap the copy with the next frame's rendering; present at the window's point size, not the backing scale).
   `usenv.sh` (package root) wraps the launch: `./usenv.sh "/path/Game.app" <steam-app-id>`.
   The plugin's own frame counter (`fps:` lines, on by default) for the Stanley Parable menu scene: 23.5 fps during
   the first 4.6 s (shader compiles), then a steady 61-62 fps at 3024x1898, 2 submits per frame of 7.9 ms each,
   CPU blocked on the GPU 98% of wall: the frame is exactly 16 ms, i.e. this scene sits on the vsync / copy-out
   wall, not on the card. The Past Within logged no `fps:` line (it presents too rarely for the 2 s window).
13. **Hearts of Iron IV (Paradox, x86_64, OpenGL):** runs 90 s on the launcher, Steam API up, but the plugin sees
   only the device creation: Apple's GL-on-Metal picks the display's renderer (AGX) through CGL, not the default
   Metal device, so OpenGL games stay on the M1 Pro under this injector. Routing GL would need the CGL renderer
   registry (IOAccelerator "IOGLBundleName"), which NVAccelArm does not publish. Kernel log after the evening's use:
   2710 lines, no fault, no reset, 21 MSIs in total (NVK completes work by polling semaphores).
14. **RTX 3070 vs M1 Pro (16-core GPU), `tools/arm64-probes/gpubench.m`, same binary, best of
   three, wall clock around waitUntilCompleted:**

   | workload | M1 Pro | RTX 3070 via NVMTL | ratio |
   |---|---|---|---|
   | FMA throughput, 1 M threads x 2048 x 8 fma | 3.73 TFLOPS | 15.92 TFLOPS | 4.3x |
   | device-memory copy, 256 MB x 8 | 126 GB/s | 409 GB/s | 3.3x |
   | ALU-heavy fragment fill, 2048x2048 x 20, 64 sin/cos per pixel | 952 Mpx/s | 9528 Mpx/s | 10x |
   | flat fill, 2048x2048 x 20 (1 ms test, noisy) | 60 Gpx/s | 76 Gpx/s | 1.3x |
   | present 3024x1898, display sync off | 226 fps | 92 fps | 0.41x |

   The card delivers 78% of its 20.3 TFLOPS spec and 91% of its 448 GB/s through this stack, so NVK/NAK and the
   translator are not in the way for GPU-bound work. The present path is the eGPU's wall, as expected: each frame's
   copy-out to the host IOSurface costs ~10 ms (the plugin's `surface-out` lines) and nothing else, which caps a
   full-Retina frame at ~92 fps and, serialised with rendering, pulls real games to the 60 fps vsync. Lower
   present resolution scales it linearly (1512x946 -> ~2.5 ms).
15. **Cyberpunk 2077 (CDPR, native arm64 Metal, Steam 1091500; hardened runtime but with the allow-dyld entitlement,
   so `usenv.sh` works).** The user had benchmarked it on the M1 Pro earlier
   (`~/Library/Application Support/CD Projekt Red/Cyberpunk 2077/benchmarkResults/`: 27.2 fps average, 1800x1125
   render, medium-ish custom preset). On the card, in order:
   - First run: the engine's own watchdog killed it after ~2 min of init (`!!! EngineWatchdog timeout!`, a `brk`
     in its code, SIGTRAP) before a frame. Second run (shader caches warm) got to its intro at 93-111 fps, then
     dropped to 0.1-0.3 fps. `engine/config/platform/mac/user.ini` now carries `[Engine/Watchdog]
     WatchdogTimeoutSecondsOverride = 3600` (section name guessed from the binary's strings); the third run lasted
     5.5 min before the same watchdog, so the key may not be the right one.
   - 8 compute pipelines failed: `nvk_shader.c: shader reads set 2 binding 4, which its pipeline layout leaves
     empty`. The translator addresses the bindless heap (set 2) at bindings 0 sampled / 1 sampler / 2 storage image /
     3 uniform texel / 4 storage texel by one slot number (`reflect::BINDLESS_*_BINDING`), and the plugin's heap had
     only 0 and 1. The heap now has all five (131072 slots each, dummies everywhere, fallback 5 -> 2 -> 1 bindings),
     `nvmtl_vk_bindless_put_full` / `_rewrite_full` write a texture's storage view and a texture buffer's texel view on
     the same slot (`nvmtl_resid_for_texture`). rendersim still 14/14. After that no pipeline failed.
   - Still 0.1 fps after the intro, process at 1% CPU, GPU idle: the game waits for something. Its stdout shows
     `nvrm_xnu: IOServiceOpen(NVAccel, 0x4e560000) 0xe00002c9 - falling back to NVRM` 28 times: the accelerator's
     `newUserClient` created the bridge client in NVRM but `attach`/`start` to NVAccel failed (kIOReturnInternalError)
     and it released the object. The direct-NVRM fallback then works, but the stall may be each failed open (NVK pools
     connections per thread; cause of the attach failure not yet known, the accelerator's kprintf is not in the ring).
     The screen showed a garbage band on black at 1280x800; probably the game's loading screen drawn from a texture
     the translator or heap does not yet feed right, not the present path (copy-out measured 2 ms, correct elsewhere).
   - **Panic #6, 02:23, `NVRMUserClient::initWithTask+0x11c`, kernel data abort reading `fPid` (offset 0x1b8) of a
     freed client in the per-process count loop over `gNvClients`.** Exactly the released-without-close objects
     above: `clientClose` was the only place a slot was cleared. Fixed in `NVRMUserClient::free()` (clears its slot
     and pmap bookkeeping under `gNvClientsLock` when the client was never closed, logs it) and in
     `nvNewAccelClient`, which now takes the accelerator service as p4, attaches and starts the client itself, logs an
     attach/start failure with both services' inactive state into the ring, and closes the client before releasing
     it; NVAccelArm passes `this` and only does its own attach/start for an older NVRM. Both kexts rebuilt
     (NVRM 0.308.x, NVAccelArm 0.308.x): a reboot is needed; the user installs with the enclosure unplugged.
16. **02:35, after the reboot on 0.308.147: the ring line says it all.** `bridge client fd 1020: attach FAILED
   (accelerator inactive 0, NVRM inactive 0, client inactive 0, accel retain 1025)`, and `ioreg` showed NVAccel with
   1020 IOAccelNVRMBridge children, 876 of them Cyberpunk's. NVK's `nvRmApiMapMemory` opened a connection per
   mapping and `nvrm_xnu_close` parked it ("pending close") until the unmap, because IOKit tears a mapping down with
   its user client; a game that keeps ~900 CPU-visible allocations therefore keeps ~900 user clients, and
   `IOService::attach` past ~1020 children of one service waits 15 s and fails (xnu's kIOServiceBusyMax wait). That
   was the 0.1 fps "stall" (each open blocked 15 s), the watchdog, and the garbage loading screen (allocations
   failing). Fix, both sides: the kext's `NVRMUserClient::clientMemoryForType` now keys mappings by the virtual fd
   the userland bound before the map (IOConnectMapMemory64's type), keeps the descriptor per fd so the unmap gets the
   same object, consumes the context, and selector 7 (`sUnmapDone`) drops the entry; NVK's `nvrm_xnu_open_map`
   hands out a /dev/null fd bound on one shared connection per node type under a mutex held through
   open -> MAP_MEMORY ioctl -> map -> close, `nvrm_xnu_munmap` unmaps by that fd and tells the kext. Legacy per-fd
   connections remain for the ctl/device/event fds (a handful per process). Mesa commit + patch regenerated.
   Booted 02:48 with the enclosure plugged in from power-on, which exposed two more things:
   - **Firmware read at boot:** the kext matched the card before the Data volume was mounted, `vnode_open` of the
     GSP blobs under /Library returned ENOENT, `RmInitAdapter failed (0x61:0x56)`, no Metal device. Every earlier
     boot had the card plugged in after login. `nv_get_firmware` now waits up to 90 s for the file (go(2) is on its
     own thread). Until that build is installed, `sudo nvrmctl go 2` after login brings the adapter up.
   - **Panic #7, 02:53, `NVRM::go+0x64c`:** that very rerun. go(2) created a second IOFilterInterruptEventSource on
     the same MSI index and IOKit panicked in `addInterruptStatistics` ("would have clobbered existing
     statistics"). go(2) now keeps the interrupt source across attempts (created once, disabled on failure,
     re-enabled on the rerun). Both fixes in NVRM 0.308.17x; the multiplexed-mapping code is otherwise unverified
     on hardware (the adapter never came up on that boot).
   Open after this: verify the mapping multiplex (ioreg: IOAccelNVRMBridge count must stay small under Cyberpunk),
   the watchdog key, the benchmark itself.

## What tinygrad's TinyGPU teaches about this hardware 

The user runs tinygrad on the eGPU through tiny corp's TinyGPU (`vendor/tinygpu-src`, the x1476 fork): a PCIDriverKit
**dext**, not a kext, so it works with SIP on; the GSP is booted and driven from user space (tinygrad's own RM
subset). Our route keeps NVRM in the kernel (NVK needs the whole RM API), which needs Permissive Security, but the
dext's measurements are the ground truth for the same card on the same kind of Mac:

- **`IOPCITunnelCompatible = true`** in the personality: IOPCIFamily matches a Thunderbolt-tunnelled device only to
  drivers that declare it. Added to NVAccelArm's PCI personality and, by `build_nvrm.sh`, to NVRM's arm64e plist.
- DMA is `IODMACommand` with 40 address bits behind the device's DART; each card has its own DART, IOVAs are per
  card (matches `kexts/NVRM/nv_xnu_dma.cpp`). A device that DMAs to an IOVA the host has unmapped does not fault
  quietly: macOS 27 answers with a **kernel panic** (`[SPTM] VIOLATION_T8110_DART_INVALID_ERR_MASK`). NVRM's stop
  path must shut the GSP down before any shared page is unmapped, and every DMA mapping must outlive its use.
- **The PCIe link**: GSP-RM retrains the link itself; on Ada (AD103, Intel TB5 bridge) the first burst of host writes
  into VRAM took the link down (AER, `Link timeout`, device torn down and re-probed). Fix: two RM registry entries,
  `RMPcieLinkSpeed = 0x800002AA` (gens 2-6 disabled) and `PCIEPowerControl = 0x3` (ASPM off). Blackwell did not need
  them; Ampere (our RTX 3060, GA106) is not measured by them. NVRM accepts registry keys through the boot-arg
  `nvregdwords=RMPcieLinkSpeed=0x800002AA;PCIEPowerControl=0x3`, so the first bring-up should carry it; the pin is
  sticky until the enclosure is power-cycled.
- Cold plug trained a 5090 at Gen4 x4 through a TB5 bridge; a JHL7540 (TB3) caps PCIe at Gen3 x4 anyway.
- No interrupts are used by the dext (user-space polling); NVRM's MSI path on Apple Silicon is therefore still
  unmeasured.

## Build

    OGKM=/path/to/open-gpu-kernel-modules   # tag 615.78.08, patched by build_rm.sh on first run
    bash build/arm64/build_rm.sh            # libnvkernel.a, libnvkms.a  (ARCH=x86_64 builds the Intel variant)
    bash build/arm64/build_nvrm.sh          # out/arm64e/NVRM.kext

`build/arm64/unwrap_kernelcache.py` extracts the running kernel collection from the Preboot kernelcache (IMG4 + LZFSE,
decoded with libcompression) so `nm` can list the kernel's exported symbols without a KDK.

## 17. Hot-replugged eGPU: a stale DART mapper (NVRM 0.308.262)

After the panic-#7 reboot the enclosure was unplugged and plugged back in with the kext loaded. The new probe
reached `rm_init_adapter` and died at the first DMA mapping: `dma: setMemoryDescriptor(1 pages, 16 KB) -> 0xe00002d7`
(kIOReturnOffline), then `kmemsysInitFlushSysmemBuffer_GA100: Could not allocate sysmem flush buffer` and
`RmInitAdapter failed! (0x22:0xffff:904)`. Cause: `nv_xnu_dma.cpp` took `IOMapper::copyMapperForDevice()` once per
kext and kept it; the replugged card is a new `IOPCIDevice` behind a new DART, and the old mapper is offline. The
mapper is now taken per device (a different `IOPCIDevice` drops the previous one; live IODMACommands keep their own
reference). Until the kext is reinstalled, a replug after an unplug needs a reboot.

## 18. Cyberpunk: pipelines refused inside parallel encoders

`cp-nvmtl9.log`: the eight "incompatible render pipeline refused" lines all come from parallel render encoders
(the shadow-map passes, 16 replayed calls each, one refusal per sub-encoder), and the NVRM channel faults right after.
The pass signature is taken from the FIRST pipeline bound, so a later pipeline that declares a subset of the
attachments (Metal's "Invalid pixel format = this stage does not touch it", which Apple's driver takes without
validation) was refused and its draws dropped. `nvmtl_vk_pipeline_subset()` now accepts such a pipeline (same sample
count, same format wherever it declares one, no depth it would need that the pass lacks); it is bound, and a pipeline
with no depth attachment gets depth test and write disabled for its draws. The refusal log now prints both signatures
and the descriptor's real attachment formats (first 16), so the next run shows what actually differs.
Still open: the presented frames themselves are black with alpha set during loading; the user sees colourful garbage
top-left. `argsim` (tools/arm64-probes/argsim.m) checks argument buffers, CPU-written gpuResourceIDs, texture buffers
and storage textures through resource IDs on the card — run it first after the reinstall.

## 19. Panic #8: a No-Snoop read into a CPU-cached line (RM coherency, NVRM 0.308.3xx)

`panic-full-2026-11-04-044734`: `AMCC0 PLANE2 UNEXP_RT_HIT_DIR error ... ADDR 0x1030fe22000 CMD/SIZE 0x14(ncrdincr_ro)`
two minutes into Cyberpunk. The Apple memory fabric caught a NON-COHERENT read (PCIe No-Snoop) of a DRAM line a CPU
held, and the platform error handler panics on it. The RM issues No-Snoop traffic for any sysmem whose memdesc CPU
cache attribute is not NV_MEMORY_CACHED: `kgmmuGetMemAperture` picks GMMU_APERTURE_SYS_NONCOH, the CE paths pick
`_NONCOHERENT_SYSMEM`, and `dmaAllocMapping` follows the memdesc snoop setting. The OS layer, however, allocates and
maps every RAM page cacheable on arm64 (item 2: nv_alloc_pages ignores the cache type, os_map_kernel_space maps RAM
default-cached), so a buffer the RM believes uncached/write-combined is cached on the CPU and read No-Snoop by the
GPU. Fix (Darwin patch, `g_mem_desc_nvoc.h`): on NV_DARWIN + __aarch64__ `memdescGetCpuCacheAttrib()` returns
NV_MEMORY_CACHED for every ADDR_SYSMEM memdesc, so all three consumers choose the coherent path. NVK already asks for
CACHED sysmem and CACHE_SNOOP_ENABLE on its mappings; the RM's own internal buffers were the exposure.
Also from this round: texture buffers (`newTextureWithDescriptor:offset:bytesPerRow:`) had no image view, so
`nvmtl_resid_for_texture` never gave them a heap slot and a shader reading `texture_buffer<>` through a gpuResourceID
read the dummy (argsim C read 0). `nvmtl_vk_bindless_put_full` now takes a slot with the dummy image on binding 0 and
the buffer view on binding 3. argsim passes A/B/C. Game logs now go to ~/Library/Logs/nvmtl (tools/arm64-probes/cp-run.sh);
/tmp is wiped by the reboot a panic forces, which lost run 10's log.

## 20. Panic #9: same AMCC No-Snoop error with the memdesc patch in (NVRM 0.308.309)

`panic-full-2026-11-04-050253`: `AMCC2 PLANE0 UNEXP_RT_HIT_DIR ... ADDR 0x1078b2a5d80 CMD 0x14(ncrdincr_ro) AID 0x1207`,
100 s into Cyberpunk and this time still during pipeline creation (no draw yet; log in ~/Library/Logs/nvmtl/cp-nvmtl11.log).
So the item-19 patch (every kernel-side memdesc reports CACHED) did not cover the reader. The remaining No-Snoop
sources are on the card side (GSP-RM's physical RM decides apertures for what it owns) or in paths that hard-code
NONCOH. Rather than chase them one by one: `kernel_bif.c` (kernel RM) calls `kbifEnableNoSnoop_HAL(NV_TRUE)` at init
unless the chipset table says NOSNOOP_NOT_CAPABLE, and on an unknown (Apple) chipset it enables it. The Darwin patch now
never enables it on arm64, and NVRM.cpp `nvSetNoSnoop(false)` clears PCIe DevCtl bit 11 (Enable No Snoop) from config
space before and after `rm_init_adapter`, logging the old and new value ("no-snoop: DevCtl ..."). With the bit clear the
function may not set NS on any TLP, so every GPU read is snooped whatever aperture the PTE/instance block carries.
Watch the ring after boot: if the "after" line shows the bit ON again, GSP-RM set it back and it needs a periodic
re-clear (or the XVE register behind BAR0, NV_XVE_DEVICE_CONTROL_STATUS, written directly).

## 21. Panic #10 with No-Snoop off: Relaxed Ordering is the other TLP attribute (NVRM 0.308.7xx)

`panic-full-2026-11-04-121428`: `AMCC0 PLANE1 UNEXP_RT_HIT_DIR ... ADDR 0x1052168dc00 CMD/SIZE 0x14(ncrdincr_ro)/0x7f AID 0x1207`,
again ~90 s into Cyberpunk's pipeline-creation phase, with NVRM 0.308.309: the ring showed `devctl ... No Snoop off` before
and after `rm_init_adapter`, so the No-Snoop bit (item 20) was not the (only) source of the non-coherent read. Checked
and ruled out this round: the memdesc patch is compiled in (`kgmmuGetMemAperture_IMPL` in `kern_gmmu.o` returns SYS_COH
for every ADDR_SYSMEM memdesc), NVK's `nvkmd_nvrm_va_bind_mem` asks `CACHE_SNOOP_ENABLE` for sysmem so
`dmaAllocMapping_GM107` picks SYS_COH, NVK allocates sysmem `COHERENCY_CACHED`. What was still on: DevCtl bit 4,
Enable Relaxed Ordering (0x211f), which `kbifInitPcieDeviceControlStatus` forces on for every chipset not flagged
RELAXED_ORDERING_NOT_CAPABLE, and which the graphics engines (not the GSP falcon, whose traffic never panicked) put on
their sysmem reads. The "_ro" in the AMCC command name points the same way. Changes:
- `kernel_bif.c` (Darwin patch): the RO branch is `if (NV_FALSE)` on NV_DARWIN + __aarch64__, like the No-Snoop one.
- `NVRM.cpp`: `nvSetNoSnoop` became `nvDevCtlTrim(when)`: clears bits 11 and 4 before and after `rm_init_adapter`;
  `devCtlWatch` thread (started at PASS 2) re-reads DevCtl every 5 s, publishes it as `debug.nvrm_devctl`, re-clears
  the bits if anything set them back (count in `debug.nvrm_devctl_fixes`, one ring line per fix).
- `os-xnu2.cpp`: `debug.nvrm_allocs` (root) lists every live RM sysmem allocation (pid, size, cache type) with its
  physical page runs coalesced, so the next AMCC ADDR can be attributed after the reboot.
- `nvrmctl allocs | devctl`; `tools/arm64-probes/cp-watch.sh N` (run as root, `sudo -E`) snapshots ring, allocs and
  devctl into ~/Library/Logs/nvmtl every 2 s while the game runs.
- `os-xnu2.cpp` `nv_get_firmware`: the boot wait for the firmware files is 300 s (was 90): a panic reboot mounted the
  Data volume at settle + 110 s and `RmFetchGspRmImages` failed with "No firmware image found"; `sudo nvrmctl go 2`
  brought the adapter up without another reboot.
If RO off is not it either, the attribution from `allocs-N.txt` decides between an RM-internal buffer (owner pid 0) and
a client buffer, and the remaining candidates are GSP-RM's physical-side apertures (RAMFC/USERD/instance block, set from
the cacheAttrib the kernel passes over RPC) and the XVE itself ignoring DevCtl.

## 22. Metal Shader Converter fragment shaders lost every texture sample (translator)

Cyberpunk's G-buffer albedo and UI came out black while depth and normals were right: every texture the game sampled
read as zero. `tools/arm64-probes/texsim.m` (30 texture paths, all pass) did not reproduce it; the game's shaders
did, once their AIR (`~/Library/Caches/nvmtl/aircache/*.ll`) was fed through `tools/arm64-probes/xlate.c`
(`xlate <dylib> <in.ll> <stage> <out.spv>`): the native emitter failed on the MSC argument-buffer pointer chains with
"sampler operand is not a sampler" / "sampler operand is a pointer" / "runtime sampler specialization cannot recover
an exact state after pointer selection", fell back to raw construction, and the raw-constructed module had **zero**
image ops where the AIR had N `@air.sample_*` calls, so the shader "succeeded" with its samples dropped.
Fix (`translator/translator/src/lib.rs`): `air_texture_call_count()` / `module_image_op_count()` compare the AIR
texture calls with the image ops in the produced module; the raw-first branch returns the raw module only when
`raw_ops >= air_ops` or the primary emitter failed, otherwise logs and falls through; and
`argument_buffer_sampler_retry_handles(err)` sends those three sampler errors to the `with_argument_buffer_samplers`
retry (ARGBUF_SAMPLERS; `NVMTL_ARGBUF_SAMPLERS=1` forces it) instead of raw construction, in both
`translate_native_no_retry_constructed_with_options` and `translate_sanitized_with_meta_prevalidated_carrier`.
The spvcache tag moved to `sha256-de5c9f74…` (1457 entries warm; the first run after a tag change trips the game's
EngineWatchdog while it retranslates, just launch again). Result: the G-buffer scene pass (#067 in the pass dump)
renders Night City. Details, the per-pass render-target dump (`nvmtlPassDump`, `passdump2png.py`), the trace
PEEK/SCAN/OBJ/TEXDUMP probes and the buffer registry are in `docs/ARM64-PORT-PROGRESS.md` §5–§7.
Still open: the main menu shows a static garbled image (two half-height tiles, false colours) in the final BGRA8 pass
while the key art / video planes it samples are intact in VRAM (`obj37/*.png`); texsim 30a shows
`get_width/get_height/get_array_size` returning 0 when a texture is only queried, not sampled.

## 23. Panic #11 with NS and RO off: the RM's "uncached" system memory must not be CPU-cacheable (NVRM 0.308.1035)

`panic-full-2026-11-04-153943`: `AMCC2 PLANE0 UNEXP_RT_HIT_DIR ... ADDR 0x1054f8c4680 CMD/SIZE 0x14(ncrdincr_ro)/0x7f
AID 0x1207`, at 15:37:50 with NVRM 0.308.751, Cyberpunk sitting at its main menu, `devctl 0x210f` (No Snoop off,
Relaxed Ordering off, 0 re-clears) five seconds earlier. So neither DevCtl bit is the source, and the kernel-side
apertures (items 19–21) are all coherent. The ADDR is in none of the 1708 live RM allocations of `allocs-13.txt`
(841 MB, every one `cache 0`), so it is not NVK or RM sysmem the kext handed out through `nv_alloc_pages`.
Ruled out this round, by experiment rather than reading: `tools/arm64-probes/surfstress.m` (`out/rendersim/surfstress
<in|out|nocopy|shared> [s]`, same injection as cp-run.sh) drives the copy engine over the app's own pinned pages with
the CPU dirtying the lines right before each copy — IOSurface surface-in 4417×, surface-out 9025×, `newBufferWith
BytesNoCopy` 4512×, shared-buffer control 3398× — no panic. Pinned host pages (`os_lock_user_pages`, OS descriptors)
are read and written coherently, like everything else that goes through a PTE.
What is left is memory the GSP or an engine reaches **without** a kernel-side aperture decision, and NVIDIA's RM
tells us which that is: every buffer it creates `NV_MEMORY_UNCACHED` / `_WRITECOMBINED` is one it expects
non-coherent traffic on (on x86 UC means no CPU cache line can exist). On a dGPU with GSP those are the sysmembar
flush page (`kern_mem_sys_ga100.c`: "the sysmembar flush does a zero byte read of sysmem ... an actual read may be
issued"), the GSP notify-op page and RM-state-monitor page (`kernel_gsp.c`), the libos init arguments, the video
trace ring (`kernel_video_engine.c`), FBSR. Item 2 made every RAM page cacheable on arm64 because of an alignment
abort that was in fact BAR2 (settled later in the same item: the RM is built `-mstrict-align` since 0.307.1329), and
item 19's accessor patch then hid the RM's intent from the OS layer too (`osAllocPages` reads
`memdescGetCpuCacheAttrib`, and under `NVCPU_AARCH64` forces CACHED for an IO-coherent chipset anyway), so the
kext never saw anything but `cache 0`. A line of such a buffer gets into a CPU cache by the kext's own zeroing, by
the RM polling it, or by a speculative/prefetched fetch through any cacheable alias (the kernel physical map
included), and the next non-coherent access from the card panics: that is why the panics are hours apart and land
in random processes. Changes:
- `os.c` (Darwin patch, `osAllocPages`): on NV_DARWIN + __aarch64__ the OS layer gets the memdesc's raw
  `_cpuCacheAttrib`, so the kext learns what the RM asked for while the RM itself keeps choosing coherent apertures
  (item 19 stays).
- `os-xnu2.cpp` `nv_alloc_pages`: arm64 now honours the type like x86 — UNCACHED → `kIOMapInhibitCache`
  (Device-nGnRnE), WRITECOMBINED → `kIOMapWriteCombineCache` (Device-GRE on T6000: XNU's `CACHE_ATTRINDX_RT` is
  WRITECOMB only on SoCs with `HAS_UCNORMAL_MEM`). IOKit applies the attribute to the physical-aperture alias as
  well, so no CPU cache can hold those lines. `debug.nvrm_allocs` now shows `cache 1` / `cache 2` for them.
- `os-xnu.cpp` `os_map_kernel_space`: RAM keeps the requested mode (RM-owned pages resolve to the allocation's own
  mapping through `nv_pm_alias`, which already carries it).
- Boot-arg `nvrmkeepcached=1` restores the all-cacheable behaviour for comparison.
- Alignment: `unaligned_scan.py` on 0.308.1035 lists 60 sites in 18 functions (30 in `kgspConstructEngine_IMPL`,
  which fills `GSP_ARGUMENTS_CACHED`, a CACHED buffer); the uncached buffers the CPU writes hold NvU32 fields
  (`NotifyOpSharedSurface`) or naturally aligned 8-byte ones (`LibosMemoryRegionInitArgument`). If an
  `Unaligned kernel data abort` shows up at boot, `panicsym.py` names the function and that access gets the
  `-mstrict-align` treatment of item 2; `nvrmkeepcached=1` is the fallback meanwhile.

## 24. Device-mapped RM memory panics the pmap within minutes: item 23 is opt-in (NVRM 0.308.1087)

With 0.308.1035 (item 23, UNCACHED → `kIOMapInhibitCache`, WRITECOMBINED → `kIOMapWriteCombineCache`, 15 such
allocations at boot: the sysmembar flush page, GSP pages, video trace ring) the machine panicked twice:
`panic-full-2026-11-04-175807`: `pmap_recycle_page: page 0x10744a1c000 is referenced @pmap_data.c:2287`, 1048 s
after boot, Cyberpunk idle at its stalled menu for six minutes; `panic-full-2026-11-04-180312`: the same text for page
0x10113a2c000, 566 s after boot, **nothing using the card at all**. Both in a kernel_task thread (13 kernel frames
from a thread start, no kext frame: a VM/pmap daemon), so a page the VM is recycling still carries a mapping or an
access flag — consistent with a page whose cache attribute was changed with `pmap_set_cache_attributes` and that is
later handed back (the kext's QUARANTINE/WATCHPAGE machinery was armed and silent). The release T6000 kernel has no
symbols and the macOS 27 xnu source is not published, so the exact check is unknown. Until it is, 0.308.1087 maps the
RM's uncached/write-combined system memory cacheable again (item 2 behaviour, item 23 exposure) and the Device
mapping is opt-in: boot-arg `nvrmdevmem=1` (the ring logs which mode is in force). Keep: the os.c Darwin patch
(`osAllocPages` passes the raw cache type, so `nvrmctl allocs` shows `cache 1/2` for the RM's intent) and the item-23
analysis. Next experiment for the Device path: allocate+free a Device-attribute IOBufferMemoryDescriptor at boot
and see whether the idle panic follows without the RM; try `kIOMapWriteCombineCache` for both types; try keeping
those allocations alive for the lifetime of the kext (no free → nothing to recycle).
Also this round: Cyberpunk's main menu is not garbled but **stalled** — the game presents one frame (the "two tiles"
image is the content of a 1280x800 RGBA8 UI texture) and then every thread sits in a condvar/usleep with no thread
inside Metal or the plugin, 0-2 % CPU, forever; `NVMTL_SKIP_EMPTY=0` makes no difference. The plugin now has a
file-triggered dump of the pending command buffers and the event each is blocked on (`touch /tmp/nvmtl-pending-request`,
`pending-dump` lines in the log); the run that was to use it (41) ended in the first pmap panic before the dump ran.
- (18:25) Back on the cacheable default (0.308.1087) the AMCC panic returned after 5 minutes, at Cyberpunk's menu
  (`panic-full-2026-11-04-182215`, ADDR 0x107ca41ce80): three menu runs plus idle time on 0.308.1035 never hit it, so
  the Device mapping does close item 23 and only the pmap side effect is left. The ring also shows the RM allocates
  its 15 uncached buffers once at init and none afterwards (0 after PASS 2 with the game running), so the pmap panic
  is not about freeing them. 0.308.11xx makes the mode a boot-arg: `nvrmdevmem=1` Inhibit/WriteCombine (as 1035),
  `=2` WriteCombine (Device-GRE) for both, `=3` Inhibit (nGnRnE) for both; the ring logs the mode and every such
  allocation (`devmem alloc #n`). Next: run `=2`; if it panics the same way, the attribute change itself is what the
  pmap daemon rejects and the CPU side has to stay cacheable with some other defence.

## 25. Mode 2 (Device-GRE) still hit the AMCC error; attribution without root (NVRM 0.308.11xx)

`panic-full-2026-11-04-185437`: `AMCC2 PLANE2 UNEXP_RT_HIT_DIR ... ADDR 0x103b01c2c80 CMD 0x14(ncrdincr_ro)` 1246 s after a
boot with `nvrmdevmem=2` (every RM uncached/write-combined buffer `kIOMapWriteCombineCache`), Cyberpunk at its menu. So
either Device-GRE on T6000 DRAM is not enough, or the line the card read non-coherently is not one of the 15 RM
buffers at all (mode 1's clean 30 minutes may have been luck: AMCC intervals ran from 5 min to 3 h). None of the
AMCC addresses so far was attributed because the allocation snapshot needed a root shell. Changes:
- `debug.nvrm_allocs` no longer needs root; it starts with `# devmem mode M, N device-mapped allocation(s)` and lists
  the live user-page pins (`pin P pages: 0x...+0x...`) after the RM allocations.
- `tools/arm64-probes/cp-watch.sh N` therefore runs unprivileged; keep it running next to every game run.
Also this round (plugin): at the menu "stall" the plugin has **0 pending command buffers** (`pending-dump`), the game's
window is on another Space (`is_off_space`) and the process sits at 0-2 % CPU: that is the game pausing itself while
unfocused/occluded, not a driver hang. The static "two tiles" frame is the real rendering bug of the menu.
Translator: `body_uses_texture_intrinsic` (meta/embedded.rs) now counts the query intrinsics (get_width/height/
depth/array_size/num_mip_levels/num_samples, is_null_texture, calculate_lod, texture atomics), so a shader that only
queries a texture still surfaces its embedded textures: texsim 30a/30b pass (get_width on a resource-ID texture read 0
before). lib.rs: a primary that kept fewer image ops than the AIR has texture calls now tries the raw construction and
takes it when it keeps more (texsim 23b still fails: both keep 0 - the device-struct → constant-table-pointer chain
is not typed by either path yet).

## 26. Unattended runs (tools/arm64-probes/unattended/)

The bottleneck became "every kext change = the user types a password, reboots, and restarts the game after a
panic", and six AMCC panics went unattributed because nobody was snapshotting the allocation table. Layer 1:
- `nvdev.sudoers` (copied into the Desktop package): password-less sudo for exactly `install.sh` (and
  `--payload *`), `nvram`, `shutdown -r now` and `nvrmctl` of the Desktop package. install.sh is editable by the
  user's own tools, so this is root for them - accepted for a development machine.
- `autorun.sh` + LaunchAgent `com.nullmoth.nvdev.autorun` (RunAtLoad, in ~/Library/LaunchAgents): at every login it
  installs the Desktop package and reboots when `~/Library/Logs/nvmtl/autorun.install` exists, otherwise waits
  for PASS 2 (one `nvrmctl go 2` if init failed), starts Steam, and launches the game up to RUNS times through
  cp-run.sh with cp-watch.sh snapshotting ring/allocs/devctl every 2 s. `autorun.off` is the kill switch;
  `autorun.conf` sets RUNS/STEAM/GAME_MAX/EXTRA. `nvdev.sh install|reboot|mark-install|bootargs K=V|off|on|status`.
- With auto-login enabled (FileVault is off on this Mac) a panic reboot lands back in the loop by itself, so
  samples accumulate overnight; `cp-watch.sh` falls back to `sudo -n` for the allocs snapshot on a kext older
  than 0.308.1139.

## 27. Layer 3: a session that continues the work after each reboot (tools/arm64-probes/unattended/autodev.sh)

`com.nullmoth.nvdev.autodev` (LaunchAgent, RunAtLoad) runs `autodev.sh` at login: after autorun.sh reports the
adapter it runs one non-interactive `claude -p` session (40 min, `--allowedTools Bash,Read,Edit,Write,Glob,Grep`,
`--max-turns 80`, cwd = the repo, `--add-dir` for ~/Library/Logs/nvmtl and the panic reports) whose task is
`autodev-brief.md`: attribute the last panic's ADDR against the allocs-N.txt snapshots of the previous boot, write the
conclusion into ~/Library/Logs/nvmtl/autodev-journal.md and append it to these notes, then arm the next experiment
through nvdev.sh only (boot-args `nvrmdevmem=N`, autorun.conf, or installing the Desktop package that is already on
disk), one reboot at most. The brief forbids source edits, builds, and touching launchd/sudoers. Rails outside the
model: `autodev.off` / `autorun.off`, a 40-minute timeout, and a breaker (4 panic reports within 3 hours after
`autodev.armed`) that sets autorun.off. The first dry run tripped the breaker on the day's attended panics, hence the
armed marker. A real session is started only by the user bootstrapping the agent.
- (autodev) 18:54 那次 AMCC（ADDR 0x103b01c2c80，mode 2）**仍无法归因**：那次 boot 没有留下 allocs 快照。原因是 ~/Desktop/nvidia-macos-driver-arm64 被 iCloud 逐出（install.sh/nvrmctl 等都是 `dataless`，读取返回 EDEADLK），在 0.308.1106 上 cp-watch.sh 的 `sudo -n nvrmctl allocs` 回退执行不了，所以 allocs-*.tmp 是空的；mark-install 也会失败。已执行 `nvdev.sh off`，没有重启。先让包重新下载到本地（或移出 iCloud 目录）并安装 0.308.1139，再继续跑 mode 2。
- (19:45) The first unattended session (autodev, 2 min) found why no snapshot ever had an allocs table: the Desktop
  package sits in the iCloud-synced Desktop and its files are evicted (`compressed,dataless`); root cannot fault
  them in (`Resource deadlock avoided`), so `sudo -n nvrmctl` and `install.sh` were unreadable. The package now lives
  in `~/nvdev/pkg` (outside iCloud) and `~/Desktop/nvidia-macos-driver-arm64` is a symlink to it, so the sudoers
  paths stay valid (verified: `sudo -n .../nvrmctl devctl` and `install.sh` run). The session correctly refused to
  reboot and switched the loop off instead of burning a panic without attribution.
- (autodev) 用软链接修的那次 mark-install 失败了：install.sh 的 `HERE` 是逻辑 pwd（软链接路径），
  `cp -cR "$HERE" "$STAGE/pkgroot"` 把软链接本身复制了过去，第 284 行的检查报 “link that leaves the package: …/pkgroot”。
  所以 Desktop 包必须是真实目录，或者 install.sh 改用 `pwd -P`。另外在 0.308.1106 上，cp-watch.sh 的 sudo 回退
  以 `sudo -n true` 为门槛，而 nvdev sudoers 不放行它，所以 allocs 快照还是会空。仍是 1106 + mode 2，没有新 panic；
  已执行 `nvdev.sh off`，没有重启。
- (autodev) 没有新 panic（最新的仍是 18:54）。1139 的 install.sh 已经跑完，但 NVRM 还在等系统设置里的人工批准，所以加载的仍是 1106。不过 `sudo -n nvrmctl allocs` 在 1106 上已经能用，run 49 的 allocs-49.txt 有 251 行，这是第一次拿到分配表快照。保持 mode 2，没有重启，等下一次 AMCC 再归因（1106 上没有 pin 行）。

## 28. Kext approval without a human: a stable team identifier (unattended/setup-signing.sh)

`spctl kext-consent disable` does not stick on this Mac (run from Recovery, still ENABLED afterwards; a reinstall
of 0.308.1139 still waited for approval). kernelmanagerd records an approval per (team id, bundle id); the kexts
were ad-hoc signed (`TeamIdentifier=not set`), so every build was a new extension. `setup-signing.sh` (run once by
the user: openssl self-signed cert with OU NULLMOTH1 and the codeSigning EKU, imported into ~/nvdev/sign/
nvdev.keychain-db with codesign allowed, user-domain trust) gives the kexts a team identifier; `package.sh` signs
with it when the identity is visible. Expected: one approval of the signed build, then later builds load
unattended. Permissive Security already accepts any signature. To be verified with the next version bump.
- (autodev) 没有新 panic（最新仍是 18:54）；19:54–20:09 的 boot 是正常关机（run 49 跑了 779 s 没出事）。20:05 人工装的签名包已加载：NVRM 0.308.1205、NVAccelArm 0.308.147，mode 2。在 1205 上非 root 的 `nvrmctl allocs` 已可用（15 个 device-mapped 分配），所以从本 boot 起的快照不再依赖 sudo。签名后是否免批准还要等下一次版本号变化才能确认。保持 mode 2，没有重启，等下一次 AMCC 再拿 ADDR 对照 allocs（含 pin 行）。
- (20:20) Result: no. 0.308.1205 signed with "NullMoth Dev Signing" was approved and loads; 0.308.1219 signed with the
  same identity (and the unchanged NVAccelArm, merely re-signed) asked for approval again: for a signature without an
  Apple team identifier kernelmanagerd approves each binary (cdhash), not the signer. package.sh keeps the identity only
  when its keychain opens silently, else ad-hoc. What is left for truly unattended kext installs: pre-recording the
  approval in /var/db/SystemPolicyConfiguration/KextPolicy (SIP is off; needs its schema and a root sqlite3 command
  in the sudoers), or an MDM kernel-extension policy. Everything else (boot-args, configs, reboots, game runs,
  snapshots, the autodev session) is already unattended.
- (autodev) 没有新 panic（最新仍是 18:54）。20:10–20:33 的 boot 是计划内重启（shutdown_stall），run 51 在 mode 2 + 1205 下跑了约 21 min 没出事；allocs-51.txt 里有 4 条 pin 行。改完 KextPolicy 后装 1219，install 日志仍然写“等待批准”，重启后加载的还是 0.308.1205，所以这一次改 KextPolicy 没有让 1219 免批准加载。保持 mode 2，没有重启。
- (autodev) 没有新 panic（最新仍是 18:54）；20:34–20:42 的 boot 是计划内重启（shutdown_stall），run 52 在 mode 2 下跑了约 7 min 没出事。UI 批准后重启，本 boot 加载的是 NVRM 0.308.1219 + NVAccelArm 0.308.147，即 1219 经人工批准一次后已加载。mode 2 下自 18:54 起累计约 41 min 游戏无 AMCC。保持 mode 2，没有重启，等下一次 AMCC 再拿 ADDR 对照 allocs-53 起的快照（含 pin 行）。
- (autodev) 没有新 panic（最新仍是 18:54）；20:43–20:49 的 boot 是计划内重启，run 53 在 mode 2 + 1219 下约 4 min 无事。免批准测试结果为否：在 NULLMOTH1 行 allowed=1 的情况下，没有 UI 批准就装 0.308.1248，重启后 NVRM 完全没有加载（只有 NVAccelArm 0.308.147），也没有退回 1219。这说明 kext_policy 的 team_id 行并不能让新的 cdhash 免批准。另外数据卷只剩约 1.9 GB。已执行 `nvdev.sh off`，没有重启。
- (20:55) The KextPolicy database route is closed too. syspolicyd does record the self-signed OU as the team id
  (`kext_policy` row NULLMOTH1/com.nullmoth.NVRM), and the UI approval sets bit 4 of `flags` on the matching row,
  but rows with allowed=1 (flags 1 or 5) plus a `kext_load_history_v3` row with the new cdhash and flags=16 did not
  make kernelmanagerd accept a build it had not seen approved: 0.308.1248 (same identity, no UI approval) stayed
  unloaded after a reboot while 0.308.1219 (approved once) loaded. So: every new kext binary needs one click in
  System Settings; boot-arg modes, configs, reboots, runs, snapshots and the autodev session are unattended.
  Also: the data volume was down to 1.5 GB free (user data, 861 GB used); my throwaway build trees are gone,
  3.4 GB free now - the loop needs room for snapshots and panic reports.

## 29. Unattended setup rolled back (user decision, 21:05)

Both LaunchAgents booted out and their plists removed, the loop processes stopped, `autorun.off`/`autodev.off`
left in place, the signing keychain (~/nvdev/sign) deleted (package.sh is back to ad-hoc signatures), the Desktop
symlink removed. The package now lives at ~/nvdev/pkg (outside iCloud, so root can read it): install with
`sudo bash ~/nvdev/pkg/install.sh`; rebuild_all.sh syncs there. Left for the user: `sudo rm /etc/sudoers.d/nvdev`
and switching automatic login off. The four `kext_policy` rows (allowed=1) are harmless. The scripts stay in
tools/arm64-probes/unattended/ as a record; nothing starts them. What the day established for later: panics need a
`cp-watch.sh N` running next to the game (root no longer required for allocs on 0.308.1139+), and a new kext binary
always needs one approval click.
- (autodev) 20:54 恢复循环后，mode 2 + NVRM 1219 下连着两次 AMCC。第一次是 205801，ADDR 0x1055204e880，开机后 485 s。它**落在一个 user-page pin 里**：allocs-54.txt 第 1634 行，250 pages，页 0x1055204c000，快照在 panic 前 2 s；不在任何 RM / devmem 分配里。250 × 16 KB 正好是一个 1280x800 RGBA8 的 IOSurface，也就是 `nvmtl_host_pages` 保留的 surface 导入；CMD 是读，所以指向 surface-in。第二次是 210049，ADDR 0x1066fcd3980，开机后 149 s，**无法归因**：allocs-55 的 561 个分配都不含它，当时 live pin 为 0，可能是两次快照之间建了又释放的临时导入。所以第 23 条“pin 的主机页是一致的”至少对 surface-in 不成立。下一个实验：autorun.conf 设 `EXTRA="NVMTL_SURFIN_UPLOAD=cpu"`，mode 2 不变，重启。

## 30. Panic #13 attributed: the AMCC address is inside a pinned drawable plane

`panic-full-2026-11-04-211114`: `AMCC0 PLANE2 UNEXP_RT_HIT_DIR ... ADDR 0x1068b0f9a80 CMD 0x14(ncrdincr_ro)`, 380 s after
boot, Cyberpunk at its menu, `nvrmdevmem=2`, with `cp-watch.sh 54` running: allocs-54.txt (24 s before the panic)
puts the address in `pin 250 pages` at page 0x1068b0f8000 + 0x1a80 - one of four live pins of 250 pages = 4,096,000 B
= a 1280x800 BGRA plane: the CAMetalLayer drawables the plugin pins for surface-in/out (`nvmtl_host_pages` keeps
their host-pointer imports). None of the 15 Device-mapped RM buffers, none of NVK's 1613 allocations. So the seven
AMCC panics were never about the RM's uncached memory; the mapping mode (items 23-25) is beside the point.
What differs from surfstress (which pinned its own IOSurfaces, default or `IOSurfaceCacheMode=4` write-combined,
13707 GPU writes + 6654 reads with the CPU touching the lines, no panic): the game's planes are CoreAnimation's
drawables, mapped and read by WindowServer as well. Whatever makes the card's access to those pages non-coherent,
the fix is the same: never let the copy engine touch a drawable's own pages. Run 55 is the test: the game with
`NVMTL_SURFOUT_READBACK=cpu NVMTL_SURFIN_UPLOAD=cpu` (staging copy through NVK memory, no pins) and cp-watch next
to it. If the AMCC panics stop, the plugin makes the CPU path the default for IOSurface-backed textures on arm64.

## 31. The garbled screen: the final blit samples a heap-placed texture that is not the UI target (in progress, 22:10)

Runs 55-57 (CPU surface copies, no pins; trace with object/image/heap pointers, descriptor-table peek): the UI pass
renders the correct frame (pass dump #024 = the NCPD "press to continue" screen) into texture A (e.g. 0x79c1764e00,
RGBA8_sRGB 1280x800 with mips), and the final drawable draw (vs 12cbf421 / fs 266a11b2) samples texture B
(0x79bdc0c700, RGBA8_sRGB 1280x800, mips 1, heap-placed) - the same object the game passes to useResource and the
one the descriptor table resolves to (id 0x...7b1). A and B are different VkImages; the game expects B to alias A's
memory through the placement heap (`newTextureWithDescriptor:offset:` binds each placed image to the heap memory at
its offset). The screen shows what B's VkImage reads from that memory: the "two half-height tiles" is what a
block-linear image looks like through a different tiling, so the next check is whether A and B share heap+offset
(cap58 trace: `heap %p+%lu` on PASS/USERES/OBJ/BLIT lines) and, if so, whether NIL picked different tilings
(mips 5 vs 1; nil/image.rs tiling choice) - in which case placed textures at one offset must share one VkImage
(views for format/mip variants) instead of being created separately. Run 58's capture is in
~/Library/Logs/nvmtl/cap58 (and the background task output) if this session was cut before reading it.

## 32. The garbled screen, solved: an sRGB texture written through its UNORM view had no STORAGE usage (22:20)

Item 31's aliasing theory was wrong: run 60's trace (`OBJ ... usage 0x7 stex 0 vkusage 0x17 vkflags 0x8`) showed B
as a plain, un-aliased image with Metal usage ShaderRead|ShaderWrite|RenderTarget whose VkImage has
TRANSFER|SAMPLED|COLOR_ATTACHMENT but no STORAGE: `nvmtl_vk_image_create_*` drops storage when
`vkGetPhysicalDeviceFormatProperties` has no STORAGE_IMAGE feature for the format, and Vulkan never has it for sRGB.
The game composes its final frame in a compute kernel that writes B through a RGBA8Unorm *view* (id 0x...789, fmt 70)
bound in a descriptor table; the view's storage slot was NULL (`nvmtl_resid_for_texture`: `im->storage` 0), so every
write vanished and B kept the last image blitted into it (the CDPR logo / the intro frame) - which is also why the
first second looked right. The storage-twin fallback only covers slot bindings of the base texture, not a view in a
table. Fix (nvmtl_vk.c `nvmtl_vk_storage_via_pair`, `nvmtl_vk_base_view_usage`, `nvmtl_vk_image_self_storage`):
an image whose format cannot be storage but whose UNORM/sRGB pair can is created with
VK_IMAGE_CREATE_EXTENDED_USAGE_BIT (+ MUTABLE_FORMAT, which every colour image already had) and STORAGE usage; its
own-format base view, and every other sRGB-format view (`nvmtl_vk_view_guard`), carries VkImageViewUsageCreateInfo
without STORAGE, the UNORM views keep it. `_stex` of the base texture and the bindless storage slot
(NVMTLEmbedded.m) now ask whether the *view's own format* is storage-capable, so the sRGB base view is never bound
as a storage image. Same treatment in `nvmtl_vk_image_size_align` (heap sizing) and the reback/migrate re-creations.
Result (run 61): the main menu renders correctly on screen - confirmed by the user.

## 33. Benchmark button aborts: nil MTLFunction for the DXR-shim ray-tracing kernels (22:25, in progress)

Pressing "run benchmark" ended run 61 with `MTLComputePipelineDescriptorInternal setComputeFunction:` "computeFunction
must not be nil": the game builds every pipeline up front, and `rgs_reference_main` (6 variants),
`rgs_restirgi_spatial`, `rgs_restirgi_spatiotemporal` had failed at library time with "native emitter: pointer
nullness is not tracked for %N" - %N is `@air.get_function_pointer_visible_function_table(%VFT, handle)` followed by
`icmp eq ptr %N, null`. These are Metal Shader Converter DXR kernels (IRDispatchRaysArgument): the visible and
intersection function tables are loaded out of an argument buffer, so the AIR has no `!"air.visible_function_table"`
argument metadata and the plugin's deferral (`nvmtl_needs_visible_link`, the DEFERRED-to-pipeline path that links
the table candidates from MTLLinkedFunctions) did not trigger. `nvmtl_air_uses_function_tables` now also looks for
the function-pointer call and for an intersection-table pointer in the body; run 62 shows all 8 DEFERRED. Whether the
pipeline-time link (`xlate_link_rt` with the game's linked functions, then `air.intersect` through ift_runtime.rs)
succeeds is the next thing to read in cp-nvmtl62.log; if it does not, a no-op stub kernel for a refused
table-reading function keeps the game alive for the benchmark (RT features off).

## 34. Benchmark: the game survives the refused RT pipelines but the GPU channel faults (runs 62-64, 22:30-23:10)

With the rgs_* kernels deferred (item 33) the benchmark no longer aborts on a nil function: the pipeline link runs
(`link: "rgs_reference_main" reads a visible function table - 24 table candidate(s)`), fails in translation, the game
takes the nil pipeline and goes on - then `nvrm: channel FAULTED ... MMU fault FAULT_PDE compute shader` a few seconds
after the benchmark scene loaded (run 62 VA 0x6209c9000, run 63 VA 0x565e8f000; FAULT_PDE = no page directory at
all, a wild 64-bit pointer read by a compute kernel). Every kernel of the game is named cs_main_, so the plugin now
keeps the last 192 dispatches and commits (`nvmtl_lastk_put`, NVMTLObjects.m) with an fnv-1a hash of each pipeline's
SPIR-V and writes them with the AIR of the distinct kernels to ~/Library/Logs/nvmtl/lastk-<pid>.txt / -<hash>.ll
when the device is lost (nvlog throttles repeated lines, so the first attempt printed 8 of 96). Open question: does the
fault come from a kernel that consumes what the refused RT dispatches should have produced (uninitialised indirect
pointers), or from an unrelated kernel the benchmark scene is the first to run?

Translator, runtime function tables from an argument buffer (in progress, replayable offline with
`out/translator/release/examples/link_rt <linkdump dir> <kernel>` on NVMTL_LINK_DUMP output):
- `linked_functions::AMBIENT_TABLE_PARAMETER`: a `get_function_pointer_visible_function_table` whose table traces to no
  kernel parameter reads the ambient runtime table (ids = candidate index + 1); `rewrite_runtime_table_lookups` also
  handles typed pointers (bitcast to `i64 addrspace(1)*`). The nullness failure is gone, the link produces a 1.2 MB
  module with switch dispatchers over the 24 hit/miss candidates.
- `parse_struct_fields` accepts `{}` (a miss shader's empty payload).
- `ift_runtime::materialize_acceleration_structure_loads`: the acceleration structure loaded out of
  top_level_global_ab reaches `air.intersect` as `i64 <address>` (the emitter never materialises device-pointer
  values); the ray-query pass's new `Structure::Value` converts it with OpConvertUToAccelerationStructureKHR.
- Next failure: `air.sample_texture sampler operand is not a sampler` (hit shaders sample through
  smp_desc_heap_ab), and in the wrapper's sampler-heap retry `owned AccessChain %459 references undefined id` - the
  emitter's address network again. The translator dylib has NOT been rebuilt with these changes (the game still gets
  nil RT pipelines); rebuild the wrapper (both arches, package.sh lipo) once the chain translates.

## 35. Benchmark fault attribution tooling (runs 64-73, 23:00-00:30)

Ray tracing was OFF in the game's settings all along (the rgs_* pipelines are built regardless), so item 34's RT
hypothesis is out. Tooling added to name the faulting kernel:
- NVK nvkmd/nvrm: `nvkmd_nvrm_va.c` traces every VA reservation, bind and unbind; at a channel fault it says whether
  the address is live, inside a reservation (and what is bound in it), unmapped (and how long ago), or never mapped,
  and prints all seven shaderProgramVA entries (always 0 here). `nvmtl_nvk_last_wseq()` (exported, default
  visibility - Mesa builds hidden) returns the sequence the last submission signals.
- Plugin: `nvmtl_lastk_*` (NVMTLObjects.m) keeps the last 192 dispatches (D: kernel name, SPIR-V fnv-1a hash,
  threads), commits (C) and submits (S: the NVK sequence + the hashes of the kernels in that command buffer, carried
  in `nvk_cmdbuf.lastk_h` which is copied into the submission part), written to ~/Library/Logs/nvmtl/lastk-<pid>.txt
  with the AIR of every kernel seen (lastk-<pid>-<hash>.ll) when the device is lost. `NVMTL_SPLIT_ENCODERS=1`
  seals a submission part at every compute encoder's end (works); =2 after every dispatch does NOT work: setBytes
  ring chunks belong to the sealed part and are freed under the encoder (run 72 faulted at VA 0 in the intro).
- Reading NVK's line: "channel FAULTED at sem N of M flushed" = the GPU completed N, the submission signalling N+1
  faulted (M is only the newest flushed).
Findings: every fault is a wild read, FAULT_PDE, VA never mapped (or in the 8 MB gap between two mappings, 0x73F000
past the lower one in runs 66 and 70 - identical offset, so a deterministic index); the faulting submission (run 70,
sem 356235) is one compute encoder of 20 dispatches starting 0ca73d37 66fbeb71 72329d58 1c41178e dab74cbd 53a177ff
71c6b195 89aa3835 ab43036e, CopyBuffer x3, ClearBuffer, 9398151e, ClearBuffer x4, f68729a4, b0908b0d. The same
encoder runs in the intro without faulting. This NVK fork chains consecutive dispatches at the QMD level ("gdq",
nvk_cmd_dispatch.c: the previous QMD's dependent-QMD pointer, barriers folded into QMD invalidate/membar bits) -
run 73 tests `NVMTL_GDQ_DQ=0`; if the benchmark survives, the chaining's barrier folding loses a write the next
dispatch's pointer load depends on.

## 36. The benchmark fault is a stale descriptor: the GPU reads memory freed two minutes earlier (runs 74-84, 00:00-01:00)

Dispatch crumbs (NVK writes a NV90C0 SET_REPORT_SEMAPHORE after every vkCmdDispatch when NVK_DISPATCH_CRUMBS=1;
the record names VkCommandBuffer + ordinal, printed with the fault) pin the faulting dispatch: run 77/78/83 = dispatch
#21 of its command buffer = kernel f68729a4 (448x320x16 threads, a froxel/cluster pass that reads through
IRDescriptorTableEntry pointers at root slots +8 and +40); run 80 = a CopyBufferCompute (direct [[buffer(29/30)]]
bindings). With every unmap kept (not a 2048 ring), run 83 says it plainly: `fault VA 0x408d3f000 is inside
0x408c00000+0x1800000 UNMAPPED 119.946 s ago (5842 unmaps later)`. The earlier "never mapped" addresses sat in the
process's 51 GB read-only reservation (0x2d6000000+0xcea000000, the game's arena), which any VA between 12 and 63 GB
falls into, so "a CPU pointer" was a red herring; "never mapped" came from the 2048-entry unmap ring. Not RT (off),
not gdq (off in run 73), not a no-copy buffer (0 host imports), not the translator: the game keeps a descriptor
(or a copy source) to a resource it released, which on Metal/Apple and on every pooling allocator keeps reading
mapped memory. NVK unmaps at vkFreeMemory, so the read is FAULT_PDE.
Mitigation = the driver-level answer other drivers give by accident: `NVK_VA_SINK=1` (nvkmd_nvrm_va.c) keeps every
freed VA range reserved and maps it, in 64 MB pieces, onto one 64 MB zero-filled GART "sink" allocation instead of
unmapping; a later bind of the same range unmaps the sink first. Stale reads return zeros, stale writes land in the
sink. VA is leaked on purpose (49-bit space; ~6k frees per run). Run 84 tests it.
Lesson on tooling: `bash cp-run.sh N | tail -1` blocks until the game exits (the pipe inherits the game's stderr),
so from run 75 on the "instant crashes" were the user's benchmark runs finishing; never pipe cp-run.

## 37. BENCHMARK COMPLETES: the fault was simdgroup_barrier lowered as a workgroup barrier (runs 85-100, 01:00-02:30)

Run 100: Cyberpunk 2077's built-in benchmark runs to the end on the RTX 3070: average 17.47 fps,
max 29.60, 82.84 s, 1447 frames, 1280x800, textures medium, FSR 2.1 auto, ray tracing off (M1 Pro's own GPU: 27.2).
Remaining: textures flicker between black and correct; the GPU fan never spins (the card is mostly idle: the plugin's
fps line shows the CPU blocked on the GPU 93% of the wall across ~27 submits per frame, each waited).

Root cause of the channel fault, found with exact crumbs (below): kernel 9398151e (light culling). Thread 0 of each
threadgroup takes the list offset with an atomic on a texture_buffer<uint> counter and stores it to threadgroup memory;
after a barrier every thread reads it and writes its light at offset*24. Metal Shader Converter emits
`air.simdgroup.barrier(i32 2, i32 1)` everywhere, including inside the thread-0 branch; the last operand is the
*memory* scope (threadgroup), but the native emitter read it as the execution scope and emitted
OpControlBarrier(Workgroup). On NVIDIA every workgroup barrier is hardware barrier 0, so thread 0 waiting inside the
branch and the other warps arriving at the later real barrier completed one barrier together; the others read
gCulledLightsOffset before thread 0 wrote it (stale shared memory from the previous threadgroup on that SM) and wrote
gigabytes away. Fix (native/emitter/ops/air_calls.rs): air.simdgroup.barrier always gets execution scope Subgroup,
the operand only sets the memory scope. The kernel validates; 11 barriers became Subgroup, 3 stay Workgroup.

Also fixed on the way (both real bugs, neither the cause):
- bindless slots of released textures were rewritten to the dummy immediately, under GPU work already committed;
  now deferred until the command buffers committed before the release complete (nvmtl_vk_bindless_drop /
  nvmtl_vk_slots_reap, reaped with the image graveyard).
- texture storage decided on ShaderWrite alone; NVMTL_USAGE_WRITES now also counts ShaderAtomic (0x20).
Wrong turns (kept as env switches, off by default): NVMTL_ZERO_HEAP (heap buffers zero-filled), NVK_VA_SINK (freed
VA kept mapped to a zero sink), NVK_SPARSE_GUARD (sparse VA arena 4-64 GB; RM refuses the 4-8 GB start), the
ENC78/G79 barrier rows, gdq chaining - the faults were wild writes from a garbage offset, so none of them helped.

Diagnostic tooling that finally localized it in one run (all env-gated, cheap parts always on):
- NVK_DISPATCH_CRUMBS=1 + NVMTL_GDQ_DQ=0: WAIT_FOR_IDLE + a "started" semaphore before every vkCmdDispatch and a
  "completed" one after; at a channel fault NVK prints `FAULTING crumb N = VkCommandBuffer #k`. Without the idle
  waits the crumbs only order *recording* (command buffers are recorded on many threads) - runs 77-94 misattributed.
- NVMTL_LASTK_WATCH=all: every dispatch records kernel hash, NVK crumb id, all bound buffers with their first 16
  CPU-visible bytes, and the first 8 entries (gpuVA + textureViewID) of the MSC descriptor tables at root +8/+40;
  the last 600 records resolve each texture entry to its bindless slot, the slot's shadow (what was last written to
  it) and the live object. Written to ~/Library/Logs/nvmtl/lastk-<pid>.txt with the AIR of every kernel.
- NVK VA trace: every reservation/bind/unbind; the fault address classified (live, reserved, unmapped how long ago,
  never mapped, CPU region of the process).
- scratchpad scripts fault_report.py / count_writers.py (session scratchpad) read those records.
Translator dylib rebuilt for both arches (it also carries the parked runtime-table / ray-query work of item 34);
the spvcache is keyed on it, so the first launch after a rebuild is killed once by the engine watchdog.

## 38. Object flicker (one object black for a frame, worse outdoors): what is ruled out (runs 101-110, 02:30-03:30)

Not whole-frame: a single object goes black and back. Tried and NOT the cause:
- deferred bindless slot release (g_slot_grave), ShaderAtomic counted as a write usage, the buffer graveyard
  (nvmtl_vk_buffer_retire defers frees/reuse past completion; NVMTL_NO_BUFGRAVE=1 disables) - run 106, no change.
- Shared events: signaledValue reads the CPU value, which is set only after nvmtl_vk_submit_wait / nvmtl_gsub_finish;
  EVFOLD only folds GPU-side waits. No early completion.
- GPU reads of sysmem are snooped (items 19-21), Cyberpunk does 0 managed uploads (Shared everywhere), NoCopy buffers
  import pages, async texture upload is off, res2 migration is off, MTLIO is not implemented (the game falls back).
- Out-of-order completion: the graveyards now reap below a watermark (every buffer with commit seq <= S finished;
  nvmtl_vk_cb_reap, NVMTL_REAP_ORDERED=0 restores the old rule). Census in menu and loading: 0 out of commit order,
  0 releases held back - Cyberpunk completes strictly in commit order, so this was never the mechanism.
Live A/B switch: `touch /tmp/nvmtl-serialize` makes every commit wait (<= 250 ms) for its command buffer, so the CPU
cannot run ahead of the GPU; `rm` turns it off; both are logged with the frame number ("serialize: ON at frame N").
If the flicker goes away with it on, the game is rewriting Shared memory the GPU still reads (an Apple completion /
UMA assumption we break); if it stays, the cause is GPU-side (translation, barriers, descriptor content).
Perf side notes: shared-in-VRAM budget override exists but memset into the BAR1 mapping bus-errors (device memory;
needs a Normal-NC kext mapping); GPU ~85% busy by timestamps yet low power (sysmem over TB3); submit-ahead declines are
dominated by "claimed" and "last part".
Result of the serialize A/B (run 112, benchmark, RT off): the object flicker STAYS with serialize on, so it is GPU-side.
A second defect showed up: with serialize OFF other places look clearly wrong, with it ON they look normal. Serialize
changes two things at once (the CPU cannot run ahead, and command buffers no longer overlap on the GPU), so a third
live switch separates them: `touch /tmp/nvmtl-noahead` stops submit-ahead (every part waits for the one before it on the
GPU, the CPU still runs ahead). Normal with noahead -> missing ordering between parts/command buffers on the GPU;
still wrong with noahead but normal with serialize -> the CPU rewrites memory the GPU still reads (UMA assumption).
Also: a benchmark that hangs on load was ray tracing switched on in UserSettings.json (acceleration structures plus a
500 MB placement heap exhaust VRAM); set back to false, backup UserSettings.json.bak-before-rt-off.
noahead result (run 114): other places look wrong with noahead on AND off; only serialize fixes them. So the second
defect is the CPU writing memory the GPU still reads, not GPU overlap. Our completion signals are exact, so the
suspects are writers that do not wait for completion: the plugin's own CPU-written rings (setBytes ring, per-draw
bind tables, argument-buffer encoders) wrapping while the CPU runs frames ahead, before the game's own buffers.

## 39. Panic: kernel data abort in the DevCtl watch thread (NVRM 0.308.1219)
panic-full-2026-11-05-134500: kernel_task, data abort on a non-canonical pointer inside IOPCIFamily, called from
NVRM::devCtlWatch + 156 (configRead16). The watch thread (item 21) looped forever on a raw NVRM*, with no retain and no
exit, reading config space through fPCI every 5 s; after the eGPU's nub went away (the run had just ended; the
pre-panic log did not survive) it read through a dead object. Fix (NVRM 0.309.830): fDevCtlLock held around every
config access, fDevCtlStop set under it by didTerminate and stop (both run before the nub can be freed), 100 ms stop
polling, the thread retains the driver and exits with thread_terminate; the start-once static became fDevCtlRunning.
debug.nvrm_devctl_fixes was 0 this boot: the watch is a guard, it has not had to clear a bit.

## 40. The "wrong materials / lighting" defect: Cyberpunk rewrites a Shared buffer before our GPU reads it (runs 115-131)
Ruled out on the way: Shared heaps (all 8 of the game's heaps are Private, storage 2; Shared-heap range deferral added
anyway, NVMTL_HEAP_DEFER=0 disables, never fires here), frames-ahead as such (the CPU was only 2-3 frames ahead).
Detector (NVMTL_LATEWRITE, default on): every Shared buffer range bound with setBuffer/setVertexBuffer/
setFragmentBuffer (and their offset setters) is hashed (256 bytes, four 64-byte quarters) at commit and again right
before the command buffer's first part reaches the GPU; a change is logged with lag, frames ahead, the CPU/GPU writer
classification (a command buffer using the buffer that finished since the commit = GPU-possible; every earlier buffer
finished = certain) and whether the command buffer waits on an event (a legal CPU-to-GPU hand-off).
Result: always the same 2 MB Shared buffer (gpuVA 0x2eb3d0100), range 0+256, rewritten by the CPU ~20-35 ms after the
commit of an unlabeled 1-part command buffer with no waits or signals, 40-70 command buffers later. The game paces
itself by polling MTLSharedEvent.signaledValue (36k reads), completion handlers and status; it never waits on this
command buffer, so it assumes it ran within the frame (true on Apple's GPU, not with us).
Frame pacing (NVMTL_MAX_FRAMES_AHEAD = frames allowed on the GPU after a presenting commit; off disables):
2 -> 30 hits per 8192 command buffers, 1 -> 20, 0 -> 0 (menu fps ~48 -> ~38). Also counted: sync use per primitive.
CORRECTION (run 130): with frame-serial pacing the game looked WORSE, and the gameplay hits were all bytes 128-255 of
the 256-byte window on a 192 MB packed ring (first 16 bytes never changed) - the window ran past the bound data into
the next allocation, which the CPU legally fills. The 2 MB hits had unchanged heads too. Item 40's overwrite is NOT
proven; the window is now 32 bytes (8-byte quarters). Frame pacing stays at its default 2 (it rarely engages).
Encoders: up to 24 open at once across threads, ~half begin while another is open. A one-encoder-at-a-time switch
(/tmp/nvmtl-oneenc, 50 ms timed semaphore) does not work: encoders stay open for long, almost every take times out,
fps 49 -> 11. Not a usable test.

## 41. Interned samplers were destroyed while bindless slots still named them (NVMTL_SAMPLER_KEEP)
nvmtl_sampler_acquire interns one VkSampler per state; nvmtl_sampler_release destroyed it at the last reference. The
bindless sampler slots (nvmtl_vk_bindless_sampler_slot) look samplers up by VkSampler handle and are never rewritten,
and command buffers in flight can still sample through them. On NVK a sampler descriptor is an index into the device
sampler table, so the next sampler created takes the freed index with ITS state: slots and in-flight draws read the
wrong filter / address / compare mode. Cyberpunk does this at the menu already (16 last releases, 34 states live).
Fix: the interner keeps a state's VkSampler for the process (refs go to 0, the entry stays and is reacquired);
NVMTL_SAMPLER_KEEP=0 restores the old destroy. Fits the A/B: serialize hid it (nothing in flight at release), noahead
and frame pacing did not (the CPU still runs ahead within a frame).
User check after item 41 (run 134): materials and lighting "much better"; objects still flash black.

## 42. Texture views were destroyed at release; live magenta dummy (runs 134-136)
Checked and not the cause: zero-returning VA guards (NVK_VA_SINK / NVK_SPARSE_GUARD are not set by cp-run.sh), res3
sparse buffers (bound at creation and fenced; res2 paging is off), encode-time argument-buffer capture (this game has
no "embedded" per-draw fields: tier2 routes every argument-buffer texture through the bindless heap).
Found: a texture view object (newTextureView...) destroyed its VkImageViews (own, swizzle, sampled-depth, texel) in
dealloc at once, while the root texture's views wait in the graveyard. On NVK a view descriptor is an index in the
device image table, freed at destroy and handed to the next view, so draws still in flight, or a bindless slot not yet
reaped, read another texture. Serialize does not remove this: other threads keep encoding and releasing while one
commit waits. Fix: view-only graveyard entries (nvmtl_vk_image_retire(NULL, ...)); NVMTL_VIEW_GRAVE=0 restores. 256
released views at the menu alone.
Live switch: `touch /tmp/nvmtl-dummy-magenta` clears the 1x1 dummy texture to magenta (rm: back to black), logged with
the frame. A flashing object that turns magenta samples an empty/released slot or an unbound texture; one that stays
black gets its black elsewhere (shader maths, lighting buffers). Unbound-texture reads elsewhere will also show magenta.
User check after item 42: the magenta dummy did not change the flashes (they are not empty-slot samples), and the
flashes happen only while moving and clear at once; a still object almost never flashes.

## 43. min_lod_clamp was dropped on every non-gradient sample (texture streaming reads unloaded mips)
Metal Shader Converter shaders carry DX12's per-resource ResourceMinLODClamp (the descriptor table entry's metadata)
into air.sample_texture_* as the min_lod_clamp float, the argument right after the level/bias float. The translator
kept it only on gradient samples (sample_gradient_pair); implicit and bias samples dropped it, so while the game
streams finer mips in, the GPU sampled mips that were not uploaded yet (fresh VRAM, black) until streaming caught up:
black only while moving, fine at once. Also the device never enabled shaderResourceMinLod.
Fix: find_sample_min_lod_clamp (sample_depth.rs) reads that float; implicit/bias samples get the MinLod image operand
(+ MinLod capability); explicit-LOD samples (explicit level, integer textures, non-fragment stages that force LOD 0)
use FMax(lod, clamp) since SPIR-V forbids Lod with MinLod. Plugin enables shaderResourceMinLod.
Translator tests: the 3 textures-band failures (and a 4th) fail the same way on the pre-change sources.
x86_64 translator could not be rebuilt (Homebrew rust has no x86_64 std); the package keeps the 02:18 x86_64 slice.
TOOLING: since the 13:56 install, `timeout 300 out/rendersim/texsim` loses DYLD_INSERT_LIBRARIES and texsim loads
the INSTALLED plugin from /Library/GPUBundles. Run texsim in the background with a kill watchdog instead; check that
the first log line names out/package-arm64. A dev-plugin texsim run with items 40-43 in: 67 PASS / same 3 FAIL.
Result (run 139): still flashes while moving. The fix is live (2531 modules re-translated after 15:03; 614 sample ops
carry MinLod, 328 of them new non-gradient ones) but it is not the flash. Next A/B, in-game and live: Resolution
Scaling FSR2 -> Off (the 853x533 internal resolution seen in item-37 captures is FSR2's); a flash tied to camera
motion points at the temporal path (motion vectors, history reprojection).
FSR2 off: still flashes (not the temporal upscaler). Enqueue order is honoured (enqueue reserves the queue slot).

## 44. Flick monitor: per-frame zero-texel series plus plugin events (one round to tie a flash to a cause)
`touch /tmp/nvmtl-flickmon` (consumed): for 1200 presented frames, each frame's G-buffer pass (first full-width pass
with 3+ colour attachments; attachments 0-2) and first full-width B10G11R11 pass are read back after completion
(nvmtl_vk_image_read_keep) into the all-zero texel fraction and channel means, with an 80x50 thumbnail, in
~/Library/Logs/nvmtl/flickmon-<pid>.txt and flickmon-<pid>/; each frame also gets an "E" line of event deltas
(texture objects made/gone, heap textures placed/recycled, views made/gone, buffer-to-texture blits, bindless slots
assigned/reaped). Costs ~20% fps (menu 45 -> 36). scratchpad flickmon_report.py <txt> <outdir> finds one-frame jumps of
the zero fraction against the 8 neighbouring frames, prints that frame's events, and writes PPMs of the frame and the
one before. Menu run: G-buffer is fmt 58/58/37, no spikes.
Benchmark run with the first monitor (run 143): the user saw many more glitches, and the data had whole-target zero
frames. Cause: the monitor read the attachments with nvmtl_vk_image_read_keep from a utility thread after completion,
as its own submission with layout barriers from the CPU-tracked layout, while later frames were already rendering
into the same G-buffer: it both disturbed rendering and read later frames' half-written contents. Partial spikes looked
like a dithered band (LOD cross-fade?) of exact-zero albedo. Discard lowers to OpDemoteToHelperInvocation, which NAK
compiles to KIL (upstream behaviour); the device does not enable shaderDemoteToHelperInvocation (NVK advertises it).
Monitor v2: the copy is recorded into the game's own command buffer right after the pass
(nvmtl_vk_cmd_copy_image_to_buffer_layer into a host-visible buffer), read on completion; colour attachment 0 gets a
320x200 thumbnail; the G-buffer pass must have >= 20 draws.

## 45. FLASH ROOT CAUSE (candidate): no barrier between a compute encoder and the next render/blit encoder
User: in the benchmark the same objects flash at the same moments every run (deterministic, GPU-side). Monitor v3
(G-buffer copied after the first full-width B10G11R11 lighting pass, in the game's command buffer; the first
3+-attachment pass only clears and draws a little, later passes load and add) shows the gaps: right after a benchmark
camera cut, for one or two frames, whole surfaces are missing from the G-buffer (exact zero, rendered black), then
present. That is GPU-driven culling / draw lists read stale: static views are unaffected (last frame's list is the same),
newly visible objects are missing for a frame - "only while moving, gone at once".
Barrier audit: compute dispatches carry their barrier BEFORE them (nvmtlE78Barrier); after the last dispatch, G79's
end-of-encoder rule owed a full barrier only when a loose (compute-only) barrier had been used, and render/blit/AS
encoder creation (nvmtl_g79_flush) paid only an owed one. So compute -> render in one command buffer had NO barrier when
the dispatches all had full barriers (512 such joins at the menu alone). Also no barrier began a recording, so with
submit-ahead a part starting with a render pass was unordered against the previous part's compute.
Fix: nvmtl_g79_flush pays a full barrier whenever compute ran last (NVMTL_G79_RENDER_BARRIER=0 restores; same for the
non-G79 end-of-encoder path), and nvmtl_vk_cmd_begin starts every recording with a full barrier (NVMTL_PART_BARRIER=0).
Menu fps 45 -> 43. Run 149: benchmark recording pending.
Run 149 (barrier fix in): user still sees the flashes. New detail from the user: a flash lasts half a second to a second
(not one frame), looks like the object "has not loaded yet", and moving again can bring it back. The monitor's one-frame
spike test cannot see that, and its zero-normal metric also counts sky/background (nothing drawn), which changes at
every camera cut: the "missing surfaces" reading of item 45 is NOT proven. The barrier fix stays (a real gap: 512
compute->render joins at the menu had no barrier) but is not shown to be the flash.
Safe-mode A/B (run 151): NVMTL_NO_HEAP_ALIAS=1 NVMTL_NO_DIRTYONLY=1 NVMTL_NO_ALIGN_GUARD=1 NVMTL_GDQ_DQ=0
NVMTL_EVFOLD=0 NVMTL_LATEWRITE=0. If the flashes go, bisect these. Note: the game does have one Shared heap (234 MB).
Safe mode result: still flashes, and indoors went very bright / off-colour (the six features are needed, e.g. the
align guard). The flash is not in those plugin paths. Logs show no forwarded (unimplemented) selectors, no skipped
dispatches, no refused passes. Defaults restored (run 153). Next: per-pass capture at the exact benchmark moment of a
flash (deterministic), to see whether the object is black already in the G-buffer colour or only after lighting.
User: flashes every ~2 s in the benchmark (too many to time). NAK honours min-LOD (CLAMP / BIAS_CLAMP, txd via
lower_txd_clamp), so that chain is complete. Pass capture (/tmp/nvmtl-passcap N): every full-width pass of N frames,
all colour attachments at 256x160, copied in the game's command buffer. Run 155 (dark room -> door opens -> purple
alley): the G-buffer is filled by ~6 passes per frame (first ~110 draws, then 82, 56 with motion vectors = dynamic
objects such as the opening door and NPCs, 33, 117, 6); pass numbers are CPU endEncoding order (multithreaded, not GPU
order) and the P lines were written after async stats, so frame attribution was unreliable: "door black" / "NPC black"
silhouettes came from pairing a frame's final image with the NEXT frame's first G-buffer pass. Captures now carry the
exact GPU completion order (ord, stamped in the completion handler) and the command buffer's commit seq (run 157).
Whole-benchmark final-image capture (/tmp/nvmtl-finalcap N, run 159) + scratchpad flash_viewer.py -> a 1475-frame
HTML viewer (benchmark-frames.html in the session folder). The user marked many flashes; the clearest is viewer frame
442 (pool hall): a woman drinking (white top) and the man beside her render as BLACK silhouettes for ~442-450 (~0.5 s)
and pop to correct colours at 452 - characters "not loaded yet". Run 161: /tmp/nvmtl-passcap "70 405" (count, start
delay in frames from the benchmark-start trigger) to capture every pass around that moment.
Run 161 capture of the pool-hall moment: the woman and the man beside her are correct, then BLACK silhouettes for
~0.4 s, then correct again - and they are black already in the G-buffer colour attachment (drawn, zero albedo), not a
lighting fault. Run 163: same capture with /tmp/nvmtl-dummy-magenta on from the benchmark start, to tell an empty /
released bindless slot (magenta) from real texture data that reads zero (stays black).
Magenta run (same window): the black characters stay BLACK with the dummy magenta, so they do not sample an empty or
released slot. In that black frame the G-buffer normal attachment holds the man's normals; colour (c0) and the material
attachment (c2) read zero: the draw ran, its albedo/material textures returned zeros. Separate finding: character skin
glows magenta-white in the lighting result, so the skin (SSS) lighting samples an unbound texture (another bug).
Per-frame events: textures are created and uploaded in bursts (e.g. +17 textures / 105 buffer->texture blits in one
frame, +20 / 136 later); the characters recover right after such a burst.
Upload verify (/tmp/nvmtl-upverify, live): each buffer->texture copy is copied back in the same command buffer with the
same row pitch and compared with its source on completion; mismatches are logged with format, size, level, region,
row pitch, block size, and whether the readback is all zero. texsim: 64 copies, 0 mismatches. Run 163: whole benchmark.
Upload verify over the whole benchmark: 8192+ buffer->texture copies, 0 mismatches. From launch (run 165, also
NVMTL_REPLACE_VERIFY=1): 8192+ copies, 1 mismatch (a 256x64 RGBA32F table whose source changed after row 4, a CPU
rewrite), and the game never calls replaceRegion. Texture data is uploaded correctly; the black comes from sampling.

## 46. min_lod_clamp past the last level: NVIDIA returns 0, Apple returns the last level
D3D-style ResourceMinLODClamp: the engine passes a clamp that can exceed the texture's level count while a texture is
streaming ("nothing resident yet"). NVIDIA's TEX LOD clamp (NAK CLAMP / BIAS_CLAMP, D3D semantics) returns zero, Apple
clamps to the smallest level, so on Apple the object is blurry for a moment and here it is black until streaming
lowers the clamp. Translator: clamp_min_lod_to_levels (sample.rs) clamps the value to OpImageQueryLevels - 1 (FMin)
on every path (MinLod operand, explicit-LOD FMax, gradient). Sample tests: 100 pass, the 3 pre-existing failures.
Run 168: pool-hall capture pending.

## 47. BLACK-FLASH ROOT CAUSE: the inliner left loop phis naming the unlabelled entry block (translator)

Symptom (since the start of the Cyberpunk work): characters and moving objects turn black for ~0.4-0.6 s, deterministic
in the benchmark (pool hall, ~445 frames after its start). In the G-buffer the albedo and material targets read zero,
normals are right.

How it was found (runs 177-207): every 10 frames the game switches a set of meshes to their dithered-LOD variant of the
same irconverter shader (e.g. fs `ebfaee83` instead of `bbbe74b0`); the variant is the same AIR plus one noise-texture
read and a call to `irconverter_discard`. A per-draw pixel probe (/tmp/nvmtl-pixprobe) showed those draws writing zero
albedo; replacing the variant's SPIR-V with the normal one (NVMTL_FS_SUBST=ebfaee83=bbbe74b0) removed the flash, so the
translation was wrong, not the data (descriptor chains dumped CPU/GPU/after-completion were identical).

Cause: `translator/src/native/inline.rs` `inline_one()` inlines the multi-block `irconverter_discard` into the entry
block of `ps_main_`. That block has no label in the text (implicit `%12` after 12 unnamed parameters), so
`enclosing_block_label()` found nothing and `relabel_phi_preds()` was skipped: the multilayer loop header's phis kept
`[init, %12]` although the edge now leaves from `.inl0.cont`. spirv-val on the pre-structurization module says "OpPhi's
incoming basic block %154 is not a predecessor"; structurization then stored the initial values on no edge, the layer
loop started from uninitialised (zero) accumulators and mask, and no layer was ever blended in.

Fix: `inline_body_to_fixpoint` gets the caller's implicit entry id (`implicit_entry_block_id` of the caller's params)
and `inline_one` uses it when the call sits in the unlabelled entry block. The fixed translation validates and has the
same structure as the non-dithered shader; the non-dithered shader translates byte-identically; translator lib tests:
the same 16 failures before and after (pre-existing). texsim 67/3 (baseline). Run 207: pool-hall woman correct in every
frame after the camera cut.

Offline repro: python ctypes calling `nvmtl_translate()` in libnvmtl_translate.dylib reproduces the in-game SPIR-V
byte-for-byte; METAL2VULKAN_PHASE_DUMP gives the phase modules; NVMTL_DUMP_RETRY_LL the inlined text.

Also fixed on the way (both real, neither the flash): SSBOs bound at 4/8-byte offsets fell back to the dummy (plugin now
sets `nvk_ssbo_align_4b`, NVMTL_SSBO_ALIGN_4B=0 reverts); `copyFromTexture:toTexture:` copied only mip 0 / slice 0
(NVMTL_WHOLE_COPY_ALL=0 reverts). Diagnostics added, all off by default: /tmp/nvmtl-texverify, /tmp/nvmtl-drawlog,
/tmp/nvmtl-skipfs, /tmp/nvmtl-pixprobe (+ argument-buffer chain dump), NVMTL_MARK_NEW, NVMTL_GBUF_CLEAR_MARK,
NVMTL_ZERO_UPLOAD_MARK, NVMTL_WIPE_WATCH, NVMTL_FILL_ORDER, NVMTL_FS_SUBST, NVMTL_NODEMOTE_FS, NVMTL_NO_DEMOTE (NVK;
crashes the game), nvlog_diag (unthrottled diagnostic log; nvlog keeps only 8 lines per format).

Open: NVRM leaks its DMA buffers across GPU re-enumeration (after several game kills RmInitAdapter fails with "Could
not allocate sysmem flush buffer", "DMA buffers alive: 512"; only a reboot clears it).

## 48. Second phi bug of the same class (switch fold) and the stall regression from always-on diagnostics

`fold_switches_to_branches_in` (translator/src/native/inline.rs) rewrote a switch that sat in the function's unlabelled
entry block and named the predecessor "entry" in the successor phis, so the default value was lost (kernel
37600f5457154428). It now uses `implicit_entry_block_id` like the inliner fix in 47. A sweep of all 2258 AIR functions
dumped from Cyberpunk 2077 (NVMTL_DUMP_AIR_DIR, scratch tr/sweep2.sh: translate, phase-06 phi predecessor check,
spirv-val) finds no phi problems and no invalid outputs after both fixes. Translator lib tests: same 16 pre-existing
failures.

Stalls ("sometimes it suddenly hangs"): the 47-era diagnostics were on by default. They are opt-in now:
NVMTL_FILL_ORDER=1, NVMTL_WIPE_WATCH=1, NVMTL_ZERO_UPLOAD=1 (or NVMTL_ZERO_UPLOAD_MARK), NVMTL_PSO_LOG=1,
NVMTL_DUMMY_PROBE=1.

New diagnostics (off by default): /tmp/nvmtl-census "count delay" writes one line per draw (R) and dispatch (K) per
frame to census-<pid>.txt; NVMTL_BAR_ABAB=N runs every compute barrier full in frames f with (f/N) odd and the relaxed
g79/e78 rules (H7, P1, BAR, ENC) in even windows, so one run tells whether a one-frame artefact follows the barrier rules.

Open: wet-floor reflection (puddle sheen) missing for one frame outdoors (run 212 frames 6590, 6593, 6611, 6631). The
census shows the same passes on those frames as on their neighbours (only periodic jobs differ), so the pass runs but
its result is wrong for a frame.

Run 213 (NVMTL_BAR_ABAB=16): the upper alley puddle's sky sheen is missing in frames 6942..6944 and 6942/6943 are in a
full-barrier window (433), so the relaxed compute barrier rules are not the cause. Camera motion is a steady 2 px per
frame across those frames (no frame-time spike). Next, NVMTL_SYNC_ABAB=N: in odd N-frame windows every commit waits for
its command buffer and a presenting commit waits until no earlier frame is on the GPU (CPU never ahead of the GPU).
Run 214 (NVMTL_SYNC_ABAB=16): the same sheen is missing in frames 4853..4855, all in a synchronised window (303), so
CPU/GPU overlap is not the cause either. The blink happens at the same camera position in runs 207, 212, 213 and 214
(the far wet edge of the first alley puddle after the pool hall): it follows the scene, not timing. Next: the same
benchmark on the Apple GPU (no plugin) as a reference.

## 49. PUDDLE FLICKER ROOT CAUSE: parallel render sub-encoders inherited each other's state (plugin)

Symptom: the wet edge of the first alley puddle after the pool hall vanished for 1-3 frames at the same camera position
in every benchmark run; the Apple GPU (screen recording) shows it in every frame. Chain of evidence (runs 213-234):
- barriers (NVMTL_BAR_ABAB) and CPU/GPU overlap (NVMTL_SYNC_ABAB) ruled out: blinks inside full-barrier and fully
  serialised windows;
- per-pass capture (/tmp/nvmtl-passcap, NVMTL_PASSCAP_ALLFMT=1): the G-buffer's third target lost the wetness written by
  the decal pass; pixel probe: decal fs a858d921 (projected box decal) wrote nothing on bad frames;
- every decal input proven equal on good and bad frames (instance ring, DrawArguments, clip plane, depth, normal copy,
  pixel-to-world matrix, decal record, mask/noise heap slots, fixed-function state); the decal's stencil test
  (>= ref 11, mask 31) failed because the floor's stencil was 20;
- per-draw stencil/depth rows (probe with no targets): the floor tile (fs 50e8f503, 30 indices x 2, static instances)
  drew with stencil reference 0 on good frames and 20 on bad ones, depth identical to the prepass.
Cause: NVMTLParallelRenderCommandEncoder replays its sub-encoders one after another into one real encoder and did not
reset state between them; Metal starts every sub-encoder from defaults. A sub-encoder that relied on the default stencil
reference 0 inherited 20 from the previous one; the draw split across sub-encoders varies per frame.
Fix: before each sub-encoder after the first, stencil reference 0/0, depth bias 0, cull none, winding clockwise, blend
colour 0, depth-stencil state nil, viewport and scissor = the pass size. NVMTL_PAR_NORESET=1 restores the old rule.
Run 234: puddle wetness continuous over the whole visible stretch (no dropouts; every earlier run had some).

Also changed on the way (not the cause, kept as Metal semantics): a pipeline without a stencil format in a pass with a
stencil attachment now gets its depth-stencil state's stencil test instead of the previous draw's, a pipeline without
depth gets the stencil test off, and a compatible pipeline switch re-applies depth-stencil state
(NVMTL_STENCIL_STALE=1 restores the old rule).

Diagnostics added (all off unless armed): pixel probe now 4 rows x 3 targets + stencil + depth rows per draw, draw kind
and arguments, indirect args, vertex buffer NVMTL_PP_VB=<index> fetch at GPU time; NVMTL_PP_DECAL=1 decal input dump
(dd-*.bin); NVMTL_DD_HEAPIDX=a,b heap-slot capture; per-pass stencil log (stenpass) while the probe is armed;
NVMTL_BAR_ABAB=N, NVMTL_SYNC_ABAB=N (alternating barrier / serialisation windows).

## 50. Performance round 1 (runs 238-241): submit pipelining and copy-engine readback

Benchmark average (same segment rule for every run, fps log submits/frame >= 25 and fps < 45):
run 238 baseline 20.77 fps -> 239 SYNC-AHEAD 21.84 -> 240 + NVMTL_GSUB_INFLIGHT=32 22.33 -> 241 + copy-engine readback 23.07 (+11 %).
Native M1 Pro GPU on the same benchmark: 27.2 fps.

Measured with NVK_PERFMON=1 (pstate, clocks, util) and /tmp/nvmtl-passtime-request (4 s of every recording's GPU total
plus 1200 render / compute (fmt 9001, W = dispatches) / blit (fmt 9002) segments; `rec` lines now name the submitter).
Clocks were never the problem (P0, 1920-1950 MHz); graphics busy ~86 % with VRAM bandwidth ~5 %.

1. GPU idle between recordings (15.9 % of wall in run 238). 91 % of submissions went through nvmtlAdvancePart's
   submit-and-wait: while the worker waited, its part was `claimed` and the submit-ahead pass stopped at it, so every
   command buffer committed meanwhile waited for the fence. Fix (NVMTLEventSync.m, NVMTL_SYNC_AHEAD=0 reverts): the
   worker submits, marks the part in flight (and promises its signals) under the class lock, kicks the ahead pass, then
   waits; the ahead pass skips a claimed part that is in flight. An empty last part (signals only) no longer blocks the
   command buffers behind it. After: 90 % of submissions go ahead, idle 8.3 %, GPU busy 92-95 %.
2. Surface-out readback (NVMTL_SURFOUT_READBACK=cpu, the Apple Silicon default): one 1280x800 BGRA8 drawable per frame,
   ~1.8-2 ms over TB3, 8.8 % of GPU time on the graphics queue, queued behind parts submitted ahead. Fix: NVK's nvrm
   backend reports has_transfer_queue (NVRM_610_XFERQ, needs CECHAN; COPY4 channel), the plugin requests one queue of
   the copy-only family and nvmtl_vk_image_read records the copy there (NVMTL_XFER_READBACK=0 reverts). Every caller
   reads after the producing part's fence (or after its own upload wait), so no cross-queue semaphore is needed.
3. Remaining, run 241 segment window: render 40.6 %, compute 30.8 % (median 61 us per dispatch; encoders of 12
   dispatches at 1.8 ms), blit 13.3 % (largest 4.2 ms each), other 10.2 %, idle 5.1 %. Low VRAM bandwidth with a busy
   engine points at shaders and copies reading Shared buffers in system RAM across Thunderbolt (Shared stays in sysmem
   by design, batch 56: BAR1 is Device memory to the CPU). Next candidate: VRAM twins for GPU-read-mostly Shared
   buffers, filled by the copy engine at submit; needs a census of bound Shared bytes per frame first.
4. Blit encoders of many small buffer copies (runs 243-244). Per-blit tallies (passtime fmt 9002: fs = KB buffer->buffer,
   buffer->texture, texture copies, KB read from system memory; W = commands) showed encoders of ~115 copies of ~1 KB
   from system memory taking 3-4 ms: every copyFromBuffer sat between two full ALL_COMMANDS barriers. Fix
   (nvmtl_vk_cmd_copy_buffer_batched, NVMTL_BLIT_BATCH=0 reverts): one barrier before a run of buffer copies, another only
   when a copy's source or destination overlaps a destination of the run (or its destination overlaps a source), by GPU
   address; every other blit command and endEncoding settles the run with a barrier. Barriers per copy 2 -> 0.48; blit
   share 13.3 % -> 4.9 %; benchmark 23.07 -> 24.61 fps (run 244; 20.77 at the start of the round, native GPU 27.2).
5. Shared census (NVMTL_SHARED_CENSUS=1, from the late-write bound-range list): per second ~10 distinct Shared buffers,
   one 192 MB heap, one 12 MB, one 2 MB, the rest under 4 KB; ~1.5 Shared bindings per command buffer. How much of the
   heap the GPU reads per frame is still unmeasured.
6. Run 244 window: render 48.7 %, compute 30.8 % (61 us median per dispatch, barriers between serial dispatches are
   already compute-to-compute), blit 4.9 %, other 5.3 %, idle 10.2 %.
7. PCIe traffic and Shared page churn (run 245, NVK_PERFMON=1 now logs NV2080_CTRL_CMD_BUS_GET_PEX_UTIL_COUNTERS TX/RX
   deltas per second, apparently bytes; NVMTL_SHARED_CENSUS=1 also hashes every 16 KB page of the >= 1 MB Shared buffers
   in use, three times ~0.2 s and ~0.8 s apart). During the benchmark: TX 250-330 MB/s (drawable readback is ~100 MB/s of
   it), RX 190-420 MB/s, i.e. ~8-17 MB of host memory read by the GPU per frame; graphics busy 96 %, VRAM 6-9 %. The
   192 MB Shared heap changes ~2-3 MB per frame (8-15 MB per ~0.2 s, 40-80 MB per ~0.8 s, CPU and GPU writes together).
   A VRAM twin would have to keep the heap's GPU virtual addresses (argument buffers hold them), i.e. back the same GPU
   VA with VRAM while the CPU keeps the system pages, copy CPU-dirty pages in before each submit and GPU-written pages
   back after; GPU-written ranges are not known, which is the open correctness problem.
8. Per-dispatch cost (tools/arm64-probes/latprobe.m, runs 246-251). latprobe times, with the command buffer's GPU times,
   1000 one-thread dispatches in one encoder and a one-thread pointer chase: on the RTX 3070 over TB3 a dependent load
   from system memory costs 2.85 us (VRAM 0.16 us, M1 Pro 0.45 us); a serial empty dispatch 12.1 us (M1 Pro 2-3 us), a
   concurrent one 0.31 us. Ablating NVK's compute barrier (temporary NVK_BARDBG mask: 1 plain WFI, 8 no flush, 2 no
   invalidate, 4 nothing) showed the whole cost is the wait-for-idle itself: it serialises dispatches, and on Ampere NVK
   takes each dispatch's QMD and root descriptor table from the upload stream, which is GART, so every serial dispatch
   pays the scheduler's QMD fetch and the shader's root fetch across Thunderbolt in sequence.
   Fix (Mesa, NVK_CS_VRAM=3, still opt-in): a VRAM-only upload stream per command buffer (pool free_vram_mem, never CPU
   mapped); when the push stream ends in a compute barrier that nvk_CmdPipelineBarrier2 recorded (hb_* in
   nvk_compute_state), nvk_cmd_upload_qmd rewinds to before the barrier, writes the root table and the QMD into VRAM with
   I2M, and replays the barrier, whose wait-for-idle orders the writes before SEND_PCAS. Dispatches without such a
   barrier keep the GART path. Serial empty dispatch 12.1 -> 1.33 us, with 64 B setBytes 17.5 -> 6.9 us, concurrent
   unchanged; 66 % of the benchmark's dispatches take the VRAM path. Benchmark 24.61 -> 25.72 fps (run 251).
   Dead ends, measured: I2M without completion (NVK_CS_VRAM=2, NVK_CS_VRAM_FLUSH unset) races - the scheduler read an
   unwritten QMD (channel fault "compute shader VA 0x0" in latprobe; Cyberpunk run 247 hung while loading); FLUSH_ONLY on
   every dispatch costs ~5.7 us (a sysmem membar) and turns concurrent dispatches from 0.31 into 6 us; FLUSH_ONLY with
   SYSMEMBAR_DISABLE still races. Run 248 (NVK_CS_VRAM=3) also left by the engine watchdog while loading, and run 250
   showed nine multi-second CPU-side stalls in the benchmark; run 250 itself loaded fine (the "hang" sampled was shader
   translation) and run 251 had no stall, so both are open but not reproduced.
   Remaining per-dispatch cost: setBytes dispatches still 6.9 us - the plugin's setBytes data lives in system memory.
9. Automation and a corrected baseline (runs 261-275). Cyberpunk takes `-benchmark` (next to benchmark.gamedef in the
   binary's option strings): tools/arm64-probes/cp-bench.sh <run> launches into the benchmark (CP_ARGS in cp-run.sh) and
   the game quits by itself; it also writes benchmarkResults/<date>/summary.json (averageFps) and frames.csv. The old
   "native 27.2 fps" was game 2.3 at 1800x1125 with RT reflections off - not comparable. Native M1 Pro with
   the current settings (2.5, 1280x800, RT reflections on, RT lighting Medium), -benchmark: 53.8 fps. Ours: ~25 fps. The
   3070 is ~95 % busy, so its work per frame is inflated, not starved.
   - The probe binaries (latprobe, csstress) load the INSTALLED /Library/GPUBundles plugin (Metal in a command-line tool
     does not read MetalPluginName through IORegistryEntryCreateCFProperty, which enumsim interposes); only NVK comes from
     out/. NVK-side results stand; plugin changes must be checked in the game. libenumsim2.dylib (also interposes
     CreateCFProperties / SearchCFProperty) is built for probes but not verified yet.
   - NVMTL_TABLES_BAR (address tables / setBytes ring in VRAM through BAR1, aligned CPU stores, own 64 MB budget, blocks
     kept): 1 = both: GPU-busy samples +4 % but ~10 of 40 samples CPU-bound (runs 266/268/271/273); 2 = tables only 25.03
     fps; 3 = ring only 25.35 and 25.07 fps with 0-1 CPU-bound samples (runs 270/274) vs 24.38/24.79 off (267/272).
   - Run 274 per-dispatch + NVMTL_PSTAT=1: no spills anywhere, half the dispatch time in 24-GPR kernels; small kernels
     cost 22-35 us (6-thread kernel 29 us, 36-thread clear 22 us, a 121-instruction kernel 35 us x 672) against 1.3 us for
     an empty one in latprobe - the game's kernels wait on dependent reads of Shared data and address tables in system
     memory. Render passes: 1280x800 VkFormat 58 25 %, 122 (B10G11R11) 22 %, and 550 passes on a 20x38 VkFormat 43 target
     at 120 us each, 18 % of render time - fixed latency per pass, not pixels.
   - NVK runs ray queries as software BVH traversal in shaders ("ray queries on NVK's software BVH"), no RT cores.
10. Run 275 (RT reflections and RT lighting off, settings restored afterwards): ours 25.12 fps, native 54.44 - the same as
    with RT on (25 / 53.8), so software ray queries are not the gap. NVMTL_TABLES_BAR now defaults to 3 (ring only).
    Run 276, NVMTL_PT_DRAW=1 (per-draw timestamp segments, kind 9004; fs = system-memory buffers bound, buffers bound,
    vertex/index count, instances; NVMTL_PT_MAX raised to 512 segments per command buffer): every one of 29429 draws had
    2-4 system-memory (Shared) buffers bound, so placement cannot be told apart per draw. Indexed draws median 5.1 us,
    non-indexed 50 us. The remaining lever is the game's Shared data itself: a VRAM twin behind the same GPU VA, CPU-dirty
    pages copied in per submit, GPU-written pages copied back - not started.
11. VRAM twin, ceiling experiment (runs 277-280).
    - Write tracking (NVMTL_SHARED_CENSUS=1 NVMTL_SHWATCH=1, run 277): the large Shared buffers are write-protected in
      1 s windows (SIGBUS/SIGSEGV handler takes faults inside the tracked ranges only, forwards the rest; Cyberpunk kept
      running). Per second in the benchmark: the 192 MB buffer had 5000-7000 CPU-written 16 KB pages (~4-5 MB a frame)
      and 130-600 pages changed by the GPU only; the 12 MB buffer 60-290 CPU pages, 0-26 GPU-only.
    - latprobe broadcast test: 1M threads x 64 loads of one 256 B buffer take 127 us Shared vs 124 us Private - system
      memory IS cached in L2; the cost is first-touch / dependent-load latency, not missing caching.
    - Twin (Mesa nvkmd_nvrm_mem_twin + exports nvmtl_nvk_memory_twin / nvmtl_nvk_cmd_copy_va; plugin NVMTL_TWIN=1 with
      NVMTL_SHARED_CENSUS=1): the 192 MB buffer is a placed sub-buffer of a 224 MB Shared heap, so the heap's memory is
      twinned: VRAM of the same size, a shadow GPU VA on the system pages, the original VA rebound to the VRAM
      (after vkDeviceWaitIdle). CPU-written pages (fault tracking) are copied shadow -> VRAM in the pre-submit prologue
      (2 GB over the first 8192 submissions including the initial full copy). Run 280: the first 6 s of the benchmark at
      27.83 fps against 22.3-22.8 for the same 6 s in the six runs before (+23 %); then the channel faulted (FAULT_PDE
      at a low VA): GPU writes are not copied back and a page copied in for a CPU write also overwrites GPU-written
      bytes of that page. A correct twin must keep GPU-written ranges on the system pages (VA rebound per range).
12. Twin follow-ups (runs 281-284) and resolution scaling.
    - Where the GPU writes (run 281, union over 1 s windows): the 192 MB buffer's GPU-only-changed pages grew from 980 to
      6259 (half of the buffer) in 182 runs with new regions every window - a ring both sides write in turns, so no fixed
      GPU-written region can be kept out of the twin.
    - CPU reads (run 282, pages PROT_NONE, ESR WnR splits read and write faults): 300-600 pages read per second, 82-463
      of them in GPU-written pages. A twin needs GPU writes visible to CPU reads, not only careful uploads.
    - NVMTL_TWIN=2 (byte-diff upload: per-page snapshot, only 16-byte chunks the CPU changed are copied) (run 284): 1.39
      M copy runs in 2048 submissions, 5.6 fps, and the same FAULT_PDE - the fault is stale CPU reads of GPU-written
      data, not clobbered GPU bytes. Twin parked: it needs read-side coherence (GPU results back to the CPU pages before
      the CPU reads them) that a signal handler cannot do through Vulkan.
    - 2560x1600 (runs 283 + native, settings restored): ours 13.41 fps, native 18.20 (1.36x) against 25 / 53.8 (2.2x) at
      1280x800 - the remaining cost is mostly fixed per draw/dispatch, not per pixel.
51. 3DMark Steel Nomad (macOS demo). The GUI's Run starts dlc/steel-nomad-test/macos/bin/3DMarkSteelNomad
    --in=setting.json --out=Result.json (cwd dlc/steel-nomad-test) with DYLD_* stripped, so GUI runs are the M1 Pro:
    899 / 898 (9.0 fps, Apple GPU 100 % busy). Running the child directly with cp-run.sh's environment reached the
    RTX 3070 after three fixes: (1) reflection set elementIsArgumentBuffer on every buffer argument of a function that
    had any argument buffer (3DMark: "merge_reflection_to_layout: Unexpected argument buffer name" on spvDynamicOffsets);
    now per buffer index (NVMTLObjects.m). (2) The macOS 27.2 SDK's AIR atomics carry one more i32 operand before the
    volatile i1 (store/RMW/f32 6, load 5, cmpxchg 8); the translator accepts both arities (air_calls.rs, test
    native_device_atomics_accept_the_macos27_sdk_extra_operand). (3) A sampler read from an argument buffer in two
    branches and merged by a phi (after CFG restructuring a synthesized lmerge phi) had no translation; with argument-buffer
    samplers the phi now merges the heap slots (OpPhi %uint) and samples through the merged slot (phi_compare.rs,
    functions.rs sampler_slot_source_values, core_inst.rs named slot ids). Result: SUCCESS, 15.83 fps (~1580 points,
    median 15.7, p10 14.9, p90 17.3); Windows desktop RTX 3070 is ~3160-3180 points (~32 fps) in UL's database.
    Translator unit tests: the same 37 failures with and without these changes (pre-existing).
52. Steel Nomad image. The 15.83 fps run of item 51 drew almost nothing: frames written with
    enable_frame_output (setting.json: enable_frame_output, enable_fixed_fps, frame_output_fixed_fps 1,
    frame_output_file_name = absolute path prefix) were flat fog colour. Per-pass capture (/tmp/nvmtl-flicker-request,
    NVMTL_FLICK_FRAMES) showed XeGTAO_PrefilterDepths at -65504 and every post pass the same constant colour.
    tools/arm64-probes/abprobe.m reproduces it: a constant/device buffer pointer in an argument buffer (with or without
    spvDynamicOffsets) read 0 on the 3070, right on the M1 Pro. Cause: the wrapper's argument-buffer-sampler retry builds
    the module raw first (RAW_BUFFERS_FIRST) and kept the raw module whenever it kept every texture op; the raw
    construction turns argument-buffer buffer pointers into null constants. Fix (translator lib.rs): the typed primary
    wins when it reads through device addresses and the raw module has none (module_device_address_count). Over the 292
    Steel Nomad shaders, 145 took raw-first and all 145 had 0 vs >0 device addresses. abprobe now reads (3, 7) / 5.
    Steel Nomad then renders the scene: 6.64 fps (median 8.0) - the 15.83 was an empty frame. Still wrong vs the M1 Pro
    from the first frame: sunlit rock dark (shadowing), some geometry missing (a tall tripod structure), extra haze;
    later the lit target (geometry_illumination_multipass c4) and SSR inputs grow from ~0.5 to 10-57 and frames go white
    or black (feedback through the previous frame's illumination).
53. Steel Nomad image, continued. Work files now live in out/3dm (setting.json, frames-<tag>, air dump, spv,
    translator-failures-baseline.txt); tools/arm64-probes/sn-run.sh <tag> nv|m1 [frames] runs the test child directly.
    - Ruled out with probes on both GPUs: depth-compare sampling (2D, 2D array, Depth16Unorm; cmpprobe.m), depth bias on
      D16 (biasprobe.m), simd_prefix_exclusive_sum / simd_shuffle / quad_shuffle_xor / device atomic add+max
      (simdprobe.m). Shadow maps are Depth16Unorm arrays (4096x4096x3 sun, 2048x2048x8 lights) drawn per slice and hold
      geometry. Turning off every recent optimisation and resource reuse (out/3dm/safe-env.txt) changes nothing.
    - Static audit (out/3dm/audit.py over the 290 shaders translated through the wrapper as the plugin calls it): one
      kernel, CalculateFroxelsLightScattering, had 63 constant reads replaced by null constants. Its typed construction
      failed ("owned SampledImage references undefined id") because cross-arm cloning (clone_crossarm, names %xa<id>_)
      copies texture loads after the opaque-resource set was computed from the uncloned IR, so the copies were loaded as
      device addresses and their image never defined; the raw fallback then dropped the constant reads. Fix: emitter
      lookups of opaque resource / sampler names see through clone names (functions.rs names_contain, core_inst.rs,
      phi_compare.rs). No shader now ends in the raw construction ([raw-used] with METAL2VULKAN_RETRY_DEBUG).
    - Plugin diagnostics added: NVMTL_PASSLIST=<n> (one line per render pass with attachments and layers); the flicker
      capture now reads Depth16Unorm and logs the fraction of non-finite texels.
    - Still wrong: haze/fog differs from the first frame; in the fixed-fps run the lit scene jumps ~300x within one frame
      (DOFDownscaleCoc 0.15 -> 43) and illumination_halve comes out 100 % NaN although DofCombine is finite - a compute
      pass between them (not covered by the render-pass capture) produces the NaN, which copy_real carries into the next
      frames (runs of black frames).
54. Kernel differential testing. tools/arm64-probes/kdiff.m runs one compute kernel from a metallib on the
    default device with deterministic synthetic inputs (argument buffers filled through argument encoders from the
    pipeline reflection) and dumps every resource; dumped AIR text compiles with `xcrun metal -c x.ll` + `metallib`.
    out/3dm/kdiff-all.sh runs all 114 Steel Nomad compute kernels on the M1 Pro and the 3070 and compares
    (out/3dm/kcmp.py). 83 identical (TAA, CompositeVolumetrics, cloud shadows, grass, culling ...); all 5
    ButterflySLM_FFT_CS variants (FFT bloom, 32x32x2 float2 threadgroup array) differ with NaNs on one side - but that
    batch used 8x8 threadgroups; with 32x32 the M1 is deterministic, the 3070 rerun is pending. Kernels that never end
    with synthetic inputs must not run on the 3070: killing them there hung the GPU and the eGPU dropped. On re-arrival
    the bring-up failed at the first DMA map (setMemoryDescriptor -> 0xe00002d7, osIovaMap failed, "DMA buffers alive:
    512") - the same re-arrival failure as the earlier panic, this time without a panic; a replug does not recover it,
    a reboot does.
55. Steel Nomad image FIXED by pipeline reflection. The engine builds its argument buffers from pipeline
    reflection. nvmtl_build_buffer_argument's kindAt map turned every embedded binding that was not a sampler into
    "texture", EmbeddedArgBufferBuffer included, so every constant-buffer pointer inside an argument buffer reflected as
    a texture (e.g. ButterflySLM_FFT_CS set0.Constants) and the engine never placed the constants behind it: kernels
    such as the FFT bloom read zero constants (FFTThreshold 0 -> white haze, then NaN -> black frames). Fixing the kind
    alone faulted the GPU at start-up (VA 0x0): the pointer then reflected with dataSize 0 and no elementStructType, and
    the engine sized its constant block from that. Now nvmtl_air_walk_struct records each pointer member's air.buffer
    node (arg_type_size, arg_type_align_size, struct_type_info) as names[@"pointees"] and the member's MTLPointerType
    carries size, alignment, access and the element struct, matching the M1 Pro field for field (kdiff KDIFF_REFL=1).
    Result: no black frames, haze and lighting match the M1 Pro (out/3dm/cmp-refl-aligned.png).
    - kdiff caveats: KDIFF_DEVICE=NVIDIA is needed (the default device follows the main display), and kernels that
      assume a threadgroup shape (the FFT: 32x2, shared memory indexed by gid&31 / gid.y&1) race under any other shape,
      so a synthetic-input mismatch there proves nothing.
    - The census now logs every dispatch ("D f<frame> <kernel> grid .. tg ..").
    - Open: in fixed-fps mode the 3070 run emits more frames than the M1 Pro (58 vs ~51) and drifts a few frames late.
    - Real-time on the 3070 after the fix: SUCCESS 12.14 fps (median 12.1, p10 11.5, p90 13.2), no fault;
      the same run with the old reflection scored 5.99 fps. A second run with the per-pass capture at 30/50/70 s
      (9.56 fps, slowed by the capture) had no non-finite texel in any pass and a steady tone_map output
      (out/3dm/rt-tonemap.png). screencapture fails from this shell (no screen-recording permission).
56. Cyberpunk 2077 benchmark after the reflection fix (same Custom settings, 1280x800, game's own summary).
    Run 292: the first launch after a translator change missed every spvcache entry and the engine watchdog fired
    while the first compute pipelines were translated (no benchmark; the 8 rgs_* "pointer nullness is not tracked"
    failures and the Steam init error are in every earlier run too). Run 293: 23.48 fps, 9 frames > 100 ms totalling
    16.2 s (cold-cache translation; 29.3 fps without them). Run 294, warm: 28.16 fps, min 21.76, 66.1 s, median frame
    33.6 ms, 5 frames > 100 ms (max 740 ms). Best before: 26.94 fps (median 36.5 ms).
    A translator update makes the next first launch slow enough to trip the watchdog: warm the cache (or launch twice).
57. Native vs 3070. Cyberpunk 2077 benchmark, identical settings (66 summary keys equal except gpuMemory):
    M1 Pro native 53.82 fps vs 3070 28.16 fps (run 294) = 52 %. Steel Nomad real time, same
    setting.json: M1 Pro 8.98 fps (median 9.0) vs 3070 12.13 fps (median 12.1) = 135 %.
58. CORRECTION to items 9, 10, 56, 57: UserSettings.json has the master switch RayTracing = False, and every benchmark
    summary involved (two native runs, 3070 runs 275 and 294) records rayTracingEnabled: false.
    RayTracedReflections = True / RayTracedLighting = Medium are stored sub-options that do nothing while the master
    switch is off. So all those Cyberpunk numbers are WITHOUT ray tracing, and "RT on vs off gives the same fps, so
    software ray queries are not the gap" (item 10) was never tested: both runs had RT off.
59. Why Steel Nomad and Cyberpunk differ. Census per frame: Steel Nomad 4K ~4900 draws + ~450 dispatches;
    Cyberpunk 1280x800 (run 295, 28.57 fps) ~1770 draws + ~210 dispatches, 8x fewer pixels. Frame time per draw: 3070
    16.8 us (SN, 82.6 ms) and 19.8 us (CP, 35.5 ms) - nearly the same; M1 Pro 22.7 us (SN, 111 ms) and 10.5 us (CP,
    18.6 ms). The 3070 behaves as if every draw/pass had a ~17-20 us floor (fixed latency: Shared data in system RAM
    over TB3 x4, per-pass cost, dependent loads), which heavy 4K draws hide and light 1280x800 draws expose.
    Resolution check (older runs and build on the 3070): 2560x1600 M1 18.2 fps (55 ms) vs 3070 13.41 (74.6 ms).
    From 1280x800 to 2560x1600 (3x more pixels) the M1 adds 36.4 ms and the 3070 adds ~37.5 ms (from 26.94 fps / 37.1
    ms that day): Cyberpunk's per-pixel work runs no faster on the 3070 than on the M1 Pro, unlike Steel Nomad. Two parts,
    then: a fixed ~18 ms per-frame excess, and per-pixel shader work that does not get the 3070's throughput.
60. Cyberpunk frame budget on the 3070, current build (passtime with NVMTL_PT_SEGS=20000, run 296 at
    1280x800 27.7 fps and run 297 at 2560x1600 16.0 fps; per-dispatch runs 2910/2920; out/cp-pt*.log, out/pt*.py).
    CORRECTS item 59's "per-pixel work is no faster": that compared a 2560 run and a 1280 run made on different builds.
    - 1280x800, 36.1 ms a frame: GPU inside recordings 29.3 ms (41.5 recordings a frame); measured segments 27.3 ms =
      render 15.5 + compute 10.0 + blit 1.75; 99 segments a frame under 100 us cost 5.6 ms (25 passes on a 20x38
      target at ~85 us each, 1 draw apiece). GPU idle between recordings 6.7 ms: 1.7 ms of ~40 us gaps between
      back-to-back recordings, 4.5 ms in ~1.6 gaps a frame over 1 ms (median gap 44 us; max 14 ms). Long gaps sit next
      to nvmtlAdvancePart (submit-and-wait) recordings: 358 of 4602 recordings, ~3 a frame.
    - Scaling 1280 -> 2560 (3x more pixels): segments over 100 us grow 21.7 -> 44.7 ms (+23 ms); the M1 Pro's whole frame
      grows 18.6 -> 55 ms (+36 ms). The 3070 does the pixel-proportional work ~1.6x faster than the M1 Pro. At 2560 the
      3070 reaches 88 % of native (16.0 vs 18.2 fps); at 1280 52 %. The gap is the fixed part: ~5.6 ms of tiny
      passes, ~6.7 ms of GPU idle, and fixed cost inside the big passes - about 14+ ms a frame against an 18.6 ms
      native frame.
    - Compute per frame 9.1 (1280) / 15.1 ms (2560) over ~170 dispatches; heaviest kernel 8c859b85 (4x4x4 groups,
      froxel-like) 0.86 / 2.87 ms. Pipeline statistics came out empty in the dispatch log.
61. GPU idle in Cyberpunk is the CPU submitting late. passtime "rec" lines now carry host_submit and
    gpu_start on CLOCK_UPTIME_RAW (calibrated pair): of 109 GPU idle gaps over 1 ms, 105 ended with work submitted
    after the GPU had gone idle (2.5 / 4.6 / 15.9 ms late, quartiles); 4 had work queued already.
    CPU samples (sample <pid> 3, out/cp-sample*.txt, out/sampleparse.py; ~6.3 ms per sample in this process):
    - 31 % of all on-CPU time was nvmtl_trace_on's CLOCK_MONOTONIC_RAW read on every nvtrace() guard (per draw/bind).
      Now a 250 ms dispatch timer polls the request files and the guard reads a flag (NVMTLObjects.m). fps unchanged
      (27.76): the workers were not saturated (~40 % on CPU, ~56 % after).
    - Parallel render encoders: setVertexBuffer:offset:attributeStride:atIndex: went through NSInvocation (recorded on
      the worker, invoked again in the replay). Fast path NVP_VBUFSTRIDE added. Run 301 28.56 fps, run 302 29.42
      (game summary; 26.94 the best before, 28.16 just before).
    - What remains on one thread: the parallel encoder's endEncoding replays every sub-encoder's calls into one
      render encoder: ~750 ns a call, median 109 ms/s, p90 307 ms/s in the benchmark (~10 ms a frame in heavy parts).
      Recording sub-encoders straight into Vulkan secondary command buffers on their own threads would remove it.
    - CPU sampling during passtime is misleading: the per-command-buffer timestamp pools (pt_pool) are created and
      destroyed per submission, which put RM free ioctls on nvmtl.execution. Without passtime there are none.
62. Parallel render encoders recorded on their own threads, NVMTL_PAR_DIRECT=1, OFF by default.
    Each sub-encoder gets a shadow NVMTLCommandBuffer of the same queue and a real render encoder on it (first keeps the
    pass's load actions, the rest Load; all Store; not taken for resolves, a visibility buffer or IOSurface attachments);
    the parallel endEncoding splices the shadows' recordings as parts (-nvmtlSpliceShadows:, NVMTLEventSync.m) and moves
    their completion handlers, late-write records and errors. Image identical (/tmp/nvmtl-shot-request screenshots,
    out/cp-shots-cmp.png); no lock contention in the driver. But slower: alternating runs 310-315, game summary
    27.98 fps (28.17/27.83/27.93) vs replay 29.40 (29.52/29.45/29.24), median frame 34.4 vs 32.9 ms - the G-buffer
    becomes 8 render passes, each reloading and storing every attachment behind a full barrier (~1.5 ms a frame).
    Doing it without splitting the pass needs secondary command buffers inside one render pass; this plugin begins
    passes lazily per pipeline and ends them for barriers/clears inside an encoder, so that is a larger change.
    - New diagnostic: /tmp/nvmtl-shot-request copies the next presented drawable (in its command buffer) to
      ~/Library/Logs/nvmtl/shot-<pid>-<n>.raw (header magic, w, h, row bytes, VkFormat).
63. Is the parallel-encoder replay worth removing?
    - Feasibility: NVK has KHR_dynamic_rendering, EXT_dynamic_rendering_unused_attachments, KHR_maintenance7 and
      EXT_nested_command_buffer. The plugin uses VkRenderPass objects made per pipeline (p->rp, the pipeline's attachment
      shape), begins the pass at the first draw, binds later pipelines that declare a subset of the pass's attachments,
      and breaks a pass inside an encoder only for the pixel probe (diagnostic). Recording sub-encoders as secondary
      command buffers inside one pass would need: a pass shaped from the descriptor, pipeline variants for that shape (or
      dynamic rendering + unused attachments), per-secondary viewport/scissor, render-encoder barriers as in-pass
      self-dependencies, occlusion queries inherited or excluded, and the secondaries' pools retired with the part.
    - Worth: NVMTL_PAR_DELAY_US=5000 (busy-wait at the start of the replay, ~1 parallel encoder a frame) runs 320-323:
      29.14 / 29.19 fps with the delay, 29.26 / 29.42 without - 5 ms a frame of extra serial replay costs ~0.5 ms of
      frame time. The replay is mostly off the critical path; removing its ~10 ms would gain about 1 ms (~3 %).
      Not pursued. The late submissions behind the GPU idle (item 61) come from elsewhere.
64. Micro render passes in Cyberpunk. The 20x38 passes (25 a frame, ~70 us each, one draw, a 20x38 area
    of a 64x64 RGBA8 sRGB atlas texture) run trivial fragment shaders (one texture sample; 19e8941b, bcc233ef, b7a39c5d,
    a9003d39 in ~/Library/Logs/nvmtl/airdump) with 56-118 constant-space loads each.
    tools/arm64-probes/tinypass.m (one encoder per pass, GPU time per pass):
    - a trivial 20x38 pass costs 16 us on the 3070 through the plugin (M1 Pro: 40 us); load action does not matter;
    - a Clear pass in a larger texture (64x64) costs 24 us: begin_pass clears the whole texture with barrier +
      vkCmdClearColorImage + barrier ("fullclear"), +8 us;
    - TP_CHAIN dependent loads, one 128-byte line each: Private 20.0 / 23.3 us for 8 / 30 loads, Shared 39.6 / 96.4 us -
      ~2.4 us per dependent system-memory miss across Thunderbolt vs ~0.1 us from VRAM.
    So the ~50 us a micro pass costs above a trivial one is ~20 dependent system-memory reads (argument buffers, the
    plugin's address tables, constants): latency, not render-pass overhead. NVMTL_TABLES_BAR=1 (address tables in
    VRAM through BAR1) is still a loss: runs 330-333, 27.52 / 27.56 fps vs 29.42 / 29.48 at the default 3, p90 frame
    50.6 vs 42 ms. Possible small wins left: do the fullclear inside the pass (render area = the whole attachment)
    (~8 us per such pass), or have the copy engine upload the address tables to a VRAM mirror at submit (CPU writes
    stay in system memory). The large part is the game's own Shared data in system memory (item 11/12 twin problem).
65. Does Cyberpunk use Managed storage? No (run 340). The plugin already answers hasUnifiedMemory = NO;
    the arm64-only binary references didModifyRange: / synchronizeResource:, but a census of device buffers by
    storage mode (NVMTLDevice.m newBufferWithLength:options:, "buffer modes" diag line) counts 4096 buffers: Shared 365
    (334 MB), Managed 0, Private 3731 (619 MB); heaps: one Shared 224 MB heap, the rest Private. The engine's Metal path
    assumes unified memory whatever the device says. Getting Managed behaviour means the driver inferring the
    didModifyRange / synchronizeResource points itself (the twin of items 11-12). The safe subset is Shared memory the
    GPU never writes: CPU writes tracked per page and uploaded by the copy engine at submit, GPU reads from VRAM.
66. DESIGN: Shared memory in VRAM with full CPU/GPU coherence ("shmirror"). Goal: an app written for
    unified memory (Cyberpunk, D3DMetal under CrossOver) keeps using Shared storage unchanged, the GPU reads and writes
    VRAM, the CPU sees exactly what it would on Apple Silicon at the points Metal guarantees visibility (command buffer
    completion, shared events signalled by the GPU). Managed resources keep their explicit path (didModifyRange /
    synchronizeResource; Intel-era games); Private unchanged. NVMTL_SHMIRROR=1 while it is being built.
    Facts it rests on: every MTLCommandQueue submits to the one graphics VkQueue (g_queue; g_xqueue is readback only),
    so parts execute in submission order; every device store and atomic the translator emits goes through a
    PhysicalStorageBuffer pointer (checked on Steel Nomad kernels); NVK has nvmtl_nvk_memory_twin (GPU VA -> VRAM copy,
    system pages kept at a GPU-visible shadow VA), nvmtl_nvk_cmd_copy_va (copy engine by VA), and fixed-VA allocation.
    Protocol, per twinned allocation (pool block, heap, standalone Shared buffer; whole VkDeviceMemory):
    - GPU side: the app's GPU addresses now reach VRAM. The CPU's contents pointer stays the system pages.
    - CPU writes: system pages are write-protected (PROT_READ); a write fault marks the 16 KB page dirty and unprotects
      it. At every submission (pre-submit prologue) dirty pages are re-protected first, then copied whole into VRAM by
      the copy engine (nvk_cmd_copy_va). Whole pages are safe: the queue is in order, so every earlier part, and its
      copy-back below, has run before the prologue's copy.
    - GPU writes: the translator (cap bit) instruments every PhysicalStorageBuffer store/atomic: address -> twinned
      range (sorted range table in VRAM, binary search; table address as a specialization constant so the spvcache
      key does not change per process) -> atomicOr of a bit per 16 bytes in that range's dirty bitmap (VRAM).
    - Copy-back: at the end of every part that may have written (a pipeline with device stores, or a blit/fill/query
      copy into twinned memory), an epilogue kernel walks the bitmaps, copies the written 16-byte chunks from VRAM to the
      shadow VA (system pages), clears the bits. Completion handlers, waitUntilCompleted and GPU-signalled events come
      after it, so the CPU reads current data. Chunk granularity keeps concurrent CPU writes to other bytes of a page.
    - Plugin-side GPU writes (blit copy/fill into a twinned buffer, visibility results, counter samples) are copied
      back by explicit ranges recorded at encode time.
    - Not twinned: IOSurface-backed and host-imported (bytesNoCopy) memory, buffers with texture views (writes through
      image stores are not instrumented), Managed, Private, memory the SASS / vendor paths write.
    - CrossOver (x86_64 under Rosetta): same code in the x86_64 slice; pages stay 16 KB-aligned ranges; the fault
      handler chains to the previous SIGBUS/SIGSEGV handler (Wine's) for every fault outside twinned memory.
    Order of work: (1) coherence torture probe (CPU/GPU ping-pong, same-page mixed writes, atomics, blits, fragment
    stores, argument-buffer pointers, heaps and pooled small buffers, shared-event mid-buffer, Managed) passing on the
    M1 Pro and on the 3070 as it is now; (2) translator instrumentation behind a cap bit; (3) plugin twin of every eligible
    allocation + range table + bitmaps + prologue/epilogue; (4) probe, Steel Nomad, Cyberpunk; (5) a Managed-mode game
    and a CrossOver game.
67. PROBE PITFALL: `perl -e 'alarm N; exec @ARGV' probe` strips DYLD_* (/usr/bin/perl is a protected
    binary), so the probe runs on the INSTALLED /Library/GPUBundles plugin (here an older build) with no enumsim/usenv,
    silently. Invalid because of it: the kdiff-all batch (item 54) and the FFT 32x2 / 32x32 reruns on the 3070
    (they compared the old plugin; the ButterflySLM conclusions there are void), and the first cohprobe runs (k_atom
    "air.atomic.global.add.u.i32 expects 5 operands" is the old translator, fixed since). Valid: direct runs (kdiff
    reflection, tinypass), and every game run (sn-run.sh / cp-run.sh launch the game directly). Use
    tools/arm64-probes/nvrun.sh <timeout> <probe> [args]: injects only into the probe (system sleep/kill are arm64e and
    refuse the arm64 dylibs) and kills it after the timeout. Check "+load ... out/package-arm64" in the log.
    tools/arm64-probes/cohprobe.m (11 coherence tests, item 66 step 1): ALL PASS on the M1 Pro and on the 3070 with the
    current plugin (Shared in system memory) - the baseline every shmirror step must keep.
68. shmirror implemented, NVMTL_SHMIRROR=1 (off by default while it is verified).
    - Translator wrapper: store_note.rs (instrumentation; 2-level table as in its header comment; spirv-val clean on all
      290 Steel Nomad and 2258 Cyberpunk shaders: 24 / 155 modules carry 144 / 1019 store sites), exports
      nvmtl_spv_instrument_stores, nvmtl_spv_store_note_spec_id, nvmtl_shm_lower_stored_roots (address lowering keeps
      no descriptor a shader stores to - Cyberpunk's ClearBufferCompute / CopyBufferCompute kept theirs).
    - Plugin: nvmtl_shm.c (+ shm_copyback.comp / .spv.h). Wrappers on vkCreateShaderModule (instrument) and
      vkCreate{Graphics,Compute}Pipelines (table address at SpecId 0x4E565301). App Shared buffers (host_visible 2):
      small ones from a mirrored pool g_spool (32 MB system blocks adopted at creation), large ones adopted on their
      own; the buffer park keeps adopted memory apart (kind 3). Prologue uploads dirty 16 KB pages; every part's
      epilogue runs the copy-back kernel and copies back plugin writes (copy/fill/query/word/image-to-buffer).
      SASS dispatch is off while shmirror is on. Internal host-visible allocations (staging, readback) are never
      adopted: readbacks submit outside parts.
    - cohprobe ALL PASS with it on (and off). Steel Nomad frames: same image as before, no fault; real time 12.75 fps
      (12.13 / 12.14 without).
    - Not covered yet: Shared heaps (Cyberpunk's 224 MB heap stays in system memory), textures made on an adopted
      buffer or placed in adopted memory (image writes are not instrumented), the x86_64 NVK slice (an older build) has no
      nvmtl_nvk_memory_twin / copy_va, so under Rosetta (CrossOver) shmirror reports UNAVAILABLE and stays off.
69. shmirror flicker found and fixed. With NVMTL_SHMIRROR=1 Cyberpunk drew some frames wrong (black
    blocks; one frame from another camera with no textures) - the user saw half the screen flicker. Consecutive-frame
    capture (/tmp/nvmtl-shot-request now takes a count, e.g. `echo 24 >`) scored A-B-A flicker 30/57/79 with shmirror,
    none without. New diagnostic /tmp/nvmtl-shm-audit (nvmtl_shm.c shm_audit): with the queue idle, every clean
    (write-protected, not dirty) page must hold the same bytes in VRAM and system memory; Cyberpunk had 7-13 clean pages
    differing, VRAM frozen while the system copy changed - CPU writes that never faulted. Cause: the fault handler
    marked the page dirty and THEN unprotected it; a prologue in between took the mark and protected the page, and the
    handler's mprotect(RW) left it writable and unmarked for good. Now unprotect first, then mark (and a failed mprotect
    keeps the pages dirty). After: audits 0 differing pages, flicker score <= 2 over 46 frame triples (as without).
    - Also fixed: dispatch timers created in a dispatch_once block were local objects under ARC, released and cancelled
      at once - the audit timer never fired, and neither did item 61's trace-request poll (tracing could not turn on).
      Both sources are static now.
    - Epilogues now run only for command buffers that bound a pipeline with store sites (vkCmdBindPipeline wrapper,
      module/pipeline handle sets) or recorded plugin writes; prologues return at once when nothing faulted.
    - Cyberpunk with shmirror after these: 27.80 / 27.83 / 27.86 fps (runs 364-366) vs ~29 without; Steel Nomad faster
      (12.75 vs 12.13). First launch after enabling hit the engine watchdog once (run 350).
70. shmirror uploads moved to the copy-engine queue (NVMTL_SHM_ASYNC, default on; =0 restores item 68).
    - The dirty-page copies of the prologue are recorded into one of 8 command buffers on g_xqueue (the readback
      queue's family, own pool) and submitted there. Two timeline semaphores order them (nvmtl_shm.c):
      G - a part whose epilogue recorded a copy-back ("writer", c->shm_writer) signals G = ++gval; an upload batch
      waits G >= gval first, so the system pages hold every GPU write and a whole-page copy cannot overwrite one in
      flight. U - a batch signals U = ++uval; the first graphics part after it waits U >= uval and starts with the
      prologue's closing barrier (nvmtl_vk_pre_barrier) to drop stale cache lines. NVK turns both waits into GPU
      semaphore acquires (signal already submitted). If the copy-queue submit fails, the same runs go into the
      graphics prologue and async is turned off.
    - nvmtl_shm_forget waits for any prologue scan in progress (g_shm_scanning) and for the last batch before the
      memory is freed. vkQueueSubmit on g_xqueue is serialised by g_xqlock (readbacks too).
    - Checks: cohprobe 24/24 (2 rounds) with async; Cyberpunk audits 23040 pages, 0 differ (run 367).
    - RESULT: no fps change. Cyberpunk async 27.32 / 28.00 vs graphics-queue uploads 27.58 / 27.80 (runs 368-371,
      alternating); shmirror off 29.09, on 27.89 (runs 374/375). The uploads were not what costs the ~1.2 fps.
    - NVMTL_SHM_DIAG_NOUP / NVMTL_SHM_DIAG_NOEPI (drop uploads / copy-backs) are diagnostics only and do not measure
      the cost: without the bytes the game renders and behaves differently (benchmark segment 36 s instead of 74 s at
      32.6 fps; without copy-backs 26.24 fps). Next suspect: the CPU write faults (~690k per run, ~440 per frame).
71. What the shmirror write faults cost (runs 378/379, tools/arm64-probes/faultbench.c).
    - faultbench (no app): one write fault (trap, signal, mprotect RW, return) 6.1 us on one thread; concurrent faults
      serialise on the VM map lock (2 threads 13 us, 4 threads 24 us, 8 threads 46 us each). mprotect(READ) 1.4 us per
      one-page call; 4096 pages in one call 84 us.
    - In Cyberpunk (cost census every 5 s, "shmirror cost:" lines; NVMTL_SHM_PROBE=1 adds a 64-write self-test on
      private protected pages): no task-level EXC_BAD_ACCESS port, so faults go straight to our signal handler.
      Benchmark: 180-730 faults per frame, almost exactly one per written page per frame (no re-faults); handler body
      1.4-2.1 us, a complete fault 4.3-5.1 us (spikes to 1 ms seen twice) -> 0.9-3.6 ms of CPU per frame, spread
      evenly over 8+ worker threads (20-90 faults per thread per frame). Prologue 0.3-2 ms per frame on the submit
      path (3-12 scans, its mprotect calls 0.1-0.7 ms of that). Uploads 3-11 MB per frame.
    - So the faults cost little on any one thread; the ~1.3 ms per frame shmirror loses (27.9 vs 29.1 fps) is more
      likely on the GPU (the copy-back dispatches and their barriers in ~25% of parts, the barrier at the head of each
      part after an upload batch, the instrumented stores) - not measured yet. The game is mostly GPU-bound here
      (gpuwait ~78%).
    - Run 377 died at startup with nvrm escape 0x2b/0x57 errors (0x10000003) before any adoption; not reproduced
      (378/379 fine, cohprobe fine after it).
72. Where shmirror's GPU time goes (passtime runs 382 off / 381 on, tools/arm64-probes/cp-ptrun.sh arms the
    20000-segment capture 20 s into the benchmark; out/ptcmp.py, out/ptrec.py, out/ptmatch.py; copy-backs are passtime
    kind 9005, barriers included). Both captures run at ~20.5 fps (capture overhead).
    - The two 4.8 s windows do not hold the same frames (135 vs 148 render segments a frame), so per-frame totals differ
      by content more than by shmirror. ptmatch.py compares the mean GPU time of the same segment (render: size,
      format, fragment shader; compute/blit: op count) in both runs, covering 97 % of the GPU time.
    - At the same content shmirror makes the GPU work FASTER: render -1.44 ms, compute -0.35 ms, blit +0.01 ms a frame
      (-1.78 ms; largest 3f34d820 1280x800 179 -> 143 us x 19 a frame, kernel 1493 -> 1164 us). Copy-backs: ~5 a frame,
      0.11 ms in their segments plus ~0.2 ms elsewhere in their recordings.
    - So the net ~1.3 ms loss is not on the GPU. The GPU sits idle ~11 ms a frame between recordings in both captures,
      8-10 ms of it because the next part was submitted after the GPU finished the last (item 61): the frame is paced
      by the CPU's submissions, and shmirror's CPU work on that path (prologue 0.3-2 ms a frame, write faults on the
      encoding threads, item 71) lengthens the frame although the GPU work got shorter.
73. Why the GPU waited for late submissions, and the fix (NVMTL_AHEAD_PAST_DONE, default on).
    - passtime "rec" lines now carry each part's timeline (UPTIME_RAW ns): recording begun, part sealed, buffer
      committed, parts in flight at submit, when the worker noticed it done, and why submit-ahead last declined it
      (why / whymask, codes of nvmtl_ahead_why + 1). out/ptgap.py places every GPU idle gap > 0.2 ms by where the part
      that ended it stood when the GPU ran dry. Capture: NVMTL_PT_SEGS=1 NVMTL_PT_WIN_S=8 tools/arm64-probes/cp-ptrun.sh.
    - Before (runs 383/384, shmirror off): idle 5.6-5.8 ms a frame = 2.4-2.6 ms in ~43 small gaps (< 0.2 ms, one per
      recording) + 3.0-3.3 ms in ~2 gaps a frame of ~1.6 ms. Every large gap was "scheduler": its part had been
      committed 40-78 ms earlier (the app runs ~2 frames ahead), yet was submitted 1.55 ms (median) after the GPU went
      idle, through nvmtlAdvancePart with nothing in flight. They are chains of small one-part command buffers (0.1-0.25
      ms of GPU each) that submit-ahead never reached: the pass stops at a part the worker has claimed and that is not
      in flight, i.e. one the GPU already finished but the worker is still publishing (surface-out readback, events,
      callbacks). The kick after a submit loses that race for parts this short, and after a part with ~0 GPU time the
      worker spent ~1.5 ms publishing with the GPU idle.
    - Fix (NVMTLEventSync.m): a claimed part gets gpuDone once its fence is in; submit-ahead passes such a part as it
      passes an in-flight one, and the worker kicks the pass right then. Ordering is the rule that already held for
      parts behind an in-flight one. cohprobe 10/10 both with and without shmirror.
    - After (run 390): idle 2.26 ms a frame (scheduler gaps 3.0 -> 0.05 ms); GPU busy ~94 % of the frame.
      Benchmark, alternating: on 29.32 / 29.59 / 29.77, off 28.42 / 29.15 / 29.15 / 29.09 (runs 387-394; 386 discarded:
      cold cache after the run 385 crash). Stall samples 1-3 vs 9-12. The game is now GPU-bound, so the GPU-side gain
      of shmirror (item 72, ~1.8 ms a frame) should show; not measured yet.
    - Run 385 was killed by the engine watchdog at startup while the main thread translated shaders (cold cache), the
      known first-launch problem; not related.
74. shmirror after the scheduler fix (runs 395 warm-up, 396, 397 timeline; off baseline runs 391-394,
    same build, ~29.1 fps). Expected +0.5-1.5 fps (item 72's GPU gain, the game now GPU-bound); got 27.71 (396) and
    27.33 (397, with the timeline) - about -1.4 fps, as before the fix.
    - GPU idle came back: 8.31 ms a frame (2.26 with shmirror off), 6.08 ms of it "queued": ~4 gaps a frame of ~1.2 ms
      where the next part had been submitted ~21 ms earlier. The GPU waits on the upload semaphore U: the part after
      an upload batch waits for it, and the batch waits for the last writer part (G). With 16 parts queued ahead, that
      writer is usually the part just before, so writer -> copy-engine upload -> reader runs in series and the
      graphics queue stands idle during the upload (5-12 MB of whole pages a frame).
    - The prologue grew to 4-10 ms of CPU a frame (0.3-2 before): 1877 waits for one of the 8 upload command buffers
      (16543 batches, ~10 a frame) under the submit mutex.
    - So with submissions on time, shmirror's cost is the bytes uploaded on the critical path between a part that
      writes Shared memory and the next one; the GPU-side saving of ~1.8 ms does not cover it.
75. What the draws read from system memory (runs 398/399, NVMTL_PT_DRAW=1 NVMTL_PT_DISPATCH=1, shmirror
    off; out/ptdraw.py). The draw records now split the bound system-memory buffers by kind (slot sys: 1 own
    allocation, 2 pooled small buffer, 3 placed in a heap; one byte each in the record's first fs word).
    - Every draw binds 2-3 buffers in system memory, and nearly all are placements in a heap - Cyberpunk's one 224 MB
      Shared heap (item 65), which shmirror does not adopt: per frame 925 draws with 3 heap buffers (8.1 ms timed),
      755 with 2 (4.5 ms), 553 with 2 heap + 1 own Shared allocation (4.6 ms). No draw binds none.
    - Dispatches: ~110 a frame, mostly 1 Shared buffer bound (4.5 ms), 27 with 3 (1.1 ms).
    - Per-draw timing is coarse (timestamps ~3 us apart, and timestamps between draws serialise them, so latency is
      overstated). The one clean signal: tiny draws (<= 64 vertices) take a median 6.1 us with 3 system-memory
      buffers and 3.1 us with 2 (run 398) - about one dependent system-memory miss per extra buffer.
    - So the system-memory data on every draw's path is the Shared heap. Moving it is constrained: BAR1 is 256 MB
      (non-resizable), so a 224 MB heap cannot simply be mapped through it, and shmirror's cost is the upload of what
      the CPU writes (item 74) - the heap's CPU write rate decides which way is viable.
76. How the CPU and GPU use Cyberpunk's 224 MB Shared heap (run 400, NVMTL_HEAPWATCH=1: every 3 s a 1 s
    window with the whole heap PROT_NONE; first access per page counted, pages hashed before/after).
    - A streaming ring: the CPU writes 5900-9900 distinct pages a second (93-155 MB, about half the heap), sweeping
      pages 0-14279 (all of it) every 1-2 s in 150-260 runs; per frame at least 160-460 pages (2.5-7 MB; a page
      rewritten within the window counts once).
    - GPU writes into it are few: 0-690 pages a second changed without a CPU write.
    - The CPU also reads it: 100-440 pages a second read without being written in the window.
    - So: mapping it through BAR1 cannot work (224 of 256 MB, and those CPU reads would be uncached PCIe reads);
      adopting it into shmirror as it is adds 2.5-7 MB a frame of uploads on the serial writer -> upload -> reader path
      that already costs ~1.4 fps (item 74). Only an upload that need not wait for writer parts (bytes the CPU
      changed, not whole pages) could overlap; that needs the old bytes (a snapshot per written page) and care with
      GPU writes landing in the same pages.
77. Upper-bound attempt: the Shared heap in VRAM (runs 401-404). NVMTL_SHM_HEAPS=1 (experiment, off by
    default) makes shmirror adopt app Shared heaps of 16 MB or more (nvmtl_vk_heap_adopt, called from
    newHeapWithDescriptor only - the first version hooked nvmtl_vk_heap_create, which the plugin's own 32 MB pool blocks
    also use, adopted a shm pool block twice and crashed cohprobe in nvk_FreeMemory). Placed buffers inherit heap->shm.
    NVMTL_SHM_DIAG_NOGWAIT=1 (diagnostic) lets upload batches skip the wait for writer parts.
    - Both runs with the heap adopted died early in the benchmark: GPU MMU fault, a compute shader dereferencing
      0x7e7e7e7e7e7e7ec6 (run 404, with the normal waits; run 402 with NOGWAIT faulted at VA 0). So the GPU read a pointer
      out of heap memory whose VRAM copy did not hold what the app last put there - most likely data the GPU itself
      writes into the heap by a path shmirror does not track (textures placed in the heap - the log shows heap texture
      placement ON - or image stores; instrumented stores cover PSB stores only), which a later whole-page upload of a
      CPU-written page then overwrote. The same-content GPU comparison could not be made.
    - Heap adoption therefore needs, before any measurement: knowing which heap ranges hold textures or are written
      by the GPU in ways the copy-back does not see, and keeping those out (or tracking them).
78. Tracking the Shared heap under shmirror (runs 405-412; NVMTL_SHM_HEAPS=1 still faults).
    - REAL BUG FIXED (NVK, nvkmd_nvrm_mem.c): nvkmd_nvrm_mem_twin allocated the VRAM copy with the backend's
      nvkmd_nvrm_alloc_mem, which does not put it on dev->mems; freeing twinned memory then ran list_del on an unlinked
      node (SIGSEGV at 0x8 in nvkmd_mem_unref, cohprobe with an adopted heap). Now nvkmd_dev_alloc_mem. Every adopted
      allocation had this on free; buffers mostly get parked and reused, heaps are freed. NVK rebuilt arm64 + x86_64.
    - New probe test T13 heap ring (cohprobe): T4's ring and results in a 32 MB Shared heap. Passes on the M1 Pro and on
      the 3070 with and without heap adoption; all 13 tests pass shmirror off/on.
    - Diagnostics added (all env-gated, off by default): NVMTL_SHM_AUDIT_MS (periodic audit), the audit names the heap
      placement covering a differing page (nvmtl_shm_note_place registry); NVMTL_SHM_VERIFY_MS (a clean page whose bytes
      changed with no write fault: VRAM compared to tell a copied-back GPU write from a lost CPU write); NVMTL_SHM_SNAP
      (bytes as uploaded kept; any chunk where VRAM differs while the system pages still hold the uploaded bytes is a
      GPU write never copied back); NVMTL_SHM_TEXALL (copy back every writable texture made on adopted memory after
      every part); NVMTL_HEAPWATCH (item 76); dispatch fault localisation as in item 37.
    - Findings in Cyberpunk with the heap adopted: no texture is placed in the Shared heap, no writable texture is made
      on adopted memory, no clean page ever changes without a fault, no GPU write goes uncopied, and every audit finds
      VRAM and system memory identical - yet a compute shader (e4b5c7a3, an MSC root at b2 = a 192 MB ring inside the
      heap, gpuVA 0x206d20000, -> descriptor tables in the heap) dereferences a repeated-byte pointer
      (0x7e7e..c6, 0x0909..21, 0x0202..1a, 0x0101..19, once 0) early in the benchmark. Not the async uploads
      (NVMTL_SHM_ASYNC=0 faults too), not submit-ahead timing (/tmp/nvmtl-noahead faults too), not late CPU writes
      (the late-write census counts none before the fault; the one at the fault is the app overwriting a ring slot the
      stuck GPU never reached). Still open: whatever the shader read was consistent at every idle point, so the bad
      read is transient or comes from memory outside the adopted ranges.
79. FOUND: the Shared heap's wild pointers were shmirror's write-back overflow (runs 413-425).
    - Bisection tooling: NVK export nvmtl_nvk_memory_untwin_range (one sub-range of a twinned allocation back on its
      system pages; the NVRM backend can only unmap a whole mapping, so it unmaps all and maps VRAM / system / VRAM
      pieces, 2 MB aligned) and NVMTL_SHM_HEAP_SYSMEM=off+len (plugin, also stops protecting/uploading those pages).
      With the WHOLE heap back in system memory, and even with the heap's lookup slots cleared
      (NVMTL_SHM_HEAP_DIAG=noslots) or its copy-back skipped (=nocopyback), Cyberpunk still faulted - so not the VRAM
      data, not note(), not the copy-back kernel. What was left: placed buffers inherit shm, so plugin-recorded writes
      into the heap (blits) go on the part's explicit write-back list - which held 32 ranges and on overflow copied
      every adopted range back WHOLE. With the heap adopted parts overflowed (2 in run 423, 1 in 415, 0 without the
      heap): 224 MB of VRAM bytes went over the system pages, undoing the argument and descriptor data the CPU had
      written since its last upload. Audits saw nothing because both copies then agreed.
    - Fix (nvmtl_shm.c): the list grows (per-part heap array, freed in the epilogue or at retire) and merges
      contiguous ranges; only an allocation failure falls back to the whole-range copy (logged). Also kept from this
      chase: 4-byte copy-back granularity (store_note.rs, shm_copyback.comp: a GPU write no longer copies back the
      CPU's bytes in the same 16-byte block) and the twin VRAM registration fix of item 78.
    - Result, heap adopted (NVMTL_SHMIRROR=1 NVMTL_SHM_HEAPS=1): run 425 32.33 fps (cp-bench), game summary 31.88
      average, min 24.3 - best so far (29.4-29.8 before). passtime at the same content (run 424 vs 403, ptmatch):
      GPU work -14.0 ms a frame (render -10.5, compute -3.1, blit -0.4; 3f34d820 210 -> 116 us x 18 a frame).
      GPU busy now 23.8 ms a frame; idle 12.1 ms: 7.4 "queued" (waiting for upload batches - writer -> upload ->
      reader in series) and 2.8 scheduler.
    - Not yet checked: rendering correctness in heap mode (audit run, screenshots), Steel Nomad and other games.
80. Correctness of shmirror with the heap adopted (runs 426-428, Steel Nomad heapon/heapoff/shmoff).
    - Cyberpunk run 426 with every check on (NVMTL_SHM_AUDIT_MS=2000, NVMTL_SHM_SNAP=1, NVMTL_SHM_VERIFY_MS=2000):
      50 audits, 0 clean pages differ, 0 untracked GPU-written chunks, 0 lost CPU writes (only copied-back GPU writes,
      VRAM agreeing); the benchmark ran through (29.81 fps with all of that on).
    - Screenshots (tools/arm64-probes/cp-shotrun.sh: 12 consecutive presented frames 20 s into the benchmark;
      out/shot2png.py): heap adopted (run 427, 32.63 fps) and not (run 428, 27.32) show the same scene drawn the same
      way (lights, signs, characters, fog; out/shots/427, 428). Frame-to-frame change is smooth in both (mean |diff|
      3.1-3.4 vs 3.6-4.1, no spikes): no flicker.
    - Steel Nomad has no MTLHeap (no newHeapWithDescriptor), so the heap mode does not touch it: 12.96 fps heap on,
      12.95 shmirror without heaps, 12.19 shmirror off. No regression; shmirror itself +6 %.
    - cohprobe 13/13 (T13 heap ring included) with shmirror off, on, and on with heaps.
81. shmirror ON by default for native Apple Silicon apps. nvmtl_shm_on(): NVMTL_SHMIRROR=1/0 forces it;
    unset, it is on in the arm64 slice unless the process is translated (sysctl.proc_translated), WindowServer, or an
    Apple system binary (/System, /usr, /bin, /sbin, /Library/Apple); off in x86_64 processes (Rosetta, CrossOver/Wine,
    Intel Macs) until those are tested. NVMTL_SHM_HEAPS now defaults on with it (=0 leaves heaps in system memory).
    - Fault-handler guard (NVMTLObjects.m nvmtl_shw_reclaim): before submissions, at most every 100 ms, a SIGBUS/SIGSEGV
      handler the app installed over ours is put back behind ours (we chain to it); a fault that comes round again
      (their handler chaining back to ours) goes to what was installed before our first handler.
    - cohprobe with no environment: shmirror on by default, heaps on, 13/13; NVMTL_SHMIRROR=0: 13/13.
    - tools/arm64-probes/nvrun.sh: the timeout subshell's output is detached, so $(nvrun.sh ...) returns when the probe
      exits instead of waiting out the timer.
82. Cutting the upload wait, attempt 1: changed-word uploads without the writer wait (runs 429-433).
    - Measured first (run 429, NVMTL_SHM_SNAP diff census): a re-uploaded page has 30-50 % of its bytes changed
      (80 % early), 1.4-1.8 runs a page (gaps > 256 B split); 11-17 MB a frame go up as whole pages, 3-7 MB changed.
    - Built (NVMTL_SHM_DIFF): a per-page "GPU wrote this" mark (host-visible array; the copy-back kernel sets it before
      copying a word back, plugin writes set it when recorded; made lazily in the prologue, because adoption runs inside a
      buffer creation that holds the allocator lock - creating it there deadlocked cohprobe), a per-range snapshot of
      the VRAM bytes, and two copy-queue batches: pages the GPU never wrote go up as changed 4-byte words with no wait
      for writer parts (safe against a writer's first write into the page: only CPU-changed words are written), the rest
      whole after the writers. cohprobe 13/13 (default, DIFF=0, shmirror off).
    - RESULT: 12.8 fps (runs 431/432) against 32: GPU idle 58.6 ms a frame "queued". ~700 pages a frame as ~1100
      changed-word runs = ~1100 small copy-engine copies a frame, each ~50 us (launch + Thunderbolt latency); whole
      pages merge into a few large copies. NVMTL_SHM_DIFF is now OFF by default (=1 opts in); with it off the path
      is the old one (the upload command-buffer ring also grew 8 -> 32): run 433 33.19 fps, game summary 32.78 / min
      24.2 (best so far).
    - Lessons: the copy engine needs few large copies; NVIDIA channels on other queues time-slice rather than run in
      parallel with graphics, so the only engine that truly overlaps rendering is the copy engine. Next idea: a
      compute scatter of the changed words inside the reading part (graphics queue, in order, no writer wait, one
      dispatch, GPU busy instead of idle) - or coalescing changed runs into page spans with the race handled.
83. Uploads by compute scatter in the part's prologue - ON by default (runs 434-438, Steel Nomad
    "scatter"; NVMTL_SHM_SCATTER=0 returns to copy-engine uploads).
    - plugin/shm_scatter.comp: one workgroup per list entry {u64 src (system pages' GPU VA), u64 dst (VRAM copy),
      u32 words}; the list is a 16 MB host-visible ring (g_shm_list, 32-byte entries). The prologue (graphics queue,
      ahead of the part, after every earlier part and its copy-back) records barrier + dispatch(es); the prologue's
      closing barrier now covers compute writes. No copy queue, no writer wait, no U wait. Pages the GPU never wrote
      (per-page marks of item 82) and already snapshotted send only the changed 4-byte runs (merged across gaps of
      16 words), the rest whole pages - in order, a whole page is exact here.
    - cohprobe 13/13 (scatter on and off). Cyberpunk: game summary 35.56 and 35.24 average (min 25.0 / 24.3) against
      32.78 with copy-engine uploads (run 433); timeline run 435: GPU busy 21.6 ms a frame, idle 8.6 (4.7 "queued" -
      mostly the scatter itself, in the untimed prologue - 2.3 small gaps, 1.6 scheduler). Audits during the benchmark
      (tools/arm64-probes/cp-auditrun.sh triggers them only once the benchmark runs: audits during loading stall the
      main thread into the engine watchdog, runs 434 and 437): 30 audits, 0 differences, 0 untracked GPU writes,
      0 lost CPU writes; 12 consecutive frames correct and smooth (out/shots/438). Steel Nomad 13.02 fps (12.96 before).
    - Against the M1 Pro at 1280x800: its frame is 18.6 ms (53.8 fps); the 3070's GPU work is now 21.6 ms of a 28 ms
      frame (was 29-32 ms of work before the heap moved to VRAM).
84. M1 Pro against the 3070, same GPU-timeline method. tools/arm64-probes/mtltime.m (libmtltime.dylib,
    inserted into the game on the Apple GPU: hooks AGXG13XFamilyCommandBuffer commit / presentDrawable:, records each
    command buffer's GPUStartTime/GPUEndTime in an 8 s window opened like cp-ptrun.sh's), tools/arm64-probes/cp-m1run.sh,
    out/gputl.py (per-frame GPU busy = union of command-buffer intervals, idle = the rest), out/setres.py.
    - 1280x800, same benchmark window: M1 Pro 45.7 fps in the window (54.38 game summary), GPU busy 21.8 ms and idle
      0.06 ms a frame (48 command buffers a frame, heavily overlapped). 3070 (run 435): 33.1 fps in the window, GPU busy
      21.6 ms, idle 8.6 ms. The GPU WORK per frame is now the same as the M1 Pro's; the whole gap is the 3070's idle time.
    - 2560x1600: M1 Pro 14.5 fps in the window (18.09 game summary), busy 68.9 ms, idle 0.3 ms a frame.
      3070 (run 439, current defaults): 3.12 fps game summary - a REGRESSION (16.0 with the build of item 60). VRAM ran
      out: the game uses ~6.8 GB at this resolution, shmirror's twins took 512+ MB early, and the soft gate then sent
      Private buffers, a placement heap and textures to system memory (20 refusals, "REFUSED VRAM (our soft gate)").
      shmirror must yield VRAM to Private resources (adopt only with headroom; evict twins under pressure).
85. shmirror gives VRAM back under pressure (runs 440-443). Fixes the 2560x1600 regression of item 84.
    - Adoption needs headroom: a range is twinned only while free VRAM stays above its size + NVMTL_VRAM_HEADROOM + 1 GB,
      and never again once anything was given back.
    - Eviction (shm_evict): when the VRAM gate (nvmtl_vk_vram_wall) would refuse an app resource, the largest twins are
      given back first: GPU idle, then NVK nvmtl_nvk_memory_untwin rebinds the GPU address to the system pages and frees
      the VRAM copy. Protection, table entries, bitmaps and touched marks of the range go; the app keeps its memory.
    - Run 440 crashed (MMU fault at 0x2245ee000, inside the first evicted range's SHADOW address). Two windows let a
      freed shadow still be used: an eviction inside a prologue (the lazily created touched buffer goes through the
      gate) whose uploads still went through the shadow, and a part whose epilogue had recorded write-backs to the
      shadow before submit_begin took the submit mutex. Fixes: untwin keeps the shadow VA mapped to the system pages
      until the memory is freed (stale copies become copies of the pages onto themselves; no re-twin while it exists);
      an eviction asked for inside a prologue is deferred to the 500 ms timer; the epilogue re-checks every recorded
      write-back against the live ranges.
    - Run 441: a timer watch that evicted whenever free VRAM fell under headroom + 768 MB fired at 1280x800 too
      (29.69 fps, the gain lost). Removed: only an actual gate refusal evicts.
    - cohprobe 12 rounds x 2 with NVMTL_SHM_EVICT_AFTER_S=1 (every twin given back after 1 s): no FAIL, 14 evictions.
    - Cyberpunk 2560x1600 (run 442): 16.29 fps game summary (min 13.45), was 3.12; 2 evictions (224 + 128 MB), 0 gate
      refusals. M1 Pro: 18.09. 1280x800 (run 443): 35.35 (min 24.59), no eviction.
86. Automatic Private heaps backed on demand - ON by default (runs 444-447). NVMTL_HEAP_LAZY=0 restores
    whole-heap backing.
    - Run 444 (census added to "heap alias" lines; the backed-heap totals now also drop destroyed heaps): at 2560x1600
      the live Private heaps total ~6000 MB (one automatic heap of 5456 MB), but first-fit placement never goes past
      2901-2933 MB of them. Backed whole at creation, ~3 GB of VRAM was held and never used; the card ran full (budget
      7460, used 7369 MB) and shmirror had to give its twins back (item 85).
    - nvmtl_vk_heap_create_lazy: an automatic Private heap of >= 256 MB gets no memory at creation. heap_resolve backs
      [off, off+len) when a buffer / image / depth image is first placed there: one 64 MB VkDeviceMemory per chunk
      (through the VRAM gate; system memory if refused), one memory for all chunks of a resource bigger than a chunk.
      Placed resources bind to (chunk memory, offset - chunk base). The free list never places a resource across a
      chunk boundary (bigger ones start a chunk); a resource across chunks backed apart takes the legacy path. Chunks
      stay until the heap is destroyed. Placement heaps (the app picks offsets) and Shared heaps are unchanged.
    - Cyberpunk 2560x1600 (run 445): 19.56 fps game summary (min 16.48), was 16.29 - the M1 Pro does 18.09. 32+ chunks
      (2 GB) backed of 5456 MB; used 4359 MB of 6825 budget; no twin given back, no refusal, 0 chunks in system memory,
      0 legacy fallbacks. 1280x800 (run 446): 36.40 (35.35 before, within run noise), used 3511 MB.
    - Correctness: cohprobe 3 rounds PASS; 12 consecutive frames at 1280x800 (out/shots/447) drawn correctly.
87. Where the 3070's GPU work goes now (1280x800, runs 448-451; out/ptseg.py new).
    - Run 448 (segments, current defaults; the capture window ran ~29 fps, so per-frame = printed x 0.69): segments
      ~21 ms a frame (= the 21.6 ms GPU busy of item 84; the capture costs little): render 12.7, compute 7.1, blit 1.4,
      copy-back 0.15 ms. ~94 segments a frame under 50 us (3.0 ms), ~56 at 50-100 us (3.9 ms). Heaviest: fragment
      shader 3f34d820 (1280x800 B10G11R11, ~19 passes a frame, 124 us each, 2.4 ms); compute encoders of 12/18 dispatches
      ~1.2 ms each; 20x38 micro passes 42-46 us (a trivial pass is 16 us, item 64).
    - Run 449 (per-draw): the draws' heap buffers are counted "system memory" by memory type but are twinned: 2 and 3
      such buffers now give the same 3.1 us median (item 75: 3.1 vs 6.1 us). The game's data is no longer read across
      Thunderbolt.
    - Run 450, NVMTL_CEIL_NOBAR=1 (new ceiling switch: nvmtl_vk_cmd_barrier / _c2c do nothing; WRONG ordering - the
      channel faulted after 16 s): 36.44 fps over those 16 s against ~35. Encoder barriers cost at most ~1 ms a frame.
    - Run 451, NVMTL_TABLES_BAR=1 (address tables and setBytes ring in VRAM through BAR1), out/ptmatch.py against 448:
      GPU work -1.64 ms a frame at the same content (render -0.90, compute -0.72; 3f34d820 124 -> 100 us). But 29.29
      fps: the CPU's uncached BAR1 stores cost more (as in runs 266-268). A VRAM twin of the tables filled by uploads
      (shmirror-style) would keep the GPU gain without the CPU cost.
    - So ~18 ms of the 21 ms is the shaders' own work. Whether it runs as fast as it should needs per-pass timing on
      the M1 Pro (counter sample buffers at stage boundaries) or a look at the generated code of the heaviest passes.
88. Address tables in VRAM by upload - a loss, OFF (runs 452/453). NVMTL_TABLES_TWIN=1 (experiment): each
    address page (256 tables of 1536 bytes: 32 buffer addresses, 32 self-addresses, 128 texture sizes) gets a VRAM
    copy; descriptors and self-addresses name it; nvmtl_tables_upload copies the tables a part wrote in its prologue
    (one copy per page, before the prologue's closing barrier).
    - Correct: cohprobe 40/40; 12 frames of run 452 drawn right.
    - Slower: game summary 34.42 (on) vs 36.01 fps (off). Cyberpunk writes ~160 tables a part (240 KB, ~10 MB a frame)
      - whole tables cross Thunderbolt, while shaders reading them in place touch a few lines each. The GPU-side gain of
      item 87 (1.64 ms) needs tables that are small: a layout sized to what each pipeline reads (translator + plugin), or
      no tables for pipelines whose bindings fit descriptors directly.
89. Address tables in BAR1 with diff writes - a loss, OFF (runs 454, 458-460; the eGPU dropped after 454).
    NVMTL_TABLES_DIFF=1 (experiment, acts only when NVMTL_TABLES_BAR=1/2 puts tables in BAR1): each BAR1 page keeps a
    cached shadow (zeroed with the page at creation) and a table stores only the words that differ - 7.4 (cohprobe) to
    19-30 (Cyberpunk) of 192. cohprobe 40/40, frames right.
    - Run 454 (NVMTL_TABLES_BAR=1): 21.64 fps, CPU-bound (GPU busy 20-40 %), and falling to ~10 fps in the last minute.
      Right after it the card was gone (no NVIDIA PCI device, NVRM ioctls -> 0x10000003, isr count frozen; runs 455-457
      could not start). Whether the falling rate was the diff writes or the link already failing is not known; heavy
      uncached BAR1 stores over the JHL7540 link are a suspect for the drop. The default (tables in system memory, only
      the setBytes ring in BAR1) is unchanged.
    - After a restart, one session, back to back (runs 458-460; the card stayed up through all three): default 35.83
      fps (GPU busy 60 %), tables in BAR1 with whole-table writes 28.43 (44 %), with diff writes 21.60 (34 %) - the
      diff run reproduces 454, so its rate was not the link failing. Fewer but scattered stores are slower than whole
      tables: BAR1 writes appear to be combined into bursts when consecutive. Every way of getting the tables into VRAM
      tried so far (copy-engine upload, item 88; BAR1 whole or diff) loses to leaving them in system memory.
90. Pass by pass, M1 Pro against the 3070 (M1 runs 461/462, 3070 run 448; 1280x800).
    - tools/arm64-probes/mtltime.m MTLTIME_ENC=1 (build: tools/arm64-probes/mkmtltime.sh, which regenerates mtlfmt.inc,
      the plugin's Metal -> VkFormat mapping): encoders made in the window get counter samples at stage boundaries
      (render: vertex and fragment start/end; compute / blit: encoder start/end) from one shared ring of 4096 samples
      (Metal refuses more than a few sample buffers per process: run 461 timed only a quarter of the encoders), and are
      keyed as passtime keys them: render = size + colour 0's VkFormat (1000 + depth's), compute / blit = op count.
      Timestamps are nanoseconds on the GPUStartTime clock. out/m1cmp.py puts both side by side per frame.
    - The same passes on both: 139.6 / 133 render, 29.6 / 27.3 compute, 25.1 / 24.6 blit encoders a frame (M1 / 3070).
      The plugin does not split passes beyond what the game asks for.
    - Work per frame: M1 render 21.50 ms of stage time, compute 11.05, blit 0.57 = 33.1 ms - done in 21.8 ms of GPU
      wall time (item 84): Apple's GPU overlaps encoders (vertex of one with fragment of another, compute with render).
      3070: render 12.66, compute 7.07, blit 1.38 = 21.1 ms, one after another, plus 8.6 ms idle.
    - Per class the 3070 is faster on everything heavy: the G-buffer (1280x800 fmt 58) 496 vs 1030 us, compute encoders
      0.3-0.9x of the M1's time, the 58 light full-screen passes (fmt 122) 97 vs 124 us. Slower only on small work:
      blit encoders 1.38 vs 0.57 ms (one-op 45 vs 19 us; 107/108-op encoders 274-320 vs 22-38 us: ~3 us an op),
      micro passes (20x38 area of a 64x64 target) 43 vs 28 us.
    - So the GPU work is not slow: the 3070 does in 21 ms what takes the M1 33 ms of stage time. The M1 wins the frame
      by overlap (33 -> 21.8 ms) and by never idling; the 3070 runs serially and idles 8.6 ms. Levers, largest first:
      the idle (scatter uploads in the prologue 4.7 ms, small gaps 2.3, scheduler 1.6, item 83), overlap of
      independent work (compute next to render: a second queue / channel; encoder barriers alone were worth <= 1 ms,
      item 87), and multi-op blit encoders (~0.8 ms).
91. Cutting the 3070's idle time (1280x800, runs 463-472).
    - Run 463 (rec timeline): 30 fps in the window, GPU busy 21.6 ms, idle 11.8 ms a frame = scheduler 4.73 (3.21 of it
      "in-flight cap": 16 parts in flight, but the worker retires a part ~7 ms after the GPU finished it), queued 4.13,
      small gaps 2.80.
    - In-flight cap 16 -> 32 (NVMTL_GSUB_INFLIGHT, default now 32, its maximum): scheduler idle 4.73 -> 0.28 ms a frame,
      32.8 fps in the window (run 464).
    - Passtime rec lines now carry pre_us / pre_lead: the part's prologue timed in its own timing pool (queries 2-3,
      read only when this submission recorded them - the pools are reused). Run 466: prologues 4.72 ms a frame of GPU
      time = the "queued" idle: the scatter reading 3.5-6 MB a frame across Thunderbolt (~1 GB/s).
    - NVMTL_SHM_STAGE=1 (experiment, OFF): runs of pages the GPU never wrote go host ring -> one copy-engine copy on the
      copy queue -> VRAM ring -> scatter; semaphore C (signalled by the consuming part) guards ring chunks (checked when
      the ring enters a chunk - checking the chunk it is already in waited on in-flight parts: run 467, 20 ms a frame of
      prologue). Run 468: prologue GPU time 4.7 -> 1.4 ms a frame, but the parts ran 2.6 ms longer (busy 22.5 -> 25.1)
      beside the copy engine's transfer - no fps change (198 vs 197 frames in the window).
    - Blit encoders: the batching cap 16 -> 128 ranges (NVMTL_BL_MAX; barriers now counted by reason: a run's start,
      the cap, an overlap), and NVMTL_BLIT_SCATTER (default on, with shmirror's scatter kernel): a run's small aligned
      copies (<= 64 KB) go out as one dispatch when the run ends, a workgroup per copy, instead of a copy launch each
      (~3 us). Run 470: blit time 1.38 -> 0.93 ms a frame, 55.9 -> 40.7 us an encoder; 97 % of copies in dispatches.
      Without shmirror (Rosetta, CrossOver) the copies go as before.
    - Together (runs 471/472, new vs old defaults): game summary 36.23 vs 35.69 (fps log 35.68 vs 35.25); frames of
      run 471 correct; cohprobe 40/40. The window gain (30 -> 33 fps) shows less in the whole benchmark. Steel Nomad
      (runs nb473/nb474, its window focused - unfocused it aborts with "Workload focus lost"): 12.94 vs 13.01 fps,
      the same within run-to-run noise (12.96-13.02 before).
