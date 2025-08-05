const std = @import("std");
const esp_idf = @import("esp-idf");
const log = std.log.scoped(.nixbadge);

pub const std_options = esp_idf.std_options;
pub const panic = esp_idf.panic;

pub const mesh = @import("nixbadge/mesh.zig");
pub const leds = @import("nixbadge/leds.zig");

export fn nixbadge_mesh_create_packet(kind: u8, size_ptr: *u32) [*]const u8 {
    const buff = mesh.createPacket(@enumFromInt(kind)) catch |err| @panic(@errorName(err));
    size_ptr.* = @intCast(buff.len);
    return buff.ptr;
}

export fn nixbadge_mesh_action_cb(data: [*]const u8, len: u32, out_data: *[*]const u8, out_len: *u32, seq: u32) esp_idf.sys.Error {
    mesh.actionCallback(data[0..len], out_data, out_len, seq) catch |err| {
        log.err("Failed to read packet {any}: {}", .{
            data[0..len],
            err,
        });
        return .fail;
    };
    return .ok;
}

export fn nixbadge_leds_config_gpios() void {
    leds.configGpios() catch |err| @panic(@errorName(err));
}

export fn nixbadge_mesh_ping_measure(i: u8) f32 {
    return mesh.pingMeasure(i);
}
