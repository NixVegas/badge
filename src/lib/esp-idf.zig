const std = @import("std");

pub const c = @cImport({
    @cInclude("esp_bridge.h");
    @cInclude("esp_event.h");
    @cInclude("esp_http_client.h");
    @cInclude("esp_http_server.h");
    @cInclude("esp_log.h");
    @cInclude("esp_mac.h");
    @cInclude("esp_mesh.h");
    @cInclude("esp_mesh_internal.h");
    @cInclude("esp_mesh_lite.h");
    @cInclude("esp_netif.h");
    @cInclude("esp_timer.h");
    @cInclude("esp_tls.h");
    @cInclude("esp_wifi.h");
    @cInclude("driver/rmt_encoder.h");
    @cInclude("driver/rmt_tx.h");
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/task.h");
    @cInclude("freertos/queue.h");
    @cInclude("nvs.h");
    @cInclude("nvs_flash.h");
    @cInclude("stdlib.h");
});

pub const drivers = @import("esp-idf/drivers.zig");
pub const freertos = @import("esp-idf/freertos.zig");
pub const nvs = @import("esp-idf/nvs.zig");
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
