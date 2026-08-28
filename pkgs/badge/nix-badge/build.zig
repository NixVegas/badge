const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // When packaging feeds us a pinned+stubbed fix source tree (see
    // nix-badge.nix), `-Dfix-src` points at it and we link psyclyx/fix's
    // fetch-less `expr` evaluator in. When absent the tool builds exactly as
    // before, minus eval: `fix-selftest` reports eval is unavailable. This is
    // the FOUNDATION for per-frame Nix eval of LED patterns; it is not yet
    // wired into any runtime loop.
    const fix_src = b.option([]const u8, "fix-src", "Path to a pinned, fetch-less fix source tree; enables the embedded expr evaluator");
    const have_fix = fix_src != null;

    // When eval is linked, force the LLVM backend: fix's threaded VM dispatcher
    // relies on `@call(.always_tail)`, which only LLVM implements. When eval is
    // absent, leave the backend unset (null) so Zig keeps its default choice --
    // this matters for riscv64-musl, whose self-hosted backend rejects the
    // `baseline` CPU ("target missing required feature v") but whose default
    // (LLVM) builds it fine. Forcing `false` here would regress the riscv build.
    const use_llvm: ?bool = if (have_fix) true else null;

    // A tiny build_options module so nix-badge.zig can learn at comptime whether
    // eval was compiled in (`@import("build_options").have_fix`).
    const nb_build_options = b.addOptions();
    nb_build_options.addOption(bool, "have_fix", have_fix);
    const nb_build_options_mod = nb_build_options.createModule();

    const root = b.createModule(.{
        .root_source_file = b.path("nix-badge.zig"),
        .target = target,
        .optimize = optimize,
    });
    root.addImport("build_options", nb_build_options_mod);

    if (fix_src) |src| {
        const graph = fixExprGraph(b, src, target, optimize);
        root.addImport("expr", graph.expr);
        root.addImport("runtime", graph.runtime);
    }

    const exe = b.addExecutable(.{
        .name = "nix-badge",
        .root_module = root,
        .use_llvm = use_llvm,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run nix-badge");
    run_step.dependOn(&run_cmd.step);

    // Tests run on the host. They still need build_options (and expr/runtime
    // when a fix source is supplied) so the eval-gated code paths compile.
    const test_root = b.createModule(.{
        .root_source_file = b.path("nix-badge.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    test_root.addImport("build_options", nb_build_options_mod);
    if (fix_src) |src| {
        const graph = fixExprGraph(b, src, b.graph.host, optimize);
        test_root.addImport("expr", graph.expr);
        test_root.addImport("runtime", graph.runtime);
    }
    const tests = b.addTest(.{
        .root_module = test_root,
        .use_llvm = use_llvm,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

/// The two modules nix-badge.zig imports from fix. `runtime` is exposed too so
/// callers can name its types if needed; today fixeval.zig only needs `expr`.
const FixGraph = struct {
    expr: *std.Build.Module,
    runtime: *std.Build.Module,
};

/// Recreate psyclyx/fix's module graph for the `expr` evaluator, fetch-less:
/// `fetchers` is pointed at the vendored stub root (already overlaid into
/// `${fix_src}/src/fetchers/` by nix-badge.nix), so there is NO libcurl/libgit2
/// and `expr` cross-links as a static musl binary with zero network symbols.
/// Mirrors fix's build.zig up to the `expr` module (build_stub.zig proved it).
fn fixExprGraph(
    b: *std.Build,
    fix_src: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) FixGraph {
    // Source files live under ${fix_src}/src/...; reference them via a
    // cwd-relative LazyPath (the store path is outside this build's root).
    const srcPath = struct {
        fn f(bb: *std.Build, root: []const u8, rel: []const u8) std.Build.LazyPath {
            return .{ .cwd_relative = bb.fmt("{s}/{s}", .{ root, rel }) };
        }
    }.f;

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", "nix-badge-embed");
    build_options.addOption(bool, "debug_checks", optimize == .Debug);
    build_options.addOption(bool, "vm_trace", false);
    build_options.addOption(bool, "thunks_log", false);
    build_options.addOption(bool, "prof_main", false);
    build_options.addOption(bool, "prof_path", false);
    const build_options_mod = build_options.createModule();

    const base_options = b.addOptions();
    base_options.addOption(bool, "fiber_census", false);
    base_options.addOption(bool, "tsan_enabled", false);
    base_options.addOption(
        bool,
        "test_emulated",
        target.result.cpu.arch != b.graph.host.result.cpu.arch or
            target.result.os.tag != b.graph.host.result.os.tag,
    );
    const base_options_mod = base_options.createModule();

    const syntax_mod = b.addModule("syntax", .{
        .root_source_file = srcPath(b, fix_src, "src/syntax/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The LALR parser tables are generated at build time by a host-target tool
    // (runs on the build machine, not the cross target) and imported as a plain
    // .zig of literal arrays.
    const gen_tables_exe = b.addExecutable(.{
        .name = "gen-parser-tables",
        .root_module = b.createModule(.{
            .root_source_file = srcPath(b, fix_src, "src/syntax/gen_parser_tables.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
        .use_llvm = true,
    });
    const run_gen_tables = b.addRunArtifact(gen_tables_exe);
    const parser_tables_path = run_gen_tables.addOutputFileArg("parser_tables.zig");
    syntax_mod.addAnonymousImport("parser_tables", .{ .root_source_file = parser_tables_path });

    const base_mod = b.addModule("base", .{
        .root_source_file = srcPath(b, fix_src, "src/base/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    base_mod.addImport("base_options", base_options_mod);

    // Hardware SHA-256 twin: only x86_64 (non-Windows) references the extern
    // symbols, so gate the object exactly as fix does. Our cross targets
    // (aarch64/riscv64) never build it; the host build (x86_64) does.
    if (target.result.cpu.arch == .x86_64 and target.result.os.tag != .windows) {
        var hw_query = target.query;
        hw_query.cpu_features_add.addFeature(@intFromEnum(std.Target.x86.Feature.sha));
        hw_query.cpu_features_add.addFeature(@intFromEnum(std.Target.x86.Feature.avx2));
        const sha256_hw_obj = b.addObject(.{
            .name = "sha256_hw",
            .root_module = b.createModule(.{
                .root_source_file = srcPath(b, fix_src, "src/base/sha256_hw.zig"),
                .target = b.resolveTargetQuery(hw_query),
                .optimize = optimize,
            }),
            .use_llvm = true,
        });
        base_mod.addObject(sha256_hw_obj);
    }

    syntax_mod.addImport("base", base_mod);

    const runtime_mod = b.addModule("runtime", .{
        .root_source_file = srcPath(b, fix_src, "src/runtime/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    runtime_mod.addImport("build_options", build_options_mod);
    runtime_mod.addImport("base", base_mod);

    const store_mod = b.addModule("store", .{
        .root_source_file = srcPath(b, fix_src, "src/store/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    store_mod.addImport("runtime", runtime_mod);
    store_mod.addImport("base", base_mod);

    // The ONLY divergence from fix's build.zig: fetchers points at the vendored
    // stub root (overlaid into src/fetchers/), links NO system libraries. libc
    // is fine (musl is always present); only curl/libgit2 are the cross pain.
    const fetchers_mod = b.addModule("fetchers", .{
        .root_source_file = srcPath(b, fix_src, "src/fetchers/stub_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    fetchers_mod.addImport("runtime", runtime_mod);
    fetchers_mod.addImport("base", base_mod);
    fetchers_mod.addImport("store", store_mod);
    fetchers_mod.link_libc = true;

    const expr_mod = b.addModule("expr", .{
        .root_source_file = srcPath(b, fix_src, "src/expr/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    expr_mod.addImport("build_options", build_options_mod);
    expr_mod.addImport("syntax", syntax_mod);
    expr_mod.addImport("runtime", runtime_mod);
    expr_mod.addImport("base", base_mod);
    expr_mod.addImport("store", store_mod);
    expr_mod.addImport("fetchers", fetchers_mod);

    return .{ .expr = expr_mod, .runtime = runtime_mod };
}
