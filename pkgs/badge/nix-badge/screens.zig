//! Sensor plumbing for the oled/bling loops: the per-frame `Context` snapshot,
//! the CPU-delta meter, and the /proc readers (load, mem, uptime). The screens
//! themselves are pure-Nix content now (see pkgs/badge/bling-content) -- the
//! old computed Zig screens that painted the panel directly are gone.

const std = @import("std");
const linux = @import("linux.zig");

/// The per-frame snapshot the loop gathers once and hands to the active screen.
pub const Context = struct {
    now_ms: u64,
    on_usb: ?u1,
    /// Which core the boot-select strap currently picks: 0 unknown, 1 arm, 2 riscv.
    strap: u8 = 0,
    battery_mv: ?u32,
    battery_pct: ?u8,
    /// The VSEL system rail in millivolts (~5000 on USB/VBUS); 0 when unreadable.
    vsel_mv: u32 = 0,
    load1: f64,
    cpu_pct: u8,
    mem_pct: u8,
    uptime_s: u64,
    /// Boot-identity strings for the bootinfo screen; constant per boot, cached
    /// once by the gather side (see nix-badge.zig readBootInfo).
    nixos_version: [:0]const u8 = "",
    kernel_version: [:0]const u8 = "",
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
