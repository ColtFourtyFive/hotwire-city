"""Parametric car body: lofted cross-sections along the car length, rounded ends, CDT end caps.

Coordinate frame (Blender): +X = driver's right, +Y = forward (nose), +Z = up, ground at Z = 0.
All units are studs. See ../README.md for the export mapping to Roblox.

The body is described by smooth 1D profiles of a handful of section "key points" as functions of Y:
    K0 bottom centre, K1 bottom corner, K2 rocker crease, K3 shoulder crease,
    K4 window base (belt) / fender top, K5 roof edge / hood edge, K6 top centre.
Every station evaluates those key points, builds a rounded half-section (geom.section_curve) with a FIXED
vertex count, mirrors it, and the stations are lofted into a quad tube. The ends are rounded by
direction-weighted inward offsets that reach vertical tangency at the very ends, and the two end rings
are closed with constrained-Delaunay caps (with interior points so the caps can be curved).
"""
from __future__ import annotations

import math
import numpy as np

from .geom import Profile, bump, ellip_drop, section_curve, polyline_normals_ccw, smoothstep

# segment counts of the half section: span0, c1, span1, c2, span2, c3, span3, c4, span4, c5, span5
HALF_COUNTS = [1, 1, 1, 1, 4, 2, 2, 1, 2, 2, 3]
# piece ids (index into HALF_COUNTS) that belong to the lower body (rocker / underside)
PIECE_BOTTOM = {0, 1, 2}
PIECE_ROCKER = {3}


class BodyModel:
    """Evaluates the parametric body for a spec dict (see archetypes.py)."""

    def __init__(self, spec):
        self.s = s = spec
        L = s["length"]
        self.yF, self.yR = L / 2.0, -L / 2.0
        hw = s["width"] / 2.0
        self.hw = hw
        yF, yR = self.yF, self.yR
        yc, yrf, yrr, yd = s["cowl_y"], s["roof_front_y"], s["roof_rear_y"], s["deck_y"]
        self.cabin = Profile([(yd, 0.0), (yrr, 1.0), (yrf, 1.0), (yc, 0.0)])

        # ---- heights ---------------------------------------------------------------------
        g = s["ground"]
        self.z_bot = Profile([(yR, g + s["rear_lift"]), (s["axle_r"] - 0.2, g), (s["axle_f"] + 0.2, g),
                              (yF, g + s["front_lift"])])
        rk = s["rocker_h"]
        self.z_rock = Profile([(yR, g + s["rear_lift"] + rk * 1.15), (s["axle_r"], g + rk),
                               (s["axle_f"], g + rk), (yF, g + s["front_lift"] + rk * 1.1)])
        self.z_shl = Profile(s["shoulder_pts"])
        self.z_g0 = Profile(s["belt_pts"])
        self.z_top = Profile(s["top_pts"])
        hc, rc = s["hood_crown"], s["roof_crown"]
        self.crown = lambda y: hc + (rc - hc) * self.cabin(y)

        # ---- half widths -------------------------------------------------------------------
        self.w_side_base = Profile([(yR, hw - s["taper_r"]), (s["axle_r"], hw), (s["axle_f"], hw),
                                    (yF, hw - s["taper_f"])])
        self.roof_hw = Profile(s["roof_hw_pts"])

    # ------------------------------------------------------------------------------------------
    def flare(self, y):
        s = self.s
        ar = s["arch_r"]
        return (s["flare_f"] * bump(y, s["axle_f"], ar + s["flare_len"])
                + s["flare_r"] * bump(y, s["axle_r"] - s.get("flare_r_shift", 0.0), ar + s["flare_len"] * 1.15))

    def keys(self, y):
        s = self.s
        fl = self.flare(y)
        w_side = self.w_side_base(y) + fl
        w_rock = w_side - s["rocker_tuck"] - 0.35 * fl
        w_shl = w_side - s["shoulder_tuck"] + 0.15 * fl
        cab = self.cabin(y)
        ledge = s["ledge_hood"] + (s["ledge_cabin"] - s["ledge_hood"]) * cab
        w_g0 = w_shl - ledge - 0.55 * fl
        hood_edge = w_g0 - s["hood_edge_in"]
        w_g1 = hood_edge + (self.roof_hw(y) - hood_edge) * cab
        w_g1 = min(w_g1, w_g0 - 0.05)
        zb = self.z_bot(y)
        zr = self.z_rock(y)
        zs = self.z_shl(y)
        z0 = self.z_g0(y)
        zt = self.z_top(y)
        z1 = zt - self.crown(y)
        K = np.array([
            [0.0, zb],
            [w_rock - s["bottom_in"], zb],
            [w_rock, zr],
            [w_shl, zs],
            [w_g0, z0],
            [w_g1, z1],
            [0.0, zt],
        ])
        # control points of the spans
        side_ctrl = np.array([w_side + (w_side - 0.5 * (w_rock + w_shl)), 0.5 * (zr + zs) + s["side_peak"] * (zs - zr)])
        lower_ctrl = np.array([w_rock - s["bottom_in"] * 0.15, zb + 0.6 * (zr - zb)])
        ledge_ctrl = None
        gh_ctrl = np.array([0.5 * (w_g0 + w_g1) + s["gh_bulge"] * cab, 0.5 * (z0 + z1)])
        roof_ctrl = np.array([0.55 * w_g1, zt])
        ctrls = [None, lower_ctrl, side_ctrl, ledge_ctrl, gh_ctrl, roof_ctrl]
        cuts = [s["r_bottom"], s["r_rocker"], s["r_shoulder"], s["r_belt"],
                s["r_roofedge_hood"] + (s["r_roofedge"] - s["r_roofedge_hood"]) * cab]
        return K, ctrls, cuts

    def half_section(self, y):
        K, ctrls, cuts = self.keys(y)
        pts, seg = section_curve(K, ctrls, cuts, HALF_COUNTS)
        nrm = polyline_normals_ccw(pts)
        nrm[0] = (0.0, -1.0)
        nrm[-1] = (0.0, 1.0)
        # end rounding: direction-weighted inward offsets
        s = self.s
        side_d = (ellip_drop(y, self.yF, s["nose_round_y"], s["nose_round_x"], s["nose_pow"])
                  + ellip_drop(-y, -self.yR, s["tail_round_y"], s["tail_round_x"], s["tail_pow"]))
        top_d = (ellip_drop(y, self.yF, s["nose_top_y"], s["nose_top_z"], 2.0)
                 + ellip_drop(-y, -self.yR, s["tail_top_y"], s["tail_top_z"], 2.0))
        bot_d = (ellip_drop(y, self.yF, s["nose_bot_y"], s["nose_bot_z"], 2.0)
                 + ellip_drop(-y, -self.yR, s["tail_bot_y"], s["tail_bot_z"], 2.0))
        # scale towards the section centre (monotone: cannot self-intersect like normal offsets)
        x_out = max(float(pts[:, 0].max()), 1e-3)
        pts = pts.copy()
        pts[:, 0] *= max(0.05, 1.0 - side_d / x_out)
        zb, zt = float(pts[:, 1].min()), float(pts[:, 1].max())
        zc = zb + 0.45 * (zt - zb)
        up = pts[:, 1] > zc
        k_up = max(0.05, 1.0 - top_d / max(zt - zc, 1e-3))
        k_dn = max(0.05, 1.0 - bot_d / max(zc - zb, 1e-3))
        pts[up, 1] = zc + (pts[up, 1] - zc) * k_up
        pts[~up, 1] = zc + (pts[~up, 1] - zc) * k_dn
        pts[0, 0] = 0.0
        pts[-1, 0] = 0.0
        return pts, nrm, seg

    # ------------------------------------------------------------------------------------------
    def end_shift(self, x, z, y):
        """Plan-view sweep + rake of the nose and tail (applied smoothly over the end zones)."""
        s = self.s
        hw = self.hw
        out = np.zeros_like(np.asarray(x, float))
        # front
        rf = smoothstep(self.yF - s["nose_ramp"], self.yF, y)
        zc_f = 0.5 * (self.z_bot(self.yF) + self.z_top(self.yF))
        out = out + rf * (-s["nose_sweep"] * (np.asarray(x) / hw) ** 2
                          - s["nose_rake"] * (np.asarray(z) - zc_f))
        rr = smoothstep(-(self.yR + s["tail_ramp"]), -self.yR, -np.asarray(y))
        zc_r = 0.5 * (self.z_bot(self.yR) + self.z_top(self.yR))
        out = out + rr * (s["tail_sweep"] * (np.asarray(x) / hw) ** 2
                          + s["tail_rake"] * (np.asarray(z) - zc_r))
        return out

    def stations(self):
        s = self.s
        yF, yR = self.yF, self.yR
        ys = np.linspace(yR, yF, 4000)
        h = np.full_like(ys, s["station_h"])
        for ax in (s["axle_f"], s["axle_r"]):
            h = np.where(np.abs(ys - ax) < s["arch_r"] + 0.5, np.minimum(h, s["station_h_arch"]), h)
        for yk in (s["cowl_y"], s["roof_front_y"], s["roof_rear_y"], s["deck_y"]):
            h = np.where(np.abs(ys - yk) < 0.45, np.minimum(h, s["station_h_feature"]), h)
        d_end = np.minimum(yF - ys, ys - yR)
        h = np.minimum(h, np.maximum(0.012, s["end_k"] * np.sqrt(np.maximum(d_end, 0.0))))
        cum = np.concatenate([[0.0], np.cumsum(0.5 * (1 / h[1:] + 1 / h[:-1]) * np.diff(ys))])
        n = max(8, int(math.ceil(cum[-1])))
        st = np.interp(np.linspace(0, cum[-1], n + 1), cum, ys)
        st[0], st[-1] = yR, yF
        return st

    # ------------------------------------------------------------------------------------------
    def build(self):
        """Returns dict(verts (V,3), quads [(a,b,c,d)], tris [(a,b,c)], quad_role, tri_role, rings info)."""
        st = self.stations()
        rings = []
        segs = None
        for y in st:
            half, nrm, seg = self.half_section(y)
            segs = seg
            N = len(half) - 1
            # full ring: right half k=0..N, left half k=N-1..1
            xs = np.concatenate([half[:, 0], -half[N - 1:0:-1, 0]])
            zs = np.concatenate([half[:, 1], half[N - 1:0:-1, 1]])
            yy = np.full_like(xs, y) + self.end_shift(xs, zs, np.full_like(xs, y))
            rings.append(np.stack([xs, yy, zs], axis=1))
        rings = np.array(rings)  # (S, R, 3)
        S, R, _ = rings.shape
        N = R // 2
        verts = rings.reshape(-1, 3)
        quads = []
        quad_piece = []
        # ring segment index r -> half-section piece id
        seg_piece = np.concatenate([segs, segs[::-1]])
        for i in range(S - 1):
            for r in range(R):
                r2 = (r + 1) % R
                quads.append((i * R + r, i * R + r2, (i + 1) * R + r2, (i + 1) * R + r))
                quad_piece.append(int(seg_piece[r]))
        self.rings = rings
        self.seg_piece = seg_piece
        tris_all = []
        tri_cap = []
        extra = [verts]
        nv = len(verts)
        for end, ring_idx in (("front", S - 1), ("rear", 0)):
            ring = rings[ring_idx]
            cap_v, cap_t = self._cap(ring, end)
            # cap_v: new interior verts; cap_t: triangles indexing ring (0..R-1) or new (R..)
            base = nv
            extra.append(cap_v)
            nv += len(cap_v)
            for t in cap_t:
                idx = tuple((ring_idx * R + k) if k < R else (base + k - R) for k in t)
                tris_all.append(idx)
                tri_cap.append(end)
        verts = np.vstack(extra)
        return dict(verts=verts, quads=quads, quad_piece=quad_piece, tris=tris_all, tri_cap=tri_cap,
                    S=S, R=R, stations=st)

    def _cap(self, ring, end):
        """Triangulate an end ring (with interior points) in the X/Z plane, then curve it with end_shift."""
        from mathutils.geometry import delaunay_2d_cdt
        from mathutils import Vector

        R = len(ring)
        xz = ring[:, [0, 2]]
        # interior grid points
        spacing = self.s["cap_spacing"]
        xmin, zmin = xz.min(axis=0)
        xmax, zmax = xz.max(axis=0)
        pts = []
        for x in np.arange(xmin + spacing * 0.5, xmax, spacing):
            for z in np.arange(zmin + spacing * 0.5, zmax, spacing * 0.8):
                pts.append((x, z))
        pts = np.array(pts) if pts else np.zeros((0, 2))
        if len(pts):
            inside = _points_in_poly(pts, xz)
            pts = pts[inside]
            # keep a margin from the outline
            if len(pts):
                d = _dist_to_poly(pts, xz)
                pts = pts[d > spacing * 0.45]
        allp = [Vector((float(p[0]), float(p[1]))) for p in xz] + [Vector((float(p[0]), float(p[1]))) for p in pts]
        edges = [(k, (k + 1) % R) for k in range(R)]
        res = delaunay_2d_cdt(allp, edges, [list(range(R))], 1, 1e-6)
        out_verts, out_edges, out_faces, orig_verts = res[0], res[1], res[2], res[3]
        # map output vertex -> our index (ring 0..R-1, interior R..)
        mapping = {}
        new_pos = []
        for oi, origs in enumerate(orig_verts):
            if origs:
                o = origs[0]
                mapping[oi] = o  # ring idx or interior idx (R + j)
            else:
                mapping[oi] = None
        # CDT may add vertices (should not with these inputs); handle anyway
        interior_idx = {}
        for oi, v in enumerate(out_verts):
            m = mapping[oi]
            if m is None or m >= R:
                interior_idx[oi] = R + len(new_pos)
                new_pos.append((v[0], v[1]))
        tris = []
        for f in out_faces:
            idx = [mapping[k] if (mapping[k] is not None and mapping[k] < R) else interior_idx[k] for k in f]
            if len(idx) == 3:
                tris.append(tuple(idx))
            else:
                for k in range(1, len(idx) - 1):
                    tris.append((idx[0], idx[k], idx[k + 1]))
        new_pos = np.array(new_pos) if new_pos else np.zeros((0, 2))
        yy0 = self.yF if end == "front" else self.yR
        if len(new_pos):
            ys = np.full(len(new_pos), yy0) + self.end_shift(new_pos[:, 0], new_pos[:, 1], np.full(len(new_pos), yy0))
            # gentle extra bulge of the cap centre
            u = new_pos[:, 0] / (np.abs(xz[:, 0]).max() + 1e-6)
            zc = 0.5 * (zmin + zmax)
            v = (new_pos[:, 1] - zc) / (0.5 * (zmax - zmin) + 1e-6)
            bul = self.s["nose_bulge" if end == "front" else "tail_bulge"] * np.clip(1 - u * u, 0, 1) * np.clip(1 - v * v, 0, 1) ** 0.5
            ys = ys + (bul if end == "front" else -bul)
            cap_v = np.stack([new_pos[:, 0], ys, new_pos[:, 1]], axis=1)
        else:
            cap_v = np.zeros((0, 3))
        return cap_v, tris


def _points_in_poly(pts, poly):
    x, y = pts[:, 0], pts[:, 1]
    inside = np.zeros(len(pts), bool)
    n = len(poly)
    j = n - 1
    for i in range(n):
        xi, yi = poly[i]
        xj, yj = poly[j]
        cond = ((yi > y) != (yj > y)) & (x < (xj - xi) * (y - yi) / (yj - yi + 1e-12) + xi)
        inside ^= cond
        j = i
    return inside


def _dist_to_poly(pts, poly):
    a = poly
    b = np.roll(poly, -1, axis=0)
    best = np.full(len(pts), np.inf)
    for k in range(len(poly)):
        ab = b[k] - a[k]
        t = np.clip(((pts - a[k]) @ ab) / (ab @ ab + 1e-12), 0, 1)
        proj = a[k] + t[:, None] * ab
        best = np.minimum(best, np.linalg.norm(pts - proj, axis=1))
    return best
