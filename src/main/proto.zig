const std = @import("std");
const esp_idf = @import("esp-idf");
const utils = @import("utils.zig");
const Allocator = std.mem.Allocator;
const der = std.crypto.asn1.der;

pub const packet_size = 18;

pub const Tag = enum(u8) {
    ping,
    req_ping,
};

pub const Packet = union(Tag) {
    ping: void,
    req_ping: void,

    pub fn init(tag: std.meta.Tag(Packet)) Packet {
        inline for (std.meta.fields(Packet)) |f| {
            const expected: Tag = std.meta.stringToEnum(Tag, f.name) orelse unreachable;
            if (tag == expected) {
                return @unionInit(Packet, f.name, switch (f.type) {
                    void => {},
                    inline else => f.type.init(),
                });
            }
        }
        unreachable;
    }

    pub fn decodeDer(decoder: *der.Decoder) !Packet {
        const tag: Tag = try decoder.any(Tag);

        inline for (std.meta.fields(Packet)) |f| {
            const expected: Tag = std.meta.stringToEnum(Tag, f.name) orelse unreachable;
            if (tag == expected) {
                return @unionInit(Packet, f.name, switch (f.type) {
                    void => {},
                    inline else => try decoder.any(f.type),
                });
            }
        }
        return error.Unexpected;
    }

    pub fn encodeDer(self: Packet, encoder: *der.Encoder) !void {
        switch (self) {
            .req_ping, .ping => {},
        }

        try encoder.any(std.meta.activeTag(self));
    }

    pub fn encode(self: Packet) ![packet_size]u8 {
        var tmpbuff = [_]u8{0} ** (packet_size * 2);
        var fba = std.heap.FixedBufferAllocator.init(&tmpbuff);

        var encoder = der.Encoder.init(fba.allocator());
        try encoder.buffer.ensureCapacity(packet_size);

        try encoder.any(self);

        var buff = [_]u8{0} ** packet_size;
        const i: usize = @min(buff.len, encoder.buffer.data.len);
        @memcpy(buff[0..i], encoder.buffer.data[0..i]);

        return buff;
    }

    pub fn decode(buff: []const u8) !Packet {
        var decoder = der.Decoder{ .bytes = buff };
        return try decoder.any(Packet);
    }
};
