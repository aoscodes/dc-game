// Sanity harness: extract biteFeast + pure deps from web/game.js and assert
// the WALK-ORDER invariants against the mirrored slime.feast -- column-major
// order, and specials firing inline early enough to change what follows them.
// (chain_harness owns the chaining/replay mirror; this one owns the order.)
import { readFileSync } from "node:fs";

// Resolved from THIS file, not the cwd: the harness is run by
// `zig build web-test` from the repo root and by hand from anywhere.
const src = readFileSync(
  new URL("../game.js", import.meta.url), "utf8");

function extract(name) {
  const start = src.indexOf(`function ${name}(`);
  if (start < 0) throw new Error(`missing ${name}`);
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
  return src.slice(start, src.indexOf("];", start) + 2);
}

// Dep list MIRRORS chain_harness's: biteFeast grew a chaining tail (an eaten
// special sets off stampOn/activateOn), so a bite can no longer be extracted
// without them.  This harness owns the BATCHING invariants -- column order,
// one column per batch, where a neutralizer's settle is keyed -- which are
// what chain_harness does not assert.
const names = ["activatesOnCast", "activatesOnEat", "downgradeName", "hazardTier",
  "cellIsEdible", "cellIsSlime", "cellStyle", "agentBlockCells", "detonateOn",
  "shapeOutcome", "stampOn", "activateOn", "biteFeast"];
const code = names.map(extract).join("\n") + "\nreturn biteFeast;";
// downgradeName may reference tier tables; pull likely consts it uses.
// SPECIAL_ACTIVATE_ON is loaded from balance at runtime; empty = every
// special keeps its default "eat" trigger, which is what this harness's
// board assumes.
// Balance-loaded globals, pinned to their defaults: every special keeps its
// "eat" trigger and rocks are free to bite, which is what this board assumes.
const biteFeast = new Function(`
  const TIER_NAMES = ["red", "yellow", "green"];
  const SPECIAL_ACTIVATE_ON = {};
  const ROCK_BITE_COSTS_HUNGER = false;
  const MAX_CHAIN_DEPTH = 3;
  const BLAST_CHAINS = false;
  ${extractConst("AGENT_BLOCK_OFFSETS")}
  ${code}`)();

// Board: 6 rows x 10 cols. Column 0: mixed; column 1: has a neutralizer with
// a hazard BELOW it in the same column, so the 3x3 must land before the walk
// reaches it.
const rows = 6, cols = 10;
const board = Array(rows * cols).fill("empty");
const at = (r, c) => r * cols + c;
// col 0
board[at(0, 0)] = "neutral";
board[at(1, 0)] = "red";      // hazard -> nibble
board[at(2, 0)] = "special_rock";  // skipped
board[at(3, 0)] = "neutral";
// col 1
board[at(0, 1)] = "neutral";
board[at(1, 1)] = "special_neutralizer"; // fires inline, mid-walk
board[at(2, 1)] = "green";          // defused by the 3x3 -> then consumed
board[at(4, 1)] = "neutral";

// biteFeast used to hand back BATCHES plus a settle map -- the meal chopped
// into animation beats, with a swallowed neutralizer closing a beat so its
// 3x3 could land in the pause.  The realtime refactor replaced all of it with
// one ordered walk (`order`), the specials firing inline on the standing
// board, and the cinematic pacing the replay itself.  The assertions that
// described the beats are gone with them; what survives is what was always
// the real claim -- WALK ORDER and OUTCOMES.
const out = biteFeast(board.slice(), rows, cols, 2);
const order = out.order;

const assert = (cond, msg) => { if (!cond) { console.error("FAIL:", msg, JSON.stringify({ order, eaten: [...out.eaten], nibbled: [...out.nibbled] })); process.exit(1); } };

// 1. The walk is column-major: column 0 top-down, then column 1.
assert(JSON.stringify(order) === JSON.stringify([...order].sort((a, b) => (a % cols) - (b % cols) || a - b)),
  "bite order is column-major");
// 2. The neutralizer is reached BEFORE the hazard below it -- which is the
//    whole reason that hazard gets defused in time to be swallowed.
const nIdx = order.indexOf(at(1, 1));
const hIdx = order.indexOf(at(2, 1));
assert(nIdx !== -1, "neutralizer must be bitten");
assert(hIdx > nIdx, "hazard below the neutralizer is reached after it");
// 3. The 3x3 fired on the standing board, so it is EATEN not nibbled.
assert(out.eaten.has(at(2, 1)) && !out.nibbled.has(at(2, 1)), "defused hazard consumed");
// 4. Col-0 expectations: neutral+neutral eaten, red nibbled, rock not eaten.
assert(out.eaten.has(at(0, 0)) && out.eaten.has(at(3, 0)), "col0 neutrals eaten");
assert(out.nibbled.has(at(1, 0)), "col0 hazard nibbled");
assert(!out.eaten.has(at(2, 0)), "rock not eaten");

console.log("BITE ORDER OK", { order });

// --- Rock rules ------------------------------------------------------------
{
  // downgradeName mirror: the Agent breaks a rock into red.
  const start = src.indexOf("function downgradeName(");
  let i = src.indexOf("{", start), depth = 0;
  for (; i < src.length; i++) { if (src[i] === "{") depth++; else if (src[i] === "}" && --depth === 0) break; }
  const downgradeName = new Function(src.slice(start, i + 1) + "\nreturn downgradeName;")();
  const chain = ["special_rock", "red", "yellow", "green", "defused", null];
  for (let k = 0; k < chain.length - 1; k++) {
    const got = downgradeName(chain[k]);
    if (got !== chain[k + 1]) { console.error("FAIL: downgrade chain", chain[k], "->", got); process.exit(1); }
  }
}
{
  // A swallowed neutralizer cracks a rock later in the same column: the 3x3
  // fires inline on the standing board, and the walk then NIBBLES the red it
  // left behind.
  const rows2 = 2, cols2 = 3;
  const b2 = Array(rows2 * cols2).fill("empty");
  b2[0] = "special_neutralizer"; // (0,0)
  b2[cols2] = "special_rock";    // (1,0)
  const out2 = biteFeast(b2.slice(), rows2, cols2, 1);
  const a = (cond, msg) => { if (!cond) { console.error("FAIL:", msg, JSON.stringify({ order: out2.order, nibbled: [...out2.nibbled], eaten: [...out2.eaten] })); process.exit(1); } };
  a(JSON.stringify(out2.order) === JSON.stringify([0, cols2]),
    "neutralizer bitten first, then the rock it cracked");
  a(out2.nibbled.has(cols2) && !out2.eaten.has(cols2), "cracked rock is NIBBLED (red), not consumed");
}
console.log("ROCK RULES OK");
