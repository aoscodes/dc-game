import { readFileSync } from "node:fs";
// Resolved from THIS file, not the cwd: the harness is run by
// `zig build web-test` from the repo root and by hand from anywhere.
const src = readFileSync(
  new URL("../game.js", import.meta.url), "utf8");

function extract(name) {
  const start = src.indexOf(`function ${name}(`);
  if (start < 0) throw new Error(`missing ${name}`);
  let i = src.indexOf("{", start), depth = 0;
  for (; i < src.length; i++) { if (src[i] === "{") depth++; else if (src[i] === "}" && --depth === 0) break; }
  return src.slice(start, i + 1);
}

// Recording canvas stub: every draw call becomes a comparable string.
const mk = () => {
  const calls = [];
  const ctx = new Proxy({}, {
    get(_, k) {
      if (k === "save" || k === "restore" || k === "beginPath" || k === "fill") {
        return () => calls.push(String(k));
      }
      if (k === "strokeRect" || k === "arc") {
        return (...a) => calls.push(`${String(k)}(${a.join(",")})`);
      }
      return undefined;
    },
    set(_, k, v) { calls.push(`${String(k)}=${v}`); return true; },
  });
  return { ctx, calls };
};

function run(fn, game, g, cols) {
  const { ctx, calls } = mk();
  new Function("ctx", "FIELD", "playerColor", "TEAM_WINDOW_MS", "game", "g", "cols", `
    ${extract("drawCursorBox")}
    ${extract(fn)}
    ${fn}(game, g, cols);
  `)(ctx,
    { cursorWidth: 3, cursorMateWidth: 2, pendingDotFrac: 0.09, pendingDotGap: 0.06 },
    (id) => `c${id}`, 3000, game, g, cols);
  return calls;
}

const g = { x0: 100, y0: 50, cell: 40 };
const cols = 8;
const game = {
  player_id: 1,
  entities: [
    { owner: 1, cursor_row: 2, cursor_col: 5 },
    { owner: 2, cursor_row: 0, cursor_col: 0 },
  ],
  recent: [{ square: 19, player_id: 2, age_ms: 500 }],
};

const ok = (c, m, x) => { if (!c) { console.error("FAIL:", m, x ?? ""); process.exit(1); } };

// The whole point: these must not vary with the board. Same game frame, and
// there is no board argument to vary -- prove it structurally AND behaviourally.
for (const fn of ["drawCursors", "drawPendingMarks"]) {
  const body = extract(fn);
  ok(!/\bgrid\b|cinematicBoard|\.board\b/.test(body),
    `${fn} must not read any board`, body.match(/\bgrid\b|cinematicBoard|\.board\b/));
  const a = run(fn, game, g, cols);
  const b = run(fn, game, g, cols);
  ok(a.length > 0, `${fn} drew nothing`);
  ok(JSON.stringify(a) === JSON.stringify(b), `${fn} not deterministic`);
}

// The crosshair lands on the cursor's coordinate, at full width for the owner.
const cur = run("drawCursors", game, g, cols);
const own = `strokeRect(${100 + 5 * 40 + 1.5},${50 + 2 * 40 + 1.5},${40 - 3},${40 - 3})`;
ok(cur.includes(own), "own crosshair must sit on (row 2, col 5) at cursorWidth", cur);
const mate = `strokeRect(${100 + 0 + 1},${50 + 0 + 1},${40 - 2},${40 - 2})`;
ok(cur.includes(mate), "teammate crosshair must sit on (0,0) at cursorMateWidth", cur);
ok(cur.indexOf(own) > cur.indexOf(mate), "own cursor draws last, on top");

// The pip sits on its cast's square, from `recent` alone.
const pips = run("drawPendingMarks", game, g, cols);
ok(pips.some((c) => c.startsWith("arc(")), "pending pip must be drawn", pips);

// The three restored gates key off playSuspended (outro), never `replay`.
const field = src.slice(src.indexOf("function drawSlimeField("));
for (const [re, what] of [
  [/if \(!playSuspended\(\)\) \{\s*\n\s*for \(const e of game\.entities/, "cursorCells gate"],
  [/const biteCols = feastWidth\(game, cols\);/, "bite strip gate"],
  [/if \(!playSuspended\(\)\) \{\s*\n\s*drawPendingMarks/, "cursor+pip gate"],
]) ok(re.test(field), `${what} must be gated on playSuspended, not replay`);

// ...and the content-derived overlays still are gated on `replay`, while the
// FOOTPRINT is not: mid-replay the gate must ask castFootprint for owners and
// hand back empty cells.  Both halves are asserted, because a gate that
// blanked everything (the old behaviour) satisfies the tint half alone.
ok(/const pv = playSuspended\(\)/.test(field), "outro still blanks the whole preview");
const midReplay = field.match(/: replay\s*\n\s*\? \{ cells: new Map\(\), owners: ([^}]*)\}/);
ok(midReplay !== null, "mid-replay branch must build owners from a footprint");
ok(/castFootprint\(game\)/.test(midReplay[1]),
  "mid-replay owners must come from castFootprint", midReplay[1]);
// Every set the hatch reads must be EMPTY during the replay -- if a new
// reachability set is added and left out of this stub, the draw either
// throws or starts telling the truth about a board that is not on screen.
const stub = field.match(/const reach = replay\s*\n\s*\? \{([^}]*)\}/);
ok(stub !== null, "nibble hatching stays replay-gated");
for (const set of ["eaten", "nibbled", "gnawed"])
  ok(new RegExp(`${set}: new Set\\(\\)`).test(stub[1]),
    `replay stub must blank reach.${set}`);

// ---------------------------------------------------------------------------
// castFootprint: the half of shapePreview that survives a feast replay.
// ---------------------------------------------------------------------------

// Structural: a footprint is (offsets + anchor + dimensions) and nothing else.
// If it ever learns to read a cell it stops being safe to draw over a replay
// board, and the gate above becomes a lie.
const fp = extract("castFootprint");
ok(!/\bgrid\b|cinematicBoard|\.board\b|work\[/.test(fp),
  "castFootprint must not read any board", fp.match(/\bgrid\b|cinematicBoard|\.board\b/));

// Behavioural: same aim, two utterly different boards, identical footprint.
// The structural check alone would pass a function that read the board
// through a helper.
function footprint(frame) {
  return new Function("game", "PLAYER_RECIPES", "TEAM_RECIPES", `
    ${extract("gridDims")}
    ${extract("addOutput")}
    ${extract("projectedCasts")}
    ${extract("projectBatch")}
    ${extract("castFootprint")}
    return castFootprint(game);
  `)(frame,
    [{ label: "poke", offsets: [{ dRow: 0, dCol: 0 }, { dRow: 1, dCol: 0 }], cost: 1 }],
    []);
}

const aim = {
  player_id: 1,
  grid_rows: 4, grid_cols: 4,
  entities: [
    { owner: 1, cursor_row: 1, cursor_col: 2, selected_shape: 0 },
    { owner: 2, cursor_row: 1, cursor_col: 2, selected_shape: 0 },
  ],
  recent: [],
};
const emptyBoard = { ...aim, grid: Array(16).fill("empty") };
const fullBoard = { ...aim, grid: Array(16).fill("tiered_red") };

const fpEmpty = footprint(emptyBoard);
const fpFull = footprint(fullBoard);
const asList = (m) => [...m.entries()].sort((a, b) => a[0] - b[0])
  .map(([k, v]) => `${k}:${v.owner}:${v.pending}`).join("|");

ok(fpEmpty.size > 0, "footprint drew nothing");
ok(asList(fpEmpty) === asList(fpFull),
  "footprint must not vary with the board", [asList(fpEmpty), asList(fpFull)]);

// The shape lands where it is aimed: anchor (1,2) on a 4-wide grid is flat 6,
// and the poke's second offset is the cell below it, flat 10.
ok(fpEmpty.has(6) && fpEmpty.has(10),
  "footprint must cover the anchor and its offset", [...fpEmpty.keys()]);
ok(fpEmpty.size === 2, "footprint must cover ONLY the shape", [...fpEmpty.keys()]);

// The viewer's own aim wins an overlap -- both players aim at the same square
// here, and player 1 is the viewer.
ok(fpEmpty.get(6).owner === 1, "viewer's own stamp must win an overlap", fpEmpty.get(6));

// Negative control for the board-independence check: a footprint that DID
// consult the board would differ between these two frames, so prove the two
// frames are actually distinguishable.
ok(JSON.stringify(emptyBoard.grid) !== JSON.stringify(fullBoard.grid),
  "the two control boards must actually differ");

// Negative control for the coverage check: an aim somewhere else must produce
// a different footprint, or `has(6) && has(10)` would pass on anything.
const moved = footprint({ ...emptyBoard,
  entities: [{ owner: 1, cursor_row: 0, cursor_col: 0, selected_shape: 0 }] });
ok(!moved.has(6), "moving the aim must move the footprint", [...moved.keys()]);

console.log("AIM OVERLAY OK");
