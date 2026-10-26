#!/usr/bin/env python3
"""Texture-preserving quadric decimation of a single-primitive textured GLB (trimesh/sam_3_3d layout).
Usage: python3 decimate.py in.glb out.glb target_faces
Keeps POSITION + TEXCOORD_0 + indices + the embedded base-color image + material, same as the input layout.
"""
import json
import struct
import sys

import numpy as np
import pymeshlab

COMP = {5121: np.uint8, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
NC = {"SCALAR": 1, "VEC2": 2, "VEC3": 3}


def load(path):
    d = open(path, "rb").read()
    off = 12
    js = binc = None
    while off < len(d):
        clen, ctype = struct.unpack_from("<II", d, off)
        chunk = d[off + 8: off + 8 + clen]
        if ctype == 0x4E4F534A:
            js = json.loads(chunk)
        elif ctype == 0x004E4942:
            binc = chunk
        off += 8 + clen
    return js, binc


def acc(js, binc, i):
    a = js["accessors"][i]
    bv = js["bufferViews"][a["bufferView"]]
    dt = COMP[a["componentType"]]
    n = NC[a["type"]]
    start = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    return np.frombuffer(binc, dtype=dt, count=a["count"] * n, offset=start).reshape(a["count"], n).copy()


def main():
    src, dst, target = sys.argv[1], sys.argv[2], int(sys.argv[3])
    js, binc = load(src)
    assert len(js["meshes"]) == 1 and len(js["meshes"][0]["primitives"]) == 1
    prim = js["meshes"][0]["primitives"][0]
    idx = acc(js, binc, prim["indices"]).reshape(-1, 3).astype(np.int64)
    pos = acc(js, binc, prim["attributes"]["POSITION"]).astype(np.float64)
    uv = acc(js, binc, prim["attributes"]["TEXCOORD_0"]).astype(np.float64)
    img_bv = js["bufferViews"][js["images"][0]["bufferView"]]
    img = binc[img_bv.get("byteOffset", 0): img_bv.get("byteOffset", 0) + img_bv["byteLength"]]
    mime = js["images"][0].get("mimeType", "image/png")

    # weld split (seam) vertices by position, keep per-corner UVs as wedge texcoords
    key = np.round(pos / 1e-6).astype(np.int64)
    _, inv = np.unique(key, axis=0, return_inverse=True)
    inv = inv.reshape(-1)
    nv = inv.max() + 1
    wpos = np.zeros((nv, 3))
    wpos[inv] = pos
    faces = inv[idx]
    good = (faces[:, 0] != faces[:, 1]) & (faces[:, 1] != faces[:, 2]) & (faces[:, 0] != faces[:, 2])
    faces = faces[good]
    wedge = uv[idx[good]].reshape(-1, 2)

    import os, tempfile
    tmpd = tempfile.mkdtemp(prefix="hcdec_")
    open(os.path.join(tmpd, "tex.png"), "wb").write(bytes(img))
    NL = chr(10)
    open(os.path.join(tmpd, "m.mtl"), "w").write("newmtl mat0" + NL + "Kd 1 1 1" + NL + "map_Kd tex.png" + NL)
    with open(os.path.join(tmpd, "m.obj"), "w") as f:
        f.write("mtllib m.mtl" + NL + "usemtl mat0" + NL)
        f.write("".join(("v %.7f %.7f %.7f" % tuple(p)) + NL for p in wpos))
        f.write("".join(("vt %.7f %.7f" % (t[0], 1.0 - t[1])) + NL for t in wedge))
        f.write("".join(("f %d/%d %d/%d %d/%d" % (a + 1, 3 * i + 1, b + 1, 3 * i + 2, c + 1, 3 * i + 3)) + NL
                        for i, (a, b, c) in enumerate(faces)))
    ms = pymeshlab.MeshSet()
    ms.load_new_mesh(os.path.join(tmpd, "m.obj"))
    print("welded verts", nv, "faces", len(faces), "loaded", ms.current_mesh().face_number())
    ms.meshing_decimation_quadric_edge_collapse_with_texture(targetfacenum=target, qualitythr=0.5, extratcoordw=1.0,
                                                             preserveboundary=True, optimalplacement=True,
                                                             preservenormal=True, planarquadric=True)
    out = ms.current_mesh()
    V = out.vertex_matrix()
    F = out.face_matrix()
    W = out.wedge_tex_coord_matrix().reshape(-1, 3, 2).copy()
    W[..., 1] = 1.0 - W[..., 1]
    print("decimated faces", len(F))

    # re-split by (vertex, uv) per corner
    corners_v = F.reshape(-1)
    corners_uv = W.reshape(-1, 2)
    k = np.concatenate([corners_v[:, None].astype(np.float64), np.round(corners_uv * 1e6)], axis=1)
    uk, cinv = np.unique(k, axis=0, return_inverse=True)
    cinv = cinv.reshape(-1)
    npos = V[uk[:, 0].astype(np.int64)].astype(np.float32)
    nuv = (uk[:, 1:] / 1e6).astype(np.float32)
    nidx = cinv.astype(np.uint32)

    # build GLB
    blobs = []
    views = []
    off = 0

    def add(b):
        nonlocal off
        pad = (-off) % 4
        if pad:
            blobs.append(b"\0" * pad)
            off += pad
        views.append({"buffer": 0, "byteOffset": off, "byteLength": len(b)})
        blobs.append(b)
        off += len(b)
        return len(views) - 1

    vi = add(nidx.tobytes())
    vp = add(npos.tobytes())
    vimg = add(bytes(img))
    vt = add(nuv.tobytes())
    out_js = {
        "scene": 0, "scenes": [{"nodes": [0]}], "asset": {"version": "2.0", "generator": "hc-decimate"},
        "meshes": [{"name": "geometry_0", "primitives": [{"attributes": {"POSITION": 1, "TEXCOORD_0": 2}, "indices": 0,
                                                          "mode": 4, "material": 0}]}],
        "accessors": [
            {"componentType": 5125, "type": "SCALAR", "bufferView": vi, "count": int(len(nidx)),
             "max": [int(nidx.max())], "min": [int(nidx.min())]},
            {"componentType": 5126, "type": "VEC3", "bufferView": vp, "count": int(len(npos)),
             "max": npos.max(0).tolist(), "min": npos.min(0).tolist()},
            {"componentType": 5126, "type": "VEC2", "bufferView": vt, "count": int(len(nuv)),
             "max": nuv.max(0).tolist(), "min": nuv.min(0).tolist()},
        ],
        "images": [{"bufferView": vimg, "mimeType": mime}],
        "textures": [{"source": 0}],
        "materials": js["materials"][:1],
        "nodes": [{"name": "geometry_0", "mesh": 0}],
        "bufferViews": views,
    }
    binbody = b"".join(blobs)
    binbody += b"\0" * ((-len(binbody)) % 4)
    out_js["buffers"] = [{"byteLength": len(binbody)}]
    jb = json.dumps(out_js).encode()
    jb += b" " * ((-len(jb)) % 4)
    total = 12 + 8 + len(jb) + 8 + len(binbody)
    with open(dst, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(jb), 0x4E4F534A))
        f.write(jb)
        f.write(struct.pack("<II", len(binbody), 0x004E4942))
        f.write(binbody)
    print("wrote", dst, "tris", len(nidx) // 3, "verts", len(npos))


if __name__ == "__main__":
    main()
