//! esp_mesh_lite_* bindings (espressif/mesh_lite managed component).

pub const ROOT: c_int = 1;

pub const ESP_MESH_LITE_RAW_MSG: c_int = 0;

pub const SendBroadcastRawFn = *const fn (
    msg: ?*anyopaque,
    size: u32,
    flag: u32,
) callconv(.c) c_int;

pub const RawProcess = *const fn (
    data: [*]u8,
    len: u32,
    out_data: *[*]u8,
    out_len: *u32,
    seq: u32,
) callconv(.c) c_int;

pub const RawMsgAction = extern struct {
    msg_id: u32,
    resp_msg_id: u32,
    raw_process: RawProcess,
};

pub const RawMsgConfig = extern struct {
    msg_id: u32 = 0,
    expect_resp_msg_id: u32 = 0,
    max_retry: u8 = 0,
    retry_interval: u16 = 0,
    data: ?*anyopaque = null,
    size: u32 = 0,
    raw_resend: ?SendBroadcastRawFn = null,
};

/// `esp_mesh_lite_msg_config_t` is a union of typed msg configs. RawMsgConfig
/// is the largest variant in our usage; this struct mirrors that variant.
pub const MsgConfig = extern struct {
    raw_msg: RawMsgConfig = .{},
};

/// `esp_mesh_lite_config_t` (esp_mesh_lite_core.h).
pub const Config = extern struct {
    vendor_id: [2]u8 = .{ 0, 0 },
    mesh_id: u8 = 0,
    max_connect_number: u8 = 0,
    max_router_number: u8 = 0,
    max_level: u8 = 0,
    max_node_number: u8 = 0,
    join_mesh_ignore_router_status: bool = false,
    join_mesh_without_configured_wifi: bool = false,
    leaf_node: bool = false,
    ota_data_len: u32 = 0,
    ota_wnd: u32 = 0,
    softap_ssid: ?[*:0]const u8 = null,
    softap_password: ?[*:0]const u8 = null,
    device_category: ?[*:0]const u8 = null,
};

pub extern fn esp_mesh_lite_init(config: *const Config) c_int;
pub extern fn esp_mesh_lite_start() c_int;
pub extern fn esp_mesh_lite_get_level() c_int;
pub extern fn esp_mesh_lite_send_msg(msg_type: c_int, config: *const MsgConfig) c_int;
pub extern fn esp_mesh_lite_raw_msg_action_list_register(action: *const RawMsgAction) c_int;
pub extern fn esp_mesh_lite_get_softap_ssid_from_nvs(ssid: [*]u8, size: *usize) c_int;
pub extern fn esp_mesh_lite_get_softap_psw_from_nvs(psw: [*]u8, size: *usize) c_int;
pub extern fn esp_mesh_lite_set_softap_info(ssid: [*:0]const u8, psw: [*:0]const u8) c_int;
pub extern fn esp_mesh_lite_send_broadcast_raw_msg_to_child(
    msg: ?*anyopaque,
    size: u32,
    flag: u32,
) callconv(.c) c_int;
pub extern fn esp_mesh_lite_send_broadcast_raw_msg_to_parent(
    msg: ?*anyopaque,
    size: u32,
    flag: u32,
) callconv(.c) c_int;
