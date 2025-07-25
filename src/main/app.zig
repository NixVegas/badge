const std = @import("std");
const esp_idf = @import("esp-idf");
const proto = @import("proto.zig");
const utils = @import("utils.zig");
const log = std.log.scoped(.@"nixbadge");

pub const std_options = esp_idf.std_options;
pub const panic = esp_idf.panic;

pub const Addr = extern union {
    addr: [6]u8,
    mip: Mip,

    pub const Mip = extern struct {
        addr: [4]u8,
        port: u16,
    };

    pub fn formatAddr(self: *const Addr, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return try writer.print("{x:02}:{x:02}:{x:02}:{x:02}:{x:02}:{x:02}", .{
            self.addr[0],
            self.addr[1],
            self.addr[2],
            self.addr[3],
            self.addr[4],
            self.addr[5],
        });
    }

    pub fn formatMip(self: *const Addr, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return try writer.print("{d}.{d}.{d}.{d}:{d}", .{
            self.mip.addr[0],
            self.mip.addr[1],
            self.mip.addr[2],
            self.mip.addr[3],
            self.mip.port,
        });
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

extern fn owo_send_packet(addr: ?*const Addr, kind: u8) esp_idf.sys.Error;

pub export fn write_mesh_packet(size_ptr: *u16, kind: u8) [*]const u8 {
    size_ptr.* = 0;

    const packet = proto.Packet.init(@enumFromInt(kind));
    const buff = packet.encode() catch |err| @panic(@errorName(err));
    log.info("Writing packet {} ({any})\n", .{packet, buff});
    size_ptr.* = buff.len;

    if (packet_queue_tx.len() + buff.len >= packet_queue_tx_buff.len) {
        packet_queue_tx.write_index = 0;
    }

    const data_start = packet_queue_tx.mask(packet_queue_tx.write_index);
    packet_queue_tx.writeSliceAssumeCapacity(&buff);
    const data_end = data_start + buff.len;
    return packet_queue_tx.data[data_start..data_end].ptr;
}

pub export fn prepare_read_mesh_packet(size_ptr: *u16) [*]const u8 {
    size_ptr.* = proto.packet_size;

    if (packet_queue_rx.len() + proto.packet_size >= packet_queue_rx_buff.len) {
        packet_queue_rx.write_index = 0;
    }

    const data_start = packet_queue_rx.mask(packet_queue_rx.write_index);
    const data_end = data_start + proto.packet_size;

    packet_queue_rx.write_index = data_end;
    return packet_queue_rx.data[data_start..data_end].ptr;
}

pub export fn read_mesh_packet(buff: [*]const u8, size: u16, addr: *const [6]u8, rssi: i8, delay_ptr: ?*i64) void {
    const from = Addr{ .addr = addr.* };
    const packet = proto.Packet.decode(buff[0..size]) catch |err| return log.err("Failed to decode {any} from {}: {}\n", .{
        buff[0..size],
        std.fmt.Formatter(Addr.formatAddr){ .data = &from },
        err,
    });

    log.info("Received {} {any} {}\n", .{
        packet,
        std.fmt.Formatter(Addr.formatAddr){ .data = &from },
        rssi,
    });

    switch (packet) {
        .req_ping => {
            owo_send_packet(&from, @intFromEnum(proto.Tag.ping)).throw() catch |err| log.err("Failed to send ping to {}: {}", .{
                std.fmt.Formatter(Addr.formatAddr){ .data = &from },
                err,
            });
        },
        .ping => |p| {
            const start = p.timestamp;
            const end = utils.getTimestamp();
            const delta = end - start;
            if (delay_ptr) |d| d.* = delta;
        },
    }
}

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
    //esp_idf.wifi.InitConfig.config(&.{
    //    .wpa_crypto_funcs = esp_idf.wifi.g_wifi_default_wpa_crypto_funcs,
    //}) catch |err| @panic(@errorName(err));
    log.info("Hello world\n", .{});
}
