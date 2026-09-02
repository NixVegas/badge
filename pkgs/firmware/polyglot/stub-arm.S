/*
 * pkgs/firmware/polyglot/stub-arm.S -- aarch64 relocating stub (#48).
 *
 * Reached by the polyglot entry 0x1400006F (`b #444`). Copies itself to scratch
 * SRAM (0x40130000), jumps there, copies the arm FSBL body down to BL2_BASE
 * (0x40100000), enters it. Cache-maintains each copy (dc cvau + ic iallu).
 */
	.arch armv8-a
	.section .text

	.globl _start
_start:
	adr	x9, _start
	ldr	w10, pool_scratch	/* SCRATCH  */
	ldr	w11, pool_body_dst	/* BODY_DST */
	ldr	w12, pool_body_src	/* BODY_SRC */
	ldr	w13, pool_body_len	/* BODY_LEN */
	adr	x14, _end
	sub	x14, x14, x9		/* stub length */

	/* 1. copy this stub [_start.._end) to SCRATCH */
	mov	x15, x9
	mov	x16, x10
	mov	x17, x14
.Lselfcopy:
	ldr	w0, [x15], #4
	str	w0, [x16], #4
	subs	x17, x17, #4
	b.gt	.Lselfcopy

	/* flush [SCRATCH, SCRATCH+len): clean D->PoU + invalidate I */
	mov	x0, x10
	add	x1, x10, x14
	mrs	x2, ctr_el0
	ubfx	x2, x2, #16, #4
	mov	x3, #4
	lsl	x2, x3, x2
	sub	x3, x2, #1
	bic	x4, x0, x3
.Lflush1:
	dc	cvau, x4
	add	x4, x4, x2
	cmp	x4, x1
	b.lo	.Lflush1
	dsb	ish
	ic	iallu
	dsb	ish
	isb

	/* 2. jump to _stage2 inside the SCRATCH copy */
	adr	x0, _stage2
	sub	x0, x0, x9
	add	x0, x0, x10
	br	x0

_stage2:
	mov	x15, x12
	mov	x16, x11
	mov	x17, x13
.Lbodycopy:
	ldr	w0, [x15], #4
	str	w0, [x16], #4
	subs	x17, x17, #4
	b.gt	.Lbodycopy

	/* flush [BODY_DST, BODY_DST+len) */
	mov	x0, x11
	add	x1, x11, x13
	mrs	x2, ctr_el0
	ubfx	x2, x2, #16, #4
	mov	x3, #4
	lsl	x2, x3, x2
	sub	x3, x2, #1
	bic	x4, x0, x3
.Lflush2:
	dc	cvau, x4
	add	x4, x4, x2
	cmp	x4, x1
	b.lo	.Lflush2
	dsb	ish
	ic	iallu
	dsb	ish
	isb

	br	x11

	.align	4
pool_scratch:	.word 0x40130000
pool_body_dst:	.word 0x40100000
pool_body_src:	.word 0x00000000	/* patched */
pool_body_len:	.word 0x00000000	/* patched */
_end:
