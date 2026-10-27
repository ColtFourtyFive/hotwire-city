#!/usr/bin/env python3
"""Build labelled contact sheets from the Sketchfab previews.

Usage: python3 -I tools/sources/contact_sheet.py [--out docs/v2/sourcing]
Writes vehicles_sheet_<n>.png (20 per sheet, grouped by class order) and weapons_sheet.png.
Label: class, slug, triangles, license, real-world size, separate wheels, logo-named parts, file size.
"""
import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "assets" / "source" / "sketchfab"
VEH_ORDER = ["compact", "sedan", "luxury_sedan", "muscle", "sports_coupe", "supercar", "suv", "pickup", "van",
             "police_cruiser", "police_suv", "taxi", "bus", "ambulance", "fire_truck", "armored_truck",
             "box_truck", "motorcycle", "lowrider", "limousine"]
WEP_ORDER = ["pistol", "heavy_pistol", "smg", "assault_rifle", "carbine", "shotgun", "sniper", "minigun",
             "melee", "grenade"]
CW, CH, LH = 480, 270, 62


def font(sz, bold=False):
    names = ["DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"]
    for n in names:
        for base in ["/usr/share/fonts/truetype/dejavu/", "/usr/share/fonts/dejavu/"]:
            try:
                return ImageFont.truetype(base + n, sz)
            except Exception:
                pass
    return ImageFont.load_default()


def cell(meta, d):
    im = Image.new("RGB", (CW, CH + LH), (22, 22, 24))
    p = d / "preview.png"
    if p.exists():
        main = Image.open(p).convert("RGB").resize((CW, CH), Image.LANCZOS)
        im.paste(main, (0, 0))
        ins = d / "preview_inset.png"
        if ins.exists():
            t = Image.open(ins).convert("RGB").resize((CW // 3, CH // 3), Image.LANCZOS)
            im.paste((200, 200, 200), (CW - t.width - 6, 4, CW - 2, t.height + 8))
            im.paste(t, (CW - t.width - 4, 6))
    else:
        ImageDraw.Draw(im).text((20, CH // 2), "no preview", fill=(255, 90, 90), font=font(18))
    dr = ImageDraw.Draw(im)
    an = meta.get("analysis") or {}
    dims = an.get("dims_m") or [0, 0, 0]
    if meta.get("kind") == "vehicle":
        size = f"{dims[1]:.1f}x{dims[0]:.1f}x{dims[2]:.1f}m"
        wheels = "wheels:SEP" if an.get("wheels_separate") else "wheels:MERGED?"
    else:
        size = f"{dims[0] * 100:.0f}cm"
        wheels = ""
    tris = an.get("triangles") or meta.get("faceCount") or 0
    lic = {"by": "CC-BY", "cc0": "CC0"}.get(meta["license"]["slug"], meta["license"]["slug"])
    logo = "  logo-parts" if an.get("logo_named") else ""
    y = CH + 3
    dr.text((6, y), meta["class"].upper().replace("_", " "), fill=(255, 200, 80), font=font(15, True))
    dr.text((6 + 9 * len(meta["class"]) + 18, y + 1), f"@{meta['author']['username']}"[:30], fill=(150, 150, 160), font=font(13))
    dr.text((6, y + 20), meta["slug"][:58], fill=(235, 235, 235), font=font(13))
    col = (140, 220, 140) if an.get("wheels_separate") or meta.get("kind") != "vehicle" else (255, 150, 120)
    dr.text((6, y + 39), f"{tris / 1000:.1f}k tris | {lic} | {size} | {meta['fileBytes'] / 1e6:.1f}MB | {wheels}{logo}",
            fill=col, font=font(13))
    return im


def sheet(cells, cols, title, out):
    rows = (len(cells) + cols - 1) // cols
    W, H = cols * CW + (cols + 1) * 6, rows * (CH + LH) + (rows + 1) * 6 + 44
    s = Image.new("RGB", (W, H), (12, 12, 14))
    dr = ImageDraw.Draw(s)
    dr.text((10, 10), title, fill=(255, 255, 255), font=font(22, True))
    for i, c in enumerate(cells):
        x = 6 + (i % cols) * (CW + 6)
        y = 44 + 6 + (i // cols) * (CH + LH + 6)
        s.paste(c, (x, y))
    s.save(out, optimize=True)
    print("wrote", out, s.size)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "docs" / "v2" / "sourcing"))
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    items = []
    for mp in sorted(SRC.glob("*/meta.json")):
        m = json.loads(mp.read_text())
        items.append((m, mp.parent))
    veh = [x for x in items if x[0].get("kind") == "vehicle"]
    wep = [x for x in items if x[0].get("kind") == "weapon"]
    veh.sort(key=lambda x: (VEH_ORDER.index(x[0]["class"]) if x[0]["class"] in VEH_ORDER else 99, x[0]["slug"]))
    wep.sort(key=lambda x: (WEP_ORDER.index(x[0]["class"]) if x[0]["class"] in WEP_ORDER else 99, x[0]["slug"]))
    per = 20
    n = (len(veh) + per - 1) // per
    for k in range(n):
        chunk = veh[k * per:(k + 1) * per]
        classes = []
        for m, _ in chunk:
            if m["class"] not in classes:
                classes.append(m["class"])
        sheet([cell(m, d) for m, d in chunk], 4,
              f"Sketchfab vehicle candidates {k + 1}/{n}  ({', '.join(classes)})  - main: 3/4 front, inset: opposite 3/4",
              out / f"vehicles_sheet_{k + 1}.png")
    if wep:
        sheet([cell(m, d) for m, d in wep], 5, f"Sketchfab weapon candidates ({len(wep)})", out / "weapons_sheet.png")


if __name__ == "__main__":
    main()
