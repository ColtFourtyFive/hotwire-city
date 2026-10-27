"""HILLS: modern Vinewood-style hillside mansion. Stone-clad plinth that reaches below grade (base_depth) so it
can sit on a slope, a floor-to-ceiling glass ground floor, a cantilevered white upper volume with ribbon
windows and a timber-slat screen, thin overhanging roof slabs with soffit lights, glass-balustrade terraces,
an infinity pool on the view side, side garage + drive. View side = -Y (downhill)."""
import math
import bk_geo as G
from bk_arch import Building, ATLAS, FRAMES


def _glass_wall(B, F, u0, u1, z0, z1, n=-0.6, bay=6.0, cells="res", mullion=0.3):
    """Floor-to-ceiling glazing with slim black mullions."""
    fr = B.b("Frames")
    k = max(1, round((u1 - u0) / bay))
    for i in range(k):
        a, b_ = u0 + (u1 - u0) * i / k, u0 + (u1 - u0) * (i + 1) / k
        rect = ATLAS["windows"][cells] if cells in ATLAS["windows"] else cells
        B.glass(F, a, b_, z0, z1, n, rect if isinstance(rect, list) else cells)
    for i in range(k + 1):
        u = u0 + (u1 - u0) * i / k
        F.box(fr, max(u0, u - mullion / 2), min(u1, u + mullion / 2), n, n + 0.25, z0, z1, skip=("back",))
    F.box(fr, u0, u1, n, n + 0.25, z0, z0 + 0.4, skip=("back",))
    F.box(fr, u0, u1, n, n + 0.25, z1 - 0.4, z1, skip=("back",))


def _balustrade(B, pts, z, h=3.6):
    """Frameless glass balustrade along a polyline (Clear role) with a slim top rail."""
    cl, fr = B.b("Clear"), B.b("Frames")
    for i in range(len(pts) - 1):
        a, b_ = pts[i], pts[i + 1]
        G.quad(cl, (a[0], a[1], z), (b_[0], b_[1], z), (b_[0], b_[1], z + h), (a[0], a[1], z + h))
        G.quad(cl, (b_[0], b_[1], z), (a[0], a[1], z), (a[0], a[1], z + h), (b_[0], b_[1], z + h))
        G.hcylinder(fr, (a[0], a[1], z + h), (b_[0], b_[1], z + h), 0.12, seg=4)


def mansion(seed=0, **kw):
    B = Building("mansion", seed, kw.get("name"))
    r = B.rng
    W = kw.get("W", r.choice([130.0, 140.0, 150.0]))
    D = kw.get("D", r.choice([110.0, 120.0]))
    base_depth = kw.get("base_depth", r.choice([12.0, 16.0, 20.0]))
    stone = kw.get("stone", r.choice(["marble", "granite", "concrete_board"]))
    slats = kw.get("slats", r.random() < 0.75)
    cant_side = kw.get("cantilever", r.choice([-1, 1]))
    B.spec = {"Walls": ("tex", "stucco", (0.96, 0.96, 0.94)), "Walls2": ("tex", stone, (0.92, 0.9, 0.86)),
              "Walls3": ("tex", "wood_slats", (0.95, 0.85, 0.75)), "Trim": ("tex", "plaster", (0.97, 0.97, 0.96)),
              "Frames": ("color", FRAMES["black"], 0.35, 0.6), "Glass": ("glass", {"tint": (0.85, 0.9, 0.92), "dim": 0.7,
                                                                                  "rough": 0.03, "metallic": 0.35}),
              "Clear": ("clear",),
              "Roof": ("tex", "roof_gravel", (0.9, 0.9, 0.9)), "Details": ("tex", "metal", (0.65, 0.66, 0.68)),
              "Accent": ("color", (0.12, 0.12, 0.13), 0.5, 0.0), "Site": ("tex", "pavers", (1.0, 0.98, 0.95)),
              "Lawn": ("tex", "grass", (0.8, 0.98, 0.65)), "Water": ("water", (0.04, 0.45, 0.58)),
              "Doors": ("tex", "wood_fence", (0.6, 0.5, 0.42)), "Neon": ("neon", (1.0, 0.82, 0.55)),
              "Grime": ("grime",), "WindowsLit": ("lit",)}
    B.lit_ratio = 0.55
    B.base_depth = base_depth
    wa, w2, w3, tr, fr = B.b("Walls"), B.b("Walls2"), B.b("Walls3"), B.b("Trim"), B.b("Frames")
    # ---- plinth (retaining podium) with a stepped lower terrace on the view side
    px0, px1 = -W / 2 + 6.0, W / 2 - 6.0
    py0, py1 = -D / 2 + 22.0, D / 2 - 6.0
    G.box(w2, px0, py0, -base_depth, px1, py1, 0.0, skip=("bottom",))
    ly0 = py0 - 14.0
    lz = -base_depth * 0.5
    G.box(w2, px0 + 10.0, ly0, -base_depth, px1 - 10.0, py0, lz, skip=("bottom",))
    G.quad(B.b("Site"), (px0 + 10.2, ly0 + 0.2, lz + 0.02), (px1 - 10.2, ly0 + 0.2, lz + 0.02), (px1 - 10.2, py0 - 0.1, lz + 0.02), (px0 + 10.2, py0 - 0.1, lz + 0.02))
    _balustrade(B, [(px0 + 10.2, py0), (px0 + 10.2, ly0 + 0.2), (px1 - 10.2, ly0 + 0.2), (px1 - 10.2, py0)], lz)
    # deck on top of the plinth
    G.quad(B.b("Site"), (px0, py0, 0.03), (px1, py0, 0.03), (px1, py1, 0.03), (px0, py1, 0.03))
    # ---- ground floor glass pavilion
    gw, gd, gh = kw.get("gw", r.choice([64.0, 72.0])), 34.0, 13.0
    gx0 = -gw / 2 - cant_side * 6.0
    gy0 = py0 + 26.0
    Fg = B.facades(gw, gd, gx0, gy0)
    for side, F in Fg.items():
        if side == "front":
            _glass_wall(B, F, 0.0, F.W - 14.0 if cant_side > 0 else F.W, 0.0, gh, n=-0.6)
            if cant_side > 0:
                F.wall(w2, 0.0, gh, u0=F.W - 14.0, u1=F.W)
            F.reveal(tr, 0.0, F.W - 14.0 if cant_side > 0 else F.W, 0.0, gh, 0.6, sides=(False, False, True, False))
        elif side == "back":
            ops = []
            F.wall(w2, 0.0, gh, [(F.W * 0.4, F.W * 0.4 + 8.0, 0.0, 10.0)])
            F.quad(B.b("Doors"), F.W * 0.4, F.W * 0.4 + 8.0, 0.0, 10.0, -0.4)
            F.reveal(tr, F.W * 0.4, F.W * 0.4 + 8.0, 0.0, 10.0, 0.4, sides=(False, True, True, True))
        else:
            _glass_wall(B, F, 2.0, F.W * 0.55, 0.0, gh, n=-0.6, bay=7.0)
            F.wall(w2, 0.0, gh, [(2.0, F.W * 0.55, 0.0, gh)])
    G.box(tr, gx0 - 0.5, gy0 - 0.5, gh, gx0 + gw + 0.5, gy0 + gd + 0.5, gh + 1.2)
    # ---- upper volume, cantilevered
    uw, ud, uh = gw + 10.0, 30.0, 12.0
    ux0 = gx0 + (gw - uw) / 2 + cant_side * 16.0
    uy0 = gy0 - 6.0
    uz = gh + 1.2
    Fu = B.facades(uw, ud, ux0, uy0)
    for side, F in Fu.items():
        ops = []
        if side == "front":
            rib0, rib1 = 4.0, F.W - (22.0 if slats else 4.0)
            ops.append((rib0, rib1, uz + 2.5, uz + uh - 2.0))
            _glass_wall(B, F, rib0, rib1, uz + 2.5, uz + uh - 2.0, n=-0.8, bay=8.0, cells="res")
            F.reveal(tr, rib0, rib1, uz + 2.5, uz + uh - 2.0, 0.8)
            if slats:
                F.box(w3, F.W - 20.0, F.W - 2.0, 0.0, 0.6, uz + 0.6, uz + uh - 0.6, skip=("back",))
                for k in range(1, 18):
                    u = F.W - 20.0 + k * 1.0
                    F.box(w3, u - 0.18, u + 0.18, 0.6, 1.1, uz + 0.6, uz + uh - 0.6, skip=("back",))
        elif side in ("left", "right"):
            ops.append((F.W * 0.3, F.W * 0.7, uz + 2.0, uz + uh - 2.0))
            _glass_wall(B, F, F.W * 0.3, F.W * 0.7, uz + 2.0, uz + uh - 2.0, n=-0.6, bay=6.0, cells="res")
        else:
            for t in (0.2, 0.5, 0.8):
                ops.append((F.W * t - 4.0, F.W * t + 4.0, uz + 4.0, uz + uh - 3.0))
                _glass_wall(B, F, F.W * t - 4.0, F.W * t + 4.0, uz + 4.0, uz + uh - 3.0, n=-0.5, bay=8.0, cells="res")
        F.wall(wa, uz, uz + uh, ops)
        B.grime(F, 0.0, F.W, uz + uh - 3.5, uz + uh, "soot", n=0.04)
    # underside of the cantilever
    G.quad(wa, (ux0, uy0 + ud, uz), (ux0 + uw, uy0 + ud, uz), (ux0 + uw, uy0, uz), (ux0, uy0, uz))
    # roof slab (thin, overhanging) + soffit lights + parapet-free flat roof
    ov = 5.0
    rz = uz + uh
    G.box(tr, ux0 - ov, uy0 - ov, rz, ux0 + uw + ov * 0.6, uy0 + ud + 2.0, rz + 1.4)
    G.cap(B.b("Roof"), [(ux0 - ov + 0.6, uy0 - ov + 0.6), (ux0 + uw + ov * 0.6 - 0.6, uy0 - ov + 0.6),
                        (ux0 + uw + ov * 0.6 - 0.6, uy0 + ud + 1.4), (ux0 - ov + 0.6, uy0 + ud + 1.4)], rz + 1.42)
    for k in range(int(uw // 8)):
        lx = ux0 + uw * (k + 0.5) / int(uw // 8)
        G.box(B.b("Neon"), lx - 0.5, uy0 - ov + 1.0, rz - 0.05, lx + 0.5, uy0 - ov + 2.0, rz, skip=("top",))
    for k in range(int(gw // 8)):
        lx = gx0 + gw * (k + 0.5) / int(gw // 8)
        if not (ux0 <= lx <= ux0 + uw):
            continue
        G.box(B.b("Neon"), lx - 0.5, uy0 + 0.6, uz - 0.05, lx + 0.5, uy0 + 1.6, uz, skip=("top",))
    # roof terrace over the part of the ground floor not covered by the upper box
    if cant_side > 0:
        tx0, tx1 = gx0, ux0
    else:
        tx0, tx1 = ux0 + uw, gx0 + gw
    if tx1 - tx0 > 4:
        _balustrade(B, [(tx0 + 0.3, gy0 + 0.3), (tx1 - 0.3, gy0 + 0.3)], gh + 1.2)
    # mechanical on the roof (hidden from the street by the slab edge)
    B.hvac(ux0 + uw * 0.7, uy0 + ud * 0.6, rz + 1.4, w=5, d=3.5, h=2.4)
    # ---- infinity pool + deck furniture on the view side
    pw = min(gw - 6.0, kw.get("pool_w", r.choice([40.0, 48.0, 56.0])))
    pd = 14.0
    pcx = gx0 + gw / 2 + r.uniform(-6, 6)
    pp0, pp1 = pcx - pw / 2, pcx + pw / 2
    G.box(B.b("Site"), pp0 - 1.2, py0 + 2.0, 0.03, pp1 + 1.2, py0 + pd + 3.2, 0.55, skip=("bottom",))
    G.quad(B.b("Water"), (pp0, py0 + 3.0, 0.56), (pp1, py0 + 3.0, 0.56), (pp1, py0 + pd + 2.0, 0.56), (pp0, py0 + pd + 2.0, 0.56))
    G.box(B.b("Accent"), pp0, py0 - 0.05, -3.0, pp1, py0 + 0.05, 0.4, skip=("bottom", "back"))   # dark overflow edge
    for k in range(4):
        cx = pp0 + 4.0 + k * 6.0
        if cx > pp1 - 2:
            break
        cy = py0 + pd + 8.0
        G.box(B.b("Details"), cx - 1.3, cy - 3.2, 0.0, cx + 1.3, cy + 3.2, 1.4)
        G.quad(B.b("Details"), (cx - 1.3, cy + 1.6, 1.4), (cx + 1.3, cy + 1.6, 1.4), (cx + 1.3, cy + 3.4, 3.6), (cx - 1.3, cy + 3.4, 3.6))
    _balustrade(B, [(px0 + 0.3, py0 + 0.3), (pp0 - 1.5, py0 + 0.3)], 0.0)
    _balustrade(B, [(pp1 + 1.5, py0 + 0.3), (px1 - 0.3, py0 + 0.3)], 0.0)
    # deck lights along the plinth edge
    for k in range(10):
        lx = px0 + (px1 - px0) * (k + 0.5) / 10
        G.box(B.b("Neon"), lx - 0.4, py0 - 0.25, -1.4, lx + 0.4, py0 - 0.05, -0.9)
    # ---- garage + drive on the side away from the cantilever
    gside = -cant_side
    gx = (px1 - 30.0) if gside > 0 else px0
    gyb = py1 - 30.0
    Fgr = B.facades(30.0, 28.0, gx, gyb)
    for side, F in Fgr.items():
        if side == ("left" if gside > 0 else "right"):
            F.wall(wa, 0.0, 11.0, [(4.0, 24.0, 0.0, 9.0)])
            F.quad(B.b("Doors"), 4.0, 24.0, 0.0, 9.0, -0.5)
            F.reveal(tr, 4.0, 24.0, 0.0, 9.0, 0.5, sides=(False, True, True, True))
        else:
            F.wall(w2 if side == "front" else wa, 0.0, 11.0)
    G.box(tr, gx - 2.0, gyb - 2.0, 11.0, gx + 32.0, gyb + 30.0, 12.2)
    dx_out = gx - 1.0 if gside > 0 else gx + 31.0
    edge = -W / 2 if gside < 0 else W / 2
    G.quad(B.b("Site"), (min(edge, dx_out), gyb + 2.0, 0.05), (max(edge, dx_out), gyb + 2.0, 0.05), (max(edge, dx_out), gyb + 26.0, 0.05), (min(edge, dx_out), gyb + 26.0, 0.05))
    # lawn around the rest of the lot at grade (front strip below the lower terrace is left to the terrain)
    G.quad(B.b("Lawn"), (-W / 2, py1, 0.02), (W / 2, py1, 0.02), (W / 2, D / 2, 0.02), (-W / 2, D / 2, 0.02))
    B.footprint, B.height = (W, D), rz + 1.4
    B.tags = {"district": "hills", "base_depth": base_depth, "cantilever": cant_side, "slats": slats}
    return B


ARCHS = {"mansion": mansion}
