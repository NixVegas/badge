#!/usr/bin/env python3
"""Merge two per-ISA FSBL bodies + their relocating stubs into ONE polyglot BL2
for the SG2000 unified fip (#48).

Layout of the produced image (offsets from byte 0, where the ROM jumps):

    0x000  entry word 0x1400006F   aarch64 `b #444` / riscv `j 320`
    0x004  7 words 0x00000000      head (ROM does not read these)
    0x140  (320) riscv trampoline  `jal x0, (riscv_reloc_off - 320)` (4 bytes)
    0x1BC  (444) arm stub          relocates arm body -> BL2_BASE, enters it
    <a4>   riscv relocator         placed right after the arm stub (4-aligned)
    0x1000 arm FSBL body           (arm stub copies it down to 0x40100000)
    <pg>   riscv FSBL body         (riscv relocator copies it to 0x0C000000)

The arm entry `b #444` lands directly on the arm stub. The riscv entry `j 320`
lands on a 4-byte `jal x0` that jumps to the riscv relocator (the riscv stub is
164 B > the 124 B gap between 320 and 444, so it cannot sit inline at 320).

Each stub is position-independent; its trailing pool's last two words
(BODY_SRC, BODY_LEN) are patched here (POOL_TAIL bytes). BL2_BASE / SCRATCH are
fixed inside the .S files (per-core address views).
"""
import struct

ENTRY_WORD      = 0x1400006F
ARM_BASE        = 0x40100000   # arm BL2_BASE (mirror view) -- must match stub-arm.S
RISCV_BASE      = 0x0C000000   # riscv BL2_BASE (origin view) -- must match stub-riscv.S
RISCV_TRAMP_OFF = 320          # riscv `j` landing (from the entry word)
ARM_STUB_OFF    = 444          # arm `b` landing (from the entry word)
BODY_PAGE       = 0x1000       # first FSBL body starts here (page-aligned)
BL2_SIZE        = 0x37000      # ROM BL2 slot budget
POOL_TAIL       = 8            # bytes of (SRC, LEN) at the end of each stub


def _align(x, a):
    return (x + a - 1) & ~(a - 1)


def encode_jal_x0(imm):
    """Encode `jal x0, imm` (an unconditional jump, no link). imm is a byte
    offset from the jal instruction, even, in [-2^20, 2^20)."""
    assert imm % 2 == 0, f"jal imm {imm} not even"
    assert -(1 << 20) <= imm < (1 << 20), f"jal imm {imm} out of range"
    u = imm & 0x1FFFFF
    imm20   = (u >> 20) & 1
    imm10_1 = (u >> 1) & 0x3FF
    imm11   = (u >> 11) & 1
    imm19_12= (u >> 12) & 0xFF
    return (imm20 << 31) | (imm10_1 << 21) | (imm11 << 20) | (imm19_12 << 12) | (0 << 7) | 0x6F


def _patch_stub(stub, base, body_off, body_len):
    """Replace the stub's trailing (SRC, LEN) pool words. SRC = the runtime
    address of the body (base + its offset in the loaded image); LEN rounded up
    to a whole word so the stub's word-copy is exact."""
    assert len(stub) >= POOL_TAIL
    src = base + body_off
    ln  = _align(body_len, 4)
    return stub[:-POOL_TAIL] + struct.pack("<II", src, ln)


def merge_bl2(arm_bl2, riscv_bl2, arm_stub, riscv_stub):
    arm_off        = BODY_PAGE
    riscv_body_off = arm_off + _align(len(arm_bl2), BODY_PAGE)
    total          = riscv_body_off + len(riscv_bl2)

    riscv_reloc_off = _align(ARM_STUB_OFF + len(arm_stub), 4)

    # sanity: nothing in the first page overlaps
    assert ARM_STUB_OFF + len(arm_stub) <= riscv_reloc_off, "arm stub / riscv reloc overlap"
    assert riscv_reloc_off + len(riscv_stub) <= BODY_PAGE, "stubs overrun the body page"
    assert RISCV_TRAMP_OFF + 4 <= ARM_STUB_OFF, "riscv trampoline overruns the arm stub"
    assert total <= BL2_SIZE, f"polyglot BL2 {total:#x} exceeds BL2_SIZE {BL2_SIZE:#x}"

    buf = bytearray(total)
    struct.pack_into("<I", buf, 0, ENTRY_WORD)                       # entry word
    # words 1..7 stay zero (head)
    jal = encode_jal_x0(riscv_reloc_off - RISCV_TRAMP_OFF)           # riscv trampoline
    struct.pack_into("<I", buf, RISCV_TRAMP_OFF, jal)

    arm_s = _patch_stub(arm_stub,   ARM_BASE,   arm_off,        len(arm_bl2))
    rv_s  = _patch_stub(riscv_stub, RISCV_BASE, riscv_body_off, len(riscv_bl2))
    buf[ARM_STUB_OFF:ARM_STUB_OFF + len(arm_s)]        = arm_s
    buf[riscv_reloc_off:riscv_reloc_off + len(rv_s)]   = rv_s
    buf[arm_off:arm_off + len(arm_bl2)]                = arm_bl2
    buf[riscv_body_off:riscv_body_off + len(riscv_bl2)] = riscv_bl2
    return bytes(buf)


if __name__ == "__main__":
    import sys
    arm, rv, arm_stub, rv_stub, out = sys.argv[1:6]
    data = merge_bl2(open(arm, "rb").read(), open(rv, "rb").read(),
                     open(arm_stub, "rb").read(), open(rv_stub, "rb").read())
    with open(out, "wb") as f:
        f.write(data)
