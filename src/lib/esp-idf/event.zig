//! esp_event_* bindings.

const netif = @import("netif.zig");

pub const EventBase = netif.EventBase;

pub const Handler = *const fn (
    event_handler_arg: ?*anyopaque,
    event_base: EventBase,
    event_id: i32,
    event_data: ?*anyopaque,
) callconv(.c) void;

pub extern fn esp_event_loop_create_default() c_int;
pub extern fn esp_event_handler_register(
    event_base: EventBase,
    event_id: i32,
    event_handler: Handler,
    event_handler_arg: ?*anyopaque,
) c_int;
