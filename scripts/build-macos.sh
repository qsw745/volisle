#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
python3 scripts/prepare-sparkle.py > .workbench/sparkle-build.log 2>&1
scripts/build-format-engine.sh >/dev/null
# Apple silicon and Intel in one app; the helper inside it too.
swift build --package-path apps/macos -c release --arch arm64 --arch x86_64
bin_dir="$(swift build --package-path apps/macos -c release --arch arm64 --arch x86_64 --show-bin-path)"
app_dir="$project_root/apps/macos/build/Volisle.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/Volisle" "$app_dir/Contents/MacOS/Volisle"
mkdir -p "$app_dir/Contents/Library/LaunchServices" "$app_dir/Contents/Library/LaunchDaemons"
cp "$bin_dir/VolisleMountHelper" "$app_dir/Contents/Library/LaunchServices/VolisleMountHelper"
cp "$project_root/apps/macos/Helper/top.qisw.volisle.mount-helper.plist" "$app_dir/Contents/Library/LaunchDaemons/"
cp "$project_root/assets/brand/Volisle.icns" "$app_dir/Contents/Resources/Volisle.icns"
# 名称按系统语言显示（中文“盘屿”、其他 Volisle）；包文件名保持 Volisle.app。
for lproj in "$project_root"/assets/brand/Localization/app/*.lproj(N); do
  rm -rf "$app_dir/Contents/Resources/${lproj:t}"
  cp -R "$lproj" "$app_dir/Contents/Resources/"
done
for resource in "$bin_dir"/*.bundle(N); do
  cp -R "$resource" "$app_dir/Contents/Resources/"
done
# 本地未签名开发包，不编造开发者拥有的 Bundle ID；正式签名须另行配置。
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Volisle</string>
<key>CFBundleDisplayName</key><string>Volisle</string>
<key>LSHasLocalizedDisplayName</key><true/>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>zh-Hant</string><string>en</string></array>
<key>CFBundleExecutable</key><string>Volisle</string>
<key>CFBundleIconFile</key><string>Volisle.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>LSMinimumSystemVersion</key><string>15.4</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSRemovableVolumesUsageDescription</key><string>盘屿需要访问你选择的外接硬盘，以检查磁盘状态并提供文件系统服务。只在你选择启用读写并通过检查后写入。</string>
</dict></plist>
PLIST
mkdir -p "$app_dir/Contents/Frameworks"
# ditto preserves the versioned framework links.
if [[ -e "$app_dir/Contents/Frameworks/Sparkle.framework" ]]; then
  rm -rf "$app_dir/Contents/Frameworks/Sparkle.framework"
fi
ditto "$project_root/.workbench/sparkle-build/Build/Products/Release/Sparkle.framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
cp "$project_root/.workbench/sparkle-source/sparkle-project-Sparkle-eef1a53/LICENSE" "$app_dir/Contents/Resources/Sparkle-LICENSE"
python3 "$project_root/scripts/configure-updates.py" "$app_dir"
plutil -lint "$app_dir/Contents/Info.plist"
printf '%s\n' "$app_dir"
