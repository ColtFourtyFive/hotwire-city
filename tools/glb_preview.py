#!/usr/bin/env python3
"""Inspect + render a GLB (from Higgsfield/Meshy image_to_3d) without external deps beyond numpy/PIL.

Usage: python3 tools/glb_preview.py in.glb out.png [--size 500]
Prints: triangle count, bounds (min/max/size per axis), node transforms, embedded texture info.
Renders 4 views (front -Z, side +X, top, iso) with per-triangle color sampled from the base color texture.
"""
import io
import json
import struct
import sys

import numpy as np
from PIL import Image, ImageDraw

COMP = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def load_glb(path):
    data = open(path, "rb").read()
    magic, version, length = struct.unpack_from("<III", data, 0)
    assert magic == 0x46546C67, "not a GLB"
    off = 12
    js, binc = None, None
    while off < length:
        clen, ctype = struct.unpack_from("<II", data, off)
        chunk = data[off + 8: off + 8 + clen]
        if ctype == 0x4E4F534A:
            js = json.loads(chunk)
        elif ctype == 0x004E4942:
            binc = chunk
        off += 8 + clen
    return js, binc


def accessor(js, binc, idx):
    a = js["accessors"][idx]
    bv = js["bufferViews"][a["bufferView"]]
    dtype = COMP[a["componentType"]]
    n = NCOMP[a["type"]]
    start = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    count = a["count"]
    stride = bv.get("byteStride")
    itemsize = np.dtype(dtype).itemsize * n
    if stride and stride != itemsize:
        raw = np.frombuffer(binc, dtype=np.uint8, count=stride * count, offset=start).reshape(count, stride)[:, :itemsize]
        arr = np.frombuffer(raw.tobytes(), dtype=dtype).reshape(count, n)
    else:
        arr = np.frombuffer(binc, dtype=dtype, count=count * n, offset=start).reshape(count, n)
    if a.get("normalized") and dtype != np.float32:
        arr = arr.astype(np.float32) / np.iinfo(dtype).max
    return arr


def node_matrix(node):
    if "matrix" in node:
        return np.array(node["matrix"], dtype=float).reshape(4, 4).T
    t = np.array(node.get("translation", [0, 0, 0]), dtype=float)
    q = node.get("rotation", [0, 0, 0, 1])
    s = np.array(node.get("scale", [1, 1, 1]), dtype=float)
    x, y, z, w = q
    R = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                  [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                  [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])
    M = np.eye(4)
    M[:3, :3] = R * s
    M[:3, 3] = t
    return M


def collect(js, binc):
    tris, cols = [], []
    textures = {}

    def tex_image(mat):
        pbr = mat.get("pbrMetallicRoughness", {})
        ti = pbr.get("baseColorTexture", {}).get("index")
        if ti is None:
            return None, pbr.get("baseColorFactor", [0.8, 0.8, 0.8, 1])
        if ti in textures:
            return textures[ti], None
        src = js["textures"][ti]["source"]
        img = js["images"][src]
        bv = js["bufferViews"][img["bufferView"]]
        raw = binc[bv.get("byteOffset", 0): bv.get("byteOffset", 0) + bv["byteLength"]]
        im = Image.open(io.BytesIO(raw)).convert("RGB")
        textures[ti] = np.asarray(im)
        return textures[ti], None

    def visit(ni, parent):
        node = js["nodes"][ni]
        M = parent @ node_matrix(node)
        if "mesh" in node:
            for prim in js["meshes"][node["mesh"]]["primitives"]:
                pos = accessor(js, binc, prim["attributes"]["POSITION"]).astype(float)
                pos = (np.c_[pos, np.ones(len(pos))] @ M.T)[:, :3]
                idx = accessor(js, binc, prim["indices"]).reshape(-1, 3) if "indices" in prim else np.arange(len(pos)).reshape(-1, 3)
                uv = accessor(js, binc, prim["attributes"]["TEXCOORD_0"]) if "TEXCOORD_0" in prim["attributes"] else None
                mat = js["materials"][prim["material"]] if "material" in prim else {}
                img, factor = tex_image(mat)
                for f in idx:
                    tris.append(pos[f])
                    if img is not None and uv is not None:
                        u, v = uv[f].mean(axis=0)
                        h, w = img.shape[:2]
                        px = img[int(np.clip(v, 0, 0.999) * h) % h, int(np.clip(u, 0, 0.999) * w) % w]
                        cols.append(px.astype(float))
                    else:
                        cols.append(np.array(factor[:3]) * 255)
        for c in node.get("children", []):
            visit(c, M)

    scene = js["scenes"][js.get("scene", 0)]
    for n in scene["nodes"]:
        visit(n, np.eye(4))
    return np.array(tris), np.array(cols), textures


def render(tris, cols, view, size):
    import math
    if view == "front":   # camera on -Z looking +Z (glTF/Roblox: forward is -Z? we just label axes)
        R = np.array([[-1, 0, 0], [0, 1, 0], [0, 0, -1]], float)
    elif view == "side":  # camera on +X looking -X
        R = np.array([[0, 0, -1], [0, 1, 0], [1, 0, 0]], float)
    elif view == "top":
        R = np.array([[1, 0, 0], [0, 0, -1], [0, 1, 0]], float)
    else:
        yaw, pitch = math.radians(-135), math.radians(25)
        Ry = np.array([[math.cos(yaw), 0, math.sin(yaw)], [0, 1, 0], [-math.sin(yaw), 0, math.cos(yaw)]])
        Rx = np.array([[1, 0, 0], [0, math.cos(pitch), -math.sin(pitch)], [0, math.sin(pitch), math.cos(pitch)]])
        R = Rx @ Ry
    cam = tris @ R.T
    light = np.array([0.4, 0.8, 0.45]); light /= np.linalg.norm(light)
    n = np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0])
    n /= np.linalg.norm(n, axis=1, keepdims=True) + 1e-12
    shade = 0.55 + 0.45 * np.abs(n @ light)
    pts = cam[:, :, :2].reshape(-1, 2)
    mn, mx = pts.min(0), pts.max(0)
    span = max(mx - mn) or 1
    sc = (size - 40) / span
    c = (mn + mx) / 2
    order = np.argsort(cam[:, :, 2].mean(1))
    img = Image.new("RGB", (size, size), (34, 38, 60))
    d = ImageDraw.Draw(img)
    for i in order:
        xy = [(size / 2 + (p[0] - c[0]) * sc, size / 2 - (p[1] - c[1]) * sc) for p in cam[i]]
        col = tuple(int(v) for v in np.clip(cols[i] * shade[i], 0, 255))
        d.polygon(xy, fill=col)
    d.text((8, 6), view, fill=(255, 255, 255))
    return img


def main():
    src, out = sys.argv[1], sys.argv[2]
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 450
    js, binc = load_glb(src)
    tris, cols, tex = collect(js, binc)
    allp = tris.reshape(-1, 3)
    mn, mx = allp.min(0), allp.max(0)
    print(f"triangles={len(tris)} bounds min={mn.round(3)} max={mx.round(3)} size={(mx - mn).round(3)}")
    print("textures:", {k: v.shape for k, v in tex.items()}, "nodes:", len(js["nodes"]), "meshes:", len(js["meshes"]))
    views = ["front", "side", "top", "iso"]
    imgs = [render(tris, cols, v, size) for v in views]
    sheet = Image.new("RGB", (size * len(imgs), size))
    for i, im in enumerate(imgs):
        sheet.paste(im, (i * size, 0))
    sheet.save(out)
    print("wrote", out)


if __name__ == "__main__":
    main()
