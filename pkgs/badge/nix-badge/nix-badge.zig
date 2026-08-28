//! nix-badge: drive the Milk-V Duo S badge's WS2812 ring, OLED HUD, core-select
//! latch, rails/battery readout, and a /dev/mem peek/poke, over the SG2000's
//! spidev/i2c/gpio devices.
//!
//! A Zig reimplementation of the original nix-badge.c. It keeps the CLI and
//! behaviour familiar but fixes the C's shape: injected I/O (no global stdout),
//! injected allocator (no page_allocator in helpers), explicit little-endian blob
//! reads, error unions instead of int codes, and comptime asserts on the layout
//! invariants (framebuffer size, uAPI struct widths). The `leds run` service
//! starts in the initrd and must not flicker, so its transfer path is unchanged
//! in effect: one continuous SPI frame plus a >=320 us latch.

const std = @import("std");
const linux = @import("linux.zig");
const ws2812 = @import("ws2812.zig");
const config = @import("config.zig");
const oled = @import("oled.zig");
const sysfs = @import("sysfs.zig");
const badapple = @import("badapple.zig");
const bled = @import("bled.zig");
const screens = @import("screens.zig");
const fixeval = @import("fixeval.zig");

const Config = config.Config;
const Rgb = ws2812.Rgb;

const runtime_conf: [*:0]const u8 = "/var/lib/nix-badge/leds.conf";
const runtime_dir: [*:0]const u8 = "/var/lib/nix-badge";

// ISR-to-mainloop flags. Signal handlers are dispatched by the kernel to a fixed
// address and cannot take a context parameter, so these are the one sanctioned
// global-state exception (Backbone / IronStyle): minimal, atomic, documented.
// SIGTERM/SIGINT request a clean stop; SIGUSR1/2 request the next pattern/screen.
var stop_requested = std.atomic.Value(bool).init(false);
var want_next_pattern = std.atomic.Value(bool).init(false);
var want_next_screen = std.atomic.Value(bool).init(false);

fn onStop(_: linux.SIG) callconv(.c) void {
    stop_requested.store(true, .monotonic);
}

fn onUser(sig: linux.SIG) callconv(.c) void {
    switch (sig) {
        .USR1 => want_next_pattern.store(true, .monotonic),
        .USR2 => want_next_screen.store(true, .monotonic),
        else => {},
    }
}

fn installHandler(sig: linux.SIG, handler: linux.Sigaction.handler_fn) void {
    const sa: linux.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    linux.sigaction(sig, &sa);
}

/// Whether a stop, next-pattern, or next-screen request is queued (by a signal or
/// the button poll). Lets the bling frame sleep wake early.
fn eventPending() bool {
    return stop_requested.load(.monotonic) or
        want_next_pattern.load(.monotonic) or
        want_next_screen.load(.monotonic);
}

// ------------------------------------------------------------- output sink ---

/// A buffered stdout writer bound to the injected I/O. Program output (the
/// `power` voltages, `leds show`, the `core`/`mmio` results) goes here; diagnostic
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
    \\  nix-badge leds run --config FILE
    \\  nix-badge leds set [--pattern P] [--brightness 0-255] [--count N] [--speed-hz HZ]
    \\        [--bits 3|4|8] [--fps N] [--color '#rrggbb' ...] [--blob PATH] [--eval PATH]
    \\  nix-badge leds show
    \\  nix-badge core <arm|riscv|status>
    \\  nix-badge power
    \\  nix-badge bling [--badapple PATH] [--oled-width W] [--oled-height H]
    \\  nix-badge bootswap
    \\  nix-badge mmio <read ADDR | write ADDR VALUE>
    \\  nix-badge fix-selftest              (smoke-test the embedded Nix evaluator)
    \\
    \\patterns: off solid pulse rainbow chase
    \\
;

/// A command failed in a way worth a non-zero exit. Distinct from an argument
/// misuse (which prints usage and returns 2).
const CmdError = error{ Usage, Failed };

// ------------------------------------------------------------- config load ---

/// Load the declarative base config (if given) then layer the runtime file on
/// top. A malformed base is fatal (the build shipped it); a malformed runtime
/// file is logged and skipped so a bad user edit cannot brick the boot indicator.
fn loadConfig(base: ?[]const u8) CmdError!Config {
    var cfg = Config.default();
    if (base) |path| {
        var path_buf: [512]u8 = undefined;
        const zpath = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.Failed;
        var file_buf: [8192]u8 = undefined;
        const text = linux.readFile(zpath, &file_buf) orelse {
            std.log.err("cannot open config {s}", .{path});
            return error.Failed;
        };
        config.parseBuffer(&cfg, text) catch |err| {
            std.log.err("config {s}: {s}", .{ path, @errorName(err) });
            return error.Failed;
        };
    }
    layerRuntime(&cfg);
    return cfg;
}

/// Apply the declarative base config over `cfg` if a path is given. Used on
/// hot-reload, where a read/parse fault is non-fatal (logged, then the stale
/// value is kept) unlike the initial load.
fn layerBase(cfg: *Config, base: ?[]const u8) void {
    const path = base orelse return;
    var path_buf: [512]u8 = undefined;
    const zpath = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return;
    var file_buf: [8192]u8 = undefined;
    const text = linux.readFile(zpath, &file_buf) orelse return;
    config.parseBuffer(cfg, text) catch |err| {
        std.log.warn("base config {s}: {s}, keeping previous", .{ path, @errorName(err) });
    };
}

/// Apply the runtime file over `cfg` if present; a parse fault is logged and the
/// file ignored (recovered).
fn layerRuntime(cfg: *Config) void {
    var file_buf: [8192]u8 = undefined;
    const text = linux.readFile(runtime_conf, &file_buf) orelse return;
    config.parseBuffer(cfg, text) catch |err| {
        std.log.warn("runtime config: {s}, ignoring", .{@errorName(err)});
    };
}

fn ensureRuntimeDir() CmdError!void {
    switch (linux.mkdir(runtime_dir, 0o755)) {
        .created, .exists => {},
        .failed => {
            std.log.err("cannot create {s}", .{runtime_dir});
            return error.Failed;
        },
    }
}

// ----------------------------------------------------------------- leds run ---

const spidev_bufsiz_path: [*:0]const u8 = "/sys/module/spidev/parameters/bufsiz";
const spidev_bufsiz_fallback: u64 = 4096;
const ssi_clk_rate_path: [*:0]const u8 = "/sys/kernel/debug/clk/clk_spi/clk_rate";
const latch_us = 320;
const max_speed_hz: u32 = 20_000_000;
const clk_report_timeout_s = 120;
const idle_poll_hz = 2;

/// Latch length in bytes at a given SPI clock (each byte is 8 SPI bits). The XL
/// parts want >=300 us held low; we size for 320 us with margin.
fn latchBytes(speed_hz: u32) u32 {
    return @intCast(@as(u64, latch_us) * speed_hz / 8_000_000 + 1);
}

/// Worst-case latch, so a clock change never resizes the frame buffer.
const max_latch_bytes: u32 = @intCast(@as(u64, latch_us) * max_speed_hz / 8_000_000 + 1);

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

/// Clamp `cfg.count` to what one spidev transfer accepts, logging when it bites.
fn clampCount(cfg: *Config, bufsiz: u64, max_count: u32) void {
    if (cfg.count <= max_count) return;
    std.log.warn("count {d} exceeds spidev bufsiz {d}, clamping to {d}", .{
        cfg.count, bufsiz, max_count,
    });
    cfg.count = max_count;
}

fn readSpidevBufsiz() u64 {
    const n = sysfs.readU64(spidev_bufsiz_path) orelse return spidev_bufsiz_fallback;
    return if (n == 0) spidev_bufsiz_fallback else n;
}

/// Largest LED count whose frame still fits one spidev transfer. The frame must
/// go out as ONE transfer; a split would put a >50 us gap mid-frame, which the
/// chain reads as a latch.
fn maxCountForBufsiz(bufsiz: u64, bytes_per_led: u32) u32 {
    if (bufsiz <= max_latch_bytes) return 1;
    const n: u32 = @intCast((bufsiz - max_latch_bytes) / bytes_per_led);
    return @max(n, 1);
}

/// Report the bit timing the controller really produces, derived from the SSI
/// input clock in debugfs and the DesignWare even-divider rule. Returns false
/// when debugfs is not mounted yet (initrd), so the caller retries.
fn logClock(cfg: *const Config) bool {
    const ssi = sysfs.readU64(ssi_clk_rate_path) orelse return false;
    const div = (((ssi + cfg.speed_hz - 1) / cfg.speed_hz) + 1) & 0xfffe;
    const actual = if (div != 0) ssi / div else 0;
    const ns: u32 = if (actual != 0) @intCast(1_000_000_000 / actual) else 0;
    const bits: u32 = @intFromEnum(cfg.encoding);
    std.log.info(
        "{s} ssi_clk {d} Hz, divider {d}, actual {d} Hz, SPI bit {d} ns, {d} bits/LED-bit" ++
            " -> T0H {d} ns, T1H {d} ns, period {d} ns",
        .{ cfg.device(), ssi, div, actual, ns, bits, ns, ns * (bits - 1), ns * bits },
    );
    return true;
}

/// Open spidev, waiting for the node to bind (initrd race), and set mode/bits/
/// speed. Returns null to tell the caller to stop cleanly when the node never
/// appears (a core with no LED bus).
fn openSpi(cfg: *const Config) ?linux.fd_t {
    var dev_buf: [256]u8 = undefined;
    const dev = std.fmt.bufPrintZ(&dev_buf, "{s}", .{cfg.device()}) catch return null;

    // The controller/spidev may bind after we start (initrd race), so wait for
    // the node instead of failing at once.
    var fd: ?linux.fd_t = null;
    var waited: u32 = 0;
    while (waited <= 30 and fd == null) : (waited += 1) {
        fd = linux.open(dev, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch |err| blk: {
            if (waited == 0)
                std.log.info("waiting for {s} ({s})", .{ cfg.device(), @errorName(err) });
            linux.sleepNsec(std.time.ns_per_s);
            break :blk null;
        };
    }
    const good = fd orelse {
        std.log.warn("{s} did not appear after 30 s, giving up", .{cfg.device()});
        return null;
    };

    var mode: u8 = linux.Spi.MODE_0 | (if (cfg.cs_high) linux.Spi.CS_HIGH else 0);
    var bits: u8 = 8;
    var speed: u32 = cfg.speed_hz;
    _ = linux.ioctl(good, linux.Spi.IOC_WR_MODE, @intFromPtr(&mode)) catch {
        std.log.err("SPI_IOC_WR_MODE failed", .{});
        linux.close(good);
        return null;
    };
    _ = linux.ioctl(good, linux.Spi.IOC_WR_BITS_PER_WORD, @intFromPtr(&bits)) catch {
        std.log.err("SPI_IOC_WR_BITS_PER_WORD failed", .{});
        linux.close(good);
        return null;
    };
    _ = linux.ioctl(good, linux.Spi.IOC_WR_MAX_SPEED_HZ, @intFromPtr(&speed)) catch {
        std.log.err("SPI_IOC_WR_MAX_SPEED_HZ failed", .{});
        linux.close(good);
        return null;
    };
    return good;
}

/// Send one WS2812 frame. Times the transfer and warns if it took much longer
/// than its own bit count implies, which means the controller stalled and the bit
/// stream was not continuous (the only way to see a mid-frame gap without a scope).
fn sendFrame(fd: linux.fd_t, frame: []const u8, speed_hz: u32, report: bool) void {
    var tr: linux.Spi.Transfer = .{
        .tx_buf = @intFromPtr(frame.ptr),
        .len = @intCast(frame.len),
        .speed_hz = speed_hz,
        .bits_per_word = 8,
    };
    const t0 = linux.monotonicNsec();
    const rc = linux.ioctl(fd, linux.Spi.IOC_MESSAGE_1, @intFromPtr(&tr));
    const t1 = linux.monotonicNsec();

    if (report) {
        const took_us: u64 = @intCast(@divTrunc(t1 - t0, 1000));
        const ideal_us: u64 = @as(u64, frame.len) * 8 * 1_000_000 / speed_hz;
        const args = .{ frame.len, took_us, ideal_us };
        if (ideal_us != 0 and took_us > ideal_us * 2) {
            std.log.warn("transfer {d} bytes took {d} us (continuous {d} us)" ++
                " -- STALLED, bit stream not continuous", args);
        } else {
            std.log.info("transfer {d} bytes took {d} us (continuous {d} us)", args);
        }
    }
    _ = rc catch std.log.warn("transfer failed", .{});
}

/// Close any currently-open blob and open the one at `cfg.blob()` if set. Returns
/// the new `?bled.Frames`: null when no blob is configured, or when the configured
/// one is missing/short/bad-magic (logged), so the caller falls back to the
/// computed pattern. This is only ever called on start and on an mtime change, so
/// the open cost is off the hot path.
fn refreshBlob(prev: ?bled.Frames, cfg: *const Config) ?bled.Frames {
    var old = prev;
    if (old) |*o| o.deinit();

    const path = cfg.blob();
    if (path.len == 0) return null;

    var path_buf: [256]u8 = undefined;
    const zpath = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return null;
    return bled.load(zpath) catch |err| {
        std.log.warn("blob {s}: {s}; using computed pattern", .{ path, @errorName(err) });
        return null;
    };
}

/// Copy the first `out.len` LEDs of one blob frame's ring-order RGB into `out`
/// with the software brightness scale, matching what `ws2812.render` applies.
/// `out.len` is the effective LED count: the blob's nleds, or fewer if the spidev
/// bufsiz clamped it, so the frame always holds at least `out.len` LEDs.
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

/// The `leds run` service. Plays a baked "BLED" blob when one is configured and
/// valid, otherwise renders the configured computed pattern. On a runtime-file
/// mtime change it hot-reloads the CLI-mutable fields AND the blob path. Static
/// patterns idle at 2 Hz (and still repaint, since a WS2812 chain has no error
/// recovery of its own); animations and blobs run at their fps. The WS2812 encode
/// + spidev write + latch path is identical in both modes — only the pixel source
/// differs — so the blob mode is purely additive and cannot regress flicker.
fn cmdLedsRun(gpa: std.mem.Allocator, base: ?[]const u8) CmdError!void {
    var cfg = try loadConfig(base);

    installHandler(.TERM, onStop);
    installHandler(.INT, onStop);

    const bufsiz = readSpidevBufsiz();
    var max_count = maxCountForBufsiz(bufsiz, cfg.encoding.bytesPerLed());

    // A configured, valid blob overrides the LED count (its nleds) and fps; the
    // buffers below are then sized to the effective geometry. A missing/bad blob
    // leaves `blob` null and the computed pattern drives everything.
    var blob = refreshBlob(null, &cfg);
    defer if (blob) |*b| b.deinit();
    applyBlobGeometry(&cfg, blob, bufsiz, max_count);
    clampCount(&cfg, bufsiz, max_count);

    // A configured pure-Nix `eval` pattern (aarch64 only) is the HIGHEST-precedence
    // pixel source, over blob and the computed pattern. It paces on its own nextMs.
    // Sensor inputs are refreshed on a slow tick (battery is a median-of-33 ADC
    // read); `t` is current every frame. Missing/bad/unavailable -> null, so the
    // painter transparently falls back to blob/computed (and riscv, with no eval
    // built in, always takes that path).
    var eval_pat: ?fixeval.Pattern = openEval(gpa, &cfg);
    defer if (eval_pat) |*p| p.deinit();
    var sensors: fixeval.Fields = .{};
    var last_sensor_ms: u64 = 0;
    var cpu_meter = screens.CpuMeter.init();

    // The frame buffer is sized for the worst-case latch so a clock change never
    // reallocates it. Pixels and frame both resize on a count/encoding reload.
    var pixels = gpa.alloc(Rgb, cfg.count) catch return error.Failed;
    defer gpa.free(pixels);
    var frame = gpa.alloc(u8, frameCapacity(&cfg)) catch return error.Failed;
    defer gpa.free(frame);

    const fd = openSpi(&cfg) orelse return; // clean stop; systemd should not respin
    defer linux.close(fd);

    var frame_len = frameLen(&cfg);
    logRunState(&cfg, blob, frame_len);

    var clk_logged = logClock(&cfg);
    const clk_deadline = linux.realtimeSeconds() + clk_report_timeout_s;
    if (!clk_logged)
        std.log.info("{s} not readable yet; will report timing once it appears", .{
            ssi_clk_rate_path,
        });

    var seen_mtime: ?i128 = linux.mtimeNsec(runtime_conf);
    var frame_no: u32 = 0;
    var report_timing = true;

    while (!stop_requested.load(.monotonic)) {
        if (!clk_logged) {
            clk_logged = logClock(&cfg);
            if (!clk_logged and linux.realtimeSeconds() > clk_deadline) {
                std.log.warn("giving up on {s}; bit timing stays unverified", .{ssi_clk_rate_path});
                clk_logged = true;
            }
        }

        const now_mtime = linux.mtimeNsec(runtime_conf);
        if (!std.meta.eql(now_mtime, seen_mtime)) {
            seen_mtime = now_mtime;
            reloadInto(&cfg, base, &max_count, bufsiz, fd);
            blob = refreshBlob(blob, &cfg); // hot-reload the blob path too
            applyBlobGeometry(&cfg, blob, bufsiz, max_count);
            // Hot-reload the eval pattern: close and re-open on any config change.
            // The pattern is a pure function of `t`, so reopening never resets the
            // visible animation; only the compile is redone (rare, ~ms).
            if (eval_pat) |*p| p.deinit();
            eval_pat = openEval(gpa, &cfg);
            last_sensor_ms = 0; // force a sensor refresh next frame
            frame_no = 0;
            report_timing = true;
            // Resize buffers to the possibly-changed count/encoding. On OOM we
            // keep the old geometry rather than crash the boot indicator.
            if (cfg.count != pixels.len) {
                if (gpa.realloc(pixels, cfg.count)) |p| {
                    pixels = p;
                } else |_| {
                    std.log.warn("cannot resize to {d} leds, keeping {d}", .{
                        cfg.count, pixels.len,
                    });
                    cfg.count = @intCast(pixels.len);
                }
            }
            if (frameCapacity(&cfg) != frame.len) {
                if (gpa.realloc(frame, frameCapacity(&cfg))) |f| {
                    frame = f;
                } else |_| {
                    std.log.warn("cannot resize frame buffer, keeping current geometry", .{});
                }
            }
            frame_len = frameLen(&cfg);
            logRunState(&cfg, blob, frame_len);
        }

        const now_ms = linux.monotonicMsec();
        const lit = pixels[0..cfg.count];

        // Source precedence: eval > blob > computed. The eval pattern, when it
        // renders successfully, also dictates the frame period via its nextMs.
        var eval_period_ns: ?u64 = null;
        if (eval_pat) |*p| {
            if (last_sensor_ms == 0 or now_ms - last_sensor_ms >= sensor_interval_ms) {
                sensors = gatherSensors(&cpu_meter);
                last_sensor_ms = now_ms;
            }
            var fields = sensors;
            fields.t_ms = now_ms;
            fields.width = cfg.count;
            fields.height = 1;
            fields.brightness = cfg.brightness;
            if (p.render(fields, lit)) |next_ms| {
                eval_period_ns = @as(u64, next_ms) * std.time.ns_per_ms;
            } else |_| {
                // render() already logged once; disable eval and fall back for good.
                p.deinit();
                eval_pat = null;
            }
        }
        if (eval_period_ns == null) {
            if (blob) |*frames| {
                paintBlobFrame(frames, now_ms, cfg.brightness, lit);
            } else {
                ws2812.render(.{
                    .pattern = cfg.pattern,
                    .brightness = cfg.brightness,
                    .fps = cfg.fps,
                    .colors = cfg.colors(),
                }, frame_no, lit);
            }
        }
        // Identical encode + transfer + latch for every source — the flicker-free
        // path is untouched; only the pixel source above differs.
        ws2812.encodeFrame(cfg.encoding, lit, latchBytes(cfg.speed_hz), frame[0..frame_len]);

        sendFrame(fd, frame[0..frame_len], cfg.speed_hz, report_timing);
        report_timing = false;
        frame_no +%= 1;

        // An eval pattern paces on the nextMs it returned; otherwise a blob or
        // animated computed pattern runs at fps, and a static one idles at 2 Hz.
        const period_ns: u64 = eval_period_ns orelse blk: {
            const animated = blob != null or cfg.pattern.isAnimated();
            break :blk if (animated)
                std.time.ns_per_s / @as(u64, cfg.fps)
            else
                std.time.ns_per_s / idle_poll_hz;
        };
        linux.sleepNsec(period_ns);
    }
    // Leave the LEDs as they are so a restart repaints without a visible gap.
}

/// How often the slow sensor block (battery, USB, load, cpu, mem, uptime) is
/// re-read for the eval scope. `t` updates every frame; these change on a ~1 s
/// timescale and battery is a median-of-33 ADC read, so polling them per frame
/// would be wasted I/O.
const sensor_interval_ms: u64 = 1000;

/// Open the configured eval pattern, or null when none is set or eval is not
/// built in (riscv). A bad pattern logs inside `open` and also yields null, so
/// the painter transparently falls back to the blob/computed source.
fn openEval(gpa: std.mem.Allocator, cfg: *const Config) ?fixeval.Pattern {
    if (!fixeval.have_fix or cfg.eval().len == 0) return null;
    return fixeval.Pattern.open(gpa, cfg.eval());
}

/// Snapshot the slow sensor inputs for the eval scope. Called on the sensor tick,
/// not every frame; `t`/width/height/brightness are filled per frame by the caller.
fn gatherSensors(cpu: *screens.CpuMeter) fixeval.Fields {
    const bat = sysfs.readBattery();
    var l1: f64 = 0;
    var l5: f64 = 0;
    screens.readLoad1And5(&l1, &l5);
    return .{
        .battery_mv = bat.millivolts orelse 0,
        .battery_pct = bat.percent orelse 0,
        .on_usb = (sysfs.readLine("usb-vbus-det") orelse 0) != 0,
        .load1 = l1,
        .cpu_pct = cpu.sample(),
        .mem_pct = @intFromFloat(@min(screens.readMemUsedFrac() * 100.0 + 0.5, 255.0)),
        .uptime_s = @intCast(@min(screens.readUptimeS(), @as(u64, std.math.maxInt(u32)))),
    };
}

/// When a blob is active, override the effective LED count (its nleds) and fps so
/// the buffer sizing, encode, and pacing all follow the baked animation. No-op when
/// no blob is active (the computed pattern's config values stand).
fn applyBlobGeometry(cfg: *Config, blob: ?bled.Frames, bufsiz: u64, max_count: u32) void {
    const frames = blob orelse return;
    cfg.count = frames.nleds;
    cfg.fps = std.math.clamp(@as(u32, frames.fps), 1, 200);
    clampCount(cfg, bufsiz, max_count);
}

/// Log the active source (blob path or pattern name) and the frame geometry, once
/// at start and after every reload.
fn logRunState(cfg: *const Config, blob: ?bled.Frames, frame_len: usize) void {
    if (blob) |frames| {
        std.log.info("blob {s}: {d} leds, {d} fps, {d} frames, brightness {d}, {d} bytes/frame", .{
            cfg.blob(), frames.nleds, frames.fps, frames.frames, cfg.brightness, frame_len,
        });
    } else {
        std.log.info("pattern {s}: {d} leds, brightness {d}, {d} fps, {d} bytes/frame", .{
            cfg.pattern.name(), cfg.count, cfg.brightness, cfg.fps, frame_len,
        });
    }
}

/// Re-read the config and adopt the CLI-mutable fields (pattern, brightness, fps,
/// count, speed, encoding, colours, blob path). Hardware identity (device) is not
/// reloaded. A speed change is pushed to the driver; each transfer also carries its
/// own speed, so nothing is reopened.
fn reloadInto(cfg: *Config, base: ?[]const u8, max_count: *u32, bufsiz: u64, fd: linux.fd_t) void {
    var fresh = Config.default();
    layerBase(&fresh, base);
    layerRuntime(&fresh);

    const old_speed = cfg.speed_hz;
    cfg.pattern = fresh.pattern;
    cfg.brightness = fresh.brightness;
    cfg.fps = fresh.fps;
    cfg.count = fresh.count;
    cfg.speed_hz = fresh.speed_hz;
    cfg.encoding = fresh.encoding;
    cfg.colors_buf = fresh.colors_buf;
    cfg.ncolors = fresh.ncolors;
    cfg.setBlob(fresh.blob());

    max_count.* = maxCountForBufsiz(bufsiz, cfg.encoding.bytesPerLed());
    clampCount(cfg, bufsiz, max_count.*);
    if (cfg.speed_hz != old_speed) {
        var sp: u32 = cfg.speed_hz;
        _ = linux.ioctl(fd, linux.Spi.IOC_WR_MAX_SPEED_HZ, @intFromPtr(&sp)) catch {
            std.log.warn("cannot set {d} Hz", .{cfg.speed_hz});
        };
    }
}

// ---------------------------------------------------------------- leds set ---

fn cmdLedsSet(out: *Out, args: []const []const u8) CmdError!void {
    var cfg = Config.default();
    layerRuntime(&cfg); // start from what is live so a partial change keeps the rest

    var have_colors = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (optArg(args, &i, "--pattern")) |v| {
            cfg.pattern = ws2812.Pattern.parse(v) orelse {
                std.log.err("unknown pattern '{s}'", .{v});
                return error.Failed;
            };
        } else if (optArg(args, &i, "--brightness")) |v| {
            const n = std.fmt.parseInt(u32, v, 10) catch 0;
            cfg.brightness = if (n > 255) 255 else @intCast(n);
        } else if (optArg(args, &i, "--speed-hz")) |v| {
            const n = std.fmt.parseInt(u32, v, 10) catch 0;
            if (n < 100_000 or n > 20_000_000) {
                std.log.err("speed-hz {d} out of range 100000-20000000", .{n});
                return error.Failed;
            }
            cfg.speed_hz = n;
        } else if (optArg(args, &i, "--bits")) |v| {
            const n = std.fmt.parseInt(u32, v, 10) catch 0;
            cfg.encoding = std.enums.fromInt(ws2812.Encoding, n) orelse {
                std.log.err("bits must be 3, 4 or 8, got {d}", .{n});
                return error.Failed;
            };
        } else if (optArg(args, &i, "--fps")) |v| {
            const n = std.fmt.parseInt(u32, v, 10) catch 0;
            if (n < 1 or n > 200) {
                std.log.err("fps {d} out of range 1-200", .{n});
                return error.Failed;
            }
            cfg.fps = n;
        } else if (optArg(args, &i, "--count")) |v| {
            const n = std.fmt.parseInt(u32, v, 10) catch 0;
            if (n == 0 or n > config.max_leds) {
                std.log.err("count {d} out of range 1-{d}", .{ n, config.max_leds });
                return error.Failed;
            }
            cfg.count = n;
        } else if (optArg(args, &i, "--color")) |v| {
            if (!have_colors) {
                cfg.ncolors = 0;
                have_colors = true;
            }
            if (cfg.ncolors >= config.max_colors) {
                std.log.err("at most {d} colours", .{config.max_colors});
                return error.Failed;
            }
            cfg.colors_buf[cfg.ncolors] = config.parseColor(v) orelse {
                std.log.err("bad colour '{s}'", .{v});
                return error.Failed;
            };
            cfg.ncolors += 1;
        } else if (optArg(args, &i, "--blob")) |v| {
            // A path selects a baked BLED animation; an empty value clears it and
            // returns to the computed pattern.
            cfg.setBlob(v);
        } else if (optArg(args, &i, "--eval")) |v| {
            // A path selects a pure-Nix pattern function evaluated per frame
            // (aarch64 only, highest precedence); an empty value clears it.
            cfg.setEval(v);
        } else {
            std.log.err("set: unknown argument '{s}'", .{a});
            return error.Usage;
        }
    }

    try ensureRuntimeDir();
    try writeRuntimeConfig(&cfg);

    // The running service picks up the change on its next tick; we do not talk to
    // systemd. Echo the two headline fields.
    out.w().print("pattern = {s}\n", .{cfg.pattern.name()}) catch return error.Failed;
    out.w().print("brightness = {d}\n", .{cfg.brightness}) catch return error.Failed;
}

/// Match `--flag VALUE` at position i; on a match advances i past the value and
/// returns it. Keeps the arg loop declarative.
fn optArg(args: []const []const u8, i: *usize, flag: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, args[i.*], flag) and i.* + 1 < args.len) {
        i.* += 1;
        return args[i.*];
    }
    return null;
}

fn writeRuntimeConfig(cfg: *const Config) CmdError!void {
    // Room for the base fields, the colour list, and two store-path lines
    // (blob + eval), which are ~120 chars each.
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    config.writeRuntime(&w, cfg) catch return error.Failed;
    linux.writeFile(runtime_conf, w.buffered()) catch {
        std.log.err("cannot write {s}", .{runtime_conf});
        return error.Failed;
    };
}

fn cmdLedsShow(out: *Out) CmdError!void {
    var cfg = Config.default();
    layerRuntime(&cfg);
    const w = out.w();
    w.print("pattern = {s}\n", .{cfg.pattern.name()}) catch return error.Failed;
    w.print("brightness = {d}\n", .{cfg.brightness}) catch return error.Failed;
    w.writeAll("colors = ") catch return error.Failed;
    config.writeColorList(w, &cfg) catch return error.Failed;
    w.writeByte('\n') catch return error.Failed;
    w.print("blob = {s}\n", .{cfg.blob()}) catch return error.Failed;
    w.print("eval = {s}\n", .{cfg.eval()}) catch return error.Failed;
}

fn cmdLeds(gpa: std.mem.Allocator, out: *Out, args: []const []const u8) CmdError!void {
    if (args.len < 1) return error.Usage;
    if (std.mem.eql(u8, args[0], "run")) {
        var base: ?[]const u8 = null;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (optArg(args, &i, "--config")) |v| {
                base = v;
            } else {
                std.log.err("run: unknown argument '{s}'", .{args[i]});
                return error.Usage;
            }
        }
        return cmdLedsRun(gpa, base);
    }
    if (std.mem.eql(u8, args[0], "set")) return cmdLedsSet(out, args[1..]);
    if (std.mem.eql(u8, args[0], "show")) return cmdLedsShow(out);
    return error.Usage;
}

// -------------------------------------------------------------------- core ---

fn cmdCore(out: *Out, args: []const []const u8) CmdError!void {
    if (args.len < 1) return error.Usage;
    const w = out.w();

    if (std.mem.eql(u8, args[0], "status")) {
        return reportStrap(w);
    }

    const core: sysfs.Core = if (std.mem.eql(u8, args[0], "arm"))
        .arm
    else if (std.mem.eql(u8, args[0], "riscv"))
        .riscv
    else {
        std.log.err("core: expected arm, riscv or status", .{});
        return error.Usage;
    };

    sysfs.latchCore(core) catch |err| {
        std.log.err("core latch failed: {s}", .{@errorName(err)});
        return error.Failed;
    };
    w.print("core-select latch set to {s}\n", .{@tagName(core)}) catch return error.Failed;
    try reportStrap(w);
    w.print(
        \\
        \\The latch only chooses which boot chain runs. Also swap the
        \\firmware so U-Boot loads the matching kernel:
        \\    swap-core {s}
        \\Then reboot, with the board switch in AUTO.
        \\
    , .{@tagName(core)}) catch return error.Failed;
}

fn reportStrap(w: *std.Io.Writer) CmdError!void {
    if (sysfs.readStrap()) |core| {
        const bit: u8 = if (core == .riscv) 1 else 0;
        w.print("strap readback: {d} ({s})\n", .{ bit, @tagName(core) }) catch return error.Failed;
    } else {
        w.writeAll("strap readback: unavailable\n") catch return error.Failed;
    }
}

// ------------------------------------------------------------------- power ---

fn cmdPower(out: *Out) CmdError!void {
    const w = out.w();

    // VSEL system rail via the vsel iio-rescale voltmeter (kernel-scaled).
    if (sysfs.readVselVolts()) |v| {
        w.print("VSEL (system / VBUS): {d:.3} V\n", .{v}) catch return error.Failed;
    } else {
        std.log.warn("VSEL rail unavailable (no vsel iio-rescale device?)", .{});
        w.writeAll("VSEL (system / VBUS): --\n") catch return error.Failed;
    }

    // VBAT volts from the kernel power_supply node; percent/status from the same.
    const bat = sysfs.readBattery();
    if (bat.millivolts) |mv| {
        const v = @as(f64, @floatFromInt(mv)) / 1000.0;
        const status = if (bat.status_len > 0) bat.status() else "unknown";
        if (bat.percent) |p| {
            w.print("VBAT (battery):       {d:.3} V ({d}%, {s})\n", .{ v, p, status }) catch
                return error.Failed;
        } else {
            w.print("VBAT (battery):       {d:.3} V ({s})\n", .{ v, status }) catch
                return error.Failed;
        }
    } else {
        std.log.warn("VBAT unavailable (no vbat-adc-battery power_supply node?)", .{});
        w.writeAll("VBAT (battery):       -- (unknown)\n") catch return error.Failed;
    }

    // J6 external test point via the base SARADC channel 2 (no divider).
    if (sysfs.readJ6Volts()) |v| {
        w.print("J6   (ext ADC):       {d:.3} V\n", .{v}) catch return error.Failed;
    } else {
        std.log.warn("J6 unavailable (no base SARADC device?)", .{});
        w.writeAll("J6   (ext ADC):       --\n") catch return error.Failed;
    }

    const vbus = sysfs.readLine("usb-vbus-det");
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
        const v = sysfs.readLine(f.line);
        const text = if (v) |b| (if (b != 0) "ok" else "FAULT") else "unknown";
        w.print("  {s: <8} {s}\n", .{ f.label, text }) catch return error.Failed;
    }
}

// -------------------------------------------------------------------- mmio ---

fn cmdMmio(out: *Out, args: []const []const u8) CmdError!void {
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

    const fd = linux.open("/dev/mem", .{ .ACCMODE = .RDWR, .SYNC = true }, 0) catch {
        std.log.err("open /dev/mem failed", .{});
        return error.Failed;
    };
    defer linux.close(fd);
    const map = linux.mmapShared(fd, page_size, @intCast(base)) catch {
        std.log.err("mmap 0x{x} failed", .{base});
        return error.Failed;
    };
    defer linux.munmap(map);

    const reg: *volatile u32 = @ptrFromInt(@intFromPtr(map.ptr) + offset);
    if (is_write) reg.* = val;
    // A volatile store then a volatile load preserves the poke-then-readback order
    // (the C used __sync_synchronize purely for that).
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

// ================================================================== bling ===
//
// The bling engine supersedes the old `oled` subcommand: one loop, a registry of
// screens each a pure function of a per-frame snapshot. The USER button and
// SIGUSR1/2 advance either the LED pattern (by rewriting the runtime config so
// the running `leds run` hot-reloads it) or the OLED screen, so one button cycles
// both ring and panel.

const Screen = struct {
    name: []const u8,
    render: *const fn (panel: *oled.Panel, ctx: *const screens.Context) u32,
};

const bling_longpress_ms = 400;

/// Advance the runtime config's `pattern =` to the next non-off pattern, leaving
/// every other line untouched so the running service hot-reloads only the
/// pattern. "off" is skipped so a button press never blanks the ring.
fn ledsNextPattern() void {
    // Read the current pattern through the same parser the service uses.
    var current = Config.default();
    layerRuntime(&current);
    const patterns = std.enums.values(ws2812.Pattern);
    var next: usize = (@intFromEnum(current.pattern) + 1) % patterns.len;
    if (next == @intFromEnum(ws2812.Pattern.off)) next += 1; // never land on off
    const want = @as(ws2812.Pattern, @enumFromInt(next)).name();

    switch (linux.mkdir(runtime_dir, 0o755)) {
        .created, .exists => {},
        .failed => {
            std.log.warn("bling: cannot create {s}", .{runtime_dir});
            return;
        },
    }

    // Rewrite the file line by line, replacing only the pattern line (appending
    // one if none existed). A modest output buffer suits this handful of lines.
    var in_buf: [8192]u8 = undefined;
    const existing = linux.readFile(runtime_conf, &in_buf) orelse &[_]u8{};

    var out_buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out_buf);
    var replaced = false;
    // Walk lines the way fgets would: each includes its trailing '\n'; a file
    // ending in '\n' yields no phantom empty line.
    var pos: usize = 0;
    while (pos < existing.len) {
        const nl = std.mem.indexOfScalarPos(u8, existing, pos, '\n');
        const line = if (nl) |e| existing[pos .. e + 1] else existing[pos..];
        pos = if (nl) |e| e + 1 else existing.len;

        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "pattern")) {
            const after = std.mem.trimStart(u8, trimmed[7..], " \t");
            if (after.len > 0 and after[0] == '=') {
                w.print("pattern = {s}\n", .{want}) catch return;
                replaced = true;
                continue;
            }
        }
        w.writeAll(line) catch return;
    }
    if (!replaced) w.print("pattern = {s}\n", .{want}) catch return;

    linux.writeFile(runtime_conf, w.buffered()) catch {
        std.log.warn("bling: cannot write {s}", .{runtime_conf});
        return;
    };
    std.log.info("bling: LED pattern -> {s}", .{want});
}

/// Gather the per-frame snapshot: the animation clock, battery/USB, and the proc
/// meters. The CPU delta is tracked in `cpu` across frames.
fn blingGather(cpu: *screens.CpuMeter) screens.Context {
    const bat = sysfs.readBattery();
    var l1: f64 = 0;
    var l5: f64 = 0;
    screens.readLoad1And5(&l1, &l5);
    return .{
        .now_ms = linux.monotonicMsec(),
        .on_usb = sysfs.readLine("usb-vbus-det"),
        .battery_mv = bat.millivolts,
        .battery_pct = bat.percent,
        .load1 = l1,
        .cpu_pct = cpu.sample(),
        .mem_pct = @intFromFloat(screens.readMemUsedFrac() * 100.0 + 0.5),
        .uptime_s = screens.readUptimeS(),
    };
}

/// Carries the button press timing across `blingWait` calls.
const PressState = struct { start_ms: u64 = 0, down: bool = false };

/// Wait up to `want_ms` for the next frame, waking early on a pending
/// stop/pattern/screen flag, a SIGUSR1/2 (poll returns EINTR), or a USER-button
/// edge. The button is event-driven off its held request fd, so no press is
/// dropped and no line is re-requested per poll. A short press (<400 ms) sets the
/// next-pattern flag, a long press the next-screen flag.
fn blingWait(want_ms: u32, button: ?sysfs.Button, press: *PressState) void {
    const deadline_ms = linux.monotonicMsec() + want_ms;
    while (true) {
        if (eventPending()) return;
        const now_ms = linux.monotonicMsec();
        if (now_ms >= deadline_ms) return;
        const remaining: i32 = @intCast(@min(deadline_ms - now_ms, std.math.maxInt(i32)));

        // Without a button there is nothing to poll; a plain sleep suffices and
        // still wakes early on a signal (EINTR).
        const btn = button orelse {
            linux.sleepNsec(@as(u64, @intCast(remaining)) * std.time.ns_per_ms);
            return;
        };

        var fds = [_]linux.pollfd{.{ .fd = btn.pollFd(), .events = linux.POLLIN, .revents = 0 }};
        const ready = linux.poll(&fds, remaining) orelse continue; // EINTR: re-check flags
        if (ready == 0) return; // frame deadline reached
        if (fds[0].revents & linux.POLLIN == 0) continue;

        // Drain every coalesced edge so a fast tap is never lost.
        while (btn.nextEdge()) |edge| switch (edge) {
            .press => press.* = .{ .start_ms = linux.monotonicMsec(), .down = true },
            .release => {
                if (!press.down) continue;
                press.down = false;
                const held = linux.monotonicMsec() - press.start_ms;
                const long = held >= bling_longpress_ms;
                const flag = if (long) &want_next_screen else &want_next_pattern;
                flag.store(true, .monotonic);
            },
        };
    }
}

// Where the current OLED screen is remembered across reboots. The LED pattern
// already persists (the leds service layers /var/lib/nix-badge/leds.conf over the
// declarative base at startup); this is the screen's equivalent. Persisted by
// NAME, not index, so it survives a registry that changes shape (badapple present
// or not).
const bling_state_file: [*:0]const u8 = "/var/lib/nix-badge/bling.state";

/// Restore the last-shown screen. A missing file or an unknown name (e.g. the
/// saved screen is gone this boot) starts at screen 0.
fn restoreScreen(active: []const Screen) usize {
    var buf: [64]u8 = undefined;
    const raw = linux.readFile(bling_state_file, &buf) orelse return 0;
    const name = std.mem.trim(u8, raw, " \t\r\n");
    for (active, 0..) |s, ix| {
        if (std.mem.eql(u8, s.name, name)) return ix;
    }
    return 0;
}

/// Persist the current screen name for the next boot. Best-effort: a write fault
/// only loses which screen was up, so it is logged, not fatal.
fn persistScreen(name: []const u8) void {
    ensureRuntimeDir() catch return;
    var buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}\n", .{name}) catch return;
    linux.writeFile(bling_state_file, line) catch
        std.log.warn("bling: cannot persist screen to {s}", .{bling_state_file});
}

fn cmdBling(gpa: std.mem.Allocator, args: []const []const u8) CmdError!void {
    var badapple_path: ?[]const u8 = null;
    var oled_width: u16 = oled.default_width;
    var oled_height: u16 = oled.default_height;
    // The USER button line, by device-tree name. Defaults to the dedicated USER
    // button (PWR_GPIO1); btn-boot-n is deliberately NOT the default so the
    // bootswap daemon can own it. A name the DT does not expose leaves the button
    // null and only SIGUSR1/2 drive the screens/patterns.
    var button_name: []const u8 = "user-btn";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (optArg(args, &i, "--badapple")) |v| {
            badapple_path = v;
        } else if (optArg(args, &i, "--button")) |v| {
            button_name = v;
        } else if (optArg(args, &i, "--oled-width")) |v| {
            oled_width = std.fmt.parseInt(u16, v, 10) catch {
                std.log.err("bling: bad --oled-width '{s}'", .{v});
                return error.Usage;
            };
        } else if (optArg(args, &i, "--oled-height")) |v| {
            oled_height = std.fmt.parseInt(u16, v, 10) catch {
                std.log.err("bling: bad --oled-height '{s}'", .{v});
                return error.Usage;
            };
        } else {
            std.log.err("bling: unknown argument '{s}'", .{args[i]});
            return error.Usage;
        }
    }

    // The panel is optional hardware; open it first so its geometry is known before
    // we decide whether a baked clip fits. A missing bus / bad size / OOM all mean
    // "no panel" and we exit 0 (like the C) so systemd does not respin us.
    var panel = oled.Panel.open(gpa, oled_width, oled_height) orelse {
        std.log.warn("bling: no OLED panel, nothing to do", .{});
        return;
    };
    defer panel.close();
    panel.init() catch {
        std.log.err("bling: SSD1306 init failed", .{});
        return;
    };

    // Load the clip and check it matches the panel geometry; badapple leads the
    // registry only when it loads AND its baked size equals the panel's, since a
    // differently-sized frame would blit the wrong number of bytes. A mismatch or a
    // bad asset just leaves it out; the meters still run.
    var clip: ?badapple.Clip = null;
    if (badapple_path) |path| {
        var path_buf: [512]u8 = undefined;
        if (std.fmt.bufPrintZ(&path_buf, "{s}", .{path})) |zpath| {
            if (badapple.load(zpath)) |c| {
                if (c.width == panel.width and c.height == panel.height) {
                    clip = c;
                    std.log.info("badapple: {s}, {d}x{d}, {d} fps, {d} frames", .{
                        path, c.width, c.height, c.fps, c.frames,
                    });
                } else {
                    std.log.warn("badapple: {s} is {d}x{d} but panel is {d}x{d}; skipping", .{
                        path, c.width, c.height, panel.width, panel.height,
                    });
                    var mismatched = c; // release the mapping we will not play
                    mismatched.deinit();
                }
            } else |err| {
                std.log.warn("badapple: {s}: {s}", .{ path, @errorName(err) });
            }
        } else |_| {}
    }
    defer if (clip) |*c| c.deinit();

    // Build the screen registry. badapple leads (and is the default) when loaded.
    var registry: [5]Screen = undefined;
    var n: usize = 0;
    if (clip != null) {
        registry[n] = .{ .name = "badapple", .render = screenBadapple };
        n += 1;
    }
    registry[n] = .{ .name = "battery", .render = screens.battery };
    n += 1;
    registry[n] = .{ .name = "load", .render = screens.load };
    n += 1;
    registry[n] = .{ .name = "power", .render = screens.power };
    n += 1;
    registry[n] = .{ .name = "clock", .render = screens.clock };
    n += 1;
    const active_screens = registry[0..n];

    installHandler(.TERM, onStop);
    installHandler(.INT, onStop);
    installHandler(.USR1, onUser);
    installHandler(.USR2, onUser);

    // Request the USER button once with edge detection; null when the DT exposes
    // no line by this name, in which case only the SIGUSR1/2 controls drive the
    // screens/patterns.
    var button = sysfs.Button.open(button_name);
    defer if (button) |*b| b.close();
    if (button == null) std.log.info("bling: button '{s}' not found; SIGUSR1/2 only", .{button_name});

    std.log.info("bling up on {s} @ 0x{x:0>2}, {d} screens, first {s}", .{
        oled.i2c_bus, oled.i2c_addr, n, active_screens[0].name,
    });

    var screen_ix: usize = restoreScreen(active_screens);
    if (screen_ix != 0) std.log.info("bling: resuming screen {s}", .{active_screens[screen_ix].name});
    var press: PressState = .{};
    var cpu = screens.CpuMeter.init();

    // The active clip is read inside screenBadapple via this file-scope pointer,
    // set for the duration of the loop. It is single-threaded and cleared on exit.
    active_clip = if (clip) |*c| c else null;
    defer active_clip = null;

    while (!stop_requested.load(.monotonic)) {
        const ctx = blingGather(&cpu);
        const want_ms = active_screens[screen_ix].render(&panel, &ctx);
        panel.flush() catch std.log.warn("bling: flush failed", .{});

        blingWait(want_ms, button, &press);

        if (want_next_pattern.swap(false, .monotonic)) ledsNextPattern();
        if (want_next_screen.swap(false, .monotonic)) {
            screen_ix = (screen_ix + 1) % active_screens.len;
            persistScreen(active_screens[screen_ix].name);
            std.log.info("bling: screen -> {s}", .{active_screens[screen_ix].name});
        }
    }

    // Leave the panel dark on a clean stop; a flush fault here is only cosmetic
    // (we are exiting anyway), so log it rather than fail the exit.
    panel.blankOff() catch |err| std.log.warn("bling: blank-off failed: {s}", .{@errorName(err)});
}

// The clip the badapple screen plays. Set only while the bling loop runs (single
// threaded); the screen fn signature is fixed by the registry so it cannot take
// the clip as a parameter, hence this scoped pointer rather than a parameter.
var active_clip: ?*badapple.Clip = null;

fn screenBadapple(panel: *oled.Panel, ctx: *const screens.Context) u32 {
    const clip = active_clip orelse return 100;
    panel.blit(clip.frameAt(ctx.now_ms));
    return clip.frameMs();
}

// ================================================================= bootswap ===
//
// A daemon that swaps the boot core when the USER holds the BOOT button. On a long
// continuous hold (>= HOLD_MS) it latches the OTHER core and reboots, so a user
// can flip ARM<->RISC-V from the button alone (board switch on AUTO). A short press
// does nothing. The button is watched by name (portb, gpiochip renumbers), request-
// once + edge poll() like the bling USER button.

const bootswap_hold_ms = 3000;

/// Reboot the machine cleanly. Prefer `systemctl reboot` (lets systemd tear down
/// units); if that is absent or exits non-zero, fall back to sync() + reboot(2).
/// Only returns on total failure (both paths failed), which the caller logs.
fn rebootNow(io: std.Io) void {
    // If systemd took the reboot, give it a moment to tear us down; otherwise fall
    // straight to the syscall. The fallback runs unconditionally as a backstop, so
    // even a "handled" reboot that stalls still restarts the machine.
    if (systemctlReboot(io)) linux.sleepNsec(5 * std.time.ns_per_s);

    linux.sync();
    linux.reboot() catch |err| std.log.err("bootswap: reboot(2) failed: {s}", .{@errorName(err)});
}

/// Try `systemctl reboot`. Returns true when systemd accepted it (exit 0), false
/// (with a logged reason) when it is absent or failed, so the caller falls back.
fn systemctlReboot(io: std.Io) bool {
    var child = std.process.spawn(io, .{ .argv = &.{ "systemctl", "reboot" } }) catch |err| {
        std.log.warn("bootswap: spawn systemctl failed ({s}); using reboot(2)", .{@errorName(err)});
        return false;
    };
    const term = child.wait(io) catch |err| {
        std.log.warn("bootswap: systemctl wait failed ({s}); using reboot(2)", .{@errorName(err)});
        return false;
    };
    switch (term) {
        .exited => |code| {
            if (code == 0) return true;
            std.log.warn("bootswap: systemctl reboot exited {d}; using reboot(2)", .{code});
        },
        else => std.log.warn("bootswap: systemctl reboot abnormal exit; using reboot(2)", .{}),
    }
    return false;
}

/// The other core: what a swap latches. arm <-> riscv.
fn otherCore(core: sysfs.Core) sysfs.Core {
    return switch (core) {
        .arm => .riscv,
        .riscv => .arm,
    };
}

/// Perform the swap: read the current boot core off the strap, latch the other,
/// and reboot. If the strap can be re-read and did NOT flip after latching, the
/// board switch is not on AUTO (it overrides the latch), so revert and do nothing
/// rather than pointlessly rebooting into the same core.
fn doBootswap(io: std.Io) void {
    const current = sysfs.readStrap() orelse {
        std.log.warn("bootswap: cannot read strap; not swapping", .{});
        return;
    };
    const target = otherCore(current);

    sysfs.latchCore(target) catch |err| {
        std.log.err("bootswap: latch {s} failed: {s}", .{ @tagName(target), @errorName(err) });
        return;
    };

    // Confirm the latch took (switch on AUTO). The strap reflects the latched
    // selection; if it did not change to the target, AUTO is off — revert and bail.
    if (sysfs.readStrap()) |after| {
        if (after != target) {
            std.log.warn("bootswap: strap still {s} after latching {s}; not in AUTO, ignoring", .{
                @tagName(after), @tagName(target),
            });
            sysfs.latchCore(current) catch |err| {
                std.log.warn("bootswap: revert latch failed: {s}", .{@errorName(err)});
            };
            return;
        }
    }

    std.log.info("bootswap: {s} -> {s}, rebooting", .{ @tagName(current), @tagName(target) });
    rebootNow(io);
}

/// Watch the BOOT button for a long continuous hold and, on one, swap the boot
/// core and reboot. Request-once + edge poll() so no press is dropped; the hold is
/// measured by polling with a timeout of "time remaining until HOLD_MS" after a
/// press edge — if that timeout elapses with no release edge, the hold completed.
fn cmdBootswap(io: std.Io) void {
    installHandler(.TERM, onStop);
    installHandler(.INT, onStop);

    var button = sysfs.Button.open("btn-boot-n") orelse {
        std.log.info("bootswap: no btn-boot-n line; nothing to do", .{});
        return; // non-fatal, exit 0 so systemd does not respin
    };
    defer button.close();

    std.log.info("bootswap: watching BOOT button, hold {d} ms to swap core", .{bootswap_hold_ms});

    var press: PressState = .{};
    while (!stop_requested.load(.monotonic)) {
        // When idle, block indefinitely on the button; when a press is in progress,
        // only until the hold threshold so we can act while it is still held.
        var timeout_ms: i32 = -1;
        if (press.down) {
            const held = linux.monotonicMsec() - press.start_ms;
            if (held >= bootswap_hold_ms) {
                doBootswap(io); // returns only if we did not reboot (not AUTO, etc.)
                press.down = false;
                continue;
            }
            timeout_ms = @intCast(bootswap_hold_ms - held);
        }

        var fds = [_]linux.pollfd{.{ .fd = button.pollFd(), .events = linux.POLLIN, .revents = 0 }};
        const ready = linux.poll(&fds, timeout_ms) orelse continue; // EINTR: re-check stop flag
        if (ready == 0) continue; // hold-threshold timeout: loop re-checks `held`
        if (fds[0].revents & linux.POLLIN == 0) continue;

        while (button.nextEdge()) |edge| switch (edge) {
            .press => press = .{ .start_ms = linux.monotonicMsec(), .down = true },
            .release => press.down = false, // a short press: nothing happens
        };
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

    // bootswap recovers every fault internally (it is a resilient daemon), so it
    // returns void rather than a CmdError; handle it before the fallible chain.
    if (std.mem.eql(u8, cmd, "bootswap")) {
        cmdBootswap(init.io);
        return;
    }

    // fix-selftest smoke-tests the embedded Nix evaluator. It returns fix's own
    // eval error union (not CmdError), and a failure here is a build/ABI fault
    // worth a non-zero exit rather than a usage message; handle it out of the
    // fallible CmdError chain. Kept terse in usage: it is a smoke test.
    if (std.mem.eql(u8, cmd, "fix-selftest")) {
        fixeval.selftest(gpa) catch |err| {
            std.log.err("fix-selftest failed: {s}", .{@errorName(err)});
            out.flush();
            std.process.exit(1);
        };
        return;
    }

    const result: CmdError!void = if (std.mem.eql(u8, cmd, "leds"))
        cmdLeds(gpa, &out, rest)
    else if (std.mem.eql(u8, cmd, "core"))
        cmdCore(&out, rest)
    else if (std.mem.eql(u8, cmd, "power"))
        cmdPower(&out)
    else if (std.mem.eql(u8, cmd, "bling"))
        cmdBling(gpa, rest)
    else if (std.mem.eql(u8, cmd, "mmio"))
        cmdMmio(&out, rest)
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

pub const CmdErrorPub = CmdError;

test {
    // Pull unit tests from the modules the program is built from.
    std.testing.refAllDecls(@This());
    _ = ws2812;
    _ = config;
    _ = oled;
    _ = sysfs;
    _ = badapple;
    _ = bled;
    _ = screens;
    _ = fixeval;
}
