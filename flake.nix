{
  description = "Claude Code cloud environment (Ubuntu x86_64, root) managed by home-manager";

  # github: 形式のままでよい（クラウド環境では gh-shim が api.github.com の代わりに応答する）
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # 購入調査の CLI。nixpkgs は follows しない（meguri 自身の flake.lock でビルドとテストを確かめている）
    meguri.url = "github:yuidvg/meguri";
  };

  outputs =
    inputs@{ nixpkgs, home-manager, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      homeConfigurations.root = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [ ./home ];
        extraSpecialArgs = { inherit inputs; };
      };

      # setup.sh は `nix run <this flake>#home-manager` で lock に固定した home-manager を使う
      packages.${system} = {
        home-manager = home-manager.packages.${system}.home-manager;
        default = home-manager.packages.${system}.home-manager;
      };
    };
}
