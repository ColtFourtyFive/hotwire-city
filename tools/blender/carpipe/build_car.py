#!/usr/bin/env python3
"""Turn any realistic car model into a Roblox-ready car GLB + JSON sidecar.

    # a registered test model (see models.json; fetch with fetch_models.py first)
    python3 -I tools/blender/carpipe/build_car.py --model carconcept

    # any file
    python3 -I tools/blender/carpipe/build_car.py --in path/to/car.glb --name sedan01 --length 17 [--front -y]

Outputs to tools/blender/carpipe/out/<name>/: <name>.glb, <name>.json, textures/*.png, islands_debug.txt
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from carpipe import pipeline, util  # noqa: E402


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", help="id from models.json")
    ap.add_argument("--in", dest="inp", help="model file (.glb .gltf .fbx .obj .blend .usd* .ply .stl .dae .3ds)")
    ap.add_argument("--name", help="output name (default: model id / file stem)")
    ap.add_argument("--out", default=os.path.join(HERE, "out"), help="output root")
    ap.add_argument("--length", type=float, help="bumper-to-bumper length in studs (default: auto = real metres x 3.4)")
    ap.add_argument("--front", choices=["+x", "-x", "+y", "-y"], help="force the front direction (file axes)")
    ap.add_argument("--up", choices=["+x", "-x", "+y", "-y", "+z", "-z"], help="force the up axis (file axes)")
    ap.add_argument("--config", help="extra JSON config file (same keys as a models.json entry)")
    ap.add_argument("--no-bake", action="store_true", help="skip texture baking (fast geometry check)")
    ap.add_argument("--save-blend", action="store_true", help="also save the final scene as .blend")
    a = ap.parse_args(argv)

    cfg = {}
    if a.model:
        reg = json.load(open(os.path.join(HERE, "models.json")))
        loc = os.path.join(HERE, "models_local.json")  # written by sketchfab_fetch.py
        if os.path.exists(loc):
            reg.update(json.load(open(loc)))
        if a.model not in reg:
            sys.exit(f"unknown model id {a.model}; known: {[k for k in reg if not k.startswith('_')]}")
        cfg.update(reg[a.model])
        path = os.path.join(HERE, "_cache", "models", a.model, cfg["file"])
        name = a.name or a.model
    elif a.inp:
        path = os.path.abspath(a.inp)
        name = a.name or os.path.splitext(os.path.basename(path))[0]
        cfg["source"] = {"file": os.path.basename(path)}
    else:
        ap.error("give --model or --in")
    if a.config:
        cfg.update(json.load(open(a.config)))
    if a.length:
        cfg["length"] = a.length
    if a.front:
        cfg["front"] = a.front
    if a.up:
        cfg["up"] = a.up
    if a.no_bake:
        cfg["bake"] = False
    if a.save_blend:
        cfg["save_blend"] = True
    # textures paths in models.json are relative to the model file's folder
    if "textures" in cfg:
        cfg["textures"] = {k: v for k, v in cfg["textures"].items()}
    out_dir = os.path.join(a.out, name)
    side = pipeline.run(path, out_dir, name, cfg)
    util.log("done:", os.path.join(out_dir, name + ".glb"), "tris", side["triangles"]["total"],
             "warnings", side["warnings"])


if __name__ == "__main__":
    main()
