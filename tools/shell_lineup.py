#!/usr/bin/env python3
"""Hero-shell lineup QA render (docs/ART_PASS.md AP1).

Usage: python3 tools/shell_lineup.py out.png [carId ...] [--size 360] [--cols 2]

For each car: reads the GLB named by assets/hero/manifest.json or assets/kit/cars.json, dumps its native bounds,
runs tools/shell_lineup.luau (the real AssetLibrary._normalize + CarBuilder.applyShell in the Lune harness), then maps
the GLB triangles into the dumped shell MeshPart and renders, per car: procedural side | shell side | procedural iso |
shell iso, at one shared scale per car. Shell panels overlay the ground plane (y = 0), the physics wheels (white
outlines), what stays visible next to the shell (police sirens) and a seated driver's head (orange ring, side view).
"""
import json
import math
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from glb_preview import collect, load_glb  # noqa: E402
from render import part_faces  # noqa: E402

DEFAULT = ["police_unit", "yellow_cab", "stretch_limo", "bigfoot", "rubber_ducky", "toilet_turbo", "pizza_van",
           "hyperion_x"]
LIGHT = np.array([0.4, 0.85, 0.35]) / np.linalg.norm([0.4, 0.85, 0.35])
BG = (30, 33, 52)
HEAD_ABOVE_SEAT = 2.6  # seated R15 head center above the seat top (studs)


def manifests():
    m = json.load(open(os.path.join(ROOT, "assets/hero/manifest.json")))
    m.update(json.load(open(os.path.join(ROOT, "assets/kit/cars.json"))))
    return m


def view_matrix(name):
    if name == "side":  # camera on +X looking -X: Z runs horizontally (front -Z on the left)
        return np.array([[0, 0, 1], [0, 1, 0], [-1, 0, 0]], dtype=float)
    yaw, pitch = math.radians(-135), math.radians(28)
    cy, sy = math.cos(yaw), math.sin(yaw)
    ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    cp, sp = math.cos(pitch), math.sin(pitch)
    rx = np.array([[1, 0, 0], [0, cp, -sp], [0, sp, cp]])
    return rx @ ry


def cf_parts(c):
    pos = np.array(c[0:3], dtype=float)
    rot = np.array([[c[3], c[4], c[5]], [c[6], c[7], c[8]], [c[9], c[10], c[11]]], dtype=float)
    return pos, rot


def shell_triangles(glb_tris, shell):
    (mn, mx) = shell["native"]
    mn, mx = np.array(mn), np.array(mx)
    nsize = np.maximum(mx - mn, 1e-9)
    size = np.array(shell["size"])
    pos, rot = cf_parts(shell["cframe"])
    local = (glb_tris - (mn + mx) / 2) * (size / nsize)
    return local @ rot.T + pos


def part_polys(parts):
    polys = []
    for p in parts:
        if p.get("transparency", 0) >= 0.95:
            continue
        col = np.array(p["color"], dtype=float)
        neon = p.get("material") == "Neon"
        for f in part_faces(p):
            polys.append((f, col, neon))
    return polys


class Panel:
    def __init__(self, size, view, center, scale):
        self.size, self.R, self.center, self.scale = size, view_matrix(view), center, scale
        self.img = Image.new("RGB", (size, size), BG)
        self.draw = ImageDraw.Draw(self.img, "RGBA")
        self.items = []

    def to_px(self, pts):
        cam = (pts - self.center) @ self.R.T
        return [(self.size / 2 + q[0] * self.scale, self.size / 2 - q[1] * self.scale) for q in cam], cam

    def add(self, face, col, neon=False, outline=(0, 0, 0, 50)):
        n = np.cross(face[1] - face[0], face[2] - face[0])
        ln = np.linalg.norm(n)
        if ln < 1e-12:
            return
        n /= ln
        if (self.R @ n)[2] < 0:
            n = -n
        shade = 1.0 if neon else 0.5 + 0.5 * max(0.0, float(n @ LIGHT))
        xy, cam = self.to_px(face)
        c = tuple(int(v) for v in np.clip(col * shade, 0, 255))
        self.items.append((float(cam[:, 2].mean()), xy, c, outline))

    def flush(self):
        self.items.sort(key=lambda it: it[0])
        for _, xy, c, outline in self.items:
            self.draw.polygon(xy, fill=c + (255,), outline=outline)
        self.items = []

    def ground(self):
        y = self.to_px(np.array([[0, 0, 0]], dtype=float))[0][0][1]
        self.draw.line([(0, y), (self.size, y)], fill=(120, 130, 160, 255), width=1)

    def circle(self, center, r, color, width=2):
        xy, _ = self.to_px(np.array([center], dtype=float))
        x, y = xy[0]
        rr = r * self.scale
        self.draw.ellipse([x - rr, y - rr, x + rr, y + rr], outline=color, width=width)

    def text(self, xy, s, fill=(255, 255, 255)):
        self.draw.text(xy, s, fill=fill)


def render_car(car, tris, cols, size):
    proc = car["procedural"]
    world = shell_triangles(tris, car["shell"])
    pts = np.concatenate([np.concatenate(part_faces(p)) for p in proc if p["transparency"] < 0.95] + [world.reshape(-1, 3)])
    mn, mx = pts.min(0), pts.max(0)
    center = (mn + mx) / 2
    span = max(mx - mn) * 1.08
    scale = (size - 30) / span
    panels = []
    a = car["attrs"]
    for view in ("side", "iso"):
        p1 = Panel(size, view, center, scale)
        for f, col, neon in part_polys(proc):
            p1.add(f, col, neon)
        p1.flush()
        if view == "side":
            p1.ground()
        p1.text((8, 6), f"{car['key']} procedural [{view}]")
        p1.text((8, size - 18), f"L {a['Length']:.2f}  W {a['Width']:.2f}  H {a['Height']:.2f}", (190, 200, 230))

        p2 = Panel(size, view, center, scale)
        shade_cols = cols
        for i in range(len(world)):
            p2.add(world[i], shade_cols[i], outline=None)
        for f, col, neon in part_polys(car["extras"]):
            p2.add(f, col, neon)
        p2.flush()
        if view == "side":
            p2.ground()
            for w in car["wheels"]:
                if w["pos"][0] > 0:  # near side (camera on +X)
                    p2.circle(w["pos"], w["r"], (255, 255, 255, 200), 1)
            if car.get("seatTop"):
                s = car["seatTop"]
                p2.circle([s[0], s[1] + HEAD_ABOVE_SEAT, s[2]], 0.6, (255, 150, 40, 255), 2)
        p2.text((8, 6), f"{car['key']} shell [{view}]")
        p2.text((8, size - 18), f"scale {a['ShellScale']:.3f}  roof {a['ShellHeight']:.2f}", (190, 200, 230))
        panels.append((p1.img, p2.img))
    row = Image.new("RGB", (size * 4, size), BG)
    row.paste(panels[0][0], (0, 0))
    row.paste(panels[0][1], (size, 0))
    row.paste(panels[1][0], (size * 2, 0))
    row.paste(panels[1][1], (size * 3, 0))
    d = ImageDraw.Draw(row)
    for x in (size, size * 2, size * 3):
        d.line([(x, 0), (x, size)], fill=(60, 66, 96), width=1 if x != size * 2 else 3)
    return row


def main():
    args = sys.argv[1:]
    out = args[0]
    size, cols = 360, 1
    keys = []
    i = 1
    while i < len(args):
        if args[i] == "--size":
            size = int(args[i + 1])
            i += 2
        elif args[i] == "--cols":
            cols = int(args[i + 1])
            i += 2
        else:
            keys.append(args[i])
            i += 1
    keys = keys or DEFAULT
    man = manifests()
    meshes, bounds = {}, {}
    for k in keys:
        js, binc = load_glb(os.path.join(ROOT, man[k]["file"]))
        tris, colors, _ = collect(js, binc)
        p = tris.reshape(-1, 3)
        meshes[k] = (tris, colors)
        bounds[k] = {"min": p.min(0).tolist(), "max": p.max(0).tolist()}
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = os.path.join(tmp, "in.json"), os.path.join(tmp, "out.json")
        json.dump(bounds, open(src, "w"))
        subprocess.run(["lune", "run", "tools/shell_lineup.luau", src, dst], cwd=ROOT, check=True)
        data = json.load(open(dst))
    by_key = {c["key"]: c for c in data["cars"]}
    rows = [render_car(by_key[k], *meshes[k], size) for k in keys]
    nrows = math.ceil(len(rows) / cols)
    sheet = Image.new("RGB", (rows[0].width * cols + (cols - 1) * 6, nrows * size + (nrows - 1) * 6), (12, 14, 24))
    for idx, r in enumerate(rows):
        sheet.paste(r, ((idx % cols) * (r.width + 6), (idx // cols) * (size + 6)))
    sheet.save(out)
    print(f"wrote {out} ({sheet.width}x{sheet.height})")


if __name__ == "__main__":
    main()
