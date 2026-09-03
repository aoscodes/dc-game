// Harness for repainting a Lil Guy in its badge's colours (web/game.js
// tintedSheet / deriveShadow).
//
// This mirrors no Zig. It is here for the same reason palette_harness is: the
// property that matters is STATISTICAL. The art is drawn in five flat tones
// and reads as a creature only because they stack in a fixed order — the
// outline darker than the shading, the shading darker than the body. Three of
// those tones are replaced at runtime by whatever three colours a badge rolled
// on the /onboard screen, and the fourth is computed from them. So the
// ordering is no longer something the artist guaranteed; it is something the
// substitution has to preserve for every palette the roller can produce.
//
// A palette that inverts it does not throw. It renders a creature whose
// outline has vanished into its body — a legible drawing on nine badges and a
// grey smear on the tenth, discovered at the event.
//
// The palettes are therefore not invented here. They come from onboard.js's
// real rollPalette over thousands of seeds, so this asserts against the actual
// reachable input space rather than a guess at it.
import { readFileSync } from "node:fs";

const gameSrc = readFileSync(new URL("../game.js", import.meta.url), "utf8");
const onboardSrc = readFileSync(new URL("../onboard.js", import.meta.url), "utf8");

/** Slice out `function NAME(...) { ... }` by brace matching. */
function extract(src, name) {
  const start = src.indexOf(`function ${name}(`);
  if (start < 0) throw new Error(`missing function ${name}`);
  let i = src.indexOf("{", start), depth = 0;
  for (; i < src.length; i++) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}" && --depth === 0) break;
  }
  return src.slice(start, i + 1);
}

/** Slice out `const NAME = {...};` / `= [...];` the same way. */
function extractConst(src, name) {
  const start = src.indexOf(`const ${name} = `);
  if (start < 0) throw new Error(`missing const ${name}`);
  const open = src.indexOf("=", start) + 1;
  let i = open, depth = 0, seen = false;
  for (; i < src.length; i++) {
    const c = src[i];
    if (c === "{" || c === "[") { depth++; seen = true; }
    else if (c === "}" || c === "]") { if (--depth === 0 && seen) break; }
    else if (c === ";" && depth === 0) { i--; break; }
  }
  return src.slice(start, i + 1) + ";";
}

const GAME_NAMES = ["luminance", "deriveShadow"];
const game = new Function(`
  ${GAME_NAMES.map((n) => extract(gameSrc, n)).join("\n")}
  return { ${GAME_NAMES.join(", ")} };
`)();

const ONBOARD_NAMES = [
  "hslToRgb", "wrapHue", "mulberry32", "randRange", "shuffle", "rollPalette",
];
const onboard = new Function(`
  ${["LAYOUT", "HARMONY"].map((n) => extractConst(onboardSrc, n)).join("\n")}
  ${ONBOARD_NAMES.map((n) => extract(onboardSrc, n)).join("\n")}
  return { ${ONBOARD_NAMES.join(", ")}, HARMONY };
`)();

const { luminance, deriveShadow } = game;
const { hslToRgb, mulberry32, rollPalette, HARMONY } = onboard;

let failures = 0;
function check(cond, what) {
  if (!cond) { failures++; console.log(`FAIL: ${what}`); }
}

// ---------------------------------------------------------------------------
// The tone legend the atlas actually ships
// ---------------------------------------------------------------------------
//
// Read from the generated file rather than restated, because that json IS the
// contract between scripts/gen_lilguys.py and the recolour: the generator
// names the roles and the client addresses them by name. A legend that lost a
// role would leave that tone un-substituted — the creature would render with
// one authored grey band still in it, which looks like a shading choice rather
// than a bug.
const meta = JSON.parse(
  readFileSync(new URL("../assets/lilguy_rose.json", import.meta.url), "utf8"),
);

for (const role of ["ink", "shadow", "fill", "accent", "prop"]) {
  check(Array.isArray(meta.tones?.[role]), `atlas legend names ${role}`);
}
check(
  typeof meta.shadow_ratio === "number" && meta.shadow_ratio > 0 &&
    meta.shadow_ratio < 1,
  "atlas carries a shadow_ratio in (0,1)",
);

// The tones must be DISTINCT, or substitution collapses two roles onto one
// replacement and the art loses a band it was drawn with.
const levels = Object.values(meta.tones).map((c) => c[0]);
check(new Set(levels).size === levels.length, "authored tones are distinct");

// Every tone is neutral (r == g == b). tintedSheet indexes its replacement
// table by the RED channel alone, which is only sound while that holds.
for (const [role, [r, g, b]] of Object.entries(meta.tones)) {
  check(r === g && g === b, `tone ${role} is neutral grey`);
}

// The authored art must itself satisfy the ordering the recolour has to
// preserve — otherwise there is nothing to preserve and the target is a guess.
check(
  meta.tones.ink[0] < meta.tones.shadow[0] &&
    meta.tones.shadow[0] < meta.tones.fill[0],
  "authored ink < shadow < fill",
);

// ---------------------------------------------------------------------------
// The ordering survives every palette the roller can produce
// ---------------------------------------------------------------------------

const SEEDS = 5000;
const ratio = meta.shadow_ratio;

let worstContrast = Infinity;
let flatPalettes = 0;

for (let seed = 0; seed < SEEDS; seed++) {
  const rand = mulberry32(seed);
  const triad = rollPalette(rand).map((c) => hslToRgb(c.h, c.s, c.l));

  // LED order is the wire's order and carries no lightness information -
  // rollPalette shuffles it. tintedSheet sorts darkest-first to recover the
  // roles, and this mirrors that.
  const [ink, fill, accent] =
    [...triad].sort((a, b) => luminance(a) - luminance(b));
  const shadow = deriveShadow(ink, fill, ratio);

  const li = luminance(ink), ls = luminance(shadow), lf = luminance(fill);

  // The invariant the drawing depends on: the outline never comes out lighter
  // than the shading, and the shading never lighter than the body. Mixing
  // makes this true by construction, so a failure here means deriveShadow
  // stopped being a mix - which is exactly the regression worth catching,
  // since the previous "darkened fill" version broke it on real palettes.
  //
  // ROUND is the one slack. Each channel is rounded to a byte, and luminance
  // weights sum to 1, so the result can sit up to half a unit outside the
  // exact mix. That only ever matters when the ink and fill are within a
  // unit of each other in luminance, where the two colours are indis-
  // tinguishable anyway - it cannot hide a real inversion, which would be
  // tens of units wide.
  const ROUND = 0.5;
  check(ls >= li - ROUND, `seed ${seed}: shadow fell below the ink`);
  check(lf >= ls - ROUND, `seed ${seed}: shadow rose above the fill`);

  // And it lands at the depth the artist drew, not merely somewhere between.
  // Rounding is per channel, so a unit of slack.
  for (let ch = 0; ch < 3; ch++) {
    const want = ink[ch] + (fill[ch] - ink[ch]) * ratio;
    check(Math.abs(shadow[ch] - want) <= 1,
      `seed ${seed}: shadow channel ${ch} off the authored depth`);
    check(Number.isInteger(shadow[ch]) && shadow[ch] >= 0 && shadow[ch] <= 255,
      `seed ${seed}: shadow channel ${ch} out of byte range`);
  }
  for (const ch of accent) {
    check(ch >= 0 && ch <= 255, `seed ${seed}: accent channel out of range`);
  }

  const contrast = luminance(accent) - li;
  worstContrast = Math.min(worstContrast, contrast);
  if (contrast < 25) flatPalettes++;
  if (failures > 20) break; // a systematic break floods; 20 is enough to see it
}

// HOW MUCH contrast a creature ends up with is the palette's business, not
// this code's. onboard.js separates its three colours by HSL lightness
// (HARMONY.minLumGap), which is the axis the LEDs and the badge screen are
// tuned for; Rec. 709 luminance is a different axis, and a saturated triad can
// be well spread on the first and nearly flat on the second. Such a badge gets
// a low-contrast Lil Guy, and that is FAITHFUL - it is wearing its own colours.
//
// What is asserted is only that this stays a rare tail. If a change to the
// palette roller ever made flat triads common, every creature on the field
// would go mushy at once, and that should not be discovered at an event.
check(flatPalettes / SEEDS < 0.05,
  `too many near-flat palettes (${flatPalettes}/${SEEDS})`);

// ---------------------------------------------------------------------------
// Adversarial inputs the roller cannot currently produce
// ---------------------------------------------------------------------------
//
// The roller's clamps are not a safety argument for this code - they live in
// a different program, and a creature drawn from flash written by an older
// firmware need not respect today's ones. Mixing holds regardless, and these
// pin that rather than the clamps.
{
  // Identical ink and fill: the degenerate case. Everything collapses to one
  // colour, which is flat but not INVERTED, and must not produce NaN.
  const shadow = deriveShadow([90, 40, 40], [90, 40, 40], ratio);
  check(shadow.every((c, i) => c === [90, 40, 40][i]),
    "an ink-equal fill yields exactly that colour, not NaN");
}
{
  // Pure black ink, the authored case: mixing from black IS scaling, so this
  // must reproduce the authored tone exactly.
  const f = meta.tones.fill[0];
  const shadow = deriveShadow([0, 0, 0], [f, f, f], ratio);
  check(shadow[0] === meta.tones.shadow[0],
    `mixing the authored fill from black returns the authored shadow ` +
    `(got ${shadow[0]}, want ${meta.tones.shadow[0]})`);
}
{
  // A near-black fill under a black ink - the case that broke the previous
  // implementation, where a scaled fill fell to the ink's own level.
  const shadow = deriveShadow([0, 0, 0], [10, 10, 10], ratio);
  check(luminance(shadow) >= 0 && luminance(shadow) <= luminance([10, 10, 10]),
    "a near-black fill still lands inside the ink..fill range");
}

if (failures > 0) {
  console.log(`tint: ${failures} failure(s)`);
  process.exit(1);
}
console.log(
  `OK  tint: ink<=shadow<=fill over ${SEEDS} palettes ` +
  `(${flatPalettes} near-flat, worst contrast ${worstContrast.toFixed(1)})`,
);
