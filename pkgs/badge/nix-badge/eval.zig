//! eval: the evaluator-independent per-frame seam.
//!
//! Both evaluator backends, fix's Zig `expr` and the upstream Nix C API, compile a
//! pure-Nix content function ONCE and apply it per frame to a `scope` attrset. The
//! evaluation is the only step that differs between them. The frame's `bitmap`
//! comes back as a plain `[]const i64`, and the decode from those integers to
//! SSD1306 GDDRAM bytes or RGB pixels lives HERE and is shared, so a comparison
//! between the two backends measures the evaluator and not the decode.
const std = @import("std");
const ws2812 = @import("ws2812.zig");

pub const Rgb = ws2812.Rgb;

/// Which evaluator produced a frame. `--backend` selects it and fix is the
/// default. nix is available on aarch64 only (see nixeval.have_nix).
///
/// A screen reads this as `scope.backend`, the integer id in `Fields.backend_id`,
/// so it can name the active evaluator without interning a string every frame.
pub const BackendKind = enum(u8) { fix = 0, nix = 1 };

/// The options both evaluator backends accept at `open`.
pub const Opts = struct {
    /// The file-I/O backend. fix reads a screen's runtime `import` and `readFile`
    /// through it, and the fetch-less stub still refuses network fetchers. nix
    /// ignores it, because upstream Nix does its own filesystem access.
    io: std.Io,
    /// A NIX_PATH-style search path for `<name>` imports, such as
    /// "nixbadge=/etc/nixbadge", so content can import a library no matter where
    /// the screen file itself lives. null keeps the evaluator default. fix passes
    /// it to Engine.setNixPath and nix passes it to nix_state_create.
    nix_path: ?[]const u8 = null,
    /// The heap size in bytes at which the evaluator collects. null keeps the
    /// evaluator's automatic line.
    ///
    /// This matters on the memory-tight badge. fix's automatic line is half of
    /// MemTotal clamped to between 256 MB and 32 GB, so on a 351 MB board it
    /// clamps to the 256 MB FLOOR. The heap then grows into swap before it ever
    /// collects, which is the "it gets slow" symptom. An explicit budget makes fix
    /// collect at that size instead. nix ignores it, because Boehm has its own
    /// policy.
    gc_budget_bytes: ?u64 = null,
};

/// The per-frame inputs a content function reads through its `scope`. These are
/// evaluator-independent, and each backend turns them into its own attrset: fix
/// through `makeAttrs` and nix through a `BindingsBuilder`.
pub const Fields = struct {
    t_ms: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    battery_mv: u32 = 0,
    battery_pct: u8 = 0,
    on_usb: bool = false,
    load1: f64 = 0,
    cpu_pct: u8 = 0,
    mem_pct: u8 = 0,
    uptime_s: u32 = 0,
    brightness: u8 = 255,
    /// The playback frame counter, which only rises. Delta screens index by this
    /// and not by wall-clock time.
    frame_index: u64 = 0,
    /// The active evaluator as an integer, 0 for fix and 1 for nix, read as
    /// `scope.backend`. It is an integer and not a string, so neither backend has
    /// to intern a string into its value heap every frame. A screen maps it to a
    /// name through its own table.
    backend_id: u8 = @intFromEnum(BackendKind.fix),
    /// The last measured frame rate, from the loop's 3-second window, read as
    /// `scope.fps` so a screen can draw a live readout. It is 0 until the first
    /// window closes.
    fps: u32 = 0,
    /// Which core the boot-select strap picks, read as `scope.strap`: 0 unknown,
    /// 1 arm, 2 riscv. This lets a screen show the RUNNING architecture next to
    /// the one the NEXT boot selects.
    strap: u8 = 0,
    /// The VSEL system rail in millivolts, read as `scope.vselMv`. It is near 5000
    /// on USB or VBUS, and 0 when it cannot be read. The power screen shows this
    /// as the rail. It previously showed the battery under a "RAIL" label, which
    /// read between 4 and 5.5 V and looked wrong next to a 5 V rail.
    vsel_mv: u32 = 0,
    /// Boot identity for the bootinfo screen, read as `scope.nixosVersion` and
    /// `scope.kernelVersion`.
    ///
    /// fix is pure and calls neither uname nor readFile during evaluation, so the
    /// gather side reads both ONCE at startup. They are NUL-terminated, so the C
    /// API backend can hand them to nix_init_string without a copy. They are
    /// constant for one boot, so fix's interner reduces the per-frame intern to a
    /// hash lookup.
    nixos_version: [:0]const u8 = "",
    kernel_version: [:0]const u8 = "",
};

/// One frame after it has been applied and read out. `bitmap` is a plain integer
/// list that the backend forced out of its own value heap into a reused buffer,
/// which is what keeps the decode evaluator-independent.
pub const Frame = struct {
    bitmap: []const i64,
    next_ms: i64,
    delta: bool = false,
    n: u32 = 0,
    /// Packed (offset, byte) entries applied ON TOP of the decoded `bitmap`,
    /// whether that bitmap was a keyframe, a delta, or a full frame. The packing
    /// is the same as a delta. This lets a screen overwrite any framebuffer byte
    /// from Nix, for example to stamp a frame-rate readout over clean video.
    /// An `overlay_n` of 0 means there is no overlay and nothing happens.
    overlay: []const i64 = &.{},
    overlay_n: u32 = 0,
    /// The screen is skipped by the button cycle and is reachable only by a direct
    /// signal jump. This is probed once when the registry is built.
    hidden: bool = false,
    /// Do NOT advance frameIndex for the next render, which freezes the playback
    /// counter. `t` keeps moving, so a time-driven screen still animates.
    pause: bool = false,
    /// After this many milliseconds on this screen the loop returns to the screen
    /// it came from. 0 means it never returns on its own.
    auto_return_ms: u32 = 0,
};

/// The panel region a rendered frame touched, so the caller can flush the least
/// it has to. When `full` is set the whole panel is stale. Otherwise `changed[p]`
/// is a bitmap of the changed columns of page `p`, and a page is at most 128
/// columns wide.
pub const Dirty = struct {
    pub const max_pages = 8;
    full: bool = true,
    changed: [max_pages]u128 = @splat(0),
};

/// One decoded OLED frame: the clamped frame period, the dirty region, and the
/// auto-return request the loop acts on. An auto-return of 0 means none.
pub const OledFrame = struct { next_ms: u32, dirty: Dirty, auto_return_ms: u32 = 0 };

/// How many frames pass between reclaims of young garbage. Only fix uses this;
/// the Boehm-collected nix backend ignores it.
pub const collect_every: u64 = 64;

/// Decode a FULL frame into `out`: 4 page-major GDDRAM bytes per integer, in
/// little-endian order, with the tail zero-filled. The whole panel is stale after
/// this, so the result is always `full`.
pub fn decodeOled(bitmap: []const i64, out: []u8) Dirty {
    const words = out.len / 4;
    const n = @min(bitmap.len, words);
    for (bitmap[0..n], 0..) |v, i| {
        out[i * 4 + 0] = @intCast(v & 0xff);
        out[i * 4 + 1] = @intCast((v >> 8) & 0xff);
        out[i * 4 + 2] = @intCast((v >> 16) & 0xff);
        out[i * 4 + 3] = @intCast((v >> 24) & 0xff);
    }
    for (out[n * 4 ..]) |*b| b.* = 0;
    return .{ .full = true };
}

/// Apply `n` packed (offset, byte) entries from `packed_ints` into `out` and add
/// every touched column to `dirty`.
///
/// The packing holds two entries per integer, with the first in the high 18 bits,
/// and each entry is `offset * 256 + byte`. The delta decode and the overlay share
/// this: a delta starts from a fresh `Dirty` and an overlay adds to whatever the
/// main decode already marked.
///
/// The entry count and every offset come from Nix, so both are bounded here. An
/// entry past the end of `packed_ints` stops the loop and an offset past the end
/// of `out` is skipped.
pub fn applyOverlay(packed_ints: []const i64, n: u32, out: []u8, width: u32, dirty: *Dirty) void {
    if (width == 0) return;
    const entry_mask: i64 = 0x3ffff; // 2^18 - 1
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const int_idx = i / 2;
        // `n` claims more entries than the list actually holds.
        if (int_idx >= packed_ints.len) break;
        const v = packed_ints[int_idx];
        const e: i64 = if (i & 1 == 0) (v >> 18) & entry_mask else v & entry_mask;
        const offset: usize = @intCast(e >> 8);
        if (offset >= out.len) continue;
        out[offset] = @intCast(e & 0xff);
        const page = offset / width;
        const col = offset % width;
        if (page < Dirty.max_pages and col < 128)
            dirty.changed[page] |= @as(u128, 1) << @intCast(col);
    }
}

/// Decode a frame into the framebuffer `out`, which persists across frames.
///
/// A full frame replaces the whole buffer. A delta frame applies `frame.n` packed
/// change entries in place and marks the changed columns of each page, so the
/// caller can flush a part of the panel. This does NOT apply `frame.overlay`; the
/// caller stamps that on afterwards, so an overlay lands over full frames too.
pub fn decodeOledFrame(frame: Frame, out: []u8, width: u32) Dirty {
    if (!frame.delta) return decodeOled(frame.bitmap, out);
    var d: Dirty = .{ .full = false };
    applyOverlay(frame.bitmap, frame.n, out, width, &d);
    return d;
}

/// The default frame period, used when a screen asks for a period of zero or less.
pub const default_next_ms: u32 = 33; // about 30 frames per second

/// The longest frame period a screen may ask for. A larger value would leave the
/// loop unresponsive for that long.
pub const max_next_ms: u32 = 60_000;

/// Clamp the frame period a screen asked for into the range the loop accepts. The
/// value comes from Nix, so it is bounded on both sides.
pub fn clampNextMs(next_ms: i64) u32 {
    if (next_ms <= 0) return default_next_ms;
    return @intCast(@min(next_ms, @as(i64, max_next_ms)));
}

/// Decode an LED frame: one 0xRRGGBB per integer, scaled by brightness into `out`.
/// A short bitmap leaves the LEDs past its end dark rather than stale.
pub fn decodeLeds(bitmap: []const i64, brightness: u8, out: []Rgb) void {
    const n = @min(bitmap.len, out.len);
    for (bitmap[0..n], 0..) |v, i| {
        out[i] = .{
            .r = ws2812.scaleChannel(@intCast((v >> 16) & 0xff), brightness),
            .g = ws2812.scaleChannel(@intCast((v >> 8) & 0xff), brightness),
            .b = ws2812.scaleChannel(@intCast(v & 0xff), brightness),
        };
    }
    for (out[n..]) |*px| px.* = .{ .r = 0, .g = 0, .b = 0 };
}

// -------------------------------------------------------------------------- tests ---

test "decodeOled full frame: 4 page-bytes/int LE, zero tail" {
    var out: [8]u8 = undefined;
    const bm = [_]i64{ 0x04030201, 0x08070605 };
    const d = decodeOled(&bm, &out);
    try std.testing.expect(d.full);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &out);
}

test "decodeOled full frame: short bitmap zero-fills the tail" {
    var out = [_]u8{0xff} ** 8;
    const d = decodeOled(&.{0x04030201}, &out);
    try std.testing.expect(d.full);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 0, 0, 0, 0 }, &out);
}

test "decodeOledFrame delta: 2 entries/int, applies to persistent fb + marks columns" {
    var out = [_]u8{0} ** 8; // width=8 => 1 page of 8 columns
    const e0: i64 = 2 * 256 + 0xAB;
    const e1: i64 = 5 * 256 + 0xCD;
    const packed_int: i64 = e0 * 262144 + e1; // E0 in the high 18 bits
    const f = Frame{ .bitmap = &.{packed_int}, .next_ms = 16, .delta = true, .n = 2 };
    const d = decodeOledFrame(f, &out, 8);
    try std.testing.expect(!d.full);
    try std.testing.expectEqual(@as(u8, 0xAB), out[2]);
    try std.testing.expectEqual(@as(u8, 0xCD), out[5]);
    try std.testing.expect(d.changed[0] & (@as(u128, 1) << 2) != 0);
    try std.testing.expect(d.changed[0] & (@as(u128, 1) << 5) != 0);
    try std.testing.expect(d.changed[0] & (@as(u128, 1) << 3) == 0);
}

test "decodeOledFrame delta: odd n ignores the unused low half of the last int" {
    var out = [_]u8{0} ** 8;
    const e0: i64 = 7 * 256 + 0xEE;
    const packed_int: i64 = e0 * 262144; // E1 = 0 (unused)
    const f = Frame{ .bitmap = &.{packed_int}, .next_ms = 16, .delta = true, .n = 1 };
    const d = decodeOledFrame(f, &out, 8);
    // Only the single applied entry's column is marked dirty.
    try std.testing.expect(!d.full);
    try std.testing.expect(d.changed[0] & (@as(u128, 1) << 7) != 0);
    try std.testing.expect(d.changed[0] & (@as(u128, 1) << 0) == 0);
    try std.testing.expectEqual(@as(u8, 0xEE), out[7]);
    // E1 would decode to offset 0 byte 0; n=1 must NOT apply it (out[0] stays 0).
    try std.testing.expectEqual(@as(u8, 0), out[0]);
}

test "applyOverlay: stamps entries over a framebuffer + adds to existing dirty" {
    var out = [_]u8{0} ** 16; // width=8 => 2 pages
    // Pre-mark page 0 col 1 as already dirty (as a main delta would have).
    var d: Dirty = .{ .full = false };
    d.changed[0] |= @as(u128, 1) << 1;
    // Overlay: page 1 (offset 8+3=11) byte 0x77, and page 0 col 4 byte 0x22.
    const e0: i64 = 11 * 256 + 0x77;
    const e1: i64 = 4 * 256 + 0x22;
    const packed_int: i64 = e0 * 262144 + e1;
    applyOverlay(&.{packed_int}, 2, &out, 8, &d);
    try std.testing.expectEqual(@as(u8, 0x77), out[11]);
    try std.testing.expectEqual(@as(u8, 0x22), out[4]);
    // The pre-existing dirty bit survives, and both overlay columns are now marked.
    try std.testing.expect(d.changed[0] & (@as(u128, 1) << 1) != 0);
    try std.testing.expect(d.changed[0] & (@as(u128, 1) << 4) != 0);
    try std.testing.expect(d.changed[1] & (@as(u128, 1) << 3) != 0);
}

test "clampNextMs: floors non-positive to 33, caps at 60000" {
    try std.testing.expectEqual(default_next_ms, clampNextMs(0));
    try std.testing.expectEqual(default_next_ms, clampNextMs(-5));
    try std.testing.expectEqual(@as(u32, 16), clampNextMs(16));
    try std.testing.expectEqual(max_next_ms, clampNextMs(100_000));
}

test "decodeLeds: 0xRRGGBB per int, brightness-scaled, dark tail" {
    var out: [2]Rgb = undefined;
    decodeLeds(&.{0xFF8040}, 255, &out);
    try std.testing.expectEqual(ws2812.scaleChannel(0xFF, 255), out[0].r);
    try std.testing.expectEqual(ws2812.scaleChannel(0x80, 255), out[0].g);
    try std.testing.expectEqual(ws2812.scaleChannel(0x40, 255), out[0].b);
    try std.testing.expectEqual(@as(u8, 0), out[1].r);
    try std.testing.expectEqual(@as(u8, 0), out[1].g);
    try std.testing.expectEqual(@as(u8, 0), out[1].b);
}
