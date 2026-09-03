#!/usr/bin/env python3
"""Convert the authored critter art into the web client's atlases.

    python3 scripts/gen_lilguys.py           # write
    python3 scripts/gen_lilguys.py --check   # verify; write nothing

Input:  ../board/src/render/assets/art/{adults,babies}/*.bmp
        The SAME 5-tone masters the e-paper board consumes.  They are the
        single source of truth for what a critter looks like and are never
        edited here.  board/tools/pixelart.py is imported rather than
        re-implemented: a second copy of the tone table is a second thing to
        forget to update, and its reader is STRICT, so art that drifts off
        the palette fails here too instead of only on the badge.

Output: ../web/assets/lilguy_{rose,mint,sky,gold,plum}.png + .json
        ../web/assets/babies.png + .json

## One sheet per critter

The board picks ONE resident adult per badge (store.h critter_of) and now
reports it, so the game draws each player's own creature instead of a shared
generic one.  Five separate sheets rather than one indexed sheet because
web/game.js already keys sprites by CLASS NAME (drawSprite's `kind`), so the
critter type slots into an axis the animator already has - no new parameter
threaded through the shared draw path that the slime and the brood also use.

Each sheet is 6x2 frames of 96x96: row 0 idle (5 frames, the 6th column
unused), row 1 eat (6 frames).  hurt and die alias the idle row, as they did
before this art existed - tickAnimator switches clips on `last_action` and
wedges on an absent one, so every clip a caller can name must resolve.

## The tones survive into the PNG

The greys are NOT flattened to a picture here.  Each of the five authored
levels ships as its own flat RGB value and the json says which is which, so
the client can substitute three of them for the colours a badge chose on the
/onboard screen (see web/game.js recolourLilGuy).  Writing a pre-shaded
picture instead would mean five colour variants x five critters baked at
build time, or no recolouring at all.

`shadow_ratio` travels with them because the client DERIVES the shadow from
whatever replaced the fill, rather than being told a fourth colour.  Emitting
the authored ratio means re-toning the art re-tunes the client for free; a
constant hardcoded over there would quietly stop matching the art.

## Paper is transparent everywhere, including where it is enclosed

Some poses seal a gap in the line work (an ear notch, the crook of a horn)
and some open the same gap to the outside - it moves frame to frame as the
creature shuffles.  A flood fill would therefore make those pixels flicker
between opaque and see-through several times a second, which is far more
visible than what transparency actually costs: the field behind them is
LAYOUT.slimeField.paper, the same near-white the author drew, so on the field
the two are indistinguishable.  Only a guy briefly standing ON the grid (a
newborn, before it walks to its post) shows a tile through those few pixels.

This is also why there is no body reconstruction.  The predecessor script
flood-filled a silhouette out of 1bpp line art and needed a morphological
close to stop the fill leaking through a stippled outline.  This art has an
authored fill tone, so the body is simply drawn.

Stdlib only; no Pillow.
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
BOARD_TOOLS = os.path.join(HERE, "..", "..", "board", "tools")
sys.path.insert(0, BOARD_TOOLS)

import pixelart  # noqa: E402  (needs the path above)

ART = os.path.join(HERE, "..", "..", "board", "src", "render", "assets", "art")
ADULT_DIR = os.path.join(ART, "adults")
BABY_DIR = os.path.join(ART, "babies")
OUT_DIR = os.path.join(HERE, "..", "web", "assets")

# BabyType ordinal order (shared/components.zig, web/game.js BABY_TYPES).
TYPES = ["rose", "mint", "sky", "gold", "plum"]

ADULT = 96
ADULT_IDLE_FRAMES = 5
ADULT_EAT_FRAMES = 6
BABY = 32
BABY_IDLE_FRAMES = 5

# Row 0 idle, row 1 eat. `frames` is how many columns of that row are real;
# fps and loop are the client's animator contract (web/game.js tickAnimator).
#
# attack is the authored eat cycle. hurt and die have no authored art and
# alias idle, faster: an unresolvable clip name wedges the animator, so every
# action the server can report must land somewhere.
CLIPS = {
    "idle":   {"row": 0, "frames": ADULT_IDLE_FRAMES, "fps": 6,  "loop": True},
    "attack": {"row": 1, "frames": ADULT_EAT_FRAMES,  "fps": 12, "loop": False},
    "hurt":   {"row": 0, "frames": ADULT_IDLE_FRAMES, "fps": 10, "loop": False},
    "die":    {"row": 0, "frames": ADULT_IDLE_FRAMES, "fps": 8,  "loop": False},
}

# Authored tone -> the flat RGB it ships as, and the role name the client
# addresses it by. The greys are emitted AS the authored values: an
# un-onboarded badge (store.h led_rgb all zero) has no colours to substitute,
# and the art already reads on the client's near-white field, so the honest
# default is simply the art.
TONE_ROLES = [
    ("ink", pixelart.TONE_INK),
    ("shadow", pixelart.TONE_SHADOW),
    ("fill", pixelart.TONE_FILL),
    ("accent", pixelart.TONE_ACCENT),
    ("prop", pixelart.TONE_PROP),
]

TRANSPARENT = (0, 0, 0, 0)


def rgba(tone: int) -> tuple[int, int, int, int]:
    """One authored grey as an opaque neutral RGBA; paper as transparent."""
    if tone == pixelart.TONE_PAPER:
        return TRANSPARENT
    return (tone, tone, tone, 255)


# ---------------------------------------------------------------------------
# Minimal pure-stdlib RGBA PNG writer
# ---------------------------------------------------------------------------


def _png_chunk(chunk_type: bytes, data: bytes) -> bytes:
    c = chunk_type + data
    return (struct.pack(">I", len(data)) + c
            + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF))


def png_bytes(width: int, height: int, pixels) -> bytes:
    """An RGBA PNG from a 2-D list of (r,g,b,a) tuples."""
    raw = bytearray()
    for row in pixels:
        raw.append(0)  # filter: None
        for r, g, b, a in row:
            raw += bytes((r, g, b, a))
    return (b"\x89PNG\r\n\x1a\n"
            + _png_chunk(b"IHDR",
                         struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + _png_chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + _png_chunk(b"IEND", b""))


def _blit(canvas, frame, col: int, row: int, size: int) -> None:
    for y in range(size):
        for x in range(size):
            canvas[row * size + y][col * size + x] = rgba(frame[y][x])


# ---------------------------------------------------------------------------
# Sheets
# ---------------------------------------------------------------------------


def _read(path: str, size: int, count: int):
    _w, _h, tones = pixelart.read_bmp16_tones(path, expect=(size * count, size))
    return pixelart.split_frames(tones, size, count)


def adult_sheet(name: str) -> tuple[bytes, dict]:
    idle = _read(
        os.path.join(ADULT_DIR,
                     f"adult_{name}_idle_{ADULT}x{ADULT}x{ADULT_IDLE_FRAMES}.bmp"),
        ADULT, ADULT_IDLE_FRAMES)
    eat = _read(
        os.path.join(ADULT_DIR,
                     f"adult_{name}_eat_{ADULT}x{ADULT}x{ADULT_EAT_FRAMES}.bmp"),
        ADULT, ADULT_EAT_FRAMES)

    cols = max(ADULT_IDLE_FRAMES, ADULT_EAT_FRAMES)
    w, h = ADULT * cols, ADULT * 2
    canvas = [[TRANSPARENT] * w for _ in range(h)]
    for i, f in enumerate(idle):
        _blit(canvas, f, i, 0, ADULT)
    for i, f in enumerate(eat):
        _blit(canvas, f, i, 1, ADULT)

    meta = {
        "frame_w": ADULT,
        "frame_h": ADULT,
        "clips": CLIPS,
        # The client substitutes ink/fill/accent and derives shadow; prop is
        # the food and is never recoloured.
        "tones": {role: list(rgba(t)[:3]) for role, t in TONE_ROLES},
        "shadow_ratio": pixelart.TONE_SHADOW / pixelart.TONE_FILL,
    }
    return png_bytes(w, h, canvas), meta


def baby_sheet() -> tuple[bytes, dict]:
    """One row of five 32x32 stills, index = BabyType ordinal.

    Frame 0 only. The babies have an authored idle cycle too, but the client
    draws them as bobbing stills (web/game.js drawBabies) rather than through
    the animator, and shipping four unused frames per type to keep the sheets
    looking symmetrical would be flash spent on nothing. The json keeps the
    name -> index map so the draw site never learns the atlas order.
    """
    w, h = BABY * len(TYPES), BABY
    canvas = [[TRANSPARENT] * w for _ in range(h)]
    for i, name in enumerate(TYPES):
        frames = _read(
            os.path.join(BABY_DIR,
                         f"baby_{name}_idle_{BABY}x{BABY}x{BABY_IDLE_FRAMES}.bmp"),
            BABY, BABY_IDLE_FRAMES)
        _blit(canvas, frames[0], i, 0, BABY)
    # Same legend as the adults, and the same substitution: a baby wears the
    # palette of the BADGE THAT BROUGHT IT, rolled from that badge's brood
    # seed (web/palette.js rollBroodPalette) rather than from its LEDs. The
    # seed is per badge, so one player's babies are a matching set.
    #
    # Babies with no badge behind them - the ones hatched at the table - keep
    # the authored greys, which is what the client draws for a null palette.
    meta = {
        "frame_w": BABY,
        "frame_h": BABY,
        "frames": {name: i for i, name in enumerate(TYPES)},
        "tones": {role: list(rgba(t)[:3]) for role, t in TONE_ROLES},
        "shadow_ratio": pixelart.TONE_SHADOW / pixelart.TONE_FILL,
    }
    return png_bytes(w, h, canvas), meta


def build() -> dict[str, bytes]:
    """emitted filename -> bytes, for both writing and --check."""
    out: dict[str, bytes] = {}
    for name in TYPES:
        png, meta = adult_sheet(name)
        out[f"lilguy_{name}.png"] = png
        out[f"lilguy_{name}.json"] = _json(meta)
    png, meta = baby_sheet()
    out["babies.png"] = png
    out["babies.json"] = _json(meta)
    return out


def _json(meta: dict) -> bytes:
    return (json.dumps(meta, indent=2) + "\n").encode()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true",
                    help="verify the committed atlases match the masters; "
                         "write nothing")
    args = ap.parse_args()

    assets = build()
    os.makedirs(OUT_DIR, exist_ok=True)
    stale: list[str] = []
    for name, data in sorted(assets.items()):
        path = os.path.join(OUT_DIR, name)
        if args.check:
            try:
                with open(path, "rb") as f:
                    current = f.read()
            except FileNotFoundError:
                current = None
            if current != data:
                stale.append(name)
            continue
        with open(path, "wb") as f:
            f.write(data)
        print(f"wrote {name}")

    if args.check:
        if stale:
            print("stale or missing (run scripts/gen_lilguys.py):",
                  file=sys.stderr)
            for name in stale:
                print(f"  {name}", file=sys.stderr)
            return 1
        print(f"gen_lilguys: {len(assets)} assets up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
