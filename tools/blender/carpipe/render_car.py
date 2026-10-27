#!/usr/bin/env python3
"""Before/after preview renders for a carpipe output.

    python3 -I tools/blender/carpipe/render_car.py --model carconcept            # all shots
    python3 -I tools/blender/carpipe/render_car.py --model carconcept --shots after_studio,street_day

Shots: before_studio, after_studio, after_rear, roles, street_day, street_night  (+ <name>_sheet.png).
Renders: Cycles CPU, OIDN denoise, 960x540, <= 64 samples, into docs/v2/proto/carpipe/.
"""
import argparse
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

import bpy  # noqa: E402
import numpy as np  # noqa: E402

from carpipe import analyze, importer, render as R, util  # noqa: E402

ALL = ["before_studio", "after_studio", "after_rear", "roles", "street_day", "street_night"]
PAINTS = [(0.62, 0.04, 0.05), (0.05, 0.06, 0.07), (0.80, 0.80, 0.78)]


def load_before(path, cfg):
    """Raw import with the source materials, only oriented/grounded/scaled (call BEFORE building the stage)."""
    importer.import_any(path, cfg)
    objs = importer.flatten(subsurf_cap=cfg.get("subsurf_cap", 1))
    mdir = os.path.dirname(os.path.abspath(path))
    for d in (mdir, os.path.dirname(mdir)):
        importer.discover_textures(d, cfg.get("textures"))
    car = analyze.Car(cfg)
    car.build(objs)
    car.orient()
    car.find_wheels()
    car.ground_and_scale(float(cfg.get("length", 17.0)))
    return car.obj


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--in", dest="inp", help="source model file when not in models.json")
    ap.add_argument("--outdir", default=os.path.join(REPO, "docs", "v2", "proto", "carpipe"))
    ap.add_argument("--glbdir", default=os.path.join(HERE, "out"))
    ap.add_argument("--shots", default=",".join(ALL))
    ap.add_argument("--samples", type=int, default=48)
    a = ap.parse_args()
    reg = json.load(open(os.path.join(HERE, "models.json")))
    if os.path.exists(os.path.join(HERE, "models_local.json")):
        reg.update(json.load(open(os.path.join(HERE, "models_local.json"))))
    cfg = reg.get(a.model, {})
    src = a.inp or os.path.join(HERE, "_cache", "models", a.model, cfg.get("file", ""))
    glb = os.path.join(a.glbdir, a.model, a.model + ".glb")
    side = json.load(open(os.path.join(a.glbdir, a.model, a.model + ".json")))
    L = side["dimensions"]["length"]
    H = side["dimensions"]["height"]
    os.makedirs(a.outdir, exist_ok=True)
    shots = a.shots.split(",")
    out = {}
    tgt = (0, 0, H * 0.42)
    for shot in shots:
        util.reset_scene()
        R.setup_cycles(samples=a.samples)
        p = os.path.join(a.outdir, f"{a.model}_{shot}.png")
        if shot == "before_studio":
            load_before(src, cfg)
            R.studio(L)
            R.camera(tgt, L, az_deg=35, el_deg=9)
        elif shot in ("after_studio", "after_rear", "roles"):
            R.studio(L)
            root, objs = R.load_glb(glb)
            if shot == "roles":
                R.colorize_roles(objs)
            if shot == "after_rear":
                R.camera(tgt, L, az_deg=150, el_deg=11)
            else:
                R.camera(tgt, L, az_deg=35, el_deg=9)
        elif shot == "street_day":
            R.street(L, night=False)
            W = side["dimensions"]["width"]
            lane = L * 0.42
            # three paint variants parked/driving in the near lanes
            R.load_glb(glb, offset=(lane * 0.5, 0, 0), paint=PAINTS[0])
            R.load_glb(glb, offset=(lane * 1.5, -L * 1.25, 0), paint=PAINTS[2])
            R.load_glb(glb, offset=(-lane * 0.5, L * 1.6, 0), rot_z=math.pi, paint=PAINTS[1])
            R.camera((lane * 0.6, -L * 0.2, H * 0.45), L, az_deg=28, el_deg=7, lens=40, dist_mul=1.15)
        elif shot == "street_night":
            R.street(L, night=True)
            lane = L * 0.42
            R.load_glb(glb, offset=(lane * 0.5, 0, 0), paint=PAINTS[1], lights_on=True)
            R.load_glb(glb, offset=(-lane * 0.5, L * 1.7, 0), rot_z=math.pi, paint=PAINTS[2], lights_on=True)
            R.camera((lane * 0.5, L * 0.1, H * 0.45), L, az_deg=24, el_deg=6, lens=40, dist_mul=1.0)
        else:
            continue
        out[shot] = R.render_to(p)
    sheet_shots = [s for s in ["before_studio", "after_studio", "roles", "street_day"] if s in out]
    if len(sheet_shots) >= 2:
        labels = {"before_studio": "BEFORE: raw import (source materials)",
                  "after_studio": f"AFTER: Roblox GLB ({side['triangles']['total']} tris)",
                  "roles": "AFTER: object roles (Body/Glass/Lights/Trim/Interior/Wheels)",
                  "street_day": "AFTER: 3 paint colours, golden-hour street"}
        R.composite([out[s] for s in sheet_shots], os.path.join(a.outdir, f"{a.model}_sheet.png"),
                    labels=[labels[s] for s in sheet_shots], cols=2)


if __name__ == "__main__":
    main()
