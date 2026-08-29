//! backend: the runtime-selectable evaluator seam.
//!
//! `Backend` is a union over the two per-frame evaluators -- `fixeval.FixBackend` (psyclyx
//! fix's `expr`) and `nixeval.NixBackend` (the upstream Nix C API) -- so a single `--backend
//! fix|nix` flag picks which one drives the OLED screens and LED patterns for an A/B on fps,
//! per-frame eval time, and RSS. Both expose the SAME surface (`open`/`applyFrame`/`collect`/
//! `deinit`/`count`/`name`), and both hand back a plain `eval.Frame`, so everything downstream
//! (the decode in eval.zig, the playback pacing here) is evaluator-independent.
//!
//! The per-screen PLAYBACK state -- delta frame_index pacing, the young-GC collect cadence,
//! the fault-drop -- lives HERE in the shared `ScreenSet` (OLED, N lambdas) / `Pattern` (LED,
//! one lambda) holders rather than in either backend, so it is written once and shared. This
//! file is NOT imported by eval.zig, so eval.zig stays dependency-free and host-testable via
//! `zig test eval.zig`; backend.zig compiles only in the full build (and `zig build test`).

const std = @import("std");
const eval = @import("eval.zig");
const fixeval = @import("fixeval.zig");
const nixeval = @import("nixeval.zig");
const ws2812 = @import("ws2812.zig");

const Rgb = ws2812.Rgb;

/// Which evaluator to open. Same values as `eval.BackendKind`.
pub const Kind = eval.BackendKind;

/// A per-frame evaluator: either fix or the upstream Nix C API. `open` picks by `Kind`,
/// falling back to fix (logged) when nix is requested but not linked (riscv / nixEval off).
pub const Backend = union(enum) {
    fix: fixeval.FixBackend,
    nix: nixeval.NixBackend,

    pub fn open(gpa: std.mem.Allocator, opts: eval.Opts, which: Kind, paths: []const []const u8) ?Backend {
        switch (which) {
            .nix => {
                if (nixeval.have_nix) {
                    if (nixeval.NixBackend.open(gpa, opts, paths)) |b| return .{ .nix = b };
                    std.log.warn("backend: nix requested but open failed; falling back to fix", .{});
                } else {
                    std.log.info("backend: nix requested but not built on this arch; using fix", .{});
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
};

/// The OLED screen set over a chosen backend: N compiled lambdas plus the shared playback
/// pacing. `play_idx` feeds `scope.frameIndex` so cumulative deltas are never skipped; it
/// resets to 0 when the active screen changes so re-entry starts on a keyframe (see
/// badapple-delta.md). Young Value garbage is swept every `eval.collect_every` frames
/// (a no-op on the Boehm-GC nix backend).
pub const ScreenSet = struct {
    be: Backend,
    frame: u64 = 0,
    play_idx: u64 = 0,
    active_ix: ?usize = null,
    logged_error: bool = false,

    pub fn open(gpa: std.mem.Allocator, opts: eval.Opts, which: Kind, paths: []const []const u8) ?ScreenSet {
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

    /// Apply screen `idx`, decode into the PERSISTENT framebuffer `out`, stamp any overlay
    /// on top, sweep on the collect cadence, and return the clamped nextMs + Dirty region.
    /// Logs ONCE on fault (the caller drops the screen).
    pub fn renderOled(self: *ScreenSet, idx: usize, fields: eval.Fields, out: []u8) !eval.OledFrame {
        return self.renderOledInner(idx, fields, out) catch |err| {
            if (!self.logged_error) {
                std.log.err("oled: eval screen '{s}' render failed: {s}; dropping it", .{ self.name(idx), @errorName(err) });
                self.logged_error = true;
            }
            return err;
        };
    }

    fn renderOledInner(self: *ScreenSet, idx: usize, fields: eval.Fields, out: []u8) !eval.OledFrame {
        // Screen switch -> restart playback at frame 0 (always a keyframe), so a delta
        // screen never applies a delta onto another screen's stale framebuffer.
        if (self.active_ix == null or self.active_ix.? != idx) {
            self.play_idx = 0;
            self.active_ix = idx;
        }
        var fr = fields;
        fr.frame_index = self.play_idx;
        const f = try self.be.applyFrame(idx, fr);
        var dirty = eval.decodeOledFrame(f, out, fr.width);
        // Overlay: Nix stamped arbitrary bytes (e.g. an fps HUD) on top of the frame.
        if (f.overlay_n > 0) eval.applyOverlay(f.overlay, f.overlay_n, out, fr.width, &dirty);
        self.frame +%= 1;
        if (self.frame % eval.collect_every == 0) self.be.collect();
        self.play_idx +%= 1;
        return .{ .next_ms = eval.clampNextMs(f.next_ms), .dirty = dirty };
    }
};

/// The LED ring painter over a chosen backend: one compiled lambda applied per frame and
/// decoded to brightness-scaled RGB. Same collect cadence + fault-drop as ScreenSet.
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

    /// Evaluate one LED frame: apply the lambda, decode `{ bitmap; nextMs }` into `out`
    /// (brightness-scaled), return the clamped nextMs. Logs ONCE on fault.
    pub fn render(self: *Pattern, fields: eval.Fields, out: []Rgb) !u32 {
        return self.renderInner(fields, out) catch |err| {
            if (!self.logged_error) {
                std.log.err("bling: eval render failed: {s}; falling back to computed", .{@errorName(err)});
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

const linux = @import("linux.zig");

fn tmpDir(buf: []u8) ![:0]const u8 {
    const dir = try std.fmt.bufPrintZ(buf, "/tmp/nbbe-{d}", .{linux.monotonicMsec()});
    switch (linux.mkdir(dir.ptr, 0o755)) {
        .created, .exists, .failed => {},
    }
    return dir;
}

fn writeScreen(buf: []u8, dir: []const u8, name: []const u8, data: []const u8) ![]const u8 {
    const path = try std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, name });
    try linux.writeFile(path.ptr, data);
    return path;
}

test "ScreenSet.renderOled paces delta playback via frameIndex and resets on screen switch" {
    if (comptime !fixeval.have_fix) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var dbuf: [256]u8 = undefined;
    const dir = try tmpDir(&dbuf);
    var abuf: [512]u8 = undefined;
    var bbuf: [512]u8 = undefined;
    // Screen A echoes its own frameIndex through bitmap[0]; screen B is constant.
    const a = try writeScreen(&abuf, dir, "a.nix", "scope: { bitmap = [ scope.frameIndex ]; nextMs = 10; }");
    const b = try writeScreen(&bbuf, dir, "b.nix", "scope: { bitmap = [ 9 ]; nextMs = 20; }");

    var set = ScreenSet.open(gpa, .{ .io = std.testing.io }, .fix, &.{ a, b }) orelse return error.OpenFailed;
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

    var dbuf: [256]u8 = undefined;
    const dir = try tmpDir(&dbuf);
    var abuf: [512]u8 = undefined;
    // Full frame writes byte 1,2,3,4 to fb[0..4]; overlay overwrites fb[1] with 0xEE.
    // overlay entry E = offset*256 + byte = 1*256 + 0xEE = 494, packed alone in the high half.
    const src = "scope: { bitmap = [ 67305985 ]; nextMs = 33; overlay = [ 129499136 ]; overlayN = 1; }";
    const s = try writeScreen(&abuf, dir, "ov.nix", src);

    var set = ScreenSet.open(gpa, .{ .io = std.testing.io }, .fix, &.{s}) orelse return error.OpenFailed;
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

    var dbuf: [256]u8 = undefined;
    const dir = try tmpDir(&dbuf);
    var abuf: [512]u8 = undefined;
    const p = try writeScreen(&abuf, dir, "led.nix", "scope: { bitmap = [ 16711680 65280 ]; nextMs = 40; }");

    var pat = Pattern.open(gpa, .{ .io = std.testing.io }, .fix, p) orelse return error.OpenFailed;
    defer pat.deinit();
    var px: [2]Rgb = undefined;
    const next = try pat.render(.{ .brightness = 255 }, &px);
    try std.testing.expectEqual(@as(u32, 40), next);
    try std.testing.expectEqual(@as(u8, 0xff), px[0].r); // 0xFF0000 -> red
    try std.testing.expectEqual(@as(u8, 0xff), px[1].g); // 0x00FF00 -> green
}
