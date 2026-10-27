"""SUBURBS: LA-style single-family houses on a full lot - ranch / Spanish / two-storey tract styles.
Stucco walls, clay-tile or shingle hip/gable roofs with fascia + soffit + gutters, attached two-car garage with
a sectional door and driveway, covered entry, white vinyl sliders with surrounds, AC condenser, block wall or
wood fence around the back yard, optional pool, front lawn + mailbox. Lot origin bottom-centre, street at -Y."""
import math
import bk_geo as G
from bk_arch import Building, ATLAS, STUCCO, FRAMES

DOOR_COLORS = [(0.30, 0.17, 0.09), (0.45, 0.07, 0.06), (0.05, 0.05, 0.06), (0.08, 0.25, 0.28), (0.85, 0.85, 0.82),
               (0.20, 0.24, 0.16)]


def _win(B, F, u0, u1, z0, z1, ops, kind="slider"):
    st = {"depth": 0.45, "mullion": "v" if kind.startswith("slider") else ("grid" if kind == "grid" else "t"), "header": None,
          "surround": 0.55 if B.tags.get("surrounds") else None, "cells": "res", "sill": True, "frame_w": 0.24,
          "frame_d": 0.3, "ac": 0.0, "shutters": B.tags.get("shutters", False) and kind != "slider_big"}
    B.window(F, u0, u1, z0, z1, st, ops)


def house(seed=0, **kw):
    B = Building("house", seed, kw.get("name"))
    r = B.rng
    style = kw.get("style", r.choice(["ranch", "spanish", "tract2", "ranch", "spanish"]))
    stories = kw.get("floors", 2 if style == "tract2" else (2 if (style == "spanish" and r.random() < 0.3) else 1))
    W = kw.get("W", r.choice([60.0, 64.0, 70.0]))
    D = kw.get("D", r.choice([96.0, 104.0, 110.0]))
    roofmat = kw.get("roof", "clay" if style == "spanish" else r.choice(["clay", "shingle", "shingle"]))
    roofform = kw.get("roof_form", "hip" if style != "ranch" or r.random() < 0.5 else "gable")
    tint = STUCCO[kw.get("stucco", r.choice(list(STUCCO)))]
    fence = kw.get("fence", r.choice(["block", "wood", "block"]))
    pool = kw.get("pool", r.random() < 0.45)
    garage_side = kw.get("garage", r.choice(["left", "right"]))
    door_rgb = DOOR_COLORS[r.randrange(len(DOOR_COLORS))]
    B.tags = {"district": "suburbs", "style": style, "floors": stories, "roof": roofmat, "surrounds": style != "ranch",
              "shutters": kw.get("shutters", style in ("ranch", "tract2") and r.random() < 0.4)}
    porch = kw.get("porch", style == "ranch" and stories == 1 and r.random() < 0.65)
    B.spec = {"Walls": ("tex", "stucco", tint), "Walls2": ("tex", "cmu" if fence == "block" else "wood_fence",
                                                             (0.88, 0.85, 0.8) if fence == "block" else (0.9, 0.85, 0.8)),
              "Trim": ("tex", "plaster", (0.95, 0.94, 0.91)), "Frames": ("color", FRAMES["white"], 0.4, 0.0),
              "Accent": ("color", door_rgb, 0.45, 0.0), "Glass": ("glass",),
              "Roof": ("tex", "roof_clay" if roofmat == "clay" else "roof_shingle", (1, 1, 1)),
              "Details": ("tex", "metal", (0.75, 0.76, 0.77)), "Doors": ("tex", "shutter", (1.0, 1.0, 1.0)),
              "Site": ("tex", "curb", (1.0, 1.0, 1.0)), "Lawn": ("tex", "grass", (0.8, 0.98, 0.65)),
              "Water": ("water", (0.05, 0.42, 0.52)), "Neon": ("neon", (1.0, 0.8, 0.5)), "Grime": ("grime",),
              "WindowsLit": ("lit",)}
    B.lit_ratio = 0.3
    sb = kw.get("setback", 26.0)
    fh1, fh2 = 12.0, 11.0
    eave = fh1 + (fh2 if stories == 2 else 0.0)
    GW, GD = kw.get("garage_w", 23.0), 24.0   # 23 = two-car, 13 = one-car (narrow lots)
    HW = min(W - GW - 7.0, kw.get("hw", r.choice([36.0, 40.0, 44.0])))
    HD = kw.get("hd", r.choice([34.0, 38.0]))
    gfwd = kw.get("garage_fwd", r.choice([0.0, 0.0, 6.0]))
    total = HW + GW
    x_left = -total / 2 + (r.uniform(-2, 2))
    if garage_side == "left":
        gx0, mx0 = x_left, x_left + GW
    else:
        mx0, gx0 = x_left, x_left + HW
    mx1, gx1 = mx0 + HW, gx0 + GW
    hy0 = -D / 2 + sb
    gy0 = hy0 - gfwd
    wa, tr, fr = B.b("Walls"), B.b("Trim"), B.b("Frames")
    # ---------------- main volume
    Fm = B.facades(HW, HD, mx0, hy0)
    door_u = HW * r.choice([0.3, 0.42, 0.62]) if garage_side == "right" else HW * r.choice([0.38, 0.58, 0.7])
    for side, F in Fm.items():
        ops = []
        if side == ("right" if garage_side == "right" else "left"):
            # shared wall with the garage: only the part not covered by it gets windows
            if stories == 2:
                for t in (0.3, 0.7):
                    _win(B, F, F.W * t - 2.5, F.W * t + 2.5, fh1 + 2.8, fh1 + 8.6, ops)
            F.wall(wa, 0, eave, ops)
            continue
        n = max(1, int(F.W // 13))
        for k in range(n):
            uc = F.W * (k + 0.5) / n
            if side == "front" and abs(uc - door_u) < 7.5:
                continue
            big = side == "back" and k == n // 2
            if big:   # sliding patio door to the yard
                _win(B, F, uc - 4.5, uc + 4.5, 0.6, 8.6, ops, "slider_big")
            else:
                _win(B, F, uc - 3.0, uc + 3.0, 3.4, 8.8, ops, "grid" if style == "spanish" and side == "front" else "slider")
            if stories == 2:
                _win(B, F, uc - 2.6, uc + 2.6, fh1 + 2.8, fh1 + 8.4, ops)
        if side == "front":
            # entry door, recessed porch
            du0, du1 = door_u - 2.0, door_u + 2.0
            ops.append((du0 - 2.4, du1 + 2.4, 0.0, 10.0 if style != "spanish" else 9.0))
            F.reveal(wa, du0 - 2.4, du1 + 2.4, 0.0, 10.0 if style != "spanish" else 9.0, 4.0, sides=(False, True, True, True))
            F.quad(wa, du0 - 2.4, du1 + 2.4, 0.0, 10.0 if style != "spanish" else 9.0, -4.0)
            F.box(B.b("Accent"), du0, du1, -4.0, -3.8, 0.4, 8.0, skip=("back",))
            F.box(fr, du0 - 0.35, du1 + 0.35, -4.0, -3.65, 0.4, 8.35, skip=("back",))
            F.box(B.b("Details"), du1 - 0.9, du1 - 0.6, -3.8, -3.5, 3.6, 4.2)
            F.box(B.b("Neon"), du1 + 1.0, du1 + 1.6, -3.95, -3.5, 7.0, 8.0)
            G.box(B.b("Site"), *F.p(du0 - 2.4, 0, -4.0)[:2], 0.0, *F.p(du1 + 2.4, 0, 0.0)[:2], 0.7, skip=("bottom",))
            if style == "spanish":   # arched-look entry: keystone + tile hood
                F.box(tr, du0 - 2.9, du1 + 2.9, 0.0, 0.4, 9.0, 10.2, skip=("back",))
            if style == "tract2" or stories == 2:
                F.box(tr, du0 - 3.2, du1 + 3.2, 0.0, 4.4, 10.4, 11.0)
        F.wall(wa, 0, eave, ops)
        B.grime(F, 0, F.W, 0, 3.5, "base")
        if stories == 2:
            F.box(tr, 0, F.W, 0.0, 0.35, fh1 - 0.2, fh1 + 0.6, skip=("back",))
    # ---------------- garage
    Fg = B.facades(GW, GD, gx0, gy0)
    gh = 11.0
    for side, F in Fg.items():
        ops = []
        if side == "front":
            ops.append((2.0, GW - 2.0, 0.0, 8.6))
            F.reveal(tr, 2.0, GW - 2.0, 0.0, 8.6, 0.6, sides=(False, True, True, True))
            dr = B.b("Doors")
            F.quad(dr, 2.0, GW - 2.0, 0.0, 8.6, -0.6)
            for k in range(1, 4):   # sectional panel joints
                F.box(dr, 2.0, GW - 2.0, -0.6, -0.45, k * 8.6 / 4 - 0.08, k * 8.6 / 4 + 0.08, skip=("back",))
            for u in (1.0, GW - 1.0):
                F.box(B.b("Neon"), u - 0.3, u + 0.3, 0.0, 0.5, 9.2, 10.0)
        elif (side == "right" and garage_side == "left") or (side == "left" and garage_side == "right"):
            hidden_from = gfwd
            if hidden_from <= 0.01:
                continue
        elif side == "back" or side in ("left", "right"):
            if side in ("left", "right") and r.random() < 0.6:
                F.box(B.b("Accent"), F.W / 2 - 1.8, F.W / 2 + 1.8, -0.2, 0.15, 0.0, 8.0)
        F.wall(wa, 0, gh, ops)
        B.grime(F, 0, F.W, 0, 3.0, "base")
    # ---------------- roofs (fascia/soffit in Trim, gutters in Details)
    roof = B.b("Roof")
    pitch = 0.36 if roofmat == "clay" else 0.42
    ov = 1.8
    if roofform == "hip":
        G.hip_roof(roof, mx0, hy0, mx1, hy0 + HD, eave, pitch=pitch, overhang=ov, fascia=tr, fascia_h=0.9, soffit=tr)
        G.hip_roof(roof, gx0, gy0, gx1, gy0 + GD, gh, pitch=pitch, overhang=ov, fascia=tr, fascia_h=0.9, soffit=tr,
                   ridge_axis="y" if GD > GW else "x")
    else:
        G.gable_roof(roof, mx0, hy0, mx1, hy0 + HD, eave, pitch=pitch, overhang=ov, ridge_axis="x", fascia=tr,
                     soffit=tr, gable_wall=wa)
        G.gable_roof(roof, gx0, gy0, gx1, gy0 + GD, gh, pitch=pitch, overhang=ov, ridge_axis="y", fascia=tr,
                     soffit=tr, gable_wall=wa)
    if porch:   # covered front porch: slab, square posts, shed roof tucked under the main eave
        pw0, pw1 = max(mx0 + 1.0, mx0 + door_u - 12.0), min(mx1 - 1.0, mx0 + door_u + 12.0)
        pd = 8.0
        G.box(B.b("Site"), pw0, hy0 - pd, 0.0, pw1, hy0, 0.8, skip=("bottom",))
        for px in (pw0 + 0.6, pw1 - 0.6, (pw0 + pw1) / 2 if pw1 - pw0 > 18 else None):
            if px is not None:
                G.box(tr, px - 0.45, hy0 - pd + 0.4, 0.8, px + 0.45, hy0 - pd + 1.3, eave - 1.6)
        G.box(tr, pw0, hy0 - pd + 0.2, eave - 1.6, pw1, hy0 - pd + 1.4, eave - 0.9)
        G.poly(roof, [(pw0 - 0.6, hy0 - pd - 0.6, eave - 1.0), (pw1 + 0.6, hy0 - pd - 0.6, eave - 1.0),
                      (pw1 + 0.6, hy0 - ov + 0.2, eave + 0.25), (pw0 - 0.6, hy0 - ov + 0.2, eave + 0.25)], uv_along=(1, 0, 0))
        G.poly(tr, [(pw0 - 0.6, hy0 - ov + 0.2, eave - 1.6), (pw1 + 0.6, hy0 - ov + 0.2, eave - 1.6),
                    (pw1 + 0.6, hy0 - pd - 0.6, eave - 1.6), (pw0 - 0.6, hy0 - pd - 0.6, eave - 1.6)])
        B.tags["porch"] = True
    # gutters + downspouts on the front eaves
    dt = B.b("Details")
    for (x0, x1, y, z) in ((mx0, mx1, hy0, eave), (gx0, gx1, gy0, gh)):
        G.box(dt, x0 - ov, y - ov - 0.6, z - 0.9, x1 + ov, y - ov - 0.05, z - 0.3)
        for x in (x0 + 0.3, x1 - 0.3):
            G.box(dt, x - 0.25, y - 0.45, 0.0, x + 0.25, y + 0.05 - 0.4, z - 0.6)
    if r.random() < 0.5:   # chimney
        cx = mx0 + HW * r.choice([0.2, 0.8])
        G.box(wa, cx - 2.2, hy0 + HD - 6.0, eave - 2.0, cx + 2.2, hy0 + HD - 1.0, eave + HD * pitch * 0.5 + 6.0, skip=("bottom",))
        G.box(tr, cx - 2.6, hy0 + HD - 6.4, eave + HD * pitch * 0.5 + 6.0, cx + 2.6, hy0 + HD - 0.6, eave + HD * pitch * 0.5 + 6.7)
    if r.random() < 0.4:   # satellite dish
        G.cylinder(dt, mx1 - 6.0, hy0 + HD - 4.0, eave + 2.0, eave + 4.0, 0.12, seg=5)
        G.cylinder(dt, mx1 - 6.0, hy0 + HD - 4.6, eave + 4.0, eave + 4.4, 1.3, seg=10, caps=(True, True), r1=1.5)
    # AC condenser on the open side
    acx = mx1 + 2.6 if garage_side == "left" else mx0 - 2.6
    G.box(dt, acx - 1.6, hy0 + HD * 0.5 - 1.6, 0.0, acx + 1.6, hy0 + HD * 0.5 + 1.6, 3.0)
    G.cylinder(dt, acx, hy0 + HD * 0.5, 3.0, 3.1, 1.3, seg=10)
    # ---------------- lot: driveway, walk, lawn, fences, pool, mailbox
    site, lawn = B.b("Site"), B.b("Lawn")
    dx0, dx1 = gx0 + 1.0, gx1 - 1.0
    G.quad(site, (dx0, -D / 2, 0.06), (dx1, -D / 2, 0.06), (dx1, gy0, 0.06), (dx0, gy0, 0.06))
    wx = mx0 + door_u
    if garage_side == "left":
        walk = [(dx1, hy0 - 10.0), (wx + 2.0, hy0 - 10.0), (wx + 2.0, hy0 - 4.0), (wx - 2.0, hy0 - 4.0), (wx - 2.0, hy0 - 6.0), (dx1, hy0 - 6.0)]
        G.quad(site, (dx1, hy0 - 10.0, 0.06), (wx + 2.0, hy0 - 10.0, 0.06), (wx + 2.0, hy0 - 6.0, 0.06), (dx1, hy0 - 6.0, 0.06))
        G.quad(site, (wx - 2.0, hy0 - 6.0, 0.06), (wx + 2.0, hy0 - 6.0, 0.06), (wx + 2.0, hy0 - 4.0, 0.06), (wx - 2.0, hy0 - 4.0, 0.06))
    else:
        G.quad(site, (wx - 2.0, hy0 - 10.0, 0.06), (dx0, hy0 - 10.0, 0.06), (dx0, hy0 - 6.0, 0.06), (wx - 2.0, hy0 - 6.0, 0.06))
        G.quad(site, (wx - 2.0, hy0 - 6.0, 0.06), (wx + 2.0, hy0 - 6.0, 0.06), (wx + 2.0, hy0 - 4.0, 0.06), (wx - 2.0, hy0 - 4.0, 0.06))
    # lawn: whole lot minus the driveway (two strips + back)
    yb = max(hy0 + HD, gy0 + GD)
    for (a, b_) in ((-W / 2, dx0), (dx1, W / 2)):
        if b_ - a > 0.5:
            G.quad(lawn, (a, -D / 2, 0.03), (b_, -D / 2, 0.03), (b_, yb, 0.03), (a, yb, 0.03))
    G.quad(lawn, (-W / 2, yb, 0.03), (W / 2, yb, 0.03), (W / 2, D / 2, 0.03), (-W / 2, D / 2, 0.03))
    # fence/wall around the back yard (from the house corners to the lot edge and along the back)
    fw = B.b("Walls2")
    fh = 6.5
    yf = hy0 + HD * 0.6
    segs = [((-W / 2 + 0.5, yf), (-W / 2 + 0.5, D / 2 - 0.5)), ((-W / 2 + 0.5, D / 2 - 0.5), (W / 2 - 0.5, D / 2 - 0.5)),
            ((W / 2 - 0.5, D / 2 - 0.5), (W / 2 - 0.5, yf)),
            ((-W / 2 + 0.5, yf), (min(mx0, gx0) - 0.0, yf)), ((max(mx1, gx1), yf), (W / 2 - 0.5, yf))]
    for (a, b_) in segs:
        if abs(a[0] - b_[0]) + abs(a[1] - b_[1]) < 1.0:
            continue
        x0, x1 = sorted((a[0], b_[0]))
        y0, y1 = sorted((a[1], b_[1]))
        G.box(fw, x0 - 0.35, y0 - 0.35, 0.0, x1 + 0.35, y1 + 0.35, fh, skip=("bottom",))
        if fence == "block":
            G.box(tr, x0 - 0.5, y0 - 0.5, fh, x1 + 0.5, y1 + 0.5, fh + 0.4)
        else:
            L = max(x1 - x0, y1 - y0)
            for k in range(int(L // 8) + 1):
                px = x0 + (x1 - x0) * k * 8 / max(L, 1e-3)
                py = y0 + (y1 - y0) * k * 8 / max(L, 1e-3)
                G.box(fw, px - 0.45, py - 0.45, 0.0, px + 0.45, py + 0.45, fh + 0.4)
    if pool:
        px0, px1 = -12.0 + r.uniform(-4, 4), 12.0 + r.uniform(-4, 4)
        py0 = yb + 10.0
        py1 = min(D / 2 - 8.0, py0 + 16.0)
        if py1 - py0 > 9:
            G.box(site, px0 - 4.0, py0 - 4.0, 0.0, px1 + 4.0, py1 + 4.0, 0.25, skip=("bottom",))
            G.box(tr, px0 - 1.0, py0 - 1.0, 0.25, px1 + 1.0, py1 + 1.0, 0.55, skip=("bottom",))
            G.quad(B.b("Water"), (px0, py0, 0.6), (px1, py0, 0.6), (px1, py1, 0.6), (px0, py1, 0.6))
            B.tags["pool"] = True
    # mailbox at the curb
    mx = dx1 + 3.0 if garage_side == "left" else dx0 - 3.0
    G.box(dt, mx - 0.2, -D / 2 + 1.5, 0.0, mx + 0.2, -D / 2 + 1.9, 3.6)
    G.box(B.b("Accent"), mx - 0.7, -D / 2 + 1.0, 3.6, mx + 0.7, -D / 2 + 2.6, 4.8)
    top = eave + (min(HW, HD) / 2 + ov) * pitch
    B.footprint, B.height = (W, D), top
    return B


ARCHS = {"house": house}
