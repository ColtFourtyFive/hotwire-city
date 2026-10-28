#!/usr/bin/env python3
"""Download Roblox catalog asset files (rbxm / animation models) for inspection.

usage: python3 -I tools/characters/fetch_assets.py OUT_DIR ID [ID ...]

Each asset is saved as OUT_DIR/<id>.rbxm (skipped when it already exists). Public catalog assets need no
credentials; nothing here reads ~/.config/hotwire. Prints one line per id: "<id> ok <bytes>" or "<id> FAIL <why>".
"""

import gzip
import json
import os
import sys
import time
import urllib.error
import urllib.request

UA = {"User-Agent": "Mozilla/5.0 (HotwireCity asset verifier)"}


def http(url: str, binary: bool = False, tries: int = 4):
    err = None
    for k in range(tries):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=40) as r:
                data = r.read()
                if r.headers.get("Content-Encoding") == "gzip" or data[:2] == b"\x1f\x8b":
                    data = gzip.decompress(data)
                return data if binary else json.loads(data)
        except urllib.error.HTTPError as e:
            err = f"HTTP {e.code}"
            if e.code in (400, 401, 403, 404):
                break
        except Exception as e:  # noqa: BLE001
            err = str(e)
        time.sleep(1.5 + k * 1.5)
    raise RuntimeError(err or "unknown error")


def locate(asset_id: int) -> dict:
    return http(f"https://assetdelivery.roblox.com/v2/assetId/{asset_id}")


def fetch(asset_id: int, out_dir: str) -> str:
    path = os.path.join(out_dir, f"{asset_id}.rbxm")
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return path
    info = locate(asset_id)
    locs = info.get("locations") or []
    if not locs:
        raise RuntimeError("no locations: " + json.dumps(info.get("errors") or info)[:160])
    data = http(locs[0]["location"], binary=True)
    with open(path, "wb") as f:
        f.write(data)
    return path


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    bad = 0
    for raw in sys.argv[2:]:
        try:
            asset_id = int(raw)
            p = fetch(asset_id, out_dir)
            print(asset_id, "ok", os.path.getsize(p))
        except Exception as e:  # noqa: BLE001
            bad += 1
            print(raw, "FAIL", e)
        time.sleep(0.25)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
