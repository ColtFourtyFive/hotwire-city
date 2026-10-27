#!/usr/bin/env python3
"""Tiny numpy z-buffer triangle rasterizer for headless previews (no GPU / no extra deps).

Scene = list of triangle batches: tris (N,3,3) world coords (Roblox axes: +Y up), colors (N,3) 0..255,
flags (N,) bit 1 = emissive (Neon: no shading), alpha (N,) 1 = opaque (< 1: blended over the opaque layer).

Cameras: Camera.ortho(eye_dir, center, span) or Camera.persp(eye, target, fov).
render(scene, cam, w, h, ss) -> PIL.Image. Large triangles are subdivided in camera space; triangles crossing the
near plane are clipped. Flat shading with a warm sun + cool sky ambient, distance haze, screen-space depth outlines.
"""
import math

import numpy as np
from PIL import Image

SUN = np.array([0.45, 0.8, 0.38])
SUN /= np.linalg.norm(SUN)


class Camera:
    def __init__(self, R, eye, ortho_span=None, fov=None):
        self.R = R  # world -> camera rotation rows: right, up, back (camera looks along -back)
        self.eye = np.asarray(eye, dtype=float)
        self.span = ortho_span
        self.fov = fov

    @staticmethod
    def look(eye, target, up=(0, 1, 0)):
        eye, target, up = (np.asarray(v, dtype=float) for v in (eye, target, up))
        back = eye - target
        back /= np.linalg.norm(back)
        right = np.cross(up, back)
        if np.linalg.norm(right) < 1e-6:
            right = np.array([1.0, 0, 0])
        right /= np.linalg.norm(right)
        upv = np.cross(back, right)
        return np.stack([right, upv, back])

    @classmethod
    def ortho(cls, direction, center, span, up=(0, 1, 0)):
        d = np.asarray(direction, dtype=float)
        d /= np.linalg.norm(d)
        center = np.asarray(center, dtype=float)
        eye = center - d * 5000
        return cls(cls.look(eye, center, up), eye, ortho_span=span)

    @classmethod
    def persp(cls, eye, target, fov=60):
        return cls(cls.look(eye, target), eye, fov=fov)


def _to_cam(cam, pts):
    return (pts - cam.eye) @ cam.R.T  # x right, y up, z back (visible points have z < 0)


def _clip_near(tri, near):
    """Clip camera-space triangles against z = -near (keep z <= -near). Returns (tris, src index)."""
    z = tri[:, :, 2]
    inside = z <= -near
    cnt = inside.sum(1)
    keep = [tri[cnt == 3]]
    src = [np.nonzero(cnt == 3)[0]]

    def inter(a, b):
        t = (-near - a[:, 2]) / (b[:, 2] - a[:, 2])
        return a + (b - a) * t[:, None]

    # one vertex inside -> one triangle
    idx1 = np.nonzero(cnt == 1)[0]
    if len(idx1):
        t = tri[idx1]
        ins = inside[idx1]
        k = np.argmax(ins, axis=1)
        a = t[np.arange(len(t)), k]
        b = t[np.arange(len(t)), (k + 1) % 3]
        c = t[np.arange(len(t)), (k + 2) % 3]
        keep.append(np.stack([a, inter(a, b), inter(a, c)], axis=1))
        src.append(idx1)
    # two inside -> quad -> two triangles
    idx2 = np.nonzero(cnt == 2)[0]
    if len(idx2):
        t = tri[idx2]
        ins = inside[idx2]
        k = np.argmin(ins, axis=1)  # the outside vertex
        o = t[np.arange(len(t)), k]
        a = t[np.arange(len(t)), (k + 1) % 3]
        b = t[np.arange(len(t)), (k + 2) % 3]
        pa, pb = inter(a, o), inter(b, o)
        keep.append(np.stack([a, b, pb], axis=1))
        keep.append(np.stack([a, pb, pa], axis=1))
        src.append(idx2)
        src.append(idx2)
    return np.concatenate(keep), np.concatenate(src)


def _project(cam, c, W, H):
    if cam.span is not None:
        s = W / cam.span
        x = W / 2 + c[..., 0] * s
        y = H / 2 - c[..., 1] * s
    else:
        f = (W / 2) / math.tan(math.radians(cam.fov) / 2)
        zz = np.minimum(c[..., 2], -1e-3)
        x = W / 2 + c[..., 0] / -zz * f
        y = H / 2 - c[..., 1] / -zz * f
    return x, y


def _subdivide(cam, tri, src, W, H, limit=40, rounds=6):
    for _ in range(rounds):
        x, y = _project(cam, tri, W, H)
        ext = np.maximum(x.max(1) - x.min(1), y.max(1) - y.min(1))
        # off-screen triangles are culled before subdividing
        vis = (x.max(1) >= 0) & (x.min(1) < W) & (y.max(1) >= 0) & (y.min(1) < H)
        tri, src, ext = tri[vis], src[vis], ext[vis]
        big = ext > limit
        if not big.any():
            break
        t = tri[big]
        a, b, c = t[:, 0], t[:, 1], t[:, 2]
        ab, bc, ca = (a + b) / 2, (b + c) / 2, (c + a) / 2
        parts = [np.stack(q, axis=1) for q in ((a, ab, ca), (ab, b, bc), (ca, bc, c), (ab, bc, ca))]
        s = src[big]
        tri = np.concatenate([tri[~big]] + parts)
        src = np.concatenate([src[~big]] + [s] * 4)
    return tri, src


def _raster(x, y, z, W, H):
    """x,y (N,3) pixel coords, z (N,3) depth (larger = farther). Returns fragment (pixel, depth, tri) arrays."""
    pix_all, dep_all, tri_all = [], [], []
    x0 = np.floor(x.min(1)).astype(np.int64)
    y0 = np.floor(y.min(1)).astype(np.int64)
    ext = np.maximum(np.ceil(x.max(1)).astype(np.int64) - x0, np.ceil(y.max(1)).astype(np.int64) - y0) + 1
    order = np.arange(len(x))
    for B in (2, 4, 8, 16, 32, 64, 128):
        sel = order[(ext <= B) & (ext > B // 2)] if B > 2 else order[ext <= 2]
        if len(sel) == 0:
            continue
        chunk = max(1, 4_000_000 // (B * B))
        g = np.arange(B)
        gx, gy = np.meshgrid(g, g)
        gx, gy = gx.ravel(), gy.ravel()
        for i0 in range(0, len(sel), chunk):
            s = sel[i0:i0 + chunk]
            px = x0[s][:, None] + gx[None, :] + 0.5
            py = y0[s][:, None] + gy[None, :] + 0.5
            ax, ay = x[s, 0][:, None], y[s, 0][:, None]
            bx, by = x[s, 1][:, None], y[s, 1][:, None]
            cx, cy = x[s, 2][:, None], y[s, 2][:, None]
            den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
            den = np.where(np.abs(den) < 1e-12, 1e-12, den)
            w0 = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / den
            w1 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / den
            w2 = 1 - w0 - w1
            ins = (w0 >= -1e-6) & (w1 >= -1e-6) & (w2 >= -1e-6)
            ins &= (px >= 0) & (px < W) & (py >= 0) & (py < H)
            if not ins.any():
                continue
            d = w0 * z[s, 0][:, None] + w1 * z[s, 1][:, None] + w2 * z[s, 2][:, None]
            ii, jj = np.nonzero(ins)
            pix_all.append((py[ii, jj].astype(np.int64)) * W + px[ii, jj].astype(np.int64))
            dep_all.append(d[ii, jj].astype(np.float32))
            tri_all.append(s[ii])
    # huge leftovers (screen-filling ground faces right in front of a perspective camera): one at a time over
    # their bbox clipped to the screen
    for t in order[ext > 128]:
        bx0, by0 = max(int(x0[t]), 0), max(int(y0[t]), 0)
        bx1, by1 = min(int(np.ceil(x[t].max())) + 1, W), min(int(np.ceil(y[t].max())) + 1, H)
        if bx1 <= bx0 or by1 <= by0:
            continue
        gx, gy = np.meshgrid(np.arange(bx0, bx1) + 0.5, np.arange(by0, by1) + 0.5)
        px, py = gx.ravel(), gy.ravel()
        (ax, bx_, cx), (ay, by_, cy) = x[t], y[t]
        den = (by_ - cy) * (ax - cx) + (cx - bx_) * (ay - cy)
        if abs(den) < 1e-12:
            continue
        w0 = ((by_ - cy) * (px - cx) + (cx - bx_) * (py - cy)) / den
        w1 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / den
        w2 = 1 - w0 - w1
        ins = (w0 >= -1e-6) & (w1 >= -1e-6) & (w2 >= -1e-6)
        if not ins.any():
            continue
        d = w0 * z[t, 0] + w1 * z[t, 1] + w2 * z[t, 2]
        pix_all.append(py[ins].astype(np.int64) * W + px[ins].astype(np.int64))
        dep_all.append(d[ins].astype(np.float32))
        tri_all.append(np.full(int(ins.sum()), t, dtype=np.int64))
    if not pix_all:
        return np.zeros(0, np.int64), np.zeros(0, np.float32), np.zeros(0, np.int64)
    return np.concatenate(pix_all), np.concatenate(dep_all), np.concatenate(tri_all)


def _resolve(pix, dep, tri):
    if len(pix) == 0:
        return pix, tri, dep
    order = np.lexsort((dep, pix))
    p = pix[order]
    first = np.ones(len(p), dtype=bool)
    first[1:] = p[1:] != p[:-1]
    o = order[first]
    return pix[o], tri[o], dep[o]


def sky(W, H, top=(110, 170, 235), bottom=(214, 234, 250)):
    t = np.linspace(0, 1, H)[:, None, None]
    img = np.array(top, dtype=np.float32) * (1 - t) + np.array(bottom, dtype=np.float32) * t
    return np.broadcast_to(img, (H, W, 3)).copy()


def render(batches, cam, W, H, ss=2, haze=None, outline=True, background=None):
    """batches: list of dicts with tris/colors/(flags)/(alpha). Returns PIL image (W x H)."""
    Ws, Hs = W * ss, H * ss
    tris = np.concatenate([b["tris"] for b in batches]).astype(np.float64)
    cols = np.concatenate([b["colors"] for b in batches]).astype(np.float32)
    flags = np.concatenate([b.get("flags", np.zeros(len(b["tris"]), np.int8)) for b in batches])
    alpha = np.concatenate([b.get("alpha", np.ones(len(b["tris"]), np.float32)) for b in batches]).astype(np.float32)

    # world-space flat normals for shading (oriented toward the camera)
    n = np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0])
    ln = np.linalg.norm(n, axis=1)
    ok = ln > 1e-9
    tris, cols, flags, alpha, n, ln = tris[ok], cols[ok], flags[ok], alpha[ok], n[ok], ln[ok]
    n = n / ln[:, None]
    centers = tris.mean(1)
    if cam.span is not None:
        view = -cam.R[2]
        toward = np.tile(-view, (len(n), 1))
    else:
        toward = cam.eye - centers
    flip = (n * toward).sum(1) < 0
    n[flip] *= -1
    diffuse = np.clip(n @ SUN, 0, 1)
    skyterm = 0.5 + 0.5 * n[:, 1]
    light = 0.42 + 0.5 * diffuse + 0.14 * skyterm
    shaded = cols * light[:, None] * np.array([1.04, 1.0, 0.96])
    emissive = (flags & 1) == 1
    shaded[emissive] = cols[emissive] * 1.08
    shaded = np.clip(shaded, 0, 255)

    c = _to_cam(cam, tris)
    if cam.span is None:
        c, src = _clip_near(c, 0.5)
    else:
        src = np.arange(len(c))
    c, src = _subdivide(cam, c, src, Ws, Hs)
    x, y = _project(cam, c, Ws, Hs)
    z = -c[..., 2]  # distance along view
    persp = cam.span is None
    if persp:
        z = -1.0 / np.maximum(z, 1e-3)  # 1/z is affine in screen space: perspective-correct depth test

    opaque = alpha[src] >= 0.999
    img = sky(Ws, Hs) if background is None else np.broadcast_to(np.array(background, np.float32), (Hs, Ws, 3)).copy()
    depth = np.full(Ws * Hs, np.inf, dtype=np.float32)
    flat = img.reshape(-1, 3)

    pix, dep, ti = _raster(x[opaque], y[opaque], z[opaque], Ws, Hs)
    idx_opaque = np.nonzero(opaque)[0]
    p, t, d = _resolve(pix, dep, ti)
    srcs = src[idx_opaque[t]]
    flat[p] = shaded[srcs]
    depth[p] = d

    trans = ~opaque
    if trans.any():
        idx_t = np.nonzero(trans)[0]
        pix, dep, ti = _raster(x[trans], y[trans], z[trans], Ws, Hs)
        front = dep < depth[pix]
        pix, dep, ti = pix[front], dep[front], ti[front]
        p, t, d = _resolve(pix, dep, ti)
        s = src[idx_t[t]]
        a = alpha[s][:, None]
        flat[p] = flat[p] * (1 - a) + shaded[s] * a

    if persp:
        finite = np.isfinite(depth)
        depth[finite] = -1.0 / np.minimum(depth[finite], -1e-9)
    if haze is not None:
        dist = depth.reshape(Hs, Ws)
        hz = np.clip((dist - haze[0]) / (haze[1] - haze[0]), 0, 0.75)
        hz[~np.isfinite(dist)] = 0
        hazec = np.array([205, 222, 240], np.float32)
        img = img * (1 - hz[..., None]) + hazec * hz[..., None]

    if outline:
        dist = depth.reshape(Hs, Ws).copy()
        finite = np.isfinite(dist)
        far = dist[finite].max() if finite.any() else 1.0
        dist[~finite] = far * 2
        ld = np.log(dist + 1.0)
        e = np.zeros_like(ld)
        e[1:-1, 1:-1] = np.maximum.reduce([
            np.abs(ld[1:-1, 2:] - ld[1:-1, 1:-1]), np.abs(ld[1:-1, :-2] - ld[1:-1, 1:-1]),
            np.abs(ld[2:, 1:-1] - ld[1:-1, 1:-1]), np.abs(ld[:-2, 1:-1] - ld[1:-1, 1:-1])])
        edge = np.clip((e - 0.015) * 14, 0, 0.55)
        img = img * (1 - edge[..., None]) + np.array([24, 26, 40], np.float32) * edge[..., None]

    im = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8))
    if ss > 1:
        im = im.resize((W, H), Image.LANCZOS)
    return im


# --------------------------------------------------------------------------------------------- primitive meshes

def _box(sx, sy, sz):
    x, y, z = sx / 2, sy / 2, sz / 2
    v = np.array([[-x, -y, -z], [x, -y, -z], [x, y, -z], [-x, y, -z], [-x, -y, z], [x, -y, z], [x, y, z], [-x, y, z]])
    quads = [[0, 1, 2, 3], [5, 4, 7, 6], [4, 0, 3, 7], [1, 5, 6, 2], [3, 2, 6, 7], [4, 5, 1, 0]]
    return [v[q] for q in quads]


def _wedge(sx, sy, sz):
    x, y, z = sx / 2, sy / 2, sz / 2
    a, b, c, d = [-x, -y, -z], [x, -y, -z], [x, -y, z], [-x, -y, z]
    e, f = [x, y, z], [-x, y, z]
    return [np.array(p, dtype=float) for p in ([a, b, c, d], [d, c, e, f], [a, b, e, f], [a, d, f], [b, c, e])]


def _cylinder(sx, sy, sz, n=14):
    r = min(sy, sz) / 2
    h = sx / 2
    ring = [(r * math.cos(2 * math.pi * i / n), r * math.sin(2 * math.pi * i / n)) for i in range(n)]
    polys = [np.array([[-h, py, pz] for py, pz in ring]), np.array([[h, py, pz] for py, pz in ring])]
    for i in range(n):
        (y1, z1), (y2, z2) = ring[i], ring[(i + 1) % n]
        polys.append(np.array([[-h, y1, z1], [h, y1, z1], [h, y2, z2], [-h, y2, z2]]))
    return polys


def _ball(sx, sy, sz, n=10):
    r = min(sx, sy, sz) / 2
    polys = []
    for i in range(n // 2 + 1):
        t1 = math.pi * i / (n // 2 + 1) - math.pi / 2
        t2 = math.pi * (i + 1) / (n // 2 + 1) - math.pi / 2
        for j in range(n):
            p1, p2 = 2 * math.pi * j / n, 2 * math.pi * (j + 1) / n
            polys.append(np.array([[r * math.cos(t) * math.cos(p), r * math.sin(t), r * math.cos(t) * math.sin(p)]
                                   for t, p in ((t1, p1), (t1, p2), (t2, p2), (t2, p1))]))
    return polys


def _fan(polys):
    out = []
    for p in polys:
        for k in range(1, len(p) - 1):
            out.append([p[0], p[k], p[k + 1]])
    return np.array(out, dtype=float)


_PRIM_CACHE = {}


def part_triangles(part):
    """Triangles (N,3,3) of a dumped part (tools/dump.luau format) in world space."""
    sx, sy, sz = part["size"]
    shape = part.get("shape", "Block")
    key = (shape, round(sx, 4), round(sy, 4), round(sz, 4))
    local = _PRIM_CACHE.get(key)
    if local is None:
        if shape in ("Wedge", "CornerWedge"):
            polys = _wedge(sx, sy, sz)
        elif shape == "Cylinder":
            polys = _cylinder(sx, sy, sz, 16 if max(sy, sz) > 6 else 10)
        elif shape == "Ball":
            polys = _ball(sx, sy, sz, 14 if sx > 20 else 8)
        else:
            polys = _box(sx, sy, sz)
        local = _fan(polys)
        _PRIM_CACHE[key] = local
    c = part["cframe"]
    pos = np.array(c[0:3])
    rot = np.array([[c[3], c[4], c[5]], [c[6], c[7], c[8]], [c[9], c[10], c[11]]])
    return local @ rot.T + pos
