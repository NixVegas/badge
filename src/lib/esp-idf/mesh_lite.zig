//! esp_mesh_lite_* bindings (espressif/mesh_lite managed component).

pub const ROOT: c_int = 1;

// esp_mesh_lite_msg_data_t enum from esp_mesh_lite_core.h:
//   ESP_MESH_LITE_JSON_MSG = 0
//   ESP_MESH_LITE_RAW_MSG  = 1
//   ESP_MESH_LITE_OTHER_MSG = 2
pub const ESP_MESH_LITE_JSON_MSG: c_int = 0;
pub const ESP_MESH_LITE_RAW_MSG: c_int = 1;
pub const ESP_MESH_LITE_OTHER_MSG: c_int = 2;

pub const SendBroadcastRawFn = *const fn (
    data: ?[*]const u8,
    size: usize,
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

pub const RawSendFailFn = *const fn (msg_id: u32) callconv(.c) void;

pub const RawMsgConfig = extern struct {
    msg_id: u32 = 0,
    expect_resp_msg_id: u32 = 0,
    max_retry: u32 = 0,
    retry_interval: u16 = 0,
    data: ?[*]const u8 = null,
    size: usize = 0,
    raw_resend: ?SendBroadcastRawFn = null,
    raw_send_fail: ?RawSendFailFn = null,
};

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
    data: ?[*]const u8,
    size: usize,
) callconv(.c) c_int;
pub extern fn esp_mesh_lite_send_broadcast_raw_msg_to_parent(
    data: ?[*]const u8,
    size: usize,
) callconv(.c) c_int;
