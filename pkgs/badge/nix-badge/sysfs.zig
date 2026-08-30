//! Board sensors and control lines reached through sysfs and the GPIO char
//! device: named GPIO lines (core-select latch, VBUS, faults, the USER button),
//! the SARADC rails over IIO, and the battery over the kernel power_supply node.

const std = @import("std");
const linux = @import("linux.zig");
const gpio = linux.Gpio;

/// Read a small sysfs file and parse a leading unsigned integer, or null if the
/// node is missing or unparsable (a missing node means "unavailable", recovered).
pub fn readU64(path: [*:0]const u8) ?u64 {
    var buf: [64]u8 = undefined;
    const s = linux.readFile(path, &buf) orelse return null;
    const t = std.mem.trim(u8, s, " \t\r\n");
    return std.fmt.parseInt(u64, t, 10) catch null;
}

/// Insert `value` into the sorted prefix `buf[0..count]`, keeping it ascending.
/// The caller passes `count` as the current filled length; the return value is the
/// new length. A tiny insertion sort: N is fixed and small, so no allocator and no
/// O(N log N) machinery is warranted (IronStyle: reach for std only when it fits —
/// here the in-place insert into a running-sorted buffer is the simplest form).
fn insertSorted(comptime T: type, buf: []T, count: usize, value: T) usize {
    var j = count;
    while (j > 0 and buf[j - 1] > value) : (j -= 1) buf[j] = buf[j - 1];
    buf[j] = value;
    return count + 1;
}

/// Median of `median_samples` reads of an unsigned sysfs integer. Same rationale
/// as `medianRaw`: the value ultimately comes off the leaky SARADC (here through
/// the kernel power_supply rescale), so single reads spike. Allocation-free, with
/// a fixed stack buffer sorted by insertion. Returns null if nothing read.
pub fn medianU64(path: [*:0]const u8) ?u64 {
    var samples: [median_samples]u64 = undefined;
    var count: usize = 0;
    for (0..median_samples) |_| {
        const v = readU64(path) orelse continue;
        count = insertSorted(u64, &samples, count, v);
    }
    if (count == 0) return null;
    return samples[count / 2];
}

/// Read a small sysfs file as a float (e.g. in_voltage_scale in mV/LSB).
pub fn readF64(path: [*:0]const u8) ?f64 {
    var buf: [64]u8 = undefined;
    const s = linux.readFile(path, &buf) orelse return null;
    const t = std.mem.trim(u8, s, " \t\r\n");
    return std.fmt.parseFloat(f64, t) catch null;
}

// ============================================================== gpio lines ===

/// A GPIO line found by name: which chip fd it lives on and its offset.
const FoundLine = struct { chip: linux.fd_t, offset: u32 };

/// Locate a named GPIO line across /dev/gpiochip0..15, using the device tree's
/// gpio-line-names so nothing depends on chip numbering. Returns null when no
/// chip carries the name. On success the caller owns `chip` and must close it.
fn findLine(name: []const u8) ?FoundLine {
    var chip: u32 = 0;
    while (chip < 16) : (chip += 1) {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/dev/gpiochip{d}", .{chip}) catch continue;
        const fd = linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch continue;

        var info: gpio.ChipInfo = std.mem.zeroes(gpio.ChipInfo);
        if (linux.ioctl(fd, gpio.GET_CHIPINFO, @intFromPtr(&info))) |_| {
            var l: u32 = 0;
            while (l < info.lines) : (l += 1) {
                var li: gpio.LineInfo = .{};
                li.offset = l;
                _ = linux.ioctl(fd, gpio.GET_LINEINFO, @intFromPtr(&li)) catch continue;
                const li_name = std.mem.sliceTo(&li.name, 0);
                if (std.mem.eql(u8, li_name, name)) return .{ .chip = fd, .offset = l };
            }
        } else |_| {}
        linux.close(fd);
    }
    return null;
}

fn setConsumer(dst: *[gpio.MAX_NAME_SIZE]u8, label: []const u8) void {
    @memset(dst, 0);
    const n = @min(label.len, dst.len - 1);
    @memcpy(dst[0..n], label[0..n]);
}

/// Read a named line as an input: 0, 1, or null if the line is unavailable.
/// Requests and releases the line per call; use `Button` for a line polled hot.
pub fn readLine(name: []const u8) ?u1 {
    const found = findLine(name) orelse return null;
    defer linux.close(found.chip);

    var req: gpio.LineRequest = .{};
    req.offsets[0] = found.offset;
    req.num_lines = 1;
    req.config.flags = gpio.FLAG_INPUT;
    setConsumer(&req.consumer, "nix-badge");

    _ = linux.ioctl(found.chip, gpio.GET_LINE, @intFromPtr(&req)) catch return null;
    if (req.fd < 0) return null;
    defer linux.close(req.fd);

    var vals: gpio.LineValues = .{};
    vals.mask = 1;
    _ = linux.ioctl(req.fd, gpio.GET_VALUES, @intFromPtr(&vals)) catch return null;
    return @intCast(vals.bits & 1);
}

// -------------------------------------------------------------- push button ---
//
// A momentary button (active-low: idles high, 0 while pressed). The C re-requested
// the line every 20 ms poll, which churns GPIO_V2_GET_LINE on one line and can
// EBUSY or drop an edge. We instead request the line ONCE with both edges enabled
// and read edge events off the held request fd, so presses are event-driven and
// never missed. The fd is pollable, so the frame loop waits on it directly.

/// A press or release edge, decoded from the kernel's edge event.
pub const ButtonEdge = enum { press, release };

/// A held GPIO line request for a momentary, active-low button.
pub const Button = struct {
    req_fd: linux.fd_t,

    /// Request `name` once with rising+falling edge detection. Returns null when
    /// the line does not exist (a core without the button), which the caller
    /// treats as "no button" and simply omits button handling.
    pub fn open(name: []const u8) ?Button {
        const found = findLine(name) orelse return null;
        defer linux.close(found.chip);

        var req: gpio.LineRequest = .{};
        req.offsets[0] = found.offset;
        req.num_lines = 1;
        req.config.flags = gpio.FLAG_INPUT | gpio.FLAG_EDGE_RISING | gpio.FLAG_EDGE_FALLING;
        setConsumer(&req.consumer, "nix-badge btn");

        _ = linux.ioctl(found.chip, gpio.GET_LINE, @intFromPtr(&req)) catch return null;
        if (req.fd < 0) return null;
        return .{ .req_fd = req.fd };
    }

    /// Request `name` once as a plain INPUT (no edge IRQ) for LEVEL polling. Use
    /// this on controllers without edge-interrupt support -- the RTC/PWR gpio at
    /// 0x5021000 (the USER button) ENXIOs any edge request, but reads fine. Null
    /// when the line does not exist. Sample with `level()`; the caller detects
    /// the press/release + timing in software.
    pub fn openPolled(name: []const u8) ?Button {
        const found = findLine(name) orelse return null;
        defer linux.close(found.chip);

        var req: gpio.LineRequest = .{};
        req.offsets[0] = found.offset;
        req.num_lines = 1;
        req.config.flags = gpio.FLAG_INPUT;
        setConsumer(&req.consumer, "nix-badge btn");

        _ = linux.ioctl(found.chip, gpio.GET_LINE, @intFromPtr(&req)) catch return null;
        if (req.fd < 0) return null;
        return .{ .req_fd = req.fd };
    }

    /// The line's current level via the held request fd (no re-request), or null
    /// on ioctl failure. Active-low: 0 = pressed, 1 = released.
    pub fn level(self: *const Button) ?u1 {
        var vals: gpio.LineValues = .{};
        vals.mask = 1;
        _ = linux.ioctl(self.req_fd, gpio.GET_VALUES, @intFromPtr(&vals)) catch return null;
        return @intCast(vals.bits & 1);
    }

    pub fn close(self: *Button) void {
        linux.close(self.req_fd);
    }

    /// The fd to poll for readable edge events.
    pub fn pollFd(self: *const Button) linux.fd_t {
        return self.req_fd;
    }

    /// Read the next queued edge without blocking, or null when none is ready.
    /// The line is active-low, so a falling edge is a press and a rising edge a
    /// release. Call in a loop after poll() reports the fd readable to drain all
    /// coalesced edges.
    pub fn nextEdge(self: *const Button) ?ButtonEdge {
        var ev: gpio.LineEvent = .{};
        const raw = std.mem.asBytes(&ev);
        const n = linux.read(self.req_fd, raw) catch return null;
        if (n < raw.len) return null;
        return switch (ev.id) {
            gpio.EVENT_FALLING_EDGE => .press,
            gpio.EVENT_RISING_EDGE => .release,
            else => null,
        };
    }
};

// -------------------------------------------------------- core-select latch ---
//
// The badge picks its boot core with a 74AUP1G175 flip-flop on the always-on
// VRTC rail. D = 1 selects ARM, 0 RISC-V; a rising edge on CP captures D; the
// strap reads back inverted (1 = RISC-V). Lines are found by name.

const line_latch_d = "core-sel-latch-d";
const line_latch_clk = "core-sel-latch-clk";
const line_strap = "core-sel-strap";

pub const CoreError = error{ LatchLineMissing, ClockLineMissing, ClaimFailed, PulseFailed };

pub const Core = enum { arm, riscv };

/// Latch the boot core. Both lines come from ONE request so D is held steady
/// while CP is pulsed, with a guaranteed order; getting that wrong picks the
/// wrong core, so it is worth the single-request discipline.
pub fn latchCore(core: Core) CoreError!void {
    const d_value: u64 = switch (core) {
        .arm => 1,
        .riscv => 0,
    };

    const d = findLine(line_latch_d) orelse return error.LatchLineMissing;
    defer linux.close(d.chip);
    const clk = findLine(line_latch_clk) orelse return error.ClockLineMissing;
    linux.close(clk.chip); // reuse d.chip for the combined request; both lines are on one chip

    var req: gpio.LineRequest = .{};
    req.offsets[0] = d.offset; // index 0 = D
    req.offsets[1] = clk.offset; // index 1 = CP
    req.num_lines = 2;
    req.config.flags = gpio.FLAG_OUTPUT;
    setConsumer(&req.consumer, "nix-badge core");
    // Start with D at the wanted value and CP low so the edge we make is the only
    // one the flip-flop sees.
    req.config.num_attrs = 1;
    req.config.attrs[0].attr.id = gpio.ATTR_ID_OUTPUT_VALUES;
    req.config.attrs[0].attr.value = d_value;
    req.config.attrs[0].mask = 0b11;

    _ = linux.ioctl(d.chip, gpio.GET_LINE, @intFromPtr(&req)) catch return error.ClaimFailed;
    if (req.fd < 0) return error.ClaimFailed;
    defer linux.close(req.fd);

    linux.sleepNsec(std.time.ns_per_ms); // settle

    var vals: gpio.LineValues = .{};
    vals.mask = 0b11;
    vals.bits = d_value | 0b10; // rising edge on CP captures D
    _ = linux.ioctl(req.fd, gpio.SET_VALUES, @intFromPtr(&vals)) catch return error.PulseFailed;
    linux.sleepNsec(std.time.ns_per_ms);

    vals.bits = d_value; // return CP low; the value is already captured
    _ = linux.ioctl(req.fd, gpio.SET_VALUES, @intFromPtr(&vals)) catch return error.PulseFailed;
    linux.sleepNsec(std.time.ns_per_ms);
}

/// The strap readback: null if unavailable, else which core the next boot picks.
pub fn readStrap() ?Core {
    const bit = readLine(line_strap) orelse return null;
    return if (bit != 0) .riscv else .arm; // inverted from D
}

// ================================================================ iio rails ===
//
// The device tree now scales every rail in-kernel, so the tool applies NO factor
// of its own. Two device shapes appear under /sys/bus/iio/devices:
//
//   * iio-rescale voltmeters (VSEL, VBAT): matched by `label`, one channel each,
//     with a per-channel `in_voltage0_scale` (the ~19.24 divider is already baked
//     in, so scale comes out ~15.5 mV/LSB). millivolts = in_voltage0_raw * scale.
//   * the base SARADC (`name` = "sophgo-cv1800b-adc"): the raw user ADC exposing
//     in_voltage{0,1,2}_raw and a single shared `in_voltage_scale` (~0.806
//     mV/LSB). J6 has NO divider, so J6 mV = in_voltage2_raw * in_voltage_scale.
//
// A missing device/label degrades to null (a recoverable runtime fault the caller
// renders as "--"), logged at the read site.

const iio_root = "/sys/bus/iio/devices";
const base_adc_name = "sophgo-cv1800b-adc";

// The SARADC feeds every rail through a high-Z, leaky 2.2M/1M divider whose source
// impedance the ADC's short sample window cannot fully settle, so a single-shot raw
// read spikes badly (VSEL momentarily read 9 V on a ~5 V rail). We reject those the
// way the original C tool did: read the channel many times and take the MEDIAN raw
// count, which discards the occasional under-settled outlier while an average would
// be dragged by it. N = 33: odd (a clean median at index N/2), well past the 25 the
// C found marginal, and cheap — each read is a few us of sysfs I/O, so ~33 of them
// is tens of us, negligible for the one-shot `power` CLI and the ~1-2 Hz meters.
const median_samples = 33;

/// Read `<dir>/in_voltage<ch>_raw` `median_samples` times and return the median
/// raw count, or null when not one sample could be read. Allocation-free: the
/// samples live in a fixed stack buffer, sorted in place with an insertion sort
/// (N is tiny, so O(N^2) is fine and needs no allocator).
fn medianRaw(dir: []const u8, channel: u32) ?i64 {
    var path_buf: [96]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/in_voltage{d}_raw", .{ dir, channel }) catch
        return null;

    var samples: [median_samples]i64 = undefined;
    var count: usize = 0;
    for (0..median_samples) |_| {
        const raw = readF64(path) orelse continue;
        count = insertSorted(i64, &samples, count, @intFromFloat(raw));
    }
    if (count == 0) return null;
    return samples[count / 2];
}

/// Find the iio:deviceN directory whose `attr` file (name or label) contains
/// `needle`, writing the directory path into `out`. Returns the slice or null.
fn findIioDir(out: []u8, attr: []const u8, needle: []const u8) ?[]const u8 {
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        var dir_buf: [64]u8 = undefined;
        const dir = std.fmt.bufPrint(&dir_buf, "{s}/iio:device{d}", .{ iio_root, i }) catch
            continue;
        var attr_path_buf: [96]u8 = undefined;
        const attr_path = std.fmt.bufPrintZ(&attr_path_buf, "{s}/{s}", .{ dir, attr }) catch
            continue;
        var val_buf: [64]u8 = undefined;
        const val = linux.readFile(attr_path, &val_buf) orelse continue;
        if (std.mem.indexOf(u8, val, needle) != null) {
            const n = @min(dir.len, out.len);
            @memcpy(out[0..n], dir[0..n]);
            return out[0..n];
        }
    }
    return null;
}

/// volts = median_raw * scale / 1000, taking the MEDIAN of `median_samples` raw
/// reads (the leaky divider spikes single reads) and the scale from `scale_attr`
/// (single read: it is a constant). Returns null on any read fault.
fn channelVolts(dir: []const u8, channel: u32, scale_attr: []const u8) ?f64 {
    const raw = medianRaw(dir, channel) orelse return null;
    if (raw < 0) return null;
    var scale_buf: [96]u8 = undefined;
    const scale_path = std.fmt.bufPrintZ(&scale_buf, "{s}/{s}", .{ dir, scale_attr }) catch
        return null;
    const scale = readF64(scale_path) orelse return null;
    return @as(f64, @floatFromInt(raw)) * scale / 1000.0;
}

/// The VSEL system rail in volts, via the vsel iio-rescale voltmeter, or null.
pub fn readVselVolts() ?f64 {
    var dir_buf: [64]u8 = undefined;
    const dir = findIioDir(&dir_buf, "label", "vsel") orelse return null;
    return channelVolts(dir, 0, "in_voltage0_scale");
}

/// The J6 external test point in volts, via the base SARADC channel 2 (no
/// divider), or null.
pub fn readJ6Volts() ?f64 {
    var dir_buf: [64]u8 = undefined;
    const dir = findIioDir(&dir_buf, "name", base_adc_name) orelse return null;
    return channelVolts(dir, 2, "in_voltage_scale");
}

// ================================================================= battery ===
//
// The battery now has a kernel power_supply node, so we read it there rather than
// off the SARADC (the port dropped the userspace battery cal). voltage_now is in
// microvolts; capacity is 0..100; status is a short word.

const psu_dir = "/sys/class/power_supply/vbat-adc-battery";

// The vbat-adc-battery node reports voltage_now at ~2x the true pack voltage (the iio-rescale
// divider is double-counted: a 3xAA pack reads ~9.9 V but is ~4.96 V), so halve it. The proper
// fix is the DT rescale, which needs an SD reflash; this is the deployable correction.
const bat_scale_num: u64 = 1;
const bat_scale_den: u64 = 2;
// The node exposes NO `capacity` (generic-adc-battery has no monitored-battery/OCV table), so
// percent is derived from the corrected voltage over the 3xAA usable window: ~1.1 V/cell (the
// regulators' practical cutoff) to ~1.6 V/cell (fresh). Alkaline discharge is non-linear, so
// this is a coarse gauge; tune the two bounds if it reads optimistic.
const bat_empty_mv: u64 = 3300;
const bat_full_mv: u64 = 4800;

pub const Battery = struct {
    /// Millivolts, or null when the node is absent.
    millivolts: ?u32,
    /// 0..100, or null when unknown.
    percent: ?u8,
    status_buf: [24]u8 = @splat(0),
    status_len: usize = 0,

    pub fn status(self: *const Battery) []const u8 {
        return self.status_buf[0..self.status_len];
    }
};

/// Read the battery from sysfs. Any field may be null/empty if its node is
/// missing; the caller renders "--"/"unknown" gracefully.
pub fn readBattery() Battery {
    var b: Battery = .{ .millivolts = null, .percent = null };

    // voltage_now (microvolts) rides the leaky SARADC through the kernel rescale, so median
    // it; then apply the 2x scale correction.
    if (medianU64(psu_dir ++ "/voltage_now")) |uv| {
        const mv: u64 = (uv / 1000) * bat_scale_num / bat_scale_den;
        b.millivolts = @intCast(mv);
        // Prefer a real `capacity` if the node ever grows one; otherwise derive percent from
        // the corrected voltage over the 3xAA window (linear, clamped).
        if (readU64(psu_dir ++ "/capacity")) |cap| {
            b.percent = @intCast(@min(cap, 100));
        } else {
            const c = std.math.clamp(mv, bat_empty_mv, bat_full_mv);
            b.percent = @intCast((c - bat_empty_mv) * 100 / (bat_full_mv - bat_empty_mv));
        }
    }
    var sbuf: [64]u8 = undefined;
    if (linux.readFile(psu_dir ++ "/status", &sbuf)) |s| {
        const t = std.mem.trim(u8, s, " \t\r\n");
        const n = @min(t.len, b.status_buf.len);
        @memcpy(b.status_buf[0..n], t[0..n]);
        b.status_len = n;
    }
    return b;
}

test "insertSorted keeps the buffer ascending as values arrive out of order" {
    var buf: [8]i64 = undefined;
    var count: usize = 0;
    for ([_]i64{ 5, 1, 9, 3, 7 }) |v| count = insertSorted(i64, &buf, count, v);
    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expectEqualSlices(i64, &[_]i64{ 1, 3, 5, 7, 9 }, buf[0..count]);
    // The median (middle element) is the settled value...
    try std.testing.expectEqual(@as(i64, 5), buf[count / 2]);
}

test "median rejects a lone spike the way the leaky SARADC needs" {
    // Simulate the failure mode: many ~320-count reads and one 640-count spike (a
    // VSEL read jumping to ~2x). The median must stay at the settled value; a mean
    // would be dragged upward by the outlier.
    var buf: [median_samples]i64 = undefined;
    var count: usize = 0;
    for (0..median_samples) |i| {
        const v: i64 = if (i == 3) 640 else 320; // one under-settled spike
        count = insertSorted(i64, &buf, count, v);
    }
    try std.testing.expectEqual(@as(i64, 320), buf[count / 2]);
}

test "readBattery reports null millivolts when the node is absent" {
    // On the host build the vbat-adc-battery node does not exist, so every field
    // degrades to null/empty rather than crashing — the graceful path the badge
    // relies on when a core does not expose the battery.
    const b = readBattery();
    try std.testing.expectEqual(@as(?u32, null), b.millivolts);
    try std.testing.expectEqual(@as(usize, 0), b.status_len);
}
