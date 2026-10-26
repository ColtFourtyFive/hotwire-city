#!/usr/bin/env python3
"""Render a JSON part dump (from tools/dump.luau) to a PNG preview.

Usage: python3 tools/render.py parts.json out.png [--views iso,iso2,top,side,front] [--size 900]

Shapes: Block, Wedge (Roblox WedgePart: slope rises from front -Z bottom to back +Z top),
CornerWedge (approximated), Cylinder (axis along X), Ball. Transparent parts (>=0.95) are skipped.
Painter's algorithm per face with simple directional shading. Good enough to judge silhouettes/layout.
"""
import json
import math
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont


def box_faces(sx, sy, sz):
    x, y, z = sx / 2, sy / 2, sz / 2
    v = np.array([[-x, -y, -z], [x, -y, -z], [x, y, -z], [-x, y, -z],
                  [-x, -y, z], [x, -y, z], [x, y, z], [-x, y, z]])
    faces = [[0, 1, 2, 3], [5, 4, 7, 6], [4, 0, 3, 7], [1, 5, 6, 2], [3, 2, 6, 7], [4, 5, 1, 0]]
    return [v[f] for f in faces]


def wedge_faces(sx, sy, sz):
    x, y, z = sx / 2, sy / 2, sz / 2
    a, b = [-x, -y, -z], [x, -y, -z]
    c, d = [x, -y, z], [-x, -y, z]
    e, f = [x, y, z], [-x, y, z]
    return [np.array(p) for p in [[a, b, c, d], [d, c, e, f], [a, b, e, f], [a, d, f], [b, c, e]]]


def cylinder_faces(sx, sy, sz, n=14):
    r = min(sy, sz) / 2
    h = sx / 2
    ring = [(r * math.cos(2 * math.pi * i / n), r * math.sin(2 * math.pi * i / n)) for i in range(n)]
    faces = []
    faces.append(np.array([[-h, py, pz] for py, pz in ring]))
    faces.append(np.array([[h, py, pz] for py, pz in ring]))
    for i in range(n):
        (y1, z1), (y2, z2) = ring[i], ring[(i + 1) % n]
        faces.append(np.array([[-h, y1, z1], [h, y1, z1], [h, y2, z2], [-h, y2, z2]]))
    return faces


def ball_faces(sx, sy, sz, n=10):
    r = min(sx, sy, sz) / 2
    faces = []
    for i in range(n):
        t1, t2 = math.pi * i / n - math.pi / 2, math.pi * (i + 1) / n - math.pi / 2
        for j in range(n):
            p1, p2 = 2 * math.pi * j / n, 2 * math.pi * (j + 1) / n
            pts = []
            for t, p in [(t1, p1), (t1, p2), (t2, p2), (t2, p1)]:
                pts.append([r * math.cos(t) * math.cos(p), r * math.sin(t), r * math.cos(t) * math.sin(p)])
            faces.append(np.array(pts))
    return faces


def part_faces(part):
    sx, sy, sz = part["size"]
    shape = part.get("shape", "Block")
    if shape == "Wedge" or shape == "CornerWedge":
        local = wedge_faces(sx, sy, sz)
    elif shape == "Cylinder":
        local = cylinder_faces(sx, sy, sz)
    elif shape == "Ball":
        local = ball_faces(sx, sy, sz)
    else:
        local = box_faces(sx, sy, sz)
    c = part["cframe"]
    pos = np.array(c[0:3])
    rot = np.array([[c[3], c[4], c[5]], [c[6], c[7], c[8]], [c[9], c[10], c[11]]])
    return [(f @ rot.T) + pos for f in local]


def view_matrix(name):
    # returns (R, light) where R maps world -> camera (x right, y up, z toward camera)
    if name == "top":
        R = np.array([[1, 0, 0], [0, 0, -1], [0, 1, 0]], dtype=float)  # look down -Y, +Z is down on image
    elif name == "side":
        R = np.array([[0, 0, 1], [0, 1, 0], [-1, 0, 0]], dtype=float)  # look along -X... shows Z horizontal
    elif name == "front":
        R = np.array([[-1, 0, 0], [0, 1, 0], [0, 0, -1]], dtype=float)  # camera in front (-Z side) looking +Z
    else:
        yaw = math.radians(-135 if name == "iso" else 45)
        pitch = math.radians(30)
        cy, sy_ = math.cos(yaw), math.sin(yaw)
        Ry = np.array([[cy, 0, sy_], [0, 1, 0], [-sy_, 0, cy]])
        cp, sp = math.cos(pitch), math.sin(pitch)
        Rx = np.array([[1, 0, 0], [0, cp, -sp], [0, sp, cp]])
        R = Rx @ Ry
    return R


def render_view(parts, name, size, title):
    R = view_matrix(name)
    light = np.array([0.4, 0.85, 0.35])
    light = light / np.linalg.norm(light)
    polys = []
    for part in parts:
        if part.get("transparency", 0) >= 0.95:
            continue
        col = np.array(part["color"], dtype=float)
        alpha = 1 - part.get("transparency", 0)
        neon = part.get("material") == "Neon"
        for f in part_faces(part):
            if len(f) < 3:
                continue
            n = np.cross(f[1] - f[0], f[2] - f[0])
            ln = np.linalg.norm(n)
            if ln < 1e-9:
                continue
            n = n / ln
            cam = f @ R.T
            nc = R @ n
            if nc[2] < 0:  # winding-agnostic: make the normal face the camera
                n = -n
            shade = 1.0 if neon else 0.45 + 0.55 * max(0.0, float(np.dot(n, light)))
            c = np.clip(col * shade, 0, 255)
            polys.append((float(cam[:, 2].mean()), cam[:, :2], tuple(int(x) for x in c), alpha))
    if not polys:
        img = Image.new("RGB", (size, size), (30, 32, 50))
        return img
    allpts = np.concatenate([p[1] for p in polys])
    mn, mx = allpts.min(axis=0), allpts.max(axis=0)
    span = max(mx[0] - mn[0], mx[1] - mn[1], 1e-6)
    margin = 30
    scale = (size - 2 * margin) / span
    cx = (mn[0] + mx[0]) / 2
    cy = (mn[1] + mx[1]) / 2
    img = Image.new("RGB", (size, size), (34, 38, 60))
    draw = ImageDraw.Draw(img, "RGBA")
    polys.sort(key=lambda p: p[0])
    for _, pts, c, a in polys:
        xy = [(size / 2 + (p[0] - cx) * scale, size / 2 - (p[1] - cy) * scale) for p in pts]
        draw.polygon(xy, fill=c + (int(255 * a),), outline=(0, 0, 0, 60))
    draw.text((10, 8), f"{title} [{name}]  span={span:.1f} studs", fill=(255, 255, 255))
    return img


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    src, out = sys.argv[1], sys.argv[2]
    views = ["iso", "iso2", "top", "side"]
    size = 700
    args = sys.argv[3:]
    for i, a in enumerate(args):
        if a == "--views":
            views = args[i + 1].split(",")
        if a == "--size":
            size = int(args[i + 1])
    data = json.load(open(src))
    groups = data if isinstance(data, dict) and "groups" in data else {"groups": [{"title": src, "parts": data}]}
    rows = []
    for g in groups["groups"]:
        imgs = [render_view(g["parts"], v, size, g["title"]) for v in views]
        row = Image.new("RGB", (size * len(imgs), size))
        for i, im in enumerate(imgs):
            row.paste(im, (i * size, 0))
        rows.append(row)
    sheet = Image.new("RGB", (rows[0].width, size * len(rows)))
    for i, r in enumerate(rows):
        sheet.paste(r, (0, i * size))
    sheet.save(out)
    print(f"wrote {out} ({sheet.width}x{sheet.height}), groups={len(rows)}")


if __name__ == "__main__":
    main()
