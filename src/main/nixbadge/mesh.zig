const std = @import("std");
const esp_idf = @import("esp-idf");
const options = @import("options");
const ml = esp_idf.mesh_lite;
const c_stdlib = esp_idf.stdlib;
const proto = @import("../proto.zig");
const utils = @import("../utils.zig");
const RingBuffer = @import("./RingBuffer.zig");
const log = std.log.scoped(.nixbadge_mesh);

const message_id: u32 = 10;
const resp_message_id: u32 = 11;

pub var last_ping_timestamp: i64 = 0;
var is_meshing: bool = false;
var netif_sta: ?*esp_idf.netif.Netif = null;

pub inline fn hasMesh() bool {
    return is_meshing;
}

pub inline fn setActive() void {
    is_meshing = true;
}

const PingEntry = struct {
    seq: u32 = 0,
    timestamp: i64 = 0,

    pub inline fn isEmpty(self: *const PingEntry) bool {
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

pub inline fn pingMeasure(i: u8) f32 {
    if (i >= ping_map.len) return 0.0;

    const entry = &ping_map[i];
    if (entry.isEmpty()) return 0.0;
    const dt = @abs(entry.timestamp - last_ping_timestamp);
    if (dt == 0) return 0.0;
    return @as(f32, @floatFromInt(entry.seq)) / (@as(f32, @floatFromInt(dt)) * 1000);
}

fn rawProcess(data: [*]u8, len: u32, out_data: *[*]u8, out_len: *u32, seq: u32) callconv(.c) c_int {
    var out_ptr: [*]const u8 = undefined;
    var out_l: u32 = 0;
    actionCallback(data[0..len], &out_ptr, &out_l, seq) catch |err| {
        log.err("Failed to read packet {any}: {}", .{ data[0..len], err });
        return esp_idf.sys.ESP_FAIL;
    };
    out_data.* = @constCast(out_ptr);
    out_len.* = out_l;
    return esp_idf.sys.ESP_OK;
}

const raw_msg_action: ml.RawMsgAction = .{
    .msg_id = message_id,
    .resp_msg_id = resp_message_id,
    .raw_process = &rawProcess,
};

pub fn broadcast(kind: u8) c_int {
    if (kind == 0) {
        last_ping_timestamp = utils.getTimestamp();
    }

    const data = createPacket(@enumFromInt(kind)) catch return esp_idf.sys.ESP_FAIL;

    var child_config = std.mem.zeroes(ml.MsgConfig);
    child_config.raw_msg.msg_id = message_id;
    child_config.raw_msg.expect_resp_msg_id = resp_message_id;
    child_config.raw_msg.max_retry = 3;
    child_config.raw_msg.data = data.ptr;
    child_config.raw_msg.size = @intCast(data.len);
    child_config.raw_msg.raw_resend = &ml.esp_mesh_lite_send_broadcast_raw_msg_to_child;
    _ = ml.esp_mesh_lite_send_msg(ml.ESP_MESH_LITE_RAW_MSG, &child_config);

    if (ml.esp_mesh_lite_get_level() != ml.ROOT) {
        var parent_config = std.mem.zeroes(ml.MsgConfig);
        parent_config.raw_msg.msg_id = message_id;
        parent_config.raw_msg.expect_resp_msg_id = resp_message_id;
        parent_config.raw_msg.max_retry = 3;
        parent_config.raw_msg.data = data.ptr;
        parent_config.raw_msg.size = @intCast(data.len);
        parent_config.raw_msg.raw_resend = &ml.esp_mesh_lite_send_broadcast_raw_msg_to_parent;
        _ = ml.esp_mesh_lite_send_msg(ml.ESP_MESH_LITE_RAW_MSG, &parent_config);
    }

    return esp_idf.sys.ESP_OK;
}

pub fn getGateway() esp_idf.netif.Ip4Addr {
    var ip_info = std.mem.zeroes(esp_idf.netif.IpInfo);
    _ = esp_idf.netif.esp_netif_get_ip_info(netif_sta, &ip_info);
    return ip_info.gw;
}

fn readNvsString(handle: esp_idf.nvs.Handle, key: [*:0]const u8, max_len: usize) ![]u8 {
    const buf = c_stdlib.malloc(max_len) orelse return error.OutOfMemory;
    const bytes: [*]u8 = @ptrCast(buf);
    const slice = bytes[0..max_len];
    const len_with_nul = (esp_idf.nvs.getStr(handle, key, slice) catch |err| {
        c_stdlib.free(buf);
        return err;
    }) orelse {
        c_stdlib.free(buf);
        return error.NotFound;
    };
    // getStr returns length including trailing NUL.
    return bytes[0..len_with_nul -| 1];
}

fn setSoftApInfo() void {
    var softap_ssid: [33]u8 = @splat(0);
    var softap_psw: [64]u8 = @splat(0);
    var ssid_size: usize = softap_ssid.len;
    var psw_size: usize = softap_psw.len;

    if (ml.esp_mesh_lite_get_softap_ssid_from_nvs(&softap_ssid, &ssid_size) != esp_idf.sys.ESP_OK) {
        var softap_mac: [6]u8 = @splat(0);
        _ = esp_idf.wifi.esp_wifi_get_mac(.ap, &softap_mac);
        // Match iot_bridge's lowercase `%02x` so the log line agrees with the
        // SSID actually advertised by `esp_bridge_wifi_set_config`.
        const written = std.fmt.bufPrintZ(
            &softap_ssid,
            "{s}_{x:0>2}{x:0>2}{x:0>2}",
            .{ options.BRIDGE_SOFTAP_SSID, softap_mac[3], softap_mac[4], softap_mac[5] },
        ) catch unreachable;
        _ = written;
    }

    if (ml.esp_mesh_lite_get_softap_psw_from_nvs(&softap_psw, &psw_size) != esp_idf.sys.ESP_OK) {
        const pw_slice = options.BRIDGE_SOFTAP_PASSWORD;
        const copy_len = @min(pw_slice.len, softap_psw.len - 1);
        @memcpy(softap_psw[0..copy_len], pw_slice[0..copy_len]);
        softap_psw[copy_len] = 0;
    }

    log.info("Serving SoftAP as {s}", .{std.mem.sliceTo(&softap_ssid, 0)});
}

extern fn esp_bridge_create_softap_netif(
    ip_info: ?*anyopaque,
    mac: ?*anyopaque,
    data_forward: bool,
    enable_dhcps: bool,
) ?*esp_idf.netif.Netif;
extern fn esp_bridge_create_station_netif(
    ip_info: ?*anyopaque,
    mac: ?*anyopaque,
    data_forward: bool,
    enable_dhcps: bool,
) ?*esp_idf.netif.Netif;

pub const InitOptions = struct {
    cache_only: bool = false,
};

pub fn init(opts: InitOptions) void {
    _ = esp_bridge_create_softap_netif(null, null, true, true);
    esp_idf.wifi.setApConfig(options.BRIDGE_SOFTAP_SSID, options.BRIDGE_SOFTAP_PASSWORD) catch |err| @panic(@errorName(err));

    if (opts.cache_only) {
        log.info("Cache-only mode: skipping STA + mesh-lite", .{});
        is_meshing = false;
        return;
    }

    is_meshing = true;
    netif_sta = esp_bridge_create_station_netif(null, null, false, false);

    const handle = esp_idf.nvs.open("config", .readonly) catch |err| @panic(@errorName(err));
    defer esp_idf.nvs.close(handle);

    const router_ssid = readNvsString(handle, "router_ssid", 32) catch |err| @panic(@errorName(err));
    defer c_stdlib.free(router_ssid.ptr);

    const router_passwd = readNvsString(handle, "router_passwd", 64) catch |err| @panic(@errorName(err));
    defer c_stdlib.free(router_passwd.ptr);

    esp_idf.wifi.setStaConfig(router_ssid, router_passwd) catch |err| @panic(@errorName(err));

    var mesh_lite_config = std.mem.zeroes(ml.Config);
    mesh_lite_config.vendor_id[0] = @intCast(options.MESH_LITE_VENDOR_ID_0 & 0xff);
    mesh_lite_config.vendor_id[1] = @intCast(options.MESH_LITE_VENDOR_ID_1 & 0xff);
    mesh_lite_config.mesh_id = @intCast(options.MESH_LITE_ID & 0xff);
    mesh_lite_config.max_connect_number = @intCast(options.BRIDGE_SOFTAP_MAX_CONNECT_NUMBER);
    mesh_lite_config.max_router_number = @intCast(options.MESH_LITE_MAX_ROUTER_NUMBER);
    mesh_lite_config.max_level = @intCast(options.MESH_LITE_MAXIMUM_LEVEL_ALLOWED);
    mesh_lite_config.max_node_number = @intCast(options.MESH_LITE_MAXIMUM_NODE_NUMBER);
    mesh_lite_config.join_mesh_ignore_router_status = options.JOIN_MESH_IGNORE_ROUTER_STATUS != 0;
    mesh_lite_config.join_mesh_without_configured_wifi = options.JOIN_MESH_WITHOUT_CONFIGURED_WIFI_INFO != 0;
    mesh_lite_config.leaf_node = options.LEAF_NODE != 0;
    mesh_lite_config.ota_data_len = options.OTA_DATA_LEN;
    mesh_lite_config.ota_wnd = options.OTA_WND_DEFAULT;
    mesh_lite_config.softap_ssid = options.BRIDGE_SOFTAP_SSID;
    mesh_lite_config.softap_password = options.BRIDGE_SOFTAP_PASSWORD;
    mesh_lite_config.device_category = options.DEVICE_CATEGORY;
    _ = ml.esp_mesh_lite_init(&mesh_lite_config);

    setSoftApInfo();

    if (ml.esp_mesh_lite_raw_msg_action_list_register(&raw_msg_action) != esp_idf.sys.ESP_OK) {
        @panic("esp_mesh_lite_raw_msg_action_list_register failed");
    }

    _ = ml.esp_mesh_lite_start();
}
