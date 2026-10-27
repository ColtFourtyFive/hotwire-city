#!/usr/bin/env python3
"""Render Hotwire City's stylized top-down map (GTA-V-style radar look) from tools/minimap/export.luau geometry.

    python3 tools/minimap/render_map.py <geometry.json> <outdir> [--world-min -1024] [--world-size 2048]
                                        [--px 2048] [--tiles 2] [--ss 3]

Writes into <outdir>:
    map_full.png          the whole map (px x px)
    tile_<row>_<col>.png  tiles x tiles tiles of px/tiles pixels (row 0 = north = smallest world Z)
    map_preview.png       a 1024 px preview

Image space: +X world -> right, +Z world -> down (north up). The world square [world-min, world-min + world-size] maps
onto the full image. Nothing is baked as text: district names are UI labels (Config/Minimap.DISTRICTS).

Look: deep navy land, block lots tinted per district, roads as bright lines over a darker asphalt casing (width and
brightness by class: highway > avenue > street), building footprints lit by height with soft south-east shadows,
dark-green parks with tree canopies, a soft sandy coastline with wet-sand and shallow-water glow bands over a deep
gradient ocean with faint depth contours. All drawing happens at --ss x supersampling, then downsampled (LANCZOS).
"""
import argparse, json, math, os, sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

# ---------------------------------------------------------------------------------------------------------------------
# Palette (sRGB). Tuned to sit under the Theme (deep navy panels, hot pink + cyan accents) and read on phones.
# ---------------------------------------------------------------------------------------------------------------------
P = {
    "deep": (8, 20, 38),
    "mid": (12, 38, 64),
    "shallow": (20, 78, 108),
    "shore": (64, 168, 186),
    "contour": (34, 82, 112),
    "sand": (184, 160, 112),
    "sand_dry": (198, 176, 126),
    "sand_wet": (140, 120, 86),
    "promenade": (122, 110, 104),
    "land": (22, 25, 36),
    "asphalt": (44, 48, 66),
    "sidewalk": (56, 60, 80),
    "paved": (64, 62, 74),
    "parking": (40, 44, 60),
    "stall": (58, 62, 82),
    "crosswalk": (92, 96, 120),
    "green": (30, 70, 50),
    "park": (30, 82, 54),
    "canopy": (44, 112, 66),
    "canopy_dark": (22, 62, 40),
    "pool": (40, 150, 200),
    "pier": (118, 88, 62),
    "ramp": (86, 92, 124),
    "building_lo": (56, 62, 86),
    "building_hi": (98, 106, 140),
    "garage": (86, 64, 118),
    "garage_edge": (255, 52, 140),
    "shadow": (4, 6, 14),
    "street": (128, 135, 162),
    "avenue": (170, 176, 200),
    "highway": (226, 214, 170),
    "highway_mid": (196, 150, 70),
}
ZONE = {
    "downtown": (34, 37, 54),
    "midtown": (35, 39, 55),
    "shops": (30, 44, 44),
    "suburbs": (28, 48, 40),
    "beachfront": (32, 48, 46),
    "docks": (40, 42, 50),
}
POI_LOT = {
    "SpawnPlaza": (70, 62, 66),
    "Dealership": (66, 66, 86),
    "PoliceHQ": (40, 46, 70),
    "ChopShop": (66, 52, 42),
    "StuntPark": (44, 46, 66),
    "Park": (30, 82, 54),
    "Pier": (88, 70, 54),
}
# road line widths in studs (the casing is the full asphalt width)
ROAD_LINE = {"alley": 8, "street": 12, "avenue": 16, "highway": 22}
ROAD_ORDER = ["alley", "street", "avenue", "highway"]

PAVED = {"Plaza", "FountainPlaza", "PlazaRing", "PoolDeck", "Driveway", "DrivewayRamp", "Concrete", "Path",
         "ParkPath", "GazeboFloor", "PipeDeck", "ChopFloor", "SprayFloor", "Skylight", "FloorStripe"}
GREENERY = {"Hedge", "Shrub", "Planter", "FlowerBox", "VeggieRow", "Bush"}
WATERY = {"Pool", "PoolWater", "Pond", "PoolFloor"}
PIER = {"PierDeck", "PierEnd", "PierRamp"}
RAMPS = {"MegaRamp", "LandingRamp", "LaunchRamp", "Kicker", "PipeDeck"}
SKIP = {"BaseSlab", "Lot", "Sidewalk", "Promenade", "Sand", "SandSlope", "CornerDune", "ParkingLot", "StallLine",
        "Crosswalk", "CenterDash", "EdgeLine", "BoundaryWall", "SpawnLocation", "LampBulb", "NeonEdge"}


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

    def blur(self, img, studs):
        return img.filter(ImageFilter.GaussianBlur(max(0.5, studs * self.k)))


def paint(base, color, mask, alpha=1.0):
    """Blend a solid color into base through mask (L), scaled by alpha."""
    if alpha < 1.0:
        mask = mask.point(lambda v: int(v * alpha))
    base.paste(color, (0, 0, base.width, base.height), mask)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def noise(size, cells, seed, smooth=Image.BICUBIC):
    rng = np.random.default_rng(seed)
    small = (rng.random((cells, cells)) * 255).astype(np.uint8)
    return Image.fromarray(small, "L").resize((size, size), smooth)


def render(geo, args):
    cv = Canvas(args.world_min, args.world_size, args.px, args.ss)
    W = cv.W
    cfg = geo["config"]
    water_level = cfg["waterLevel"]
    print(f"canvas {W}x{W} ({cv.k:.2f} px/stud, ss {args.ss})")

    # --- masks ----------------------------------------------------------------------------------------------------
    island = cv.mask()
    di = ImageDraw.Draw(island)
    land = cv.mask()
    dl = ImageDraw.Draw(land)
    promenade = cv.mask()
    dp = ImageDraw.Draw(promenade)
    for p in geo["parts"]:
        n = p["name"]
        if n in ("Sand", "SandSlope", "Promenade", "BaseSlab") and "hull" in p:
            if p["top"] >= water_level - 0.5:
                cv.poly(di, hull(p["hull"]))
        if n == "CornerDune" and "center" in p:
            cy, r = p["centerY"], p["radius"]
            dy = water_level - cy
            if abs(dy) < r:
                cv.circle(di, p["center"][0], p["center"][1], math.sqrt(r * r - dy * dy))
        if n == "BaseSlab" and "hull" in p:
            pass
        if n == "Promenade" and "hull" in p:
            cv.poly(dp, hull(p["hull"]))
    # land = the city slab inside the promenade: lots + roads + sidewalks
    for p in geo["parts"]:
        if p["name"] in ("Lot", "Sidewalk") and "hull" in p:
            cv.poly(dl, hull(p["hull"]))
    for r in geo["roads"]:
        ax, az = r["a"]
        bx, bz = r["b"]
        road_poly(cv, dl, ax, az, bx, bz, r["width"], r["width"] / 2)
    # soft, rounded coastline: blur + threshold the union (rounds corners, removes stair steps)
    island = cv.blur(island, 10).point(lambda v: 255 if v >= 128 else 0)
    island = cv.blur(island, 1.2)
    print("masks done")

    # --- ocean (computed at low res, upscaled) ---------------------------------------------------------------------
    lo = 512
    isl_small = np.asarray(island.resize((lo, lo), Image.BILINEAR), dtype=np.float32) / 255.0
    stud_per_lo = args.world_size / lo

    def gblur(arr, studs):
        img = Image.fromarray((np.clip(arr, 0, 1) * 255).astype(np.uint8), "L")
        img = img.filter(ImageFilter.GaussianBlur(studs / stud_per_lo))
        return np.asarray(img, dtype=np.float32) / 255.0

    near = gblur(isl_small, 40)  # shallow shelf
    far = gblur(isl_small, 180)  # deep gradient
    glow = gblur(isl_small, 10)
    n1 = np.asarray(noise(lo, 24, 7), dtype=np.float32) / 255.0
    n2 = np.asarray(noise(lo, 90, 11), dtype=np.float32) / 255.0
    depth = np.clip(far * 1.9, 0, 1)
    col = np.zeros((lo, lo, 3), np.float32)
    deep, mid, shallow, shore = (np.array(P[k], np.float32) for k in ("deep", "mid", "shallow", "shore"))
    col[:] = deep
    col += (mid - deep) * depth[..., None]
    col += (shallow - col) * np.clip(near * 1.6, 0, 1)[..., None] ** 1.4
    col += (shore - col) * (np.clip(glow * 1.8 - 0.25, 0, 1) ** 2.2)[..., None] * 0.55
    col *= (0.93 + 0.1 * n1 + 0.04 * n2)[..., None]
    # faint depth contours (two rings following the coast)
    for level, strength in ((0.30, 0.22), (0.12, 0.16), (0.05, 0.10)):
        band = np.exp(-((far - level) ** 2) / (2 * (0.008 + level * 0.02) ** 2))
        band *= (1 - np.clip(near * 3, 0, 1))
        col += (np.array(P["contour"], np.float32) - col) * (band * strength)[..., None]
    ocean = Image.fromarray(np.clip(col, 0, 255).astype(np.uint8), "RGB").resize((W, W), Image.BICUBIC)
    base = ocean
    print("ocean done")

    # --- beach ------------------------------------------------------------------------------------------------------
    sand_noise = noise(W, 160, 3).point(lambda v: int(v * 0.5))
    paint(base, P["sand"], island)
    # dry sand toward the city, wet sand at the waterline
    inner = cv.blur(island.point(lambda v: 255 if v > 250 else 0), 18)
    wet_band = Image.fromarray(
        np.clip((np.asarray(island, np.float32) - np.asarray(inner, np.float32)) * 2.2, 0, 255).astype(np.uint8), "L")
    paint(base, P["sand_wet"], wet_band, 0.75)
    paint(base, P["sand_dry"], sand_noise, 0.35)
    # shoreline foam: a thin bright line right at the edge
    edge = Image.fromarray(np.clip(255 - np.abs(np.asarray(cv.blur(island, 2.5), np.float32) - 128) * 2.0 - 40, 0, 255)
                           .astype(np.uint8), "L")
    paint(base, (210, 236, 236), edge, 0.35)
    paint(base, P["promenade"], promenade, 0.9)
    print("beach done")

    # --- city land + lots -------------------------------------------------------------------------------------------
    paint(base, P["land"], land)
    lots = {}
    for p in geo["parts"]:
        if p["name"] == "Lot" and "hull" in p:
            if p.get("plot"):
                color = ZONE.get(p.get("zone") or "", P["land"])
                color = lerp(color, P["garage"], 0.18)
            elif p.get("poi") and p["poi"] in POI_LOT:
                color = POI_LOT[p["poi"]]
            else:
                color = ZONE.get(p.get("zone") or "", P["land"])
            m = cv.mask()
            cv.poly(ImageDraw.Draw(m), hull(p["hull"]))
            paint(base, color, m)
            lots[(p.get("block") or [0, 0])[0], (p.get("block") or [0, 0])[1]] = p
    # subtle grain on land
    grain = noise(W, 400, 5).point(lambda v: max(0, v - 128) * 2)
    paint(base, (255, 255, 255), Image.fromarray(
        (np.asarray(grain, np.float32) * np.asarray(land, np.float32) / 255 * 0.05).astype(np.uint8), "L"))
    print("lots done")

    # --- ground details: sidewalks, paved areas, parking, greenery, water features ----------------------------------
    masks = {k: cv.mask() for k in ("sidewalk", "paved", "parking", "stall", "green", "pool", "pier", "ramp", "cross")}
    draws = {k: ImageDraw.Draw(v) for k, v in masks.items()}
    for p in geo["parts"]:
        n = p["name"]
        if "hull" not in p:
            continue
        h = hull(p["hull"])
        if n == "Sidewalk":
            cv.poly(draws["sidewalk"], h)
        elif n == "ParkingLot":
            cv.poly(draws["parking"], h)
        elif n == "StallLine":
            cv.poly(draws["stall"], h)
        elif n == "Crosswalk":
            cv.poly(draws["cross"], h)
        elif n in PAVED:
            cv.poly(draws["paved"], h)
        elif n in GREENERY:
            cv.poly(draws["green"], h)
        elif n in WATERY:
            if p.get("shape") == "Cylinder":
                xs = [q[0] for q in h]
                zs = [q[1] for q in h]
                x0, y0 = cv.xy(min(xs), min(zs))
                x1, y1 = cv.xy(max(xs), max(zs))
                draws["pool"].ellipse([x0, y0, x1, y1], fill=255)
            else:
                cv.poly(draws["pool"], h)
        elif n in PIER:
            cv.poly(draws["pier"], h)
        elif n in RAMPS:
            cv.poly(draws["ramp"], h)
    paint(base, P["sidewalk"], masks["sidewalk"])
    paint(base, P["paved"], masks["paved"])
    paint(base, P["parking"], masks["parking"])
    paint(base, P["stall"], masks["stall"], 0.8)
    paint(base, P["green"], masks["green"])
    paint(base, P["pier"], cv.blur(masks["pier"], 0.4))
    # pier planks: faint stripes
    paint(base, P["ramp"], masks["ramp"])
    print("ground done")

    # --- roads -------------------------------------------------------------------------------------------------------
    asphalt = cv.mask()
    da = ImageDraw.Draw(asphalt)
    for r in geo["roads"]:
        road_poly(cv, da, r["a"][0], r["a"][1], r["b"][0], r["b"][1], r["width"], r["width"] / 2)
    paint(base, P["asphalt"], asphalt)
    paint(base, P["crosswalk"], masks["cross"], 0.55)
    for cls in ROAD_ORDER:
        m = cv.mask()
        dm = ImageDraw.Draw(m)
        any_road = False
        for r in geo["roads"]:
            if r["class"] != cls:
                continue
            any_road = True
            w = ROAD_LINE.get(cls, 12)
            road_poly(cv, dm, r["a"][0], r["a"][1], r["b"][0], r["b"][1], w, w / 2)
        if not any_road:
            continue
        # soft glow under the brighter classes so the hierarchy reads at radar zoom
        if cls in ("avenue", "highway"):
            paint(base, P[cls], cv.blur(m, 6), 0.18)
        paint(base, P[cls], m)
        if cls == "highway":
            mm = cv.mask()
            dmm = ImageDraw.Draw(mm)
            for r in geo["roads"]:
                if r["class"] == cls:
                    road_poly(cv, dmm, r["a"][0], r["a"][1], r["b"][0], r["b"][1], 2.2, 1.1)
            paint(base, P["highway_mid"], mm, 0.8)
    print("roads done")

    # --- pools / ponds on top of lots ----------------------------------------------------------------------------------
    paint(base, (20, 60, 90), cv.blur(masks["pool"], 1.5), 0.6)
    paint(base, P["pool"], masks["pool"])

    # --- trees + buildings with shadows ---------------------------------------------------------------------------------
    shadow = cv.mask()
    dsh = ImageDraw.Draw(shadow)
    buildings = []  # (top height, hull, kind)
    trees = []
    for s in geo["slots"]:
        if s["category"] == "Buildings":
            for b in s["boxes"]:
                buildings.append((b["top"], hull(b["hull"]), "building"))
        else:
            role = s["role"]
            if role in ("tree", "palm_tree", "bush"):
                r = {"tree": 7.5, "palm_tree": 6.0, "bush": 3.5}[role] * max(0.6, min(1.6, (s.get("fit") or 20) / 20))
                trees.append((s["pos"][0], s["pos"][1], r, role))
            elif role in ("shipping_container", "water_tower", "ferris_wheel", "lifeguard_tower", "bus_stop",
                          "hotdog_stand", "car_crusher", "fountain"):
                for b in s["boxes"]:
                    buildings.append((min(b["top"], 14), hull(b["hull"]), "prop"))
    for g in geo["garages"]:
        buildings.append((22.6, hull(g["hull"]), "garage"))
    for p in geo["parts"]:
        n = p["name"]
        if "hull" not in p or n in SKIP or n in PAVED or n in GREENERY or n in WATERY or n in PIER or n in RAMPS:
            continue
        if n.startswith("Road_"):
            continue
        h = hull(p["hull"])
        xs = [q[0] for q in h]
        zs = [q[1] for q in h]
        w, d = max(xs) - min(xs), max(zs) - min(zs)
        height = p["top"] - max(cfg["curbTop"], p["bottom"])
        if p["top"] > 4 and min(w, d) >= 3 and w * d >= 40:
            buildings.append((min(p["top"], 30), h, "structure"))

    # shadows (south-east, length grows with height, capped)
    for top, h, kind in buildings:
        off = min(22.0, 2.0 + top * 0.12)
        cv.poly(dsh, [(x + off * 0.7, z + off) for x, z in h])
        cv.poly(dsh, h)
    for x, z, r, role in trees:
        cv.circle(dsh, x + r * 0.35, z + r * 0.5, r)
    shadow = cv.blur(shadow, 3.5)
    paint(base, P["shadow"], shadow, 0.55)

    # tree canopies
    canopy = cv.mask()
    dc = ImageDraw.Draw(canopy)
    hilite = cv.mask()
    dh = ImageDraw.Draw(hilite)
    for x, z, r, role in trees:
        cv.circle(dc, x, z, r)
        cv.circle(dh, x - r * 0.25, z - r * 0.25, r * 0.55)
    paint(base, P["canopy_dark"], canopy)
    paint(base, P["canopy"], cv.blur(hilite, 1.5), 0.85)

    # buildings: lowest first so taller ones overlap; fill by height, bright rim on the lit (north-west) edges
    buildings.sort(key=lambda b: b[0])
    max_top = max([b[0] for b in buildings] + [1])
    for top, h, kind in buildings:
        t = min(1.0, max(0.0, (top - 8) / 140.0)) ** 0.6
        if kind == "garage":
            fill = P["garage"]
        elif kind == "prop":
            fill = lerp(P["building_lo"], P["paved"], 0.4)
        elif kind == "structure":
            fill = lerp(P["building_lo"], P["land"], 0.25)
        else:
            fill = lerp(P["building_lo"], P["building_hi"], t)
        m = cv.mask()
        cv.poly(ImageDraw.Draw(m), h)
        # rim light: the polygon minus itself shifted south-east
        rim = cv.mask()
        dr = ImageDraw.Draw(rim)
        cv.poly(dr, h)
        inset = 1.6 if kind != "prop" else 0.8
        cv.poly(dr, [(x + inset, z + inset) for x, z in h], fill=0)
        paint(base, fill, m)
        paint(base, lerp(fill, (255, 255, 255), 0.22), rim)
        if kind == "garage":
            edge = cv.mask()
            de = ImageDraw.Draw(edge)
            cv.poly(de, h)
            cv.poly(de, shrink(h, 2.2), fill=0)
            paint(base, P["garage_edge"], edge, 0.55)
    print(f"buildings done ({len(buildings)} footprints, {len(trees)} trees)")

    # --- finish: downsample ----------------------------------------------------------------------------------------------
    out = base.resize((args.px, args.px), Image.LANCZOS)
    return out


def shrink(h, d):
    cx = sum(x for x, _ in h) / len(h)
    cz = sum(z for _, z in h) / len(h)
    out = []
    for x, z in h:
        vx, vz = x - cx, z - cz
        L = math.hypot(vx, vz) or 1
        out.append((x - vx / L * d * 1.4, z - vz / L * d * 1.4))
    return out


def road_poly(cv, draw, ax, az, bx, bz, width, extend):
    dx, dz = bx - ax, bz - az
    L = math.hypot(dx, dz)
    if L < 1e-6:
        return
    ux, uz = dx / L, dz / L
    nx, nz = -uz, ux
    hw = width / 2
    ax2, az2 = ax - ux * extend, az - uz * extend
    bx2, bz2 = bx + ux * extend, bz + uz * extend
    cv.poly(draw, [(ax2 + nx * hw, az2 + nz * hw), (bx2 + nx * hw, bz2 + nz * hw),
                   (bx2 - nx * hw, bz2 - nz * hw), (ax2 - nx * hw, az2 - nz * hw)])


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
