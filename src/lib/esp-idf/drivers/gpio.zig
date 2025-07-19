const std = @import("std");
const assert = std.debug.assert;
const sys = @import("../sys.zig");

pub const IsrHandler = *const fn (?*anyopaque) callconv(.C) void;

pub const Config = extern struct {
    pin_bit_mask: u64,
    mode: Mode,
    pull_up_en: PullUp,
    pull_down_en: PullDown,
    intr_type: IntType,

    extern fn gpio_config(*const Config) sys.Error;
    pub inline fn config(self: *const Config) !void {
        return gpio_config(self).throw();
    }
};

pub const Mode = enum(c_int) {
    disable = 0,
    input = 1 << 0,
    output = 1 << 1,
    output_od = 1 << 1 | 1 << 2,
    input_output = 1 << 0 | 1 << 1,
};

pub const PullUp = enum(c_int) {
    disable = 0,
    enable = 1,
};

pub const PullDown = enum(c_int) {
    disable = 0,
    enable = 1,
};

pub const IntType = enum(c_int) {
    disable = 0,
    posedge = 1,
    negedge = 2,
    anyedge = 3,
    low_level = 4,
    high_level = 5,
};

extern fn gpio_install_isr_service(c_int) sys.Error;
pub inline fn installIsrService(intr_alloc_flags: c_int) !void {
    return gpio_install_isr_service(intr_alloc_flags).throw();
}

extern fn gpio_isr_handler_add(c_int, IsrHandler, ?*anyopaque) sys.Error;
pub inline fn isrHandlerAdd(gpio_num: c_int, isr_handler: IsrHandler, args: ?*anyopaque) !void {
    return gpio_isr_handler_add(gpio_num, isr_handler, args).throw();
}

extern fn gpio_set_level(c_int, u32) sys.Error;
pub inline fn setLevel(gpio_num: c_int, level: u32) !void {
    return gpio_set_level(gpio_num, level).throw();
}

comptime {
    assert(@sizeOf(IntType) == 4);
    assert(@sizeOf(Config) == 24);
}
