"""bpy helpers: scene reset, mesh objects from numpy data, materials."""
from __future__ import annotations

import bpy
import bmesh
import numpy as np


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def mesh_object(name, verts, faces, mat_idx=None, materials=(), smooth=True, collection=None):
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(map(float, v)) for v in verts], [], [tuple(f) for f in faces])
    me.validate(clean_customdata=False)
    for m in materials:
        me.materials.append(m)
    if mat_idx is not None and len(me.polygons) == len(mat_idx):
        me.polygons.foreach_set("material_index", np.asarray(mat_idx, dtype=np.int32))
    me.update()
    ob = bpy.data.objects.new(name, me)
    (collection or bpy.context.scene.collection).objects.link(ob)
    if smooth:
        me.shade_smooth()
    return ob


def bm_to_object(name, bm, materials=(), smooth=True, collection=None):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    for m in materials:
        me.materials.append(m)
    ob = bpy.data.objects.new(name, me)
    (collection or bpy.context.scene.collection).objects.link(ob)
    if smooth:
        me.shade_smooth()
    return ob


def tri_count(ob):
    me = ob.data
    me.calc_loop_triangles()
    return len(me.loop_triangles)
