const std = @import("std");
const zbor = @import("zbor");

pub const packet_size = 18;

pub const Tag = enum(u8) {
    ping,
    req_ping,
};

pub const Packet = union(Tag) {
    ping: void,
    req_ping: void,

    pub fn init(tag: std.meta.Tag(Packet)) Packet {
        return switch (tag) {
            inline else => |t| @unionInit(Packet, @tagName(t), {}),
        };
    }

    /// Wire format: CBOR-encoded `Tag` value, zero-padded to `packet_size`.
    /// The variants currently carry no payload, so the tag is the whole packet.
    pub fn encode(self: Packet) ![packet_size]u8 {
        var buff: [packet_size]u8 = @splat(0);
        var writer = std.Io.Writer.fixed(&buff);
        zbor.stringify(std.meta.activeTag(self), .{}, &writer) catch return error.Encode;
        return buff;
    }

    pub fn decode(buff: []const u8) !Packet {
        const item = zbor.DataItem.new(buff) catch return error.Malformed;
        const tag = zbor.parse(Tag, item, .{}) catch return error.Decode;
        return init(tag);
    }
};
