//! nix-badge: drive the Milk-V Duo S badge's WS2812 ring, OLED HUD, core-select
//! latch, rails/battery readout, and a /dev/mem peek/poke, over the SG2000's
//! spidev/i2c/gpio devices.
//!
//! A Zig reimplementation of the original nix-badge.c. It keeps the CLI and
//! behaviour familiar but fixes the C's shape: injected I/O (no global stdout),
//! injected allocator (no page_allocator in helpers), explicit little-endian blob
//! reads, error unions instead of int codes, and comptime asserts on the layout
//! invariants (framebuffer size, uAPI struct widths). The `bling run` service
//! starts in the initrd and must not flicker, so its transfer path is unchanged
//! in effect: one continuous SPI frame plus a >=320 us latch.

const std = @import("std");
const linux = @import("linux.zig");
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

// Mutable runtime state lives in /etc/nixbadge alongside the (symlinked) default
// content, so the badge's whole hackable surface is one folder. The dir is created
// declaratively (systemd.tmpfiles + nixbadge-content.service) but we mkdir it too so
// early-boot / initrd paths don't depend on that ordering.
const runtime_conf: [*:0]const u8 = "/etc/nixbadge/leds.conf";
const runtime_dir: [*:0]const u8 = "/etc/nixbadge";

// ISR-to-mainloop flags. Signal handlers are dispatched by the kernel to a fixed
// address and cannot take a context parameter, so these are the one sanctioned
// global-state exception (Backbone / IronStyle): minimal, atomic, documented.
// SIGTERM/SIGINT request a clean stop; SIGUSR1/2 request the next pattern/screen.
var stop_requested = std.atomic.Value(bool).init(false);
var want_next_pattern = std.atomic.Value(bool).init(false);
var want_next_screen = std.atomic.Value(bool).init(false);
// A >5 s USER-button hold requests a live evaluator-backend switch (fix <-> nix).
var want_switch_backend = std.atomic.Value(bool).init(false);

/// Parse a `--backend fix|nix` value into a Kind. Unknown -> fix (logged). The nix arm
/// falls back to fix at open() when it is not linked (riscv / nixEval off), so requesting
/// nix on a fix-only build is harmless.
fn parseBackendKind(v: []const u8) backend.Kind {
    if (std.mem.eql(u8, v, "nix")) return .nix;
    if (std.mem.eql(u8, v, "fix")) return .fix;
    std.log.warn("unknown --backend '{s}'; using fix", .{v});
    return .fix;
}

/// Human name of a backend kind, for the fps window log + the on-panel HUD.
fn backendName(k: backend.Kind) []const u8 {
    return switch (k) {
        .fix => "fix",
        .nix => "nix",
    };
}

fn onStop(_: linux.SIG) callconv(.c) void {
    stop_requested.store(true, .monotonic);
}

// ---- screen-control API (RT signals, kernel-numbered) -----------------------
// `kill -<sig> <pid>` (or `systemctl kill -s <sig> nixbadge-oled`) drives the
// screen directly: sig 40+N jumps to screen index N (0..15); sig 56 jumps to the
// screen whose name contains "swapcore" (the bootswap hold indicator, which is a
// hidden auto-returning content screen). Numbers 40+ stay clear of the libc
// runtime's internal RT signals (32..34). The oled daemon writes its pid to
// /run/nixbadge-oled.pid so peers (bootswap) can signal without systemctl.
const sig_jump_base: u32 = 40;
const sig_jump_count: u32 = 16;
const sig_swapcore: u32 = 56;
const oled_pidfile: [*:0]const u8 = "/run/nixbadge-oled.pid";
/// Pending jump: -1 none, -2 swapcore-by-name, else a screen index.
var want_jump = std.atomic.Value(i32).init(-1);

fn onJump(sig: linux.SIG) callconv(.c) void {
    const n = @intFromEnum(sig);
    if (n == sig_swapcore) {
        want_jump.store(-2, .monotonic);
    } else if (n >= sig_jump_base and n < sig_jump_base + sig_jump_count) {
        want_jump.store(@intCast(n - sig_jump_base), .monotonic);
    }
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

/// Whether a stop, next-pattern, next-screen, or backend-switch request is queued (by a
/// signal or the button poll). Lets the oled frame sleep wake early.
fn eventPending() bool {
    return stop_requested.load(.monotonic) or
        want_next_pattern.load(.monotonic) or
        want_next_screen.load(.monotonic) or
        want_switch_backend.load(.monotonic) or
        want_jump.load(.monotonic) != -1;
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
    \\  nix-badge oled [--eval-screen PATH ...] [--eval-dir DIR] [--content-root DIR] [--oled-width W] [--oled-height H] [--backend fix|nix]
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

// ---------------------------------------------------------------- bling run ---

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
/// emergency fill. This is only ever called on start and on an mtime change, so
/// the open cost is off the hot path.
fn refreshBlob(prev: ?bled.Frames, cfg: *const Config) ?bled.Frames {
    var old = prev;
    if (old) |*o| o.deinit();

    const path = cfg.blob();
    if (path.len == 0) return null;

    var path_buf: [256]u8 = undefined;
    const zpath = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return null;
    return bled.load(zpath) catch |err| {
        std.log.warn("blob {s}: {s}; ignoring it", .{ path, @errorName(err) });
        return null;
    };
}

/// Copy the first `out.len` LEDs of one blob frame's ring-order RGB into `out`
/// with the software brightness scale (a WS2812 chain has no brightness byte).
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

/// The `bling run` service. Pixel-source precedence: the pure-Nix eval pattern,
/// then a baked "BLED" blob, then the hardcoded dim-blue emergency fill (the
/// Zig-computed patterns are gone; pure-Nix content is the only real surface).
/// On a runtime-file mtime change it hot-reloads the CLI-mutable fields AND the
/// blob/eval paths. The static fill idles at 2 Hz (and still repaints, since a
/// WS2812 chain has no error recovery of its own); eval patterns and blobs run
/// at their own pace. The WS2812 encode + spidev write + latch path is identical
/// for every source — only the pixel source differs — so no source can regress
/// flicker.
fn cmdBlingRun(gpa: std.mem.Allocator, base: ?[]const u8, backend_kind: backend.Kind, io: std.Io) CmdError!void {
    var cfg = try loadConfig(base);

    installHandler(.TERM, onStop);
    installHandler(.INT, onStop);

    const bufsiz = readSpidevBufsiz();
    var max_count = maxCountForBufsiz(bufsiz, cfg.encoding.bytesPerLed());

    // A configured, valid blob overrides the LED count (its nleds) and fps; the
    // buffers below are then sized to the effective geometry. A missing/bad blob
    // leaves `blob` null and the eval pattern (or the fill) drives everything.
    var blob = refreshBlob(null, &cfg);
    defer if (blob) |*b| b.deinit();
    applyBlobGeometry(&cfg, blob, bufsiz, max_count);
    clampCount(&cfg, bufsiz, max_count);

    // A configured pure-Nix `eval` pattern (aarch64 only) is the HIGHEST-precedence
    // pixel source, over the blob. It paces on its own nextMs. Sensor inputs are
    // refreshed on a slow tick (battery is a median-of-33 ADC read); `t` is
    // current every frame. Missing/bad/unavailable -> null, so the painter
    // transparently falls back to blob/fill (and riscv, with no eval built in,
    // always takes that path).
    var eval_pat: ?backend.Pattern = openEval(gpa, &cfg, backend_kind, io);
    defer if (eval_pat) |*p| p.deinit();
    var sensors: eval.Fields = .{};
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
            eval_pat = openEval(gpa, &cfg, backend_kind, io);
            last_sensor_ms = 0; // force a sensor refresh next frame
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

        // Source precedence: eval > blob > emergency fill. The eval pattern, when
        // it renders successfully, also dictates the frame period via its nextMs.
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
            fields.backend_id = @intFromEnum(backend_kind);
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
                // No eval pattern and no blob: the pure-Nix patterns are the only
                // real surface, so this hardcoded dim-blue fill is the emergency
                // indicator -- an eval fault stays visible, but calm.
                @memset(lit, .{ .r = 0, .g = 8, .b = 32 });
            }
        }
        // Identical encode + transfer + latch for every source — the flicker-free
        // path is untouched; only the pixel source above differs.
        ws2812.encodeFrame(cfg.encoding, lit, latchBytes(cfg.speed_hz), frame[0..frame_len]);

        sendFrame(fd, frame[0..frame_len], cfg.speed_hz, report_timing);
        report_timing = false;

        // An eval pattern paces on the nextMs it returned; a blob runs at its
        // fps; the static emergency fill idles at 2 Hz (and still repaints,
        // since a WS2812 chain has no error recovery of its own).
        const period_ns: u64 = eval_period_ns orelse if (blob != null)
            std.time.ns_per_s / @as(u64, cfg.fps)
        else
            std.time.ns_per_s / idle_poll_hz;
        // Sleep in <=50 ms slices, re-checking the conf mtime each slice: the
        // USER button's short-press pattern cycle lands as a leds.conf rewrite,
        // and a whole-period sleep deferred noticing it by up to the pattern's
        // own nextMs (a second+ on slow patterns) -- the LED twin of the OLED's
        // hold-the-button bug. Breaking early lets the loop top reload and
        // paint the new pattern within ~50 ms of the press.
        const slice_ns: u64 = 50 * std.time.ns_per_ms;
        var slept: u64 = 0;
        while (slept < period_ns and !stop_requested.load(.monotonic)) {
            const step = @min(slice_ns, period_ns - slept);
            linux.sleepNsec(step);
            slept += step;
            if (!std.meta.eql(linux.mtimeNsec(runtime_conf), seen_mtime)) break;
        }
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
/// the painter transparently falls back to the blob (or the emergency fill).
// The badge content root + its `<nixbadge>` search-path entry (so LED/OLED content can
// `import <nixbadge/lib/...>`). oled takes an optional `--content-root` override; the LED
// painter uses the fixed default.
const default_content_root = "/etc/nixbadge";
const default_nix_path = "nixbadge=" ++ default_content_root;

fn openEval(gpa: std.mem.Allocator, cfg: *const Config, kind: backend.Kind, io: std.Io) ?backend.Pattern {
    if (cfg.eval().len == 0) return null;
    return backend.Pattern.open(gpa, .{ .io = io, .nix_path = default_nix_path }, kind, cfg.eval());
}

/// Snapshot the slow sensor inputs for the eval scope. Called on the sensor tick,
/// not every frame; `t`/width/height/brightness are filled per frame by the caller.
fn gatherSensors(cpu: *screens.CpuMeter) eval.Fields {
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
/// no blob is active (the config's own count/fps stand).
fn applyBlobGeometry(cfg: *Config, blob: ?bled.Frames, bufsiz: u64, max_count: u32) void {
    const frames = blob orelse return;
    cfg.count = frames.nleds;
    cfg.fps = std.math.clamp(@as(u32, frames.fps), 1, 200);
    clampCount(cfg, bufsiz, max_count);
}

/// Log the active blob (or its absence) and the frame geometry, once at start
/// and after every reload.
fn logRunState(cfg: *const Config, blob: ?bled.Frames, frame_len: usize) void {
    if (blob) |frames| {
        std.log.info("blob {s}: {d} leds, {d} fps, {d} frames, brightness {d}, {d} bytes/frame", .{
            cfg.blob(), frames.nleds, frames.fps, frames.frames, cfg.brightness, frame_len,
        });
    } else {
        // No blob: the pixel source is the pure-Nix eval pattern when one is
        // configured (and healthy), else the dim-blue emergency fill.
        std.log.info("no blob: {d} leds, brightness {d}, {d} fps, {d} bytes/frame", .{
            cfg.count, cfg.brightness, cfg.fps, frame_len,
        });
    }
}

/// Re-read the config and adopt the CLI-mutable fields (brightness, fps, count,
/// speed, encoding, blob + eval paths). Hardware identity (device) is not
/// reloaded. A speed change is pushed to the driver; each transfer also carries its
/// own speed, so nothing is reopened.
fn reloadInto(cfg: *Config, base: ?[]const u8, max_count: *u32, bufsiz: u64, fd: linux.fd_t) void {
    var fresh = Config.default();
    layerBase(&fresh, base);
    layerRuntime(&fresh);

    const old_speed = cfg.speed_hz;
    cfg.brightness = fresh.brightness;
    cfg.fps = fresh.fps;
    cfg.count = fresh.count;
    cfg.speed_hz = fresh.speed_hz;
    cfg.encoding = fresh.encoding;
    cfg.setBlob(fresh.blob());
    // The eval path is CLI-mutable too (the short-press cycle rewrites `eval =`).
    // It was missing from this whitelist, so every reload re-opened the STALE
    // startup path while leds.conf marched on -- the button "cycling back to the
    // same pattern" bug. The reload loop reopens the eval pattern right after
    // this returns, so refreshing the path here is all it takes.
    cfg.setEval(fresh.eval());

    max_count.* = maxCountForBufsiz(bufsiz, cfg.encoding.bytesPerLed());
    clampCount(cfg, bufsiz, max_count.*);
    if (cfg.speed_hz != old_speed) {
        var sp: u32 = cfg.speed_hz;
        _ = linux.ioctl(fd, linux.Spi.IOC_WR_MAX_SPEED_HZ, @intFromPtr(&sp)) catch {
            std.log.warn("cannot set {d} Hz", .{cfg.speed_hz});
        };
    }
}

// --------------------------------------------------------------- bling set ---

fn cmdBlingSet(out: *Out, args: []const []const u8) CmdError!void {
    var cfg = Config.default();
    layerRuntime(&cfg); // start from what is live so a partial change keeps the rest

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (optArg(args, &i, "--brightness")) |v| {
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
        } else if (optArg(args, &i, "--blob")) |v| {
            // A path selects a baked BLED animation; an empty value clears it and
            // returns to the eval pattern (or the emergency fill).
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
    out.w().print("brightness = {d}\n", .{cfg.brightness}) catch return error.Failed;
    out.w().print("eval = {s}\n", .{cfg.eval()}) catch return error.Failed;
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

fn cmdBlingShow(out: *Out) CmdError!void {
    var cfg = Config.default();
    layerRuntime(&cfg);
    const w = out.w();
    w.print("brightness = {d}\n", .{cfg.brightness}) catch return error.Failed;
    w.print("blob = {s}\n", .{cfg.blob()}) catch return error.Failed;
    w.print("eval = {s}\n", .{cfg.eval()}) catch return error.Failed;
}

fn cmdBling(gpa: std.mem.Allocator, out: *Out, io: std.Io, args: []const []const u8) CmdError!void {
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
        return cmdBlingRun(gpa, base, kind, io);
    }
    if (std.mem.eql(u8, args[0], "set")) return cmdBlingSet(out, args[1..]);
    if (std.mem.eql(u8, args[0], "show")) return cmdBlingShow(out);
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

    // VBAT pack volts + derived percent from the vbat iio channel (3x AA
    // primaries: no charging state to report).
    const bat = sysfs.readBattery();
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

const oled_longpress_ms = 400;
// A USER-button hold of at least this long switches the evaluator backend live (fix<->nix).
const backend_switch_ms = 5000;

/// Where the pure-Nix LED patterns live; a short press cycles these files.
/// Overridable via `--bling-dir` (oled subcommand arg parse).
var bling_dir: []const u8 = "/etc/nixbadge/bling.d";

/// Advance the runtime config's `eval =` to the NEXT pure-Nix pattern in
/// /etc/nixbadge/bling.d (sorted; NN- prefix = cycle order), leaving every other
/// line untouched so the running service hot-reloads only the pattern. This is
/// the whole user-facing pattern surface now -- the old Zig-computed patterns
/// are gone (an eval fault shows the hardcoded dim-blue emergency fill).
fn blingNextPattern() void {
    // Scan the pattern dir fresh each press: drop-in files join the cycle with
    // no restart (same contract as oled.d).
    var buf: [16][]const u8 = undefined;
    var sfa = std.heap.stackFallback(4096, std.heap.page_allocator);
    const a = sfa.get();
    const n = collectNixScreens(a, bling_dir, &buf, 0);
    defer for (buf[0..n]) |p| a.free(p);
    if (n == 0) {
        std.log.warn("oled: no LED patterns in {s}; press ignored", .{bling_dir});
        return;
    }

    // Read the current eval path through the same parser the service uses, find
    // it in the cycle, and step to the next (an unknown/absent path starts at 0).
    var current = Config.default();
    layerRuntime(&current);
    var next_ix: usize = 0;
    const cur = current.eval();
    if (cur.len > 0) {
        for (buf[0..n], 0..) |p, i| {
            if (std.mem.eql(u8, p, cur)) {
                next_ix = (i + 1) % n;
                break;
            }
        }
    }
    const want = buf[next_ix];

    switch (linux.mkdir(runtime_dir, 0o755)) {
        .created, .exists => {},
        .failed => {
            std.log.warn("oled: cannot create {s}", .{runtime_dir});
            return;
        },
    }

    // Rewrite the file line by line, replacing only the `eval =` line (appending
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
        if (std.mem.startsWith(u8, trimmed, "eval")) {
            const after = std.mem.trimStart(u8, trimmed[4..], " \t");
            if (after.len > 0 and after[0] == '=') {
                w.print("eval = {s}\n", .{want}) catch return;
                replaced = true;
                continue;
            }
        }
        w.writeAll(line) catch return;
    }
    if (!replaced) w.print("eval = {s}\n", .{want}) catch return;

    linux.writeFile(runtime_conf, w.buffered()) catch {
        std.log.warn("oled: cannot write {s}", .{runtime_conf});
        return;
    };
    std.log.info("oled: LED pattern -> {s}", .{want});
}

/// Gather the per-frame snapshot: the animation clock, battery/USB, and the proc
/// meters. The CPU delta is tracked in `cpu` across frames.
// Boot-identity strings for the bootinfo screen (`scope.nixosVersion` /
// `scope.kernelVersion`). fix is pure (no uname/readFile at eval), so the
// runtime reads them ONCE at oled start -- they are constant per boot -- and
// oledGather copies the cached slices into every Context snapshot.
var nixos_version_buf: [64:0]u8 = undefined;
var kernel_version_buf: [64:0]u8 = undefined;
var nixos_version: [:0]const u8 = "";
var kernel_version: [:0]const u8 = "";

fn cacheVersion(buf: *[64:0]u8, s: []const u8) [:0]const u8 {
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}

/// Kernel release from uname(2) (always available); NixOS version from
/// /etc/os-release VERSION_ID, falling back to the `init=` store-path label on
/// /proc/cmdline (`init=/nix/store/<hash>-nixos-system-<host>-<label>/init`) --
/// the initrd ships no os-release, and systemd-initrd mounts /proc early
/// enough that the cmdline is always there. The hostname may itself contain
/// dashes, so the label is the first dash-separated token starting with a
/// digit (NixOS labels look like 26.05.20260830.1a2b3c).
fn readBootInfo() void {
    const uts = std.posix.uname();
    kernel_version = cacheVersion(&kernel_version_buf, std.mem.sliceTo(&uts.release, 0));

    var fbuf: [4096]u8 = undefined;
    nixos_version = cacheVersion(&nixos_version_buf, blk: {
        // The cmdline `init=` store-path label is the PRIMARY source: it is the
        // full version ("26.05.20260812.9f78f44"), and /proc/cmdline exists
        // everywhere this runs (initrd AND stage 2), while os-release is absent
        // in the initrd and only as fresh as whoever populated it. The screen
        // derives its "26.05" hero from this same string (truncate at the
        // second dot), so one source feeds both renderings.
        if (linux.readFile("/proc/cmdline", &fbuf)) |txt| {
            if (std.mem.indexOf(u8, txt, "-nixos-system-")) |i| {
                var rest = txt[i + "-nixos-system-".len ..];
                if (std.mem.indexOfAny(u8, rest, " /\n")) |end| rest = rest[0..end];
                var toks = std.mem.splitScalar(u8, rest, '-');
                var off: usize = 0;
                while (toks.next()) |tok| {
                    if (tok.len > 0 and std.ascii.isDigit(tok[0])) break :blk rest[off..];
                    off += tok.len + 1;
                }
            }
        }
        // Fallback for an unlabeled init= (dev sandboxes, custom boots):
        // os-release BUILD_ID is the full label, VERSION_ID the bare release.
        if (linux.readFile("/etc/os-release", &fbuf)) |txt| {
            var lines = std.mem.splitScalar(u8, txt, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "BUILD_ID=")) {
                    break :blk std.mem.trim(u8, line["BUILD_ID=".len..], "\" \r");
                }
            }
            lines = std.mem.splitScalar(u8, txt, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "VERSION_ID=")) {
                    break :blk std.mem.trim(u8, line["VERSION_ID=".len..], "\" \r");
                }
            }
        }
        break :blk "";
    });
}

fn oledGather(cpu: *screens.CpuMeter) screens.Context {
    const bat = sysfs.readBattery();
    var l1: f64 = 0;
    var l5: f64 = 0;
    screens.readLoad1And5(&l1, &l5);
    return .{
        .now_ms = linux.monotonicMsec(),
        .on_usb = sysfs.readLine("usb-vbus-det"),
        .strap = if (sysfs.readStrap()) |core| switch (core) {
            .arm => @as(u8, 1),
            .riscv => @as(u8, 2),
        } else 0,
        .battery_mv = bat.millivolts,
        .battery_pct = bat.percent,
        // Kernel-scaled iio-rescale read; the rail is stiff, so no smoothing.
        .vsel_mv = if (sysfs.readVselVolts()) |v| @intFromFloat(v * 1000.0 + 0.5) else 0,
        .load1 = l1,
        .cpu_pct = cpu.sample(),
        .mem_pct = @intFromFloat(screens.readMemUsedFrac() * 100.0 + 0.5),
        .uptime_s = screens.readUptimeS(),
        .nixos_version = nixos_version,
        .kernel_version = kernel_version,
    };
}

/// Carries button press timing across poll iterations (bootswap's hold loop).
const PressState = struct { start_ms: u64 = 0, down: bool = false };

/// Stops the button sampler thread at shutdown (set + join).
var button_sampler_stop = std.atomic.Value(bool).init(false);

/// USER-button sampler THREAD. The RTC/PWR gpio has no edge IRQ, so the button
/// must be level-polled -- and polling from the render loop starved the instant
/// frames got slow: a heavy screen spends 250 ms - 2 s inside one eval call
/// where nothing samples, so a short press (both edges inside one eval) was
/// physically unobservable and the user had to HOLD the button until the next
/// frame boundary. This thread samples every 15 ms regardless of frame rate and
/// reports through the same atomics SIGUSR1/2 use (the sanctioned global-state
/// exception), so the loop's existing eventPending()/flag consumption is
/// unchanged. Action latency is still bounded by the in-flight eval (the loop
/// only reacts between frames), but no press is ever LOST. Release < 400 ms
/// cycles the LED pattern, < backend_switch_ms cycles the screen, else flips
/// the evaluator backend.
fn buttonSampler(btn: sysfs.Button) void {
    var down = false;
    var start_ms: u64 = 0;
    while (!button_sampler_stop.load(.monotonic)) {
        if (btn.level()) |lvl| {
            const t = linux.monotonicMsec();
            const pressed = lvl == 0; // active-low
            if (pressed and !down) {
                down = true;
                start_ms = t;
            } else if (!pressed and down) {
                down = false;
                const held = t - start_ms;
                const flag = if (held >= backend_switch_ms)
                    &want_switch_backend
                else if (held >= oled_longpress_ms)
                    &want_next_screen
                else
                    &want_next_pattern;
                flag.store(true, .monotonic);
            }
        }
        linux.sleepNsec(15 * std.time.ns_per_ms);
    }
}

/// Sleep until the absolute monotonic `deadline_ms` (the frame's start time plus
/// its nextMs), waking early on a pending stop/pattern/screen flag or a SIGUSR1/2
/// (poll returns EINTR). The deadline is anchored to the frame START, not to this
/// call, so the frame PERIOD is nextMs total -- the render + flush time is absorbed
/// into the budget, not added on top of it. If render+flush already overran nextMs
/// the deadline is in the past and this returns immediately. Steps at 15 ms so a
/// button flag latched by the sampler thread is acted on promptly mid-wait.
fn oledWait(deadline_ms: u64) void {
    const poll_ms: u64 = 15;
    while (true) {
        if (eventPending()) return;
        const now_ms = linux.monotonicMsec();
        if (now_ms >= deadline_ms) return;
        const remain = deadline_ms - now_ms;
        const step: u64 = @min(poll_ms, remain);
        linux.sleepNsec(step * std.time.ns_per_ms);
    }
}

// Where the current OLED screen is remembered across reboots. The LED pattern
// already persists (the bling service layers /etc/nixbadge/leds.conf over the
// declarative base at startup); this is the screen's equivalent. Persisted by
// NAME, not index, so it survives a registry that changes shape (the content
// set changing across boots).
const oled_state_file: [*:0]const u8 = "/etc/nixbadge/oled.state";

/// Restore the last-shown screen. A missing file or an unknown name (e.g. the
/// saved screen is gone this boot) starts at screen 0.
fn restoreScreen(active: []const Screen) usize {
    var buf: [64]u8 = undefined;
    const raw = linux.readFile(oled_state_file, &buf) orelse return 0;
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
    linux.writeFile(oled_state_file, line) catch
        std.log.warn("oled: cannot persist screen to {s}", .{oled_state_file});
}

// Cap on the number of pure-Nix eval screens passed via `--eval-screen`. Five
// today (badapple-live + battery/load/power/clock + currentsystem); size with
// headroom so a config can add a few more without a code change. A path past the
// cap is logged and ignored.
const max_eval_screens = 16;

/// Scan `dir` for `*.nix` files and append their full paths (sorted ascending by name, so a
/// `NN-` numeric prefix sets the cycle order) to `out` starting at `count`; returns the new
/// count. Full paths are gpa-duped (process-lifetime; the oled loop holds them until exit).
/// Bounded by out.len; a directory with more `.nix` files than fit is logged and truncated.
/// A borrowed dirent name is copied by the allocPrint, so nothing dangles past `next()`.
fn collectNixScreens(gpa: std.mem.Allocator, dir: []const u8, out: [][]const u8, count: usize) usize {
    var dbuf: [512]u8 = undefined;
    const zdir = std.fmt.bufPrintZ(&dbuf, "{s}", .{dir}) catch return count;
    var iterbuf: [8192]u8 align(8) = undefined;
    var it = linux.openDirIter(zdir.ptr, &iterbuf) orelse {
        std.log.warn("oled: --eval-dir {s} not readable; ignoring", .{dir});
        return count;
    };
    defer it.deinit();

    var c = count;
    while (it.next()) |e| {
        if (!std.mem.endsWith(u8, e.name, ".nix")) continue;
        if (c >= out.len) {
            std.log.warn("oled: --eval-dir {s} has more than {d} screens; dropping the rest", .{ dir, out.len });
            break;
        }
        // allocPrint copies the borrowed dirent name into a fresh, process-lifetime path.
        out[c] = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, e.name }) catch break;
        c += 1;
    }
    // Every path shares the `dir + "/"` prefix, so a plain lexical sort orders by basename.
    std.mem.sort([]const u8, out[count..c], {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return c;
}

/// Take the panel from a surviving predecessor -- the initrd boot splash
/// (oled-early.nix) lives through switch_root and keeps painting while THIS
/// instance pays the ScreenSet compile; its pid crosses over in /run's pidfile.
/// SIGTERM it and wait (<=1s) for the bus to free. Best-effort: no pidfile,
/// a dead pid, or our own (a restart re-reading its own leftover) = no-op.
fn killPredecessor() void {
    var buf: [32]u8 = undefined;
    const txt = linux.readFile(oled_pidfile, &buf) orelse return;
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, txt, " \n\r"), 10) catch return;
    if (pid <= 0 or pid == linux.getpid()) return;
    // A stale pidfile (e.g. a plain restart: systemd already reaped the old
    // instance) can hold a RECYCLED pid by the time our compile finishes --
    // only signal something that is actually a nix-badge.
    var comm_path_buf: [48]u8 = undefined;
    var comm_buf: [32]u8 = undefined;
    const comm_path = std.fmt.bufPrintZ(&comm_path_buf, "/proc/{d}/comm", .{pid}) catch return;
    const comm = linux.readFile(comm_path, &comm_buf) orelse return;
    if (!std.mem.startsWith(u8, comm, "nix-badge")) return;
    linux.kill(pid, 15) catch return; // SIGTERM; ESRCH -> already gone
    var tries: u32 = 0;
    while (tries < 20) : (tries += 1) {
        linux.kill(pid, 0) catch return; // signal 0 probes existence
        linux.sleepNsec(50 * std.time.ns_per_ms);
    }
    std.log.warn("oled: predecessor pid {d} still alive after 1s; taking the panel anyway", .{pid});
}

fn cmdOled(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) CmdError!void {
    // Cache the constant-per-boot version strings before anything gathers a
    // Context (the registry-build probe render already reads them).
    readBootInfo();
    // `--eval-screen PATH` is repeatable: each occurrence appends a pure-Nix OLED
    // screen. They are compiled into ONE shared fix Engine (a ScreenSet) so the
    // Value/chunk heap is paid once, not once per screen.
    var eval_screen_paths: [max_eval_screens][]const u8 = undefined;
    var eval_screen_count: usize = 0;
    var oled_width: u16 = oled.default_width;
    var oled_height: u16 = oled.default_height;
    // The USER button line, by device-tree name. Defaults to the dedicated USER
    // button (PWR_GPIO1); btn-boot-n is deliberately NOT the default so the
    // bootswap daemon can own it. A name the DT does not expose leaves the button
    // null and only SIGUSR1/2 drive the screens/patterns.
    var button_name: []const u8 = "user-btn";
    // The starting evaluator backend (default fix). A >5 s button hold flips it live; the
    // choice persists across restarts (see restoreBackend/persistBackend).
    var backend_kind: backend.Kind = .fix;
    // Root for the `<nixbadge>` search path, so a screen can `import <nixbadge/lib/font.nix>`.
    var content_root: []const u8 = default_content_root;
    // GC collection line for the fix Engine, in bytes (0 = evaluator default). CRITICAL on
    // the 351MB badge: fix's auto line clamps to a 256MB floor and grows into swap before
    // collecting, so the module passes an explicit --gc-budget-mb (see eval.Opts, #28).
    var gc_budget_bytes: u64 = 0;
    // Panel controller: auto probes at open (SH1106 supports I2C RAM read-back,
    // SSD1306 does not); an explicit value skips the probe.
    var oled_controller: oled.ControllerChoice = .auto;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (optArg(args, &i, "--backend")) |v| {
            backend_kind = parseBackendKind(v);
        } else if (optArg(args, &i, "--content-root")) |v| {
            content_root = v;
        } else if (optArg(args, &i, "--bling-dir")) |v| {
            // Where the short-press LED pattern cycle scans (default /etc/nixbadge/bling.d).
            bling_dir = v;
        } else if (optArg(args, &i, "--gc-budget-mb")) |v| {
            const mb = std.fmt.parseInt(u32, v, 10) catch {
                std.log.err("oled: bad --gc-budget-mb '{s}'", .{v});
                return error.Usage;
            };
            gc_budget_bytes = @as(u64, mb) << 20;
        } else if (optArg(args, &i, "--oled-controller")) |v| {
            oled_controller = std.meta.stringToEnum(oled.ControllerChoice, v) orelse {
                std.log.err("oled: bad --oled-controller '{s}' (auto|ssd1306|sh1106)", .{v});
                return error.Usage;
            };
        } else if (optArg(args, &i, "--eval-dir")) |v| {
            // Drop-in dir-based content: scan v for *.nix, sorted by name (NN- prefix =
            // cycle order). Appends to any explicit --eval-screen already collected.
            eval_screen_count = collectNixScreens(gpa, v, &eval_screen_paths, eval_screen_count);
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

    // The panel is optional hardware; open it first so its geometry is known
    // (it sizes the shared eval framebuffer below). A missing bus / bad size /
    // OOM all mean "no panel" and we exit 0 (like the C) so systemd does not
    // respin us.
    var panel = oled.Panel.open(gpa, oled_width, oled_height, oled_controller) orelse {
        std.log.warn("oled: no OLED panel, nothing to do", .{});
        return;
    };
    defer panel.close();
    // Memory guard (#30): the fix Engine (ScreenSet, ~72 MB) is only stood up
    // below, AFTER this. An absent panel NAKs the probe write, so we exit 0 here
    // and never pay for the Engine on a display-less config. (systemd does not
    // respin on exit 0.) Deliberately a NON-DESTRUCTIVE NOP, not init: the
    // initrd boot splash may still be painting the panel (it survives
    // switch_root), and it keeps doing so through the long ScreenSet compile
    // below -- the real init runs after killPredecessor takes the panel over.
    panel.probe() catch {
        std.log.warn("oled: no OLED responding at 0x{x:0>2}; skipping (fix Engine not started)", .{oled.i2c_addr});
        return;
    };

    // Open the pure-Nix eval screens: ALL `--eval-screen` paths compiled into ONE
    // shared fix Engine (a ScreenSet), each a lambda applied per frame and decoded
    // to page-major bytes. Only on an eval build (aarch64); a screen that fails to
    // compile is skipped but the rest load. When at least one loads we get a set
    // and a shared framebuffer; otherwise `eval_set` stays null and the daemon
    // exits below (pure-Nix content is the only screen surface).
    // Shared eval options: the file-IO backend (screen `import`/`readFile`) + the
    // `<nixbadge>` search path so a screen can `import <nixbadge/lib/font.nix>`. Held at
    // function scope so the live backend-switch reopen below reuses it.
    var nix_path_buf: [512]u8 = undefined;
    const nix_path = std.fmt.bufPrint(&nix_path_buf, "nixbadge={s}", .{content_root}) catch "nixbadge=/etc/nixbadge";
    const eval_opts = eval.Opts{
        .io = io,
        .nix_path = nix_path,
        .gc_budget_bytes = if (gc_budget_bytes > 0) gc_budget_bytes else null,
    };

    var eval_set: ?backend.ScreenSet = null;
    var eval_fb: ?[]u8 = null;
    if (eval_screen_count > 0) {
        // A live backend switch persists its choice; honour it over the ExecStart default.
        backend_kind = restoreBackend(backend_kind);
        if (backend.ScreenSet.open(gpa, eval_opts, backend_kind, eval_screen_paths[0..eval_screen_count])) |s| {
            const fb = gpa.alloc(u8, @as(usize, panel.width) * (panel.height / 8)) catch blk: {
                std.log.warn("oled: cannot alloc eval framebuffer; dropping eval screens", .{});
                break :blk null;
            };
            if (fb) |b| {
                eval_set = s;
                eval_fb = b;
                backend_kind = s.kind(); // reflect a nix->fix fallback at open()
            } else {
                var dead = s;
                dead.deinit();
            }
        }
    }
    defer if (eval_set) |*s| s.deinit();
    defer if (eval_fb) |b| gpa.free(b);

    // Build the screen registry from the eval set: the cyclable screens are the N
    // pure-Nix eval screens, rendered via the shared Engine. There is no Zig
    // fallback registry any more -- pure-Nix content is the only screen surface --
    // so no loaded eval screens (every screen failed to compile, or the eval-less
    // riscv core) means nothing to show: log it and exit 0 so systemd does not
    // respin a daemon that has no content.
    var registry: [max_eval_screens]Screen = undefined;
    var active_screens: []Screen = undefined;
    // Minimal probe scope for the registry's contract-v2 `hidden` reads.
    const probe_fields = eval.Fields{ .width = panel.width, .height = panel.height };
    if (eval_set) |*s| {
        active_screens = buildEvalRegistry(&registry, s, probe_fields);
    } else {
        std.log.err("oled: no eval screens loaded; nothing to show", .{});
        return;
    }

    // The ScreenSet is compiled; NOW take the panel: kill the surviving initrd
    // splash (it kept the panel painted through the compile above) and run the
    // real init+clear. The dark gap is the ~100ms between its last flush and
    // our first frame, not the whole compile. An init fault after the takeover
    // still exits 0 (panel yanked mid-boot).
    killPredecessor();
    panel.init() catch {
        std.log.warn("oled: init failed at 0x{x:0>2} after takeover; skipping", .{oled.i2c_addr});
        return;
    };

    installHandler(.TERM, onStop);
    installHandler(.INT, onStop);
    installHandler(.USR1, onUser);
    installHandler(.USR2, onUser);
    // The screen-control API: RT signals 40..55 jump to screen 0..15, 56 to the
    // "swapcore" screen (see the sig_jump_* docs at onJump).
    {
        var sn: u32 = 0;
        while (sn < sig_jump_count) : (sn += 1)
            installHandler(@enumFromInt(sig_jump_base + sn), onJump);
        installHandler(@enumFromInt(sig_swapcore), onJump);
    }
    // Advertise the pid so peers (bootswap's hold indicator) can signal without
    // systemctl (which would drag its closure into the binary).
    {
        var pid_buf: [16]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&pid_buf, "{d}\n", .{linux.getpid()}) catch "";
        linux.writeFile(oled_pidfile, pid_str) catch
            std.log.warn("oled: cannot write {s}; RT-signal peers won't find us", .{oled_pidfile});
    }

    // Request the USER button once as a polled INPUT (the RTC/PWR gpio has no edge
    // IRQ, so the edge path ENXIOs) and hand it to the sampler THREAD -- see
    // buttonSampler for why in-loop polling could not work on slow screens. Null
    // when the DT exposes no line by this name, in which case only SIGUSR1/2 drive
    // the screens/patterns.
    var button = sysfs.Button.openPolled(button_name);
    defer if (button) |*b| b.close();
    if (button == null) std.log.info("oled: button '{s}' not found; SIGUSR1/2 only", .{button_name});
    const button_thread: ?std.Thread = if (button) |btn|
        std.Thread.spawn(.{}, buttonSampler, .{btn}) catch |err| blk: {
            std.log.warn("oled: button sampler thread failed ({s}); SIGUSR1/2 only", .{@errorName(err)});
            break :blk null;
        }
    else
        null;
    defer if (button_thread) |t| {
        button_sampler_stop.store(true, .monotonic);
        t.join();
    };

    std.log.info("oled up on {s} @ 0x{x:0>2}, {d} screens, first {s}", .{
        oled.i2c_bus, oled.i2c_addr, active_screens.len, active_screens[0].name,
    });

    var screen_ix: usize = restoreScreen(active_screens);
    // Never resume ON a hidden (transient) screen: fall back to 0.
    if (screen_ix < active_screens.len and active_screens[screen_ix].hidden) screen_ix = 0;
    if (screen_ix != 0) std.log.info("oled: resuming screen {s}", .{active_screens[screen_ix].name});
    // Contract-v2 navigation state: where auto-return goes back to, and when the
    // current screen was entered (the auto-return clock).
    var prev_screen_ix: usize = 0;
    var screen_entered_ms: u64 = linux.monotonicMsec();
    var cpu = screens.CpuMeter.init();
    var flush_fail_count: u32 = 0;

    // Effective-fps window: log the achieved rate every ~3 s so the sustained frame
    // rate (esp. 60 fps Bad Apple) is visible in the journal without a per-frame log.
    // Also sums the per-frame eval (render+decode+collect) and flush time so the
    // window log shows WHERE the frame budget goes (eval-bound vs bus-bound).
    var fps_frames: u64 = 0;
    var fps_win_ms: u64 = 0;
    var eval_ns_sum: i128 = 0;
    var flush_ns_sum: i128 = 0;
    // Carry the last window's measured fps forward into `scope.fps` each frame, so a screen
    // can draw a live HUD (the value updates once per ~3 s window). 0 until the first close.
    var last_fps: u32 = 0;

    // Sensors (battery = a median-of-33 SARADC read, plus /proc load/cpu/mem/uptime and
    // the VBUS gpio) move on a human timescale, not per frame. Reading them every frame
    // cost ~15 ms/frame -- the true ~46 fps ceiling, NOT eval (~1 ms) or I2C flush
    // (~5 ms), which is why raising the bus to 1 MHz changed nothing. Refresh on a slow
    // tick and carry the snapshot between refreshes; only now_ms (the animation clock +
    // the frame-rate-limiter anchor) updates every frame.
    const sensor_refresh_ms: u64 = 500;
    var ctx = oledGather(&cpu);
    var last_gather_ms: u64 = ctx.now_ms;
    // Battery EMA across gathers: a median-of-33 rejects single-read SPIKES but the
    // leaky-divider SARADC also WANDERS slowly (temperature/load), so back-to-back
    // 500 ms snapshots still jump visibly. Blend at alpha=0.25 (~2 s time constant)
    // and derive percent from the SMOOTHED millivolts so both readouts agree.
    var bat_mv_ema: ?f64 = if (ctx.battery_mv) |mv| @floatFromInt(mv) else null;

    while (!stop_requested.load(.monotonic)) {
        const now_ms = linux.monotonicMsec();
        if (now_ms - last_gather_ms >= sensor_refresh_ms) {
            ctx = oledGather(&cpu);
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
        // Render the current screen: apply its ScreenSet lambda into the shared
        // framebuffer and blit it. A NULL return means the screen faulted ->
        // drop it by name so the loop falls back to the remaining screens (never
        // spins the log, the fault is logged once inside renderOled).
        const set_ptr = if (eval_set) |*s| s else null;
        const t_eval0 = linux.monotonicNsec();
        const rendered = renderScreen(cur, &panel, &ctx, set_ptr, eval_fb, @intFromEnum(backend_kind), last_fps) orelse blk: {
            active_screens = dropScreen(active_screens, cur.name, &screen_ix);
            std.log.warn("oled: eval screen '{s}' dropped after render fault", .{cur.name});
            break :blk eval.OledFrame{ .next_ms = 100, .dirty = .{ .full = true } };
        };
        const t_eval1 = linux.monotonicNsec();
        // A delta frame flushes only its changed columns (a few dozen bytes); a full
        // frame (keyframe / info screen) flushes the whole panel. This partial flush
        // is what keeps 60 fps Bad Apple under the 400 kHz I2C bandwidth.
        if (flushDirty(&panel, rendered.dirty)) |_| {
            if (flush_fail_count > 0) {
                // The bus just came back after a failure streak. Mid-streak re-inits
                // raced the unstable bus, and a moved/re-powered panel wakes in its
                // RESET state (display off) -- so successful flushes alone leave it
                // dark (field-observed on a port swap: "flush~4ms" yet a dark panel
                // until a service restart). One clean redetect + init + full redraw
                // now that writes are landing again.
                std.log.info("oled: bus recovered after {d} flush failures; re-initing", .{flush_fail_count});
                _ = panel.redetect();
                panel.init() catch {};
                panel.flush() catch {};
            }
            flush_fail_count = 0;
        } else |_| {
            // Self-heal a panel that fell off the bus (brown-out / module reset): a
            // single NAK is transient noise, but a RUN of failures means the
            // controller lost its init state -- re-run the init sequence and push a
            // full redraw. Retrying every 8th failure keeps the recovery attempts
            // paced by the frame loop instead of hammering a dead bus.
            flush_fail_count += 1;
            if (flush_fail_count == 1) std.log.warn("oled: flush failed", .{});
            if (flush_fail_count % 8 == 0) {
                std.log.warn("oled: {d} consecutive flush failures; re-initing panel", .{flush_fail_count});
                // A panel swap always drops the bus first, so recovery is where a
                // DIFFERENT controller may now be seated: re-probe before re-init
                // (a dead-bus probe keeps the last known controller).
                _ = panel.redetect();
                if (panel.init()) |_| {
                    panel.flush() catch {};
                } else |_| {}
            }
        }
        const t_flush1 = linux.monotonicNsec();

        // Effective fps over a ~3 s window (measured before the wait, so it reflects
        // the true achieved rate whether render- or wait-bound), plus the average
        // eval and flush split so the log shows what the frame budget is spent on.
        fps_frames += 1;
        eval_ns_sum += t_eval1 - t_eval0;
        flush_ns_sum += t_flush1 - t_eval1;
        if (fps_win_ms == 0) fps_win_ms = ctx.now_ms;
        if (ctx.now_ms - fps_win_ms >= 3000) {
            const denom = @as(i128, @intCast(fps_frames)) * 1_000_000;
            const evms = @divTrunc(eval_ns_sum, denom);
            const flms = @divTrunc(flush_ns_sum, denom);
            // Collect time is a SUBSET of eval (it runs inside renderScreen); shown
            // separately so eval-minus-collect = the per-frame apply+decode cost.
            const collms = @divTrunc(fixeval.takeCollectNs(), denom);
            last_fps = @intCast(fps_frames * 1000 / (ctx.now_ms - fps_win_ms));
            // Backend tag ([fix]/[nix]) + self RSS so the A/B log shows fps, eval split, and
            // the evaluator's memory cost side by side on the same screen.
            std.log.info("oled: {d} fps [{s}] ({s}) eval~{d}ms (collect~{d}ms) flush~{d}ms rss~{d}MB", .{
                last_fps, backendName(backend_kind), cur.name, evms, collms, flms, readSelfRssKb() / 1024,
            });
            fps_frames = 0;
            fps_win_ms = ctx.now_ms;
            eval_ns_sum = 0;
            flush_ns_sum = 0;
        }

        // Frame-rate limit against the frame START (ctx.now_ms), so the period is
        // nextMs total, not nextMs on top of the render+flush time (which halved the
        // effective rate). A frame that overran nextMs makes this a no-op.
        oledWait(ctx.now_ms + rendered.next_ms);

        if (want_next_pattern.swap(false, .monotonic)) blingNextPattern();
        if (want_next_screen.swap(false, .monotonic)) {
            // Long-press cycle skips contract-v2 hidden screens (they are only
            // reachable by a direct RT jump). Bounded walk: if EVERY screen is
            // hidden we stay put rather than spin.
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
                persistScreen(active_screens[screen_ix].name);
                std.log.info("oled: screen -> {s}", .{active_screens[screen_ix].name});
            }
        }
        // RT-signal jumps: 40+N -> screen N; 56 -> the "swapcore" screen. Direct
        // jumps reach hidden screens; transient (hidden) targets are not persisted
        // so a reboot never lands on one.
        const jump = want_jump.swap(-1, .monotonic);
        if (jump != -1) {
            const target: ?usize = if (jump == -2)
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
                    if (!active_screens[tix].hidden) persistScreen(active_screens[tix].name);
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
                eval_set = backend.ScreenSet.open(gpa, eval_opts, new_kind, eval_screen_paths[0..eval_screen_count]) orelse
                    backend.ScreenSet.open(gpa, eval_opts, cur_kind, eval_screen_paths[0..eval_screen_count]);
                if (eval_set) |*ns| {
                    backend_kind = ns.kind();
                    persistBackend(backend_kind);
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
    panel.blankOff() catch |err| std.log.warn("oled: blank-off failed: {s}", .{@errorName(err)});
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

/// Render the current screen and return its nextMs hint + dirty region, or null
/// when the screen faulted (the caller drops it). The screen's ScreenSet lambda
/// is applied into the shared `fb` (a delta screen mutates it in place), then
/// blitted; the returned dirty region lets the caller flush minimally.
fn renderScreen(
    screen: Screen,
    panel: *oled.Panel,
    ctx: *const screens.Context,
    set: ?*backend.ScreenSet,
    fb: ?[]u8,
    backend_id: u8,
    fps: u32,
) ?eval.OledFrame {
    // The set + framebuffer are created together before the loop starts (the
    // daemon exits when no eval screens load), so a missing one is a bug, not a
    // runtime fault; paint nothing and idle rather than crash the daemon.
    const s = set orelse return .{ .next_ms = 100, .dirty = .{ .full = true } };
    const b = fb orelse return .{ .next_ms = 100, .dirty = .{ .full = true } };
    const r = s.renderOled(screen.eval, evalFields(panel, ctx, backend_id, fps), b) catch return null;
    panel.blit(b);
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
fn evalFields(panel: *const oled.Panel, ctx: *const screens.Context, backend_id: u8, fps: u32) eval.Fields {
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

// Where the live-chosen evaluator backend is remembered across restarts (like oled.state
// for the screen). Persisted by name ("fix"/"nix").
const backend_state_file: [*:0]const u8 = "/etc/nixbadge/oled.backend";

/// Restore the last live-chosen backend, or `dflt` when there is no saved choice. A saved
/// "nix" on a fix-only build still falls back to fix at open(), so this is safe to honour.
fn restoreBackend(dflt: backend.Kind) backend.Kind {
    var buf: [16]u8 = undefined;
    const raw = linux.readFile(backend_state_file, &buf) orelse return dflt;
    const name = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, name, "nix")) return .nix;
    if (std.mem.eql(u8, name, "fix")) return .fix;
    return dflt;
}

/// Persist the current backend for the next start. Best-effort (a write fault only loses
/// which backend was up), so it is logged, not fatal.
fn persistBackend(kind: backend.Kind) void {
    ensureRuntimeDir() catch return;
    var buf: [16]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}\n", .{backendName(kind)}) catch return;
    linux.writeFile(backend_state_file, line) catch
        std.log.warn("oled: cannot persist backend to {s}", .{backend_state_file});
}

/// This process's resident set size in KiB, from /proc/self/status `VmRSS`. Used for the
/// backend-tagged fps window log so the fix-vs-nix RSS is visible next to fps. 0 on any
/// read/parse fault (the log just shows rss~0MB).
fn readSelfRssKb() u64 {
    var buf: [4096]u8 = undefined;
    const raw = linux.readFile("/proc/self/status", &buf) orelse return 0;
    return parseVmRssKb(raw) orelse 0;
}

/// Parse the `VmRSS:` kB value out of a /proc/self/status body. Factored for host testing.
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
// A daemon that swaps the boot core when the USER holds the BOOT button. On a long
// continuous hold (>= HOLD_MS) it latches the OTHER core and reboots, so a user
// can flip ARM<->RISC-V from the button alone (board switch on AUTO). A short press
// does nothing. The button is watched by name (portb, gpiochip renumbers), request-
// once + edge poll() like the oled USER button.

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
/// core and reboot. The BOOT gpio (portb) delivers no edge IRQ -- an edge poll()
/// there blocks forever -- so LEVEL-POLL it like the USER button: sample the line,
/// and a continuous hold reaching bootswap_hold_ms fires the swap ONCE.
fn cmdBootswap(io: std.Io) void {
    installHandler(.TERM, onStop);
    installHandler(.INT, onStop);

    var button = sysfs.Button.openPolled("btn-boot-n") orelse {
        std.log.info("bootswap: no btn-boot-n line; nothing to do", .{});
        return; // non-fatal, exit 0 so systemd does not respin
    };
    defer button.close();

    std.log.info("bootswap: watching BOOT button, hold {d} ms to swap core", .{bootswap_hold_ms});

    // Active-low: 0 = pressed. `fired` latches so one continuous hold triggers at
    // most one swap; it clears on release, so the user must let go and re-hold.
    const poll_ms: u64 = 50;
    var press: PressState = .{};
    var fired = false;
    while (!stop_requested.load(.monotonic)) {
        const pressed = if (button.level()) |lvl| lvl == 0 else false;
        if (pressed and !press.down) {
            press = .{ .start_ms = linux.monotonicMsec(), .down = true };
            fired = false;
            // Boot-button UX: tell the oled daemon (via its pidfile + the RT
            // screen-control API) to show the "swapcore" screen while the hold is
            // in progress. Best-effort: no oled/pidfile/screen -> nothing shown.
            var pid_buf: [32]u8 = undefined;
            if (linux.readFile("/run/nixbadge-oled.pid", &pid_buf)) |raw| {
                const t = std.mem.trim(u8, raw, " \t\r\n");
                if (std.fmt.parseInt(i32, t, 10)) |opid| {
                    linux.kill(opid, sig_swapcore) catch {};
                } else |_| {}
            }
        } else if (pressed and press.down and !fired) {
            const held = linux.monotonicMsec() - press.start_ms;
            if (held >= bootswap_hold_ms) {
                fired = true;
                doBootswap(io); // returns only if it did not reboot (not AUTO, etc.)
            }
        } else if (!pressed and press.down) {
            press.down = false; // released: a short press does nothing
        }
        linux.sleepNsec(poll_ms * std.time.ns_per_ms);
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
        fixeval.selftest(gpa, init.io) catch |err| {
            std.log.err("fix-selftest failed: {s}", .{@errorName(err)});
            out.flush();
            std.process.exit(1);
        };
        return;
    }

    // nix-selftest: the equivalent smoke test for the upstream Nix C API backend -- the
    // first real exercise of the C++ static link (libnixexpr + libstdc++). Exits non-zero
    // on any failure (or a nix-less build) so a broken link is caught loudly.
    if (std.mem.eql(u8, cmd, "nix-selftest")) {
        if (!nixeval.selftest()) {
            out.flush();
            std.process.exit(1);
        }
        std.log.info("nix-selftest: OK", .{});
        return;
    }

    const result: CmdError!void = if (std.mem.eql(u8, cmd, "bling"))
        cmdBling(gpa, &out, init.io, rest)
    else if (std.mem.eql(u8, cmd, "core"))
        cmdCore(&out, rest)
    else if (std.mem.eql(u8, cmd, "power"))
        cmdPower(&out)
    else if (std.mem.eql(u8, cmd, "oled"))
        cmdOled(gpa, init.io, rest)
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
    _ = bled;
    _ = screens;
    _ = fixeval;
    _ = nixeval;
    _ = eval;
    _ = backend;
}

test "parseVmRssKb pulls the VmRSS kB field" {
    const status =
        \\VmPeak:   123456 kB
        \\VmSize:   120000 kB
        \\VmRSS:     45678 kB
        \\VmData:    10000 kB
    ;
    try std.testing.expectEqual(@as(?u64, 45678), parseVmRssKb(status));
    // Tab-separated (as real /proc uses) also parses; missing VmRSS -> null.
    try std.testing.expectEqual(@as(?u64, 45678), parseVmRssKb("VmRSS:\t 45678 kB\n"));
    try std.testing.expectEqual(@as(?u64, null), parseVmRssKb("VmSize:\t 100 kB\n"));
}

test "parseBackendKind maps names, defaults to fix" {
    try std.testing.expectEqual(backend.Kind.nix, parseBackendKind("nix"));
    try std.testing.expectEqual(backend.Kind.fix, parseBackendKind("fix"));
    try std.testing.expectEqual(backend.Kind.fix, parseBackendKind("bogus"));
}

test "collectNixScreens: only *.nix, sorted by name, appended after existing" {
    const gpa = std.testing.allocator;
    // Fresh temp dir with mixed files, out of order.
    var dbuf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dbuf, "/tmp/nbdir-{d}", .{linux.monotonicMsec()});
    switch (linux.mkdir(dir.ptr, 0o755)) {
        .created, .exists, .failed => {},
    }
    var pbuf: [128]u8 = undefined;
    inline for (.{ "20-load.nix", "10-badapple.nix", "readme.txt", "30-clock.nix" }) |fname| {
        const p = try std.fmt.bufPrintZ(&pbuf, "{s}/{s}", .{ dir, fname });
        try linux.writeFile(p.ptr, "scope: { bitmap = [ 0 ]; nextMs = 33; }");
    }

    var out: [max_eval_screens][]const u8 = undefined;
    // Seed one explicit path to prove the dir screens append after it.
    out[0] = "explicit.nix";
    const n = collectNixScreens(gpa, dir, &out, 1);
    defer for (out[1..n]) |p| gpa.free(p);

    try std.testing.expectEqual(@as(usize, 4), n); // explicit + 3 .nix (readme.txt skipped)
    try std.testing.expectEqualStrings("explicit.nix", out[0]);
    try std.testing.expect(std.mem.endsWith(u8, out[1], "/10-badapple.nix"));
    try std.testing.expect(std.mem.endsWith(u8, out[2], "/20-load.nix"));
    try std.testing.expect(std.mem.endsWith(u8, out[3], "/30-clock.nix"));
}
