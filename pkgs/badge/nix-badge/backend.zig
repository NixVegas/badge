//! backend: the evaluator seam the runtime selects between.
//!
//! `Backend` is a union over the two per-frame evaluators, `fixeval.FixBackend`
//! and `nixeval.NixBackend`, so one `--backend fix|nix` flag picks which drives
//! the OLED screens and the LED patterns. That makes the two comparable on frame
//! rate, per-frame evaluation time, and memory. Both expose the same surface and
//! both return a plain `eval.Frame`, so everything downstream of them, the decode
//! in eval.zig and the playback pacing here, is evaluator-independent.
//!
//! The per-screen playback state lives HERE, in the shared `ScreenSet` for the
//! OLED and `Pattern` for the LED ring, rather than in either backend: the
//! frame-index pacing for delta screens, the collection cadence, and dropping a
//! screen that faults. That way it is written once.
//!
//! eval.zig does not import this file, so eval.zig stays free of dependencies and
//! can be tested on its own.

const std = @import("std");
const eval = @import("eval.zig");
const fixeval = @import("fixeval.zig");
const nixeval = @import("nixeval.zig");
const ws2812 = @import("ws2812.zig");

const Rgb = ws2812.Rgb;

/// Which evaluator to open. The same values as `eval.BackendKind`.
///
/// The render methods below keep an inferred error set on purpose. They are a
/// dispatch shim over two evaluators whose own error sets differ, and fix's set
/// comes from its Engine rather than from this codebase. Every caller recovers the
/// same way, by dropping the screen, so none of them selects on the error value.
pub const Kind = eval.BackendKind;

/// A per-frame evaluator: either fix or the upstream Nix C API. `open` picks by `Kind`,
/// falling back to fix (logged) when nix is requested but not linked (riscv / nixEval off).
pub const Backend = union(enum) {
    fix: fixeval.FixBackend,
    nix: nixeval.NixBackend,

    pub fn open(
        gpa: std.mem.Allocator,
        opts: eval.Opts,
        which: Kind,
        paths: []const []const u8,
    ) ?Backend {
        switch (which) {
            .nix => {
                if (nixeval.have_nix) {
                    if (nixeval.NixBackend.open(gpa, opts, paths)) |b| return .{ .nix = b };
                    std.log.warn("backend: nix could not be opened; using fix", .{});
                } else {
                    std.log.info("backend: nix is not built on this arch; using fix", .{});
                }
                if (fixeval.FixBackend.open(gpa, opts, paths)) |b| return .{ .fix = b };
                return null;
            },
            .fix => {
                if (fixeval.FixBackend.open(gpa, opts, paths)) |b| return .{ .fix = b };
                return null;
            },
        }
    }

    pub fn applyFrame(self: *Backend, idx: usize, fields: eval.Fields) !eval.Frame {
        switch (self.*) {
            inline else => |*b| return b.applyFrame(idx, fields),
        }
    }

    pub fn collect(self: *Backend) void {
        switch (self.*) {
            inline else => |*b| b.collect(),
        }
    }

    pub fn deinit(self: *Backend) void {
        switch (self.*) {
            inline else => |*b| b.deinit(),
        }
    }

    pub fn count(self: *const Backend) usize {
        switch (self.*) {
            inline else => |*b| return b.count(),
        }
    }

    pub fn name(self: *const Backend, idx: usize) []const u8 {
        switch (self.*) {
            inline else => |*b| return b.name(idx),
        }
    }

    pub fn kind(self: *const Backend) Kind {
        return switch (self.*) {
            .fix => .fix,
            .nix => .nix,
        };
    }

    /// Read and clear the time spent collecting since the last call. Only fix
    /// collects, so the nix arm always reports zero.
    pub fn takeCollectNs(self: *Backend) i128 {
        return switch (self.*) {
            .fix => |*b| b.takeCollectNs(),
            .nix => 0,
        };
    }
};

/// The OLED screen set over a chosen backend: N compiled lambdas plus the shared
/// playback state.
///
/// `play_idx` feeds `scope.frameIndex`, so a screen that emits cumulative deltas
/// never has one skipped. It resets to 0 when the active screen changes, so
/// returning to a screen starts on a keyframe rather than applying a delta onto
/// another screen's stale framebuffer. Young garbage is swept every
/// `eval.collect_every` frames, which the nix backend ignores.
pub const ScreenSet = struct {
    be: Backend,
    frame: u64 = 0,
    play_idx: u64 = 0,
    active_ix: ?usize = null,
    logged_error: bool = false,

    pub fn open(
        gpa: std.mem.Allocator,
        opts: eval.Opts,
        which: Kind,
        paths: []const []const u8,
    ) ?ScreenSet {
        const be = Backend.open(gpa, opts, which, paths) orelse return null;
        return .{ .be = be };
    }

    pub fn deinit(self: *ScreenSet) void {
        self.be.deinit();
    }

    pub fn count(self: *const ScreenSet) usize {
        return self.be.count();
    }

    pub fn name(self: *const ScreenSet, idx: usize) []const u8 {
        return self.be.name(idx);
    }

    pub fn kind(self: *const ScreenSet) Kind {
        return self.be.kind();
    }

    /// Read and clear the time spent collecting since the last call.
    pub fn takeCollectNs(self: *ScreenSet) i128 {
        return self.be.takeCollectNs();
    }

    /// Apply screen `idx`, decode into the framebuffer `out`, which persists across
    /// frames, stamp any overlay on top, sweep on the collection cadence, and
    /// return the clamped frame period and the dirty region.
    ///
    /// A fault is logged ONCE, because the caller then drops the screen and a
    /// per-frame log line would fill the journal.
    pub fn renderOled(
        self: *ScreenSet,
        idx: usize,
        fields: eval.Fields,
        out: []u8,
    ) !eval.OledFrame {
        return self.renderOledInner(idx, fields, out) catch |err| {
            if (!self.logged_error) {
                std.log.err("oled: eval screen '{s}' failed to render ({t}); dropping it", .{
                    self.name(idx), err,
                });
                self.logged_error = true;
            }
            return err;
        };
    }

    fn renderOledInner(
        self: *ScreenSet,
        idx: usize,
        fields: eval.Fields,
        out: []u8,
    ) !eval.OledFrame {
        // A screen change restarts playback at frame 0, which is always a keyframe.
        if (self.active_ix == null or self.active_ix.? != idx) {
            self.play_idx = 0;
            self.active_ix = idx;
        }
        var fr = fields;
        fr.frame_index = self.play_idx;
        const f = try self.be.applyFrame(idx, fr);
        var dirty = eval.decodeOledFrame(f, out, fr.width);
        if (f.overlay_n > 0) eval.applyOverlay(f.overlay, f.overlay_n, out, fr.width, &dirty);
        self.frame +%= 1;
        if (self.frame % eval.collect_every == 0) self.be.collect();
        // `pause` freezes the playback counter. The screen keeps rendering with a
        // moving `t`, but frameIndex stands still.
        if (!f.pause) self.play_idx +%= 1;
        return .{
            .next_ms = eval.clampNextMs(f.next_ms),
            .dirty = dirty,
            .auto_return_ms = f.auto_return_ms,
        };
    }

    /// Read a screen's `hidden` flag by applying it ONCE at frame 0, which also
    /// warms its first frame. The registry uses this so the button cycle can skip
    /// a hidden screen before it ever shows one. A fault here reports NOT hidden,
    /// because the render path handles and drops a faulting screen itself.
    pub fn probeHidden(self: *ScreenSet, idx: usize, fields: eval.Fields) bool {
        var fr = fields;
        fr.frame_index = 0;
        const f = self.be.applyFrame(idx, fr) catch return false;
        return f.hidden;
    }
};

/// The LED ring painter over a chosen backend: one compiled lambda applied every
/// frame and decoded to RGB scaled by brightness. It uses the same collection
/// cadence and the same drop-on-fault behaviour as `ScreenSet`.
pub const Pattern = struct {
    be: Backend,
    frame: u64 = 0,
    logged_error: bool = false,

    pub fn open(gpa: std.mem.Allocator, opts: eval.Opts, which: Kind, path: []const u8) ?Pattern {
        const be = Backend.open(gpa, opts, which, &.{path}) orelse return null;
        return .{ .be = be };
    }

    pub fn deinit(self: *Pattern) void {
        self.be.deinit();
    }

    pub fn kind(self: *const Pattern) Kind {
        return self.be.kind();
    }

    /// Evaluate one LED frame: apply the lambda, decode its bitmap into `out`
    /// scaled by brightness, and return the clamped frame period. A fault is
    /// logged ONCE, because the caller then falls back to another pixel source.
    pub fn render(self: *Pattern, fields: eval.Fields, out: []Rgb) !u32 {
        return self.renderInner(fields, out) catch |err| {
            if (!self.logged_error) {
                std.log.err("bling: the eval pattern failed to render ({t}); falling back", .{err});
                self.logged_error = true;
            }
            return err;
        };
    }

    fn renderInner(self: *Pattern, fields: eval.Fields, out: []Rgb) !u32 {
        const f = try self.be.applyFrame(0, fields);
        eval.decodeLeds(f.bitmap, fields.brightness, out);
        self.frame +%= 1;
        if (self.frame % eval.collect_every == 0) self.be.collect();
        return eval.clampNextMs(f.next_ms);
    }
};

// ------------------------------------------------------------------------- tests ---
// These exercise the shared holders through whichever backend is linked in the host test
// build (fix, since have_nix is false there). They prove the playback pacing + fault-drop
// live in the holder, independent of the backend.

// A throwaway directory of screen files, removed when the test ends. The holders
// load screens by path, so the tests need real files on disk.
const TmpScreens = struct {
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = @splat(0),
    root_len: usize = 0,

    fn init() !TmpScreens {
        var self: TmpScreens = .{ .tmp = std.testing.tmpDir(.{}) };
        self.root_len = try self.tmp.dir.realPath(std.testing.io, &self.root_buf);
        return self;
    }

    fn deinit(self: *TmpScreens) void {
        self.tmp.cleanup();
    }

    fn write(self: *TmpScreens, buf: []u8, name: []const u8, data: []const u8) ![]const u8 {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = data });
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.root_buf[0..self.root_len], name });
    }
};

test "ScreenSet.renderOled paces delta playback via frameIndex and resets on screen switch" {
    if (comptime !fixeval.have_fix) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var screens_dir = try TmpScreens.init();
    defer screens_dir.deinit();
    var abuf: [512]u8 = undefined;
    var bbuf: [512]u8 = undefined;
    // Screen A echoes its own frameIndex through bitmap[0]; screen B is constant.
    const a_src = "scope: { bitmap = [ scope.frameIndex ]; nextMs = 10; }";
    const a = try screens_dir.write(&abuf, "a.nix", a_src);
    const b = try screens_dir.write(&bbuf, "b.nix", "scope: { bitmap = [ 9 ]; nextMs = 20; }");

    var set = ScreenSet.open(gpa, .{ .io = std.testing.io }, .fix, &.{ a, b }) orelse
        return error.OpenFailed;
    defer set.deinit();
    try std.testing.expectEqual(@as(usize, 2), set.count());
    try std.testing.expectEqual(Kind.fix, set.kind());

    var fb: [512]u8 = @splat(0);
    // Frame 0 of screen A: frameIndex 0.
    _ = try set.renderOled(0, .{ .width = 128, .height = 32 }, &fb);
    try std.testing.expectEqual(@as(u8, 0), fb[0]);
    // Frame 1 of screen A: frameIndex 1 -> bitmap[0] = 1 -> LE byte 0 is 1.
    _ = try set.renderOled(0, .{ .width = 128, .height = 32 }, &fb);
    try std.testing.expectEqual(@as(u8, 1), fb[0]);
    // Switch to B, then back to A: A's play_idx must reset to 0.
    _ = try set.renderOled(1, .{ .width = 128, .height = 32 }, &fb);
    _ = try set.renderOled(0, .{ .width = 128, .height = 32 }, &fb);
    try std.testing.expectEqual(@as(u8, 0), fb[0]);
}

test "ScreenSet applies an overlay on top of the decoded frame" {
    if (comptime !fixeval.have_fix) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var screens_dir = try TmpScreens.init();
    defer screens_dir.deinit();
    var abuf: [512]u8 = undefined;
    // Full frame writes byte 1,2,3,4 to fb[0..4]; overlay overwrites fb[1] with 0xEE.
    // overlay entry E = offset*256 + byte = 1*256 + 0xEE = 494, packed alone in the high half.
    const src =
        "scope: { bitmap = [ 67305985 ]; nextMs = 33; overlay = [ 129499136 ]; overlayN = 1; }";
    const s = try screens_dir.write(&abuf, "ov.nix", src);

    var set = ScreenSet.open(gpa, .{ .io = std.testing.io }, .fix, &.{s}) orelse
        return error.OpenFailed;
    defer set.deinit();
    var fb: [512]u8 = @splat(0);
    _ = try set.renderOled(0, .{ .width = 128, .height = 32 }, &fb);
    try std.testing.expectEqual(@as(u8, 1), fb[0]);
    try std.testing.expectEqual(@as(u8, 0xEE), fb[1]); // overlay won over the main decode's 2
    try std.testing.expectEqual(@as(u8, 3), fb[2]);
}

test "Pattern.render decodes an LED frame and reports nextMs" {
    if (comptime !fixeval.have_fix) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var screens_dir = try TmpScreens.init();
    defer screens_dir.deinit();
    var abuf: [512]u8 = undefined;
    const led_src = "scope: { bitmap = [ 16711680 65280 ]; nextMs = 40; }";
    const p = try screens_dir.write(&abuf, "led.nix", led_src);

    var pat = Pattern.open(gpa, .{ .io = std.testing.io }, .fix, p) orelse return error.OpenFailed;
    defer pat.deinit();
    var px: [2]Rgb = undefined;
    const next = try pat.render(.{ .brightness = 255 }, &px);
    try std.testing.expectEqual(@as(u32, 40), next);
    try std.testing.expectEqual(@as(u8, 0xff), px[0].r); // 0xFF0000 -> red
    try std.testing.expectEqual(@as(u8, 0xff), px[1].g); // 0x00FF00 -> green
}
