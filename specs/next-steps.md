# Next Steps

## Status

All bugs from the previous list are resolved. `zig build test` passes (31/31).

## Known gaps / next areas

### Gameplay
- No player name entry UI — name hardcoded to "Player"
- Game over screen only shows "Game Over!" — no winner/loser detail
- No action feedback UI (damage numbers, heal flash, etc.)

### Networking
- WASM / browser client not tested end-to-end
- `reconnect` during in-game phase: server keeps slot, but client needs to re-sync game state on reconnect (currently only broadcasts `lobby_update`, not `game_state`)

### Testing
- No test for mid-game reconnect (game_state re-sync path)
- No test for wave chain progression
- No e2e test for healer / mage action paths
