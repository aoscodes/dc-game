# Slime Feast — Playtester Briefing

Welcome! This doc tells you everything you need to play, and how to help us tune
the game. No technical background needed.

**Play here: http://198.74.58.178/game**

---

## 1. What the game is

Slime Feast is a **co-op realtime game for up to 4 players**. A crew of hungry
Lil Guys is parked at the **left edge** of a slime conveyor, and on a steady
clock they **bite the front columns whole** — good or bad, they eat
*everything* they can reach. Your job is to support them:

- Hazard slime comes in tiers: **red → yellow → green**. A live hazard the
  bite reaches is only **nibbled** — softened one tier — filling the shared
  **Hunger bar** for zero points.
- You **cast shapes** that stamp onto the field, downgrading every covered
  hazard one tier. Fully downgraded ("**defused**") slime is safe food: the
  bite consumes it whole, for a point.
- After each bite the survivors slide **left** and fresh slime pours in from
  the **right**: the field is a conveyor drifting into their mouths.

**You win** when the whole field (and the off-screen reserve) is eaten bare.
**Time runs out** when the Hunger bar fills — every single bite fills it, so
the bar is the game's clock, and nibbles are the clock wasted on nothing.
Either way you get a shared **score**: the slime consumed. It's everyone's
score together — this is a team game.

---

## 2. How casting works

Everything is realtime — there are no turns.

| Key | Meaning |
|-----|---------|
| `1` / `2` | Shape wheel: next / previous move |
| `← ↑ ↓ →` | Aim your cursor |
| `Enter` | Cast the selected shape at your cursor |
| `p` / `Shift+P` | Take / give up a player seat |

Rules of thumb:

- A cast lands the **instant you press it**. After each cast you have a short
  **cooldown** (default 0.75s) — presses inside it are simply ignored.
- Every cast costs **charges** from ONE pool shared by the whole team for the
  WHOLE game (canister pickups aside, it never refills). A cast you can't
  afford is refused and costs nothing.
- Your wheel pick **sticks** until you turn it again, and everyone can see
  everyone's pick and cursor — that visibility is how teams coordinate.

### Team recipes (groups)

Some shapes are too big for one player. Each landed cast stays **ripe** for a
short window (default 3s); when a **different** player lands the group's other
component on the **same square** inside that window, the group's big shape
fires there too. The completing player pays the group's cost instead of their
own. The lobby guide lists every move and group.

---

## 3. The bite clock

The Lil Guys bite on a tuneable clock (default: every 4s):

- Every **extra Lil Guy** at the table speeds the bites up (default +15% per
  guy past the first).
- Every **baby** Lil Guy speeds them up too (default +5% each) — babies your
  board brought AND babies hatched from eggs mid-game.
- The countdown to the next bite is on screen; the front columns the bite
  will chew are marked on the field.

Feel: the more of you there are, the faster the conveyor runs — defuse the
front before it lands in a mouth.

---

## 4. The tuning system — where you come in

**Every number above is a knob, not a rule.** All balance lives in editable
data, and you can change it yourself without any developer help:

1. Open **http://198.74.58.178/tune**.
2. Change any values, edit moves and groups, redesign the encounter.
3. Hit save — you get a **shareable link** like `/config/abc123...`.
4. Open that link to create a game with your settings. Friends who join with
   your room code automatically get the same settings.
5. To iterate on a saved config, open `/tune?from=<that hash>`.

Changes apply to **new games** — finish or leave your current game and create
a fresh one to feel the difference.

### The knobs (with current defaults)

| Knob | Default | What it does |
|------|---------|--------------|
| Bite interval | 4000 ms | Base ms between bites — the game's heartbeat |
| Speedup per lil guy | 15 % | Faster bites per seated player past the first |
| Speedup per baby | 5 % | Faster bites per baby at the table |
| Cast cooldown | 750 ms | Lockout after each of your casts |
| Team window | 3000 ms | How long a landed cast can still complete a group |
| Hunger per bite | 1 | Hunger per cell bitten — consumed and nibbled alike |
| Bite width | 1 column (+0 per guy) | Columns chewed per bite |
| Moves & groups | see the lobby guide | Shapes and costs — fully editable |
| Encounter | slime mix + charge pool | The field's contents and the team's whole casting budget |

### The tuning report

When a game ends, the **game-over screen is a full report**: totals for eaten
vs nibbled, each player's casts and coverage, which moves and groups fired and
how often. **Please screenshot this screen** and include it with your
feedback — it's the single most useful artifact you can send us.

---

## 5. Getting into a game

1. Go to **http://198.74.58.178/game** (or tap **Play** on the directory at
   the bare address). A game is always running; you join it — there is no
   screen in front of it, so you land straight on the board.
2. Press **p** to take a seat (or watch as an observer). The Lil Guys do not
   start eating until somebody sits, so an empty board is just waiting.
3. In game: `1`/`2` turn the wheel, arrows aim, `Enter` casts. Your held shape
   and cooldown are in your seat's panel at the bottom. The report's button
   starts the next encounter.

---

## 6. What feedback we want

- **Pacing**: Does the 4s bite feel tense or sluggish? Does the crowd speedup
  make a full table feel exciting or unfair? Try tuning the interval and the
  percents.
- **Cooldown feel**: Is 750ms between casts snappy enough? Does spamming feel
  punished or fine?
- **Hunger pressure**: Are games too easy or hopeless? Try bigger encounters,
  wider bites, leaner charge pools.
- **Groups**: Did you discover them from the guide? Is a 3s window enough to
  actually land one with a partner? Worth the coordination?
- **Your tuning experiments**: If you find settings that feel better (or
  hilariously broken), send us the `/config/...` link plus a game-over
  screenshot.

Thanks for playing — every session and screenshot makes the game better.
