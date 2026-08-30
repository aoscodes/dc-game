// Mirror check: web/game.js stampOn / activateOn / detonateOn / biteFeast
// against src/shared/slime.zig stamp / activate / detonate / feast, for
// cast activation and reaction chains.  Every scenario here has a twin in
// slime.zig's "cast activation" test block; the boards must match cell for
// cell.
import { readFileSync } from "node:fs";
// Resolved from THIS file, not the cwd: the harness is run by
// `zig build web-test` from the repo root and by hand from anywhere.
const src = readFileSync(
  new URL("../game.js", import.meta.url), "utf8");

function extract(name) {
  const start = src.indexOf(`function ${name}(`);
  if (start < 0) throw new Error(`missing function ${name}`);
  let i = src.indexOf("{", start), depth = 0;
  for (; i < src.length; i++) { if (src[i] === "{") depth++; else if (src[i] === "}" && --depth === 0) break; }
  return src.slice(start, i + 1);
}
function extractConst(name) {
  const start = src.indexOf(`const ${name} = [`);
  if (start < 0) throw new Error(`missing const ${name}`);
  const end = src.indexOf("];", start);
  return src.slice(start, end + 2);
}

/** Build a sandbox with the real game.js walks and a chosen tuning. */
function build({ activateOn = {}, maxDepth = 3, blastChains = false, rocksOnly = false } = {}) {
  return new Function(`
    const TIER_NAMES = ["red", "yellow", "green"];
    const TIER_CHAR = { red: "\u2261", yellow: "=", green: "-" };
    const BOMB_ROCKS_ONLY = ${rocksOnly};
    const ROCK_BITE_COSTS_HUNGER = false;
    const SPECIAL_ACTIVATE_ON = ${JSON.stringify(activateOn)};
    const MAX_CHAIN_DEPTH = ${maxDepth};
    const BLAST_CHAINS = ${blastChains};
    ${extractConst("AGENT_BLOCK_OFFSETS")}
    ${extract("activatesOnCast")}
    ${extract("activatesOnEat")}
    ${extract("downgradeName")}
    ${extract("hazardTier")}
    ${extract("cellIsEdible")}
    ${extract("cellIsSlime")}
    ${extract("cellStyle")}
    ${extract("agentBlockCells")}
    ${extract("detonateOn")}
    ${extract("shapeOutcome")}
    ${extract("stampOn")}
    ${extract("activateOn")}
    ${extract("biteFeast").replace(
        "return { eaten, nibbled, gnawed, order };",
        "return { eaten, nibbled, gnawed, order, board: work };")}
    // --- replay side.  bite()/biteAt() are the CINEMATIC's mirror of the
    // same rules; they must land on the identical board or the player
    // watches a meal the server never served.  Stubbed only where they
    // touch the screen.
    let cinematic = null;
    const cellAnim = new Map();
    const FIELD = { popS: 1, flashS: 1 };
    const WAVE_S = 0.3;
    const LAYOUT = { floater: { stack: 0 }, chainFx: {
      waveS: WAVE_S, maxWaves: 4, lifeS: 0.45, count: 1, speed: 0, speedJitter: 0,
      gravity: 0, size: 1, sizeJitter: 0, max: 700,
    } };
    const SPECIAL_COLOR = "violet", BOMB_COLOR = "orange", CANISTER_COLOR = "";
    const cellCenter = () => ({ x: 0, y: 0 });
    const parseRgb = () => [0, 0, 0];
    const spawnFlyTri = () => {};
    const spawnFloater = () => {};
    ${extract("spawnChainBurst")}
    ${extract("tickChainParticles")}
    ${extract("chainRevealsPending")}
    ${extract("tickGridAnims")}
    ${extract("animProgress")}
    const chainParticles = [];
    // The real scheduler, not a stub: the WHOLE point of the effect is which
    // cell is held how long, so a harness that faked it would be testing
    // nothing.  Every event the walks report is also logged, so a scenario
    // can assert the link and the cause a cell was reached by.
    const fxLog = [];
    ${extract("scheduleChainFx").replace(
        "function scheduleChainFx(ev, rows, cols) {",
        "function scheduleChainFx(ev, rows, cols) {\n  fxLog.push({ ...ev });")}
    ${extract("bite")}
    ${extract("biteAt")}
    const runReplayBite = (board, rows, cols, order) => {
      cinematic = { board, rows, cols };
      fxLog.length = 0; cellAnim.clear(); chainParticles.length = 0;
      for (const flat of order) biteAt(null, flat);
      return board;
    };
    return { runReplayBite, stampOn, activateOn, detonateOn, biteFeast, shapeOutcome,
             activatesOnCast, activatesOnEat, agentBlockCells, scheduleChainFx,
             tickChainParticles, chainRevealsPending, tickGridAnims,
             cellAnim, chainParticles, fxLog, WAVE_S,
             AGENT_BLOCK_OFFSETS };
  `)();
}

let failures = 0;
const ok = (cond, msg, extra) => {
  if (!cond) { console.error("FAIL:", msg, extra ?? ""); failures++; }
};
const eq = (a, b, msg) => ok(JSON.stringify(a) === JSON.stringify(b), msg, `${JSON.stringify(a)} != ${JSON.stringify(b)}`);

const E = "empty", RED = "red", N = "special_neutralizer", B = "special_bomb";
const DOT = [{ dRow: 0, dCol: 0 }];
const SQ3 = [];
for (let dr = -1; dr <= 1; dr++) for (let dc = -1; dc <= 1; dc++) SQ3.push({ dRow: dr, dCol: dc });

const blank = (n) => Array(n).fill(E);

// --- 1. A cast is INERT on a special by default -----------------------------
// Twin: slime.zig "a cast is INERT on a special by default".
{
  const ctx = build();
  const board = blank(9);
  board[4] = B; board[0] = RED;
  const out = ctx.shapeOutcome();
  ctx.stampOn(board, DOT, 1, 1, 3, 3, out, 0);
  ok(out.inert === 1, "unarmed bomb is inert", out);
  ok(out.activated === 0, "unarmed bomb does not activate", out);
  ok(board[4] === B, "unarmed bomb survives the cast", board[4]);

  // Armed: goes off, levels its 3x3, and is cleared before its own blast.
  const armedCtx = build({ activateOn: { special_bomb: "cast" } });
  const armed = blank(9);
  armed[4] = B; armed[0] = RED;
  const armedOut = armedCtx.shapeOutcome();
  armedCtx.stampOn(armed, DOT, 1, 1, 3, 3, armedOut, 0);
  ok(armedOut.activated === 1, "armed bomb activates", armedOut);
  ok(armedOut.destroyed === 1, "the blast took the lone red", armedOut);
  eq(armed, blank(9), "armed cast clears the board");
}

// --- 2. An armed special is still EATEN, but its effect is LOST -------------
// Twin: slime.zig "an armed special is still EATEN — but its effect is LOST".
{
  const row = () => [B, RED, RED];
  const fired = build().biteFeast(row(), 1, 3, 1);
  const lost = build({ activateOn: { special_bomb: "cast" } }).biteFeast(row(), 1, 3, 1);
  // Swallowed either way: same cells visited, same eaten set.
  eq([...fired.eaten], [...lost.eaten], "armed bomb is still eaten");
  eq(fired.order, lost.order, "the bite walks identically");
  // `eatcast` restores the blast without giving up the cast trigger.
  const both = build({ activateOn: { special_bomb: "eatcast" } }).biteFeast(row(), 1, 3, 1);
  eq([...fired.eaten], [...both.eaten], "eatcast eats like eat");
}

// --- 3. Activation CLEARS before firing (no self-retrigger) -----------------
// Twin: slime.zig "activation CLEARS the unit before firing".  Completing
// at all is the assertion: a live self-trigger would hang here.
{
  const ctx = build({ activateOn: { special_neutralizer: "cast" } });
  const board = blank(9);
  board[4] = N;
  board[0] = "green"; board[1] = "green"; board[8] = "green";
  const out = ctx.shapeOutcome();
  ctx.stampOn(board, DOT, 1, 1, 3, 3, out, 0);
  ok(out.activated === 1, "neutralizer activated once", out);
  ok(board[4] === E, "the neutralizer was spent", board[4]);
  ok(out.neutralized === 3, "its block defused the three greens", out);
  eq([board[0], board[1], board[8]], ["defused", "defused", "defused"], "greens defused");
}

// --- 4. Chain depth ---------------------------------------------------------
// Twin: slime.zig "a chain runs from special to special, bounded by
// max_chain_depth".  A cap of N sets off N+1 units.
for (const [cap, fired] of [[0, 1], [1, 2], [3, 4], [9, 5]]) {
  const ctx = build({ activateOn: { special_neutralizer: "cast" }, maxDepth: cap });
  const board = Array(5).fill(N);
  const out = ctx.shapeOutcome();
  ctx.stampOn(board, DOT, 0, 0, 1, 5, out, 0);
  ok(out.activated === fired, `cap ${cap} fires ${fired}`, out.activated);
  ok(board.filter((c) => c !== E).length === 5 - fired,
    `cap ${cap} leaves ${5 - fired} standing`, board);
}

// --- 5. blast_chains --------------------------------------------------------
// Twin: slime.zig "blast_chains makes one bomb set off the next".  Bombs at
// (1,0) and (1,1) on a 3x4; the witness red at (1,2) is outside the FIRST
// blast (cols 0..1) and inside the second's (cols 0..2).
{
  const seed = () => { const b = blank(12); b[4] = B; b[5] = B; b[6] = RED; return b; };
  const quiet = seed();
  build({ activateOn: { special_bomb: "cast" } })
    .stampOn(quiet, DOT, 1, 0, 3, 4, build().shapeOutcome(), 0);
  ok(quiet[6] === RED, "without blast_chains the far red lives", quiet[6]);

  const loud = seed();
  const loudCtx = build({ activateOn: { special_bomb: "cast" }, blastChains: true });
  const out = loudCtx.shapeOutcome();
  loudCtx.stampOn(loud, DOT, 1, 0, 3, 4, out, 0);
  ok(loud[6] === E, "the chain reached the far red", loud[6]);
  ok(out.activated === 1, "the cast armed exactly one", out);
  ok(out.destroyed > 1, "the chain destroyed more than one", out);
  eq(loud, blank(12), "the whole board went up");
}

// --- 6. blast_chains belongs to the BLAST: a SWALLOWED bomb chains too ------
// Twin: slime.zig "blast_chains belongs to the BLAST".
{
  // Bombs at (1,0) and (1,1) on a 3x4, witness red at (1,2).  A bite three
  // columns wide reaches the red, so whether it is NIBBLED is the readout:
  // the chain destroys it first, the plain blast does not.
  const seed = () => { const b = blank(12); b[4] = B; b[5] = B; b[6] = RED; return b; };
  const chained = build({ blastChains: true }).biteFeast(seed(), 3, 4, 3);
  const plain = build().biteFeast(seed(), 3, 4, 3);
  ok(chained.eaten.size === 1, "one bomb was EATEN, not cast at", chained.eaten.size);
  ok(plain.eaten.size === 1, "same for the control", plain.eaten.size);
  ok(!chained.nibbled.has(6), "the swallowed bomb's chain destroyed the far red",
    [...chained.nibbled]);
  ok(plain.nibbled.has(6), "without the knob the far red survives to be nibbled",
    [...plain.nibbled]);
}

// --- 7. Offset ORDER against the standing board -----------------------------
// Twin: slime.zig "a stamp activates IN OFFSET ORDER".  Two adjacent bombs
// under one 3x3: the first blast clears the second before the later offset
// reaches it, so only ONE activates.
{
  const ctx = build({ activateOn: { special_bomb: "cast" } });
  const board = blank(9);
  board[0] = B; board[1] = B;
  const out = ctx.shapeOutcome();
  ctx.stampOn(board, SQ3, 1, 1, 3, 3, out, 0);
  ok(out.activated === 1, "only the first bomb activated", out);
  ok(out.inert > 0, "the later offset found a crater and counted it waste", out);
  eq(board, blank(9), "the board is empty");
}

// --- 8. An eaten neutralizer's block sets off an armed special --------------
// Twin: slime.zig "an eaten neutralizer's block can set off an armed special".
{
  const board = blank(9);
  board[3] = N; board[4] = B; board[8] = RED;
  build({ activateOn: { special_bomb: "cast" } }).biteFeast(board, 3, 3, 1);
  ok(board[8] === RED, "biteFeast must not mutate the caller's board", board[8]);
}
{
  // The board biteFeast simulates internally is not returned, so the effect
  // is observed through what the bite could then reach: with the bomb armed,
  // the neutralizer's block sets it off and the blast empties (2,2).
  const board = blank(9);
  board[3] = N; board[4] = B; board[8] = RED;
  const wide = build({ activateOn: { special_bomb: "cast" } }).biteFeast(board, 3, 3, 3);
  // The blast cleared (2,2) before the walk reached column 2, so the red was
  // never nibbled.
  ok(!wide.nibbled.has(8), "the chain destroyed the red before the bite got there",
    [...wide.nibbled]);
}

// --- 9. The eat gate is per-kind, not global --------------------------------
{
  const ctx = build({ activateOn: { special_bomb: "cast" } });
  ok(ctx.activatesOnEat("special_neutralizer"), "untuned kinds still fire on eat");
  ok(!ctx.activatesOnEat("special_bomb"), "a cast-armed bomb does not fire on eat");
  ok(ctx.activatesOnCast("special_bomb"), "a cast-armed bomb fires on cast");
  ok(!ctx.activatesOnCast("special_neutralizer"), "an untuned kind ignores the cast");
  const both = build({ activateOn: { special_bomb: "eatcast" } });
  ok(both.activatesOnEat("special_bomb") && both.activatesOnCast("special_bomb"),
    "eatcast fires on both");
}

// --- 10. AGENT_BLOCK_OFFSETS matches agentBlockCells' order -----------------
// The two must walk identically or an activated block and an eaten one would
// resolve in different orders.
{
  const ctx = build();
  const viaOffsets = (center, rows, cols) => {
    const r = Math.floor(center / cols), c = center % cols;
    return ctx.AGENT_BLOCK_OFFSETS
      .map(({ dRow, dCol }) => [r + dRow, c + dCol])
      .filter(([rr, cc]) => rr >= 0 && rr < rows && cc >= 0 && cc < cols)
      .map(([rr, cc]) => rr * cols + cc);
  };
  // Every centre, including the clipped corners and edges, on an odd grid.
  for (let center = 0; center < 12; center++) {
    eq(viaOffsets(center, 3, 4), ctx.agentBlockCells(center, 3, 4),
      `block offsets and agentBlockCells agree at ${center}`);
  }
}

// --- 11. The REPLAY board must equal the SIMULATED board -------------------
// biteFeast (used for the reachability preview) and bite/biteAt (used by the
// feast cinematic) are two independent mirrors of slime.feast.  Walking the
// same `order` over the same start board must leave them identical — any
// drift here is a meal the player watches that the server never served.
// This is what a cast-armed special breaks if bite() forgets the eat gate.
{
  const boards = [
    // A neutralizer beside hazards, so its block matters.
    { cells: { 0: N, 1: "green", 4: "red" }, rows: 3, cols: 3, w: 3 },
    // A bomb beside a hazard, so its blast matters.
    { cells: { 0: B, 1: "green", 4: "red" }, rows: 3, cols: 3, w: 3 },
    // Both, adjacent: a swallowed neutralizer's block lands on the bomb.
    { cells: { 3: N, 4: B, 8: RED }, rows: 3, cols: 3, w: 3 },
    // Two bombs, for the chain.
    { cells: { 4: B, 5: B, 6: RED }, rows: 3, cols: 4, w: 4 },
  ];
  const tunings = [
    { name: "default", opts: {} },
    { name: "bomb armed for cast", opts: { activateOn: { special_bomb: "cast" } } },
    { name: "neutralizer armed for cast", opts: { activateOn: { special_neutralizer: "cast" } } },
    { name: "bomb eatcast", opts: { activateOn: { special_bomb: "eatcast" } } },
    { name: "blast chains", opts: { blastChains: true } },
    { name: "bomb armed + chains", opts: { activateOn: { special_bomb: "cast" }, blastChains: true } },
    { name: "no chains at all", opts: { activateOn: { special_bomb: "cast" }, maxDepth: 0 } },
  ];
  for (const b of boards) {
    for (const t of tunings) {
      const ctx = build(t.opts);
      const seed = () => {
        const arr = blank(b.rows * b.cols);
        for (const [k, v] of Object.entries(b.cells)) arr[+k] = v;
        return arr;
      };
      // biteFeast simulates on its own copy and hands back the walk order.
      const sim = seed();
      const meal = ctx.biteFeast(sim, b.rows, b.cols, b.w);
      // Re-derive the board biteFeast ended on by replaying its own order
      // through the cinematic's walk.
      const replay = ctx.runReplayBite(seed(), b.rows, b.cols, meal.order);

      // And the reference: biteFeast's internal board, recovered by running
      // it again and diffing through reachability's override contract.
      const reference = seed();
      const ref = ctx.biteFeast(reference, b.rows, b.cols, b.w);
      eq(ref.order, meal.order, `${t.name}: biteFeast is deterministic`);

      // EXACT: the cinematic's board and the simulation's board must be
      // the same board.  Anything weaker lets a divergence hide in a cell
      // neither `eaten` nor `nibbled` happens to name — which is exactly
      // where a wrong chain depth puts one.
      eq(replay, meal.board,
        `${t.name} / ${JSON.stringify(b.cells)}: replay board must equal the simulated board`);
    }
  }
}

// --- 12. The replay must NOT detonate a cast-armed bomb it swallows --------
// The specific divergence: with the bomb armed for the cast, the server eats
// it silently, so the replay board must keep the neighbours the blast would
// otherwise have taken.
{
  const seed = () => { const b = blank(9); b[0] = B; b[4] = RED; return b; };
  const armedCtx = build({ activateOn: { special_bomb: "cast" } });
  const armedMeal = armedCtx.biteFeast(seed(), 3, 3, 1);
  const armedBoard = armedCtx.runReplayBite(seed(), 3, 3, armedMeal.order);
  ok(armedBoard[4] === RED, "an armed bomb goes down SILENTLY in the replay too", armedBoard[4]);

  const plainCtx = build();
  const plainMeal = plainCtx.biteFeast(seed(), 3, 3, 1);
  const plainBoard = plainCtx.runReplayBite(seed(), 3, 3, plainMeal.order);
  ok(plainBoard[4] === E, "an unarmed bomb still detonates in the replay", plainBoard[4]);
}

// --- 13. Every reported cell names the link and the cause that reached it --
// The board is only half the mirror.  A reaction the player cannot SEE
// unfold is, on screen, indistinguishable from the board simply being
// different — so what each cell is reported AS matters as much as what it
// became.  `depth` is the link, `source` is what did it.
{
  // A cast lands on a neutralizer, whose block covers a bomb, whose blast
  // levels its own 3x3.  Three distinct causes, three distinct links, all
  // resolved inside one call.
  //
  //   . . . . .        the cast hits (1,1); the block covers (2,2);
  //   . N . . .        the blast is centred there.
  //   . . B . .
  //   . . . r .
  //   . . . . .
  const ctx = build({
    activateOn: { special_neutralizer: "cast", special_bomb: "cast" },
    blastChains: true,
  });
  const board = blank(25);
  board[6] = N; board[12] = B; board[18] = RED;
  const log = [];
  ctx.stampOn(board, DOT, 1, 1, 5, 5, ctx.shapeOutcome(), 0,
    (ev) => log.push(ev));

  const at = (flat) => log.find((e) => e.flat === flat);

  // The neutralizer spends ITSELF at the cast's own depth: it is the thing
  // the player hit, not something a later link reached.
  eq([at(6).depth, at(6).source, at(6).to], [0, "block", "empty"],
    "the struck neutralizer is reported at the cast's own link");

  // The bomb was reached by the BLOCK, one link out...
  ok(at(12).depth === 1, "the bomb is reached one link out", at(12));
  // ...but is reported as a blast, because a bomb spending itself IS the
  // blast starting, not the block finishing.
  ok(at(12).source === "blast", "a bomb spending itself is already the blast",
    at(12));

  // ...and what the blast took is one link further still.
  eq([at(18).depth, at(18).source, at(18).to], [2, "blast", "empty"],
    "the blast's victims are one link past the bomb");

  // The whole board is levelled either way; the point is that the three
  // cells are staged as three separate moments.
  ok(board[6] === E && board[12] === E && board[18] === E,
    "the chain still levels everything it reached", board);
}

// --- 14. Depth is not callback ORDER --------------------------------------
// stampOn recurses depth-first in the middle of walking its offsets, so the
// callbacks arrive interleaved: a cell at the cast's own depth can be
// reported AFTER cells three links deep.  Anything that paced the effect by
// arrival order would draw the chain inside out, which is why `depth` exists
// at all.
{
  //   N r .      the 3x3 cast covers everything.  Its FIRST offset lands on
  //   . . .      the neutralizer at (0,0), whose block immediately reports
  //   . . r      (0,1) one link out — before the cast has even reached the
  //              slime at (2,2), which is its own depth-0 work.
  const ctx = build({ activateOn: { special_neutralizer: "cast" } });
  const board = blank(9);
  board[0] = N; board[1] = RED; board[8] = RED;
  const log = [];
  ctx.stampOn(board, SQ3, 1, 1, 3, 3, ctx.shapeOutcome(), 0,
    (ev) => log.push(ev));

  const depths = log.map((e) => e.depth);
  ok(depths.some((d, i) => i > 0 && d < depths[i - 1]),
    "depths arrive OUT of order — the walk is depth-first", depths);
  // The last cell the cast itself touches is still its own first link,
  // reported long after the block's deeper ones.
  const last = log[log.length - 1];
  eq([last.flat, last.depth, last.source], [8, 0, "cast"],
    "a depth-0 cell can be reported last of all");
}

// --- 15. A cell is HELD at its old look until its link is due --------------
// The staging is the feature.  A cell reached at link N must keep its
// pre-chain appearance for N waves and change exactly once, no matter how
// many links passed through it.
{
  const ctx = build();
  const R = 5, C = 5;

  ctx.cellAnim.clear();
  // Link 0 — the player's own cast.  Never held: this is the common case,
  // and making an ordinary cast wait would be a regression dressed as a
  // feature.
  ctx.scheduleChainFx(
    { flat: 0, from: RED, to: "yellow", depth: 0, source: "cast" }, R, C);
  ok(ctx.cellAnim.get(0).kind === "flash",
    "a depth-0 downgrade changes at once", ctx.cellAnim.get(0));

  // Link 2 — held for two waves, THEN revealed.
  ctx.scheduleChainFx(
    { flat: 1, from: N, to: "empty", depth: 2, source: "blast" }, R, C);
  const held = ctx.cellAnim.get(1);
  eq([held.kind, held.from, held.t], ["hold", N, 2 * ctx.WAVE_S],
    "a depth-2 cell is held at its old look for two waves");
  ok(held.then?.kind === "pop",
    "a cell the reaction ERASED bursts when its turn comes", held.then);

  // The hold hands over rather than expiring into nothing.
  ctx.tickGridAnims(2 * ctx.WAVE_S + 0.001);
  ok(ctx.cellAnim.get(1)?.kind === "pop",
    "the hold hands over to its reveal", ctx.cellAnim.get(1));
}

// --- 16. A cell two links touch changes ONCE, at the later one ------------
// A block steps a unit down, then a blast behind it takes the same cell.
// Showing the intermediate tier would claim a step that never had a moment
// on screen; changing early would put the cell ahead of its own chain.
{
  const ctx = build();
  ctx.cellAnim.clear();
  ctx.scheduleChainFx(
    { flat: 3, from: N, to: RED, depth: 1, source: "block" }, 5, 5);
  ctx.scheduleChainFx(
    { flat: 3, from: RED, to: "empty", depth: 3, source: "blast" }, 5, 5);

  const a = ctx.cellAnim.get(3);
  eq([a.kind, a.from, a.t], ["hold", N, 3 * ctx.WAVE_S],
    "the cell keeps its FIRST look and the LAST moment");
  ok(a.then?.kind === "pop", "and settles on what the last link did", a.then);
}

// --- 17. Only cells still WAITING hold the collapse ------------------------
// The eat cinematic must wait for the last link to arrive — the collapse
// packs survivors left and would move the cells a pending wave is holding.
// Sparks already FLYING are loose in screen space with no cell to be wrong
// about, so they must NOT stall the clock for as long as they happen to burn.
{
  const ctx = build();
  ctx.cellAnim.clear();
  ctx.chainParticles.length = 0;
  ok(!ctx.chainRevealsPending(), "nothing pending on a quiet board");

  ctx.scheduleChainFx(
    { flat: 4, from: RED, to: "empty", depth: 2, source: "blast" }, 5, 5);
  ok(ctx.chainRevealsPending(), "a link still owed holds the collapse");

  // Past the last wave: the cell has revealed, so the collapse is free —
  // even though the spark it threw is still very much alive.
  ctx.tickGridAnims(2 * ctx.WAVE_S + 0.01);
  ok(ctx.chainParticles.some((p) => p.delay <= 0 && p.age < p.life)
     || ctx.chainParticles.length > 0,
    "the spark outlives the wave that spawned it");
  ok(!ctx.chainRevealsPending(),
    "once the last link has fired the collapse is free to run, sparks or no");

  // A depth-0 cell never holds the collapse at all.
  ctx.cellAnim.clear();
  ctx.scheduleChainFx(
    { flat: 5, from: RED, to: "yellow", depth: 0, source: "cast" }, 5, 5);
  ok(!ctx.chainRevealsPending(), "an ordinary cast never stalls the meal");
}

// --- 17b. Waves are capped independently of the balance knob --------------
// max_chain_depth is the server's to raise.  If it set animation length, a
// tuning change could stretch the eat stage past the bite interval and every
// meal would end by being cut short.
{
  const ctx = build();
  ctx.cellAnim.clear();
  ctx.scheduleChainFx(
    { flat: 6, from: RED, to: "empty", depth: 40, source: "blast" }, 5, 5);
  eq(ctx.cellAnim.get(6).t, 4 * ctx.WAVE_S,
    "an absurdly deep link is still staged within the wave ceiling");
}

// --- 17c. A depth-0 link cannot jump a queue it is already in -------------
// The walk recurses mid-offset, so a block fired by the first cell a cast
// covers reports BEFORE the cast reaches its own later cells.  If one of
// those is a cell the block already holds, the cast's link must change what
// the cell wakes up as — not wake it early.
{
  const ctx = build();
  ctx.cellAnim.clear();
  ctx.scheduleChainFx(
    { flat: 7, from: N, to: RED, depth: 2, source: "block" }, 5, 5);
  ctx.scheduleChainFx(
    { flat: 7, from: RED, to: "empty", depth: 0, source: "cast" }, 5, 5);

  const a = ctx.cellAnim.get(7);
  eq([a.kind, a.from, a.t], ["hold", N, 2 * ctx.WAVE_S],
    "the later depth-0 link does NOT release the hold");
  ok(a.then?.kind === "pop",
    "but it does decide what the cell wakes up as", a.then);
}

// --- 18. A deep chain cannot flood the particle buffer --------------------
{
  const ctx = build();
  ctx.chainParticles.length = 0;
  for (let i = 0; i < 5000; i++) {
    ctx.scheduleChainFx(
      { flat: i % 25, from: RED, to: "empty", depth: 1, source: "blast" }, 5, 5);
  }
  ok(ctx.chainParticles.length <= 700,
    "the spark buffer is capped", ctx.chainParticles.length);
}

if (failures > 0) { console.error(`\n${failures} failure(s)`); process.exit(1); }
console.log("chain_harness: all mirror checks passed");
