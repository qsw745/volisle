# 盘屿官网版的 Homebrew 安装配置，发布到 qsw745/homebrew-volisle。
# version 与 sha256 由 scripts/release/update-homebrew-tap.py 在每次发布时改写，不要手改。
cask "volisle" do
  version "0.9.11"
  sha256 "239e9de9f96ed0f1e9809ee8683632502864f10956b505b40bb9f41b785d8850"

  url "https://qisw.top/volisle/downloads/Volisle-#{version}-universal.dmg"
  name "Volisle"
  name "盘屿"
  desc "NTFS read-write built on FSKit"
  homepage "https://qisw.top/volisle/"

  livecheck do
    url "https://qisw.top/volisle/updates/appcast.xml"
    strategy :sparkle, &:short_version
  end

  # 更新由应用内的 Sparkle 负责：它会先安全结束磁盘读写再替换应用。
  # 声明 auto_updates 后，brew upgrade 默认不碰盘屿。
  auto_updates true
  depends_on macos: :sequoia

  app "Volisle.app"

  # 盘屿挂着盘时替换或删除应用，文件系统扩展可能被中途结束，卷会卡住直到重启。
  # 与应用内更新同一个判断：系统里不能有 volisle 类型的挂载。
  preflight_steps do
    run "/bin/sh", args: ["-c", <<~SH]
      version=$(/usr/bin/sw_vers -productVersion) || exit 1
      major=${version%%.*}
      minor=${version#*.}
      minor=${minor%%.*}
      if [ "$major" -lt 15 ] || { [ "$major" -eq 15 ] && [ "$minor" -lt 4 ]; }; then
        echo 'Volisle requires macOS 15.4 or later.' >&2
        exit 1
      fi
    SH
    run "/bin/sh", args: ["-c", <<~SH]
      mounts=$(/sbin/mount) || exit 1
      printf '%s\n' "$mounts" | /usr/bin/grep -q '(volisle[,)]' || exit 0
      echo '盘屿正在读写 NTFS 磁盘。请先在盘屿或 Finder 中推出所有 NTFS 磁盘，再重新运行这条 brew 命令。' >&2
      echo 'Volisle has NTFS disks mounted. Eject them in Volisle or Finder first, then run this brew command again.' >&2
      exit 1
    SH
  end

  uninstall_preflight_steps do
    run "/bin/sh", args: ["-c", <<~SH]
      mounts=$(/sbin/mount) || exit 1
      printf '%s\n' "$mounts" | /usr/bin/grep -q '(volisle[,)]' || exit 0
      echo '盘屿正在读写 NTFS 磁盘。请先在盘屿或 Finder 中推出所有 NTFS 磁盘，再重新运行这条 brew 命令。' >&2
      echo 'Volisle has NTFS disks mounted. Eject them in Volisle or Finder first, then run this brew command again.' >&2
      exit 1
    SH
  end

  uninstall launchctl: "top.qisw.volisle.mount-helper",
            quit:      "top.qisw.volisle"

  # 文件系统扩展的容器里有写入中断后的恢复记录，只移到废纸篓，需要时还能放回。
  zap delete: "/private/var/db/volisle",
      trash:  [
        "~/Library/Application Scripts/top.qisw.volisle.filesystem",
        "~/Library/Caches/top.qisw.volisle",
        "~/Library/Containers/top.qisw.volisle.filesystem",
        "~/Library/HTTPStorages/top.qisw.volisle",
        "~/Library/Preferences/top.qisw.volisle.plist",
      ]

  caveats <<~EOS
    首次打开盘屿会弹出设置向导：允许后台运行、在“系统设置 → 通用 → 登录项与扩展 → 文件系统扩展”中打开“盘屿 NTFS”、允许完全磁盘访问。

    盘屿在应用内自动更新（会先安全结束磁盘读写），brew upgrade 默认不会升级它。
    如需通过 Homebrew 更新，请先推出全部盘屿磁盘，再运行 brew upgrade --cask --greedy volisle。

    卸载前建议先在盘屿的 设置 → 支持 → NTFS 引擎 中点“移除组件”。
    zap 会把写入中断后的恢复记录移到废纸篓：请先确认每块 NTFS 磁盘最近一次都是正常推出的。
  EOS
end
