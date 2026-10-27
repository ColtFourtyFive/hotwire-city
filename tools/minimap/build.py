#!/usr/bin/env python3
"""One command to regenerate the minimap art and ship it.

    python3 -I tools/minimap/build.py                 # export -> render -> icons -> upload changed -> Config
    python3 -I tools/minimap/build.py --no-upload     # render only (keeps the ids already in Config/Minimap)
    python3 -I tools/minimap/build.py --force         # re-upload every image even if unchanged
    python3 -I tools/minimap/build.py --ss 2          # faster draft render (default 3)

Steps
 1. lune run tools/minimap/export.luau  -> build/minimap/geometry.json   (roads, parts, slots, garages, terrain)
 2. render_map.py                        -> assets/minimap/tile_<r>_<c>.png (+ map_full.png, map_preview.png)
 3. icons.py                             -> assets/minimap/blips.png       (blip atlas + radar overlays)
 4. upload every image whose sha256 changed (tools/rbxcloud.py, Open Cloud; key from ~/.config/hotwire/roblox_api_key,
    never printed) and record ids + hashes in assets/minimap/manifest.json
 5. rewrite the GENERATED block of src/shared/Config/Minimap.luau: tile ids, world bounds, atlas id, icon cells

Run it whenever the map layout (Config/Map, MapLayout, MapBuilder) changes.
"""
import argparse, hashlib, json, os, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(ROOT, "tools", "minimap"))

ASSETS = os.path.join(ROOT, "assets", "minimap")
BUILD = os.path.join(ROOT, "build", "minimap")
MANIFEST = os.path.join(ASSETS, "manifest.json")
CONFIG = os.path.join(ROOT, "src", "shared", "Config", "Minimap.luau")
USER_ID = "11686693147"
BEGIN = "-- BEGIN GENERATED (tools/minimap/build.py)"
END = "-- END GENERATED"


def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def run(cmd):
    print("$ " + " ".join(cmd))
    subprocess.run(cmd, check=True, cwd=ROOT)


def upload_image(path, name):
    from rbxcloud import upload, req  # noqa: E402  (reads the key itself; never printed)

    st, body, _ = upload(path, name, USER_ID, "Image", "image/png")  # "Decal" ids do not work in ImageLabels
    if st >= 300:
        raise RuntimeError(f"upload {name}: HTTP {st} {body[:300]}")
    op = json.loads(body)["path"]
    for _ in range(60):
        st, body, _ = req("GET", f"https://apis.roblox.com/assets/v1/{op}")
        d = json.loads(body)
        if d.get("done"):
            resp = d.get("response") or {}
            if "assetId" not in resp:
                raise RuntimeError(f"upload {name}: no assetId in {json.dumps(d)[:300]}")
            return int(resp["assetId"]), (resp.get("moderationResult") or {}).get("moderationState")
        time.sleep(3)
    raise RuntimeError(f"upload {name}: operation timed out")


def write_config(manifest, args, icon_index):
    tiles = args.tiles
    ids = []
    for r in range(tiles):
        row = []
        for c in range(tiles):
            e = manifest.get(f"tile_{r}_{c}")
            row.append(f'"rbxassetid://{e["assetId"]}"' if e and e.get("assetId") else '""')
        ids.append("\t{ " + ", ".join(row) + " },")
    atlas = manifest.get("blips")
    atlas_id = f'"rbxassetid://{atlas["assetId"]}"' if atlas and atlas.get("assetId") else '""'
    icon_lines = []
    for name, (x, y, w, h) in icon_index.items():
        icon_lines.append(f"\t{name} = {{ {x}, {y}, {w}, {h} }},")
    block = "\n".join([
        BEGIN,
        "-- World square covered by the map image (studs) and its tiles (row 1 = north = smallest Z, column 1 = west).",
        f"Minimap.WORLD_MIN = Vector2.new({args.world_min:g}, {args.world_min:g})",
        f"Minimap.WORLD_SIZE = {args.world_size:g}",
        f"Minimap.TILE_COUNT = {tiles}",
        f"Minimap.TILE_PIXELS = {args.px // tiles}",
        "Minimap.TILES = {",
        *ids,
        "}",
        "-- Blip atlas (tools/minimap/icons.py): name -> { x, y, w, h } in atlas pixels.",
        f"Minimap.ATLAS = {atlas_id}",
        "Minimap.ATLAS_CELLS = {",
        *icon_lines,
        "}",
        END,
    ])
    src = open(CONFIG).read()
    a, b = src.index(BEGIN), src.index(END) + len(END)
    new = src[:a] + block + src[b:]
    if new != src:
        open(CONFIG, "w").write(new)
        print(f"updated {os.path.relpath(CONFIG, ROOT)}")
    else:
        print("Config/Minimap.luau already up to date")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-upload", action="store_true")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--ss", type=int, default=3)
    ap.add_argument("--px", type=int, default=2048)
    ap.add_argument("--tiles", type=int, default=2)
    ap.add_argument("--world-min", type=float, default=-1024)
    ap.add_argument("--world-size", type=float, default=2048)
    ap.add_argument("--geometry", help="reuse this geometry.json instead of exporting the world again (a restyle of "
                    "the current map while the city layout is being changed elsewhere)")
    args = ap.parse_args()
    os.makedirs(ASSETS, exist_ok=True)
    os.makedirs(BUILD, exist_ok=True)

    if args.geometry:
        geo = os.path.abspath(args.geometry)
        print(f"reusing {os.path.relpath(geo, ROOT)} (no export)")
    else:
        geo = os.path.join(BUILD, "geometry.json")
        run(["lune", "run", "tools/minimap/export.luau", geo])
    run([sys.executable, "-I", "tools/minimap/render_map.py", geo, ASSETS, "--ss", str(args.ss), "--px", str(args.px),
         "--tiles", str(args.tiles), "--world-min", str(args.world_min), "--world-size", str(args.world_size)])
    run([sys.executable, "-I", "tools/minimap/icons.py", os.path.join(ASSETS, "blips.png"),
         "--sheet", os.path.join(BUILD, "blips_sheet.png")])

    import icons  # noqa: E402

    manifest = json.load(open(MANIFEST)) if os.path.exists(MANIFEST) else {}
    files = {f"tile_{r}_{c}": os.path.join(ASSETS, f"tile_{r}_{c}.png")
             for r in range(args.tiles) for c in range(args.tiles)}
    files["blips"] = os.path.join(ASSETS, "blips.png")
    for key, path in files.items():
        h = sha(path)
        entry = manifest.get(key) or {}
        if not args.force and entry.get("sha256") == h and entry.get("assetId"):
            print(f"{key}: unchanged ({entry['assetId']})")
            continue
        if args.no_upload:
            print(f"{key}: changed, not uploaded (--no-upload)")
            continue
        asset_id, moderation = upload_image(path, f"HotwireCity minimap {key}")  # assetType Image
        manifest[key] = {"assetId": asset_id, "sha256": h, "file": os.path.relpath(path, ROOT),
                         "moderation": moderation, "uploaded": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        print(f"{key}: uploaded -> {asset_id} ({moderation})")
        json.dump(manifest, open(MANIFEST, "w"), indent=2)
    json.dump(manifest, open(MANIFEST, "w"), indent=2)
    write_config(manifest, args, icons.index())


if __name__ == "__main__":
    main()
