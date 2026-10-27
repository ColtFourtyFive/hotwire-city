#!/usr/bin/env python3
"""Blender (Cycles, CPU) renders for the 3D-looking VFX flipbooks. Run with Blender's Python module:

    python3 -I tools/vfx/render_blender.py [coin_spin debris_chips cash_flutter confetti]

Every flipbook is 16 frames (Grid4x4), one full loop of a tumble, on a transparent film; frames are rendered at
2x and downsampled with premultiplied alpha. cash_flutter needs assets/vfx/_bill_flat.png (gen_textures.py cash_bill).
"""
import math
import os
import sys
import tempfile

import bpy
import numpy as np
from mathutils import Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "assets", "vfx")
sys.path.insert(0, HERE)
from vfxlib import atlas, resize, save  # noqa: E402

FRAMES = 16


# ----------------------------------------------------------------------------------------------------------------
# scene
# ----------------------------------------------------------------------------------------------------------------
def reset(res, samples=48):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = samples
    sc.cycles.use_denoising = True
    sc.render.film_transparent = True
    sc.render.resolution_x = res
    sc.render.resolution_y = res
    sc.render.resolution_percentage = 100
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGBA"
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    world = bpy.data.worlds.new("World")
    sc.world = world
    world.use_nodes = True
    nt = world.node_tree
    nt.nodes.clear()
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position = 0.35
    ramp.color_ramp.elements[0].color = (0.05, 0.05, 0.06, 1)
    ramp.color_ramp.elements[1].position = 0.75
    ramp.color_ramp.elements[1].color = (0.9, 0.9, 0.92, 1)
    mapr = nt.nodes.new("ShaderNodeMapRange")
    mapr.inputs["From Min"].default_value = -1
    mapr.inputs["From Max"].default_value = 1
    bg = nt.nodes.new("ShaderNodeBackground")
    bg.inputs["Strength"].default_value = 0.9
    out = nt.nodes.new("ShaderNodeOutputWorld")
    nt.links.new(tc.outputs["Generated"], sep.inputs[0])
    nt.links.new(sep.outputs["Z"], mapr.inputs["Value"])
    nt.links.new(mapr.outputs["Result"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bg.inputs["Color"])
    nt.links.new(bg.outputs["Background"], out.inputs["Surface"])
    # camera: orthographic, looking along -Y
    cam_data = bpy.data.cameras.new("Cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = 2.6
    cam = bpy.data.objects.new("Cam", cam_data)
    sc.collection.objects.link(cam)
    cam.location = (0, -10, 0)
    cam.rotation_euler = (math.radians(90), 0, 0)
    sc.camera = cam
    # lights: key (top-left-front), fill (right), rim (back-top)
    def area(name, loc, energy, size, color=(1, 1, 1)):
        ld = bpy.data.lights.new(name, "AREA")
        ld.energy = energy
        ld.size = size
        ld.color = color
        ob = bpy.data.objects.new(name, ld)
        sc.collection.objects.link(ob)
        ob.location = loc
        direction = Vector((0, 0, 0)) - Vector(loc)
        ob.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
        return ob

    area("Key", (-4, -5, 5), 900, 4)
    area("Fill", (5, -4, 0), 250, 5)
    area("Rim", (0, 5, 4), 500, 3)
    return sc, cam


def principled(name, color, metallic=0.0, roughness=0.5, image=None, spec=0.5):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*color, 1)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = spec
    if image:
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image = bpy.data.images.load(image)
        nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    return m


def render_frames(name, obj_pose, res_out, cols=4, res_render=None):
    """obj_pose(i, t) poses the scene for frame i; renders FRAMES frames, packs them into an atlas."""
    sc = bpy.context.scene
    res_render = res_render or res_out * 2
    sc.render.resolution_x = res_render
    sc.render.resolution_y = res_render
    frames = []
    tmp = tempfile.mkdtemp(prefix="hcvfx_")
    for i in range(FRAMES):
        obj_pose(i, i / FRAMES)
        path = os.path.join(tmp, f"{name}_{i:02d}.png")
        sc.render.filepath = path
        bpy.ops.render.render(write_still=True)
        img = bpy.data.images.load(path)
        px = np.array(img.pixels[:], dtype=np.float32).reshape(res_render, res_render, 4)[::-1]
        bpy.data.images.remove(img)
        frames.append(resize(px, (res_out, res_out)))
    out = save(atlas(frames, cols), name)
    print("wrote", os.path.relpath(out, ROOT))


def pad_scale(cam, scale):
    cam.data.ortho_scale = scale


# ----------------------------------------------------------------------------------------------------------------
# helpers to build meshes
# ----------------------------------------------------------------------------------------------------------------
def mesh_from(name, verts, faces):
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.update()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def add_modifier(ob, kind, **props):
    m = ob.modifiers.new(kind.lower(), kind)
    for k, v in props.items():
        setattr(m, k, v)
    return m


def shade_smooth(ob, smooth=True):
    for p in ob.data.polygons:
        p.use_smooth = smooth


# ----------------------------------------------------------------------------------------------------------------
# coin
# ----------------------------------------------------------------------------------------------------------------
def coin_spin():
    sc, cam = reset(256)
    gold = principled("Gold", (1.0, 0.72, 0.22), metallic=1.0, roughness=0.22)
    bpy.ops.mesh.primitive_cylinder_add(vertices=96, radius=1.0, depth=0.18, rotation=(math.radians(90), 0, 0))
    coin = bpy.context.active_object
    coin.data.materials.append(gold)
    add_modifier(coin, "BEVEL", width=0.05, segments=3)
    shade_smooth(coin)
    parts = [coin]
    for side in (-1, 1):
        # raised rim ring
        bpy.ops.mesh.primitive_torus_add(major_radius=0.86, minor_radius=0.045, major_segments=96, minor_segments=12,
                                         location=(0, side * 0.09, 0), rotation=(math.radians(90), 0, 0))
        ring = bpy.context.active_object
        ring.data.materials.append(gold)
        shade_smooth(ring)
        parts.append(ring)
        # embossed 5-point star
        n = 5
        verts = [(0, 0, 0)]
        for k in range(n * 2):
            a = math.pi / 2 + k * math.pi / n
            r = 0.6 if k % 2 == 0 else 0.26
            verts.append((math.cos(a) * r, 0, math.sin(a) * r))
        faces = [(0, 1 + k, 1 + (k + 1) % (n * 2)) for k in range(n * 2)]
        star = mesh_from("Star", verts, faces)
        star.location = (0, side * 0.09, 0)
        add_modifier(star, "SOLIDIFY", thickness=0.07, offset=side * -1.0 if side > 0 else 1.0)
        add_modifier(star, "BEVEL", width=0.02, segments=2)
        star.data.materials.append(gold)
        parts.append(star)
    pivot = bpy.data.objects.new("Pivot", None)
    sc.collection.objects.link(pivot)
    for p in parts:
        p.parent = pivot
    pad_scale(cam, 2.35)

    def pose(i, t):
        # half turn = loop (both faces identical); slight tilt so the edge reads as 3D
        pivot.matrix_world = Matrix.Rotation(math.radians(-14), 4, "X") @ Matrix.Rotation(t * math.pi, 4, "Z")

    render_frames("coin_spin", pose, 128)


# ----------------------------------------------------------------------------------------------------------------
# debris chunk
# ----------------------------------------------------------------------------------------------------------------
def debris_chips():
    sc, cam = reset(256)
    rng = np.random.default_rng(7)
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=0.8)
    chunk = bpy.context.active_object
    me = chunk.data
    for v in me.vertices:
        s = rng.uniform(0.65, 1.2)
        v.co = Vector((v.co.x * s * 1.25, v.co.y * s * 0.55, v.co.z * s))
    me.update()
    add_modifier(chunk, "BEVEL", width=0.03, segments=1)
    shade_smooth(chunk, False)
    chunk.data.materials.append(principled("Chip", (0.85, 0.85, 0.87), metallic=0.35, roughness=0.42))
    pad_scale(cam, 2.7)
    axis = Vector((0.45, 0.3, 0.84)).normalized()

    def pose(i, t):
        chunk.matrix_world = Matrix.Rotation(t * 2 * math.pi, 4, axis) @ Matrix.Rotation(0.4, 4, "X")

    render_frames("debris_chips", pose, 128)


# ----------------------------------------------------------------------------------------------------------------
# cash flutter (bill bends + tumbles)
# ----------------------------------------------------------------------------------------------------------------
def bent_sheet(name, w, h, cuts, material):
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=cuts, y_subdivisions=max(2, cuts // 2), size=1)
    ob = bpy.context.active_object
    ob.name = name
    ob.scale = (w, h, 1)
    bpy.ops.object.transform_apply(scale=True)
    ob.data.materials.append(material)
    add_modifier(ob, "SOLIDIFY", thickness=0.01)
    bend = add_modifier(ob, "SIMPLE_DEFORM", deform_method="BEND", deform_axis="Y", angle=0.0)
    shade_smooth(ob)
    return ob, bend


def cash_flutter():
    bill = os.path.join(OUT, "_bill_flat.png")
    if not os.path.exists(bill):
        raise SystemExit("run gen_textures.py cash_bill first")
    sc, cam = reset(512)
    mat = principled("Bill", (1, 1, 1), roughness=0.62, image=bill, spec=0.3)
    ob, bend = bent_sheet("Bill", 2.0, 1.0, 24, mat)
    pivot = bpy.data.objects.new("Pivot", None)
    sc.collection.objects.link(pivot)
    ob.parent = pivot
    pad_scale(cam, 2.45)
    axis = Vector((0.25, 0.55, 0.8)).normalized()

    def pose(i, t):
        bend.angle = math.radians(55) * math.sin(2 * math.pi * t)
        pivot.matrix_world = (Matrix.Rotation(t * 2 * math.pi, 4, axis) @ Matrix.Rotation(math.radians(70), 4, "X"))

    render_frames("cash_flutter", pose, 256)


# ----------------------------------------------------------------------------------------------------------------
# confetti piece
# ----------------------------------------------------------------------------------------------------------------
def confetti():
    sc, cam = reset(256)
    mat = principled("Paper", (0.92, 0.92, 0.92), roughness=0.38, spec=0.6)
    ob, bend = bent_sheet("Confetti", 0.62, 1.25, 16, mat)
    pivot = bpy.data.objects.new("Pivot", None)
    sc.collection.objects.link(pivot)
    ob.parent = pivot
    pad_scale(cam, 1.75)
    axis = Vector((0.6, 0.35, 0.72)).normalized()

    def pose(i, t):
        bend.angle = math.radians(35) * math.sin(2 * math.pi * t + 0.6)
        pivot.matrix_world = Matrix.Rotation(t * 2 * math.pi, 4, axis) @ Matrix.Rotation(math.radians(60), 4, "X")

    render_frames("confetti", pose, 128)


JOBS = {"coin_spin": coin_spin, "debris_chips": debris_chips, "cash_flutter": cash_flutter, "confetti": confetti}

if __name__ == "__main__":
    names = [a for a in sys.argv[1:] if a in JOBS] or list(JOBS)
    for n in names:
        JOBS[n]()
