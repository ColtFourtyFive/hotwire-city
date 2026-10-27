#!/usr/bin/env python3
"""Build Roblox-ready PBR maps for Hotwire City's MaterialVariants, plus road-marking / grime decal textures.

Sources are CC0 (ambientCG + Poly Haven, picks from docs/v2/research/cc0_assets.md). Outputs (all 1024 px, seamless):

  assets/materials/<key>/color.png       sRGB "detail" colour map (see COLOUR CONTRACT below)
  assets/materials/<key>/normal.png      tangent-space normal, OpenGL convention (+Y / green = image up)
  assets/materials/<key>/roughness.png   grayscale, white = rough
  assets/materials/<key>/metalness.png   grayscale, white = metal (only for materials that have metal)
  assets/materials/decals/<name>.png     RGBA decal textures (road markings, manhole, cracks, stains, grime)
  assets/materials/materials.json        metadata consumed by tools/look/upload.py and tools/look/gen_project.py
  docs/v2/early/look/materials_sheet.png / materials_maps.png / decals_sheet.png   contact sheets

COLOUR CONTRACT. Roblox multiplies a MaterialVariant's ColorMap by BasePart.Color (and terrain by its material colour),
exactly like its own 2022 materials, whose colour maps are bright near-neutral detail maps (measured: Brick mean
(223,208,197), Asphalt (225,226,227)). Our colour maps follow the same rule so the MaterialService base-material
overrides are drop-in for parts that are already coloured for built-in materials: each map is the graded source divided
by its (partly neutralised) mean colour and scaled to a bright mean. `look` is the art-directed average albedo; the
script derives `color` = the Part.Color (or terrain colour) that reproduces it, which gen_project.py writes into
Config/Look as the recommended colour.

Usage:
  python3 -I tools/look/prep_materials.py --src <cc0 texture dir> [--only key1,key2] [--fetch] [--no-sheets]
    <cc0 texture dir> holds ACG/<Id>/<Id>_1K-JPG_<Map>.jpg and PH/<id>/<id>_<map>_1k.jpg (as fetched by
    docs/v2/research/cc0_assets.md); --fetch downloads any missing source maps there first.
"""

import argparse
import io
import math
import os
import sys
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import numpy as np  # noqa: E402
from PIL import Image, ImageDraw  # noqa: E402

import lookcommon as lc  # noqa: E402

SIZE = 1024
T_MAX = 0.86  # brightest detail-map mean we aim for (Roblox's own maps sit around 0.88)

# ---------------------------------------------------------------------------------------------------------------
# Material definitions
#   key            folder name under assets/materials
#   variant        MaterialVariant name (HC_ prefix avoids clashes with Creator Store material packs)
#   base           Enum.Material name of MaterialVariant.BaseMaterial
#   override       also set MaterialService.<base>Name = variant (global look for every part/terrain of that material)
#   src            (library, id) or a procedural builder name
#   tile_m         real-world size of one tile in metres -> StudsPerTile = tile_m / 0.28
#   pattern        MaterialPattern: Regular | Organic
#   look           art-directed average albedo (sRGB 0..255) seen with the recommended Part.Color
#   hue_remove     0..1: how much of the source's average hue moves from the map into Part.Color (1 = neutral map)
#   detail         contrast of the colour detail about its mean (1 = source)
#   sat            saturation of the colour detail
#   rough          (target mean, contrast) of the roughness map
#   normal         normal-map strength multiplier
#   metal          None (dielectric: no map uploaded), "src", a constant, or "rust" (derived)
#   ao             how much of the ambient-occlusion map is multiplied into the colour map
#   shares         reuse another key's uploaded maps (no new images), only BaseMaterial/look differ
# ---------------------------------------------------------------------------------------------------------------

MATERIALS = [
    dict(key="asphalt", variant="HC_Asphalt", base="Asphalt", override=True, src=("ACG", "Road012A"), tile_m=3.0,
         pattern="Organic", look=(80, 80, 82), hue_remove=1.0, detail=1.15, sat=0.4, rough=(0.84, 1.0), normal=1.2,
         ao=0.5, note="Road asphalt for avenues and streets (fine dark aggregate)."),
    dict(key="asphalt_worn", variant="HC_AsphaltWorn", base="Asphalt", override=False, src=("PH", "asphalt_02"),
         tile_m=3.0, pattern="Organic", look=(98, 97, 94), hue_remove=1.0, detail=1.0, sat=0.4, rough=(0.86, 1.0),
         normal=1.0, ao=0.6, note="Worn, cracked asphalt for older streets, alleys and lots."),
    dict(key="asphalt_wet", variant="HC_AsphaltWet", base="Asphalt", override=False, src="wet:asphalt", tile_m=3.0,
         pattern="Organic", look=(60, 60, 62), rough=(0.24, 1.0), shares_maps=("color", "normal"),
         note="Night/rain swap for HC_Asphalt (same colour+normal, wet roughness with puddles)."),
    dict(key="sidewalk", variant="HC_Sidewalk", base="Pavement", override=True, src="sidewalk", tile_m=3.0,
         pattern="Regular", look=(172, 169, 162), hue_remove=1.0, detail=1.0, sat=0.3, rough=(0.80, 1.0), normal=1.0,
         ao=0.5, note="US concrete sidewalk: 1.5 m panels with tooled joints and smooth margins (2x2 panels per tile)."),
    dict(key="concrete", variant="HC_Concrete", base="Concrete", override=True, src=("ACG", "Concrete042A"),
         tile_m=2.6, pattern="Organic", look=(160, 157, 151), hue_remove=1.0, detail=0.7, sat=0.3, rough=(0.80, 1.0),
         normal=1.0, ao=0.5, note="Plain cast concrete: curbs, medians, freeway decks and pillars, walls."),
    dict(key="concrete_modern", variant="HC_ConcreteModern", base="Concrete", override=False,
         src=("ACG", "Concrete034"), tile_m=2.2, pattern="Organic", look=(190, 188, 183), hue_remove=1.0, detail=0.5,
         sat=0.3, rough=(0.68, 1.0), normal=0.9, ao=0.0, note="Smooth light architectural concrete for modern facades."),
    dict(key="brick_red", variant="HC_BrickRed", base="Brick", override=True, src=("PH", "red_brick"), tile_m=1.4,
         pattern="Regular", look=(136, 96, 76), hue_remove=0.55, detail=1.0, sat=0.85, rough=(0.88, 1.0), normal=1.0,
         ao=0.6, note="Red running-bond brick with grey mortar."),
    dict(key="brick_tan", variant="HC_BrickTan", base="Brick", override=False, src=("ACG", "Bricks105"), tile_m=2.4,
         pattern="Regular", look=(182, 150, 114), hue_remove=0.55, detail=1.0, sat=0.85, rough=(0.85, 1.0),
         normal=1.0, ao=0.6, note="Tan/buff brick, LA mid-century commercial."),
    dict(key="stucco", variant="HC_Stucco", base="Plaster", override=True, src=("ACG", "Plaster001"), tile_m=2.0,
         pattern="Organic", look=(226, 222, 214), hue_remove=1.0, detail=0.45, sat=0.0, rough=(0.90, 0.8),
         normal=0.9, ao=0.0, note="Fine stucco/plaster, near-white: tint per building with Part.Color (pastels, beige)."),
    dict(key="roof_tiles", variant="HC_RoofTiles", base="ClayRoofTiles", override=True,
         src=("ACG", "RoofingTiles006"), tile_m=3.2, pattern="Regular", look=(150, 86, 62), hue_remove=0.5,
         detail=1.0, sat=0.85, rough=(0.74, 1.0), normal=1.0, ao=0.7, note="Terracotta barrel tiles (Spanish/Mission)."),
    dict(key="gravel_roof", variant="HC_GravelRoof", base="Pebble", override=True, src=("ACG", "Gravel023"),
         tile_m=1.5, pattern="Organic", look=(170, 167, 160), hue_remove=1.0, detail=0.9, sat=0.4, rough=(0.92, 1.0),
         normal=1.0, ao=0.6, note="Flat-roof gravel ballast (downtown roofs seen from the air)."),
    dict(key="corrugated_metal", variant="HC_CorrugatedMetal", base="Metal", override=False,
         src=("PH", "corrugated_iron"), tile_m=1.12, pattern="Regular", look=(160, 166, 166), hue_remove=1.0,
         detail=1.0, sat=0.5, rough=(0.46, 1.0), normal=1.2, metal=0.9, ao=0.6,
         note="Galvanised corrugated sheet (warehouses, sheds, fences). Not a global Metal override (lamp poles, cars)."),
    dict(key="rusty_metal", variant="HC_RustyMetal", base="CorrodedMetal", override=True,
         src=("PH", "rusty_metal_02"), tile_m=2.0, pattern="Organic", look=(150, 124, 92), hue_remove=0.35,
         detail=1.0, sat=0.8, rough=(0.70, 1.0), normal=1.0, metal="rust", ao=0.5,
         note="Galvanised steel with rust bloom (port, industrial props)."),
    dict(key="wood_planks", variant="HC_WoodPlanks", base="WoodPlanks", override=True,
         src=("PH", "weathered_brown_planks"), tile_m=1.8, pattern="Regular", look=(112, 90, 70), hue_remove=0.5,
         detail=1.0, sat=0.8, rough=(0.84, 1.0), normal=1.0, ao=0.6, note="Weathered boardwalk / pier planks."),
    dict(key="grass", variant="HC_Grass", base="Grass", override=True, src=("ACG", "Grass004"), tile_m=2.8,
         pattern="Organic", look=(90, 102, 56), hue_remove=0.7, detail=1.0, sat=0.8, rough=(0.92, 1.0), normal=1.0,
         ao=0.5, note="Mown lawn, slightly dry LA green (parts and terrain)."),
    dict(key="grass_leafy", variant="HC_GrassLeafy", base="LeafyGrass", override=True, shares="grass",
         look=(84, 98, 54), note="Same maps as HC_Grass for the LeafyGrass terrain material."),
    dict(key="grass_dry", variant="HC_DryGrass", base="Ground", override=True, src=("PH", "withered_grass"),
         tile_m=3.4, pattern="Organic", look=(152, 134, 106), hue_remove=0.7, detail=1.0, sat=0.8, rough=(0.92, 1.0),
         normal=1.0, ao=0.5, note="Dry grass and dirt for hills and lots (Ground terrain)."),
    dict(key="sand", variant="HC_Sand", base="Sand", override=True, src=("ACG", "Ground055S"), tile_m=3.4,
         pattern="Organic", look=(198, 186, 158), hue_remove=1.0, detail=1.0, sat=0.5, rough=(0.93, 1.0), normal=1.1,
         ao=0.3, note="Pale wind-rippled beach sand."),
    dict(key="rock", variant="HC_Rock", base="Rock", override=True, src=("PH", "rock_face_03"), tile_m=4.0,
         pattern="Organic", look=(136, 116, 96), hue_remove=0.6, detail=1.0, sat=0.8, rough=(0.86, 1.0), normal=1.0,
         ao=0.6, note="Tan fractured rock for cliffs and hill cuts."),
    dict(key="rock_slate", variant="HC_RockSlate", base="Slate", override=True, shares="rock", look=(120, 108, 96),
         note="Same maps as HC_Rock for the Slate material (cliffs built from Slate)."),
    dict(key="terrazzo", variant="HC_Terrazzo", base="Marble", override=True, src=("ACG", "Terrazzo005"),
         tile_m=1.6, pattern="Organic", look=(204, 200, 194), hue_remove=1.0, detail=0.85, sat=0.5,
         rough=(0.30, 1.0), normal=1.0, ao=0.0, note="White terrazzo for plazas, lobbies, malls and the airport."),
    dict(key="window_glass", variant="HC_WindowGlass", base="SmoothPlastic", override=False, src="glass", tile_m=3.4,
         pattern="Regular", look=(44, 54, 62), rough=(0.07, 1.0), metal=0.25,
         note="Opaque reflective facade glass (low roughness, slight metalness). Glass has no MaterialService override "
              "slot, so this variant sits on SmoothPlastic: set Material=SmoothPlastic + MaterialVariant=HC_WindowGlass."),
]

# ---------------------------------------------------------------------------------------------------------------
# Source lookup / fetch
# ---------------------------------------------------------------------------------------------------------------

ACG_MAPS = {"color": "Color", "normal": "NormalGL", "rough": "Roughness", "metal": "Metalness",
            "ao": "AmbientOcclusion", "opacity": "Opacity"}
PH_MAPS = {"color": "diff", "normal": "nor_gl", "rough": "rough", "metal": "metal", "ao": "ao"}


def src_path(src_dir, lib, ident, m):
    if lib == "ACG":
        return os.path.join(src_dir, "ACG", ident, "%s_1K-JPG_%s.jpg" % (ident, ACG_MAPS[m]))
    return os.path.join(src_dir, "PH", ident, "%s_%s_1k.jpg" % (ident, PH_MAPS[m]))


def fetch(src_dir, lib, ident):
    """Download a source set (1K JPG). ambientCG ships zips; only the expected member names are extracted."""
    if lib == "ACG":
        d = os.path.join(src_dir, "ACG", ident)
        if os.path.exists(src_path(src_dir, lib, ident, "color")):
            return
        url = "https://ambientcg.com/get?file=%s_1K-JPG.zip" % ident
        print("fetch", url)
        data = urllib.request.urlopen(url, timeout=120).read()
        os.makedirs(d, exist_ok=True)
        allowed = {"%s_1K-JPG_%s.jpg" % (ident, v) for v in ACG_MAPS.values()}
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            for name in z.namelist():
                base = os.path.basename(name)
                if base in allowed and "/" not in name and "\\" not in name:
                    with open(os.path.join(d, base), "wb") as f:
                        f.write(z.read(name))
    else:
        d = os.path.join(src_dir, "PH", ident)
        os.makedirs(d, exist_ok=True)
        for m, v in PH_MAPS.items():
            p = src_path(src_dir, lib, ident, m)
            if os.path.exists(p):
                continue
            url = "https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/%s/%s_%s_1k.jpg" % (ident, ident, v)
            try:
                data = urllib.request.urlopen(url, timeout=120).read()
            except Exception:  # noqa: BLE001 - optional maps (metal, ao) may not exist
                continue
            print("fetch", url)
            with open(p, "wb") as f:
                f.write(data)


def load_set(src_dir, lib, ident):
    out = {}
    for m in ("color", "normal", "rough", "metal", "ao", "opacity"):
        p = src_path(src_dir, lib, ident, m) if (lib == "ACG" or m in PH_MAPS) else None
        if not p or not os.path.exists(p):
            continue
        a = lc.load_rgb(p) if m in ("color", "normal") else lc.load_gray(p)
        a = lc.squarify(a)
        a = lc.resize(a, SIZE, SIZE)
        out[m] = a
    if "color" not in out or "normal" not in out or "rough" not in out:
        raise SystemExit("missing source maps for %s/%s (use --fetch)" % (lib, ident))
    out["src"] = "%s/%s" % (lib, ident)
    return out


# ---------------------------------------------------------------------------------------------------------------
# Procedural sources
# ---------------------------------------------------------------------------------------------------------------


def build_sidewalk(src_dir):
    """US sidewalk: 1.5 m panels (2x2 per 3 m tile) on a real 3 m concrete scan, tooled joints, smooth margins."""
    if ARGS.fetch:
        fetch(src_dir, "PH", "concrete_floor_worn_001")
    s = load_set(src_dir, "PH", "concrete_floor_worn_001")
    n = SIZE
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
    half = n / 2.0

    def dist_to_joint(c):  # distance (px) to the nearest joint line at 0 / half / n (periodic)
        d = np.abs(((c + half / 2) % half) - half / 2)
        return d

    dx, dy = dist_to_joint(xx), dist_to_joint(yy)
    d = np.minimum(dx, dy)
    groove_w = 2.6  # px half-width (~0.8 cm at 3 m / 1024 px)
    margin = 16.0  # tooled smooth border (~5 cm)
    groove = np.exp(-(d / groove_w) ** 2)
    rim = np.clip(1 - d / margin, 0, 1) * (1 - groove)
    # per-panel tone (+-3 %)
    rng = np.random.default_rng(7)
    tones = rng.uniform(-0.03, 0.03, size=(2, 2))
    pi = (yy >= half).astype(int)
    pj = (xx >= half).astype(int)
    tone = tones[pi, pj]
    # broom finish: faint streaks across the walking direction
    broom = lc.fractal_noise(n, beta=1.2, seed=11, lo=40, hi=400, sy=12.0)  # streaks along y, tileable
    col = s["color"] * (1 + tone)[..., None] * (1 - 0.05 * (broom - 0.5))[..., None]
    col = col * (1 - 0.45 * groove)[..., None] + 0.03 * rim[..., None]
    height = -groove * 1.0 + rim * 0.05
    gn = lc.height_to_normal(height, 9.0)
    nrm = lc.blend_normals(lc.normal_strength(s["normal"], 0.8), gn)
    rough = s["rough"] * (1 - 0.18 * rim) + 0.12 * groove
    return {"color": np.clip(col, 0, 1), "normal": nrm, "rough": np.clip(rough, 0, 1), "ao": s.get("ao"),
            "src": "PH/concrete_floor_worn_001 + procedural joints"}


def build_glass(_src_dir):
    """Facade glass: almost uniform colour, very low-frequency panel waviness, faint smudges in roughness."""
    n = SIZE
    smudge = lc.fractal_noise(n, beta=2.2, seed=3, lo=2, hi=60)
    wave = lc.fractal_noise(n, beta=3.0, seed=5, lo=1, hi=6)
    col = np.ones((n, n, 3), np.float32) * (0.95 + 0.05 * smudge[..., None])
    nrm = lc.height_to_normal(wave * 6.0, 1.0)
    rough = 0.05 + 0.06 * np.clip((smudge - 0.45) * 2.5, 0, 1)
    return {"color": col, "normal": nrm, "rough": rough, "src": "procedural"}


# ---------------------------------------------------------------------------------------------------------------
# Processing
# ---------------------------------------------------------------------------------------------------------------


def detail_color(img, look, hue_remove, detail, sat):
    """Colour map + the Part.Color that reproduces `look` (see COLOUR CONTRACT in the module doc)."""
    img = lc.saturate(img, sat)
    img = lc.contrast_about_mean(img, detail)
    img = np.clip(img, 0.002, 1)
    m = img.mean(axis=(0, 1))
    grey = float((m * lc.LUMA).sum())
    m_ref = grey + (m - grey) * hue_remove  # 1 = per-channel normalisation (neutral map), 0 = keep the source hue
    ratio = img / m_ref
    p = float(np.percentile(ratio.max(axis=-1), 99.5))
    t = min(T_MAX, 1.0 / max(p, 1e-6))
    t = max(t, 0.55)
    cmap = lc.soft_clip(ratio * t, 0.92)
    mean_map = cmap.mean(axis=(0, 1))
    color = np.array(look, np.float32) / 255.0 / np.maximum(mean_map, 1e-3)
    if color.max() > 1.0:  # brighter than the map can deliver: scale the map up and the colour down
        k = color.max()
        cmap = lc.soft_clip(cmap * k, 0.94)
        mean_map = cmap.mean(axis=(0, 1))
        color = np.array(look, np.float32) / 255.0 / np.maximum(mean_map, 1e-3)
        color = np.minimum(color, 1.0)
    return cmap, color, float(t)


def roughness_map(r, target, contrast):
    r2 = target + (r - r.mean()) * contrast
    return np.clip(r2, 0.02, 1.0)


def rust_metal(color_src):
    """Galvanised zinc reads metal, rust reads dielectric: mask from warm chroma."""
    r, g, b = color_src[..., 0], color_src[..., 1], color_src[..., 2]
    rustiness = np.clip((r - b) * 3.2 - 0.25, 0, 1)
    return np.clip(0.88 * (1 - rustiness), 0, 1)


def process(defn, src_dir, done):
    key = defn["key"]
    out_dir = os.path.join(lc.MATERIALS_DIR, key)
    rec = {k: v for k, v in defn.items() if k not in ("src",)}
    rec["studsPerTile"] = round(defn.get("tile_m", 3.0) / lc.STUD_M, 2) if "tile_m" in defn else None
    if "shares" in defn:
        parent = done[defn["shares"]]
        rec.update(studsPerTile=parent["studsPerTile"], pattern=parent["pattern"], maps=parent["maps"],
                   files=parent["files"], source=parent["source"])
        mean_map = np.array(parent["mapMean"], np.float32)
        rec["color"] = [int(round(c)) for c in np.clip(np.array(defn["look"]) / np.maximum(mean_map, 1e-3), 0, 255)]
        rec["mapMean"] = parent["mapMean"]
        return rec

    src = defn["src"]
    if isinstance(src, tuple):
        if ARGS.fetch:
            fetch(src_dir, *src)
        s = load_set(src_dir, *src)
    elif src == "sidewalk":
        s = build_sidewalk(src_dir)
    elif src == "glass":
        s = build_glass(src_dir)
    elif src.startswith("wet:"):
        parent = done[src.split(":")[1]]
        base_rough = lc.load_gray(os.path.join(lc.ROOT, parent["files"]["roughness"]))
        puddles = lc.fractal_noise(SIZE, beta=3.0, seed=21, lo=1, hi=24)
        pm = np.clip((puddles - 0.58) * 6.0, 0, 1)
        rough = np.clip(0.30 + (base_rough - base_rough.mean()) * 0.5, 0.12, 0.6) * (1 - pm) + 0.05 * pm
        lc.save_png(rough, os.path.join(out_dir, "roughness.png"))
        rec.update(pattern=parent["pattern"], source=parent["source"] + " (wet roughness)")
        rec["maps"] = {"color": parent["key"], "normal": parent["key"], "roughness": key}
        rec["files"] = {"color": parent["files"]["color"], "normal": parent["files"]["normal"],
                        "roughness": lc.rel(os.path.join(out_dir, "roughness.png"))}
        mean_map = np.array(parent["mapMean"], np.float32)
        rec["color"] = [int(round(c)) for c in np.clip(np.array(defn["look"]) / np.maximum(mean_map, 1e-3), 0, 255)]
        rec["mapMean"] = parent["mapMean"]
        rec["seam"] = parent["seam"]
        return rec
    else:
        raise SystemExit("unknown src " + str(src))

    col = s["color"]
    if s.get("ao") is not None and defn.get("ao", 0) > 0:
        col = col * (1 - defn["ao"] + defn["ao"] * s["ao"])[..., None]
    if src == "glass":
        cmap = col
        mean_map = cmap.mean(axis=(0, 1))
        color = np.minimum(np.array(defn["look"], np.float32) / 255.0 / mean_map, 1.0)
        t = float(mean_map.mean())
    else:
        cmap, color, t = detail_color(col, defn["look"], defn.get("hue_remove", 1.0), defn.get("detail", 1.0),
                                      defn.get("sat", 1.0))
    nrm = lc.normal_strength(s["normal"], defn.get("normal", 1.0))
    rough = roughness_map(s["rough"], *defn["rough"])
    metal = None
    mdef = defn.get("metal")
    if mdef == "src" and s.get("metal") is not None:
        metal = s["metal"]
    elif mdef == "rust":
        metal = rust_metal(s["color"])
        rough = np.clip(rough * (0.55 + 0.45 * (1 - metal)) + 0.08, 0, 1)  # zinc smoother than rust
    elif isinstance(mdef, (int, float)):
        if s.get("metal") is not None:
            metal = np.clip(s["metal"] * mdef, 0, 1)
        else:
            metal = np.full((SIZE, SIZE), float(mdef), np.float32)
        if src == "glass":
            metal = np.clip(metal + 0.04 * (lc.fractal_noise(SIZE, 2.0, 9, 2, 40) - 0.5), 0, 1)

    seams = {}
    for name, arr in (("color", cmap), ("normal", nrm), ("roughness", rough)):
        sx, sy = lc.seam_ratio(arr)
        seams[name] = [round(sx, 2), round(sy, 2)]

    files = {}
    files["color"] = lc.rel(lc.save_png(cmap, os.path.join(out_dir, "color.png")))
    files["normal"] = lc.rel(lc.save_png(nrm, os.path.join(out_dir, "normal.png")))
    files["roughness"] = lc.rel(lc.save_png(rough, os.path.join(out_dir, "roughness.png")))
    if metal is not None:
        files["metalness"] = lc.rel(lc.save_png(metal, os.path.join(out_dir, "metalness.png")))
    else:
        stale = os.path.join(out_dir, "metalness.png")
        if os.path.exists(stale):
            os.remove(stale)
    rec.update(files=files, maps={k: key for k in files}, source=s["src"], seam=seams,
               color=[int(round(c * 255)) for c in np.clip(color, 0, 1)],
               mapMean=[round(float(c), 4) for c in cmap.mean(axis=(0, 1))], detailScale=round(t, 3))
    print("%-18s %-20s studs=%5.2f color=%s seams=%s" % (key, rec["source"], rec["studsPerTile"], rec["color"], seams))
    return rec


# ---------------------------------------------------------------------------------------------------------------
# Decals (RGBA, not PBR; Decal/Texture.Color3 multiplies them)
# ---------------------------------------------------------------------------------------------------------------

WHITE_PAINT = (232, 232, 224)
YELLOW_PAINT = (214, 168, 44)


def wear(h, w, seed, amount):
    """Tileable paint-wear field in 0..1 (1 = paint gone)."""
    size = max(h, w)
    a = lc.fractal_noise(size, beta=1.6, seed=seed, lo=3, hi=size // 3)
    b = lc.fractal_noise(size, beta=2.4, seed=seed + 1, lo=1, hi=12)
    field = 0.6 * a + 0.4 * b
    field = lc.resize(field, w, h) if (h, w) != (size, size) else field
    return np.clip((field - (1.0 - amount)) * 4.0, 0, 1)


def paint_rgba(mask, paint, seed, amount=0.42):
    h, w = mask.shape
    wr = wear(h, w, seed, amount)
    grain = lc.fractal_noise(max(h, w), beta=1.0, seed=seed + 7, lo=20)
    grain = lc.resize(grain, w, h) if h != w else grain
    alpha = mask * (1 - wr) * (0.86 + 0.14 * grain)
    col = np.array(paint, np.float32) / 255.0 * (0.9 + 0.1 * grain)[..., None]
    return np.concatenate([col, alpha[..., None]], axis=-1)


def supersample_mask(w, h, draw_fn, ss=4):
    im = Image.new("L", (w * ss, h * ss), 0)
    draw_fn(ImageDraw.Draw(im), w * ss, h * ss)
    return np.asarray(im.resize((w, h), Image.LANCZOS), np.float32) / 255.0


def ragged(mask, seed, px=1.5):
    """Slightly irregular paint edges."""
    h, w = mask.shape
    n = lc.fractal_noise(max(h, w), beta=1.4, seed=seed, lo=8)
    n = lc.resize(n, w, h) if h != w else n
    return np.clip((lc.blur(mask, 0.8) - 0.5) * 1.6 + 0.5 + (n - 0.5) * 0.35 * px, 0, 1)


def arrow_mask(kind, w=512, h=1024):
    """MUTCD-style elongated lane arrows (pointing up = direction of travel when the decal's top faces forward)."""

    def draw(d, W, H):
        sw = 0.15 * W  # shaft width
        cx = 0.5 * W

        def straight(x):
            d.rectangle((x - sw / 2, 0.40 * H, x + sw / 2, 0.985 * H), fill=255)
            d.polygon([(x, 0.015 * H), (x - 0.28 * W, 0.42 * H), (x + 0.28 * W, 0.42 * H)], fill=255)

        def turn(x, side):
            # shaft from the bottom up, then a quarter arc to the side, then a head pointing sideways
            d.rectangle((x - sw / 2, 0.58 * H, x + sw / 2, 0.985 * H), fill=255)
            r = 0.17 * W
            ccx = x + side * r
            ccy = 0.58 * H
            pts = []
            for i in range(0, 41):
                ang = math.pi * (i / 80.0)
                pts.append((ccx - side * r * math.cos(ang), ccy - r * math.sin(ang)))
            for i in range(len(pts) - 1):
                d.line([pts[i], pts[i + 1]], fill=255, width=int(sw))
                d.ellipse((pts[i][0] - sw / 2, pts[i][1] - sw / 2, pts[i][0] + sw / 2, pts[i][1] + sw / 2), fill=255)
            ey = ccy - r
            hx = ccx + side * 0.02 * W
            tip = ccx + side * 0.42 * W
            d.polygon([(tip, ey), (hx, ey - 0.13 * H), (hx, ey + 0.13 * H)], fill=255)

        if kind == "straight":
            straight(cx)
        elif kind == "left":
            turn(0.62 * W, -1)
        elif kind == "right":
            turn(0.38 * W, 1)
        elif kind == "straight_left":
            straight(0.64 * W)
            turn(0.64 * W, -1)
        elif kind == "straight_right":
            straight(0.36 * W)
            turn(0.36 * W, 1)

    return supersample_mask(w, h, draw)


def crack_mask(n, seed, count, width, branch=0.35, seg=6.0):
    """Random-walk crack network, tileable by drawing every stroke at 9 offsets."""
    rng = np.random.default_rng(seed)
    ss = 2
    im = Image.new("L", (n * ss, n * ss), 0)
    d = ImageDraw.Draw(im)
    N = n * ss

    def stroke(x, y, ang, length, wdt, depth):
        pts = [(x, y)]
        for _ in range(int(length / seg)):
            ang += rng.normal(0, 0.35)
            x += math.cos(ang) * seg * ss
            y += math.sin(ang) * seg * ss
            pts.append((x, y))
            if depth < 2 and rng.random() < branch * 0.04:
                stroke(x, y, ang + rng.choice([-1, 1]) * rng.uniform(0.6, 1.2), length * 0.4, wdt * 0.6, depth + 1)
        for ox in (-N, 0, N):
            for oy in (-N, 0, N):
                d.line([(px + ox, py + oy) for px, py in pts], fill=255, width=max(1, int(wdt * ss)), joint="curve")

    for _ in range(count):
        stroke(rng.uniform(0, N), rng.uniform(0, N), rng.uniform(0, 2 * math.pi), rng.uniform(0.3, 0.8) * n, width, 0)
    return np.asarray(im.resize((n, n), Image.LANCZOS), np.float32) / 255.0


def blotch_mask(n, seed, falloff=0.42, thresh=0.45):
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32) / n - 0.5
    r = np.sqrt(xx * xx + yy * yy)
    radial = np.clip(1 - r / falloff, 0, 1)
    nz = lc.fractal_noise(n, beta=2.0, seed=seed, lo=2, hi=80)
    m = np.clip((nz * 0.6 + radial * 0.9 - thresh) * 3.0, 0, 1)
    return m * np.clip(radial * 3, 0, 1)


def build_decals(src_dir):
    out = os.path.join(lc.MATERIALS_DIR, "decals")
    os.makedirs(out, exist_ok=True)
    decals = []

    def put(name, rgba, note, **hints):
        p = lc.save_png(rgba, os.path.join(out, name + ".png"))
        h, w = rgba.shape[:2]
        rec = dict(name=name, file=lc.rel(p), width=w, height=h, note=note)
        rec.update(hints)
        decals.append(rec)

    # ---- lines (full-bleed paint: the marking part's own size sets the line width; tile along V)
    full = np.ones((1024, 128), np.float32)
    edge = np.ones((1024, 128), np.float32)
    edge[:, :3] = 0.6
    edge[:, -3:] = 0.6
    put("line_white_solid", paint_rgba(full * edge, WHITE_PAINT, 101),
        "Solid white line. Texture on the top face of a 0.45-stud-wide marking strip; StudsPerTileV ~ 12.",
        studsPerTileV=12)
    put("line_yellow_solid", paint_rgba(full * edge, YELLOW_PAINT, 102), "Solid yellow line (same use).",
        studsPerTileV=12)
    dash = np.zeros((1024, 128), np.float32)
    dash[:256] = 1.0  # 10 ft dash in a 40 ft period
    dash = ragged(dash * edge, 103)
    put("line_white_dash", paint_rgba(dash, WHITE_PAINT, 104),
        "White lane dash: 10 ft dash + 30 ft gap per tile. StudsPerTileV = 42.7 (period).", studsPerTileV=42.7)
    put("line_yellow_dash", paint_rgba(dash, YELLOW_PAINT, 105), "Yellow centre dash (same period).",
        studsPerTileV=42.7)
    dbl = np.zeros((1024, 255), np.float32)
    dbl[:, :85] = 1.0
    dbl[:, 170:] = 1.0
    dbl = ragged(dbl, 106)
    put("line_yellow_double", paint_rgba(dbl, YELLOW_PAINT, 107),
        "Double solid yellow centre line: two 0.45 lines with a 0.45 gap (strip 1.35 studs wide).", studsPerTileV=12)
    stop = ragged(np.ones((256, 1024), np.float32) * (np.pad(np.ones((250, 1024)), ((3, 3), (0, 0))) * 0.4 + 0.6),
                  108)
    put("stop_line_white", paint_rgba(stop, WHITE_PAINT, 109, 0.36),
        "Stop bar (full bleed, tile along U). Strip 1.6 studs deep across the lanes.", studsPerTileU=12)
    bars = np.zeros((512, 512), np.float32)
    bars[:, :256] = 1.0
    bars = ragged(bars, 110)
    put("crosswalk_bars_white", paint_rgba(bars, WHITE_PAINT, 111, 0.4),
        "Continental crosswalk: one bar + one gap per tile along U, bars run along V. Strip 10.7 studs long "
        "(crossing width); StudsPerTileU = 4.3 (0.6 m bars), StudsPerTileV = 10.7.", studsPerTileU=4.3,
        studsPerTileV=10.7)
    for i, kind in enumerate(("straight", "left", "right", "straight_left", "straight_right")):
        m = ragged(arrow_mask(kind), 120 + i, 1.0)
        put("arrow_" + kind, paint_rgba(m, WHITE_PAINT, 130 + i, 0.32),
            "White lane arrow (%s), 512x1024; Decal on a 4 x 8 stud area, top = direction of travel." % kind)

    # ---- grime / street detail
    acg = os.path.join(src_dir, "ACG")
    mh = os.path.join(acg, "ManholeCover009", "ManholeCover009_1K-JPG_Color.jpg")
    if os.path.exists(mh):
        c = lc.load_rgb(mh)
        o = lc.load_gray(mh.replace("_Color", "_Opacity"))
        ys, xs = np.where(o > 0.5)
        y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
        c, o = c[y0:y1, x0:x1], o[y0:y1, x0:x1]
        c = lc.saturate(c, 0.35) * 0.82
        rgba = np.concatenate([c, o[..., None]], axis=-1)
        put("manhole_round", lc.resize(rgba, 512, 512), "Round cast-iron manhole cover (Decal, ~2.6 x 2.6 studs).")
    dmg = os.path.join(acg, "AsphaltDamageSet001", "AsphaltDamageSet001_1K-JPG_Color.jpg")
    if os.path.exists(dmg):
        c = lc.load_rgb(dmg)
        o = lc.load_gray(dmg.replace("_Color", "_Opacity"))
        for j, (y0, y1) in enumerate(((0, 300), (520, 800))):
            cc = lc.saturate(c[y0:y1], 0.3) * 0.75
            oo = o[y0:y1]
            put("asphalt_damage_%s" % "ab"[j], np.concatenate([cc, oo[..., None]], axis=-1),
                "Torn/patched asphalt patch (1024x%d), Decal on roads to break tiling." % (y1 - y0))
    cr = crack_mask(1024, 201, 9, 2.2)
    col = np.full((1024, 1024, 3), 0.10, np.float32)
    put("crack_network", np.concatenate([col, (cr * 0.85)[..., None]], axis=-1),
        "Thin asphalt cracks (tileable). Texture over a road with StudsPerTile ~ 24, or Decal.")
    tar = crack_mask(1024, 303, 6, 7.0, branch=0.2, seg=8.0)
    col = np.full((1024, 1024, 3), 0.045, np.float32)
    put("tar_snakes", np.concatenate([col, (lc.blur(tar, 1.0) * 0.92)[..., None]], axis=-1),
        "Crack-sealant 'tar snakes' (tileable), very LA. Texture with StudsPerTile ~ 30.")
    for j, seed in enumerate((401, 402)):
        m = blotch_mask(512, seed)
        col = np.stack([np.full((512, 512), 0.07), np.full((512, 512), 0.065), np.full((512, 512), 0.06)], -1)
        put("oil_stain_%s" % "ab"[j], np.concatenate([col.astype(np.float32), (m * 0.5)[..., None]], axis=-1),
            "Oil/tyre stain for parking spots, junction stop zones, driveways (Decal ~6 x 6 studs).")
    n = 512
    streak = lc.fractal_noise(n, beta=1.5, seed=501, lo=2, hi=120, sy=16.0)
    streak = lc.resize(streak, n, 2 * n)
    fall = np.linspace(1, 0, 2 * n, dtype=np.float32)[:, None] ** 1.6
    a = np.clip((streak - 0.35) * 1.8, 0, 1) * fall * 0.55
    col = np.stack([np.full((2 * n, n), 0.18), np.full((2 * n, n), 0.16), np.full((2 * n, n), 0.14)], -1)
    put("wall_grime_streaks", np.concatenate([col.astype(np.float32), a[..., None]], axis=-1),
        "Rain-streak grime under ledges/windows/AC units (Decal on walls, top edge at the ledge).")
    return decals


# ---------------------------------------------------------------------------------------------------------------
# Contact sheets
# ---------------------------------------------------------------------------------------------------------------


def tiled(a, reps=2, size=320):
    t = np.concatenate([np.concatenate([a] * reps, axis=1)] * reps, axis=0)
    return lc.resize(t, size, size)


def material_preview(rec, size=320):
    f = rec["files"]
    col = lc.load_rgb(os.path.join(lc.ROOT, f["color"])) * (np.array(rec["color"], np.float32) / 255.0)
    nrm = lc.load_rgb(os.path.join(lc.ROOT, f["normal"]))
    rough = lc.load_gray(os.path.join(lc.ROOT, f["roughness"]))
    metal = lc.load_gray(os.path.join(lc.ROOT, f["metalness"])) if "metalness" in f else None
    shaded = lc.render_lit(col, nrm, rough, metal)
    return tiled(shaded, 2, size)


def sheets(recs, decals):
    os.makedirs(lc.EARLY_DIR, exist_ok=True)
    T = 300
    cols = 5
    rows = (len(recs) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * T, rows * (T + 34) + 40), (14, 14, 16))
    lc.label(sheet, (8, 10), "Hotwire City v2 - MaterialVariants (lit preview, 2x2 tiles, recommended Part.Color, "
             "light from upper-left: bumps lit on top = OpenGL +Y normals)", size=15, fill=(255, 210, 120))
    for i, r in enumerate(recs):
        x0, y0 = (i % cols) * T, 40 + (i // cols) * (T + 34)
        prev = material_preview(r, T)
        sheet.paste(Image.fromarray(lc.to_u8(prev)), (x0, y0 + 34))
        star = " *override" if r["override"] else ""
        lc.label(sheet, (x0 + 4, y0 + 2), "%s%s" % (r["variant"], star), size=13, fill=(255, 255, 255))
        lc.label(sheet, (x0 + 4, y0 + 18), "%s  %s studs  %s" % (r["base"], r["studsPerTile"], r["pattern"]),
                 size=11, fill=(200, 200, 200))
        sw = Image.new("RGB", (26, 26), tuple(r["color"]))
        sheet.paste(sw, (x0 + T - 30, y0 + 38))
    sheet.save(os.path.join(lc.EARLY_DIR, "materials_sheet.png"))

    uniq = [r for r in recs if "shares" not in r and not r.get("shares_maps")]
    M = 180
    maps_sheet = Image.new("RGB", (5 * M + 160, len(uniq) * M + 30), (14, 14, 16))
    for j, h in enumerate(("color x Part.Color", "color map", "normal (GL)", "roughness", "metalness")):
        lc.label(maps_sheet, (160 + j * M + 4, 6), h, size=12)
    for i, r in enumerate(uniq):
        y = 30 + i * M
        f = r["files"]
        cmap = lc.load_rgb(os.path.join(lc.ROOT, f["color"]))
        cells = [cmap * (np.array(r["color"], np.float32) / 255.0), cmap,
                 lc.load_rgb(os.path.join(lc.ROOT, f["normal"])),
                 np.repeat(lc.load_gray(os.path.join(lc.ROOT, f["roughness"]))[..., None], 3, -1)]
        if "metalness" in f:
            cells.append(np.repeat(lc.load_gray(os.path.join(lc.ROOT, f["metalness"]))[..., None], 3, -1))
        for j, c in enumerate(cells):
            maps_sheet.paste(Image.fromarray(lc.to_u8(lc.resize(c, M - 4, M - 4))), (160 + j * M, y))
        lc.label(maps_sheet, (6, y + 4), r["variant"], size=12)
        lc.label(maps_sheet, (6, y + 24), r["source"][:22], size=10, fill=(190, 190, 190))
        lc.label(maps_sheet, (6, y + 42), "color %s" % (tuple(r["color"]),), size=10, fill=(190, 190, 190))
    maps_sheet.save(os.path.join(lc.EARLY_DIR, "materials_maps.png"))

    # decals over the asphalt preview and over a checker
    asphalt = next(r for r in recs if r["key"] == "asphalt")
    road = material_preview(asphalt, 1024)
    D = 260
    cols = 6
    rows = (len(decals) + cols - 1) // cols
    ds = Image.new("RGB", (cols * D, rows * (D + 20) + 30), (14, 14, 16))
    lc.label(ds, (8, 6), "Decal textures (over HC_Asphalt preview; markings are pre-coloured white/yellow paint)",
             size=14, fill=(255, 210, 120))
    for i, dcl in enumerate(decals):
        rgba = np.asarray(Image.open(os.path.join(lc.ROOT, dcl["file"])).convert("RGBA"), np.float32) / 255.0
        h, w = rgba.shape[:2]
        sc = (D - 10) / max(h, w)
        rw, rh = max(1, int(w * sc)), max(1, int(h * sc))
        small = lc.resize(rgba, rw, rh)
        bg = lc.resize(road, D - 10, D - 10)[:rh, :rw] if "wall" not in dcl["name"] else \
            np.full((rh, rw, 3), 0.8, np.float32)
        comp = lc.over(small, bg)
        x0, y0 = (i % cols) * D, 30 + (i // cols) * (D + 20)
        ds.paste(Image.fromarray(lc.to_u8(comp)), (x0 + 5 + (D - 10 - rw) // 2, y0 + 20 + (D - 10 - rh) // 2))
        lc.label(ds, (x0 + 4, y0 + 2), dcl["name"], size=11)
    ds.save(os.path.join(lc.EARLY_DIR, "decals_sheet.png"))
    print("sheets ->", lc.rel(lc.EARLY_DIR))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.environ.get("HC_CC0_TEX", os.path.expanduser("~/.cache/hotwire/cc0/tex")))
    ap.add_argument("--only", default="")
    ap.add_argument("--fetch", action="store_true")
    ap.add_argument("--no-sheets", action="store_true")
    ap.add_argument("--no-decals", action="store_true")
    global ARGS
    ARGS = ap.parse_args()
    only = set(filter(None, ARGS.only.split(",")))
    meta_path = os.path.join(lc.MATERIALS_DIR, "materials.json")
    prev = lc.read_json(meta_path, {}) or {}
    prev_by_key = {m["key"]: m for m in prev.get("materials", [])}
    done = {}
    recs = []
    for d in MATERIALS:
        if only and d["key"] not in only and d.get("shares") not in only:
            if d["key"] in prev_by_key:
                done[d["key"]] = prev_by_key[d["key"]]
                recs.append(prev_by_key[d["key"]])
                continue
        r = process(d, ARGS.src, done)
        done[d["key"]] = r
        recs.append(r)
    decals = prev.get("decals", [])
    if not ARGS.no_decals:
        decals = build_decals(ARGS.src)
    for r in recs:  # sha1 of every output so upload.py can skip unchanged images
        r["sha1"] = {k: lc.sha1(os.path.join(lc.ROOT, p)) for k, p in r["files"].items()}
    for dcl in decals:
        dcl["sha1"] = lc.sha1(os.path.join(lc.ROOT, dcl["file"]))
    lc.write_json(meta_path, {"materials": recs, "decals": decals,
                              "note": "generated by tools/look/prep_materials.py - do not edit"})
    if not ARGS.no_sheets:
        sheets(recs, decals)


ARGS = None

if __name__ == "__main__":
    main()
