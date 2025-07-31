extern fn nixbadge_timestamp_now() callconv(.C) i64;
pub const getTimestamp = nixbadge_timestamp_now;
