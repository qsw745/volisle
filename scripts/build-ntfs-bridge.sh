#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
source_dir="$project_root/.workbench/ntfs-3g-2026.7.7"
if [[ ! -f "$source_dir/libntfs-3g/.libs/libntfs-3g.a" ]]; then
  python3 scripts/prepare-ntfs-probe.py
fi
# This disposable-image test library is not bundled into the application.
scripts/build-mkntfs.sh >/dev/null
scripts/build-ntfsrecover.sh >/dev/null
clang -shared -fPIC -DHAVE_CONFIG_H -DNK_WITH_FORMAT=1 -DNK_EXPERIMENTAL_REPLACEMENT=1 -DNK_EXPERIMENTAL_PRIVATE_MODES=1 \
  -I "$source_dir" -I "$source_dir/include" \
  packages/VolisleNTFS/bridge/ntfs_bridge.c \
  .workbench/fskit-build/mkntfs/*.o \
  .workbench/fskit-build/ntfsrecover/*.o \
  "$source_dir/libntfs-3g/.libs/libntfs-3g.a" \
  -framework CoreFoundation -o .workbench/libVolisleNTFS.dylib
