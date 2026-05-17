//! esp_netif_* bindings.

pub const Netif = opaque {};

pub const Ip4Addr = extern struct {
    addr: u32,
};

pub const Ip6Addr = extern struct {
    addr: [4]u32,
    zone: u8,
};

pub const IpInfo = extern struct {
    ip: Ip4Addr,
    netmask: Ip4Addr,
    gw: Ip4Addr,
};

pub const IpEventGotIp = extern struct {
    esp_netif: ?*Netif,
    ip_info: IpInfo,
    ip_changed: bool,
};

// `esp_event_base_t` is `const char *`. The `IP_EVENT` symbol is the string
// identifier defined via `ESP_EVENT_DEFINE_BASE(IP_EVENT)` in esp_netif.
pub const EventBase = [*:0]const u8;
pub extern const IP_EVENT: EventBase;

// ip_event_t enum (esp_netif_types.h)
pub const IP_EVENT_STA_GOT_IP: i32 = 0;

pub extern fn esp_netif_init() c_int;
pub extern fn esp_netif_get_ip_info(esp_netif: ?*Netif, ip_info: *IpInfo) c_int;
