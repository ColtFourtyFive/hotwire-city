"""Geometry core of the building kit: per-material-role mesh buffers + low-poly primitives.

Everything is built directly as vertex/face lists (no bpy.ops), in building-local space:
  +X right, +Y back, +Z up, front facade faces -Y, origin at the footprint's bottom centre. 1 unit = 1 stud.
UVs default to world-space box projection with a per-role tile size (studs per texture repeat), so tiling PBR
textures keep a constant texel density on every building and textures can be shared city-wide.
"""
import math
import bpy
from mathutils import Vector


def _newell(pts):
    n = [0.0, 0.0, 0.0]
    for i in range(len(pts)):
        a, b = pts[i], pts[(i + 1) % len(pts)]
        n[0] += (a[1] - b[1]) * (a[2] + b[2])
        n[1] += (a[2] - b[2]) * (a[0] + b[0])
        n[2] += (a[0] - b[0]) * (a[1] + b[1])
    l = math.sqrt(n[0] ** 2 + n[1] ** 2 + n[2] ** 2) or 1.0
    return (n[0] / l, n[1] / l, n[2] / l)


def box_uv(pts, tile, off=(0.0, 0.0)):
    """World-space box projection (u right as seen from outside, v up)."""
    nx, ny, nz = _newell(pts)
    ax, ay, az = abs(nx), abs(ny), abs(nz)
    out = []
    for p in pts:
        if az >= ax and az >= ay:
            u, v = p[0], (p[1] if nz > 0 else -p[1])
        elif ax >= ay:
            u, v = (p[1] if nx > 0 else -p[1]), p[2]
        else:
            u, v = (-p[0] if ny > 0 else p[0]), p[2]
        out.append((u / tile + off[0], v / tile + off[1]))
    return out


class MeshBuf:
    """Geometry accumulated for one material role of one building (becomes one MeshPart)."""

    def __init__(self, name, tile=8.0):
        self.name, self.tile = name, tile
        self.v, self.f, self.uv = [], [], []

    def add(self, pts, faces, uvs=None, tile=None, off=(0.0, 0.0)):
        base = len(self.v)
        self.v.extend(tuple(p) for p in pts)
        for k, f in enumerate(faces):
            self.f.append(tuple(base + i for i in f))
            self.uv.append(uvs[k] if uvs is not None else box_uv([pts[i] for i in f], tile or self.tile, off))

    def tris(self):
        return sum(len(f) - 2 for f in self.f)

    def empty(self):
        return not self.f


# ----------------------------------------------------------------------------- primitives
def quad(buf, a, b, c, d, uv=None, tile=None):
    """Quad a-b-c-d counter-clockwise seen from the front. uv: 4 (u,v) or (u0,v0,u1,v1) rect, a=bottom-left."""
    if uv is not None and len(uv) == 4 and not isinstance(uv[0], (tuple, list)):
        u0, v0, u1, v1 = uv
        uv = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]
    buf.add([a, b, c, d], [(0, 1, 2, 3)], None if uv is None else [uv], tile=tile)


def _orient(pts, faces, center):
    """Make every face of a convex solid wind outward (centroid test)."""
    out = []
    for f in faces:
        fp = [pts[i] for i in f]
        c = [sum(p[k] for p in fp) / len(fp) for k in range(3)]
        n = _newell(fp)
        d = [c[k] - center[k] for k in range(3)]
        out.append(f if n[0] * d[0] + n[1] * d[1] + n[2] * d[2] >= 0 else tuple(reversed(f)))
    return out


def _sort_ccw(pts, idx, outward):
    c = Vector([sum(pts[i][k] for i in idx) / len(idx) for k in range(3)])
    n = Vector(outward).normalized()
    t = (Vector((1, 0, 0)) if abs(n.x) < 0.9 else Vector((0, 1, 0))).cross(n).normalized()
    b = n.cross(t)
    return tuple(sorted(idx, key=lambda i: math.atan2((Vector(pts[i]) - c).dot(b), (Vector(pts[i]) - c).dot(t))))


def box(buf, x0, y0, z0, x1, y1, z1, bevel=0.0, skip=(), tile=None, off=(0.0, 0.0)):
    """Axis-aligned box. bevel>0 -> 45deg chamfer on all edges (shaded smooth with weighted normals later).
    skip: faces to drop when hidden, any of 'bottom','top','-x','+x','-y','+y' (unbevelled boxes only)."""
    x0, x1 = min(x0, x1), max(x0, x1)
    y0, y1 = min(y0, y1), max(y0, y1)
    z0, z1 = min(z0, z1), max(z0, z1)
    c = min(bevel, (x1 - x0) * 0.45, (y1 - y0) * 0.45, (z1 - z0) * 0.45)
    ctr = ((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)
    if c <= 1e-4:
        P = [(x, y, z) for z in (z0, z1) for y in (y0, y1) for x in (x0, x1)]
        F = {"bottom": (0, 1, 3, 2), "top": (4, 5, 7, 6), "-y": (0, 1, 5, 4), "+y": (2, 3, 7, 6),
             "-x": (0, 2, 6, 4), "+x": (1, 3, 7, 5)}
        faces = [f for k, f in F.items() if k not in skip]
        buf.add(P, _orient(P, faces, ctr), tile=tile, off=off)
        return
    X, Y, Z = (x0, x1), (y0, y1), (z0, z1)
    P, idx = [], {}
    for sx in (0, 1):
        for sy in (0, 1):
            for sz in (0, 1):
                px, py, pz = X[sx], Y[sy], Z[sz]
                dx, dy, dz = (c if sx == 0 else -c), (c if sy == 0 else -c), (c if sz == 0 else -c)
                for axis, p in (("x", (px, py + dy, pz + dz)), ("y", (px + dx, py, pz + dz)), ("z", (px + dx, py + dy, pz))):
                    idx[(sx, sy, sz, axis)] = len(P)
                    P.append(p)
    faces = []
    for s in (0, 1):  # main faces
        if not ("bottom" in skip and s == 0):
            faces.append(_sort_ccw(P, [idx[(a, b, s, "z")] for a in (0, 1) for b in (0, 1)], (0, 0, 1 if s else -1)))
        faces.append(_sort_ccw(P, [idx[(s, a, b, "x")] for a in (0, 1) for b in (0, 1)], (1 if s else -1, 0, 0)))
        faces.append(_sort_ccw(P, [idx[(a, s, b, "y")] for a in (0, 1) for b in (0, 1)], (0, 1 if s else -1, 0)))
    for a in (0, 1):  # edge faces
        for b in (0, 1):
            faces.append(_sort_ccw(P, [idx[(s, a, b, k)] for s in (0, 1) for k in ("y", "z")], (0, a - .5, b - .5)))
            faces.append(_sort_ccw(P, [idx[(a, s, b, k)] for s in (0, 1) for k in ("x", "z")], (a - .5, 0, b - .5)))
            faces.append(_sort_ccw(P, [idx[(a, b, s, k)] for s in (0, 1) for k in ("x", "y")], (a - .5, b - .5, 0)))
    for sx in (0, 1):  # corner triangles
        for sy in (0, 1):
            for sz in (0, 1):
                if "bottom" in skip and sz == 0:
                    continue
                faces.append(tuple(idx[(sx, sy, sz, k)] for k in ("x", "y", "z")))
    if "bottom" in skip:
        faces = [f for f in faces if not all(P[i][2] < z0 + c * 0.5 for i in f)]
    buf.add(P, _orient(P, faces, ctr), tile=tile, off=off)


def cylinder(buf, cx, cy, z0, z1, r, seg=12, caps=(False, True), tile=None, r1=None):
    """Vertical cylinder / cone frustum (r at bottom, r1 at top)."""
    r1 = r if r1 is None else r1
    P = []
    for k in range(seg):
        a = 2 * math.pi * k / seg
        P.append((cx + r * math.cos(a), cy + r * math.sin(a), z0))
    for k in range(seg):
        a = 2 * math.pi * k / seg
        P.append((cx + r1 * math.cos(a), cy + r1 * math.sin(a), z1))
    faces = [(k, (k + 1) % seg, seg + (k + 1) % seg, seg + k) for k in range(seg)]
    circ = 2 * math.pi * max(r, r1)
    t = tile or buf.tile
    uvs = [[(k / seg * circ / t, z0 / t), ((k + 1) / seg * circ / t, z0 / t), ((k + 1) / seg * circ / t, z1 / t),
            (k / seg * circ / t, z1 / t)] for k in range(seg)]
    if caps[0]:
        f = tuple(reversed(range(seg)))
        faces.append(f)
        uvs.append(box_uv([P[i] for i in f], t))
    if caps[1]:
        f = tuple(range(seg, 2 * seg))
        faces.append(f)
        uvs.append(box_uv([P[i] for i in f], t))
    buf.add(P, faces, uvs)


def hcylinder(buf, p0, p1, r, seg=8, tile=None):
    """Cylinder between two points (pipes, rails, poles). No caps."""
    a, b = Vector(p0), Vector(p1)
    ax = (b - a).normalized()
    t = (Vector((0, 0, 1)) if abs(ax.z) < 0.9 else Vector((1, 0, 0))).cross(ax).normalized()
    s = ax.cross(t)
    P = []
    for e in (a, b):
        for k in range(seg):
            ang = 2 * math.pi * k / seg
            P.append(tuple(e + (t * math.cos(ang) + s * math.sin(ang)) * r))
    faces = [(k, (k + 1) % seg, seg + (k + 1) % seg, seg + k) for k in range(seg)]
    faces = _orient(P, faces, tuple((a + b) / 2))
    buf.add(P, faces, tile=tile)


# ----------------------------------------------------------------------------- 2D loops & sweeps
def offset_loop(loop, d, closed=True):
    """Offset a CCW polyline outward by d with mitred corners."""
    n = len(loop)
    out = []
    for i in range(n):
        p = Vector(loop[i])
        if closed or 0 < i < n - 1:
            a, b = Vector(loop[i - 1]), Vector(loop[(i + 1) % n])
            e1, e2 = (p - a).normalized(), (b - p).normalized()
            n1, n2 = Vector((e1.y, -e1.x)), Vector((e2.y, -e2.x))
            m = n1 + n2
            k = 1 + n1.dot(n2)
            out.append(tuple(p + m * (d / k)) if k > 1e-3 else tuple(p + n1 * d))
        else:
            e = (Vector(loop[1]) - p) if i == 0 else (p - Vector(loop[i - 1]))
            e.normalize()
            out.append(tuple(p + Vector((e.y, -e.x)) * d))
    return out


def rounded_rect(x0, y0, x1, y1, radii=(0, 0, 0, 0), seg=6):
    """CCW loop; radii for corners (front-left, front-right, back-right, back-left)."""
    corners = [((x0, y0), (1, 1), 180), ((x1, y0), (-1, 1), 270), ((x1, y1), (-1, -1), 0), ((x0, y1), (1, -1), 90)]
    loop = []
    for k,((cx, cy), (sx, sy), a0) in enumerate(corners):
        r = radii[k]
        if r <= 0:
            loop.append((cx, cy))
            continue
        ox, oy = cx + sx * r, cy + sy * r
        for j in range(seg + 1):
            a = math.radians(a0 + 90 * j / seg)
            loop.append((ox + r * math.cos(a), oy + r * math.sin(a)))
    return loop


def sweep(buf, path, profile, closed=True, cap_ends=False, tile=None, u_off=0.0):
    """Sweep a vertical-section profile [(out, z), ...] along a CCW 2D path (outward = right of travel).
    Profile order: bottom->top along the outside gives outward normals."""
    t = tile or buf.tile
    rings = [offset_loop(path, o, closed) for o, _ in profile]
    n = len(path)
    P = []
    for k, (o, z) in enumerate(profile):
        for p in rings[k]:
            P.append((p[0], p[1], z))
    # u along the (unoffset) path, v along the profile
    plen = [0.0]
    for i in range(1, n + (1 if closed else 0)):
        a, b = path[i - 1], path[i % n]
        plen.append(plen[-1] + math.hypot(b[0] - a[0], b[1] - a[1]))
    vlen = [0.0]
    for k in range(1, len(profile)):
        vlen.append(vlen[-1] + math.hypot(profile[k][0] - profile[k - 1][0], profile[k][1] - profile[k - 1][1]))
    faces, uvs = [], []
    segs = n if closed else n - 1
    for k in range(len(profile) - 1):
        for i in range(segs):
            j = (i + 1) % n
            a, b, c, d = k * n + i, k * n + j, (k + 1) * n + j, (k + 1) * n + i
            if P[a] == P[d] and P[b] == P[c]:
                continue
            faces.append((a, b, c, d))
            u0, u1 = (plen[i] + u_off) / t, (plen[i + 1] + u_off) / t
            v0, v1 = vlen[k] / t, vlen[k + 1] / t
            uvs.append([(u0, v0), (u1, v0), (u1, v1), (u0, v1)])
    if cap_ends and not closed:
        m = len(profile)
        for i, rev in ((0, True), (n - 1, False)):
            f = tuple(k * n + i for k in range(m))
            f = tuple(reversed(f)) if rev else f
            faces.append(f)
            uvs.append(box_uv([P[q] for q in f], t))
    buf.add(P, faces, uvs)


def cap(buf, loop, z, up=True, tile=None, uv_rect=None):
    """Fan-triangulated convex cap (roofs, slabs)."""
    P = [(p[0], p[1], z) for p in loop]
    f = tuple(range(len(P))) if up else tuple(reversed(range(len(P))))
    if uv_rect is None:
        buf.add(P, [f], tile=tile)
    else:
        xs, ys = [p[0] for p in loop], [p[1] for p in loop]
        u0, v0, u1, v1 = uv_rect
        def m(p):
            return (u0 + (p[0] - min(xs)) / (max(xs) - min(xs)) * (u1 - u0), v0 + (p[1] - min(ys)) / (max(ys) - min(ys)) * (v1 - v0))
        buf.add(P, [f], [[m(P[i]) for i in f]])


# ----------------------------------------------------------------------------- facades
class Facade:
    """A planar, axis-aligned wall. Local coords: u along R (left->right seen from outside), z up,
    n along the outward normal (0 = wall plane, negative = into the building)."""

    def __init__(self, origin, right, normal, width):
        self.O, self.R, self.N, self.W = Vector(origin), Vector(right), Vector(normal), width

    def p(self, u, z, n=0.0):
        q = self.O + self.R * u + self.N * n
        return (q.x, q.y, z)

    def box(self, buf, u0, u1, n0, n1, z0, z1, bevel=0.0, skip=(), tile=None, off=(0.0, 0.0)):
        a, b = self.p(u0, z0, n0), self.p(u1, z1, n1)
        sk = []
        for s in skip:   # translate facade-local face names to world axes
            if s in ("top", "bottom"):
                sk.append(s)
            elif s in ("back", "front"):
                v = self.N * (-1 if s == "back" else 1)
                sk.append(("+" if (v.x + v.y) > 0 else "-") + ("x" if abs(v.x) > 0.5 else "y"))
            elif s in ("left", "right"):
                v = self.R * (-1 if s == "left" else 1)
                sk.append(("+" if (v.x + v.y) > 0 else "-") + ("x" if abs(v.x) > 0.5 else "y"))
        box(buf, a[0], a[1], a[2], b[0], b[1], b[2], bevel=bevel, skip=tuple(sk), tile=tile, off=off)

    def quad(self, buf, u0, u1, z0, z1, n=0.0, uv=None, tile=None):
        quad(buf, self.p(u0, z0, n), self.p(u1, z0, n), self.p(u1, z1, n), self.p(u0, z1, n), uv=uv, tile=tile)

    def wall(self, buf, z0, z1, openings=(), u0=0.0, u1=None, n=0.0):
        """Wall plane between z0..z1 with rectangular holes [(u0,u1,z0,z1), ...]; greedy-merged quads."""
        u1 = self.W if u1 is None else u1
        us = sorted({u0, u1, *[max(u0, min(u1, o[0])) for o in openings], *[max(u0, min(u1, o[1])) for o in openings]})
        zs = sorted({z0, z1, *[max(z0, min(z1, o[2])) for o in openings], *[max(z0, min(z1, o[3])) for o in openings]})
        def hole(uc, zc):
            return any(o[0] < uc < o[1] and o[2] < zc < o[3] for o in openings)
        for j in range(len(zs) - 1):
            za, zb = zs[j], zs[j + 1]
            if zb - za < 1e-4:
                continue
            run = None
            for i in range(len(us) - 1):
                ua, ub = us[i], us[i + 1]
                if ub - ua < 1e-4:
                    continue
                solid = not hole((ua + ub) / 2, (za + zb) / 2)
                if solid:
                    run = (run[0], ub) if run else (ua, ub)
                elif run:
                    self.quad(buf, run[0], run[1], za, zb, n)
                    run = None
            if run:
                self.quad(buf, run[0], run[1], za, zb, n)

    def reveal(self, buf, u0, u1, z0, z1, depth, sides=(True, True, True, True)):
        """Inner faces of a recessed opening (bottom, right, top, left)."""
        P = lambda u, z, n: self.p(u, z, n)
        if sides[0]:
            quad(buf, P(u0, z0, -depth), P(u1, z0, -depth), P(u1, z0, 0), P(u0, z0, 0))
        if sides[1]:
            quad(buf, P(u1, z0, 0), P(u1, z0, -depth), P(u1, z1, -depth), P(u1, z1, 0))
        if sides[2]:
            quad(buf, P(u0, z1, 0), P(u1, z1, 0), P(u1, z1, -depth), P(u0, z1, -depth))
        if sides[3]:
            quad(buf, P(u0, z0, -depth), P(u0, z0, 0), P(u0, z1, 0), P(u0, z1, -depth))


# ----------------------------------------------------------------------------- roofs / misc solids
def slope_uv(pts, along, tile, off=(0.0, 0.0)):
    """UV for a sloped roof face: u along the eave direction `along`, v up the slope (from the lowest vertex)."""
    a = Vector(along).normalized()
    n = Vector(_newell(pts))
    up = n.cross(a).normalized()
    if up.z < 0:
        up = -up
    p0 = Vector(pts[0])
    return [(((Vector(p) - p0).dot(a)) / tile + off[0], ((Vector(p) - p0).dot(up)) / tile + off[1]) for p in pts]


def poly(buf, pts, uv_along=None, tile=None):
    """Single planar polygon (any count, convex), CCW seen from the front. uv_along -> slope_uv."""
    t = tile or buf.tile
    uv = slope_uv(pts, uv_along, t) if uv_along is not None else None
    buf.add([tuple(p) for p in pts], [tuple(range(len(pts)))], None if uv is None else [uv], tile=t)


def tri(buf, a, b, c, uv_along=None, tile=None):
    poly(buf, [a, b, c], uv_along, tile)


def hip_roof(roof, x0, y0, x1, y1, z, pitch=0.42, overhang=1.5, ridge_axis=None, fascia=None, fascia_h=0.9, soffit=None):
    """Hip roof over rect (x0..x1, y0..y1) at eave height z. pitch = rise/run. Returns ridge height.
    fascia/soffit: optional MeshBufs for the eave board and the underside."""
    X0, Y0, X1, Y1 = x0 - overhang, y0 - overhang, x1 + overhang, y1 + overhang
    W, D = X1 - X0, Y1 - Y0
    if ridge_axis is None:
        ridge_axis = "x" if W >= D else "y"
    if ridge_axis == "x":
        h = D / 2 * pitch
        r0, r1 = (X0 + D / 2, (Y0 + Y1) / 2, z + h), (X1 - D / 2, (Y0 + Y1) / 2, z + h)
        if r0[0] > r1[0]:
            r0 = r1 = ((X0 + X1) / 2, (Y0 + Y1) / 2, z + h)
        poly(roof, [(X0, Y0, z), (X1, Y0, z), r1, r0], uv_along=(1, 0, 0))
        poly(roof, [(X1, Y1, z), (X0, Y1, z), r0, r1], uv_along=(-1, 0, 0))
        tri(roof, (X1, Y0, z), (X1, Y1, z), r1, uv_along=(0, 1, 0))
        tri(roof, (X0, Y1, z), (X0, Y0, z), r0, uv_along=(0, -1, 0))
    else:
        h = W / 2 * pitch
        r0, r1 = ((X0 + X1) / 2, Y0 + W / 2, z + h), ((X0 + X1) / 2, Y1 - W / 2, z + h)
        if r0[1] > r1[1]:
            r0 = r1 = ((X0 + X1) / 2, (Y0 + Y1) / 2, z + h)
        poly(roof, [(X1, Y0, z), (X1, Y1, z), r1, r0], uv_along=(0, 1, 0))
        poly(roof, [(X0, Y1, z), (X0, Y0, z), r0, r1], uv_along=(0, -1, 0))
        tri(roof, (X0, Y0, z), (X1, Y0, z), r0, uv_along=(1, 0, 0))
        tri(roof, (X1, Y1, z), (X0, Y1, z), r1, uv_along=(-1, 0, 0))
    _eave(X0, Y0, X1, Y1, z, fascia, fascia_h, soffit, x0, y0, x1, y1)
    return z + h


def gable_roof(roof, x0, y0, x1, y1, z, pitch=0.42, overhang=1.5, ridge_axis="x", fascia=None, fascia_h=0.9,
               soffit=None, gable_wall=None, rake=None):
    """Gable roof; the triangular gable ends are added to `gable_wall` (flush with the wall plane)."""
    X0, Y0, X1, Y1 = x0 - overhang, y0 - overhang, x1 + overhang, y1 + overhang
    if ridge_axis == "x":
        h = (Y1 - Y0) / 2 * pitch
        yc = (Y0 + Y1) / 2
        poly(roof, [(X0, Y0, z), (X1, Y0, z), (X1, yc, z + h), (X0, yc, z + h)], uv_along=(1, 0, 0))
        poly(roof, [(X1, Y1, z), (X0, Y1, z), (X0, yc, z + h), (X1, yc, z + h)], uv_along=(-1, 0, 0))
        if gable_wall is not None:
            zw = z - overhang * pitch * 0.0
            hh = (y1 - y0) / 2 * pitch + overhang * pitch
            tri(gable_wall, (x0, y1, z), (x0, y0, z), (x0, (y0 + y1) / 2, z + hh))
            tri(gable_wall, (x1, y0, z), (x1, y1, z), (x1, (y0 + y1) / 2, z + hh))
        if rake is not None:   # barge boards along the sloped edges
            for X in (X0, X1):
                for (ya, yb) in ((Y0, yc), (Y1, yc)):
                    za, zb = z, z + h
                    poly(rake, [(X, ya, za - fascia_h), (X, yb, zb - fascia_h), (X, yb, zb), (X, ya, za)][::(1 if (X == X1) == (yb > ya) else -1)])
        if fascia is not None:
            for Y, sgn in ((Y0, -1), (Y1, 1)):
                box(fascia, X0, Y - 0.15 if sgn < 0 else Y - 0.05, z - fascia_h, X1, Y + 0.05 if sgn < 0 else Y + 0.15, z + 0.05)
        if soffit is not None:
            for (ya, yb) in ((Y0, y0), (y1, Y1)):
                poly(soffit, [(X0, ya, z - 0.05), (X0, yb, z - 0.05), (X1, yb, z - 0.05), (X1, ya, z - 0.05)])
    else:
        h = (X1 - X0) / 2 * pitch
        xc = (X0 + X1) / 2
        poly(roof, [(X1, Y0, z), (X1, Y1, z), (xc, Y1, z + h), (xc, Y0, z + h)], uv_along=(0, 1, 0))
        poly(roof, [(X0, Y1, z), (X0, Y0, z), (xc, Y0, z + h), (xc, Y1, z + h)], uv_along=(0, -1, 0))
        if gable_wall is not None:
            hh = (x1 - x0) / 2 * pitch + overhang * pitch
            tri(gable_wall, (x0, y0, z), (x1, y0, z), ((x0 + x1) / 2, y0, z + hh))
            tri(gable_wall, (x1, y1, z), (x0, y1, z), ((x0 + x1) / 2, y1, z + hh))
        if fascia is not None:
            for X, sgn in ((X0, -1), (X1, 1)):
                box(fascia, X - 0.15 if sgn < 0 else X - 0.05, Y0, z - fascia_h, X + 0.05 if sgn < 0 else X + 0.15, Y1, z + 0.05)
        if soffit is not None:
            for (xa, xb) in ((X0, x0), (x1, X1)):
                poly(soffit, [(xa, Y0, z - 0.05), (xb, Y0, z - 0.05), (xb, Y1, z - 0.05), (xa, Y1, z - 0.05)][::-1])
    return z + h


def _eave(X0, Y0, X1, Y1, z, fascia, fh, soffit, x0, y0, x1, y1):
    if fascia is not None:
        box(fascia, X0 - 0.15, Y0 - 0.15, z - fh, X1 + 0.15, Y0 + 0.05, z + 0.05, skip=("back",))
        box(fascia, X0 - 0.15, Y1 - 0.05, z - fh, X1 + 0.15, Y1 + 0.15, z + 0.05)
        box(fascia, X0 - 0.15, Y0 + 0.05, z - fh, X0 + 0.05, Y1 - 0.05, z + 0.05)
        box(fascia, X1 - 0.05, Y0 + 0.05, z - fh, X1 + 0.15, Y1 - 0.05, z + 0.05)
    if soffit is not None:
        zz = z - fh + 0.02
        for q in (((X0, Y0), (X1, Y0), (x1, y0), (x0, y0)), ((X1, Y0), (X1, Y1), (x1, y1), (x1, y0)),
                  ((X1, Y1), (X0, Y1), (x0, y1), (x1, y1)), ((X0, Y1), (X0, Y0), (x0, y0), (x0, y1))):
            poly(soffit, [(p[0], p[1], zz) for p in q][::-1])


def shed_roof(roof, x0, y0, x1, y1, z_low, z_high, overhang=1.0, low_side="-y"):
    X0, Y0, X1, Y1 = x0 - overhang, y0 - overhang, x1 + overhang, y1 + overhang
    if low_side == "-y":
        poly(roof, [(X0, Y0, z_low), (X1, Y0, z_low), (X1, Y1, z_high), (X0, Y1, z_high)], uv_along=(1, 0, 0))
    else:
        poly(roof, [(X1, Y1, z_low), (X0, Y1, z_low), (X0, Y0, z_high), (X1, Y0, z_high)], uv_along=(-1, 0, 0))


def prism(buf, loop, z0, z1, top=True, bottom=False, tile=None):
    """Vertical extrusion of a CCW loop (walls + optional caps). Concave caps are not supported."""
    n = len(loop)
    for i in range(n):
        a, b = loop[i], loop[(i + 1) % n]
        quad(buf, (a[0], a[1], z0), (b[0], b[1], z0), (b[0], b[1], z1), (a[0], a[1], z1), tile=tile)
    if top:
        cap(buf, loop, z1, up=True, tile=tile)
    if bottom:
        cap(buf, loop, z0, up=False, tile=tile)


# ----------------------------------------------------------------------------- to Blender
def to_object(buf, material, collection, parent=None, sharp_deg=50.0, weighted=True):
    me = bpy.data.meshes.new(buf.name)
    me.from_pydata(buf.v, [], buf.f)
    uvl = me.uv_layers.new(name="UVMap")
    li = 0
    for poly, uvs in zip(me.polygons, buf.uv):
        for k, loop_index in enumerate(poly.loop_indices):
            uvl.data[loop_index].uv = uvs[k]
    me.validate(clean_customdata=False)
    me.shade_smooth()
    me.set_sharp_from_angle(angle=math.radians(sharp_deg))
    if material is not None:
        me.materials.append(material)
    ob = bpy.data.objects.new(buf.name, me)
    collection.objects.link(ob)
    if parent is not None:
        ob.parent = parent
    if weighted:
        m = ob.modifiers.new("WeightedNormal", "WEIGHTED_NORMAL")
        m.keep_sharp = True
        m.weight = 50
        m.mode = "FACE_AREA"
    return ob
