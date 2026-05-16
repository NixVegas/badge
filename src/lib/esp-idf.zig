const std = @import("std");

pub const bridge = @import("esp-idf/bridge.zig");
pub const drivers = @import("esp-idf/drivers.zig");
pub const event = @import("esp-idf/event.zig");
pub const freertos = @import("esp-idf/freertos.zig");
pub const http_client = @import("esp-idf/http_client.zig");
pub const http_server = @import("esp-idf/http_server.zig");
pub const log = @import("esp-idf/log.zig");
pub const mesh_lite = @import("esp-idf/mesh_lite.zig");
pub const netif = @import("esp-idf/netif.zig");
pub const nvs = @import("esp-idf/nvs.zig");
pub const rmt = @import("esp-idf/rmt.zig");
pub const stdlib = @import("esp-idf/stdlib.zig");
pub const sys = @import("esp-idf/sys.zig");
pub const timer = @import("esp-idf/timer.zig");
pub const tls = @import("esp-idf/tls.zig");
pub const wifi = @import("esp-idf/wifi.zig");

pub const std_options: std.Options = .{
    .logFn = logFn,
};

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, format, args) catch return;
    sys.logWrite(.fromStd(level), @tagName(scope), msg);
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    var buf: [256]u8 = undefined;
    const detail = std.fmt.bufPrintZ(&buf, "PANIC: {s}", .{msg}) catch "PANIC";
    sys.systemAbort(detail);
}
