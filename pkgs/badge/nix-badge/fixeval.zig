//! fixeval: the FIX evaluator backend (psyclyx/fix's fetch-less `expr`, aarch64 only;
//! the riscv core builds eval-less and uses the computed/blob paths).
//!
//! Per-frame content eval. A pattern/screen is a pure Nix function
//!     scope: { bitmap = [ <int> ... ]; nextMs = <int>; }
//! where `bitmap` is a flat list of small packed ints (LED: one 0xRRGGBB per pixel)
//! and `nextMs` is how long until the next call. The function is compiled ONCE to a
//! lambda (`FixBackend.open`), then applied every frame to a freshly-built `scope`
//! attrset via the native `Engine.applyValue`/`Engine.makeAttrs` patch -- NO source
//! recompile, so fix mints no new chunk per frame. `applyFrame` forces the result
//! `bitmap` (and optional `overlay`) list out of fix's Value heap into plain `[]i64`;
//! the DECODE from ints -> GDDRAM bytes / RGB lives in `eval.zig`, shared with the nix
//! backend, so an A/B measures the evaluator, not the decode.
//!
//! `FixBackend` is the fix arm of `backend.Backend`; it exposes the same surface as
//! `nixeval.NixBackend` (`open`/`applyFrame`/`collect`/`deinit`/`count`/`name`). The
//! per-screen PLAYBACK state (frame_index pacing, collect cadence) lives in the shared
//! `backend.ScreenSet`/`backend.Pattern` holders, not here, so both backends share it.
//! The Value-heap garbage is reclaimed by a young-gated `collect()` the holder calls on
//! a cadence.
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

/// Diagnostic: total nanoseconds spent in `collect` since the loop last read+reset it
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

/// The fix backend: ONE fix Engine holding N compiled lambdas, one per screen/pattern
/// (five separate Engines would each carry the ~34-81 MB Value/chunk heap -> OOM on the
/// 351 MB badge). Each lambda is compiled from its own source text (kept alive for error
/// spans), all pinned together in a SINGLE `gcSetExternalRoots` call. A screen that fails
/// to compile is skipped (logged once); if none compile, `open` returns null. The LED ring
/// uses a single-lambda backend; the OLED uses N. `applyFrame` is the ONLY place fix
/// `Value`s are read out to ints.
pub const FixBackend = struct {
    gpa: std.mem.Allocator,
    ev: Engine,
    lambdas: []Value,
    texts: [][]u8,
    names: [][]u8,
    // Reused bitmap / overlay int buffers (grown on first render); freed in deinit.
    ints: []i64 = &.{},
    overlay_ints: []i64 = &.{},

    /// Stand up ONE single-threaded Engine, compile each path to a lambda, pin ALL lambdas
    /// at once. Skips (logs once) a path that cannot be read / does not compile / is not a
    /// function; the rest still load. Returns null when eval is unavailable or none loaded.
    ///
    /// `opts.io` is the file-IO backend fed to the Engine so a screen's runtime `import`/
    /// `builtins.readFile` of an on-disk path works; the vendored fetch-less stub still errors
    /// on network fetchers, so this is LOCAL reads only. `opts.nix_path`, when set, registers
    /// the `<name>` search path (e.g. "nixbadge=/etc/nixbadge") so content can
    /// `import <nixbadge/lib/font.nix>` regardless of where the screen file lives.
    pub fn open(gpa: std.mem.Allocator, opts: eval.Opts, paths: []const []const u8) ?FixBackend {
        if (comptime !have_fix) {
            std.log.info("fix: eval requested but unavailable on this arch", .{});
            return null;
        }
        if (paths.len == 0) return null;

        var ev = Engine.init(gpa, .{ .worker_count = 0, .compile_cache = .off, .io = opts.io }) catch |err| {
            std.log.err("fix: eval engine init failed: {s}", .{@errorName(err)});
            return null;
        };
        // [#34] fix's young-gated MINOR collection has a remembered-set gap (a live young child
        // reachable only from an old/pinned parent gets swept -> "missed edge" panic). Force
        // MAJOR-only collection: a major rebuilds old/young from the true reachable set and
        // cannot sweep a live object. Sound + memory-bounded (see gc-always-major.patch).
        ev.setAlwaysMajor(true);
        if (opts.nix_path) |np| ev.setNixPath(np) catch |err|
            std.log.warn("fix: setNixPath('{s}') failed: {s}; <name> imports unavailable", .{ np, @errorName(err) });

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
                std.log.warn("fix: cannot read eval screen {s}; skipping", .{path});
                continue;
            };
            const lambda = ev.evaluate(text) catch |err| {
                std.log.warn("fix: eval screen {s} did not compile ({s}); skipping", .{ path, @errorName(err) });
                gpa.free(text);
                continue;
            };
            if (!lambda.isNixClosure()) {
                std.log.warn("fix: eval screen {s} is not a function; skipping", .{path});
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
            std.log.info("fix: eval screen {s} ({d} bytes) compiled as '{s}'", .{ path, text.len, nm });
        }

        if (loaded == 0) {
            gpa.free(lambdas);
            gpa.free(texts);
            gpa.free(names);
            ev.deinit();
            std.log.warn("fix: no eval screens loaded", .{});
            return null;
        }

        lambdas = gpa.realloc(lambdas, loaded) catch lambdas[0..loaded];
        texts = gpa.realloc(texts, loaded) catch texts[0..loaded];
        names = gpa.realloc(names, loaded) catch names[0..loaded];

        ev.gcSetExternalRoots(lambdas) catch |err| {
            std.log.err("fix: eval root pin failed: {s}", .{@errorName(err)});
            for (texts) |t| gpa.free(t);
            for (names) |n| gpa.free(n);
            gpa.free(lambdas);
            gpa.free(texts);
            gpa.free(names);
            ev.deinit();
            return null;
        };

        std.log.info("fix: {d} eval screen(s) loaded into one engine", .{loaded});
        return .{ .gpa = gpa, .ev = ev, .lambdas = lambdas, .texts = texts, .names = names };
    }

    pub fn deinit(self: *FixBackend) void {
        if (comptime !have_fix) return;
        if (self.ints.len > 0) self.gpa.free(self.ints);
        if (self.overlay_ints.len > 0) self.gpa.free(self.overlay_ints);
        self.ev.deinit();
        for (self.texts) |t| self.gpa.free(t);
        for (self.names) |nm| self.gpa.free(nm);
        self.gpa.free(self.lambdas);
        self.gpa.free(self.texts);
        self.gpa.free(self.names);
    }

    /// How many lambdas loaded.
    pub fn count(self: *const FixBackend) usize {
        return self.lambdas.len;
    }

    /// Display name of lambda `idx` (the file basename sans `.nix`).
    pub fn name(self: *const FixBackend, idx: usize) []const u8 {
        return self.names[idx];
    }

    /// Build the per-frame `scope` natively, apply lambda `idx`, and force the result's
    /// `bitmap` (+ optional `overlay`) list into the reused int buffers as plain i64.
    /// Returns a backend-agnostic `eval.Frame`. Mints NO new chunk. This is the ONLY place
    /// fix `Value`s are read out to ints. Collect is deferred to `collect()` (the holder
    /// calls it after decode), safe because the ints are already extracted here.
    pub fn applyFrame(self: *FixBackend, idx: usize, fields: eval.Fields) !eval.Frame {
        if (comptime !have_fix) return error.EvalUnavailable;
        const ev = &self.ev;
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
            .{ .name = "backend", .value = Value.int(fields.backend_id) },
            .{ .name = "fps", .value = Value.int(fields.fps) },
        });

        const result = try ev.applyValue(self.lambdas[idx], scope);
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
        try ensureInts(self.gpa, &self.ints, pix.len);
        for (pix, 0..) |p, i| self.ints[i] = (try ev.forceValue(p)).asInt();

        // Optional overlay: packed (offset,byte) entries stamped over the decoded frame by
        // the runtime. Absent -> overlay_n 0 (no-op). `overlayN` counts entries; when it is
        // omitted, assume the list is fully packed (2 entries/int).
        var overlay_len: usize = 0;
        var overlay_entries: u32 = 0;
        if (try ev.getAttr(result, "overlay")) |ov| {
            const ovf = try ev.forceValue(ov);
            if (ovf.kind() == .list) {
                const ol = try ev.heapListOf(ovf.asObjectId());
                try ensureInts(self.gpa, &self.overlay_ints, ol.len);
                for (ol, 0..) |p, i| self.overlay_ints[i] = (try ev.forceValue(p)).asInt();
                overlay_len = ol.len;
                if (try ev.getAttr(result, "overlayN")) |ovn| {
                    const raw = (try ev.forceValue(ovn)).asInt();
                    if (raw > 0) overlay_entries = @intCast(@min(raw, @as(i64, std.math.maxInt(u32))));
                } else {
                    overlay_entries = @intCast(@min(overlay_len * 2, @as(usize, std.math.maxInt(u32))));
                }
            }
        }

        return .{
            .bitmap = self.ints[0..pix.len],
            .next_ms = next.asInt(),
            .delta = is_delta,
            .n = n_changes,
            .overlay = self.overlay_ints[0..overlay_len],
            .overlay_n = overlay_entries,
        };
    }

    /// Reclaim young Value garbage (the scope, result attrset, and bitmap/overlay lists of
    /// the frames since the last collect). MUST be called only AFTER the caller has decoded
    /// the frame (the ints are already extracted in `applyFrame`, so the sweep is safe). The
    /// holder calls this on `eval.collect_every` cadence. No-op for the nix backend.
    ///
    /// A fast MINOR collect: correct now that the vendored gc-remset-young-source.patch fixes
    /// fix's write-barrier (records young-source edges so a parent that tenures mid-minor
    /// keeps its old->young edge). Before that patch this had to be collectMajorNow to dodge
    /// the missed-edge death-spiral (#34), but a full major every 64 frames cost ~48ms and
    /// showed as periodic GC pauses; the minor is ~1-5ms.
    pub fn collect(self: *FixBackend) void {
        if (comptime !have_fix) return;
        const c0 = linux.monotonicNsec();
        _ = self.ev.collectNow();
        collect_ns_accum += linux.monotonicNsec() - c0;
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
pub fn selftest(gpa: std.mem.Allocator, io: std.Io) !void {
    if (comptime !have_fix) {
        std.log.info("nix-badge built without -Dfix-src; eval unavailable", .{});
        return;
    }

    var ev = try Engine.init(gpa, .{ .worker_count = 0, .compile_cache = .off, .io = io });
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

// A fresh per-test temp dir under /tmp so the screen files keep CLEAN basenames.
fn tmpScreenDir(buf: []u8) ![:0]const u8 {
    const dir = try std.fmt.bufPrintZ(buf, "/tmp/nbtest-{d}", .{linux.monotonicMsec()});
    switch (linux.mkdir(dir.ptr, 0o755)) {
        .created, .exists, .failed => {},
    }
    return dir;
}

// Write `data` to `<dir>/<name>` so FixBackend.open (via linux.readFile) can open it.
fn writeTmpScreen(buf: []u8, dir: []const u8, name: []const u8, data: []const u8) ![]const u8 {
    const path = try std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, name });
    try linux.writeFile(path.ptr, data);
    return path;
}

// applyFrame extracts a compiled lambda's bitmap ints + nextMs; the delta/overlay contract
// fields come through. On an eval-less build this is a no-op.
test "FixBackend.applyFrame extracts bitmap ints, nextMs, delta, and overlay" {
    if (comptime !have_fix) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var dbuf: [256]u8 = undefined;
    const dir = try tmpScreenDir(&dbuf);
    var abuf: [512]u8 = undefined;
    // A full-frame screen: bitmap of two ints, plus an overlay of one packed entry.
    const src =
        \\scope: { bitmap = [ 67305985 134678021 ]; nextMs = 50; overlay = [ 393216 ]; overlayN = 1; }
    ;
    const path = try writeTmpScreen(&abuf, dir, "s.nix", src);

    var be = FixBackend.open(gpa, .{ .io = std.testing.io },&.{path}) orelse return error.OpenFailed;
    defer be.deinit();
    try std.testing.expectEqual(@as(usize, 1), be.count());
    try std.testing.expectEqualStrings("s", be.name(0));

    const f = try be.applyFrame(0, .{ .width = 128, .height = 32 });
    try std.testing.expectEqual(@as(i64, 50), f.next_ms);
    try std.testing.expect(!f.delta);
    try std.testing.expectEqual(@as(usize, 2), f.bitmap.len);
    try std.testing.expectEqual(@as(i64, 67305985), f.bitmap[0]);
    // overlay = [ 393216 ] with overlayN=1 -> one entry; 393216 = (offset 6)*65536.. actually
    // E0 = 393216 >> 18 = 1 -> offset 0, byte ... just assert it came through as one entry.
    try std.testing.expectEqual(@as(u32, 1), f.overlay_n);
    try std.testing.expectEqual(@as(usize, 1), f.overlay.len);
}

// A screen's runtime `import <abs-path>` resolves through the Engine's io backend (this is
// what makes /etc/nixbadge/lib importable). Previously this faulted FileIoUnavailable.
test "FixBackend runtime import of an absolute path works with io wired" {
    if (comptime !have_fix) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var dbuf: [256]u8 = undefined;
    const dir = try tmpScreenDir(&dbuf);
    var lbuf: [512]u8 = undefined;
    var sbuf: [640]u8 = undefined;
    const lib = try writeTmpScreen(&lbuf, dir, "lib.nix", "{ v = 7; }");
    // The screen imports the lib by ABSOLUTE path (no relative base when we eval source text).
    const src = try std.fmt.allocPrint(gpa, "scope: {{ bitmap = [ (import {s}).v ]; nextMs = 10; }}", .{lib});
    const screen = try writeTmpScreen(&sbuf, dir, "imp.nix", src);

    var be = FixBackend.open(gpa, .{ .io = std.testing.io }, &.{screen}) orelse return error.OpenFailed;
    defer be.deinit();
    const f = try be.applyFrame(0, .{});
    try std.testing.expectEqual(@as(i64, 7), f.bitmap[0]);
}

// A screen's `import <nixbadge/lib.nix>` resolves through the search path set from
// opts.nix_path -- content is location-independent (this is what /etc/nixbadge/lib uses).
test "FixBackend resolves <nixbadge/...> search-path imports" {
    if (comptime !have_fix) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var dbuf: [256]u8 = undefined;
    const dir = try tmpScreenDir(&dbuf);
    var lbuf: [512]u8 = undefined;
    var sbuf: [512]u8 = undefined;
    // <nixbadge> -> `dir`; the screen imports <nixbadge/val.nix>.
    _ = try writeTmpScreen(&lbuf, dir, "val.nix", "{ v = 9; }");
    const screen = try writeTmpScreen(&sbuf, dir, "s.nix", "scope: { bitmap = [ (import <nixbadge/val.nix>).v ]; nextMs = 10; }");

    var npbuf: [320]u8 = undefined;
    const np = try std.fmt.bufPrint(&npbuf, "nixbadge={s}", .{dir});
    var be = FixBackend.open(gpa, .{ .io = std.testing.io, .nix_path = np }, &.{screen}) orelse return error.OpenFailed;
    defer be.deinit();
    const f = try be.applyFrame(0, .{});
    try std.testing.expectEqual(@as(i64, 9), f.bitmap[0]);
}

// applyFrame sees scope.backend (the backend id) + scope.fps: a screen that echoes them
// through bitmap must reflect what Fields carried.
test "FixBackend.applyFrame exposes scope.backend + scope.fps" {
    if (comptime !have_fix) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var dbuf: [256]u8 = undefined;
    const dir = try tmpScreenDir(&dbuf);
    var abuf: [512]u8 = undefined;
    const src = "scope: { bitmap = [ scope.backend scope.fps ]; nextMs = 10; }";
    const path = try writeTmpScreen(&abuf, dir, "bf.nix", src);

    var be = FixBackend.open(gpa, .{ .io = std.testing.io },&.{path}) orelse return error.OpenFailed;
    defer be.deinit();
    const f = try be.applyFrame(0, .{ .backend_id = 1, .fps = 59 });
    try std.testing.expectEqual(@as(i64, 1), f.bitmap[0]);
    try std.testing.expectEqual(@as(i64, 59), f.bitmap[1]);
}

// A FixBackend where one path is unreadable must still load the good screens; all-bad -> null.
test "FixBackend skips a bad screen but loads the rest" {
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
    var be = FixBackend.open(gpa, .{ .io = std.testing.io },paths) orelse return error.OpenFailed;
    defer be.deinit();
    try std.testing.expectEqual(@as(usize, 1), be.count());
    try std.testing.expectEqualStrings("ok", be.name(0));

    try std.testing.expect(FixBackend.open(gpa, .{ .io = std.testing.io },&.{"/nonexistent/a.nix"}) == null);
    try std.testing.expect(FixBackend.open(gpa, .{ .io = std.testing.io },&.{}) == null);
}
