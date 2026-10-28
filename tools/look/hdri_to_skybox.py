#!/usr/bin/env python3
"""Convert Poly Haven *_puresky HDRIs (equirect .hdr) into Roblox Sky faces, using the ENGINE-VERIFIED face mapping
(docs/v2/research/sky_orientation.md, Studio job 0005):

  SkyboxFt -> -Z   SkyboxBk -> +Z   SkyboxLf -> +X   SkyboxRt -> -X      (none mirrored, all upright)
  SkyboxUp -> image top points to +X                                       (not mirrored)
  SkyboxDn -> image top points to -X                                       (not mirrored)

World frame = Roblox: +Y up, the default camera looks down -Z with +X on its right. The equirect's centre column is
mapped to -Z and moving right in the panorama turns right (towards +X), i.e. the panorama is not mirrored either.

Per sky: exposure (EV), filmic tonemap, desaturation, horizon whitening/haze (GTA midday is whiter near the horizon),
below-horizon fill (the puresky lower half is a mirror of the sky), and the HDRI sun disc is painted out / dimmed so
it does not double the engine sun. The measured HDRI sun direction (after mapping) is recorded so LightingService can
rotate the sky (Sky.SkyboxOrientation.Y) to put the HDRI's sun glow where the engine sun is.

Skies: day and golden only. The night, dawn and dusk skies come from tools/look/procedural_sky.py (backlog 14).

Outputs: assets/sky/<name>/{ft,bk,lf,rt,up,dn}.png (1024 px), assets/sky/skies.json (other skies' entries kept),
         docs/v2/early/look/sky_<name>_cross.png

Usage: python3 -I tools/look/hdri_to_skybox.py --hdri-dir <dir with <id>_4k.hdr> [--only day,golden] [--cache <dir>]
       (4k = 4096x2048 equirect gives 1024 px per 90-degree face; --fetch downloads missing 4k files from Poly Haven)
"""

import argparse
import math
import os
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402

import lookcommon as lc  # noqa: E402

FACE = 1024

# Face basis: centre direction, image-right direction, image-down direction (all world space).
# Horizontal faces: upright and readable when facing them => right = forward x up, down = -Y.
# Up: image top -> +X  => down = -X; viewed from inside looking up (screen up = +Z, right = +X) the image is the view
#     rotated 90 deg clockwise, so image right -> -Z.
# Dn: image top -> -X  => down = +X; looking down while facing -Z (screen up = -Z, right = +X) the image is the view
#     rotated 90 deg counter-clockwise, so image right -> -Z.
FACES = {
    "ft": dict(prop="SkyboxFt", c=(0, 0, -1), r=(1, 0, 0), d=(0, -1, 0)),
    "bk": dict(prop="SkyboxBk", c=(0, 0, 1), r=(-1, 0, 0), d=(0, -1, 0)),
    "lf": dict(prop="SkyboxLf", c=(1, 0, 0), r=(0, 0, 1), d=(0, -1, 0)),
    "rt": dict(prop="SkyboxRt", c=(-1, 0, 0), r=(0, 0, -1), d=(0, -1, 0)),
    "up": dict(prop="SkyboxUp", c=(0, 1, 0), r=(0, 0, -1), d=(-1, 0, 0)),
    "dn": dict(prop="SkyboxDn", c=(0, -1, 0), r=(0, 0, -1), d=(1, 0, 0)),
}

# Per-sky grading. ev: exposure offset from auto (upper-hemisphere median -> 0.18). sat: saturation multiplier.
# horizon: amount/width(deg) of the whitening blend towards the haze colour; haze_white: how white that colour is;
# lift: blend of the whole dome towards the haze colour (milky midday blue).
# sun: paint out the HDRI sun (core/edge radius in degrees, glow). below: fill darkening below the horizon.
# Behaviour (written to skies.json -> the generated Look.Skies):
#   follow_sun   LightingService keeps the sky's glow azimuth on the engine sun while this sky is up (rate-limited by
#                Look.SkyStyle.maxYawRate); otherwise the horizon glow is parked on Look.SkyStyle.fixedGlowAzimuth
#   star_count   Sky.StarCount (0 under cloud / city light pollution)
#   celestial    Sky.CelestialBodiesShown (engine sun + moon discs; off where the HDRI already has a moonlit deck)
#   clouds       multiplier on the preset's volumetric Clouds.Cover while this sky is up: 0 when the HDRI already
#                carries painted clouds (two differently lit cloud layers, one turning with the sky, read wrong)
SKIES = {
    "day": dict(hdri="kloofendal_48d_partly_cloudy_puresky", ev=0.15, sat=0.65, horizon=0.55, horizon_w=18.0,
                lift=0.18, haze_white=0.55, tint=(1.0, 1.0, 1.0), sun=dict(core=1.6, edge=7.0, glow=0.35),
                below=0.30, contrast=1.0, star_count=0, follow_sun=True, celestial=True, clouds=0.0,
                use="07:15-16:45 (engine sun above ~18 deg): whiter, hazier horizon; GTA V cumulus"),
    "golden": dict(hdri="kloppenheim_06_puresky", ev=0.0, sat=0.82, horizon=0.25, horizon_w=8.0, haze_white=0.25,
                   tint=(1.0, 0.985, 0.95), sun=dict(core=1.4, edge=6.0, glow=0.5), below=0.35, contrast=1.0,
                   star_count=0, follow_sun=True, celestial=True, clouds=0.0,
                   use="05:57-07:15 and 16:45-18:06 golden hours, sun 0-18 deg (glow follows the engine sun)"),
    # "blue" (qwantani_dusk_2_puresky) and "night" (kloppenheim_07_puresky) used to be built here. They rendered
    # reddish-brown / maroon at the held night clock (jobs 0009 / 0011, backlog 14): the engine's sky cast at a -3 deg sun
    # is R/G ~2.8. The night, dawn and dusk skies now come from tools/look/procedural_sky.py, pre-compensated for it.
}

# ---------------------------------------------------------------------------------------------------------------
# HDR IO
# ---------------------------------------------------------------------------------------------------------------


def read_hdr(path):
    """Radiance RGBE (.hdr) reader, new-style RLE and flat scanlines. Returns float32 linear RGB (H, W, 3)."""
    data = open(path, "rb").read()
    i = 0
    W = H = None
    while True:
        j = data.index(b"\n", i)
        line = data[i:j]
        i = j + 1
        if line.startswith(b"-Y") or line.startswith(b"+Y"):
            p = line.split()
            H, W = int(p[1]), int(p[3])
            flip = line.startswith(b"+Y")
            break
    buf = np.frombuffer(data, np.uint8)
    img = np.zeros((H, W, 4), np.uint8)
    pos = i
    for y in range(H):
        if buf[pos] == 2 and buf[pos + 1] == 2 and (int(buf[pos + 2]) << 8 | int(buf[pos + 3])) == W:
            pos += 4
            for c in range(4):
                row = img[y, :, c]
                x = 0
                while x < W:
                    n = int(buf[pos])
                    pos += 1
                    if n > 128:
                        n -= 128
                        row[x:x + n] = buf[pos]
                        pos += 1
                    else:
                        row[x:x + n] = buf[pos:pos + n]
                        pos += n
                    x += n
        else:
            img[y] = buf[pos:pos + 4 * W].reshape(W, 4)
            pos += 4 * W
    e = img[..., 3].astype(np.int32)
    f = np.where(e > 0, np.ldexp(1.0, e - 136), 0.0).astype(np.float32)
    out = img[..., :3].astype(np.float32) * f[..., None]
    return out[::-1] if flip else out


def load_hdri(hdri_dir, ident, cache):
    if cache:
        cp = os.path.join(cache, ident + ".npy")
        if os.path.exists(cp):
            return np.nan_to_num(np.load(cp).astype(np.float32), posinf=65000.0)
    path = os.path.join(hdri_dir, ident + "_4k.hdr")
    if not os.path.exists(path):
        if not ARGS.fetch:
            raise SystemExit("missing %s (use --fetch)" % path)
        url = "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/%s_4k.hdr" % ident
        print("fetch", url)
        os.makedirs(hdri_dir, exist_ok=True)
        with open(path, "wb") as f:
            f.write(urllib.request.urlopen(url, timeout=300).read())
    a = read_hdr(path)
    if cache:
        os.makedirs(cache, exist_ok=True)
        # float16 tops out at 65504; the sun peak is clipped, which is harmless (it gets painted out anyway)
        np.save(os.path.join(cache, ident + ".npy"), np.minimum(a, 65000.0).astype(np.float16))
    return a


# ---------------------------------------------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------------------------------------------


def dir_to_equirect(d, w, h):
    """World direction -> equirect pixel coords (centre column = -Z, moving right = towards +X)."""
    x, y, z = d[..., 0], d[..., 1], d[..., 2]
    az = np.arctan2(x, -z)
    el = np.arcsin(np.clip(y, -1, 1))
    u = (0.5 + az / (2 * np.pi)) * w - 0.5
    v = (0.5 - el / np.pi) * h - 0.5
    return u, v


def equirect_to_dir(u, v, w, h):
    az = ((u + 0.5) / w - 0.5) * 2 * np.pi
    el = (0.5 - (v + 0.5) / h) * np.pi
    return np.stack([np.cos(el) * np.sin(az), np.sin(el), -np.cos(el) * np.cos(az)], axis=-1)


def sample_bilinear(img, u, v):
    h, w = img.shape[:2]
    u0 = np.floor(u).astype(np.int64)
    v0 = np.floor(v).astype(np.int64)
    fu = (u - u0)[..., None].astype(np.float32)
    fv = (v - v0)[..., None].astype(np.float32)
    u0w, u1w = u0 % w, (u0 + 1) % w
    v0c, v1c = np.clip(v0, 0, h - 1), np.clip(v0 + 1, 0, h - 1)
    a = img[v0c, u0w] * (1 - fu) + img[v0c, u1w] * fu
    b = img[v1c, u0w] * (1 - fu) + img[v1c, u1w] * fu
    return a * (1 - fv) + b * fv


def face_dirs(name, n, ss=1):
    f = FACES[name]
    m = n * ss
    t = (np.arange(m, dtype=np.float32) + 0.5) / m * 2 - 1
    uu, vv = np.meshgrid(t, t)
    c, r, d = (np.array(f[k], np.float32) for k in ("c", "r", "d"))
    dirs = c + uu[..., None] * r + vv[..., None] * d
    return dirs / np.linalg.norm(dirs, axis=-1, keepdims=True)


def azimuth_deg(d):
    """Azimuth in degrees: 0 = -Z, 90 = +X, 180 = +Z, -90 = -X (clockwise seen from above)."""
    return math.degrees(math.atan2(float(d[0]), float(-d[2])))


# ---------------------------------------------------------------------------------------------------------------
# Grading (operates on directions + linear HDR values so it is identical for every face)
# ---------------------------------------------------------------------------------------------------------------


def aces(x):
    a, b, c, d, e = 2.51, 0.03, 2.43, 0.59, 0.14
    return np.clip((x * (a * x + b)) / (x * (c * x + d) + e), 0, 1)


class Grader:
    def __init__(self, hdr, p):
        self.hdr = hdr
        self.p = p
        h, w = hdr.shape[:2]
        lum = (hdr * lc.LUMA).sum(-1)
        upper = lum[: h // 2]
        med = float(np.median(upper))
        self.exposure = 0.18 / max(med, 1e-6) * (2.0 ** p["ev"])
        # sun: brightest point of a slightly blurred luminance (upper hemisphere)
        small = lc.resize(lum, w // 8, h // 8)
        sv, su = np.unravel_index(np.argmax(small[: small.shape[0] // 2]), small[: small.shape[0] // 2].shape)
        self.sun = equirect_to_dir(np.array(su * 8 + 3.5), np.array(sv * 8 + 3.5), w, h)
        self.sun = self.sun / np.linalg.norm(self.sun)
        self.sun_peak = float(small.max())
        # haze colour = band just above the horizon (0..4 deg), averaged in linear, then whitened
        v_hi = int((0.5 - math.radians(4) / math.pi) * h)
        band = hdr[v_hi: h // 2].reshape(-1, 3)
        band_l = (band * lc.LUMA).sum(-1)
        keep = band_l < np.percentile(band_l, 97)  # ignore the sun
        hc = band[keep].mean(0) * self.exposure
        hl = float((hc * lc.LUMA).sum())
        hc = lc.saturate(hc, p["sat"]) * np.array(p["tint"], np.float32)  # same grade as the sky itself
        self.haze = hc * (1 - p["haze_white"]) + hl * p["haze_white"]
        # horizon glow: azimuth of the brightest column of the 0..6 deg band (smoothed over ~20 deg of azimuth); for
        # a night sky that is the warm city glow, which LightingService parks on Look.SkyStyle.fixedGlowAzimuth
        v6 = int((0.5 - math.radians(6) / math.pi) * h)
        col_l = lum[v6: h // 2].mean(axis=0)
        k = max(1, w // 18)
        sm = np.convolve(np.concatenate([col_l[-k:], col_l, col_l[:k]]), np.ones(k) / k, mode="same")[k:-k]
        u = int(np.argmax(sm))
        self.horizon_glow = equirect_to_dir(np.array(float(u)), np.array(float(h // 2 - 1)), w, h)
        # sun fill: median of an annulus around the sun
        if p.get("sun"):
            dirs = equirect_to_dir(*np.meshgrid(np.arange(w, dtype=np.float32), np.arange(h, dtype=np.float32)), w, h)
            ang = np.degrees(np.arccos(np.clip((dirs * self.sun).sum(-1), -1, 1)))
            e = p["sun"]["edge"]
            ring = (ang > e) & (ang < e * 1.8)
            self.fill = np.median(hdr[ring], axis=0) if ring.any() else hc / self.exposure
        else:
            self.fill = None

    def __call__(self, dirs, hdr_vals):
        p = self.p
        x = hdr_vals.copy()
        el = np.degrees(np.arcsin(np.clip(dirs[..., 1], -1, 1)))
        # 1) paint out / dim the sun disc (HDR space)
        if self.fill is not None:
            s = p["sun"]
            ang = np.degrees(np.arccos(np.clip((dirs * self.sun).sum(-1), -1, 1)))
            glow = 1.0 + s["glow"] * np.exp(-ang / (s["edge"] * 0.6))
            cap = self.fill[None, None, :] * glow[..., None]
            w = np.clip((ang - s["core"]) / max(s["edge"] - s["core"], 1e-3), 0, 1)
            w = (w * w * (3 - 2 * w))[..., None]
            x = np.minimum(x, cap) * (1 - w) + x * w
        # 2) exposure + saturation in linear
        x = x * self.exposure
        x = lc.saturate(x, p["sat"])
        x = x * np.array(p["tint"], np.float32)
        # 3) horizon whitening (towards the haze colour), above the horizon
        hw = p["horizon"] * np.exp(-np.clip(el, 0, None) / p["horizon_w"])
        x = x * (1 - hw[..., None]) + self.haze * hw[..., None]
        # 3b) lift: blend the whole dome a little towards the haze colour (GTA's milky midday blue; keeps the
        #     anti-sun side from going deep navy behind front-lit buildings)
        if p.get("lift"):
            x = x * (1 - p["lift"]) + self.haze * p["lift"]
        # 4) below the horizon: haze colour fading darker (hidden by ground/sea; matters for aerial edges only)
        below = np.clip(-el / 2.0, 0, 1)[..., None]
        dark = 1.0 - p["below"] * (1 - np.exp(np.clip(el, None, 0) / 25.0))
        fill = self.haze * dark[..., None]
        x = x * (1 - below) + fill * below
        # 5) tonemap -> sRGB
        g = np.power(aces(x), 1 / 2.2)  # ACES fit output -> display gamma
        if p["contrast"] != 1.0:  # contrast in display space around the mean, never crushing to black
            m = float(g.mean())
            g = np.clip(m + (g - m) * p["contrast"], 0, 1)
        return g


def render_face(hdr, grade, name, ss=2):
    h, w = hdr.shape[:2]
    dirs = face_dirs(name, FACE, ss)
    u, v = dir_to_equirect(dirs, w, h)
    vals = sample_bilinear(hdr, u, v)
    out = grade(dirs, vals)
    if ss > 1:
        out = out.reshape(FACE, ss, FACE, ss, 3).mean(axis=(1, 3))
    return out.astype(np.float32)


def render_equirect_preview(hdr, grade, w=1024):
    h = w // 2
    uu, vv = np.meshgrid(np.arange(w, dtype=np.float32), np.arange(h, dtype=np.float32))
    dirs = equirect_to_dir(uu, vv, w, h)
    H, W = hdr.shape[:2]
    u, v = dir_to_equirect(dirs, W, H)
    return grade(dirs, sample_bilinear(hdr, u, v))


# ---------------------------------------------------------------------------------------------------------------
# Contact sheet: cross layout aligned so edges meet (display rotations only) + the faces exactly as uploaded
# ---------------------------------------------------------------------------------------------------------------


def cross_sheet(name, faces, eq, meta, path):
    S = 256
    pad = 30
    W = 4 * S
    sheet = Image.new("RGB", (W + 2 * pad, pad + S // 2 + 30 + 3 * S + 70 + S // 2 + 40), (12, 12, 14))
    lc.label(sheet, (pad, 8), "sky '%s'  (%s)  sun az %s el %s" % (
        name, meta["hdri"], meta.get("sunAzimuth"), meta.get("sunElevation")), size=14, fill=(255, 210, 120))
    eqi = Image.fromarray(lc.to_u8(eq)).resize((W, S // 2), Image.LANCZOS)
    y0 = pad + 4
    sheet.paste(eqi, (pad, y0))
    lc.label(sheet, (pad + 4, y0 + 4), "equirect after grading (centre = -Z/Ft, right = +X)", size=11)
    y1 = y0 + S // 2 + 30
    # display rotations so the cross is continuous: facing Ft and looking up, the stored Up image appears rotated
    # 90 deg clockwise (its top points to +X); looking down, the stored Dn image appears rotated 90 deg counter-clockwise
    disp = {
        "ft": faces["ft"], "lf": faces["lf"], "bk": faces["bk"], "rt": faces["rt"],
        "up": np.rot90(faces["up"], -1), "dn": np.rot90(faces["dn"], 1),
    }
    pos = {"up": (0, 0), "ft": (0, 1), "lf": (1, 1), "bk": (2, 1), "rt": (3, 1), "dn": (0, 2)}
    names = {"ft": "Ft (-Z)", "lf": "Lf (+X)", "bk": "Bk (+Z)", "rt": "Rt (-X)", "up": "Up (stored rotated 90 CW)",
             "dn": "Dn (stored rotated 90 CCW)"}
    for k, (cx, cy) in pos.items():
        im = Image.fromarray(lc.to_u8(disp[k])).resize((S, S), Image.LANCZOS)
        sheet.paste(im, (pad + cx * S, y1 + cy * S))
        lc.label(sheet, (pad + cx * S + 4, y1 + cy * S + 4), names[k], size=11)
    note =("Turning right from Ft: Ft -> Lf -> Bk -> Rt (edges continuous).  Stored files below are what "
            "Look.Skies ids point to:")
    lc.label(sheet, (pad + S + 8, y1 + S // 2 - 10), "cross: faces as seen from inside", size=12)
    y2 = y1 + 3 * S + 10
    lc.label(sheet, (pad, y2), note, size=11, fill=(200, 200, 200))
    y3 = y2 + 26
    for i, k in enumerate(("ft", "bk", "lf", "rt", "up", "dn")):
        im = Image.fromarray(lc.to_u8(faces[k])).resize((W // 6 - 6, W // 6 - 6), Image.LANCZOS)
        sheet.paste(im, (pad + i * (W // 6), y3))
        lc.label(sheet, (pad + i * (W // 6) + 3, y3 + 3), FACES[k]["prop"], size=10)
    sheet = sheet.crop((0, 0, sheet.width, y3 + W // 6 + 10))
    sheet.save(path)


# ---------------------------------------------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hdri-dir", default=os.environ.get("HC_HDRI_DIR", os.path.expanduser("~/.cache/hotwire/hdri")))
    ap.add_argument("--cache", default="")
    ap.add_argument("--only", default="")
    ap.add_argument("--fetch", action="store_true")
    ap.add_argument("--ss", type=int, default=2, help="supersampling per axis")
    global ARGS
    ARGS = ap.parse_args()
    only = set(filter(None, ARGS.only.split(",")))
    meta_path = os.path.join(lc.SKY_DIR, "skies.json")
    meta_all = lc.read_json(meta_path, {}) or {}
    skies = meta_all.get("skies", {})
    for name, p in SKIES.items():
        if only and name not in only:
            continue
        hdr = load_hdri(ARGS.hdri_dir, p["hdri"], ARGS.cache)
        g = Grader(hdr, p)
        faces = {}
        files = {}
        for k in FACES:
            faces[k] = render_face(hdr, g, k, ARGS.ss)
            files[k] = lc.rel(lc.save_png(faces[k], os.path.join(lc.SKY_DIR, name, k + ".png")))
        sun = g.sun
        meta = dict(hdri=p["hdri"], source="Poly Haven (CC0) %s 4k" % p["hdri"], use=p["use"], files=files,
                    starCount=p["star_count"], followSun=p["follow_sun"], celestialBodiesShown=p["celestial"],
                    clouds=p["clouds"], glowAzimuth=round(azimuth_deg(sun), 1),
                    glowElevation=round(math.degrees(math.asin(float(sun[1]))), 1),
                    horizonGlowAzimuth=round(azimuth_deg(g.horizon_glow), 1),
                    grading={k: v for k, v in p.items()
                             if k not in ("hdri", "use", "follow_sun", "star_count", "celestial", "clouds")},
                    hazeColor=[int(round(c * 255)) for c in np.power(aces(g.haze), 1 / 2.2)],
                    sha1={k: lc.sha1(os.path.join(lc.ROOT, f)) for k, f in files.items()})
        if p.get("sun"):
            meta["sunAzimuth"] = round(azimuth_deg(sun), 1)
            meta["sunElevation"] = round(math.degrees(math.asin(float(sun[1]))), 1)
            meta["sunPeak"] = round(g.sun_peak, 1)
        skies[name] = meta
        eq = render_equirect_preview(hdr, g)
        cross_sheet(name, faces, eq, meta, os.path.join(lc.EARLY_DIR, "sky_%s_cross.png" % name))
        print(name, p["hdri"], "exposure %.4f" % g.exposure, "sun az/el", meta.get("sunAzimuth"),
              meta.get("sunElevation"), "haze", meta["hazeColor"])
    lc.write_json(meta_path, {"skies": skies, "faceMapping": {k: dict(v) for k, v in FACES.items()},
                              "note": "generated by tools/look/hdri_to_skybox.py - do not edit"})


ARGS = None

if __name__ == "__main__":
    main()
