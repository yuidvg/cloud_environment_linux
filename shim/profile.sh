# /etc/profile.d/zz-gh-shim.sh として置く（setup.sh が配置）。
# ログインシェル（bash -l）でも、home-manager の有無に関係なく、gh-shim 付きの nix ラッパーが
# 本物の nix より先に見つかるようにする。名前の zz- は、ほかの profile.d（nix.sh など）より後に
# 読ませて PATH の先頭を取るため。
if [ -r /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi
case "$PATH" in
  /root/.local/bin:*) ;;
  *) PATH="/root/.local/bin:$PATH"; export PATH ;;
esac
