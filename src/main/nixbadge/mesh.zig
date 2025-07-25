const std = @import("std");
const esp_idf = @import("esp-idf");
const proto = @import("../proto.zig");
const utils = @import("../utils.zig");
const log = std.log.scoped(.@"nixbadge_mesh");

pub const Client = struct {
    rssi: i8,
    last_ping: i64 = 0,
    ping_delay: i64 = 0,

    pub fn qos(self: *const Client) f32 {
        if (self.ping_delay == 0.0) return 0.0;
        return @as(f32, @floatFromInt(self.rssi)) / @as(f32, @floatFromInt(self.ping_delay));
    }
};

const max_packets = 50;

var packet_queue_tx_buff = [_]u8{0} ** (max_packets * proto.packet_size);
var packet_queue_tx = std.RingBuffer{
    .data = &packet_queue_tx_buff,
    .write_index = 0,
    .read_index = 0,
};

var packet_queue_rx_buff = [_]u8{0} ** (max_packets * proto.packet_size);
var packet_queue_rx = std.RingBuffer{
    .data = &packet_queue_rx_buff,
    .write_index = 0,
    .read_index = 0,
};

var peer_map = std.AutoHashMap([6]u8, Client).init(std.heap.c_allocator);

extern fn nixbadge_mesh_send_packet(addr: ?*const esp_idf.wifi.Addr, kind: u8) esp_idf.sys.Error;

pub fn sendPacket(addr: ?*const esp_idf.wifi.Addr, tag: proto.Tag) !void {
    return nixbadge_mesh_send_packet(addr, @intFromEnum(tag)).throw();
}

pub fn createPacket(tag: proto.Tag) ![]const u8 {
    const packet = proto.Packet.init(tag);
    const buff = try packet.encode();

    if (packet_queue_tx.len() + buff.len >= packet_queue_tx_buff.len) {
        packet_queue_tx.write_index = 0;
    }

    const data_start = packet_queue_tx.mask(packet_queue_tx.write_index);
    packet_queue_tx.writeSliceAssumeCapacity(&buff);
    const data_end = data_start + buff.len;
    return packet_queue_tx.data[data_start..data_end];
}

pub fn allocRead() []const u8 {
    if (packet_queue_rx.len() + proto.packet_size >= packet_queue_rx_buff.len) {
        packet_queue_rx.write_index = 0;
    }

    const data_start = packet_queue_rx.mask(packet_queue_rx.write_index);
    const data_end = data_start + proto.packet_size;

    packet_queue_rx.write_index = data_end;
    return packet_queue_rx.data[data_start..data_end];
}

pub fn readPacket(buff: []const u8, from: esp_idf.wifi.Addr) !void {
    const packet = try proto.Packet.decode(buff);

    const peer_client = peer_map.getPtr(from.addr);

    log.info("Received {} {any} {?} {?}\n", .{
        packet,
        std.fmt.Formatter(esp_idf.wifi.Addr.formatAddr){ .data = &from },
        peer_client,
        if (peer_client) |c| c.qos() else null,
    });

    switch (packet) {
        .req_ping => try sendPacket(&from, .ping),
        .ping => |p| {
            const start = p.timestamp;
            const end = utils.getTimestamp();
            const delta = end - start;

            if (peer_client) |c| {
                c.last_ping = end;
                c.ping_delay = delta;
            }
        },
    }
}

pub fn clearPeers() void {
    peer_map.clearAndFree();
}

pub fn pushPeer(addr: esp_idf.wifi.Addr, rssi: i8) !void {
    try peer_map.put(addr.addr, .{ .rssi = rssi });
}
