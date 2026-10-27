#!/usr/bin/env python3
"""Poly Haven HDRI -> the six Roblox Sky faces (SkyboxBk/Dn/Ft/Lf/Rt/Up), 1024 px PNG, with exposure + tonemap.

    python3 -I tools/blender/sky/hdri_to_skybox.py --preset all            # the 3 project skies -> assets/sky/<name>/
    python3 -I tools/blender/sky/hdri_to_skybox.py --preset golden --sun-az 250
    python3 -I tools/blender/sky/hdri_to_skybox.py --hdri kloofendal_43d_clear_puresky --name test --ev -0.3 \
        --tonemap agx --sun-az 235 --keep-sun
    python3 -I tools/blender/sky/hdri_to_skybox.py --cross-only            # rebuild docs/v2/proto/sky/cross.png

Face convention (Roblox world, Y up; engine-verified in Studio job 0005, docs/v2/research/sky_orientation.md):
    SkyboxFt looks at -Z, SkyboxBk at +Z, SkyboxLf at +X, SkyboxRt at -X; all upright, none mirrored.
    SkyboxUp: image top points to +X (seen facing Ft and looking up it appears rotated 90 deg clockwise).
    SkyboxDn: image top points to -X (seen facing Ft and looking down it appears rotated 90 deg counter-clockwise).
This agrees with the community mapping (devforum "Custom Skyboxes 101": rotate Up 90 CW and Dn 90 CCW) once the
cube-map tool's mirrored px/nx naming is accounted for. cross.png proves it two ways: a test pattern with compass
letters reads N on Ft, E on Lf, S on Bk, W on Rt, with a continuous horizon; and every one of the 12 cube edges is
checked numerically (adjacent faces must sample the same directions).

Compass used everywhere here: azimuth 0 = -Z ("north", the way SkyboxFt faces), 90 = +X, 180 = +Z, 270 = -X.
Roblox draws its own sun (Sky.CelestialBodiesShown); by default the HDRI's sun disc is painted out (the glow stays)
and the sky is yawed so the glow sits where the in-game sun is. Pass that direction with --sun-dir x,y,z (the value
of Lighting:GetSunDirection() at the ClockTime you ship) or as --sun-az degrees.

Each sky folder gets the six faces, a 1024x512 LDR panorama preview and sky.json (sun direction, measured sun / sky /
horizon colours as Lighting + Atmosphere hints, and the exact settings used).
"""
import argparse
import json
import math
import os
import sys
import time
import urllib.request

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
CACHE = os.path.join(HERE, "_cache", "hdri")
OUT = os.path.join(ROOT, "assets", "sky")
PROTO = os.path.join(ROOT, "docs", "v2", "proto", "sky")
FACES = ("Ft", "Bk", "Lf", "Rt", "Up", "Dn")
LUM = np.array([0.2126, 0.7152, 0.0722], np.float32)

# The three project skies. key: target mean luminance of the upper hemisphere (scene-linear, before tonemap),
# i.e. auto-exposure; ev is applied on top. haze: horizon whitening toward haze_color (matches Atmosphere).
PRESETS = {
    "day": dict(hdri="kloofendal_48d_partly_cloudy_puresky", label="Clear GTA day (scattered cumulus)",
                key=0.42, ev=0.0, tonemap="agx", sat=1.0, sun_az=235.0, haze=0.22, haze_color=(0.80, 0.84, 0.88),
                ground="haze", clock_hint=14.5),
    "golden": dict(hdri="kloppenheim_06_puresky", label="Golden hour with clouds",
                   key=0.30, ev=0.0, tonemap="agx", sat=1.08, sun_az=255.0, haze=0.18, haze_color=(0.98, 0.80, 0.60),
                   ground="haze", clock_hint=17.6),
    "night": dict(hdri="qwantani_dusk_2_puresky", label="Blue-hour / night city",
                  key=0.075, ev=0.0, tonemap="agx", sat=1.0, sun_az=285.0, haze=0.0, haze_color=(0.30, 0.33, 0.42),
                  ground="haze", glow=0.55, glow_color=(1.0, 0.56, 0.26), glow_width=9.0, clock_hint=19.4),
}


# ----------------------------------------------------------------------------------------------------- loading
def fetch_hdri(hid, res="2k"):
    if os.path.exists(hid):
        return hid
    dst = os.path.join(CACHE, f"{hid}_{res}.hdr")
    if not os.path.exists(dst):
        os.makedirs(CACHE, exist_ok=True)
        ua = {"User-Agent": "HotwireCity-sky/1.0"}
        api = json.load(urllib.request.urlopen(urllib.request.Request(f"https://api.polyhaven.com/files/{hid}", headers=ua)))
        url = api["hdri"][res]["hdr"]["url"]
        with urllib.request.urlopen(urllib.request.Request(url, headers=ua), timeout=300) as r, open(dst + ".part", "wb") as f:
            f.write(r.read())
        os.replace(dst + ".part", dst)
    return dst


def load_hdr(path):
    """Equirect float32 HxWx3 (row 0 = zenith side) via Blender's image loader."""
    import bpy
    im = bpy.data.images.load(path, check_existing=True)
    W, H = im.size
    a = np.empty(W * H * 4, np.float32)
    im.pixels.foreach_get(a)
    bpy.data.images.remove(im)
    return np.ascontiguousarray(a.reshape(H, W, 4)[::-1, :, :3])


# ------------------------------------------------------------------------------------------------ directions
def face_dirs(face, n, ss=1):
    """Unit directions (Roblox world) for every pixel of a face, n x n (x ss supersamples). Rows go down, cols right."""
    m = n * ss
    t = (np.arange(m, dtype=np.float32) + 0.5) / m * 2 - 1  # -1..1
    u, v = np.meshgrid(t, t)  # u: right, v: down
    one = np.ones_like(u)
    if face == "Ft":    # -Z, right = +X
        d = (u, -v, -one)
    elif face == "Bk":  # +Z, right = -X
        d = (-u, -v, one)
    elif face == "Lf":  # +X, right = +Z
        d = (one, -v, u)
    elif face == "Rt":  # -X, right = -Z
        d = (-one, -v, -u)
    elif face == "Up":  # image top -> +X, image right -> -Z
        d = (-v, one, -u)
    elif face == "Dn":  # image top -> -X, image right -> -Z
        d = (v, -one, -u)
    else:
        raise ValueError(face)
    d = np.stack(d, axis=-1)
    return d / np.linalg.norm(d, axis=-1, keepdims=True)


def dir_to_equirect(d, yaw_deg, W, H):
    """Roblox direction -> continuous pixel coords in an equirect whose centre column looks at compass `-yaw`.
    Compass az = atan2(x, -z). The panorama's own azimuth phi = az - yaw, increasing to the right."""
    az = np.degrees(np.arctan2(d[..., 0], -d[..., 2]))
    el = np.degrees(np.arcsin(np.clip(d[..., 1], -1, 1)))
    phi = (az - yaw_deg + 180.0) % 360.0 - 180.0
    x = (phi / 360.0 + 0.5) * W - 0.5
    y = (0.5 - el / 180.0) * H - 0.5
    return x, y


def bilinear(img, x, y):
    H, W = img.shape[:2]
    x0 = np.floor(x).astype(np.int64)
    y0 = np.floor(y).astype(np.int64)
    fx = (x - x0)[..., None]
    fy = (y - y0)[..., None]
    x0w, x1w = x0 % W, (x0 + 1) % W
    y0c, y1c = np.clip(y0, 0, H - 1), np.clip(y0 + 1, 0, H - 1)
    a = img[y0c, x0w] * (1 - fx) + img[y0c, x1w] * fx
    b = img[y1c, x0w] * (1 - fx) + img[y1c, x1w] * fx
    return a * (1 - fy) + b * fy


def equirect_dirs(W, H):
    """Directions for every pixel of an equirect with yaw 0 (centre = -Z)."""
    phi = np.radians((np.arange(W, dtype=np.float32) + 0.5) / W * 360.0 - 180.0)
    el = np.radians(90.0 - (np.arange(H, dtype=np.float32) + 0.5) / H * 180.0)
    P, E = np.meshgrid(phi, el)
    return np.stack([np.cos(E) * np.sin(P), np.sin(E), -np.cos(E) * np.cos(P)], axis=-1)


# --------------------------------------------------------------------------------------------- sky processing
def find_and_remove_sun(img, keep=False):
    """Locate the sun (very bright compact blob), measure it, paint the disc out with the ring median.
    Returns (img, info) with info: phi/el of the sun in panorama coords, irradiance, colour."""
    H, W = img.shape[:2]
    L = img @ LUM
    med = float(np.median(L[: H // 2]))
    thr = max(20.0, med * 60.0)
    m = L > thr
    info = {"found": bool(m.any())}
    if not m.any():
        return img, info
    ys, xs = np.nonzero(m)
    lat = (0.5 - (ys + 0.5) / H) * math.pi
    dOm = (2 * math.pi / W) * (math.pi / H) * np.cos(lat)
    w = L[m] * dOm
    cx = float((xs * w).sum() / w.sum())
    cy = float((ys * w).sum() / w.sum())
    y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
    pad = max(4, int((y1 - y0) * 2))
    ring = img[max(0, y0 - pad):y1 + pad + 1, max(0, x0 - pad):x1 + pad + 1].reshape(-1, 3)
    rl = ring @ LUM
    fill = np.median(ring[rl < thr], axis=0) if (rl < thr).any() else np.full(3, thr, np.float32)
    E_rgb = ((img[m] - fill[None, :]) * dOm[:, None]).sum(0)
    info.update(phi=((cx + 0.5) / W - 0.5) * 360.0, el=(0.5 - (cy + 0.5) / H) * 180.0,
                irradiance=float(E_rgb @ LUM), color=(E_rgb / max(1e-6, E_rgb.max())).tolist(),
                pixels=int(m.sum()))
    if not keep:
        img = img.copy()
        # feather: dilate the mask a little and blend to the fill so no hard ring remains
        mm = m.copy()
        for _ in range(2):
            mm = mm | np.roll(mm, 1, 0) | np.roll(mm, -1, 0) | np.roll(mm, 1, 1) | np.roll(mm, -1, 1)
        img[mm] = np.minimum(img[mm], fill[None, :] * 1.5)
        img[m] = fill
    return img, info


def tonemap(x, mode):
    x = np.maximum(x, 0)
    if mode == "agx":
        # AgX base (Sobotka), polynomial contrast fit (Wrensch). Output is display-encoded (~sRGB).
        M = np.array([[0.842479062253094, 0.0423282422610123, 0.0423756549057051],
                      [0.0784335999999992, 0.878468636469772, 0.0784336],
                      [0.0792237451477643, 0.0791661274605434, 0.879142973793104]], np.float32)
        lo, hi = -12.47393, 4.026069
        v = x @ M
        v = np.clip(np.log2(np.maximum(v, 1e-10)), lo, hi)
        v = (v - lo) / (hi - lo)
        v2 = v * v
        v4 = v2 * v2
        v = 15.5 * v4 * v2 - 40.14 * v4 * v + 31.96 * v4 - 6.868 * v2 * v + 0.4298 * v2 + 0.1191 * v - 0.00232
        Minv = np.linalg.inv(M).astype(np.float32)
        v = np.clip(v, 0, 1) ** 2.2 @ Minv  # back to linear display, then re-encode below
        return np.clip(srgb_encode(np.clip(v, 0, 1)), 0, 1)
    if mode == "aces":  # Narkowicz fit, linear display out
        v = (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14)
        return srgb_encode(np.clip(v, 0, 1))
    if mode == "reinhard":
        return srgb_encode(x / (1 + x))
    if mode == "clip":
        return srgb_encode(np.clip(x, 0, 1))
    raise ValueError(mode)


def srgb_encode(v):
    return np.where(v <= 0.0031308, v * 12.92, 1.055 * np.power(np.maximum(v, 0), 1 / 2.4) - 0.055)


def process(hdr, cfg, log):
    """Scene-linear equirect -> graded scene-linear equirect + metadata (sun found, colours)."""
    img, sun = find_and_remove_sun(hdr, keep=cfg.get("keep_sun", False))
    H, W = img.shape[:2]
    el = (0.5 - (np.arange(H) + 0.5) / H) * 180.0
    elc = el[:, None, None]
    upper = el > 0
    wts = np.cos(np.radians(el))[upper]
    Lup = (img[upper] @ LUM).mean(axis=1)
    mean_up = float((Lup * wts).sum() / wts.sum())
    gain = cfg["key"] / max(mean_up, 1e-6) * 2.0 ** cfg.get("ev", 0.0)
    img = img * gain
    log(f"  sun found={sun.get('found')} phi={sun.get('phi', 0):.1f} el={sun.get('el', 0):.1f} "
        f"E={sun.get('irradiance', 0):.1f}; sky mean {mean_up:.3f} -> gain {gain:.3f}")
    # horizon colour before haze (for Atmosphere hints)
    band = (el > 0.5) & (el < 6)
    horizon = img[band].reshape(-1, 3).mean(0)
    # optional warm light-pollution band (city at night)
    if cfg.get("glow", 0) > 0:
        gw = cfg.get("glow_width", 9.0)
        prof = np.exp(-np.maximum(elc, 0) / gw) * (elc > -2)
        az = np.linspace(-180, 180, W, endpoint=False)[None, :, None]
        # brighter toward downtown (compass glow_az), never zero
        ga = cfg.get("glow_az", 30.0) - cfg["_yaw"]
        bias = 0.55 + 0.45 * np.cos(np.radians(az - ga)) ** 2
        g = np.array(cfg["glow_color"], np.float32) * cfg["glow"] * cfg["key"] * 3.0
        img = img + prof * bias * g[None, None, :]
    # horizon haze: whiten toward the Atmosphere colour near the horizon
    if cfg.get("haze", 0) > 0:
        hc = np.array(cfg["haze_color"], np.float32)
        lvl = float((horizon @ LUM))
        f = cfg["haze"] * np.exp(-np.maximum(elc, 0) / 7.0)
        img = img * (1 - f) + (hc / max(hc @ LUM, 1e-6) * lvl * 1.05)[None, None, :] * f
    # below the horizon: no HDRI ground (it reads as a grey floor past the map edge). Continue the horizon colour
    # and darken slowly, like a hazy sea surface.
    if cfg.get("ground", "haze") == "haze":
        hrow = img[(el > 0.2) & (el < 2.5)].reshape(-1, W, 3).mean(0)  # per-column horizon colour
        t = np.clip(-elc / 30.0, 0, 1)
        below = hrow[None, :, :] * (1 - 0.55 * t)
        blend = np.clip(-elc / 1.5 + 0.0, 0, 1)
        img = np.where(elc < 0, img * (1 - blend) + below * blend, img)
    sat = cfg.get("sat", 1.0)
    if sat != 1.0:
        lum = (img @ LUM)[..., None]
        img = lum + (img - lum) * sat
    meta = {
        "sun_found": sun.get("found", False),
        "sun_el": sun.get("el"),
        "sun_color_linear": sun.get("color"),
        "sun_irradiance_rel": (sun.get("irradiance", 0) * gain) if sun.get("found") else None,
        "horizon_linear": horizon.tolist(),
        "zenith_linear": img[: max(2, H // 40)].reshape(-1, 3).mean(0).tolist(),
        "sky_mean_linear": (img[upper].reshape(-1, 3).mean(0)).tolist(),
    }
    return img.astype(np.float32), sun, meta


def to_srgb8(lin, mode):
    return (tonemap(lin, mode) * 255 + 0.5).clip(0, 255).astype(np.uint8)


def hexcol(lin, mode="agx"):
    c = to_srgb8(np.array(lin, np.float32)[None, None, :], mode)[0, 0]
    return [int(c[0]), int(c[1]), int(c[2])]


# ------------------------------------------------------------------------------------------------ cube faces
def make_faces(img, yaw, n=1024, ss=2):
    H, W = img.shape[:2]
    out = {}
    for f in FACES:
        d = face_dirs(f, n, ss)
        x, y = dir_to_equirect(d, yaw, W, H)
        s = bilinear(img, x, y)
        if ss > 1:
            s = s.reshape(n, ss, n, ss, 3).mean((1, 3))
        out[f] = s.astype(np.float32)
    return out


def edge_check(faces):
    """Numerical proof the faces fit: for each face pixel along an edge, the neighbouring face must hold the pixel
    for (nearly) the same direction. Sample both faces at the edge directions and compare. Returns max mean abs
    error over the 12 edges in 0..255 units."""
    n = next(iter(faces.values())).shape[0]
    t = (np.arange(n) + 0.5) / n * 2 - 1
    errs = {}
    # walk every face edge, find the other face that owns the direction just across it
    for f in FACES:
        for edge in ("top", "bottom", "left", "right"):
            if edge in ("top", "bottom"):
                u, v = t, np.full(n, -1.0 if edge == "top" else 1.0)
            else:
                u, v = np.full(n, -1.0 if edge == "left" else 1.0), t
            d = face_dirs_uv(f, u, v)
            outward = 1.0 + 2.0 / n  # just past the edge
            d2 = face_dirs_uv(f, u * (outward if edge in ("left", "right") else 1), v * (outward if edge in ("top", "bottom") else 1))
            g, gu, gv = owner(d2)
            if g == f:
                continue
            a = sample_face(faces[f], u * (1 - 1.0 / n) if edge in ("left", "right") else u,
                            v * (1 - 1.0 / n) if edge in ("top", "bottom") else v)
            b = sample_face(faces[g], gu, gv)
            key = "-".join(sorted((f, g)))
            errs[key] = max(errs.get(key, 0.0), float(np.abs(a - b).mean()))
    return errs


def face_dirs_uv(face, u, v):
    one = np.ones_like(u)
    d = {"Ft": (u, -v, -one), "Bk": (-u, -v, one), "Lf": (one, -v, u), "Rt": (-one, -v, -u),
         "Up": (-v, one, -u), "Dn": (v, -one, -u)}[face]
    d = np.stack(d, axis=-1)
    return d / np.linalg.norm(d, axis=-1, keepdims=True)


def owner(d):
    """Face that owns the (first) direction, and that face's (u, v) for all directions (inverse of face_dirs_uv)."""
    x, y, z = d[0]
    ax = np.argmax(np.abs(d[0]))
    if ax == 0:
        f = "Lf" if x > 0 else "Rt"
    elif ax == 1:
        f = "Up" if y > 0 else "Dn"
    else:
        f = "Bk" if z > 0 else "Ft"
    X, Y, Z = d[:, 0], d[:, 1], d[:, 2]
    if f == "Ft":
        u, v = X / -Z, -Y / -Z
    elif f == "Bk":
        u, v = -X / Z, -Y / Z
    elif f == "Lf":
        u, v = Z / X, -Y / X
    elif f == "Rt":
        u, v = -Z / -X, -Y / -X
    elif f == "Up":
        u, v = -Z / Y, -X / Y
    else:
        u, v = -Z / -Y, X / -Y
    return f, u, v


def sample_face(face_img, u, v):
    n = face_img.shape[0]
    x = (u + 1) / 2 * n - 0.5
    y = (v + 1) / 2 * n - 0.5
    x0 = np.clip(np.floor(x).astype(int), 0, n - 1)
    y0 = np.clip(np.floor(y).astype(int), 0, n - 1)
    return face_img[y0, x0].astype(np.float32)


# ------------------------------------------------------------------------------------------------- outputs
def font(sz):
    for p in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
        if os.path.exists(p):
            return ImageFont.truetype(p, sz)
    return ImageFont.load_default()


def cross_image(face_imgs, tile=256, title=None):
    """Horizontal cross as seen from inside: row Rt | Ft | Lf | Bk, Up above Ft and Dn below it, each shown the way
    it appears on screen (Up rotated 90 CW, Dn rotated 90 CCW, per the engine-verified convention)."""
    W, H = tile * 4, tile * 3 + (28 if title else 0)
    oy = 28 if title else 0
    im = Image.new("RGB", (W, H), (16, 16, 18))
    d = ImageDraw.Draw(im)
    if title:
        d.text((8, 5), title, fill=(235, 235, 235), font=font(15))
    pos = {"Rt": (0, 1), "Ft": (1, 1), "Lf": (2, 1), "Bk": (3, 1), "Up": (1, 0), "Dn": (1, 2)}
    world = {"Ft": "-Z (N)", "Lf": "+X (E)", "Bk": "+Z (S)", "Rt": "-X (W)", "Up": "+Y", "Dn": "-Y"}
    f2 = font(12)
    for f, (cx, cy) in pos.items():
        t = Image.fromarray(face_imgs[f]).resize((tile, tile), Image.LANCZOS)
        if f == "Up":
            t = t.transpose(Image.ROTATE_270)  # 90 deg clockwise, as seen facing Ft
        elif f == "Dn":
            t = t.transpose(Image.ROTATE_90)   # 90 deg counter-clockwise
        im.paste(t, (cx * tile, oy + cy * tile))
        lab = f"Skybox{f}  {world[f]}"
        d.text((cx * tile + 5, oy + cy * tile + 4), lab, fill=(0, 0, 0), font=f2)
        d.text((cx * tile + 4, oy + cy * tile + 3), lab, fill=(255, 255, 120), font=f2)
    return im


def test_pattern(W=2048, H=1024):
    """Equirect debug pattern (yaw 0): 15-deg grid, horizon line, compass letters at the horizon, an arrow at the
    zenith pointing north (-Z) and one at the nadir, colour-coded hemispheres."""
    img = Image.new("RGB", (W, H), (0, 0, 0))
    d = ImageDraw.Draw(img)
    for r in range(H):
        el = 90 - (r + 0.5) / H * 180
        c = (int(70 + 90 * max(el, 0) / 90), int(110 + 80 * max(el, 0) / 90), 200) if el >= 0 else (90, 70, 40)
        d.line([(0, r), (W, r)], fill=c)
    for k in range(0, 360, 15):
        x = k / 360 * W
        d.line([(x, 0), (x, H)], fill=(255, 255, 255) if k % 90 == 0 else (150, 150, 150), width=3 if k % 90 == 0 else 1)
    for e in range(-75, 90, 15):
        y = (90 - e) / 180 * H
        d.line([(0, y), (W, y)], fill=(255, 60, 60) if e == 0 else (150, 150, 150), width=4 if e == 0 else 1)
    big = font(90)
    # compass az a -> phi = a (yaw 0) -> column (a/360 + 0.5) W
    for a, name in ((0, "N"), (90, "E"), (180, "S"), (270, "W")):
        x = ((a + 180) % 360) / 360 * W
        d.text((x - 30, H / 2 - 150), name, fill=(255, 255, 255), font=big)
        d.text((x - 46, H / 2 + 30), f"{a}°", fill=(255, 230, 120), font=font(40))
    return np.asarray(img).astype(np.float32) / 255.0


def write_sky(name, cfg, log=print, n=1024):
    t0 = time.time()
    src = fetch_hdri(cfg["hdri"], cfg.get("res", "2k"))
    hdr = load_hdr(src)
    log(f"[{name}] {os.path.basename(src)} {hdr.shape[1]}x{hdr.shape[0]}")
    _, sun0 = find_and_remove_sun(hdr, keep=True)
    # yaw: put the HDRI sun (or glow) at the requested compass azimuth
    target = cfg.get("sun_az")
    if cfg.get("sun_dir"):
        x, y, z = cfg["sun_dir"]
        target = math.degrees(math.atan2(x, -z))
    yaw = (target - sun0["phi"]) if (target is not None and sun0.get("found")) else cfg.get("yaw", 0.0)
    cfg["_yaw"] = yaw
    img, sun, meta = process(hdr, cfg, log)
    faces = make_faces(img, yaw, n=n, ss=2)
    dst = os.path.join(OUT, name)
    os.makedirs(dst, exist_ok=True)
    faces8 = {}
    for f, a in faces.items():
        faces8[f] = to_srgb8(a, cfg["tonemap"])
        Image.fromarray(faces8[f], "RGB").save(os.path.join(dst, f"Skybox{f}.png"), optimize=True)
    pano = np.asarray(Image.fromarray(to_srgb8(img, cfg["tonemap"])).resize((1024, 512), Image.LANCZOS))
    # re-centre the preview panorama on compass 0 (-Z) so every preview reads the same way
    shift = int(round(-yaw / 360 * 1024))
    Image.fromarray(np.roll(pano, shift, axis=1)).save(os.path.join(dst, "preview_pano.png"), optimize=True)
    errs = edge_check({f: a.astype(np.float32) for f, a in faces8.items()})
    sun_az = (sun0["phi"] + yaw) if sun0.get("found") else None
    sun_vec = None
    if sun0.get("found"):
        e, a = math.radians(sun0["el"]), math.radians(sun_az)
        sun_vec = [round(math.cos(e) * math.sin(a), 4), round(math.sin(e), 4), round(-math.cos(e) * math.cos(a), 4)]
    info = {
        "name": name, "label": cfg.get("label", name),
        "source": {"hdri": cfg["hdri"], "res": cfg.get("res", "2k"), "url": f"https://polyhaven.com/a/{cfg['hdri']}",
                   "license": "CC0 (Poly Haven)"},
        "faces": {f"Skybox{f}": f"assets/sky/{name}/Skybox{f}.png" for f in FACES},
        "convention": "SkyboxFt=-Z, Bk=+Z, Lf=+X, Rt=-X; Up top=+X; Dn top=-X (Studio job 0005)",
        "settings": {k: v for k, v in cfg.items() if not k.startswith("_")},
        "yaw_deg": round(yaw, 2),
        "sun": {"in_hdri": sun0.get("found"), "painted_out": not cfg.get("keep_sun", False),
                "compass_az": None if sun_az is None else round(sun_az % 360, 1),
                "elevation": None if not sun0.get("found") else round(sun0["el"], 1),
                "roblox_dir": sun_vec,
                "note": "match Lighting:GetSunDirection() at the shipped ClockTime; rerun with --sun-dir if it differs"},
        "hints": {
            "horizon_srgb": hexcol(meta["horizon_linear"], cfg["tonemap"]),
            "zenith_srgb": hexcol(meta["zenith_linear"], cfg["tonemap"]),
            "sky_mean_srgb": hexcol(meta["sky_mean_linear"], cfg["tonemap"]),
            "sun_color_srgb": None if not meta["sun_color_linear"] else
            [int(255 * min(1, c) ** (1 / 2.2)) for c in meta["sun_color_linear"]],
            "use": "Atmosphere.Color/Decay ~ horizon; OutdoorAmbient ~ darker sky_mean; Lighting sun tint ~ sun_color",
            "clock_time_hint": cfg.get("clock_hint"),
        },
        "edge_error_0_255": {k: round(v, 2) for k, v in sorted(errs.items())},
        "seconds": round(time.time() - t0, 1),
    }
    json.dump(info, open(os.path.join(dst, "sky.json"), "w"), indent=1)
    log(f"  wrote {dst} yaw={yaw:.1f} sun_az={info['sun']['compass_az']} max edge err {max(errs.values()):.2f} "
        f"({info['seconds']}s)")
    return faces8, info


def cross_sheet(names, path):
    tile = 200
    # 1) debug pattern through the exact same face code
    tp = test_pattern()
    faces = make_faces(tp, 0.0, n=512, ss=1)
    tp8 = {f: (np.clip(a, 0, 1) * 255).astype(np.uint8) for f, a in faces.items()}
    errs = edge_check({f: a.astype(np.float32) for f, a in tp8.items()})
    blocks = [cross_image(tp8, tile, f"Test pattern via Roblox convention - max edge error {max(errs.values()):.2f}/255")]
    for n in names:
        d = os.path.join(OUT, n)
        if not os.path.exists(os.path.join(d, "SkyboxFt.png")):
            continue
        f8 = {f: np.asarray(Image.open(os.path.join(d, f"Skybox{f}.png")).convert("RGB")) for f in FACES}
        info = json.load(open(os.path.join(d, "sky.json")))
        e = max(info["edge_error_0_255"].values())
        blocks.append(cross_image(f8, tile, f"{n}: {info['label']} - sun az {info['sun']['compass_az']} - edge err {e:.2f}"))
    cols = 2
    bw, bh = blocks[0].size
    rows = (len(blocks) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * bw + (cols + 1) * 10, rows * bh + (rows + 1) * 10 + 44), (10, 10, 12))
    dd = ImageDraw.Draw(sheet)
    dd.text((12, 10), "Roblox Sky faces, horizontal cross seen from inside: Rt(-X) | Ft(-Z) | Lf(+X) | Bk(+Z); "
                      "Up shown rotated 90 CW, Dn 90 CCW (as on screen when facing Ft)", fill=(230, 230, 230), font=font(15))
    for i, b in enumerate(blocks):
        sheet.paste(b, (10 + (i % cols) * (bw + 10), 44 + 10 + (i // cols) * (bh + 10)))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sheet.save(path, optimize=True)
    print("wrote", path, sheet.size, "test-pattern edge errors:", {k: round(v, 2) for k, v in errs.items()})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preset", help="day | golden | night | all")
    ap.add_argument("--hdri", help="Poly Haven id or path to .hdr (custom sky)")
    ap.add_argument("--name")
    ap.add_argument("--res", default=None, help="Poly Haven resolution: 1k 2k 4k (default 2k)")
    ap.add_argument("--ev", type=float)
    ap.add_argument("--key", type=float)
    ap.add_argument("--tonemap", choices=("agx", "aces", "reinhard", "clip"))
    ap.add_argument("--sat", type=float)
    ap.add_argument("--sun-az", type=float, help="compass az for the HDRI sun: 0=-Z, 90=+X, 180=+Z, 270=-X")
    ap.add_argument("--sun-dir", help="x,y,z Roblox vector (Lighting:GetSunDirection())")
    ap.add_argument("--keep-sun", action="store_true")
    ap.add_argument("--haze", type=float)
    ap.add_argument("--size", type=int, default=1024)
    ap.add_argument("--cross-only", action="store_true")
    args = ap.parse_args()
    if args.cross_only:
        cross_sheet(list(PRESETS), os.path.join(PROTO, "cross.png"))
        return
    jobs = []
    if args.preset:
        names = list(PRESETS) if args.preset == "all" else args.preset.split(",")
        for n in names:
            jobs.append((n, dict(PRESETS[n])))
    elif args.hdri:
        jobs.append((args.name or os.path.basename(args.hdri).split(".")[0],
                     dict(hdri=args.hdri, key=0.4, ev=0.0, tonemap="agx", sat=1.0, sun_az=None, haze=0.0,
                          haze_color=(0.8, 0.84, 0.88), ground="haze")))
    else:
        ap.error("--preset or --hdri")
    for name, cfg in jobs:
        for k in ("ev", "key", "tonemap", "sat", "haze", "res"):
            if getattr(args, k) is not None:
                cfg[k] = getattr(args, k)
        if args.sun_az is not None:
            cfg["sun_az"] = args.sun_az
        if args.sun_dir:
            cfg["sun_dir"] = [float(x) for x in args.sun_dir.split(",")]
        if args.keep_sun:
            cfg["keep_sun"] = True
        write_sky(name, cfg, n=args.size)
    cross_sheet(list(PRESETS), os.path.join(PROTO, "cross.png"))


if __name__ == "__main__":
    main()
