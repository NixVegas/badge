# Activate a core (arm|riscv) on a mounted Duo S FAT boot partition by swapping
# the active fip.bin and extlinux.conf. The SG2000 BootROM only reads one
# fip.bin, so switching cores is a file swap plus the physical board switch.
{ pkgs }:
pkgs.writeShellApplication {
  name = "swap-core";
  runtimeInputs = [ pkgs.coreutils ];
  text = ''
    usage() { echo "usage: swap-core <arm|riscv> <bootdir>" >&2; exit 1; }
    core="''${1:-}"
    bootdir="''${2:-}"
    case "$core" in arm|riscv) ;; *) usage ;; esac
    [ -n "$bootdir" ] || usage
    if [ ! -d "$bootdir" ] || [ ! -f "$bootdir/fip-arm.bin" ] || [ ! -f "$bootdir/fip-riscv.bin" ]; then
      echo "swap-core: '$bootdir' is not a Duo S boot partition (missing fip-arm.bin/fip-riscv.bin)" >&2
      exit 1
    fi
    cp -f "$bootdir/fip-$core.bin" "$bootdir/fip.bin"
    mkdir -p "$bootdir/extlinux"
    cp -f "$bootdir/$core/extlinux/extlinux.conf" "$bootdir/extlinux/extlinux.conf"
    sync
    echo "swap-core: active core is now $core; flip the board switch to $core and reboot."
  '';
}
