"""Read the parameters that matter for classification out of arbitrary Blender materials
(Principled BSDF from glTF/FBX/OBJ importers, or bare viewport colours), incl. texture averages."""
from __future__ import annotations

import re

import bpy
import numpy as np

from .util import lin_to_srgb, norm_name, srgb_to_lin

GENERIC_MAT = re.compile(
    r"^(material|mat|default|standard|lambert|phong|blinn|initialshadinggroup|none|_|\d+_default|"
    r"material_?\d*|mat_?\d*|default_?material|wire_\w+|color_\w+|\d+)$")

_IMG_CACHE: dict = {}


def principled(mat):
    if not mat or not mat.use_nodes or not mat.node_tree:
        return None
    out = None
    for n in mat.node_tree.nodes:
        if n.type == "OUTPUT_MATERIAL" and n.is_active_output:
            out = n
    if out is not None and out.inputs["Surface"].is_linked:
        n = out.inputs["Surface"].links[0].from_node
        seen = 0
        while n is not None and n.type != "BSDF_PRINCIPLED" and seen < 6:
            seen += 1
            nxt = None
            for i in n.inputs:
                if i.is_linked and i.links[0].from_node.type in ("BSDF_PRINCIPLED", "MIX_SHADER", "ADD_SHADER"):
                    nxt = i.links[0].from_node
                    if nxt.type == "BSDF_PRINCIPLED":
                        break
            n = nxt
        if n is not None and n.type == "BSDF_PRINCIPLED":
            return n
    for n in mat.node_tree.nodes:
        if n.type == "BSDF_PRINCIPLED":
            return n
    return None


def upstream_image(sock, depth=0):
    """Find the first Image Texture node feeding `sock` (through mix/multiply/separate nodes)."""
    if sock is None or not sock.is_linked or depth > 6:
        return None
    n = sock.links[0].from_node
    if n.type == "TEX_IMAGE" and n.image is not None:
        return n
    for i in n.inputs:
        if i.is_linked:
            r = upstream_image(i, depth + 1)
            if r is not None:
                return r
    return None


def image_small(img, size=128):
    """Downscaled float RGBA copy of an image as numpy (H, W, 4), cached. Returns None if unreadable."""
    key = (img.name, size)
    if key in _IMG_CACHE:
        return _IMG_CACHE[key]
    arr = None
    try:
        if img.size[0] == 0 or img.size[1] == 0:
            img.reload()
        if img.size[0] > 0:
            cp = img.copy()
            cp.scale(size, size)
            px = np.empty(size * size * 4, dtype=np.float32)
            cp.pixels.foreach_get(px)
            arr = px.reshape(size, size, 4)
            bpy.data.images.remove(cp)
            # Image.pixels of 8-bit images are in the file's own (sRGB) encoding; float images are linear.
            if img.is_float:
                arr[..., :3] = lin_to_srgb(arr[..., :3]).astype(np.float32)
    except Exception:
        arr = None
    _IMG_CACHE[key] = arr
    return arr


def _val(bsdf, name, default):
    i = bsdf.inputs.get(name)
    if i is None:
        return default, None
    tex = upstream_image(i) if i.is_linked else None
    try:
        v = tuple(i.default_value)
    except TypeError:
        v = i.default_value
    return v, tex


def material_info(mat) -> dict:
    """Summary dict: name, generic, base (sRGB 0..1 rgb incl. texture average), base_tex (image name or None),
    metallic, roughness, transmission, alpha, emission (luminance), emission_rgb."""
    d = {"name": mat.name if mat else "None", "generic": True, "base": (0.8, 0.8, 0.8), "base_tex": None,
         "metallic": 0.0, "roughness": 0.5, "transmission": 0.0, "alpha": 1.0, "emission": 0.0,
         "emission_rgb": (0, 0, 0), "uv_map": None}
    if mat is None:
        return d
    base = re.sub(r"\.\d{3}$", "", mat.name)
    d["generic"] = bool(GENERIC_MAT.match(norm_name(base))) or len(norm_name(base)) <= 1
    b = principled(mat)
    if b is None:
        c = tuple(mat.diffuse_color)[:3]
        d["base"] = tuple(float(x) for x in lin_to_srgb(c))
        d["alpha"] = float(mat.diffuse_color[3])
        d["metallic"] = float(getattr(mat, "metallic", 0.0))
        d["roughness"] = float(getattr(mat, "roughness", 0.5))
        return d
    bc, btex = _val(b, "Base Color", (0.8, 0.8, 0.8, 1))
    base_rgb = np.array(bc[:3], dtype=np.float64)
    base_srgb = None
    if btex is not None:
        d["base_tex"] = btex.image.name
        arr = image_small(btex.image)
        if arr is not None:
            a = arr[..., 3:4]
            base_srgb = (arr[..., :3] * a).sum((0, 1)) / max(a.sum(), 1e-6)  # image_small() returns sRGB
        # try to find the UV map used
        vin = btex.inputs.get("Vector")
        if vin is not None and vin.is_linked and vin.links[0].from_node.type == "UVMAP":
            d["uv_map"] = vin.links[0].from_node.uv_map or None
    if base_srgb is not None:
        d["base"] = tuple(float(x) for x in base_srgb)
    else:
        d["base"] = tuple(float(x) for x in lin_to_srgb(base_rgb))
    met, mtex = _val(b, "Metallic", 0.0)
    rough, rtex = _val(b, "Roughness", 0.5)
    d["metallic"] = float(met) if mtex is None else 0.5
    d["roughness"] = float(rough) if rtex is None else 0.5
    tr, _ = _val(b, "Transmission Weight", 0.0)
    d["transmission"] = float(tr)
    al, atex = _val(b, "Alpha", 1.0)
    if atex is None:
        d["alpha"] = float(al)
    else:  # alpha from a texture (cut-outs vs. tinted glass): use the texture's mean coverage
        arr = image_small(atex.image, 64)
        if arr is None:
            d["alpha"] = 0.5
        elif atex.image.channels == 4 and float(arr[..., 3].min()) < 0.99:
            d["alpha"] = float(arr[..., 3].mean())
        else:
            d["alpha"] = float(arr[..., :3].mean())
    if atex is not None and getattr(mat, "surface_render_method", "") == "DITHERED" and mat.blend_method == "OPAQUE":
        d["alpha"] = 1.0
    ec, etex = _val(b, "Emission Color", (0, 0, 0, 1))
    es, _ = _val(b, "Emission Strength", 0.0)
    erg = np.array(ec[:3], dtype=np.float64)
    if etex is not None:
        arr = image_small(etex.image)
        erg = srgb_to_lin(arr[..., :3].mean((0, 1))) if arr is not None else np.array([0.2, 0.2, 0.2])
    elif b.inputs.get("Emission Color") is not None and b.inputs["Emission Color"].is_linked:
        erg = np.array([0.1, 0.1, 0.1])
    erg = erg * float(es)
    d["emission_rgb"] = tuple(float(x) for x in erg)
    d["emission"] = float(0.2126 * erg[0] + 0.7152 * erg[1] + 0.0722 * erg[2])
    return d
