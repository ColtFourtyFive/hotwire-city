#!/usr/bin/env python3
"""UI art pipeline (gta_ui_language §6): render -> upload changed PNGs as Image assets -> Config/UIAssets.luau.

    python3 -I tools/ui/build.py               # render the HUD art, upload what changed, write the config
    python3 -I tools/ui/build.py --keyart      # also re-render the six loading panels (tools/ui/keyart.py: Blender
                                               # renders of the carpipe cars, ~30 min on 4 cores)
    python3 -I tools/ui/build.py --no-render   # upload / config only (art already in assets/ui)
    python3 -I tools/ui/build.py --no-upload   # render only; keeps the ids already recorded
    python3 -I tools/ui/build.py --force       # re-upload everything

Uploads go through tools/rbxcloud.py (Open Cloud; key from ~/.config/hotwire/roblox_api_key, never printed) as asset
type **Image** (Decal ids do not resolve in ImageLabels). Ids, hashes and moderation state are kept in
assets/ui/manifest.json; the GENERATED block of src/shared/Config/UIAssets.luau is rewritten from it plus
assets/ui/cells.json (sprite-sheet cells).
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
ASSETS = os.path.join(ROOT, "assets", "ui")
MANIFEST = os.path.join(ASSETS, "manifest.json")
CELLS = os.path.join(ASSETS, "cells.json")
CONFIG = os.path.join(ROOT, "src", "shared", "Config", "UIAssets.luau")
USER_ID = "11686693147"
BEGIN = "-- BEGIN GENERATED (tools/ui/build.py)"
END = "-- END GENERATED"

# asset key -> file. Sheets are referenced as "<sheet>.<cell>" through Kit.image.
IMAGES = {
    "hud": "hud_sheet.png",
    "apps": "apps_sheet.png",
    "portraits": "portraits_sheet.png",
    "banners": "banners_sheet.png",
    "wedge": "wedge.png",
    "vignette": "vignette.png",
    "shard_band": "shard_band.png",
    "phone_shell": "phone_shell.png",
    "wordmark": "wordmark.png",
    "loading_1": "loading_1.png",
    "loading_2": "loading_2.png",
    "loading_3": "loading_3.png",
    "loading_4": "loading_4.png",
    "loading_5": "loading_5.png",
    "loading_6": "loading_6.png",
}
SHEETS = ["hud", "apps", "portraits", "banners"]


def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def upload_image(path, name):
    from rbxcloud import req, upload  # noqa: E402  (reads the key itself; never printed)

    st, body, _ = upload(path, name, USER_ID, "Image", "image/png")
    if st >= 300:
        raise RuntimeError(f"upload {name}: HTTP {st} {body[:300]}")
    op = json.loads(body)["path"]
    for _ in range(80):
        st, body, _ = req("GET", f"https://apis.roblox.com/assets/v1/{op}")
        d = json.loads(body)
        if d.get("done"):
            resp = d.get("response") or {}
            if "assetId" not in resp:
                raise RuntimeError(f"upload {name}: no assetId in {json.dumps(d)[:300]}")
            return int(resp["assetId"]), (resp.get("moderationResult") or {}).get("moderationState")
        time.sleep(3)
    raise RuntimeError(f"upload {name}: operation timed out")


def lua_id(manifest, key):
    e = manifest.get(key)
    return f'"rbxassetid://{e["assetId"]}"' if e and e.get("assetId") else '""'


def write_config(manifest, cells):
    lines = [BEGIN, "-- Whole images (Kit.image(\"<key>\")); \"\" until uploaded.", "UIAssets.Images = {"]
    for key in IMAGES:
        if key in SHEETS:
            continue
        lines.append(f"\t{key} = {lua_id(manifest, key)},")
    lines.append("}")
    lines.append("-- Sprite sheets (Kit.image(\"<sheet>.<cell>\")): cell = { x, y, w, h } in sheet pixels.")
    lines.append("UIAssets.Sheets = {")
    for sheet in SHEETS:
        lines.append(f"\t{sheet} = {{")
        lines.append(f"\t\timage = {lua_id(manifest, sheet)},")
        lines.append("\t\tcells = {")
        for name, (x, y, w, h) in sorted(cells.get(sheet, {}).items()):
            lines.append(f"\t\t\t{name} = {{ {x}, {y}, {w}, {h} }},")
        lines.append("\t\t},")
        lines.append("\t},")
    lines.append("}")
    shell = cells.get("phone_shell", {})
    sl = shell.get("slice", [60, 120, 452, 840])
    lines.append("-- Phone shell 9-slice (drawn at 2x: SliceScale 0.5) and its transparent screen window (shell px).")
    lines.append(f"UIAssets.PHONE_SLICE = Rect.new({sl[0]}, {sl[1]}, {sl[2]}, {sl[3]})")
    sc = shell.get("screen", [18, 48, 494, 896])
    lines.append(f"UIAssets.PHONE_SCREEN = {{ {sc[0]}, {sc[1]}, {sc[2]}, {sc[3]} }}")
    lines.append(END)
    block = "\n".join(lines)
    src = open(CONFIG).read()
    a, b = src.index(BEGIN), src.index(END) + len(END)
    open(CONFIG, "w").write(src[:a] + block + src[b:])
    subprocess.run(["stylua", CONFIG], cwd=ROOT, check=False)
    print("wrote", os.path.relpath(CONFIG, ROOT))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-render", action="store_true")
    ap.add_argument("--keyart", action="store_true", help="re-render the loading panels (slow)")
    ap.add_argument("--no-upload", action="store_true")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--only", nargs="*", help="asset keys to (re)upload")
    args = ap.parse_args()
    if not args.no_render:
        subprocess.run([sys.executable, "-I", os.path.join(HERE, "art.py")], check=True)
        if args.keyart:
            subprocess.run([sys.executable, "-I", os.path.join(HERE, "keyart.py")], check=True)
    manifest = json.load(open(MANIFEST)) if os.path.exists(MANIFEST) else {}
    if not args.no_upload:
        for key, fname in IMAGES.items():
            if args.only and key not in args.only:
                continue
            path = os.path.join(ASSETS, fname)
            h = sha(path)
            entry = manifest.get(key, {})
            if not args.force and entry.get("sha256") == h and entry.get("assetId"):
                print(f"{key}: unchanged ({entry['assetId']})")
                continue
            asset_id, moderation = upload_image(path, f"HotwireCity UI {key}")
            manifest[key] = {"assetId": asset_id, "sha256": h, "file": os.path.relpath(path, ROOT),
                             "moderation": moderation, "uploaded": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
            print(f"{key}: uploaded -> {asset_id} ({moderation})")
            with open(MANIFEST, "w") as fh:
                json.dump(manifest, fh, indent=1, sort_keys=True)
            time.sleep(12)  # docs/v2/CONTENT_SAFETY.md: at most one upload per 10 s
    cells = json.load(open(CELLS))
    write_config(manifest, cells)


if __name__ == "__main__":
    main()
