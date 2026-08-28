// emit_nix.c -- turn a badge "BADA" 1-bit frame blob into a pure-Nix Bad Apple
// PATTERN FILE the embedded fix evaluator applies per frame (see
// pkgs/badge/nix-badge/fixeval.zig renderOled).
//
// Input  (stdin):  the "BADA" blob (pkgs/badge/badapple: 16-byte header + N
//                  frames of WIDTH*HEIGHT/8 page-major GDDRAM bytes).
// Output (stdout): a Nix function
//
//     scope:
//     let
//       frames = [ [ <ints> ... ] ... ];   # N frames, each (fbLen/4) packed ints
//       nframes = N; fps = FPS;
//       mod = a: b: a - (a / b) * b;
//     in {
//       bitmap = builtins.elemAt frames (mod (scope.t * fps / 1000) nframes);
//       nextMs = <1000/fps>;
//     }
//
// Each int packs 4 consecutive page-bytes LITTLE-ENDIAN:
//     int = b0 | b1<<8 | b2<<16 | b3<<24    (b0 = page-byte[i*4])
// so fbLen/4 ints per frame -- the exact inverse of renderOled's decode. The
// scope contract (bitmap = flat int list; nextMs) is the unified content shape;
// the runtime decodes each int back to 4 page-bytes and blits.
//
// Args: emit_nix          (geometry + fps are read from the blob header)
//
// Assisted-by: Claude Opus 4.8 <noreply@anthropic.com>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

static unsigned rd_u16(const unsigned char *p)
{
	return (unsigned)p[0] | ((unsigned)p[1] << 8);
}

static unsigned long rd_u32(const unsigned char *p)
{
	return (unsigned long)p[0] | ((unsigned long)p[1] << 8) |
	       ((unsigned long)p[2] << 16) | ((unsigned long)p[3] << 24);
}

int main(void)
{
	unsigned char header[16];
	if (fread(header, 1, sizeof(header), stdin) != sizeof(header)) {
		fprintf(stderr, "emit_nix: short header\n");
		return 1;
	}
	if (memcmp(header, "BADA", 4) != 0) {
		fprintf(stderr, "emit_nix: not a BADA blob\n");
		return 1;
	}

	unsigned width = rd_u16(header + 4);
	unsigned height = rd_u16(header + 6);
	unsigned fps = rd_u16(header + 8);
	unsigned long frames = rd_u32(header + 12);

	if (width == 0 || height == 0 || (height % 8) != 0 || fps == 0 ||
	    frames == 0) {
		fprintf(stderr, "emit_nix: bad header (w=%u h=%u fps=%u frames=%lu)\n",
			width, height, fps, frames);
		return 1;
	}

	size_t fb_len = (size_t)width * (height / 8); // page-major bytes/frame
	if ((fb_len % 4) != 0) {
		// The runtime packs 4 page-bytes per int; a non-multiple-of-4 frame
		// would drop the tail. 128x32 is 512, a clean multiple.
		fprintf(stderr, "emit_nix: fbLen %zu not a multiple of 4\n", fb_len);
		return 1;
	}
	size_t words = fb_len / 4; // ints per frame

	unsigned char *fb = malloc(fb_len);
	if (!fb) {
		fprintf(stderr, "emit_nix: out of memory\n");
		return 1;
	}

	// The pattern header: a self-contained `scope -> { bitmap; nextMs; }`.
	unsigned next_ms = 1000u / fps;
	if (next_ms == 0)
		next_ms = 1;
	printf("# Pure-Nix Bad Apple, applied per frame by the badge's embedded fix\n");
	printf("# evaluator (pkgs/badge/nix-badge/fixeval.zig renderOled). GENERATED --\n");
	printf("# do not edit; regenerate via pkgs/badge/bling-content/badapple-live.nix.\n");
	printf("# %ux%u, %u fps, %lu frames; each frame is %zu ints, 4 page-bytes/int LE.\n",
		width, height, fps, frames, words);
	printf("scope:\n");
	printf("let\n");
	printf("  frames = [\n");

	for (unsigned long f = 0; f < frames; f++) {
		size_t got = fread(fb, 1, fb_len, stdin);
		if (got != fb_len) {
			fprintf(stderr, "emit_nix: short frame %lu (%zu of %zu bytes)\n",
				f, got, fb_len);
			free(fb);
			return 1;
		}
		fputs("    [", stdout);
		for (size_t i = 0; i < words; i++) {
			uint32_t v = (uint32_t)fb[i * 4 + 0] |
				     ((uint32_t)fb[i * 4 + 1] << 8) |
				     ((uint32_t)fb[i * 4 + 2] << 16) |
				     ((uint32_t)fb[i * 4 + 3] << 24);
			printf(" %lu", (unsigned long)v);
		}
		fputs(" ]\n", stdout);
	}

	// Reject trailing bytes: a blob longer than its declared frame count is
	// corrupt, and silently ignoring it would desync the loop.
	unsigned char extra;
	if (fread(&extra, 1, 1, stdin) != 0) {
		fprintf(stderr, "emit_nix: trailing bytes past %lu frames\n", frames);
		free(fb);
		return 1;
	}

	printf("  ];\n");
	printf("  nframes = %lu;\n", frames);
	printf("  fps = %u;\n", fps);
	printf("  # a mod b (Nix has no builtins.mod; integer division floors for >= 0).\n");
	printf("  mod = a: b: a - (a / b) * b;\n");
	printf("in {\n");
	printf("  # The frame the animation clock lands on; wraps so the clip loops.\n");
	printf("  bitmap = builtins.elemAt frames (mod (scope.t * fps / 1000) nframes);\n");
	printf("  nextMs = %u;\n", next_ms);
	printf("}\n");

	free(fb);
	fprintf(stderr, "emit_nix: %lu frames, %ux%u @ %u fps, %zu ints/frame\n",
		frames, width, height, fps, words);
	return 0;
}
