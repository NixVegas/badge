const std = @import("std");
const c = @import("esp-idf").c;

// cImport renders rmt_symbol_word_t / rmt_bytes_encoder_config_t as opaque
// because of their bitfield-containing nested struct/union. Mirror the
// layouts here so the structs are constructible in Zig.
const Symbol = extern union {
    val: u32,
};

const BytesEncoderConfig = extern struct {
    bit0: Symbol,
    bit1: Symbol,
    flags: u32,
};

const CopyEncoderConfig = extern struct {};

extern fn rmt_new_bytes_encoder(config: *const BytesEncoderConfig, ret_encoder: *c.rmt_encoder_handle_t) c.esp_err_t;
extern fn rmt_new_copy_encoder(config: *const CopyEncoderConfig, ret_encoder: *c.rmt_encoder_handle_t) c.esp_err_t;

const Encoder = extern struct {
    base: c.rmt_encoder_t,
    bytes_encoder: c.rmt_encoder_handle_t,
    copy_encoder: c.rmt_encoder_handle_t,
    state: c_int,
    reset_code: Symbol,
};

inline fn symbol(level0: u1, duration0: u15, level1: u1, duration1: u15) Symbol {
    return .{ .val = @as(u32, duration0) |
        (@as(u32, level0) << 15) |
        (@as(u32, duration1) << 16) |
        (@as(u32, level1) << 31) };
}

fn encode(
    encoder_ptr: [*c]c.rmt_encoder_t,
    channel: c.rmt_channel_handle_t,
    primary_data: ?*const anyopaque,
    data_size: usize,
    ret_state: [*c]c.rmt_encode_state_t,
) callconv(.c) usize {
    const base: *c.rmt_encoder_t = @ptrCast(encoder_ptr);
    const self: *Encoder = @fieldParentPtr("base", base);
    var session_state: c.rmt_encode_state_t = c.RMT_ENCODING_RESET;
    var out_state: c.rmt_encode_state_t = c.RMT_ENCODING_RESET;
    var encoded: usize = 0;

    switch (self.state) {
        0 => {
            const benc = self.bytes_encoder;
            encoded += benc.*.encode.?(benc, channel, primary_data, data_size, &session_state);
            if ((session_state & c.RMT_ENCODING_COMPLETE) != 0) {
                self.state = 1;
            }
            if ((session_state & c.RMT_ENCODING_MEM_FULL) != 0) {
                out_state |= c.RMT_ENCODING_MEM_FULL;
                ret_state[0] = out_state;
                return encoded;
            }
            // fall through to state 1
            const cenc = self.copy_encoder;
            encoded += cenc.*.encode.?(cenc, channel, &self.reset_code, @sizeOf(Symbol), &session_state);
            if ((session_state & c.RMT_ENCODING_COMPLETE) != 0) {
                self.state = c.RMT_ENCODING_RESET;
                out_state |= c.RMT_ENCODING_COMPLETE;
            }
            if ((session_state & c.RMT_ENCODING_MEM_FULL) != 0) {
                out_state |= c.RMT_ENCODING_MEM_FULL;
            }
        },
        1 => {
            const cenc = self.copy_encoder;
            encoded += cenc.*.encode.?(cenc, channel, &self.reset_code, @sizeOf(Symbol), &session_state);
            if ((session_state & c.RMT_ENCODING_COMPLETE) != 0) {
                self.state = c.RMT_ENCODING_RESET;
                out_state |= c.RMT_ENCODING_COMPLETE;
            }
            if ((session_state & c.RMT_ENCODING_MEM_FULL) != 0) {
                out_state |= c.RMT_ENCODING_MEM_FULL;
            }
        },
        else => {},
    }

    ret_state[0] = out_state;
    return encoded;
}

fn del(encoder_ptr: [*c]c.rmt_encoder_t) callconv(.c) c.esp_err_t {
    const base: *c.rmt_encoder_t = @ptrCast(encoder_ptr);
    const self: *Encoder = @fieldParentPtr("base", base);
    _ = c.rmt_del_encoder(self.bytes_encoder);
    _ = c.rmt_del_encoder(self.copy_encoder);
    c.free(self);
    return c.ESP_OK;
}

fn reset(encoder_ptr: [*c]c.rmt_encoder_t) callconv(.c) c.esp_err_t {
    const base: *c.rmt_encoder_t = @ptrCast(encoder_ptr);
    const self: *Encoder = @fieldParentPtr("base", base);
    _ = c.rmt_encoder_reset(self.bytes_encoder);
    _ = c.rmt_encoder_reset(self.copy_encoder);
    self.state = c.RMT_ENCODING_RESET;
    return c.ESP_OK;
}

/// Allocate and configure a WS2812 LED strip encoder. On success, writes the
/// encoder handle to `ret_encoder` and returns ESP_OK.
pub fn new(resolution_hz: u32, ret_encoder: *c.rmt_encoder_handle_t) c.esp_err_t {
    const mem = c.rmt_alloc_encoder_mem(@sizeOf(Encoder)) orelse return c.ESP_ERR_NO_MEM;
    const self: *Encoder = @ptrCast(@alignCast(mem));
    self.* = std.mem.zeroes(Encoder);
    self.base.encode = &encode;
    self.base.del = &del;
    self.base.reset = &reset;

    const ticks_per_us = resolution_hz / 1_000_000;
    const t0h: u15 = @intCast(ticks_per_us * 3 / 10); // 0.3us
    const t0l: u15 = @intCast(ticks_per_us * 9 / 10); // 0.9us
    const t1h: u15 = @intCast(ticks_per_us * 9 / 10); // 0.9us
    const t1l: u15 = @intCast(ticks_per_us * 3 / 10); // 0.3us

    const bytes_config = BytesEncoderConfig{
        .bit0 = symbol(1, t0h, 0, t0l),
        .bit1 = symbol(1, t1h, 0, t1l),
        .flags = 1, // msb_first bit
    };

    var rc = rmt_new_bytes_encoder(&bytes_config, &self.bytes_encoder);
    if (rc != c.ESP_OK) {
        c.free(self);
        return rc;
    }

    const copy_config = CopyEncoderConfig{};
    rc = rmt_new_copy_encoder(&copy_config, &self.copy_encoder);
    if (rc != c.ESP_OK) {
        _ = c.rmt_del_encoder(self.bytes_encoder);
        c.free(self);
        return rc;
    }

    // 50us reset code split across two halves.
    const reset_ticks: u15 = @intCast(ticks_per_us * 50 / 2);
    self.reset_code = symbol(0, reset_ticks, 0, reset_ticks);

    ret_encoder.* = &self.base;
    return c.ESP_OK;
}
