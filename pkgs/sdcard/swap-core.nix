# Activate a core (arm|riscv) on a mounted Duo S FAT boot partition.
#
# Only fip.bin moves. The SG2000 BootROM reads exactly one fip.bin, so that is
# the single thing that selects a boot chain, and it is the one file that
# cannot be made per-core. Everything downstream is already per-core: each
# core's U-Boot is built to read its own /<core>/extlinux/extlinux.conf, so no
# shared config has to be kept in sync.
{ pkgs }:
pkgs.writeShellApplication {
  name = "swap-core";
  runtimeInputs = [ pkgs.coreutils ];
  text = ''
    usage() { echo "usage: swap-core <arm|riscv> [bootdir, default /boot]" >&2; exit 1; }
    core="''${1:-}"
    # The boot partition is mounted at /boot on the badge, so the common case
    # needs no path.
    bootdir="''${2:-/boot}"
    case "$core" in arm|riscv) ;; *) usage ;; esac
    if [ ! -d "$bootdir" ] || [ ! -f "$bootdir/fip-arm.bin" ] || [ ! -f "$bootdir/fip-riscv.bin" ]; then
      echo "swap-core: '$bootdir' is not a Duo S boot partition (missing fip-arm.bin/fip-riscv.bin)" >&2
      exit 1
    fi
    # Check the target core actually has a kernel to boot before we point the
    # BootROM at it. Without this a swap would succeed and then strand the
    # board at the U-Boot prompt.
    src_conf="$bootdir/$core/extlinux/extlinux.conf"
    if [ ! -f "$src_conf" ]; then
      echo "swap-core: missing $src_conf, so the $core U-Boot would have nothing to boot" >&2
      exit 1
    fi
    cp -f "$bootdir/fip-$core.bin" "$bootdir/fip.bin"
    sync
    echo "swap-core: active core is now $core; flip the board switch to $core and reboot."
  '';
}
