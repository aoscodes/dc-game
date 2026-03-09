/**
 * ws_glue.js — JavaScript WebSocket bridge for the WASM client.
 *
 * This file is injected into the Emscripten module's importObject under the
 * "env" namespace.  It implements the three extern functions declared in
 * src/client/net/ws_browser.zig and routes WebSocket events back into WASM
 * by calling the exported Zig functions.
 *
 * Usage (in index.html):
 *   const wsGlue = createWsGlue();   // call before instantiating WASM
 *   // merge wsGlue.env into your importObject.env
 *   // after WASM is instantiated, call wsGlue.setInstance(wasmInstance)
 *
 * Memory notes:
 *   - All Uint8Array views are derived fresh from memory.buffer on each use
 *     because WASM memory growth invalidates existing views.
 *   - Messages from WASM are copied out before the call returns.
 *   - Messages from JS are written into a small stack buffer allocated via
 *     the WASM allocator (see index.html bootstrap for the alloc export).
 */

"use strict";

function createWsGlue() {
  let wasmInstance = null;
  let wasmMemory   = null;   // WebAssembly.Memory object

  // handle → WebSocket map; handles are small integers starting at 0.
  const sockets = {};
  let nextHandle = 0;

  /** Call after the WASM module is instantiated. */
  function setInstance(instance, memory) {
    wasmInstance = instance;
    wasmMemory   = memory;
  }

  /** Read a UTF-8 string from WASM linear memory. */
  function readString(ptr, len) {
    return new TextDecoder().decode(new Uint8Array(wasmMemory.buffer, ptr, len));
  }

  /**
   * Write `bytes` (Uint8Array) into WASM memory at `ptr`.
   * Caller must ensure there is sufficient space.
   */
  function writeBytes(ptr, bytes) {
    new Uint8Array(wasmMemory.buffer, ptr, bytes.length).set(bytes);
  }

  // -------------------------------------------------------------------------
  // Extern functions (called FROM Zig/WASM)
  // -------------------------------------------------------------------------

  /**
   * ws_connect(url_ptr, url_len) → i32
   * Opens a new WebSocket.  Returns a handle >= 0 or -1 on failure.
   */
  function ws_connect(urlPtr, urlLen) {
    try {
      const url    = readString(urlPtr, urlLen);
      const handle = nextHandle++;
      const ws     = new WebSocket(url);
      ws.binaryType = "arraybuffer";
      sockets[handle] = ws;

      ws.onopen = () => {
        if (wasmInstance) wasmInstance.exports.on_ws_open(handle);
      };

      ws.onmessage = (ev) => {
        if (!wasmInstance) return;
        const bytes  = new Uint8Array(ev.data);
        const len    = bytes.length;

        // Allocate a buffer in WASM memory, copy message in, call handler,
        // then free.  Requires the WASM module to export alloc/free.
        const ptr = wasmInstance.exports.wasm_alloc(len);
        if (!ptr) {
          console.error("ws_glue: wasm_alloc returned null, dropping message");
          return;
        }
        writeBytes(ptr, bytes);
        wasmInstance.exports.on_ws_message(handle, ptr, len);
        wasmInstance.exports.wasm_free(ptr, len);
      };

      ws.onerror = (err) => {
        console.error("WebSocket error on handle", handle, err);
      };

      ws.onclose = () => {
        if (wasmInstance) wasmInstance.exports.on_ws_close(handle);
        delete sockets[handle];
      };

      return handle;
    } catch (e) {
      console.error("ws_connect failed:", e);
      return -1;
    }
  }

  /**
   * ws_send(handle, ptr, len)
   * Sends a binary message from WASM memory over the socket.
   */
  function ws_send(handle, ptr, len) {
    const ws = sockets[handle];
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      console.warn("ws_send: socket", handle, "not open");
      return;
    }
    // Copy out before sending; the WASM memory view must not be held.
    const slice = new Uint8Array(wasmMemory.buffer, ptr, len);
    ws.send(slice.slice());
  }

  /**
   * ws_close(handle)
   * Closes the socket.
   */
  function ws_close(handle) {
    const ws = sockets[handle];
    if (ws) {
      ws.close();
      delete sockets[handle];
    }
  }

  return {
    /** Merge these into your WASM importObject.env. */
    env: { ws_connect, ws_send, ws_close },
    setInstance,
  };
}
