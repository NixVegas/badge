//! esp_timer_* bindings.

pub extern fn esp_timer_get_time() callconv(.c) i64;
