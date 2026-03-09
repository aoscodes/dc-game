const std = @import("std");
const shared = @import("shared");

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

pub const WsBrowserTransport = struct {
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
    handle: i32,
    thread: std.Thread,
    alive: std.atomic.Value(bool),
    caller_ready: std.atomic.Value(bool),

    pub fn connect(url: []const u8) error{ConnectionFailed}!WsBrowserTransport {
        const addr = parse_ws_url(url) catch return error.ConnectionFailed;
        const stream = std.net.tcpConnectToHost(
            std.heap.page_allocator,
            addr.host,
            addr.port,
        ) catch return error.ConnectionFailed;

        ws_handshake(stream, addr.host, addr.path) catch {
            stream.close();
            return error.ConnectionFailed;
        };

        return WsBrowserTransport{
            .stream = stream,
            .allocator = std.heap.page_allocator,
            .handle = 0,
            .thread = undefined,
            .alive = std.atomic.Value(bool).init(true),
            .caller_ready = std.atomic.Value(bool).init(false),
        };
    }

    pub fn notify_open(self: *WsBrowserTransport) void {
        self.caller_ready.store(true, .release);
        self.thread = std.Thread.spawn(.{}, read_loop, .{self}) catch {
            self.alive.store(false, .monotonic);
            return;
        };
    }

    pub fn close(self: *WsBrowserTransport) void {
        self.alive.store(false, .monotonic);
        self.stream.close();
        if (self.caller_ready.load(.monotonic)) {
            self.thread.join();
        }
    }

    pub fn transport(self: *WsBrowserTransport) shared.Transport {
        return .{ .send_fn = native_send, .ctx = self };
    }

    fn native_send(ctx: *anyopaque, msg: []const u8) anyerror!void {
        const self: *WsBrowserTransport = @ptrCast(@alignCast(ctx));
        try write_frame(self.stream, msg);
    }
};

fn read_loop(self: *WsBrowserTransport) void {
    g_callbacks.on_open(self.handle);

    var buf: [8192]u8 = undefined;
    while (self.alive.load(.monotonic)) {
        const frame = read_frame(self.stream, &buf) catch |err| {
            std.log.err("read_loop: read_frame error: {}", .{err});
            break;
        };
        std.log.debug("read_loop: opcode={} len={}", .{ frame.opcode, frame.payload.len });
        if (frame.opcode == 8) {
            std.log.info("read_loop: close frame received", .{});
            break;
        }
        if (frame.opcode == 9) {
            write_frame_opcode(self.stream, 10, frame.payload) catch |err| {
                std.log.err("read_loop: pong write error: {}", .{err});
            };
            continue;
        }
        if (frame.opcode == 2 or frame.opcode == 1) {
            g_callbacks.on_message(self.handle, frame.payload);
        }
    }
    self.alive.store(false, .monotonic);
    g_callbacks.on_close(self.handle);
}

const Frame = struct {
    opcode: u8,
    payload: []u8,
};

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

fn write_frame_opcode(stream: std.net.Stream, opcode: u8, payload: []const u8) !void {
    var header_buf: [10 + 4]u8 = undefined;
    var pos: usize = 0;

    header_buf[pos] = 0x80 | (opcode & 0x0F);
    pos += 1;

    const len = payload.len;
    const mask_key = [4]u8{ 0xDE, 0xAD, 0xBE, 0xEF };

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

fn write_frame(stream: std.net.Stream, payload: []const u8) !void {
    var header_buf: [10 + 4]u8 = undefined;
    var pos: usize = 0;

    header_buf[pos] = 0x82;
    pos += 1;

    const len = payload.len;
    const mask_key = [4]u8{ 0xDE, 0xAD, 0xBE, 0xEF };

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

const ParsedUrl = struct { host: []const u8, port: u16, path: []const u8 };

fn parse_ws_url(url: []const u8) !ParsedUrl {
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
    const host: []const u8 = if (colon) |col| host_port[0..col] else host_port;
    const port: u16 = if (colon) |col|
        std.fmt.parseInt(u16, host_port[col + 1 ..], 10) catch 80
    else
        80;

    return .{ .host = host, .port = port, .path = path };
}

fn ws_handshake(stream: std.net.Stream, host: []const u8, path: []const u8) !void {
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

    var resp_buf: [1024]u8 = undefined;
    var resp_len: usize = 0;
    while (resp_len < resp_buf.len) {
        const n = try stream.read(resp_buf[resp_len .. resp_len + 1]);
        resp_len += n;
        if (resp_len >= 4 and std.mem.eql(u8, resp_buf[resp_len - 4 .. resp_len], "\r\n\r\n")) break;
    }
    if (!std.mem.startsWith(u8, &resp_buf, "HTTP/1.1 101")) return error.HandshakeFailed;
}
