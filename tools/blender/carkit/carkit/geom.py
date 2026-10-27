"""Pure-numpy geometry helpers for the car kit: 1D profiles, 2D section curves, Coons patches.

Nothing in here imports bpy, so it can be unit-tested with plain Python.
"""
from __future__ import annotations

import math
import numpy as np


# --------------------------------------------------------------------------------------------
# 1D profiles (monotone cubic Hermite / PCHIP, constant extrapolation)
# --------------------------------------------------------------------------------------------
class Profile:
    """Smooth, overshoot-free curve through (x, y) control points. Call with a scalar or array."""

    def __init__(self, pts):
        pts = sorted(pts, key=lambda p: p[0])
        xs = np.array([p[0] for p in pts], float)
        ys = np.array([p[1] for p in pts], float)
        # merge duplicate x
        keep = np.concatenate([[True], np.diff(xs) > 1e-9])
        self.x, self.y = xs[keep], ys[keep]
        n = len(self.x)
        if n == 1:
            self.m = np.zeros(1)
            return
        h = np.diff(self.x)
        d = np.diff(self.y) / h
        m = np.zeros(n)
        m[0], m[-1] = d[0], d[-1]
        for k in range(1, n - 1):
            if d[k - 1] * d[k] <= 0:
                m[k] = 0.0
            else:
                w1 = 2 * h[k] + h[k - 1]
                w2 = h[k] + 2 * h[k - 1]
                m[k] = (w1 + w2) / (w1 / d[k - 1] + w2 / d[k])
        # flat ends read better on car silhouettes
        m[0] = 0.0 if n > 2 else m[0]
        m[-1] = 0.0 if n > 2 else m[-1]
        self.m = m

    def __call__(self, x):
        x = np.asarray(x, float)
        scalar = x.ndim == 0
        x = np.atleast_1d(x)
        if len(self.x) == 1:
            out = np.full_like(x, self.y[0])
        else:
            xc = np.clip(x, self.x[0], self.x[-1])
            k = np.clip(np.searchsorted(self.x, xc) - 1, 0, len(self.x) - 2)
            h = self.x[k + 1] - self.x[k]
            t = (xc - self.x[k]) / h
            t2, t3 = t * t, t * t * t
            h00 = 2 * t3 - 3 * t2 + 1
            h10 = t3 - 2 * t2 + t
            h01 = -2 * t3 + 3 * t2
            h11 = t3 - t2
            out = h00 * self.y[k] + h10 * h * self.m[k] + h01 * self.y[k + 1] + h11 * h * self.m[k + 1]
        return float(out[0]) if scalar else out


def smoothstep(e0, e1, x):
    t = np.clip((np.asarray(x, float) - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def bump(x, center, half_width):
    """Smooth cos^2 bump, 1 at center, 0 beyond half_width."""
    t = np.clip(np.abs(np.asarray(x, float) - center) / half_width, 0.0, 1.0)
    return np.cos(t * math.pi / 2) ** 2


def ellip_drop(y, y_end, extent_y, amount, power=2.0):
    """Quarter-ellipse falloff: 0 before (y_end - extent_y), `amount` at y_end, tangent vertical at y_end.
    `power` > 2 makes the corner squarer (superellipse)."""
    s = np.clip((np.asarray(y, float) - (y_end - extent_y)) / extent_y, 0.0, 1.0)
    return amount * (1.0 - (1.0 - s ** power) ** (1.0 / power))


# --------------------------------------------------------------------------------------------
# 2D section curve: key points + bulged spans + rounded corners, resampled to fixed counts
# --------------------------------------------------------------------------------------------
def _qbez(p0, c, p1, n=48):
    t = np.linspace(0, 1, n)[:, None]
    return (1 - t) ** 2 * p0 + 2 * (1 - t) * t * c + t ** 2 * p1


def _cbez(p0, c0, c1, p1, n=32):
    t = np.linspace(0, 1, n)[:, None]
    return (1 - t) ** 3 * p0 + 3 * (1 - t) ** 2 * t * c0 + 3 * (1 - t) * t ** 2 * c1 + t ** 3 * p1


def _arclen(poly):
    seg = np.linalg.norm(np.diff(poly, axis=0), axis=1)
    return np.concatenate([[0.0], np.cumsum(seg)])


def _resample(poly, n_seg):
    """Resample a dense polyline to n_seg equal-arc-length segments (n_seg + 1 points)."""
    s = _arclen(poly)
    if s[-1] < 1e-9:
        return np.repeat(poly[:1], n_seg + 1, axis=0)
    targets = np.linspace(0, s[-1], n_seg + 1)
    out = np.empty((n_seg + 1, 2))
    out[:, 0] = np.interp(targets, s, poly[:, 0])
    out[:, 1] = np.interp(targets, s, poly[:, 1])
    return out


def _cut_at(poly, dist, from_end=False):
    """Split a polyline at arc distance `dist` from its start (or end). Returns (point, unit tangent, piece)."""
    s = _arclen(poly)
    total = s[-1]
    d = total - dist if from_end else dist
    d = float(np.clip(d, 0.0, total))
    x = np.interp(d, s, poly[:, 0])
    y = np.interp(d, s, poly[:, 1])
    p = np.array([x, y])
    k = int(np.clip(np.searchsorted(s, d), 1, len(poly) - 1))
    t = poly[k] - poly[k - 1]
    t = t / (np.linalg.norm(t) + 1e-12)
    if from_end:
        piece = np.vstack([poly[s < d - 1e-9], p])
    else:
        piece = np.vstack([p, poly[s > d + 1e-9]])
    return p, t, piece


def section_curve(keys, ctrls, corner_cuts, counts):
    """Build a half cross-section polyline.

    keys:        (K+1, 2) key points (x, z) from bottom-centre to top-centre (counter-clockwise).
    ctrls:       list of K quadratic-Bezier control points (one per span), or None for a straight span.
    corner_cuts: list of K-1 cut-back distances for the interior corners (0 = sharp).
    counts:      list of 2K-1 segment counts: span0, corner1, span1, corner2, ..., spanK-1.
    Returns (pts (N+1, 2), seg_index (N,) piece id per segment).
    """
    keys = np.asarray(keys, float)
    K = len(keys) - 1
    spans = []
    for i in range(K):
        p0, p1 = keys[i], keys[i + 1]
        c = ctrls[i]
        if c is None:
            c = 0.5 * (p0 + p1)
        spans.append(_qbez(p0, np.asarray(c, float), p1))
    pieces = []
    cur = spans[0]
    for i in range(1, K):
        d = corner_cuts[i - 1]
        nxt = spans[i]
        la, lb = _arclen(cur)[-1], _arclen(nxt)[-1]
        d = min(d, 0.45 * la, 0.45 * lb)
        A, tA, cur_trim = _cut_at(cur, d, from_end=True)
        B, tB, nxt_trim = _cut_at(nxt, d, from_end=False)
        cosang = float(np.clip(np.dot(tA, tB), -1, 1))
        theta = math.acos(cosang)
        if theta < 1e-3:
            h = d * 2.0 / 3.0
        else:
            r = d / max(math.tan(theta / 2), 1e-6)
            h = 4.0 / 3.0 * math.tan(theta / 4) * r
        corner = _cbez(A, A + tA * h, B - tB * h, B)
        pieces.append(cur_trim)
        pieces.append(corner)
        cur = nxt_trim
    pieces.append(cur)
    assert len(pieces) == len(counts), (len(pieces), len(counts))
    out = [pieces[0][:1]]
    seg_id = []
    for pi, (piece, n) in enumerate(zip(pieces, counts)):
        rs = _resample(piece, n)
        out.append(rs[1:])
        seg_id += [pi] * n
    return np.vstack(out), np.array(seg_id)


def polyline_normals_ccw(pts):
    """Outward normals for a CCW open polyline (x right, z up). Ends use one-sided differences."""
    t = np.zeros_like(pts)
    t[1:-1] = pts[2:] - pts[:-2]
    t[0] = pts[1] - pts[0]
    t[-1] = pts[-1] - pts[-2]
    t /= np.linalg.norm(t, axis=1, keepdims=True) + 1e-12
    return np.stack([t[:, 1], -t[:, 0]], axis=1)


# --------------------------------------------------------------------------------------------
# Coons patch
# --------------------------------------------------------------------------------------------
def coons(bottom, top, left, right):
    """bottom/top: (a+1, 3) left->right; left/right: (b+1, 3) bottom->top. Returns (a+1, b+1, 3)."""
    a = len(bottom) - 1
    b = len(left) - 1
    u = np.linspace(0, 1, a + 1)[:, None, None]
    v = np.linspace(0, 1, b + 1)[None, :, None]
    B = bottom[:, None, :]
    T = top[:, None, :]
    L = left[None, :, :]
    R = right[None, :, :]
    P00, P10, P01, P11 = bottom[0], bottom[-1], top[0], top[-1]
    return ((1 - v) * B + v * T + (1 - u) * L + u * R
            - ((1 - u) * (1 - v) * P00 + u * (1 - v) * P10 + (1 - u) * v * P01 + u * v * P11))


def rounded_poly(points, radius, seg=4):
    """Round the corners of a closed 2D polygon (list of (x, y)). radius may be a scalar or per-corner list."""
    pts = np.asarray(points, float)
    n = len(pts)
    rad = radius if hasattr(radius, "__len__") else [radius] * n
    out = []
    for i in range(n):
        p_prev, p, p_next = pts[i - 1], pts[i], pts[(i + 1) % n]
        r = rad[i]
        if r <= 1e-6:
            out.append(p)
            continue
        a = p_prev - p
        b = p_next - p
        la, lb = np.linalg.norm(a), np.linalg.norm(b)
        a /= la
        b /= lb
        d = min(r, 0.49 * la, 0.49 * lb)
        A = p + a * d
        B = p + b * d
        for k in range(seg + 1):
            t = k / seg
            out.append((1 - t) ** 2 * A + 2 * (1 - t) * t * p + t ** 2 * B)
    return np.array(out)
