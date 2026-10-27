#!/usr/bin/env python3
"""Roblox FileMesh reader + converter, and bulk downloader for a model's meshes/textures.

    # convert one mesh file (any version 1.00 .. 7.00) to OBJ and/or GLB
    python3 -I tools/sources/rbxmesh.py convert <in.mesh> <out.obj|out.glb> [--texture tex.png]

    # download + convert every MeshId / TextureID / SurfaceAppearance map / Decal referenced by a
    # model inspected with rbxm_inspect.luau (tree.json). Writes per-asset files next to the cache:
    #   assets/source/roblox/<meshId>/mesh.obj + mesh.glb + mesh.json (counts, bbox, version)
    #   assets/source/roblox/<imageId>/image.png
    # and assets/source/roblox/<modelId>/deps.json (what was referenced and what resolved).
    python3 -I tools/sources/rbxmesh.py model <modelId> [-j 8]

    # quick stats for a mesh file
    python3 -I tools/sources/rbxmesh.py info <in.mesh>

Format notes (community spec, devforum "Roblox Mesh Format" by Max_Gr / CloneTrooper1019, cross-checked
against real payloads):
  * every version starts with a 12-char ASCII "version X.YY" + "\n".
  * 1.00 / 1.01: text. num_faces line, then [x,y,z] triplets: pos, normal, uvw per corner, 3 corners per
    face. 1.00 positions are 2x (multiply by 0.5). V is stored bottom-up (we flip to the binary
    convention, which is top-left origin like glTF / D3D).
  * 2.00: u16 headerSize(12) u8 vertexSize(36|40) u8 faceSize(12) u32 nVerts u32 nFaces; verts; faces.
  * 3.00/3.01: u16 headerSize(16) u8 vSize u8 fSize u16 lodSize(4) u16 nLods u32 nVerts u32 nFaces;
    verts; faces; u32 lodOffsets[nLods]. Faces [lod[0], lod[1]) are the full-detail mesh.
  * 4.00/4.01: u16 headerSize(24) u16 lodType u32 nVerts u32 nFaces u16 nLods u16 nBones
    u32 boneNamesSize u16 nSubsets u8 nHqLods u8 pad; verts(40); skinning(8*nVerts if nBones);
    faces; lods; bones(60 each); names; subsets(72 each).
  * 5.00: v4 header + u32 facsFormat u32 facsSize (header 32); FACS blob at the end (ignored).
  * 6.00/7.00: chunked: 8-byte type, u32 chunkVersion, u32 size, data. COREMESH v1 = u32 nVerts,
    verts(40), u32 nFaces, faces. COREMESH v2 (7.00) = u32 size + Draco bitstream (needs DracoPy).
    LODS v1 = u16 lodType, u8 nHq, u32 nLods, u32 offsets[].
  * vertex (36/40 bytes): f32 pos[3], f32 normal[3], f32 uv[2], i8 tangent[4], [u8 rgba[4]].
Coordinates are Roblox mesh space: Y up, right-handed, a car's front is -Z.
"""
import json
import os
import re
import struct
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import rbxdl  # noqa: E402


class Mesh:
    __slots__ = ("version", "pos", "nrm", "uv", "col", "faces", "lods", "num_bones", "notes")

    def __init__(self):
        self.version = ""
        self.pos = self.nrm = self.uv = self.col = self.faces = None
        self.lods = []
        self.num_bones = 0
        self.notes = []

    # --- derived --------------------------------------------------------------------------
    def bbox(self):
        used = np.unique(self.faces) if len(self.faces) else np.arange(len(self.pos))
        p = self.pos[used] if len(used) else self.pos
        return p.min(0), p.max(0)

    def compact(self):
        """Drop vertices not referenced by the chosen LOD faces."""
        used, inv = np.unique(self.faces, return_inverse=True)
        self.pos, self.nrm, self.uv = self.pos[used], self.nrm[used], self.uv[used]
        if self.col is not None:
            self.col = self.col[used]
        self.faces = inv.reshape(-1, 3).astype(np.uint32)
        return self


# ---------------------------------------------------------------------------------------------
# parsing
# ---------------------------------------------------------------------------------------------
_VTX40 = np.dtype([("p", "<f4", 3), ("n", "<f4", 3), ("uv", "<f4", 2), ("t", "i1", 4), ("c", "u1", 4)])
_VTX36 = np.dtype([("p", "<f4", 3), ("n", "<f4", 3), ("uv", "<f4", 2), ("t", "i1", 4)])
_VTX36_UVW = np.dtype([("p", "<f4", 3), ("n", "<f4", 3), ("uvw", "<f4", 3)])


def _verts(buf, off, n, vsize):
    if vsize == 40:
        a = np.frombuffer(buf, _VTX40, n, off)
        return a["p"].copy(), a["n"].copy(), a["uv"].copy(), a["c"].copy()
    if vsize == 36:
        a = np.frombuffer(buf, _VTX36, n, off)
        return a["p"].copy(), a["n"].copy(), a["uv"].copy(), None
    raise ValueError(f"unsupported vertex size {vsize}")


def _first_lod(faces, lods):
    if len(lods) >= 2 and 0 <= lods[0] < lods[1] <= len(faces):
        return faces[lods[0]:lods[1]]
    return faces


def parse_v1(text, ver):
    lines = text.splitlines()
    nfaces = int(lines[1].strip())
    nums = re.findall(r"\[([^\]]*)\]", "\n".join(lines[2:]))
    vals = np.array([[float(x) for x in t.split(",")[:3]] for t in nums], dtype=np.float32)
    need = nfaces * 9
    if len(vals) < need:
        raise ValueError(f"v1 mesh truncated: {len(vals)} < {need}")
    vals = vals[:need].reshape(nfaces * 3, 3, 3)
    m = Mesh()
    m.version = ver
    pos = vals[:, 0]
    if ver.startswith("1.00"):
        pos = pos * 0.5
    m.pos = pos.astype(np.float32)
    m.nrm = vals[:, 1].astype(np.float32)
    uv = vals[:, 2, :2].copy()
    uv[:, 1] = 1.0 - uv[:, 1]  # v1 stores V bottom-up; normalise to binary (top-left) convention
    m.uv = uv.astype(np.float32)
    m.faces = np.arange(nfaces * 3, dtype=np.uint32).reshape(-1, 3)
    return m


def parse_v2(buf, off, ver):
    hs, vs, fs, nv, nf = struct.unpack_from("<HBBII", buf, off)
    off += hs
    m = Mesh()
    m.version = ver
    m.pos, m.nrm, m.uv, m.col = _verts(buf, off, nv, vs)
    off += nv * vs
    m.faces = np.frombuffer(buf, "<u4", nf * 3, off).reshape(-1, 3).copy()
    return m


def parse_v3(buf, off, ver):
    hs, vs, fs, ls, nl, nv, nf = struct.unpack_from("<HBBHHII", buf, off)
    off += hs
    m = Mesh()
    m.version = ver
    m.pos, m.nrm, m.uv, m.col = _verts(buf, off, nv, vs)
    off += nv * vs
    faces = np.frombuffer(buf, "<u4", nf * 3, off).reshape(-1, 3)
    off += nf * fs
    m.lods = list(struct.unpack_from(f"<{nl}I", buf, off)) if nl else []
    m.faces = _first_lod(faces, m.lods).copy()
    return m


def parse_v4(buf, off, ver):
    hs, lodtype, nv, nf, nl, nb, bnsize, nsub, nhq, _ = struct.unpack_from("<HHIIHHIHBB", buf, off)
    off += hs
    m = Mesh()
    m.version = ver
    m.num_bones = nb
    m.pos, m.nrm, m.uv, m.col = _verts(buf, off, nv, 40)
    off += nv * 40
    if nb > 0:
        off += nv * 8
    faces = np.frombuffer(buf, "<u4", nf * 3, off).reshape(-1, 3)
    off += nf * 12
    m.lods = list(struct.unpack_from(f"<{nl}I", buf, off)) if nl else []
    m.faces = _first_lod(faces, m.lods).copy()
    return m


def _draco_decode(blob):
    try:
        import DracoPy
    except ImportError as e:
        raise RuntimeError("mesh v7 COREMESH is Draco-compressed: pip install DracoPy") from e
    dm = DracoPy.decode(blob)
    m = Mesh()
    m.pos = np.asarray(dm.points, dtype=np.float32).reshape(-1, 3)
    m.faces = np.asarray(dm.faces, dtype=np.uint32).reshape(-1, 3)
    n = len(m.pos)
    m.nrm = np.zeros((n, 3), np.float32)
    m.uv = np.zeros((n, 2), np.float32)
    # DracoPy exposes typed attributes (normals / tex_coord) and, in newer versions, a generic
    # attribute list keyed by unique id (Roblox: 0 pos, 1 normal, 2 uv, 3 tangent, 4 colour).
    def fit(arr, comps, dtype):
        a = np.asarray(arr, dtype)
        if a.ndim == 2 and a.shape[0] == n and a.shape[1] >= comps:
            return a[:, :comps].copy()
        if a.size and a.size % n == 0 and a.size // n >= comps:
            return a.reshape(n, -1)[:, :comps].copy()
        raise ValueError(f"attribute size {a.size} does not fit {n} verts")
    typed = set()
    for label, getter, comps, dtype, attr in (("normals", lambda: dm.normals, 3, np.float32, "nrm"),
                                              ("tex_coord", lambda: dm.tex_coord, 2, np.float32, "uv"),
                                              ("colors", lambda: dm.colors, 4, np.uint8, "col")):
        try:
            v = getter()
            if v is not None and len(v):
                setattr(m, attr, fit(v, comps, dtype))
                typed.add(attr)
        except Exception as e:  # noqa: BLE001
            m.notes.append(f"draco {label}: {e}")
    # only fall back to Roblox's unique-id convention for attributes Draco did not type
    for att in (getattr(dm, "attributes", None) or []) if len(typed) < 2 else []:
        try:
            uid = att.get("unique_id") if isinstance(att, dict) else getattr(att, "unique_id", None)
            data = att.get("data") if isinstance(att, dict) else getattr(att, "data", None)
            if data is None:
                continue
            if uid == 1:
                m.nrm = fit(data, 3, np.float32)
            elif uid == 2:
                m.uv = fit(data, 2, np.float32)
            elif uid == 4:
                m.col = fit(data, 4, np.uint8)
        except Exception as e:  # noqa: BLE001
            m.notes.append(f"draco attribute {att!r:.40}: {e}")
    return m


def parse_chunked(buf, off, ver):
    m = None
    lods = []
    while off + 16 <= len(buf):
        ctype = buf[off:off + 8].rstrip(b"\0").decode("ascii", "replace")
        cver, size = struct.unpack_from("<II", buf, off + 8)
        data_off = off + 16
        off = data_off + size
        if ctype == "COREMESH":
            if cver == 1:
                nv, = struct.unpack_from("<I", buf, data_off)
                m = Mesh()
                m.pos, m.nrm, m.uv, m.col = _verts(buf, data_off + 4, nv, 40)
                fo = data_off + 4 + nv * 40
                nf, = struct.unpack_from("<I", buf, fo)
                m.faces = np.frombuffer(buf, "<u4", nf * 3, fo + 4).reshape(-1, 3).copy()
            elif cver == 2:
                dsize, = struct.unpack_from("<I", buf, data_off)
                m = _draco_decode(bytes(buf[data_off + 4:data_off + 4 + dsize]))
            else:
                raise ValueError(f"COREMESH chunk version {cver} unsupported")
        elif ctype == "LODS":
            lodtype, nhq, nl = struct.unpack_from("<HBI", buf, data_off)
            lods = list(struct.unpack_from(f"<{nl}I", buf, data_off + 7)) if nl else []
        elif ctype == "SKINNING" and m is not None:
            m.num_bones = -1  # skinned; bones not needed for static props
    if m is None:
        raise ValueError("no COREMESH chunk")
    m.version = ver
    m.lods = lods
    m.faces = _first_lod(m.faces, lods).copy()
    return m


def parse(data):
    """bytes -> Mesh (full-detail LOD, unused verts dropped, uv in top-left convention)."""
    if not data.startswith(b"version "):
        raise ValueError("not a Roblox mesh (missing 'version ' header)")
    nl = data.index(b"\n")
    ver = data[8:nl].decode("ascii", "replace").strip()
    off = nl + 1
    major = ver.split(".")[0]
    if major == "1":
        m = parse_v1(data.decode("ascii", "replace"), ver)
    elif major == "2":
        m = parse_v2(data, off, ver)
    elif major == "3":
        m = parse_v3(data, off, ver)
    elif major in ("4", "5"):
        m = parse_v4(data, off, ver)
    elif major in ("6", "7"):
        m = parse_chunked(data, off, ver)
    else:
        raise ValueError(f"unknown mesh version {ver}")
    m.faces = m.faces.astype(np.uint32)
    if len(m.faces) and int(m.faces.max()) >= len(m.pos):
        bad = (m.faces >= len(m.pos)).any(1)
        m.notes.append(f"dropped {int(bad.sum())} faces with out-of-range indices")
        m.faces = m.faces[~bad]
    return m.compact()


def load(path):
    with open(path, "rb") as f:
        return parse(f.read())


# ---------------------------------------------------------------------------------------------
# export
# ---------------------------------------------------------------------------------------------
def write_obj(m, path, mtl_texture=None, name="mesh"):
    """OBJ uses bottom-left UV origin -> v' = 1 - v."""
    lines = [f"# Roblox mesh v{m.version} -> OBJ (rbxmesh.py); units = studs, Y up"]
    if mtl_texture:
        mtl = os.path.splitext(path)[0] + ".mtl"
        with open(mtl, "w") as f:
            f.write(f"newmtl {name}\nKd 1 1 1\nmap_Kd {os.path.relpath(mtl_texture, os.path.dirname(path))}\n")
        lines.append(f"mtllib {os.path.basename(mtl)}")
    lines.append(f"o {name}")
    lines += [f"v {x:.6f} {y:.6f} {z:.6f}" for x, y, z in m.pos]
    lines += [f"vt {u:.6f} {1.0 - v:.6f}" for u, v in m.uv]
    lines += [f"vn {x:.5f} {y:.5f} {z:.5f}" for x, y, z in m.nrm]
    if mtl_texture:
        lines.append(f"usemtl {name}")
    f1 = m.faces + 1
    lines += [f"f {a}/{a}/{a} {b}/{b}/{b} {c}/{c}/{c}" for a, b, c in f1]
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def write_glb(m, path, texture_png=None, name="mesh"):
    """glTF uses a top-left UV origin like Roblox, so UVs are written unchanged. Y-up, +Z front
    in glTF; Roblox meshes are also Y-up right-handed, so positions are written unchanged."""
    pos = np.ascontiguousarray(m.pos, np.float32)
    nrm = m.nrm.astype(np.float32)
    ln = np.linalg.norm(nrm, axis=1, keepdims=True)
    nrm = np.where(ln > 1e-8, nrm / np.maximum(ln, 1e-8), np.array([0, 1, 0], np.float32)).astype(np.float32)
    uv = np.ascontiguousarray(m.uv, np.float32)
    idx = np.ascontiguousarray(m.faces.reshape(-1), np.uint32)
    blobs, views, accs = [], [], []
    offset = 0

    def add(arr, target, comp, ctype, typ, minmax=False):
        nonlocal offset
        b = arr.tobytes()
        pad = (-len(b)) % 4
        views.append({"buffer": 0, "byteOffset": offset, "byteLength": len(b), "target": target})
        acc = {"bufferView": len(views) - 1, "componentType": ctype, "count": int(arr.shape[0]), "type": typ}
        if minmax:
            acc["min"] = [float(x) for x in arr.min(0)]
            acc["max"] = [float(x) for x in arr.max(0)]
        accs.append(acc)
        blobs.append(b + b"\0" * pad)
        offset += len(b) + pad
        return len(accs) - 1

    a_pos = add(pos, 34962, 3, 5126, "VEC3", True)
    a_nrm = add(nrm, 34962, 3, 5126, "VEC3")
    a_uv = add(uv, 34962, 2, 5126, "VEC2")
    attrs = {"POSITION": a_pos, "NORMAL": a_nrm, "TEXCOORD_0": a_uv}
    if m.col is not None and (m.col != 255).any():
        attrs["COLOR_0"] = add(np.ascontiguousarray(m.col, np.uint8), 34962, 4, 5121, "VEC4")
        accs[-1]["normalized"] = True
    a_idx = add(idx.reshape(-1, 1)[:, 0], 34963, 1, 5125, "SCALAR")
    gltf = {
        "asset": {"version": "2.0", "generator": "HotwireCity rbxmesh.py"},
        "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0, "name": name}],
        "meshes": [{"name": name, "primitives": [{"attributes": attrs, "indices": a_idx, "material": 0}]}],
        "materials": [{"name": name, "pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 1], "metallicFactor": 0.0, "roughnessFactor": 0.6}}],
        "accessors": accs, "bufferViews": views,
    }
    if texture_png:
        b = open(texture_png, "rb").read()
        pad = (-len(b)) % 4
        views.append({"buffer": 0, "byteOffset": offset, "byteLength": len(b)})
        blobs.append(b + b"\0" * pad)
        offset += len(b) + pad
        gltf["images"] = [{"bufferView": len(views) - 1, "mimeType": "image/png"}]
        gltf["samplers"] = [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}]
        gltf["textures"] = [{"source": 0, "sampler": 0}]
        gltf["materials"][0]["pbrMetallicRoughness"]["baseColorTexture"] = {"index": 0}
        gltf["materials"][0]["alphaMode"] = "MASK"
    bin_ = b"".join(blobs)
    gltf["buffers"] = [{"byteLength": len(bin_)}]
    js = json.dumps(gltf, separators=(",", ":")).encode()
    js += b" " * ((-len(js)) % 4)
    total = 12 + 8 + len(js) + 8 + len(bin_)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(js), 0x4E4F534A) + js)
        f.write(struct.pack("<II", len(bin_), 0x004E4942) + bin_)


def info(m):
    lo, hi = m.bbox()
    return {"version": m.version, "verts": int(len(m.pos)), "tris": int(len(m.faces)), "lods": m.lods[:8],
            "bones": int(m.num_bones), "bbox_min": [round(float(x), 5) for x in lo],
            "bbox_max": [round(float(x), 5) for x in hi], "size": [round(float(x), 5) for x in hi - lo],
            "has_vertex_color": bool(m.col is not None and (m.col != 255).any()), "notes": m.notes}


# ---------------------------------------------------------------------------------------------
# asset cache helpers
# ---------------------------------------------------------------------------------------------
def mesh_asset(mesh_id, force=False):
    """Download mesh asset, convert to mesh.obj/mesh.glb/mesh.json. Returns (info dict | None, err)."""
    meta = rbxdl.fetch(mesh_id)
    if not meta.get("ok"):
        return None, f"download: {meta.get('status')} {meta.get('error', '')[:100]}"
    if meta["kind"] != "mesh":
        return None, f"not a mesh payload ({meta['kind']})"
    d = rbxdl.asset_dir(meta["id"])
    jpath = os.path.join(d, "mesh.json")
    if not force and os.path.exists(jpath) and os.path.exists(os.path.join(d, "mesh.glb")):
        return json.load(open(jpath)), None
    try:
        m = load(meta["path"])
    except Exception as e:  # noqa: BLE001
        return None, f"parse v{meta.get('mesh_version')}: {type(e).__name__}: {e}"
    write_obj(m, os.path.join(d, "mesh.obj"), name=f"mesh_{meta['id']}")
    write_glb(m, os.path.join(d, "mesh.glb"), name=f"mesh_{meta['id']}")
    inf = info(m)
    json.dump(inf, open(jpath, "w"), indent=1)
    return inf, None


_ref_re = re.compile(rb"(rbxassetid://\d+|roblox\.com/asset/\?id=\d+)", re.I)


def image_asset(image_id, depth=0):
    """Download an image (following Decal -> Image indirection), save image.png. Returns (png path, err)."""
    from PIL import Image
    meta = rbxdl.fetch(image_id)
    if not meta.get("ok"):
        return None, f"download: {meta.get('status')} {meta.get('error', '')[:100]}"
    d = rbxdl.asset_dir(meta["id"])
    png = os.path.join(d, "image.png")
    if os.path.exists(png):
        return png, None
    kind = meta["kind"]
    if kind in ("rbxm", "rbxmx") and depth < 2:
        raw = open(meta["path"], "rb").read()
        if kind == "rbxm":
            ids = re.findall(rb"rbxassetid://(\d+)|asset/\?id=(\d+)", raw)
        else:
            ids = re.findall(rb"rbxassetid://(\d+)|asset/\?id=(\d+)", raw)
        for a, b in ids:
            sub = int(a or b)
            if sub != meta["id"]:
                p, err = image_asset(sub, depth + 1)
                if p:
                    # link for convenience
                    try:
                        Image.open(p).save(png)
                    except Exception:  # noqa: BLE001
                        pass
                    return p, None
        return None, f"{kind} without image reference"
    if kind in ("png", "jpg", "webp", "gif", "bmp", "tga"):
        try:
            im = Image.open(meta["path"])
            im.load()
            if im.mode not in ("RGB", "RGBA"):
                im = im.convert("RGBA")
            im.save(png)
            return png, None
        except Exception as e:  # noqa: BLE001
            return None, f"image decode: {e}"
    return None, f"unsupported image kind {kind}"


def collect_refs(tree):
    """tree.json -> {'mesh': {id: [paths]}, 'image': {id: [paths]}, 'union': [paths]}"""
    meshes, images, unions = {}, {}, []
    for n in tree["nodes"]:
        p = n["props"]
        c = n["class"]
        if c == "MeshPart" or c == "SpecialMesh" or c == "FileMesh":
            mid = rbxdl.parse_asset_id(p.get("MeshId"))
            if mid:
                meshes.setdefault(mid, []).append(n["path"])
            tid = rbxdl.parse_asset_id(p.get("TextureID") or p.get("TextureId"))
            if tid:
                images.setdefault(tid, []).append(n["path"])
        elif c == "SurfaceAppearance":
            for k in ("ColorMap", "NormalMap", "MetalnessMap", "RoughnessMap"):
                tid = rbxdl.parse_asset_id(p.get(k))
                if tid:
                    images.setdefault(tid, []).append(n["path"] + "#" + k)
        elif c in ("Decal", "Texture"):
            tid = rbxdl.parse_asset_id(p.get("Texture"))
            if tid:
                images.setdefault(tid, []).append(n["path"])
        elif c in ("UnionOperation", "IntersectOperation", "NegateOperation"):
            unions.append(n["path"])
    return {"mesh": meshes, "image": images, "union": unions}


def process_model(model_id, jobs=8, quiet=False):
    import concurrent.futures as cf
    d = rbxdl.asset_dir(model_id)
    tree = json.load(open(os.path.join(d, "tree.json")))
    refs = collect_refs(tree)
    out = {"model": int(model_id), "mesh": {}, "image": {}, "unions": refs["union"]}
    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        mf = {ex.submit(mesh_asset, mid): mid for mid in refs["mesh"]}
        imf = {ex.submit(image_asset, iid): iid for iid in refs["image"]}
        for f in cf.as_completed(list(mf) + list(imf)):
            if f in mf:
                mid = mf[f]
                inf, err = f.result()
                out["mesh"][str(mid)] = {"ok": inf is not None, "err": err, "uses": len(refs["mesh"][mid]),
                                         **({k: inf[k] for k in ("version", "verts", "tris", "size")} if inf else {})}
            else:
                iid = imf[f]
                png, err = f.result()
                size = None
                if png:
                    from PIL import Image
                    with Image.open(png) as im:
                        size = list(im.size)
                        mode = im.mode
                else:
                    mode = None
                out["image"][str(iid)] = {"ok": png is not None, "err": err, "png": os.path.relpath(png, rbxdl.ROOT) if png else None,
                                          "size": size, "mode": mode, "uses": refs["image"][iid][:4]}
    json.dump(out, open(os.path.join(d, "deps.json"), "w"), indent=1)
    if not quiet:
        mok = sum(1 for v in out["mesh"].values() if v["ok"])
        iok = sum(1 for v in out["image"].values() if v["ok"])
        vers = {}
        for v in out["mesh"].values():
            if v.get("version"):
                vers[v["version"]] = vers.get(v["version"], 0) + 1
        print(f"model {model_id}: meshes {mok}/{len(out['mesh'])} {vers}  images {iok}/{len(out['image'])}  unions {len(out['unions'])}")
        for k, v in list(out["mesh"].items()) + list(out["image"].items()):
            if not v["ok"]:
                print(f"   FAIL {k}: {v['err']}")
    return out


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    cmd = argv[0]
    if cmd == "convert":
        src, dst = argv[1], argv[2]
        tex = argv[argv.index("--texture") + 1] if "--texture" in argv else None
        m = load(src)
        if dst.endswith(".obj"):
            write_obj(m, dst, mtl_texture=tex)
        else:
            write_glb(m, dst, texture_png=tex)
        print(json.dumps(info(m)))
    elif cmd == "info":
        print(json.dumps(info(load(argv[1])), indent=1))
    elif cmd == "model":
        jobs = int(argv[argv.index("-j") + 1]) if "-j" in argv else 8
        ids = [a for i, a in enumerate(argv[1:], 1) if a.isdigit() and argv[i - 1] != "-j"]
        for mid in ids:
            process_model(int(mid), jobs=jobs)
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
