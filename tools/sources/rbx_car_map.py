#!/usr/bin/env python3
"""Classify the parts of an inspected Roblox car model into runtime groups and emit a mapping spec.

    python3 -I tools/sources/rbx_car_map.py <modelId> [...] [--md]

Reads assets/source/roblox/<id>/tree.json (+ deps.json, mesh.json caches) and writes
docs/v2/sourcing/roblox_car_maps/<id>.json:

  forward / dims / suggested scale, strip list (scripts, GUIs, physics junk, flagged backdoors),
  hubs (4 wheel centres + radius in the car frame), and groups:
    Wheel_FL/FR/RL/RR (spinning), WheelStatic_* (calipers etc.), Glass, Lights_{Head,Tail,Brake,
    Reverse,Indicator_L,Indicator_R,Emergency,Other}, Paint (+ colour), Interior, Body, Hidden.
  Each group lists explicit instance paths (duplicate sibling names get a "#k" suffix, k = 1-based
  index among same-named siblings in file order) and the rule that matched.

Rules (first match wins, applied to visible BaseParts; Decals follow their parent part):
  1 Wheel_*      descendant of a wheel container (Wheels/FL.., or a part named like a wheel),
                 quadrant by position in the car frame; Fixed/WheelFixed/Caliper/Brake -> WheelStatic_*
  2 Lights_*     name ~ light|lamp|led|drl|indicator|signal|blinker|brake|reverse|fog|tail|head..,
                 or Material=Neon, or has a Light child; subtype by name, then colour/position
  3 Glass        Material=Glass, or name ~ glass|window|windscreen|windshield, or 0.15<=T<=0.85
  4 Interior     name ~ interior|seat|dash|steer|gauge|needle|speedo|tach|console|pedal|mirror_in
  5 Paint        untextured parts whose Color matches the paint colour (named paint/body parts first,
                 else the area-dominant chromatic colour)
  6 Body         everything else visible
"""
import json
import math
import os
import re
import sys
from collections import Counter, defaultdict

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rbxdl  # noqa: E402

OUT_DIR = os.path.join(rbxdl.ROOT, "docs", "v2", "sourcing", "roblox_car_maps")
PART_CLASSES = {"Part", "MeshPart", "WedgePart", "CornerWedgePart", "TrussPart", "Seat", "VehicleSeat",
                "SpawnLocation", "UnionOperation", "IntersectOperation"}
STRIP_CLASSES = {"Script", "LocalScript", "ModuleScript", "ScreenGui", "BillboardGui", "SurfaceGui", "Humanoid",
                 "BodyThrust", "BodyVelocity", "BodyGyro", "BodyPosition", "BodyForce", "BodyAngularVelocity",
                 "RemoteEvent", "RemoteFunction", "BindableEvent", "Sound", "ParticleEmitter", "Smoke", "Fire",
                 "BloomEffect", "BlurEffect", "ColorCorrectionEffect", "SunRaysEffect", "Camera", "Animation",
                 "ClickDetector", "ProximityPrompt", "Explosion", "Sparkles", "Trail", "Beam"}
JOINT_CLASSES = {"Weld", "ManualWeld", "WeldConstraint", "Motor6D", "Motor", "Snap", "HingeConstraint",
                 "CylindricalConstraint", "PrismaticConstraint", "SpringConstraint", "BallSocketConstraint",
                 "RopeConstraint", "RodConstraint", "NoCollisionConstraint", "AlignOrientation", "AlignPosition",
                 "VectorForce", "LinearVelocity", "AngularVelocity", "Torque", "Attachment"}
BACKDOOR_FLAGS = ("require-by-attribute", "require-tonumber", "self-hide", "coregui-toggle", "studio-evasion",
                  "backdoor-family", "odd-parent", "getfenv", "loadstring", "setfenv")

RE_WHEELCONT = re.compile(r"^(fl|fr|rl|rr|lf|rf|lr|wheel ?fl|wheel ?fr|wheel ?rl|wheel ?rr|wheel_?(fl|fr|rl|rr)|"
                          r"front ?left|front ?right|rear ?left|rear ?right|back ?left|back ?right)$", re.I)
RE_WHEELNAME = re.compile(r"wheel|tire|tyre|rim\b|rims|hubcap|\bhub\b|rotor|spoke|lugnut|lug nut|disk|disc|pneu|jante|roue", re.I)
RE_STEER = re.compile(r"steer|misc", re.I)
RE_WHEEL_STATIC = re.compile(r"^(fixed|wheelfixed|caliper|calipers|brake ?caliper|knuckle|strut|plaquette|etrier|"
                             r"brake ?pad|pads?)$", re.I)
RE_LIGHT = re.compile(r"light|lamp|\bled|drl|indicator|signal|blinker|turn|brake|reverse|reversing|fog|beam|"
                      r"hazard|tail|^head|lightbar|siren|strobe|\bels\b|flasher|marker|phare|^feux?\b|clignot|gyro", re.I)
RE_NOT_LIGHT = re.compile(r"headrest|headliner|lightweight|highlight", re.I)
RE_EMERG = re.compile(r"lightbar|siren|strobe|\bels\b|flasher|emergency|wail|lightbar|pushbar ?led|police ?light|"
                      r"\bblue\b|\bred\b ?led|gyro|deux ?tons", re.I)
RE_GLASS = re.compile(r"glass|window|windscreen|windshield|wind ?shield|wndw|sunroof|moonroof|vitre|vidrio|cristal", re.I)
RE_INTERIOR = re.compile(r"interior|seat|dash|steer|gauge|needle|speedo|tach|console|pedal|shifter|gear ?stick|"
                         r"headrest|carpet|^int[_ ]|cabin|si[eè]ge|volant|int[eé]rieur", re.I)
RE_PAINT = re.compile(r"paint|bodyshell|body ?colou?r|carpaint|^colou?r$|^shell|^body ?panel|carrosserie|carroceria|"
                      r"karosserie|^lack$", re.I)
RE_BRAND = re.compile(r"logo|badge|emblem|ford|toyota|nissan|kia|jaguar|mercedes|benz|amg|peugeot|chevrolet|"
                      r"chevy|gmc|chrysler|prius|patrol|murano|sorento|tundra|isuzu|lexus|bmw|audi|honda|"
                      r"plate|license|licence", re.I)

REAL_LENGTH_M = {  # approximate real-world overall length of the car each listing depicts
    89890547548224: (5.89, "2009-14 Ford F-150 SuperCrew 5.5 ft bed"),
    11881862706: (4.79, "Jaguar XKR-S GT"),
    14746413121: (5.05, "Nissan Patrol Y61 5-door"),
    117276253886376: (4.69, "Kia Sorento XM 2011"),
    73893179863762: (4.77, "Nissan Murano Z50 2005"),
    126180570128588: (5.93, "2022 Toyota Tundra CrewMax (badged \"VELLFIRE\")"),
    113053967699143: (5.04, "Ford Explorer Police Interceptor-style SUV"),
    103123587729335: (4.25, "Peugeot 308-style hatchback"),
    131180706902259: (7.0, "Isuzu NPR-style 16 ft box truck"),
    97965573521866: (4.94, "Mercedes-AMG GLE 53 4MATIC+ coupe SUV"),
    132078381973405: (4.46, "Toyota Prius XW30 2010"),
    951086064: (4.84, "Nissan Maxima A35 2009"),
    3204824887: (4.57, "Chrysler ME Four-Twelve"),
    16390639371: (5.10, "Ford Taurus PI-style sedan"),
    10141791793: (6.35, "GMC Sierra 2500 HD AT4 crew cab"),
    71284840505836: (4.90, "1980s panel van"),
    94301391128632: (5.38, "Ford Crown Victoria taxi"),
}
STUD_M = 0.28


def cf_rot(cf):
    return np.array(cf[3:12], float).reshape(3, 3)


def luminance(c):
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def saturation(c):
    mx, mn = max(c), min(c)
    return 0.0 if mx < 1e-6 else (mx - mn) / mx


def _vis_aabb(nodes):
    lo, hi = np.full(3, np.inf), np.full(3, -np.inf)
    for n in nodes:
        p = n["props"]
        if n["class"] not in PART_CLASSES or "CFrame" not in p or "Size" not in p:
            continue
        if float(p.get("Transparency", 0) or 0) >= 0.98:
            continue
        R = cf_rot(p["CFrame"])
        half = np.abs(R) @ (np.array(p["Size"], float) / 2)
        c = np.array(p["CFrame"][:3], float)
        lo, hi = np.minimum(lo, c - half), np.maximum(hi, c + half)
    return lo, hi


def find_forward(nodes):
    """-> (unit forward vector in Roblox world (y = 0), method). Seat look vectors are only trusted
    when they run along the long horizontal axis of the visible geometry."""
    lo, hi = _vis_aabb(nodes)
    ext = hi - lo if np.isfinite(lo).all() else np.array([1.0, 1.0, 1.0])
    long_axis = np.array([1.0, 0, 0]) if ext[0] > ext[2] else np.array([0, 0, 1.0])
    elong = max(ext[0], ext[2]) / max(min(ext[0], ext[2]), 1e-6)
    seats = [n for n in nodes if n["class"] in ("VehicleSeat", "Seat") and n["props"].get("CFrame")]
    seats.sort(key=lambda s: (s["class"] != "VehicleSeat", "drive" not in s["name"].lower()))
    for s in seats:
        cf = s["props"]["CFrame"]
        look = -np.array([cf[5], cf[8], cf[11]], float)
        look[1] = 0
        if np.linalg.norm(look) < 0.5:
            continue
        look /= np.linalg.norm(look)
        if elong < 1.3 or abs(look @ long_axis) > 0.85:
            return look, f"seat:{s['name']}"
    heads, tails = [], []
    for n in nodes:
        nm = n["name"].lower()
        p = n["props"]
        cf = p.get("CFrame")
        if not cf or n["class"] not in PART_CLASSES:
            continue
        col = p.get("Color", [0, 0, 0])
        if "headlight" in nm or nm.startswith("head") or "front" in nm:
            heads.append(cf[:3])
        elif "tail" in nm or "brake" in nm or "rear" in nm or "reverse" in nm or (
                (p.get("Material") == "Neon" or "light" in nm) and col[0] > 0.5 and col[1] < 0.25 and col[2] < 0.25):
            tails.append(cf[:3])
    ctr = (lo + hi) / 2 if np.isfinite(lo).all() else np.zeros(3)
    if heads or tails:
        h = np.mean(heads, 0) if heads else ctr
        t = np.mean(tails, 0) if tails else ctr
        v = (h - t) * np.array([1, 0, 1.0])
        if np.linalg.norm(v) > 0.5:
            v = v / np.linalg.norm(v)
            if elong >= 1.3:  # snap to the long axis
                v = long_axis * np.sign(v @ long_axis or 1)
            return v, "light-names" + ("+long-axis" if elong >= 1.3 else "")
    cam = next((n for n in nodes if n["class"] == "Camera" and n["props"].get("CFrame")), None)
    if cam is not None and elong >= 1.3:
        v = np.array(cam["props"]["CFrame"][:3], float) - ctr
        if abs(v @ long_axis) > 1e-3:  # thumbnails are framed from the front 3/4 by convention
            return long_axis * np.sign(v @ long_axis), "thumbnail-camera+long-axis"
    return -long_axis, "long-axis(-)"


def analyze(model_id):
    d = rbxdl.asset_dir(model_id)
    tree = json.load(open(os.path.join(d, "tree.json")))
    deps = json.load(open(os.path.join(d, "deps.json"))) if os.path.exists(os.path.join(d, "deps.json")) else {}
    nodes = tree["nodes"]
    byid = {n["id"]: n for n in nodes}
    kids = defaultdict(list)
    for n in nodes:
        kids[n["parent"]].append(n["id"])

    # unique instance paths ("#k" for duplicate sibling names)
    upath = {}
    for n in nodes:
        par = n["parent"]
        sib = [byid[c] for c in kids[par]]
        same = [s for s in sib if s["name"] == n["name"]]
        seg = n["name"] if len(same) == 1 else f"{n['name']}#{same.index(n) + 1}"
        upath[n["id"]] = seg if par == 0 else upath[par] + "/" + seg

    def ancestors(n):
        out = []
        p = n["parent"]
        while p:
            out.append(byid[p])
            p = byid[p]["parent"]
        return out

    def is_part(n):
        return n["class"] in PART_CLASSES and "CFrame" in n["props"] and "Size" in n["props"]

    def visible(n):
        return float(n["props"].get("Transparency", 0) or 0) < 0.98

    parts = [n for n in nodes if is_part(n)]
    vis = [n for n in parts if visible(n)]
    fwd, fmethod = find_forward(nodes)
    up = np.array([0, 1.0, 0])
    right = np.cross(fwd, up)

    def aabb(n):
        cf = n["props"]["CFrame"]
        R = cf_rot(cf)
        half = np.abs(R) @ (np.array(n["props"]["Size"], float) / 2)
        c = np.array(cf[:3], float)
        return c - half, c + half

    boxes = {n["id"]: aabb(n) for n in vis}
    if boxes:
        allmin = np.min([b[0] for b in boxes.values()], 0)
        allmax = np.max([b[1] for b in boxes.values()], 0)
    else:
        allmin = allmax = np.zeros(3)
    ctr = (allmin + allmax) / 2

    def local(p):
        v = np.asarray(p, float) - ctr
        return np.array([v @ right, v @ up, v @ fwd])  # (x right, y up, z forward)

    # extents in car frame
    corners = []
    re_appendage = re.compile(r"antenn|aerial|whip|flag", re.I)
    for nid, (lo, hi) in boxes.items():
        if any(re_appendage.search(a["name"]) for a in [byid[nid]] + ancestors(byid[nid])[:3]):
            continue  # whip antennas etc. would distort the length used for scaling
        for i in range(8):
            corners.append(local([(lo, hi)[i >> k & 1][k] for k in range(3)]))
    corners = np.array(corners) if corners else np.zeros((1, 3))
    lmin, lmax = corners.min(0), corners.max(0)
    dims = {"length": round(float(lmax[2] - lmin[2]), 2), "width": round(float(lmax[0] - lmin[0]), 2),
            "height": round(float(lmax[1] - lmin[1]), 2)}
    ground_y = lmin[1]

    def quadrant(p):
        q = local(p)
        return ("F" if q[2] > 0 else "R") + ("R" if q[0] > 0 else "L")

    group = {}
    rule = {}

    # --- 1. wheels ---------------------------------------------------------------------------
    wheel_containers = []
    for n in nodes:
        anc_names = [a["name"].lower() for a in ancestors(n)]
        if RE_WHEELCONT.match(n["name"].strip()) and ("wheels" in anc_names[:2] or (is_part(n) and n["props"].get("Shape") in ("Ball", "Cylinder"))):
            if any(RE_STEER.search(a) for a in anc_names[:1]):
                continue
            wheel_containers.append(n)
    wheel_method = None
    if wheel_containers:
        wheel_method = "containers:" + ",".join(sorted({upath[w["id"]] for w in wheel_containers})[:4])
        cont_ids = {w["id"]: w for w in wheel_containers}
        for n in vis:
            chain = [n] + ancestors(n)
            hit = next((a for a in chain if a["id"] in cont_ids), None)
            if hit is None:
                continue
            static = any(RE_WHEEL_STATIC.match(a["name"].strip()) or re.search(r"caliper", a["name"], re.I)
                         for a in chain[:chain.index(hit)])
            # quadrant from the container's own position when it is a part, else from the part
            src = hit if is_part(hit) else n
            q = quadrant(src["props"]["CFrame"][:3])
            g = ("WheelStatic_" if static else "Wheel_") + q
            group[n["id"]] = g
            rule[n["id"]] = f"under wheel container {upath[hit['id']]}" + (" (static)" if static else "")
    # name-based wheel parts not under containers
    for n in vis:
        if n["id"] in group:
            continue
        chain = [n] + ancestors(n)
        names = [a["name"] for a in chain[:3]]
        if any(RE_STEER.search(x) for x in names) or any(RE_INTERIOR.search(x) for x in names[:1]):
            continue
        if any(RE_WHEELNAME.search(x) for x in names):
            lo, hi = boxes[n["id"]]
            c = (lo + hi) / 2
            if local(c)[1] - ground_y > dims["height"] * 0.55:
                continue  # spare wheel on a roof / tailgate etc.
            static = bool(re.search(r"caliper|brake", " ".join(names), re.I))
            q = quadrant(c)
            group[n["id"]] = ("WheelStatic_" if static else "Wheel_") + q
            rule[n["id"]] = "wheel-ish name: " + next(x for x in names if RE_WHEELNAME.search(x))
            wheel_method = wheel_method or "names"
    # geometric fallback: round parts (Ball / Cylinder / two equal dims) low down near the 4 corners
    if not any(g.startswith("Wheel_") for g in group.values()):
        cands = []
        for n in vis:
            p = n["props"]
            sz = np.array(p["Size"], float)
            sm = next((byid[c] for c in kids[n["id"]] if byid[c]["class"] in ("SpecialMesh", "CylinderMesh")), None)
            shape = p.get("Shape")
            if sm is not None and sm["class"] == "SpecialMesh":
                shape = {"Cylinder": "Cylinder", "Sphere": "Ball"}.get(sm["props"].get("MeshType"), shape)
            srt = np.sort(sz)
            roundish = shape in ("Ball", "Cylinder") or (srt[2] > 1.2 and abs(srt[2] - srt[1]) / srt[2] < 0.12 and srt[0] < srt[2] * 0.75)
            if not roundish:
                continue
            lo, hi = boxes[n["id"]]
            q = local((lo + hi) / 2)
            if q[1] - ground_y > dims["height"] * 0.45 or abs(q[0]) < dims["width"] * 0.2 or abs(q[2]) < dims["length"] * 0.15:
                continue
            cands.append((float(srt[2]), n, q))
        best = {}
        for d_, n, q in cands:
            k = ("F" if q[2] > 0 else "R") + ("R" if q[0] > 0 else "L")
            if k not in best or d_ > best[k][0]:
                best[k] = (d_, n, q)
        if len(best) >= 3:
            wheel_method = "geometry(round parts at corners)"
            for k, (d_, hub_n, hq) in best.items():
                for n in vis:
                    if n["id"] in group:
                        continue
                    lo, hi = boxes[n["id"]]
                    q = local((lo + hi) / 2)
                    if np.linalg.norm((q - hq)[[1, 2]]) < d_ * 0.5 and abs(q[0] - hq[0]) < d_ * 0.6 and \
                            np.max(np.array(n["props"]["Size"], float)) <= d_ * 1.05:
                        group[n["id"]] = "Wheel_" + k
                        rule[n["id"]] = f"within {d_ / 2:.2f} studs of round hub part {upath[hub_n['id']]}"
    # hubs: per quadrant, use the largest wheel part (tyre)
    hubs = {}
    for q in ("FL", "FR", "RL", "RR"):
        ids = [i for i, g in group.items() if g == "Wheel_" + q]
        if not ids:
            continue
        big = max(ids, key=lambda i: np.prod(np.array(byid[i]["props"]["Size"], float)))
        lo, hi = boxes[big]
        c = (lo + hi) / 2
        sz = sorted(np.array(byid[big]["props"]["Size"], float))
        hubs[q] = {"center": [round(float(x), 3) for x in local(c)], "radius": round(float(sz[-1] / 2), 3),
                   "width": round(float(sz[0]), 3), "parts": len(ids)}

    # spare-wheel style geometric fallback: none; report if wheels missing
    # --- 2..5 ----------------------------------------------------------------------------------
    light_child = {n["parent"] for n in nodes if n["class"] in ("SpotLight", "PointLight", "SurfaceLight")}
    for n in vis:
        if n["id"] in group:
            continue
        p = n["props"]
        nm = n["name"]
        chain_names = [nm] + [a["name"] for a in ancestors(n)[:2]]
        joined = " ".join(chain_names)
        mat = p.get("Material", "Plastic")
        tr = float(p.get("Transparency", 0) or 0)
        col = p.get("Color", [0.64, 0.64, 0.65])
        lightish = (any(RE_LIGHT.search(x) and not RE_NOT_LIGHT.search(x) for x in chain_names)
                    or mat == "Neon" or n["id"] in light_child)
        if lightish and not RE_GLASS.search(nm) or (lightish and mat == "Neon"):
            q = local(p["CFrame"][:3])
            if RE_EMERG.search(joined):
                sub = "Emergency"
            elif re.search(r"indicator|signal|blinker|turn|hazard|arrow|clignot", joined, re.I):
                sub = "Indicator_" + ("R" if q[0] > 0 else "L")
            elif re.search(r"reverse|reversing|backup", joined, re.I):
                sub = "Reverse"
            elif re.search(r"brake|stop", joined, re.I):
                sub = "Brake"
            elif re.search(r"tail|rear|arri[eè]re", joined, re.I):
                sub = "Tail"
            elif re.search(r"head|front|drl|fog|beam|\bhi\b|\blo\b|high|low|avant", joined, re.I):
                sub = "Head"
            elif col[0] > 0.6 and col[1] > 0.35 and col[2] < 0.25:
                sub = "Indicator_" + ("R" if q[0] > 0 else "L")
            else:
                sub = "Head" if q[2] > 0 else "Tail"
            group[n["id"]] = "Lights_" + sub
            rule[n["id"]] = "light: " + ("Neon" if mat == "Neon" else "name/light child")
            continue
        trim = re.search(r"contour|trim|frame|seal|surround|rubber|joint", nm, re.I)
        if not trim and (mat == "Glass" or RE_GLASS.search(" ".join(chain_names[:2])) or (0.15 <= tr <= 0.85 and luminance(col) < 0.5)):
            group[n["id"]] = "Glass"
            rule[n["id"]] = "glass: " + ("Material=Glass" if mat == "Glass" else ("name" if RE_GLASS.search(" ".join(chain_names[:2])) else f"T={tr}"))
            continue
        if any(re.search(r"plate|licen[cs]e|plaque|matr[ií]cula|kennzeichen", x, re.I) for x in chain_names[:3]):
            group[n["id"]] = "Plate"
            rule[n["id"]] = "licence plate name"
            continue
        if any(RE_INTERIOR.search(x) for x in chain_names[:2]):
            group[n["id"]] = "Interior"
            rule[n["id"]] = "interior name"
            continue

    # colour/position lights: saturated red parts in the rear quarter are tail lamps; parts that share
    # a TextureID with an already-classified lamp are lamps too (photo-textured light atlases)
    for n in vis:
        if n["id"] in group:
            continue
        c = n["props"].get("Color", [0, 0, 0])
        q = local(n["props"]["CFrame"][:3])
        if c[0] > 0.45 and c[1] < 0.2 and c[2] < 0.2 and q[2] < -0.3 * dims["length"]:
            group[n["id"]] = "Lights_Tail"
            rule[n["id"]] = "red part in rear quarter"
    tex_users = Counter(rbxdl.parse_asset_id(n["props"].get("TextureID")) for n in vis)
    tex_lamps = Counter(rbxdl.parse_asset_id(byid[i]["props"].get("TextureID")) for i, g in group.items()
                        if g.startswith("Lights_"))
    # only dedicated lamp textures (few users, a good share already lamps), never shared body atlases
    lamp_tex = {t for t, k in tex_lamps.items() if t and tex_users[t] <= 6 and k / tex_users[t] >= 0.3}
    for n in vis:
        if n["id"] in group:
            continue
        t = rbxdl.parse_asset_id(n["props"].get("TextureID"))
        if t and t in lamp_tex:
            q = local(n["props"]["CFrame"][:3])
            group[n["id"]] = "Lights_Head" if q[2] > 0 else "Lights_Tail"
            rule[n["id"]] = f"shares lamp texture {t}"

    # --- paint -----------------------------------------------------------------------------------
    def has_tex(n):
        if rbxdl.parse_asset_id(n["props"].get("TextureID")):
            return True
        for c in kids[n["id"]]:
            k = byid[c]
            if k["class"] == "SurfaceAppearance":
                return True
            if k["class"] == "SpecialMesh" and rbxdl.parse_asset_id(k["props"].get("TextureId")):
                return True
        return False

    def area(n):
        s = np.array(n["props"]["Size"], float)
        return float(s[0] * s[1] + s[1] * s[2] + s[0] * s[2]) * 2

    rest = [n for n in vis if n["id"] not in group]
    named = [n for n in rest if any(RE_PAINT.search(x["name"]) for x in [n] + ancestors(n)[:2])]
    paint_color = None
    paint_method = None

    def ckey(c):
        return tuple(round(float(x) * 255) for x in c)

    named_plain = [n for n in named if not has_tex(n)]
    paint_baked = []
    if named_plain:
        cnt = Counter()
        for n in named_plain:
            cnt[ckey(n["props"].get("Color", [0, 0, 0]))] += area(n)
        paint_color = cnt.most_common(1)[0][0]
        paint_method = "named paint/body parts"
    elif named:
        # the body panel exists but its colour/livery is baked into a texture or SurfaceAppearance
        paint_baked = named
        paint_method = "named body part is textured (livery baked; Color does not repaint it)"
    else:
        cnt = Counter()
        for n in rest:
            if has_tex(n):
                continue
            c = n["props"].get("Color", [0, 0, 0])
            w = area(n)
            if saturation(c) > 0.2 or luminance(c) > 0.75:
                w *= 3  # prefer chromatic / white body colours over trim greys & blacks
            if abs(c[0] - 0.639) < 0.01 and abs(c[1] - 0.635) < 0.01:
                w *= 0.3  # Roblox default "Medium stone grey" = untouched detail parts
            cnt[ckey(c)] += w
        if cnt:
            paint_color = cnt.most_common(1)[0][0]
            paint_method = "area-dominant colour"
    for n in paint_baked:
        group[n["id"]] = "PaintBaked"
        rule[n["id"]] = "named body part with texture/SurfaceAppearance"
    paint_textured = 0
    if paint_color is not None:
        for n in rest:
            c = ckey(n["props"].get("Color", [0, 0, 0]))
            if max(abs(a - b) for a, b in zip(c, paint_color)) <= 4:
                if has_tex(n):
                    paint_textured += 1
                    continue
                group[n["id"]] = "Paint"
                rule[n["id"]] = f"Color == rgb{paint_color}"
    for n in vis:
        if n["id"] not in group:
            group[n["id"]] = "Body"
            rule[n["id"]] = "default"

    # decals follow parent part
    decals = [n for n in nodes if n["class"] in ("Decal", "Texture")]
    decal_info = []
    for dcl in decals:
        par = byid.get(dcl["parent"])
        img = rbxdl.parse_asset_id(dcl["props"].get("Texture"))
        decal_info.append({"path": upath[dcl["id"]], "face": dcl["props"].get("Face"), "image": img,
                           "parentGroup": group.get(par["id"]) if par else None,
                           "transparency": dcl["props"].get("Transparency", 0)})

    # --- strip list & security ---------------------------------------------------------------
    strip = Counter()
    flagged = []
    for n in nodes:
        if n["class"] in STRIP_CLASSES or n["class"].endswith("Value") or n["class"] in ("Frame", "TextLabel", "TextButton", "ImageLabel", "ImageButton", "ScrollingFrame", "Folder") and any(a["class"] in ("ScreenGui", "BillboardGui", "SurfaceGui") for a in ancestors(n)):
            strip[n["class"]] += 1
        elif n["class"] in JOINT_CLASSES:
            strip[n["class"]] += 1
        s = n["props"].get("Scan")
        if s:
            fl = s["flags"] if isinstance(s["flags"], list) else []
            req = s["requireIds"] if isinstance(s["requireIds"], list) else []
            bad = [f for f in fl if f.split(":")[0].split("(")[0] in BACKDOOR_FLAGS]
            if bad or req:
                payload = set()
                stack = list(kids[n["id"]])
                while stack:  # ids hidden in attributes / values anywhere under the script
                    k = byid[stack.pop()]
                    stack += kids[k["id"]]
                    at = k["props"].get("Attributes") or {}
                    vals = list(at.values()) if isinstance(at, dict) else []
                    if k["class"].endswith("Value"):
                        vals.append(k["props"].get("Value"))
                    for v in vals:
                        if isinstance(v, (int, float)) and v > 1e6:
                            payload.add(int(v))
                        elif isinstance(v, str) and re.fullmatch(r"\d{8,17}", v.strip()):
                            payload.add(int(v))
                lits = s.get("numericLiterals") if isinstance(s.get("numericLiterals"), list) else []
                payload |= {int(x) for x in lits if len(x) >= 10}
                flagged.append({"path": upath[n["id"]], "class": n["class"], "flags": bad, "requireIds": req,
                                "payloadIds": sorted(payload)})
    hidden = [n for n in parts if not visible(n)]

    # --- stats -----------------------------------------------------------------------------------
    tris = 0
    mesh_ids = set()
    for n in vis:
        mid = rbxdl.parse_asset_id(n["props"].get("MeshId"))
        for c in kids[n["id"]]:
            k = byid[c]
            if k["class"] == "SpecialMesh" and k["props"].get("MeshType", "FileMesh") == "FileMesh":
                mid = mid or rbxdl.parse_asset_id(k["props"].get("MeshId"))
        if mid:
            mesh_ids.add(mid)
            mj = os.path.join(rbxdl.asset_dir(mid), "mesh.json")
            if os.path.exists(mj):
                tris += json.load(open(mj))["tris"]
        else:
            tris += 12
    images = deps.get("image", {})
    tex_ok = [v for v in images.values() if v.get("ok")]
    real = REAL_LENGTH_M.get(int(model_id))
    sug_scale = None
    if real and dims["length"] > 0:
        sug_scale = round(real[0] / STUD_M / dims["length"], 3)

    groups_out = defaultdict(lambda: {"paths": [], "rules": Counter()})
    for i, g in group.items():
        groups_out[g]["paths"].append(upath[i])
        groups_out[g]["rules"][rule[i]] += 1
    groups_json = {g: {"count": len(v["paths"]), "rules": dict(v["rules"].most_common(6)), "paths": sorted(v["paths"])}
                   for g, v in sorted(groups_out.items())}
    # compact selectors: a subtree whose visible parts all share one group becomes "path/**"
    root_id = nodes[0]["id"] if nodes else 0
    vis_ids = {n["id"] for n in vis}
    sub_groups = {}

    def collect(i):
        gs = Counter()
        if i in vis_ids:
            gs[group[i]] += 1
        for c in kids[i]:
            gs.update(collect(c))
        sub_groups[i] = gs
        return gs
    collect(root_id)

    def rel(i):
        p_ = upath[i]
        return p_.split("/", 1)[1] if "/" in p_ else "."

    selectors = defaultdict(list)

    def emit(i):
        gs = sub_groups[i]
        if not gs:
            return
        if len(gs) == 1 and (kids[i] or i == root_id):
            g = next(iter(gs))
            selectors[g].append(rel(i) + "/**" if i != root_id else "**")
            return
        leaf_by_group = defaultdict(list)
        if i in vis_ids:
            leaf_by_group[group[i]].append(rel(i))
        for c in kids[i]:
            part_leaf = c in vis_ids and sum(sub_groups[c].values()) == 1
            if kids[c] and sub_groups[c] and not part_leaf:
                emit(c)
            elif c in vis_ids:
                leaf_by_group[group[c]].append(byid[c]["name"] + ("#%s" % upath[c].rsplit("#", 1)[1] if "#" in upath[c].rsplit("/", 1)[-1] else ""))
        for g, names in leaf_by_group.items():
            base = rel(i)
            names = sorted(set(names))
            if len(names) > 6:
                selectors[g].append(f"{base}/{{{', '.join(names[:6])}, +{len(names) - 6} more}}")
            else:
                selectors[g].append(f"{base}/{{{', '.join(names)}}}" if len(names) > 1 else f"{base}/{names[0]}")
    emit(root_id)
    for g in groups_json:
        groups_json[g]["selectors"] = selectors.get(g, [])

    out = {
        "assetId": int(model_id),
        "name": nodes[0]["name"] if nodes else "",
        "depicts": real[1] if real else None,
        "forward": {"method": fmethod, "lookVector": [round(float(x), 4) for x in fwd]},
        "frame": "car-local: x = right, y = up, z = forward, origin = visible-geometry bbox centre",
        "dims_studs": dims,
        "real_length_m": real[0] if real else None,
        "suggested_uniform_scale": sug_scale,
        "counts": {"instances": len(nodes), "baseParts": len(parts), "visibleParts": len(vis),
                   "meshParts": sum(1 for n in vis if n["class"] == "MeshPart"),
                   "uniqueMeshes": len(mesh_ids), "approxTris": int(tris), "hiddenParts": len(hidden),
                   "decals": len(decals), "images": len(images), "imagesOk": len(tex_ok),
                   "surfaceAppearances": sum(1 for n in nodes if n["class"] == "SurfaceAppearance"),
                   "unions": sum(1 for n in vis if n["class"] in ("UnionOperation", "IntersectOperation")),
                   "scripts": sum(1 for n in nodes if n["class"] in ("Script", "LocalScript", "ModuleScript"))},
        "wheelMethod": wheel_method,
        "hubs": hubs,
        "paint": {"color_rgb255": list(paint_color) if paint_color else None, "method": paint_method,
                  "parts": groups_json.get("Paint", {}).get("count", 0), "sameColourButTextured": paint_textured},
        "security": {"flaggedScripts": flagged, "verdict": "BACKDOOR - strip all scripts before parenting" if flagged else "no backdoor pattern found (still strip all scripts)"},
        "strip": dict(strip.most_common()),
        "groups": groups_json,
        "decals": decal_info,
        "brandHints": sorted({upath[n["id"]] for n in nodes if RE_BRAND.search(n["name"]) and n["class"] not in ("Script", "LocalScript", "ModuleScript")})[:40],
    }
    os.makedirs(OUT_DIR, exist_ok=True)
    json.dump(out, open(os.path.join(OUT_DIR, f"{model_id}.json"), "w"), indent=1)
    return out


def summary_line(o):
    g = o["groups"]
    c = o["counts"]

    def n(k):
        return g.get(k, {}).get("count", 0)
    wheels = "/".join(str(n("Wheel_" + q)) for q in ("FL", "FR", "RL", "RR"))
    lights = sum(v["count"] for k, v in g.items() if k.startswith("Lights_"))
    return (f"{o['assetId']} {o['name'][:26]:26s} vis={c['visibleParts']:3d} mesh={c['uniqueMeshes']:3d} tris={c['approxTris']:6d} "
            f"wheels={wheels} glass={n('Glass')} lights={lights} paint={n('Paint')}{o['paint']['color_rgb255']}+baked{n('PaintBaked')} "
            f"body={n('Body')} int={n('Interior')} dims={o['dims_studs']} scale={o['suggested_uniform_scale']} "
            f"fwd={o['forward']['method']} sec={'FLAG' if o['security']['flaggedScripts'] else 'ok'}")


def main(argv):
    ids = [a for a in argv if a.isdigit()]
    for i in ids:
        o = analyze(int(i))
        print(summary_line(o))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
