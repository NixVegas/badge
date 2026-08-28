//! fixeval: the badge's embedded Nix evaluator, psyclyx/fix's `expr` linked in
//! fetch-less (no curl/libgit2, static musl). aarch64 only: fix's fiber/mmap
//! core is x86_64/aarch64-only, so the riscv core builds eval-less and falls
//! back to the computed/blob pattern paths.
//!
//! This is the build FOUNDATION for a later feature: per-frame Nix eval of LED
//! patterns (`t -> [ {r;g;b;} ]`). It is deliberately NOT wired into the leds
//! or bling runtime loops yet -- the only entry point is `selftest`, a smoke
//! test reachable via the hidden `nix-badge fix-selftest` subcommand.
//!
//! Whether the evaluator is compiled in is a build-time decision: nix-badge.nix
//! passes `-Dfix-src=<patched fix source>` only when a fix source is threaded
//! through, and build.zig turns that into `build_options.have_fix`. When eval
//! is absent, `selftest` says so and returns cleanly, so every existing
//! subcommand keeps building and running with a null fixSrc.

const std = @import("std");
const build_options = @import("build_options");

/// True when `-Dfix-src` supplied a fix source and `expr` was linked in.
pub const have_fix = build_options.have_fix;

// `expr` (and its `Engine`/`Value` ABI) only exist in the build graph when
// have_fix; guard the import so a null-fixSrc build never references it.
const expr = if (have_fix) @import("expr") else struct {};

/// Prove the embedded evaluator is live: construct an Engine, evaluate a couple
/// of Nix expressions, and walk a `genList` of `{r;g;b;}` attrsets the way a
/// per-frame pattern will. Logs its findings via std.log; returns an error only
/// on a genuine eval/ABI failure. A build without eval logs and returns.
pub fn selftest(gpa: std.mem.Allocator) !void {
    if (!have_fix) {
        std.log.info("nix-badge built without -Dfix-src; eval unavailable", .{});
        return;
    }

    const Engine = expr.Engine;

    // Single-threaded: worker_count = 0. The badge drives one small eval per
    // frame; there is no work to fan out to a pool.
    var ev = try Engine.init(gpa, .{ .worker_count = 0 });
    defer ev.deinit();

    // (1) A scalar builtins eval. genList underpins every pattern, so exercise
    // it and assert the length. A wrong answer is a programmer/ABI error, not
    // an I/O fault -- fail loudly.
    const len_v = try ev.evaluate("builtins.length (builtins.genList (i: i) 24)");
    const len = len_v.asInt();
    std.debug.assert(len == 24);
    std.log.info("fix-selftest: builtins.genList length = {d} (want 24)", .{len});

    // (2) The real per-frame contract: a pattern is `[ {r;g;b;} ]`. Evaluate a
    // small one with a captured `t`, walk the list, force each element, and
    // read r/g/b as ints. This is the exact path a bling/leds frame will drive.
    const pattern_src =
        \\let t = 3; in builtins.genList (i: { r = i * 8; g = 255 - i * 8; b = t; }) 4
    ;
    const list_v = try ev.evaluate(pattern_src);
    if (list_v.kind() != .list) {
        std.log.err("fix-selftest: pattern did not evaluate to a list", .{});
        return error.FixSelftestFailed;
    }

    const items = try ev.heapListOf(list_v.asObjectId());
    std.log.info("fix-selftest: pattern -> {d} leds", .{items.len});
    for (items, 0..) |item, i| {
        const attrs = try ev.forceValue(item);
        const r = try ev.forceValue((try ev.getAttr(attrs, "r")) orelse {
            std.log.err("fix-selftest: led {d} missing attr 'r'", .{i});
            return error.FixSelftestFailed;
        });
        const g = try ev.forceValue((try ev.getAttr(attrs, "g")) orelse {
            std.log.err("fix-selftest: led {d} missing attr 'g'", .{i});
            return error.FixSelftestFailed;
        });
        const bl = try ev.forceValue((try ev.getAttr(attrs, "b")) orelse {
            std.log.err("fix-selftest: led {d} missing attr 'b'", .{i});
            return error.FixSelftestFailed;
        });
        std.log.info(
            "fix-selftest: led {d} = ({d},{d},{d})",
            .{ i, r.asInt(), g.asInt(), bl.asInt() },
        );
    }

    std.log.info("fix-selftest: OK", .{});
}

test "have_fix flag is defined" {
    // The build option must resolve regardless of whether eval is linked in;
    // this keeps the gated module in the test graph both ways.
    _ = have_fix;
}
