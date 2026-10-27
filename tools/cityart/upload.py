#!/usr/bin/env python3
"""Upload every final city-art PNG (assets/cityart/<category>/<id>.png) to Roblox as an **Image** asset via Open
Cloud (same call as `tools/rbxcloud.py upload-image`), poll the operation, and record the id + moderation state in
assets/cityart/manifest.json (keyed by item id; an entry whose sha1 matches is skipped, so re-runs only upload what
changed). The API key is read by tools/rbxcloud.py and never printed.

Usage: python3 tools/cityart/upload.py [--user 11686693147] [--jobs 3] [--dry-run] [--status]
Then:  python3 tools/cityart/gen_config.py
"""
import argparse
import hashlib
import json
import os
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))

import spec  # noqa: E402
from rbxcloud import req, upload  # noqa: E402

MANIFEST = os.path.join(ROOT, "assets", "cityart", "manifest.json")
LOCK = threading.Lock()


def read_manifest():
    return json.load(open(MANIFEST)) if os.path.exists(MANIFEST) else {}


def save(key, entry):
    with LOCK:
        man = read_manifest()
        man[key] = entry
        with open(MANIFEST, "w") as f:
            json.dump(dict(sorted(man.items())), f, indent=1)
            f.write("\n")


def sha1(path):
    return hashlib.sha1(open(path, "rb").read()).hexdigest()


def poll(op_path, tries=40):
    for _ in range(tries):
        st, body, _ = req("GET", "https://apis.roblox.com/assets/v1/%s" % op_path)
        if st == 200:
            d = json.loads(body)
            if d.get("done"):
                return d.get("response", {})
        time.sleep(3)
    return None


def upload_one(cat, item, user, dry):
    rel = "assets/cityart/%s/%s.png" % (cat, item["id"])
    full = os.path.join(ROOT, rel)
    h = sha1(full)
    with LOCK:
        cur = read_manifest().get(item["id"])
    if cur and cur.get("sha1") == h and cur.get("assetId"):
        return "skip", item["id"], cur["assetId"]
    name = "HC city %s" % item["id"]
    if cur and cur.get("sha1") == h and cur.get("operation") and not cur.get("assetId"):
        res = poll(cur["operation"], tries=5)
        if res and res.get("assetId"):
            entry = dict(cur, assetId=int(res["assetId"]), moderation=res.get("moderationResult", {}).get("moderationState"))
            save(item["id"], entry)
            return "ok", item["id"], entry["assetId"]
    if dry:
        return "would-upload", item["id"], None
    for attempt in range(8):
        st, body, _ = upload(full, name, user, "Image", "image/png")
        if st == 200:
            break
        if st in (429, 500, 502, 503, 504):
            time.sleep(5 * (attempt + 1))
            continue
        return "fail", item["id"], "%s %s" % (st, body[:200])
    else:
        return "fail", item["id"], "rate limited"
    op = json.loads(body).get("path")
    res = poll(op) if op else None
    base = {"category": cat, "file": rel, "sha1": h, "name": name, "operation": op}
    if not res or not res.get("assetId"):
        save(item["id"], base)
        return "pending", item["id"], op
    entry = dict(base, assetId=int(res["assetId"]), assetType=res.get("assetType"),
                 moderation=res.get("moderationResult", {}).get("moderationState"))
    save(item["id"], entry)
    return "ok", item["id"], entry["assetId"]


def refresh_status():
    man = read_manifest()
    counts = {}
    for k in sorted(man):
        aid = man[k].get("assetId")
        if not aid:
            res = poll(man[k]["operation"], tries=2) if man[k].get("operation") else None
            if res and res.get("assetId"):
                man[k]["assetId"] = int(res["assetId"])
                aid = man[k]["assetId"]
            else:
                counts["pending"] = counts.get("pending", 0) + 1
                continue
        st, body, _ = req("GET", "https://apis.roblox.com/assets/v1/assets/%s" % aid)
        if st == 200:
            man[k]["moderation"] = json.loads(body).get("moderationResult", {}).get("moderationState")
        m = man[k].get("moderation")
        counts[m] = counts.get(m, 0) + 1
        if m != "Approved":
            print(m, aid, k)
    with open(MANIFEST, "w") as f:
        json.dump(dict(sorted(man.items())), f, indent=1)
        f.write("\n")
    print("moderation:", json.dumps(counts, sort_keys=True), "of", len(man))


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
    items = list(spec.all_items())
    counts = {}
    with ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        for status, key, info in ex.map(lambda ci: upload_one(ci[0], ci[1], a.user, a.dry_run), items):
            counts[status] = counts.get(status, 0) + 1
            print("%-12s %s %s" % (status, key, info if info is not None else ""), flush=True)
    print("summary:", json.dumps(counts, sort_keys=True), "of", len(items))


if __name__ == "__main__":
    main()
