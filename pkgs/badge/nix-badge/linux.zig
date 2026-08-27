//! The Linux kernel-ABI layer: raw syscalls and the uAPI structs/ioctls this
//! tool drives (spidev, i2c-dev, the GPIO character device v2, statx, mmap).
//!
//! Zig 0.16's `std.posix` no longer exposes plain open/write/close/mkdir, and no
//! std wrapper covers `ioctl` with these device structs, so we call
//! `std.os.linux` directly. Every wrapper returns an error union decoded from the
//! raw -errno return, per the Backbone Rule (never assume I/O succeeds).
//!
//! The ioctl request numbers are the encoded `_IOC(dir,type,nr,size)` constants
//! from the 6.x kernel headers, identical across aarch64 and riscv64 (both LP64).
//! They are cited by their header symbol at each definition.

const std = @import("std");
const linux = std.os.linux;

pub const O = linux.O;
pub const PROT = linux.PROT;
pub const MAP = linux.MAP;
pub const fd_t = i32;

// Signal handling surface used by the service loops.
pub const SIG = linux.SIG;
pub const Sigaction = linux.Sigaction;
pub const sigemptyset = linux.sigemptyset;

/// Install a handler for `sig`. A failure would mean we passed an invalid signal
/// number (KILL/STOP or out of range), which is a programmer error, so assert.
pub fn sigaction(sig: SIG, act: *const Sigaction) void {
    const rc = linux.sigaction(sig, act, null);
    std.debug.assert(linux.errno(rc) == .SUCCESS);
}

/// A syscall failed. The specific errno is logged at the recovery site; callers
/// that must branch on it use the `*Errno` variants below.
pub const Error = error{Io};

fn decode(ret: usize) Error!usize {
    return switch (linux.errno(ret)) {
        .SUCCESS => ret,
        else => error.Io,
    };
}

pub fn open(path: [*:0]const u8, flags: O, mode: linux.mode_t) Error!fd_t {
    const ret = linux.open(path, flags, mode);
    return @intCast(try decode(ret));
}

pub fn close(fd: fd_t) void {
    // A close() error is not actionable (the fd is released regardless) and EBADF
    // would mean a double close, our bug; either way we do not branch on it.
    const rc = linux.close(fd);
    std.debug.assert(linux.errno(rc) != .BADF);
}

pub fn read(fd: fd_t, buf: []u8) Error!usize {
    return decode(linux.read(fd, buf.ptr, buf.len));
}

pub fn write(fd: fd_t, buf: []const u8) Error!usize {
    return decode(linux.write(fd, buf.ptr, buf.len));
}

/// Read the whole file at `path` into `buf`, returning the bytes read, or null on
/// any open/read fault (the caller treats a missing sysfs node as "unavailable").
pub fn readFile(path: [*:0]const u8, buf: []u8) ?[]u8 {
    const fd = open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return null;
    defer close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const r = read(fd, buf[n..]) catch return null;
        if (r == 0) break;
        n += r;
    }
    return buf[0..n];
}

/// Truncate-create `path` and write `data` in full. Used for the tiny runtime
/// config; a short write is retried until the buffer is drained.
pub fn writeFile(path: [*:0]const u8, data: []const u8) Error!void {
    const fd = try open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer close(fd);
    var n: usize = 0;
    while (n < data.len) {
        n += try write(fd, data[n..]);
    }
}

/// mkdir(); EEXIST is reported distinctly so callers can treat "already there" as
/// success while still surfacing a real failure (EACCES, ENOSPC, ...).
pub const MkdirResult = enum { created, exists, failed };
pub fn mkdir(path: [*:0]const u8, mode: linux.mode_t) MkdirResult {
    return switch (linux.errno(linux.mkdir(path, mode))) {
        .SUCCESS => .created,
        .EXIST => .exists,
        else => .failed,
    };
}

pub fn mmapRead(fd: fd_t, len: usize) Error![]align(std.heap.page_size_min) u8 {
    const ret = linux.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    _ = try decode(ret);
    const p: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(ret);
    return p[0..len];
}

pub fn mmapShared(fd: fd_t, len: usize, offset: i64) Error![]align(std.heap.page_size_min) u8 {
    const prot: PROT = .{ .READ = true, .WRITE = true };
    const ret = linux.mmap(null, len, prot, .{ .TYPE = .SHARED }, fd, offset);
    _ = try decode(ret);
    const p: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(ret);
    return p[0..len];
}

pub fn munmap(mem: []align(std.heap.page_size_min) const u8) void {
    // EINVAL here would mean we passed a mapping we did not create, our bug.
    const rc = linux.munmap(mem.ptr, mem.len);
    std.debug.assert(linux.errno(rc) == .SUCCESS);
}

/// ioctl with a pointer/scalar argument. Returns the raw signed result so the
/// GPIO helpers can read back the request fd the kernel writes into the struct.
pub fn ioctl(fd: fd_t, request: u32, arg: usize) Error!usize {
    return decode(linux.ioctl(fd, request, arg));
}

pub const pollfd = linux.pollfd;
pub const POLLIN: i16 = 0x001;

/// Wait up to `timeout_ms` for readiness on `fds`. Returns the number of ready
/// fds (0 on timeout), or null when the wait was interrupted by a signal
/// (EINTR): the caller re-checks its signal flags and re-polls. Any other errno
/// is a bad request, our bug, so assert.
pub fn poll(fds: []pollfd, timeout_ms: i32) ?usize {
    const rc = linux.poll(fds.ptr, @intCast(fds.len), timeout_ms);
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .INTR => null,
        else => {
            std.debug.assert(false);
            return 0;
        },
    };
}

/// Modification time of `path` via statx, or null on any error. Used to detect a
/// runtime-config change without holding the file open.
pub fn mtimeNsec(path: [*:0]const u8) ?i128 {
    // statx fills stx before we read it, and only on the .SUCCESS path below.
    var stx: linux.Statx = undefined; // zippy:ignore unsafe_undefined
    const rc = linux.statx(linux.AT.FDCWD, path, 0, .{ .MTIME = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @as(i128, stx.mtime.sec) * std.time.ns_per_s + stx.mtime.nsec;
}

/// Size in bytes of an open fd via statx, or null on error.
pub fn fileSize(fd: fd_t) ?u64 {
    // zippy:ignore unsafe_undefined -- statx fills stx before we read stx.size.
    var stx: linux.Statx = undefined;
    const empty: [*:0]const u8 = "";
    const rc = linux.statx(fd, empty, linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return stx.size;
}

/// Sleep for `total_ns`, letting a signal cut it short (nanosleep with a null
/// remainder: an interrupted sleep just returns early, which is fine here).
pub fn sleepNsec(total_ns: u64) void {
    const req: linux.timespec = .{
        .sec = @intCast(total_ns / std.time.ns_per_s),
        .nsec = @intCast(total_ns % std.time.ns_per_s),
    };
    // EINTR (a signal broke the sleep) is expected and benign; any other error is
    // a bad request, our bug.
    const rc = linux.nanosleep(&req, null);
    std.debug.assert(linux.errno(rc) == .SUCCESS or linux.errno(rc) == .INTR);
}

/// Read `clock_id` into a timespec. A failure means an invalid clock id, our bug,
/// so assert; the clock reads below cannot fail at runtime.
fn clockGet(clock_id: linux.clockid_t) linux.timespec {
    // zippy:ignore unsafe_undefined -- clock_gettime fills ts before we read it.
    var ts: linux.timespec = undefined;
    const rc = linux.clock_gettime(clock_id, &ts);
    std.debug.assert(linux.errno(rc) == .SUCCESS);
    return ts;
}

pub fn monotonicMsec() u64 {
    const ts = clockGet(.MONOTONIC);
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec * std.time.ms_per_s + nsec / std.time.ns_per_ms;
}

pub fn monotonicNsec() i128 {
    const ts = clockGet(.MONOTONIC);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

pub fn realtimeSeconds() i64 {
    const ts = clockGet(.REALTIME);
    return ts.sec;
}

// ================================================================== spidev ===
// linux/spi/spidev.h. SPI_IOC_MAGIC 'k' (0x6b).

pub const Spi = struct {
    pub const MODE_0: u8 = 0x00;
    pub const CS_HIGH: u8 = 0x04; // _BITUL(2)

    pub const IOC_WR_MODE: u32 = 0x40016b01; // _IOW('k',1,__u8)
    pub const IOC_WR_BITS_PER_WORD: u32 = 0x40016b03; // _IOW('k',3,__u8)
    pub const IOC_WR_MAX_SPEED_HZ: u32 = 0x40046b04; // _IOW('k',4,__u32)
    pub const IOC_MESSAGE_1: u32 = 0x40206b00; // SPI_IOC_MESSAGE(1) = _IOW('k',0,char[32])

    /// struct spi_ioc_transfer (32 bytes). Layout is identical in 32- and 64-bit
    /// userspace per the header note.
    pub const Transfer = extern struct {
        tx_buf: u64 = 0,
        rx_buf: u64 = 0,
        len: u32 = 0,
        speed_hz: u32 = 0,
        delay_usecs: u16 = 0,
        bits_per_word: u8 = 0,
        cs_change: u8 = 0,
        tx_nbits: u8 = 0,
        rx_nbits: u8 = 0,
        word_delay_usecs: u8 = 0,
        pad: u8 = 0,
    };

    comptime {
        std.debug.assert(@sizeOf(Transfer) == 32);
    }
};

// ================================================================= i2c-dev ===
// linux/i2c-dev.h.

pub const I2c = struct {
    pub const SLAVE: u32 = 0x0703;
};

// ================================================================ gpio uAPI ===
// linux/gpio.h, ABI v2. Struct sizes are asserted at comptime against the header
// values so a field-width mistake fails the build, not a device.

pub const Gpio = struct {
    pub const MAX_NAME_SIZE = 32;
    pub const LINES_MAX = 64;
    pub const NUM_ATTRS_MAX = 10;

    pub const FLAG_INPUT: u64 = 1 << 2; // GPIO_V2_LINE_FLAG_INPUT
    pub const FLAG_OUTPUT: u64 = 1 << 3; // GPIO_V2_LINE_FLAG_OUTPUT
    pub const FLAG_EDGE_RISING: u64 = 1 << 4; // GPIO_V2_LINE_FLAG_EDGE_RISING
    pub const FLAG_EDGE_FALLING: u64 = 1 << 5; // GPIO_V2_LINE_FLAG_EDGE_FALLING
    pub const ATTR_ID_OUTPUT_VALUES: u32 = 2; // GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES

    pub const EVENT_RISING_EDGE: u32 = 1; // GPIO_V2_LINE_EVENT_RISING_EDGE
    pub const EVENT_FALLING_EDGE: u32 = 2; // GPIO_V2_LINE_EVENT_FALLING_EDGE

    pub const GET_CHIPINFO: u32 = 0x8044b401; // GPIO_GET_CHIPINFO_IOCTL
    pub const GET_LINEINFO: u32 = 0xc100b405; // GPIO_V2_GET_LINEINFO_IOCTL
    pub const GET_LINE: u32 = 0xc250b407; // GPIO_V2_GET_LINE_IOCTL
    pub const GET_VALUES: u32 = 0xc010b40e; // GPIO_V2_LINE_GET_VALUES_IOCTL
    pub const SET_VALUES: u32 = 0xc010b40f; // GPIO_V2_LINE_SET_VALUES_IOCTL

    pub const ChipInfo = extern struct {
        name: [MAX_NAME_SIZE]u8,
        label: [MAX_NAME_SIZE]u8,
        lines: u32,
    };

    pub const LineAttribute = extern struct {
        id: u32 = 0,
        padding: u32 = 0,
        // union { u64 flags; u64 values; u32 debounce_period_us; }
        value: u64 align(8) = 0,
    };

    pub const LineConfigAttribute = extern struct {
        attr: LineAttribute = .{},
        mask: u64 align(8) = 0,
    };

    pub const LineConfig = extern struct {
        flags: u64 align(8) = 0,
        num_attrs: u32 = 0,
        padding: [5]u32 = @splat(0),
        attrs: [NUM_ATTRS_MAX]LineConfigAttribute = @splat(.{}),
    };

    pub const LineRequest = extern struct {
        offsets: [LINES_MAX]u32 = @splat(0),
        consumer: [MAX_NAME_SIZE]u8 = @splat(0),
        config: LineConfig = .{},
        num_lines: u32 = 0,
        event_buffer_size: u32 = 0,
        padding: [5]u32 = @splat(0),
        fd: i32 = 0,
    };

    pub const LineInfo = extern struct {
        name: [MAX_NAME_SIZE]u8 = @splat(0),
        consumer: [MAX_NAME_SIZE]u8 = @splat(0),
        offset: u32 = 0,
        num_attrs: u32 = 0,
        flags: u64 align(8) = 0,
        attrs: [NUM_ATTRS_MAX]LineAttribute = @splat(.{}),
        padding: [4]u32 = @splat(0),
    };

    pub const LineValues = extern struct {
        bits: u64 align(8) = 0,
        mask: u64 align(8) = 0,
    };

    /// One edge event read from a request fd opened with edge detection. `id` is
    /// EVENT_RISING_EDGE or EVENT_FALLING_EDGE.
    pub const LineEvent = extern struct {
        timestamp_ns: u64 align(8) = 0,
        id: u32 = 0,
        offset: u32 = 0,
        seqno: u32 = 0,
        line_seqno: u32 = 0,
        padding: [6]u32 = @splat(0),
    };

    comptime {
        std.debug.assert(@sizeOf(ChipInfo) == 68);
        std.debug.assert(@sizeOf(LineAttribute) == 16);
        std.debug.assert(@sizeOf(LineConfigAttribute) == 24);
        std.debug.assert(@sizeOf(LineConfig) == 272);
        std.debug.assert(@sizeOf(LineRequest) == 592);
        std.debug.assert(@sizeOf(LineInfo) == 256);
        std.debug.assert(@sizeOf(LineValues) == 16);
        std.debug.assert(@sizeOf(LineEvent) == 48);
    }
};
