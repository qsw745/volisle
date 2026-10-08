#!/bin/zsh
# Publish a new version of 盘屿 end to end. Usage:
#
#   scripts/release/release.sh <version> <notes.txt>      e.g. 0.6.2 ~/Desktop/notes.txt
#
# Stops before anything irreversible and asks: after the candidate is built and
# installed for testing, and before the website goes live. Once live, the public
# repository qsw745/volisle gets the matching source snapshot. Prerequisites and the
# notes format: docs/release/自己发布新版本.md. Run from a clean main branch.
set -euo pipefail
cd "${0:A:h:h:h}"
version=${1:-} notes=${2:-}
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && -f $notes ]] || { print -u2 "用法：$0 <版本号，如 0.6.2> <更新说明.txt>"; exit 2; }
notes=${notes:A}
step() { print "\n━━ $1"; }
ask() { local answer; read "answer?$1 输入 y 继续，其他任意键停止："; [[ $answer == y ]] || { print '已停止。'; exit 1; }; }
# Stopped or failed before the website commit: drop the version commit this run
# made, but only while nothing else sits on top of it or in the work tree.
undo_version() {
  [[ -n ${release_commit:-} && $(git rev-parse HEAD) == $release_commit && -z $(git status --porcelain) ]] || return 0
  git reset -q --hard HEAD~1 && print -u2 "已撤销本次的版本号提交 ${release_commit:0:7}。"
}
trap undo_version EXIT

# Expected hashes: the extension's declarations, entitlements and the helper's
# launchd plist must stay byte-identical to the released ones (a change breaks
# in-place updates until the user logs out). Change them only on purpose.
EXPECT_DECL=4738df1a5aff8684 EXPECT_APP=e3b0c44298fc1c14 EXPECT_EXT=7765429137f06229 EXPECT_HELPER=e3b0c44298fc1c14 EXPECT_PLIST=78a2800b2a0f3efd
source scripts/release/local-config.sh   # signing, notarization and server settings
IDENTITY=$VOLISLE_SIGN_IDENTITY PROFILE=$VOLISLE_PROFILE NOTARY_KEY=$VOLISLE_NOTARY_KEY ISSUER=$VOLISLE_NOTARY_ISSUER

step "1/10 检查环境"
[[ $(git branch --show-current) == main ]] || { print -u2 '请在 main 分支上发布'; exit 1; }
[[ -z $(git status --porcelain) ]] || { print -u2 '工作区有未提交的改动，请先提交或撤销'; git status --short; exit 1; }
security find-identity -v -p codesigning | grep -q "$IDENTITY" || { print -u2 "钥匙串里没有签名证书：$IDENTITY"; exit 1; }
[[ -f $PROFILE ]] || { print -u2 "缺少描述文件：$PROFILE"; exit 1; }
[[ -f $NOTARY_KEY ]] || { print -u2 "缺少公证密钥：$NOTARY_KEY"; exit 1; }
ssh -o BatchMode=yes -o ConnectTimeout=10 $VOLISLE_DEPLOY_HOST true || { print -u2 "无法免密登录服务器 $VOLISLE_DEPLOY_HOST"; exit 1; }
[[ -f config/publish-public.local.json ]] || { print -u2 '缺少 config/publish-public.local.json（公开仓库快照的个人信息替换清单）'; exit 1; }
python3 -c 'import dmgbuild' 2>/dev/null || { print -u2 '缺少 dmgbuild（安装窗口布局）：pip3 install --user dmgbuild==1.6.7'; exit 1; }
for tool in pnpm python3 swift xcrun curl; do command -v $tool >/dev/null || { print -u2 "缺少命令：$tool"; exit 1; }; done
current=$(python3 -c "import json;d=json.load(open('config/updates.json'));print(d['version'], d['build'])")
old_version=${current% *} old_build=${current#* }
python3 -c "import sys;a,b=[tuple(map(int,v.split('.'))) for v in sys.argv[1:]];sys.exit(0 if a>b else 1)" $version $old_version \
  || { print -u2 "新版本号 $version 必须大于当前的 $old_version"; exit 1; }
build=$((old_build + 1))
python3 scripts/release/release_web.py check-notes "$notes"
head -1 "$notes" | grep -q "$version" || { print -u2 "更新说明第一行里没有版本号 $version"; exit 1; }
out=dist/Volisle-$version-build$build
[[ ! -e $out ]] || { print -u2 "$out 已存在。上次中断的话，先检查里面的内容再删掉"; exit 1; }
print "准备发布 $version（构建 $build），上一版 $old_version（构建 $old_build）"

step "2/10 测试与版本号"
swift test --package-path packages/VolisleCore 2>&1 | grep -E "Test run with" | tail -1 | grep -q passed || { print -u2 '单元测试没有通过'; exit 1; }
python3 scripts/check-localization.py | tail -1 | grep -q '问题 0 个' || { print -u2 '本地化检查没有通过（缺翻译？运行 python3 scripts/check-localization.py 查看）'; exit 1; }
print '单元测试、本地化检查通过'
python3 - $version $build <<'PY'
import json, sys, pathlib
p = pathlib.Path('config/updates.json'); d = json.loads(p.read_text())
d['version'], d['build'] = sys.argv[1], int(sys.argv[2])
p.write_text(json.dumps(d, ensure_ascii=False, indent=2) + '\n')
PY
git commit -qam "feat: 盘屿 $version（构建 $build）"
release_commit=$(git rev-parse HEAD)

step "3/10 构建、签名并装到本机"
tag=build$build-release-$(date +%Y%m%d-%H%M%S)  # a retry the same day needs new candidate folders
zsh scripts/release/build-local-candidate.sh $tag
app=apps/macos/build/signed-$tag/top.qisw.volisle.app
[[ -d $app ]] || { print -u2 '候选包没有生成，请看 .workbench/logs/build-'$tag'.log'; exit 1; }
[[ $(plutil -extract CFBundleShortVersionString raw $app/Contents/Info.plist) == $version ]] || { print -u2 '候选包版本号不对'; exit 1; }
hash16() { shasum -a 256 | cut -c1-16; }
decl=$(plutil -extract EXAppExtensionAttributes xml1 -o - "$app/Contents/Extensions/VolisleFS.appex/Contents/Info.plist" | hash16)
e_app=$(codesign -d --entitlements - --xml "$app" 2>/dev/null | hash16)
e_ext=$(codesign -d --entitlements - --xml "$app/Contents/Extensions/VolisleFS.appex" 2>/dev/null | hash16)
e_helper=$(codesign -d --entitlements - --xml "$app/Contents/Library/LaunchServices/VolisleMountHelper" 2>/dev/null | hash16)
plist=$(cat "$app/Contents/Library/LaunchDaemons/"*.plist | hash16)
[[ $decl == $EXPECT_DECL && $e_app == $EXPECT_APP && $e_ext == $EXPECT_EXT && $e_helper == $EXPECT_HELPER && $plist == $EXPECT_PLIST ]] || {
  print -u2 "扩展声明、权限或后台组件配置变了（$decl $e_app $e_ext $e_helper $plist），原位升级会让扩展失效，停止发布"; exit 1; }
print "已装到本机（/Applications/Volisle.app，没有时为 ~/Applications/Volisle Test.app），扩展声明与各组件权限与已发布版本一致"
ask "请用本机新装的版本实际试一下（插盘、读写、推出）。确认没问题后"

step "4/10 苹果公证"
zsh scripts/release/notarize-and-staple.sh $app $out $ISSUER

step "5/10 更新目录"
mkdir -p $out/release-inputs
cp "$notes" $out/release-inputs/notes.txt
curl -fsS https://qisw.top/volisle/updates/appcast.xml -o $out/release-inputs/previous-appcast.xml
cmp -s $out/release-inputs/previous-appcast.xml apps/web/public/updates/appcast.xml \
  || { print -u2 '线上更新目录与仓库里的不一致：上次发布可能没提交完整，停止'; exit 1; }
python3 scripts/release/release_web.py readiness $app $build $version
python3 scripts/prepare-update-release.py --candidate $app --source $out/package/Volisle-$version-source.tar.gz \
  --previous-feed $out/release-inputs/previous-appcast.xml --notes $out/release-inputs/notes.txt --output-dir $out/update-release
cp $out/update-release/appcast.xml apps/web/public/updates/appcast.xml

step "6/10 官网页面与暂存"
dmg=$out/signed-dmg/Volisle-$version-arm64.dmg source=$out/package/Volisle-$version-source.tar.gz
python3 scripts/release/release_web.py website $dmg $source "$notes"
zsh scripts/stage-website-release.sh $out $out/site-stage
python3 scripts/release/release_web.py history-files $out/site-stage/downloads
(cd $out/site-stage && find . -type f ! -name MANIFEST.sha256 | LC_ALL=C sort | xargs shasum -a 256 > MANIFEST.sha256)

step "7/10 核对源码包与发布提交一致"
tmp=$(mktemp -d)
tar -xzf $source -C $tmp
bad=0 n=0
for f in $(cd $tmp/Volisle && find packages apps/extension apps/macos/Sources apps/macos/Helper scripts assets/brand/Localization -type f \
            \( -name '*.swift' -o -name '*.c' -o -name '*.inc' -o -name '*.h' -o -name '*.py' -o -name '*.sh' -o -name '*.strings' \
               -o -name '*.plist' -o -name '*.entitlements' \)); do
  n=$((n + 1))
  [[ $(shasum -a 256 < $tmp/Volisle/$f | cut -c1-64) == $(git show $release_commit:$f 2>/dev/null | shasum -a 256 | cut -c1-64) ]] || { print -u2 "不一致：$f"; bad=$((bad + 1)); }
done
rm -rf $tmp
(( bad == 0 )) || { print -u2 "源码包有 $bad 个文件与发布提交不一致，停止"; exit 1; }
print "源码包 $n 个文件与发布提交 ${release_commit:0:7} 一致"

step "8/10 上线"
site_name=$(date +%Y%m%d)-$version-build$build
previous_site=$(ssh -o BatchMode=yes $VOLISLE_DEPLOY_HOST readlink $VOLISLE_SITE_DIR | xargs basename)
zsh scripts/deploy-website.sh check $out/site-stage $site_name
git add apps/web config/release-readiness.json docs/testing
git commit -qm "chore: 官网与更新目录同步 $version"
ask "即将把 $version 发布到 https://qisw.top/volisle/ ，老用户会收到更新提示；随后把对应源码快照推送到公开仓库 qsw745/volisle。"
zsh scripts/deploy-website.sh deploy $out/site-stage $site_name | tail -3

step "9/10 标签与推送"
git tag -a v$version $release_commit -m "盘屿 $version（构建 $build）"
git push -q origin main v$version

step "10/10 公开仓库源码快照"
# Already live: a failure here only leaves the public repository behind; say how to catch up.
# The clone goes to a temporary folder outside this repository; macOS clears those.
public_out=$out/public-snapshot public_clone=$(mktemp -d)/volisle
if python3 scripts/publish-public.py export v$version --out $public_out \
   && git clone -q https://github.com/qsw745/volisle.git $public_clone \
   && python3 scripts/publish-public.py sync $public_out $public_clone "盘屿 $version" \
   && git -C $public_clone push -q origin HEAD; then
  print "公开仓库 qsw745/volisle 已同步到 $version"
else
  print -u2 "⚠️ 公开仓库没有同步（官网发布不受影响）。补做：见 docs/release/自己发布新版本.md「中途出错怎么办」"
fi
print "\n✅ 盘屿 $version（构建 $build）已发布。"
print "   安装包 SHA-256：$(shasum -a 256 $dmg | cut -c1-64)"
print "   出问题回到上一版：scripts/deploy-website.sh rollback $previous_site"
print "   别忘了在 docs/release/当前交付清单.md 记一笔。"
