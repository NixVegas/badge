// nixbadge-leds: drive the badge WS2812 (NeoPixel) ring from the SG2000 SPI3
// controller through spidev.
//
// WS2812 is a single-wire part. It has no clock line. Each LED bit is a pulse
// whose HIGH time gives the bit value. We make those pulses with the SPI MOSI
// line: we send 3 SPI bits for each LED bit, and we set the SPI clock so that
// 3 SPI bits equal one 1.25 us LED bit.
//
//   LED bit 0 -> 0b100     LED bit 1 -> 0b110
//
// 8 LED bits become 24 SPI bits, which is exactly 3 bytes. No bit straddles a
// byte boundary, so the encoder stays simple.
//
// Clock math on this SoC, MEASURED on a Milk-V Duo S rather than assumed:
//   /sys/kernel/debug/clk/clk_spi/clk_rate reads 187500000, so ssi_clk is
//   187.5 MHz and FPLL is 1.5 GHz (clk_spi = FPLL / 8).
//   The DesignWare APB SSI divides ssi_clk by an even integer:
//     clk_div  = (DIV_ROUND_UP(ssi_clk, freq) + 1) & 0xfffe = 80
//     speed_hz = 187500000 / 80 = 2343750 Hz
//     SPI bit  = 426.7 ns
//     T0H      = 426.7 ns   (WS2812B wants 400 ns +/- 150 ns)
//     T1H      = 853.3 ns   (WS2812B wants 800 ns +/- 150 ns)
//     LED bit  = 1280 ns    (WS2812B wants 1250 ns)
//   All inside tolerance. The timing also stays in spec for any ssi_clk from
//   about 25 MHz upward, so it does not depend on this exact rate.
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

#include <linux/spi/spidev.h>

// Path that the CLI writes and that the service reads after the base config.
// The initrd has no /var, so early boot always uses the declarative config.
#define RUNTIME_CONF "/var/lib/nixbadge/leds.conf"
#define RUNTIME_DIR "/var/lib/nixbadge"

// How often a static pattern wakes to look for a config change. An animation
// polls once per frame instead, which it gets for free.
#define IDLE_POLL_HZ 2

// How long to keep looking for the SPI clock in debugfs. The service starts in
// the initrd, so debugfs only appears once stage 2 mounts it.
#define CLK_REPORT_TIMEOUT_SECONDS 120

#define MAX_LEDS 1024
#define MAX_COLORS 16
#define LATCH_BYTES 64 // about 280 us of low, which covers the SK6812 80 us
#define OPEN_RETRY_SECONDS 30

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
	unsigned brightness; // 0-255, applied in software
	unsigned fps;
	enum pattern pattern;
	struct rgb colors[MAX_COLORS];
	unsigned ncolors;
};

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
	fprintf(stderr, "nixbadge-leds: ");
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
	c->speed_hz = 2400000;
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

// One LED byte becomes 3 SPI bytes, MSB first.
static void encode_byte(uint8_t v, uint8_t *out)
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

// WS2812 takes the channels in G, R, B order.
static void encode_frame(const struct rgb *px, unsigned count, uint8_t *out)
{
	for (unsigned i = 0; i < count; i++) {
		encode_byte(px[i].g, out + i * 9 + 0);
		encode_byte(px[i].r, out + i * 9 + 3);
		encode_byte(px[i].b, out + i * 9 + 6);
	}
	memset(out + count * 9, 0, LATCH_BYTES);
}

// ------------------------------------------------------------------ spi ----

// The clock that feeds the SPI controller. The sophgo clk driver names it
// clk_spi, and the common clock framework exports its rate through debugfs.
#define SSI_CLK_RATE_PATH "/sys/kernel/debug/clk/clk_spi/clk_rate"

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
	fprintf(stderr,
		"nixbadge-leds: %s ssi_clk %lu Hz, divider %lu, actual %lu Hz, "
		"SPI bit %u ns, T0H %u ns, T1H %u ns "
		"(WS2812B wants 400 and 800 ns, +/- 150 ns)\n",
		c->device, ssi, div, actual, ns, ns, ns * 2);
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
				"nixbadge-leds: waiting for %s (%s)\n",
				c->device, strerror(errno));
		sleep(1);
	}
	if (fd < 0) {
		// A missing node means the board has no LED bus, for example a
		// core whose device tree does not mux SPI3. That is not a
		// failure worth restarting for, so we tell the caller to stop.
		fprintf(stderr,
			"nixbadge-leds: %s did not appear after %u seconds, "
			"giving up\n",
			c->device, OPEN_RETRY_SECONDS);
		return -1;
	}

	uint8_t mode = SPI_MODE_0;
	uint8_t bits = 8;
	uint32_t speed = c->speed_hz;

	if (ioctl(fd, SPI_IOC_WR_MODE, &mode) < 0)
		die("SPI_IOC_WR_MODE: %s", strerror(errno));
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
	cfg->ncolors = fresh.ncolors;
	memcpy(cfg->colors, fresh.colors, sizeof(cfg->colors));

	fprintf(stderr,
		"nixbadge-leds: reloaded, pattern %s, brightness %u, %u fps\n",
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

	struct rgb *px = calloc(cfg.count, sizeof(*px));
	uint8_t *frame = calloc(cfg.count * 9 + LATCH_BYTES, 1);
	if (!px || !frame)
		die("out of memory for %u leds", cfg.count);

	int fd = spi_open(&cfg);
	if (fd < 0) {
		free(px);
		free(frame);
		return 0; // clean stop, so systemd does not restart us forever
	}
	// Not const: a reload can change the LED count and resize the buffers.
	size_t framelen = cfg.count * 9 + LATCH_BYTES;

	fprintf(stderr,
		"nixbadge-leds: %u leds, pattern %s, brightness %u, %u fps, "
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
			"nixbadge-leds: %s not readable yet, will report the "
			"real bit timing once it appears\n",
			SSI_CLK_RATE_PATH);

	struct timespec seen;
	int have_seen = runtime_mtime(&seen) == 0;
	unsigned n = 0;

	while (!stop_requested) {
		if (!clk_logged) {
			clk_logged = log_clock(&cfg);
			if (!clk_logged && time(NULL) > clk_deadline) {
				fprintf(stderr,
					"nixbadge-leds: giving up on %s, bit "
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
			reload_live(&cfg, base);
			n = 0;

			// count is reloadable so the ring length can be
			// bisected without a rebuild. That matters when only
			// the first few LEDs respond and you need to find
			// where the chain stops working.
			if (cfg.count != old_count) {
				struct rgb *npx =
					realloc(px, cfg.count * sizeof(*px));
				uint8_t *nframe = realloc(
					frame, cfg.count * 9 + LATCH_BYTES);
				if (npx && nframe) {
					px = npx;
					frame = nframe;
					framelen = cfg.count * 9 + LATCH_BYTES;
					fprintf(stderr,
						"nixbadge-leds: count now %u, "
						"%zu bytes per frame\n",
						cfg.count, framelen);
				} else {
					// Keep the old buffers rather than
					// touch memory we no longer own.
					if (npx)
						px = npx;
					if (nframe)
						frame = nframe;
					cfg.count = old_count;
					fprintf(stderr,
						"nixbadge-leds: cannot resize "
						"to %u leds, keeping %u\n",
						cfg.count, old_count);
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
			encode_frame(px, cfg.count, frame);

			struct spi_ioc_transfer tr;
			memset(&tr, 0, sizeof(tr));
			tr.tx_buf = (unsigned long)frame;
			tr.rx_buf = 0;
			tr.len = (uint32_t)framelen;
			tr.speed_hz = cfg.speed_hz;
			tr.bits_per_word = 8;

			if (ioctl(fd, SPI_IOC_MESSAGE(1), &tr) < 0) {
				// A transient error must not kill the boot
				// indicator.
				fprintf(stderr,
					"nixbadge-leds: transfer failed: %s\n",
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
	// a visible gap. Use "nixbadge-leds set --pattern off" to clear them on
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

static void usage(void)
{
	fprintf(stderr,
		"usage:\n"
		"  nixbadge-leds run --config FILE\n"
		"  nixbadge-leds set [--pattern P] [--brightness 0-255] "
		"[--count N] [--color '#rrggbb' ...]\n"
		"  nixbadge-leds show\n"
		"\n"
		"patterns: off solid pulse rainbow chase\n");
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		usage();
		return 2;
	}
	if (strcmp(argv[1], "run") == 0)
		return cmd_run(argc - 2, argv + 2);
	if (strcmp(argv[1], "set") == 0)
		return cmd_set(argc - 2, argv + 2);
	if (strcmp(argv[1], "show") == 0)
		return cmd_show();
	usage();
	return 2;
}
