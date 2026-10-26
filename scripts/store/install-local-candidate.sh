#!/bin/zsh
# Replaces the store test candidate in /Applications with the one just built
# (scripts/store/build-local-candidate.sh). The extension's switch in System
# Settings is kept; turning it on the first time stays a manual step.
set -euo pipefail
cd "${0:A:h:h:h}"
NAME="Volisle MAS Probe.app"; SRC=".workbench/store/$NAME"; DST="/Applications/$NAME"
EXT="Contents/Extensions/VolisleFS.appex"
[[ -d $SRC ]] || { print -u2 "还没有构建：$SRC"; exit 1; }
# An extension process that loses its mounted volume leaves the volume stuck in
# the kernel until restart. The whole output first: a pipe into `grep -q` can
# end early and, under pipefail, read as "nothing mounted".
nothing_mounted() { local table; table=$(mount); [[ $table != *'(volislemas,'* ]] }
nothing_mounted || { print -u2 '还有商店版挂载的卷，先推出再安装'; exit 1; }
pkill -f "$DST/Contents/MacOS/" || true
rm -rf "$DST"
cp -R "$SRC" "$DST"
# FSKit keeps an idle instance of the replaced copy alive to answer probes, and it
# ignores a polite termination. Give instances that are finishing an unmount a
# moment to leave on their own, and look at the mount table again before ending the rest.
pkill -f "$DST/$EXT/" || true
sleep 2
nothing_mounted || { print -u2 '安装期间有卷被旧扩展挂上了：推出它，再重新运行本脚本'; exit 1; }
pkill -9 -f "$DST/$EXT/" || true
open -g "$DST"
sleep 3
cmp -s "$SRC/$EXT/Contents/MacOS/VolisleFS" "$DST/$EXT/Contents/MacOS/VolisleFS" || { print -u2 '装上的扩展与构建结果不一致'; exit 1; }
print "installed: $DST"
