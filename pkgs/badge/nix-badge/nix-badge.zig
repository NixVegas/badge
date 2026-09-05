//! nix-badge: drive the Milk-V Duo S badge's WS2812 ring, OLED panel, core-select
//! latch, rail and battery readout, and a /dev/mem peek and poke, over the
//! SG2000's spidev, i2c, and gpio devices.
//!
//! The `bling run` service starts in the initrd and must not make the ring
//! flicker, so its transfer path sends one continuous SPI frame followed by a
//! latch of at least 320 microseconds.
//!
//! Files and time come through the injected `std.Io`. The three character devices
//! this tool drives need `ioctl`, which `std.Io` does not model, so each device's
//! uAPI structs live beside the code that drives them: the spidev structs here,
//! i2c-dev in oled.zig, and the GPIO v2 layout in sysfs.zig.

const std = @import("std");
const ws2812 = @import("ws2812.zig");
const config = @import("config.zig");
const oled = @import("oled.zig");
const sysfs = @import("sysfs.zig");
const bled = @import("bled.zig");
const screens = @import("screens.zig");
const fixeval = @import("fixeval.zig");
const nixeval = @import("nixeval.zig");
const eval = @import("eval.zig");
const backend = @import("backend.zig");

const Config = config.Config;
const Rgb = ws2812.Rgb;

// Mutable runtime state lives in /etc/nixbadge beside the default content, so the
// whole surface a user can change is one folder. The directory is also created
// declaratively, but this tool creates it as well, so an early-boot path does not
// depend on that ordering.
const runtime_conf = "/etc/nixbadge/leds.conf";
const runtime_dir = "/etc/nixbadge";

// Flags a signal handler sets for the main loop to read.
//
// The kernel dispatches a signal handler to a fixed address, so a handler cannot
// take a context parameter. These are the one sanctioned exception to the
// no-globals rule: they are minimal, atomic, and documented. TERM and INT ask for
// a clean stop, and USR1 and USR2 ask for the next pattern or screen.
var stop_requested = std.atomic.Value(bool).init(false);
var want_next_pattern = std.atomic.Value(bool).init(false);
var want_next_screen = std.atomic.Value(bool).init(false);
// A button hold longer than `backend_switch_ms` asks for a live evaluator change.
var want_switch_backend = std.atomic.Value(bool).init(false);

/// Parse a `--backend fix|nix` value. An unknown name selects fix and is logged.
/// Requesting nix on a build without it is harmless, because `open` falls back to
/// fix.
fn parseBackendKind(v: []const u8) backend.Kind {
    if (std.mem.eql(u8, v, "nix")) return .nix;
    if (std.mem.eql(u8, v, "fix")) return .fix;
    std.log.warn("unknown --backend '{s}'; using fix", .{v});
    return .fix;
}

/// The name of a backend, for the frame-rate log line and the on-panel readout.
fn backendName(k: backend.Kind) []const u8 {
    return @tagName(k);
}

fn onStop(_: std.os.linux.SIG) callconv(.c) void {
    stop_requested.store(true, .monotonic);
}

// ---- the screen-control signals ---------------------------------------------
//
// A real-time signal drives the panel directly, so a peer can change the screen
// without systemd in its closure. Signal 40+N selects screen index N, and signal
// 56 selects the screen whose name contains "swapcore", which is the hidden
// indicator the core swap shows while the button is held. The numbers start at 40
// to stay clear of the C runtime's own real-time signals at 32 through 34.
//
// The oled daemon writes its pid to a file, so a peer can find it.
const sig_jump_base: u32 = 40;
const sig_jump_count: u32 = 16;
const sig_swapcore: u32 = 56;
const oled_pidfile = "/run/nixbadge-oled.pid";

/// A queued screen change: `jump_none` for nothing, `jump_swapcore` to select the
/// swapcore screen by name, and any other value is a screen index.
const jump_none: i32 = -1;
const jump_swapcore: i32 = -2;
var want_jump = std.atomic.Value(i32).init(jump_none);

fn onJump(sig: std.os.linux.SIG) callconv(.c) void {
    const n = @intFromEnum(sig);
    if (n == sig_swapcore) {
        want_jump.store(jump_swapcore, .monotonic);
    } else if (n >= sig_jump_base and n < sig_jump_base + sig_jump_count) {
        want_jump.store(@intCast(n - sig_jump_base), .monotonic);
    }
}

fn onUser(sig: std.os.linux.SIG) callconv(.c) void {
    switch (sig) {
        .USR1 => want_next_pattern.store(true, .monotonic),
        .USR2 => want_next_screen.store(true, .monotonic),
        else => {},
    }
}

/// Install a handler for `sig`. A failure would mean this code passed a signal
/// number that cannot be caught or is out of range, which is a programmer error,
/// so it is asserted.
fn installHandler(sig: std.os.linux.SIG, handler: std.os.linux.Sigaction.handler_fn) void {
    const sa: std.os.linux.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    const rc = std.os.linux.sigaction(sig, &sa, null);
    std.debug.assert(std.os.linux.errno(rc) == .SUCCESS);
}

/// Whether a stop, next-pattern, next-screen, or backend change is queued, by a
/// signal or by the button sampler. This lets the frame wait end early.
fn eventPending() bool {
    return stop_requested.load(.monotonic) or
        want_next_pattern.load(.monotonic) or
        want_next_screen.load(.monotonic) or
        want_switch_backend.load(.monotonic) or
        want_jump.load(.monotonic) != jump_none;
}

// ------------------------------------------------------------- output sink ---

/// A buffered stdout writer bound to the injected I/O. Program output (the
/// `power` voltages, `bling show`, the `core`/`mmio` results) goes here; diagnostic
/// chatter goes to std.log (stderr). Flush before returning.
const Out = struct {
    file_writer: std.Io.File.Writer,

    fn init(io: std.Io, buffer: []u8) Out {
        return .{ .file_writer = std.Io.File.stdout().writer(io, buffer) };
    }

    fn w(self: *Out) *std.Io.Writer {
        return &self.file_writer.interface;
    }

    fn flush(self: *Out) void {
        self.file_writer.interface.flush() catch |err| {
            std.log.warn("stdout flush failed: {s}", .{@errorName(err)});
        };
    }
};

// ================================================================ commands ===

const usage_text =
    \\usage:
    \\  nix-badge bling run --config FILE [--backend fix|nix]
    \\  nix-badge bling set [--brightness 0-255] [--count N] [--speed-hz HZ]
    \\        [--bits 3|4|8] [--fps N] [--blob PATH] [--eval PATH]
    \\  nix-badge bling show
    \\  nix-badge core <arm|riscv|status>
    \\  nix-badge power
    \\  nix-badge oled [--eval-screen PATH ...] [--eval-dir DIR] [--content-root DIR]
    \\        [--oled-width W] [--oled-height H] [--backend fix|nix]
    \\  nix-badge bootswap
    \\  nix-badge mmio <read ADDR | write ADDR VALUE>
    \\  nix-badge fix-selftest              (smoke-test the embedded fix evaluator)
    \\  nix-badge nix-selftest              (smoke-test the upstream Nix C API backend)
    \\
;

/// A command failed in a way worth a non-zero exit. Distinct from an argument
/// misuse (which prints usage and returns 2).
const CmdError = error{ Usage, Failed };

// ------------------------------------------------------------- config load ---

/// The largest config file this tool reads. Both files hold a handful of short
/// `key = value` lines.
const config_max_bytes = 8192;

/// Load the declarative base config, when one is given, then apply the runtime
/// file over it.
///
/// A malformed base config is fatal, because the build shipped it. A malformed
/// runtime file is logged and skipped, so a bad edit cannot stop the badge from
/// booting with its indicator lit.
fn loadConfig(io: std.Io, base: ?[]const u8) CmdError!Config {
    var cfg = Config.default();
    if (base) |path| {
        var file_buf: [config_max_bytes]u8 = undefined;
        const text = std.Io.Dir.cwd().readFile(io, path, &file_buf) catch |err| {
            std.log.err("cannot read config {s}: {t}", .{ path, err });
            return error.Failed;
        };
        config.parseBuffer(&cfg, text) catch |err| {
            std.log.err("config {s}: {t}", .{ path, err });
            return error.Failed;
        };
    }
    layerRuntime(io, &cfg);
    return cfg;
}

/// Apply the declarative base config over `cfg`, when a path is given.
///
/// This is the reload path, so a read or parse fault is not fatal here. It is
/// logged and the previous value is kept, unlike the initial load above.
fn layerBase(io: std.Io, cfg: *Config, base: ?[]const u8) void {
    const path = base orelse return;
    var file_buf: [config_max_bytes]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(io, path, &file_buf) catch |err| {
        std.log.warn("cannot re-read base config {s} ({t}); keeping the old values", .{
            path, err,
        });
        return;
    };
    config.parseBuffer(cfg, text) catch |err| {
        std.log.warn("base config {s}: {t}; keeping the previous values", .{ path, err });
    };
}

/// Apply the runtime file over `cfg` when it is present. A missing file is the
/// normal state before anything has been changed, so it is not logged. A parse
/// fault is logged and the file is ignored.
fn layerRuntime(io: std.Io, cfg: *Config) void {
    var file_buf: [config_max_bytes]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(io, runtime_conf, &file_buf) catch |err| {
        if (err != error.FileNotFound)
            std.log.warn("cannot read {s} ({t}); ignoring it", .{ runtime_conf, err });
        return;
    };
    config.parseBuffer(cfg, text) catch |err| {
        std.log.warn("runtime config: {t}; ignoring it", .{err});
    };
}

/// Create the runtime directory if it is not already there.
fn ensureRuntimeDir(io: std.Io) CmdError!void {
    std.Io.Dir.cwd().createDir(io, runtime_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            std.log.err("cannot create {s}: {t}", .{ runtime_dir, err });
            return error.Failed;
        },
    };
}

// ---------------------------------------------------------------- bling run ---

const spidev_bufsiz_path = "/sys/module/spidev/parameters/bufsiz";
const spidev_bufsiz_fallback: u64 = 4096;
const ssi_clk_rate_path = "/sys/kernel/debug/clk/clk_spi/clk_rate";
const latch_us = 320;
const clk_report_timeout_s = 120;
const idle_poll_hz = 2;

/// The `linux/spi/spidev.h` subset this tool drives. The request numbers are the
/// encoded `_IOC(dir, type, nr, size)` constants from the 6.x kernel headers, and
/// they are the same on aarch64 and riscv64 because both are LP64.
const Spi = struct {
    const mode_0: u8 = 0x00;
    const cs_high: u8 = 0x04; // _BITUL(2)

    const ioc_wr_mode: u32 = 0x40016b01; // _IOW('k', 1, __u8)
    const ioc_wr_bits_per_word: u32 = 0x40016b03; // _IOW('k', 3, __u8)
    const ioc_wr_max_speed_hz: u32 = 0x40046b04; // _IOW('k', 4, __u32)
    const ioc_message_1: u32 = 0x40206b00; // SPI_IOC_MESSAGE(1)

    /// struct spi_ioc_transfer. The header states that the layout is identical in
    /// 32-bit and 64-bit userspace.
    const Transfer = extern struct {
        tx_buf: u64 = 0,
        rx_buf: u64 = 0,
        len: u32 = 0,
        speed_hz: u32 = 0,
        delay_usecs: u16 = 0,
        bits_per_word: u8 = 0,
        cs_change: u8 = 0,
        tx_nbits: u8 = 0,
        rx_nbits: u8 = 0,
        word_delay_usecs: u8 = 0,
        pad: u8 = 0,
    };

    comptime {
        std.debug.assert(@sizeOf(Transfer) == 32);
    }
};

/// An ioctl on an open file. spidev reports only success or failure here, so the
/// return value carries nothing worth keeping.
fn ioctl(handle: std.Io.File.Handle, request: u32, arg: usize) error{Io}!void {
    return switch (std.os.linux.errno(std.os.linux.ioctl(handle, request, arg))) {
        .SUCCESS => {},
        else => error.Io,
    };
}

/// The latch length in bytes at a given SPI clock; each byte is 8 SPI bits. The
/// XL parts need the line held low for at least 300 us, and `latch_us` allows 320
/// for margin.
fn latchBytes(speed_hz: u32) u32 {
    return @intCast(@as(u64, latch_us) * speed_hz / 8_000_000 + 1);
}

/// The longest latch any accepted clock produces. The frame buffer is sized for
/// this, so a clock change never has to resize it.
const max_latch_bytes: u32 = @intCast(@as(u64, latch_us) * config.max_speed_hz / 8_000_000 + 1);

/// Encoded LED bytes for `cfg.count` LEDs at `cfg.encoding`, without the latch.
fn ledBytes(cfg: *const Config) u32 {
    return cfg.count * cfg.encoding.bytesPerLed();
}

/// One frame's byte length: encoded LEDs plus the actual latch at `cfg.speed_hz`.
fn frameLen(cfg: *const Config) usize {
    return ledBytes(cfg) + latchBytes(cfg.speed_hz);
}

/// The allocation size for the frame buffer: encoded LEDs plus the worst-case
/// latch, so a speed change never has to reallocate.
fn frameCapacity(cfg: *const Config) usize {
    return ledBytes(cfg) + max_latch_bytes;
}

/// Clamp `cfg.count` to what one spidev transfer accepts, and log when it does.
fn clampCount(cfg: *Config, bufsiz: u64, max_count: u32) void {
    if (cfg.count <= max_count) return;
    std.log.warn("count {d} is past the spidev bufsiz of {d}; clamping to {d}", .{
        cfg.count, bufsiz, max_count,
    });
    cfg.count = max_count;
}

fn readSpidevBufsiz(io: std.Io) u64 {
    const n = sysfs.read(u64, io, spidev_bufsiz_path) orelse return spidev_bufsiz_fallback;
    return if (n == 0) spidev_bufsiz_fallback else n;
}

/// The largest LED count whose frame still fits one spidev transfer.
///
/// A frame must go out as ONE transfer. A split puts a gap of more than 50 us in
/// the middle of the frame, and the LED chain reads that gap as a latch.
fn maxCountForBufsiz(bufsiz: u64, bytes_per_led: u32) u32 {
    if (bufsiz <= max_latch_bytes) return 1;
    const n: u32 = @intCast((bufsiz - max_latch_bytes) / bytes_per_led);
    return @max(n, 1);
}

/// Log the bit timing the controller really produces, derived from the SSI input
/// clock in debugfs and the DesignWare even-divider rule. Returns false when
/// debugfs is not mounted yet, which happens in the initrd, so the caller retries.
fn logClock(io: std.Io, cfg: *const Config) bool {
    const ssi = sysfs.read(u64, io, ssi_clk_rate_path) orelse return false;
    const div = (((ssi + cfg.speed_hz - 1) / cfg.speed_hz) + 1) & 0xfffe;
    const actual = if (div != 0) ssi / div else 0;
    const ns: u32 = if (actual != 0) @intCast(1_000_000_000 / actual) else 0;
    const bits: u32 = @intFromEnum(cfg.encoding);
    std.log.info(
        "{s} ssi_clk {d} Hz, divider {d}, actual {d} Hz, SPI bit {d} ns, {d} bits per LED bit," ++
            " T0H {d} ns, T1H {d} ns, period {d} ns",
        .{ cfg.device.slice(), ssi, div, actual, ns, bits, ns, ns * (bits - 1), ns * bits },
    );
    return true;
}

/// How long to wait for the spidev node to appear before giving up.
const spidev_wait_s = 30;

/// Open spidev and set its mode, word size, and clock.
///
/// The controller can bind after this service starts, which happens in the
/// initrd, so this waits for the node rather than failing at once. Returns null
/// when the node never appears, which tells the caller to stop cleanly, because a
/// core without an LED bus has nothing to do.
fn openSpi(io: std.Io, cfg: *const Config) ?std.Io.File {
    const dev = cfg.device.slice();

    var file: ?std.Io.File = null;
    var waited: u32 = 0;
    while (waited <= spidev_wait_s and file == null) : (waited += 1) {
        file = std.Io.Dir.cwd().openFile(io, dev, .{ .mode = .read_write }) catch |err| blk: {
            if (waited == 0) std.log.info("waiting for {s} ({t})", .{ dev, err });
            // A cancelled wait only makes the next attempt happen sooner, and the
            // loop bound still ends it, so there is nothing to recover from.
            io.sleep(.{ .nanoseconds = std.time.ns_per_s }, .awake) catch |sleep_err|
                std.log.debug("the wait for {s} was cut short: {t}", .{ dev, sleep_err });
            break :blk null;
        };
    }
    const opened = file orelse {
        std.log.warn("{s} did not appear after {d} s; giving up", .{ dev, spidev_wait_s });
        return null;
    };
    errdefer opened.close(io);

    var mode: u8 = Spi.mode_0 | (if (cfg.cs_high) Spi.cs_high else 0);
    var bits: u8 = 8;
    var speed: u32 = cfg.speed_hz;
    const settings = .{
        .{ "mode", Spi.ioc_wr_mode, @intFromPtr(&mode) },
        .{ "bits per word", Spi.ioc_wr_bits_per_word, @intFromPtr(&bits) },
        .{ "max speed", Spi.ioc_wr_max_speed_hz, @intFromPtr(&speed) },
    };
    inline for (settings) |s| {
        ioctl(opened.handle, s[1], s[2]) catch {
            std.log.err("cannot set the spidev {s} on {s}", .{ s[0], dev });
            opened.close(io);
            return null;
        };
    }
    return opened;
}

/// Send one WS2812 frame.
///
/// When `report` is set this times the transfer and warns if it took much longer
/// than its own bit count implies. That means the controller stalled and the bit
/// stream was not continuous, which is the only way to see a gap inside a frame
/// without an oscilloscope.
fn sendFrame(io: std.Io, file: std.Io.File, frame: []const u8, speed_hz: u32, report: bool) void {
    var tr: Spi.Transfer = .{
        .tx_buf = @intFromPtr(frame.ptr),
        .len = @intCast(frame.len),
        .speed_hz = speed_hz,
        .bits_per_word = 8,
    };
    const started = std.Io.Timestamp.now(io, .awake);
    const result = ioctl(file.handle, Spi.ioc_message_1, @intFromPtr(&tr));
    const took = started.durationTo(.now(io, .awake));

    if (report) {
        const took_us: u64 = @intCast(@max(@divTrunc(took.nanoseconds, std.time.ns_per_us), 0));
        const ideal_us: u64 = @as(u64, frame.len) * 8 * 1_000_000 / speed_hz;
        const args = .{ frame.len, took_us, ideal_us };
        if (ideal_us != 0 and took_us > ideal_us * 2) {
            std.log.warn("transfer of {d} bytes took {d} us against {d} us continuous;" ++
                " the controller stalled and the bit stream was not continuous", args);
        } else {
            std.log.info("transfer of {d} bytes took {d} us against {d} us continuous", args);
        }
    }
    result catch std.log.warn("the spidev transfer failed", .{});
}

/// Close any currently-open blob and open the one at `cfg.blob()` if set. Returns
/// the new `?bled.Frames`: null when no blob is configured, or when the configured
/// one is missing/short/bad-magic (logged), so the caller falls back to the
/// emergency fill. This is only ever called on start and on an mtime change, so
/// the open cost is off the hot path.
fn refreshBlob(io: std.Io, prev: ?bled.Frames, cfg: *const Config) ?bled.Frames {
    var old = prev;
    if (old) |*o| o.deinit(io);

    if (cfg.blob.isEmpty()) return null;
    const path = cfg.blob.slice();
    return bled.load(io, path) catch |err| {
        std.log.warn("blob {s}: {t}; ignoring it", .{ path, err });
        return null;
    };
}

/// Copy the first `out.len` LEDs of one blob frame into `out`, scaled by
/// brightness in software, because a WS2812 chain has no brightness byte.
///
/// `out.len` is the effective LED count: the blob's own count, or fewer when the
/// spidev buffer size clamped it, so the frame always holds at least that many.
fn paintBlobFrame(frames: *const bled.Frames, now_ms: u64, brightness: u8, out: []Rgb) void {
    const src = frames.frameAt(now_ms);
    std.debug.assert(src.len >= out.len * bled.bytes_per_led);
    for (out, 0..) |*dst, i| {
        const px = bled.Frames.pixel(src, i);
        dst.* = .{
            .r = ws2812.scaleChannel(px.r, brightness),
            .g = ws2812.scaleChannel(px.g, brightness),
            .b = ws2812.scaleChannel(px.b, brightness),
        };
    }
}

/// The `bling run` service.
///
/// The pixel source is chosen in this order: a pure-Nix pattern, then a baked
/// blob, then a dim blue fill. The fill is the emergency indicator, so a failure
/// in the sources above it stays visible but calm.
///
/// A change to the runtime file's modification time reloads the fields the CLI
/// can set and the blob and pattern paths. The static fill repaints at 2 Hz,
/// because a WS2812 chain has no error recovery of its own; a pattern and a blob
/// each run at their own rate.
///
/// The encode, the spidev write, and the latch are the same for every source, so
/// no source can make the ring flicker.
fn cmdBlingRun(
    io: std.Io,
    gpa: std.mem.Allocator,
    base: ?[]const u8,
    backend_kind: backend.Kind,
) CmdError!void {
    var cfg = try loadConfig(io, base);

    installHandler(.TERM, onStop);
    installHandler(.INT, onStop);

    const bufsiz = readSpidevBufsiz(io);
    var max_count = maxCountForBufsiz(bufsiz, cfg.encoding.bytesPerLed());

    // A valid blob sets the LED count and the frame rate, and the buffers below
    // are then sized to that geometry. A missing or bad blob leaves this null and
    // the pattern, or the fill, drives everything.
    var blob = refreshBlob(io, null, &cfg);
    defer if (blob) |*b| b.deinit(io);
    applyBlobGeometry(&cfg, blob, bufsiz, max_count);
    clampCount(&cfg, bufsiz, max_count);

    // A configured pure-Nix pattern is the highest-precedence pixel source, above
    // the blob, and it sets its own frame period. Sensor inputs refresh on a slow
    // tick, because the battery read is a median of 33 samples, while `t` is
    // current every frame. A missing, bad, or unavailable pattern gives null here
    // and the painter falls back without any further handling.
    var eval_pat: ?backend.Pattern = openEval(io, gpa, &cfg, backend_kind);
    defer if (eval_pat) |*p| p.deinit();
    var sensors: eval.Fields = .{};
    var last_sensor_ms: u64 = 0;
    var cpu_meter = screens.CpuMeter.init(io);

    // The frame buffer is sized for the longest latch, so a clock change never
    // has to reallocate it. Both buffers resize when a reload changes the count
    // or the encoding.
    var pixels = gpa.alloc(Rgb, cfg.count) catch return error.Failed;
    defer gpa.free(pixels);
    var frame = gpa.alloc(u8, frameCapacity(&cfg)) catch return error.Failed;
    defer gpa.free(frame);

    // A missing bus is a clean stop, so systemd does not start this again.
    const spi = openSpi(io, &cfg) orelse return;
    defer spi.close(io);

    var frame_len = frameLen(&cfg);
    logRunState(&cfg, blob, frame_len);

    var clk_logged = logClock(io, &cfg);
    const clk_deadline = std.Io.Timestamp.now(io, .awake)
        .addDuration(.{ .nanoseconds = clk_report_timeout_s * std.time.ns_per_s });
    if (!clk_logged)
        std.log.info("{s} cannot be read yet; the timing report follows when it appears", .{
            ssi_clk_rate_path,
        });

    var seen_mtime = confMtime(io);
    var report_timing = true;

    while (!stop_requested.load(.monotonic)) {
        if (!clk_logged) {
            clk_logged = logClock(io, &cfg);
            const now = std.Io.Timestamp.now(io, .awake);
            if (!clk_logged and now.nanoseconds > clk_deadline.nanoseconds) {
                std.log.warn("{s} never appeared; bit timing is unverified", .{ssi_clk_rate_path});
                clk_logged = true;
            }
        }

        const now_mtime = confMtime(io);
        if (!std.meta.eql(now_mtime, seen_mtime)) {
            seen_mtime = now_mtime;
            reloadInto(io, &cfg, .{ .file = spi, .bufsiz = bufsiz, .max_count = &max_count }, base);
            blob = refreshBlob(io, blob, &cfg);
            applyBlobGeometry(&cfg, blob, bufsiz, max_count);
            // Reopen the pattern on any config change. A pattern is a pure
            // function of `t`, so reopening never restarts the visible animation.
            // Only the compile is repeated, which costs a few milliseconds and
            // happens rarely.
            if (eval_pat) |*p| p.deinit();
            eval_pat = openEval(io, gpa, &cfg, backend_kind);
            last_sensor_ms = 0; // read the sensors again on the next frame
            report_timing = true;
            // Resize for a changed count or encoding. If that allocation fails,
            // keep the current geometry rather than stop the boot indicator.
            if (cfg.count != pixels.len) {
                if (gpa.realloc(pixels, cfg.count)) |p| {
                    pixels = p;
                } else |_| {
                    std.log.warn("cannot resize to {d} leds; keeping {d}", .{
                        cfg.count, pixels.len,
                    });
                    cfg.count = @intCast(pixels.len);
                }
            }
            if (frameCapacity(&cfg) != frame.len) {
                if (gpa.realloc(frame, frameCapacity(&cfg))) |f| {
                    frame = f;
                } else |_| {
                    std.log.warn("cannot resize the frame buffer; keeping the geometry", .{});
                }
            }
            frame_len = frameLen(&cfg);
            logRunState(&cfg, blob, frame_len);
        }

        const now_ms = monotonicMs(io);
        const lit = pixels[0..cfg.count];

        // A pattern that renders also sets the frame period.
        var eval_period_ns: ?u64 = null;
        if (eval_pat) |*p| {
            if (last_sensor_ms == 0 or now_ms - last_sensor_ms >= sensor_interval_ms) {
                sensors = gatherSensors(io, &cpu_meter);
                last_sensor_ms = now_ms;
            }
            var fields = sensors;
            fields.t_ms = now_ms;
            fields.width = cfg.count;
            fields.height = 1;
            fields.brightness = cfg.brightness;
            fields.backend_id = @intFromEnum(backend_kind);
            if (p.render(fields, lit)) |next_ms| {
                eval_period_ns = @as(u64, next_ms) * std.time.ns_per_ms;
            } else |_| {
                // render already logged the fault once. Close the pattern so the
                // painter falls back for good rather than fault every frame.
                p.deinit();
                eval_pat = null;
            }
        }
        if (eval_period_ns == null) {
            if (blob) |*frames| {
                paintBlobFrame(frames, now_ms, cfg.brightness, lit);
            } else {
                // With no pattern and no blob, this dim blue fill is the emergency
                // indicator: a fault above stays visible, but calm.
                @memset(lit, .{ .r = 0, .g = 8, .b = 32 });
            }
        }
        // The encode, the transfer, and the latch are the same for every source.
        ws2812.encodeFrame(cfg.encoding, lit, latchBytes(cfg.speed_hz), frame[0..frame_len]);

        sendFrame(io, spi, frame[0..frame_len], cfg.speed_hz, report_timing);
        report_timing = false;

        const period_ns: u64 = eval_period_ns orelse if (blob != null)
            std.time.ns_per_s / @as(u64, cfg.fps)
        else
            std.time.ns_per_s / idle_poll_hz;

        // Wait in slices and re-check the config's modification time in each one.
        //
        // A short button press writes the config file, and a wait of one whole
        // period delayed noticing that by up to the pattern's own frame period,
        // which is more than a second on a slow pattern. Ending the wait early
        // lets the top of the loop reload and paint the new pattern within about
        // one slice of the press.
        const slice_ns: u64 = 50 * std.time.ns_per_ms;
        var slept: u64 = 0;
        while (slept < period_ns and !stop_requested.load(.monotonic)) {
            const step = @min(slice_ns, period_ns - slept);
            io.sleep(.{ .nanoseconds = @intCast(step) }, .awake) catch break;
            slept += step;
            if (!std.meta.eql(confMtime(io), seen_mtime)) break;
        }
    }
    // Leave the LEDs lit, so a restart repaints them without a visible gap.
}

/// The runtime config's modification time, or null when the file is absent. The
/// painter watches this to notice a change without holding the file open.
fn confMtime(io: std.Io) ?std.Io.Timestamp {
    const stat = std.Io.Dir.cwd().statFile(io, runtime_conf, .{}) catch return null;
    return stat.mtime;
}

/// Milliseconds on the monotonic clock. The animation clock and every timeout in
/// this file are measured against it.
fn monotonicMs(io: std.Io) u64 {
    const now = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    return @intCast(@max(now, 0));
}

/// How often the slow sensor block is read again for the pattern's scope.
///
/// `t` updates every frame, but the battery, USB, load, CPU, memory, and uptime
/// values change on a timescale near one second, and the battery read is a median
/// of 33 samples. Reading them every frame would be wasted I/O.
const sensor_interval_ms: u64 = 1000;

// The content root and its search-path entry, so LED and OLED content can import
// a shared library. The oled command takes a `--content-root` override; the LED
// painter uses this default.
const default_content_root = "/etc/nixbadge";
const default_nix_path = "nixbadge=" ++ default_content_root;

/// Open the configured pattern, or null when none is set or the evaluator is not
/// built in. A bad pattern is logged inside `open` and also gives null, so the
/// painter falls back to the blob or the fill.
fn openEval(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: *const Config,
    kind: backend.Kind,
) ?backend.Pattern {
    if (cfg.eval.isEmpty()) return null;
    const opts = eval.Opts{ .io = io, .nix_path = default_nix_path };
    return backend.Pattern.open(gpa, opts, kind, cfg.eval.slice());
}

/// Read the slow sensor inputs for the pattern's scope. This runs on the sensor
/// tick and not every frame. The caller fills in `t`, the geometry, and the
/// brightness per frame.
fn gatherSensors(io: std.Io, cpu: *screens.CpuMeter) eval.Fields {
    const bat = sysfs.readBattery(io);
    const load = screens.readLoad(io);
    return .{
        .battery_mv = bat.millivolts orelse 0,
        .battery_pct = bat.percent orelse 0,
        .on_usb = (sysfs.readLine(io, "usb-vbus-det") orelse 0) != 0,
        .load1 = load.one,
        .cpu_pct = cpu.sample(io),
        .mem_pct = @intFromFloat(@min(screens.readMemUsedFrac(io) * 100.0 + 0.5, 100.0)),
        .uptime_s = @intCast(@min(screens.readUptimeS(io), @as(u64, std.math.maxInt(u32)))),
    };
}

/// When a blob is active it sets the effective LED count and frame rate, so the
/// buffer sizes, the encode, and the pacing all follow the baked animation. With
/// no blob the config's own count and rate stand.
fn applyBlobGeometry(cfg: *Config, blob: ?bled.Frames, bufsiz: u64, max_count: u32) void {
    const frames = blob orelse return;
    cfg.count = frames.nleds;
    cfg.fps = std.math.clamp(@as(u32, frames.fps), config.min_fps, config.max_fps);
    clampCount(cfg, bufsiz, max_count);
}

/// Log the active blob, or its absence, and the frame geometry. This runs once at
/// start and after every reload.
fn logRunState(cfg: *const Config, blob: ?bled.Frames, frame_len: usize) void {
    if (blob) |frames| {
        std.log.info("blob {s}: {d} leds, {d} fps, {d} frames, brightness {d}, {d} bytes", .{
            cfg.blob.slice(), frames.nleds, frames.fps, frames.frames, cfg.brightness, frame_len,
        });
    } else {
        std.log.info("no blob: {d} leds, brightness {d}, {d} fps, {d} bytes per frame", .{
            cfg.count, cfg.brightness, cfg.fps, frame_len,
        });
    }
}

/// Read the config again and adopt the fields the CLI can set: brightness, frame
/// rate, count, speed, encoding, and the blob and pattern paths. The device path
/// is hardware identity and is not reloaded.
///
/// A speed change is pushed to the driver. Each transfer also carries its own
/// speed, so nothing has to be reopened.
///
/// The pattern path belongs in this list: a short button press rewrites it. It was
/// once missing here, so every reload reopened the path from startup while the
/// config file moved on, which is why the button appeared to cycle back to the
/// same pattern.
fn reloadInto(io: std.Io, cfg: *Config, spi: SpiLink, base: ?[]const u8) void {
    var fresh = Config.default();
    layerBase(io, &fresh, base);
    layerRuntime(io, &fresh);

    const old_speed = cfg.speed_hz;
    cfg.brightness = fresh.brightness;
    cfg.fps = fresh.fps;
    cfg.count = fresh.count;
    cfg.speed_hz = fresh.speed_hz;
    cfg.encoding = fresh.encoding;
    cfg.blob = fresh.blob;
    cfg.eval = fresh.eval;

    spi.max_count.* = maxCountForBufsiz(spi.bufsiz, cfg.encoding.bytesPerLed());
    clampCount(cfg, spi.bufsiz, spi.max_count.*);
    if (cfg.speed_hz != old_speed) {
        var sp: u32 = cfg.speed_hz;
        ioctl(spi.file.handle, Spi.ioc_wr_max_speed_hz, @intFromPtr(&sp)) catch {
            std.log.warn("cannot set the spidev clock to {d} Hz", .{cfg.speed_hz});
        };
    }
}

/// The open spidev link and the limits its transfer size imposes. These three
/// always travel together, so a reload takes them as one value.
const SpiLink = struct {
    file: std.Io.File,
    /// The largest single transfer the spidev driver accepts.
    bufsiz: u64,
    /// The largest LED count that still fits one transfer, recomputed whenever the
    /// encoding changes.
    max_count: *u32,
};

// --------------------------------------------------------------- bling set ---

/// Each `bling set` flag and the config key it writes.
///
/// The flags share the config parser's validation rather than repeat it, so the
/// file and the command line can never accept different values for one setting.
const set_flags = [_]struct { flag: []const u8, key: []const u8 }{
    .{ .flag = "--brightness", .key = "brightness" },
    .{ .flag = "--speed-hz", .key = "speed_hz" },
    .{ .flag = "--bits", .key = "bits" },
    .{ .flag = "--fps", .key = "fps" },
    .{ .flag = "--count", .key = "count" },
    .{ .flag = "--blob", .key = "blob" },
    .{ .flag = "--eval", .key = "eval" },
};

fn cmdBlingSet(io: std.Io, out: *Out, args: []const []const u8) CmdError!void {
    var cfg = Config.default();
    // Start from what is live, so changing one field keeps the rest.
    layerRuntime(io, &cfg);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        var matched = false;
        for (set_flags) |f| {
            const value = optArg(args, &i, f.flag) orelse continue;
            config.applyKeyValue(&cfg, f.key, value) catch |err| {
                std.log.err("set {s} {s}: {t}", .{ f.flag, value, err });
                return error.Failed;
            };
            matched = true;
            break;
        }
        if (!matched) {
            std.log.err("set: unknown argument '{s}'", .{arg});
            return error.Usage;
        }
    }

    try ensureRuntimeDir(io);
    try writeRuntimeConfig(io, &cfg);

    // The running service reads the change on its next tick, so nothing here talks
    // to systemd. Report the two fields a user most often changes.
    out.w().print("brightness = {d}\n", .{cfg.brightness}) catch return error.Failed;
    out.w().print("eval = {s}\n", .{cfg.eval.slice()}) catch return error.Failed;
}

/// Match `--flag VALUE` at position `i`. On a match this advances `i` past the
/// value and returns it.
fn optArg(args: []const []const u8, i: *usize, flag: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, args[i.*], flag) and i.* + 1 < args.len) {
        i.* += 1;
        return args[i.*];
    }
    return null;
}

fn writeRuntimeConfig(io: std.Io, cfg: *const Config) CmdError!void {
    // Room for the scalar fields and the two path lines, which are store paths of
    // about 120 characters each.
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    config.writeRuntime(&w, cfg) catch return error.Failed;
    const written: std.Io.Dir.WriteFileOptions = .{
        .sub_path = runtime_conf,
        .data = w.buffered(),
    };
    std.Io.Dir.cwd().writeFile(io, written) catch |err| {
        std.log.err("cannot write {s}: {t}", .{ runtime_conf, err });
        return error.Failed;
    };
}

fn cmdBlingShow(io: std.Io, out: *Out) CmdError!void {
    var cfg = Config.default();
    layerRuntime(io, &cfg);
    const w = out.w();
    w.print("brightness = {d}\n", .{cfg.brightness}) catch return error.Failed;
    w.print("blob = {s}\n", .{cfg.blob.slice()}) catch return error.Failed;
    w.print("eval = {s}\n", .{cfg.eval.slice()}) catch return error.Failed;
}

fn cmdBling(io: std.Io, gpa: std.mem.Allocator, out: *Out, args: []const []const u8) CmdError!void {
    if (args.len < 1) return error.Usage;
    if (std.mem.eql(u8, args[0], "run")) {
        var base: ?[]const u8 = null;
        var kind: backend.Kind = .fix;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (optArg(args, &i, "--config")) |v| {
                base = v;
            } else if (optArg(args, &i, "--backend")) |v| {
                kind = parseBackendKind(v);
            } else {
                std.log.err("run: unknown argument '{s}'", .{args[i]});
                return error.Usage;
            }
        }
        return cmdBlingRun(io, gpa, base, kind);
    }
    if (std.mem.eql(u8, args[0], "set")) return cmdBlingSet(io, out, args[1..]);
    if (std.mem.eql(u8, args[0], "show")) return cmdBlingShow(io, out);
    return error.Usage;
}

// -------------------------------------------------------------------- core ---

fn cmdCore(io: std.Io, out: *Out, args: []const []const u8) CmdError!void {
    if (args.len < 1) return error.Usage;
    const w = out.w();

    if (std.mem.eql(u8, args[0], "status")) {
        return reportStrap(io, w);
    }

    const core: sysfs.Core = if (std.mem.eql(u8, args[0], "arm"))
        .arm
    else if (std.mem.eql(u8, args[0], "riscv"))
        .riscv
    else {
        std.log.err("core: expected arm, riscv or status", .{});
        return error.Usage;
    };

    sysfs.latchCore(io, core) catch |err| {
        std.log.err("cannot latch the {s} core: {t}", .{ @tagName(core), err });
        return error.Failed;
    };
    w.print("core-select latch set to {s}\n", .{@tagName(core)}) catch return error.Failed;
    try reportStrap(io, w);
    w.writeAll(
        \\
        \\/boot/fip.bin boots either core by the strap, so the latch alone selects
        \\the boot chain and no image has to be copied. Set the board switch to AUTO
        \\and reboot to start the latched core.
        \\
    ) catch return error.Failed;
}

fn reportStrap(io: std.Io, w: *std.Io.Writer) CmdError!void {
    if (sysfs.readStrap(io)) |core| {
        const bit: u8 = if (core == .riscv) 1 else 0;
        w.print("strap readback: {d} ({s})\n", .{ bit, @tagName(core) }) catch return error.Failed;
    } else {
        w.writeAll("strap readback: unavailable\n") catch return error.Failed;
    }
}

// ------------------------------------------------------------------- power ---

fn cmdPower(io: std.Io, out: *Out) CmdError!void {
    const w = out.w();

    // The VSEL system rail, through the vsel voltmeter the kernel already scales.
    if (sysfs.readVselVolts(io)) |v| {
        w.print("VSEL (system / VBUS): {d:.3} V\n", .{v}) catch return error.Failed;
    } else {
        std.log.warn("the VSEL rail is unavailable; is there a vsel iio-rescale device?", .{});
        w.writeAll("VSEL (system / VBUS): --\n") catch return error.Failed;
    }

    // The pack voltage and its percent, from the vbat channel. The pack is 3x AA
    // primaries, so there is no charging state to report.
    const bat = sysfs.readBattery(io);
    if (bat.millivolts) |mv| {
        const v = @as(f64, @floatFromInt(mv)) / 1000.0;
        if (bat.percent) |p| {
            w.print("VBAT (battery):       {d:.3} V ({d}%)\n", .{ v, p }) catch
                return error.Failed;
        } else {
            w.print("VBAT (battery):       {d:.3} V\n", .{v}) catch
                return error.Failed;
        }
    } else {
        std.log.warn("VBAT is unavailable; is there a vbat iio-rescale device?", .{});
        w.writeAll("VBAT (battery):       -- (unknown)\n") catch return error.Failed;
    }

    // The J6 external test point, through base SARADC channel 2, which has no divider.
    if (sysfs.readJ6Volts(io)) |v| {
        w.print("J6   (ext ADC):       {d:.3} V\n", .{v}) catch return error.Failed;
    } else {
        std.log.warn("J6 is unavailable; is there a base SARADC device?", .{});
        w.writeAll("J6   (ext ADC):       --\n") catch return error.Failed;
    }

    const vbus = sysfs.readLine(io, "usb-vbus-det");
    const vbus_text = if (vbus) |v| (if (v != 0) "yes" else "no") else "unknown";
    w.print("USB VBUS present:     {s}\n", .{vbus_text}) catch return error.Failed;

    const faults = [_]struct { label: []const u8, line: []const u8 }{
        .{ .label = "usb-5v:", .line = "usb-5v-fault-n" },
        .{ .label = "hdmi-5v:", .line = "hdmi-5v-fault-n" },
        .{ .label = "sd:", .line = "sd-fault-n" },
        .{ .label = "sao:", .line = "sao-fault-n" },
    };
    w.writeAll("Faults:\n") catch return error.Failed;
    for (faults) |f| {
        const v = sysfs.readLine(io, f.line);
        const text = if (v) |b| (if (b != 0) "ok" else "FAULT") else "unknown";
        w.print("  {s: <8} {s}\n", .{ f.label, text }) catch return error.Failed;
    }
}

// -------------------------------------------------------------------- mmio ---

fn cmdMmio(io: std.Io, out: *Out, args: []const []const u8) CmdError!void {
    if (args.len < 2) return error.Usage;
    const is_write = std.mem.eql(u8, args[0], "write");
    if (!is_write and !std.mem.eql(u8, args[0], "read")) {
        std.log.err("mmio: first arg must be 'read' or 'write'", .{});
        return error.Usage;
    }
    if (is_write and args.len < 3) return error.Usage;

    const addr = parseCUnsigned(args[1]) orelse {
        std.log.err("mmio: bad address '{s}'", .{args[1]});
        return error.Usage;
    };
    const val: u32 = if (is_write) blk: {
        const v = parseCUnsigned(args[2]) orelse {
            std.log.err("mmio: bad value '{s}'", .{args[2]});
            return error.Usage;
        };
        break :blk @truncate(v);
    } else 0;

    const page_size = std.heap.pageSize();
    const base = addr & ~(@as(u64, page_size) - 1);
    const offset = addr - base;

    const file = std.Io.Dir.cwd().openFile(io, "/dev/mem", .{ .mode = .read_write }) catch |err| {
        std.log.err("cannot open /dev/mem: {t}", .{err});
        return error.Failed;
    };
    defer file.close(io);

    // This mapping is made directly rather than through `std.Io`, because it must
    // be a real MAP_SHARED mapping of the device.
    //
    // `std.Io.File.createMemoryMap` falls back to reading the file into ordinary
    // memory when it cannot map it. For a register window that fallback would be
    // silently wrong: a write would land in that copy and never reach the
    // hardware, and the readback would report the value that was never written.
    const prot: std.os.linux.PROT = .{ .READ = true, .WRITE = true };
    const flags: std.os.linux.MAP = .{ .TYPE = .SHARED };
    const rc = std.os.linux.mmap(null, page_size, prot, flags, file.handle, @intCast(base));
    if (std.os.linux.errno(rc) != .SUCCESS) {
        std.log.err("cannot map the page at 0x{x}", .{base});
        return error.Failed;
    }
    const page: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(rc);
    defer std.posix.munmap(page[0..page_size]);

    const reg: *volatile u32 = @ptrFromInt(@intFromPtr(page) + offset);
    if (is_write) reg.* = val;
    // The store and the load are both volatile, which keeps the write before the
    // readback and stops either one from being optimised away.
    out.w().print("0x{x:0>8} = 0x{x:0>8}\n", .{ addr, reg.* }) catch return error.Failed;
}

/// Parse a number the way C's strtoul(s, NULL, 0) does: 0x -> hex, leading 0 ->
/// octal, else decimal. Untrusted CLI input, so overflow is a recovered null.
fn parseCUnsigned(text: []const u8) ?u64 {
    const s = std.mem.trim(u8, text, " \t");
    if (s.len == 0) return null;
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X'))
        return std.fmt.parseInt(u64, s[2..], 16) catch null;
    if (s.len >= 2 and s[0] == '0')
        return std.fmt.parseInt(u64, s[1..], 8) catch null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

// =================================================================== oled ===
//
// The oled engine: one loop, a registry of screens each a pure function of a
// per-frame snapshot. The USER button and SIGUSR1/2 advance either the LED
// pattern (by rewriting the runtime config so the running `bling run` hot-reloads
// it) or the OLED screen, so one button cycles both ring and panel.

// A cyclable OLED screen: a pure-Nix eval screen, one lambda of the shared
// `ScreenSet`, addressed by index and rendered via ScreenSet.renderOled into
// the shared eval framebuffer, then blitted. (The old computed-Zig flavour is
// gone; pure-Nix content is the only screen surface.)
const Screen = struct {
    name: []const u8,
    /// Contract v2: hidden screens are skipped by the long-press cycle and are
    /// only reachable by a direct RT-signal jump. Probed once at registry build.
    hidden: bool = false,
    /// Index into the active ScreenSet's lambdas.
    eval: usize,
};

/// A button hold of at least this long selects the next screen instead of the
/// next LED pattern.
const oled_longpress_ms = 400;

/// A button hold of at least this long changes the evaluator instead.
const backend_switch_ms = 5000;

/// The default directory of pure-Nix LED patterns that a short press cycles
/// through. `--bling-dir` overrides it.
const default_bling_dir = "/etc/nixbadge/bling.d";

/// The most LED patterns one directory can contribute to the press cycle.
const max_bling_patterns = 16;

/// Point the runtime config's `eval` line at the NEXT pattern in `dir`, and leave
/// every other line as it is, so the running service reloads only the pattern.
///
/// The directory is scanned on each press, so a file dropped in joins the cycle
/// with no restart.
fn blingNextPattern(io: std.Io, gpa: std.mem.Allocator, dir: []const u8) void {
    var paths: [max_bling_patterns][]const u8 = undefined;
    const n = collectNixScreens(io, gpa, dir, &paths, 0);
    defer for (paths[0..n]) |p| gpa.free(p);
    if (n == 0) {
        std.log.warn("oled: no LED patterns in {s}; ignoring the press", .{dir});
        return;
    }

    // Read the current path through the same parser the service uses, find it in
    // the cycle, and step past it. An absent or unknown path starts at the first.
    var current = Config.default();
    layerRuntime(io, &current);
    var next_ix: usize = 0;
    const cur = current.eval.slice();
    if (cur.len > 0) {
        for (paths[0..n], 0..) |p, i| {
            if (std.mem.eql(u8, p, cur)) {
                next_ix = (i + 1) % n;
                break;
            }
        }
    }
    const want = paths[next_ix];

    ensureRuntimeDir(io) catch return;

    var in_buf: [config_max_bytes]u8 = undefined;
    const existing = std.Io.Dir.cwd().readFile(io, runtime_conf, &in_buf) catch &[_]u8{};

    // Copy the file line by line and replace only the `eval` line, adding one when
    // the file has none.
    var out_buf: [config_max_bytes]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out_buf);
    var replaced = false;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        // splitScalar yields a trailing empty part for a file that ends in a
        // newline, which must not become a blank line of its own.
        if (line.len == 0 and lines.rest().len == 0) break;
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "eval")) {
            const after = std.mem.trimStart(u8, trimmed[4..], " \t");
            if (after.len > 0 and after[0] == '=') {
                w.print("eval = {s}\n", .{want}) catch return;
                replaced = true;
                continue;
            }
        }
        w.print("{s}\n", .{line}) catch return;
    }
    if (!replaced) w.print("eval = {s}\n", .{want}) catch return;

    const written: std.Io.Dir.WriteFileOptions = .{
        .sub_path = runtime_conf,
        .data = w.buffered(),
    };
    std.Io.Dir.cwd().writeFile(io, written) catch |err| {
        std.log.warn("oled: cannot write {s}: {t}", .{ runtime_conf, err });
        return;
    };
    std.log.info("oled: the LED pattern is now {s}", .{want});
}

/// The boot identity a screen reads as `scope.nixosVersion` and
/// `scope.kernelVersion`.
///
/// These are constant for one boot, and fix is pure and cannot call uname or read
/// a file during evaluation, so the runtime reads them once when the oled command
/// starts and copies them into every snapshot. The strings are NUL-terminated,
/// because the Nix C API backend hands them straight to the C API.
///
/// This is owned by `cmdOled` and passed by pointer rather than kept as global
/// state.
const BootInfo = struct {
    /// Long enough for a NixOS label and a kernel release.
    const max_len = 64;

    nixos_buf: [max_len:0]u8 = @splat(0),
    kernel_buf: [max_len:0]u8 = @splat(0),
    nixos_len: usize = 0,
    kernel_len: usize = 0,

    fn nixosVersion(self: *const BootInfo) [:0]const u8 {
        return self.nixos_buf[0..self.nixos_len :0];
    }

    fn kernelVersion(self: *const BootInfo) [:0]const u8 {
        return self.kernel_buf[0..self.kernel_len :0];
    }

    fn store(buf: *[max_len:0]u8, s: []const u8) usize {
        const n = @min(s.len, max_len);
        @memcpy(buf[0..n], s[0..n]);
        buf[n] = 0;
        return n;
    }

    /// Read the kernel release from uname, which is always available, and the
    /// NixOS version from the boot command line or from os-release.
    ///
    /// The `init=` store path on /proc/cmdline is the first source, because it
    /// carries the full version and /proc/cmdline exists everywhere this runs,
    /// in the initrd and after it. os-release is absent in the initrd and is only
    /// as current as whatever wrote it.
    ///
    /// The label inside that store path follows the hostname, and a hostname can
    /// itself contain dashes, so the label is taken as the first dash-separated
    /// part that starts with a digit. A NixOS label looks like
    /// `26.05.20260830.1a2b3c`.
    fn read(io: std.Io) BootInfo {
        var self: BootInfo = .{};
        const uts = std.posix.uname();
        self.kernel_len = store(&self.kernel_buf, std.mem.sliceTo(&uts.release, 0));

        var fbuf: [4096]u8 = undefined;
        self.nixos_len = store(&self.nixos_buf, blk: {
            if (std.Io.Dir.cwd().readFile(io, "/proc/cmdline", &fbuf)) |txt| {
                if (std.mem.indexOf(u8, txt, "-nixos-system-")) |i| {
                    var rest = txt[i + "-nixos-system-".len ..];
                    if (std.mem.indexOfAny(u8, rest, " /\n")) |end| rest = rest[0..end];
                    var parts = std.mem.splitScalar(u8, rest, '-');
                    var off: usize = 0;
                    while (parts.next()) |part| {
                        if (part.len > 0 and std.ascii.isDigit(part[0])) break :blk rest[off..];
                        off += part.len + 1;
                    }
                }
            } else |_| {}
            // With no label on the command line, which happens in a development
            // sandbox or a custom boot, fall back to os-release. BUILD_ID is the
            // full label and VERSION_ID is the bare release.
            if (std.Io.Dir.cwd().readFile(io, "/etc/os-release", &fbuf)) |txt| {
                inline for (.{ "BUILD_ID=", "VERSION_ID=" }) |key| {
                    var lines = std.mem.splitScalar(u8, txt, '\n');
                    while (lines.next()) |line| {
                        if (std.mem.startsWith(u8, line, key))
                            break :blk std.mem.trim(u8, line[key.len..], "\" \r");
                    }
                }
            } else |_| {}
            break :blk "";
        });
        return self;
    }
};

/// Gather the per-frame snapshot: the animation clock, the power inputs, and the
/// /proc meters. The CPU difference is tracked in `cpu` across frames.
fn oledGather(io: std.Io, cpu: *screens.CpuMeter, boot: *const BootInfo) screens.Context {
    const bat = sysfs.readBattery(io);
    const load = screens.readLoad(io);
    return .{
        .now_ms = monotonicMs(io),
        .on_usb = sysfs.readLine(io, "usb-vbus-det"),
        .strap = if (sysfs.readStrap(io)) |core| switch (core) {
            .arm => @as(u8, 1),
            .riscv => @as(u8, 2),
        } else 0,
        .battery_mv = bat.millivolts,
        .battery_pct = bat.percent,
        // The kernel scales this channel, and the rail is stiff, so the reading
        // needs no smoothing of its own.
        .vsel_mv = if (sysfs.readVselVolts(io)) |v|
            @intFromFloat(@max(v, 0.0) * 1000.0 + 0.5)
        else
            0,
        .load1 = load.one,
        .cpu_pct = cpu.sample(io),
        .mem_pct = @intFromFloat(@min(screens.readMemUsedFrac(io) * 100.0 + 0.5, 100.0)),
        .uptime_s = screens.readUptimeS(io),
        .nixos_version = boot.nixosVersion(),
        .kernel_version = boot.kernelVersion(),
    };
}

/// Button press timing carried across the sampling loop.
const PressState = struct { start_ms: u64 = 0, down: bool = false };

/// Set at shutdown to stop the button sampler thread, which is then joined.
var button_sampler_stop = std.atomic.Value(bool).init(false);

/// How often the sampler thread reads the button line.
const button_sample_ms: u64 = 15;

/// The USER-button sampler thread.
///
/// The RTC/PWR controller gives no edge interrupt for this line, so the button
/// must be sampled. Sampling from the render loop lost presses as soon as frames
/// got slow: a heavy screen spends between 250 ms and 2 s inside one evaluation,
/// nothing samples during that time, and a short press that started and ended
/// inside it could not be observed at all. A user then had to hold the button
/// until the next frame boundary.
///
/// This thread samples at a fixed rate whatever the frame rate is, and reports
/// through the same atomic flags the signal handlers set, so the loop consumes
/// them the same way. How soon the loop acts is still bounded by the evaluation
/// in flight, because it only reacts between frames, but no press is lost.
///
/// A release sets one flag by how long the button was held: a short press asks
/// for the next LED pattern, a longer one for the next screen, and the longest
/// for the other evaluator.
fn buttonSampler(io: std.Io, btn: sysfs.Button) void {
    var press: PressState = .{};
    while (!button_sampler_stop.load(.monotonic)) {
        if (btn.level()) |lvl| {
            const now_ms = monotonicMs(io);
            const pressed = lvl == 0; // the line is active-low
            if (pressed and !press.down) {
                press = .{ .start_ms = now_ms, .down = true };
            } else if (!pressed and press.down) {
                press.down = false;
                const held = now_ms - press.start_ms;
                const flag = if (held >= backend_switch_ms)
                    &want_switch_backend
                else if (held >= oled_longpress_ms)
                    &want_next_screen
                else
                    &want_next_pattern;
                flag.store(true, .monotonic);
            }
        }
        io.sleep(.{ .nanoseconds = button_sample_ms * std.time.ns_per_ms }, .awake) catch return;
    }
}

/// Wait until `deadline_ms` on the monotonic clock, and end early when a stop,
/// pattern, screen, or backend request is queued.
///
/// The deadline is the frame's START time plus its frame period, not the time
/// this call began, so the render and flush time is absorbed into the period
/// rather than added on top of it. A frame that already overran its period has a
/// deadline in the past and this returns at once.
///
/// The wait steps in small slices, so a flag the sampler thread sets partway
/// through is acted on without waiting out the rest of the period.
fn oledWait(io: std.Io, deadline_ms: u64) void {
    while (true) {
        if (eventPending()) return;
        const now_ms = monotonicMs(io);
        if (now_ms >= deadline_ms) return;
        const step: u64 = @min(button_sample_ms, deadline_ms - now_ms);
        io.sleep(.{ .nanoseconds = step * std.time.ns_per_ms }, .awake) catch return;
    }
}

// Where the current screen is remembered across reboots. The LED pattern already
// persists, because the bling service applies the runtime file over the base
// config at startup; this is the screen's equivalent.
//
// The screen is stored by NAME and not by index, so it survives a content set
// that changes shape between boots.
const oled_state_file = "/etc/nixbadge/oled.state";

/// Restore the screen that was last shown. A missing file, or a name that no
/// longer exists this boot, starts at screen 0.
fn restoreScreen(io: std.Io, active: []const Screen) usize {
    var buf: [64]u8 = undefined;
    const raw = std.Io.Dir.cwd().readFile(io, oled_state_file, &buf) catch return 0;
    const name = std.mem.trim(u8, raw, " \t\r\n");
    for (active, 0..) |s, ix| {
        if (std.mem.eql(u8, s.name, name)) return ix;
    }
    return 0;
}

/// Store the current screen name for the next boot. A write fault only loses
/// which screen was up, so it is logged rather than treated as fatal.
fn persistScreen(io: std.Io, name: []const u8) void {
    ensureRuntimeDir(io) catch return;
    var buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}\n", .{name}) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = oled_state_file, .data = line }) catch |err|
        std.log.warn("oled: cannot store the screen in {s}: {t}", .{ oled_state_file, err });
}

// Cap on the number of pure-Nix eval screens passed via `--eval-screen`. Five
// today (badapple-live + battery/load/power/clock + currentsystem); size with
// headroom so a config can add a few more without a code change. A path past the
// cap is logged and ignored.
const max_eval_screens = 16;

/// Find every `*.nix` file in `dir` and append its full path to `out`, starting at
/// `count`, then sort the appended paths by name. Returns the new count.
///
/// The paths are allocated from `gpa` and live as long as the process, because the
/// oled loop holds them until it exits. The number of paths is bounded by
/// `out.len`, and a directory with more screens than fit is logged and truncated
/// rather than silently cut short.
///
/// Sorting by name is what a `NN-` numeric prefix on a filename uses to set the
/// cycle order. Every path here shares the same directory prefix, so sorting the
/// full paths orders them by basename.
fn collectNixScreens(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: []const u8,
    out: [][]const u8,
    count: usize,
) usize {
    var handle = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch |err| {
        std.log.warn("oled: cannot read screen directory {s} ({t}); ignoring it", .{ dir, err });
        return count;
    };
    defer handle.close(io);

    var c = count;
    var it = handle.iterate();
    while (it.next(io) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".nix")) continue;
        if (c >= out.len) {
            std.log.warn("oled: {s} holds over {d} screens; dropping the rest", .{ dir, out.len });
            break;
        }
        // The entry name is only valid until the next `next` call, so allocPrint
        // copies it into a path of its own.
        out[c] = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, entry.name }) catch break;
        c += 1;
    }
    std.mem.sort([]const u8, out[count..c], {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return c;
}

/// How long to wait for a predecessor to release the panel.
const predecessor_wait_ms = 1000;

/// Take the panel from a predecessor that is still running.
///
/// The initrd boot splash survives the switch to the real root and keeps painting
/// while THIS instance compiles its screens, which is what keeps the panel lit
/// through a slow start. Its pid comes across in the pid file. Signal it to stop
/// and wait for the bus to free.
///
/// Nothing here is fatal: no pid file, a pid that is already gone, or this
/// process's own pid from a restart all mean there is nothing to take over from.
fn killPredecessor(io: std.Io) void {
    var buf: [32]u8 = undefined;
    const txt = std.Io.Dir.cwd().readFile(io, oled_pidfile, &buf) catch return;
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, txt, " \n\r"), 10) catch return;
    if (pid <= 0 or pid == std.os.linux.getpid()) return;

    // A stale pid file can name a pid the kernel has since given to something
    // else, so confirm the process is a nix-badge before signalling it.
    var comm_path_buf: [48]u8 = undefined;
    var comm_buf: [32]u8 = undefined;
    const comm_path = std.fmt.bufPrint(&comm_path_buf, "/proc/{d}/comm", .{pid}) catch return;
    const comm = std.Io.Dir.cwd().readFile(io, comm_path, &comm_buf) catch return;
    if (!std.mem.startsWith(u8, comm, "nix-badge")) return;

    // An ESRCH here means the process is already gone, which is the wanted state.
    std.posix.kill(pid, .TERM) catch return;
    const step_ms = 50;
    var waited: u32 = 0;
    while (waited < predecessor_wait_ms) : (waited += step_ms) {
        // Signal 0 tests only whether the process still exists.
        std.posix.kill(pid, @enumFromInt(0)) catch return;
        io.sleep(.{ .nanoseconds = step_ms * std.time.ns_per_ms }, .awake) catch return;
    }
    std.log.warn("oled: predecessor pid {d} is still running; taking the panel anyway", .{pid});
}

fn cmdOled(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8) CmdError!void {
    // Read the boot identity before anything gathers a snapshot; the probe render
    // that builds the registry already reads it.
    const boot = BootInfo.read(io);

    // `--eval-screen PATH` can be repeated, and each one adds a screen. They are
    // compiled into ONE shared evaluator, so the value heap is paid for once
    // rather than once per screen.
    var eval_screen_paths: [max_eval_screens][]const u8 = undefined;
    var eval_screen_count: usize = 0;
    var oled_width: u16 = oled.default_width;
    var oled_height: u16 = oled.default_height;
    // The USER button line, named as the device tree names it. `btn-boot-n` is
    // deliberately not the default, so the bootswap daemon can own that line. A
    // name the device tree does not expose leaves the button absent, and then only
    // the signals change the screen.
    var button_name: []const u8 = "user-btn";
    // The evaluator to start with. A long button hold changes it, and that choice
    // persists across restarts.
    var backend_kind: backend.Kind = .fix;
    // The root of the search path, so a screen can import a shared library.
    var content_root: []const u8 = default_content_root;
    // The directory the short-press pattern cycle scans.
    var bling_dir: []const u8 = default_bling_dir;
    // The evaluator's collection line in bytes, where 0 keeps its own default. See
    // `eval.Opts.gc_budget_bytes` for why the badge sets this.
    var gc_budget_bytes: u64 = 0;
    // Which panel controller drives the display. `auto` probes at open.
    var oled_controller: oled.ControllerChoice = .auto;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (optArg(args, &i, "--backend")) |v| {
            backend_kind = parseBackendKind(v);
        } else if (optArg(args, &i, "--content-root")) |v| {
            content_root = v;
        } else if (optArg(args, &i, "--bling-dir")) |v| {
            bling_dir = v;
        } else if (optArg(args, &i, "--gc-budget-mb")) |v| {
            const mb = std.fmt.parseInt(u32, v, 10) catch {
                std.log.err("oled: bad --gc-budget-mb '{s}'", .{v});
                return error.Usage;
            };
            gc_budget_bytes = @as(u64, mb) << 20;
        } else if (optArg(args, &i, "--oled-controller")) |v| {
            oled_controller = std.meta.stringToEnum(oled.ControllerChoice, v) orelse {
                std.log.err("oled: bad --oled-controller '{s}' (auto, ssd1306, or sh1106)", .{v});
                return error.Usage;
            };
        } else if (optArg(args, &i, "--eval-dir")) |v| {
            // Add every screen in a directory, sorted by name. These come after any
            // `--eval-screen` already collected.
            eval_screen_count =
                collectNixScreens(io, gpa, v, &eval_screen_paths, eval_screen_count);
        } else if (optArg(args, &i, "--eval-screen")) |v| {
            if (eval_screen_count < max_eval_screens) {
                eval_screen_paths[eval_screen_count] = v;
                eval_screen_count += 1;
            } else {
                std.log.warn(
                    "oled: too many --eval-screen (>{d}); ignoring {s}",
                    .{ max_eval_screens, v },
                );
            }
        } else if (optArg(args, &i, "--button")) |v| {
            button_name = v;
        } else if (optArg(args, &i, "--oled-width")) |v| {
            oled_width = std.fmt.parseInt(u16, v, 10) catch {
                std.log.err("oled: bad --oled-width '{s}'", .{v});
                return error.Usage;
            };
        } else if (optArg(args, &i, "--oled-height")) |v| {
            oled_height = std.fmt.parseInt(u16, v, 10) catch {
                std.log.err("oled: bad --oled-height '{s}'", .{v});
                return error.Usage;
            };
        } else {
            std.log.err("oled: unknown argument '{s}'", .{args[i]});
            return error.Usage;
        }
    }

    // The panel is optional hardware, and it is opened first so its geometry is
    // known, because that sizes the shared framebuffer below. A missing bus, a bad
    // size, and a failed allocation all mean "no panel", and this exits 0 so
    // systemd does not start it again.
    var panel = oled.Panel.open(io, gpa, oled_width, oled_height, oled_controller) orelse {
        std.log.warn("oled: no panel; nothing to do", .{});
        return;
    };
    defer panel.close();

    // Probe before standing up the evaluator, whose heap is tens of megabytes. An
    // absent panel does not acknowledge the probe write, so a board with no
    // display exits here and never pays for that heap.
    //
    // The probe changes no display state on purpose, and `init` is NOT run yet: the
    // initrd boot splash may still be painting the panel, and it keeps painting
    // through the long compile below. The real init runs once killPredecessor has
    // taken the panel over.
    panel.probe() catch {
        std.log.warn("oled: nothing answered at 0x{x:0>2}; no evaluator started", .{oled.i2c_addr});
        return;
    };

    // Every screen path is compiled into ONE shared evaluator. A screen that fails
    // to compile is skipped and the rest still load. If none load, the daemon has
    // nothing to show and exits below.
    //
    // These options are held at function scope, because the backend change further
    // down reopens the set with them.
    var nix_path_buf: [512]u8 = undefined;
    const nix_path = std.fmt.bufPrint(&nix_path_buf, "nixbadge={s}", .{content_root}) catch
        default_nix_path;
    const eval_opts = eval.Opts{
        .io = io,
        .nix_path = nix_path,
        .gc_budget_bytes = if (gc_budget_bytes > 0) gc_budget_bytes else null,
    };

    var eval_set: ?backend.ScreenSet = null;
    var eval_fb: ?[]u8 = null;
    if (eval_screen_count > 0) {
        // A backend chosen at runtime persists, so it wins over the default.
        backend_kind = restoreBackend(io, backend_kind);
        const wanted = eval_screen_paths[0..eval_screen_count];
        if (backend.ScreenSet.open(gpa, eval_opts, backend_kind, wanted)) |s| {
            const fb = gpa.alloc(u8, @as(usize, panel.width) * (panel.height / 8)) catch blk: {
                std.log.warn("oled: cannot allocate the framebuffer; dropping the screens", .{});
                break :blk null;
            };
            if (fb) |b| {
                eval_set = s;
                eval_fb = b;
                backend_kind = s.kind(); // report the backend `open` actually chose
            } else {
                var dead = s;
                dead.deinit();
            }
        }
    }
    defer if (eval_set) |*s| s.deinit();
    defer if (eval_fb) |b| gpa.free(b);

    // Build the screen registry. Screen content is pure Nix, so with no screens
    // loaded there is nothing to show, and the daemon exits 0 rather than let
    // systemd start it again with the same result.
    var registry: [max_eval_screens]Screen = @splat(.{ .name = "", .eval = 0 });
    // A minimal scope for the probe that reads each screen's `hidden` flag.
    const probe_fields = eval.Fields{ .width = panel.width, .height = panel.height };
    const set_for_registry = if (eval_set) |*s| s else {
        std.log.err("oled: no screens loaded; nothing to show", .{});
        return;
    };
    var active_screens = buildEvalRegistry(&registry, set_for_registry, probe_fields);

    // The screens are compiled, so take the panel now: stop the boot splash that
    // kept it painted through the compile above, then run the real init and clear.
    // The panel is dark only for the time between that splash's last write and the
    // first frame here, not for the whole compile.
    killPredecessor(io);
    panel.init() catch {
        std.log.warn("oled: init failed at 0x{x:0>2} after taking the panel", .{oled.i2c_addr});
        return;
    };

    installHandler(.TERM, onStop);
    installHandler(.INT, onStop);
    installHandler(.USR1, onUser);
    installHandler(.USR2, onUser);
    // The screen-control signals; see the notes at `sig_jump_base`.
    {
        var sn: u32 = 0;
        while (sn < sig_jump_count) : (sn += 1)
            installHandler(@enumFromInt(sig_jump_base + sn), onJump);
        installHandler(@enumFromInt(sig_swapcore), onJump);
    }
    // Publish the pid, so a peer can signal this daemon without systemctl, which
    // would pull its whole closure into the image.
    {
        var pid_buf: [16]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&pid_buf, "{d}\n", .{std.os.linux.getpid()}) catch "";
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = oled_pidfile, .data = pid_str }) catch |err|
            std.log.warn("oled: cannot write {s} ({t}); peers cannot find it", .{
                oled_pidfile, err,
            });
    }

    // Request the button once and hand it to the sampler thread. See buttonSampler
    // for why sampling inside the render loop could not work. With no such line the
    // button is absent and only the signals change the screen.
    var button = sysfs.Button.open(io, button_name);
    defer if (button) |*b| b.close();
    if (button == null)
        std.log.info("oled: no button named '{s}'; the control signals still work", .{button_name});
    const button_thread: ?std.Thread = if (button) |btn|
        std.Thread.spawn(.{}, buttonSampler, .{ io, btn }) catch |err| blk: {
            std.log.warn("oled: cannot start the button sampler ({t}); signals still work", .{err});
            break :blk null;
        }
    else
        null;
    defer if (button_thread) |t| {
        button_sampler_stop.store(true, .monotonic);
        t.join();
    };

    std.log.info("oled is up on {s} at 0x{x:0>2} with {d} screens, starting on {s}", .{
        oled.i2c_bus, oled.i2c_addr, active_screens.len, active_screens[0].name,
    });

    var screen_ix: usize = restoreScreen(io, active_screens);
    // Never resume on a hidden screen, which is transient by definition.
    if (screen_ix < active_screens.len and active_screens[screen_ix].hidden) screen_ix = 0;
    if (screen_ix != 0)
        std.log.info("oled: resuming on screen {s}", .{active_screens[screen_ix].name});
    // Where an auto-return goes back to, and when the current screen was entered.
    var prev_screen_ix: usize = 0;
    var screen_entered_ms: u64 = monotonicMs(io);
    var cpu = screens.CpuMeter.init(io);
    var flush_fail_count: u32 = 0;

    // The frame-rate window. The achieved rate is logged once per window rather
    // than once per frame, and the evaluation and flush times are summed alongside
    // it, so the log shows where the frame budget goes: the evaluator or the bus.
    var fps_frames: u64 = 0;
    var fps_win_ms: u64 = 0;
    var eval_ns_sum: i128 = 0;
    var flush_ns_sum: i128 = 0;
    // The last window's rate, carried into `scope.fps` every frame so a screen can
    // draw it. It is 0 until the first window closes.
    var last_fps: u32 = 0;

    // The sensors move on a human timescale, not a per-frame one. Reading them
    // every frame cost about 15 ms per frame, which was the real ceiling near 46
    // frames per second. Neither the evaluation, at about 1 ms, nor the flush, at
    // about 5 ms, was the limit, which is why raising the bus clock changed
    // nothing. They refresh on a slow tick and the snapshot is carried between
    // refreshes; only the clock updates every frame.
    const sensor_refresh_ms: u64 = 500;

    // How long one frame-rate window lasts before it is logged and reset.
    const fps_window_ms: u64 = 3000;
    var ctx = oledGather(io, &cpu, &boot);
    var last_gather_ms: u64 = ctx.now_ms;
    // Battery EMA across gathers: a median-of-33 rejects single-read SPIKES but the
    // leaky-divider SARADC also WANDERS slowly (temperature/load), so back-to-back
    // 500 ms snapshots still jump visibly. Blend at alpha=0.25 (~2 s time constant)
    // and derive percent from the SMOOTHED millivolts so both readouts agree.
    var bat_mv_ema: ?f64 = if (ctx.battery_mv) |mv| @floatFromInt(mv) else null;

    while (!stop_requested.load(.monotonic)) {
        const now_ms = monotonicMs(io);
        if (now_ms - last_gather_ms >= sensor_refresh_ms) {
            ctx = oledGather(io, &cpu, &boot);
            last_gather_ms = now_ms;
            if (ctx.battery_mv) |mv| {
                const fresh: f64 = @floatFromInt(mv);
                const ema = if (bat_mv_ema) |prev| prev * 0.75 + fresh * 0.25 else fresh;
                bat_mv_ema = ema;
                const smoothed: u64 = @intFromFloat(ema + 0.5);
                ctx.battery_mv = @intCast(smoothed);
                ctx.battery_pct = sysfs.percentFromMv(smoothed);
            }
        }
        ctx.now_ms = now_ms;
        const cur = active_screens[screen_ix];
        // Render the current screen into the shared framebuffer and copy it to the
        // panel. A null result means the screen faulted, so it is dropped by name
        // and the loop continues on the screens that remain. renderOled logs the
        // fault once, so this cannot fill the log.
        const set_ptr = if (eval_set) |*s| s else null;
        const eval_started = std.Io.Timestamp.now(io, .awake);
        const rendered = renderScreen(.{
            .screen = cur,
            .panel = &panel,
            .ctx = &ctx,
            .set = set_ptr,
            .fb = eval_fb,
            .backend_id = @intFromEnum(backend_kind),
            .fps = last_fps,
        }) orelse blk: {
            active_screens = dropScreen(active_screens, cur.name, &screen_ix);
            std.log.warn("oled: dropped screen '{s}' after it failed to render", .{cur.name});
            break :blk eval.OledFrame{ .next_ms = idle_next_ms, .dirty = .{ .full = true } };
        };
        const eval_ended = std.Io.Timestamp.now(io, .awake);

        // A delta frame flushes only its changed columns, a few dozen bytes, while
        // a full frame flushes the whole panel. That partial flush is what fits a
        // 60 frames per second animation into the bus bandwidth.
        if (flushDirty(&panel, rendered.dirty)) |_| {
            if (flush_fail_count > 0) {
                // The bus has come back after a run of failures. A panel that was
                // moved or re-powered wakes in its reset state with the display
                // off, so flushes alone would land on a dark panel. Probe, init,
                // and redraw once, now that writes are getting through.
                std.log.info("oled: the bus recovered after {d} failures", .{flush_fail_count});
                if (panel.redetect())
                    std.log.info("oled: the controller changed during recovery", .{});
                panel.init() catch |err|
                    std.log.warn("oled: init failed during recovery: {t}", .{err});
                panel.flush() catch |err|
                    std.log.warn("oled: the redraw after recovery failed: {t}", .{err});
            }
            flush_fail_count = 0;
        } else |_| {
            // Recover a panel that fell off the bus, after a brown-out or a module
            // reset. One failure is transient noise, but a RUN of them means the
            // controller lost its configuration, so run init again and redraw. The
            // retry happens on every eighth failure, which paces the attempts by
            // the frame loop rather than repeating them against a dead bus.
            flush_fail_count += 1;
            if (flush_fail_count == 1) std.log.warn("oled: a flush failed", .{});
            if (flush_fail_count % 8 == 0) {
                std.log.warn("oled: {d} flushes failed in a row; re-init", .{flush_fail_count});
                // A panel swap drops the bus first, so a recovery is exactly when a
                // different controller may now be fitted. Probe before init; a probe
                // on a dead bus keeps the last known controller.
                if (panel.redetect())
                    std.log.info("oled: the controller changed during recovery", .{});
                if (panel.init()) |_| {
                    panel.flush() catch |err|
                        std.log.warn("oled: the redraw after init failed: {t}", .{err});
                } else |_| {}
            }
        }
        const flush_ended = std.Io.Timestamp.now(io, .awake);

        // The frame rate over one window, measured before the wait so it reports
        // the rate actually achieved whether the loop is bound by rendering or by
        // waiting, along with how the frame time split between the two.
        fps_frames += 1;
        eval_ns_sum += eval_started.durationTo(eval_ended).nanoseconds;
        flush_ns_sum += eval_ended.durationTo(flush_ended).nanoseconds;
        if (fps_win_ms == 0) fps_win_ms = ctx.now_ms;
        if (ctx.now_ms - fps_win_ms >= fps_window_ms) {
            const denom = @as(i128, @intCast(fps_frames)) * std.time.ns_per_ms;
            const eval_ms = @divTrunc(eval_ns_sum, denom);
            const flush_ms = @divTrunc(flush_ns_sum, denom);
            // Collection time is part of the evaluation time, because it runs
            // inside the render. It is reported separately, so the evaluation time
            // minus it is the per-frame apply and decode cost.
            const collect_ms = if (eval_set) |*s| @divTrunc(s.takeCollectNs(), denom) else 0;
            last_fps = @intCast(fps_frames * 1000 / (ctx.now_ms - fps_win_ms));
            // This is logged at debug level rather than info on purpose. It repeats
            // every window for as long as the daemon runs, and the panel can be
            // wired as a console, where an info line would fill the terminal and
            // make it unusable. The same numbers reach a screen through `scope.fps`.
            std.log.debug("oled: {d} fps [{s}] ({s}) eval~{d}ms gc~{d}ms flush~{d}ms rss~{d}MB", .{
                last_fps,                 backendName(backend_kind), cur.name,
                eval_ms,                  collect_ms,                flush_ms,
                readSelfRssKb(io) / 1024,
            });
            fps_frames = 0;
            fps_win_ms = ctx.now_ms;
            eval_ns_sum = 0;
            flush_ns_sum = 0;
        }

        // Limit the rate against the frame's START time, so the period is the whole
        // frame period rather than that period added on top of the render and flush
        // time, which would halve the achieved rate. A frame that already overran
        // its period passes straight through.
        oledWait(io, ctx.now_ms + rendered.next_ms);

        if (want_next_pattern.swap(false, .monotonic)) blingNextPattern(io, gpa, bling_dir);
        if (want_next_screen.swap(false, .monotonic)) {
            // The button cycle skips hidden screens, which are only reachable by a
            // direct signal. The walk is bounded, so a set where every screen is
            // hidden stays put instead of looping forever.
            var steps: usize = 0;
            var ix = screen_ix;
            while (steps < active_screens.len) : (steps += 1) {
                ix = (ix + 1) % active_screens.len;
                if (!active_screens[ix].hidden) break;
            }
            if (ix != screen_ix) {
                prev_screen_ix = screen_ix;
                screen_ix = ix;
                screen_entered_ms = ctx.now_ms;
                persistScreen(io, active_screens[screen_ix].name);
                std.log.info("oled: screen -> {s}", .{active_screens[screen_ix].name});
            }
        }
        // RT-signal jumps: 40+N -> screen N; 56 -> the "swapcore" screen. Direct
        // jumps reach hidden screens; transient (hidden) targets are not persisted
        // so a reboot never lands on one.
        const jump = want_jump.swap(jump_none, .monotonic);
        if (jump != jump_none) {
            const target: ?usize = if (jump == jump_swapcore)
                findScreenContaining(active_screens, "swapcore")
            else if (jump >= 0 and @as(usize, @intCast(jump)) < active_screens.len)
                @as(usize, @intCast(jump))
            else
                null;
            if (target) |tix| {
                if (tix != screen_ix) {
                    prev_screen_ix = screen_ix;
                    screen_ix = tix;
                    screen_entered_ms = ctx.now_ms;
                    if (!active_screens[tix].hidden) persistScreen(io, active_screens[tix].name);
                    std.log.info("oled: jump -> {s}", .{active_screens[tix].name});
                }
            } else std.log.warn("oled: jump signal for unknown screen ({d})", .{jump});
        }
        // Contract-v2 auto-return: a transient screen's frames carry autoReturnMs;
        // once we have been on it that long, bounce back to the screen we came from.
        if (rendered.auto_return_ms > 0 and
            ctx.now_ms - screen_entered_ms >= rendered.auto_return_ms and
            prev_screen_ix < active_screens.len and prev_screen_ix != screen_ix)
        {
            screen_ix = prev_screen_ix;
            screen_entered_ms = ctx.now_ms;
            std.log.info("oled: auto-return -> {s}", .{active_screens[screen_ix].name});
        }
        // A >5 s hold flips the evaluator backend live: tear down the current ScreenSet and
        // reopen the SAME screens on the other backend (a recompile; a brief freeze is fine).
        // The registry names point into the set's storage, so rebuild it after reopen. Only
        // meaningful when eval screens are active AND the other backend is available.
        if (want_switch_backend.swap(false, .monotonic)) {
            if (eval_set) |*s| {
                const cur_kind = s.kind();
                const new_kind: backend.Kind = if (cur_kind == .fix) .nix else .fix;
                const keep = active_screens[screen_ix].name; // try to stay on this screen
                var keep_buf: [64]u8 = undefined;
                const keep_name = if (keep.len <= keep_buf.len) blk: {
                    @memcpy(keep_buf[0..keep.len], keep);
                    break :blk keep_buf[0..keep.len];
                } else keep;
                std.log.info("oled: backend {s} -> {s} (recompiling {d} screens)", .{
                    backendName(cur_kind), backendName(new_kind), eval_screen_count,
                });
                s.deinit();
                const wanted = eval_screen_paths[0..eval_screen_count];
                eval_set = backend.ScreenSet.open(gpa, eval_opts, new_kind, wanted) orelse
                    backend.ScreenSet.open(gpa, eval_opts, cur_kind, wanted);
                if (eval_set) |*ns| {
                    backend_kind = ns.kind();
                    persistBackend(io, backend_kind);
                    active_screens = buildEvalRegistry(&registry, ns, probe_fields);
                    screen_ix = findScreen(active_screens, keep_name) orelse 0;
                    prev_screen_ix = 0;
                    screen_entered_ms = ctx.now_ms;
                    std.log.info("oled: backend now [{s}]", .{backendName(backend_kind)});
                } else {
                    std.log.err("oled: backend switch lost the eval screens; stopping", .{});
                    break;
                }
            }
        }
    }

    // Leave the panel dark on a clean stop; a flush fault here is only cosmetic
    // (we are exiting anyway), so log it rather than fail the exit.
    panel.blankOff() catch |err| std.log.warn("oled: cannot blank the panel on exit: {t}", .{err});
}

/// Remove the screen named `name` from `active` in place (shifting the tail down
/// over the backing array) and return the shortened slice. `cur_ix` is fixed up
/// so it still points at a live screen: unchanged if before the removed one,
/// decremented if at or after it, and clamped so it never indexes past the end.
/// A name not present (or an empty result) returns the slice untouched.
fn dropScreen(active: []Screen, name: []const u8, cur_ix: *usize) []Screen {
    var found: ?usize = null;
    for (active, 0..) |s, ix| {
        if (std.mem.eql(u8, s.name, name)) {
            found = ix;
            break;
        }
    }
    const rm = found orelse return active;
    if (active.len <= 1) return active; // never drop the last screen -> empty set
    std.mem.copyForwards(Screen, active[rm .. active.len - 1], active[rm + 1 ..]);
    const shorter = active[0 .. active.len - 1];
    if (cur_ix.* > rm) cur_ix.* -= 1;
    if (cur_ix.* >= shorter.len) cur_ix.* = 0;
    return shorter;
}

/// Everything one render needs. These travel together on every call, so they are
/// one parameter rather than seven.
const RenderRequest = struct {
    screen: Screen,
    panel: *oled.Panel,
    ctx: *const screens.Context,
    set: ?*backend.ScreenSet,
    fb: ?[]u8,
    backend_id: u8,
    fps: u32,
};

/// The frame period used when a render cannot happen at all, in milliseconds. It
/// keeps the loop turning without spending the whole budget on a screen that is
/// producing nothing.
const idle_next_ms: u32 = 100;

/// Render the current screen and return its frame period and dirty region, or null
/// when the screen faulted, which makes the caller drop it.
///
/// The screen renders into the shared framebuffer, which a delta screen changes in
/// place, and that buffer is then copied to the panel. The dirty region it returns
/// is what lets the caller flush only part of the panel.
fn renderScreen(req: RenderRequest) ?eval.OledFrame {
    // The set and the framebuffer are created together before the loop starts, and
    // the daemon exits when no screens load, so one of them missing here is a bug
    // rather than a runtime fault. Idle instead of stopping the daemon.
    const s = req.set orelse return .{ .next_ms = idle_next_ms, .dirty = .{ .full = true } };
    const b = req.fb orelse return .{ .next_ms = idle_next_ms, .dirty = .{ .full = true } };
    const fields = evalFields(req.panel, req.ctx, req.backend_id, req.fps);
    const r = s.renderOled(req.screen.eval, fields, b) catch return null;
    req.panel.blit(b);
    return r;
}

/// Push a rendered frame's dirty region to the panel: the whole panel for a full
/// frame (keyframe / full-frame screen), else only the changed column span of each
/// dirty page (a few dozen bytes at 60 fps Bad Apple). Clamped to the panel's page
/// count so a `Dirty` sized for 64 rows is safe on a 32-row panel.
fn flushDirty(panel: *oled.Panel, dirty: eval.Dirty) !void {
    if (dirty.full) return panel.flush();
    const pages = @min(panel.pages(), @as(u16, eval.Dirty.max_pages));
    // The changed bitmap holds 128 columns; cap the scan so colBit never shifts >= 128
    // (SSD1306 panels are <= 128 wide, so this only guards a misconfiguration).
    const width = @min(panel.width, @as(u16, 128));
    // Merge two changed-runs separated by <= this many unchanged columns into one
    // flush: re-sending a few clean bytes is cheaper than a fresh addressing command +
    // I2C transaction (~2 syscalls, tens of us of bus framing). 8 columns of data at
    // 400 kHz (~0.18 ms) is well under that, so coalescing small gaps is a net win.
    const gap_merge: u16 = 8;
    var p: u16 = 0;
    while (p < pages) : (p += 1) {
        const bits = dirty.changed[p];
        if (bits == 0) continue;
        // Walk the columns, flushing each run of changed columns (small gaps absorbed).
        var col: u16 = 0;
        while (col < width and (bits & colBit(col)) == 0) col += 1;
        if (col >= width) continue;
        var run_start = col;
        var run_end = col;
        col += 1;
        while (col < width) : (col += 1) {
            if (bits & colBit(col) == 0) continue;
            if (col - run_end <= gap_merge) {
                run_end = col; // absorb the small gap into the current run
            } else {
                try panel.flushPageSpan(p, run_start, run_end);
                run_start = col;
                run_end = col;
            }
        }
        try panel.flushPageSpan(p, run_start, run_end);
    }
}

/// One-bit mask for column `c` in a `Dirty.changed` page bitmap (c < 128).
inline fn colBit(c: u16) u128 {
    return @as(u128, 1) << @intCast(c);
}

/// Build the per-frame `Fields` an eval screen's scope wants from the snapshot the
/// loop already gathered. `t_ms`/width/height are per-frame; the sensor block is
/// carried in `ctx`. Brightness is not applied on the 1-bit panel.
fn evalFields(
    panel: *const oled.Panel,
    ctx: *const screens.Context,
    backend_id: u8,
    fps: u32,
) eval.Fields {
    return .{
        .t_ms = ctx.now_ms,
        .width = panel.width,
        .height = panel.height,
        .battery_mv = ctx.battery_mv orelse 0,
        .battery_pct = ctx.battery_pct orelse 0,
        .on_usb = ctx.on_usb == 1,
        .load1 = ctx.load1,
        .cpu_pct = ctx.cpu_pct,
        .mem_pct = ctx.mem_pct,
        .uptime_s = @intCast(@min(ctx.uptime_s, @as(u64, std.math.maxInt(u32)))),
        .backend_id = backend_id,
        .fps = fps,
        .strap = ctx.strap,
        .vsel_mv = ctx.vsel_mv,
        .nixos_version = ctx.nixos_version,
        .kernel_version = ctx.kernel_version,
    };
}

/// Rebuild the screen registry from an eval screen set: one `.eval` entry per lambda, named
/// by the set's (basename) names. Returns the active slice. Used at startup and after a live
/// backend switch (the names point into the set's storage, so they must be rebuilt).
fn buildEvalRegistry(registry: []Screen, s: *backend.ScreenSet, probe: eval.Fields) []Screen {
    var n: usize = 0;
    const cnt = @min(s.count(), registry.len);
    while (n < cnt) : (n += 1) registry[n] = .{
        .name = s.name(n),
        // One probe apply per screen reads the contract-v2 `hidden` flag (and
        // warms the screen's first frame as a side effect).
        .hidden = s.probeHidden(n, probe),
        .eval = n,
    };
    return registry[0..n];
}

/// Index of the screen named `name` in `active`, or null if absent.
fn findScreen(active: []const Screen, name: []const u8) ?usize {
    for (active, 0..) |s, ix| {
        if (std.mem.eql(u8, s.name, name)) return ix;
    }
    return null;
}

/// Index of the first screen whose name CONTAINS `frag` (the RT jump-by-role
/// lookup, e.g. "swapcore" matching "90-swapcore"), or null.
fn findScreenContaining(active: []const Screen, frag: []const u8) ?usize {
    for (active, 0..) |s, ix| {
        if (std.mem.indexOf(u8, s.name, frag) != null) return ix;
    }
    return null;
}

// Where the evaluator chosen at runtime is remembered across restarts, in the same
// way the screen is. It is stored by name.
const backend_state_file = "/etc/nixbadge/oled.backend";

/// Restore the evaluator last chosen at runtime, or `fallback` when nothing was
/// stored. A stored name the build does not have still ends up on fix, because
/// `open` falls back, so any stored value is safe to honour.
fn restoreBackend(io: std.Io, fallback: backend.Kind) backend.Kind {
    var buf: [16]u8 = undefined;
    const raw = std.Io.Dir.cwd().readFile(io, backend_state_file, &buf) catch return fallback;
    const name = std.mem.trim(u8, raw, " \t\r\n");
    return std.meta.stringToEnum(backend.Kind, name) orelse fallback;
}

/// Store the current evaluator for the next start. A write fault only loses which
/// evaluator was in use, so it is logged rather than treated as fatal.
fn persistBackend(io: std.Io, kind: backend.Kind) void {
    ensureRuntimeDir(io) catch return;
    var buf: [16]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}\n", .{backendName(kind)}) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = backend_state_file, .data = line }) catch |err|
        std.log.warn("oled: cannot store the backend in {s}: {t}", .{ backend_state_file, err });
}

/// This process's resident set size in KiB, from /proc/self/status. The frame-rate
/// log reports it, so an evaluator's memory cost is visible next to its frame
/// rate. A read or parse fault gives 0.
fn readSelfRssKb(io: std.Io) u64 {
    var buf: [4096]u8 = undefined;
    const raw = std.Io.Dir.cwd().readFile(io, "/proc/self/status", &buf) catch return 0;
    return parseVmRssKb(raw) orelse 0;
}

/// Parse the `VmRSS` value out of a /proc/self/status body. This is separate from
/// the read above so it can be tested without /proc.
fn parseVmRssKb(status: []const u8) ?u64 {
    var lines = std.mem.tokenizeScalar(u8, status, '\n');
    while (lines.next()) |line| {
        const rest = stripPrefix(line, "VmRSS:") orelse continue;
        var toks = std.mem.tokenizeAny(u8, rest, " \t");
        const num = toks.next() orelse return null;
        return std.fmt.parseInt(u64, num, 10) catch null;
    }
    return null;
}

fn stripPrefix(s: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, s, prefix)) return s[prefix.len..];
    return null;
}

// ================================================================= bootswap ===
//
// A daemon that changes the boot core when the BOOT button is held.
//
// A continuous hold of at least `bootswap_hold_ms` latches the OTHER core and
// reboots, so a user can move between the two cores from the button alone, with
// the board switch set to AUTO. A short press does nothing.
//
// The button is found by name, because chip numbering changes between boots, and
// the line is requested once and then sampled, like the USER button.

const bootswap_hold_ms = 3000;

/// How long to wait for systemd to take the machine down before falling back.
const systemd_reboot_wait_s = 5;

/// Reboot the machine.
///
/// `systemctl reboot` is tried first, because it lets systemd stop its units
/// cleanly. The syscall fallback then runs whatever happened, so a reboot systemd
/// accepted but did not complete still restarts the machine. This only returns
/// when both paths failed.
fn rebootNow(io: std.Io) void {
    // A cancelled wait only reaches the syscall below sooner, which is the same
    // outcome this function is driving towards.
    if (systemctlReboot(io))
        io.sleep(.{ .nanoseconds = systemd_reboot_wait_s * std.time.ns_per_s }, .awake) catch |err|
            std.log.debug("bootswap: the wait for systemd was cut short: {t}", .{err});

    std.posix.sync();
    std.posix.reboot(.RESTART) catch |err|
        std.log.err("bootswap: the reboot syscall failed: {t}", .{err});
}

/// Run `systemctl reboot`. Returns true when systemd accepted it. A false result
/// is logged with its reason, and the caller falls back to the syscall.
fn systemctlReboot(io: std.Io) bool {
    var child = std.process.spawn(io, .{ .argv = &.{ "systemctl", "reboot" } }) catch |err| {
        std.log.warn("bootswap: cannot run systemctl ({t}); using the reboot syscall", .{err});
        return false;
    };
    const term = child.wait(io) catch |err| {
        std.log.warn("bootswap: cannot wait for systemctl ({t}); using the reboot syscall", .{err});
        return false;
    };
    switch (term) {
        .exited => |code| {
            if (code == 0) return true;
            std.log.warn("bootswap: systemctl exited {d}; using the reboot syscall", .{code});
        },
        else => std.log.warn("bootswap: systemctl did not exit normally; using the syscall", .{}),
    }
    return false;
}

/// The core a swap moves to.
fn otherCore(core: sysfs.Core) sysfs.Core {
    return switch (core) {
        .arm => .riscv,
        .riscv => .arm,
    };
}

/// Confirm the target core has a kernel before latching to it. Without this check
/// a swap that reported success could leave the board at the bootloader prompt.
/// Each core's bootloader reads its own extlinux tree.
fn targetHasKernel(io: std.Io, target: sysfs.Core) bool {
    var conf_buf: [64]u8 = undefined;
    const name = @tagName(target);
    const conf = std.fmt.bufPrint(&conf_buf, "/boot/{s}/extlinux/extlinux.conf", .{name}) catch
        return false;
    std.Io.Dir.cwd().access(io, conf, .{}) catch return false;
    return true;
}

fn doBootswap(io: std.Io) void {
    const current = sysfs.readStrap(io) orelse {
        std.log.warn("bootswap: cannot read the strap; not swapping", .{});
        return;
    };
    const target = otherCore(current);

    // /boot/fip.bin boots either core by the strap, so a core change is only a
    // latch change and no image has to be copied. Confirm the target has a kernel
    // before latching to it.
    if (!targetHasKernel(io, target)) {
        std.log.err("bootswap: {s} has no /boot/{s}/extlinux tree; not swapping", .{
            @tagName(target), @tagName(target),
        });
        return;
    }

    sysfs.latchCore(io, target) catch |err| {
        std.log.err("bootswap: cannot latch the {s} core: {t}", .{ @tagName(target), err });
        return;
    };

    // Confirm the latch took effect. The strap reports the latched selection, so a
    // strap that did not change means the board switch is not on AUTO. Put the
    // latch back and stop, rather than reboot into the same core.
    if (sysfs.readStrap(io)) |after| {
        if (after != target) {
            std.log.warn("bootswap: the strap still reads {s} after latching {s};" ++
                " the board switch is not on AUTO, so nothing was changed", .{
                @tagName(after), @tagName(target),
            });
            sysfs.latchCore(io, current) catch |err| {
                std.log.warn("bootswap: cannot put the latch back: {t}", .{err});
            };
            return;
        }
    }

    std.log.info("bootswap: moving from {s} to {s}; rebooting", .{
        @tagName(current), @tagName(target),
    });
    rebootNow(io);
}

/// How often the BOOT button line is sampled.
const bootswap_sample_ms: u64 = 50;

/// Watch the BOOT button and, on a long continuous hold, change the boot core and
/// reboot.
///
/// The BOOT line gives no edge interrupt, so it is sampled like the USER button. A
/// continuous hold that reaches `bootswap_hold_ms` starts the swap once.
fn cmdBootswap(io: std.Io) void {
    installHandler(.TERM, onStop);
    installHandler(.INT, onStop);

    var button = sysfs.Button.open(io, "btn-boot-n") orelse {
        std.log.info("bootswap: no btn-boot-n line; nothing to do", .{});
        return; // not a failure, so exit 0 and systemd does not start this again
    };
    defer button.close();

    std.log.info("bootswap: watching the BOOT button; hold {d} ms to swap", .{bootswap_hold_ms});

    // The line is active-low, so 0 means pressed. `fired` makes one continuous
    // hold start at most one swap, and it clears on release, so the button has to
    // be let go and held again.
    var press: PressState = .{};
    var fired = false;
    while (!stop_requested.load(.monotonic)) {
        const pressed = if (button.level()) |lvl| lvl == 0 else false;
        if (pressed and !press.down) {
            press = .{ .start_ms = monotonicMs(io), .down = true };
            fired = false;
            // Ask the oled daemon to show its swapcore screen while the hold is in
            // progress. Nothing here is required: with no daemon, no pid file, or
            // no such screen, the hold simply shows nothing.
            var pid_buf: [32]u8 = undefined;
            if (std.Io.Dir.cwd().readFile(io, oled_pidfile, &pid_buf)) |raw| {
                const trimmed = std.mem.trim(u8, raw, " \t\r\n");
                if (std.fmt.parseInt(i32, trimmed, 10)) |oled_pid| {
                    std.posix.kill(oled_pid, @enumFromInt(sig_swapcore)) catch |err|
                        std.log.debug("bootswap: cannot signal the oled daemon: {t}", .{err});
                } else |_| {}
            } else |_| {}
        } else if (pressed and press.down and !fired) {
            if (monotonicMs(io) - press.start_ms >= bootswap_hold_ms) {
                fired = true;
                // This returns only when it did not reboot.
                doBootswap(io);
            }
        } else if (!pressed and press.down) {
            press.down = false; // released, and a short press does nothing
        }
        io.sleep(.{ .nanoseconds = bootswap_sample_ms * std.time.ns_per_ms }, .awake) catch return;
    }
}

// ================================================================== main ===

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(gpa);
    var it = init.minimal.args.iterate();
    while (it.next()) |a| try argv.append(gpa, a);

    var out_buf: [1024]u8 = undefined;
    var out = Out.init(init.io, &out_buf);
    defer out.flush();

    if (argv.items.len < 2) {
        std.log.info("{s}", .{usage_text});
        std.process.exit(2);
    }

    const cmd = argv.items[1];
    const rest = argv.items[2..];

    // bootswap recovers from every fault itself, because it is a long-running
    // daemon, so it returns nothing and is handled before the chain below.
    if (std.mem.eql(u8, cmd, "bootswap")) {
        cmdBootswap(init.io);
        return;
    }

    // The two self-tests exercise each evaluator. They report their own error
    // types, and a failure in either is a build or link fault that deserves a
    // non-zero exit rather than a usage message, so they are handled separately.
    if (std.mem.eql(u8, cmd, "fix-selftest")) {
        fixeval.selftest(init.io, gpa) catch |err| {
            std.log.err("fix-selftest failed: {t}", .{err});
            out.flush();
            std.process.exit(1);
        };
        return;
    }
    if (std.mem.eql(u8, cmd, "nix-selftest")) {
        if (!nixeval.selftest()) {
            out.flush();
            std.process.exit(1);
        }
        std.log.info("nix-selftest passed", .{});
        return;
    }

    const result: CmdError!void = if (std.mem.eql(u8, cmd, "bling"))
        cmdBling(init.io, gpa, &out, rest)
    else if (std.mem.eql(u8, cmd, "core"))
        cmdCore(init.io, &out, rest)
    else if (std.mem.eql(u8, cmd, "power"))
        cmdPower(init.io, &out)
    else if (std.mem.eql(u8, cmd, "oled"))
        cmdOled(init.io, gpa, rest)
    else if (std.mem.eql(u8, cmd, "mmio"))
        cmdMmio(init.io, &out, rest)
    else
        error.Usage;

    result catch |err| {
        out.flush();
        switch (err) {
            error.Usage => {
                std.log.info("{s}", .{usage_text});
                std.process.exit(2);
            },
            error.Failed => std.process.exit(1),
        }
    };
}

test {
    // Pull in the unit tests of every module this program is built from.
    std.testing.refAllDecls(@This());
    _ = ws2812;
    _ = config;
    _ = oled;
    _ = sysfs;
    _ = bled;
    _ = screens;
    _ = fixeval;
    _ = nixeval;
    _ = eval;
    _ = backend;
}

test "parseVmRssKb reads the VmRSS value out of a status body" {
    const status =
        \\VmPeak:   123456 kB
        \\VmSize:   120000 kB
        \\VmRSS:     45678 kB
        \\VmData:    10000 kB
    ;
    try std.testing.expectEqual(@as(?u64, 45678), parseVmRssKb(status));
    // Real /proc separates the fields with tabs, which must parse the same way.
    try std.testing.expectEqual(@as(?u64, 45678), parseVmRssKb("VmRSS:\t 45678 kB\n"));
    // A body with no VmRSS line, and an empty body, both report null.
    try std.testing.expectEqual(@as(?u64, null), parseVmRssKb("VmSize:\t 100 kB\n"));
    try std.testing.expectEqual(@as(?u64, null), parseVmRssKb(""));
}

test "parseBackendKind maps each name and falls back to fix" {
    try std.testing.expectEqual(backend.Kind.nix, parseBackendKind("nix"));
    try std.testing.expectEqual(backend.Kind.fix, parseBackendKind("fix"));
    try std.testing.expectEqual(backend.Kind.fix, parseBackendKind("bogus"));
    try std.testing.expectEqual(backend.Kind.fix, parseBackendKind(""));
}

test "otherCore always moves to the core that is not running" {
    try std.testing.expectEqual(sysfs.Core.riscv, otherCore(.arm));
    try std.testing.expectEqual(sysfs.Core.arm, otherCore(.riscv));
}

test "latchBytes covers the required low time at every accepted clock" {
    // The latch must hold the line low for at least 300 us at any clock the config
    // accepts. Each byte carries 8 SPI bits, so the low time is bytes*8/clock.
    for ([_]u32{ config.min_speed_hz, 6_400_000, config.max_speed_hz }) |hz| {
        const bytes = latchBytes(hz);
        const low_us = @as(u64, bytes) * 8 * 1_000_000 / hz;
        try std.testing.expect(low_us >= 300);
        try std.testing.expect(bytes <= max_latch_bytes);
    }
}

test "maxCountForBufsiz keeps a frame inside one spidev transfer" {
    const bpl = ws2812.Encoding.eight.bytesPerLed();
    const bufsiz: u64 = 4096;
    const n = maxCountForBufsiz(bufsiz, bpl);
    // The frame that count produces, plus the longest latch, must still fit.
    try std.testing.expect(@as(u64, n) * bpl + max_latch_bytes <= bufsiz);
    // One more LED must not fit, so the bound is the largest that does.
    try std.testing.expect(@as(u64, n + 1) * bpl + max_latch_bytes > bufsiz);
    // A buffer too small for even the latch still reports a usable count of 1.
    try std.testing.expectEqual(@as(u32, 1), maxCountForBufsiz(8, bpl));
}

test "collectNixScreens takes only .nix files, sorts them, and appends" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    // Write the screens out of order, with one file that is not a screen.
    inline for (.{ "20-load.nix", "10-badapple.nix", "readme.txt", "30-clock.nix" }) |name| {
        try tmp.dir.writeFile(io, .{
            .sub_path = name,
            .data = "scope: { bitmap = [ 0 ]; nextMs = 33; }",
        });
    }

    var out: [max_eval_screens][]const u8 = undefined;
    // Seed one path, so the directory's screens must appear after it.
    out[0] = "explicit.nix";
    const n = collectNixScreens(io, gpa, root, &out, 1);
    defer for (out[1..n]) |p| gpa.free(p);

    // The seed plus three screens; readme.txt is not one.
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("explicit.nix", out[0]);
    try std.testing.expect(std.mem.endsWith(u8, out[1], "/10-badapple.nix"));
    try std.testing.expect(std.mem.endsWith(u8, out[2], "/20-load.nix"));
    try std.testing.expect(std.mem.endsWith(u8, out[3], "/30-clock.nix"));
}

test "collectNixScreens leaves the count alone when the directory is missing" {
    const gpa = std.testing.allocator;
    var out: [max_eval_screens][]const u8 = undefined;
    out[0] = "explicit.nix";
    const n = collectNixScreens(std.testing.io, gpa, "/nix-badge-absent-dir", &out, 1);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("explicit.nix", out[0]);
}

test "dropScreen removes a screen and keeps the index on a live one" {
    var screens_buf = [_]Screen{
        .{ .name = "a", .eval = 0 },
        .{ .name = "b", .eval = 1 },
        .{ .name = "c", .eval = 2 },
    };
    var active: []Screen = &screens_buf;

    // Dropping a screen before the current one moves the index down with it.
    var ix: usize = 2;
    active = dropScreen(active, "a", &ix);
    try std.testing.expectEqual(@as(usize, 2), active.len);
    try std.testing.expectEqual(@as(usize, 1), ix);
    try std.testing.expectEqualStrings("c", active[ix].name);

    // Dropping the current one, which is last, wraps the index back to the start.
    active = dropScreen(active, "c", &ix);
    try std.testing.expectEqual(@as(usize, 1), active.len);
    try std.testing.expectEqual(@as(usize, 0), ix);
    try std.testing.expectEqualStrings("b", active[ix].name);

    // The last screen is never dropped, because that would leave nothing to show.
    active = dropScreen(active, "b", &ix);
    try std.testing.expectEqual(@as(usize, 1), active.len);

    // A name that is not present changes nothing.
    active = dropScreen(active, "absent", &ix);
    try std.testing.expectEqual(@as(usize, 1), active.len);
}

test "findScreen matches a whole name and findScreenContaining matches a part" {
    const active = [_]Screen{
        .{ .name = "10-clock", .eval = 0 },
        .{ .name = "90-swapcore", .eval = 1 },
    };
    try std.testing.expectEqual(@as(?usize, 1), findScreen(&active, "90-swapcore"));
    try std.testing.expectEqual(@as(?usize, null), findScreen(&active, "swapcore"));
    // The signal jump looks a screen up by role, so a partial name must match.
    try std.testing.expectEqual(@as(?usize, 1), findScreenContaining(&active, "swapcore"));
    try std.testing.expectEqual(@as(?usize, null), findScreenContaining(&active, "absent"));
}
