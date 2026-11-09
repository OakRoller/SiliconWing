# Apple Silicon 首次加载操作单

目标：在 M1 Pro + JHL7540 雷电 3 显卡盒 + GA104（RTX 3070 LHR）上第一次加载 arm64e 的 NVRM.kext，看 GSP 能否启动。
每一步都是在真机上没做过的；出问题的恢复办法写在最后。

## 0. 先把安装包放到没有空格的路径

    ~/Desktop/nvidia-macos-driver-arm64/      ← build/arm64/package.sh 的产物（195 MB）

## 1. 恢复模式：把安全策略改成 Permissive

1. 显卡盒先拔掉。关机，长按电源键直到出现"选项"，进入恢复模式。
2. 菜单栏"实用工具" > "终端"，按这个顺序执行两条命令（卷组 UUID 用 `diskutil info /` 里的 APFS Volume Group）：

       bputil -k -v 69B621CD-5FAC-4A60-9EB1-98BCE2A5DD89
       csrutil disable

   顺序很重要：`bputil -k` 打开"3rd Party Kexts"开关（smb2）的同时会把模式设成 Reduced（SIP 开、boot-args 过滤开），
   所以 `csrutil disable` 必须在它之后，把模式降到 Permissive（SIP 关、boot-args 可改），smb2 保留。
   曾经反过来做过一次，结果是 Reduced + Kexts Enabled + SIP on，安装脚本拒绝临时签名的 kext。
   `bputil -k` 在 macOS 里执行会报 `AP boot mode (11)`，只能在恢复环境做；授权用户名是本机的管理员账户。
   验证：`bputil -d -v <卷组>` 应同时显示 `Security Mode: Permissive` 和 `3rd Party Kexts Status: Enabled`。
   **不要用"启动安全性实用工具"的图形界面勾"允许用户管理内核扩展"**：它会把模式改成 Reduced 并重新打开 SIP，
   Reduced 只接受开发者签名的 kext，我们的临时签名会被安装脚本和 kernelmanagerd 拒绝（踩过这个坑）。
3. 重启回 macOS。`csrutil status` 应显示 disabled。

## 2. 停用 TinyGPU

TinyGPU 的 DriverKit 扩展一插卡就会接管显卡并打开总线主控，和 NVRM 同时操作一张卡会出事。
退出 TinyGPU.app；系统设置 > 通用 > 登录项与扩展 > 驱动程序扩展，把 TinyGPU 关掉（或 `systemextensionsctl list` 后 uninstall）。

## 3. boot-args（重启生效）

    sudo nvram boot-args="amfi_get_out_of_my_way=0x1 amfi=0x80 ipc_control_port_options=0 nvregdwords=RMPcieLinkSpeed=0x800002AA;PCIEPowerControl=0x3"

- 前三项让 WindowServer 和应用能加载未签名的 Metal 插件（和 Intel 版一样，代价是关掉了库校验）。
- `nvregdwords=...` 把 PCIe 链路钉在 Gen1 并关 ASPM。tinygrad 在 Ada 卡上测到 GSP 一跑流量就把雷电链路打断，
  Ampere 没有测过；第一次启动先带上它求稳，跑通后再去掉看 Gen3 是否稳定。它会一直生效到显卡盒断电。

## 4. 安装

    cd ~/Desktop/nvidia-macos-driver-arm64
    sudo CHECK=1 bash install.sh      # 只检查，不改系统：策略、kext 签名、固件（安装脚本要求显卡盒此时插着）
    sudo bash install.sh              # 正式安装：拷 kext、插件、固件，kmutil load 触发审批

首次会提示去"系统设置 > 隐私与安全性"批准 NullMoth 的内核扩展，批准后重启，kernelmanagerd 才会把它们编进辅助内核集合。

## 5. 第一次插卡（登录之后，不要在开机前插）

显卡盒是热插拔的：开机时不插，万一 NVRM 内核恐慌，拔掉显卡盒重启就能回到正常系统，不会反复崩溃。

1. 先开一个终端看日志：

       /usr/bin/log stream --style compact --predicate 'eventMessage CONTAINS "NVRM" OR eventMessage CONTAINS "NVAccel" OR eventMessage CONTAINS "apciec" OR eventMessage CONTAINS "DART"'

2. 插上显卡盒。期待看到的顺序：`NVRM-xnu` 匹配到 67:0:0 → `interrupt source ... (MSI)` → `MSI N armed; calling rm_init_adapter()`
   → 固件加载 → `PASS 2 REACHED: the adapter is up`。
3. 验证：

       ioreg -rn display@0 -l | grep -E "nvrm-gpu-profile|NVRM|NVAccel"
       sysctl debug.nvrm_isr_count          # MSI 计数在涨
       ~/Desktop/nvidia-macos-driver-arm64/enumsim   # 列出 Metal 设备，应多出一个 NVIDIA 设备

## 6. 出问题时

- **内核恐慌**：拔显卡盒，重启。恐慌日志在 `/Library/Logs/DiagnosticReports/*.panic`，整份发给我。
  `-nvoff` 加进 boot-args 可以让 NVRM 不碰显卡。
- **没有 MSI 中断源**（日志 `no MSI source on the device — refusing`）：这是 Apple Silicon 上唯一没验证过的点，NVRM 会拒绝启动而不会崩，把日志给我。
- **链路断开**（日志 `Link timeout` / `AER`）：说明 Gen1 钉链路没生效或还不够，拔掉显卡盒重插（显卡盒断电才会清掉链路状态）。
- 卸载：`sudo bash uninstall.sh`；恢复 SIP：恢复模式 `csrutil enable`。
