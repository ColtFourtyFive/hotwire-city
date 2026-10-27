#!/usr/bin/env python3
"""Download the CC0 PBR textures + sky HDRI + OFL sign fonts the building kit uses.

    python3 -I tools/blender/buildkit/fetch_assets.py          # idempotent, skips files already present

Everything lands in tools/blender/buildkit/_cache/ (gitignore it; ~45 MB). Sources:
  * Poly Haven (CC0)  api.polyhaven.com/files/<id> -> dl.polyhaven.org   (1k JPG: diff, nor_gl, rough[, metal])
  * Google Fonts (SIL OFL) raw TTFs from github.com/google/fonts
"""
import json, os, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "_cache")

# material key -> Poly Haven texture id. Keys are what the kit (bk_mat.py) refers to.
TEXTURES = {
    "brick_red": "red_brick_03",
    "brick_tan": "yellow_brick",
    "brick_painted": "whitewashed_brick",    # white painted brick: tintable
    "stucco": "white_stucco_02",             # near-white: tinted per building (pastels)
    "plaster": "white_plaster_02",
    "concrete": "concrete_wall_008",
    "concrete_board": "concrete_slab_wall",
    "granite": "granite_tile",
    "facade_tiles": "rectangular_facade_tiles",
    "roof_gravel": "gravel_concrete",
    "roof_tar": "tarred_gravel",
    "metal": "metal_plate_02",
    "shutter": "painted_metal_shutter",
    "asphalt": "asphalt_02",
    "sidewalk": "large_grey_tiles",
    "terrazzo": "terrazzo_tiles",
    "curb": "concrete_floor_01",
    # added for the full archetype set
    "corrugated": "corrugated_iron_02",        # raw galvanised siding / roofs
    "metal_siding": "box_profile_metal_sheet", # painted warehouse cladding: tintable
    "roof_clay": "clay_roof_tiles_02",         # Spanish / mission tile (LA suburbs, deco)
    "roof_shingle": "grey_roof_01",            # asphalt shingles (ranch houses)
    "cmu": "concrete_block_wall",              # block walls, warehouse bases, garden walls
    "wood_fence": "brown_planks_05",           # horizontal plank fences / modern cladding
    "wood_slats": "synthetic_wood",            # vertical slat cladding (hills mansion)
    "marble": "marble_01",                     # tower podiums, lobbies, mansion plinths
    "pavers": "concrete_pavement_03",          # forecourts, plazas, pool decks
    "precast": "concrete_panels",              # tilt-up / precast panels
    "grass": "leafy_grass",                    # lawns (scene + optional Lawn role)
}
MAPS = {"diff": "Diffuse", "nor": "nor_gl", "rough": "Rough", "metal": "Metal"}
HDRIS = {"sky_late_afternoon": ("qwantani_late_afternoon_puresky", "4k"),
         "sky_sunset": ("qwantani_sunset_puresky", "2k"),
         "sky_dusk": ("qwantani_dusk_2_puresky", "2k")}
FONTS = {  # OFL fonts for signage
    "Pacifico": "ofl/pacifico/Pacifico-Regular.ttf",
    "Monoton": "ofl/monoton/Monoton-Regular.ttf",
    "Righteous": "ofl/righteous/Righteous-Regular.ttf",
    "Bungee": "ofl/bungee/Bungee-Regular.ttf",
    "Limelight": "ofl/limelight/Limelight-Regular.ttf",
    "Oswald": "ofl/oswald/Oswald%5Bwght%5D.ttf",
}


def get(url, dst):
    if os.path.exists(dst) and os.path.getsize(dst) > 0:
        return False
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    req = urllib.request.Request(url, headers={"User-Agent": "HotwireCity-buildkit/1.0"})
    with urllib.request.urlopen(req, timeout=120) as r, open(dst + ".part", "wb") as f:
        f.write(r.read())
    os.replace(dst + ".part", dst)
    return True


def api(asset_id):
    req = urllib.request.Request(f"https://api.polyhaven.com/files/{asset_id}", headers={"User-Agent": "HotwireCity-buildkit/1.0"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def main():
    for key, pid in TEXTURES.items():
        files = None
        for short, long in MAPS.items():
            dst = os.path.join(CACHE, "tex", key, f"{short}.jpg")
            if os.path.exists(dst):
                continue
            files = files or api(pid)
            ent = files.get(long, {}).get("1k", {}).get("jpg")
            if not ent:
                continue
            get(ent["url"], dst)
            print("tex", key, short)
        with open(os.path.join(CACHE, "tex", key, "SOURCE.txt"), "w") as f:
            f.write(f"Poly Haven (CC0): https://polyhaven.com/a/{pid}\n")
    for key, (pid, res) in HDRIS.items():
        dst = os.path.join(CACHE, "hdri", f"{key}.hdr")
        if not os.path.exists(dst):
            get(api(pid)["hdri"][res]["hdr"]["url"], dst)
            print("hdri", key)
    for name, path in FONTS.items():
        dst = os.path.join(CACHE, "fonts", f"{name}.ttf")
        try:
            if get("https://raw.githubusercontent.com/google/fonts/main/" + path, dst):
                print("font", name)
        except Exception as e:  # fonts are optional: signage falls back to DejaVu
            print("font FAILED", name, e, file=sys.stderr)


if __name__ == "__main__":
    main()
