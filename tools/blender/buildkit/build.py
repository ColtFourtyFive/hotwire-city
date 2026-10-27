#!/usr/bin/env python3
"""Hotwire City procedural building kit - build, preview-render and export buildings.

    python3 -I tools/blender/buildkit/build.py --arch midtown --seed 3 --render docs/v2/proto/buildkit/midtown.png
    python3 -I tools/blender/buildkit/build.py --arch tower --seed 1 --export tools/blender/buildkit/out/glb
    python3 -I tools/blender/buildkit/build.py --all --export tools/blender/buildkit/out/glb   # every archetype x seeds

Archetypes: tower (downtown glass), midtown (brick/stucco apartments), shop (single storey shop/diner),
deco (beach art-deco hotel). Run fetch_assets.py and gen_textures.py first.
"""
import argparse, json, math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import bpy  # noqa: E402
import bk_geo as G  # noqa: E402
import bk_mat as M  # noqa: E402
import bk_arch as A  # noqa: E402
import bk_scene as S  # noqa: E402

ARCHS = {"midtown": A.midtown}
for _n in ("tower", "shop", "deco"):
    if hasattr(A, _n):
        ARCHS[_n] = getattr(A, _n)

ROLE_ORDER = ["Walls", "Trim", "Accent", "Frames", "Glass", "Roof", "Details", "Awning", "Sign", "WindowsLit"]


def make_material(B, role):
    spec = B.spec.get(role, ("color", (0.5, 0.5, 0.5), 0.5, 0.0))
    name = f"{B.name}_{role}"
    k = spec[0]
    if k == "tex":
        return M.textured(name, spec[1], spec[2], *spec[3:])
    if k == "color":
        return M.color(name, spec[1], *spec[2:])
    if k == "glass":
        return M.glass(name, **(spec[1] if len(spec) > 1 else {}))
    if k == "atlas":
        return M.atlas(name, spec[1], *spec[2:])
    if k == "lit":
        return M.lit(name)
    raise ValueError(spec)


def instantiate(B, col=None, loc=(0, 0, 0), rot_z=0.0, night=False):
    col = col or bpy.context.scene.collection
    root = bpy.data.objects.new(B.name, None)
    col.objects.link(root)
    root.location = loc
    root.rotation_euler = (0, 0, math.radians(rot_z))
    objs = {}
    for role in ROLE_ORDER:
        buf = B.bufs.get(role)
        if buf is None or buf.empty():
            continue
        ob = G.to_object(buf, make_material(B, role), col, parent=root,
                         weighted=role not in ("Glass", "Sign", "WindowsLit", "Awning"))
        if role == "WindowsLit":
            ob.hide_render = not night
        objs[role] = ob
    return root, objs


def build(arch, seed, **kw):
    return ARCHS[arch](seed=seed, **kw)


# ----------------------------------------------------------------------------- export
def export_glb(B, out_dir):
    """One GLB per building, one mesh object per role (=> one MeshPart each), modifiers applied.
    Writes <name>.glb and <name>.json (roles, tris, materials, tint) next to it."""
    S.reset()
    root, objs = instantiate(B, night=True)
    os.makedirs(out_dir, exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    for ob in objs.values():
        ob.select_set(True)
    root.select_set(True)
    path = os.path.join(out_dir, B.name + ".glb")
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_apply=True,
                              export_image_format="AUTO", export_yup=True, export_texcoords=True,
                              export_normals=True, export_materials="EXPORT")
    meta = {"name": B.name, "archetype": B.kind, "seed": B.seed, "footprint": B.footprint, "height": round(B.height, 2),
            "front": "-Y in Blender = +Z in glTF; Roblox front is -Z, so use yaw=180 in Config/Assets",
            "roles": {}}
    for role, ob in objs.items():
        tris = sum(len(p.vertices) - 2 for p in ob.data.polygons)
        meta["roles"][role] = {"tris": tris, "material": dict(ob.active_material.get("roblox", {})) if ob.active_material else {},
                               "tile_studs": A.TILES.get(role),
                               "night_only": role == "WindowsLit"}
        meta["roles"][role]["material"] = {k: (list(v) if hasattr(v, "__len__") and not isinstance(v, str) else v)
                                           for k, v in meta["roles"][role]["material"].items()}
    meta["total_tris"] = sum(r["tris"] for r in meta["roles"].values())
    with open(os.path.join(out_dir, B.name + ".json"), "w") as f:
        json.dump(meta, f, indent=1)
    return path, meta


# ----------------------------------------------------------------------------- preview
def preview(B, path, night=False, cam=None, samples=64, sky="sky_late_afternoon", sun_az=-55.0, props=True):
    S.reset()
    S.world(sky, sun_az=sun_az, strength=0.25 if night else 1.0)
    root, objs = instantiate(B, night=night)
    W, D = B.footprint
    col = bpy.context.scene.collection
    S.street_strip(col, -W / 2 - 160, W / 2 + 160, -D / 2 - 0.01)
    # neighbouring lots: plain sidewalk ground continues; side ground
    if props:
        y_lamp = -D / 2 - 12 + 1.6
        for x in (-W / 2 - 14, W / 2 + 14):
            S.street_lamp(col, x, y_lamp, facing=-1)
        S.palm(col, -W / 2 - 4, y_lamp + 0.6, h=24, seed=B.seed)
        S.palm(col, W / 2 + 26, y_lamp + 0.6, h=27, seed=B.seed + 5)
    H = B.height
    if cam is None:
        d = max(W, H * 0.9)
        cam = dict(loc=(-W * 0.75 - 6, -D / 2 - 12 - 26, 6.5), target=(W * 0.12, -D / 2, H * 0.42), lens=22)
    S.camera(cam["loc"], cam["target"], cam.get("lens", 24), cam.get("shift_y", 0.0))
    if night:
        bpy.context.scene.view_settings.exposure = 0.8
    S.render(path, samples=samples)
    return objs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", default="midtown")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--render")
    ap.add_argument("--night", action="store_true")
    ap.add_argument("--samples", type=int, default=64)
    ap.add_argument("--sky", default="sky_late_afternoon")
    ap.add_argument("--sun", type=float, default=-55.0)
    ap.add_argument("--export")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--kw", default="{}", help="json overrides for the archetype")
    ap.add_argument("--cam", default=None, help='json {"loc":[x,y,z],"target":[x,y,z],"lens":24}')
    a = ap.parse_args()
    kw = json.loads(a.kw)
    if a.all:
        rows = []
        for arch in ARCHS:
            for seed in range(4):
                B = build(arch, seed)
                p, meta = export_glb(B, a.export)
                rows.append((B.name, meta["total_tris"], max(r["tris"] for r in meta["roles"].values()), len(meta["roles"])))
        for r in rows:
            print("%-14s total=%6d max_role=%6d parts=%d" % r)
        return
    B = build(a.arch, a.seed, **kw)
    print("stats", B.name, B.stats(), "total", sum(B.stats().values()))
    if a.render:
        preview(B, a.render, night=a.night, cam=json.loads(a.cam) if a.cam else None, samples=a.samples, sky=a.sky, sun_az=a.sun)
    if a.export:
        p, meta = export_glb(B, a.export)
        print("exported", p, meta["total_tris"])


if __name__ == "__main__":
    main()
