#!/bin/zsh
# Compile NTFS-3G's ntfsrecover (replays a Windows $LogFile) into objects under
# .workbench/fskit-build/ntfsrecover/. Sources come from the pinned NTFS-3G
# tree; the only change is packages/VolisleNTFS/patches/ntfsrecover-external-device.patch
# (the helper's device instead of a path, main renamed, no exit()).
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
source_dir="$project_root/.workbench/ntfs-3g-2026.7.7"
if [[ ! -f "$source_dir/libntfs-3g/.libs/libntfs-3g.a" ]]; then
  python3 scripts/prepare-ntfs-probe.py
fi
out=.workbench/fskit-build/ntfsrecover
rm -rf "$out"
mkdir -p "$out/ntfsprogs"
for file in ntfsrecover.c ntfsrecover.h playlog.c; do cp "$source_dir/ntfsprogs/$file" "$out/ntfsprogs/"; done
patch --quiet --forward -p1 -d "$out" < packages/VolisleNTFS/patches/ntfsrecover-external-device.patch
grep -q 'nk_ntfsrecover_main' "$out/ntfsprogs/ntfsrecover.c" || { print -u2 'ntfsrecover 补丁未生效'; exit 1; }
for file in ntfsrecover.c playlog.c; do
  clang -target "arm64-apple-macos${VOLISLE_MIN_MACOS:-15.4}" -c -fPIC -DHAVE_CONFIG_H -w \
    -I "$source_dir" -I "$source_dir/include" -I "$source_dir/include/ntfs-3g" -I "$out/ntfsprogs" -I "$source_dir/ntfsprogs" \
    "$out/ntfsprogs/$file" -o "$out/${file:r}.o"
done
print "$out"
