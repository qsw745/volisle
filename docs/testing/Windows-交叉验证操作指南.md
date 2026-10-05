# Windows 交叉验证操作指南

适用于 qsw 2 TB NTFS 移动硬盘和当前日常候选。此轮验证普通文件双向读写；私有 Mac 权限与替换实验还未写入此盘，不能用这轮结果代替其专项验收。

## 1. 接盘并核对 Mac 写入的数据

1. Mac 上先在盘屿点“推出”，看到完成后再拔线。若硬盘已未挂载，可正常断开。
2. 插到 Windows 主机之前能识别硬盘的后置 USB 接口。确认资源管理器里是 qsw、约 2 TB，记下盘符。下文以 E: 为例，请换成实际盘符。
3. 把 `Volisle-Windows-Validation-20260924.zip` 复制到 Windows 本机桌面并解压，不要直接从压缩包内运行。
4. 双击 `Start-Verify.cmd`，输入盘符字母，例如 `E`。无需先以管理员运行。
5. 正常结果应为 **17/17 内容一致**，包括一个 64 MiB 文件和 16 个中文小文件。可在资源管理器中打开一个小文本，检查中文正常；不要保存修改到原验收文件。

工具只读取以下已知目录，不遍历整块硬盘：
`Volisle-Acceptance-20260923-a66957f52b614133896f2088379c5f94`

校验清单来自 Mac 写入后已经完成的系统 NTFS 独立只读回读记录，并非根据 Windows 当前文件重新生成。若目录不存在、文件缺失或哈希不符，保留结果，不创建同名空文件或覆盖它们来凑通过。

报告在 Windows 用户目录 `Volisle-Windows-Reports\日期-随机编号\windows-checksums.json`，窗口会显示完整路径。失败时同目录还有 `error.txt`。报告只表示这 17 个文件的内容核对，不表示整卷结构、ACL 或双向编辑通过。

启动器的执行策略选项仅作用于本次 PowerShell 进程，不更改系统的永久执行策略。工具不请求管理员权限，不运行修复，不挂载或格式化磁盘。

## 2. 检查 NTFS 结构，不执行修复

关闭正在打开 qsw 文件的编辑器、播放器及复制任务。右键开始菜单，选择“终端（管理员）”或“Windows PowerShell（管理员）”，在 PowerShell 中执行：

```powershell
chkdsk E: 2>&1 | Tee-Object -FilePath "$env:USERPROFILE\Volisle-chkdsk.txt"
$code = $LASTEXITCODE
"ExitCode=$code" | Add-Content -LiteralPath "$env:USERPROFILE\Volisle-chkdsk.txt"
```

这里 **E: 必须替换成 qsw 的实际盘符**。不要添加 `/f`、`/r`、`/x`、`/scan` 或其他参数。此轮只运行状态检查；不安排下次启动修复，不点系统弹出的“扫描并修复”来代替本项。

检查完成后保留完整日志。正常目标是报告没有文件系统问题，退出码为 0。如果无法检查、出现错误、要求卸载/修复，先停在这里，把日志交回分析，不接着进行新写入。活动卷未被锁定时也可能有误报，需要结合日志和占用情况判断，不能只见一个词就判定驱动损坏。

2 TB 的检查耗时取决于文件数量与当前状态，不以快速结束作为通过依据，也不需要执行逐扇区坏道扫描。

## 3. 在 Windows 新建内容，再插回 Mac

仅在前两项正常后进行：

1. 在 qsw 根目录新建 `Volisle-Windows-Return-20260924`。若已存在，改用一个新的后缀，不覆盖旧目录。
2. 在该目录新建 `Windows写入.txt`，用记事本输入几行中文，保存、关闭、重新打开，确认内容还在。
3. 从旧验收目录的 `子目录` 中，把 `64MiB 中文 🌊.bin` **复制**进这个新目录；不移动或修改原文件。
4. 关闭新文件后，回到 PowerShell 记录 Windows 上的摘要（目录和盘符按实际值调整）：

```powershell
Get-FileHash -LiteralPath 'E:\Volisle-Windows-Return-20260924\Windows写入.txt','E:\Volisle-Windows-Return-20260924\64MiB 中文 🌊.bin' -Algorithm SHA256 | Format-List | Out-File -FilePath "$env:USERPROFILE\Volisle-Windows-Return-hash.txt" -Encoding utf8
```

5. 使用 Windows 的“安全删除硬件”，完成后拔线插回 Mac。

将 `windows-checksums.json`、`Volisle-chkdsk.txt`、`Volisle-Windows-Return-hash.txt` 带回。Mac 端随后只读核对新文件的 SHA-256 与 Windows 报告，并查看中文内容。先不重写新文件，不运行修复。返回测试使用新目录，原验收目录作为内容基线保留。

## 本轮通过标准与未覆盖项

| 项目 | 通过依据 |
|---|---|
| Mac → Windows | 固定清单 17/17 SHA-256 一致，中文路径正常 |
| NTFS 结构 | `chkdsk` 完整日志无问题且退出 0，异常时由开发端进一步分析 |
| Windows → Mac | 记事本重开内容正常，两个返回文件在 Mac 上哈希与 Windows 记录一致 |
| 数据边界 | 未格式化、未修复、未修改原验收基线或其他既有文件 |

这不是 Windows ACL、私有权限、覆盖保存、全部断电场景或正式产品完成的证明。Windows 自定义权限的保存需要“Windows 设置测试 ACL → 记录安全描述符 → Mac 指定编辑 → Windows 再对照”的独立测试，当前日常候选尚未开放相应覆盖功能，不在此轮盲测。

## 工具准备与验证状态

2026-09-24：本机 PowerShell 7.6.6（官方 arm64 成品，下载摘要已核对）完成 13 项校验行为检查；按历史固定内容重建的 17 个本地文件全部校验通过。脚本采用 Windows PowerShell 5.1 可用语法，保留 UTF-8 BOM 以正确显示中文；入口和 Get-Volume 仍需实际 Windows 验证。未操作 qsw、未声明 Windows 实机通过。

参考：[微软 chkdsk 文档](https://learn.microsoft.com/zh-cn/windows-server/administration/windows-commands/chkdsk)、[Get-FileHash 文档](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/get-filehash?view=powershell-5.1)。

## 用户实际执行更新

2026-09-24 用户提供实机截图：G: qsw 的 17/17 校验通过、脚本退出 0；随后 `chkdsk G:` 的只读检查完成并报告未发现文件系统问题。chkdsk 数字退出码未显示、原始报告文件尚未收取，Windows → Mac 回读尚待进行。完整记录见 [Windows 基础只读验收](2026-09-24-Windows基础只读验收.md)。上方工具准备段保留为运行前历史，ZIP 工具包未改写。

后续更新：已通过 UU 完成 Windows 新目录写入、记事本保存与重开，并取回原始 17/17 JSON。用户物理接回 Mac 后，2026-09-24 03:53:41 UTC 只读回读的返回文件 **2/2 哈希一致**，原固定基线 **17/17 一致**，中文和记事本追加内容保留。该轮指定文件往返验收通过；Windows 安全弹出操作未观察、chkdsk 数字退出码仍未知。详见 [Windows 返程远程验收](2026-09-24-Windows返程远程验收.md)。
