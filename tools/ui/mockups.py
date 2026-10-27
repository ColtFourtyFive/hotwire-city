#!/usr/bin/env python3
"""Layout mockups of the v2 GTA-style UI (PIL), drawn from the same numbers the game uses.

    python3 -I tools/ui/mockups.py [outdir]          (default docs/v2/early/ui)

Layout rects come from src/client/UI/HudLayout.luau via `lune run tools/ui/export_layout.luau` (run automatically),
sprites from assets/ui/*_sheet.png + cells.json, fonts from assets/ui/fonts, the radar map from
assets/minimap/map_full.png and the street backdrop from docs/previews/map_street.png. These are approximations for
reviewing placement, hierarchy and type; Studio is the source of truth for the final look.

Outputs, each at desktop 1280x720 and phone 844x390 (landscape, notch + top bar + home bar insets):
    hud_rest_*.png       on foot: radar + bars, help text, feed card, cash, location, objective
    driving_*.png        driving with 3 stars: flashing radar, GPS route, delivery timer, speed, drift line
    pause_*.png          pause menu on the JOBS tab: tabs, list + detail, instructional buttons
    phone_*.png          the phone open on its 3x3 home screen
    list_*.png           the GTA interaction list menu (Gear shop)
    wasted_*.png         the WASTED shard over the desaturated scene
"""
import json
import math
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageOps

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import C, ROOT, font  # noqa: E402

K = 2  # supersampling of the overlay
LAYOUT_JSON = os.path.join(ROOT, "build", "ui_layout.json")


def rgba(c, a=255):
    return tuple(c[:3]) + (int(a),)


def alpha_of(transparency):
    return int(round(255 * (1 - transparency)))


# ---------------------------------------------------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------------------------------------------------
def load_layout():
    os.makedirs(os.path.dirname(LAYOUT_JSON), exist_ok=True)
    subprocess.run(["lune", "run", "tools/ui/export_layout.luau", LAYOUT_JSON], cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL)
    return json.load(open(LAYOUT_JSON))


CELLS = json.load(open(os.path.join(ROOT, "assets", "ui", "cells.json")))
SHEETS = {name: Image.open(os.path.join(ROOT, "assets", "ui", name + "_sheet.png")).convert("RGBA")
          for name in ("hud", "apps", "portraits", "banners")}
MAP = Image.open(os.path.join(ROOT, "assets", "minimap", "map_full.png")).convert("RGB")
MAP_K = MAP.width / 2048.0
WMIN = -1024.0


def sprite(key, w, h=None, tint=None, alpha=255):
    sheet, cell = key.split(".")
    x, y, cw, ch = CELLS[sheet][cell]
    im = SHEETS[sheet].crop((x, y, x + cw, y + ch)).resize((max(1, int(w)), max(1, int(h or w))), Image.LANCZOS)
    if tint is not None or alpha != 255:
        r, g, b, a = im.split()
        if tint is not None:
            r = r.point(lambda v: v * tint[0] // 255)
            g = g.point(lambda v: v * tint[1] // 255)
            b = b.point(lambda v: v * tint[2] // 255)
        if alpha != 255:
            a = a.point(lambda v: v * alpha // 255)
        im = Image.merge("RGBA", (r, g, b, a))
    return im


def backdrop(w, h, dim=0.0):
    src = Image.open(os.path.join(ROOT, "docs", "previews", "map_street.png")).convert("RGB")
    ch = 536
    cw = min(1000, int(ch * w / h))
    x0 = 1000 + (1000 - cw) // 2
    img = src.crop((x0, 24, x0 + cw, 24 + ch)).resize((w, h), Image.LANCZOS)
    # a touch of GTA grade: slightly warmer and less saturated than the raw render
    img = ImageEnhance.Color(img).enhance(0.85)
    if dim:
        img = Image.blend(img, Image.new("RGB", (w, h), (0, 0, 0)), dim)
    return img.convert("RGBA")


# ---------------------------------------------------------------------------------------------------------------------
# Overlay canvas in design px
# ---------------------------------------------------------------------------------------------------------------------
class Mock:
    def __init__(self, cw, ch):
        self.cw, self.ch = cw, ch
        self.img = Image.new("RGBA", (int(cw * K), int(ch * K)), (0, 0, 0, 0))
        self.d = ImageDraw.Draw(self.img)

    def box(self, x, y, w, h, fill, radius=0):
        if w * K < 1 or h * K < 1:
            return
        b = [x * K, y * K, (x + w) * K - 1, (y + h) * K - 1]
        if radius:
            self.d.rounded_rectangle(b, radius=radius * K, fill=fill)
        else:
            self.d.rectangle(b, fill=fill)

    def blend_box(self, x, y, w, h, fill, radius=0):
        if w * K < 1 or h * K < 1:
            return
        lay = Image.new("RGBA", self.img.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(lay)
        b = [x * K, y * K, (x + w) * K - 1, (y + h) * K - 1]
        if radius:
            d.rounded_rectangle(b, radius=radius * K, fill=fill)
        else:
            d.rectangle(b, fill=fill)
        self.img.alpha_composite(lay)

    def circle(self, cx, cy, r, fill, outline=None, width=0):
        self.blend_ellipse(cx, cy, r, fill, outline, width)

    def blend_ellipse(self, cx, cy, r, fill, outline=None, width=0):
        lay = Image.new("RGBA", self.img.size, (0, 0, 0, 0))
        ImageDraw.Draw(lay).ellipse([(cx - r) * K, (cy - r) * K, (cx + r) * K, (cy + r) * K], fill=fill,
                                    outline=outline, width=int(width * K))
        self.img.alpha_composite(lay)

    def line(self, pts, fill, width):
        self.d.line([(x * K, y * K) for x, y in pts], fill=fill, width=max(1, int(width * K)), joint="curve")

    def measure(self, s, fname, size):
        return self.d.textlength(s, font=font(fname, int(size * K))) / K

    def text(self, x, y, s, fname, size, fill, anchor="la", stroke=0, stroke_fill=(0, 0, 0, 255), shadow=False):
        f = font(fname, int(size * K))
        if shadow:
            self.d.text(((x + 1.5) * K, (y + 1.5) * K), s, font=f, fill=(0, 0, 0, 170), anchor=anchor)
        self.d.text((x * K, y * K), s, font=f, fill=fill, anchor=anchor, stroke_width=int(stroke * K),
                    stroke_fill=stroke_fill)

    def paste(self, im, x, y, w=None, h=None, rot=0):
        w = w or im.width / K
        h = h or im.height / K
        im = im.resize((max(1, int(w * K)), max(1, int(h * K))), Image.LANCZOS)
        if rot:
            im = im.rotate(-rot, resample=Image.BICUBIC, expand=True)
            x -= (im.width / K - w) / 2
            y -= (im.height / K - h) / 2
        self.img.alpha_composite(im, (int(round(x * K)), int(round(y * K))))

    def glyph(self, key, x, y, size, tint=None, alpha=255, rot=0):
        self.paste(sprite(key, size * K, size * K, tint, alpha), x, y, size, size, rot)

    def rich(self, x, y, runs, fname, size, anchor="l", shadow=True, outline=0):
        """runs: [(text, color)] or ("KEY", None) tuples marked with color='key'. y is the text middle."""
        widths = []
        for text, col in runs:
            if col == "key":
                widths.append(self.measure(text, "Montserrat-600", size * 0.85) + size * 0.7)
            else:
                widths.append(self.measure(text, fname, size))
        total = sum(widths)
        cx = x - (total / 2 if anchor == "m" else (total if anchor == "r" else 0))
        for (text, col), w in zip(runs, widths):
            if col == "key":
                kh = size * 1.25
                self.box(cx + 1, y - kh / 2, w - 2, kh, rgba(C["text"]))
                self.text(cx + w / 2, y, text, "Montserrat-600", size * 0.85, (0, 0, 0, 255), anchor="mm")
            else:
                self.text(cx, y, text, fname, size, rgba(col), anchor="lm", shadow=shadow, stroke=outline)
            cx += w
        return total

    def wrap_rich(self, x, y, width, runs, fname, size, line_h):
        """Word-wraps runs into lines inside `width`; returns the height used."""
        words = []
        for text, col in runs:
            if col == "key":
                words.append((text, col))
                continue
            parts = text.split(" ")
            for i, p in enumerate(parts):
                words.append((p + (" " if i < len(parts) - 1 else ""), col))
        lines, cur, cur_w = [], [], 0
        for wtext, col in words:
            ww = (self.measure(wtext, "Montserrat-600", size * 0.85) + size * 0.7) if col == "key" else \
                self.measure(wtext, fname, size)
            if cur and cur_w + ww > width:
                lines.append(cur)
                cur, cur_w = [], 0
            cur.append((wtext, col))
            cur_w += ww
        if cur:
            lines.append(cur)
        for i, ln in enumerate(lines):
            self.rich(x, y + line_h * (i + 0.5), ln, fname, size, shadow=False)
        return line_h * len(lines)


def compose(view, mock, back):
    """Puts the design-px overlay onto the real-pixel backdrop at the safe-area inset."""
    c = view["canvas"]
    s = c["scale"]
    ov = mock.img.resize((int(round(c["w"] * s)), int(round(c["h"] * s))), Image.LANCZOS)
    out = back.copy()
    out.alpha_composite(ov, (int(c["inset"][0]), int(c["inset"][1])))
    return out


def roblox_topbar(img, view):
    """The Roblox top bar buttons (outside CoreUISafeInsets) so the mock reads like the real screen."""
    d = ImageDraw.Draw(img)
    touch = view["canvas"]["touch"]
    top = view["canvas"]["inset"][1]
    size = 32 if touch else 44
    x = view["canvas"]["inset"][0] + (6 if touch else 12)
    y = max(2, (top - size) / 2)
    for i in range(2):
        d.rounded_rectangle([x + i * (size + 8), y, x + i * (size + 8) + size, y + size], radius=size * 0.3,
                            fill=(20, 22, 28, 200))


# ---------------------------------------------------------------------------------------------------------------------
# HUD pieces
# ---------------------------------------------------------------------------------------------------------------------
def radar(m, L, state):
    r = L["radar"]
    x, y, w, h = r["x"], r["y"], r["w"], r["h"]
    zoom = state.get("zoom", 165)
    pivot_x, pivot_y = w * 0.5, h * 0.6
    scale = pivot_y / zoom  # design px per stud
    heading = state.get("heading", 20)  # camera heading (degrees, map rotates the other way)
    px, pz = state.get("pos", (0, -240))
    # rotate the map so the camera looks up: sample a big square around the player, rotate, crop
    span = int(max(w, h) * 2.2 / scale * MAP_K)
    mu, mv = (px - WMIN) * MAP_K, (pz - WMIN) * MAP_K
    crop = MAP.crop((int(mu - span / 2), int(mv - span / 2), int(mu + span / 2), int(mv + span / 2)))
    crop = crop.rotate(heading, resample=Image.BICUBIC)
    out_px = int(span / MAP_K * scale * K)
    crop = crop.resize((out_px, out_px), Image.LANCZOS)
    # GTA radar: darkened, slightly cool
    crop = ImageEnhance.Brightness(crop).enhance(0.62)
    crop = ImageEnhance.Color(crop).enhance(0.55).convert("RGBA")
    cx, cy = out_px / 2, out_px / 2
    left = int(cx - pivot_x * K)
    top = int(cy - pivot_y * K)
    tile = crop.crop((left, top, left + int(w * K), top + int(h * K)))
    td = ImageDraw.Draw(tile)

    def to_tile(wx, wz):
        dx, dz = (wx - px) * scale, (wz - pz) * scale
        a = math.radians(-heading)
        rx = dx * math.cos(a) - dz * math.sin(a)
        rz = dx * math.sin(a) + dz * math.cos(a)
        return (pivot_x + rx) * K, (pivot_y + rz) * K

    # GPS route
    route = state.get("route")
    if route:
        pts = [to_tile(*p) for p in route]
        td.line(pts, fill=(0, 0, 0, 220), width=int((4 + 3) * K), joint="curve")
        td.line(pts, fill=rgba(state.get("route_color", C["yellow"])), width=int(4 * K), joint="curve")
    # wanted flash on the edges
    if state.get("wanted"):
        col = C["red"] if state.get("red", True) else C["blue"]
        glow = Image.new("L", tile.size, 0)
        gd = ImageDraw.Draw(glow)
        bw = int(10 * K)
        gd.rectangle([0, 0, tile.width - 1, tile.height - 1], outline=200, width=bw)
        glow = glow.filter(ImageFilter.GaussianBlur(6 * K))
        tile.paste(rgba(col), (0, 0, tile.width, tile.height), glow)
    m.paste(tile, x, y, w, h)
    # blips (edge-clamped like MinimapController.clampToRect)
    for (wx, wz), key, tint, size in state.get("blips", []):
        bx, by = to_tile(wx, wz)
        bx, by = bx / K, by / K
        inset = 6
        bx = min(max(bx, inset), w - inset)
        by = min(max(by, inset), h - inset)
        m.glyph(key, x + bx - size / 2, y + by - size / 2, size, tint)
    # player arrow + north
    m.glyph("hud.arrow", x + pivot_x - 8, y + pivot_y - 8, 16, C["text"], rot=state.get("face", 0) - heading)
    # north marker sits on the rim in the north direction
    dx, dy = math.sin(math.radians(-heading)), -math.cos(math.radians(-heading))
    t = min((w / 2 - 8) / max(1e-6, abs(dx)) if dx else 1e9, (pivot_y - 8) / max(1e-6, -dy) if dy < 0 else 1e9,
            (h - pivot_y - 8) / max(1e-6, dy) if dy > 0 else 1e9)
    nx, ny = pivot_x + dx * t, pivot_y + dy * t
    m.glyph("hud.north", x + nx - 7, y + ny - 7, 14, C["text"])
    # bars under the radar: health 50 | armour 25 | ability 25
    b = L["bars"]
    seg = state["segs"]
    fr = state.get("bars", (1.0, 0.0, 1.0))
    cols = [(C["health"], C["health_track"]), (C["blue"], C["blue_dark"]), (C["yellow"], C["yellow_dark"])]
    bx = b["x"]
    for i, sw in enumerate(seg):
        m.box(bx, b["y"], sw, b["h"], rgba(cols[i][1], 220))
        m.box(bx, b["y"], sw * fr[i], b["h"], rgba(cols[i][0]))
        bx += sw + 2


def help_box(m, L, runs, touch):
    r = L["help"]
    size = 18 if touch else 16
    pad = 10
    lay = Mock(m.cw, m.ch)
    used = lay.wrap_rich(r["x"] + pad, r["y"] + pad, r["w"] - 2 * pad, runs, "Montserrat-500", size, size * 1.45)
    m.blend_box(r["x"], r["y"], r["w"], used + 2 * pad, (0, 0, 0, alpha_of(0.27)))
    m.img.alpha_composite(lay.img)
    return used + 2 * pad


def feed_card(m, x, y, w, portrait, title, sub, body_runs):
    h = 74
    m.blend_box(x, y, w, h, (0, 0, 0, alpha_of(0.27)))
    m.paste(sprite("portraits." + portrait, 48 * K), x + 8, y + 8, 48, 48)
    m.text(x + 64, y + 10, title, "Oswald-600", 15, rgba(C["text"]))
    m.text(x + 64, y + 29, sub, "Montserrat-500", 12, rgba(C["dim"]))
    lay = Mock(m.cw, m.ch)
    lay.wrap_rich(x + 8, y + 58, w - 16, body_runs, "Montserrat-500", 12, 15)
    m.blend_box(x, y + h, w, 18, (0, 0, 0, alpha_of(0.27)))
    m.img.alpha_composite(lay.img)


def stars(m, L, n, flashing_grey=None):
    r = L["stars"]
    size, pitch = L["starSize"], L["starPitch"]
    for i in range(5):
        sx = r["x"] + i * pitch
        if i < n:
            tint = C["dim"] if flashing_grey is not None and i in flashing_grey else C["text"]
            m.glyph("hud.star_fill", sx, r["y"], size, tint)
        else:
            m.glyph("hud.star_hollow", sx, r["y"], size, C["text"], alpha=int(255 * 0.7))


def cash(m, L, amount, delta=None):
    r = L["cash"]
    m.text(r["x"] + r["w"], r["y"] + r["h"] / 2, amount, "Kanit-900", 30, rgba(C["text"]), anchor="rm",
           stroke=2, stroke_fill=(0, 0, 0, 255))
    if delta:
        d = L["delta"]
        col = C["green"] if delta.startswith("+") else C["red"]
        m.text(d["x"] + d["w"], d["y"] + d["h"] / 2, delta, "Kanit-900", 20, rgba(col), anchor="rm",
               stroke=2, stroke_fill=(0, 0, 0, 255))


def objective(m, L, runs, touch):
    r = L["objective"]
    cy = r["y"] + (12 if touch else r["h"] - 12)
    m.rich(r["x"] + r["w"] / 2, cy, runs, "Montserrat-500", 18, anchor="m", outline=1.2)


def location(m, L, lines, driving, touch):
    r = L["locationDriving"] if driving else L["location"]
    n = L["locationLines"]
    lh = r["h"] / n
    size = L["locationSize"]
    shown = [s for s in lines if s][-n:] if not touch else [" · ".join(s for s in lines[1:] if s) or lines[0]]
    while len(shown) < n:
        shown.insert(0, "")
    for i, s in enumerate(shown):
        if not s:
            continue
        cy = r["y"] + lh * (i + 0.5)
        if touch:
            m.text(r["x"] + r["w"] / 2, cy, s, "Damion-400", size, rgba(C["text"]), anchor="mm", stroke=1.5,
                   stroke_fill=(0, 0, 0, 150))
        else:
            m.text(r["x"] + r["w"], cy, s, "Damion-400", size, rgba(C["text"]), anchor="rm", stroke=1.5,
                   stroke_fill=(0, 0, 0, 150))


def timer_bar(m, L, label, value, driving, value_col=None):
    t = L["timersDriving"] if driving else L["timers"]
    x, y, w, h = t["x"], t["y"], t["w"], t["h"]
    lay = Image.new("RGBA", (int(w * K), int(h * K)), (0, 0, 0, 0))
    for i in range(lay.width):
        a = int(200 * min(1.0, (i / lay.width) / 0.35))
        ImageDraw.Draw(lay).line([(i, 0), (i, lay.height)], fill=(0, 0, 0, a))
    m.paste(lay, x, y, w, h)
    m.text(x + w * 0.38, y + h / 2, label, "Oswald-500", 14, rgba(C["text"]), anchor="rm")
    m.text(x + w - 8, y + h / 2, value, "Kanit-900", 18, rgba(value_col or C["text"]), anchor="rm")


def speed(m, L, mph):
    r = L["speed"]
    m.text(r["x"] + r["w"] - 40, r["y"] + r["h"] - 4, str(mph), "Kanit-900", 34, rgba(C["text"]), anchor="rs",
           stroke=2, stroke_fill=(0, 0, 0, 255))
    m.text(r["x"] + r["w"] - 36, r["y"] + r["h"] - 8, "MPH", "Oswald-600", 14, rgba(C["dim"]), anchor="ls")


def drift_line(m, L, secs):
    r = L["driftText"]
    w1 = m.measure(f"{secs:.1f}s", "Oswald-600", 18)
    m.text(r["x"] + r["w"] - w1 - 6, r["y"] + r["h"] / 2, "DRIFT", "Oswald-600", 18, rgba(C["text"]), anchor="rm",
           stroke=1, stroke_fill=(0, 0, 0, 140))
    m.text(r["x"] + r["w"], r["y"] + r["h"] / 2, f"{secs:.1f}s", "Oswald-600", 18, rgba(C["yellow"]), anchor="rm",
           stroke=1, stroke_fill=(0, 0, 0, 140))


def circle_button(m, rect, caption, glyph):
    cx, cy = rect["x"] + rect["w"] / 2, rect["y"] + rect["h"] / 2
    rad = rect["w"] / 2
    m.blend_ellipse(cx, cy, rad, (0, 0, 0, alpha_of(0.35)), outline=rgba(C["text"], 77), width=1.5)
    gs = rect["w"] * 0.46
    m.glyph(glyph, cx - gs / 2, cy - rad * 0.16 - gs / 2, gs, C["text"])
    m.text(cx, cy + rad * 0.56, caption.upper(), "Oswald-500", max(11, rect["w"] * 0.2), rgba(C["text"]),
           anchor="mm")


def thumbstick_hint(m, L):
    """The dynamic thumbstick zone (left 40%, lower two thirds) as a faint guide on phone mocks."""
    w, h = L["w"], L["h"]
    m.blend_ellipse(w * 0.17, h * 0.72, 46, (255, 255, 255, 30), outline=(255, 255, 255, 60), width=2)
    m.blend_ellipse(w * 0.17, h * 0.72, 20, (255, 255, 255, 50))


def jump_button(m, L):
    w, h = L["w"], L["h"]
    m.blend_ellipse(w - 70, h - 62, 44, (255, 255, 255, 40), outline=(255, 255, 255, 90), width=2)


def instructional(m, x_right, y, items, size=14):
    """GTA instructional buttons, right-aligned: [key] Label  [key] Label."""
    x = x_right
    for key, label in reversed(items):
        lw = m.measure(label, "Montserrat-500", size)
        x -= lw
        m.text(x, y, label, "Montserrat-500", size, rgba(C["text"]), anchor="lm")
        x -= 6
        kw = m.measure(key, "Montserrat-600", size * 0.85) + size * 0.8
        x -= kw
        m.box(x, y - size * 0.65, kw, size * 1.3, rgba(C["text"]))
        m.text(x + kw / 2, y, key, "Montserrat-600", size * 0.85, (0, 0, 0, 255), anchor="mm")
        x -= 16


# ---------------------------------------------------------------------------------------------------------------------
# Scenes
# ---------------------------------------------------------------------------------------------------------------------
BLIPS = [((260, -360), "apps.garage", C["yellow"], 14), ((-120, -120), "hud.car", C["text"], 12),
         ((60, -420), "hud.wrench", C["text"], 12), ((-300, -260), "hud.cash", C["green"], 12)]


def hud_base(m, view, state):
    L = view["layout"]
    touch = L["touch"]
    st = dict(state)
    st["segs"] = view["bars"]
    radar(m, L, st)
    return L, touch


def scene_rest(view, location_lines=True):
    c = view["canvas"]
    L = view["layout"]
    touch = L["touch"]
    m = Mock(c["w"], c["h"])
    hud_base(m, view, {"blips": BLIPS, "bars": (1.0, 0.0, 0.85), "heading": 20, "face": 35})
    if touch:
        runs = [("Walk up to the ", C["text"]), ("car", C["blue"]),
                (" and hold the on-screen prompt to hotwire it.", C["text"])]
    else:
        runs = [("Walk up to the ", C["text"]), ("car", C["blue"]), (" and hold ", C["text"]), ("E", "key"),
                (" to hotwire it.", C["text"])]
    help_h = help_box(m, L, runs, touch)
    f = L["feed"]
    fw = f["w"]
    if touch:
        feed_card(m, f["x"], L["help"]["y"] + help_h + 6, fw, "security", "Garage Security", "Text message",
                  [("Your garage earned ", C["text"]), ("$1,240", C["green"]), (" while you were away.", C["text"])])
    else:
        feed_card(m, f["x"], f["y"] + f["h"] - 92, fw, "security", "Garage Security", "Text message",
                  [("Your garage earned ", C["text"]), ("$1,240", C["green"]), (" while you were away.", C["text"])])
    cash(m, L, "$15,150", "+$700")
    objective(m, L, [("Steal a ", C["text"]), ("car", C["blue"]), (".", C["text"])], touch)
    if location_lines:
        location(m, L, ["", "Downtown", "Main Street"], False, touch)
    if touch:
        thumbstick_hint(m, L)
        jump_button(m, L)
        circle_button(m, L["buttons"]["phone"], "Phone", "hud.phone")
        circle_button(m, L["buttons"]["map"], "Map", "hud.map")
    return m


def scene_driving(view):
    c = view["canvas"]
    L = view["layout"]
    touch = L["touch"]
    m = Mock(c["w"], c["h"])
    route = [(0, -240), (0, -300), (120, -300), (120, -360), (260, -360)]
    hud_base(m, view, {"blips": BLIPS + [((-40, -170), "hud.dot", C["red"], 8), ((70, -200), "hud.dot", C["blue"], 8)],
                       "bars": (0.8, 0.3, 0.6), "heading": 0, "face": 0, "zoom": 260, "route": route,
                       "wanted": True, "red": True})
    stars(m, L, 3, flashing_grey={1})
    cash(m, L, "$15,150")
    timer_bar(m, L, "DELIVERY", "1:42", True)
    objective(m, L, [("Lose the ", C["text"]), ("cops", C["red"]), (".", C["text"])], touch)
    location(m, L, ["Banshee", "Downtown", "Main Street"], True, touch)
    speed(m, L, 87)
    drift_line(m, L, 2.4)
    if touch:
        thumbstick_hint(m, L)
        b = L["buttons"]
        circle_button(m, b["nitro"], "Nitro", "hud.nitro")
        circle_button(m, b["drift"], "Drift", "hud.drift")
        circle_button(m, b["horn"], "Horn", "hud.horn")
        circle_button(m, b["exit"], "Exit", "hud.exit")
        circle_button(m, b["radio"], "Radio", "hud.signal")
        circle_button(m, b["phoneDriving"], "Phone", "hud.phone")
    else:
        # the radio station name shows top-centre for 3 s after a change
        r = L["radio"]
        m.text(r["x"] + r["w"] / 2, r["y"] + 12, "RADIO HOTWIRE", "Oswald-600", 18, rgba(C["text"]), anchor="mm",
               stroke=1, stroke_fill=(0, 0, 0, 160))
        m.text(r["x"] + r["w"] / 2, r["y"] + 33, "Night Drive (Instrumental)", "Montserrat-500", 14, rgba(C["dim"]),
               anchor="mm", stroke=1, stroke_fill=(0, 0, 0, 140))
    return m


JOB_ROWS = [("Contracts", None), ("Steal 3 sports cars", "2/3"), ("Deliver a car in under 60s", "DONE"),
            ("Lose a 3-star chase", "0/1"), ("Daily rewards", None), ("Day 3", "CLAIM"), ("Day 4", "TOMORROW"),
            ("Playtime gifts", None), ("10 minutes", "CLAIMED"), ("30 minutes", "12:04")]


def scene_pause(view):
    c = view["canvas"]
    L = view["layout"]
    touch = L["touch"]
    W, H = c["w"], c["h"]
    m = Mock(W, H)
    fr = view["pause"]
    left, right = fr["left"] * W, fr["right"] * W
    # title lock-up + player block, bottom-aligned just above the tabs (PauseMenu._build)
    base = (fr["tabs"] - 0.012) * H
    ts = 34 if not touch else 28
    m.text(left, base - 6, "HOTWIRE", "Kanit-900", ts, rgba(C["text"]), anchor="ls")
    tw = m.measure("HOTWIRE", "Kanit-900", ts)
    m.text(left + tw + 8, base - 2, "City", "Damion-400", ts, rgba(C["accent"]), anchor="ls")
    info_r = right - (60 if touch else 0)
    m.box(info_r - 46, base - 48, 46, 46, rgba(C["menu_hi"]))
    m.glyph("hud.person", info_r - 40, base - 42, 34, C["dim"])
    m.text(info_r - 54, base - 40, "Ayan", "Oswald-500", 16, rgba(C["text"]), anchor="rm")
    m.text(info_r - 54, base - 24, "SATURDAY 21:34", "Oswald-500", 15, rgba(C["dim"]), anchor="rm")
    m.text(info_r - 54, base - 9, "$15,150", "Oswald-500", 15, rgba(C["green"]), anchor="rm")
    if touch:
        m.blend_box(right - 48, 0.02 * H, 48, 48, (0, 0, 0, alpha_of(0.3)))
        m.text(right - 24, 0.02 * H + 24, "X", "Oswald-600", 24, rgba(C["text"]), anchor="mm")
    # tabs: desktop fills the row (26 px), touch is a scrolling row of 130 x 36 tabs
    tabs = ["MAP", "JOBS", "GARAGE", "STATS", "STORE", "SETTINGS"]
    gap = 3
    row_h = 30 if not touch else 40
    tab_h = 26 if not touch else 36
    tab_w = (right - left) / len(tabs) - gap if not touch else 130
    ty = fr["tabs"] * H + row_h - tab_h
    for i, name in enumerate(tabs):
        tx = left + i * (tab_w + gap)
        sel = name == "JOBS"
        if sel:
            m.box(tx, ty, tab_w, tab_h, rgba(C["text"]))
            m.box(tx, ty + tab_h - 3, tab_w, 3, rgba(C["accent"]))
        else:
            m.blend_box(tx, ty, tab_w, tab_h, (0, 0, 0, alpha_of(0.3)))
        m.text(tx + tab_w / 2, ty + tab_h / 2, name, "Oswald-600", 15 if not touch else 18,
               (0, 0, 0, 255) if sel else rgba(C["text"]), anchor="mm")
    # body: list (left 42%) + detail (right)
    top, bottom = fr["top"] * H, fr["bottom"] * H
    lw = (right - left) * 0.42
    row_h = 28 if not touch else 40
    y = top
    sel_index = 1
    for i, (label, value) in enumerate(JOB_ROWS):
        if y + row_h > bottom:
            break
        if value is None:
            m.blend_box(left, y, lw, row_h, (0, 0, 0, alpha_of(0.05)))
            m.text(left + 10, y + row_h / 2, label.upper(), "Oswald-500", 13, rgba(C["dim"]), anchor="lm")
        else:
            sel = i == sel_index
            if sel:
                m.box(left, y, lw, row_h, rgba(C["text"]))
            else:
                m.blend_box(left, y, lw, row_h, (0, 0, 0, alpha_of(0.35)))
            ink = (0, 0, 0, 255) if sel else rgba(C["text"])
            m.text(left + 10, y + row_h / 2, label, "Montserrat-500", 14, ink, anchor="lm")
            vcol = ink if sel else rgba(C["green"] if value in ("DONE", "CLAIM") else C["text"])
            m.text(left + lw - 10, y + row_h / 2, value, "Montserrat-600", 13, vcol, anchor="rm")
        y += row_h + 1
    dx = left + lw + 6
    dw = right - dx
    m.blend_box(dx, top, dw, bottom - top, (0, 0, 0, alpha_of(0.27)))
    m.text(dx + 16, top + 26, "Steal 3 sports cars", "Oswald-600", 22, rgba(C["text"]), anchor="lm")
    m.text(dx + 16, top + 52, "CONTRACT  ·  RESETS IN 6:12:40", "Oswald-500", 13, rgba(C["dim"]), anchor="lm")
    lay = Mock(W, H)
    lay.wrap_rich(dx + 16, top + 72, dw - 32, [("Hotwire any three ", C["text"]), ("Sports", C["blue"]),
                                                (" class cars and get them into your garage.", C["text"])],
                  "Montserrat-500", 14, 20)
    m.img.alpha_composite(lay.img)
    # progress bar + reward
    py = top + 140
    m.box(dx + 16, py, dw - 32, 6, rgba(C["menu_dark"]))
    m.box(dx + 16, py, (dw - 32) * 2 / 3, 6, rgba(C["accent"]))
    m.text(dx + 16, py + 24, "REWARD", "Oswald-500", 13, rgba(C["dim"]), anchor="lm")
    m.text(dx + dw - 16, py + 24, "$4,500", "Kanit-900", 20, rgba(C["green"]), anchor="rm")
    # footer instructional buttons (keyboard / gamepad only: touch taps the rows and the X)
    if not touch:
        instructional(m, right, bottom + 10 + 13, [("Enter", "Select"), ("Esc", "Back"), ("Q E", "Tab")])
    return m


def pause_backdrop(view):
    real = view["canvas"]["real"]
    b = backdrop(real[0], real[1]).filter(ImageFilter.GaussianBlur(8))
    b = Image.blend(b.convert("RGB"), Image.new("RGB", b.size, (0, 0, 0)), 0.55).convert("RGBA")
    return b


APPS = [("contacts", "Contacts"), ("jobs", "Jobs"), ("daily", "Daily"), ("gifts", "Gifts"), ("codes", "Codes"),
        ("camera", "Camera"), ("settings", "Settings"), ("map", "Map"), ("prestige", "Prestige")]


def phone(m, L):
    p = L["phone"]
    s = L["phoneScale"]
    W, H = 176, 330

    def X(v):
        return p["x"] + v * s

    def Y(v):
        return p["y"] + v * s

    # screen
    scr = Image.new("RGBA", (int((W - 12) * s * K), int((H - 38) * s * K)))
    for yy in range(scr.height):
        t = yy / scr.height
        col = tuple(int(a + (b - a) * t) for a, b in zip((44, 40, 58), (12, 12, 16)))
        ImageDraw.Draw(scr).line([(0, yy), (scr.width, yy)], fill=col + (255,))
    m.paste(scr, X(6), Y(16), (W - 12) * s, (H - 38) * s)
    # status row + title bar
    m.blend_box(X(6), Y(16), (W - 12) * s, 16 * s, (0, 0, 0, alpha_of(0.3)))
    m.text(X(6) + (W - 12) * s / 2, Y(24), "21:34", "Oswald-500", 11 * s, rgba(C["text"]), anchor="mm")
    m.glyph("hud.signal", X(12), Y(18), 12 * s, C["text"])
    m.glyph("hud.battery", X(W - 26), Y(18), 13 * s, C["text"])
    m.box(X(6), Y(32), (W - 12) * s, 24 * s, rgba(C["accent"]))
    m.text(X(14), Y(44), "Fone", "Oswald-600", 15 * s, (0, 0, 0, 255), anchor="lm")
    # 3x3 grid
    gx0, gy0 = 6 + 8, 60
    cw, chh = (W - 12 - 16) / 3, 70
    for i, (key, label) in enumerate(APPS):
        col, row = i % 3, i // 3
        cx = gx0 + col * cw + cw / 2
        cy = gy0 + row * chh
        if i == 1:
            m.blend_box(X(cx - 26), Y(cy - 2), 52 * s, 64 * s, rgba(C["accent"], alpha_of(0.15)), radius=6 * s)
        m.paste(sprite("apps." + key, 40 * s * K), X(cx - 20), Y(cy + 4), 40 * s, 40 * s)
        m.text(X(cx), Y(cy + 54), label, "Montserrat-500", 10 * s, rgba(C["text"]), anchor="mm")
        if key == "daily":
            m.circle(X(cx + 16), Y(cy + 6), 6 * s, rgba(C["red"]))
    # shell (9-slice approximated by a scaled image: the shell art is drawn for this aspect)
    shell = Image.open(os.path.join(ROOT, "assets", "ui", "phone_shell.png")).convert("RGBA")
    m.paste(shell, p["x"], p["y"], p["w"], p["h"])


def scene_phone(view):
    # HUDController.setPhoneOpen: the location lines hide; HudLayout.withPhone keeps cash / stars clear of the phone
    view = dict(view, layout=view.get("phoneLayout", view["layout"]))
    m = scene_rest(view, location_lines=False)
    L = view["layout"]
    phone(m, L)
    instructional(m, L["phone"]["x"] - 12, L["h"] - 24 if not L["touch"] else L["phone"]["y"] + 14,
                  [("Enter", "Open"), ("Backspace", "Back")] if not L["touch"] else [])
    return m


GEAR_ROWS = [("Nitro Tank", "Lv 2", "$1,500"), ("Laser Lock", "Lv 1", "$900"), ("Hotwire Kit", "Lv 3", "$2,200"),
             ("Cash Pad", "MAX", ""), ("Tow Hook", "Lv 0", "$600"), ("BONK Bat", "OWNED", ""),
             ("Stun Zapper", "", "$3,500"), ("Spike Strip", "", "$1,200")]


def scene_list(view):
    c = view["canvas"]
    L = view["layout"]
    touch = L["touch"]
    m = Mock(c["w"], c["h"])
    hud_base(m, view, {"blips": BLIPS, "bars": (1.0, 0.0, 0.85), "heading": 20, "face": 35})
    cash(m, L, "$15,150")
    r = L["list"]
    row_h = L["listRow"]
    if touch:
        x, w = 0, c["w"]
        y = c["h"] - r["h"]
        m.blend_box(x, y, w, r["h"], (0, 0, 0, alpha_of(0.15)))
        banner_h = 48
    else:
        x, y, w = r["x"], r["y"], r["w"]
        banner_h = 64
    # the header is the Accent band (ListMenu.BANNER_ART is off until per-shop key art exists)
    m.box(x, y, w, banner_h, rgba(C["accent"]))
    m.text(x + w / 2, y + banner_h / 2, "Gear", "Damion-400", 36 if not touch else 30, rgba(C["text"]),
           anchor="mm", stroke=1, stroke_fill=(0, 0, 0, 150))
    if touch:
        m.blend_box(x + w - 48, y + 4, 40, 40, (0, 0, 0, alpha_of(0.4)))
        m.text(x + w - 28, y + 24, "X", "Oswald-600", 22, rgba(C["text"]), anchor="mm")
    y += banner_h
    m.box(x, y, w, 24, (0, 0, 0, alpha_of(0.05)))
    m.text(x + 10, y + 12, "UPGRADES", "Oswald-500", 13, rgba(C["text"]), anchor="lm")
    m.text(x + w - 10, y + 12, "2/8", "Oswald-500", 13, rgba(C["text"]), anchor="rm")
    y += 24
    visible = 8 if not touch else view["sheet"]["rows"]
    for i, (label, lvl, price) in enumerate(GEAR_ROWS[:visible]):
        sel = i == 1
        if sel:
            m.box(x, y, w, row_h, rgba(C["text"]))
        else:
            m.blend_box(x, y, w, row_h, (0, 0, 0, alpha_of(0.35)))
        ink = (0, 0, 0, 255) if sel else rgba(C["text"])
        m.text(x + 10, y + row_h / 2, label, "Montserrat-500", 14 if not touch else 16, ink, anchor="lm")
        right = x + w - 10
        if price:
            m.text(right, y + row_h / 2, price, "Montserrat-600", 14 if not touch else 16,
                   ink if sel else rgba(C["green"]), anchor="rm")
            right -= m.measure(price, "Montserrat-600", 14 if not touch else 16) + 12
        if lvl:
            m.text(right, y + row_h / 2, lvl, "Montserrat-500", 13 if not touch else 15,
                   ink if sel else rgba(C["dim"]), anchor="rm")
        y += row_h
    m.box(x, y, w, 2, rgba(C["text"]))
    y += 2
    if not touch:
        lay = Mock(c["w"], c["h"])
        used = lay.wrap_rich(x + 10, y + 8, w - 20, [("How long your garage laser gate stays locked. ", C["text"]),
                                                       ("Lv 2: 90 s.", C["yellow"])], "Montserrat-500", 13, 18)
        m.blend_box(x, y, w, used + 16, (0, 0, 0, alpha_of(0.27)))
        m.img.alpha_composite(lay.img)
        instructional(m, c["w"] - 20, c["h"] - 24, [("Enter", "Buy"), ("Backspace", "Back"), ("Up Down", "Select")])
    else:
        # fixed two-line description, then the tappable Back / Select row (the rows scroll with a finger drag)
        spec = view["sheet"]["spec"]
        m.blend_box(x, y, w, spec["desc"], (0, 0, 0, alpha_of(0.27)))
        lay = Mock(c["w"], c["h"])
        lay.wrap_rich(x + 10, y + 6, w - 20, [("How long your garage laser gate stays locked. ", C["text"]),
                                              ("Lv 2: 90 s.", C["yellow"])], "Montserrat-500", 16, 20)
        m.img.alpha_composite(lay.img)
        y += spec["desc"]
        bx = w - 14
        for label in ("Select", "Back"):
            lw = m.measure(label, "Montserrat-500", 16) + 24
            bx -= lw
            m.blend_box(bx, y + 4, lw, spec["hints"] - 8, (0, 0, 0, alpha_of(0.3)))
            m.text(bx + lw / 2, y + spec["hints"] / 2, label, "Montserrat-500", 16, rgba(C["text"]), anchor="mm")
            bx -= 14
    return m


def scene_wasted(view):
    c = view["canvas"]
    real = view["canvas"]["real"]
    W, H = real
    m = Mock(W, H)  # the shard is full-screen (insets none): draw in real px
    cy, bh = 0.488 * H, 0.195 * H
    band = Image.open(os.path.join(ROOT, "assets", "ui", "shard_band.png")).convert("RGBA")
    # keystone band image is 0.23 H tall; centre on the band
    bh_img = 0.23 * H
    m.paste(band, 0, cy - bh_img / 2, W, bh_img)
    size = bh * 0.62
    m.text(W / 2, cy + size * 0.04, "wasted", "Kanit-900", size, rgba(C["wasted"]), anchor="mm", stroke=2,
           stroke_fill=(0, 0, 0, 255))
    # vignette
    vig = Image.open(os.path.join(ROOT, "assets", "ui", "vignette.png")).convert("RGBA")
    m.paste(vig, 0, 0, W, H)
    return m, c


def wasted_backdrop(view):
    real = view["canvas"]["real"]
    b = backdrop(real[0], real[1]).convert("RGB")
    g = ImageOps.grayscale(b).convert("RGB")
    g = ImageEnhance.Contrast(g).enhance(1.3)
    g = ImageEnhance.Brightness(g).enhance(0.92)
    return g.filter(ImageFilter.GaussianBlur(1.5)).convert("RGBA")


# ---------------------------------------------------------------------------------------------------------------------
def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "docs", "v2", "early", "ui")
    os.makedirs(out_dir, exist_ok=True)
    layout = load_layout()
    written = []
    for dev in ("desktop", "phone"):
        view = layout[dev]
        real = view["canvas"]["real"]
        for name, fn, back_fn in (("hud_rest", scene_rest, None), ("driving", scene_driving, None),
                                  ("pause", scene_pause, pause_backdrop), ("phone", scene_phone, None),
                                  ("list", scene_list, None)):
            back = back_fn(view) if back_fn else backdrop(real[0], real[1])
            m = fn(view)
            img = compose(view, m, back)
            roblox_topbar(img, view)
            path = os.path.join(out_dir, f"{name}_{dev}.png")
            img.convert("RGB").save(path, optimize=True)
            written.append(path)
        m, _ = scene_wasted(view)
        back = wasted_backdrop(view)
        ov = m.img.resize((real[0], real[1]), Image.LANCZOS)
        back.alpha_composite(ov)
        path = os.path.join(out_dir, f"wasted_{dev}.png")
        back.convert("RGB").save(path, optimize=True)
        written.append(path)
    for p in written:
        print("wrote", os.path.relpath(p, ROOT))


if __name__ == "__main__":
    main()
