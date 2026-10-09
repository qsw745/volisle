#!/bin/zsh
# Compiles an isolated module only. Does not register, install, sign, or mount it.
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
source_dir="$project_root/.workbench/ntfs-3g-2026.7.7"
if [[ ! -f "$source_dir/libntfs-3g/.libs/libntfs-3g.a" ]]; then
  python3 scripts/prepare-ntfs-probe.py
fi
mkdir -p .workbench/fskit-build
# The oldest macOS this build runs on; an explicit override remains available.
min_macos="${VOLISLE_MIN_MACOS:-15.4}"
[[ "$min_macos" =~ '^[0-9]+\.[0-9]+$' ]] || { print -u2 "VOLISLE_MIN_MACOS 格式错误：$min_macos"; exit 1; }
extra_flags=()
c_flags=()
replacement=false
private_permissions=false
physical=false
daily=false
if (( $# == 1 )) && [[ "$1" == "--daily-write" ]]; then
  extra_flags=(-D VOLISLE_DAILY_WRITES)
  daily=true
elif (( $# == 2 )) && [[ "$1" == "--physical-test" ]]; then
  python3 scripts/physical_test_binding.py "$2" .workbench/fskit-build/PhysicalTestTarget.swift
  extra_flags=(-D VOLISLE_PHYSICAL_TEST .workbench/fskit-build/PhysicalTestTarget.swift)
  physical=true
elif (( $# > 0 )); then
  if (( $# < 2 )) || [[ "$1" != "--write-fixture" ]]; then
    print -u2 '实验构建必须提供 --write-fixture 新建镜像目录'; exit 1
  fi
  python3 scripts/fskit_fixture.py "$2" .workbench/fskit-build/ExperimentalFixture.swift
  extra_flags=(-D VOLISLE_EXPERIMENTAL_WRITES .workbench/fskit-build/ExperimentalFixture.swift)
  for flag in "${@:3}"; do
    if [[ "$flag" == "--experimental-replacement" && "$replacement" == false ]]; then
      replacement=true
      c_flags+=(-DNK_EXPERIMENTAL_REPLACEMENT=1)
      extra_flags+=(-D VOLISLE_EXPERIMENTAL_REPLACEMENT)
    elif [[ "$flag" == "--experimental-private-permissions" && "$private_permissions" == false ]]; then
      private_permissions=true
      c_flags+=(-DNK_EXPERIMENTAL_PRIVATE_MODES=1)
      extra_flags+=(-D VOLISLE_EXPERIMENTAL_PRIVATE_PERMISSIONS)
    else
      print -u2 '未知或重复的实验开关'; exit 1
    fi
  done
fi
clang "${c_flags[@]}" -arch arm64 -arch x86_64 -mmacosx-version-min="$min_macos" -c -fPIC -DHAVE_CONFIG_H -I "$source_dir" -I "$source_dir/include" \
  packages/VolisleNTFS/bridge/ntfs_bridge.c -o .workbench/fskit-build/ntfs_bridge.o
# One slice per architecture (swiftc builds one at a time), then one universal binary.
for arch in arm64 x86_64; do
  swiftc -swift-version 6 -parse-as-library -application-extension -target "$arch-apple-macos$min_macos" \
    "${extra_flags[@]}" \
    -import-objc-header packages/VolisleNTFS/bridge/ntfs_bridge.h \
    apps/extension/Sources/*.swift packages/VolisleCore/Sources/VolisleCore/ReplacementJournal.swift .workbench/fskit-build/ntfs_bridge.o \
    "$source_dir/libntfs-3g/.libs/libntfs-3g.a" \
    -framework FSKit -framework ExtensionFoundation -framework CoreFoundation \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o .workbench/fskit-build/VolisleFS-$arch
done
lipo -create .workbench/fskit-build/VolisleFS-arm64 .workbench/fskit-build/VolisleFS-x86_64 -output .workbench/fskit-build/VolisleFS
rm .workbench/fskit-build/VolisleFS-arm64 .workbench/fskit-build/VolisleFS-x86_64
python3 scripts/verify-extension-entry.py
# Default builds remain read-only; experimental builds bind one tiny fixture.
python3 - "$#" "$replacement" "$physical" "$daily" "$private_permissions" "$min_macos" <<'PY'
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys
binary = Path('.workbench/fskit-build/VolisleFS')
receipt = {
    'target': 'arm64+x86_64-apple-macos' + sys.argv[6],
    'experimental_writes': sys.argv[1] != '0' and sys.argv[4] != 'true',
    'daily_writes': sys.argv[4] == 'true',
    'experimental_private_permissions': sys.argv[5] == 'true',
    'experimental_replacement': sys.argv[2] == 'true',
    'entry_point': '_NSExtensionMain',
    'built_at': datetime.now(timezone.utc).isoformat(),
    'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
}
if sys.argv[3] == 'true':
    receipt['physical_test'] = json.loads(Path('.workbench/fskit-build/PhysicalTestTarget.json').read_text())
elif receipt['experimental_writes']:
    receipt['fixture'] = json.loads(Path('.workbench/fskit-build/ExperimentalFixture.json').read_text())
binary.with_suffix('.build.json').write_text(json.dumps(receipt, indent=2) + '\n')
PY
