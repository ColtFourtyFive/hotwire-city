"""Shared helpers for the tools/look pipeline (materials, decals, skies).

Only numpy + Pillow. Images are float32 arrays in 0..1 (sRGB-encoded unless a function says linear).
Normal maps follow Roblox's convention: tangent space, OpenGL (+Y / green = image up), (128,128,255) is flat.
"""

import hashlib
import json
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
MATERIALS_DIR = os.path.join(ROOT, "assets", "materials")
SKY_DIR = os.path.join(ROOT, "assets", "sky")
EARLY_DIR = os.path.join(ROOT, "docs", "v2", "early", "look")
STUD_M = 0.28  # 1 stud = 0.28 m (Roblox physics units)

# ---------------------------------------------------------------------------------------------------------------
# IO
# ---------------------------------------------------------------------------------------------------------------


def load_rgb(path):
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0


def load_gray(path):
    return np.asarray(Image.open(path).convert("L"), dtype=np.float32) / 255.0


def to_u8(a):
    return (np.clip(a, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)


def save_png(a, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    arr = to_u8(a)
    if arr.ndim == 2:
        Image.fromarray(arr, "L").save(path, optimize=True)
    elif arr.shape[2] == 4:
        Image.fromarray(arr, "RGBA").save(path, optimize=True)
    else:
        Image.fromarray(arr, "RGB").save(path, optimize=True)
    return path


def sha1(path):
    return hashlib.sha1(open(path, "rb").read()).hexdigest()


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")


def read_json(path, default=None):
    if not os.path.exists(path):
        return default
    with open(path) as f:
        return json.load(f)


def rel(path):
    return os.path.relpath(path, ROOT)


# ---------------------------------------------------------------------------------------------------------------
# Resampling / tiling
# ---------------------------------------------------------------------------------------------------------------


def resize(a, w, h):
    """Lanczos resize of a float image (2D or 3D)."""
    if a.shape[1] == w and a.shape[0] == h:
        return a
    if a.ndim == 2:
        im = Image.fromarray(a.astype(np.float32), "F")
        return np.asarray(im.resize((w, h), Image.LANCZOS), dtype=np.float32)
    chans = [resize(a[..., c], w, h) for c in range(a.shape[2])]
    return np.stack(chans, axis=-1)


def squarify(a):
    """Make a 2:1 (or 1:2) tileable map square by repeating it along the short axis (keeps texel density)."""
    h, w = a.shape[:2]
    if h == w:
        return a
    if w > h and w % h == 0:
        return np.concatenate([a] * (w // h), axis=0)
    if h > w and h % w == 0:
        return np.concatenate([a] * (h // w), axis=1)
    raise ValueError("cannot squarify %dx%d" % (w, h))


def seam_ratio(a):
    """Wrap-around discontinuity relative to the average neighbour difference (about 1 = seamless)."""
    g = a if a.ndim == 2 else a.mean(axis=2)
    ix = np.abs(g[:, 1:] - g[:, :-1]).mean() + 1e-6
    iy = np.abs(g[1:] - g[:-1]).mean() + 1e-6
    return float(np.abs(g[:, 0] - g[:, -1]).mean() / ix), float(np.abs(g[0] - g[-1]).mean() / iy)


def make_seamless(a, feather=0.18):
    """Offset-blend seam removal for ORGANIC maps (never use it on bricks/tiles): blends the map with a copy rolled by
    half a tile, weighted so the borders come only from the rolled copy (whose own wrap is continuous)."""
    h, w = a.shape[:2]
    b = np.roll(np.roll(a, h // 2, axis=0), w // 2, axis=1)
    y = np.minimum(np.arange(h), h - 1 - np.arange(h)) / (h * feather)
    x = np.minimum(np.arange(w), w - 1 - np.arange(w)) / (w * feather)
    m = np.clip(np.minimum(y[:, None], x[None, :]), 0, 1)
    m = m * m * (3 - 2 * m)
    if a.ndim == 3:
        m = m[..., None]
    return a * m + b * (1 - m)


# ---------------------------------------------------------------------------------------------------------------
# Colour
# ---------------------------------------------------------------------------------------------------------------

LUMA = np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)


def srgb_to_linear(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0, None)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055)


def luminance(rgb):
    return (rgb * LUMA).sum(axis=-1)


def saturate(rgb, s):
    l = luminance(rgb)[..., None]
    return l + (rgb - l) * s


def contrast_about_mean(a, k):
    m = a.mean(axis=(0, 1), keepdims=True)
    return m + (a - m) * k


def soft_clip(x, knee=0.9):
    """Identity below `knee`, smooth roll-off to 1.0 above it."""
    over = x > knee
    y = x.copy()
    span = 1.0 - knee
    y[over] = knee + span * np.tanh((x[over] - knee) / span)
    return y


# ---------------------------------------------------------------------------------------------------------------
# Normals
# ---------------------------------------------------------------------------------------------------------------


def decode_normal(rgb):
    n = rgb * 2.0 - 1.0
    n /= np.linalg.norm(n, axis=-1, keepdims=True) + 1e-6
    return n


def encode_normal(n):
    n = n / (np.linalg.norm(n, axis=-1, keepdims=True) + 1e-6)
    return n * 0.5 + 0.5


def normal_strength(rgb, k):
    n = decode_normal(rgb)
    n[..., 0] *= k
    n[..., 1] *= k
    return encode_normal(n)


def height_to_normal(h, strength):
    """OpenGL tangent-space normal from a tileable height field (rows go DOWN the image, +Y/green points UP)."""
    dx = (np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)) * 0.5
    drow = (np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)) * 0.5
    # n = (-dh/du, -dh/dv, 1) with v pointing up = -row  =>  n_y = +dh/drow
    n = np.stack([-dx * strength, drow * strength, np.ones_like(h)], axis=-1)
    return encode_normal(n)


def blend_normals(base_rgb, detail_rgb):
    """Whiteout blend of two GL normal maps."""
    a = decode_normal(base_rgb)
    b = decode_normal(detail_rgb)
    n = np.stack([a[..., 0] + b[..., 0], a[..., 1] + b[..., 1], a[..., 2] * b[..., 2]], axis=-1)
    return encode_normal(n)


# ---------------------------------------------------------------------------------------------------------------
# Tileable noise (spectral synthesis => seamless by construction)
# ---------------------------------------------------------------------------------------------------------------


def fractal_noise(size, beta=2.0, seed=0, lo=1.0, hi=None, sx=1.0, sy=1.0):
    """Periodic 1/f^beta noise in 0..1. `lo`/`hi` band-limit the frequencies (cycles per tile).
    sx/sy > 1 squash the spectrum on that axis, i.e. stretch features along it (streaks), still tileable."""
    rng = np.random.default_rng(seed)
    white = rng.standard_normal((size, size))
    f = np.fft.fftfreq(size) * size
    fx, fy = np.meshgrid(f, f)
    r = np.sqrt((fx * sx) ** 2 + (fy * sy) ** 2)
    amp = np.zeros_like(r)
    ok = r >= lo
    if hi is not None:
        ok &= r <= hi
    amp[ok] = 1.0 / np.power(r[ok], beta / 2.0)
    out = np.real(np.fft.ifft2(np.fft.fft2(white) * amp))
    out -= out.min()
    out /= out.max() + 1e-9
    return out.astype(np.float32)


def blur(a, radius_px):
    """Periodic gaussian blur via FFT (keeps maps tileable)."""
    if radius_px <= 0:
        return a
    h, w = a.shape[:2]
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.fftfreq(w)[None, :]
    g = np.exp(-2 * (np.pi * radius_px) ** 2 * (fx * fx + fy * fy))
    if a.ndim == 2:
        return np.real(np.fft.ifft2(np.fft.fft2(a) * g)).astype(np.float32)
    return np.stack([blur(a[..., c], radius_px) for c in range(a.shape[2])], axis=-1)


# ---------------------------------------------------------------------------------------------------------------
# Preview rendering (contact sheets only; an approximation of a lit PBR surface, light from the upper left)
# ---------------------------------------------------------------------------------------------------------------

LIGHT = np.array([-0.45, 0.55, 0.70], dtype=np.float32)
LIGHT /= np.linalg.norm(LIGHT)


def render_lit(albedo_srgb, normal_rgb, rough, metal, sky=(0.62, 0.70, 0.80), sun=(1.0, 0.97, 0.92)):
    """Rough PBR-ish preview: Lambert + Blinn-Phong spec + a constant sky reflection, in linear space."""
    alb = srgb_to_linear(albedo_srgb)
    n = decode_normal(normal_rgb)
    ndl = np.clip((n * LIGHT).sum(-1), 0, 1)[..., None]
    v = np.array([0, 0, 1.0], dtype=np.float32)
    hv = LIGHT + v
    hv /= np.linalg.norm(hv)
    ndh = np.clip((n * hv).sum(-1), 0, 1)
    r = np.clip(rough, 0.03, 1.0)
    shin = np.clip(2.0 / (r ** 4) - 2.0, 1.0, 4000.0)
    spec = ((shin + 2) / 8.0) * np.power(ndh, shin)
    m = metal[..., None] if metal is not None else 0.0
    f0 = 0.04 * (1 - m) + alb * m
    ndv = np.clip(n[..., 2], 0, 1)[..., None]
    fres = f0 + (1 - f0) * np.power(1 - ndv, 5)
    sky = np.array(sky, dtype=np.float32)
    sun = np.array(sun, dtype=np.float32) * 1.1
    # exposure chosen so a flat surface shows roughly its albedo (the sheet should read as "the look", not lighting)
    diffuse = alb * (1 - m) * (sun * ndl * 0.9 + sky * 0.42)
    gloss = (1.0 - r)[..., None] ** 2
    specular = fres * (sun * spec[..., None] * ndl * 0.25 + sky * (0.15 + 0.85 * gloss) * 0.6)
    return linear_to_srgb(diffuse + specular)


def font(size=14, bold=True):
    for p in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ):
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def label(im, xy, text, size=14, fill=(255, 255, 255), bg=(0, 0, 0)):
    d = ImageDraw.Draw(im)
    f = font(size)
    x, y = xy
    box = d.textbbox((x, y), text, font=f)
    d.rectangle((box[0] - 3, box[1] - 2, box[2] + 3, box[3] + 2), fill=bg)
    d.text((x, y), text, font=f, fill=fill)


def checker(w, h, cell=16, a=(0.36, 0.36, 0.38), b=(0.46, 0.46, 0.48)):
    yy, xx = np.mgrid[0:h, 0:w]
    m = ((xx // cell + yy // cell) % 2).astype(np.float32)[..., None]
    return np.array(a, np.float32) * (1 - m) + np.array(b, np.float32) * m


def over(rgba, bg):
    a = rgba[..., 3:4]
    return rgba[..., :3] * a + bg * (1 - a)
