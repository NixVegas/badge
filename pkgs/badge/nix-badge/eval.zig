//! eval: the backend-agnostic per-frame evaluator seam.
//!
//! Both evaluator backends (fix's Zig `expr`, and the upstream Nix C API) compile a
//! pure-Nix content function ONCE and apply it per frame to a `scope` attrset. The ONLY
//! thing that differs between them is the eval itself; the frame's `bitmap` is handed
//! back as a plain `[]const i64`, and the decode from ints -> SSD1306 GDDRAM bytes / RGB
//! pixels lives HERE, shared, so an A/B comparison measures the evaluator and not the
//! decode. See docs/superpowers/specs/2026-08-29-nix-c-api-backend-design.md.
const std = @import("std");
const ws2812 = @import("ws2812.zig");

pub const Rgb = ws2812.Rgb;

/// Which evaluator produced a frame. Selected by `--backend` (default fix); nix is
/// aarch64-only (see nixeval.have_nix). A screen sees this as `scope.backend` (an int
/// id, `backend_id` below) so it can label the active evaluator without string interning.
pub const BackendKind = enum(u8) { fix = 0, nix = 1 };

/// The per-frame inputs fed to a content function's `scope`. Backend-agnostic; the
/// backend turns these into its own attrset (fix `makeAttrs`, nix `BindingsBuilder`).
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
    /// Monotonic playback frame counter (delta screens index by this, not wall-clock).
    frame_index: u64 = 0,
    /// Active evaluator, as an int (0 fix / 1 nix), fed to `scope.backend`. An int (not a
    /// string) so neither backend has to intern a string into its value heap each frame;
    /// a screen maps it to a name via its own inlined table (see badapple-live.nix).
    backend_id: u8 = @intFromEnum(BackendKind.fix),
    /// Last measured effective frames/sec (the loop's 3 s window), fed to `scope.fps` so a
    /// screen can draw a live HUD. 0 until the first window closes.
    fps: u32 = 0,
};

/// One applied+extracted frame. `bitmap` is a plain int list the backend forced out of
/// its own value heap into a reused buffer, so the decode is evaluator-independent.
///
/// `overlay` (+ `overlay_n`) is an OPTIONAL, backward-compatible extension: packed exactly
/// like a delta (2 entries/int, `E = offset*256+byte`, high 18 bits first), it is applied
/// ON TOP of the decoded `bitmap` (keyframe, delta, OR full frame), letting a screen
/// overwrite arbitrary framebuffer bytes from Nix -- e.g. stamp a `[backend] fps` HUD over
/// clean Bad Apple. Absent (`overlay_n == 0`) -> no-op.
pub const Frame = struct {
    bitmap: []const i64,
    next_ms: i64,
    delta: bool = false,
    n: u32 = 0,
    overlay: []const i64 = &.{},
    overlay_n: u32 = 0,
};

/// The panel region a rendered frame touched, so the caller flushes minimally. `full` ->
/// whole panel; else `changed[p]` is a bitmap of the changed columns of page `p` (<=128).
pub const Dirty = struct {
    pub const max_pages = 8;
    full: bool = true,
    changed: [max_pages]u128 = .{0} ** max_pages,
};

/// One decoded OLED frame: the clamped period plus the dirty region.
pub const OledFrame = struct { next_ms: u32, dirty: Dirty };

/// Reclaim young garbage every this many frames (fix); nix (Boehm) ignores it.
pub const collect_every: u64 = 64;

/// Decode a FULL frame: 4 page-major GDDRAM bytes per int, little-endian, into `out`
/// (zero-filling the tail). Returns `Dirty.full`. `width` is unused for a full frame.
pub fn decodeOled(bitmap: []const i64, out: []u8, width: u32) Dirty {
    _ = width;
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

/// Apply `n` packed (offset,byte) entries from `packed_ints` (2 per int, first in the high
/// 18 bits, `E = offset*256+byte`) into `out`, OR-ing each touched column into `dirty`.
/// Shared by the delta decode and the overlay: a delta starts from a fresh `Dirty`, an
/// overlay adds to whatever the main decode already marked.
pub fn applyOverlay(packed_ints: []const i64, n: u32, out: []u8, width: u32, dirty: *Dirty) void {
    if (width == 0) return;
    const entry_mask: i64 = 0x3ffff; // 2^18 - 1
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const int_idx = i / 2;
        if (int_idx >= packed_ints.len) break; // malformed: n claims more ints than emitted
        const v = packed_ints[int_idx];
        const e: i64 = if (i & 1 == 0) (v >> 18) & entry_mask else v & entry_mask;
        const offset: usize = @intCast(e >> 8);
        if (offset >= out.len) continue; // defensive
        out[offset] = @intCast(e & 0xff);
        const page = offset / width;
        const col = offset % width;
        if (page < Dirty.max_pages and col < 128) dirty.changed[page] |= @as(u128, 1) << @intCast(col);
    }
}

/// Decode a frame into the PERSISTENT framebuffer `out`, dispatching on `frame.delta`.
/// Delta: `frame.n` packed (offset,byte) change entries via `applyOverlay`. Marks the
/// changed columns per page for a partial flush. Does NOT apply `frame.overlay` -- the
/// caller stamps that on top afterward (so it lands over full frames too).
pub fn decodeOledFrame(frame: Frame, out: []u8, width: u32) Dirty {
    if (!frame.delta) return decodeOled(frame.bitmap, out, width);
    var d: Dirty = .{ .full = false };
    applyOverlay(frame.bitmap, frame.n, out, width, &d);
    return d;
}

/// Clamp a raw `nextMs` hint to a sane frame period: a non-positive value becomes 33 ms
/// (~30 fps default) and the max is 60 s so a screen cannot wedge the loop.
pub fn clampNextMs(next_ms: i64) u32 {
    return if (next_ms <= 0) 33 else @intCast(@min(next_ms, @as(i64, 60_000)));
}

/// Decode an LED frame: one 0xRRGGBB per int, brightness-scaled into `out`; a short
/// bitmap leaves the tail LEDs dark rather than stale.
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
    const d = decodeOled(&bm, &out, 8);
    try std.testing.expect(d.full);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &out);
}

test "decodeOled full frame: short bitmap zero-fills the tail" {
    var out = [_]u8{0xff} ** 8;
    const d = decodeOled(&.{0x04030201}, &out, 8);
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
    _ = decodeOledFrame(f, &out, 8);
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
    try std.testing.expectEqual(@as(u32, 33), clampNextMs(0));
    try std.testing.expectEqual(@as(u32, 33), clampNextMs(-5));
    try std.testing.expectEqual(@as(u32, 16), clampNextMs(16));
    try std.testing.expectEqual(@as(u32, 60_000), clampNextMs(100_000));
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
