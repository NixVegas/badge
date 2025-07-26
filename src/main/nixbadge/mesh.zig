const std = @import("std");
const esp_idf = @import("esp-idf");
const proto = @import("../proto.zig");
const utils = @import("../utils.zig");
const log = std.log.scoped(.nixbadge_mesh);

pub const Client = struct {
    last_ping: i64 = 0,
    ping_delay: i64 = 0,
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

    const peer_client = blk: {
        const r = try peer_map.getOrPut(from.addr);
        if (!r.found_existing) r.value_ptr.* = .{};
        break :blk r.value_ptr;
    };

    log.info("Received {} {any} {}\n", .{
        packet,
        std.fmt.Formatter(esp_idf.wifi.Addr.formatAddr){ .data = &from },
        peer_client,
    });

    switch (packet) {
        .req_ping => try sendPacket(&from, .ping),
        .ping => |p| {
            const start = p.timestamp;
            const end = utils.getTimestamp();
            const delta = end - start;

            peer_client.last_ping = end;
            peer_client.ping_delay = delta;
        },
    }
}

pub fn removePeer(addr: esp_idf.wifi.Addr) void {
    _ = peer_map.remove(addr.addr);
}

pub fn avgPing() f32 {
    var value: f32 = 0;
    var count: usize = 0;
    var iter = peer_map.valueIterator();
    while (iter.next()) |client| {
        value += @floatFromInt(client.ping_delay);
        count += 1;
    }
    if (count == 0) return 0;
    return value / @as(f32, @floatFromInt(count));
}
