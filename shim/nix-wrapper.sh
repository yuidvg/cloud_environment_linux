#!/bin/bash
# /root/.local/bin/nix として置くラッパー。
# 毎回 shim の前提（hosts・CA バンドル・shim プロセス）を確認してから本物の nix を exec する。
# no_proxy / NIX_SSL_CERT_FILE は nix のプロセスにだけ効かせる
# （gh や curl などほかのツールはこれまでどおりプロキシ経由。.bashrc には書かない）。

/opt/gh-shim/ensure.sh

export no_proxy="${no_proxy:+$no_proxy,}api.github.com"
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}api.github.com"
export NIX_SSL_CERT_FILE=/etc/nix/ca-bundle.pem

# NixOS/nix-installer（--init none）でのデフォルトプロファイル
exec /nix/var/nix/profiles/default/bin/nix "$@"
