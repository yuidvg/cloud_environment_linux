#!/bin/bash
# gh-shim の前提をそろえる（冪等）。/opt/gh-shim/ensure.sh として置かれ、
# setup.sh と Claude Code の SessionStart フック（セッション開始・再開のたび）から呼ばれる。
#   1. /etc/hosts に 127.0.0.1 api.github.com（プロキシを使わない nix 用。VM の復元で消えうる）
#   2. /etc/nix/ca-bundle.pem をプロキシ CA + システム CA + shim CA で作り直す
#      （プロキシの CA は入れ替わることがある）
#   3. nix.conf の最後で /etc/nix/gh-shim.conf を読ませる（ssl-cert-file / access-tokens）。
#      nix.custom.conf などに ssl-cert-file があっても、最後に読むこちらが勝つ
#   4. shim（127.0.0.1:443）と intercept（127.0.0.1:18443）を supervise.sh 付きで起動する
#   5. iptables: エージェントプロキシ（HTTPS_PROXY のポート）宛ての接続を intercept へ付け替える。
#      プロキシのポートはセッションごとに変わるので毎回入れ直す。intercept は nix の
#      CONNECT api.github.com だけを shim に回し、それ以外はそのまま元のプロキシへ流す
# shim の CA はシステムの信頼ストアには入れない（Nix だけが信頼する）。
# 標準出力は SessionStart フックだと Claude の文脈に入るので、何も出さない。
exec >>/var/log/gh-shim.log 2>&1

DIR=/opt/gh-shim
SHIM_CA=$DIR/ca.crt
BUNDLE=/etc/nix/ca-bundle.pem
NIX_CONF=/etc/nix/nix.conf
SHIM_CONF=/etc/nix/gh-shim.conf
INCLUDE_LINE="!include $SHIM_CONF"
INTERCEPT_PORT=18443
MARK=0x6768
CHAIN=GH_SHIM

log() { printf '[%s] ensure: %s\n' "$(date '+%F %T')" "$*"; }
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

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

# 4. shim / intercept（落ちても supervise.sh が起動し直す）
start() { # start <name> <port> <command...>
  local name=$1 port=$2
  shift 2
  if ! pgrep -f "supervise.sh $name " >/dev/null; then
    log "starting $name"
    setsid nohup "$DIR/supervise.sh" "$name" "$@" >/dev/null 2>&1 </dev/null &
  fi
  for _ in $(seq 50); do
    port_open "$port" && return 0
    sleep 0.1
  done
  log "WARN: $name is not listening on $port"
  return 1
}
start shim 443 python3 "$DIR/shim.py"
intercept_ok=0
start intercept "$INTERCEPT_PORT" python3 "$DIR/intercept.py" && intercept_ok=1

# 5. iptables（intercept が待ち受けているときだけ。止まっていると全通信が止まるので）
proxy=${HTTPS_PROXY:-${https_proxy:-}}
if [[ $proxy =~ ^https?://127\.0\.0\.1:([0-9]+)/?$ ]] && command -v iptables >/dev/null; then
  port=${BASH_REMATCH[1]}
  rule="-A $CHAIN -d 127.0.0.1/32 -p tcp -m tcp --dport $port -m mark ! --mark $MARK -j REDIRECT --to-ports $INTERCEPT_PORT"
  iptables -t nat -N "$CHAIN" 2>/dev/null
  iptables -t nat -C OUTPUT -j "$CHAIN" 2>/dev/null || iptables -t nat -A OUTPUT -j "$CHAIN"
  if [ "$intercept_ok" = 1 ]; then
    if ! iptables -t nat -S "$CHAIN" | grep -qxF -- "$rule"; then
      iptables -t nat -F "$CHAIN"
      # shellcheck disable=SC2086
      iptables -t nat $rule && log "redirecting 127.0.0.1:$port -> intercept :$INTERCEPT_PORT"
    fi
  else
    iptables -t nat -F "$CHAIN"
    log "WARN: intercept down; iptables redirect removed"
  fi
else
  log "no loopback HTTPS_PROXY (${proxy:-unset}); iptables redirect not installed"
fi
exit 0
