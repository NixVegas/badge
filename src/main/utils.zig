extern fn esp_timer_get_time() callconv(.c) i64;

/// Milliseconds since boot from the monotonic esp_timer clock.
pub inline fn getTimestamp() i64 {
    return @divTrunc(esp_timer_get_time(), 1000);
}
