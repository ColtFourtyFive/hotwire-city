"""Import ANY car model file into a clean, flat list of mesh objects.

Supported: .glb .gltf .fbx .obj .blend .usd/.usda/.usdc/.usdz .ply .stl .abc, and via pymeshlab (geometry only)
.dae .3ds .off .wrl .x3d.  After import:
  * modifiers applied (subdivision capped), instances realised, curves/text converted to mesh
  * parents cleared with transforms kept and baked into vertices
  * every mesh object carries `cp_path` = its own name + ancestor names (for keyword classification)
  * cameras / lights / empties / armatures removed (armature deform is applied first)
  * materials without textures get textures auto-discovered from files next to the model (name match)
"""
from __future__ import annotations

import difflib
import os
import re

import bpy

from .util import log, norm_name, select_only

IMG_EXT = (".png", ".jpg", ".jpeg", ".bmp", ".tga", ".tif", ".tiff", ".webp", ".dds")


def _import_blend(path):
    with bpy.data.libraries.load(path, link=False) as (src, dst):
        dst.objects = list(src.objects)
    coll = bpy.context.scene.collection
    for o in dst.objects:
        if o is not None and o.name not in coll.objects:
            coll.objects.link(o)


def _import_via_pymeshlab(path):
    import tempfile

    import pymeshlab

    ms = pymeshlab.MeshSet()
    ms.load_new_mesh(path)
    tmp = os.path.join(tempfile.mkdtemp(prefix="carpipe_"), "conv.obj")
    ms.save_current_mesh(tmp)
    bpy.ops.wm.obj_import(filepath=tmp)


def import_any(path: str, opts: dict | None = None):
    opts = opts or {}
    ext = os.path.splitext(path)[1].lower()
    before = set(bpy.data.objects)
    if ext in (".glb", ".gltf"):
        bpy.ops.import_scene.gltf(filepath=path, merge_vertices=False)
    elif ext == ".fbx":
        try:
            bpy.ops.import_scene.fbx(filepath=path, use_custom_normals=True, automatic_bone_orientation=False)
        except Exception as e:  # fall back to the new native importer if the legacy one is missing
            log("legacy fbx importer failed:", e)
            bpy.ops.wm.fbx_import(filepath=path)
    elif ext == ".obj":
        bpy.ops.wm.obj_import(filepath=path, use_split_objects=True, use_split_groups=True,
                              forward_axis=opts.get("obj_forward", "NEGATIVE_Z"), up_axis=opts.get("obj_up", "Y"))
    elif ext == ".blend":
        _import_blend(path)
    elif ext in (".usd", ".usda", ".usdc", ".usdz"):
        bpy.ops.wm.usd_import(filepath=path)
    elif ext == ".ply":
        bpy.ops.wm.ply_import(filepath=path)
    elif ext == ".stl":
        bpy.ops.wm.stl_import(filepath=path)
    elif ext == ".abc":
        bpy.ops.wm.alembic_import(filepath=path)
    elif ext in (".dae", ".3ds", ".off", ".wrl", ".x3d"):
        _import_via_pymeshlab(path)
    else:
        raise ValueError(f"unsupported model format: {ext}")
    new = [o for o in bpy.data.objects if o not in before]
    log(f"imported {os.path.basename(path)}: {len(new)} objects")
    return new


def _ancestors(o):
    out = []
    p = o.parent
    while p is not None:
        out.append(p.name)
        p = p.parent
    return out


def flatten(subsurf_cap: int = 1):
    """Make every renderable thing a standalone mesh object with identity transform."""
    scene = bpy.context.scene
    vl = bpy.context.view_layer
    # unhide everything that could be relevant (hidden objects are often LODs/collision -> handled later by name)
    for o in scene.objects:
        o.hide_set(False)
        o.hide_viewport = False
    # realise collection instances
    inst = [o for o in scene.objects if o.instance_type != "NONE" and o.type == "EMPTY" and o.instance_collection]
    if inst:
        select_only(inst)
        bpy.ops.object.duplicates_make_real(use_base_parent=True, use_hierarchy=True)
    # record hierarchy path names before we unparent
    for o in scene.objects:
        o["cp_path"] = " / ".join([o.name] + _ancestors(o))
        if o.data is not None and hasattr(o.data, "name"):
            o["cp_path"] += " / " + o.data.name
    # cap subdivision so a hand-made .blend doesn't explode
    for o in scene.objects:
        for m in getattr(o, "modifiers", []):
            if m.type == "SUBSURF":
                m.levels = min(m.levels, subsurf_cap)
                m.render_levels = min(m.render_levels, subsurf_cap)
            if m.type in ("ARMATURE",):
                pass
    # convert curves/text/surfaces with geometry into meshes; apply modifiers via evaluated copies
    deps = bpy.context.evaluated_depsgraph_get()
    convert = [o for o in scene.objects if o.type in ("CURVE", "FONT", "SURFACE", "META", "MESH")]
    for o in convert:
        if o.type != "MESH" or len(o.modifiers):
            ev = o.evaluated_get(deps)
            try:
                me = bpy.data.meshes.new_from_object(ev, preserve_all_data_layers=True, depsgraph=deps)
            except Exception as e:
                log("convert failed", o.name, e)
                continue
            path = o.get("cp_path", o.name)
            mats = [s.material for s in o.material_slots]
            new = bpy.data.objects.new(o.name + "_m", me)
            scene.collection.objects.link(new)
            new.matrix_world = o.matrix_world.copy()
            if not me.materials and mats:
                for m in mats:
                    me.materials.append(m)
            new["cp_path"] = path
            # children must survive: reparent them to the new object keeping transforms
            for ch in list(o.children):
                mw = ch.matrix_world.copy()
                ch.parent = new
                ch.matrix_world = mw
            bpy.data.objects.remove(o, do_unlink=True)
    # unparent everything keeping world transforms
    for o in list(scene.objects):
        if o.parent is not None:
            mw = o.matrix_world.copy()
            o.parent = None
            o.matrix_world = mw
    # drop non-mesh objects
    for o in list(scene.objects):
        if o.type != "MESH":
            bpy.data.objects.remove(o, do_unlink=True)
    meshes = [o for o in scene.objects if o.type == "MESH" and len(o.data.polygons)]
    for o in list(scene.objects):
        if o not in meshes:
            bpy.data.objects.remove(o, do_unlink=True)
    # single-user data, then bake transforms into vertices
    for o in meshes:
        if o.data.users > 1:
            o.data = o.data.copy()
    for o in meshes:
        neg = o.matrix_world.determinant() < 0
        o.data.transform(o.matrix_world)
        o.matrix_world.identity()
        if neg:  # mirrored instance: baking the transform turns the faces inside out
            o.data.flip_normals()
    vl.update()
    log(f"flatten: {len(meshes)} mesh objects, {sum(len(o.data.polygons) for o in meshes)} faces")
    return meshes


def _principled(mat):
    if not mat or not mat.use_nodes or not mat.node_tree:
        return None
    for n in mat.node_tree.nodes:
        if n.type == "BSDF_PRINCIPLED":
            return n
    return None


def discover_textures(model_dir: str, explicit: dict | None = None):
    """For materials whose Base Color is unlinked, attach an image found next to the model by name similarity.
    `explicit` maps material name -> image file name (relative to model_dir) and wins over fuzzy matching."""
    explicit = explicit or {}
    imgs = []
    for root, _dirs, files in os.walk(model_dir):
        for f in files:
            if f.lower().endswith(IMG_EXT):
                imgs.append(os.path.join(root, f))
    if not imgs:
        return 0
    keys = {norm_name(os.path.splitext(os.path.basename(p))[0]): p for p in imgs}
    n = 0
    for mat in bpy.data.materials:
        bsdf = _principled(mat)
        if bsdf is None:
            continue
        bc = bsdf.inputs["Base Color"]
        if bc.is_linked:
            continue
        path = None
        base = re.sub(r"\.\d{3}$", "", mat.name)
        if base in explicit:
            p = os.path.join(model_dir, explicit[base])
            path = p if os.path.exists(p) else None
        if path is None and not explicit.get("_no_fuzzy"):
            k = norm_name(base)
            if k in keys:
                path = keys[k]
            else:
                cand = [kk for kk in keys if kk.startswith(k) or k.startswith(kk)]
                if not cand:
                    cand = difflib.get_close_matches(k, list(keys), n=1, cutoff=0.8)
                if cand:
                    path = keys[sorted(cand, key=len)[0]]
        if not path:
            continue
        nt = mat.node_tree
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image = bpy.data.images.load(path, check_existing=True)
        nt.links.new(tex.outputs["Color"], bc)
        bc.default_value = (1, 1, 1, 1)
        log(f"texture auto-discovered: {mat.name} <- {os.path.relpath(path, model_dir)}")
        n += 1
    return n
