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
    // Monotonic playback frame counter, injected by ScreenSet (NOT the caller):
    // a delta screen (Bad Apple) indexes its frame list by this instead of by
    // wall-clock `t_ms`, so cumulative deltas are never skipped. Resets to 0 when
    // the active screen changes, so re-entry starts on a keyframe. See `scope.frameIndex`.
    frame_index: u64 = 0,
};

/// The panel region a rendered frame touched, so the caller flushes minimally.
/// A plain struct (no Engine dependency) so it is defined on the eval-less build
/// too, where every screen is `.full`. `full` -> flush the whole panel (a keyframe,
/// or any screen that emits no `delta=true`). Otherwise each page `p` with
/// `col_lo[p] <= col_hi[p]` changed columns `col_lo[p]..col_hi[p]` (inclusive);
/// `col_lo[p] == clean` means page `p` is untouched. See badapple-delta.md.
pub const Dirty = struct {
    /// A 64-row panel is 8 pages; 32-row is 4. Size for the max.
    pub const max_pages = 8;

    full: bool = true,
    /// Per-page bitmap of changed columns: bit c set => column c of this page changed.
    /// SSD1306 panels are <=128 columns, so a u128 holds one bit per column. flushDirty
    /// coalesces the set bits into contiguous runs and flushes each run, so only the
    /// columns that actually changed cross I2C -- not the min..max bounding span, which
    /// over-sent (a page with changes at columns 3 and 120 flushed all 118 between).
    changed: [max_pages]u128 = .{0} ** max_pages,
};

/// One applied+decoded OLED frame: the frame period plus the dirty region.
pub const OledFrame = struct { next_ms: u32, dirty: Dirty };

/// Reclaim young Value garbage every this many frames. Native apply mints no
/// chunks, so the young Value heap is the only growth, and the collection is
/// O(young) -- cheap. Not every frame (that is dominated by GC bookkeeping).
/// Shared by the single-lambda `Pattern` (LEDs) and the N-lambda `ScreenSet`
/// (OLED): both apply a pre-compiled lambda and reclaim on this cadence.
pub const collect_every: u64 = 64;

/// One applied frame: the forced `bitmap` list values and the raw `nextMs` int.
/// The two decoders (`decodeLeds`, `decodeOled`) share this; each reads `bitmap`
/// its own way, THEN the caller collects so the young-Value sweep never runs
/// while a decoder is still reading the bitmap ints out of the Value heap.
const Frame = struct {
    bitmap: []const Value,
    next_ms: i64,
    // Delta contract (OLED only; LEDs never set these). `delta = false` -> `bitmap`
    // is a full frame (4 page-bytes/int LE). `delta = true` -> `bitmap` is `n`
    // change entries packed 2-per-int; `decodeOled` applies them to the persistent
    // framebuffer. Absent attrs default to a full frame, so info screens are
    // unaffected. See badapple-delta.md.
    delta: bool = false,
    n: u32 = 0,
};

/// Build the per-frame `scope` natively, apply the pre-compiled `lambda`, and
/// force the `{ bitmap = [ints]; nextMs; }` result into a `Frame`. Mints NO new
/// chunk (native apply runs the pre-compiled body). The returned bitmap slice
/// points into the Value heap and stays valid until the caller collects. Shared
/// by `Pattern` and `ScreenSet` -- keyed by `(ev, lambda)`, not `self`, so one
/// Engine can drive many lambdas.
fn applyFrame(ev: *Engine, lambda: Value, fields: Fields) !Frame {
    // Build the scope attrset natively -- inline ints/floats/bool, no chunk,
    // no heap-member rooting. camelCase, matching the content contract.
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

    // Native apply: runs the pre-compiled chunk, mints NO new chunk.
    const result = try ev.applyValue(lambda, scope);
    if (result.kind() != .attrs) return error.PatternNotAttrs;

    const bitmap = try ev.forceValue((try ev.getAttr(result, "bitmap")) orelse return error.MissingBitmap);
    const next = try ev.forceValue((try ev.getAttr(result, "nextMs")) orelse return error.MissingNextMs);
    if (bitmap.kind() != .list) return error.BitmapNotList;

    // Optional delta contract. Absent -> full frame (info screens, LED patterns).
    var is_delta = false;
    var n_changes: u32 = 0;
    if (try ev.getAttr(result, "delta")) |d| {
        is_delta = (try ev.forceValue(d)).asBool();
    }
    if (is_delta) {
        if (try ev.getAttr(result, "n")) |nv| {
            const raw = (try ev.forceValue(nv)).asInt();
            if (raw > 0) n_changes = @intCast(@min(raw, @as(i64, std.math.maxInt(u32))));
        }
    }

    const pix = try ev.heapListOf(bitmap.asObjectId());
    return .{ .bitmap = pix, .next_ms = next.asInt(), .delta = is_delta, .n = n_changes };
}

/// Decode a frame's `bitmap` (0xRRGGBB per pixel) into brightness-scaled `Rgb`
/// pixels. A short bitmap leaves the tail LEDs dark, not stale from last frame.
fn decodeLeds(ev: *Engine, f: Frame, brightness: u8, out: []Rgb) !void {
    const n = @min(f.bitmap.len, out.len);
    for (f.bitmap[0..n], 0..) |p, i| {
        const v = (try ev.forceValue(p)).asInt(); // 0xRRGGBB packed
        // `& 0xff` yields 0..255 regardless of sign, so the u8 cast is safe.
        const r: u8 = @intCast((v >> 16) & 0xff);
        const g: u8 = @intCast((v >> 8) & 0xff);
        const b: u8 = @intCast(v & 0xff);
        out[i] = .{
            .r = ws2812.scaleChannel(r, brightness),
            .g = ws2812.scaleChannel(g, brightness),
            .b = ws2812.scaleChannel(b, brightness),
        };
    }
    for (out[n..]) |*px| px.* = .{ .r = 0, .g = 0, .b = 0 };
}

/// Decode a frame's `bitmap` into SSD1306 page-major GDDRAM bytes in `out` (a
/// PERSISTENT framebuffer reused across frames) and return the `Dirty` region.
/// `out.len` is `width*height/8`. Full frame (`delta=false`): 4 page-bytes/int LE,
/// overwrite `out`, zero the tail, dirty = whole panel. Delta (`delta=true`):
/// hand off to `decodeOledDelta`, which mutates `out` in place. `width` splits the
/// linear offset into (page,col) for delta dirty-tracking.
fn decodeOled(ev: *Engine, f: Frame, out: []u8, width: u32) !Dirty {
    if (f.delta) return decodeOledDelta(ev, f, out, width);
    const words = out.len / 4;
    const n = @min(f.bitmap.len, words);
    for (f.bitmap[0..n], 0..) |p, i| {
        const v = (try ev.forceValue(p)).asInt();
        out[i * 4 + 0] = @intCast(v & 0xff);
        out[i * 4 + 1] = @intCast((v >> 8) & 0xff);
        out[i * 4 + 2] = @intCast((v >> 16) & 0xff);
        out[i * 4 + 3] = @intCast((v >> 24) & 0xff);
    }
    for (out[n * 4 ..]) |*b| b.* = 0;
    return .{ .full = true };
}

/// Apply `f.n` packed (offset,byte) change entries to the PERSISTENT framebuffer
/// `out`, and return the per-page dirty column spans so the caller flushes only
/// the changed columns. Two entries per int, first in the high 18 bits:
///   `E = (int >> 18) & 0x3ffff` then `(int & 0x3ffff)`; `offset = E >> 8`,
///   `byte = E & 0xff`. Bounded by `n` (not the int count), so an odd `n`'s unused
/// low half of the last int is ignored. Out-of-range offsets are dropped, never
/// written. See badapple-delta.md.
fn decodeOledDelta(ev: *Engine, f: Frame, out: []u8, width: u32) !Dirty {
    var d: Dirty = .{ .full = false };
    if (width == 0) return d;
    const entry_mask: i64 = 0x3ffff; // 2^18 - 1
    var i: u32 = 0;
    while (i < f.n) : (i += 1) {
        const int_idx = i / 2;
        if (int_idx >= f.bitmap.len) break; // malformed: n claims more ints than emitted
        const v = (try ev.forceValue(f.bitmap[int_idx])).asInt();
        const e: i64 = if (i & 1 == 0) (v >> 18) & entry_mask else v & entry_mask;
        const offset: usize = @intCast(e >> 8);
        if (offset >= out.len) continue; // defensive: never write out of range
        out[offset] = @intCast(e & 0xff);
        const page = offset / width;
        const col = offset % width;
        if (page < Dirty.max_pages and col < 128) {
            d.changed[page] |= @as(u128, 1) << @intCast(col);
        }
    }
    return d;
}

/// Advance a frame counter, collect young Value garbage on the cadence (the
/// scope, result attrset, and bitmap list of THIS frame), and clamp the raw
/// nextMs to a sane frame period. MUST be called only after the caller has
/// finished reading the bitmap ints -- the collection can sweep them.
/// Diagnostic: total nanoseconds spent in `collectNow` since the loop last read+reset
/// it (via `takeCollectNs`). Lets the render loop split the per-frame eval cost into
/// "apply+decode" vs "GC collect" without threading a timer through every call.
pub var collect_ns_accum: i128 = 0;

/// Read and zero the accumulated collect time.
pub fn takeCollectNs() i128 {
    const v = collect_ns_accum;
    collect_ns_accum = 0;
    return v;
}

fn finishFrame(ev: *Engine, frame: *u64, next_ms: i64) u32 {
    frame.* +%= 1;
    if (frame.* % collect_every == 0) {
        const c0 = linux.monotonicNsec();
        _ = ev.collectNow();
        collect_ns_accum += linux.monotonicNsec() - c0;
    }
    return if (next_ms <= 0) 33 else @intCast(@min(next_ms, @as(i64, 60_000)));
}

/// A compiled-once Nix content function plus the fix Engine that owns it. `open`
/// reads + compiles the pattern to a lambda (pinned as an external GC root);
/// `render` applies it to a per-frame scope and decodes the packed bitmap. Used
/// for the LED ring (one pattern per painter). The OLED uses `ScreenSet` (N
/// lambdas, one Engine); both share the `applyFrame`/`decode*`/`finishFrame`
/// helpers above.
pub const Pattern = struct {
    gpa: std.mem.Allocator,
    ev: Engine,
    // The pattern source, kept alive because compiled chunks reference it for
    // error spans; freed in `deinit`.
    text: []u8,
    lambda: Value,
    frame: u64 = 0,
    logged_error: bool = false,

    /// Read the pattern at `path`, stand up a single-threaded Engine, and compile
    /// the pattern to a lambda ONCE. Returns null (logged) on any failure or when
    /// eval is unavailable, so the painter falls back to the computed/blob path.
    pub fn open(gpa: std.mem.Allocator, path: []const u8) ?Pattern {
        if (comptime !have_fix) {
            std.log.info("bling: eval pattern requested but unavailable on this arch", .{});
            return null;
        }
        const text = readPattern(gpa, path) orelse {
            std.log.err("bling: cannot read eval pattern {s}", .{path});
            return null;
        };
        // compile_cache = .off: a persistent cross-run disk chunk cache is useless
        // for a single embedded pattern (compiled once), and `.auto` probes
        // XDG_CACHE_HOME the service does not set. Skip it.
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
        // isNixClosure covers both a capture-free `function` (ChunkId payload)
        // and a heap `closure` (a lambda whose body has `let` bindings / captures
        // -- e.g. leds-live.nix). isFunction alone rejects the latter.
        if (!lambda.isNixClosure()) {
            std.log.err("bling: eval pattern {s} is not a function", .{path});
            ev.deinit();
            gpa.free(text);
            return null;
        }
        // Pin the lambda so a collection between frames cannot sweep it.
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
        self.ev.deinit();
        self.gpa.free(self.text);
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
                std.log.err("bling: eval render failed: {s}; falling back to computed", .{@errorName(err)});
                self.logged_error = true;
            }
            return err;
        };
    }

    fn renderInner(self: *Pattern, fields: Fields, out: []Rgb) !u32 {
        if (comptime !have_fix) return error.EvalUnavailable;
        const f = try applyFrame(&self.ev, self.lambda, fields);
        try decodeLeds(&self.ev, f, fields.brightness, out); // reads bitmap ints
        return finishFrame(&self.ev, &self.frame, f.next_ms); // collect after
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
                std.log.err("oled: eval-screen render failed: {s}; dropping eval screen", .{@errorName(err)});
                self.logged_error = true;
            }
            return err;
        };
    }

    fn renderOledInner(self: *Pattern, fields: Fields, out: []u8) !u32 {
        if (comptime !have_fix) return error.EvalUnavailable;
        const f = try applyFrame(&self.ev, self.lambda, fields);
        _ = try decodeOled(&self.ev, f, out, fields.width); // full-frame only; caller full-flushes
        return finishFrame(&self.ev, &self.frame, f.next_ms); // collect after
    }
};

/// The OLED screen set: ONE fix Engine holding N compiled lambdas, one per
/// screen. Five separate Engines would each carry the ~34-81 MB Value/chunk heap
/// -> OOM on the 351 MB badge; sharing the Engine keeps that cost once. Each
/// lambda is compiled from its own source text (kept alive for error spans), all
/// pinned together in a SINGLE `gcSetExternalRoots` call (it REPLACES the root
/// set, so the whole slice goes in one call). A screen whose source fails to
/// compile is skipped (logged once); if none compile, `open` returns null and
/// the caller falls back to the Zig screens.
pub const ScreenSet = struct {
    gpa: std.mem.Allocator,
    ev: Engine,
    // Parallel arrays, one entry per loaded screen. `lambdas[i]` is compiled from
    // `texts[i]` (owned, kept alive for chunk error spans) and displayed as
    // `names[i]` (owned, derived from the file basename). All freed in `deinit`.
    lambdas: []Value,
    texts: [][]u8,
    names: [][]u8,
    frame: u64 = 0,
    logged_error: bool = false,
    // Playback pacing for delta screens (Bad Apple). `play_idx` is the monotonic
    // frame the active screen is on; it feeds `scope.frameIndex` so cumulative
    // deltas are never skipped. `active_ix` tracks which screen is playing; when it
    // changes, `play_idx` resets to 0 (a keyframe) so re-entry never applies a delta
    // onto a stale framebuffer. See badapple-delta.md.
    play_idx: u64 = 0,
    active_ix: ?usize = null,

    /// Stand up ONE single-threaded Engine, compile each path's source to a
    /// lambda, and pin ALL lambdas at once. Skips (logs once) a path that cannot
    /// be read, does not compile, or is not a function; the rest still load.
    /// Returns null when eval is unavailable (riscv) or NO screen loaded.
    pub fn open(gpa: std.mem.Allocator, paths: []const []const u8) ?ScreenSet {
        if (comptime !have_fix) {
            std.log.info("oled: eval screens requested but unavailable on this arch", .{});
            return null;
        }
        if (paths.len == 0) return null;

        // compile_cache = .off: a persistent cross-run disk chunk cache is useless
        // here (each screen is compiled once at startup) and `.auto` probes an
        // XDG_CACHE_HOME the service does not set. worker_count = 0: single
        // threaded, the badge has no spare cores to burn on eval.
        var ev = Engine.init(gpa, .{ .worker_count = 0, .compile_cache = .off }) catch |err| {
            std.log.err("oled: eval engine init failed: {s}", .{@errorName(err)});
            return null;
        };

        // Accumulate the compiled screens. Grown up-front to `paths.len`; only the
        // slots that actually compiled are kept, so the arrays are trimmed to
        // `count` before pinning.
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
            // A per-screen fault is a WARN, not an err: the screen is skipped but
            // the rest of the set still loads, so the badge shows the others (a
            // hard err would fail the whole set and is reserved for open() itself).
            const text = readPattern(gpa, path) orelse {
                std.log.warn("oled: cannot read eval screen {s}; skipping", .{path});
                continue;
            };
            // NB: screens MUST be self-contained (no `import`). The embedded Engine
            // has no file-I/O backend, so a runtime `import` compiles but faults on
            // force (FileIoUnavailable) -> the screen would render-fault and be
            // dropped. The packaging inlines each screen's deps (draw.nix + font +
            // oled.nix) at build time; badapple-live is likewise self-contained.
            const lambda = ev.evaluate(text) catch |err| {
                std.log.warn(
                    "oled: eval screen {s} did not compile ({s}); skipping",
                    .{ path, @errorName(err) },
                );
                gpa.free(text);
                continue;
            };
            // isNixClosure covers a capture-free `function` and a heap `closure`
            // (a lambda with `let`/captures); isFunction alone rejects the latter.
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
            std.log.info(
                "oled: eval screen {s} ({d} bytes) compiled as '{s}'",
                .{ path, text.len, nm },
            );
        }

        if (loaded == 0) {
            gpa.free(lambdas);
            gpa.free(texts);
            gpa.free(names);
            ev.deinit();
            std.log.warn("oled: no eval screens loaded; falling back to computed screens", .{});
            return null;
        }

        // Trim the arrays to what actually loaded (so deinit frees exactly these).
        lambdas = gpa.realloc(lambdas, loaded) catch lambdas[0..loaded];
        texts = gpa.realloc(texts, loaded) catch texts[0..loaded];
        names = gpa.realloc(names, loaded) catch names[0..loaded];

        // Pin ALL lambdas in ONE call: gcSetExternalRoots REPLACES the root set,
        // so the whole slice must go together or an earlier screen is swept.
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

    /// Evaluate screen `idx` for a 1-bit OLED panel: apply its lambda to the
    /// per-frame scope, decode the packed page-bytes (or deltas) into the PERSISTENT
    /// framebuffer `out`, collect on the cadence, and return the clamped nextMs plus
    /// the `Dirty` region the caller flushes. Selecting among N lambdas, with
    /// per-screen delta pacing. Logs ONCE on fault.
    pub fn renderOled(self: *ScreenSet, idx: usize, fields: Fields, out: []u8) !OledFrame {
        if (comptime !have_fix) return error.EvalUnavailable;
        return self.renderOledInner(idx, fields, out) catch |err| {
            if (!self.logged_error) {
                std.log.err(
                    "oled: eval screen '{s}' render failed: {s}; dropping it",
                    .{ self.names[idx], @errorName(err) },
                );
                self.logged_error = true;
            }
            return err;
        };
    }

    fn renderOledInner(self: *ScreenSet, idx: usize, fields: Fields, out: []u8) !OledFrame {
        if (comptime !have_fix) return error.EvalUnavailable;
        // Screen switch -> restart playback at frame 0 (always a keyframe), so a
        // delta screen never applies a delta onto another screen's stale framebuffer.
        if (self.active_ix == null or self.active_ix.? != idx) {
            self.play_idx = 0;
            self.active_ix = idx;
        }
        var fr = fields;
        fr.frame_index = self.play_idx;
        const f = try applyFrame(&self.ev, self.lambdas[idx], fr);
        const dirty = try decodeOled(&self.ev, f, out, fr.width); // reads bitmap ints
        const next_ms = finishFrame(&self.ev, &self.frame, f.next_ms); // collect after
        self.play_idx +%= 1;
        return .{ .next_ms = next_ms, .dirty = dirty };
    }
};

/// Derive a screen's display name from its path: the basename with a trailing
/// `.nix` stripped (`.../battery.nix` -> `battery`). An empty result (a path that
/// is all slashes) falls back to "screen".
fn screenName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const stem = if (std.mem.endsWith(u8, base, ".nix")) base[0 .. base.len - 4] else base;
    return if (stem.len == 0) "screen" else stem;
}

/// Read a pattern file (bounded to `max_pattern_bytes`) into a gpa-owned buffer.
/// Returns null on any read fault WITHOUT logging -- the caller knows whether an
/// unreadable file is fatal (a single LED pattern -> the run falls back) or just
/// one skipped screen among many (a ScreenSet), and logs at the right severity.
fn readPattern(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (comptime !have_fix) return null;
    var pbuf: [512]u8 = undefined;
    const zpath = std.fmt.bufPrintZ(&pbuf, "{s}", .{path}) catch return null;
    const scratch = gpa.alloc(u8, max_pattern_bytes) catch return null;
    defer gpa.free(scratch);
    const used = linux.readFile(zpath, scratch) orelse return null;
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

// A fresh per-test temp dir under /tmp so the screen files keep CLEAN basenames
// (screenName derives the display name from the basename, so a unique suffix must
// live in the DIR, not the filename). Built once per test off the monotonic clock.
fn tmpScreenDir(buf: []u8) ![:0]const u8 {
    const dir = try std.fmt.bufPrintZ(buf, "/tmp/nbtest-{d}", .{linux.monotonicMsec()});
    // .created / .exists are both fine; a real .failed surfaces at writeFile below
    // (the test errors there), so no need to branch on it here.
    switch (linux.mkdir(dir.ptr, 0o755)) {
        .created, .exists, .failed => {},
    }
    return dir;
}

// Write `data` to `<dir>/<name>` (a NUL-terminated path) so ScreenSet.open, which
// reads via linux.readFile (the runtime path), can open it. Returns the path slice
// into `buf`. Uses the codebase's own linux.writeFile rather than
// std.fs.Dir.writeFile (whose signature shifts across zig versions).
fn writeTmpScreen(buf: []u8, dir: []const u8, name: []const u8, data: []const u8) ![]const u8 {
    const path = try std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, name });
    try linux.writeFile(path.ptr, data);
    return path; // sentinel-terminated slice; usable as []const u8 too
}

// Prove ONE Engine holds N lambdas: open a ScreenSet of two distinct inline
// screens (written to temp files, opened by path), then render EACH into its own
// framebuffer. The two lambdas must decode to different bytes (so they are truly
// separate compiled functions sharing one Engine), each screen's nextMs must come
// through, and the derived names must be the file basenames. On an eval-less build
// this test is a no-op.
test "ScreenSet holds N lambdas in one engine and renders each" {
    if (comptime !have_fix) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // Two tiny screens, each keying its first bitmap int off a distinct scope
    // field so the apply is exercised (not a constant): "alpha.nix" emits
    // batteryPct, "beta.nix" emits cpuPct+1000.
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

    // Both screens loaded into the one Engine, named by basename.
    try std.testing.expectEqual(@as(usize, 2), set.count());
    try std.testing.expectEqualStrings("alpha", set.name(0));
    try std.testing.expectEqualStrings("beta", set.name(1));

    // Render screen 0: bitmap[0] = batteryPct (87) -> LE bytes 87,0,0,0.
    var fb0: [512]u8 = @splat(0xaa);
    const n0 = try set.renderOled(0, .{ .width = 128, .height = 32, .battery_pct = 87 }, &fb0);
    try std.testing.expectEqual(@as(u32, 111), n0);
    try std.testing.expectEqualSlices(u8, &.{ 87, 0, 0, 0 }, fb0[0..4]);
    for (fb0[4..]) |b| try std.testing.expectEqual(@as(u8, 0), b);

    // Render screen 1 from the SAME set/Engine: bitmap[0] = cpuPct+1000 = 1042 =
    // 0x412 -> LE bytes 0x12,0x04,0,0. A different result proves it applied the
    // OTHER lambda, not screen 0's.
    var fb1: [512]u8 = @splat(0xaa);
    const n1 = try set.renderOled(1, .{ .width = 128, .height = 32, .cpu_pct = 42 }, &fb1);
    try std.testing.expectEqual(@as(u32, 222), n1);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x04, 0, 0 }, fb1[0..4]);

    // Re-render screen 0 after screen 1 to confirm the lambdas stay independent
    // (one Engine, two pinned roots -- neither swept the other).
    var fb0b: [512]u8 = @splat(0xaa);
    _ = try set.renderOled(0, .{ .width = 128, .height = 32, .battery_pct = 5 }, &fb0b);
    try std.testing.expectEqualSlices(u8, &.{ 5, 0, 0, 0 }, fb0b[0..4]);
}

// A ScreenSet where one path is unreadable/bad must still load the good screens
// (skip + log the bad one), and a set of all-bad paths returns null.
test "ScreenSet skips a bad screen but loads the rest" {
    if (comptime !have_fix) return;
    // This test deliberately feeds bad paths, so ScreenSet.open emits the
    // expected "skipping"/"no eval screens" WARNs. Raise the test log threshold to
    // .err for the duration so those expected warnings do not clutter test output
    // (warns are not counted as failures, but the noise is misleading).
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

    // "ok.nix" compiles; the missing path is skipped. One screen survives.
    const paths: []const []const u8 = &.{ ok, "/nonexistent/nope.nix" };
    var set = ScreenSet.open(gpa, paths) orelse return error.ScreenSetOpenFailed;
    defer set.deinit();
    try std.testing.expectEqual(@as(usize, 1), set.count());
    try std.testing.expectEqualStrings("ok", set.name(0));

    // All-bad -> null (the caller then keeps the Zig screens).
    try std.testing.expect(ScreenSet.open(gpa, &.{"/nonexistent/a.nix"}) == null);
    try std.testing.expect(ScreenSet.open(gpa, &.{}) == null);
}

// The badge-critical path: the real info screens are shipped SELF-CONTAINED (the
// screens-install package inlines draw.nix + the font + oled.nix at build time)
// because the embedded Engine has NO file-I/O backend, so a runtime `import` would
// fault. This test proves a self-contained screen SHAPED like the inlined ones --
// a `let` block of "font"-like data looked up per frame, NO imports, over
// ~800 bytes of source -- compiles once and renders through ScreenSet, so the
// inlined screens will run on the badge. (The screens-install package's own build
// asserts the emitted screens contain no `import` and still eval to a valid frame.)
test "ScreenSet renders a self-contained (inlined-shape) screen" {
    if (comptime !have_fix) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var dbuf: [256]u8 = undefined;
    const dir = try tmpScreenDir(&dbuf);

    // A self-contained screen with an inlined "table" + helper (mimicking the
    // font/draw let-bindings the real screens carry) looked up per frame -- no
    // imports. Picks table entry batteryPct%4 into bitmap[0]: for batteryPct=87,
    // 87%4=3 -> 515 = 0x0203 -> LE bytes 03 02.
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
    try std.testing.expectEqual(@as(u32, 77), next);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x02, 0, 0 }, fb[0..4]);
}
