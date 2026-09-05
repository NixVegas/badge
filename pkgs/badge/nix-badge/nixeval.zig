//! nixeval: the upstream Nix C API evaluator backend, a second evaluator beside
//! fix so the two can be compared on the same content.
//!
//! It has the same compile-once and apply-per-frame shape as fixeval. `open`
//! evaluates each screen to a lambda once. Every frame builds a `scope` attrset
//! with a BindingsBuilder, calls the lambda, forces the result, and reads the
//! `bitmap` list into a plain `[]i64` for the shared decode in eval.zig. The store
//! is `dummy://`, because pure evaluation needs no real Nix store.
//!
//! The C++ `libnixexpr` is linked in through pkg-config; see build.zig. Without
//! it `have_nix` is false, `open` returns null, and the caller falls back to fix.
//!
//! Error discipline: every C API call reports failure through a `nix_err` return
//! code. `check` turns one into a Zig error, so no call here can fail unnoticed.
//! `release` handles reference-count drops, whose failure would mean this file
//! miscounted a reference, which is a programmer error rather than a runtime one.

const std = @import("std");
const build_options = @import("build_options");
const eval = @import("eval.zig");

/// True when the Nix C API was linked in. It is available on aarch64 only.
pub const have_nix = build_options.have_nix;

// The C API only exists in the link when have_nix. Alias it to an empty struct
// otherwise, so the gated bodies below are statically unreachable and are never
// analysed on a build without it.
const c = if (have_nix) @cImport({
    @cInclude("nix_api_util.h");
    @cInclude("nix_api_store.h");
    @cInclude("nix_api_expr.h");
    @cInclude("nix_api_value.h");
}) else struct {};

// The C API handle types, aliased to a placeholder on a build without nix so the
// struct fields and method signatures still type-check.
const NixContext = if (have_nix) c.nix_c_context else anyopaque;
const NixState = if (have_nix) c.EvalState else anyopaque;
const NixStore = if (have_nix) c.Store else anyopaque;

/// A managed nix value pointer.
///
/// `nix_value` is an opaque C type, so translate-c renders `nix_value *` as a
/// single-item `?*nix_value`. A `[*c]` many-pointer to an opaque type of unknown
/// size is rejected.
const ValuePtr = if (have_nix) ?*c.nix_value else ?*anyopaque;

/// The largest content source this backend reads, matching fixeval's limit.
const max_pattern_bytes = 8 * 1024 * 1024;

/// What can go wrong inside this backend. `NixCall` covers any C API call that
/// reported a failure code; the C API keeps the detailed message on its context.
pub const NixError = error{
    NixCall,
    CallFailed,
    PatternNotAttrs,
    MissingBitmap,
    MissingNextMs,
    BitmapNotList,
    ListElemNull,
    EvalUnavailable,
};

// The C API's return code type, aliased so the helpers below still have a valid
// signature on a build without nix.
const NixErr = if (have_nix) c.nix_err else c_int;
const nix_ok: NixErr = if (have_nix) c.NIX_OK else 0;

/// Turn a C API return code into a Zig error, so a failed call cannot pass
/// unnoticed.
fn check(rc: NixErr) NixError!void {
    if (rc != nix_ok) return error.NixCall;
}

/// Drop a reference this file owns. A failure here would mean this file
/// miscounted a reference, which is a bug in this file and not a runtime fault,
/// so it is asserted rather than returned.
fn release(ctx: ?*NixContext, value: ValuePtr) void {
    if (comptime !have_nix) return;
    std.debug.assert(c.nix_value_decref(ctx, value) == c.NIX_OK);
}

/// Grow `ints.*` to hold at least `need` integers. The first allocation is
/// separate from the growth path, because the `&.{}` default is not owned by the
/// allocator and must not be passed to `realloc`.
fn ensureInts(gpa: std.mem.Allocator, ints: *[]i64, need: usize) !void {
    if (ints.len >= need) return;
    ints.* = if (ints.len == 0) try gpa.alloc(i64, need) else try gpa.realloc(ints.*, need);
}

/// A screen's display name: the file's basename without a trailing `.nix`.
fn screenName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const stem = if (std.mem.endsWith(u8, base, ".nix")) base[0 .. base.len - 4] else base;
    return if (stem.len == 0) "screen" else stem;
}

/// Prove the Nix C API links and evaluates: compile `scope: scope.t + 1` once,
/// apply it to `{ t = 41; }`, and check that the result is 42. This is reachable
/// as `nix-badge nix-selftest` and is the first real exercise of the C++ link.
pub fn selftest() bool {
    if (comptime !have_nix) {
        std.log.info("nix-badge was built without the Nix C API backend", .{});
        return false;
    }
    selftestInner() catch |err| {
        std.log.err("nix-selftest failed: {t}", .{err});
        return false;
    };
    return true;
}

fn selftestInner() !void {
    const ctx = c.nix_c_context_create();
    defer c.nix_c_context_free(ctx);
    try check(c.nix_libexpr_init(ctx));

    const store = c.nix_store_open(ctx, "dummy://", null) orelse return error.NixCall;
    defer c.nix_store_free(store);
    const state = c.nix_state_create(ctx, null, store) orelse return error.NixCall;
    defer c.nix_state_free(state);

    // Compile the lambda once, the way a backend does at open.
    const fn_val = c.nix_alloc_value(ctx, state);
    defer release(ctx, fn_val);
    try check(c.nix_expr_eval_from_string(ctx, state, "scope: scope.t + 1", ".", fn_val));

    // scope = { t = 41; }
    const t = c.nix_alloc_value(ctx, state);
    defer release(ctx, t);
    try check(c.nix_init_int(ctx, t, 41));
    const bb = c.nix_make_bindings_builder(ctx, state, 1);
    defer c.nix_bindings_builder_free(bb);
    try check(c.nix_bindings_builder_insert(ctx, bb, "t", t));
    const scope = c.nix_alloc_value(ctx, state);
    defer release(ctx, scope);
    try check(c.nix_make_attrs(ctx, scope, bb));

    const res = c.nix_alloc_value(ctx, state);
    defer release(ctx, res);
    try check(c.nix_value_call(ctx, state, fn_val, scope, res));
    try check(c.nix_value_force(ctx, state, res));

    const got = c.nix_get_int(ctx, res);
    std.log.info("nix-selftest: (scope: scope.t + 1) {{ t = 41; }} = {d} (want 42)", .{got});
    if (got != 42) return error.CallFailed;
}

/// The upstream Nix C API evaluator backend, with the same surface as
/// `fixeval.FixBackend` so `backend.Backend` can hold either one.
///
/// One `EvalState` over a `dummy://` store holds N compiled lambdas. Each frame
/// builds a `scope` attrset with a BindingsBuilder, calls the lambda, and forces
/// the `bitmap`, and any `overlay`, into a reused `[]i64` for the shared decode.
/// The value heap is Boehm collected, so `collect` does nothing.
///
/// Reference discipline: every `nix_value *` this file obtains is released once it
/// has been read, so per-frame temporaries do not accumulate as permanent roots.
/// Only the compiled lambdas stay rooted, and their references are released in
/// `deinit`.
pub const NixBackend = struct {
    gpa: std.mem.Allocator,
    ctx: ?*NixContext = null,
    state: ?*NixState = null,
    store: ?*NixStore = null,
    lambdas: []ValuePtr = &.{},
    names: [][]u8 = &.{},
    ints: []i64 = &.{},
    overlay_ints: []i64 = &.{},

    /// Start libexpr, open a `dummy://` store and an eval state, and compile each
    /// path to a lambda that stays rooted. A path that cannot be read, does not
    /// compile, or is not a function is skipped with a log line, and the rest still
    /// load. Returns null when nix is not linked or when no screen loaded.
    ///
    /// `opts.io` is accepted so the signature matches FixBackend, but it is not
    /// used: upstream Nix does its own filesystem access. `opts.nix_path` becomes
    /// the eval state's lookup path, so content can use `<name>` imports the same
    /// way it does under fix.
    pub fn open(gpa: std.mem.Allocator, opts: eval.Opts, paths: []const []const u8) ?NixBackend {
        if (comptime !have_nix) {
            std.log.info("nix: eval requested but the Nix C API is not linked on this arch", .{});
            return null;
        }
        if (paths.len == 0) return null;
        return openInner(gpa, opts, paths) catch |err| switch (err) {
            // Every screen was skipped, and each one already said why. The caller
            // handles an empty set, so this is not a failure of the evaluator.
            error.NoScreensLoaded => {
                std.log.warn("nix: no screens loaded", .{});
                return null;
            },
            else => {
                std.log.err("nix: cannot open the evaluator: {t}", .{err});
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
    ) !NixBackend {
        const ctx = c.nix_c_context_create();
        errdefer c.nix_c_context_free(ctx);
        try check(c.nix_libexpr_init(ctx));

        const store = c.nix_store_open(ctx, "dummy://", null) orelse return error.NixCall;
        errdefer c.nix_store_free(store);

        // The lookup path is a null-terminated array of "name=path" entries. Nix
        // copies them, so a stack array and one temporary duplicate are enough.
        var lookup_storage: [2][*c]const u8 = @splat(null);
        var nix_path_z: ?[:0]u8 = null;
        defer if (nix_path_z) |z| gpa.free(z);
        if (opts.nix_path) |np| {
            nix_path_z = try gpa.dupeZ(u8, np);
            lookup_storage[0] = nix_path_z.?.ptr;
        }
        const lookup: [*c][*c]const u8 = if (nix_path_z != null) &lookup_storage else null;

        const state = c.nix_state_create(ctx, lookup, store) orelse return error.NixCall;
        errdefer c.nix_state_free(state);

        var lambdas = try gpa.alloc(ValuePtr, paths.len);
        errdefer gpa.free(lambdas);
        var names = try gpa.alloc([]u8, paths.len);
        errdefer gpa.free(names);

        var loaded: usize = 0;
        errdefer for (lambdas[0..loaded], names[0..loaded]) |l, n| {
            release(ctx, l);
            gpa.free(n);
        };
        for (paths) |path| {
            // Nix parses the source into its own AST, so the text can go right
            // after. It must be NUL-terminated, because the C API takes a `char *`.
            const src = std.Io.Dir.cwd().readFileAllocOptions(
                opts.io,
                path,
                gpa,
                .limited(max_pattern_bytes),
                .of(u8),
                0,
            ) catch |err| {
                std.log.warn("nix: cannot read eval screen {s} ({t}); skipping", .{ path, err });
                continue;
            };
            defer gpa.free(src);

            const fn_val = c.nix_alloc_value(ctx, state);
            if (loadLambda(ctx, state, src, fn_val)) |_| {} else |err| {
                std.log.warn("nix: screen {s} is not a usable function ({t}); skipping", .{
                    path, err,
                });
                release(ctx, fn_val);
                continue;
            }
            const nm = gpa.dupe(u8, screenName(path)) catch |err| {
                release(ctx, fn_val);
                return err;
            };
            // The allocation reference is kept, so fn_val stays a rooted value for
            // the backend's life and survives every collection between frames.
            lambdas[loaded] = fn_val;
            names[loaded] = nm;
            loaded += 1;
            std.log.info("nix: eval screen {s} compiled as '{s}'", .{ path, nm });
        }
        if (loaded == 0) return error.NoScreensLoaded;

        // Shrinking cannot fail in practice, and if it does the oversized buffer is
        // still correct, so keep the original and use only the loaded prefix.
        lambdas = gpa.realloc(lambdas, loaded) catch lambdas[0..loaded];
        names = gpa.realloc(names, loaded) catch names[0..loaded];

        std.log.info("nix: {d} eval screen(s) loaded into one state", .{loaded});
        return .{
            .gpa = gpa,
            .ctx = ctx,
            .state = state,
            .store = store,
            .lambdas = lambdas,
            .names = names,
        };
    }

    /// Evaluate one screen's source and confirm the result is a function.
    fn loadLambda(ctx: ?*NixContext, state: ?*NixState, src: [:0]const u8, out: ValuePtr) !void {
        try check(c.nix_expr_eval_from_string(ctx, state, src.ptr, ".", out));
        try check(c.nix_value_force(ctx, state, out));
        if (c.nix_get_type(ctx, out) != c.NIX_TYPE_FUNCTION) return error.PatternNotAttrs;
    }

    pub fn deinit(self: *NixBackend) void {
        if (comptime !have_nix) return;
        for (self.lambdas) |l| release(self.ctx, l);
        for (self.names) |nm| self.gpa.free(nm);
        self.gpa.free(self.lambdas);
        self.gpa.free(self.names);
        if (self.ints.len > 0) self.gpa.free(self.ints);
        if (self.overlay_ints.len > 0) self.gpa.free(self.overlay_ints);
        if (self.state) |s| c.nix_state_free(s);
        if (self.store) |s| c.nix_store_free(s);
        if (self.ctx) |x| c.nix_c_context_free(x);
    }

    pub fn count(self: *const NixBackend) usize {
        return self.lambdas.len;
    }

    pub fn name(self: *const NixBackend, idx: usize) []const u8 {
        return self.names[idx];
    }

    /// Boehm manages the value heap, so there is no per-frame sweep to run.
    pub fn collect(self: *NixBackend) void {
        _ = self;
    }

    /// Allocate one nix value holding `v`. The C API has a separate initialiser per
    /// type, so the right one is selected at comptime from `v`'s Zig type. The
    /// caller owns the returned reference.
    fn newValue(self: *NixBackend, v: anytype) !ValuePtr {
        const val = c.nix_alloc_value(self.ctx, self.state);
        errdefer release(self.ctx, val);
        const T = @TypeOf(v);
        switch (@typeInfo(T)) {
            .bool => try check(c.nix_init_bool(self.ctx, val, v)),
            .int, .comptime_int => try check(c.nix_init_int(self.ctx, val, @intCast(v))),
            .float, .comptime_float => try check(c.nix_init_float(self.ctx, val, @floatCast(v))),
            .pointer => try check(c.nix_init_string(self.ctx, val, v)),
            else => @compileError("no nix initialiser for " ++ @typeName(T)),
        }
        return val;
    }

    /// Build one frame's `scope` attrset.
    ///
    /// The entry table is the single source of truth for the scope: the builder
    /// capacity and the temporary-value array both derive from its length, so they
    /// cannot drift apart from the entries themselves. Every member is released
    /// once `nix_make_attrs` has copied it into the bindings.
    fn buildScope(self: *NixBackend, fields: eval.Fields) !ValuePtr {
        const entries = .{
            .{ "t", @as(i64, @intCast(fields.t_ms)) },
            .{ "frameIndex", @as(i64, @intCast(fields.frame_index)) },
            .{ "width", @as(i64, fields.width) },
            .{ "height", @as(i64, fields.height) },
            .{ "batteryMv", @as(i64, fields.battery_mv) },
            .{ "batteryPct", @as(i64, fields.battery_pct) },
            .{ "onUsb", fields.on_usb },
            .{ "load1", fields.load1 },
            .{ "cpuPct", @as(i64, fields.cpu_pct) },
            .{ "memPct", @as(i64, fields.mem_pct) },
            .{ "uptimeS", @as(i64, fields.uptime_s) },
            .{ "backend", @as(i64, fields.backend_id) },
            .{ "fps", @as(i64, fields.fps) },
            .{ "strap", @as(i64, fields.strap) },
            .{ "vselMv", @as(i64, fields.vsel_mv) },
            .{ "nixosVersion", fields.nixos_version.ptr },
            .{ "kernelVersion", fields.kernel_version.ptr },
        };
        const member_count = entries.len;

        var members: [member_count]ValuePtr = @splat(null);
        var built: usize = 0;
        // The members stay alive until make_attrs has copied them, then all go.
        defer for (members[0..built]) |m| release(self.ctx, m);

        const bb = c.nix_make_bindings_builder(self.ctx, self.state, member_count);
        defer c.nix_bindings_builder_free(bb);

        inline for (entries) |entry| {
            const val = try self.newValue(entry[1]);
            members[built] = val;
            built += 1;
            try check(c.nix_bindings_builder_insert(self.ctx, bb, entry[0], val));
        }

        const scope = c.nix_alloc_value(self.ctx, self.state);
        errdefer release(self.ctx, scope);
        try check(c.nix_make_attrs(self.ctx, scope, bb));
        return scope;
    }

    /// Read an optional attribute of `res` as `T`, or return `fallback` when the
    /// attribute is absent. The C API has one getter per type, so the right one is
    /// selected at comptime from `T`. The reference is released either way.
    fn optAttr(
        self: *NixBackend,
        comptime T: type,
        res: ValuePtr,
        attr: [*c]const u8,
        fallback: T,
    ) !T {
        if (!c.nix_has_attr_byname(self.ctx, res, self.state, attr)) return fallback;
        const v = c.nix_get_attr_byname(self.ctx, res, self.state, attr);
        if (v == null) return fallback;
        defer release(self.ctx, v);
        try check(c.nix_value_force(self.ctx, self.state, v));
        return switch (T) {
            bool => c.nix_get_bool(self.ctx, v),
            i64 => c.nix_get_int(self.ctx, v),
            else => @compileError("no nix getter for " ++ @typeName(T)),
        };
    }

    /// Clamp a count that came from Nix into a u32. A negative or oversized value
    /// is content that asked for something impossible, so it is bounded here.
    fn clampCount(raw: i64) u32 {
        if (raw <= 0) return 0;
        return @intCast(@min(raw, @as(i64, std.math.maxInt(u32))));
    }

    /// Build this frame's scope, apply lambda `idx`, and read the result's `bitmap`
    /// and any `overlay` into the reused integer buffers.
    pub fn applyFrame(self: *NixBackend, idx: usize, fields: eval.Fields) !eval.Frame {
        if (comptime !have_nix) return error.EvalUnavailable;
        const ctx = self.ctx;
        const state = self.state;

        const scope = try self.buildScope(fields);
        defer release(ctx, scope);

        const res = c.nix_alloc_value(ctx, state);
        defer release(ctx, res);
        check(c.nix_value_call(ctx, state, self.lambdas[idx], scope, res)) catch
            return error.CallFailed;
        try check(c.nix_value_force(ctx, state, res));
        if (c.nix_get_type(ctx, res) != c.NIX_TYPE_ATTRS) return error.PatternNotAttrs;

        // bitmap and nextMs are required; everything below them is optional.
        const bitmap = c.nix_get_attr_byname(ctx, res, state, "bitmap") orelse
            return error.MissingBitmap;
        defer release(ctx, bitmap);
        try check(c.nix_value_force(ctx, state, bitmap));
        if (c.nix_get_type(ctx, bitmap) != c.NIX_TYPE_LIST) return error.BitmapNotList;

        const next_v = c.nix_get_attr_byname(ctx, res, state, "nextMs") orelse
            return error.MissingNextMs;
        defer release(ctx, next_v);
        try check(c.nix_value_force(ctx, state, next_v));
        const next_ms = c.nix_get_int(ctx, next_v);

        const is_delta = try self.optAttr(bool, res, "delta", false);
        const n_changes: u32 = if (is_delta)
            clampCount(try self.optAttr(i64, res, "n", 0))
        else
            0;

        const bitmap_len = try self.extractList(bitmap, &self.ints);

        // The overlay holds packed (offset, byte) entries stamped over the frame.
        // When `overlayN` is absent, the list is assumed to be fully packed at two
        // entries per integer.
        var overlay_len: usize = 0;
        var overlay_entries: u32 = 0;
        if (c.nix_has_attr_byname(ctx, res, state, "overlay")) {
            const ov = c.nix_get_attr_byname(ctx, res, state, "overlay");
            if (ov != null) {
                defer release(ctx, ov);
                try check(c.nix_value_force(ctx, state, ov));
                if (c.nix_get_type(ctx, ov) == c.NIX_TYPE_LIST) {
                    overlay_len = try self.extractList(ov, &self.overlay_ints);
                    overlay_entries = if (c.nix_has_attr_byname(ctx, res, state, "overlayN"))
                        clampCount(try self.optAttr(i64, res, "overlayN", 0))
                    else
                        @intCast(@min(overlay_len * 2, @as(usize, std.math.maxInt(u32))));
                }
            }
        }

        return .{
            .bitmap = self.ints[0..bitmap_len],
            .next_ms = next_ms,
            .delta = is_delta,
            .n = n_changes,
            .overlay = self.overlay_ints[0..overlay_len],
            .overlay_n = overlay_entries,
            .hidden = try self.optAttr(bool, res, "hidden", false),
            .pause = try self.optAttr(bool, res, "pause", false),
            .auto_return_ms = clampCount(try self.optAttr(i64, res, "autoReturnMs", 0)),
        };
    }

    /// Force each element of a nix list and read it into `dst`, growing `dst` as
    /// needed. Every element reference is released once it has been read.
    fn extractList(self: *NixBackend, list: ValuePtr, dst: *[]i64) !usize {
        const ctx = self.ctx;
        const state = self.state;
        const len = c.nix_get_list_size(ctx, list);
        try ensureInts(self.gpa, dst, len);
        var i: c_uint = 0;
        while (i < len) : (i += 1) {
            const el = c.nix_get_list_byidx(ctx, list, state, i) orelse return error.ListElemNull;
            defer release(ctx, el);
            try check(c.nix_value_force(ctx, state, el));
            dst.*[i] = c.nix_get_int(ctx, el);
        }
        return len;
    }
};

test "have_nix is defined and the host test build does not link the C API" {
    // The host build cannot link the aarch64 nix archives, so have_nix must be
    // false here. The nix backend is exercised on the badge itself through
    // `nix-badge nix-selftest`.
    try std.testing.expect(!have_nix);
    const opened = NixBackend.open(std.testing.allocator, .{ .io = std.testing.io }, &.{});
    try std.testing.expect(opened == null);
}

test "screenName takes the basename and drops a .nix suffix" {
    try std.testing.expectEqualStrings("clock", screenName("/etc/nixbadge/oled.d/clock.nix"));
    try std.testing.expectEqualStrings("10-badapple", screenName("10-badapple.nix"));
    // A name that is not a .nix file keeps its whole basename.
    try std.testing.expectEqualStrings("readme.txt", screenName("/tmp/readme.txt"));
    // A bare ".nix" would leave an empty stem, which falls back to a placeholder.
    try std.testing.expectEqualStrings("screen", screenName("/tmp/.nix"));
}
