#!/usr/bin/env python3
"""Contact sheet of the 8 generated player looks (docs/v2/evidence/characters_lineup.jpg).

Each card is one look from tools/characters/dump_specs.luau (LookCodec.seeded, picked for variety): the body bundle's
catalog render (the realistic Base Body / Rthro frame), the skin tone swatch, and the catalog thumbnails of the items
the HumanoidDescription wears (dynamic head, hair, every layered garment, shoes), with the engine result from
tools/characters/cloud_looks.py (accessories loaded, body height). Thumbnails come from thumbnails.roblox.com
(public, no credentials) and are cached in a scratch folder.

usage (repo root):
  python3 -I tools/characters/lineup.py SPECS.json ENGINE.json OUT.jpg CACHE_DIR
"""
import io
import json
import os
import sys
import time
import urllib.request

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
FONTS = os.path.join(ROOT, "assets", "ui", "fonts")
UA = {"User-Agent": "Mozilla/5.0 (HotwireCity lineup sheet)"}
STUD_M = 0.28

BG = (12, 12, 13)
CARD = (24, 24, 26)
PANEL = (34, 34, 37)
TEXT = (240, 240, 240)
DIM = (155, 155, 155)
ACCENT = (255, 138, 61)
GREEN = (114, 204, 114)

KIND_LABEL = {
    "Hair": "HAIR",
    "TShirt": "TEE",
    "Shirt": "SHIRT",
    "Sweater": "SWEATER",
    "Jacket": "JACKET",
    "Pants": "PANTS",
    "Shorts": "SHORTS",
    "DressSkirt": "SKIRT",
    "LeftShoe": "SHOES",
}


def font(name, size):
    return ImageFont.truetype(os.path.join(FONTS, name + ".ttf"), size)


def get(url, binary=False, tries=4):
    err = None
    for k in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=40) as r:
                data = r.read()
                return data if binary else json.loads(data)
        except Exception as e:  # noqa: BLE001
            err = e
            time.sleep(1 + k)
    raise RuntimeError(f"{url}: {err}")


def thumbs(kind, ids, cache):
    """kind 'assets' | 'bundles' -> {id: PIL image}; batched, cached as PNG files."""
    out, need = {}, []
    for i in ids:
        p = os.path.join(cache, f"{kind}_{i}.png")
        if os.path.exists(p):
            out[i] = Image.open(p).convert("RGBA")
        else:
            need.append(i)
    for n in range(0, len(need), 30):
        chunk = need[n:n + 30]
        if kind == "assets":
            url = ("https://thumbnails.roblox.com/v1/assets?assetIds=" + ",".join(map(str, chunk))
                   + "&returnPolicy=PlaceHolder&size=420x420&format=Png&isCircular=false")
        else:
            url = ("https://thumbnails.roblox.com/v1/bundles/thumbnails?bundleIds=" + ",".join(map(str, chunk))
                   + "&size=420x420&format=Png&isCircular=false")
        for _ in range(6):
            data = get(url).get("data") or []
            pending = [d for d in data if d.get("state") != "Completed"]
            if not pending:
                break
            time.sleep(3)
        for d in data:
            if d.get("state") == "Completed" and d.get("imageUrl"):
                img = Image.open(io.BytesIO(get(d["imageUrl"], binary=True))).convert("RGBA")
                img.save(os.path.join(cache, f"{kind}_{d['targetId']}.png"))
                out[d["targetId"]] = img
    return out


def paste_fit(dst, img, box, bg=None):
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    if bg:
        ImageDraw.Draw(dst).rectangle(box, fill=bg)
    if img is None:
        return
    im = img.copy()
    im.thumbnail((w, h), Image.LANCZOS)
    dst.alpha_composite(im, (x0 + (w - im.width) // 2, y0 + (h - im.height) // 2))


def gradient(w, h, top, bottom):
    g = Image.new("RGBA", (w, h))
    d = ImageDraw.Draw(g)
    for y in range(h):
        t = y / max(1, h - 1)
        d.line([(0, y), (w, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,))
    return g


def main() -> int:
    if len(sys.argv) < 5:
        print(__doc__)
        return 2
    specs = json.load(open(sys.argv[1]))
    engine = json.load(open(sys.argv[2]))
    out_path, cache = sys.argv[3], sys.argv[4]
    os.makedirs(cache, exist_ok=True)
    looks = specs["lineup"][:8]
    eng = {r.get("key"): r for r in (engine.get("result", {}).get("lineup") or [])}
    summ = engine.get("summary", {})

    asset_ids, bundle_ids = set(), set()
    for lk in looks:
        s = lk["spec"]
        asset_ids.add(s["head"])
        bundle_ids.add(lk["bodyBundle"])
        for a in s["accessories"]:
            if a["kind"] in KIND_LABEL:
                asset_ids.add(a["id"])
    at = thumbs("assets", sorted(asset_ids), cache)
    bt = thumbs("bundles", sorted(bundle_ids), cache)

    cols, rows = 4, 2
    cw, ch, gap, margin, head_h = 470, 760, 18, 28, 150
    W = margin * 2 + cols * cw + (cols - 1) * gap
    H = margin * 2 + head_h + rows * ch + (rows - 1) * gap + 40
    sheet = Image.new("RGBA", (W, H), BG + (255,))
    d = ImageDraw.Draw(sheet)
    f_title = font("Oswald-600", 46)
    f_sub = font("Montserrat-500", 19)
    f_card = font("Oswald-600", 27)
    f_card2 = font("Oswald-400", 21)
    f_small = font("Montserrat-500", 16)
    f_tag = font("Oswald-500", 15)

    d.rectangle([0, 0, W, 6], fill=ACCENT)
    d.text((margin, margin), "HOTWIRE CITY  ·  PLAYER LOOKS", font=f_title, fill=TEXT)
    sub1 = ("8 generated looks (LookCodec.seeded, picked for variety)  ·  realistic Base Body / Rthro frames, "
            "dynamic heads, layered clothing, mocap walk packs")
    sub2 = (f"Real engine (Open Cloud Luau task, place v{summ.get('placeVersion', '?')}): "
            f"{summ.get('items', 0) - summ.get('itemsFailed', 0)}/{summ.get('items', 0)} accessories, "
            f"{summ.get('bodies', 0) - summ.get('bodiesFailed', 0)}/{summ.get('bodies', 0)} bodies, "
            f"{summ.get('faces', 0) - summ.get('facesFailed', 0)}/{summ.get('faces', 0)} heads, "
            f"{summ.get('walkStyles', 0) - summ.get('walkStylesFailed', 0)}/{summ.get('walkStyles', 0)} walk styles, "
            f"{summ.get('looks', 0) - summ.get('looksIncomplete', 0)}/{summ.get('looks', 0)} full looks load complete. "
            "Item art: Roblox catalog thumbnails.")
    d.text((margin, margin + 62), sub1, font=f_sub, fill=DIM)
    d.text((margin, margin + 90), sub2, font=f_sub, fill=DIM)

    for n, lk in enumerate(looks):
        cx = margin + (n % cols) * (cw + gap)
        cy = margin + head_h + (n // cols) * (ch + gap)
        d.rectangle([cx, cy, cx + cw, cy + ch], fill=CARD)
        lab = lk["labels"]
        s = lk["spec"]
        d.text((cx + 18, cy + 12), f"{n + 1:02d}  {lab['outfit'].upper()}", font=f_card, fill=TEXT)
        d.text((cx + 18, cy + 48), lab["variant"], font=f_card2, fill=ACCENT)
        # body frame render on a studio gradient + skin swatch
        top = cy + 84
        body_box = (cx + 18, top, cx + cw - 18, top + 300)
        sheet.alpha_composite(gradient(body_box[2] - body_box[0], 300, (58, 60, 64), (22, 22, 24)), body_box[:2])
        paste_fit(sheet, bt.get(lk["bodyBundle"]), (body_box[0] + 60, top + 6, body_box[2] - 60, top + 274))
        skin = tuple(s["skin"])
        d.ellipse([cx + 32, top + 14, cx + 76, top + 58], fill=skin, outline=(240, 240, 240), width=2)
        d.text((cx + 86, top + 16), f"{lab['skin']} skin", font=f_small, fill=TEXT)
        d.text((cx + 86, top + 36), f"{lab['body']} build  ·  {lab['face']} face", font=f_small, fill=DIM)
        cap = "catalog render of the build's bundle; in game: the items below"
        d.text((body_box[0] + 10, top + 300 - 22), cap, font=f_tag, fill=DIM)
        # items: head, hair, garments, shoes
        items = [("HEAD", s["head"])]
        for a in s["accessories"]:
            if a["kind"] in KIND_LABEL:
                items.append((KIND_LABEL[a["kind"]], a["id"]))
        items.sort(key=lambda kv: ["HEAD", "HAIR", "TEE", "SHIRT", "SWEATER", "JACKET", "PANTS", "SHORTS", "SKIRT",
                                   "SHOES"].index(kv[0]))
        tile, tg = 100, 10
        ix0, iy0 = cx + 18, top + 316
        for k, (label, aid) in enumerate(items[:8]):
            x = ix0 + (k % 4) * (tile + tg)
            y = iy0 + (k // 4) * (tile + 26)
            d.rectangle([x, y, x + tile, y + tile], fill=PANEL)
            paste_fit(sheet, at.get(aid), (x + 4, y + 4, x + tile - 4, y + tile - 4))
            d.text((x + 2, y + tile + 3), label, font=f_tag, fill=DIM)
        # footer: hair, walk, engine
        fy = cy + ch - 78
        d.text((cx + 18, fy), f"Hair: {lab['hair']} ({lab['hairColor'].lower()})  ·  Walk: {lab['walk']}",
               font=f_small, fill=TEXT)
        e = eng.get(lk["key"]) or {}
        if e.get("ok"):
            h = e.get("height") or 0
            typed = "" if e.get("missingGroups") else ", types ok"
            line = (f"Engine: {e.get('got')}/{e.get('want')} loaded{typed}  ·  body {h:.1f} studs "
                    f"({h * STUD_M:.2f} m)")
            colour = GREEN if e.get("got") == e.get("want") and not e.get("missingGroups") else ACCENT
        else:
            line, colour = "Engine: not checked", DIM
        d.text((cx + 18, fy + 22), line, font=f_small, fill=colour)
        d.text((cx + 18, fy + 44), f"look {lk['key']}", font=f_small, fill=DIM)

    d.text((margin, H - margin - 18),
           "Roblox catalog items only (no uploads of faces or people)  ·  never the anime (979-987) or blocky "
           "(238/239) bodies  ·  in-game renders: studio/jobs/0016-characters.md",
           font=f_small, fill=DIM)
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    sheet.convert("RGB").save(out_path, quality=88)
    print("wrote", out_path, sheet.size)
    return 0


if __name__ == "__main__":
    sys.exit(main())
