#!/usr/bin/env python3
"""Mobile budget pass: decimate + downscale textures for every owned kit/hero GLB, re-upload, update manifests.
Originals are kept in <dir>/_hi/. Usage: python3 tools/optimize_kit.py [--dry]"""
import json, os, shutil, subprocess, sys
DRY = "--dry" in sys.argv
# (triangles, max texture px) per key; defaults by category below
BUDGET = {
    # frequently repeated street props / nature
    "palm_tree_a": (2500, 512), "palm_tree_b": (2500, 512), "round_tree": (2500, 512), "pine_tree": (2000, 512),
    "bush": (800, 256), "rock": (400, 256), "street_lamp": (1200, 256), "traffic_light": (1500, 256),
    "bench": (1000, 256), "fire_hydrant": (600, 256), "trash_can": (600, 256), "mailbox": (600, 256),
    "newspaper_box": (600, 256), "bus_stop": (2000, 512), "traffic_cone": (300, 128), "road_barrier": (600, 256),
    "billboard": (2500, 512), "hotdog_stand": (3000, 512), "beach_umbrella": (1200, 256), "beach_chair": (1000, 256),
    "lifeguard_tower": (3000, 512), "surfboard_rack": (2000, 512), "fountain": (6000, 1024),
    "ferris_wheel": (9000, 1024), "water_tower": (5000, 512),
    # garage / loot / docks
    "car_lift": (3000, 512), "tool_chest": (1500, 512), "tire_stack": (1500, 256), "oil_barrels": (1500, 256),
    "workbench": (2500, 512), "garage_shelf": (2500, 512), "money_pile": (2500, 512), "gold_bars": (800, 256),
    "safe_vault": (2000, 512), "trophy": (1500, 256), "money_bag": (1200, 256), "police_barricade": (800, 256),
    "shipping_container": (1500, 512), "crate_stack": (1200, 256), "dumpster": (1200, 256), "car_crusher": (5000, 512),
    # buildings
    "skyscraper_neon": (12000, 1024), "skyscraper_deco": (12000, 1024), "skyscraper_twist": (12000, 1024),
    "office_block": (8000, 1024), "apartment_balcony": (8000, 1024), "brick_loft": (8000, 1024), "hotel_beach": (8000, 1024),
    "lighthouse": (6000, 1024), "police_hq": (8000, 1024), "car_showroom": (8000, 1024), "warehouse": (6000, 1024),
}
CATEGORY_DEFAULT = {"buildings": (6000, 1024), "props": (2000, 512), "nature-street": (2000, 512)}
HERO_DEFAULT = (9000, 1024)  # hero (Meshy) cars: keep 9k tris, halve the 2048 textures

def tris_of(path):
    out = subprocess.run(["python3", "tools/glb_preview.py", path, "/tmp/claude-0/_opt_prev.png", "--size", "64"],
                         capture_output=True, text=True).stdout
    for tok in out.split():
        if tok.startswith("triangles="):
            return int(tok.split("=")[1])
    return 0

jobs = []
for cat in ("buildings", "props", "nature-street"):
    man = f"assets/kit/{cat}.json"
    for key, v in json.load(open(man)).items():
        tris, tex = BUDGET.get(key, CATEGORY_DEFAULT[cat])
        jobs.append((man, key, v, tris, tex))
for key, v in json.load(open("assets/hero/manifest.json")).items():
    jobs.append(("assets/hero/manifest.json", key, v, *HERO_DEFAULT))

for man, key, v, tris, tex in jobs:
    path = v["file"]
    hi = os.path.join(os.path.dirname(path), "_hi", os.path.basename(path))
    os.makedirs(os.path.dirname(hi), exist_ok=True)
    if not os.path.exists(hi):
        shutil.copy(path, hi)
    before = tris_of(hi)
    r = subprocess.run(["python3", "tools/decimate_glb.py", hi, path, str(min(tris, before) if before else tris), str(tex)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("DECIMATE FAIL", key, r.stderr[-300:]); shutil.copy(hi, path); continue
    after = tris_of(path)
    print(f"{key}: {before} -> {after} tris, tex<= {tex}", flush=True)
    if DRY:
        continue
    up = subprocess.run(["python3", "tools/upload_hero.py", key, path, v["name"], str(v["yaw"]), str(v["length"]),
                         "--manifest", man, "--fit", v.get("fit", "length"), "--role", v.get("role", key)],
                        capture_output=True, text=True)
    last = up.stdout.strip().splitlines()[-1] if up.stdout.strip() else up.stderr[-300:]
    print("   ", last[:140], flush=True)
