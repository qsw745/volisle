#!/bin/zsh
# Build the NTFS format engine (bridge + patched mkntfs + libntfs-3g) as one
# static library. Only the root helper links it; the app and extension do not.
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
source_dir="$project_root/.workbench/ntfs-3g-2026.7.7"
scripts/build-mkntfs.sh >/dev/null
out=.workbench/format-engine
rm -rf "$out"
mkdir -p "$out"
clang -target "arm64-apple-macos${VOLISLE_MIN_MACOS:-15.4}" -c -fPIC -DHAVE_CONFIG_H -DNK_WITH_FORMAT=1 -I "$source_dir" -I "$source_dir/include" \
  packages/VolisleNTFS/bridge/ntfs_bridge.c -o "$out/ntfs_bridge.o"
libtool -static -no_warning_for_no_symbols -o "$out/libvolisleformat.a" \
  "$out/ntfs_bridge.o" .workbench/fskit-build/mkntfs/*.o "$source_dir/libntfs-3g/.libs/libntfs-3g.a"
print "$out/libvolisleformat.a"
