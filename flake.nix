{
  description = "NixOS for the Milk-V Duo S badge (Sophgo SG2000, dual ARM + RISC-V).";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      # core "arm" -> aarch64, "riscv" -> riscv64. One place names the arch.
      hostPlatformOf = core: if core == "arm" then "aarch64-linux" else "riscv64-linux";

      # buildPlatform lets us cross-compile, the reliable bootstrap path
      # (QEMU native build is flaky). x86_64 and aarch64 are dev-host options.
      buildHosts = [
        "x86_64-linux"
        "aarch64-linux"
        "riscv64-linux"
      ];

      mkDuoS =
        { core, buildPlatform }:
        nixpkgs.lib.nixosSystem {
          modules = [
            {
              nixpkgs.hostPlatform = hostPlatformOf core;
              nixpkgs.buildPlatform = buildPlatform;
            }
            ./modules/duo-s/common.nix
            ./modules/duo-s/base.nix
            ./modules/duo-s/wifi.nix
            ./modules/duo-s/leds.nix
            ./modules/duo-s/core-${core}.nix
          ];
        };

      # All sensible (core, buildPlatform) pairs for one core. We keep the
      # native host plus the practical cross hosts, and drop nonsense like
      # building an aarch64 target from a riscv64 box.
      configsFor =
        core:
        let
          hostPlatform = hostPlatformOf core;
          valid = lib.filter (b: b == hostPlatform || b != "riscv64-linux") buildHosts;
        in
        lib.mapAttrs' (
          buildPlatform: cfg:
          lib.nameValuePair (
            "duo-s-${core}"
            + lib.optionalString (
              buildPlatform != hostPlatform
            ) "-${lib.head (lib.splitString "-" buildPlatform)}"
          ) cfg
        ) (lib.genAttrs valid (buildPlatform: mkDuoS { inherit core buildPlatform; }));

      # Build the combined dual-system SD image for a given BUILD host,
      # selecting the cross/native nixos variants whose buildPlatform == that host.
      shortArch = p: lib.head (lib.splitString "-" p);
      buildSystems = [ "x86_64-linux" "aarch64-linux" ];
      sdcardFor =
        buildSystem:
        let
          pkgs = nixpkgs.legacyPackages.${buildSystem};
          armSys = self.nixosConfigurations.${
            if buildSystem == "aarch64-linux" then "duo-s-arm" else "duo-s-arm-x86_64"
          };
          riscvSys = self.nixosConfigurations."duo-s-riscv-${shortArch buildSystem}";
          fipArmReal = import ./pkgs/firmware/fip.nix { inherit pkgs; };
          fipRiscvReal = import ./pkgs/firmware/fip.nix { inherit pkgs; core = "riscv"; };
          mkCombinedRoot = import ./pkgs/sdcard/make-combined-root.nix { inherit pkgs; };
          mkBoot = import ./pkgs/sdcard/make-boot-dir.nix { inherit pkgs; };
          mkImg = import ./pkgs/sdcard/make-sd-image.nix { inherit pkgs; };
          root = mkCombinedRoot { systems = [ armSys riscvSys ]; label = "NIXOS_ROOT"; };
          # Both ARM and RISC-V now use real firmware.
          bootDir = mkBoot {
            inherit armSys riscvSys;
            fipArm = fipArmReal;
            fipRiscv = fipRiscvReal;
            defaultCore = "arm";
          };
        in
        mkImg { inherit bootDir root; };
    in
    {
      # Native -> duo-s-<core>; cross -> duo-s-<core>-<buildArch>. So:
      #   duo-s-arm, duo-s-arm-x86_64,
      #   duo-s-riscv, duo-s-riscv-x86_64, duo-s-riscv-aarch64
      nixosConfigurations = lib.mergeAttrsList (
        map configsFor [
          "arm"
          "riscv"
        ]
      );

      packages = lib.genAttrs buildSystems (buildSystem: rec {
        duo-s-sdcard = sdcardFor buildSystem;
        default = duo-s-sdcard;
      });
    };
}
