/*
 * pkgs/firmware/polyglot/stub-riscv.S -- riscv64 (T-Head C906) relocating stub
 * for the SG2000 polyglot BL2 (#48). Reached by the polyglot entry word
 * 0x1400006F, which on riscv is `j 320`; the merge tool routes offset 320 to
 * this stub (via a 4-byte `jal x0` trampoline at 320 when the stub is larger
 * than the 124-byte gap before the arm stub at 444 -- see merge_bl2.py).
 *
 * The image is loaded by the ROM to BL2_BASE (riscv TPU_SRAM_ORIGIN_BASE
 * 0x0C000000); this stub sits inside the region it must overwrite with the
 * riscv FSBL body, so it copies ITSELF to scratch SRAM (0x0C030000, top 64 KiB
 * of TPU-SRAM, past the image), jumps there, then copies the body down to
 * BL2_BASE and enters it.
 *
 * PIC: `lla` gives the runtime address of local labels; s0 holds the runtime
 * &_start so label offsets are just (lla X) - s0. .option norvc so the
 * C-extension can't shift offsets. The pool's last two words (BODY_SRC,
 * BODY_LEN) are patched by merge_bl2.py.
 */
	.option norvc
	.section .text
	.globl _start
_start:
	lla	s0, _start		/* s0 = runtime &_start (base) */
	lla	t0, pool_scratch	/* t0 = runtime &pool */
	lw	t1, 0(t0)		/* SCRATCH  */
	lw	t2, 4(t0)		/* BODY_DST */
	lw	t3, 8(t0)		/* BODY_SRC */
	lw	t4, 12(t0)		/* BODY_LEN */
	lla	t5, _end
	sub	t5, t5, s0		/* t5 = stub length (_end - _start) */

	/* 1. copy this stub [_start.._end) to SCRATCH */
	mv	a0, s0			/* src */
	mv	a1, t1			/* dst = SCRATCH */
	mv	a2, t5			/* len */
1:	lw	a3, 0(a0)
	sw	a3, 0(a1)
	addi	a0, a0, 4
	addi	a1, a1, 4
	addi	a2, a2, -4
	bgtz	a2, 1b

	/* 2. jump to _stage2 inside the SCRATCH copy */
	lla	a4, _stage2
	sub	a4, a4, s0		/* stage2 offset from _start */
	add	a4, a4, t1		/* SCRATCH + offset */
	jr	a4

_stage2:
	/* now executing from SCRATCH: safe to overwrite [BODY_DST, ...) */
	mv	a0, t3			/* src = BODY_SRC */
	mv	a1, t2			/* dst = BODY_DST */
	mv	a2, t4			/* len = BODY_LEN */
2:	lw	a3, 0(a0)
	sw	a3, 0(a1)
	addi	a0, a0, 4
	addi	a1, a1, 4
	addi	a2, a2, -4
	bgtz	a2, 2b

	/* 3. barrier + enter the relocated FSBL body (its word 0 = `j _real`).
	 * fence drains the body stores; fence.i flushes the I-fetch of the new
	 * code (Zifencei is in the C906 base ISA). If the bench shows a stale
	 * fetch, swap for th.icache.iall. */
	fence
	fence.i
	jr	t2			/* enter FSBL body at BODY_DST */
	.align	2
pool_scratch:	.word 0x0C030000	/* riscv scratch SRAM (origin view) */
pool_body_dst:	.word 0x0C000000	/* riscv BL2_BASE (origin view)     */
pool_body_src:	.word 0x00000000	/* patched: BODY_DST + riscv_body_off */
pool_body_len:	.word 0x00000000	/* patched: riscv FSBL body length    */
_end:
