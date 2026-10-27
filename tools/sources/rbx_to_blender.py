#!/usr/bin/env python3
"""Rebuild a downloaded Roblox model in Blender and render previews.

    python3 -I tools/sources/rbx_to_blender.py <modelId> [--samples 32] [--res 960x540]
                                              [--glb] [--blend] [--no-render] [--keep-hidden]

Prerequisites (all cached under assets/source/roblox/):
    python3 -I tools/sources/rbxdl.py <modelId>
    lune run tools/sources/rbxm_inspect.luau assets/source/roblox/<id>/asset.rbxm[x] assets/source/roblox/<id>/tree.json
    python3 -I tools/sources/rbxmesh.py model <modelId>
(`python3 -I tools/sources/rbx_cars.py <ids>` runs the whole chain.)

What it builds (1 Blender unit = 1 stud):
  * MeshPart     converted FileMesh, recentred on its bbox, scaled so the bbox fills Part.Size
                 (Size / InitialSize when InitialSize is present), TextureID applied (texture alpha
                 = cut-out), SurfaceAppearance ColorMap/NormalMap/Metalness/Roughness applied.
  * Part + SpecialMesh  FileMesh (vertices * Scale + Offset, not normalised) or Brick/Wedge/
                 Cylinder/Sphere/Head primitives scaled by Size*Scale.
  * Part / WedgePart / CornerWedgePart / Seat  box, cylinder (X axis), ball, wedge, corner wedge.
  * UnionOperation  bounding box (CSG geometry is not decoded) -> flagged in the report.
  * Decal / Texture  textured quad on the part face (bbox face for meshes).
  * Color3 is sRGB -> linear; Roblox Material -> Principled roughness/metallic/transmission;
    Neon -> emission; Glass / Transparency -> alpha; Reflectance -> clear coat.
Coordinates: Roblox (x, y, z) -> Blender (x, -z, y). The car is re-oriented so its front (from the
VehicleSeat look vector, else light names, else -Z) faces Blender -Y, and sits on z = 0.

Outputs in assets/source/roblox/<id>/: preview_34.png (3/4 front), preview_side.png (left side,
orthographic), build.json (stats), optional rebuilt.glb / rebuilt.blend.
"""
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import bpy  # noqa: E402  (must precede bmesh)
import bmesh  # noqa: E402
import numpy as np  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402

import rbxdl  # noqa: E402
import rbxmesh  # noqa: E402

PART_CLASSES = {"Part", "MeshPart", "WedgePart", "CornerWedgePart", "TrussPart", "Seat", "VehicleSeat",
                "SpawnLocation", "UnionOperation", "IntersectOperation", "SkateboardPlatform", "FlagStand"}
R2B = Matrix(((1, 0, 0, 0), (0, 0, -1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))  # roblox -> blender world


# ---------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------
def srgb_to_lin(c):
    c = float(c)
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def cf_matrix(cf):
    x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf
    return Matrix(((r00, r01, r02, x), (r10, r11, r12, y), (r20, r21, r22, z), (0, 0, 0, 1)))


def scale_matrix(s):
    return Matrix(((s[0], 0, 0, 0), (0, s[1], 0, 0), (0, 0, s[2], 0), (0, 0, 0, 1)))


def trans_matrix(t):
    return Matrix.Translation(Vector(t))


def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    for c in (bpy.data.objects, bpy.data.meshes, bpy.data.materials, bpy.data.images, bpy.data.cameras, bpy.data.lights):
        for b in list(c):
            c.remove(b)


def mesh_from_arrays(name, pos, faces, uv=None, nrm=None, smooth=True):
    me = bpy.data.meshes.new(name)
    nv, nf = len(pos), len(faces)
    me.vertices.add(nv)
    me.vertices.foreach_set("co", np.asarray(pos, np.float32).ravel())
    me.loops.add(nf * 3)
    me.loops.foreach_set("vertex_index", np.asarray(faces, np.int32).ravel())
    me.polygons.add(nf)
    me.polygons.foreach_set("loop_start", np.arange(0, nf * 3, 3, dtype=np.int32))
    me.update(calc_edges=True)
    if uv is not None:
        lay = me.uv_layers.new(name="UVMap")
        luv = np.asarray(uv, np.float32)[np.asarray(faces).ravel()].copy()
        luv[:, 1] = 1.0 - luv[:, 1]  # Roblox top-left origin -> Blender bottom-left
        lay.data.foreach_set("uv", luv.ravel())
    if smooth:
        me.polygons.foreach_set("use_smooth", np.ones(nf, dtype=bool))
    if nrm is not None and len(nrm) == nv:
        n = np.asarray(nrm, np.float32)
        ln = np.linalg.norm(n, axis=1, keepdims=True)
        ok = ln[:, 0] > 1e-6
        n[ok] /= ln[ok]
        n[~ok] = (0, 1, 0)
        try:
            me.normals_split_custom_set_from_vertices([tuple(v) for v in n])
        except Exception:  # noqa: BLE001
            pass
    me.validate(clean_customdata=False)
    return me


_prim_cache = {}


def prim(kind):
    """Unit primitives in Roblox part space (size 1 along each axis, centred)."""
    if kind in _prim_cache:
        return _prim_cache[kind]
    bm = bmesh.new()
    if kind == "box":
        bmesh.ops.create_cube(bm, size=1.0)
    elif kind == "cyl_x":  # Part Shape=Cylinder: axis along X
        bmesh.ops.create_cone(bm, cap_ends=True, segments=32, radius1=0.5, radius2=0.5, depth=1.0)
        bmesh.ops.rotate(bm, verts=bm.verts, cent=(0, 0, 0), matrix=Matrix.Rotation(math.pi / 2, 4, "Y"))
    elif kind == "cyl_y":  # CylinderMesh / SpecialMesh Head: axis along Y
        bmesh.ops.create_cone(bm, cap_ends=True, segments=32, radius1=0.5, radius2=0.5, depth=1.0)
        bmesh.ops.rotate(bm, verts=bm.verts, cent=(0, 0, 0), matrix=Matrix.Rotation(-math.pi / 2, 4, "X"))
    elif kind == "ball":
        bmesh.ops.create_uvsphere(bm, u_segments=32, v_segments=16, radius=0.5)
    elif kind == "wedge":  # full height at +Z (back), slope down to -Z (front)
        vs = [bm.verts.new(v) for v in ((-.5, -.5, -.5), (.5, -.5, -.5), (.5, -.5, .5), (-.5, -.5, .5), (-.5, .5, .5), (.5, .5, .5))]
        for f in ((0, 1, 2, 3), (3, 2, 5, 4), (0, 4, 5, 1), (0, 3, 4), (1, 5, 2)):
            bm.faces.new([vs[i] for i in f])
    elif kind == "cornerwedge":  # apex above (+X, -Z) corner
        vs = [bm.verts.new(v) for v in ((-.5, -.5, -.5), (.5, -.5, -.5), (.5, -.5, .5), (-.5, -.5, .5), (.5, .5, -.5))]
        for f in ((0, 3, 2, 1), (0, 1, 4), (1, 2, 4), (2, 3, 4), (3, 0, 4)):
            bm.faces.new([vs[i] for i in f])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new("prim_" + kind)
    bm.to_mesh(me)
    bm.free()
    if kind in ("cyl_x", "cyl_y", "ball"):
        for p in me.polygons:
            p.use_smooth = len(p.vertices) == 4 or kind == "ball"
    me.uv_layers.new(name="UVMap")
    _prim_cache[kind] = me
    return me


_mesh_cache = {}


def file_mesh(mesh_id):
    """-> (bpy mesh in raw mesh space, bbox_min, bbox_max) or None"""
    if mesh_id in _mesh_cache:
        return _mesh_cache[mesh_id]
    meta = rbxdl.cached(mesh_id)
    res = None
    if meta and meta.get("ok") and meta.get("kind") == "mesh":
        try:
            m = rbxmesh.load(os.path.join(rbxdl.asset_dir(mesh_id), meta["file"]))
            if len(m.faces):
                lo, hi = m.bbox()
                me = mesh_from_arrays(f"mesh_{mesh_id}", m.pos, m.faces, m.uv, m.nrm)
                res = (me, np.array(lo), np.array(hi), (m.pos.astype(np.float64), m.faces.astype(np.int64)))
        except Exception as e:  # noqa: BLE001
            print(f"  mesh {mesh_id} failed: {e}")
    _mesh_cache[mesh_id] = res
    return res


_img_cache = {}


def image(asset_ref):
    aid = rbxdl.parse_asset_id(asset_ref)
    if not aid:
        return None
    if aid in _img_cache:
        return _img_cache[aid]
    png = os.path.join(rbxdl.asset_dir(aid), "image.png")
    img = None
    if os.path.exists(png):
        try:
            img = bpy.data.images.load(png, check_existing=True)
            img.alpha_mode = "STRAIGHT"
        except Exception:  # noqa: BLE001
            img = None
    _img_cache[aid] = img
    return img


def img_has_alpha(img):
    if img is None or img.channels < 4:
        return False
    key = "_hc_alpha"
    if key in img:
        return bool(img[key])
    px = np.empty(img.size[0] * img.size[1] * 4, np.float32)
    img.pixels.foreach_get(px)
    has = bool((px[3::4] < 0.98).any())
    img[key] = has
    return has


# ---------------------------------------------------------------------------------------------
# materials
# ---------------------------------------------------------------------------------------------
MAT_PARAMS = {  # roblox material -> (roughness, metallic)
    "Plastic": (0.55, 0.0), "SmoothPlastic": (0.32, 0.0), "Glass": (0.04, 0.0), "Metal": (0.35, 1.0),
    "DiamondPlate": (0.4, 1.0), "Foil": (0.25, 1.0), "CorrodedMetal": (0.7, 0.7), "Neon": (0.5, 0.0),
    "Fabric": (0.95, 0.0), "Sand": (0.85, 0.0), "Wood": (0.7, 0.0), "Concrete": (0.9, 0.0),
    "Granite": (0.7, 0.0), "Marble": (0.3, 0.0), "Slate": (0.8, 0.0), "Brick": (0.9, 0.0),
    "Pebble": (0.85, 0.0), "Cobblestone": (0.85, 0.0), "Ice": (0.1, 0.0), "Rubber": (0.9, 0.0),
    "Leather": (0.6, 0.0), "Carpet": (1.0, 0.0), "Asphalt": (0.9, 0.0), "ForceField": (0.5, 0.0),
}
_mat_cache = {}


def material(color, mat, transparency, reflectance, tex=None, sa=None, vertex_color=None, tex_is_decal=False,
             decal_color=None, uv_scale=None):
    key = (tuple(round(c, 3) for c in color), mat, round(transparency, 3), round(reflectance, 3),
           tex.name if tex else None, json.dumps(sa, sort_keys=True) if sa else None,
           tuple(vertex_color) if vertex_color else None, tex_is_decal,
           tuple(decal_color) if decal_color else None, tuple(uv_scale) if uv_scale else None)
    if key in _mat_cache:
        return _mat_cache[key]
    m = bpy.data.materials.new(f"{mat}_{len(_mat_cache)}")
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    out = nt.nodes.get("Material Output")
    rough, metal = MAT_PARAMS.get(mat, (0.6, 0.0))
    lin = [srgb_to_lin(c) for c in color] + [1.0]
    bsdf.inputs["Base Color"].default_value = lin
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    alpha = 1.0 - transparency
    if mat == "Glass":
        alpha = max(0.18, min(alpha, 0.55))
        bsdf.inputs["Coat Weight"].default_value = 1.0
        bsdf.inputs["Coat Roughness"].default_value = 0.02
    if reflectance > 0:
        bsdf.inputs["Coat Weight"].default_value = min(1.0, 0.4 + reflectance * 2)
        bsdf.inputs["Coat Roughness"].default_value = 0.03
        bsdf.inputs["Roughness"].default_value = min(rough, 0.35)
    if mat == "Neon":
        bsdf.inputs["Emission Color"].default_value = lin
        bsdf.inputs["Emission Strength"].default_value = 3.0
    uvnode = None
    if uv_scale:
        tc = nt.nodes.new("ShaderNodeTexCoord")
        mp = nt.nodes.new("ShaderNodeMapping")
        mp.inputs["Scale"].default_value = (uv_scale[0], uv_scale[1], 1)
        nt.links.new(tc.outputs["UV"], mp.inputs["Vector"])
        uvnode = mp.outputs["Vector"]
    tex_alpha_socket = None
    if tex is not None:
        ti = nt.nodes.new("ShaderNodeTexImage")
        ti.image = tex
        ti.interpolation = "Linear"
        if tex_is_decal and not uv_scale:
            ti.extension = "CLIP"
        if uvnode:
            nt.links.new(uvnode, ti.inputs["Vector"])
        col_out = ti.outputs["Color"]
        tint = decal_color or vertex_color
        if tint and any(abs(c - 1) > 1e-3 for c in tint):
            mix = nt.nodes.new("ShaderNodeMix")
            mix.data_type = "RGBA"
            mix.blend_type = "MULTIPLY"
            mix.inputs["Factor"].default_value = 1.0
            nt.links.new(col_out, mix.inputs[6])
            mix.inputs[7].default_value = [srgb_to_lin(c) for c in tint] + [1]
            col_out = mix.outputs[2]
        nt.links.new(col_out, bsdf.inputs["Base Color"])
        if mat == "Neon":
            nt.links.new(col_out, bsdf.inputs["Emission Color"])
        if tex_is_decal or img_has_alpha(tex):
            tex_alpha_socket = ti.outputs["Alpha"]
    if sa:
        alpha_mode = sa.get("AlphaMode", "Overlay")
        cm = image(sa.get("ColorMap"))
        if cm is not None:
            ti = nt.nodes.new("ShaderNodeTexImage")
            ti.image = cm
            col_out = ti.outputs["Color"]
            sa_tint = sa.get("Color") or [1, 1, 1]
            if alpha_mode == "Overlay" and img_has_alpha(cm):
                mix = nt.nodes.new("ShaderNodeMix")
                mix.data_type = "RGBA"
                nt.links.new(ti.outputs["Alpha"], mix.inputs["Factor"])
                mix.inputs[6].default_value = lin
                nt.links.new(col_out, mix.inputs[7])
                col_out = mix.outputs[2]
            elif alpha_mode == "TintMask":
                tintc = [srgb_to_lin(c) for c in sa_tint] + [1]
                mix = nt.nodes.new("ShaderNodeMix")
                mix.data_type = "RGBA"
                mix.blend_type = "MULTIPLY"
                nt.links.new(ti.outputs["Alpha"], mix.inputs["Factor"])
                nt.links.new(col_out, mix.inputs[6])
                mix.inputs[7].default_value = tintc
                col_out = mix.outputs[2]
            elif alpha_mode == "Transparency" and img_has_alpha(cm):
                tex_alpha_socket = ti.outputs["Alpha"]
            if any(abs(c - 1) > 1e-3 for c in sa_tint) and alpha_mode != "TintMask":
                mix = nt.nodes.new("ShaderNodeMix")
                mix.data_type = "RGBA"
                mix.blend_type = "MULTIPLY"
                mix.inputs["Factor"].default_value = 1.0
                nt.links.new(col_out, mix.inputs[6])
                mix.inputs[7].default_value = [srgb_to_lin(c) for c in sa_tint] + [1]
                col_out = mix.outputs[2]
            nt.links.new(col_out, bsdf.inputs["Base Color"])
        nm = image(sa.get("NormalMap"))
        if nm is not None:
            nm.colorspace_settings.name = "Non-Color"
            ti = nt.nodes.new("ShaderNodeTexImage")
            ti.image = nm
            nmap = nt.nodes.new("ShaderNodeNormalMap")
            nt.links.new(ti.outputs["Color"], nmap.inputs["Color"])
            nt.links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
        for key_, sock in (("MetalnessMap", "Metallic"), ("RoughnessMap", "Roughness")):
            im = image(sa.get(key_))
            if im is not None:
                im.colorspace_settings.name = "Non-Color"
                ti = nt.nodes.new("ShaderNodeTexImage")
                ti.image = im
                nt.links.new(ti.outputs["Color"], bsdf.inputs[sock])
    if tex_alpha_socket is not None:
        if alpha < 0.999:
            mul = nt.nodes.new("ShaderNodeMath")
            mul.operation = "MULTIPLY"
            nt.links.new(tex_alpha_socket, mul.inputs[0])
            mul.inputs[1].default_value = alpha
            nt.links.new(mul.outputs[0], bsdf.inputs["Alpha"])
        else:
            nt.links.new(tex_alpha_socket, bsdf.inputs["Alpha"])
    else:
        bsdf.inputs["Alpha"].default_value = alpha
    _mat_cache[key] = m
    _ = out
    return m


# ---------------------------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------------------------
FACE_AXES = {  # face -> (normal, right, up) in part space
    "Front": ((0, 0, -1), (-1, 0, 0), (0, 1, 0)),
    "Back": ((0, 0, 1), (1, 0, 0), (0, 1, 0)),
    "Right": ((1, 0, 0), (0, 0, -1), (0, 1, 0)),
    "Left": ((-1, 0, 0), (0, 0, 1), (0, 1, 0)),
    "Top": ((0, 1, 0), (1, 0, 0), (0, 0, -1)),
    "Bottom": ((0, -1, 0), (1, 0, 0), (0, 0, 1)),
}


def decal_quad(size, face):
    n, r, u = (np.array(v, float) for v in FACE_AXES[face])
    half = np.array(size, float) / 2
    c = n * (half + 0.004)
    w = abs(np.dot(r, size))
    h = abs(np.dot(u, size))
    pts = [c - r * w / 2 - u * h / 2, c + r * w / 2 - u * h / 2, c + r * w / 2 + u * h / 2, c - r * w / 2 + u * h / 2]
    uv = [(0, 1), (1, 1), (1, 0), (0, 0)]  # roblox (top-left origin) uv
    return np.array(pts, np.float32), np.array([[0, 1, 2], [0, 2, 3]], np.uint32), np.array(uv, np.float32), (w, h)


def decal_project(surf, size, face):
    pos, faces = surf
    n, r, u = (np.array(v, float) for v in FACE_AXES[face])
    tri = pos[faces]
    fn = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
    ln = np.linalg.norm(fn, axis=1)
    keep = (ln > 1e-12) & ((fn @ n) / np.maximum(ln, 1e-12) > 0.05)
    if not keep.any():
        return None
    sub = faces[keep]
    used, inv = np.unique(sub, return_inverse=True)
    pts = pos[used] + n * 0.003
    w = abs(float(np.dot(np.abs(r), size)))
    h = abs(float(np.dot(np.abs(u), size)))
    uv = np.stack([0.5 + (pts @ r) / max(w, 1e-6), 0.5 - (pts @ u) / max(h, 1e-6)], 1)
    return pts.astype(np.float32), inv.reshape(-1, 3).astype(np.uint32), uv.astype(np.float32), (w, h)


def build(model_id, keep_hidden=False):
    d = rbxdl.asset_dir(model_id)
    tree = json.load(open(os.path.join(d, "tree.json")))
    nodes = {n["id"]: n for n in tree["nodes"]}
    children = {}
    for n in tree["nodes"]:
        children.setdefault(n["parent"], []).append(n["id"])
    root = bpy.data.objects.new("CarRoot", None)
    bpy.context.scene.collection.objects.link(root)
    col = bpy.context.scene.collection
    stats = {"parts": 0, "visible": 0, "hidden": 0, "meshparts": 0, "mesh_missing": 0, "unions_as_box": 0,
             "decals": 0, "special_meshes": 0, "textured": 0, "surface_appearance": 0}
    seats = []
    built = []
    for n in tree["nodes"]:
        cls = n["class"]
        p = n["props"]
        if cls not in PART_CLASSES or "CFrame" not in p or "Size" not in p:
            continue
        stats["parts"] += 1
        if cls in ("VehicleSeat", "Seat"):
            seats.append(n)
        tr = float(p.get("Transparency", 0) or 0)
        kids = [nodes[c] for c in children.get(n["id"], [])]
        decals = [k for k in kids if k["class"] in ("Decal", "Texture") and float(k["props"].get("Transparency", 0) or 0) < 0.99]
        if tr >= 0.98 and not keep_hidden and not decals:
            stats["hidden"] += 1
            continue
        size = np.array(p["Size"], float)
        M = cf_matrix(p["CFrame"])
        color = p.get("Color", [0.64, 0.64, 0.65])
        matname = p.get("Material", "Plastic")
        refl = float(p.get("Reflectance", 0) or 0)
        sm = next((k for k in kids if k["class"] in ("SpecialMesh", "FileMesh", "BlockMesh", "CylinderMesh")), None)
        sa = next((k["props"] for k in kids if k["class"] == "SurfaceAppearance"), None)
        tex = None
        vcol = None
        mesh = None
        local = None  # matrix applied after CFrame (part space)
        surf = None  # (pos, faces) of the visible surface in part space, for projecting decals
        if cls == "MeshPart":
            stats["meshparts"] += 1
            mid = rbxdl.parse_asset_id(p.get("MeshId"))
            fm = file_mesh(mid) if mid else None
            if fm is None:
                stats["mesh_missing"] += 1
                mesh = prim("box")
                local = scale_matrix(size)
            else:
                mesh, lo, hi, arr = fm
                ext = hi - lo
                init = np.array(p.get("InitialSize") or ext, float)
                ref = np.where(init > 1e-5, init, ext)
                sc = np.where(ref > 1e-5, size / np.maximum(ref, 1e-9), 1.0)
                local = scale_matrix(sc) @ trans_matrix(-(lo + hi) / 2)
                surf = ((arr[0] - (lo + hi) / 2) * sc, arr[1])
            tex = image(p.get("TextureID"))
        elif sm is not None and sm["class"] in ("SpecialMesh", "FileMesh"):
            stats["special_meshes"] += 1
            sp = sm["props"]
            mt = sp.get("MeshType", "FileMesh") if sm["class"] == "SpecialMesh" else "FileMesh"
            scale = np.array(sp.get("Scale", [1, 1, 1]), float)
            off = np.array(sp.get("Offset", [0, 0, 0]), float)
            vcol = sp.get("VertexColor")
            if mt == "FileMesh":
                mid = rbxdl.parse_asset_id(sp.get("MeshId"))
                fm = file_mesh(mid) if mid else None
                if fm is None:
                    stats["mesh_missing"] += 1
                    mesh, local = prim("box"), trans_matrix(off) @ scale_matrix(size * scale)
                else:
                    mesh = fm[0]
                    local = trans_matrix(off) @ scale_matrix(scale)
                    surf = (fm[3][0] * scale + off, fm[3][1])
                tex = image(sp.get("TextureId"))
            else:
                kind = {"Brick": "box", "Wedge": "wedge", "Cylinder": "cyl_x", "Sphere": "ball", "Head": "cyl_y",
                        "Torso": "box"}.get(mt, "box")
                mesh = prim(kind)
                local = trans_matrix(off) @ scale_matrix(size * scale)
        else:
            if sm is not None:  # BlockMesh / CylinderMesh
                sp = sm["props"]
                scale = np.array(sp.get("Scale", [1, 1, 1]), float)
                off = np.array(sp.get("Offset", [0, 0, 0]), float)
                kind = "cyl_y" if sm["class"] == "CylinderMesh" else "box"
                mesh, local = prim(kind), trans_matrix(off) @ scale_matrix(size * scale)
            elif cls in ("UnionOperation", "IntersectOperation"):
                stats["unions_as_box"] += 1
                mesh, local = prim("box"), scale_matrix(size)
            elif cls == "WedgePart":
                mesh, local = prim("wedge"), scale_matrix(size)
            elif cls == "CornerWedgePart":
                mesh, local = prim("cornerwedge"), scale_matrix(size)
            else:
                shape = p.get("Shape", "Block")
                if shape == "Cylinder":
                    dd = min(size[1], size[2])
                    mesh, local = prim("cyl_x"), scale_matrix((size[0], dd, dd))
                elif shape == "Ball":
                    dd = float(min(size))
                    mesh, local = prim("ball"), scale_matrix((dd, dd, dd))
                elif shape == "Wedge":
                    mesh, local = prim("wedge"), scale_matrix(size)
                elif shape == "CornerWedge":
                    mesh, local = prim("cornerwedge"), scale_matrix(size)
                else:
                    mesh, local = prim("box"), scale_matrix(size)
        world = R2B @ M
        if tr < 0.98 or keep_hidden:
            stats["visible"] += 1
            if tex is not None:
                stats["textured"] += 1
            if sa:
                stats["surface_appearance"] += 1
            ob = bpy.data.objects.new(n["name"][:50], mesh)
            ob.matrix_world = world @ local
            ob["rbx_path"] = n["path"]
            ob["rbx_class"] = cls
            mtl = material(color, matname, min(tr, 0.98), refl, tex=tex, sa=sa, vertex_color=vcol)
            if len(ob.data.materials) == 0:  # mesh data is shared; materials are linked per object
                ob.data.materials.append(None)
            ob.material_slots[0].link = "OBJECT"
            ob.material_slots[0].material = mtl
            col.objects.link(ob)
            ob.parent = root
            built.append(ob)
        # decals / textures on faces
        for k in decals:
            kp = k["props"]
            img = image(kp.get("Texture"))
            if img is None:
                continue
            face = kp.get("Face", "Front")
            if face not in FACE_AXES:
                continue
            if surf is not None:
                # Roblox projects a decal along the face axis onto every triangle facing that way
                proj = decal_project(surf, size, face)
                if proj is None:
                    continue
                pts, fcs, uv, (w, h) = proj
            else:
                pts, fcs, uv, (w, h) = decal_quad(size, face)
            me = mesh_from_arrays(f"decal_{k['id']}", pts, fcs, uv, None, smooth=surf is not None)
            uvs = None
            if k["class"] == "Texture":
                su, sv = float(kp.get("StudsPerTileU", 2) or 2), float(kp.get("StudsPerTileV", 2) or 2)
                uvs = (w / max(su, 1e-3), h / max(sv, 1e-3))
            mtl = material([1, 1, 1], "SmoothPlastic", float(kp.get("Transparency", 0) or 0), 0, tex=img,
                           tex_is_decal=True, decal_color=kp.get("Color3"), uv_scale=uvs)
            me.materials.append(mtl)
            ob = bpy.data.objects.new(f"Decal_{k['name'][:40]}", me)
            ob.matrix_world = world
            ob["rbx_path"] = k["path"]
            ob["rbx_class"] = k["class"]
            col.objects.link(ob)
            ob.parent = root
            built.append(ob)
            stats["decals"] += 1
    return root, built, seats, stats, tree


def find_forward(seats, tree):
    """-> (forward unit vector in Roblox world, method string)"""
    pref = sorted(seats, key=lambda s: (s["class"] != "VehicleSeat", "drive" not in s["name"].lower()))
    for s in pref:
        cf = s["props"]["CFrame"]
        look = -np.array([cf[5], cf[8], cf[11]], float)
        look[1] = 0
        if np.linalg.norm(look) > 0.5:
            return look / np.linalg.norm(look), f"seat:{s['name']}"
    heads, tails = [], []
    for n in tree["nodes"]:
        nm = n["name"].lower()
        cf = n["props"].get("CFrame")
        if not cf or n["class"] not in PART_CLASSES:
            continue
        if "headlight" in nm or nm.startswith("head") or "front" in nm:
            heads.append(cf[:3])
        elif "tail" in nm or "brake" in nm or "rear" in nm or "reverse" in nm:
            tails.append(cf[:3])
    if heads and tails:
        v = np.mean(heads, 0) - np.mean(tails, 0)
        v[1] = 0
        if np.linalg.norm(v) > 0.5:
            return v / np.linalg.norm(v), "light-names"
    return np.array([0, 0, -1.0]), "default(-Z)"


def world_bbox(objs):
    pts = []
    for o in objs:
        mw = o.matrix_world
        for c in o.bound_box:
            pts.append(mw @ Vector(c))
    a = np.array([tuple(p) for p in pts])
    return a.min(0), a.max(0)


def setup_render(samples, res):
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = samples
    sc.cycles.use_denoising = True
    try:
        sc.cycles.denoiser = "OPENIMAGEDENOISE"
    except Exception:  # noqa: BLE001
        pass
    sc.cycles.max_bounces = 6
    sc.cycles.transparent_max_bounces = 24
    sc.cycles.use_adaptive_sampling = True
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = False
    sc.render.image_settings.file_format = "PNG"
    try:
        sc.view_settings.view_transform = "AgX"
        sc.view_settings.look = "AgX - Medium High Contrast"
    except Exception:  # noqa: BLE001
        pass
    # world: simple sky/horizon/ground gradient (gives readable reflections on paint)
    w = bpy.data.worlds.new("World")
    sc.world = w
    w.use_nodes = True
    nt = w.node_tree
    bg = nt.nodes.get("Background")
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    nt.links.new(tc.outputs["Generated"], sep.inputs[0])
    mr = nt.nodes.new("ShaderNodeMapRange")
    mr.inputs["From Min"].default_value = -1
    mr.inputs["From Max"].default_value = 1
    nt.links.new(sep.outputs["Z"], mr.inputs["Value"])
    nt.links.new(mr.outputs["Result"], ramp.inputs["Fac"])
    els = ramp.color_ramp.elements
    els[0].position, els[0].color = 0.0, (0.06, 0.06, 0.06, 1)
    els[1].position, els[1].color = 1.0, (0.25, 0.42, 0.75, 1)
    e = els.new(0.49)
    e.color = (0.16, 0.15, 0.14, 1)
    e = els.new(0.505)
    e.color = (0.85, 0.88, 0.92, 1)
    nt.links.new(ramp.outputs["Color"], bg.inputs["Color"])
    bg.inputs["Strength"].default_value = 0.9
    sun = bpy.data.lights.new("Sun", "SUN")
    sun.energy = 3.2
    sun.angle = math.radians(2.0)
    so = bpy.data.objects.new("Sun", sun)
    so.rotation_euler = (math.radians(50), 0, math.radians(-35))
    sc.collection.objects.link(so)
    # ground
    gm = bpy.data.meshes.new("ground")
    s = 400
    gm.from_pydata([(-s, -s, 0), (s, -s, 0), (s, s, 0), (-s, s, 0)], [], [(0, 1, 2, 3)])
    g = bpy.data.objects.new("Ground", gm)
    gmat = bpy.data.materials.new("ground")
    gmat.use_nodes = True
    b = gmat.node_tree.nodes.get("Principled BSDF")
    b.inputs["Base Color"].default_value = (0.16, 0.16, 0.165, 1)
    b.inputs["Roughness"].default_value = 0.85
    gm.materials.append(gmat)
    sc.collection.objects.link(g)


def look_at(cam_obj, target):
    d = Vector(target) - cam_obj.location
    cam_obj.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()


def render_views(model_id, objs, out_dir, samples, res):
    sc = bpy.context.scene
    lo, hi = world_bbox(objs)
    ctr = (lo + hi) / 2
    ext = hi - lo
    cam = bpy.data.cameras.new("Cam")
    co = bpy.data.objects.new("Cam", cam)
    sc.collection.objects.link(co)
    sc.camera = co
    aspect = res[0] / res[1]
    outs = {}
    # 3/4 front (front faces -Y): camera front-left, slightly high
    cam.type = "PERSP"
    cam.lens = 50
    cam.sensor_width = 36
    r = 0.5 * float(np.linalg.norm(ext))
    fov_v = 2 * math.atan(cam.sensor_width / aspect / 2 / cam.lens)
    dist = r / math.sin(fov_v / 2) * 0.66
    az, el = math.radians(-35), math.radians(14)  # from front (-Y) rotate toward -X (car's left... viewer)
    dirv = Vector((math.sin(az) * math.cos(el), -math.cos(az) * math.cos(el), math.sin(el)))
    tgt = Vector((ctr[0], ctr[1], ctr[2] * 0.85))
    co.location = tgt + dirv * dist
    look_at(co, tgt)
    sc.render.filepath = os.path.join(out_dir, "preview_34.png")
    bpy.ops.render.render(write_still=True)
    outs["34"] = sc.render.filepath
    # side (orthographic) from the car's left (+X side when front is -Y? left of driver = -X)
    cam.type = "ORTHO"
    cam.ortho_scale = max(ext[1], ext[2] * aspect) * 1.12
    co.location = Vector((ctr[0] - 60 - ext[0], ctr[1], ctr[2] + 0.5))
    look_at(co, Vector((ctr[0], ctr[1], ctr[2])))
    sc.render.filepath = os.path.join(out_dir, "preview_side.png")
    bpy.ops.render.render(write_still=True)
    outs["side"] = sc.render.filepath
    return outs, (lo, hi)


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    model_id = int(argv[0])
    samples = int(argv[argv.index("--samples") + 1]) if "--samples" in argv else 32
    res = tuple(int(x) for x in argv[argv.index("--res") + 1].split("x")) if "--res" in argv else (960, 540)
    samples = min(samples, 48)
    res = (min(res[0], 960), min(res[1], 540))
    reset_scene()
    root, objs, seats, stats, tree = build(model_id, keep_hidden="--keep-hidden" in argv)
    if not objs:
        print("nothing visible to render")
        return 2
    fwd, method = find_forward(seats, tree)
    # rotate so that roblox forward -> blender -Y.  roblox fwd (fx, 0, fz) maps to blender (fx, -fz, 0)
    fb = Vector((fwd[0], -fwd[2], 0))
    ang = math.atan2(fb.y, fb.x) - math.atan2(-1, 0)
    bpy.context.view_layer.update()
    root.rotation_euler = (0, 0, -ang)
    bpy.context.view_layer.update()
    lo, hi = world_bbox(objs)
    root.location = Vector((-(lo[0] + hi[0]) / 2, -(lo[1] + hi[1]) / 2, -lo[2]))
    bpy.context.view_layer.update()
    lo, hi = world_bbox(objs)
    stats["forward_method"] = method
    stats["bbox_studs_LxWxH"] = [round(float(hi[1] - lo[1]), 2), round(float(hi[0] - lo[0]), 2), round(float(hi[2] - lo[2]), 2)]
    out_dir = rbxdl.asset_dir(model_id)
    if "--no-render" not in argv:
        setup_render(samples, res)
        outs, _ = render_views(model_id, objs, out_dir, samples, res)
        stats["renders"] = {k: os.path.relpath(v, rbxdl.ROOT) for k, v in outs.items()}
    if "--glb" in argv:
        for o in bpy.data.objects:
            o.select_set(o in objs)
        bpy.ops.export_scene.gltf(filepath=os.path.join(out_dir, "rebuilt.glb"), use_selection=True, export_format="GLB",
                                  export_yup=True, export_apply=False)
    if "--blend" in argv:
        bpy.ops.wm.save_as_mainfile(filepath=os.path.join(out_dir, "rebuilt.blend"))
    json.dump(stats, open(os.path.join(out_dir, "build.json"), "w"), indent=1)
    print(json.dumps(stats))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
