# クラウド環境（root）の home-manager 設定。
# 編集して push → 環境のキャッシュが作り直されたあとの新しいセッションから反映（README「パッケージや環境変数を追加する」参照）。
# 秘密情報はここに書かない（公開リポジトリ）。API キーなどはクラウド環境の設定側で渡す。
{ config, pkgs, ... }:
{
  home.username = "root";
  home.homeDirectory = "/root";
  home.stateVersion = "26.05";

  # 入れたい CLI ツール
  home.packages = with pkgs; [
    fd
    bat
    eza
    just
    ripgrep
    jq
  ];

  # 環境変数（bash -lc / bash -ic の両方で見える）
  home.sessionVariables = {
    EDITOR = "vim";
    # scripts/check.sh が sessionVariables の反映確認に使う目印
    CLOUD_ENV_LINUX = "1";
  };

  programs.home-manager.enable = true;

  # Claude の Bash ツールからも nix と環境変数が見えるよう .bashrc で読み込む。
  # bashrcExtra は非対話シェルでも実行される位置（interactive ガードより前）に入る。
  programs.bash = {
    enable = true;
    bashrcExtra = ''
      # Nix（NixOS/nix-installer, --init none）のプロファイル
      if [ -r /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
      fi
      # home.sessionVariables（プロファイルの場所に依存しないよう store パスで直接読む）
      . "${config.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh"
    '';
  };

  programs.git = {
    enable = true;
    settings.alias.st = "status";
  };
}
