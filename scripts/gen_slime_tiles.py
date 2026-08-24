#!/usr/bin/env python3
"""Convert the authored SlimeBlock art into the web client's slime tile atlas.

Input:  ../../board/src/render/assets/art/slime/SlimeBlock*_20x20x1.bmp
        The SAME files the e-paper board's tile generator consumes
        (board/tools/gen_tiles.py).  They are the single source of truth for
        what a slime unit looks like; they are never edited here.  Despite
        the 16bpp container, every pixel is strictly 0 (ink) or 0x7FFF
        (paper) — 1-bit art.
Output: ../web/assets/slime.png  +  ../web/assets/slime.json

One row of eight 20x20 frames.  The json maps frame NAME -> index, so
web/game.js picks frames by name and the atlas order can change without
touching the client:

    hard / medium / soft / goo            the cell art (red / yellow / green /
                                          grey in the game's colour language)
    *_invert                              the same cell SELECTED (covered by
                                          the cast preview or a cursor)

Deliberately black-and-white, as authored: ink pixels are painted black and
paper pixels white, both fully opaque, so a tile reads as a paper card with
line art on the dark canvas — the same face the e-paper badge shows.

Stdlib only; no Pillow.
"""

import json
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ART_DIR = os.path.join(
    HERE, "..", "..", "board", "src", "render", "assets", "art", "slime",
)
OUT_DIR = os.path.join(HERE, "..", "web", "assets")
NAME = "slime"

FRAME = 20

# Atlas frame name -> authored file stem.  Hard/Medium/Soft/Goo map to the
# red/yellow/green/grey ("hard to soft") tier language used in gameplay.
FRAMES = {
    "hard": "SlimeBlockHard",
    "medium": "SlimeBlockMedium",
    "soft": "SlimeBlockSoft",
    "goo": "SlimeBlockGoo",
    "hard_invert": "SlimeBlockHardInvert",
    "medium_invert": "SlimeBlockMediumInvert",
    "soft_invert": "SlimeBlockSoftInvert",
    "goo_invert": "SlimeBlockGooInvert",
}

INK = (16, 12, 28, 255)      # near-black, matching the client's glyph ink
PAPER = (238, 242, 250, 255)  # the faintly cool white the Lil Guys use


def read_art_bmp(path):
    """Return FRAME x FRAME rows (top-down) of ink booleans.

    The authored exports are 16bpp uncompressed BMPs holding only 0 (ink) and
    0x7FFF (paper); anything else is an unexpected export and fails loudly.
    """
    d = open(path, "rb").read()
    if d[:2] != b"BM":
        raise ValueError(f"{path}: not a BMP")
    (pix_off,) = struct.unpack_from("<I", d, 10)
    w, h = struct.unpack_from("<ii", d, 18)
    (bpp,) = struct.unpack_from("<H", d, 28)
    (comp,) = struct.unpack_from("<I", d, 30)
    if bpp != 16 or comp != 0:
        raise ValueError(f"{path}: want 16bpp uncompressed, got {bpp}/{comp}")
    top_down = h < 0
    height = abs(h)
    if w != FRAME or height != FRAME:
        raise ValueError(f"{path}: want {FRAME}x{FRAME}, got {w}x{height}")
    stride = (w * 2 + 3) // 4 * 4
    rows = []
    for y in range(height):
        src_y = y if top_down else height - 1 - y
        rows.append([
            struct.unpack_from("<H", d, pix_off + src_y * stride + x * 2)[0] == 0
            for x in range(w)
        ])
    return rows


def _png_chunk(chunk_type, data):
    c = chunk_type + data
    return struct.pack(">I", len(data)) + c + \
        struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)


def write_png(path, width, height, pixels):
    """Write an RGBA PNG from a 2-D list of (r,g,b,a) tuples."""
    raw = bytearray()
    for row in pixels:
        raw.append(0)  # filter: None
        for r, g, b, a in row:
            raw += bytes((r, g, b, a))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(_png_chunk(
            b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)))
        f.write(_png_chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        f.write(_png_chunk(b"IEND", b""))


def main():
    names = list(FRAMES)
    sheet_w, sheet_h = FRAME * len(names), FRAME
    canvas = [[PAPER] * sheet_w for _ in range(sheet_h)]
    for i, name in enumerate(names):
        path = os.path.join(ART_DIR, f"{FRAMES[name]}_{FRAME}x{FRAME}x1.bmp")
        art = read_art_bmp(path)
        for y in range(FRAME):
            for x in range(FRAME):
                canvas[y][i * FRAME + x] = INK if art[y][x] else PAPER

    os.makedirs(OUT_DIR, exist_ok=True)
    write_png(os.path.join(OUT_DIR, f"{NAME}.png"), sheet_w, sheet_h, canvas)
    with open(os.path.join(OUT_DIR, f"{NAME}.json"), "w") as f:
        json.dump({
            "frame_w": FRAME,
            "frame_h": FRAME,
            "frames": {name: i for i, name in enumerate(names)},
        }, f, indent=2)
        f.write("\n")
    print(f"wrote {NAME}.png ({sheet_w}x{sheet_h}) + {NAME}.json to {OUT_DIR}")


if __name__ == "__main__":
    main()
