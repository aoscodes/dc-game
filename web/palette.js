// Colour maths and palette rolling, shared by the onboarding kiosk and the
// game renderer.
//
// This file exists because a badge's colours are decided in TWO places that
// must agree:
//
//   - /onboard (web/onboard.js) rolls the ADULT palette, streams it to the
//     badge's three LEDs, and banks it in the badge's flash.  Those colours
//     then travel back as CTRL:STAT led= and dress that player's Lil Guy.
//   - the game (web/game.js) rolls the BROOD palette, from the seed the badge
//     derives off its flash uid (CTRL:STAT seed=), and dresses that player's
//     BABY Lil Guys in it.
//
// The second one is never stored anywhere.  That is the whole trick: a seed is
// four bytes on the wire and nothing in flash, and the badge has no reason to
// hold an opinion about the shade because its own panel is 1bpp.  So the roll
// has to be reproducible from the seed alone, which makes the roll itself the
// contract — and a contract with two callers belongs in one file.
//
// Loaded as a plain script before its callers on both pages; everything here
// is a top-level global, same as the rest of web/.  No DOM, no state, no
// clock: given the same seed this file produces the same colours forever.
//
// Extracted by name in web/test/palette_harness.mjs.

// ---------------------------------------------------------------------------
// Colour
// ---------------------------------------------------------------------------

/**
 * HSL -> 8-bit RGB.  Hue in degrees (any range, wrapped), s/l in 0..1.
 * @returns {number[]} [r, g, b], each 0..255
 */
function hslToRgb(h, s, l) {
  const hp = ((((h % 360) + 360) % 360)) / 60;
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs((hp % 2) - 1));
  const m = l - c / 2;
  let r = 0, g = 0, b = 0;
  if (hp < 1) { r = c; g = x; }
  else if (hp < 2) { r = x; g = c; }
  else if (hp < 3) { g = c; b = x; }
  else if (hp < 4) { g = x; b = c; }
  else if (hp < 5) { r = x; b = c; }
  else { r = c; b = x; }
  return [
    Math.round((r + m) * 255),
    Math.round((g + m) * 255),
    Math.round((b + m) * 255),
  ];
}

/**
 * Rec. 709 relative luminance of an [r,g,b], 0..255.
 *
 * THE axis a palette is ordered in (see rollHarmonic), and deliberately not
 * HSL lightness, which is the axis the harmony bounds are drawn in. The two
 * are not the same ordering and swapping them is not a detail: 709 weights
 * green at 0.7152 and blue at 0.0722, so a blue at l=0.62 comes out darker to
 * the eye than a green at l=0.42. Ordering by `l` would put that blue last and
 * hand the creature a pale outline over a dark body — the exact inversion the
 * ordering exists to prevent. `l` still does its own job: it is what the LED
 * spacing (minLumGap) is tuned for, and spacing is order-free.
 */
function luminance([r, g, b]) {
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/** [r,g,b] -> "rrggbb", the wire form the firmware parses. */
function rgbToHex(rgb) {
  return rgb.map((v) => Math.max(0, Math.min(255, v)).toString(16).padStart(2, "0")).join("");
}

/** Fold any hue onto 0..360. */
function wrapHue(h) {
  return ((h % 360) + 360) % 360;
}

/**
 * Signed shortest way round the colour wheel from `a` to `b`, in -180..180.
 * Used so a zone's final approach drifts the short way into its target
 * instead of doubling back across the wheel.
 */
function hueDelta(a, b) {
  return ((wrapHue(b - a) + 540) % 360) - 180;
}

/** Distance between two hues ignoring direction, 0..180. */
function hueSeparation(a, b) {
  return Math.abs(hueDelta(a, b));
}

// ---------------------------------------------------------------------------
// Randomness
// ---------------------------------------------------------------------------

/**
 * Small seedable PRNG.  Seeded rather than Math.random so the harness can
 * assert the harmony invariants over thousands of reproducible rolls — a
 * palette rule that holds "usually" is a palette rule that will eventually
 * hand a player three muddy browns.
 *
 * Also used for effects that just need a stable per-thing wobble (game.js
 * seeds it from a cell's flat index), which is the other half of why it lives
 * here rather than beside the palettes.
 * @param {number} seed
 * @returns {() => number} uniform in [0, 1)
 */
function mulberry32(seed) {
  let a = seed >>> 0;
  return function next() {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Uniform in [lo, hi). */
function randRange(rand, lo, hi) {
  return lo + rand() * (hi - lo);
}

/** Uniform integer in [lo, hi]. */
function randInt(rand, lo, hi) {
  return lo + Math.floor(rand() * (hi - lo + 1));
}

/** Fisher-Yates, in place, returning the same array. */
function shuffle(rand, arr) {
  for (let i = arr.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    const t = arr[i]; arr[i] = arr[j]; arr[j] = t;
  }
  return arr;
}

// ---------------------------------------------------------------------------
// Harmony
// ---------------------------------------------------------------------------

/**
 * How many colours a palette has.
 *
 * Three, and not by coincidence: it is the badge's LED count, and it is the
 * number of recolourable tones in a Lil Guy (ink, fill, accent — see game.js
 * tintedSheet). The adult palette is literally the same three values doing
 * both jobs, so the two counts are one constant.
 */
const PALETTE_SIZE = 3;

/**
 * Hue offsets from a random base.  Classical schemes; the tightest pair in
 * the table is split-complementary's 150/210, 60 degrees apart.  Shared by
 * both harmonies below — what separates adults from babies is saturation, not
 * which shapes the wheel is cut into.
 */
const HUE_SCHEMES = [
  [0, 120, 240], // triadic
  [0, 150, 210], // split-complementary
  [0, 90, 180],  // tetradic, three of four
];

/**
 * The rules a landed ADULT palette must satisfy.  These are not decoration:
 * three colours picked independently at random are, more often than not, ugly
 * and — worse on a badge with three small LEDs a few millimetres apart —
 * indistinguishable.  Every bound here is defending one of those two failures.
 */
const HARMONY = {
  schemes: HUE_SCHEMES,
  // Enough wobble that repeat rolls of one scheme do not look identical, small
  // enough that the scheme is still recognisable.
  hueJitterDeg: 8,
  // The floor the harness asserts, and it is TIGHT: the worst case is that
  // 60-degree pair jittered apart in opposite directions, 60 - 2*8 = 44, which
  // is what the harness actually observes. Widening the jitter or adding a
  // closer scheme breaks this immediately — which is the point of asserting it
  // rather than trusting the arithmetic to survive the next edit.
  minSeparationDeg: 44,
  // Saturated enough to read as a colour on a diffused LED, short of the
  // full-blast primaries that all look like "on".
  sat: [0.62, 0.88],
  // Kept off both ends: near-black loses the hue, near-white washes it out.
  lum: [0.42, 0.62],
  // Three colours of equal lightness read as one smear at a glance, so the
  // three are forced onto distinct steps.  2 * 0.08 fits inside the 0.20 band
  // above with room to spare, so this is always satisfiable.
  minLumGap: 0.08,
};

/**
 * The same rules for a badge's BABY Lil Guys, differing in exactly one band.
 *
 * The problem this solves: babies are drawn beside their owner's adult, and
 * the adult is the thing the player recognises themselves by. If the babies
 * were rolled from the same bands they would land in the same colour space,
 * and a screen of five families becomes a wash where nobody can find their
 * own creature, let alone tell an adult from its brood at a glance.
 *
 * SATURATION is the axis that separates them, and it is the right one:
 *
 *   - Hue cannot be it. The brood seed comes off the flash uid and the adult
 *     palette comes off the kiosk spin — they are independent, so any hue rule
 *     ("babies are the parent's hue, shifted") is unimplementable without one
 *     knowing about the other. Splitting the wheel into an adult half and a
 *     baby half would work but costs every family half its colours.
 *   - Lightness cannot be it. It is already spent: `lum` is the ladder that
 *     orders ink/fill/accent WITHIN a palette, and narrowing it to make room
 *     for a second band would flatten every creature it applies to.
 *
 * So: babies are the same hues, DESATURATED. They read as the pastel version
 * of the same palette space, which is both legible next to a saturated adult
 * and a fair description of a baby. The band is far enough below the adults'
 * 0.62 floor to leave a clear gap rather than abutting it, so no roll of one
 * can be mistaken for a roll of the other.
 *
 * THE LIGHTNESS LADDER IS WIDER HERE, and that is a consequence of the
 * desaturation rather than a second aesthetic choice. A creature reads as a
 * creature because its outline is visibly darker than its body, measured in
 * Rec. 709 luminance, and that separation comes from two sources: the `l`
 * rungs, and the fact that hues at the same `l` have different luminance.
 * Desaturating removes most of the second — at s=0 every hue has exactly
 * luminance `l` — so keeping the adults' band would leave babies with only
 * the rungs to work with. It does not merely reduce the margin: on the adult
 * band it produces a flat, unreadable brood about one roll in eight, against
 * one in a hundred for adults. Widening the ladder buys the lost spread back
 * (see web/test/tint_harness.mjs, which measures exactly this and is what
 * these numbers were fitted to).
 *
 * The band goes wider at BOTH ends rather than sliding, so babies stay
 * centred on the adults' range and read as the same family of colours.
 *
 * The badge's own LEDs never show these — a badge has three lamps and one
 * adult palette to put in them. This is screen-only, which is also why the
 * band may go places the adults' cannot: nothing here has to survive being
 * shone through a diffuser.
 */
const BABY_HARMONY = {
  schemes: HUE_SCHEMES,
  hueJitterDeg: HARMONY.hueJitterDeg,
  minSeparationDeg: HARMONY.minSeparationDeg,
  // The band the whole distinction rests on. Clear of the adults' [0.62,0.88]
  // with 0.14 of daylight between them, and off zero at the bottom so a baby
  // still has a hue rather than turning grey.
  sat: [0.28, 0.48],
  // Wider than the adults' [0.42, 0.62], for the reason above. Still off both
  // ends: 0.30 keeps the darkest rung a colour rather than a silhouette, and
  // 0.74 stops the lightest washing out to paper on a light background.
  lum: [0.30, 0.74],
  // Widened with the band, so the rungs stay proportionally spaced rather
  // than bunching at the bottom. 2 * 0.12 = 0.24 inside a 0.44 band, so this
  // is always satisfiable with slack to spare.
  minLumGap: 0.12,
};

/**
 * Roll one harmonic triad under the given bounds, DARKEST FIRST.
 *
 * The lightness step deserves a note: rather than resampling until three
 * independent draws happen to be far enough apart (unbounded, and biased
 * towards the extremes), it draws three sorted offsets from the SLACK left
 * over after reserving the gaps, then adds the gaps back. That is exactly
 * uniform over the valid orderings and cannot fail.
 *
 * The last thing this does, and the load-bearing one, is put the three in
 * order of how dark they actually look. INDEX IS ROLE, everywhere downstream:
 * game.js tintedSheet reads entry 0 as the creature's outline, 1 as its body,
 * 2 as its highlight, and for adults that index is also LED index the whole
 * way down (paletteHex, then LED:SET, then store.h led_rgb, then CTRL:STAT
 * led=). Two things follow, and both are the point:
 *
 *   - A badge means the same thing as every other badge. Its leftmost lamp is
 *     its creature's outline on the shared screen, on every badge in the room.
 *     Unordered, LED 0 was a different role per badge and the lamps taught the
 *     player nothing.
 *   - The outline is always darker than the body it bounds. A renderer handed
 *     the three in a random order gets that backwards about two times in three
 *     and the creature flattens into a blob, which is why game.js used to sort
 *     them itself. Ordering the palette where it is BORN serves both; sorting
 *     in the renderer could only ever serve the second.
 *
 * Ordered in `luminance`, NOT in the `l` the lightness ladder above is built
 * in — see that function for why the two disagree and why this is the one that
 * decides. A consequence worth naming: luminance is hue-dependent, so blues
 * drift towards the ink slot and greens towards the accent. That is not bias
 * to be corrected, it is what "darkest first" means when blue really is darker.
 *
 * Hue and saturation still shuffle, so the scheme's ROTATION carries no index
 * bias. That is the bias worth breaking: which hue leads should be luck, which
 * end of the palette leads is a contract.
 *
 * @param {() => number} rand
 * @param {typeof HARMONY} harmony bounds to roll within
 * @returns {{h: number, s: number, l: number}[]} PALETTE_SIZE entries,
 *   ascending in `luminance` — ink, fill, accent
 */
function rollHarmonic(rand, harmony) {
  const base = rand() * 360;
  const scheme = harmony.schemes[Math.floor(rand() * harmony.schemes.length)];
  const j = harmony.hueJitterDeg;
  const hues = scheme.map((off) => wrapHue(base + off + randRange(rand, -j, j)));

  const sats = hues.map(() => randRange(rand, harmony.sat[0], harmony.sat[1]));

  const [lo, hi] = harmony.lum;
  const gap = harmony.minLumGap;
  const slack = (hi - lo) - gap * (PALETTE_SIZE - 1);
  const offsets = [];
  for (let i = 0; i < PALETTE_SIZE; i++) offsets.push(rand());
  offsets.sort((a, b) => a - b);
  // Ascending, but only as a way to hand each entry a different rung: the sort
  // below is what actually decides which colour goes where.
  const lums = offsets.map((u, i) => lo + u * slack + i * gap);

  // Hue and saturation travel together — a jittered scheme offset and the
  // saturation drawn for it are a pair — so they shuffle as one unit.
  const tint = shuffle(rand, hues.map((h, i) => ({ h, s: sats[i] })));
  const triad = tint.map((t, i) => ({ h: t.h, s: t.s, l: lums[i] }));

  // Darkest first, in the axis the eye uses. See the note above.
  return triad.sort((a, b) =>
    luminance(hslToRgb(a.h, a.s, a.l)) - luminance(hslToRgb(b.h, b.s, b.l)));
}

/**
 * Roll the palette the onboarding kiosk spins towards: one badge's three LEDs
 * and, downstream, its adult Lil Guy.
 * @param {() => number} rand
 * @returns {{h: number, s: number, l: number}[]} darkest first
 */
function rollPalette(rand) {
  return rollHarmonic(rand, HARMONY);
}

/**
 * Roll the palette a badge's BABY Lil Guys wear, from that badge's brood seed.
 *
 * Takes the SEED rather than a `rand`, unlike its sibling, because that is the
 * whole interface: the seed arrives over the wire (CTRL:STAT seed= -> STAT:
 * seed= -> Appearance.brood_seed -> the render frame's `brood_seed`) and this
 * is the only thing that ever turns it into colours. Nothing between the badge
 * and here knows what the badge's babies look like, and nothing needs to.
 *
 * Per BADGE, not per baby: every baby a player brings wears these same three
 * colours, so a player's brood reads as one family and a stranger's reads as
 * another. Which of the five critter shapes each baby is remains its own
 * business — shape says species, colour says whose.
 *
 * Deterministic and pure, so it is safe to memoise on the seed (game.js does),
 * and stable across power cycles because the seed is derived from the badge's
 * flash uid alone (board/src/game/seed.c brood_seed_from_uid).
 *
 * @param {number} seed the badge's brood seed, a u32
 * @returns {{h: number, s: number, l: number}[]} darkest first
 */
function rollBroodPalette(seed) {
  return rollHarmonic(mulberry32(seed >>> 0), BABY_HARMONY);
}
