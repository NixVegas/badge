//! An optional monochrome I2C OLED with RUNTIME dimensions (SSD1306-class).
//!
//! The panel is `height/8` pages of `width` columns; a page is 8 vertically
//! stacked pixels in one byte, LSB on top. So a pixel (x,y) lives in page y/8,
//! column x, at bit y%8 of the framebuffer, and the buffer streams straight to
//! GDDRAM with no reshuffle once horizontal addressing spans the whole panel.
//!
//! The display is OPTIONAL hardware and its size is configurable: `Panel.open`
//! takes width/height and heap-allocates a framebuffer of `width*height/8` bytes
//! from an injected allocator (no hidden alloc, no static framebuffer global).
//! Only 32- and 64-row heights are supported (the two SSD1306 COM-pin layouts).
//!
//! I2C framing: every message starts with a control byte. 0x00 -> the following
//! bytes are commands; 0x40 -> display data. Init/config go out as command
//! frames, the framebuffer flush as one data frame — so we keep the 0x40 control
//! byte as the first byte of the buffer and stream control+data in one write.

const std = @import("std");
const linux = @import("linux.zig");

pub const i2c_bus: [*:0]const u8 = "/dev/i2c-1";
pub const i2c_addr: u16 = 0x3c;

/// Default geometry: the SSD1306 128x32 fitted today.
pub const default_width: u16 = 128;
pub const default_height: u16 = 32;

/// A panel height must be one of the two SSD1306 COM-pin layouts.
pub fn heightSupported(height: u16) bool {
    return height == 32 or height == 64;
}

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

pub const OpenError = error{ UnsupportedHeight, OutOfMemory };

/// A runtime-sized panel: an open i2c fd plus a heap framebuffer it owns. One
/// instance per panel, passed by pointer, so there is no static state. `buf` is
/// `1 + width*pages` bytes: byte 0 is the fixed 0x40 data control byte, `buf[1..]`
/// is the framebuffer that streams to GDDRAM behind it.
pub const Panel = struct {
    alloc: std.mem.Allocator,
    fd: linux.fd_t,
    width: u16,
    height: u16,
    /// 0x40 control byte + framebuffer. Owned; freed in `close`.
    buf: []u8,

    pub fn pages(self: *const Panel) u16 {
        return self.height / 8;
    }

    /// The framebuffer (page-major), a view into `buf` after the control byte.
    pub fn fb(self: *Panel) []u8 {
        return self.buf[1..];
    }

    fn fbLen(width: u16, height: u16) usize {
        return @as(usize, width) * (height / 8);
    }

    /// Open the i2c bus, bind the SSD1306 address, and allocate the framebuffer.
    /// Returns null (with a logged reason) on any failure — the panel is optional
    /// hardware, so a missing bus, a bad height, or OOM all mean "no panel" and
    /// the caller simply runs without it.
    pub fn open(alloc: std.mem.Allocator, width: u16, height: u16) ?Panel {
        if (!heightSupported(height)) {
            std.log.warn("oled: unsupported height {d} (must be 32 or 64)", .{height});
            return null;
        }
        const buf = alloc.alloc(u8, 1 + fbLen(width, height)) catch {
            std.log.warn("oled: cannot allocate a {d}x{d} framebuffer", .{ width, height });
            return null;
        };
        @memset(buf, 0);
        buf[0] = 0x40; // data control byte, fixed for the whole panel lifetime

        const fd = linux.open(i2c_bus, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch {
            std.log.warn("cannot open {s}", .{i2c_bus});
            alloc.free(buf);
            return null;
        };
        _ = linux.ioctl(fd, linux.I2c.SLAVE, i2c_addr) catch {
            std.log.warn("cannot select i2c addr 0x{x:0>2}", .{i2c_addr});
            linux.close(fd);
            alloc.free(buf);
            return null;
        };
        return .{ .alloc = alloc, .fd = fd, .width = width, .height = height, .buf = buf };
    }

    pub fn close(self: *Panel) void {
        linux.close(self.fd);
        self.alloc.free(self.buf);
    }

    /// Send a run of command bytes as one 0x00-control frame. The SSD1306 takes a
    /// whole command list after a single control byte.
    fn sendCommands(self: *Panel, cmds: []const u8) linux.Error!void {
        var out: [64]u8 = undefined;
        std.debug.assert(cmds.len + 1 <= out.len);
        out[0] = 0x00;
        @memcpy(out[1 .. 1 + cmds.len], cmds);
        const n = try linux.write(self.fd, out[0 .. cmds.len + 1]);
        if (n != cmds.len + 1) return error.Io;
    }

    fn sendCommand(self: *Panel, c: u8) linux.Error!void {
        try self.sendCommands(&.{c});
    }

    /// Push the whole framebuffer to GDDRAM: point the column/page windows at the
    /// full panel, then stream `1 + width*pages` bytes behind the 0x40 control
    /// byte already at buf[0].
    pub fn flush(self: *Panel) linux.Error!void {
        try self.sendCommands(&.{
            Cmd.column_addr, 0, @intCast(self.width - 1),
            Cmd.page_addr,   0, @intCast(self.pages() - 1),
        });
        const n = try linux.write(self.fd, self.buf);
        if (n != self.buf.len) return error.Io;
    }

    /// Flush ONE page's column span [c0, c1] (inclusive) to GDDRAM. A page's bytes
    /// `fb[page*width + c0 .. + span]` are contiguous, so this points the column/page
    /// window at just that span and streams it behind one 0x40 control byte -- no
    /// gather. The delta render path calls this once per dirty page, pushing only the
    /// changed columns (a few dozen bytes) instead of the whole ~1 KiB panel, which
    /// is what lets 60 fps Bad Apple fit the 400 kHz bus. In horizontal addressing a
    /// single-page window wraps back to (page, c0) after c1, but we write exactly
    /// `span` bytes so it fills (page, c0..c1) and stops.
    pub fn flushPageSpan(self: *Panel, page: u16, c0: u16, c1: u16) linux.Error!void {
        std.debug.assert(page < self.pages());
        std.debug.assert(c0 <= c1 and c1 < self.width);
        try self.sendCommands(&.{
            Cmd.column_addr, @intCast(c0),   @intCast(c1),
            Cmd.page_addr,   @intCast(page), @intCast(page),
        });
        const span: usize = @as(usize, c1 - c0) + 1;
        // 0x40 data control byte + up to a full 128-column SSD1306 row.
        var tmp: [1 + 128]u8 = undefined;
        std.debug.assert(1 + span <= tmp.len);
        tmp[0] = 0x40;
        const start = @as(usize, page) * self.width + c0;
        @memcpy(tmp[1 .. 1 + span], self.fb()[start .. start + span]);
        const n = try linux.write(self.fd, tmp[0 .. 1 + span]);
        if (n != 1 + span) return error.Io;
    }

    /// The Adafruit power-on sequence, generalised to the runtime height: multiplex
    /// = height-1, COM pins = 0x02 for 32 rows / 0x12 for 64, page window = pages-1,
    /// charge pump on, horizontal addressing, segment remap + reversed COM scan so
    /// (0,0) is top-left. Sent in <=8-byte chunks; some panels dislike a giant burst.
    pub fn init(self: *Panel) linux.Error!void {
        std.debug.assert(heightSupported(self.height));
        const mux: u8 = @intCast(self.height - 1);
        const com_pins: u8 = if (self.height == 32) 0x02 else 0x12;
        const seq = [_]u8{
            Cmd.display_off,
            Cmd.set_display_clock_div,
            0x80,
            Cmd.set_multiplex,
            mux,
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
            com_pins,
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
        @memset(self.fb(), 0);
    }

    /// Blit a full page-major frame into the framebuffer. `frame.len` must equal
    /// this panel's framebuffer length (the caller validates a baked clip's size
    /// against the panel before playing it).
    pub fn blit(self: *Panel, frame: []const u8) void {
        std.debug.assert(frame.len == self.fb().len);
        @memcpy(self.fb(), frame);
    }

    /// Set or clear one pixel. Off-screen coordinates are dropped so callers never
    /// have to clip.
    pub fn setPixel(self: *Panel, x: i32, y: i32, on: bool) void {
        if (x < 0 or x >= self.width or y < 0 or y >= self.height) return;
        const idx: usize = @intCast(@divTrunc(y, 8) * @as(i32, self.width) + x);
        const bit = @as(u8, 1) << @intCast(@mod(y, 8));
        const cells = self.fb();
        if (on) cells[idx] |= bit else cells[idx] &= ~bit;
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
            if (x >= self.width) break;
            self.drawChar(x, y, ch);
            x += glyph_w;
        }
    }

    /// Draw a 2x-scaled string (each source pixel a 2x2 block) for hero numbers.
    pub fn drawText2x(self: *Panel, x_start: i32, y: i32, s: []const u8) void {
        var x = x_start;
        for (s) |ch| {
            if (x >= self.width) break;
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

// A test panel backed by a fixed stack buffer instead of the allocator + i2c fd,
// so the pure framebuffer logic is exercised without a device or heap.
fn testPanel(store: []u8, width: u16, height: u16) Panel {
    @memset(store, 0);
    store[0] = 0x40;
    return .{
        .alloc = std.testing.failing_allocator,
        .fd = -1,
        .width = width,
        .height = height,
        .buf = store,
    };
}

test "setPixel writes the right page-major bit at 128x32" {
    var store: [1 + 128 * 4]u8 = undefined;
    var p = testPanel(&store, 128, 32);
    p.setPixel(0, 0, true); // page 0, col 0, bit 0
    try std.testing.expectEqual(@as(u8, 0x01), p.fb()[0]);
    p.setPixel(5, 9, true); // page 1, col 5, bit 1
    try std.testing.expectEqual(@as(u8, 0x02), p.fb()[128 + 5]);
    p.setPixel(0, 0, false);
    try std.testing.expectEqual(@as(u8, 0x00), p.fb()[0]);
}

test "setPixel indexes by the runtime width, not a fixed 128" {
    var store: [1 + 64 * 8]u8 = undefined;
    var p = testPanel(&store, 64, 64);
    // Row 8 (page 1) column 3 lands at (y/8)*width + x = 1*64 + 3.
    p.setPixel(3, 8, true);
    try std.testing.expectEqual(@as(u8, 0x01), p.fb()[64 + 3]);
    // A 64-row panel accepts y up to 63; the 128x32 bound would have dropped it.
    p.setPixel(0, 63, true);
    try std.testing.expectEqual(@as(u8, 0x80), p.fb()[7 * 64 + 0]);
}

test "off-screen pixels are dropped, not wrapped" {
    var store: [1 + 128 * 4]u8 = undefined;
    var p = testPanel(&store, 128, 32);
    p.setPixel(-1, 0, true);
    p.setPixel(128, 0, true);
    p.setPixel(0, 32, true); // one past the last row of a 32-row panel
    for (p.fb()) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "heightSupported accepts 32 and 64 only" {
    try std.testing.expect(heightSupported(32));
    try std.testing.expect(heightSupported(64));
    try std.testing.expect(!heightSupported(48));
    try std.testing.expect(!heightSupported(16));
}

test "drawHbar frac 0 draws only the border" {
    var store: [1 + 128 * 4]u8 = undefined;
    var p = testPanel(&store, 128, 32);
    p.drawHbar(.{ .x = 0, .y = 0, .w = 10, .h = 6 }, 0.0);
    // Top-left corner is border, interior column 1 row 1 stays clear.
    try std.testing.expect(p.fb()[0] & 0x01 != 0);
    try std.testing.expect(p.fb()[1] & 0x02 == 0);
}
