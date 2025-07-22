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
    var buf: [1024]u8 = undefined;
    sys.logWrite(.fromStd(level), @tagName(scope), std.fmt.bufPrintZ(&buf, format, args) catch unreachable);
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    var buf: [1024]u8 = undefined;
    sys.systemAbort(std.fmt.bufPrintZ(&buf, "PANIC: {s}", .{msg}) catch unreachable);
}
