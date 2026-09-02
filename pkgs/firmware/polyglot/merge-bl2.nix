# Build the polyglot BL2 (#48): assemble both per-ISA relocating stubs, then
# merge them with the two FSBL bodies into one image whose first word is the
# dual-ISA entry 0x1400006F. See merge_bl2.py for the layout and
# docs/superpowers/plans/2026-09-01-sg2000-polyglot-fip.md for the design.
#
# arm  = primary   FSBL (reads MONITOR / LOADER_2ND slots, unpatched)
# riscv = secondary FSBL (reads BLCP_2ND / LOADER_2ND_B; slot="secondary")
{ pkgs }:
let
  armFsbl   = import ../fsbl.nix { inherit pkgs; core = "arm"; };
  riscvFsbl = import ../fsbl.nix { inherit pkgs; core = "riscv"; slot = "secondary"; };
  armCC     = pkgs.pkgsCross.aarch64-embedded.stdenv.cc;
  riscvCC   = pkgs.pkgsCross.riscv64-embedded.stdenv.cc;
  armPfx    = armCC.targetPrefix;    # aarch64-none-elf-
  riscvPfx  = riscvCC.targetPrefix;  # riscv64-none-elf-
in
pkgs.runCommand "polyglot-bl2.bin" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  # aarch64 stub: default march/abi are fine (integer asm, no float).
  ${armCC}/bin/${armPfx}gcc -c -o arm.o ${./stub-arm.S}
  ${armCC}/bin/${armPfx}objcopy -O binary arm.o arm-stub.bin

  # riscv stub: -mabi=lp64 avoids the toolchain's default D requirement; the
  # stub is .option norvc, and fence.i needs zifencei.
  ${riscvCC}/bin/${riscvPfx}gcc -march=rv64imac_zifencei -mabi=lp64 -c -o rv.o ${./stub-riscv.S}
  ${riscvCC}/bin/${riscvPfx}objcopy -O binary rv.o rv-stub.bin

  python3 ${./merge_bl2.py} \
    ${armFsbl}/bl2.bin ${riscvFsbl}/bl2.bin arm-stub.bin rv-stub.bin "$out"

  # Sanity: entry word at byte 0, within the BL2 slot budget.
  python3 - "$out" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
assert struct.unpack_from("<I", d, 0)[0] == 0x1400006F, "entry word missing"
assert len(d) <= 0x37000, f"polyglot BL2 {len(d):#x} exceeds BL2_SIZE"
print(f"polyglot BL2 ok: {len(d):#x} bytes, entry 0x1400006F")
PY
''
