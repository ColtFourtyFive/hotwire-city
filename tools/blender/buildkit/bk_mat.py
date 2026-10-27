"""Materials for the building kit. Every material uses only the channels a Roblox SurfaceAppearance has
(ColorMap, NormalMap, RoughnessMap, MetalnessMap) + an optional tint (SurfaceAppearance.Color / TintMask),
so the Cycles previews do not promise shading Roblox cannot show. Exception: WindowsLit uses emission
(Roblox: Material=Neon on that MeshPart, shown only at night)."""
import os
import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
TEX = os.path.join(HERE, "_cache", "tex")
GEN = os.path.join(HERE, "out", "textures")

# key -> (folder or generated file, default roughness multiplier, normal strength)
TEXSETS = {
    "brick_red": ("brick_red", 1.0, 1.0), "brick_tan": ("brick_tan", 1.0, 1.0),
    "brick_painted": ("brick_painted", 1.0, 1.0), "stucco": ("stucco", 1.0, 0.8), "plaster": ("plaster", 1.0, 0.6),
    "concrete": ("concrete", 1.0, 0.8), "concrete_board": ("concrete_board", 1.0, 0.8), "granite": ("granite", 0.8, 0.6),
    "facade_tiles": ("facade_tiles", 1.0, 0.7), "roof_gravel": ("roof_gravel", 1.0, 1.0), "roof_tar": ("roof_tar", 1.0, 1.0),
    "metal": ("metal", 1.0, 0.7), "shutter": ("shutter", 1.0, 1.0), "asphalt": ("asphalt", 1.0, 1.0),
    "sidewalk": ("sidewalk", 1.0, 1.0), "curb": ("curb", 1.0, 1.0), "terrazzo": ("terrazzo", 1.0, 0.5),
    "corrugated": ("corrugated", 1.0, 1.0), "metal_siding": ("metal_siding", 1.0, 1.0), "roof_clay": ("roof_clay", 1.0, 1.0),
    "roof_shingle": ("roof_shingle", 1.0, 1.0), "cmu": ("cmu", 1.0, 0.8), "wood_fence": ("wood_fence", 1.0, 0.8),
    "wood_slats": ("wood_slats", 1.0, 0.8), "marble": ("marble", 0.7, 0.4), "pavers": ("pavers", 1.0, 0.8),
    "precast": ("precast", 1.0, 0.6), "grass": ("grass", 1.0, 1.0),
}
TINTABLE = {"stucco", "brick_painted", "plaster", "metal_siding", "cmu", "precast"}   # grey <key>_tint.png ColorMap

_cache = {}


def img(path, data=False):
    im = bpy.data.images.load(path, check_existing=True)
    if data:
        im.colorspace_settings.name = "Non-Color"
    return im


def _new(name):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    nt.links.new(bsdf.outputs[0], out.inputs[0])
    return m, nt, bsdf


def textured(name, key, tint=(1, 1, 1), rough=1.0, normal=None, metallic=None):
    """Tiling PBR material. tint multiplies the colour map (Roblox: SurfaceAppearance.Color)."""
    folder, rmul, nstr = TEXSETS[key]
    m, nt, bsdf = _new(name)
    d = os.path.join(TEX, folder)
    diff_path = os.path.join(GEN, f"{key}_tint.png") if key in TINTABLE else os.path.join(d, "diff.jpg")
    t_diff = nt.nodes.new("ShaderNodeTexImage"); t_diff.image = img(diff_path)
    mix = nt.nodes.new("ShaderNodeMix"); mix.data_type = "RGBA"; mix.blend_type = "MULTIPLY"
    mix.inputs[0].default_value = 1.0
    nt.links.new(t_diff.outputs[0], mix.inputs[6])
    mix.inputs[7].default_value = (*tint, 1.0)
    nt.links.new(mix.outputs[2], bsdf.inputs["Base Color"])
    t_r = nt.nodes.new("ShaderNodeTexImage"); t_r.image = img(os.path.join(d, "rough.jpg"), True)
    mr = nt.nodes.new("ShaderNodeMath"); mr.operation = "MULTIPLY"; mr.inputs[1].default_value = rmul * rough
    nt.links.new(t_r.outputs[0], mr.inputs[0]); nt.links.new(mr.outputs[0], bsdf.inputs["Roughness"])
    t_n = nt.nodes.new("ShaderNodeTexImage"); t_n.image = img(os.path.join(d, "nor.jpg"), True)
    nm = nt.nodes.new("ShaderNodeNormalMap"); nm.inputs[0].default_value = normal if normal is not None else nstr
    nt.links.new(t_n.outputs[0], nm.inputs[1]); nt.links.new(nm.outputs[0], bsdf.inputs["Normal"])
    mp = os.path.join(d, "metal.jpg")
    if metallic is not None:
        bsdf.inputs["Metallic"].default_value = metallic
    elif os.path.exists(mp):
        t_m = nt.nodes.new("ShaderNodeTexImage"); t_m.image = img(mp, True)
        nt.links.new(t_m.outputs[0], bsdf.inputs["Metallic"])
    m["roblox"] = {"kind": "texture", "set": key, "tint": list(tint)}
    return m


def color(name, rgb, rough=0.45, metallic=0.0):
    """Untextured: maps to a MeshPart with plain Color + Material (recolourable at runtime)."""
    m, nt, bsdf = _new(name)
    bsdf.inputs["Base Color"].default_value = (*rgb, 1)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metallic
    m["roblox"] = {"kind": "color", "color": list(rgb), "metallic": metallic, "roughness": rough}
    return m


def atlas(name, file, rough=0.5, metallic=0.0, tint=(1, 1, 1), normal_flat=True, emit=0.0):
    """Unique-UV atlas material (signs, awnings). emit>0: backlit at night (preview only)."""
    m, nt, bsdf = _new(name)
    t = nt.nodes.new("ShaderNodeTexImage"); t.image = img(os.path.join(GEN, file))
    t.interpolation = "Cubic"
    if emit > 0:
        nt.links.new(t.outputs[0], bsdf.inputs["Emission Color"])
        bsdf.inputs["Emission Strength"].default_value = emit
    mix = nt.nodes.new("ShaderNodeMix"); mix.data_type = "RGBA"; mix.blend_type = "MULTIPLY"
    mix.inputs[0].default_value = 1.0
    nt.links.new(t.outputs[0], mix.inputs[6]); mix.inputs[7].default_value = (*tint, 1)
    nt.links.new(mix.outputs[2], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metallic
    m["roblox"] = {"kind": "atlas", "file": file, "roughness": rough, "metallic": metallic}
    return m


def glass(name, tint=(1, 1, 1), dim=0.55, rough=0.05, metallic=0.0, spec=0.6):
    """Window glass: ColorMap = interior atlas * tint, low roughness, optional metalness for mirror glass."""
    m, nt, bsdf = _new(name)
    t = nt.nodes.new("ShaderNodeTexImage"); t.image = img(os.path.join(GEN, "windows_day.png"))
    mix = nt.nodes.new("ShaderNodeMix"); mix.data_type = "RGBA"; mix.blend_type = "MULTIPLY"
    mix.inputs[0].default_value = 1.0
    nt.links.new(t.outputs[0], mix.inputs[6]); mix.inputs[7].default_value = (tint[0] * dim, tint[1] * dim, tint[2] * dim, 1)
    nt.links.new(mix.outputs[2], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Specular IOR Level"].default_value = spec
    bsdf.inputs["IOR"].default_value = 1.52
    m["roblox"] = {"kind": "glass", "file": "windows_day.png", "tint": list(tint), "roughness": rough, "metallic": metallic}
    return m


def clear(name, tint=(0.85, 0.93, 0.94), alpha=0.35):
    """See-through glass (balustrades, bus shelters). Roblox: Material=Glass, Transparency ~0.6, Color=tint."""
    m, nt, bsdf = _new(name)
    bsdf.inputs["Base Color"].default_value = (*tint, 1)
    bsdf.inputs["Roughness"].default_value = 0.03
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Alpha"].default_value = alpha
    bsdf.inputs["Specular IOR Level"].default_value = 0.8
    try:
        m.surface_render_method = "BLENDED"
    except Exception:
        pass
    m["roblox"] = {"kind": "clear", "color": list(tint), "transparency": round(1 - alpha, 2), "material": "Glass"}
    return m


def lit(name, strength=4.0):
    """Night windows (WindowsLit object). Hidden by day."""
    m, nt, bsdf = _new(name)
    t = nt.nodes.new("ShaderNodeTexImage"); t.image = img(os.path.join(GEN, "windows_lit.png"))
    nt.links.new(t.outputs[0], bsdf.inputs["Base Color"])
    nt.links.new(t.outputs[0], bsdf.inputs["Emission Color"])
    bsdf.inputs["Emission Strength"].default_value = strength
    bsdf.inputs["Roughness"].default_value = 0.1
    m["roblox"] = {"kind": "lit", "file": "windows_lit.png"}
    return m


def grime(name, file="grime.png", strength=1.0):
    """Alpha-blended dirt decals (Roblox: SurfaceAppearance AlphaMode=Transparency, CastShadow=false)."""
    m, nt, bsdf = _new(name)
    t = nt.nodes.new("ShaderNodeTexImage"); t.image = img(os.path.join(GEN, file))
    nt.links.new(t.outputs[0], bsdf.inputs["Base Color"])
    if strength != 1.0:
        mm = nt.nodes.new("ShaderNodeMath"); mm.operation = "MULTIPLY"; mm.inputs[1].default_value = strength
        nt.links.new(t.outputs[1], mm.inputs[0]); nt.links.new(mm.outputs[0], bsdf.inputs["Alpha"])
    else:
        nt.links.new(t.outputs[1], bsdf.inputs["Alpha"])
    bsdf.inputs["Roughness"].default_value = 0.9
    try:
        m.surface_render_method = "BLENDED"
    except Exception:
        pass
    m["roblox"] = {"kind": "decal", "file": file, "alpha": "Transparency"}
    return m


def neon(name, rgb, strength=6.0, day_rgb=None):
    """Night-glow tubes / light fixtures (Roblox: Material=Neon at night, SmoothPlastic+day colour by day)."""
    m, nt, bsdf = _new(name)
    day = day_rgb or tuple(min(1.0, c * 0.6 + 0.3) for c in rgb)
    bsdf.inputs["Base Color"].default_value = (*day, 1)
    bsdf.inputs["Emission Color"].default_value = (*rgb, 1)
    bsdf.inputs["Emission Strength"].default_value = strength
    bsdf.inputs["Roughness"].default_value = 0.3
    m["roblox"] = {"kind": "neon", "color": list(rgb), "day_color": list(day)}
    return m


def water(name, rgb=(0.05, 0.38, 0.45)):
    m, nt, bsdf = _new(name)
    bsdf.inputs["Base Color"].default_value = (*rgb, 1)
    bsdf.inputs["Roughness"].default_value = 0.02
    bsdf.inputs["Specular IOR Level"].default_value = 0.6
    bsdf.inputs["IOR"].default_value = 1.33
    m["roblox"] = {"kind": "water", "color": list(rgb), "transparency": 0.25, "material": "Glass"}
    return m


def paint(name, rgb, rough=0.6):
    """Road markings etc (scene only)."""
    return color(name, rgb, rough)
