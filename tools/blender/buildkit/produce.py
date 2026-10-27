#!/usr/bin/env python3
"""Production export of the game building set (variants.py) -> assets/buildings/.

    python3 -I tools/blender/buildkit/produce.py                    # every variant
    python3 -I tools/blender/buildkit/produce.py --only tower_hero640 midtown_w60f6
    python3 -I tools/blender/buildkit/produce.py --family house --preview /tmp/houses   # + one Cycles preview each

Writes, per variant, assets/buildings/glb/<key>.glb (light GLB: geometry + UVs only; the Roblox importer ignores
glTF colour factors and would turn embedded images into one Image asset per building, so materials are applied at
runtime from Config/Buildings) and assets/buildings/glb/<key>.json, then assets/buildings/catalog.json with every
variant's family, footprint, height, body box, parts (role, tris, material set / colour) and lot spawns.

Axes: Blender (x, y, z) -> Roblox (-x, z, y) after the importer's 180-degree turn (verified with a probe upload,
docs/v2/early/buildings/README.md). Building front = Blender -Y = Roblox -Z = the parcel CFrame's LookVector.
"""
import argparse, datetime, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, HERE)

import bk_arch as A  # noqa: E402
import bk_geo as G  # noqa: E402

A.PROD = True
G.NO_BEVEL = True
import build as BK  # noqa: E402
from variants import V  # noqa: E402

OUT = os.path.join(ROOT, "assets", "buildings")
LOT_ROLES = {"Site", "Asphalt", "Paint", "Lawn", "Water"}
PART_LIMIT = 20000
FH_TOWER = 13.0


def build_variant(v):
    kw = dict(v["kw"])
    target = kw.pop("target_h", None)
    kw.pop("planned", None)
    if v["family"] == "office":
        kw.setdefault("podium_h", 26.0)
    if target is None:
        return BK.build(v["arch"], v["seed"], name=v["key"], **kw)
    # towers: pick the floor count that lands closest to the target height (crown included)
    floors = max(6, int(round(target / FH_TOWER)))
    best = None
    for _ in range(4):
        B = BK.build(v["arch"], v["seed"], name=v["key"], floors=floors, **kw)
        if best is None or abs(B.height - target) < abs(best.height - target):
            best = B
        step = int(round((target - B.height) / FH_TOWER))
        if step == 0:
            break
        floors = max(6, floors + step)
    return best


def body_box(B):
    """Bounding box of the building itself (no lot paving / lawn / pool), Blender coords."""
    lo, hi = [1e9] * 3, [-1e9] * 3
    for role, buf in B.bufs.items():
        if role in LOT_ROLES or buf.empty():
            continue
        for p in buf.v:
            for k in range(3):
                lo[k] = min(lo[k], p[k])
                hi[k] = max(hi[k], p[k])
    return lo, hi


def to_roblox_box(lo, hi):
    # Roblox X = -Blender X, Roblox Y = Blender Z, Roblox Z = Blender Y
    return {"min": [round(-hi[0], 2), round(lo[2], 2), round(lo[1], 2)],
            "max": [round(-lo[0], 2), round(hi[2], 2), round(hi[1], 2)]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--family", nargs="*")
    ap.add_argument("--preview", help="directory for one Cycles preview per variant (slow; spot checks)")
    ap.add_argument("--samples", type=int, default=24)
    a = ap.parse_args()
    gdir = os.path.join(OUT, "glb")
    os.makedirs(gdir, exist_ok=True)
    cat_path = os.path.join(OUT, "catalog.json")
    full = not a.only and not a.family
    catalog = json.load(open(cat_path)) if (os.path.exists(cat_path) and not full) else {"variants": {}}
    sel = [v for v in V if (not a.only or v["key"] in a.only) and (not a.family or v["family"] in a.family)]
    if full:   # a full run owns the folder: drop exports of variants that left variants.py
        keep = {v["key"] for v in V}
        for fn in os.listdir(gdir):
            if os.path.splitext(fn)[0] not in keep:
                os.remove(os.path.join(gdir, fn))
    problems = []
    for v in sel:
        B = build_variant(v)
        path, meta = BK.export_glb(B, gdir, textures=False)
        lo, hi = body_box(B)
        parts = {}
        for pn, p in meta["parts"].items():
            if p["tris"] > PART_LIMIT:
                problems.append(f"{pn}: {p['tris']} tris")
            parts[pn] = {"role": p["role"], "tris": p["tris"], "night_only": p["night_only"], "material": p["material"]}
        W, D = B.footprint
        catalog["variants"][v["key"]] = {
            "key": v["key"], "arch": v["arch"], "family": v["family"], "seed": v["seed"],
            "kw": {k: val for k, val in v["kw"].items()},
            "footprint": [round(W, 2), round(D, 2)], "height": round(B.height, 2), "base_depth": round(B.base_depth, 2),
            "body": to_roblox_box(lo, hi), "tags": B.tags, "spawns": [list(s) for s in B.spawns],
            "total_tris": meta["total_tris"], "max_part_tris": meta["max_part_tris"], "n_parts": len(parts),
            "parts": parts, "glb": f"glb/{os.path.basename(path)}", "glb_bytes": meta["glb_bytes"],
        }
        print("%-22s %-8s parts=%2d tris=%6d max=%5d  lot %5.0f x %5.0f  h %5.1f  %4.0f KB" % (
            v["key"], v["family"], len(parts), meta["total_tris"], meta["max_part_tris"], W, D, B.height,
            meta["glb_bytes"] / 1024), flush=True)
        if a.preview:
            os.makedirs(a.preview, exist_ok=True)
            B2 = build_variant(v)
            BK.preview(B2, os.path.join(a.preview, v["key"] + ".png"), samples=a.samples)
    catalog["generated"] = datetime.datetime.now().isoformat(timespec="seconds")
    catalog["axes"] = "Roblox model space after import: front -Z, origin = lot bottom-centre at grade, +Y up"
    catalog["count"] = len(catalog["variants"])
    with open(cat_path, "w") as f:
        json.dump(catalog, f, indent=1, sort_keys=True)
    print("catalog:", cat_path, catalog["count"], "variants;", len(problems), "budget problems")
    for p in problems:
        print("  PROBLEM", p)


if __name__ == "__main__":
    main()
