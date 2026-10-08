#!/bin/zsh
# Renders the DMG window background from assets/brand/dmg/background.html into
# background.tiff (1× and 2× in one file, so Retina screens get the sharp one).
# The TIFF is committed: releases do not need Chrome. Run after editing the HTML.
set -euo pipefail
cd "${0:A:h:h}"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[[ -x $chrome ]] || { print -u2 "需要 Google Chrome 渲染背景：$chrome"; exit 1; }
dir=assets/brand/dmg
tmp=$(mktemp -d)
for scale in 1 2; do
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=$scale \
    --window-size=660,440 --screenshot="$tmp/bg-$scale.png" "file://$PWD/$dir/background.html" >/dev/null 2>&1
done
[[ $(sips -g pixelWidth "$tmp/bg-1.png" | awk '/pixelWidth/ {print $2}') == 660 ]] || { print -u2 '1× 尺寸不对'; exit 1; }
[[ $(sips -g pixelWidth "$tmp/bg-2.png" | awk '/pixelWidth/ {print $2}') == 1320 ]] || { print -u2 '2× 尺寸不对'; exit 1; }
# The 2× image must say 144 dpi, or Finder treats it as a second 1× image.
# (PNG dpi does not survive tiffutil; set it on TIFF copies.)
sips -s format tiff -s dpiWidth 72 -s dpiHeight 72 "$tmp/bg-1.png" --out "$tmp/bg-1.tiff" >/dev/null
sips -s format tiff -s dpiWidth 144 -s dpiHeight 144 "$tmp/bg-2.png" --out "$tmp/bg-2.tiff" >/dev/null
tiffutil -cat "$tmp/bg-1.tiff" "$tmp/bg-2.tiff" -out "$dir/background.tiff" >/dev/null 2>&1
[[ $(tiffutil -info "$dir/background.tiff" 2>&1 | grep -c 'Resolution: 144, 144') == 1 ]] || { print -u2 '2× 分辨率没有写成 144 dpi'; exit 1; }
print "$dir/background.tiff"
