#!/bin/bash
# gh-shim の前提を毎回そろえる（冪等）。/opt/gh-shim/ensure.sh として置かれ、
# setup.sh と nix ラッパーの両方から呼ばれる。
#   1. /etc/hosts に 127.0.0.1 api.github.com（VM の復元で消える可能性がある）
#   2. /etc/nix/ca-bundle.pem をプロキシ CA + システム CA + shim CA で作り直す
#      （プロキシの CA は入れ替わることがある）
#   3. nix.conf の最後で /etc/nix/gh-shim.conf を読ませる（ssl-cert-file / access-tokens）。
#      環境変数ではなく設定ファイルで渡すので、ラッパーを通らない nix
#      （ベースイメージに入っている nix、nix-daemon、home-manager が呼ぶ nix など）にも効く。
#      nix.custom.conf などに ssl-cert-file があっても、最後に読むこちらが勝つ
#   4. shim が動いていなければ起動し、ポートが開くまで待つ
# shim の CA はシステムの信頼ストアには入れない（Nix だけが信頼する）。

SHIM_CA=/opt/gh-shim/ca.crt
BUNDLE=/etc/nix/ca-bundle.pem
NIX_CONF=/etc/nix/nix.conf
SHIM_CONF=/etc/nix/gh-shim.conf
INCLUDE_LINE="!include $SHIM_CONF"

# 1. hosts
grep -q '^127\.0\.0\.1 api\.github\.com$' /etc/hosts 2>/dev/null \
  || echo '127.0.0.1 api.github.com' >> /etc/hosts

# 2. CA バンドル（中身が変わったときだけ書き換える）
mkdir -p /etc/nix
tmp=$BUNDLE.tmp.$$
cat /root/.ccr/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt "$SHIM_CA" 2>/dev/null > "$tmp"
if cmp -s "$tmp" "$BUNDLE"; then
  rm -f "$tmp"
else
  mv -f "$tmp" "$BUNDLE"
fi

# 3. nix.conf（nix.conf がまだないとき = インストール前は gh-shim.conf だけ用意する）
want="# Managed by cloud_environment_linux (shim/ensure.sh). 手で編集しない。
ssl-cert-file = $BUNDLE
# Nix はトークンがあるときだけ api.github.com/.../tarball を使う（ないと github.com/.../archive に行く）。
# ダミーで秘密ではない。shim は中身を見ない
extra-access-tokens = github.com=gh-shim-dummy"
if [ "$(cat "$SHIM_CONF" 2>/dev/null)" != "$want" ]; then
  printf '%s\n' "$want" > "$SHIM_CONF.tmp.$$" && mv -f "$SHIM_CONF.tmp.$$" "$SHIM_CONF"
fi
if [ -f "$NIX_CONF" ] && [ "$(tail -n1 "$NIX_CONF")" != "$INCLUDE_LINE" ]; then
  # 途中にある古い行は消し、必ず最後の行にする（後から読んだ設定が勝つ）
  { grep -vxF "$INCLUDE_LINE" "$NIX_CONF"; echo "$INCLUDE_LINE"; } > "$NIX_CONF.tmp.$$" \
    && mv -f "$NIX_CONF.tmp.$$" "$NIX_CONF"
fi

# 4. shim プロセス
if ! (exec 3<>/dev/tcp/127.0.0.1/443) 2>/dev/null; then
  nohup python3 /opt/gh-shim/shim.py >>/var/log/gh-shim.log 2>&1 </dev/null &
  for _ in $(seq 50); do
    (exec 3<>/dev/tcp/127.0.0.1/443) 2>/dev/null && break
    sleep 0.1
  done
fi
exit 0
