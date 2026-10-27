"""Split the classified working mesh into role objects, clean, decimate to the Roblox triangle budget,
and unwrap a fresh atlas UV for baking."""
from __future__ import annotations

import math

import bmesh
import bpy
import numpy as np

from .analyze import BODY, BODY2, DISCARD, GLASS, INTERIOR, LIGHT_F, LIGHT_R, TRIM, WHEEL0
from .util import log, select_only, tri_count

# default triangle budgets (sum 17.6k <= 18k car budget; every MeshPart <= 20k)
BUDGET = {"Body": 7000, "Body2": 1000, "Glass": 700, "LightsFront": 450, "LightsRear": 450, "Trim": 2600,
          "Interior": 1500, "Wheel": 900}
CAR_BUDGET = 18000


def extract(src, face_mask: np.ndarray, name: str):
    me = src.data.copy()
    me.name = name
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.faces.ensure_lookup_table()
    dele = [f for f, keep in zip(bm.faces, face_mask) if not keep]
    if dele:
        bmesh.ops.delete(bm, geom=dele, context="FACES")
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    # drop unused material slots
    used = set(np.unique(_mat_idx(me)).tolist()) if len(me.polygons) else set()
    select_only([ob])
    try:
        bpy.ops.object.material_slot_remove_unused()
    except Exception:
        pass
    _ = used
    return ob


def _mat_idx(me):
    a = np.empty(len(me.polygons), dtype=np.int32)
    me.polygons.foreach_get("material_index", a)
    return a


def split_roles(car):
    """Returns dict name -> object (high-res, still with source materials)."""
    out = {}
    fr = car.frole
    groups = {"Body": fr == BODY, "Body2": fr == BODY2, "Glass": fr == GLASS, "LightsFront": fr == LIGHT_F,
              "LightsRear": fr == LIGHT_R, "Trim": fr == TRIM, "Interior": fr == INTERIOR}
    for wi, w in enumerate(getattr(car, "wheels", [])):
        groups[w["name"]] = fr == WHEEL0 + wi
    for name, mask in groups.items():
        if mask.sum() == 0:
            continue
        ob = extract(car.obj, mask, name + "_hi")
        out[name] = ob
        log(f"split {name}: {tri_count(ob)} tris")
    return out


def weld(ob, dist):
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=dist)
    bmesh.ops.dissolve_degenerate(bm, edges=bm.edges, dist=dist * 0.1)
    bm.to_mesh(ob.data)
    bm.free()
    ob.data.update()


def drop_small_islands(ob, min_diag, keep_frac=0.0):
    """Remove loose parts whose bbox diagonal is below `min_diag` (bolts, tiny badges) to free budget."""
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bm.faces.ensure_lookup_table()
    seen = set()
    kill = []
    for f in bm.faces:
        if f.index in seen:
            continue
        stack = [f]
        comp = []
        seen.add(f.index)
        while stack:
            g = stack.pop()
            comp.append(g)
            for e in g.edges:
                for h in e.link_faces:
                    if h.index not in seen:
                        seen.add(h.index)
                        stack.append(h)
        pts = np.array([v.co[:] for g in comp for v in g.verts])
        if np.linalg.norm(pts.max(0) - pts.min(0)) < min_diag:
            kill.extend(comp)
    if kill:
        bmesh.ops.delete(bm, geom=list(set(kill)), context="FACES")
    bm.to_mesh(ob.data)
    bm.free()
    return len(kill)


def decimate(ob, target_tris, symmetric=False):
    t = tri_count(ob)
    if t <= target_tris:
        return t
    for attempt in range(3):
        ratio = max(0.002, target_tris / max(tri_count(ob), 1) * (0.97 if attempt else 1.0))
        m = ob.modifiers.new("dec", "DECIMATE")
        m.decimate_type = "COLLAPSE"
        m.ratio = ratio
        m.use_collapse_triangulate = True
        if symmetric:
            m.use_symmetry = True
            m.symmetry_axis = "X"
        select_only([ob])
        bpy.ops.object.modifier_apply(modifier=m.name)
        if tri_count(ob) <= target_tris:
            break
    return tri_count(ob)


def triangulate(ob):
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.triangulate(bm, faces=bm.faces, quad_method="BEAUTY", ngon_method="BEAUTY")
    bm.to_mesh(ob.data)
    bm.free()


def smooth_by_angle(ob, deg=40.0):
    select_only([ob])
    try:
        bpy.ops.object.shade_smooth_by_angle(angle=math.radians(deg), keep_sharp_edges=False)
    except TypeError:
        bpy.ops.object.shade_smooth_by_angle(angle=math.radians(deg))


def make_low(hi, name, budget, length, symmetric=False):
    lo = hi.copy()
    lo.data = hi.data.copy()
    lo.name = name
    lo.data.name = name
    bpy.context.scene.collection.objects.link(lo)
    # custom split normals from the importer would fight decimation
    if lo.data.has_custom_normals:
        select_only([lo])
        bpy.ops.mesh.customdata_custom_splitnormals_clear()
    weld(lo, length * 1e-4)
    t0 = tri_count(lo)
    if t0 > 2.5 * budget:  # very dense part: drop crumbs first
        n = drop_small_islands(lo, length * 0.012)
        if n:
            log(f"{name}: dropped {n} faces of tiny parts")
    t = decimate(lo, budget, symmetric=symmetric)
    triangulate(lo)
    smooth_by_angle(lo)
    log(f"low {name}: {t0} -> {tri_count(lo)} tris (budget {budget})")
    return lo


def atlas_uv(objs, margin=0.004, angle=60.0):
    """Smart-project + pack a fresh 'atlas' UV on all given objects together (shared texture space)."""
    for o in objs:
        me = o.data
        uv = me.uv_layers.get("atlas") or me.uv_layers.new(name="atlas")
        me.uv_layers.active = uv
    select_only(objs, objs[0])
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(angle), island_margin=margin, area_weight=0.0,
                             correct_aspect=True, scale_to_bounds=False)
    try:
        bpy.ops.uv.pack_islands(udim_source="CLOSEST_UDIM", rotate=True, margin_method="FRACTION", margin=margin,
                                shape_method="CONCAVE")
    except TypeError:
        bpy.ops.uv.pack_islands(rotate=True, margin=margin)
    bpy.ops.object.mode_set(mode="OBJECT")


def keep_only_uv(ob, name="atlas"):
    me = ob.data
    for l in list(me.uv_layers):
        if l.name != name:
            me.uv_layers.remove(l)
    if me.uv_layers:
        me.uv_layers[0].name = "UVMap"
