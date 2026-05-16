//! HTTP server + upstream cache proxy. Serves /nix-cache-info, /nar/*,
//! and treats /* as a narinfo lookup; forwards everything else to the
//! configured upstream cache (or to the parent node via mesh).

const std = @import("std");
const esp_idf = @import("esp-idf");
const c = esp_idf.c;
const mesh = @import("mesh.zig");
const log = std.log.scoped(.nixbadge_http);

const HttpdUri = struct {
    uri: [*:0]const u8,
    method: c.httpd_method_t,
    handler: *const fn (req: [*c]c.httpd_req_t) callconv(.c) c.esp_err_t,
};

fn httpClientEvent(evt: [*c]c.esp_http_client_event_t) callconv(.c) c.esp_err_t {
    const ev = &evt[0];
    const req: [*c]c.httpd_req_t = @ptrCast(@alignCast(ev.user_data));
    const uri_ptr: [*:0]const u8 = @ptrCast(&req.*.uri);
    const uri = std.mem.sliceTo(uri_ptr, 0);
    switch (ev.event_id) {
        c.HTTP_EVENT_ERROR => log.info("Received error while fetching {s}", .{uri}),
        c.HTTP_EVENT_ON_CONNECTED => log.info("Connected to upstream cache at {s}", .{uri}),
        c.HTTP_EVENT_ON_HEADER => {
            log.info("Received header for {s}", .{uri});
            _ = c.httpd_resp_set_hdr(req, ev.header_key, ev.header_value);
        },
        c.HTTP_EVENT_ON_DATA => return c.httpd_resp_send_chunk(req, @ptrCast(ev.data), ev.data_len),
        c.HTTP_EVENT_ON_FINISH => {
            log.info("Connection to upstream cache at {s} is complete", .{uri});
            _ = c.httpd_resp_sendstr_chunk(req, null);
        },
        c.HTTP_EVENT_DISCONNECTED => {
            log.info("Got disconnected while fetching {s}", .{uri});
            var mbedtls_err: c_int = 0;
            const err = c.esp_tls_get_and_clear_last_error(@ptrCast(@alignCast(ev.data)), &mbedtls_err, null);
            if (err != 0) {
                log.info("Last esp error code: 0x{x}", .{err});
                log.info("Last mbedtls failure: 0x{x}", .{mbedtls_err});
            }
        },
        else => {},
    }
    return c.ESP_OK;
}

fn readNvsStringAlloc(handle: esp_idf.nvs.Handle, key: [*:0]const u8) ?[]u8 {
    const required = (esp_idf.nvs.getStrLen(handle, key) catch return null) orelse return null;
    const buf = c.malloc(required) orelse return null;
    const bytes: [*]u8 = @ptrCast(buf);
    const slice = bytes[0..required];
    const len_with_nul = (esp_idf.nvs.getStr(handle, key, slice) catch {
        c.free(buf);
        return null;
    }) orelse {
        c.free(buf);
        return null;
    };
    // Length includes trailing NUL; return without it.
    return bytes[0..len_with_nul -| 1];
}

/// Returns a freshly-allocated NUL-terminated cache host string.
/// Caller must `c.free` it.
fn getCacheHost() ?[*:0]u8 {
    const handle = esp_idf.nvs.open("config", .readonly) catch return null;
    defer esp_idf.nvs.close(handle);

    const cache_p2p = (esp_idf.nvs.getU8(handle, "cache_p2p") catch null) orelse 1;

    if (c.esp_mesh_lite_get_level() == c.ROOT or cache_p2p != 0) {
        const slice = readNvsStringAlloc(handle, "cache_upstream") orelse return null;
        // Underlying buffer still has the trailing NUL.
        return @ptrCast(slice.ptr);
    }

    const addr = mesh.getGateway();
    const bytes: *const [4]u8 = @ptrCast(&addr.addr);
    var ip_buf: [16]u8 = @splat(0);
    const written = std.fmt.bufPrintZ(&ip_buf, "{d}.{d}.{d}.{d}", .{
        bytes[0], bytes[1], bytes[2], bytes[3],
    }) catch return null;

    const out = c.malloc(written.len + 1) orelse return null;
    const out_bytes: [*]u8 = @ptrCast(out);
    @memcpy(out_bytes[0..written.len], written);
    out_bytes[written.len] = 0;
    return @ptrCast(out);
}

fn nixCacheInfoHandler(req: [*c]c.httpd_req_t) callconv(.c) c.esp_err_t {
    const handle = esp_idf.nvs.open("config", .readonly) catch return c.ESP_FAIL;
    defer esp_idf.nvs.close(handle);

    const cache_store = readNvsStringAlloc(handle, "cache_store") orelse return c.ESP_FAIL;
    defer c.free(cache_store.ptr);

    const cache_priority = (esp_idf.nvs.getU32(handle, "cache_priority") catch null) orelse 0;

    var buf: [256]u8 = @splat(0);
    const body = std.fmt.bufPrint(&buf, "StoreDir: {s}\nWantMassQuery: 1\nPriority: {d}\n", .{
        cache_store, cache_priority,
    }) catch return c.ESP_FAIL;

    _ = c.httpd_resp_set_hdr(req, "Content-Type", "text/x-nix-cache-info");
    return c.httpd_resp_send(req, body.ptr, @intCast(body.len));
}

fn proxyHandler(req: [*c]c.httpd_req_t, content_type: [*:0]const u8, buffer_size: c_int) c.esp_err_t {
    const cache_host = getCacheHost() orelse return c.ESP_FAIL;
    defer c.free(cache_host);

    const handle = esp_idf.nvs.open("config", .readonly) catch return c.ESP_FAIL;
    defer esp_idf.nvs.close(handle);

    const uri_ptr: [*:0]const u8 = @ptrCast(&req.*.uri);
    log.info("Querying {s} on level {d}", .{ std.mem.sliceTo(uri_ptr, 0), c.esp_mesh_lite_get_level() });

    var cfg = std.mem.zeroes(c.esp_http_client_config_t);
    cfg.host = cache_host;
    cfg.path = uri_ptr;
    cfg.buffer_size = buffer_size;
    cfg.is_async = false;
    cfg.timeout_ms = 3_000_000;
    cfg.event_handler = &httpClientEvent;
    cfg.user_data = req;

    const cache_use_https = (esp_idf.nvs.getU8(handle, "cache_use_https") catch null) orelse 0;
    var cert_buf: ?[*]u8 = null;
    defer if (cert_buf) |b| c.free(b);

    if (cache_use_https != 0 and c.esp_mesh_lite_get_level() == c.ROOT) {
        cfg.transport_type = c.HTTP_TRANSPORT_OVER_SSL;
        if (esp_idf.nvs.getStrLen(handle, "cache_cert") catch null) |required| {
            const buf = c.malloc(required + 1) orelse return c.ESP_ERR_NO_MEM;
            const bytes: [*]u8 = @ptrCast(buf);
            _ = esp_idf.nvs.getStr(handle, "cache_cert", bytes[0 .. required + 1]) catch {
                c.free(buf);
                return c.ESP_FAIL;
            };
            bytes[required] = 0;
            // cImport flattens the anonymous { cert_pem; cert_der; } union into
            // a sub-struct named `unnamed_0`. Access cert_pem through it.
            cfg.unnamed_0.cert_pem = @ptrCast(bytes);
            cfg.cert_len = required;
            cert_buf = bytes;
        } else {
            cfg.use_global_ca_store = true;
        }
    } else if (c.esp_mesh_lite_get_level() != c.ROOT) {
        cfg.port = 1008;
    }

    _ = c.httpd_resp_set_hdr(req, "Content-Type", content_type);

    const client = c.esp_http_client_init(&cfg) orelse return c.ESP_FAIL;
    defer _ = c.esp_http_client_cleanup(client);
    return c.esp_http_client_perform(client);
}

fn narinfoHandler(req: [*c]c.httpd_req_t) callconv(.c) c.esp_err_t {
    return proxyHandler(req, "text/x-nix-narinfo", 16 * 1024);
}

fn narHandler(req: [*c]c.httpd_req_t) callconv(.c) c.esp_err_t {
    return proxyHandler(req, "application/x-nix-nar", 64 * 1024);
}

const uri_table = [_]HttpdUri{
    .{ .uri = "/nix-cache-info", .method = c.HTTP_GET, .handler = &nixCacheInfoHandler },
    .{ .uri = "/nar/*", .method = c.HTTP_GET, .handler = &narHandler },
    .{ .uri = "/*", .method = c.HTTP_GET, .handler = &narinfoHandler },
};

fn httpdStart(port: u16) c.esp_err_t {
    var cfg = std.mem.zeroes(c.httpd_config_t);
    cfg.task_priority = c.tskIDLE_PRIORITY + 5;
    cfg.stack_size = 4096;
    cfg.core_id = c.tskNO_AFFINITY;
    cfg.task_caps = c.MALLOC_CAP_INTERNAL | c.MALLOC_CAP_8BIT;
    cfg.max_req_hdr_len = c.CONFIG_HTTPD_MAX_REQ_HDR_LEN;
    cfg.max_uri_len = c.CONFIG_HTTPD_MAX_URI_LEN;
    cfg.server_port = port;
    cfg.ctrl_port = c.ESP_HTTPD_DEF_CTRL_PORT;
    cfg.max_open_sockets = 7;
    cfg.max_uri_handlers = 8;
    cfg.max_resp_headers = 8;
    cfg.backlog_conn = 5;
    cfg.recv_wait_timeout = 5;
    cfg.send_wait_timeout = 5;
    cfg.uri_match_fn = &c.httpd_uri_match_wildcard;

    var server: c.httpd_handle_t = null;
    const err = c.httpd_start(&server, &cfg);
    if (err != c.ESP_OK) return err;

    for (uri_table) |entry| {
        var uri = std.mem.zeroes(c.httpd_uri_t);
        uri.uri = entry.uri;
        uri.method = entry.method;
        uri.handler = entry.handler;
        _ = c.httpd_register_uri_handler(server, &uri);
    }
    return c.ESP_OK;
}

pub fn init() void {
    _ = c.esp_tls_init_global_ca_store();
    if (httpdStart(1008) != c.ESP_OK) {
        @panic("httpd_start failed");
    }
}
