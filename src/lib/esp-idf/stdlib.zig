//! Standard C library bits we cross over to from Zig.

pub extern fn malloc(size: usize) ?*anyopaque;
pub extern fn free(ptr: ?*anyopaque) void;

pub const O_RDONLY: c_int = 0;
pub extern fn open(pathname: [*:0]const u8, flags: c_int) c_int;
pub extern fn close(fd: c_int) c_int;
pub extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;

// newlib re-entrant errno: `__errno()` returns a pointer to the thread-local
// `errno` slot. ESP-IDF's libc plumbing wires `errno` through this.
extern fn __errno() *c_int;
pub inline fn errno() c_int {
    return __errno().*;
}

// POSIX directory iteration. ESP-IDF's `struct dirent` lives in
// newlib/platform_include/sys/dirent.h: `{ ino_t d_ino; uint8_t d_type;
// char d_name[256]; }`. d_name immediately follows d_type with no padding.
pub const Dir = opaque {};
pub const DT_UNKNOWN: u8 = 0;
pub const DT_REG: u8 = 1;
pub const DT_DIR: u8 = 2;

pub const Dirent = extern struct {
    d_ino: c_long,
    d_type: u8,
    d_name: [256]u8,
};

pub extern fn opendir(name: [*:0]const u8) ?*Dir;
pub extern fn readdir(dirp: *Dir) ?*Dirent;
pub extern fn closedir(dirp: *Dir) c_int;
