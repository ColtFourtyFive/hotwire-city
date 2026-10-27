#!/usr/bin/env python3
"""Dressed previews of a garage / the dealership showroom (art pass AP2b).

Every AssetSlot / LootSlot placeholder and every display car in a tools/dump_dressing.luau dump is swapped for its
decimated kit GLB (tools/kitgeo.py reproduces AssetLibrary._normalize: yaw, bottom-center root, fit scale; the slot's
numeric Fit rescales like MapDresser / PlotService do), Decals are textured from the local billboard art, and the
scene is drawn with tools/raster.py (numpy z-buffer). Slots whose role has no local GLB keep their placeholder parts.

  lune run tools/dump_dressing.luau garage 3 4 /tmp/g.json
  python3 tools/preview_slots.py garage /tmp/g.json docs/previews/garage_dressed.png
  lune run tools/dump_dressing.luau dealer /tmp/d.json
  python3 tools/preview_slots.py dealer /tmp/d.json docs/previews/dealership_dressed.png
  python3 tools/preview_slots.py placeholders /tmp/g.json out.png   # fallback look (no meshes)
  python3 tools/preview_slots.py variants out.png /tmp/g1.json /tmp/g2.json placeholders:/tmp/g3.json
"""
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kitgeo  # noqa: E402  (AP2's shared GLB normalization)
import raster  # noqa: E402  (AP2's numpy rasterizer)

FACES = {"Props": 2400, "Buildings": 5000, "Hero": 2600}
_IMG_CACHE = {}


def rot_of(c):
    return np.array([[c[3], c[4], c[5]], [c[6], c[7], c[8]], [c[9], c[10], c[11]]], dtype=float)


def to_world(origin, p):
    return rot_of(origin) @ np.asarray(p, dtype=float) + np.array(origin[:3])


def dir_world(origin, d):
    return rot_of(origin) @ np.asarray(d, dtype=float)


def image_for(texture):
    """Decal Content string -> RGB array (local art from assets/images/manifest.json)."""
    if texture in _IMG_CACHE:
        return _IMG_CACHE[texture]
    files = kitgeo.image_files()
    aid = texture.replace("rbxassetid://", "")
    path = files.get(aid)
    img = None
    if path and os.path.exists(path):
        img = np.asarray(Image.open(path).convert("RGB").resize((192, 108), Image.LANCZOS)).astype(np.float32)
    _IMG_CACHE[texture] = img
    return img


def decal_tris(part, decal, nu=64, nv=36):
    """A textured grid over the decal's face (Front: viewer looks +Z local, so image-right is -X)."""
    img = image_for(decal["texture"])
    if img is None:
        return None
    sx, sy, sz = part["size"]
    face = decal["face"]
    us = np.linspace(0, 1, nu + 1)
    vs = np.linspace(0, 1, nv + 1)
    U, V = np.meshgrid(us, vs)
    if face == "Front":
        P = np.stack([-(U - 0.5) * sx, (0.5 - V) * sy, np.full_like(U, -sz / 2 - 0.03)], axis=-1)
    elif face == "Back":
        P = np.stack([(U - 0.5) * sx, (0.5 - V) * sy, np.full_like(U, sz / 2 + 0.03)], axis=-1)
    elif face == "Top":  # image top toward the part's Front (-Z), like Top-face SurfaceGuis
        P = np.stack([(U - 0.5) * sx, np.full_like(U, sy / 2 + 0.03), (V - 0.5) * sz], axis=-1)
    else:
        return None
    a, b, c, d = P[:-1, :-1], P[:-1, 1:], P[1:, 1:], P[1:, :-1]
    tris = np.concatenate([np.stack([a, b, c], -2).reshape(-1, 3, 3), np.stack([a, c, d], -2).reshape(-1, 3, 3)])
    h, w = img.shape[:2]
    cu = ((np.arange(nu) + 0.5) / nu * w).astype(int)
    cv = ((np.arange(nv) + 0.5) / nv * h).astype(int)
    col = img[cv][:, cu].reshape(-1, 3)
    cols = np.concatenate([col, col])
    cf = part["cframe"]
    world = tris @ rot_of(cf).T + np.array(cf[:3])
    return {"tris": world, "colors": cols, "flags": np.zeros(len(world), np.int8)}


class Scene:
    def __init__(self, dump, kit, use_meshes=True):
        self.dump = dump
        self.kit = kit
        self.use_meshes = use_meshes
        self.mesh_cache = {}
        self.dressed = set()  # slot indices (1-based) replaced by a mesh
        self.missing = set()
        if use_meshes:
            for i, s in enumerate(dump["slots"], start=1):
                s["role"] = self.resolve(s.get("category"), s.get("role"), s["cframe"][:3])
                if self.mesh(s.get("category"), s.get("role")) is not None:
                    self.dressed.add(i)
                else:
                    self.missing.add(f"{s.get('category')}/{s.get('role')}")

    def resolve(self, cat, role, pos):
        """MapBuilder variant roles (palm_tree -> palm_tree_a/b, tree -> round/pine) picked by position, like a dresser."""
        if self.kit.def_of(cat, role):
            return role
        variants = {"palm_tree": ["palm_tree_a", "palm_tree_b"], "tree": ["round_tree", "pine_tree"]}.get(role)
        if not variants:
            return role
        h = int(abs(pos[0]) * 7 + abs(pos[2]) * 13) % len(variants)
        return variants[h]

    def mesh(self, cat, role):
        key = (cat, role)
        if key not in self.mesh_cache:
            res = None
            if cat and role and self.kit.def_of(cat, role) and self.kit.glb_of(cat, role):
                res = self.kit.preview(cat, role, FACES.get(cat, 2400))
            self.mesh_cache[key] = res
        return self.mesh_cache[key]

    def batches(self, hide_names=(), hide=None, max_tier=99, cars=True):
        out = []
        tris, cols, flags, alpha = [], [], [], []
        hidden_slots = set()
        for i, s in enumerate(self.dump["slots"], start=1):
            if s.get("tier") is not None and s["tier"] > max_tier:
                hidden_slots.add(i)
        for p in self.dump["parts"]:
            t = p.get("transparency", 0)
            if p["name"] in hide_names or (hide and hide(p)):
                continue
            sl = p.get("slot")
            if sl and (sl in hidden_slots or sl in self.dressed):
                continue
            for d in p.get("decals") or []:  # decals draw even on invisible parts
                b = decal_tris(p, d)
                if b is not None:
                    out.append(b)
            if t >= 0.95:
                continue
            tr = raster.part_triangles(p)
            tris.append(tr)
            cols.append(np.tile(np.array(p["color"], np.float32), (len(tr), 1)))
            flags.append(np.full(len(tr), 1 if p.get("material") == "Neon" else 0, np.int8))
            a = 1 - t
            if p.get("material") == "Glass":
                a = min(a, 0.45)
            alpha.append(np.full(len(tr), a, np.float32))
        if tris:
            out.append({"tris": np.concatenate(tris), "colors": np.concatenate(cols), "flags": np.concatenate(flags),
                        "alpha": np.concatenate(alpha)})
        for i, s in enumerate(self.dump["slots"], start=1):
            if i not in self.dressed or i in hidden_slots:
                continue
            if hide and hide({"name": s["name"], "slot": i, "role": s["role"]}):
                continue
            m = self.mesh(s["category"], s["role"])
            d = s.get("def") or {}
            k = 1.0
            if isinstance(s.get("fit"), (int, float)) and d.get("size"):
                k = s["fit"] / d["size"]
            cf = s["cframe"]
            w = (m["tris"] * k) @ rot_of(cf).T + np.array(cf[:3])
            out.append({"tris": w, "colors": m["colors"], "flags": np.zeros(len(w), np.int8)})
        if cars:
            for c in self.dump.get("cars", []):
                m = self.mesh("Hero", c["carId"])
                if m is None:
                    continue
                cf = c["cframe"]
                w = m["tris"] @ rot_of(cf).T + np.array(cf[:3])
                out.append({"tris": w, "colors": m["colors"], "flags": np.zeros(len(w), np.int8)})
        return out


def label(img, text, sub=None):
    d = ImageDraw.Draw(img, "RGBA")
    try:
        font = ImageFont.truetype("DejaVuSans-Bold.ttf", 20)
        small = ImageFont.truetype("DejaVuSans.ttf", 14)
    except OSError:
        font = small = ImageFont.load_default()
    d.rectangle([0, 0, img.width, 30 if not sub else 50], fill=(14, 16, 30, 170))
    d.text((10, 5), text, fill=(255, 255, 255), font=font)
    if sub:
        d.text((10, 30), sub, fill=(200, 210, 230), font=small)
    return img


def sheet(rows, out, title=None):
    """rows: list of lists of PIL images (same height per row)."""
    W = max(sum(im.width for im in r) for r in rows)
    H = sum(r[0].height for r in rows) + (36 if title else 0)
    sh = Image.new("RGB", (W, H), (14, 16, 30))
    y = 0
    if title:
        d = ImageDraw.Draw(sh)
        try:
            font = ImageFont.truetype("DejaVuSans-Bold.ttf", 22)
        except OSError:
            font = ImageFont.load_default()
        d.text((12, 6), title, fill=(255, 255, 255), font=font)
        y = 36
    for r in rows:
        x = 0
        for im in r:
            sh.paste(im, (x, y))
            x += im.width
        y += r[0].height
    sh.save(out)
    print(f"wrote {out} ({sh.width}x{sh.height})")


ROOF = ("Roof", "Skylight", "SkylightRail", "Parapet", "ACUnit", "ACFan", "LightBar", "LightHanger")
FRONT = ("WallFrontL", "WallFrontR", "WallFrontTop", "Window", "WindowFrame", "WindowSill", "DoorHeader", "ShutterRoll",
         "StatusLight", "TrimStrip", "CornerPillar", "Sign", "SignTrim", "SignLogo", "SignLogoTrim", "DropoffSign",
         "SignCable", "LockSign", "PosterFrame", "Poster", "Emitter", "DoorPost", "Plinth")


def garage_views(scene, out, W=900, H=560):
    o = scene.dump["origin"]
    P = lambda p: to_world(o, p)  # noqa: E731
    D = lambda d: dir_world(o, d)  # noqa: E731
    imgs = []
    # 1) dollhouse: roof + front wall cut away
    cam = raster.Camera.ortho(D((-0.55, -1.0, 1.0)), P((0, 6, 4)), 150)
    hide = set(ROOF + FRONT)
    imgs.append(label(raster.render(scene.batches(hide_names=hide), cam, W, H, ss=2, background=(30, 34, 52)),
                      "Dollhouse cut-away (roof + front wall hidden)"))
    # 2) loot corner + couch from the owner spawn
    cam = raster.Camera.persp(P((0, 9.5, 17)), P((1, 3, 44)), fov=74)
    imgs.append(label(raster.render(scene.batches(), cam, W, H, ss=2), "Hangout: couch, collect pad, loot corner (max tier)"))
    # 3) toward the door: lifts, workbench, shelf, posters
    cam = raster.Camera.persp(P((0, 12, 30)), P((0, 7, -42)), fov=70)
    imgs.append(label(raster.render(scene.batches(), cam, W, H, ss=2), "Toward the door: lift corner, shelf, posters"))
    # 4) street facade
    cam = raster.Camera.persp(P((30, 10, -104)), P((0, 21, -44)), fov=55)
    imgs.append(label(raster.render(scene.batches(), cam, W, H, ss=2, haze=(200, 900)), "Street: logo crown over the owner sign"))
    rows = [imgs[0:2], imgs[2:4]]
    # 5) loot tiers 0..4
    tiers = []
    tw, th = (2 * W) // 5, 330
    for t in range(5):
        cam = raster.Camera.persp(P((6.75, 7.5, 27)), P((6.75, 2.5, 44.5)), fov=88)
        names = ["base", "100/s", "1k/s", "10k/s", "100k/s"]
        tiers.append(label(raster.render(scene.batches(max_tier=t, cars=False), cam, tw, th, ss=2),
                           f"Loot tier {t} ({names[t]})"))
    rows.append(tiers)
    sheet(rows, out, scene.dump.get("title"))


def dealer_views(scene, out, W=900, H=560):
    o = scene.dump["origin"]
    P = lambda p: to_world(o, p)  # noqa: E731
    imgs = []
    cam = raster.Camera.persp(P((-150, 22, -10)), P((0, 14, 10)), fov=58)
    imgs.append(label(raster.render(scene.batches(), cam, W, H, ss=2, haze=(250, 1200)), "From the spawn plaza (west)"))
    cam = raster.Camera.persp(P((-20, 20, -112)), P((0, 10, 10)), fov=62)
    imgs.append(label(raster.render(scene.batches(), cam, W, H, ss=2, haze=(250, 1200)), "From the north road (drive-out side)"))
    cam = raster.Camera.ortho(np.array([0.75, -0.9, 0.85]), P((-30, 10, 0)), 300)
    imgs.append(label(raster.render(scene.batches(), cam, W, H, ss=2), "Aerial (NW)"))
    cam = raster.Camera.persp(P((10, 9, -2)), P((-26, 5, 40)), fov=70)
    imgs.append(label(raster.render(scene.batches(), cam, W, H, ss=2), "Inside: back-left corner (palm, hot dog stand), ad frieze"))
    sheet([imgs[0:2], imgs[2:4]], out, scene.dump.get("title"))


def variants(kit, out, srcs, W=600, H=420):
    """Dollhouse views of several garage dumps side by side; a "placeholders:" prefix renders without meshes."""
    imgs = []
    for src in srcs:
        bare = src.startswith("placeholders:")
        dump = json.load(open(src.split(":", 1)[1] if bare else src))
        scene = Scene(dump, kit, use_meshes=not bare)
        o = dump["origin"]
        cam = raster.Camera.ortho(dir_world(o, (-0.55, -1.0, 1.0)), to_world(o, (0, 6, 4)), 150)
        im = raster.render(scene.batches(hide_names=set(ROOF + FRONT)), cam, W, H, ss=2, background=(30, 34, 52))
        imgs.append(label(im, dump.get("title", src) + (" - procedural fallback" if bare else "")))
    rows = [imgs[i:i + 3] for i in range(0, len(imgs), 3)]
    while len(rows[-1]) < 3:
        rows[-1].append(Image.new("RGB", (W, H), (14, 16, 30)))
    sheet(rows, out, "Garage dressing variants (deterministic per plot) + fallback")


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)
    mode, src, out = sys.argv[1], sys.argv[2], sys.argv[3]
    if mode == "variants":  # preview_slots.py variants out.png a.json b.json placeholders:c.json ...
        variants(kitgeo.Kit(), src, sys.argv[3:])
        return
    dump = json.load(open(src))
    kit = kitgeo.Kit()
    scene = Scene(dump, kit, use_meshes=(mode != "placeholders"))
    if scene.missing:
        print("no local GLB (placeholder kept):", ", ".join(sorted(scene.missing)))
    print(f"slots dressed {len(scene.dressed)}/{len(dump['slots'])}, cars {len(dump.get('cars', []))}")
    if mode == "dealer":
        dealer_views(scene, out)
    else:
        garage_views(scene, out)


if __name__ == "__main__":
    main()
