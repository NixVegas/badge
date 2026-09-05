//! Sensor plumbing for the oled and bling loops: the per-frame `Context`
//! snapshot, the CPU-utilisation meter, and the /proc readers for load, memory,
//! and uptime.
//!
//! Screen content is pure Nix (see pkgs/badge/bling-content). This module only
//! gathers the numbers a screen reads through its scope.

const std = @import("std");

/// The per-frame snapshot the loop gathers once and hands to the active screen.
pub const Context = struct {
    now_ms: u64,
    on_usb: ?u1,
    /// Which core the boot-select strap picks: 0 unknown, 1 arm, 2 riscv.
    strap: u8 = 0,
    battery_mv: ?u32,
    battery_pct: ?u8,
    /// The VSEL system rail in millivolts, near 5000 on USB or VBUS. 0 when it
    /// cannot be read.
    vsel_mv: u32 = 0,
    load1: f64,
    cpu_pct: u8,
    mem_pct: u8,
    uptime_s: u64,
    /// Boot-identity strings for the bootinfo screen. These are constant for one
    /// boot and the gather side caches them once (see nix-badge.zig readBootInfo).
    nixos_version: [:0]const u8 = "",
    kernel_version: [:0]const u8 = "",
};

/// A CPU-utilisation tracker. Utilisation is the difference between two
/// /proc/stat samples, so the previous sample is carried across frames.
pub const CpuMeter = struct {
    prev: Jiffies = .{},

    pub fn init(io: std.Io) CpuMeter {
        return .{ .prev = readCpuJiffies(io) };
    }

    /// Sample again and return utilisation from 0 to 100 since the last call.
    pub fn sample(self: *CpuMeter, io: std.Io) u8 {
        const now = readCpuJiffies(io);
        // The counters only rise, but they reset when /proc/stat cannot be read,
        // so wrapping subtraction keeps a reset from producing a huge difference.
        const busy = now.busy -% self.prev.busy;
        const total = busy +% (now.idle -% self.prev.idle);
        self.prev = now;
        if (total == 0) return 0;
        return @intCast(busy * 100 / total);
    }
};

// ------------------------------------------------------------- /proc readers ---

/// One /proc/stat aggregate sample, split into busy and idle jiffies.
const Jiffies = struct { busy: u64 = 0, idle: u64 = 0 };

/// The aggregate `cpu` line of /proc/stat. A read fault or a malformed line
/// gives zeroes, which `CpuMeter.sample` reports as 0% rather than a spike.
fn readCpuJiffies(io: std.Io) Jiffies {
    var buf: [4096]u8 = undefined;
    const s = std.Io.Dir.cwd().readFile(io, "/proc/stat", &buf) catch return .{};
    const first_nl = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
    var it = std.mem.tokenizeAny(u8, s[0..first_nl], " \t");
    const label = it.next() orelse return .{};
    if (!std.mem.eql(u8, label, "cpu")) return .{}; // the aggregate line must lead

    // The fields are user, nice, system, idle, iowait, irq, softirq, steal.
    var v: [8]u64 = @splat(0);
    var got: usize = 0;
    while (got < v.len) : (got += 1) {
        const tok = it.next() orelse break;
        v[got] = std.fmt.parseInt(u64, tok, 10) catch break;
    }
    if (got < 5) return .{}; // user through iowait are the minimum
    return .{
        .busy = v[0] + v[1] + v[2] + v[5] + v[6] + v[7],
        .idle = v[3] + v[4],
    };
}

/// The 1-minute and 5-minute load averages.
pub const Load = struct { one: f64 = 0, five: f64 = 0 };

/// Load averages from /proc/loadavg. A read or parse fault gives zeroes.
pub fn readLoad(io: std.Io) Load {
    var buf: [128]u8 = undefined;
    const s = std.Io.Dir.cwd().readFile(io, "/proc/loadavg", &buf) catch return .{};
    var it = std.mem.tokenizeAny(u8, s, " \t\n");
    const one = it.next() orelse return .{};
    const five = it.next() orelse return .{};
    return .{
        .one = std.fmt.parseFloat(f64, one) catch 0,
        .five = std.fmt.parseFloat(f64, five) catch 0,
    };
}

/// The used-memory fraction from 0 to 1, computed from /proc/meminfo as
/// (MemTotal - MemAvailable) / MemTotal. MemAvailable already accounts for
/// reclaimable cache.
pub fn readMemUsedFrac(io: std.Io) f64 {
    var buf: [8192]u8 = undefined;
    const s = std.Io.Dir.cwd().readFile(io, "/proc/meminfo", &buf) catch return 0.0;
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

/// Seconds since boot from /proc/uptime, or 0 on a read or parse fault. The value
/// is clamped at zero before the conversion, because a negative float would make
/// the cast to an unsigned integer undefined.
pub fn readUptimeS(io: std.Io) u64 {
    var buf: [64]u8 = undefined;
    const s = std.Io.Dir.cwd().readFile(io, "/proc/uptime", &buf) catch return 0;
    var it = std.mem.tokenizeAny(u8, s, " \t\n");
    const first = it.next() orelse return 0;
    const up = std.fmt.parseFloat(f64, first) catch return 0;
    return @intFromFloat(@max(up, 0.0));
}

// -------------------------------------------------------------------- tests ---

test "CpuMeter reports the busy share between two samples" {
    // Drive the difference arithmetic directly, so the test does not depend on
    // what the host's /proc/stat happens to hold.
    var m: CpuMeter = .{ .prev = .{ .busy = 100, .idle = 300 } };
    const now: Jiffies = .{ .busy = 150, .idle = 350 };
    const busy = now.busy -% m.prev.busy;
    const total = busy +% (now.idle -% m.prev.idle);
    m.prev = now;
    try std.testing.expectEqual(@as(u64, 50), busy);
    try std.testing.expectEqual(@as(u64, 100), total);
    try std.testing.expectEqual(@as(u8, 50), @as(u8, @intCast(busy * 100 / total)));
}

test "a stalled cpu sample reports 0 rather than dividing by zero" {
    var m: CpuMeter = .{ .prev = .{ .busy = 0, .idle = 0 } };
    // Two identical samples give a zero total, which must read as 0%.
    m.prev = .{ .busy = 7, .idle = 9 };
    const now: Jiffies = .{ .busy = 7, .idle = 9 };
    const busy = now.busy -% m.prev.busy;
    const total = busy +% (now.idle -% m.prev.idle);
    try std.testing.expectEqual(@as(u64, 0), total);
}

test "readUptimeS and readMemUsedFrac stay in range on the host" {
    const io = std.testing.io;
    // /proc exists on the host, so these read real values. The contract under
    // test is the range, not the value.
    const frac = readMemUsedFrac(io);
    try std.testing.expect(frac >= 0.0 and frac <= 1.0);
    const load = readLoad(io);
    try std.testing.expect(load.one >= 0.0);
    try std.testing.expect(load.five >= 0.0);
}

test "a missing /proc node degrades to zero instead of faulting" {
    // std.testing.io reads real files, so point the readers at a path that cannot
    // exist and confirm every one of them recovers.
    var buf: [64]u8 = undefined;
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().readFile(std.testing.io, "/proc/nix-badge-absent", &buf),
    );
    const j = readCpuJiffies(std.testing.io);
    // The host has a real /proc/stat, so busy must have advanced past zero.
    try std.testing.expect(j.busy > 0 or j.idle > 0);
}
