const std = @import("std");
const esp_idf = @import("esp-idf");
const proto = @import("../proto.zig");
const utils = @import("../utils.zig");
const log = std.log.scoped(.nixbadge_mesh);

extern var last_ping_timestamp: i64;

pub const Client = struct {
    last_ping_timestamp: i64 = 0,
    ping_delay: i64 = 0,
};

const max_packets = 50;

var packet_queue_tx_buff = [_]u8{0} ** (max_packets * proto.packet_size);
var packet_queue_tx = std.RingBuffer{
    .data = &packet_queue_tx_buff,
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

    log.info("Sending {} {any}\n", .{packet, buff});

    if (packet_queue_tx.len() + buff.len >= packet_queue_tx_buff.len) {
        packet_queue_tx.write_index = 0;
    }

    const data_start = packet_queue_tx.mask(packet_queue_tx.write_index);
    packet_queue_tx.writeSliceAssumeCapacity(&buff);
    const data_end = data_start + buff.len;
    return packet_queue_tx.data[data_start..data_end];
}

pub fn actionCallback(data: []const u8, out_data: *[*]const u8, out_len: *u32, seq: u32) !void {
    _ = seq;

    const packet = try proto.Packet.decode(data);

    log.info("Received {}\n", .{
        packet,
    });

    switch (packet) {
        .req_ping => {
            const resp = try createPacket(.ping);
            out_data.* = resp.ptr;
            out_len.* = resp.len;
        },
        .ping => {
        },
    }
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
        .ping => {
            const now = utils.getTimestamp();
            const delta = now - peer_client.last_ping_timestamp;
            if (delta > 0) {
                peer_client.last_ping_timestamp = now;
                peer_client.ping_delay = delta;
            }
        },
    }
}

pub fn removePeer(addr: esp_idf.wifi.Addr) void {
    _ = peer_map.remove(addr.addr);
}

pub fn avgPing() f32 {
    const ping_delta = utils.getTimestamp() - last_ping_timestamp;
    var value: f32 = 0;
    var count: f32 = 0;
    var iter = peer_map.valueIterator();
    while (iter.next()) |client| {
        if (client.last_ping_timestamp - ping_delta <= last_ping_timestamp) {
            value += @floatFromInt(client.ping_delay);
            count += 1;
        }
    }
    return if (value != 0) count / @log10(value) else 0;
}
