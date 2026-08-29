//! The baked "BLED" LED-animation blob: a header plus N frames of ring-order RGB,
//! so LED patterns can be authored in Nix the way the OLED screens are. Loaded via
//! mmap so a long animation costs no heap and pages in on demand.
//!
//! Header (little-endian): magic "BLED" (4 bytes), u16 nleds, u16 fps, u32
//! frame_count, then frame_count frames of `nleds*3` bytes each (R,G,B per LED, in
//! ring order). The painter plays a frame straight through the SAME ws2812 encoder
//! + spidev write + latch as the computed patterns — only the pixel source differs.

const std = @import("std");
const linux = @import("linux.zig");
const ws2812 = @import("ws2812.zig");

const Rgb = ws2812.Rgb;

// Bytes per LED in the blob: R,G,B, packed with no padding. (Rgb's in-memory
// @sizeOf is 4 due to alignment, so a frame is NOT a []Rgb — the painter decodes
// each LED's three bytes explicitly, which is also byte-order portable.)
pub const bytes_per_led = 3;

pub const magic = "BLED";
pub const header_len = 12;

// A sane ceiling so a corrupt nleds cannot demand an enormous pixel buffer. Matches
// the painter's own MAX_LEDS ceiling (config.max_leds); kept local to avoid a cycle.
const max_nleds = 1024;

pub const LoadError = error{
    OpenFailed,
    TooSmall,
    MmapFailed,
    BadMagic,
    Inconsistent,
};

/// An mmapped LED animation. Owns the mapping; call `deinit` to unmap.
pub const Frames = struct {
    map: []align(std.heap.page_size_min) const u8,
    nleds: u16,
    fps: u16,
    frames: u32,

    pub fn deinit(self: *Frames) void {
        linux.munmap(self.map);
        self.* = undefined;
    }

    /// Bytes per frame: `nleds*3`.
    pub fn frameLen(self: *const Frames) usize {
        return @as(usize, self.nleds) * bytes_per_led;
    }

    /// The frame the animation clock at `now_ms` lands on, as `nleds*3` raw RGB
    /// bytes (ring order). The index wraps, so the animation loops. The caller
    /// decodes each LED with `pixel`.
    pub fn frameAt(self: *const Frames, now_ms: u64) []const u8 {
        // fps and frames are validated non-zero at load, so this cannot divide by
        // or modulo zero.
        const idx: usize = @intCast((now_ms * self.fps / 1000) % self.frames);
        const off = header_len + idx * self.frameLen();
        return self.map[off..][0..self.frameLen()];
    }

    /// LED `i` of a frame returned by `frameAt`, decoded R,G,B.
    pub fn pixel(frame: []const u8, i: usize) Rgb {
        const o = i * bytes_per_led;
        return .{ .r = frame[o], .g = frame[o + 1], .b = frame[o + 2] };
    }
};

/// Open, validate, and mmap a blob. Validation is strict: bad magic, a truncated
/// header, zero nleds/fps/frames, an nleds beyond the painter's ceiling, or a file
/// too short for its claimed frame count all disqualify it, so the painter can
/// fall back to the computed pattern rather than play garbage. Every field is read
/// with an explicit little-endian decode, so the loader is byte-order portable.
pub fn load(path: [*:0]const u8) LoadError!Frames {
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true };
    const fd = linux.open(path, flags, 0) catch return error.OpenFailed;
    const size = linux.fileSize(fd) orelse {
        linux.close(fd);
        return error.TooSmall;
    };
    if (size < header_len) {
        linux.close(fd);
        return error.TooSmall;
    }
    const len: usize = @intCast(size);
    const map = linux.mmapRead(fd, len) catch {
        linux.close(fd);
        return error.MmapFailed;
    };
    linux.close(fd); // the mapping keeps the pages; the fd is no longer needed
    errdefer linux.munmap(map);

    if (!std.mem.eql(u8, map[0..4], magic)) return error.BadMagic;

    const nleds = std.mem.readInt(u16, map[4..6], .little);
    const fps = std.mem.readInt(u16, map[6..8], .little);
    const frames = std.mem.readInt(u32, map[8..12], .little);
    if (nleds == 0 or nleds > max_nleds or fps == 0 or frames == 0)
        return error.Inconsistent;

    // Reject a file that cannot hold the frame count it claims, using checked
    // arithmetic on the untrusted fields so a huge value cannot overflow the bound.
    const frame_len = @as(usize, nleds) * bytes_per_led;
    const body = std.math.mul(usize, frames, frame_len) catch return error.Inconsistent;
    const needed = std.math.add(usize, header_len, body) catch return error.Inconsistent;
    if (len < needed) return error.Inconsistent;

    return .{ .map = map, .nleds = nleds, .fps = fps, .frames = frames };
}

test "frameLen is nleds*3 and pixel decodes R,G,B" {
    const f: Frames = .{ .map = &.{}, .nleds = 24, .fps = 30, .frames = 4 };
    try std.testing.expectEqual(@as(usize, 72), f.frameLen()); // 24 * 3

    const one_frame = [_]u8{ 0x11, 0x22, 0x33, 0xaa, 0xbb, 0xcc };
    const p0 = Frames.pixel(&one_frame, 0);
    const p1 = Frames.pixel(&one_frame, 1);
    try std.testing.expectEqual(Rgb{ .r = 0x11, .g = 0x22, .b = 0x33 }, p0);
    try std.testing.expectEqual(Rgb{ .r = 0xaa, .g = 0xbb, .b = 0xcc }, p1);
}
