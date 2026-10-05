# Sourced by the release scripts: owner-specific settings from
# config/release.local.env (not in git; copy config/release.local.env.example).
_volisle_config="${${(%):-%x}:A:h:h:h}/config/release.local.env"
[[ -f $_volisle_config ]] || { print -u2 "缺少 $_volisle_config：复制 config/release.local.env.example 并填写自己的签名、公证和服务器信息"; exit 1; }
source "$_volisle_config"
for _volisle_var in VOLISLE_SIGN_IDENTITY VOLISLE_PROFILE VOLISLE_NOTARY_KEY_ID VOLISLE_NOTARY_KEY VOLISLE_NOTARY_ISSUER \
                    VOLISLE_DEPLOY_HOST VOLISLE_SITE_DIR VOLISLE_RELEASES_DIR; do
  [[ -n ${(P)_volisle_var:-} ]] || { print -u2 "$_volisle_config 里没有填写 $_volisle_var"; exit 1; }
done
unset _volisle_config _volisle_var
