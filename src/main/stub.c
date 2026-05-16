// All application source code lives in Zig (see lib/libnixbadge_zig.a, linked
// in via ../cmake/zig-build.cmake). This translation unit exists only because
// ESP-IDF's idf_component_register requires a real STATIC library for `main`
// so that PRIV_REQUIRES propagate the include paths Zig's @cImport needs.
