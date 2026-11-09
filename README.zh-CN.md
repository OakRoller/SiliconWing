# SiliconWing —— 让 Apple Silicon 用上 NVIDIA 外接显卡（实验性）

[English](README.md)

*SiliconWing 是 [NullMoth 的 macOS NVIDIA 驱动](https://github.com/nullmoth/nvidia-macos-driver) 的 Apple Silicon 移植版，
基于它的内核扩展、Metal 插件和着色器翻译器构建——所以系统里看到的组件名是 `com.nullmoth.*`。*

安装包请到 [Releases 页面](https://github.com/OakRoller/SiliconWing/releases) 下载；下文的步骤说的都是安装包里的文件（`install.sh`、`launch/` 等）。

> **给你的 M 系列 Mac 插上一块 GeForce，用它来玩 Metal 游戏。**

苹果从来没有在 Apple Silicon 上支持过外接显卡，这个版本做到了：雷电显卡盒里的 GeForce RTX 显卡负责渲染 Mac 原生的
Metal 游戏，画面照常显示在 Mac 自己的屏幕上。不用给游戏打补丁，也不用重新编译——游戏只会发现，原来内置 GPU 的位置上
换成了一块 NVIDIA 显卡。

- 🎮 **原生 Apple Silicon 游戏直接跑**——赛博朋克 2077、3DMark Steel Nomad 都能在 RTX 3070 上从头跑到尾。
- 🚀 **重负载下超过 M1 Pro 内置 GPU**——Steel Nomad **快 44%**，赛博朋克 2077 在 2560×1600 下 **快 8%**。
- ⚡ **不止游戏，Metal 计算也能跑**——计算内核同样在显卡上运行：赛博朋克的计算阶段只用 M1 Pro 0.3–0.9 倍的时间；
  你自己写的 Metal 代码也能像选择其他 GPU 一样选中这块显卡。
- 🧠 **隔着雷电模拟统一内存**——为苹果 CPU/GPU 共享内存写的游戏，会在显存里得到一份保持一致的镜像，完全察觉不到显卡
  是接在线缆另一头的。
- 🖥️ **桌面不受影响**——macOS 照常用内置 GPU 绘制桌面，只有你通过它启动的游戏才会用到显卡，一次只影响一个应用。
- 🔓 **源码公开，建立在开源组件之上**——NVIDIA 开源 GPU 内核模块、Mesa 的 NVK Vulkan 驱动，以及基于 metal2vulkan 的着色器翻译器（LGPL）。SiliconWing 本身可免费用于非商业用途。

## 性能表现

游戏自带基准测试的汇总结果，关闭光线追踪；同一台 MacBook Pro M1 Pro，对比内置 GPU 与经雷电 3 外接的 RTX 3070：

| | M1 Pro（内置 GPU） | 本版本 + RTX 3070 | |
|---|---|---|---|
| 3DMark Steel Nomad（演示版测试） | 9.0 fps | **13.0 fps** | **+44%** |
| 赛博朋克 2077，2560×1600 | 18.2 fps | **19.6 fps**（最低 16.5） | **+8%** |
| 赛博朋克 2077，1280×800 | **53.8 fps** | 36.2 fps（最低 24.5） | −33% |

实话实说：每个渲染阶段和计算调度都要隔着雷电链路付出一笔固定开销。所以每帧像素工作量越大，3070 越占优；分辨率低的时候，
这笔固定开销占了大头，就会落后。分辨率越高，表现越好。

## Metal 计算

计算是一等公民：计算管线、计算编码器（串行和并发）、间接调度，以及 Shared 缓冲区的 CPU/GPU 一致性，都能在显卡上正常
工作——赛博朋克 2077 每帧约 30 个计算阶段就是这样跑的，驱动自己的一致性测试（`cohprobe`）用的也是计算负载。

这块显卡会和内置 GPU 一起出现在 `MTLCopyAllDevices()` 里，你的代码可以直接选中它：

```swift
import Metal
let gpu = MTLCopyAllDevices().first { $0.name.contains("NVIDIA") } ?? MTLCreateSystemDefaultDevice()!
print(gpu.name)   // "NVIDIA GeForce RTX 3070 (NVMTL over NVIDIA GeForce RTX 3070 (NVK GA104-A))"
```

只会向系统要默认 GPU 的工具，不用改代码，用 `launch/usenv.sh`（第 5 节）启动就能指向这块显卡。数据量大的输入，建议放在
Private 缓冲区里一次性拷进去：这样数据就待在显存里，显卡读起来最快。Apple Silicon 上尚未测试：Metal Performance Shaders、
Core ML 和 OpenCL（它们在 NullMoth 的 Intel 版里可用）。

## 工作原理

```
你的 Metal 游戏 ─▶ NVMTLDriver（Metal 插件）─▶ AIR → SPIR-V 翻译器 ─▶ NVK（Mesa Vulkan）
                                                              └─▶ NVIDIA 开源内核模块 ─▶ 经雷电连接的 RTX 显卡
```

Apple Silicon 游戏默认 CPU 和 GPU 共用同一块内存，可隔着线缆并不是这样。于是驱动在显存里保留一份游戏共享内存的副本，
并让两边始终保持一致：跟踪 CPU 写了什么、只上传改动的部分、再把 GPU 写的内容拷回去。性能提升大部分就来自这份镜像。

## 安装前必读

这是早期的实验版本：它会修改 Mac 的安全设置、加载未签名的内核扩展，并且只在一台机器上测试过。安装前请把本页读完。

| | |
|---|---|
| 测试环境 | MacBook Pro M1 Pro、macOS 27.0.1、雷电 3 显卡盒（Intel JHL7540 控制器）、GeForce RTX 3070（GA104） |
| 应该能用 | Ampere（RTX 30 系列）显卡；其他 Turing 及更新的显卡在 Apple Silicon 上未测试 |
| 支持的游戏 | 使用系统默认 GPU、且没有启用强化运行时（hardened runtime）签名的原生 Apple Silicon Metal 游戏 |
| 暂不支持 | Rosetta（Intel 版）游戏和 CrossOver 预计可以运行，但未测试；启用强化运行时的应用无法切换到这块显卡 |

## 开始之前

- 需要：一台 Apple Silicon Mac、一个雷电 3/4 显卡盒、一张支持的 NVIDIA 显卡、一个管理员账户，以及大约 30 分钟
  （中间要重启两次）。
- 先备份。安装会修改 Mac 的启动安全策略（改为"宽松安全性"、关闭 SIP）。这些改动可以撤销，但只能在恢复模式里撤销。
- 退出并停用其他会驱动这块显卡的软件（例如 TinyGPU / tinygrad 的驱动扩展：系统设置 → 通用 → 登录项与扩展 →
  驱动程序扩展，把它关掉）。两个驱动同时操作一张卡会导致 Mac 死机。
- 解压安装包，会得到一个名为 `package-arm64` 的文件夹。可以改名，放在任何**路径中没有空格**的位置。在**这个文件夹里**
  打开终端——本页所有命令都在这里执行（在访达里右键点该文件夹 → 新建位于文件夹位置的终端窗口）。然后清除下载隔离标记，
  否则里面的工具无法运行：`xattr -dr com.apple.quarantine .`
- 趁还在 macOS 里，先记下**卷组 UUID**（第 1 步要用）：`diskutil info / | grep "Volume Group"`。

## 1. 允许第三方内核扩展（恢复模式）

1. 拔掉显卡盒。关机后长按电源键，直到出现"正在载入启动选项"，选择**选项**进入恢复模式。
2. 打开**实用工具 → 终端**，**按这个顺序**执行（填入刚才记下的卷组 UUID）：

   ```bash
   bputil -k -v <卷组UUID>
   ```

   ```bash
   csrutil disable
   ```

   顺序很重要：`bputil -k` 会打开第三方内核扩展，但同时把模式设成"降低安全性"；`csrutil disable` 必须在它之后执行，
   才能把模式降到"宽松安全性"。**不要**改用"启动安全性实用工具"的图形界面——它会设成"降低安全性"，而这个模式会拒绝
   这些临时签名的内核扩展。
3. 用 `bputil -d -v <卷组UUID>` 检查：应该同时显示 `Security Mode: Permissive` 和 `3rd Party Kexts Status: Enabled`。
   重启回 macOS 后，`csrutil status` 应显示 disabled。

## 2. 设置启动参数

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=0x1 amfi=0x80 ipc_control_port_options=0 nvregdwords=RMPcieLinkSpeed=0x800002AA;PCIEPowerControl=0x3"
```

前三项让应用能加载未签名的 Metal 插件（代价是在整个系统范围内关闭了库校验）。`nvregdwords` 部分把雷电 PCIe 链路
设得比较保守，并关闭链路节能；在你的设备确认稳定之前请保留它。启动参数在重启后生效。

## 3. 安装

登录之后再插上显卡盒，然后在安装包文件夹里执行：

```bash
sudo CHECK=1 bash install.sh
```

```bash
sudo bash install.sh
```

第一条命令只做检查（安全策略、内核扩展签名、固件、显卡是否在位），不改动系统，最后必须显示 `CHECK PASS`。第二条
命令正式安装。如果想在不插显卡盒的情况下安装，用 `sudo NOGPU=1 bash install.sh`。

macOS 会提示你到 系统设置 → 隐私与安全性 里**允许这些扩展**。允许之后重启。

## 4. 重启后第一次插卡

**登录之后**再插上显卡盒（万一出问题，拔掉显卡盒再重启就能回到正常的 Mac）。确认显卡已经启动：

```bash
sysctl debug.nvrm_isr_count
```

数字在增长，说明显卡在工作。然后确认 Metal 能看到它（在安装包文件夹里执行）：

```bash
launch/defaultdev
```

最后一行（`MTLCopyAllDevices[0]`）应该是 NVIDIA 显卡；前两行仍然是内置 GPU，也就是普通应用拿到的设备。想看通过
`usenv` 启动的游戏会拿到什么：

```bash
DYLD_INSERT_LIBRARIES=launch/libusenv.dylib launch/defaultdev
```

驱动正常时，三行都应该是 NVIDIA 显卡。

## 5. 用 NVIDIA 显卡启动游戏

macOS 会把内置 GPU 作为"系统默认"设备交给每个应用。安装包里的 `launch/` 文件夹可以逐个应用地改变这一点：
`usenv.sh` 在启动游戏时注入 `libusenv.dylib`，让这个进程（且只有这个进程）把 NVIDIA 显卡当作默认设备。

**任意应用或游戏：**

```bash
launch/usenv.sh "/Applications/Some Game.app"
```

应用路径后面的参数会原样传给游戏。

**Steam 游戏：**先打开 Steam 客户端，再在后面加上游戏的 Steam 应用 ID（就是 `steamapps/appmanifest_<ID>.acf` 里的数字）：

```bash
launch/usenv.sh "$HOME/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/Cyberpunk2077.app" 1091500
```

如果想照常从 Steam 库里启动，可以把游戏的**启动选项**（属性 → 通用）设为：

```
DYLD_INSERT_LIBRARIES=<安装包文件夹>/launch/libusenv.dylib %command%
```

这里 Steam 需要完整路径。在安装包文件夹里运行下面这条命令，把它输出的路径粘贴进去：

```bash
echo "$PWD/launch/libusenv.dylib"
```

**怎么确认成功：**终端会打印 `usenv: default Metal device -> NVIDIA GeForce …`。如果显示 `NVMTLDevice NOT found`，
说明驱动没有启动（见第 4 步）。如果 `usenv.sh` 提示 **hardened runtime**，说明这个游戏会忽略注入，仍然使用内置 GPU；
本版本没有绕过的办法。

**安装（或更新）后第一次启动会比较慢。**每个着色器都要翻译一次，结果会缓存起来（`~/Library/Caches/nvmtl/spvcache`）。
有些游戏（例如赛博朋克 2077）带有看门狗，加载时间太长就会结束游戏；如果游戏在第一次加载时退出，直接再启动一次即可，
第二次会用上缓存。

## 6. 设置

默认值按进程自动选择；环境变量可以覆盖默认值（写在命令前面，或者写在 Steam 启动选项里 `%command%` 的前面）。

| 变量 | 默认值 | 作用 |
|---|---|---|
| `NVMTL_SHMIRROR=1` / `=0` | 原生 Apple Silicon 应用开启，Rosetta / CrossOver 关闭 | 把游戏中 CPU 与 GPU 共享的内存放进显存，并保证 CPU 和 GPU 两边看到的数据一致。这是提速最大的一项（赛博朋克约 +20%，Steel Nomad +7%）。游戏出现异常时可以关掉。 |
| `NVMTL_SHM_HEAPS=0` | 开启（随上一项一起） | 把共享的 Metal 堆也放进显存。赛博朋克的提速主要来自这一项。 |
| `NVMTL_HEAP_LAZY=0` | 开启 | 游戏的 Private 堆按需分配显存（每 64 MB 一块，用到才分配），不再在创建时整块占满。高分辨率下省出的显存最多（赛博朋克 2560×1600 约 3 GB）。设为 0 则恢复整块分配。 |
| `NVMTL_LOG_PATH=/路径/文件.log` | `/tmp/nvmtl.log` | 驱动日志写到哪里（如果 `/tmp/nvmtl.log` 属于别的用户，就写到你的 `$TMPDIR` 下的 `nvmtl.log`）。报告问题时请附上。 |

示例——关闭共享内存加速来运行游戏：

```bash
NVMTL_SHMIRROR=0 launch/usenv.sh "/Applications/Some Game.app"
```

## 7. 已知问题

- **拔插显卡盒**：桌面由内置 GPU 绘制，所以拔掉显卡盒不会让桌面崩溃（正在显卡上运行的游戏会失去显卡），但显卡通常
  要重启后才能重新使用。每次开机只插一次。
- **游戏让 GPU 出错**（少见）：这个游戏会失去显卡，其他应用不受影响。重新启动游戏即可；如果显卡一直不可用，重启 Mac。
- **Rosetta 和 CrossOver** 游戏未经测试，默认不开启共享内存加速。
- **启用强化运行时的应用**（很多 Mac App Store 游戏）无法通过 `usenv` 切换到这块显卡。
- 性能受限于显卡盒经由雷电提供的 PCIe 3.0 x4 链路：每次访问系统内存都要花上几微秒，这也是共享内存加速如此重要的原因。

## 8. 日志与问题报告

- 驱动日志：`/tmp/nvmtl.log`、`$TMPDIR/nvmtl.log`，或你设置的 `NVMTL_LOG_PATH`。`/tmp` 会在重启时清空，所以请在
  重启前把日志复制出来，或者把 `NVMTL_LOG_PATH` 设到你主目录下的某个文件。
- 内核恐慌报告：`/Library/Logs/DiagnosticReports/*.panic`。
- 内核侧消息：`log stream --style compact --predicate 'eventMessage CONTAINS "NVRM" OR eventMessage CONTAINS "NVAccel"'`。
- 安装包里的 `BUILD-NOTES.txt` 标明了具体的构建版本，报告问题时请一并附上。

## 9. 卸载

在安装包文件夹里执行：

```bash
sudo bash uninstall.sh
```

卸载后重启。如果要恢复完整的安全设置，进入恢复模式执行 `csrutil enable`（也可以先用 `sudo nvram -d boot-args`
删除启动参数）。

## 许可与源码

SiliconWing 是 [NullMoth 的 macOS NVIDIA 驱动](https://github.com/nullmoth/nvidia-macos-driver) 的 Apple Silicon 移植版，
和原项目一样采用 **PolyForm Noncommercial License 1.0.0**（见 `LICENSE`）：个人使用、学习、研究、爱好项目和非营利组织
都可以免费使用；**不得用于商业用途**。它是"源码公开"的软件，不属于 OSI 定义的开源软件。如需商业用途，请联系 NullMoth Systems。

第三方组件保留各自的许可证（见 `NOTICE`，许可证全文在 `licenses/`）：着色器翻译器基于 Anees Iqbal 的
[metal2vulkan](https://github.com/steelbrain/metal2vulkan)（LGPL-3.0 或更新版本）；内核侧基于 NVIDIA 开源 GPU 内核模块
（MIT / GPL-2.0）；Vulkan 后端是 Mesa 的 NVK（MIT）；GSP 固件来自 NVIDIA，按 NVIDIA 的许可原样再分发。

源码：https://github.com/OakRoller/SiliconWing（本移植版，包括修改过的着色器翻译器），基于原项目 https://github.com/nullmoth/nvidia-macos-driver
