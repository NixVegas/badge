//! esp_bridge_* bindings (iot_bridge component).

const netif = @import("netif.zig");
const wifi_iface = @import("wifi.zig").Interface;

pub extern fn esp_bridge_create_softap_netif(
    ip_info: ?*anyopaque,
    mac: ?*anyopaque,
    data_forward: bool,
    enable_dhcps: bool,
) ?*netif.Netif;

pub extern fn esp_bridge_create_station_netif(
    ip_info: ?*anyopaque,
    mac: ?*anyopaque,
    data_forward: bool,
    enable_dhcps: bool,
) ?*netif.Netif;

pub extern fn esp_bridge_wifi_set_config(interface: wifi_iface, config: *const anyopaque) c_int;
