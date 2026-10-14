#!/bin/zsh
# Assembles the unsigned Mac App Store bundle: the sandboxed app with the store
# extension inside. Shared by the local test candidate and the store package,
# so both carry the same code, declarations and resources; signing differs.
# Usage: assemble-bundle.sh <app bundle path> <version> <build> [--test-name]
#   --test-name  the extension's name in System Settings says it is a test build
set -euo pipefail
cd "${0:A:h:h:h}"
APP=${1:?应用包路径}; VERSION=${2:?版本号}; BUILD=${3:?构建号}; TESTNAME=${4:-}
[[ -z $TESTNAME || $TESTNAME == --test-name ]] || { print -u2 "未知参数：$TESTNAME"; exit 1; }
W=${APP:h}; EX="$APP/Contents/Extensions/VolisleFS.appex"
TEAM=6N5T3G6H33; BUNDLE=top.qisw.volisle.mas
# Must match StoreMountStatus.group in apps/extension/Sources/StoreMount.swift.
GROUP=$TEAM.$BUNDLE
MIN=26.4
mkdir -p "$W"
grep -q "static let group = \"$GROUP\"" apps/extension/Sources/StoreMount.swift || { print -u2 '应用组与扩展源码不一致'; exit 1; }
VOLISLE_MIN_MACOS=$MIN scripts/build-fskit-extension.sh --store
python3 -c "import json,sys;sys.exit(0 if json.load(open('.workbench/fskit-build/VolisleFS.build.json')).get('store') is True else 1)" \
  || { print -u2 '扩展不是商店版构建'; exit 1; }
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$EX/Contents/MacOS" "$EX/Contents/Resources"
mkdir -p "$APP/Contents/Resources"
# The app shares the extension's record format and keys (StoreMount.swift), nothing else.
for arch in arm64 x86_64; do
  swiftc -swift-version 6 -O -parse-as-library -target $arch-apple-macos$MIN -D VOLISLE_STORE \
    apps/store/Sources/*.swift apps/extension/Sources/StoreMount.swift \
    -framework FSKit -framework DiskArbitration -o "$W/VolisleStore-$arch"
done
lipo -create "$W/VolisleStore-arm64" "$W/VolisleStore-x86_64" -output "$APP/Contents/MacOS/VolisleStore"
rm "$W/VolisleStore-arm64" "$W/VolisleStore-x86_64"
cp apps/macos/Sources/Volisle/Resources/BrandMark.png assets/brand/Volisle.icns LICENSE "$APP/Contents/Resources/"
# Interface in Simplified and Traditional Chinese and English; keys are the Chinese source strings.
python3 scripts/check-localization.py --store
cp -R assets/brand/Localization/store/*.lproj "$APP/Contents/Resources/"
cp .workbench/fskit-build/VolisleFS "$EX/Contents/MacOS/VolisleFS"
cp LICENSE "$EX/Contents/Resources/LICENSE"
cp packages/VolisleNTFS/UPSTREAM.md "$EX/Contents/Resources/NTFS-NOTICE.md"
cp apps/extension/UPSTREAM.md "$EX/Contents/Resources/FSKit-NOTICE.md"
python3 - "$APP/Contents/Info.plist" "$EX/Contents/Info.plist" $BUNDLE $MIN "$VERSION" "$BUILD" <<'PY'
import plistlib, sys
host, ext, bundle, minimum, short, build = sys.argv[1:]
version = {'CFBundleShortVersionString': short, 'CFBundleVersion': build, 'LSMinimumSystemVersion': minimum}
# Development region en with a zh-Hans table of its own, as in the website app: a system in any other language gets English.
plistlib.dump({'CFBundleIdentifier': bundle, 'CFBundleName': 'Volisle', 'CFBundleDisplayName': 'Volisle', 'CFBundleExecutable': 'VolisleStore',
               'CFBundlePackageType': 'APPL', 'CFBundleIconFile': 'Volisle.icns', 'CFBundleDevelopmentRegion': 'en',
               'CFBundleLocalizations': ['zh-Hans', 'zh-Hant', 'en'], 'LSHasLocalizedDisplayName': True,
               'NSHighResolutionCapable': True, 'LSApplicationCategoryType': 'public.app-category.utilities',
               'NSHumanReadableCopyright': 'Copyright © 2026 <开发者>. GNU GPL v2.',
               # Hashes and message authentication only (the write journal); the store build carries no cipher code.
               'ITSAppUsesNonExemptEncryption': False, **version}, open(host, 'wb'))
# The system picks a module for a disk from FSMediaTypes; the website build declares none (its helper mounts by name).
# After any change under EXAppExtensionAttributes the system stops listing an installed module (2026-10-11,
# macOS 27.2: "No extension with fsShortName"), by earlier experience until the next login, and its owner has to
# switch it on again. These are meant to be final for the first release; every key is one the system's own
# msdos/exfat modules or another shipping NTFS module declares.
# Probe order: lower goes first. The system's read-only NTFS has 2000 (GPT basic data), 1000 (MBR NTFS) and
# 4000 (no partition table); APFS and HFS claim whole disks at 1000 and 2000.
media = lambda hint, order: {'FSMediaProperties': {'Content Hint': hint, 'Leaf': True}, 'FSProbeOrder': order}
plistlib.dump({'CFBundleDevelopmentRegion': 'en', 'CFBundleLocalizations': ['zh-Hans', 'zh-Hant', 'en'],
               'CFBundleExecutable': 'VolisleFS', 'CFBundleIdentifier': bundle + '.filesystem',
               'CFBundleName': 'VolisleFS', 'CFBundleDisplayName': 'Volisle NTFS', 'CFBundlePackageType': 'XPC!', **version,
               'EXAppExtensionAttributes': {
                   'EXExtensionPointIdentifier': 'com.apple.fskit.fsmodule',
                   # FSShortName is the mount type; NTFSVolume reports the same name for the store build.
                   'FSShortName': 'volislemas',
                   'FSPersonalities': {'NTFS': {'FSName': 'Volisle NTFS', 'FSSubType': 0}},
                   'FSSupportsBlockResources': True, 'FSSupportsKernelOffloadedIO': False, 'FSSupportsGenericURLResources': False,
                   'FSSupportsPathURLs': False, 'FSSupportsServerURLs': False,
                   'FSVolumeAlwaysIgnoreOwnership': True,
                   'FSActivateOptionSyntax': {'shortOptions': 'o:'},
                   # Flags only. An option syntax that takes arguments made macOS 26 drop the whole module.
                   'FSCheckOptionSyntax': {'shortOptions': 'nqy'},
                   'FSMediaTypes': {'EBD0A0A2-B9E5-4433-87C0-68B6B72699C7': media('EBD0A0A2-B9E5-4433-87C0-68B6B72699C7', 100),
                                    'Windows_NTFS': media('Windows_NTFS', 100),
                                    # NTFS on a disk with no partition table. The probe still requires an NTFS boot sector.
                                    'Partitionless': {'FSMediaProperties': {'Leaf': True, 'Whole': True}, 'FSProbeOrder': 3900}}}},
              open(ext, 'wb'))
PY
# The extension's name in System Settings. A local candidate says so: on a Mac that also has the
# website build, two entries both called "盘屿 NTFS" cannot be told apart.
python3 - "$EX/Contents/Resources" "$TESTNAME" <<'PY'
import pathlib, re, sys
suffix = {'en': ' (Store Test)', 'zh-Hans': '（商店测试）', 'zh-Hant': '（商店測試）'} if sys.argv[2] else dict.fromkeys(('en', 'zh-Hans', 'zh-Hant'), '')
for source in sorted(pathlib.Path('assets/brand/Localization/store-extension').glob('*.lproj')):
    target = pathlib.Path(sys.argv[1]) / source.name
    target.mkdir()
    text = (source / 'InfoPlist.strings').read_text(encoding='utf-8')
    text, count = re.subn(r'("CFBundleDisplayName" = "[^"]*)(";)', lambda m: m.group(1) + suffix[source.stem] + m.group(2), text)
    assert count == 1, source
    (target / 'InfoPlist.strings').write_text(text, encoding='utf-8')
    # The one message the extension shows (Disk Utility's First Aid log).
    (target / 'Localizable.strings').write_bytes((source / 'Localizable.strings').read_bytes())
PY
