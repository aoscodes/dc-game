//! Abstract transport interface.
//!
//! Game logic (sessions, AI, action resolution) sends messages through a
//! `Transport` value and never imports a concrete WebSocket implementation.
//! This makes it trivial to swap the underlying transport (e.g. switch from
//! WS to raw TCP, or use a loopback transport for tests).
//!
//! Concrete implementations:
//!   src/server/net/ws_server.zig  — websocket.zig server-side
//!   src/client/net/ws_browser.zig — extern JS WebSocket (WASM client)

const std = @import("std");

pub const Transport = struct {
    send_fn: *const fn (ctx: *anyopaque, msg: []const u8) anyerror!void,
    ctx: *anyopaque,

    pub fn send(self: Transport, msg: []const u8) !void {
        return self.send_fn(self.ctx, msg);
    }
};

pub const null_transport = Transport{
    .send_fn = null_send,
    .ctx = @ptrFromInt(1), // non-null sentinel; never dereferenced
};

fn null_send(_: *anyopaque, _: []const u8) anyerror!void {}

pub const BufferTransport = struct {
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn transport(self: *BufferTransport) Transport {
        return .{ .send_fn = buf_send, .ctx = self };
    }

    fn buf_send(ctx: *anyopaque, msg: []const u8) anyerror!void {
        const self: *BufferTransport = @ptrCast(@alignCast(ctx));
        try self.buf.appendSlice(self.allocator, msg);
    }
};

test "null_transport discards silently" {
    try null_transport.send("hello");
}

test "BufferTransport accumulates messages" {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(std.testing.allocator);

    var bt = BufferTransport{ .buf = &list, .allocator = std.testing.allocator };
    const t = bt.transport();

    try t.send("foo");
    try t.send("bar");

    try std.testing.expectEqualSlices(u8, "foobar", list.items);
}
