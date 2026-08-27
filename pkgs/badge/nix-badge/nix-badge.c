// nix-badge: drive the badge WS2812 (NeoPixel) ring from the SG2000 SPI3
// controller through spidev.
//
// WS2812 is a single-wire part. It has no clock line. Each LED bit is a pulse
// whose HIGH time gives the bit value. We make those pulses with the SPI MOSI
// line, sending several SPI bits for each LED bit.
//
// Three encodings are available, chosen with "bits":
//
//   bits = 8 (DEFAULT)   0 -> 0b10000000   1 -> 0b11111100   high 12.5% or 75%
//   bits = 4             0 -> 0b1000       1 -> 0b1110       high 25%   or 75%
//   bits = 3             0 -> 0b100        1 -> 0b110        high 33%   or 67%
//
// 8-bit uses one whole SPI byte per LED bit. 4-bit packs two LED bits per byte
// and is the scheme joosteto/ws2812-spi uses. 3-bit packs 8 LED bits into 3
// bytes. None lets a bit straddle a byte boundary.
//
// 8-BIT IS THE DEFAULT BECAUSE THE OTHER TWO FAILED ON REAL HARDWARE, and the
// way they failed is worth recording:
//
//   3-bit: only responded within about 1% of nominal timing, and even there
//          bits flipped at random. A 33/67 split leaves too little margin.
//   4-bit: asking for pure red (G=0x00, R=0xff, B=0x00) lit the ring WHITE.
//          Two of the three bytes are all zeros, so the ZERO bits were being
//          read as ones. Slowing the clock made it brighter, which is the same
//          fault seen from the other side: a longer clock stretches every
//          pulse, so even more zeros cross the threshold.
//
// The badge's XL parts latch a 1 somewhere below the 320 ns that 4-bit's 25%
// duty produced at 3.125 MHz. 8-bit halves the zero pulse to 160 ns while
// leaving the one pulse at 960 ns, and that combination reads correctly.
//
// THE BADGE PARTS ARE NOT WS2812B. The chain is a mix of XL-1615 and XL-2020,
// whose T1H window is 0.9 to 1.0 us, NOT the 0.8 us +/- 0.15 of a WS2812B.
// Stock NeoPixel and FastLED timing violates it. From the board device tree:
//
//   "Mixed XL-1615/XL-2020 chain: T1H window is only 0.9-1.0 us - stock
//    NeoPixel/FastLED timing violates it. Use spidev at 3.2 MHz, encode
//    0 -> 1000, 1 -> 1110, latch >= 300 us"
//
// CHIP SELECT GATES THE DATA. The badge wires LED_DIN = CS AND SDO through
// U10, so the LEDs only see SDO while CS is HIGH. A normal active-low CS sits
// low for the whole transfer, the AND gate emits a constant zero, and the LEDs
// receive nothing. The gating is deliberate: it lets SPI3 be shared without
// corrupting the chain.
//
// This is fixed in the DEVICE TREE, not here. spi3 declares
//   cs-gpios = <&portb 16 GPIO_ACTIVE_HIGH>
// and the pad is muxed to XGPIOB_16 (mux 3) instead of SPI3_CS (mux 5).
//
// SPI_CS_HIGH from userspace does NOT work for this. With the native DW chip
// select, dw_spi_set_cs only decides whether to raise the Slave Enable bit,
// and its own comment says SER is set "no matter whether the SPI core is
// configured to support active-high or active-low CS level". The pad stays
// active-low in hardware. Only a gpiod chip select honours polarity, through
// spi_toggle_csgpiod() -> gpiod_set_value(desc, activate). dw_spi sets
// SPI_CONTROLLER_GPIO_SS, so SER is still raised and the transfer still runs.
//
// THE POLARITY IS SET BY "spi-cs-high" ON THE SPIDEV CHILD NODE, not by the
// GPIO_ACTIVE_HIGH flag on cs-gpios. gpiolib-of.c has a quirk that forces every
// SPI cs-gpio active low unless the child node carries that property. Without
// it gpioinfo showed:
//   line 16: output active-low consumer="spi3 CS0"
// cs_high here just keeps the spidev mode consistent with what the DT declared.
//
// Clock math on this SoC, MEASURED on a Milk-V Duo S rather than assumed:
//   /sys/kernel/debug/clk/clk_spi/clk_rate reads 187500000, so ssi_clk is
//   187.5 MHz and FPLL is 1.5 GHz (clk_spi = FPLL / 8).
//   The DesignWare APB SSI divides ssi_clk by an even integer:
//     clk_div  = (DIV_ROUND_UP(ssi_clk, freq) + 1) & 0xfffe
//
//   8-bit at 6400000 Hz gives divider 30, so 6250000 Hz:
//     SPI bit  = 160 ns
//     T0H      = 160 ns    (1 bit high)
//     T1H      = 960 ns    (6 bits high, inside the XL 900..1000 ns window)
//     LED bit  = 1280 ns
//   CONFIRMED WORKING on the badge: solid colours are correct at these values.
//
//   For reference, 4-bit at 3200000 Hz gives the same 960 ns T1H and the same
//   1280 ns period, but a 320 ns T0H, and that zero pulse was too long. The
//   period is not the problem, the zero pulse is.
//
// The program runs in the initrd and stays alive after switch_root, so it must
// not depend on anything outside its own store path.

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <linux/gpio.h>
#include <linux/spi/spidev.h>

// Path that the CLI writes and that the service reads after the base config.
// The initrd has no /var, so early boot always uses the declarative config.
#define RUNTIME_CONF "/var/lib/nix-badge/leds.conf"
#define RUNTIME_DIR "/var/lib/nix-badge"

// How often a static pattern wakes to look for a config change. An animation
// polls once per frame instead, which it gets for free.
#define IDLE_POLL_HZ 2

// How long to keep looking for the SPI clock in debugfs. The service starts in
// the initrd, so debugfs only appears once stage 2 mounts it.
#define CLK_REPORT_TIMEOUT_SECONDS 120

#define MAX_LEDS 1024
#define MAX_COLORS 16
#define OPEN_RETRY_SECONDS 30

// Reset/latch time held low at the end of a frame. The badge's XL-1615 and
// XL-2020 parts want at least 300 us, far more than the 50-80 us a WS2812
// needs, so this is sized for them with margin.
#define LATCH_US 320
#define MAX_SPEED_HZ 20000000u

// Latch length in bytes at a given clock. Each byte is 8 SPI bits.
static unsigned latch_bytes(unsigned speed_hz)
{
	return (unsigned)(((unsigned long long)LATCH_US * speed_hz) /
			  8000000ULL) +
	       1;
}

// Worst case latch, used for allocation so a clock change never has to
// resize the frame buffer.
#define MAX_LATCH_BYTES (((LATCH_US * (unsigned long long)MAX_SPEED_HZ) / 8000000ULL) + 1)

enum pattern {
	PAT_OFF = 0,
	PAT_SOLID,
	PAT_PULSE,
	PAT_RAINBOW,
	PAT_CHASE,
};

static const char *const pattern_names[] = {
	"off", "solid", "pulse", "rainbow", "chase", NULL,
};

struct rgb {
	uint8_t r, g, b;
};

struct config {
	char device[256];
	unsigned count;
	unsigned speed_hz;
	unsigned bits; // SPI bits per LED bit, 3 or 4
	unsigned cs_high; // mirrors the DTS "spi-cs-high", see the header
	unsigned brightness; // 0-255, applied in software
	unsigned fps;
	enum pattern pattern;
	struct rgb colors[MAX_COLORS];
	unsigned ncolors;
};

// SPI bytes needed for one LED. 3-bit packs 8 LED bits into 3 bytes, 4-bit
// packs 2 LED bits into 1 byte, so 8 LED bits into 4 bytes.
static unsigned bytes_per_led(unsigned bits)
{
	switch (bits) {
	case 8:
		return 24u; // 1 SPI byte per LED bit
	case 4:
		return 12u; // 2 LED bits per SPI byte
	default:
		return 9u; // 8 LED bits per 3 SPI bytes
	}
}

static volatile sig_atomic_t stop_requested;

static void on_signal(int sig)
{
	(void)sig;
	stop_requested = 1;
}

static void die(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "nix-badge: ");
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fprintf(stderr, "\n");
	exit(1);
}

// ---------------------------------------------------------------- config ---

static void config_defaults(struct config *c)
{
	snprintf(c->device, sizeof(c->device), "/dev/spidev3.0");
	c->count = 24;
	c->speed_hz = 6400000; // 8-bit: T0H 160 ns, T1H 960 ns
	c->bits = 8;
	c->cs_high = 1; // match the DTS spi-cs-high, see spi_open()
	c->brightness = 64;
	c->fps = 30;
	c->pattern = PAT_RAINBOW;
	c->ncolors = 1;
	c->colors[0] = (struct rgb){ 255, 255, 255 };
}

static int parse_pattern(const char *s, enum pattern *out)
{
	for (unsigned i = 0; pattern_names[i]; i++) {
		if (strcmp(s, pattern_names[i]) == 0) {
			*out = (enum pattern)i;
			return 0;
		}
	}
	return -1;
}

// A local hex test keeps the locale out of the parse.
static int isxdigit_ascii(char ch)
{
	return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') ||
	       (ch >= 'A' && ch <= 'F');
}

// Accept "#rrggbb" or "rrggbb".
static int parse_color(const char *s, struct rgb *out)
{
	if (*s == '#')
		s++;
	if (strlen(s) != 6)
		return -1;
	for (unsigned i = 0; i < 6; i++) {
		if (!isxdigit_ascii(s[i]))
			return -1;
	}
	unsigned long v = strtoul(s, NULL, 16);
	out->r = (v >> 16) & 0xff;
	out->g = (v >> 8) & 0xff;
	out->b = v & 0xff;
	return 0;
}

// Split a comma separated colour list.
static int parse_colors(const char *s, struct config *c)
{
	char buf[512];
	snprintf(buf, sizeof(buf), "%s", s);
	c->ncolors = 0;
	char *save = NULL;
	for (char *tok = strtok_r(buf, ",", &save); tok;
	     tok = strtok_r(NULL, ",", &save)) {
		while (*tok == ' ')
			tok++;
		if (*tok == '\0')
			continue;
		if (c->ncolors >= MAX_COLORS)
			break;
		if (parse_color(tok, &c->colors[c->ncolors]) != 0)
			return -1;
		c->ncolors++;
	}
	if (c->ncolors == 0)
		return -1;
	return 0;
}

static void apply_kv(struct config *c, const char *key, const char *val,
		     const char *where)
{
	if (strcmp(key, "device") == 0) {
		snprintf(c->device, sizeof(c->device), "%s", val);
	} else if (strcmp(key, "count") == 0) {
		unsigned n = (unsigned)strtoul(val, NULL, 10);
		if (n == 0 || n > MAX_LEDS)
			die("%s: count %u is out of range 1-%u", where, n,
			    MAX_LEDS);
		c->count = n;
	} else if (strcmp(key, "speed_hz") == 0) {
		c->speed_hz = (unsigned)strtoul(val, NULL, 10);
	} else if (strcmp(key, "cs_high") == 0) {
		c->cs_high = strtoul(val, NULL, 10) ? 1u : 0u;
	} else if (strcmp(key, "bits") == 0) {
		unsigned n = (unsigned)strtoul(val, NULL, 10);
		if (n != 3 && n != 4 && n != 8)
			die("%s: bits must be 3, 4 or 8, got %u", where, n);
		c->bits = n;
	} else if (strcmp(key, "brightness") == 0) {
		unsigned n = (unsigned)strtoul(val, NULL, 10);
		c->brightness = n > 255 ? 255 : n;
	} else if (strcmp(key, "fps") == 0) {
		unsigned n = (unsigned)strtoul(val, NULL, 10);
		c->fps = n == 0 ? 1 : (n > 200 ? 200 : n);
	} else if (strcmp(key, "pattern") == 0) {
		if (parse_pattern(val, &c->pattern) != 0)
			die("%s: unknown pattern '%s'", where, val);
	} else if (strcmp(key, "colors") == 0) {
		if (parse_colors(val, c) != 0)
			die("%s: bad colour list '%s'", where, val);
	}
	// Unknown keys are ignored so an old runtime file cannot block a boot.
}

// Read "key = value" lines. Blank lines and lines that start with # are
// skipped. A missing file is not an error, the caller decides that.
static int config_load(struct config *c, const char *path, int required)
{
	FILE *f = fopen(path, "r");
	if (!f) {
		if (required)
			die("cannot open config %s: %s", path, strerror(errno));
		return -1;
	}
	char line[600];
	while (fgets(line, sizeof(line), f)) {
		char *p = line;
		while (*p == ' ' || *p == '\t')
			p++;
		if (*p == '#' || *p == '\n' || *p == '\0')
			continue;
		char *eq = strchr(p, '=');
		if (!eq)
			continue;
		*eq = '\0';
		char *key = p;
		char *val = eq + 1;
		// Trim the key tail.
		for (char *k = key + strlen(key); k > key; k--) {
			if (k[-1] == ' ' || k[-1] == '\t')
				k[-1] = '\0';
			else
				break;
		}
		// Trim the value head and tail.
		while (*val == ' ' || *val == '\t')
			val++;
		for (char *v = val + strlen(val); v > val; v--) {
			if (v[-1] == '\n' || v[-1] == '\r' || v[-1] == ' ' ||
			    v[-1] == '\t')
				v[-1] = '\0';
			else
				break;
		}
		apply_kv(c, key, val, path);
	}
	fclose(f);
	return 0;
}

// --------------------------------------------------------------- pattern ---

// Integer colour wheel. It avoids libm so the binary stays small.
static struct rgb wheel(uint8_t pos)
{
	struct rgb c;
	pos = 255 - pos;
	if (pos < 85) {
		c.r = 255 - pos * 3;
		c.g = 0;
		c.b = pos * 3;
	} else if (pos < 170) {
		pos -= 85;
		c.r = 0;
		c.g = pos * 3;
		c.b = 255 - pos * 3;
	} else {
		pos -= 170;
		c.r = pos * 3;
		c.g = 255 - pos * 3;
		c.b = 0;
	}
	return c;
}

static uint8_t scale(uint8_t v, unsigned num)
{
	return (uint8_t)((unsigned)v * num / 255u);
}

// Triangle wave from 0 to 255 and back. It gives a pulse without libm.
static unsigned triangle(unsigned frame, unsigned period)
{
	unsigned x = frame % period;
	unsigned half = period / 2;
	if (half == 0)
		return 255;
	return x < half ? x * 255 / half : (period - x) * 255 / half;
}

static void render(const struct config *c, unsigned frame, struct rgb *out)
{
	switch (c->pattern) {
	case PAT_OFF:
		memset(out, 0, c->count * sizeof(*out));
		break;

	case PAT_SOLID:
		for (unsigned i = 0; i < c->count; i++)
			out[i] = c->colors[i % c->ncolors];
		break;

	case PAT_PULSE: {
		unsigned lvl = triangle(frame, c->fps * 2);
		struct rgb base = c->colors[0];
		struct rgb v = { scale(base.r, lvl), scale(base.g, lvl),
				 scale(base.b, lvl) };
		for (unsigned i = 0; i < c->count; i++)
			out[i] = v;
		break;
	}

	case PAT_RAINBOW:
		for (unsigned i = 0; i < c->count; i++) {
			unsigned pos = (i * 256u / c->count + frame) & 0xff;
			out[i] = wheel((uint8_t)pos);
		}
		break;

	case PAT_CHASE: {
		memset(out, 0, c->count * sizeof(*out));
		unsigned head = frame % c->count;
		unsigned lap = frame / c->count;
		out[head] = c->colors[lap % c->ncolors];
		break;
	}
	}

	// Global brightness. WS2812 has no brightness byte, unlike APA102, so
	// we scale the channels here.
	if (c->brightness < 255) {
		for (unsigned i = 0; i < c->count; i++) {
			out[i].r = scale(out[i].r, c->brightness);
			out[i].g = scale(out[i].g, c->brightness);
			out[i].b = scale(out[i].b, c->brightness);
		}
	}
}

// --------------------------------------------------------------- encoder ---

// 3 SPI bits per LED bit: 0 -> 0b100, 1 -> 0b110. One LED byte becomes exactly
// 3 SPI bytes, MSB first, so no bit straddles a byte boundary.
//
// The high time is 1/3 or 2/3 of the bit period. That separation is narrow,
// and on this badge it turned out to be too narrow: only a clock within about
// 1% of nominal produced anything, and even then bits flipped at random.
static void encode_byte3(uint8_t v, uint8_t *out)
{
	uint32_t acc = 0;
	for (int i = 7; i >= 0; i--) {
		acc <<= 3;
		acc |= ((v >> i) & 1) ? 0x6u : 0x4u; // 0b110 : 0b100
	}
	out[0] = (uint8_t)(acc >> 16);
	out[1] = (uint8_t)(acc >> 8);
	out[2] = (uint8_t)acc;
}

// 4 SPI bits per LED bit: 0 -> 0b1000, 1 -> 0b1110. Two LED bits pack into one
// SPI byte, so one LED byte becomes 4 SPI bytes, again with no straddling.
//
// This is the scheme joosteto/ws2812-spi uses:
//   ((d>>(2*ibit+1))&1)*0x60 + ((d>>(2*ibit+0))&1)*0x06 + 0x88
//     0x88 = 1000 1000   both bits 0
//    +0x60 = 1110 1000   high bit 1
//    +0x06 = 1000 1110   low bit 1
// We take the bit pairs MSB first, because WS2812 wants the most significant
// bit of each channel first.
//
// The high time is 1/4 or 3/4 of the bit period, roughly double the 3-bit
// scheme's margin, which is why this survives edge degradation that the 3-bit
// scheme does not.
static void encode_byte4(uint8_t v, uint8_t *out)
{
	for (unsigned i = 0; i < 4; i++) {
		unsigned hi = (v >> (7 - 2 * i)) & 1;
		unsigned lo = (v >> (6 - 2 * i)) & 1;
		out[i] = (uint8_t)(0x88u | (hi ? 0x60u : 0u) |
				   (lo ? 0x06u : 0u));
	}
}

// 8 SPI bits per LED bit: one whole SPI byte carries one LED bit.
//   0 -> 0b10000000 (0x80)   high for 1/8 of the period
//   1 -> 0b11111100 (0xfc)   high for 6/8 of the period
//
// This exists because the 4-bit scheme's 25% "0" pulse was still too long for
// the badge's XL parts: asking for pure red (G=0x00, R=0xff, B=0x00) lit the
// ring WHITE, meaning the zero bits were being read as ones, and slowing the
// clock made it worse because it stretched the pulse further.
//
// At 6.25 MHz this gives T0H 160 ns and T1H 960 ns, so the zero pulse is half
// what 4-bit produced while the one pulse stays inside the XL 900..1000 ns
// window.
static void encode_byte8(uint8_t v, uint8_t *out)
{
	for (unsigned i = 0; i < 8; i++)
		out[i] = ((v >> (7 - i)) & 1) ? 0xfcu : 0x80u;
}

// WS2812 takes the channels in G, R, B order.
static void encode_frame(const struct rgb *px, unsigned count, unsigned bits,
			 unsigned latch, uint8_t *out)
{
	const unsigned bpl = bytes_per_led(bits);
	const unsigned bpc = bpl / 3; // bytes per colour channel

	for (unsigned i = 0; i < count; i++) {
		uint8_t *p = out + i * bpl;
		switch (bits) {
		case 8:
			encode_byte8(px[i].g, p + 0 * bpc);
			encode_byte8(px[i].r, p + 1 * bpc);
			encode_byte8(px[i].b, p + 2 * bpc);
			break;
		case 4:
			encode_byte4(px[i].g, p + 0 * bpc);
			encode_byte4(px[i].r, p + 1 * bpc);
			encode_byte4(px[i].b, p + 2 * bpc);
			break;
		default:
			encode_byte3(px[i].g, p + 0 * bpc);
			encode_byte3(px[i].r, p + 1 * bpc);
			encode_byte3(px[i].b, p + 2 * bpc);
			break;
		}
	}
	memset(out + count * bpl, 0, latch);
}

// ------------------------------------------------------------------ spi ----

// The clock that feeds the SPI controller. The sophgo clk driver names it
// clk_spi, and the common clock framework exports its rate through debugfs.
#define SSI_CLK_RATE_PATH "/sys/kernel/debug/clk/clk_spi/clk_rate"

// spidev refuses a transfer larger than its bufsiz module parameter, which
// defaults to 4096, with EMSGSIZE ("Message too long"). Read the real value so
// the LED count can be clamped to something the driver will actually accept.
#define SPIDEV_BUFSIZ_PATH "/sys/module/spidev/parameters/bufsiz"
#define SPIDEV_BUFSIZ_FALLBACK 4096

static unsigned long read_spidev_bufsiz(void)
{
	FILE *f = fopen(SPIDEV_BUFSIZ_PATH, "r");
	if (!f)
		return SPIDEV_BUFSIZ_FALLBACK;
	unsigned long n = 0;
	if (fscanf(f, "%lu", &n) != 1 || n == 0)
		n = SPIDEV_BUFSIZ_FALLBACK;
	fclose(f);
	return n;
}

// Largest LED count whose frame still fits in one spidev transfer. The frame
// must go out as ONE transfer: splitting it would put a gap in the middle, and
// a gap longer than 50 us is a WS2812 latch.
static unsigned max_count_for_bufsiz(unsigned long bufsiz, unsigned bpl)
{
	if (bufsiz <= MAX_LATCH_BYTES)
		return 1;
	unsigned n = (unsigned)((bufsiz - MAX_LATCH_BYTES) / bpl);
	return n < 1 ? 1 : n;
}

// Return the SPI input clock in Hz, or 0 when it cannot be read.
static unsigned long read_ssi_clk(void)
{
	FILE *f = fopen(SSI_CLK_RATE_PATH, "r");
	if (!f)
		return 0;
	unsigned long hz = 0;
	if (fscanf(f, "%lu", &hz) != 1)
		hz = 0;
	fclose(f);
	return hz;
}

// Report the bit timing that the hardware really produces. Returns 1 when it
// managed to read the clock, 0 when the clock is not available yet.
//
// SPI_IOC_RD_MAX_SPEED_HZ is useless for this: spidev.c returns the value we
// wrote, not the rate the controller uses. The DesignWare driver picks an even
// divider of its input clock at transfer time (spi-dw-core.c):
//
//   clk_div  = (DIV_ROUND_UP(ssi_clk, freq) + 1) & 0xfffe
//   speed_hz = ssi_clk / clk_div
//
// So we read ssi_clk and do the same arithmetic. The service starts in the
// initrd, where debugfs is not mounted, so the first attempt usually fails and
// the caller retries until stage 2 mounts it.
static int log_clock(const struct config *c)
{
	unsigned long ssi = read_ssi_clk();
	if (!ssi)
		return 0;

	unsigned long div =
		(((ssi + c->speed_hz - 1) / c->speed_hz) + 1) & 0xfffeUL;
	unsigned long actual = div ? ssi / div : 0;
	unsigned ns = actual ? (unsigned)(1000000000ull / actual) : 0;

	// A 0 is one high SPI bit in both encodings. A 1 is all but the last
	// bit high, so 2 of 3 or 3 of 4. Getting this wrong made the log claim
	// T1H 532 ns when the wire really carried 800 ns.
	unsigned t0h = ns;
	unsigned t1h = ns * (c->bits - 1);
	unsigned period = ns * c->bits;

	fprintf(stderr,
		"nix-badge: %s ssi_clk %lu Hz, divider %lu, actual %lu Hz, "
		"SPI bit %u ns, %u bits per LED bit -> T0H %u ns, T1H %u ns, "
		"period %u ns (WS2812B wants 400, 800 and 1250 ns, +/- 150)\n",
		c->device, ssi, div, actual, ns, c->bits, t0h, t1h, period);
	return 1;
}

static int spi_open(const struct config *c)
{
	int fd = -1;
	// The SPI controller and spidev may bind after we start, above all in
	// the initrd, so we wait for the node instead of failing at once.
	for (unsigned waited = 0; waited <= OPEN_RETRY_SECONDS; waited++) {
		fd = open(c->device, O_RDWR | O_CLOEXEC);
		if (fd >= 0)
			break;
		if (waited == 0)
			fprintf(stderr,
				"nix-badge: waiting for %s (%s)\n",
				c->device, strerror(errno));
		sleep(1);
	}
	if (fd < 0) {
		// A missing node means the board has no LED bus, for example a
		// core whose device tree does not mux SPI3. That is not a
		// failure worth restarting for, so we tell the caller to stop.
		fprintf(stderr,
			"nix-badge: %s did not appear after %u seconds, "
			"giving up\n",
			c->device, OPEN_RETRY_SECONDS);
		return -1;
	}

	// The badge wires LED_DIN = CS AND SDO through U10, so the chip select
	// GATES the data. With the usual active-low CS the line sits low for
	// the whole transfer and the AND gate emits a constant zero, so the
	// LEDs receive nothing at all. Active-high CS holds it high while we
	// transmit, letting SDO through.
	//
	// dw_spi does not advertise SPI_CS_HIGH in ctlr->mode_bits, but the SPI
	// core adds it for any controller with use_gpio_descriptors set
	// (spi.c: "A controller using GPIO descriptors always supports
	// SPI_CS_HIGH if need be"), and dw_spi_set_cs honours the flag. So this
	// works even though CS here is the native pad, not a GPIO.
	uint8_t mode = SPI_MODE_0 | (c->cs_high ? SPI_CS_HIGH : 0);
	uint8_t bits = 8;
	uint32_t speed = c->speed_hz;

	if (ioctl(fd, SPI_IOC_WR_MODE, &mode) < 0)
		die("SPI_IOC_WR_MODE (mode 0x%02x): %s", mode, strerror(errno));
	if (ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, &bits) < 0)
		die("SPI_IOC_WR_BITS_PER_WORD: %s", strerror(errno));
	if (ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, &speed) < 0)
		die("SPI_IOC_WR_MAX_SPEED_HZ: %s", strerror(errno));

	return fd;
}

// -------------------------------------------------------------- commands ---

// Modification time of the runtime config, or -1 when it does not exist.
static int runtime_mtime(struct timespec *out)
{
	struct stat st;
	if (stat(RUNTIME_CONF, &st) != 0)
		return -1;
	*out = st.st_mtim;
	return 0;
}

// Re-read the config and take over the fields the CLI is allowed to change.
// The hardware fields (device, count, speed_hz) are NOT reloaded: the SPI node
// is already open and the frame buffers are already sized, and those values
// describe the board, not a user preference. They come from the declarative
// config and change only with a rebuild.
static void reload_live(struct config *cfg, const char *base)
{
	struct config fresh;
	config_defaults(&fresh);
	if (base)
		config_load(&fresh, base, 0);
	config_load(&fresh, RUNTIME_CONF, 0);

	cfg->pattern = fresh.pattern;
	cfg->brightness = fresh.brightness;
	cfg->fps = fresh.fps;
	cfg->count = fresh.count;
	// speed_hz is reloadable because the WS2812 bit time comes straight from
	// it, and the right value depends on which LED part is fitted. Sweeping
	// it at run time beats guessing and reflashing. Each transfer carries
	// its own speed_hz, so nothing has to be reopened.
	cfg->speed_hz = fresh.speed_hz;
	cfg->bits = fresh.bits;
	cfg->ncolors = fresh.ncolors;
	memcpy(cfg->colors, fresh.colors, sizeof(cfg->colors));

	fprintf(stderr,
		"nix-badge: reloaded, pattern %s, brightness %u, %u fps\n",
		pattern_names[cfg->pattern], cfg->brightness, cfg->fps);
}

static int cmd_run(int argc, char **argv)
{
	struct config cfg;
	config_defaults(&cfg);

	const char *base = NULL;
	for (int i = 0; i < argc; i++) {
		if (strcmp(argv[i], "--config") == 0 && i + 1 < argc)
			base = argv[++i];
		else
			die("run: unknown argument '%s'", argv[i]);
	}
	if (base)
		config_load(&cfg, base, 1);
	// The runtime file wins when it exists. It is absent in the initrd.
	config_load(&cfg, RUNTIME_CONF, 0);

	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);

	const unsigned long bufsiz = read_spidev_bufsiz();
	// Recomputed on reload, because the 4-bit encoding needs 12 bytes per
	// LED where the 3-bit one needs 9.
	unsigned max_count = max_count_for_bufsiz(bufsiz, bytes_per_led(cfg.bits));
	if (cfg.count > max_count) {
		fprintf(stderr,
			"nix-badge: count %u needs %u bytes but spidev takes "
			"%lu, clamping to %u\n",
			cfg.count, cfg.count * bytes_per_led(cfg.bits) + latch_bytes(cfg.speed_hz), bufsiz,
			max_count);
		cfg.count = max_count;
	}

	struct rgb *px = calloc(cfg.count, sizeof(*px));
	uint8_t *frame = calloc(cfg.count * bytes_per_led(cfg.bits) + MAX_LATCH_BYTES, 1);
	if (!px || !frame)
		die("out of memory for %u leds", cfg.count);

	int fd = spi_open(&cfg);
	if (fd < 0) {
		free(px);
		free(frame);
		return 0; // clean stop, so systemd does not restart us forever
	}
	// Not const: a reload can change the LED count and resize the buffers.
	size_t framelen = cfg.count * bytes_per_led(cfg.bits) + latch_bytes(cfg.speed_hz);

	fprintf(stderr,
		"nix-badge: %u leds, pattern %s, brightness %u, %u fps, "
		"%zu bytes per frame\n",
		cfg.count, pattern_names[cfg.pattern], cfg.brightness, cfg.fps,
		framelen);

	// The clock lives in debugfs, which is not mounted in the initrd, so we
	// keep trying until stage 2 mounts it. We stop after a while so a
	// system without debugfs does not poll for ever.
	int clk_logged = log_clock(&cfg);
	time_t clk_deadline = time(NULL) + CLK_REPORT_TIMEOUT_SECONDS;
	if (!clk_logged)
		fprintf(stderr,
			"nix-badge: %s not readable yet, will report the "
			"real bit timing once it appears\n",
			SSI_CLK_RATE_PATH);

	struct timespec seen;
	int have_seen = runtime_mtime(&seen) == 0;
	unsigned n = 0;
	// Report the transfer duration once at start and once after every
	// reload, so a settings change shows its own measurement.
	int report_timing = 1;

	while (!stop_requested) {
		if (!clk_logged) {
			clk_logged = log_clock(&cfg);
			if (!clk_logged && time(NULL) > clk_deadline) {
				fprintf(stderr,
					"nix-badge: giving up on %s, bit "
					"timing stays unverified\n",
					SSI_CLK_RATE_PATH);
				clk_logged = 1; // stop retrying
			}
		}

		struct timespec now;
		int have_now = runtime_mtime(&now) == 0;
		if (have_now != have_seen ||
		    (have_now && (now.tv_sec != seen.tv_sec ||
				  now.tv_nsec != seen.tv_nsec))) {
			seen = now;
			have_seen = have_now;
			unsigned old_count = cfg.count;
			unsigned old_speed = cfg.speed_hz;
			unsigned old_bits = cfg.bits;
			reload_live(&cfg, base);
			n = 0;
			report_timing = 1;

			// A different encoding changes the frame size, so the
			// clamp and the buffers both have to follow it.
			if (cfg.bits != old_bits) {
				max_count = max_count_for_bufsiz(
					bufsiz, bytes_per_led(cfg.bits));
				fprintf(stderr,
					"nix-badge: encoding now %u bits per "
					"LED bit (%u bytes per LED)\n",
					cfg.bits, bytes_per_led(cfg.bits));
			}

			if (cfg.count > max_count) {
				fprintf(stderr,
					"nix-badge: count %u needs %u bytes "
					"but spidev takes %lu, clamping to %u\n",
					cfg.count, cfg.count * bytes_per_led(cfg.bits) + latch_bytes(cfg.speed_hz),
					bufsiz, max_count);
				cfg.count = max_count;
			}

			if (cfg.speed_hz != old_speed) {
				uint32_t sp = cfg.speed_hz;
				if (ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, &sp) < 0)
					fprintf(stderr,
						"nix-badge: cannot set %u Hz: "
						"%s\n",
						cfg.speed_hz, strerror(errno));
				else
					log_clock(&cfg);
			}

			// count is reloadable so the ring length can be
			// bisected without a rebuild. That matters when only
			// the first few LEDs respond and you need to find
			// where the chain stops working.
			if (cfg.count != old_count || cfg.bits != old_bits) {
				struct rgb *npx =
					realloc(px, cfg.count * sizeof(*px));
				uint8_t *nframe = realloc(
					frame, cfg.count * bytes_per_led(cfg.bits) + MAX_LATCH_BYTES);
				if (npx && nframe) {
					px = npx;
					frame = nframe;
					framelen = cfg.count * bytes_per_led(cfg.bits) + latch_bytes(cfg.speed_hz);
					fprintf(stderr,
						"nix-badge: count now %u, "
						"%zu bytes per frame\n",
						cfg.count, framelen);
				} else {
					// Adopt whichever block did move, so we
					// never keep a pointer we no longer own,
					// then roll BOTH count and bits back.
					// Rolling back only count would leave
					// the encoder writing 12 bytes per LED
					// into a buffer sized for 9.
					if (npx)
						px = npx;
					if (nframe)
						frame = nframe;
					fprintf(stderr,
						"nix-badge: cannot resize to "
						"%u leds at %u bits, keeping %u "
						"at %u\n",
						cfg.count, cfg.bits, old_count,
						old_bits);
					cfg.count = old_count;
					cfg.bits = old_bits;
					max_count = max_count_for_bufsiz(
						bufsiz, bytes_per_led(cfg.bits));
					framelen = cfg.count * bytes_per_led(cfg.bits) +
						   latch_bytes(cfg.speed_hz);
				}
			}
		}

		int animated = cfg.pattern != PAT_OFF && cfg.pattern != PAT_SOLID;

		// Every tick repaints, including static patterns. A WS2812 chain
		// has no error recovery of its own: one corrupted frame stays on
		// screen for ever. Repainting at the idle rate makes the display
		// self-healing, and 280 bytes twice a second costs nothing.
		{
			render(&cfg, n, px);
			encode_frame(px, cfg.count, cfg.bits, latch_bytes(cfg.speed_hz), frame);

			struct spi_ioc_transfer tr;
			memset(&tr, 0, sizeof(tr));
			tr.tx_buf = (unsigned long)frame;
			tr.rx_buf = 0;
			tr.len = (uint32_t)framelen;
			tr.speed_hz = cfg.speed_hz;
			tr.bits_per_word = 8;

			// Time the transfer. A WS2812 frame must leave the pin as
			// one continuous bit stream: any gap longer than 50 us
			// is a latch, and the rest of the frame then lands in
			// LEDs that have already stopped listening. spidev
			// cannot report that, but a transfer that takes much
			// longer than its own bit count says the controller
			// stalled, which is the same thing. This is the only
			// way to see it without a scope.
			struct timespec t_a, t_b;
			clock_gettime(CLOCK_MONOTONIC, &t_a);

			int xfer_rc = ioctl(fd, SPI_IOC_MESSAGE(1), &tr);

			clock_gettime(CLOCK_MONOTONIC, &t_b);
			if (report_timing) {
				report_timing = 0;
				unsigned long took_us =
					(unsigned long)((t_b.tv_sec - t_a.tv_sec) *
								1000000L +
							(t_b.tv_nsec -
							 t_a.tv_nsec) /
								1000L);
				unsigned long ideal_us =
					(unsigned long)framelen * 8UL *
					1000000UL / cfg.speed_hz;
				fprintf(stderr,
					"nix-badge: transfer %zu bytes took "
					"%lu us, continuous would be %lu us%s\n",
					framelen, took_us, ideal_us,
					(ideal_us && took_us > ideal_us * 2)
						? "  <- STALLED, the bit stream "
						  "is not continuous"
						: "");
			}

			if (xfer_rc < 0) {
				// A transient error must not kill the boot
				// indicator.
				fprintf(stderr,
					"nix-badge: transfer failed: %s\n",
					strerror(errno));
			}
		}
		n++;

		// Animations run at the configured rate. A static pattern only
		// has to notice a config change, so it idles at 2 Hz.
		long period_ns = animated ? 1000000000L / (long)cfg.fps
					  : 1000000000L / IDLE_POLL_HZ;
		struct timespec ts = { .tv_sec = 0, .tv_nsec = period_ns };
		nanosleep(&ts, NULL);
	}

	// We leave the LEDs as they are on exit, so a restart repaints without
	// a visible gap. Use "nix-badge leds set --pattern off" to clear them on
	// purpose.
	close(fd);
	free(px);
	free(frame);
	return 0;
}

static int cmd_set(int argc, char **argv)
{
	struct config cfg;
	config_defaults(&cfg);
	// Start from whatever is already live so a partial change keeps the
	// rest.
	config_load(&cfg, RUNTIME_CONF, 0);

	int have_colors = 0;
	struct config incoming = cfg;

	for (int i = 0; i < argc; i++) {
		const char *a = argv[i];
		if (strcmp(a, "--pattern") == 0 && i + 1 < argc) {
			if (parse_pattern(argv[++i], &incoming.pattern) != 0)
				die("unknown pattern '%s'", argv[i]);
		} else if (strcmp(a, "--brightness") == 0 && i + 1 < argc) {
			unsigned n = (unsigned)strtoul(argv[++i], NULL, 10);
			incoming.brightness = n > 255 ? 255 : n;
		} else if (strcmp(a, "--speed-hz") == 0 && i + 1 < argc) {
			// The WS2812 bit time is 3 SPI bits, so this is the
			// timing knob. Sweep it to match the fitted part.
			unsigned n = (unsigned)strtoul(argv[++i], NULL, 10);
			if (n < 100000 || n > 20000000)
				die("speed-hz %u is out of range 100000-20000000",
				    n);
			incoming.speed_hz = n;
		} else if (strcmp(a, "--bits") == 0 && i + 1 < argc) {
			// 4 gives 0 -> 1000 and 1 -> 1110, a 25/75 split.
			// 3 gives 0 -> 100 and 1 -> 110, a 33/67 split with
			// much less margin.
			unsigned n = (unsigned)strtoul(argv[++i], NULL, 10);
			if (n != 3 && n != 4 && n != 8)
				die("bits must be 3, 4 or 8, got %u", n);
			incoming.bits = n;
		} else if (strcmp(a, "--fps") == 0 && i + 1 < argc) {
			// Lower fps means fewer frames per second, so fewer
			// chances for a corrupted one to be visible. A stopgap
			// for the transfer gaps, not a fix for them.
			unsigned n = (unsigned)strtoul(argv[++i], NULL, 10);
			if (n < 1 || n > 200)
				die("fps %u is out of range 1-200", n);
			incoming.fps = n;
		} else if (strcmp(a, "--count") == 0 && i + 1 < argc) {
			// Reloadable so a chain that only lights partway can be
			// bisected without a rebuild.
			unsigned n = (unsigned)strtoul(argv[++i], NULL, 10);
			if (n == 0 || n > MAX_LEDS)
				die("count %u is out of range 1-%u", n, MAX_LEDS);
			incoming.count = n;
		} else if (strcmp(a, "--color") == 0 && i + 1 < argc) {
			if (!have_colors) {
				incoming.ncolors = 0;
				have_colors = 1;
			}
			if (incoming.ncolors >= MAX_COLORS)
				die("at most %u colours", MAX_COLORS);
			if (parse_color(argv[++i],
					&incoming.colors[incoming.ncolors]) != 0)
				die("bad colour '%s'", argv[i]);
			incoming.ncolors++;
		} else {
			die("set: unknown argument '%s'", a);
		}
	}

	if (mkdir(RUNTIME_DIR, 0755) != 0 && errno != EEXIST)
		die("cannot create %s: %s", RUNTIME_DIR, strerror(errno));

	FILE *f = fopen(RUNTIME_CONF, "w");
	if (!f)
		die("cannot write %s: %s", RUNTIME_CONF, strerror(errno));
	fprintf(f, "# Written by nixbadge-leds set. The service reads this\n");
	fprintf(f, "# after the declarative config, so these values win.\n");
	fprintf(f, "pattern = %s\n", pattern_names[incoming.pattern]);
	fprintf(f, "brightness = %u\n", incoming.brightness);
	fprintf(f, "count = %u\n", incoming.count);
	fprintf(f, "fps = %u\n", incoming.fps);
	fprintf(f, "speed_hz = %u\n", incoming.speed_hz);
	fprintf(f, "bits = %u\n", incoming.bits);
	fprintf(f, "colors = ");
	for (unsigned i = 0; i < incoming.ncolors; i++)
		fprintf(f, "%s#%02x%02x%02x", i ? "," : "",
			incoming.colors[i].r, incoming.colors[i].g,
			incoming.colors[i].b);
	fprintf(f, "\n");
	fclose(f);

	// Nothing else to do. The running service watches this file and picks
	// the change up on its next tick, so we do not talk to systemd at all.
	printf("pattern = %s\n", pattern_names[incoming.pattern]);
	printf("brightness = %u\n", incoming.brightness);
	return 0;
}

static int cmd_show(void)
{
	struct config cfg;
	config_defaults(&cfg);
	config_load(&cfg, RUNTIME_CONF, 0);
	printf("pattern = %s\n", pattern_names[cfg.pattern]);
	printf("brightness = %u\n", cfg.brightness);
	printf("colors = ");
	for (unsigned i = 0; i < cfg.ncolors; i++)
		printf("%s#%02x%02x%02x", i ? "," : "", cfg.colors[i].r,
		       cfg.colors[i].g, cfg.colors[i].b);
	printf("\n");
	return 0;
}

// ============================================================ core select ===
//
// The badge picks its boot core with a 74AUP1G175 flip-flop (U2) on the
// always-on VRTC rail, so the choice survives a power cycle. The Duo S switch
// has an AUTO position, and in AUTO the latch decides.
//
//   core-sel-latch-d    D input,  1 = ARM, 0 = RISC-V on the next boot
//   core-sel-latch-clk  CP clock, a RISING edge captures D
//   core-sel-strap      readback, 1 = RISC-V, 0 = ARM (inverted from D)
//
// We drive this through the GPIO character-device uAPI rather than shelling
// out to gpioset, because gpioset only holds a line while its process lives
// and its --toggle flips every named line at once. Holding D steady while
// pulsing CP is not expressible in one invocation, and getting it wrong picks
// the wrong boot core.
//
// Lines are found BY NAME, using the gpio-line-names the device tree sets, so
// nothing here depends on chip numbering or line offsets.

#define LINE_LATCH_D "core-sel-latch-d"
#define LINE_LATCH_CLK "core-sel-latch-clk"
#define LINE_STRAP "core-sel-strap"

// Locate a named GPIO line. On success returns an open chip fd and stores the
// line offset. Returns -1 when no chip has that name.
static int gpio_find_line(const char *name, unsigned *offset)
{
	for (unsigned chip = 0; chip < 16; chip++) {
		char path[64];
		snprintf(path, sizeof(path), "/dev/gpiochip%u", chip);
		int fd = open(path, O_RDWR | O_CLOEXEC);
		if (fd < 0)
			continue;

		struct gpiochip_info ci;
		memset(&ci, 0, sizeof(ci));
		if (ioctl(fd, GPIO_GET_CHIPINFO_IOCTL, &ci) < 0) {
			close(fd);
			continue;
		}

		for (unsigned l = 0; l < ci.lines; l++) {
			struct gpio_v2_line_info li;
			memset(&li, 0, sizeof(li));
			li.offset = l;
			if (ioctl(fd, GPIO_V2_GET_LINEINFO_IOCTL, &li) < 0)
				continue;
			if (strcmp(li.name, name) == 0) {
				*offset = l;
				return fd;
			}
		}
		close(fd);
	}
	return -1;
}

// Read one named line as an input. Returns 0 or 1, or -1 on failure.
static int gpio_read_line(const char *name)
{
	unsigned off;
	int chip = gpio_find_line(name, &off);
	if (chip < 0)
		return -1;

	struct gpio_v2_line_request req;
	memset(&req, 0, sizeof(req));
	req.offsets[0] = off;
	req.num_lines = 1;
	req.config.flags = GPIO_V2_LINE_FLAG_INPUT;
	snprintf(req.consumer, sizeof(req.consumer), "nix-badge");

	int rc = ioctl(chip, GPIO_V2_GET_LINE_IOCTL, &req);
	close(chip);
	if (rc < 0 || req.fd < 0)
		return -1;

	struct gpio_v2_line_values vals;
	memset(&vals, 0, sizeof(vals));
	vals.mask = 1;
	rc = ioctl(req.fd, GPIO_V2_LINE_GET_VALUES_IOCTL, &vals);
	close(req.fd);
	if (rc < 0)
		return -1;
	return (int)(vals.bits & 1);
}

// Latch the boot core. d_value is 1 for ARM, 0 for RISC-V.
static int core_latch(unsigned d_value)
{
	unsigned d_off, clk_off;
	int chip_d = gpio_find_line(LINE_LATCH_D, &d_off);
	if (chip_d < 0)
		die("cannot find GPIO line '%s'. Is the device tree current?",
		    LINE_LATCH_D);
	unsigned probe;
	int chip_c = gpio_find_line(LINE_LATCH_CLK, &probe);
	if (chip_c < 0) {
		close(chip_d);
		die("cannot find GPIO line '%s'", LINE_LATCH_CLK);
	}
	close(chip_c);
	clk_off = probe;

	// Both lines must come from ONE request so they can be driven together
	// with a guaranteed order. Index 0 is D, index 1 is CP.
	struct gpio_v2_line_request req;
	memset(&req, 0, sizeof(req));
	req.offsets[0] = d_off;
	req.offsets[1] = clk_off;
	req.num_lines = 2;
	req.config.flags = GPIO_V2_LINE_FLAG_OUTPUT;
	snprintf(req.consumer, sizeof(req.consumer), "nix-badge core");

	// Start with D at the wanted value and CP low, so the rising edge we
	// make below is the only edge the flip-flop sees.
	req.config.num_attrs = 1;
	req.config.attrs[0].attr.id = GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES;
	req.config.attrs[0].attr.values = d_value ? 1u : 0u;
	req.config.attrs[0].mask = 0x3;

	if (ioctl(chip_d, GPIO_V2_GET_LINE_IOCTL, &req) < 0) {
		int e = errno;
		close(chip_d);
		die("cannot claim the core-select lines: %s", strerror(e));
	}
	close(chip_d);

	struct timespec settle = { .tv_sec = 0, .tv_nsec = 1000000 }; // 1 ms
	nanosleep(&settle, NULL);

	// Rising edge on CP captures D.
	struct gpio_v2_line_values vals;
	memset(&vals, 0, sizeof(vals));
	vals.mask = 0x3;
	vals.bits = (d_value ? 1u : 0u) | 0x2u;
	if (ioctl(req.fd, GPIO_V2_LINE_SET_VALUES_IOCTL, &vals) < 0) {
		int e = errno;
		close(req.fd);
		die("cannot pulse the latch clock: %s", strerror(e));
	}
	nanosleep(&settle, NULL);

	// Return CP low. The value is already captured.
	vals.bits = d_value ? 1u : 0u;
	ioctl(req.fd, GPIO_V2_LINE_SET_VALUES_IOCTL, &vals);
	nanosleep(&settle, NULL);
	close(req.fd);
	return 0;
}

static void core_report_strap(void)
{
	int strap = gpio_read_line(LINE_STRAP);
	if (strap < 0) {
		printf("strap readback: unavailable\n");
		return;
	}
	// The strap is inverted from D: 1 means RISC-V.
	printf("strap readback: %d (%s)\n", strap, strap ? "riscv" : "arm");
}

static int cmd_core(int argc, char **argv)
{
	if (argc < 1) {
		fprintf(stderr, "usage: nix-badge core <arm|riscv|status>\n");
		return 2;
	}

	if (strcmp(argv[0], "status") == 0) {
		core_report_strap();
		return 0;
	}

	unsigned d_value;
	if (strcmp(argv[0], "arm") == 0)
		d_value = 1;
	else if (strcmp(argv[0], "riscv") == 0)
		d_value = 0;
	else {
		fprintf(stderr, "core: expected arm, riscv or status\n");
		return 2;
	}

	core_latch(d_value);
	printf("core-select latch set to %s\n", argv[0]);
	core_report_strap();
	printf("\n");
	printf("The latch only chooses which boot chain runs. Also swap the\n");
	printf("firmware so U-Boot loads the matching kernel:\n");
	printf("    swap-core %s\n", argv[0]);
	printf("Then reboot, with the board switch in AUTO.\n");
	return 0;
}

// ================================================================== power ===
//
// Rail voltages from the cv1800b SARADC (read over IIO sysfs) plus the USB
// VBUS-detect and per-supply fault GPIOs. Each ADC channel is fed through a
// 2.2M/1M divider (x3.2), and the driver reports in_voltage_scale in mV per LSB,
// so a rail is raw * scale * 3.2. Channel map (see the shared dtsi &saradc):
//   in_voltage0 = VSEL  (system rail, = VBUS through the TPS2116 mux on USB power)
//   in_voltage1 = VBAT  (battery)
//   in_voltage2 = J6    (external test point)
// VBUS-detect and the active-low *-fault-n lines are read by name via the same
// GPIO uAPI helper the core latch uses (gpio_read_line).

// The 2.2M/1M dividers present a ~688k source, far too high for the cv1800b
// SARADC's ~640 ns sample window to settle, so every reading is attenuated by a
// roughly fixed fraction (the cap charges to ~1/6). The correction is therefore an
// empirically calibrated factor, not the ideal x3.2. Calibrated 2026-08-26 against
// a multimeter: VSEL = 4.980 V at a median raw of 320 (scale 0.805664 mV/LSB) ->
// 4980 / (320 * 0.805664) = 19.3. VSEL and VBAT share the divider, so they share
// the factor. This constant is per-badge (divider tolerance + ADC sample cap); a
// kernel patch slowing the ADC clock (CLKDIV) would make it board-independent.
//
// Overridable at build time (-DSARADC_FACTOR=...) through saradcFactor in
// nix-badge.nix, so re-calibrating after a kernel ADC-sampling change (e.g. a
// slower CLKDIV that lets the divider settle) is a nix one-liner, not a C edit.
#ifndef SARADC_FACTOR
#define SARADC_FACTOR 19.3
#endif

// Locate the SARADC IIO device directory (its driver name contains "adc").
static int saradc_dir(char *dir, size_t dirlen)
{
	for (int i = 0; i < 16; i++) {
		char base[64], namepath[96], name[64];
		snprintf(base, sizeof(base),
			 "/sys/bus/iio/devices/iio:device%d", i);
		snprintf(namepath, sizeof(namepath), "%s/name", base);
		FILE *f = fopen(namepath, "r");
		if (!f)
			continue;
		int ok = fgets(name, sizeof(name), f) && strstr(name, "adc");
		fclose(f);
		if (ok) {
			snprintf(dir, dirlen, "%s", base);
			return 0;
		}
	}
	return -1;
}

// Read a sysfs file as a double. Returns 0 on success.
static int read_sysfs_double(const char *path, double *out)
{
	FILE *f = fopen(path, "r");
	if (!f)
		return -1;
	int ok = fscanf(f, "%lf", out) == 1;
	fclose(f);
	return ok ? 0 : -1;
}

// The rail correction factor, runtime-overridable. A positive decimal in
// /var/lib/nix-badge/saradc-factor wins over the compile-time SARADC_FACTOR, so
// re-calibrating (e.g. after a CLKDIV change that settles the divider further) is
// a file write that takes effect on the next `nix-badge power`, with no rebuild.
static double saradc_factor(void)
{
	double f;
	if (read_sysfs_double("/var/lib/nix-badge/saradc-factor", &f) == 0 &&
	    f > 0.0)
		return f;
	return SARADC_FACTOR;
}

static int cmp_int(const void *a, const void *b)
{
	int x = *(const int *)a, y = *(const int *)b;
	return (x > y) - (x < y);
}

// Read one SARADC channel N times and return the median raw count. The high-Z
// divider makes single reads jitter by tens of counts and occasionally return a
// badly-undersettled sample; the median rejects those.
static int saradc_median_raw(const char *dir, int ch)
{
	/* 65, not 25: the leaky high-Z divider makes the per-read raw jitter ~+/-20%,
	 * so a 25-sample median still wobbles a few counts run-to-run (~2.5% on the
	 * reported volts). More samples tighten the median; a read is only a few us. */
	enum { NSAMP = 65 };
	int s[NSAMP], n = 0;
	char rp[96];
	snprintf(rp, sizeof(rp), "%s/in_voltage%d_raw", dir, ch);
	for (int i = 0; i < NSAMP; i++) {
		double v;
		if (read_sysfs_double(rp, &v) == 0)
			s[n++] = (int)v;
	}
	if (n == 0)
		return -1;
	qsort(s, n, sizeof(s[0]), cmp_int);
	return s[n / 2];
}

// Auto-calibrate the rail factor against the known ~5V USB VBUS. When power is
// plugged, VSEL is the 5V USB rail through the TPS2116 mux -- a roughly known
// quantity -- so with VBUS detected we pin factor = 5000mV / (VSEL_raw * scale),
// absorbing this badge's divider tolerance and ADC leakage without a per-badge
// DMM step. VSEL and VBAT share the divider, so the same factor calibrates the
// battery read. No-op (keeps the stored factor) when VBUS is absent: on battery
// there is no known reference, so the last USB-calibrated factor is reused.
#define SARADC_VBUS_NOMINAL_MV 5000.0
static int saradc_calibrate(void)
{
	int vbus = gpio_read_line("usb-vbus-det");
	if (vbus != 1) {
		fprintf(stderr, "calibrate: USB VBUS %s; no 5V reference, "
				"factor unchanged\n",
			vbus < 0 ? "unknown" : "absent");
		return 1;
	}
	char dir[64], sp[96];
	double scale;
	if (saradc_dir(dir, sizeof(dir)) != 0) {
		fprintf(stderr, "calibrate: no SARADC device\n");
		return 1;
	}
	snprintf(sp, sizeof(sp), "%s/in_voltage_scale", dir);
	if (read_sysfs_double(sp, &scale) != 0) {
		fprintf(stderr, "calibrate: cannot read %s\n", sp);
		return 1;
	}
	int raw = saradc_median_raw(dir, 0); // VSEL is channel 0
	if (raw <= 0) {
		fprintf(stderr, "calibrate: bad VSEL raw (%d)\n", raw);
		return 1;
	}
	double factor = SARADC_VBUS_NOMINAL_MV / (raw * scale);
	FILE *f = fopen("/var/lib/nix-badge/saradc-factor", "w");
	if (!f) {
		perror("calibrate: /var/lib/nix-badge/saradc-factor");
		return 1;
	}
	fprintf(f, "%.4f\n", factor);
	fclose(f);
	printf("calibrated: VSEL raw %d @ %.0f mV VBUS -> factor %.4f\n", raw,
	       SARADC_VBUS_NOMINAL_MV, factor);
	return 0;
}

static int cmd_power(int argc, char **argv)
{
	if (argc >= 1 && strcmp(argv[0], "calibrate") == 0)
		return saradc_calibrate();
	(void)argc;
	(void)argv;

	char dir[64];
	if (saradc_dir(dir, sizeof(dir)) == 0) {
		char sp[96];
		double scale;
		snprintf(sp, sizeof(sp), "%s/in_voltage_scale", dir);
		if (read_sysfs_double(sp, &scale) == 0) {
			static const struct {
				int ch;
				const char *label;
			} rails[] = {
				{ 0, "VSEL (system / VBUS):" },
				{ 1, "VBAT (battery):      " },
				{ 2, "J6   (ext ADC):      " },
			};
			for (size_t i = 0; i < 3; i++) {
				int raw = saradc_median_raw(dir, rails[i].ch);
				if (raw >= 0)
					printf("%s %.3f V\n", rails[i].label,
					       raw * scale * saradc_factor() /
						       1000.0);
				else
					printf("%s (read error)\n",
					       rails[i].label);
			}
		} else {
			fprintf(stderr, "power: cannot read %s\n", sp);
		}
	} else {
		fprintf(stderr, "power: no SARADC IIO device "
				"(is &saradc enabled and booted?)\n");
	}

	int vbus = gpio_read_line("usb-vbus-det");
	printf("USB VBUS present:     %s\n",
	       vbus < 0 ? "unknown" : (vbus ? "yes" : "no"));

	// Active-low fault lines (TPS2553 open-drain /FAULT): low means asserted.
	static const struct {
		const char *label;
		const char *line;
	} faults[] = {
		{ "usb-5v:", "usb-5v-fault-n" },
		{ "hdmi-5v:", "hdmi-5v-fault-n" },
		{ "sd:", "sd-fault-n" },
		{ "sao:", "sao-fault-n" },
	};
	printf("Faults:\n");
	for (size_t i = 0; i < 4; i++) {
		int v = gpio_read_line(faults[i].line);
		printf("  %-8s %s\n", faults[i].label,
		       v < 0 ? "unknown" : (v ? "ok" : "FAULT"));
	}
	return 0;
}

// =================================================================== main ===

static void usage(void)
{
	fprintf(stderr,
		"usage:\n"
		"  nix-badge leds run --config FILE\n"
		"  nix-badge leds set [--pattern P] [--brightness 0-255] "
		"[--count N] [--speed-hz HZ] [--bits 3|4|8] [--fps N]\n"
		"        [--color '#rrggbb' ...]\n"
		"  nix-badge leds show\n"
		"  nix-badge core <arm|riscv|status>\n"
		"  nix-badge power [calibrate]\n"
		"\n"
		"patterns: off solid pulse rainbow chase\n");
}

static int cmd_leds(int argc, char **argv)
{
	if (argc < 1) {
		usage();
		return 2;
	}
	if (strcmp(argv[0], "run") == 0)
		return cmd_run(argc - 1, argv + 1);
	if (strcmp(argv[0], "set") == 0)
		return cmd_set(argc - 1, argv + 1);
	if (strcmp(argv[0], "show") == 0)
		return cmd_show();
	usage();
	return 2;
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		usage();
		return 2;
	}
	if (strcmp(argv[1], "leds") == 0)
		return cmd_leds(argc - 2, argv + 2);
	if (strcmp(argv[1], "core") == 0)
		return cmd_core(argc - 2, argv + 2);
	if (strcmp(argv[1], "power") == 0)
		return cmd_power(argc - 2, argv + 2);
	usage();
	return 2;
}
