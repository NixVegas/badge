# Make deploy-rs (and a manual on-device nixos-rebuild) safe on the dual-core
# badge. See flake.nix `deploy.nodes` for the two targets, one per core.
#
# The badge's FAT boot partition is NOT a stock NixOS /boot. It holds a per-core
# tree built off-device by pkgs/sdcard/make-boot-dir.nix:
#   /fip.bin /fip-arm.bin /fip-riscv.bin
#   /arm/nixos/... /arm/extlinux/extlinux.conf
#   /riscv/nixos/... /riscv/extlinux/extlinux.conf
# Each core's U-Boot reads its OWN /<core>/extlinux/extlinux.conf; only fip.bin
# selects the core. The stock generic-extlinux-compatible installer writes
# generations to the /boot ROOT with ../nixos/ paths, which clobbers this layout
# and leaves the board unbootable.
#
# So override the installer to update ONLY the running core's subtree and never
# touch fip.bin, fip-*.bin, or the other core. Core switching stays with
# nix-badge / swap-core. The image build is unaffected: make-boot-dir.nix calls
# populateCmd directly, not this installer.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Baked per system: the arm closure installs into /arm, the riscv one into /riscv.
  core = if pkgs.stdenv.hostPlatform.isAarch64 then "arm" else "riscv";
in
{
  # The 416 MB FAT is shared by both cores, and each generation is ~40 MB
  # (kernel+initrd+dtb). Keep 3 per core so the other core's tree and the fips
  # still fit. Also caps what the on-device installer prunes to.
  boot.loader.generic-extlinux-compatible.configurationLimit = 3;

  # Dual-core-aware bootloader install. switch-to-configuration calls this with
  # the new system's toplevel as $1, exactly like the stock install-extlinux-conf.sh
  # (which runs `populateCmd -c "$1" -d /boot`); we redirect it to the core subtree.
  system.build.installBootLoader = lib.mkForce (
    pkgs.writeShellScript "install-duos-bootloader" ''
      set -euo pipefail
      toplevel="$1"
      dir="/boot/${core}"
      # Populate the running core's subtree: adds this generation, prunes to the
      # configurationLimit. Leaves fip.bin, fip-*.bin, and the other core alone.
      ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c "$toplevel" -d "$dir"
      # U-Boot resolves LABEL paths from the FAT root, so rewrite the builder's
      # relative ../nixos/ to absolute /${core}/nixos/ (as make-boot-dir.nix does).
      ${pkgs.gnused}/bin/sed -i 's|\.\./nixos/|/${core}/nixos/|g' "$dir/extlinux/extlinux.conf"
      echo "duos: installed the ${core} boot tree in $dir (fip.bin and the other core untouched)"
    ''
  );

  # deploy-rs activates as root over SSH via sudo, non-interactively. The badge
  # user is in wheel; allow it to sudo without a password so a deploy does not
  # hang on a prompt. This is a dev badge; pair it with SSH key auth (add your
  # pubkey to users.users.badge.openssh.authorizedKeys) rather than relying on the
  # weak console password over the network.
  security.sudo.wheelNeedsPassword = false;

  # deploy-rs pushes the closure with `nix copy` as the SSH user (badge), whose
  # nix-daemon otherwise rejects the locally-built, unsigned paths with "lacks a
  # signature by a trusted key". Trust the wheel group so the copy is accepted
  # without needing the dev host's paths signed.
  nix.settings.trusted-users = [ "@wheel" ];
}
