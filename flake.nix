{
  description = "Rebuild the world... or just the Nix Badge.";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-esp-dev.url = "github:mirrexagon/nixpkgs-esp-dev";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-compat.url = "https://flakehub.com/f/edolstra/flake-compat/1.tar.gz";
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      nixpkgs-esp-dev,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.flake-parts.flakeModules.easyOverlay
      ];

      flake = {
        # nothing for now
      };

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          config,
          system,
          inputs',
          pkgs,
          final,
          ...
        }:
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [
              nixpkgs-esp-dev.overlays.default
              self.overlays.default
            ];
            config = { };
          };

          overlayAttrs = {
            # nothing for now
            nixbadge = pkgs.callPackage ./pkgs/nixbadge rec {
              target = "esp32c6";
              esp-idf = pkgs."esp-idf-${target}";
            };
          };

          packages = {
            default = pkgs.nixbadge;
            inherit (pkgs) nixbadge;
          };

          devShells = {
            default = pkgs.nixbadge.shell;
          };
        };
    };
}
