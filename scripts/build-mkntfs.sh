#!/bin/zsh
# Compile NTFS-3G's mkntfs (patched to format a host-provided device) into
# objects under .workbench/fskit-build/mkntfs/. Sources come from the pinned
# NTFS-3G tree; the only change is packages/VolisleNTFS/patches/mkntfs-external-device.patch.
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
source_dir="$project_root/.workbench/ntfs-3g-2026.7.7"
if [[ ! -f "$source_dir/libntfs-3g/.libs/libntfs-3g.a" ]]; then
  python3 scripts/prepare-ntfs-probe.py
fi
out=.workbench/fskit-build/mkntfs
rm -rf "$out"
mkdir -p "$out/ntfsprogs"
files=(mkntfs.c utils.c utils.h attrdef.c attrdef.h boot.c boot.h sd.c sd.h)
for file in $files; do cp "$source_dir/ntfsprogs/$file" "$out/ntfsprogs/"; done
patch --quiet --forward -p1 -d "$out" < packages/VolisleNTFS/patches/mkntfs-external-device.patch
grep -q 'nk_mkntfs_main' "$out/ntfsprogs/mkntfs.c" || { print -u2 'mkntfs 补丁未生效'; exit 1; }
for file in mkntfs.c utils.c attrdef.c boot.c sd.c; do
  clang -target arm64-apple-macos26.4 -c -fPIC -DHAVE_CONFIG_H -w \
    -I "$source_dir" -I "$source_dir/include" -I "$source_dir/include/ntfs-3g" -I "$out/ntfsprogs" \
    "$out/ntfsprogs/$file" -o "$out/${file:r}.o"
done
print "$out"
