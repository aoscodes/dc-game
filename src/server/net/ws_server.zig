//! Server-side WebSocket transport backed by karlseguin/websocket.zig.
//!
//! Wraps a `*ws.Conn` as a `shared.Transport` so the session logic never
//! imports a concrete networking type.

const std = @import("std");
const ws = @import("websocket");
const shared = @import("shared");

pub fn conn_transport(conn: *ws.Conn) shared.Transport {
    return .{ .send_fn = conn_send, .ctx = conn };
}

fn conn_send(ctx: *anyopaque, msg: []const u8) anyerror!void {
    const conn: *ws.Conn = @ptrCast(@alignCast(ctx));
    try conn.writeBin(msg);
}
