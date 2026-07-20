# PLACEHOLDER firmware blob. The SG2000 BootROM needs a real fip.bin (vendor
# FSBL + ATF/OpenSBI + U-Boot). Building that is Plan B; until then the SD
# image carries this dummy so the assembler builds and is structurally testable.
# An image built with this placeholder will NOT boot.
{ pkgs }:
pkgs.runCommand "fip-placeholder.bin" { } ''
  printf 'FIP-PLACEHOLDER-NOT-BOOTABLE\n' > "$out"
''
