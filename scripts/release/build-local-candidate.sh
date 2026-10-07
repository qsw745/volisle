#!/bin/zsh
# Local acceptance: end qsw's write session via the helper, then build, sign and
# install a candidate over the copy this Mac uses. Usage: <tag>
# (Moved out of the git-ignored .workbench after it was wiped on 2026-10-04.)
set -u
project_root="${0:A:h:h:h}"
cd "$project_root"
source scripts/release/local-config.sh
# One copy per Mac, or FSKit may pick either extension: since 0.8.1 the test build
# replaces /Applications/Volisle.app; VOLISLE_TEST_APP overrides.
app=${VOLISLE_TEST_APP:-}
[[ -n $app ]] || { [[ -d /Applications/Volisle.app ]] && app=/Applications/Volisle.app || app=~/Applications/"Volisle Test.app"; }
B=$app/Contents/MacOS/Volisle
tag=$1
logs=.workbench/logs; mkdir -p "$logs"
# The disk number changes between connections: find qsw by hardware and name, never by number.
dev=none
for d in $(diskutil list external physical | awk '/^\/dev\/disk/ {sub("/dev/","",$1); print $1}'); do
  diskutil info $d | grep -q "Media Name:.*Expansion" || continue
  p=$(diskutil list $d | awk '/(Windows_NTFS|Microsoft Basic Data) +qsw / {print $NF}' | head -1)
  [[ -n $p ]] && dev=$p
done
[[ $dev == none ]] && echo 'test disk partition not found; skipping restore'
echo "qsw = $dev"
osascript -e 'tell application id "top.qisw.volisle" to quit' 2>/dev/null; sleep 2
mount | grep -q "(volisle" && [[ $dev == none ]] && { echo "a Volisle mount exists but qsw was not found"; exit 1; }
if mount | grep -q "$dev on .*volisle"; then
  [[ -x $B ]] || { echo "qsw is write-mounted but no installed Volisle at $app to end the session"; exit 1; }
  ID=$($B --helper-cycle-latest | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
  $B --helper-cycle-recover $ID >/dev/null
  for i in $(seq 1 90); do p=$($B --helper-cycle-latest | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['phase'], d.get('recoveryFailure'))"); case "$p" in finished*|needsRecovery*) break;; esac; sleep 1; done
  echo "restore: $p"
fi
mount | grep $dev
mount | grep -q "$dev on .*volisle" && { echo "qsw still mounted by Volisle"; exit 1; }
python3 scripts/prepare-extension-bundle.py --bundle-id top.qisw.volisle --daily-write --output-dir apps/macos/build/review-$tag > $logs/build-$tag.log 2>&1 || { echo prepare failed; exit 1; }
python3 scripts/sign-extension-bundle.py --profile "$VOLISLE_PROFILE" --candidate-dir apps/macos/build/review-$tag --output-dir apps/macos/build/signed-$tag --daily-write >> $logs/build-$tag.log 2>&1 || { echo sign failed; exit 1; }
python3 scripts/install-local-candidate.py apps/macos/build/signed-$tag/top.qisw.volisle.app --label $tag --target "$app" || exit 1
# A second copy with the same extension in ~/Applications confuses FSKit discovery.
mkdir -p ~/"Volisle 测试回滚副本"
for r in ~/Applications/"Volisle Test.before-"*.rollback(N); do mv "$r" ~/"Volisle 测试回滚副本"/; done
$B --helper-register
# The installer quits the app; reopen it so automatic write access resumes.
open "$app"
