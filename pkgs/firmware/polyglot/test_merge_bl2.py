#!/usr/bin/env python3
"""Off-hardware layout tests for merge_bl2.py (#48)."""
import struct
import unittest

from merge_bl2 import (
    merge_bl2, encode_jal_x0,
    ENTRY_WORD, ENTRY_OFF, ARM_BASE, RISCV_BASE, ARM_STUB_OFF, RISCV_TRAMP_OFF,
    BODY_PAGE, BL2_SIZE, POOL_TAIL, _align,
)

# opcode 0x6F = JAL
def decode_jal(word):
    assert (word & 0x7F) == 0x6F, f"not a JAL: {word:#010x}"
    rd = (word >> 7) & 0x1F
    imm20    = (word >> 31) & 1
    imm10_1  = (word >> 21) & 0x3FF
    imm11    = (word >> 20) & 1
    imm19_12 = (word >> 12) & 0xFF
    imm = (imm20 << 20) | (imm19_12 << 12) | (imm11 << 11) | (imm10_1 << 1)
    if imm & (1 << 20):
        imm -= (1 << 21)
    return rd, imm


# stubs sized like the real assembled ones; last 16 bytes are the 4-word pool
# [scratch, body_dst, body_src, body_len]. merge_bl2 validates the riscv scratch
# (word 0) and patches (body_src, body_len) -- the trailing POOL_TAIL bytes.
def make_stub(size, marker, scratch=0):
    body = bytes([marker]) * (size - 16)
    return body + struct.pack("<IIII", scratch, 0, 0, 0)


class TestMerge(unittest.TestCase):
    def setUp(self):
        self.arm = b"\xAA" * 0x1234        # arm FSBL body (not page-aligned len)
        self.rv  = b"\xBB" * 0x2010        # riscv FSBL body
        self.arm_stub = make_stub(144, 0x11)
        # riscv SCRATCH must land in the dead gap [RISCV_BASE + align(len(rv),4),
        # RISCV_BASE + riscv_body_off). Here riscv_body_off = 0x1000 +
        # align(0x1234, 0x1000) = 0x3000 and body-dst end = 0x2010, so the gap is
        # [0x0C002010, 0x0C003000); 0x0C002800 sits safely inside it.
        self.rv_scratch = RISCV_BASE + 0x2800
        self.rv_stub  = make_stub(164, 0x22, scratch=self.rv_scratch)
        self.out = merge_bl2(self.arm, self.rv, self.arm_stub, self.rv_stub)

    def test_entry_word(self):
        # The ROM jumps to offset 32 (bl2_entrypoint_real slot), so the entry
        # word lives there -- NOT at offset 0 (proven by C906 JTAG: mepc=0x20).
        self.assertEqual(ENTRY_OFF, 0x20)
        self.assertEqual(struct.unpack_from("<I", self.out, ENTRY_OFF)[0], ENTRY_WORD)

    def test_head_zero(self):
        # the 8-word bl2_head the ROM steps over, up to the entry word
        self.assertEqual(self.out[0:ENTRY_OFF], b"\x00" * ENTRY_OFF)

    def test_riscv_trampoline(self):
        word = struct.unpack_from("<I", self.out, RISCV_TRAMP_OFF)[0]
        rd, imm = decode_jal(word)
        self.assertEqual(rd, 0)                       # jal x0 (no link)
        riscv_reloc_off = _align(ARM_STUB_OFF + len(self.arm_stub), 4)
        self.assertEqual(imm, riscv_reloc_off - RISCV_TRAMP_OFF)

    def test_arm_stub_placed_and_patched(self):
        s = self.out[ARM_STUB_OFF:ARM_STUB_OFF + len(self.arm_stub)]
        self.assertEqual(s[:-16], b"\x11" * (144 - 16))    # body (minus 4-word pool)
        src, ln = struct.unpack("<II", s[-POOL_TAIL:])
        self.assertEqual(src, ARM_BASE + BODY_PAGE)
        self.assertEqual(ln, _align(len(self.arm), 4))

    def test_riscv_reloc_placed_and_patched(self):
        off = _align(ARM_STUB_OFF + len(self.arm_stub), 4)
        s = self.out[off:off + len(self.rv_stub)]
        self.assertEqual(s[:-16], b"\x22" * (164 - 16))    # body (minus 4-word pool)
        scratch = struct.unpack_from("<I", s, len(s) - 16)[0]
        self.assertEqual(scratch, self.rv_scratch)         # scratch (pool word 0) preserved
        src, ln = struct.unpack("<II", s[-POOL_TAIL:])
        riscv_body_off = BODY_PAGE + _align(len(self.arm), BODY_PAGE)
        self.assertEqual(src, RISCV_BASE + riscv_body_off)
        self.assertEqual(ln, _align(len(self.rv), 4))

    def test_bodies_placed(self):
        self.assertEqual(self.out[BODY_PAGE:BODY_PAGE + len(self.arm)], self.arm)
        riscv_body_off = BODY_PAGE + _align(len(self.arm), BODY_PAGE)
        self.assertEqual(self.out[riscv_body_off:riscv_body_off + len(self.rv)], self.rv)

    def test_within_budget(self):
        self.assertLessEqual(len(self.out), BL2_SIZE)

    def test_oversize_rejected(self):
        with self.assertRaises(AssertionError):
            merge_bl2(b"\x00" * 0x30000, b"\x00" * 0x30000, self.arm_stub, self.rv_stub)

    def test_jal_encoding_known(self):
        # jal x0, 272 == 0x1100006F (hand-derived)
        self.assertEqual(encode_jal_x0(272), 0x1100006F)
        for imm in (2, 268, 272, 1024, -1024, (1 << 20) - 2):
            rd, back = decode_jal(encode_jal_x0(imm))
            self.assertEqual((rd, back), (0, imm))


if __name__ == "__main__":
    unittest.main()
