const esp_idf = @import("esp-idf");
const options = @import("options");

pub fn configGpios() !void {
    try esp_idf.drivers.gpio.Config.config(&.{
        .intr_type = .posedge,
        .pin_bit_mask = 1 << @as(comptime_int, switch (options.board_rev) {
            .@"0.5" => 15,
            else => @panic("Not supported"),
        }),
        .mode = .input,
        .pull_down_en = .enable,
        .pull_up_en = .disable,
    });

    try esp_idf.drivers.gpio.Config.config(&.{
        .intr_type = .disable,
        .pin_bit_mask = 1 << @as(comptime_int, switch (options.board_rev) {
            .@"0.5" => 23,
            else => @panic("Not supported"),
        }),
        .mode = .output,
        .pull_down_en = .disable,
        .pull_up_en = .disable,
    });

    // TODO: create queue
    try esp_idf.drivers.gpio.installIsrService(0);
}
