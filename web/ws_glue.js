/**
 * ws_glue.js — JavaScript WebSocket bridge for the WASM client.
 *
 * ws_connect / ws_send / ws_close are provided to WASM via web/ws_lib.js,
 * an Emscripten JS library that preserves their names through Closure
 * Compiler.  ws_lib.js exposes Module._ws_glue_register(impl) which this
 * file calls from onRuntimeInitialized to wire up the live implementations.
 *
 * Usage (in index.html):
 *   const wsGlue = createWsGlue();
 *   // In Module.onRuntimeInitialized:
 *   wsGlue.register(Module);
 *
 * Memory notes:
 *   - All Uint8Array views are derived fresh from memory.buffer on each use
 *     because WASM memory growth invalidates existing views.
 *   - Messages from WASM are copied out before the call returns.
 *   - Messages from JS are written into a buffer allocated via the WASM
 *     allocator (Module._wasm_alloc / Module._wasm_free).
 */

"use strict";

function createWsGlue() {
  let mod        = null;   // Emscripten Module, set by register()
  let wasmMemory = null;   // WebAssembly.Memory, set by register()

  // handle → WebSocket map; handles are small integers starting at 0.
  const sockets = {};
  let nextHandle = 0;

  /**
   * Call from Module.onRuntimeInitialized.
   * Registers the live ws_connect/ws_send/ws_close implementations with
   * ws_lib.js and stores the Module reference for WASM callbacks.
   */
  function register(module) {
    mod        = module;
    wasmMemory = module.wasmMemory;
    // Populate the ws_impl dispatch slots exposed by ws_lib.js via
    // EXPORTED_RUNTIME_METHODS so ws_connect/ws_send/ws_close call our impls.
    module['ws_impl'].connect = ws_connect;
    module['ws_impl'].send    = ws_send;
    module['ws_impl'].close   = ws_close;
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
  // Extern implementations (called FROM Zig/WASM via ws_lib.js stubs)
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
        if (mod) mod._on_ws_open(handle);
      };

      ws.onmessage = (ev) => {
        if (!mod) return;
        const bytes = new Uint8Array(ev.data);
        const len   = bytes.length;

        // Allocate a buffer in WASM memory, copy message in, call handler,
        // then free.  Requires the WASM module to export alloc/free.
        const ptr = mod._wasm_alloc(len);
        if (!ptr) {
          console.error("ws_glue: wasm_alloc returned null, dropping message");
          return;
        }
        writeBytes(ptr, bytes);
        mod._on_ws_message(handle, ptr, len);
        mod._wasm_free(ptr, len);
      };

      ws.onerror = (err) => {
        console.error("WebSocket error on handle", handle, err);
      };

      ws.onclose = () => {
        if (mod) mod._on_ws_close(handle);
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

  return { register };
}
