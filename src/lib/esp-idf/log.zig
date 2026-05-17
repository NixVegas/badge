//! esp_log_* bindings. (Most of the Zig-side log infra lives in sys.zig.)

const sys = @import("sys.zig");

pub const Level = sys.LogLevel;
pub const write = sys.logWrite;
