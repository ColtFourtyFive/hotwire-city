#!/usr/bin/env python3
"""CC0 PBR texture sets -> Roblox MaterialVariant / SurfaceAppearance maps.

    python3 -I tools/blender/materials/prep_pbr.py                 # fetch + convert all + manifest + contact sheet
    python3 -I tools/blender/materials/prep_pbr.py --only brick_red,stucco
    python3 -I tools/blender/materials/prep_pbr.py --no-render     # maps + manifest only (no Blender)
    python3 -I tools/blender/materials/prep_pbr.py --sheet-only    # re-render the contact sheet from assets/materials

Per set this writes assets/materials/<name>/{color,normal,roughness,metalness}.png (1024 px, 8-bit) and
assets/materials/manifest.json (BaseMaterial, StudsPerTile, MaterialPattern, sources, checks), plus the contact sheet
docs/v2/proto/materials/sheet.png.

What "the convention Roblox expects" means here (create.roblox.com/docs/art/modeling/surface-appearance and
.../texture-specifications, fetched 2026-10-27):
  * NormalMap: tangent space, OpenGL (+Y / green up). We do not trust file names: every normal map is checked against
    the set's height map (green must correlate positively with dh/drow, i.e. "Y up"); a DirectX map is flipped.
  * ColorMap: 24-bit RGB (sRGB). AO is multiplied in (SurfaceAppearance/MaterialVariant have no AO slot).
  * RoughnessMap / MetalnessMap: 8-bit single channel, linear. Metalness is 0 or 1 in most texels.
  * <= 1024 px. MaterialVariant tiles by StudsPerTile (1 stud = 0.3 m for this project's scale), and the part's
    Color multiplies the ColorMap, so parts that use a variant should be white unless they want a tint.
  * Seamless: wrap-around seams are measured (edge step vs interior step) and fixed with an offset cross-fade if
    a set fails the check.
Sources: Poly Haven (api.polyhaven.com) and ambientCG (ambientcg.com), both CC0.
"""
import argparse
import io
import json
import math
import os
import shutil
import sys
import time
import urllib.request
import zipfile

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
CACHE = os.path.join(HERE, "_cache")
OUT = os.path.join(ROOT, "assets", "materials")
SHEET_DIR = os.path.join(ROOT, "docs", "v2", "proto", "materials")
M_PER_STUD = 0.3  # project scale: character 5.5 studs ~ 1.75 m, storey 12.5 studs ~ 3.75 m
SIZE = 1024
UA = {"User-Agent": "HotwireCity-materials/1.0"}

# name -> source spec.
#   src: ("ph", polyhaven_id) | ("acg", ambientcg_id)
#   base: Roblox BaseMaterial for the MaterialVariant (what physics/sounds/terrain fallback use)
#   spt: StudsPerTile override (default: real-world size / M_PER_STUD)
#   pattern: MaterialPattern (Organic hides repetition on natural / noisy sets; Regular keeps joints straight)
#   ao: how much of the AO map is multiplied into the ColorMap; metal: constant metalness when the set has no map
SETS = {
    "asphalt_clean": dict(src=("acg", "Asphalt025C"), base="Asphalt", spt=8, pattern="Organic", ao=0.4,
                          use="roads, parking lots (new surface)"),
    "asphalt_worn": dict(src=("acg", "Asphalt026C"), base="Asphalt", spt=10, pattern="Organic", ao=0.4,
                         use="older streets, alleys, industrial lots (cracks)"),
    "sidewalk_paving": dict(src=("ph", "concrete_pavement"), base="Pavement", pattern="Regular", ao=0.5,
                            use="LA-style scored concrete sidewalk slabs"),
    "curb_concrete": dict(src=("ph", "concrete_floor_01"), base="Concrete", spt=8, pattern="Organic", ao=0.4,
                          use="curbs, medians, plinths, barriers"),
    "brick_red": dict(src=("ph", "red_brick_03"), base="Brick", pattern="Regular", ao=0.6,
                      use="midtown walls, lofts, warehouses"),
    "brick_tan": dict(src=("ph", "yellow_brick"), base="Brick", pattern="Regular", ao=0.6,
                      use="older commercial facades"),
    "stucco": dict(src=("ph", "white_stucco_02"), base="Plaster", spt=8, pattern="Organic", ao=0.4,
                   use="houses, deco hotels; near-white so part Color tints it"),
    "roof_tiles": dict(src=("ph", "clay_roof_tiles_02"), base="Slate", pattern="Regular", ao=0.6,
                       use="Spanish / mission clay roofs"),
    "roof_gravel": dict(src=("ph", "gravel_floor_02"), base="Pebble", spt=7, pattern="Organic", ao=0.5,
                        use="flat roofs (ballast gravel)"),
    "metal_corrugated": dict(src=("ph", "corrugated_iron_02"), base="Metal", pattern="Regular", ao=0.5, metal=1.0,
                             use="sheds, warehouse siding, fences"),
    "metal_rusty": dict(src=("ph", "rusty_metal_04"), base="CorrodedMetal", spt=8, pattern="Organic", ao=0.4,
                        use="containers, port, scrap, industrial"),
    "wood_planks": dict(src=("ph", "wooden_planks"), base="WoodPlanks", pattern="Regular", ao=0.5,
                        use="pier / boardwalk decks, fences"),
    "grass": dict(src=("acg", "Grass004"), base="Grass", spt=8, pattern="Organic", ao=0.4,
                  use="lawns, parks, verges (or terrain Grass)"),
    "sand": dict(src=("acg", "Ground080"), base="Sand", spt=10, pattern="Organic", ao=0.4,
                 use="beach (or terrain Sand)"),
    "rock": dict(src=("ph", "rock_face"), base="Rock", pattern="Organic", ao=0.5,
                 use="hills, cliffs, rock outcrops (or terrain Rock)"),
    "terrazzo": dict(src=("acg", "Terrazzo013"), base="Marble", spt=6, pattern="Regular", ao=0.3,
                     use="lobbies, malls, plazas"),
}

PH_MAPS = {"color": "Diffuse", "nor_gl": "nor_gl", "nor_dx": "nor_dx", "rough": "Rough", "metal": "Metal",
           "ao": "AO", "disp": "Displacement"}
ACG_MAPS = {"color": "Color", "nor_gl": "NormalGL", "nor_dx": "NormalDX", "rough": "Roughness", "metal": "Metalness",
            "ao": "AmbientOcclusion", "disp": "Displacement"}


# ----------------------------------------------------------------------------------------------------- download
def _get(url, timeout=120):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def fetch(name, spec):
    """Download the source maps into _cache/<name>/ (idempotent). Returns {role: path} and source info."""
    kind, sid = spec["src"]
    d = os.path.join(CACHE, name)
    os.makedirs(d, exist_ok=True)
    info_p = os.path.join(d, "source.json")
    if os.path.exists(info_p):
        info = json.load(open(info_p))
        if info.get("id") == sid and all(os.path.exists(p) for p in info["files"].values()):
            return info
    files = {}
    if kind == "ph":
        meta = json.loads(_get(f"https://api.polyhaven.com/info/{sid}"))
        api = json.loads(_get(f"https://api.polyhaven.com/files/{sid}"))
        for role, key in PH_MAPS.items():
            ent = api.get(key, {}).get("1k", {}).get("png")
            if not ent:
                continue
            dst = os.path.join(d, f"{role}.png")
            if not os.path.exists(dst):
                open(dst, "wb").write(_get(ent["url"]))
            files[role] = dst
        dims = meta.get("dimensions")  # [w, h] in millimetres
        info = {"kind": "ph", "id": sid, "files": files, "dims_m": [x / 1000 for x in dims] if dims else None,
                "url": f"https://polyhaven.com/a/{sid}", "license": "CC0 (Poly Haven)"}
    else:
        blob = _get(f"https://ambientcg.com/get?file={sid}_1K-PNG.zip", timeout=300)
        zf = zipfile.ZipFile(io.BytesIO(blob))
        for member in zf.namelist():
            base = os.path.basename(member)  # never trust archive paths
            for role, key in ACG_MAPS.items():
                if base == f"{sid}_1K-PNG_{key}.png":
                    dst = os.path.join(d, f"{role}.png")
                    with zf.open(member) as src, open(dst, "wb") as out:
                        shutil.copyfileobj(src, out)
                    files[role] = dst
        info = {"kind": "acg", "id": sid, "files": files, "dims_m": None,
                "url": f"https://ambientcg.com/view?id={sid}", "license": "CC0 (ambientCG)"}
    json.dump(info, open(info_p, "w"), indent=1)
    return info


# ------------------------------------------------------------------------------------------------------ images
def load(path, mode):
    """float32 array in 0..1. mode 'RGB' -> HxWx3, 'L' -> HxW. Handles 8/16-bit PNGs."""
    im = Image.open(path)
    if im.mode in ("I;16", "I;16B", "I"):
        a = np.asarray(im, dtype=np.float32)
        a = a / (65535.0 if a.max() > 255 else 255.0)
        if mode == "RGB":
            a = np.repeat(a[..., None], 3, axis=2)
        return a
    if mode == "L" and im.mode not in ("L", "LA"):
        a = np.asarray(im.convert("RGB"), dtype=np.float32) / 255.0
        return a[..., 0]  # roughness/metal/ao/disp maps are grey; take R (avoids luminance weighting)
    return np.asarray(im.convert(mode), dtype=np.float32) / 255.0


def resize(a, n=SIZE):
    if a.shape[0] == n and a.shape[1] == n:
        return a
    if a.ndim == 2:
        return np.asarray(Image.fromarray(a.astype(np.float32), "F").resize((n, n), Image.LANCZOS), np.float32)
    return np.stack([resize(a[..., c], n) for c in range(a.shape[2])], axis=2)


def to8(a):
    return (np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8)


# ---------------------------------------------------------------------------------------------------- checks
def normal_convention(nrm, disp):
    """Correlate the normal map against the height map.
    OpenGL (+Y up): green - 0.5 ~ +dh/drow (rows grow downward). DirectX: the opposite sign.
    Red - 0.5 ~ -dh/dcol in both. Returns (verdict, r_green, r_red)."""
    h = disp.astype(np.float64)
    h = h - h.mean()
    # central differences with wrap (textures tile)
    dh_drow = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5
    dh_dcol = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5
    g = nrm[..., 1].astype(np.float64) - 0.5
    r = nrm[..., 0].astype(np.float64) - 0.5

    def corr(a, b):
        a = a - a.mean()
        b = b - b.mean()
        return float((a * b).sum() / math.sqrt((a * a).sum() * (b * b).sum() + 1e-12))

    rg = corr(g, dh_drow)
    rr = corr(r, -dh_dcol)
    verdict = "opengl" if rg > 0.05 else ("directx" if rg < -0.05 else "unknown")
    return verdict, rg, rr


def seam_score(a):
    """Wrap-around step / interior step (1.0 = as smooth as the interior). Uses luminance."""
    if a.ndim == 3:
        a = a @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    inner_x = np.abs(np.diff(a, axis=1)).mean()
    inner_y = np.abs(np.diff(a, axis=0)).mean()
    edge_x = np.abs(a[:, 0] - a[:, -1]).mean()
    edge_y = np.abs(a[0, :] - a[-1, :]).mean()
    return float(max(edge_x / (inner_x + 1e-6), edge_y / (inner_y + 1e-6)))


def make_seamless(maps, band=0.18):
    """Offset cross-fade: blend each map with itself rolled by half, weighted toward the rolled copy at the borders
    (where the rolled copy is continuous) and toward the original in the middle. Same weights for every map."""
    n = next(iter(maps.values())).shape[0]
    t = np.abs(np.linspace(-1, 1, n, dtype=np.float32))  # 0 center .. 1 border
    edge = np.clip((t - (1 - 2 * band)) / (2 * band), 0, 1)
    edge = edge * edge * (3 - 2 * edge)
    w = np.maximum(edge[None, :], edge[:, None])
    out = {}
    for k, a in maps.items():
        rolled = np.roll(np.roll(a, n // 2, 0), n // 2, 1)
        ww = w[..., None] if a.ndim == 3 else w
        out[k] = a * (1 - ww) + rolled * ww
    if "normal" in out:
        v = out["normal"] * 2 - 1
        v /= np.linalg.norm(v, axis=2, keepdims=True) + 1e-6
        out["normal"] = v * 0.5 + 0.5
    return out


# ------------------------------------------------------------------------------------------------------ convert
def convert(name, spec, info, force=False):
    dst = os.path.join(OUT, name)
    os.makedirs(dst, exist_ok=True)
    f = info["files"]
    color = resize(load(f["color"], "RGB"))
    # Normal: prefer the GL map, but verify against the height map either way.
    nsrc = "nor_gl" if "nor_gl" in f else "nor_dx"
    nrm = resize(load(f[nsrc], "RGB"))
    rough = resize(load(f["rough"], "L")) if "rough" in f else np.full((SIZE, SIZE), 0.8, np.float32)
    if "metal" in f:
        metal = resize(load(f["metal"], "L"))
    else:
        metal = np.full((SIZE, SIZE), float(spec.get("metal", 0.0)), np.float32)
    check = {"normal_source": f"{info['kind']}:{nsrc}"}
    if "disp" in f:
        disp = resize(load(f["disp"], "L"))
        verdict, rg, rr = normal_convention(nrm, disp)
        check.update(normal_detected=verdict, corr_green_vs_height=round(rg, 3), corr_red_vs_height=round(rr, 3))
        if verdict == "directx":
            nrm[..., 1] = 1.0 - nrm[..., 1]
            check["normal_flipped_green"] = True
        # sanity: the opposite file (if present) should test as the other convention
        other = "nor_dx" if nsrc == "nor_gl" else "nor_gl"
        if other in f:
            v2, rg2, _ = normal_convention(resize(load(f[other], "RGB")), disp)
            check["other_file"] = {"file": other, "detected": v2, "corr_green_vs_height": round(rg2, 3)}
    else:
        check["normal_detected"] = "unverified (no height map)"
    # renormalise (JPEG/8-bit drift) and keep z positive
    v = nrm * 2 - 1
    v[..., 2] = np.maximum(v[..., 2], 0.05)
    v /= np.linalg.norm(v, axis=2, keepdims=True) + 1e-6
    nrm = v * 0.5 + 0.5
    if "ao" in f and spec.get("ao", 0) > 0:
        ao = resize(load(f["ao"], "L"))
        k = float(spec["ao"])
        color = color * (1 - k + k * ao)[..., None]
        check["ao_baked"] = k
    maps = {"color": color, "normal": nrm, "roughness": rough, "metalness": metal}
    s0 = {k: round(seam_score(a), 2) for k, a in maps.items() if k != "metalness"}
    check["seam_before"] = s0
    if max(s0.values()) > 1.6:
        maps = make_seamless(maps)
        check["seam_fixed"] = True
        check["seam_after"] = {k: round(seam_score(a), 2) for k, a in maps.items() if k != "metalness"}
    Image.fromarray(to8(maps["color"]), "RGB").save(os.path.join(dst, "color.png"), optimize=True)
    Image.fromarray(to8(maps["normal"]), "RGB").save(os.path.join(dst, "normal.png"), optimize=True)
    Image.fromarray(to8(maps["roughness"]), "L").save(os.path.join(dst, "roughness.png"), optimize=True)
    Image.fromarray(to8(maps["metalness"]), "L").save(os.path.join(dst, "metalness.png"), optimize=True)
    # stats the importer / Look tuning can use
    lin = np.where(color <= 0.04045, color / 12.92, ((color + 0.055) / 1.055) ** 2.4)
    mean_lin = lin.reshape(-1, 3).mean(0)
    mean_srgb = [round(float(x), 3) for x in color.reshape(-1, 3).mean(0)]
    if spec.get("spt"):
        spt = float(spec["spt"])
    elif info.get("dims_m"):
        spt = round(info["dims_m"][0] / M_PER_STUD, 1)
    else:
        spt = 8.0
    entry = {
        "name": name,
        "files": {k: f"assets/materials/{name}/{k}.png" for k in ("color", "normal", "roughness", "metalness")},
        "size": SIZE,
        "materialVariant": {"Name": "HC_" + "".join(p.capitalize() for p in name.split("_")), "BaseMaterial": spec["base"],
                            "StudsPerTile": spt, "MaterialPattern": spec["pattern"]},
        "use": spec.get("use", ""),
        "realWorldTileMeters": info.get("dims_m"),
        "meanColorSRGB": mean_srgb,
        "meanAlbedoLinear": [round(float(x), 4) for x in mean_lin],
        "meanRoughness": round(float(maps["roughness"].mean()), 3),
        "meanMetalness": round(float(maps["metalness"].mean()), 3),
        "source": info["url"], "license": info["license"],
        "checks": check,
    }
    with open(os.path.join(dst, "SOURCE.txt"), "w") as fh:
        fh.write(f"{info['license']}: {info['url']}\nConverted by tools/blender/materials/prep_pbr.py\n")
    return entry


# ------------------------------------------------------------------------------------------------- contact sheet
def render_swatches(entries, size=360, samples=32):
    """Lit Blender preview per set: a 3x3-tile floor at true StudsPerTile scale, a cube and a 5.5-stud figure for
    scale, under a low warm sun so the normal maps read. Shaded only with the four Roblox channels."""
    import bpy  # Blender as a Python module
    from mathutils import Vector

    sys.path.insert(0, os.path.join(HERE, "..", "buildkit"))
    out = {}
    hdri = os.path.join(HERE, "..", "buildkit", "_cache", "hdri", "sky_late_afternoon_nosun.exr")
    for e in entries:
        bpy.ops.wm.read_factory_settings(use_empty=True)
        s = bpy.context.scene
        s.render.engine = "CYCLES"
        s.cycles.device = "CPU"
        s.cycles.samples = samples
        s.cycles.use_denoising = True
        s.render.resolution_x = s.render.resolution_y = size
        s.view_settings.view_transform = "AgX"
        try:
            s.view_settings.look = "AgX - Medium High Contrast"
        except Exception:
            pass
        s.view_settings.exposure = -0.4
        w = bpy.data.worlds.new("W")
        s.world = w
        w.use_nodes = True
        nt = w.node_tree
        bg = nt.nodes["Background"]
        if os.path.exists(hdri):
            env = nt.nodes.new("ShaderNodeTexEnvironment")
            env.image = bpy.data.images.load(hdri, check_existing=True)
            nt.links.new(env.outputs[0], bg.inputs[0])
            bg.inputs[1].default_value = 1.6
        else:
            bg.inputs[0].default_value = (0.5, 0.6, 0.75, 1)
        sun = bpy.data.lights.new("Sun", "SUN")
        sun.energy = 4.5
        sun.color = (1.0, 0.9, 0.78)
        sun.angle = math.radians(0.8)
        so = bpy.data.objects.new("Sun", sun)
        s.collection.objects.link(so)
        so.rotation_euler = (math.radians(62), 0, math.radians(-35))
        spt = e["materialVariant"]["StudsPerTile"]
        # material
        m = bpy.data.materials.new(e["name"])
        m.use_nodes = True
        mt = m.node_tree
        bsdf = mt.nodes["Principled BSDF"]
        tc = mt.nodes.new("ShaderNodeTexCoord")
        mp = mt.nodes.new("ShaderNodeMapping")
        mp.inputs["Scale"].default_value = (1 / spt, 1 / spt, 1 / spt)
        mt.links.new(tc.outputs["Object"], mp.inputs[0])

        def tex(role, data):
            t = mt.nodes.new("ShaderNodeTexImage")
            t.image = bpy.data.images.load(os.path.join(ROOT, e["files"][role]), check_existing=True)
            if data:
                t.image.colorspace_settings.name = "Non-Color"
            t.projection = "BOX"
            t.projection_blend = 0.15
            mt.links.new(mp.outputs[0], t.inputs[0])
            return t
        mt.links.new(tex("color", False).outputs[0], bsdf.inputs["Base Color"])
        mt.links.new(tex("roughness", True).outputs[0], bsdf.inputs["Roughness"])
        mt.links.new(tex("metalness", True).outputs[0], bsdf.inputs["Metallic"])
        nm = mt.nodes.new("ShaderNodeNormalMap")
        mt.links.new(tex("normal", True).outputs[0], nm.inputs["Color"])
        mt.links.new(nm.outputs[0], bsdf.inputs["Normal"])
        # floor: 3x3 tiles, cube, figure
        L = 3 * spt
        bpy.ops.mesh.primitive_plane_add(size=L, location=(0, 0, 0))
        fl = bpy.context.object
        fl.data.materials.append(m)
        c = max(4.0, spt * 0.55)
        bpy.ops.mesh.primitive_cube_add(size=c, location=(L * 0.12, L * 0.1, c / 2))
        cb = bpy.context.object
        cb.rotation_euler = (0, 0, math.radians(28))
        cb.data.materials.append(m)
        mod = cb.modifiers.new("b", "BEVEL")
        mod.width = c * 0.03
        mod.segments = 2
        # Object coords for box mapping need world-consistent scale: apply transforms
        for ob in (fl, cb):
            ob.select_set(True)
        bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
        fig_m = bpy.data.materials.new("fig")
        fig_m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.05, 0.05, 0.06, 1)
        bpy.ops.mesh.primitive_cylinder_add(radius=0.75, depth=5.5, location=(-L * 0.18, L * 0.02, 2.75))
        bpy.context.object.data.materials.append(fig_m)
        cam_d = bpy.data.cameras.new("C")
        cam_d.lens = 35
        cam = bpy.data.objects.new("C", cam_d)
        s.collection.objects.link(cam)
        s.camera = cam
        cam.location = Vector((-L * 0.62, -L * 0.78, L * 0.55))
        d = Vector((0, L * 0.06, 0)) - cam.location
        cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
        p = os.path.join(CACHE, "_swatch", f"{e['name']}.png")
        os.makedirs(os.path.dirname(p), exist_ok=True)
        s.render.filepath = p
        t0 = time.time()
        bpy.ops.render.render(write_still=True)
        print(f"  swatch {e['name']} {time.time() - t0:.1f}s")
        out[e["name"]] = p
    return out


def font(sz):
    for p in ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/dejavu/DejaVuSans.ttf"):
        if os.path.exists(p):
            return ImageFont.truetype(p, sz)
    return ImageFont.load_default()


def contact_sheet(entries, swatches, path):
    R, T = 300, 150  # lit render size, map thumb size
    bw, bh = R + 2 * T + 12, R + 46
    cols = 3
    rows = (len(entries) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * bw + 12, rows * bh + 56), (18, 19, 22))
    d = ImageDraw.Draw(sheet)
    d.text((14, 12), "Hotwire City CC0 PBR starter set -> Roblox MaterialVariant maps (1024 px, OpenGL normals)",
           fill=(235, 235, 235), font=font(20))
    f1, f2 = font(15), font(12)
    for i, e in enumerate(entries):
        x0 = 12 + (i % cols) * bw
        y0 = 50 + (i // cols) * bh
        if e["name"] in swatches and os.path.exists(swatches[e["name"]]):
            sheet.paste(Image.open(swatches[e["name"]]).convert("RGB").resize((R, R), Image.LANCZOS), (x0, y0 + 36))
        for j, role in enumerate(("color", "normal", "roughness", "metalness")):
            im = Image.open(os.path.join(ROOT, e["files"][role])).convert("RGB").resize((T, T), Image.LANCZOS)
            sheet.paste(im, (x0 + R + 4 + (j % 2) * (T + 2), y0 + 36 + (j // 2) * (T + 2)))
        mv = e["materialVariant"]
        ck = e["checks"]
        d.text((x0, y0 + 2), f"{e['name']}  ({mv['BaseMaterial']}, {mv['StudsPerTile']:g} studs/tile, {mv['MaterialPattern']})",
               fill=(240, 240, 240), font=f1)
        nv = ck.get("normal_detected", "?")
        rg = ck.get("corr_green_vs_height")
        seam = "fixed" if ck.get("seam_fixed") else f"ok {max(ck['seam_before'].values()):.2f}"
        src = e["source"].split("/")[-1].replace("view?id=", "")
        d.text((x0, y0 + 20), f"normal: {nv}{f' (r={rg:+.2f})' if rg is not None else ''}  seam: {seam}  src: {src}",
               fill=(150, 200, 150) if nv == "opengl" else (230, 180, 120), font=f2)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sheet.save(path, optimize=True)
    print("wrote", path, sheet.size)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only")
    ap.add_argument("--no-render", action="store_true")
    ap.add_argument("--sheet-only", action="store_true")
    ap.add_argument("--samples", type=int, default=32)
    args = ap.parse_args()
    names = args.only.split(",") if args.only else list(SETS)
    man_p = os.path.join(OUT, "manifest.json")
    manifest = json.load(open(man_p)) if os.path.exists(man_p) else {}
    manifest.pop("_about", None)
    if not args.sheet_only:
        for n in names:
            t0 = time.time()
            info = fetch(n, SETS[n])
            e = convert(n, SETS[n], info)
            manifest[n] = e
            ck = e["checks"]
            print(f"{n:18s} {time.time() - t0:5.1f}s normal={ck.get('normal_detected')} r_g={ck.get('corr_green_vs_height')} "
                  f"seam={ck['seam_before']}{' FIXED' if ck.get('seam_fixed') else ''} spt={e['materialVariant']['StudsPerTile']}")
        ordered = {k: manifest[k] for k in SETS if k in manifest}
        about = ("CC0 PBR sets converted for Roblox MaterialVariant / SurfaceAppearance by "
                 "tools/blender/materials/prep_pbr.py. Normal maps are OpenGL (+Y), verified against height maps. "
                 "ColorMap has AO baked in. Part Color multiplies the ColorMap: use white parts for true colour.")
        json.dump({"_about": about, **ordered}, open(man_p, "w"), indent=1)
        manifest = ordered
    entries = [manifest[k] for k in SETS if k in manifest]
    swatches = {}
    if not args.no_render:
        swatches = render_swatches(entries, samples=args.samples)
    else:
        sd = os.path.join(CACHE, "_swatch")
        swatches = {e["name"]: os.path.join(sd, e["name"] + ".png") for e in entries}
    contact_sheet(entries, swatches, os.path.join(SHEET_DIR, "sheet.png"))


if __name__ == "__main__":
    main()
