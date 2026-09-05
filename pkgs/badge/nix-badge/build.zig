const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The embedded evaluator comes from the pinned `fix` dependency, patched by
    // `patchedFix` below. `-Dfix=false` builds without it, and `fix-selftest` then
    // reports it as unavailable.
    //
    // fix's evaluator runs on aarch64, riscv64, and x86_64. Any other target
    // builds without it rather than fail, because the fiber support it needs is
    // written per architecture.
    const fix_supported = switch (target.result.cpu.arch) {
        .aarch64, .riscv64, .x86_64 => true,
        else => false,
    };
    const want_fix = b.option(bool, "fix", "embed the fix evaluator") orelse fix_supported;
    if (want_fix and !fix_supported) {
        std.debug.panic("nix-badge: fix has no fiber support for {t}", .{target.result.cpu.arch});
    }
    const fix_src: ?std.Build.LazyPath = if (want_fix) patchedFix(b) else null;
    const have_fix = fix_src != null;

    // The upstream Nix C API backend: a SECOND per-frame evaluator beside fix, so
    // the two can be compared on the same content. It is available on aarch64 only.
    //
    // pkg-config resolves the whole link. `linkSystemLibrary` runs it and takes the
    // include directories, library directories, and library names from its answer,
    // so this build needs no flags describing any of them. The packaging only has
    // to put the right .pc files on PKG_CONFIG_PATH.
    //
    // The components are C++ built against gcc's libstdc++, so this links libc
    // rather than libc++: LLVM's libc++ is not ABI-compatible with gcc's libstdc++.
    const nix_eval = b.option(bool, "nix-eval", "link the upstream Nix C API backend") orelse
        false;
    const have_nix = nix_eval;

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
    nb_build_options.addOption(bool, "have_nix", have_nix);
    const nb_build_options_mod = nb_build_options.createModule();

    // The host test build cannot link the aarch64 nix static libs, so have_nix is FALSE for
    // tests (the shared decode is host-tested in eval.zig; the nix backend is integration-
    // tested on the badge via the fps/RSS harness + `nix-badge nix-selftest`).
    const nb_test_options = b.addOptions();
    nb_test_options.addOption(bool, "have_fix", have_fix);
    nb_test_options.addOption(bool, "have_nix", false);
    const nb_test_options_mod = nb_test_options.createModule();

    const root = b.createModule(.{
        .root_source_file = b.path("nix-badge.zig"),
        .target = target,
        .optimize = optimize,
    });
    root.addImport("build_options", nb_build_options_mod);

    if (fix_src) |src| {
        // The fix graph builds ReleaseFast even when nix-badge itself is ReleaseSafe:
        // fix's `gc_debug` (= ReleaseSafe, heap.zig:28) enables its use-after-free
        // detector, which DELIBERATELY never reuses freed OBJECT slots ("Detector
        // leaves freed slots unused so use-after-free is caught",
        // beginObjectSlot's `!gc_debug` reuse gate). Under the badge's
        // compile-once/apply-per-frame loop that is ~160 leaked Object headers per
        // frame -> reserved bytes grow ~4 MB/s and outgrow zram in minutes
        // (host-measured: objects.count 16K -> 1.27M over 7900 applies in
        // ReleaseSafe; FLAT in ReleaseFast). GC correctness for this embedding was
        // separately witnessed with the detector ON (ReleaseSafe host suite, zero
        // panics) after the Engine-move aliasing fix, so production drops the
        // detector. nix-badge's own code keeps `optimize` (ReleaseSafe safety).
        const fix_optimize: std.builtin.OptimizeMode =
            if (optimize == .Debug) .Debug else .ReleaseFast;
        const graph = fixExprGraph(b, src, target, fix_optimize);
        root.addImport("expr", graph.expr);
        root.addImport("runtime", graph.runtime);
    }

    const exe = b.addExecutable(.{
        .name = "nix-badge",
        .root_module = root,
        .use_llvm = use_llvm,
    });
    b.installArtifact(exe);

    // Link the Nix C API through pkg-config. This applies only to the target
    // executable, never to the host test build.
    if (have_nix) {
        // One entry is enough: nix-expr-c.pc names the other components in its
        // `Requires`, so pkg-config returns their include directories and
        // libraries too.
        //
        // `use_pkg_config = .force` makes a missing or broken .pc file fail the
        // build. The default would fall back to a bare `-lnix-expr-c`, which drops
        // every include directory, and the @cImport in nixeval.zig would then fail
        // with a much less obvious error.
        root.linkSystemLibrary("nix-expr-c", .{ .use_pkg_config = .force });
        root.link_libc = true;
    }

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
    test_root.addImport("build_options", nb_test_options_mod);
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

/// Every change made to the fetched fix source, applied in this order.
///
/// The two stub files replace fix's network fetchers with versions that return
/// `error.FetchUnsupported`. They use relative imports, so they have to sit inside
/// fix's own `src/fetchers/` directory rather than be added as a module.
const fix_edits = struct {
    /// Files copied over the fetched tree, as destination and source pairs.
    const overlays = [_][2][]const u8{
        .{ "src/fetchers/stub_root.zig", "fix-stub/stub_root.zig" },
        .{ "src/fetchers/stub_cache.zig", "fix-stub/stub_cache.zig" },
    };

    /// Patches applied with `patch -p1`, each with the reason it exists.
    const patches = [_]struct { file: []const u8, why: []const u8 }{
        .{
            .file = "fix-stub/native-apply.patch",
            .why = "Engine.applyValue and Engine.makeAttrs, so a compiled lambda can be " ++
                "applied to a fresh scope with no source recompile. A chunk is a " ++
                "permanent root, so compiling once per frame would leak one per frame.",
        },
        .{
            .file = "fix-stub/gc-seed-pinned-minor.patch",
            .why = "Seed the pinned region in a minor mark. Without it a live young " ++
                "child reachable only from a pinned parent was swept, which the " ++
                "collector then reported as a missed edge.",
        },
        .{
            .file = "fix-stub/gc-always-major.patch",
            .why = "Allow major-only collection per Engine, as a fallback for the same " ++
                "fault reached through a tenured parent.",
        },
        .{
            .file = "fix-stub/gc-sizeof-diet-x86only.patch",
            .why = "Limit the object-size asserts to x86_64. They fail on aarch64 in " ++
                "ReleaseFast, which is the mode the badge builds fix in.",
        },
        .{
            .file = "fix-stub/riscv64-fiber.patch",
            .why = "riscv64 fiber support, so the RISC-V core gets the evaluator too. " ++
                "The hunks are gated at comptime, so they are inert elsewhere.",
        },
    };
};

/// The shell that applies the patches.
///
/// It copies the tree it is given into a fresh output directory and patches that,
/// so the `WriteFile` output it reads from is never modified. The build cache
/// treats a step's output as final, and patching it where it lies would apply the
/// patches a second time on the next build, which fails.
///
/// `$1` is the output directory, `$2` is the tree to copy, and the arguments after
/// them are the patch files in the order they must be applied.
const fix_patch_script =
    \\set -eu
    \\out=$1; src=$2; shift 2
    \\cp -R "$src/." "$out"
    \\chmod -R u+w "$out"
    \\for p in "$@"; do patch -p1 --batch -d "$out" -i "$p"; done
;

/// Fetch fix, overlay the stub fetchers, apply the patches, and return the
/// patched tree.
///
/// This is two build steps rather than work done while the build graph is built.
/// A `WriteFile` step copies the fetched tree, which is read-only, and lays the
/// stub files over it. A `Run` step then produces the patched tree as its own
/// output. Both are cached on their inputs, so the patches are applied again only
/// when the pin, a stub, or a patch actually changes.
fn patchedFix(b: *std.Build) std.Build.LazyPath {
    const dep = b.dependency("fix", .{});

    const overlaid = b.addWriteFiles();
    const tree = overlaid.addCopyDirectory(dep.path(""), "", .{});
    for (fix_edits.overlays) |overlay| {
        _ = overlaid.addCopyFile(b.path(overlay[1]), overlay[0]);
    }

    const run = std.Build.Step.Run.create(b, "patch fix");
    // The trailing "fix-patch" becomes $0, so the arguments below start at $1.
    run.addArgs(&.{ "sh", "-c", fix_patch_script, "fix-patch" });
    const out = run.addOutputDirectoryArg("fix");
    run.addDirectoryArg(tree);
    for (fix_edits.patches) |p| run.addFileArg(b.path(p.file));
    return out;
}

/// The two modules nix-badge.zig imports from fix. `runtime` is exposed too so
/// callers can name its types if needed; today fixeval.zig only needs `expr`.
const FixGraph = struct {
    expr: *std.Build.Module,
    runtime: *std.Build.Module,
};

/// Rebuild psyclyx/fix's module graph up to the `expr` evaluator.
///
/// This mirrors fix's own build.zig, with one change: `fetchers` points at the
/// stub root that `patchedFix` overlaid, so there is no libcurl and no libgit2 and
/// `expr` links with no network symbols at all.
fn fixExprGraph(
    b: *std.Build,
    fix_src: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) FixGraph {
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
        .root_source_file = fix_src.path(b, "src/syntax/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The LALR parser tables are generated at build time by a host-target tool
    // (runs on the build machine, not the cross target) and imported as a plain
    // .zig of literal arrays.
    const gen_tables_exe = b.addExecutable(.{
        .name = "gen-parser-tables",
        .root_module = b.createModule(.{
            .root_source_file = fix_src.path(b, "src/syntax/gen_parser_tables.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
        .use_llvm = true,
    });
    const run_gen_tables = b.addRunArtifact(gen_tables_exe);
    const parser_tables_path = run_gen_tables.addOutputFileArg("parser_tables.zig");
    syntax_mod.addAnonymousImport("parser_tables", .{ .root_source_file = parser_tables_path });

    const base_mod = b.addModule("base", .{
        .root_source_file = fix_src.path(b, "src/base/root.zig"),
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
                .root_source_file = fix_src.path(b, "src/base/sha256_hw.zig"),
                .target = b.resolveTargetQuery(hw_query),
                .optimize = optimize,
            }),
            .use_llvm = true,
        });
        base_mod.addObject(sha256_hw_obj);
    }

    syntax_mod.addImport("base", base_mod);

    const runtime_mod = b.addModule("runtime", .{
        .root_source_file = fix_src.path(b, "src/runtime/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    runtime_mod.addImport("build_options", build_options_mod);
    runtime_mod.addImport("base", base_mod);

    const store_mod = b.addModule("store", .{
        .root_source_file = fix_src.path(b, "src/store/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    store_mod.addImport("runtime", runtime_mod);
    store_mod.addImport("base", base_mod);

    // The ONLY divergence from fix's build.zig: fetchers points at the vendored
    // stub root (overlaid into src/fetchers/), links NO system libraries. libc
    // is fine (musl is always present); only curl/libgit2 are the cross pain.
    const fetchers_mod = b.addModule("fetchers", .{
        .root_source_file = fix_src.path(b, "src/fetchers/stub_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    fetchers_mod.addImport("runtime", runtime_mod);
    fetchers_mod.addImport("base", base_mod);
    fetchers_mod.addImport("store", store_mod);
    fetchers_mod.link_libc = true;

    const expr_mod = b.addModule("expr", .{
        .root_source_file = fix_src.path(b, "src/expr/root.zig"),
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
