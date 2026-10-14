#!/bin/zsh
# Exercises a volume the store extension has mounted read-write, through the
# ordinary file system interface, and checks everything again after a remount.
# Works inside one new folder on the volume and removes it at the end.
#   scripts/store/test-mounted-volume.sh /Volumes/<name> [megabytes of bulk data, default 1024]
set -euo pipefail
cd "${0:A:h:h:h}"
VOL=${1:?卷的挂载点}; BULK=${2:-1024}
info=$(mount | grep " on $VOL (") || { print -u2 "$VOL 没有挂载"; exit 1; }
[[ $info == *'(volislemas,'* ]] || { print -u2 "$VOL 不是商店版扩展挂载的：$info"; exit 1; }
[[ $info != *'read-only'* ]] || { print -u2 "$VOL 是只读挂载"; exit 1; }
DEV=${info%% on *}
W=.workbench/store-test/payload; rm -rf $W; mkdir -p $W/small
DIR="$VOL/盘屿商店版测试-$(date +%Y%m%d-%H%M%S)"
pass() { print "PASS $1" }
sum() { shasum -a 256 "$1" | cut -d' ' -f1 }

# Local source data: one large file and many small ones.
dd if=/dev/urandom of=$W/bulk.bin bs=1m count=$BULK 2>/dev/null
for i in {1..500}; do head -c $(( (i * 37) % 9000 + 1 )) /dev/urandom > $W/small/文件-$i.dat; done
( cd $W && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 ) > .workbench/store-test/payload.sha

mkdir "$DIR"
start=$(date +%s)
cp $W/bulk.bin "$DIR/大文件.bin"
print "写入 ${BULK} MiB 用时 $(( $(date +%s) - start )) 秒"
cp -R $W/small "$DIR/small"
[[ $(sum "$DIR/大文件.bin") == $(sum $W/bulk.bin) ]]; pass '大文件写入后回读一致'
( cd "$DIR" && for f in small/*.dat; do shasum -a 256 "$f"; done | sort ) > .workbench/store-test/volume-small.sha
( cd $W && for f in small/*.dat; do shasum -a 256 "$f"; done | sort ) > .workbench/store-test/local-small.sha
cmp -s .workbench/store-test/volume-small.sha .workbench/store-test/local-small.sha; pass '500 个小文件回读一致'

# Names, rename, overwrite, truncate, append, delete, nested folders.
mkdir -p "$DIR/多层/目录 with space/第三层"
print '第一版' > "$DIR/多层/目录 with space/第三层/说明.txt"
mv "$DIR/多层/目录 with space/第三层/说明.txt" "$DIR/多层/改名后的说明.txt"
print '第二版，更长一些' > "$DIR/多层/改名后的说明.txt"
print '追加一行' >> "$DIR/多层/改名后的说明.txt"
[[ "$(cat "$DIR/多层/改名后的说明.txt")" == $'第二版，更长一些\n追加一行' ]]; pass '改名、覆盖、追加'
cp $W/small/文件-1.dat "$DIR/待删除.dat"; rm "$DIR/待删除.dat"; [[ ! -e "$DIR/待删除.dat" ]]; pass '删除'
: > "$DIR/空文件"; [[ -f "$DIR/空文件" && ! -s "$DIR/空文件" ]]; pass '空文件'
truncate -s 1000 "$DIR/截短.bin" 2>/dev/null || dd if=/dev/zero of="$DIR/截短.bin" bs=1000 count=1 2>/dev/null
[[ $(stat -f %z "$DIR/截短.bin") == 1000 ]]; pass '指定大小的文件'
xattr -w com.volisle.test '扩展属性' "$DIR/空文件" && [[ "$(xattr -p com.volisle.test "$DIR/空文件")" == '扩展属性' ]]; pass '扩展属性'
rm -rf "$DIR/small/"文件-{1..100}.dat; [[ $(ls "$DIR/small" | wc -l) -eq 400 ]]; pass '批量删除 100 个'

# Everything must survive an unmount and a fresh mount.
before=$(sum "$DIR/大文件.bin")
diskutil unmount "$DEV" >/dev/null
diskutil mount "$DEV" >/dev/null
info=$(mount | grep " on $VOL (")
[[ $info == *'(volislemas,'* && $info != *'read-only'* ]]; pass '重新挂载后仍由商店版读写挂载'
[[ $(sum "$DIR/大文件.bin") == $before ]]; pass '重新挂载后大文件一致'
[[ $(ls "$DIR/small" | wc -l) -eq 400 ]]
for i in 101 250 500; do cmp -s "$DIR/small/文件-$i.dat" $W/small/文件-$i.dat; done; pass '重新挂载后小文件一致'
[[ "$(cat "$DIR/多层/改名后的说明.txt")" == $'第二版，更长一些\n追加一行' ]]; pass '重新挂载后文本一致'
[[ "$(xattr -p com.volisle.test "$DIR/空文件")" == '扩展属性' ]]; pass '重新挂载后扩展属性仍在'

rm -rf "$DIR"; [[ ! -e "$DIR" ]]; pass '清理测试文件夹'
rm -rf $W
print '全部通过'
