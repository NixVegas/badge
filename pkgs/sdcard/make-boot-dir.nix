# Build the FAT boot-partition tree for the dual-core Duo S card: per-core
# kernel/initrd/dtb + extlinux, both fips, and the default core marked active.
#
# There is deliberately NO shared /extlinux/extlinux.conf. Each core's U-Boot
# is built to read its own /<core>/extlinux/extlinux.conf (see
# pkgs/firmware/uboot-duos-{arm,riscv}.nix).
#
# fip.bin is the POLYGLOT fip (#48): one static image the BootROM reads that
# boots EITHER core depending on the GPIO_RTX strap, so core-switch is a live
# latch flip with no SD change. fip-arm.bin / fip-riscv.bin are the per-core
# split fips, kept purely as known-good recovery blobs (cp fip-arm.bin fip.bin
# to fall back). defaultCore no longer selects fip.bin (the polyglot serves
# both); it only affects which core the latch defaults to at first boot.
{ pkgs }:
{ armSys, riscvSys, fipArm, fipRiscv, fipPolyglot, defaultCore ? "arm" }:
pkgs.runCommand "duos-boot-dir" { } ''
  mkdir -p "$out"

  ${armSys.config.boot.loader.generic-extlinux-compatible.populateCmd} \
    -c ${armSys.config.system.build.toplevel} -d "$out/arm"
  ${riscvSys.config.boot.loader.generic-extlinux-compatible.populateCmd} \
    -c ${riscvSys.config.system.build.toplevel} -d "$out/riscv"

  sed -i 's|\.\./nixos/|/arm/nixos/|g'   "$out/arm/extlinux/extlinux.conf"
  sed -i 's|\.\./nixos/|/riscv/nixos/|g' "$out/riscv/extlinux/extlinux.conf"

  cp ${fipArm}      "$out/fip-arm.bin"
  cp ${fipRiscv}    "$out/fip-riscv.bin"
  cp ${fipPolyglot} "$out/fip.bin"
''
