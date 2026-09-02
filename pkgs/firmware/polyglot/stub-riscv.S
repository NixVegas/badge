/*
 * pkgs/firmware/polyglot/stub-riscv.S -- riscv64 (T-Head C906) relocating stub (#48).
 *
 * Reached by the polyglot entry 0x1400006F (`j 320`) via a jal trampoline.
 * Copies itself to scratch (0x0C00B000, inside the ROM-loaded image -- see the
 * pool comment), jumps there, copies the riscv FSBL body down to BL2_BASE
 * (0x0C000000), enters it. Cache-maintains each copy (dcache.cpa + sync.s +
 * icache.iall + fence.i, T-Head raw encodings).
 */
	.option norvc
	.section .text

	.globl _start
_start:
	lla	s0, _start		/* s0 = runtime &_start */
	lla	t0, pool_scratch
	lw	t1, 0(t0)		/* SCRATCH  */
	lw	t2, 4(t0)		/* BODY_DST */
	lw	t3, 8(t0)		/* BODY_SRC */
	lw	t4, 12(t0)		/* BODY_LEN */
	lla	t5, _end
	sub	t5, t5, s0		/* stub length */

	/* 1. copy this stub [_start.._end) to SCRATCH */
	mv	a0, s0
	mv	a1, t1
	mv	a2, t5
.Lselfcopy:
	lw	a3, 0(a0)
	sw	a3, 0(a1)
	addi	a0, a0, 4
	addi	a1, a1, 4
	addi	a2, a2, -4
	bgtz	a2, .Lselfcopy

	/* flush [SCRATCH, SCRATCH+len): clean D per line + sync + invalidate I */
	mv	a5, t1
	add	a6, t1, t5
	li	a7, -64
	and	a0, a5, a7
.Lflush1:
	.word	0x0295000b		/* dcache.cpa a0 */
	addi	a0, a0, 64
	bltu	a0, a6, .Lflush1
	.word	0x0190000b		/* sync.s */
	.word	0x0100000b		/* icache.iall */
	fence
	fence.i

	/* 2. jump to _stage2 inside the SCRATCH copy */
	lla	a4, _stage2
	sub	a4, a4, s0
	add	a4, a4, t1
	jr	a4

_stage2:
	mv	a0, t3
	mv	a1, t2
	mv	a2, t4
.Lbodycopy:
	lw	a3, 0(a0)
	sw	a3, 0(a1)
	addi	a0, a0, 4
	addi	a1, a1, 4
	addi	a2, a2, -4
	bgtz	a2, .Lbodycopy

	/* flush [BODY_DST, BODY_DST+len) */
	mv	a5, t2
	add	a6, t2, t4
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

	jr	t2

	.align	2
	/*
	 * SCRATCH: where this stub relocates itself before copying the FSBL body
	 * down to BL2_BASE. Parked in the DEAD GAP between where the riscv body
	 * lands (BODY_DST + len) and where it is sourced from (BODY_SRC = the
	 * riscv body's packed offset): that gap is the ARM body's tail, dead on a
	 * riscv boot, and inside the ROM-loaded image -- so provably writable
	 * with no assumptions about SRAM beyond the image. merge_bl2.py asserts
	 * it stays within the gap, so a body-size change fails the build loudly.
	 * (An earlier 'A then E:RESET' here was NOT this address: it was the
	 * unlinked-lla reloc bug -- see merge-bl2.nix's link step. 0x0C030000
	 * was never actually dereferenced.)
	 */
pool_scratch:	.word 0x0C00B000
pool_body_dst:	.word 0x0C000000
pool_body_src:	.word 0x00000000	/* patched */
pool_body_len:	.word 0x00000000	/* patched */
_end:
