// Put a test brood on a bridge-connected board, without touching its flash.
//
// The problem this solves is that a badge's stats are frozen into the game at
// one instant and reported by the board once per link, so iterating on how a
// brood LOOKS meant reflashing and replugging a badge for every palette. This
// rewrites the bridge's in-memory picture of a board instead and reseats it,
// which is the whole round trip a real CTRL:STAT would take minus the flash.
//
// Nothing here writes to the badge. The override survives exactly as long as
// the USB link: replug and the board's real flash contents win again.
//
// The palettes are not reimplemented. web/palette.js is loaded and run as-is,
// so the colours printed below are the same numbers the browser will paint —
// a preview that can drift from the renderer is worse than no preview.
//
// Requires the bridge to be running with DEV_INJECT=1.
//
//   DEV_INJECT=1 npm start --prefix bridge
//
// Usage:
//   node bridge/tools/inject.mjs --list
//   node bridge/tools/inject.mjs --babies 3,2,1,1,2 --seed 1f3c9a04
//   node bridge/tools/inject.mjs --sweep 6000
//   node bridge/tools/inject.mjs --board 4 --colors none   # boardless look
//   node bridge/tools/inject.mjs --clear
import { readFileSync } from "node:fs";
import { createContext, runInContext } from "node:vm";

const BABY_TYPES = ["rose", "mint", "sky", "gold", "plum"];
const DEFAULT_BABIES = [3, 2, 1, 1, 2];
// Arbitrary, but FIXED: a default that rolled randomly would make "it looked
// wrong on the last run" an unanswerable question.
const DEFAULT_SEED = 0x1f3c9a04;
const DEFAULT_SWEEP_MS = 6000;

// ---------------------------------------------------------------------------
// The real rollers
// ---------------------------------------------------------------------------

// palette.js is browser code, but it is plain arithmetic over plain globals
// with no DOM in it, so it runs unmodified in a bare vm context. If this ever
// throws on a missing global, that is worth knowing: it means the colour
// module picked up a browser dependency and is no longer portable.
const paletteSrc = readFileSync(new URL("../../web/palette.js", import.meta.url), "utf8");
const ctx = createContext({});
runInContext(paletteSrc, ctx, { filename: "palette.js" });
const { rollPalette, rollBroodPalette, mulberry32, rgbToHex, hslToRgb } = ctx;
for (const [name, fn] of Object.entries({ rollPalette, rollBroodPalette, mulberry32, rgbToHex, hslToRgb })) {
  if (typeof fn !== "function") {
    console.error(`palette.js did not define ${name}() — has it been renamed?`);
    process.exit(1);
  }
}

// The rollers deal in {h,s,l} — the form the LED spin interpolates in — and
// everything downstream of them wants six hex digits.
const hex = (c) => rgbToHex(hslToRgb(c.h, c.s, c.l));

// ---------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------

function usage(problem) {
  if (problem) console.error(`inject: ${problem}\n`);
  console.error(`Put a test brood on a bridge-connected board (in-memory; flash untouched).

  --list                 show linked boards and exit
  --board <linkId|uid>   which board (default: all linked)
  --babies <a,b,c,d,e>   per-type counts, ${BABY_TYPES.join("/")} (default: ${DEFAULT_BABIES.join(",")})
  --seed <hex>           brood seed, u32 (default: ${DEFAULT_SEED.toString(16)})
  --colors <a,b,c|auto|none|keep>
                         badge palette as six-digit hex.  auto = roll one from
                         the seed, none = pretend never onboarded, keep = leave
                         whatever the board reported (default: auto)
  --sweep [ms]           re-roll the seed every ms until interrupted
                         (default: ${DEFAULT_SWEEP_MS})
  --clear                drop all overrides; board reverts on its next report
  --no-reseat            rewrite the stats but do not rebuild the player
  --port <n>             bridge port (default: 3000, or $PORT)
`);
  process.exit(problem ? 2 : 0);
}

function parseArgs(argv) {
  const out = {
    list: false, target: "all", babies: undefined, seed: undefined,
    colors: "auto", sweep: null, clear: false, reseat: true,
    port: Number(process.env.PORT ?? 3000),
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    // Read the next argv entry, but only if it is a value rather than the
    // next flag — this is what lets --sweep take an optional duration.
    const peek = () => (argv[i + 1] !== undefined && !argv[i + 1].startsWith("--")) ? argv[++i] : null;
    const need = () => { const v = peek(); if (v === null) usage(`${arg} needs a value`); return v; };
    switch (arg) {
      case "--help": case "-h": usage(); break;
      case "--list": out.list = true; break;
      case "--clear": out.clear = true; break;
      case "--no-reseat": out.reseat = false; break;
      case "--board": {
        const v = need();
        out.target = /^\d+$/.test(v) ? Number(v) : v;
        break;
      }
      case "--babies": {
        const parts = need().split(",");
        if (parts.length !== BABY_TYPES.length || !parts.every((p) => /^\d+$/.test(p))) {
          usage(`--babies wants ${BABY_TYPES.length} non-negative integers`);
        }
        out.babies = parts.map(Number);
        break;
      }
      case "--seed": {
        const v = need();
        if (!/^(0x)?[0-9a-fA-F]{1,8}$/.test(v)) usage("--seed wants up to 8 hex digits");
        out.seed = parseInt(v.replace(/^0x/, ""), 16) >>> 0;
        break;
      }
      case "--colors": out.colors = need(); break;
      case "--sweep": out.sweep = Number(peek() ?? DEFAULT_SWEEP_MS); break;
      case "--port": out.port = Number(need()); break;
      default: usage(`unknown option ${arg}`);
    }
  }
  if (out.sweep !== null && (!Number.isFinite(out.sweep) || out.sweep < 250)) {
    usage("--sweep wants a duration of at least 250ms");
  }
  return out;
}

// ---------------------------------------------------------------------------
// Bridge calls
// ---------------------------------------------------------------------------

async function call(port, method, route, body) {
  const url = `http://127.0.0.1:${port}${route}`;
  let res;
  try {
    res = await fetch(url, {
      method,
      headers: body === undefined ? {} : { "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch (err) {
    console.error(`inject: cannot reach the bridge at ${url} (${err.cause?.code ?? err.message})`);
    console.error("        is it running?  DEV_INJECT=1 npm start --prefix bridge");
    process.exit(1);
  }
  // The routes 404 as a block when DEV_INJECT is unset, so a 404 on the
  // endpoint itself is far more likely to be a disabled bridge than a typo.
  if (res.status === 404) {
    const payload = await res.json().catch(() => null);
    if (payload === null) {
      console.error("inject: the bridge has /api/dev disabled.");
      console.error("        restart it with DEV_INJECT=1 npm start --prefix bridge");
      process.exit(1);
    }
    console.error(`inject: ${(payload.errors ?? ["not found"]).join("; ")}`);
    process.exit(1);
  }
  const payload = await res.json().catch(() => ({}));
  if (!res.ok) {
    console.error(`inject: bridge rejected the request (${res.status})`);
    for (const e of payload.errors ?? []) console.error(`        ${e}`);
    process.exit(1);
  }
  return payload;
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

/** The three colours a seed will actually paint a brood, darkest first. */
function broodPreview(seed) {
  return rollBroodPalette(seed).map((c) => `#${hex(c)}`);
}

function describe(b) {
  const counts = b.babies
    .map((n, i) => (n > 0 ? `${n} ${BABY_TYPES[i]}` : null))
    .filter((s) => s !== null);
  const total = b.babies.reduce((a, n) => a + n, 0);
  const lines = [
    `  link ${b.linkId}  uid=${b.uid}${b.seated ? "" : "  (unseated)"}`,
    `    babies   ${total === 0 ? "none" : `${total} — ${counts.join(", ")}`}`,
    `    palette  ${b.colors === null ? "none (renders greyscale)" : b.colors.map((c) => `#${c}`).join(" ")}`,
  ];
  if (b.seed === null) {
    lines.push("    seed     none");
  } else {
    const seed = parseInt(b.seed, 16) >>> 0;
    lines.push(`    seed     ${b.seed}`);
    // The gate the renderer applies: no palette on the badge means no brood
    // palette either, so a seed alone would be a silently ignored setting.
    lines.push(b.colors === null
      ? "    brood    greyscale — the badge has no palette"
      : `    brood    ${broodPreview(seed).join(" ")}`);
  }
  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const opts = parseArgs(process.argv.slice(2));

if (opts.list) {
  const { boards } = await call(opts.port, "GET", "/api/dev/boards");
  if (boards.length === 0) {
    console.log("no boards are linked");
  } else {
    console.log(`${boards.length} board${boards.length === 1 ? "" : "s"} linked:\n`);
    for (const b of boards) console.log(describe(b) + "\n");
  }
  process.exit(0);
}

if (opts.clear) {
  const { applied } = await call(opts.port, "POST", "/api/dev/inject", {
    target: opts.target,
    babies: [0, 0, 0, 0, 0],
    colors: null,
    seed: null,
    reseat: opts.reseat,
  });
  console.log(`cleared ${applied.length} board${applied.length === 1 ? "" : "s"} ` +
    "(real values return on the next replug)\n");
  for (const b of applied) console.log(describe(b) + "\n");
  process.exit(0);
}

/** Build one injection body for a given seed. */
function bodyFor(seed) {
  const body = {
    target: opts.target,
    babies: opts.babies ?? DEFAULT_BABIES,
    seed,
    reseat: opts.reseat,
  };
  if (opts.colors === "auto") {
    body.colors = rollPalette(mulberry32(seed)).map(hex);
  } else if (opts.colors === "none") {
    body.colors = null;
  } else if (opts.colors !== "keep") {
    const parts = opts.colors.split(",");
    if (parts.length !== 3 || !parts.every((c) => /^[0-9a-fA-F]{6}$/.test(c))) {
      usage("--colors wants three six-digit hex values, or auto/none/keep");
    }
    body.colors = parts.map((c) => c.toLowerCase());
  }
  // "keep" omits the key entirely, which is how the bridge tells "leave this
  // stat alone" from "clear it".
  return body;
}

async function inject(seed) {
  const { applied } = await call(opts.port, "POST", "/api/dev/inject", bodyFor(seed));
  const reseated = applied.filter((b) => b.reseated).length;
  console.log(`injected into ${applied.length} board${applied.length === 1 ? "" : "s"}` +
    (opts.reseat
      ? `, ${reseated} reseated${reseated < applied.length ? " (the rest were not playing)" : ""}`
      : ", none reseated (--no-reseat)"));
  for (const b of applied) console.log(describe(b) + "\n");
}

if (opts.sweep === null) {
  await inject(opts.seed ?? DEFAULT_SEED);
  if (opts.reseat) {
    console.log("the board left and rejoined its game carrying these stats");
  } else {
    console.log("stats rewritten; they reach the game when the board is next seated");
  }
} else {
  // Walk the seed space rather than sampling it randomly, so a palette that
  // looked wrong can be found again: every run visits the same sequence.
  let seed = opts.seed ?? DEFAULT_SEED;
  const rand = mulberry32(seed);
  console.log(`sweeping a new brood every ${opts.sweep}ms — ctrl-c to stop`);
  console.log("NOTE: each change reseats the board, so it leaves and rejoins the game\n");
  for (;;) {
    await inject(seed);
    await new Promise((r) => setTimeout(r, opts.sweep));
    seed = (rand() * 0x100000000) >>> 0;
  }
}
