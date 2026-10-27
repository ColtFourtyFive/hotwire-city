#!/usr/bin/env python3
"""Tileable window-bay images for BuildingService's procedural massing (the fallback when no template fits or an asset
fails to load). One bay per tile: Texture.StudsPerTileU = bay width, StudsPerTileV = storey height. Transparent where
the wall is, so the block's own PBR material (Brick / Plaster / Concrete MaterialVariant) shows between windows.

    python3 -I tools/blender/buildkit/fallback_textures.py      -> assets/buildings/textures/fb_*.png
"""
import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(os.path.join(HERE, "..", "..", "..", "assets", "buildings", "textures"))
S = 256


def glass(d, x0, y0, x1, y1, top=(70, 86, 104), bottom=(34, 42, 52)):
    h = max(1, y1 - y0)
    for y in range(y0, y1):
        t = (y - y0) / h
        c = tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
        d.line([(x0, y), (x1 - 1, y)], fill=c + (255,))
    # soft sky reflection streak (opaque: blended by hand so the glass keeps alpha 255)
    for y in range(y0, y1):
        t = (y - y0) / h
        xa = int(x0 + (x1 - x0) * (0.15 - 0.15 * t))
        xb = int(x0 + (x1 - x0) * (0.45 - 0.25 * t))
        base = tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
        c = tuple(int(base[i] * 0.75 + (150, 165, 182)[i] * 0.25) for i in range(3))
        if xb > xa:
            d.line([(xa, y), (xb, y)], fill=c + (255,))


def punched():
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im, "RGBA")
    x0, x1 = int(S * 0.24), int(S * 0.76)
    y0, y1 = int(S * 0.2), int(S * 0.78)
    d.rectangle([x0 - 10, y0 - 10, x1 + 10, y1 + 6], fill=(60, 58, 56, 150))   # reveal shadow
    glass(d, x0, y0, x1, y1)
    f = (226, 224, 218, 255)
    d.rectangle([x0, y0, x1, y0 + 6], fill=f)
    d.rectangle([x0, y1 - 6, x1, y1], fill=f)
    d.rectangle([x0, y0, x0 + 6, y1], fill=f)
    d.rectangle([x1 - 6, y0, x1, y1], fill=f)
    d.rectangle([(x0 + x1) // 2 - 3, y0, (x0 + x1) // 2 + 3, y1], fill=f)
    d.rectangle([x0 - 14, y1, x1 + 14, y1 + 10], fill=(214, 210, 202, 255))   # sill
    return im


def curtain():
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im, "RGBA")
    spand = int(S * 0.26)
    glass(d, 0, 0, S, S - spand, top=(96, 114, 132), bottom=(58, 70, 84))
    d.rectangle([0, S - spand, S, S], fill=(64, 70, 78, 255))   # spandrel
    m = (40, 42, 46, 255)
    d.rectangle([0, 0, 5, S], fill=m)
    d.rectangle([S - 6, 0, S, S], fill=m)
    d.rectangle([0, S - spand - 4, S, S - spand + 4], fill=m)
    d.rectangle([0, S - 6, S, S], fill=m)
    return im


def ribbon():
    """Horizontal strip window (office / parkade band): glass across the full bay, wall above and below."""
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im, "RGBA")
    y0, y1 = int(S * 0.3), int(S * 0.8)
    glass(d, 0, y0, S, y1, top=(84, 100, 118), bottom=(40, 48, 58))
    d.rectangle([0, y0, 4, y1], fill=(46, 48, 52, 255))
    d.rectangle([S - 5, y0, S, y1], fill=(46, 48, 52, 255))
    return im


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, fn in (("fb_punched", punched), ("fb_curtain", curtain), ("fb_ribbon", ribbon)):
        p = os.path.join(OUT, name + ".png")
        fn().save(p)
        print("wrote", p)


if __name__ == "__main__":
    main()
