#!/usr/bin/env python3
"""Upload every look image (material maps, decals, sky faces) to Roblox as **Image** assets via Open Cloud and record
the ids. Decal-type ids do not resolve in Sky / MaterialVariant / Texture (403 IncorrectAssetType), hence Image.

Manifests (keyed by the image's repo-relative path; an entry whose sha1 matches is skipped, so re-runs only upload what
changed):
  assets/materials/manifest.json   material maps + decals
  assets/sky/manifest.json         sky faces

The API key is read by tools/rbxcloud.py ($ROBLOX_API_KEY or ~/.config/hotwire/roblox_api_key) and never printed.

Usage: python3 tools/look/upload.py [--user 11686693147] [--jobs 3] [--dry-run] [--status]
Then:  python3 tools/look/gen_project.py
"""

import argparse
import json
import os
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))

import lookcommon as lc  # noqa: E402
from rbxcloud import req, upload  # noqa: E402

MAT_MANIFEST = os.path.join(lc.MATERIALS_DIR, "manifest.json")
SKY_MANIFEST = os.path.join(lc.SKY_DIR, "manifest.json")
LOCK = threading.Lock()


def collect():
    """[(relpath, display name, manifest path)] for every image the look needs (deduplicated)."""
    out = []
    seen = set()
    mats = lc.read_json(os.path.join(lc.MATERIALS_DIR, "materials.json"))
    if not mats:
        raise SystemExit("run tools/look/prep_materials.py first")
    for m in mats["materials"]:
        for kind, path in m["files"].items():
            if path in seen:
                continue
            seen.add(path)
            owner = os.path.basename(os.path.dirname(path))
            out.append((path, "HC mat %s %s" % (owner, kind), MAT_MANIFEST))
    for d in mats["decals"]:
        out.append((d["file"], "HC decal %s" % d["name"], MAT_MANIFEST))
    skies = lc.read_json(os.path.join(lc.SKY_DIR, "skies.json"))
    if skies:
        for name, s in sorted(skies["skies"].items()):
            for face, path in sorted(s["files"].items()):
                out.append((path, "HC sky %s %s" % (name, face), SKY_MANIFEST))
    return out


def poll(op_path, tries=60):
    for _ in range(tries):
        st, body, _ = req("GET", "https://apis.roblox.com/assets/v1/%s" % op_path)
        if st == 200:
            d = json.loads(body)
            if d.get("done"):
                return d.get("response", {})
        time.sleep(3)
    return None


def save(manifest_path, key, entry):
    with LOCK:
        man = lc.read_json(manifest_path, {}) or {}
        man[key] = entry
        lc.write_json(manifest_path, man)


def upload_one(item, user, dry):
    path, name, manifest_path = item
    full = os.path.join(lc.ROOT, path)
    h = lc.sha1(full)
    with LOCK:
        cur = (lc.read_json(manifest_path, {}) or {}).get(path)
    if cur and cur.get("sha1") == h and cur.get("assetId"):
        return "skip", path, cur["assetId"]
    if cur and cur.get("sha1") == h and cur.get("operation") and not cur.get("assetId"):
        res = poll(cur["operation"], tries=5)  # a previous run timed out waiting; try to finish it
        if res and res.get("assetId"):
            entry = dict(cur, assetId=int(res["assetId"]), assetType=res.get("assetType"),
                         moderation=res.get("moderationResult", {}).get("moderationState"))
            save(manifest_path, path, entry)
            return "ok", path, entry["assetId"]
    if dry:
        return "would-upload", path, None
    for attempt in range(6):
        st, body, _ = upload(full, name, user, "Image", "image/png")
        if st == 200:
            break
        if st in (429, 500, 502, 503, 504):
            time.sleep(4 * (attempt + 1))
            continue
        return "fail", path, "%s %s" % (st, body[:200])
    else:
        return "fail", path, "rate limited"
    op = json.loads(body).get("path")
    res = poll(op) if op else None
    if not res or not res.get("assetId"):
        save(manifest_path, path, {"operation": op, "sha1": h, "name": name})
        return "pending", path, op
    entry = {"assetId": int(res["assetId"]), "assetType": res.get("assetType"), "sha1": h, "name": name,
             "moderation": res.get("moderationResult", {}).get("moderationState")}
    save(manifest_path, path, entry)
    return "ok", path, entry["assetId"]


def refresh_status():
    for mp in (MAT_MANIFEST, SKY_MANIFEST):
        man = lc.read_json(mp, {}) or {}
        for k in sorted(man):
            aid = man[k].get("assetId")
            if not aid:
                continue
            st, body, _ = req("GET", "https://apis.roblox.com/assets/v1/assets/%s" % aid)
            if st == 200:
                man[k]["moderation"] = json.loads(body).get("moderationResult", {}).get("moderationState")
            print(man[k].get("moderation"), aid, k)
        lc.write_json(mp, man)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--user", default="11686693147")
    ap.add_argument("--jobs", type=int, default=3)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--status", action="store_true")
    a = ap.parse_args()
    if a.status:
        refresh_status()
        return
    items = collect()
    counts = {}
    with ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        for status, path, info in ex.map(lambda it: upload_one(it, a.user, a.dry_run), items):
            counts[status] = counts.get(status, 0) + 1
            print("%-12s %s %s" % (status, path, info if info is not None else ""), flush=True)
    print("summary:", json.dumps(counts, sort_keys=True), "of", len(items))


if __name__ == "__main__":
    main()
