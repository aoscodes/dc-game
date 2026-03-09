//! Native (non-WASM) WebSocket transport for desktop development/testing.
//!
//! This is a minimal WebSocket client implementation using std.net.  It
//! performs the HTTP upgrade handshake and then reads/writes frames in a
//! background thread.
//!
//! The public API mirrors ws_browser.zig so client/main.zig can select
//! between the two at comptime.

const std = @import("std");
const shared = @import("shared");

// ---------------------------------------------------------------------------
// Callbacks (same shape as ws_browser.zig)
// ---------------------------------------------------------------------------

pub const Callbacks = struct {
    on_open: *const fn (handle: i32) void,
    on_message: *const fn (handle: i32, data: []const u8) void,
    on_close: *const fn (handle: i32) void,
};

var g_callbacks: Callbacks = .{
    .on_open = default_cb_open,
    .on_message = default_cb_message,
    .on_close = default_cb_close,
};

pub fn set_callbacks(cb: Callbacks) void {
    g_callbacks = cb;
}

fn default_cb_open(_: i32) void {}
fn default_cb_message(_: i32, _: []const u8) void {}
fn default_cb_close(_: i32) void {}

// ---------------------------------------------------------------------------
// WsBrowserTransport (same name as in ws_browser.zig for comptime swap)
// ---------------------------------------------------------------------------

pub const WsBrowserTransport = struct {
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
    handle: i32,
    thread: std.Thread,
    alive: std.atomic.Value(bool),

    pub fn connect(url: []const u8) error{ConnectionFailed}!WsBrowserTransport {
        const addr = parse_ws_url(url) catch return error.ConnectionFailed;
        const stream = std.net.tcpConnectToHost(
            std.heap.page_allocator,
            addr.host,
            addr.port,
        ) catch return error.ConnectionFailed;

        // HTTP WebSocket upgrade handshake
        ws_handshake(stream, addr.host, addr.path) catch {
            stream.close();
            return error.ConnectionFailed;
        };

        var self = WsBrowserTransport{
            .stream = stream,
            .allocator = std.heap.page_allocator,
            .handle = 0,
            .thread = undefined,
            .alive = std.atomic.Value(bool).init(true),
        };

        self.thread = std.Thread.spawn(.{}, read_loop, .{&self}) catch {
            stream.close();
            return error.ConnectionFailed;
        };

        // NOTE: on_ws_open is NOT called here.
        // The caller must call notify_open() after assigning the transport
        // to g_state, so that send_join() can find a non-null transport.
        return self;
    }

    /// Fire the on_open callback.  Call this after the transport has been
    /// stored in g_state (i.e. after `g_state.transport = ws_transport.transport()`).
    pub fn notify_open(self: *WsBrowserTransport) void {
        g_callbacks.on_open(self.handle);
    }

    pub fn close(self: *WsBrowserTransport) void {
        self.alive.store(false, .monotonic);
        self.stream.close();
        self.thread.join();
    }

    pub fn transport(self: *WsBrowserTransport) shared.Transport {
        return .{ .send_fn = native_send, .ctx = self };
    }

    fn native_send(ctx: *anyopaque, msg: []const u8) anyerror!void {
        const self: *WsBrowserTransport = @ptrCast(@alignCast(ctx));
        try write_frame(self.stream, msg);
    }
};

// ---------------------------------------------------------------------------
// Background read loop
// ---------------------------------------------------------------------------

fn read_loop(self: *WsBrowserTransport) void {
    var buf: [8192]u8 = undefined;
    while (self.alive.load(.monotonic)) {
        const frame = read_frame(self.stream, &buf) catch break;
        if (frame.opcode == 8) break; // close frame
        if (frame.opcode == 2 or frame.opcode == 1) { // binary or text
            g_callbacks.on_message(self.handle, frame.payload);
        }
    }
    self.alive.store(false, .monotonic);
    g_callbacks.on_close(self.handle);
}

// ---------------------------------------------------------------------------
// Minimal WS framing
// ---------------------------------------------------------------------------

const Frame = struct {
    opcode: u8,
    payload: []u8,
};

/// Read one WebSocket frame from `stream` into `buf`.
/// Only handles unmasked frames (server→client).
fn read_frame(stream: std.net.Stream, buf: []u8) !Frame {
    var header: [2]u8 = undefined;
    _ = try stream.read(&header);
    const opcode: u8 = header[0] & 0x0F;
    const mask_bit = (header[1] & 0x80) != 0;
    var payload_len: u64 = header[1] & 0x7F;

    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        _ = try stream.read(&ext);
        payload_len = @as(u64, ext[0]) << 8 | ext[1];
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        _ = try stream.read(&ext);
        payload_len = std.mem.readInt(u64, &ext, .big);
    }

    if (mask_bit) {
        // Server-to-client frames should not be masked per RFC 6455,
        // but we drain the 4-byte mask key if present.
        var mask_scratch: [4]u8 = undefined;
        _ = try stream.read(&mask_scratch);
    }

    if (payload_len > buf.len) return error.FrameTooLarge;
    const slice = buf[0..@intCast(payload_len)];
    var total: usize = 0;
    while (total < slice.len) {
        total += try stream.read(slice[total..]);
    }
    return .{ .opcode = opcode, .payload = slice };
}

/// Write one masked binary WebSocket frame to `stream`.
fn write_frame(stream: std.net.Stream, payload: []const u8) !void {
    var header_buf: [10 + 4]u8 = undefined;
    var pos: usize = 0;

    header_buf[pos] = 0x82;
    pos += 1; // FIN + opcode=binary

    const len = payload.len;
    const mask_key = [4]u8{ 0xDE, 0xAD, 0xBE, 0xEF }; // static mask for dev

    if (len <= 125) {
        header_buf[pos] = @as(u8, @intCast(len)) | 0x80;
        pos += 1;
    } else if (len <= 65535) {
        header_buf[pos] = 126 | 0x80;
        pos += 1;
        header_buf[pos] = @intCast(len >> 8);
        pos += 1;
        header_buf[pos] = @intCast(len & 0xFF);
        pos += 1;
    } else {
        header_buf[pos] = 127 | 0x80;
        pos += 1;
        var i: u3 = 7;
        while (true) : (i -= 1) {
            header_buf[pos] = @intCast((len >> (@as(u6, i) * 8)) & 0xFF);
            pos += 1;
            if (i == 0) break;
        }
    }

    header_buf[pos] = mask_key[0];
    pos += 1;
    header_buf[pos] = mask_key[1];
    pos += 1;
    header_buf[pos] = mask_key[2];
    pos += 1;
    header_buf[pos] = mask_key[3];
    pos += 1;

    try stream.writeAll(header_buf[0..pos]);

    // Write masked payload
    var tmp_buf: [4096]u8 = undefined;
    var off: usize = 0;
    while (off < len) {
        const chunk = @min(tmp_buf.len, len - off);
        for (payload[off .. off + chunk], 0..) |b, i| {
            tmp_buf[i] = b ^ mask_key[i % 4];
        }
        try stream.writeAll(tmp_buf[0..chunk]);
        off += chunk;
    }
}

// ---------------------------------------------------------------------------
// HTTP upgrade handshake
// ---------------------------------------------------------------------------

const ParsedUrl = struct { host: []const u8, port: u16, path: []const u8 };

fn parse_ws_url(url: []const u8) !ParsedUrl {
    // Expect ws://host[:port][/path]
    var rest = url;
    if (std.mem.startsWith(u8, rest, "ws://")) {
        rest = rest[5..];
    } else {
        return error.InvalidUrl;
    }

    const slash = std.mem.indexOf(u8, rest, "/");
    const host_port = if (slash) |s| rest[0..s] else rest;
    const path: []const u8 = if (slash) |s| rest[s..] else "/";

    const colon = std.mem.indexOf(u8, host_port, ":");
    const host: []const u8 = if (colon) |c| host_port[0..c] else host_port;
    const port: u16 = if (colon) |c|
        std.fmt.parseInt(u16, host_port[c + 1 ..], 10) catch 80
    else
        80;

    return .{ .host = host, .port = port, .path = path };
}

fn ws_handshake(stream: std.net.Stream, host: []const u8, path: []const u8) !void {
    // Minimal HTTP/1.1 upgrade request
    var buf: [512]u8 = undefined;
    const req = try std.fmt.bufPrint(
        &buf,
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n\r\n",
        .{ path, host },
    );
    try stream.writeAll(req);

    // Read response until \r\n\r\n
    var resp_buf: [1024]u8 = undefined;
    var resp_len: usize = 0;
    while (resp_len < resp_buf.len) {
        const n = try stream.read(resp_buf[resp_len .. resp_len + 1]);
        resp_len += n;
        if (resp_len >= 4 and std.mem.eql(u8, resp_buf[resp_len - 4 .. resp_len], "\r\n\r\n")) break;
    }
    // Verify 101 Switching Protocols
    if (!std.mem.startsWith(u8, &resp_buf, "HTTP/1.1 101")) return error.HandshakeFailed;
}
