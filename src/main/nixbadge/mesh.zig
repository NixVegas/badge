const std = @import("std");
const esp_idf = @import("esp-idf");
const proto = @import("../proto.zig");
const utils = @import("../utils.zig");
const RingBuffer = @import("./RingBuffer.zig");
const log = std.log.scoped(.nixbadge_mesh);

extern var last_ping_timestamp: i64;

const PingEntry = struct {
    seq: u32 = 0,
    timestamp: i64 = 0,

    pub fn isEmpty(self: *const PingEntry) bool {
        return self.seq == 0 and self.timestamp == 0;
    }
};

const max_packets = 50;

var packet_queue_tx_buff = [_]u8{0} ** (max_packets * proto.packet_size);
var packet_queue_tx = RingBuffer{
    .data = &packet_queue_tx_buff,
    .write_index = 0,
    .read_index = 0,
};

var ping_index: usize = 0;
var ping_map = [_]PingEntry{.{}} ** 12;

fn findFreePing() *PingEntry {
    const i = ping_index % ping_map.len;
    ping_index = i + 1;
    return &ping_map[i];
}

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

pub fn actionCallback(data: []const u8, out_data: *[*]const u8, out_len: *u32, seq: u32) !void {
    const packet = try proto.Packet.decode(data);

    switch (packet) {
        .req_ping => {
            last_ping_timestamp = utils.getTimestamp();
            const resp = try createPacket(.ping);
            out_data.* = resp.ptr;
            out_len.* = resp.len;
        },
        .ping => {
            const ping = findFreePing();
            ping.* = .{
                .seq = seq,
                .timestamp = utils.getTimestamp(),
            };
        },
    }
}

pub fn pingMeasure(i: u8) f32 {
    if (i > ping_map.len) return 0.0;

    const entry = &ping_map[i];
    return @as(f32, @floatFromInt(entry.seq)) / (@as(f32, @floatFromInt(@abs(entry.timestamp - last_ping_timestamp))) * 1000);
}
