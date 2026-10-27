"""Cycles bakes from the original high-res role mesh onto the decimated low mesh (selected-to-active):
base colour, roughness, metallic, emission (all through an Emission proxy so metallic paint doesn't bake black),
tangent-space normal, and ambient occlusion on the low mesh.  Writes PNGs <= 1024 px."""
from __future__ import annotations

import os

import bpy
import numpy as np

from . import matinfo
from .util import log, select_only


def _cycles(samples=4):
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = samples
    sc.cycles.use_denoising = False
    sc.render.threads_mode = "AUTO"
    return sc


def new_image(name, size, data=False, alpha=False, fill=(0.5, 0.5, 0.5, 1.0)):
    img = bpy.data.images.get(name)
    if img is not None:
        bpy.data.images.remove(img)
    img = bpy.data.images.new(name, size, size, alpha=alpha, float_buffer=False)
    img.colorspace_settings.name = "Non-Color" if data else "sRGB"
    px = np.tile(np.array(fill, dtype=np.float32), size * size)
    img.pixels.foreach_set(px)
    return img


def _target_material(lo, img):
    """Give the low object a single material whose active node is an image texture with `img`."""
    mat = bpy.data.materials.new(lo.name + "_bake")
    mat.use_nodes = True
    nt = mat.node_tree
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = img
    uv = nt.nodes.new("ShaderNodeUVMap")
    uv.uv_map = "atlas"
    nt.links.new(uv.outputs["UV"], tex.inputs["Vector"])
    nt.nodes.active = tex
    lo.data.materials.clear()
    lo.data.materials.append(mat)
    return mat


def _proxy_materials(hi_objs, channel):
    """Swap every material on the high objects for an Emission proxy of `channel`
    ('base', 'rough', 'metal', 'emit', 'alpha').  Returns restore list."""
    restore = []
    cache = {}
    for o in hi_objs:
        for si, slot in enumerate(o.material_slots):
            m = slot.material
            restore.append((o, si, m))
            key = (m.name if m else None, channel)
            if key not in cache:
                cache[key] = _make_proxy(m, channel)
            slot.material = cache[key]
    return restore


def _restore(restore):
    for o, si, m in restore:
        o.material_slots[si].material = m


def _make_proxy(m, channel):
    if m is None:
        p = bpy.data.materials.new("proxy_none")
        p.use_nodes = True
        b = p.node_tree.nodes.get("Principled BSDF")
        if b:
            b.inputs["Base Color"].default_value = (0.5, 0.5, 0.5, 1)
        m = p
    p = m.copy()
    p.name = f"proxy_{channel}_{m.name}"
    nt = p.node_tree
    if nt is None:
        p.use_nodes = True
        nt = p.node_tree
    b = matinfo.principled(p)
    out = None
    for n in nt.nodes:
        if n.type == "OUTPUT_MATERIAL":
            out = n
            n.is_active_output = False
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    out.is_active_output = True
    out.target = "ALL"
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Strength"].default_value = 1.0
    nt.links.new(em.outputs["Emission"], out.inputs["Surface"])
    if b is None:
        col = tuple(m.diffuse_color[:3]) + (1,)
        val = {"base": col, "rough": (0.5,) * 3 + (1,), "metal": (0,) * 3 + (1,), "emit": (0, 0, 0, 1),
               "alpha": (1, 1, 1, 1)}[channel]
        em.inputs["Color"].default_value = val
        return p
    sock = {"base": "Base Color", "rough": "Roughness", "metal": "Metallic", "emit": "Emission Color",
            "alpha": "Alpha"}[channel]
    src = b.inputs[sock]
    if src.is_linked:
        nt.links.new(src.links[0].from_socket, em.inputs["Color"])
    else:
        v = src.default_value
        try:
            v = tuple(v)[:3] + (1,)
        except TypeError:
            v = (v, v, v, 1)
        em.inputs["Color"].default_value = v
    if channel == "emit":
        em.inputs["Strength"].default_value = min(float(b.inputs["Emission Strength"].default_value), 1.0) \
            if not b.inputs["Emission Strength"].is_linked else 1.0
    return p


def bake_selected_to_active(lo, hi_objs, img, btype, extrusion, ray, samples=4, margin=4):
    _cycles(samples)
    _target_material(lo, img)
    select_only(list(hi_objs) + [lo], lo)
    # Rays leave the low mesh along its *shading* normals.  On sliver triangles of old game meshes the smoothed
    # normals swing far from the face and rays miss (black texels), so colour-type bakes use flat shading;
    # the normal map needs the real (smooth) shading normals.
    flat = btype != "NORMAL"
    me = lo.data
    smooth = np.empty(len(me.polygons), dtype=bool)
    me.polygons.foreach_get("use_smooth", smooth)
    if flat:
        me.polygons.foreach_set("use_smooth", np.zeros(len(me.polygons), dtype=bool))
        me.update()
    try:
        bpy.ops.object.bake(type=btype, use_selected_to_active=True, cage_extrusion=extrusion,
                            max_ray_distance=ray, margin=margin, margin_type="EXTEND", use_clear=True,
                            target="IMAGE_TEXTURES", normal_space="TANGENT")
    finally:
        if flat:
            me.polygons.foreach_set("use_smooth", smooth)
            me.update()


def bake_channels(lo, hi_objs, size, outdir, prefix, channels, extrusion, ray):
    """channels subset of: base, rough, metal, emit, normal. Returns {channel: path}."""
    res = {}
    for ch in channels:
        data = ch in ("rough", "metal", "normal")
        fill = {"base": (0.5, 0.5, 0.5, 1), "rough": (0.5, 0.5, 0.5, 1), "metal": (0, 0, 0, 1),
                "emit": (0, 0, 0, 1), "normal": (0.5, 0.5, 1.0, 1)}[ch]
        img = new_image(f"{prefix}_{ch}", size, data=data, fill=fill)
        if ch == "normal":
            bake_selected_to_active(lo, hi_objs, img, "NORMAL", extrusion, ray, samples=4)
        else:
            restore = _proxy_materials(hi_objs, ch)
            try:
                bake_selected_to_active(lo, hi_objs, img, "EMIT", extrusion, ray, samples=2)
            finally:
                _restore(restore)
        path = os.path.join(outdir, f"{prefix}_{ch}.png")
        save_png(img, path)
        res[ch] = path
        log(f"baked {prefix}_{ch} ({size}px)")
    return res


def bake_ao(lo, size, outdir, prefix, distance, hide=()):
    _cycles(16)
    for h in hide:
        h.hide_render = True
    img = new_image(f"{prefix}_ao", size, data=True, fill=(1, 1, 1, 1))
    _target_material(lo, img)
    bpy.context.scene.world = bpy.context.scene.world or bpy.data.worlds.new("w")
    bpy.context.scene.world.light_settings.distance = distance
    select_only([lo], lo)
    bpy.ops.object.bake(type="AO", use_selected_to_active=False, margin=4, margin_type="EXTEND", use_clear=True,
                        target="IMAGE_TEXTURES")
    for h in hide:
        h.hide_render = False
    path = os.path.join(outdir, f"{prefix}_ao.png")
    save_png(img, path)
    log(f"baked {prefix}_ao")
    return path


def save_png(img, path, rgba=False):
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    return path


def load_np(path):
    from PIL import Image
    return np.asarray(Image.open(path).convert("RGBA")).astype(np.float32) / 255.0


def save_np(arr, path):
    from PIL import Image
    a = (np.clip(arr, 0, 1) * 255 + 0.5).astype(np.uint8)
    mode = "RGBA" if a.shape[2] == 4 else "RGB"
    Image.fromarray(a, mode).save(path)
    return path


def multiply_ao(color_path, ao_path, strength=0.7):
    c = load_np(color_path)
    ao = load_np(ao_path)[..., :1]
    c[..., :3] *= (1 - strength) + strength * ao
    save_np(c, color_path)


def _hue(rgb, mx, mn):
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    dlt = np.maximum(mx - mn, 1e-6)
    h = np.where(mx == r, ((g - b) / dlt) % 6, np.where(mx == g, (b - r) / dlt + 2, (r - g) / dlt + 4))
    return (h * 60.0) % 360.0


def tint_mask(color_path, out_tint, out_overlay, paint_hint=None, uv_mask=None):
    """Build the two recolour textures for a body whose paint lives inside a texture:
      * out_tint:    SurfaceAppearance AlphaMode=TintMask: alpha=1 on paint, paint RGB -> neutral shading
      * out_overlay: MeshPart.TextureID route: alpha=0 on paint so MeshPart.Color shows through
    Returns (paint_rgb_srgb, coverage)."""
    c = load_np(color_path)
    rgb = c[..., :3]
    valid = np.ones(rgb.shape[:2], bool) if uv_mask is None else uv_mask
    px = rgb[valid]
    # dominant colour: most populated cell of a coarse 3D histogram (paint is the biggest colour on a car)
    q = np.clip((px * 12).astype(int), 0, 11)
    key = q[:, 0] * 144 + q[:, 1] * 12 + q[:, 2]
    cnt = np.bincount(key, minlength=12 ** 3)
    # ignore near-black/near-grey cells unless they win by a landslide (black/grey/white cars)
    cells = np.arange(12 ** 3)
    cr, cg, cb = cells // 144, (cells // 12) % 12, cells % 12
    cmx = np.maximum(np.maximum(cr, cg), cb)
    cmn = np.minimum(np.minimum(cr, cg), cb)
    chroma = (cmx - cmn) / 11.0
    score = cnt * np.where(chroma > 0.15, 1.6, 1.0)
    if paint_hint is not None:
        hk = np.clip((np.array(paint_hint) * 12).astype(int), 0, 11)
        best = hk[0] * 144 + hk[1] * 12 + hk[2]
    else:
        best = int(score.argmax())
    sel = key == best
    if paint_hint is not None and sel.sum() < 50:
        paint = np.array(paint_hint, dtype=np.float32)
    else:
        paint = np.median(px[sel], axis=0) if sel.any() else px.mean(0)
    # match: chroma-normalised distance + loose brightness band (keeps baked shading variations)
    lum = rgb.mean(-1, keepdims=True) + 1e-4
    plum = paint.mean() + 1e-4
    chrom = rgb / lum
    pch = paint / plum
    d = np.linalg.norm(chrom - pch, axis=-1)
    bright = lum[..., 0] / plum
    pchroma = paint.max() - paint.min()
    if pchroma > 0.12:
        # chromatic paint: hue within +-24 deg, enough saturation, broad value band (keeps worn/faded/lit panels)
        mx = rgb.max(-1)
        mn = rgb.min(-1)
        sat = (mx - mn) / np.maximum(mx, 1e-4)
        hue = _hue(rgb, mx, mn)
        pmx, pmn = float(paint.max()), float(paint.min())
        psat = (pmx - pmn) / max(pmx, 1e-4)
        phue = float(_hue(paint[None, None, :], np.array([[pmx]]), np.array([[pmn]]))[0, 0])
        dh = np.abs((hue - phue + 180.0) % 360.0 - 180.0)
        m = (dh < 24.0) & (sat > 0.4 * psat) & (mx > 0.25 * pmx) & (mx < 2.6 * pmx + 0.05)
        m |= (d < 0.35) & (bright > 0.35) & (bright < 1.8)
    else:  # achromatic paint: rely on brightness band + low chroma
        cchroma = rgb.max(-1) - rgb.min(-1)
        m = (cchroma < 0.10) & (bright > 0.7) & (bright < 1.35)
    m &= valid
    mf = m.astype(np.float32)
    # soften 1px
    k = mf.copy()
    k[1:-1, 1:-1] = (mf[1:-1, 1:-1] * 4 + mf[:-2, 1:-1] + mf[2:, 1:-1] + mf[1:-1, :-2] + mf[1:-1, 2:]) / 8
    # neutral shading kept from the texture; for near-black paint there is no shading to keep -> flat
    shade = np.clip(lum[..., 0] / plum, 0, 1.0) if plum > 0.08 else np.ones_like(lum[..., 0])
    tint = c.copy()
    for ch in range(3):
        tint[..., ch] = np.where(m, shade, rgb[..., ch])
    tint[..., 3] = k
    save_np(tint, out_tint)
    over = c.copy()
    over[..., 3] = 1 - k
    save_np(over, out_overlay)
    cov = float(m[valid].mean()) if valid.any() else 0.0
    log(f"tint mask: paint={np.round(paint, 3)} coverage={cov:.2f}")
    return [float(x) for x in paint], cov
