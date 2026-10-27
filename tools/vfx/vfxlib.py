#!/usr/bin/env python3
"""Shared numpy helpers for the Hotwire City VFX texture generators (tools/vfx/gen_textures.py).

Everything is float32 in [0, 1]. Fields are (H, W) arrays; images are (H, W, 4) RGBA with straight alpha.
Noise is spectral (FFT-filtered white noise), so every noise field tiles in both axes for free; that is what
makes the flame flipbook loop and the skid-mark strip wrap without seams.
"""
import math
import os

import numpy as np
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT_DIR = os.path.join(ROOT, "assets", "vfx")


# ----------------------------------------------------------------------------------------------------------------
# coordinates / shaping
# ----------------------------------------------------------------------------------------------------------------
def grid(h, w=None):
    """Centered coordinates in [-1, 1] (y down), returned as (x, y)."""
    w = w or h
    ys = (np.arange(h, dtype=np.float32) + 0.5) / h * 2 - 1
    xs = (np.arange(w, dtype=np.float32) + 0.5) / w * 2 - 1
    x, y = np.meshgrid(xs, ys)
    return x, y


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def norm01(a):
    a = a.astype(np.float32)
    lo, hi = float(a.min()), float(a.max())
    if hi - lo < 1e-9:
        return np.zeros_like(a)
    return (a - lo) / (hi - lo)


# ----------------------------------------------------------------------------------------------------------------
# noise
# ----------------------------------------------------------------------------------------------------------------
def spectral_noise(h, w, rng, beta=2.0, fmin=1.0, fmax=None):
    """Tileable fractal noise via 1/f^beta spectral synthesis, normalized to [0, 1].
    fmin / fmax are in cycles per tile: fmin=2 removes features bigger than half the tile."""
    white = rng.standard_normal((h, w)).astype(np.float32)
    fy = np.fft.fftfreq(h)[:, None] * h
    fx = np.fft.fftfreq(w)[None, :] * w
    f = np.sqrt(fx * fx + fy * fy)
    amp = np.zeros_like(f)
    mask = f >= fmin
    if fmax is not None:
        mask &= f <= fmax
    amp[mask] = 1.0 / np.power(f[mask], beta / 2.0)
    field = np.real(np.fft.ifft2(np.fft.fft2(white) * amp))
    return norm01(field)


def sample_bilinear(field, x, y):
    """Sample a (H, W) field at float pixel coordinates (x, y) with wraparound."""
    h, w = field.shape
    x0 = np.floor(x).astype(np.int64)
    y0 = np.floor(y).astype(np.int64)
    fx = (x - x0).astype(np.float32)
    fy = (y - y0).astype(np.float32)
    x0 %= w
    y0 %= h
    x1 = (x0 + 1) % w
    y1 = (y0 + 1) % h
    a = field[y0, x0]
    b = field[y0, x1]
    c = field[y1, x0]
    d = field[y1, x1]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def warp(field, dx, dy, amount):
    """Domain warp: sample `field` displaced by (dx, dy) in [-0.5, 0.5] * amount pixels."""
    h, w = field.shape
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    return sample_bilinear(field, xs + (dx - 0.5) * amount, ys + (dy - 0.5) * amount)


# ----------------------------------------------------------------------------------------------------------------
# blur
# ----------------------------------------------------------------------------------------------------------------
def blur(field, sigma, wrap=False):
    """Gaussian blur (FFT). wrap=False pads by 3 sigma with edge values so borders don't bleed across."""
    if sigma <= 0:
        return field.astype(np.float32)
    pad = 0 if wrap else int(math.ceil(sigma * 3))
    src = np.pad(field, pad, mode="edge") if pad else field
    h, w = src.shape
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.fftfreq(w)[None, :]
    g = np.exp(-2 * (math.pi ** 2) * (sigma ** 2) * (fx * fx + fy * fy))
    out = np.real(np.fft.ifft2(np.fft.fft2(src) * g)).astype(np.float32)
    if pad:
        out = out[pad:-pad, pad:-pad]
    return out


# ----------------------------------------------------------------------------------------------------------------
# lighting for puffy volumes
# ----------------------------------------------------------------------------------------------------------------
def shade_from_density(density, light=(-0.55, -0.75, 0.6), strength=1.0, soften=2.0):
    """Fake volumetric lighting: treat a blurred density as a height field and Lambert-shade it.
    light is (x, y, z) with y down (screen space); returns [0, 1]."""
    hgt = blur(density, soften)
    gy, gx = np.gradient(hgt)
    s = strength * density.shape[0] / 64.0
    nx, ny, nz = -gx * s, -gy * s, np.ones_like(hgt)
    inv = 1.0 / np.sqrt(nx * nx + ny * ny + nz * nz)
    lx, ly, lz = light
    ll = math.sqrt(lx * lx + ly * ly + lz * lz)
    lam = (nx * lx + ny * ly + nz * lz) * inv / ll
    return np.clip(lam, 0, 1)


# ----------------------------------------------------------------------------------------------------------------
# images
# ----------------------------------------------------------------------------------------------------------------
def rgba(gray, alpha, tint=(1.0, 1.0, 1.0)):
    g = np.clip(gray, 0, 1)
    a = np.clip(alpha, 0, 1)
    return np.stack([g * tint[0], g * tint[1], g * tint[2], a], axis=-1).astype(np.float32)


def rgba_color(rgb, alpha):
    return np.concatenate([np.clip(rgb, 0, 1), np.clip(alpha, 0, 1)[..., None]], axis=-1).astype(np.float32)


def bleed_rgb(img, iterations=6):
    """Fill RGB under fully transparent pixels from nearby opaque ones (no dark fringes when the GPU filters)."""
    out = img.copy()
    a = out[..., 3]
    known = a > 0.004
    rgb = out[..., :3] * known[..., None]
    wsum = known.astype(np.float32)
    for i in range(iterations):
        s = 2.0 * (2 ** i)
        rgb_b = np.stack([blur(rgb[..., c], s) for c in range(3)], axis=-1)
        w_b = blur(wsum, s)
        fill = (~known) & (w_b > 1e-4)
        est = rgb_b / np.maximum(w_b, 1e-6)[..., None]
        out[..., :3][fill] = est[fill]
        known = known | fill
        rgb = out[..., :3] * known[..., None]
        wsum = known.astype(np.float32)
    return out


def edge_fade(alpha, margin_px):
    """Force alpha to 0 within margin_px of the image border (flipbook cells must not bleed)."""
    h, w = alpha.shape
    ys = np.arange(h, dtype=np.float32)[:, None]
    xs = np.arange(w, dtype=np.float32)[None, :]
    d = np.minimum(np.minimum(xs, w - 1 - xs), np.minimum(ys, h - 1 - ys))
    return alpha * smoothstep(0, margin_px, d - 1)


def to_image(img):
    arr = (np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8)
    return Image.fromarray(arr, "RGBA")


def save(img, name, bleed=True):
    os.makedirs(OUT_DIR, exist_ok=True)
    if bleed:
        img = bleed_rgb(img)
    path = os.path.join(OUT_DIR, name + ".png")
    to_image(img).save(path, optimize=True)
    return path


def atlas(frames, cols):
    """Pack equally sized RGBA frames row-major (Roblox flipbook order: left->right, top->bottom)."""
    fh, fw, _ = frames[0].shape
    rows = (len(frames) + cols - 1) // cols
    out = np.zeros((rows * fh, cols * fw, 4), dtype=np.float32)
    for i, f in enumerate(frames):
        r, c = divmod(i, cols)
        out[r * fh:(r + 1) * fh, c * fw:(c + 1) * fw] = f
    return out


def resize(img, size):
    """Downsample an RGBA float image with premultiplied alpha (no halos)."""
    pm = img.copy()
    pm[..., :3] *= pm[..., 3:4]
    channels = []
    for c in range(4):
        im = Image.fromarray(pm[..., c].astype(np.float32), "F").resize(size, Image.LANCZOS)
        channels.append(np.asarray(im, dtype=np.float32))
    out = np.stack(channels, axis=-1)
    a = np.clip(out[..., 3:4], 0, 1)
    out[..., :3] = np.where(a > 1e-4, out[..., :3] / np.maximum(a, 1e-4), 0)
    out[..., 3:4] = a
    return np.clip(out, 0, 1)
