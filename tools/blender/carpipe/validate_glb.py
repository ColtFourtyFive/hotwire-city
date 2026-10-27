#!/usr/bin/env python3
"""Check a carpipe GLB (+ sidecar) against the Roblox car budget, without Blender.

    python3 -I tools/blender/carpipe/validate_glb.py tools/blender/carpipe/out/carconcept/carconcept.glb

Checks: required object names, one material per mesh, triangles per MeshPart <= 20000, Body(+Body2) <= 8000,
whole car <= 18000, every texture <= 1024 px, wheel nodes carry their centre as translation and match the sidecar,
front of the car at -Z.  Exit code 1 on failure.
"""
import json
import os
import struct
import sys

REQUIRED = ["Body", "WheelFL", "WheelFR", "WheelRL", "WheelRR"]
OPTIONAL = ["Body2", "Glass", "Trim", "LightsFront", "LightsRear", "Interior", "SirenRed", "SirenBlue", "Sign",
            "WheelML", "WheelMR", "WheelML1", "WheelML2", "WheelMR1", "WheelMR2"]


def read_glb(path):
    b = open(path, "rb").read()
    magic, ver, length = struct.unpack("<4sII", b[:12])
    assert magic == b"glTF", "not a GLB"
    off = 12
    js = binc = None
    while off < length:
        clen, ctype = struct.unpack("<I4s", b[off:off + 8])
        chunk = b[off + 8: off + 8 + clen]
        if ctype == b"JSON":
            js = json.loads(chunk)
        elif ctype == b"BIN\x00":
            binc = chunk
        off += 8 + clen
    return js, binc


def png_size(data):
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", data[16:24])
    if data[:2] == b"\xff\xd8":  # JPEG: scan SOF markers
        i = 2
        while i < len(data):
            if data[i] != 0xFF:
                i += 1
                continue
            m = data[i + 1]
            if m in (0xC0, 0xC1, 0xC2):
                h, w = struct.unpack(">HH", data[i + 5:i + 9])
                return w, h
            i += 2 + struct.unpack(">H", data[i + 2:i + 4])[0]
    return None


def main(path):
    js, binc = read_glb(path)
    errors, notes = [], []
    nodes = {n["name"]: n for n in js["nodes"] if "mesh" in n}
    for r in REQUIRED:
        if r not in nodes:
            errors.append(f"missing object {r}")
    missing_opt = [n for n in ("Glass", "Trim", "LightsFront", "LightsRear", "Interior") if n not in nodes]
    if missing_opt:
        notes.append(f"no {missing_opt} (source had none / painted into the body texture)")
    extra = [n for n in nodes if n not in REQUIRED + OPTIONAL]
    if extra:
        notes.append(f"extra objects: {extra}")
    total = 0
    body = 0
    tris = {}
    for name, n in nodes.items():
        m = js["meshes"][n["mesh"]]
        if len(m["primitives"]) != 1:
            errors.append(f"{name}: {len(m['primitives'])} primitives/materials (Roblox wants 1 per MeshPart)")
        t = 0
        for p in m["primitives"]:
            if "indices" in p:
                t += js["accessors"][p["indices"]]["count"] // 3
            else:
                t += js["accessors"][p["attributes"]["POSITION"]]["count"] // 3
        tris[name] = t
        total += t
        if name in ("Body", "Body2"):
            body += t
        if t > 20000:
            errors.append(f"{name}: {t} tris > 20000 MeshPart limit")
    if body > 8000:
        errors.append(f"Body(+Body2) {body} tris > 8000")
    if total > 18000:
        errors.append(f"car total {total} tris > 18000")
    for i, img in enumerate(js.get("images", [])):
        bv = js["bufferViews"][img["bufferView"]]
        data = binc[bv.get("byteOffset", 0): bv.get("byteOffset", 0) + bv["byteLength"]]
        sz = png_size(data)
        if sz is None:
            notes.append(f"image {img.get('name')}: unknown format")
        elif max(sz) > 1024:
            errors.append(f"image {img.get('name')}: {sz} > 1024 px")
    side_p = os.path.splitext(path)[0] + ".json"
    if os.path.exists(side_p):
        side = json.load(open(side_p))
        for k, w in side.get("wheels", {}).items():
            n = nodes.get(w["object"])
            if n is None:
                continue
            t = n.get("translation", [0, 0, 0])
            if max(abs(a - b) for a, b in zip(t, w["center"])) > 1e-2:
                errors.append(f"{w['object']}: node translation {t} != sidecar centre {w['center']}")
        fz = [w["center"][2] for k, w in side.get("wheels", {}).items() if k.startswith("F")]
        rz = [w["center"][2] for k, w in side.get("wheels", {}).items() if k.startswith("R")]
        if fz and rz and not (sum(fz) / len(fz) < sum(rz) / len(rz)):
            errors.append("front wheels are not at -Z (front must face -Z)")
    else:
        notes.append("no sidecar json found")
    print(f"{os.path.basename(path)}: {total} tris total, body {body}; " +
          ", ".join(f"{k} {v}" for k, v in tris.items()))
    for n in notes:
        print("note:", n)
    for e in errors:
        print("FAIL:", e)
    print("OK" if not errors else f"{len(errors)} problem(s)")
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(max(main(p) for p in sys.argv[1:]) if len(sys.argv) > 1 else 2)
