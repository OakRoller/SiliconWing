/*
 * NullMoth NVIDIA driver for macOS
 * Copyright (c) 2026 NullMoth Systems.
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 *
 * DMA address translation for the RM (nv_dma_map_alloc and friends).
 *
 * The RM keeps two address spaces for system memory: the CPU physical pages that nv_alloc_pages / nv_register_user_pages
 * hand back, and the addresses the GPU puts on the bus. On a PC booted by OpenCore the IOMMU is off and the two are the
 * same, which is what the driver always did (identity). An Apple Silicon Mac puts every PCIe device, Thunderbolt ones
 * included, behind a DART: the GPU can only reach what the DART maps for it, and it sees DART addresses, not CPU ones.
 * So nv_requires_dma_remap() says yes there, the RM keeps a per-GPU IOVA space (pNv->iovaspace_id), and every mapping
 * of a memdesc goes through here: an IODMACommand bound to the GPU's own mapper (IOMapper::copyMapperForDevice) maps
 * the physical pages and hands back the bus addresses, in place, in the array the RM gave us.
 *
 * The array the RM passes holds one entry per OS page (os_page_size, 16 KB on Apple Silicon), or a single entry for a
 * contiguous allocation; the RM deflates its own 4 KB page arrays to OS pages before calling (os.c, osIovaMap).
 */

#include "nv-xnu.h"
#include <IOKit/IODMACommand.h>
#include <IOKit/IOMapper.h>
#include <IOKit/IOMemoryDescriptor.h>
#include <IOKit/pci/IOPCIDevice.h>

extern "C" {
extern NvU32 nv_xnu_dma_bits;          // what the RM said the GPU can address (os-xnu2.cpp, nv_set_dma_address_size)
extern bool  nv_xnu_chat(void);
}

// nv_dma_device_t is opaque to the RM; this is what it is on XNU.
struct nv_dma_device {
    IOPCIDevice *pci;       // the function the mapping is for
    IOMapper    *mapper;    // its DART (retained), or NULL when the platform maps nothing (x86)
    bool         remap;     // nv_requires_dma_remap(): translate, or hand back the CPU address
};

static nv_dma_device gNvDmaDevice;      // one GPU per kext instance today; the RM passes nv->dma_dev back to us

extern "C" nv_dma_device_t *nv_xnu_dma_device_init(IOPCIDevice *pci)
{
    // A hot-unplugged and replugged eGPU comes back as a NEW IOPCIDevice behind a NEW DART: the mapper taken for the
    // previous function is offline, and every IODMACommand::setMemoryDescriptor on it fails with kIOReturnOffline
    // ("dma: setMemoryDescriptor(1 pages, 16 KB) -> 0xe00002d7", then kmemsysInitFlushSysmemBuffer fails and
    // RmInitAdapter bails). So the mapper is taken per device, not per kext: a different device drops the old one.
    // Live mappings of the old instance hold their own reference through their IODMACommand, so the drop is safe.
    if (gNvDmaDevice.mapper && gNvDmaDevice.pci != pci) {
        kprintf("NVRM-xnu: dma: device changed (%p -> %p) - dropping the previous mapper %s\n", gNvDmaDevice.pci, pci, gNvDmaDevice.mapper->getName());
        gNvDmaDevice.mapper->release();
        gNvDmaDevice.mapper = NULL;
    }
    gNvDmaDevice.pci = pci;
    gNvDmaDevice.remap = NV_XNU_ARM64 ? true : false;
    if (gNvDmaDevice.remap && !gNvDmaDevice.mapper) {
        gNvDmaDevice.mapper = IOMapper::copyMapperForDevice(pci);   // retained; kept while this device is the GPU
        if (gNvDmaDevice.mapper)
            kprintf("NVRM-xnu: dma: mapper %s for %s, page size %llu\n", gNvDmaDevice.mapper->getName(), pci->getName(),
                    (unsigned long long)gNvDmaDevice.mapper->getPageSize());
        else
            kprintf("NVRM-xnu: dma: NO mapper for %s - the GPU would see CPU physical addresses, which a DART does not allow\n", pci->getName());
    }
    return &gNvDmaDevice;
}

// The RM asks this once per GPU, before it knows the DMA width; the answer picks the identity or IOVA path.
NvBool NV_API_CALL nv_requires_dma_remap(nv_state_t *nv) { return gNvDmaDevice.remap ? NV_TRUE : NV_FALSE; }

struct nv_xnu_dma_map {
    IOMemoryDescriptor *md;     // the physical pages, as the RM listed them
    IODMACommand       *cmd;    // the mapping; its IOVA is live until clearMemoryDescriptor
    NvU64               pages;  // OS pages
    bool                contig;
};

// Physical pages -> bus addresses, written back into va_array (one per OS page, or va_array[0] when contiguous).
NV_STATUS NV_API_CALL nv_dma_map_alloc(nv_dma_device_t *dev, NvU64 page_count, NvU64 *va_array, NvBool contig, NvBool read_only, void **priv)
{
    if (!va_array || !page_count || !priv) return NV_ERR_INVALID_ARGUMENT;
    if (!dev || !dev->remap || !dev->mapper) {
        // Identity: the GPU reaches CPU physical memory directly (no IOMMU in the way). What the driver shipped with.
        if (nv_xnu_chat()) kprintf("NVRM-xnu: >nv_dma_map_alloc pages=%llu contig=%u first=0x%llx (identity)\n", page_count, contig, va_array[0]);
        *priv = NULL; return NV_OK;
    }
    const NvU64 n = contig ? 1 : page_count;
    const NvU64 bytes = page_count * PAGE_SIZE;
    IOAddressRange *ranges = (IOAddressRange *)IOMallocData(sizeof(IOAddressRange) * n);
    if (!ranges) return NV_ERR_NO_MEMORY;
    for (NvU64 i = 0; i < n; i++) {
        if (va_array[i] & PAGE_MASK) { kprintf("NVRM-xnu: dma: page %llu phys 0x%llx is not page aligned\n", i, va_array[i]); IOFreeData(ranges, sizeof(IOAddressRange) * n); return NV_ERR_INVALID_ADDRESS; }
        ranges[i].address = va_array[i]; ranges[i].length = contig ? bytes : PAGE_SIZE;
    }
    // task NULL: the ranges are physical addresses. The RM's pages are pinned already (our IOBufferMemoryDescriptor or
    // the prepared user mapping), so this descriptor only names them.
    IOMemoryDescriptor *md = IOMemoryDescriptor::withAddressRanges(ranges, (UInt32)n, read_only ? kIODirectionOut : kIODirectionInOut, NULL);
    IOFreeData(ranges, sizeof(IOAddressRange) * n);
    if (!md) { kprintf("NVRM-xnu: dma: withAddressRanges(%llu pages) FAILED\n", page_count); return NV_ERR_NO_MEMORY; }
    const UInt8 bits = (nv_xnu_dma_bits >= 32 && nv_xnu_dma_bits <= 64) ? (UInt8)nv_xnu_dma_bits : 64;
    IODMACommand *cmd = IODMACommand::withSpecification(kIODMACommandOutputHost64, bits, 0, IODMACommand::kMapped, 0, PAGE_SIZE, dev->mapper);
    if (!cmd) { md->release(); kprintf("NVRM-xnu: dma: IODMACommand::withSpecification(%u bits) FAILED\n", bits); return NV_ERR_NO_MEMORY; }
    IOReturn r = cmd->setMemoryDescriptor(md, true);   // prepare: this is where the DART mapping is made
    if (r != kIOReturnSuccess) {
        kprintf("NVRM-xnu: dma: setMemoryDescriptor(%llu pages, %llu KB) -> 0x%x\n", page_count, bytes >> 10, r);
        cmd->release(); md->release(); return r == kIOReturnNoResources ? NV_ERR_INSUFFICIENT_RESOURCES : NV_ERR_GENERIC;
    }
    // Walk the bus-address segments and write one address per OS page (or the single base for contiguous memory).
    UInt64 off = 0; NvU64 filled = 0; bool ok = true;
    while (off < bytes && ok) {
        IODMACommand::Segment64 seg[32]; UInt32 ns = 32;
        r = cmd->gen64IOVMSegments(&off, seg, &ns);
        if (r != kIOReturnSuccess || ns == 0) { kprintf("NVRM-xnu: dma: gen64IOVMSegments at 0x%llx -> 0x%x (%u segs)\n", off, r, ns); ok = false; break; }
        for (UInt32 s = 0; s < ns && ok; s++) {
            if (contig) {
                if (filled == 0) { va_array[0] = seg[s].fIOVMAddr; filled = 1; }   // continuity is checked below
            } else {
                for (UInt64 p = 0; p < seg[s].fLength && filled < page_count; p += PAGE_SIZE) va_array[filled++] = seg[s].fIOVMAddr + p;
            }
        }
    }
    if (ok && !contig && filled != page_count) { kprintf("NVRM-xnu: dma: mapped %llu of %llu pages\n", filled, page_count); ok = false; }
    if (ok && contig) {
        // A contiguous allocation must come back as one bus range: the RM only keeps va_array[0]. Check by re-walking.
        UInt64 o2 = 0; IODMACommand::Segment64 s1; UInt32 n1 = 1; NvU64 expect = va_array[0];
        while (o2 < bytes) {
            n1 = 1; if (cmd->gen64IOVMSegments(&o2, &s1, &n1) != kIOReturnSuccess || n1 != 1 || s1.fIOVMAddr != expect) { ok = false; break; }
            expect += s1.fLength;
        }
        if (!ok) kprintf("NVRM-xnu: dma: contiguous allocation of %llu KB did not map to one bus range\n", bytes >> 10);
    }
    if (!ok) { cmd->clearMemoryDescriptor(); cmd->release(); md->release(); return NV_ERR_GENERIC; }
    nv_xnu_dma_map *m = (nv_xnu_dma_map *)IOMallocZero(sizeof *m);
    if (!m) { cmd->clearMemoryDescriptor(); cmd->release(); md->release(); return NV_ERR_NO_MEMORY; }
    m->md = md; m->cmd = cmd; m->pages = page_count; m->contig = contig;
    *priv = m;
    if (nv_xnu_chat()) kprintf("NVRM-xnu: >nv_dma_map_alloc pages=%llu contig=%u -> iova 0x%llx (%u-bit)\n", page_count, contig, va_array[0], bits);
    return NV_OK;
}

NV_STATUS NV_API_CALL nv_dma_unmap_alloc(nv_dma_device_t *dev, NvU64 page_count, NvU64 *va_array, void **priv)
{
    if (!priv || !*priv) return NV_OK;   // identity mappings carry no state
    nv_xnu_dma_map *m = (nv_xnu_dma_map *)*priv;
    if (m->cmd) { m->cmd->clearMemoryDescriptor(); m->cmd->release(); }
    if (m->md) m->md->release();
    IOFree(m, sizeof *m);
    *priv = NULL;
    return NV_OK;
}

// Peer and MMIO mappings (another GPU's BAR seen through this GPU's IOMMU): one eGPU, no peers. Not supported, as the
// weak stubs said before; spelled out here so the RM gets a clean status.
NV_STATUS NV_API_CALL nv_dma_map_mmio(nv_dma_device_t *dev, NvU64 page_count, NvU64 *va)        { return NV_ERR_NOT_SUPPORTED; }
void      NV_API_CALL nv_dma_unmap_mmio(nv_dma_device_t *dev, NvU64 page_count, NvU64 va)        { }
NV_STATUS NV_API_CALL nv_dma_map_peer(nv_dma_device_t *dev, nv_dma_device_t *peer, NvU8 bar, NvU64 page_count, NvU64 *va) { return NV_ERR_NOT_SUPPORTED; }
void      NV_API_CALL nv_dma_unmap_peer(nv_dma_device_t *dev, NvU64 page_count, NvU64 va)        { }
