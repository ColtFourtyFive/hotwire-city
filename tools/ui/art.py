"""Hotwire City UI art (gta_ui_language §6): sprite sheets, wedge / vignette / band sprites, the parody phone shell,
contact portraits, interaction-menu banners and the wordmark. Loading illustrations live in keyart.py.

    python3 -I tools/ui/art.py            # writes assets/ui/*.png + assets/ui/cells.json

All art is our own vector drawing (PIL). Fonts are the OFL files in assets/ui/fonts (outlines rendered into art).
"""
import json
import math
import os
import random
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(__file__))
from common import BRAND, C, INK, OUT_DIR, Canvas, font, horizontal_gradient, lerp_col, save, vertical_gradient  # noqa: E402
import glyphs  # noqa: E402


def hud_sheet():
    sheet = Image.new("RGBA", (512, 512), (0, 0, 0, 0))
    cells = {}

    def put(name, img, x, y):
        sheet.alpha_composite(img, (x, y))
        cells[name] = [x, y, img.width, img.height]

    row0 = [
        ("star_fill", glyphs.star_fill()),
        ("star_hollow", glyphs.star_hollow()),
        ("arrow", glyphs.player_arrow()),
        ("north", glyphs.north_disc()),
        ("chevron", glyphs.chevron()),
        ("dot", glyphs.dot()),
        ("ring", glyphs.ring()),
        ("square", glyphs.square()),
    ]
    for i, (name, img) in enumerate(row0):
        put(name, img, i * 64, 0)
    for i, (name, fn, holes) in enumerate(glyphs.TOUCH):
        put(name, glyphs.glyph(fn, 64, holes), (i % 8) * 64, 64 + (i // 8) * 64)
    put("spinner", glyphs.spinner(128), 0, 256)
    return sheet, cells


def apps_sheet():
    sheet = Image.new("RGBA", (384, 384), (0, 0, 0, 0))
    cells = {}
    for i, (key, bg, fn, holes, dark) in enumerate(glyphs.APPS):
        x, y = (i % 4) * 96, (i // 4) * 96
        sheet.alpha_composite(glyphs.app_icon(bg, fn, holes, dark), (x, y))
        cells[key] = [x, y, 96, 96]
    return sheet, cells


def wedge(size=256, spread=60):
    """Police vision cone: apex at the image centre, opening upward, radial alpha falloff (rotate about the centre)."""
    img = Image.new("L", (size, size), 0)
    px = img.load()
    c = size / 2
    for y in range(size):
        for x in range(size):
            dx, dy = x + 0.5 - c, c - (y + 0.5)
            r = math.hypot(dx, dy)
            if r > c or dy <= 0:
                continue
            ang = math.degrees(math.atan2(dx, dy))
            edge = spread / 2 - abs(ang)
            if edge <= 0:
                continue
            a = min(1.0, edge / 4) * (1 - (r / c) ** 1.6) * min(1.0, r / 6)
            px[x, y] = int(255 * max(0.0, a))
    out = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    out.putalpha(img)
    return out


def vignette(size=512):
    img = Image.new("L", (size, size), 0)
    px = img.load()
    c = size / 2
    for y in range(size):
        for x in range(size):
            r = math.hypot(x + 0.5 - c, y + 0.5 - c) / c
            px[x, y] = int(255 * min(1.0, max(0.0, (r - 0.45) / 0.65)) ** 1.5)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.putalpha(img)
    return out


def shard_band(w=1024, h=128):
    """The big-message band's keystone (§0/§5.9): 15.5% H tall at the left edge, 23% at the right (image spans the
    right-edge height; the left edge covers the middle 67%)."""
    cv = Canvas(w, h, 2)
    left = h * 0.155 / 0.23
    top_l = (h - left) / 2
    cv.poly([(0, top_l), (w, 0), (w, h), (0, top_l + left)], fill=(0, 0, 0, 255))
    return cv.done()


def phone_shell(w=256, h=480):
    """Our own parody handset ("Fone"), drawn at 2x for a 9-slice ImageLabel (SliceScale 0.5). The screen window is
    fully transparent; the UI paints the screen under it."""
    s = 2
    cv = Canvas(w * s, h * s, 3)
    W, H = w * s, h * s
    # body
    cv.rect((0, 0, W, H), fill=(18, 18, 20, 255), radius=46 * s / 2)
    cv.rect((3, 3, W - 3, H - 3), outline=(70, 72, 78, 255), width=3, radius=44 * s / 2)
    cv.rect((10, 10, W - 10, H - 10), outline=(8, 8, 9, 255), width=4, radius=40 * s / 2)
    # speaker + camera
    cv.rect((W / 2 - 34, 22, W / 2 + 34, 30), fill=(48, 48, 52, 255), radius=4)
    cv.circle(W / 2 + 52, 26, 6, fill=(30, 34, 46, 255), outline=(60, 64, 80, 255), width=1.5)
    # side buttons
    cv.rect((W - 4, 120, W, 180), fill=(48, 48, 52, 255))
    img = cv.done()
    # screen window: transparent
    hole = Canvas(W, H, 3)
    hole.rect((18, 48, W - 18, H - 64), fill=(255, 255, 255, 255), radius=10)
    mask = hole.done().split()[3]
    a = ImageChops.subtract(img.split()[3], mask)
    img.putalpha(a)
    # home bar
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([W / 2 - 40, H - 36, W / 2 + 40, H - 28], radius=4, fill=(90, 92, 98, 255))
    return img, {"screen": [18, 48, W - 18, H - 64], "slice": [60, 120, W - 60, H - 120], "scale": 1 / s}


# --- contact portraits ------------------------------------------------------------------------------------------------

PORTRAITS = [
    # key, bg top, bg bottom, skin, hair, clothing, accessory
    ("mechanic", (60, 74, 92), (24, 28, 36), (198, 146, 110), (40, 30, 24), (40, 76, 120), "cap"),
    ("lawyer", (88, 70, 50), (30, 24, 20), (226, 184, 150), (60, 52, 48), (34, 34, 40), "tie"),
    ("fence", (64, 52, 80), (20, 16, 28), (150, 104, 76), (20, 18, 18), (52, 56, 60), "hood"),
    ("bonus", (120, 96, 40), (40, 30, 14), (236, 196, 160), (120, 70, 30), (214, 181, 99), "chain"),
    ("security", (40, 60, 80), (12, 18, 26), (176, 122, 92), (30, 26, 24), (24, 28, 34), "security"),
    ("crew", (100, 56, 40), (34, 18, 14), (120, 84, 62), (16, 14, 14), (210, 90, 50), "shades"),
    ("cab", (120, 100, 30), (40, 32, 10), (210, 160, 120), (70, 50, 30), (240, 200, 80), "headset"),
    ("dispatch", (40, 50, 90), (14, 16, 30), (224, 176, 140), (150, 90, 50), (40, 60, 110), "headset"),
]


def portrait(bg_top, bg_bot, skin, hair, cloth, acc, size=128):
    cv = Canvas(size, size, 4)
    bg = vertical_gradient(size * 4, size * 4, [(0, bg_top), (1, bg_bot)])
    cv.img.alpha_composite(bg)
    shade = lambda c, k: tuple(int(v * k) for v in c) + (255,)  # noqa: E731
    ink = (14, 10, 18, 255)
    # shoulders
    hood = acc == "hood"
    cv.ellipse((10, 86, 118, 170), fill=shade(cloth, 1), outline=ink, width=3)
    cv.poly([(64, 92), (118, 104), (118, 140), (64, 140)], fill=shade(cloth, 0.78))
    if acc == "tie":
        cv.poly([(52, 90), (64, 112), (76, 90)], fill=(236, 236, 236, 255), outline=ink, width=2)
        cv.poly([(60, 98), (68, 98), (70, 128), (64, 134), (58, 128)], fill=(150, 30, 40, 255), outline=ink, width=2)
    if acc == "chain":
        cv.arc((44, 80, 84, 112), 20, 160, (240, 210, 120, 255), 4)
    if acc == "security":
        cv.rect((78, 104, 98, 116), fill=(240, 200, 80, 255), outline=ink, width=1.5)
    # neck
    cv.rect((54, 70, 74, 96), fill=shade(skin, 0.86), outline=ink, width=2.5)
    if hood:
        cv.ellipse((26, 18, 102, 110), fill=shade(cloth, 0.9), outline=ink, width=3)
    # head
    cv.ellipse((40, 24, 88, 84), fill=shade(skin, 1), outline=ink, width=3)
    cv.poly([(64, 26), (88, 40), (88, 70), (70, 84), (64, 84)], fill=shade(skin, 0.86))
    cv.ellipse((40, 24, 88, 84), outline=ink, width=3)
    # ear
    cv.ellipse((36, 50, 46, 64), fill=shade(skin, 0.9), outline=ink, width=2)
    # hair
    if not hood:
        cv.poly([(38, 46), (40, 30), (54, 20), (74, 20), (88, 30), (90, 46), (84, 36), (64, 32), (46, 36)],
                fill=shade(hair, 1), outline=ink, width=2.5)
    # face features (minimal)
    cv.line([(52, 52), (58, 52)], ink, 2.5)
    cv.line([(70, 52), (76, 52)], ink, 2.5)
    cv.line([(58, 70), (70, 70)], shade(skin, 0.55), 2)
    if acc == "shades":
        cv.rect((48, 47, 62, 56), fill=(16, 16, 20, 255), radius=2)
        cv.rect((66, 47, 80, 56), fill=(16, 16, 20, 255), radius=2)
        cv.line([(62, 50), (66, 50)], (16, 16, 20, 255), 2)
    if acc == "cap":
        cv.poly([(38, 40), (42, 22), (64, 16), (86, 22), (90, 40)], fill=(200, 60, 40, 255), outline=ink, width=2.5)
        cv.poly([(84, 38), (106, 42), (104, 46), (84, 44)], fill=(160, 46, 30, 255), outline=ink, width=2)
    if acc == "security":
        cv.poly([(38, 40), (42, 22), (64, 16), (86, 22), (90, 40)], fill=(24, 28, 34, 255), outline=ink, width=2.5)
        cv.rect((58, 24, 70, 32), fill=(240, 200, 80, 255))
    if acc == "headset":
        cv.arc((34, 20, 94, 80), 180, 360, (30, 30, 34, 255), 5)
        cv.rect((32, 46, 42, 62), fill=(30, 30, 34, 255), radius=3)
        cv.line([(38, 62), (52, 74)], (30, 30, 34, 255), 3)
    return cv.done()


def portraits_sheet():
    sheet = Image.new("RGBA", (512, 256), (0, 0, 0, 0))
    cells = {}
    for i, (key, top, bot, skin, hair, cloth, acc) in enumerate(PORTRAITS):
        x, y = (i % 4) * 128, (i // 4) * 128
        sheet.alpha_composite(portrait(top, bot, skin, hair, cloth, acc), (x, y))
        cells[key] = [x, y, 128, 128]
    return sheet, cells


# --- interaction-menu header banners ------------------------------------------------------------------------------------

BANNERS = [
    ("garage", 0.0, "garage"),
    ("dealership", 0.12, "car"),
    ("gear", -0.08, "wrench"),
    ("spray", 0.2, "spray"),
    ("chop", -0.15, "saw"),
    ("store", 0.06, "bag"),
]


def shift(c, k):
    return tuple(max(0, min(255, int(v + k * 255))) for v in c)


def banner(hue_shift, motif, w=600, h=128, seed=1):
    rnd = random.Random(seed)
    stops = [(0, shift(BRAND[0], hue_shift * 0.4)), (0.45, BRAND[1]), (0.8, BRAND[2]), (1, BRAND[3])]
    img = horizontal_gradient(w, h, stops)
    # sky glow + sun disc right
    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([w * 0.66, h * 0.05, w * 0.66 + h * 0.9, h * 0.95], fill=(255, 220, 160, 120))
    glow = glow.filter(ImageFilter.GaussianBlur(14))
    img.alpha_composite(glow)
    # skyline silhouette
    cv = Canvas(w, h, 2)
    x = 0
    while x < w:
        bw = rnd.randint(18, 46)
        bh = rnd.randint(24, 80) * (1.25 if 0.3 < x / w < 0.6 else 1)
        cv.rect((x, h - bh, x + bw, h), fill=(34, 24, 52, 255))
        if rnd.random() < 0.35:
            cv.rect((x + bw / 2 - 2, h - bh - 14, x + bw / 2 + 2, h - bh), fill=(34, 24, 52, 255))
        for wy in range(int(h - bh + 8), h - 6, 9):
            for wx in range(int(x + 4), int(x + bw - 4), 7):
                if rnd.random() < 0.18:
                    cv.rect((wx, wy, wx + 3, wy + 4), fill=(255, 196, 120, 200))
        x += bw + rnd.randint(0, 4)
    # palms
    for px in (w * 0.08, w * 0.9):
        cv.line([(px, h), (px + 6, h - 70)], (24, 16, 36, 255), 5)
        for a in range(-150, 151, 40):
            ang = math.radians(a - 90)
            cv.line([(px + 6, h - 70), (px + 6 + 30 * math.cos(ang), h - 70 + 16 * math.sin(ang) + 12)],
                    (24, 16, 36, 255), 4)
    sky = cv.done()
    img.alpha_composite(sky)
    # diagonal speed stripes
    stripes = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    sd = ImageDraw.Draw(stripes)
    for i in range(-h, w, 26):
        sd.line([(i, h), (i + h, 0)], fill=(255, 255, 255, 14), width=8)
    img.alpha_composite(stripes)
    # bottom shade so the runtime title (Damion, white) reads
    shade = vertical_gradient(w, h, [(0, (0, 0, 0)), (1, (0, 0, 0))])
    shade.putalpha(vertical_gradient(w, h, [(0, (40, 40, 40)), (1, (120, 120, 120))]).split()[0])
    img.alpha_composite(shade)
    return img.convert("RGBA")


def banners_sheet():
    w, h = 600, 128
    sheet = Image.new("RGBA", (w, h * len(BANNERS)), (0, 0, 0, 0))
    cells = {}
    for i, (key, hs, motif) in enumerate(BANNERS):
        sheet.alpha_composite(banner(hs, motif, w, h, seed=i + 3), (0, i * h))
        cells[key] = [0, i * h, w, h]
    return sheet, cells


# --- wordmark -------------------------------------------------------------------------------------------------------------


def wordmark(w=1024, h=256):
    """HOTWIRE in Kanit Black (white, ink drop shadow, a slight forward lean) with CITY signed across it in Damion."""
    ss = 3
    big = Image.new("RGBA", (w * ss, h * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    f = font("Kanit-900", 170 * ss)
    text = "HOTWIRE"
    cx, cy = w * ss / 2, h * ss * 0.44
    d.text((cx + 10 * ss, cy + 12 * ss), text, font=f, fill=INK + (255,), anchor="mm")
    d.text((cx, cy), text, font=f, fill=(245, 245, 245, 255), anchor="mm", stroke_width=4 * ss,
           stroke_fill=(10, 8, 14, 255))
    # lean forward (shear)
    big = big.transform(big.size, Image.AFFINE, (1, 0.16, -0.16 * big.height / 2, 0, 1, 0), Image.BICUBIC)
    d = ImageDraw.Draw(big)
    fs = font("Damion-400", 118 * ss)
    sx, sy = w * ss * 0.69, h * ss * 0.80
    d.text((sx + 5 * ss, sy + 6 * ss), "City", font=fs, fill=(10, 8, 14, 220), anchor="mm")
    d.text((sx, sy), "City", font=fs, fill=C["accent"] + (255,), anchor="mm", stroke_width=2 * ss,
           stroke_fill=(10, 8, 14, 255))
    img = big.resize((w, h), Image.LANCZOS)
    return img


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    cells = {}
    hud, hud_cells = hud_sheet()
    save(hud, "hud_sheet.png")
    cells["hud"] = hud_cells
    apps, app_cells = apps_sheet()
    save(apps, "apps_sheet.png")
    cells["apps"] = app_cells
    por, por_cells = portraits_sheet()
    save(por, "portraits_sheet.png")
    cells["portraits"] = por_cells
    ban, ban_cells = banners_sheet()
    save(ban, "banners_sheet.png")
    cells["banners"] = ban_cells
    save(wedge(), "wedge.png")
    save(vignette(), "vignette.png")
    save(shard_band(), "shard_band.png")
    shell, shell_meta = phone_shell()
    save(shell, "phone_shell.png")
    cells["phone_shell"] = shell_meta
    save(wordmark(), "wordmark.png")
    with open(os.path.join(OUT_DIR, "cells.json"), "w") as fh:
        json.dump(cells, fh, indent=1, sort_keys=True)
    print("art written to", OUT_DIR)


if __name__ == "__main__":
    main()
