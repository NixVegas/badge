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
