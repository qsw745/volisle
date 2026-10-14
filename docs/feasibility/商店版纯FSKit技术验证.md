# 商店版纯 FSKit 技术验证（调研结论）

日期：2026-10-04。状态：**第 0 步复测通过（2026-10-11）**，2026-10-05 的“不通过”是启用方式不对造成的，见文末。其余结论为只读代码分析得出，未在设备上验证。

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

## 第 0 步复测（2026-10-11，macOS 27.2，2 TB 实盘）

起因：Mac App Store 已有同路线应用在售（xntfs，沙盒宿主 + FSKit 扩展 + NTFS-3G，GPL-2.0，2026-06-24 首发），其公开记录里有 macOS 27 上实体 USB 盘自动挂载的实测，与上节结论矛盾。

做法与上次的差别：扩展取自 0.9.2；测试应用装在 `/Applications`；在“系统设置 → 通用 → 登录项与扩展 → 文件系统扩展”里打开“盘屿 MAS 测试”，没有用 `pluginkit -e use`；显示名改为独立名称（原先沿用正式版本地化名，列表里两项同名）。签名仍是 Developer ID。

结果：通过。退出盘屿后重插，系统把实体盘交给测试扩展，挂在 `/Volumes/NTFS`，没有 root 后台组件参与。

- 14:05:48 fskitd `Call fskit_agent to set enabled state of identifier … to (1`：系统设置里的开关生效。
- 14:06:23 fskit_agent 启动 `top.qisw.volisle.mas.filesystem`；fskitd `apply resource error ((null)), probe resource error ((null))`：探测成功，上次的 Code=1 / Code=2 没有出现。
- 14:06:23 `FSKit check of resource … exited with error NSPOSIXErrorDomain Code=45`：扩展没有实现检查操作，磁盘仲裁按“修复失败”处理，弹出“macOS 无法修复磁盘”，并以只读挂载。
- `mount` 显示类型为 `volisle` 而不是 `volislemas`：类型名在 `NTFSVolume.swift` 的 `FSStatFSResult(fileSystemTypeName:)` 里写死，判断是哪个模块要看进程路径或日志，不能看这一列。
- `pluginkit -m` 里测试扩展前面是 `-`（上次清理留下的 ignore），照样被选中：pluginkit 的选择不是 FSKit 的开关。上次失败的原因即在此。

上节“第三方模块在所有内置驱动之后才参与探测、实盘报权限错误”的说法在 macOS 27.2 上不成立；引用的论坛帖主要是 macOS 15 的情况，macOS 15 与 26 未复测。

商店版由此新增的待办：实现检查操作（至少对干净的卷快速返回成功），否则每次插盘都会弹“无法修复”并只读；读写授权不能再靠后台组件传 `volisle-rw`，要按上文 App Group 策略改；应用内不能主动挂载实体盘（沙盒拒绝 `system.volume.external.mount`），切换只读/读写需重插或用磁盘工具。GPL 与审核风险不变。

## 实现进展（2026-10-11，分支 store-version）

扩展用 `-D VOLISLE_STORE` 编译（`scripts/build-fskit-extension.sh --store`，最低系统 26.4），官网版与默认只读两种变体不含这部分代码。本地测试包：`scripts/store/build-local-candidate.sh` 构建，`scripts/store/install-local-candidate.sh` 换装。

已做并验证（带 GPT 分区表的磁盘镜像走系统挂载路径，macOS 27.2）：

- 检查操作：系统挂载前的检查直接通过，不再弹“无法修复磁盘”；输出里写明没有检查文件系统。系统传来的参数是 `-q`。
- 读写判定：系统自动挂载不带 `volisle-rw`，商店版默认读写；`rdonly` 选项（`diskutil mount readOnly` 传的就是它）、写保护、“默认只读”偏好、恢复未完成、预检不干净时改为只读挂载，不拒绝；原因写入应用组，主应用显示。要求只读时不做回滚（回滚要写盘），镜像前后逐字节一致。
- 引擎打不开的卷在探测阶段交还系统（`nk_openable`），由系统驱动只读挂载；激活失败后系统不会自己回退。镜像里复现了 `$MFT` 记录 3 与 `$MFTMirr` 不一致的状态并验证。
- 探测返回真实卷标，挂载点不再一律叫“NTFS”；挂载类型为 `volislemas`。
- BitLocker 卷不接管。
- 主应用（`apps/store/`，沙盒，无后台组件、无 Sparkle）：NTFS 卷列表、读写/只读状态与原因、扩展未开启时的引导、“默认只读”开关、在访达中显示、推出。读写、按只读挂载、默认只读、系统挂载四种情形界面核对过；“推出”尚未实际点过。
- 测试：`scripts/test-store-mount-policy.swift`、`scripts/test-store-app-status.swift`、`scripts/test-ntfs-openable.py`。

实盘（2 TB 测试盘）：检查通过、不再弹窗；该盘当时带着官网版 0.9.2 留下的记录 3 不一致（结束读写约 1 秒后直接拔线），引擎打不开，另案排查。干净实盘上的读写与拔线恢复尚未测。

期间确认的系统行为：

- 扩展声明（EXAppExtensionAttributes）任何改动后，FSKit 不再列出已安装的模块，换构建号、`lsregister -f`、`pluginkit -a` 无效；改回原样即重新列出，但处于关闭状态。声明须在首个商店版本前定稿。待加入并上机验证的：`Partitionless`（无分区表的整盘 NTFS）、`FSVolumeAlwaysIgnoreOwnership`、personality 的 `FSSubType`（现在访达“显示简介”的格式是“未知 (volislemas)”）。
- 替换应用后，FSKit 留着旧副本的一个空闲扩展实例继续答复探测，不响应 SIGTERM。商店更新时系统如何处理，待 TestFlight 验证。
- `diskutil mount` 不重新探测已连接的盘。

- 声明定稿（已装进测试包，待重新登录后上机验证）：personality 改为 `NTFS`（FSName “Volisle NTFS”，FSSubType 0），去掉顶层 FSName，加 `FSVolumeAlwaysIgnoreOwnership` 与 `Partitionless`（探测顺序 3900，排在 APFS/HFS 整盘之后、系统 ntfs 的 4000 之前）；GPT 基本数据与 MBR NTFS 两项保持 100（系统 ntfs 为 2000 与 1000）。依据：磁盘仲裁源码 `DASupport.m` 的 `__propertiesForFSModule` 只读 FSShortName、FSSupportsBlockResources、FSMediaTypes、FSPersonalities，缺后两项的模块记“FSModule missing information”（官网版扩展即属此类，所以系统不会自动选它）；其余键取自系统自带的 msdos/exfat 模块。访达里的格式名由 CoreServices 决定，能否不再是“未知 (volislemas)”要上机看。
- 扩展显示名：`assets/brand/Localization/store-extension/`（盘屿 NTFS / 盤嶼 NTFS / Volisle NTFS）；本地测试包加“（商店测试）”后缀，以便和官网版的条目区分。
- 界面语言：简体、繁体、英文（`assets/brand/Localization/store/`，中文原文作键；`scripts/check-localization.py --store` 核对，`scripts/make-zh-hant.py --store` 生成繁体）。英文与繁体界面各截图核对过主窗口。

未做：图标收尾、格式化与 BitLocker、macOS 26 上机、商店签名与描述文件、上传与审核说明、与官网版并存时的处理。

送审前还要定的事（两轮代码审查留下的）：

- 出口合规：扩展二进制里带着 BitLocker 的 AES 代码（商店版并不接管 BitLocker 卷）。要么在商店版构建里去掉这部分，要么在 Info.plist 声明 `ITSAppUsesNonExemptEncryption` 并按要求申报。
- 检查操作一律报告通过，磁盘工具的“急救”因此对有问题的卷也显示成功（输出里有一句“没有检查文件系统”）。如实报告失败会重新触发系统的“无法修复磁盘”弹窗；是否区分系统挂载前的 `-q` 与用户手动检查，待定。
- 卷标直接取自磁盘：已去掉路径分隔符与控制字符并限长；带 `/` 或超长卷标的盘还没有上机挂载过。
- 沙盒里“推出”与“在访达中显示”尚未实际点过；最终签名的包上要再确认一次。

## 声明定稿上机验证（2026-10-13，macOS 27.2，重启后）

改了声明的测试包装上后，注销前系统一直不认（“No extension with fsShortName”）；重启并在系统设置里打开“盘屿 NTFS（商店测试）”后恢复正常。只锁屏或睡眠不算，登录会话和 fskit_agent 没有重启就不会重新读取声明。

用磁盘镜像走系统挂载路径：

| 情形 | 结果 |
|---|---|
| GPT 分区里的干净 NTFS | 商店版读写挂载（`volislemas`），写入成功 |
| 没有分区表的整盘 NTFS（`Partitionless`） | 商店版读写挂载，写入成功 |
| 记录 3 与镜像不一致的 NTFS | 交还系统，系统驱动只读挂载 |
| 没有分区表的 FAT16 镜像 | 仍由系统 msdos 挂载，不受影响 |
| 所有权 | 挂载带 `noowners`，文件属主为当前用户 |

没有解决的：访达“显示简介”里的格式仍是“未知 (volislemas)”，`diskutil info` 显示为 “MS-DOS (FAT)”。格式名来自 CoreServices 按挂载类型查找文件系统包（`/System/Library/Filesystems`），第三方 FSKit 模块没有这样的包，personality 里的 FSName 与 FSSubType 不起作用。挂载类型名由扩展代码决定、不属于声明，以后要换写法不需要用户重新启用。

同日补上的主应用问题（辅助功能可用后代点界面发现）：

- “在访达中显示”原先直接打开卷的地址，在沙盒里被 Launch Services 拒绝（permErr），点了没反应。改为请访达选中这个卷，会打开“电脑”窗口并选中它。
- “推出”在沙盒里可用：卸载并推出了磁盘镜像。实体盘上还没点过。
- 官网版盘屿正在读写的盘，在商店版里原先显示成“系统挂载、盘屿没有接管”。现在按挂载类型认出它，显示“官网版盘屿”，说明读写和推出在官网版里操作，两个按钮置灰。两个版本同时启用时一块盘到底归谁，还没有系统地测过。

## 实盘读写与拔线（2026-10-13，macOS 27.2，Seagate Expansion 2 TB USB 硬盘）

脚本：`scripts/store/test-mounted-volume.sh`（读写）、`scripts/store/test-unplug.sh`（拔线）。只走普通文件接口，在盘上新建的文件夹里进行，测完删除。

读写（商店版读写挂载，挂载前预检干净）：1 GiB 大文件 21 秒写完，回读哈希一致；500 个小文件、中文名与多层目录、改名、覆盖、追加、删除、空文件、扩展属性都正常；卸载再挂载后逐项复核一致。扩展没有报错。

长时间写入：连续写 240 个 256 MiB 文件（61 GB）没有报错，抽查第 1、120、240 个与基线文件一致。速度随写入量下降：开始约 6 秒一个，结束时约 16 秒一个，原因未查。

写入中拔线：40 个 256 MiB 文件轮流重写，持续约 3 小时（843 次）后直接拔线，约 20 秒后插回。

- 拔线时扩展记“写入日志会话停止：记录保留，下次连接时恢复”；插回后记“上次写入中断已回滚到最后一致点并释放本机脏标记”，预检干净，重新以读写挂载，从插回到可用约 14 秒。
- 拔线前 45 秒以上写好的基线（200 MiB 大文件与 50 个小文件）完好。
- 40 个轮写文件里 39 个完整，1 个（当时正在重写的前两个之一）停在 165 MiB：盘回到了拔线前约 20 秒的状态，写入方此后报告完成的两次重写被一并退回。这是设计内的代价。
- 恢复后的盘上再跑一遍读写脚本（512 MiB）全部通过。

没有做：恢复后接到 Windows 上跑磁盘检查；正常结束后立即拔线（这个分支在 0.9.4 之前拉出，还没有 0.9.4 的“记录保留到确认写入”修复，出商店版安装包前要先合入 main）。

与官网版并存时观察到的：官网版结束读写、请系统把盘挂回只读时，系统把盘交给了已启用的商店版扩展（按只读要求挂载），官网版随后的“推出”报“磁盘正被其他程序使用”。两个版本同时启用会互相妨碍，上架说明里要写清楚只用其中一个。

## 合入 main 之后的实盘补测（2026-10-14，macOS 27.2，同一块 2 TB 硬盘）

分支已合入 main（含 0.9.3、0.9.4），冲突只有桥接头文件一处。三种扩展变体重新编译；商店版三组测试与桥接层、检查标记、卷记录副本、写入日志回归通过。

正常结束后立即拔线（`scripts/store/test-unplug.sh end`）：写基线并静置 45 秒，再写 6 个 64 MiB 文件，随即正常卸载并语音提示拔线。

- 卸载时扩展记“写入日志会话正常结束：记录保留到确认写入”（10:28:20.46），卸载完成 10:28:20.50，磁盘消失 10:28:25.47，间隔约 5 秒。
- 插回后扩展核对了保留的记录，记“上次正常结束的写入都在盘上，保留的记录已清除”，预检干净，以读写挂载；核对用了约 8.6 秒。
- 基线与最后一批 6 个文件全部完整。这次硬盘在 5 秒内已把缓存写完，所以走的是“都在盘上”这一支；“没写上而回退”那一支在实盘上没有碰到（官网版当时是约 1 秒后拔线）。
- 随后在这块盘上重跑读写脚本（512 MiB）14 项全部通过，扩展无报错。

主应用“推出”在实体盘上：点击后系统授权记录为 `Succeeded authorizing right 'system.volume.external.unmount' by client '…/Volisle MAS Probe.app'`，磁盘仲裁记“ejected disk … success”，卷已卸载。

仍未做：恢复后的盘接到 Windows 上跑磁盘检查；macOS 26 上机；两个版本同时启用的各种先后顺序；写入速度随写入量下降的原因；商店签名的安装包与通过 TestFlight 更新。

## 商店签名与打包（2026-10-14）

所有者决定：检查操作维持一律通过（输出里说明没有检查文件系统）；商店版去掉 BitLocker 加密代码。

- 商店版扩展用 `NK_NO_BITLOCKER` 编译，解密层换成空实现；二进制不再引用 CommonCrypto（官网版仍有）。剩下的只有写入记录用的 SHA-256 与 HMAC，属于校验，应用信息里声明 `ITSAppUsesNonExemptEncryption = false`。
- `scripts/store/assemble-bundle.sh` 组装未签名的应用包，本地测试包与商店包共用，内容一致，只是签名不同；本地测试包的扩展显示名带“（商店测试）”。
- `scripts/store/build-store-package.sh <构建号>`：核对两份商店描述文件（标识符、Mac App Store 类型、未过期、扩展带 FSKit Module），用“3rd Party Mac Developer Application”签名，`productbuild` 用“3rd Party Mac Developer Installer”生成 `dist/store/Volisle-<版本>-store<构建号>/Volisle.pkg`。不上传。商店签名的包在本机无法启动（商店描述文件不含设备），要经 TestFlight 或商店重新签名后才能运行。

账号现状（2026-10-14）：

| 项目 | 状态 |
|---|---|
| 标识符 `top.qisw.volisle.mas.filesystem`（扩展，FSKit Module） | 已登记 |
| 标识符 `top.qisw.volisle.mas`（主应用，名称 Volisle MAS） | 已登记（当天用接口创建） |
| 描述文件 Volisle MAS App Store 20261014、Volisle MAS FS App Store 20261014 | 已创建（Mac App Store 类型），文件在 `~/Downloads`，路径写在 `config/release.local.env` |
| App Store Connect 应用记录 | 已创建：名称“盘屿 - NTFS 磁盘读写”，主要语言简体中文，SKU `volisle-mas`（不可改） |
| 证书 Mac App Distribution、Mac Installer Distribution | 有效到 2027-08-06，本机钥匙串里有 |

## 上传前的界面修改（2026-10-14）

所有者决定商店版版本号从 1.0 起，单独记在 `config/store.json`，不再沿用官网版的 `config/updates.json`。之前打的 0.9.4 构建 1 没有上传，已删除。

- 扩展没打开时，整个窗口换成分步引导（打开系统设置 → 打开“盘屿 NTFS” → 已接着的盘推出后重接），每 2 秒重新查一次开关，打开后自动回到磁盘列表；系统没列出扩展时说明放进“应用程序”、重开或重启。3 秒内查不到状态按“暂时无法读取”处理，不会一直转圈。
- 本机装着官网版（`top.qisw.volisle`）时，顶部提示两个版本只用一个，可“不再提示”。商店版应用看不到官网版扩展的开关状态（命令行查询也只列出系统自带模块），所以按“装着”判断。
- 去掉不起作用的边栏开关按钮；未挂载时的提示改为“拔下后重新接上”（此时“推出”不可用）；设置按钮补了辅助功能标签。
- 排版教训：提示条里的长文字带 `fixedSize(vertical:)` 时，内容高度会超过窗口，整窗什么都不画（辅助功能里内容都在）。改为文字占满按钮之外的宽度。
- 截图核对：引导页（简体、英文）、扩展未列出页、带提示条的主界面（简体、繁体），实盘挂载后的主界面；“不再提示”重开应用后仍生效。

商店包 `dist/store/Volisle-1.0-store1/Volisle.pkg`（版本 1.0，构建 1）已通过 `xcrun altool --validate-app`（VERIFY SUCCEEDED with no errors），2026-10-14 11:26 经所有者确认用 `altool --upload-app` 上传（Delivery UUID b73b26a7-a12d-4da6-9d15-821a6f9dd12e），约 2 分钟后处理完成：VALID，TestFlight 内部测试状态 READY_FOR_BETA_TESTING，未要求补填出口合规。账号里还没有 TestFlight 测试组。

构建 1 的应用包叫 `Volisle.app`，装到 `/Applications` 会和官网版同名（标识符不同）。所有者决定改名：从构建 2 起商店版应用包叫 `Volisle Store.app`（访达与程序坞里仍显示“盘屿”），构建 1 不再使用。构建 2 已打包并通过 altool 校验，经所有者确认上传（Delivery UUID 4e22179d-0201-4814-b144-ac1479ba3b64），11:45 处理完成：VALID，内部测试状态 IN_BETA_TESTING。

TestFlight：用接口建了内部测试组“内部测试”（自动获得所有构建），账户持有人已加为测试员。本机还有同标识符、Developer ID 签名的 `/Applications/Volisle MAS Probe.app`，装 TestFlight 版前要先移走。

## TestFlight 版实盘验证（2026-10-14）

所有者从 TestFlight 装上构建 2（`/Applications/Volisle Store.app`，签名 TestFlight Beta Distribution，带 `_MASReceipt`、无内嵌描述文件），在系统设置打开“盘屿 NTFS”，插上 2 TB 测试盘。

- 商店签名版读写挂载（类型 volislemas），`test-mounted-volume.sh … 512` 全部通过，重新挂载后仍由商店版读写挂载。
- 11:56:56 我用 `open "/Applications/Volisle Store.app"` 打开主应用时，lsd 重新登记了这个应用（“Building bundle record for app”），launchd 随即“remove all extension instances … top.qisw.volisle.mas.filesystem”。挂着测试盘的扩展收到 SIGTERM，尝试强制卸载被内核拒绝（-536870198），5 秒后被 SIGKILL，卷卡在内核（`/Volumes/Untitled`，读目录报 Stale NFS file handle），重启后才释放。
- 重启后：开机那一刻商店版扩展还被当作关闭（“Attempt to start disabled extension”），系统先用自带只读驱动挂上；官网版随登录启动，卸下后想用自己的扩展接管，因盘带脏标记拒绝。退出官网版、重插后，商店版“上次写入中断已回滚到最后一致点并释放本机脏标记”，读写挂载；被退回的是被杀前最后几秒的清理操作（测试文件夹又出现，404 个文件都能完整读出）。
- 复现（测试镜像，实体盘先卸下）：挂着读写卷时，主应用运行中按路径打开、退出后按路径打开、按标识符打开，各一次，都没有再重新登记，扩展进程不变。所以那次是装完后的一次性登记，不是每次打开都会发生。
- 由此推断（未验证）：商店或 TestFlight 更新应用时同样会结束全部扩展实例，挂着读写的盘会卡到重启，最后一段写入被回滚。商店版无法像官网版那样在更新前先结束读写会话。要用构建 3 在挂着镜像时通过 TestFlight 更新来验证。
- 日志里 taskgated-helper 对两个包都报 “Unsatisfied entitlements: com.apple.security.application-groups”，昨天的 Developer ID 测试包同样报过；应用组实际可用（扩展读到了“默认只读”为关，按读写挂载）。我们创建的商店描述文件里没有应用组项。

### 挂着读写卷时通过 TestFlight 更新（构建 2 → 3，2026-10-14 15:11）

用 `scripts/store/test-update-while-mounted.sh` 在测试镜像副本上每 0.5 秒写一个小文件，实体盘已拔下；所有者在 TestFlight 点“更新”。

- appstoreagent 请 RunningBoard 结束 `top.qisw.volisle.mas` 与 `.filesystem` 的全部进程；挂着卷的扩展被直接 `kill(9)`，没有 SIGTERM 宽限，扩展来不及做任何事。主应用当时开着，报 “termination resistance”，更新仍照常完成。
- 这次内核随即自行卸下了卷（“spontaneous unmount cleanup”），没有卡住，不用重启。和装完后那次不同：那次是 pkd 移除扩展实例，扩展先收到 SIGTERM，FSKit 自己尝试强制卸载被拒，5 秒后 SIGKILL，卷卡到重启。
- 重新挂载：“上次写入中断已回滚到最后一致点并释放本机脏标记”，读写挂载。写完关闭的 110 个文件里保住 69 个，最后 41 个（约 20 秒）被退回，保住的内容都正确。这正是写入记录的 20 秒保留窗口（`WriteJournal.retentionSeconds`）：恢复时分不清“进程被结束”和“拔线”，一律退回到确认已落盘的点。
- 结论：商店或 TestFlight 更新会像拔线一样打断正在读写的盘，最后约 20 秒的写入丢失，访达还可能提示磁盘未正确推出。商店版默认自动更新，而扩展不依赖主应用运行，用户无从察觉。

### 中断提示与更新说明（构建 4，2026-10-14）

所有者决定先做两件事：说明里写清楚“更新前先推出”，以及恢复退回写入后告诉用户。

- 扩展：恢复结果为“中断后回滚”或“正常结束后过早断开”时，挂载记录里多一项 `recovery`（`interrupted` / `after-end`），主应用选中这块盘时用橙色提示退回了写入，请用户检查最近拷贝的文件。下次正常挂载会覆盖记录，提示随之消失。
- 主应用：可读写的盘多一句“盘屿更新时会中断正在读写的磁盘，更新前请先推出”；设置里新增“更新”一节。商店介绍与帮助页文字草稿在 `docs/store/商店介绍与帮助草稿.md`，尚未填写或发布。
- 上机：构建 4 上传处理完成后，在测试镜像上持续写入，所有者在 TestFlight 把 3 更新到 4。旧扩展被结束，卷由内核卸下；重挂后新扩展回滚（写完 157 个，留下 116 个），主应用显示中断提示。正常卸下等 25 秒再挂载后，提示消失。

构建 5（2026-10-14）：只多了扩展的急救日志说明翻译（`assets/brand/Localization/store-extension/*/Localizable.strings`），校验并上传（Delivery UUID 8e86abf1-360b-4377-95ac-bfc7dc1c2b7e），处理完成 VALID，进入内部测试。审核备注草稿与审核用测试磁盘在 `docs/store/`。

公开源码（2026-10-14，所有者确认）：用 `scripts/publish-public.py` 从 store-version 导出（排除 `docs/store/` 草稿，扫描无命中），同步到公开仓库 `qsw745/volisle` 的提交 c67d569“盘屿商店版 1.0（构建 5）”，作者 noreply，并推送标签 `store-1.0-build5`；本地仓库在导出的那次提交上打了同名标签（未推送私有仓库）。注意：以后官网版发版时 release.sh 从 main 的标签导出快照，main 里没有商店版代码，会把公开仓库 main 上的商店版代码去掉；`store-1.0-build5` 标签不受影响。商店版合进 main 之前，每次商店发版都要单独打标签同步。

官网页面（2026-10-14，所有者确认上线）：在 main 上新增 App Store 版帮助页（`/volisle/store/`、`/volisle/en/store/`），隐私说明加“App Store 版”一节（提交 8d917b5，分支 web-store-pages 快进合并进 main，未推送）。用 0.9.4 的发布产物重新暂存整站，与 0.9.4 上线时只多这两页，更新目录不变；部署为 `20261014-0.9.4-build76-store-pages`，回滚 `scripts/deploy-website.sh rollback 20261012-0.9.4-build76`。App Store Connect：技术支持网址 `https://qisw.top/volisle/store/`，隐私政策网址 `https://qisw.top/volisle/privacy/`。商店版应用里的帮助链接改为按界面语言打开这两页（a6f5d72），从构建 6 起生效。

构建 6（2026-10-14）：先合入 main（官网 App Store 版帮助页），主应用的帮助链接按界面语言指向 `/volisle/store/` 或 `/volisle/en/store/`；校验并上传（Delivery UUID 8df98a07-9ad9-45b5-b881-66421d3b127d）。审核备注改用构建 6 和源码标签 `store-1.0-build6`（公开仓库待同步）。

