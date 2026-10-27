"""Preview renders for carpipe: studio turntable shots and a GTA-like street (golden hour / wet night),
before (raw import, original materials) vs after (the Roblox GLB), role breakdown and paint variants."""
from __future__ import annotations

import math
import os

import bpy
import numpy as np
from mathutils import Euler, Matrix, Vector

from .util import log, reset_scene, select_only, srgb_to_lin, verts_np

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(HERE, "_cache")

ROLE_COLORS = {"Body": (0.85, 0.12, 0.10), "Body2": (0.55, 0.05, 0.25), "Glass": (0.2, 0.75, 0.95),
               "LightsFront": (1.0, 0.95, 0.4), "LightsRear": (1.0, 0.35, 0.0), "Trim": (0.55, 0.55, 0.6),
               "Interior": (0.2, 0.7, 0.25), "Wheel": (0.12, 0.12, 0.14)}


# ------------------------------------------------------------------------------------------ setup
def setup_cycles(samples=64, res=(960, 540)):
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    c = sc.cycles
    c.device = "CPU"
    c.samples = samples
    c.use_adaptive_sampling = True
    c.adaptive_threshold = 0.02
    c.use_denoising = True
    try:
        c.denoiser = "OPENIMAGEDENOISE"
    except Exception:
        pass
    c.max_bounces, c.diffuse_bounces, c.glossy_bounces, c.transmission_bounces = 8, 3, 4, 8
    c.transparent_max_bounces = 16
    c.caustics_reflective = c.caustics_refractive = False
    c.sample_clamp_indirect = 6.0
    c.blur_glossy = 1.0
    sc.render.threads_mode = "AUTO"
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = False
    sc.view_settings.view_transform = "AgX"
    for look in ("AgX - Medium High Contrast", "AgX - Punchy", "Medium High Contrast"):
        try:
            sc.view_settings.look = look
            break
        except Exception:
            continue
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGB"
    return sc


def hdri_sun(path):
    """Azimuth (deg, Blender world, from +X toward +Y) and elevation of the brightest blob in an equirect HDRI."""
    img = bpy.data.images.load(path, check_existing=True)
    w, h = img.size
    px = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    a = px.reshape(h, w, 4)[..., :3].sum(-1)
    k = 8
    a2 = a[: h - h % k, : w - w % k].reshape(h // k, k, w // k, k).mean((1, 3))
    y, x = np.unravel_index(np.argmax(a2), a2.shape)
    u = (x + 0.5) / a2.shape[1]
    v = (y + 0.5) / a2.shape[0]  # row 0 = bottom in Blender pixel order
    elev = (v - 0.5) * 180.0
    az = (u - 0.5) * 360.0  # Blender equirect: u=0.5 looks down -Y? we return a world azimuth for the env as-is
    # Blender maps direction (x,y,z) -> u = atan2(dir.y, -dir.x)/(2pi) + 0.5
    phi = (u - 0.5) * 2 * math.pi
    d = Vector((-math.cos(phi), math.sin(phi), 0))
    az = math.degrees(math.atan2(d.y, d.x))
    return az, elev


def world_hdri(path, strength=1.0, rot_deg=0.0, bg_strength=None):
    w = bpy.data.worlds.new("World")
    bpy.context.scene.world = w
    w.use_nodes = True
    nt = w.node_tree
    nt.nodes.clear()
    tc = nt.nodes.new("ShaderNodeTexCoord")
    mp = nt.nodes.new("ShaderNodeMapping")
    mp.inputs["Rotation"].default_value = (0, 0, math.radians(rot_deg))
    env = nt.nodes.new("ShaderNodeTexEnvironment")
    env.image = bpy.data.images.load(path, check_existing=True)
    out = nt.nodes.new("ShaderNodeOutputWorld")
    nt.links.new(tc.outputs["Generated"], mp.inputs["Vector"])
    nt.links.new(mp.outputs["Vector"], env.inputs["Vector"])
    if bg_strength is None:
        bg = nt.nodes.new("ShaderNodeBackground")
        bg.inputs["Strength"].default_value = strength
        nt.links.new(env.outputs["Color"], bg.inputs["Color"])
        nt.links.new(bg.outputs["Background"], out.inputs["Surface"])
    else:  # different strength for camera rays (backplate) and lighting
        lp = nt.nodes.new("ShaderNodeLightPath")
        b1 = nt.nodes.new("ShaderNodeBackground")
        b1.inputs["Strength"].default_value = strength
        b2 = nt.nodes.new("ShaderNodeBackground")
        b2.inputs["Strength"].default_value = bg_strength
        mix = nt.nodes.new("ShaderNodeMixShader")
        nt.links.new(env.outputs["Color"], b1.inputs["Color"])
        nt.links.new(env.outputs["Color"], b2.inputs["Color"])
        nt.links.new(lp.outputs["Is Camera Ray"], mix.inputs["Fac"])
        nt.links.new(b1.outputs["Background"], mix.inputs[1])
        nt.links.new(b2.outputs["Background"], mix.inputs[2])
        nt.links.new(mix.outputs["Shader"], out.inputs["Surface"])
    return w


def _mat(name, rgb=(0.5, 0.5, 0.5), rough=0.5, metal=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = tuple(srgb_to_lin(rgb)) + (1,)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    return m


def _tex_mat(name, key, scale, rough_mul=1.0, tint=(1, 1, 1), wet=0.0):
    d = os.path.join(CACHE, "tex", key)
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes["Principled BSDF"]
    tc = nt.nodes.new("ShaderNodeTexCoord")
    mp = nt.nodes.new("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (scale, scale, scale)
    nt.links.new(tc.outputs["Object"], mp.inputs["Vector"])

    def img(fn, data):
        n = nt.nodes.new("ShaderNodeTexImage")
        n.image = bpy.data.images.load(os.path.join(d, fn), check_existing=True)
        n.image.colorspace_settings.name = "Non-Color" if data else "sRGB"
        n.projection = "BOX"
        n.projection_blend = 0.2
        nt.links.new(mp.outputs["Vector"], n.inputs["Vector"])
        return n

    dif = img("diff.jpg", False)
    mul = nt.nodes.new("ShaderNodeMix")
    mul.data_type = "RGBA"
    mul.blend_type = "MULTIPLY"
    mul.inputs["Factor"].default_value = 1.0
    nt.links.new(dif.outputs["Color"], mul.inputs[6])
    mul.inputs[7].default_value = tuple(tint) + (1,)
    nt.links.new(mul.outputs[2], b.inputs["Base Color"])
    r = img("rough.jpg", True)
    mr = nt.nodes.new("ShaderNodeMath")
    mr.operation = "MULTIPLY"
    mr.inputs[1].default_value = rough_mul
    nt.links.new(r.outputs["Color"], mr.inputs[0])
    nt.links.new(mr.outputs["Value"], b.inputs["Roughness"])
    n = img("nor.jpg", True)
    nm = nt.nodes.new("ShaderNodeNormalMap")
    nm.inputs["Strength"].default_value = 0.6
    nt.links.new(n.outputs["Color"], nm.inputs["Color"])
    nt.links.new(nm.outputs["Normal"], b.inputs["Normal"])
    if wet > 0:
        b.inputs["Coat Weight"].default_value = wet
        b.inputs["Coat Roughness"].default_value = 0.12
    return m


def _plane(name, sx, sy, loc=(0, 0, 0), mat=None):
    bpy.ops.mesh.primitive_plane_add(size=1, location=loc)
    o = bpy.context.active_object
    o.name = name
    o.scale = (sx, sy, 1)
    bpy.ops.object.transform_apply(scale=True)
    if mat:
        o.data.materials.append(mat)
    return o


def _box(name, size, loc, mat=None):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc)
    o = bpy.context.active_object
    o.name = name
    o.scale = size
    bpy.ops.object.transform_apply(scale=True)
    if mat:
        o.data.materials.append(mat)
    return o


# ------------------------------------------------------------------------------------------ scenes
def studio(L=17.0):
    world_hdri(os.path.join(CACHE, "hdri", "studio.hdr"), strength=0.55, rot_deg=40)
    # cyclorama: floor + curved wall
    bpy.ops.mesh.primitive_plane_add(size=1)
    o = bpy.context.active_object
    o.name = "Cyc"
    o.scale = (L * 8, L * 8, 1)
    bpy.ops.object.transform_apply(scale=True)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.subdivide(number_cuts=40)
    bpy.ops.object.mode_set(mode="OBJECT")
    me = o.data
    co = verts_np(me)
    y0 = L * 1.4
    R = L * 1.2
    for i, (x, y, z) in enumerate(co):  # sweep the far (-Y) side of the floor up into a wall
        if -y > y0:
            u = -y - y0
            t = min(u / R, math.pi / 2)
            co[i] = (x, -(y0 + R * math.sin(t)), R * (1 - math.cos(t)) + max(0.0, u - R * math.pi / 2))
    me.vertices.foreach_set("co", co.astype(np.float32).ravel())
    me.update()
    for p in me.polygons:
        p.use_smooth = True
    o.data.materials.append(_mat("cyc", (0.42, 0.43, 0.45), rough=0.55))
    # soft key + rim area lights
    for nm, loc, energy, size in (("Key", (-L * 0.8, -L * 0.9, L * 0.9), 11000 * (L / 17) ** 2, L * 0.6),
                                   ("Rim", (L * 0.9, L * 0.7, L * 0.6), 5000 * (L / 17) ** 2, L * 0.5)):
        bpy.ops.object.light_add(type="AREA", location=loc)
        lt = bpy.context.active_object
        lt.name = nm
        lt.data.energy = energy
        lt.data.size = size
        lt.rotation_euler = (Vector((0, 0, L * 0.12)) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
        lt.visible_camera = False
        lt.visible_glossy = True


def street(L=17.0, night=False, keep_clear=None):
    """Golden-hour (or wet night) street: 4-lane asphalt, markings, curb + sidewalk, lamp posts.
    keep_clear: (x, y) camera position; lamp posts between it and the origin are skipped."""
    if night:
        world_hdri(os.path.join(CACHE, "hdri", "street_night.hdr"), strength=0.35, rot_deg=200, bg_strength=0.45)
    else:
        path = os.path.join(CACHE, "hdri", "street_sunset.hdr")
        az, el = hdri_sun(path)
        rot = -40.0 - az  # put the sun behind-left of a car facing +Y viewed from front-right
        world_hdri(path, strength=1.0, rot_deg=rot, bg_strength=1.0)
        bpy.ops.object.light_add(type="SUN")
        sun = bpy.context.active_object
        sun.data.energy = 3.2
        sun.data.angle = math.radians(1.5)
        sun.data.color = (1.0, 0.78, 0.55)
        a = math.radians(az + rot)
        e = math.radians(max(el, 8.0))
        d = Vector((math.cos(a) * math.cos(e), math.sin(a) * math.cos(e), math.sin(e)))
        sun.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
    lane = L * 0.42  # lane width ~ 3.6 m at car-length 4.8 m
    road_w = lane * 4
    asphalt = _tex_mat("asphalt", "asphalt", 0.12 * 17 / L, rough_mul=0.8 if night else 1.0,
                       tint=(0.6, 0.6, 0.62) if night else (0.85, 0.85, 0.85), wet=0.35 if night else 0.0)
    _plane("Road", road_w, L * 30, loc=(0, 0, 0), mat=asphalt)
    paint = _mat("marking", (0.85, 0.85, 0.8), rough=0.6)
    yellow = _mat("yellow", (0.85, 0.65, 0.1), rough=0.6)
    for x in (-lane, lane):  # dashed white lane lines
        for k in range(-12, 13):
            _plane("dash", 0.12 * L / 17 * 1.2, L * 0.18, loc=(x, k * L * 0.45, 0.004), mat=paint)
    for dx in (-0.09, 0.09):
        _plane("center", 0.1 * L / 17 * 1.2, L * 30, loc=(dx * L / 17 * 1.2, 0, 0.004), mat=yellow)
    curb_h = 0.5 * L / 17
    walk_w = L * 0.55
    curb = _tex_mat("curb", "curb", 0.5 * 17 / L, tint=(0.8, 0.8, 0.78))
    walk = _tex_mat("sidewalk", "sidewalk", 0.18 * 17 / L, tint=(0.9, 0.88, 0.85))
    for s in (-1, 1):
        _box("curb", (0.35 * L / 17, L * 30, curb_h), (s * (road_w / 2 + 0.17 * L / 17), 0, curb_h / 2), curb)
        _box("walk", (walk_w, L * 30, curb_h * 0.95), (s * (road_w / 2 + 0.35 * L / 17 + walk_w / 2), 0, curb_h * 0.95 / 2),
             walk)
    # lamp posts (and their lights at night)
    pole = _mat("pole", (0.18, 0.19, 0.2), rough=0.4, metal=0.8)
    for s in (-1, 1):
        for k in (-3, -2, -1, 0, 1, 2, 3):
            x = s * (road_w / 2 + 0.9 * L / 17)
            y = k * L * 1.6 + (L * 0.8 if s > 0 else 0)
            if keep_clear is not None:
                cx, cy = keep_clear
                # distance from the pole to the segment camera -> origin
                t = max(0.0, min(1.0, (x * cx + y * cy) / max(cx * cx + cy * cy, 1e-6)))
                if math.hypot(x - t * cx, y - t * cy) < L * 0.45 and t > 0.05:
                    continue
            _box("pole", (0.25, 0.25, 9.5 * L / 17), (x, y, 4.75 * L / 17), pole)
            _box("arm", (2.6 * L / 17, 0.2, 0.2), (x - s * 1.2 * L / 17, y, 9.4 * L / 17), pole)
            if night:
                bpy.ops.object.light_add(type="POINT", location=(x - s * 2.3 * L / 17, y, 9.2 * L / 17))
                lt = bpy.context.active_object
                lt.data.energy = 9000 * (L / 17) ** 2
                lt.data.color = (1.0, 0.62, 0.3)
                lt.data.shadow_soft_size = 0.4


def camera_pos(target, L, az_deg=35.0, el_deg=10.0, lens=50, dist_mul=1.0):
    a = math.radians(az_deg)
    e = math.radians(el_deg)
    fov = 2 * math.atan(18.0 / lens)
    d = (L * 0.62) / math.tan(fov / 2) * dist_mul
    return Vector(target) + Vector((math.sin(a) * math.cos(e), math.cos(a) * math.cos(e), math.sin(e))) * d


def camera(target, L, az_deg=35.0, el_deg=10.0, lens=50, dist_mul=1.0, shift_y=0.0):
    """az measured from the car's front (+Y) toward its right (+X)."""
    cam = bpy.data.cameras.new("Cam")
    cam.lens = lens
    cam.shift_y = shift_y
    ob = bpy.data.objects.new("Cam", cam)
    bpy.context.scene.collection.objects.link(ob)
    a = math.radians(az_deg)
    e = math.radians(el_deg)
    fov = 2 * math.atan(18.0 / lens)
    d = (L * 0.62) / math.tan(fov / 2) * dist_mul
    pos = Vector(target) + Vector((math.sin(a) * math.cos(e), math.cos(a) * math.cos(e), math.sin(e))) * d
    ob.location = pos
    ob.rotation_euler = (Vector(target) - pos).to_track_quat("-Z", "Y").to_euler()
    bpy.context.scene.camera = ob
    return ob


def render_to(path):
    bpy.context.scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    log("render ->", path)
    return path


# ------------------------------------------------------------------------------------------ car loading
def _tintmask_nodes(m, b, tint_png, paint):
    """Emulate Roblox SurfaceAppearance AlphaMode=TintMask: colour = lerp(ColorMap, ColorMap * Color, ColorMap.a)
    using carpipe's <name>_Body_tintmask.png (paint pixels are neutral shading with alpha = 1)."""
    nt = m.node_tree
    src = b.inputs["Base Color"].links[0].from_socket if b.inputs["Base Color"].is_linked else None
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(tint_png, check_existing=True)
    uv = nt.nodes.new("ShaderNodeUVMap")
    nt.links.new(uv.outputs["UV"], tex.inputs["Vector"])
    mul = nt.nodes.new("ShaderNodeMix")
    mul.data_type = "RGBA"
    mul.blend_type = "MULTIPLY"
    mul.inputs["Factor"].default_value = 1.0
    nt.links.new(tex.outputs["Color"], mul.inputs[6])
    mul.inputs[7].default_value = tuple(srgb_to_lin(paint)) + (1,)
    mix = nt.nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    nt.links.new(tex.outputs["Alpha"], mix.inputs["Factor"])
    if src is not None:
        nt.links.new(src, mix.inputs[6])
    else:
        nt.links.new(tex.outputs["Color"], mix.inputs[6])
    nt.links.new(mul.outputs[2], mix.inputs[7])
    nt.links.new(mix.outputs[2], b.inputs["Base Color"])


def load_glb(path, offset=(0, 0, 0), rot_z=0.0, paint=None, lights_on=False):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    new = [o for o in bpy.data.objects if o not in before]
    root = bpy.data.objects.new("CarRoot", None)
    bpy.context.scene.collection.objects.link(root)
    for o in new:
        if o.parent is None:
            o.parent = root
    root.location = offset
    root.rotation_euler = (0, 0, rot_z)
    for o in new:
        if o.type != "MESH":
            continue
        for s in o.material_slots:
            m = s.material
            if m is None or not m.use_nodes:
                continue
            b = m.node_tree.nodes.get("Principled BSDF")
            if b is None:
                continue
            base = o.name.split(".")[0]
            if base == "Body" and paint is not None:
                m = m.copy()
                s.material = m
                b = m.node_tree.nodes.get("Principled BSDF")
                tint_png = os.path.join(os.path.dirname(path), "textures",
                                        os.path.splitext(os.path.basename(path))[0] + "_Body_tintmask.png")
                if not b.inputs["Base Color"].is_linked:
                    b.inputs["Base Color"].default_value = tuple(srgb_to_lin(paint)) + (1,)
                elif os.path.exists(tint_png):
                    _tintmask_nodes(m, b, tint_png, paint)
            if (base == "Body" or base == "Body2") and not b.inputs["Roughness"].is_linked:
                # strip route (untextured paint): stand-in for Roblox's glossy paint look.  Tint-mask bodies keep
                # their baked roughness: old game textures have highlights painted in and look wrong under coat.
                b.inputs["Metallic"].default_value = 0.0
                b.inputs["Roughness"].default_value = 0.32
                try:
                    b.inputs["Coat Weight"].default_value = 1.0
                    b.inputs["Coat Roughness"].default_value = 0.04
                except KeyError:
                    pass
            if base.startswith("Lights"):
                b.inputs["Emission Strength"].default_value = (6.0 if base == "LightsFront" else 3.0) if lights_on else 0.0
            if base == "Glass":
                m.surface_render_method = "BLENDED"
    return root, new


def colorize_roles(objs):
    for o in objs:
        if o.type != "MESH":
            continue
        base = o.name.split(".")[0]
        key = "Wheel" if base.startswith("Wheel") else base
        rgb = ROLE_COLORS.get(key, (1, 0, 1))
        m = _mat("role_" + key, rgb, rough=0.6)
        if key == "Glass":
            b = m.node_tree.nodes["Principled BSDF"]
            b.inputs["Alpha"].default_value = 0.35
            m.surface_render_method = "BLENDED"
        o.data.materials.clear()
        o.data.materials.append(m)


def scene_bounds(objs):
    pts = []
    for o in objs:
        if o.type == "MESH":
            mw = o.matrix_world
            v = verts_np(o.data)
            pts.append((np.c_[v, np.ones(len(v))] @ np.array(mw).T)[:, :3])
    p = np.concatenate(pts)
    return p.min(0), p.max(0)


def composite(paths, out, labels=None, cols=2, label_h=34):
    from PIL import Image, ImageDraw, ImageFont
    ims = [Image.open(p).convert("RGB") for p in paths]
    w, h = ims[0].size
    rows = math.ceil(len(ims) / cols)
    sheet = Image.new("RGB", (w * cols, (h + (label_h if labels else 0)) * rows), (18, 18, 20))
    try:
        font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 20)
    except Exception:
        font = ImageFont.load_default()
    dr = ImageDraw.Draw(sheet)
    for i, im in enumerate(ims):
        x = (i % cols) * w
        y = (i // cols) * (h + (label_h if labels else 0))
        if labels:
            dr.text((x + 12, y + 6), labels[i], fill=(235, 235, 235), font=font)
            y += label_h
        sheet.paste(im, (x, y))
    sheet.save(out)
    log("sheet ->", out)
    return out
