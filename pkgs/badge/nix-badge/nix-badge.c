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
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <linux/gpio.h>
#include <linux/i2c-dev.h>
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
// The observed VBUS at VSEL is ~4.96V, not a clean 5.00V -- a small drop through
// the power tree from the USB rail -- so calibrate to that measured value.
#define SARADC_VBUS_NOMINAL_MV 4960.0
#define SARADC_FACTOR_FILE "/var/lib/nix-badge/saradc-factor"
static int saradc_calibrate(int force, int quiet)
{
	// Calibrate once per badge: if a factor was already stored, keep it unless
	// forced. So this can run on EVERY voltage read and only acts the first time
	// it gets the chance (VBUS plugged and not yet calibrated). quiet suppresses
	// the chatter when it runs opportunistically from inside `power`.
	if (!force && access(SARADC_FACTOR_FILE, F_OK) == 0) {
		if (!quiet) {
			double cur = 0;
			read_sysfs_double(SARADC_FACTOR_FILE, &cur);
			printf("calibrate: already calibrated (factor %.4f); "
			       "use --force to redo\n",
			       cur);
		}
		return 0;
	}
	int vbus = gpio_read_line("usb-vbus-det");
	if (vbus != 1) {
		if (!quiet)
			fprintf(stderr, "calibrate: USB VBUS %s; no reference "
					"yet, will calibrate when power is "
					"plugged\n",
				vbus < 0 ? "unknown" : "absent");
		return 1;
	}
	char dir[64], sp[96];
	double scale;
	if (saradc_dir(dir, sizeof(dir)) != 0) {
		if (!quiet)
			fprintf(stderr, "calibrate: no SARADC device\n");
		return 1;
	}
	snprintf(sp, sizeof(sp), "%s/in_voltage_scale", dir);
	if (read_sysfs_double(sp, &scale) != 0) {
		if (!quiet)
			fprintf(stderr, "calibrate: cannot read %s\n", sp);
		return 1;
	}
	int raw = saradc_median_raw(dir, 0); // VSEL is channel 0
	if (raw <= 0) {
		if (!quiet)
			fprintf(stderr, "calibrate: bad VSEL raw (%d)\n", raw);
		return 1;
	}
	double factor = SARADC_VBUS_NOMINAL_MV / (raw * scale);
	FILE *f = fopen(SARADC_FACTOR_FILE, "w");
	if (!f) {
		if (!quiet)
			perror("calibrate: " SARADC_FACTOR_FILE);
		return 1;
	}
	fprintf(f, "%.4f\n", factor);
	fclose(f);
	if (!quiet)
		printf("calibrated: VSEL raw %d @ %.0f mV VBUS -> factor %.4f\n",
		       raw, SARADC_VBUS_NOMINAL_MV, factor);
	return 0;
}

static int cmd_power(int argc, char **argv)
{
	if (argc >= 1 && strcmp(argv[0], "calibrate") == 0) {
		int force = argc >= 2 && strcmp(argv[1], "--force") == 0;
		return saradc_calibrate(force, 0);
	}
	(void)argc;
	(void)argv;

	// Opportunistic auto-cal: if this badge has never been calibrated and USB
	// VBUS is available right now, calibrate before reading so we report the real
	// per-badge factor. No-op once calibrated or on battery; quiet so it does not
	// clutter the reading. The OLED meter reuses this path, so it self-calibrates.
	saradc_calibrate(0, 1);

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

// ==================================================================== oled ===
//
// A 128x32 SSD1306 monochrome OLED on I2C bus 1 at address 0x3c, driven through
// the Linux i2c-dev userspace interface. `nix-badge oled run` is a foreground
// systemd service: it renders a small status HUD to a static 512-byte
// framebuffer and pushes it over I2C at ~12 fps, cycling between views on the
// USER button. The rail/battery numbers reuse the SARADC + GPIO helpers that
// `power` uses, so the meter self-calibrates off VBUS the same way.
//
// SSD1306 I2C framing: every message begins with a control byte. 0x00 says the
// bytes that follow are COMMANDS, 0x40 says they are DISPLAY DATA (GDDRAM). We
// keep the two streams separate: init/config goes out as command frames, the
// framebuffer flush goes out as one data frame.
//
// The panel is organised as 4 pages of 128 columns. A page is 8 vertically
// stacked pixels sharing a column byte, LSB on top. So a pixel at (x,y) lives in
// page y/8, column x, at bit y%8 of that byte -- which is exactly how set_pixel
// indexes the framebuffer, and why the buffer streams straight to GDDRAM with no
// reshuffle once we select horizontal/page addressing over the whole panel.

#define OLED_I2C_BUS "/dev/i2c-1"
#define OLED_I2C_ADDR 0x3c
#define OLED_W 128
#define OLED_H 32
#define OLED_PAGES (OLED_H / 8) // 4
#define OLED_FBLEN (OLED_W * OLED_PAGES) // 512

// SSD1306 command bytes we use.
#define SSD1306_SETCONTRAST 0x81
#define SSD1306_DISPLAYALLON_RESUME 0xa4
#define SSD1306_NORMALDISPLAY 0xa6
#define SSD1306_DISPLAYOFF 0xae
#define SSD1306_DISPLAYON 0xaf
#define SSD1306_SETDISPLAYOFFSET 0xd3
#define SSD1306_SETCOMPINS 0xda
#define SSD1306_SETVCOMDETECT 0xdb
#define SSD1306_SETDISPLAYCLOCKDIV 0xd5
#define SSD1306_SETPRECHARGE 0xd9
#define SSD1306_SETMULTIPLEX 0xa8
#define SSD1306_SETLOWCOLUMN 0x00
#define SSD1306_SETHIGHCOLUMN 0x10
#define SSD1306_SETSTARTLINE 0x40
#define SSD1306_MEMORYMODE 0x20
#define SSD1306_COLUMNADDR 0x21
#define SSD1306_PAGEADDR 0x22
#define SSD1306_COMSCANDEC 0xc8
#define SSD1306_SEGREMAP 0xa1
#define SSD1306_CHARGEPUMP 0x8d

// The framebuffer. Static so set_pixel/oled_flush can reach it without threading
// a pointer through every draw helper, and so the working set is one 512-byte
// blob the compiler can keep hot.
static uint8_t oled_fb[OLED_FBLEN];

// ------------------------------------------------------------- oled: font ---
//
// A compact 5x7 ASCII font, one glyph per 5 bytes, each byte a COLUMN (LSB =
// top pixel, matching the panel's page layout). Rendered with a 1px gap so cells
// are 6px wide. Coverage: space, digits 0-9, A-Z, a-z, and the punctuation the
// HUD needs ('.', '%', ':', '-', 'V' is already a letter). Anything outside the
// covered range draws as blank. This is the classic 5x7 "font5x7" column table
// trimmed to the glyphs we use; unsupported codepoints map to space.

#define FONT_W 5
#define FONT_H 7
#define GLYPH_W (FONT_W + 1) // 6px cell incl. the 1px inter-char gap

// One glyph = 5 column bytes. Index by ASCII value minus 0x20 (space).
static const uint8_t oled_font[][FONT_W] = {
	{ 0x00, 0x00, 0x00, 0x00, 0x00 }, // 0x20 space
	{ 0x00, 0x00, 0x5f, 0x00, 0x00 }, // 0x21 !
	{ 0x00, 0x07, 0x00, 0x07, 0x00 }, // 0x22 "
	{ 0x14, 0x7f, 0x14, 0x7f, 0x14 }, // 0x23 #
	{ 0x24, 0x2a, 0x7f, 0x2a, 0x12 }, // 0x24 $
	{ 0x23, 0x13, 0x08, 0x64, 0x62 }, // 0x25 %
	{ 0x36, 0x49, 0x55, 0x22, 0x50 }, // 0x26 &
	{ 0x00, 0x05, 0x03, 0x00, 0x00 }, // 0x27 '
	{ 0x00, 0x1c, 0x22, 0x41, 0x00 }, // 0x28 (
	{ 0x00, 0x41, 0x22, 0x1c, 0x00 }, // 0x29 )
	{ 0x14, 0x08, 0x3e, 0x08, 0x14 }, // 0x2a *
	{ 0x08, 0x08, 0x3e, 0x08, 0x08 }, // 0x2b +
	{ 0x00, 0x50, 0x30, 0x00, 0x00 }, // 0x2c ,
	{ 0x08, 0x08, 0x08, 0x08, 0x08 }, // 0x2d -
	{ 0x00, 0x60, 0x60, 0x00, 0x00 }, // 0x2e .
	{ 0x20, 0x10, 0x08, 0x04, 0x02 }, // 0x2f /
	{ 0x3e, 0x51, 0x49, 0x45, 0x3e }, // 0x30 0
	{ 0x00, 0x42, 0x7f, 0x40, 0x00 }, // 0x31 1
	{ 0x42, 0x61, 0x51, 0x49, 0x46 }, // 0x32 2
	{ 0x21, 0x41, 0x45, 0x4b, 0x31 }, // 0x33 3
	{ 0x18, 0x14, 0x12, 0x7f, 0x10 }, // 0x34 4
	{ 0x27, 0x45, 0x45, 0x45, 0x39 }, // 0x35 5
	{ 0x3c, 0x4a, 0x49, 0x49, 0x30 }, // 0x36 6
	{ 0x01, 0x71, 0x09, 0x05, 0x03 }, // 0x37 7
	{ 0x36, 0x49, 0x49, 0x49, 0x36 }, // 0x38 8
	{ 0x06, 0x49, 0x49, 0x29, 0x1e }, // 0x39 9
	{ 0x00, 0x36, 0x36, 0x00, 0x00 }, // 0x3a :
	{ 0x00, 0x56, 0x36, 0x00, 0x00 }, // 0x3b ;
	{ 0x08, 0x14, 0x22, 0x41, 0x00 }, // 0x3c <
	{ 0x14, 0x14, 0x14, 0x14, 0x14 }, // 0x3d =
	{ 0x00, 0x41, 0x22, 0x14, 0x08 }, // 0x3e >
	{ 0x02, 0x01, 0x51, 0x09, 0x06 }, // 0x3f ?
	{ 0x32, 0x49, 0x79, 0x41, 0x3e }, // 0x40 @
	{ 0x7e, 0x11, 0x11, 0x11, 0x7e }, // 0x41 A
	{ 0x7f, 0x49, 0x49, 0x49, 0x36 }, // 0x42 B
	{ 0x3e, 0x41, 0x41, 0x41, 0x22 }, // 0x43 C
	{ 0x7f, 0x41, 0x41, 0x22, 0x1c }, // 0x44 D
	{ 0x7f, 0x49, 0x49, 0x49, 0x41 }, // 0x45 E
	{ 0x7f, 0x09, 0x09, 0x09, 0x01 }, // 0x46 F
	{ 0x3e, 0x41, 0x49, 0x49, 0x7a }, // 0x47 G
	{ 0x7f, 0x08, 0x08, 0x08, 0x7f }, // 0x48 H
	{ 0x00, 0x41, 0x7f, 0x41, 0x00 }, // 0x49 I
	{ 0x20, 0x40, 0x41, 0x3f, 0x01 }, // 0x4a J
	{ 0x7f, 0x08, 0x14, 0x22, 0x41 }, // 0x4b K
	{ 0x7f, 0x40, 0x40, 0x40, 0x40 }, // 0x4c L
	{ 0x7f, 0x02, 0x0c, 0x02, 0x7f }, // 0x4d M
	{ 0x7f, 0x04, 0x08, 0x10, 0x7f }, // 0x4e N
	{ 0x3e, 0x41, 0x41, 0x41, 0x3e }, // 0x4f O
	{ 0x7f, 0x09, 0x09, 0x09, 0x06 }, // 0x50 P
	{ 0x3e, 0x41, 0x51, 0x21, 0x5e }, // 0x51 Q
	{ 0x7f, 0x09, 0x19, 0x29, 0x46 }, // 0x52 R
	{ 0x46, 0x49, 0x49, 0x49, 0x31 }, // 0x53 S
	{ 0x01, 0x01, 0x7f, 0x01, 0x01 }, // 0x54 T
	{ 0x3f, 0x40, 0x40, 0x40, 0x3f }, // 0x55 U
	{ 0x1f, 0x20, 0x40, 0x20, 0x1f }, // 0x56 V
	{ 0x3f, 0x40, 0x38, 0x40, 0x3f }, // 0x57 W
	{ 0x63, 0x14, 0x08, 0x14, 0x63 }, // 0x58 X
	{ 0x07, 0x08, 0x70, 0x08, 0x07 }, // 0x59 Y
	{ 0x61, 0x51, 0x49, 0x45, 0x43 }, // 0x5a Z
	{ 0x00, 0x7f, 0x41, 0x41, 0x00 }, // 0x5b [
	{ 0x02, 0x04, 0x08, 0x10, 0x20 }, // 0x5c backslash
	{ 0x00, 0x41, 0x41, 0x7f, 0x00 }, // 0x5d ]
	{ 0x04, 0x02, 0x01, 0x02, 0x04 }, // 0x5e ^
	{ 0x40, 0x40, 0x40, 0x40, 0x40 }, // 0x5f _
	{ 0x00, 0x01, 0x02, 0x04, 0x00 }, // 0x60 `
	{ 0x20, 0x54, 0x54, 0x54, 0x78 }, // 0x61 a
	{ 0x7f, 0x48, 0x44, 0x44, 0x38 }, // 0x62 b
	{ 0x38, 0x44, 0x44, 0x44, 0x20 }, // 0x63 c
	{ 0x38, 0x44, 0x44, 0x48, 0x7f }, // 0x64 d
	{ 0x38, 0x54, 0x54, 0x54, 0x18 }, // 0x65 e
	{ 0x08, 0x7e, 0x09, 0x01, 0x02 }, // 0x66 f
	{ 0x0c, 0x52, 0x52, 0x52, 0x3e }, // 0x67 g
	{ 0x7f, 0x08, 0x04, 0x04, 0x78 }, // 0x68 h
	{ 0x00, 0x44, 0x7d, 0x40, 0x00 }, // 0x69 i
	{ 0x20, 0x40, 0x44, 0x3d, 0x00 }, // 0x6a j
	{ 0x7f, 0x10, 0x28, 0x44, 0x00 }, // 0x6b k
	{ 0x00, 0x41, 0x7f, 0x40, 0x00 }, // 0x6c l
	{ 0x7c, 0x04, 0x18, 0x04, 0x78 }, // 0x6d m
	{ 0x7c, 0x08, 0x04, 0x04, 0x78 }, // 0x6e n
	{ 0x38, 0x44, 0x44, 0x44, 0x38 }, // 0x6f o
	{ 0x7c, 0x14, 0x14, 0x14, 0x08 }, // 0x70 p
	{ 0x08, 0x14, 0x14, 0x18, 0x7c }, // 0x71 q
	{ 0x7c, 0x08, 0x04, 0x04, 0x08 }, // 0x72 r
	{ 0x48, 0x54, 0x54, 0x54, 0x20 }, // 0x73 s
	{ 0x04, 0x3f, 0x44, 0x40, 0x20 }, // 0x74 t
	{ 0x3c, 0x40, 0x40, 0x20, 0x7c }, // 0x75 u
	{ 0x1c, 0x20, 0x40, 0x20, 0x1c }, // 0x76 v
	{ 0x3c, 0x40, 0x30, 0x40, 0x3c }, // 0x77 w
	{ 0x44, 0x28, 0x10, 0x28, 0x44 }, // 0x78 x
	{ 0x0c, 0x50, 0x50, 0x50, 0x3c }, // 0x79 y
	{ 0x44, 0x64, 0x54, 0x4c, 0x44 }, // 0x7a z
};

// Highest ASCII code the table covers (0x7a = 'z').
#define FONT_LAST 0x7a

// ------------------------------------------------------- oled: framebuffer ---

// Set or clear one pixel. Off-screen coordinates are dropped so callers never
// have to clip. page = y/8, bit = y%8, matching the SSD1306 GDDRAM layout.
static void set_pixel(int x, int y, int on)
{
	if (x < 0 || x >= OLED_W || y < 0 || y >= OLED_H)
		return;
	uint8_t *cell = &oled_fb[(y / 8) * OLED_W + x];
	uint8_t bit = (uint8_t)(1u << (y % 8));
	if (on)
		*cell |= bit;
	else
		*cell &= (uint8_t)~bit;
}

static void oled_clear(void)
{
	memset(oled_fb, 0, sizeof(oled_fb));
}

// Draw one glyph at (x,y), y being the top pixel row. Returns nothing; callers
// step x by GLYPH_W. Codepoints outside the covered range render as a blank
// cell, so a stray byte never smears the display.
static void oled_draw_char(int x, int y, char ch)
{
	unsigned c = (unsigned char)ch;
	if (c < 0x20 || c > FONT_LAST)
		c = 0x20; // space for anything we do not carry
	const uint8_t *g = oled_font[c - 0x20];
	for (int col = 0; col < FONT_W; col++) {
		uint8_t bits = g[col];
		for (int row = 0; row < FONT_H; row++)
			if (bits & (1u << row))
				set_pixel(x + col, y + row, 1);
	}
}

// Draw a NUL-terminated string. Characters are laid out left to right with the
// 1px inter-char gap baked into GLYPH_W; drawing stops at the right edge.
static void oled_draw_text(int x, int y, const char *s)
{
	for (; *s; s++) {
		if (x >= OLED_W)
			break;
		oled_draw_char(x, y, *s);
		x += GLYPH_W;
	}
}

// Draw a "big" (2x scaled) string for the hero number on the battery view. Each
// source pixel becomes a 2x2 block, so glyphs are 10px wide + 2px gap = 12px.
static void oled_draw_text_2x(int x, int y, const char *s)
{
	for (; *s; s++) {
		if (x >= OLED_W)
			break;
		unsigned c = (unsigned char)*s;
		if (c < 0x20 || c > FONT_LAST)
			c = 0x20;
		const uint8_t *g = oled_font[c - 0x20];
		for (int col = 0; col < FONT_W; col++) {
			uint8_t bits = g[col];
			for (int row = 0; row < FONT_H; row++) {
				if (!(bits & (1u << row)))
					continue;
				int px = x + col * 2;
				int py = y + row * 2;
				set_pixel(px, py, 1);
				set_pixel(px + 1, py, 1);
				set_pixel(px, py + 1, 1);
				set_pixel(px + 1, py + 1, 1);
			}
		}
		x += 2 * GLYPH_W;
	}
}

// A horizontal bar: a hollow rectangle w x h at (x,y) with the leftmost
// frac (0..1) of its interior filled. Clamped so out-of-range fractions saturate
// rather than overrun. Handy for a battery/CPU/mem gauge.
static void oled_draw_hbar(int x, int y, int w, int h, double frac)
{
	if (w < 2 || h < 2)
		return;
	if (frac < 0.0)
		frac = 0.0;
	if (frac > 1.0)
		frac = 1.0;

	// Border.
	for (int i = 0; i < w; i++) {
		set_pixel(x + i, y, 1);
		set_pixel(x + i, y + h - 1, 1);
	}
	for (int j = 0; j < h; j++) {
		set_pixel(x, y + j, 1);
		set_pixel(x + w - 1, y + j, 1);
	}

	// Fill. The interior is (w-2) x (h-2), inset by the 1px border.
	int inner = w - 2;
	int fill = (int)(inner * frac + 0.5);
	for (int i = 0; i < fill; i++)
		for (int j = 1; j < h - 1; j++)
			set_pixel(x + 1 + i, y + j, 1);
}

// -------------------------------------------------------------- oled: i2c ---

// Open the I2C bus and bind to the SSD1306's slave address. Returns an fd, or -1
// with a message on stderr. The bus node is created by the DTS enabling i2c1; it
// may not exist on a core that does not mux it, which is not fatal for the tool.
static int oled_open(void)
{
	int fd = open(OLED_I2C_BUS, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "nix-badge: cannot open %s: %s\n", OLED_I2C_BUS,
			strerror(errno));
		return -1;
	}
	if (ioctl(fd, I2C_SLAVE, OLED_I2C_ADDR) < 0) {
		fprintf(stderr, "nix-badge: cannot select I2C addr 0x%02x: %s\n",
			OLED_I2C_ADDR, strerror(errno));
		close(fd);
		return -1;
	}
	return fd;
}

// Send a run of command bytes as one control(0x00)+payload frame. Returns 0 on
// success. The SSD1306 accepts a whole command list after a single 0x00 control
// byte, so init is a handful of writes rather than one per command.
static int oled_cmds(int fd, const uint8_t *cmds, size_t n)
{
	uint8_t buf[64];
	if (n + 1 > sizeof(buf))
		return -1; // our init lists are short; keep the stack frame tiny
	buf[0] = 0x00; // Co=0, D/C#=0 -> command stream
	memcpy(buf + 1, cmds, n);
	ssize_t w = write(fd, buf, n + 1);
	return (w == (ssize_t)(n + 1)) ? 0 : -1;
}

static int oled_cmd1(int fd, uint8_t c)
{
	return oled_cmds(fd, &c, 1);
}

// Push the whole 512-byte framebuffer to GDDRAM. We first point the column and
// page address windows at the full 128x32 panel (horizontal addressing mode set
// in init auto-advances across it), then stream the buffer behind a single 0x40
// control byte. One 513-byte write is well under the i2c-dev per-transfer limit.
static int oled_flush(int fd)
{
	uint8_t win[] = {
		SSD1306_COLUMNADDR, 0, OLED_W - 1,	  // columns 0..127
		SSD1306_PAGEADDR,   0, OLED_PAGES - 1,	  // pages 0..3
	};
	if (oled_cmds(fd, win, sizeof(win)) != 0)
		return -1;

	uint8_t buf[1 + OLED_FBLEN];
	buf[0] = 0x40; // Co=0, D/C#=1 -> data stream
	memcpy(buf + 1, oled_fb, OLED_FBLEN);
	ssize_t w = write(fd, buf, sizeof(buf));
	return (w == (ssize_t)sizeof(buf)) ? 0 : -1;
}

// The SSD1306 power-on / config sequence for a 128x32 panel. This is the classic
// Adafruit init tuned for the 32-row geometry: multiplex 0x1f (32 rows), COM
// pins 0x02 (sequential, no remap, right for 128x32), charge pump on, horizontal
// addressing mode, segment remap + reversed COM scan so (0,0) is top-left in the
// usual orientation. Returns 0 on success.
static int oled_init(int fd)
{
	static const uint8_t init[] = {
		SSD1306_DISPLAYOFF,
		SSD1306_SETDISPLAYCLOCKDIV, 0x80,	// default ratio / osc freq
		SSD1306_SETMULTIPLEX, 0x1f,		// 32 rows (MUX = height-1)
		SSD1306_SETDISPLAYOFFSET, 0x00,
		SSD1306_SETSTARTLINE | 0x00,
		SSD1306_CHARGEPUMP, 0x14,		// internal charge pump on
		SSD1306_MEMORYMODE, 0x00,		// horizontal addressing
		SSD1306_SEGREMAP,			// col 127 -> SEG0
		SSD1306_COMSCANDEC,			// scan COM[N-1]..COM0
		SSD1306_SETCOMPINS, 0x02,		// 128x32 COM pin layout
		SSD1306_SETCONTRAST, 0x8f,
		SSD1306_SETPRECHARGE, 0xf1,		// charge-pump precharge
		SSD1306_SETVCOMDETECT, 0x40,
		SSD1306_DISPLAYALLON_RESUME,		// follow GDDRAM, not all-on
		SSD1306_NORMALDISPLAY,			// non-inverted
		SSD1306_DISPLAYON,
	};
	// The init list is longer than one oled_cmds frame is sized for, and some
	// panels dislike a giant command burst, so send it a few bytes at a time.
	for (size_t i = 0; i < sizeof(init); i += 8) {
		size_t chunk = sizeof(init) - i;
		if (chunk > 8)
			chunk = 8;
		if (oled_cmds(fd, init + i, chunk) != 0)
			return -1;
	}
	return 0;
}

// ------------------------------------------------------------ oled: sensors ---
//
// Small readers for the "load" view, kept local to the oled section. Each is
// tolerant of a missing/garbled /proc file: on failure it leaves the out-params
// at whatever the caller pre-seeded, so a transient read error just repeats the
// last value rather than blanking the HUD.

// 1/5/15-minute load averages from /proc/loadavg.
static void read_loadavg(double *l1, double *l5, double *l15)
{
	FILE *f = fopen("/proc/loadavg", "r");
	if (!f)
		return;
	double a = 0, b = 0, c = 0;
	if (fscanf(f, "%lf %lf %lf", &a, &b, &c) == 3) {
		*l1 = a;
		*l5 = b;
		*l15 = c;
	}
	fclose(f);
}

// Aggregate CPU jiffies from the first "cpu" line of /proc/stat, split into
// "busy" (user+nice+system+irq+softirq+steal) and "idle" (idle+iowait). The
// caller diffs two samples to get a utilisation fraction; a single reading is
// meaningless on its own.
static void read_cpu_jiffies(unsigned long long *busy, unsigned long long *idle)
{
	*busy = 0;
	*idle = 0;
	FILE *f = fopen("/proc/stat", "r");
	if (!f)
		return;
	char lbl[16];
	unsigned long long u = 0, ni = 0, sy = 0, id = 0, io = 0, irq = 0,
			   sirq = 0, st = 0;
	// user nice system idle iowait irq softirq steal (guests folded into user)
	if (fscanf(f, "%15s %llu %llu %llu %llu %llu %llu %llu %llu", lbl, &u,
		   &ni, &sy, &id, &io, &irq, &sirq, &st) >= 5) {
		*busy = u + ni + sy + irq + sirq + st;
		*idle = id + io;
	}
	fclose(f);
}

// Memory used fraction (0..1) from /proc/meminfo: (MemTotal - MemAvailable) /
// MemTotal. MemAvailable already accounts for reclaimable cache, so this tracks
// real pressure rather than the misleading "free" number.
static double read_mem_used_frac(void)
{
	FILE *f = fopen("/proc/meminfo", "r");
	if (!f)
		return 0.0;
	char key[32];
	unsigned long val;
	char unit[16];
	unsigned long total = 0, avail = 0;
	while (fscanf(f, "%31s %lu %15s", key, &val, unit) >= 2) {
		if (strcmp(key, "MemTotal:") == 0)
			total = val;
		else if (strcmp(key, "MemAvailable:") == 0)
			avail = val;
		if (total && avail)
			break;
	}
	fclose(f);
	if (!total)
		return 0.0;
	if (avail > total)
		avail = total;
	return (double)(total - avail) / (double)total;
}

// System uptime in whole seconds from /proc/uptime.
static unsigned long read_uptime_s(void)
{
	FILE *f = fopen("/proc/uptime", "r");
	if (!f)
		return 0;
	double up = 0;
	if (fscanf(f, "%lf", &up) != 1)
		up = 0;
	fclose(f);
	return (unsigned long)up;
}

// -------------------------------------------------------------- oled: views ---
//
// Each view paints the whole framebuffer for one screen. They pull their data
// through the same SARADC/GPIO helpers `power` uses, so the meter matches the
// CLI numbers and self-calibrates off VBUS. Voltages come out as
// raw * scale * saradc_factor() / 1000 volts, exactly like cmd_power.

enum oled_view {
	VIEW_BATTERY = 0,
	VIEW_LOAD,
	VIEW_POWER,
	VIEW_COUNT,
};

// Read one rail (channel ch) in volts, or a negative number on failure. dir/scale
// are passed in so a view reads several rails without re-scanning sysfs.
static double oled_rail_volts(const char *dir, double scale, int ch)
{
	int raw = saradc_median_raw(dir, ch);
	if (raw < 0)
		return -1.0;
	return raw * scale * saradc_factor() / 1000.0;
}

// Resolve the SARADC directory and in_voltage_scale once per render. Returns 0
// and fills dir/scale on success; -1 if the ADC is unavailable.
static int oled_adc_setup(char *dir, size_t dirlen, double *scale)
{
	if (saradc_dir(dir, dirlen) != 0)
		return -1;
	char sp[96];
	snprintf(sp, sizeof(sp), "%s/in_voltage_scale", dir);
	if (read_sysfs_double(sp, scale) != 0)
		return -1;
	return 0;
}

// View 1 -- battery: VBAT big, a 3.0..4.2 V bar with a rough %, and a USB tag.
static void oled_view_battery(void)
{
	oled_clear();

	char dir[64];
	double scale;
	double vbat = -1.0;
	if (oled_adc_setup(dir, sizeof(dir), &scale) == 0)
		vbat = oled_rail_volts(dir, scale, 1); // VBAT is channel 1

	int vbus = gpio_read_line("usb-vbus-det");

	oled_draw_text(0, 0, "BATT");
	if (vbus == 1)
		oled_draw_text(OLED_W - 3 * GLYPH_W, 0, "USB");

	char big[16];
	if (vbat >= 0.0) {
		snprintf(big, sizeof(big), "%.2fV", vbat);
		oled_draw_text_2x(0, 9, big);
	} else {
		oled_draw_text_2x(0, 9, "--.--");
	}

	// Linear 3.0 V (empty) .. 4.2 V (full). Crude but honest for a Li-ion HUD.
	double frac = (vbat - 3.0) / (4.2 - 3.0);
	if (frac < 0.0)
		frac = 0.0;
	if (frac > 1.0)
		frac = 1.0;

	oled_draw_hbar(0, OLED_H - 7, OLED_W - 24, 7, vbat >= 0.0 ? frac : 0.0);
	char pct[8];
	snprintf(pct, sizeof(pct), "%3d%%", (int)(frac * 100.0 + 0.5));
	oled_draw_text(OLED_W - 22, OLED_H - 7, pct);
}

// View 2 -- load: 1-min loadavg (big-ish), a CPU% bar and a mem% bar. The CPU
// fraction is a static delta across renders; the first frame after a view switch
// shows 0% until the second sample lands, which is fine at ~12 fps.
static void oled_view_load(double cpu_frac, double mem_frac)
{
	oled_clear();

	double l1 = 0, l5 = 0, l15 = 0;
	read_loadavg(&l1, &l5, &l15);

	// Header: 1-min load on the left, uptime as up:NNh / up:NNm on the right.
	char line[24];
	snprintf(line, sizeof(line), "LD %.2f %.2f", l1, l5);
	oled_draw_text(0, 0, line);

	unsigned long up = read_uptime_s();
	char ut[24];
	// Clamp the displayed hours so a bogus /proc/uptime cannot make a silly
	// wide string; anything past ~41 days just pins at 999h.
	unsigned hours = up / 3600 > 999 ? 999 : (unsigned)(up / 3600);
	unsigned mins = (unsigned)((up % 3600) / 60);
	if (up >= 3600)
		snprintf(ut, sizeof(ut), "%uh", hours);
	else
		snprintf(ut, sizeof(ut), "%um", mins);
	int utx = OLED_W - (int)strlen(ut) * GLYPH_W;
	oled_draw_text(utx < 0 ? 0 : utx, 0, ut);

	if (cpu_frac < 0.0)
		cpu_frac = 0.0;
	if (mem_frac < 0.0)
		mem_frac = 0.0;

	oled_draw_text(0, 11, "CPU");
	oled_draw_hbar(4 * GLYPH_W, 10, OLED_W - 4 * GLYPH_W - 26, 8, cpu_frac);
	char cp[8];
	snprintf(cp, sizeof(cp), "%3d%%", (int)(cpu_frac * 100.0 + 0.5));
	oled_draw_text(OLED_W - 22, 11, cp);

	oled_draw_text(0, 22, "MEM");
	oled_draw_hbar(4 * GLYPH_W, 21, OLED_W - 4 * GLYPH_W - 26, 8, mem_frac);
	char mp[8];
	snprintf(mp, sizeof(mp), "%3d%%", (int)(mem_frac * 100.0 + 0.5));
	oled_draw_text(OLED_W - 22, 22, mp);
}

// View 3 -- power/rails: VSEL and VBUS volts, VBUS presence, and any asserted
// fault by short name. Mirrors what `nix-badge power` prints, condensed to 4
// lines of 5x7 text (4 * 8px = 32px, exactly the panel height).
static void oled_view_power(void)
{
	oled_clear();

	char dir[64];
	double scale;
	double vsel = -1.0;
	if (oled_adc_setup(dir, sizeof(dir), &scale) == 0)
		vsel = oled_rail_volts(dir, scale, 0); // VSEL is channel 0

	int vbus = gpio_read_line("usb-vbus-det");

	char line[24];
	if (vsel >= 0.0)
		snprintf(line, sizeof(line), "VSEL %.2fV", vsel);
	else
		snprintf(line, sizeof(line), "VSEL --.--");
	oled_draw_text(0, 0, line);

	snprintf(line, sizeof(line), "VBUS %s",
		 vbus < 0 ? "unk" : (vbus ? "yes" : "no"));
	oled_draw_text(0, 8, line);

	// Active-low fault lines: 0 = FAULT. Collect the asserted ones by short
	// name onto one line; show "OK" when everything is clear.
	static const struct {
		const char *name;
		const char *line;
	} faults[] = {
		{ "USB", "usb-5v-fault-n" },
		{ "HDMI", "hdmi-5v-fault-n" },
		{ "SD", "sd-fault-n" },
		{ "SAO", "sao-fault-n" },
	};
	char flt[24];
	size_t used = 0;
	flt[0] = '\0';
	for (size_t i = 0; i < 4; i++) {
		int v = gpio_read_line(faults[i].line);
		if (v == 0) { // asserted (active low)
			int n = snprintf(flt + used, sizeof(flt) - used, "%s%s",
					 used ? " " : "", faults[i].name);
			if (n > 0 && (size_t)n < sizeof(flt) - used)
				used += (size_t)n;
		}
	}
	oled_draw_text(0, 16, "FLT:");
	oled_draw_text(4 * GLYPH_W, 16, used ? flt : "OK");
}

// -------------------------------------------------------------- oled: run ---

// Blank the panel and turn the display off. Used by `oled off` and on exit from
// `oled run`, so a stopped service does not leave a frozen frame lit.
static int oled_blank_off(int fd)
{
	oled_clear();
	int rc = oled_flush(fd);
	if (oled_cmd1(fd, SSD1306_DISPLAYOFF) != 0)
		rc = -1;
	return rc;
}

static int cmd_oled_run(void)
{
	int fd = oled_open();
	if (fd < 0)
		return 1;
	if (oled_init(fd) != 0) {
		fprintf(stderr, "nix-badge: SSD1306 init failed: %s\n",
			strerror(errno));
		close(fd);
		return 1;
	}

	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);

	fprintf(stderr, "nix-badge: oled up on %s @ 0x%02x, %dx%d\n",
		OLED_I2C_BUS, OLED_I2C_ADDR, OLED_W, OLED_H);

	int view = VIEW_BATTERY;

	// USER button (btn-boot-n) is active-low: 0 = pressed. We edge-detect a
	// press (was released, now pressed) and advance the view once per press,
	// so a held button does not spin through every screen.
	int btn_prev = 1; // assume released at start

	// CPU utilisation is a delta between renders, so we keep the previous
	// jiffy sample. mem is instantaneous.
	unsigned long long busy_prev = 0, idle_prev = 0;
	read_cpu_jiffies(&busy_prev, &idle_prev);
	double cpu_frac = 0.0;

	// ~12 fps. Plenty for a status HUD and light on the I2C bus / CPU.
	const long frame_ns = 1000000000L / 12;

	while (!stop_requested) {
		struct timespec t_a;
		clock_gettime(CLOCK_MONOTONIC, &t_a);

		// Opportunistic self-calibration off VBUS, same as `power`. Quiet,
		// idempotent: a no-op once a factor is stored or on battery.
		saradc_calibrate(0, 1);

		// Debounced button edge -> advance the view.
		int btn = gpio_read_line("btn-boot-n");
		if (btn == 0 && btn_prev == 1)
			view = (view + 1) % VIEW_COUNT;
		if (btn >= 0)
			btn_prev = btn;

		// Refresh the CPU delta every frame regardless of the active view,
		// so switching to the load screen shows a live number at once.
		unsigned long long busy = 0, idle = 0;
		read_cpu_jiffies(&busy, &idle);
		unsigned long long dbusy = busy - busy_prev;
		unsigned long long didle = idle - idle_prev;
		unsigned long long dtot = dbusy + didle;
		if (dtot)
			cpu_frac = (double)dbusy / (double)dtot;
		busy_prev = busy;
		idle_prev = idle;

		switch (view) {
		case VIEW_LOAD:
			oled_view_load(cpu_frac, read_mem_used_frac());
			break;
		case VIEW_POWER:
			oled_view_power();
			break;
		case VIEW_BATTERY:
		default:
			oled_view_battery();
			break;
		}

		if (oled_flush(fd) != 0)
			fprintf(stderr, "nix-badge: oled flush failed: %s\n",
				strerror(errno));

		// Sleep the remainder of the frame.
		struct timespec t_b;
		clock_gettime(CLOCK_MONOTONIC, &t_b);
		long spent_ns = (long)((t_b.tv_sec - t_a.tv_sec) * 1000000000L +
				       (t_b.tv_nsec - t_a.tv_nsec));
		long rem_ns = frame_ns - spent_ns;
		if (rem_ns > 0) {
			struct timespec ts = { .tv_sec = 0, .tv_nsec = rem_ns };
			nanosleep(&ts, NULL);
		}
	}

	// Leave the panel dark on a clean stop so a restarted service repaints
	// from a known state rather than a stale frame.
	oled_blank_off(fd);
	close(fd);
	return 0;
}

static int cmd_oled_off(void)
{
	int fd = oled_open();
	if (fd < 0)
		return 1;
	// The panel may be uninitialised (fresh boot with no `run` yet), so bring
	// the controller up first, then blank + display-off. init is idempotent.
	oled_init(fd);
	int rc = oled_blank_off(fd);
	close(fd);
	return rc == 0 ? 0 : 1;
}

static int cmd_oled(int argc, char **argv)
{
	if (argc < 1) {
		fprintf(stderr, "usage: nix-badge oled <run|off>\n");
		return 2;
	}
	if (strcmp(argv[0], "run") == 0)
		return cmd_oled_run();
	if (strcmp(argv[0], "off") == 0)
		return cmd_oled_off();
	fprintf(stderr, "oled: expected run or off\n");
	return 2;
}

// ================================================================== bling ===
//
// The "bling engine" is a second OLED runtime that supersedes `oled run`. It
// keeps ONE render model: a screen is a pure function of a snapshot context
// (struct badge_ctx) that the loop gathers once per frame. A screen paints
// oled_fb (via oled_clear + the draw_* helpers, or a raw memcpy for baked
// frames) and RETURNS the number of ms until it wants to run again -- its own
// frame-rate hint. That lets a static meter idle at 2 Hz while Bad Apple runs
// at its baked fps, all under one loop.
//
// Controls are shared with the LED painter: the USER button and SIGUSR1/2 both
// advance either the OLED screen or the LED pattern, and the LED change is made
// by rewriting RUNTIME_CONF so the running `leds run` service hot-reloads it.
// So one button on the badge cycles both the panel and the ring.

// Snapshot the loop hands each screen. Gathered once per frame so a screen is a
// pure function of it -- no screen re-scans /proc or the ADC mid-render unless
// it chooses to (the folded-in views still do, which is fine at these rates).
struct badge_ctx {
	uint64_t now_ms; // CLOCK_MONOTONIC in ms, the animation time base
	int battery_mv; // -1 if unavailable
	int battery_pct; // 0..100, -1 if unknown
	int on_usb; // 1 if VBUS present, 0 if not, -1 unknown
	double load1; // 1-min loadavg
	int cpu_pct; // 0..100, diff of two /proc/stat samples across frames
	int mem_pct; // 0..100
	uint64_t uptime_s;
};

// A screen renders into oled_fb and returns its own desired ms-until-next-call.
typedef uint32_t (*screen_fn)(const struct badge_ctx *ctx);
struct screen {
	const char *name;
	screen_fn render;
};

// -------------------------------------------------------- bling: bad apple ---
//
// A baked frame blob. The header is little-endian: magic 'BADA', u16 width, u16
// height, u16 fps, u16 flags, u32 frame_count, then frame_count * 512-byte
// frames in the SAME SSD1306 page-major layout as oled_fb, so a frame streams
// to the panel with a plain memcpy. Loaded via mmap so a long clip costs no
// heap and pages in on demand. When no valid blob is supplied the screen is not
// registered at all, so the badge still works without the asset.
#define BADAPPLE_MAGIC "BADA"
#define BADAPPLE_HDR_LEN 16
static const uint8_t *badapple_base; // mmap of the whole file, or NULL
static size_t badapple_maplen;
static uint32_t badapple_fps;
static uint32_t badapple_frames;

// Read a little-endian u16/u32 from a byte pointer without assuming host
// endianness or alignment.
static uint16_t rd_le16(const uint8_t *p)
{
	return (uint16_t)(p[0] | (p[1] << 8));
}
static uint32_t rd_le32(const uint8_t *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
	       ((uint32_t)p[3] << 24);
}

// Open, validate and mmap a Bad Apple blob. Returns 0 and populates the
// badapple_* globals on success; -1 (with a message) on any problem, in which
// case the screen stays unregistered. Validation is strict: bad magic, a
// truncated header, zero frames, or a file too short for its claimed frame
// count all disqualify it, because a partial memcpy would smear the panel.
static int badapple_load(const char *path)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "nix-badge: badapple: cannot open %s: %s\n", path,
			strerror(errno));
		return -1;
	}
	struct stat st;
	if (fstat(fd, &st) != 0 || (size_t)st.st_size < BADAPPLE_HDR_LEN) {
		fprintf(stderr, "nix-badge: badapple: %s too small for a header\n",
			path);
		close(fd);
		return -1;
	}
	size_t len = (size_t)st.st_size;
	const uint8_t *base = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, 0);
	close(fd); // the mapping keeps the file alive; the fd is no longer needed
	if (base == MAP_FAILED) {
		fprintf(stderr, "nix-badge: badapple: mmap %s: %s\n", path,
			strerror(errno));
		return -1;
	}
	if (memcmp(base, BADAPPLE_MAGIC, 4) != 0) {
		fprintf(stderr, "nix-badge: badapple: %s has no BADA magic\n", path);
		munmap((void *)base, len);
		return -1;
	}
	uint32_t fps = rd_le16(base + 8);
	uint32_t frames = rd_le32(base + 12);
	// Every frame is exactly OLED_FBLEN bytes; reject a file that cannot hold
	// the frame count it claims, so the render memcpy can never run off the end.
	if (fps == 0 || frames == 0 ||
	    len < (size_t)BADAPPLE_HDR_LEN + (size_t)frames * OLED_FBLEN) {
		fprintf(stderr,
			"nix-badge: badapple: %s header inconsistent (fps %u, "
			"frames %u, %zu bytes)\n",
			path, fps, frames, len);
		munmap((void *)base, len);
		return -1;
	}
	badapple_base = base;
	badapple_maplen = len;
	badapple_fps = fps;
	badapple_frames = frames;
	fprintf(stderr, "nix-badge: badapple: %s, %ux%u, %u fps, %u frames\n", path,
		rd_le16(base + 4), rd_le16(base + 6), fps, frames);
	return 0;
}

// Play the baked blob on the animation clock: pick the frame the current time
// lands on and blit it straight to oled_fb. Returns the per-frame period so the
// loop paces it at the baked fps.
static uint32_t screen_badapple(const struct badge_ctx *ctx)
{
	uint32_t idx = (uint32_t)((ctx->now_ms * badapple_fps / 1000) %
				  badapple_frames);
	memcpy(oled_fb, badapple_base + BADAPPLE_HDR_LEN + (size_t)idx * OLED_FBLEN,
	       OLED_FBLEN);
	uint32_t ms = 1000u / badapple_fps;
	return ms ? ms : 1u; // never return 0, that would busy-spin the loop
}

// ---------------------------------------------------------- bling: screens ---
//
// The meter screens fold in the existing oled_view_* painters so their look and
// self-calibration match `oled run` and `power` exactly. load needs the CPU
// delta, which the loop tracks in ctx, so it hands ctx->cpu_pct through rather
// than recomputing it here.

static uint32_t screen_battery(const struct badge_ctx *ctx)
{
	(void)ctx; // the view re-reads VBAT/VBUS itself, same as `oled run`
	oled_view_battery();
	return 500; // a slow meter; 2 Hz is plenty and light on I2C
}

static uint32_t screen_load(const struct badge_ctx *ctx)
{
	// Reuse the loop's rolling CPU delta (a single sample is meaningless), and
	// read mem fresh -- it is instantaneous. mem_pct is also in ctx but the
	// view takes a fraction, so pass the same number back as a fraction.
	oled_view_load(ctx->cpu_pct / 100.0, ctx->mem_pct / 100.0);
	return 500;
}

static uint32_t screen_power(const struct badge_ctx *ctx)
{
	(void)ctx; // the view re-reads the rails/faults itself
	oled_view_power();
	return 750; // rails move slowly; a slower refresh keeps the ADC quiet
}

// Uptime clock: Dd HH:MM:SS drawn big, with the colon blinking at 1 Hz off the
// animation clock so the panel visibly ticks. Returns 250 ms so the blink has
// four samples a second and never looks stuttery.
static uint32_t screen_clock(const struct badge_ctx *ctx)
{
	oled_clear();
	oled_draw_text(0, 0, "UPTIME");

	uint64_t s = ctx->uptime_s;
	// Clamp days to 3 digits so the big string is bounded (the panel only fits
	// so much anyway); a bogus /proc/uptime cannot overrun the buffer.
	unsigned days = (unsigned)(s / 86400);
	if (days > 999)
		days = 999;
	unsigned hh = (unsigned)((s % 86400) / 3600);
	unsigned mm = (unsigned)((s % 3600) / 60);
	unsigned ss = (unsigned)(s % 60);

	// Blink the colons: on for the first half of each second, off for the
	// second half. now_ms % 1000 < 500 is the 1 Hz square wave.
	int colon = (ctx->now_ms % 1000) < 500;
	char sep = colon ? ':' : ' ';

	char big[24];
	if (days > 0)
		snprintf(big, sizeof(big), "%ud%02u%c%02u", days, hh, sep, mm);
	else
		snprintf(big, sizeof(big), "%02u%c%02u%c%02u", hh, sep, mm, sep,
			 ss);
	oled_draw_text_2x(0, 12, big);

	// A seconds progress bar along the bottom, a second read on the tick.
	oled_draw_hbar(0, OLED_H - 5, OLED_W, 5, (s % 60) / 60.0);
	return 250;
}

// The registry. badapple is registered FIRST (and so is the default screen)
// only when a valid blob loaded; otherwise the meters lead. Order here is the
// cycle order the button/SIGUSR2 walk.
static struct screen screens[8];
static int n_screens;

// Build the screen table, putting badapple first when it is available so it is
// the default. Kept out of cmd_bling so the ordering rule lives in one place.
static void screens_init(void)
{
	n_screens = 0;
	if (badapple_base)
		screens[n_screens++] =
			(struct screen){ "badapple", screen_badapple };
	screens[n_screens++] = (struct screen){ "battery", screen_battery };
	screens[n_screens++] = (struct screen){ "load", screen_load };
	screens[n_screens++] = (struct screen){ "power", screen_power };
	screens[n_screens++] = (struct screen){ "clock", screen_clock };
}

// ------------------------------------------------------- bling: leds.conf ---
//
// "Next LED pattern" advances the `pattern =` value in RUNTIME_CONF and leaves
// every other line untouched, so the running `leds run` service hot-reloads
// just the pattern on its next tick. We skip index 0 ("off") when cycling so a
// button press never blanks the ring -- to turn the LEDs off you use
// `leds set --pattern off` on purpose, the same as before.

// Read the current pattern name from RUNTIME_CONF, or the first non-off pattern
// when the file or key is absent. Returns an index into pattern_names[].
static int leds_current_pattern(void)
{
	struct config c;
	config_defaults(&c);
	// config_load applies `pattern =` through apply_kv, so this reuses the
	// exact same parse the service uses; a missing file just keeps the default.
	if (config_load(&c, RUNTIME_CONF, 0) != 0)
		return PAT_SOLID; // no runtime file yet: start at the first non-off
	return (int)c.pattern;
}

// Advance RUNTIME_CONF's pattern to the next name in pattern_names[], wrapping
// and skipping index 0 ("off"). All other keys/lines are preserved by copying
// the file line by line and rewriting only the pattern line (appending one if
// none exists). Creates the file with just the pattern when it is absent.
static void leds_next_pattern(void)
{
	// Count the real (non-NULL) pattern names once.
	int npat = 0;
	while (pattern_names[npat])
		npat++;

	int cur = leds_current_pattern();
	int next = cur + 1;
	if (next >= npat)
		next = 0;
	if (next == PAT_OFF) // skip "off" so cycling never lands on a dark ring
		next = PAT_OFF + 1;
	const char *want = pattern_names[next];

	if (mkdir(RUNTIME_DIR, 0755) != 0 && errno != EEXIST) {
		fprintf(stderr, "nix-badge: bling: cannot create %s: %s\n",
			RUNTIME_DIR, strerror(errno));
		return;
	}

	// Copy the existing file into memory, replacing the pattern line, so all
	// other keys survive. A modest cap is fine: this file is a handful of
	// short key = value lines.
	char lines[64][256];
	int nlines = 0, replaced = 0;
	FILE *in = fopen(RUNTIME_CONF, "r");
	if (in) {
		char line[256];
		while (nlines < 64 && fgets(line, sizeof(line), in)) {
			// Detect a "pattern =" line the same loose way apply_kv keys
			// are matched: skip leading blanks, compare the trimmed key.
			char *p = line;
			while (*p == ' ' || *p == '\t')
				p++;
			int is_pattern = 0;
			if (strncmp(p, "pattern", 7) == 0) {
				const char *q = p + 7;
				while (*q == ' ' || *q == '\t')
					q++;
				if (*q == '=')
					is_pattern = 1;
			}
			if (is_pattern) {
				snprintf(lines[nlines], sizeof(lines[nlines]),
					 "pattern = %s\n", want);
				replaced = 1;
			} else {
				snprintf(lines[nlines], sizeof(lines[nlines]), "%s",
					 line);
			}
			nlines++;
		}
		fclose(in);
	}

	FILE *out = fopen(RUNTIME_CONF, "w");
	if (!out) {
		fprintf(stderr, "nix-badge: bling: cannot write %s: %s\n",
			RUNTIME_CONF, strerror(errno));
		return;
	}
	if (nlines == 0) {
		// Fresh file: just the pattern, which is a valid minimal config.
		fprintf(out, "pattern = %s\n", want);
	} else {
		for (int i = 0; i < nlines; i++)
			fputs(lines[i], out);
		if (!replaced) // no pattern line existed: append one, keep the rest
			fprintf(out, "pattern = %s\n", want);
	}
	fclose(out);
	fprintf(stderr, "nix-badge: bling: LED pattern -> %s\n", want);
}

// --------------------------------------------------------- bling: signals ---
//
// SIGUSR1 = next LED pattern, SIGUSR2 = next OLED screen. The handlers only set
// atomic flags; the loop acts on them between frames AND the wait polls them, so
// a signal breaks the frame sleep and the change feels instant. SIGTERM/SIGINT
// reuse the shared on_signal/stop_requested path so a clean exit blanks the
// panel like `oled run`.
static volatile sig_atomic_t want_next_pattern;
static volatile sig_atomic_t want_next_screen;

static void on_bling_signal(int sig)
{
	if (sig == SIGUSR1)
		want_next_pattern = 1;
	else if (sig == SIGUSR2)
		want_next_screen = 1;
}

// ------------------------------------------------------------- bling: loop ---

// Gather the per-frame context: the animation clock, battery/USB off the SARADC
// + VBUS GPIO (mirroring cmd_power/oled_view_battery, with the same opportunistic
// self-calibration), and cpu/mem/load/uptime off the /proc readers. cpu_pct is a
// delta, so the previous jiffy sample is passed in and updated.
static void bling_gather(struct badge_ctx *ctx, unsigned long long *busy_prev,
			 unsigned long long *idle_prev)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	ctx->now_ms = (uint64_t)t.tv_sec * 1000 + (uint64_t)t.tv_nsec / 1000000;

	// Self-calibrate off VBUS the same way the meters do: idempotent no-op once
	// a factor is stored or on battery, so it is safe to call every frame.
	saradc_calibrate(0, 1);

	ctx->on_usb = gpio_read_line("usb-vbus-det");

	// Battery voltage in mV and a rough linear %; -1 when the ADC is absent.
	ctx->battery_mv = -1;
	ctx->battery_pct = -1;
	char dir[64];
	double scale;
	if (oled_adc_setup(dir, sizeof(dir), &scale) == 0) {
		double v = oled_rail_volts(dir, scale, 1); // VBAT is channel 1
		if (v >= 0.0) {
			ctx->battery_mv = (int)(v * 1000.0 + 0.5);
			// Rough Li-ion map: 3.0 V empty .. 4.2 V full, clamped. Not a
			// real fuel gauge, just a HUD hint, same as oled_view_battery.
			double frac = (v - 3.0) / (4.2 - 3.0);
			if (frac < 0.0)
				frac = 0.0;
			if (frac > 1.0)
				frac = 1.0;
			ctx->battery_pct = (int)(frac * 100.0 + 0.5);
		}
	}

	// CPU utilisation is a delta between two /proc/stat samples across frames.
	unsigned long long busy = 0, idle = 0;
	read_cpu_jiffies(&busy, &idle);
	unsigned long long dbusy = busy - *busy_prev;
	unsigned long long dtot = dbusy + (idle - *idle_prev);
	ctx->cpu_pct = dtot ? (int)(dbusy * 100 / dtot) : 0;
	*busy_prev = busy;
	*idle_prev = idle;

	double l1 = 0, l5 = 0, l15 = 0;
	read_loadavg(&l1, &l5, &l15);
	ctx->load1 = l1;
	ctx->mem_pct = (int)(read_mem_used_frac() * 100.0 + 0.5);
	ctx->uptime_s = read_uptime_s();
}

// Sleep up to want_ms, but wake early on a pending stop/pattern/screen signal
// flag or a fresh USER-button press, so screen and pattern switches feel
// instant. We poll in ~20 ms slices: each slice checks the flags, then debounces
// the button, measuring a press-hold so short vs long presses can be told apart
// on release. Short (<400 ms) advances the LED pattern, long (>=400 ms) the OLED
// screen. Sets the same want_next_* flags the signal handlers use, so the caller
// has one place to act on a change.
#define BLING_POLL_MS 20
#define BLING_LONGPRESS_MS 400
static void bling_wait(uint32_t want_ms, int *btn_prev, uint64_t *press_start_ms)
{
	uint64_t waited = 0;
	while (waited < want_ms) {
		if (stop_requested || want_next_pattern || want_next_screen)
			return; // a change is pending; act on it now, do not sleep on

		int btn = gpio_read_line("btn-boot-n"); // active-low: 0 = pressed
		struct timespec t;
		clock_gettime(CLOCK_MONOTONIC, &t);
		uint64_t now_ms =
			(uint64_t)t.tv_sec * 1000 + (uint64_t)t.tv_nsec / 1000000;

		if (btn == 0 && *btn_prev == 1) {
			// Falling edge: press began. Record when, decide on release.
			*press_start_ms = now_ms;
		} else if (btn == 1 && *btn_prev == 0) {
			// Rising edge: released. Hold duration picks the action.
			uint64_t held = now_ms - *press_start_ms;
			if (held >= BLING_LONGPRESS_MS)
				want_next_screen = 1;
			else
				want_next_pattern = 1;
		}
		if (btn >= 0)
			*btn_prev = btn;

		uint32_t slice = (uint32_t)(want_ms - waited);
		if (slice > BLING_POLL_MS)
			slice = BLING_POLL_MS;
		struct timespec ts = { .tv_sec = 0,
				       .tv_nsec = (long)slice * 1000000L };
		nanosleep(&ts, NULL);
		waited += slice;
	}
}

static int cmd_bling(int argc, char **argv)
{
	const char *badapple_path = NULL;
	for (int i = 0; i < argc; i++) {
		if (strcmp(argv[i], "--badapple") == 0 && i + 1 < argc)
			badapple_path = argv[++i];
		else
			die("bling: unknown argument '%s'", argv[i]);
	}

	// Try the blob first so badapple can be the default screen. An invalid or
	// missing asset just leaves the screen unregistered; the badge still works.
	if (badapple_path)
		badapple_load(badapple_path);
	screens_init();

	int fd = oled_open();
	if (fd < 0) {
		// A core without the SAO mux has no panel. Non-fatal, exactly like
		// cmd_oled_run's caller expects: exit 0 so systemd does not respin.
		fprintf(stderr, "nix-badge: bling: no OLED panel, nothing to do\n");
		return 0;
	}
	if (oled_init(fd) != 0) {
		fprintf(stderr, "nix-badge: bling: SSD1306 init failed: %s\n",
			strerror(errno));
		close(fd);
		return 0;
	}

	// SIGTERM/SIGINT stop (shared on_signal/stop_requested); SIGUSR1/2 request
	// the next pattern/screen. All installed with an empty mask so a handler is
	// not itself interrupted mid-flag-set.
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	sa.sa_handler = on_bling_signal;
	sigaction(SIGUSR1, &sa, NULL);
	sigaction(SIGUSR2, &sa, NULL);

	fprintf(stderr, "nix-badge: bling up on %s @ 0x%02x, %d screens, first %s\n",
		OLED_I2C_BUS, OLED_I2C_ADDR, n_screens, screens[0].name);

	int screen_ix = 0;

	// USER button state carried across wait() calls: released to start, no
	// press in progress. CPU delta state for the load screen.
	int btn_prev = 1;
	uint64_t press_start_ms = 0;
	unsigned long long busy_prev = 0, idle_prev = 0;
	read_cpu_jiffies(&busy_prev, &idle_prev);

	while (!stop_requested) {
		struct badge_ctx ctx;
		bling_gather(&ctx, &busy_prev, &idle_prev);

		uint32_t want_ms = screens[screen_ix].render(&ctx);
		if (oled_flush(fd) != 0)
			fprintf(stderr, "nix-badge: bling: flush failed: %s\n",
				strerror(errno));

		// Interruptible frame wait: wakes early on a signal flag or button.
		bling_wait(want_ms, &btn_prev, &press_start_ms);

		// Act on any change the wait or a signal queued. Pattern first, so a
		// simultaneous pattern+screen request still applies both.
		if (want_next_pattern) {
			want_next_pattern = 0;
			leds_next_pattern();
		}
		if (want_next_screen) {
			want_next_screen = 0;
			screen_ix = (screen_ix + 1) % n_screens;
			fprintf(stderr, "nix-badge: bling: screen -> %s\n",
				screens[screen_ix].name);
		}
	}

	// Blank the panel on a clean stop, same as `oled run`, so a restart
	// repaints from a known state. Drop the blob mapping too for tidiness.
	oled_blank_off(fd);
	close(fd);
	if (badapple_base)
		munmap((void *)badapple_base, badapple_maplen);
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
		"  nix-badge oled <run|off>\n"
		"  nix-badge bling [--badapple PATH]\n"
		"  nix-badge mmio <read ADDR | write ADDR VALUE>\n"
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

// ---------------------------------------------------------------- mmio ---
// Minimal 32-bit /dev/mem peek/poke for SoC register bring-up. Used to sweep
// the SAO IIC1 pinmux (VIVO_D4=0x0300114c, VIVO_D3=0x03001150) live while
// hunting for the SSD1306's 0x3c ACK, so no reboot-per-guess is needed.
//   nix-badge mmio read  <addr>
//   nix-badge mmio write <addr> <value>
static int cmd_mmio(int argc, char **argv)
{
	if (argc < 2)
		die("usage: nix-badge mmio <read ADDR | write ADDR VALUE>");
	int is_write = strcmp(argv[0], "write") == 0;
	if (!is_write && strcmp(argv[0], "read") != 0)
		die("mmio: first arg must be 'read' or 'write'");
	if (is_write && argc < 3)
		die("mmio write needs ADDR and VALUE");

	unsigned long addr = strtoul(argv[1], NULL, 0);
	uint32_t val = is_write ? (uint32_t)strtoul(argv[2], NULL, 0) : 0;

	long pagesize = sysconf(_SC_PAGESIZE);
	unsigned long base = addr & ~(unsigned long)(pagesize - 1);
	unsigned long off = addr - base;

	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0)
		die("open /dev/mem: %s", strerror(errno));
	volatile uint8_t *map = mmap(NULL, (size_t)pagesize,
				     PROT_READ | PROT_WRITE, MAP_SHARED, fd,
				     (off_t)base);
	if (map == MAP_FAILED)
		die("mmap 0x%lx: %s", base, strerror(errno));

	volatile uint32_t *reg = (volatile uint32_t *)(map + off);
	if (is_write) {
		*reg = val;
		__sync_synchronize();
		printf("0x%08lx = 0x%08x\n", addr, *reg);
	} else {
		printf("0x%08lx = 0x%08x\n", addr, *reg);
	}
	munmap((void *)map, (size_t)pagesize);
	close(fd);
	return 0;
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
	if (strcmp(argv[1], "oled") == 0)
		return cmd_oled(argc - 2, argv + 2);
	if (strcmp(argv[1], "bling") == 0)
		return cmd_bling(argc - 2, argv + 2);
	if (strcmp(argv[1], "mmio") == 0)
		return cmd_mmio(argc - 2, argv + 2);
	usage();
	return 2;
}
