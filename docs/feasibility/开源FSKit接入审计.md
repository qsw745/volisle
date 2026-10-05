# 开源 FSKit 接入初审

日期：2026-09-20。执行基线：先完成免费开源版，后续评估 Mac App Store 付费下载；商业 SDK 询价暂停。

## 结论与证据范围

候选 ntfskit 可用于研究 NTFS-3G 到 FSKit 的桥接，但**不能按上游默认实现直接接入盘屿**。已发现恢复挂载、清除 dirty 标记、格式化和缺失资源仍报告检查成功等路径，需要先收紧，再做隔离镜像测试。

本次仅完成固定版本的部分源码静态审查：没有编译或运行该驱动，没有安装扩展、执行上游脚本、访问原始磁盘或复制上游界面。既有 NTFS-3G 普通镜像实验不等于本候选驱动已经通过测试，也不证明能够上架商店。

## 固定版本与许可边界

- 上游：[whereteam/ntfskit](https://github.com/whereteam/ntfskit)。固定提交：`b7153a8dd51b895d0a87345c6ad8e95bda963ed3`。
- 隔离仓库：`.workbench/ntfskit-audit`；本次审查文件副本：`.workbench/ntfskit-source-audit/`。这些目录是调查材料，不是产品依赖或发布内容。
- 根 [LICENSE](https://github.com/whereteam/ntfskit/blob/b7153a8dd51b895d0a87345c6ad8e95bda963ed3/LICENSE) 将 `NTFSModule/` 和 `fsbundle/` 声明为 GPL v2；还将 `App/` 宿主界面声明为专有。实际树中的 `App-OSS` 命名与该说明不完全对应，不能据目录名推定许可，当前不使用该界面。
- 接入前仍须逐文件核对 GPL 文本、版权头、修改来源和完整依赖许可，记录核心与桥接各自的许可版本；本次根 LICENSE 检查不是完整许可审计。
- 不直接复用上游品牌、Bundle ID、签名团队或预编译工具。盘屿已有原创 SwiftUI 界面继续独立维护。

## 首轮发现

以下行号均对应上述固定提交，描述的是已读取的代码路径；尚未通过运行复现其对磁盘的实际影响。

| 发现 | 证据 | 盘屿接入要求 |
| --- | --- | --- |
| 可写挂载选择恢复标志 | `bridge/ntfs_bridge.c:134,153`：`NTFS_MNT_RECOVER` | 先只读检查；dirty、休眠及未知风险拒绝写入。审查核心对挂载标志的实际处理，不能仅删除标志就宣称安全 |
| 检查可能转为修复 | `NTFSFileSystem.swift:225-233`：非 `-n` 且资源可写时传入 repair；`bridge/ntfs_bridge.c:768,780-781`：恢复挂载并写入清除 dirty 后的标志 | 首版检查必须只读，不能因系统维护回调或默认选项自动修复、重放或清 dirty |
| 缺少资源仍报告成功 | `NTFSFileSystem.swift:213-222`：缺少 `lastResource` 时直接返回，完成回调没有错误 | 缺失资源返回明确失败或未知状态，不能当作卷健康检查通过 |
| 包含真正的格式化入口 | `NTFSFileSystem.swift:252-282` 调用 `nk_format`；`bridge/ntfs_bridge.c:936-939` 调用 mkntfs | 产品扩展明确拒绝格式化请求，不仅隐藏界面；从构建中排除 mkntfs/newfs 工具和相关入口 |
| 公开日志含用户卷标签或原始错误 | `NTFSFileSystem.swift:285-287` 使用 `.public` | 使用结构化错误码与隐私日志；诊断导出继续只允许白名单字段 |

源码：[FSKit 维护操作](https://github.com/whereteam/ntfskit/blob/b7153a8dd51b895d0a87345c6ad8e95bda963ed3/NTFSModule/NTFSFileSystem.swift#L194)、[C 桥接挂载](https://github.com/whereteam/ntfskit/blob/b7153a8dd51b895d0a87345c6ad8e95bda963ed3/NTFSModule/bridge/ntfs_bridge.c#L125)、[检查与修复](https://github.com/whereteam/ntfskit/blob/b7153a8dd51b895d0a87345c6ad8e95bda963ed3/NTFSModule/bridge/ntfs_bridge.c#L756)。

桥接里的 `NDevDirty`、`NInoDirty` 等内部记账状态不能一概视为卷风险标记；本表清 dirty 的证据特指 `ntfs_volume_write_flags` 对 `VOLUME_IS_DIRTY` 的处理。上游注释关于日志重放的描述也不能替代对实际链接核心版本的验证。

## 构建边界

已读取的 [project.yml](https://github.com/whereteam/ntfskit/blob/b7153a8dd51b895d0a87345c6ad8e95bda963ed3/project.yml) 指定 macOS 15.4、arm64，引用 `refs/ntfs-3g/libntfs-3g/.libs/libntfs-3g.a`，并包含 BitLocker 所用 libbde/libyal 依赖。配置还带有上游签名团队、Bundle ID，关闭 Hardened Runtime，并引用 fsbundle 内工具。不能整份复制作为盘屿发行配置。

下一步只保留 NTFS 首版所需依赖，排除 BitLocker、格式化与修复；固定实际核心来源和构建参数，建立可复现编译。运行时最低系统版本、CPU 架构、扩展 entitlement、签名及发行加固要求须在盘屿配置中单独验证。尚未完成所有源文件、Info.plist、entitlement 和依赖构建脚本审查。

## 接入顺序与验收

1. 完成实际核心依赖与许可清单，明确可复用文件范围；不纳入许可不明的界面和预编译二进制。
2. 建立普通文件镜像 I/O 测试层。只读预检的写回调一律拒绝并计数，检查前后比较整个镜像哈希，确认检查没有改写镜像。
3. 验证干净卷、dirty、休眠、截断/损坏、未知检查结果与缺失资源。危险或无法判定的状态不得进入可写挂载；不通过自动修复制造“通过”。测试夹具须记录来源和生成方法。
4. 在可丢弃镜像上验证创建、改写、重命名、删除、flush、卸载，再用新进程重新打开并校验数据；增加取消、I/O 失败与并发路径测试。
5. 再接入现有 `FileSystemAdapter` / `MountCoordinator`。扩展端必须对最终实际资源复核身份与权限，不能只依赖应用端先前的检查结果。
6. 具备实际开发者标识和扩展能力后，进行 FSKit、Finder 和 Windows 交叉验收；只在明确指定的可丢弃介质上做真实写入测试。

目前应用仍使用不可写引擎适配器，真实 NTFS 写入尚未开放。此初审没有改变该状态。

## 商店收费目标

[Apple FSKit 文档](https://developer.apple.com/documentation/fskit)提供可通过 Mac App Store 分发的用户态扩展路径，但这不是 GPL 组合许可或盘屿最终包合规的结论。后续单独核对 GPL 条件、实际 Apple 分发协议、沙盒、包内组件和[审核指南 2.4.5](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility)。免费开源版的研发继续推进，暂不实现支付或激活系统。

完整路线见[开源与商业化规划](../product/开源与商业化规划.md)。

## 后续开发记录

2026-09-20 已在保留来源和 GPL 声明的前提下抽取、修改部分桥接与 Swift 驱动文件，完成 13 组镜像测试及独立只读 FSKit 模块编译；上文“本次仅静态审查”为初审时点。最新范围见[简洁版与开源引擎进展](../testing/2026-09-20-简洁版与开源引擎进展.md)。未复制专有 UI，未安装扩展，未开放真实写入。

同日后续增加本会话 dirty 生命周期、失败锁定、扩展属性和跨组件互斥；现为 21 组镜像检查、28 项 Swift 核心测试通过。已有异常卷的 dirty 仍不清理；正常会话标记的清理边界和剩余产品验收见[写入保护与扩展属性验收](../testing/2026-09-20-写入保护与扩展属性验收.md)。
