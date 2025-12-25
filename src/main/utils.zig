extern fn nixbadge_timestamp_now() callconv(.c) i64;
pub const getTimestamp = nixbadge_timestamp_now;
