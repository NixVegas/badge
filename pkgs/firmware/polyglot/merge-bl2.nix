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
  # aarch64 stub: default march/abi are fine (integer asm, no float). The link
  # step matters here too: aarch64 GAS resolves adr/ldr-literal to LOCAL labels
  # at assembly time, but `_start` is .globl, so its `adr x9, _start` carried a
  # relocation and objcopy of the bare .o left it as `adr x9, #0` (= address of
  # the adr itself, +0x14 off). The unlinked stub still booted by accidental
  # cancellation -- the wrong x9 was both the copy-source base and the
  # jump-delta base, so the shifted scratch copy matched the shifted jump --
  # but the linked version is actually correct, not luckily correct.
  ${armCC}/bin/${armPfx}gcc -c -o arm.o ${./stub-arm.S}
  ${armCC}/bin/${armPfx}ld -Ttext=0 -e _start -o arm.elf arm.o
  ${armCC}/bin/${armPfx}objcopy -O binary arm.elf arm-stub.bin

  # riscv stub: -mabi=lp64 avoids the toolchain's default D requirement; the
  # stub is .option norvc, and fence.i needs zifencei.
  #
  # The LINK step is LOAD-BEARING: riscv GAS always emits R_RISCV_PCREL_HI20/
  # LO12 relocations for `lla` -- even to local labels (linker-relaxation
  # design) -- so objcopy of the UNLINKED .o leaves every lla as
  # `auipc rd,0; addi rd,rd,0` = "address of myself". On the bench that read
  # instruction words as the pool: mepc=stub+0x54 (first sw of the self-copy),
  # mcause=6 (misaligned store), mtval=0x297 = the `auipc t0,0` ENCODING used
  # as a store address. ld resolves the pcrel pairs; --no-relax keeps every
  # instruction 4 bytes so the pool stays at the stub's tail. lla is
  # auipc-relative, so the linked blob stays position-independent (-Ttext=0 is
  # arbitrary).
  ${riscvCC}/bin/${riscvPfx}gcc -march=rv64imac_zifencei -mabi=lp64 -c -o rv.o ${./stub-riscv.S}
  ${riscvCC}/bin/${riscvPfx}ld --no-relax -Ttext=0 -e _start -o rv.elf rv.o
  ${riscvCC}/bin/${riscvPfx}objcopy -O binary rv.elf rv-stub.bin

  python3 ${./merge_bl2.py} \
    ${armFsbl}/bl2.bin ${riscvFsbl}/bl2.bin arm-stub.bin rv-stub.bin "$out"

  # Sanity: entry word at OFFSET 0x20 (the ROM's BL2 jump target, past the
  # 8-word bl2_head), head zero, within the BL2 slot budget. (The ROM jumps to
  # bl2_entrypoint_real @ 0x20, not byte 0 -- proven by C906 JTAG: mepc=0x20.)
  python3 - "$out" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
assert d[0:0x20] == b"\x00" * 0x20, "bl2_head (0..0x20) not zero"
assert struct.unpack_from("<I", d, 0x20)[0] == 0x1400006F, "entry word missing at 0x20"
assert len(d) <= 0x37000, f"polyglot BL2 {len(d):#x} exceeds BL2_SIZE"
print(f"polyglot BL2 ok: {len(d):#x} bytes, entry 0x1400006F @ 0x20")
PY
''
