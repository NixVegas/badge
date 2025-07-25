const std = @import("std");
const esp_idf = @import("esp-idf");
const log = std.log.scoped(.nixbadge);

pub const std_options = esp_idf.std_options;
pub const panic = esp_idf.panic;

pub const mesh = @import("nixbadge/mesh.zig");

export fn nixbadge_mesh_create_packet(kind: u8, size_ptr: *u16) [*]const u8 {
    const buff = mesh.createPacket(@enumFromInt(kind)) catch |err| @panic(@errorName(err));
    size_ptr.* = @intCast(buff.len);
    return buff.ptr;
}

export fn nixbadge_mesh_alloc_read(size_ptr: *u16) [*]const u8 {
    const buff = mesh.allocRead();
    size_ptr.* = @intCast(buff.len);
    return buff.ptr;
}

export fn nixbadge_mesh_read_packet(buff: [*]const u8, size: u16, from: esp_idf.wifi.Addr) void {
    mesh.readPacket(buff[0..size], from) catch |err| return log.err("Failed to read packet {any} from {}: {}", .{
        buff[0..size],
        std.fmt.Formatter(esp_idf.wifi.Addr.formatAddr){ .data = &from },
        err,
    });
}

export fn nixbadge_mesh_clear_peers() void {
    mesh.clearPeers();
}

export fn nixbadge_mesh_push_peer(addr: esp_idf.wifi.Addr, rssi: i8) void {
    mesh.pushPeer(addr, rssi) catch |err| @panic(@errorName(err));
}

export fn setup_gpios_config() callconv(.C) void {
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
