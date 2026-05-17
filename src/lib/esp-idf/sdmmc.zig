pub const GpioNum = c_int; // gpio_num_t (enum) is ABI-equivalent to c_int.
pub const GPIO_NUM_NC: GpioNum = -1;

pub const HOST_FLAG_1BIT: u32 = 1 << 0;
pub const HOST_FLAG_4BIT: u32 = 1 << 1;
pub const HOST_FLAG_8BIT: u32 = 1 << 2;
pub const HOST_FLAG_SPI: u32 = 1 << 3;
pub const HOST_FLAG_DDR: u32 = 1 << 4;
pub const HOST_FLAG_DEINIT_ARG: u32 = 1 << 5;

pub const FREQ_DEFAULT: c_int = 20000;
pub const FREQ_PROBING: c_int = 400;
pub const FREQ_HIGHSPEED: c_int = 40000;

pub const SpiHostDevice = enum(c_uint) {
    spi2 = 1, // SPI0/SPI1 are reserved for flash/PSRAM.
    spi3 = 2,
};

pub const SpiDmaChan = enum(c_int) {
    disabled = 0,
    ch_auto = 3,
};

pub const IntrCpuAffinity = enum(c_uint) {
    auto = 0,
    cpu0 = 1,
    cpu1 = 2,
};

pub const DriverStrength = enum(c_uint) { b = 0, a = 1, c = 2, d = 3 };
pub const CurrentLimit = enum(c_uint) { ma_200 = 0, ma_400 = 1, ma_600 = 2, ma_800 = 3 };
pub const DelayPhase = enum(c_uint) { phase_0 = 0, phase_1 = 1, phase_2 = 2, phase_3 = 3, auto = 4 };

pub const SpiBusConfig = extern struct {
    mosi_io_num: c_int,
    miso_io_num: c_int,
    sclk_io_num: c_int,
    quadwp_io_num: c_int,
    quadhd_io_num: c_int,
    data4_io_num: c_int,
    data5_io_num: c_int,
    data6_io_num: c_int,
    data7_io_num: c_int,
    data_io_default_level: bool,
    max_transfer_sz: c_int,
    flags: u32,
    isr_cpu_id: IntrCpuAffinity,
    intr_flags: c_int,
};

pub const SdspiDevHandle = c_int;

/// Mirrors `sdspi_device_config_t` from driver/sdspi_host.h.
pub const SdspiDeviceConfig = extern struct {
    host_id: SpiHostDevice,
    gpio_cs: GpioNum,
    gpio_cd: GpioNum,
    gpio_wp: GpioNum,
    gpio_int: GpioNum,
    gpio_wp_polarity: bool,
    duty_cycle_pos: u16,
};

/// Mirrors `sdmmc_host_t`. Function-pointer slots are populated by
/// `sdspiHostDefault()` to point at the SDSPI driver symbols.
pub const Host = extern struct {
    flags: u32,
    slot: c_int,
    max_freq_khz: c_int,
    io_voltage: f32,
    driver_strength: DriverStrength,
    current_limit: CurrentLimit,
    init: ?*const fn () callconv(.c) c_int,
    set_bus_width: ?*const fn (slot: c_int, width: usize) callconv(.c) c_int,
    get_bus_width: ?*const fn (slot: c_int) callconv(.c) usize,
    set_bus_ddr_mode: ?*const fn (slot: c_int, ddr_enable: bool) callconv(.c) c_int,
    set_card_clk: ?*const fn (slot: c_int, freq_khz: u32) callconv(.c) c_int,
    set_cclk_always_on: ?*const fn (slot: c_int, always_on: bool) callconv(.c) c_int,
    do_transaction: ?*const fn (slot: c_int, cmdinfo: *anyopaque) callconv(.c) c_int,
    deinit_p: ?*const fn (slot: c_int) callconv(.c) c_int,
    io_int_enable: ?*const fn (slot: c_int) callconv(.c) c_int,
    io_int_wait: ?*const fn (slot: c_int, timeout_ticks: u32) callconv(.c) c_int,
    command_timeout_ms: c_int,
    get_real_freq: ?*const fn (slot: c_int, real_freq: *c_int) callconv(.c) c_int,
    input_delay_phase: DelayPhase,
    set_input_delay: ?*const fn (slot: c_int, phase: DelayPhase) callconv(.c) c_int,
    dma_aligned_buffer: ?*anyopaque,
    pwr_ctrl_handle: ?*anyopaque,
    get_dma_info: ?*const fn (slot: c_int, dma_mem_info: *anyopaque) callconv(.c) c_int,
    check_buffer_alignment: ?*const fn (slot: c_int, buf: ?*const anyopaque, size: usize) callconv(.c) bool,
    is_slot_set_to_uhs1: ?*const fn (slot: c_int, is_uhs1: *bool) callconv(.c) c_int,
};

pub const Cid = extern struct {
    mfg_id: c_int,
    oem_id: c_int,
    name: [8]u8,
    revision: c_int,
    serial: c_int,
    date: c_int,
};

/// Mirrors `sdmmc_card_t`. We only read fields back, so a generous tail
/// reservation covers the rest of the struct without enumerating it.
pub const Card = extern struct {
    host: Host,
    ocr: u32,
    cid: Cid,
    _tail: [128]u8 align(4) = @splat(0),
};

// SPI master bus
pub extern fn spi_bus_initialize(host_id: SpiHostDevice, bus_config: *const SpiBusConfig, dma_chan: SpiDmaChan) c_int;
pub extern fn spi_bus_free(host_id: SpiHostDevice) c_int;

// SDSPI host
pub extern fn sdspi_host_init() c_int;
pub extern fn sdspi_host_deinit() c_int;
pub extern fn sdspi_host_init_device(dev_config: *const SdspiDeviceConfig, out_handle: *SdspiDevHandle) c_int;
pub extern fn sdspi_host_remove_device(handle: SdspiDevHandle) c_int;
pub extern fn sdspi_host_set_card_clk(handle: SdspiDevHandle, freq_khz: u32) c_int;
pub extern fn sdspi_host_do_transaction(handle: SdspiDevHandle, cmdinfo: *anyopaque) c_int;
pub extern fn sdspi_host_io_int_enable(handle: SdspiDevHandle) c_int;
pub extern fn sdspi_host_io_int_wait(handle: SdspiDevHandle, timeout_ticks: u32) c_int;
pub extern fn sdspi_host_get_real_freq(handle: SdspiDevHandle, real_freq: *c_int) c_int;
pub extern fn sdspi_host_check_buffer_alignment(handle: SdspiDevHandle, buf: ?*const anyopaque, size: usize) bool;

// Card-init protocol layer
pub extern fn sdmmc_card_init(host: *const Host, card: *Card) c_int;

/// `esp_vfs_fat_mount_config_t` from esp_vfs_fat.h.
pub const FatMountConfig = extern struct {
    format_if_mount_failed: bool = false,
    max_files: c_int = 5,
    allocation_unit_size: usize = 0,
    disk_status_check_enable: bool = false,
    use_one_fat: bool = false,
};

/// All-in-one mount: initializes the SDSPI device on an already-`spi_bus_initialize`'d
/// bus, probes the card, and registers a FATFS volume at `base_path`. On success
/// `out_card` is populated with the heap-allocated card-handle pointer.
pub extern fn esp_vfs_fat_sdspi_mount(
    base_path: [*:0]const u8,
    host_config: *const Host,
    slot_config: *const SdspiDeviceConfig,
    mount_config: *const FatMountConfig,
    out_card: *?*Card,
) c_int;

pub extern fn esp_vfs_fat_sdcard_unmount(base_path: [*:0]const u8, card: ?*Card) c_int;

/// Builds a `Host` matching `SDSPI_HOST_DEFAULT()`. `host.slot` is set to the
/// caller's SDSPI device handle after `sdspi_host_init_device`.
pub fn sdspiHostDefault() Host {
    return .{
        .flags = HOST_FLAG_SPI | HOST_FLAG_DEINIT_ARG,
        .slot = @intFromEnum(SpiHostDevice.spi2),
        .max_freq_khz = FREQ_DEFAULT,
        .io_voltage = 3.3,
        .driver_strength = .b,
        .current_limit = .ma_200,
        .init = &sdspi_host_init,
        .set_bus_width = null,
        .get_bus_width = null,
        .set_bus_ddr_mode = null,
        .set_card_clk = &sdspi_host_set_card_clk,
        .set_cclk_always_on = null,
        .do_transaction = &sdspi_host_do_transaction,
        .deinit_p = &sdspi_host_remove_device,
        .io_int_enable = &sdspi_host_io_int_enable,
        .io_int_wait = &sdspi_host_io_int_wait,
        .command_timeout_ms = 0,
        .get_real_freq = &sdspi_host_get_real_freq,
        .input_delay_phase = .phase_0,
        .set_input_delay = null,
        .dma_aligned_buffer = null,
        .pwr_ctrl_handle = null,
        .get_dma_info = null,
        .check_buffer_alignment = &sdspi_host_check_buffer_alignment,
        .is_slot_set_to_uhs1 = null,
    };
}
