/**
 * ws_lib.js — Emscripten JS library providing ws_connect / ws_send / ws_close.
 *
 * These three functions are declared as `extern "env"` in ws_browser.zig.
 * Providing them via --js-library ensures Emscripten (and Closure Compiler)
 * preserves their names and wires them correctly in all optimize modes.
 *
 * Dispatch slots are held in the $ws_impl symbol (emitted by Emscripten as
 * `var ws_impl = {...}`).  Library function bodies reference `ws_impl`
 * directly — Emscripten does NOT add an underscore prefix to $-symbol
 * variable names in the emitted output; it only underscore-prefixes function
 * names (_ws_connect etc.).
 *
 * Module['ws_impl'] is exported via EXPORTED_RUNTIME_METHODS and populated
 * by ws_glue.js at onRuntimeInitialized time.
 */

mergeInto(LibraryManager.library, {
  // $ws_impl holds live implementations populated by ws_glue.js at runtime.
  $ws_impl: { connect: null, send: null, close: null, poll: null },

  // WASM extern: ws_connect(url_ptr: [*]u8, url_len: usize) i32
  ws_connect__deps: ['$ws_impl'],
  ws_connect: function(urlPtr, urlLen) {
    if (!ws_impl.connect) { console.error("ws_connect: not yet registered"); return -1; }
    return ws_impl.connect(urlPtr, urlLen);
  },

  // WASM extern: ws_send(handle: i32, ptr: [*]u8, len: usize) void
  ws_send__deps: ['$ws_impl'],
  ws_send: function(handle, ptr, len) {
    if (ws_impl.send) ws_impl.send(handle, ptr, len);
  },

  // WASM extern: ws_close(handle: i32) void
  ws_close__deps: ['$ws_impl'],
  ws_close: function(handle) {
    if (ws_impl.close) ws_impl.close(handle);
  },

  // WASM extern: ws_poll() void
  // Called once per frame from within the WASM main loop (safe Asyncify
  // call stack).  Flushes all queued socket events into WASM callbacks.
  ws_poll__deps: ['$ws_impl'],
  ws_poll: function() {
    if (ws_impl.poll) ws_impl.poll();
  },
});
