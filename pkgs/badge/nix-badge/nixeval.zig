//! nixeval: the upstream Nix C API evaluator backend (a SECOND per-frame evaluator
//! alongside fix, for an A/B comparison). The C++ `libnixexpr` links in statically when
//! `-Dnix-include` is provided (aarch64 only) -- see nix-badge.nix and the proven link
//! recipe in docs/superpowers/plans/2026-08-29-nix-c-api-backend.md. Without it every
//! method is a no-op / stub so the fix-only and riscv builds are unchanged.
//!
//! Same compile-once / apply-per-frame shape as fixeval: `nix_expr_eval_from_string` a
//! lambda ONCE, then per frame build a `BindingsBuilder` scope, `nix_value_call`,
//! `nix_value_force`, and read the `bitmap` list into a plain `[]i64` for the shared
//! eval.zig decode. A `dummy://` store means no real Nix store is needed for pure eval.
const std = @import("std");
const build_options = @import("build_options");
const linux = @import("linux.zig");
const eval = @import("eval.zig");

/// True when `-Dnix-include` supplied the Nix C API headers + the libs were linked in.
pub const have_nix = build_options.have_nix;

// The C API only exists in the link when have_nix; @cImport it then, else a stub so the
// gated methods still type-check on a nix-less build (mirrors fixeval's `have_fix`).
const c = if (have_nix) @cImport({
    @cInclude("nix_api_util.h");
    @cInclude("nix_api_store.h");
    @cInclude("nix_api_expr.h");
    @cInclude("nix_api_value.h");
}) else struct {};

// The C API handle types, aliased to a placeholder on a nix-less build so the struct
// fields + method signatures still type-check (mirrors fixeval's `Value = void`).
const NixContext = if (have_nix) c.nix_c_context else anyopaque;
const NixState = if (have_nix) c.EvalState else anyopaque;
const NixStore = if (have_nix) c.Store else anyopaque;
// A managed nix value pointer. `nix_value` is an OPAQUE C type, so translate-c renders
// `nix_value *` as a single-item `?*nix_value` (a `[*c]` many-pointer to an opaque, unknown-
// size type is rejected). `?*anyopaque` when nix is not linked.
const ValuePtr = if (have_nix) ?*c.nix_value else ?*anyopaque;

/// Same source-size cap as fixeval (a baked Bad Apple frame-list is the outlier at ~6 MiB).
const max_pattern_bytes = 8 * 1024 * 1024;

/// Prove the Nix C API links + evaluates: compile `scope: scope.t + 1` once, apply it to
/// `{ t = 41; }`, and check the result is 42. Reachable via `nix-badge nix-selftest`; the
/// first real exercise of the C++ static link. Returns false (logged) on a nix-less build.
pub fn selftest() bool {
    if (comptime !have_nix) {
        std.log.info("nix-badge built without -Dnix-include; nix backend unavailable", .{});
        return false;
    }
    const ctx = c.nix_c_context_create();
    if (c.nix_libexpr_init(ctx) != c.NIX_OK) {
        std.log.err("nix-selftest: nix_libexpr_init failed", .{});
        return false;
    }
    const store = c.nix_store_open(ctx, "dummy://", null);
    if (store == null) {
        std.log.err("nix-selftest: nix_store_open failed", .{});
        return false;
    }
    const state = c.nix_state_create(ctx, null, store);
    if (state == null) {
        std.log.err("nix-selftest: nix_state_create failed", .{});
        return false;
    }
    defer c.nix_state_free(state);

    // Compile the lambda ONCE (as a backend would at open()).
    const fn_val = c.nix_alloc_value(ctx, state);
    if (c.nix_expr_eval_from_string(ctx, state, "scope: scope.t + 1", ".", fn_val) != c.NIX_OK) {
        std.log.err("nix-selftest: nix_expr_eval_from_string failed", .{});
        return false;
    }

    // scope = { t = 41; }
    const bb = c.nix_make_bindings_builder(ctx, state, 1);
    const t = c.nix_alloc_value(ctx, state);
    _ = c.nix_init_int(ctx, t, 41);
    _ = c.nix_bindings_builder_insert(ctx, bb, "t", t);
    const scope = c.nix_alloc_value(ctx, state);
    _ = c.nix_make_attrs(ctx, scope, bb);
    c.nix_bindings_builder_free(bb);

    const res = c.nix_alloc_value(ctx, state);
    if (c.nix_value_call(ctx, state, fn_val, scope, res) != c.NIX_OK) {
        std.log.err("nix-selftest: nix_value_call failed", .{});
        return false;
    }
    _ = c.nix_value_force(ctx, state, res);
    const got = c.nix_get_int(ctx, res);
    std.log.info("nix-selftest: (scope: scope.t + 1) {{ t = 41; }} = {d} (want 42)", .{got});
    return got == 42;
}

/// Grow `ints.*` to at least `need` i64s. Mirrors fixeval.ensureInts.
fn ensureInts(gpa: std.mem.Allocator, ints: *[]i64, need: usize) !void {
    if (ints.len >= need) return;
    ints.* = if (ints.len == 0) try gpa.alloc(i64, need) else try gpa.realloc(ints.*, need);
}

/// Derive a screen's display name from its path: the basename sans a trailing `.nix`.
fn screenName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const stem = if (std.mem.endsWith(u8, base, ".nix")) base[0 .. base.len - 4] else base;
    return if (stem.len == 0) "screen" else stem;
}

/// Read a pattern file (bounded to `max_pattern_bytes`) into a gpa-owned, NUL-terminated
/// buffer (the C API wants `const char *`). Null on any read fault WITHOUT logging.
fn readPatternZ(gpa: std.mem.Allocator, path: []const u8) ?[:0]u8 {
    if (comptime !have_nix) return null;
    var pbuf: [512]u8 = undefined;
    const zpath = std.fmt.bufPrintZ(&pbuf, "{s}", .{path}) catch return null;
    const scratch = gpa.alloc(u8, max_pattern_bytes) catch return null;
    defer gpa.free(scratch);
    const used = linux.readFile(zpath, scratch) orelse return null;
    return gpa.dupeZ(u8, used) catch null;
}

/// The upstream Nix C API evaluator backend. Same surface as `fixeval.FixBackend`
/// (`open`/`applyFrame`/`collect`/`deinit`/`count`/`name`), so `backend.Backend` can hold
/// either. ONE `EvalState` (over a `dummy://` store, pure eval only) holds N compiled
/// lambdas; each frame builds a `scope` attrset with a `BindingsBuilder`, `nix_value_call`s
/// the lambda, and forces the `bitmap` (+ optional `overlay`) list into a reused `[]i64`
/// for the shared eval.zig decode. Boehm-GC managed, so `collect` is a no-op.
///
/// Refcount discipline: every `nix_value *` obtained from the API (alloc'd scope pieces and
/// every `nix_get_*` result) is `nix_value_decref`'d once read, so per-frame temporaries do
/// not accumulate as permanent GC roots. Only the compiled lambdas are kept rooted (their
/// alloc ref is held for the backend's life and decref'd in `deinit`).
pub const NixBackend = struct {
    gpa: std.mem.Allocator,
    ctx: ?*NixContext = null,
    state: ?*NixState = null,
    store: ?*NixStore = null,
    lambdas: []ValuePtr = &.{},
    names: [][]u8 = &.{},
    ints: []i64 = &.{},
    overlay_ints: []i64 = &.{},

    /// Init libexpr, open a `dummy://` store + eval state, compile each path to a lambda
    /// ONCE and keep it rooted. Skips (logs once) a path that cannot be read / does not
    /// compile / is not a function. Returns null when nix is not linked or none loaded.
    ///
    /// `opts.io` is accepted for signature parity with FixBackend but ignored: upstream Nix
    /// does its own filesystem `import`/`readFile` natively. `opts.nix_path` (e.g.
    /// "nixbadge=/etc/nixbadge") becomes the eval state's `lookupPath`, so content can
    /// `import <nixbadge/lib/font.nix>` the same as under fix.
    pub fn open(gpa: std.mem.Allocator, opts: eval.Opts, paths: []const []const u8) ?NixBackend {
        _ = opts.io;
        if (comptime !have_nix) {
            std.log.info("nix: eval requested but not built on this arch", .{});
            return null;
        }
        if (paths.len == 0) return null;

        const ctx = c.nix_c_context_create();
        if (c.nix_libexpr_init(ctx) != c.NIX_OK) {
            std.log.err("nix: nix_libexpr_init failed", .{});
            c.nix_c_context_free(ctx);
            return null;
        }
        const store = c.nix_store_open(ctx, "dummy://", null);
        if (store == null) {
            std.log.err("nix: nix_store_open(dummy://) failed", .{});
            c.nix_c_context_free(ctx);
            return null;
        }
        // lookupPath = a null-terminated array of "name=path" entries (nix copies them, so a
        // stack array + a transient dupeZ is fine). One entry: opts.nix_path.
        var lp_storage: [2][*c]const u8 = .{ null, null };
        var np_z: ?[:0]u8 = null;
        if (opts.nix_path) |np| {
            np_z = gpa.dupeZ(u8, np) catch null;
            if (np_z) |z| lp_storage[0] = z.ptr;
        }
        defer if (np_z) |z| gpa.free(z);
        const lookup: [*c][*c]const u8 = if (np_z != null) &lp_storage else null;
        const state = c.nix_state_create(ctx, lookup, store);
        if (state == null) {
            std.log.err("nix: nix_state_create failed", .{});
            c.nix_store_free(store);
            c.nix_c_context_free(ctx);
            return null;
        }

        var lambdas = gpa.alloc(ValuePtr, paths.len) catch {
            c.nix_state_free(state);
            c.nix_store_free(store);
            c.nix_c_context_free(ctx);
            return null;
        };
        var names = gpa.alloc([]u8, paths.len) catch {
            gpa.free(lambdas);
            c.nix_state_free(state);
            c.nix_store_free(store);
            c.nix_c_context_free(ctx);
            return null;
        };

        var loaded: usize = 0;
        for (paths) |path| {
            const src = readPatternZ(gpa, path) orelse {
                std.log.warn("nix: cannot read eval screen {s}; skipping", .{path});
                continue;
            };
            defer gpa.free(src); // nix parses into its own AST; the text can go
            const fn_val = c.nix_alloc_value(ctx, state);
            if (c.nix_expr_eval_from_string(ctx, state, src.ptr, ".", fn_val) != c.NIX_OK) {
                std.log.warn("nix: eval screen {s} did not compile; skipping", .{path});
                _ = c.nix_value_decref(ctx, fn_val);
                continue;
            }
            if (c.nix_value_force(ctx, state, fn_val) != c.NIX_OK or
                c.nix_get_type(ctx, fn_val) != c.NIX_TYPE_FUNCTION)
            {
                std.log.warn("nix: eval screen {s} is not a function; skipping", .{path});
                _ = c.nix_value_decref(ctx, fn_val);
                continue;
            }
            const nm = gpa.dupe(u8, screenName(path)) catch {
                _ = c.nix_value_decref(ctx, fn_val);
                continue;
            };
            // Keep the alloc ref: fn_val stays a rooted GC value for the backend's life
            // (decref'd in deinit), so it survives across frames' collections.
            lambdas[loaded] = fn_val;
            names[loaded] = nm;
            loaded += 1;
            std.log.info("nix: eval screen {s} compiled as '{s}'", .{ path, nm });
        }

        if (loaded == 0) {
            gpa.free(lambdas);
            gpa.free(names);
            c.nix_state_free(state);
            c.nix_store_free(store);
            c.nix_c_context_free(ctx);
            std.log.warn("nix: no eval screens loaded", .{});
            return null;
        }

        lambdas = gpa.realloc(lambdas, loaded) catch lambdas[0..loaded];
        names = gpa.realloc(names, loaded) catch names[0..loaded];

        std.log.info("nix: {d} eval screen(s) loaded into one state", .{loaded});
        return .{ .gpa = gpa, .ctx = ctx, .state = state, .store = store, .lambdas = lambdas, .names = names };
    }

    pub fn deinit(self: *NixBackend) void {
        if (comptime !have_nix) return;
        for (self.lambdas) |l| _ = c.nix_value_decref(self.ctx, l);
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

    /// Boehm-GC manages the value heap, so there is no per-frame young sweep to run.
    pub fn collect(self: *NixBackend) void {
        _ = self;
    }

    /// Build the per-frame `scope`, apply lambda `idx`, force the result's `bitmap` (+
    /// optional `overlay`) list into the reused int buffers, and return an `eval.Frame`.
    /// Every per-frame `nix_value *` is decref'd so nothing accumulates as a GC root.
    pub fn applyFrame(self: *NixBackend, idx: usize, fields: eval.Fields) !eval.Frame {
        if (comptime !have_nix) return error.EvalUnavailable;
        const ctx = self.ctx;
        const state = self.state;

        // scope = { t; frameIndex; width; ...; backend; fps; }. Members are kept rooted
        // until AFTER nix_make_attrs copies them into the Bindings, then decref'd.
        var members: [16]ValuePtr = undefined;
        var mi: usize = 0;
        const bb = c.nix_make_bindings_builder(ctx, state, 13);
        mi = self.addInt(bb, &members, mi, "t", @intCast(fields.t_ms));
        mi = self.addInt(bb, &members, mi, "frameIndex", @intCast(fields.frame_index));
        mi = self.addInt(bb, &members, mi, "width", fields.width);
        mi = self.addInt(bb, &members, mi, "height", fields.height);
        mi = self.addInt(bb, &members, mi, "batteryMv", fields.battery_mv);
        mi = self.addInt(bb, &members, mi, "batteryPct", fields.battery_pct);
        mi = self.addBool(bb, &members, mi, "onUsb", fields.on_usb);
        mi = self.addFloat(bb, &members, mi, "load1", fields.load1);
        mi = self.addInt(bb, &members, mi, "cpuPct", fields.cpu_pct);
        mi = self.addInt(bb, &members, mi, "memPct", fields.mem_pct);
        mi = self.addInt(bb, &members, mi, "uptimeS", fields.uptime_s);
        mi = self.addInt(bb, &members, mi, "backend", fields.backend_id);
        mi = self.addInt(bb, &members, mi, "fps", fields.fps);
        mi = self.addInt(bb, &members, mi, "strap", fields.strap);

        const scope = c.nix_alloc_value(ctx, state);
        _ = c.nix_make_attrs(ctx, scope, bb); // consumes the builder's contents
        c.nix_bindings_builder_free(bb);
        for (members[0..mi]) |m| _ = c.nix_value_decref(ctx, m);

        const res = c.nix_alloc_value(ctx, state);
        if (c.nix_value_call(ctx, state, self.lambdas[idx], scope, res) != c.NIX_OK) {
            _ = c.nix_value_decref(ctx, scope);
            _ = c.nix_value_decref(ctx, res);
            return error.CallFailed;
        }
        _ = c.nix_value_decref(ctx, scope);
        if (c.nix_value_force(ctx, state, res) != c.NIX_OK or c.nix_get_type(ctx, res) != c.NIX_TYPE_ATTRS) {
            _ = c.nix_value_decref(ctx, res);
            return error.PatternNotAttrs;
        }
        // Everything below reads from `res`; decref it on the way out of every path.
        defer _ = c.nix_value_decref(ctx, res);

        // Required: bitmap (a list) + nextMs (an int).
        const bitmap = c.nix_get_attr_byname(ctx, res, state, "bitmap");
        if (bitmap == null) return error.MissingBitmap;
        defer _ = c.nix_value_decref(ctx, bitmap);
        if (c.nix_value_force(ctx, state, bitmap) != c.NIX_OK or c.nix_get_type(ctx, bitmap) != c.NIX_TYPE_LIST)
            return error.BitmapNotList;

        const next_v = c.nix_get_attr_byname(ctx, res, state, "nextMs");
        if (next_v == null) return error.MissingNextMs;
        defer _ = c.nix_value_decref(ctx, next_v);
        _ = c.nix_value_force(ctx, state, next_v);
        const next_ms = c.nix_get_int(ctx, next_v);

        // Optional delta contract.
        var is_delta = false;
        var n_changes: u32 = 0;
        if (c.nix_has_attr_byname(ctx, res, state, "delta")) {
            const dv = c.nix_get_attr_byname(ctx, res, state, "delta");
            defer _ = c.nix_value_decref(ctx, dv);
            _ = c.nix_value_force(ctx, state, dv);
            is_delta = c.nix_get_bool(ctx, dv);
        }
        if (is_delta and c.nix_has_attr_byname(ctx, res, state, "n")) {
            const nv = c.nix_get_attr_byname(ctx, res, state, "n");
            defer _ = c.nix_value_decref(ctx, nv);
            _ = c.nix_value_force(ctx, state, nv);
            const raw = c.nix_get_int(ctx, nv);
            if (raw > 0) n_changes = @intCast(@min(raw, @as(i64, std.math.maxInt(u32))));
        }

        const bitmap_len = try self.extractList(bitmap, &self.ints);

        // Optional overlay: packed (offset,byte) entries stamped over the decoded frame.
        var overlay_len: usize = 0;
        var overlay_entries: u32 = 0;
        if (c.nix_has_attr_byname(ctx, res, state, "overlay")) {
            const ov = c.nix_get_attr_byname(ctx, res, state, "overlay");
            defer _ = c.nix_value_decref(ctx, ov);
            if (c.nix_value_force(ctx, state, ov) == c.NIX_OK and c.nix_get_type(ctx, ov) == c.NIX_TYPE_LIST) {
                overlay_len = try self.extractList(ov, &self.overlay_ints);
                if (c.nix_has_attr_byname(ctx, res, state, "overlayN")) {
                    const ovn = c.nix_get_attr_byname(ctx, res, state, "overlayN");
                    defer _ = c.nix_value_decref(ctx, ovn);
                    _ = c.nix_value_force(ctx, state, ovn);
                    const raw = c.nix_get_int(ctx, ovn);
                    if (raw > 0) overlay_entries = @intCast(@min(raw, @as(i64, std.math.maxInt(u32))));
                } else {
                    overlay_entries = @intCast(@min(overlay_len * 2, @as(usize, std.math.maxInt(u32))));
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
        };
    }

    /// Force each element of a nix list value and extract it into `dst` (grown as needed).
    /// Each `nix_get_list_byidx` result is an owned ref, decref'd after reading.
    fn extractList(self: *NixBackend, list: ValuePtr, dst: *[]i64) !usize {
        const ctx = self.ctx;
        const state = self.state;
        const len = c.nix_get_list_size(ctx, list);
        try ensureInts(self.gpa, dst, len);
        var i: c_uint = 0;
        while (i < len) : (i += 1) {
            const el = c.nix_get_list_byidx(ctx, list, state, i);
            if (el == null) return error.ListElemNull;
            _ = c.nix_value_force(ctx, state, el);
            dst.*[i] = c.nix_get_int(ctx, el);
            _ = c.nix_value_decref(ctx, el);
        }
        return len;
    }

    fn addInt(self: *NixBackend, bb: anytype, members: []ValuePtr, mi: usize, name_z: [*c]const u8, v: i64) usize {
        const val = c.nix_alloc_value(self.ctx, self.state);
        _ = c.nix_init_int(self.ctx, val, v);
        _ = c.nix_bindings_builder_insert(self.ctx, bb, name_z, val);
        members[mi] = val;
        return mi + 1;
    }
    fn addBool(self: *NixBackend, bb: anytype, members: []ValuePtr, mi: usize, name_z: [*c]const u8, v: bool) usize {
        const val = c.nix_alloc_value(self.ctx, self.state);
        _ = c.nix_init_bool(self.ctx, val, v);
        _ = c.nix_bindings_builder_insert(self.ctx, bb, name_z, val);
        members[mi] = val;
        return mi + 1;
    }
    fn addFloat(self: *NixBackend, bb: anytype, members: []ValuePtr, mi: usize, name_z: [*c]const u8, v: f64) usize {
        const val = c.nix_alloc_value(self.ctx, self.state);
        _ = c.nix_init_float(self.ctx, val, v);
        _ = c.nix_bindings_builder_insert(self.ctx, bb, name_z, val);
        members[mi] = val;
        return mi + 1;
    }
};
