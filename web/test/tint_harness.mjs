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
// The palettes are therefore not invented here. They come from palette.js's
// real rollers over thousands of seeds, so this asserts against the actual
// reachable input space rather than a guess at it. BOTH rollers: the adults
// wear rollPalette and their babies wear rollBroodPalette, the two are drawn
// from different saturation bands, and the same substitution has to hold for
// each. Desaturating is exactly the direction that makes an ordering fragile
// — the three colours span less of the cube — so the baby band is not a
// weaker case of the adult one and is checked in its own right.
import { readFileSync } from "node:fs";

const gameSrc = readFileSync(new URL("../game.js", import.meta.url), "utf8");
const paletteSrc = readFileSync(new URL("../palette.js", import.meta.url), "utf8");

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

const GAME_NAMES = [
  "deriveShadow", "parseRgba", "playerColor", "seatPalette",
];
const GAME_CONSTS = [
  "PLAYER_COLORS", "C_UNSEATED", "SEAT_INK_MIX", "SEAT_ACCENT_MIX",
];
const game = new Function(`
  ${GAME_CONSTS.map((n) => extractConst(gameSrc, n)).join("\n")}
  ${GAME_NAMES.map((n) => extract(gameSrc, n)).join("\n")}
  return { ${GAME_NAMES.join(", ")}, PLAYER_COLORS };
`)();

const PALETTE_NAMES = [
  "hslToRgb", "wrapHue", "mulberry32", "randRange", "shuffle", "rollHarmonic",
  "rollPalette", "rollBroodPalette", "luminance",
];
const PALETTE_CONSTS = ["PALETTE_SIZE", "HUE_SCHEMES", "HARMONY", "BABY_HARMONY"];
const palette = new Function(`
  ${PALETTE_CONSTS.map((n) => extractConst(paletteSrc, n)).join("\n")}
  ${PALETTE_NAMES.map((n) => extract(paletteSrc, n)).join("\n")}
  return { ${PALETTE_NAMES.join(", ")}, ${PALETTE_CONSTS.join(", ")} };
`)();

const { deriveShadow, seatPalette, PLAYER_COLORS } = game;
// luminance comes from palette.js, which is where the ordering rule that uses
// it lives — so the rule and this check cannot come to measure different axes.
const {
  hslToRgb, mulberry32, rollPalette, rollBroodPalette, luminance, HARMONY,
} = palette;

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

// The BABY atlas is recoloured by the same code, from a different palette, so
// it needs the same legend. It shipped without one for as long as babies were
// nobody's — they belonged to the table, and there was no badge behind them to
// borrow colours from. Now that a player's babies wear their badge's brood
// palette, a missing legend here is a silent no-op: tintedSheet returns the
// authored sheet unchanged and every brood on the field is grey, which looks
// like the feature was never wired up rather than like a broken asset.
{
  const babies = JSON.parse(
    readFileSync(new URL("../assets/babies.json", import.meta.url), "utf8"),
  );
  for (const role of ["ink", "shadow", "fill", "accent"]) {
    check(Array.isArray(babies.tones?.[role]), `baby atlas legend names ${role}`);
  }
  check(typeof babies.shadow_ratio === "number",
    "baby atlas carries a shadow_ratio");
  // Same authored greys as the adults, which is what lets one substitution
  // serve both. If the two ever diverged, the shared deriveShadow ratio and
  // the shared role ordering would each be right for only one of them.
  for (const role of ["ink", "shadow", "fill", "accent"]) {
    check(JSON.stringify(babies.tones?.[role]) === JSON.stringify(meta.tones[role]),
      `baby atlas tone ${role} matches the adults'`);
  }
}

// ---------------------------------------------------------------------------
// The ordering survives every palette the rollers can produce
// ---------------------------------------------------------------------------

const SEEDS = 5000;
const ratio = meta.shadow_ratio;

/**
 * Run one roller's whole reachable output through the substitution.
 * @param {string} label which palette, for the failure text
 * @param {(seed: number) => {h,s,l}[]} roll
 * @returns {{worstContrast: number, flat: number}}
 */
function checkRoller(label, roll) {
  let worstContrast = Infinity;
  let flatPalettes = 0;
  const before = failures;

  for (let seed = 0; seed < SEEDS; seed++) {
    const triad = roll(seed).map((c) => hslToRgb(c.h, c.s, c.l));

    // INDEX IS ROLE: the roller deals its lightness ladder out ascending, and
    // that index survives unchanged all the way to the renderer (for adults it
    // is also LED index). Taken here exactly as tintedSheet takes it -
    // positionally, with no sort - so this measures the contract rather than a
    // repair of it.
    const [ink, fill, accent] = triad;
    const shadow = deriveShadow(ink, fill, ratio);

    const li = luminance(ink), ls = luminance(shadow), lf = luminance(fill);

    // The ordering the renderer trusts, checked in the renderer's own axis.
    // palette_harness asserts the same thing in HSL lightness, where the
    // roller builds it; these are different axes and a saturated triad can be
    // well spread on one and tight on the other, so both are worth stating.
    check(li <= lf,
      `${label} seed ${seed}: entry 0 is lighter than entry 1, so the ink ` +
      `would outline the fill in a paler colour than the fill itself`);
    check(lf <= luminance(accent),
      `${label} seed ${seed}: entry 2 is darker than entry 1, so the ` +
      `highlight would be darker than the body it highlights`);

    // The invariant the drawing depends on: the outline never comes out
    // lighter than the shading, and the shading never lighter than the body.
    // Mixing makes this true by construction, so a failure here means
    // deriveShadow stopped being a mix - which is exactly the regression worth
    // catching, since the previous "darkened fill" version broke it on real
    // palettes.
    //
    // ROUND is the one slack. Each channel is rounded to a byte, and luminance
    // weights sum to 1, so the result can sit up to half a unit outside the
    // exact mix. That only ever matters when the ink and fill are within a
    // unit of each other in luminance, where the two colours are indis-
    // tinguishable anyway - it cannot hide a real inversion, which would be
    // tens of units wide.
    const ROUND = 0.5;
    check(ls >= li - ROUND, `${label} seed ${seed}: shadow fell below the ink`);
    check(lf >= ls - ROUND, `${label} seed ${seed}: shadow rose above the fill`);

    // And it lands at the depth the artist drew, not merely somewhere between.
    // Rounding is per channel, so a unit of slack.
    for (let ch = 0; ch < 3; ch++) {
      const want = ink[ch] + (fill[ch] - ink[ch]) * ratio;
      check(Math.abs(shadow[ch] - want) <= 1,
        `${label} seed ${seed}: shadow channel ${ch} off the authored depth`);
      check(Number.isInteger(shadow[ch]) && shadow[ch] >= 0 && shadow[ch] <= 255,
        `${label} seed ${seed}: shadow channel ${ch} out of byte range`);
    }
    for (const ch of accent) {
      check(ch >= 0 && ch <= 255, `${label} seed ${seed}: accent channel out of range`);
    }

    const contrast = luminance(accent) - li;
    worstContrast = Math.min(worstContrast, contrast);
    if (contrast < 25) flatPalettes++;
    if (failures > before + 20) break; // a systematic break floods; 20 shows it
  }
  return { worstContrast, flat: flatPalettes };
}

const adult = checkRoller("adult", (seed) => rollPalette(mulberry32(seed)));
const brood = checkRoller("brood", rollBroodPalette);

// HOW MUCH contrast a creature ends up with is the palette's business, not
// this code's. palette.js separates its three colours by HSL lightness
// (minLumGap), which is the axis the LEDs and the badge screen are tuned for;
// Rec. 709 luminance is a different axis, and a saturated triad can be well
// spread on the first and nearly flat on the second. Such a badge gets a
// low-contrast Lil Guy, and that is FAITHFUL - it is wearing its own colours.
//
// What is asserted is only that this stays a rare tail. If a change to a
// palette roller ever made flat triads common, every creature on the field
// would go mushy at once, and that should not be discovered at an event.
//
// The BABY band is where this bound earns its keep. Desaturating pulls all
// three colours toward the same grey, so it is the change most likely to push
// the tail up, and the one whose damage is least visible in review: a brood
// too flat to read is five small smudges, not an obviously broken adult.
check(adult.flat / SEEDS < 0.05,
  `too many near-flat adult palettes (${adult.flat}/${SEEDS})`);
check(brood.flat / SEEDS < 0.05,
  `too many near-flat brood palettes (${brood.flat}/${SEEDS})`);
console.log(`  contrast: adult worst ${adult.worstContrast.toFixed(1)} ` +
  `(${adult.flat} flat), brood worst ${brood.worstContrast.toFixed(1)} ` +
  `(${brood.flat} flat), of ${SEEDS} each`);

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

// --- the seat-colour fallback ----------------------------------------------
//
// A player without a badge borrows their seat colour, and the result is fed to
// exactly the same recolour path as a rolled palette. So it has to satisfy
// exactly the same ordering: ink darkest, then shadow, then fill, then accent,
// or the outline stops reading as an outline. Held to the real standard rather
// than assumed safe because it is synthesised — nobody looks at these the way
// somebody looks at a colour they picked at the kiosk.
{
  const seats = [...PLAYER_COLORS.keys(), 0xff]; // every seat, plus unseated
  let worstSeatGap = Infinity;
  for (const seat of seats) {
    const [ink, fill, accent] = seatPalette(seat);
    const shadow = deriveShadow(ink, fill, ratio);
    const [li, ls, lf, la] =
      [ink, shadow, fill, accent].map(luminance);

    check(li < ls && ls < lf && lf < la,
      `seat ${seat}: ink<shadow<fill<accent ` +
      `(got ${li.toFixed(0)}, ${ls.toFixed(0)}, ${lf.toFixed(0)}, ${la.toFixed(0)})`);

    // Ordered is not the same as legible: a correctly ordered palette spread
    // over three luminance steps is still one flat blob on screen. Rolled
    // palettes are allowed a rare near-flat tail because a player chose them;
    // these were chosen by this file, so they get no such excuse.
    worstSeatGap = Math.min(worstSeatGap, la - li);

    for (const ch of [...ink, ...fill, ...accent]) {
      check(Number.isInteger(ch) && ch >= 0 && ch <= 255,
        `seat ${seat}: channel ${ch} is a byte`);
    }
  }
  check(worstSeatGap > 60,
    `every seat palette spans a visible range (worst ${worstSeatGap.toFixed(0)})`);

  // Distinct seats must stay distinct as creatures, or the fallback defeats
  // the only purpose it has.
  const fills = PLAYER_COLORS.map((_, i) => seatPalette(i)[1].join(","));
  check(new Set(fills).size === fills.length,
    "the four seats yield four different creature colours");
}

if (failures > 0) {
  console.log(`tint: ${failures} failure(s)`);
  process.exit(1);
}
console.log(
  `OK  tint: ink<=shadow<=fill over ${SEEDS} adult + ${SEEDS} brood palettes ` +
  `(${adult.flat} + ${brood.flat} near-flat)`,
);
