//! The baked "Bad Apple" frame blob: a header plus N page-major 512-byte frames
//! in the SSD1306 layout, so a frame blits straight into the framebuffer. Loaded
//! via mmap so a long clip costs no heap and pages in on demand.
//!
//! Header (little-endian): magic "BADA", u16 width, u16 height, u16 fps, u16
//! flags, u32 frame_count, then frame_count * 512 bytes.

const std = @import("std");
const linux = @import("linux.zig");
const oled = @import("oled.zig");

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

    /// The frame the animation clock at `now_ms` lands on, blitted into `panel`.
    /// The index wraps, so the clip loops.
    pub fn frameAt(self: *const Clip, now_ms: u64) *const [oled.fb_len]u8 {
        // fps and frames are validated non-zero at load, so this cannot divide by
        // or modulo zero.
        const idx: usize = @intCast((now_ms * self.fps / 1000) % self.frames);
        const off = header_len + idx * oled.fb_len;
        return self.map[off..][0..oled.fb_len];
    }

    /// Per-frame period in ms at the baked fps (never zero, which would busy-spin).
    pub fn frameMs(self: *const Clip) u32 {
        const ms = 1000 / @as(u32, self.fps);
        return if (ms != 0) ms else 1;
    }
};

/// Open, validate, and mmap a blob. Validation is strict: bad magic, a truncated
/// header, zero frames/fps, or a file too short for its claimed frame count all
/// disqualify it, because a partial blit would smear the panel. Every field is
/// read with an explicit little-endian decode, so the loader is byte-order
/// portable (the C assumed the host order).
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

    const fps = std.mem.readInt(u16, map[8..10], .little);
    const frames = std.mem.readInt(u32, map[12..16], .little);
    // Reject a file that cannot hold the frame count it claims, using checked
    // arithmetic on the untrusted count so a huge value cannot overflow the bound.
    const body = std.math.mul(usize, frames, oled.fb_len) catch return error.Inconsistent;
    const needed = std.math.add(usize, header_len, body) catch return error.Inconsistent;
    if (fps == 0 or frames == 0 or len < needed) return error.Inconsistent;

    return .{
        .map = map,
        .width = std.mem.readInt(u16, map[4..6], .little),
        .height = std.mem.readInt(u16, map[6..8], .little),
        .fps = fps,
        .frames = frames,
    };
}
