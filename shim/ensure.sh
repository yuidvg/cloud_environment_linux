#!/bin/bash
# gh-shim の前提を毎回そろえる（冪等）。/opt/gh-shim/ensure.sh として置かれ、
# setup.sh と nix ラッパーの両方から呼ばれる。
#   1. /etc/hosts に 127.0.0.1 api.github.com（VM の復元で消える可能性がある）
#   2. /etc/nix/ca-bundle.pem をシステム CA + shim CA で作り直す（プロキシ CA の入れ替わり対策）
#   3. shim が動いていなければ起動し、ポートが開くまで待つ
# shim の CA はシステムの信頼ストアには入れない（Nix だけが信頼する）。

grep -q '^127\.0\.0\.1 api\.github\.com$' /etc/hosts 2>/dev/null \
  || echo '127.0.0.1 api.github.com' >> /etc/hosts

mkdir -p /etc/nix
cat /etc/ssl/certs/ca-certificates.crt /opt/gh-shim/ca.crt > /etc/nix/ca-bundle.pem.tmp.$$ \
  && mv -f /etc/nix/ca-bundle.pem.tmp.$$ /etc/nix/ca-bundle.pem

if ! (exec 3<>/dev/tcp/127.0.0.1/443) 2>/dev/null; then
  nohup python3 /opt/gh-shim/shim.py >>/var/log/gh-shim.log 2>&1 </dev/null &
  for _ in $(seq 50); do
    (exec 3<>/dev/tcp/127.0.0.1/443) 2>/dev/null && break
    sleep 0.1
  done
fi
