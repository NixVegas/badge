//! fixeval: the FIX evaluator backend (psyclyx/fix's fetch-less `expr`, aarch64 only;
//! the riscv core builds eval-less and uses the computed/blob paths).
//!
//! Per-frame content eval. A pattern/screen is a pure Nix function
//!     scope: { bitmap = [ <int> ... ]; nextMs = <int>; }
//! where `bitmap` is a flat list of small packed ints (LED: one 0xRRGGBB per pixel)
//! and `nextMs` is how long until the next call. The function is compiled ONCE to a
//! lambda (`Pattern.open`/`ScreenSet.open`), then applied every frame to a freshly-built
//! `scope` attrset via the native `Engine.applyValue`/`Engine.makeAttrs` patch -- NO
//! source recompile, so fix mints no new chunk per frame. `applyFrame` forces the result
//! `bitmap` list out of fix's Value heap into a plain `[]i64`; the DECODE from ints ->
//! GDDRAM bytes / RGB lives in `eval.zig`, shared with the nix backend, so an A/B measures
//! the evaluator, not the decode. The Value-heap garbage is reclaimed by a young-gated
//! `collectNow()` on a cadence.
//!
//! Whether eval is compiled in is a build-time decision (`build_options.have_fix`, set
//! from `-Dfix-src`). Without it every method is a no-op / null so the eval-less (riscv)
//! build keeps working on the computed patterns.

const std = @import("std");
const build_options = @import("build_options");
const linux = @import("linux.zig");
const ws2812 = @import("ws2812.zig");
const eval = @import("eval.zig");

const Rgb = ws2812.Rgb;

/// True when `-Dfix-src` supplied a fix source and `expr` was linked in.
pub const have_fix = build_options.have_fix;

// `expr`/`runtime` only exist in the build graph when have_fix; alias to void
// otherwise so the gated methods still type-check on an eval-less build.
const expr = if (have_fix) @import("expr") else struct {};
const Engine = if (have_fix) expr.Engine else void;
const Value = if (have_fix) @import("runtime").value.Value else void;

/// Largest pattern source we read. A live LED pattern is ~1 KiB, but a baked frame-list
/// (Bad Apple: ~6 MiB for the full song) is the outlier -- size for that. The scratch
/// buffer is transient (freed after the source is duped), so this only caps a one-shot
/// allocation at open.
pub const max_pattern_bytes = 8 * 1024 * 1024;

/// Diagnostic: total nanoseconds spent in `collectNow` since the loop last read+reset it
/// (via `takeCollectNs`). Lets the render loop split the per-frame eval cost into
/// "apply+decode" vs "GC collect" without threading a timer through every call.
pub var collect_ns_accum: i128 = 0;

/// Read and zero the accumulated collect time.
pub fn takeCollectNs() i128 {
    const v = collect_ns_accum;
    collect_ns_accum = 0;
    return v;
}

/// Grow `ints.*` to at least `need` i64s (via the owning allocator). A separate first
/// alloc from the `&.{}` default avoids reallocating a non-owned empty slice.
fn ensureInts(gpa: std.mem.Allocator, ints: *[]i64, need: usize) !void {
    if (ints.len >= need) return;
    ints.* = if (ints.len == 0) try gpa.alloc(i64, need) else try gpa.realloc(ints.*, need);
}

/// Build the per-frame `scope` natively, apply the pre-compiled `lambda`, and force the
/// result's `bitmap` list into `ints` (grown as needed) as plain i64. Returns a
/// backend-agnostic `eval.Frame`. Mints NO new chunk. This is the ONLY place fix `Value`s
/// are read out to ints; keyed by `(ev, lambda)`, not `self`, so one Engine drives many.
fn applyFrame(ev: *Engine, lambda: Value, fields: eval.Fields, ints: *[]i64, gpa: std.mem.Allocator) !eval.Frame {
    const scope = try ev.makeAttrs(&.{
        .{ .name = "t", .value = Value.int(@intCast(fields.t_ms)) },
        .{ .name = "frameIndex", .value = Value.int(@intCast(fields.frame_index)) },
        .{ .name = "width", .value = Value.int(fields.width) },
        .{ .name = "height", .value = Value.int(fields.height) },
        .{ .name = "batteryMv", .value = Value.int(fields.battery_mv) },
        .{ .name = "batteryPct", .value = Value.int(fields.battery_pct) },
        .{ .name = "onUsb", .value = Value.boolVal(fields.on_usb) },
        .{ .name = "load1", .value = Value.float(fields.load1) },
        .{ .name = "cpuPct", .value = Value.int(fields.cpu_pct) },
        .{ .name = "memPct", .value = Value.int(fields.mem_pct) },
        .{ .name = "uptimeS", .value = Value.int(fields.uptime_s) },
    });

    const result = try ev.applyValue(lambda, scope);
    if (result.kind() != .attrs) return error.PatternNotAttrs;

    const bitmap = try ev.forceValue((try ev.getAttr(result, "bitmap")) orelse return error.MissingBitmap);
    const next = try ev.forceValue((try ev.getAttr(result, "nextMs")) orelse return error.MissingNextMs);
    if (bitmap.kind() != .list) return error.BitmapNotList;

    // Optional delta contract. Absent -> full frame (info screens, LED patterns).
    var is_delta = false;
    var n_changes: u32 = 0;
    if (try ev.getAttr(result, "delta")) |d| is_delta = (try ev.forceValue(d)).asBool();
    if (is_delta) {
        if (try ev.getAttr(result, "n")) |nv| {
            const raw = (try ev.forceValue(nv)).asInt();
            if (raw > 0) n_changes = @intCast(@min(raw, @as(i64, std.math.maxInt(u32))));
        }
    }

    const pix = try ev.heapListOf(bitmap.asObjectId());
    try ensureInts(gpa, ints, pix.len);
    for (pix, 0..) |p, i| ints.*[i] = (try ev.forceValue(p)).asInt();
    return .{ .bitmap = ints.*[0..pix.len], .next_ms = next.asInt(), .delta = is_delta, .n = n_changes };
}

/// Advance the frame counter and collect young Value garbage on the cadence (the scope,
/// result attrset, and bitmap list of THIS frame), clamping the raw nextMs. MUST be called
/// only AFTER the caller has finished reading the bitmap ints out (they are extracted into
/// the `[]i64` in `applyFrame`, so the sweep is safe here).
fn finishFrame(ev: *Engine, frame: *u64, next_ms: i64) u32 {
    frame.* +%= 1;
    if (frame.* % eval.collect_every == 0) {
        const c0 = linux.monotonicNsec();
        _ = ev.collectNow();
        collect_ns_accum += linux.monotonicNsec() - c0;
    }
    return if (next_ms <= 0) 33 else @intCast(@min(next_ms, @as(i64, 60_000)));
}

/// A compiled-once Nix content function plus the fix Engine that owns it. Used for the LED
/// ring (one pattern per painter). The OLED uses `ScreenSet` (N lambdas, one Engine). Both
/// share `applyFrame`/`finishFrame` and the `eval.decode*` helpers.
pub const Pattern = struct {
    gpa: std.mem.Allocator,
    ev: Engine,
    // The pattern source, kept alive because compiled chunks reference it for error spans.
    text: []u8,
    lambda: Value,
    frame: u64 = 0,
    logged_error: bool = false,
    // Reused bitmap-int buffer (grown on first render); freed in deinit.
    ints: []i64 = &.{},

    /// Read the pattern at `path`, stand up a single-threaded Engine, and compile it to a
    /// lambda ONCE. Returns null (logged) on any failure or when eval is unavailable.
    pub fn open(gpa: std.mem.Allocator, path: []const u8) ?Pattern {
        if (comptime !have_fix) {
            std.log.info("bling: eval pattern requested but unavailable on this arch", .{});
            return null;
        }
        const text = readPattern(gpa, path) orelse {
            std.log.err("bling: cannot read eval pattern {s}", .{path});
            return null;
        };
        var ev = Engine.init(gpa, .{ .worker_count = 0, .compile_cache = .off }) catch |err| {
            std.log.err("bling: eval engine init failed: {s}", .{@errorName(err)});
            gpa.free(text);
            return null;
        };
        const lambda = ev.evaluate(text) catch |err| {
            std.log.err("bling: eval pattern {s} did not compile: {s}", .{ path, @errorName(err) });
            ev.deinit();
            gpa.free(text);
            return null;
        };
        if (!lambda.isNixClosure()) {
            std.log.err("bling: eval pattern {s} is not a function", .{path});
            ev.deinit();
            gpa.free(text);
            return null;
        }
        ev.gcSetExternalRoots(&.{lambda}) catch |err| {
            std.log.err("bling: eval root pin failed: {s}", .{@errorName(err)});
            ev.deinit();
            gpa.free(text);
            return null;
        };
        std.log.info("bling: eval pattern {s} ({d} bytes) compiled once", .{ path, text.len });
        return .{ .gpa = gpa, .ev = ev, .text = text, .lambda = lambda };
    }

    pub fn deinit(self: *Pattern) void {
        if (comptime !have_fix) return;
        if (self.ints.len > 0) self.gpa.free(self.ints);
        self.ev.deinit();
        self.gpa.free(self.text);
    }

    /// Evaluate one LED frame: apply the compiled lambda, decode `{ bitmap; nextMs }` into
    /// `out` (brightness-scaled), return the clamped nextMs. Logs ONCE on fault.
    pub fn render(self: *Pattern, fields: eval.Fields, out: []Rgb) !u32 {
        if (comptime !have_fix) return error.EvalUnavailable;
        return self.renderInner(fields, out) catch |err| {
            if (!self.logged_error) {
                std.log.err("bling: eval render failed: {s}; falling back to computed", .{@errorName(err)});
                self.logged_error = true;
            }
            return err;
        };
    }

    fn renderInner(self: *Pattern, fields: eval.Fields, out: []Rgb) !u32 {
        if (comptime !have_fix) return error.EvalUnavailable;
        const f = try applyFrame(&self.ev, self.lambda, fields, &self.ints, self.gpa);
        eval.decodeLeds(f.bitmap, fields.brightness, out); // reads the extracted ints
        return finishFrame(&self.ev, &self.frame, f.next_ms); // collect after
    }

    /// Evaluate one full-frame OLED pattern (single-lambda path; the multi-screen OLED
    /// uses `ScreenSet`). Decodes into `out` as page-major bytes, returns clamped nextMs.
    pub fn renderOled(self: *Pattern, fields: eval.Fields, out: []u8) !u32 {
        if (comptime !have_fix) return error.EvalUnavailable;
        return self.renderOledInner(fields, out) catch |err| {
            if (!self.logged_error) {
                std.log.err("oled: eval-screen render failed: {s}; dropping eval screen", .{@errorName(err)});
                self.logged_error = true;
            }
            return err;
        };
    }

    fn renderOledInner(self: *Pattern, fields: eval.Fields, out: []u8) !u32 {
        if (comptime !have_fix) return error.EvalUnavailable;
        const f = try applyFrame(&self.ev, self.lambda, fields, &self.ints, self.gpa);
        _ = eval.decodeOledFrame(f, out, fields.width); // full-frame path; caller full-flushes
        return finishFrame(&self.ev, &self.frame, f.next_ms);
    }
};

/// The OLED screen set: ONE fix Engine holding N compiled lambdas, one per screen (five
/// separate Engines would each carry the ~34-81 MB Value/chunk heap -> OOM on the 351 MB
/// badge). Each lambda is compiled from its own source text (kept alive for error spans),
/// all pinned together in a SINGLE `gcSetExternalRoots` call. A screen that fails to
/// compile is skipped (logged once); if none compile, `open` returns null.
pub const ScreenSet = struct {
    gpa: std.mem.Allocator,
    ev: Engine,
    lambdas: []Value,
    texts: [][]u8,
    names: [][]u8,
    frame: u64 = 0,
    logged_error: bool = false,
    // Playback pacing for delta screens (Bad Apple). `play_idx` feeds `scope.frameIndex`
    // so cumulative deltas are never skipped; it resets to 0 when the active screen
    // changes (`active_ix`) so re-entry starts on a keyframe. See badapple-delta.md.
    play_idx: u64 = 0,
    active_ix: ?usize = null,
    // Reused bitmap-int buffer (grown on first render); freed in deinit.
    ints: []i64 = &.{},

    /// Stand up ONE single-threaded Engine, compile each path to a lambda, pin ALL lambdas
    /// at once. Skips (logs once) a path that cannot be read / does not compile / is not a
    /// function; the rest still load. Returns null when eval is unavailable or none loaded.
    pub fn open(gpa: std.mem.Allocator, paths: []const []const u8) ?ScreenSet {
        if (comptime !have_fix) {
            std.log.info("oled: eval screens requested but unavailable on this arch", .{});
            return null;
        }
        if (paths.len == 0) return null;

        var ev = Engine.init(gpa, .{ .worker_count = 0, .compile_cache = .off }) catch |err| {
            std.log.err("oled: eval engine init failed: {s}", .{@errorName(err)});
            return null;
        };

        var lambdas = gpa.alloc(Value, paths.len) catch {
            ev.deinit();
            return null;
        };
        var texts = gpa.alloc([]u8, paths.len) catch {
            gpa.free(lambdas);
            ev.deinit();
            return null;
        };
        var names = gpa.alloc([]u8, paths.len) catch {
            gpa.free(lambdas);
            gpa.free(texts);
            ev.deinit();
            return null;
        };

        var loaded: usize = 0;
        for (paths) |path| {
            const text = readPattern(gpa, path) orelse {
                std.log.warn("oled: cannot read eval screen {s}; skipping", .{path});
                continue;
            };
            const lambda = ev.evaluate(text) catch |err| {
                std.log.warn("oled: eval screen {s} did not compile ({s}); skipping", .{ path, @errorName(err) });
                gpa.free(text);
                continue;
            };
            if (!lambda.isNixClosure()) {
                std.log.warn("oled: eval screen {s} is not a function; skipping", .{path});
                gpa.free(text);
                continue;
            }
            const nm = gpa.dupe(u8, screenName(path)) catch {
                gpa.free(text);
                continue;
            };
            lambdas[loaded] = lambda;
            texts[loaded] = text;
            names[loaded] = nm;
            loaded += 1;
            std.log.info("oled: eval screen {s} ({d} bytes) compiled as '{s}'", .{ path, text.len, nm });
        }

        if (loaded == 0) {
            gpa.free(lambdas);
            gpa.free(texts);
            gpa.free(names);
            ev.deinit();
            std.log.warn("oled: no eval screens loaded; falling back to computed screens", .{});
            return null;
        }

        lambdas = gpa.realloc(lambdas, loaded) catch lambdas[0..loaded];
        texts = gpa.realloc(texts, loaded) catch texts[0..loaded];
        names = gpa.realloc(names, loaded) catch names[0..loaded];

        ev.gcSetExternalRoots(lambdas) catch |err| {
            std.log.err("oled: eval root pin failed: {s}", .{@errorName(err)});
            for (texts) |t| gpa.free(t);
            for (names) |n| gpa.free(n);
            gpa.free(lambdas);
            gpa.free(texts);
            gpa.free(names);
            ev.deinit();
            return null;
        };

        std.log.info("oled: {d} eval screen(s) loaded into one engine", .{loaded});
        return .{ .gpa = gpa, .ev = ev, .lambdas = lambdas, .texts = texts, .names = names };
    }

    pub fn deinit(self: *ScreenSet) void {
        if (comptime !have_fix) return;
        if (self.ints.len > 0) self.gpa.free(self.ints);
        self.ev.deinit();
        for (self.texts) |t| self.gpa.free(t);
        for (self.names) |nm| self.gpa.free(nm);
        self.gpa.free(self.lambdas);
        self.gpa.free(self.texts);
        self.gpa.free(self.names);
    }

    /// How many screens loaded.
    pub fn count(self: *const ScreenSet) usize {
        return self.lambdas.len;
    }

    /// Display name of screen `idx` (the file basename sans `.nix`).
    pub fn name(self: *const ScreenSet, idx: usize) []const u8 {
        return self.names[idx];
    }

    /// Evaluate screen `idx` for a 1-bit OLED panel: apply its lambda, decode into the
    /// PERSISTENT framebuffer `out`, collect on the cadence, return the clamped nextMs plus
    /// the `Dirty` region. Per-screen delta pacing. Logs ONCE on fault.
    pub fn renderOled(self: *ScreenSet, idx: usize, fields: eval.Fields, out: []u8) !eval.OledFrame {
        if (comptime !have_fix) return error.EvalUnavailable;
        return self.renderOledInner(idx, fields, out) catch |err| {
            if (!self.logged_error) {
                std.log.err("oled: eval screen '{s}' render failed: {s}; dropping it", .{ self.names[idx], @errorName(err) });
                self.logged_error = true;
            }
            return err;
        };
    }

    fn renderOledInner(self: *ScreenSet, idx: usize, fields: eval.Fields, out: []u8) !eval.OledFrame {
        if (comptime !have_fix) return error.EvalUnavailable;
        // Screen switch -> restart playback at frame 0 (always a keyframe), so a delta
        // screen never applies a delta onto another screen's stale framebuffer.
        if (self.active_ix == null or self.active_ix.? != idx) {
            self.play_idx = 0;
            self.active_ix = idx;
        }
        var fr = fields;
        fr.frame_index = self.play_idx;
        const f = try applyFrame(&self.ev, self.lambdas[idx], fr, &self.ints, self.gpa);
        const dirty = eval.decodeOledFrame(f, out, fr.width);
        const next_ms = finishFrame(&self.ev, &self.frame, f.next_ms);
        self.play_idx +%= 1;
        return .{ .next_ms = next_ms, .dirty = dirty };
    }
};

/// Derive a screen's display name from its path: the basename sans a trailing `.nix`.
fn screenName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const stem = if (std.mem.endsWith(u8, base, ".nix")) base[0 .. base.len - 4] else base;
    return if (stem.len == 0) "screen" else stem;
}

/// Read a pattern file (bounded to `max_pattern_bytes`) into a gpa-owned buffer. Null on
/// any read fault WITHOUT logging -- the caller logs at the right severity.
fn readPattern(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (comptime !have_fix) return null;
    var pbuf: [512]u8 = undefined;
    const zpath = std.fmt.bufPrintZ(&pbuf, "{s}", .{path}) catch return null;
    const scratch = gpa.alloc(u8, max_pattern_bytes) catch return null;
    defer gpa.free(scratch);
    const used = linux.readFile(zpath, scratch) orelse return null;
    return gpa.dupe(u8, used) catch null;
}

/// Prove the embedded evaluator + native-apply path are live: compile a pattern lambda
/// once, apply it to a native scope, decode the flat bitmap. Reachable via `nix-badge
/// fix-selftest`. A build without eval logs and returns cleanly.
pub fn selftest(gpa: std.mem.Allocator) !void {
    if (comptime !have_fix) {
        std.log.info("nix-badge built without -Dfix-src; eval unavailable", .{});
        return;
    }

    var ev = try Engine.init(gpa, .{ .worker_count = 0, .compile_cache = .off });
    defer ev.deinit();

    const lambda = try ev.evaluate(
        \\scope: {
        \\  bitmap = builtins.genList (i: i * 65536 + (255 - i) * 256 + scope.batteryPct) scope.width;
        \\  nextMs = 33;
        \\}
    );
    if (!lambda.isNixClosure()) {
        std.log.err("fix-selftest: expression is not a function", .{});
        return error.FixSelftestFailed;
    }
    try ev.gcSetExternalRoots(&.{lambda});

    const scope = try ev.makeAttrs(&.{
        .{ .name = "width", .value = Value.int(4) },
        .{ .name = "batteryPct", .value = Value.int(87) },
    });
    const result = try ev.applyValue(lambda, scope);
    if (result.kind() != .attrs) {
        std.log.err("fix-selftest: result is not an attrset", .{});
        return error.FixSelftestFailed;
    }
    const bitmap = try ev.forceValue((try ev.getAttr(result, "bitmap")) orelse return error.FixSelftestFailed);
    const next = try ev.forceValue((try ev.getAttr(result, "nextMs")) orelse return error.FixSelftestFailed);
    const pix = try ev.heapListOf(bitmap.asObjectId());
    std.log.info("fix-selftest: native apply -> {d} px, nextMs={d} (want 4, 33)", .{ pix.len, next.asInt() });
    for (pix, 0..) |p, i| {
        const v = (try ev.forceValue(p)).asInt();
        std.log.info("fix-selftest: px {d} = 0x{x:0>6}", .{ i, @as(u64, @intCast(v & 0xffffff)) });
    }
    std.log.info("fix-selftest: OK", .{});
}

test "have_fix flag is defined" {
    _ = have_fix;
}

// Exercise renderOled's page-byte LE decode on a real compiled Pattern: a lambda that
// returns two known ints must land in the framebuffer as their 4 LE bytes, with the
// untouched tail zeroed. On an eval-less build this test is a no-op.
test "renderOled decodes bitmap ints to page-major LE bytes" {
    if (comptime !have_fix) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var ev = try Engine.init(gpa, .{ .worker_count = 0, .compile_cache = .off });
    const lambda = try ev.evaluate(
        \\scope: { bitmap = [ 67305985 134678021 ]; nextMs = 50; }
    );
    try std.testing.expect(lambda.isNixClosure());
    try ev.gcSetExternalRoots(&.{lambda});

    var pat: Pattern = .{
        .gpa = gpa,
        .ev = ev,
        .text = try gpa.dupe(u8, ""),
        .lambda = lambda,
    };
    defer pat.deinit();

    var fb: [512]u8 = @splat(0xaa);
    const next = try pat.renderOled(.{ .width = 128, .height = 32 }, &fb);
    try std.testing.expectEqual(@as(u32, 50), next);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, fb[0..8]);
    for (fb[8..]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

// A fresh per-test temp dir under /tmp so the screen files keep CLEAN basenames.
fn tmpScreenDir(buf: []u8) ![:0]const u8 {
    const dir = try std.fmt.bufPrintZ(buf, "/tmp/nbtest-{d}", .{linux.monotonicMsec()});
    switch (linux.mkdir(dir.ptr, 0o755)) {
        .created, .exists, .failed => {},
    }
    return dir;
}

// Write `data` to `<dir>/<name>` so ScreenSet.open (via linux.readFile) can open it.
fn writeTmpScreen(buf: []u8, dir: []const u8, name: []const u8, data: []const u8) ![]const u8 {
    const path = try std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, name });
    try linux.writeFile(path.ptr, data);
    return path;
}

// Prove ONE Engine holds N lambdas: open a ScreenSet of two distinct inline screens, then
// render EACH into its own framebuffer -> different bytes (truly separate lambdas sharing
// one Engine), each nextMs comes through, names are the basenames.
test "ScreenSet holds N lambdas in one engine and renders each" {
    if (comptime !have_fix) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var dbuf: [256]u8 = undefined;
    const dir = try tmpScreenDir(&dbuf);
    var abuf: [512]u8 = undefined;
    var bbuf: [512]u8 = undefined;
    const alpha_src = "scope: { bitmap = [ scope.batteryPct ]; nextMs = 111; }";
    const beta_src = "scope: { bitmap = [ (scope.cpuPct + 1000) ]; nextMs = 222; }";
    const alpha = try writeTmpScreen(&abuf, dir, "alpha.nix", alpha_src);
    const beta = try writeTmpScreen(&bbuf, dir, "beta.nix", beta_src);

    var set = ScreenSet.open(gpa, &.{ alpha, beta }) orelse return error.ScreenSetOpenFailed;
    defer set.deinit();

    try std.testing.expectEqual(@as(usize, 2), set.count());
    try std.testing.expectEqualStrings("alpha", set.name(0));
    try std.testing.expectEqualStrings("beta", set.name(1));

    var fb0: [512]u8 = @splat(0xaa);
    const n0 = try set.renderOled(0, .{ .width = 128, .height = 32, .battery_pct = 87 }, &fb0);
    try std.testing.expectEqual(@as(u32, 111), n0.next_ms);
    try std.testing.expectEqualSlices(u8, &.{ 87, 0, 0, 0 }, fb0[0..4]);
    for (fb0[4..]) |b| try std.testing.expectEqual(@as(u8, 0), b);

    var fb1: [512]u8 = @splat(0xaa);
    const n1 = try set.renderOled(1, .{ .width = 128, .height = 32, .cpu_pct = 42 }, &fb1);
    try std.testing.expectEqual(@as(u32, 222), n1.next_ms);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x04, 0, 0 }, fb1[0..4]);

    var fb0b: [512]u8 = @splat(0xaa);
    _ = try set.renderOled(0, .{ .width = 128, .height = 32, .battery_pct = 5 }, &fb0b);
    try std.testing.expectEqualSlices(u8, &.{ 5, 0, 0, 0 }, fb0b[0..4]);
}

// A ScreenSet where one path is unreadable must still load the good screens; all-bad -> null.
test "ScreenSet skips a bad screen but loads the rest" {
    if (comptime !have_fix) return;
    const saved_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_level;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var dbuf: [256]u8 = undefined;
    const dir = try tmpScreenDir(&dbuf);
    var okbuf: [512]u8 = undefined;
    const ok = try writeTmpScreen(&okbuf, dir, "ok.nix", "scope: { bitmap = [ 7 ]; nextMs = 33; }");

    const paths: []const []const u8 = &.{ ok, "/nonexistent/nope.nix" };
    var set = ScreenSet.open(gpa, paths) orelse return error.ScreenSetOpenFailed;
    defer set.deinit();
    try std.testing.expectEqual(@as(usize, 1), set.count());
    try std.testing.expectEqualStrings("ok", set.name(0));

    try std.testing.expect(ScreenSet.open(gpa, &.{"/nonexistent/a.nix"}) == null);
    try std.testing.expect(ScreenSet.open(gpa, &.{}) == null);
}

// A self-contained (inlined-shape) screen -- a `let` table looked up per frame, NO imports
// -- compiles once and renders through ScreenSet, proving the badge's inlined info screens run.
test "ScreenSet renders a self-contained (inlined-shape) screen" {
    if (comptime !have_fix) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var dbuf: [256]u8 = undefined;
    const dir = try tmpScreenDir(&dbuf);

    var scbuf: [1024]u8 = undefined;
    const self_contained =
        \\scope:
        \\let
        \\  tbl = [ 100 200 300 515 ];
        \\  mod = a: b: a - (a / b) * b;
        \\in { bitmap = [ (builtins.elemAt tbl (mod scope.batteryPct 4)) ]; nextMs = 77; }
    ;
    const sc = try writeTmpScreen(&scbuf, dir, "selfcontained.nix", self_contained);

    var set = ScreenSet.open(gpa, &.{sc}) orelse return error.ScreenSetOpenFailed;
    defer set.deinit();
    try std.testing.expectEqual(@as(usize, 1), set.count());
    try std.testing.expectEqualStrings("selfcontained", set.name(0));

    var fb: [512]u8 = @splat(0xaa);
    const next = try set.renderOled(0, .{ .width = 128, .height = 32, .battery_pct = 87 }, &fb);
    try std.testing.expectEqual(@as(u32, 77), next.next_ms);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x02, 0, 0 }, fb[0..4]);
}
