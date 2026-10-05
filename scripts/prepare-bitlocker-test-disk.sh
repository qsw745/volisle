#!/bin/zsh
# Real-USB acceptance for BitLocker read-only: repartitions ONLY the Seagate
# Expansion 2 TB test disk (qsw) into a 159 MiB partition holding a volume that
# Windows 11 encrypted (.workbench/bitlocker-fixtures/xts128.img) and the rest
# as NTFS "qsw" formatted by 盘屿. Everything else on qsw is erased.
#   sudo zsh scripts/prepare-bitlocker-test-disk.sh            # asks for "yes"
#   zsh scripts/prepare-bitlocker-test-disk.sh --dry-run       # only shows the target
set -euo pipefail
cd "${0:A:h:h}"
fixture=.workbench/bitlocker-fixtures/xts128.img
app=~/Applications/"Volisle Test.app"/Contents/MacOS/Volisle
fixture_size=166658048
dry=false; [[ "${1:-}" == "--dry-run" ]] && dry=true
[[ -f $fixture && $(stat -f %z $fixture) == $fixture_size ]] || { print -u2 "缺少测试卷 $fixture"; exit 1; }

# Identify qsw by hardware, never by disk number: external, physical, USB,
# media name Expansion, 1.9–2.1 TB. Exactly one such disk.
targets=()
for d in $(diskutil list external physical | awk '/^\/dev\/disk/ {sub("/dev/","",$1); print $1}'); do
  plist=$(diskutil info -plist $d)
  name=$(plutil -extract MediaName raw - <<< $plist 2>/dev/null || true)
  bus=$(plutil -extract BusProtocol raw - <<< $plist 2>/dev/null || true)
  internal=$(plutil -extract Internal raw - <<< $plist 2>/dev/null || true)
  size=$(plutil -extract Size raw - <<< $plist 2>/dev/null || echo 0)
  [[ $name == *Expansion* && $bus == USB && $internal == false ]] || continue
  (( size > 1900000000000 && size < 2100000000000 )) || continue
  targets+=$d
done
(( ${#targets} == 1 )) || { print -u2 "应当恰好找到 1 块希捷 Expansion 2 TB 测试盘，实际 ${#targets} 块；未做任何修改。"; exit 1; }
disk=${targets[1]}
print "目标：/dev/$disk（希捷 Expansion，USB）"; diskutil list $disk
$dry && { print "（仅查看，未做任何修改）"; exit 0; }
[[ $EUID == 0 && -n ${SUDO_USER:-} ]] || { print -u2 "请用 sudo 运行（需要写入原始分区）"; exit 1; }
read "answer?将抹掉上面这块盘的全部内容。输入 yes 继续："
[[ $answer == yes ]] || { print "已取消，未做任何修改"; exit 1; }

diskutil unmountDisk $disk
# diskutil sizes are decimal and rounded down: ask for 300 MB, then trim that
# partition's end (same start) to the volume's exact size.
diskutil partitionDisk $disk 2 GPT %Windows_NTFS% %noformat% 300M %Windows_NTFS% %noformat% R
bde=""; rest=""
for p in $(diskutil list $disk | awk '/Microsoft Basic Data|Windows_NTFS/ {print $NF}'); do
  s=$(diskutil info -plist $p | plutil -extract Size raw -)
  if (( s < 1000000000 )); then bde=$p; else rest=$p; fi
done
[[ -n $bde && -n $rest ]] || { print -u2 "没有找到预期的两个分区，未写入加密卷"; diskutil list $disk; exit 1; }
start=$(( $(diskutil info -plist $bde | plutil -extract PartitionMapPartitionOffset raw -) / 512 ))
(( $(diskutil info -plist $bde | plutil -extract Size raw -) >= fixture_size )) || { print -u2 "分区小于测试卷"; exit 1; }
diskutil unmountDisk $disk
# macOS's gpt no longer edits tables; shrink the entry ourselves (both copies, CRCs checked).
python3 scripts/gpt-shrink-partition.py /dev/r$disk $start $(( fixture_size / 512 ))
sleep 3
[[ $(diskutil info -plist $bde | plutil -extract Size raw -) == $fixture_size ]] || { print -u2 "分区大小不符，未写入加密卷"; diskutil list $disk; exit 1; }
dd if=$fixture of=/dev/r$bde bs=1m
[[ $(head -c $fixture_size /dev/r$bde | shasum -a 256 | cut -d' ' -f1) == $(shasum -a 256 $fixture | cut -d' ' -f1) ]] || { print -u2 "写入校验失败"; exit 1; }
print "加密测试卷已写入 /dev/$bde 并校验一致"
sudo -u $SUDO_USER "$app" --helper-format $rest qsw
diskutil mount $rest || true
diskutil list $disk
print "\n下一步（以普通用户运行）："
print "  echo 'Volisle-Test-2026!' | \"$app\" --helper-bitlocker-unlock $bde password"
