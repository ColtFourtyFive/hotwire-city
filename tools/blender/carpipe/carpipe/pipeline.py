"""End-to-end: any car model file -> Roblox-ready GLB (named MeshPart objects) + JSON sidecar + texture PNGs."""
from __future__ import annotations

import json
import math
import os

import bpy
import numpy as np

from . import analyze, bake, importer, optimize
from .analyze import INTERIOR, KW_SEAT, TRIM, WHEEL0
from .util import ensure_dir, fmt3, kw_match, log, reset_scene, select_only, srgb_to_lin, tri_count, verts_np

DEFAULTS = {
    "length": 17.0,          # studs, bumper to bumper
    "tex_body": 1024, "tex_trim": 1024, "tex_interior": 512, "tex_wheel": 512, "tex_lights": 256,
    "glass_tint": [0.06, 0.08, 0.09], "glass_alpha": 0.45,
    "body_maps": True,       # also write Body normal/AO PNGs for an optional SurfaceAppearance
    "budget": {},            # per-object overrides of optimize.BUDGET
    "bake": True,
}


def rbx(v):
    """Blender canonical (x right, y forward, z up) -> Roblox/glTF (x right, y up, -z forward)."""
    return [round(float(v[0]), 4), round(float(v[2]), 4), round(float(-v[1]), 4)]


def run(model_path: str, out_dir: str, name: str, cfg: dict | None = None) -> dict:
    cfg = {**DEFAULTS, **(cfg or {})}
    budget = {**optimize.BUDGET, **cfg.get("budget", {})}
    ensure_dir(out_dir)
    tex_dir = ensure_dir(os.path.join(out_dir, "textures"))
    reset_scene()
    importer.import_any(model_path, cfg)
    objs = importer.flatten(subsurf_cap=cfg.get("subsurf_cap", 1))
    mdir = os.path.dirname(os.path.abspath(model_path))
    for d in {mdir, os.path.dirname(mdir)}:
        importer.discover_textures(d, cfg.get("textures"))
    car = analyze.Car(cfg)
    car.build(objs)
    tris_in = int(sum(car.lt - 2))
    car.orient()
    car.find_wheels()
    car.unsteer_wheels()
    car.ground_and_scale(float(cfg["length"]))
    car.classify()
    car.debug_dump(os.path.join(out_dir, "islands_debug.txt"))
    seats = _seats(car)
    exhausts = _exhausts(car)
    lo_b, hi_b = car.bbox()
    L, W, H = (hi_b - lo_b)

    his = optimize.split_roles(car)
    bpy.data.objects.remove(car.obj, do_unlink=True)
    wheel_names = [w["name"] for w in getattr(car, "wheels", [])]

    # ---------------------------------------------------------------- low-poly versions
    lows = {}
    for nm, hi in his.items():
        b = budget["Wheel"] if nm in wheel_names else budget.get(nm, 2000)
        lows[nm] = optimize.make_low(hi, nm, b, L, symmetric=nm in ("Body", "Body2", "Glass"))
    total = sum(tri_count(o) for o in lows.values())
    if total > optimize.CAR_BUDGET:  # squeeze trim/interior first
        over = total - optimize.CAR_BUDGET
        for nm in ("Interior", "Trim", "Body"):
            if nm in lows and over > 0:
                t = tri_count(lows[nm])
                newt = max(int(t * 0.5), t - over - 50)
                optimize.decimate(lows[nm], newt)
                over -= t - tri_count(lows[nm])
        total = sum(tri_count(o) for o in lows.values())
    log(f"total tris {tris_in} -> {total}")

    # ---------------------------------------------------------------- UV atlases + bakes
    ext = 0.006 * L
    ray = 0.03 * L
    textures = {}
    paint = dict(getattr(car, "paint", {}) or {})
    route = "strip"
    groups = []
    if "Body" in lows:
        groups.append(("Body", ["Body"], cfg["tex_body"]))
    if "Body2" in lows:
        groups.append(("Body2", ["Body2"], cfg["tex_body"] // 2))
    if "Trim" in lows:
        groups.append(("Trim", ["Trim"], cfg["tex_trim"]))
    if "Interior" in lows:
        groups.append(("Interior", ["Interior"], cfg["tex_interior"]))
    lights = [n for n in ("LightsFront", "LightsRear") if n in lows]
    if lights:
        groups.append(("Lights", lights, cfg["tex_lights"]))
    if wheel_names:
        groups.append(("Wheel", [n for n in wheel_names if n in lows], cfg["tex_wheel"]))
    for gname, members, size in groups:
        objs = [lows[m] for m in members]
        optimize.atlas_uv(objs, margin=0.006 if size >= 512 else 0.012)
    if cfg["bake"]:
        for gname, members, size in groups:
            if gname == "Body":
                textured_paint = bool(paint.get("textured"))
            elif gname == "Body2":
                textured_paint = bool((getattr(car, "paint2", None) or {}).get("textured"))
            else:
                textured_paint = False
            if gname in ("Body", "Body2") and not textured_paint:
                chans = ["normal"] if cfg["body_maps"] else []
            elif gname == "Lights":
                chans = ["base", "emit", "normal"]
            else:
                chans = ["base", "rough", "metal", "normal"]
            res = {}
            for m in members:
                # each member bakes into the shared image: bake one member at a time, then composite by UV coverage
                lo = lows[m]
                hi = his[m]
                r = bake.bake_channels(lo, [hi], size, tex_dir, f"{name}_{m}", chans, ext, ray) if chans else {}
                res[m] = r
            merged = _merge_member_bakes(res, tex_dir, f"{name}_{gname}", members, lows, size)
            if gname in ("Trim", "Interior", "Wheel") and "base" in merged:
                aos = []
                for m in members:
                    aos.append(bake.bake_ao(lows[m], size, tex_dir, f"{name}_{m}", distance=0.04 * L,
                                            hide=list(his.values())))
                ao = _merge_paths(aos, members, lows, size, os.path.join(tex_dir, f"{name}_{gname}_ao.png"), data=True)
                bake.multiply_ao(merged["base"], ao, strength=0.75 if gname == "Interior" else 0.6)
                merged["ao"] = ao
            if gname == "Body" and cfg["body_maps"] and not paint.get("textured"):
                ao = bake.bake_ao(lows["Body"], size, tex_dir, f"{name}_Body", distance=0.05 * L,
                                  hide=list(his.values()))
                merged["ao"] = ao
            if gname == "Body" and paint.get("textured") and "base" in merged:
                route = "tintmask"
                uvm = _uv_coverage(lows["Body"], size)
                pc, cov = bake.tint_mask(merged["base"], os.path.join(tex_dir, f"{name}_Body_tintmask.png"),
                                         os.path.join(tex_dir, f"{name}_Body_overlay.png"), uv_mask=uvm)
                paint["color_srgb"] = [round(c, 4) for c in pc]
                paint["mask_coverage"] = round(cov, 3)
                merged["tintmask"] = os.path.join(tex_dir, f"{name}_Body_tintmask.png")
                merged["overlay"] = os.path.join(tex_dir, f"{name}_Body_overlay.png")
            textures[gname] = merged

    # ---------------------------------------------------------------- final materials
    for nm, lo in lows.items():
        optimize.keep_only_uv(lo, "atlas")
        gname = "Wheel" if nm in wheel_names else ("Lights" if nm in ("LightsFront", "LightsRear") else nm)
        _final_material(lo, nm, gname, textures.get(gname, {}), car, cfg, route)
    # wheel origins at the axle centre
    wheel_info = {}
    for w in getattr(car, "wheels", []):
        lo = lows.get(w["name"])
        if lo is None:
            continue
        c = np.array(w["center"])
        lo.data.transform(_translate(-c))
        lo.location = c.tolist()
        v = verts_np(lo.data)
        bbc = (v.min(0) + v.max(0)) / 2 + c
        wheel_info[w["name"].replace("Wheel", "")] = {
            "object": w["name"], "center": rbx(c), "radius": round(w["radius"], 4), "width": round(w["width"], 4),
            "part_center": rbx(bbc), "attachment_offset": rbx(c - bbc), "axle": [1, 0, 0],
            "steer": w["name"].startswith("WheelF"), "tris": tri_count(lo)}
    # remove high-res sources
    for hi in his.values():
        bpy.data.objects.remove(hi, do_unlink=True)
    for o in list(bpy.context.scene.objects):
        if o.name not in lows:
            bpy.data.objects.remove(o, do_unlink=True)

    glb = os.path.join(out_dir, f"{name}.glb")
    export_glb(glb)

    # ---------------------------------------------------------------- sidecar
    lights_info = _lights(lows, L, W, H)
    objects = {}
    for nm, lo in lows.items():
        v = verts_np(lo.data) + np.array(lo.location)
        objects[nm] = {"tris": tri_count(lo), "bbox_min": rbx([v[:, 0].min(), v[:, 1].max(), v[:, 2].min()]),
                       "bbox_max": rbx([v[:, 0].max(), v[:, 1].min(), v[:, 2].max()]),
                       "textures": {k: os.path.relpath(p, out_dir) for k, p in textures.get(
                           "Wheel" if nm in wheel_names else ("Lights" if nm.startswith("Lights") else nm), {}).items()}}
    wheels_sorted = sorted(getattr(car, "wheels", []), key=lambda w: -w["center"][1])
    wb = (wheels_sorted[0]["center"][1] - wheels_sorted[-1]["center"][1]) if len(wheels_sorted) >= 2 else None
    fw = [w for w in wheels_sorted if w["name"].startswith("WheelF")]
    rw = [w for w in wheels_sorted if w["name"].startswith("WheelR")]
    side = {
        "name": name,
        "generator": "HotwireCity tools/blender/carpipe",
        "source": cfg.get("source", {"file": os.path.basename(model_path)}),
        "units": "studs",
        "coordinates": "Roblox/glTF: +X = car right, +Y = up, -Z = forward (front of the car). "
                       "Origin: ground plane, centred between the wheel contact patches.",
        "glb": os.path.basename(glb),
        "dimensions": {"length": round(float(L), 3), "width": round(float(W), 3), "height": round(float(H), 3),
                       "wheelbase": round(float(wb), 3) if wb else None,
                       "track_front": round(float(abs(fw[0]["center"][0] - fw[-1]["center"][0])), 3) if len(fw) >= 2 else None,
                       "track_rear": round(float(abs(rw[0]["center"][0] - rw[-1]["center"][0])), 3) if len(rw) >= 2 else None,
                       "bbox_min": rbx([lo_b[0], hi_b[1], lo_b[2]]), "bbox_max": rbx([hi_b[0], lo_b[1], hi_b[2]])},
        "wheels": wheel_info,
        "seats": seats,
        "lights": lights_info,
        "exhausts": exhausts,
        "center_of_mass_hint": rbx([0.0, (wheels_sorted[0]["center"][1] + wheels_sorted[-1]["center"][1]) / 2
                                    if wheels_sorted else 0.0, 0.32 * H]),
        "paint": {"route": route, "primary": {"object": "Body", **paint},
                  "secondary": ({"object": "Body2", **car.paint2} if getattr(car, "paint2", None) and "Body2" in lows else None),
                  "how_to_recolor": (
                      "strip: Body has no texture -> set MeshPart.Color (and Material=SmoothPlastic/Metal). "
                      "Optional SurfaceAppearance: ColorMap=Body_ao (grey), NormalMap=Body_normal, AlphaMode=TintMask, "
                      "then script SurfaceAppearance.Color."
                      if route == "strip" else
                      "tintmask: SurfaceAppearance ColorMap=Body_tintmask.png with AlphaMode=TintMask and script "
                      "SurfaceAppearance.Color; or MeshPart.TextureID=Body_overlay.png (paint is transparent) and set "
                      "MeshPart.Color.")},
        "objects": objects,
        "triangles": {"source": tris_in, "total": int(sum(tri_count(o) for o in lows.values())),
                      "limits": {"car": optimize.CAR_BUDGET, "body": budget["Body"], "meshpart": 20000}},
        "orientation": car.report.get("orientation"),
        "scale": car.report.get("scale"),
        "classes": car.report.get("classes"),
        "warnings": car.warnings,
    }
    with open(os.path.join(out_dir, f"{name}.json"), "w") as f:
        json.dump(side, f, indent=2)
    if cfg.get("save_blend"):
        bpy.ops.wm.save_as_mainfile(filepath=os.path.join(out_dir, f"{name}.blend"))
    log(f"wrote {glb} ({side['triangles']['total']} tris) warnings={car.warnings}")
    return side


# ------------------------------------------------------------------------------------------- helpers
def _translate(v):
    from mathutils import Matrix, Vector
    return Matrix.Translation(Vector(v))


def _uv_coverage(lo, size, dilate=False):
    """Boolean (size,size) mask of texels covered by the atlas UV islands (rasterised triangles)."""
    from PIL import Image, ImageDraw
    me = lo.data
    uv = np.empty(len(me.loops) * 2)
    me.uv_layers["atlas"].data.foreach_get("uv", uv)
    uv = uv.reshape(-1, 2)
    im = Image.new("L", (size, size), 0)
    dr = ImageDraw.Draw(im)
    for p in me.polygons:
        pts = [(uv[li, 0] * size, (1 - uv[li, 1]) * size) for li in p.loop_indices]
        dr.polygon(pts, fill=255)
    m = np.asarray(im) > 0  # PNG orientation (row 0 = v 1), same as bake.load_np
    if dilate:
        d = m.copy()
        d[1:, :] |= m[:-1, :]
        d[:-1, :] |= m[1:, :]
        d[:, 1:] |= m[:, :-1]
        d[:, :-1] |= m[:, 1:]
        m = d
    return m


def _merge_member_bakes(res, tex_dir, prefix, members, lows, size):
    """Several objects share one atlas image: composite their individual bakes by each one's UV coverage."""
    if not res or not any(res.values()):
        return {}
    chans = set()
    for r in res.values():
        chans |= set(r)
    out = {}
    for ch in chans:
        paths = [res[m].get(ch) for m in members]
        out[ch] = _merge_paths(paths, members, lows, size, os.path.join(tex_dir, f"{prefix}_{ch}.png"))
    return out


def _merge_paths(paths, members, lows, size, out_path, data=False):
    if len(members) == 1:
        if paths[0] and paths[0] != out_path:
            os.replace(paths[0], out_path)
        return out_path
    acc = None
    for p, m in zip(paths, members):
        if p is None:
            continue
        a = bake.load_np(p)
        cov = _uv_coverage(lows[m], size, dilate=True)
        if acc is None:
            acc = a.copy()
        else:
            acc[cov] = a[cov]
        os.remove(p)
    bake.save_np(acc, out_path)
    return out_path


def _final_material(lo, nm, gname, tex, car, cfg, route):
    mat = bpy.data.materials.new(nm)
    mat.use_nodes = True
    nt = mat.node_tree
    b = nt.nodes.get("Principled BSDF")
    lo.data.materials.clear()
    lo.data.materials.append(mat)

    def img_node(path, data=False):
        n = nt.nodes.new("ShaderNodeTexImage")
        n.image = bpy.data.images.load(path, check_existing=True)
        n.image.colorspace_settings.name = "Non-Color" if data else "sRGB"
        return n

    if gname == "Glass":
        t = cfg["glass_tint"]
        b.inputs["Base Color"].default_value = tuple(srgb_to_lin(t)) + (1,)
        b.inputs["Roughness"].default_value = 0.05
        b.inputs["Metallic"].default_value = 0.0
        b.inputs["Alpha"].default_value = cfg["glass_alpha"]
        mat.surface_render_method = "BLENDED"
        try:
            mat.blend_method = "BLEND"
        except Exception:
            pass
        return
    if (gname == "Body" and route == "strip") or gname == "Body2":
        p = (car.paint if gname == "Body" else (car.paint2 or car.paint))
        b.inputs["Base Color"].default_value = tuple(srgb_to_lin(p["color_srgb"])) + (1,)
        b.inputs["Metallic"].default_value = 0.0
        b.inputs["Roughness"].default_value = 0.25
        try:
            b.inputs["Coat Weight"].default_value = 1.0
        except KeyError:
            pass
        return
    if "base" in tex:
        n = img_node(tex["base"])
        nt.links.new(n.outputs["Color"], b.inputs["Base Color"])
        if gname == "Lights":
            if "emit" in tex:
                e = img_node(tex["emit"])
                nt.links.new(e.outputs["Color"], b.inputs["Emission Color"])
            else:
                nt.links.new(n.outputs["Color"], b.inputs["Emission Color"])
            b.inputs["Emission Strength"].default_value = 1.0
    if "rough" in tex:
        n = img_node(tex["rough"], True)
        nt.links.new(n.outputs["Color"], b.inputs["Roughness"])
    if "metal" in tex:
        n = img_node(tex["metal"], True)
        nt.links.new(n.outputs["Color"], b.inputs["Metallic"])
    if "normal" in tex:
        n = img_node(tex["normal"], True)
        nm_ = nt.nodes.new("ShaderNodeNormalMap")
        nm_.uv_map = "UVMap"
        nt.links.new(n.outputs["Color"], nm_.inputs["Color"])
        nt.links.new(nm_.outputs["Normal"], b.inputs["Normal"])


def export_glb(path):
    kw = dict(filepath=path, export_format="GLB", use_selection=False, export_yup=True, export_apply=True,
              export_texcoords=True, export_normals=True, export_tangents=False, export_materials="EXPORT",
              export_cameras=False, export_lights=False, export_animations=False, export_extras=False,
              export_image_format="AUTO")
    try:
        bpy.ops.export_scene.gltf(**kw)
    except TypeError:
        kw.pop("export_lights", None)
        bpy.ops.export_scene.gltf(**kw)
    log("exported", path, f"{os.path.getsize(path) / 1e6:.2f} MB")


def _seats(car):
    lo, hi = car.bbox()
    L, W, H = hi - lo
    isl = [i for i in range(car.n_isl) if car.irole[i] == INTERIOR and kw_match(car.island_name(i), KW_SEAT)]
    out = {}
    if isl:
        cs = np.array([(car.imin[i] + car.imax[i]) / 2 for i in isl])
        mn = np.array([car.imin[i] for i in isl])
        mx = np.array([car.imax[i] for i in isl])
        a = car.ia[isl]
        # seats that span both sides (bench objects) -> split later with the fallback
        single = (mx[:, 0] - mn[:, 0]) < 0.45 * W
        if single.sum() >= 1:
            cs, mn, mx, a = cs[single], mn[single], mx[single], a[single]
            front_y = cs[:, 1].max()
            fr = cs[:, 1] > front_y - 0.12 * L
            for lab, sgn in (("driver", -1), ("passenger", 1)):
                sel = fr & (np.sign(cs[:, 0]) == sgn)
                if sel.any():
                    zmin, zmax = mn[sel, 2].min(), mx[sel, 2].max()
                    c = [float(np.average(cs[sel, 0], weights=a[sel])), float(np.average(cs[sel, 1], weights=a[sel])),
                         float(zmin + 0.38 * (zmax - zmin))]
                    out[lab] = {"position": rbx(c), "estimated": False}
    ws = getattr(car, "wheels", [])
    if ws:
        yr = min(w["center"][1] for w in ws)
        yf = max(w["center"][1] for w in ws)
    else:
        yr, yf = lo[1] + 0.2 * L, hi[1] - 0.2 * L
    for lab, sgn in (("driver", -1), ("passenger", 1)):
        if lab not in out:
            c = [sgn * 0.19 * W, yr + 0.42 * (yf - yr), 0.36 * H]
            out[lab] = {"position": rbx(c), "estimated": True}
    out["note"] = "left-hand drive assumed (driver on -X). Position = hip point; put the VehicleSeat just below it."
    return out


def _exhausts(car):
    lo, hi = car.bbox()
    L, W, H = hi - lo
    isl = [i for i in range(car.n_isl) if car.irole[i] in (TRIM,) and
           kw_match(car.island_name(i), [r"exhaust", r"muffler", r"tail_?pipe"]) and car.ic[i, 1] < 0]
    pts = []
    if isl:
        for i in isl:
            c = (car.imin[i] + car.imax[i]) / 2
            c[1] = car.imin[i][1]
            pts.append({"position": rbx(c), "estimated": False})
    else:
        pts.append({"position": rbx([-0.3 * W, lo[1] + 0.01 * L, 0.12 * H]), "estimated": True})
    return pts[:4]


def _lights(lows, L, W, H):
    out = {}
    for key, nm, sgn in (("front", "LightsFront", 1), ("rear", "LightsRear", -1)):
        lo = lows.get(nm)
        items = []
        if lo is not None and len(lo.data.vertices):
            v = verts_np(lo.data)
            for side in (-1, 1):
                s = v[np.sign(v[:, 0]) == side]
                if len(s):
                    c = s.mean(0)
                    c[1] = s[:, 1].max() if sgn > 0 else s[:, 1].min()
                    items.append({"position": rbx(c), "direction": [0, 0, -sgn], "estimated": False})
        if not items:
            for side in (-1, 1):
                c = [side * 0.36 * W, sgn * 0.49 * L, (0.42 if sgn > 0 else 0.52) * H]
                items.append({"position": rbx(c), "direction": [0, 0, -sgn], "estimated": True})
        out[key] = items
    return out
