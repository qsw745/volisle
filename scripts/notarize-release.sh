#!/bin/zsh
# Notarize and staple a signed candidate, then rebuild and notarize its DMG.
# Local only: uploads to Apple's notary service, publishes nothing.
# Usage: scripts/notarize-release.sh <signed-candidate.app> <output-dir> <issuer-uuid>
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
app="${1:A}" out="${2:A}" issuer="$3"
source scripts/release/local-config.sh
key_id=$VOLISLE_NOTARY_KEY_ID
key=$VOLISLE_NOTARY_KEY
[[ -d "$app" && -f "$key" ]] || { print -u2 '缺少签名候选或 API 密钥文件'; exit 1; }
[[ "$issuer" =~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' ]] || { print -u2 'Issuer ID 格式不正确'; exit 1; }
[[ ! -e "$out" ]] || { print -u2 '输出目录已存在，保留旧产物'; exit 1; }
mkdir -p "$out"
auth=(--key "$key" --key-id "$key_id" --issuer "$issuer")

submit() {  # $1 file, $2 label
  xcrun notarytool submit "$1" "${auth[@]}" --wait --output-format json > "$out/notary-$2.json"
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('status')=='Accepted' else 1)" "$out/notary-$2.json" \
    || { xcrun notarytool log "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['id'])" "$out/notary-$2.json")" "${auth[@]}" "$out/notary-$2-log.json" || true
         print -u2 "公证未通过：$2，详见 $out"; exit 1; }
}

codesign --verify --deep --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/app.zip"
submit "$out/app.zip" app
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"

python3 scripts/package-local-candidate.py --candidate "$app" --output-dir "$out/package"
dmg=$(ls "$out"/package/Volisle-*-arm64.dmg)
submit "$dmg" dmg
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
python3 - "$out" "$dmg" <<'PY'
import hashlib, json, sys
from pathlib import Path
out, dmg = Path(sys.argv[1]), Path(sys.argv[2])
delivery = json.loads((out/'package/delivery.json').read_text())
delivery.update(notarized=True, stapled=True, dmg_sha256=hashlib.sha256(dmg.read_bytes()).hexdigest())
(out/'package/delivery.json').write_text(json.dumps(delivery, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(delivery, ensure_ascii=False, indent=2))
PY
