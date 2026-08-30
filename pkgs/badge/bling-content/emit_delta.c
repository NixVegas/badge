// emit_delta.c -- turn a badge "BADA" 1-bit frame blob into a pure-Nix Bad Apple
// DELTA PATTERN FILE the embedded fix evaluator applies per frame (see
// pkgs/badge/bling-content/badapple-delta.md -- the byte/int contract, and
// pkgs/badge/nix-badge/fixeval.zig decodeOled for the runtime decode side).
//
// Input  (stdin):  the "BADA" blob (pkgs/badge/badapple: 16-byte header + N
//                  frames of WIDTH*HEIGHT/8 page-major GDDRAM bytes). Header:
//                  "BADA" magic, u16 width@4, u16 height@6, u16 fps@8,
//                  u32 frame_count@12, all little-endian.
// Output (stdout): a Nix function whose `frames` list mixes KEYFRAMES and DELTAS
//                  (per badapple-delta.md "Nix output shape"):
//
//     scope:
//     let
//       frames = [
//         { k = true;  b = [ <fbLen/4 ints> ]; }                 # keyframe
//         { k = false; n = <count>; b = [ <ceil(count/2) ints> ]; }  # delta
//         ...
//       ];
//       nframes = N;
//       mod = a: b: a - (a / b) * b;
//     in
//     let fr = builtins.elemAt frames (mod scope.frameIndex nframes);
//     in {
//       bitmap = fr.b;
//       delta  = !fr.k;
//       n      = fr.n or 0;
//       nextMs = <1000/fps, min 1>;
//     }
//
// KEYFRAME packing (identical to emit_nix.c): the full frame, fbLen/4 ints, each
// 4 consecutive page-major GDDRAM bytes LITTLE-ENDIAN:
//     int = b0 | b1<<8 | b2<<16 | b3<<24    (b0 = page-byte[i*4]).
//
// DELTA packing: the change entries (bytes where this frame differs from the
// exactly-reconstructed previous frame), ascending offset. Each change is
//     E = offset * 256 + byte           (offset <= fbLen-1, byte 0..255)
// and TWO entries pack into one int, the earlier change in the HIGH bits:
//     int = E0 * 262144 + E1            (262144 == 2^18)
// An odd count leaves the final int's low 18 bits (E1) zero; the decoder bounds
// by `n`, so the padding is ignored. Max packed value is (2^18-1)*2^18+(2^18-1)
// == 2^36-1, which OVERFLOWS uint32_t -- the packed value is carried in uint64_t.
//
// A frame f is a KEYFRAME iff (f % K == 0), K = keyframe interval from argv[1]
// (default 60). So frame 0 is always a keyframe. Because the diff is lossless,
// `prev` is exactly the previous frame's raw bytes.
//
// Args: emit_delta [K]      (geometry + fps are read from the blob header)
//
// Assisted-by: Claude Opus 4.8 <noreply@anthropic.com>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <inttypes.h>

static unsigned rd_u16(const unsigned char *p)
{
	return (unsigned)p[0] | ((unsigned)p[1] << 8);
}

static unsigned long rd_u32(const unsigned char *p)
{
	return (unsigned long)p[0] | ((unsigned long)p[1] << 8) |
	       ((unsigned long)p[2] << 16) | ((unsigned long)p[3] << 24);
}

int main(int argc, char **argv)
{
	// Keyframe interval K: argv[1], default 60. K must be >= 1 (K=1 => every
	// frame a keyframe, i.e. the old full-frame stream).
	unsigned long keyint = 60;
	if (argc > 1) {
		char *end = NULL;
		unsigned long v = strtoul(argv[1], &end, 10);
		if (end == argv[1] || *end != '\0' || v == 0) {
			fprintf(stderr, "emit_delta: bad keyframe interval '%s'\n",
				argv[1]);
			return 1;
		}
		keyint = v;
	}

	unsigned char header[16];
	if (fread(header, 1, sizeof(header), stdin) != sizeof(header)) {
		fprintf(stderr, "emit_delta: short header\n");
		return 1;
	}
	if (memcmp(header, "BADA", 4) != 0) {
		fprintf(stderr, "emit_delta: not a BADA blob\n");
		return 1;
	}

	unsigned width = rd_u16(header + 4);
	unsigned height = rd_u16(header + 6);
	unsigned fps = rd_u16(header + 8);
	unsigned long frames = rd_u32(header + 12);

	if (width == 0 || height == 0 || (height % 8) != 0 || fps == 0 ||
	    frames == 0) {
		fprintf(stderr, "emit_delta: bad header (w=%u h=%u fps=%u frames=%lu)\n",
			width, height, fps, frames);
		return 1;
	}

	size_t fb_len = (size_t)width * (height / 8); // page-major bytes/frame
	if ((fb_len % 4) != 0) {
		// Keyframes pack 4 page-bytes per int; a non-multiple-of-4 frame
		// would drop the tail. 128x64 is 1024, a clean multiple.
		fprintf(stderr, "emit_delta: fbLen %zu not a multiple of 4\n", fb_len);
		return 1;
	}
	// Delta offset must fit E = offset*256+byte in 18 bits, i.e. offset <= 1023
	// (fbLen <= 1024). 128x64 = 1024 is the intended panel and the exact ceiling.
	if (fb_len > 1024) {
		fprintf(stderr, "emit_delta: fbLen %zu > 1024; delta offset would "
			"overflow the 18-bit entry (offset must be <= 1023)\n", fb_len);
		return 1;
	}
	size_t words = fb_len / 4; // ints per KEYFRAME

	unsigned char *fb = malloc(fb_len);   // this frame's raw page-bytes
	unsigned char *prev = malloc(fb_len); // the exact previous frame
	if (!fb || !prev) {
		fprintf(stderr, "emit_delta: out of memory\n");
		free(fb);
		free(prev);
		return 1;
	}

	// The pattern header: a self-contained `scope -> { bitmap; delta; n; nextMs }`.
	unsigned next_ms = 1000u / fps;
	if (next_ms == 0)
		next_ms = 1;
	printf("# Pure-Nix Bad Apple DELTA pattern, applied per frame by the badge's\n");
	printf("# embedded fix evaluator (pkgs/badge/nix-badge/fixeval.zig decodeOled).\n");
	printf("# Byte/int contract: pkgs/badge/bling-content/badapple-delta.md.\n");
	printf("# GENERATED -- do not edit; regenerate via badapple-live.nix.\n");
	printf("# %ux%u, %u fps, %lu frames; keyframe interval K = %lu.\n",
		width, height, fps, frames, keyint);
	printf("# Keyframe: full frame, %zu ints (4 page-bytes/int LE). Delta: n change\n",
		words);
	printf("# entries, 2/int, E = offset*256+byte, int = E0*262144 + E1.\n");
	printf("scope:\n");
	printf("let\n");
	printf("  frames = [\n");

	// Running stats for the stderr summary.
	unsigned long total_keyframes = 0;
	unsigned long total_delta_frames = 0;
	unsigned long long total_delta_entries = 0;

	for (unsigned long f = 0; f < frames; f++) {
		size_t got = fread(fb, 1, fb_len, stdin);
		if (got != fb_len) {
			fprintf(stderr, "emit_delta: short frame %lu (%zu of %zu bytes)\n",
				f, got, fb_len);
			free(fb);
			free(prev);
			return 1;
		}

		int is_keyframe = (f % keyint) == 0; // frame 0 always a keyframe

		if (is_keyframe) {
			// Full frame: fbLen/4 ints, 4 page-bytes/int LE (== emit_nix.c).
			total_keyframes++;
			fputs("    { k = true; b = [", stdout);
			for (size_t i = 0; i < words; i++) {
				uint32_t v = (uint32_t)fb[i * 4 + 0] |
					     ((uint32_t)fb[i * 4 + 1] << 8) |
					     ((uint32_t)fb[i * 4 + 2] << 16) |
					     ((uint32_t)fb[i * 4 + 3] << 24);
				printf(" %lu", (unsigned long)v);
			}
			fputs(" ]; }\n", stdout);
		} else {
			// Delta: emit each byte index i where fb[i] != prev[i], ascending,
			// as E = i*256 + fb[i]; pack two per int, E0 in the high 18 bits.
			total_delta_frames++;

			// First pass: count the changes so we can emit `n` before `b`.
			size_t count = 0;
			for (size_t i = 0; i < fb_len; i++)
				if (fb[i] != prev[i])
					count++;
			total_delta_entries += (unsigned long long)count;

			printf("    { k = false; n = %zu; b = [", count);

			// Second pass: pack. Hold a pending high entry E0; when its low
			// partner E1 arrives, flush `E0*262144 + E1`. A trailing odd E0
			// flushes as `E0*262144` (E1 = 0).
			int have_hi = 0;
			uint64_t hi = 0; // pending E0
			for (size_t i = 0; i < fb_len; i++) {
				if (fb[i] == prev[i])
					continue;
				uint64_t e = (uint64_t)i * 256u + (uint64_t)fb[i];
				if (!have_hi) {
					hi = e;
					have_hi = 1;
				} else {
					uint64_t packed = hi * 262144u + e;
					printf(" %" PRIu64, packed);
					have_hi = 0;
				}
			}
			if (have_hi) {
				uint64_t packed = hi * 262144u; // E1 = 0, ignored by decoder
				printf(" %" PRIu64, packed);
			}

			fputs(" ]; }\n", stdout);
		}

		// The diff is lossless, so the exact reconstructed previous frame is
		// simply this frame's raw bytes.
		memcpy(prev, fb, fb_len);
	}

	// Reject trailing bytes: a blob longer than its declared frame count is
	// corrupt, and silently ignoring it would desync the loop.
	unsigned char extra;
	if (fread(&extra, 1, 1, stdin) != 0) {
		fprintf(stderr, "emit_delta: trailing bytes past %lu frames\n", frames);
		free(fb);
		free(prev);
		return 1;
	}

	printf("  ];\n");
	printf("  nframes = %lu;\n", frames);
	printf("  # a mod b (Nix has no builtins.mod; integer division floors for >= 0).\n");
	printf("  mod = a: b: a - (a / b) * b;\n");
	// A [backend] fps HUD stamped over EVERY frame (keyframe or delta) via the
	// overlay contract (eval.zig applyOverlay), using the shared importable font
	// lib. scope.backend is 0=fix / 1=nix; scope.fps is the loop's measured rate.
	//
	// The HUD is gated to the NIX backend (scope.backend == 1). Rendering the font
	// in Nix every frame is ~25-40 ms of eval (the <nixbadge/lib/font.nix> import +
	// renderText allocation); on fix that per-frame young-allocation trips the GC
	// missed-edge bug (#34) into a death spiral (eval climbs to tens of seconds).
	// Lazy eval means `hud` is NEVER forced when scope.backend != 1, so fix does
	// zero HUD work and Bad Apple stays at its pre-HUD 60 fps; fix is still identified
	// by the journal [fix] tag. nix (no such GC bug) renders the on-panel HUD.
	printf("  # [backend] fps HUD via the overlay contract + <nixbadge/lib/font.nix>,\n");
	printf("  # gated to nix: rendering the font per-frame in Nix is too costly for fix (#34).\n");
	printf("  font = import <nixbadge/lib/font.nix>;\n");
	printf("  hud = font.renderText {\n");
	printf("    text = \"[\" + (builtins.elemAt [ \"fix\" \"nix\" ] scope.backend) + \"] \" + toString scope.fps + \"fps\";\n");
	printf("    x = 0;\n");
	printf("    width = scope.width;\n");
	printf("  };\n");
	printf("  hudOn = scope.backend == 1;\n");
	printf("in\n");
	// frameIndex is a monotonic per-screen play counter (see badapple-delta.md
	// "Playback model"); it wraps so the clip loops and resets to 0 (a keyframe)
	// on screen entry.
	printf("let fr = builtins.elemAt frames (mod scope.frameIndex nframes);\n");
	printf("in {\n");
	printf("  bitmap   = fr.b;\n");
	printf("  delta    = !fr.k;\n");
	printf("  n        = fr.n or 0;\n");
	printf("  nextMs   = %u;\n", next_ms);
	printf("  overlay  = if hudOn then hud.overlay else [];\n");
	printf("  overlayN = if hudOn then hud.overlayN else 0;\n");
	printf("}\n");

	free(fb);
	free(prev);

	double avg = total_delta_frames
		? (double)total_delta_entries / (double)total_delta_frames
		: 0.0;
	fprintf(stderr,
		"emit_delta: %lu frames, %ux%u @ %u fps, K=%lu; %lu keyframes, "
		"%lu delta frames, %llu delta entries (avg %.1f entries/delta-frame)\n",
		frames, width, height, fps, keyint, total_keyframes,
		total_delta_frames, total_delta_entries, avg);
	return 0;
}
