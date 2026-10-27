#!/usr/bin/env python3
"""QA + evidence renders for the Vehicles v2 roster (assets/vehicles/<id>/<id>.glb + sidecar + roster.json).

    python3 -I tools/blender/carpipe/render_roster.py look nami wren      # studio 3/4 shot, runtime look
    python3 -I tools/blender/carpipe/render_roster.py roles nami          # object roles (QA)
    python3 -I tools/blender/carpipe/render_roster.py sheet               # docs/v2/early/vehicles/roster.png
    python3 -I tools/blender/carpipe/render_roster.py street --rig assets/vehicles/_rig/rig.json [--night]

The "look" emulates what the game sets at runtime (CarBuilder v2 / Config/Vehicles): Body = untextured MeshPart whose
Color is the paint, with the overlay PNG (paint pixels transparent) as TextureID on tint-mask cars and the full
livery PNG on livery cars; Glass = Roblox Glass at 0.4 transparency; SirenRed/SirenBlue = Neon; Lights / Sign =
their base TextureID; Trim / Interior / Wheels = the GLB's own PBR set (the importer's SurfaceAppearance).
"street" places every part from the CarBuilder rig dump (lune run tools/blender/carpipe/rig_dump.luau): the rig's own
part CFrames (wheel welds, ride height, chassis) drive the render, so it shows the rig, not just the GLB.
Cycles CPU, OIDN, <= 48 samples; previews <= 960x540.
"""
import argparse
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
VEH = os.path.join(REPO, "assets", "vehicles")
QA = os.path.join(VEH, "_qa")
EARLY = os.path.join(REPO, "docs", "v2", "early", "vehicles")

import bpy  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402

from carpipe import render as R, util  # noqa: E402
from carpipe.util import srgb_to_lin  # noqa: E402


def roster():
    r = json.load(open(os.path.join(HERE, "roster.json")))
    return {k: v for k, v in r.items() if not k.startswith("_")}


def sidecar(vid):
    return json.load(open(os.path.join(VEH, vid, vid + ".json")))


def _img(nt, path, data=False):
    n = nt.nodes.new("ShaderNodeTexImage")
    n.image = bpy.data.images.load(path, check_existing=True)
    n.image.colorspace_settings.name = "Non-Color" if data else "sRGB"
    return n


def runtime_look(objs, vid, entry, side, paint=None, lights_on=False, sirens_on=True):
    """Re-material the imported GLB objects the way the game dresses the MeshParts."""
    tex = os.path.join(VEH, vid, "textures")
    paint = paint or entry["paints"][0]
    prgb = tuple(srgb_to_lin([c / 255 for c in paint]))
    route = side["paint"]["route"]
    for o in objs:
        if o.type != "MESH":
            continue
        base = o.name.split(".")[0]
        if base in ("Body", "Body2"):
            m = bpy.data.materials.new(f"rt_{vid}_{base}")
            m.use_nodes = True
            nt = m.node_tree
            b = nt.nodes["Principled BSDF"]
            b.inputs["Roughness"].default_value = 0.3
            b.inputs["Metallic"].default_value = 0.0
            try:
                b.inputs["Coat Weight"].default_value = 0.8
                b.inputs["Coat Roughness"].default_value = 0.06
            except KeyError:
                pass
            sec = (side["paint"].get("secondary") or {}).get("color_srgb")
            col = prgb if base == "Body" else tuple(srgb_to_lin(sec if sec else [c / 255 for c in paint]))
            b.inputs["Base Color"].default_value = col + (1,)
            made = side["objects"]["Body"].get("textures", {})  # this build's files only
            livery = os.path.join(VEH, vid, made["base"]) if made.get("base") else None
            overlay = os.path.join(VEH, vid, made["overlay"]) if made.get("overlay") else None
            pick = None
            if base == "Body" and route == "tintmask" and entry.get("body") == "livery" and livery:
                pick = livery
            elif base == "Body" and route == "tintmask" and overlay:
                pick = overlay
            if pick:
                t = _img(nt, pick)
                mix = nt.nodes.new("ShaderNodeMix")
                mix.data_type = "RGBA"
                mix.inputs["A"].default_value = col + (1,)
                nt.links.new(t.outputs["Alpha"], mix.inputs["Factor"])
                nt.links.new(t.outputs["Color"], mix.inputs["B"])
                nt.links.new(mix.outputs["Result"], b.inputs["Base Color"])
                if pick == livery:  # baked game textures carry their own highlights: no clear coat
                    try:
                        b.inputs["Coat Weight"].default_value = 0.25
                    except KeyError:
                        pass
            o.data.materials.clear()
            o.data.materials.append(m)
        elif base == "Glass":
            m = bpy.data.materials.new("rt_glass")
            m.use_nodes = True
            b = m.node_tree.nodes["Principled BSDF"]
            b.inputs["Base Color"].default_value = tuple(srgb_to_lin([0.08, 0.10, 0.11])) + (1,)
            b.inputs["Roughness"].default_value = 0.04
            b.inputs["Alpha"].default_value = 0.6
            m.surface_render_method = "BLENDED"
            o.data.materials.clear()
            o.data.materials.append(m)
        elif base in ("SirenRed", "SirenBlue"):
            m = bpy.data.materials.new("rt_" + base)
            m.use_nodes = True
            b = m.node_tree.nodes["Principled BSDF"]
            c = (1.0, 0.03, 0.02) if base == "SirenRed" else (0.02, 0.1, 1.0)
            b.inputs["Base Color"].default_value = c + (1,)
            b.inputs["Emission Color"].default_value = c + (1,)
            b.inputs["Emission Strength"].default_value = 12.0 if sirens_on else 0.0
            o.data.materials.clear()
            o.data.materials.append(m)
        elif base.startswith("Lights"):
            for s in o.material_slots:
                if s.material and s.material.use_nodes:
                    b = s.material.node_tree.nodes.get("Principled BSDF")
                    if b and lights_on:
                        src = b.inputs["Base Color"].links[0].from_node if b.inputs["Base Color"].is_linked else None
                        if src is not None:
                            s.material.node_tree.links.new(src.outputs["Color"], b.inputs["Emission Color"])
                        b.inputs["Emission Strength"].default_value = 5.0 if base == "LightsFront" else 3.0


def load_car(vid, offset=(0, 0, 0), rot_z=0.0, paint=None, lights_on=False, roles=False):
    glb = os.path.join(VEH, vid, vid + ".glb")
    root, objs = R.load_glb(glb, offset=offset, rot_z=rot_z)
    if roles:
        R.colorize_roles(objs)
    else:
        runtime_look(objs, vid, roster()[vid], sidecar(vid), paint=paint, lights_on=lights_on)
    return root, objs


def shot_studio(vid, kind, res=(640, 360), samples=32):
    side = sidecar(vid)
    L, H = side["dimensions"]["length"], side["dimensions"]["height"]
    util.reset_scene()
    R.setup_cycles(samples=samples, res=res)
    R.studio(max(L, 14.0))
    load_car(vid, roles=(kind == "roles"))
    R.camera((0, 0, H * 0.42), L, az_deg=35, el_deg=9)
    os.makedirs(QA, exist_ok=True)
    return R.render_to(os.path.join(QA, f"{vid}_{kind}.png"))


CLASS_LABEL = {"compact": "compact", "hatch": "hot hatch", "sedan": "sedan", "taxi": "taxi", "luxury": "luxury",
               "limo": "limousine", "muscle": "muscle", "lowrider": "lowrider", "sports": "sports",
               "super": "supercar", "hyper": "hypercar", "suv": "SUV", "pickup": "pickup", "van": "van",
               "ambulance": "ambulance", "police": "police cruiser", "police_suv": "police SUV",
               "armored": "armored truck", "box_truck": "box truck", "bus": "bus", "fire": "fire truck"}


def sheet(ids, out, cols=5):
    from PIL import Image, ImageDraw, ImageFont
    paths, labels = [], []
    ros = roster()
    for vid in ids:
        p = os.path.join(QA, f"{vid}_look.png")
        if not os.path.exists(p):
            continue
        e = ros[vid]
        side = sidecar(vid)
        paths.append(p)
        labels.append((f"{e['brand']} {e['model']}",
                       f"{CLASS_LABEL.get(e['class'], e['class'])} · {side['triangles']['total']:,} tris · "
                       f"{side['dimensions']['length']:.1f} studs · {vid}"))
    ims = [Image.open(p).convert("RGB") for p in paths]
    w, h = ims[0].size
    lab = 52
    rows = math.ceil(len(ims) / cols)
    title_h = 56
    img = Image.new("RGB", (w * cols, title_h + (h + lab) * rows), (16, 16, 18))
    dr = ImageDraw.Draw(img)
    try:
        f1 = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 22)
        f2 = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 15)
        ft = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 28)
    except Exception:
        f1 = f2 = ft = ImageFont.load_default()
    dr.text((16, 12), f"Hotwire City vehicles v2: {len(ims)} uploaded car models (runtime look: paint, livery, "
                      f"glass, sirens as the game sets them)", fill=(240, 240, 240), font=ft)
    for i, im in enumerate(ims):
        x = (i % cols) * w
        y = title_h + (i // cols) * (h + lab)
        img.paste(im, (x, y))
        dr.text((x + 10, y + h + 4), labels[i][0], fill=(245, 245, 245), font=f1)
        dr.text((x + 10, y + h + 30), labels[i][1], fill=(170, 170, 175), font=f2)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    img.save(out)
    util.log("sheet ->", out)
    return out


# ------------------------------------------------------------------------------------------- rigged street render
def rb_to_bl(p):
    """Roblox (x right, y up, -z forward) -> Blender canonical used by carpipe (x right, y forward, z up)."""
    return Vector((p[0], -p[2], p[1]))


def place_rigged(vid, rig, at, heading, paint, lights_on):
    """Place each GLB object at the CFrame the CarBuilder rig gave the matching MeshPart (rig dump, chassis space,
    built pose), then move the car to `at` (Blender xy) facing `heading` radians."""
    glb = os.path.join(VEH, vid, vid + ".glb")
    root, objs = R.load_glb(glb)
    runtime_look(objs, vid, roster()[vid], sidecar(vid), paint=paint, lights_on=lights_on)
    parts = rig["parts"]
    for o in objs:
        if o.type != "MESH":
            continue
        base = o.name.split(".")[0]
        key = {"WheelFL": "Wheel_FL", "WheelFR": "Wheel_FR", "WheelRL": "Wheel_RL", "WheelRR": "Wheel_RR"}.get(base,
                                                                                                            base)
        p = parts.get(key)
        if not p:
            continue
        # the rig dump gives the part's bbox centre (Roblox, ground frame). The GLB object's origin is its node
        # translation (wheel axle / scene origin); move it so its bbox centre lands on the rig's centre.
        mn = Vector((min(v.co.x for v in o.data.vertices), min(v.co.y for v in o.data.vertices),
                     min(v.co.z for v in o.data.vertices)))
        mx = Vector((max(v.co.x for v in o.data.vertices), max(v.co.y for v in o.data.vertices),
                     max(v.co.z for v in o.data.vertices)))
        local_c = (mn + mx) / 2  # mesh space (object rotation is identity after import parenting)
        want = rb_to_bl(p["center"])
        o.matrix_world = Matrix.Translation(want - o.matrix_world.to_3x3() @ local_c) @ Matrix(o.matrix_world.to_3x3()).to_4x4()
    root.location = (at[0], at[1], 0)
    root.rotation_euler = (0, 0, heading)
    return root


def street(rig_path, night, out):
    rigs = json.load(open(rig_path))
    order = [v for v in rigs["order"] if os.path.exists(os.path.join(VEH, v, v + ".glb"))]
    util.reset_scene()
    R.setup_cycles(samples=40, res=(960, 540))
    L = 17.0
    lane = L * 0.42
    R.street(L, night=night, keep_clear=(lane * 1.9, L * 1.55))
    slots = [(lane * 0.5, -L * 0.3, 0.0), (lane * 1.5, -L * 1.4, 0.0), (-lane * 0.5, -L * 1.3, math.pi),
             (lane * 0.5, -L * 2.5, 0.0), (-lane * 1.5, -L * 2.4, math.pi), (lane * 1.5, -L * 3.4, 0.0),
             (-lane * 0.5, -L * 3.8, math.pi), (lane * 0.5, -L * 4.8, 0.0), (-lane * 1.5, -L * 5.2, math.pi)]
    for vid, (x, y, h) in zip(order, slots):
        rig = rigs["cars"][vid]
        place_rigged(vid, rig, (x, y), h, rig.get("paint"), night)
    R.camera_lookat((lane * 1.9, L * 1.55, 5.2), (-lane * 0.15, -L * 1.7, 2.6), lens=40)
    return R.render_to(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["look", "roles", "sheet", "street"])
    ap.add_argument("ids", nargs="*")
    ap.add_argument("--rig", default=os.path.join(VEH, "_rig", "rig.json"))
    ap.add_argument("--night", action="store_true")
    ap.add_argument("--out")
    ap.add_argument("--samples", type=int, default=32)
    a = ap.parse_args()
    ids = a.ids or [k for k in roster() if os.path.exists(os.path.join(VEH, k, k + ".glb"))]
    if a.mode in ("look", "roles"):
        for vid in ids:
            shot_studio(vid, a.mode, samples=a.samples)
    elif a.mode == "sheet":
        sheet(ids, a.out or os.path.join(EARLY, "roster.png"))
    else:
        street(a.rig, a.night, a.out or os.path.join(EARLY, "street_night.png" if a.night else "street_day.png"))


if __name__ == "__main__":
    main()
