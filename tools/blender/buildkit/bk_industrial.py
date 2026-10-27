"""INDUSTRIAL: distribution warehouse on its lot - corrugated metal shed (low gable, ridge vents, clerestory)
or concrete tilt-up box (panel reveals, parapet). Loading docks with roller doors, dock seals, bumpers, lights
and a canopy; a grade-level drive-in door; two-storey office annex with the company sign; truck court with
trailer stripes; roof exhaust fans and skylights. Lot origin bottom-centre, street at -Y."""
import math
import bk_geo as G
from bk_arch import Building, ATLAS, STUCCO, FRAMES

SIDING = {"beige": (0.90, 0.84, 0.70), "grey": (0.78, 0.79, 0.80), "blue": (0.55, 0.66, 0.78),
          "white": (0.93, 0.93, 0.91), "sage": (0.70, 0.76, 0.66), "rust": (0.70, 0.45, 0.32)}


def warehouse(seed=0, **kw):
    B = Building("warehouse", seed, kw.get("name"))
    r = B.rng
    style = kw.get("style", r.choice(["metal", "tiltup", "metal"]))
    Wb = kw.get("bw", r.choice([110.0, 130.0, 150.0]))
    Db = kw.get("bd", r.choice([70.0, 80.0, 90.0]))
    H = kw.get("h", r.choice([30.0, 34.0]) if style == "metal" else r.choice([34.0, 38.0]))
    W, D = Wb + 30.0, Db + 86.0
    sid = SIDING[kw.get("siding", r.choice(list(SIDING)))]
    trim_c = r.choice([(0.12, 0.22, 0.42), (0.55, 0.08, 0.06), (0.15, 0.15, 0.16), (0.85, 0.85, 0.83)])
    B.spec = {"Walls": ("tex", "metal_siding", sid) if style == "metal" else ("tex", "precast", sid),
              "Walls2": ("tex", "cmu", (0.82, 0.8, 0.77)), "Trim": ("color", trim_c, 0.45, 0.5),
              "Accent": ("color", (0.95, 0.72, 0.08), 0.5, 0.0), "Frames": ("color", FRAMES["silver"], 0.3, 0.8),
              "Glass": ("glass", {"tint": (0.7, 0.8, 0.85), "dim": 0.6, "rough": 0.05, "metallic": 0.3}),
              "Roof": ("tex", "corrugated", (0.9, 0.9, 0.9)) if style == "metal" else ("tex", "roof_gravel", (1, 1, 1)),
              "Details": ("tex", "metal", (0.6, 0.62, 0.64)), "Doors": ("tex", "shutter", (0.85, 0.85, 0.85)),
              "Brand": ("atlas", "brands.png"), "Site": ("tex", "curb", (0.95, 0.95, 0.95)),
              "Asphalt": ("tex", "asphalt", (0.92, 0.92, 0.94)), "Paint": ("color", (0.92, 0.88, 0.5), 0.7, 0.0),
              "Neon": ("neon", (1.0, 0.85, 0.6)), "Grime": ("grime",), "WindowsLit": ("lit",),
              "Roof2": ("color", (0.08, 0.08, 0.08), 0.9, 0.0)}
    x0, x1 = -Wb / 2 + r.uniform(-6, 6), 0.0
    x1 = x0 + Wb
    y1 = D / 2 - 6.0
    y0 = y1 - Db
    Fs = B.facades(Wb, Db, x0, y0)
    wa, tr, dt, dr = B.b("Walls"), B.b("Trim"), B.b("Details"), B.b("Doors")
    dock_z = 4.4
    # ---- office annex (front-left corner, projecting forward)
    ow, od, oh = 34.0, 22.0, 24.0
    ox0, oy0 = x0 + 6.0, y0 - od
    # ---- front facade: docks
    F = Fs["front"]
    ops = []
    n_dock = kw.get("docks", max(3, int((Wb - ow - 30) // 16)))
    du_start = ow + 14.0
    dock_w, dock_h = 10.0, 11.0
    span_end = du_start
    for k in range(n_dock):
        u = du_start + k * 16.0
        if u + dock_w > F.W - 20:
            break
        span_end = u + dock_w
        ops.append((u, u + dock_w, dock_z, dock_z + dock_h))
        F.reveal(tr, u, u + dock_w, dock_z, dock_z + dock_h, 0.5, sides=(True, True, True, True))
        F.quad(dr, u, u + dock_w, dock_z, dock_z + dock_h, -0.5)
        # dock seal (black foam) + bumpers + light arm
        F.box(B.b("Roof2"), u - 1.2, u, 0.0, 1.8, dock_z - 0.5, dock_z + dock_h + 0.6)
        F.box(B.b("Roof2"), u + dock_w, u + dock_w + 1.2, 0.0, 1.8, dock_z - 0.5, dock_z + dock_h + 0.6)
        F.box(B.b("Roof2"), u - 1.2, u + dock_w + 1.2, 0.0, 1.8, dock_z + dock_h, dock_z + dock_h + 1.8)
        for bu in (u + 0.6, u + dock_w - 1.6):
            F.box(B.b("Roof2"), bu, bu + 1.0, 0.0, 0.8, dock_z - 2.4, dock_z - 0.2)
        G.hcylinder(dt, F.p(u + dock_w + 1.8, dock_z + 7.0, 0.1), F.p(u + dock_w + 1.8, dock_z + 7.0, 3.0), 0.12, seg=4)
        F.box(B.b("Neon"), u + dock_w + 1.3, u + dock_w + 2.3, 2.8, 3.6, dock_z + 6.6, dock_z + 7.4)
        B.grime(F, u - 1.2, u + dock_w + 1.2, 0.0, dock_z + 1.0, "base", n=1.85)
        B.grime(F, u, u + dock_w, dock_z + dock_h - 3.0, dock_z + dock_h + 2.0, "streak", n=0.04)
    # dock face (concrete below the doors) + dock canopy
    F.box(B.b("Walls2"), du_start - 4.0, span_end + 4.0, 0.0, 0.25, 0.0, dock_z, skip=("back",))
    F.box(tr, du_start - 4.0, span_end + 4.0, 0.0, 7.0, dock_z + dock_h + 3.0, dock_z + dock_h + 3.8)
    for u in (du_start - 3.0, span_end + 3.0):
        G.hcylinder(dt, F.p(u, dock_z + dock_h + 3.0, 6.6), F.p(u, dock_z + dock_h + 9.0, 0.1), 0.15, seg=4)
    # grade-level drive-in door with a ramp
    gu = F.W - 18.0
    ops.append((gu, gu + 14.0, 0.0, 14.0))
    F.reveal(tr, gu, gu + 14.0, 0.0, 14.0, 0.5, sides=(False, True, True, True))
    F.quad(dr, gu, gu + 14.0, 0.0, 14.0, -0.5)
    for bu in (gu - 1.5, gu + 15.5):
        bx, by, _ = F.p(bu, 0, 1.5)
        G.cylinder(B.b("Accent"), bx, by, 0, 4.0, 0.5, seg=8, caps=(False, True))
    # personnel door + stair to the dock level
    pu = du_start - 9.0
    ops.append((pu, pu + 3.6, dock_z, dock_z + 7.6))
    F.reveal(tr, pu, pu + 3.6, dock_z, dock_z + 7.6, 0.3)
    F.quad(B.b("Frames"), pu, pu + 3.6, dock_z, dock_z + 7.6, -0.3)
    F.box(B.b("Walls2"), pu - 1.0, pu + 4.6, 0.0, 4.0, 0.0, dock_z, skip=("back",))
    for k in range(5):
        F.box(B.b("Walls2"), pu + 4.6 + k * 1.0, pu + 5.6 + k * 1.0, 0.0, 4.0, 0.0, dock_z * (5 - k) / 5.5, skip=("back",))
    F.box(B.b("Accent"), pu - 1.0, pu + 4.6, 3.8, 4.0, dock_z, dock_z + 3.4, skip=("back",))
    # clerestory band (metal) / high windows (tilt-up)
    zc0, zc1 = H - 8.0, H - 5.0
    for side, FF in Fs.items():
        o2 = ops if side == "front" else []
        if style == "metal" and side in ("front", "back", "left", "right"):
            n = max(1, int((FF.W - 8) // 18))
            for k in range(n):
                u = 4 + (FF.W - 8) * (k + 0.5) / n
                o2.append((u - 6.0, u + 6.0, zc0, zc1))
                FF.reveal(tr, u - 6.0, u + 6.0, zc0, zc1, 0.3)
                B.glass(FF, u - 6.0, u + 6.0, zc0, zc1, -0.3, ATLAS["windows"]["spandrel"], lit=r.random() < 0.3)
        elif style == "tiltup" and side != "front":
            n = max(1, int((FF.W - 8) // 22))
            for k in range(n):
                u = 4 + (FF.W - 8) * (k + 0.5) / n
                o2.append((u - 3.0, u + 3.0, H - 12.0, H - 6.0))
                FF.reveal(tr, u - 3.0, u + 3.0, H - 12.0, H - 6.0, 0.6)
                B.glass(FF, u - 3.0, u + 3.0, H - 12.0, H - 6.0, -0.6, "office")
        if side == "back":
            FF.box(dr, FF.W * 0.3, FF.W * 0.3 + 4, -0.2, 0.15, 0, 8)
        FF.wall(wa, 4.0 if style == "metal" else 0.0, H, o2)
        if style == "metal":
            FF.wall(B.b("Walls2"), 0.0, 4.0, [o for o in o2 if o[2] < 4.0])
            FF.box(tr, 0, FF.W, 0.0, 0.3, 3.8, 4.3, skip=("back",))
        else:
            n = max(1, int(FF.W // 24))
            for k in range(1, n):
                u = FF.W * k / n
                FF.box(B.b("Roof2"), u - 0.15, u + 0.15, -0.05, 0.02, 0.0, H, skip=("back",))
            FF.box(tr, 0, FF.W, 0.0, 0.05, H - 3.2, H - 2.2, skip=("back",))
        B.grime(FF, 0, FF.W, 0, 6.0, "base")
        B.grime(FF, 0, FF.W, H - 9.0, H, "soot")
        for u in (0.8, FF.W - 0.8):
            FF.box(dt, u - 0.4, u + 0.4, 0.0, 0.8, 0.0, H - 0.5)
        for k in range(max(1, int(FF.W // 30))):
            u = FF.W * (k + 0.5) / max(1, int(FF.W // 30))
            FF.box(B.b("Neon"), u - 0.6, u + 0.6, 0.0, 0.8, 16.0, 17.0)
    # corner trims
    for (cx, cy) in ((x0, y0), (x1, y0), (x1, y1), (x0, y1)):
        G.box(tr, cx - 0.6, cy - 0.6, 0.0, cx + 0.6, cy + 0.6, H + 0.3, skip=("bottom",))
    # ---- roof
    rf = B.b("Roof")
    if style == "metal":
        pitch = 1.0 / 12.0
        ridge = G.gable_roof(rf, x0, y0, x1, y1, H, pitch=pitch, overhang=1.2, ridge_axis="x", fascia=tr, fascia_h=0.8,
                             gable_wall=wa)
        nv = int(Wb // 14)
        yc = (y0 + y1) / 2
        for k in range(nv):
            vx = x0 + Wb * (k + 0.5) / nv
            G.box(dt, vx - 2.5, yc - 1.5, ridge - 0.3, vx + 2.5, yc + 1.5, ridge + 2.2)
            G.box(dt, vx - 3.0, yc - 2.0, ridge + 2.2, vx + 3.0, yc + 2.0, ridge + 2.6)
        for k in range(int(Wb // 22)):
            sx = x0 + Wb * (k + 0.5) / int(Wb // 22)
            for yy in (y0 + Db * 0.25, y0 + Db * 0.75):
                zz = H + (Db / 2 - abs(yy - yc)) * pitch + 0.05
                G.quad(B.b("Frames"), (sx - 2.5, yy - 4.0, zz - 0.25 * (1 if yy < yc else -1)), (sx + 2.5, yy - 4.0, zz - 0.25 * (1 if yy < yc else -1)),
                       (sx + 2.5, yy + 4.0, zz + 0.4 * (1 if yy < yc else -1)), (sx - 2.5, yy + 4.0, zz + 0.4 * (1 if yy < yc else -1)))
        top = ridge + 2.6
    else:
        loop = B.rect_loop(Wb, Db, x0, y0)
        G.sweep(tr, loop, [(0.0, H), (0.3, H), (0.3, H + 0.6), (-0.8, H + 0.6), (-0.8, H - 3.0)], closed=True)
        G.cap(rf, G.offset_loop(loop, -0.8), H - 3.0)
        for k in range(int(Wb // 20)):
            for j in range(int(Db // 24)):
                sx = x0 + Wb * (k + 0.5) / int(Wb // 20)
                sy = y0 + Db * (j + 0.5) / int(Db // 24)
                if (k + j) % 2 == 0:
                    G.box(B.b("Frames"), sx - 2.5, sy - 4.0, H - 3.0, sx + 2.5, sy + 4.0, H - 1.8)
                else:
                    G.cylinder(dt, sx, sy, H - 3.0, H - 0.6, 1.6, seg=10, caps=(False, True))
                    G.cylinder(dt, sx, sy, H - 0.6, H + 0.4, 2.2, seg=10, caps=(True, True), r1=0.6)
        B.hvac(x0 + 14, y0 + 10, H - 3.0, w=6, d=4, h=3)
        top = H + 0.6
    # ---- office annex
    Fo = B.facades(ow, od, ox0, oy0)
    for side, FF in Fo.items():
        if side == "back":
            continue
        o2 = []
        if side == "front":
            st = {"cells": "office", "depth": 0.8, "bay": 5.0, "transom": 1.0, "kick": 1.0}
            B.storefront(FF, 3.0, FF.W - 3.0, 0.0, 10.0, st, o2, door=FF.W * 0.3)
            B.storefront(FF, 3.0, FF.W - 3.0, 12.5, 21.0, dict(st, kick=1.4), o2, door=None)
        else:
            B.storefront(FF, 3.0, FF.W - 3.0, 12.5, 21.0, {"cells": "office", "depth": 0.8, "bay": 5.0, "transom": 1.0, "kick": 1.0}, o2)
        FF.wall(B.b("Walls2") if style == "metal" else wa, 0, oh, o2)
        B.grime(FF, 0, FF.W, 0, 4.0, "base")
    ol = B.rect_loop(ow, od, ox0, oy0)
    G.sweep(tr, ol, [(0.0, oh), (0.4, oh), (0.4, oh + 0.8), (-0.8, oh + 0.8), (-0.8, oh - 1.2)], closed=True)
    G.cap(B.b("Roof2"), G.offset_loop(ol, -0.8), oh - 1.2)
    name = "wide%d" % kw.get("brand", r.choice([4, 5, 6]))
    B.brand(Fo["front"], ow / 2, oh - 2.4, name, 3.2, n=0.0, depth=0.3, frame="Trim")
    Fo["front"].box(tr, 0.0, ow, 0.0, 4.0, 10.6, 11.2)
    # ---- lot: truck court, trailer stripes, car stalls, walk
    G.box(B.b("Site"), ox0 - 1.0, oy0 - 5.0, -0.5, ox0 + ow + 1.0, oy0, 0.6, skip=("bottom",))
    court0 = -D / 2 + 6.0
    G.quad(B.b("Asphalt"), (-W / 2, court0, 0.05), (W / 2, court0, 0.05), (W / 2, y0, 0.05), (-W / 2, y0, 0.05))
    pt = B.b("Paint")
    for k in range(n_dock + 1):
        u = du_start + k * 16.0 - 3.0
        xx = F.p(u, 0)[0]
        if xx > x0 + span_end + 4:
            break
        G.quad(pt, (xx - 0.25, y0 - 50.0, 0.09), (xx + 0.25, y0 - 50.0, 0.09), (xx + 0.25, y0 - 2.0, 0.09), (xx - 0.25, y0 - 2.0, 0.09))
    if (oy0 - 5.0 - court0) > 24:
        B.parking(-W / 2 + 2.0, court0, ox0 + ow + 2.0, oy0 - 5.0, rows=("-y",), stall_d=18.0, z=0.07)
    G.quad(B.b("Site"), (-W / 2, -D / 2, 0.04), (W / 2, -D / 2, 0.04), (W / 2, court0, 0.04), (-W / 2, court0, 0.04))
    # dumpsters by the side
    for k in range(2):
        dx = x1 + 3.0
        dy = y0 + 8.0 + k * 8.0
        G.box(B.b("Trim"), dx, dy, 0.0, dx + 5.0, dy + 7.0, 4.6)
        G.box(B.b("Roof2"), dx - 0.1, dy - 0.1, 4.6, dx + 5.2, dy + 7.1, 5.0)
    B.footprint, B.height = (W, D), top
    B.tags = {"district": "industrial", "style": style, "docks": n_dock, "building": [Wb, Db, H]}
    return B


ARCHS = {"warehouse": warehouse}
