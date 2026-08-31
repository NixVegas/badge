//! WS2812 (NeoPixel) framing over an SPI MOSI line.
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

/// Scale a channel by num/255 (num 0..255), the software brightness step
/// (a WS2812 chain has no per-pixel brightness byte).
pub fn scaleChannel(v: u8, num: u32) u8 {
    return @intCast(@as(u32, v) * num / 255);
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

test "scaleChannel scales linearly with saturating endpoints" {
    try std.testing.expectEqual(@as(u8, 0), scaleChannel(200, 0));
    try std.testing.expectEqual(@as(u8, 200), scaleChannel(200, 255));
    try std.testing.expectEqual(@as(u8, 100), scaleChannel(200, 128)); // 200*128/255
}
