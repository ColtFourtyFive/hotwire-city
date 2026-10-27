#!/usr/bin/env python3
"""Raw Higgsfield renders (assets/cityart/raw/*.png, gitignored) -> final Roblox-sized PNGs in
assets/cityart/{logos,billboards,signs,posters,graffiti,loading}/ and contact sheets in docs/v2/early/cityart/.

usage: python3 -I tools/cityart/process.py [--fonts DIR] [--only ID_SUBSTRING] [--sheets-only]
DIR holds the OFL fonts used for re-lettered text (Kanit-900.ttf, Oswald-*.ttf, Montserrat-*.ttf).
Raw files are untrusted downloads; this script only reads them as images.
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import spec  # noqa: E402

RAW = os.path.join(ROOT, "assets", "cityart", "raw")
OUT = os.path.join(ROOT, "assets", "cityart")
SHEETS = os.path.join(ROOT, "docs", "v2", "early", "cityart")
FONTS = os.environ.get("CITYART_FONTS", "")


def font(name, size):
    return ImageFont.truetype(os.path.join(FONTS, name), size)


def ratio(aspect):
    a, b = aspect.split(":")
    return float(a) / float(b)


def crop_to(im, aspect, o=0.5):
    """Crop to the aspect along the over-long axis; o picks the window (0 = top/left, 1 = bottom/right)."""
    w, h = im.size
    r = ratio(aspect)
    if w / h > r:  # too wide -> crop width
        nw = round(h * r)
        x = round((w - nw) * o)
        return im.crop((x, 0, x + nw, h))
    nh = round(w / r)
    y = round((h - nh) * o)
    return im.crop((0, y, w, y + nh))


def dehalo(im):
    """Cut soft semi-transparent glows: keep solid pixels plus a 2 px antialias rim around them."""
    a = np.array(im.getchannel("A"))
    solid = Image.fromarray(((a >= 200) * 255).astype(np.uint8))
    rim = np.array(solid.filter(ImageFilter.MaxFilter(5)))
    a2 = np.where(rim > 0, a, 0).astype(np.uint8)
    im = im.copy()
    im.putalpha(Image.fromarray(a2))
    return im


def fit_alpha(im, size, margin=0.06):
    """Trim to the alpha bbox and centre on a transparent canvas of `size` with a margin."""
    a = np.array(im.getchannel("A"))
    a[a < 10] = 0
    im = im.copy()
    im.putalpha(Image.fromarray(a))
    bbox = im.getbbox()
    im = im.crop(bbox)
    W, H = size
    mw, mh = W * (1 - 2 * margin), H * (1 - 2 * margin)
    s = min(mw / im.width, mh / im.height)
    im = im.resize((max(1, round(im.width * s)), max(1, round(im.height * s))), Image.LANCZOS)
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))
    canvas.paste(im, ((W - im.width) // 2, (H - im.height) // 2), im)
    # clear colour under fully transparent pixels so mip-mapping does not bleed dark fringes
    arr = np.array(canvas)
    arr[arr[:, :, 3] == 0, :3] = 255
    return Image.fromarray(arr)


# ---- per-item fixes (re-lettered text, wordmarks) ------------------------------------------------------------------

def fix_hotwire_motors_bar(im):
    """The generated bottom bar is clipped by the 2:1 crop: repaint it with exact lettering."""
    W, H = im.size
    bar = round(H * 0.13)
    d = ImageDraw.Draw(im)
    d.rectangle([0, H - bar, W, H], fill=(255, 138, 61))
    d.rectangle([0, H - bar, W, H - bar + 3], fill=(30, 30, 30))
    f = font("Kanit-900.ttf", round(bar * 0.62))
    text = "HOTWIRE MOTORS  •  CROWN BOULEVARD"
    tw = d.textlength(text, font=f)
    # fake italic: draw on a layer and shear it
    layer = Image.new("RGBA", (W, bar), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    ld.text(((W - tw) / 2, bar * 0.5), text, font=f, fill=(30, 30, 30), anchor="lm")
    layer = layer.transform(layer.size, Image.AFFINE, (1, 0.18, -bar * 0.09, 0, 1, 0), Image.BICUBIC)
    im.paste(layer, (0, H - bar), layer)
    return im


def wordmark(im, top=False):
    """HOTWIRE CITY lock-up bottom-left (or top-left when `top`): HOTWIRE in Kanit 900 Accent orange with a dark
    stroke, a rule plus tracked CITY in Oswald underneath, sheared slightly forward."""
    W, H = im.size
    im = im.convert("RGBA")
    # soft dark gradient behind the mark so it reads on any art
    grad = Image.new("L", (W, H), 0)
    gd = ImageDraw.Draw(grad)
    for y in range(H):
        t = max(0.0, ((H - y) if top else y) - H * 0.5) / (H * 0.5)
        gd.line([(0, y), (W, y)], fill=round(165 * t * t))
    shade = Image.new("RGBA", (W, H), (10, 8, 20, 255))
    shade.putalpha(grad)
    im = Image.alpha_composite(im, shade)

    ink = (20, 14, 30, 255)
    orange = (255, 138, 61, 255)
    big = font("Kanit-900.ttf", round(H * 0.13))
    small = font("Oswald-600.ttf", round(H * 0.052))
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    x = round(W * 0.045)
    base = round(H * (0.2 if top else 0.82))  # HOTWIRE baseline
    hw = ld.textlength("HOTWIRE", font=big)
    ld.text((x + 5, base + 5), "HOTWIRE", font=big, fill=(0, 0, 0, 150), anchor="ls")
    ld.text((x, base), "HOTWIRE", font=big, fill=orange, anchor="ls", stroke_width=4, stroke_fill=ink)
    # tracked CITY, right-aligned under HOTWIRE, with an orange rule filling the space to its left
    track = H * 0.03
    letters = "CITY"
    widths = [ld.textlength(c, font=small) for c in letters]
    cw = sum(widths) + track * (len(letters) - 1)
    cy = base + round(H * 0.085)
    cx = x + hw - cw
    for c, w in zip(letters, widths):
        ld.text((cx, cy), c, font=small, fill=(244, 244, 244, 255), anchor="ls", stroke_width=2, stroke_fill=ink)
        cx += w + track
    ry = cy - round(H * 0.019)
    rh = max(3, round(H * 0.009))
    ld.rectangle([x + 2, ry - rh // 2 - 2, x + hw - cw - track * 1.2 + 2, ry + rh // 2 + 2], fill=ink)
    ld.rectangle([x + 4, ry - rh // 2, x + hw - cw - track * 1.2, ry + rh // 2], fill=orange)
    layer = layer.transform(layer.size, Image.AFFINE, (1, 0.12, -base * 0.12, 0, 1, 0), Image.BICUBIC)
    return Image.alpha_composite(im, layer).convert("RGB")


def blur_spots(im, spots, radius=5):
    """Smear small ellipses (x, y, rx, ry) in final pixel coords, e.g. car-grille emblems that read like real brands."""
    mask = Image.new("L", im.size, 0)
    d = ImageDraw.Draw(mask)
    for x, y, rx, ry in spots:
        d.ellipse([x - rx, y - ry, x + rx, y + ry], fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(2))
    return Image.composite(im.filter(ImageFilter.GaussianBlur(radius)), im, mask)


def bokeh(im, box, feather=24, radius=6):
    """Depth-of-field blur inside box (x0, y0, x1, y1) with a feathered edge: turns AI pseudo-lettering on
    background signage into unreadable neon glow."""
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rectangle(box, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(feather))
    return Image.composite(im.filter(ImageFilter.GaussianBlur(radius)), im, mask)


FIXES = {"hotwire_motors_bar": fix_hotwire_motors_bar}


def process(cat, item):
    src = os.path.join(RAW, item["raw"] + ".png")
    if not os.path.exists(src):
        return None
    im = Image.open(src)
    size = spec.SIZES[item["aspect"]]
    if item.get("alpha"):
        im = im.convert("RGBA")
        if cat == "logos" and item["brand"] in spec.LOGO_DEHALO:
            im = dehalo(im)
        im = fit_alpha(im, size, margin=0.06 if cat == "logos" else 0.04)
    else:
        im = im.convert("RGB")
        im = crop_to(im, item["aspect"], item.get("o", 0.5)).resize(size, Image.LANCZOS)
        if item.get("fix"):
            im = FIXES[item["fix"]](im)
        if item.get("blur"):
            im = blur_spots(im, item["blur"])
        if item.get("bokeh"):
            im = bokeh(im, item["bokeh"])
        if cat == "loading":
            im = wordmark(im, top=item.get("wordmark") == "top")
    dst = os.path.join(OUT, cat, item["id"] + ".png")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    im.save(dst, optimize=True)
    return dst


def checker(w, h, s=16):
    im = Image.new("RGB", (w, h), (92, 92, 96))
    d = ImageDraw.Draw(im)
    for y in range(0, h, s):
        for x in range(0, w, s):
            if (x // s + y // s) % 2:
                d.rectangle([x, y, x + s - 1, y + s - 1], fill=(120, 120, 124))
    return im


def sheet(name, files, cell, cols, title):
    if not files:
        return
    cw, ch = cell
    pad, lab, head = 8, 22, 40
    rows = (len(files) + cols - 1) // cols
    W = cols * (cw + pad) + pad
    H = head + rows * (ch + lab + pad) + pad
    s = Image.new("RGB", (W, H), (22, 22, 24))
    d = ImageDraw.Draw(s)
    d.text((pad, 8), title, font=font("Oswald-600.ttf", 22), fill=(255, 138, 61))
    f = font("Oswald-400.ttf", 14)
    for i, p in enumerate(files):
        im = Image.open(p).convert("RGBA")
        x = pad + (i % cols) * (cw + pad)
        y = head + (i // cols) * (ch + lab + pad)
        bg = checker(cw, ch)
        im.thumbnail((cw, ch), Image.LANCZOS)
        bg.paste(im, ((cw - im.width) // 2, (ch - im.height) // 2), im)
        s.paste(bg, (x, y))
        n = os.path.splitext(os.path.basename(p))[0]
        w, h = Image.open(p).size
        d.text((x + 2, y + ch + 3), f"{n}  {w}x{h}", font=f, fill=(225, 225, 225))
    os.makedirs(SHEETS, exist_ok=True)
    out = os.path.join(SHEETS, name)
    s.save(out, optimize=True)
    print("sheet", out, s.size)


def main():
    global FONTS
    ap = argparse.ArgumentParser()
    ap.add_argument("--fonts", default=FONTS)
    ap.add_argument("--only", default=None)
    ap.add_argument("--sheets-only", action="store_true")
    a = ap.parse_args()
    FONTS = a.fonts
    done = {}
    missing = []
    for cat, item in spec.all_items():
        dst = os.path.join(OUT, cat, item["id"] + ".png")
        if a.sheets_only or (a.only and a.only not in item["id"]):
            if os.path.exists(dst):
                done.setdefault(cat, []).append(dst)
            continue
        p = process(cat, item)
        if p:
            done.setdefault(cat, []).append(p)
        else:
            missing.append(item["id"])
    print({k: len(v) for k, v in done.items()}, "missing:", missing)
    sheet("logos.png", done.get("logos", []), (220, 220), 6, "CITY ART / LOGOS (512x512 alpha)")
    bb = done.get("billboards", [])
    sheet("billboards_wide.png", [p for p in bb if "/bb_" in p], (400, 200), 3, "CITY ART / BILLBOARDS 2:1 (1024x512)")
    sheet("billboards_portrait.png", [p for p in bb if "/bbp_" in p], (180, 360), 6, "CITY ART / BILLBOARDS 1:2 (512x1024)")
    sg = done.get("signs", [])
    sheet("signs_fascia.png", [p for p in sg if Image.open(p).size == (1024, 384)], (400, 150), 3,
          "CITY ART / STOREFRONT FASCIA 8:3 (1024x384)")
    sheet("signs_awning_pylon.png", [p for p in sg if Image.open(p).size != (1024, 384)], (300, 300), 5,
          "CITY ART / AWNINGS 2:1, PAINTED 2:1, PYLONS 1:2")
    sheet("posters.png", done.get("posters", []), (200, 300), 7, "CITY ART / POSTERS, FLYERS, BUS-STOP ADS (2:3)")
    sheet("graffiti.png", done.get("graffiti", []), (300, 150), 4, "CITY ART / GRAFFITI TAGS, STENCILS (alpha), MURALS")
    sheet("loading.png", done.get("loading", []), (512, 288), 2, "CITY ART / LOADING KEY ART (1024x576)")


if __name__ == "__main__":
    main()
