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

    const esp_idf_source_path = b.option(std.Build.LazyPath, "esp-idf-source", "Path to the esp-idf source directory") orelse @panic("Missing esp-idf source directory");
    const esp_idf_build_path = b.option(std.Build.LazyPath, "esp-idf-build", "Path to the esp-idf build directory") orelse @panic("Missing esp-idf build directory");

    const lib = b.addStaticLibrary(.{
        .name = "app_zig",
        .root_source_file = b.path("main/app.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.no_builtin = true;
    lib.root_module.addImport("esp-idf", importIdf(b, .{
        .target = target,
        .optimize = optimize,
        .source_path = esp_idf_source_path,
        .build_path = esp_idf_build_path,
    }));

    b.installArtifact(lib);
}

pub fn importIdf(b: *std.Build, options: struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    source_path: std.Build.LazyPath,
    build_path: std.Build.LazyPath,
}) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("lib/esp-idf.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });

    var iter = std.mem.splitSequence(u8, b.graph.env_map.get("INCLUDE_DIRS") orelse @panic("Missing INCLUDE_DIRS env"), ";");
    while (iter.next()) |dir| {
        module.addIncludePath(.{ .cwd_relative = dir });
    }

    module.addObjectFile(options.build_path.path(b, "esp_driver_uart/libesp_driver_uart.a"));
    module.addObjectFile(options.build_path.path(b, "esp_system/libesp_system.a"));
    module.addObjectFile(options.build_path.path(b, "esp_wifi/libesp_wifi.a"));
    module.addObjectFile(options.build_path.path(b, "wpa_supplicant/libwpa_supplicant.a"));
    return module;
}
