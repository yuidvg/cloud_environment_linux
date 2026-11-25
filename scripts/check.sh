#!/bin/bash
# 受け入れテスト。新しいクラウド環境のセッションで実行する:
#   bash scripts/check.sh
# または clone せずに:
#   curl -fsSL https://raw.githubusercontent.com/yuidvg/cloud_environment_linux/main/scripts/check.sh | bash
set -uo pipefail

WRAPPER=/root/.local/bin/nix
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

# 1. which nix がラッパーを指す（login / interactive の両方）
for mode in -lc -ic; do
  check "1. bash $mode: which nix = $WRAPPER" \
    bash -c "[ \"\$(bash $mode 'which nix' 2>/dev/null | tail -n1)\" = '$WRAPPER' ]"
done

# 1b. 従来コマンド（nix-build など）もラッパーを指す
for mode in -lc -ic; do
  check "1b. bash $mode: which nix-build / nix-shell = /root/.local/bin/..." \
    bash -c "[ \"\$(bash $mode 'which nix-build; which nix-shell' 2>/dev/null | tail -n2 | tr '\n' ' ')\" = '/root/.local/bin/nix-build /root/.local/bin/nix-shell ' ]"
done

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

# 4. shim を kill し hosts の行を消しても、ラッパーが自動で直して github: が解決できる
self_heal() {
  pkill -f /opt/gh-shim/shim.py || true
  sleep 0.3
  sed -i '/^127\.0\.0\.1 api\.github\.com$/d' /etc/hosts
  "$WRAPPER" flake metadata --refresh github:nix-community/home-manager/release-26.05 \
    && grep -q '^127\.0\.0\.1 api\.github\.com$' /etc/hosts \
    && pgrep -f /opt/gh-shim/shim.py >/dev/null
}
check "4. shim 停止 + hosts 削除からの自動復旧" self_heal

# 5. github: と git+https: で同じ rev の narHash が一致する
nar_match() {
  local rev a b
  rev=$("$WRAPPER" flake metadata --json github:nix-community/home-manager/release-26.05 \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["locked"]["rev"])') || return 1
  a=$("$WRAPPER" flake prefetch --json "github:nix-community/home-manager/$rev" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["hash"])') || return 1
  b=$("$WRAPPER" flake prefetch --json \
    "git+https://github.com/nix-community/home-manager?ref=release-26.05&rev=$rev&shallow=1" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["hash"])') || return 1
  echo "rev=$rev github:=$a git+https:=$b"
  [ -n "$a" ] && [ "$a" = "$b" ]
}
check "5. github: と git+https: の narHash が一致" nar_match

# 6. ラッパーの外（gh / curl）は shim を通らない
not_via_shim() {
  local issuer
  # 対話シェルの no_proxy に api.github.com が入っていない
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

# 8. ラッパーを通らない本物の nix にも shim の設定が効いている（nix.conf 経由）
real_nix_conf() {
  local real=/nix/var/nix/profiles/default/bin/nix cert tokens
  cert=$(env -u NIX_SSL_CERT_FILE "$real" config show ssl-cert-file 2>&1)
  tokens=$("$real" config show access-tokens 2>&1)
  echo "ssl-cert-file=$cert access-tokens=$tokens"
  [ "$cert" = /etc/nix/ca-bundle.pem ] && echo "$tokens" | grep -q 'github.com=gh-shim-dummy'
}
check "8. 本物の nix でも ssl-cert-file / access-tokens が shim 用" real_nix_conf

if grep -q 'WARN: home-manager switch failed' "$LOG" 2>/dev/null; then
  echo "⚠️  $LOG に home-manager の失敗が記録されている"
fi

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
