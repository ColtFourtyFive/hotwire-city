#!/usr/bin/env python3
"""Write the look into the place: rewrites ONLY

  * default.project.json  tree.MaterialService  (MaterialVariants + base-material overrides + Use2022Materials)
  * default.project.json  tree.Lighting         ($properties + the Sky/Atmosphere/Bloom/ColorCorrection/SunRays children)
  * src/shared/Config/Look.luau                 the block between "BEGIN GENERATED" and "END GENERATED"

from assets/materials/materials.json + manifest.json, assets/sky/skies.json + manifest.json, and the day preset of
Config/Look (exported with `lune run tools/look/export_look.luau`, so Look.luau stays the single source of truth).
Every other part of default.project.json is left byte-for-byte as it was (it round-trips through json.dumps(indent=2)).
Idempotent: a second run produces no diff. Look.luau is re-formatted with stylua afterwards.

Property names / value formats (verified against Rojo 7.7.1 `rojo build` output and the 0.744 API dump, see
tools/look/README.md):
  MaterialVariant  BaseMaterial "Asphalt" (enum by name), ColorMap/NormalMap/RoughnessMap/MetalnessMap
                   "rbxassetid://<Image id>" (Rojo migrates them to *Content), StudsPerTile number,
                   MaterialPattern "Regular"|"Organic"
  MaterialService  "<Material>Name": "<variant>" (NotScriptable, file-only), Use2022Materials true (-> ...Xml)
  Lighting         LightingStyle "Realistic", PrioritizeLightingQuality true, Color3 as [r, g, b] floats 0..1,
                   Technology "Future" (deprecated, but the engine derives LightingStyle from it on load: without it a
                   real server read LightingStyle Soft, jobs 0007 / 0009; see LIGHTING_TECHNOLOGY)
  Sky              SkyboxBk/Dn/Ft/Lf/Rt/Up "rbxassetid://<Image id>" (-> Skybox*Content), SkyboxOrientation [x, y, z]

Usage: python3 tools/look/gen_project.py [--check]   (--check: exit 1 if anything would change)
"""

import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import lookcommon as lc  # noqa: E402

PROJECT = os.path.join(lc.ROOT, "default.project.json")
LOOK_LUAU = os.path.join(lc.ROOT, "src", "shared", "Config", "Look.luau")
BEGIN = "-- BEGIN GENERATED (tools/look/gen_project.py) - do not edit by hand"
END = "-- END GENERATED"
FACE_ORDER = ["Bk", "Dn", "Ft", "Lf", "Rt", "Up"]
MAP_PROPS = [("color", "ColorMap"), ("normal", "NormalMap"), ("roughness", "RoughnessMap"),
             ("metalness", "MetalnessMap")]
# Materials Terrain:SetMaterialColor accepts. Real-engine probe (2026-10-27, tools/look/sun_probe.py): Asphalt, Brick,
# Concrete, Grass, Ground, LeafyGrass, Pavement, Rock, Sand, Slate, WoodPlanks OK; ClayRoofTiles, CorrodedMetal,
# Marble, Pebble, Plaster -> "Invalid terrain material". The rest are the other terrain materials.
# Lighting.Technology baked next to LightingStyle. The Unified Lighting migration maps the legacy Technology onto
# LightingStyle / PrioritizeLightingQuality when a place loads (Future -> Realistic + quality, ShadowMap -> Soft).
# Without Technology in the file the engine read LightingStyle = Soft on a headless server and in Studio although the
# file says Realistic (jobs 0007 / 0009; the Studio place carried RBX_OriginalTechnologyOnFileLoad = 3 = ShadowMap).
# Verified on the real engine with tools/look/probe_place.py (see tools/look/README.md "LightingStyle").
LIGHTING_TECHNOLOGY = "Future"
TERRAIN_MATERIALS = {"Asphalt", "Basalt", "Brick", "Cobblestone", "Concrete", "CrackedLava", "Glacier", "Grass",
                     "Ground", "Ice", "LeafyGrass", "Limestone", "Mud", "Pavement", "Rock", "Salt", "Sand",
                     "Sandstone", "Slate", "Snow", "WoodPlanks"}


def asset(manifest, path):
    e = manifest.get(path) or {}
    return "rbxassetid://%d" % e["assetId"] if e.get("assetId") else ""


def load_inputs():
    mats = lc.read_json(os.path.join(lc.MATERIALS_DIR, "materials.json"))
    if not mats:
        raise SystemExit("missing assets/materials/materials.json (run prep_materials.py)")
    mman = lc.read_json(os.path.join(lc.MATERIALS_DIR, "manifest.json"), {}) or {}
    skies = (lc.read_json(os.path.join(lc.SKY_DIR, "skies.json"), {}) or {}).get("skies", {})
    sman = lc.read_json(os.path.join(lc.SKY_DIR, "manifest.json"), {}) or {}
    out = subprocess.run(["lune", "run", "tools/look/export_look.luau"], cwd=lc.ROOT, capture_output=True,
                         text=True, check=True)
    look = json.loads(out.stdout)
    return mats, mman, skies, sman, look


def build_materials(mats, mman):
    variants = []
    for m in mats["materials"]:
        ids = {kind: asset(mman, path) for kind, path in m["files"].items()}
        missing = [k for k, v in ids.items() if not v]
        if missing:
            print("WARN: %s has no uploaded id for %s - left out (run tools/look/upload.py)" % (m["variant"], missing))
            continue
        variants.append((m, ids))
    return variants


def build_decals(mats, mman):
    out = []
    for d in mats["decals"]:
        img = asset(mman, d["file"])
        if not img:
            print("WARN: decal %s not uploaded" % d["name"])
        out.append((d, img))
    return out


def build_skies(skies, sman):
    out = {}
    for name, s in sorted(skies.items()):
        faces = {}
        for k, path in s["files"].items():
            faces[k[0].upper() + k[1:]] = asset(sman, path)
        if not all(faces.values()):
            print("WARN: sky %s has faces without ids" % name)
        out[name] = (s, faces)
    return out


# ---------------------------------------------------------------------------------------------------------------
# Luau block
# ---------------------------------------------------------------------------------------------------------------


def lua_str(s):
    return json.dumps(s, ensure_ascii=False)


def lua_num(x):
    if isinstance(x, bool):
        return "true" if x else "false"
    if float(x).is_integer():
        return str(int(x))
    return repr(round(float(x), 4))


def lua_rgb(c):
    return "{ %s }" % ", ".join(str(int(v)) for v in c)


def luau_block(variants, decals, skies):
    L = []
    L.append("local Materials: { [string]: MaterialDef } = {")
    for m, ids in sorted(variants, key=lambda v: v[0]["variant"]):
        L.append("\t%s = {" % m["variant"])
        L.append("\t\tkey = %s," % lua_str(m["key"]))
        L.append("\t\tbaseMaterial = %s," % lua_str(m["base"]))
        L.append("\t\toverride = %s," % lua_num(bool(m["override"])))
        L.append("\t\tcolorMap = %s," % lua_str(ids["color"]))
        L.append("\t\tnormalMap = %s," % lua_str(ids["normal"]))
        L.append("\t\troughnessMap = %s," % lua_str(ids["roughness"]))
        if ids.get("metalness"):
            L.append("\t\tmetalnessMap = %s," % lua_str(ids["metalness"]))
        L.append("\t\tstudsPerTile = %s," % lua_num(m["studsPerTile"]))
        L.append("\t\tpattern = %s," % lua_str(m["pattern"]))
        L.append("\t\tcolor = %s," % lua_rgb(m["color"]))
        L.append("\t\tnote = %s," % lua_str(m.get("note", "")))
        L.append("\t},")
    L.append("}")
    L.append("Look.Materials = Materials")
    L.append("")
    L.append("-- Global base-material overrides (every part and terrain voxel). Baked into the place as")
    L.append("-- MaterialService.<Material>Name, which the real engine does not honour (job 0009), so")
    L.append("-- Util/MaterialOverrides applies them at runtime too (server + every client).")
    L.append("local Overrides: { [string]: string } = {")
    for m, _ in sorted(variants, key=lambda v: v[0]["base"]):
        if m["override"]:
            L.append("\t%s = %s," % (m["base"], lua_str(m["variant"])))
    L.append("}")
    L.append("Look.Overrides = Overrides")
    L.append("")
    L.append("-- Terrain:SetMaterialColor values for the overridden TERRAIN materials (colour contract), applied by")
    L.append("-- LightingService after MapBuilder. Part-only materials are left out (the engine rejects them).")
    L.append("local TerrainColors: { [string]: RGB } = {")
    for m, _ in sorted(variants, key=lambda v: v[0]["base"]):
        if m["override"] and m["base"] in TERRAIN_MATERIALS:
            L.append("\t%s = %s," % (m["base"], lua_rgb(m["color"])))
    L.append("}")
    L.append("Look.TerrainColors = TerrainColors")
    L.append("")
    L.append("local Decals: { [string]: DecalDef } = {")
    for d, img in sorted(decals, key=lambda v: v[0]["name"]):
        L.append("\t%s = {" % d["name"])
        L.append("\t\timage = %s," % lua_str(img))
        L.append("\t\twidth = %d," % d["width"])
        L.append("\t\theight = %d," % d["height"])
        if "studsPerTileU" in d:
            L.append("\t\tstudsPerTileU = %s," % lua_num(d["studsPerTileU"]))
        if "studsPerTileV" in d:
            L.append("\t\tstudsPerTileV = %s," % lua_num(d["studsPerTileV"]))
        L.append("\t\tnote = %s," % lua_str(d["note"]))
        L.append("\t},")
    L.append("}")
    L.append("Look.Decals = Decals")
    L.append("")
    L.append("local Skies: { [string]: SkyDef } = {")
    for name, (s, faces) in skies.items():
        L.append("\t%s = {" % name)
        L.append("\t\tfaces = {")
        for k in FACE_ORDER:
            L.append("\t\t\t%s = %s," % (k, lua_str(faces.get(k, ""))))
        L.append("\t\t},")
        L.append("\t\tglowAzimuth = %s," % lua_num(s["glowAzimuth"]))
        L.append("\t\thorizonGlowAzimuth = %s," % lua_num(s["horizonGlowAzimuth"]))
        if "sunAzimuth" in s:
            L.append("\t\tsunAzimuth = %s," % lua_num(s["sunAzimuth"]))
            L.append("\t\tsunElevation = %s," % lua_num(s["sunElevation"]))
        L.append("\t\tfollowSun = %s," % lua_num(bool(s["followSun"])))
        L.append("\t\tstarCount = %d," % s["starCount"])
        L.append("\t\tcelestialBodiesShown = %s," % lua_num(bool(s["celestialBodiesShown"])))
        L.append("\t\tclouds = %s," % lua_num(s["clouds"]))
        L.append("\t\thazeColor = %s," % lua_rgb(s["hazeColor"]))
        L.append("\t},")
    L.append("}")
    L.append("Look.Skies = Skies")
    return "\n".join(L)


def write_look(block):
    src = open(LOOK_LUAU).read()
    i = src.index(BEGIN)
    j = src.index(END)
    # keep the BEGIN line and its separator line, replace everything up to the separator before END
    head_end = src.index("\n", src.index("\n", i) + 1) + 1
    tail_start = src.rindex("\n", 0, src.rindex("\n", 0, j)) + 1
    new = src[:head_end] + "\n" + block + "\n\n" + src[tail_start:]
    return new


# ---------------------------------------------------------------------------------------------------------------
# Project JSON
# ---------------------------------------------------------------------------------------------------------------


def c3(rgb):
    return [round(v / 255.0, 4) for v in rgb]


def material_service(variants):
    node = {"$className": "MaterialService", "$properties": {"Use2022Materials": True}}
    for m, _ in sorted(variants, key=lambda v: v[0]["base"]):
        if m["override"]:
            node["$properties"]["%sName" % m["base"]] = m["variant"]
    for m, ids in sorted(variants, key=lambda v: v[0]["variant"]):
        props = {"BaseMaterial": m["base"]}
        for kind, prop in MAP_PROPS:
            if ids.get(kind):
                props[prop] = ids[kind]
        props["StudsPerTile"] = m["studsPerTile"]
        props["MaterialPattern"] = m["pattern"]
        node[m["variant"]] = {"$className": "MaterialVariant", "$properties": props}
    return node


def lighting(look, skies):
    day = look["Presets"]["day"]
    style = look["SkyStyle"]
    start = look["Cycle"]["startHour"]
    a = day["atmosphere"]
    props = {
        "Technology": LIGHTING_TECHNOLOGY,
        "LightingStyle": "Realistic",
        "PrioritizeLightingQuality": True,
        "GlobalShadows": True,
        "EnvironmentDiffuseScale": 1,
        "EnvironmentSpecularScale": 1,
        "ShadowSoftness": day["shadowSoftness"],
        "Brightness": day["brightness"],
        "ExposureCompensation": day["exposure"],
        "Ambient": c3(day["ambient"]),
        "OutdoorAmbient": c3(day["outdoorAmbient"]),
        "ClockTime": start,
        "GeographicLatitude": look["Sun"]["latitude"],
        "FogEnd": 100000,
    }
    sky_props = {}
    day_sky = skies.get("day")
    celestial = True
    if day_sky:
        s, faces = day_sky
        for k in FACE_ORDER:
            if faces.get(k):
                sky_props["Skybox" + k] = faces[k]
        sky_props["StarCount"] = s["starCount"]
        celestial = bool(s["celestialBodiesShown"])
    sky_props.update({
        "SkyboxOrientation": [0, 0, 0],
        "SunAngularSize": style["sunAngularSize"],
        # the place starts at Look.Cycle.startHour, in daylight (tested): LightingService hides the moon while the
        # engine sun is up (moonSizeAt), so the file starts without one too
        "MoonAngularSize": 0,
        "CelestialBodiesShown": celestial,
    })
    cc = day["colorCorrection"]
    return {
        "$className": "Lighting",
        "$properties": props,
        "Sky": {"$className": "Sky", "$properties": sky_props},
        "Atmosphere": {"$className": "Atmosphere", "$properties": {
            "Density": a["density"], "Offset": a["offset"], "Haze": a["haze"], "Glare": a["glare"],
            "Color": c3(a["color"]), "Decay": c3(a["decay"])}},
        "Bloom": {"$className": "BloomEffect", "$properties": {
            "Intensity": day["bloom"]["intensity"], "Size": day["bloom"]["size"],
            "Threshold": day["bloom"]["threshold"]}},
        "ColorCorrection": {"$className": "ColorCorrectionEffect", "$properties": {
            "Brightness": cc["brightness"], "Contrast": cc["contrast"], "Saturation": cc["saturation"],
            "TintColor": c3(cc["tint"])}},
        "SunRays": {"$className": "SunRaysEffect", "$properties": {
            "Intensity": day["sunRays"]["intensity"], "Spread": day["sunRays"]["spread"]}},
    }


def dumps(obj):
    """json.dumps(indent=2), but short all-number lists on one line ([0.05, 0.05, 0.06])."""
    text = json.dumps(obj, indent=2, ensure_ascii=False)

    def inline(mt):
        items = [x.strip() for x in mt.group(1).split(",")]
        return "[" + ", ".join(items) + "]"

    return re.sub(r"\[\s*((?:-?[\d.eE+-]+\s*,\s*)*-?[\d.eE+-]+)\s*\]", inline, text)


def update_project(variants, look, skies):
    raw = open(PROJECT).read()
    proj = json.loads(raw)
    tree = proj["tree"]
    new_tree = {}
    for k, v in tree.items():
        if k == "Lighting":
            new_tree[k] = lighting(look, skies)
            if "MaterialService" not in tree:
                new_tree["MaterialService"] = material_service(variants)
        elif k == "MaterialService":
            new_tree[k] = material_service(variants)
        else:
            new_tree[k] = v
    if "Lighting" not in tree:
        new_tree["Lighting"] = lighting(look, skies)
    if "MaterialService" not in new_tree:
        new_tree["MaterialService"] = material_service(variants)
    proj["tree"] = new_tree
    out = dumps(proj)
    if raw.endswith("\n"):
        out += "\n"
    return raw, out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    mats, mman, skies_meta, sman, look = load_inputs()
    variants = build_materials(mats, mman)
    decals = build_decals(mats, mman)
    skies = build_skies(skies_meta, sman)

    old_look = open(LOOK_LUAU).read()
    new_look = write_look(luau_block(variants, decals, skies))
    raw, new_proj = update_project(variants, look, skies)

    if args.check:
        # format the candidate Look.luau the same way before comparing
        fmt = subprocess.run(["stylua", "-"], input=new_look, capture_output=True, text=True, cwd=lc.ROOT,
                             check=True).stdout
        changed = [p for p, a, b in ((LOOK_LUAU, old_look, fmt), (PROJECT, raw, new_proj)) if a != b]
        for p in changed:
            print("would change", lc.rel(p))
        sys.exit(1 if changed else 0)

    with open(LOOK_LUAU, "w") as f:
        f.write(new_look)
    subprocess.run(["stylua", LOOK_LUAU], cwd=lc.ROOT, check=True)
    with open(PROJECT, "w") as f:
        f.write(new_proj)
    print("variants %d (overrides %d), decals %d, skies %d" % (
        len(variants), sum(1 for m, _ in variants if m["override"]), len(decals), len(skies)))
    print("wrote", lc.rel(LOOK_LUAU), "and", lc.rel(PROJECT), "(MaterialService, Lighting)")


if __name__ == "__main__":
    main()
