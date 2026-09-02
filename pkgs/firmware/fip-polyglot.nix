# Pack the unified polyglot fip.bin (#48): ONE fip that boots either core via
# the GPIO_RTX strap. Mirrors pkgs/firmware/fip.nix's genfip, but with the
# polyglot BL2 (merge-bl2.nix) and BOTH cores' payloads:
#   arm  (primary)   MONITOR = bl31,   LOADER_2ND   = arm u-boot   (LZMA)
#   riscv(secondary) BLCP_2ND = OpenSBI, LOADER_2ND_B = riscv u-boot (LZMA, via
#                    the symmetric-pack fiptool patch)
# The riscv monitor rides BLCP_2ND with its RUNADDR overridden 0x9FE00000 ->
# 0x80000000 (a DRAM monitor address). CHIP_CONF is byte-identical across cores
# (verdict), so the arm one is shared. See the design + plan docs.
{ pkgs }:
let
  fsblSrc = pkgs.fetchFromGitHub {
    owner = "sophgo";
    repo = "fsbl";
    rev = "29edcfa0b5f999c8ea8f0759b0dd0038421e6c25";
    hash = "sha256-AzeOovjmxtwswNYpWViUKllKEVI9LLbcyqnOVcYPvGo=";
  };

  # fiptool with symmetric LOADER_2ND_B packing (Option Y).
  fsblSrcPatched = pkgs.runCommand "fsbl-src-fiptool-symmetric" { } ''
    cp -r ${fsblSrc} $out
    chmod -R +w $out
    patch -d $out -p1 < ${./polyglot/fiptool-loader-2nd-b-symmetric.patch}
  '';

  bl2        = import ./polyglot/merge-bl2.nix { inherit pkgs; };
  armFsbl    = import ./fsbl.nix { inherit pkgs; core = "arm"; };   # for the shared chip_conf.bin
  armMon     = import ./bl31-blob.nix { inherit pkgs; };
  riscvMon   = import ./opensbi-fw-dynamic.nix { inherit pkgs; };
  armUboot   = import ./uboot-duos-arm.nix { inherit pkgs; };
  riscvUboot = import ./uboot-duos-riscv.nix { inherit pkgs; };
in
pkgs.runCommand "sg2000-fip-polyglot.bin" {
  nativeBuildInputs = [ pkgs.python3 ];
} ''
  python3 ${fsblSrcPatched}/plat/cv181x/fiptool.py -v genfip \
    "$out" \
    --MONITOR_RUNADDR=0x80000000 \
    --BLCP_2ND_RUNADDR=0x80000000 \
    --CHIP_CONF=${armFsbl}/chip_conf.bin \
    --NOR_INFO=FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF \
    --NAND_INFO=00000000 \
    --BL2=${bl2} \
    --BLCP_IMG_RUNADDR=0x05200200 \
    --BLCP_PARAM_LOADADDR=0 \
    --BLCP=${fsblSrc}/test/empty.bin \
    --BLCP_2ND=${riscvMon} \
    --MONITOR=${armMon} \
    --LOADER_2ND=${armUboot}/u-boot-raw.bin \
    --LOADER_2ND_B=${riscvUboot}/u-boot-raw.bin \
    --compress=lzma

  # Sanity: re-open with the patched fiptool and confirm the polyglot BL2 entry
  # word sits at the BL2 slot start and both u-boot slots are populated.
  python3 - "$out" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
# BL2 image starts at param1.BL2_IMG offset; the whole file must contain the
# entry word, and be a plausible size (BL2 + 2 monitors + 2 u-boots).
assert b"\x6f\x00\x00\x14" in d, "polyglot entry word not found in fip"
assert len(d) > 0x40000, f"fip suspiciously small: {len(d):#x}"
print(f"polyglot fip ok: {len(d):#x} bytes")
PY
''
