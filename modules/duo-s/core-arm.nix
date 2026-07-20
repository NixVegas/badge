# ARM Cortex-A53 core for the Milk-V Duo S (Sophgo SG2000).
# Mainline carries the SG2000 SoC device tree on arm64
# (arch/arm64/boot/dts/sophgo/sg2000.dtsi), so we run a stock mainline kernel.
# hostPlatform/buildPlatform are set by mkDuoS in flake.nix.
{
  config,
  pkgs,
  lib,
  ...
}:
{
  # Our Duo S aarch64 DTB, compiled standalone from the mainline kernel DTS
  # sources (see pkgs/firmware/duos-arm-dtb.nix). The board switch must be
  # physically set to ARM to boot this.
  hardware.deviceTree.name = "sophgo/sg2000-milkv-duo-s.dtb";
  hardware.deviceTree.package = lib.mkForce (import ../../pkgs/firmware/duos-arm-dtb.nix {
    inherit pkgs;
    kernel = config.boot.kernelPackages.kernel;
  });

  # TODO: firmware. ARM boot chain is vendor FSBL -> ATF (BL31) -> U-Boot.
  # The FSBL is a vendor blob regardless of core; package fip.bin here.

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_ROOT";
    fsType = "ext4";
  };
}
