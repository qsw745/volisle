#!/bin/zsh
# try.sh <png> [wait]: builds the store host alone into a throwaway bundle (arm64, ad-hoc, no sandbox),
# with TRY_STATE forcing the extension state and TRY_PATCH patching the copied sources (layout checks only),
# opens it and captures its window, but only if it really is in front.
set -e
# Works in a throwaway folder (VOLISLE_SHOT_DIR, default a new temporary one); the patches and window-numbers.swift sit next to this script.
H=${0:A:h}; S=${VOLISLE_SHOT_DIR:-$(mktemp -d)}; A=$S/VolisleTry.app; cd ${0:A:h:h:h:h}
[[ -x $S/winid ]] || swiftc -O -o $S/winid $H/window-numbers.swift
pkill -f "$A/Contents/MacOS/" || true
rm -rf $A $S/try-src; mkdir -p $A/Contents/MacOS $A/Contents/Resources; cp -R apps/store/Sources $S/try-src
[[ -n ${TRY_STATE:-} ]] && python3 -c "import pathlib,sys;p=pathlib.Path(sys.argv[1]);t=p.read_text();old='Task { @MainActor in self.extensionState = state }';assert old in t;p.write_text(t.replace(old,'Task { @MainActor in self.extensionState = .'+sys.argv[2]+' }'))" $S/try-src/StoreDisks.swift $TRY_STATE
[[ -n ${TRY_PATCH:-} ]] && python3 $TRY_PATCH $S/try-src
swiftc -swift-version 6 -Onone -parse-as-library -target arm64-apple-macos26.4 -D VOLISLE_STORE \
  $S/try-src/*.swift apps/extension/Sources/StoreMount.swift -framework FSKit -framework DiskArbitration -o $A/Contents/MacOS/VolisleTry
cp apps/macos/Sources/Volisle/Resources/BrandMark.png $A/Contents/Resources/
cp -R assets/brand/Localization/store/*.lproj $A/Contents/Resources/
python3 -c "import plistlib;plistlib.dump({'CFBundleIdentifier':'top.qisw.volisle.layouttry','CFBundleExecutable':'VolisleTry','CFBundlePackageType':'APPL','CFBundleName':'VolisleTry','CFBundleShortVersionString':'1.0','CFBundleVersion':'5','CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['zh-Hans','zh-Hant','en']},open('$A/Contents/Info.plist','wb'))"
codesign -s - --force $A 2>/dev/null
open $A ${=TRY_ARGS:-}
sleep ${2:-5}
osascript -e 'tell application "System Events" to set frontmost of process "VolisleTry" to true'; sleep 1
[[ -n ${TRY_KEYS:-} ]] && { osascript -e "tell application \"System Events\" to tell process \"VolisleTry\" to keystroke \"$TRY_KEYS\" using command down"; sleep 1.5; }
# TRY_GEOM="x,y,w,h" (System Events coordinates): place the front window, then capture it alone by its window number.
if [[ -n ${TRY_GEOM:-} ]]; then
  g=(${(s:,:)TRY_GEOM})
  osascript -e "tell application \"System Events\" to tell process \"VolisleTry\" to set position of window 1 to {${g[1]}, ${g[2]}}" \
            -e "tell application \"System Events\" to tell process \"VolisleTry\" to set size of window 1 to {${g[3]}, ${g[4]}}"
  sleep 1.5
  osascript -e 'tell application "System Events" to set frontmost of process "VolisleTry" to true'; sleep 0.8
  front=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true')
  [[ $front == VolisleTry ]] || { print -u2 "不在最前（$front），不截图"; exit 1; }
  wid=$($S/winid $(pgrep -f "$A/Contents/MacOS/VolisleTry") | head -1)
  screencapture -x -l $wid "$1"; sips -g pixelWidth -g pixelHeight "$1" | tail -2 | tr '\n' ' '; echo; exit 0
fi
front=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true')
[[ $front == VolisleTry ]] || { print -u2 "不在最前（$front），不截图"; exit 1; }
R=$(osascript -e 'tell application "System Events" to tell process "VolisleTry" to get {position, size} of window 1' | tr -d ' ')
screencapture -x -R "$R" "$1"; echo $R
