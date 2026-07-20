# Build the FAT boot-partition tree for the dual-core Duo S card: per-core
# kernel/initrd/dtb + extlinux (paths rewritten absolute so the active copy
# works from the FAT root), both fips, and the default core marked active.
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

  mkdir -p "$out/extlinux"
  cp "$out/${defaultCore}/extlinux/extlinux.conf" "$out/extlinux/extlinux.conf"
''
