/**
 * ws_glue.js — JavaScript WebSocket bridge for the WASM client.
 *
 * Socket events (onopen, onmessage, onclose) arrive asynchronously from the
 * browser.  Calling WASM exports directly from those handlers is unsafe when
 * Asyncify is active: the WASM stack may be suspended inside emscripten_sleep
 * (called by WindowShouldClose), and re-entering it causes "index out of
 * bounds" / stack corruption.
 *
 * Solution: buffer all events in a JS queue.  Each frame, WASM calls the
 * ws_poll extern (provided by ws_lib.js), which drains the queue and invokes
 * the WASM callbacks synchronously — safely, from within the normal call stack.
 */

"use strict";

function createWsGlue() {
  let mod        = null;   // Emscripten Module, set by register()
  let wasmMemory = null;   // WebAssembly.Memory, set by register()

  // handle → WebSocket map; handles are small integers starting at 0.
  const sockets = {};
  let nextHandle = 0;

  // Pending events: { type: 'open'|'message'|'close', handle, data? }
  const eventQueue = [];

  function register(module) {
    mod        = module;
    wasmMemory = module.wasmMemory;
    module['ws_impl'].connect = ws_connect;
    module['ws_impl'].send    = ws_send;
    module['ws_impl'].close   = ws_close;
    module['ws_impl'].poll    = ws_poll;
  }

  function readString(ptr, len) {
    return new TextDecoder().decode(new Uint8Array(wasmMemory.buffer, ptr, len));
  }

  function writeBytes(ptr, bytes) {
    new Uint8Array(wasmMemory.buffer, ptr, bytes.length).set(bytes);
  }

  // -------------------------------------------------------------------------
  // Extern implementations (called FROM Zig/WASM via ws_lib.js stubs)
  // -------------------------------------------------------------------------

  function ws_connect(urlPtr, urlLen) {
    try {
      const url    = readString(urlPtr, urlLen);
      const handle = nextHandle++;
      const ws     = new WebSocket(url);
      ws.binaryType = "arraybuffer";
      sockets[handle] = ws;

      ws.onopen    = () => eventQueue.push({ type: 'open', handle });
      ws.onmessage = (ev) => eventQueue.push({ type: 'message', handle, data: new Uint8Array(ev.data) });
      ws.onerror   = (err) => console.error("WebSocket error on handle", handle, err);
      ws.onclose   = () => { eventQueue.push({ type: 'close', handle }); delete sockets[handle]; };

      return handle;
    } catch (e) {
      console.error("ws_connect failed:", e);
      return -1;
    }
  }

  function ws_send(handle, ptr, len) {
    const ws = sockets[handle];
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      console.warn("ws_send: socket", handle, "not open");
      return;
    }
    const slice = new Uint8Array(wasmMemory.buffer, ptr, len);
    ws.send(slice.slice());
  }

  function ws_close(handle) {
    const ws = sockets[handle];
    if (ws) { ws.close(); delete sockets[handle]; }
  }

  /**
   * ws_poll() — called once per frame by WASM (via ws_poll extern).
   * Drains the event queue and delivers events to WASM callbacks.
   * Always called from within the normal WASM call stack, never from an
   * async JS event, so it is safe to call WASM exports here.
   */
  function ws_poll() {
    if (!mod) return;
    while (eventQueue.length > 0) {
      const ev = eventQueue.shift();
      if (ev.type === 'open') {
        mod._on_ws_open(ev.handle);
      } else if (ev.type === 'message') {
        const len = ev.data.length;
        const ptr = mod._wasm_alloc(len);
        if (!ptr) { console.error("ws_poll: wasm_alloc returned null, dropping message"); continue; }
        writeBytes(ptr, ev.data);
        mod._on_ws_message(ev.handle, ptr, len);
        mod._wasm_free(ptr, len);
      } else if (ev.type === 'close') {
        mod._on_ws_close(ev.handle);
      }
    }
  }

  return { register };
}
