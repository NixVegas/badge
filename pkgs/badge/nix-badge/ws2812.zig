//! WS2812 (NeoPixel) framing over an SPI MOSI line, plus the ring animations.
//!
//! WS2812 has no clock line: each LED bit is a pulse whose HIGH fraction encodes
//! the bit value. We synthesise those pulses by sending several SPI bits per LED
//! bit. Three encodings trade duty-cycle margin against bytes-per-bit; see
//! `Encoding`. The badge's XL-1615/XL-2020 parts have a T1H window of 0.9-1.0 us
//! (narrower than a stock WS2812B), so `.eight` at ~6.25 MHz is the default: it
//! gives T0H 160 ns, T1H 960 ns, which reads correctly on real hardware where
//! `.four` (320 ns T0H) lit zeros as ones.

const std = @import("std");

pub const Rgb = packed struct { r: u8, g: u8, b: u8 };

/// SPI bits per LED bit. The name is the bit count; the value carries the
/// datasheet-derived 0/1 pulse patterns, MSB first, so no LED bit straddles a
/// byte boundary.
pub const Encoding = enum(u8) {
    /// 0 -> 0b100, 1 -> 0b110. 33/67 duty. Too little margin on the badge parts
    /// (bits flipped at random within ~1% of nominal clock); kept for parity.
    three = 3,
    /// 0 -> 0b1000, 1 -> 0b1110. 25/75 duty (joosteto/ws2812-spi scheme).
    four = 4,
    /// 0 -> 0b10000000, 1 -> 0b11111100. 12.5/75 duty. Default: halves the zero
    /// pulse so it stays clear of the XL parts' latch threshold.
    eight = 8,

    /// SPI bytes emitted for one 24-bit LED (three colour channels).
    pub fn bytesPerLed(self: Encoding) u32 {
        return switch (self) {
            .three => 9, // 8 LED bits -> 3 SPI bytes, x3 channels
            .four => 12, // 2 LED bits per SPI byte, x3
            .eight => 24, // 1 SPI byte per LED bit, x3
        };
    }

    /// SPI bytes for one 8-bit colour channel.
    pub fn bytesPerChannel(self: Encoding) u32 {
        return self.bytesPerLed() / 3;
    }
};

/// Encode one colour channel into `out`, which must be exactly
/// `enc.bytesPerChannel()` bytes. MSB of the channel goes out first, matching
/// WS2812's bit order.
pub fn encodeChannel(enc: Encoding, value: u8, out: []u8) void {
    switch (enc) {
        .three => {
            std.debug.assert(out.len == 3);
            // Pack 8 LED bits into 24 SPI bits (3 bytes) with no straddle.
            var acc: u32 = 0;
            var i: u8 = 8;
            while (i > 0) {
                i -= 1;
                acc <<= 3;
                acc |= if ((value >> @intCast(i)) & 1 != 0) 0b110 else 0b100;
            }
            out[0] = @truncate(acc >> 16);
            out[1] = @truncate(acc >> 8);
            out[2] = @truncate(acc);
        },
        .four => {
            std.debug.assert(out.len == 4);
            // 0x88 = both bits 0; +0x60 sets the high bit, +0x06 the low bit.
            for (0..4) |i| {
                const hi = (value >> @intCast(7 - 2 * i)) & 1;
                const lo = (value >> @intCast(6 - 2 * i)) & 1;
                const hi_bits: u8 = if (hi != 0) 0x60 else 0;
                const lo_bits: u8 = if (lo != 0) 0x06 else 0;
                out[i] = 0x88 | hi_bits | lo_bits;
            }
        },
        .eight => {
            std.debug.assert(out.len == 8);
            for (0..8) |i| {
                out[i] = if ((value >> @intCast(7 - i)) & 1 != 0) 0xfc else 0x80;
            }
        },
    }
}

/// Encode `pixels` (in the caller's RGB order) into `out` as a WS2812 frame:
/// channels go out G, R, B per pixel, followed by `latch_bytes` of zeros to hold
/// the line low for the reset. `out` must be at least
/// `pixels.len * enc.bytesPerLed() + latch_bytes`.
pub fn encodeFrame(enc: Encoding, pixels: []const Rgb, latch_bytes: usize, out: []u8) void {
    const bpl = enc.bytesPerLed();
    const bpc = enc.bytesPerChannel();
    std.debug.assert(out.len >= pixels.len * bpl + latch_bytes);

    for (pixels, 0..) |px, i| {
        const p = out[i * bpl ..];
        encodeChannel(enc, px.g, p[0 * bpc ..][0..bpc]);
        encodeChannel(enc, px.r, p[1 * bpc ..][0..bpc]);
        encodeChannel(enc, px.b, p[2 * bpc ..][0..bpc]);
    }
    @memset(out[pixels.len * bpl ..][0..latch_bytes], 0);
}

// ------------------------------------------------------------- animations ---

pub const Pattern = enum(u8) {
    off = 0,
    solid,
    pulse,
    rainbow,
    chase,

    /// Parse a pattern name, or null when unknown (a recoverable input fault).
    pub fn parse(text: []const u8) ?Pattern {
        return std.meta.stringToEnum(Pattern, text);
    }

    pub fn name(self: Pattern) []const u8 {
        return @tagName(self);
    }

    /// Whether this pattern changes frame to frame (drives fps vs idle pacing).
    pub fn isAnimated(self: Pattern) bool {
        return switch (self) {
            .off, .solid => false,
            .pulse, .rainbow, .chase => true,
        };
    }
};

/// Integer colour wheel: pos 0..255 -> a hue around the RGB circle. libm-free.
pub fn wheel(pos_in: u8) Rgb {
    var pos: u32 = 255 - @as(u32, pos_in);
    if (pos < 85) return .{ .r = @intCast(255 - pos * 3), .g = 0, .b = @intCast(pos * 3) };
    if (pos < 170) {
        pos -= 85;
        return .{ .r = 0, .g = @intCast(pos * 3), .b = @intCast(255 - pos * 3) };
    }
    pos -= 170;
    return .{ .r = @intCast(pos * 3), .g = @intCast(255 - pos * 3), .b = 0 };
}

/// Scale a channel by num/255 (num 0..255), the software brightness step.
pub fn scaleChannel(v: u8, num: u32) u8 {
    return @intCast(@as(u32, v) * num / 255);
}

/// Triangle wave 0..255..0 over `period` frames. A libm-free pulse envelope.
pub fn triangle(frame: u32, period: u32) u32 {
    if (period == 0) return 255;
    const x = frame % period;
    const half = period / 2;
    if (half == 0) return 255;
    return if (x < half) x * 255 / half else (period - x) * 255 / half;
}

/// Parameters a render needs beyond the frame counter. Bundled so `render` stays
/// a pure function of its inputs.
pub const RenderParams = struct {
    pattern: Pattern,
    brightness: u8,
    fps: u32,
    colors: []const Rgb,
};

/// Paint one animation frame into `out` (one entry per LED). `out.len` is the
/// ring length. `params.colors` must be non-empty. Global brightness is applied
/// last, matching a WS2812 chain that has no per-pixel brightness byte.
pub fn render(params: RenderParams, frame: u32, out: []Rgb) void {
    std.debug.assert(params.colors.len > 0);
    const count: u32 = @intCast(out.len);

    switch (params.pattern) {
        .off => @memset(out, .{ .r = 0, .g = 0, .b = 0 }),
        .solid => for (out, 0..) |*px, i| {
            px.* = params.colors[i % params.colors.len];
        },
        .pulse => {
            const level = triangle(frame, params.fps * 2);
            const base = params.colors[0];
            const v: Rgb = .{
                .r = scaleChannel(base.r, level),
                .g = scaleChannel(base.g, level),
                .b = scaleChannel(base.b, level),
            };
            @memset(out, v);
        },
        .rainbow => for (out, 0..) |*px, i| {
            const idx: u32 = @intCast(i);
            const pos = (idx * 256 / count + frame) & 0xff;
            px.* = wheel(@intCast(pos));
        },
        .chase => {
            @memset(out, .{ .r = 0, .g = 0, .b = 0 });
            const head = frame % count;
            const lap = frame / count;
            out[head] = params.colors[lap % params.colors.len];
        },
    }

    if (params.brightness < 255) {
        for (out) |*px| {
            px.r = scaleChannel(px.r, params.brightness);
            px.g = scaleChannel(px.g, params.brightness);
            px.b = scaleChannel(px.b, params.brightness);
        }
    }
}

// -------------------------------------------------------------------- tests ---

test "encodeChannel eight: zero and full and a mixed byte" {
    var buf: [8]u8 = undefined;
    encodeChannel(.eight, 0x00, &buf);
    try std.testing.expectEqualSlices(u8, &@as([8]u8, @splat(0x80)), &buf);
    encodeChannel(.eight, 0xff, &buf);
    try std.testing.expectEqualSlices(u8, &@as([8]u8, @splat(0xfc)), &buf);
    encodeChannel(.eight, 0x3c, &buf);
    const mixed = [8]u8{ 0x80, 0x80, 0xfc, 0xfc, 0xfc, 0xfc, 0x80, 0x80 };
    try std.testing.expectEqualSlices(u8, &mixed, &buf);
}

test "encodeChannel four: 0x3c matches the joosteto scheme" {
    var buf: [4]u8 = undefined;
    encodeChannel(.four, 0x3c, buf[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x88, 0xee, 0xee, 0x88 }, &buf);
}

test "encodeChannel three: 0xff packs to db 6d b6" {
    var buf: [3]u8 = undefined;
    encodeChannel(.three, 0xff, buf[0..3]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xdb, 0x6d, 0xb6 }, &buf);
}

test "encodeFrame writes GRB order then a zero latch" {
    const px = [_]Rgb{.{ .r = 0x11, .g = 0x22, .b = 0x33 }};
    var out: [8 * 3 + 4]u8 = undefined;
    encodeFrame(.eight, &px, 4, &out);
    // G channel first: 0x22 -> pattern for bit 5,1 set.
    var g: [8]u8 = undefined;
    encodeChannel(.eight, 0x22, &g);
    try std.testing.expectEqualSlices(u8, &g, out[0..8]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, out[24..28]);
}

test "wheel endpoints" {
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, wheel(0));
}

test "triangle peaks at the half period and is zero at the ends" {
    try std.testing.expectEqual(@as(u32, 0), triangle(0, 60));
    try std.testing.expectEqual(@as(u32, 255), triangle(30, 60));
    try std.testing.expectEqual(@as(u32, 255), triangle(1, 0)); // zero period guard
}

test "Pattern.parse rejects garbage and accepts names" {
    try std.testing.expectEqual(Pattern.rainbow, Pattern.parse("rainbow").?);
    try std.testing.expectEqual(@as(?Pattern, null), Pattern.parse("nope"));
}

test "render chase lights exactly one LED" {
    const colors = [_]Rgb{.{ .r = 10, .g = 20, .b = 30 }};
    var out: [4]Rgb = undefined;
    render(.{ .pattern = .chase, .brightness = 255, .fps = 30, .colors = &colors }, 1, &out);
    var lit: u32 = 0;
    for (out) |px| {
        if (px.r != 0 or px.g != 0 or px.b != 0) lit += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), lit);
    try std.testing.expectEqual(colors[0], out[1]);
}
