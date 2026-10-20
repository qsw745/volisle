#!/bin/zsh
# Builds the Mac App Store submission: the same bundle as the local candidate,
# signed with the store certificates and profiles, wrapped in a signed installer
# package. Everything is built on this Mac; nothing is uploaded here.
# Usage: scripts/store/build-store-package.sh <build number>
#   → dist/store/Volisle-<version>-store<build>/Volisle.pkg
# Needs two Mac App Store provisioning profiles (developer portal → Profiles →
# Mac App Store Connect), named by VOLISLE_STORE_APP_PROFILE and
# VOLISLE_STORE_EXT_PROFILE, in the environment or config/release.local.env:
#   top.qisw.volisle.mas             the app
#   top.qisw.volisle.mas.filesystem  the extension, with the FSKit Module capability
# A bundle signed this way does not launch on this Mac: store profiles name no
# device. It runs once the App Store or TestFlight has re-signed it.
set -euo pipefail
cd "${0:A:h:h:h}"
BUILD=${1:?构建号（整数，每次提交递增）}
[[ $BUILD == <-> ]] || { print -u2 "构建号必须是整数：$BUILD"; exit 1; }
[[ -f config/release.local.env ]] && source config/release.local.env
for name in VOLISLE_STORE_APP_PROFILE VOLISLE_STORE_EXT_PROFILE; do
  [[ -n ${(P)name:-} && -f ${(P)name} ]] || { print -u2 "缺少商店描述文件：请把 $name 设为文件路径（见本脚本开头的说明）"; exit 1; }
done
APP_ID="3rd Party Mac Developer Application: <开发者> (6N5T3G6H33)"
PKG_ID="3rd Party Mac Developer Installer: <开发者> (6N5T3G6H33)"
TEAM=6N5T3G6H33; BUNDLE=top.qisw.volisle.mas; GROUP=$TEAM.$BUNDLE
# The store build has its own version line (config/store.json), apart from the website build's.
VERSION=$(python3 -c "import json;print(json.load(open('config/store.json'))['version'])")
# Not Volisle.app: that is the website build's name in /Applications, and a store
# install must neither replace it nor be refused because of it. Finder and the Dock
# use the same 盘屿 Volisle brand in every localization.
W=.workbench/store-package; APP="$W/盘屿 Volisle.app"; EX="$APP/Contents/Extensions/VolisleFS.appex"
OUT="dist/store/Volisle-$VERSION-store$BUILD"
[[ ! -e $OUT ]] || { print -u2 "已经存在：$OUT（换一个构建号，提交过的构建号不能重用）"; exit 1; }
for identity in $APP_ID $PKG_ID; do
  security find-identity -v | grep -qF "\"$identity\"" || { print -u2 "钥匙串里没有证书：$identity"; exit 1; }
done

# A profile for the wrong identifier, without the capability, expired or for
# development only fails at upload or, worse, at review: check here.
python3 - "$VOLISLE_STORE_APP_PROFILE" "$VOLISLE_STORE_EXT_PROFILE" $TEAM $BUNDLE <<'PY'
import datetime, plistlib, subprocess, sys
app, ext, team, bundle = sys.argv[1:]
def load(path):
    return plistlib.loads(subprocess.run(['security', 'cms', '-D', '-i', path], capture_output=True, check=True).stdout)
problems = []
for path, identifier, fskit in ((app, bundle, False), (ext, bundle + '.filesystem', True)):
    profile = load(path); grants = profile.get('Entitlements', {})
    if grants.get('com.apple.application-identifier') != f'{team}.{identifier}':
        problems.append(f'{path}: 不是 {identifier} 的描述文件')
    if 'ProvisionedDevices' in profile or profile.get('ProvisionsAllDevices'):
        problems.append(f'{path}: 不是 Mac App Store 类型的描述文件')
    if 'OSX' not in profile.get('Platform', []):
        problems.append(f'{path}: 不是 macOS 平台')
    if profile['ExpirationDate'] <= datetime.datetime.now():
        problems.append(f'{path}: 已过期')
    if fskit and grants.get('com.apple.developer.fskit.fsmodule') is not True:
        problems.append(f'{path}: 没有 FSKit Module 能力')
if problems:
    sys.exit('\n'.join(problems))
PY

rm -rf $W
scripts/store/assemble-bundle.sh "$APP" "$VERSION" "$BUILD"
cp "$VOLISLE_STORE_APP_PROFILE" "$APP/Contents/embedded.provisionprofile"
cp "$VOLISLE_STORE_EXT_PROFILE" "$EX/Contents/embedded.provisionprofile"
ent() { python3 -c "import plistlib,sys;sys.stdout.buffer.write(plistlib.dumps(eval(sys.argv[1])))" "$1"; }
ent "{'com.apple.application-identifier':'$TEAM.$BUNDLE.filesystem','com.apple.developer.team-identifier':'$TEAM','com.apple.developer.fskit.fsmodule':True,'com.apple.security.app-sandbox':True,'com.apple.security.application-groups':['$GROUP']}" > $W/ext.entitlements
ent "{'com.apple.application-identifier':'$TEAM.$BUNDLE','com.apple.developer.team-identifier':'$TEAM','com.apple.security.app-sandbox':True,'com.apple.security.application-groups':['$GROUP']}" > $W/host.entitlements
codesign --force --options runtime --timestamp --sign "$APP_ID" --entitlements $W/ext.entitlements "$EX"
codesign --force --options runtime --timestamp --sign "$APP_ID" --entitlements $W/host.entitlements "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p "$OUT"
productbuild --component "$APP" /Applications --sign "$PKG_ID" "$OUT/Volisle.pkg"
pkgutil --check-signature "$OUT/Volisle.pkg" | sed -n 1,4p
shasum -a 256 "$OUT/Volisle.pkg" > "$OUT/Volisle.pkg.sha256"
print "built: $OUT/Volisle.pkg（版本 $VERSION，构建 $BUILD）"
print '下一步（未执行）：xcrun altool --validate-app -f <pkg> -t macos --apiKey … --apiIssuer …，核对通过后再 --upload-app'
