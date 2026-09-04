// The grid diff's CLASSIFICATION of a board change, and the one rule that
// governs every tile that moves.
//
// Unlike its neighbours this harness mirrors no Zig: `updateGridAnims` decides
// how a change LOOKS, and the server has no opinion about that.  What it does
// have is a shape — the field only ever packs left (slime.shift_left) and
// pours in from the right (slime.fill) — and the client is free to contradict
// it, which is exactly what went wrong.
//
// Two bugs are pinned here.
//
//   1. A cell can be stepped down the tier ladder MORE THAN ONCE in a single
//      server tick: a cast covering a cast-armed neutralizer fires a 3x3
//      centred inside its own footprint, so every cell in the overlap is
//      downgraded twice.  The diff sees only the endpoints of the tick, and
//      asking for a single rung called `red -> green` a replacement.
//      Replacements travel, so a defused slime appeared to arrive from
//      somewhere else instead of changing where it stood.
//
//   2. The record that tells the diff which cells a reaction reached was a
//      module-level Map, written by two producers and cleared by the consumer.
//      One producer sat below the consumer, so every cell it noted was
//      discarded unread.  Silent, which is why it lasted.
//
// And one invariant, which is the point of the whole exercise: NOTHING FALLS.
// A `drop` animation kind is a rule the game does not have.
import { readFileSync } from "node:fs";

// Resolved from THIS file, not the cwd: run by `zig build web-test` from the
// repo root and by hand from anywhere.
const src = readFileSync(new URL("../game.js", import.meta.url), "utf8");

let failures = 0;
function ok(cond, what, got) {
  if (cond) return;
  failures++;
  console.log(`FAIL: ${what}${got === undefined ? "" : ` (got ${JSON.stringify(got)})`}`);
}
function eq(a, b, what) {
  ok(a === b, what, a);
}

function extract(name) {
  const start = src.indexOf(`function ${name}(`);
  if (start < 0) throw new Error(`missing function ${name}`);
  let i = src.indexOf("{", start), depth = 0;
  for (; i < src.length; i++) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}" && --depth === 0) break;
  }
  return src.slice(start, i + 1);
}
function extractConst(name) {
  const start = src.indexOf(`const ${name} = [`);
  if (start < 0) throw new Error(`missing const ${name}`);
  const end = src.indexOf("];", start);
  return src.slice(start, end + 2);
}
/** A one-line `const NAME = <literal>;`, lifted rather than restated so the
 *  harness cannot drift from the value it is asserting about. */
function extractScalar(name) {
  const m = new RegExp(`^const ${name} = [^;\\n]+;$`, "m").exec(src);
  if (m === null) throw new Error(`missing scalar const ${name}`);
  return m[0];
}

const COLLAPSE_S = 0.4;

/** The real diff and the real walks, over a stubbed screen. */
function build({ activateOn = {}, maxDepth = 3, blastChains = false } = {}) {
  return new Function(`
    const TIER_NAMES = ["red", "yellow", "green"];
    const TIER_CHAR = { red: "\u2261", yellow: "=", green: "-" };
    const BOMB_ROCKS_ONLY = false;
    const ROCK_BITE_COSTS_HUNGER = false;
    const SPECIAL_ACTIVATE_ON = ${JSON.stringify(activateOn)};
    const MAX_CHAIN_DEPTH = ${maxDepth};
    const BLAST_CHAINS = ${blastChains};
    const FIELD = { popS: 0.22, flashS: 0.25 };
    const LAYOUT = {
      cinematic: { collapseS: ${COLLAPSE_S}, matchBeatS: 0.4 },
      floater: { stack: 0 },
      chainFx: {
        waveS: 0.3, maxWaves: 4, lifeS: 0.45, count: 1, speed: 0,
        speedJitter: 0, gravity: 0, size: 1, sizeJitter: 0, max: 700,
      },
    };
    const SPECIAL_COLOR = "violet", BOMB_COLOR = "orange";
    const NEUTRAL_COLOR = "grey", EGG_COLOR = "cream", ROCK_COLOR = "slate";
    const CANISTER_COLOR = "teal";
    const TILE_RGB = {};
    const chainParticles = [];
    const cellAnim = new Map();
    const cellCenter = () => ({ x: 0, y: 0 });
    const parseRgb = () => [0, 0, 0];
    const spawnFloater = () => {};

    // The console the seal reports through.  Captured, not silenced: the
    // guard firing IS the assertion.
    const sealErrors = [];
    const console = { error: (...a) => sealErrors.push(a.join(" ")) };

    ${extractConst("AGENT_BLOCK_OFFSETS")}
    ${extract("activatesOnCast")}
    ${extract("activatesOnEat")}
    ${extract("downgradeName")}
    ${extractScalar("LADDER_RUNGS")}
    ${extract("downgradeSteps")}
    ${extract("hazardTier")}
    ${extract("cellStyle")}
    ${extract("cellIsSlime")}
    ${extract("cellIsEdible")}
    ${extract("agentBlockCells")}
    ${extract("detonateOn")}
    ${extract("shapeOutcome")}
    ${extract("stampOn")}
    ${extract("activateOn")}
    ${extract("makeCastRecord")}
    ${extract("matchBlockCells")}
    ${extract("recordMatchBlocks")}
    ${extract("spawnChainBurst")}
    ${extract("scheduleChainFx")}
    ${extract("tickGridAnims")}
    ${extract("animProgress")}

    // prevGrid is module state in game.js and the diff reassigns it, so it has
    // to be a live binding here too rather than a parameter.
    let prevGrid = [];
    ${extract("updateGridAnims")}

    return {
      cellAnim, sealErrors, makeCastRecord, downgradeSteps, downgradeName,
      stampOn, shapeOutcome, updateGridAnims, cellStyle, tickGridAnims,
      setPrev: (g) => { prevGrid = g.slice(); },
      getPrev: () => prevGrid,
    };
  `)();
}

// ---------------------------------------------------------------------------
// The ladder, in isolation
// ---------------------------------------------------------------------------
{
  const c = build();
  const S = c.downgradeSteps;
  eq(S("red", "yellow"), 1, "one rung: red -> yellow");
  eq(S("red", "green"), 2, "TWO rungs: red -> green (the cast + its block)");
  eq(S("red", "defused"), 3, "three rungs: red -> defused");
  eq(S("special_rock", "red"), 1, "the break alone");
  eq(S("special_rock", "defused"), 4, "the break plus the whole ladder");
  eq(S("yellow", "defused"), 2, "yellow -> defused");

  // Not below it on the ladder: a genuine replacement, and replacements travel.
  eq(S("green", "red"), null, "UP the ladder is not a downgrade");
  eq(S("red", "red"), null, "no change is not a downgrade");
  eq(S("neutral", "defused"), null, "neutral is not on the ladder");
  eq(S("defused", "neutral"), null, "defused is the bottom");
  eq(S("empty", "red"), null, "an empty cell being filled is an arrival");
  eq(S("special_egg", "red"), null, "only the rock breaks into slime");
  eq(S("red", "special_egg"), null, "a hazard never becomes a special");
}

// ---------------------------------------------------------------------------
// The bug as the player met it: a cast that covers a neutralizer
// ---------------------------------------------------------------------------
//
// 5x5 board of red slime with a neutralizer at the centre.  A 3x3 cast lands
// on that centre: the outer stamp downgrades, the neutralizer it uncovers
// fires its own 3x3 over the SAME cells, and the overlap ends two rungs down.
//
// The contract asserted is the player-visible one, not an implementation
// detail: a cast makes nothing travel.  Everything it touched either blooms
// where it stands or bursts.
{
  // Keyed by CELL name, as config.js builds it: `special_${kind}`.
  const c = build({ activateOn: { special_neutralizer: "cast" } });
  const rows = 5, cols = 5;
  const before = Array(rows * cols).fill("red");
  const centre = 2 * cols + 2;
  before[centre] = "special_neutralizer";

  const after = before.slice();
  const record = c.makeCastRecord();
  const CAST = [];
  for (let dr = -1; dr <= 1; dr++) {
    for (let dc = -1; dc <= 1; dc++) CAST.push({ dRow: dr, dCol: dc });
  }
  // Exactly what recordCastChain does: run the mirror over the pre-cast board
  // and note the link each cell was reached on.
  c.stampOn(after, CAST, 2, 2, rows, cols, c.shapeOutcome(), 0,
    ({ flat, depth, source }) => record.note(flat, depth, source));

  // The scenario is only worth anything if the double step actually happened.
  const twoRungs = after.filter((now, i) => c.downgradeSteps(before[i], now) === 2);
  ok(twoRungs.length > 0, "scenario builds a two-rung downgrade", twoRungs.length);
  eq(after[centre], "empty", "the neutralizer spent itself");

  c.cellAnim.clear();
  c.setPrev(before);
  c.updateGridAnims(record, { special_matches: [] }, after, rows, cols);

  const kinds = [...c.cellAnim.values()].map((a) => a.kind);
  ok(kinds.length > 0, "the diff queued something", kinds.length);
  const travelled = [...c.cellAnim.entries()].filter(([, a]) => a.kind === "slide");
  eq(travelled.length, 0,
    `a cast makes NOTHING travel (${travelled.map(([f, a]) => `${f}:${a.kind}`).join()})`);
  ok(kinds.every((k) => k === "flash" || k === "hold" || k === "pop"),
    "every cell a cast reached blooms, holds or bursts", kinds);

  // And specifically: the two-rung cells are among them, not written off.
  for (let flat = 0; flat < before.length; flat++) {
    if (c.downgradeSteps(before[flat], after[flat]) !== 2) continue;
    const a = c.cellAnim.get(flat);
    ok(a !== undefined && a.kind !== "slide",
      `two-rung cell ${flat} changed in place`, a?.kind);
  }
}

// ---------------------------------------------------------------------------
// A real replacement still travels, and travels from the RIGHT
// ---------------------------------------------------------------------------
{
  const c = build();
  const rows = 1, cols = 4;
  const before = ["red", "empty", "neutral", "green"];
  const after = ["red", "yellow", "neutral", "green"];

  c.cellAnim.clear();
  c.setPrev(before);
  // No record: nothing claims to have caused this, so it is an arrival.
  c.updateGridAnims(c.makeCastRecord(), { special_matches: [] }, after, rows, cols);

  const a = c.cellAnim.get(1);
  eq(a?.kind, "slide", "an unattributed arrival travels");
  eq(a?.dur, COLLAPSE_S, "and does it at the ONE conveyor speed");
  eq(c.cellAnim.size, 1, "unchanged cells queue nothing");
}

// A change with a record but off the ladder is still an arrival: the diff, not
// the local mirror, is the authority on what happened.
{
  const c = build();
  const rows = 1, cols = 2;
  const record = c.makeCastRecord();
  record.note(0, 0, "cast");
  c.cellAnim.clear();
  c.setPrev(["green", "neutral"]);
  c.updateGridAnims(record, { special_matches: [] }, ["red", "neutral"], rows, cols);
  eq(c.cellAnim.get(0)?.kind, "slide",
    "a recorded cell that went UP the ladder is a replacement, not a downgrade");
}

// ---------------------------------------------------------------------------
// NOTHING FALLS
// ---------------------------------------------------------------------------
{
  // The kind is gone from the source, not merely unqueued: no queue site, no
  // draw branch, no duration knob.
  ok(!/kind:\s*"drop"/.test(src), "no animation queues a `drop`");
  ok(!/anim\?\.kind === "drop"/.test(src), "no draw branch honours a `drop`");
  ok(!/\bdropS\b/.test(src), "the fall duration knob is gone");

  // drawTile took a vertical offset that, after this, no caller passed. A
  // parameter nothing uses is how the fall came back the first time.
  const sig = src.slice(src.indexOf("function drawTile("));
  const params = sig.slice(sig.indexOf("(") + 1, sig.indexOf(")"));
  ok(!/\bdy\b/.test(params), "drawTile takes no vertical offset", params);

  // Every CALL site agrees with the six-parameter signature (the definition,
  // asserted above, is not one of them).
  const calls = [...src.matchAll(/(?<!function )drawTile\(([^;]*?)\);/g)]
    .map((m) => m[1]);
  // Both live on the field (the swap tween and the tile draw); the third was
  // the pre-match guide's mini-board demo, gone with that screen.  The floor
  // is here so a regex that matched NOTHING cannot pass the loop vacuously.
  ok(calls.length >= 2, "found the drawTile call sites", calls.length);
  for (const args of calls) {
    // Top-level commas only: an argument may itself contain a call.
    let depth = 0, n = 1;
    for (const ch of args) {
      if (ch === "(") depth++;
      else if (ch === ")") depth--;
      else if (ch === "," && depth === 0) n++;
    }
    ok(n === 6 || n === 7, "drawTile called with 6 or 7 arguments", args.trim());
  }
}

// ---------------------------------------------------------------------------
// The record's lifecycle: no ordering can lose a write
// ---------------------------------------------------------------------------
{
  const c = build();

  // Deepest link wins: a cell settles when the LAST thing to touch it is done.
  const r = c.makeCastRecord();
  r.note(7, 0, "cast");
  r.note(7, 2, "block");
  r.note(7, 1, "blast");
  eq(r.get(7)?.depth, 2, "the deepest link is kept");
  eq(r.get(7)?.source, "block", "and its cause with it");

  // consume() empties: a second read cannot re-animate a settled cell.
  eq(r.consume().size, 1, "consume hands over the generation");
  eq(r.consume().size, 0, "and leaves nothing behind");

  // The guard that replaces the silent loss.
  eq(c.sealErrors.length, 0, "nothing has tripped the seal yet");
  r.note(7, 0, "cast");
  eq(c.sealErrors.length, 1, "a write after the read is REPORTED, not swallowed");
  ok(/after the diff/.test(c.sealErrors[0]), "and says what went wrong", c.sealErrors[0]);
  ok(r.get(7) !== undefined,
    "and is still recorded — degrade to the old behaviour, never worse");

  // open() is the frame boundary.
  r.open();
  r.note(8, 0, "cast");
  eq(c.sealErrors.length, 1, "a new frame writes freely again");

  // discard() spends it unread, and does NOT seal: startFeastCinematic throws
  // the record away and the next frame must still be able to record a cast.
  r.discard();
  eq(r.get(8), undefined, "discard empties");
  r.note(9, 0, "cast");
  eq(c.sealErrors.length, 1, "discard is not a read, so it seals nothing");
}

// open() KEEPS unread notes, and says how many it is carrying.
//
// Load-bearing, and the non-obvious direction: a cast landing while the feast
// replay owns the board is deliberately noted for the diff that runs when the
// replay LANDS — many frames later, since a replay is several passes of a few
// tenths of a second each (see recordCastChain). An open() that cleared would
// silently swallow that cast's bloom, which is invisible on screen: the cell
// just changes with no reaction on it. So the carry is the feature, and the
// count is how the renderer tells a legitimate carry from a leak.
{
  const c = build();
  const r = c.makeCastRecord();

  eq(r.carried(), 0, "a fresh record carries nothing");

  r.note(4, 1, "blast");
  r.note(5, 0, "cast");
  // Not counted until a frame boundary: these are THIS frame's notes, and this
  // frame's own diff is still entitled to read them.
  eq(r.carried(), 0, "notes made this frame are not a carry");

  r.open();
  eq(r.carried(), 2, "open() reports the notes no diff read");
  ok(r.get(4) !== undefined && r.get(5) !== undefined,
    "and KEEPS them — a mid-replay cast blooms when the replay lands");

  // A consumed generation leaves nothing to carry, which is the healthy path.
  r.consume();
  r.open();
  eq(r.carried(), 0, "a consumed generation carries nothing forward");

  // discard() is the replay taking over, and resets the count with the cells:
  // reporting a carry the very next frame would cry wolf on every settle.
  r.note(6, 0, "cast");
  r.open();
  eq(r.carried(), 1, "an unread note is carried");
  r.discard();
  eq(r.carried(), 0, "discard clears the carry with the cells");
}

// A match's cells are recorded by the diff ITSELF, so no caller can order the
// two wrongly. This is the bug: the producer used to run after the consumer.
{
  const c = build();
  const rows = 5, cols = 5;
  const before = Array(rows * cols).fill("red");
  const after = before.map((n, i) =>
    // The 5x5 neutralize_block around the centre of a 5x5 board is the board.
    c.downgradeName(n) ?? n);
  const centre = 2 * cols + 2;

  c.cellAnim.clear();
  c.setPrev(before);
  // Nothing is recorded by hand: the only producer is the one updateGridAnims
  // calls for itself.
  c.updateGridAnims(c.makeCastRecord(),
    { special_matches: [{ center: centre, kind: "neutralizer", cells: [] }] },
    after, rows, cols);

  const kinds = [...c.cellAnim.values()].map((a) => a.kind);
  eq(kinds.length, rows * cols, "every cell the block covered was classified");
  ok(kinds.every((k) => k === "flash"),
    "a resolved match blooms in place — no link behind it, so no hold", kinds);
  // The guard's own report, checked directly: invert the producer and the
  // consumer inside updateGridAnims and this is what says so.
  eq(c.sealErrors.length, 0, "the diff writes its record before reading it");
}

// Without the match producer there is no record, and the same board reads as an
// arrival: proof the assertion above is testing the producer and not the ladder.
{
  const c = build();
  const rows = 5, cols = 5;
  const before = Array(rows * cols).fill("red");
  const after = before.map(() => "yellow");
  c.cellAnim.clear();
  c.setPrev(before);
  c.updateGridAnims(c.makeCastRecord(), { special_matches: [] }, after, rows, cols);
  ok([...c.cellAnim.values()].every((a) => a.kind === "slide"),
    "an unrecorded downgrade is an arrival, which is what makes the record load-bearing");
}

// ---------------------------------------------------------------------------
// First frame, and the baseline
// ---------------------------------------------------------------------------
{
  const c = build();
  c.cellAnim.clear();
  c.setPrev([]);
  const board = ["red", "green"];
  c.updateGridAnims(c.makeCastRecord(), { special_matches: [] }, board, 1, 2);
  eq(c.cellAnim.size, 0, "the first frame is adopted silently, never animated");
  ok(c.getPrev() !== board, "the baseline is a COPY, not the frame's own array");
  eq(c.getPrev().join(), board.join(), "and holds what was drawn");
}

// ---------------------------------------------------------------------------
// The defused tile, as it actually renders
// ---------------------------------------------------------------------------
//
// Pinned to keep the doc honest, not because it is right: defused and neutral
// are indistinguishable, and the comment above cellStyle says so. If someone
// implements the ring, this fails and the comment gets updated with it.
{
  const c = build();
  const defused = c.cellStyle("defused");
  const neutral = c.cellStyle("neutral");
  eq(defused.body, neutral.body, "defused still renders as neutral (see cellStyle)");
  eq(defused.ring, false, "the ring is documented as unimplemented");
  ok(!/ring:\s*true/.test(src), "no branch of cellStyle claims a ring");
}

if (failures > 0) {
  console.log(`\n${failures} assertion(s) failed`);
  process.exit(1);
}
console.log("anim_harness: diff classification, one-way travel, record lifecycle OK");
