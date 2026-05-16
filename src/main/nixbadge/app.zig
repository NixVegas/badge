const std = @import("std");
const math = std.math;
const esp_idf = @import("esp-idf");
const c = esp_idf.c;
const utils = @import("../utils.zig");
const mesh = @import("mesh.zig");
const leds = @import("leds.zig");
const http = @import("http.zig");
const log = std.log.scoped(.nixbadge);

const frame_duration_ms: u32 = 20;
const angle_inc_frame: f32 = 0.02;

fn check(err: c.esp_err_t) void {
    if (err != c.ESP_OK) {
        log.err("esp_err {x}", .{err});
        c.esp_system_abort("esp_err nonzero");
    }
}

fn ipEventHandler(_: ?*anyopaque, _: c.esp_event_base_t, _: i32, event_data: ?*anyopaque) callconv(.c) void {
    const event: *const c.ip_event_got_ip_t = @ptrCast(@alignCast(event_data orelse return));
    const bytes: *const [4]u8 = @ptrCast(&event.ip_info.ip.addr);
    log.info("<IP_EVENT_STA_GOT_IP>IP:{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
}

pub export fn app_main() void {
    log.info("Hello world {d}", .{utils.getTimestamp()});

    esp_idf.nvs.flashInitOrErase() catch |err| @panic(@errorName(err));

    check(c.esp_netif_init());
    check(c.esp_event_loop_create_default());
    check(c.esp_event_handler_register(c.IP_EVENT, c.IP_EVENT_STA_GOT_IP, &ipEventHandler, null));

    const cfg = esp_idf.wifi.InitConfig{
        .wpa_crypto_funcs = esp_idf.wifi.g_wifi_default_wpa_crypto_funcs,
    };
    cfg.config() catch |err| @panic(@errorName(err));
    check(c.esp_wifi_set_mode(c.WIFI_MODE_APSTA));
    check(c.esp_wifi_set_storage(c.WIFI_STORAGE_FLASH));

    if (shouldEnableWireless()) {
        mesh.init();
        http.init();
    }

    log.info("Start LED rainbow chase", .{});
    leds.init() catch |err| @panic(@errorName(err));

    var offset: f32 = 0;
    var last_ping = utils.getTimestamp();
    log.info("Mesh is {s}", .{if (mesh.hasMesh()) "enabled" else "disabled"});

    while (true) {
        if (mesh.hasMesh()) {
            leds.pull();
            const now = utils.getTimestamp();
            const time_delta = now - last_ping;
            if (@mod(@divTrunc(time_delta, 1000), 5) == 0) {
                _ = mesh.broadcast(0);
                last_ping = utils.getTimestamp();
            }
        } else {
            leds.pulse(offset);
            offset += angle_inc_frame;
            if (offset > 2 * math.pi) {
                offset -= 2 * math.pi;
            }
        }

        leds.sync() catch |err| @panic(@errorName(err));
        c.vTaskDelay(msToTicks(frame_duration_ms));
    }
}

fn msToTicks(ms: u32) c.TickType_t {
    return @intCast(@divTrunc(ms * c.configTICK_RATE_HZ, 1000));
}

fn shouldEnableWireless() bool {
    if (readBootMeshFlag()) return true;
    return esp_idf.drivers.gpio.getLevel(leds.input_pin) != 0;
}

fn readBootMeshFlag() bool {
    const handle = esp_idf.nvs.open("config", .readonly) catch return false;
    defer esp_idf.nvs.close(handle);
    const value = esp_idf.nvs.getU8(handle, "boot_mesh") catch return false;
    return (value orelse 0) != 0;
}
