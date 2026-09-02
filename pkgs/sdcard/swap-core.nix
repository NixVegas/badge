# Guide a core switch on a Duo S FAT boot partition (#48).
#
# fip.bin is now the POLYGLOT fip: ONE image the BootROM reads that boots EITHER
# core depending on the GPIO_RTX strap. So a core-switch no longer copies a fip
# -- it is a pure LATCH flip (`nix-badge core <arch>` + reboot in AUTO). This
# command just validates the boot partition and points you at the latch; the
# per-core fip-arm.bin / fip-riscv.bin are kept only as recovery blobs.
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
    if [ ! -d "$bootdir" ] || [ ! -f "$bootdir/fip.bin" ]; then
      echo "swap-core: '$bootdir' is not a Duo S boot partition (missing fip.bin)" >&2
      exit 1
    fi
    # Check the target core actually has a kernel to boot before switching to
    # it. Without this a swap would succeed and then strand the board at the
    # U-Boot prompt.
    src_conf="$bootdir/$core/extlinux/extlinux.conf"
    if [ ! -f "$src_conf" ]; then
      echo "swap-core: missing $src_conf, so the $core U-Boot would have nothing to boot" >&2
      exit 1
    fi
    echo "swap-core: fip.bin is the polyglot fip -- it already boots $core, no copy needed."
    echo "swap-core: set the core-select latch and reboot (board switch in AUTO):"
    echo "    nix-badge core $core   # then reboot"
  '';
}
