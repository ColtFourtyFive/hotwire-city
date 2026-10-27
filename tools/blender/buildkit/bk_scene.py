"""Preview scene helpers (Cycles CPU): GTA-style late-afternoon lighting, streets, lots and props.

Lighting = Poly Haven pure-sky HDRI with the sun disc painted out (cached EXR) for sky fill + a real Sun lamp
placed exactly where the HDRI sun was, with the irradiance measured from the removed pixels. That gives crisp,
warm GTA-like shadows and a matching sky. Aerial perspective = mist-pass haze in the compositor (CPU).
Props (palms, lamps, cars, trees) exist only in previews; they are NOT exported with the buildings.
"""
import json, math, os, random
import bpy
import numpy as np
from mathutils import Vector

import bk_geo as G
import bk_mat as M

HERE = os.path.dirname(os.path.abspath(__file__))
HDRI = os.path.join(HERE, "_cache", "hdri")


def reset(res=(960, 540)):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _mats.clear()
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
    c.transparent_max_bounces = 8
    c.caustics_reflective = c.caustics_refractive = False
    c.sample_clamp_indirect = 6.0
    s.render.threads_mode = "FIXED"
    s.render.threads = 4
    s.render.resolution_x, s.render.resolution_y = res
    s.render.resolution_percentage = 100
    s.view_settings.view_transform = "AgX"
    for look in ("AgX - Medium High Contrast", "AgX - Punchy", "Medium High Contrast"):
        try:
            s.view_settings.look = look
            break
        except Exception:
            continue
    s.view_settings.exposure = -0.7
    s.render.image_settings.file_format = "PNG"
    return s


# ----------------------------------------------------------------------------- sky
def prep_sky(sky):
    """Paint the sun out of the HDRI once; returns dict(az, el, irradiance, color, path)."""
    meta_p = os.path.join(HDRI, f"{sky}_nosun.json")
    exr_p = os.path.join(HDRI, f"{sky}_nosun.exr")
    if os.path.exists(meta_p) and os.path.exists(exr_p):
        return dict(json.load(open(meta_p)), path=exr_p)
    im = bpy.data.images.load(os.path.join(HDRI, sky + ".hdr"))
    W, H = im.size
    a = np.empty(W * H * 4, np.float32)
    im.pixels.foreach_get(a)
    a = a.reshape(H, W, 4)
    rgb = a[..., :3]
    L = rgb @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    med = float(np.median(L))
    thr = max(30.0, med * 120)
    m = L > thr
    info = {"az": 0.0, "el": 0.0, "irradiance": 0.0, "color": [1, 1, 1]}
    if m.any():
        ys, xs = np.nonzero(m)
        lat = ((ys + 0.5) / H - 0.5) * math.pi
        dOm = (2 * math.pi / W) * (math.pi / H) * np.cos(lat)
        # neighbourhood fill value: median of a ring around the disc
        y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
        pad = max(4, (y1 - y0) * 2)
        ring = rgb[max(0, y0 - pad):y1 + pad + 1, max(0, x0 - pad):x1 + pad + 1].reshape(-1, 3)
        ringL = ring @ np.array([0.2126, 0.7152, 0.0722], np.float32)
        fillc = np.median(ring[ringL < thr], axis=0) if (ringL < thr).any() else np.array([thr] * 3)
        excess = rgb[m] - fillc[None, :]
        E_rgb = (excess * dOm[:, None]).sum(0)
        E = float(E_rgb @ np.array([0.2126, 0.7152, 0.0722]))
        w = L[m] * dOm
        u = float((xs * w).sum() / w.sum() + 0.5) / W
        v = float((ys * w).sum() / w.sum() + 0.5) / H
        info = {"az": (0.5 - u) * 360.0, "el": (v - 0.5) * 180.0, "irradiance": E,
                "color": (E_rgb / max(1e-6, E_rgb.max())).tolist()}
        rgb[m] = fillc
    # downsample to <= 2k wide (sky only, sun is a lamp now)
    if W > 2048:
        f = W // 2048
        rgb = rgb.reshape(H // f, f, W // f, f, 3).mean((1, 3))
        H, W = H // f, W // f
    out = bpy.data.images.new(sky + "_nosun", W, H, alpha=False, float_buffer=True)
    px = np.ones((H, W, 4), np.float32)
    px[..., :3] = rgb
    out.pixels.foreach_set(px.ravel())
    out.filepath_raw = exr_p
    out.file_format = "OPEN_EXR"
    out.save()
    json.dump(info, open(meta_p, "w"), indent=1)
    return dict(info, path=exr_p)


def world(sky="sky_late_afternoon", sun_az=-55.0, strength=1.0, sun=True, sun_scale=1.0, sun_el=None,
          sun_tint=(1.0, 0.93, 0.82), sky_gain=2.2):
    """sun_az: azimuth (deg, from +X towards +Y) of the direction pointing AT the sun.
    The sky is rotated so its painted-out sun sits at sun_az; a Sun lamp replaces it."""
    info = prep_sky(sky)
    w = bpy.data.worlds.new("Sky")
    bpy.context.scene.world = w
    w.use_nodes = True
    nt = w.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    tc = nt.nodes.new("ShaderNodeTexCoord")
    mp = nt.nodes.new("ShaderNodeMapping")
    env = nt.nodes.new("ShaderNodeTexEnvironment")
    env.image = bpy.data.images.load(info["path"], check_existing=True)
    bg = nt.nodes.new("ShaderNodeBackground")
    out = nt.nodes.new("ShaderNodeOutputWorld")
    nt.links.new(tc.outputs["Generated"], mp.inputs[0])
    nt.links.new(mp.outputs[0], env.inputs[0])
    nt.links.new(env.outputs[0], bg.inputs[0])
    nt.links.new(bg.outputs[0], out.inputs[0])
    bg.inputs[1].default_value = strength * (sky_gain if sun else 1.0)   # GTA-style lifted, blue shadows
    mp.inputs["Rotation"].default_value[2] = math.radians(info["az"] - sun_az)
    w.mist_settings.start, w.mist_settings.depth, w.mist_settings.falloff = 120.0, 2600.0, "LINEAR"
    if sun and info["irradiance"] > 0:
        el = info["el"] if sun_el is None else sun_el
        ld = bpy.data.lights.new("Sun", "SUN")
        ld.energy = info["irradiance"] * sun_scale * strength
        c = info["color"]
        ld.color = tuple(min(1.0, c[k] * sun_tint[k] / max(c[0] * sun_tint[0], 1e-6)) for k in range(3))
        ld.angle = math.radians(0.6)
        ob = bpy.data.objects.new("Sun", ld)
        bpy.context.scene.collection.objects.link(ob)
        d = Vector((math.cos(math.radians(el)) * math.cos(math.radians(sun_az)),
                    math.cos(math.radians(el)) * math.sin(math.radians(sun_az)), math.sin(math.radians(el))))
        ob.rotation_euler = d.to_track_quat("Z", "Y").to_euler()
    return w


def night(strength=0.06):
    """Blue-hour night: dusk HDRI very dim, no sun."""
    w = world("sky_dusk", sun=False, strength=strength)
    return w


def look(cam, target):
    d = Vector(target) - cam.location
    cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()


def camera(loc, target, lens=28.0, shift_y=0.0, shift_x=0.0):
    cd = bpy.data.cameras.new("Cam")
    cd.lens = lens
    cd.shift_y, cd.shift_x = shift_y, shift_x
    cd.clip_start, cd.clip_end = 0.5, 8000
    cam = bpy.data.objects.new("Cam", cd)
    bpy.context.scene.collection.objects.link(cam)
    cam.location = Vector(loc)
    look(cam, target)
    bpy.context.scene.camera = cam
    return cam


def haze(color=(0.62, 0.70, 0.80), amount=0.55, night=False):
    """Aerial perspective through the compositor: mix toward `color` by the mist pass."""
    s = bpy.context.scene
    s.view_layers[0].use_pass_mist = True
    ng = bpy.data.node_groups.new("Comp", "CompositorNodeTree")
    s.compositing_node_group = ng
    try:
        s.render.compositor_device = "CPU"
    except Exception:
        pass
    rl = ng.nodes.new("CompositorNodeRLayers")
    mul = ng.nodes.new("ShaderNodeMath"); mul.operation = "MULTIPLY"; mul.use_clamp = True
    mul.inputs[1].default_value = amount
    lt = ng.nodes.new("ShaderNodeMath"); lt.operation = "LESS_THAN"; lt.inputs[1].default_value = 0.995
    m2 = ng.nodes.new("ShaderNodeMath"); m2.operation = "MULTIPLY"
    ng.links.new(rl.outputs["Mist"], lt.inputs[0])
    mix = ng.nodes.new("ShaderNodeMix"); mix.data_type = "RGBA"
    ng.interface.new_socket("Image", in_out="OUTPUT", socket_type="NodeSocketColor")
    out = ng.nodes.new("NodeGroupOutput")
    ng.links.new(rl.outputs["Mist"], mul.inputs[0])
    ng.links.new(mul.outputs[0], m2.inputs[0])
    ng.links.new(lt.outputs[0], m2.inputs[1])
    ng.links.new(m2.outputs[0], mix.inputs[0])
    ng.links.new(rl.outputs["Image"], mix.inputs[6])
    mix.inputs[7].default_value = (*color, 1)
    last = mix.outputs[2]
    if night:
        gl = ng.nodes.new("CompositorNodeGlare")
        try:
            gl.glare_type = "BLOOM"          # Blender <= 4.x
        except Exception:
            pass
        if "Type" in gl.inputs:              # Blender 5.x: the glare type is a menu socket
            try:
                gl.inputs["Type"].default_value = "Bloom"
            except Exception:
                pass
        for k, v in (("Threshold", 1.0), ("Strength", 0.6), ("Size", 0.6)):
            if k in gl.inputs:
                try:
                    gl.inputs[k].default_value = v
                except Exception:
                    pass
        ng.links.new(last, gl.inputs[0])
        last = gl.outputs[0]
    ng.links.new(last, out.inputs[0])


def render(path, samples=None, res=None):
    s = bpy.context.scene
    if samples:
        s.cycles.samples = samples
    if res:
        s.render.resolution_x, s.render.resolution_y = res
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    s.render.filepath = path
    bpy.ops.render.render(write_still=True)


# ----------------------------------------------------------------------------- materials for scene props
_mats = {}


def _m(key):
    if key in _mats:
        return _mats[key]
    T = {"asphalt": lambda: M.textured("Asphalt", "asphalt", tint=(0.9, 0.9, 0.92), rough=1.0),
         "sidewalk": lambda: M.textured("Sidewalk", "sidewalk", tint=(0.92, 0.93, 0.95)),
         "curb": lambda: M.textured("Curb", "curb", tint=(1.05, 1.05, 1.05)),
         "grass": lambda: M.textured("Grass", "grass", tint=(0.8, 0.98, 0.65)),
         "dirt": lambda: M.textured("Dirt", "roof_gravel", tint=(0.75, 0.62, 0.48)),
         "drygrass": lambda: M.textured("DryGrass", "grass", tint=(0.95, 0.85, 0.55)),
         "sand": lambda: M.textured("Sand", "sand", tint=(1.05, 1.0, 0.92)),
         "sea": lambda: M.water("Sea", (0.04, 0.22, 0.30)),
         "white": lambda: M.paint("PaintWhite", (0.85, 0.85, 0.82), 0.7),
         "yellow": lambda: M.paint("PaintYellow", (0.85, 0.62, 0.08), 0.7),
         "pole": lambda: M.color("Pole", (0.30, 0.31, 0.32), 0.45, 0.8),
         "lamp": lambda: M.neon("LampHead", (1.0, 0.62, 0.25), 0.0, day_rgb=(0.9, 0.88, 0.8)),
         "palm_trunk": lambda: M.color("PalmTrunk", (0.36, 0.30, 0.24), 0.95),
         "palm_leaf": lambda: M.color("PalmLeaf", (0.16, 0.24, 0.08), 0.55),
         "palm_dead": lambda: M.color("PalmDead", (0.42, 0.33, 0.22), 0.9),
         "tree_trunk": lambda: M.color("TreeTrunk", (0.22, 0.18, 0.14), 0.9),
         "tree_leaf": lambda: M.color("TreeLeaf", (0.10, 0.20, 0.06), 0.6),
         "tree_leaf2": lambda: M.color("TreeLeaf2", (0.16, 0.25, 0.08), 0.6),
         "bush": lambda: M.color("Bush", (0.09, 0.18, 0.06), 0.7),
         "rock": lambda: M.textured("Rock", "concrete", tint=(0.72, 0.62, 0.5)),
         "tire": lambda: M.color("Tire", (0.03, 0.03, 0.03), 0.8),
         "rim": lambda: M.color("Rim", (0.6, 0.62, 0.64), 0.25, 1.0),
         "carglass": lambda: M.color("CarGlass", (0.02, 0.025, 0.03), 0.05),
         "chrome": lambda: M.color("Chrome", (0.8, 0.8, 0.8), 0.1, 1.0),
         "tail": lambda: M.color("TailLight", (0.5, 0.02, 0.02), 0.2),
         "head": lambda: M.color("HeadLight", (0.9, 0.9, 0.85), 0.1),
         }
    _mats[key] = T[key]()
    return _mats[key]


def car_paint(rgb):
    k = "paint_%.2f_%.2f_%.2f" % tuple(rgb)
    if k not in _mats:
        m = M.color(k, rgb, 0.25, 0.4)
        bsdf = m.node_tree.nodes["Principled BSDF"]
        bsdf.inputs["Coat Weight"].default_value = 1.0
        _mats[k] = m
    return _mats[k]


# ----------------------------------------------------------------------------- ground
def street_strip(col, x0, x1, y_front, side_w=12.0, road_w=44.0, far_side=True, markings=True, far_w=60.0,
                 curb_h=0.6):
    """Ground along +X: sidewalk [y_front-side_w, y_front] (+40 behind for the lot), road beyond, optional far
    sidewalk. Returns the road centre-line y."""
    side = G.MeshBuf("Sidewalk", tile=12.0)
    curb = G.MeshBuf("Curb", tile=6.0)
    road = G.MeshBuf("Road", tile=24.0)
    wht, yel = G.MeshBuf("LineW", 4), G.MeshBuf("LineY", 4)
    ys0 = y_front - side_w
    G.box(side, x0, ys0 + 0.5, -2, x1, y_front + 0.02, curb_h, skip=("bottom",))
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
                x += 24
        for ly in (yr0 + 1.2, yr1 - 1.2):
            G.quad(wht, (x0, ly - 0.2, 0.02), (x1, ly - 0.2, 0.02), (x1, ly + 0.2, 0.02), (x0, ly + 0.2, 0.02))
    if far_side:
        G.box(curb, x0, yr0 - 0.5, -1, x1, yr0, curb_h, bevel=0.12, skip=("bottom",))
        G.box(side, x0, yr0 - far_w, -2, x1, yr0 - 0.5, curb_h, skip=("bottom",))
    for b, k in ((side, "sidewalk"), (curb, "curb"), (road, "asphalt"), (wht, "white"), (yel, "yellow")):
        if not b.empty():
            G.to_object(b, _m(k), col, weighted=False)
    return yc


def ground(col, x0, y0, x1, y1, kind="grass", z=0.0, tile=None):
    b = G.MeshBuf("Ground_" + kind, tile=tile or {"grass": 20.0, "asphalt": 24.0, "sidewalk": 12.0, "sand": 30.0,
                                                    "dirt": 20.0, "sea": 60.0, "curb": 8.0, "drygrass": 30.0}.get(kind, 20))
    G.quad(b, (x0, y0, z), (x1, y0, z), (x1, y1, z), (x0, y1, z))
    return G.to_object(b, _m(kind), col, weighted=False)


def road(col, x0, y0, x1, y1, axis="x", lanes=True, z=0.0):
    """Plain road patch with centre double-yellow and dashed lane lines."""
    ground(col, x0, y0, x1, y1, "asphalt", z)
    wht, yel = G.MeshBuf("LineW", 4), G.MeshBuf("LineY", 4)
    if axis == "x":
        yc = (y0 + y1) / 2
        for dy in (-0.35, 0.35):
            G.quad(yel, (x0, yc + dy - 0.15, z + 0.02), (x1, yc + dy - 0.15, z + 0.02), (x1, yc + dy + 0.15, z + 0.02), (x0, yc + dy + 0.15, z + 0.02))
        if lanes:
            for ly in (yc - (y1 - y0) / 4, yc + (y1 - y0) / 4):
                x = x0
                while x < x1:
                    G.quad(wht, (x, ly - 0.2, z + 0.02), (min(x1, x + 8), ly - 0.2, z + 0.02), (min(x1, x + 8), ly + 0.2, z + 0.02), (x, ly + 0.2, z + 0.02))
                    x += 24
    else:
        xc = (x0 + x1) / 2
        for dx in (-0.35, 0.35):
            G.quad(yel, (xc + dx - 0.15, y0, z + 0.02), (xc + dx + 0.15, y0, z + 0.02), (xc + dx + 0.15, y1, z + 0.02), (xc + dx - 0.15, y1, z + 0.02))
        if lanes:
            for lx in (xc - (x1 - x0) / 4, xc + (x1 - x0) / 4):
                y = y0
                while y < y1:
                    G.quad(wht, (lx - 0.2, y, z + 0.02), (lx + 0.2, y, z + 0.02), (lx + 0.2, min(y1, y + 8), z + 0.02), (lx - 0.2, min(y1, y + 8), z + 0.02))
                    y += 24
    for b, k in ((wht, "white"), (yel, "yellow")):
        if not b.empty():
            G.to_object(b, _m(k), col, weighted=False)


def sidewalk_block(col, x0, y0, x1, y1, h=0.6):
    """Raised sidewalk slab with curb all around (a city block's pavement ring)."""
    side = G.MeshBuf("Sidewalk", tile=12.0)
    curb = G.MeshBuf("Curb", tile=6.0)
    G.box(side, x0 + 0.5, y0 + 0.5, -1, x1 - 0.5, y1 - 0.5, h, skip=("bottom",))
    for (a, b, c, d) in ((x0, y0, x1, y0 + 0.5), (x0, y1 - 0.5, x1, y1), (x0, y0 + 0.5, x0 + 0.5, y1 - 0.5), (x1 - 0.5, y0 + 0.5, x1, y1 - 0.5)):
        G.box(curb, a, b, -1, c, d, h, skip=("bottom",))
    G.to_object(side, _m("sidewalk"), col, weighted=False)
    G.to_object(curb, _m("curb"), col, weighted=False)


# ----------------------------------------------------------------------------- props
def street_lamp(col, x, y, facing=(0, -1), h=26.0, night=False):
    """Cobra-head street light (LA style). facing = unit 2D direction the arm reaches over the road."""
    fx, fy = facing
    b = G.MeshBuf("Lamp", 4)
    G.cylinder(b, x, y, 0.6, h, 0.32, seg=10, r1=0.2)
    G.cylinder(b, x, y, 0.6, 2.2, 0.55, seg=10)
    arm = 7.0
    p0 = Vector((x, y, h - 0.6))
    p1 = Vector((x + fx * arm * 0.6, y + fy * arm * 0.6, h + 0.9))
    p2 = Vector((x + fx * arm, y + fy * arm, h + 1.1))
    G.hcylinder(b, p0, p1, 0.16, seg=6)
    G.hcylinder(b, p1, p2, 0.14, seg=6)
    G.to_object(b, _m("pole"), col)
    hd = G.MeshBuf("LampHead", 4)
    cx, cy = x + fx * (arm + 1.2), y + fy * (arm + 1.2)
    G.box(hd, cx - 1.3 * abs(fx) - 0.5 * abs(fy), cy - 1.3 * abs(fy) - 0.5 * abs(fx), h + 0.6,
          cx + 1.3 * abs(fx) + 0.5 * abs(fy), cy + 1.3 * abs(fy) + 0.5 * abs(fx), h + 1.3, bevel=0.2)
    G.to_object(hd, _m("lamp"), col)
    if night:
        ld = bpy.data.lights.new("StreetLight", "SPOT")
        ld.energy = 26000
        ld.color = (1.0, 0.62, 0.3)
        ld.spot_size = math.radians(120)
        ld.spot_blend = 0.6
        ld.shadow_soft_size = 0.6
        ob = bpy.data.objects.new("StreetLight", ld)
        col.objects.link(ob)
        ob.location = (cx, cy, h + 0.4)


def palm(col, x, y, h=48.0, seed=0, kind="fan"):
    """LA street palm. kind='fan': Mexican fan palm (Washingtonia) - very tall thin trunk, small dense head with
    a skirt of dead fronds; kind='date': Canary date palm - thick trunk, big pinnate crown."""
    r = random.Random(seed)
    t = G.MeshBuf("PalmTrunk", 4)
    lean = Vector((r.uniform(-1, 1), r.uniform(-1, 1), 0)).normalized() * r.uniform(0.5, 2.5)
    nseg = 8
    pts = [Vector((x, y, 0.4)) + lean * ((k / nseg) ** 2) + Vector((0, 0, h * k / nseg)) for k in range(nseg + 1)]
    r0, r1 = (0.95, 0.55) if kind == "fan" else (1.9, 1.5)
    for k in range(nseg):
        G.hcylinder(t, pts[k], pts[k + 1] + (pts[k + 1] - pts[k]) * 0.03, r0 + (r1 - r0) * k / nseg, seg=9)
    G.to_object(t, _m("palm_trunk"), col)
    top = pts[-1]
    lf = G.MeshBuf("PalmLeaf", 4)
    dead = G.MeshBuf("PalmDead", 4)
    if kind == "fan":
        # skirt of dead fronds: jagged cone hanging below the head
        sk = 3.4 if r.random() < 0.7 else 1.2
        n = 18
        for k in range(n):
            a0, a1 = 2 * math.pi * k / n, 2 * math.pi * (k + 1) / n
            rr = 1.1 + r.uniform(0, 0.5)
            ln = sk * r.uniform(0.7, 1.3)
            p = lambda a, rad, dz: (top.x + rad * math.cos(a), top.y + rad * math.sin(a), top.z + dz)
            G.quad(dead, p(a0, rr * 1.6, -ln), p(a1, rr * 1.6, -ln), p(a1, rr, 0.5), p(a0, rr, 0.5))
        G.to_object(dead, _m("palm_dead"), col, sharp_deg=80)
        nf = 22
        for k in range(nf):
            a = 2 * math.pi * k / nf + r.uniform(-0.15, 0.15)
            tilt = r.uniform(-0.6, 0.9)          # elevation of the petiole
            d = Vector((math.cos(a), math.sin(a), 0))
            pet = r.uniform(2.6, 3.6)
            base = top + Vector((0, 0, 0.6))
            hub = base + d * pet * math.cos(tilt) + Vector((0, 0, pet * math.sin(tilt)))
            G.hcylinder(lf, base, hub, 0.09, seg=4)
            # fan: ~13 leaflets spread over 140deg in a plane roughly perpendicular to the petiole
            up = Vector((0, 0, 1))
            side = d.cross(up).normalized()
            fwd = (hub - base).normalized()
            rad = r.uniform(3.4, 4.4)
            nl = 13
            for j in range(nl):
                th = math.radians(-70 + 140 * j / (nl - 1))
                dirv = (fwd * math.cos(th) + side * math.sin(th)).normalized()
                droop = Vector((0, 0, -0.55 * rad * (0.4 + 0.6 * abs(math.sin(th)))))
                tip = hub + dirv * rad + droop * 0.5
                mid = hub + dirv * rad * 0.55 + droop * 0.12
                wv = side.cross(dirv).normalized() * 0.0 + (dirv.cross(Vector((0, 0, 1))).normalized() if abs(dirv.z) < 0.95 else side) * 0.32
                fold = Vector((0, 0, 0.12 if j % 2 else -0.12))
                G.quad(lf, hub, mid - wv + fold, tip, mid + wv + fold, uv=(0, 0, 1, 1))
        G.to_object(lf, _m("palm_leaf"), col, sharp_deg=85)
    else:
        nf = 30
        for k in range(nf):
            a = 2 * math.pi * k / nf * 1.618 * 3 + r.uniform(-0.2, 0.2)
            el = r.uniform(-0.5, 0.7)
            L = r.uniform(10, 14)
            d = Vector((math.cos(a) * math.cos(el), math.sin(a) * math.cos(el), math.sin(el)))
            side = Vector((-math.sin(a), math.cos(a), 0))
            prev = None
            segs = 6
            for j in range(segs + 1):
                s = j / segs
                c = top + d * (L * s) + Vector((0, 0, -3.5 * s * s))
                wdt = 1.9 * math.sin(math.pi * min(1, s * 1.05 + 0.05))
                l, rr = c + side * wdt + Vector((0, 0, -0.5 * wdt)), c - side * wdt + Vector((0, 0, -0.5 * wdt))
                if prev:
                    G.quad(lf, prev[0], prev[2], c, l, uv=(0, 0, 1, 1))
                    G.quad(lf, prev[2], prev[1], rr, c, uv=(0, 0, 1, 1))
                prev = (l, rr, c)
        G.to_object(lf, _m("palm_leaf"), col, sharp_deg=80)


def tree(col, x, y, h=22.0, seed=0, spread=None):
    """Broadleaf street / yard tree (ficus, oak): trunk + forks + a cloud of small leaf cards."""
    r = random.Random(seed)
    spread = spread or h * 0.42
    t = G.MeshBuf("TreeTrunk", 4)
    base = Vector((x, y, 0))
    fork = base + Vector((r.uniform(-0.6, 0.6), r.uniform(-0.6, 0.6), h * 0.38))
    G.hcylinder(t, base, fork, 0.9, seg=8)
    crown_c = Vector((x, y, h * 0.66))
    for k in range(4):
        a = r.uniform(0, 2 * math.pi)
        tip = crown_c + Vector((math.cos(a) * spread * 0.5, math.sin(a) * spread * 0.5, r.uniform(-1, h * 0.15)))
        G.hcylinder(t, fork, tip, 0.45, seg=6)
    G.to_object(t, _m("tree_trunk"), col)
    lobes = [crown_c + Vector((r.uniform(-0.5, 0.5) * spread, r.uniform(-0.5, 0.5) * spread, r.uniform(-0.1, 0.25) * h))
             for _ in range(4)]
    for key in ("tree_leaf", "tree_leaf2"):
        lf = G.MeshBuf("Leaves", 4)
        n = 1500
        for i in range(n):
            # sample inside a lumpy ellipsoid, biased to the surface
            while True:
                v = Vector((r.uniform(-1, 1), r.uniform(-1, 1), r.uniform(-1, 1)))
                if v.length <= 1:
                    break
            v = v.normalized() * (v.length ** 0.35)
            cc = lobes[i % len(lobes)]
            p = cc + Vector((v.x * spread * 0.62, v.y * spread * 0.62, v.z * h * 0.24))
            s = r.uniform(0.55, 1.0)
            a = Vector((r.uniform(-1, 1), r.uniform(-1, 1), r.uniform(-0.3, 1))).normalized()
            b = a.cross(Vector((r.uniform(-1, 1), r.uniform(-1, 1), r.uniform(-1, 1)))).normalized()
            G.tri(lf, tuple(p), tuple(p + a * s), tuple(p + b * s))
        G.to_object(lf, _m(key), col, sharp_deg=89, weighted=False)


def bush(col, x, y, w=4.0, h=3.0, seed=0, n=220):
    r = random.Random(seed)
    lf = G.MeshBuf("Bush", 4)
    c = Vector((x, y, h * 0.5))
    for i in range(n):
        v = Vector((r.uniform(-1, 1), r.uniform(-1, 1), r.uniform(-1, 1)))
        if v.length > 1:
            continue
        p = c + Vector((v.x * w / 2, v.y * w / 2, v.z * h / 2))
        s = r.uniform(0.5, 0.9)
        a = Vector((r.uniform(-1, 1), r.uniform(-1, 1), r.uniform(-0.2, 1))).normalized()
        b = a.cross(Vector((r.uniform(-1, 1), r.uniform(-1, 1), r.uniform(-1, 1)))).normalized()
        G.tri(lf, tuple(p), tuple(p + a * s), tuple(p + b * s))
    G.to_object(lf, _m("bush"), col, sharp_deg=89, weighted=False)


CAR_COLORS = [(0.62, 0.63, 0.64), (0.03, 0.03, 0.035), (0.85, 0.85, 0.84), (0.05, 0.09, 0.2), (0.35, 0.02, 0.02),
              (0.25, 0.26, 0.27), (0.75, 0.75, 0.73), (0.08, 0.15, 0.1), (0.45, 0.38, 0.28)]


CAR_PROFILES = {
    # lower body side profile (x forward, z up) and greenhouse profile, in studs (sedan ~16.6 long)
    "sedan": dict(L=16.6, W=6.7, body=[(8.2, 1.15), (8.35, 2.1), (8.05, 3.05), (5.0, 3.55), (-5.4, 3.75), (-8.0, 3.55),
                                         (-8.35, 2.3), (-8.2, 1.15)],
                  cabin=[(4.7, 3.55), (1.5, 5.2), (-2.7, 5.25), (-5.5, 3.75)], wheels=(5.15, -5.0), r=1.35),
    "suv": dict(L=17.0, W=7.1, body=[(8.4, 1.5), (8.55, 2.6), (8.3, 3.9), (5.4, 4.4), (-7.9, 4.5), (-8.5, 4.2),
                                       (-8.5, 2.4), (-8.3, 1.5)],
                cabin=[(5.1, 4.4), (2.6, 6.6), (-7.6, 6.6), (-8.1, 4.5)], wheels=(5.4, -5.4), r=1.6),
    "hatch": dict(L=14.4, W=6.5, body=[(7.1, 1.15), (7.25, 2.1), (6.95, 3.0), (4.2, 3.55), (-6.5, 3.75), (-7.2, 3.5),
                                         (-7.25, 2.2), (-7.1, 1.15)],
                  cabin=[(3.9, 3.55), (1.0, 5.25), (-5.6, 5.3), (-6.9, 3.75)], wheels=(4.6, -4.5), r=1.3),
}


def _extrude_profile(buf, prof, w0, w1=None):
    """Prism of a convex side profile [(x, z)] across y in [-w/2, w/2]; w1 = width at the top (tumblehome)."""
    w1 = w0 if w1 is None else w1
    zs = [p[1] for p in prof]
    zmin, zmax = min(zs), max(zs)
    def hw(z):
        t = (z - zmin) / max(1e-6, zmax - zmin)
        return (w0 + (w1 - w0) * t) / 2
    L = [(x, -hw(z), z) for x, z in prof]
    R = [(x, hw(z), z) for x, z in prof]
    n = len(prof)
    P = L + R
    faces = []
    for i in range(n):
        j = (i + 1) % n
        faces.append((i, j, n + j, n + i))
    faces.append(tuple(range(n)))
    faces.append(tuple(range(n, 2 * n))[::-1])
    cx = sum(p[0] for p in prof) / n
    cz = sum(p[1] for p in prof) / n
    buf.add(P, G._orient(P, faces, (cx, 0.0, cz)))


def car(col, x, y, heading=0.0, seed=0, kind=None, rgb=None):
    """Scale-reference parked car (sedan ~16.6 studs). heading in degrees (0 = nose to +X)."""
    r = random.Random(seed)
    kind = kind or r.choice(["sedan", "sedan", "suv", "hatch"])
    rgb = rgb or r.choice(CAR_COLORS)
    P = CAR_PROFILES[kind]
    Wd = P["W"]
    body, glass, wheels, rims, lights_f, lights_r = (G.MeshBuf(n, 4) for n in ("CarBody", "CarGlass", "Tire", "Rim", "Head", "Tail"))
    _extrude_profile(body, P["body"], Wd, Wd - 0.35)
    _extrude_profile(glass, P["cabin"], Wd - 0.5, Wd - 1.7)
    # roof skin in body colour, slightly above the glass top edge
    cab = P["cabin"]
    zr = max(c[1] for c in cab) + 0.04
    x0r, x1r = cab[2][0] + 0.2, cab[1][0] - 0.25
    G.box(body, x0r, -(Wd - 1.75) / 2, zr - 0.12, x1r, (Wd - 1.75) / 2, zr)
    zb = cab[0][1]
    rr = P["r"]
    for ax in P["wheels"]:
        for sy in (-1, 1):
            cy = sy * (Wd / 2 - 0.5)
            G.hcylinder(wheels, (ax, cy - 0.6, rr), (ax, cy + 0.6, rr), rr, seg=16)
            G.hcylinder(rims, (ax, cy + sy * 0.58, rr), (ax, cy + sy * 0.66, rr), rr * 0.62, seg=12)
            # fake wheel well: dark disc just proud of the body side, behind the tyre
            ring = [(ax + (rr + 0.3) * math.cos(2 * math.pi * k / 16), sy * (Wd / 2 + 0.03),
                     rr + 0.05 + (rr + 0.3) * math.sin(2 * math.pi * k / 16)) for k in range(16)]
            G.poly(wheels, ring if sy < 0 else ring[::-1])
    fx = P["body"][2][0]
    rx = P["body"][6][0]
    zf = P["body"][2][1]
    for sy in (-1, 1):
        G.box(lights_f, fx - 0.3, sy * (Wd / 2 - 1.5) - 0.75, zf - 0.75, fx + 0.12, sy * (Wd / 2 - 1.5) + 0.75, zf - 0.3)
        G.box(lights_r, rx - 0.12, sy * (Wd / 2 - 1.2) - 0.85, zf - 0.55, rx + 0.3, sy * (Wd / 2 - 1.2) + 0.85, zf - 0.1)
        G.box(body, 3.4, sy * (Wd / 2 + 0.35) - 0.3, zb + 0.2, 4.0, sy * (Wd / 2 + 0.35) + 0.3, zb + 0.8)   # mirrors
    root = bpy.data.objects.new("Car", None)
    col.objects.link(root)
    root.location = (x, y, 0)
    root.rotation_euler = (0, 0, math.radians(heading))
    for b, m in ((body, car_paint(rgb)), (glass, _m("carglass")), (wheels, _m("tire")), (rims, _m("rim")),
                 (lights_f, _m("head")), (lights_r, _m("tail"))):
        G.to_object(b, m, col, parent=root, weighted=(b is body), sharp_deg=35)
    return root


def parked_row(col, x0, x1, y, heading=0.0, gap=(3.0, 8.0), seed=0, prob=0.8):
    r = random.Random(seed)
    x = x0
    while x < x1 - 17:
        if r.random() < prob:
            car(col, x + 8.5, y, heading + (180 if r.random() < 0.15 else 0), seed=r.randint(0, 10_000))
        x += 17 + r.uniform(*gap)


def hill(col, x0, y0, x1, y1, z_fn, nx=40, ny=40, kind="dirt", skip=None):
    """Height-field terrain patch for hillside previews. skip(x, y) -> True leaves a hole (e.g. under a lot)."""
    b = G.MeshBuf("Hill", 20)
    for i in range(nx):
        for j in range(ny):
            xa, xb = x0 + (x1 - x0) * i / nx, x0 + (x1 - x0) * (i + 1) / nx
            ya, yb = y0 + (y1 - y0) * j / ny, y0 + (y1 - y0) * (j + 1) / ny
            if skip is not None and skip((xa + xb) / 2, (ya + yb) / 2):
                continue
            G.quad(b, (xa, ya, z_fn(xa, ya)), (xb, ya, z_fn(xb, ya)), (xb, yb, z_fn(xb, yb)), (xa, yb, z_fn(xa, yb)))
    return G.to_object(b, _m(kind), col, weighted=False, sharp_deg=60)
