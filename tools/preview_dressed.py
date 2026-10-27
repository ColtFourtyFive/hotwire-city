#!/usr/bin/env python3
"""Render the DRESSED city (art pass AP2) without Roblox.

  python3 tools/preview_dressed.py [--json slots.json] [--out docs/previews] [--views top,iso_sw,...] [--fallback]

1. Runs `lune run tools/dump.luau mapslots` (MapBuilder.build + buildTerrain in the Lune harness) unless --json given.
2. Replaces every AssetSlot with its kit GLB (assets/kit/... / assets/hero/..., found through Config/Assets ids and the
   manifests), decimated to ~500 triangles (~1600 near close-up cameras; cached in /tmp/claude-0/preview_cache),
   normalized exactly like AssetLibrary._normalize (yaw, bottom-center root, fit), scaled by Fit / size, turned by the
   slot Yaw and placed on the slot pivot. Slots without a local GLB (Creator Store roles) keep their placeholder.
3. Remaining procedural parts are drawn as-is, Billboard boards get their ad image (the one MapDresser picks), the
   logo sign gets the logo, terrain FillBlocks become water / grass.
4. Writes docs/previews/dressed_{top,iso_sw,iso_ne,downtown,beach,plaza}.png (--fallback renders the procedural city
   instead, to dressed_fallback_*.png).
"""
import argparse
import json
import math
import os
import subprocess
import sys
import time

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kitgeo import Kit, image_files, yaw_matrix  # noqa: E402
from raster import Camera, part_triangles, render  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP = "/tmp/claude-0"

# (eye, target, fov) street-level close-ups; ortho views take (direction, center, span)
VIEWS = {
    "top": ("ortho", (0.0001, -1, 0.0002), (0, 0, 0), 1960, (1600, 1600)),
    "iso_sw": ("ortho", (0.62, -0.62, -0.48), (-40, 30, 40), 1900, (1800, 1100)),
    "iso_ne": ("ortho", (-0.6, -0.56, 0.58), (40, 30, -40), 1900, (1800, 1100)),
    "downtown": ("persp", (-215, 9, 128), (-40, 70, -60), 68, (1600, 1000)),
    "beach": ("persp", (520, 7, 846), (180, 14, 780), 62, (1600, 1000)),
    "plaza": ("persp", (-10, 7, 128), (-135, 16, 60), 64, (1600, 1000)),
}
HI_RES_RADIUS = 260


def cf_matrix(c):
    pos = np.array(c[0:3], dtype=float)
    rot = np.array([[c[3], c[4], c[5]], [c[6], c[7], c[8]], [c[9], c[10], c[11]]], dtype=float)
    return pos, rot


def lerp_color(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


class Scene:
    def __init__(self, data, kit, fallback=False):
        self.data = data
        self.kit = kit
        self.fallback = fallback
        self.images = image_files()
        self._img_cache = {}
        self.dressed = set()  # slot indices (1-based) replaced by a mesh
        if not fallback:
            for i, s in enumerate(data["slots"], start=1):
                if s["key"] and kit.glb_of(s["category"], s["key"]):
                    self.dressed.add(i)

    # ---- batches -------------------------------------------------------------------------------------------
    def part_batch(self):
        tris, cols, flags, alpha = [], [], [], []
        for p in self.data["parts"]:
            if p["slot"] in self.dressed:
                continue
            t = p.get("transparency", 0)
            if t >= 0.95:
                continue
            tr = part_triangles(p)
            tris.append(tr)
            col = np.array(p["color"], dtype=np.float32)
            mat = p.get("material", "")
            if mat == "Grass":
                col = col * 0.92
            cols.append(np.tile(col, (len(tr), 1)))
            flags.append(np.full(len(tr), 1 if mat == "Neon" else 0, np.int8))
            alpha.append(np.full(len(tr), 1.0 - t if t > 0.05 else 1.0, np.float32))
        return {"tris": np.concatenate(tris), "colors": np.concatenate(cols), "flags": np.concatenate(flags),
                "alpha": np.concatenate(alpha)}

    def slot_batch(self, cam_pos=None):
        tris, cols = [], []
        for i, s in enumerate(self.data["slots"], start=1):
            if i not in self.dressed:
                continue
            pos, rot = cf_matrix(s["cframe"])
            faces = 500
            if cam_pos is not None and np.linalg.norm(pos - cam_pos) < HI_RES_RADIUS:
                faces = 1600
            mesh = self.kit.preview(s["category"], s["key"], faces)
            d = self.kit.def_of(s["category"], s["key"])
            k = (s["fit"] or d["size"]) / d["size"]
            local = mesh["tris"].astype(np.float64) * k
            if s.get("yaw"):
                local = local @ yaw_matrix(s["yaw"]).T
            tris.append(local @ rot.T + pos)
            cols.append(mesh["colors"])
        if not tris:
            return None
        return {"tris": np.concatenate(tris), "colors": np.concatenate(cols)}

    def _image(self, content):
        cid = content.replace("rbxassetid://", "")
        if cid not in self._img_cache:
            path = self.images.get(cid)
            self._img_cache[cid] = np.asarray(Image.open(path).convert("RGB").resize((48, 27))) if path else None
        return self._img_cache[cid]

    def textured_quad(self, cframe, size, content, back):
        """Grid of colored quads on the Front (-Z) and optionally Back (+Z) face of a board."""
        img = self._image(content)
        if img is None:
            return None
        pos, rot = cf_matrix(cframe)
        sx, sy, sz = size
        h, w = img.shape[:2]
        tris, cols = [], []
        for face, zsign in (("front", -1), ("back", 1)):
            if face == "back" and not back:
                continue
            z = zsign * (sz / 2 + 0.03)
            for r in range(h):
                for c in range(w):
                    u0, u1 = c / w, (c + 1) / w
                    v0, v1 = r / h, (r + 1) / h
                    # image left->right maps to -X..+X seen from the front (camera at -Z looks +Z: +X is screen left)
                    xa = (0.5 - u0) * sx if face == "front" else (u0 - 0.5) * sx
                    xb = (0.5 - u1) * sx if face == "front" else (u1 - 0.5) * sx
                    ya, yb = (0.5 - v0) * sy, (0.5 - v1) * sy
                    q = np.array([[xa, ya, z], [xb, ya, z], [xb, yb, z], [xa, yb, z]])
                    tris.append(q[[0, 1, 2]])
                    tris.append(q[[0, 2, 3]])
                    col = img[r, c].astype(np.float32)
                    cols.append(col)
                    cols.append(col)
        tris = np.array(tris) @ rot.T + pos
        return {"tris": tris, "colors": np.array(cols), "flags": np.ones(len(tris), np.int8)}

    def board_batches(self):
        out = []
        if not self.fallback:
            for b in self.data["boards"]:
                if b.get("image"):
                    q = self.textured_quad(b["cframe"], b["size"], b["image"], b["back"])
                    if q:
                        out.append(q)
        for b in self.data.get("images", []):
            q = self.textured_quad(b["cframe"], b["size"], b["image"], True)
            if q:
                out.append(q)
        return out

    def terrain_batch(self):
        tris, cols, alpha = [], [], []
        # ocean: one big tessellated plane at water level
        lvl = -2.0
        n = 24
        ext = 1800
        g = np.linspace(-ext, ext, n + 1)
        for i in range(n):
            for j in range(n):
                x0, x1, z0, z1 = g[i], g[i + 1], g[j], g[j + 1]
                q = np.array([[x0, lvl, z0], [x1, lvl, z0], [x1, lvl, z1], [x0, lvl, z1]])
                tris += [q[[0, 1, 2]], q[[0, 2, 3]]]
                cols += [(40, 186, 222)] * 2
                alpha += [1.0, 1.0]
        for op in self.data.get("terrain", []):
            if op["material"] != "Grass":
                continue
            pos, rot = cf_matrix(op["cframe"])
            sx, sy, sz = op["size"]
            top = pos[1] + sy / 2
            # rendered terrain surface lands a little under the fill top (partial voxel occupancy)
            y = top - 0.3
            nx = max(1, int(sx // 8))
            nz = max(1, int(sz // 8))
            xs = np.linspace(pos[0] - sx / 2, pos[0] + sx / 2, nx + 1)
            zs = np.linspace(pos[2] - sz / 2, pos[2] + sz / 2, nz + 1)
            rng = np.random.default_rng(7)
            for i in range(nx):
                for j in range(nz):
                    q = np.array([[xs[i], y, zs[j]], [xs[i + 1], y, zs[j]], [xs[i + 1], y, zs[j + 1]], [xs[i], y, zs[j + 1]]])
                    tint = rng.uniform(0.9, 1.06)
                    c = (min(255, 92 * tint), min(255, 180 * tint), min(255, 72 * tint))
                    tris += [q[[0, 1, 2]], q[[0, 2, 3]]]
                    cols += [c, c]
                    alpha += [1.0, 1.0]
        return {"tris": np.array(tris, dtype=float), "colors": np.array(cols, dtype=np.float32),
                "alpha": np.array(alpha, dtype=np.float32)}


def make_camera(view):
    kind = view[0]
    if kind == "ortho":
        _, d, center, span, size = view
        up = (0, 0, -1) if abs(d[1]) > 0.99 else (0, 1, 0)
        return Camera.ortho(d, center, span, up=up), size, None
    _, eye, target, fov, size = view
    return Camera.persp(eye, target, fov), size, np.array(eye, dtype=float)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json")
    ap.add_argument("--out", default=os.path.join(ROOT, "docs/previews"))
    ap.add_argument("--views", default=",".join(VIEWS))
    ap.add_argument("--fallback", action="store_true")
    ap.add_argument("--ss", type=int, default=2)
    args = ap.parse_args()

    src = args.json
    if not src:
        os.makedirs(TMP, exist_ok=True)
        src = os.path.join(TMP, "mapslots.json")
        t0 = time.time()
        res = subprocess.run(["lune", "run", "tools/dump.luau", "mapslots", src], cwd=ROOT, capture_output=True, text=True)
        print(res.stdout.strip().splitlines()[-2] if res.stdout else res.stderr[-2000:])
        if res.returncode != 0:
            print(res.stderr)
            sys.exit(1)
        print(f"dump {time.time() - t0:.1f}s")
    data = json.load(open(src))
    kit = Kit()
    scene = Scene(data, kit, fallback=args.fallback)
    missing = sorted({s["key"] or s["role"] for i, s in enumerate(data["slots"], start=1) if i not in scene.dressed})
    print(f"slots {len(data['slots'])}: {len(scene.dressed)} dressed with GLBs; placeholder kept for: {', '.join(missing)}")
    t0 = time.time()
    base = [scene.part_batch(), scene.terrain_batch()] + scene.board_batches()
    print(f"scene batches {time.time() - t0:.1f}s")
    prefix = "dressed_fallback_" if args.fallback else "dressed_"
    for name in args.views.split(","):
        view = VIEWS[name]
        cam, (W, H), cam_pos = make_camera(view)
        t0 = time.time()
        batches = list(base)
        sb = scene.slot_batch(cam_pos)
        if sb:
            batches.append(sb)
        haze = None if view[0] == "ortho" else (500, 2600)
        img = render(batches, cam, W, H, ss=args.ss, haze=haze)
        d = ImageDraw.Draw(img)
        label = f"Hotwire City {'fallback (procedural)' if args.fallback else 'dressed'} - {name}"
        d.text((12, 10), label, fill=(20, 20, 30))
        d.text((11, 9), label, fill=(255, 255, 255))
        out = os.path.join(args.out, f"{prefix}{name}.png")
        img.save(out)
        print(f"wrote {out} ({time.time() - t0:.1f}s)")


if __name__ == "__main__":
    main()
