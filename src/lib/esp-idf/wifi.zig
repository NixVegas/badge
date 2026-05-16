const std = @import("std");
const options = @import("options");
const sys = @import("sys.zig");

pub const OsiFuncs = opaque {};

/// `wpa_crypto_funcs_t` (esp_wifi_crypto_types.h): two u32s + 10 function
/// pointers = 48 bytes. We never construct one; ESP-IDF exports a fully
/// populated `g_wifi_default_wpa_crypto_funcs` that callers copy in.
pub const CryptoFuncs = extern struct {
    size: u32,
    version: u32,
    fns: [10]?*const anyopaque,
};

extern const g_wifi_osi_funcs: OsiFuncs;
pub extern const g_wifi_default_wpa_crypto_funcs: CryptoFuncs;

/// `wifi_interface_t` (esp_wifi_types.h).
pub const Interface = enum(c_uint) {
    sta = 0,
    ap = 1,
    nan = 2,
};

/// `wifi_mode_t` (esp_wifi_types.h).
pub const Mode = enum(c_uint) {
    null = 0,
    sta = 1,
    ap = 2,
    apsta = 3,
    nan = 4,
};

/// `wifi_storage_t` (esp_wifi_types.h).
pub const Storage = enum(c_uint) {
    flash = 0,
    ram = 1,
};

// Constants from esp_wifi.h that aren't pulled directly from sdkconfig.
pub const INIT_CONFIG_MAGIC: c_int = 0x1F2F3F4F;
pub const FEATURE_CAPS: u64 = 0; // We don't depend on individual feature flags.

extern fn esp_wifi_sta_get_rssi(*c_int) sys.Error;
pub extern fn esp_wifi_set_mode(mode: Mode) sys.Error;
pub extern fn esp_wifi_set_storage(storage: Storage) sys.Error;
pub extern fn esp_wifi_get_mac(interface: Interface, mac: *[6]u8) sys.Error;

pub fn getStaRssi() !c_int {
    var rssi: c_int = 0;
    try esp_wifi_sta_get_rssi(&rssi).throw();
    return rssi;
}

// wifi_config_t is a union of wifi_ap_config_t / wifi_sta_config_t / wifi_nan_config_t.
// The STA variant carries C bitfields, so we hand ESP-IDF a properly sized zeroed
// buffer and poke the fields we care about by offset. Both AP and STA variants
// start with ssid[32]+password[64].
//
// Sizes (ESP-IDF 5.5, RISC-V, default Kconfig):
//   wifi_ap_config_t  = 132
//   wifi_sta_config_t = 184
//   wifi_nan_config_t =   8
const wifi_config_size: usize = 200;
const sta_pmf_required_offset: usize = 129;
const ap_pmf_required_offset: usize = 118;

const ConfigBuf = extern struct {
    bytes: [wifi_config_size]u8 align(4) = @splat(0),
};

extern fn esp_bridge_wifi_set_config(interface: Interface, conf: *const anyopaque) sys.Error;

inline fn fillSsidPassword(buf: *ConfigBuf, ssid: []const u8, password: []const u8) void {
    const n_ssid = @min(ssid.len, 32);
    const n_pass = @min(password.len, 64);
    @memcpy(buf.bytes[0..n_ssid], ssid[0..n_ssid]);
    @memcpy(buf.bytes[32 .. 32 + n_pass], password[0..n_pass]);
}

pub fn setStaConfig(ssid: []const u8, password: []const u8) !void {
    var buf = ConfigBuf{};
    fillSsidPassword(&buf, ssid, password);
    buf.bytes[sta_pmf_required_offset] = 1;
    try esp_bridge_wifi_set_config(.sta, &buf).throw();
}

pub fn setApConfig(ssid: []const u8, password: []const u8) !void {
    var buf = ConfigBuf{};
    fillSsidPassword(&buf, ssid, password);
    buf.bytes[ap_pmf_required_offset] = 0;
    try esp_bridge_wifi_set_config(.ap, &buf).throw();
}

pub const Addr = extern union {
    addr: [6]u8,
    mip: Mip,

    pub const Mip = extern struct {
        addr: [4]u8,
        port: u16,
    };

    pub fn formatAddr(self: *const Addr, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return try writer.print("{x:02}:{x:02}:{x:02}:{x:02}:{x:02}:{x:02}", .{
            self.addr[0], self.addr[1], self.addr[2], self.addr[3], self.addr[4], self.addr[5],
        });
    }

    pub fn formatMip(self: *const Addr, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return try writer.print("{d}.{d}.{d}.{d}:{d}", .{
            self.mip.addr[0], self.mip.addr[1], self.mip.addr[2], self.mip.addr[3], self.mip.port,
        });
    }
};

/// Mirror of `wifi_init_config_t` (esp_wifi.h). Field order, types, and the
/// default values must stay in sync with WIFI_INIT_CONFIG_DEFAULT() - see
/// `esp_wifi.h` in the active ESP-IDF release.
pub const InitConfig = extern struct {
    osi_funcs: *const OsiFuncs = &g_wifi_osi_funcs,
    wpa_crypto_funcs: CryptoFuncs,
    static_rx_buf_num: c_int = @intCast(options.ESP_WIFI_STATIC_RX_BUFFER_NUM),
    dynamic_rx_buf_num: c_int = @intCast(options.ESP_WIFI_DYNAMIC_RX_BUFFER_NUM),
    tx_buf_type: c_int = @intCast(options.ESP_WIFI_TX_BUFFER_TYPE),
    static_tx_buf_num: c_int = @intCast(options.ESP_WIFI_STATIC_TX_BUFFER_NUM),
    dynamic_tx_buf_num: c_int = @intCast(options.ESP_WIFI_DYNAMIC_TX_BUFFER_NUM),
    rx_mgmt_buf_type: c_int = @intCast(options.ESP_WIFI_DYNAMIC_RX_MGMT_BUF),
    rx_mgmt_buf_num: c_int = @intCast(options.ESP_WIFI_RX_MGMT_BUF_NUM_DEF),
    cache_tx_buf_num: c_int = @intCast(options.ESP_WIFI_CACHE_TX_BUFFER_NUM),
    csi_enable: c_int = 0,
    ampdu_rx_enable: c_int = 1,
    ampdu_tx_enable: c_int = 1,
    amsdu_tx_enable: c_int = 0,
    nvs_enable: c_int = 1,
    nano_enable: c_int = 0,
    rx_ba_win: c_int = @intCast(options.ESP_WIFI_RX_BA_WIN),
    wifi_task_core_id: c_int = 0,
    beacon_max_len: c_int = @intCast(options.ESP_WIFI_SOFTAP_BEACON_MAX_LEN),
    mgmt_sbuf_num: c_int = @intCast(options.ESP_WIFI_MGMT_SBUF_NUM),
    feature_caps: u64 = FEATURE_CAPS,
    sta_disconnected_pm: bool = true,
    espnow_max_encrypt_num: c_int = @intCast(options.ESP_WIFI_ESPNOW_MAX_ENCRYPT_NUM),
    tx_hetb_queue_num: c_int = @intCast(options.ESP_WIFI_TX_HETB_QUEUE_NUM),
    dump_hesigb_enable: bool = true,
    magic: c_int = INIT_CONFIG_MAGIC,

    extern fn esp_wifi_init(*const InitConfig) callconv(.c) sys.Error;
    pub fn config(self: *const InitConfig) !void {
        return esp_wifi_init(self).throw();
    }
};
