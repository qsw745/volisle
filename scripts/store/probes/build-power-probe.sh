#!/bin/zsh
# Builds the sandboxed power / login-item probe (power-probe.swift), Developer ID signed.
# Usage: build-power-probe.sh <output directory>   → <dir>/Volisle Power Probe.app
set -euo pipefail
cd "${0:A:h:h:h:h}"
OUT=${1:?输出目录}; APP="$OUT/Volisle Power Probe.app"
ID="Developer ID Application: <开发者> (6N5T3G6H33)"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -swift-version 6 -O -parse-as-library -target arm64-apple-macos26.4 scripts/store/probes/power-probe.swift \
  -framework IOKit -framework ServiceManagement -o "$APP/Contents/MacOS/PowerProbe" 2>&1 | grep -v "^$" || true
[[ -x "$APP/Contents/MacOS/PowerProbe" ]]
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
plistlib.dump({'CFBundleIdentifier': 'top.qisw.volisle.probe.power', 'CFBundleName': 'Volisle Power Probe',
               'CFBundleExecutable': 'PowerProbe', 'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.1',
               'CFBundleVersion': '1', 'LSMinimumSystemVersion': '26.4', 'LSUIElement': True}, open(sys.argv[1], 'wb'))
PY
python3 -c "import plistlib,sys;sys.stdout.buffer.write(plistlib.dumps({'com.apple.security.app-sandbox':True}))" > "$OUT/power-probe.entitlements"
codesign --force --options runtime --timestamp --sign "$ID" --entitlements "$OUT/power-probe.entitlements" "$APP"
codesign --verify --strict "$APP" && echo "built: $APP"
