#!/usr/bin/env python3
"""Top-down plot of the character creator's orbit camera (docs/v2/evidence/characters_creator_orbit.png).

Reads the dump of tools/characters/creator_orbit.luau (CreatorModel.framing over a full turn) and draws the lineup room
from above: walls, the height chart on the back wall's room-facing side, the character, and the lens at every 5 deg
of yaw for the desktop full-body framing (the widest orbit). Reachable yaws (within the +-MAX_YAW orbit limit) are
solid; the rest are hollow and show the in-room pull-in that keeps the lens inside even past the limit. The second
panel does the same for the touch framing. Summary numbers are printed under each panel.

usage (repo root):
  lune run tools/characters/creator_orbit.luau ORBIT.json
  python3 -I tools/characters/creator_orbit.py ORBIT.json docs/v2/evidence/characters_creator_orbit.png
"""
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
FONTS = os.path.join(ROOT, "assets", "ui", "fonts")

BG = (12, 12, 13)
PANEL = (24, 24, 26)
WALL = (88, 90, 96)
TEXT = (240, 240, 240)
DIM = (155, 155, 155)
ACCENT = (255, 138, 61)
GREEN = (114, 204, 114)
CHART = (225, 225, 218)


def font(name, size):
    return ImageFont.truetype(os.path.join(FONTS, name + ".ttf"), size)


def panel(img, box, data, touch, title):
    d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = box
    d.rectangle(box, fill=PANEL)
    d.text((x0 + 20, y0 + 14), title, font=font("Oswald-500", 30), fill=TEXT)
    room = data["room"]
    # world x -> right, world z -> down (the camera side, +Z, at the bottom)
    pad = 70
    span_x = room["halfW"] * 2 + 4
    span_z = room["front"] - room["back"] + 4
    scale = min((x1 - x0 - 2 * pad) / span_x, (y1 - y0 - 2 * pad - 60) / span_z)
    cx = (x0 + x1) / 2
    top = y0 + pad + 40  # the back wall at the top, the camera side (+Z) toward the bottom

    def Q(x, z):
        return (cx + x * scale, top + (z - (room["back"] - 2)) * scale)

    for w in data["walls"]:
        if w["name"] in ("Floor", "Ceiling"):
            continue
        a = Q(w["x"] - w["sx"] / 2, w["z"] - w["sz"] / 2)
        b = Q(w["x"] + w["sx"] / 2, w["z"] + w["sz"] / 2)
        d.rectangle([a[0], a[1], b[0], b[1]], fill=WALL)
    # the height chart: on the back wall's +Z (Back) face, toward the room
    back = next(w for w in data["walls"] if w["name"] == "BackWall")
    face_z = back["z"] + back["sz"] / 2 if data["chartFace"] == "Back" else back["z"] - back["sz"] / 2
    a = Q(-7, face_z)
    b = Q(7, face_z)
    d.line([a, b], fill=CHART, width=5)
    d.text((a[0], a[1] + 6), f"height chart ({data['chartFace']} face, toward the room)", font=font("Montserrat-500", 15),
           fill=CHART)
    # margin box the lens must stay in
    m = data["margin"]
    a = Q(-room["halfW"] + m, room["back"] + m)
    b = Q(room["halfW"] - m, room["front"] - m)
    d.rectangle([a[0], a[1], b[0], b[1]], outline=(70, 70, 74), width=1)
    # the character
    c = Q(0, 0)
    d.ellipse([c[0] - 9, c[1] - 9, c[0] + 9, c[1] + 9], fill=ACCENT)
    d.line([c, Q(0, 1.6)], fill=ACCENT, width=3)  # faces +Z
    samples = [s for s in data["samples"] if s["focus"] == "body" and s["touch"] == touch]
    inside = 0
    pulled_reach = 0
    for s in samples:
        p = Q(s["x"], s["z"])
        ok = (room["back"] + m - 1e-6 <= s["z"] <= room["front"] - m + 1e-6) and abs(s["x"]) <= room["halfW"] - m + 1e-6
        inside += 1 if ok else 0
        if s["reachable"] and s["pulledIn"]:
            pulled_reach += 1
        colour = GREEN if s["reachable"] else DIM
        r = 6
        if s["reachable"]:
            d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=colour)
        else:
            d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], outline=colour, width=2)
        q = (p[0] + s["lx"] * 18, p[1] + s["lz"] * 18)
        d.line([p, q], fill=colour, width=1)
    lim = data["maxYaw"]
    f = font("Montserrat-500", 17)
    d.text((x0 + 20, y1 - 74), f"{inside}/{len(samples)} lens positions inside the room ({m} stud margin), "
                               f"yaw -180..180", font=f, fill=TEXT)
    d.text((x0 + 20, y1 - 50), f"solid = within the +-{lim:.0f} deg orbit limit ({pulled_reach} pulled in); "
                               f"hollow = past it", font=f, fill=DIM)


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    data = json.load(open(sys.argv[1]))
    W, H = 1600, 900
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W, 6], fill=ACCENT)
    d.text((30, 22), "CHARACTER CREATOR  ·  ORBIT CAMERA FROM ABOVE", font=font("Oswald-500", 40), fill=TEXT)
    d.text((30, 76), "CreatorModel.framing at every 5 deg of yaw, full-body framing (head 5.6 studs). The lens never "
                     "leaves the lineup room; the chart faces the camera.", font=font("Montserrat-500", 18), fill=DIM)
    panel(img, (30, 120, 790, 870), data, False, "Desktop (character right of the list)")
    panel(img, (810, 120, 1570, 870), data, True, "Touch (character above the sheet)")
    os.makedirs(os.path.dirname(os.path.abspath(sys.argv[2])), exist_ok=True)
    img.save(sys.argv[2])
    print("wrote", sys.argv[2])
    return 0


if __name__ == "__main__":
    sys.exit(main())
