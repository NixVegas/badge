//! Standard C library bits we cross over to from Zig.

pub extern fn malloc(size: usize) ?*anyopaque;
pub extern fn free(ptr: ?*anyopaque) void;
