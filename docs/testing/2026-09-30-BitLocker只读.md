# BitLocker 只读（2026-09-30，开发中）

## 测试数据

Windows 11 专业版虚拟机生成 4 个 160 MB 的 VHD，各含一个完全加密的 NTFS 卷（XTS-AES 128/256、AES-CBC 128/256），保护器为密码与 48 位恢复密钥；内含中文路径文件 `说明.txt` 与 3 MiB 规律数据 `照片/2026/pattern.bin`，哈希由 Windows 计算。取出的卷镜像与元数据在 `.workbench/bitlocker-fixtures/`（不入库）。

## 引擎（`scripts/test-bitlocker.py`，6 项）

- 四种加密方式用密码解锁后只读挂载，两个文件的 SHA-256 与 Windows 一致；每块约 0.2 秒。
- 四块都能用恢复密钥解锁，内容一致。
- 密码与恢复密钥解出同一把卷主密钥；用主密钥可只读挂载且内容一致；主密钥错一位拒绝访问，格式不对（大写、长度、非十六进制）参数无效。
- 错误密码、校验不通过或组数不对的恢复密钥返回“拒绝访问”；全程零写入。
- 普通 NTFS 不被识别为 BitLocker。
- 四块镜像在全部测试前后逐字节不变。

结果：`docs/testing/bitlocker-result.json`。回归：`test-ntfs-bridge.py` 22、`test-ntfs-format.py` 8、`test-ntfs-symlink.py` 3、`test-ntfs-xattr-names.py` 3、`test-ntfs-check-marker.py` 4 项通过。

## 扩展（FSKit，本机镜像）

- `scripts/test-bitlocker-mount-option.swift`：挂载参数只接受恰好一个 64 位小写十六进制主密钥；BitLocker 卷头识别与卷 GUID。
- 安装候选版后，把加密卷镜像（整盘及带 MBR 分区表两种）挂接为设备，由普通用户执行 `mount -F -t volisle`：
  - 不带主密钥：扩展拒绝激活（Permission denied）。
  - 带主密钥：只读挂载成功，Finder 中可见 `说明.txt`、`照片`，两个文件哈希一致；新建文件、目录均返回“只读文件系统”；卸载正常；镜像逐字节不变。
  - 系统日志（含调试级别）中既没有主密钥，也没有参数名。
- 系统对 BitLocker 分区的描述：Windows_NTFS 分区、无卷类型、不可挂载；盘屿挂载后系统磁盘服务也不记录该挂载。

## 后台组件与应用

- VolisleCore 新增 12 项单元测试（请求校验、恢复密钥规整、回复解码、挂载点判定、只读核对、控制器的探测/解锁/推出/挂载表同步），全部 285 项通过。
- qsw（希捷 Expansion 2 TB，USB，普通 NTFS）上的后台路径：已挂载时探测被拒（磁盘正被使用）；卸载后回答“不是 BitLocker”；对它解锁提示“这个分区不是 BitLocker 加密分区”；内置盘拒绝。

## 真实 USB 盘（qsw，命令行）

所有者运行 `sudo zsh scripts/prepare-bitlocker-test-disk.sh`：GPT，disk8s2 为 166,658,048 字节的 Windows 数据分区，写入 xts128 测试卷并读回校验一致；disk8s3 由盘屿格式化为 NTFS “qsw”。准备过程中发现两点：`diskutil` 分区大小为十进制并向下取整到 MiB；本机 macOS 自带的 `gpt` 已不能修改分区表（镜像上普通用户同样报 operation not permitted）。改用 `scripts/gpt-shrink-partition.py` 原位收缩分区（主表与备份表、校验和先核对后写入，只许缩小；先在 1 GB 镜像上验证）。

- 探测：disk8s2 为 BitLocker；已挂载的 disk8s3 被拒（磁盘正被使用）。
- 错误密码、校验不通过的恢复密钥：“密码或恢复密钥不正确”，不挂载。
- 密码解锁 1.0 秒：只读挂载在 `/private/var/run/volisle-bitlocker/<uuid>`（mounted by qsw，nosuid、nodev）；两个文件哈希与 Windows 一致；新建文件为“只读文件系统”。
- 仍挂载时再次解锁被拒（磁盘正被使用）。
- 推出：`diskutil unmount <挂载点>` 失败（系统磁盘服务不知道这个挂载）；用户 `umount` 成功。界面“推出”已改用 `/sbin/umount`。
- 恢复密钥（空格分隔输入）解锁成功，内容正确。
- 密钥在进程参数中的暴露：解锁期间每约 60 毫秒采样一次 `ps`，root 的 `/sbin/mount` 进程参数中可见主密钥约 0.85 秒，其余时间不可见。

## 界面（所有者验收）

- 侧边栏在 qsw 下方显示“加密的 Windows 分区 · BitLocker · 已锁定”；错误密码提示“密码或恢复密钥不正确”；正确密码解锁后自动打开 Finder，状态变为只读。
- 第一轮发现：“推出”按钮先锁定、再推出整个设备，同盘 qsw 处于读写会话时整机推出被拒，弹出“磁盘正被其他程序使用”（锁定本身已成功）。修改：已解锁时按钮为“锁定”，只卸载加密分区；已锁定时“推出”推出整个设备，若同盘另一分区在读写会话中，先按原流程恢复只读再推出。界面新文字补齐英文（本地化检查 0 问题）。
- 第二轮（候选版 bde-lock-20260930）：解锁、锁定无弹窗，推出整个设备正常；重新插拔后加密分区不被系统挂载、保持锁定，qsw 照常挂载。

## 待完成
- Windows 直接加密的整块 U 盘或移动硬盘（含 4K 扇区）验收。
- 官网兼容性、帮助页与更新说明。
