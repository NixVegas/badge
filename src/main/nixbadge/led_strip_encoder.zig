const std = @import("std");
const esp_idf = @import("esp-idf");
const rmt = esp_idf.rmt;
const c_stdlib = esp_idf.stdlib;

const Symbol = rmt.Symbol;

const Encoder = extern struct {
    base: rmt.Encoder,
    bytes_encoder: rmt.EncoderHandle,
    copy_encoder: rmt.EncoderHandle,
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
    encoder_ptr: *rmt.Encoder,
    channel: rmt.ChannelHandle,
    primary_data: ?*const anyopaque,
    data_size: usize,
    ret_state: *rmt.EncodeState,
) callconv(.c) usize {
    const self: *Encoder = @fieldParentPtr("base", encoder_ptr);
    var session_state: rmt.EncodeState = rmt.ENCODING_RESET;
    var out_state: rmt.EncodeState = rmt.ENCODING_RESET;
    var encoded: usize = 0;

    switch (self.state) {
        0 => {
            const benc = self.bytes_encoder.?;
            encoded += benc.encode.?(benc, channel, primary_data, data_size, &session_state);
            if ((session_state & rmt.ENCODING_COMPLETE) != 0) {
                self.state = 1;
            }
            if ((session_state & rmt.ENCODING_MEM_FULL) != 0) {
                out_state |= rmt.ENCODING_MEM_FULL;
                ret_state.* = out_state;
                return encoded;
            }
            const cenc = self.copy_encoder.?;
            encoded += cenc.encode.?(cenc, channel, &self.reset_code, @sizeOf(Symbol), &session_state);
            if ((session_state & rmt.ENCODING_COMPLETE) != 0) {
                self.state = @intCast(rmt.ENCODING_RESET);
                out_state |= rmt.ENCODING_COMPLETE;
            }
            if ((session_state & rmt.ENCODING_MEM_FULL) != 0) {
                out_state |= rmt.ENCODING_MEM_FULL;
            }
        },
        1 => {
            const cenc = self.copy_encoder.?;
            encoded += cenc.encode.?(cenc, channel, &self.reset_code, @sizeOf(Symbol), &session_state);
            if ((session_state & rmt.ENCODING_COMPLETE) != 0) {
                self.state = @intCast(rmt.ENCODING_RESET);
                out_state |= rmt.ENCODING_COMPLETE;
            }
            if ((session_state & rmt.ENCODING_MEM_FULL) != 0) {
                out_state |= rmt.ENCODING_MEM_FULL;
            }
        },
        else => {},
    }

    ret_state.* = out_state;
    return encoded;
}

fn del(encoder_ptr: *rmt.Encoder) callconv(.c) c_int {
    const self: *Encoder = @fieldParentPtr("base", encoder_ptr);
    _ = rmt.rmt_del_encoder(self.bytes_encoder);
    _ = rmt.rmt_del_encoder(self.copy_encoder);
    c_stdlib.free(self);
    return esp_idf.sys.ESP_OK;
}

fn reset(encoder_ptr: *rmt.Encoder) callconv(.c) c_int {
    const self: *Encoder = @fieldParentPtr("base", encoder_ptr);
    _ = rmt.rmt_encoder_reset(self.bytes_encoder);
    _ = rmt.rmt_encoder_reset(self.copy_encoder);
    self.state = @intCast(rmt.ENCODING_RESET);
    return esp_idf.sys.ESP_OK;
}

/// Allocate and configure a WS2812 LED strip encoder. On success, writes the
/// encoder handle to `ret_encoder` and returns ESP_OK.
pub fn new(resolution_hz: u32, ret_encoder: *rmt.EncoderHandle) c_int {
    const mem = rmt.rmt_alloc_encoder_mem(@sizeOf(Encoder)) orelse return esp_idf.sys.ESP_ERR_NO_MEM;
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

    const bytes_config = rmt.BytesEncoderConfig{
        .bit0 = symbol(1, t0h, 0, t0l),
        .bit1 = symbol(1, t1h, 0, t1l),
        .flags = 1, // msb_first bit
    };

    var rc = rmt.rmt_new_bytes_encoder(&bytes_config, &self.bytes_encoder);
    if (rc != esp_idf.sys.ESP_OK) {
        c_stdlib.free(self);
        return rc;
    }

    const copy_config = rmt.CopyEncoderConfig{};
    rc = rmt.rmt_new_copy_encoder(&copy_config, &self.copy_encoder);
    if (rc != esp_idf.sys.ESP_OK) {
        _ = rmt.rmt_del_encoder(self.bytes_encoder);
        c_stdlib.free(self);
        return rc;
    }

    // 50us reset code split across two halves.
    const reset_ticks: u15 = @intCast(ticks_per_us * 50 / 2);
    self.reset_code = symbol(0, reset_ticks, 0, reset_ticks);

    ret_encoder.* = &self.base;
    return esp_idf.sys.ESP_OK;
}
