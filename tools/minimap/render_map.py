#!/usr/bin/env python3
"""Render Hotwire City's stylized top-down map (GTA-V-style radar look) from tools/minimap/export.luau geometry.

    python3 -I tools/minimap/render_map.py <geometry.json> <outdir> [--world-min -1024] [--world-size 2048]
                                           [--px 2048] [--tiles 2] [--ss 3]

Writes into <outdir>:
    map_full.png          the whole map (px x px)
    tile_<row>_<col>.png  tiles x tiles tiles of px/tiles pixels (row 0 = north = smallest world Z)
    map_preview.png       a 1024 px preview

Image space: +X world -> right, +Z world -> down (north up). The world square [world-min, world-min + world-size] maps
onto the full image. Nothing is baked as text: district names are UI labels (Config/Minimap.DISTRICTS).

Look: deep navy land with per-district lot tints (violet downtown, blue midtown, plum Market Row, green suburbs,
teal beachfront, warm grey docks) that also tint the roofs, roads as lines over a darker asphalt casing ranked by width
and brightness (dim streets, bright avenues with a centre line, a glowing white ring highway with an amber median),
building footprints lit by height (rim light, roof inset, crisp south-east shadow), green parks with tree canopies, a soft rounded sandy coastline with wet sand, foam and a
shallow-water glow over a deep gradient ocean with faint depth contours. Everything is drawn at --ss x
supersampling and downsampled with LANCZOS, so edges are clean at 1 px per stud.
"""
import argparse, json, math, os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

# ---------------------------------------------------------------------------------------------------------------------
# Palette (sRGB). Sits under the game Theme (deep navy panels, hot pink + cyan accents); roads are the brightest thing
# on land so the GPS route and the street layout read at radar size on a phone.
# ---------------------------------------------------------------------------------------------------------------------
P = {
    "deep": (9, 20, 40),
    "mid": (13, 38, 64),
    "shallow": (22, 82, 110),
    "shore": (96, 196, 204),
    "contour": (44, 104, 136),
    "sand": (166, 146, 104),
    "sand_wet": (124, 108, 80),
    "foam": (222, 240, 236),
    "promenade": (92, 88, 92),
    "land": (23, 26, 38),
    "sidewalk": (34, 38, 53),
    "asphalt": (46, 50, 69),
    "paved": (44, 46, 62),
    "parking": (37, 41, 56),
    "stall": (54, 58, 77),
    "crosswalk": (98, 104, 128),
    "hedge": (30, 72, 50),
    "park": (30, 74, 50),
    "canopy": (54, 124, 74),
    "canopy_rim": (22, 60, 40),
    "palm": (78, 150, 88),
    "pool": (48, 160, 210),
    "pool_rim": (24, 70, 100),
    "pier": (112, 86, 62),
    "pier_plank": (90, 68, 50),
    "ramp": (70, 76, 104),
    "building_lo": (47, 53, 75),
    "building_hi": (76, 84, 114),
    "garage": (66, 54, 92),
    "garage_edge": (236, 70, 150),
    "shadow": (5, 7, 15),
    # road hierarchy reads by width AND brightness: dim narrow streets, bright avenues, a white ring highway with an
    # amber median and a soft glow (GTA V pause-map style)
    "street": (104, 112, 142),
    "avenue": (184, 192, 220),
    "highway": (238, 241, 250),
    "highway_mid": (240, 176, 64),
    "highway_casing": (30, 33, 48),
}
# District lot tints: distinct hues, still dark enough that every blip, the route and the roads pop over them.
ZONE = {
    "downtown": (40, 34, 66),  # violet core
    "midtown": (27, 39, 68),  # blue
    "shops": (50, 37, 50),  # plum (Market Row)
    "suburbs": (25, 52, 41),  # green
    "beachfront": (20, 52, 60),  # teal
    "docks": (48, 45, 41),  # warm industrial grey
}
# How much of the district hue rubs off on building roofs (so whole districts read at a glance, not just the lots).
ZONE_ROOF_TINT = 0.32
POI_LOT = {
    "SpawnPlaza": (62, 56, 62),
    "Dealership": (58, 58, 80),
    "PoliceHQ": (34, 42, 66),
    "ChopShop": (60, 48, 40),
    "StuntPark": (40, 42, 62),
    "Park": (30, 74, 50),
    "Pier": (80, 64, 50),
}
# road line widths in studs (the casing is the full asphalt width)
ROAD_LINE = {"alley": 7, "street": 10, "avenue": 17, "highway": 25}
ROAD_ORDER = ["alley", "street", "avenue", "highway"]

PAVED = {"Plaza", "FountainPlaza", "PlazaRing", "PoolDeck", "Driveway", "DrivewayRamp", "Concrete", "Path",
         "ParkPath", "GazeboFloor", "ChopFloor", "SprayFloor", "Skylight", "FloorStripe"}
GREENERY = {"Hedge", "Shrub", "Planter", "FlowerBox", "VeggieRow", "Bush"}
WATERY = {"Pool", "PoolWater", "Pond", "PoolFloor"}
PIER = {"PierDeck", "PierEnd", "PierRamp"}
RAMPS = {"MegaRamp", "LandingRamp", "LaunchRamp", "Kicker", "PipeDeck"}
SKIP = {"BaseSlab", "Lot", "Sidewalk", "Promenade", "Sand", "SandSlope", "CornerDune", "ParkingLot", "StallLine",
        "Crosswalk", "CenterDash", "EdgeLine", "BoundaryWall", "SpawnLocation", "LampBulb", "NeonEdge", "LightPole",
        "PylonFrame", "PylonSign", "PylonPole", "BillboardPost", "Board", "BoardLeg", "SignPost", "Billboard",
        "BillboardGlow", "Beacon", "Flag", "FlagPole", "Fence", "PicketFence", "NetPost", "Net", "PierPost",
        "PierRail", "PierLamp", "PierLampPole", "GantryLeg", "CraneCable", "CraneMagnet"}
STRUCTURE_MIN_AREA = 60


# ---------------------------------------------------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------------------------------------------------
def hull(points):
    pts = sorted(set((float(x), float(y)) for x, y in points))
    if len(pts) <= 2:
        return pts

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    lower, upper = [], []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


def clip_convex(subject, clip):
    """Sutherland-Hodgman: subject polygon clipped by a convex polygon (both CCW/CW consistent)."""
    def inside(p, a, b, sign):
        return sign * ((b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])) >= 0

    def inter(p, q, a, b):
        x1, y1, x2, y2 = p[0], p[1], q[0], q[1]
        x3, y3, x4, y4 = a[0], a[1], b[0], b[1]
        den = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
        if abs(den) < 1e-12:
            return q
        t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / den
        return (x1 + t * (x2 - x1), y1 + t * (y2 - y1))

    area = sum(clip[i][0] * clip[(i + 1) % len(clip)][1] - clip[(i + 1) % len(clip)][0] * clip[i][1]
               for i in range(len(clip)))
    sign = 1 if area > 0 else -1
    out = list(subject)
    for i in range(len(clip)):
        a, b = clip[i], clip[(i + 1) % len(clip)]
        inp, out = out, []
        if not inp:
            break
        s = inp[-1]
        for e in inp:
            if inside(e, a, b, sign):
                if not inside(s, a, b, sign):
                    out.append(inter(s, e, a, b))
                out.append(e)
            elif inside(s, a, b, sign):
                out.append(inter(s, e, a, b))
            s = e
    return out


def offset_convex(h, d):
    """Inset a convex polygon by d (studs); falls back to the centroid when it collapses."""
    n = len(h)
    if n < 3:
        return h
    area = sum(h[i][0] * h[(i + 1) % n][1] - h[(i + 1) % n][0] * h[i][1] for i in range(n))
    sign = 1 if area > 0 else -1
    lines = []
    for i in range(n):
        a, b = h[i], h[(i + 1) % n]
        dx, dz = b[0] - a[0], b[1] - a[1]
        L = math.hypot(dx, dz) or 1
        nx, nz = -dz / L * sign, dx / L * sign  # inward normal
        lines.append(((a[0] + nx * d, a[1] + nz * d), (dx, dz)))
    out = []
    for i in range(n):
        (p1, d1), (p2, d2) = lines[i - 1], lines[i]
        den = d1[0] * d2[1] - d1[1] * d2[0]
        if abs(den) < 1e-9:
            out.append(p2)
            continue
        t = ((p2[0] - p1[0]) * d2[1] - (p2[1] - p1[1]) * d2[0]) / den
        out.append((p1[0] + d1[0] * t, p1[1] + d1[1] * t))
    # collapsed? (inset larger than the polygon)
    if abs(sum(out[i][0] * out[(i + 1) % n][1] - out[(i + 1) % n][0] * out[i][1] for i in range(n))) < 1 or \
            (sum(out[i][0] * out[(i + 1) % n][1] - out[(i + 1) % n][0] * out[i][1] for i in range(n)) > 0) != (area > 0):
        return []
    return out


def bbox_size(h):
    xs = [q[0] for q in h]
    zs = [q[1] for q in h]
    return max(xs) - min(xs), max(zs) - min(zs)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def smooth_noise(size, cells, seed):
    rng = np.random.default_rng(seed)
    small = (rng.random((cells, cells)) * 255).astype(np.uint8)
    img = Image.fromarray(small, "L").resize((size, size), Image.BICUBIC)
    return img.filter(ImageFilter.GaussianBlur(size / cells * 0.6))


class Canvas:
    def __init__(self, world_min, world_size, px, ss):
        self.wmin = world_min
        self.wsize = world_size
        self.px = px
        self.ss = ss
        self.W = px * ss
        self.k = self.W / world_size  # canvas px per stud

    def xy(self, x, z):
        return ((x - self.wmin) * self.k, (z - self.wmin) * self.k)

    def mask(self):
        return Image.new("L", (self.W, self.W), 0)

    def poly(self, draw, pts, fill=255):
        if len(pts) >= 3:
            draw.polygon([self.xy(x, z) for x, z in pts], fill=fill)

    def circle(self, draw, x, z, r, fill=255):
        cx, cy = self.xy(x, z)
        rr = r * self.k
        draw.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=fill)

    def ellipse_box(self, draw, h, fill):
        xs = [q[0] for q in h]
        zs = [q[1] for q in h]
        x0, y0 = self.xy(min(xs), min(zs))
        x1, y1 = self.xy(max(xs), max(zs))
        draw.ellipse([x0, y0, x1, y1], fill=fill)

    def road(self, draw, ax, az, bx, bz, width, extend, fill):
        dx, dz = bx - ax, bz - az
        L = math.hypot(dx, dz)
        if L < 1e-6:
            return
        ux, uz = dx / L, dz / L
        nx, nz = -uz, ux
        hw = width / 2
        a2 = (ax - ux * extend, az - uz * extend)
        b2 = (bx + ux * extend, bz + uz * extend)
        self.poly(draw, [(a2[0] + nx * hw, a2[1] + nz * hw), (b2[0] + nx * hw, b2[1] + nz * hw),
                         (b2[0] - nx * hw, b2[1] - nz * hw), (a2[0] - nx * hw, a2[1] - nz * hw)], fill)

    def blur(self, img, studs):
        return img.filter(ImageFilter.GaussianBlur(max(0.5, studs * self.k)))


def paint(base, color, mask, alpha=1.0):
    """Blend a solid color into base through mask (L), scaled by alpha."""
    if alpha < 1.0:
        mask = mask.point(lambda v: int(v * alpha))
    base.paste(color, (0, 0, base.width, base.height), mask)


# ---------------------------------------------------------------------------------------------------------------------
# Coast + ocean (computed on a coarse grid, upscaled: these are smooth fields)
# ---------------------------------------------------------------------------------------------------------------------
def coast_field(geo, cv, lo):
    """Smooth island field in 0..1 at lo x lo (0.5 = waterline): union of the beach/slab parts, closed (fills the
    notches between the side slopes and the corner dunes), rounded and given a gentle wobble."""
    cfg = geo["config"]
    wl = cfg["waterLevel"]
    scale = lo / cv.wsize
    img = Image.new("L", (lo, lo), 0)
    d = ImageDraw.Draw(img)

    def to(x, z):
        return ((x - cv.wmin) * scale, (z - cv.wmin) * scale)

    for p in geo["parts"]:
        n = p["name"]
        if n in ("Sand", "SandSlope", "Promenade", "BaseSlab", "Lot", "Sidewalk") and "hull" in p:
            if p["top"] >= wl - 0.5:
                d.polygon([to(x, z) for x, z in hull(p["hull"])], fill=255)
        if n == "CornerDune" and "center" in p:
            dy = wl - p["centerY"]
            r = p["radius"]
            if abs(dy) < r:
                rr = math.sqrt(r * r - dy * dy) * scale
                cx, cy = to(*p["center"])
                d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=255)
    studs = cv.wsize / lo

    def blur(im, s):
        return im.filter(ImageFilter.GaussianBlur(s / studs))

    # closing: dilate (blur + low threshold) then erode (blur + high threshold)
    img = blur(img, 22).point(lambda v: 255 if v > 30 else 0)
    img = blur(img, 22).point(lambda v: 255 if v > 225 else 0)
    # round the corners
    f = np.asarray(blur(img, 30), np.float32) / 255.0
    wob = (np.asarray(smooth_noise(lo, 14, 21), np.float32) / 255.0 - 0.5) * 0.10
    return np.clip(f + wob * (1 - np.abs(f - 0.5) * 2) ** 0.5 * 0.6, 0, 1)


def gauss_np(arr, sigma):
    """Float gaussian blur (FFT, zero padded): uint8 blurs quantize smooth fields into visible steps."""
    h, w = arr.shape
    pad = int(sigma * 3) + 1
    big = np.zeros((h + 2 * pad, w + 2 * pad), np.float64)
    big[pad:pad + h, pad:pad + w] = arr
    fy = np.fft.fftfreq(big.shape[0])[:, None]
    fx = np.fft.fftfreq(big.shape[1])[None, :]
    kern = np.exp(-2 * (math.pi * sigma) ** 2 * (fx * fx + fy * fy))
    out = np.real(np.fft.ifft2(np.fft.fft2(big) * kern))
    return out[pad:pad + h, pad:pad + w].astype(np.float32)


def ocean_image(field, cv):
    lo = field.shape[0]
    studs = cv.wsize / lo
    isl = (field >= 0.5).astype(np.float32)

    def gblur(arr, s):
        return gauss_np(arr, s / studs)

    near = gblur(isl, 34)
    far = gblur(isl, 170)
    glow = gblur(isl, 9)
    n1 = np.asarray(smooth_noise(lo, 10, 7), np.float32) / 255.0
    col = np.zeros((lo, lo, 3), np.float32)
    deep, mid, shallow, shore = (np.array(P[k], np.float32) for k in ("deep", "mid", "shallow", "shore"))
    col[:] = deep
    col += (mid - deep) * np.clip(far * 2.1, 0, 1)[..., None] ** 0.8
    col += (shallow - col) * (np.clip(near * 1.7, 0, 1) ** 1.6)[..., None]
    col += (shore - col) * (np.clip(glow * 1.9 - 0.3, 0, 1) ** 2.4)[..., None] * 0.6
    col *= (0.95 + 0.08 * n1)[..., None]
    # crisp depth contours: lines of constant `far`, width normalized by the field gradient
    gy, gx = np.gradient(far)
    grad = np.sqrt(gx * gx + gy * gy) + 1e-6
    for level, strength in ((0.34, 0.45), (0.17, 0.32), (0.07, 0.22)):
        dist_px = np.abs(far - level) / grad
        line = np.clip(1.0 - dist_px / 0.9, 0, 1)
        line *= 1 - np.clip(near * 2.5, 0, 1)
        col += (np.array(P["contour"], np.float32) - col) * (line * strength)[..., None]
    return Image.fromarray(np.clip(col, 0, 255).astype(np.uint8), "RGB")


# ---------------------------------------------------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------------------------------------------------
def render(geo, args):
    cv = Canvas(args.world_min, args.world_size, args.px, args.ss)
    W = cv.W
    cfg = geo["config"]
    print(f"canvas {W}x{W} ({cv.k:.2f} px/stud, ss {args.ss})")

    # --- coast + ocean ---------------------------------------------------------------------------------------------
    lo = 1024
    field = coast_field(geo, cv, lo)
    base = ocean_image(field, cv).resize((W, W), Image.BICUBIC)
    big = np.asarray(Image.fromarray((field * 255).astype(np.uint8), "L").resize((W, W), Image.BICUBIC),
                     np.float32) / 255.0
    edge_w = 0.012  # field units across the anti-aliased waterline
    island = Image.fromarray((np.clip((big - 0.5) / edge_w + 0.5, 0, 1) * 255).astype(np.uint8), "L")
    wet = Image.fromarray((np.clip(1 - (big - 0.5) / 0.09, 0, 1) * np.asarray(island, np.float32)).astype(np.uint8),
                          "L")
    foam = Image.fromarray((np.clip(1 - np.abs(big - 0.5) / 0.014, 0, 1) * 255).astype(np.uint8), "L")
    del big
    print("coast + ocean done")

    # --- beach --------------------------------------------------------------------------------------------------------
    paint(base, P["sand"], island)
    paint(base, P["sand_wet"], wet, 0.7)
    paint(base, P["foam"], foam, 0.45)
    ripple = smooth_noise(W, 220, 3).point(lambda v: max(0, v - 120) * 2)
    paint(base, lerp(P["sand"], (255, 240, 200), 0.25), Image.fromarray(
        (np.asarray(ripple, np.float32) * np.asarray(island, np.float32) / 255 * 0.25).astype(np.uint8), "L"))
    draw = ImageDraw.Draw(base)
    for p in geo["parts"]:
        if p["name"] == "Promenade" and "hull" in p:
            cv.poly(draw, hull(p["hull"]), P["promenade"])
    print("beach done")

    # --- city ground: land, lots, sidewalks, paved, parking, greenery, water features, pier ----------------------------
    for p in geo["parts"]:
        if p["name"] in ("Lot", "Sidewalk") and "hull" in p:
            cv.poly(draw, hull(p["hull"]), P["land"])
    for r in geo["roads"]:
        cv.road(draw, r["a"][0], r["a"][1], r["b"][0], r["b"][1], r["width"], r["width"] / 2, P["land"])
    for p in geo["parts"]:
        if p["name"] == "Lot" and "hull" in p:
            if p.get("plot"):
                color = lerp(ZONE.get(p.get("zone") or "", P["land"]), P["garage"], 0.2)
            elif p.get("poi") and p["poi"] in POI_LOT:
                color = POI_LOT[p["poi"]]
            else:
                color = ZONE.get(p.get("zone") or "", P["land"])
            cv.poly(draw, hull(p["hull"]), color)
    order = [("Sidewalk", "sidewalk"), ("ParkingLot", "parking"), ("StallLine", "stall")]
    for name, key in order:
        for p in geo["parts"]:
            if p["name"] == name and "hull" in p:
                cv.poly(draw, hull(p["hull"]), P[key])
    for p in geo["parts"]:
        n = p["name"]
        if "hull" not in p:
            continue
        h = hull(p["hull"])
        if n in PAVED:
            cv.poly(draw, h, P["paved"])
        elif n in GREENERY:
            cv.poly(draw, h, P["hedge"])
        elif n in RAMPS:
            cv.poly(draw, h, P["ramp"])
    for p in geo["parts"]:
        n = p["name"]
        if "hull" not in p or n not in WATERY:
            continue
        h = hull(p["hull"])
        if p.get("shape") == "Cylinder":
            cv.ellipse_box(draw, h, P["pool_rim"])
            cv.ellipse_box(draw, offset_convex(h, 1.2) or h, P["pool"])
        else:
            cv.poly(draw, h, P["pool_rim"])
            cv.poly(draw, offset_convex(h, 1.0) or h, P["pool"])
    for p in geo["parts"]:
        if p["name"] in PIER and "hull" in p:
            h = hull(p["hull"])
            cv.poly(draw, h, P["pier"])
            w, d = bbox_size(h)
            xs = [q[0] for q in h]
            zs = [q[1] for q in h]
            if d > w:  # planks across the deck
                z = min(zs) + 3
                while z < max(zs) - 1:
                    cv.poly(draw, [(min(xs), z), (max(xs), z), (max(xs), z + 0.6), (min(xs), z + 0.6)], P["pier_plank"])
                    z += 3
    print("ground done")

    # --- roads ---------------------------------------------------------------------------------------------------------
    for r in geo["roads"]:
        cv.road(draw, r["a"][0], r["a"][1], r["b"][0], r["b"][1], r["width"], r["width"] / 2, P["asphalt"])
    for cls in ROAD_ORDER:
        roads = [r for r in geo["roads"] if r["class"] == cls]
        if not roads:
            continue
        w = ROAD_LINE.get(cls, 12)
        if cls in ("avenue", "highway"):
            glow = cv.mask()
            dg = ImageDraw.Draw(glow)
            spread = 10 if cls == "highway" else 4
            for r in roads:
                cv.road(dg, r["a"][0], r["a"][1], r["b"][0], r["b"][1], w + spread, w / 2 + spread / 2, 255)
            paint(base, P[cls], cv.blur(glow, spread), 0.26 if cls == "highway" else 0.16)
            draw = ImageDraw.Draw(base)
        if cls == "highway":
            # dark casing so the bright carriageway has a crisp edge even over light lots
            for r in roads:
                cv.road(draw, r["a"][0], r["a"][1], r["b"][0], r["b"][1], w + 5, w / 2 + 2.5, P["highway_casing"])
        for r in roads:
            cv.road(draw, r["a"][0], r["a"][1], r["b"][0], r["b"][1], w, w / 2, P[cls])
        if cls == "highway":
            for r in roads:
                cv.road(draw, r["a"][0], r["a"][1], r["b"][0], r["b"][1], 3.2, 1.6, P["highway_mid"])
        elif cls == "avenue":
            # thin dark centre line: avenues read as two-way boulevards, streets stay plain
            for r in roads:
                cv.road(draw, r["a"][0], r["a"][1], r["b"][0], r["b"][1], 1.4, 0.7, lerp(P["avenue"], P["asphalt"], 0.6))
    print("roads done")

    # --- footprints ------------------------------------------------------------------------------------------------------
    buildings = []  # (top, hull, kind)
    trees = []
    for s in geo["slots"]:
        if s["category"] == "Buildings":
            for b in s["boxes"]:
                buildings.append((b["top"], hull(b["hull"]), "building"))
        else:
            role = s["role"]
            fit = max(0.6, min(1.6, (s.get("fit") or 20) / 20))
            if role in ("tree", "palm_tree", "bush"):
                r = {"tree": 7.0, "palm_tree": 5.2, "bush": 3.2}[role] * fit
                trees.append((s["pos"][0], s["pos"][1], r, role))
            elif role in ("shipping_container", "water_tower", "lifeguard_tower", "bus_stop", "hotdog_stand",
                          "car_crusher", "fountain", "ferris_wheel"):
                for b in s["boxes"]:
                    buildings.append((min(b["top"], 12), hull(b["hull"]), "prop"))
    for g in geo["garages"]:
        buildings.append((22.6, hull(g["hull"]), "garage"))
    for p in geo["parts"]:
        n = p["name"]
        if "hull" not in p or n in SKIP or n in PAVED or n in GREENERY or n in WATERY or n in PIER or n in RAMPS:
            continue
        if n.startswith("Road_") or n.startswith("Dealer") or n.startswith("Leaderboard"):
            continue
        h = hull(p["hull"])
        w, d = bbox_size(h)
        if p["top"] > 4 and min(w, d) >= 4 and w * d >= STRUCTURE_MIN_AREA:
            buildings.append((min(p["top"], 30), h, "structure"))

    # crisp south-east shadows (one mask, light blur so they stay graphic)
    shadow = cv.mask()
    dsh = ImageDraw.Draw(shadow)
    for top, h, kind in buildings:
        off = min(26.0, 1.5 + top * 0.11)
        sh = [(x + off * 0.75, z + off) for x, z in h]
        cv.poly(dsh, hull(h + sh))
    for x, z, r, role in trees:
        cv.circle(dsh, x + r * 0.45, z + r * 0.6, r * 0.95)
    paint(base, P["shadow"], cv.blur(shadow, 0.9), 0.5)
    draw = ImageDraw.Draw(base)

    # tree canopies: dark rim, body, north-west highlight
    for x, z, r, role in trees:
        body = P["palm"] if role == "palm_tree" else P["canopy"]
        cv.circle(draw, x, z, r, P["canopy_rim"])
        cv.circle(draw, x, z, r - 0.9, body)
        cv.circle(draw, x - r * 0.28, z - r * 0.3, r * 0.42, lerp(body, (255, 255, 255), 0.18))

    # district of a footprint: the lot (axis-aligned box) containing its centroid
    lots = []
    for p in geo["parts"]:
        if p["name"] == "Lot" and "hull" in p and p.get("zone") in ZONE:
            xs = [q[0] for q in p["hull"]]
            zs = [q[1] for q in p["hull"]]
            lots.append((min(xs), min(zs), max(xs), max(zs), ZONE[p["zone"]]))

    def zone_tint(h):
        cx = sum(q[0] for q in h) / len(h)
        cz = sum(q[1] for q in h) / len(h)
        for x0, z0, x1, z1, col in lots:
            if x0 <= cx <= x1 and z0 <= cz <= z1:
                return col
        return None

    # buildings: lowest first, rim light on the north-west edges, roof inset
    buildings.sort(key=lambda b: b[0])
    for top, h, kind in buildings:
        t = min(1.0, max(0.0, (top - 8) / 150.0)) ** 0.6
        if kind == "garage":
            fill = P["garage"]
        elif kind == "prop":
            fill = lerp(P["building_lo"], P["paved"], 0.35)
        elif kind == "structure":
            fill = lerp(P["building_lo"], P["land"], 0.2)
        else:
            fill = lerp(P["building_lo"], P["building_hi"], t)
        if kind in ("building", "structure"):
            tint = zone_tint(h)
            if tint:
                # keep the height shading, pull the hue toward the district (brightened so roofs stay above lots)
                fill = lerp(fill, lerp(tint, (255, 255, 255), 0.22 + 0.25 * t), ZONE_ROOF_TINT)
        rim = lerp(fill, (255, 255, 255), 0.2)
        cv.poly(draw, h, rim)
        inset = 1.4 if kind != "prop" else 0.7
        body = clip_convex([(x + inset, z + inset) for x, z in h], h)
        cv.poly(draw, body, fill)
        w, d = bbox_size(h)
        if kind in ("building", "garage") and min(w, d) > 14:
            roof = offset_convex(h, 3.2)
            if roof:
                cv.poly(draw, roof, lerp(fill, P["land"], 0.18))
                roof2 = offset_convex(h, 4.0)
                if roof2:
                    cv.poly(draw, roof2, lerp(fill, (255, 255, 255), 0.04))
        if kind == "garage":
            outer = offset_convex(h, -1.2)
            if outer:
                edge = cv.mask()
                de = ImageDraw.Draw(edge)
                cv.poly(de, outer)
                cv.poly(de, h, 0)
                paint(base, P["garage_edge"], edge, 0.8)
                draw = ImageDraw.Draw(base)
    print(f"footprints done ({len(buildings)} footprints, {len(trees)} trees)")

    return base.resize((args.px, args.px), Image.LANCZOS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("geometry")
    ap.add_argument("outdir")
    ap.add_argument("--world-min", type=float, default=-1024)
    ap.add_argument("--world-size", type=float, default=2048)
    ap.add_argument("--px", type=int, default=2048)
    ap.add_argument("--tiles", type=int, default=2)
    ap.add_argument("--ss", type=int, default=3)
    args = ap.parse_args()
    geo = json.load(open(args.geometry))
    os.makedirs(args.outdir, exist_ok=True)
    img = render(geo, args)
    img.save(os.path.join(args.outdir, "map_full.png"), optimize=True)
    tile = args.px // args.tiles
    for r in range(args.tiles):
        for c in range(args.tiles):
            img.crop((c * tile, r * tile, (c + 1) * tile, (r + 1) * tile)).save(
                os.path.join(args.outdir, f"tile_{r}_{c}.png"), optimize=True)
    img.resize((1024, 1024), Image.LANCZOS).save(os.path.join(args.outdir, "map_preview.png"))
    print(f"wrote {args.outdir}: map_full.png + {args.tiles}x{args.tiles} tiles of {tile}px")


if __name__ == "__main__":
    main()
