#!/usr/bin/env python3
"""Upload the VFX textures (assets/vfx/<key>.png) to Roblox as images via Open Cloud and record the ids in
assets/vfx/manifest.json. A key whose PNG hash matches the manifest is skipped, so re-running only uploads what
changed. The API key is read by tools/rbxcloud.py (never printed).

Usage: python3 tools/vfx/upload.py [key ...] [--user 11686693147] [--force]
Then:  python3 tools/vfx/gen_luau.py   (writes the ids into src/shared/Config/VFX.luau)
"""
import hashlib
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from rbxcloud import req, upload  # noqa: E402

KEYS = [
    "smoke_puff_a", "smoke_puff_b", "smoke_puff_c", "smoke_flipbook", "tire_smoke", "dust_puff",
    "fire_flipbook", "nitro_jet", "backfire_burst", "spark_streak", "speed_line", "glow_dot", "sparkle_star",
    "glare", "shockwave_ring", "impact_star", "debris_chips", "water_splash", "cash_bill", "cash_flutter",
    "coin_spin", "confetti", "skid_mark", "headlight_beam", "underglow",
]
MANIFEST = os.path.join(ROOT, "assets", "vfx", "manifest.json")


def sha1(path):
    return hashlib.sha1(open(path, "rb").read()).hexdigest()


def poll(op_path, tries=45):
    for _ in range(tries):
        st, body, _ = req("GET", f"https://apis.roblox.com/assets/v1/{op_path}")
        if st == 200:
            d = json.loads(body)
            if d.get("done"):
                return d.get("response", {})
        time.sleep(3)
    return None


def main(argv):
    user = "11686693147"
    force = "--force" in argv
    if "--user" in argv:
        user = argv[argv.index("--user") + 1]
    keys = [a for a in argv if a in KEYS] or KEYS
    man = json.load(open(MANIFEST)) if os.path.exists(MANIFEST) else {}
    for k in keys:
        path = os.path.join(ROOT, "assets", "vfx", k + ".png")
        if not os.path.exists(path):
            print("missing", k)
            continue
        h = sha1(path)
        cur = man.get(k)
        if cur and cur.get("sha1") == h and cur.get("assetId") and not force:
            print("skip", k, cur["assetId"])
            continue
        st, body, _ = upload(path, f"HC VFX {k}", user, "Decal", "image/png")
        if st != 200:
            print("upload failed", k, st, body[:300])
            continue
        op = json.loads(body).get("path")
        res = poll(op) if op else None
        if not res:
            print("operation timed out", k, op)
            man[k] = {"operation": op, "file": os.path.relpath(path, ROOT), "sha1": h}
        else:
            man[k] = {
                "assetId": int(res["assetId"]),
                "assetType": res.get("assetType"),
                "file": os.path.relpath(path, ROOT),
                "sha1": h,
                "moderation": res.get("moderationResult", {}).get("moderationState"),
            }
            print("ok", k, man[k]["assetId"], man[k]["assetType"], man[k]["moderation"])
        json.dump(man, open(MANIFEST, "w"), indent=2, sort_keys=True)
        time.sleep(0.5)


if __name__ == "__main__":
    main(sys.argv[1:])
