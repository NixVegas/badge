const timer = @import("esp-idf").timer;

/// Milliseconds since boot from the monotonic esp_timer clock.
pub inline fn getTimestamp() i64 {
    return @divTrunc(timer.esp_timer_get_time(), 1000);
}
