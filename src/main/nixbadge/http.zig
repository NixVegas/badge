//! HTTP server + upstream cache proxy. Serves /nix-cache-info, /nar/*,
//! and treats /* as a narinfo lookup; forwards everything else to the
//! configured upstream cache (or to the parent node via mesh).

const std = @import("std");
const esp_idf = @import("esp-idf");
const options = @import("options");
const hc = esp_idf.http_client;
const hs = esp_idf.http_server;
const c_stdlib = esp_idf.stdlib;
const mesh = @import("mesh.zig");
const log = std.log.scoped(.nixbadge_http);

fn httpClientEvent(evt: *hc.Event) callconv(.c) c_int {
    const req: *hs.Req = @ptrCast(@alignCast(evt.user_data));
    const uri_ptr: [*:0]const u8 = @ptrCast(&req.uri);
    const uri = std.mem.sliceTo(uri_ptr, 0);
    switch (evt.event_id) {
        .ERROR => log.info("Received error while fetching {s}", .{uri}),
        .ON_CONNECTED => log.info("Connected to upstream cache at {s}", .{uri}),
        .ON_HEADER => {
            log.info("Received header for {s}", .{uri});
            if (evt.header_key) |k| {
                if (evt.header_value) |v| {
                    _ = hs.httpd_resp_set_hdr(req, k, v);
                }
            }
        },
        .ON_DATA => return hs.httpd_resp_send_chunk(req, @ptrCast(evt.data), evt.data_len),
        .ON_FINISH => {
            log.info("Connection to upstream cache at {s} is complete", .{uri});
            _ = hs.httpd_resp_sendstr_chunk(req, null);
        },
        .DISCONNECTED => {
            log.info("Got disconnected while fetching {s}", .{uri});
            var mbedtls_err: c_int = 0;
            const err = esp_idf.tls.esp_tls_get_and_clear_last_error(@alignCast(evt.data), &mbedtls_err, null);
            if (err != 0) {
                log.info("Last esp error code: 0x{x}", .{err});
                log.info("Last mbedtls failure: 0x{x}", .{mbedtls_err});
            }
        },
        else => {},
    }
    return esp_idf.sys.ESP_OK;
}

fn readNvsStringAlloc(handle: esp_idf.nvs.Handle, key: [*:0]const u8) ?[]u8 {
    const required = (esp_idf.nvs.getStrLen(handle, key) catch return null) orelse return null;
    const buf = c_stdlib.malloc(required) orelse return null;
    const bytes: [*]u8 = @ptrCast(buf);
    const slice = bytes[0..required];
    const len_with_nul = (esp_idf.nvs.getStr(handle, key, slice) catch {
        c_stdlib.free(buf);
        return null;
    }) orelse {
        c_stdlib.free(buf);
        return null;
    };
    // Length includes trailing NUL; return without it.
    return bytes[0..len_with_nul -| 1];
}

/// Returns a freshly-allocated NUL-terminated cache host string.
/// Caller must `c_stdlib.free` it.
fn getCacheHost() ?[*:0]u8 {
    const handle = esp_idf.nvs.open("config", .readonly) catch return null;
    defer esp_idf.nvs.close(handle);

    const cache_p2p = (esp_idf.nvs.getU8(handle, "cache_p2p") catch null) orelse 1;

    if (esp_idf.mesh_lite.esp_mesh_lite_get_level() == esp_idf.mesh_lite.ROOT or cache_p2p != 0) {
        const slice = readNvsStringAlloc(handle, "cache_upstream") orelse return null;
        return @ptrCast(slice.ptr);
    }

    const addr = mesh.getGateway();
    const bytes: *const [4]u8 = @ptrCast(&addr.addr);
    var ip_buf: [16]u8 = @splat(0);
    const written = std.fmt.bufPrintZ(&ip_buf, "{d}.{d}.{d}.{d}", .{
        bytes[0], bytes[1], bytes[2], bytes[3],
    }) catch return null;

    const out = c_stdlib.malloc(written.len + 1) orelse return null;
    const out_bytes: [*]u8 = @ptrCast(out);
    @memcpy(out_bytes[0..written.len], written);
    out_bytes[written.len] = 0;
    return @ptrCast(out);
}

fn nixCacheInfoHandler(req: *hs.Req) callconv(.c) c_int {
    const handle = esp_idf.nvs.open("config", .readonly) catch return esp_idf.sys.ESP_FAIL;
    defer esp_idf.nvs.close(handle);

    const cache_store = readNvsStringAlloc(handle, "cache_store") orelse return esp_idf.sys.ESP_FAIL;
    defer c_stdlib.free(cache_store.ptr);

    const cache_priority = (esp_idf.nvs.getU32(handle, "cache_priority") catch null) orelse 0;

    var buf: [256]u8 = @splat(0);
    const body = std.fmt.bufPrint(&buf, "StoreDir: {s}\nWantMassQuery: 1\nPriority: {d}\n", .{
        cache_store, cache_priority,
    }) catch return esp_idf.sys.ESP_FAIL;

    _ = hs.httpd_resp_set_hdr(req, "Content-Type", "text/x-nix-cache-info");
    return hs.httpd_resp_send(req, body.ptr, @intCast(body.len));
}

fn proxyHandler(req: *hs.Req, content_type: [*:0]const u8, buffer_size: c_int) c_int {
    const cache_host = getCacheHost() orelse return esp_idf.sys.ESP_FAIL;
    defer c_stdlib.free(cache_host);

    const handle = esp_idf.nvs.open("config", .readonly) catch return esp_idf.sys.ESP_FAIL;
    defer esp_idf.nvs.close(handle);

    const uri_ptr: [*:0]const u8 = @ptrCast(&req.uri);
    log.info("Querying {s} on level {d}", .{ std.mem.sliceTo(uri_ptr, 0), esp_idf.mesh_lite.esp_mesh_lite_get_level() });

    var cfg = hc.Config{
        .host = cache_host,
        .path = uri_ptr,
        .buffer_size = buffer_size,
        .is_async = false,
        .timeout_ms = 3_000_000,
        .event_handler = &httpClientEvent,
        .user_data = req,
    };

    const cache_use_https = (esp_idf.nvs.getU8(handle, "cache_use_https") catch null) orelse 0;
    var cert_buf: ?[*]u8 = null;
    defer if (cert_buf) |b| c_stdlib.free(b);

    if (cache_use_https != 0 and esp_idf.mesh_lite.esp_mesh_lite_get_level() == esp_idf.mesh_lite.ROOT) {
        cfg.transport_type = .over_ssl;
        if (esp_idf.nvs.getStrLen(handle, "cache_cert") catch null) |required| {
            const buf = c_stdlib.malloc(required + 1) orelse return esp_idf.sys.ESP_ERR_NO_MEM;
            const bytes: [*]u8 = @ptrCast(buf);
            _ = esp_idf.nvs.getStr(handle, "cache_cert", bytes[0 .. required + 1]) catch {
                c_stdlib.free(buf);
                return esp_idf.sys.ESP_FAIL;
            };
            bytes[required] = 0;
            cfg.cert_pem = @ptrCast(bytes);
            cfg.cert_len = required;
            cert_buf = bytes;
        } else {
            cfg.use_global_ca_store = true;
        }
    } else if (esp_idf.mesh_lite.esp_mesh_lite_get_level() != esp_idf.mesh_lite.ROOT) {
        cfg.port = 1008;
    }

    _ = hs.httpd_resp_set_hdr(req, "Content-Type", content_type);

    const client = hc.esp_http_client_init(&cfg) orelse return esp_idf.sys.ESP_FAIL;
    defer _ = hc.esp_http_client_cleanup(client);
    return hc.esp_http_client_perform(client);
}

fn narinfoHandler(req: *hs.Req) callconv(.c) c_int {
    return proxyHandler(req, "text/x-nix-narinfo", 16 * 1024);
}

fn narHandler(req: *hs.Req) callconv(.c) c_int {
    return proxyHandler(req, "application/x-nix-nar", 64 * 1024);
}

const Entry = struct {
    uri: [*:0]const u8,
    method: hs.Method,
    handler: hs.Handler,
};

const uri_table = [_]Entry{
    .{ .uri = "/nix-cache-info", .method = .GET, .handler = &nixCacheInfoHandler },
    .{ .uri = "/nar/*", .method = .GET, .handler = &narHandler },
    .{ .uri = "/*", .method = .GET, .handler = &narinfoHandler },
};

fn httpdStart(port: u16) c_int {
    var cfg = std.mem.zeroes(hs.Config);
    cfg.task_priority = hs.tskIDLE_PRIORITY + 5;
    cfg.stack_size = 4096;
    cfg.core_id = hs.tskNO_AFFINITY;
    cfg.task_caps = hs.MALLOC_CAP_INTERNAL | hs.MALLOC_CAP_8BIT;
    cfg.max_req_hdr_len = options.HTTPD_MAX_REQ_HDR_LEN;
    cfg.max_uri_len = options.HTTPD_MAX_URI_LEN;
    cfg.server_port = port;
    cfg.ctrl_port = hs.ESP_HTTPD_DEF_CTRL_PORT;
    cfg.max_open_sockets = 7;
    cfg.max_uri_handlers = 8;
    cfg.max_resp_headers = 8;
    cfg.backlog_conn = 5;
    cfg.recv_wait_timeout = 5;
    cfg.send_wait_timeout = 5;
    cfg.uri_match_fn = &hs.httpd_uri_match_wildcard;

    var server: hs.Handle = null;
    const err = hs.httpd_start(&server, &cfg);
    if (err != esp_idf.sys.ESP_OK) return err;

    for (uri_table) |entry| {
        var uri = std.mem.zeroes(hs.UriEntry);
        uri.uri = entry.uri;
        uri.method = entry.method;
        uri.handler = entry.handler;
        _ = hs.httpd_register_uri_handler(server, &uri);
    }
    return esp_idf.sys.ESP_OK;
}

pub fn init() void {
    _ = esp_idf.tls.esp_tls_init_global_ca_store();
    if (httpdStart(1008) != esp_idf.sys.ESP_OK) {
        @panic("httpd_start failed");
    }
}
