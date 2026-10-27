#!/usr/bin/env python3
"""Kit asset geometry helpers shared by tools/preview_dressed.py (and handy on their own).

Reads src/shared/Config/Assets.luau (role -> owned asset id, fit, size, yaw), maps each asset id to its local GLB
through the manifests (assets/kit/*.json, assets/hero/manifest.json), and reproduces AssetLibrary._normalize:
  yaw about +Y (front -> -Z), root at the bottom-center of the rotated bounds, uniform scale so the `fit`
  dimension equals `size`.

Usage:
  python3 tools/kitgeo.py dims                 # normalized W/H/D (studs) of every kit role with a local GLB
  python3 tools/kitgeo.py luau                 # same, as a Luau table body (MapBuilder KIT_DIMS)
  python3 tools/kitgeo.py probe <Category> <role> [slices]   # vertex-height profile (pole/arm/panel probing)
  python3 tools/kitgeo.py decimate <Category> <role> [faces]  # build + cache the preview mesh, print stats

Preview meshes (decimated with pymeshlab, recolored from the nearest original triangle) are cached as .npz under
/tmp/claude-0/preview_cache.
"""
import hashlib
import io
import json
import math
import os
import re
import struct
import sys

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = "/tmp/claude-0/preview_cache"

COMP = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


# ------------------------------------------------------------------------------------------------- config parsing

def load_assets_config():
    """{Category: {role: {ids, source, fit, size, yaw}}} parsed from Config/Assets.luau."""
    src = open(os.path.join(ROOT, "src/shared/Config/Assets.luau")).read()
    out = {}
    for block in re.finditer(r"Assets\.(\w+)\s*=\s*\{(.*?)\n\}\s*::", src, re.S):
        cat, body = block.group(1), block.group(2)
        entries = {}
        for m in re.finditer(r"^\s*(\w+)\s*=\s*\{\s*ids\s*=\s*\{([^}]*)\}(.*?)\},?\s*$", body, re.M):
            key, ids, rest = m.group(1), m.group(2), m.group(3)
            d = {"ids": [int(x) for x in re.findall(r"\d+", ids)]}
            for fld in ("source", "fit"):
                mm = re.search(fld + r'\s*=\s*"(\w+)"', rest)
                if mm:
                    d[fld] = mm.group(1)
            for fld in ("size", "yaw"):
                mm = re.search(fld + r"\s*=\s*(-?[\d.]+)", rest)
                if mm:
                    d[fld] = float(mm.group(1))
            d.setdefault("yaw", 0.0)
            entries[key] = d
        if entries:
            out[cat] = entries
    return out


def load_images_config():
    src = open(os.path.join(ROOT, "src/shared/Config/Assets.luau")).read()
    return dict(re.findall(r'(\w+)\s*=\s*"rbxassetid://(\d+)"', src))


def manifest_files():
    """asset id -> local GLB path."""
    files = {}
    paths = [os.path.join(ROOT, "assets/kit", f) for f in os.listdir(os.path.join(ROOT, "assets/kit")) if f.endswith(".json")]
    paths.append(os.path.join(ROOT, "assets/hero/manifest.json"))
    for p in paths:
        if not os.path.exists(p):
            continue
        for _, v in json.load(open(p)).items():
            if "assetId" in v and v.get("file"):
                fp = os.path.join(ROOT, v["file"])
                if os.path.exists(fp):
                    files[int(v["assetId"])] = fp
    return files


def image_files():
    """Content id (str) -> local png path, for billboard ads / logo."""
    man = json.load(open(os.path.join(ROOT, "assets/images/manifest.json")))
    return {str(v["assetId"]): os.path.join(ROOT, v["file"]) for v in man.values() if v.get("file")}


# ---------------------------------------------------------------------------------------------------- GLB loading

def load_glb(path):
    data = open(path, "rb").read()
    magic, _version, length = struct.unpack_from("<III", data, 0)
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


def _accessor(js, binc, idx):
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


def _node_matrix(node):
    if "matrix" in node:
        return np.array(node["matrix"], dtype=float).reshape(4, 4).T
    t = np.array(node.get("translation", [0, 0, 0]), dtype=float)
    x, y, z, w = node.get("rotation", [0, 0, 0, 1])
    s = np.array(node.get("scale", [1, 1, 1]), dtype=float)
    R = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                  [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                  [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])
    M = np.eye(4)
    M[:3, :3] = R * s
    M[:3, 3] = t
    return M


def glb_triangles(path):
    """(verts Vx3, faces Fx3, face colors Fx3 in 0..255) with node transforms applied."""
    js, binc = load_glb(path)
    textures = {}
    allv, allf, allc = [], [], []
    base = [0]

    def tex_image(mat):
        pbr = mat.get("pbrMetallicRoughness", {})
        ti = pbr.get("baseColorTexture", {}).get("index")
        factor = pbr.get("baseColorFactor", [0.8, 0.8, 0.8, 1])
        if ti is None:
            return None, factor
        if ti not in textures:
            img = js["images"][js["textures"][ti]["source"]]
            bv = js["bufferViews"][img["bufferView"]]
            raw = binc[bv.get("byteOffset", 0): bv.get("byteOffset", 0) + bv["byteLength"]]
            textures[ti] = np.asarray(Image.open(io.BytesIO(raw)).convert("RGB")).astype(np.float32)
        return textures[ti], factor

    def visit(ni, parent):
        node = js["nodes"][ni]
        M = parent @ _node_matrix(node)
        if "mesh" in node:
            for prim in js["meshes"][node["mesh"]]["primitives"]:
                pos = _accessor(js, binc, prim["attributes"]["POSITION"]).astype(float)
                pos = (np.c_[pos, np.ones(len(pos))] @ M.T)[:, :3]
                if "indices" in prim:
                    idx = _accessor(js, binc, prim["indices"]).reshape(-1, 3).astype(np.int64)
                else:
                    idx = np.arange(len(pos)).reshape(-1, 3)
                mat = js["materials"][prim["material"]] if "material" in prim else {}
                img, factor = tex_image(mat)
                uv = _accessor(js, binc, prim["attributes"]["TEXCOORD_0"]) if "TEXCOORD_0" in prim["attributes"] else None
                if img is not None and uv is not None:
                    h, w = img.shape[:2]
                    # average 3 corner samples + centroid sample per face
                    samples = []
                    uvf = uv[idx]  # F x 3 x 2
                    for pts in (uvf.mean(axis=1), uvf[:, 0], uvf[:, 1], uvf[:, 2]):
                        u = np.mod(pts[:, 0], 1.0)
                        v = np.mod(pts[:, 1], 1.0)
                        samples.append(img[(v * (h - 1)).astype(int), (u * (w - 1)).astype(int)])
                    col = samples[0] * 0.4 + (samples[1] + samples[2] + samples[3]) * 0.2
                    col = col * np.array(factor[:3], dtype=np.float32)
                else:
                    col = np.tile(np.array(factor[:3], dtype=np.float32) * 255, (len(idx), 1))
                allv.append(pos)
                allf.append(idx + base[0])
                allc.append(col)
                base[0] += len(pos)
        for c in node.get("children", []):
            visit(c, M)

    for n in js["scenes"][js.get("scene", 0)]["nodes"]:
        visit(n, np.eye(4))
    return np.concatenate(allv), np.concatenate(allf), np.concatenate(allc)


# -------------------------------------------------------------------------------------------------- normalization

def yaw_matrix(deg):
    """Roblox CFrame.Angles(0, yaw, 0) rotation (column vectors)."""
    a = math.radians(deg)
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])


def normalize_verts(verts, d):
    """AssetLibrary._normalize: yaw, bottom-center root, uniform fit scale. Returns (verts, size W/H/D)."""
    v = verts @ yaw_matrix(d.get("yaw", 0)).T
    mn, mx = v.min(0), v.max(0)
    c = (mn + mx) / 2
    v = v - np.array([c[0], mn[1], c[2]])
    size = mx - mn
    fit = d.get("fit", "maxDim")
    if fit == "length":
        cur = size[2]
    elif fit == "height":
        cur = size[1]
    elif fit == "footprint":
        cur = max(size[0], size[2])
    else:
        cur = size.max()
    f = d["size"] / max(cur, 1e-6)
    return v * f, size * f


class Kit:
    def __init__(self):
        self.config = load_assets_config()
        self.files = manifest_files()

    def def_of(self, cat, role):
        return self.config.get(cat, {}).get(role)

    def glb_of(self, cat, role):
        d = self.def_of(cat, role)
        if not d:
            return None
        for i in d["ids"]:
            if i in self.files:
                return self.files[i]
        return None

    def normalized(self, cat, role):
        """Full-res normalized (verts, faces, colors, size) or None when no local GLB."""
        path = self.glb_of(cat, role)
        if not path:
            return None
        v, f, c = glb_triangles(path)
        v, size = normalize_verts(v, self.def_of(cat, role))
        return v, f, c, size

    def preview(self, cat, role, faces=500):
        """Decimated normalized mesh: dict(tris Fx3x3, colors Fx3, size 3). Cached."""
        path = self.glb_of(cat, role)
        if not path:
            return None
        d = self.def_of(cat, role)
        st = os.stat(path)
        key = hashlib.sha1(f"{path}|{st.st_mtime}|{st.st_size}|{json.dumps(d, sort_keys=True)}|{faces}|v3".encode()).hexdigest()[:16]
        os.makedirs(CACHE, exist_ok=True)
        cp = os.path.join(CACHE, f"{cat}_{role}_{key}.npz")
        if os.path.exists(cp):
            z = np.load(cp)
            return {"tris": z["tris"], "colors": z["colors"], "size": z["size"]}
        v, f, c, size = self.normalized(cat, role)
        tris, cols = decimate(v, f, c, faces)
        np.savez_compressed(cp, tris=tris, colors=cols, size=size)
        return {"tris": tris, "colors": cols, "size": size}


def decimate(v, f, c, target):
    """Quadric decimation via pymeshlab, then per-face color from the nearest original face centroid."""
    import pymeshlab

    ms = pymeshlab.MeshSet()
    ms.add_mesh(pymeshlab.Mesh(vertex_matrix=v.astype(np.float64), face_matrix=f.astype(np.int32)))
    try:
        ms.meshing_merge_close_vertices(threshold=pymeshlab.PercentageValue(0.05))
    except Exception:
        pass
    ms.meshing_decimation_quadric_edge_collapse(targetfacenum=int(target), preservetopology=False, qualitythr=0.3,
                                                planarquadric=True, autoclean=True)
    m = ms.current_mesh()
    nv, nf = m.vertex_matrix(), m.face_matrix()
    tris = nv[nf]
    # color transfer: nearest original centroid, area-weighted average of the k nearest
    oc = v[f].mean(axis=1)
    nc = tris.mean(axis=1)
    cols = np.zeros((len(nc), 3), dtype=np.float32)
    k = 6
    for i0 in range(0, len(nc), 256):
        blk = nc[i0:i0 + 256]
        d2 = ((blk[:, None, :] - oc[None, :, :]) ** 2).sum(-1)
        nn = np.argpartition(d2, k, axis=1)[:, :k]
        cols[i0:i0 + 256] = c[nn].mean(axis=1)
    return tris.astype(np.float32), cols


# ------------------------------------------------------------------------------------------------------------ CLI

def main():
    args = sys.argv[1:]
    kit = Kit()
    if not args or args[0] in ("dims", "luau"):
        for cat in ("Buildings", "Props"):
            for role in sorted(kit.config.get(cat, {})):
                res = kit.normalized(cat, role)
                if res is None:
                    if args and args[0] == "dims":
                        print(f"{cat:10s} {role:20s} (no local GLB: {kit.def_of(cat, role)['source']})")
                    continue
                size = res[3]
                if args and args[0] == "luau":
                    print(f"\t{role} = Vector3.new({size[0]:.1f}, {size[1]:.1f}, {size[2]:.1f}),")
                else:
                    d = kit.def_of(cat, role)
                    print(f"{cat:10s} {role:20s} fit={d['fit']:9s} size={d['size']:6.1f}  W={size[0]:6.1f} H={size[1]:6.1f} D={size[2]:6.1f}")
    elif args[0] == "probe":
        cat, role = args[1], args[2]
        slices = int(args[3]) if len(args) > 3 else 12
        v, f, c, size = kit.normalized(cat, role)
        print(f"{cat}/{role} size W={size[0]:.2f} H={size[1]:.2f} D={size[2]:.2f}")
        H = size[1]
        for i in range(slices):
            y0, y1 = H * i / slices, H * (i + 1) / slices
            sel = v[(v[:, 1] >= y0) & (v[:, 1] < y1)]
            if len(sel) == 0:
                continue
            mn, mx, mean = sel.min(0), sel.max(0), sel.mean(0)
            print(f"  y {y0:6.1f}-{y1:6.1f}: n={len(sel):6d} x[{mn[0]:6.1f},{mx[0]:6.1f}] z[{mn[2]:6.1f},{mx[2]:6.1f}] mean x={mean[0]:6.1f} z={mean[2]:6.1f}")
    elif args[0] == "decimate":
        cat, role = args[1], args[2]
        faces = int(args[3]) if len(args) > 3 else 500
        p = kit.preview(cat, role, faces)
        print(role, "faces", len(p["tris"]), "size", p["size"])
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
