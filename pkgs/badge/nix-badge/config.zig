//! The LED ring configuration model and the `leds.conf` key=value format.
//!
//! The declarative base config (from the Nix module) is read first; the runtime
//! file `/etc/nixbadge/leds.conf`, written by `bling set` and the oled
//! button handler, is layered on top so a user change wins. Unknown keys are
//! ignored so a stale runtime file can never block a boot -- which is also how
//! the retired `pattern =` / `colors =` keys (the old Zig-computed patterns)
//! age out: old files still parse, those keys just no longer do anything. The
//! pixel sources are the pure-Nix `eval` pattern and the baked `blob`.

const std = @import("std");
const ws2812 = @import("ws2812.zig");

const Encoding = ws2812.Encoding;

pub const max_leds = 1024;

/// A key or value was present but not valid: out of range, or an unknown enum.
/// These are user-input faults the caller recovers from, not programmer errors.
pub const ConfigError = error{
    CountOutOfRange,
    BrightnessOutOfRange,
    BadEncoding,
    SpeedOutOfRange,
    FpsOutOfRange,
};

/// A filesystem path stored inline, so a config carries no allocation and no
/// pointer into a buffer the caller owns. A path longer than the capacity is
/// truncated, which then fails to open and is reported at the open site.
pub const Path = struct {
    /// Long enough for a /nix/store path plus a content filename.
    pub const capacity = 256;

    buf: [capacity]u8 = @splat(0),
    len: usize = 0,

    pub fn slice(self: *const Path) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *Path, path: []const u8) void {
        const n = @min(path.len, capacity);
        @memcpy(self.buf[0..n], path[0..n]);
        self.len = n;
    }

    pub fn isEmpty(self: *const Path) bool {
        return self.len == 0;
    }
};

pub const Config = struct {
    /// The spidev node. This is hardware identity rather than a preference, so it
    /// is not reloaded once the service is running.
    device: Path = .{},
    count: u32 = 24,
    /// SPI clock in Hz. The WS2812 bit time derives from this, so it is the
    /// timing knob that is swept to match the fitted LED part.
    speed_hz: u32 = 6_400_000,
    encoding: Encoding = .eight,
    /// Mirrors the DTS `spi-cs-high`. The badge combines CS with SDO, so CS must
    /// stay high through a transfer for data to reach the chain.
    cs_high: bool = true,
    brightness: u8 = 64,
    fps: u32 = 30,
    /// An optional baked "BLED" LED-animation blob. When it is set and it loads,
    /// the painter plays it instead of the emergency fill. Empty means no blob.
    /// It reloads on the same mtime watch as brightness and fps.
    blob: Path = .{},
    /// An optional pure-Nix pattern function (see fixeval.zig). When it is set
    /// and the evaluator is built in, the painter evaluates it every frame. This
    /// is the highest-precedence pixel source, above the blob. Empty means no
    /// pattern. It reloads on the same mtime watch.
    eval: Path = .{},

    pub fn default() Config {
        var c: Config = .{};
        c.device.set("/dev/spidev3.0");
        return c;
    }
};

/// Apply one trimmed key/value pair. Out-of-range values on validated keys are
/// faults; unknown keys are silently ignored (forward/backward compatibility).
pub fn applyKeyValue(c: *Config, key: []const u8, val: []const u8) ConfigError!void {
    if (std.mem.eql(u8, key, "device")) {
        c.device.set(val);
    } else if (std.mem.eql(u8, key, "count")) {
        const n = std.fmt.parseInt(u32, val, 10) catch return error.CountOutOfRange;
        if (n == 0 or n > max_leds) return error.CountOutOfRange;
        c.count = n;
    } else if (std.mem.eql(u8, key, "speed_hz")) {
        const n = std.fmt.parseInt(u32, val, 10) catch return error.SpeedOutOfRange;
        if (n < min_speed_hz or n > max_speed_hz) return error.SpeedOutOfRange;
        c.speed_hz = n;
    } else if (std.mem.eql(u8, key, "cs_high")) {
        c.cs_high = (std.fmt.parseInt(u32, val, 10) catch 0) != 0;
    } else if (std.mem.eql(u8, key, "bits")) {
        const n = std.fmt.parseInt(u32, val, 10) catch return error.BadEncoding;
        c.encoding = std.enums.fromInt(Encoding, n) orelse return error.BadEncoding;
    } else if (std.mem.eql(u8, key, "brightness")) {
        c.brightness = std.fmt.parseInt(u8, val, 10) catch return error.BrightnessOutOfRange;
    } else if (std.mem.eql(u8, key, "fps")) {
        const n = std.fmt.parseInt(u32, val, 10) catch return error.FpsOutOfRange;
        c.fps = std.math.clamp(n, min_fps, max_fps);
    } else if (std.mem.eql(u8, key, "blob")) {
        // An empty value clears the blob and falls back to the eval pattern.
        c.blob.set(val);
    } else if (std.mem.eql(u8, key, "eval")) {
        // An empty value clears the pattern and falls back to the blob or fill.
        c.eval.set(val);
    }
    // Unknown keys are ignored on purpose. That includes the retired `pattern`
    // and `colors` keys, so a runtime file written by an older build still parses.
}

/// The SPI clock range the WS2812 framing is valid over. Below the minimum the
/// pulse widths grow past the part's bit window, and above the maximum the
/// controller cannot hold a continuous stream.
pub const min_speed_hz: u32 = 100_000;
pub const max_speed_hz: u32 = 20_000_000;

/// The frame-rate range the painter accepts. Zero would divide by zero when the
/// frame period is computed, and the upper bound keeps one frame off the bus.
pub const min_fps: u32 = 1;
pub const max_fps: u32 = 200;

/// Parse a whole config buffer ("key = value" lines; blank and #-lines skipped),
/// mutating `c` in place. A malformed line's key/value validation error is
/// returned; a line with no '=' is skipped like the C original.
pub fn parseBuffer(c: *Config, text: []const u8) ConfigError!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimStart(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#' or line[0] == '\r') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        try applyKeyValue(c, key, val);
    }
}

/// Serialize the CLI-visible fields to `w` in the runtime-file format. The
/// header comment marks the file as machine-written; the service reads it after
/// the declarative config, so these values win.
pub fn writeRuntime(w: *std.Io.Writer, c: *const Config) std.Io.Writer.Error!void {
    try w.writeAll("# Written by nixbadge-bling set. The service reads this\n");
    try w.writeAll("# after the declarative config, so these values win.\n");
    try w.print("brightness = {d}\n", .{c.brightness});
    try w.print("count = {d}\n", .{c.count});
    try w.print("fps = {d}\n", .{c.fps});
    try w.print("speed_hz = {d}\n", .{c.speed_hz});
    try w.print("bits = {d}\n", .{@intFromEnum(c.encoding)});
    // The blob line is always written, even when empty, so `bling set --blob ''`
    // clears a blob instead of leaving the stale one from the base config.
    try w.print("blob = {s}\n", .{c.blob.slice()});
    // The eval pattern path is written for the same reason.
    try w.print("eval = {s}\n", .{c.eval.slice()});
}

// -------------------------------------------------------------------- tests ---

test "parseBuffer applies known keys and ignores unknown ones" {
    var c = Config.default();
    // `pattern` and `colors` are retired keys, because the Zig-computed patterns
    // are gone. They must parse as unknown keys, so a runtime file written by an
    // older build still loads.
    try parseBuffer(&c,
        \\# a comment
        \\brightness = 200
        \\future_key = whatever
        \\pattern = solid
        \\colors = #ff0000, #00ff00
    );
    try std.testing.expectEqual(@as(u8, 200), c.brightness);
}

test "blob key sets and clears the blob path" {
    var c = Config.default();
    try std.testing.expectEqualStrings("", c.blob.slice());
    try parseBuffer(&c, "blob = /run/leds/spin.bled\n");
    try std.testing.expectEqualStrings("/run/leds/spin.bled", c.blob.slice());
    // An empty value clears it, so the painter falls back to the next source.
    try parseBuffer(&c, "blob =\n");
    try std.testing.expectEqualStrings("", c.blob.slice());
}

test "eval key sets and clears the pattern path" {
    var c = Config.default();
    try std.testing.expectEqualStrings("", c.eval.slice());
    try parseBuffer(&c, "eval = /run/leds/live.nix\n");
    try std.testing.expectEqualStrings("/run/leds/live.nix", c.eval.slice());
    try parseBuffer(&c, "eval =\n");
    try std.testing.expectEqualStrings("", c.eval.slice());
}

test "applyKeyValue rejects a value outside each validated key's range" {
    var c = Config.default();
    try std.testing.expectError(error.CountOutOfRange, applyKeyValue(&c, "count", "0"));
    try std.testing.expectError(error.CountOutOfRange, applyKeyValue(&c, "count", "99999"));
    try std.testing.expectError(error.BadEncoding, applyKeyValue(&c, "bits", "5"));
    try std.testing.expectError(error.BrightnessOutOfRange, applyKeyValue(&c, "brightness", "256"));
    // The speed bounds are the range the WS2812 framing stays valid over. A value
    // outside them used to be accepted and produced unusable bit timing.
    try std.testing.expectError(error.SpeedOutOfRange, applyKeyValue(&c, "speed_hz", "1000"));
    try std.testing.expectError(error.SpeedOutOfRange, applyKeyValue(&c, "speed_hz", "99000000"));
    // A rejected value must leave the previous one in place.
    try std.testing.expectEqual(@as(u32, 6_400_000), c.speed_hz);
}

test "applyKeyValue accepts the endpoints of each validated range" {
    var c = Config.default();
    try applyKeyValue(&c, "count", "1");
    try std.testing.expectEqual(@as(u32, 1), c.count);
    try applyKeyValue(&c, "brightness", "255");
    try std.testing.expectEqual(@as(u8, 255), c.brightness);
    try applyKeyValue(&c, "speed_hz", "100000");
    try std.testing.expectEqual(min_speed_hz, c.speed_hz);
}

test "fps clamps into the accepted range instead of failing" {
    var c = Config.default();
    try applyKeyValue(&c, "fps", "5000");
    try std.testing.expectEqual(max_fps, c.fps);
    try applyKeyValue(&c, "fps", "0");
    try std.testing.expectEqual(min_fps, c.fps);
    try applyKeyValue(&c, "fps", "60");
    try std.testing.expectEqual(@as(u32, 60), c.fps);
}

test "Path truncates a path past its capacity instead of overflowing" {
    var p: Path = .{};
    try std.testing.expect(p.isEmpty());
    const long: [Path.capacity + 32]u8 = @splat('x');
    p.set(&long);
    try std.testing.expectEqual(Path.capacity, p.slice().len);
    p.set("");
    try std.testing.expect(p.isEmpty());
}

test "writeRuntime round-trips through parseBuffer" {
    var c = Config.default();
    c.brightness = 42;
    c.count = 30;
    c.fps = 24;
    c.speed_hz = 6_250_000;
    c.encoding = .four;
    c.blob.set("/run/leds/rainbow.bled");
    c.eval.set("/run/leds/live.nix");

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRuntime(&w, &c);

    var back = Config.default();
    try parseBuffer(&back, w.buffered());
    try std.testing.expectEqual(c.brightness, back.brightness);
    try std.testing.expectEqual(c.count, back.count);
    try std.testing.expectEqual(c.fps, back.fps);
    try std.testing.expectEqual(c.speed_hz, back.speed_hz);
    try std.testing.expectEqual(c.encoding, back.encoding);
    try std.testing.expectEqualStrings(c.blob.slice(), back.blob.slice());
    try std.testing.expectEqualStrings(c.eval.slice(), back.eval.slice());
}
