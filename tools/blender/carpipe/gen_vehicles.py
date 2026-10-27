#!/usr/bin/env python3
"""Write src/shared/Config/Vehicles.luau from the roster (roster.json), the carpipe sidecars
(assets/vehicles/<id>/<id>.json) and the upload manifest (assets/vehicles/manifest.json).

    python3 tools/blender/carpipe/gen_vehicles.py && stylua src/shared/Config/Vehicles.luau

Every value is in studs, in CarBuilder's BUILT POSE (ground y = 0, centred between the wheels, front facing -Z).
A car whose Model is not uploaded yet gets assetId = 0 (the game keeps the v1 procedural car for it).
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
VEH = os.path.join(ROOT, "assets", "vehicles")
OUT = os.path.join(ROOT, "src", "shared", "Config", "Vehicles.luau")

# target AssemblyMass per class (SPEC §8: ~900-3000)
MASS = {"compact": 1100, "hatch": 1150, "sedan": 1450, "taxi": 1500, "luxury": 1750, "limo": 2400, "muscle": 1600,
        "lowrider": 1700, "sports": 1350, "super": 1450, "hyper": 1400, "suv": 1900, "pickup": 2100, "van": 2200,
        "ambulance": 2700, "police": 1650, "police_suv": 2100, "armored": 3000, "box_truck": 2900, "bus": 3000,
        "fire": 3000}
WHEEL_ORDER = ["FL", "FR", "RL", "RR"]


def f(x):
    return f"{round(float(x), 3):g}"


def v3(p):
    return f"V({f(p[0])}, {f(p[1])}, {f(p[2])})"


def box(b):
    return f"{{ center = {v3(b['center'])}, size = {v3(b['size'])} }}"


def lstr(s):
    return json.dumps(s, ensure_ascii=False)


def main():
    ros = json.load(open(os.path.join(HERE, "roster.json")))
    man = json.load(open(os.path.join(VEH, "manifest.json"))) if os.path.exists(
        os.path.join(VEH, "manifest.json")) else {"models": {}, "images": {}}
    entries = []
    for vid, e in ros.items():
        if vid.startswith("_"):
            continue
        sp = os.path.join(VEH, vid, vid + ".json")
        if not os.path.exists(sp):
            continue
        s = json.load(open(sp))
        d = s["dimensions"]
        wheels = s["wheels"]
        keys = [k for k in WHEEL_ORDER if k in wheels] + sorted(k for k in wheels if k not in WHEEL_ORDER)
        rmax = max(w["radius"] for w in wheels.values())
        parts = []
        for nm, o in sorted(s["objects"].items()):
            mn, mx = o["bbox_min"], o["bbox_max"]
            c = [(mn[i] + mx[i]) / 2 for i in range(3)]
            sz = [abs(mx[i] - mn[i]) for i in range(3)]
            parts.append(f"\t\t\t{nm} = {{ center = {v3(c)}, size = {v3(sz)}, tris = {o['tris']} }},")
        wl = []
        for k in keys:
            w = wheels[k]
            wl.append(f"\t\t\t{{ key = \"{k}\", center = {v3(w['center'])}, partCenter = {v3(w['part_center'])}, "
                      f"radius = {f(w['radius'])}, width = {f(w['width'])}, steer = {'true' if w.get('steer') else 'false'} }},")
        model = man["models"].get(vid, {})
        img = man["images"].get(vid, {})
        asset = int(model.get("assetId") or 0) if model.get("moderation") != "Rejected" else 0
        image = int(img.get("assetId") or 0) if img.get("moderation") != "Rejected" else 0
        seat = s["seats"]["driver"]
        pas = s["seats"].get("passenger", seat)
        sirens = s.get("sirens") or {}
        src = s.get("source", {})
        credit = src.get("attribution") or src.get("title") or ""
        lines = [
            "\t{",
            f"\t\tid = \"{vid}\",",
            f"\t\tbrand = {lstr(e['brand'])},",
            f"\t\tmodel = {lstr(e['model'])},",
            f"\t\tclass = \"{e['class']}\",",
            f"\t\tassetId = {asset},",
            f"\t\tbodyImage = {image},",
            f"\t\tbodyMode = \"{e.get('body', 'paint')}\",",
            f"\t\tpaintRoute = \"{s['paint']['route']}\",",
            f"\t\tlength = {f(d['length'])},",
            f"\t\twidth = {f(d['width'])},",
            f"\t\theight = {f(d['height'])},",
            f"\t\twheelbase = {f(d.get('wheelbase') or 0)},",
            f"\t\twheelRadius = {f(rmax)},",
            f"\t\tbboxMin = {v3(d['bbox_min'])},",
            f"\t\tbboxMax = {v3(d['bbox_max'])},",
            "\t\twheels = {",
            *wl,
            "\t\t},",
            f"\t\tseat = {v3(seat['position'])},",
            f"\t\tpassenger = {v3(pas['position'])},",
            f"\t\tlightsFront = {{ {', '.join(v3(l['position']) for l in s['lights']['front'])} }},",
            f"\t\tlightsRear = {{ {', '.join(v3(l['position']) for l in s['lights']['rear'])} }},",
            "\t\tparts = {",
            *parts,
            "\t\t},",
        ]
        if "SirenRed" in sirens:
            lines.append(f"\t\tsirenRed = {box(sirens['SirenRed'])},")
        if "SirenBlue" in sirens:
            lines.append(f"\t\tsirenBlue = {box(sirens['SirenBlue'])},")
        if s.get("sign"):
            lines.append(f"\t\tsign = {box(s['sign'])},")
        lines += [
            f"\t\tpaints = {{ {', '.join(f'C({c[0]}, {c[1]}, {c[2]})' for c in e['paints'])} }},",
            f"\t\ttris = {s['triangles']['total']},",
            f"\t\tmass = {MASS.get(e['class'], 1500)},",
            f"\t\tcredit = {lstr(credit)},",
            "\t},",
        ]
        entries.append("\n".join(lines))
    head = '''--!strict
-- GENERATED by tools/blender/carpipe/gen_vehicles.py from tools/blender/carpipe/roster.json, the carpipe sidecars
-- (assets/vehicles/<id>/<id>.json) and the upload manifest (assets/vehicles/manifest.json). Do not edit by hand:
-- edit the roster / re-run carpipe, then `python3 tools/blender/carpipe/gen_vehicles.py && stylua <this file>`.
--
-- Vehicles v2 (PLAN wave A4): one entry per uploaded car Model (realistic CC-BY sources, real badges removed, our own
-- parody brands). Shared/Vehicle/CarBuilder mounts the Model on the arcade raycast chassis; Config/Cars entries point
-- here with `vehicle = <id>`. Coordinates: studs, CarBuilder's BUILT POSE (ground y = 0, centred between the wheel
-- contact patches, front facing -Z, driver on -X).
--   assetId     owned Model (InsertService), 0 = not uploaded (the v1 procedural car stands in)
--   bodyImage   Image set as Body.TextureID: the livery (bodyMode "livery") or the paint overlay (paintRoute
--               "tintmask": paint pixels transparent so Body.Color shows through); 0 = none (Body.Color only)
--   wheels      FL, FR, RL, RR first (extra axles after): axle centre, MeshPart bbox centre, radius, width
--   parts       every MeshPart of the Model: bbox centre / size in the built pose, triangles
--   seat        driver hip point (the VehicleSeat top sits just below it)
--   credit      CC-BY attribution (assets/ATTRIBUTION.md)

export type Box = { center: Vector3, size: Vector3 }
export type PartBox = { center: Vector3, size: Vector3, tris: number }
export type Wheel = {
	key: string,
	center: Vector3,
	partCenter: Vector3,
	radius: number,
	width: number,
	steer: boolean,
}
export type Spec = {
	id: string,
	brand: string,
	model: string,
	class: string,
	assetId: number,
	bodyImage: number,
	bodyMode: string,
	paintRoute: string,
	length: number,
	width: number,
	height: number,
	wheelbase: number,
	wheelRadius: number,
	bboxMin: Vector3,
	bboxMax: Vector3,
	wheels: { Wheel },
	seat: Vector3,
	passenger: Vector3,
	lightsFront: { Vector3 },
	lightsRear: { Vector3 },
	parts: { [string]: PartBox },
	sirenRed: Box?,
	sirenBlue: Box?,
	sign: Box?,
	paints: { Color3 },
	tris: number,
	mass: number,
	credit: string,
}

local V = Vector3.new
local C = Color3.fromRGB

local list: { Spec } = {
'''
    tail = '''}

local Vehicles = {}
Vehicles.List = list
Vehicles.ById = {} :: { [string]: Spec }
for _, spec in list do
	assert(Vehicles.ById[spec.id] == nil, "duplicate vehicle id " .. spec.id)
	Vehicles.ById[spec.id] = spec
end

function Vehicles.get(id: string?): Spec?
	if id == nil then
		return nil
	end
	return Vehicles.ById[id]
end

-- "Brand Model" display name of a vehicle id ("" when unknown).
function Vehicles.displayName(id: string?): string
	local spec = Vehicles.get(id)
	return if spec then spec.brand .. " " .. spec.model else ""
end

return Vehicles
'''
    with open(OUT, "w") as fh:
        fh.write(head + "\n".join(entries) + "\n" + tail)
    print("wrote", OUT, len(entries), "vehicles")
    write_attribution(ros, man)


ATTR = os.path.join(ROOT, "assets", "ATTRIBUTION.md")
MARK_A, MARK_B = "<!-- vehicles-v2:start -->", "<!-- vehicles-v2:end -->"


def write_attribution(ros, man):
    """The 'shipped in Vehicles v2' section of assets/ATTRIBUTION.md (in-game Credits source), between markers."""
    rows = []
    for vid, e in ros.items():
        if vid.startswith("_") or not man["models"].get(vid, {}).get("assetId"):
            continue
        meta_p = os.path.join(ROOT, "assets", "source", "sketchfab", e["source"], "meta.json")
        if not os.path.exists(meta_p):
            continue
        m = json.load(open(meta_p))
        au = m.get("author", {})
        lic = m.get("license", {})
        rows.append(f"| {e['brand']} {e['model']} (`{vid}`) | {m.get('name')} | [{au.get('displayName')}]"
                    f"({au.get('profileUrl')}) | [{lic.get('label')}]({lic.get('url')}) | [sketchfab]({m.get('modelUrl')})"
                    f" | {man['models'][vid]['assetId']} |")
    block = "\n".join([
        MARK_A,
        "## Shipped: Vehicles v2 (wave A4)",
        "",
        "Each in-game car below is built from the listed CC-BY model (converted by tools/blender/carpipe: real "
        "badges and emblems removed, renamed to our own parody brand). Generated by "
        "tools/blender/carpipe/gen_vehicles.py; these credits must appear in the in-game Credits screen.",
        "",
        "| In-game car | Source model | Author | License | Source | Roblox Model id |",
        "|---|---|---|---|---|---|",
        *rows,
        MARK_B,
    ])
    text = open(ATTR).read()
    if MARK_A in text and MARK_B in text:
        a = text.index(MARK_A)
        b = text.index(MARK_B) + len(MARK_B)
        text = text[:a] + block + text[b:]
    else:
        text = text.rstrip("\n") + "\n\n" + block + "\n"
    open(ATTR, "w").write(text)
    print("wrote", ATTR, len(rows), "shipped vehicles")


if __name__ == "__main__":
    main()
