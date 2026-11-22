#!/usr/bin/env python3
"""Draws Progman31lua's icon, assets/progman31lua.ico (and a 256 px PNG).

An original drawing, not Microsoft's: a beige retro monitor whose screen
shows a small desktop of three launcher tiles (a star, a diamond and a
play arrow) under a navy title bar, the "program manager" idea in WinRetro
colours. Every size is drawn 8x larger and scaled down, with the shapes
snapped to that size's grid so the small ones stay crisp.

    python3 tools/make_icon.py [out_dir]       (needs Pillow)
"""
import io
import os
import struct
import sys

from PIL import Image, ImageDraw, ImageFilter

SS = 8

BEIGE = (226, 214, 186)
BEIGE_LIGHT = (246, 238, 218)
BEIGE_DARK = (150, 138, 112)
BEZEL = (60, 58, 66)
SCREEN = (20, 120, 128)
SCREEN_LIGHT = (40, 160, 168)
TITLE = (24, 36, 112)
WINDOW = (236, 236, 236)
TILES = [(244, 128, 32), (214, 52, 140), (110, 70, 200)]


def draw(size):
    s = size * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    def R(x0, y0, x1, y1):  # a box in a 32 x 32 design grid, snapped to pixels of `size`
        q = lambda v: round(v * size / 32) * SS
        a, b = q(x0), q(y0)
        return (a, b, max(q(x1), a + SS) - 1, max(q(y1), b + SS) - 1)

    # Shadow.
    sh = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle(R(3, 4, 31, 31), radius=s // 12, fill=(0, 0, 0, 110))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(s / 50)))

    d = ImageDraw.Draw(img)
    # Stand and base.
    d.rectangle(R(13, 25, 19, 28), fill=BEIGE_DARK)
    d.rounded_rectangle(R(8, 27, 24, 30), radius=s // 40, fill=BEIGE, outline=BEIGE_DARK, width=SS)
    # Case, with a light top-left and dark bottom-right edge.
    d.rounded_rectangle(R(2, 2, 30, 26), radius=s // 14, fill=BEIGE_DARK)
    d.rounded_rectangle(R(2, 2, 29, 25), radius=s // 14, fill=BEIGE_LIGHT)
    d.rounded_rectangle(R(3, 3, 29, 25), radius=s // 16, fill=BEIGE)
    # Bezel and screen.
    d.rounded_rectangle(R(5, 5, 27, 22), radius=s // 30, fill=BEZEL)
    d.rectangle(R(6, 6, 26, 21), fill=SCREEN)
    if size >= 32:
        d.rectangle(R(6, 6, 26, 8), fill=SCREEN_LIGHT)
    # A window on the screen: navy title bar, light body, three tiles.
    d.rectangle(R(8, 8, 25, 20), fill=WINDOW)
    d.rectangle(R(8, 8, 25, 10), fill=TITLE)
    if size >= 24:
        d.rectangle(R(23, 8, 25, 10), fill=(200, 200, 200))
    xs = (9, 14.5, 20) if size >= 32 else (9, 14, 19)
    for i, (x, c) in enumerate(zip(xs, TILES)):
        box = R(x, 12, x + 4.5 if size >= 32 else x + 5, 17)
        d.rounded_rectangle(box, radius=max(SS, s // 64), fill=c)
        if size >= 32:  # a glyph in each tile
            x0, y0, x1, y1 = box
            cx, cy, r = (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) * 0.3
            w = (255, 255, 255)
            if i == 0:
                import math
                pts = []
                for k in range(10):
                    a = -math.pi / 2 + k * math.pi / 5
                    rr = r if k % 2 == 0 else r * 0.45
                    pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
                d.polygon(pts, fill=w)
            elif i == 1:
                d.polygon([(cx, cy - r), (cx + r * 0.75, cy), (cx, cy + r), (cx - r * 0.75, cy)], fill=w)
            else:
                d.polygon([(cx - r * 0.6, cy - r), (cx + r, cy), (cx - r * 0.6, cy + r)], fill=w)
    # Power light.
    d.ellipse(R(25, 23, 27, 25), fill=(80, 220, 90))
    return img.resize((size, size), Image.LANCZOS)


def write_ico(path, images):
    """An .ico of PNG entries (Windows Vista and later read them at every size)."""
    blobs = []
    for im in images:
        b = io.BytesIO()
        im.save(b, "PNG")
        blobs.append(b.getvalue())
    out = struct.pack("<HHH", 0, 1, len(images))
    off = 6 + 16 * len(images)
    for im, data in zip(images, blobs):
        w, h = im.size
        out += struct.pack("<BBBBHHII", w % 256, h % 256, 0, 0, 1, 32, len(data), off)
        off += len(data)
    with open(path, "wb") as f:
        f.write(out + b"".join(blobs))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "assets")
    os.makedirs(out, exist_ok=True)
    images = [draw(n) for n in (16, 24, 32, 48, 64, 128, 256)]
    write_ico(os.path.join(out, "progman31lua.ico"), images)
    images[-1].save(os.path.join(out, "progman31lua.png"))
    print("wrote", os.path.join(out, "progman31lua.ico"))


if __name__ == "__main__":
    main()
