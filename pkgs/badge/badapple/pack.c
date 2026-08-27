// pack.c -- pack raw gray8 frames into the badge's SSD1306 "BADA" blob.
//
// Input  (stdin):  a stream of WIDTH*HEIGHT gray8 pixels per frame, row-major,
//                  top-left origin (exactly what `ffmpeg -pix_fmt gray -f
//                  rawvideo` emits after `scale=WIDTH:HEIGHT,format=gray`).
// Output (stdout): the packed blob --
//
//   Header (16 bytes, little-endian):
//     [0:4]   magic 'B','A','D','A'
//     [4:6]   u16 width
//     [6:8]   u16 height
//     [8:10]  u16 fps
//     [10:12] u16 flags (0 = uncompressed raw frames)
//     [12:16] u32 frame_count
//   Then frame_count frames, each WIDTH*HEIGHT/8 bytes in SSD1306 page-major
//   GDDRAM layout: byte = page*WIDTH + col (page in 0..HEIGHT/8-1, col in
//   0..WIDTH-1); within the byte, bit `row` (LSB=row0) is SET iff pixel
//   (x=col, y=page*8+row) is ON. This is exactly the runtime framebuffer:
//   fb[(y/8)*WIDTH + x] with bit (y%8) -- see nix-badge.c set_pixel().
//
// A pixel is ON iff its gray value >= THRESHOLD. The frame_count is written
// last (we don't know it until the input ends), by seeking back over stdout;
// stdout must therefore be a regular file (the derivation redirects to one).
//
// Args: pack WIDTH HEIGHT FPS THRESHOLD
//
// Assisted-by: Claude Opus 4.8 <noreply@anthropic.com>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

static void put_u16(unsigned char *p, unsigned v)
{
	p[0] = (unsigned char)(v & 0xff);
	p[1] = (unsigned char)((v >> 8) & 0xff);
}

static void put_u32(unsigned char *p, unsigned long v)
{
	p[0] = (unsigned char)(v & 0xff);
	p[1] = (unsigned char)((v >> 8) & 0xff);
	p[2] = (unsigned char)((v >> 16) & 0xff);
	p[3] = (unsigned char)((v >> 24) & 0xff);
}

int main(int argc, char **argv)
{
	if (argc != 5) {
		fprintf(stderr, "usage: %s WIDTH HEIGHT FPS THRESHOLD\n", argv[0]);
		return 2;
	}

	int width = atoi(argv[1]);
	int height = atoi(argv[2]);
	int fps = atoi(argv[3]);
	int threshold = atoi(argv[4]);

	if (width <= 0 || height <= 0 || (height % 8) != 0 ||
	    fps <= 0 || fps > 65535 || threshold < 0 || threshold > 255) {
		fprintf(stderr, "pack: bad args (width=%d height=%d fps=%d thr=%d; "
				"height must be a multiple of 8)\n",
			width, height, fps, threshold);
		return 2;
	}

	size_t pixels = (size_t)width * (size_t)height;   // gray8 bytes per input frame
	size_t fb_len = pixels / 8;                       // packed bytes per output frame
	int pages = height / 8;

	unsigned char *gray = malloc(pixels);
	unsigned char *fb = malloc(fb_len);
	if (!gray || !fb) {
		fprintf(stderr, "pack: out of memory\n");
		return 1;
	}

	// Reserve the 16-byte header slot; we rewrite frame_count at the end.
	unsigned char header[16];
	memset(header, 0, sizeof(header));
	header[0] = 'B'; header[1] = 'A'; header[2] = 'D'; header[3] = 'A';
	put_u16(header + 4, (unsigned)width);
	put_u16(header + 6, (unsigned)height);
	put_u16(header + 8, (unsigned)fps);
	put_u16(header + 10, 0);            // flags = 0 (uncompressed)
	put_u32(header + 12, 0);            // frame_count placeholder
	if (fwrite(header, 1, sizeof(header), stdout) != sizeof(header)) {
		fprintf(stderr, "pack: header write failed\n");
		return 1;
	}

	unsigned long frame_count = 0;
	for (;;) {
		size_t got = fread(gray, 1, pixels, stdin);
		if (got == 0)
			break;                 // clean EOF
		if (got != pixels) {
			// A trailing partial frame means the input was truncated;
			// refuse rather than emit a corrupt frame.
			fprintf(stderr, "pack: short frame (%zu of %zu bytes) -- "
					"truncated input\n", got, pixels);
			return 1;
		}

		memset(fb, 0, fb_len);
		for (int y = 0; y < height; y++) {
			int page = y / 8;
			unsigned char bit = (unsigned char)(1u << (y % 8));
			const unsigned char *row = gray + (size_t)y * (size_t)width;
			unsigned char *cell = fb + (size_t)page * (size_t)width;
			for (int x = 0; x < width; x++) {
				if (row[x] >= threshold)
					cell[x] |= bit;
			}
		}

		if (fwrite(fb, 1, fb_len, stdout) != fb_len) {
			fprintf(stderr, "pack: frame write failed\n");
			return 1;
		}
		frame_count++;
		if (frame_count > 0xffffffffUL) {
			fprintf(stderr, "pack: too many frames for u32\n");
			return 1;
		}
	}

	(void)pages;

	// Patch frame_count into the header. stdout must be seekable (regular file).
	if (fflush(stdout) != 0) {
		fprintf(stderr, "pack: flush failed\n");
		return 1;
	}
	if (fseek(stdout, 12, SEEK_SET) != 0) {
		fprintf(stderr, "pack: cannot seek stdout (must be a regular file)\n");
		return 1;
	}
	unsigned char cnt[4];
	put_u32(cnt, frame_count);
	if (fwrite(cnt, 1, sizeof(cnt), stdout) != sizeof(cnt)) {
		fprintf(stderr, "pack: frame_count write failed\n");
		return 1;
	}

	fprintf(stderr, "pack: %lu frames, %dx%d @ %d fps, %lu bytes total\n",
		frame_count, width, height, fps,
		(unsigned long)(16 + frame_count * fb_len));
	return 0;
}
