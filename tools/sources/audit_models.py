#!/usr/bin/env python3
"""Audit downloaded Sketchfab GLBs for licensing / IP / cleanup risks (pure Python, no Blender).

Usage: python3 -I tools/sources/audit_models.py   -> docs/v2/sourcing/audit.json + console table

Flags per model:
  brand      real car/gun maker named in the title/tags/node/material/image names (badges likely)
  rip_names  node naming typical of ripped game assets (GTA-style *_dummy, dside/pside, chassis_vlo,
             detach_*, pivot_*, LODs) -> provenance doubtful even if the upload says CC-BY
  logo_tex   images/materials named logo/badge/emblem/decal/sticker
  wheels     number of nodes whose name looks like a wheel/tyre
  textures   count + max size of embedded images (from PNG/JPEG headers)
"""
import json
import re
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "assets" / "source" / "sketchfab"
OUT = ROOT / "docs" / "v2" / "sourcing" / "audit.json"

BRANDS = re.compile(
    r"\b(ford|chevrolet|chevy|gmc|cadillac|dodge|chrysler|jeep|ram\b|lincoln|mercury|toyota|lexus|honda|acura|nissan|"
    r"mazda|subaru|mitsubishi|suzuki|yamaha|kawasaki|ducati|harley|bmw|mercedes|benz|audi|volkswagen|vw\b|porsche|"
    r"ferrari|lamborghini|maserati|mclaren|bugatti|koenigsegg|bentley|rolls|jaguar|land ?rover|range ?rover|hummer|"
    r"tesla|volvo|peugeot|renault|fiat|isuzu|hino|man\b|scania|freightliner|kenworth|peterbilt|"
    r"glock|beretta|colt|smith ?& ?wesson|remington|mossberg|benelli|heckler|h&k|hk\d|sig ?sauer|kimber|"
    r"magnum research|imi|kriss|barrett|accuracy international|nelson|rawlings|louisville|ka-?bar)", re.I)
RIP = re.compile(r"_dummy\b|dummy_|\bdside|\bpside|chassis_vlo|bodyshell|detach_|_pivot_|pivot_|_lod\d|lod\d_|_vlo\b|"
                 r"misc_[a-z]\b|extra_\d|windscreen_f|bonnet_|boot_|TrafficBadge|Maxcar", re.I)
LOGO = re.compile(r"logo|badge|emblem|decal|sticker|lettering|brand", re.I)
WHEEL = re.compile(r"wheel|tire|tyre|\brims?\b|_rim|rim_", re.I)
STEER = re.compile(r"steer|spare", re.I)


def glb_json(path):
    d = path.read_bytes()
    jl, _ = struct.unpack_from("<II", d, 12)
    js = json.loads(d[20:20 + jl])
    off = 20 + jl
    binc = b""
    if off + 8 <= len(d):
        bl, _ = struct.unpack_from("<II", d, off)
        binc = d[off + 8: off + 8 + bl]
    return js, binc


def img_size(js, binc, img):
    bv = img.get("bufferView")
    if bv is None:
        return 0
    v = js["bufferViews"][bv]
    head = binc[v.get("byteOffset", 0): v.get("byteOffset", 0) + 64 * 1024]
    if head[:8] == b"\x89PNG\r\n\x1a\n":
        w, h = struct.unpack(">II", head[16:24])
        return max(w, h)
    if head[:2] == b"\xff\xd8":
        i = 2
        while i < len(head) - 9:
            if head[i] != 0xFF:
                i += 1
                continue
            m = head[i + 1]
            if m in (0xC0, 0xC1, 0xC2):
                h, w = struct.unpack(">HH", head[i + 5:i + 9])
                return max(w, h)
            seg = struct.unpack(">H", head[i + 2:i + 4])[0]
            i += 2 + seg
    return 0


def main():
    res = {}
    for mp in sorted(SRC.glob("*/meta.json")):
        m = json.loads(mp.read_text())
        glb = mp.parent / "model.glb"
        if not glb.exists():
            continue
        js, binc = glb_json(glb)
        nodes = [n.get("name", "") for n in js.get("nodes", [])]
        mats = [x.get("name", "") for x in js.get("materials", [])]
        imgs = [x.get("name", "") or x.get("uri", "") for x in js.get("images", [])]
        names = nodes + mats + imgs
        title = " ".join([m["name"]] + (m.get("tags") or []))
        brand = sorted({b.group(0).lower() for b in BRANDS.finditer(title)} |
                       {b.group(0).lower() for n in names for b in BRANDS.finditer(n)})
        rip = sorted({n for n in nodes if RIP.search(n)})[:8]
        logo = sorted({n for n in names if LOGO.search(n)})[:8]
        wheels = [n for n in nodes if WHEEL.search(n) and not STEER.search(n)]
        sizes = [img_size(js, binc, x) for x in js.get("images", [])]
        res[m["slug"]] = {
            "class": m["class"], "kind": m["kind"], "author": m["author"]["username"],
            "brand": brand, "rip_names": rip, "logo_names": logo,
            "wheel_nodes": len(wheels), "textures": len(sizes), "tex_max": max(sizes, default=0),
            "materials": len(mats), "extensions": js.get("extensionsUsed", []),
            "animations": len(js.get("animations", [])), "skins": len(js.get("skins", [])),
        }
    OUT.write_text(json.dumps(res, indent=1))
    for k, v in res.items():
        flags = []
        if v["brand"]:
            flags.append("brand:" + ",".join(v["brand"][:4]))
        if v["rip_names"]:
            flags.append("RIP?:" + ",".join(v["rip_names"][:3]))
        if v["logo_names"]:
            flags.append("logo:" + ",".join(v["logo_names"][:2]))
        print(f"{k[:55]:55} wheels={v['wheel_nodes']:<3} tex={v['textures']}x{v['tex_max']:<5} {' | '.join(flags)}")


if __name__ == "__main__":
    main()
