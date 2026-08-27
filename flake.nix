{
  description = "Rebuild the world... or just the Nix Badge. (+ Milk-V Duo S badgeOS)";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # badgeOS (Milk-V Duo S) is pinned to nixpkgs 26.05, kept separate from the
    # ESP32 badge's unstable nixpkgs so each half builds against what it expects.
    nixpkgs-2605.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-esp-dev.url = "github:mirrexagon/nixpkgs-esp-dev";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-compat.url = "https://flakehub.com/f/edolstra/flake-compat/1.tar.gz";
    flakever.url = "github:numinit/flakever";
    # deploy-rs: push a closure + activate it on the badge over SSH. Follows the
    # badge's nixpkgs so the target-arch activate wrapper matches the systems.
    deploy-rs.url = "github:serokell/deploy-rs";
    deploy-rs.inputs.nixpkgs.follows = "nixpkgs-2605";
    # psyclyx/fix: a fast, parallel Nix-language evaluator (Zig). It has no
    # flake.nix (it uses npins), so it comes in as a plain source and is built
    # via its own default.nix overlay against our nixpkgs (which has zig_0_16).
    # Used at build time to evaluate the pure-Nix bling screens into blobs.
    fix = {
      url = "github:psyclyx/fix";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      flakever,
      nixpkgs-esp-dev,
      nixpkgs-2605,
      deploy-rs,
      ...
    }:
    let
      flakeverConfig = flakever.lib.mkFlakever {
        inherit inputs;

        digits = [
          1
          2
          2
        ];
      };

      # ----------------------------------------------------------------------
      # badgeOS: NixOS for the Milk-V Duo S badge (Sophgo SG2000, dual ARM +
      # RISC-V). Merged in from ~/badgeos; kept on its own nixpkgs 26.05 input.
      # ----------------------------------------------------------------------
      duosLib = nixpkgs-2605.lib;

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
        nixpkgs-2605.lib.nixosSystem {
          modules = [
            {
              nixpkgs.hostPlatform = hostPlatformOf core;
              nixpkgs.buildPlatform = buildPlatform;
            }
            ./modules/duo-s/common.nix
            ./modules/duo-s/base.nix
            ./modules/duo-s/wifi.nix
            ./modules/duo-s/leds.nix
            ./modules/duo-s/bling.nix
            ./modules/duo-s/deploy.nix
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
          valid = duosLib.filter (b: b == hostPlatform || b != "riscv64-linux") buildHosts;
        in
        duosLib.mapAttrs' (
          buildPlatform: cfg:
          duosLib.nameValuePair (
            "duo-s-${core}"
            + duosLib.optionalString (
              buildPlatform != hostPlatform
            ) "-${duosLib.head (duosLib.splitString "-" buildPlatform)}"
          ) cfg
        ) (duosLib.genAttrs valid (buildPlatform: mkDuoS { inherit core buildPlatform; }));

      # Build the combined dual-system SD image for a given BUILD host,
      # selecting the cross/native nixos variants whose buildPlatform == that host.
      shortArch = p: duosLib.head (duosLib.splitString "-" p);
      duosBuildSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      sdcardFor =
        buildSystem:
        let
          pkgs = nixpkgs-2605.legacyPackages.${buildSystem};
          armSys =
            self.nixosConfigurations.${
              if buildSystem == "aarch64-linux" then "duo-s-arm" else "duo-s-arm-x86_64"
            };
          riscvSys = self.nixosConfigurations."duo-s-riscv-${shortArch buildSystem}";
          fipArmReal = import ./pkgs/firmware/fip.nix { inherit pkgs; };
          fipRiscvReal = import ./pkgs/firmware/fip.nix {
            inherit pkgs;
            core = "riscv";
          };
          mkCombinedRoot = import ./pkgs/sdcard/make-combined-root.nix { inherit pkgs; };
          mkBoot = import ./pkgs/sdcard/make-boot-dir.nix { inherit pkgs; };
          mkImg = import ./pkgs/sdcard/make-sd-image.nix { inherit pkgs; };
          root = mkCombinedRoot {
            systems = [
              armSys
              riscvSys
            ];
            label = "NIXOS_ROOT";
          };
          # Both ARM and RISC-V now use real firmware.
          bootDir = mkBoot {
            inherit armSys riscvSys;
            fipArm = fipArmReal;
            fipRiscv = fipRiscvReal;
            defaultCore = "arm";
          };
        in
        mkImg { inherit bootDir root; };

      # Native -> duo-s-<core>; cross -> duo-s-<core>-<buildArch>. So:
      #   duo-s-arm, duo-s-arm-x86_64,
      #   duo-s-riscv, duo-s-riscv-x86_64, duo-s-riscv-aarch64
      duosNixosConfigurations = duosLib.mergeAttrsList (
        map configsFor [
          "arm"
          "riscv"
        ]
      );
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.flake-parts.flakeModules.easyOverlay
      ];

      flake = {
        versionTemplate = "2.0-<lastModifiedDate>-<rev>";

        # badgeOS NixOS systems (built against nixpkgs 26.05).
        nixosConfigurations = duosNixosConfigurations;

        # deploy-rs: two nodes, one per core, both reaching the same badge (only
        # one core is booted at a time). Deploy the node matching the CURRENTLY
        # booted core, e.g. `nix run github:serokell/deploy-rs -- .#nixbadge-duos-arm`
        # (or -riscv). Each node activates ONLY its own /boot/<core> subtree and
        # never rewrites fip.bin, so a deploy cannot switch cores -- use
        # `nix-badge core <arch>` + reboot for that. The cross (-x86_64) systems
        # build on an x86_64 dev host; see modules/duo-s/deploy.nix for the
        # dual-core installer and the passwordless-sudo requirement.
        deploy.nodes =
          let
            # deploy-rs only ships lib.<system> for its flake-utils systems
            # (x86_64/aarch64/darwin -- no riscv64). Its lib is just its overlay
            # applied to a nixpkgs, so build the per-target lib ourselves against
            # nixpkgs-2605; this gives a working riscv64 node too. The activate
            # wrapper is the target-arch deploy-rs binary and builds at deploy time.
            #
            # CROSS, not native: deploy from an x86_64 dev host. If we imported
            # nixpkgs with `system = <target>` (native aarch64/riscv64), the
            # deploy-rs Rust binary + the activatable-nixos-system wrapper would
            # be native target-arch builds and, with no target remote builder,
            # nix falls back to qemu user emulation (a `qemu-aarch64 rustc` grind
            # that made the first deploy crawl). Instead we take the x86_64 pkgs
            # set's `pkgsCross.<target>` (buildPlatform=x86_64 / hostPlatform=
            # target) and apply the deploy-rs overlay on top -- the overlay
            # propagates into pkgsCross, so `deploy-rs.deploy-rs` and the wrapper
            # build ON x86_64 with a gcc/rust cross toolchain. The RUNTIME output
            # is byte-for-byte a target-arch package (aarch64/riscv64 activate
            # binary + shebangs), just cross-produced instead of emulated.
            #
            # crossName maps our deploy node system -> nixpkgs pkgsCross attr.
            crossName = {
              "aarch64-linux" = "aarch64-multiplatform";
              "riscv64-linux" = "riscv64";
            };
            deployLibFor =
              system:
              (import nixpkgs-2605 {
                system = "x86_64-linux";
                overlays = [ deploy-rs.overlays.default ];
              }).pkgsCross.${crossName.${system}}.deploy-rs.lib;
            mkNode = system: nixosCfg: {
              hostname = "10.8.3.128"; # current DHCP address; override with --hostname
              sshUser = "badge";
              user = "root";
              profiles.system.path = (deployLibFor system).activate.nixos nixosCfg;
            };
          in
          {
            nixbadge-duos-arm = mkNode "aarch64-linux" self.nixosConfigurations."duo-s-arm-x86_64";
            nixbadge-duos-riscv = mkNode "riscv64-linux" self.nixosConfigurations."duo-s-riscv-x86_64";
          };
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
            nixbadge = pkgs.callPackage ./pkgs/idf/nixbadge rec {
              target = "esp32c6";
              esp-idf = pkgs."esp-idf-${target}";
            };
            flakever = flakeverConfig;
          }
          # badgeOS combined dual-core SD image (nixpkgs 26.05), on the hosts
          # that can build it.
          // duosLib.optionalAttrs (duosLib.elem system duosBuildSystems) {
            duo-s-sdcard = sdcardFor system;
          };

          packages = {
            default = pkgs.duo-s-sdcard;
            v1 = pkgs.nixbadge-v1;
            # OpenOCD with the CH347 driver, for JTAG over the badge's J1 port.
            openocd-ch347 = import ./pkgs/openocd-ch347.nix { inherit pkgs; };
            # The `fix` evaluator (psyclyx/fix), built via its overlay on our
            # nixpkgs. Exposed so the bling content bake can use it.
            fix = (pkgs.extend (import inputs.fix { }).overlay).fix;
            # A pure-Nix OLED animation baked to a BADA blob by `fix` -- the
            # proof that the badge's screens can be authored in Nix. Play with
            # `nix-badge bling --badapple <result>/bling-anim.bin`.
            bling-demo = import ./pkgs/badge/bling-content {
              inherit pkgs;
              fix = (pkgs.extend (import inputs.fix { }).overlay).fix;
            };
          };

          devShells = {
            v1 = pkgs.nixbadge-v1.shell;
          };
        };
    };
}
