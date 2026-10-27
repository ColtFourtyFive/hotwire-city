"""Building kit role/material -> Roblox surface (the runtime contract, one source for gen_config.py and the Blender
evidence renders).

Decision (docs/v2/early/buildings/README.md, evidence: probe upload 95401734300558): building MeshParts are coloured
at runtime, not by the uploaded file.
  * The Open Cloud GLB importer drops glTF colour factors (every MeshPart arrives grey Plastic), turns a lone base-colour
    image into MeshPart.TextureID (a new Image asset per file) and a full PBR set into a SurfaceAppearance (4 new
    Image assets per building). SurfaceAppearance maps are not scriptable, and per-building embedded textures would
    mean ~5 uploads per variant and no reuse.
  * So tiling surfaces use Enum.Material + the place's global PBR MaterialVariants (Config/Look: Brick -> HC_BrickRed,
    Plaster -> HC_Stucco, Concrete -> HC_Concrete, ...; per-part HC_BrickTan / HC_ConcreteModern / HC_CorrugatedMetal),
    tinted by BasePart.Color (Look colour contract). MaterialVariants are projected per face at StudsPerTile on
    MeshParts (UVs are not used), so texel density is identical on every building and survives scaling.
  * Atlas surfaces (window interiors, shop signs, brands, awnings) use MeshPart.TextureID (scriptable at runtime) with
    four shared uploaded Images; the GLB keeps their atlas UVs.
Colours are sRGB 0..255 (Color3.fromRGB).
"""
import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
_MATS = None


def look():
    """HC_ variants from assets/materials/materials.json: name -> {base, color, studsPerTile, override, files}."""
    global _MATS
    if _MATS is None:
        data = json.load(open(os.path.join(ROOT, "assets", "materials", "materials.json")))
        _MATS = {m["variant"]: m for m in data["materials"]}
    return _MATS


def overrides():
    return {m["base"]: v for v, m in look().items() if m.get("override")}


def _mul(c, t, k=1.0):
    return [max(0, min(255, int(round(c[i] * t[i] * k)))) for i in range(3)]


def _rgb(t, k=1.0):
    return [max(0, min(255, int(round(255 * t[i] * k)))) for i in range(3)]


# kit texture set -> (Enum.Material, per-part MaterialVariant or None = the global override, base colour, tint gain)
TEXSET = {
    "brick_red": ("Brick", None, "HC_BrickRed", 1.0),
    "brick_tan": ("Brick", "HC_BrickTan", "HC_BrickTan", 1.0),
    "brick_painted": ("Brick", "HC_BrickTan", (236, 230, 218), 1.0),
    "stucco": ("Plaster", None, "HC_Stucco", 1.0),
    "plaster": ("Plaster", None, "HC_Stucco", 1.0),
    "concrete": ("Concrete", None, "HC_Concrete", 1.0),
    "concrete_board": ("Concrete", None, "HC_Concrete", 1.0),
    "curb": ("Concrete", None, "HC_Concrete", 1.0),
    "cmu": ("Concrete", None, "HC_Concrete", 1.0),
    "precast": ("Concrete", "HC_ConcreteModern", "HC_ConcreteModern", 1.0),
    "facade_tiles": ("Concrete", "HC_ConcreteModern", "HC_ConcreteModern", 1.0),
    "granite": ("Marble", None, (178, 170, 162), 1.0),
    "marble": ("Marble", None, (240, 236, 230), 1.0),
    "terrazzo": ("Marble", None, "HC_Terrazzo", 1.0),
    "roof_gravel": ("Pebble", None, "HC_GravelRoof", 1.0),
    "roof_tar": ("Concrete", None, (92, 92, 94), 1.0),
    "roof_clay": ("ClayRoofTiles", None, "HC_RoofTiles", 1.0),
    "roof_shingle": ("Asphalt", None, (118, 110, 104), 1.0),
    "metal": ("Metal", None, (200, 202, 205), 1.0),
    "shutter": ("Metal", "HC_CorrugatedMetal", "HC_CorrugatedMetal", 1.0),
    "corrugated": ("Metal", "HC_CorrugatedMetal", "HC_CorrugatedMetal", 1.0),
    "metal_siding": ("Metal", "HC_CorrugatedMetal", "HC_CorrugatedMetal", 1.0),
    "wood_fence": ("WoodPlanks", None, "HC_WoodPlanks", 1.1),
    "wood_slats": ("WoodPlanks", None, "HC_WoodPlanks", 1.15),
    "pavers": ("Pavement", None, "HC_Sidewalk", 1.0),
    "sidewalk": ("Pavement", None, "HC_Sidewalk", 1.0),
    "asphalt": ("Asphalt", None, "HC_Asphalt", 1.0),
    "grass": ("Grass", None, "HC_Grass", None),
    "sand": ("Sand", None, "HC_Sand", None),
}
ATLAS_KEYS = {"windows_day", "signs", "brands", "awnings"}
# glass: towers / offices read as mirror-coated curtain wall (HC_WindowGlass); everything else shows the interior atlas
MIRROR_ARCHS = {"tower"}
SOLID_ROLES = {"Walls", "Walls2", "Walls3", "Trim", "Glass", "Roof", "Roof2", "Doors", "Clear"}
SHADOW_ROLES = {"Walls", "Walls2", "Walls3", "Trim", "Roof", "Roof2", "Details", "Accent", "Awning", "Doors", "Clear"}
WALL_ROLES = {"Walls"}   # re-skinnable from the district palette


def base_colour(spec):
    if isinstance(spec, str):
        return look()[spec]["color"]
    return list(spec)


def surface(role, mat, arch):
    """-> dict(material, variant, color, texture, transparency, reflectance, night) for one kit part."""
    kind = mat.get("kind", "color")
    out = {"material": "SmoothPlastic", "variant": None, "color": [163, 162, 165], "texture": None,
           "transparency": 0.0, "reflectance": 0.0, "night": None}
    if kind == "texture":
        enum, variant, base, gain = TEXSET[mat["set"]]
        tint = mat.get("tint") or [1, 1, 1]
        out.update(material=enum, variant=variant)
        out["color"] = list(base_colour(base)) if gain is None else _mul(base_colour(base), tint, gain)
    elif kind == "color":
        c = mat.get("color", [0.6, 0.6, 0.6])
        out["material"] = "Metal" if mat.get("metallic", 0) >= 0.5 else "SmoothPlastic"
        out["color"] = _rgb(c)
    elif kind == "glass":
        if arch in MIRROR_ARCHS:
            tint = mat.get("tint")
            out.update(material="SmoothPlastic", variant="HC_WindowGlass",
                       color=_rgb(tint, 0.62) if tint else list(look()["HC_WindowGlass"]["color"]))
        else:
            out.update(material="SmoothPlastic", texture="windows_day", reflectance=0.12, color=[255, 255, 255])
    elif kind == "atlas":
        key = os.path.splitext(mat.get("file", ""))[0]
        out.update(texture=key if key in ATLAS_KEYS else None, color=[255, 255, 255])
    elif kind == "clear":
        out.update(material="Glass", color=[205, 222, 228], transparency=0.6)
    elif kind == "water":
        out.update(material="Glass", color=_rgb(mat.get("color", [0.05, 0.42, 0.52])), transparency=0.25,
                   reflectance=0.2)
    elif kind == "neon":
        day = mat.get("day_color") or mat.get("color")
        out.update(color=_rgb(day), night={"material": "Neon", "color": _rgb(mat.get("color"))})
    elif kind == "lit":
        out.update(material="Neon", color=[255, 196, 136], transparency=1.0, night={"material": "Neon"})
    elif kind == "decal":
        return None   # grime decals are not shipped (TextureID alpha is a hard cut-out)
    return out
