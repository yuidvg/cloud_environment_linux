#!/bin/bash
# cloud_environment_linux: Claude Code クラウド環境のセットアップ
#
# クラウド環境の Setup script 欄から次のように呼ばれる:
#   curl -fsSL https://raw.githubusercontent.com/yuidvg/cloud_environment_linux/main/setup.sh | bash
#
#   1. shim setup         … api.github.com のローカル shim（github: 形式の flake 入力を通すため）
#   2. nix install        … NixOS/nix-installer（linux プランナー / --init none）
#   3. home-manager setup … この flake の homeConfigurations.root を switch
#
# 失敗の扱い:
#   - shim / nix の失敗は非ゼロで終了する（セッションが起動しないので必ず気づける）
#   - home-manager の失敗は WARN をログに残してゼロで終了する（設定ミスでセッション自体が
#     使えなくなるのを避ける。nix とラッパーは使えるので、セッション内で直して switch できる）
set -euo pipefail

export USER=root HOME=/root

OWNER=${CLOUD_ENV_OWNER:-yuidvg}
REPO=${CLOUD_ENV_REPO:-cloud_environment_linux}
REF=${CLOUD_ENV_REF:-main}
RAW="https://raw.githubusercontent.com/$OWNER/$REPO/$REF"
FLAKE="github:$OWNER/$REPO/$REF"

LOG=/var/log/cloud-env-setup.log
SHIM_DIR=/opt/gh-shim
REAL_NIX=/nix/var/nix/profiles/default/bin/nix
NIX_PROFILE_SCRIPT=/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
WRAPPER=/root/.local/bin/nix

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

# stage <name> <function>: 開始・終了・所要時間をログに出す。
# `fn || rc=$?` の形だと関数内で set -e が効かないので、サブシェルで set -e を有効にして走らせる
stage() {
  local name=$1 fn=$2 t0 rc
  t0=$(date +%s)
  log "=== START $name"
  set +e
  ( set -e; "$fn" )
  rc=$?
  set -e
  log "=== END   $name (rc=$rc, $(( $(date +%s) - t0 ))s)"
  return "$rc"
}

# リポジトリ内のファイルを取得する。clone したディレクトリから実行された場合はそれを使う
# （curl | bash のときは BASH_SOURCE が空なので raw.githubusercontent.com から取る）
SRC_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/shim/shim.py" ]; then
  SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fi

fetch() { # fetch <repo-relative path> <dest>
  local tmp="$2.tmp.$$"
  if [ -n "$SRC_DIR" ]; then
    cp "$SRC_DIR/$1" "$tmp"
  else
    curl -fsSL --retry 3 "$RAW/$1" -o "$tmp"
  fi
  mv -f "$tmp" "$2"
}

# ---------------------------------------------------------------------------
# 1. shim setup（nix-installer に --ssl-cert-file を渡すので、先に CA バンドルを作る）
# ---------------------------------------------------------------------------
shim_setup() {
  mkdir -p "$SHIM_DIR" /var/cache/gh-shim /root/.local/bin

  fetch shim/shim.py "$SHIM_DIR/shim.py"
  fetch shim/ensure.sh "$SHIM_DIR/ensure.sh"
  fetch shim/nix-wrapper.sh "$WRAPPER"
  chmod +x "$SHIM_DIR/ensure.sh" "$WRAPPER"

  # 自己署名 CA と api.github.com 用サーバー証明書（SAN 必須）。Nix だけが信頼する
  if [ ! -s "$SHIM_DIR/server.crt" ] || [ ! -s "$SHIM_DIR/ca.crt" ]; then
    log "generating gh-shim CA and server certificate"
    (
      cd "$SHIM_DIR"
      openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=gh-shim local CA" \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -keyout ca.key -out ca.crt 2>/dev/null
      openssl req -newkey rsa:2048 -nodes -subj "/CN=api.github.com" \
        -keyout server.key -out server.csr 2>/dev/null
      printf 'subjectAltName=DNS:api.github.com\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' > ext.cnf
      openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 3650 \
        -extfile ext.cnf -out server.crt 2>/dev/null
      chmod 600 ca.key server.key
    )
  fi

  # 毎回: hosts / CA バンドル再生成 / shim 起動
  "$SHIM_DIR/ensure.sh"
  if ! (exec 3<>/dev/tcp/127.0.0.1/443) 2>/dev/null; then
    log "ERROR: gh-shim did not start (see /var/log/gh-shim.log)"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 2. nix install（NixOS/nix-installer。インストール済みならスキップ）
# ---------------------------------------------------------------------------
nix_install() {
  if [ -x "$REAL_NIX" ]; then
    log "nix already installed: $("$REAL_NIX" --version)"
    return 0
  fi

  local installer=/tmp/nix-installer.sh url
  for url in https://artifacts.nixos.org/nix-installer \
             https://channels.nixos.org/nix-latest/nix-installer; do
    if curl -sSfL --retry 3 "$url" -o "$installer"; then
      log "downloaded installer from $url"
      break
    fi
    log "WARN: failed to download installer from $url"
  done
  [ -s "$installer" ] || { log "ERROR: could not download nix-installer"; return 1; }

  # --enable-flakes: 2.35.2 以降の nix-installer は既定で flakes を有効にしない
  # access-tokens のダミー: これがないと Nix は github.com/.../archive/... を取りに行き shim を通らない
  NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
  sh "$installer" install linux \
    --init none \
    --no-confirm \
    --enable-flakes \
    --ssl-cert-file /etc/nix/ca-bundle.pem \
    --extra-conf "sandbox = false" \
    --extra-conf "access-tokens = github.com=gh-shim-dummy"
  rm -f "$installer"

  [ -x "$REAL_NIX" ] || { log "ERROR: $REAL_NIX not found after install"; return 1; }
  log "installed: $("$REAL_NIX" --version)"
}

# ---------------------------------------------------------------------------
# 3. home-manager setup（この flake を直接参照して switch。clone はしない）
# ---------------------------------------------------------------------------
home_manager_setup() {
  # shellcheck disable=SC1090
  [ -r "$NIX_PROFILE_SCRIPT" ] && . "$NIX_PROFILE_SCRIPT"
  export PATH=/root/.local/bin:$PATH

  # home-manager 本体も flake.lock で固定したものを使う（release ブランチの最新を毎回取らない）
  "$WRAPPER" run --refresh "$FLAKE#home-manager" -- \
    switch --flake "$FLAKE#root" -b bak
}

# home-manager が失敗したときでも、最低限 nix（ラッパー）が Claude の Bash から見えるようにする
bashrc_fallback() {
  [ -L /root/.bashrc ] && return 0 # home-manager 管理下なら触らない
  grep -q 'cloud_environment_linux fallback' /root/.bashrc 2>/dev/null && return 0
  cat >> /root/.bashrc <<EOF
# >>> cloud_environment_linux fallback (home-manager switch failed) >>>
[ -r $NIX_PROFILE_SCRIPT ] && . $NIX_PROFILE_SCRIPT
export PATH=/root/.local/bin:\$PATH
# <<< cloud_environment_linux fallback <<<
EOF
  log "wrote fallback PATH setup to /root/.bashrc"
}

main() {
  local start
  start=$(date +%s)
  log "cloud_environment_linux setup ($FLAKE, src=${SRC_DIR:-$RAW})"
  stage "shim setup" shim_setup
  stage "nix install" nix_install
  if ! stage "home-manager setup" home_manager_setup; then
    log "WARN: home-manager switch failed; session will start without it (see $LOG)"
    bashrc_fallback
  fi
  log "TOTAL $(( $(date +%s) - start ))s"
}

# curl | bash では stdin がスクリプト本体なので、子プロセスに読ませないよう /dev/null をつなぐ。
# main をここで呼ぶことで、実行開始前にスクリプト全体が読み込まれる。
# stdout とログの両方に出す
main "$@" </dev/null 2>&1 | tee -a "$LOG"
exit "${PIPESTATUS[0]}"
