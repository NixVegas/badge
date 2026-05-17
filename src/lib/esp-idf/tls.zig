//! esp_tls_* bindings.

pub extern fn esp_tls_init_global_ca_store() c_int;

// `esp_tls_get_and_clear_last_error(handle, esp_tls_code, esp_tls_flags)`
// where `handle` is an `esp_tls_last_error_t *`.
pub extern fn esp_tls_get_and_clear_last_error(
    handle: ?*anyopaque,
    esp_tls_code: ?*c_int,
    esp_tls_flags: ?*c_int,
) c_int;
