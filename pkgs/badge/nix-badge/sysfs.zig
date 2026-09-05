//! Board sensors and control lines, read through sysfs and the GPIO character
//! device: the named GPIO lines (core-select latch, VBUS, faults, the USER
//! button), the SARADC rails over IIO, and the battery pack voltage.
//!
//! Text attributes come through the injected `std.Io`, so a caller can supply a
//! test I/O backend. The GPIO character device needs `ioctl`, which `std.Io` does
//! not model, so this module opens the chip through `std.Io` and then calls
//! `std.os.linux.ioctl` on the file handle. The uAPI structs below are the v2
//! `linux/gpio.h` layout; their widths are asserted at comptime so a field
//! mistake fails the build and not a device.

const std = @import("std");

/// The largest attribute this module reads. Every sysfs node it touches holds one
/// short number or one short label.
const attr_max = 64;

/// Read a small sysfs attribute and parse it as `T`. Integers parse in base 10
/// and floats parse as decimal.
///
/// Returns null when the node is missing, is longer than `attr_max`, or does not
/// parse. A missing or malformed sysfs node means "unavailable", which every
/// caller recovers from, so this reports null rather than an error.
pub fn read(comptime T: type, io: std.Io, path: []const u8) ?T {
    var buf: [attr_max]u8 = undefined;
    const raw = std.Io.Dir.cwd().readFile(io, path, &buf) catch return null;
    const text = std.mem.trim(u8, raw, " \t\r\n");
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, text, 10) catch null,
        .float => std.fmt.parseFloat(T, text) catch null,
        else => @compileError("sysfs.read handles integers and floats only, got " ++ @typeName(T)),
    };
}

/// Put `value` into the sorted prefix `buf[0..count]` and keep the prefix in
/// ascending order. The return value is the new length. The sample count is
/// fixed and small, so this insertion sort needs no allocator.
fn insertSorted(comptime T: type, buf: []T, count: usize, value: T) usize {
    var j = count;
    while (j > 0 and buf[j - 1] > value) : (j -= 1) buf[j] = buf[j - 1];
    buf[j] = value;
    return count + 1;
}

// ============================================================== gpio lines ===

/// The v2 uAPI subset this module drives. Values come from `linux/gpio.h` and are
/// the same on aarch64 and riscv64, because both are LP64.
pub const Gpio = struct {
    pub const max_name_size = 32;
    pub const lines_max = 64;
    pub const num_attrs_max = 10;

    pub const flag_input: u64 = 1 << 2; // GPIO_V2_LINE_FLAG_INPUT
    pub const flag_output: u64 = 1 << 3; // GPIO_V2_LINE_FLAG_OUTPUT
    pub const attr_id_output_values: u32 = 2; // GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES

    pub const get_chipinfo: u32 = 0x8044b401; // GPIO_GET_CHIPINFO_IOCTL
    pub const get_lineinfo: u32 = 0xc100b405; // GPIO_V2_GET_LINEINFO_IOCTL
    pub const get_line: u32 = 0xc250b407; // GPIO_V2_GET_LINE_IOCTL
    pub const get_values: u32 = 0xc010b40e; // GPIO_V2_LINE_GET_VALUES_IOCTL
    pub const set_values: u32 = 0xc010b40f; // GPIO_V2_LINE_SET_VALUES_IOCTL

    pub const ChipInfo = extern struct {
        name: [max_name_size]u8 = @splat(0),
        label: [max_name_size]u8 = @splat(0),
        lines: u32 = 0,
    };

    pub const LineAttribute = extern struct {
        id: u32 = 0,
        padding: u32 = 0,
        /// The header union of flags, values, and debounce_period_us.
        value: u64 align(8) = 0,
    };

    pub const LineConfigAttribute = extern struct {
        attr: LineAttribute = .{},
        mask: u64 align(8) = 0,
    };

    pub const LineConfig = extern struct {
        flags: u64 align(8) = 0,
        num_attrs: u32 = 0,
        padding: [5]u32 = @splat(0),
        attrs: [num_attrs_max]LineConfigAttribute = @splat(.{}),
    };

    pub const LineRequest = extern struct {
        offsets: [lines_max]u32 = @splat(0),
        consumer: [max_name_size]u8 = @splat(0),
        config: LineConfig = .{},
        num_lines: u32 = 0,
        event_buffer_size: u32 = 0,
        padding: [5]u32 = @splat(0),
        fd: i32 = 0,
    };

    pub const LineInfo = extern struct {
        name: [max_name_size]u8 = @splat(0),
        consumer: [max_name_size]u8 = @splat(0),
        offset: u32 = 0,
        num_attrs: u32 = 0,
        flags: u64 align(8) = 0,
        attrs: [num_attrs_max]LineAttribute = @splat(.{}),
        padding: [4]u32 = @splat(0),
    };

    pub const LineValues = extern struct {
        bits: u64 align(8) = 0,
        mask: u64 align(8) = 0,
    };

    comptime {
        std.debug.assert(@sizeOf(ChipInfo) == 68);
        std.debug.assert(@sizeOf(LineAttribute) == 16);
        std.debug.assert(@sizeOf(LineConfigAttribute) == 24);
        std.debug.assert(@sizeOf(LineConfig) == 272);
        std.debug.assert(@sizeOf(LineRequest) == 592);
        std.debug.assert(@sizeOf(LineInfo) == 256);
        std.debug.assert(@sizeOf(LineValues) == 16);
    }
};

/// An ioctl on an open file. The result is the raw signed return, because the
/// GPIO calls write the request fd back into the caller's struct.
fn ioctl(handle: std.Io.File.Handle, request: u32, arg: usize) error{Io}!usize {
    const rc = std.os.linux.ioctl(handle, request, arg);
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => rc,
        else => error.Io,
    };
}

/// Close a raw request fd the kernel handed back inside a `LineRequest`. That fd
/// never passes through `std.Io`, so it is closed directly.
fn closeHandle(handle: std.Io.File.Handle) void {
    // A close error is not actionable, because the fd is released either way.
    // EBADF would mean a double close, which is our own bug.
    std.debug.assert(std.os.linux.errno(std.os.linux.close(handle)) != .BADF);
}

/// A GPIO line found by name: the chip file it lives on and its line offset.
const FoundLine = struct { chip: std.Io.File, offset: u32 };

/// Find a named GPIO line across /dev/gpiochip0..15 through the device tree's
/// gpio-line-names, so nothing depends on chip numbering. Returns null when no
/// chip carries the name. On success the caller owns `chip` and must close it.
fn findLine(io: std.Io, name: []const u8) ?FoundLine {
    var chip: u32 = 0;
    while (chip < 16) : (chip += 1) {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/dev/gpiochip{d}", .{chip}) catch continue;
        const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch continue;

        var info: Gpio.ChipInfo = .{};
        if (ioctl(file.handle, Gpio.get_chipinfo, @intFromPtr(&info))) |_| {
            var line: u32 = 0;
            while (line < info.lines) : (line += 1) {
                var li: Gpio.LineInfo = .{};
                li.offset = line;
                _ = ioctl(file.handle, Gpio.get_lineinfo, @intFromPtr(&li)) catch continue;
                if (std.mem.eql(u8, std.mem.sliceTo(&li.name, 0), name))
                    return .{ .chip = file, .offset = line };
            }
        } else |_| {}
        file.close(io);
    }
    return null;
}

fn setConsumer(dst: *[Gpio.max_name_size]u8, label: []const u8) void {
    @memset(dst, 0);
    const n = @min(label.len, dst.len - 1);
    @memcpy(dst[0..n], label[0..n]);
}

/// Read a named line as an input: 0, 1, or null if the line is unavailable. This
/// requests and releases the line on each call. Use `Button` for a line that is
/// sampled at a high rate.
pub fn readLine(io: std.Io, name: []const u8) ?u1 {
    const found = findLine(io, name) orelse return null;
    defer found.chip.close(io);

    var req: Gpio.LineRequest = .{};
    req.offsets[0] = found.offset;
    req.num_lines = 1;
    req.config.flags = Gpio.flag_input;
    setConsumer(&req.consumer, "nix-badge");

    _ = ioctl(found.chip.handle, Gpio.get_line, @intFromPtr(&req)) catch return null;
    if (req.fd < 0) return null;
    defer closeHandle(req.fd);

    var vals: Gpio.LineValues = .{};
    vals.mask = 1;
    _ = ioctl(req.fd, Gpio.get_values, @intFromPtr(&vals)) catch return null;
    return @intCast(vals.bits & 1);
}

// -------------------------------------------------------------- push button ---

/// A momentary, active-low button held as one GPIO line request. The line idles
/// high and reads 0 while the button is down.
///
/// The RTC/PWR controller that carries the USER button gives no edge interrupt,
/// so the line must be sampled. The request is made once and held, because a
/// per-sample request churns GPIO_V2_GET_LINE and can return EBUSY.
pub const Button = struct {
    req_fd: std.Io.File.Handle,

    /// Request `name` once as a plain input for level sampling. Returns null when
    /// the line does not exist, which the caller treats as "no button".
    pub fn open(io: std.Io, name: []const u8) ?Button {
        const found = findLine(io, name) orelse return null;
        defer found.chip.close(io);

        var req: Gpio.LineRequest = .{};
        req.offsets[0] = found.offset;
        req.num_lines = 1;
        req.config.flags = Gpio.flag_input;
        setConsumer(&req.consumer, "nix-badge btn");

        _ = ioctl(found.chip.handle, Gpio.get_line, @intFromPtr(&req)) catch return null;
        if (req.fd < 0) return null;
        return .{ .req_fd = req.fd };
    }

    /// The current level through the held request fd, or null on an ioctl fault.
    /// The line is active-low: 0 is pressed and 1 is released.
    pub fn level(self: *const Button) ?u1 {
        var vals: Gpio.LineValues = .{};
        vals.mask = 1;
        _ = ioctl(self.req_fd, Gpio.get_values, @intFromPtr(&vals)) catch return null;
        return @intCast(vals.bits & 1);
    }

    pub fn close(self: *Button) void {
        closeHandle(self.req_fd);
    }
};

// -------------------------------------------------------- core-select latch ---
//
// The badge selects its boot core with a 74AUP1G175 flip-flop on the always-on
// VRTC rail. D = 1 selects ARM and D = 0 selects RISC-V. A rising edge on CP
// captures D. The strap reads back inverted, so 1 means RISC-V.

const line_latch_d = "core-sel-latch-d";
const line_latch_clk = "core-sel-latch-clk";
const line_strap = "core-sel-strap";

pub const CoreError = error{ LatchLineMissing, ClockLineMissing, ClaimFailed, PulseFailed };

pub const Core = enum { arm, riscv };

/// Latch the boot core. Both lines come from ONE request, so D stays steady while
/// CP is pulsed and the order is guaranteed. A wrong order selects the wrong core,
/// so the single-request discipline is necessary.
pub fn latchCore(io: std.Io, core: Core) CoreError!void {
    const d_value: u64 = switch (core) {
        .arm => 1,
        .riscv => 0,
    };

    const d = findLine(io, line_latch_d) orelse return error.LatchLineMissing;
    defer d.chip.close(io);
    const clk = findLine(io, line_latch_clk) orelse return error.ClockLineMissing;
    // Both lines sit on one chip, so the combined request below reuses d.chip.
    clk.chip.close(io);

    var req: Gpio.LineRequest = .{};
    req.offsets[0] = d.offset; // index 0 is D
    req.offsets[1] = clk.offset; // index 1 is CP
    req.num_lines = 2;
    req.config.flags = Gpio.flag_output;
    setConsumer(&req.consumer, "nix-badge core");
    // Start with D at the wanted value and CP low, so the edge we make is the only
    // edge the flip-flop sees.
    req.config.num_attrs = 1;
    req.config.attrs[0].attr.id = Gpio.attr_id_output_values;
    req.config.attrs[0].attr.value = d_value;
    req.config.attrs[0].mask = 0b11;

    _ = ioctl(d.chip.handle, Gpio.get_line, @intFromPtr(&req)) catch return error.ClaimFailed;
    if (req.fd < 0) return error.ClaimFailed;
    defer closeHandle(req.fd);

    settle(io);

    var vals: Gpio.LineValues = .{};
    vals.mask = 0b11;
    vals.bits = d_value | 0b10; // the rising edge on CP captures D
    _ = ioctl(req.fd, Gpio.set_values, @intFromPtr(&vals)) catch return error.PulseFailed;
    settle(io);

    vals.bits = d_value; // return CP low; the value is already captured
    _ = ioctl(req.fd, Gpio.set_values, @intFromPtr(&vals)) catch return error.PulseFailed;
    settle(io);
}

/// Hold for one millisecond so the latch lines settle.
///
/// The only failure here is cancellation, which shortens the hold. The flip-flop's
/// setup time is measured in nanoseconds, so even a hold cut to nothing still
/// meets it, and the caller checks the strap afterwards either way.
fn settle(io: std.Io) void {
    io.sleep(.{ .nanoseconds = std.time.ns_per_ms }, .awake) catch |err|
        std.log.debug("core latch: the settle delay was cut short: {t}", .{err});
}

/// The strap readback: null when unavailable, else the core the next boot selects.
pub fn readStrap(io: std.Io) ?Core {
    const bit = readLine(io, line_strap) orelse return null;
    return if (bit != 0) .riscv else .arm; // inverted from D
}

// ================================================================ iio rails ===
//
// The device tree scales every rail in the kernel, so this tool applies no factor
// of its own. Two device shapes appear under /sys/bus/iio/devices:
//
//   * iio-rescale voltmeters (VSEL, VBAT), matched by `label`, with one channel
//     each and a per-channel `in_voltage0_scale`. The ~19.24 divider is already
//     part of that scale, which comes out near 15.5 mV/LSB.
//   * the base SARADC (`name` = "sophgo-cv1800b-adc"), the raw user ADC. It
//     exposes in_voltage{0,1,2}_raw and one shared `in_voltage_scale` near 0.806
//     mV/LSB. J6 has no divider, so J6 mV = in_voltage2_raw * in_voltage_scale.
//
// A missing device or label gives null, which the caller renders as "--".

const iio_root = "/sys/bus/iio/devices";
const base_adc_name = "sophgo-cv1800b-adc";

// The SARADC reads every rail through a high-impedance, leaky 2.2M/1M divider.
// The converter's short sample window cannot fully settle that source, so a
// single raw read spikes badly: VSEL momentarily read 9 V on a ~5 V rail. To
// reject those spikes, read the channel many times and take the MEDIAN raw count.
// The median discards an occasional under-settled outlier, but a mean would be
// pulled by it. N = 33 is odd, which gives a clean median at index N/2, and it is
// well past the 25 samples that proved marginal. Each read costs a few
// microseconds, so 33 of them stay negligible for the one-shot `power` command
// and the 1 to 2 Hz meters.
const median_samples = 33;

/// Read `<dir>/in_voltage<ch>_raw` `median_samples` times and return the median
/// raw count, or null when no sample could be read. The samples live in a fixed
/// stack buffer, so this needs no allocator.
fn medianRaw(io: std.Io, dir: []const u8, channel: u32) ?i64 {
    var path_buf: [96]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/in_voltage{d}_raw", .{ dir, channel }) catch
        return null;

    var samples: [median_samples]i64 = undefined;
    var count: usize = 0;
    for (0..median_samples) |_| {
        const raw = read(f64, io, path) orelse continue;
        count = insertSorted(i64, &samples, count, @intFromFloat(raw));
    }
    if (count == 0) return null;
    return samples[count / 2];
}

/// Find the iio:deviceN directory whose `attr` file (name or label) contains
/// `needle` and write that directory path into `out`. Returns the slice or null.
fn findIioDir(io: std.Io, out: []u8, attr: []const u8, needle: []const u8) ?[]const u8 {
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        var dir_buf: [64]u8 = undefined;
        const dir = std.fmt.bufPrint(&dir_buf, "{s}/iio:device{d}", .{ iio_root, i }) catch
            continue;
        var attr_path_buf: [96]u8 = undefined;
        const attr_path = std.fmt.bufPrint(&attr_path_buf, "{s}/{s}", .{ dir, attr }) catch
            continue;
        var val_buf: [attr_max]u8 = undefined;
        const val = std.Io.Dir.cwd().readFile(io, attr_path, &val_buf) catch continue;
        if (std.mem.indexOf(u8, val, needle) == null) continue;
        // A truncated path would name the wrong device, so refuse a short buffer.
        if (dir.len > out.len) return null;
        @memcpy(out[0..dir.len], dir);
        return out[0..dir.len];
    }
    return null;
}

/// volts = median_raw * scale / 1000. The raw count is the median of
/// `median_samples` reads, because the leaky divider spikes single reads. The
/// scale is a constant, so it is read once. Returns null on any read fault.
fn channelVolts(io: std.Io, dir: []const u8, channel: u32, scale_attr: []const u8) ?f64 {
    const raw = medianRaw(io, dir, channel) orelse return null;
    if (raw < 0) return null;
    var scale_buf: [96]u8 = undefined;
    const scale_path = std.fmt.bufPrint(&scale_buf, "{s}/{s}", .{ dir, scale_attr }) catch
        return null;
    const scale = read(f64, io, scale_path) orelse return null;
    return @as(f64, @floatFromInt(raw)) * scale / 1000.0;
}

/// The VSEL system rail in volts, through the vsel iio-rescale voltmeter.
pub fn readVselVolts(io: std.Io) ?f64 {
    var dir_buf: [64]u8 = undefined;
    const dir = findIioDir(io, &dir_buf, "label", "vsel") orelse return null;
    return channelVolts(io, dir, 0, "in_voltage0_scale");
}

/// The J6 external test point in volts, through base SARADC channel 2, which has
/// no divider.
pub fn readJ6Volts(io: std.Io) ?f64 {
    var dir_buf: [64]u8 = undefined;
    const dir = findIioDir(io, &dir_buf, "name", base_adc_name) orelse return null;
    return channelVolts(io, dir, 2, "in_voltage_scale");
}

// ================================================================= battery ===
//
// VBAT comes from the vbat iio-rescale channel, the same path as readVselVolts,
// and NOT from the generic-adc-battery power_supply node. After the SARADC
// recalibration the rescaled iio channels are correct: VSEL cross-checks against
// the ~5.1 V VBUS at 5.2 V. The power_supply `voltage_now` instead reads about
// HALF the real pack voltage, because its own sample path loads the divider
// differently. That is where the "0% and wrong voltage" report came from: an
// earlier /2 correction, calibrated against the pre-recalibration kernel, made
// the value doubly wrong. It showed 1.3 V for a ~5.5 V pack, below the empty
// clamp, so the gauge always read 0%.
//
// The power_supply `status` field is gone as well. It is VBUS-derived and means
// nothing for a primary-cell pack: the pack is 3x AA lithium primaries, which
// read about 1.8 V per cell when fresh, and nothing ever charges them.

// The usable window for 3x lithium AA: about 1.1 V per cell at the regulators'
// practical cutoff, up to about 1.8 V per cell fresh. Lithium primaries hold a
// long 1.5 V per cell plateau, so this linear percent is a coarse gauge that sits
// mid-scale for most of the pack's life.
const bat_empty_mv: u64 = 3300;
const bat_full_mv: u64 = 5400;

pub const Battery = struct {
    /// Millivolts, or null when the channel is absent.
    millivolts: ?u32,
    /// 0..100, or null when unknown.
    percent: ?u8,
};

/// Linear percent over the pack window, clamped. This is public so the oled loop
/// can recompute percent from its smoothed millivolts. Deriving percent from the
/// raw voltage instead would let the two readouts disagree.
pub fn percentFromMv(mv: u64) u8 {
    const c = std.math.clamp(mv, bat_empty_mv, bat_full_mv);
    return @intCast((c - bat_empty_mv) * 100 / (bat_full_mv - bat_empty_mv));
}

/// Read the battery pack from the vbat iio-rescale channel. The fields are null
/// when the channel is missing, and the caller renders "--".
pub fn readBattery(io: std.Io) Battery {
    var dir_buf: [64]u8 = undefined;
    const dir = findIioDir(io, &dir_buf, "label", "vbat") orelse
        return .{ .millivolts = null, .percent = null };
    const volts = channelVolts(io, dir, 0, "in_voltage0_scale") orelse
        return .{ .millivolts = null, .percent = null };
    const mv: u64 = @intFromFloat(@max(volts, 0.0) * 1000.0);
    return .{ .millivolts = @intCast(mv), .percent = percentFromMv(mv) };
}

test "insertSorted keeps the buffer ascending as values arrive out of order" {
    var buf: [8]i64 = undefined;
    var count: usize = 0;
    for ([_]i64{ 5, 1, 9, 3, 7 }) |v| count = insertSorted(i64, &buf, count, v);
    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expectEqualSlices(i64, &[_]i64{ 1, 3, 5, 7, 9 }, buf[0..count]);
    try std.testing.expectEqual(@as(i64, 5), buf[count / 2]);
}

test "median rejects the lone spike the leaky SARADC produces" {
    // The failure mode is many settled ~320-count reads and one 640-count spike,
    // which is a VSEL read that jumped to about twice the true value. The median
    // must stay at the settled value; a mean would be pulled upward by it.
    var buf: [median_samples]i64 = undefined;
    var count: usize = 0;
    for (0..median_samples) |i| {
        const v: i64 = if (i == 3) 640 else 320;
        count = insertSorted(i64, &buf, count, v);
    }
    try std.testing.expectEqual(@as(i64, 320), buf[count / 2]);
}

test "percentFromMv clamps to the pack window and scales linearly between" {
    try std.testing.expectEqual(@as(u8, 0), percentFromMv(0));
    try std.testing.expectEqual(@as(u8, 0), percentFromMv(bat_empty_mv));
    try std.testing.expectEqual(@as(u8, 100), percentFromMv(bat_full_mv));
    try std.testing.expectEqual(@as(u8, 100), percentFromMv(9999));
    // The window midpoint must read 50%.
    try std.testing.expectEqual(@as(u8, 50), percentFromMv((bat_empty_mv + bat_full_mv) / 2));
}

test "readBattery reports null fields when the vbat channel is absent" {
    // The host build has no vbat iio-rescale device, so both fields must degrade
    // to null. This is the path a core without a battery takes.
    const b = readBattery(std.testing.io);
    try std.testing.expectEqual(@as(?u32, null), b.millivolts);
    try std.testing.expectEqual(@as(?u8, null), b.percent);
}

test "read reports null for a node that does not exist" {
    const absent = "/proc/nix-badge-absent";
    try std.testing.expectEqual(@as(?u64, null), read(u64, std.testing.io, absent));
    try std.testing.expectEqual(@as(?f64, null), read(f64, std.testing.io, absent));
}
