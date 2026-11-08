# Homebrew 安装（自建 tap）

起因：[qsw745/volisle#8](https://github.com/qsw745/volisle/issues/8)，用户希望用 Homebrew 统一安装和更新。

## 为什么是自建 tap

官方 homebrew/cask 对开发者自己提交的项目有知名度门槛：几百个星标，或几十上百个复刻（fork）/关注者（watcher）。公开仓库目前远未达到，所以发布到自己的 tap 仓库 `qsw745/homebrew-volisle`：

```bash
brew install --cask qsw745/volisle/volisle
```

## 文件

| 文件 | 作用 |
|---|---|
| `packaging/homebrew/Casks/volisle.rb` | cask 本体，版本号和 SHA-256 由发布脚本改写 |
| `packaging/homebrew/README.md` | tap 仓库首页 |
| `scripts/release/update-homebrew-tap.py` | `set` 改写版本；`push` 同步到 tap 仓库 |

`release.sh` 第 6 步执行 `set`，cask 随“官网与更新目录同步”提交入库；第 10 步在官网上线后执行 `push`，失败只提示、不影响发布。

## 设计取舍

- **下载地址用官网**：`https://qisw.top/volisle/downloads/Volisle-<版本>-universal.dmg`。国内访问 GitHub 下载很慢；官网会保留历史版本，旧版 cask 也能用。
- **`auto_updates true`**：更新仍由应用内的 Sparkle 负责，它会先安全结束磁盘读写再替换应用。`brew upgrade` 默认跳过盘屿；用户用 `--greedy` 强制升级时，下面的挂载检查兜底。
- **挂着盘时拒绝安装、升级和卸载**：判断方式与应用内更新（`UpdateSafety.verifyNoMountedVolumes`）一致，即系统里有 `volisle` 类型的挂载就停下。原因是替换或删除应用时，扩展可能被中途结束，卷会卡在内核里直到重启。
- **卸载**：退出主应用（`quit`），用 sudo 从 launchd 移除后台组件 `top.qisw.volisle.mount-helper`（`launchctl`）。
- **zap 用 trash 不用 delete**：扩展容器里存着写入中断后的恢复记录，移到废纸篓后还能放回。

## 首次上线（需要所有者操作）

1. 在 GitHub 新建公开仓库 `qsw745/homebrew-volisle`（不要加 workflow，避免触发云端构建）。
2. 运行 `python3 scripts/release/update-homebrew-tap.py push "volisle 0.9.10"`。
3. 在 macOS 15 虚拟机里完成下面的实测，再回复 issue。

## 实测清单

在虚拟机中执行（本机已装盘屿，`brew install` 会与 `/Applications/Volisle.app` 冲突）：

1. `brew install --cask qsw745/volisle/volisle`：下载、校验通过，`/Applications/Volisle.app` 版本正确，向导正常，插盘可读写。
2. 挂着一块 NTFS 盘时运行 `brew uninstall --cask volisle`：应拒绝，并打印中英文提示，应用保持原样。
3. `brew upgrade`：应跳过盘屿；`brew upgrade --greedy` 在挂着盘时应拒绝。
4. 推出磁盘后运行 `brew uninstall --cask volisle`：应用被删除，`sudo launchctl print system/top.qisw.volisle.mount-helper` 报找不到。
5. 重新安装后运行 `brew uninstall --zap --cask volisle`：所列文件出现在废纸篓。
6. `brew livecheck --cask qsw745/volisle/volisle`：报告的版本与官网一致。
7. `brew audit --cask --strict qsw745/volisle/volisle`、`brew style qsw745/volisle`：无错误。

## issue 回复草稿

> 感谢建议！盘屿现在可以用 Homebrew 安装了：
>
> ```bash
> brew install --cask qsw745/volisle/volisle
> ```
>
> 说明两点：
>
> 1. 盘屿暂时还进不了 Homebrew 官方仓库（官方对项目知名度有要求），所以要从我自己的 tap 安装。命令里的 `qsw745/volisle/` 就是 tap 地址，第一次运行时会自动添加。
> 2. 更新仍然在盘屿里完成。盘屿安装更新前会先安全结束磁盘读写，`brew upgrade` 做不到这一点，所以默认不会升级盘屿。挂着 NTFS 盘时，brew 也会拒绝卸载或强制升级，避免磁盘卡住。
>
> 安装包与官网下载的是同一个文件。遇到问题欢迎继续在这里反馈。
