//! The baked "BLED" LED-animation blob: a header plus N frames of ring-order RGB,
//! so LED patterns can be authored the way the OLED screens are. The file is
//! memory mapped, so a long animation costs no heap and pages in on demand.
//!
//! Header, little-endian: the magic "BLED" (4 bytes), u16 nleds, u16 fps, u32
//! frame_count. After it come frame_count frames of `nleds*3` bytes each, with
//! R, G, B per LED in ring order. The painter plays a frame through the same
//! ws2812 encoder, spidev write, and latch as every other pixel source; only the
//! source of the pixels differs.

const std = @import("std");
const ws2812 = @import("ws2812.zig");

const Rgb = ws2812.Rgb;

/// Bytes per LED in the blob: R, G, B with no padding.
///
/// A frame is NOT a `[]Rgb`. `Rgb` has an in-memory `@sizeOf` of 4 because of
/// alignment, so the painter decodes each LED's three bytes one at a time. That
/// is also what makes the decode byte-order portable.
pub const bytes_per_led = 3;

pub const magic = "BLED";
pub const header_len = 12;

/// A ceiling on nleds, so a corrupt header cannot demand an enormous pixel
/// buffer. It matches the painter's own limit in config.max_leds and is repeated
/// here to avoid an import cycle.
const max_nleds = 1024;

pub const LoadError = error{
    OpenFailed,
    TooSmall,
    MapFailed,
    BadMagic,
    Inconsistent,
};

/// A memory-mapped LED animation. It owns the mapping, so call `deinit`.
pub const Frames = struct {
    map: std.Io.File.MemoryMap,
    nleds: u16,
    fps: u16,
    frames: u32,

    pub fn deinit(self: *Frames, io: std.Io) void {
        self.map.destroy(io);
        self.map.file.close(io);
    }

    /// Bytes per frame: `nleds*3`.
    pub fn frameLen(self: *const Frames) usize {
        return @as(usize, self.nleds) * bytes_per_led;
    }

    /// The frame the animation clock at `now_ms` lands on, as `nleds*3` raw RGB
    /// bytes in ring order. The index wraps, so the animation repeats. The caller
    /// decodes each LED with `pixel`.
    pub fn frameAt(self: *const Frames, now_ms: u64) []const u8 {
        // load validates fps and frames as non-zero, so neither the divide nor
        // the modulo here can divide by zero.
        const idx: usize = @intCast((now_ms * self.fps / 1000) % self.frames);
        const off = header_len + idx * self.frameLen();
        return self.map.memory[off..][0..self.frameLen()];
    }

    /// LED `i` of a frame that `frameAt` returned, decoded to R, G, B.
    pub fn pixel(frame: []const u8, i: usize) Rgb {
        const o = i * bytes_per_led;
        return .{ .r = frame[o], .g = frame[o + 1], .b = frame[o + 2] };
    }
};

/// Open, validate, and map a blob.
///
/// Validation is strict. A bad magic, a truncated header, a zero nleds, fps or
/// frame count, an nleds past the painter's ceiling, and a file too short for the
/// frame count it claims all disqualify the blob, so the painter falls back to
/// another pixel source rather than play garbage. Every field is decoded
/// explicitly as little-endian, which keeps the loader byte-order portable.
pub fn load(io: std.Io, path: []const u8) LoadError!Frames {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.OpenFailed;
    errdefer file.close(io);

    const stat = file.stat(io) catch return error.TooSmall;
    if (stat.size < header_len) return error.TooSmall;
    const len: usize = std.math.cast(usize, stat.size) orelse return error.TooSmall;

    var map = file.createMemoryMap(io, .{
        .len = len,
        .protection = .{ .read = true },
    }) catch return error.MapFailed;
    errdefer map.destroy(io);

    const bytes = map.memory;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;

    const nleds = std.mem.readInt(u16, bytes[4..6], .little);
    const fps = std.mem.readInt(u16, bytes[6..8], .little);
    const frames = std.mem.readInt(u32, bytes[8..12], .little);
    if (nleds == 0 or nleds > max_nleds or fps == 0 or frames == 0)
        return error.Inconsistent;

    // Reject a file that cannot hold the frame count it claims. The fields come
    // from the file, so the bound is computed with checked arithmetic and a huge
    // value cannot overflow past the check.
    const frame_len = @as(usize, nleds) * bytes_per_led;
    const body = std.math.mul(usize, frames, frame_len) catch return error.Inconsistent;
    const needed = std.math.add(usize, header_len, body) catch return error.Inconsistent;
    if (len < needed) return error.Inconsistent;

    return .{ .map = map, .nleds = nleds, .fps = fps, .frames = frames };
}

// -------------------------------------------------------------------- tests ---

// A Frames over an in-memory body, so the frame arithmetic is testable without a
// device or a real mapping.
fn testFrames(body: []u8, nleds: u16, fps: u16, frames: u32) Frames {
    return .{
        .map = .{
            .file = .{ .handle = -1, .flags = .{ .nonblocking = false } },
            .offset = 0,
            .memory = @alignCast(body),
            .section = {},
        },
        .nleds = nleds,
        .fps = fps,
        .frames = frames,
    };
}

test "frameLen is nleds*3 and pixel decodes R,G,B" {
    const one_frame = [_]u8{ 0x11, 0x22, 0x33, 0xaa, 0xbb, 0xcc };
    const p0 = Frames.pixel(&one_frame, 0);
    const p1 = Frames.pixel(&one_frame, 1);
    try std.testing.expectEqual(Rgb{ .r = 0x11, .g = 0x22, .b = 0x33 }, p0);
    try std.testing.expectEqual(Rgb{ .r = 0xaa, .g = 0xbb, .b = 0xcc }, p1);

    var body: [header_len]u8 align(std.heap.page_size_min) = @splat(0);
    const f = testFrames(&body, 24, 30, 4);
    try std.testing.expectEqual(@as(usize, 72), f.frameLen()); // 24 * 3
}

test "frameAt advances with the clock and wraps at the end of the animation" {
    // Two LEDs, 3 frames, 10 fps: one frame per 100 ms. Each frame is tagged with
    // its own index in its first byte so the selection is visible.
    const nleds = 2;
    const frame_len = nleds * bytes_per_led;
    var body: [header_len + 3 * frame_len]u8 align(std.heap.page_size_min) = @splat(0);
    for (0..3) |i| body[header_len + i * frame_len] = @intCast(0xa0 + i);

    const f = testFrames(&body, nleds, 10, 3);
    try std.testing.expectEqual(@as(u8, 0xa0), f.frameAt(0)[0]);
    try std.testing.expectEqual(@as(u8, 0xa1), f.frameAt(100)[0]);
    try std.testing.expectEqual(@as(u8, 0xa2), f.frameAt(250)[0]);
    // 300 ms is one full cycle, so playback returns to frame 0.
    try std.testing.expectEqual(@as(u8, 0xa0), f.frameAt(300)[0]);
    try std.testing.expectEqual(@as(u8, 0xa1), f.frameAt(2500)[0]);
}

test "load rejects a file too short to hold a header" {
    // The host has no blob, and a directory is never a valid one either. Both
    // must come back as a recovered error rather than a crash.
    const missing = load(std.testing.io, "/proc/nix-badge-absent.bled");
    try std.testing.expectError(error.OpenFailed, missing);
}
