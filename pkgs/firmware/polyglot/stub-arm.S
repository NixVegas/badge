/*
 * pkgs/firmware/polyglot/stub-arm.S -- aarch64 relocating stub for the SG2000
 * polyglot BL2 (#48). Reached by the polyglot entry word 0x1400006F, which on
 * aarch64 is `b #444`; the merge tool places this stub's first byte at offset
 * 444 of the polyglot image.
 *
 * The image is loaded by the ROM to BL2_BASE (arm mirror 0x40100000) and this
 * stub sits at BL2_BASE+444 -- INSIDE the region [BL2_BASE, BL2_BASE+BODY_LEN)
 * that it must overwrite with the arm FSBL body. So it first copies ITSELF to
 * the free scratch SRAM (0x40130000, top 64 KiB of TPU-SRAM, past the image),
 * jumps there, and only then copies the body down to BL2_BASE and enters it.
 *
 * Fully position-independent: every reference is PC-relative or via the pool,
 * so the merge tool can drop the raw bytes at any offset. The pool's last two
 * words (BODY_SRC, BODY_LEN) are patched by merge_bl2.py; SCRATCH and BODY_DST
 * are fixed here. The arm/riscv FSBL entrypoints consume no incoming registers
 * (arm sets its own state, riscv zeroes x1-x31), so clobbering regs is safe.
 */
	.arch armv8-a
	.section .text
	.globl _start
_start:
	adr	x9, _start		/* x9 = &_start (this stub's load address) */
	ldr	w10, pool_scratch	/* SCRATCH  */
	ldr	w11, pool_body_dst	/* BODY_DST */
	ldr	w12, pool_body_src	/* BODY_SRC */
	ldr	w13, pool_body_len	/* BODY_LEN */
	adr	x14, _end
	sub	x14, x14, x9		/* x14 = stub length */

	/* 1. copy this stub [_start.._end) to SCRATCH */
	mov	x15, x9			/* src */
	mov	x16, x10		/* dst = SCRATCH */
	mov	x17, x14		/* len */
1:	ldr	w0, [x15], #4
	str	w0, [x16], #4
	subs	x17, x17, #4
	b.gt	1b

	/* 2. jump to _stage2 inside the SCRATCH copy */
	adr	x0, _stage2
	sub	x0, x0, x9		/* stage2 offset from _start */
	add	x0, x0, x10		/* SCRATCH + offset */
	br	x0

_stage2:
	/* now executing from SCRATCH: safe to overwrite [BODY_DST, ...) */
	mov	x15, x12		/* src = BODY_SRC */
	mov	x16, x11		/* dst = BODY_DST */
	mov	x17, x13		/* len = BODY_LEN */
2:	ldr	w0, [x15], #4
	str	w0, [x16], #4
	subs	x17, x17, #4
	b.gt	2b

	/* 3. barrier + enter the relocated FSBL body (its word 0 = `b _real`) */
	dsb	sy
	ic	iallu
	isb
	br	x11

	.align	4
pool_scratch:	.word 0x40130000	/* arm scratch SRAM (mirror view)  */
pool_body_dst:	.word 0x40100000	/* arm BL2_BASE (mirror view)      */
pool_body_src:	.word 0x00000000	/* patched: BODY_DST + arm_body_off */
pool_body_len:	.word 0x00000000	/* patched: arm FSBL body length    */
_end:
