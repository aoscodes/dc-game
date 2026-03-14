//! Browser WebSocket transport for WASM clients.
//!
//! The browser exposes WebSocket as a JS API.  WASM cannot call JS directly,
//! so we declare a small set of `extern "env"` functions that must be provided
//! by the JS glue layer (web/ws_glue.js).
//!
//! JS calls back into WASM by invoking the `export`ed functions below.
//! The handle (i32) is an opaque integer that maps to a WebSocket instance on
//! the JS side; the WASM side never dereferences it.
//!
//! Memory boundary rules:
//!   - Only numeric types (i32, u32, f32, …) cross the WASM↔JS boundary.
//!   - Strings/buffers: caller passes (ptr: [*]const u8, len: usize) into WASM
//!     linear memory; JS reads/writes via Uint8Array(memory.buffer, ptr, len).
//!   - JS re-derives the Uint8Array view after every WASM call because memory
//!     growth invalidates all existing TypedArray views.

const std = @import("std");
const shared = @import("shared");

// ---------------------------------------------------------------------------
// JS-provided extern functions
// ---------------------------------------------------------------------------

/// Open a WebSocket connection to `url`.
/// Returns a handle (>= 0) on success; -1 on failure.
extern "env" fn ws_connect(url_ptr: [*]const u8, url_len: usize) i32;

/// Send `len` bytes starting at `ptr` over the connection identified by `handle`.
extern "env" fn ws_send(handle: i32, ptr: [*]const u8, len: usize) void;

/// Close the connection identified by `handle`.
extern "env" fn ws_close(handle: i32) void;

/// Flush all queued JS socket events (open/message/close) into WASM callbacks.
/// Must be called once per frame from within the normal WASM call stack so that
/// Asyncify is not suspended when the callbacks run.
extern "env" fn ws_poll() void;

// ---------------------------------------------------------------------------
// WsBrowserTransport
// ---------------------------------------------------------------------------

/// A Transport backed by a browser WebSocket.
///
/// Usage:
///   1. Call `WsBrowserTransport.connect(url)` to open the socket.
///   2. Use `.transport()` to get a `shared.Transport` for sending.
///   3. Implement `on_message` / `on_open` / `on_close` callbacks in client
///      logic; they are called by the JS glue via the exported functions below.
pub const WsBrowserTransport = struct {
    handle: i32,

    /// Open a WebSocket connection to `url`.
    /// Returns an error if the JS layer reports failure (handle < 0).
    pub fn connect(url: []const u8) error{ConnectionFailed}!WsBrowserTransport {
        const h = ws_connect(url.ptr, url.len);
        if (h < 0) return error.ConnectionFailed;
        return .{ .handle = h };
    }

    pub fn close(self: *WsBrowserTransport) void {
        ws_close(self.handle);
    }

    /// No-op on WASM — the JS glue fires on_open asynchronously after the
    /// WebSocket handshake, by which point g_state.transport is already set.
    pub fn notify_open(_: *WsBrowserTransport) void {}

    /// Obtain a `shared.Transport` backed by this WebSocket.
    /// The `WsBrowserTransport` must outlive the returned Transport.
    pub fn transport(self: *WsBrowserTransport) shared.Transport {
        return .{ .send_fn = ws_send_impl, .ctx = self };
    }

    fn ws_send_impl(ctx: *anyopaque, msg: []const u8) anyerror!void {
        const self: *WsBrowserTransport = @ptrCast(@alignCast(ctx));
        ws_send(self.handle, msg.ptr, msg.len);
    }
};

// ---------------------------------------------------------------------------
// Static scratch buffer for incoming messages
// ---------------------------------------------------------------------------

/// JS writes raw message bytes here (via wasmMemory) before calling
/// on_ws_message.  Avoids alloc/free across the WASM↔JS boundary.
/// 4 KB is sufficient for all current protocol messages.
export var g_msg_buf: [4096]u8 = [_]u8{0} ** 4096;

// ---------------------------------------------------------------------------
// WASM exports — called by JS glue when socket events fire
// ---------------------------------------------------------------------------

/// Called by JS when the WebSocket `onopen` event fires.
export fn on_ws_open(handle: i32) void {
    client_on_ws_open(handle);
}

/// Called by JS when a binary message arrives.
/// JS must have written `len` bytes into `g_msg_buf` before calling this
/// export.  No alloc/free crosses the WASM↔JS boundary.
export fn on_ws_message(handle: i32, len: usize) void {
    if (len > g_msg_buf.len) return;
    client_on_ws_message(handle, g_msg_buf[0..len]);
}

/// Called by JS when the WebSocket `onclose` event fires.
export fn on_ws_close(handle: i32) void {
    client_on_ws_close(handle);
}

// ---------------------------------------------------------------------------
// Weak stubs — client/main.zig overrides these by providing strong definitions
// ---------------------------------------------------------------------------
//
// Zig does not have the C `__attribute__((weak))` concept, so instead we use
// function pointers stored in mutable globals.  client/main.zig calls
// `ws_browser.set_callbacks(...)` at startup to wire up its handlers.

pub const Callbacks = struct {
    on_open: *const fn (handle: i32) void,
    on_message: *const fn (handle: i32, data: []const u8) void,
    on_close: *const fn (handle: i32) void,
};

var g_callbacks: Callbacks = .{
    .on_open = default_on_open,
    .on_message = default_on_message,
    .on_close = default_on_close,
};

pub fn set_callbacks(cb: Callbacks) void {
    g_callbacks = cb;
}

/// Drain queued JS socket events. Call once per frame before processing input.
pub fn poll() void {
    ws_poll();
}

fn client_on_ws_open(handle: i32) void {
    g_callbacks.on_open(handle);
}

fn client_on_ws_message(handle: i32, data: []const u8) void {
    g_callbacks.on_message(handle, data);
}

fn client_on_ws_close(handle: i32) void {
    g_callbacks.on_close(handle);
}

fn default_on_open(_: i32) void {}
fn default_on_message(_: i32, _: []const u8) void {}
fn default_on_close(_: i32) void {}
