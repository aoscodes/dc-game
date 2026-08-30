import { readFileSync } from "node:fs";
// Resolved from THIS file, not the cwd: the harness is run by
// `zig build web-test` from the repo root and by hand from anywhere.
const src = readFileSync(
  new URL("../game.js", import.meta.url), "utf8");

function extractConst(name) {
  const start = src.indexOf(`const ${name} = [`);
  if (start < 0) throw new Error(`missing const ${name}`);
  return src.slice(start, src.indexOf("];", start) + 2);
}
function extract(name) {
  const start = src.indexOf(`function ${name}(`);
  if (start < 0) throw new Error(`missing ${name}`);
  let i = src.indexOf("{", start), depth = 0;
  for (; i < src.length; i++) { if (src[i] === "{") depth++; else if (src[i] === "}" && --depth === 0) break; }
  return src.slice(start, i + 1);
}
const TIER_NAMES = ["red", "yellow", "green"];
const BOMB_ROCKS_ONLY = false;
const ROCK_BITE_COSTS_HUNGER = false;
const ctx = new Function(`
  const TIER_NAMES = ${JSON.stringify(TIER_NAMES)};
  const BOMB_ROCKS_ONLY = ${BOMB_ROCKS_ONLY};
  const ROCK_BITE_COSTS_HUNGER = ${ROCK_BITE_COSTS_HUNGER};
  const SPECIAL_ACTIVATE_ON = {};
  const MAX_CHAIN_DEPTH = 3;
  const BLAST_CHAINS = false;
  const TIER_CHAR = { red: "\u2261", yellow: "=", green: "-" };
  ${extractConst("AGENT_BLOCK_OFFSETS")}
  ${extract("activatesOnCast")}
  ${extract("activatesOnEat")}
  ${extract("shapeOutcome")}
  ${extract("stampOn")}
  ${extract("activateOn")}
  ${extract("downgradeName")}
  ${extract("hazardTier")}
  ${extract("cellIsEdible")}
  ${extract("cellStyle")}
  ${extract("cellIsSlime")}
  ${extract("agentBlockCells")}
  ${extract("detonateOn")}
  ${extract("biteFeast")}
  return { downgradeName, biteFeast, cellIsEdible, hazardTier };
`)();

const ok = (cond, msg, extra) => {
  if (!cond) { console.error("FAIL:", msg, extra ?? ""); process.exit(1); }
};

// 1. The break ladder, mirroring slime.apply_shape.
const chain = ["special_rock", "red", "yellow", "green", "defused", null];
for (let k = 0; k < chain.length - 1; k++) {
  ok(ctx.downgradeName(chain[k]) === chain[k + 1], `ladder ${chain[k]}`, ctx.downgradeName(chain[k]));
}
// Other specials stay cast-proof.
for (const s of ["special_egg", "special_neutralizer", "special_canister", "special_bomb", "neutral"]) {
  ok(ctx.downgradeName(s) === null, `${s} must be cast-proof`, ctx.downgradeName(s));
}

// 2. The bite SKIPS an unbroken rock: not eaten, not nibbled, not in order.
{
  const rows = 1, cols = 2;
  const b = ["special_rock", "neutral"];
  const out = ctx.biteFeast(b, rows, cols, 2);
  ok(!out.eaten.has(0) && !out.nibbled.has(0), "rock must not be bitten");
  ok(!out.order.includes(0), "rock must not enter the walk order (biteAt would consume it)");
  ok(out.eaten.has(1), "neutral beside a rock is still eaten");
}

// 3. A swallowed neutralizer BREAKS a rock inline, on the standing board.
{
  // row 0: [neutralizer, rock]  -- rock is in the agent block of flat 0
  const rows = 1, cols = 2;
  const b = ["special_neutralizer", "special_rock"];
  const out = ctx.biteFeast(b.slice(), rows, cols, 2);
  ok(out.eaten.has(0), "neutralizer swallowed");
  // The rock became red mid-walk, so the walk NIBBLES it when it arrives.
  ok(out.nibbled.has(1), "rock cracked to red mid-bite is then nibbled", [...out.nibbled]);
}

// 4. A rocks-only front is a STALL: the bite takes nothing at all.
{
  const rows = 2, cols = 1;
  const out = ctx.biteFeast(["special_rock", "special_rock"], rows, cols, 1);
  ok(out.order.length === 0 && out.eaten.size === 0 && out.nibbled.size === 0,
    "rocks-only bite must be a no-op (this is the stall)");
}
console.log("REALTIME ROCK MIRROR OK");
