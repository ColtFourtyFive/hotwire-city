#!/usr/bin/env python3
"""Hero shot: several carpipe GLBs together on the GTA-like street (golden hour or wet night).

    python3 -I tools/blender/carpipe/render_lineup.py --cars fairheaven_lt,canyon_taxi,carconcept,shvan_van,fairheaven_cop,goblin_supercar
    python3 -I tools/blender/carpipe/render_lineup.py --night ...

Writes docs/v2/proto/carpipe/lineup_street_{day,night}.png
"""
import argparse
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

from carpipe import render as R, util  # noqa: E402

PAINT = {"fairheaven_lt": (0.10, 0.22, 0.42), "carconcept": (0.62, 0.04, 0.05), "goblin_supercar": None,
         "shvan_van": (0.85, 0.85, 0.82), "musclecar": (0.93, 0.68, 0.08)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cars", required=True)
    ap.add_argument("--night", action="store_true")
    ap.add_argument("--samples", type=int, default=64)
    ap.add_argument("--res", default="960x540")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    cars = a.cars.split(",")
    util.reset_scene()
    R.setup_cycles(samples=a.samples, res=tuple(int(x) for x in a.res.split("x")))
    L = 17.0
    lane = L * 0.42
    # right lanes (x > 0) drive +Y towards the camera, left lanes drive away; nearest car ~1.2 L from the lens
    slots = [(lane * 0.5, -L * 0.3, 0.0), (lane * 1.5, -L * 1.3, 0.0), (-lane * 0.5, -L * 1.25, math.pi),
             (lane * 1.5, -L * 3.0, 0.0), (lane * 0.5, -L * 2.2, 0.0), (-lane * 1.5, -L * 2.05, math.pi),
             (-lane * 0.5, -L * 3.4, math.pi), (lane * 0.5, -L * 4.2, 0.0)]
    cam_pos = (lane * 1.9, L * 1.55, 5.2)
    cam_tgt = (-lane * 0.15, -L * 1.55, 2.6)
    R.street(L, night=a.night, keep_clear=(cam_pos[0], cam_pos[1]))
    for car, (x, y, h) in zip(cars, slots):
        glb = os.path.join(HERE, "out", car, car + ".glb")
        if not os.path.exists(glb):
            util.log("missing", glb)
            continue
        R.load_glb(glb, offset=(x, y, 0), rot_z=h, paint=PAINT.get(car), lights_on=a.night)
    R.camera_lookat(cam_pos, cam_tgt, lens=44)
    out = a.out or os.path.join(REPO, "docs", "v2", "proto", "carpipe",
                                f"lineup_street_{'night' if a.night else 'day'}.png")
    R.render_to(out)


if __name__ == "__main__":
    main()
