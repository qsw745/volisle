# 商店版纯 FSKit 技术验证（调研结论）

日期：2026-10-04。状态：**第 0 步验证不通过（2026-10-05），商店版暂停**，待 macOS 修复后复测。只读代码分析得出，未在设备上验证。

## 结论

技术上大概率可行，PoC 约 6–9 人日；GPL 与商店条款是比技术更大的不确定项。

- 拔线回滚已在扩展内（`NTFSVolume.activateVolume` → `recoverInterruptedWrites` → `inspectBeforeWritableActivation` → 决定只读/读写，日志在扩展沙盒容器）。root 后台组件主要负责：卸载系统原生 ntfs、以 root `mount -F -t volisle -o volisle-rw` 挂载、恢复原生挂载、IOKit 拔线判断、格式化（mkntfs）、清除检查标记、BitLocker VMK。
- 两个先决风险：① 商店版扩展须新增 `FSMediaTypes` 让系统自动探测挂载（现发布扩展没有，官网版声明不能动，所以商店版用独立 bundle id 与 FSShortName）；② 系统自带只读 ntfs 可能抢先自动挂载。

## 各职责在纯 FSKit 下的去向

| 职责 | 方案 |
| --- | --- |
| 挂载/卸载 | 系统自动挂载；推出用 NSWorkspace / FileManager；沙盒能否 DADiskMount 待验证，不行提示重新插拔 |
| 读写开关 | 扩展 activate 时读 App Group 策略（按卷序列号）+ 预检 + 回滚成功才读写；结果与只读原因写回 App Group，notify_post 通知主应用；切换需重新挂载 |
| 预检与回滚 | 现有扩展代码复用；官网版与商店版恢复记录互不可见，但脏标记使另一版本保持只读（安全失败） |
| 清除检查标记 | App Group 中“下次挂载时清除”请求，扩展 activate 时完整只读检查后清除 |
| 格式化 | 实现 FSKit format 维护操作交给“磁盘工具”，否则商店版不提供 |
| BitLocker | VMK 推导移入扩展，密码经共享钥匙串一次性传递；否则先不提供 |
| 主应用 | 失去 /dev、完全磁盘访问、mount、SMAppService.daemon；Sparkle 条件编译排除 |

## PoC 步骤

0. **先做（半天）**：沙盒扩展声明 FSMediaTypes，插盘看 `mount` 类型是 volisle 还是系统 ntfs；原生 ntfs 稳定抢先则整体方案另找出路。
1. 新建沙盒主应用 `top.qisw.volisle.mas`（无 helper、无 Sparkle）与扩展 `top.qisw.volisle.mas.filesystem`（FSShortName 如 volislemas），权限 app-sandbox + application-groups (+ fskit.fsmodule)。
2. 构建/签名脚本加商店版参数；官网版 EXAppExtensionAttributes 不动。
3. App Group 策略替换 `allowsDaily` 对 `volisle-rw` 的判断。

测试盘验证：挂载类型与无 helper；开关只读/读写与脏盘、休眠盘强制只读；写入中拔线重插回滚且原文件哈希一致（ntfs-3g 与 Windows chkdsk /scan）；正常推出清空记录；中断后用过 Windows 走作废路径；无 Sandbox deny；与官网版同时安装；altool 商店包校验。

## GPL 与商店条款（事实与选项，非法律结论）

NTFS-3G 为 GPL-2.0-or-later，ntfskit 桥接与 NTFSVolume/NTFSItem 为 GPLv2；GPLv2 第 6 条禁止附加限制，FSF 认为商店使用规则不兼容，VLC 2011 年因版权人投诉下架；须提供完整对应源码。选项：取得全部版权人例外或商业授权（含 Tuxera、whereteam）；净室重写 ntfskit 衍生部分；更换引擎；自有代码双许可 + CLA；商店版暂缓。

关键文件：apps/extension/Sources/NTFSVolume.swift、WriteMountPolicy.swift、scripts/prepare-extension-bundle.py、packages/VolisleCore/Sources/VolisleCore/SystemHelperWriteMount.swift、apps/macos/Sources/Volisle/AppUpdates.swift。

## 签名准备（2026-10-05）

- 已注册 App ID：`top.qisw.volisle.mas.filesystem`（描述 Volisle MAS File System，能力 FSKit Module；In-App Purchase 为苹果默认）。宿主应用 `top.qisw.volisle.mas` 尚未注册，Developer ID 下沙盒宿主不需要。
- 已生成 Developer ID 描述文件“Volisle MAS FS Developer ID 20261005”，证书 <开发者>（Developer ID Application，2027-02-01 到期），含 `com.apple.developer.fskit.fsmodule`；文件在 `~/Downloads/Volisle_MAS_FS_Developer_ID_20261005.provisionprofile`。
- 第 0 步验证安排在 0.5.6 发布之后：两个 FSKit 模块同时声明 NTFS 可能干扰正在用的盘屿，验证时需先暂停盘屿自动读写。

## 第 0 步结果（2026-10-05，macOS 27.2，qsw 实盘）

做法：沙盒宿主 `top.qisw.volisle.mas` + 扩展 `top.qisw.volisle.mas.filesystem`（复用 0.5.6 扩展程序，FSShortName `volislemas`，FSMediaTypes 声明 `EBD0A0A2-…` 与 `Windows_NTFS`，FSProbeOrder 100；系统 ntfs.fs 为 2000/1000），Developer ID 签名，`pluginkit -e use` 启用（前面出现 `+`），退出盘屿后拔插 qsw。

结果：仍由系统 `ntfs`（只读）挂载，测试扩展未被调用。fskitd 日志两次 `apply resource error (NSPOSIXErrorDomain Code=1)`、`probe resource error (Code=2)`：把真实 USB 磁盘交给以用户身份运行的第三方模块时被拒（`/dev/disk8s3` 为 root:operator 640）。

与苹果开发者论坛 https://developer.apple.com/forums/thread/788609 一致：第三方 FSKit 模块在所有内置驱动之后才参与探测，NTFS 总被系统只读驱动先认领；真实磁盘对第三方模块报权限错误，仅磁盘镜像与内存盘可用。苹果 DTS 承认问题并请提交 FB18230524，2026 年 4 月仍称需等待更多修复；没有官方接口或设置可绕过，社区绕法（chown 设备节点）需要 root。

结论：在苹果修复前，不依赖 root 后台组件的纯 FSKit 商店版无法实现自动读写挂载。官网版依赖的 root 后台组件正是商店不允许的部分。

后续：保留 `.workbench/mas-poc`（构建与签名步骤见本节）、App ID 与描述文件；每次 macOS 大版本更新后复测第 0 步。测试扩展已 `pluginkit -e ignore` 并删除测试应用。
