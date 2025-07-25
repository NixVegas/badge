const std = @import("std");
const c = @import("../esp-idf.zig").c;
const sys = @import("sys.zig");

pub const OsiFuncs = opaque {};
pub const CryptoFuncs = c.wpa_crypto_funcs_t;

extern const g_wifi_osi_funcs: OsiFuncs;
pub extern const g_wifi_default_wpa_crypto_funcs: CryptoFuncs;

pub const Addr = extern union {
    addr: [6]u8,
    mip: Mip,

    pub const Mip = extern struct {
        addr: [4]u8,
        port: u16,
    };

    pub fn formatAddr(self: *const Addr, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return try writer.print("{x:02}:{x:02}:{x:02}:{x:02}:{x:02}:{x:02}", .{
            self.addr[0],
            self.addr[1],
            self.addr[2],
            self.addr[3],
            self.addr[4],
            self.addr[5],
        });
    }

    pub fn formatMip(self: *const Addr, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return try writer.print("{d}.{d}.{d}.{d}:{d}", .{
            self.mip.addr[0],
            self.mip.addr[1],
            self.mip.addr[2],
            self.mip.addr[3],
            self.mip.port,
        });
    }
};

pub const InitConfig = extern struct {
    osi_funcs: *const OsiFuncs = &g_wifi_osi_funcs,
    wpa_crypto_funcs: CryptoFuncs,
    static_rx_buf_num: c_int = c.CONFIG_ESP_WIFI_STATIC_RX_BUFFER_NUM,
    dynamic_rx_buf_num: c_int = c.CONFIG_ESP_WIFI_DYNAMIC_RX_BUFFER_NUM,
    tx_buf_type: c_int = c.CONFIG_ESP_WIFI_TX_BUFFER_TYPE,
    static_tx_buf_num: c_int = c.WIFI_STATIC_TX_BUFFER_NUM,
    dynamic_tx_buf_num: c_int = c.WIFI_DYNAMIC_TX_BUFFER_NUM,
    rx_mgmt_buf_type: c_int = c.CONFIG_ESP_WIFI_DYNAMIC_RX_MGMT_BUF,
    rx_mgmt_buf_num: c_int = c.WIFI_RX_MGMT_BUF_NUM_DEF,
    cache_tx_buf_num: c_int = c.WIFI_CACHE_TX_BUFFER_NUM,
    csi_enable: c_int = c.WIFI_CSI_ENABLED,
    ampdu_rx_enable: c_int = c.WIFI_AMPDU_RX_ENABLED,
    ampdu_tx_enable: c_int = c.WIFI_AMPDU_TX_ENABLED,
    amsdu_tx_enable: c_int = c.WIFI_AMSDU_TX_ENABLED,
    nvs_enable: c_int = c.WIFI_NVS_ENABLED,
    nano_enable: c_int = c.WIFI_NANO_FORMAT_ENABLED,
    rx_ba_win: c_int = c.WIFI_DEFAULT_RX_BA_WIN,
    wifi_task_core_id: c_int = c.WIFI_TASK_CORE_ID,
    beacon_max_len: c_int = c.WIFI_SOFTAP_BEACON_MAX_LEN,
    mgmt_sbuf_num: c_int = c.WIFI_MGMT_SBUF_NUM,
    feature_caps: u64 = c.WIFI_FEATURE_CAPS,
    sta_disconnected_pm: bool = true,
    espnow_max_encrypt_num: c_int = c.CONFIG_ESP_WIFI_ESPNOW_MAX_ENCRYPT_NUM,
    tx_hetb_queue_num: c_int = c.WIFI_TX_HETB_QUEUE_NUM,
    dump_hesigb_enable: bool = true,
    magic: c_int = c.WIFI_INIT_CONFIG_MAGIC,

    extern fn esp_wifi_init(*const InitConfig) callconv(.C) sys.Error;
    pub fn config(self: *const InitConfig) !void {
        return esp_wifi_init(self).throw();
    }
};
