#!/bin/zsh
# Store build, local test candidate: a sandboxed host plus the store extension
# (mounted by the system, no background component), Developer ID signed so it
# runs on this Mac. Not a Mac App Store submission: that needs the store
# certificates and profiles. The bundle keeps its test name so it can sit next
# to the website build in /Applications.
# Usage: scripts/store/build-local-candidate.sh   → .workbench/store/Volisle MAS Probe.app
# Test: end Volisle's write sessions and quit it, scripts/store/install-local-candidate.sh, turn on
# "盘屿 NTFS（商店测试）" under System Settings → General → Login Items & Extensions →
# File System Extensions, replug the test disk.
set -euo pipefail
cd "${0:A:h:h:h}"
W=.workbench/store; APP="$W/Volisle MAS Probe.app"; EX="$APP/Contents/Extensions/VolisleFS.appex"
PROF=${VOLISLE_STORE_PROFILE:-~/Downloads/Volisle_MAS_FS_Developer_ID_20261005.provisionprofile}
ID="Developer ID Application: <开发者> (6N5T3G6H33)"
TEAM=6N5T3G6H33; BUNDLE=top.qisw.volisle.mas; GROUP=$TEAM.$BUNDLE
[[ -f $PROF ]] || { print -u2 "找不到描述文件：$PROF"; exit 1; }
# A new build number for every local candidate, so the system never pairs one
# candidate's registration with another's declarations.
scripts/store/assemble-bundle.sh "$APP" "$(python3 -c "import json;print(json.load(open('config/store.json'))['version'])")" \
  "$(python3 -c "import json,time;print(f\"{json.load(open('config/updates.json'))['build']}.{int(time.time()) % 100000000}\")")" --test-name
cp "$PROF" "$EX/Contents/embedded.provisionprofile"
ent() { python3 -c "import plistlib,sys;sys.stdout.buffer.write(plistlib.dumps(eval(sys.argv[1])))" "$1"; }
ent "{'com.apple.application-identifier':'$TEAM.$BUNDLE.filesystem','com.apple.developer.fskit.fsmodule':True,'com.apple.developer.team-identifier':'$TEAM','com.apple.security.app-sandbox':True,'com.apple.security.application-groups':['$GROUP']}" > $W/ext.entitlements
ent "{'com.apple.security.app-sandbox':True,'com.apple.security.application-groups':['$GROUP']}" > $W/host.entitlements
ent "{'com.apple.security.application-groups':['$GROUP']}" > $W/host-tool.entitlements
codesign --force --options runtime --timestamp --sign "$ID" --entitlements $W/ext.entitlements "$EX"
codesign --force --options runtime --timestamp --sign "$ID" --entitlements $W/host.entitlements "$APP"
# Not part of the app: lets tests set the shared preference and read the extension's records.
swiftc -O scripts/store/dev-group-defaults.swift -o "$W/dev-group-defaults"
codesign --force --options runtime --sign "$ID" --entitlements $W/host-tool.entitlements "$W/dev-group-defaults"
codesign --verify --deep --strict "$APP" && echo "built: $APP"
