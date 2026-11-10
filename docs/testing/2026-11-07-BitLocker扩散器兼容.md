# BitLocker 扩散器兼容：开发与验收记录

> 实体验收更新：2026-11-10，构建 92 已通过 Win7 SP1 原生 AES-128-CBC + Elephant Diffuser USB 分区的密码/48 位恢复密钥解锁、文件操作、锁定重开及 Mac↔Win7 双向哈希回读。详见 [实体验收](2026-11-10-Win7原生扩散器实体往返.md)。原生 256 位及中断压力场景仍待验证；正式渠道未改变。

> 发布状态更新：2026-11-07 按所有者授权独立发布 0.9.11 兼容测试版 1（86），未推送正式更新。以下保留开发验收阶段结论；真实 Win7 与跨系统验收仍未完成。发布详情见 `../release/0.9.11-beta.1-发布记录.md`。

## 当前结论

已实现元数据 v2 的 AES-128/256-CBC + Elephant Diffuser（0x8000、0x8001）解锁、读取及写入。独立算法向量、合成解锁、NTFS 镜像文件操作、写入日志恢复、现有算法回归和本地双架构构建通过。

**当前验收边界：** 原生 128 位实体盘已通过上述验收，原生 256 位和其他未覆盖路径不能据此宣称通过。以下保留 2026-11-07 开发阶段及转换样本的记录，不能与 2026-11-10 原生实盘结果混同。

**2026-11-07 历史边界：** 当时尚不作为正式支持发布。未取得 Windows 7 原生加密样本，未做旧格式实盘或 Finder 挂载验收；转换镜像在 Windows 11 中也没有通过互操作测试。不能据当轮结果宣称真实 Win7 磁盘已验收。官网已有的已发布版本说明当轮未改动，未安装、签名、提交、推送或发布应用。

## 实现

- `packages/VolisleNTFS/bridge/bitlocker.inc`：沿用 CommonCrypto、现有密码/恢复密钥/卷主密钥路径和密文写入日志；增加独立 TWEAK 上下文、扇区密钥、A/B 扩散与逆扩散。128 位模式仍按 32 字节槽位分割 FVEK 与 TWEAK，各取前 16 字节。
- 显式小端字读取、无符号 32 位加减、零位旋转分支，避免不对齐访问和移位未定义行为。
- 保留只读设备约束、保留区跨界写入零写入拒绝、错误传播和密钥清理；Vista 元数据、TPM 专用保护器、未完成加密/解密仍不支持。
- 更新接口注释和三种语言的通用“不支持格式或解锁方式”提示，避免错误地统一归因为 Windows 7 扩散器。
- 商店版 `NK_NO_BITLOCKER` 构建边界保持不变。

## 验证证据

| 项目 | 结果与范围 |
| --- | --- |
| 独立参考向量 | 12 组：128/256 位 × 512/4096 字节 × 3 个源偏移，分别精确比对加密密文与解密明文；含超过 32 位地址、不对齐内存 |
| 完整解锁与块 I/O | 4 组合成 v2 样本，覆盖密码、48 位恢复密钥、卷主密钥、错误凭据、畸形 FVEK、卷头重定位、不对齐写入、只读、保留区和 I/O 故障 |
| ASan / UBSan | `python3 scripts/test-bitlocker-diffuser.py --sanitize`，7 项通过；含原生进程中的公开解锁及块 I/O，未依赖 Python 注入 sanitizer |
| 扩散器 NTFS 镜像 | 只读 6 项、读写 5 项；中文名、9 MiB 文件、新建/修改/追加/改名/删除、恢复密钥重新解锁、原始样本不变 |
| 扩散器密文日志 | 6 项、66 个场景；中断、半写、缓存丢失、无密钥拒绝、恢复后文件和保留区完整 |
| 原四种算法 | 只读 6 项、读写 5 项；日志 6 项、132 个场景 |
| Swift 核心 | `swift test --package-path packages/VolisleCore`，532 项、51 套件通过 |
| 本机构建 | 格式引擎、主应用/后台组件 release、日常写入 FSKit 扩展，arm64 / x86_64 通过；扩展入口检查通过，未安装或挂载 |
| 本地化 | 简体、繁体、英文 `.strings` 的 `plutil -lint` 通过 |

报告：`bitlocker-diffuser-read-result.json`、`bitlocker-diffuser-write-result.json`、`bitlocker-diffuser-journal-result.json`、`bitlocker-diffuser-summary.json`。完整本地日志、原算法本轮报告副本在 `.workbench/bitlocker-diffuser-tests/`；既有历史验收报告未被新样本覆盖。

## 样本来源与可复现性

独立参考为 [Dislocker 固定提交](https://github.com/Aorimn/dislocker/tree/21ef6e58deb400502121e80fc0dfc7d9974e364f) 的原始扩散/加解密函数，加 OpenSSL AES 绑定。下载文件的 SHA-256 固定在 `scripts/bitlocker-fixtures/make-diffuser-vectors.py`，测试运行只需要已入库的 JSON。算法与格式另参照 [微软原始算法说明](https://www.microsoft.com/en-ie/download/details.aspx?id=13866) 和 [libyal BDE 格式说明](https://github.com/libyal/libbde/blob/main/documentation/BitLocker%20Drive%20Encryption%20%28BDE%29%20format.asciidoc)。生产代码未链接或打包 Dislocker。

合成解锁样本的 AES-CCM 封装由 Python cryptography 独立生成，所有密码和密钥均为公开测试值。NTFS 集成样本由现有 Windows 11 CBC 镜像副本独立重加密；**不是 Windows 7 创建的镜像**。生成器仅处理 `.workbench` 的已知测试镜像，不能用于真实磁盘重加密。

```sh
# 仅重新生成样本时需要；依赖放在本地测试虚拟环境，不是产品依赖。
.workbench/bitlocker-diffuser-venv/bin/python scripts/bitlocker-fixtures/make-diffuser-vectors.py
zsh scripts/build-ntfs-bridge.sh
.workbench/bitlocker-diffuser-venv/bin/python scripts/bitlocker-fixtures/make-diffuser-images.py

python3 scripts/test-bitlocker-diffuser.py --sanitize

VOLISLE_BDE_FIXTURES=.workbench/bitlocker-diffuser-fixtures \
VOLISLE_BDE_NAMES=diffuser128,diffuser256 \
VOLISLE_BDE_REPORT=docs/testing/bitlocker-diffuser-read-result.json \
python3 scripts/test-bitlocker.py

VOLISLE_BDE_FIXTURES=.workbench/bitlocker-diffuser-fixtures \
VOLISLE_BDE_NAMES=diffuser128,diffuser256 \
VOLISLE_BDE_WRITTEN=.workbench/bitlocker-diffuser-written \
VOLISLE_BDE_REPORT=docs/testing/bitlocker-diffuser-write-result.json \
python3 scripts/test-bitlocker-write.py

VOLISLE_BDE_FIXTURES=.workbench/bitlocker-diffuser-fixtures \
VOLISLE_BDE_NAMES=diffuser128,diffuser256 \
VOLISLE_BDE_REPORT=docs/testing/bitlocker-diffuser-journal-result.json \
python3 scripts/test-bitlocker-journal.py
```

自定义样本必须显式指定独立报告路径；读写还必须指定独立输出目录。输出限于 `.workbench`，不能与输入样本重叠；日志构建目录也不能与输入重叠。缺失报告和目录重叠的拒绝行为均实际验证，源样本标记未被删除。

## Windows 互操作：未通过

本机 Windows 11 Parallels 虚拟机中的对照：

1. 原始 Windows 11 CBC128 VHD：识别为 `Aes128`，2 个保护器，密码解锁成功。
2. 转换的扩散器 VHD：识别为 Unknown / 无保护器，解锁返回 `0x80310033`；没有进入文件校验，更没有计为成功。
3. 新增普通 CBC128→CBC256 重封装对照，同样被 Windows 拒绝。因此问题包含测试镜像元数据重写，不能将失败直接归因于扩散器生产算法或 Windows 不支持旧算法。

生成器已保持方法双字段、原始 nonce 布局，重算 CRC32 及 VMK 加密的 SHA-256；这些还不足以证明转换镜像符合 Windows 的全部校验。保留生成器、失败日志及 `verify-diffuser.ps1` 供继续定位。Windows 校验脚本要求两份各 4 项的完整文件清单，并校验实际算法名称；已在 Windows 实测语法及缺失清单拒绝，拒绝发生在挂载之前；上传失败按失败退出，不生成成功验收。

## 原开发阶段审查与发布前剩余事项（2026-11-07）

独立审查和 CodeRabbit 未发现生产算法缺陷。审查提出的自定义报告覆盖、输出目录删除输入样本、缺失期望文件清单零校验假成功、日志输出目录重叠风险已修复并检查。一次原算法日志回归编译被并行修改头文件打断，头文件稳定后重跑 132 个场景通过。

发布前还需：获取 Windows 7 原生创建的 128/256 位样本，用 Windows 和盘屿分别核验原文件及双向写入哈希；完成真实磁盘和 Finder / FSKit 挂载、锁定、推出、重插及恢复路径验收。若继续使用转换样本，先解决其 Windows 元数据兼容问题；不能用本地自洽读写代替跨系统验收。

2026-11-10 补充：上述原生 128 位密码及恢复密钥解锁、实盘 FSKit 文件操作、锁定、正常推出/重插及双向文件哈希已完成；256 位、专用只读与中断恢复压力验证继续保留为未完成项。
