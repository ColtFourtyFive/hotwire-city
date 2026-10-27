#!/usr/bin/env python3
"""Evidence renders: real production GLBs (assets/buildings/glb) placed by BuildingService's own planner
(lune run tools/blender/buildkit/export_placements.luau -> _cache/placements.json), surfaced the way the game does it
(rbxmat.surface + the plan's wall finish / glass tint, the place's HC_ MaterialVariant maps box-projected at their
StudsPerTile, atlas Images on the GLB UVs), on the generator's road network.

    python3 -I tools/blender/buildkit/render_city.py --scene downtown midtown beach suburbs downtown_night
    python3 -I tools/blender/buildkit/render_city.py --scene midtown --samples 24 --out /tmp/x

Coordinates: Blender = M * Roblox with M = [[-1,0,0],[0,0,1],[0,1,0]] (x -> -x, z -> y, y -> z), the same turn the
Roblox importer applies to the kit's GLBs, so a template's kit-space mesh drops in with M R M^-1 and diag(sx, sz, sy).
Preview-only context: road ribbons, sidewalks, cobra-head lamps, palms. Output: docs/v2/early/buildings/<scene>.png.
"""
import argparse, json, math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bpy  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402
import bk_scene as S  # noqa: E402
import rbxmat  # noqa: E402

ROOT = rbxmat.ROOT
GLB = os.path.join(ROOT, "assets", "buildings", "glb")
CATALOG = os.path.join(ROOT, "assets", "buildings", "catalog.json")
TEXTURES = os.path.join(HERE, "out", "textures")
FB = os.path.join(ROOT, "assets", "buildings", "textures")
OUT = os.path.join(ROOT, "docs", "v2", "early", "buildings")
M3 = Matrix(((-1, 0, 0), (0, 0, 1), (0, 1, 0)))
CORE = {"Walls", "Walls2", "Trim", "Glass", "Roof", "WindowsLit"}

# scene: district to centre on (densest cluster of its buildings) or a fixed Roblox point, inclusion radius,
# camera offset from the centre (Roblox studs: dx, dy, dz), look-at height, lens, sky, sun azimuth
SCENES = {
    "downtown": dict(center=(150, 12, -300), radius=1100, cam=(-760, 210, 820), look=(120, 140, -380), lens=30),
    "downtown_street": dict(district="downtown", radius=520, cam=(-150, 9, 210), look_d=(60, 70, -120), lens=24),
    "midtown": dict(district="midtown", radius=520, cam=(-260, 70, 300), look_d=(20, 30, -40), lens=26),
    "beach": dict(district="beach", radius=520, cam=(260, 60, 300), look_d=(-30, 25, -40), lens=26),
    "suburbs": dict(district="southgate", radius=420, cam=(-200, 90, 230), look_d=(10, 0, -30), lens=26),
    "downtown_night": dict(center=(150, 12, -300), radius=1100, cam=(-760, 210, 820), look=(120, 140, -380), lens=30,
                           night=True),
}


def to_b(p):
    return Vector((-p[0], p[2], p[1]))


# ---------------------------------------------------------------------------------------------------- materials
_mats = {}


def _lin(c):
    return tuple(((v / 255 + 0.055) / 1.055) ** 2.4 if v / 255 > 0.04045 else v / 255 / 12.92 for v in c)


def _img(path, data=False):
    im = bpy.data.images.load(path, check_existing=True)
    if data:
        im.colorspace_settings.name = "Non-Color"
    return im


def material(s, night=False):
    """Blender stand-in for one Roblox surface (rbxmat.surface dict)."""
    key = (s["material"], s.get("variant"), tuple(s["color"]), s.get("texture"), s.get("transparency"), night)
    if key in _mats:
        return _mats[key]
    m = bpy.data.materials.new("R_%s_%s" % (s["material"], s.get("variant") or s.get("texture") or ""))
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes["Principled BSDF"]
    col = (*_lin(s["color"]), 1.0)
    b.inputs["Base Color"].default_value = col
    variant = s.get("variant") or rbxmat.overrides().get(s["material"])
    look = rbxmat.look().get(variant) if variant else None
    if s.get("texture"):
        path = os.path.join(TEXTURES, s["texture"] + ".png")
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image = _img(path)
        nt.links.new(tex.outputs[0], b.inputs["Base Color"])
        b.inputs["Roughness"].default_value = 0.18 if s["texture"] == "windows_day" else 0.45
    elif variant == "HC_WindowGlass":
        b.inputs["Metallic"].default_value = 1.0
        b.inputs["Roughness"].default_value = 0.07
    elif look:
        tc = nt.nodes.new("ShaderNodeTexCoord")
        sc = nt.nodes.new("ShaderNodeVectorMath")
        sc.operation = "SCALE"
        sc.inputs["Scale"].default_value = 1.0 / float(look["studsPerTile"])
        nt.links.new(tc.outputs["Object"], sc.inputs[0])
        files = look["files"]
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image = _img(os.path.join(ROOT, files["color"]))
        tex.projection = "BOX"
        tex.projection_blend = 0.15
        nt.links.new(sc.outputs[0], tex.inputs[0])
        mix = nt.nodes.new("ShaderNodeMix")
        mix.data_type = "RGBA"
        mix.blend_type = "MULTIPLY"
        mix.inputs[0].default_value = 1.0
        nt.links.new(tex.outputs[0], mix.inputs[6])
        mix.inputs[7].default_value = col
        nt.links.new(mix.outputs[2], b.inputs["Base Color"])
        rt = nt.nodes.new("ShaderNodeTexImage")
        rt.image = _img(os.path.join(ROOT, files["roughness"]), True)
        rt.projection = "BOX"
        rt.projection_blend = 0.15
        nt.links.new(sc.outputs[0], rt.inputs[0])
        nt.links.new(rt.outputs[0], b.inputs["Roughness"])
        bump = nt.nodes.new("ShaderNodeBump")
        bump.inputs["Strength"].default_value = 0.25
        bump.inputs["Distance"].default_value = 0.05
        nt.links.new(tex.outputs[0], bump.inputs["Height"])
        nt.links.new(bump.outputs[0], b.inputs["Normal"])
        if files.get("metalness"):
            b.inputs["Metallic"].default_value = 0.6
    elif s["material"] == "Metal":
        b.inputs["Metallic"].default_value = 0.75
        b.inputs["Roughness"].default_value = 0.42
    elif s["material"] == "Glass":
        b.inputs["Roughness"].default_value = 0.05
        b.inputs["Transmission Weight"].default_value = 1.0 - min(0.9, 1.0 - (s.get("transparency") or 0.5))
        b.inputs["Alpha"].default_value = 1.0 - 0.6 * (s.get("transparency") or 0.5)
        try:
            m.surface_render_method = "BLENDED"
        except Exception:
            pass
    else:
        b.inputs["Roughness"].default_value = 0.4
    if s["material"] == "Neon" and night:
        b.inputs["Emission Color"].default_value = col
        b.inputs["Emission Strength"].default_value = 3.5
    m.use_backface_culling = s["material"] != "Glass"
    _mats[key] = m
    return m


# ---------------------------------------------------------------------------------------------------- templates
_tpl = {}


def template_meshes(key):
    """{part name -> mesh data} from the production GLB (imported once, objects unlinked)."""
    if key in _tpl:
        return _tpl[key]
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(GLB, key + ".glb"))
    meshes = {}
    for ob in set(bpy.data.objects) - before:
        if ob.type == "MESH":
            ob.data.transform(ob.matrix_world)   # bake the import transform (identity for kit exports)
            meshes[ob.name.split(".")[0]] = ob.data
        bpy.data.objects.remove(ob)
    _tpl[key] = meshes
    return meshes


def place_building(col, b, cat, night):
    key = b["template"]
    v = cat[key]
    meshes = template_meshes(key)
    c = b["cframe"]
    R = Matrix(((c[3], c[4], c[5]), (c[6], c[7], c[8]), (c[9], c[10], c[11])))
    Rk = M3 @ R @ M3
    sx, sy, sz = b["scale"]
    Sk = Matrix.Diagonal((sx, sz, sy)).to_4x4()
    world = Matrix.Translation(to_b(c[:3])) @ Rk.to_4x4()
    n = 0
    for pname, p in sorted(v["parts"].items()):
        s = rbxmat.surface(p["role"], p["material"], v["arch"])
        if s is None or pname not in meshes:
            continue
        role = p["role"]
        if b.get("lite") and role not in CORE:
            continue
        if role == "WindowsLit":
            if not night or not b.get("lit"):
                continue
            s = dict(s, color=[int(x) for x in b["litColor"]])
        if role == "Neon" and night and s.get("night"):
            s = dict(s, material="Neon", color=s["night"].get("color") or s["color"])
        if role == "Walls" and b.get("wall"):
            w = b["wall"]
            s = dict(s, material=w["mat"], variant=w.get("var"), color=w["rgb"])
        if role == "Glass" and b.get("glass") and s.get("variant") == "HC_WindowGlass":
            s = dict(s, color=b["glass"])
        me = meshes[pname].copy()
        me.transform(Sk)
        ob = bpy.data.objects.new(pname, me)
        ob.matrix_world = world
        me.materials.clear()
        me.materials.append(material(s, night and role in ("WindowsLit", "Neon")))
        col.objects.link(ob)
        n += 1
    if b.get("foundation", 0) > 0:
        bb = v["body"]
        lo = Vector((bb["min"][0] * sx, -b["foundation"], bb["min"][2] * sz))
        hi = Vector((bb["max"][0] * sx, 0.0, bb["max"][2] * sz))
        box(col, world, lo, hi, {"material": "Concrete", "color": [186, 183, 176]})
    return n


def box(col, world, lo, hi, s, name="Box"):
    """Axis box given in Roblox model space (lo/hi), placed with `world` (Blender)."""
    me = bpy.data.meshes.new(name)
    corners = [Vector((x, y, z)) for z in (lo.z, hi.z) for y in (lo.y, hi.y) for x in (lo.x, hi.x)]
    verts = [M3 @ q for q in corners]
    faces = [(0, 2, 3, 1), (4, 5, 7, 6), (0, 1, 5, 4), (2, 6, 7, 3), (0, 4, 6, 2), (1, 3, 7, 5)]
    me.from_pydata([tuple(v) for v in verts], [], faces)
    me.update()
    # outward normals
    import bmesh
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    ob.matrix_world = world
    me.materials.append(material(dict({"variant": None, "texture": None, "transparency": 0}, **s)))
    col.objects.link(ob)
    return ob


def place_massing(col, b, night):
    c = b["cframe"]
    R = Matrix(((c[3], c[4], c[5]), (c[6], c[7], c[8]), (c[9], c[10], c[11])))
    world = Matrix.Translation(to_b(c[:3])) @ (M3 @ R @ M3).to_4x4()
    w, h, d = b["size"]
    wall = b.get("wall") or {"mat": "Concrete", "rgb": [186, 183, 176]}
    if b["kind"] == "parkade":
        deck = 10.5
        n = max(2, int(h // deck))
        box(col, world, Vector((-w / 2 + 3, 0, -d / 2 + 3)), Vector((w / 2 - 3, n * deck, d / 2 - 3)),
            {"material": "SmoothPlastic", "color": [34, 36, 40]})
        for k in range(min(n, 6) + 1):
            t = 1.2 if k == 0 else 3.4
            y0 = k * deck + (0 if k == 0 else 0.0)
            box(col, world, Vector((-w / 2, y0, -d / 2)), Vector((w / 2, y0 + t, d / 2)),
                {"material": "Concrete", "color": [196, 192, 184]})
    else:
        box(col, world, Vector((-w / 2, 0, -d / 2)), Vector((w / 2, h, d / 2)),
            {"material": wall["mat"], "variant": wall.get("var"), "color": wall["rgb"]})
        box(col, world, Vector((-w / 2 - 0.3, h - 0.5, -d / 2 - 0.3)), Vector((w / 2 + 0.3, h + 0.7, d / 2 + 0.3)),
            {"material": "Concrete", "color": [196, 192, 184]})


# ---------------------------------------------------------------------------------------------------- context
def roads(col, data, center, radius):
    asphalt = material({"material": "Asphalt", "variant": None, "color": [104, 104, 107], "texture": None})
    walk = material({"material": "Pavement", "variant": None, "color": [200, 197, 188], "texture": None})
    paint = material({"material": "SmoothPlastic", "variant": None, "color": [236, 196, 70], "texture": None})
    cx, cz = center[0], center[2]
    lamps = []
    for e in data["roads"]:
        pts = e["points"]
        if not any((p[0] - cx) ** 2 + (p[2] - cz) ** 2 < (radius + 300) ** 2 for p in pts):
            continue
        hw = e["width"] / 2
        sw = e.get("sidewalk") or 0
        for a, mat, o0, o1, dy in ((0, asphalt, -hw, hw, 0.0), (1, walk, hw, hw + sw, 0.6), (2, walk, -hw - sw, -hw, 0.6),
                                         (3, paint, -0.7, 0.7, 0.03)):
            if a in (1, 2) and sw <= 0:
                continue
            if a == 3 and e["class"] not in ("boulevard", "avenue"):
                continue
            verts, faces = [], []
            for i, p in enumerate(pts):
                q = pts[min(i + 1, len(pts) - 1)]
                r = pts[max(i - 1, 0)]
                tx, tz = q[0] - r[0], q[2] - r[2]
                L = math.hypot(tx, tz) or 1.0
                nx, nz = -tz / L, tx / L
                for off in (o0, o1):
                    verts.append(tuple(to_b((p[0] + nx * off, p[1] + dy + 0.02 * a, p[2] + nz * off))))
                if i > 0:
                    k = 2 * i
                    faces.append((k - 2, k - 1, k + 1, k))
            me = bpy.data.meshes.new("Road")
            me.from_pydata(verts, [], faces)
            me.update()
            for poly in me.polygons:   # face up
                if poly.normal.z < 0:
                    poly.flip()
            me.materials.append(mat)
            ob = bpy.data.objects.new("Road", me)
            col.objects.link(ob)
        if e["class"] in ("boulevard", "avenue", "street") and not e.get("elevated") and not e.get("bridge"):
            acc = 0.0
            for i in range(1, len(pts)):
                p, q = pts[i - 1], pts[i]
                seg = math.hypot(q[0] - p[0], q[2] - p[2])
                acc += seg
                if acc > 110 and seg > 1:
                    acc = 0.0
                    tx, tz = (q[0] - p[0]) / seg, (q[2] - p[2]) / seg
                    nx, nz = -tz, tx
                    for side in (1, -1):
                        off = hw + max(1.5, sw * 0.35)
                        lx, lz = q[0] + nx * off * side, q[2] + nz * off * side
                        if (lx - cx) ** 2 + (lz - cz) ** 2 < radius ** 2:
                            lamps.append((lx, q[1] + 0.6, lz, -nx * side, -nz * side))
    return lamps


def ground(col, center, radius, y, kind):
    s = {"grass": {"material": "Grass", "color": [146, 161, 109]}, "concrete": {"material": "Pavement", "color": [196, 192, 186]}}[kind]
    mat = material(dict({"variant": None, "texture": None}, **s))
    c = to_b(center)
    me = bpy.data.meshes.new("Ground")
    r = radius + 500
    me.from_pydata([(c.x - r, c.y - r, y), (c.x + r, c.y - r, y), (c.x + r, c.y + r, y), (c.x - r, c.y + r, y)], [], [(0, 1, 2, 3)])
    me.materials.append(mat)
    ob = bpy.data.objects.new("Ground", me)
    col.objects.link(ob)


def densest(data, district, radius=260):
    pts = []
    for b in data["buildings"]:
        p = data["parcels"][b["parcel"] - 1]
        if p["district"] == district and b["kind"] == "template":
            pts.append(b["cframe"][:3])
    best, bc = None, -1
    for q in pts[:: max(1, len(pts) // 300)]:
        n = sum(1 for o in pts if (o[0] - q[0]) ** 2 + (o[2] - q[2]) ** 2 < radius * radius)
        if n > bc:
            best, bc = q, n
    return best


def render_scene(name, data, cat, samples, out_dir):
    sc = SCENES[name]
    night = sc.get("night", False)
    S.reset()
    if night:
        S.night(strength=0.05)
    else:
        S.world("sky_late_afternoon", sun_az=sc.get("sun", -35.0))
    col = bpy.context.scene.collection
    center = sc.get("center") or densest(data, sc["district"])
    radius = sc["radius"]
    ys = []
    nb = nparts = 0
    for b in data["buildings"]:
        c = b["cframe"]
        if (c[0] - center[0]) ** 2 + (c[2] - center[2]) ** 2 > radius ** 2:
            continue
        ys.append(c[1])
        if b["kind"] == "template":
            nparts += place_building(col, b, cat, night)
        else:
            place_massing(col, b, night)
        nb += 1
    gy = (sorted(ys)[len(ys) // 2] if ys else center[1]) - 0.4
    lamps = roads(col, data, center, radius)
    district = sc.get("district") or "downtown"
    ground(col, center, radius, gy, "grass" if district in ("southgate", "hills") else "concrete")
    for k, (x, y, z, fx, fz) in enumerate(lamps[:220]):
        bp = to_b((x, y, z))
        lc = bpy.data.collections.new("Lamp%d" % k)
        col.children.link(lc)
        S.street_lamp(lc, 0.0, 0.0, facing=(-fx, fz), night=night)
        for ob in lc.objects:
            ob.location = ob.location + Vector((bp.x, bp.y, bp.z))
    if district == "beach":
        for k, (x, y, z, fx, fz) in enumerate(lamps[:120:2]):
            bp = to_b((x + fx * 4, y, z + fz * 4))
            pc = bpy.data.collections.new("Palm%d" % k)
            col.children.link(pc)
            S.palm(pc, 0.0, 0.0, h=44 + (k % 5) * 4, seed=k)
            for ob in pc.objects:
                ob.location = ob.location + Vector((bp.x, bp.y, bp.z))
    if "look" in sc:
        cam = to_b(tuple(center[i] + sc["cam"][i] for i in range(3)))
        tgt = to_b(sc["look"])
    else:
        cam = to_b((center[0] + sc["cam"][0], gy + sc["cam"][1], center[2] + sc["cam"][2]))
        tgt = to_b((center[0] + sc["look_d"][0], gy + sc["look_d"][1], center[2] + sc["look_d"][2]))
    S.camera(tuple(cam), tuple(tgt), sc.get("lens", 28))
    S.haze(night=night, amount=0.35 if not night else 0.2)
    path = os.path.join(out_dir, name + ".png")
    S.render(path, samples=samples)
    print("rendered", path, nb, "buildings", nparts, "parts", "centre", [round(x) for x in center])
    return path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scene", nargs="+", default=["downtown", "midtown", "beach", "suburbs", "downtown_night"])
    ap.add_argument("--placements", default=os.path.join(HERE, "_cache", "placements.json"))
    ap.add_argument("--samples", type=int, default=40)
    ap.add_argument("--out", default=OUT)
    a = ap.parse_args()
    data = json.load(open(a.placements))
    cat = json.load(open(CATALOG))["variants"]
    os.makedirs(a.out, exist_ok=True)
    for name in a.scene:
        _mats.clear()
        _tpl.clear()
        render_scene(name, data, cat, a.samples, a.out)


if __name__ == "__main__":
    main()
