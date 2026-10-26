#!/usr/bin/env python3
"""Regenerate the Hero / Props / Buildings tables in src/shared/Config/Assets.luau from the upload manifests
(assets/hero/manifest.json, assets/kit/*.json) plus curated Creator Store extras (STORE_EXTRAS below)."""
import json, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
def load(p):
    p = os.path.join(ROOT, p)
    return json.load(open(p)) if os.path.exists(p) else {}

hero = {}
for k, v in load("assets/hero/manifest.json").items():
    hero[k] = v
for k, v in load("assets/kit/cars.json").items():
    hero.setdefault(k, v)

buildings = load("assets/kit/buildings.json")
props = {}
props.update(load("assets/kit/nature-street.json"))
props.update(load("assets/kit/props.json"))

# Creator Store fills for roles the custom kit doesn't cover (source=store; needs "Allow Loading Third Party Assets").
STORE_EXTRAS = {
    "flower_bed": {"ids": [4542793421], "fit": "footprint", "size": 10},
    "neon_sign_open": {"ids": [491723807], "fit": "maxDim", "size": 7},
    "cash_stack": {"ids": [9507277429], "fit": "maxDim", "size": 2.5},
    "spray_can": {"ids": [5403252616], "fit": "height", "size": 4},
    "donut_giant": {"ids": [13742217239], "fit": "maxDim", "size": 8},
    "street_lamp_classic": {"ids": [14212653287], "fit": "height", "size": 14},
    "phone_booth": {"ids": [8932794862], "fit": "height", "size": 9},
    "parking_meter": {"ids": [8932663219], "fit": "height", "size": 5},
    "construction_barrier": {"ids": [10558582668], "fit": "length", "size": 8},
    "scrap_car": {"ids": [8027653806], "fit": "length", "size": 14},
    "police_helicopter": {"ids": [17797349765], "fit": "length", "size": 34},
    "garage_door_rollup": {"ids": [10163587378], "fit": "length", "size": 30},
}

def entry(v, source="owned"):
    fit = v.get("fit", "length")
    size = v.get("length", v.get("size"))
    yaw = v.get("yaw", 0)
    ids = v.get("ids") or [v["assetId"]]
    ids_s = ", ".join(str(i) for i in ids)
    return f'{{ ids = {{ {ids_s} }}, source = "{source}", fit = "{fit}", size = {float(size):g}, yaw = {float(yaw):g} }}'

def table(name, d, store=None):
    lines = [f'\t{k} = {entry(v)},' for k, v in sorted(d.items())]
    for k, v in sorted((store or {}).items()):
        if k not in d:
            lines.append(f'\t{k} = {entry(v, "store")},')
    return f"Assets.{name} = {{\n" + "\n".join(lines) + "\n} :: { [string]: AssetDef }"

p = os.path.join(ROOT, "src/shared/Config/Assets.luau")
s = open(p).read()
for name, d, store in (("Hero", hero, None), ("Props", props, STORE_EXTRAS), ("Buildings", buildings, None)):
    s = re.sub(rf"Assets\.{name} = \{{.*?\}} :: \{{ \[string\]: AssetDef \}}", table(name, d, store).replace("\\", "\\\\"), s, flags=re.S)
open(p, "w").write(s)
print(f"Hero={len(hero)} Props={len(props)}+{len([k for k in STORE_EXTRAS if k not in props])} store Buildings={len(buildings)}")
