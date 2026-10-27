#!/usr/bin/env python3
"""Download the carpipe test cars (models.json) and the CC0 render assets (Poly Haven HDRIs + ground textures).

    python3 -I tools/blender/carpipe/fetch_models.py            # everything, idempotent
    python3 -I tools/blender/carpipe/fetch_models.py carconcept # one model

Everything lands in tools/blender/carpipe/_cache/ (do not commit).  Each model folder gets SOURCE.json with
licence + attribution copied from models.json.  Archives are unpacked into <id>/src/.
"""
import json
import os
import sys
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "_cache")
UA = {"User-Agent": "HotwireCity-carpipe/1.0"}

HDRIS = {  # Poly Haven, CC0
    "studio": ("studio_small_09", "2k"),
    "street_sunset": ("sunset_jhbcentral", "2k"),
    "street_night": ("hansaplatz", "2k"),
}
TEXTURES = {  # Poly Haven, CC0 (1k jpg)
    "asphalt": "asphalt_02",
    "sidewalk": "large_grey_tiles",
    "curb": "concrete_floor_01",
}
MAPS = {"diff": "Diffuse", "nor": "nor_gl", "rough": "Rough"}


def get(url, dst):
    if os.path.exists(dst) and os.path.getsize(dst) > 0:
        return False
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=180) as r, open(dst + ".part", "wb") as f:
        while True:
            b = r.read(1 << 20)
            if not b:
                break
            f.write(b)
    os.replace(dst + ".part", dst)
    print("downloaded", os.path.relpath(dst, HERE))
    return True


def ph_files(asset_id):
    req = urllib.request.Request(f"https://api.polyhaven.com/files/{asset_id}", headers=UA)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def fetch_model(mid, ent):
    d = os.path.join(CACHE, "models", mid)
    url = ent["source"]["download"]
    dst = os.path.join(d, os.path.basename(url.split("?")[0]))
    get(url, dst)
    if dst.endswith(".zip"):
        src = os.path.join(d, "src")
        if not os.path.isdir(src):
            with zipfile.ZipFile(dst) as z:
                for m in z.namelist():  # refuse path traversal
                    p = os.path.realpath(os.path.join(src, m))
                    if not p.startswith(os.path.realpath(src)):
                        raise RuntimeError(f"unsafe path in zip: {m}")
                z.extractall(src)
    with open(os.path.join(d, "SOURCE.json"), "w") as f:
        json.dump(ent["source"], f, indent=2)


def fetch_render_assets():
    for key, (pid, res) in HDRIS.items():
        dst = os.path.join(CACHE, "hdri", key + ".hdr")
        if not os.path.exists(dst):
            get(ph_files(pid)["hdri"][res]["hdr"]["url"], dst)
    for key, pid in TEXTURES.items():
        files = None
        for short, long in MAPS.items():
            dst = os.path.join(CACHE, "tex", key, short + ".jpg")
            if os.path.exists(dst):
                continue
            files = files or ph_files(pid)
            ent = files.get(long, {}).get("1k", {}).get("jpg")
            if ent:
                get(ent["url"], dst)


def main(argv):
    reg = json.load(open(os.path.join(HERE, "models.json")))
    ids = argv or [k for k in reg if not k.startswith("_")]
    for mid in ids:
        try:
            fetch_model(mid, reg[mid])
        except Exception as e:  # keep going; report
            print("FAILED", mid, e)
    fetch_render_assets()
    with open(os.path.join(CACHE, "SOURCES.txt"), "w") as f:
        f.write("Render assets: Poly Haven (CC0) HDRIs " + ", ".join(v[0] for v in HDRIS.values()) +
                "; textures " + ", ".join(TEXTURES.values()) + "\n")


if __name__ == "__main__":
    main(sys.argv[1:])
