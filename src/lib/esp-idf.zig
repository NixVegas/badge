const std = @import("std");

pub const c = @cImport({
    @cInclude("esp_mesh.h");
    @cInclude("esp_wifi.h");
});

pub const drivers = @import("esp-idf/drivers.zig");
pub const sys = @import("esp-idf/sys.zig");
pub const wifi = @import("esp-idf/wifi.zig");

pub const std_options: std.Options = .{
    .logFn = logFn,
};

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const buff = std.fmt.allocPrintSentinel(std.heap.c_allocator, format, args, 0) catch return;
    defer std.heap.c_allocator.free(buff);
    sys.logWrite(.fromStd(level), @tagName(scope), buff);
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    const buff = std.fmt.allocPrintSentinel(std.heap.c_allocator, "PANIC: {s}", .{msg}, 0) catch unreachable;
    defer std.heap.c_allocator.free(buff);
    sys.systemAbort(buff);
}
