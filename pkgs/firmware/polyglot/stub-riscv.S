/*
 * pkgs/firmware/polyglot/stub-riscv.S -- riscv64 (T-Head C906) relocating stub
 * for the SG2000 polyglot BL2 (#48). Reached by the polyglot entry word
 * 0x1400006F, which on riscv is `j 320`; the merge tool routes offset 320 to
 * this stub via a 4-byte `jal x0` trampoline (the stub is > the 124-byte gap
 * before the arm stub at 444).
 *
 * The image is loaded by the ROM to BL2_BASE (riscv TPU_SRAM_ORIGIN_BASE
 * 0x0C000000); this stub sits inside the region it must overwrite with the
 * riscv FSBL body, so it copies ITSELF to scratch SRAM (0x0C030000, top 64 KiB
 * of TPU-SRAM, past the image), jumps there, then copies the body down to
 * BL2_BASE and enters it.
 *
 * CACHE COHERENCY: both copies write code with plain stores, then JUMP to fetch
 * it. On the C906 fence.i invalidates the I-cache but does NOT clean the
 * write-back D-cache, so the copied code would sit in the D-cache while the
 * I-fetch reads stale memory -> garbage -> hang (the arm-side bug). After EACH
 * copy we clean the copied range D->memory with dcache.cpa (T-Head clean-by-PA,
 * L1 line = 64 B) + sync.s, then icache.iall + fence.i. T-Head ops are emitted
 * as raw words (the stub builds -march=rv64imac_zifencei, no xthead), matching
 * the FSBL's lib/cpu/riscv/cache.c encodings.
 *
 * PIC via `lla`; s0 = runtime &_start. .option norvc. Pool's last two words
 * (BODY_SRC, BODY_LEN) are patched by merge_bl2.py.
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
.Lselfcopy:
	lw	a3, 0(a0)
	sw	a3, 0(a1)
	addi	a0, a0, 4
	addi	a1, a1, 4
	addi	a2, a2, -4
	bgtz	a2, .Lselfcopy

	/* flush the SCRATCH copy [SCRATCH, SCRATCH+len): clean D per 64 B line
	 * + sync, invalidate I, so the jump below fetches the real copied code. */
	mv	a5, t1			/* start = SCRATCH */
	add	a6, t1, t5		/* end   = SCRATCH + stub length */
	li	a7, -64
	and	a0, a5, a7		/* a0 = start & ~63 (dcache.cpa uses a0=rs1) */
.Lflush1:
	.word	0x0295000b		/* dcache.cpa a0  (clean D line by PA) */
	addi	a0, a0, 64
	bltu	a0, a6, .Lflush1
	.word	0x0190000b		/* sync.s */
	.word	0x0100000b		/* icache.iall */
	fence
	fence.i

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
.Lbodycopy:
	lw	a3, 0(a0)
	sw	a3, 0(a1)
	addi	a0, a0, 4
	addi	a1, a1, 4
	addi	a2, a2, -4
	bgtz	a2, .Lbodycopy

	/* flush the relocated body [BODY_DST, BODY_DST+len): clean D + sync,
	 * invalidate I, so entering it fetches the real FSBL code. */
	mv	a5, t2			/* start = BODY_DST */
	add	a6, t2, t4		/* end   = BODY_DST + BODY_LEN */
	li	a7, -64
	and	a0, a5, a7
.Lflush2:
	.word	0x0295000b		/* dcache.cpa a0 */
	addi	a0, a0, 64
	bltu	a0, a6, .Lflush2
	.word	0x0190000b		/* sync.s */
	.word	0x0100000b		/* icache.iall */
	fence
	fence.i

	/* 3. enter the relocated FSBL body (its word 0 = `j bl2_entrypoint_real`) */
	jr	t2

	.align	2
pool_scratch:	.word 0x0C030000	/* riscv scratch SRAM (origin view) */
pool_body_dst:	.word 0x0C000000	/* riscv BL2_BASE (origin view)     */
pool_body_src:	.word 0x00000000	/* patched: BODY_DST + riscv_body_off */
pool_body_len:	.word 0x00000000	/* patched: riscv FSBL body length    */
_end:
