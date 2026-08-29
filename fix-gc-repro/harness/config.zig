//! The LED ring configuration model and the `leds.conf` key=value format.
//!
//! The declarative base config (from the Nix module) is read first; the runtime
//! file `/var/lib/nix-badge/leds.conf`, written by `leds set` and the bling
//! button handler, is layered on top so a user change wins. Unknown keys are
//! ignored so a stale runtime file can never block a boot.

const std = @import("std");
const ws2812 = @import("ws2812.zig");

const Rgb = ws2812.Rgb;
const Pattern = ws2812.Pattern;
const Encoding = ws2812.Encoding;

pub const max_leds = 1024;
pub const max_colors = 16;

/// A key or value was present but semantically invalid (out of range, bad enum,
/// bad colour). These are user-input faults, recovered by the caller, not asserts.
pub const ConfigError = error{
    CountOutOfRange,
    BadEncoding,
    BadPattern,
    BadColorList,
    SpeedOutOfRange,
    FpsOutOfRange,
    TooManyColors,
    BadColor,
};

pub const Config = struct {
    /// Fixed-capacity device path; the spidev node, not a user preference to
    /// hot-reload. Stored inline to avoid an allocation for a ~14-byte string.
    /// Zero-initialised so only `device_len` bytes are ever read as the path.
    device_buf: [256]u8 = @splat(0),
    device_len: usize = 0,
    count: u32 = 24,
    /// SPI clock in Hz. The WS2812 bit time derives from this, so it is the
    /// timing knob swept to match the fitted LED part.
    speed_hz: u32 = 6_400_000,
    encoding: Encoding = .eight,
    /// Mirrors the DTS `spi-cs-high`; the badge ANDs CS with SDO so CS must be
    /// held high during a transfer for data to reach the chain.
    cs_high: bool = true,
    brightness: u8 = 64,
    fps: u32 = 30,
    pattern: Pattern = .rainbow,
    /// Only the first `ncolors` entries are meaningful; the rest are zeroed.
    colors_buf: [max_colors]Rgb = @splat(.{ .r = 0, .g = 0, .b = 0 }),
    ncolors: u32 = 1,
    /// Optional path to a baked "BLED" LED-animation blob. When set (non-empty)
    /// and it loads, the painter plays it instead of the computed pattern. Empty
    /// = no blob. Reloadable on the same mtime watch as pattern/brightness/fps.
    blob_buf: [256]u8 = @splat(0),
    blob_len: usize = 0,
    /// Optional path to a pure-Nix pattern function (see fixeval.zig). When set
    /// (non-empty) and eval is built in (aarch64), the painter evaluates it per
    /// frame -- highest precedence, over blob and the computed pattern. Empty =
    /// no eval. Reloadable on the same mtime watch.
    eval_buf: [256]u8 = @splat(0),
    eval_len: usize = 0,

    pub fn default() Config {
        var c: Config = .{};
        c.setDevice("/dev/spidev3.0");
        c.colors_buf[0] = .{ .r = 255, .g = 255, .b = 255 };
        c.ncolors = 1;
        return c;
    }

    pub fn device(self: *const Config) []const u8 {
        return self.device_buf[0..self.device_len];
    }

    pub fn setDevice(self: *Config, path: []const u8) void {
        const n = @min(path.len, self.device_buf.len);
        @memcpy(self.device_buf[0..n], path[0..n]);
        self.device_len = n;
    }

    /// The configured blob path, or an empty slice when none is set.
    pub fn blob(self: *const Config) []const u8 {
        return self.blob_buf[0..self.blob_len];
    }

    pub fn setBlob(self: *Config, path: []const u8) void {
        const n = @min(path.len, self.blob_buf.len);
        @memcpy(self.blob_buf[0..n], path[0..n]);
        self.blob_len = n;
    }

    /// The configured eval-pattern path, or an empty slice when none is set.
    pub fn eval(self: *const Config) []const u8 {
        return self.eval_buf[0..self.eval_len];
    }

    pub fn setEval(self: *Config, path: []const u8) void {
        const n = @min(path.len, self.eval_buf.len);
        @memcpy(self.eval_buf[0..n], path[0..n]);
        self.eval_len = n;
    }

    pub fn colors(self: *const Config) []const Rgb {
        return self.colors_buf[0..self.ncolors];
    }
};

/// Accept "#rrggbb" or "rrggbb". Returns null on any malformed input (recovered
/// as BadColor by callers).
pub fn parseColor(text: []const u8) ?Rgb {
    var s = text;
    if (s.len > 0 and s[0] == '#') s = s[1..];
    if (s.len != 6) return null;
    for (s) |ch| {
        if (!std.ascii.isHex(ch)) return null;
    }
    const v = std.fmt.parseInt(u24, s, 16) catch return null;
    return .{
        .r = @truncate(v >> 16),
        .g = @truncate(v >> 8),
        .b = @truncate(v),
    };
}

/// Parse a comma-separated colour list into the config, replacing any existing
/// colours. Empty entries are skipped; the list must yield at least one colour.
pub fn parseColors(list: []const u8, c: *Config) ConfigError!void {
    c.ncolors = 0;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const tok = std.mem.trimStart(u8, raw, " ");
        if (tok.len == 0) continue;
        if (c.ncolors >= max_colors) break;
        c.colors_buf[c.ncolors] = parseColor(tok) orelse return error.BadColorList;
        c.ncolors += 1;
    }
    if (c.ncolors == 0) return error.BadColorList;
}

/// Apply one trimmed key/value pair. Out-of-range values on validated keys are
/// faults; unknown keys are silently ignored (forward/backward compatibility).
pub fn applyKeyValue(c: *Config, key: []const u8, val: []const u8) ConfigError!void {
    if (std.mem.eql(u8, key, "device")) {
        c.setDevice(val);
    } else if (std.mem.eql(u8, key, "count")) {
        const n = std.fmt.parseInt(u32, val, 10) catch return error.CountOutOfRange;
        if (n == 0 or n > max_leds) return error.CountOutOfRange;
        c.count = n;
    } else if (std.mem.eql(u8, key, "speed_hz")) {
        c.speed_hz = std.fmt.parseInt(u32, val, 10) catch return error.SpeedOutOfRange;
    } else if (std.mem.eql(u8, key, "cs_high")) {
        c.cs_high = (std.fmt.parseInt(u32, val, 10) catch 0) != 0;
    } else if (std.mem.eql(u8, key, "bits")) {
        const n = std.fmt.parseInt(u32, val, 10) catch return error.BadEncoding;
        c.encoding = std.enums.fromInt(Encoding, n) orelse return error.BadEncoding;
    } else if (std.mem.eql(u8, key, "brightness")) {
        const n = std.fmt.parseInt(u32, val, 10) catch return error.CountOutOfRange;
        c.brightness = if (n > 255) 255 else @intCast(n);
    } else if (std.mem.eql(u8, key, "fps")) {
        const n = std.fmt.parseInt(u32, val, 10) catch return error.FpsOutOfRange;
        c.fps = std.math.clamp(n, 1, 200);
    } else if (std.mem.eql(u8, key, "pattern")) {
        c.pattern = Pattern.parse(val) orelse return error.BadPattern;
    } else if (std.mem.eql(u8, key, "colors")) {
        try parseColors(val, c);
    } else if (std.mem.eql(u8, key, "blob")) {
        // An empty value clears the blob (falls back to the computed pattern).
        c.setBlob(val);
    } else if (std.mem.eql(u8, key, "eval")) {
        // An empty value clears the eval pattern (falls back to blob/computed).
        c.setEval(val);
    }
    // Unknown keys ignored on purpose.
}

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
    try w.writeAll("# Written by nixbadge-leds set. The service reads this\n");
    try w.writeAll("# after the declarative config, so these values win.\n");
    try w.print("pattern = {s}\n", .{c.pattern.name()});
    try w.print("brightness = {d}\n", .{c.brightness});
    try w.print("count = {d}\n", .{c.count});
    try w.print("fps = {d}\n", .{c.fps});
    try w.print("speed_hz = {d}\n", .{c.speed_hz});
    try w.print("bits = {d}\n", .{@intFromEnum(c.encoding)});
    try w.writeAll("colors = ");
    try writeColorList(w, c);
    try w.writeByte('\n');
    // Always emit the blob line (possibly empty) so `leds set --blob ''` clears a
    // previously-set blob rather than leaving a stale one from the base config.
    try w.print("blob = {s}\n", .{c.blob()});
    // Same for the eval pattern path (always emitted so it can be cleared).
    try w.print("eval = {s}\n", .{c.eval()});
}

/// Write the `#rrggbb,#rrggbb,...` colour list (no trailing newline).
pub fn writeColorList(w: *std.Io.Writer, c: *const Config) std.Io.Writer.Error!void {
    for (c.colors(), 0..) |col, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("#{x:0>2}{x:0>2}{x:0>2}", .{ col.r, col.g, col.b });
    }
}

// -------------------------------------------------------------------- tests ---

test "parseColor accepts both forms and rejects bad input" {
    try std.testing.expectEqual(Rgb{ .r = 0xaa, .g = 0xbb, .b = 0xcc }, parseColor("#aabbcc").?);
    try std.testing.expectEqual(Rgb{ .r = 0x01, .g = 0x02, .b = 0x03 }, parseColor("010203").?);
    try std.testing.expectEqual(@as(?Rgb, null), parseColor("#12345")); // too short
    try std.testing.expectEqual(@as(?Rgb, null), parseColor("gggggg")); // non-hex
}

test "parseBuffer applies known keys and ignores unknown ones" {
    var c = Config.default();
    try parseBuffer(&c,
        \\# a comment
        \\pattern = solid
        \\brightness = 200
        \\future_key = whatever
        \\colors = #ff0000, #00ff00
    );
    try std.testing.expectEqual(Pattern.solid, c.pattern);
    try std.testing.expectEqual(@as(u8, 200), c.brightness);
    try std.testing.expectEqual(@as(u32, 2), c.ncolors);
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0xff, .b = 0 }, c.colors_buf[1]);
}

test "blob key sets and clears the blob path" {
    var c = Config.default();
    try std.testing.expectEqualStrings("", c.blob());
    try parseBuffer(&c, "blob = /run/leds/spin.bled\n");
    try std.testing.expectEqualStrings("/run/leds/spin.bled", c.blob());
    // An empty value clears it (fall back to the computed pattern).
    try parseBuffer(&c, "blob =\n");
    try std.testing.expectEqualStrings("", c.blob());
}

test "eval key sets and clears the pattern path" {
    var c = Config.default();
    try std.testing.expectEqualStrings("", c.eval());
    try parseBuffer(&c, "eval = /run/leds/live.nix\n");
    try std.testing.expectEqualStrings("/run/leds/live.nix", c.eval());
    try parseBuffer(&c, "eval =\n");
    try std.testing.expectEqualStrings("", c.eval());
}

test "applyKeyValue rejects out-of-range count and bad bits" {
    var c = Config.default();
    try std.testing.expectError(error.CountOutOfRange, applyKeyValue(&c, "count", "0"));
    try std.testing.expectError(error.CountOutOfRange, applyKeyValue(&c, "count", "99999"));
    try std.testing.expectError(error.BadEncoding, applyKeyValue(&c, "bits", "5"));
    try std.testing.expectError(error.BadPattern, applyKeyValue(&c, "pattern", "sparkle"));
}

test "fps clamps into 1..200" {
    var c = Config.default();
    try applyKeyValue(&c, "fps", "5000");
    try std.testing.expectEqual(@as(u32, 200), c.fps);
    try applyKeyValue(&c, "fps", "0");
    try std.testing.expectEqual(@as(u32, 1), c.fps);
}

test "writeRuntime round-trips through parseBuffer" {
    var c = Config.default();
    c.pattern = .chase;
    c.brightness = 42;
    c.count = 30;
    c.fps = 24;
    c.speed_hz = 6_250_000;
    c.encoding = .four;
    c.colors_buf[0] = .{ .r = 0x10, .g = 0x20, .b = 0x30 };
    c.ncolors = 1;
    c.setBlob("/run/leds/rainbow.bled");
    c.setEval("/run/leds/live.nix");

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRuntime(&w, &c);

    var back = Config.default();
    try parseBuffer(&back, w.buffered());
    try std.testing.expectEqual(c.pattern, back.pattern);
    try std.testing.expectEqual(c.brightness, back.brightness);
    try std.testing.expectEqual(c.count, back.count);
    try std.testing.expectEqual(c.fps, back.fps);
    try std.testing.expectEqual(c.speed_hz, back.speed_hz);
    try std.testing.expectEqual(c.encoding, back.encoding);
    try std.testing.expectEqual(c.colors_buf[0], back.colors_buf[0]);
    try std.testing.expectEqualStrings(c.blob(), back.blob());
    try std.testing.expectEqualStrings(c.eval(), back.eval());
}
