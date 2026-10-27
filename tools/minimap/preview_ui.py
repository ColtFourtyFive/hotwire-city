#!/usr/bin/env python3
"""Approximate previews of the radar + fullscreen map UI (PIL), using the same art and layout numbers as the game.

    python3 -I tools/minimap/preview_ui.py <outdir> [--routes routes.json]

Reads assets/minimap/map_full.png + blips.png, build/minimap/geometry.json (POIs, garages) and
src/shared/Config/Minimap.luau (radar sizes, zoom, GPS widths). Routes come from the real RoadGraph via
`lune run tools/minimap/sample_route.luau` (run automatically when --routes is not given).

Outputs (desktop at 1280x720 design scale 1, phone 844x390 at the HUD's 0.55 floor):
    radar_closeups.png          the radar in four states (on foot / driving + GPS / wanted chase / phone size)
    hud_desktop_minimap.png     desktop HUD: radar bottom-left, menu column wrapped above it, area name
    hud_phone_minimap.png       phone HUD: radar top-left under the topbar, buttons moved right, thumbstick zone
    map_fullscreen_desktop.png  fullscreen map with legend, labels, blips, GPS route + chip
    map_fullscreen_phone.png    the same on a phone
"""
import argparse, json, math, os, re, subprocess, sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ASSETS = os.path.join(ROOT, "assets", "minimap")
SS = 3

FONT_HEAVY = "/usr/share/fonts/opentype/inter/Inter-ExtraBold.otf"
FONT_BOLD = "/usr/share/fonts/opentype/inter/Inter-Bold.otf"
FONT_DISPLAY = "/usr/share/fonts/opentype/inter/InterDisplay-Bold.otf"

THEME = {
    "Background": (18, 20, 38), "Panel": (28, 31, 58), "PanelLight": (42, 46, 84), "Stroke": (10, 11, 22),
    "Text": (255, 255, 255), "TextDim": (170, 176, 214), "Primary": (255, 52, 140), "Secondary": (0, 214, 255),
    "Cash": (70, 235, 110), "Warning": (255, 190, 40), "Danger": (255, 70, 70), "Gold": (255, 205, 50),
}
WATER = (10, 24, 44)


def font(path, size):
    return ImageFont.truetype(path, max(6, int(size)))


def cfg_numbers():
    src = open(os.path.join(ROOT, "src", "shared", "Config", "Minimap.luau")).read()
    out = {}
    for k, v in re.findall(r"^\s*([A-Z_]+)\s*=\s*(-?[\d.]+),", src, re.M):
        out.setdefault(k, float(v))
    m = re.search(r"Minimap\.WORLD_MIN = Vector2\.new\((-?[\d.]+)", src)
    out["WORLD_MIN"] = float(m.group(1)) if m else -1024.0
    m = re.search(r"Minimap\.WORLD_SIZE = ([\d.]+)", src)
    out["WORLD_SIZE"] = float(m.group(1)) if m else 2048.0
    cells = {}
    for name, x, y, w, h in re.findall(r"^\s*(_?\w+) = \{ (\d+), (\d+), (\d+), (\d+) \},", src, re.M):
        cells[name] = (int(x), int(y), int(w), int(h))
    out["cells"] = cells
    return out


C = cfg_numbers()
WMIN, WSIZE = C["WORLD_MIN"], C["WORLD_SIZE"]
MAP = Image.open(os.path.join(ASSETS, "map_full.png")).convert("RGB")
MAP_K = MAP.width / WSIZE  # map px per stud
ATLAS = Image.open(os.path.join(ASSETS, "blips.png")).convert("RGBA")


def icon(name, size, tint=(255, 255, 255)):
    x, y, w, h = C["cells"][name]
    im = ATLAS.crop((x, y, x + w, y + h)).resize((max(1, int(size)), max(1, int(size))), Image.LANCZOS)
    r, g, b, a = im.split()
    r = r.point(lambda v: v * tint[0] // 255)
    g = g.point(lambda v: v * tint[1] // 255)
    b = b.point(lambda v: v * tint[2] // 255)
    return Image.merge("RGBA", (r, g, b, a))


def paste_center(dst, im, x, y, rot=0.0):
    if rot:
        im = im.rotate(-rot, resample=Image.BICUBIC, expand=True)
    dst.alpha_composite(im, (int(round(x - im.width / 2)), int(round(y - im.height / 2))))


def heading(lx, lz):
    return math.degrees(math.atan2(lx, -lz))


def rot2(x, y, deg):
    r = math.radians(deg)
    c, s = math.cos(r), math.sin(r)
    return x * c - y * s, x * s + y * c


def rounded(draw, box, r, fill=None, outline=None, width=1):
    draw.rounded_rectangle(box, radius=r, fill=fill, outline=outline, width=width)


def text_center(draw, xy, s, f, fill, stroke=2, stroke_fill=(10, 11, 22)):
    draw.text(xy, s, font=f, fill=fill, anchor="mm", stroke_width=stroke, stroke_fill=stroke_fill)


# ---------------------------------------------------------------------------------------------------------------------
# Geometry from the export
# ---------------------------------------------------------------------------------------------------------------------
GEO = json.load(open(os.path.join(ROOT, "build", "minimap", "geometry.json")))
P = GEO["pois"]
POIS = [
    ((P["Dealership"][0], P["Dealership"][1]), "car", (0, 214, 255), "Dealership"),
    ((P["GearShop"][0], P["GearShop"][1] + 30), "wrench", (255, 205, 50), "Gear Shop"),
    ((P["SprayShopA"][0], P["SprayShopA"][1] - 40), "spray", (255, 120, 200), "Spray Shop"),
    ((P["SprayShopB"][0], P["SprayShopB"][1] - 40), "spray", (255, 120, 200), None),
    ((P["ChopShop"][0], P["ChopShop"][1] + 40), "saw", (255, 140, 40), "Chop Shop"),
    ((P["PoliceHQ"][0], P["PoliceHQ"][1]), "badge", (70, 140, 255), "Police HQ"),
    ((P["SpawnPlaza"][0], P["SpawnPlaza"][1]), "star", (255, 255, 255), "Spawn Plaza"),
    ((P["StuntPark"][0], P["StuntPark"][1]), "flag", (255, 52, 140), "Stunt Park"),
    ((P["Park"][0], P["Park"][1]), "tree", (90, 220, 120), "City Park"),
    ((P["Pier"][0], P["Pier"][1]), "wheel", (120, 230, 255), "Ocean Pier"),
]
RANGE = {"star": 500, "flag": 600, "tree": 600, "wheel": 600}
GARAGES = [tuple(g["door"]) for g in GEO["garages"]]
DISTRICTS = [("DOWNTOWN", 0, -240, 1), ("MIDTOWN", -400, -400, 1), ("MARKET ROW", 240, -560, 1),
             ("PALM SUBURBS", -720, -80, 1), ("SUNSET BEACH", 720, 80, 1), ("THE DOCKS", 0, -720, 1),
             ("SOUTH SHORE", 0, 720, 1), ("STUNT PARK", 720, 640, 2), ("CITY PARK", -720, 640, 2),
             ("OCEAN PIER", 720, -910, 2), ("CHOP YARD", -720, -800, 2)]


def garage_door(i):
    # export door = the front wall; the radar uses the drive-in spot between the door and the drop-off
    return GARAGES[i]


# ---------------------------------------------------------------------------------------------------------------------
# Radar
# ---------------------------------------------------------------------------------------------------------------------
def render_radar(state, d_real, ui):
    """Radar image (RGBA, d_real + margin) mirroring MinimapController's layer stack."""
    k = SS
    D = int(round(d_real * k))
    pad = int(D * 0.2)
    W = D + pad * 2
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    cx = cy = W / 2
    border = C["BORDER"] * ui * k
    inner = D - 2 * border
    R = inner / 2
    zoom = state["zoom"]
    scale = R / zoom  # canvas px per stud
    px, pz = state["pos"]
    rot = -heading(*state["cam"])

    # shadow
    sh = Image.new("L", (W, W), 0)
    ImageDraw.Draw(sh).ellipse([cx - D / 2 + 3 * k, cy - D / 2 + 6 * k, cx + D / 2 + 3 * k, cy + D / 2 + 6 * k], fill=150)
    sh = sh.filter(ImageFilter.GaussianBlur(10 * k))
    img.paste((0, 0, 0, 255), (0, 0, W, W), sh)
    d = ImageDraw.Draw(img)
    # wanted glow ring
    flash = state.get("wanted", 0) >= 1
    ring_color = (255, 50, 60) if state.get("red", True) else (50, 110, 255)
    if flash:
        glow = Image.new("L", (W, W), 0)
        ImageDraw.Draw(glow).ellipse([cx - D * 0.58, cy - D * 0.58, cx + D * 0.58, cy + D * 0.58], outline=255,
                                     width=int(6 * k))
        glow = glow.filter(ImageFilter.GaussianBlur(7 * k))
        img.paste(ring_color + (255,), (0, 0, W, W), glow)
    # bezel
    d.ellipse([cx - D / 2, cy - D / 2, cx + D / 2, cy + D / 2], fill=THEME["Panel"] + (255,),
              outline=(ring_color if flash else THEME["Stroke"]) + (255,), width=int((4 if flash else 3) * ui * k))

    # map (affine: output px -> map px)
    r = math.radians(rot)
    cs, sn = math.cos(r), math.sin(r)
    mu, mv = (px - WMIN) * MAP_K, (pz - WMIN) * MAP_K
    f = MAP_K / scale
    size = int(inner)
    ox = oy = size / 2
    a, b = cs * f, sn * f
    c0 = mu - a * ox - b * oy
    dd, e = -sn * f, cs * f
    f0 = mv - dd * ox - e * oy
    big = MAP.transform((size, size), Image.AFFINE, (a, b, c0, dd, e, f0), resample=Image.BICUBIC, fillcolor=WATER)
    lay = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    lay.paste(big.convert("RGBA"), (0, 0))
    ld = ImageDraw.Draw(lay)

    def to_radar(wx, wz):
        x, y = rot2((wx - px) * scale, (wz - pz) * scale, rot)
        return ox + x, oy + y

    # wanted search area
    if flash and state.get("seen"):
        sx, sz = state["seen"]
        rad = (70 + 25 * (min(state["wanted"], 5) - 1)) * scale
        u, v = to_radar(sx, sz)
        area = Image.new("L", (size, size), 0)
        ImageDraw.Draw(area).ellipse([u - rad, v - rad, u + rad, v + rad], fill=110)
        area = area.filter(ImageFilter.GaussianBlur(rad * 0.25))
        lay.paste(ring_color + (255,), (0, 0, size, size), area)
        ld.ellipse([u - rad, v - rad, u + rad, v + rad], outline=ring_color + (230,), width=int(2.5 * k))
    # GPS route
    route = state.get("route")
    if route:
        pts = [to_radar(x, z) for x, z in route]
        w = C["WIDTH"] * ui * k
        o = C["OUTLINE"] * ui * k
        ld.line(pts, fill=(10, 12, 24, 230), width=int(w + 2 * o), joint="curve")
        for p in pts:
            ld.ellipse([p[0] - (w / 2 + o), p[1] - (w / 2 + o), p[0] + (w / 2 + o), p[1] + (w / 2 + o)],
                       fill=(10, 12, 24, 230))
        col = state["route_color"]
        ld.line(pts, fill=col + (255,), width=int(w), joint="curve")
        for p in pts:
            ld.ellipse([p[0] - w / 2, p[1] - w / 2, p[0] + w / 2, p[1] + w / 2], fill=col + (255,))
        if state.get("target"):
            t = to_radar(*state["target"])
            ld.line([pts[-1], t], fill=col + (150,), width=int(w))

    # blips
    blip = C["BLIP_SIZE"] * ui * k
    small = C["BLIP_SIZE_SMALL"] * ui * k
    edge = R - C["EDGE_INSET"] * ui * k

    def put(wx, wz, name, color, sz, sticky=False, rng=None):
        dx, dz = wx - px, wz - pz
        if rng and dx * dx + dz * dz > rng * rng:
            return
        x, y = rot2(dx * scale, dz * scale, rot)
        dist = math.hypot(x, y)
        if dist > edge:
            if not sticky:
                return
            x, y = x / dist * edge, y / dist * edge
        paste_center(lay, icon(name, sz, color), ox + x, oy + y)

    for (wx, wz), name, color, _ in POIS:
        put(wx, wz, name, color, blip, False, RANGE.get(name))
    for i, (wx, wz) in enumerate(GARAGES):
        if i == state.get("own_garage"):
            put(wx, wz, "garage", (70, 235, 110), blip + 2 * ui * k, True)
        elif i in state.get("rival_garages", ()):
            put(wx, wz, "garage", (150, 156, 190), blip - 4 * ui * k)
    for (wx, wz), red in state.get("police", []):
        put(wx, wz, "dot", (255, 60, 60) if red else (60, 120, 255), small + 2 * ui * k)
    for (wx, wz), name, color in state.get("waypoints", []):
        put(wx, wz, name, color, blip + 2 * ui * k, True)

    # clip to circle + vignette
    vx, vy, vw, vh = C["cells"]["_vignette"]
    vig = ATLAS.crop((vx, vy, vx + vw, vy + vh)).resize((size, size), Image.LANCZOS)
    lay.alpha_composite(vig)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, size - 1, size - 1], fill=255)
    img.paste(lay, (int(cx - size / 2), int(cy - size / 2)), mask)
    d = ImageDraw.Draw(img)
    d.ellipse([cx - R, cy - R, cx + R, cy + R], outline=(255, 255, 255, 46), width=int(1.5 * k))

    # player arrow
    ar = C["PLAYER_ARROW"] * ui * k
    paste_center(img, icon("_arrow", ar), cx, cy, heading(*state["face"]) + rot)
    # north
    nx, ny = rot2(0, -(D / 2 - 3 * ui * k), rot)
    nr = 11 * ui * k
    d.ellipse([cx + nx - nr, cy + ny - nr, cx + nx + nr, cy + ny + nr], fill=THEME["Background"] + (255,),
              outline=THEME["TextDim"] + (255,), width=int(1.5 * ui * k))
    text_center(d, (cx + nx, cy + ny), "N", font(FONT_HEAVY, 13 * ui * k), (255, 255, 255), 0)
    # M key cap (desktop) at 45 degrees
    hx, hy = cx + D * 0.354, cy - D * 0.354
    hs = 12 * ui * k
    rounded(d, [hx - hs, hy - hs, hx + hs, hy + hs], 6 * ui * k, fill=THEME["PanelLight"] + (255,),
            outline=THEME["Stroke"] + (255,), width=int(2 * ui * k))
    text_center(d, (hx, hy), state.get("key", "M"), font(FONT_HEAVY, 13 * ui * k), (255, 255, 255), 0)
    # distance pill
    if state.get("dist"):
        tf = font(FONT_HEAVY, 15 * ui * k)
        tw = d.textlength(state["dist"], font=tf)
        pw = tw + 40 * ui * k
        ph = 24 * ui * k
        py = cy + D / 2 - 2 * ui * k
        rounded(d, [cx - pw / 2, py - ph / 2, cx + pw / 2, py + ph / 2], ph / 2, fill=THEME["Background"] + (255,),
                outline=THEME["Stroke"] + (255,), width=int(2 * ui * k))
        paste_center(img, icon(state.get("dist_icon", "pin"), 18 * ui * k, state["route_color"]),
                     cx - pw / 2 + 16 * ui * k, py)
        d.text((cx - pw / 2 + 28 * ui * k, py), state["dist"], font=tf, fill=(255, 255, 255), anchor="lm",
               stroke_width=int(1.5 * k), stroke_fill=THEME["Stroke"])
    out = img.resize((W // k, W // k), Image.LANCZOS)
    return out, pad // k


# ---------------------------------------------------------------------------------------------------------------------
# HUD mock pieces
# ---------------------------------------------------------------------------------------------------------------------
def backdrop(w, h):
    src = Image.open(os.path.join(ROOT, "docs", "previews", "map_street.png")).convert("RGB")
    ch = 536
    cw = min(1000, int(ch * w / h))
    x0 = 1000 + (1000 - cw) // 2
    crop = src.crop((x0, 24, x0 + cw, 24 + ch))
    return crop.resize((w, h), Image.LANCZOS).convert("RGBA")


def cash_pill(img, cx, top, s):
    d = ImageDraw.Draw(img)
    w, h = 250 * s, 58 * s
    rounded(d, [cx - w / 2, top, cx + w / 2, top + h], h / 2, fill=(30, 22, 34, 240), outline=(30, 140, 60), width=int(3 * s))
    d.ellipse([cx - w / 2 - 6 * s, top - 4 * s, cx - w / 2 + 60 * s, top + h + 4 * s], fill=(60, 200, 90),
              outline=(10, 11, 22), width=int(3 * s))
    d.text((cx + 20 * s, top + h / 2), "$12.4K", font=font(FONT_HEAVY, 34 * s), fill=(110, 255, 140), anchor="mm",
           stroke_width=int(2 * s), stroke_fill=(10, 11, 22))


def stars(img, cx, top, s, n):
    d = ImageDraw.Draw(img)
    w, h = 262 * s, 50 * s
    rounded(d, [cx - w / 2, top, cx + w / 2, top + h], h / 2, fill=THEME["Background"] + (235,), outline=(10, 11, 22),
            width=int(3 * s))
    for i in range(5):
        x = cx - w / 2 + 55 * s + i * 42 * s
        col = (255, 205, 50) if i < n else (58, 62, 104)
        pts = []
        for j in range(10):
            rr = (16 if j % 2 == 0 else 7) * s
            a = -math.pi / 2 + j * math.pi / 5
            pts.append((x + math.cos(a) * rr, top + h / 2 + math.sin(a) * rr))
        d.polygon(pts, fill=col, outline=(10, 11, 22))


def menu_grid(img, x, y, cols, rows, cell, pad, s, labels):
    d = ImageDraw.Draw(img)
    colors = [(255, 205, 50), (0, 214, 255), (160, 90, 255), (255, 52, 140), (255, 190, 40), (70, 235, 110),
              (120, 70, 255)]
    for i, lab in enumerate(labels):
        col, row = i % cols, i // cols
        if row >= rows:
            break
        bx, by = x + col * (cell + pad) * s, y + row * (cell + pad) * s
        rounded(d, [bx, by, bx + cell * s, by + cell * s], 14 * s, fill=colors[i % len(colors)],
                outline=(10, 11, 22), width=int(3 * s))
        d.text((bx + cell * s / 2, by + cell * s - 9 * s), lab, font=font(FONT_HEAVY, 11 * s), fill=(255, 255, 255),
               anchor="mm", stroke_width=max(1, int(1.5 * s)), stroke_fill=(10, 11, 22))


def top_row(img, x, y, cell, s):
    d = ImageDraw.Draw(img)
    for i, lab in enumerate(["CODES", "SETTINGS"]):
        bx = x + i * cell * s
        rounded(d, [bx, y, bx + (cell - 6) * s, y + (cell - 6) * s], 12 * s, fill=THEME["PanelLight"],
                outline=(10, 11, 22), width=int(3 * s))
        d.text((bx + (cell - 6) * s / 2, y + (cell - 14) * s), lab, font=font(FONT_HEAVY, 9 * s), fill=(255, 255, 255),
               anchor="mm")


MENU_LABELS = ["STORE", "GEAR", "INDEX", "DAILY", "JOBS", "GIFTS", "REBIRTH"]


def grid_fit(count, available, cell, pad):
    rows = max(1, int((available + pad) // (cell + pad)))
    rows = min(rows, count)
    return math.ceil(count / rows), rows


def touch_grid(count, aw, ah, cells, pad):
    cols, rows, cell = 1, count, cells[-1]
    for i, c in enumerate(cells):
        cols = max(1, min(count, int((aw + pad) // (c + pad))))
        rows = math.ceil(count / cols)
        cell = c
        if rows * (c + pad) - pad <= ah or i == len(cells) - 1:
            break
    return cols, rows, cell


# ---------------------------------------------------------------------------------------------------------------------
# Scenes
# ---------------------------------------------------------------------------------------------------------------------
def scene_desktop(routes, out):
    W, H = 1280, 720
    s = 1.0
    img = backdrop(W, H)
    d = ImageDraw.Draw(img)
    # topbar + chat window (CoreGui) placeholders
    inset = 58
    d.rectangle([0, 0, W, inset], fill=(20, 22, 30, 230))
    for i in range(2):
        rounded(d, [12 + i * 46, 10, 50 + i * 46, 48], 12, fill=(60, 62, 76))
    rounded(d, [8, inset + 8, 420, inset + 236], 10, fill=(0, 0, 0, 110))
    d.text((20, inset + 20), "Chat (default window)", font=font(FONT_BOLD, 14), fill=(220, 220, 230))
    cash_pill(img, W / 2, inset + 8, s)
    stars(img, W / 2, inset + 80, s, 3)
    # HUD menu column (HUDController.layout with the minimap reserve)
    D = C["DESKTOP_SIZE"]
    reserve = D + C["MARGIN"] + C["PILL_ROOM"] + 4
    top = 250
    top_row(img, 12, inset + top, 52, s)
    menu_top = top + 52 + 14
    avail = H - inset - menu_top - reserve
    cols, rows = grid_fit(7, avail, 62, 6)
    cell = 62
    if cols > 4:
        c2, r2, cell2 = touch_grid(7, 4 * 68 - 6, avail, [62, 52], 6)
        if r2 * (cell2 + 6) - 6 <= avail:
            cols, rows, cell = c2, r2, cell2
    menu_grid(img, 12, inset + menu_top, cols, rows, cell, 6, s, MENU_LABELS)
    # radar: driving + GPS home while wanted
    route = routes[0]
    radar, pad = render_radar({
        "pos": (route["from"][0], route["from"][1]), "cam": (0.6, -0.8), "face": (0.55, -0.83), "zoom": 300,
        "route": [tuple(p) for p in route["points"]], "route_color": (70, 235, 110), "target": None,
        "waypoints": [((route["to"][0], route["to"][1]), "home", (70, 235, 110))], "own_garage": 4,
        "rival_garages": (1, 6), "police": [((route["from"][0] - 90, route["from"][1] + 60), True),
                                              ((route["from"][0] + 40, route["from"][1] + 140), False)],
        "wanted": 3, "seen": (route["from"][0] - 30, route["from"][1] + 20), "red": True,
        "dist": f"{route['length'] / 3:.0f}m", "dist_icon": "home",
    }, D, 1.0)
    rx, ry = C["MARGIN"], H - C["MARGIN"] - C["PILL_ROOM"] - D
    img.alpha_composite(radar, (int(rx - pad), int(ry - pad)))
    d = ImageDraw.Draw(img)
    d.text((rx + D + 12, ry + D - 4), "MIDTOWN", font=font(FONT_HEAVY, 15), fill=(255, 255, 255), anchor="ls",
           stroke_width=2, stroke_fill=(10, 11, 22))
    # speedometer placeholder (bottom-center)
    rounded(d, [W / 2 - 150, H - 180, W / 2 + 150, H - 12], 16, fill=(18, 20, 38, 200), outline=(10, 11, 22), width=3)
    d.text((W / 2, H - 110), "87", font=font(FONT_HEAVY, 64), fill=(255, 255, 255), anchor="mm", stroke_width=3,
           stroke_fill=(10, 11, 22))
    d.text((W / 2, H - 62), "MPH", font=font(FONT_HEAVY, 16), fill=THEME["TextDim"], anchor="mm")
    img.convert("RGB").save(out)


def scene_phone(routes, out):
    W, H = 844, 390
    s = 0.55
    inset = 36
    img = backdrop(W, H)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W, inset], fill=(20, 22, 30, 230))
    for i in range(2):
        rounded(d, [12 + i * 32, 6, 38 + i * 32, 30], 8, fill=(60, 62, 76))
    canvas_w, canvas_h = W / s, (H - inset) / s
    D = C["TOUCH_SIZE"]
    left = 12 + D + 12
    top_row(img, left * s, inset + 6 * s, 62, s)
    menu_top = 6 + 62 + 14
    cols, rows, cell = touch_grid(7, canvas_w / 2 - 168 - left, canvas_h / 3 - menu_top, [76, 62], 6)
    menu_grid(img, left * s, inset + menu_top * s, cols, rows, cell, 6, s, MENU_LABELS)
    cash_pill(img, W / 2, inset + 8 * s, s)
    # thumbstick zone (left 40%, bottom 2/3)
    zone = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    zd = ImageDraw.Draw(zone)
    zx1, zy0 = W * 0.4, inset + (H - inset) / 3
    zd.rectangle([0, zy0, zx1, H], fill=(255, 255, 255, 26), outline=(255, 255, 255, 120), width=1)
    zd.text((8, zy0 + 6), "dynamic thumbstick zone", font=font(FONT_BOLD, 11), fill=(255, 255, 255, 190))
    img.alpha_composite(zone)
    d = ImageDraw.Draw(img)
    # driving buttons (right) placeholders
    for (bx, by, r, lab) in [(W - 46, H - 50, 32, "NITRO"), (W - 112, H - 40, 27, "DRIFT"), (W - 45, H - 117, 23, "HORN")]:
        d.ellipse([bx - r, by - r, bx + r, by + r], fill=(0, 0, 0, 90), outline=(255, 255, 255, 150), width=2)
        d.text((bx, by), lab, font=font(FONT_HEAVY, 9), fill=(255, 255, 255), anchor="mm")
    route = routes[1]
    radar, pad = render_radar({
        "pos": (route["from"][0], route["from"][1]), "cam": (-1, 0.05), "face": (-1, 0.1), "zoom": 165,
        "route": [tuple(p) for p in route["points"]], "route_color": (186, 94, 255),
        "waypoints": [((route["to"][0], route["to"][1]), "pin", (186, 94, 255))], "own_garage": 0,
        "rival_garages": (3, 5), "dist": f"{route['length'] / 3:.0f}m", "dist_icon": "pin", "key": "🗺",
    }, D * s, s)
    rx, ry = 12 * s, inset + 6 * s
    img.alpha_composite(radar, (int(rx - pad), int(ry - pad)))
    d = ImageDraw.Draw(img)
    d.text((rx + D * s / 2, ry + D * s + 14 * s), "SPAWN PLAZA", font=font(FONT_HEAVY, 15 * s * 1.1),
           fill=(255, 255, 255), anchor="mt", stroke_width=1, stroke_fill=(10, 11, 22))
    img.convert("RGB").save(out)


def scene_map(routes, out, W, H, phone):
    ui = max(0.72, min(W / 1280, H / 720)) if phone else min(W / 1280, H / 720)
    img = Image.new("RGBA", (W, H), WATER + (255,))
    top = 84 * ui
    fit = min(W, H - top) / ((960 + 50) * 2)
    scale = fit
    cx, cz = 0.0, -(top / 2) / scale

    def ws(x, z):
        return W / 2 + (x - cx) * scale, H / 2 + (z - cz) * scale

    # map art
    x0, y0 = ws(WMIN, WMIN)
    size = int(WSIZE * scale)
    img.paste(MAP.resize((size, size), Image.LANCZOS).convert("RGBA"), (int(x0), int(y0)))
    d = ImageDraw.Draw(img)
    # edge shades
    shade = Image.new("L", (1, 256))
    for yy in range(256):
        shade.putpixel((0, yy), int(165 * max(0, 1 - yy / 255)))
    band = shade.resize((W, int(H * 0.22)))
    img.paste((0, 0, 0, 255), (0, 0, W, band.height), band)
    img.paste((0, 0, 0, 255), (0, H - band.height, W, H), band.transpose(Image.FLIP_TOP_BOTTOM))
    # route (from the player's position)
    route = routes[1]
    pts = [ws(*p) for p in route["points"]]
    w = 7 * ui
    o = 2.5 * ui
    lay = Image.new("RGBA", (W * SS, H * SS), (0, 0, 0, 0))
    ld = ImageDraw.Draw(lay)
    sp = [(x * SS, y * SS) for x, y in pts]
    ld.line(sp, fill=(10, 12, 24, 230), width=int((w + 2 * o) * SS), joint="curve")
    ld.line(sp, fill=(186, 94, 255, 255), width=int(w * SS), joint="curve")
    for p in sp:
        ld.ellipse([p[0] - w * SS / 2, p[1] - w * SS / 2, p[0] + w * SS / 2, p[1] + w * SS / 2], fill=(186, 94, 255, 255))
    img.alpha_composite(lay.resize((W, H), Image.LANCZOS))
    d = ImageDraw.Draw(img)
    # labels
    lf = font(FONT_HEAVY, 20 * ui)
    lf2 = font(FONT_HEAVY, 15 * ui)
    for name, x, z, tier in DISTRICTS:
        if tier != 1:
            continue  # tier-2 names appear once zoomed in (zoom >= 1.6)
        sx, sy = ws(x, z)
        d.text((sx, sy), name, font=lf if tier == 1 else lf2, fill=(255, 255, 255), anchor="mm",
               stroke_width=max(1, int(2 * ui)), stroke_fill=(10, 11, 22))
    # blips
    bs = 30 * ui * 0.93
    for (x, z), name, color, _ in POIS:
        sx, sy = ws(x, z)
        paste_center(img, icon(name, bs, color), sx, sy)
    for i, door in enumerate(GARAGES):
        sx, sy = ws(*door)
        if i == 4:
            paste_center(img, icon("garage", bs + 6, (70, 235, 110)), sx, sy)
        elif i in (1, 6):
            paste_center(img, icon("garage", bs, (150, 156, 190)), sx, sy)
    for (x, z) in [(-470, 310), (-500, 150), (330, -90)]:
        sx, sy = ws(x, z)
        paste_center(img, icon("dot", bs * 0.55, (255, 60, 60)), sx, sy)
    tx, tz = route["to"]
    sx, sy = ws(tx, tz)
    paste_center(img, icon("pin", bs + 8, (186, 94, 255)), sx, sy)
    hx, hz = (320, 480)
    sx, sy = ws(hx, hz)
    paste_center(img, icon("flame", bs + 6, (255, 190, 40)), sx, sy)
    px, pz = route["from"]
    sx, sy = ws(px, pz)
    paste_center(img, icon("_arrow", 38 * ui), sx, sy, 60)
    # chrome
    d = ImageDraw.Draw(img)
    cs = ui
    d.text((24 * cs, 14 * cs), "HOTWIRE CITY", font=font(FONT_DISPLAY, 34 * cs), fill=(255, 255, 255),
           stroke_width=int(2 * cs), stroke_fill=(10, 11, 22))
    hint = ("Tap to set a waypoint  •  Pinch to zoom  •  Drag to move" if phone else
            "Click to set a waypoint  •  Scroll to zoom  •  Drag to move  •  [M] close")
    d.text((26 * cs, 58 * cs), hint, font=font(FONT_BOLD, 15 * cs), fill=THEME["TextDim"])
    bx = W - 18 * cs - 56 * cs
    rounded(d, [bx, 14 * cs, bx + 56 * cs, 70 * cs], 14 * cs, fill=THEME["Danger"], outline=(10, 11, 22), width=int(3 * cs))
    text_center(d, (bx + 28 * cs, 42 * cs), "X", font(FONT_HEAVY, 24 * cs), (255, 255, 255))
    # gps chip
    chip = f"WAYPOINT  •  {route['length'] / 3:.0f}m"
    cf = font(FONT_HEAVY, 19 * cs)
    tw = d.textlength(chip, font=cf)
    cw, ch = tw + 70 * cs, 44 * cs
    rounded(d, [W / 2 - cw / 2, 16 * cs, W / 2 + cw / 2, 16 * cs + ch], 14 * cs, fill=THEME["Panel"],
            outline=(10, 11, 22), width=int(3 * cs))
    paste_center(img, icon("pin", 28 * cs, (186, 94, 255)), W / 2 - cw / 2 + 28 * cs, 16 * cs + ch / 2)
    d.text((W / 2 - cw / 2 + 48 * cs, 16 * cs + ch / 2), chip, font=cf, fill=(255, 255, 255), anchor="lm",
           stroke_width=int(1.5 * cs), stroke_fill=(10, 11, 22))
    # tools
    for i, lab in enumerate(["", "-", "+"]):
        by = H - 18 * cs - 60 * cs - i * 70 * cs
        col = THEME["Secondary"] if i == 0 else THEME["PanelLight"]
        rounded(d, [W - 78 * cs, by, W - 18 * cs, by + 60 * cs], 14 * cs, fill=col, outline=(10, 11, 22), width=int(3 * cs))
        if lab:
            text_center(d, (W - 48 * cs, by + 30 * cs), lab, font(FONT_HEAVY, 28 * cs), (255, 255, 255))
        else:
            paste_center(img, icon("target", 36 * cs), W - 48 * cs, by + 30 * cs)
    rounded(d, [W - 96 * cs - 210 * cs, H - 18 * cs - 50 * cs, W - 96 * cs, H - 18 * cs], 14 * cs,
            fill=THEME["Primary"], outline=(10, 11, 22), width=int(3 * cs))
    text_center(d, (W - 96 * cs - 105 * cs, H - 18 * cs - 25 * cs), "CLEAR WAYPOINT", font(FONT_HEAVY, 16 * cs),
                (255, 255, 255))
    # legend
    if phone:
        rounded(d, [18 * cs, H - 18 * cs - 48 * cs, 148 * cs, H - 18 * cs], 14 * cs, fill=THEME["PanelLight"],
                outline=(10, 11, 22), width=int(3 * cs))
        text_center(d, (83 * cs, H - 42 * cs), "LEGEND", font(FONT_HEAVY, 17 * cs), (255, 255, 255))
    else:
        rows = [("_arrow", (255, 255, 255), "You"), ("garage", (70, 235, 110), "Your Garage"),
                ("garage", (150, 156, 190), "Rival Garage")] + \
               [(n, c, lab) for _, n, c, lab in POIS if lab] + \
               [("flame", (255, 190, 40), "Hot Drop"), ("pin", (186, 94, 255), "Waypoint"),
                ("dot", (255, 60, 60), "Police")]
        lh = 26 * cs
        lw = 210 * cs
        top = H - 18 * cs - (len(rows) * (lh + 2) + 24 * cs + 30 * cs)
        rounded(d, [18 * cs, top, 18 * cs + lw, H - 18 * cs], 14 * cs, fill=THEME["Panel"] + (240,),
                outline=(10, 11, 22), width=int(3 * cs))
        d.text((30 * cs, top + 12 * cs), "LEGEND", font=font(FONT_HEAVY, 17 * cs), fill=(255, 255, 255))
        y = top + 40 * cs
        for name, col, lab in rows:
            paste_center(img, icon(name, 22 * cs, col), 42 * cs, y + 12 * cs)
            d.text((62 * cs, y + 12 * cs), lab, font=font(FONT_BOLD, 15 * cs), fill=(255, 255, 255), anchor="lm")
            y += lh + 2
    img.convert("RGB").save(out)


def scene_closeups(routes, out):
    tiles = []
    r0, r1, r2 = routes[0], routes[1], routes[2]
    states = [
        ("ON FOOT  (zoom 165, camera-up)", {
            "pos": (-80, 60), "cam": (0.2, -1), "face": (0.5, -0.8), "zoom": 165, "own_garage": 4,
            "rival_garages": (1, 6)}),
        ("DRIVING + GPS  (zoom eases out)", {
            "pos": (r1["from"][0], r1["from"][1]), "cam": (-1, 0.05), "face": (-1, 0.1), "zoom": 330,
            "route": [tuple(p) for p in r1["points"]], "route_color": (186, 94, 255),
            "waypoints": [((r1["to"][0], r1["to"][1]), "pin", (186, 94, 255))], "own_garage": 0,
            "dist": f"{r1['length'] / 3:.0f}m"}),
        ("3-STAR CHASE  (search area, cops)", {
            "pos": (r0["from"][0], r0["from"][1]), "cam": (0.6, -0.8), "face": (0.55, -0.83), "zoom": 300,
            "route": [tuple(p) for p in r0["points"]], "route_color": (70, 235, 110),
            "waypoints": [((r0["to"][0], r0["to"][1]), "home", (70, 235, 110))], "own_garage": 4,
            "police": [((r0["from"][0] - 90, r0["from"][1] + 60), True), ((r0["from"][0] + 40, r0["from"][1] + 140), False),
                       ((r0["from"][0] - 160, r0["from"][1] - 40), True)],
            "wanted": 3, "seen": (r0["from"][0] - 30, r0["from"][1] + 20), "red": False,
            "dist": f"{r0['length'] / 3:.0f}m", "dist_icon": "home"}),
        ("HOT DROP  (sticky blip on the rim)", {
            "pos": (-560, -260), "cam": (0, -1), "face": (0.1, -1), "zoom": 165, "own_garage": 0,
            "route": [tuple(p) for p in r2["points"]], "route_color": (255, 190, 40),
            "waypoints": [((320, 480), "flame", (255, 190, 40))], "dist": "540m", "dist_icon": "flame"}),
    ]
    size = 260
    sheet = Image.new("RGBA", (4 * (size + 80) + 20, size + 150), (24, 27, 40, 255))
    d = ImageDraw.Draw(sheet)
    for i, (title, st) in enumerate(states):
        radar, pad = render_radar(st, size, size / C["DESKTOP_SIZE"])
        x = 20 + i * (size + 80)
        sheet.alpha_composite(radar, (int(x + 30 - pad), int(50 - pad)))
        d.text((x + 30 + size / 2, size + 110), title, font=font(FONT_BOLD, 14), fill=(220, 225, 245), anchor="mm")
    d.text((20, 14), "Hotwire City radar (approximation of MinimapController, real map art + RoadGraph routes)",
           font=font(FONT_HEAVY, 16), fill=(255, 255, 255))
    sheet.convert("RGB").save(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir")
    ap.add_argument("--routes")
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)
    rpath = a.routes or os.path.join(ROOT, "build", "minimap", "sample_routes.json")
    if not a.routes:
        gx, gz = GARAGES[4]
        subprocess.run(["lune", "run", "tools/minimap/sample_route.luau", rpath,
                        "-150", "-250", str(gx), str(gz),  # midtown -> home garage (plot 5)
                        "70", "80", "480", "-400",  # spawn -> custom waypoint
                        "-560", "-260", "320", "480"], check=True, cwd=ROOT)
    routes = json.load(open(rpath))["routes"]
    scene_closeups(routes, os.path.join(a.outdir, "radar_closeups.png"))
    scene_desktop(routes, os.path.join(a.outdir, "hud_desktop_minimap.png"))
    scene_phone(routes, os.path.join(a.outdir, "hud_phone_minimap.png"))
    scene_map(routes, os.path.join(a.outdir, "map_fullscreen_desktop.png"), 1280, 720, False)
    scene_map(routes, os.path.join(a.outdir, "map_fullscreen_phone.png"), 844, 390, True)
    print("wrote previews to " + a.outdir)


if __name__ == "__main__":
    main()
