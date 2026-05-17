//! SD card readout + FATFS mount in SPI mode. The esp32c6 has no SDMMC host
//! peripheral, so we drive the badge's SD socket via SPI2:
//!
//!   CLK (19) → SCK   MOSI ← CMD (18)
//!   MISO ← D0 (20)   CS   → D3 (22)
//!   CD  ← IO8 (active low)
//!
//! D1/D2 stay floating; the board has external pull-ups on them so the card
//! enters SPI mode cleanly. On boot we initialize the bus and try
//! `esp_vfs_fat_sdspi_mount`; if it succeeds, `/sdcard/...` is accessible via
//! POSIX file I/O and the HTTP handlers can serve nar/narinfo files locally.

const std = @import("std");
const esp_idf = @import("esp-idf");
const sd = esp_idf.sdmmc;
const log = std.log.scoped(.nixbadge_sdcard);

const pin_sck: c_int = 19;
const pin_mosi: c_int = 18; // CMD
const pin_miso: c_int = 20; // D0
const pin_cs: c_int = 22; // D3
const pin_cd: c_int = 8;

/// Path where the FATFS volume gets mounted in the VFS layer.
pub const base_path: [*:0]const u8 = "/sdcard";

var mounted_card: ?*sd.Card = null;

pub inline fn isMounted() bool {
    return mounted_card != null;
}

/// Initialize the SPI bus and try to mount the SD card's FAT volume at
/// `/sdcard`. Logs the CID on success and leaves the volume mounted; on
/// failure (no card, init error, unformatted card) logs a warning and
/// returns. Subsequent reads through `/sdcard/...` will then fail with
/// ENOENT, which the HTTP handlers treat as "miss → fall through to proxy".
pub fn mount() void {
    const bus_config = sd.SpiBusConfig{
        .mosi_io_num = pin_mosi,
        .miso_io_num = pin_miso,
        .sclk_io_num = pin_sck,
        .quadwp_io_num = sd.GPIO_NUM_NC,
        .quadhd_io_num = sd.GPIO_NUM_NC,
        .data4_io_num = sd.GPIO_NUM_NC,
        .data5_io_num = sd.GPIO_NUM_NC,
        .data6_io_num = sd.GPIO_NUM_NC,
        .data7_io_num = sd.GPIO_NUM_NC,
        .data_io_default_level = false,
        .max_transfer_sz = 4000,
        .flags = 0,
        .isr_cpu_id = .auto,
        .intr_flags = 0,
    };
    var rc = sd.spi_bus_initialize(.spi2, &bus_config, .ch_auto);
    if (rc != esp_idf.sys.ESP_OK) {
        log.err("spi_bus_initialize failed: 0x{x}", .{rc});
        return;
    }

    const dev_config = sd.SdspiDeviceConfig{
        .host_id = .spi2,
        .gpio_cs = pin_cs,
        .gpio_cd = sd.GPIO_NUM_NC,
        .gpio_wp = sd.GPIO_NUM_NC,
        .gpio_int = sd.GPIO_NUM_NC,
        .gpio_wp_polarity = false,
        .duty_cycle_pos = 0,
    };
    _ = pin_cd;

    const host = sd.sdspiHostDefault();
    const mount_config = sd.FatMountConfig{
        .format_if_mount_failed = false,
        .max_files = 5,
        .allocation_unit_size = 0,
        .disk_status_check_enable = false,
        .use_one_fat = false,
    };

    var card_handle: ?*sd.Card = null;
    rc = sd.esp_vfs_fat_sdspi_mount(base_path, &host, &dev_config, &mount_config, &card_handle);
    if (rc == esp_idf.sys.ESP_ERR_NOT_FOUND) {
        log.info("CD reads high on first probe; waiting 200 ms and retrying...", .{});
        esp_idf.sys.vTaskDelay(200 / 10); // 10 ms per tick at FREERTOS_HZ=100
        rc = sd.esp_vfs_fat_sdspi_mount(base_path, &host, &dev_config, &mount_config, &card_handle);
    }
    if (rc == esp_idf.sys.ESP_ERR_NOT_FOUND) {
        log.info("No SD card detected (CD line is high); FATFS not mounted.", .{});
        return;
    }
    if (rc != esp_idf.sys.ESP_OK) {
        log.err("esp_vfs_fat_sdspi_mount failed: 0x{x} (card present but mount failed)", .{rc});
        return;
    }

    mounted_card = card_handle;
    if (card_handle) |c| {
        log.info(
            "SD card mounted at {s}; CID: mfg=0x{x:0>2} oem=0x{x:0>4} name='{s}' rev=0x{x:0>2} serial=0x{x:0>8} date=0x{x}",
            .{
                std.mem.span(base_path),
                @as(u32, @bitCast(c.cid.mfg_id)),
                @as(u32, @bitCast(c.cid.oem_id)),
                std.mem.sliceTo(&c.cid.name, 0),
                @as(u32, @bitCast(c.cid.revision)),
                @as(u32, @bitCast(c.cid.serial)),
                @as(u32, @bitCast(c.cid.date)),
            },
        );
    }

    dumpRoot();
}

/// Walks `/sdcard` and logs every entry. Useful as a boot-time sanity check
/// that `nix copy --to file:///mnt/...` actually wrote files to the volume
/// the badge sees.
fn dumpRoot() void {
    const dir = esp_idf.stdlib.opendir(base_path) orelse {
        log.err("opendir({s}) failed: errno {d}", .{ std.mem.span(base_path), esp_idf.stdlib.errno() });
        return;
    };
    defer _ = esp_idf.stdlib.closedir(dir);

    log.info("Contents of {s}:", .{std.mem.span(base_path)});
    var count: usize = 0;
    while (esp_idf.stdlib.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(&entry.d_name, 0);
        const kind: []const u8 = switch (entry.d_type) {
            esp_idf.stdlib.DT_REG => "file",
            esp_idf.stdlib.DT_DIR => "dir ",
            else => "?   ",
        };
        log.info("  {s} {s}", .{ kind, name });
        count += 1;
    }
    if (count == 0) log.info("  (empty)", .{});
}
