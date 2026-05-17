//! RMT (Remote Control transceiver) bindings.
//! ESP-IDF's rmt_* structs have C bitfields (mostly in `flags`), so we mirror
//! the layouts directly with u32 placeholders for those fields.

pub const ChannelHandle = ?*anyopaque;
pub const EncoderHandle = ?*Encoder;

pub const EsClockSource = enum(c_uint) {
    pll_f80m = 4,
    xtal = 9,
    rc_fast = 8,
    pub const default: EsClockSource = .pll_f80m;
};

pub const EncodeState = c_uint;
pub const ENCODING_RESET: EncodeState = 0;
pub const ENCODING_COMPLETE: EncodeState = 1 << 0;
pub const ENCODING_MEM_FULL: EncodeState = 1 << 1;

/// `rmt_symbol_word_t`. We treat it as an opaque u32 since the bitfields are
/// constructed by hand (level0/duration0/level1/duration1 packing).
pub const Symbol = extern union {
    val: u32,
};

pub const EncodeFn = *const fn (
    encoder: *Encoder,
    channel: ChannelHandle,
    primary_data: ?*const anyopaque,
    data_size: usize,
    ret_state: *EncodeState,
) callconv(.c) usize;

pub const DelFn = *const fn (encoder: *Encoder) callconv(.c) c_int;
pub const ResetFn = *const fn (encoder: *Encoder) callconv(.c) c_int;

pub const Encoder = extern struct {
    encode: ?EncodeFn = null,
    reset: ?ResetFn = null,
    del: ?DelFn = null,
};

/// `rmt_tx_channel_config_t` (driver/rmt_tx.h). `flags` is a C bitfield word;
/// we expose it as a plain u32.
pub const TxChannelConfig = extern struct {
    gpio_num: c_int,
    clk_src: EsClockSource,
    resolution_hz: u32,
    mem_block_symbols: usize,
    trans_queue_depth: usize,
    intr_priority: c_int,
    flags: u32 = 0,
};

/// `rmt_transmit_config_t` (driver/rmt_tx.h).
pub const TransmitConfig = extern struct {
    loop_count: c_int = 0,
    flags: u32 = 0,
};

/// `rmt_bytes_encoder_config_t` (driver/rmt_encoder.h).
pub const BytesEncoderConfig = extern struct {
    bit0: Symbol,
    bit1: Symbol,
    flags: u32 = 0,
};

/// `rmt_copy_encoder_config_t` (driver/rmt_encoder.h) - currently empty.
pub const CopyEncoderConfig = extern struct {};

pub extern fn rmt_new_tx_channel(config: *const TxChannelConfig, ret_chan: *ChannelHandle) c_int;
pub extern fn rmt_new_bytes_encoder(config: *const BytesEncoderConfig, ret_encoder: *EncoderHandle) c_int;
pub extern fn rmt_new_copy_encoder(config: *const CopyEncoderConfig, ret_encoder: *EncoderHandle) c_int;
pub extern fn rmt_enable(chan: ChannelHandle) c_int;
pub extern fn rmt_transmit(
    chan: ChannelHandle,
    encoder: EncoderHandle,
    payload: *const anyopaque,
    payload_bytes: usize,
    config: *const TransmitConfig,
) c_int;
pub extern fn rmt_tx_wait_all_done(chan: ChannelHandle, timeout_ms: c_int) c_int;
pub extern fn rmt_alloc_encoder_mem(size: usize) ?*anyopaque;
pub extern fn rmt_del_encoder(encoder: EncoderHandle) c_int;
pub extern fn rmt_encoder_reset(encoder: EncoderHandle) c_int;
