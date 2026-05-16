//! esp_http_server (httpd_*) bindings.

const std = @import("std");

pub const Handle = ?*anyopaque;

/// `enum http_method` from llhttp / http_parser. Only the values we care about.
pub const Method = enum(c_int) {
    GET = 1,
    _,
};

/// `httpd_req_t` from esp_http_server.h. We only access `.uri`, so just mirror
/// the prefix and leave the rest opaque.
pub const Req = extern struct {
    handle: Handle,
    method: c_int,
    uri: [512]u8, // CONFIG_HTTPD_MAX_URI_LEN - exact value doesn't matter; we
    // only read it via @ptrCast on `&req.*.uri`. The trailing fields are
    // unused from Zig.
};

pub const Handler = *const fn (req: *Req) callconv(.c) c_int;

pub const UriEntry = extern struct {
    uri: [*:0]const u8,
    method: Method,
    handler: ?Handler,
    user_ctx: ?*anyopaque,
    // CONFIG_HTTPD_WS_SUPPORT-gated trailing fields; default-on in ESP-IDF.
    is_websocket: bool,
    handle_ws_control_frames: bool,
    supported_subprotocol: ?[*:0]const u8,
};

pub const UriMatchFn = *const fn (
    reference_uri: [*:0]const u8,
    uri_to_match: [*:0]const u8,
    match_upto: usize,
) callconv(.c) bool;

/// Mirrors `httpd_config_t` (esp_http_server.h). All scalar/pointer; no bitfields.
pub const Config = extern struct {
    task_priority: c_uint,
    stack_size: usize,
    core_id: c_int, // BaseType_t
    task_caps: u32,
    max_req_hdr_len: usize,
    max_uri_len: usize,
    server_port: u16,
    ctrl_port: u16,
    max_open_sockets: u16,
    max_uri_handlers: u16,
    max_resp_headers: u16,
    backlog_conn: u16,
    lru_purge_enable: bool,
    recv_wait_timeout: u16,
    send_wait_timeout: u16,
    global_user_ctx: ?*anyopaque = null,
    global_user_ctx_free_fn: ?*const fn (?*anyopaque) callconv(.c) void = null,
    global_transport_ctx: ?*anyopaque = null,
    global_transport_ctx_free_fn: ?*const fn (?*anyopaque) callconv(.c) void = null,
    enable_so_linger: bool = false,
    linger_timeout: c_int = 0,
    keep_alive_enable: bool = false,
    keep_alive_idle: c_int = 0,
    keep_alive_interval: c_int = 0,
    keep_alive_count: c_int = 0,
    open_fn: ?*anyopaque = null,
    close_fn: ?*anyopaque = null,
    uri_match_fn: ?UriMatchFn = null,
};

pub extern fn httpd_start(handle: *Handle, config: *const Config) c_int;
pub extern fn httpd_register_uri_handler(handle: Handle, uri: *const UriEntry) c_int;
pub extern fn httpd_resp_send(req: *Req, buf: [*]const u8, len: c_int) c_int;
pub extern fn httpd_resp_send_chunk(req: *Req, buf: [*]const u8, len: c_int) c_int;
/// `httpd_resp_sendstr_chunk` is `static inline` in the header, so we provide
/// the equivalent ourselves: NULL terminates the chunked response stream.
pub inline fn httpd_resp_sendstr_chunk(req: *Req, str: ?[*:0]const u8) c_int {
    const ptr: [*]const u8 = if (str) |s| @ptrCast(s) else "";
    const len: c_int = if (str) |s| @intCast(std.mem.len(s)) else 0;
    return httpd_resp_send_chunk(req, ptr, len);
}
pub extern fn httpd_resp_set_hdr(req: *Req, key: [*:0]const u8, value: [*:0]const u8) c_int;
pub extern fn httpd_uri_match_wildcard(
    reference_uri: [*:0]const u8,
    uri_to_match: [*:0]const u8,
    match_upto: usize,
) callconv(.c) bool;

// FreeRTOS constants used to populate Config.
pub const tskIDLE_PRIORITY: c_uint = 0;
pub const tskNO_AFFINITY: c_int = 0x7FFFFFFF;

// heap_caps.h constants used by Config.task_caps.
pub const MALLOC_CAP_8BIT: u32 = 1 << 2;
pub const MALLOC_CAP_INTERNAL: u32 = 1 << 11;

// Default control port used by HTTPD_DEFAULT_CONFIG().
pub const ESP_HTTPD_DEF_CTRL_PORT: u16 = 32768;
