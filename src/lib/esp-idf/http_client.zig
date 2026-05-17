//! esp_http_client_* bindings.

pub const Handle = ?*anyopaque;

pub const EventId = enum(c_int) {
    ERROR = 0,
    ON_CONNECTED = 1,
    HEADERS_SENT = 2,
    ON_HEADER = 3,
    ON_DATA = 4,
    ON_FINISH = 5,
    DISCONNECTED = 6,
    REDIRECT = 7,
    _,
};

pub const TransportType = enum(c_int) {
    unknown = 0,
    over_tcp = 1,
    over_ssl = 2,
    _,
};

/// `esp_http_client_event_t` (esp_http_client.h).
pub const Event = extern struct {
    event_id: EventId,
    client: Handle,
    data: ?*anyopaque,
    data_len: c_int,
    user_data: ?*anyopaque,
    header_key: ?[*:0]const u8,
    header_value: ?[*:0]const u8,
};

pub const EventHandler = *const fn (event: *Event) callconv(.c) c_int;

/// Mirrors `esp_http_client_config_t` (esp_http_client.h, ESP-IDF 5.5).
/// Order, types, and Kconfig gates must match the current sdkconfig.
pub const Config = extern struct {
    url: ?[*:0]const u8 = null,
    host: ?[*:0]const u8 = null,
    port: c_int = 0,
    username: ?[*:0]const u8 = null,
    password: ?[*:0]const u8 = null,
    auth_type: c_int = 0,
    path: ?[*:0]const u8 = null,
    query: ?[*:0]const u8 = null,
    cert_pem: ?[*:0]const u8 = null, // anonymous union of cert_pem/cert_der
    cert_len: usize = 0,
    client_cert_pem: ?[*:0]const u8 = null, // anonymous union of client_cert_pem/_der
    client_cert_len: usize = 0,
    client_key_pem: ?[*:0]const u8 = null,
    client_key_len: usize = 0,
    client_key_password: ?[*:0]const u8 = null,
    client_key_password_len: usize = 0,
    tls_version: c_int = 0,
    user_agent: ?[*:0]const u8 = null,
    method: c_int = 0,
    timeout_ms: c_int = 0,
    disable_auto_redirect: bool = false,
    max_redirection_count: c_int = 0,
    max_authorization_retries: c_int = 0,
    event_handler: ?EventHandler = null,
    transport_type: TransportType = .unknown,
    buffer_size: c_int = 0,
    buffer_size_tx: c_int = 0,
    user_data: ?*anyopaque = null,
    is_async: bool = false,
    use_global_ca_store: bool = false,
    skip_cert_common_name_check: bool = false,
    common_name: ?[*:0]const u8 = null,
    crt_bundle_attach: ?*const fn (conf: ?*anyopaque) callconv(.c) c_int = null,
    keep_alive_enable: bool = false,
    keep_alive_idle: c_int = 0,
    keep_alive_interval: c_int = 0,
    keep_alive_count: c_int = 0,
    if_name: ?*anyopaque = null, // struct ifreq*
    alpn_protos: ?[*]const ?[*:0]const u8 = null, // CONFIG_ESP_HTTP_CLIENT_ENABLE_HTTPS (on)
    addr_type: c_int = 0,
};

pub extern fn esp_http_client_init(config: *const Config) Handle;
pub extern fn esp_http_client_perform(client: Handle) c_int;
pub extern fn esp_http_client_cleanup(client: Handle) c_int;
