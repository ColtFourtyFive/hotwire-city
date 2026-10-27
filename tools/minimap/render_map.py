#!/usr/bin/env python3
"""Render Hotwire City v2's stylized top-down map (GTA-V pause-map look) from tools/minimap/export.luau geometry.

    python3 -I tools/minimap/render_map.py <geometry.json> <outdir> [--world-min-x -6656] [--world-min-z -6756]
                                           [--world-size 13312] [--px 4096] [--tiles 4] [--ss 2]

Writes into <outdir>:
    map_full.png          the whole map (px x px)
    tile_<row>_<col>.png  tiles x tiles tiles of px/tiles pixels (row 0 = north = smallest world Z)
    map_preview.png       a 1024 px preview

Image space: +X world -> right, +Z world -> down (north up). The world square [world-min, world-min + world-size] maps
onto the full image. No text is baked in: names are UI labels (Config/Minimap.DISTRICTS).

Look: a deep gradient ocean with a shallow-water glow at the coast; navy land with soft hillshade from the terrain
heights (the Sunwood Hills, Mount Talon and the Red Mesa buttes read as relief), faint per-district tints; lots as
building footprints lit by height with district roof hues, green parks, paved plazas and parking; roads over a darker
casing ranked by class (dim streets, bright avenues, glowing white freeways with an amber median line), decks drawn
over the streets they cross; garages in the Hotwire violet with a pink rim.
"""
import argparse
import json
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

P = {
    "deep": (9, 20, 40),
    "mid": (13, 38, 64),
    "shallow": (22, 82, 110),
    "shore": (70, 160, 176),
    "land": (23, 26, 38),
    "sand": (120, 106, 80),
    "rock": (58, 52, 50),
    "desert": (52, 42, 36),
    "paved": (44, 46, 62),
    "parking": (37, 41, 56),
    "park": (30, 74, 50),
    "garage": (66, 54, 92),
    "garage_edge": (236, 70, 150),
    "building_lo": (47, 53, 75),
    "building_hi": (90, 98, 130),
    "casing": (16, 18, 28),
    "rail": (70, 62, 58),
    "path": (60, 62, 80),
}
ZONE = {
    "downtown": (84, 70, 130),
    "midtown": (62, 82, 130),
    "beach": (58, 102, 116),
    "hills": (62, 100, 78),
    "foundry": (108, 72, 102),
    "rust": (100, 90, 78),
    "southgate": (62, 100, 78),
    "port": (100, 90, 78),
    "airport": (70, 76, 100),
    "cactus": (110, 86, 66),
    "driftwood": (58, 102, 116),
    "mesa": (110, 86, 66),
}
ROAD = {
    # class: (fill colour, casing colour)
    "freeway": ((238, 241, 250), (60, 52, 40)),
    "ramp": ((214, 218, 232), (40, 40, 52)),
    "highway": ((206, 210, 226), (30, 33, 48)),
    "boulevard": ((196, 202, 226), (24, 26, 40)),
    "avenue": ((180, 188, 216), (24, 26, 40)),
    "street": (((112, 120, 150)), (20, 22, 34)),
    "rural": ((150, 150, 166), (24, 24, 32)),
    "alley": ((74, 78, 98), (20, 22, 34)),
    "service": ((84, 88, 108), (20, 22, 34)),
    "dirt": ((110, 92, 70), (30, 26, 22)),
    "runway": ((96, 98, 116), (30, 32, 44)),
    "pier": ((120, 92, 66), (40, 30, 24)),
    "channel": ((84, 88, 108), (20, 22, 34)),
}
OPEN = {"park", "plaza", "parking_lot", "yard", "container_yard"}


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


class View:
    def __init__(self, x0, z0, size, px):
        self.x0, self.z0, self.size, self.px = x0, z0, size, px
        self.s = px / size

    def xy(self, x, z):
        return ((x - self.x0) * self.s, (z - self.z0) * self.s)


def base_layer(geo, x0, z0, size, n):
    """Ocean, land, hillshade and district tints at n x n (RGB uint8)."""
    t = geo["terrain"]
    gx0, gz0, step, nx, nz = t["x0"], t["z0"], t["step"], t["nx"], t["nz"]
    H = np.array(t["h"], np.float32).reshape(nz, nx)
    WL = np.array(t["water"], np.float32).reshape(nz, nx)
    xs = x0 + (np.arange(n) + 0.5) * size / n
    zs = z0 + (np.arange(n) + 0.5) * size / n
    fx = np.clip((xs - gx0) / step, 0, nx - 1.001)
    fz = np.clip((zs - gz0) / step, 0, nz - 1.001)
    ix, iz = np.floor(fx).astype(int), np.floor(fz).astype(int)
    tx, tz = (fx - ix)[None, :], (fz - iz)[:, None]
    h00 = H[np.ix_(iz, ix)]
    h01 = H[np.ix_(iz, ix + 1)]
    h10 = H[np.ix_(iz + 1, ix)]
    h11 = H[np.ix_(iz + 1, ix + 1)]
    h = (h00 * (1 - tx) + h01 * tx) * (1 - tz) + (h10 * (1 - tx) + h11 * tx) * tz
    # water level: the highest of the 4 surrounding samples (sea / reservoir), so the shoreline follows the smooth
    # bilinear ground instead of the 32-stud sample grid; inland carves below sea level (the trench) stay dry
    wl = np.maximum.reduce([
        WL[np.ix_(iz, ix)], WL[np.ix_(iz, ix + 1)], WL[np.ix_(iz + 1, ix)], WL[np.ix_(iz + 1, ix + 1)]])
    outside = (xs[None, :] < gx0) | (xs[None, :] > gx0 + (nx - 1) * step) | (zs[:, None] < gz0) | (
        zs[:, None] > gz0 + (nz - 1) * step)
    h = np.where(outside, -58, h)
    wl = np.where(outside, 0, wl)
    water = (wl > -9000) & (h < wl)
    # hillshade (light from the north-west)
    cell = size / n
    gz_, gx_ = np.gradient(h, cell)
    nrm = np.stack([-gx_, np.ones_like(h) * 1.0, -gz_], -1)
    nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
    light = np.array([-0.5, 0.75, -0.45])
    light /= np.linalg.norm(light)
    shade = np.clip((nrm @ light), 0, 1)
    img = np.zeros((n, n, 3), np.float32)
    land = np.array(P["land"], np.float32)
    # land: navy, lifted by relief; high ground drifts to rock, low shore to sand
    lum = 0.55 + 0.9 * shade
    img[:] = land * lum[..., None]
    hi = np.clip((h - 120) / 500, 0, 1)[..., None]
    img = img * (1 - hi) + np.array(P["rock"], np.float32) * lum[..., None] * hi
    sand = ((h < 3.5) & (h > -0.5) & ~water)[..., None]
    img = np.where(sand, np.array(P["sand"], np.float32) * (0.8 + 0.3 * shade[..., None]), img)
    # water: depth gradient with a shallow glow
    depth = np.clip((wl - h) / 50, 0, 1)
    wcol = np.array(P["shallow"], np.float32)[None, None] * (1 - depth[..., None]) + np.array(
        P["deep"], np.float32)[None, None] * depth[..., None]
    glow = np.clip(1 - (wl - h) / 4, 0, 1)[..., None] * 0.5
    wcol = wcol * (1 - glow) + np.array(P["shore"], np.float32) * glow
    img = np.where(water[..., None], wcol, img)
    out = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB")
    # district tints on land
    tint = Image.new("RGB", (n, n), (0, 0, 0))
    mask = Image.new("L", (n, n), 0)
    view = View(x0, z0, size, n)
    dt = ImageDraw.Draw(tint)
    dm = ImageDraw.Draw(mask)
    for d in geo["districts"]:
        poly = [view.xy(p[0], p[1]) for p in d["poly"]]
        col = ZONE.get(d["id"], (60, 64, 90))
        dt.polygon(poly, fill=col)
        dm.polygon(poly, fill=34)
    mask = Image.fromarray((np.array(mask) * (~water)).astype(np.uint8))
    mask = mask.filter(ImageFilter.GaussianBlur(n / 400))
    out = Image.composite(tint, out, mask)
    return out


def render(geo, a):
    S = a.px * a.ss
    view = View(a.world_min_x, a.world_min_z, a.world_size, S)
    base = base_layer(geo, a.world_min_x, a.world_min_z, a.world_size, min(a.px, 2048))
    img = base.resize((S, S), Image.BILINEAR)
    d = ImageDraw.Draw(img)
    k = view.s  # px per stud

    # lots -------------------------------------------------------------------------------------------------------
    for p in geo["parcels"]:
        poly = [view.xy(c[0], c[1]) for c in p["c"]]
        use = p["use"]
        if use == "park":
            d.polygon(poly, fill=P["park"])
        elif use in ("plaza",):
            d.polygon(poly, fill=P["paved"])
        elif use in ("parking_lot", "yard", "container_yard"):
            d.polygon(poly, fill=P["parking"])
        else:
            t = min(1.0, (p["h"] or 20) / 300)
            col = lerp(P["building_lo"], P["building_hi"], t)
            zc = ZONE.get(p["district"])
            if zc:
                col = lerp(col, zc, 0.35)
            # shadow to the south-east, then the roof inset
            sh = [(x + 3 * k, y + 3 * k) for x, y in poly]
            d.polygon(sh, fill=(8, 10, 18))
            d.polygon(poly, fill=col)
    for p in geo["pois"]:
        poly = [view.xy(c[0], c[1]) for c in p["c"]]
        d.polygon(poly, fill=P["paved"])
        cx = sum(x for x, _ in poly) / 4
        cy = sum(y for _, y in poly) / 4
        inner = [(cx + (x - cx) * 0.6, cy + (y - cy) * 0.6) for x, y in poly]
        t = min(1.0, (p["h"] or 20) / 300)
        d.polygon(inner, fill=lerp(P["building_lo"], P["building_hi"], 0.4 + 0.6 * t))
    for lm in geo["landmarks"]:
        if lm["kind"] == "park":
            d.polygon([view.xy(c[0], c[1]) for c in lm["c"]], fill=P["park"])
    for p in geo["plots"]:
        poly = [view.xy(c[0], c[1]) for c in p["c"]]
        d.polygon(poly, fill=P["garage"], outline=P["garage_edge"], width=max(2, int(3 * k)))

    # paths, rails -----------------------------------------------------------------------------------------------
    for p in geo["paths"]:
        pts = [view.xy(q[0], q[1]) for q in p["pts"]]
        if len(pts) >= 2:
            d.line(pts, fill=P["path"], width=max(1, int(p["width"] * k)), joint="curve")
    for r in geo["rails"]:
        pts = [view.xy(q[0], q[1]) for q in r["pts"]]
        if len(pts) >= 2:
            w = max(2, int((r["tracks"] * max(r["spacing"], 12)) * k))
            d.line(pts, fill=P["rail"], width=w, joint="curve")

    # roads: ground first, then decks (freeways over the streets they cross) -----------------------------------------
    def draw_roads(sel, casing):
        for r in sel:
            pts = [view.xy(q[0], q[1]) for q in r["pts"]]
            if len(pts) < 2:
                continue
            fill, case = ROAD.get(r["class"], ROAD["street"])
            w = r["width"]
            if casing:
                d.line(pts, fill=case, width=max(3, int((w + 6) * k)), joint="curve")
            else:
                lw = max(2, int(w * (0.62 if r["class"] in ("street", "alley", "service") else 0.8) * k))
                d.line(pts, fill=fill, width=lw, joint="curve")
                if r["class"] in ("freeway",) and w > 30:
                    d.line(pts, fill=(240, 176, 64), width=max(1, int(1.6 * k)), joint="curve")

    ground = [r for r in geo["roads"] if not r["elevated"]]
    decks = [r for r in geo["roads"] if r["elevated"]]
    rank = {"alley": 0, "service": 0, "dirt": 0, "runway": 1, "channel": 1, "pier": 1, "street": 2, "rural": 3,
            "avenue": 4, "boulevard": 5, "highway": 6, "ramp": 7, "freeway": 8}
    ground.sort(key=lambda r: rank.get(r["class"], 2))
    decks.sort(key=lambda r: (r["layer"], rank.get(r["class"], 2)))
    draw_roads(ground, True)
    draw_roads(ground, False)
    for layer in sorted(set(r["layer"] for r in decks)):
        sel = [r for r in decks if r["layer"] == layer]
        draw_roads(sel, True)
        draw_roads(sel, False)

    return img.resize((a.px, a.px), Image.LANCZOS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("geometry")
    ap.add_argument("outdir")
    ap.add_argument("--world-min-x", type=float, default=-6656)
    ap.add_argument("--world-min-z", type=float, default=-6756)
    ap.add_argument("--world-size", type=float, default=13312)
    ap.add_argument("--px", type=int, default=4096)
    ap.add_argument("--tiles", type=int, default=4)
    ap.add_argument("--ss", type=int, default=2)
    a = ap.parse_args()
    geo = json.load(open(a.geometry))
    os.makedirs(a.outdir, exist_ok=True)
    img = render(geo, a)
    img.save(os.path.join(a.outdir, "map_full.png"), optimize=True)
    t = a.px // a.tiles
    for r in range(a.tiles):
        for c in range(a.tiles):
            img.crop((c * t, r * t, (c + 1) * t, (r + 1) * t)).save(
                os.path.join(a.outdir, "tile_%d_%d.png" % (r, c)), optimize=True)
    img.resize((1024, 1024), Image.LANCZOS).save(os.path.join(a.outdir, "map_preview.png"))
    print("rendered %d px map, %dx%d tiles of %d px -> %s" % (a.px, a.tiles, a.tiles, t, a.outdir))


if __name__ == "__main__":
    main()
