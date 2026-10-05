#!/bin/zsh
# Notarize a signed candidate via scripts/notarize-release.sh, then sign, notarize
# and staple its DMG. Usage: <candidate.app> <dist/Volisle-x.y.z-buildN> [issuer-id]
# (the issuer defaults to VOLISLE_NOTARY_ISSUER from config/release.local.env)
set -euo pipefail
cd "${0:A:h:h:h}"
source scripts/release/local-config.sh
cand=$1 out=$2 issuer=${3:-$VOLISLE_NOTARY_ISSUER}
scripts/notarize-release.sh "$cand" "$out" "$issuer"
mkdir -p "$out/signed-dmg"
hdiutil convert "$out"/package/Volisle-*-arm64.dmg -format UDZO -o "$out/signed-dmg/$(basename "$out"/package/Volisle-*-arm64.dmg)" >/dev/null
dmg=$(ls "$out"/signed-dmg/Volisle-*-arm64.dmg)
codesign --sign "$VOLISLE_SIGN_IDENTITY" --timestamp "$dmg"
codesign --verify "$dmg"
xcrun notarytool submit "$dmg" --key "$VOLISLE_NOTARY_KEY" --key-id "$VOLISLE_NOTARY_KEY_ID" --issuer "$issuer" --wait --output-format json > "$out/signed-dmg/notary.json"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['status'], d['id']); sys.exit(0 if d['status']=='Accepted' else 1)" "$out/signed-dmg/notary.json"
xcrun stapler staple "$dmg" && xcrun stapler validate "$dmg"
shasum -a 256 "$dmg"
