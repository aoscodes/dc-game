// Mirror check: web/game.js biteFeast vs src/shared/slime.zig feast, for the
// rock gnaw, with specials.rock.bite_costs_hunger both OFF and ON.
import { readFileSync } from "node:fs";
// Resolved from THIS file, not the cwd: the harness is run by
// `zig build web-test` from the repo root and by hand from anywhere.
const src = readFileSync(
  new URL("../game.js", import.meta.url), "utf8");

const grab = (name) => {
  const i = src.indexOf(`function ${name}(`);
  if (i < 0) throw new Error(`missing ${name}`);
  let d = 0, j = src.indexOf("{", i);
  for (let k = j; k < src.length; k++) {
    if (src[k] === "{") d++;
    else if (src[k] === "}" && --d === 0) return src.slice(i, k + 1);
  }
  throw new Error(`unbalanced ${name}`);
};

let ROCK_BITE_COSTS_HUNGER = false;
let BOMB_ROCKS_ONLY = false;
const TIER_NAMES = ["red", "yellow", "green"];
const hazardTier = (n) => { const i = TIER_NAMES.indexOf(String(n).replace("tiered_", "")); return n?.startsWith("tiered_") && i >= 0 ? i : null; };
const downgradeName = (n) => {
  if (n === "special_rock") return "tiered_red";
  const t = hazardTier(n);
  if (t === null) return null;
  return t === 2 ? "neutralized" : `tiered_${TIER_NAMES[t + 1]}`;
};
const cellIsEdible = (n) => n === "neutral" || n === "neutralized" ||
  (n?.startsWith("special_") && n !== "special_rock");
const agentBlockCells = () => [];
const detonateOn = () => 0;
// This harness only exercises the ROCK path, so the chain hooks are stubbed
// to their default-tuning answers: nothing is armed for the cast, everything
// still fires on eat.
const SPECIAL_ACTIVATE_ON = {};
const AGENT_BLOCK_OFFSETS = [];
const activatesOnEat = () => true;
const activatesOnCast = () => false;
const shapeOutcome = () => ({ downgraded: 0, neutralized: 0, rocksBroken: 0, offGrid: 0, inert: 0, activated: 0, destroyed: 0 });
const stampOn = () => {};

const biteFeast = eval(`(${grab("biteFeast")})`);

const ok = (c, m) => { if (!c) { console.error("FAIL: " + m); process.exit(1); } };

const R = "special_rock", N = "neutral", E = "empty";

// --- flag OFF: rock is skipped entirely -------------------------------------
ROCK_BITE_COSTS_HUNGER = false;
let r = biteFeast([N, R, N], 3, 1, 1);
ok(r.eaten.size === 2, "off: two neutrals eaten");
ok(r.gnawed.size === 0, "off: nothing gnawed");
ok(r.order.length === 2, "off: rock not visited");
ok(!r.order.includes(1), "off: rock absent from order");

// --- flag ON: rock is visited, unchanged, never eaten ------------------------
ROCK_BITE_COSTS_HUNGER = true;
r = biteFeast([N, R, N], 3, 1, 1);
ok(r.eaten.size === 2, "on: still exactly two eaten");
ok(!r.eaten.has(1), "on: rock NOT eaten");
ok(r.nibbled.size === 0, "on: a gnaw is not a nibble");
ok(r.gnawed.size === 1 && r.gnawed.has(1), "on: rock gnawed");
ok(r.order.length === 3, "on: rock visited");
ok(r.order[1] === 1, "on: gnaw happens in walk order (top-down)");

// --- the board must be IDENTICAL either way ---------------------------------
const board = [N, R, N];
ROCK_BITE_COSTS_HUNGER = false; const a = board.slice(); biteFeast(a, 3, 1, 1);
ROCK_BITE_COSTS_HUNGER = true;  const b = board.slice(); biteFeast(b, 3, 1, 1);
ok(JSON.stringify(a) === JSON.stringify(b), "flag changes NO board state");

// --- empties are never gnawed ------------------------------------------------
ROCK_BITE_COSTS_HUNGER = true;
r = biteFeast([E, E, E], 3, 1, 1);
ok(r.gnawed.size === 0 && r.order.length === 0, "empties never gnawed");

// --- a rock outside the bite strip is untouched -----------------------------
r = biteFeast([N, R], 1, 2, 1); // width 1, rock in col 1
ok(r.gnawed.size === 0, "rock outside the strip is not gnawed");

// --- rocks-only: every rock gnawed, every bite, forever ---------------------
r = biteFeast([R, R], 1, 2, 2);
ok(r.gnawed.size === 2 && r.eaten.size === 0, "rocks-only: all gnawed, none eaten");

// --- biteAt must not swallow a rock -----------------------------------------
const biteAtSrc = grab("biteAt");
ok(/name === "special_rock"/.test(biteAtSrc), "biteAt guards special_rock");
const guardAt = biteAtSrc.indexOf('name === "special_rock"');
ok(guardAt < biteAtSrc.indexOf("bite(flat)"), "guard precedes bite(flat)");

// --- the wasted-mouthful hatch covers gnaws ---------------------------------
ok(/reach\.nibbled\.has\(flat\) \|\| reach\.gnawed\.has\(flat\)/.test(src),
  "nibble hatch also marks gnawed rocks");
ok(/eaten: new Set\(\), nibbled: new Set\(\), gnawed: new Set\(\)/.test(src),
  "replay stub carries gnawed (else the draw throws)");
ok(/bal\.specials\?\.rock\?\.bite_costs_hunger/.test(src), "flag read from balance");

console.log("GNAW MIRROR OK");
