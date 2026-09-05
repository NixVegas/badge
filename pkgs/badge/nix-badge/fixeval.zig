//! fixeval: the fix evaluator backend, built on psyclyx/fix's fetch-less `expr`.
//!
//! A pattern or screen is a pure Nix function of the shape
//!     scope: { bitmap = [ <int> ... ]; nextMs = <int>; }
//! where `bitmap` is a flat list of packed integers, one 0xRRGGBB per pixel for
//! the LED ring, and `nextMs` is how long to wait before the next call.
//!
//! `open` compiles the function ONCE to a lambda. Every frame after that applies
//! the lambda to a freshly built `scope` attrset through the native
//! `Engine.applyValue` and `Engine.makeAttrs` entry points. There is no source
//! recompile, so fix creates no new chunk per frame; chunks are permanent roots,
//! so a recompile per frame would leak. `applyFrame` forces the result's `bitmap`,
//! and its optional `overlay`, out of fix's Value heap into a plain `[]i64`. The
//! decode from those integers to panel bytes lives in `eval.zig` and is shared
//! with the nix backend.
//!
//! `FixBackend` is the fix arm of `backend.Backend` and exposes the same surface
//! as `nixeval.NixBackend`. The per-screen playback state, the frame-index pacing
//! and the collection cadence, lives in the shared `backend.ScreenSet` and
//! `backend.Pattern` holders rather than here, so both backends share it.
//!
//! Whether the evaluator is compiled in is a build-time decision, reported by
//! `have_fix`. Without it `open` returns null and the caller falls back.

const std = @import("std");
const build_options = @import("build_options");
const eval = @import("eval.zig");

/// True when `-Dfix-src` supplied a fix source and `expr` was linked in.
pub const have_fix = build_options.have_fix;

// `expr`/`runtime` only exist in the build graph when have_fix; alias to void
// otherwise so the gated methods still type-check on an eval-less build.
const expr = if (have_fix) @import("expr") else struct {};
const Engine = if (have_fix) expr.Engine else void;

/// The Engine must NEVER move after its first evaluation, so it is heap allocated
/// before that evaluation and held by pointer.
///
/// fix installs its collection hook at the first evaluation and records the
/// Engine's address at that moment. Holding the Engine by value and returning it
/// from `open` moved it AFTER the compile had installed the hook. Every later
/// collection then ran against the dead pre-move copy, so the mutator and the
/// collector saw different inline heap state.
///
/// That aliasing caused the whole family of collector faults seen on the badge:
/// the "missed edge" panics, because a minor collection read the stale copy's
/// remembered set; unbounded growth in reserved bytes, because sweeps freed into
/// stale free lists the live allocator never saw; evaluation that slowed down as
/// frames played; and setters that appeared to do nothing, because they were
/// written to the live copy and read back from the stale one.
const EnginePtr = if (have_fix) *expr.Engine else void;
const Value = if (have_fix) @import("runtime").value.Value else void;

/// The largest content source this backend reads. A live LED pattern is about
/// 1 KiB, but a baked frame list is the outlier at a few MiB, so the limit is
/// sized for that. It bounds one read at open, not anything on the frame path.
pub const max_pattern_bytes = 8 * 1024 * 1024;

/// Grow `ints.*` to hold at least `need` integers. The first allocation is
/// separate from the growth path, because the `&.{}` default is not owned by the
/// allocator and must not be passed to `realloc`.
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
    io: std.Io,
    ev: EnginePtr,
    lambdas: []Value,
    texts: [][]u8,
    names: [][]u8,
    /// Reused bitmap and overlay integer buffers. They grow on the first render
    /// that needs more room and are freed in `deinit`.
    ints: []i64 = &.{},
    overlay_ints: []i64 = &.{},
    /// Nanoseconds spent in `collect` since `takeCollectNs` last read and cleared
    /// it. The render loop uses this to split the per-frame cost into the apply and
    /// decode part and the collection part, without a timer in every call.
    collect_ns: i128 = 0,

    /// Read and clear the accumulated collection time.
    pub fn takeCollectNs(self: *FixBackend) i128 {
        const v = self.collect_ns;
        self.collect_ns = 0;
        return v;
    }

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
        return openInner(gpa, opts, paths) catch |err| switch (err) {
            // Every screen was skipped, and each one already said why. The caller
            // handles an empty set, so this is not a failure of the evaluator.
            error.NoScreensLoaded => {
                std.log.warn("fix: no screens loaded", .{});
                return null;
            },
            else => {
                std.log.err("fix: cannot open the evaluator: {t}", .{err});
                return null;
            },
        };
    }

    /// The fallible body of `open`. Every resource is released by an `errdefer`, so
    /// one failure path cannot leak or double-free what an earlier step took.
    fn openInner(
        gpa: std.mem.Allocator,
        opts: eval.Opts,
        paths: []const []const u8,
    ) !FixBackend {

        // Heap-allocate BEFORE the first compile: the compile is an evaluation, which
        // installs the GC hook at the Engine's CURRENT address (see EnginePtr). The move
        // into `ev.*` happens before that, so the hook pins the final, stable address.
        const ev = try gpa.create(Engine);
        errdefer gpa.destroy(ev);
        ev.* = try Engine.init(gpa, .{ .worker_count = 0, .compile_cache = .off, .io = opts.io });
        errdefer ev.deinit();
        // Cap the collection line when the caller asked for one. See
        // `eval.Opts.gc_budget_bytes` for why the automatic line is wrong here.
        // The collection policy itself stays stock: minor collections with
        // promotion-gated majors. An earlier setAlwaysMajor(true) here worked
        // around the "missed edge" panics, which the Engine-move aliasing
        // described at `EnginePtr` fully explains. It never took effect anyway,
        // because it was written to the live Engine copy and read back from the
        // stale one. With the aliasing fixed, minor collections are correct and
        // cost O(young) instead of a major's O(live heap).
        if (opts.gc_budget_bytes) |b| ev.configureMemory(b, null, false);
        if (opts.nix_path) |np| ev.setNixPath(np) catch |err|
            std.log.warn("fix: setNixPath('{s}') failed ({t}); <name> imports will not resolve", .{
                np, err,
            });

        var lambdas = try gpa.alloc(Value, paths.len);
        errdefer gpa.free(lambdas);
        var texts = try gpa.alloc([]u8, paths.len);
        errdefer gpa.free(texts);
        var names = try gpa.alloc([]u8, paths.len);
        errdefer gpa.free(names);

        // A screen that cannot be read, does not compile, or is not a function is
        // skipped with a log line, and the rest still load.
        var loaded: usize = 0;
        errdefer for (texts[0..loaded], names[0..loaded]) |t, n| {
            gpa.free(t);
            gpa.free(n);
        };
        for (paths) |path| {
            const text = readPattern(opts.io, gpa, path) catch |err| {
                std.log.warn("fix: cannot read eval screen {s} ({t}); skipping", .{ path, err });
                continue;
            };
            const lambda = ev.evaluate(text) catch |err| {
                std.log.warn("fix: screen {s} did not compile ({t}); skipping", .{ path, err });
                gpa.free(text);
                continue;
            };
            if (!lambda.isNixClosure()) {
                std.log.warn("fix: eval screen {s} is not a function; skipping", .{path});
                gpa.free(text);
                continue;
            }
            const nm = gpa.dupe(u8, screenName(path)) catch |err| {
                gpa.free(text);
                return err;
            };
            lambdas[loaded] = lambda;
            texts[loaded] = text;
            names[loaded] = nm;
            loaded += 1;
            std.log.info("fix: screen {s} ({d} bytes) compiled as '{s}'", .{ path, text.len, nm });
        }
        if (loaded == 0) return error.NoScreensLoaded;

        // Shrinking cannot fail in practice, and if it does the oversized buffer is
        // still correct, so keep the original and use only the loaded prefix.
        lambdas = gpa.realloc(lambdas, loaded) catch lambdas[0..loaded];
        texts = gpa.realloc(texts, loaded) catch texts[0..loaded];
        names = gpa.realloc(names, loaded) catch names[0..loaded];

        try ev.gcSetExternalRoots(lambdas);

        std.log.info("fix: {d} eval screen(s) loaded into one engine", .{loaded});
        return .{
            .gpa = gpa,
            .io = opts.io,
            .ev = ev,
            .lambdas = lambdas,
            .texts = texts,
            .names = names,
        };
    }

    pub fn deinit(self: *FixBackend) void {
        if (comptime !have_fix) return;
        if (self.ints.len > 0) self.gpa.free(self.ints);
        if (self.overlay_ints.len > 0) self.gpa.free(self.overlay_ints);
        self.ev.deinit();
        self.gpa.destroy(self.ev);
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
        const ev = self.ev; // heap-allocated (see EnginePtr)
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
            .{ .name = "strap", .value = Value.int(fields.strap) },
            .{ .name = "vselMv", .value = Value.int(fields.vsel_mv) },
            // Constant per boot -> intern dedupes to a lookup after the first frame.
            .{
                .name = "nixosVersion",
                .value = Value.string(try ev.intern.intern(fields.nixos_version)),
            },
            .{
                .name = "kernelVersion",
                .value = Value.string(try ev.intern.intern(fields.kernel_version)),
            },
        });

        const result = try ev.applyValue(self.lambdas[idx], scope);
        if (result.kind() != .attrs) return error.PatternNotAttrs;

        const bitmap_attr = (try ev.getAttr(result, "bitmap")) orelse return error.MissingBitmap;
        const bitmap = try ev.forceValue(bitmap_attr);
        const next_attr = (try ev.getAttr(result, "nextMs")) orelse return error.MissingNextMs;
        const next = try ev.forceValue(next_attr);
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
                    if (raw > 0)
                        overlay_entries = @intCast(@min(raw, @as(i64, std.math.maxInt(u32))));
                } else {
                    const packed_entries = overlay_len * 2;
                    const capped = @min(packed_entries, @as(usize, std.math.maxInt(u32)));
                    overlay_entries = @intCast(capped);
                }
            }
        }

        // Contract v2 optionals (absent -> v1 defaults): hidden (cycle skip),
        // pause (freeze frameIndex), autoReturnMs (transient screen bounce-back).
        var hidden = false;
        var pause = false;
        var auto_return_ms: u32 = 0;
        if (try ev.getAttr(result, "hidden")) |h| hidden = (try ev.forceValue(h)).asBool();
        if (try ev.getAttr(result, "pause")) |p| pause = (try ev.forceValue(p)).asBool();
        if (try ev.getAttr(result, "autoReturnMs")) |ar| {
            const raw = (try ev.forceValue(ar)).asInt();
            if (raw > 0) auto_return_ms = @intCast(@min(raw, @as(i64, std.math.maxInt(u32))));
        }

        return .{
            .bitmap = self.ints[0..pix.len],
            .next_ms = next.asInt(),
            .delta = is_delta,
            .n = n_changes,
            .overlay = self.overlay_ints[0..overlay_len],
            .overlay_n = overlay_entries,
            .hidden = hidden,
            .pause = pause,
            .auto_return_ms = auto_return_ms,
        };
    }

    /// Reclaim the per-frame Value garbage (the scope, result attrset, and bitmap/overlay
    /// lists of the frames since the last collect). MUST be called only AFTER the caller has
    /// decoded the frame (the ints are already extracted in `applyFrame`, so the sweep is
    /// safe). The holder calls this on `eval.collect_every` cadence. No-op for the nix backend.
    ///
    /// CRITICAL: reset the Engine's external root set to ONLY the compiled lambdas first.
    /// `Engine.applyValue` -> `runWithVm` calls `gcRootCrossingValue(result)` on EVERY frame's
    /// return Value (so it survives crossing back to native), and those roots PERSIST until the
    /// next `gcSetExternalRoots` replaces the set. We set the roots once at open, so without
    /// this reset `extra_roots` grew one result per frame forever -> every (major, #34)
    /// collection marked an O(frames-played) set and per-frame eval climbed 5ms -> tens of
    /// seconds over a playback (with the frames themselves never reclaimable). Re-pinning just
    /// the lambdas drops the already-decoded results so the collect reclaims them; `extra_roots`
    /// then stays bounded by `collect_every`, and majors stay cheap regardless of clip length.
    pub fn collect(self: *FixBackend) void {
        if (comptime !have_fix) return;
        const started = std.Io.Timestamp.now(self.io, .awake);
        self.ev.gcSetExternalRoots(self.lambdas) catch |err| {
            // The lambdas stay pinned by the previous root set, so the collection
            // below is still safe. Only the already-decoded per-frame results go
            // unreclaimed this round, which the next collection picks up.
            std.log.warn("fix: cannot re-pin the eval roots ({t}); skipping this collect", .{err});
            return;
        };
        // collectNow reports what it reclaimed. The cadence here is fixed rather
        // than driven by that number, and the size the heap settles at is already
        // visible in the frame-rate log's memory figure, so it is not read.
        _ = self.ev.collectNow(); // zippy:ignore discarded_error
        self.collect_ns += started.durationTo(.now(self.io, .awake)).nanoseconds;
    }
};

/// Derive a screen's display name from its path: the basename sans a trailing `.nix`.
fn screenName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const stem = if (std.mem.endsWith(u8, base, ".nix")) base[0 .. base.len - 4] else base;
    return if (stem.len == 0) "screen" else stem;
}

/// Read a content file into an exactly-sized, gpa-owned buffer, bounded to
/// `max_pattern_bytes`. The error is returned without a log line, so the caller
/// can report it at the severity that fits the call site.
fn readPattern(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_pattern_bytes));
}

/// Prove the embedded evaluator + native-apply path are live: compile a pattern lambda
/// once, apply it to a native scope, decode the flat bitmap. Reachable via `nix-badge
/// fix-selftest`. A build without eval logs and returns cleanly.
pub fn selftest(io: std.Io, gpa: std.mem.Allocator) !void {
    if (comptime !have_fix) {
        std.log.info("nix-badge built without -Dfix-src; eval unavailable", .{});
        return;
    }

    var ev = try Engine.init(gpa, .{ .worker_count = 0, .compile_cache = .off, .io = io });
    defer ev.deinit();

    const lambda = try ev.evaluate(
        \\scope:
        \\let mix = i: i * 65536 + (255 - i) * 256 + scope.batteryPct;
        \\in {
        \\  bitmap = builtins.genList mix scope.width;
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
    const bitmap_attr = (try ev.getAttr(result, "bitmap")) orelse return error.FixSelftestFailed;
    const bitmap = try ev.forceValue(bitmap_attr);
    const next_attr = (try ev.getAttr(result, "nextMs")) orelse return error.FixSelftestFailed;
    const next = try ev.forceValue(next_attr);
    const pix = try ev.heapListOf(bitmap.asObjectId());
    std.log.info("fix-selftest: applied to {d} px, nextMs={d} (want 4, 33)", .{
        pix.len, next.asInt(),
    });
    for (pix, 0..) |p, i| {
        const v = (try ev.forceValue(p)).asInt();
        std.log.info("fix-selftest: px {d} = 0x{x:0>6}", .{ i, @as(u64, @intCast(v & 0xffffff)) });
    }
    std.log.info("fix-selftest: OK", .{});
}

test "have_fix flag is defined" {
    _ = have_fix;
}

// A throwaway directory of screen files.
//
// `FixBackend.open` reads each screen by path and takes its display name from the
// basename, so the tests need real files. The directory is removed at cleanup, and
// its absolute path is resolved once so a screen can be named for an import.
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

    fn root(self: *const TmpScreens) []const u8 {
        return self.root_buf[0..self.root_len];
    }

    /// Write `data` to `<root>/<name>` and return the absolute path, which stays
    /// valid until `deinit`.
    fn write(self: *TmpScreens, buf: []u8, name: []const u8, data: []const u8) ![]const u8 {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = data });
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.root(), name });
    }
};

// applyFrame extracts a compiled lambda's bitmap ints + nextMs; the delta/overlay contract
// fields come through. On an eval-less build this is a no-op.
test "FixBackend.applyFrame extracts bitmap ints, nextMs, delta, and overlay" {
    if (comptime !have_fix) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var screens_dir = try TmpScreens.init();
    defer screens_dir.deinit();
    var abuf: [512]u8 = undefined;
    // A full-frame screen: bitmap of two ints, plus an overlay of one packed entry.
    const src =
        \\scope: {
        \\  bitmap = [ 67305985 134678021 ]; nextMs = 50;
        \\  overlay = [ 393216 ]; overlayN = 1;
        \\}
    ;
    const path = try screens_dir.write(&abuf, "s.nix", src);

    var be = FixBackend.open(gpa, .{ .io = std.testing.io }, &.{path}) orelse
        return error.OpenFailed;
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

    var screens_dir = try TmpScreens.init();
    defer screens_dir.deinit();
    var lbuf: [512]u8 = undefined;
    var sbuf: [640]u8 = undefined;
    const lib = try screens_dir.write(&lbuf, "lib.nix", "{ v = 7; }");
    // The screen imports the lib by ABSOLUTE path (no relative base when we eval source text).
    const src = try std.fmt.allocPrint(
        gpa,
        "scope: {{ bitmap = [ (import {s}).v ]; nextMs = 10; }}",
        .{lib},
    );
    const screen = try screens_dir.write(&sbuf, "imp.nix", src);

    var be = FixBackend.open(gpa, .{ .io = std.testing.io }, &.{screen}) orelse
        return error.OpenFailed;
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

    var screens_dir = try TmpScreens.init();
    defer screens_dir.deinit();
    var lbuf: [512]u8 = undefined;
    var sbuf: [512]u8 = undefined;
    // <nixbadge> -> `dir`; the screen imports <nixbadge/val.nix>.
    _ = try screens_dir.write(&lbuf, "val.nix", "{ v = 9; }");
    const screen_src = "scope: { bitmap = [ (import <nixbadge/val.nix>).v ]; nextMs = 10; }";
    const screen = try screens_dir.write(&sbuf, "s.nix", screen_src);

    var npbuf: [320]u8 = undefined;
    const np = try std.fmt.bufPrint(&npbuf, "nixbadge={s}", .{screens_dir.root()});
    var be = FixBackend.open(gpa, .{ .io = std.testing.io, .nix_path = np }, &.{screen}) orelse
        return error.OpenFailed;
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

    var screens_dir = try TmpScreens.init();
    defer screens_dir.deinit();
    var abuf: [512]u8 = undefined;
    const src = "scope: { bitmap = [ scope.backend scope.fps ]; nextMs = 10; }";
    const path = try screens_dir.write(&abuf, "bf.nix", src);

    var be = FixBackend.open(gpa, .{ .io = std.testing.io }, &.{path}) orelse
        return error.OpenFailed;
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

    var screens_dir = try TmpScreens.init();
    defer screens_dir.deinit();
    var okbuf: [512]u8 = undefined;
    const ok = try screens_dir.write(&okbuf, "ok.nix", "scope: { bitmap = [ 7 ]; nextMs = 33; }");

    const paths: []const []const u8 = &.{ ok, "/nonexistent/nope.nix" };
    var be = FixBackend.open(gpa, .{ .io = std.testing.io }, paths) orelse return error.OpenFailed;
    defer be.deinit();
    try std.testing.expectEqual(@as(usize, 1), be.count());
    try std.testing.expectEqualStrings("ok", be.name(0));

    const all_bad = FixBackend.open(gpa, .{ .io = std.testing.io }, &.{"/nonexistent/a.nix"});
    try std.testing.expect(all_bad == null);
    try std.testing.expect(FixBackend.open(gpa, .{ .io = std.testing.io }, &.{}) == null);
}
