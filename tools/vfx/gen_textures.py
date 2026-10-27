#!/usr/bin/env python3
"""Procedural VFX textures for Hotwire City (numpy + PIL). Output: assets/vfx/<key>.png

Usage:  python3 tools/vfx/gen_textures.py            # everything procedural
        python3 tools/vfx/gen_textures.py smoke_puff_a fire_flipbook

Conventions (see src/shared/Config/VFX.luau):
  * Mostly white / greyscale with straight alpha so ParticleEmitter.Color / Beam.Color / Trail.Color can tint.
    The impact star keeps a dark comic outline (multiply-tinting leaves it dark), the cash bill is green.
  * Flipbooks are square, row-major (left->right, top->bottom) with transparent padding in every cell.
  * Streak sprites (spark_streak, speed_line) are vertical: VelocityParallel particles align texture-up with motion.
  * Beam / Trail strips (nitro_jet, headlight_beam, skid_mark, underglow) run along +X (Attachment0 -> Attachment1).
The Blender-rendered set (coin_spin, debris_chips, cash_flutter, confetti) lives in tools/vfx/render_blender.py.
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(__file__))
from vfxlib import (  # noqa: E402
    OUT_DIR,
    atlas,
    blur,
    edge_fade,
    grid,
    norm01,
    resize,
    rgba,
    rgba_color,
    sample_bilinear,
    save,
    shade_from_density,
    smoothstep,
    spectral_noise,
)

GENERATORS = {}


def generator(fn):
    GENERATORS[fn.__name__] = fn
    return fn


# ----------------------------------------------------------------------------------------------------------------
# smoke family: a lit union of spheres (cauliflower billows) with noise-eroded, fluffy edges
# ----------------------------------------------------------------------------------------------------------------
def make_spheres(rng, count, spread, rmin, rmax, squash=1.0, core_scale=1.45):
    sph = []
    for i in range(count):
        a = rng.uniform(0, 2 * math.pi)
        d = spread * math.sqrt(rng.uniform(0.05, 1)) * (0.15 if i == 0 else 1.0)
        r = rng.uniform(rmin, rmax) * (core_scale if i == 0 else 1.0)
        sph.append([math.cos(a) * d, math.sin(a) * d * squash, rng.uniform(-0.2, 0.25), r, math.cos(a), math.sin(a)])
    return sph


def ring_spheres(rng, rings, jitter=0.25, squash=1.0):
    """Rounder clusters: rings of (ring radius, count, sphere radius); center spheres sit in front."""
    sph = []
    for (R, n, r) in rings:
        a0 = rng.uniform(0, 2 * math.pi)
        for k in range(n):
            a = a0 + k * 2 * math.pi / max(n, 1) + rng.uniform(-jitter, jitter) / max(n, 1) * 6
            d = R * rng.uniform(0.85, 1.12)
            rr = r * rng.uniform(0.8, 1.2)
            sph.append([math.cos(a) * d, math.sin(a) * d * squash, rng.uniform(-0.15, 0.2) - R * 0.3, rr,
                        math.cos(a), math.sin(a)])
    return sph


def sphere_field(size, spheres, grow=1.0, drift=0.0, rise=0.0, rscale=1.0):
    """Height field + normals of the union of spheres (front-most surface wins)."""
    x, y = grid(size)
    H = np.full((size, size), -9.0, dtype=np.float32)
    nx = np.zeros_like(H)
    ny = np.zeros_like(H)
    nz = np.ones_like(H)
    T = np.zeros_like(H)
    for (cx, cy, cz, r, dx, dy) in spheres:
        px = (cx + dx * drift) * grow
        py = (cy + dy * drift) * grow - rise
        rr = r * rscale * grow
        d2 = (x - px) ** 2 + (y - py) ** 2
        inside = d2 < rr * rr
        chord = np.sqrt(np.maximum(rr * rr - d2, 0))
        T += 2 * chord
        h = chord + cz * rr
        upd = inside & (h > H)
        H = np.where(upd, h, H)
        nx = np.where(upd, (x - px) / rr, nx)
        ny = np.where(upd, (y - py) / rr, ny)
        nz = np.where(upd, np.sqrt(np.maximum(rr * rr - d2, 0)) / rr, nz)
    cover = (H > -8).astype(np.float32)
    return H, nx, ny, nz, cover, T


def puff_image(size, spheres, rng_noise, t=0.0, grow=1.0, drift=0.0, rise=0.0, rscale=1.0, erosion=0.25,
               fluff=0.22, contrast=0.62, opacity=1.0, wisp=0.0, grit=0.0, light=(-0.45, -0.8, 0.55)):
    """Render a puff. rng_noise: dict of precomputed noise fields (n1, n2, n3, wx, wy) at `size`."""
    n1, n2, n3, wx, wy = (rng_noise[k] for k in ("n1", "n2", "n3", "wx", "wy"))
    H, nx, ny, nz, cover, T = sphere_field(size, spheres, grow, drift, rise, rscale)
    # smooth the facets (smoke is soft) + a gentle low-frequency bump
    soft = size / 110.0
    nx, ny, nz = blur(nx, soft), blur(ny, soft), blur(nz, soft)
    gy, gx = np.gradient(blur(n1, size / 120.0))
    bump = size / 70.0
    nx = nx - gx * bump
    ny = ny - gy * bump
    inv = 1.0 / np.sqrt(nx * nx + ny * ny + nz * nz + 1e-6)
    nx, ny, nz = nx * inv, ny * inv, nz * inv
    lx, ly, lz = light
    ll = math.sqrt(lx * lx + ly * ly + lz * lz)
    ndl = (nx * lx + ny * ly + nz * lz) / ll
    wrap = 0.45
    diffuse = np.clip((ndl + wrap) / (1 + wrap), 0, 1)
    rim = np.power(np.clip(1 - nz, 0, 1), 2.5) * 0.18
    Hc = np.where(cover > 0, H, 0)
    ao = np.clip(1 + (Hc - blur(Hc, size / 14.0)) * 2.6, 0.5, 1.08)
    x, y = grid(size)
    under = 0.88 + 0.12 * np.clip(-y * 1.2 + 0.2, -1, 1)  # undersides a touch darker
    gray = (1 - contrast) + contrast * diffuse * ao * under + rim
    gray += (n2 - 0.5) * 0.05
    # alpha: thickness from height, eroded by multi-scale noise -> fluffy, translucent fringe
    # alpha: Beer-Lambert on the summed chord thickness, eroded by multi-scale noise -> fluffy, translucent fringe
    e = 0.5 * n1 + 0.3 * n2 + 0.2 * n3
    dens = T * (1 + (e - 0.5) * fluff * 3.0) - erosion * (0.1 + 0.32 * e)
    alpha = 1 - np.exp(-np.maximum(dens, 0) * 11.0)
    alpha = blur(alpha, size / 260.0)
    if grit > 0:
        g = spectral_noise(size, size, np.random.default_rng(5), beta=0.4, fmin=60)
        alpha *= 1 - grit * (1 - g) * 0.9
    img = rgba(np.clip(gray, 0, 1), np.clip(alpha * opacity, 0, 1))
    if wisp > 0:
        ys, xs = np.mgrid[0:size, 0:size].astype(np.float32)
        amt = wisp * size
        sx = xs + (wx - 0.5) * amt
        sy = ys + (wy - 0.5) * amt
        img = np.stack([sample_bilinear(img[..., c], sx, sy) for c in range(4)], axis=-1)
    img[..., 3] = edge_fade(img[..., 3], size * 0.025)
    return img


def noise_set(size, seed, wisp_scale=2.6):
    rng = np.random.default_rng(seed)
    return {
        "n1": spectral_noise(size, size, rng, beta=2.0, fmin=4),
        "n2": spectral_noise(size, size, rng, beta=1.5, fmin=10),
        "n3": spectral_noise(size, size, rng, beta=1.0, fmin=28),
        "wx": spectral_noise(size, size, rng, beta=wisp_scale, fmin=2),
        "wy": spectral_noise(size, size, rng, beta=wisp_scale, fmin=2),
    }


@generator
def smoke_puff_a():
    rng = np.random.default_rng(101)
    sph = make_spheres(rng, 28, 0.52, 0.14, 0.27, core_scale=1.15)
    img = puff_image(1024, sph, noise_set(1024, 11), erosion=0.26, fluff=0.36, wisp=0.02)
    return save(resize(img, (512, 512)), "smoke_puff_a")


@generator
def smoke_puff_b():
    rng = np.random.default_rng(202)
    sph = make_spheres(rng, 26, 0.58, 0.14, 0.29, squash=0.75)
    img = puff_image(1024, sph, noise_set(1024, 22), erosion=0.28, wisp=0.03)
    return save(resize(img, (512, 512)), "smoke_puff_b")


@generator
def smoke_puff_c():
    rng = np.random.default_rng(313)
    sph = make_spheres(rng, 16, 0.5, 0.17, 0.32)
    img = puff_image(1024, sph, noise_set(1024, 33), erosion=0.42, fluff=0.4, wisp=0.09, contrast=0.4,
                     opacity=0.92)
    return save(resize(img, (512, 512)), "smoke_puff_c")


@generator
def dust_puff():
    rng = np.random.default_rng(404)
    sph = make_spheres(rng, 28, 0.5, 0.13, 0.25, squash=0.72, core_scale=1.2)
    img = puff_image(1024, sph, noise_set(1024, 44), erosion=0.4, fluff=0.45, wisp=0.05, contrast=0.5,
                     grit=0.45)
    # flying grit specks around the cloud
    x, y = grid(1024)
    r = np.sqrt(x * x + y * y)
    sp = np.zeros((1024, 1024), dtype=np.float32)
    for _ in range(46):
        a = rng.uniform(0, 2 * math.pi)
        d = rng.uniform(0.55, 0.9)
        sx, sy, sr = math.cos(a) * d, math.sin(a) * d * 0.85, rng.uniform(0.004, 0.009)
        sp = np.maximum(sp, np.exp(-((x - sx) ** 2 + (y - sy) ** 2) / (sr * sr)) * rng.uniform(0.6, 1))
    a_ = np.maximum(img[..., 3], sp * smoothstep(0.98, 0.9, r))
    img[..., 3] = a_
    img[..., :3] = np.where((sp > 0.05)[..., None] & (img[..., 3:4] < 0.2), 0.45, img[..., :3])
    return save(resize(img, (512, 512)), "dust_puff")


def evolving_puff(seed, cells=16, cell=256, wispy=False):
    S = cell * 2
    rng = np.random.default_rng(seed)
    if wispy:
        sph = ring_spheres(rng, [(0.0, 1, 0.3), (0.26, 6, 0.2), (0.48, 10, 0.15)], jitter=0.5)
    else:
        sph = ring_spheres(rng, [(0.0, 1, 0.32), (0.27, 6, 0.21), (0.5, 9, 0.17)], jitter=0.35)
    ns = noise_set(S, seed + 1)
    frames = []
    for i in range(cells):
        t = i / (cells - 1)
        e = 1 - (1 - t) ** 2
        grow = 0.86 + 0.34 * e
        img = puff_image(
            S, sph, _shift_noise(ns, t, S),
            grow=grow, drift=0.06 * e, rise=0.03 * t, rscale=1.0 + 0.05 * t,
            erosion=(0.3 if wispy else 0.18) + 0.75 * t,
            fluff=(0.5 if wispy else 0.26) + 0.25 * t,
            wisp=(0.06 if wispy else 0.015) + (0.1 if wispy else 0.07) * t,
            contrast=(0.4 if wispy else 0.62) - 0.1 * t,
            opacity=(0.8 if wispy else 1.0) * (1 - 0.3 * smoothstep(0.6, 1.0, t)),
        )
        frames.append(resize(img, (cell, cell)))
    return atlas(frames, 4)


def _shift_noise(ns, t, S):
    """Noise drifts up + swirls over the flipbook (sampling offset grows with t)."""
    ys, xs = np.mgrid[0:S, 0:S].astype(np.float32)
    ox, oy = 18 * t * S / 256, 30 * t * S / 256
    out = {}
    for k, f in ns.items():
        out[k] = sample_bilinear(f, xs + ox * (1 if k in ("n1", "wx") else -0.6), ys + oy)
    return out


@generator
def smoke_flipbook():
    return save(evolving_puff(505), "smoke_flipbook")


@generator
def tire_smoke():
    return save(evolving_puff(606, wispy=True), "tire_smoke")


# ----------------------------------------------------------------------------------------------------------------
# fire family
# ----------------------------------------------------------------------------------------------------------------
@generator
def fire_flipbook():
    """Looping flame (16 frames): the noise scrolls exactly one / two tile periods over the loop -> seamless."""
    S = 512
    cell = 256
    rng = np.random.default_rng(707)
    n1 = spectral_noise(S, S, rng, beta=2.0, fmin=2)
    n2 = spectral_noise(S, S, rng, beta=1.4, fmin=6)
    wx = spectral_noise(S, S, rng, beta=2.4, fmin=2)
    x, y = grid(S)
    ys, xs = np.mgrid[0:S, 0:S].astype(np.float32)
    yy = (0.72 - y) / 1.55  # 0 at the flame base (lower part of the cell), 1 near the top
    frames = []
    for i in range(16):
        ph = i / 16.0
        off1 = ph * S
        off2 = ph * S * 2
        warpx = (sample_bilinear(wx, xs, ys + off1) - 0.5) * 70 * np.clip(yy, 0, 1)
        n = 0.62 * sample_bilinear(n1, xs + warpx, ys + off1) + 0.38 * sample_bilinear(n2, xs + warpx * 0.6,
                                                                                         ys + off2)
        xw = x + (warpx / S) * 2 * 0.6
        width = 0.5 * np.power(np.clip(1 - yy, 0, 1), 0.75) + 0.02
        dist = np.abs(xw) / np.maximum(width, 1e-3)
        base = np.clip(1 - dist, 0, 1) * np.power(np.clip(1 - yy, 0, 1), 0.55)
        f = base * 1.55 - n * (0.25 + 0.95 * np.clip(yy, 0, 1)) - 0.05
        f *= smoothstep(-0.12, 0.06, yy)  # soft base
        flame = smoothstep(0.0, 0.42, f)
        core = smoothstep(0.32, 0.85, f)
        gray = 0.62 + 0.38 * core
        alpha = np.clip(flame * 0.85 + core * 0.15, 0, 1)
        alpha = edge_fade(alpha, S * 0.03)
        frames.append(resize(rgba(gray, alpha), (cell, cell)))
    return save(atlas(frames, 4), "fire_flipbook")


@generator
def nitro_jet():
    """Beam strip (512x128, x = exhaust -> tip): hot core, shock diamonds, soft sheath. Tint with Beam.Color."""
    W, H = 1024, 256
    rng = np.random.default_rng(808)
    xs = (np.arange(W, dtype=np.float32) + 0.5) / W
    ys = (np.arange(H, dtype=np.float32) + 0.5) / H * 2 - 1
    x, y = np.meshgrid(xs, ys)
    w = 0.42 * np.power(1 - x, 0.7) + 0.05
    core = np.exp(-np.power(y / (w * 0.55), 2) * 2.2) * np.power(1 - x, 1.1)
    sheath = np.exp(-np.power(y / (w * 1.25), 2) * 1.6) * np.power(1 - x, 1.8) * 0.55
    diamonds = np.zeros_like(x)
    for k, xc in enumerate([0.12, 0.27, 0.41, 0.54, 0.66]):
        amp = 0.95 * (0.78 ** k)
        dx = (x - xc) / (0.038 + 0.006 * k)
        dy = y / (w * 0.42)
        diamonds += amp * np.exp(-(np.abs(dx) + np.abs(dy)) ** 2 * 1.8)
    n = spectral_noise(H, W, rng, beta=1.8, fmin=3)
    streak = np.repeat(blur(n, 3)[:, :1], W, axis=1)  # streaks along x
    turb = 0.82 + 0.18 * (0.6 * n + 0.4 * streak)
    inten = (core * 0.85 + sheath + diamonds * 0.6 * np.exp(-np.power(y / (w * 0.8), 2))) * turb
    inten *= smoothstep(0.0, 0.025, x) * smoothstep(1.0, 0.82, x)
    inten = np.clip(inten, 0, 1.2)
    gray = 0.7 + 0.3 * np.clip(core * 1.2 + diamonds * 0.5, 0, 1)
    alpha = np.clip(inten, 0, 1)
    alpha *= smoothstep(1.0, 0.9, np.abs(y))
    img = rgba(gray, alpha)
    return save(resize(img, (512, 128)), "nitro_jet")


@generator
def backfire_burst():
    """2x2 one-shot burst: hot pop -> petals -> breaking ring -> wisps."""
    S = 512
    cell = 256
    rng = np.random.default_rng(909)
    x, y = grid(S)
    r = np.sqrt(x * x + y * y)
    th = np.arctan2(y, x)
    lobes = np.zeros_like(th)
    for k, amp in [(5, 0.22), (8, 0.15), (13, 0.1), (21, 0.06)]:
        lobes += amp * np.sin(k * th + rng.uniform(0, 6.28))
    n = spectral_noise(S, S, rng, beta=1.7, fmin=4)
    frames = []
    for i, t in enumerate([0.0, 0.33, 0.66, 1.0]):
        R = 0.42 + 0.48 * (1 - (1 - t) ** 2)
        edge = R * (0.72 + lobes * (0.6 + 0.6 * t))
        body = smoothstep(edge, edge * (0.55 - 0.25 * t), r)
        hollow = smoothstep(0.05 + 0.55 * t * R, 0.25 + 0.6 * t * R, r) if t > 0 else np.ones_like(r)
        f = body * hollow - n * (0.15 + 0.7 * t)
        flame = smoothstep(0.02, 0.4, f)
        core = smoothstep(0.35, 0.95, f) * (1 - 0.6 * t)
        hot = np.exp(-(r / (0.25 * (1 - 0.7 * t) + 0.05)) ** 2) * (1 - t)
        gray = np.clip(0.6 + 0.4 * np.maximum(core, hot), 0, 1)
        alpha = np.clip(np.maximum(flame, hot) * (1 - 0.35 * t), 0, 1)
        alpha = edge_fade(alpha, S * 0.03)
        frames.append(resize(rgba(gray, alpha), (cell, cell)))
    return save(atlas(frames, 2), "backfire_burst")


# ----------------------------------------------------------------------------------------------------------------
# light sprites
# ----------------------------------------------------------------------------------------------------------------
@generator
def glow_dot():
    S = 256
    x, y = grid(S)
    r2 = x * x + y * y
    inten = 0.55 * np.exp(-r2 / 0.012) + 0.3 * np.exp(-r2 / 0.06) + 0.18 * np.exp(-r2 / 0.25)
    inten = norm01(inten) * smoothstep(1.0, 0.85, np.sqrt(r2))
    return save(rgba(np.ones_like(inten), inten), "glow_dot")


@generator
def sparkle_star():
    S = 256
    x, y = grid(S)
    r = np.sqrt(x * x + y * y)
    ray = lambda a, b, l: np.exp(-np.abs(a) / 0.016) * np.power(np.clip(1 - np.abs(b) / l, 0, 1), 2.2)  # noqa
    main = ray(x, y, 0.98) + ray(y, x, 0.98)
    xd, yd = (x + y) / math.sqrt(2), (x - y) / math.sqrt(2)
    diag = 0.45 * (ray(xd, yd, 0.55) + ray(yd, xd, 0.55))
    core = np.exp(-r * r / 0.006) + 0.35 * np.exp(-r * r / 0.05)
    inten = np.clip(main + diag + core, 0, 1)
    inten *= smoothstep(1.0, 0.9, np.maximum(np.abs(x), np.abs(y)))
    return save(rgba(np.ones_like(inten), inten), "sparkle_star")


@generator
def glare():
    """Siren / headlight glare: hot core, anamorphic horizontal streak, thin starburst, faint halo ring."""
    S = 512
    rng = np.random.default_rng(1111)
    x, y = grid(S)
    r = np.sqrt(x * x + y * y)
    th = np.arctan2(y, x)
    core = np.exp(-r * r / 0.004) + 0.5 * np.exp(-r * r / 0.03) + 0.2 * np.exp(-r * r / 0.15)
    streak = np.exp(-np.power(y / 0.018, 2)) * np.exp(-np.abs(x) / 0.38) * 0.9
    streak += np.exp(-np.power(y / 0.06, 2)) * np.exp(-np.abs(x) / 0.25) * 0.25
    vstreak = np.exp(-np.power(x / 0.012, 2)) * np.exp(-np.abs(y) / 0.16) * 0.35
    rays = np.zeros_like(r)
    for k in range(12):
        a = k * math.pi / 6 + rng.uniform(-0.06, 0.06)
        d = np.abs(np.sin(th - a)) * r
        along = np.cos(th - a)
        ln = rng.uniform(0.35, 0.7)
        rays += np.exp(-d / 0.006) * np.clip(along, 0, 1) * np.power(np.clip(1 - r / ln, 0, 1), 1.5) * 0.35
    halo = np.exp(-np.power((r - 0.55) / 0.03, 2)) * 0.12
    inten = np.clip(core + streak + vstreak + rays + halo, 0, 1)
    inten *= smoothstep(1.0, 0.92, np.maximum(np.abs(x), np.abs(y)))
    return save(rgba(np.ones_like(inten), inten), "glare")


@generator
def spark_streak():
    S = 256
    x, y = grid(S)
    v = (y + 1) / 2  # 0 top (leading end) .. 1 bottom (tail)
    profile = smoothstep(0.02, 0.14, v) * np.power(np.clip(1 - v, 0, 1), 1.3) * 1.25
    profile = np.clip(profile, 0, 1)
    width = 0.022 + 0.02 * (1 - v)
    core = np.exp(-np.power(x / (width * 0.6), 2))
    glow = np.exp(-np.power(x / (width * 3.2), 2)) * 0.35
    inten = np.clip((core + glow) * profile, 0, 1)
    gray = 0.85 + 0.15 * np.clip(core * 1.2, 0, 1)
    return save(rgba(gray, inten), "spark_streak")


@generator
def speed_line():
    S = 256
    x, y = grid(S)
    v = (y + 1) / 2
    profile = np.power(np.sin(np.clip(v, 0, 1) * math.pi), 1.6) * (0.7 + 0.3 * (1 - v))
    core = np.exp(-np.power(x / 0.018, 2))
    glow = np.exp(-np.power(x / 0.06, 2)) * 0.25
    inten = np.clip((core + glow) * profile, 0, 1) * 0.9
    return save(rgba(np.ones_like(inten), inten), "speed_line")


@generator
def shockwave_ring():
    S = 512
    rng = np.random.default_rng(1212)
    x, y = grid(S)
    r = np.sqrt(x * x + y * y)
    th = np.arctan2(y, x)
    wob = 0.012 * np.sin(7 * th + 1.3) + 0.008 * np.sin(13 * th + 0.2)
    rr = r + wob
    front = smoothstep(0.9, 0.84, rr) * np.power(smoothstep(0.35, 0.84, rr), 2.4)
    rim = np.exp(-np.power((rr - 0.855) / 0.018, 2)) * 0.6
    n = spectral_noise(S, S, rng, beta=1.5, fmin=6)
    inten = np.clip((front * 0.85 + rim) * (0.8 + 0.2 * n), 0, 1)
    gray = 0.8 + 0.2 * smoothstep(0.6, 0.86, rr)
    return save(rgba(gray, inten), "shockwave_ring")


# ----------------------------------------------------------------------------------------------------------------
# comic impact star (normal blending: keeps a dark outline)
# ----------------------------------------------------------------------------------------------------------------
@generator
def impact_star():
    S = 512
    SS = 4
    big = S * SS
    rng = np.random.default_rng(1313)
    c = big / 2

    def star_points(n, rout, rin, rot, jitter):
        pts = []
        for k in range(n * 2):
            a = rot + k * math.pi / n + rng.uniform(-jitter, jitter)
            rad = (rout * rng.uniform(0.82, 1.0)) if k % 2 == 0 else (rin * rng.uniform(0.9, 1.08))
            pts.append((c + math.cos(a) * rad * c, c + math.sin(a) * rad * c))
        return pts

    outline = (27, 29, 43)
    shadow = Image.new("L", (big, big), 0)
    body = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    outer = star_points(12, 0.86, 0.52, -0.2, 0.07)
    inner = star_points(9, 0.56, 0.33, 0.15, 0.05)
    sd = ImageDraw.Draw(shadow)
    off = int(0.035 * big)
    sd.polygon([(px + off, py + off) for px, py in outer], fill=150)
    d = ImageDraw.Draw(body)
    # action lines outside the star
    for k in range(16):
        a = k * 2 * math.pi / 16 + rng.uniform(-0.1, 0.1)
        r0, r1 = rng.uniform(0.8, 0.88), rng.uniform(0.93, 0.99)
        wdt = int(big * rng.uniform(0.008, 0.014))
        d.line([(c + math.cos(a) * r0 * c, c + math.sin(a) * r0 * c),
                (c + math.cos(a) * r1 * c, c + math.sin(a) * r1 * c)], fill=outline + (255,), width=wdt)
    d.polygon(outer, fill=(222, 222, 222, 255))
    d.line(outer + [outer[0]], fill=outline + (255,), width=int(big * 0.03), joint="curve")
    # halftone dots on the outer band
    step = int(big * 0.034)
    for yy in range(0, big, step):
        for xx in range(((yy // step) % 2) * step // 2, big, step):
            dx, dy = (xx - c) / c, (yy - c) / c
            rr = math.hypot(dx, dy)
            if 0.38 < rr < 0.8:
                rad = big * 0.009 * (rr - 0.3)
                d.ellipse([xx - rad, yy - rad, xx + rad, yy + rad], fill=(185, 185, 185, 255))
    # re-stroke so the dots stay inside
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).polygon(outer, fill=255)
    clipped = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    clipped.paste(body, (0, 0), mask)
    body = Image.alpha_composite(Image.new("RGBA", (big, big), (0, 0, 0, 0)), body)
    d = ImageDraw.Draw(body)
    d.line(outer + [outer[0]], fill=outline + (255,), width=int(big * 0.03), joint="curve")
    d.polygon(inner, fill=(255, 255, 255, 255))
    d.line(inner + [inner[0]], fill=outline + (255,), width=int(big * 0.016), joint="curve")
    # glossy highlight in the inner star
    hl = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(hl).ellipse([c - 0.3 * c, c - 0.36 * c, c - 0.02 * c, c - 0.12 * c], fill=(255, 255, 255, 140))
    body = Image.alpha_composite(body, hl)
    # compose: blurred shadow under the body
    shadow = shadow.resize((S, S), Image.LANCZOS)
    sh = blur(np.asarray(shadow, dtype=np.float32) / 255.0, 4) * 0.55
    b = np.asarray(body.resize((S, S), Image.LANCZOS), dtype=np.float32) / 255.0
    a_b = b[..., 3]
    a = a_b + sh * (1 - a_b)
    rgb = np.where(a[..., None] > 1e-4, (b[..., :3] * a_b[..., None] + 0.08 * (sh * (1 - a_b))[..., None])
                   / np.maximum(a, 1e-4)[..., None], 0)
    return save(rgba_color(rgb, a), "impact_star")


# ----------------------------------------------------------------------------------------------------------------
# water
# ----------------------------------------------------------------------------------------------------------------
@generator
def water_splash():
    S = 512 * 4
    cell = 256
    rng = np.random.default_rng(1414)
    jets = []
    for k in range(17):
        a = math.radians(rng.uniform(-62, 62))
        jets.append((a, rng.uniform(0.55, 1.0), rng.uniform(0.012, 0.024), rng.uniform(0, 1)))
    frames = []
    for i, t in enumerate([0.15, 0.45, 0.75, 1.0]):
        im = Image.new("L", (S, S), 0)
        d = ImageDraw.Draw(im)
        bx, by = S / 2, S * 0.8
        # foam base
        fw = S * (0.22 + 0.16 * t)
        d.ellipse([bx - fw, by - S * 0.05, bx + fw, by + S * 0.05], fill=int(200 * (1 - 0.5 * t)))
        for (a, ln, wd, ph) in jets:
            reach = ln * S * 0.62 * min(1.0, 0.35 + t * 1.1)
            drop = max(0.0, t - 0.55) * S * 0.25
            sx = bx + math.sin(a) * S * 0.08
            ex = bx + math.sin(a) * reach
            ey = by - math.cos(a) * reach + drop * (0.6 + ph)
            sheet_len = 1.0 - smoothstep(0.5, 1.0, t) * 0.75
            mx = sx + (ex - sx) * (1 - sheet_len)
            my = by + (ey - by) * (1 - sheet_len)
            w0 = int(S * wd * (1 - 0.4 * t))
            d.line([(mx, my), (ex, ey)], fill=int(235 * (1 - 0.3 * t)), width=max(2, w0))
            rr = S * wd * 0.9
            d.ellipse([ex - rr, ey - rr, ex + rr, ey + rr], fill=255)
            if t > 0.4:
                for q in range(3):
                    qq = (q + 1) * 0.12 + ph * 0.1
                    qx = ex + math.sin(a) * S * qq * 0.4 + rng.uniform(-1, 1) * S * 0.01
                    qy = ey - math.cos(a) * S * qq * 0.25 + (t - 0.4) * S * 0.2 * (q + 1) * 0.5
                    qr = S * wd * rng.uniform(0.4, 0.8)
                    d.ellipse([qx - qr, qy - qr, qx + qr, qy + qr], fill=230)
        a_small = np.asarray(im.resize((512, 512), Image.LANCZOS), dtype=np.float32) / 255.0
        a_small = blur(a_small, 1.2)
        x, y = grid(512)
        gray = 0.82 + 0.18 * (0.5 - 0.5 * y)
        hl = blur(a_small, 6)
        gray = gray + 0.1 * (a_small - hl)
        frames.append(resize(rgba(gray, edge_fade(a_small, 14)), (cell, cell)))
    return save(atlas(frames, 2), "water_splash")


# ----------------------------------------------------------------------------------------------------------------
# beams / trails
# ----------------------------------------------------------------------------------------------------------------
@generator
def skid_mark():
    """Trail strip, tiles along X (trail length). Tread blocks + patchy rubber deposit. Tint dark."""
    W, H = 512, 128
    rng = np.random.default_rng(1515)
    xs = (np.arange(W, dtype=np.float32) + 0.5) / W
    ys = (np.arange(H, dtype=np.float32) + 0.5) / H * 2 - 1
    x, y = np.meshgrid(xs, ys)
    band = smoothstep(0.98, 0.78, np.abs(y))
    grooves = np.ones_like(y)
    for gc in (-0.42, 0.0, 0.42):
        grooves *= 1 - 0.75 * np.exp(-np.power((y - gc) / 0.05, 2))
    # lateral sipes: angled blocks repeating 16x along the strip (tileable)
    sipes = 0.5 + 0.5 * np.cos(2 * math.pi * (x * 16 + np.abs(y) * 0.6))
    sipes = 1 - 0.35 * smoothstep(0.75, 0.95, sipes) * smoothstep(0.1, 0.25, np.abs(y))
    n = spectral_noise(H, W, rng, beta=1.6, fmin=2)
    n_streak = spectral_noise(H, W, rng, beta=2.2, fmin=1)
    # stretch the second noise along x by sampling a squashed version (stays tileable: integer repeat)
    ys_i, xs_i = np.mgrid[0:H, 0:W].astype(np.float32)
    n_streak = sample_bilinear(n_streak, xs_i * 0.25, ys_i)
    deposit = 0.5 + 0.5 * (0.55 * n + 0.45 * n_streak)
    deposit = smoothstep(0.25, 0.9, deposit)
    alpha = band * grooves * sipes * (0.35 + 0.65 * deposit) * 0.9
    gray = 0.85 + 0.15 * n
    return save(rgba(gray, alpha), "skid_mark")


@generator
def headlight_beam():
    W, H = 512, 256
    rng = np.random.default_rng(1616)
    xs = (np.arange(W, dtype=np.float32) + 0.5) / W
    ys = (np.arange(H, dtype=np.float32) + 0.5) / H * 2 - 1
    x, y = np.meshgrid(xs, ys)
    along = smoothstep(0.0, 0.05, x) * np.power(np.clip(1 - x, 0, 1), 1.7)
    across = smoothstep(1.0, 0.25, np.abs(y)) * (0.7 + 0.3 * np.exp(-np.power(y / 0.3, 2)))
    n = spectral_noise(H, W, rng, beta=2.0, fmin=2)
    rays = np.repeat(blur(n, 2)[:, :1], W, axis=1)
    inten = along * across * (0.78 + 0.22 * (0.5 * n + 0.5 * rays))
    inten = np.clip(inten / inten.max(), 0, 1)
    return save(rgba(np.ones_like(inten), inten), "headlight_beam")


@generator
def underglow():
    W, H = 512, 256
    xs = (np.arange(W, dtype=np.float32) + 0.5) / W * 2 - 1
    ys = (np.arange(H, dtype=np.float32) + 0.5) / H * 2 - 1
    x, y = np.meshgrid(xs, ys)
    # stadium SDF (half-length 0.55, radius 0.32 in a 2:1 frame)
    px = np.abs(x) * 2 - 1.1
    q = np.maximum(px, 0)
    dist = np.sqrt(q * q + (y * 1.0) ** 2) - 0.45
    inside = smoothstep(0.25, -0.35, dist)
    halo = np.exp(-np.maximum(dist, 0) ** 2 / 0.08)
    inten = np.clip(0.55 * inside + 0.6 * halo, 0, 1)
    inten *= smoothstep(1.0, 0.9, np.abs(x)) * smoothstep(1.0, 0.85, np.abs(y))
    return save(rgba(np.ones_like(inten), inten), "underglow")


# ----------------------------------------------------------------------------------------------------------------
# cash bill (flat art; cash_flutter renders it in Blender)
# ----------------------------------------------------------------------------------------------------------------
def _font(size, bold=True):
    for p in ["/usr/share/fonts/opentype/inter/InterDisplay-Bold.otf", "/usr/share/fonts/opentype/inter/Inter-Bold.otf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"]:
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def bill_image(W=1024, H=512):
    """Our own fictional note: Hotwire City 'Hot Buck', a flame-car medallion, guilloche, no real-currency motifs."""
    SS = 2
    w, h = W * SS, H * SS
    paper = np.zeros((h, w, 3), dtype=np.float32)
    xs = np.linspace(-1, 1, w, dtype=np.float32)
    ys = np.linspace(-1, 1, h, dtype=np.float32)
    x, y = np.meshgrid(xs, ys)
    base = np.array([0.56, 0.80, 0.52])
    dark = np.array([0.10, 0.36, 0.20])
    rng = np.random.default_rng(1717)
    n = spectral_noise(h, w, rng, beta=1.2, fmin=20)
    # guilloche: interfering sine rosettes
    th = np.arctan2(y * 0.5, x)
    r = np.sqrt((x * 1.0) ** 2 + (y * 0.5) ** 2)
    g1 = 0.5 + 0.5 * np.sin(40 * r + 6 * np.sin(8 * th))
    g2 = 0.5 + 0.5 * np.sin(60 * (x * 0.9 + 0.15 * np.sin(y * 9)))
    guil = smoothstep(0.85, 1.0, g1) * 0.5 + smoothstep(0.9, 1.0, g2) * 0.35
    tone = 0.5 + 0.5 * x * 0.15 + (n - 0.5) * 0.12
    for cch in range(3):
        paper[..., cch] = base[cch] * (0.92 + 0.12 * tone) - guil * (base[cch] - dark[cch]) * 0.55
    img = Image.fromarray((np.clip(paper, 0, 1) * 255).astype(np.uint8), "RGB").convert("RGBA")
    d = ImageDraw.Draw(img)
    ink = (22, 82, 46, 255)
    light = (225, 245, 220, 255)
    m = int(0.035 * h)
    d.rounded_rectangle([m, m, w - m, h - m], radius=int(0.05 * h), outline=ink, width=int(0.022 * h))
    d.rounded_rectangle([m * 2.1, m * 2.1, w - m * 2.1, h - m * 2.1], radius=int(0.04 * h), outline=ink,
                        width=int(0.008 * h))
    # medallion
    cx, cy, R = w * 0.5, h * 0.5, h * 0.33
    d.ellipse([cx - R * 1.08, cy - R * 1.08, cx + R * 1.08, cy + R * 1.08], fill=(196, 230, 190, 255), outline=ink,
              width=int(0.014 * h))
    for k in range(48):
        a = k * 2 * math.pi / 48
        d.line([(cx + math.cos(a) * R * 0.92, cy + math.sin(a) * R * 0.92),
                (cx + math.cos(a) * R * 1.04, cy + math.sin(a) * R * 1.04)], fill=ink, width=int(0.006 * h))
    # stylised flame-car silhouette (our own emblem)
    s = R / 100.0
    car = [(-70, 18), (-66, -2), (-40, -8), (-20, -30), (22, -30), (42, -8), (70, -4), (74, 18)]
    d.polygon([(cx + px * s, cy + py * s) for px, py in car], fill=ink)
    for wx in (-42, 46):
        d.ellipse([cx + (wx - 15) * s, cy + 6 * s, cx + (wx + 15) * s, cy + 36 * s], fill=ink)
        d.ellipse([cx + (wx - 7) * s, cy + 14 * s, cx + (wx + 7) * s, cy + 28 * s], fill=(196, 230, 190, 255))
    d.polygon([(cx + px * s, cy + py * s) for px, py in [(-14, -24), (16, -24), (32, -8), (-28, -8)]],
              fill=(196, 230, 190, 255))
    for k, (fx, fy, fl) in enumerate([(-74, -2, 46), (-76, 8, 60), (-74, 16, 40)]):
        d.polygon([(cx + fx * s, cy + (fy - 5) * s), (cx + (fx - fl) * s, cy + fy * s),
                   (cx + fx * s, cy + (fy + 5) * s)], fill=ink)
    # value + name
    big = _font(int(h * 0.26))
    small = _font(int(h * 0.075))
    for (tx, ty, anchor) in [(w * 0.13, h * 0.3, "mm"), (w * 0.87, h * 0.72, "mm")]:
        d.ellipse([tx - h * 0.17, ty - h * 0.17, tx + h * 0.17, ty + h * 0.17], fill=(30, 98, 56, 255))
        d.text((tx, ty + h * 0.01), "100", font=_font(int(h * 0.15)), fill=light, anchor=anchor)
    d.text((w * 0.5, h * 0.115), "HOTWIRE CITY", font=small, fill=ink, anchor="mm")
    d.text((w * 0.5, h * 0.885), "ONE HUNDRED HOT BUCKS", font=small, fill=ink, anchor="mm")
    d.text((w * 0.25, h * 0.72), "HC", font=big, fill=(30, 98, 56, 110), anchor="mm")
    d.text((w * 0.75, h * 0.3), "HC", font=big, fill=(30, 98, 56, 110), anchor="mm")
    img = img.resize((W, H), Image.LANCZOS)
    return img


@generator
def cash_bill():
    W = 1024
    bill = bill_image(W, W // 2)
    bill.save(os.path.join(OUT_DIR, "_bill_flat.png"))  # Blender input (not uploaded)
    # square sprite (512): the bill centered with a soft drop shadow
    S = 512
    bw, bh = int(S * 0.94), int(S * 0.47)
    small = bill.resize((bw, bh), Image.LANCZOS)
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sh = np.zeros((S, S), dtype=np.float32)
    x0, y0 = (S - bw) // 2, (S - bh) // 2
    sh[y0 + 8:y0 + bh + 8, x0 + 6:x0 + bw + 6] = 0.45
    sh = blur(sh, 6)
    shadow = Image.fromarray((np.stack([np.zeros_like(sh)] * 3 + [sh], -1) * 255).astype(np.uint8), "RGBA")
    canvas = Image.alpha_composite(canvas, shadow)
    canvas.alpha_composite(small, (x0, y0))
    arr = np.asarray(canvas, dtype=np.float32) / 255.0
    return save(arr, "cash_bill")


def main(names):
    os.makedirs(OUT_DIR, exist_ok=True)
    todo = names or list(GENERATORS)
    for nm in todo:
        if nm not in GENERATORS:
            print("unknown", nm)
            continue
        p = GENERATORS[nm]()
        print("wrote", os.path.relpath(p))


if __name__ == "__main__":
    main(sys.argv[1:])
