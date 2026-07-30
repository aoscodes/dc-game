# Slime Feast — Playtester Briefing

Welcome! This doc tells you everything you need to play, and how to help us tune
the game. No technical background needed.

**Play here: http://198.74.58.178**

---

## 1. What the game is

Slime Feast is a **co-op game for up to 6 players**. A horde of hungry Lil Guys
is devouring a slime field, one zone at a time — and they will eat *everything*,
good or bad. Your job is to support them:

- Some slime is **Modified** (colored red, green, yellow, or blue). Eating it
  hurts — it fills the shared **Hunger bar** fast.
- You **Dispense** color-matched **Neutralizing Agents** to purify Modified
  Slime before it gets eaten. Purified ("Neutralized") slime is safe.
- You dispense **Medicine** to heal Hunger damage — but only damage caused by
  modified slime of the *same color* as the medicine.

**You win** when the whole field is cleared. **You lose** if the Hunger bar
fills up. Either way you get a shared **score**: the amount of safe slime the
Lil Guys ate. It's everyone's score together — this is a team game.

---

## 2. How casting works (both modes)

You build **combos** of up to 5 key presses:

| Key | Meaning |
|-----|---------|
| Q | Red |
| W | Green |
| E | Yellow |
| R | Blue |
| 1 | Dispense (Neutralizing Agents) |
| 2 | Medicine |
| Esc | Cancel your combo |

Rules of thumb:

- **Pick a color first, then actions.** The color "sticks" until you pick a new
  one. So `Q 1 1` = red, dispense, dispense — two doses of red agents.
- An action with **no color yet is wasted**. Don't start with 1 or 2.
- An **empty or all-wasted combo fizzles for free** — it doesn't count against
  you.
- Agents only purify slime of the **matching color**. Extra or wrong-colored
  agents are wasted.
- Medicine is color-locked too: blue medicine only heals hunger damage caused
  by blue modified slime, and can't heal more than that damage. Overheal is
  discarded.

### Recipes

Exact combo patterns produce **bonus output** instead of the normal amount. The
lobby screen lists all recipes with their key sequences. Current defaults:

**Solo recipes** (you cast the exact pattern yourself):

| Recipe | Keys | Output |
|--------|------|--------|
| Big Red | Q 1 1 1 | 20 red agents |
| Big Green | W 1 1 1 | 20 green agents |
| Big Yellow | E 1 1 1 | 20 yellow agents |
| Big Blue | R 1 1 1 | 20 blue agents |
| Prism | Q 1 R 1 | 6 agents of *every* color |
| Panacea | R 2 2 | 10 blue medicine |

**Team recipes** (two *different* players cast matching patterns at the same
time — big payoffs, coordinate with voice chat!):

| Recipe | Player A | Player B | Output |
|--------|----------|----------|--------|
| Twin Red | Q 1 1 | Q 1 1 | 30 red agents + 20 red medicine |
| Twin Brown | R 1 1 | W 1 1 | 40 green + 40 blue agents |

---

## 3. Classic mode (turn-based)

The default mode. Play proceeds in **rounds** on a shared timer
(default: 5 seconds per round).

- Each round you get a limited number of casts (default: **1**). Compose your
  combo freely during the cast window — **your latest edit wins**, Esc cancels.
- When the window closes, your combo **auto-commits**. No Enter needed.
- Team recipes fire when players' combos match **in the same window**.
- At the **end of the round, the Lil Guys eat the entire current zone**: safe
  slime scores points, un-purified modified slime spikes the Hunger bar. Then
  the next zone starts.

Feel: deliberate and chess-like. You have a few seconds to read the zone,
agree on a plan, and commit.

## 4. Realtime mode

Same game, no rounds — everything flows continuously.

- The Lil Guys **eat constantly** (default: 2 slime per second, *per connected
  player* — more players, faster feast).
- Compose your combo, then **press Enter to cast**. It fires **0.5 seconds
  later** (default).
- If another player's cast lands in that 0.5s window and together you complete
  a **team recipe, your casts merge and fire together** — you'll see
  "team combo locked!".
- After each cast you have a short **cooldown** (default 0.5s). If you press
  Enter again before your pending cast fires, it **replaces** the pending one.
- When a zone is eaten bare, the next one starts immediately.

Feel: fast and reactive. Purify slime before it disappears into mouths.

---

## 5. The tuning system — where you come in

**Every number above is a knob, not a rule.** All balance lives in editable
data, and you can change it yourself without any developer help:

1. Open **http://198.74.58.178/tune** (or **/tune?mode=realtime** for the
   realtime view).
2. Change any values, edit recipes, even redesign the slime zones.
3. Hit save — you get a **shareable link** like `/config/abc123...`.
4. Open that link to create a lobby with your settings. Friends who join with
   your room code automatically get the same settings.
5. To iterate on a saved config, open `/tune?from=<that hash>`.

Changes apply to **new lobbies** — finish or leave your current game and create
a fresh one to feel the difference.

### The knobs (with current defaults)

| Knob | Default | What it does |
|------|---------|--------------|
| Casts per round | 1 | Classic: spells each player gets per round |
| Round duration | 5 s | Classic: length of each round |
| Units per slot | 5 | Agents produced per dispense press (non-recipe) |
| Medicine per slot | 3 | Medicine produced per medicine press (non-recipe) |
| Hunger cost (normal) | 1 | Hunger per slime eaten — never healable |
| Hunger cost (modified extra) | 2 | *Extra* hunger per un-purified modified slime — this part is healable |
| Neutralize residue | 0.5 | Fraction of purified slime that survives to be eaten (rest vanishes — safer, but less score) |
| Eat rate | 2 /s per player | Realtime: how fast the Lil Guys eat |
| Cast buffer | 0.5 s | Realtime: delay before a cast fires = team-recipe pairing window |
| Cast cooldown | 0.5 s | Realtime: lockout after each cast |
| Recipes | see above | Patterns and payouts, solo and team — fully editable |
| Encounters | 3-zone (hunger 200) and 9-zone (hunger 700) | Zone-by-zone slime amounts/colors and the hunger budget — the main difficulty dials |

### The tuning report

When a game ends, the **game-over screen is a full report**: a per-round table,
each player's casts, which recipes fired and how often, and totals for wasted
agents and overhealed medicine. **Please screenshot this screen** and include
it with your feedback — it's the single most useful artifact you can send us.

---

## 6. Getting into a game

1. Go to **http://198.74.58.178** (classic) or
   **http://198.74.58.178/realtime** (realtime).
2. On the start screen:
   - **C** — create a lobby (in the page's mode)
   - **R** — create a lobby in the *other* mode
   - **J** — join a friend's lobby by 6-character room code
3. In the lobby, press **Enter** to toggle Ready. The lobby shows a
   "How casting works" guide and all current recipes.
4. In game: Q/W/E/R colors, 1/2 actions, Esc cancels. In realtime, **Enter
   submits your cast**. Any key leaves the game-over screen.

---

## 7. What feedback we want

- **Pacing**: Does classic feel too slow/rushed at 5s rounds? Does realtime
  feel frantic or sluggish? Try tuning round duration and eat rate.
- **Hunger pressure**: Are games too easy or hopeless? Try the 9-zone
  encounter; try tweaking hunger costs and budget.
- **Recipes**: Did you discover them from the lobby guide? Are team recipes
  worth coordinating for? Too strong? Too fiddly to line up in realtime?
- **Casting feel**: Realtime — does the 0.5s buffer/cooldown feel good?
  Classic — is one cast per round enough to feel involved?
- **Your tuning experiments**: If you find settings that feel better (or
  hilariously broken), send us the `/config/...` link plus a game-over
  screenshot.

Thanks for playing — every session and screenshot makes the game better.
