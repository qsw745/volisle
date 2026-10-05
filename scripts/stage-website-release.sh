#!/bin/zsh
# Build the website for https://qisw.top/volisle/ and stage it together with a
# verified release (DMG, source, signed update feed and archive). Local only:
# uploads nothing. Usage: scripts/stage-website-release.sh <release-dir> <stage-dir>
#   <release-dir> holds signed-dmg/, package/ and update-release/ (see notarize-release.sh
#   and prepare-update-release.py).
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
release="${1:A}" stage="${2:A}"
[[ ! -e "$stage" ]] || { print -u2 '暂存目录已存在，保留旧产物'; exit 1; }
dmg=$(ls "$release"/signed-dmg/Volisle-*-arm64.dmg)
source_tgz=$(ls "$release"/package/Volisle-*-source.tar.gz)
updates="$release/update-release"
[[ -f "$dmg" && -f "$source_tgz" && -f "$updates/appcast.xml" ]] || { print -u2 '发行目录不完整'; exit 1; }

# The feed shipped in public/ must be the signed one, byte for byte.
cmp -s "$updates/appcast.xml" apps/web/public/updates/appcast.xml || { print -u2 'public/updates/appcast.xml 不是本次签名的更新目录'; exit 1; }
xcrun stapler validate "$dmg" >/dev/null
spctl -a -t open --context context:primary-signature "$dmg" 2>/dev/null || { print -u2 'DMG 未通过 Gatekeeper 评估'; exit 1; }

# Website hashes must describe exactly these files.
dmg_sha=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
source_sha=$(shasum -a 256 "$source_tgz" | cut -d' ' -f1)
grep -q "dmgSha256: '$dmg_sha'" apps/web/lib/release.ts || { print -u2 'release.ts 中的 DMG 摘要不符'; exit 1; }
grep -q "sourceSha256: '$source_sha'" apps/web/lib/release.ts || { print -u2 'release.ts 中的源码摘要不符'; exit 1; }
grep -q "dmg: '/downloads/${dmg:t}'" apps/web/lib/release.ts || { print -u2 'release.ts 中的 DMG 文件名不符'; exit 1; }
grep -q "source: '/downloads/${source_tgz:t}'" apps/web/lib/release.ts || { print -u2 'release.ts 中的源码文件名不符'; exit 1; }

(cd apps/web && pnpm -s lint && pnpm -s typecheck && NEXT_PUBLIC_BASE_PATH=/volisle pnpm -s build >/dev/null)
python3 scripts/verify-web.py >/dev/null

mkdir -p "$stage"
cp -R apps/web/out/. "$stage/"
mkdir -p "$stage/downloads"
cp "$dmg" "$source_tgz" "$stage/downloads/"
(cd "$updates" && shasum -a 256 -c SHA256SUMS >/dev/null)
cp "$updates"/Volisle-*-arm64.zip "$updates"/Volisle-*-source.tar.gz "$stage/updates/"
cmp -s "$updates/appcast.xml" "$stage/updates/appcast.xml"

# Every URL inside the feed must resolve to a staged file.
python3 - "$stage" <<'PY'
import sys, xml.etree.ElementTree as ET
from pathlib import Path
stage = Path(sys.argv[1]); prefix = 'https://qisw.top/volisle/'
feed = ET.parse(stage / 'updates/appcast.xml')
for enclosure in feed.iter('enclosure'):
    url = enclosure.get('url'); assert url.startswith(prefix), url
    path = stage / url[len(prefix):]
    assert path.is_file() and path.stat().st_size == int(enclosure.get('length')), url
PY
(cd "$stage" && find . -type f ! -name MANIFEST.sha256 | LC_ALL=C sort | xargs shasum -a 256 > MANIFEST.sha256)
print "已暂存：$stage（$(wc -l < "$stage/MANIFEST.sha256" | tr -d ' ') 个文件，$(du -sh "$stage" | cut -f1)）；尚未上传。"
