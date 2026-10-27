"""DOWNTOWN: glass / steel office towers - podium with stone lobby, stacked shaft segments with setbacks,
four facade systems (curtain, ribbon, grid, fins), crowns (mechanical screen, spire, stepped, slant, helipad)
and rooftop mechanical (cooling towers, HVAC, exhaust stacks, window-washing gantry, antennas)."""
import math
import bk_geo as G
from bk_arch import Building, ATLAS, FRAMES, ACCENTS

GLASS_TINTS = {"blue": (0.55, 0.72, 0.86), "green": (0.55, 0.80, 0.74), "bronze": (0.80, 0.66, 0.50),
               "grey": (0.66, 0.70, 0.74), "silver": (0.78, 0.82, 0.86)}
PANELS = [("concrete", (0.92, 0.92, 0.9)), ("granite", (0.85, 0.82, 0.78)), ("precast", (0.9, 0.88, 0.84)),
          ("facade_tiles", (1.0, 1.0, 1.0)), ("marble", (1.0, 1.0, 1.0))]


def _bays(width, target):
    n = max(1, round(width / target))
    return n, width / n


def segment(B, x0, y0, x1, y1, z0, floors, fh, style, bay, last=False):
    """One shaft segment (rectangular). Returns top z."""
    z1 = z0 + floors * fh
    Fs = B.facades(x1 - x0, y1 - y0, x0, y0)
    fr, gl, wa, ac, tr = B.b("Frames"), B.b("Glass"), B.b("Walls"), B.b("Accent"), B.b("Trim")
    for side, F in Fs.items():
        n, bw = _bays(F.W, bay)
        room = 2 if bw < 6.5 else 1
        gn = -0.45                      # glass plane (behind the mullion faces)
        for k in range(floors):
            zf = z0 + k * fh
            if style in ("curtain", "fins"):
                spand = 3.2
                for i in range(0, n, room):
                    ua, ub = i * bw, min(F.W, (i + room) * bw)
                    B.glass(F, ua, ub, zf + spand, zf + fh, gn, "office")
                    F.quad(gl, ua, ub, zf, zf + spand, gn, uv=ATLAS["windows"]["spandrel"])
                F.box(fr, 0, F.W, gn, 0.18, zf - 0.18, zf + 0.18, skip=("back", "left", "right"))
                F.box(fr, 0, F.W, gn, 0.05, zf + spand - 0.1, zf + spand + 0.1, skip=("back", "left", "right"))
            elif style == "ribbon":
                sb, st = 1.6, 3.0          # spandrel band below / above the floor line
                for i in range(0, n, room):
                    ua, ub = i * bw, min(F.W, (i + room) * bw)
                    B.glass(F, ua, ub, zf + st, zf + fh - sb, gn, "office")
                F.box(wa, -0.3, F.W + 0.3, gn, 0.55, zf - sb, zf + st, skip=("back",))
            elif style == "grid":
                sp_h = 3.4
                for i in range(n):
                    B.glass(F, i * bw, (i + 1) * bw, zf + sp_h, zf + fh, gn - 0.6, "office")
                F.box(wa, 0, F.W, gn - 0.6, 0.9, zf, zf + sp_h, skip=("back", "left", "right"))
        top_cap = 0.6
        # verticals
        for i in range(n + 1):
            u = i * bw
            if style == "grid":
                w = 1.5 if i in (0, n) else 1.1
                ua, ub = max(0, u - w / 2), min(F.W, u + w / 2)
                F.box(wa, ua, ub, gn - 0.6, 1.25, z0, z1, skip=("back",))
            elif style == "fins":
                if i in (0, n):
                    F.box(fr, max(0, u - 0.4), min(F.W, u + 0.4), gn, 0.3, z0, z1, skip=("back",))
                else:
                    F.box(ac, u - 0.22, u + 0.22, gn, 2.1, z0, z1, skip=("back",))
            else:
                w = 0.4 if i not in (0, n) else 0.9
                F.box(fr, max(0, u - w / 2), min(F.W, u + w / 2), gn, 0.22, z0, z1, skip=("back",))
        if style == "ribbon":
            for i in range(1, n):
                if i % room == 0:
                    F.box(fr, i * bw - 0.18, i * bw + 0.18, gn, gn + 0.25, z0, z1, skip=("back",))
        if style == "grid":
            for i in range(n):
                um = (i + 0.5) * bw
                F.box(fr, um - 0.15, um + 0.15, gn - 0.6, gn - 0.35, z0, z1, skip=("back",))
    # floor-edge slab / coping at the top of this segment
    loop = B.rect_loop(x1 - x0, y1 - y0, x0, y0)
    G.sweep(tr, loop, [(0.0, z1), (0.6, z1), (0.6, z1 + 1.4), (-1.0, z1 + 1.4)], closed=True)
    G.sweep(tr, loop, [(-1.0, z1 + 1.4), (-1.0, z1 + 0.2)], closed=True)
    G.cap(B.b("Roof"), G.offset_loop(loop, -1.0), z1 + 0.2)
    for side, F in Fs.items():
        B.grime(F, 0, F.W, z1 - 6, z1 + 1.4, "soot", n=0.7)
    return z1


def cooling_tower(B, x, y, z, w=10, d=8, h=7):
    dt = B.b("Details")
    G.box(dt, x - w / 2, y - d / 2, z, x + w / 2, y + d / 2, z + h, skip=("bottom",))
    n = 2 if w >= 9 else 1
    for k in range(n):
        cx = x - w / 2 + w * (k + 0.5) / n
        G.cylinder(dt, cx, y, z + h, z + h + 1.6, min(w / n, d) * 0.42, seg=14, caps=(False, True))
    # louvre lines on the long faces
    for t in (0.25, 0.45, 0.65):
        G.box(dt, x - w / 2 - 0.08, y - d / 2 - 0.08, z + h * t, x + w / 2 + 0.08, y + d / 2 + 0.08, z + h * t + 0.25, skip=("top", "bottom"))


def gantry(B, x0, x1, y, z, h=4.0):
    dt = B.b("Details")
    G.box(dt, x0, y - 0.3, z, x1, y + 0.3, z + 0.4)
    G.box(dt, x0, y + 2.7, z, x1, y + 3.3, z + 0.4)
    xm = (x0 + x1) / 2
    G.box(dt, xm - 1.5, y - 0.5, z + 0.4, xm + 1.5, y + 3.5, z + h)
    G.box(dt, xm - 0.4, y - 7.0, z + h - 1.0, xm + 0.4, y + 3.0, z + h - 0.2)


def tower(seed=0, **kw):
    B = Building("tower", seed, kw.get("name"))
    r = B.rng
    W = kw.get("W", r.choice([56, 64, 72, 80]))
    D = kw.get("D", r.choice([56, 64, 72]))
    floors = kw.get("floors", r.randint(18, 40))
    style = kw.get("style", r.choice(["curtain", "curtain", "ribbon", "grid", "fins"]))
    crown = kw.get("crown", r.choice(["mech", "mech", "spire", "stepped", "slant", "helipad"]))
    fh = 13.0
    gtint = GLASS_TINTS[kw.get("glass", r.choice(list(GLASS_TINTS)))]
    panel, ptint = PANELS[r.randrange(len(PANELS))] if style in ("ribbon", "grid") else ("concrete", (0.9, 0.9, 0.9))
    stone = kw.get("stone", r.choice(["granite", "marble", "granite"]))
    frame = {"silver": (0.42, 0.44, 0.46), "black": (0.05, 0.05, 0.055), "bronze": (0.2, 0.15, 0.1),
             "graphite": (0.16, 0.17, 0.18)}[kw.get("frame", r.choice(["silver", "black", "bronze", "graphite"]))]
    accent = kw.get("accent_rgb", (0.55, 0.57, 0.6) if r.random() < 0.6 else frame)
    B.spec = {"Walls": ("tex", panel, ptint), "Walls2": ("tex", stone, (0.95, 0.95, 0.95)),
              "Trim": ("tex", "concrete", (0.92, 0.92, 0.9)), "Frames": ("color", frame, 0.3, 0.85),
              "Accent": ("color", accent, 0.35, 0.85),
              "Glass": ("glass", {"tint": gtint, "dim": 0.5, "rough": 0.03, "metallic": 0.7}),
              "Roof": ("tex", "roof_gravel", (0.95, 0.95, 0.95)), "Details": ("tex", "metal", (0.62, 0.64, 0.66)),
              "Brand": ("atlas", "brands.png", 0.4, 0.2), "Sign": ("atlas", "signs.png"), "Grime": ("grime",),
              "Neon": ("neon", (1.0, 0.15, 0.1)), "WindowsLit": ("lit",), "Site": ("tex", "pavers", (0.95, 0.95, 0.95))}
    B.lit_ratio = 0.45
    # ---- podium (stone + glass lobby)
    pod_floors = r.choice([2, 2, 3])
    lobby_h = 26.0
    ph = lobby_h + (pod_floors - 2) * fh
    Fs = B.facades(W, D)
    st, fr = B.b("Walls2"), B.b("Frames")
    for side, F in Fs.items():
        ops = []
        n, bw = _bays(F.W - 8, 9.0)
        for i in range(n):
            ua, ub = 4 + i * bw + 0.9, 4 + (i + 1) * bw - 0.9
            ops.append((ua, ub, 0.0, lobby_h - 3.0))
            F.reveal(st, ua, ub, 0.0, lobby_h - 3.0, 1.6, sides=(False, True, True, True))
            cell = "lobby0" if side == "front" else "office"
            B.glass(F, ua, ub, 0.0, lobby_h - 3.0, -1.6, ATLAS["windows"]["lobby0"] if side == "front" else cell, lit=True)
            for t in (0.0, 0.5, 1.0):
                u = ua + (ub - ua) * t
                F.box(fr, max(ua, u - 0.25), min(ub, u + 0.25), -1.6, -1.2, 0.0, lobby_h - 3.0, skip=("back",))
            F.box(fr, ua, ub, -1.6, -1.2, lobby_h - 7.0, lobby_h - 6.6, skip=("back",))
            if side == "front" and i in (n // 2 - (1 - n % 2), n // 2):
                F.box(fr, ua + 0.6, ub - 0.6, -1.6, -1.1, 0.0, 9.0, skip=("back",))
                F.box(fr, ua + 0.6, ub - 0.6, -1.6, -1.1, 0.0, 0.6, skip=("back",))
        if pod_floors > 2:
            for i in range(n):
                ua, ub = 4 + i * bw + 1.2, 4 + (i + 1) * bw - 1.2
                zf = lobby_h + 2.6
                ops.append((ua, ub, zf, zf + fh - 4.6))
                F.reveal(st, ua, ub, zf, zf + fh - 4.6, 1.0)
                B.glass(F, ua, ub, zf, zf + fh - 4.6, -1.0, "office")
        F.wall(st, 0, ph, ops)
        B.grime(F, 0, F.W, 0, 6.0, "base")
    pl = B.rect_loop(W, D)
    G.sweep(B.b("Trim"), pl, [(0.0, lobby_h - 3.0), (0.5, lobby_h - 3.0), (0.5, lobby_h - 1.8), (0.0, lobby_h - 1.8)])
    G.sweep(B.b("Trim"), pl, [(0.0, ph), (0.7, ph), (0.7, ph + 1.2), (-0.8, ph + 1.2), (-0.8, ph + 0.2)])
    G.cap(B.b("Roof"), G.offset_loop(pl, -0.8), ph + 0.2)
    # entrance canopy + name board
    F = Fs["front"]
    cw = min(34.0, W * 0.45)
    F.box(B.b("Accent"), W / 2 - cw / 2, W / 2 + cw / 2, 0.0, 9.0, 15.0, 16.2)
    F.box(B.b("Neon"), W / 2 - cw / 2 + 1, W / 2 + cw / 2 - 1, 1.0, 8.5, 14.9, 15.0, skip=("top",))
    for u in (W / 2 - cw / 2 + 1.5, W / 2 + cw / 2 - 1.5):
        F.box(B.b("Details"), u - 0.15, u + 0.15, 8.6, 8.9, 15.0, 22.0)
    name_key = "wide%d" % kw.get("name_idx", r.choice([0, 1, 2, 3]))
    B.brand(F, W / 2, 18.0, name_key, 3.6, n=0.0, depth=0.0, frame="Walls2")
    # plaza strip in front (part of the lot, under the canopy)
    # ---- shaft with setbacks
    inset = r.choice([5.0, 6.0, 8.0])
    x0, y0, x1, y1 = -W / 2 + inset, -D / 2 + inset, W / 2 - inset, D / 2 - inset
    z = ph + 0.2
    n_set = kw.get("setbacks", r.choice([0, 1, 1, 2]))
    rem = floors - pod_floors
    cuts = sorted(r.sample(range(int(rem * 0.45), int(rem * 0.85)), n_set)) if n_set and rem > 8 else []
    bay = r.choice([5.0, 5.5, 6.0]) if style != "grid" else r.choice([6.5, 7.5])
    seg_starts = [0] + cuts + [rem]
    for si in range(len(seg_starts) - 1):
        nf = seg_starts[si + 1] - seg_starts[si]
        if nf <= 0:
            continue
        z = segment(B, x0, y0, x1, y1, z, nf, fh, style, bay, last=(si == len(seg_starts) - 2)) + 0.2
        if si < len(seg_starts) - 2:
            sb = r.choice([6.0, 8.0, 10.0])
            if (x1 - x0) - 2 * sb < 24 or (y1 - y0) - 2 * sb < 24:
                sb = 4.0
            # setback terrace: rooftop units on the ledge
            for k in range(2):
                B.hvac(r.uniform(x0 + 4, x1 - 4), y0 + 2.6, z, w=4, d=2.6, h=2.4)
            ax = r.choice([0, 1])
            x0, x1 = (x0 + sb, x1 - sb) if ax or True else (x0, x1)
            y0, y1 = y0 + sb, y1 - sb
    top = z + 1.2
    tw, td = x1 - x0, y1 - y0
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    dt = B.b("Details")
    # ---- crown
    if crown == "mech":
        sh = 14.0
        F2 = B.facades(tw - 3, td - 3, x0 + 1.5, y0 + 1.5)
        for side, F in F2.items():
            F.wall(B.b("Walls") if style in ("ribbon", "grid") else B.b("Trim"), z, z + 1.5)
            k = 0
            zz = z + 2.0
            while zz < z + sh - 0.8:
                F.box(dt, 0, F.W, -0.3, 0.35, zz, zz + 0.45, skip=("back", "left", "right"))
                zz += 1.1
            n, bw = _bays(F.W, 6.0)
            for i in range(n + 1):
                F.box(fr, max(0, i * bw - 0.3), min(F.W, i * bw + 0.3), -0.4, 0.5, z, z + sh, skip=("back",))
            F.wall(B.b("Details"), z + 1.5, z + sh, n=-0.5)
        G.sweep(B.b("Trim"), B.rect_loop(tw - 3, td - 3, x0 + 1.5, y0 + 1.5), [(0.0, z + sh), (0.6, z + sh), (0.6, z + sh + 1.0), (0.0, z + sh + 1.0)])
        G.cap(B.b("Roof"), B.rect_loop(tw - 3, td - 3, x0 + 1.5, y0 + 1.5), z + sh + 1.0)
        top = z + sh + 1.0
        G.cylinder(dt, cx + tw * 0.2, cy, top, top + 22, 0.5, seg=8, caps=(False, True), r1=0.25)
        G.box(B.b("Neon"), cx + tw * 0.2 - 0.6, cy - 0.6, top + 22, cx + tw * 0.2 + 0.6, cy + 0.6, top + 23.2)
        cooling_tower(B, x0 + 9, y1 - 8, z, w=10, d=7, h=6)
    elif crown == "spire":
        for k, (inset2, hh) in enumerate(((2.0, 6.0), (6.0, 5.0))):
            lp = B.rect_loop(tw - 2 * inset2, td - 2 * inset2, x0 + inset2, y0 + inset2)
            G.prism(B.b("Walls2" if k else "Trim"), lp, z, z + hh, top=True)
            z += hh
        r0 = min(tw, td) * 0.16
        G.cylinder(B.b("Accent"), cx, cy, z, z + 8, r0, seg=16, caps=(False, True), r1=r0 * 0.75)
        G.cylinder(B.b("Accent"), cx, cy, z + 8, z + 70, r0 * 0.6, seg=12, caps=(False, False), r1=0.25)
        G.box(B.b("Neon"), cx - 0.5, cy - 0.5, z + 70, cx + 0.5, cy + 0.5, z + 71)
        top = z + 71
    elif crown == "stepped":
        for k in range(3):
            ins = 3.0 * (k + 1)
            lp = B.rect_loop(tw - 2 * ins, td - 2 * ins, x0 + ins, y0 + ins)
            hh = 7.0 - k
            Fk = B.facades(tw - 2 * ins, td - 2 * ins, x0 + ins, y0 + ins)
            for side, F in Fk.items():
                F.wall(B.b("Walls2"), z, z + hh)
                n, bw = _bays(F.W, 4.0)
                for i in range(1, n):
                    F.box(B.b("Accent"), i * bw - 0.35, i * bw + 0.35, 0.0, 0.6, z, z + hh - 0.6, skip=("back",))
            G.cap(B.b("Roof"), lp, z + hh)
            G.sweep(B.b("Trim"), lp, [(0.0, z + hh), (0.5, z + hh), (0.5, z + hh + 0.6), (0.0, z + hh + 0.6)])
            z += hh + 0.6
        G.cylinder(dt, cx, cy, z, z + 18, 0.45, seg=8, caps=(False, True), r1=0.2)
        G.box(B.b("Neon"), cx - 0.5, cy - 0.5, z + 18, cx + 0.5, cy + 0.5, z + 19)
        top = z + 19
    elif crown == "slant":
        hh = min(tw, td) * 0.45
        gl = B.b("Glass")
        P = [(x0, y0, z), (x1, y0, z), (x1, y1, z + hh), (x0, y1, z + hh)]
        G.quad(gl, *P, uv=ATLAS["windows"]["spandrel"])
        G.tri(B.b("Walls2"), (x1, y0, z), (x1, y1, z), (x1, y1, z + hh))
        G.tri(B.b("Walls2"), (x0, y1, z), (x0, y0, z), (x0, y1, z + hh))
        G.quad(B.b("Walls2"), (x1, y1, z), (x0, y1, z), (x0, y1, z + hh), (x1, y1, z + hh))
        n = max(2, int(tw / 6))
        for i in range(n + 1):
            xx = x0 + tw * i / n
            G.box(fr, xx - 0.3, y0, z, xx + 0.3, y0 + 0.5, z + 0.5)
            p0, p1 = (xx, y0, z + 0.4), (xx, y1, z + hh + 0.4)
            G.hcylinder(fr, p0, p1, 0.3, seg=4)
        top = z + hh
    else:  # helipad
        G.prism(B.b("Trim"), B.rect_loop(min(tw, td) * 0.7, min(tw, td) * 0.7, cx - min(tw, td) * 0.35, cy - min(tw, td) * 0.35), z, z + 3.0)
        s = min(tw, td) * 0.7
        G.quad(B.b("Sign"), (cx - s / 2, cy - s / 2, z + 3.02), (cx + s / 2, cy - s / 2, z + 3.02), (cx + s / 2, cy + s / 2, z + 3.02),
               (cx - s / 2, cy + s / 2, z + 3.02), uv=ATLAS["signs"]["helipad"])
        for sx in (-1, 1):
            for sy in (-1, 1):
                G.box(B.b("Neon"), cx + sx * s / 2 - 0.4, cy + sy * s / 2 - 0.4, z + 3.0, cx + sx * s / 2 + 0.4, cy + sy * s / 2 + 0.4, z + 3.5)
        cooling_tower(B, x0 + 7, y0 + 6, z, w=8, d=6, h=5)
        top = z + 3.0
    if crown in ("mech", "helipad", "slant") and tw > 36:
        gantry(B, x0 + 2, x1 - 2, y0 + 1.0, z if crown != "mech" else z, h=4.0)
    for k in range(r.randint(2, 4)):
        if crown in ("mech", "stepped", "spire"):
            break
        B.hvac(r.uniform(x0 + 5, x1 - 5), r.uniform(cy, y1 - 4), z, w=r.choice([4, 6]), d=3, h=2.6)
    B.footprint, B.height = (W, D), top
    B.tags = {"district": "downtown", "floors": floors, "style": style, "crown": crown}
    return B


ARCHS = {"tower": tower}
