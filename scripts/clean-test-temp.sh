#!/bin/zsh
# Lists, and with --yes removes, the temporary folders test scripts leave in
# .workbench when a run fails or is killed (write-journal-XXXXXXXX,
# create-safety-XXXXXXXX, ...). Only folders that look exactly like
# tempfile.mkdtemp output are touched: <name>-<8 random [a-z0-9_]>, mode 700.
# Never touched: *-fixtures, dated folders (…-20260925), anything else in
# .workbench (ntfs-3g source, fskit-build, sparkle, …), folders changed in the
# last 30 minutes (a test may still be running) and folders backing an
# attached disk image.
#   clean-test-temp.sh         list only
#   clean-test-temp.sh --yes   remove the listed folders
set -euo pipefail
zmodload zsh/stat
workbench="${0:A:h:h}/.workbench"
remove=false
case "${1:-}" in
  --yes) remove=true ;;
  '') ;;
  *) echo "用法：$0 [--yes]" >&2; exit 2 ;;
esac
[[ -d "$workbench" ]] || { echo "没有 $workbench"; exit 0; }

attached=$(/usr/bin/hdiutil info 2>/dev/null | sed -n 's/^image-path *: //p') \
  || { echo "无法读取 hdiutil info，为安全起见不清理" >&2; exit 1; }

candidates=() total=0
for dir in "$workbench"/*(N/); do
  name="${dir:t}"
  [[ "$name" == *-fixtures ]] && continue
  [[ "$name" =~ '^[A-Za-z0-9._-]+-([a-z0-9_]{8})$' ]] || continue
  [[ "${match[1]}" == <-> ]] && continue                   # dated, e.g. -20260925
  [[ -L "$dir" ]] && continue
  [[ "$(zstat -L +mode -o "$dir")" == 040700 ]] || continue  # mkdtemp creates 0700
  if [[ -n "$(find "$dir" -mmin -30 -print -quit 2>/dev/null)" ]]; then
    echo "跳过（30 分钟内有改动，可能仍在运行）：$name"; continue
  fi
  if print -r -- "$attached" | grep -qF -- "$dir/"; then
    echo "跳过（其中有镜像仍挂接）：$name"; continue
  fi
  kib=$(du -sk "$dir" | cut -f1)
  total=$((total + kib))
  printf '%8s  %s\n' "$(du -sh "$dir" | cut -f1)" "$name"
  candidates+=("$name")
done

if (( ${#candidates} == 0 )); then
  echo "没有可清理的测试临时目录。"; exit 0
fi
printf '共 %d 个，约 %d MiB。\n' ${#candidates} $((total / 1024))
if ! $remove; then
  echo "确认删除请加 --yes。"; exit 0
fi
for name in "${candidates[@]}"; do
  rm -rf -- "${workbench:?}/${name:?}"
done
echo "已删除。"
