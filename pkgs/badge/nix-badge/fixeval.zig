//! fixeval: the badge's embedded Nix evaluator (psyclyx/fix's fetch-less `expr`,
//! aarch64 only; the riscv core builds eval-less and uses the computed/blob paths).
//!
//! Per-frame content eval. A pattern/screen is a pure Nix function
//!     scope: { bitmap = [ <int> ... ]; nextMs = <int>; }
//! where `bitmap` is a flat list of small packed ints (LED: one 0xRRGGBB per
//! pixel) and `nextMs` is how long until the next call. The function is compiled
//! ONCE to a lambda (`Pattern.open`), then applied every frame to a freshly-built
//! `scope` attrset via the native `Engine.applyValue`/`Engine.makeAttrs` patch --
//! NO source recompile, so fix mints no new chunk per frame (chunks are permanent
//! GC roots and are never collected; compile-per-frame would leak). The Value-heap
//! garbage (the scope, the result attrset, the bitmap list) is reclaimed by a
//! young-gated `collectNow()` on a cadence.
//!
//! Whether eval is compiled in is a build-time decision (`build_options.have_fix`,
//! set from `-Dfix-src`). Without it every method is a no-op / null so the eval-less
//! (riscv) build keeps working on the computed patterns.

const std = @import("std");
const build_options = @import("build_options");
const linux = @import("linux.zig");
const ws2812 = @import("ws2812.zig");

const Rgb = ws2812.Rgb;

/// True when `-Dfix-src` supplied a fix source and `expr` was linked in.
pub const have_fix = build_options.have_fix;

// `expr`/`runtime` only exist in the build graph when have_fix; alias to void
// otherwise so the gated methods still type-check on an eval-less build.
const expr = if (have_fix) @import("expr") else struct {};
const Engine = if (have_fix) expr.Engine else void;
const Value = if (have_fix) @import("runtime").value.Value else void;

/// Largest pattern source we read. A live LED pattern is ~1 KiB, but a baked
/// frame-list (Bad Apple: ~400 frames = 392 KiB at 20 s, ~6 MiB for the full
/// song) is the outlier -- size for that. The scratch buffer is transient (freed
/// after the source is duped to its real size), so this only caps a one-shot
/// allocation at Pattern.open.
pub const max_pattern_bytes = 8 * 1024 * 1024;

/// The per-frame inputs fed to a content function's `scope`. `t_ms` changes every
/// frame; the sensor block is refreshed by the caller on a slow tick (battery is
/// a median-of-33 ADC read) and carried unchanged between refreshes. `brightness`
/// is NOT passed to Nix -- it is applied after eval with `ws2812.scaleChannel`, so
/// patterns always emit full-range 0..255 channels.
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
};

/// A compiled-once Nix content function plus the fix Engine that owns it. `open`
/// reads + compiles the pattern to a lambda (pinned as an external GC root);
/// `render` applies it to a per-frame scope and decodes the packed bitmap.
pub const Pattern = struct {
    gpa: std.mem.Allocator,
    ev: Engine,
    // The pattern source, kept alive because compiled chunks reference it for
    // error spans; freed in `deinit`.
    text: []u8,
    lambda: Value,
    frame: u64 = 0,
    logged_error: bool = false,

    /// Reclaim young Value garbage every this many frames. Native apply mints no
    /// chunks, so the young Value heap is the only growth, and the collection is
    /// O(young) -- cheap. Not every frame (that is dominated by GC bookkeeping).
    pub const collect_every: u64 = 64;

    /// Read the pattern at `path`, stand up a single-threaded Engine, and compile
    /// the pattern to a lambda ONCE. Returns null (logged) on any failure or when
    /// eval is unavailable, so the painter falls back to the computed/blob path.
    pub fn open(gpa: std.mem.Allocator, path: []const u8) ?Pattern {
        if (comptime !have_fix) {
            std.log.info("leds: eval pattern requested but unavailable on this arch", .{});
            return null;
        }
        const text = readPattern(gpa, path) orelse return null;
        // compile_cache = .off: a persistent cross-run disk chunk cache is useless
        // for a single embedded pattern (compiled once), and `.auto` probes
        // XDG_CACHE_HOME the service does not set. Skip it.
        var ev = Engine.init(gpa, .{ .worker_count = 0, .compile_cache = .off }) catch |err| {
            std.log.err("leds: eval engine init failed: {s}", .{@errorName(err)});
            gpa.free(text);
            return null;
        };
        const lambda = ev.evaluate(text) catch |err| {
            std.log.err("leds: eval pattern {s} did not compile: {s}", .{ path, @errorName(err) });
            ev.deinit();
            gpa.free(text);
            return null;
        };
        // isNixClosure covers both a capture-free `function` (ChunkId payload)
        // and a heap `closure` (a lambda whose body has `let` bindings / captures
        // -- e.g. leds-live.nix). isFunction alone rejects the latter.
        if (!lambda.isNixClosure()) {
            std.log.err("leds: eval pattern {s} is not a function", .{path});
            ev.deinit();
            gpa.free(text);
            return null;
        }
        // Pin the lambda so a collection between frames cannot sweep it.
        ev.gcSetExternalRoots(&.{lambda}) catch |err| {
            std.log.err("leds: eval root pin failed: {s}", .{@errorName(err)});
            ev.deinit();
            gpa.free(text);
            return null;
        };
        std.log.info("leds: eval pattern {s} ({d} bytes) compiled once", .{ path, text.len });
        return .{ .gpa = gpa, .ev = ev, .text = text, .lambda = lambda };
    }

    pub fn deinit(self: *Pattern) void {
        if (comptime !have_fix) return;
        self.ev.deinit();
        self.gpa.free(self.text);
    }

    /// One applied frame: the forced `bitmap` list values and the raw `nextMs`
    /// int. The two decoders (`render` for LEDs, `renderOled` for page-bytes)
    /// share this; each reads `bitmap` its own way, THEN calls `finishFrame` so
    /// the young-Value collection never runs while a decoder is still reading the
    /// bitmap ints out of the Value heap.
    const Frame = struct {
        bitmap: []const Value,
        next_ms: i64,
    };

    /// Build the per-frame `scope`, apply the compiled lambda, and force the
    /// `{ bitmap = [ints]; nextMs; }` result into a `Frame`. Mints NO new chunk
    /// (native apply runs the pre-compiled body). The returned bitmap slice points
    /// into the Value heap and stays valid until `finishFrame` collects.
    fn applyFrame(self: *Pattern, fields: Fields) !Frame {
        // Build the scope attrset natively -- inline ints/floats/bool, no chunk,
        // no heap-member rooting. camelCase, matching the content contract.
        const scope = try self.ev.makeAttrs(&.{
            .{ .name = "t", .value = Value.int(@intCast(fields.t_ms)) },
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

        // Native apply: runs the pre-compiled chunk, mints NO new chunk.
        const result = try self.ev.applyValue(self.lambda, scope);
        if (result.kind() != .attrs) return error.PatternNotAttrs;

        const bitmap = try self.ev.forceValue((try self.ev.getAttr(result, "bitmap")) orelse return error.MissingBitmap);
        const next = try self.ev.forceValue((try self.ev.getAttr(result, "nextMs")) orelse return error.MissingNextMs);
        if (bitmap.kind() != .list) return error.BitmapNotList;

        const pix = try self.ev.heapListOf(bitmap.asObjectId());
        return .{ .bitmap = pix, .next_ms = next.asInt() };
    }

    /// Advance the frame counter, collect young Value garbage on the cadence (the
    /// scope, result attrset, and bitmap list of THIS frame), and clamp the raw
    /// nextMs to a sane frame period. MUST be called only after the caller has
    /// finished reading the bitmap ints -- the collection can sweep them.
    fn finishFrame(self: *Pattern, next_ms: i64) u32 {
        self.frame +%= 1;
        if (self.frame % collect_every == 0) _ = self.ev.collectNow();
        return if (next_ms <= 0) 33 else @intCast(@min(next_ms, @as(i64, 60_000)));
    }

    /// Evaluate one frame: apply the compiled lambda to a native `scope` built
    /// from `fields`, decode the returned `{ bitmap = [0xRRGGBB...]; nextMs; }`
    /// into `out` (brightness-scaled), and return the clamped nextMs hint. On any
    /// eval fault logs ONCE and returns the error so the caller disables eval for
    /// the run and falls back -- never spinning the log every frame.
    pub fn render(self: *Pattern, fields: Fields, out: []Rgb) !u32 {
        if (comptime !have_fix) return error.EvalUnavailable;
        return self.renderInner(fields, out) catch |err| {
            if (!self.logged_error) {
                std.log.err("leds: eval render failed: {s}; falling back to computed", .{@errorName(err)});
                self.logged_error = true;
            }
            return err;
        };
    }

    fn renderInner(self: *Pattern, fields: Fields, out: []Rgb) !u32 {
        if (comptime !have_fix) return error.EvalUnavailable;

        const f = try self.applyFrame(fields);

        const n = @min(f.bitmap.len, out.len);
        for (f.bitmap[0..n], 0..) |p, i| {
            const v = (try self.ev.forceValue(p)).asInt(); // 0xRRGGBB packed
            // `& 0xff` yields 0..255 regardless of sign, so the u8 cast is safe.
            const r: u8 = @intCast((v >> 16) & 0xff);
            const g: u8 = @intCast((v >> 8) & 0xff);
            const b: u8 = @intCast(v & 0xff);
            out[i] = .{
                .r = ws2812.scaleChannel(r, fields.brightness),
                .g = ws2812.scaleChannel(g, fields.brightness),
                .b = ws2812.scaleChannel(b, fields.brightness),
            };
        }
        // A short bitmap leaves the tail LEDs dark, not stale from last frame.
        for (out[n..]) |*px| px.* = .{ .r = 0, .g = 0, .b = 0 };

        return self.finishFrame(f.next_ms); // collect only after the decode
    }

    /// Evaluate one frame for a 1-bit OLED panel: apply the compiled lambda,
    /// decode the returned `{ bitmap = [ints]; nextMs; }` into `out` as SSD1306
    /// page-major GDDRAM bytes, and return the clamped nextMs hint. `out.len` is
    /// `width*height/8` (512 for 128x32). Each bitmap int packs 4 consecutive
    /// page-bytes little-endian: byte 0 = int & 0xff, byte 1 = (int>>8)&0xff, ...
    /// so `out.len/4` ints fill the frame. A short bitmap zero-fills the tail (a
    /// dark panel) rather than leaving last frame's bytes. Logs ONCE on fault.
    pub fn renderOled(self: *Pattern, fields: Fields, out: []u8) !u32 {
        if (comptime !have_fix) return error.EvalUnavailable;
        return self.renderOledInner(fields, out) catch |err| {
            if (!self.logged_error) {
                std.log.err("bling: eval-screen render failed: {s}; dropping eval screen", .{@errorName(err)});
                self.logged_error = true;
            }
            return err;
        };
    }

    fn renderOledInner(self: *Pattern, fields: Fields, out: []u8) !u32 {
        if (comptime !have_fix) return error.EvalUnavailable;

        const f = try self.applyFrame(fields);

        // Each int is 4 page-bytes LE. Decode min(bitmapLen, out.len/4) ints.
        const words = out.len / 4;
        const n = @min(f.bitmap.len, words);
        for (f.bitmap[0..n], 0..) |p, i| {
            const v = (try self.ev.forceValue(p)).asInt();
            out[i * 4 + 0] = @intCast(v & 0xff);
            out[i * 4 + 1] = @intCast((v >> 8) & 0xff);
            out[i * 4 + 2] = @intCast((v >> 16) & 0xff);
            out[i * 4 + 3] = @intCast((v >> 24) & 0xff);
        }
        // Zero any tail the bitmap did not cover (short bitmap or a non-multiple
        // panel size): a dark region, not stale bytes from the previous frame.
        for (out[n * 4 ..]) |*b| b.* = 0;

        return self.finishFrame(f.next_ms); // collect only after the decode
    }
};

/// Read a pattern file (bounded to `max_pattern_bytes`) into a gpa-owned buffer.
fn readPattern(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (comptime !have_fix) return null;
    var pbuf: [512]u8 = undefined;
    const zpath = std.fmt.bufPrintZ(&pbuf, "{s}", .{path}) catch return null;
    const scratch = gpa.alloc(u8, max_pattern_bytes) catch return null;
    defer gpa.free(scratch);
    const used = linux.readFile(zpath, scratch) orelse {
        std.log.err("leds: cannot read eval pattern {s}", .{path});
        return null;
    };
    return gpa.dupe(u8, used) catch null;
}

/// Prove the embedded evaluator + the native-apply path are live: compile a
/// pattern lambda once, apply it to a native scope, and decode the flat bitmap.
/// Reachable via the hidden `nix-badge fix-selftest`. A build without eval logs
/// and returns cleanly.
pub fn selftest(gpa: std.mem.Allocator) !void {
    if (comptime !have_fix) {
        std.log.info("nix-badge built without -Dfix-src; eval unavailable", .{});
        return;
    }

    var ev = try Engine.init(gpa, .{ .worker_count = 0, .compile_cache = .off });
    defer ev.deinit();

    // Compile ONCE: a `scope -> { bitmap = [ints]; nextMs; }` function.
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

    // Apply it to a natively-built scope (no source recompile).
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

// Exercise renderOled's page-byte LE decode on a real compiled Pattern: a lambda
// that returns two known ints must land in the framebuffer as their 4 LE bytes,
// with the untouched tail zeroed. On an eval-less build this test is a no-op.
test "renderOled decodes bitmap ints to page-major LE bytes" {
    if (comptime !have_fix) return;
    // The Engine acquires a worker buffer pool lazily on first evaluate and holds
    // it for its lifetime (fix owns that teardown); back it with an arena so the
    // leak checker sees a clean tree once the arena is released.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var ev = try Engine.init(gpa, .{ .worker_count = 0, .compile_cache = .off });
    // A two-int bitmap with distinct, byte-distinguishable values so a wrong
    // endianness or offset is caught: 0x04030201 and 0x08070605.
    const lambda = try ev.evaluate(
        \\scope: { bitmap = [ 67305985 134678021 ]; nextMs = 50; }
    );
    try std.testing.expect(lambda.isNixClosure());
    try ev.gcSetExternalRoots(&.{lambda});

    // Build the Pattern by hand (open() reads from a path; here we already hold
    // the compiled lambda). text is an empty owned slice so deinit's free is safe.
    var pat: Pattern = .{
        .gpa = gpa,
        .ev = ev,
        .text = try gpa.dupe(u8, ""),
        .lambda = lambda,
    };
    defer pat.deinit();

    var fb: [512]u8 = @splat(0xaa); // preload garbage so the tail-zero is checked
    const next = try pat.renderOled(.{ .width = 128, .height = 32 }, &fb);
    try std.testing.expectEqual(@as(u32, 50), next);

    // int 0x04030201 -> bytes 01 02 03 04 ; int 0x08070605 -> 05 06 07 08.
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, fb[0..8]);
    // Every byte past the two decoded ints is zeroed, not stale 0xaa.
    for (fb[8..]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}
