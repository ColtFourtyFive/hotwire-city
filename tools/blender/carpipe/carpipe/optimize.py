"""Split the classified working mesh into role objects, clean, decimate to the Roblox triangle budget,
and unwrap a fresh atlas UV for baking."""
from __future__ import annotations

import math
import os
import time

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


def decimate_meshlab(ob, target_tris):
    """Quadric edge collapse via pymeshlab (ignores UV seams/boundaries; fine because we re-bake)."""
    import pymeshlab

    triangulate(ob)
    me = ob.data
    v = np.empty(len(me.vertices) * 3)
    me.vertices.foreach_get("co", v)
    f = np.empty(len(me.polygons) * 3, dtype=np.int64)
    me.polygons.foreach_get("vertices", f)
    ms = pymeshlab.MeshSet()
    ms.add_mesh(pymeshlab.Mesh(vertex_matrix=v.reshape(-1, 3), face_matrix=f.reshape(-1, 3).astype(np.int32)))
    ms.meshing_decimation_quadric_edge_collapse(targetfacenum=int(target_tris), preserveboundary=False,
                                                preservenormal=True, preservetopology=False, optimalplacement=True,
                                                planarquadric=True, qualitythr=0.3, autoclean=True)
    m = ms.current_mesh()
    nv = m.vertex_matrix()
    nf = m.face_matrix()
    mats = [s.material for s in ob.material_slots]
    new = bpy.data.meshes.new(me.name)
    new.from_pydata(nv.tolist(), [], nf.tolist())
    for mt in mats:
        new.materials.append(mt)
    new.update()
    old = ob.data
    ob.data = new
    bpy.data.meshes.remove(old)
    return tri_count(ob)


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
    if tri_count(ob) > 1.03 * target_tris:  # collapse stalled (open boundaries, UV seams): quadric fallback
        before = tri_count(ob)
        decimate_meshlab(ob, int(target_tris * 0.98))
        log(f"{ob.name}: blender decimate stalled at {before}, pymeshlab -> {tri_count(ob)}")
    return tri_count(ob)


def recalc_normals(ob):
    """Make face winding consistent and outward per connected part.  Roblox renders single-sided, and Cycles'
    selected-to-active bake casts along the low-poly normal, so inverted faces bake black AND vanish in-game."""
    me = ob.data
    before = np.empty(len(me.polygons) * 3)
    me.polygons.foreach_get("normal", before)
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    me.update()
    after = np.empty(len(me.polygons) * 3)
    me.polygons.foreach_get("normal", after)
    dots = (before.reshape(-1, 3) * after.reshape(-1, 3)).sum(1)
    return int((dots < 0).sum())


def clean_degenerate(ob, dist):
    """Zero-area / duplicate faces make smart_project emit huge empty UV islands that waste the atlas."""
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.dissolve_degenerate(bm, edges=bm.edges, dist=dist)
    bad = [f for f in bm.faces if f.calc_area() < dist * dist * 0.01]
    # coincident duplicates (double-sided shells modelled as two faces on the same vertices): they overlap in UV
    # space and fight in the bake.  Keep the one facing away from the part's centre.
    seen = {}
    cen = sum((v.co for v in bm.verts), bm.verts[0].co.copy() * 0) / max(len(bm.verts), 1) if bm.verts else None
    for f in bm.faces:
        if f in bad:
            continue
        key = tuple(sorted(v.index for v in f.verts))
        g = seen.get(key)
        if g is None:
            seen[key] = f
            continue
        fo = (f.calc_center_median() - cen).dot(f.normal)
        go = (g.calc_center_median() - cen).dot(g.normal)
        if fo > go:
            bad.append(g)
            seen[key] = f
        else:
            bad.append(f)
    if bad:
        bmesh.ops.delete(bm, geom=list(set(bad)), context="FACES")
    loose = [v for v in bm.verts if not v.link_faces]
    if loose:
        bmesh.ops.delete(bm, geom=loose, context="VERTS")
    bm.to_mesh(ob.data)
    bm.free()
    ob.data.validate(clean_customdata=False)
    ob.data.update()


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
    clean_degenerate(lo, length * 2e-4)
    n_flip = recalc_normals(lo)
    if n_flip:
        log(f"{name}: {n_flip} faces re-oriented outward")
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
                             correct_aspect=False, scale_to_bounds=False)
    if os.environ.get("CARPIPE_UVDEBUG"):
        bpy.ops.object.mode_set(mode="OBJECT")
        log("after smart_project", [round(uv_utilisation(o), 3) for o in objs], [o.data.uv_layers.active.name for o in objs])
        bpy.ops.object.mode_set(mode="EDIT")
    t0 = time.time()
    # smart_project already packs all selected objects into one 0-1 space (~0.7 texel use). A second
    # pack_islands(AABB) after shrinking ground-facing islands measured WORSE (0.3-0.5), and CONVEX/CONCAVE
    # packing costs 20-40 s on interiors, so the smart_project layout is kept as is.
    if os.environ.get("CARPIPE_PACK"):
        _weight_islands(objs)
        bpy.ops.uv.pack_islands(udim_source="CLOSEST_UDIM", rotate=True, margin_method="FRACTION", margin=margin,
                                shape_method=os.environ["CARPIPE_PACK"])
    bpy.ops.object.mode_set(mode="OBJECT")
    log(f"atlas uv {[o.name for o in objs]} packed in {time.time() - t0:.1f}s, "
        f"texel use {sum(uv_utilisation(o) for o in objs):.2f}")


def uv_utilisation(o, layer="atlas"):
    me = o.data
    uvl = me.uv_layers.get(layer)
    if uvl is None or not len(me.loops):
        return 0.0
    uv = np.empty(len(me.loops) * 2)
    uvl.data.foreach_get("uv", uv)
    uv = uv.reshape(-1, 2)
    ls = np.empty(len(me.polygons), dtype=np.int64)
    lt = np.empty(len(me.polygons), dtype=np.int64)
    me.polygons.foreach_get("loop_start", ls)
    me.polygons.foreach_get("loop_total", lt)
    a = 0.0
    for s0, n in zip(ls, lt):  # shoelace per polygon
        p = uv[s0:s0 + n]
        a += 0.5 * abs(np.dot(p[:, 0], np.roll(p[:, 1], 1)) - np.dot(p[:, 1], np.roll(p[:, 0], 1)))
    return float(a)


def _weight_islands(objs, down=0.3):
    """Shrink UV islands that face the ground (underbody, insides of arches) so visible parts get the texels.
    Runs in edit mode; pack_islands afterwards keeps these relative scales."""
    from bpy_extras import bmesh_utils
    for o in objs:
        bm = bmesh.from_edit_mesh(o.data)
        uvl = bm.loops.layers.uv.active
        if uvl is None:
            continue
        for isl in bmesh_utils.bmesh_linked_uv_islands(bm, uvl):
            nz = 0.0
            ar = 0.0
            for f in isl:
                a = f.calc_area()
                nz += f.normal.z * a
                ar += a
            if ar <= 0 or nz / ar > -0.5:
                continue
            pts = [l[uvl].uv.copy() for f in isl for l in f.loops]
            cx = sum(p.x for p in pts) / len(pts)
            cy = sum(p.y for p in pts) / len(pts)
            for f in isl:
                for l in f.loops:
                    uv = l[uvl].uv
                    uv.x = cx + (uv.x - cx) * down
                    uv.y = cy + (uv.y - cy) * down
        bmesh.update_edit_mesh(o.data)


def keep_only_uv(ob, name="atlas"):
    me = ob.data
    for l in list(me.uv_layers):
        if l.name != name:
            me.uv_layers.remove(l)
    if me.uv_layers:
        me.uv_layers[0].name = "UVMap"
