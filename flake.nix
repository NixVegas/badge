{
  description = "Rebuild the world... or just the Nix Badge.";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-esp-dev.url = "github:mirrexagon/nixpkgs-esp-dev";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-compat.url = "https://flakehub.com/f/edolstra/flake-compat/1.tar.gz";
    flakever.url = "github:numinit/flakever";
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      flakever,
      nixpkgs-esp-dev,
      ...
    }:
    let
      flakeverConfig = flakever.lib.mkFlakever {
        inherit inputs;

        digits = [ 1 2 2 ];
      };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.flake-parts.flakeModules.easyOverlay
      ];

      flake = {
        versionTemplate = "1.1pre-<lastModifiedDate>-<rev>";
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
            config = {
              permittedInsecurePackages = [
                "python3.13-ecdsa-0.19.1"
              ];
            };
          };

          overlayAttrs = {
            # nothing for now
            nixbadge = pkgs.callPackage ./pkgs/nixbadge rec {
              target = "esp32c6";
              esp-idf = pkgs."esp-idf-${target}";
            };
            flakever = flakeverConfig;
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
