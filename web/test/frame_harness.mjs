// How the renderer folds the render frames that arrive between two animation
// frames — and the contract that says which fields it must fold.
//
// The bug this pins: frames landed in a single `latestMsg` slot and overwrote
// each other, so a frame buried before requestAnimationFrame next ran took its
// ONE-SHOT events with it. The pops, the flashes and the whole settle replay
// never played. Nothing errored, nothing logged; the board just changed
// instantly, which reads as "sometimes the animations don't happen".
//
// Three things are asserted here.
//
//   1. FOLDING. Additive events from every frame survive, in arrival order;
//      absolute state (the board, the scalars) comes from the newest frame
//      alone. Those are opposite rules and a merge that picks either one for
//      everything is wrong in one direction or the other.
//
//   2. THE BITE IS NOT ADDITIVE. `bite_settled` carries the pass count the
//      replay loops on, and `refills` are keyed by a pass index that every bite
//      numbers from ZERO. Concatenating two bites' passes lets the second
//      bite's pass 0 masquerade as the first's, and the replay walks a cascade
//      that never happened — a worse failure than the dropped frame, because it
//      shows something false instead of nothing. So the newest bite wins whole.
//
//   3. THE CONTRACT, read back out of the Zig writer. The transient fields are
//      declared in `src/client/stdout_writer.zig`, and a new one that nobody
//      adds to FRAME_TRANSIENTS silently falls through to "newest wins" —
//      re-introducing the exact bug, for one field, invisibly. This harness
//      fails when the two drift. That is not hypothetical here: the same file
//      documents `anchor` travelling the whole way to the tab and being dropped
//      by a hand-copied mirror, with every test still passing.
import { readFileSync } from "node:fs";

// Resolved from THIS file, not the cwd: run by `zig build web-test` from the
// repo root and by hand from anywhere.
const src = readFileSync(new URL("../game.js", import.meta.url), "utf8");
const zigSrc = readFileSync(
  new URL("../../src/client/stdout_writer.zig", import.meta.url), "utf8");

let failures = 0;
function ok(cond, what, got) {
  if (cond) return;
  failures++;
  console.log(`FAIL: ${what}${got === undefined ? "" : ` (got ${JSON.stringify(got)})`}`);
}
function eq(a, b, what) {
  ok(a === b, what, a);
}
function eqJson(a, b, what) {
  ok(JSON.stringify(a) === JSON.stringify(b), what, a);
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
/** An object literal `const NAME = { ... };`, lifted rather than restated so
 *  the harness cannot drift from the table it is asserting about. */
function extractObject(name) {
  const start = src.indexOf(`const ${name} = {`);
  if (start < 0) throw new Error(`missing const ${name}`);
  const end = src.indexOf("\n};", start);
  return src.slice(start, end + 3);
}

const { mergeFrames, FRAME_TRANSIENTS } = new Function(`
  ${extractObject("FRAME_TRANSIENTS")}
  ${extract("mergeFrames")}
  return { mergeFrames, FRAME_TRANSIENTS };
`)();

// --- helpers ---------------------------------------------------------------

/** A render frame, with only the fields a test cares about. */
function frame(game) {
  return { tag: "render", phase: "game", game: { grid: [], ...game } };
}

// ---------------------------------------------------------------------------
// 1. The normal path costs nothing
// ---------------------------------------------------------------------------
{
  // One frame per server tick is the steady state — the client emits on the
  // tick's board, not on a timer — and a tick is 50ms against a ~17ms animation
  // frame. So the overwhelmingly common case is a single frame, and it must come
  // through untouched: identity matters downstream, since `drawGame` decides
  // whether a frame's one-shots have already fired by comparing objects.
  const f = frame({ score: 7 });
  eq(mergeFrames([f]), f, "a lone frame is passed through by identity");
}

// ---------------------------------------------------------------------------
// 2. Folding: additive events survive, absolute state does not accumulate
// ---------------------------------------------------------------------------
{
  const a = frame({
    score: 1,
    grid: ["a"],
    shape_casts: [{ id: "c1" }],
    recipes_fired: [{ id: "r1" }],
    special_matches: [{ id: "m1" }],
  });
  const b = frame({
    score: 2,
    grid: ["b"],
    shape_casts: [{ id: "c2" }, { id: "c3" }],
    recipes_fired: [],
    special_matches: [{ id: "m2" }],
  });
  const m = mergeFrames([a, b]);

  // Absolute state: the newest is the truth. A board is not a delta.
  eq(m.game.score, 2, "scalars come from the newest frame");
  eqJson(m.game.grid, ["b"], "the board comes from the newest frame");

  // Additive one-shots: every frame's worth, in arrival order. Order is part of
  // the contract — a cast chain's flashes are sequenced by it.
  eqJson(m.game.shape_casts.map((c) => c.id), ["c1", "c2", "c3"],
    "shape_casts concatenate in arrival order");
  eqJson(m.game.recipes_fired.map((r) => r.id), ["r1"],
    "recipes_fired concatenate across frames");
  eqJson(m.game.special_matches.map((x) => x.id), ["m1", "m2"],
    "special_matches concatenate when no bite is replaying");

  // A merge builds a NEW frame, so the renderer sees it as fresh and fires its
  // one-shots exactly once. Returning a mutated input would make a merged frame
  // indistinguishable from a redraw of an old one.
  ok(m !== a && m !== b, "a merge yields a new frame object");
  ok(m.game !== a.game && m.game !== b.game, "a merge yields a new game object");
  eq(a.game.score, 1, "merging does not mutate its inputs");
}

// ---------------------------------------------------------------------------
// 3. `last`: one fact, newest wins
// ---------------------------------------------------------------------------
{
  const a = frame({ over_budget: { need: 5 }, cast_refused: { reason: "x" } });
  const b = frame({ over_budget: { need: 9 } });
  const m = mergeFrames([a, b]);
  // A refusal describes the viewer's latest cast. Two in the window say the
  // same thing about a newer moment, so the newer one replaces it outright.
  eqJson(m.game.over_budget, { need: 9 }, "over_budget takes the newest");
  // But a field absent from the newest frame is NOT thereby cleared: it was
  // never contradicted, only unmentioned.
  eqJson(m.game.cast_refused, { reason: "x" },
    "cast_refused survives a newer frame that does not mention it");
}

// ---------------------------------------------------------------------------
// 4. The bite is a coupled unit, not an additive event
// ---------------------------------------------------------------------------
{
  // Two bites settling inside one animation frame. Both number their passes
  // from 0, so keeping both refill lists would hand the replay two different
  // "pass 0" fills for one cascade.
  const a = frame({
    bite_settled: { bite: 1, passes: 2 },
    refills: [{ pass: 0, cells: [1] }, { pass: 1, cells: [2] }],
    special_matches: [{ pass: 0, id: "m1" }],
  });
  const b = frame({
    bite_settled: { bite: 2, passes: 1 },
    refills: [{ pass: 0, cells: [9] }],
    special_matches: [{ pass: 0, id: "m2" }],
  });
  const m = mergeFrames([a, b]);

  eq(m.game.bite_settled.bite, 2, "the newest bite wins");
  // WHOLE: the superseded bite's passes go with it. One skipped animation,
  // landing on the same board — the snapshot is the truth either way.
  eqJson(m.game.refills, [{ pass: 0, cells: [9] }],
    "only the winning bite's refills survive");
  eqJson(m.game.special_matches.map((x) => x.id), ["m2"],
    "only the winning bite's matches survive");
  // The pass indices must stay collision-free, which is the whole point.
  const passes = m.game.refills.map((r) => r.pass);
  eq(new Set(passes).size, passes.length, "no two refills claim the same pass");
}
{
  // The bite is not required to be in the NEWEST frame: a tick with no bite can
  // land behind one that had it. The board still comes from the newest, but the
  // replay data must come from the bite's own frame or the passes are lost.
  const a = frame({
    bite_settled: { bite: 4, passes: 1 },
    refills: [{ pass: 0, cells: [3] }],
    special_matches: [{ pass: 0, id: "m1" }],
  });
  const b = frame({ score: 12, grid: ["z"] });
  const m = mergeFrames([a, b]);
  eq(m.game.bite_settled.bite, 4, "a bite in an older frame is not lost");
  eqJson(m.game.refills, [{ pass: 0, cells: [3] }],
    "the bite's refills come from the bite's own frame");
  eqJson(m.game.special_matches.map((x) => x.id), ["m1"],
    "the bite's matches come from the bite's own frame");
  eqJson(m.game.grid, ["z"], "the board still comes from the newest frame");
}
{
  // No bite anywhere: refills describe a cascade nobody is replaying, so
  // carrying them would leave the next replay reading a previous meal's fills.
  const m = mergeFrames([
    frame({ refills: [{ pass: 0 }] }),
    frame({ score: 3 }),
  ]);
  eq(m.game.bite_settled, undefined, "no bite means no bite_settled");
  eqJson(m.game.refills, [], "refills are dropped when no bite is replaying");
}

// ---------------------------------------------------------------------------
// 5. Degenerate frames
// ---------------------------------------------------------------------------
{
  // A boardless frame cannot be merged into meaningfully, and the renderer
  // already handles one (it draws the report without an outro). Passing it
  // through is strictly better than fabricating a `game` from older frames.
  const b = { tag: "render", phase: "game_over" };
  eq(mergeFrames([frame({ score: 1 }), b]), b,
    "a newest frame with no board is passed through");
}

// ---------------------------------------------------------------------------
// 6. The drain is guarded (so an idle animation frame is not a fresh frame)
// ---------------------------------------------------------------------------
{
  // The renderer must redraw every animation frame — animations advance on dt —
  // but must only REPLACE the frame when something actually arrived. An
  // unconditional reassignment would hand `drawGame` a new object every 17ms
  // and every one-shot would fire ~3 times over.
  const loop = extract("gameLoop");
  ok(/if \(inbox\.length > 0\) \{\s*latestMsg = mergeFrames\(inbox\);\s*inbox\.length = 0;\s*\}/.test(loop),
    "gameLoop replaces latestMsg only when the inbox is non-empty");
  ok(/if \(latestMsg\) renderFrame\(latestMsg, dt\);/.test(loop),
    "gameLoop redraws every animation frame, inbox or not");
}

// ---------------------------------------------------------------------------
// 7. The board's frame step is clamped whether or not a replay is running
// ---------------------------------------------------------------------------
{
  // requestAnimationFrame stops firing in a hidden tab, so returning to one
  // delivers a single frame carrying the whole absence. The replay always
  // clamped that; the plain grid animations did not, so a returning tab
  // finished every slide and flash on the frame it started them and the board
  // changed with no animation at all. Same symptom as a dropped frame, entirely
  // different cause, which is how it hid behind the other bug.
  const { boardStep, MAX_STEP_S } = new Function(`
    ${/const LAYOUT = \{[\s\S]*?\n\};/.exec(src)[0]}
    ${extract("boardStep")}
    return { boardStep, MAX_STEP_S: LAYOUT.cinematic.maxStepS };
  `)();

  ok(MAX_STEP_S > 0 && MAX_STEP_S < 1, "the clamp is a sane frame length", MAX_STEP_S);

  // Deliberately no `cinematic` binding in the sandbox above: the clamp must not
  // depend on a replay being in flight, so a boardStep that still consulted one
  // fails HERE, by name, instead of throwing halfway through the suite.
  const step = (dt) => {
    try {
      return boardStep(dt);
    } catch (err) {
      failures++;
      console.log(`FAIL: boardStep must not depend on a replay (${err.message})`);
      return null;
    }
  };

  eq(step(0.008), 0.008, "a normal frame passes through unclamped");
  eq(step(MAX_STEP_S), MAX_STEP_S, "the clamp itself passes through");
  // The case that mattered: four seconds in a background tab.
  eq(step(4), MAX_STEP_S, "a tab's whole absence is clamped to one frame");
}

// ---------------------------------------------------------------------------
// 8. startFeastCinematic's two order-of-operations traps
// ---------------------------------------------------------------------------
{
  // Not behavioural — the function needs half the renderer to run — but both of
  // these ARE pure ordering, and both were got wrong once.
  const fn = extract("startFeastCinematic");
  const at = (needle) => {
    const i = fn.indexOf(needle);
    ok(i >= 0, `startFeastCinematic still contains ${JSON.stringify(needle)}`);
    return i;
  };

  // A replay landing above sets prevGrid to the board it landed on, and the new
  // meal must start from THERE. Reading prevGrid first makes the second bite
  // chew a board the first one already ate.
  ok(at("snapFinishCinematic()") < at("const before = prevGrid"),
    "prevGrid is read after the in-flight replay is landed");

  // When the frame cannot be replayed, the normal grid diff takes over — and
  // the diff is precisely the cast record's consumer. Discarding before the
  // bail left it with nothing to read, so a cast landing on such a frame lost
  // its bloom entirely.
  ok(at("return false") < at("castRecord.discard()"),
    "the unreplayable-frame bail comes before the cast record is discarded");
}

// ---------------------------------------------------------------------------
// 9. The contract, read back out of the Zig writer
// ---------------------------------------------------------------------------
{
  // The renderer reads this JSON and nothing else, and the Json* mirror in the
  // writer is a HAND COPY of the wire structs. A transient field added there
  // and not added to FRAME_TRANSIENTS is silently folded as "newest wins",
  // which drops every older tick's copy — the original bug, one field at a
  // time, with nothing failing.
  const m = /const JsonGame = struct \{\n([\s\S]*?)\n\};/.exec(zigSrc);
  ok(m !== null, "found JsonGame in stdout_writer.zig");

  const declared = [];
  let doc = [];
  for (const line of m[1].split("\n")) {
    const t = line.trim();
    if (t.startsWith("///")) { doc.push(t); continue; }
    const f = /^([a-z_][a-z0-9_]*):/.exec(t);
    // The writer marks every drained-per-frame field "(transient)" in its doc
    // comment, which is the only machine-readable signal of the distinction.
    if (f !== null && doc.join(" ").includes("(transient)")) declared.push(f[1]);
    doc = [];
  }

  // A sanity floor: if the doc convention above ever changes, this parse would
  // quietly find nothing and the check would pass vacuously.
  ok(declared.length >= 8,
    "the writer declares a plausible number of transient fields", declared.length);

  const covered = new Set(Object.keys(FRAME_TRANSIENTS));
  for (const field of declared) {
    ok(covered.has(field),
      `FRAME_TRANSIENTS covers the writer's transient field '${field}'`);
  }
  for (const field of covered) {
    ok(declared.includes(field),
      `FRAME_TRANSIENTS entry '${field}' is still a transient in the writer`);
  }

  // Every rule must be one the merge implements; a typo'd rule silently means
  // "newest wins", which is the failure mode this whole table exists to stop.
  for (const [field, how] of Object.entries(FRAME_TRANSIENTS)) {
    ok(["concat", "last", "bite"].includes(how),
      `FRAME_TRANSIENTS['${field}'] is a known rule`, how);
  }
}

if (failures > 0) {
  console.log(`\nframe_harness: ${failures} failure(s)`);
  process.exit(1);
}
console.log("frame_harness: frame folding, bite coupling, writer contract OK");
