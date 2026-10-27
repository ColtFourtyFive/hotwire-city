#!/usr/bin/env python3
"""Batch-export the building kit + write the manifest the world builder consumes.

    python3 -I tools/blender/buildkit/manifest.py                         # every archetype x 4 seeds, light GLBs
    python3 -I tools/blender/buildkit/manifest.py --seeds 8 --archs house midtown
    python3 -I tools/blender/buildkit/manifest.py --embed                 # self-contained GLBs (textures inside)

Output (tools/blender/buildkit/out/):
  glb/<arch>_<seed>.glb + .json     one GLB per building, one mesh object per material role (= one MeshPart)
  glb/<arch>_00_embedded.glb        seed 0 of every archetype also exported with embedded textures (Studio test)
  texlib/<set>/{color,normal,roughness,metalness}.{jpg,png} + texlib.json   shared SurfaceAppearance library
  manifest.json                     footprint, height, tris, parts, materials, spawns, files, budget checks
Budget checks: every part <= 20,000 tris (we split at 19,500), every texture <= 1024 px.
"""
import argparse, datetime, json, os, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import bpy  # noqa: E402
import build as BK  # noqa: E402
import bk_mat as M  # noqa: E402

DEFAULT_ARCHS = ["tower", "midtown", "strip", "corner_store", "gas", "diner", "deco", "house", "warehouse", "mansion"]


def texlib(out):
    """Copy every tiling set + generated atlas once into out/texlib with Roblox-friendly names."""
    lib = {}
    dst_root = os.path.join(out, "texlib")
    for key, (folder, rmul, nstr) in M.TEXSETS.items():
        src = os.path.join(M.TEX, folder)
        if not os.path.isdir(src):
            continue
        d = os.path.join(dst_root, key)
        os.makedirs(d, exist_ok=True)
        ent = {"normal_strength": nstr, "tintable": key in M.TINTABLE}
        color_src = os.path.join(M.GEN, f"{key}_tint.png") if key in M.TINTABLE else os.path.join(src, "diff.jpg")
        for role, path in (("color", color_src), ("normal", os.path.join(src, "nor.jpg")),
                           ("roughness", os.path.join(src, "rough.jpg")), ("metalness", os.path.join(src, "metal.jpg"))):
            if os.path.exists(path):
                fn = role + os.path.splitext(path)[1]
                shutil.copy2(path, os.path.join(d, fn))
                ent[role] = f"{key}/{fn}"
        srcnote = os.path.join(src, "SOURCE.txt")
        if os.path.exists(srcnote):
            ent["source"] = open(srcnote).read().strip()
        lib[key] = ent
    d = os.path.join(dst_root, "atlas")
    os.makedirs(d, exist_ok=True)
    for fn in ("windows_day.png", "windows_lit.png", "awnings.png", "signs.png", "brands.png", "grime.png", "atlas.json"):
        shutil.copy2(os.path.join(M.GEN, fn), os.path.join(d, fn))
        lib[os.path.splitext(fn)[0]] = {"color": f"atlas/{fn}"}
    json.dump(lib, open(os.path.join(dst_root, "texlib.json"), "w"), indent=1)
    return lib


def check_textures(out):
    bad = []
    for dp, _, fns in os.walk(os.path.join(out, "texlib")):
        for fn in fns:
            if fn.lower().endswith((".png", ".jpg")):
                im = bpy.data.images.load(os.path.join(dp, fn), check_existing=True)
                if max(im.size) > 1024:
                    bad.append((os.path.join(dp, fn), tuple(im.size)))
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=4)
    ap.add_argument("--archs", nargs="*", default=DEFAULT_ARCHS)
    ap.add_argument("--embed", action="store_true", help="embed textures in every GLB")
    ap.add_argument("--no-embed-first", action="store_true", help="skip the embedded copy of seed 0")
    ap.add_argument("--out", default=os.path.join(HERE, "out"))
    a = ap.parse_args()
    gdir = os.path.join(a.out, "glb")
    os.makedirs(gdir, exist_ok=True)
    lib = texlib(a.out)
    rows, violations = [], []
    for arch in a.archs:
        for seed in range(a.seeds):
            B = BK.build(arch, seed)
            path, meta = BK.export_glb(B, gdir, textures=a.embed)
            files = {"glb": f"glb/{meta['glb']}", "json": f"glb/{B.name}.json"}
            if seed == 0 and not a.embed and not a.no_embed_first:
                B = BK.build(arch, seed)
                p2, _ = BK.export_glb(B, gdir, textures=True, suffix="_embedded")
                files["glb_embedded"] = f"glb/{os.path.basename(p2)}"
            for pn, p in meta["parts"].items():
                if p["tris"] > 20000:
                    violations.append(f"{B.name}:{pn} has {p['tris']} tris")
            rows.append({k: meta[k] for k in ("name", "archetype", "seed", "footprint", "height", "base_depth", "tags",
                                              "total_tris", "max_part_tris", "spawns")}
                        | {"parts": {pn: {"role": p["role"], "tris": p["tris"], "night_only": p["night_only"],
                                          "material": p["material"]} for pn, p in meta["parts"].items()},
                           "n_parts": len(meta["parts"]), "files": files, "glb_bytes": meta["glb_bytes"]})
            print("%-18s parts=%2d tris=%6d max_part=%6d  %5.1f MB" % (B.name, len(meta["parts"]), meta["total_tris"],
                                                                      meta["max_part_tris"], meta["glb_bytes"] / 1e6))
    tex_bad = check_textures(a.out)
    violations += [f"texture {p} is {s}" for p, s in tex_bad]
    man = {"generated": datetime.datetime.now().isoformat(timespec="seconds"), "units": "studs (1 Blender unit = 1 stud)",
           "axes": "glTF Y-up; building front = +Z in glTF (Blender -Y). Origin = lot bottom-centre at grade.",
           "roblox": {"part_tri_limit": 20000, "split_at": BK.MAX_TRIS, "max_texture_px": 1024,
                      "night": "parts with night_only=true (WindowsLit) are hidden by day; role Neon switches to "
                               "Material=Neon at night; Sign/Brand may use SurfaceAppearance emissive if available",
                      "tint": "material.tint -> SurfaceAppearance.Color (texture sets marked tintable are grey bases)"},
           "texture_library": "texlib/texlib.json", "count": len(rows), "violations": violations, "buildings": rows}
    with open(os.path.join(a.out, "manifest.json"), "w") as f:
        json.dump(man, f, indent=1)
    print("manifest:", os.path.join(a.out, "manifest.json"), len(rows), "buildings,", len(violations), "violations")
    for v in violations:
        print("  VIOLATION", v)


if __name__ == "__main__":
    main()
