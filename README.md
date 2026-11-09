# SiliconWing — NVIDIA eGPUs for Apple Silicon (experimental)

[中文说明](README.zh-CN.md)

*SiliconWing is the Apple Silicon port of [NullMoth's NVIDIA driver for macOS](https://github.com/nullmoth/nvidia-macos-driver),
built on its kernel extensions, Metal plugin and shader translator — which is why the system lists its parts as
`com.nullmoth.*`.*

Get the installer package from the [Releases page](https://github.com/OakRoller/SiliconWing/releases); the steps below refer to the files inside it
(`install.sh`, `launch/`, …).

> **Plug a GeForce into your M-series Mac — and play Metal games on it.**

Apple has never supported external graphics cards on Apple Silicon. This build does: a GeForce RTX card in a
Thunderbolt enclosure renders your Mac's native Metal games, and the picture shows up on the Mac's own display. No game
patches, no recompiling — the game simply finds an NVIDIA GPU where the built-in one used to be.

- 🎮 **Runs native Apple Silicon games unmodified** — Cyberpunk 2077 and 3DMark Steel Nomad run start to finish on an RTX 3070.
- 🚀 **Beats the built-in M1 Pro GPU on heavy work** — Steel Nomad **+44 %**, Cyberpunk 2077 at 2560×1600 **+8 %**.
- ⚡ **Metal compute, not just games** — compute kernels run on the card too: in Cyberpunk its compute passes take
  0.3–0.9× the time they take on the M1 Pro, and your own Metal code can pick the card like any other GPU.
- 🧠 **Unified memory, emulated across Thunderbolt** — games written for Apple's shared CPU/GPU memory get a coherent
  mirror of it in video memory, so they never notice the card is on a cable.
- 🖥️ **Your desktop stays safe** — macOS keeps drawing on the built-in GPU; only the games you launch through it go to
  the card, one app at a time.
- 🔓 **Source available, built on open pieces** — NVIDIA's open GPU kernel modules, Mesa's NVK Vulkan driver and the
  metal2vulkan-based shader translator (LGPL). SiliconWing itself is free for noncommercial use.

## Benchmarks

Game benchmark summaries, ray tracing off, MacBook Pro M1 Pro vs the same Mac with an RTX 3070 over Thunderbolt 3:

| | M1 Pro (built-in GPU) | RTX 3070 with this build | |
|---|---|---|---|
| 3DMark Steel Nomad (demo test) | 9.0 fps | **13.0 fps** | **+44 %** |
| Cyberpunk 2077, 2560×1600 | 18.2 fps | **19.6 fps** (min 16.5) | **+8 %** |
| Cyberpunk 2077, 1280×800 | **53.8 fps** | 36.2 fps (min 24.5) | −33 % |

The honest part: every render pass and dispatch pays a fixed cost across the Thunderbolt link, so the 3070 shines when
each frame carries a lot of pixel work and trails at low resolutions, where that fixed cost dominates. The higher you
go, the better it looks.

## Metal compute

Compute is a first-class citizen: compute pipelines, compute encoders (serial and concurrent), indirect dispatch and
the CPU/GPU coherence of Shared buffers all work on the card — they carry about 30 compute passes a frame in
Cyberpunk 2077, and the driver's own coherence tests (`cohprobe`) are compute workloads.

The card shows up in `MTLCopyAllDevices()` next to the built-in GPU, so your code can choose it directly:

```swift
import Metal
let gpu = MTLCopyAllDevices().first { $0.name.contains("NVIDIA") } ?? MTLCreateSystemDefaultDevice()!
print(gpu.name)   // "NVIDIA GeForce RTX 3070 (NVMTL over NVIDIA GeForce RTX 3070 (NVK GA104-A))"
```

A tool that only asks for the system default GPU can be pointed at the card with `launch/usenv.sh` (section 5),
unmodified. For big inputs, put them in Private buffers and copy them in once: they then live in video memory, where the
card reads them fastest. Not yet tested on Apple Silicon: Metal Performance Shaders, Core ML and OpenCL (they work in
NullMoth's Intel build).

## How it works

```
your Metal game ─▶ NVMTLDriver (Metal plugin) ─▶ AIR → SPIR-V translator ─▶ NVK (Mesa Vulkan)
                                                                  └─▶ NVIDIA open kernel modules ─▶ RTX card over Thunderbolt
```

Apple Silicon games assume the CPU and GPU share one memory. Over a cable they don't, so the driver keeps a VRAM copy of
the game's shared memory and keeps both sides coherent — tracking what the CPU writes, uploading only what changed, and
copying GPU writes back. That mirror is where most of the speed comes from.

## Read this first

It is an early, experimental build: it changes your Mac's security settings, loads unsigned kernel extensions, and has
been tested on one machine. Read the whole page before installing.

| | |
|---|---|
| Tested on | MacBook Pro M1 Pro, macOS 27.0.1, a Thunderbolt 3 enclosure (Intel JHL7540 controller), GeForce RTX 3070 (GA104) |
| Should work | Ampere (RTX 30) cards; other Turing-and-newer cards are untested on Apple Silicon |
| Games | Native Apple Silicon Metal games that use the system default GPU and are not hardened-runtime signed |
| Not yet | Rosetta (Intel) games and CrossOver are expected to work but are untested; hardened-runtime apps cannot be redirected |

## Before you start

- You need: an Apple Silicon Mac, a Thunderbolt 3/4 enclosure, a supported NVIDIA card, an admin account, and about
  30 minutes with two restarts.
- Back up. The install changes the Mac's startup security policy (Permissive Security, SIP off). You can undo it, but
  only from recoveryOS.
- Quit and disable anything else that drives the card (TinyGPU / tinygrad's driver extension: System Settings →
  General → Login Items & Extensions → Driver Extensions, switch it off). Two drivers on one card will crash the Mac.
- Unzip the package (it unpacks to a folder named `package-arm64`) and move it to a path **without spaces**; this
  page assumes `~/Desktop/siliconwing/`:
  `mv ~/Downloads/package-arm64 ~/Desktop/siliconwing`. Then clear the
  download quarantine so its tools can run: `xattr -dr com.apple.quarantine ~/Desktop/siliconwing`.
- Note your **volume group UUID** while still in macOS — step 1 needs it: `diskutil info / | grep "Volume Group"`.

## 1. Allow third-party kernel extensions (recoveryOS)

1. Unplug the enclosure. Shut down, then hold the power button until "Loading startup options" appears; choose
   **Options** to enter recoveryOS.
2. Open **Utilities → Terminal** and run, **in this order** (use the volume group UUID you noted):

   ```bash
   bputil -k -v <volume-group-uuid>
   ```

   ```bash
   csrutil disable
   ```

   The order matters: `bputil -k` enables third-party kexts but also sets Reduced Security; `csrutil disable` must
   come second to lower it to Permissive. Do **not** use the Startup Security Utility window instead — it sets Reduced
   Security, which rejects these ad-hoc-signed kexts.
3. Check with `bputil -d -v <volume-group-uuid>`: it should show `Security Mode: Permissive` and `3rd Party Kexts
   Status: Enabled`. Restart into macOS; `csrutil status` should say disabled.

## 2. Set boot arguments

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=0x1 amfi=0x80 ipc_control_port_options=0 nvregdwords=RMPcieLinkSpeed=0x800002AA;PCIEPowerControl=0x3"
```

The first three let apps load the unsigned Metal plugin (this also turns off library validation system-wide). The
`nvregdwords` part pins the Thunderbolt PCIe link conservatively and turns off link power saving; keep it until your
setup has proven stable. Restart for boot-args to take effect.

## 3. Install

Plug the enclosure in after you have logged in, then:

```bash
cd ~/Desktop/siliconwing
```

```bash
sudo CHECK=1 bash install.sh
```

```bash
sudo bash install.sh
```

The first command only checks (security policy, kext signatures, firmware, card present) and changes nothing; it
must end with `CHECK PASS`. The second installs. If you want to install with the enclosure unplugged, use
`sudo NOGPU=1 bash install.sh`.

macOS will ask you to **allow the extensions** in System Settings → Privacy & Security. Allow them, then restart.

## 4. First plug-in after the restart

Plug the enclosure in **after logging in** (if something goes wrong, unplugging it and restarting gets you back to a
normal Mac). To confirm the card came up:

```bash
sysctl debug.nvrm_isr_count
```

A number that grows means the card is running. Then check that Metal sees it (from the package folder):

```bash
launch/defaultdev
```

The last line (`MTLCopyAllDevices[0]`) should name the NVIDIA card; the first two still name the built-in GPU, which is
what an ordinary app gets. To see what a game launched through `usenv` gets:

```bash
DYLD_INSERT_LIBRARIES=launch/libusenv.dylib launch/defaultdev
```

With the driver up, all three lines name the NVIDIA card.

## 5. Launching a game on the NVIDIA GPU

macOS hands every app the built-in GPU as its "system default". The `launch/` folder in this package changes that for
one app at a time: `usenv.sh` starts the game with `libusenv.dylib` inserted, which makes the NVIDIA card the default
device for that process only.

**Any app or game:**

```bash
~/Desktop/siliconwing/launch/usenv.sh "/Applications/Some Game.app"
```

Arguments after the app path go to the game.

**Steam games:** start the Steam client first, then pass the game's Steam app id (the number in
`steamapps/appmanifest_<id>.acf`):

```bash
~/Desktop/siliconwing/launch/usenv.sh "$HOME/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/Cyberpunk2077.app" 1091500
```

Or, to launch from the Steam library as usual, set the game's **Launch Options** (Properties → General) to:

```
DYLD_INSERT_LIBRARIES=/Users/<you>/Desktop/siliconwing/launch/libusenv.dylib %command%
```

**How to tell it worked:** the terminal prints `usenv: default Metal device -> NVIDIA GeForce …`. If it says
`NVMTLDevice NOT found`, the driver is not up (see step 4). If `usenv.sh` warns about the **hardened runtime**, that
game ignores the insertion and will stay on the built-in GPU; there is no workaround in this build.

**First launch after installing (or after an update) is slow.** Every shader is translated once and cached
(`~/Library/Caches/nvmtl/spvcache`). Some games (Cyberpunk 2077) have a watchdog that kills the game if loading takes
too long; if a game quits during its first load, just launch it again — the second launch uses the cache.

## 6. Settings

Defaults are chosen per process; environment variables override them (put them before the command, or in Steam's
launch options before `%command%`).

| Variable | Default | What it does |
|---|---|---|
| `NVMTL_SHMIRROR=1` / `=0` | on for native Apple Silicon apps, off for Rosetta / CrossOver | Keeps the game's shared CPU/GPU memory in video memory with full CPU/GPU coherence. The biggest speed-up (about +20% Cyberpunk, +7% Steel Nomad). Turn off if a game misbehaves. |
| `NVMTL_SHM_HEAPS=0` | on (with the above) | Also moves shared Metal heaps into video memory. This is where most of the Cyberpunk gain comes from. |
| `NVMTL_HEAP_LAZY=0` | on | Gives a game's Private heaps video memory as it uses them (64 MB at a time) instead of all at creation. Saves the most at high resolutions (about 3 GB in Cyberpunk at 2560×1600). `=0` backs every heap whole, as before. |
| `NVMTL_LOG_PATH=/path/file.log` | `/tmp/nvmtl.log` | Where the driver writes its log (if `/tmp/nvmtl.log` belongs to another user, `nvmtl.log` in your `$TMPDIR`). Attach it when reporting a problem. |

Example — run a game with the shared-memory acceleration off:

```bash
NVMTL_SHMIRROR=0 ~/Desktop/siliconwing/launch/usenv.sh "/Applications/Some Game.app"
```

## 7. Known issues

- **Unplugging and replugging the enclosure**: the desktop is drawn by the built-in GPU, so unplugging does not take it
  down (games running on the card lose it), but the card usually does not come back until you restart. Plug it in
  once per boot.
- **A game that crashes the GPU** (rare) loses the card for that game; other apps keep working. Restart the game; if the
  card stays unavailable, restart the Mac.
- **Rosetta and CrossOver** games are untested; the shared-memory acceleration is off for them by default.
- **Hardened-runtime apps** (many Mac App Store games) cannot be redirected to the card by `usenv`.
- Performance is limited by the enclosure's PCIe 3.0 x4 link over Thunderbolt: every trip to system memory costs
  microseconds, which is why the shared-memory acceleration matters.

## 8. Logs and reporting problems

- Driver log: `/tmp/nvmtl.log`, or `$TMPDIR/nvmtl.log`, or your `NVMTL_LOG_PATH`. `/tmp` is cleared at restart, so
  copy the log before restarting, or set `NVMTL_LOG_PATH` to a file in your home folder.
- Kernel panic reports: `/Library/Logs/DiagnosticReports/*.panic`.
- Kernel-side messages: `log stream --style compact --predicate 'eventMessage CONTAINS "NVRM" OR eventMessage CONTAINS "NVAccel"'`.
- `BUILD-NOTES.txt` in the package names the exact build; include it with any report.

## 9. Uninstall

```bash
cd ~/Desktop/siliconwing
```

```bash
sudo bash uninstall.sh
```

Restart afterwards. To restore full security, boot into recoveryOS and run `csrutil enable` (and, if you like,
remove the boot-args first with `sudo nvram -d boot-args`).

## License and source

SiliconWing is the Apple Silicon port of [NullMoth's NVIDIA driver for macOS](https://github.com/nullmoth/nvidia-macos-driver)
and, like it, is licensed under the **PolyForm Noncommercial License 1.0.0** (`LICENSE`): free for personal use, study,
research, hobby projects and noncommercial organisations; **not for commercial use**. It is source-available, not
open-source in the OSI sense. For anything commercial, ask NullMoth Systems.

Third-party parts keep their own licences (`NOTICE`, texts in `licenses/`): the shader translator is based on
[metal2vulkan](https://github.com/steelbrain/metal2vulkan) by Anees Iqbal (LGPL-3.0-or-later); the kernel side builds
against NVIDIA's open GPU kernel modules (MIT / GPL-2.0); the Vulkan back end is Mesa's NVK (MIT); the GSP firmware is
NVIDIA's, redistributed unmodified under NVIDIA's licence.

Source: https://github.com/OakRoller/SiliconWing (this port, including the modified shader translator), based on
https://github.com/nullmoth/nvidia-macos-driver
