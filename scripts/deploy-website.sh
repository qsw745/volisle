#!/bin/zsh
# Upload a staged website release to the origin server and switch
# the live site to it atomically. Nginx is not touched. Server settings come
# from config/release.local.env (scripts/release/local-config.sh).
#
#   scripts/deploy-website.sh check    <stage-dir> <release-name>   read-only preflight
#   scripts/deploy-website.sh deploy   <stage-dir> <release-name>   upload, verify, switch
#   scripts/deploy-website.sh rollback <release-name>               switch back to an existing release
#
# The stage directory comes from stage-website-release.sh and carries MANIFEST.sha256.
set -euo pipefail
source "${0:A:h}/release/local-config.sh"
host=$VOLISLE_DEPLOY_HOST
site=$VOLISLE_SITE_DIR
releases=$VOLISLE_RELEASES_DIR
public=https://qisw.top/volisle
action="${1:-}"

remote() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" "$@"; }
valid_name() { [[ "$1" =~ '^[0-9]{8}-[A-Za-z0-9.-]+$' ]] || { print -u2 "发行目录名无效：$1"; exit 1; }; }

preflight() {  # $1 release name
  remote "set -e
    test -L $site || { echo '当前站点不是符号链接，停止'; exit 1; }
    echo \"当前指向：\$(readlink $site)\"
    test ! -e $releases/$1 || { echo '同名发行目录已存在，停止'; exit 1; }
    df -h /data | tail -1
    avail=\$(df -Pk /data | awk 'NR==2 {print \$4}')
    test \"\$avail\" -ge 2097152 || { echo \"服务器 /data 只剩 \$((avail / 1024)) MB，不足 2 GB：先清理不再需要的旧发行目录再发布\"; exit 1; }
    sudo -n nginx -t 2>&1 | tail -1"
}

# Compare public files with the staged manifest (appcast, downloads, pages).
verify_public() {  # $1 stage dir
  local stage="$1" failed=0 url got
  while read -r sum rel; do
    case "$rel" in
      ./updates/*|./downloads/*|./index.html|./download/index.html) ;;
      *) continue ;;
    esac
    url="$public/${rel#./}"; [[ "$url" == */index.html ]] && url="${url%index.html}"
    got=$(curl -fsS --retry 2 "$url" | shasum -a 256 | cut -d' ' -f1) || got=missing
    if [[ "$got" == "$sum" ]]; then print "一致  $url"; else print -u2 "不一致 $url"; failed=1; fi
  done < "$stage/MANIFEST.sha256"
  return $failed
}

case "$action" in
  check)
    stage="${2:A}" name="$3"; valid_name "$name"
    [[ -f "$stage/MANIFEST.sha256" ]] || { print -u2 '缺少暂存清单'; exit 1; }
    (cd "$stage" && shasum -a 256 -c MANIFEST.sha256 >/dev/null) && print '本地暂存清单校验通过'
    preflight "$name" ;;
  deploy)
    stage="${2:A}" name="$3"; valid_name "$name"
    (cd "$stage" && shasum -a 256 -c MANIFEST.sha256 >/dev/null)
    preflight "$name"
    previous=$(remote "readlink $site")
    upload="/tmp/volisle-upload-$name"
    remote "rm -rf $upload && mkdir -p $upload"
    rsync -a --delete "$stage/" "$host:$upload/"
    remote "set -e
      cd $upload && sha256sum --quiet -c MANIFEST.sha256
      sudo mkdir -p $releases/$name
      sudo cp -a $upload/. $releases/$name/
      sudo chown -R root:root $releases/$name
      sudo find $releases/$name -type d -exec chmod 755 {} +
      sudo find $releases/$name -type f -exec chmod 644 {} +
      cd $releases/$name && sha256sum --quiet -c MANIFEST.sha256
      sudo ln -sfn $releases/$name $site.next
      sudo mv -T $site.next $site
      rm -rf $upload
      echo \"已切换：\$(readlink $site)（上一版：$previous）\""
    print "$previous" > "$stage.previous-release"
    verify_public "$stage" || { print -u2 '公网内容与暂存不一致；可运行 rollback 切回上一版'; exit 1; }
    print "部署完成。回滚命令：scripts/deploy-website.sh rollback ${previous:t}" ;;
  rollback)
    name="$2"; valid_name "$name"
    remote "set -e
      test -d $releases/$name || { echo '发行目录不存在'; exit 1; }
      sudo ln -sfn $releases/$name $site.next
      sudo mv -T $site.next $site
      echo \"已切回：\$(readlink $site)\""
    curl -fsS "$public/updates/appcast.xml" | shasum -a 256 ;;
  *)
    sed -n 2,10p "$0"; exit 2 ;;
esac
