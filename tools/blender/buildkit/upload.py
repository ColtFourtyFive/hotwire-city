#!/usr/bin/env python3
"""Uploads the production building set to Roblox (Open Cloud) and records every id in assets/buildings/manifest.json.

    python3 tools/blender/buildkit/upload.py              # upload new / changed files (sha1), 3 at a time
    python3 tools/blender/buildkit/upload.py --status     # refresh moderation state of every recorded asset
    python3 tools/blender/buildkit/upload.py --dry-run

Models: assets/buildings/glb/<key>.glb -> assetType Model (owned by user 11686693147; loaded at runtime with
InsertService:LoadAsset). Images: the four shared atlases (windows_day, signs, brands, awnings; MeshPart.TextureID)
and the fallback window bays (fb_*; Texture.Texture) -> assetType Image. Then run gen_config.py.
The API key comes from tools/rbxcloud.py ($ROBLOX_API_KEY or ~/.config/hotwire/roblox_api_key); it is never printed.
"""
import argparse, concurrent.futures, datetime, hashlib, json, os, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from rbxcloud import upload, req  # noqa: E402

USER = "11686693147"
MANIFEST = os.path.join(ROOT, "assets", "buildings", "manifest.json")
CATALOG = os.path.join(ROOT, "assets", "buildings", "catalog.json")
IMAGES = {
    "windows_day": os.path.join(HERE, "out", "textures", "windows_day.png"),
    "signs": os.path.join(HERE, "out", "textures", "signs.png"),
    "brands": os.path.join(HERE, "out", "textures", "brands.png"),
    "awnings": os.path.join(HERE, "out", "textures", "awnings.png"),
    "fb_punched": os.path.join(ROOT, "assets", "buildings", "textures", "fb_punched.png"),
    "fb_curtain": os.path.join(ROOT, "assets", "buildings", "textures", "fb_curtain.png"),
    "fb_ribbon": os.path.join(ROOT, "assets", "buildings", "textures", "fb_ribbon.png"),
}
lock = threading.Lock()


def sha1(path):
    return hashlib.sha1(open(path, "rb").read()).hexdigest()


def load_manifest():
    if os.path.exists(MANIFEST):
        return json.load(open(MANIFEST))
    return {"note": "Hotwire City v2 buildings: Roblox asset ids (owner user %s). Written by upload.py." % USER,
            "models": {}, "images": {}}


def save(man):
    man["updated"] = datetime.datetime.now().isoformat(timespec="seconds")
    tmp = MANIFEST + ".tmp"
    with open(tmp, "w") as f:
        json.dump(man, f, indent=1, sort_keys=True)
    os.replace(tmp, MANIFEST)


def poll(op, tries=90):
    for _ in range(tries):
        st, body, _ = req("GET", f"https://apis.roblox.com/assets/v1/{op}")
        if st == 200:
            d = json.loads(body)
            if d.get("done"):
                return d.get("response") or {}
        time.sleep(3)
    return None


def upload_one(kind, key, path, man, dry):
    digest = sha1(path)
    cur = man[kind].get(key)
    if cur and cur.get("assetId") and cur.get("sha1") == digest:
        return "unchanged", key, cur["assetId"]
    if dry:
        return "would-upload", key, None
    name = ("HC bldg " if kind == "models" else "HC bldg tex ") + key
    ctype = "model/gltf-binary" if kind == "models" else "image/png"
    atype = "Model" if kind == "models" else "Image"
    for attempt in range(4):
        st, body, _ = upload(path, name, USER, atype, ctype)
        if st == 200:
            break
        if st == 429 or st >= 500:
            time.sleep(10 * (attempt + 1))
            continue
        return "error", key, f"{st} {body[:200]}"
    else:
        return "error", key, f"{st} {body[:200]}"
    op = json.loads(body).get("path")
    res = poll(op) if op else None
    if not res or not res.get("assetId"):
        with lock:
            man[kind][key] = {"assetId": 0, "sha1": digest, "file": os.path.relpath(path, ROOT), "operation": op,
                              "moderation": "Pending"}
            save(man)
        return "pending", key, op
    entry = {"assetId": int(res["assetId"]), "sha1": digest, "file": os.path.relpath(path, ROOT),
             "moderation": res.get("moderationResult", {}).get("moderationState"), "bytes": os.path.getsize(path)}
    with lock:
        man[kind][key] = entry
        save(man)
    return "uploaded", key, entry["assetId"]


def refresh(man):
    for kind in ("models", "images"):
        for key, e in sorted(man[kind].items()):
            if not e.get("assetId") and e.get("operation"):
                res = poll(e["operation"], tries=2)
                if res and res.get("assetId"):
                    e["assetId"] = int(res["assetId"])
            if not e.get("assetId"):
                continue
            st, body, _ = req("GET", f"https://apis.roblox.com/assets/v1/assets/{e['assetId']}")
            if st == 200:
                e["moderation"] = json.loads(body).get("moderationResult", {}).get("moderationState")
            print("%-9s %-28s %s %s" % (kind, key, e.get("assetId"), e.get("moderation")))
    save(man)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=3)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--only", nargs="*")
    a = ap.parse_args()
    man = load_manifest()
    if a.status:
        refresh(man)
        return
    cat = json.load(open(CATALOG))["variants"]
    items = [("images", k, p) for k, p in IMAGES.items()]
    items += [("models", k, os.path.join(ROOT, "assets", "buildings", v["glb"])) for k, v in sorted(cat.items())]
    if a.only:
        items = [it for it in items if it[1] in a.only]
    # forget models that left the catalog (their assets stay on Roblox, unused)
    for k in list(man["models"]):
        if k not in cat:
            man.setdefault("retired", {})[k] = man["models"].pop(k)
    counts = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        for status, key, info in ex.map(lambda it: upload_one(it[0], it[1], it[2], man, a.dry_run), items):
            counts[status] = counts.get(status, 0) + 1
            print("%-12s %-28s %s" % (status, key, info if info is not None else ""), flush=True)
    if not a.dry_run:
        save(man)
    print(counts)


if __name__ == "__main__":
    main()
