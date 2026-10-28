#!/usr/bin/env python3
"""Verify every catalog id in src/shared/Config/PlayerLooks.luau against the live Roblox APIs.

usage (repo root):
    lune run tools/characters/dump_looks.luau /tmp/looks_ids.json
    python3 -I tools/characters/verify_looks.py /tmp/looks_ids.json docs/v2/evidence/characters_catalog_verify.json \
        [--cache DIR]

For each id:
  1. economy.roblox.com/v2/assets/<id>/details: exists, AssetTypeId matches the slot, creator, for sale, price.
  2. assetdelivery.roblox.com/v2/assetId/<id>: the file resolves (paid avatar animations answer 401 to anonymous
     downloads; they are still checked by type and creator, and HumanoidDescription needs no ownership).
  3. The downloaded file is opened with tools/characters/asset_refs.luau: every mesh / texture / cage / surface
     appearance map it references must resolve too (this is what caught Brown Hair 62234425: a TextureId that 404s),
     and accessories must carry a WrapLayer (we set IsLayered = true for all of them).
Also fails on any banned id (PlayerLooks.BANNED). Exit code 1 when any id fails. Nothing here needs credentials.
"""

import datetime
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fetch_assets  # noqa: E402

UA = {"User-Agent": "Mozilla/5.0 (HotwireCity asset verifier)"}
BANNED = {62234425}
ACCESSORY_TYPES = {41, 64, 65, 66, 67, 68, 69, 70, 71, 72, 76, 77}


def get_json(url: str, tries: int = 5):
    err = None
    for k in range(tries):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=40) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            body = None
            try:
                body = json.loads(e.read())
            except Exception:  # noqa: BLE001
                pass
            if e.code == 429:
                time.sleep(4 + 4 * k)
                err = (e.code, body)
                continue
            return e.code, body
        except Exception as e:  # noqa: BLE001
            err = (0, str(e))
            time.sleep(1.5 + k)
    return err if err else (0, None)


def economy(asset_id: int) -> dict:
    code, d = get_json(f"https://economy.roblox.com/v2/assets/{asset_id}/details")
    if code != 200 or not isinstance(d, dict) or not d.get("AssetId"):
        return {"ok": False, "code": code}
    return {
        "ok": True,
        "type": d.get("AssetTypeId"),
        "name": d.get("Name"),
        "creator": (d.get("Creator") or {}).get("Name"),
        "creatorVerified": (d.get("Creator") or {}).get("HasVerifiedBadge"),
        "forSale": d.get("IsForSale"),
        "price": d.get("PriceInRobux"),
        "created": d.get("Created"),
    }


def delivery(asset_id: int) -> dict:
    code, d = get_json(f"https://assetdelivery.roblox.com/v2/assetId/{asset_id}")
    if code == 200 and isinstance(d, dict) and d.get("locations"):
        return {"ok": True, "archived": bool(d.get("isArchived")), "type": d.get("assetTypeId")}
    msg = None
    if isinstance(d, dict) and d.get("errors"):
        msg = d["errors"][0].get("message")
        code = d["errors"][0].get("code", code)
    return {"ok": False, "code": code, "message": msg}


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    cache = None
    for a in sys.argv[1:]:
        if a.startswith("--cache="):
            cache = a.split("=", 1)[1]
    if len(args) < 2:
        print(__doc__)
        return 2
    ids_path, out_path = args[0], args[1]
    items = json.load(open(ids_path))
    cache = cache or os.path.join(os.path.dirname(os.path.abspath(ids_path)), "verify_cache")
    os.makedirs(cache, exist_ok=True)

    results = []
    ref_cache: dict = {}
    files = []
    for n, it in enumerate(items):
        aid = int(it["id"])
        r = {
            "id": aid,
            "slot": it["typeName"],
            "expectedType": it["type"],
            "roles": it["roles"],
            "status": "ok",
            "problems": [],
        }
        if aid in BANNED:
            r["problems"].append("banned id")
        eco = economy(aid)
        r["economy"] = eco
        if not eco["ok"]:
            r["problems"].append(f"economy lookup failed ({eco.get('code')})")
        elif eco["type"] != it["type"]:
            r["problems"].append(f"asset type {eco['type']} != expected {it['type']}")
        dl = delivery(aid)
        r["delivery"] = dl
        if not dl["ok"]:
            # 401: paid catalog items (avatar animations, third-party clothing) cannot be downloaded anonymously. They
            # still work in a HumanoidDescription without ownership; type + creator are verified here and the load
            # itself in the real engine (tools/characters/cloud_looks.py -> characters_engine_check.json).
            if dl.get("code") == 401 and eco.get("ok") and eco.get("type") == it["type"]:
                kind = "avatar animation" if it["type"] in (48, 50, 51, 52, 53, 54, 55) else "catalog item"
                r["notes"] = f"file needs auth to download (paid {kind}); type + creator verified, engine load checked"
            else:
                r["problems"].append(f"assetdelivery failed ({dl.get('code')}: {dl.get('message')})")
        elif dl.get("archived"):
            r["problems"].append("archived")
        if dl["ok"]:
            try:
                path = fetch_assets.fetch(aid, cache)
                files.append((aid, path))
            except Exception as e:  # noqa: BLE001
                r["problems"].append(f"download failed: {e}")
        results.append(r)
        print(f"[{n + 1}/{len(items)}] {aid} {it['typeName']} {eco.get('name')} -> {r['problems'] or 'ok'}", flush=True)
        time.sleep(0.3)

    # open the files and check every referenced content id
    refs_json = os.path.join(cache, "refs.json")
    if files:
        cmd = ["lune", "run", os.path.join(HERE, "asset_refs.luau"), refs_json] + [p for _, p in files]
        subprocess.run(cmd, check=True, cwd=os.path.dirname(os.path.dirname(HERE)))
        refs = json.load(open(refs_json))
    else:
        refs = {}
    by_id = {r["id"]: r for r in results}
    for aid, path in files:
        r = by_id[aid]
        entry = refs.get(path) or {}
        if not entry.get("ok"):
            head = open(path, "rb").read(32)
            if head.startswith(b"Kaydara FBX"):
                # some 2022 Base Body accessories deliver their "source" FBX here; the engine still builds the
                # accessory from it (characters_engine_check.json loads every accessory alone)
                r.setdefault("warnings", []).append("delivered source is an FBX, not a model: refs not scanned")
            else:
                r["problems"].append(f"file did not open: {entry.get('error')}")
            continue
        r["layered"] = entry.get("layered", False)
        if r["expectedType"] in ACCESSORY_TYPES and not r["layered"]:
            r.setdefault("warnings", []).append("accessory without WrapLayer (rigid): IsLayered must be false")
        ids = sorted({x["id"] for x in entry.get("refs", []) if x.get("id")})
        r["refs"] = ids
        bad = []
        for rid in ids:
            if rid not in ref_cache:
                ref_cache[rid] = delivery(int(rid))
                time.sleep(0.15)
            if not ref_cache[rid]["ok"]:
                bad.append({"id": rid, **ref_cache[rid]})
        if bad:
            r["badRefs"] = bad
            missing = [b for b in bad if b.get("code") != 401]
            if missing:
                r["problems"].append(f"{len(missing)} referenced content id(s) do not resolve")
            else:
                # 401 = exists but needs auth to download (newer Roblox-made heads); the engine loads them
                r.setdefault("warnings", []).append(f"{len(bad)} referenced content id(s) need auth to download")

    failed = 0
    for r in results:
        if r["problems"]:
            r["status"] = "FAIL"
            failed += 1
    summary = {
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "total": len(results),
        "ok": len(results) - failed,
        "failed": failed,
        "contentRefsChecked": len(ref_cache),
        "contentRefsBad": sum(1 for v in ref_cache.values() if not v["ok"]),
        "authOnlyDownloads": sum(1 for r in results if r.get("notes")),
        "warnings": sum(1 for r in results if r.get("warnings")),
        "engineCheck": "docs/v2/evidence/characters_engine_check.json (tools/characters/cloud_looks.py)",
    }
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w") as f:
        json.dump({"summary": summary, "items": results}, f, indent=1)
    print(json.dumps(summary, indent=1))
    for r in results:
        if r["problems"]:
            print("FAIL", r["id"], r["slot"], r["roles"], r["problems"])
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
