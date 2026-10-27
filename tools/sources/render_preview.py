#!/usr/bin/env python3
"""Blender (bpy module) studio preview + analysis for a sourced GLB.

Usage:
  python3 -I tools/sources/render_preview.py <in.glb> <out.png> <stats.json> [--kind vehicle|weapon]
         [--size 720x405] [--samples 32]

Renders a 3/4 view in a neutral grey studio (floor + softboxes, Cycles CPU, OIDN denoise) plus a small
inset of the opposite 3/4 view (so the true front is always visible whatever the model's forward axis),
and writes analysis stats: real-world dimensions, triangle count, mesh/material/texture counts, separate
wheel detection (by name and by geometry), logo/badge-like names, glass-like materials, animations.
"""
import json
import math
import re
import sys
import time

import bpy
from mathutils import Matrix, Vector

WHEEL_RE = re.compile(r"wheel|tire|tyre|rim\b|rims|_rim|rim_|whl|disk|disc|brake|roda|колес", re.I)
LOGO_RE = re.compile(r"logo|badge|emblem|brand|decal|sticker|lettering|marque", re.I)
GLASS_RE = re.compile(r"glass|window|windshield|windscreen|vidrio|стекл", re.I)


def parse_args():
    argv = sys.argv[1:]
    a = {"kind": "vehicle", "size": (720, 405), "samples": 32}
    pos = []
    i = 0
    while i < len(argv):
        if argv[i] == "--kind":
            a["kind"] = argv[i + 1]; i += 2
        elif argv[i] == "--size":
            w, h = argv[i + 1].split("x"); a["size"] = (int(w), int(h)); i += 2
        elif argv[i] == "--samples":
            a["samples"] = int(argv[i + 1]); i += 2
        else:
            pos.append(argv[i]); i += 1
    a["glb"], a["out"], a["stats"] = pos[:3]
    return a


def world_bbox(objs):
    mn = Vector((1e18, 1e18, 1e18))
    mx = Vector((-1e18, -1e18, -1e18))
    for o in objs:
        for c in o.bound_box:
            w = o.matrix_world @ Vector(c)
            mn = Vector(map(min, mn, w))
            mx = Vector(map(max, mx, w))
    return mn, mx


def mesh_objects():
    return [o for o in bpy.context.scene.objects if o.type == "MESH" and o.data and len(o.data.polygons) > 0]


def main():
    a = parse_args()
    t0 = time.time()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=a["glb"])
    scene = bpy.context.scene
    meshes = mesh_objects()
    if not meshes:
        raise SystemExit("no meshes")

    # hide obviously non-model helpers (shadow planes baked as separate objects are kept – they show up)
    # ---------------------------------------------------------------- root for re-orientation
    root = bpy.data.objects.new("PREVIEW_ROOT", None)
    scene.collection.objects.link(root)
    for o in scene.objects:
        if o.parent is None and o is not root:
            o.parent = root
    bpy.context.view_layer.update()

    mn, mx = world_bbox(meshes)
    dims = mx - mn
    stats = {"import_dims_m": [round(d, 4) for d in dims]}

    # orientation: vehicles keep Z up but put the long axis on Y; weapons get long->X, mid->Z, small->Y
    rot = Matrix.Identity(4)
    if a["kind"] == "vehicle":
        if dims.z > max(dims.x, dims.y) * 1.15:  # lying on its nose/tail -> stand it up
            rot = Matrix.Rotation(math.radians(-90), 4, "X")
        root.matrix_world = rot @ root.matrix_world
        bpy.context.view_layer.update()
        mn, mx = world_bbox(meshes); dims = mx - mn
        if dims.x > dims.y:
            root.matrix_world = Matrix.Rotation(math.radians(90), 4, "Z") @ root.matrix_world
    else:
        order = sorted(range(3), key=lambda k: -dims[k])  # longest, middle, smallest
        axes = [Vector((1, 0, 0)), Vector((0, 1, 0)), Vector((0, 0, 1))]
        # build rotation mapping longest->X, middle->Z, smallest->Y
        src = [axes[order[0]], axes[order[1]], axes[order[2]]]
        dst = [Vector((1, 0, 0)), Vector((0, 0, 1)), Vector((0, 1, 0))]
        M = Matrix(((0, 0, 0), (0, 0, 0), (0, 0, 0)))
        for s, d in zip(src, dst):
            for r in range(3):
                for c in range(3):
                    M[r][c] += d[r] * s[c]
        if M.determinant() < 0:
            M = Matrix(((1, 0, 0), (0, -1, 0), (0, 0, 1))) @ M
        root.matrix_world = M.to_4x4() @ root.matrix_world
    bpy.context.view_layer.update()
    mn, mx = world_bbox(meshes)
    # put on the floor, centred
    c = (mn + mx) / 2
    root.matrix_world = Matrix.Translation(Vector((-c.x, -c.y, -mn.z))) @ root.matrix_world
    bpy.context.view_layer.update()
    mn, mx = world_bbox(meshes)
    dims = mx - mn
    stats["dims_m"] = [round(d, 3) for d in dims]  # x=width/len, y, z=height after orientation

    # ---------------------------------------------------------------- analysis
    tris = 0
    names = []
    wheel_named, wheel_geom, logo_named = [], [], []
    H = max(dims.z, 1e-6)
    long_axis = 1 if a["kind"] == "vehicle" else 0
    for o in meshes:
        me = o.data
        tris += sum(len(p.vertices) - 2 for p in me.polygons)
        names.append(o.name)
        if WHEEL_RE.search(o.name) or WHEEL_RE.search(me.name):
            wheel_named.append(o.name)
        if LOGO_RE.search(o.name) or LOGO_RE.search(me.name):
            logo_named.append(o.name)
        if a["kind"] == "vehicle":
            omn, omx = world_bbox([o])
            od = omx - omn
            across = od.x  # wheel thickness axis (car long axis is Y)
            dia_y, dia_z = od.y, od.z
            if (dia_z > 0.12 * H and dia_z < 0.75 * H and abs(dia_y - dia_z) / max(dia_y, dia_z) < 0.2
                    and across < 0.8 * dia_z and omn.z < mn.z + 0.08 * H):
                wheel_geom.append(o.name)
    mats = {m.name for o in meshes for m in o.data.materials if m}
    imgs = [i for i in bpy.data.images if i.size[0] > 0]
    tex_max = max([max(i.size) for i in imgs], default=0)
    logo_imgs = [i.name for i in imgs if LOGO_RE.search(i.name) or LOGO_RE.search(i.filepath or "")]
    glass = sorted({m for m in mats if GLASS_RE.search(m)})
    stats.update({
        "mesh_objects": len(meshes),
        "triangles": tris,
        "materials": len(mats),
        "material_names": sorted(mats)[:60],
        "textures": len(imgs),
        "texture_max_px": tex_max,
        "wheel_named": wheel_named[:24],
        "wheel_geom": wheel_geom[:24],
        "wheels_separate": bool(len(wheel_geom) >= 2 or len(wheel_named) >= 2),
        "logo_named": (logo_named + logo_imgs)[:24],
        "glass_materials": glass[:12],
        "animations": len(bpy.data.actions),
        "object_names": names[:80],
    })

    # ---------------------------------------------------------------- studio
    scene.render.engine = "CYCLES"
    cy = scene.cycles
    cy.device = "CPU"
    cy.samples = a["samples"]
    cy.use_denoising = True
    try:
        cy.denoiser = "OPENIMAGEDENOISE"
    except Exception:
        pass
    cy.max_bounces = 6
    cy.transmission_bounces = 6
    cy.glossy_bounces = 3
    cy.diffuse_bounces = 2
    cy.use_adaptive_sampling = True
    scene.render.film_transparent = False
    scene.view_settings.view_transform = "AgX" if "AgX" in [v.identifier for v in
                                                           type(scene.view_settings).bl_rna.properties["view_transform"].enum_items] else "Filmic"
    try:
        scene.view_settings.look = "AgX - Medium High Contrast"
    except Exception:
        pass

    world = bpy.data.worlds.new("Studio")
    scene.world = world
    world.use_nodes = True
    nt = world.node_tree
    bg = nt.nodes["Background"]
    # vertical gradient sky: lighter above for car-paint reflections
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position = 0.45
    ramp.color_ramp.elements[0].color = (0.05, 0.05, 0.055, 1)
    ramp.color_ramp.elements[1].position = 0.75
    ramp.color_ramp.elements[1].color = (0.75, 0.76, 0.78, 1)
    mapr = nt.nodes.new("ShaderNodeMapRange")
    mapr.inputs["From Min"].default_value = -1
    mapr.inputs["From Max"].default_value = 1
    nt.links.new(tc.outputs["Generated"], sep.inputs[0])
    nt.links.new(tc.outputs["Normal"] if False else tc.outputs["Generated"], sep.inputs[0])
    # use the view direction z for the gradient
    lp = nt.nodes.new("ShaderNodeNewGeometry")
    sep2 = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(lp.outputs["Incoming"], sep2.inputs[0])
    nt.links.new(sep2.outputs["Z"], mapr.inputs["Value"])
    nt.links.new(mapr.outputs["Result"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bg.inputs["Color"])
    bg.inputs["Strength"].default_value = 0.9

    size = max(dims.x, dims.y, dims.z)
    # floor (studio sweep approximation)
    bpy.ops.mesh.primitive_plane_add(size=size * 30, location=(0, 0, 0))
    floor = bpy.context.active_object
    fm = bpy.data.materials.new("Floor")
    fm.use_nodes = True
    bsdf = fm.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (0.32, 0.32, 0.33, 1)
    bsdf.inputs["Roughness"].default_value = 0.6
    floor.data.materials.append(fm)

    def area(name, loc, energy, sz, color=(1, 1, 1)):
        ld = bpy.data.lights.new(name, "AREA")
        ld.energy = energy
        ld.size = sz
        ld.color = color
        lo = bpy.data.objects.new(name, ld)
        scene.collection.objects.link(lo)
        lo.location = loc
        d = Vector((0, 0, dims.z * 0.4)) - Vector(loc)
        lo.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
        return lo

    s = size
    E = 120.0 * s * s  # scale light power with model size (watts ~ area)
    area("Key", (s * 1.2, -s * 1.4, s * 1.6), E * 1.0, s * 1.2)
    area("Fill", (-s * 1.6, -s * 0.6, s * 0.9), E * 0.35, s * 1.5, (0.9, 0.95, 1.0))
    area("Rim", (-s * 0.6, s * 1.8, s * 1.3), E * 0.6, s * 1.0)
    area("Top", (0, 0, s * 2.2), E * 0.45, s * 2.0)

    cam_d = bpy.data.cameras.new("Cam")
    cam_d.lens = 50
    cam_d.sensor_width = 36
    cam = bpy.data.objects.new("Cam", cam_d)
    scene.collection.objects.link(cam)
    scene.camera = cam
    center = Vector((0, 0, dims.z * 0.5))
    radius = 0.5 * dims.length

    def place(az_deg, el_deg, fill=0.92):
        az, el = math.radians(az_deg), math.radians(el_deg)
        dvec = Vector((math.sin(az) * math.cos(el), -math.cos(az) * math.cos(el), math.sin(el)))
        aspect = a["size"][0] / a["size"][1]
        fov_v = 2 * math.atan((36 / aspect) / 2 / cam_d.lens)
        dist = radius / math.sin(fov_v / 2) * fill
        cam.location = center + dvec * dist
        cam.rotation_euler = (center - cam.location).to_track_quat("-Z", "Y").to_euler()
        cam_d.clip_start = dist * 0.01
        cam_d.clip_end = dist * 20

    out = a["out"]
    W, Hh = a["size"]
    if a["kind"] == "vehicle":
        views = [("main", 35, 14, (W, Hh), 0.80), ("inset", 180 + 35, 14, (W // 2, Hh // 2), 0.80)]
    else:
        views = [("main", 18, 12, (W, Hh), 0.62), ("inset", 180 + 18, 12, (W // 2, Hh // 2), 0.62)]
    paths = []
    for tag, az, el, (rw, rh), fill in views:
        scene.render.resolution_x, scene.render.resolution_y = rw, rh
        scene.render.resolution_percentage = 100
        cy.samples = a["samples"] if tag == "main" else max(12, a["samples"] // 2)
        place(az, el, fill)
        p = out if tag == "main" else out.replace(".png", "_inset.png")
        scene.render.filepath = p
        bpy.ops.render.render(write_still=True)
        paths.append(p)
    stats["render_s"] = round(time.time() - t0, 1)
    stats["renders"] = paths
    with open(a["stats"], "w") as f:
        json.dump(stats, f, indent=1)
    print("PREVIEW_OK", json.dumps({k: stats[k] for k in ("dims_m", "triangles", "mesh_objects", "wheels_separate", "render_s")}))


if __name__ == "__main__":
    main()
