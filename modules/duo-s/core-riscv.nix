# RISC-V T-Head C906 core for the Milk-V Duo S (Sophgo SG2000).
# Uses our authored sg2000-milkv-duo-s-riscv.dts, compiled standalone from
# the riscv kernel source's DTS include tree (sg2002.dtsi path).
# hostPlatform/buildPlatform are set by mkDuoS in flake.nix.
{ config, pkgs, lib, ... }:
{
  # Use our authored Duo S RISC-V DTB, compiled standalone from the kernel DTS sources.
  # The board switch must be physically set to RISC-V to boot this.
  hardware.deviceTree.name = "sophgo/sg2000-milkv-duo-s.dtb";
  hardware.deviceTree.package = lib.mkForce (import ../../pkgs/firmware/duos-riscv-dtb.nix {
    inherit pkgs;
    kernel = config.boot.kernelPackages.kernel;
  });

  # TODO: firmware. RISC-V boot chain is vendor FSBL -> OpenSBI -> U-Boot.

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_ROOT";
    fsType = "ext4";
  };
}
