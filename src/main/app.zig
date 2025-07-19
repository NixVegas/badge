const std = @import("std");
const esp_idf = @import("esp-idf");
const log = std.log.scoped(.@"nixbadge");

pub const std_options = esp_idf.std_options;
pub const panic = esp_idf.panic;

pub export fn setup_gpios_config() callconv(.C) void {
    esp_idf.drivers.gpio.Config.config(&.{
        .intr_type = .posedge,
        .pin_bit_mask = 1 << 15,
        .mode = .input,
        .pull_down_en = .enable,
        .pull_up_en = .disable,
    }) catch |err| @panic(@errorName(err));

    esp_idf.drivers.gpio.Config.config(&.{
        .intr_type = .disable,
        .pin_bit_mask = 1 << 23,
        .mode = .output,
        .pull_down_en = .disable,
        .pull_up_en = .disable,
    }) catch |err| @panic(@errorName(err));

    // TODO: create queue
    esp_idf.drivers.gpio.installIsrService(0) catch |err| @panic(@errorName(err));
}

pub export fn zig_main() callconv(.C) void {
    log.info("Hello world\n", .{});
}
