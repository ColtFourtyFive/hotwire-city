#!/usr/bin/env python3
"""Loading-screen key art (gta_ui_language §5.14, §6) rendered from OUR cars: the carpipe GLBs (the roster the game
loads) staged on carpipe's golden-hour / wet-night street, inked with Freestyle and finished in PIL with a painterly
grade and the brand gradient. No traced or third-party art: every car is a carpipe output, every backdrop a CC0 HDRI
from carpipe's cache (see tools/blender/carpipe/_cache/SOURCES.txt).

    python3 -I tools/ui/keyart.py                       # all six panels -> assets/ui/loading_<n>.png (1920x1080)
    python3 -I tools/ui/keyart.py --panels 1,3 --res 960x540 --samples 24 --out /tmp/x   # quick look

Then `python3 -I tools/ui/build.py --no-render` uploads the changed PNGs as Image assets and rewrites
Config/UIAssets.luau.
"""
import argparse
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
CARPIPE = os.path.join(ROOT, "tools", "blender", "carpipe")
sys.path.insert(0, CARPIPE)

import bpy  # noqa: E402
from mathutils import Vector  # noqa: E402

from carpipe import render as R, util  # noqa: E402

GLB = os.path.join(CARPIPE, "out")

# Car paints (sRGB). Ignition Orange is the brand accent.
ORANGE = (0.98, 0.4, 0.1)
BLACK = (0.05, 0.055, 0.06)
WHITE = (0.84, 0.84, 0.82)
RED = (0.62, 0.04, 0.05)
SILVER = (0.55, 0.57, 0.6)
TEAL = (0.05, 0.38, 0.42)
YELLOW = (0.95, 0.72, 0.08)
PURPLE = (0.3, 0.12, 0.42)
DEEP_RED = (0.72, 0.05, 0.04)


def find_cache():
    """carpipe's _cache (HDRIs + textures) lives in the main checkout; worktrees point R.CACHE at it."""
    for d in (os.path.join(CARPIPE, "_cache"), os.path.join(os.path.expanduser("~"), "HotwireCity", "tools", "blender",
                                                             "carpipe", "_cache"),
              "/home/user/HotwireCity/tools/blender/carpipe/_cache"):
        if os.path.isdir(os.path.join(d, "hdri")):
            return d
    raise SystemExit("carpipe _cache not found: run tools/blender/carpipe/fetch_models.py first")


def car(name, offset=(0.0, 0.0), rot=0.0, paint=None, lights=False):
    path = os.path.join(GLB, name, name + ".glb")
    return R.load_glb(path, offset=(offset[0], offset[1], 0), rot_z=rot, paint=paint, lights_on=lights)


def look_at(pos, target, lens):
    return R.camera_lookat(Vector(pos), Vector(target), lens=lens)


def ink(thickness):
    """Freestyle ink outline: silhouettes, borders and sharp creases, near-black, constant width."""
    sc = bpy.context.scene
    sc.render.use_freestyle = True
    sc.render.line_thickness_mode = "ABSOLUTE"
    sc.render.line_thickness = thickness
    vl = bpy.context.view_layer
    vl.use_freestyle = True
    fs = vl.freestyle_settings
    fs.crease_angle = math.radians(128)
    ls = fs.linesets[0] if fs.linesets else fs.linesets.new("Ink")
    ls.select_by_visibility = True
    ls.visibility = "VISIBLE"
    ls.select_by_edge_types = True
    ls.select_silhouette = True
    ls.select_border = True
    ls.select_crease = True
    ls.select_contour = True
    ls.select_external_contour = True
    style = ls.linestyle
    if style is None:
        style = bpy.data.linestyles.new("Ink")
        ls.linestyle = style
    style.color = (0.03, 0.025, 0.04)
    style.thickness = thickness
    style.alpha = 0.85


# Each panel builds one scene. L = car length (studs); the street scales with it. Cars used: the carpipe outputs that
# are fully textured and carry no real brand marks (not camaro: untextured clay; not uaz452: a placeholder plate;
# not bmw27: its grille is a real brand mark).
def p1_sunset(L):
    """Ignition-orange supercar on the golden-hour avenue, traffic behind."""
    lane = L * 0.42
    cam = (lane * 2.3, L * 1.05, L * 0.13)
    R.street(L, night=False, keep_clear=(cam[0], cam[1]))
    car("goblin_supercar", (lane * 0.5, 0.0), paint=ORANGE)
    car("corrado", (lane * 1.5, -L * 1.5), paint=WHITE)
    car("canyon_taxi", (-lane * 0.5, -L * 2.3), rot=math.pi)
    car("fairheaven_lt", (-lane * 1.5, -L * 4.2), rot=math.pi, paint=PURPLE)
    look_at(cam, (lane * 0.15, -L * 0.3, L * 0.13), 30)


def p2_pursuit(L):
    """Night chase: a red muscle car with patrol cars on its tail, wet street, lights on."""
    lane = L * 0.42
    cam = (-lane * 2.2, L * 1.25, L * 0.09)
    R.street(L, night=True, keep_clear=(cam[0], cam[1]))
    car("musclecar", (lane * 0.5, 0.0), paint=DEEP_RED, lights=True)
    car("fairheaven_cop", (lane * 0.5, -L * 1.45), lights=True)
    car("fairheaven_cop", (lane * 1.5, -L * 3.1), lights=True)
    look_at(cam, (lane * 0.6, -L * 0.6, L * 0.12), 32)


def p3_downtown(L):
    """Golden-hour downtown at road level: a cab coming down the near lane, traffic both ways."""
    lane = L * 0.42
    cam = (lane * 0.1, L * 1.9, L * 0.12)
    R.street(L, night=False, keep_clear=(cam[0], cam[1]))
    car("canyon_taxi", (lane * 0.5, 0.0))
    car("corrado", (-lane * 0.5, -L * 2.2), rot=math.pi, paint=SILVER)
    car("fairheaven_lt", (lane * 1.5, -L * 2.6), paint=PURPLE)
    car("carconcept", (-lane * 1.5, -L * 4.6), rot=math.pi, paint=WHITE)
    look_at(cam, (lane * 0.45, -L * 0.6, L * 0.14), 32)


def p4_night_cruise(L):
    """Night cruise: a red concept car, headlights on, oncoming traffic on the wet asphalt."""
    lane = L * 0.42
    cam = (lane * 1.45, L * 1.45, L * 0.08)
    R.street(L, night=True, keep_clear=(cam[0], cam[1]))
    car("carconcept", (lane * 0.5, 0.0), paint=RED, lights=True)
    car("canyon_taxi", (-lane * 0.5, -L * 2.0), rot=math.pi, lights=True)
    car("fairheaven_lt", (-lane * 1.5, -L * 3.8), rot=math.pi, paint=SILVER, lights=True)
    look_at(cam, (lane * 0.3, -L * 0.45, L * 0.13), 30)


def p5_getaway(L):
    """The getaway: a red coupe pulling away from two patrol cars at sunset, seen from behind the cops."""
    lane = L * 0.42
    cam = (-lane * 1.6, -L * 4.6, L * 0.13)
    R.street(L, night=False, keep_clear=(cam[0], cam[1]))
    car("corrado", (lane * 0.5, 0.0), paint=RED)
    car("fairheaven_cop", (lane * 1.5, -L * 1.6))
    car("fairheaven_cop", (lane * 0.5, -L * 2.9))
    look_at(cam, (lane * 0.6, -L * 0.8, L * 0.12), 32)


def p6_heavy(L):
    """A work van at golden hour, low across the road, a supercar slipping past behind it."""
    lane = L * 0.42
    cam = (-lane * 2.9, L * 0.4, L * 0.09)
    R.street(L, night=False, keep_clear=(cam[0], cam[1]))
    car("shvan_van", (lane * 0.5, 0.0), paint=YELLOW)
    car("goblin_supercar", (lane * 1.5, -L * 1.9), paint=BLACK)
    car("canyon_taxi", (-lane * 0.5, -L * 3.0), rot=math.pi)
    look_at(cam, (lane * 0.7, -L * 0.45, L * 0.14), 28)


PANELS = {1: p1_sunset, 2: p2_pursuit, 3: p3_downtown, 4: p4_night_cruise, 5: p5_getaway, 6: p6_heavy}


def finish(raw, out, night):
    """Painterly finish: a light mode filter (flattens texture noise into painted patches), punchier colour, a brand
    gradient wash (orange low, violet high) and a soft vignette."""
    from PIL import Image, ImageChops, ImageEnhance, ImageFilter

    im = Image.open(raw).convert("RGB")
    w, h = im.size
    im = im.filter(ImageFilter.MedianFilter(size=3 if w < 1400 else 5))
    im = ImageEnhance.Color(im).enhance(1.28 if not night else 1.15)
    im = ImageEnhance.Contrast(im).enhance(1.12)
    # brand gradient wash, screen-blended: Ignition Orange at the horizon, violet at the top
    grad = Image.new("RGB", (1, h))
    top, low = (70, 36, 110), (255, 138, 61)
    for y in range(h):
        t = min(1.0, max(0.0, (y / h - 0.1) / 0.6))
        grad.putpixel((0, y), tuple(int(top[i] + (low[i] - top[i]) * t) for i in range(3)))
    grad = grad.resize((w, h))
    wash = ImageChops.screen(im, grad)
    im = Image.blend(im, wash, 0.16 if not night else 0.1)
    # vignette
    mask = Image.new("L", (w, h), 0)
    px = mask.load()
    for y in range(0, h, 4):
        for x in range(0, w, 4):
            dx, dy = (x / w - 0.5) * 1.6, (y / h - 0.5) * 1.9
            v = int(max(0.0, min(1.0, (dx * dx + dy * dy - 0.35) / 0.9)) * 150)
            for yy in range(y, min(y + 4, h)):
                for xx in range(x, min(x + 4, w)):
                    px[xx, yy] = v
    mask = mask.filter(ImageFilter.GaussianBlur(8))
    im = Image.composite(Image.new("RGB", (w, h), (8, 6, 12)), im, mask)
    im.save(out, optimize=True)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--panels", default="1,2,3,4,5,6")
    ap.add_argument("--res", default="1920x1080")
    ap.add_argument("--samples", type=int, default=40)
    ap.add_argument("--out", default=os.path.join(ROOT, "assets", "ui"))
    a = ap.parse_args()
    R.CACHE = find_cache()
    res = tuple(int(x) for x in a.res.split("x"))
    os.makedirs(a.out, exist_ok=True)
    L = 17.0
    for n in (int(x) for x in a.panels.split(",")):
        build = PANELS[n]
        util.reset_scene()
        R.setup_cycles(samples=a.samples, res=res)
        build(L)
        ink(max(1.0, res[0] / 900))
        raw = os.path.join(a.out, f"_raw_loading_{n}.png")
        R.render_to(raw)
        night = build in (p2_pursuit, p4_night_cruise)
        finish(raw, os.path.join(a.out, f"loading_{n}.png"), night)
        os.remove(raw)
        print(f"panel {n} done", flush=True)


if __name__ == "__main__":
    main()
