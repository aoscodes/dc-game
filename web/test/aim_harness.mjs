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

// ...and the content-derived overlays still are gated on `replay`.
ok(/const pv = replay \|\| playSuspended\(\)/.test(field), "preview tints stay replay-gated");
// Every set the hatch reads must be EMPTY during the replay -- if a new
// reachability set is added and left out of this stub, the draw either
// throws or starts telling the truth about a board that is not on screen.
const stub = field.match(/const reach = replay\s*\n\s*\? \{([^}]*)\}/);
ok(stub !== null, "nibble hatching stays replay-gated");
for (const set of ["eaten", "nibbled", "gnawed"])
  ok(new RegExp(`${set}: new Set\\(\\)`).test(stub[1]),
    `replay stub must blank reach.${set}`);

console.log("AIM OVERLAY OK");
