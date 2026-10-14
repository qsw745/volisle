#!/bin/zsh
# Unplug test for a volume the store extension has mounted read-write.
#   test-unplug.sh start  /Volumes/<name>   writes a baseline, lets it settle, then keeps writing
#                                           in the background: pull the cable while it runs
#   test-unplug.sh end    /Volumes/<name>   writes a baseline, lets it settle, writes a last batch,
#                                           unmounts cleanly and says "拔线" aloud: pull the cable at once
#   test-unplug.sh verify /Volumes/<name>   after the disk is back: what survived, what was rolled back
#   test-unplug.sh clean  /Volumes/<name>   removes the test folder
# State lives in .workbench/store-test/unplug/.
set -euo pipefail
cd "${0:A:h:h:h}"
MODE=${1:?start | end | verify | clean}; VOL=${2:?卷的挂载点}
S=.workbench/store-test/unplug
sum() { shasum -a 256 "$1" | cut -d' ' -f1 }
mounted_rw() { local info; info=$(mount | grep " on $VOL (") || return 1; [[ $info == *'(volislemas,'* && $info != *'read-only'* ]] }

case $MODE in
start)
  mounted_rw || { print -u2 "$VOL 不是商店版读写挂载"; exit 1; }
  rm -rf $S; mkdir -p $S
  DIR="$VOL/盘屿商店版拔线测试-$(date +%Y%m%d-%H%M%S)"; print -r -- "$DIR" > $S/dir
  dd if=/dev/urandom of=$S/baseline.bin bs=1m count=200 2>/dev/null
  dd if=/dev/urandom of=$S/stream.bin bs=1m count=256 2>/dev/null
  sum $S/baseline.bin > $S/baseline.sha; sum $S/stream.bin > $S/stream.sha
  mkdir "$DIR"
  cp $S/baseline.bin "$DIR/基线.bin"
  for i in {1..50}; do print "基线小文件 $i" > "$DIR/基线-$i.txt"; done
  [[ $(sum "$DIR/基线.bin") == $(<$S/baseline.sha) ]]
  # Longer than the stretch an unplug may take back, so the baseline is not in it.
  print '基线已写入，静置 45 秒…'; sync; sleep 45
  date +%s > $S/stream-started
  # Rewrites the same 40 files in turn for up to six hours, so there is no hurry to pull the cable.
  ( n=0; deadline=$(( $(date +%s) + 21600 ))
    while (( $(date +%s) < deadline )); do
      n=$((n+1)); i=$(( (n - 1) % 40 + 1 ))
      cp $S/stream.bin "$DIR/流-$i.bin" 2>>$S/writer.err || { print "$(date +%s) 写第 $n 次（流-$i）时出错" >> $S/progress; break; }
      print "$(date +%s) $n" >> $S/progress
    done; print "$(date +%s) 结束" >> $S/progress ) >/dev/null 2>&1 &!
  print "开始持续写入（40 个 256 MiB 的文件轮流重写，最长 6 小时）。进度：$S/progress"
  ;;
end)
  # A clean end followed at once by an unplug: the last writes may still be in
  # the drive's own cache when the power goes.
  mounted_rw || { print -u2 "$VOL 不是商店版读写挂载"; exit 1; }
  DEV=$(mount | grep " on $VOL (" | cut -d' ' -f1)
  rm -rf $S; mkdir -p $S
  DIR="$VOL/盘屿商店版拔线测试-$(date +%Y%m%d-%H%M%S)"; print -r -- "$DIR" > $S/dir
  dd if=/dev/urandom of=$S/baseline.bin bs=1m count=200 2>/dev/null
  dd if=/dev/urandom of=$S/stream.bin bs=1m count=64 2>/dev/null
  sum $S/baseline.bin > $S/baseline.sha; sum $S/stream.bin > $S/stream.sha
  mkdir "$DIR"
  cp $S/baseline.bin "$DIR/基线.bin"
  for i in {1..50}; do print "基线小文件 $i" > "$DIR/基线-$i.txt"; done
  print '基线已写入，静置 45 秒…'; sync; sleep 45
  for i in {1..6}; do cp $S/stream.bin "$DIR/流-$i.bin"; print "$(date +%s) $i" >> $S/progress; done
  diskutil unmount "$DEV" >/dev/null
  date +%s > $S/unmounted
  say '拔线' 2>/dev/null || true
  print "已正常卸载（$(date +%T)），请立即拔线"
  ;;
verify)
  DIR=$(<$S/dir)
  info=$(mount | grep " on $VOL (") || { print "结果：$VOL 没有挂载"; exit 1; }
  print "挂载：${info#* \(}"
  [[ -d $DIR ]] || { print "结果：测试文件夹不在了（基线被退回）"; exit 1; }
  ok=1
  [[ $(sum "$DIR/基线.bin") == $(<$S/baseline.sha) ]] && print 'PASS 基线大文件完好' || { print 'FAIL 基线大文件不一致'; ok=0; }
  n=0; for i in {1..50}; do [[ "$(cat "$DIR/基线-$i.txt" 2>/dev/null)" == "基线小文件 $i" ]] && n=$((n+1)); done
  [[ $n == 50 ]] && print 'PASS 50 个基线小文件完好' || { print "FAIL 基线小文件只剩 $n 个完好"; ok=0; }
  reported=$(grep -c -E '^[0-9]+ [0-9]+$' $S/progress 2>/dev/null || true)
  whole=0; broken=0; last=0
  for f in "$DIR"/流-*.bin(N); do
    i=${${f:t}#流-}; i=${i%.bin}
    if [[ $(sum "$f") == $(<$S/stream.sha) ]]; then whole=$((whole+1)); (( i > last )) && last=$i
    else broken=$((broken+1)); print "  不完整：${f:t}（$(stat -f %z "$f") 字节）"; fi
  done
  print "写入方报告完成 $reported 次；盘上完整 $whole 个（最大编号 $last），不完整 $broken 个"
  (( ok )) && print '基线检查通过' || { print '基线检查未通过'; exit 1; }
  ;;
clean)
  DIR=$(<$S/dir); mounted_rw || { print -u2 "$VOL 不是商店版读写挂载"; exit 1; }
  rm -rf "$DIR"; [[ ! -e $DIR ]] && print '已清理测试文件夹'; rm -rf $S
  ;;
esac
