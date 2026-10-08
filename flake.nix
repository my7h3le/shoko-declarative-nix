{
  description = "Declarative bootstrap of a Shoko Server instance (first-run wizard, users, AniDB, API keys) via nixflix's mkSecureCurl";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixflix = {
      url = "github:kiriwalawren/nixflix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixflix,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      allSystems = systems ++ [
        "aarch64-darwin"
      ];
    in
    {
      nixosModules.default = import ./module.nix { inherit nixflix; };
      nixosModules.shoko-declarative = self.nixosModules.default;

      checks = forAllSystems (pkgs: {
        vm = import ./tests/vm.nix {
          inherit pkgs;
          module = self.nixosModules.default;
        };
      });

      formatter = lib.genAttrs allSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);
    };
}
