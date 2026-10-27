#!/usr/bin/env python3
"""Generate the kit's procedural 1024px textures (numpy + PIL, no Blender needed).

    python3 -I tools/blender/buildkit/gen_textures.py

Writes tools/blender/buildkit/out/textures/:
  windows_day.png   4x4 atlas of window "interiors" (blinds, curtains, rooms, offices, shops, lobby, spandrel)
  windows_lit.png   the same 16 cells lit for night (used by the WindowsLit object)
  awnings.png       8 striped canvas bands (128 px each), tiles horizontally
  signs.png         city-wide sign trim sheet: 12 horizontal signs, 2 vertical hotel blades, helipad
  <key>_tint.png    grey "tint base" versions of stucco / painted brick / plaster (multiply by a pastel at runtime)
  atlas.json        UV rectangles of every cell (consumed by bk_arch.py)
Cells keep an 8 px edge-extended gutter so mip-mapping on Roblox does not bleed neighbours.
"""
import json, math, os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "_cache")
OUT = os.path.join(HERE, "out", "textures")
CELL, GUT, SS = 256, 8, 2           # cell size, gutter, supersampling
INNER = CELL - 2 * GUT

rng = np.random.default_rng(7)


# ----------------------------------------------------------------------------- helpers (images are HxWx3 floats, sRGB 0..1)
def smooth_noise(h, w, cells, seed):
    r = np.random.default_rng(seed).random((cells + 1, cells + 1)).astype(np.float32)
    im = Image.fromarray((r * 255).astype(np.uint8)).resize((w, h), Image.BICUBIC)
    return np.asarray(im, np.float32) / 255.0


def fill(img, x0, y0, x1, y1, col, a=1.0):
    h, w, _ = img.shape
    x0, x1 = int(max(0, x0)), int(min(w, x1))
    y0, y1 = int(max(0, y0)), int(min(h, y1))
    if x1 > x0 and y1 > y0:
        img[y0:y1, x0:x1] = img[y0:y1, x0:x1] * (1 - a) + np.asarray(col, np.float32) * a


def room(h, w, wall, ceil, floor, depth=0.22, seed=0):
    """Fake 'interior mapping' room box seen straight on: back wall + ceiling/floor/side trapezoids."""
    img = np.zeros((h, w, 3), np.float32)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    u, v = xx / w, yy / h
    bx0, bx1, by0, by1 = depth, 1 - depth, depth * 0.9, 1 - depth * 1.1
    # distance to back-wall rect in each direction decides which face we see
    left = (bx0 - u) / bx0
    right = (u - bx1) / (1 - bx1)
    top = (by0 - v) / by0
    bot = (v - by1) / (1 - by1)
    m = np.maximum.reduce([left, right, top, bot])
    img[:] = wall
    side = np.asarray(wall, np.float32) * 0.8
    img[(left == m) & (m > 0)] = side
    img[(right == m) & (m > 0)] = side * 0.9
    img[(top == m) & (m > 0)] = ceil
    img[(bot == m) & (m > 0)] = floor
    # light falloff from window towards the back
    shade = 0.75 + 0.25 * np.clip(m, 0, 1)[..., None]
    img *= shade
    img *= (0.92 + 0.16 * smooth_noise(h, w, 6, seed))[..., None]
    return img, (bx0 * w, by0 * h, bx1 * w, by1 * h)


def blinds(img, y_end, col, slat, seed=0, x0=0, x1=None, tilt=0.0):
    h, w, _ = img.shape
    x1 = w if x1 is None else x1
    y_end = int(y_end)
    yy = np.arange(y_end, dtype=np.float32)
    ph = (yy % slat) / slat
    prof = 0.78 + 0.22 * np.sin(ph * math.pi) - 0.35 * (ph > 0.88)
    prof = prof[:, None, None] * np.asarray(col, np.float32)
    n = (0.95 + 0.1 * smooth_noise(y_end, int(x1 - x0), 4, seed))[..., None]
    img[:y_end, int(x0):int(x1)] = prof * n
    fill(img, x0, y_end - slat * 0.9, x1, y_end, np.asarray(col) * 0.7)  # bottom rail


def curtain(img, x0, x1, col, folds, y0=0, y1=None, sheer=0.0, seed=0):
    h, w, _ = img.shape
    y1 = h if y1 is None else y1
    x0, x1, y0, y1 = int(x0), int(x1), int(y0), int(y1)
    if x1 <= x0:
        return
    xx = np.arange(x1 - x0, dtype=np.float32) / max(1, x1 - x0)
    ph = rng.random() * 6.28
    sh = 0.72 + 0.28 * np.cos(xx * folds * 2 * math.pi + ph) + 0.05 * np.cos(xx * folds * 5.3 * math.pi)
    yy = np.linspace(0, 1, y1 - y0, dtype=np.float32)
    vert = 1.0 - 0.15 * yy
    c = sh[None, :, None] * vert[:, None, None] * np.asarray(col, np.float32)
    region = img[y0:y1, x0:x1]
    img[y0:y1, x0:x1] = region * sheer + c * (1 - sheer)


def lamp_glow(img, cx, cy, r, col, k=1.0):
    h, w, _ = img.shape
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / r
    g = np.exp(-d * d * 2.5)[..., None] * k
    img[:] = img + g * np.asarray(col, np.float32)


def furniture(img, rect, seed, lit=False):
    """Silhouettes against the back wall: sofa/table/plant/picture/shelf."""
    r = np.random.default_rng(seed)
    bx0, by0, bx1, by1 = rect
    W, H = bx1 - bx0, by1 - by0
    dark = np.array([0.06, 0.05, 0.05]) * (3.0 if lit else 1.0)
    kind = r.integers(0, 4)
    if kind == 0:   # sofa
        fill(img, bx0 + W * 0.1, by1 - H * 0.28, bx0 + W * 0.75, by1 - H * 0.02, dark + r.random(3) * 0.06)
        fill(img, bx0 + W * 0.1, by1 - H * 0.42, bx0 + W * 0.75, by1 - H * 0.27, dark * 1.4 + r.random(3) * 0.05)
    elif kind == 1:  # shelf
        fill(img, bx0 + W * 0.55, by0 + H * 0.15, bx0 + W * 0.95, by1, dark * 1.3)
        for k in range(4):
            yb = by0 + H * (0.25 + k * 0.19)
            for j in range(5):
                c = r.random(3) * (0.35 if not lit else 0.8)
                fill(img, bx0 + W * (0.57 + j * 0.075), yb - H * 0.09, bx0 + W * (0.63 + j * 0.075), yb, c)
    elif kind == 2:  # plant
        cx, cy = bx0 + W * r.uniform(0.2, 0.8), by1 - H * 0.25
        hh, ww, _ = img.shape
        yy, xx = np.mgrid[0:hh, 0:ww].astype(np.float32)
        d = ((xx - cx) / (W * 0.18)) ** 2 + ((yy - cy) / (H * 0.3)) ** 2
        m = (d < 1) & (smooth_noise(hh, ww, 20, seed) > 0.35)
        img[m] = np.array([0.08, 0.16, 0.07]) * (2.5 if lit else 1.0)
        fill(img, cx - W * 0.05, by1 - H * 0.08, cx + W * 0.05, by1 + H * 0.05, [0.25, 0.12, 0.08])
    if r.random() < 0.6:  # picture frame on back wall
        px = bx0 + W * r.uniform(0.1, 0.6)
        fill(img, px, by0 + H * 0.15, px + W * 0.25, by0 + H * 0.38, [0.12, 0.1, 0.08])
        fill(img, px + 3 * SS, by0 + H * 0.15 + 3 * SS, px + W * 0.25 - 3 * SS, by0 + H * 0.38 - 3 * SS,
             r.random(3) * (0.35 if not lit else 0.9))


CURTAIN_COLS = [(0.78, 0.72, 0.62), (0.55, 0.16, 0.18), (0.20, 0.42, 0.45), (0.85, 0.82, 0.76),
                (0.62, 0.52, 0.30), (0.30, 0.28, 0.45), (0.80, 0.55, 0.45), (0.9, 0.9, 0.88)]


# ----------------------------------------------------------------------------- cells
def residential(kind, seed, lit):
    s = INNER * SS
    r = np.random.default_rng(seed)
    if lit:
        warm = np.array([1.0, 0.78, 0.5]) * r.uniform(0.75, 1.0)
        img, rect = room(s, s, warm * 0.85, warm * 1.05, warm * 0.55, seed=seed)
        lamp_glow(img, s * r.uniform(0.3, 0.7), s * 0.22, s * 0.35, [0.5, 0.35, 0.15])
    else:
        img, rect = room(s, s, [0.20, 0.18, 0.16], [0.30, 0.29, 0.27], [0.10, 0.08, 0.07], seed=seed)
    furniture(img, rect, seed, lit)
    cc = np.array(CURTAIN_COLS[r.integers(len(CURTAIN_COLS))])
    if lit:
        cc = np.minimum(1.0, cc * 1.25 + np.array([0.15, 0.08, 0.0]))
    if kind == 0:       # venetian blinds half down
        blinds(img, s * r.uniform(0.35, 0.7), [0.88, 0.86, 0.80] if not lit else [1.0, 0.85, 0.6], 7 * SS, seed)
    elif kind == 1:     # two curtains, gap in the middle
        g = r.uniform(0.18, 0.4)
        curtain(img, 0, s * (0.5 - g / 2), cc, 3.5, seed=seed)
        curtain(img, s * (0.5 + g / 2), s, cc, 3.5, seed=seed + 1)
        fill(img, 0, 0, s, 7 * SS, cc * 0.6)
    elif kind == 2:     # roller shade + sheer
        fill(img, 0, 0, s, s * r.uniform(0.2, 0.45), [0.86, 0.80, 0.68] if not lit else [1.0, 0.8, 0.5])
        curtain(img, 0, s, [0.92, 0.92, 0.9] if not lit else [1, 0.9, 0.75], 7, sheer=0.55, seed=seed)
    elif kind == 3:     # plain room, dark
        pass
    elif kind == 4:     # sheer fully closed
        curtain(img, 0, s, [0.92, 0.91, 0.88] if not lit else [1.0, 0.86, 0.62], 8, sheer=0.3, seed=seed)
    elif kind == 5:     # blinds fully closed
        blinds(img, s, [0.84, 0.83, 0.79] if not lit else [1.0, 0.82, 0.55], 7 * SS, seed)
    elif kind == 6:     # single side curtain
        curtain(img, s * 0.62, s, cc, 2.5, seed=seed)
    elif kind == 7:     # vertical blinds, part open
        xx = np.arange(int(s * 0.55), dtype=np.float32)
        ph = (xx % (14 * SS)) / (14 * SS)
        prof = (0.75 + 0.25 * np.sin(ph * math.pi))[None, :, None]
        col = np.array([0.85, 0.84, 0.8] if not lit else [1.0, 0.85, 0.6])
        img[:, :int(s * 0.55)] = prof * col
    return img


def office(kind, seed, lit):
    s = INNER * SS
    r = np.random.default_rng(seed)
    base = 1.0 if not lit else 2.6
    img, (bx0, by0, bx1, by1) = room(s, s, np.array([0.22, 0.23, 0.24]) * base, np.array([0.42, 0.43, 0.44]) * base,
                                     np.array([0.12, 0.12, 0.13]) * base, depth=0.3, seed=seed)
    img = np.minimum(img, 1.0)
    # fluorescent panels on the ceiling (perspective rows)
    for k in range(3):
        t = (k + 0.5) / 3
        y = by0 * t * 0.9
        half = (0.5 - (0.5 - 0.3) * (1 - t)) * s * 0.35
        for j in (-1, 0, 1):
            cx = s / 2 + j * half * 1.6
            fill(img, cx - half * 0.35, y, cx + half * 0.35, y + 6 * SS * (0.6 + t), [0.95, 0.97, 1.0])
    # cubicle partitions + monitors
    fill(img, 0, by1 - (by1 - by0) * 0.18, s, by1 + 4 * SS, np.array([0.30, 0.32, 0.34]) * min(base, 1.6))
    for j in range(r.integers(2, 5)):
        x = r.uniform(0.1, 0.85) * s
        fill(img, x, by1 - (by1 - by0) * 0.32, x + s * 0.09, by1 - (by1 - by0) * 0.2,
             [0.05, 0.05, 0.06] if not lit else [0.4, 0.6, 0.9])
    if kind == 1:
        blinds(img, s * r.uniform(0.25, 0.5), [0.8, 0.8, 0.78] if not lit else [1, 0.95, 0.85], 6 * SS, seed)
    if kind == 3:
        xx = np.arange(int(s * 0.4), dtype=np.float32)
        prof = (0.75 + 0.25 * np.sin(((xx % (14 * SS)) / (14 * SS)) * math.pi))[None, :, None]
        img[:, int(s * 0.6):int(s * 0.6) + len(xx)] = prof * np.array([0.8, 0.8, 0.78])
    return img


def shop(kind, seed, lit):
    s = INNER * SS
    r = np.random.default_rng(seed)
    k = 1.0 if not lit else 1.6
    if kind == 0:   # grocery shelves
        img, (bx0, by0, bx1, by1) = room(s, s, np.array([0.55, 0.55, 0.52]) * k, np.array([0.7, 0.7, 0.68]) * k,
                                         np.array([0.45, 0.44, 0.42]) * k, depth=0.18, seed=seed)
        for row in range(5):
            y = by0 + (by1 - by0) * (0.12 + row * 0.17)
            fill(img, bx0, y + (by1 - by0) * 0.12, bx1, y + (by1 - by0) * 0.14, [0.35, 0.35, 0.36])
            x = bx0
            while x < bx1:
                wv = r.uniform(0.025, 0.06) * s
                col = np.array([[0.85, 0.15, 0.12], [0.95, 0.75, 0.1], [0.1, 0.45, 0.8], [0.15, 0.6, 0.25],
                                [0.95, 0.95, 0.9], [0.9, 0.4, 0.1]])[r.integers(6)]
                fill(img, x, y + (by1 - by0) * r.uniform(0.02, 0.05), x + wv - SS * 2, y + (by1 - by0) * 0.12, col * 0.8 * k)
                x += wv
        for j in range(3):
            fill(img, s * (0.2 + j * 0.3), 3 * SS, s * (0.3 + j * 0.3), 7 * SS, [1, 1, 1])
    else:           # diner / cafe: booths, counter, pendant lamps
        img, (bx0, by0, bx1, by1) = room(s, s, np.array([0.55, 0.42, 0.32]) * k, np.array([0.6, 0.55, 0.5]) * k,
                                         np.array([0.3, 0.3, 0.32]) * k, depth=0.16, seed=seed)
        # checker floor band
        yy, xx = np.mgrid[0:s, 0:s]
        m = (yy > by1) & (((xx // (14 * SS)) + (yy // (10 * SS))) % 2 == 0)
        img[m] = img[m] * 0.35 + 0.6
        for j in range(3):
            x = s * (0.08 + j * 0.32)
            fill(img, x, by1 - (by1 - by0) * 0.38, x + s * 0.24, by1 + 8 * SS, [0.7, 0.08, 0.08])
            fill(img, x + s * 0.03, by1 - (by1 - by0) * 0.18, x + s * 0.21, by1 - (by1 - by0) * 0.12, [0.85, 0.85, 0.82])
            lamp_glow(img, x + s * 0.12, by0 + (by1 - by0) * 0.1, s * 0.08, [1.0, 0.75, 0.4], 0.8)
            fill(img, x + s * 0.11, 0, x + s * 0.13, by0 + (by1 - by0) * 0.08, [0.1, 0.1, 0.1])
    return np.clip(img, 0, 1)


def lobby(seed, lit):
    s = INNER * SS
    k = 1.0 if not lit else 1.5
    img, (bx0, by0, bx1, by1) = room(s, s, np.array([0.62, 0.58, 0.52]) * k, np.array([0.75, 0.74, 0.72]) * k,
                                     np.array([0.7, 0.68, 0.64]) * k, depth=0.2, seed=seed)
    fill(img, s * 0.3, by1 - (by1 - by0) * 0.25, s * 0.7, by1, [0.25, 0.18, 0.12])  # desk
    fill(img, s * 0.3, by0 + (by1 - by0) * 0.25, s * 0.7, by0 + (by1 - by0) * 0.4, [0.85, 0.7, 0.3])  # logo plate
    for j in range(4):
        lamp_glow(img, s * (0.2 + j * 0.2), by0 * 0.5, s * 0.06, [1, 0.9, 0.7], 0.9)
    return np.clip(img, 0, 1)


def spandrel(seed):
    s = INNER * SS
    img = np.zeros((s, s, 3), np.float32)
    g = np.linspace(0.0, 1.0, s, dtype=np.float32)[:, None, None]
    img[:] = np.array([0.17, 0.2, 0.23]) * (0.85 + 0.25 * g)
    img *= (0.94 + 0.12 * smooth_noise(s, s, 5, seed))[..., None]
    fill(img, 0, s * 0.48, s, s * 0.5, [0.1, 0.12, 0.14])
    return img


def to_cell(img):
    """Downsample supersampled inner image and pad with an edge-extended gutter."""
    im = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8)).resize((INNER, INNER), Image.LANCZOS)
    a = np.pad(np.asarray(im), ((GUT, GUT), (GUT, GUT), (0, 0)), mode="edge")
    return a


# 16 cells. index -> (name, painter)
CELLS = (
    [(f"res{i}", (lambda i: lambda lit, s: residential(i, 100 + i, lit))(i)) for i in range(8)]
    + [(f"office{i}", (lambda i: lambda lit, s: office(i, 200 + i, lit))(i)) for i in range(4)]
    + [("shop0", lambda lit, s: shop(0, 300, lit)), ("diner0", lambda lit, s: shop(1, 301, lit)),
       ("lobby0", lambda lit, s: lobby(400, lit)), ("spandrel", lambda lit, s: spandrel(500) * (1.0 if not lit else 1.0))]
)


def window_atlases(atlas):
    for lit in (False, True):
        sheet = np.zeros((1024, 1024, 3), np.uint8)
        for idx, (name, fn) in enumerate(CELLS):
            cx, cy = idx % 4, idx // 4
            sheet[cy * CELL:(cy + 1) * CELL, cx * CELL:(cx + 1) * CELL] = to_cell(fn(lit, idx))
            if not lit:
                # uv rect (u0, v0, u1, v1) in Blender/glTF convention (v up), inner area only
                atlas["windows"][name] = [(cx * CELL + GUT) / 1024, 1 - (cy * CELL + CELL - GUT) / 1024,
                                          (cx * CELL + CELL - GUT) / 1024, 1 - (cy * CELL + GUT) / 1024]
        Image.fromarray(sheet).save(os.path.join(OUT, "windows_lit.png" if lit else "windows_day.png"))


# ----------------------------------------------------------------------------- awnings
AWNINGS = [("red", (0.75, 0.1, 0.1), (0.95, 0.94, 0.9)), ("teal", (0.0, 0.5, 0.52), (0.95, 0.94, 0.9)),
           ("green", (0.1, 0.42, 0.22), (0.95, 0.94, 0.9)), ("navy", (0.1, 0.16, 0.38), (0.95, 0.94, 0.9)),
           ("yellow", (0.95, 0.72, 0.1), (0.95, 0.94, 0.9)), ("pink", (0.92, 0.42, 0.6), (0.97, 0.95, 0.92)),
           ("solid_red", (0.7, 0.08, 0.08), (0.7, 0.08, 0.08)), ("solid_blue", (0.05, 0.3, 0.6), (0.05, 0.3, 0.6))]


def awning_atlas(atlas):
    H = 128
    sheet = np.zeros((1024, 1024, 3), np.float32)
    weave = smooth_noise(1024, 1024, 256, 9) * 0.06 + smooth_noise(1024, 1024, 16, 10) * 0.08
    for i, (name, a, b) in enumerate(AWNINGS):
        x = np.arange(1024)
        stripe = ((x // 64) % 2 == 0)[None, :, None]
        band = np.where(stripe, np.asarray(a, np.float32), np.asarray(b, np.float32))
        band = np.repeat(band, H, axis=0)
        g = np.linspace(1.0, 0.85, H, dtype=np.float32)[:, None, None]
        sheet[i * H:(i + 1) * H] = band * g
        atlas["awnings"][name] = [0.0, 1 - ((i + 1) * H - 4) / 1024, 1.0, 1 - (i * H + 4) / 1024]
    sheet = sheet * (0.94 + weave[..., None])
    Image.fromarray((np.clip(sheet, 0, 1) * 255).astype(np.uint8)).save(os.path.join(OUT, "awnings.png"))


# ----------------------------------------------------------------------------- signs
def font(name, size):
    p = os.path.join(CACHE, "fonts", name + ".ttf")
    if not os.path.exists(p):
        p = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
    return ImageFont.truetype(p, size)


H_SIGNS = [  # text, font, fg, bg, border
    ("Sunset Diner", "Pacifico", (255, 250, 240), (196, 26, 40), (255, 210, 80)),
    ("LUCKY LIQUOR", "Bungee", (255, 214, 64), (22, 34, 80), (255, 214, 64)),
    ("PALM MART 24/7", "Righteous", (255, 255, 255), (0, 128, 128), (255, 255, 255)),
    ("OCEAN GRILL", "Limelight", (24, 40, 70), (240, 232, 214), (24, 40, 70)),
    ("NEON NOODLE", "Monoton", (255, 80, 180), (14, 10, 22), (80, 220, 255)),
    ("HOTWIRE PAWN", "Bungee", (20, 20, 20), (250, 200, 20), (20, 20, 20)),
    ("Coral Cafe", "Pacifico", (255, 255, 255), (240, 110, 100), (255, 255, 255)),
    ("FRESH CUTS", "Righteous", (230, 30, 40), (245, 245, 240), (30, 60, 160)),
    ("DONUT DASH", "Bungee", (255, 255, 255), (235, 80, 150), (120, 60, 30)),
    ("SPEEDY LAUNDRY", "Oswald", (255, 255, 255), (30, 110, 200), (255, 255, 255)),
    ("PIZZA PALACE", "Limelight", (255, 240, 200), (30, 100, 50), (200, 40, 30)),
    ("PACIFIC BANK", "Oswald", (230, 230, 225), (40, 44, 52), (200, 170, 90)),
]
V_SIGNS = [("FLAMINGO", "Limelight", (255, 120, 170), (250, 248, 240)),
           ("BREEZE", "Righteous", (0, 150, 160), (250, 248, 240))]


def draw_fit(d, box, text, fnt_name, fill, max_size):
    x0, y0, x1, y1 = box
    size = max_size
    while size > 10:
        f = font(fnt_name, size)
        l, t, r, b = d.textbbox((0, 0), text, font=f)
        if r - l <= (x1 - x0) and b - t <= (y1 - y0):
            break
        size -= 2
    l, t, r, b = d.textbbox((0, 0), text, font=f)
    d.text(((x0 + x1) / 2 - (l + r) / 2, (y0 + y1) / 2 - (t + b) / 2), text, font=f, fill=fill)


def sign_atlas(atlas):
    S = 2
    img = Image.new("RGB", (1024 * S, 1024 * S), (40, 40, 40))
    d = ImageDraw.Draw(img)
    RH = 85
    for i, (text, fn, fg, bg, bd) in enumerate(H_SIGNS):
        y0 = i * RH * S
        d.rectangle([0, y0, 768 * S, y0 + RH * S], fill=bd)
        d.rectangle([5 * S, y0 + 5 * S, 763 * S, y0 + (RH - 5) * S], fill=bg)
        d.rectangle([9 * S, y0 + 9 * S, 759 * S, y0 + (RH - 9) * S], outline=bd, width=S)
        draw_fit(d, (30 * S, y0 + 12 * S, 738 * S, y0 + (RH - 14) * S), text, fn, fg, 64 * S)
        atlas["signs"][f"h{i}"] = [0.0, 1 - (i + 1) * RH / 1024, 0.75, 1 - i * RH / 1024]
        atlas["sign_names"][f"h{i}"] = text
    for j, (text, fn, fg, bg) in enumerate(V_SIGNS):
        x0 = (768 + 128 * j) * S
        d.rectangle([x0, 0, x0 + 128 * S, 768 * S], fill=fg)
        d.rectangle([x0 + 6 * S, 6 * S, x0 + 122 * S, 762 * S], fill=bg)
        n = len(text)
        step = (740 / n)
        for k, ch in enumerate(text):
            cy = 14 + k * step
            draw_fit(d, (x0 + 14 * S, cy * S, x0 + 114 * S, (cy + step - 6) * S), ch, fn, fg, 110 * S)
        atlas["signs"][f"v{j}"] = [(768 + 128 * j) / 1024, 1 - 768 / 1024, (768 + 128 * (j + 1)) / 1024, 1.0]
        atlas["sign_names"][f"v{j}"] = text
    # helipad
    x0, y0 = 768 * S, 768 * S
    d.rectangle([x0, y0, x0 + 256 * S, y0 + 256 * S], fill=(58, 60, 62))
    c = (x0 + 128 * S, y0 + 128 * S)
    d.ellipse([c[0] - 112 * S, c[1] - 112 * S, c[0] + 112 * S, c[1] + 112 * S], outline=(245, 200, 30), width=10 * S)
    draw_fit(d, (c[0] - 60 * S, c[1] - 70 * S, c[0] + 60 * S, c[1] + 70 * S), "H", "Oswald", (245, 245, 240), 170 * S)
    d.rectangle([x0 + 3 * S, y0 + 3 * S, x0 + 253 * S, y0 + 253 * S], outline=(240, 240, 235), width=4 * S)
    atlas["signs"]["helipad"] = [768 / 1024, 0.0, 1.0, 256 / 1024]
    img = img.resize((1024, 1024), Image.LANCZOS)
    # remaining strip (rows 1020..1024 under the horizontal signs) is just border colour; fine
    img.save(os.path.join(OUT, "signs.png"))


# ----------------------------------------------------------------------------- tint bases
def tint_base(key, target=0.82, contrast=0.8):
    src = os.path.join(CACHE, "tex", key, "diff.jpg")
    a = np.asarray(Image.open(src).convert("RGB"), np.float32) / 255.0
    lum = a @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    lum = (lum - lum.mean()) * contrast + target
    lum = np.clip(lum, 0, 1)
    Image.fromarray((np.stack([lum] * 3, -1) * 255).astype(np.uint8)).save(os.path.join(OUT, f"{key}_tint.png"))


# ----------------------------------------------------------------------------- grime decals (RGBA)
def grime_atlas(atlas):
    """Dirt overlays (alpha-blended decal quads in front of walls). 4 bands of 1024x256, each tiles in u:
    base   : ground splash / rising damp (dark at the bottom, fades up)
    streak : rain streaks hanging from sills / cornices (dark at the top, fading down)
    soot   : soft roof-edge / parapet weathering
    leak   : rust drip from AC units / metal (brown streaks)"""
    H = 256
    sheet = np.zeros((1024, 1024, 4), np.float32)
    xs = np.arange(1024, dtype=np.float32)
    def tile_noise(h, cells, seed):
        n = smooth_noise(h, 1024 + 64, cells, seed)[:, :1024]
        # make it tile in u by cross-fading the ends
        k = 64
        w = np.linspace(0, 1, k, dtype=np.float32)[None, :]
        n2 = n.copy()
        n2[:, :k] = n[:, :k] * w + n[:, -k:] * (1 - w)
        return n2
    yy = np.linspace(0, 1, H, dtype=np.float32)[:, None]   # 0 = top of band image
    # base grime: alpha high at bottom (yy=1)
    n1, n2 = tile_noise(H, 24, 11), tile_noise(H, 96, 12)
    edge = 0.55 + 0.45 * tile_noise(1, 40, 13)[0][None, :]
    a = np.clip((yy - (1 - edge * 0.9)) / (edge * 0.9), 0, 1) ** 1.6
    a = a * (0.55 + 0.45 * n1) * (0.8 + 0.4 * n2)
    sheet[0:H, :, :3] = np.array([0.16, 0.14, 0.12])
    sheet[0:H, :, 3] = np.clip(a * 0.85, 0, 1)
    # streaks: dark at top, columns of varying length
    r = np.random.default_rng(21)
    cols = np.zeros(1024, np.float32)
    lens = np.zeros(1024, np.float32)
    x = 0
    while x < 1024:
        w = int(r.integers(6, 40))
        cols[x:x + w] = r.uniform(0.25, 1.0)
        lens[x:x + w] = r.uniform(0.25, 1.0)
        x += w + int(r.integers(0, 30))
    cols = np.convolve(cols, np.ones(9) / 9, mode="same")
    lens = np.convolve(lens, np.ones(9) / 9, mode="same")
    fall = np.clip(1 - yy / np.maximum(lens[None, :], 0.05), 0, 1) ** 1.3
    a = fall * cols[None, :] * (0.7 + 0.3 * tile_noise(H, 64, 22))
    a[:6] *= np.linspace(0.3, 1, 6)[:, None]
    sheet[H:2 * H, :, :3] = np.array([0.12, 0.11, 0.10])
    sheet[H:2 * H, :, 3] = np.clip(a * 0.7, 0, 1)
    # soot: broad soft darkening from the top
    n3 = tile_noise(H, 16, 31)
    a = np.clip(1 - yy * (1.2 + 0.8 * n3), 0, 1) ** 1.8 * (0.6 + 0.4 * tile_noise(H, 80, 32))
    sheet[2 * H:3 * H, :, :3] = np.array([0.10, 0.10, 0.10])
    sheet[2 * H:3 * H, :, 3] = np.clip(a * 0.6, 0, 1)
    # rust leak
    sheet[3 * H:4 * H, :, :3] = np.array([0.32, 0.17, 0.08])
    sheet[3 * H:4 * H, :, 3] = np.clip(fall * cols[None, ::-1] * 0.75, 0, 1)
    for i, k in enumerate(("base", "streak", "soot", "leak")):
        atlas["grime"][k] = [0.0, 1 - (i + 1) * H / 1024 + 2 / 1024, 1.0, 1 - i * H / 1024 - 2 / 1024]
    Image.fromarray((np.clip(sheet, 0, 1) * 255).astype(np.uint8), "RGBA").save(os.path.join(OUT, "grime.png"))


# ----------------------------------------------------------------------------- brand sheet
BLADES = [("FLAMINGO", "Limelight", (232, 96, 140), (248, 246, 238)),
          ("BREEZE", "Righteous", (0, 140, 150), (248, 246, 238)),
          ("CORONADO", "Limelight", (40, 70, 120), (246, 240, 226)),
          ("SEA SPRAY", "Righteous", (230, 120, 60), (248, 246, 238))]
WIDE = [  # 512x96 name boards: towers, warehouses, hotels, strip malls
    ("PACIFIC TRUST", "Oswald", (226, 196, 120), (24, 26, 30)),
    ("MERIDIAN", "Oswald", (235, 235, 235), (30, 34, 40)),
    ("HALCYON TOWER", "Limelight", (220, 200, 150), (36, 32, 30)),
    ("VANTAGE", "Oswald", (255, 255, 255), (12, 70, 120)),
    ("BAYVIEW LOGISTICS", "Oswald", (255, 255, 255), (20, 60, 120)),
    ("KESTREL STEEL CO.", "Oswald", (30, 30, 30), (236, 190, 40)),
    ("OCEANSIDE FREIGHT", "Oswald", (255, 255, 255), (170, 30, 30)),
    ("HOTEL CORONADO", "Limelight", (40, 70, 120), (246, 240, 226)),
    ("THE SANDPIPER", "Limelight", (230, 110, 120), (248, 246, 238)),
    ("PALM PLAZA", "Righteous", (255, 255, 255), (28, 110, 100)),
    ("QUIK STOP 24/7", "Bungee", (255, 255, 255), (200, 30, 40)),
    ("PUMP & GO", "Bungee", (255, 255, 255), (16, 70, 160)),
]


def brand_atlas(atlas):
    S = 2
    img = Image.new("RGB", (1024 * S, 1024 * S), (60, 60, 60))
    d = ImageDraw.Draw(img)
    rect = lambda x0, y0, x1, y1: [x0 / 1024, 1 - y1 / 1024, x1 / 1024, 1 - y0 / 1024]
    # vertical blades: x 0..512, y 0..768
    for j, (text, fn, fg, bg) in enumerate(BLADES):
        x0 = 128 * j * S
        d.rectangle([x0, 0, x0 + 128 * S, 768 * S], fill=fg)
        d.rectangle([x0 + 7 * S, 7 * S, x0 + 121 * S, 761 * S], fill=bg)
        t = text.replace(" ", "")
        step = 736 / len(t)
        for k, ch in enumerate(t):
            cy = 16 + k * step
            draw_fit(d, (x0 + 16 * S, cy * S, x0 + 112 * S, (cy + step - 8) * S), ch, fn, fg, 120 * S)
        atlas["brands"][f"blade{j}"] = rect(128 * j + 2, 2, 128 * (j + 1) - 2, 766)
        atlas["brand_names"][f"blade{j}"] = text
    # wide boards: x 512..1024, rows of 64 (12 rows -> y 0..768)
    for i, (text, fn, fg, bg) in enumerate(WIDE):
        y0 = i * 64 * S
        x0 = 512 * S
        d.rectangle([x0, y0, x0 + 512 * S, y0 + 64 * S], fill=bg)
        draw_fit(d, (x0 + 20 * S, y0 + 9 * S, x0 + 492 * S, y0 + 55 * S), text, fn, fg, 46 * S)
        atlas["brands"][f"wide{i}"] = rect(514, i * 64 + 2, 1022, (i + 1) * 64 - 2)
        atlas["brand_names"][f"wide{i}"] = text
    # gas price board 160x256 at (0,768)
    x0, y0 = 0, 768 * S
    d.rectangle([x0, y0, x0 + 160 * S, y0 + 256 * S], fill=(16, 70, 160))
    draw_fit(d, (x0 + 10 * S, y0 + 8 * S, x0 + 150 * S, y0 + 60 * S), "PUMP&GO", "Bungee", (255, 255, 255), 40 * S)
    for k, (lab, pr) in enumerate((("REG", "4.89"), ("PLUS", "5.09"), ("DSL", "5.39"))):
        yy = y0 + (72 + k * 60) * S
        d.rectangle([x0 + 8 * S, yy, x0 + 152 * S, yy + 52 * S], fill=(12, 12, 14))
        draw_fit(d, (x0 + 12 * S, yy + 6 * S, x0 + 56 * S, yy + 46 * S), lab, "Oswald", (255, 255, 255), 26 * S)
        draw_fit(d, (x0 + 60 * S, yy + 4 * S, x0 + 148 * S, yy + 48 * S), pr, "Oswald", (255, 60, 40), 44 * S)
    atlas["brands"]["gasprice"] = rect(2, 770, 158, 1022)
    # gas logo square 128 at (160, 768)
    x0 = 160 * S
    d.rectangle([x0, y0, x0 + 128 * S, y0 + 128 * S], fill=(16, 70, 160))
    d.ellipse([x0 + 14 * S, y0 + 14 * S, x0 + 114 * S, y0 + 114 * S], fill=(250, 200, 30))
    draw_fit(d, (x0 + 24 * S, y0 + 36 * S, x0 + 104 * S, y0 + 92 * S), "P&G", "Bungee", (16, 70, 160), 40 * S)
    atlas["brands"]["gaslogo"] = rect(162, 770, 286, 894)
    # canopy fascia stripe 288..1024 x 768..832 : brand blue with yellow + red stripes (tiles in u)
    x0, x1 = 288 * S, 1024 * S
    d.rectangle([x0, y0, x1, y0 + 64 * S], fill=(16, 70, 160))
    d.rectangle([x0, y0 + 40 * S, x1, y0 + 48 * S], fill=(250, 200, 30))
    d.rectangle([x0, y0 + 50 * S, x1, y0 + 56 * S], fill=(210, 30, 40))
    atlas["brands"]["fascia"] = rect(290, 770, 1022, 830)
    # posters 4 x (96x128) at (160+128.., 832)
    posters = [("COLD\nBEER", (200, 30, 40), (255, 255, 255)), ("LOTTO", (250, 200, 30), (20, 20, 20)),
               ("ATM", (20, 120, 60), (255, 255, 255)), ("2 FOR\n$5", (255, 255, 255), (200, 30, 40)),
               ("ICE", (30, 120, 200), (255, 255, 255)), ("OPEN", (20, 20, 20), (255, 60, 60))]
    for k, (t, bg, fg) in enumerate(posters):
        px, py = (288 + k * 120) * S, (840) * S
        d.rectangle([px, py, px + 112 * S, py + 176 * S], fill=bg)
        lines = t.split("\n")
        for li, ln in enumerate(lines):
            hh = 150 / len(lines)
            draw_fit(d, (px + 8 * S, py + (12 + li * hh) * S, px + 104 * S, py + (12 + (li + 1) * hh - 6) * S), ln, "Bungee", fg, 48 * S)
        atlas["brands"][f"poster{k}"] = rect(288 + k * 120 + 1, 841, 288 + k * 120 + 111, 1015)
    # diner roof sign 128x128 at (160, 896): "EAT"
    x0, yb = 160 * S, 896 * S
    d.rectangle([x0, yb, x0 + 128 * S, yb + 128 * S], fill=(200, 20, 30))
    draw_fit(d, (x0 + 10 * S, yb + 20 * S, x0 + 118 * S, yb + 108 * S), "EAT", "Bungee", (255, 240, 200), 70 * S)
    atlas["brands"]["eat"] = rect(162, 898, 286, 1022)
    img = img.resize((1024, 1024), Image.LANCZOS)
    img.save(os.path.join(OUT, "brands.png"))


def main():
    os.makedirs(OUT, exist_ok=True)
    atlas = {"windows": {}, "awnings": {}, "signs": {}, "sign_names": {}, "grime": {}, "brands": {}, "brand_names": {}}
    window_atlases(atlas)
    awning_atlas(atlas)
    sign_atlas(atlas)
    grime_atlas(atlas)
    brand_atlas(atlas)
    for k, tgt, c in (("stucco", 0.86, 0.9), ("brick_painted", 0.8, 0.9), ("plaster", 0.84, 0.7),
                      ("metal_siding", 0.78, 1.0), ("cmu", 0.74, 0.9), ("precast", 0.8, 0.8)):
        tint_base(k, tgt, c)
    with open(os.path.join(OUT, "atlas.json"), "w") as f:
        json.dump(atlas, f, indent=1)
    print("ok", OUT)


if __name__ == "__main__":
    main()
