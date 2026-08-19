#!/usr/bin/env python3
"""Convert the authored Lil Guy spritesheet into the web client's asset pair.

Input:  ../../board/src/render/assets/spritesheets/lilguy_72x72x2.bmp
        A 1bpp, vertically-stacked BMP — the SAME file the e-paper board build
        consumes via board/tools/bmp2sprite.py.  That file is the single source
        of truth for what the Lil Guy looks like; it is never edited here.
Output: ../web/assets/lilguy.png  +  ../web/assets/lilguy.json

The two consumers want different things, which is why this script exists rather
than a copy of the bitmap:

  * the board packs 1bpp ink for a REFLECTIVE panel: the paper supplies the
    white, so only the black strokes need storing;
  * this client composites RGBA over a DARK field (LAYOUT.bg).  There is no
    paper behind it, so the white has to be drawn.  Painting only the strokes
    leaves an unreadable dark-on-dark figure; painting them white inverts it
    into a ghostly outline.  Both are wrong: the art is line work that assumes
    a white body.

So the body is reconstructed (see fill_body) and the sheet ships three states
per pixel: STROKE where the author drew ink, BODY for the enclosed area, and
fully transparent outside — the figure reads as a white creature with a black
outline over any background.

Sheet layout follows the client's atlas convention (see web/game.js drawSprite):
frames run left-to-right within a row, one row per clip.  The authored art has
exactly two frames and no per-action poses, so every clip aliases row 0: the
animator (tickAnimator) switches clips on `last_action` and would wedge on an
absent one, and a two-frame shuffle is a legible response to a feast.

Stdlib only; no Pillow.
"""

import json
import os
import struct
import zlib
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
SRC_BMP = os.path.join(
    HERE, "..", "..", "board", "src", "render", "assets", "spritesheets",
    "lilguy_72x72x2.bmp",
)
OUT_DIR = os.path.join(HERE, "..", "web", "assets")
NAME = "lilguy"

FRAME_W = 72
FRAME_H = 72
FRAMES = 2

# The authored strokes: black, as drawn.  Read as an outline against the body.
STROKE = (0, 0, 0, 255)
# The body the strokes enclose.  Faintly cool white, so the guys sit with the
# blue-grey UI text instead of glowing warmer than anything else on screen.
BODY = (238, 242, 250, 255)
# Outside the figure.  Fully transparent: the slime field shows through.
PAPER = (0, 0, 0, 0)

# Gap-bridging radius for fill_body, in pixels.  The authored outline is
# deliberately broken/stippled, so a plain flood fill of the background leaks
# through it and floods the body too.  1 is the smallest radius that seals every
# gap in this art; 2 visibly chamfers the skirt and fattens the antennae.
SEAL_R = 1

# Frame rates: idle is a slow shuffle; the one-shot clips are the same two
# frames played fast, so a feast reads as a lunge.
CLIPS = {
    "idle":   {"row": 0, "frames": FRAMES, "fps": 6,  "loop": True},
    "attack": {"row": 0, "frames": FRAMES, "fps": 12, "loop": False},
    "hurt":   {"row": 0, "frames": FRAMES, "fps": 10, "loop": False},
    "die":    {"row": 0, "frames": FRAMES, "fps": 8,  "loop": False},
}

# ---------------------------------------------------------------------------
# 1bpp BMP reader (mirrors board/tools/bmp2sprite.py's parse step)
# ---------------------------------------------------------------------------


def read_bmp_1bpp(path):
    """Return (width, height, rows) where rows is top-down, one str of '0'/'1'
    per row and '1' means INK (BMP palette index 0 = black)."""
    d = open(path, "rb").read()
    if d[:2] != b"BM":
        raise ValueError(f"{path}: not a BMP")
    (pix_off,) = struct.unpack_from("<I", d, 10)
    w, h = struct.unpack_from("<ii", d, 18)
    (bpp,) = struct.unpack_from("<H", d, 28)
    (comp,) = struct.unpack_from("<I", d, 30)
    if bpp != 1:
        raise ValueError(f"{path}: bpp={bpp}, only 1bpp supported")
    if comp != 0:
        raise ValueError(f"{path}: compression={comp}, only uncompressed")

    top_down = h < 0
    height = abs(h)
    packed = (w + 7) // 8
    stride = (packed + 3) // 4 * 4  # BMP rows pad to 4 bytes

    rows = []
    for r in range(height):
        raw = d[pix_off + r * stride:pix_off + r * stride + packed]
        # Invert: palette index 0 is black, and we want 1 = ink.
        bits = "".join(f"{(~b) & 0xFF:08b}" for b in raw)[:w]
        rows.append(bits)
    if not top_down:
        rows = rows[::-1]  # bottom-up -> top-down
    return w, height, rows


# ---------------------------------------------------------------------------
# Body reconstruction
# ---------------------------------------------------------------------------
#
# The board never needed this: paper is white by default there.  Here the body
# must be found explicitly, and a plain flood fill will not do it — the authored
# outline is stippled, so the background leaks inside and takes the body with it.
#
# Instead, close the outline before deciding what is outside:
#
#   1. DILATE the strokes by SEAL_R, bridging every gap;
#   2. flood the background of THAT thickened figure from the border — it cannot
#      leak, so what it does not reach is exactly the interior (plus the
#      SEAL_R-thick collar the dilation added);
#   3. ERODE by the same radius to give the collar back, restoring the true
#      silhouette.
#
# Steps 1-3 are a morphological closing; doing it as fill-then-erode rather than
# dilate-then-erode is what keeps genuine background — the gap between the legs,
# say — from being filled in as body.


def _neighborhood(r):
    """Offsets of a disc of radius r.  A disc, not a square: a square structuring
    element would bevel the silhouette's diagonals into staircases."""
    return [(dx, dy)
            for dy in range(-r, r + 1)
            for dx in range(-r, r + 1)
            if dx * dx + dy * dy <= r * r]


def _dilate(mask, w, h, r):
    out = [[False] * w for _ in range(h)]
    offs = _neighborhood(r)
    for y in range(h):
        for x in range(w):
            if not mask[y][x]:
                continue
            for dx, dy in offs:
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h:
                    out[ny][nx] = True
    return out


def _erode(mask, w, h, r):
    """Erosion as the dual of dilation: dilating the complement and inverting."""
    comp = [[not mask[y][x] for x in range(w)] for y in range(h)]
    grown = _dilate(comp, w, h, r)
    return [[not grown[y][x] for x in range(w)] for y in range(h)]


def _flood_outside(mask, w, h):
    """4-connected flood of the non-mask pixels reachable from the border."""
    seen = [[False] * w for _ in range(h)]
    q = deque()

    def push(x, y):
        if not mask[y][x] and not seen[y][x]:
            seen[y][x] = True
            q.append((x, y))

    for x in range(w):
        push(x, 0)
        push(x, h - 1)
    for y in range(h):
        push(0, y)
        push(w - 1, y)
    while q:
        x, y = q.popleft()
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h:
                push(nx, ny)
    return seen


def fill_body(strokes, w, h):
    """Return the silhouette mask (strokes + the body they enclose)."""
    sealed = _dilate(strokes, w, h, SEAL_R)
    outside = _flood_outside(sealed, w, h)
    inside = [[not outside[y][x] for x in range(w)] for y in range(h)]
    body = _erode(inside, w, h, SEAL_R)
    # Union with the strokes: erosion pulls back off the outline itself, and the
    # outline is unambiguously part of the figure.
    return [[body[y][x] or strokes[y][x] for x in range(w)] for y in range(h)]


# ---------------------------------------------------------------------------
# Minimal pure-stdlib RGBA PNG writer
# ---------------------------------------------------------------------------


def _png_chunk(chunk_type, data):
    c = chunk_type + data
    return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)


def write_png(path, width, height, pixels):
    """Write an RGBA PNG from a 2-D list of (r,g,b,a) tuples."""
    raw = bytearray()
    for row in pixels:
        raw.append(0)  # filter type: None
        for r, g, b, a in row:
            raw += bytes((r, g, b, a))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(_png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)))
        f.write(_png_chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        f.write(_png_chunk(b"IEND", b""))


def main():
    w, h, rows = read_bmp_1bpp(SRC_BMP)
    if w != FRAME_W or h != FRAME_H * FRAMES:
        raise ValueError(
            f"{SRC_BMP}: expected {FRAME_W}x{FRAME_H * FRAMES}, got {w}x{h}"
        )

    # Stacked frames become a single row, which is what the atlas indexes by
    # `frame * frame_w`.
    sheet_w, sheet_h = FRAME_W * FRAMES, FRAME_H
    canvas = [[PAPER] * sheet_w for _ in range(sheet_h)]
    for f in range(FRAMES):
        strokes = [
            [rows[f * FRAME_H + y][x] == "1" for x in range(FRAME_W)]
            for y in range(FRAME_H)
        ]
        silhouette = fill_body(strokes, FRAME_W, FRAME_H)
        for y in range(FRAME_H):
            for x in range(FRAME_W):
                # Strokes last: they are drawn ON the body, not replaced by it.
                if strokes[y][x]:
                    canvas[y][f * FRAME_W + x] = STROKE
                elif silhouette[y][x]:
                    canvas[y][f * FRAME_W + x] = BODY

    os.makedirs(OUT_DIR, exist_ok=True)
    write_png(os.path.join(OUT_DIR, f"{NAME}.png"), sheet_w, sheet_h, canvas)
    with open(os.path.join(OUT_DIR, f"{NAME}.json"), "w") as f:
        json.dump({"frame_w": FRAME_W, "frame_h": FRAME_H, "clips": CLIPS}, f, indent=2)
        f.write("\n")
    print(f"wrote {NAME}.png ({sheet_w}x{sheet_h}) + {NAME}.json to {OUT_DIR}")


if __name__ == "__main__":
    main()
