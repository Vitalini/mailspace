#!/usr/bin/env python3
"""Cut the MailSpace artwork out of its opaque backdrop and fit it to the macOS icon grid.

Source art is a light squircle tile sitting on a slightly different light background.
macOS wants: 1024 canvas, transparent margin, 824 squircle of actual artwork.
"""
import sys
from PIL import Image, ImageDraw, ImageFilter

SRC = sys.argv[1]
DST = sys.argv[2]
CANVAS = 1024
TILE = 824  # Apple's macOS icon grid: 824 of 1024, centred


def tile_bounds(img):
    """Find the artwork tile inside the backdrop by walking in from the edges."""
    rgb = img.convert("RGB")
    w, h = rgb.size
    bg = rgb.getpixel((2, 2))

    def differs(p):
        return max(abs(p[i] - bg[i]) for i in range(3)) > 6

    mid_y, mid_x = h // 2, w // 2
    left = next((x for x in range(w) if differs(rgb.getpixel((x, mid_y)))), 0)
    right = next((x for x in range(w - 1, -1, -1) if differs(rgb.getpixel((x, mid_y)))), w - 1)
    top = next((y for y in range(h) if differs(rgb.getpixel((mid_x, y)))), 0)
    bottom = next((y for y in range(h - 1, -1, -1) if differs(rgb.getpixel((mid_x, y)))), h - 1)
    return left, top, right + 1, bottom + 1


def squircle(size, n=5.0, supersample=4):
    """Apple-style continuous-corner shape: superellipse |x|^n + |y|^n = 1."""
    s = size * supersample
    mask = Image.new("L", (s, s), 0)
    draw = ImageDraw.Draw(mask)
    r = s / 2.0
    points = []
    steps = 2048
    for i in range(steps):
        t = 2.0 * 3.141592653589793 * i / steps
        import math
        ct, st = math.cos(t), math.sin(t)
        x = r * (abs(ct) ** (2.0 / n)) * (1 if ct >= 0 else -1)
        y = r * (abs(st) ** (2.0 / n)) * (1 if st >= 0 else -1)
        points.append((r + x, r + y))
    draw.polygon(points, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


src = Image.open(SRC).convert("RGBA")
box = tile_bounds(src)
tile = src.crop(box)

# square it off, centred, so the squircle mask lands on the artwork symmetrically
w, h = tile.size
side = max(w, h)
square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
square.paste(tile, ((side - w) // 2, (side - h) // 2))

# inset a touch so no backdrop fringe survives at the rounded corners
inset = int(side * 0.008)
square = square.crop((inset, inset, side - inset, side - inset))

art = square.resize((TILE, TILE), Image.LANCZOS)
art.putalpha(squircle(TILE))

canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
offset = (CANVAS - TILE) // 2
canvas.paste(art, (offset, offset), art)

# the soft drop shadow macOS icons carry under the tile
shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
shadow.paste(Image.new("RGBA", (TILE, TILE), (0, 0, 0, 70)), (offset, offset + int(TILE * 0.012)),
             squircle(TILE))
shadow = shadow.filter(ImageFilter.GaussianBlur(int(TILE * 0.018)))

out = Image.alpha_composite(shadow, canvas)
out.save(DST)
print(f"tile bounds {box} -> {DST}")
