#!/bin/bash
# 受け入れテスト。新しいクラウド環境のセッションで実行する:
#   bash scripts/check.sh
# または clone せずに:
#   curl -fsSL https://raw.githubusercontent.com/yuidvg/cloud_environment_linux/main/scripts/check.sh | bash
set -uo pipefail

REAL_NIX=/nix/var/nix/profiles/default/bin/nix
REPO_FLAKE=github:nix-community/home-manager/release-26.05
LOG=/var/log/cloud-env-setup.log
PASS=0
FAIL=0

ok() { echo "✅ $*"; PASS=$((PASS + 1)); }
ng() { echo "❌ $*"; FAIL=$((FAIL + 1)); }

# check <説明> <コマンド...>
check() {
  local desc=$1
  shift
  local out
  if out=$("$@" 2>&1 </dev/null); then
    ok "$desc"
  else
    ng "$desc"
    printf '%s\n' "$out" | tail -n 15 | sed 's/^/     /'
  fi
}

# 1. ログインシェル・対話シェル・Claude の Bash ツール（このスクリプトを呼んだ環境）のどれでも nix が見つかる
#    （PATH の順番は問わない。shim は iptables 経由で、どの nix にも効く）
for mode in -lc -ic; do
  check "1. bash $mode: nix が PATH にある" bash -c "bash $mode 'command -v nix' >/dev/null 2>&1"
done
check "1. 呼び出し元の環境: nix が PATH にある" bash -c 'command -v nix >/dev/null'

# 2. home.packages のツールに PATH が通っている
for tool in fd bat eza just rg jq; do
  check "2. bash -lc / -ic: $tool が PATH にある" \
    bash -c "bash -lc 'command -v $tool' >/dev/null 2>&1 && bash -ic 'command -v $tool' >/dev/null 2>&1"
done

# 3. home.sessionVariables が見える
for mode in -lc -ic; do
  check "3. bash $mode: CLOUD_ENV_LINUX=1 / EDITOR=vim" \
    bash -c "[ \"\$(bash $mode 'echo \$CLOUD_ENV_LINUX:\$EDITOR' 2>/dev/null | tail -n1)\" = '1:vim' ]"
done

# fetch_ok <nix> : --refresh で github: を取り、403 の警告（＝キャッシュへの退避）がないことを確かめる
fetch_ok() {
  local out
  out=$("$1" flake metadata --refresh "$REPO_FLAKE" 2>&1) || { printf '%s\n' "$out"; return 1; }
  if printf '%s\n' "$out" | grep -q 'unable to download'; then
    printf '%s\n' "$out" | grep 'unable to download'
    return 1
  fi
}

# 4. shim を kill し hosts の行を消しても、supervise.sh と SessionStart フック（ensure.sh）で直る
self_heal() {
  pkill -f '^python3 /opt/gh-shim/shim.py' || true
  sed -i '/^127\.0\.0\.1 api\.github\.com$/d' /etc/hosts
  /opt/gh-shim/ensure.sh \
    && grep -q '^127\.0\.0\.1 api\.github\.com$' /etc/hosts \
    && pgrep -f '^python3 /opt/gh-shim/shim.py' >/dev/null \
    && fetch_ok "$REAL_NIX"
}
check "4. shim 停止 + hosts 削除からの復旧" self_heal

# 5. github: と git+https: で同じ rev の narHash が一致する
nar_match() {
  local rev a b
  rev=$("$REAL_NIX" flake metadata --json "$REPO_FLAKE" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["locked"]["rev"])') || return 1
  a=$("$REAL_NIX" flake prefetch --json "github:nix-community/home-manager/$rev" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["hash"])') || return 1
  b=$("$REAL_NIX" flake prefetch --json \
    "git+https://github.com/nix-community/home-manager?ref=release-26.05&rev=$rev&shallow=1" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["hash"])') || return 1
  echo "rev=$rev github:=$a git+https:=$b"
  [ -n "$a" ] && [ "$a" = "$b" ]
}
check "5. github: と git+https: の narHash が一致" nar_match

# 6. nix 以外（gh / curl）は shim を通らない
not_via_shim() {
  local issuer
  # どのシェルの no_proxy にも api.github.com が入っていない（shim には iptables 経由でだけ回す）
  if bash -ic 'echo "${no_proxy:-}${NO_PROXY:-}"' 2>/dev/null | tail -n1 | grep -q api.github.com; then
    echo "no_proxy in interactive shell contains api.github.com"
    return 1
  fi
  # curl が受け取った証明書の発行者が gh-shim の CA ではない
  issuer=$(curl -sv -o /dev/null https://api.github.com/ 2>&1 | grep -i 'issuer:' | head -n1)
  echo "curl: $issuer"
  [ -n "$issuer" ] || return 1
  echo "$issuer" | grep -q 'gh-shim' && return 1
  # gh api が使えるなら、こちらもプロキシ経由で応答する（shim は /zen を知らないので 404 になる）
  if command -v gh >/dev/null 2>&1; then
    gh api /zen >/dev/null 2>&1 || echo "note: gh api /zen failed (未認証の可能性。shim の 404 ではないことを確認)"
  fi
  return 0
}
check "6. curl / gh は shim を通らない（プロキシ経由）" not_via_shim

# 7. setup.sh の所要時間が 5 分未満
setup_time() {
  local t
  t=$(grep -o 'TOTAL [0-9]*s' "$LOG" 2>/dev/null | tail -n1 | grep -o '[0-9]*')
  echo "last setup: ${t:-?}s"
  [ -n "$t" ] && [ "$t" -lt 300 ]
}
check "7. setup.sh の所要時間 < 300s" setup_time

# 8. nix.conf 経由で shim の設定（ssl-cert-file / access-tokens）が効いている
real_nix_conf() {
  local cert tokens
  cert=$(env -u NIX_SSL_CERT_FILE "$REAL_NIX" config show ssl-cert-file 2>&1)
  tokens=$("$REAL_NIX" config show access-tokens 2>&1)
  echo "ssl-cert-file=$cert access-tokens=$tokens"
  [ "$cert" = /etc/nix/ca-bundle.pem ] && echo "$tokens" | grep -q 'github.com=gh-shim-dummy'
}
check "8. nix.conf で ssl-cert-file / access-tokens が shim 用" real_nix_conf

# 9. 付け替えの仕組みが入っている（SessionStart フック・intercept・iptables）
redirect_ready() {
  local port
  port=$(printf '%s' "${HTTPS_PROXY:-${https_proxy:-}}" | sed -n 's#^https\?://127\.0\.0\.1:\([0-9]*\)/\?$#\1#p')
  echo "HTTPS_PROXY port=${port:-?}"
  python3 -c 'import json,sys; d=json.load(open("/root/.claude/settings.json"));
sys.exit(0 if any(h.get("command")=="/opt/gh-shim/ensure.sh" for g in d["hooks"]["SessionStart"] for h in g["hooks"]) else 1)' \
    || { echo "SessionStart hook not registered"; return 1; }
  pgrep -f '^python3 /opt/gh-shim/intercept.py' >/dev/null || { echo "intercept not running"; return 1; }
  [ -n "$port" ] && iptables -t nat -S GH_SHIM | grep -q -- "--dport $port .*--to-ports 18443"
}
check "9. SessionStart フック / intercept / iptables（プロキシのポート宛てを付け替え）" redirect_ready

# 10. ラッパーなしの nix を、PATH 経由・プロファイルの絶対パス・store パスのどれで呼んでも github: が取れる
#     （403 → 古いキャッシュへの退避が起きない）
any_nix() {
  fetch_ok "$(command -v nix)" && fetch_ok "$REAL_NIX" && fetch_ok "$(readlink -f "$REAL_NIX")"
}
check "10. どの nix でも github: を --refresh で取れる（403 の退避なし）" any_nix

# 直近のセットアップ（最後の開始行より後）だけを見る
if awk '/cloud_environment_linux setup \(/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' "$LOG" 2>/dev/null \
  | grep -q 'WARN: home-manager switch failed'; then
  echo "⚠️  $LOG に home-manager の失敗が記録されている"
fi

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
