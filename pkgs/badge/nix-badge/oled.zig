//! A 128x32 SSD1306 monochrome OLED over Linux i2c-dev at 0x3c.
//!
//! The panel is 4 pages of 128 columns; a page is 8 vertically-stacked pixels in
//! one byte, LSB on top. So a pixel (x,y) lives in page y/8, column x, at bit y%8
//! of `fb[(y/8)*W + x]` and the framebuffer streams straight to GDDRAM with no
//! reshuffle once horizontal addressing spans the whole panel.
//!
//! I2C framing: every message starts with a control byte. 0x00 -> the following
//! bytes are commands; 0x40 -> display data. Init/config go out as command
//! frames, the framebuffer flush as one data frame.

const std = @import("std");
const linux = @import("linux.zig");

pub const width = 128;
pub const height = 32;
pub const pages = height / 8; // 4
pub const fb_len = width * pages; // 512

comptime {
    // The frame blob format and the GDDRAM window both assume exactly this size.
    std.debug.assert(fb_len == 512);
    std.debug.assert(height % 8 == 0);
}

pub const i2c_bus: [*:0]const u8 = "/dev/i2c-1";
pub const i2c_addr: u16 = 0x3c;

// SSD1306 command bytes (datasheet). Only the ones the init/flush use.
const Cmd = struct {
    const set_contrast = 0x81;
    const display_all_on_resume = 0xa4;
    const normal_display = 0xa6;
    const display_off = 0xae;
    const display_on = 0xaf;
    const set_display_offset = 0xd3;
    const set_com_pins = 0xda;
    const set_vcom_detect = 0xdb;
    const set_display_clock_div = 0xd5;
    const set_precharge = 0xd9;
    const set_multiplex = 0xa8;
    const set_start_line = 0x40;
    const memory_mode = 0x20;
    const column_addr = 0x21;
    const page_addr = 0x22;
    const com_scan_dec = 0xc8;
    const seg_remap = 0xa1;
    const charge_pump = 0x8d;
};

const font = @import("oled/font.zig");
pub const glyph_w = font.glyph_w;

/// The panel: an open i2c fd plus the framebuffer it owns. One instance per
/// panel, passed by pointer, so there is no static framebuffer global.
pub const Panel = struct {
    fd: linux.fd_t,
    fb: [fb_len]u8 = @splat(0),

    /// Open the i2c bus and bind the SSD1306 slave address. Returns null (with a
    /// logged reason) when the bus node is absent — a core that does not mux i2c1
    /// has no panel, which is not fatal for the tool.
    pub fn open() ?Panel {
        const fd = linux.open(i2c_bus, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch {
            std.log.warn("cannot open {s}", .{i2c_bus});
            return null;
        };
        _ = linux.ioctl(fd, linux.I2c.SLAVE, i2c_addr) catch {
            std.log.warn("cannot select i2c addr 0x{x:0>2}", .{i2c_addr});
            linux.close(fd);
            return null;
        };
        return .{ .fd = fd };
    }

    pub fn close(self: *Panel) void {
        linux.close(self.fd);
    }

    /// Send a run of command bytes as one 0x00-control frame. The SSD1306 takes a
    /// whole command list after a single control byte.
    fn sendCommands(self: *Panel, cmds: []const u8) linux.Error!void {
        var buf: [64]u8 = undefined;
        std.debug.assert(cmds.len + 1 <= buf.len);
        buf[0] = 0x00;
        @memcpy(buf[1 .. 1 + cmds.len], cmds);
        const n = try linux.write(self.fd, buf[0 .. cmds.len + 1]);
        if (n != cmds.len + 1) return error.Io;
    }

    fn sendCommand(self: *Panel, c: u8) linux.Error!void {
        try self.sendCommands(&.{c});
    }

    /// Push the whole framebuffer to GDDRAM: point the column/page windows at the
    /// full panel, then stream 512 bytes behind one 0x40 data control byte.
    pub fn flush(self: *Panel) linux.Error!void {
        try self.sendCommands(&.{
            Cmd.column_addr, 0, width - 1,
            Cmd.page_addr,   0, pages - 1,
        });
        var buf: [1 + fb_len]u8 = undefined;
        buf[0] = 0x40;
        @memcpy(buf[1..], &self.fb);
        const n = try linux.write(self.fd, &buf);
        if (n != buf.len) return error.Io;
    }

    /// The Adafruit 128x32 power-on sequence: multiplex 0x1f (32 rows), COM pins
    /// 0x02, charge pump on, horizontal addressing, segment remap + reversed COM
    /// scan so (0,0) is top-left. Sent in <=8-byte chunks; some panels dislike a
    /// giant command burst.
    pub fn init(self: *Panel) linux.Error!void {
        // Command bytes interleaved with their data. Notable data: 0x1f = 32 rows
        // (MUX = height-1), 0x14 = charge pump on, 0x00 after memory_mode =
        // horizontal addressing, 0x02 = 128x32 COM pin layout.
        const seq = [_]u8{
            Cmd.display_off,
            Cmd.set_display_clock_div,
            0x80,
            Cmd.set_multiplex,
            0x1f,
            Cmd.set_display_offset,
            0x00,
            Cmd.set_start_line | 0x00,
            Cmd.charge_pump,
            0x14,
            Cmd.memory_mode,
            0x00,
            Cmd.seg_remap,
            Cmd.com_scan_dec,
            Cmd.set_com_pins,
            0x02,
            Cmd.set_contrast,
            0x8f,
            Cmd.set_precharge,
            0xf1,
            Cmd.set_vcom_detect,
            0x40,
            Cmd.display_all_on_resume,
            Cmd.normal_display,
            Cmd.display_on,
        };
        var i: usize = 0;
        while (i < seq.len) : (i += 8) {
            const end = @min(i + 8, seq.len);
            try self.sendCommands(seq[i..end]);
        }
    }

    /// Blank the framebuffer, flush it, and turn the panel off so a stopped
    /// service leaves a dark panel rather than a frozen frame.
    pub fn blankOff(self: *Panel) linux.Error!void {
        self.clear();
        try self.flush();
        try self.sendCommand(Cmd.display_off);
    }

    // ---------------------------------------------------------- framebuffer ---

    pub fn clear(self: *Panel) void {
        @memset(&self.fb, 0);
    }

    /// Blit a full 512-byte frame straight into the framebuffer (baked Bad Apple
    /// frames use the same page-major layout).
    pub fn blit(self: *Panel, frame: *const [fb_len]u8) void {
        @memcpy(&self.fb, frame);
    }

    /// Set or clear one pixel. Off-screen coordinates are dropped so callers never
    /// have to clip.
    pub fn setPixel(self: *Panel, x: i32, y: i32, on: bool) void {
        if (x < 0 or x >= width or y < 0 or y >= height) return;
        const idx: usize = @intCast(@divTrunc(y, 8) * width + x);
        const bit = @as(u8, 1) << @intCast(@mod(y, 8));
        if (on) self.fb[idx] |= bit else self.fb[idx] &= ~bit;
    }

    /// Draw one glyph with its top-left at (x,y). Codepoints outside the font map
    /// to a blank cell, so a stray byte never smears the display.
    pub fn drawChar(self: *Panel, x: i32, y: i32, ch: u8) void {
        const g = font.glyph(ch);
        for (0..font.width) |col| {
            const bits = g[col];
            for (0..font.height) |row| {
                if (bits & (@as(u8, 1) << @intCast(row)) != 0)
                    self.setPixel(x + @as(i32, @intCast(col)), y + @as(i32, @intCast(row)), true);
            }
        }
    }

    /// Draw a string left to right; the 1px inter-char gap is baked into glyph_w.
    /// Drawing stops at the right edge.
    pub fn drawText(self: *Panel, x_start: i32, y: i32, s: []const u8) void {
        var x = x_start;
        for (s) |ch| {
            if (x >= width) break;
            self.drawChar(x, y, ch);
            x += glyph_w;
        }
    }

    /// Draw a 2x-scaled string (each source pixel a 2x2 block) for hero numbers.
    pub fn drawText2x(self: *Panel, x_start: i32, y: i32, s: []const u8) void {
        var x = x_start;
        for (s) |ch| {
            if (x >= width) break;
            const g = font.glyph(ch);
            for (0..font.width) |col| {
                const bits = g[col];
                for (0..font.height) |row| {
                    if (bits & (@as(u8, 1) << @intCast(row)) == 0) continue;
                    const px = x + @as(i32, @intCast(col)) * 2;
                    const py = y + @as(i32, @intCast(row)) * 2;
                    self.setPixel(px, py, true);
                    self.setPixel(px + 1, py, true);
                    self.setPixel(px, py + 1, true);
                    self.setPixel(px + 1, py + 1, true);
                }
            }
            x += 2 * glyph_w;
        }
    }

    /// A hollow rectangle `r` with its leftmost `frac` (0..1) of the interior
    /// filled. Out-of-range fractions saturate. A battery/CPU/mem gauge.
    pub fn drawHbar(self: *Panel, r: Rect, frac_in: f64) void {
        if (r.w < 2 or r.h < 2) return;
        const frac = std.math.clamp(frac_in, 0.0, 1.0);

        for (0..@intCast(r.w)) |i| {
            self.setPixel(r.x + @as(i32, @intCast(i)), r.y, true);
            self.setPixel(r.x + @as(i32, @intCast(i)), r.y + r.h - 1, true);
        }
        for (0..@intCast(r.h)) |j| {
            self.setPixel(r.x, r.y + @as(i32, @intCast(j)), true);
            self.setPixel(r.x + r.w - 1, r.y + @as(i32, @intCast(j)), true);
        }

        const inner: f64 = @floatFromInt(r.w - 2);
        const fill: i32 = @intFromFloat(inner * frac + 0.5);
        var i: i32 = 0;
        while (i < fill) : (i += 1) {
            var j: i32 = 1;
            while (j < r.h - 1) : (j += 1) self.setPixel(r.x + 1 + i, r.y + j, true);
        }
    }
};

/// A rectangle in panel pixel coordinates.
pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

// -------------------------------------------------------------------- tests ---

test "setPixel writes the right page-major bit" {
    var p: Panel = .{ .fd = -1 };
    p.setPixel(0, 0, true); // page 0, col 0, bit 0
    try std.testing.expectEqual(@as(u8, 0x01), p.fb[0]);
    p.setPixel(5, 9, true); // page 1, col 5, bit 1
    try std.testing.expectEqual(@as(u8, 0x02), p.fb[width + 5]);
    p.setPixel(0, 0, false);
    try std.testing.expectEqual(@as(u8, 0x00), p.fb[0]);
}

test "off-screen pixels are dropped, not wrapped" {
    var p: Panel = .{ .fd = -1 };
    p.setPixel(-1, 0, true);
    p.setPixel(width, 0, true);
    p.setPixel(0, height, true);
    for (p.fb) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "drawHbar frac 0 draws only the border" {
    var p: Panel = .{ .fd = -1 };
    p.drawHbar(.{ .x = 0, .y = 0, .w = 10, .h = 6 }, 0.0);
    // Top-left corner is border, interior column 1 row 1 stays clear.
    try std.testing.expect(p.fb[0] & 0x01 != 0);
    try std.testing.expect(p.fb[1] & 0x02 == 0);
}
