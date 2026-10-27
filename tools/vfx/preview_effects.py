#!/usr/bin/env python3
"""Offline preview of the VFX presets in context: simulates the real Config/VFX presets (sizes, speeds, drag,
acceleration, spread, color / size / transparency sequences, flipbooks, orientation, light emission) and composites
the uploaded textures over a simple street scene with a car-sized reference block. It approximates the engine
(no lighting, no depth-sorting against geometry), good for judging scale, timing, color and density.

Usage:
  lune run tools/vfx/dump_presets.luau /tmp/presets.json
  python3 tools/vfx/preview_effects.py /tmp/presets.json [outdir]   -> outdir/preview_effects.png (+ per-scene pngs)
"""
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
TEX = os.path.join(ROOT, "assets", "vfx")
W, H = 640, 400
FOV = math.radians(70)
RNG = np.random.default_rng(3)
DT = 1 / 60
GRID = {"Grid2x2": 2, "Grid4x4": 4, "Grid8x8": 8}

_tex_cache = {}


def texture(key):
    if key not in _tex_cache:
        im = np.asarray(Image.open(os.path.join(TEX, key + ".png")).convert("RGBA"), dtype=np.float32) / 255.0
        _tex_cache[key] = im
    return _tex_cache[key]


def frame_of(key, layout, idx):
    im = texture(key)
    n = GRID.get(layout or "", 1)
    if n == 1:
        return im
    h, w, _ = im.shape
    ch, cw = h // n, w // n
    r, c = divmod(idx % (n * n), n)
    return im[r * ch:(r + 1) * ch, c * cw:(c + 1) * cw]


# ----------------------------------------------------------------------------------------------------------------
# camera
# ----------------------------------------------------------------------------------------------------------------
class Cam:
    def __init__(self, eye, target):
        self.eye = np.array(eye, dtype=np.float64)
        fwd = np.array(target, dtype=np.float64) - self.eye
        self.fwd = fwd / np.linalg.norm(fwd)
        right = np.cross(self.fwd, [0, 1, 0])
        self.right = right / np.linalg.norm(right)
        self.up = np.cross(self.right, self.fwd)
        self.f = (H / 2) / math.tan(FOV / 2)

    def project(self, p):
        d = np.asarray(p, dtype=np.float64) - self.eye
        z = d @ self.fwd
        if z < 0.5:
            return None
        x = d @ self.right
        y = d @ self.up
        return np.array([W / 2 + self.f * x / z, H / 2 - self.f * y / z]), z


# ----------------------------------------------------------------------------------------------------------------
# sequences
# ----------------------------------------------------------------------------------------------------------------
def seq_eval(keys, a, u=0.0):
    a = min(max(a, 0.0), 1.0)
    for i in range(1, len(keys)):
        k0, k1 = keys[i - 1], keys[i]
        if a <= k1["t"]:
            f = (a - k0["t"]) / max(k1["t"] - k0["t"], 1e-6)
            v = k0["v"] + (k1["v"] - k0["v"]) * f
            e = k0.get("e", 0) + (k1.get("e", 0) - k0.get("e", 0)) * f
            return v + u * e
    return keys[-1]["v"] + u * keys[-1].get("e", 0)


def color_eval(keys, a):
    if not keys:
        return np.ones(3)
    a = min(max(a, 0.0), 1.0)
    for i in range(1, len(keys)):
        k0, k1 = keys[i - 1], keys[i]
        if a <= k1["t"]:
            f = (a - k0["t"]) / max(k1["t"] - k0["t"], 1e-6)
            return (np.array(k0["c"]) * (1 - f) + np.array(k1["c"]) * f) / 255.0
    return np.array(keys[-1]["c"]) / 255.0


# ----------------------------------------------------------------------------------------------------------------
# particles
# ----------------------------------------------------------------------------------------------------------------
def basis(direction):
    d = np.asarray(direction, dtype=np.float64)
    d = d / (np.linalg.norm(d) + 1e-9)
    a = np.cross(d, [0, 1, 0]) if abs(d[1]) < 0.99 else np.cross(d, [1, 0, 0])
    a /= np.linalg.norm(a)
    b = np.cross(a, d)
    return d, a, b


def spawn(preset, pos, direction, n, overrides=None):
    o = overrides or {}
    out = []
    d, a, b = basis(direction)
    lo, hi = preset["lifetime"][0], preset["lifetime"][-1]
    sp = preset.get("speed", [0, 0])
    spread = preset.get("spread", [0, 0])
    for _ in range(n):
        ax = math.radians(RNG.uniform(-spread[0], spread[0]))
        ay = math.radians(RNG.uniform(-spread[-1], spread[-1]))
        v = d * math.cos(ax) * math.cos(ay) + a * math.sin(ax) + b * math.sin(ay) * math.cos(ax)
        v = v / (np.linalg.norm(v) + 1e-9)
        speed = RNG.uniform(sp[0], sp[-1])
        rot = preset.get("rotation", [0, 0])
        rs = preset.get("rotSpeed", [0, 0])
        fb = preset.get("flipbook") or {}
        out.append({
            "p": np.array(pos, dtype=np.float64), "v": v * speed, "age": 0.0, "life": RNG.uniform(lo, hi),
            "u": RNG.uniform(-1, 1), "rot": RNG.uniform(rot[0], rot[-1]), "rs": RNG.uniform(rs[0], rs[-1]),
            "frame0": RNG.integers(0, 64) if fb.get("startRandom") else 0,
            "fps": RNG.uniform(*(fb.get("fps") or [30, 30])) if fb else 0,
            "preset": preset, "scale": o.get("scale", 1.0), "color": o.get("color"),
        })
    return out


def step(parts, dt):
    alive = []
    for q in parts:
        pr = q["preset"]
        q["age"] += dt
        if q["age"] >= q["life"]:
            continue
        acc = np.array(pr.get("acceleration", [0, 0, 0]), dtype=np.float64)
        q["v"] = q["v"] + acc * dt
        drag = pr.get("drag", 0)
        if drag:
            q["v"] = q["v"] * (2 ** (-drag * dt))
        q["p"] = q["p"] + q["v"] * dt
        q["rot"] += q["rs"] * dt
        alive.append(q)
    return alive


def homography(src, dst):
    """3x3 H with dst ~ H * src (4 point pairs)."""
    A = []
    for (x, y), (u, v) in zip(src, dst):
        A.append([x, y, 1, 0, 0, 0, -u * x, -u * y, -u])
        A.append([0, 0, 0, x, y, 1, -v * x, -v * y, -v])
    _, _, vt = np.linalg.svd(np.array(A))
    Hm = vt[-1].reshape(3, 3)
    return Hm / Hm[2, 2]


def draw_quad(buf, sprite, corners, tint, alpha_mul, light_emission, brightness=1.0):
    """Warp sprite (h,w,4 float) onto screen quad corners [tl,tr,br,bl] and blend into buf (H,W,3)."""
    xs = [c[0] for c in corners]
    ys = [c[1] for c in corners]
    x0, x1 = int(max(0, math.floor(min(xs)))), int(min(W, math.ceil(max(xs))))
    y0, y1 = int(max(0, math.floor(min(ys)))), int(min(H, math.ceil(max(ys))))
    if x1 - x0 < 1 or y1 - y0 < 1 or (x1 - x0) * (y1 - y0) > W * H * 4:
        return
    sh, sw, _ = sprite.shape
    src = [(0, 0), (sw, 0), (sw, sh), (0, sh)]
    Hm = homography([(cx - x0, cy - y0) for cx, cy in corners], src)
    coeffs = (Hm.flatten() / Hm[2, 2])[:8]
    im = Image.fromarray((np.clip(sprite, 0, 1) * 255).astype(np.uint8), "RGBA")
    warped = im.transform((x1 - x0, y1 - y0), Image.PERSPECTIVE, tuple(coeffs), Image.BILINEAR)
    s = np.asarray(warped, dtype=np.float32) / 255.0
    rgb = s[..., :3] * np.asarray(tint, dtype=np.float32)
    a = s[..., 3:4] * alpha_mul
    if light_emission > 0:
        rgb = rgb * (1 + (brightness - 1) * light_emission)
    region = buf[y0:y1, x0:x1]
    region[:] = region * (1 - a * (1 - light_emission)) + rgb * a


def render_particles(buf, cam, parts):
    order = []
    for q in parts:
        pr = cam.project(q["p"])
        if pr:
            order.append((pr[1], q, pr[0]))
    order.sort(key=lambda t: -t[0])
    for z, q, sc in order:
        pr = q["preset"]
        a = q["age"] / q["life"]
        size = max(seq_eval(pr["size"], a, q["u"]) * q["scale"], 0.01)
        tr = seq_eval(pr["transparency"], a)
        sq = seq_eval(pr["squash"], a) if pr.get("squash") else 0.0
        col = np.array(q["color"]) / 255.0 if q["color"] is not None else color_eval(pr.get("color"), a)
        fb = pr.get("flipbook")
        idx = 0
        if fb:
            n = GRID[fb["layout"]] ** 2
            if fb["mode"] == "OneShot":
                idx = min(int(a * n), n - 1)
            else:
                idx = int(q["frame0"] + q["age"] * q["fps"]) % n
        sprite = frame_of(pr["texture"], fb["layout"] if fb else None, idx)
        hgt = size * (1 + sq)
        wid = size / (1 + 0.5 * sq) if sq > 0 else size * (1 - sq)
        orient = pr.get("orientation", "FacingCamera")
        p = q["p"]
        if orient == "VelocityPerpendicular":
            n_, ua, ub = basis(q["v"] if np.linalg.norm(q["v"]) > 1e-6 else [0, 1, 0])
            corners3 = [p - ua * wid / 2 + ub * hgt / 2, p + ua * wid / 2 + ub * hgt / 2,
                        p + ua * wid / 2 - ub * hgt / 2, p - ua * wid / 2 - ub * hgt / 2]
        else:
            if orient == "VelocityParallel" and np.linalg.norm(q["v"]) > 1e-6:
                upv = q["v"] - (q["v"] @ cam.fwd) * cam.fwd
                upv = upv / (np.linalg.norm(upv) + 1e-9)
                rv = np.cross(cam.fwd, upv)
                rv = -rv / (np.linalg.norm(rv) + 1e-9)
            else:
                ang = math.radians(q["rot"])
                rv = cam.right * math.cos(ang) + cam.up * math.sin(ang)
                upv = -cam.right * math.sin(ang) + cam.up * math.cos(ang)
            corners3 = [p - rv * wid / 2 + upv * hgt / 2, p + rv * wid / 2 + upv * hgt / 2,
                        p + rv * wid / 2 - upv * hgt / 2, p - rv * wid / 2 - upv * hgt / 2]
        pts = [cam.project(c) for c in corners3]
        if any(x is None for x in pts):
            continue
        draw_quad(buf, sprite, [x[0] for x in pts], col, 1 - tr, pr.get("lightEmission", 0), pr.get("brightness", 1))


def strip(buf, cam, key, points, width, tint, alpha, le=0.0, ground=True, faces=None, tex_len=None, tint_seq=None):
    """Draw a textured ribbon through 3D points (Trail / Beam approximation); texture u runs along the strip."""
    sprite = texture(key)
    sh, sw, _ = sprite.shape
    total = sum(np.linalg.norm(points[i + 1] - points[i]) for i in range(len(points) - 1))
    acc = 0.0
    for i in range(len(points) - 1):
        a, b = points[i], points[i + 1]
        seg = np.linalg.norm(b - a)
        if seg < 1e-4:
            continue
        d = (b - a) / seg
        view = cam.eye - (a + b) / 2
        side = np.cross(d, [0, 1, 0]) if ground else np.cross(d, view / (np.linalg.norm(view) + 1e-9))
        side = side / (np.linalg.norm(side) + 1e-9)
        wa = width[0] + (width[1] - width[0]) * (acc / total) if isinstance(width, tuple) else width
        wb = width[0] + (width[1] - width[0]) * ((acc + seg) / total) if isinstance(width, tuple) else width
        if tex_len:
            u0, u1 = (acc / tex_len) % 1.0, (acc / tex_len) % 1.0 + seg / tex_len
        else:
            u0, u1 = acc / total, (acc + seg) / total
        acc += seg
        c3 = [a + side * wa / 2, b + side * wb / 2, b - side * wb / 2, a - side * wa / 2]
        pts = [cam.project(c) for c in c3]
        if any(x is None for x in pts):
            continue
        xa, xb = int(u0 * sw) % sw, int(min(u1, u0 + 1) * sw)
        sub = sprite[:, xa:max(xb, xa + 1)] if xb <= sw else np.concatenate([sprite[:, xa:], sprite[:, :xb - sw]], 1)
        # sprite x (u) runs a -> b, sprite y across the strip
        quad = [pts[0][0], pts[1][0], pts[2][0], pts[3][0]]
        col = np.asarray(tint) / 255.0
        if tint_seq:
            mid = (u0 + u1) / 2
            for (t0, c0), (t1, c1) in zip(tint_seq, tint_seq[1:]):
                if t0 <= mid <= t1:
                    f = (mid - t0) / max(t1 - t0, 1e-6)
                    col = (np.array(c0) * (1 - f) + np.array(c1) * f) / 255.0
        draw_quad(buf, sub, [quad[0], quad[1], quad[2], quad[3]], col, alpha, le)


# ----------------------------------------------------------------------------------------------------------------
# scene
# ----------------------------------------------------------------------------------------------------------------
def scene(cam, night=False):
    buf = np.zeros((H, W, 3), dtype=np.float32)
    ys = np.linspace(0, 1, H)[:, None]
    sky_top = np.array([0.04, 0.05, 0.12]) if night else np.array([0.33, 0.55, 0.85])
    sky_bot = np.array([0.15, 0.1, 0.25]) if night else np.array([0.85, 0.78, 0.7])
    hz = cam.project(cam.eye + np.array([cam.fwd[0], 0, cam.fwd[2]]) * 1000)
    horizon = int(hz[0][1]) if hz else H // 3
    for c in range(3):
        buf[..., c] = sky_top[c] + (sky_bot[c] - sky_top[c]) * np.clip(ys / max(horizon, 1) * np.ones((1, W)), 0, 1)
    ground_col = np.array([0.1, 0.1, 0.12]) if night else np.array([0.32, 0.33, 0.36])
    buf[horizon:, :] = ground_col
    img = Image.fromarray((np.clip(buf, 0, 1) * 255).astype(np.uint8))
    d = ImageDraw.Draw(img)
    # lane lines
    for z in range(-60, 60, 8):
        a = cam.project([0, 0.02, z])
        b = cam.project([0, 0.02, z + 4])
        if a and b:
            d.line([tuple(a[0]), tuple(b[0])], fill=(230, 220, 140) if not night else (120, 115, 80), width=2)
    for x in (-20, 20):
        a = cam.project([x, 0.02, -80])
        b = cam.project([x, 0.02, 40])
        if a and b:
            d.line([tuple(a[0]), tuple(b[0])], fill=(200, 200, 200), width=2)
    return np.asarray(img, dtype=np.float32) / 255.0


def car(buf, cam, center, color=(220, 50, 80), yaw=0.0):
    """A car-sized reference block (6 x 3.6 x 12 studs) drawn as a shaded box."""
    img = Image.fromarray((np.clip(buf, 0, 1) * 255).astype(np.uint8))
    d = ImageDraw.Draw(img)
    cx, cy, cz = center
    hw, hh, hl = 3.0, 1.8, 6.0
    cy0 = 0.6
    c, s = math.cos(yaw), math.sin(yaw)

    def P(x, y, z):
        return np.array([cx + x * c - z * s, y, cz + x * s + z * c])

    faces = [
        ([P(-hw, cy0, -hl), P(hw, cy0, -hl), P(hw, cy0 + 2 * hh, -hl), P(-hw, cy0 + 2 * hh, -hl)], 0.75),
        ([P(-hw, cy0, hl), P(hw, cy0, hl), P(hw, cy0 + 2 * hh, hl), P(-hw, cy0 + 2 * hh, hl)], 0.8),
        ([P(-hw, cy0, -hl), P(-hw, cy0, hl), P(-hw, cy0 + 2 * hh, hl), P(-hw, cy0 + 2 * hh, -hl)], 0.6),
        ([P(hw, cy0, -hl), P(hw, cy0, hl), P(hw, cy0 + 2 * hh, hl), P(hw, cy0 + 2 * hh, -hl)], 0.6),
        ([P(-hw, cy0 + 2 * hh, -hl), P(hw, cy0 + 2 * hh, -hl), P(hw, cy0 + 2 * hh, hl), P(-hw, cy0 + 2 * hh, hl)], 1.0),
    ]
    faces.sort(key=lambda f: -np.linalg.norm(np.mean(f[0], 0) - cam.eye))
    for pts3, shade in faces:
        pts = [cam.project(p) for p in pts3]
        if any(x is None for x in pts):
            continue
        d.polygon([tuple(x[0]) for x in pts], fill=tuple(int(v * shade) for v in color))
    for wx in (-hw, hw):
        for wz in (-hl + 2, hl - 2):
            p = cam.project(P(wx, 1.0, wz))
            if p:
                r = cam.f * 1.0 / p[1]
                d.ellipse([p[0][0] - r * 0.5, p[0][1] - r, p[0][0] + r * 0.5, p[0][1] + r], fill=(20, 20, 24))
    return np.asarray(img, dtype=np.float32) / 255.0


def to_img(buf, label):
    img = Image.fromarray((np.clip(buf, 0, 1) * 255).astype(np.uint8))
    d = ImageDraw.Draw(img)
    try:
        f = ImageFont.truetype("/usr/share/fonts/opentype/inter/Inter-Bold.otf", 17)
    except Exception:
        f = ImageFont.load_default()
    d.rectangle([0, 0, W, 26], fill=(0, 0, 0))
    d.text((8, 4), label, font=f, fill=(255, 255, 255))
    return img


def run_burst_scene(P, cam, bursts, t, night=False, cars=()):
    parts = []
    for name, pos, direction, n_override, ov in bursts:
        pr = P[name]
        n = n_override or pr.get("count", 1)
        parts += spawn(pr, pos, direction, n, ov)
    tt = 0.0
    while tt < t:
        parts = step(parts, DT)
        tt += DT
    buf = scene(cam, night)
    for cc in cars:
        buf = car(buf, cam, *cc)
    render_particles(buf, cam, parts)
    return buf


def stream_scene(P, cam, emitters, duration, path=None, night=False, cars_fn=None, extra=None):
    """emitters: list of (presetName, offset_fn(t) -> (pos, dir), rateScale, overrides)."""
    parts = []
    acc = {i: 0.0 for i in range(len(emitters))}
    tt = 0.0
    while tt < duration:
        for i, (name, fn, rs, ov) in enumerate(emitters):
            pr = P[name]
            acc[i] += pr["rate"] * rs * DT
            while acc[i] >= 1:
                acc[i] -= 1
                pos, d = fn(tt)
                parts += spawn(pr, pos, d, 1, ov)
        parts = step(parts, DT)
        tt += DT
    buf = scene(cam, night)
    if cars_fn:
        buf = cars_fn(buf)
    if extra:
        extra(buf)
    render_particles(buf, cam, parts)
    return buf


def main(presets_json, outdir):
    data = json.load(open(presets_json))
    P = data["presets"]
    os.makedirs(outdir, exist_ok=True)
    panels = []
    up = [0, 1, 0]

    # 1. car wreck at three moments
    cam = Cam([0, 10, 34], [0, 4, 0])
    for t in (0.12, 0.45, 1.3):
        bursts = [
            ("Fireball", [0, 2.1, 0], up, None, None),
            ("WreckSmoke", [0, 2.1, 0], up, None, None),
            ("Debris", [0, 1.6, 0], up, None, {"color": [210, 50, 80]}),
            ("Sparks", [0, 1.6, 0], up, 34, None),
            ("Shockwave", [0, 0.3, 0], up, None, {"scale": 1.1}),
            ("Flash", [0, 2.1, 0], up, None, {"scale": 1.5}),
            ("ImpactStar", [0, 3.1, 0], up, None, {"scale": 1.2}),
        ]
        buf = run_burst_scene(P, cam, bursts, t, cars=[((0, 0, 0), (210, 50, 80))])
        panels.append(to_img(buf, f"CarWreck  t={t:.2f}s"))

    # 2. drift: smoke from rear wheels along an arc + skid marks, car at the end
    cam2 = Cam([16, 11, 30], [0, 2, -4])
    R = 26.0

    def arc(t, side):
        ang = -0.9 + t * 0.55
        cx, cz = math.sin(ang) * R - 6, -math.cos(ang) * R + R - 22
        tangent = np.array([math.cos(ang), 0, math.sin(ang)])
        right = np.cross(tangent, up)
        return np.array([cx, 0, cz]) + right * side * 2.6 - tangent * 4.2, -tangent

    def drift_extra(buf):
        for side in (-1, 1):
            pts = [arc(t, side)[0] + np.array([0, 0.06, 0]) for t in np.linspace(0, 2.0, 40)]
            strip(buf, cam2, "skid_mark", pts, 1.1, (22, 22, 24), 0.65, tex_len=4)

    def drift_car(buf):
        p, d = arc(2.0, 0)
        yaw = math.atan2(-d[0], -d[2]) + 0.45
        return car(buf, cam2, (p[0] - d[0] * 4.2, 0, p[2] - d[2] * 4.2), (40, 160, 255), yaw)

    em = [("TireSmoke", (lambda tt, s=s: (arc(tt, s)[0] + np.array([0, 0.6, 0]), arc(tt, s)[1])), 1.0, None)
          for s in (-1, 1)]
    buf = stream_scene(P, cam2, em, 2.0, cars_fn=drift_car, extra=drift_extra)
    panels.append(to_img(buf, "Drift: TireSmoke streams + SkidMark trails"))

    # 3. nitro from behind (chase cam): flame + core streams + jet beam + backfire
    cam3 = Cam([0, 6.5, 22], [0, 2.5, -10])

    def nitro_extra(buf):
        ex = np.array([0, 1.6, 6.3])
        strip(buf, cam3, "nitro_jet", [ex, ex + np.array([0, 0, 4.5])], (1.35, 0.4), (90, 210, 255), 1.0, le=1.0,
              ground=False)

    em3 = [("NitroFlame", lambda tt: (np.array([0, 1.6, 6.3]), np.array([0, 0, 1])), 1.0, None),
           ("NitroCore", lambda tt: (np.array([0, 1.6, 6.3]), np.array([0, 0, 1])), 1.0, None)]
    buf = stream_scene(P, cam3, em3, 0.4, night=True,
                       cars_fn=lambda b: car(b, cam3, (0, 0, 0), (60, 60, 70)), extra=nitro_extra)
    panels.append(to_img(buf, "Nitro (night, chase cam): NitroFlame + NitroCore"))
    camn = Cam([-16, 4, 2], [0, 2, 6])

    def nitro_side(buf):
        ex = np.array([0, 1.6, 6.3])
        strip(buf, camn, "nitro_jet", [ex, ex + np.array([0, 0, 2.25]), ex + np.array([0, 0, 4.5])], (2.0, 0.6),
              (255, 255, 255), 1.0, le=1.0, ground=False, tint_seq=[(0, (255, 255, 255)), (0.3, (0, 214, 255)),
                                                                      (1, (175, 80, 255))])

    buf = stream_scene(P, camn, em3, 0.4, night=True,
                       cars_fn=lambda b: car(b, camn, (0, 0, 0), (60, 60, 70)), extra=nitro_side)
    panels.append(to_img(buf, "Nitro (night, side): + NitroJet beam"))

    # 4. cash burst
    for t in (0.35, 1.0):
        bursts = [("CashFlutter", [0, 1, 0], up, None, None), ("Coins", [0, 1, 0], up, None, None),
                  ("Sparkle", [0, 2, 0], up, 16, {"color": [70, 235, 110]}),
                  ("Flash", [0, 1, 0], up, None, {"scale": 0.8, "color": [70, 235, 110]})]
        buf = run_burst_scene(P, Cam([0, 8, 30], [0, 6, 0]), bursts, t)
        panels.append(to_img(buf, f"CashBurst  t={t:.2f}s"))

    # 5. confetti (legendary)
    for t in (0.5, 1.4):
        bursts = [("Confetti", [0, 1.5, 0], up, 14, {"color": c}) for c in data["confetti"]]
        bursts += [("Sparkle", [0, 2, 0], up, None, {"color": [255, 205, 50]}),
                   ("Shockwave", [0, 0.3, 0], up, None, {"scale": 0.9, "color": [255, 205, 50]}),
                   ("Coins", [0, 1.5, 0], up, 10, None)]
        buf = run_burst_scene(P, Cam([0, 9, 32], [0, 7, 0]), bursts, t)
        panels.append(to_img(buf, f"Confetti (Legendary delivery)  t={t:.2f}s"))

    # 6. bonk + zap close-up
    camb = Cam([0, 5, 14], [0, 3, 0])
    to_cam = camb.eye - np.array([0, 3, 0])
    for t in (0.07, 0.22):
        bursts = [("ImpactStar", [0, 3, 0], to_cam, None, {"scale": 0.8}),
                  ("Sparks", [0, 3, 0], up, 14, {"color": [255, 236, 170]}),
                  ("Shockwave", [0, 3, 0], to_cam, None, {"scale": 0.28, "color": [255, 255, 255]}),
                  ("Sparkle", [0, 3, 0], up, 8, {"color": [255, 205, 50]})]
        buf = run_burst_scene(P, camb, bursts, t)
        panels.append(to_img(buf, f"Bonk  t={t:.2f}s"))

    # 7. off-road dust + water spray
    camd = Cam([14, 8, 26], [0, 2, -6])
    em7 = [("Dust", (lambda tt, s=s: (np.array([s * 2.6, 0.4, 4.0 - tt * 40 + 40]), np.array([0, 0, 1]))), 1.0,
            {"color": [226, 202, 150]}) for s in (-1, 1)]
    buf = stream_scene(P, camd, em7, 1.2, cars_fn=lambda b: car(b, camd, (0, 0, -8), (255, 190, 40)))
    panels.append(to_img(buf, "Off-road Dust (sand) behind a car doing ~40 studs/s"))

    # 8. siren glare at night
    camg = Cam([0, 5, 20], [0, 3, 0])
    buf = scene(camg, night=True)
    buf = car(buf, camg, (0, 0, 0), (30, 32, 40))
    glare = texture("glare")
    for x, colr in ((-1.2, (255, 40, 60)), (1.2, (40, 110, 255))):
        p = camg.project([x, 4.4, 2])
        s = camg.f * 7 / p[1]
        c = p[0]
        draw_quad(buf, glare, [(c[0] - s / 2, c[1] - s / 2), (c[0] + s / 2, c[1] - s / 2), (c[0] + s / 2, c[1] + s / 2),
                               (c[0] - s / 2, c[1] + s / 2)], np.array(colr) / 255.0, 1.0, 0.0)
    panels.append(to_img(buf, "SirenGlare sprites (both phases shown)"))

    cols = 3
    rows = (len(panels) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * W, rows * H), (0, 0, 0))
    for i, p in enumerate(panels):
        sheet.paste(p, ((i % cols) * W, (i // cols) * H))
    out = os.path.join(outdir, "preview_effects.png")
    sheet.save(out)
    print("wrote", os.path.relpath(out, ROOT))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "docs", "v2", "early", "vfx"))
