#!/usr/bin/env python3
"""Contact sheet of every VFX texture: on dark (blend mode as used in game), on light, and tinted as the presets
tint it. Output: docs/v2/early/vfx/sheet.png (+ sheet_dark.png / sheet_light.png halves for close inspection).

Usage: python3 tools/vfx/contact_sheet.py [outdir]
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(__file__))
from vfxlib import OUT_DIR, ROOT  # noqa: E402

# key -> (blend, tint rgb 0..255, caption)
ITEMS = [
    ("smoke_puff_a", "alpha", (150, 150, 158), "smoke puff A"),
    ("smoke_puff_b", "alpha", (90, 90, 98), "smoke puff B"),
    ("smoke_puff_c", "alpha", (215, 215, 225), "smoke puff C (wispy)"),
    ("smoke_flipbook", "alpha", (120, 120, 128), "smoke flipbook 4x4"),
    ("tire_smoke", "alpha", (235, 235, 242), "tire smoke 4x4"),
    ("dust_puff", "alpha", (196, 168, 120), "dust / dirt puff"),
    ("fire_flipbook", "add", (255, 150, 50), "fire / nitro flipbook 4x4"),
    ("nitro_jet", "add", (90, 200, 255), "nitro jet (Beam)"),
    ("backfire_burst", "add", (255, 140, 40), "backfire burst 2x2"),
    ("spark_streak", "add", (255, 200, 90), "spark streak"),
    ("speed_line", "add", (220, 240, 255), "speed line"),
    ("glow_dot", "add", (255, 210, 120), "glow dot"),
    ("sparkle_star", "add", (255, 230, 140), "sparkle / glint"),
    ("glare", "add", (255, 50, 70), "siren / lens glare"),
    ("shockwave_ring", "add", (255, 230, 150), "shockwave ring"),
    ("impact_star", "alpha", (255, 214, 64), "impact star (KAPOW)"),
    ("debris_chips", "alpha", (120, 124, 136), "debris chips 4x4"),
    ("water_splash", "alpha", (190, 225, 255), "water splash 2x2"),
    ("cash_bill", "alpha", (255, 255, 255), "cash bill"),
    ("cash_flutter", "alpha", (255, 255, 255), "cash flutter 4x4"),
    ("coin_spin", "alpha", (255, 255, 255), "coin spin 4x4"),
    ("confetti", "alpha", (255, 70, 140), "confetti tumble 4x4"),
    ("skid_mark", "alpha", (24, 24, 26), "skid mark (Trail)"),
    ("headlight_beam", "add", (255, 244, 214), "headlight cone (Beam)"),
    ("underglow", "add", (190, 70, 255), "neon underglow"),
]

TILE = 300
PAD = 14
LABEL = 30
DARK = (17, 19, 26)
LIGHT = (222, 226, 232)


def font(sz):
    for p in ["/usr/share/fonts/opentype/inter/Inter-Bold.otf", "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"]:
        if os.path.exists(p):
            return ImageFont.truetype(p, sz)
    return ImageFont.load_default()


def fit(img, box):
    w, h = img.size
    k = min(box / w, box / h)
    return img.resize((max(1, int(w * k)), max(1, int(h * k))), Image.LANCZOS)


def checker(size, a, b, step=20):
    im = Image.new("RGB", (size, size), a)
    d = ImageDraw.Draw(im)
    for y in range(0, size, step):
        for x in range(0, size, step):
            if (x // step + y // step) % 2:
                d.rectangle([x, y, x + step - 1, y + step - 1], fill=b)
    return im


def composite(bg_rgb, tex, blend, tint):
    bg = np.asarray(bg_rgb, dtype=np.float32) / 255.0
    t = np.asarray(tex, dtype=np.float32) / 255.0
    rgb = t[..., :3] * (np.array(tint, dtype=np.float32) / 255.0)
    a = t[..., 3:4]
    if blend == "add":
        out = bg + rgb * a
    else:
        out = bg * (1 - a) + rgb * a
    return Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8), "RGB")


def panel(key, bg, blend, tint, light_bg=False):
    path = os.path.join(OUT_DIR, key + ".png")
    base = Image.new("RGB", (TILE, TILE), bg)
    if light_bg:
        base = checker(TILE, bg, tuple(max(0, c - 14) for c in bg))
    if not os.path.exists(path):
        d = ImageDraw.Draw(base)
        d.text((TILE / 2, TILE / 2), "missing", font=font(20), fill=(255, 80, 80), anchor="mm")
        return base
    tex = fit(Image.open(path).convert("RGBA"), TILE - 8)
    ox, oy = (TILE - tex.size[0]) // 2, (TILE - tex.size[1]) // 2
    region = base.crop((ox, oy, ox + tex.size[0], oy + tex.size[1]))
    base.paste(composite(region, tex, blend, tint), (ox, oy))
    return base


def build(outdir):
    cols = 3
    rows = (len(ITEMS) + cols - 1) // cols
    cw = TILE * 3 + PAD * 2
    ch = TILE + LABEL
    sheet = Image.new("RGB", (cols * cw + PAD, rows * ch + PAD + 50), (8, 9, 12))
    d = ImageDraw.Draw(sheet)
    d.text((PAD, 14), "Hotwire City VFX library  |  per item: in-game blend on dark  /  on light  /  preset tint",
           font=font(24), fill=(240, 240, 245))
    dark_only = Image.new("RGB", (cols * (TILE + PAD) + PAD, rows * ch + PAD), (8, 9, 12))
    light_only = Image.new("RGB", (cols * (TILE + PAD) + PAD, rows * ch + PAD), (200, 204, 210))
    dd, dl = ImageDraw.Draw(dark_only), ImageDraw.Draw(light_only)
    for i, (key, blend, tint, caption) in enumerate(ITEMS):
        r, c = divmod(i, cols)
        x0, y0 = PAD + c * cw, 50 + r * ch
        p1 = panel(key, DARK, blend, (255, 255, 255))
        p2 = panel(key, LIGHT, "alpha", (255, 255, 255), light_bg=True)
        p3 = panel(key, DARK if blend == "add" else (60, 64, 74), blend, tint)
        if key == "skid_mark":
            p3 = panel(key, (120, 122, 128), blend, tint)
        sheet.paste(p1, (x0, y0 + LABEL))
        sheet.paste(p2, (x0 + TILE, y0 + LABEL))
        sheet.paste(p3, (x0 + TILE * 2, y0 + LABEL))
        d.text((x0 + 4, y0 + 4), f"{key}  -  {caption}", font=font(19), fill=(235, 235, 240))
        xa, ya = PAD + c * (TILE + PAD), PAD + r * ch
        dark_only.paste(p1, (xa, ya + LABEL))
        light_only.paste(p2, (xa, ya + LABEL))
        dd.text((xa + 2, ya + 4), key, font=font(18), fill=(235, 235, 240))
        dl.text((xa + 2, ya + 4), key, font=font(18), fill=(20, 20, 24))
    os.makedirs(outdir, exist_ok=True)
    sheet.save(os.path.join(outdir, "sheet.png"))
    dark_only.save(os.path.join(outdir, "sheet_dark.png"))
    light_only.save(os.path.join(outdir, "sheet_light.png"))
    print("wrote", os.path.relpath(os.path.join(outdir, "sheet.png"), ROOT))


if __name__ == "__main__":
    build(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "docs", "v2", "early", "vfx"))
