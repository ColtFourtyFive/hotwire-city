#!/usr/bin/env python3
"""Blender (5.2, as a Python module) preview renderer for the v2 world (MapBuilder v2 output).

    lune run tools/blender/preview/dump.luau build/preview          # world.json + terrain.bin/json
    python3 -I tools/blender/preview/render.py [--dump build/preview] [--out docs/v2/early/world]
            [--views overview,downtown_street,freeway_interchange,palmera_beach,garage_plot,hillside_sign]
            [--samples 40] [--res 960x540] [--no-standins]

What it draws (Roblox space (x, y, z) -> Blender (x, -z, y), 1 stud = 1 unit):
  * every part MapBuilder built: Block / Wedge / Cylinder / Ball / SpecialMesh sphere, merged into one mesh per
    material (Look MaterialVariant PBR sets from assets/materials, box-projected at their StudsPerTile, multiplied by
    the part colour as Roblox does); Neon = emission; Glass = glossy transmission
  * Texture children (lane markings, crosswalks) as overlay quads with the same U/V convention the game uses
    (U across the part's X from its -X edge, V along +Z, offsets in studs)
  * terrain from World/Terrain.chunk (8-stud grid near the camera, 32 studs elsewhere), per-material PBR slots, and
    the water surfaces it reports (ocean / reservoir; the trench and the dry channel stay dry)
  * stand-ins, clearly not ours: A3's buildings as massing boxes per parcel, PlotService's garages as sheds
Lighting: the buildkit's sun-free late-afternoon HDRI + a matching Sun lamp when the cache exists, else the
multiple-scattering sky; haze = camera-ray distance blend to the sky colour. Cycles CPU, <= 960x540, <= 48 samples.
"""
import argparse
import json
import math
import os
import sys
import time

import numpy as np
import bpy

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
MATS = os.path.join(ROOT, "assets", "materials")
HDRI_DIRS = [
    os.path.join(ROOT, "tools", "blender", "buildkit", "_cache", "hdri"),
    "/home/user/HotwireCity/tools/blender/buildkit/_cache/hdri",
]

# --------------------------------------------------------------------------------------------- geometry primitives


def box_geo():
    v = np.array([[x, y, z] for x in (-0.5, 0.5) for y in (-0.5, 0.5) for z in (-0.5, 0.5)], np.float32)
    # index = xi*4 + yi*2 + zi
    f = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
    return v, f


def wedge_geo():
    # Roblox WedgePart: bottom full, the slope rises from the front-bottom edge (z -0.5) to the back-top edge (z +0.5)
    v = np.array([
        [-0.5, -0.5, -0.5], [0.5, -0.5, -0.5], [0.5, -0.5, 0.5], [-0.5, -0.5, 0.5],
        [-0.5, 0.5, 0.5], [0.5, 0.5, 0.5],
    ], np.float32)
    f = [(0, 3, 2, 1), (3, 4, 5, 2), (0, 1, 5, 4), (0, 4, 3), (1, 2, 5)]
    return v, f


def cyl_geo(n=14):
    # axis along X, radius 0.5 in YZ
    ring = [(0.5 * math.cos(2 * math.pi * i / n), 0.5 * math.sin(2 * math.pi * i / n)) for i in range(n)]
    v = [[-0.5, y, z] for y, z in ring] + [[0.5, y, z] for y, z in ring]
    f = [tuple(range(n - 1, -1, -1)), tuple(range(n, 2 * n))]
    for i in range(n):
        j = (i + 1) % n
        f.append((i, j, n + j, n + i))
    return np.array(v, np.float32), f


def sphere_geo(nu=12, nv=7):
    v = [[0, -0.5, 0]]
    for j in range(1, nv):
        t = -math.pi / 2 + math.pi * j / nv
        for i in range(nu):
            p = 2 * math.pi * i / nu
            v.append([0.5 * math.cos(t) * math.cos(p), 0.5 * math.sin(t), 0.5 * math.cos(t) * math.sin(p)])
    v.append([0, 0.5, 0])
    f = []
    top = len(v) - 1
    for i in range(nu):
        f.append((0, 1 + (i + 1) % nu, 1 + i))
    for j in range(nv - 2):
        for i in range(nu):
            a = 1 + j * nu + i
            b = 1 + j * nu + (i + 1) % nu
            f.append((a, b, b + nu, a + nu))
    base = 1 + (nv - 2) * nu
    for i in range(nu):
        f.append((base + i, base + (i + 1) % nu, top))
    return np.array(v, np.float32), f


GEO = {"Block": box_geo(), "Wedge": wedge_geo(), "Cylinder": cyl_geo(), "Sphere": sphere_geo(), "Ball": sphere_geo()}


def to_blender(p):
    """Roblox (x, y, z) -> Blender (x, -z, y), arrays of shape (..., 3)."""
    return np.stack([p[..., 0], -p[..., 2], p[..., 1]], axis=-1)


def transform(c, size, local):
    pos = np.array(c[0:3], np.float32)
    R = np.array(c[3:12], np.float32).reshape(3, 3)
    return (local * np.array(size, np.float32)) @ R.T + pos


# --------------------------------------------------------------------------------------------- mesh accumulation


class Acc:
    def __init__(self):
        self.verts = []
        self.faces = []
        self.cols = []
        self.uvs = []
        self.n = 0

    def add(self, verts, faces, col, uvs=None):
        self.verts.append(verts)
        for fc in faces:
            self.faces.append(tuple(i + self.n for i in fc))
            self.cols.append(col)
            if uvs is not None:
                self.uvs.append([uvs[i] for i in fc])
        self.n += len(verts)


def build_mesh(name, acc, material, with_uv=False, smooth=False):
    if acc.n == 0:
        return None
    verts = to_blender(np.concatenate(acc.verts, axis=0))
    me = bpy.data.meshes.new(name)
    me.vertices.add(len(verts))
    me.vertices.foreach_set("co", verts.ravel())
    sizes = np.array([len(f) for f in acc.faces], np.int32)
    starts = np.concatenate([[0], np.cumsum(sizes)[:-1]]).astype(np.int32)
    loops = np.fromiter((i for f in acc.faces for i in f), np.int32, count=int(sizes.sum()))
    me.loops.add(len(loops))
    me.loops.foreach_set("vertex_index", loops)
    me.polygons.add(len(acc.faces))
    me.polygons.foreach_set("loop_start", starts)
    me.polygons.foreach_set("loop_total", sizes)
    # per-face colour (corner domain)
    cols = np.repeat(np.array(acc.cols, np.float32), sizes, axis=0)
    attr = me.color_attributes.new("Col", "FLOAT_COLOR", "CORNER")
    rgba = np.ones((len(cols), 4), np.float32)
    rgba[:, :3] = cols
    attr.data.foreach_set("color", rgba.ravel())
    if with_uv and acc.uvs:
        uv = me.uv_layers.new(name="UV")
        flat = np.array([c for f in acc.uvs for c in f], np.float32)
        uv.data.foreach_set("uv", flat.ravel())
    me.validate()
    me.update()
    if smooth:
        me.shade_smooth()
    else:
        me.shade_flat()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    ob.data.materials.append(material)
    return ob


def srgb_to_lin(c):
    c = np.asarray(c, np.float32) / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


# --------------------------------------------------------------------------------------------- materials

_mats = {}
MATDEF = {}
for m in json.load(open(os.path.join(MATS, "materials.json")))["materials"]:
    MATDEF[m["variant"]] = m
HAZE = {"color": (0.56, 0.66, 0.80), "dist": 9000.0, "max": 0.8}


def haze_wrap(nt, shader_out):
    """Blend camera rays toward the haze colour with distance (cheap aerial perspective)."""
    lp = nt.nodes.new("ShaderNodeLightPath")
    mul = nt.nodes.new("ShaderNodeMath")
    mul.operation = "DIVIDE"
    nt.links.new(lp.outputs["Ray Length"], mul.inputs[0])
    mul.inputs[1].default_value = HAZE["dist"]
    ex = nt.nodes.new("ShaderNodeMath")
    ex.operation = "EXPONENT"
    neg = nt.nodes.new("ShaderNodeMath")
    neg.operation = "MULTIPLY"
    nt.links.new(mul.outputs[0], neg.inputs[0])
    neg.inputs[1].default_value = -1.0
    nt.links.new(neg.outputs[0], ex.inputs[0])
    inv = nt.nodes.new("ShaderNodeMath")
    inv.operation = "SUBTRACT"
    inv.inputs[0].default_value = 1.0
    nt.links.new(ex.outputs[0], inv.inputs[1])
    cap = nt.nodes.new("ShaderNodeMath")
    cap.operation = "MULTIPLY"
    cap.inputs[1].default_value = HAZE["max"]
    nt.links.new(inv.outputs[0], cap.inputs[0])
    cam = nt.nodes.new("ShaderNodeMath")
    cam.operation = "MULTIPLY"
    nt.links.new(cap.outputs[0], cam.inputs[0])
    nt.links.new(lp.outputs["Is Camera Ray"], cam.inputs[1])
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = (*HAZE["color"], 1)
    em.inputs["Strength"].default_value = 1.0
    mix = nt.nodes.new("ShaderNodeMixShader")
    nt.links.new(cam.outputs[0], mix.inputs[0])
    nt.links.new(shader_out, mix.inputs[1])
    nt.links.new(em.outputs[0], mix.inputs[2])
    return mix.outputs[0]


def new_mat(name):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    return m, nt, out


def img(path, non_color=False):
    im = bpy.data.images.load(path, check_existing=True)
    if non_color:
        im.colorspace_settings.name = "Non-Color"
    return im


def pbr_material(name, variant, tint=None, roughness_scale=1.0, uv=None):
    """Look MaterialVariant: box-projected maps x vertex colour (Part.Color)."""
    key = (name, variant, tint)
    if key in _mats:
        return _mats[key]
    d = MATDEF[variant]
    m, nt, out = new_mat(name)
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    tc = nt.nodes.new("ShaderNodeTexCoord")
    mp = nt.nodes.new("ShaderNodeMapping")
    s = 1.0 / d["studsPerTile"]
    mp.inputs["Scale"].default_value = (s, s, s)
    nt.links.new(tc.outputs["Object"], mp.inputs["Vector"])

    def tex(kind, non_color):
        f = d["files"].get(kind)
        if not f:
            return None
        t = nt.nodes.new("ShaderNodeTexImage")
        t.image = img(os.path.join(ROOT, f), non_color)
        t.projection = "BOX"
        t.projection_blend = 0.25
        nt.links.new(mp.outputs[0], t.inputs["Vector"])
        return t

    col = tex("color", False)
    vc = nt.nodes.new("ShaderNodeVertexColor")
    vc.layer_name = "Col"
    mulc = nt.nodes.new("ShaderNodeMix")
    mulc.data_type = "RGBA"
    mulc.blend_type = "MULTIPLY"
    mulc.inputs["Factor"].default_value = 1.0
    nt.links.new(col.outputs["Color"], mulc.inputs["A"])
    if tint is not None:
        mulc.inputs["B"].default_value = (*tint, 1)
    else:
        nt.links.new(vc.outputs["Color"], mulc.inputs["B"])
    nt.links.new(mulc.outputs["Result"], bsdf.inputs["Base Color"])
    rough = tex("roughness", True)
    if rough:
        rm = nt.nodes.new("ShaderNodeMath")
        rm.operation = "MULTIPLY"
        rm.inputs[1].default_value = roughness_scale
        nt.links.new(rough.outputs["Color"], rm.inputs[0])
        nt.links.new(rm.outputs[0], bsdf.inputs["Roughness"])
    nrm = tex("normal", True)
    if nrm:
        nm = nt.nodes.new("ShaderNodeNormalMap")
        nm.inputs["Strength"].default_value = 0.6
        nt.links.new(nrm.outputs["Color"], nm.inputs["Color"])
        nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])
    met = tex("metalness", True)
    if met:
        nt.links.new(met.outputs["Color"], bsdf.inputs["Metallic"])
    nt.links.new(haze_wrap(nt, bsdf.outputs[0]), out.inputs["Surface"])
    _mats[key] = m
    return m


def plain_material(name, rough=0.6, metal=0.0, emission=0.0, transmission=0.0, alpha=1.0):
    key = (name, rough, metal, emission, transmission, alpha)
    if key in _mats:
        return _mats[key]
    m, nt, out = new_mat(name)
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    vc = nt.nodes.new("ShaderNodeVertexColor")
    vc.layer_name = "Col"
    nt.links.new(vc.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    if transmission > 0:
        bsdf.inputs["Transmission Weight"].default_value = transmission
    if emission > 0:
        nt.links.new(vc.outputs["Color"], bsdf.inputs["Emission Color"])
        bsdf.inputs["Emission Strength"].default_value = emission
    shader = bsdf.outputs[0]
    if alpha < 1.0:
        tr = nt.nodes.new("ShaderNodeBsdfTransparent")
        mix = nt.nodes.new("ShaderNodeMixShader")
        mix.inputs[0].default_value = 1.0 - alpha
        nt.links.new(bsdf.outputs[0], mix.inputs[1])
        nt.links.new(tr.outputs[0], mix.inputs[2])
        shader = mix.outputs[0]
    nt.links.new(haze_wrap(nt, shader), out.inputs["Surface"])
    _mats[key] = m
    return m


def overlay_material(path):
    key = ("overlay", path)
    if key in _mats:
        return _mats[key]
    m, nt, out = new_mat("ov_" + os.path.basename(path))
    t = nt.nodes.new("ShaderNodeTexImage")
    t.image = img(path)
    t.interpolation = "Linear"
    uvn = nt.nodes.new("ShaderNodeUVMap")
    uvn.uv_map = "UV"
    nt.links.new(uvn.outputs["UV"], t.inputs["Vector"])
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.inputs["Roughness"].default_value = 0.7
    nt.links.new(t.outputs["Color"], bsdf.inputs["Base Color"])
    tr = nt.nodes.new("ShaderNodeBsdfTransparent")
    mix = nt.nodes.new("ShaderNodeMixShader")
    nt.links.new(t.outputs["Alpha"], mix.inputs[0])
    nt.links.new(tr.outputs[0], mix.inputs[1])
    nt.links.new(bsdf.outputs[0], mix.inputs[2])
    nt.links.new(haze_wrap(nt, mix.outputs[0]), out.inputs["Surface"])
    _mats[key] = m
    return m


PLAIN = {
    # Roblox material -> (roughness, metal, transmission)
    "SmoothPlastic": (0.45, 0.0, 0.0),
    "Plastic": (0.5, 0.0, 0.0),
    "Metal": (0.35, 0.85, 0.0),
    "Wood": (0.75, 0.0, 0.0),
    "WoodPlanks": (0.75, 0.0, 0.0),
    "Glass": (0.05, 0.0, 0.85),
    "LeafyGrass": (0.85, 0.0, 0.0),
    "Grass": (0.9, 0.0, 0.0),
    "Concrete": (0.85, 0.0, 0.0),
    "Rock": (0.9, 0.0, 0.0),
}


def material_for(p):
    v = p.get("v")
    m = p["m"]
    t = p.get("t") or 0
    if m == "Neon":
        return plain_material("neon", emission=3.0), "neon"
    if t >= 0.95:
        return None, None
    if v and v in MATDEF and v != "HC_WindowGlass":
        return pbr_material("pbr_" + v, v), "pbr_" + v
    if v == "HC_WindowGlass":
        return pbr_material("pbr_glass", v, roughness_scale=1.6), "pbr_glass"
    r, me, tr = PLAIN.get(m, (0.6, 0.0, 0.0))
    if m == "Glass" or t > 0.2:
        return plain_material("glassy", rough=0.05, transmission=0.0, alpha=max(0.25, 1 - t)), "glassy"
    return plain_material("plain_" + m, rough=r, metal=me), "plain_" + m


# --------------------------------------------------------------------------------------------- scene


def reset(res, samples):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _mats.clear()
    s = bpy.context.scene
    s.render.engine = "CYCLES"
    c = s.cycles
    c.device = "CPU"
    c.samples = samples
    c.use_adaptive_sampling = True
    c.adaptive_threshold = 0.03
    c.use_denoising = True
    try:
        c.denoiser = "OPENIMAGEDENOISE"
    except Exception:
        pass
    c.max_bounces, c.diffuse_bounces, c.glossy_bounces, c.transmission_bounces = 4, 2, 2, 2
    c.transparent_max_bounces = 6
    c.caustics_reflective = c.caustics_refractive = False
    c.sample_clamp_indirect = 5.0
    s.render.threads_mode = "FIXED"
    s.render.threads = 4
    s.render.resolution_x, s.render.resolution_y = res
    s.render.resolution_percentage = 100
    s.view_settings.view_transform = "AgX"
    for look in ("AgX - Medium High Contrast", "AgX - Punchy"):
        try:
            s.view_settings.look = look
            break
        except Exception:
            continue
    s.view_settings.exposure = -0.55
    s.render.image_settings.file_format = "PNG"
    return s


def world_light(sun_az=-128.0, sun_el=24.0):
    """Late afternoon: the buildkit's sun-free HDRI + Sun lamp when cached, else the multiple-scattering sky."""
    w = bpy.data.worlds.new("Sky")
    bpy.context.scene.world = w
    w.use_nodes = True
    nt = w.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    bg = nt.nodes.new("ShaderNodeBackground")
    out = nt.nodes.new("ShaderNodeOutputWorld")
    nt.links.new(bg.outputs[0], out.inputs[0])
    meta = None
    for d in HDRI_DIRS:
        jp = os.path.join(d, "sky_late_afternoon_nosun.json")
        ep = os.path.join(d, "sky_late_afternoon_nosun.exr")
        if os.path.exists(jp) and os.path.exists(ep):
            meta = dict(json.load(open(jp)), path=ep)
            break
    if meta:
        tc = nt.nodes.new("ShaderNodeTexCoord")
        mp = nt.nodes.new("ShaderNodeMapping")
        env = nt.nodes.new("ShaderNodeTexEnvironment")
        env.image = bpy.data.images.load(meta["path"], check_existing=True)
        nt.links.new(tc.outputs["Generated"], mp.inputs[0])
        nt.links.new(mp.outputs[0], env.inputs[0])
        nt.links.new(env.outputs[0], bg.inputs[0])
        bg.inputs[1].default_value = 1.5
        mp.inputs["Rotation"].default_value[2] = math.radians(meta["az"] - sun_az)
        energy = max(4.5, meta["irradiance"] * 1.4)
    else:
        sky = nt.nodes.new("ShaderNodeTexSky")
        sky.sky_type = "MULTIPLE_SCATTERING"
        sky.sun_elevation = math.radians(sun_el)
        sky.sun_rotation = math.radians(sun_az)
        nt.links.new(sky.outputs[0], bg.inputs[0])
        bg.inputs[1].default_value = 0.35
        energy = 4.0
    ld = bpy.data.lights.new("Sun", "SUN")
    ld.energy = energy
    ld.color = (1.0, 0.9, 0.78)
    ld.angle = math.radians(0.6)
    ob = bpy.data.objects.new("Sun", ld)
    bpy.context.scene.collection.objects.link(ob)
    az, el = math.radians(sun_az), math.radians(sun_el)
    d = np.array([math.cos(el) * math.cos(az), math.cos(el) * math.sin(az), math.sin(el)])
    ob.rotation_euler = (0.0, 0.0, 0.0)
    from mathutils import Vector
    ob.rotation_euler = Vector((-d[0], -d[1], -d[2])).to_track_quat("-Z", "Y").to_euler()


def camera(view):
    from mathutils import Vector
    pos = to_blender(np.array(view["pos"], np.float32))
    tgt = to_blender(np.array(view["target"], np.float32))
    cd = bpy.data.cameras.new("Cam")
    cd.lens_unit = "FOV"
    cd.angle = math.radians(view.get("fov", 55))
    cd.clip_start = 0.5
    cd.clip_end = 60000
    ob = bpy.data.objects.new("Cam", cd)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = Vector(pos.tolist())
    ob.rotation_euler = (Vector(tgt.tolist()) - Vector(pos.tolist())).to_track_quat("-Z", "Y").to_euler()
    bpy.context.scene.camera = ob
    return pos, tgt


# --------------------------------------------------------------------------------------------- content


def add_parts(parts, focus, radius):
    groups = {}
    overlays = {}
    for p in parts:
        c = p["c"]
        if focus is not None:
            dx, dz = c[0] - focus[0], c[2] - focus[2]
            if dx * dx + dz * dz > radius * radius:
                continue
        mat, key = material_for(p)
        size = p["z"]
        if mat is not None:
            v, f = GEO.get(p["s"], GEO["Block"])
            if p["s"] == "Ball":
                r = min(size)
                size = [r, r, r]
            verts = transform(c, size, v)
            col = srgb_to_lin(p["k"])
            g = groups.get(key)
            if g is None:
                g = groups[key] = (Acc(), mat)
            g[0].add(verts, f, col)
        for t in p.get("x") or []:
            if not t.get("file") or t["face"] != "Top" or t.get("decal"):
                continue
            path = os.path.join(ROOT, t["file"])
            if not os.path.exists(path):
                continue
            sx, sy, sz = size
            lift = sy / 2 + 0.04
            loc = np.array([[-sx / 2, lift, -sz / 2], [sx / 2, lift, -sz / 2], [sx / 2, lift, sz / 2],
                            [-sx / 2, lift, sz / 2]], np.float32)
            pos = np.array(c[0:3], np.float32)
            R = np.array(c[3:12], np.float32).reshape(3, 3)
            verts = loc @ R.T + pos
            uvs = []
            for lx, _, lz in loc:
                u = (lx + sx / 2 + t["ou"]) / t["su"]
                vv = (lz + sz / 2 + t["ov"]) / t["sv"]
                uvs.append((u, 1.0 - vv))
            o = overlays.get(path)
            if o is None:
                o = overlays[path] = Acc()
            o.add(verts, [(0, 3, 2, 1)], (1, 1, 1), uvs)
    for key, (acc, mat) in groups.items():
        build_mesh("parts_" + key, acc, mat)
    for path, acc in overlays.items():
        build_mesh("ov_" + os.path.basename(path), acc, overlay_material(path), with_uv=True)
    return sum(len(a.faces) for a, _ in groups.values())


STANDIN_VARIANT = {
    "glass": "HC_WindowGlass",
    "concrete": "HC_ConcreteModern",
    "stucco": "HC_Stucco",
    "brick": "HC_BrickRed",
    "corrugated": "HC_CorrugatedMetal",
    "wood": "HC_WoodPlanks",
}
STANDIN_TINT = {
    "glass": (0.30, 0.38, 0.46),
    "concrete": (0.62, 0.61, 0.58),
    "stucco": (0.80, 0.74, 0.64),
    "brick": (0.70, 0.52, 0.44),
    "corrugated": (0.60, 0.62, 0.62),
    "wood": (0.55, 0.46, 0.36),
}


def add_standins(standins, focus, radius):
    groups = {}
    v, f = GEO["Block"]
    for s in standins:
        c = list(s["c"])
        if focus is not None:
            dx, dz = c[0] - focus[0], c[2] - focus[2]
            if dx * dx + dz * dz > radius * radius:
                continue
        size = s["z"]
        if s["kind"] == "building":
            c[1] = c[1] + size[1] / 2  # the parcel frame is at ground level
            key = s["mat"]
        else:
            key = "corrugated"
        verts = transform(c, size, v)
        acc = groups.setdefault(key, Acc())
        # slight per-building tint variety
        h = ((s.get("seed") or 7) * 2654435761 % 1000) / 1000.0
        acc.add(verts, f, (0.85 + 0.25 * h,) * 3)
    for key, acc in groups.items():
        var = STANDIN_VARIANT[key]
        mat = pbr_material("standin_" + key, var, tint=None)
        build_mesh("standin_" + key, acc, mat)
        # tint through the vertex colour: scale by the stand-in tint
        ob = bpy.data.objects["standin_" + key]
        attr = ob.data.color_attributes["Col"]
        n = len(attr.data)
        arr = np.empty(n * 4, np.float32)
        attr.data.foreach_get("color", arr)
        arr = arr.reshape(n, 4)
        arr[:, :3] *= np.array(STANDIN_TINT[key], np.float32)
        attr.data.foreach_set("color", arr.ravel())


TERRAIN_VARIANT = {
    "Grass": ("HC_Grass", None),
    "LeafyGrass": ("HC_Grass", (0.42, 0.50, 0.30)),
    "Sand": ("HC_Sand", None),
    "Rock": ("HC_Rock", None),
    "Slate": ("HC_RockSlate", None),
    "Ground": ("HC_DryGrass", None),
    "Concrete": ("HC_Concrete", None),
    "Sandstone": ("HC_Rock", (0.70, 0.46, 0.32)),
    "Asphalt": ("HC_Asphalt", None),
}


def mesh_np(name, verts, faces, cols, material, smooth=True):
    """verts (N, 3) Roblox space, faces (F, 4) int quads, cols (F, 3) linear RGB."""
    if len(faces) == 0:
        return None
    used, inv = np.unique(faces.ravel(), return_inverse=True)
    faces = inv.reshape(faces.shape).astype(np.int32)
    v = to_blender(verts[used])
    me = bpy.data.meshes.new(name)
    me.vertices.add(len(v))
    me.vertices.foreach_set("co", v.ravel())
    F, k = faces.shape
    me.loops.add(F * k)
    me.loops.foreach_set("vertex_index", faces.ravel())
    me.polygons.add(F)
    me.polygons.foreach_set("loop_start", (np.arange(F, dtype=np.int32) * k))
    me.polygons.foreach_set("loop_total", np.full(F, k, np.int32))
    attr = me.color_attributes.new("Col", "FLOAT_COLOR", "CORNER")
    rgba = np.ones((F * k, 4), np.float32)
    rgba[:, :3] = np.repeat(cols, k, axis=0)
    attr.data.foreach_set("color", rgba.ravel())
    me.validate()
    me.update()
    if smooth:
        me.shade_smooth()
    else:
        me.shade_flat()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    ob.data.materials.append(material)
    return ob


def add_terrain(dump, center, fine_r, coarse=4, fine=1):
    meta = json.load(open(os.path.join(dump, "terrain.json")))
    nx, nz, step = meta["nx"], meta["nz"], meta["step"]
    raw = np.fromfile(os.path.join(dump, "terrain.bin"), dtype=np.uint8)
    H = raw[: nx * nz * 4].view(np.float32).reshape(nz, nx)
    W = raw[nx * nz * 4: nx * nz * 8].view(np.float32).reshape(nz, nx)
    M = raw[nx * nz * 8: nx * nz * 9].reshape(nz, nx)
    names = meta["materials"]
    colors = meta.get("colors") or {}
    colors.setdefault("Sandstone", [196, 150, 112])
    colors.setdefault("Ground", [207, 190, 158])
    x0, z0 = meta["x0"] + step / 4, meta["z0"] + step / 4

    def grid(ix0, ix1, iz0, iz1, k, hole=None):
        xs = np.arange(ix0, ix1 + 1, k)
        zs = np.arange(iz0, iz1 + 1, k)
        xs = xs[xs < nx]
        zs = zs[zs < nz]
        if len(xs) < 2 or len(zs) < 2:
            return
        hh = H[np.ix_(zs, xs)]
        X, Z = np.meshgrid(x0 + xs * step, z0 + zs * step)
        verts = np.stack([X, hh, Z], -1).reshape(-1, 3).astype(np.float32)
        ncol = len(xs)
        I, J = np.meshgrid(np.arange(ncol - 1), np.arange(len(zs) - 1))
        I, J = I.ravel(), J.ravel()
        a = J * ncol + I
        faces = np.stack([a, a + ncol, a + ncol + 1, a + 1], -1)
        keep = np.ones(len(a), bool)
        cxw, czw = x0 + xs[I] * step, z0 + zs[J] * step
        if hole is not None:
            keep &= ~((cxw > hole[0]) & (cxw < hole[2]) & (czw > hole[1]) & (czw < hole[3]))
        mids = M[zs[J], xs[I]]
        for mid in np.unique(mids[keep]):
            sel = keep & (mids == mid)
            name = names[mid - 1] if 0 < mid <= len(names) else "Ground"
            var, tint = TERRAIN_VARIANT.get(name, ("HC_DryGrass", None))
            col = srgb_to_lin(colors.get(name, [200, 190, 160]))
            cols = np.tile(col, (int(sel.sum()), 1)).astype(np.float32)
            mesh_np("terrain_%s_%d" % (name, k), verts, faces[sel], cols, pbr_material("terrain_" + name, var, tint=tint))
        wl = W[zs[J], xs[I]]
        ws = keep & (wl > -9000)
        if ws.any():
            xa, za = cxw[ws], czw[ws]
            xb, zb = xa + k * step, za + k * step
            lv = wl[ws]
            q = np.stack([
                np.stack([xa, lv, za], -1), np.stack([xa, lv, zb], -1),
                np.stack([xb, lv, zb], -1), np.stack([xb, lv, za], -1),
            ], 1).reshape(-1, 3).astype(np.float32)
            n = int(ws.sum())
            wf = np.arange(n * 4, dtype=np.int64).reshape(n, 4)
            mesh_np("water_%d" % k, q, wf, np.ones((n, 3), np.float32), water_material(), smooth=False)

    cx = int((center[0] - x0) / step)
    cz = int((center[2] - z0) / step)
    r = int(fine_r / step)
    fx0, fx1 = max(0, cx - r), min(nx - 1, cx + r)
    fz0, fz1 = max(0, cz - r), min(nz - 1, cz + r)
    hole = None
    if fine_r > 0:
        grid(fx0, fx1, fz0, fz1, fine)
        hole = (x0 + fx0 * step, z0 + fz0 * step, x0 + (fx1 - coarse) * step, z0 + (fz1 - coarse) * step)
    grid(0, nx - 1, 0, nz - 1, coarse, hole)


def water_material():
    key = ("water",)
    if key in _mats:
        return _mats[key]
    m, nt, out = new_mat("water")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.inputs["Base Color"].default_value = (0.012, 0.05, 0.07, 1)
    bsdf.inputs["Roughness"].default_value = 0.06
    bsdf.inputs["Specular IOR Level"].default_value = 0.6
    noise = nt.nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 0.08
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.08
    tc = nt.nodes.new("ShaderNodeTexCoord")
    nt.links.new(tc.outputs["Object"], noise.inputs["Vector"])
    nt.links.new(noise.outputs["Fac"], bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    nt.links.new(haze_wrap(nt, bsdf.outputs[0]), out.inputs["Surface"])
    _mats[key] = m
    return m


# --------------------------------------------------------------------------------------------- main

VIEW_SETTINGS = {
    # name: (parts radius around the target, fine-terrain radius, coarse step, haze distance)
    "overview": (None, 0, 4, 26000),
    "downtown_street": (2600, 1400, 4, 9000),
    "freeway_interchange": (2600, 1600, 4, 14000),
    "palmera_beach": (3200, 1600, 4, 12000),
    "garage_plot": (1800, 900, 4, 9000),
    "hillside_sign": (6000, 2400, 4, 18000),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump", default=os.path.join(ROOT, "build", "preview"))
    ap.add_argument("--out", default=os.path.join(ROOT, "docs", "v2", "early", "world"))
    ap.add_argument("--views", default=",".join(VIEW_SETTINGS))
    ap.add_argument("--samples", type=int, default=40)
    ap.add_argument("--res", default="960x540")
    ap.add_argument("--no-standins", action="store_true")
    a = ap.parse_args()
    res = tuple(int(x) for x in a.res.split("x"))
    data = json.load(open(os.path.join(a.dump, "world.json")))
    os.makedirs(a.out, exist_ok=True)
    for name in a.views.split(","):
        view = data["views"][name]
        prad, frad, coarse, haze = VIEW_SETTINGS.get(name, (3000, 1200, 4, 6000))
        HAZE["dist"] = haze
        t0 = time.time()
        reset(res, min(a.samples, 48))
        world_light()
        camera(view)
        tgt = view["target"]
        focus = None if prad is None else (tgt[0], tgt[1], tgt[2])
        # parts near the target; the overview keeps everything
        nf = add_parts(data["parts"], focus, prad or 1e9)
        if not a.no_standins:
            add_standins(data["standins"], focus, prad or 1e9)
        add_terrain(a.dump, tgt if frad else (0, 0, 0), frad, coarse=coarse)
        path = os.path.join(a.out, name + ".png")
        bpy.context.scene.render.filepath = path
        bpy.ops.render.render(write_still=True)
        print("%s: %d part faces, %.0f s -> %s" % (name, nf, time.time() - t0, path), flush=True)


if __name__ == "__main__":
    main()
