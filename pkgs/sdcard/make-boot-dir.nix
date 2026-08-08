# Build the FAT boot-partition tree for the dual-core Duo S card: per-core
# kernel/initrd/dtb + extlinux, both fips, and the default core marked active.
#
# There is deliberately NO shared /extlinux/extlinux.conf. Each core's U-Boot
# is built to read its own /<core>/extlinux/extlinux.conf (see
# pkgs/firmware/uboot-duos-{arm,riscv}.nix), so the only file that selects a
# core is fip.bin. That is what the BootROM reads, and it is the one thing that
# cannot be made per-core.
{ pkgs }:
{ armSys, riscvSys, fipArm, fipRiscv, defaultCore ? "arm" }:
pkgs.runCommand "duos-boot-dir" { } ''
  mkdir -p "$out"

  ${armSys.config.boot.loader.generic-extlinux-compatible.populateCmd} \
    -c ${armSys.config.system.build.toplevel} -d "$out/arm"
  ${riscvSys.config.boot.loader.generic-extlinux-compatible.populateCmd} \
    -c ${riscvSys.config.system.build.toplevel} -d "$out/riscv"

  sed -i 's|\.\./nixos/|/arm/nixos/|g'   "$out/arm/extlinux/extlinux.conf"
  sed -i 's|\.\./nixos/|/riscv/nixos/|g' "$out/riscv/extlinux/extlinux.conf"

  cp ${fipArm}   "$out/fip-arm.bin"
  cp ${fipRiscv} "$out/fip-riscv.bin"
  cp "$out/fip-${defaultCore}.bin" "$out/fip.bin"
''
