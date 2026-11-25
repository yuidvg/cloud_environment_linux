#!/bin/bash
# /root/.local/bin/nix として置くラッパー。nix-build / nix-shell / nix-env などの名前でも
# シンボリックリンクで置かれ、呼ばれた名前と同じ本物のコマンドを exec する。
# 毎回 shim の前提（hosts・CA バンドル・nix.conf・shim プロセス）を確認する。
#
# ssl-cert-file と access-tokens は nix.conf（/etc/nix/gh-shim.conf）で渡すので、ラッパーを
# 通らない nix にも効く。ラッパーでしか渡せないのは no_proxy だけ（Nix の設定に proxy の項目は
# ない）。no_proxy は nix のプロセスにだけ効かせ、.bashrc には書かない
# （gh や curl などほかのツールはこれまでどおりプロキシ経由）。

/opt/gh-shim/ensure.sh

export no_proxy="${no_proxy:+$no_proxy,}api.github.com"
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}api.github.com"
# nix.conf の設定が優先されるが、念のため環境変数もそろえる
export NIX_SSL_CERT_FILE=/etc/nix/ca-bundle.pem

# NixOS/nix-installer（--init none）でのデフォルトプロファイル
exec "/nix/var/nix/profiles/default/bin/${0##*/}" "$@"
