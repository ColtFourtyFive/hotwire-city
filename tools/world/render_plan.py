#!/usr/bin/env python3
"""Render the Hotwire City v2 world plan from tools/world/export_layout.luau JSON.

    lune run tools/world/export_layout.luau build/world_layout.json
    python3 -I tools/world/render_plan.py build/world_layout.json docs/v2/world

Writes into the output directory:
    plan.png            the whole island (north up), terrain + districts + lots + roads + POIs, legend and scale bar
    plan_downtown.png   zoomed crop of the core (Pinnacle Heights + Midtown edge + the ring freeway)
    plan_gameplay.png   gameplay overlay: garages, police, hospitals, hot drops, stunt jumps, routes, travel rings

Image space: +X world -> right, +Z world -> down (north = -Z is up). Everything is drawn supersampled (--ss) and
downsampled with LANCZOS. Only Pillow + numpy are needed.
"""
import argparse
import json
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

FONT_DIRS = ["/usr/share/fonts/opentype/inter", "/usr/share/fonts/truetype/dejavu"]


def font(name, size):
    for d in FONT_DIRS:
        p = os.path.join(d, name)
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", size)


# ---------------------------------------------------------------------------------------------------------------------
# Palette
# ---------------------------------------------------------------------------------------------------------------------
OCEAN_DEEP = np.array([16, 44, 78])
OCEAN_MID = np.array([28, 86, 128])
OCEAN_SHALLOW = np.array([66, 150, 172])
SAND = np.array([226, 206, 160])
URBAN = np.array([214, 210, 200])
GRASS = np.array([142, 162, 104])
FOREST = np.array([96, 124, 78])
ROCK = np.array([164, 146, 122])
DESERT = np.array([214, 172, 118])
DESERT_DARK = np.array([186, 128, 84])

ROAD = {
    # class: (fill, casing, min px width at scale)
    "freeway": ((246, 178, 60), (120, 74, 20)),
    "ramp": ((246, 190, 92), (120, 74, 20)),
    "highway": ((252, 214, 120), (128, 96, 44)),
    "boulevard": ((255, 255, 255), (96, 96, 104)),
    "avenue": ((255, 255, 255), (110, 110, 118)),
    "street": ((246, 246, 244), (138, 138, 144)),
    "rural": ((250, 236, 200), (140, 120, 90)),
    "alley": ((232, 232, 232), (150, 150, 150)),
    "dirt": ((196, 160, 116), (130, 100, 70)),
    "pier": ((176, 132, 88), (96, 66, 40)),
    "channel": ((200, 200, 196), (120, 120, 120)),
    "runway": ((88, 90, 96), (40, 40, 44)),
    "service": ((226, 226, 222), (140, 140, 140)),
}

USE_COLOR = {
    "office_tower": (78, 98, 132),
    "residential_tower": (96, 112, 140),
    "hotel": (118, 108, 150),
    "beach_hotel": (232, 170, 150),
    "apartment": (178, 150, 132),
    "office_midrise": (132, 140, 160),
    "retail": (204, 168, 128),
    "restaurant": (206, 150, 120),
    "nightclub": (150, 90, 140),
    "parking_garage": (150, 150, 150),
    "parking_lot": (186, 186, 182),
    "plaza": (226, 220, 206),
    "park": (128, 170, 100),
    "house": (214, 160, 128),
    "duplex": (200, 150, 124),
    "corner_store": (210, 150, 100),
    "retail_strip": (204, 168, 128),
    "church": (220, 210, 190),
    "mansion": (236, 232, 222),
    "villa": (226, 220, 206),
    "loft": (170, 104, 84),
    "warehouse": (150, 140, 128),
    "brewery": (160, 110, 80),
    "gallery": (186, 132, 110),
    "factory": (124, 116, 108),
    "yard": (170, 160, 140),
    "shed": (160, 150, 136),
    "container_yard": (120, 136, 140),
    "hangar": (176, 180, 188),
    "farmhouse": (220, 196, 160),
    "barn": (168, 80, 64),
    "shop": (210, 170, 120),
    "diner": (220, 120, 100),
    "motel": (214, 150, 110),
}

POI_STYLE = {
    # kind: (glyph, color)
    "dealership": ("$", (34, 150, 230)),
    "customs": ("C", (250, 140, 20)),
    "spray": ("S", (90, 200, 90)),
    "chop": ("X", (170, 90, 40)),
    "gunshop": ("G", (220, 40, 40)),
    "bank": ("B", (240, 196, 40)),
    "bank_branch": ("b", (230, 186, 50)),
    "jewelry": ("J", (200, 80, 220)),
    "armored_depot": ("A", (100, 120, 90)),
    "convenience": ("24", (240, 110, 60)),
    "gas": ("F", (60, 170, 160)),
    "police": ("P", (40, 90, 220)),
    "hospital": ("H", (230, 50, 70)),
    "landmark": ("*", (250, 220, 60)),
    "plaza": ("*", (250, 220, 60)),
    "motel": ("M", (180, 120, 80)),
    "diner": ("D", (200, 90, 70)),
    "airport_terminal": ("T", (120, 120, 140)),
    "port_office": ("O", (60, 120, 140)),
    "gym": ("W", (220, 130, 50)),
}


class View:
    def __init__(self, minx, minz, maxx, maxz, px_per_stud, ss):
        self.minx, self.minz, self.maxx, self.maxz = minx, minz, maxx, maxz
        self.s = px_per_stud * ss
        self.ss = ss
        self.w = int(round((maxx - minx) * self.s))
        self.h = int(round((maxz - minz) * self.s))

    def p(self, x, z):
        return ((x - self.minx) * self.s, (z - self.minz) * self.s)

    def pts(self, pts):
        return [self.p(q[0], q[-1] if len(q) == 2 else q[2]) for q in pts]


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def terrain_image(data, view):
    """Hypsometric + hillshade raster resampled into the view."""
    hm = data["heightmap"]
    H = np.array(hm["rows"], dtype=np.float32)
    step = hm["step"]
    # hillshade (light from the north-west, high sun)
    gy, gx = np.gradient(H, step)
    slope = np.arctan(np.hypot(gx, gy) * 1.6)
    az = math.radians(315)
    alt = math.radians(48)
    aspect = np.arctan2(-gx, gy)
    shade = np.sin(alt) * np.cos(slope) + np.cos(alt) * np.sin(slope) * np.cos(az - aspect)
    shade = np.clip(shade, 0, 1)

    sea = data["meta"]["sea"]
    grade = data["meta"]["grade"]
    rgb = np.zeros(H.shape + (3,), dtype=np.float32)
    # water by depth
    depth = np.clip(sea - H, 0, 80)
    tdeep = smoothstep(0, 46, depth)[..., None]
    water = OCEAN_SHALLOW * (1 - tdeep) + OCEAN_DEEP * tdeep
    tmid = smoothstep(4, 18, depth)[..., None]
    water = water * 1.0 + (OCEAN_MID - water) * (tmid * (1 - tdeep)) * 0.5
    # land: base by height + x (desert east), sand near sea level
    xs = hm["minX"] + np.arange(H.shape[1]) * step
    zs = hm["minZ"] + np.arange(H.shape[0]) * step
    X, Z = np.meshgrid(xs, zs)
    hab = H - grade
    t_hill = smoothstep(8, 120, hab)[..., None]
    t_forest = smoothstep(60, 200, hab)[..., None]
    land = URBAN * (1 - t_hill) + GRASS * t_hill
    land = land * (1 - t_forest * 0.6) + FOREST * (t_forest * 0.6)
    t_desert = smoothstep(2600, 3600, X)[..., None] * (1 - smoothstep(-4300, -3900, -Z)[..., None] * 0)
    t_desert = t_desert * (1 - smoothstep(-2400, -3300, Z)[..., None] * 0.0)
    desert = DESERT * (1 - smoothstep(30, 140, hab)[..., None]) + DESERT_DARK * smoothstep(30, 140, hab)[..., None]
    land = land * (1 - t_desert) + desert * t_desert
    # foothills north of the foundry: dry grass
    t_dry = (smoothstep(1500, 2400, X) * smoothstep(-1700, -2400, Z))[..., None] * (1 - t_desert)
    land = land * (1 - t_dry * 0.7) + ROCK * (t_dry * 0.7)
    t_sand = (1 - smoothstep(1.5, 9.5, H))[..., None]
    land = land * (1 - t_sand) + SAND * t_sand
    # concrete channel / quays (very low but on land): handled by vector layers
    is_water = (H < sea)[..., None]
    rgb = np.where(is_water, water, land)
    # apply hillshade on land only (water gets a faint version)
    sh = (0.62 + 0.55 * shade)[..., None]
    rgb = np.where(is_water, rgb * (0.92 + 0.1 * shade[..., None]), rgb * sh)
    rgb = np.clip(rgb, 0, 255).astype(np.uint8)
    img = Image.fromarray(rgb, "RGB")
    # map to the view
    full_w = (hm["nx"] - 1) * step
    full_h = (hm["nz"] - 1) * step
    sx = view.s
    big = img.resize((max(1, int(full_w * sx)), max(1, int(full_h * sx))), Image.BICUBIC)
    ox = int(round((view.minx - hm["minX"]) * sx))
    oz = int(round((view.minz - hm["minZ"]) * sx))
    return big.crop((ox, oz, ox + view.w, oz + view.h))


def land_mask(data, view):
    """L-mode mask: 255 on land (heightmap above sea level), resampled into the view."""
    hm = data["heightmap"]
    H = np.array(hm["rows"], dtype=np.float32)
    m = Image.fromarray(((H > data["meta"]["sea"]) * 255).astype(np.uint8), "L")
    step = hm["step"]
    full_w = (hm["nx"] - 1) * step
    full_h = (hm["nz"] - 1) * step
    big = m.resize((max(1, int(full_w * view.s)), max(1, int(full_h * view.s))), Image.BILINEAR)
    ox = int(round((view.minx - hm["minX"]) * view.s))
    oz = int(round((view.minz - hm["minZ"]) * view.s))
    return big.crop((ox, oz, ox + view.w, oz + view.h))


def poly_draw(draw, view, pts, fill=None, outline=None, width=1):
    xy = view.pts(pts)
    if len(xy) >= 3:
        draw.polygon(xy, fill=fill, outline=outline, width=width)


def line(draw, xy, fill, width):
    if len(xy) < 2:
        return
    draw.line(xy, fill=fill, width=max(1, int(round(width))), joint="curve")
    r = width / 2
    for p in (xy[0], xy[-1]):
        draw.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=fill)


def obb_corners(f):
    cx, _, cz = f["pos"]
    sx, _, sz = f["size"]
    rx, rz = f["right"]
    lx, lz = f["look"]
    hw, hd = sx / 2, sz / 2
    return [
        (cx + rx * hw + lx * hd, cz + rz * hw + lz * hd),
        (cx - rx * hw + lx * hd, cz - rz * hw + lz * hd),
        (cx - rx * hw - lx * hd, cz - rz * hw - lz * hd),
        (cx + rx * hw - lx * hd, cz + rz * hw - lz * hd),
    ]


def draw_text(draw, xy, text, fnt, fill, stroke=(0, 0, 0), sw=2, anchor="mm", spacing=0):
    if spacing:
        # letter-spaced (manual)
        widths = [draw.textlength(ch, font=fnt) for ch in text]
        total = sum(widths) + spacing * (len(text) - 1)
        x = xy[0] - total / 2 if anchor[0] == "m" else xy[0]
        for ch, w in zip(text, widths):
            draw.text((x, xy[1]), ch, font=fnt, fill=fill, stroke_width=sw, stroke_fill=stroke, anchor="l" + anchor[1])
            x += w + spacing
    else:
        draw.text(xy, text, font=fnt, fill=fill, stroke_width=sw, stroke_fill=stroke, anchor=anchor)


def render(data, view, opts):
    ss = view.ss
    img = terrain_image(data, view).convert("RGBA")
    draw = ImageDraw.Draw(img, "RGBA")
    zoom = view.s / ss  # px per stud in the final image

    # inland water
    for w in data["water"]:
        poly_draw(draw, view, w["points"], fill=(52, 120, 160, 255))

    # districts: soft tint + dashed outline
    tint = Image.new("RGBA", img.size, (0, 0, 0, 0))
    td = ImageDraw.Draw(tint, "RGBA")
    for d in sorted(data["districts"], key=lambda d: d["priority"]):
        c = d["color"]
        poly_draw(td, view, d["polygon"], fill=(c[0], c[1], c[2], 34))
    tint.putalpha(Image.fromarray(np.minimum(np.array(tint.split()[3]), np.array(land_mask(data, view)))))
    img = Image.alpha_composite(img, tint)
    draw = ImageDraw.Draw(img, "RGBA")

    # channel concrete
    ch = data["channel"]
    chpts = view.pts(ch["points"])
    line(draw, chpts, (176, 176, 170, 255), (ch["floorHalfWidth"] + ch["wallRun"]) * 2 * view.s)
    line(draw, chpts, (196, 196, 190, 255), ch["floorHalfWidth"] * 2 * view.s)
    line(draw, chpts, (110, 150, 160, 255), 10 * view.s)

    # paths (boardwalk, park paths)
    for p in data["paths"]:
        col = (170, 128, 84, 255) if p["kind"] == "boardwalk" else (226, 214, 186, 255)
        line(draw, view.pts(p["points"]), col, max(p["width"] * view.s, 1.2 * ss))

    # parks (Echo Park), plaza, palm park strip
    # (drawn as parcels / landmarks below)

    # parcels: shadow then footprint
    shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow, "RGBA")
    parcels = data["parcels"]
    for f in parcels:
        h = f["size"][1]
        if h <= 0:
            continue
        off = min(h * 0.32, 220)  # studs of shadow toward the south-east
        corners = obb_corners(f)
        moved = [(x + off * 0.7, z + off * 0.7) for x, z in corners]
        hull = corners + moved
        # convex hull of the 8 points
        hull = convex_hull(hull)
        sd.polygon(view.pts(hull), fill=(20, 24, 36, 70))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=max(1, ss * 1.2)))
    img = Image.alpha_composite(img, shadow)
    draw = ImageDraw.Draw(img, "RGBA")

    for f in parcels:
        use = f["use"]
        base = USE_COLOR.get(use, (190, 180, 170))
        h = f["size"][1]
        if use in ("parking_lot",):
            col = (196, 196, 192, 255)
        elif use in ("plaza",):
            col = (230, 224, 210, 255)
        elif use in ("park",):
            col = (126, 176, 98, 255)
        elif use == "container_yard":
            col = (140, 150, 150, 255)
        else:
            lift = min(1.0, h / 400.0)
            col = tuple(int(c * (0.9 + 0.25 * lift)) for c in base) + (255,)
        corners = obb_corners(f)
        draw.polygon(view.pts(corners), fill=col, outline=(60, 60, 70, 160), width=max(1, ss // 2))
        if use == "container_yard" and zoom > 0.2:
            # container rows
            cx, _, cz = f["pos"]
            rx, rz = f["right"]
            lx, lz = f["look"]
            rows = max(1, int(f["size"][2] / 2 / 30))
            for k in range(-rows + 1, rows):
                a = (cx + rx * (f["size"][0] / 2 - 10) + lx * k * 30, cz + rz * (f["size"][0] / 2 - 10) + lz * k * 30)
                b = (cx - rx * (f["size"][0] / 2 - 10) + lx * k * 30, cz - rz * (f["size"][0] / 2 - 10) + lz * k * 30)
                cc = [(196, 70, 50), (40, 110, 170), (220, 160, 40), (60, 140, 90)][k % 4]
                draw.line([view.p(*a), view.p(*b)], fill=cc + (255,), width=max(1, int(14 * view.s)))
        if use in ("office_tower", "residential_tower", "hotel") and h > 250 and zoom > 0.15:
            # roof detail: inner inset
            inner = []
            cx, _, cz = f["pos"]
            for x, z in corners:
                inner.append((cx + (x - cx) * 0.62, cz + (z - cz) * 0.62))
            draw.polygon(view.pts(inner), fill=tuple(min(255, int(c * 1.12)) for c in col[:3]) + (255,))

    # POI footprints (reserved buildings)
    for p in data["pois"]:
        k = p["kind"]
        glyph, c = POI_STYLE.get(k, ("?", (200, 200, 200)))
        corners = obb_corners(p)
        if k == "plaza":
            fillc = (236, 228, 208, 255)
        else:
            fillc = tuple(int(v * 0.55 + 255 * 0.45) for v in c) + (255,)
        draw.polygon(view.pts(corners), fill=fillc, outline=tuple(int(v * 0.6) for v in c) + (255,), width=max(1, ss))
    # plots
    for p in data["plots"]:
        corners = obb_corners(p)
        draw.polygon(view.pts(corners), fill=(236, 70, 150, 255), outline=(110, 20, 70, 255), width=max(1, ss))

    # landmarks with an area footprint
    for l in data["landmarks"]:
        k = l["kind"]
        if k in ("runway",):
            corners = obb_corners(l)
            draw.polygon(view.pts(corners), fill=(70, 72, 78, 255))
        elif k in ("race_track",):
            cx, _, cz = l["pos"]
            sx, _, sz = l["size"]
            bb = [view.p(cx - sx / 2, cz - sz / 2), view.p(cx + sx / 2, cz + sz / 2)]
            draw.ellipse(bb, outline=(150, 100, 60, 255), width=max(2, int(60 * view.s)))
        elif k in ("ballpark",):
            cx, _, cz = l["pos"]
            sx, _, sz = l["size"]
            draw.rounded_rectangle([view.p(cx - sx / 2, cz - sz / 2), view.p(cx + sx / 2, cz + sz / 2)], radius=int(60 * view.s), fill=(126, 176, 98, 255))
            draw.ellipse([view.p(cx - 90, cz - 70), view.p(cx + 40, cz + 60)], fill=(64, 140, 170, 255))
        elif k in ("rail_yard",):
            cx, _, cz = l["pos"]
            sx, _, sz = l["size"]
            draw.rectangle([view.p(cx - sx / 2, cz - sz / 2), view.p(cx + sx / 2, cz + sz / 2)], fill=(150, 140, 128, 255))

    # rails
    for r in data["rails"]:
        xy = view.pts(r["points"])
        n = r.get("tracks", 1)
        for k in range(n):
            off = (k - (n - 1) / 2) * 14 * view.s
            line(draw, [(x, y + off) for x, y in xy], (90, 80, 76, 255), max(1, 3 * view.s))
        if n == 1:
            line(draw, xy, (90, 80, 76, 255), max(1.5 * ss, 6 * view.s))

    # roads: ground layer first, then elevated decks by height
    edges = data["edges"]

    def edge_w(e):
        return e["width"]

    ground = [e for e in edges if not e["elevated"] and e["layer"] <= 0]
    elevated = [e for e in edges if e["elevated"] or e["layer"] > 0]
    order = ["dirt", "service", "alley", "street", "rural", "pier", "channel", "runway", "avenue", "boulevard", "highway", "ramp", "freeway"]

    def cls_rank(e):
        return order.index(e["class"]) if e["class"] in order else 0

    def min_px(cls):
        return {"freeway": 3.2, "highway": 2.6, "boulevard": 2.2, "avenue": 2.0, "ramp": 1.4, "street": 1.2, "rural": 1.6}.get(cls, 1.0)

    # sidewalks (zoomed views)
    if zoom >= 0.35:
        for e in sorted(ground, key=cls_rank):
            if e["sidewalk"] > 0:
                line(draw, view.pts(e["points"]), (196, 194, 188, 255), (e["width"] + 2 * e["sidewalk"]) * view.s)
    for e in sorted(ground, key=cls_rank):
        fill, case = ROAD.get(e["class"], ((240, 240, 240), (120, 120, 120)))
        w = max(edge_w(e) * view.s, min_px(e["class"]) * ss)
        line(draw, view.pts(e["points"]), case + (255,), w + max(1.2 * ss, 3 * view.s))
    for e in sorted(ground, key=cls_rank):
        fill, case = ROAD.get(e["class"], ((240, 240, 240), (120, 120, 120)))
        w = max(edge_w(e) * view.s, min_px(e["class"]) * ss)
        xy = view.pts(e["points"])
        line(draw, xy, fill + (255,), w)
        if e["class"] == "runway":
            # center dashes
            draw.line(xy, fill=(240, 240, 240, 255), width=max(1, int(3 * view.s)))
        if e["bridge"]:
            line(draw, xy, (255, 255, 255, 90), w * 0.35)
        if zoom >= 0.6 and e["class"] in ("boulevard", "avenue") and e["median"] >= 8:
            line(draw, xy, (150, 186, 120, 255), e["median"] * view.s)
    # elevated: drop shadow, casing, fill (sorted by height)
    def max_y(e):
        return max(p[1] for p in e["points"])

    elevated.sort(key=max_y)
    shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(shadow, "RGBA")
    for e in elevated:
        xy = [(x + 26 * view.s, y + 26 * view.s) for x, y in view.pts(e["points"])]
        line(sdraw, xy, (10, 14, 24, 90), max(edge_w(e) * view.s, min_px(e["class"]) * ss) + 2 * ss)
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=max(1, ss * 1.5)))
    img = Image.alpha_composite(img, shadow)
    draw = ImageDraw.Draw(img, "RGBA")
    for e in elevated:
        fill, case = ROAD.get(e["class"], ((240, 240, 240), (120, 120, 120)))
        w = max(edge_w(e) * view.s, min_px(e["class"]) * ss)
        xy = view.pts(e["points"])
        line(draw, xy, case + (255,), w + max(1.4 * ss, 4 * view.s))
        line(draw, xy, fill + (255,), w)
        if zoom >= 0.5 and e["class"] == "freeway":
            # lane dashes
            draw.line(xy, fill=(255, 240, 200, 160), width=max(1, ss // 2))

    # signals (zoomed views)
    if zoom >= 0.35:
        for i in data["intersections"]:
            x, _, z = i["pos"]
            c = {"signal": (220, 40, 40), "allway": (240, 160, 30), "stop": (240, 200, 60)}.get(i["control"])
            if c:
                r = max(1.5 * ss, 5 * view.s)
                px, py = view.p(x, z)
                draw.ellipse([px - r, py - r, px + r, py + r], fill=c + (230,), outline=(40, 0, 0, 255))

    # stunt jumps, hot drops, helipads (light markers on the base plan)
    if opts.get("markers", True):
        f_small = font("Inter-Bold.otf", int(max(9, 13 * ss * opts["label_scale"])))
        for p in data["pois"]:
            glyph, c = POI_STYLE.get(p["kind"], ("?", (200, 200, 200)))
            x, _, z = p["pos"]
            px, py = view.p(x, z)
            r = 9 * ss * opts["label_scale"]
            draw.ellipse([px - r, py - r, px + r, py + r], fill=c + (255,), outline=(255, 255, 255, 255), width=max(1, ss))
            draw.text((px, py), glyph, font=f_small, fill=(255, 255, 255, 255), anchor="mm")
        for p in data["plots"]:
            x, _, z = p["pos"]
            px, py = view.p(x, z)
            r = 11 * ss * opts["label_scale"]
            draw.rounded_rectangle([px - r, py - r, px + r, py + r], radius=int(r * 0.35), fill=(236, 40, 140, 255), outline=(255, 255, 255, 255), width=max(1, ss))
            draw.text((px, py), str(p["index"]), font=f_small, fill=(255, 255, 255, 255), anchor="mm")

    return img


def convex_hull(points):
    pts = sorted(set(points))
    if len(pts) <= 2:
        return pts

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    lower = []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    upper = []
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


def label_districts(img, data, view, scale):
    draw = ImageDraw.Draw(img, "RGBA")
    ss = view.ss
    f = font("InterDisplay-Black.otf", int(34 * ss * scale))
    anchors = {
        "downtown": (180, -1060),
        "midtown": (-2350, 120),
        "beach": (-4250, -1550),
        "hills": (-3350, -2700),
        "foundry": (2700, -1350),
        "rust": (2900, 2350),
        "southgate": (-700, 2620),
        "port": (500, 4300),
        "airport": (-4100, 3020),
        "cactus": (4330, -1080),
        "mesa": (4300, 600),
    }
    for d in data["districts"]:
        a = anchors.get(d["id"])
        if not a:
            continue
        px, py = view.p(*a)
        if 0 <= px < img.width and 0 <= py < img.height:
            draw_text(draw, (px, py), d["name"].upper(), f, (255, 255, 255, 235), stroke=(30, 34, 48, 220), sw=int(3 * ss * scale), spacing=int(5 * ss * scale))
    # water labels
    fw = font("InterDisplay-SemiBoldItalic.otf", int(30 * ss * scale)) if os.path.exists("/usr/share/fonts/opentype/inter/InterDisplay-SemiBoldItalic.otf") else f
    for txt, (x, z) in (("SAPPHIRE  OCEAN", (-5900, 600)), ("IRON  BAY", (2200, 3240)), ("SAPPHIRE  OCEAN", (2600, 4800)), ("RUST  RIVER", (1985, 2160)), ("MESA  RESERVOIR", (3000, -2780))):
        px, py = view.p(x, z)
        if 0 <= px < img.width and 0 <= py < img.height:
            draw_text(draw, (px, py), txt, fw, (200, 228, 244, 220), stroke=(20, 50, 80, 160), sw=int(2 * ss * scale), spacing=int(6 * ss * scale))


def label_pois(img, data, view, scale, kinds=None, names=True):
    draw = ImageDraw.Draw(img, "RGBA")
    ss = view.ss
    f = font("Inter-SemiBold.otf", int(13 * ss * scale))
    placed = []
    for p in data["pois"]:
        if kinds and p["kind"] not in kinds:
            continue
        x, _, z = p["pos"]
        px, py = view.p(x, z)
        if not (0 <= px < img.width and 0 <= py < img.height):
            continue
        tx, ty = px + 14 * ss * scale, py
        bb = draw.textbbox((tx, ty), p["name"], font=f, anchor="lm")
        if any(not (bb[2] < q[0] or bb[0] > q[2] or bb[3] < q[1] or bb[1] > q[3]) for q in placed):
            continue
        placed.append(bb)
        draw.text((tx, ty), p["name"], font=f, fill=(20, 22, 30, 255), anchor="lm", stroke_width=int(3 * ss * scale), stroke_fill=(255, 255, 255, 220))
    for p in data["plots"]:
        x, _, z = p["pos"]
        px, py = view.p(x, z)
        if not (0 <= px < img.width and 0 <= py < img.height):
            continue
        draw.text((px + 16 * ss * scale, py + 14 * ss * scale), p["name"], font=f, fill=(170, 10, 90, 255), anchor="lm", stroke_width=int(3 * ss * scale), stroke_fill=(255, 255, 255, 230))


def label_landmarks(img, data, view, scale):
    draw = ImageDraw.Draw(img, "RGBA")
    ss = view.ss
    f = font("Inter-BoldItalic.otf", int(14 * ss * scale)) if os.path.exists("/usr/share/fonts/opentype/inter/Inter-BoldItalic.otf") else font("Inter-Bold.otf", int(14 * ss * scale))
    for l in data["landmarks"]:
        if l["kind"] in ("promenade",):
            continue
        x, _, z = l["pos"]
        px, py = view.p(x, z)
        if 0 <= px < img.width and 0 <= py < img.height:
            r = 4 * ss * scale
            draw.ellipse([px - r, py - r, px + r, py + r], fill=(250, 220, 60, 255), outline=(60, 40, 0, 255))
            draw.text((px, py - 10 * ss * scale), l["name"], font=f, fill=(70, 50, 10, 255), anchor="md", stroke_width=int(3 * ss * scale), stroke_fill=(255, 250, 230, 230))


def road_names(img, data, view, scale, classes=("freeway", "highway", "boulevard", "avenue")):
    draw = ImageDraw.Draw(img, "RGBA")
    ss = view.ss
    f = font("Inter-SemiBold.otf", int(11 * ss * scale))
    seen = {}
    for e in data["edges"]:
        if e["class"] not in classes:
            continue
        name = e["name"].split(" (")[0]
        if e["length"] < 500:
            continue
        pts = e["points"]
        mid = pts[len(pts) // 2]
        key = name
        x, z = mid[0], mid[2]
        if key in seen and any(math.hypot(x - a, z - b) < 1800 for a, b in seen[key]):
            continue
        seen.setdefault(key, []).append((x, z))
        px, py = view.p(x, z)
        if 0 <= px < img.width and 0 <= py < img.height:
            draw.text((px, py), name, font=f, fill=(40, 40, 50, 255), anchor="mm", stroke_width=int(3 * ss * scale), stroke_fill=(255, 255, 255, 235))


def legend(img, data, scale, ss, title, subtitle, px_per_stud):
    draw = ImageDraw.Draw(img, "RGBA")
    W, H = img.size
    pad = int(24 * ss * scale)
    ft = font("InterDisplay-Black.otf", int(40 * ss * scale))
    fs = font("Inter-Medium.otf", int(15 * ss * scale))
    fl = font("Inter-SemiBold.otf", int(13 * ss * scale))
    # title block
    bw = int(640 * ss * scale)
    bh = int(118 * ss * scale)
    draw.rounded_rectangle([pad, pad, pad + bw, pad + bh], radius=int(10 * ss * scale), fill=(14, 18, 28, 215))
    draw.text((pad + 22 * ss * scale, pad + 18 * ss * scale), title, font=ft, fill=(255, 255, 255, 255))
    draw.text((pad + 24 * ss * scale, pad + 72 * ss * scale), subtitle, font=fs, fill=(200, 210, 225, 255))

    # legend box (bottom-left)
    items = [
        ("road", "freeway", "Freeway (elevated ring H1, H2, H9)"),
        ("road", "highway", "Coast Highway (divided)"),
        ("road", "boulevard", "Boulevard / avenue"),
        ("road", "street", "Street"),
        ("road", "rural", "Rural / hill road"),
        ("road", "channel", "Rust River channel (drivable)"),
        ("box", (236, 70, 150), "Player garage plot (8)"),
        ("box", (78, 98, 132), "Tower lot (shadow = height)"),
        ("box", (214, 160, 128), "House / low-rise lot"),
        ("box", (186, 186, 182), "Parking lot / plaza"),
        ("dot", (220, 40, 40), "Traffic signal (zoomed plan)"),
    ]
    lh = int(22 * ss * scale)
    lw = int(390 * ss * scale)
    lx0 = pad
    ly0 = H - pad - lh * (len(items) + 1) - int(70 * ss * scale)
    draw.rounded_rectangle([lx0, ly0, lx0 + lw, H - pad], radius=int(10 * ss * scale), fill=(255, 255, 255, 225), outline=(40, 40, 50, 255))
    y = ly0 + int(14 * ss * scale)
    for kind, val, text in items:
        x = lx0 + int(16 * ss * scale)
        cy = y + lh // 2
        if kind == "road":
            fill, case = ROAD[val]
            draw.line([(x, cy), (x + 44 * ss * scale, cy)], fill=case, width=int(10 * ss * scale))
            draw.line([(x, cy), (x + 44 * ss * scale, cy)], fill=fill, width=int(6 * ss * scale))
        elif kind == "box":
            draw.rectangle([x + 10 * ss * scale, cy - 7 * ss * scale, x + 34 * ss * scale, cy + 7 * ss * scale], fill=val, outline=(60, 60, 70))
        else:
            r = 5 * ss * scale
            draw.ellipse([x + 22 * ss * scale - r, cy - r, x + 22 * ss * scale + r, cy + r], fill=val)
        draw.text((x + 58 * ss * scale, cy), text, font=fl, fill=(20, 22, 30), anchor="lm")
        y += lh
    # scale bar
    sb_studs = 2000
    sbw = sb_studs * px_per_stud * ss
    x = lx0 + int(16 * ss * scale)
    y = H - pad - int(46 * ss * scale)
    for k in range(4):
        c = (20, 22, 30) if k % 2 == 0 else (255, 255, 255)
        draw.rectangle([x + sbw * k / 4, y, x + sbw * (k + 1) / 4, y + 8 * ss * scale], fill=c, outline=(20, 22, 30))
    draw.text((x, y + 14 * ss * scale), "0", font=fl, fill=(20, 22, 30), anchor="lt")
    draw.text((x + sbw, y + 14 * ss * scale), "2,000 studs = 560 m = 20 s at 100 studs/s", font=fl, fill=(20, 22, 30), anchor="rt")
    # north arrow
    nx, ny = W - pad - 40 * ss * scale, pad + 60 * ss * scale
    r = 26 * ss * scale
    draw.polygon([(nx, ny - r), (nx - r * 0.5, ny + r * 0.6), (nx, ny + r * 0.25), (nx + r * 0.5, ny + r * 0.6)], fill=(20, 22, 30, 230), outline=(255, 255, 255))
    draw.text((nx, ny - r - 6 * ss * scale), "N", font=fs, fill=(20, 22, 30), anchor="md", stroke_width=int(2 * ss * scale), stroke_fill=(255, 255, 255))


def gameplay_overlay(img, data, view, scale):
    draw = ImageDraw.Draw(img, "RGBA")
    ss = view.ss
    f = font("Inter-Bold.otf", int(13 * ss * scale))
    # travel-time rings around Hotwire Plaza (30 s / 60 s / 90 s at 100 studs/s straight line)
    plaza = next((p for p in data["pois"] if p["id"] == "HotwirePlaza"), None)
    if plaza:
        cx, _, cz = plaza["pos"]
        for secs in (30, 60, 90):
            r = secs * 100
            a = view.p(cx - r, cz - r)
            b = view.p(cx + r, cz + r)
            draw.ellipse([a, b], outline=(255, 255, 255, 120), width=max(1, ss * 2))
            px, py = view.p(cx, cz - r)
            draw.text((px, py), f"{secs}s @100 studs/s", font=f, fill=(255, 255, 255, 230), anchor="md", stroke_width=int(2 * ss), stroke_fill=(0, 0, 0, 200))
    # routes
    colors = {"armored": (40, 200, 120), "race": (250, 120, 40)}
    for r in data["routes"]:
        c = colors.get(r["kind"], (255, 255, 255))
        xy = view.pts(r["path"])
        if len(xy) > 1:
            draw.line(xy, fill=c + (210,), width=max(2, int(6 * ss * scale)), joint="curve")
    # restricted zones
    for z in data["restricted"]:
        poly = obb_corners(z)
        xy = view.pts(poly)
        for k in range(len(xy)):
            a, b = xy[k], xy[(k + 1) % len(xy)]
            draw.line([a, b], fill=(255, 60, 60, 255), width=max(2, int(5 * ss * scale)))
    # hot drops
    for z in data["hotDrops"]:
        x, _, zz = z["pos"]
        px, py = view.p(x, zz)
        r = 16 * ss * scale
        draw.ellipse([px - r, py - r, px + r, py + r], outline=(255, 200, 0, 255), width=max(2, int(4 * ss * scale)))
        draw.text((px, py), "HD", font=f, fill=(255, 220, 40, 255), anchor="mm", stroke_width=int(2 * ss), stroke_fill=(0, 0, 0))
    # stunt jumps
    for j in data["stuntJumps"]:
        x, _, z = j["pos"]
        lx, _, lz = j["landing"]
        a, b = view.p(x, z), view.p(lx, lz)
        draw.line([a, b], fill=(0, 220, 255, 255), width=max(2, int(4 * ss * scale)))
        r = 7 * ss * scale
        draw.polygon([(a[0], a[1] - r), (a[0] - r, a[1] + r), (a[0] + r, a[1] + r)], fill=(0, 220, 255, 255))
    # police spawns
    for p in data["policeSpawns"]:
        x, _, z = p["pos"]
        px, py = view.p(x, z)
        r = 4 * ss * scale
        draw.rectangle([px - r, py - r, px + r, py + r], fill=(40, 90, 230, 255))
    # garages: big markers with on-ramp distance
    for p in data["plots"]:
        x, _, z = p["pos"]
        px, py = view.p(x, z)
        r = 18 * ss * scale
        draw.rounded_rectangle([px - r, py - r, px + r, py + r], radius=int(r * 0.3), fill=(236, 40, 140, 255), outline=(255, 255, 255), width=max(2, ss * 2))
        draw.text((px, py), str(p["index"]), font=f, fill=(255, 255, 255), anchor="mm")
        draw.text((px, py + r + 4 * ss), f"{p['name']} ({int(p['nearestOnRamp'])} to ramp)", font=f, fill=(255, 255, 255), anchor="mt", stroke_width=int(3 * ss), stroke_fill=(150, 0, 80))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("json")
    ap.add_argument("outdir")
    ap.add_argument("--ss", type=int, default=2)
    ap.add_argument("--px", type=float, default=0.25, help="px per stud for the full plan")
    ap.add_argument("--crop-px", type=float, default=0.75)
    args = ap.parse_args()
    with open(args.json) as fh:
        data = json.load(fh)
    os.makedirs(args.outdir, exist_ok=True)
    b = data["meta"]["bounds"]
    stats = data["meta"]["stats"]

    # full plan
    view = View(b["min"][0], b["min"][2], b["max"][0], b["max"][2], args.px, args.ss)
    img = render(data, view, {"label_scale": 1.0, "markers": True})
    label_districts(img, data, view, 1.0)
    road_names(img, data, view, 1.0, classes=("freeway", "highway", "boulevard"))
    label_landmarks(img, data, view, 0.9)
    legend(
        img,
        data,
        1.0,
        args.ss,
        "HOTWIRE CITY  -  V2 WORLD PLAN",
        f"{stats['edges']} road edges  |  {stats['roadLength'] / 1000:.0f}k studs of road  |  {stats['signals']} signals  |  {stats['parcels']} lots  |  {stats['pois']} POIs  |  1 stud = 0.28 m",
        args.px,
    )
    out = img.resize((img.width // args.ss, img.height // args.ss), Image.LANCZOS).convert("RGB")
    out.save(os.path.join(args.outdir, "plan.png"), optimize=True)
    print("wrote plan.png", out.size)

    # gameplay overlay
    img2 = render(data, view, {"label_scale": 1.0, "markers": False})
    dim = Image.new("RGBA", img2.size, (8, 12, 24, 110))
    img2 = Image.alpha_composite(img2, dim)
    gameplay_overlay(img2, data, view, 1.0)
    label_districts(img2, data, view, 1.0)
    legend(img2, data, 1.0, args.ss, "HOTWIRE CITY  -  GAMEPLAY LAYER", "garages (pink), police spawns (blue), hot drops (HD), stunt jumps (cyan), armored routes (green), races (orange), restricted (red)", args.px)
    out2 = img2.resize((img2.width // args.ss, img2.height // args.ss), Image.LANCZOS).convert("RGB")
    out2.save(os.path.join(args.outdir, "plan_gameplay.png"), optimize=True)
    print("wrote plan_gameplay.png", out2.size)

    # downtown crop
    cview = View(-2300, -2350, 2300, 1900, args.crop_px, args.ss)
    img3 = render(data, cview, {"label_scale": 1.0, "markers": True})
    road_names(img3, data, cview, 1.2, classes=("freeway", "highway", "boulevard", "avenue", "street"))
    label_pois(img3, data, cview, 1.2)
    label_landmarks(img3, data, cview, 1.1)
    legend(img3, data, 1.1, args.ss, "PINNACLE HEIGHTS  -  CORE", "downtown grid with one-way pairs, elevated H1 ring + trumpet interchanges, Rust River channel", args.crop_px)
    out3 = img3.resize((img3.width // args.ss, img3.height // args.ss), Image.LANCZOS).convert("RGB")
    out3.save(os.path.join(args.outdir, "plan_downtown.png"), optimize=True)
    print("wrote plan_downtown.png", out3.size)


if __name__ == "__main__":
    main()
