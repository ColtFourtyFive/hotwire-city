#!/usr/bin/env python3
"""Hotwire City procedural building kit - build, export and quick-preview buildings.

    python3 -I tools/blender/buildkit/build.py --arch midtown --seed 3 --render /tmp/m.png
    python3 -I tools/blender/buildkit/build.py --arch tower --seed 1 --export tools/blender/buildkit/out/glb
    python3 -I tools/blender/buildkit/build.py --arch house --kw '{"floors":2,"roof":"clay"}' --render /tmp/h.png

Archetypes (see ARCHS): tower, midtown, strip, corner_store, gas, diner, deco, house, warehouse, mansion.
Run fetch_assets.py and gen_textures.py first. Full batch export + manifest: manifest.py. Hero renders: render_kit.py.
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
for _mod in ("bk_tower", "bk_retail", "bk_deco", "bk_house", "bk_industrial", "bk_mansion"):
    try:
        _m = __import__(_mod)
    except ImportError as e:  # a module still being written must not break the others
        print("WARN cannot import", _mod, e, file=sys.stderr)
        continue
    ARCHS.update(getattr(_m, "ARCHS", {}))

MAX_TRIS = 19_500   # Roblox MeshPart limit is 20k; keep a margin for triangulation differences


def make_material(B, role, night=False):
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
        emit = 1.2 if (night and role in ("Sign", "Brand")) else 0.0
        return M.atlas(name, spec[1], *spec[2:], emit=emit)
    if k == "lit":
        return M.lit(name)
    if k == "grime":
        return M.grime(name, strength=spec[1] if len(spec) > 1 else 1.0)
    if k == "neon":
        m = M.neon(name, spec[1], strength=8.0 if night else 0.0)
        return m
    if k == "clear":
        return M.clear(name, *spec[1:])
    if k == "water":
        return M.water(name, *spec[1:])
    raise ValueError(spec)


def split_buf(buf, limit=MAX_TRIS):
    """Split a MeshBuf into <= limit-triangle chunks (whole faces, vertices duplicated as needed)."""
    if buf.tris() <= limit:
        return [buf]
    out, cur, t = [], None, 0
    for f, uv in zip(buf.f, buf.uv):
        n = len(f) - 2
        if cur is None or t + n > limit:
            cur = G.MeshBuf(f"{buf.name}_{len(out) + 1}", buf.tile)
            out.append(cur)
            t = 0
        cur.add([buf.v[i] for i in f], [tuple(range(len(f)))], [uv])
        t += n
    return out


def instantiate(B, col=None, loc=(0, 0, 0), rot_z=0.0, night=False, split=False, roles=None):
    col = col or bpy.context.scene.collection
    root = bpy.data.objects.new(B.name, None)
    col.objects.link(root)
    root.location = loc
    root.rotation_euler = (0, 0, math.radians(rot_z))
    objs = {}
    for role in A.ROLE_ORDER:
        if roles is not None and role not in roles:
            continue
        buf = B.bufs.get(role)
        if buf is None or buf.empty():
            continue
        mat = make_material(B, role, night)
        parts = split_buf(buf) if split else [buf]
        for k, pb in enumerate(parts):
            ob = G.to_object(pb, mat, col, parent=root,
                             weighted=role not in ("Glass", "Sign", "Brand", "WindowsLit", "Awning", "Grime", "Paint", "Site", "Asphalt", "Lawn", "Water", "Clear"))
            ob.name = pb.name
            if role in A.NIGHT_ONLY:
                ob.hide_render = not night
            if role == "Grime":
                ob.visible_shadow = False
            objs[ob.name] = (role, ob)
    return root, objs


def build(arch, seed, **kw):
    return ARCHS[arch](seed=seed, **kw)


# ----------------------------------------------------------------------------- export
def _json_safe(d):
    return {k: (list(v) if hasattr(v, "__len__") and not isinstance(v, str) else v) for k, v in d.items()}


def export_glb(B, out_dir, textures=True):
    """One GLB per building, one mesh object per material role (=> one MeshPart each, split past 19.5k tris).
    Writes <name>.glb and <name>.json (parts, tris, materials, tint, night-only flags) next to it."""
    S.reset()
    root, objs = instantiate(B, night=False, split=True)
    for name, (role, ob) in objs.items():   # export everything, including night-only parts
        ob.hide_render = False
    os.makedirs(out_dir, exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    for _, ob in objs.values():
        ob.select_set(True)
    root.select_set(True)
    path = os.path.join(out_dir, B.name + ".glb")
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_apply=True,
                              export_image_format="AUTO", export_yup=True, export_texcoords=True,
                              export_normals=True, export_materials="EXPORT" if textures else "PLACEHOLDER")
    meta = {"name": B.name, "archetype": B.kind, "seed": B.seed, "footprint": list(B.footprint),
            "height": round(B.height, 2), "base_depth": round(B.base_depth, 2), "tags": B.tags,
            "front": "-Y in Blender = +Z in glTF; Roblox front is -Z, so use yaw=180 in Config/Assets",
            "parts": {}}
    for name, (role, ob) in objs.items():
        tris = sum(len(p.vertices) - 2 for p in ob.data.polygons)
        mat = _json_safe(dict(ob.active_material.get("roblox", {}))) if ob.active_material else {}
        meta["parts"][name] = {"role": role, "tris": tris, "material": mat, "tile_studs": A.TILES.get(role),
                               "night_only": role in A.NIGHT_ONLY}
    meta["total_tris"] = sum(r["tris"] for r in meta["parts"].values())
    meta["max_part_tris"] = max(r["tris"] for r in meta["parts"].values())
    meta["glb"] = os.path.basename(path)
    meta["glb_bytes"] = os.path.getsize(path)
    with open(os.path.join(out_dir, B.name + ".json"), "w") as f:
        json.dump(meta, f, indent=1)
    return path, meta


# ----------------------------------------------------------------------------- quick preview
def preview(B, path, night=False, cam=None, samples=64, sky="sky_late_afternoon", sun_az=-55.0, props=True,
            backfaces=False):
    S.reset()
    if night:
        S.night()
    else:
        S.world(sky, sun_az=sun_az)
    root, objs = instantiate(B, night=night)
    W, D = B.footprint
    col = bpy.context.scene.collection
    S.street_strip(col, -W / 2 - 160, W / 2 + 160, -D / 2 - 0.01)
    if props:
        y_lamp = -D / 2 - 12 + 1.6
        for x in (-W / 2 - 14, W / 2 + 14):
            S.street_lamp(col, x, y_lamp, facing=(0, -1), night=night)
    H = B.height
    if cam is None:
        cam = dict(loc=(-W * 0.62 - 10, -D / 2 - 12 - 40, 7.0), target=(W * 0.05, -D / 2, H * 0.36), lens=24)
    S.camera(cam["loc"], cam["target"], cam.get("lens", 24), cam.get("shift_y", 0.0))
    if backfaces:
        backface_debug()
    S.haze(night=night)
    S.render(path, samples=samples)
    return objs


def backface_debug():
    """Replace every material with grey-front / red-back (Roblox culls back faces: anything red is wrong)."""
    m = bpy.data.materials.new("BackfaceDebug")
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    mix = nt.nodes.new("ShaderNodeMix"); mix.data_type = "RGBA"
    mix.inputs[6].default_value = (0.6, 0.6, 0.6, 1)
    mix.inputs[7].default_value = (1.0, 0.0, 0.0, 1)
    nt.links.new(geo.outputs["Backfacing"], mix.inputs[0])
    nt.links.new(mix.outputs[2], bsdf.inputs["Base Color"])
    for ob in bpy.data.objects:
        if ob.type == "MESH" and ob.data.materials:
            ob.data.materials[0] = m


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
    ap.add_argument("--backfaces", action="store_true", help="debug render: back faces red")
    ap.add_argument("--kw", default="{}", help="json overrides for the archetype")
    ap.add_argument("--cam", default=None, help='json {"loc":[x,y,z],"target":[x,y,z],"lens":24}')
    a = ap.parse_args(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else None)
    kw = json.loads(a.kw)
    B = build(a.arch, a.seed, **kw)
    st = B.stats()
    print("stats", B.name, st, "total", sum(st.values()), "footprint", B.footprint, "height", round(B.height, 1))
    if a.render:
        preview(B, a.render, night=a.night, cam=json.loads(a.cam) if a.cam else None, samples=a.samples, sky=a.sky, sun_az=a.sun,
                backfaces=a.backfaces)
    if a.export:
        p, meta = export_glb(B, a.export)
        print("exported", p, meta["total_tris"], "max part", meta["max_part_tris"])


if __name__ == "__main__":
    main()
