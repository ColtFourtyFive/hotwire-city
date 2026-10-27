"""Small shared helpers: logging, scene reset, mesh numpy access, keyword matching."""
from __future__ import annotations

import math
import os
import re
import sys
import time

import bpy
import numpy as np

_T0 = time.time()
VERBOSE = True


def log(*a):
    if VERBOSE:
        print(f"[carpipe {time.time() - _T0:6.1f}s]", *a, flush=True)


def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.unit_settings.system = "NONE"
    return sc


def mesh_objects(scene=None):
    scene = scene or bpy.context.scene
    return [o for o in scene.objects if o.type == "MESH"]


def tri_count(obj) -> int:
    me = obj.data
    if not me.polygons:
        return 0
    n = np.empty(len(me.polygons), dtype=np.int32)
    me.polygons.foreach_get("loop_total", n)
    return int((n - 2).clip(min=0).sum())


def verts_np(me) -> np.ndarray:
    co = np.empty(len(me.vertices) * 3, dtype=np.float64)
    me.vertices.foreach_get("co", co)
    return co.reshape(-1, 3)


def set_verts_np(me, co: np.ndarray):
    me.vertices.foreach_set("co", co.astype(np.float32).ravel())
    me.update()


def faces_np(me):
    """Returns (loop_start, loop_total, loop_vert_index, face_center, face_normal, face_area, material_index)."""
    nf = len(me.polygons)
    ls = np.empty(nf, dtype=np.int64)
    lt = np.empty(nf, dtype=np.int64)
    me.polygons.foreach_get("loop_start", ls)
    me.polygons.foreach_get("loop_total", lt)
    lv = np.empty(len(me.loops), dtype=np.int64)
    me.loops.foreach_get("vertex_index", lv)
    cen = np.empty(nf * 3)
    me.polygons.foreach_get("center", cen)
    nor = np.empty(nf * 3)
    me.polygons.foreach_get("normal", nor)
    area = np.empty(nf)
    me.polygons.foreach_get("area", area)
    mi = np.empty(nf, dtype=np.int64)
    me.polygons.foreach_get("material_index", mi)
    return ls, lt, lv, cen.reshape(-1, 3), nor.reshape(-1, 3), area, mi


def norm_name(s: str) -> str:
    s = s or ""
    s = re.sub(r"([a-z])([A-Z])", r"\1_\2", s)  # camelCase -> camel_Case
    return re.sub(r"[^a-z0-9]+", "_", s.lower()).strip("_")


def kw_match(name: str, patterns) -> str | None:
    """Return the first regex in `patterns` that matches the normalised name (word-ish boundaries)."""
    n = "_" + norm_name(name) + "_"
    for p in patterns:
        if re.search(p, n):
            return p
    return None


def srgb_to_lin(c):
    c = np.asarray(c, dtype=np.float64)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def lin_to_srgb(c):
    c = np.clip(np.asarray(c, dtype=np.float64), 0, None)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055)


def rgb_to_hsv(rgb):
    r, g, b = [float(x) for x in rgb[:3]]
    mx, mn = max(r, g, b), min(r, g, b)
    v = mx
    s = 0.0 if mx <= 1e-6 else (mx - mn) / mx
    if mx - mn < 1e-6:
        h = 0.0
    elif mx == r:
        h = ((g - b) / (mx - mn)) % 6
    elif mx == g:
        h = (b - r) / (mx - mn) + 2
    else:
        h = (r - g) / (mx - mn) + 4
    return (h * 60.0) % 360.0, s, v


def select_only(objs, active=None):
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    for o in objs:
        o.select_set(True)
    if active is not None or objs:
        bpy.context.view_layer.objects.active = active or objs[0]


def apply_transforms(objs):
    select_only(objs)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)


def ensure_dir(p):
    os.makedirs(p, exist_ok=True)
    return p


def fmt3(v, nd=3):
    return [round(float(x), nd) for x in v]
