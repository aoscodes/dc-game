#!/usr/bin/env python3
"""Convert the authored baby-critter art into the web client's baby atlas.

Input:  ../../board/src/render/assets/art/babies/LilGuys-Baby{1..5}.png
        The SAME masters the e-paper board's icon generator consumes
        (board/tools/gen_babies.py).  They are the single source of truth for
        what a baby looks like; they are never edited here.  32x32,
        greyscale+alpha, strictly 1-bit in practice: every pixel is black
        stroke, white body or transparent.
Output: ../web/assets/babies.png  +  ../web/assets/babies.json

One row of five 32x32 frames, index = BabyType ordinal (components.zig /
web/game.js BABY_TYPES): rose, mint, sky, gold, plum — the file number IS the
identity, LilGuys-Baby1 = rose .. LilGuys-Baby5 = plum.  The json maps frame
NAME -> index (the slime atlas convention), so game.js picks frames by baby
type name and the atlas order could change without touching the client.

Unlike gen_lilguy.py there is no body reconstruction: the masters carry real
alpha, so the three states ship straight through — STROKE where the author
drew ink, BODY for the white the strokes enclose, transparent outside.  The
palette matches the Lil Guy sheet (these are their babies), so the brood
reads as the same species over the dark field.

Stdlib only; no Pillow.
"""

import json
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ART_DIR = os.path.join(
    HERE, "..", "..", "board", "src", "render", "assets", "art", "babies",
)
OUT_DIR = os.path.join(HERE, "..", "web", "assets")
NAME = "babies"

FRAME = 32

# Atlas frame name -> authored file, in BabyType ordinal order.
FRAMES = {
    "rose": "LilGuys-Baby1.png",
    "mint": "LilGuys-Baby2.png",
    "sky": "LilGuys-Baby3.png",
    "gold": "LilGuys-Baby4.png",
    "plum": "LilGuys-Baby5.png",
}

# The authored strokes: black, as drawn — the Lil Guy sheet's STROKE.
STROKE = (0, 0, 0, 255)
# The body the strokes enclose: the faintly cool white the Lil Guys use.
BODY = (238, 242, 250, 255)
# Outside the figure.  Fully transparent: the slime field shows through.
PAPER = (0, 0, 0, 0)


def read_art_png(path):
    """Return FRAME x FRAME rows (top-down) of (grey, alpha) pairs.

    Only the exact shape the masters use (8-bit greyscale+alpha,
    non-interlaced) is supported; anything else fails loudly rather than
    shipping a mangled critter.
    """
    d = open(path, "rb").read()
    if d[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path}: not a PNG")
    pos = 8
    idat = b""
    w = h = bd = ct = il = -1
    while pos < len(d):
        (ln,) = struct.unpack_from(">I", d, pos)
        typ = d[pos + 4:pos + 8]
        chunk = d[pos + 8:pos + 8 + ln]
        pos += 12 + ln
        if typ == b"IHDR":
            w, h, bd, ct, _, _, il = struct.unpack(">IIBBBBB", chunk)
        elif typ == b"IDAT":
            idat += chunk
    if (w, h) != (FRAME, FRAME):
        raise ValueError(f"{path}: want {FRAME}x{FRAME}, got {w}x{h}")
    if (bd, ct, il) != (8, 4, 0):
        raise ValueError(
            f"{path}: bitdepth={bd} colourtype={ct} interlace={il}, "
            "want 8-bit greyscale+alpha, non-interlaced")

    raw = zlib.decompress(idat)
    bpp = 2  # bytes per pixel: grey, alpha
    stride = w * bpp
    prev = bytearray(stride)
    rows = []
    i = 0
    for _ in range(h):
        flt = raw[i]
        line = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        if flt == 1:  # Sub
            for x in range(bpp, stride):
                line[x] = (line[x] + line[x - bpp]) & 0xFF
        elif flt == 2:  # Up
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 0xFF
        elif flt == 3:  # Average
            for x in range(stride):
                left = line[x - bpp] if x >= bpp else 0
                line[x] = (line[x] + (left + prev[x]) // 2) & 0xFF
        elif flt == 4:  # Paeth
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 0xFF
        elif flt != 0:
            raise ValueError(f"{path}: unknown filter {flt}")
        prev = line
        rows.append([(line[x * 2], line[x * 2 + 1]) for x in range(w)])
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
        art = read_art_png(os.path.join(ART_DIR, FRAMES[name]))
        for y in range(FRAME):
            for x in range(FRAME):
                grey, alpha = art[y][x]
                if alpha < 128:
                    continue  # PAPER already there
                canvas[y][i * FRAME + x] = STROKE if grey < 128 else BODY

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
