const std = @import("std");

const targets = &[_]std.Target.Query{
    .{
        .cpu_arch = .riscv32,
        .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv32 },
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_add = std.Target.riscv.featureSet(&.{ .m, .a, .c, .zifencei, .zicsr }),
    },
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{
        .whitelist = targets,
        .default_target = targets[0],
    });

    const optimize = b.standardOptimizeOption(.{});

    const esp_idf_build_path = b.option(std.Build.LazyPath, "esp-idf-build", "Path to the esp-idf build directory") orelse @panic("Missing esp-idf build directory");

    const lib = b.addStaticLibrary(.{
        .name = "app_zig",
        .root_source_file = b.path("main/app.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.root_module.addImport("esp-idf", importIdf(b, .{
        .target = target,
        .optimize = optimize,
        .build_path = esp_idf_build_path,
    }));

    b.installArtifact(lib);
}

pub fn importIdf(b: *std.Build, options: struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_path: std.Build.LazyPath,
}) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("lib/esp-idf.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });

    module.addObjectFile(options.build_path.path(b, "esp_driver_uart/libesp_driver_uart.a"));
    module.addObjectFile(options.build_path.path(b, "esp_system/libesp_system.a"));
    return module;
}
