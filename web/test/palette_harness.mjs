// Harness for the badge onboarding palette (web/onboard.js).
//
// Unlike its neighbours this one mirrors no Zig code. It is here because the
// palette rules are *statistical*: rollPalette is only correct if it is
// correct for every seed, and a rule that holds for the nine rolls you tried
// by hand will still, one evening, hand a player three identical muddy browns
// on a badge whose flash then has to be rewritten by unplugging it.
//
// So: the invariants that make a triad legible — pairwise hue separation,
// saturation and lightness bands, distinct lightness steps — are asserted over
// thousands of reproducible seeds. The spin is checked for the one property
// that actually matters downstream: it lands EXACTLY on the colour that gets
// written to flash, so the LEDs never settle on a colour different from the
// saved one.
//
// Functions are extracted by name, same as the other harnesses, so onboard.js
// stays a plain browser script with no module system.
import { readFileSync } from "node:fs";

const src = readFileSync(new URL("../onboard.js", import.meta.url), "utf8");

/** Slice out `function NAME(...) { ... }` by brace matching. */
function extract(name) {
  const start = src.indexOf(`function ${name}(`);
  if (start < 0) throw new Error(`missing function ${name}`);
  let i = src.indexOf("{", start), depth = 0;
  for (; i < src.length; i++) { if (src[i] === "{") depth++; else if (src[i] === "}" && --depth === 0) break; }
  return src.slice(start, i + 1);
}

/**
 * Slice out `const NAME = {...};` / `= [...];` the same way.  Extracted rather
 * than restated here: the tunables are the thing under test, and a copy in the
 * harness would just drift until it agreed with nothing.
 */
function extractConst(name) {
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

const NAMES = [
  "hslToRgb", "rgbToHex", "luminance", "wrapHue", "hueDelta", "hueSeparation",
  "mulberry32", "randRange", "randInt", "shuffle", "rollPalette",
  "easeOutQuint", "makeNoise", "makeSpin", "spinSample", "spinColors",
  "spinDone", "paletteHex", "zoneRect",
];

const api = new Function(`
  ${["LAYOUT", "HARMONY", "SPIN"].map(extractConst).join("\n")}
  ${NAMES.map(extract).join("\n")}
  return { ${NAMES.join(", ")}, LAYOUT, HARMONY, SPIN };
`)();

const {
  hslToRgb, rgbToHex, luminance, hueSeparation, mulberry32, rollPalette,
  easeOutQuint, makeSpin, spinSample, spinColors, spinDone, paletteHex,
  zoneRect, LAYOUT, HARMONY,
} = api;

let failures = 0;
function check(cond, what) {
  if (!cond) { failures++; console.log(`FAIL: ${what}`); }
}
function eq(a, b, what) {
  check(a === b, `${what} (got ${a}, want ${b})`);
}
function near(a, b, tol, what) {
  check(Math.abs(a - b) <= tol, `${what} (got ${a}, want ~${b})`);
}

const SEEDS = 5000;
// Floating point: a lightness gap of exactly minLumGap is built by addition,
// so allow it to land a few ulps short.
const EPS = 1e-9;

// --- harmony ---------------------------------------------------------------
{
  let worstHue = Infinity, worstLum = Infinity, worstDist = Infinity;
  for (let seed = 1; seed <= SEEDS; seed++) {
    const p = rollPalette(mulberry32(seed));
    if (p.length !== LAYOUT.zones) { check(false, `seed ${seed}: wrong zone count`); break; }

    for (let i = 0; i < p.length; i++) {
      const c = p[i];
      if (!(c.h >= 0 && c.h < 360)) check(false, `seed ${seed}: hue ${c.h} out of 0..360`);
      if (c.s < HARMONY.sat[0] - EPS || c.s > HARMONY.sat[1] + EPS) {
        check(false, `seed ${seed}: saturation ${c.s} outside band`);
      }
      if (c.l < HARMONY.lum[0] - EPS || c.l > HARMONY.lum[1] + EPS) {
        check(false, `seed ${seed}: lightness ${c.l} outside band`);
      }
      for (let j = i + 1; j < p.length; j++) {
        worstHue = Math.min(worstHue, hueSeparation(c.h, p[j].h));
        worstLum = Math.min(worstLum, Math.abs(c.l - p[j].l));
        const a = hslToRgb(c.h, c.s, c.l), b = hslToRgb(p[j].h, p[j].s, p[j].l);
        worstDist = Math.min(worstDist,
          Math.max(Math.abs(a[0] - b[0]), Math.abs(a[1] - b[1]), Math.abs(a[2] - b[2])));
      }
    }
  }
  check(worstHue >= HARMONY.minSeparationDeg - EPS,
    `closest hue pair over ${SEEDS} seeds was ${worstHue.toFixed(1)}deg, floor is ${HARMONY.minSeparationDeg}`);
  check(worstLum >= HARMONY.minLumGap - EPS,
    `closest lightness pair was ${worstLum}, floor is ${HARMONY.minLumGap}`);
  // The point of all of the above: the three LEDs must be TELLABLE APART as
  // 8-bit colours, which is the only form the badge ever sees.
  check(worstDist >= 24,
    `closest pair of landed colours differed by only ${worstDist}/255 on its widest channel`);
  console.log(`  harmony: worst hue ${worstHue.toFixed(1)}deg, worst lum ${worstLum.toFixed(3)}, worst channel ${worstDist}/255`);
}

// --- zone order ------------------------------------------------------------
//
// The contract game.js tintedSheet reads the palette under: zone index is LED
// index, and the renderer takes LED 0 as the creature's ink, LED 1 as its fill
// and LED 2 as its accent WITHOUT looking at the colours. That only produces a
// creature whose outline is darker than its body if the roll hands them over
// in that order, so the ordering is asserted here, at the source, rather than
// repaired downstream.
//
// Asserted in LUMINANCE, not in the HSL `l` the ladder above is drawn in. The
// two orderings genuinely disagree — 709 weights green ten times as heavily as
// blue — and it is luminance that decides whether an outline reads as one. An
// earlier attempt at this ordered by `l` and passed here while leaving roughly
// a third of creatures inverted on screen; tint_harness caught it.
//
// The hue check is the other half, and it is what stops this being "fixed" by
// sorting harder: which end of the palette leads is a contract, which HUE
// leads is luck. If an edit ever pinned hue to zone, every badge would wear
// the same colour in the same lamp and the roll would mean nothing. Note this
// asserts hue is not FIXED by position, not that it is uncorrelated with it:
// luminance is hue-dependent, so blues really do drift towards zone 0.
{
  let ascending = 0;
  // Which zone holds the smallest / middle / largest hue, as a "012"-style
  // key. All six orderings must show up, or hue has become positional.
  const hueOrders = new Set();
  for (let seed = 1; seed <= SEEDS; seed++) {
    const p = rollPalette(mulberry32(seed));
    const lum = p.map((c) => luminance(hslToRgb(c.h, c.s, c.l)));
    if (lum[0] <= lum[1] && lum[1] <= lum[2]) ascending++;
    hueOrders.add(
      [...p.keys()].sort((a, b) => p[a].h - p[b].h).join(""));
  }
  check(ascending === SEEDS,
    `${SEEDS - ascending} of ${SEEDS} rolls were not ascending in luminance ` +
    `by zone; game.js tintedSheet reads zone order as ink, fill, accent`);
  check(hueOrders.size === 6,
    `hue landed in only ${hueOrders.size} of the 6 possible zone orderings, ` +
    `so hue has become a function of position`);
  console.log(`  order: ${ascending}/${SEEDS} ascending in luminance, ` +
    `hue in all ${hueOrders.size} orderings`);
}

// --- determinism -----------------------------------------------------------
{
  const a = JSON.stringify(rollPalette(mulberry32(12345)));
  const b = JSON.stringify(rollPalette(mulberry32(12345)));
  eq(a, b, "same seed rolls the same palette");
  const c = JSON.stringify(rollPalette(mulberry32(12346)));
  check(a !== c, "different seeds roll different palettes");
}

// --- wire form -------------------------------------------------------------
{
  for (let seed = 1; seed <= 200; seed++) {
    const hex = paletteHex(rollPalette(mulberry32(seed)));
    eq(hex.length, LAYOUT.zones, `seed ${seed}: hex colour count`);
    for (const h of hex) {
      check(/^[0-9a-f]{6}$/.test(h), `seed ${seed}: '${h}' is not the rrggbb the firmware parses`);
    }
  }
  // Anchors, so a rewrite of hslToRgb has to stay honest.
  eq(rgbToHex(hslToRgb(0, 1, 0.5)), "ff0000", "red");
  eq(rgbToHex(hslToRgb(120, 1, 0.5)), "00ff00", "green");
  eq(rgbToHex(hslToRgb(240, 1, 0.5)), "0000ff", "blue");
  eq(rgbToHex(hslToRgb(0, 0, 0)), "000000", "black");
  eq(rgbToHex(hslToRgb(0, 0, 1)), "ffffff", "white");
  eq(rgbToHex(hslToRgb(-120, 1, 0.5)), "0000ff", "negative hue wraps");
  eq(rgbToHex(hslToRgb(600, 1, 0.5)), "0000ff", "hue past 360 wraps");
}

// --- spin ------------------------------------------------------------------
{
  near(easeOutQuint(0), 0, 0, "ease starts at 0");
  near(easeOutQuint(1), 1, 0, "ease ends at 1");

  for (let seed = 1; seed <= 500; seed++) {
    const rand = mulberry32(seed);
    const target = rollPalette(rand);
    const spin = makeSpin(rand, target);

    // THE invariant: what the LEDs settle on is what gets banked. The wobble
    // is damped by (1-p)^2, so it must be exactly zero at the landing — not
    // small, zero, or the saved colour differs from the shown one.
    for (let i = 0; i < spin.length; i++) {
      const end = spinSample(spin[i], spin[i].duration);
      near(end.h, target[i].h, 1e-9, `seed ${seed} zone ${i}: lands on target hue`);
      near(end.s, target[i].s, 1e-12, `seed ${seed} zone ${i}: lands on target saturation`);
      near(end.l, target[i].l, 1e-12, `seed ${seed} zone ${i}: lands on target lightness`);
    }
    // ...and stays there, since the render keeps sampling after the landing
    // while the flash save runs.
    const late = spinColors(spin, 60);
    for (let i = 0; i < spin.length; i++) {
      near(late[i].h, target[i].h, 1e-9, `seed ${seed} zone ${i}: stays put after landing`);
    }

    // Nothing goes NaN or leaves the representable range mid-sweep.
    for (let t = 0; t <= 4; t += 0.05) {
      for (const z of spin) {
        const c = spinSample(z, t);
        check(Number.isFinite(c.h) && c.h >= 0 && c.h < 360, `seed ${seed}: hue ${c.h} at t=${t}`);
        check(c.s >= 0 && c.s <= 1 && c.l >= 0 && c.l <= 1, `seed ${seed}: s/l out of range at t=${t}`);
      }
    }

    // Zones land at different times, or the three "stop" as one and the whole
    // effect reads as a single fade.
    const durations = spin.map((z) => z.duration);
    check(new Set(durations).size === durations.length, `seed ${seed}: zones land together`);
    check(!spinDone(spin, Math.min(...durations) - 1e-6), `seed ${seed}: done before the slowest zone`);
    check(spinDone(spin, Math.max(...durations)), `seed ${seed}: done once all zones land`);
  }
}

// --- layout ----------------------------------------------------------------
{
  let x = 0, total = 0;
  for (let i = 0; i < LAYOUT.zones; i++) {
    const r = zoneRect(i);
    eq(r.x, x, `zone ${i} starts where zone ${i - 1} ended`);
    check(r.w > 0, `zone ${i} has width`);
    x = r.x + r.w;
    total += r.w;
  }
  eq(total, LAYOUT.screen.w, "the zones tile the screen exactly");
}

if (failures === 0) console.log(`OK  palette: harmony over ${SEEDS} seeds, spin landing, wire form`);
else console.log(`FAIL: ${failures} palette checks failed`);
process.exit(failures === 0 ? 0 : 1);
