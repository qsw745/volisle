# 盘屿 Volisle · Homebrew

盘屿官网版的 Homebrew 安装配置。安装包与官网下载的是同一个文件（Developer ID 签名、已公证）。

```bash
brew install --cask qsw745/volisle/volisle
```

要求 macOS 15.4 或更新版本。首次打开盘屿会弹出设置向导，按提示打开三个开关即可。

## 更新

盘屿在应用内自动更新：安装更新前会先安全结束磁盘读写。因此 `brew upgrade` 默认不会升级盘屿，这是有意的。

通过 Homebrew 更新时，先在盘屿或 Finder 中推出全部盘屿磁盘，再运行：

```bash
brew update
brew upgrade --cask --greedy volisle
```

## 卸载

1. 在盘屿或 Finder 中推出所有 NTFS 磁盘（挂着盘时 brew 会拒绝卸载）。
2. 在盘屿的 设置 → 支持 → NTFS 引擎 中点“移除组件”。
3. 运行 `brew uninstall --cask volisle`。

`brew uninstall --zap --cask volisle` 还会把设置、缓存和写入恢复记录移到废纸篓。请先确认每块 NTFS 磁盘最近一次都是正常推出的。

问题反馈：https://github.com/qsw745/volisle/issues

---

Homebrew cask for the website edition of Volisle, free and open-source NTFS read-write for Mac. Requires macOS 15.4 or later.

```bash
brew install --cask qsw745/volisle/volisle
```

Volisle updates itself in the app and safely ends disk access first, so `brew upgrade` leaves it alone by design. Eject all NTFS disks before `brew uninstall`; brew refuses while one is mounted.
