#!/bin/zsh
# What an app update does to a volume the store extension has mounted read-write.
# Works on a copy of the GPT test image, never on a physical disk: an extension the
# system ends leaves its volume stuck in the kernel until restart.
#   test-update-while-mounted.sh start    attach a copy, let the store extension mount it, keep writing
#   (update the app in TestFlight while it writes)
#   test-update-while-mounted.sh report   what the system did, which writes survived
#   test-update-while-mounted.sh clean    stop writing, eject and delete the copy (only if it can be ejected)
set -euo pipefail
cd "${0:A:h:h:h}"
MODE=${1:?start | report | clean}
W=.workbench/store-test/update; IMG=$W/gpt-update.img; mkdir -p $W
case $MODE in
start)
  [[ ! -e $IMG ]] || { print -u2 "上一轮还没清理：$0 clean"; exit 1; }
  cp .workbench/store-test/gpt.img $IMG
  dev=$(diskutil image attach --noMount $IMG 2>/dev/null | awk '/Microsoft Basic Data/{print $1}')
  [[ -n $dev ]] || { print -u2 '镜像没有附加上'; exit 1; }
  print $dev > $W/dev
  sleep 3
  [[ $(mount) == *"$dev on "* ]] || diskutil mount $dev >/dev/null
  info=$(mount | grep "^$dev on ") || { print -u2 "$dev 没有挂载"; exit 1; }
  [[ $info == *'(volislemas,'* && $info != *read-only* ]] || { print -u2 "不是商店版读写挂载：$info"; exit 1; }
  vol=${${info#$dev on }%% \(*}; print $vol > $W/vol
  date "+%Y-%m-%d %H:%M:%S" > $W/started
  : > $W/written
  # One small file every half second; a number is recorded only after its file is closed.
  nohup zsh -c '
    n=0; while [[ -d "$1" ]]; do
      n=$((n + 1))
      print "写入 $n $(date +%T.%N)" > "$1/seq-$n.txt" 2>/dev/null || exit 0
      print $n >> "$2"; sleep 0.5
    done' writer "$vol" $PWD/$W/written >/dev/null 2>&1 &
  print $! > $W/writer.pid
  print "镜像 $dev 由商店版读写挂载在 $vol，正在持续写入；现在可以在 TestFlight 里更新"
  ;;
report)
  vol=$(<$W/vol); since=$(<$W/started)
  print "== 记录到已写完的文件：$(wc -l < $W/written | tr -d ' ') 个，最后一个 $(tail -1 $W/written)"
  print "== 挂载表"; mount | grep "^$(<$W/dev) " || print '（没有挂载）'
  print "== 卷是否还能读"; ls "$vol" > /dev/null 2>&1 && print "能读，seq 文件 $(ls "$vol" | grep -c '^seq-') 个" || print '读不了'
  print "== 系统对商店版做了什么"
  /usr/bin/log show --start "$since" --style compact --predicate '(process == "lsd" AND eventMessage CONTAINS "top.qisw.volisle.mas") OR (process == "launchd" AND eventMessage CONTAINS "top.qisw.volisle.mas.filesystem") OR (subsystem BEGINSWITH "Volisle") OR (process == "VolisleFS" AND (eventMessage CONTAINS "kernelForceUnmount" OR eventMessage CONTAINS "SIGTERM")) OR (process == "fskit_agent" AND eventMessage CONTAINS "SIGKILL")' 2>/dev/null \
    | grep -v '^Timestamp' | cut -c1-220 | awk '!seen[substr($0, 24)]++' | head -60
  ;;
clean)
  [[ -f $W/writer.pid ]] && kill $(<$W/writer.pid) 2>/dev/null || true
  dev=$(<$W/dev)
  # A stuck volume is left alone: forcing it makes things worse. Restart, then run clean again.
  diskutil eject ${dev%s1} || { print -u2 '推不出：卷可能卡在内核里，重启后再清理'; exit 1; }
  rm -rf $W
  print '已清理'
  ;;
*) print -u2 "未知操作：$MODE"; exit 1 ;;
esac
