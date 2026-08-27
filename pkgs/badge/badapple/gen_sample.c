// gen_sample.c -- generate a small, valid, network-free "BADA" blob for the
// runtime team to test the player against, without fetching any video.
//
// It is a self-contained procedural animation (a bouncing filled circle plus a
// sweeping horizontal scanline) in the SAME format the real badapple.bin uses,
// so a player that renders this correctly will render the real blob correctly.
// This is NOT Bad Apple footage -- it is a format fixture. See README.md.
//
// Output (stdout, must be a regular file): the 16-byte header + N 512-byte
// page-major frames for a 128x32 panel, identical layout to pack.c.
//
// Assisted-by: Claude Opus 4.8 <noreply@anthropic.com>

#include <stdio.h>
#include <string.h>
#include <stdint.h>

#define W 128
#define H 32
#define PAGES (H / 8)
#define FBLEN (W * PAGES) // 512
#define FPS 20
#define FRAMES 240        // 12 s at 20 fps -> 16 + 240*512 = 122896 bytes

static uint8_t fb[FBLEN];

static void put_u16(unsigned char *p, unsigned v) { p[0] = v & 0xff; p[1] = (v >> 8) & 0xff; }
static void put_u32(unsigned char *p, unsigned long v)
{ p[0] = v & 0xff; p[1] = (v >> 8) & 0xff; p[2] = (v >> 16) & 0xff; p[3] = (v >> 24) & 0xff; }

static void set_pixel(int x, int y)
{
	if (x < 0 || x >= W || y < 0 || y >= H)
		return;
	fb[(y / 8) * W + x] |= (uint8_t)(1u << (y % 8));
}

int main(void)
{
	unsigned char header[16];
	memset(header, 0, sizeof(header));
	header[0] = 'B'; header[1] = 'A'; header[2] = 'D'; header[3] = 'A';
	put_u16(header + 4, W);
	put_u16(header + 6, H);
	put_u16(header + 8, FPS);
	put_u16(header + 10, 0);        // flags
	put_u32(header + 12, FRAMES);
	fwrite(header, 1, sizeof(header), stdout);

	for (int f = 0; f < FRAMES; f++) {
		memset(fb, 0, sizeof(fb));

		// Bouncing circle: x sweeps across, y bounces top/bottom.
		int cx = 8 + (f * 3) % (W - 16);
		int phase = f % 32;
		int cy = (phase < 16 ? phase : 31 - phase) + 8; // 8..23
		int r = 6;
		for (int y = cy - r; y <= cy + r; y++)
			for (int x = cx - r; x <= cx + r; x++)
				if ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r)
					set_pixel(x, y);

		// A vertical scan bar sweeping left->right, so every column/page is
		// exercised over the animation.
		int bar = (f * 5) % W;
		for (int y = 0; y < H; y++)
			set_pixel(bar, y);

		// A frame border so orientation/edges are obvious on the panel.
		for (int x = 0; x < W; x++) { set_pixel(x, 0); set_pixel(x, H - 1); }
		for (int y = 0; y < H; y++) { set_pixel(0, y); set_pixel(W - 1, y); }

		fwrite(fb, 1, FBLEN, stdout);
	}
	return 0;
}
