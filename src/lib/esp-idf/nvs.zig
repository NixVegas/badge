pub const Handle = u32;

pub const OpenMode = enum(c_uint) {
    readonly = 0,
    readwrite = 1,
};

pub const Error = error{
    NotFound,
    NoFreePages,
    NewVersionFound,
    Other,
};

const ESP_OK: c_int = 0;
const ESP_ERR_NVS_NOT_FOUND: c_int = 0x1102;
const ESP_ERR_NVS_NO_FREE_PAGES: c_int = 0x110d;
const ESP_ERR_NVS_NEW_VERSION_FOUND: c_int = 0x1110;

extern fn nvs_open(namespace_name: [*:0]const u8, open_mode: OpenMode, out_handle: *Handle) c_int;
extern fn nvs_close(handle: Handle) void;
extern fn nvs_get_u8(handle: Handle, key: [*:0]const u8, out_value: *u8) c_int;
extern fn nvs_get_u32(handle: Handle, key: [*:0]const u8, out_value: *u32) c_int;
extern fn nvs_get_str(handle: Handle, key: [*:0]const u8, out_value: ?[*]u8, length: *usize) c_int;
extern fn nvs_flash_init() c_int;
extern fn nvs_flash_erase() c_int;

inline fn fromCode(code: c_int) Error {
    return switch (code) {
        ESP_ERR_NVS_NOT_FOUND => error.NotFound,
        ESP_ERR_NVS_NO_FREE_PAGES => error.NoFreePages,
        ESP_ERR_NVS_NEW_VERSION_FOUND => error.NewVersionFound,
        else => error.Other,
    };
}

pub fn open(namespace: [*:0]const u8, mode: OpenMode) Error!Handle {
    var handle: Handle = 0;
    const rc = nvs_open(namespace, mode, &handle);
    if (rc == ESP_OK) return handle;
    return fromCode(rc);
}

pub inline fn close(handle: Handle) void {
    nvs_close(handle);
}

/// Returns null on NOT_FOUND, error on other failures.
pub fn getU8(handle: Handle, key: [*:0]const u8) Error!?u8 {
    var value: u8 = 0;
    const rc = nvs_get_u8(handle, key, &value);
    if (rc == ESP_OK) return value;
    if (rc == ESP_ERR_NVS_NOT_FOUND) return null;
    return fromCode(rc);
}

pub fn getU32(handle: Handle, key: [*:0]const u8) Error!?u32 {
    var value: u32 = 0;
    const rc = nvs_get_u32(handle, key, &value);
    if (rc == ESP_OK) return value;
    if (rc == ESP_ERR_NVS_NOT_FOUND) return null;
    return fromCode(rc);
}

/// Returns the required buffer length (including trailing NUL) for `key`,
/// or null if the key is absent.
pub fn getStrLen(handle: Handle, key: [*:0]const u8) Error!?usize {
    var len: usize = 0;
    const rc = nvs_get_str(handle, key, null, &len);
    if (rc == ESP_OK) return len;
    if (rc == ESP_ERR_NVS_NOT_FOUND) return null;
    return fromCode(rc);
}

/// Reads a NUL-terminated string into `out`. `out.len` is taken as the
/// buffer length on entry. Returns the number of bytes written (including
/// the trailing NUL), or null if the key is absent.
pub fn getStr(handle: Handle, key: [*:0]const u8, out: []u8) Error!?usize {
    var len: usize = out.len;
    const rc = nvs_get_str(handle, key, out.ptr, &len);
    if (rc == ESP_OK) return len;
    if (rc == ESP_ERR_NVS_NOT_FOUND) return null;
    return fromCode(rc);
}

pub inline fn flashInit() Error!void {
    const rc = nvs_flash_init();
    if (rc == ESP_OK) return;
    return fromCode(rc);
}

pub inline fn flashErase() Error!void {
    const rc = nvs_flash_erase();
    if (rc == ESP_OK) return;
    return fromCode(rc);
}

/// Initialize NVS, automatically erasing and retrying if the partition is
/// stale (no free pages or wrong version).
pub fn flashInitOrErase() Error!void {
    flashInit() catch |err| switch (err) {
        error.NoFreePages, error.NewVersionFound => {
            try flashErase();
            try flashInit();
        },
        else => return err,
    };
}
