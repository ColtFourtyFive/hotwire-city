#!/usr/bin/env python3
"""Blip icon atlas for the minimap / fullscreen map (GTA-style glyphs: white shape + dark outline, tinted in-game
with ImageColor3) plus the radar overlays.

    python3 -I tools/minimap/icons.py <out.png> [--sheet preview.png]

Atlas: 512 x 512.
    icons    64 x 64 cells, 8 per row, starting at (0, 0) in ICONS order (row-major). Glyph white (tintable),
             outline near-black, transparent background.
    vignette 256 x 256 at (0, 256): radar inner shadow (black, alpha rises toward the rim) + a faint top sheen
    glow     128 x 128 at (256, 256): soft white radial glow (blip halos, wanted-area fill)
    ring     128 x 128 at (384, 256): soft white ring (wanted-area pulse edge, waypoint ping)
    arrow    128 x 128 at (256, 384): the player arrow (white chevron, dark outline, drop shadow), pointing up
    disc     128 x 128 at (384, 384): crisp white disc with dark outline (round blip badges)

The Luau side (Config/Minimap.ICONS) indexes cells by the same names; keep ICONS in sync with it (the build script
writes the index into the generated block of Config/Minimap.luau).
"""
import argparse, math

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

CELL = 64
SS = 8  # supersampling for glyph drawing
G = CELL * SS  # glyph canvas size

ICONS = [
    "garage", "car", "wrench", "spray", "saw", "flame", "pin", "badge",
    "dot", "heli", "star", "flag", "tree", "wheel", "cash", "alert",
    "target", "home", "square", "person", "trophy", "bolt", "chevron", "diamond",
]


def U(v):
    return v * G


def poly(d, pts):
    d.polygon([(U(x), U(y)) for x, y in pts], fill=255)


def ell(d, cx, cy, rx, ry=None):
    ry = rx if ry is None else ry
    d.ellipse([U(cx - rx), U(cy - ry), U(cx + rx), U(cy + ry)], fill=255)


def rect(d, x0, y0, x1, y1, r=0.0):
    if r > 0:
        d.rounded_rectangle([U(x0), U(y0), U(x1), U(y1)], radius=U(r), fill=255)
    else:
        d.rectangle([U(x0), U(y0), U(x1), U(y1)], fill=255)


def cut(d, fn, *a):
    """Draw with fill 0 (carve holes)."""
    class Z:
        def polygon(self, pts, fill):
            d.polygon(pts, fill=0)

        def ellipse(self, box, fill):
            d.ellipse(box, fill=0)

        def rectangle(self, box, fill):
            d.rectangle(box, fill=0)

        def rounded_rectangle(self, box, radius, fill):
            d.rounded_rectangle(box, radius=radius, fill=0)

        def line(self, pts, width, fill):
            d.line(pts, width=width, fill=0)

    fn(Z(), *a)


def line(d, pts, w):
    d.line([(U(x), U(y)) for x, y in pts], width=int(U(w)), fill=255, joint="curve")
    for x, y in (pts[0], pts[-1]):
        ell(d, x, y, w / 2)


def star_pts(cx, cy, r1, r2, n=5, rot=-math.pi / 2):
    pts = []
    for i in range(n * 2):
        r = r1 if i % 2 == 0 else r2
        a = rot + i * math.pi / n
        pts.append((cx + math.cos(a) * r, cy + math.sin(a) * r))
    return pts


# --- glyphs (unit square, y down; keep within ~0.12..0.88 so the outline fits) ------------------------------------------
def g_garage(d):
    poly(d, [(0.14, 0.44), (0.5, 0.16), (0.86, 0.44), (0.86, 0.84), (0.14, 0.84)])
    cut(d, rect, 0.28, 0.5, 0.72, 0.84)
    for y in (0.56, 0.66, 0.76):
        rect(d, 0.3, y, 0.7, y + 0.055)


def g_car(d):
    poly(d, [(0.12, 0.62), (0.16, 0.48), (0.3, 0.46), (0.38, 0.3), (0.64, 0.3), (0.74, 0.46), (0.86, 0.5),
             (0.88, 0.66), (0.12, 0.66)])
    cut(d, poly, [(0.4, 0.36), (0.5, 0.36), (0.5, 0.46), (0.35, 0.46)])
    cut(d, poly, [(0.55, 0.36), (0.62, 0.36), (0.68, 0.46), (0.55, 0.46)])
    ell(d, 0.3, 0.68, 0.1)
    ell(d, 0.7, 0.68, 0.1)
    cut(d, ell, 0.3, 0.68, 0.04)
    cut(d, ell, 0.7, 0.68, 0.04)


def g_wrench(d):
    line(d, [(0.28, 0.76), (0.6, 0.42)], 0.13)
    ell(d, 0.66, 0.34, 0.18)
    cut(d, poly, [(0.66, 0.34), (0.86, 0.14), (0.95, 0.3), (0.74, 0.42)])
    cut(d, ell, 0.66, 0.34, 0.07)


def g_spray(d):
    rect(d, 0.34, 0.36, 0.66, 0.86, 0.06)
    rect(d, 0.4, 0.26, 0.6, 0.36)
    rect(d, 0.44, 0.17, 0.58, 0.26)
    cut(d, rect, 0.34, 0.5, 0.66, 0.56)
    for (x, y, r) in ((0.72, 0.16, 0.035), (0.8, 0.22, 0.03), (0.76, 0.3, 0.028), (0.86, 0.14, 0.025)):
        ell(d, x, y, r)


def g_saw(d):
    poly(d, star_pts(0.5, 0.5, 0.38, 0.27, n=10, rot=0.0))
    ell(d, 0.5, 0.5, 0.3)
    cut(d, ell, 0.5, 0.5, 0.1)


def g_flame(d):
    poly(d, [(0.5, 0.1), (0.62, 0.3), (0.74, 0.46), (0.78, 0.62), (0.72, 0.78), (0.6, 0.88), (0.4, 0.88),
             (0.28, 0.78), (0.22, 0.62), (0.28, 0.44), (0.36, 0.52), (0.38, 0.34)])
    ell(d, 0.5, 0.68, 0.24, 0.21)
    cut(d, poly, [(0.5, 0.48), (0.6, 0.64), (0.6, 0.76), (0.5, 0.82), (0.4, 0.76), (0.4, 0.64)])


def g_pin(d):
    ell(d, 0.5, 0.38, 0.26)
    poly(d, [(0.28, 0.48), (0.5, 0.9), (0.72, 0.48)])
    cut(d, ell, 0.5, 0.38, 0.1)


def g_badge(d):
    poly(d, [(0.5, 0.1), (0.84, 0.22), (0.8, 0.56), (0.5, 0.9), (0.2, 0.56), (0.16, 0.22)])
    cut(d, poly, star_pts(0.5, 0.48, 0.2, 0.09))


def g_dot(d):
    ell(d, 0.5, 0.5, 0.26)


def g_heli(d):
    ell(d, 0.46, 0.56, 0.2, 0.15)
    rect(d, 0.6, 0.52, 0.88, 0.58)
    rect(d, 0.84, 0.44, 0.9, 0.64)
    rect(d, 0.14, 0.3, 0.8, 0.35)
    rect(d, 0.44, 0.34, 0.48, 0.44)
    rect(d, 0.32, 0.76, 0.62, 0.8)
    rect(d, 0.36, 0.68, 0.39, 0.78)
    rect(d, 0.54, 0.68, 0.57, 0.78)


def g_star(d):
    poly(d, star_pts(0.5, 0.52, 0.4, 0.17))


def g_flag(d):
    rect(d, 0.2, 0.12, 0.27, 0.9)
    poly(d, [(0.27, 0.14), (0.84, 0.14), (0.84, 0.54), (0.27, 0.54)])
    for i in range(4):
        for j in range(2):
            if (i + j) % 2 == 0:
                cut(d, rect, 0.27 + i * 0.1425, 0.14 + j * 0.2, 0.27 + (i + 1) * 0.1425, 0.34 + j * 0.2)


def g_tree(d):
    ell(d, 0.5, 0.36, 0.24)
    ell(d, 0.34, 0.52, 0.18)
    ell(d, 0.66, 0.52, 0.18)
    rect(d, 0.45, 0.6, 0.55, 0.88)


def g_wheel(d):
    ell(d, 0.5, 0.46, 0.34)
    cut(d, ell, 0.5, 0.46, 0.26)
    for k in range(8):
        a = k * math.pi / 4
        line(d, [(0.5, 0.46), (0.5 + math.cos(a) * 0.28, 0.46 + math.sin(a) * 0.28)], 0.04)
    ell(d, 0.5, 0.46, 0.07)
    poly(d, [(0.5, 0.46), (0.3, 0.9), (0.38, 0.9), (0.5, 0.6), (0.62, 0.9), (0.7, 0.9)])


def g_cash(d):
    rect(d, 0.12, 0.28, 0.88, 0.72, 0.06)
    cut(d, rect, 0.18, 0.34, 0.82, 0.66, 0.03)
    ell(d, 0.5, 0.5, 0.12)
    ell(d, 0.26, 0.5, 0.04)
    ell(d, 0.74, 0.5, 0.04)


def g_alert(d):
    poly(d, [(0.5, 0.12), (0.9, 0.84), (0.1, 0.84)])
    cut(d, poly, [(0.46, 0.36), (0.54, 0.36), (0.525, 0.62), (0.475, 0.62)])
    cut(d, ell, 0.5, 0.72, 0.045)


def g_target(d):
    ell(d, 0.5, 0.5, 0.38)
    cut(d, ell, 0.5, 0.5, 0.28)
    ell(d, 0.5, 0.5, 0.18)
    cut(d, ell, 0.5, 0.5, 0.09)


def g_home(d):
    poly(d, [(0.12, 0.5), (0.5, 0.14), (0.88, 0.5), (0.78, 0.5), (0.78, 0.86), (0.22, 0.86), (0.22, 0.5)])
    cut(d, rect, 0.42, 0.6, 0.58, 0.86)


def g_square(d):
    rect(d, 0.24, 0.24, 0.76, 0.76, 0.08)


def g_person(d):
    ell(d, 0.5, 0.28, 0.13)
    poly(d, [(0.28, 0.88), (0.3, 0.52), (0.4, 0.44), (0.6, 0.44), (0.7, 0.52), (0.72, 0.88)])


def g_trophy(d):
    poly(d, [(0.26, 0.16), (0.74, 0.16), (0.7, 0.44), (0.58, 0.56), (0.42, 0.56), (0.3, 0.44)])
    rect(d, 0.45, 0.55, 0.55, 0.72)
    rect(d, 0.32, 0.72, 0.68, 0.84, 0.02)
    ell(d, 0.24, 0.3, 0.1)
    ell(d, 0.76, 0.3, 0.1)
    cut(d, ell, 0.24, 0.3, 0.05)
    cut(d, ell, 0.76, 0.3, 0.05)


def g_bolt(d):
    poly(d, [(0.58, 0.1), (0.24, 0.56), (0.46, 0.56), (0.4, 0.9), (0.76, 0.42), (0.54, 0.42)])


def g_chevron(d):
    poly(d, [(0.5, 0.12), (0.84, 0.86), (0.5, 0.68), (0.16, 0.86)])


def g_diamond(d):
    poly(d, [(0.5, 0.12), (0.86, 0.5), (0.5, 0.88), (0.14, 0.5)])


GLYPHS = {name: globals()["g_" + name] for name in ICONS}


def glyph_cell(name, outline_px=3.2):
    m = Image.new("L", (G, G), 0)
    GLYPHS[name](ImageDraw.Draw(m))
    # outline = dilated glyph (blur + threshold keeps it round)
    r = outline_px * SS
    o = m.filter(ImageFilter.GaussianBlur(r * 0.55)).point(lambda v: 255 if v > 18 else 0)
    o = o.filter(ImageFilter.GaussianBlur(SS * 0.6))
    cell = Image.new("RGBA", (G, G), (0, 0, 0, 0))
    cell.paste((12, 14, 26, 255), (0, 0, G, G), o)
    cell.paste((255, 255, 255, 255), (0, 0, G, G), m)
    return cell.resize((CELL, CELL), Image.LANCZOS)


def radial(size, fn):
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    c = (size - 1) / 2
    r = np.sqrt((x - c) ** 2 + (y - c) ** 2) / (size / 2)
    return fn(r, x / size, y / size)


def vignette(size=256):
    def f(r, x, y):
        a = np.clip((r - 0.62) / 0.38, 0, 1) ** 1.8 * 0.62
        a = np.where(r > 1.0, 0, a)
        return a
    a = radial(size, f)
    img = np.zeros((size, size, 4), np.uint8)
    img[..., 3] = (a * 255).astype(np.uint8)
    # faint top sheen (glassy bezel)
    def sheen(r, x, y):
        s = np.clip(1 - np.abs(r - 0.9) / 0.08, 0, 1) * np.clip((0.5 - y) * 2.2, 0, 1) * 0.22
        return np.where(r > 1.0, 0, s)
    s = radial(size, sheen)
    alpha = img[..., 3].astype(np.float32) / 255
    out_a = s + alpha * (1 - s)
    rgb = (255 * s / np.maximum(out_a, 1e-6))[..., None] * np.ones(3)
    img[..., :3] = np.clip(rgb, 0, 255).astype(np.uint8)
    img[..., 3] = (np.clip(out_a, 0, 1) * 255).astype(np.uint8)
    return Image.fromarray(img, "RGBA")


def glow(size=128):
    a = radial(size, lambda r, x, y: np.clip(1 - r, 0, 1) ** 2.2)
    img = np.zeros((size, size, 4), np.uint8)
    img[..., :3] = 255
    img[..., 3] = (a * 255).astype(np.uint8)
    return Image.fromarray(img, "RGBA")


def ring(size=128):
    a = radial(size, lambda r, x, y: np.exp(-((r - 0.86) / 0.07) ** 2) + np.clip(0.86 - r, 0, 1) * 0.0)
    a = np.where(radial(size, lambda r, x, y: r) > 1, 0, a)
    img = np.zeros((size, size, 4), np.uint8)
    img[..., :3] = 255
    img[..., 3] = (np.clip(a, 0, 1) * 255).astype(np.uint8)
    return Image.fromarray(img, "RGBA")


def arrow(size=128):
    S2 = size * SS
    m = Image.new("L", (S2, S2), 0)
    d = ImageDraw.Draw(m)
    k = S2
    d.polygon([(0.5 * k, 0.16 * k), (0.78 * k, 0.8 * k), (0.5 * k, 0.66 * k), (0.22 * k, 0.8 * k)], fill=255)
    o = m.filter(ImageFilter.GaussianBlur(5 * SS * 0.55)).point(lambda v: 255 if v > 18 else 0)
    o = o.filter(ImageFilter.GaussianBlur(SS * 0.6))
    sh = o.filter(ImageFilter.GaussianBlur(4 * SS))
    img = Image.new("RGBA", (S2, S2), (0, 0, 0, 0))
    img.paste((0, 0, 0, 255), (0, 0, S2, S2), sh.point(lambda v: int(v * 0.55)))
    img.paste((14, 16, 30, 255), (0, 0, S2, S2), o)
    img.paste((255, 255, 255, 255), (0, 0, S2, S2), m)
    # subtle bevel: darker right half so the arrow reads as a 3D chevron
    half = Image.new("L", (S2, S2), 0)
    ImageDraw.Draw(half).polygon([(0.5 * k, 0.16 * k), (0.78 * k, 0.8 * k), (0.5 * k, 0.66 * k)], fill=60)
    img.paste((150, 160, 190, 255), (0, 0, S2, S2), half)
    return img.resize((size, size), Image.LANCZOS)


def disc(size=128):
    S2 = size * SS
    m = Image.new("L", (S2, S2), 0)
    ImageDraw.Draw(m).ellipse([0.1 * S2, 0.1 * S2, 0.9 * S2, 0.9 * S2], fill=255)
    o = Image.new("L", (S2, S2), 0)
    ImageDraw.Draw(o).ellipse([0.04 * S2, 0.04 * S2, 0.96 * S2, 0.96 * S2], fill=255)
    img = Image.new("RGBA", (S2, S2), (0, 0, 0, 0))
    img.paste((12, 14, 26, 255), (0, 0, S2, S2), o)
    img.paste((255, 255, 255, 255), (0, 0, S2, S2), m)
    return img.resize((size, size), Image.LANCZOS)


def build_atlas():
    atlas = Image.new("RGBA", (512, 512), (0, 0, 0, 0))
    for i, name in enumerate(ICONS):
        atlas.paste(glyph_cell(name), ((i % 8) * CELL, (i // 8) * CELL))
    atlas.paste(vignette(256), (0, 256))
    atlas.paste(glow(128), (256, 256))
    atlas.paste(ring(128), (384, 256))
    atlas.paste(arrow(128), (256, 384))
    atlas.paste(disc(128), (384, 384))
    return atlas


def index():
    """name -> (x, y, w, h) in atlas pixels."""
    out = {name: ((i % 8) * CELL, (i // 8) * CELL, CELL, CELL) for i, name in enumerate(ICONS)}
    out.update({"_vignette": (0, 256, 256, 256), "_glow": (256, 256, 128, 128), "_ring": (384, 256, 128, 128),
                "_arrow": (256, 384, 128, 128), "_disc": (384, 384, 128, 128)})
    return out


def sheet(atlas):
    """Preview: every icon tinted on the radar background."""
    bg = Image.new("RGBA", (8 * 80 + 20, 3 * 92 + 300), (24, 27, 40, 255))
    tints = [(255, 255, 255), (70, 235, 110), (0, 214, 255), (255, 52, 140), (255, 190, 40), (255, 70, 70)]
    d = ImageDraw.Draw(bg)
    for i, name in enumerate(ICONS):
        x, y = 10 + (i % 8) * 80, 10 + (i // 8) * 92
        ic = atlas.crop(((i % 8) * CELL, (i // 8) * CELL, (i % 8 + 1) * CELL, (i // 8 + 1) * CELL))
        t = tints[i % len(tints)]
        arr = np.asarray(ic).astype(np.float32)
        arr[..., :3] *= np.array(t, np.float32) / 255
        bg.alpha_composite(Image.fromarray(arr.astype(np.uint8), "RGBA"), (x + 8, y))
        d.text((x + 8, y + 66), name, fill=(200, 205, 230))
    y0 = 3 * 92 + 20
    for j, (key, box) in enumerate([("_vignette", (0, 256, 256, 512)), ("_glow", (256, 256, 384, 384)),
                                    ("_ring", (384, 256, 512, 384)), ("_arrow", (256, 384, 384, 512)),
                                    ("_disc", (384, 384, 512, 512))]):
        part = atlas.crop(box)
        x = 10 + [0, 270, 410, 540, 540][j]
        y = y0 + (0 if j < 4 else 130)
        if key == "_vignette":
            tmp = Image.new("RGBA", part.size, (60, 90, 120, 255))
            tmp.alpha_composite(part)
            part = tmp
        bg.alpha_composite(part, (x, y))
    return bg


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--sheet")
    a = ap.parse_args()
    atlas = build_atlas()
    atlas.save(a.out, optimize=True)
    if a.sheet:
        sheet(atlas).save(a.sheet)
    print(f"wrote {a.out} ({len(ICONS)} icons)")


if __name__ == "__main__":
    main()
