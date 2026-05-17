const std = @import("std");
const math = std.math;
const esp_idf = @import("esp-idf");
const rmt = esp_idf.rmt;
const options = @import("options");
const mesh = @import("mesh.zig");
const strip_encoder = @import("led_strip_encoder.zig");
const log = std.log.scoped(.nixbadge_leds);

const num_leds = 12;
const angle_inc_led: f32 = 0.3;
const color_offset: f32 = math.pi * 2.0 / 3.0;

const rmt_resolution_hz: u32 = 10_000_000;
const rmt_gpio_num: c_int = 14;

pub const input_pin: c_int = switch (options.board_rev) {
    .@"0.5" => 15,
    .@"1.0" => 3,
};

pub const output_pin: c_int = switch (options.board_rev) {
    .@"0.5" => 23,
    .@"1.0" => 15,
};

pub var pixels: [num_leds * 3]u8 = @splat(0);

inline fn pixelFromFloat(v: f32) u8 {
    return @intFromFloat(math.clamp(v, 0.0, 255.0));
}

fn shade(led: usize, angle: f32) void {
    const mul: f32 = if (led == 4) 127 else 64;
    const off: f32 = if (led == 4) 128 else 0;
    pixels[led * 3 + 0] = pixelFromFloat(@sin(angle + color_offset * 0) * mul + off);
    pixels[led * 3 + 1] = pixelFromFloat(@sin(angle + color_offset * 1) * mul + off);
    pixels[led * 3 + 2] = pixelFromFloat(@sin(angle + color_offset * 2) * mul + off);
}

pub fn pulse(offset: f32) void {
    for (0..num_leds) |led| {
        const angle = offset + @as(f32, @floatFromInt(led)) * angle_inc_led;
        shade(led, angle);
    }
}

pub fn pull() void {
    for (0..num_leds) |led| {
        const offset = mesh.pingMeasure(@intCast(led));
        const angle = offset + @as(f32, @floatFromInt(led)) * angle_inc_led;
        shade(led, angle);
    }
}

var gpio_evt_queue: ?*esp_idf.freertos.Queue = null;

fn gpioIsrHandler(arg: ?*anyopaque) linksection(".iram1.nixbadge_gpio_isr") callconv(.c) void {
    const gpio_num: u32 = @truncate(@intFromPtr(arg));
    if (gpio_evt_queue) |q| {
        _ = esp_idf.freertos.queueSendFromISR(q, &gpio_num, null);
    }
}

fn gpioTask(_: ?*anyopaque) callconv(.c) void {
    var io_num: u32 = 0;
    var cnt: u32 = 0;
    while (true) {
        const queue = gpio_evt_queue orelse return;
        if (esp_idf.freertos.queueReceive(queue, &io_num, esp_idf.freertos.portMAX_DELAY)) {
            log.info("GPIO[{d}] intr, val: {d}", .{ io_num, esp_idf.drivers.gpio.getLevel(@intCast(io_num)) });
            esp_idf.drivers.gpio.setLevel(output_pin, cnt % 2) catch {};
            cnt +%= 1;
        }
    }
}

fn configGpios() !void {
    try esp_idf.drivers.gpio.Config.config(&.{
        .intr_type = .posedge,
        .pin_bit_mask = 1 << input_pin,
        .mode = .input,
        .pull_down_en = .enable,
        .pull_up_en = .disable,
    });

    try esp_idf.drivers.gpio.Config.config(&.{
        .intr_type = .disable,
        .pin_bit_mask = 1 << output_pin,
        .mode = .output,
        .pull_down_en = .disable,
        .pull_up_en = .disable,
    });

    try esp_idf.drivers.gpio.installIsrService(0);
}

pub fn setupGpios() !void {
    log.info("Setting up gpios...", .{});
    try configGpios();

    gpio_evt_queue = try esp_idf.freertos.queueCreate(10, @sizeOf(u32));
    try esp_idf.freertos.taskCreate(gpioTask, "gpio_task", 4096, null, 10, null);
    try esp_idf.drivers.gpio.isrHandlerAdd(input_pin, gpioIsrHandler, @ptrFromInt(@as(usize, @intCast(input_pin))));
}

var led_chan: rmt.ChannelHandle = null;
var led_encoder: rmt.EncoderHandle = null;

inline fn checkErr(rc: c_int) !void {
    if (rc != esp_idf.sys.ESP_OK) {
        log.err("esp_err 0x{x}", .{rc});
        return error.EspErr;
    }
}

pub fn setupRmt() !void {
    log.info("Create RMT TX channel", .{});
    const tx_chan_config = rmt.TxChannelConfig{
        .gpio_num = rmt_gpio_num,
        .clk_src = .default,
        .resolution_hz = rmt_resolution_hz,
        .mem_block_symbols = 64,
        .trans_queue_depth = 4,
        .intr_priority = 0,
        .flags = 0,
    };
    try checkErr(rmt.rmt_new_tx_channel(&tx_chan_config, &led_chan));

    log.info("Install led strip encoder", .{});
    try checkErr(strip_encoder.new(rmt_resolution_hz, &led_encoder));

    log.info("Enable RMT TX channel", .{});
    try checkErr(rmt.rmt_enable(led_chan));
}

pub fn init() !void {
    try setupGpios();
    try setupRmt();
}

pub fn sync() !void {
    const tx_config = rmt.TransmitConfig{};
    try checkErr(rmt.rmt_transmit(led_chan, led_encoder, &pixels, pixels.len, &tx_config));
    // rmt_tx_wait_all_done takes a c_int timeout in ms; -1 means wait forever.
    try checkErr(rmt.rmt_tx_wait_all_done(led_chan, -1));
}
