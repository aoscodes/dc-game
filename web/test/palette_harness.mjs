// Harness for the badge palettes (web/palette.js) and the onboarding spin
// (web/onboard.js).
//
// Unlike its neighbours this one mirrors no Zig code. It is here because the
// palette rules are *statistical*: a roll is only correct if it is correct for
// every seed, and a rule that holds for the nine rolls you tried by hand will
// still, one evening, hand a player three identical muddy browns on a badge
// whose flash then has to be rewritten by unplugging it.
//
// So: the invariants that make a triad legible — pairwise hue separation,
// saturation and lightness bands, distinct lightness steps — are asserted over
// thousands of reproducible seeds, for BOTH palettes. The spin is checked for
// the one property that actually matters downstream: it lands EXACTLY on the
// colour that gets written to flash, so the LEDs never settle on a colour
// different from the saved one.
//
// Functions are extracted by name, same as the other harnesses, so palette.js
// and onboard.js stay plain browser scripts with no module system.
import { readFileSync } from "node:fs";

const palette = readFileSync(new URL("../palette.js", import.meta.url), "utf8");
const onboard = readFileSync(new URL("../onboard.js", import.meta.url), "utf8");

/** Slice out `function NAME(...) { ... }` by brace matching. */
function extract(src, name) {
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

// palette.js first, and its constants before its functions: onboard.js's
// LAYOUT reads PALETTE_SIZE at definition time, exactly as the browser does.
const PALETTE_CONSTS = ["PALETTE_SIZE", "HUE_SCHEMES", "HARMONY", "BABY_HARMONY"];
const PALETTE_NAMES = [
  "hslToRgb", "rgbToHex", "luminance", "wrapHue", "hueDelta", "hueSeparation",
  "mulberry32", "randRange", "randInt", "shuffle", "rollHarmonic",
  "rollPalette", "rollBroodPalette",
];
const ONBOARD_CONSTS = ["LAYOUT", "SPIN"];
const ONBOARD_NAMES = [
  "easeOutQuint", "makeNoise", "makeSpin", "spinSample", "spinColors",
  "spinDone", "paletteHex", "zoneRect",
];

const NAMES = [...PALETTE_NAMES, ...ONBOARD_NAMES];
const CONSTS = [...PALETTE_CONSTS, ...ONBOARD_CONSTS];

const api = new Function(`
  ${PALETTE_CONSTS.map((n) => extractConst(palette, n)).join("\n")}
  ${PALETTE_NAMES.map((n) => extract(palette, n)).join("\n")}
  ${ONBOARD_CONSTS.map((n) => extractConst(onboard, n)).join("\n")}
  ${ONBOARD_NAMES.map((n) => extract(onboard, n)).join("\n")}
  return { ${NAMES.join(", ")}, ${CONSTS.join(", ")} };
`)();

const {
  hslToRgb, rgbToHex, luminance, hueSeparation, mulberry32, rollPalette,
  rollBroodPalette, easeOutQuint, makeSpin, spinSample, spinColors, spinDone,
  paletteHex, zoneRect, LAYOUT, HARMONY, BABY_HARMONY, PALETTE_SIZE,
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
//
// Run twice, over the same seeds, for the two palettes: the ADULT one the
// kiosk spins onto a badge's LEDs, and the BROOD one the game rolls from that
// badge's seed to dress its babies.  Same rules, different bands — see
// BABY_HARMONY in palette.js for why saturation is the axis that separates
// them — so the assertions are shared and the bands come from whichever
// harmony is under test.
//
// @param {string} label which palette, for the failure text
// @param {(seed: number) => {h,s,l}[]} roll
// @param {typeof HARMONY} harmony the bands it claims to obey
// @param {number} minChannel how far apart two colours must land, per the
//   widest 8-bit channel, to be tellable apart on the medium that shows them
// @returns {{sat: [number, number]}} the saturation range actually observed
function checkHarmony(label, roll, harmony, minChannel) {
  let worstHue = Infinity, worstLum = Infinity, worstDist = Infinity;
  let satLo = Infinity, satHi = -Infinity;
  for (let seed = 1; seed <= SEEDS; seed++) {
    const p = roll(seed);
    if (p.length !== PALETTE_SIZE) { check(false, `${label} seed ${seed}: wrong colour count`); break; }

    for (let i = 0; i < p.length; i++) {
      const c = p[i];
      if (!(c.h >= 0 && c.h < 360)) check(false, `${label} seed ${seed}: hue ${c.h} out of 0..360`);
      if (c.s < harmony.sat[0] - EPS || c.s > harmony.sat[1] + EPS) {
        check(false, `${label} seed ${seed}: saturation ${c.s} outside band`);
      }
      if (c.l < harmony.lum[0] - EPS || c.l > harmony.lum[1] + EPS) {
        check(false, `${label} seed ${seed}: lightness ${c.l} outside band`);
      }
      satLo = Math.min(satLo, c.s); satHi = Math.max(satHi, c.s);
      for (let j = i + 1; j < p.length; j++) {
        worstHue = Math.min(worstHue, hueSeparation(c.h, p[j].h));
        worstLum = Math.min(worstLum, Math.abs(c.l - p[j].l));
        const a = hslToRgb(c.h, c.s, c.l), b = hslToRgb(p[j].h, p[j].s, p[j].l);
        worstDist = Math.min(worstDist,
          Math.max(Math.abs(a[0] - b[0]), Math.abs(a[1] - b[1]), Math.abs(a[2] - b[2])));
      }
    }
  }
  check(worstHue >= harmony.minSeparationDeg - EPS,
    `${label}: closest hue pair over ${SEEDS} seeds was ${worstHue.toFixed(1)}deg, floor is ${harmony.minSeparationDeg}`);
  check(worstLum >= harmony.minLumGap - EPS,
    `${label}: closest lightness pair was ${worstLum}, floor is ${harmony.minLumGap}`);
  // The point of all of the above: the three colours must be TELLABLE APART
  // as 8-bit values, which is the only form anything downstream ever sees.
  check(worstDist >= minChannel,
    `${label}: closest pair of landed colours differed by only ${worstDist}/255 on its widest channel`);
  console.log(`  harmony ${label}: worst hue ${worstHue.toFixed(1)}deg, worst lum ${worstLum.toFixed(3)}, worst channel ${worstDist}/255`);
  return { sat: [satLo, satHi] };
}

// The badge's three LEDs are a few millimetres apart behind one diffuser, so
// this is the tighter bar of the two.
const adultSat = checkHarmony("adult", (s) => rollPalette(mulberry32(s)), HARMONY, 24).sat;
// Babies hold the SAME floor despite being desaturated, which is worth
// naming: desaturating necessarily pulls the channels together, so this was
// the bound expected to give. It does not, because BABY_HARMONY widens the
// lightness ladder to pay for exactly that, and the ladder is where most of
// this distance comes from — the observed worst case is 35/255. Holding the
// two palettes to one number keeps that trade honest: narrow the baby
// lightness band back toward the adults' and this fails here rather than on
// the screen.
const babySat = checkHarmony("brood", rollBroodPalette, BABY_HARMONY, 24).sat;

// --- adults vs babies ------------------------------------------------------
//
// The reason BABY_HARMONY exists at all: a player has to be able to pick their
// own adult out of a screenful of creatures, and to see at a glance which of
// the small ones are theirs. If the two bands overlapped, a desaturated adult
// and a saturated baby would land in the same colours and the distinction
// would be decorative rather than real.
//
// Asserted on the OBSERVED range rather than the declared band, so that this
// fails if a roll ever escapes its bounds in a way the per-seed checks above
// somehow let through, and asserted with a margin rather than at touching, so
// the two are separated by daylight and not by a rounding accident.
{
  check(babySat[1] < adultSat[0] - 0.1,
    `baby saturations reach ${babySat[1].toFixed(3)} and adult saturations ` +
    `start at ${adultSat[0].toFixed(3)}: the two palettes are not visibly ` +
    `distinct, so a player cannot tell their brood from someone's adult`);
  console.log(`  bands: brood sat ${babySat[0].toFixed(2)}..${babySat[1].toFixed(2)}, ` +
    `adult sat ${adultSat[0].toFixed(2)}..${adultSat[1].toFixed(2)}`);
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

// --- brood ordering and determinism ----------------------------------------
//
// The brood palette is never stored — not in the badge's flash, not on the
// server, not in the frame. It is rolled from the seed on every client that
// draws that badge's babies, so "same seed, same colours" is not a nicety, it
// is the only thing making two screens agree about one player's family.
{
  let ascending = 0;
  for (let seed = 1; seed <= SEEDS; seed++) {
    const p = rollBroodPalette(seed);
    const lum = p.map((c) => luminance(hslToRgb(c.h, c.s, c.l)));
    if (lum[0] <= lum[1] && lum[1] <= lum[2]) ascending++;
  }
  check(ascending === SEEDS,
    `${SEEDS - ascending} of ${SEEDS} brood rolls were not ascending in ` +
    `luminance; game.js tintedSheet reads index order as ink, fill, accent`);

  const a = JSON.stringify(rollBroodPalette(0xdeadbeef));
  eq(a, JSON.stringify(rollBroodPalette(0xdeadbeef)),
    "the same brood seed rolls the same palette");
  check(a !== JSON.stringify(rollBroodPalette(0xdeadbef0)),
    "neighbouring brood seeds roll different palettes");

  // Zero is a seed like any other, not an absence: the board derives it from
  // its flash uid, so there is no "unset" value for it to collide with. The
  // wire keeps a presence flag for exactly this reason (protocol.zig
  // Appearance.brood_seed), and this pins that the roll itself has no opinion.
  check(rollBroodPalette(0).length === PALETTE_SIZE,
    "a brood seed of zero rolls a real palette");
  // The top of the u32 range, where a seed that arrived through JSON as a
  // signed number would land. mulberry32 coerces with >>> 0, so both spellings
  // of the same bits must roll the same family.
  eq(JSON.stringify(rollBroodPalette(0xffffffff)),
    JSON.stringify(rollBroodPalette(-1)),
    "a brood seed read back as a negative rolls the same palette");
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

if (failures === 0) console.log(`OK  palette: adult + brood harmony over ${SEEDS} seeds, spin landing, wire form`);
else console.log(`FAIL: ${failures} palette checks failed`);
process.exit(failures === 0 ? 0 : 1);
