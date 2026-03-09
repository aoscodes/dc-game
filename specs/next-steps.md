# Next Steps — Bug Fixes & Integration

## Issues

### Bug 1 — `join_lobby` never handled on server
`handle_client_message` has no case for `.join_lobby`. Player name stays "connecting..." forever.

### Bug 2 — Client never learns its own `player_id` during lobby
`LobbyUpdate` has no `your_player_id` field. `g_state.lobby.our_player_id` stays `0xFF`; lobby highlight never fires.

### Bug 3 — Reconnect flow not implemented on client
`send_join()` always sends `JoinLobby`. `save_player_id` is referenced in `index.html` as a WASM export but never exported from Zig.

### Bug 4 — Transport race condition in native client startup
`ws_native.zig` fires `on_ws_open` inside `connect()` before the caller assigns `g_state.transport`. `send_join()` sees `null` and silently drops the message.

### Bug 5 — Healer targeting logic wrong in client
`update_game()` confirm handler always sets `target_team = .enemies` when `action == .attack`. Healers target `.players`. Server receives `target_entity = 0`.

### Bug 6 — `our_player_id` not centralised
Lobby and game each have separate `our_player_id` fields; only the game one is ever set (from `game_start`). Lobby render can't highlight the local player's row.

---

## Deliverables (in order)

| # | Change | Files | Effort |
|---|---|---|---|
| 1 | Protocol: add `your_player_id` to `LobbyUpdate` wire format | `shared/protocol.zig` | S |
| 2 | Server: handle `join_lobby`; per-player `lobby_update` broadcast | `server/session.zig` | S |
| 3 | Client: learn pid from `lobby_update`, centralise `our_player_id`, export `save_player_id` | `client/main.zig` | S |
| 4 | Client: fix transport race — defer `on_ws_open` until after transport assigned | `client/net/ws_native.zig`, `client/main.zig` | S |
| 5 | Client: fix healer targeting — derive target team from own class | `client/main.zig` | S |

Steps 1+2 must land together (breaking wire format change).
Steps 3–5 are independent and follow after 1+2.

---

## Acceptance criteria

- Lobby shows each player's own name highlighted in yellow
- Two clients can connect, pick classes, ready up, and start a game
- Fighter attacking an enemy deals damage visible in HP bar
- Healer's attack action targets ally grid, restores HP
- Killing a client and reconnecting restores the slot (name preserved)
- `zig build test` passes throughout
