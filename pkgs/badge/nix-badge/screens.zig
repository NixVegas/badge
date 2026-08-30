//! The oled screen model: a screen is a pure function of a per-frame snapshot
//! (`Context`) that paints the OLED framebuffer and returns how many ms until it
//! wants to run again (its own frame-rate hint). That lets a static meter idle at
//! 2 Hz while Bad Apple runs at its baked fps under one loop.

const std = @import("std");
const linux = @import("linux.zig");
const oled = @import("oled.zig");
const sysfs = @import("sysfs.zig");

const Panel = oled.Panel;
const glyph_w = oled.glyph_w;

/// The per-frame snapshot the loop gathers once and hands to the active screen.
pub const Context = struct {
    now_ms: u64,
    on_usb: ?u1,
    /// Which core the boot-select strap currently picks: 0 unknown, 1 arm, 2 riscv.
    strap: u8 = 0,
    battery_mv: ?u32,
    battery_pct: ?u8,
    load1: f64,
    cpu_pct: u8,
    mem_pct: u8,
    uptime_s: u64,
};

/// A CPU-utilisation tracker: utilisation is a delta between two /proc/stat
/// samples, so the previous sample is carried across frames.
pub const CpuMeter = struct {
    busy: u64 = 0,
    idle: u64 = 0,

    pub fn init() CpuMeter {
        var m: CpuMeter = .{};
        readCpuJiffies(&m.busy, &m.idle);
        return m;
    }

    /// Sample again and return utilisation 0..100 since the last call.
    pub fn sample(self: *CpuMeter) u8 {
        var busy: u64 = 0;
        var idle: u64 = 0;
        readCpuJiffies(&busy, &idle);
        const dbusy = busy -% self.busy;
        const dtotal = dbusy +% (idle -% self.idle);
        self.busy = busy;
        self.idle = idle;
        if (dtotal == 0) return 0;
        return @intCast(dbusy * 100 / dtotal);
    }
};

// ------------------------------------------------------------- /proc readers ---

fn readCpuJiffies(busy: *u64, idle: *u64) void {
    busy.* = 0;
    idle.* = 0;
    var buf: [4096]u8 = undefined;
    const s = linux.readFile("/proc/stat", &buf) orelse return;
    const first_nl = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
    var it = std.mem.tokenizeAny(u8, s[0..first_nl], " \t");
    const label = it.next() orelse return;
    if (!std.mem.eql(u8, label, "cpu")) return; // aggregate line must lead
    // user nice system idle iowait irq softirq steal
    var v: [8]u64 = @splat(0);
    var got: usize = 0;
    while (got < 8) : (got += 1) {
        const tok = it.next() orelse break;
        v[got] = std.fmt.parseInt(u64, tok, 10) catch break;
    }
    if (got < 5) return; // need at least user..iowait
    busy.* = v[0] + v[1] + v[2] + v[5] + v[6] + v[7];
    idle.* = v[3] + v[4];
}

/// 1- and 5-minute load averages from /proc/loadavg; 0 on a read fault.
pub fn readLoad1And5(l1: *f64, l5: *f64) void {
    l1.* = 0;
    l5.* = 0;
    var buf: [128]u8 = undefined;
    const s = linux.readFile("/proc/loadavg", &buf) orelse return;
    var it = std.mem.tokenizeAny(u8, s, " \t\n");
    const a = it.next() orelse return;
    const b = it.next() orelse return;
    l1.* = std.fmt.parseFloat(f64, a) catch 0;
    l5.* = std.fmt.parseFloat(f64, b) catch 0;
}

/// Used memory fraction (0..1) from /proc/meminfo: (MemTotal - MemAvailable) /
/// MemTotal. MemAvailable already accounts for reclaimable cache.
pub fn readMemUsedFrac() f64 {
    var buf: [8192]u8 = undefined;
    const s = linux.readFile("/proc/meminfo", &buf) orelse return 0.0;
    var total: u64 = 0;
    var avail: u64 = 0;
    var lines = std.mem.splitScalar(u8, s, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const key = it.next() orelse continue;
        const val_tok = it.next() orelse continue;
        const val = std.fmt.parseInt(u64, val_tok, 10) catch continue;
        if (std.mem.eql(u8, key, "MemTotal:")) total = val;
        if (std.mem.eql(u8, key, "MemAvailable:")) avail = val;
        if (total != 0 and avail != 0) break;
    }
    if (total == 0) return 0.0;
    if (avail > total) avail = total;
    return @as(f64, @floatFromInt(total - avail)) / @as(f64, @floatFromInt(total));
}

pub fn readUptimeS() u64 {
    var buf: [64]u8 = undefined;
    const s = linux.readFile("/proc/uptime", &buf) orelse return 0;
    var it = std.mem.tokenizeAny(u8, s, " \t\n");
    const first = it.next() orelse return 0;
    const up = std.fmt.parseFloat(f64, first) catch return 0;
    return @intFromFloat(up);
}

// ------------------------------------------------------------------- screens ---
//
// Each render paints the whole framebuffer and returns its own ms-until-next.

/// The battery view: VBAT big (from the power_supply node), a 3.0..4.2 V bar with
/// the kernel percent, and a USB tag.
pub fn battery(panel: *Panel, ctx: *const Context) u32 {
    const w: i32 = panel.width;
    const h: i32 = panel.height;
    panel.clear();
    panel.drawText(0, 0, "BATT");
    if (ctx.on_usb == 1) panel.drawText(w - 3 * glyph_w, 0, "USB");

    var big_buf: [16]u8 = undefined;
    if (ctx.battery_mv) |mv| {
        const v = @as(f64, @floatFromInt(mv)) / 1000.0;
        const big = std.fmt.bufPrint(&big_buf, "{d:.2}V", .{v}) catch "--.--";
        panel.drawText2x(0, 9, big);
    } else {
        panel.drawText2x(0, 9, "--.--");
    }

    // Prefer the kernel capacity for the bar/percent; fall back to a rough linear
    // Li-ion map (3.0 V empty..4.2 V full) only when capacity is unknown.
    var frac: f64 = 0;
    var pct: u8 = 0;
    if (ctx.battery_pct) |p| {
        pct = p;
        frac = @as(f64, @floatFromInt(p)) / 100.0;
    } else if (ctx.battery_mv) |mv| {
        const v = @as(f64, @floatFromInt(mv)) / 1000.0;
        frac = std.math.clamp((v - 3.0) / (4.2 - 3.0), 0.0, 1.0);
        pct = @intFromFloat(frac * 100.0 + 0.5);
    }

    panel.drawHbar(.{ .x = 0, .y = h - 7, .w = w - 24, .h = 7 }, frac);
    var pct_buf: [8]u8 = undefined;
    const pct_s = std.fmt.bufPrint(&pct_buf, "{d: >3}%", .{pct}) catch "  0%";
    panel.drawText(w - 22, h - 7, pct_s);
    return 500; // a slow meter; 2 Hz is plenty and light on I2C
}

/// The load view: 1/5-min loadavg, a CPU% bar, and a mem% bar.
pub fn load(panel: *Panel, ctx: *const Context) u32 {
    const w: i32 = panel.width;
    panel.clear();

    var l1: f64 = 0;
    var l5: f64 = 0;
    readLoad1And5(&l1, &l5);
    var line_buf: [24]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "LD {d:.2} {d:.2}", .{ l1, l5 }) catch "LD";
    panel.drawText(0, 0, line);

    var ut_buf: [24]u8 = undefined;
    const hours = @min(ctx.uptime_s / 3600, 999);
    const mins = (ctx.uptime_s % 3600) / 60;
    const ut = if (ctx.uptime_s >= 3600)
        std.fmt.bufPrint(&ut_buf, "{d}h", .{hours}) catch "0h"
    else
        std.fmt.bufPrint(&ut_buf, "{d}m", .{mins}) catch "0m";
    const utx = w - @as(i32, @intCast(ut.len)) * glyph_w;
    panel.drawText(@max(utx, 0), 0, ut);

    const cpu_frac = @as(f64, @floatFromInt(ctx.cpu_pct)) / 100.0;
    const mem_frac = @as(f64, @floatFromInt(ctx.mem_pct)) / 100.0;

    // The two gauges share geometry: left of the label, right of the "NNN%" tag.
    const bar_x = 4 * glyph_w;
    const bar_w = w - 4 * glyph_w - 26;

    panel.drawText(0, 11, "CPU");
    panel.drawHbar(.{ .x = bar_x, .y = 10, .w = bar_w, .h = 8 }, cpu_frac);
    var cp_buf: [8]u8 = undefined;
    const cp = std.fmt.bufPrint(&cp_buf, "{d: >3}%", .{ctx.cpu_pct}) catch "  0%";
    panel.drawText(w - 22, 11, cp);

    panel.drawText(0, 22, "MEM");
    panel.drawHbar(.{ .x = bar_x, .y = 21, .w = bar_w, .h = 8 }, mem_frac);
    var mp_buf: [8]u8 = undefined;
    const mp = std.fmt.bufPrint(&mp_buf, "{d: >3}%", .{ctx.mem_pct}) catch "  0%";
    panel.drawText(w - 22, 22, mp);
    return 500;
}

/// The power view: VSEL and VBUS presence, plus any asserted fault by short name.
pub fn power(panel: *Panel, ctx: *const Context) u32 {
    _ = ctx; // the view re-reads the rails/faults itself, matching `power`
    panel.clear();

    const vsel = sysfs.readVselVolts();

    var line_buf: [24]u8 = undefined;
    const line = if (vsel) |v|
        std.fmt.bufPrint(&line_buf, "VSEL {d:.2}V", .{v}) catch "VSEL"
    else
        "VSEL --.--";
    panel.drawText(0, 0, line);

    const vbus = sysfs.readLine("usb-vbus-det");
    var vbus_buf: [24]u8 = undefined;
    const vbus_text = if (vbus) |v| (if (v != 0) "yes" else "no") else "unk";
    const vbus_line = std.fmt.bufPrint(&vbus_buf, "VBUS {s}", .{vbus_text}) catch "VBUS";
    panel.drawText(0, 8, vbus_line);

    const faults = [_]struct { name: []const u8, line: []const u8 }{
        .{ .name = "USB", .line = "usb-5v-fault-n" },
        .{ .name = "HDMI", .line = "hdmi-5v-fault-n" },
        .{ .name = "SD", .line = "sd-fault-n" },
        .{ .name = "SAO", .line = "sao-fault-n" },
    };
    // The four short names plus separators fit in 24 bytes, so these writes
    // cannot overflow; a write error would mean the buffer was mis-sized (a
    // programmer error), so stop appending on the first failure.
    var flt_buf: [24]u8 = undefined;
    var w: std.Io.Writer = .fixed(&flt_buf);
    var any = false;
    for (faults) |f| {
        if (sysfs.readLine(f.line) == 0) { // active low: 0 = asserted
            if (any) w.writeByte(' ') catch break;
            w.writeAll(f.name) catch break;
            any = true;
        }
    }
    panel.drawText(0, 16, "FLT:");
    panel.drawText(4 * glyph_w, 16, if (any) w.buffered() else "OK");
    return 750; // rails move slowly; keep the ADC quiet
}

/// The uptime clock: Dd HH:MM:SS drawn big, colons blinking at 1 Hz off the
/// animation clock so the panel visibly ticks.
pub fn clock(panel: *Panel, ctx: *const Context) u32 {
    panel.clear();
    panel.drawText(0, 0, "UPTIME");

    const s = ctx.uptime_s;
    const days = @min(s / 86400, 999);
    const hh = (s % 86400) / 3600;
    const mm = (s % 3600) / 60;
    const ss = s % 60;

    const sep: u8 = if (ctx.now_ms % 1000 < 500) ':' else ' '; // 1 Hz square wave

    var big_buf: [24]u8 = undefined;
    const big = if (days > 0)
        std.fmt.bufPrint(&big_buf, "{d}d{d:0>2}{c}{d:0>2}", .{ days, hh, sep, mm }) catch "0d"
    else
        std.fmt.bufPrint(&big_buf, "{d:0>2}{c}{d:0>2}{c}{d:0>2}", .{ hh, sep, mm, sep, ss }) catch
            "00";
    panel.drawText2x(0, 12, big);

    const secs_frac = @as(f64, @floatFromInt(s % 60)) / 60.0;
    const w: i32 = panel.width;
    const h: i32 = panel.height;
    panel.drawHbar(.{ .x = 0, .y = h - 5, .w = w, .h = 5 }, secs_frac);
    return 250; // four blink samples a second
}
