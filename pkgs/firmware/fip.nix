# fip.bin packer for Sophgo SG2000 / Milk-V Duo S.
#
# Supports both boot cores via the `core` parameter:
#   core = "arm"   (DEFAULT): ARM fip.bin - MONITOR=bl31.bin, fsbl/uboot for aarch64.
#   core = "riscv":           RISC-V fip.bin - MONITOR=fw_dynamic.bin, fsbl/uboot for riscv64.
#
# The fiptool.py genfip command, run addresses, and all other args are
# identical for both cores. Only three inputs differ by core:
#   MONITOR:    arm  = bl31-blob.nix (bl31.bin prebuilt blob)
#               riscv = opensbi-fw-dynamic.nix (fw_dynamic.bin built from source)
#   BL2 + CHIP_CONF: fsbl.nix with matching core=
#   LOADER_2ND: arm  = uboot-duos-arm.nix (u-boot-raw.bin, aarch64 S-mode)
#               riscv = uboot-duos-riscv.nix (u-boot-raw.bin, riscv64 S-mode)
#
# The TOC magic (0xAA640001 arm vs 0xC906B001 riscv) flips automatically
# with the riscv BL2 from fsbl.nix.
#
# Constant values from fip.mk:
#   BLCP_IMG_RUNADDR=0x05200200  BLCP_PARAM_LOADADDR=0  NAND_INFO=00000000
#   NOR_INFO=FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
#     (72 hex chars = 36 bytes 0xFF, the non-fastboot default)
#   FIP_COMPRESS=lzma
#
# Run addresses from fsbl/plat/cv181x/include/mmap.h:
#   MONITOR_RUNADDR  = CVIMMAP_MONITOR_ADDR           = 0x80000000
#   BLCP_2ND_RUNADDR = CVIMMAP_FSBL_C906L_START_ADDR  = 0x9FE00000
#
# BLCP and BLCP_2ND use test/empty.bin from the fsbl source (no BLCP/RTOS).
#
# Output: $out is fip.bin directly.
#
# Backward-compatible: import ./fip.nix { inherit pkgs; } gives the ARM fip unchanged.
# dumpRom = true builds a one-shot debug fip whose BL2 prints the mask ROM over
# UART (see fsbl.nix). Off by default, so normal fips are unaffected.
{ pkgs, core ? "arm", dumpRom ? false }:
let
  fsblSrc = pkgs.fetchFromGitHub {
    owner = "sophgo";
    repo = "fsbl";
    rev = "29edcfa0b5f999c8ea8f0759b0dd0038421e6c25";
    hash = "sha256-AzeOovjmxtwswNYpWViUKllKEVI9LLbcyqnOVcYPvGo=";
  };

  # Per-core input selection. Only these three swap; everything else is shared.
  coreInputs =
    if core == "arm" then {
      fsbl    = import ./fsbl.nix { inherit pkgs dumpRom; };
      monitor = import ./bl31-blob.nix { inherit pkgs; };
      uboot   = import ./uboot-duos-arm.nix { inherit pkgs; };
    } else if core == "riscv" then {
      fsbl    = import ./fsbl.nix { inherit pkgs dumpRom; core = "riscv"; };
      monitor = import ./opensbi-fw-dynamic.nix { inherit pkgs; };
      uboot   = import ./uboot-duos-riscv.nix { inherit pkgs; };
    } else
      throw "fip.nix: unknown core=${core}, expected arm or riscv";

  fsbl    = coreInputs.fsbl;
  monitor = coreInputs.monitor;
  uboot   = coreInputs.uboot;
in
pkgs.runCommand "sg2000-fip-${core}.bin" {
  nativeBuildInputs = [ pkgs.python3 ];
} ''
  # fip-all recipe from fsbl/make_helpers/fip.mk (BOOT_CPU=aarch64 / riscv path):
  #   fiptool.py -v genfip <output>
  #     --MONITOR_RUNADDR=$MONITOR_RUNADDR     (0x80000000, core-agnostic)
  #     --BLCP_2ND_RUNADDR=$BLCP_2ND_RUNADDR  (0x9FE00000, core-agnostic)
  #     --CHIP_CONF=chip_conf.bin
  #     --NOR_INFO=<NOR_INFO>
  #     --NAND_INFO=<NAND_INFO>
  #     --BL2=bl2.bin
  #     --BLCP_IMG_RUNADDR=0x05200200
  #     --BLCP_PARAM_LOADADDR=0
  #     --BLCP=test/empty.bin
  #     --BLCP_2ND=test/empty.bin
  #     --MONITOR=<per-core monitor binary>
  #     --LOADER_2ND=u-boot-raw.bin
  #     --compress=lzma

  python3 ${fsblSrc}/plat/cv181x/fiptool.py -v genfip \
    "$out" \
    --MONITOR_RUNADDR=0x80000000 \
    --BLCP_2ND_RUNADDR=0x9FE00000 \
    --CHIP_CONF=${fsbl}/chip_conf.bin \
    --NOR_INFO=FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF \
    --NAND_INFO=00000000 \
    --BL2=${fsbl}/bl2.bin \
    --BLCP_IMG_RUNADDR=0x05200200 \
    --BLCP_PARAM_LOADADDR=0 \
    --BLCP=${fsblSrc}/test/empty.bin \
    --BLCP_2ND=${fsblSrc}/test/empty.bin \
    --MONITOR=${monitor} \
    --LOADER_2ND=${uboot}/u-boot-raw.bin \
    --compress=lzma
''
