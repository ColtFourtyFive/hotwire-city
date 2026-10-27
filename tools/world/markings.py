#!/usr/bin/env python3
"""Paint one lane-marking texture per road cross-section and upload them (MapBuilder v2 road markings).

    lune run tools/world/markings_export.luau build/world/markings.json
    python3 -I tools/world/markings.py [--no-upload] [--force] [--preview docs/v2/early/world/markings_sheet.png]

Each texture is transparent paint on clear: U (columns) = across the road, one tile = the curb-to-curb width;
V (rows) = along the road, one tile = PERIOD studs (World/Markings.PERIOD). Lines come from World/Markings.signature,
the same code MapBuilder uses, so the texture always matches the lanes. Paint is worn: alpha breaks up with a
deterministic noise, a little grime is mixed into the colour.

Outputs: assets/world/markings/<key>.png, assets/world/markings/manifest.json (ids, sha256), and the GENERATED block
of src/server/Systems/World/Markings.luau (key -> rbxassetid). Uploads go through tools/rbxcloud.py as asset type Image
(the key stays in ~/.config/hotwire and is never printed).
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time

import numpy as np
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
OUT = os.path.join(ROOT, "assets", "world", "markings")
LUAU = os.path.join(ROOT, "src", "server", "Systems", "World", "Markings.luau")
USER_ID = "11686693147"
SIZE_U, SIZE_V = 1024, 1024

WHITE = (236, 236, 230)
YELLOW = (232, 178, 46)


def noise(shape, seed, scale):
    """Smooth value noise in 0..1 (bilinear upsampled random grid)."""
    rng = np.random.default_rng(seed)
    gh, gw = max(2, shape[0] // scale + 2), max(2, shape[1] // scale + 2)
    g = rng.random((gh, gw)).astype(np.float32)
    img = Image.fromarray((g * 255).astype(np.uint8)).resize((shape[1], shape[0]), Image.BILINEAR)
    return np.asarray(img).astype(np.float32) / 255.0


def paint(spec, period, seed):
    W = spec["width"]
    pu = SIZE_U / W  # px per stud across
    pv = SIZE_V / period  # px per stud along
    rgb = np.zeros((SIZE_V, SIZE_U, 3), np.float32)
    alpha = np.zeros((SIZE_V, SIZE_U), np.float32)

    def u_of(x):
        return (x + W / 2) * pu

    def band(x0, x1, v0, v1, color):
        u0, u1 = int(round(u_of(x0))), int(round(u_of(x1)))
        if u1 <= u0:
            u1 = u0 + 1
        u0, u1 = max(0, u0), min(SIZE_U, u1)
        a0, a1 = int(round(v0 * pv)), int(round(v1 * pv))
        a0, a1 = max(0, a0), min(SIZE_V, a1)
        if u1 <= u0 or a1 <= a0:
            return
        rgb[a0:a1, u0:u1] = color
        alpha[a0:a1, u0:u1] = 1.0

    line = 0.45
    for ln in spec["lines"]:
        x, kind = ln["x"], ln["kind"]
        if kind == "white_solid":
            band(x - line / 2, x + line / 2, 0, period, WHITE)
        elif kind == "yellow_solid":
            band(x - line / 2, x + line / 2, 0, period, YELLOW)
        elif kind == "yellow_double":
            for dx in (-line, line):
                band(x + dx - line / 2, x + dx + line / 2, 0, period, YELLOW)
        elif kind == "white_dash" or kind == "yellow_dash":
            col = WHITE if kind == "white_dash" else YELLOW
            v = 0.0
            while v < period - 0.01:
                band(x - line / 2, x + line / 2, v, v + 10, col)
                v += 40
        elif kind == "ticks":
            x1 = ln.get("x1", x)
            lo, hi = min(x, x1), max(x, x1)
            v = 0.0
            while v < period - 0.01:
                band(lo, hi, v, v + line, WHITE)
                v += 24
        elif kind == "runway_center":
            v = 0.0
            while v < period - 0.01:
                band(x - 1.5, x + 1.5, v, v + 30, WHITE)
                v += 60
        else:
            raise ValueError("unknown line kind " + kind)

    # wear: paint alpha 0.55-0.9 with smooth breakup, sparse chips, grime tint
    h = int(hashlib.sha1(spec["key"].encode()).hexdigest()[:8], 16) ^ seed
    n1 = noise(alpha.shape, h, 48)
    n2 = noise(alpha.shape, h + 1, 9)
    chips = (noise(alpha.shape, h + 2, 3) > 0.83).astype(np.float32)
    wear = np.clip(0.62 + 0.36 * n1 - 0.25 * (n2 > 0.72) - 0.6 * chips, 0.0, 0.92)
    a = alpha * wear
    grime = 0.82 + 0.18 * n2[..., None]
    rgb = rgb * grime
    out = np.zeros((SIZE_V, SIZE_U, 4), np.uint8)
    out[..., :3] = np.clip(rgb, 0, 255).astype(np.uint8)
    out[..., 3] = np.clip(a * 255, 0, 255).astype(np.uint8)
    # transparent pixels keep the paint colour (no dark fringes when the engine filters / mipmaps)
    mask = out[..., 3] == 0
    out[..., :3][mask] = (180, 180, 176)
    return Image.fromarray(out, "RGBA")


def rbxcloud(*args):
    cmd = [sys.executable, os.path.join(ROOT, "tools", "rbxcloud.py")] + list(args)
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    return r.stdout.strip() + r.stderr.strip()


def upload(path, name):
    out = rbxcloud("upload-image", path, name, USER_ID)
    m = re.search(r'"path"\s*:\s*"(operations/[^"]+)"', out)
    if not m:
        m = re.search(r"(operations/[0-9a-zA-Z\-]+)", out)
    if not m:
        raise RuntimeError("upload failed for %s: %s" % (name, out[:300]))
    op = m.group(1)
    for _ in range(60):
        time.sleep(2)
        res = rbxcloud("operation", op)
        m2 = re.search(r'"assetId"\s*:\s*"?(\d+)', res)
        if m2:
            return m2.group(1)
    raise RuntimeError("no assetId for %s (%s)" % (name, op))


def write_luau(images):
    src = open(LUAU).read()
    lines = ["-- BEGIN GENERATED (tools/world/markings.py) - do not edit by hand", "Markings.Images = {"]
    for key in sorted(images):
        lines.append('\t["%s"] = "rbxassetid://%s",' % (key, images[key]))
    lines.append("} :: { [string]: string }")
    lines.append("-- END GENERATED")
    block = "\n".join(lines)
    src2 = re.sub(
        r"-- BEGIN GENERATED \(tools/world/markings\.py\).*?-- END GENERATED", block, src, flags=re.S
    )
    open(LUAU, "w").write(src2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--specs", default=os.path.join(ROOT, "build", "world", "markings.json"))
    ap.add_argument("--no-upload", action="store_true")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--preview", default=None)
    a = ap.parse_args()
    data = json.load(open(a.specs))
    period = data["period"]
    os.makedirs(OUT, exist_ok=True)
    man_path = os.path.join(OUT, "manifest.json")
    manifest = json.load(open(man_path)) if os.path.exists(man_path) else {}
    images = {}
    tiles = []
    for spec in data["signatures"]:
        key = spec["key"]
        img = paint(spec, period, 1337)
        path = os.path.join(OUT, key + ".png")
        img.save(path, optimize=True)
        tiles.append((key, img))
        sha = hashlib.sha256(open(path, "rb").read()).hexdigest()
        entry = manifest.get(key)
        if entry and entry.get("sha256") == sha and entry.get("id") and not a.force:
            images[key] = entry["id"]
            continue
        if a.no_upload:
            if entry and entry.get("id"):
                images[key] = entry["id"]
            continue
        aid = upload(path, "HC road " + key)
        manifest[key] = {"id": aid, "sha256": sha, "width": spec["width"], "period": period}
        images[key] = aid
        print("uploaded", key, aid)
    json.dump(manifest, open(man_path, "w"), indent=1, sort_keys=True)
    write_luau(images)
    print("markings: %d textures, %d with ids" % (len(tiles), len(images)))
    if a.preview:
        cols = 6
        rows = (len(tiles) + cols - 1) // cols
        cell = 200
        sheet = Image.new("RGB", (cols * cell, rows * (cell + 10)), (40, 40, 44))
        for i, (key, img) in enumerate(tiles):
            bg = Image.new("RGBA", img.size, (78, 78, 82, 255))
            comp = Image.alpha_composite(bg, img).convert("RGB").resize((cell - 8, cell - 8))
            sheet.paste(comp, ((i % cols) * cell + 4, (i // cols) * (cell + 10) + 4))
        os.makedirs(os.path.dirname(a.preview), exist_ok=True)
        sheet.save(a.preview)
        print("preview", a.preview)


if __name__ == "__main__":
    main()
