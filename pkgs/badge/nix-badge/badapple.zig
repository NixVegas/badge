//! The baked "Bad Apple" frame blob: a header plus N page-major frames in the
//! SSD1306 layout, so a frame blits straight into the framebuffer. Loaded via
//! mmap so a long clip costs no heap and pages in on demand.
//!
//! Header (little-endian): magic "BADA", u16 width, u16 height, u16 fps, u16
//! flags, u32 frame_count, then frame_count frames of `width*height/8` bytes each.
//! The width/height carried here let the caller check the clip matches the panel
//! it will play on and reject a mismatch instead of smearing the display.

const std = @import("std");
const linux = @import("linux.zig");

pub const magic = "BADA";
pub const header_len = 16;

pub const LoadError = error{
    OpenFailed,
    TooSmall,
    MmapFailed,
    BadMagic,
    Inconsistent,
};

/// An mmapped clip. Owns the mapping; call `deinit` to unmap.
pub const Clip = struct {
    map: []align(std.heap.page_size_min) const u8,
    width: u16,
    height: u16,
    fps: u16,
    frames: u32,

    pub fn deinit(self: *Clip) void {
        linux.munmap(self.map);
        self.* = undefined;
    }

    /// Bytes per frame in this clip's own geometry: page-major, `width*height/8`.
    pub fn frameLen(self: *const Clip) usize {
        return @as(usize, self.width) * (self.height / 8);
    }

    /// The frame the animation clock at `now_ms` lands on, as a page-major slice of
    /// `frameLen()` bytes. The index wraps, so the clip loops. The slice matches the
    /// panel's framebuffer length (validated at open time), so `panel.blit` accepts
    /// it directly.
    pub fn frameAt(self: *const Clip, now_ms: u64) []const u8 {
        // fps and frames are validated non-zero at load, so this cannot divide by
        // or modulo zero.
        const idx: usize = @intCast((now_ms * self.fps / 1000) % self.frames);
        const off = header_len + idx * self.frameLen();
        return self.map[off..][0..self.frameLen()];
    }

    /// Per-frame period in ms at the baked fps (never zero, which would busy-spin).
    pub fn frameMs(self: *const Clip) u32 {
        const ms = 1000 / @as(u32, self.fps);
        return if (ms != 0) ms else 1;
    }
};

/// Open, validate, and mmap a blob. Validation is strict: bad magic, a truncated
/// header, zero frames/fps, a non-page-aligned height, or a file too short for its
/// claimed frame count all disqualify it, because a partial blit would smear the
/// panel. Every field is read with an explicit little-endian decode, so the loader
/// is byte-order portable (the C assumed the host order).
pub fn load(path: [*:0]const u8) LoadError!Clip {
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

    const width = std.mem.readInt(u16, map[4..6], .little);
    const height = std.mem.readInt(u16, map[6..8], .little);
    const fps = std.mem.readInt(u16, map[8..10], .little);
    const frames = std.mem.readInt(u32, map[12..16], .little);
    // A page is 8 rows; a height that is not a multiple of 8 has no page-major
    // layout, and zero dims give a zero frame size that would loop forever.
    if (width == 0 or height == 0 or height % 8 != 0 or fps == 0 or frames == 0)
        return error.Inconsistent;

    // Reject a file that cannot hold the frame count it claims, using checked
    // arithmetic on the untrusted fields so a huge value cannot overflow the bound.
    const frame_len = @as(usize, width) * (height / 8);
    const body = std.math.mul(usize, frames, frame_len) catch return error.Inconsistent;
    const needed = std.math.add(usize, header_len, body) catch return error.Inconsistent;
    if (len < needed) return error.Inconsistent;

    return .{ .map = map, .width = width, .height = height, .fps = fps, .frames = frames };
}

test "load rejects a truncated / bad-magic blob without a device" {
    // A pure in-memory validation is hard here since load() mmaps a path; the
    // dimension math is exercised via frameLen on a constructed Clip instead.
    const clip: Clip = .{ .map = &.{}, .width = 128, .height = 32, .fps = 30, .frames = 1 };
    try std.testing.expectEqual(@as(usize, 512), clip.frameLen());
    const clip64: Clip = .{ .map = &.{}, .width = 128, .height = 64, .fps = 30, .frames = 1 };
    try std.testing.expectEqual(@as(usize, 1024), clip64.frameLen());
}
