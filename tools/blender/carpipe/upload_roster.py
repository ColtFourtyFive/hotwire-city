#!/usr/bin/env python3
"""Upload the Vehicles v2 roster to Roblox (Open Cloud) and record every id in assets/vehicles/manifest.json.

    python3 tools/blender/carpipe/upload_roster.py                  # new / changed GLBs + body images (sha1)
    python3 tools/blender/carpipe/upload_roster.py nami wren        # just these cars
    python3 tools/blender/carpipe/upload_roster.py --status         # refresh moderation state of every asset
    python3 tools/blender/carpipe/upload_roster.py --dry-run

Models: assets/vehicles/<id>/<id>.glb -> assetType Model, owned by user 11686693147, loaded at runtime with
InsertService:LoadAsset (Shared/Vehicle/CarTemplates). The importer makes one MeshPart per GLB object (names kept),
SurfaceAppearances from the Trim / Interior / Wheel PBR sets and TextureIDs from the Lights / Sign base maps.
Body images (assetType Image, set as Body.TextureID at runtime): the overlay (paint pixels transparent) for
tint-mask paint cars, the full livery for livery cars; strip-route paint cars need none.
Then run gen_vehicles.py. The API key comes from tools/rbxcloud.py and is never printed.
"""
import argparse
import concurrent.futures
import datetime
import hashlib
import json
import os
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from rbxcloud import req, upload  # noqa: E402

USER = "11686693147"
VEH = os.path.join(ROOT, "assets", "vehicles")
MANIFEST = os.path.join(VEH, "manifest.json")
lock = threading.Lock()


def sha1(path):
    return hashlib.sha1(open(path, "rb").read()).hexdigest()


def roster():
    r = json.load(open(os.path.join(HERE, "roster.json")))
    return {k: v for k, v in r.items() if not k.startswith("_")}


def load_manifest():
    if os.path.exists(MANIFEST):
        return json.load(open(MANIFEST))
    return {"note": "Hotwire City v2 vehicles: Roblox asset ids (owner user %s). Written by upload_roster.py." % USER,
            "models": {}, "images": {}}


def save(man):
    man["updated"] = datetime.datetime.now().isoformat(timespec="seconds")
    tmp = MANIFEST + ".tmp"
    with open(tmp, "w") as f:
        json.dump(man, f, indent=1, sort_keys=True)
    os.replace(tmp, MANIFEST)


def body_image(vid, entry):
    """(kind, path) of the image the game sets as Body.TextureID, or (None, None)."""
    side = json.load(open(os.path.join(VEH, vid, vid + ".json")))
    if side["paint"]["route"] != "tintmask":
        return None, None  # untextured paint: Body.Color only
    made = side["objects"]["Body"].get("textures", {})  # this build's own files (never a stale one)
    key = "base" if entry.get("body") == "livery" else "overlay"
    rel = made.get(key)
    if not rel:
        return None, None
    return ("livery" if key == "base" else "overlay"), os.path.join(VEH, vid, rel)


def poll(op, tries=100):
    for _ in range(tries):
        st, body, _ = req("GET", f"https://apis.roblox.com/assets/v1/{op}")
        if st == 200:
            d = json.loads(body)
            if d.get("done"):
                return d.get("response") or {}
        time.sleep(3)
    return None


def upload_one(kind, key, path, name, man, dry, extra=None):
    digest = sha1(path)
    cur = man[kind].get(key)
    if cur and cur.get("assetId") and cur.get("sha1") == digest:
        return "unchanged", key, cur["assetId"]
    if dry:
        return "would-upload", key, None
    ctype = "model/gltf-binary" if kind == "models" else "image/png"
    atype = "Model" if kind == "models" else "Image"
    st, body = 0, ""
    for attempt in range(5):
        st, body, _ = upload(path, name, USER, atype, ctype)
        if st == 200:
            break
        if st == 429 or st >= 500:
            time.sleep(12 * (attempt + 1))
            continue
        return "error", key, f"{st} {body[:200]}"
    else:
        return "error", key, f"{st} {body[:200]}"
    op = json.loads(body).get("path")
    res = poll(op) if op else None
    entry = {"sha1": digest, "file": os.path.relpath(path, ROOT), "bytes": os.path.getsize(path), "name": name}
    entry.update(extra or {})
    if not res or not res.get("assetId"):
        entry.update({"assetId": 0, "operation": op, "moderation": "Pending"})
        status = "pending"
    else:
        entry.update({"assetId": int(res["assetId"]),
                      "moderation": res.get("moderationResult", {}).get("moderationState")})
        status = "uploaded"
    with lock:
        man[kind][key] = entry
        save(man)
    return status, key, entry["assetId"] or op


def refresh(man):
    for kind in ("models", "images"):
        for key, e in sorted(man[kind].items()):
            if not e.get("assetId") and e.get("operation"):
                res = poll(e["operation"], tries=2)
                if res and res.get("assetId"):
                    e["assetId"] = int(res["assetId"])
                    e.pop("operation", None)
            if not e.get("assetId"):
                print("%-7s %-24s pending" % (kind, key))
                continue
            st, body, _ = req("GET", f"https://apis.roblox.com/assets/v1/assets/{e['assetId']}")
            if st == 200:
                e["moderation"] = json.loads(body).get("moderationResult", {}).get("moderationState")
            print("%-7s %-24s %s %s" % (kind, key, e.get("assetId"), e.get("moderation")))
    save(man)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ids", nargs="*")
    ap.add_argument("--jobs", type=int, default=3)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--status", action="store_true")
    a = ap.parse_args()
    man = load_manifest()
    if a.status:
        refresh(man)
        return
    ros = roster()
    ids = a.ids or [k for k in ros if os.path.exists(os.path.join(VEH, k, k + ".glb"))]
    items = []
    for vid in ids:
        e = ros[vid]
        label = f"{e['brand']} {e['model']}"
        items.append(("models", vid, os.path.join(VEH, vid, vid + ".glb"), f"HC car {label}", None))
        kind, path = body_image(vid, e)
        if path:
            items.append(("images", vid, path, f"HC car {label} body {kind}", {"kind": kind}))
    counts = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futs = [ex.submit(upload_one, k, key, p, n, man, a.dry_run, x) for k, key, p, n, x in items]
        for f in concurrent.futures.as_completed(futs):
            status, key, info = f.result()
            counts[status] = counts.get(status, 0) + 1
            print("%-12s %-24s %s" % (status, key, info if info is not None else ""), flush=True)
    if not a.dry_run:
        save(man)
    print(counts)


if __name__ == "__main__":
    main()
