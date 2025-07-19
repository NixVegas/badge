const std = @import("std");

pub const Error = enum(c_int) {
    ok = 0,
    fail = -1,
    no_mem = 0x101,
    invalid_arg = 0x102,
    invalid_state = 0x103,
    invalid_size = 0x104,
    not_found = 0x105,
    not_supported = 0x106,
    timeout = 0x107,
    invalid_response = 0x108,
    invalid_crc = 0x109,
    invalid_version = 0x10A,
    invalid_mac = 0x10B,
    wifi_base = 0x3000,
    mesh_base = 0x4000,
    flash_base = 0x6000,
    hw_crypto_base = 0xC000,
    memprot_base = 0xD000,

    pub fn throw(e: Error) !void {
        return switch (e) {
            .ok => {},
            .fail => error.Unexpected,
            .no_mem => error.OutOfMemory,
            .invalid_arg => error.InvalidArg,
            .invalid_state => error.InvalidState,
            .invalid_size => error.InvalidSize,
            .not_found => error.NotFound,
            .not_supported => error.NotSupported,
            else => unreachable,
        };
    }
};

extern fn esp_get_idf_version() [*:0]const u8;
pub inline fn getIdfVersion() []const u8 {
    const str = esp_get_idf_version();
    return str[0..std.mem.length(str)];
}

pub const ResetReason = enum(c_uint) {
    unknown = 0,
    poweron = 1,
    ext = 2,
    sw = 3,
    panic = 4,
    init_wdt = 5,
    task_wdt = 6,
    wdt = 7,
    deepsleep = 8,
    brownout = 9,
    sdio = 10,
    usb = 11,
    jtag = 12,
};

pub const ShutdownHandler = *const fn () callconv(.C) void;

extern fn esp_register_shutdown_handler(handle: ShutdownHandler) Error;
pub inline fn registerShutdownHandler(handle: ShutdownHandler) !void {
    return esp_register_shutdown_handler(handle).throw();
}

pub extern fn esp_unregister_shutdown_handler(handle: ShutdownHandler) Error;
pub inline fn unregisterShutdownHandler(handle: ShutdownHandler) !void {
    return esp_unregister_shutdown_handler(handle).throw();
}

extern fn esp_restart() noreturn;
pub const restart = esp_restart;

extern fn esp_reset_reason() ResetReason;
pub const resetReason = esp_reset_reason;

extern fn esp_get_free_heap_size() u32;
pub const getFreeHeapSize = esp_get_free_heap_size;

extern fn esp_get_free_internal_heap_size() u32;
pub const getFreeInternalHeapSize = esp_get_free_internal_heap_size;

extern fn esp_get_minimum_free_heap_size() u32;
pub const getMinimumFreeHeapSize = esp_get_minimum_free_heap_size;

extern fn esp_system_abort(details: [*:0]const u8) noreturn;
pub const systemAbort = esp_system_abort;

pub const LogLevel = enum(c_uint) {
    none = 0,
    err = 1,
    warn = 2,
    info = 3,
    debug = 4,
    verbose = 5,

    pub fn toStd(l: LogLevel) ?std.log.Level {
        return switch (l) {
            .none => null,
            .err => .err,
            .warn => .warn,
            .info => .info,
            .debug => .debug,
            .verbose => .debug,
        };
    }

    pub fn fromStd(l: ?std.log.Level) LogLevel {
        return switch (l orelse return .none) {
            .err => .err,
            .warn => .warn,
            .info => .info,
            .debug => .debug,
        };
    }
};

extern fn esp_log_write(level: LogLevel, tag: [*:0]const u8, format: [*:0]const u8, ...) void;
pub const logWrite = esp_log_write;
