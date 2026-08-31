# The initrd OLED boot-info splash (#29): the panel lights during EARLY BOOT with
# the bootinfo screen (NixOS version + kernel release + arch), rendered by a live
# fix Engine in the initrd -- the same trick the LED ring already does for its
# declarative eval pattern (bling.nix). The versions come from uname(2) and, with
# no /etc/os-release in the initrd, the `init=` store-path label on /proc/cmdline.
#
# The binary is the SAME static fix-only nix-badge the bling/initrd instance uses
# (identical import args -> identical store path), so the splash adds no second
# binary to the initrd. The content is a MINIMAL tree -- lib/ + the bootinfo
# screen -- picked out of the shared contentTree: shipping all of oled.d would
# drag the Bad Apple frame data into a RAM-loaded initrd on a 351 MB board.
#
# Unlike the bling unit this one does NOT survive switch_root: the stage-2 oled
# service starts its own Engine and must own the panel/I2C bus, so the initrd
# instance dies in the final kill (a brief blank across the handover is fine).
# The I2C stack needs no initrd module work: I2C=y, I2C_CHARDEV=y and
# I2C_DESIGNWARE_PLATFORM=y are all built in, so /dev/i2c-1 exists from devtmpfs
# before initrd userspace starts.
{
  config,
  lib,
  pkgs,
  badgeFixSrc,
  badgeContentTree,
  ...
}:
let
  cfg = config.nixbadge.oled;

  # Same args as bling.nix's pkg -> the derivations dedupe; see that file for why
  # the initrd instance stays static and C-API-free.
  pkg = import ../../pkgs/badge/nix-badge.nix {
    inherit pkgs;
    fixSrc = badgeFixSrc;
    nixEval = false;
  };

  # lib/ (draw + fonts, a few hundred KB of Nix text) + ONLY the bootinfo screen,
  # structure-preserved so `--content-root` resolves its <nixbadge/lib/...> imports.
  bootTree = pkgs.buildPackages.runCommand "nixbadge-bootinfo-initrd" { } ''
    mkdir -p "$out/oled.d"
    cp -r ${badgeContentTree}/lib "$out/lib"
    cp ${badgeContentTree}/oled.d/15-bootinfo.nix "$out/oled.d/15-bootinfo.nix"
  '';
in
{
  config = lib.mkIf cfg.enable {
    boot.initrd.systemd.storePaths = [
      "${pkg}/bin/nix-badge"
      bootTree
    ];

    boot.initrd.systemd.services.nixbadge-oled-boot = {
      description = "nixbadge OLED boot-info splash";
      wantedBy = [ "initrd.target" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "simple";
        ExecStart = lib.concatStringsSep " " [
          "${pkg}/bin/nix-badge"
          "oled"
          "--content-root ${bootTree}"
          "--eval-screen ${bootTree}/oled.d/15-bootinfo.nix"
          "--oled-width ${toString cfg.width}"
          "--oled-height ${toString cfg.height}"
          "--oled-controller ${cfg.controller}"
          "--gc-budget-mb ${toString cfg.gcBudgetMb}"
        ];
        # on-failure, not always: the daemon exits 0 when no panel answers on the
        # bus (a badge assembled without the OLED), and we must not spin on that.
        Restart = "on-failure";
        RestartSec = 1;
      };
    };
  };
}
