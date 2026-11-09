# Progress note: Cyberpunk renders black after the panics stop

Written from a side session so that it does not collide with `ARM64-PORT-NOTES.md` (items up to 21) or the
memory file, both of which stop at "Relaxed Ordering off, attribution tooling ready" (NVRM 0.308.751 on the Desktop).
Fold this into NOTES item 22 when the main investigation closes.

## 1. Where the port stands

- NVRM 0.308.751 installed (No-Snoop + Relaxed Ordering cleared, `devCtlWatch` every 5 s, firmware wait 300 s).
  No AMCC panic since; `nvrmctl devctl` stays `0x210f`, re-cleared 0 times. The three earlier panics all fell inside
  Cyberpunk's pipeline-creation phase.
- Cyberpunk 2077 (Steam, Metal Shader Converter build) reaches its main menu on the RTX 3070 at ~68 fps, 27 submits
  per frame. argsim and texsim pass. The picture is black apart from a few garbage pixels.
- Runs 12–30 of `tools/arm64-probes/cp-run.sh N [trace]`; logs in `~/Library/Logs/nvmtl/cp-nvmtl{N}.log`,
  `cp-stdout{N}.txt`; `ring/allocs/devctl-13.txt` from `cp-watch.sh` (root) still running in a Terminal tab.
  Runs 22, 25, 26, 27 died (engine watchdog with the shader cache cleared; three SIGKILL/SIGSEGV PAC faults in game
  threads while the trace peek was on — cause not found, the LATE re-read was removed again).

## 2. Diagnostic tooling added (all in the working tree, none committed)

- **Per-pass dump** (`NVMTLRenderCommandEncoder nvmtlPassDump`, NVMTLObjects.m): `touch /tmp/nvmtl-passdump-request`
  arms the next 96 drawing passes; each writes a record line to `/tmp/nvmtl-passdump-<pid>.txt` (pass size, ncol,
  load bits, draw count, colour-0 and depth format, depth-stencil state, viewport, scissor, cull) and reads back every
  colour attachment plus depth (D32F, X8_D24, D24S8, D32S8) after its command buffer completes, to
  `/tmp/nvmtl-pass-<pid>-<seq>{cN|ds0}-<w>x<h>-fmt<VkFormat>-bpp<b>.raw`. `tools/arm64-probes/passdump2png.py <out>`
  renders them and prints non-black percentage and mean per attachment. Draw counter `_passDraws` added to the
  encoder; `NVMTL_DEPTH_ALWAYS=1` forces the depth compare to Always (bisection knob).
- **texsim** (`tools/arm64-probes/texsim.m`, built to `out/rendersim/texsim`): 27 groups of texture paths sampled
  through resource IDs — managed/replaceRegion, private blit, automatic and placement heaps, aliased placement, BC1,
  mip chains and lodMinClamp, sRGB views, texture2d<half>, dynamic `r[idx]`, locals, constant-space tables, private
  tables, arrays, cubes, anisotropy, 1-layer 2D arrays sampled as texture2d_array, BC1_sRGB array in a heap, ~1000
  heap slots, 4-/5-argument views incl. level ranges and swizzles, tables bound at 33 MB offsets, offset-only rebinds,
  CPU overwrites after a GPU read. Everything passes except 16/16b/16c/23/24: a texture reached through a pointer
  stored in a buffer (device or constant address space, Metal Shader Converter's descriptor-table shape) — the
  translator emits `OpConstantNull` for the sample (`METAL2VULKAN_UNMODELED_WHY=1` reports
  `raw_buffer_offset_load_placeholder` / `define_unmodeled_byte_pointer` on the entry GEP). Plain data through the
  same pointers (19a–c) works via PhysicalStorageBuffer loads.
- **Trace peek** (`/tmp/nvmtl-trace-peek` with the trace on): for every fragment buffer bound, each 8-byte word of
  the first 256 bytes that looks like a GPU address is resolved through a new weak registry of all `NVMTLBuffer`s
  (`+alloc` hook) to the buffer it points into, the first three `IRDescriptorTableEntry`s there are decoded
  (gpuVA / textureViewID / metadata, heap slot, "issued" against `nvmtl_vk_bindless_next()`), the region after the
  pointer is scanned (up to 1 MB) and the first heap-tagged IDs are resolved back to their texture objects
  (`nvmtl_resid_resource()` exported from NVMTLEmbedded.m). The first 24 `newTextureView…levels:slices:` calls are
  logged. Note: `find /tmp` without a trailing slash does not descend the symlink; use `/private/tmp`.
- **Patched game shaders**: the 22 cached fragment SPIR-V files with ≥15 samples in `~/Library/Caches/nvmtl/spvcache`
  are currently PATCHED (backups in `/tmp/claude-501/spvbak/`) to write the low 30 bits of the first descriptor-table
  pointer they read into colour 0 instead of their result. Restore the backups before judging any picture.

## 3. What the evidence says

- Frame structure at the menu (33 passes): depth prepass (4 draws, reverse-Z, clear 0, GreaterEqual) → G-buffer
  853x533 with 4 MRTs (A2R10G10B10, A2R10G10B10, RGBA8, RG16F; 11 draws) → shadow maps 2048² X8_D24 → lighting,
  bloom chain, UI 1280x800 RGBA8_sRGB (4 draws) → B8G8R8A8 output.
- Depth is written over ~23 % of the screen (values 0.0003–0.007, far geometry) and the G-buffer's alpha is 1 over
  the same 52 % of pixels: rasterisation, vertex transforms and the depth test are right. c1 (normals) has content,
  c2 only blue, c0 (albedo) and everything sampled from textures is black; the UI atlas too. The 128x128 sky LUT and
  one RG8 constant pass have content (no texture input).
- The game uses Metal Shader Converter: `ps_main_/vs_main_/cs_main_`, `top_level_global_ab` in the constant address
  space, descriptor tables of 24-byte `IRDescriptorTableEntry`s, 1-layer `MTLTextureType2DArray` for every 2D
  texture (shaders declare `texture2d_array`), uploads by `copyFromBuffer:toTexture:` from a 128 MB staging buffer
  (6104 of 6129 uploads carried non-zero bytes), no MTLIO, no argument encoders, no `setFragmentTexture`.
- The translator lowers the game's chains faithfully: AB word → `OpConvertUToPtr` PhysicalStorageBuffer → load the
  low uint of `textureViewID` → `& 131071` → set-2 heap index; sampler via `& 2047`. A 23-sample G-buffer shader has
  165 PSB loads and no null in any sampling chain. AIR vs SPIR-V agree on table offsets (56/64/104/128) and indices.
- At encode time the CPU view of the bound AB holds pointers (words 0–9, 11, 13–17); the sampler table holds valid
  plugin sampler IDs; the texture table at word 13 holds 698 heap-tagged IDs (slots ~0x2da–0x301) starting at entry
  32041; the tables at words 7/8 hold nothing in their first 32 entries, at encode time and after completion.
- The patched shaders report what the GPU reads: slot 0, sampler 0, and the table pointer at AB words 14/15 reads
  as **0** — while the CPU sees `0x20360ba90`-class pointers at the same bytes. Synchronous commit
  (`NVMTL_ASYNC_COMMIT=0`) changes nothing. Offsets, set relocation (fragment set 0 → 1 at pipeline creation) and
  every isolated binding variant check out in texsim.

## 4. Open question and next steps

The one unexplained fact is the GPU reading zeros from AB bytes 56–63 that the CPU wrote. Candidates, in order:
1. GPU-side caching of system memory: NVK's `NVK69_MEM_GPU_CACHED` (`GPU_CACHEABLE_YES`) on GART allocations
   (`nvk_device_memory.c:81`) lets L2 hold stale lines across kicks; texsim 27a–d did not reproduce it with fresh
   buffers, but the game's ring is re-read every frame.
2. The AB region the GPU reads is not the region the CPU wrote (ring sub-range, promotion to a constant bank,
   per-stage set relocation on the *patched* modules).
3. Something in the parallel-encoder replay path binding a different buffer/offset than the trace reports.
Quick checks: an Xcode GPU frame capture of the same scene on the Apple GPU to confirm the AB/table layout the engine
produces; a texsim case that re-reads a ring region every frame while the CPU rewrites it; reading `tab_out/dyn_out`
for the game's draws.

Housekeeping before any screenshot or benchmark: restore the 22 shader files from `/tmp/claude-501/spvbak/`, remove
`/tmp/nvmtl-trace-request`, `/tmp/nvmtl-trace-long`, `/tmp/nvmtl-trace-peek`; `rustc` from Homebrew is broken
(LLVM symbol mismatch), so the translator CLI could not be built.

---

# Part 2, 14:30 → 15:40: the black screen was the translator; the menu now renders Night City but the UI/video is garbled

Appended from the forked session at 15:42 (the main investigation session is still the owner of the working tree;
this is a snapshot of where it stood). Supersedes §4 above: the "GPU reads zeros from the AB" theory was an artefact
of the patched-shader experiment (the patched spvcache entries were not the SPIR-V the pipelines actually used, which
lives in `~/Library/Caches/nvmtl/pstat/<fnv32>.frag.spv`). Backups were restored; `/tmp/claude-501/spvbak/` is empty.

## 5. Root cause of the black picture: dropped texture samples in Metal Shader Converter shaders

`tools/arm64-probes/xlate.c` (`out/xlate/xlate <dylib> <in.ll> <stage> <out.spv>`, loads the translator dylib,
`nvmtl_translate_set_caps(3)` then `nvmtl_translate`) run over the game's AIR text in `aircache/*.ll` showed that for
the MSC fragment shaders the emitted SPIR-V had far fewer image ops than the AIR had `@air.sample_*/read_*/gather`
calls — the native emitter hit "sampler operand is not a sampler / is a pointer" on the pointer-chain samplers, fell
into raw construction (`construct_raw`), and the raw path emitted `OpConstantNull` for every sample it could not model.
The wrapper retry `with_argument_buffer_samplers` (ARGBUF_SAMPLERS) would have handled it, but the raw-construction
arm caught the error first and returned a "successful" module.

Fix in `translator/translator/src/lib.rs`:
- `air_texture_call_count(ll)` and `module_image_op_count(module)` (counts ImageSample*/Fetch/Gather/DrefGather/Read).
- `argument_buffer_sampler_retry_handles(err)`: true when ARGBUF_SAMPLERS is off and the error is one of the three
  sampler-operand messages (incl. "runtime sampler specialization cannot recover an exact state after pointer
  selection").
- In `translate_native_no_retry_constructed_with_options` and `translate_sanitized_with_meta_prevalidated_carrier`
  a match arm `Err(e) if rc.needs_raw_construction() && argument_buffer_sampler_retry_handles(&e) => return Err(e)`
  sits before the raw-construction arm, so the error propagates to the wrapper retry instead of being swallowed.
- The raw-first shortcut now only returns the raw module when `raw_ops >= air_ops || primary.is_err()`; otherwise it
  logs and falls through to the primary result.
- Diagnostic `METAL2VULKAN_LOAD_DBG` eprintln left in `native/emitter/body/core_inst.rs` (remove or gate later).
Verified with xlate: every formerly failing game shader now keeps image ops == AIR sample calls. Build:
`cd translator/wrapper && cargo build --release --target-dir ../../out/translator` (needs the Homebrew rust upgraded
to 1.99.1; 1.84.1 was broken against llvm 23), arm64 slice lipo'd into
`out/package-arm64/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/libnvmtl_translate.dylib` (x86_64 slice is
the OLD one), `install_name_tool -id @rpath/libnvmtl_translate.dylib`, ad-hoc codesign. Old universal dylib kept at
`/tmp/claude-501/libnvmtl_translate.old.dylib`. spvcache is keyed by the dylib sha256 tag, now `de5c9f74…`: the
first game runs after a translator change retranslate ~1457 shaders and die to the EngineWatchdog ("Trace/BPT
trap" / "Killed: 9", not a kernel panic); rerun until the cache is warm. Do not run texsim with the system driver
between game runs — it sweeps the dev cache (stale-tag entries).

## 6. Result: runs 31–37

- Pass dump #067 (G-buffer) shows Night City with correct albedo, normals and lighting: textures sample. No kernel
  panic in the whole stretch; `nvrmctl devctl` still 0x210f.
- The main menu is wrong in a new way: the final B8G8R8A8 pass shows a static garbled image — two half-height tiles
  side by side with false blue/green colours — instead of the key art + video. The UI pass (16 draws into RGBA16F)
  samples: 1920x1080 BC7_sRGB key art, a 1920x1088 R8 and two 960x544 R8 textures (video Y/UV planes, blit-uploaded
  from the 192 MB ring), 1280x800 RGBA16F, 1280x800 and 640x400 RGBA8, a 2048² R8. Candidate PSOs (pstat fnv32):
  fs `0fe9769a`, `4a2d55e8`, `39a86ef7`, `71b7c632`.
- texsim case 30a: `get_width/get_height/get_array_size` on a texture that is only queried, never sampled, return 0
  through the pointer-chain path — a second translator defect, plausibly the one scaling the menu UVs (half-height
  tiles = height treated as 0/wrong). Not yet fixed.
- Run 37 TEXDUMP (trace peek, `/private/tmp/nvmtl-obj-<ptr>-WxH-fmt<vk>-bpp<b>.raw`, converted to PNG in the
  session scratchpad `obj37/`): the two 960x544 R8 planes have mean 119/137 and the 1920x1088 R8 mean 22 — i.e. real
  video content is in VRAM (not black, not uniform); the 640x400 RGBA8 is all zero, the 1280x800 RGBA16F mean 4.7.
  So the upload path is fine and the fault is in the drawing shaders / UV math, pointing back at the query-only
  lowering (30a). PNGs not yet eyeballed for orientation/tiling.

## 7. Tooling added since §2

- `tools/arm64-probes/xlate.c` → `out/xlate/xlate` (standalone translator driver; env `METAL2VULKAN_*` passes
  through).
- texsim grew to 30 groups (f_qsize = query-only, f_aread, f_heap/f_heap1, f_cptr/f_cptrd …).
- Trace peek gained OBJ/TEXDUMP: the first 12 large (w ≥ 512) textures referenced from the bound tables are read back
  synchronously to `/tmp/nvmtl-obj-*.raw` (`nvmtl_vk_image_read`). Clear them with
  `find /private/tmp -maxdepth 1 -name 'nvmtl-obj-*.raw' -delete` (an `rm -f` glob inside a long command trips the
  safety check).
- Plugin: buffer registry (`nvmtl_bufreg_add/find`), `nvmtl_resid_resource()`, `nvmtl_vk_bindless_next()`,
  `NVMTL_DEPTH_ALWAYS`, `_passDraws` — all diagnostic, all uncommitted.

## 8. Next steps (in order)

0. (16:40) Panic #11 at the menu (AMCC, ADDR in no listed allocation) → NOTES item 23: the RM's UNCACHED/WC system
   memory is now mapped Device on arm64 (NVRM 0.308.1035 in `~/Desktop/nvidia-macos-driver-arm64`, with the fixed
   translator + plugin). Install, reboot, then `nvrmctl allocs | grep -c 'cache [12]'` should be > 0.
1. Look at `obj37/*.png` (done: key art, 1920x1088 + 960x544 video planes, 1280x800 RGBA/RGBA16F are all intact in
   VRAM → the fault is in the drawing shaders / UV path, not the upload); dump the AIR+SPIR-V of fs
   `0fe9769a`/`71b7c632` (pstat + aircache) and check how the UVs are computed — expect a `get_width/get_height`
   query feeding a divide.
2. Fix the query-only lowering in the translator (texsim 30a must return the real size), rebuild, warm the cache,
   rerun Cyberpunk; expect the menu to show key art + video.
3. Enter the game / benchmark; compare with the 27.2 fps avg baseline (1800x1125).
4. Docs: gate/remove the `METAL2VULKAN_LOAD_DBG` eprintln; restore texsim 29/30 orientation.
