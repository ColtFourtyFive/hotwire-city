#!/usr/bin/env python3
"""Scout Sketchfab candidates per vehicle/weapon class and build thumbnail grids for human review.

Usage:
  python3 -I tools/sources/scout_sketchfab.py [--only cls1,cls2] [--top 20] [--out DIR]

Writes:
  docs/v2/sourcing/scout_candidates.json   (all merged search results per class, no secrets)
  <out>/<class>.jpg                        (thumbnail grid: index, faces, likes, license, size, name)
The thumbnails are Sketchfab's public preview images; nothing is downloaded beyond them.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import io
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sketchfab as sf  # noqa: E402
from PIL import Image, ImageDraw, ImageFont  # noqa: E402

ROOT = sf.ROOT
OUT_JSON = ROOT / "docs" / "v2" / "sourcing" / "scout_candidates.json"

VEHICLE_QUERIES = {
    "compact": ["hatchback car", "compact car", "hatchback"],
    "sedan": ["sedan car", "sedan", "family car"],
    "luxury_sedan": ["luxury sedan", "executive sedan", "luxury car sedan"],
    "muscle": ["muscle car", "american muscle car"],
    "sports_coupe": ["sports car coupe", "sport coupe", "sports car"],
    "supercar": ["supercar", "hypercar"],
    "suv": ["suv car", "suv", "4x4 offroad suv"],
    "pickup": ["pickup truck", "pickup"],
    "van": ["van", "cargo van", "minivan"],
    "police_cruiser": ["police car", "police cruiser", "police interceptor"],
    "police_suv": ["police suv", "police 4x4"],
    "taxi": ["taxi", "taxi cab"],
    "bus": ["city bus", "bus"],
    "ambulance": ["ambulance"],
    "fire_truck": ["fire truck", "fire engine"],
    "armored_truck": ["armored truck", "armoured van", "cash transit van", "swat truck"],
    "box_truck": ["box truck", "delivery truck", "truck lorry"],
    "motorcycle": ["sport motorcycle", "sportbike", "motorcycle"],
    "lowrider": ["lowrider", "impala 1964", "chevrolet impala"],
    "limousine": ["limousine", "stretch limo", "limo"],
}
WEAPON_QUERIES = {
    "pistol": ["pistol", "glock", "handgun"],
    "heavy_pistol": ["revolver", "desert eagle", "magnum revolver"],
    "smg": ["smg", "submachine gun", "mp5", "uzi"],
    "assault_rifle": ["assault rifle", "ak-47", "akm"],
    "carbine": ["m4a1", "carbine rifle", "ar-15"],
    "shotgun": ["pump shotgun", "shotgun", "remington 870"],
    "sniper": ["sniper rifle", "bolt action rifle"],
    "minigun": ["minigun", "gatling gun"],
    "melee": ["baseball bat", "combat knife", "knife"],
    "grenade": ["frag grenade", "grenade"],
}

# names that are obviously off-brief (wrecks, toys, stylised) – still kept in json, just ranked last
BAD = re.compile(r"burn|destroy|wreck|abandon|rust|\btoy\b|cartoon|lego|stylized|stylised|voxel|minecraft|"
                 r"chibi|cute|kids|broken|dirty|crash|damaged|old |scan of|diorama|scene|lowpoly pack|"
                 r"sci-?fi|fantasy|futur|cyber|hover|zombie|apocalyp|nerf|water ?gun|paper|clay|sketch|"
                 r"wip|concept", re.I)


KEEP = ["uid", "name", "author", "faces", "likes", "license_hint", "url", "glb_size", "textures", "bad_name",
        "too_big", "queries"]


def save(data):
    """Write the candidate index compactly (no thumbnails/tags) - it lives in docs/."""
    out = {}
    for k, v in data.items():
        out[k] = {kk: vv for kk, vv in v.items() if kk != "items"}
        out[k]["items"] = [{f: r.get(f) for f in KEEP} for r in v["items"]]
    OUT_JSON.parent.mkdir(parents=True, exist_ok=True)
    OUT_JSON.write_text(json.dumps(out, separators=(",", ":")))


def font(sz):
    for p in ["/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
              str(ROOT / "tools/blender/buildkit/_cache/fonts/Oswald.ttf")]:
        try:
            return ImageFont.truetype(p, sz)
        except Exception:
            pass
    return ImageFont.load_default()


def gather(cls, queries, max_faces, min_faces, categories=None):
    merged = {}
    for q in queries:
        try:
            res = sf.search(q, "both", max_faces=max_faces, min_faces=min_faces, count=24, categories=categories)
        except Exception as e:
            print(f"[scout] {cls}/{q}: {e}", file=sys.stderr)
            continue
        for r in res:
            r.setdefault("queries", [])
            if r["uid"] in merged:
                merged[r["uid"]]["queries"].append(q)
            else:
                r["queries"] = [q]
                merged[r["uid"]] = r
    items = list(merged.values())
    for r in items:
        r["bad_name"] = bool(BAD.search(r["name"] or ""))
        r["too_big"] = bool(r.get("glb_size") and r["glb_size"] > 60e6 and
                            (not r.get("gltf_size") or r["gltf_size"] > 60e6))
    items.sort(key=lambda r: (r["bad_name"], r["too_big"], -(r["likes"] or 0)))
    return items


def grid(cls, items, out, top):
    items = items[:top]
    cw, ch, cols = 320, 220, 5
    rows = (len(items) + cols - 1) // cols or 1
    W, H = cols * cw, rows * ch + 30
    img = Image.new("RGB", (W, H), (24, 24, 26))
    d = ImageDraw.Draw(img)
    f1, f2 = font(13), font(18)
    d.text((8, 6), f"{cls}  ({len(items)} shown)", fill=(255, 255, 255), font=f2)

    def fetch(r):
        try:
            return Image.open(io.BytesIO(sf._fetch_bytes(r["thumb"], 3_000_000))).convert("RGB") if r.get("thumb") else None
        except Exception:
            return None

    with cf.ThreadPoolExecutor(6) as ex:
        thumbs = list(ex.map(fetch, items))
    for i, (r, t) in enumerate(zip(items, thumbs)):
        x, y = (i % cols) * cw, 30 + (i // cols) * ch
        if t:
            t.thumbnail((cw - 6, ch - 46))
            img.paste(t, (x + 3 + (cw - 6 - t.width) // 2, y + 3))
        col = (255, 120, 120) if (r["bad_name"] or r["too_big"]) else (230, 230, 230)
        size = (r.get("glb_size") or 0) / 1e6
        d.text((x + 4, y + ch - 42), f"#{i} {r['faces'] or 0}f {r['likes'] or 0}L {r['license_hint']} {size:.0f}MB",
               fill=(255, 220, 120), font=f1)
        d.text((x + 4, y + ch - 24), (r["name"] or "")[:40], fill=col, font=f1)
    img.save(out / f"{cls}.jpg", quality=85)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--out", required=True)
    ap.add_argument("--user", default=None, help="grid of one author's models instead of class searches")
    ap.add_argument("--q", default="")
    ap.add_argument("--name", default=None, help="name for an ad-hoc --q/--user grid")
    ap.add_argument("--kind", default="vehicle")
    a = ap.parse_args()
    if a.user or a.name:
        out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
        cat = "cars-vehicles" if a.kind == "vehicle" else "weapons-military" if a.kind == "weapon" else None
        items = sf.search(a.q, "both", max_faces=150000, min_faces=1000, user=a.user, pages=8 if a.user else 2,
                          categories=None if a.user else cat)
        for r in items:
            r["bad_name"] = bool(BAD.search(r["name"] or "")); r["too_big"] = False
        name = a.name or a.user
        data = json.loads(OUT_JSON.read_text()) if OUT_JSON.exists() else {}
        data["_adhoc_" + name] = {"kind": a.kind, "queries": [a.q], "user": a.user, "items": items}
        save(data)
        for i in range(0, len(items), a.top):
            grid(f"{name}_{i // a.top}", items[i:i + a.top], out, a.top)
        print(f"[scout] {name}: {len(items)}")
        return
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    only = set(filter(None, a.only.split(",")))
    data = json.loads(OUT_JSON.read_text()) if OUT_JSON.exists() else {}
    jobs = [(c, q, "vehicle", 150000, 3000, "cars-vehicles") for c, q in VEHICLE_QUERIES.items()] + \
           [(c, q, "weapon", 80000, 400, "weapons-military") for c, q in WEAPON_QUERIES.items()]
    for cls, queries, kind, mx, mn, cat in jobs:
        if only and cls not in only:
            continue
        items = gather(cls, queries, mx, mn, cat)
        data[cls] = {"kind": kind, "queries": queries, "items": items}
        grid(cls, items, out, a.top)
        print(f"[scout] {cls}: {len(items)} candidates")
        save(data)


if __name__ == "__main__":
    main()
