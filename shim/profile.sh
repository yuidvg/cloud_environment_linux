# /etc/profile.d/zz-gh-shim.sh として置く（setup.sh が配置）。
# ログインシェル（bash -l）でも、home-manager の有無に関係なく nix のプロファイルを読む。
# gh-shim 自体は iptables と intercept で効くので、PATH の順番には依存しない。
if [ -r /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi
