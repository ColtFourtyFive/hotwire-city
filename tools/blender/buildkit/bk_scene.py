"""Preview scene helpers: Cycles CPU settings, Poly Haven sky HDRI aligned to a chosen sun direction,
street (asphalt road, curbs, sidewalk, markings), street props, camera and render."""
import math, os
import bpy
from mathutils import Vector

import bk_geo as G
import bk_mat as M

HERE = os.path.dirname(os.path.abspath(__file__))
HDRI = os.path.join(HERE, "_cache", "hdri")
# Sun position measured in each HDRI (u of the brightest pixel -> Blender azimuth, degrees)
HDRI_SUN = {"sky_late_afternoon": (-36.0, 19.1), "sky_sunset": (-36.0, 6.1), "sky_dusk": (-39.2, 10.5)}


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    s = bpy.context.scene
    s.render.engine = "CYCLES"
    c = s.cycles
    c.device = "CPU"
    c.samples = 64
    c.use_adaptive_sampling = True
    c.adaptive_threshold = 0.02
    c.use_denoising = True
    try:
        c.denoiser = "OPENIMAGEDENOISE"
    except Exception:
        pass
    c.max_bounces, c.diffuse_bounces, c.glossy_bounces, c.transmission_bounces = 6, 3, 3, 2
    c.caustics_reflective = c.caustics_refractive = False
    c.sample_clamp_indirect = 8.0
    s.render.threads_mode = "FIXED"
    s.render.threads = 4
    s.render.resolution_x, s.render.resolution_y = 960, 540
    s.render.resolution_percentage = 100
    s.view_settings.view_transform = "AgX"
    for look in ("AgX - Medium High Contrast", "AgX - Punchy", "Medium High Contrast"):
        try:
            s.view_settings.look = look
            break
        except Exception:
            continue
    s.render.image_settings.file_format = "PNG"
    return s


def world(sky="sky_late_afternoon", sun_az=-120.0, strength=1.0):
    """sun_az: azimuth (deg, from +X towards +Y) of the direction pointing at the sun."""
    w = bpy.data.worlds.new("Sky")
    bpy.context.scene.world = w
    w.use_nodes = True
    nt = w.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    tc = nt.nodes.new("ShaderNodeTexCoord")
    mp = nt.nodes.new("ShaderNodeMapping")
    env = nt.nodes.new("ShaderNodeTexEnvironment")
    env.image = bpy.data.images.load(os.path.join(HDRI, sky + ".hdr"), check_existing=True)
    bg = nt.nodes.new("ShaderNodeBackground")
    out = nt.nodes.new("ShaderNodeOutputWorld")
    nt.links.new(tc.outputs["Generated"], mp.inputs[0])
    nt.links.new(mp.outputs[0], env.inputs[0])
    nt.links.new(env.outputs[0], bg.inputs[0])
    nt.links.new(bg.outputs[0], out.inputs[0])
    bg.inputs[1].default_value = strength
    az0 = HDRI_SUN.get(sky, (0, 0))[0]
    mp.inputs["Rotation"].default_value[2] = math.radians(az0 - sun_az)
    return w


def look(cam, target):
    d = Vector(target) - cam.location
    cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()


def camera(loc, target, lens=28.0, shift_y=0.0):
    cd = bpy.data.cameras.new("Cam")
    cd.lens = lens
    cd.shift_y = shift_y
    cd.clip_start, cd.clip_end = 0.5, 6000
    cam = bpy.data.objects.new("Cam", cd)
    bpy.context.scene.collection.objects.link(cam)
    cam.location = Vector(loc)
    look(cam, target)
    bpy.context.scene.camera = cam
    return cam


def render(path, samples=None, res=None):
    s = bpy.context.scene
    if samples:
        s.cycles.samples = samples
    if res:
        s.render.resolution_x, s.render.resolution_y = res
    os.makedirs(os.path.dirname(path), exist_ok=True)
    s.render.filepath = path
    bpy.ops.render.render(write_still=True)


# ----------------------------------------------------------------------------- street
_mats = {}


def _m(key):
    if key not in _mats:
        if key == "asphalt":
            _mats[key] = M.textured("Asphalt", "asphalt", tint=(0.85, 0.85, 0.85), rough=1.0)
        elif key == "sidewalk":
            _mats[key] = M.textured("Sidewalk", "sidewalk", tint=(1.05, 1.03, 1.0))
        elif key == "curb":
            _mats[key] = M.textured("Curb", "curb", tint=(1.1, 1.1, 1.1))
        elif key == "white":
            _mats[key] = M.paint("PaintWhite", (0.85, 0.85, 0.82), 0.7)
        elif key == "yellow":
            _mats[key] = M.paint("PaintYellow", (0.85, 0.62, 0.08), 0.7)
        elif key == "pole":
            _mats[key] = M.color("Pole", (0.12, 0.13, 0.14), 0.4, 0.6)
        elif key == "lamp":
            _mats[key] = M.color("LampGlass", (1.0, 0.95, 0.85), 0.2)
        elif key == "palm_trunk":
            _mats[key] = M.color("PalmTrunk", (0.42, 0.33, 0.24), 0.9)
        elif key == "palm_leaf":
            _mats[key] = M.color("PalmLeaf", (0.13, 0.32, 0.08), 0.6)
    return _mats[key]


def street_strip(col, x0, x1, y_front, side_w=12.0, road_w=44.0, far_side=True, markings=True):
    """Ground along +X: sidewalk [y_front-side_w, y_front], road beyond, optional far sidewalk.
    Returns the road centre-line y."""
    curb_h = 0.6
    side = G.MeshBuf("Sidewalk", tile=12.0)
    curb = G.MeshBuf("Curb", tile=6.0)
    road = G.MeshBuf("Road", tile=24.0)
    wht, yel = G.MeshBuf("LineW", 4), G.MeshBuf("LineY", 4)
    ys0 = y_front - side_w
    G.box(side, x0, ys0 + 0.5, -2, x1, y_front + 40, curb_h, skip=("bottom",))
    G.box(curb, x0, ys0, -1, x1, ys0 + 0.5, curb_h, bevel=0.12, skip=("bottom",))
    yr1, yr0 = ys0, ys0 - road_w
    G.quad(road, (x0, yr0, 0), (x1, yr0, 0), (x1, yr1, 0), (x0, yr1, 0))
    yc = (yr0 + yr1) / 2
    if markings:
        for dy in (-0.35, 0.35):
            G.quad(yel, (x0, yc + dy - 0.15, 0.02), (x1, yc + dy - 0.15, 0.02), (x1, yc + dy + 0.15, 0.02), (x0, yc + dy + 0.15, 0.02))
        for ly in (yc - road_w / 4, yc + road_w / 4):
            x = x0
            while x < x1:
                G.quad(wht, (x, ly - 0.2, 0.02), (min(x1, x + 8), ly - 0.2, 0.02), (min(x1, x + 8), ly + 0.2, 0.02), (x, ly + 0.2, 0.02))
                x += 20
        for ly in (yr0 + 0.9, yr1 - 0.9):
            G.quad(wht, (x0, ly - 0.2, 0.02), (x1, ly - 0.2, 0.02), (x1, ly + 0.2, 0.02), (x0, ly + 0.2, 0.02))
    if far_side:
        G.box(curb, x0, yr0 - 0.5, -1, x1, yr0, curb_h, bevel=0.12, skip=("bottom",))
        G.box(side, x0, yr0 - side_w - 60, -2, x1, yr0 - 0.5, curb_h, skip=("bottom",))
    for b, k in ((side, "sidewalk"), (curb, "curb"), (road, "asphalt"), (wht, "white"), (yel, "yellow")):
        if not b.empty():
            G.to_object(b, _m(k), col, weighted=False)
    return yc


def street_lamp(col, x, y, facing=1, h=16.0):
    b = G.MeshBuf("Lamp", 4)
    G.cylinder(b, x, y, 0.6, h, 0.25, seg=10, r1=0.18)
    G.cylinder(b, x, y, 0.6, 1.6, 0.45, seg=10)
    G.hcylinder(b, (x, y, h - 0.2), (x, y + facing * 4.0, h + 0.4), 0.14, seg=6)
    G.box(b, x - 0.5, y + facing * 3.6 - 0.9, h - 0.2, x + 0.5, y + facing * 3.6 + 0.9, h + 0.6, bevel=0.15)
    G.to_object(b, _m("pole"), col)


def palm(col, x, y, h=26.0, seed=0):
    import random
    r = random.Random(seed)
    t = G.MeshBuf("PalmTrunk", 4)
    lean = Vector((r.uniform(-1, 1), r.uniform(-1, 1), 0)).normalized() * r.uniform(0.6, 2.2)
    pts = [Vector((x, y, 0.6)) + lean * ((k / 6) ** 2) + Vector((0, 0, h * k / 6)) for k in range(7)]
    for k in range(6):
        G.hcylinder(t, pts[k], pts[k + 1] + (pts[k + 1] - pts[k]) * 0.04, 0.75 - 0.3 * k / 6, seg=8)
    G.to_object(t, _m("palm_trunk"), col)
    lf = G.MeshBuf("PalmLeaf", 4)
    top = pts[-1]
    n = 9
    for k in range(n):
        a = 2 * math.pi * k / n + r.uniform(-0.2, 0.2)
        L = r.uniform(8, 11)
        droop = r.uniform(4, 7)
        d = Vector((math.cos(a), math.sin(a), 0))
        side = Vector((-d.y, d.x, 0))
        segs = 5
        prev = None
        for j in range(segs + 1):
            s = j / segs
            c = top + d * (L * s) + Vector((0, 0, 1.2 * s - droop * s * s))
            wdt = 1.6 * math.sin(math.pi * min(1, s * 1.1 + 0.05))
            l, rr = c + side * wdt + Vector((0, 0, -0.35 * wdt)), c - side * wdt + Vector((0, 0, -0.35 * wdt))
            if prev:
                G.quad(lf, prev[0], prev[2], c, l, uv=(0, 0, 1, 1))
                G.quad(lf, prev[2], prev[1], rr, c, uv=(0, 0, 1, 1))
            prev = (l, rr, c)
    G.to_object(lf, _m("palm_leaf"), col, sharp_deg=80)
