"""BEACH: Ocean-Drive style art-deco / streamline-moderne hotel. Symmetric facade, central tower bay with
vertical fins and a blade sign, window eyebrows, racing-stripe bands, porthole windows, raised cafe terrace
with umbrellas, neon outlines for night (Neon role). White base + one sun-bleached pastel accent."""
import math
import bk_geo as G
from bk_arch import Building, ATLAS, PASTELS, FRAMES


def _mute(c, k=0.45):
    """Sun-bleach a pastel towards warm white (keeps GTA realism instead of candy colours)."""
    w = (0.95, 0.94, 0.9)
    return tuple(c[i] * (1 - k) + w[i] * k for i in range(3))


def deco(seed=0, **kw):
    B = Building("deco", seed, kw.get("name"))
    r = B.rng
    W = kw.get("W", r.choice([60.0, 66.0, 72.0, 80.0]))
    D = kw.get("D", r.choice([48.0, 54.0]))
    floors = kw.get("floors", r.randint(2, 4))
    gf, fh = 15.0, 12.0
    top = gf + floors * fh
    accent_name = kw.get("accent", r.choice(["mint", "pink", "aqua", "lemon", "lavender", "peach", "sky"]))
    acc = _mute(PASTELS[accent_name], 0.35)
    base = (0.96, 0.95, 0.91) if r.random() < 0.7 else _mute(PASTELS[accent_name], 0.7)
    neon_c = {"mint": (0.2, 1.0, 0.6), "pink": (1.0, 0.2, 0.55), "aqua": (0.1, 0.9, 1.0), "lemon": (1.0, 0.85, 0.2),
              "lavender": (0.6, 0.35, 1.0), "peach": (1.0, 0.45, 0.2), "sky": (0.2, 0.6, 1.0)}[accent_name]
    B.spec = {"Walls": ("tex", "stucco", base), "Walls2": ("tex", "terrazzo", (1.0, 1.0, 1.0)),
              "Trim": ("tex", "plaster", (0.97, 0.96, 0.93)), "Accent": ("color", acc, 0.6, 0.0),
              "Frames": ("color", FRAMES[r.choice(["white", "silver", "white"])], 0.35, 0.3), "Glass": ("glass",),
              "Roof": ("tex", "roof_tar", (1, 1, 1)), "Details": ("tex", "metal", (0.7, 0.72, 0.74)),
              "Awning": ("atlas", "awnings.png"), "Brand": ("atlas", "brands.png", 0.35, 0.0),
              "Neon": ("neon", neon_c), "Grime": ("grime",), "WindowsLit": ("lit",)}
    B.footprint, B.height = (W, D), top
    Fs = B.facades(W, D)
    loop = B.rect_loop(W, D)
    wa, ac, tr, fr = B.b("Walls"), B.b("Accent"), B.b("Trim"), B.b("Frames")
    tw = kw.get("tower_w", 14.0)
    tower_rise = kw.get("tower_rise", r.choice([12.0, 16.0, 20.0]))
    style = {"depth": 0.6, "mullion": "t", "header": None, "ac": 0.12, "cells": "res", "sill": True, "frame_w": 0.28}
    for side, F in Fs.items():
        ops_up, ops_gf = [], []
        front = side == "front"
        # window groups: symmetric pairs left/right of the centre (front), regular on sides
        if front:
            half = (F.W - tw) / 2
            ng = max(1, int((half - 4.0) // 13.0))
            gw = (half - 4.0) / ng
            groups = []
            for k in range(ng):
                a = 3.0 + k * gw + 1.2
                groups.append((a, a + gw - 2.4))
                b0 = F.W - 3.0 - (k + 1) * gw + 1.2
                groups.append((b0, b0 + gw - 2.4))
        else:
            ng = max(1, int((F.W - 6.0) // 12.0))
            gw = (F.W - 6.0) / ng
            groups = [(3.0 + k * gw + 1.5, 3.0 + (k + 1) * gw - 1.5) for k in range(ng)]
        for fi in range(floors):
            z0 = gf + fi * fh + 2.6
            z1 = z0 + 6.2
            for (a, b_) in groups:
                # double window with a centre mullion: one opening, frame subdivides
                B.window(F, a, b_, z0, z1, dict(style, mullion="cross" if b_ - a > 7 else "t"), ops_up)
                # eyebrow: thin projecting ledge over the window group (the deco signature)
                F.box(tr, a - 1.2, b_ + 1.2, 0.0, 2.2, z1 + 0.6, z1 + 1.0)
                if side != "back" and r.random() < 0.3:
                    B.grime(F, a, b_, z0 - 4.0, z0 - 0.4, "streak", n=0.03)
            # racing stripes between floors on the outer bays
            if side != "back":
                for (ua, ub) in ((0.0, 2.6), (F.W - 2.6, F.W)):
                    for k in range(3):
                        zz = gf + fi * fh + 1.2 + k * 0.9
                        F.box(ac, ua, ub, 0.0, 0.18, zz, zz + 0.45, skip=("back",))
        # ground floor
        if front:
            st = {"cells": "diner", "depth": 0.8, "bay": 5.0, "transom": 2.0, "kick": 1.0}
            for (a, b_) in groups:
                B.storefront(F, a, b_, 2.0, gf - 2.0, st, ops_gf, door=None)
            B.storefront(F, (F.W - tw) / 2 + 2.5, (F.W + tw) / 2 - 2.5, 2.0, gf - 1.0, dict(st, cells="lobby"), ops_gf,
                         door=F.W / 2)
        elif side in ("left", "right"):
            for (a, b_) in groups[:2]:
                B.window(F, a, b_, 4.0, gf - 3.0, dict(style, mullion="cross", ac=0), ops_gf)
        else:
            F.box(B.b("Details"), F.W / 2 - 2.0, F.W / 2 + 2.0, -0.2, 0.15, 0, 8.0)
        F.wall(wa, 0, top, ops_up + ops_gf)
        B.grime(F, 0, F.W, 0, 6.0, "base")
    # base band + floor line + parapet
    B.belt(loop, 0.0, h=2.0, out=0.3, role="Accent")
    B.belt(loop, gf - 1.0, h=1.0, out=0.5)
    G.sweep(tr, loop, [(0.0, top), (0.0, top + 3.0), (0.5, top + 3.0), (0.5, top + 3.6), (-0.9, top + 3.6), (-0.9, top)], closed=True)
    G.cap(B.b("Roof"), G.offset_loop(loop, -0.9), top + 0.02)
    G.sweep(B.b("Neon"), loop, [(0.5, top + 3.6), (0.7, top + 3.6), (0.7, top + 3.85), (0.5, top + 3.85)], closed=True)
    # ---- central tower bay (projecting 1.5) with fins + blade sign + portholes
    F = Fs["front"]
    u0, u1 = (W - tw) / 2, (W + tw) / 2
    zt = top + tower_rise
    F.box(wa, u0, u1, 0.0, 1.5, gf - 1.0, zt, skip=("back",))
    for k, inset in enumerate((0.0, 2.0, 4.0)):
        zz = zt + k * 2.2
        F.box(tr, u0 + inset - 0.3, u1 - inset + 0.3, -1.0, 1.9, zz, zz + 2.2 if k < 2 else zz + 1.2)
    G.box(B.b("Neon"), *F.p(u0 - 0.3, 0, 1.9)[:2], zt + 6.6 - 0.05, *F.p(u1 + 0.3, 0, 1.95)[:2], zt + 6.6 + 0.25)
    nfin = 3
    for k in range(nfin):
        u = u0 + tw * (k + 1) / (nfin + 1)
        F.box(ac, u - 0.35, u + 0.35, 1.5, 3.0, gf + 3.0, zt - 1.0, skip=("back",))
        F.box(B.b("Neon"), u - 0.12, u + 0.12, 3.0, 3.15, gf + 3.0, zt - 1.0, skip=("back",))
    for fi in range(floors):
        zc = gf + fi * fh + 6.0
        for uc in (u0 + 2.8, u1 - 2.8):
            n = 10
            pts = [F.p(uc + 1.4 * math.cos(2 * math.pi * k / n), zc + 1.4 * math.sin(2 * math.pi * k / n), 1.52) for k in range(n)]
            rect = ATLAS["windows"]["res4"]
            uvs = [(rect[0] + (rect[2] - rect[0]) * (0.5 + 0.5 * math.cos(2 * math.pi * k / n)),
                    rect[1] + (rect[3] - rect[1]) * (0.5 + 0.5 * math.sin(2 * math.pi * k / n))) for k in range(n)]
            B.b("Glass").add(pts, [tuple(range(n))], [uvs])
            ring = [F.p(uc + 1.7 * math.cos(2 * math.pi * k / n), zc + 1.7 * math.sin(2 * math.pi * k / n), 1.52) for k in range(n)]
            for k in range(n):
                a, b_ = pts[k], pts[(k + 1) % n]
                c, d = ring[(k + 1) % n], ring[k]
                G.quad(fr, a, d, c, b_)
    # blade sign on the tower face (vertical name)
    blade = "blade%d" % kw.get("blade", r.randrange(4))
    bu0, bv0, bu1, bv1 = ATLAS["brands"][blade]
    bh = min(zt - gf - 4.0, 30.0)
    bwid = bh * (bu1 - bu0) / (bv1 - bv0)
    zb = zt - 2.0 - bh
    # the blade sits between the fins, proud of them
    F.box(ac, W / 2 - bwid / 2 - 0.4, W / 2 + bwid / 2 + 0.4, 1.5, 3.1, zb - 0.4, zb + bh + 0.4)
    F.quad(B.b("Brand"), W / 2 - bwid / 2, W / 2 + bwid / 2, zb, zb + bh, 3.12, uv=(bu0, bv0, bu1, bv1))
    # tower roof + flagpole
    # tower behind the facade plane (rises above the roof)
    G.box(wa, u0 - W / 2, -D / 2 + 1.5, top, u1 - W / 2, -D / 2 + 8.0, zt, skip=("bottom", "-y"))
    G.cylinder(B.b("Details"), 0.0, -D / 2 + 4.5, zt + 6.0, zt + 18.0, 0.15, seg=6)
    # ---- raised cafe terrace with low wall, steps and umbrellas
    td = 12.0
    G.box(B.b("Walls2"), -W / 2 + 1.0, -D / 2 - td, 0.0, W / 2 - 1.0, -D / 2, 2.0, skip=("bottom",))
    Ft = G.Facade((-W / 2 + 1.0, -D / 2 - td, 0), (1, 0, 0), (0, -1, 0), W - 2.0)
    sw = 10.0
    for (a, b_) in ((0.0, (W - 2.0) / 2 - sw / 2), ((W - 2.0) / 2 + sw / 2, W - 2.0)):
        Ft.box(wa, a, b_, 0.0, 0.8, 2.0, 4.6, skip=("bottom",))
        Ft.box(tr, a - 0.1, b_ + 0.1, -0.1, 0.9, 4.6, 5.0)
        Ft.box(ac, a, b_, -0.02, 0.0, 0.3, 1.2, skip=("back",))
    for k in range(3):
        Ft.box(B.b("Walls2"), (W - 2.0) / 2 - sw / 2, (W - 2.0) / 2 + sw / 2, -0.0 - (k + 1) * 1.2, 0.0 - k * 1.2, 0.0, 2.0 - (k + 1) * 0.66, skip=("bottom",))
    G.box(wa, -W / 2 + 1.0, -D / 2 - td, 2.0, -W / 2 + 1.8, -D / 2, 4.6)
    G.box(wa, W / 2 - 1.8, -D / 2 - td, 2.0, W / 2 - 1.0, -D / 2, 4.6)
    aw = B.b("Awning")
    awk = list(ATLAS["awnings"].keys())
    colr = r.choice(awk[:6])
    au0, av0, au1, av1 = ATLAS["awnings"][colr]
    nu = max(2, int((W - 24) // 14))
    for k in range(nu):
        ux = -W / 2 + 8.0 + (W - 16.0) * (k + 0.5) / nu
        if abs(ux) < sw / 2 + 3:
            continue
        uy = -D / 2 - td / 2
        G.cylinder(B.b("Details"), ux, uy, 2.0, 9.6, 0.12, seg=6)
        n = 8
        rr = 4.2
        for j in range(n):
            a0, a1 = 2 * math.pi * j / n, 2 * math.pi * (j + 1) / n
            pa = (ux + rr * math.cos(a0), uy + rr * math.sin(a0), 8.2)
            pb = (ux + rr * math.cos(a1), uy + rr * math.sin(a1), 8.2)
            uu = au0 + (j % 2) * 0.0625
            aw.add([pa, pb, (ux, uy, 9.9)], [(0, 1, 2)], [[(uu, av0), (uu + 0.06, av0), (uu + 0.03, av1)]])
            aw.add([pb, pa, (ux, uy, 9.9)], [(0, 1, 2)], [[(uu + 0.06, av0), (uu, av0), (uu + 0.03, av1)]])  # underside
        G.cylinder(B.b("Details"), ux, uy, 2.0, 4.8, 1.6, seg=10, caps=(False, True), r1=1.6)
    B.tags = {"district": "beach", "floors": floors, "accent": accent_name}
    return B


ARCHS = {"deco": deco}
