"""Studio render setup for car previews: HDRI reflections, soft key + rim light, shadow catcher floor,
Cycles CPU + OpenImageDenoise, then PIL composite over a gradient backdrop."""
from __future__ import annotations

import math
import os
import urllib.request

import bpy
from mathutils import Vector

CACHE = os.path.expanduser("~/.cache/hotwire_carkit")
HDRI_ID = "studio_small_09"
HDRI_URL = "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/2k/studio_small_09_2k.hdr"  # CC0, Poly Haven


def hdri_path():
    os.makedirs(CACHE, exist_ok=True)
    p = os.path.join(CACHE, f"{HDRI_ID}_2k.hdr")
    if not os.path.exists(p):
        urllib.request.urlretrieve(HDRI_URL, p)
    return p


def setup_render(res=(960, 540), samples=64):
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = samples
    sc.cycles.use_denoising = True
    try:
        sc.cycles.denoiser = "OPENIMAGEDENOISE"
    except Exception:
        pass
    sc.cycles.max_bounces = 6
    sc.cycles.transparent_max_bounces = 8
    sc.cycles.glossy_bounces = 4
    sc.cycles.transmission_bounces = 6
    sc.render.threads_mode = "AUTO"
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = True
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGBA"
    try:
        sc.view_settings.view_transform = "AgX"
        sc.view_settings.look = "AgX - Medium High Contrast"
    except Exception:
        pass
    sc.view_settings.exposure = 0.0


def setup_world(strength=1.0, rot_deg=0.0):
    sc = bpy.context.scene
    w = bpy.data.worlds.new("Studio") if sc.world is None else sc.world
    sc.world = w
    w.use_nodes = True
    nt = w.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputWorld")
    bg = nt.nodes.new("ShaderNodeBackground")
    env = nt.nodes.new("ShaderNodeTexEnvironment")
    env.image = bpy.data.images.load(hdri_path(), check_existing=True)
    mp = nt.nodes.new("ShaderNodeMapping")
    tc = nt.nodes.new("ShaderNodeTexCoord")
    mp.inputs["Rotation"].default_value = (0, 0, math.radians(rot_deg))
    nt.links.new(tc.outputs["Generated"], mp.inputs["Vector"])
    nt.links.new(mp.outputs["Vector"], env.inputs["Vector"])
    nt.links.new(env.outputs["Color"], bg.inputs["Color"])
    bg.inputs["Strength"].default_value = strength
    nt.links.new(bg.outputs["Background"], out.inputs["Surface"])


def add_area(name, loc, target, size, power, color=(1, 1, 1), shape="RECTANGLE", size_y=None):
    ld = bpy.data.lights.new(name, "AREA")
    ld.energy = power
    ld.color = color
    ld.shape = shape
    ld.size = size
    if size_y is not None:
        ld.size_y = size_y
    ob = bpy.data.objects.new(name, ld)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = loc
    d = Vector(target) - Vector(loc)
    ob.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    return ob


def setup_stage(center, length):
    """Shadow-catcher floor + key/rim/fill area lights scaled to the car size."""
    sc = bpy.context.scene
    me = bpy.data.meshes.new("Floor")
    s = 200.0
    me.from_pydata([(-s, -s, 0), (s, -s, 0), (s, s, 0), (-s, s, 0)], [], [(0, 1, 2, 3)])
    fl = bpy.data.objects.new("Floor", me)
    sc.collection.objects.link(fl)
    fl.is_shadow_catcher = True
    k = length / 17.0
    cx, cy, cz = center
    add_area("Key", (cx - 14 * k, cy + 10 * k, 18 * k), (cx, cy, cz), 14 * k, 9000 * k * k, (1.0, 0.97, 0.92))
    add_area("Rim", (cx + 16 * k, cy - 14 * k, 9 * k), (cx, cy, cz + 1), 10 * k, 5500 * k * k, (0.85, 0.92, 1.0))
    add_area("Top", (cx, cy, 22 * k), (cx, cy, 0), 20 * k, 4000 * k * k, (1, 1, 1), size_y=8 * k)
    add_area("Fill", (cx + 12 * k, cy + 18 * k, 4 * k), (cx, cy, cz), 8 * k, 1200 * k * k, (1.0, 0.95, 0.9))


def camera(name, loc, target, lens=50.0, ortho_scale=None):
    cd = bpy.data.cameras.new(name)
    cd.lens = lens
    cd.sensor_width = 36
    if ortho_scale:
        cd.type = "ORTHO"
        cd.ortho_scale = ortho_scale
    ob = bpy.data.objects.new(name, cd)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = loc
    d = Vector(target) - Vector(loc)
    ob.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    return ob


def view_cameras(length, height):
    """Return dict view-name -> camera object. Car nose points +Y."""
    L = length
    tz = height * 0.42
    cams = {}
    # 3/4 front: from front-left, slightly above
    ang = math.radians(38)
    dist = L * 1.75
    cams["34"] = camera("Cam34", (-dist * math.sin(ang), dist * math.cos(ang), L * 0.42), (0, -0.4, tz), lens=50)
    cams["side"] = camera("CamSide", (-L * 3.2, 0, height * 0.55), (0, 0, height * 0.42), lens=85)
    ang = math.radians(145)
    cams["34r"] = camera("Cam34r", (-dist * math.sin(ang), dist * math.cos(ang), L * 0.45), (0, 0.4, tz), lens=50)
    cams["top"] = camera("CamTop", (0, 0, L * 3), (0, 0, 0), lens=60)
    cams["front"] = camera("CamFront", (0, L * 3.0, height * 0.6), (0, 0, height * 0.45), lens=85)
    return cams


def render(cam, path, bg=((0.30, 0.32, 0.36), (0.11, 0.12, 0.14))):
    sc = bpy.context.scene
    sc.camera = cam
    raw = path.replace(".png", "_rgba.png")
    sc.render.filepath = raw
    bpy.ops.render.render(write_still=True)
    composite(raw, path, bg)
    os.remove(raw)


def composite(raw, path, bg):
    from PIL import Image
    import numpy as np

    im = Image.open(raw).convert("RGBA")
    w, h = im.size
    top, bot = np.array(bg[0]), np.array(bg[1])
    yy = np.linspace(0, 1, h)[:, None, None]
    xx = np.linspace(-1, 1, w)[None, :, None]
    grad = top * (1 - yy) + bot * yy
    vign = 1.0 - 0.25 * (xx ** 2)
    arr = np.clip(grad * vign, 0, 1)
    arr = np.broadcast_to(arr, (h, w, 3))
    # sRGB-ish encode
    arr = (np.power(arr, 1 / 2.2) * 255).astype("uint8")
    base = Image.fromarray(arr, "RGB").convert("RGBA")
    out = Image.alpha_composite(base, im)
    out.convert("RGB").save(path)
