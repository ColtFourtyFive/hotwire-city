"""RETAIL: single-storey commercial - LA mini-mall strip, 24/7 convenience store, gas station with canopy,
stainless-steel roadside diner. All include their lot (parking / forecourt), so they drop onto a city lot as-is.
Lot origin: bottom-centre, street edge at y = -D/2."""
import math
import bk_geo as G
from bk_arch import Building, ATLAS, STUCCO, FRAMES, ACCENTS, TILES

SIGN_KEYS = [k for k in ATLAS["signs"] if k.startswith("h")]


def _common_spec(B, wall_tint, frame="silver", wall="stucco"):
    B.spec = {"Walls": ("tex", wall, wall_tint), "Walls2": ("tex", "cmu", (0.9, 0.88, 0.85)),
              "Trim": ("tex", "plaster", (0.93, 0.92, 0.9)), "Frames": ("color", FRAMES[frame], 0.3, 0.8),
              "Accent": ("color", (0.95, 0.75, 0.1), 0.5, 0.0), "Glass": ("glass",),
              "Roof": ("tex", "roof_tar", (1, 1, 1)), "Details": ("tex", "metal", (0.62, 0.64, 0.66)),
              "Doors": ("tex", "shutter", (0.8, 0.8, 0.8)), "Sign": ("atlas", "signs.png"), "Brand": ("atlas", "brands.png"),
              "Site": ("tex", "curb", (1.0, 1.0, 1.0)), "Asphalt": ("tex", "asphalt", (0.92, 0.92, 0.94)),
              "Paint": ("color", (0.9, 0.9, 0.86), 0.7, 0.0), "Lawn": ("tex", "grass", (0.8, 0.98, 0.65)),
              "Neon": ("neon", (1.0, 0.97, 0.9)), "Grime": ("grime",), "WindowsLit": ("lit",)}


def _box_building(B, x0, y0, x1, y1, h, parapet=1.2, roof_units=2):
    """Plain walls on the sides/back (front handled by caller), parapet coping, roof + HVAC."""
    W, D = x1 - x0, y1 - y0
    Fs = B.facades(W, D, x0, y0)
    loop = B.rect_loop(W, D, x0, y0)
    G.sweep(B.b("Trim"), loop, [(0.0, h), (0.4, h), (0.4, h + 0.8), (-0.9, h + 0.8), (-0.9, h - parapet)], closed=True)
    G.cap(B.b("Roof"), G.offset_loop(loop, -0.9), h - parapet + 0.02)
    r = B.rng
    for k in range(roof_units):
        B.hvac(r.uniform(x0 + 6, x1 - 6), r.uniform(y0 + 8, y1 - 6), h - parapet, w=r.choice([5, 6]), d=4, h=3.0)
    return Fs


def _service_back(B, F, h):
    r = B.rng
    n = max(1, int(F.W // 30))
    for k in range(n):
        u = F.W * (k + 0.5) / n
        F.box(B.b("Doors"), u - 2.0, u + 2.0, -0.2, 0.15, 0, 8.0)
        F.box(B.b("Neon"), u - 0.6, u + 0.6, 0.0, 0.7, 9.0, 9.7)
    for u in (1.2, F.W - 1.2):
        F.box(B.b("Details"), u - 0.35, u + 0.35, 0.0, 0.7, 0, h - 0.4)


def strip(seed=0, **kw):
    """LA mini-mall: row of 3-6 storefronts under a canopy, fascia signs, parking in front, pylon sign."""
    B = Building("strip", seed, kw.get("name"))
    r = B.rng
    n = kw.get("units", r.randint(3, 6))
    uw = kw.get("unit_w", r.choice([24.0, 26.0, 28.0]))
    bd = kw.get("bd", r.choice([44.0, 50.0]))
    canopy = kw.get("canopy", r.choice(["mansard", "flat", "flat"]))
    bw = n * uw
    park_d = kw.get("park_d", 62.0)   # 62 = two stall rows + aisle; ~34 = one row along the storefronts
    W, D = bw + 24.0, bd + 10.0 + park_d + 8.0
    tint = STUCCO[kw.get("stucco", r.choice(["bone", "cream", "sand", "grey", "taupe", "salmon"]))]
    _common_spec(B, tint, frame=r.choice(["silver", "bronze", "black"]))
    h = 20.0
    x0, x1 = -bw / 2, bw / 2
    y1 = D / 2 - 2.0
    y0 = y1 - bd
    Fs = _box_building(B, x0, y0, x1, y1, h, roof_units=max(2, n - 1))
    F = Fs["front"]
    ops = []
    cd = 10.0
    st = {"cells": "shop", "depth": 0.9, "bay": 6.0, "transom": 2.0, "kick": 1.4}
    for i in range(n):
        u0, u1 = i * uw + 1.0, (i + 1) * uw - 1.0
        door = u0 + 3.5 if r.random() < 0.5 else u1 - 3.5
        B.storefront(F, u0, u1, 0.0, 11.5, dict(st, cells=r.choice(["shop", "diner", "shop", "office"])), ops, door=door)
        F.box(B.b("Walls"), u1, u1 + 2.0, 0.0, 0.5, 0.0, 12.5) if i < n - 1 else None
    F.wall(B.b("Walls"), 0, h, ops)
    for side in ("left", "right", "back"):
        Fs[side].wall(B.b("Walls"), 0, h)
        B.grime(Fs[side], 0, Fs[side].W, 0, 5.5, "base")
        B.grime(Fs[side], 0, Fs[side].W, h - 5, h, "soot")
    _service_back(B, Fs["back"], h)
    B.grime(F, 0, F.W, 0, 3.0, "base")
    # canopy / covered walk
    tr, wa = B.b("Trim"), B.b("Walls")
    zc = 13.0
    F.box(tr, -1.0, F.W + 1.0, 0.0, cd, zc, zc + 0.6)
    F.box(wa, -1.0, F.W + 1.0, cd - 0.6, cd, zc - 0.6, zc + 4.2, skip=("back",))
    F.box(tr, -1.2, F.W + 1.2, cd - 0.8, cd + 0.2, zc + 4.2, zc + 4.8)
    for i in range(n + 1):
        u = i * uw
        F.box(wa, max(-1.0, u - 0.8), min(F.W + 1.0, u + 0.8), cd - 2.2, cd - 0.6, 0.0, zc, skip=("bottom",))
    for i in range(n):
        for t in (0.3, 0.7):
            u = i * uw + uw * t
            F.box(B.b("Neon"), u - 0.8, u + 0.8, 3.5, 5.0, zc - 0.05, zc, skip=("top",))
    if canopy == "mansard":
        rf = B.b("Roof")
        za, zb = zc + 4.8, zc + 9.0
        pa, pb = F.p(-1.2, za, cd + 0.2), F.p(F.W + 1.2, za, cd + 0.2)
        pc, pd = F.p(F.W + 1.2, zb, cd - 4.0), F.p(-1.2, zb, cd - 4.0)
        G.poly(B.b("Roof2"), [pa, pb, pc, pd], uv_along=(1, 0, 0), tile=10.0)
        B.spec["Roof2"] = ("tex", "roof_clay", (1, 1, 1))
        G.quad(wa, F.p(-1.2, zb, cd - 4.0), F.p(F.W + 1.2, zb, cd - 4.0), F.p(F.W + 1.2, zb, 0.0), F.p(-1.2, zb, 0.0))
        for side_u, sgn in ((-1.2, -1), (F.W + 1.2, 1)):
            G.poly(wa, [F.p(side_u, za, 0.0), F.p(side_u, za, cd + 0.2), F.p(side_u, zb, cd - 4.0), F.p(side_u, zb, 0.0)][::(1 if sgn > 0 else -1)])
    keys = r.sample(SIGN_KEYS, min(n, len(SIGN_KEYS)))
    for i in range(n):
        B.sign(F, i * uw + uw / 2, zc + 0.9, keys[i], height=2.4, n=cd)
    # walkway slab
    G.box(B.b("Site"), x0 - 1.0, y0 - cd - 1.0, -0.5, x1 + 1.0, y0, 0.6, skip=("bottom",))
    # parking
    py0, py1 = -D / 2 + 8.0, y0 - cd - 1.0
    B.parking(-W / 2 + 2, py0, W / 2 - 2, py1, rows=("-y", "+y") if park_d >= 50 else ("+y",))
    G.quad(B.b("Lawn"), (-W / 2, -D / 2, 0.08), (W / 2, -D / 2, 0.08), (W / 2, py0, 0.08), (-W / 2, py0, 0.08))
    G.box(B.b("Trim"), -W / 2, py0 - 0.5, 0, W / 2 - 26, py0, 0.7)
    # pylon sign at the street corner
    px, py = W / 2 - 10.0, -D / 2 + 4.0
    pylon(B, px, py, [keys[i % len(keys)] for i in range(min(4, n))], "wide9", h=30.0)
    for x in (-W / 4, W / 4):
        B.lot_light(x, (py0 + py1) / 2, h=24.0)
    B.footprint, B.height = (W, D), max(h + 0.8, 30.0)
    B.tags = {"district": "commercial", "units": n, "canopy": canopy, "building": [round(bw, 1), bd]}
    return B


def pylon(B, x, y, tenant_keys, top_key, h=30.0):
    """Two-post pylon sign: brand cabinet on top, tenant panels stacked below."""
    wa, fr = B.b("Walls"), B.b("Frames")
    pw = 12.0
    F = G.Facade((x - pw / 2, y, 0), (1, 0, 0), (0, -1, 0), pw)
    F.box(wa, -1.0, pw + 1.0, -1.0, 1.0, 0.0, 3.0)
    for u in (0.6, pw - 2.0):
        F.box(wa, u, u + 1.4, -0.7, 0.7, 3.0, h)
    zc = h - 5.0
    F.box(fr, -0.6, pw + 0.6, -0.8, 0.8, zc - len(tenant_keys) * 2.3 - 0.4, h + 0.4)
    B.brand(F, pw / 2, zc + 0.6, top_key, 4.0, n=0.8, depth=0.0)
    Fb = G.Facade((x + pw / 2, y, 0), (-1, 0, 0), (0, 1, 0), pw)
    B.brand(Fb, pw / 2, zc + 0.6, top_key, 4.0, n=0.8, depth=0.0)
    for k, key in enumerate(tenant_keys):
        z = zc - (k + 1) * 2.3
        u0_, v0, u1_, v1 = ATLAS["signs"][key]
        for FF in (F, Fb):
            FF.quad(B.b("Sign"), 0.4, pw - 0.4, z, z + 2.0, 0.82, uv=(u0_, v0, u1_, v1))


def _store_box(B, x0, y0, W, D, h, name_key, posters=True):
    """Convenience store body: glass front with posters, fascia brand board, side/back walls, roof."""
    r = B.rng
    x1, y1 = x0 + W, y0 + D
    Fs = _box_building(B, x0, y0, x1, y1, h, roof_units=2)
    F = Fs["front"]
    ops = []
    st = {"cells": "shop", "depth": 0.6, "bay": 5.0, "transom": 1.2, "kick": 1.2}
    gw0, gw1 = 3.0, W - 3.0
    B.storefront(F, gw0, gw1, 0.0, 10.5, st, ops, door=W / 2 + (W * 0.22 if r.random() < 0.5 else -W * 0.22))
    if posters:
        for k in range(4):
            u = gw0 + 3.0 + k * 6.0 + r.uniform(0, 1.5)
            if u + 3.2 > gw1:
                break
            key = "poster%d" % r.randrange(6)
            u0_, v0, u1_, v1 = ATLAS["brands"][key]
            F.quad(B.b("Brand"), u, u + 2.8, 3.2, 7.2, -0.55, uv=(u0_, v0, u1_, v1))
    F.wall(B.b("Walls"), 0, h, ops)
    # fascia board, lit: brands.png key ("wideN") or a storefront sign from signs.png ("hN")
    if name_key.startswith("h"):
        B.sign(F, W / 2, h - 5.4, name_key, height=3.6, n=0.0, frame="Trim")
    else:
        B.brand(F, W / 2, h - 5.6, name_key, 4.2, n=0.0, depth=0.6, frame="Trim")
    if r.random() < 0.4:   # half-open security shutter on part of the glass
        sh0 = gw0 + r.uniform(0, 4)
        F.box(B.b("Doors"), sh0, sh0 + r.uniform(8, 14), 0.1, 0.5, 10.5 - r.uniform(2.0, 5.0), 10.6)
    F.box(B.b("Trim"), -0.5, W + 0.5, 0.0, 4.5, 11.2, 11.8)
    for t in (0.2, 0.5, 0.8):
        F.box(B.b("Neon"), W * t - 0.8, W * t + 0.8, 2.5, 3.8, 11.15, 11.2, skip=("top",))
    for side in ("left", "right", "back"):
        Fs[side].wall(B.b("Walls2"), 0, h)
        B.grime(Fs[side], 0, Fs[side].W, 0, 5.0, "base")
    _service_back(B, Fs["back"], h)
    B.grime(F, 0, W, 0, 2.5, "base")
    # ice chest + propane cage + bins + bollards in front
    dt = B.b("Details")
    ix = 0.6
    F.box(dt, ix, ix + 6.0, 0.1, 3.4, 0.0, 6.0)
    u0_, v0, u1_, v1 = ATLAS["brands"]["poster4"]
    F.quad(B.b("Brand"), ix + 1.4, ix + 4.6, 2.4, 5.6, 3.42, uv=(u0_, v0, u1_, v1))
    F.box(dt, W - 7.0, W - 1.0, 0.1, 3.5, 0.0, 0.3)
    F.box(dt, W - 7.0, W - 1.0, 0.1, 3.5, 6.0, 6.3)
    for (a, b_) in ((W - 7.0, W - 6.7), (W - 1.3, W - 1.0)):
        F.box(dt, a, b_, 0.1, 3.5, 0.0, 6.3, skip=("top", "bottom"))
    for k in range(4):
        G.cylinder(dt, *F.p(W - 6.0 + k * 1.4, 0, 1.9)[:2], 0.3, 4.2, 0.55, seg=8, caps=(False, True))
    for k in range(int((gw1 - gw0) // 6) + 1):
        bx, by, _ = F.p(gw0 + k * 6.0, 0, 4.0)
        B.bollard(bx, by)
    return Fs


def corner_store(seed=0, **kw):
    """24/7 convenience store on its own lot with front parking."""
    B = Building("corner_store", seed, kw.get("name"))
    r = B.rng
    W0, D0 = kw.get("W", r.choice([44.0, 50.0, 56.0])), kw.get("bd", r.choice([36.0, 40.0]))
    W, D = W0 + 20.0, D0 + 50.0
    tint = STUCCO[kw.get("stucco", r.choice(["white", "bone", "grey", "cream"]))]
    _common_spec(B, tint, frame="silver")
    B.spec["Walls2"] = ("tex", "cmu", tint)
    h = 17.0
    x0, y0 = -W0 / 2, D / 2 - 2.0 - D0
    _store_box(B, x0, y0, W0, D0, h, kw.get("sign", r.choice(["wide10", "wide10", "h1", "h2", "h5", "h9"])))
    G.box(B.b("Site"), x0 - 2.0, y0 - 7.0, -0.5, x0 + W0 + 2.0, y0, 0.6, skip=("bottom",))
    B.parking(-W / 2 + 1, -D / 2 + 2.0, W / 2 - 1, y0 - 7.0, rows=("+y",))
    B.lot_light(-W / 2 + 4, -D / 2 + 6, h=22.0, arms=1)
    B.footprint, B.height = (W, D), h + 0.8
    B.tags = {"district": "commercial", "building": [W0, D0]}
    return B


def gas(seed=0, **kw):
    """Gas station: branded canopy over pump islands, convenience kiosk, price pylon, concrete forecourt."""
    B = Building("gas", seed, kw.get("name"))
    r = B.rng
    W, D = kw.get("W", r.choice([140.0, 150.0, 160.0])), kw.get("D", r.choice([120.0, 130.0]))
    tint = STUCCO[r.choice(["white", "bone", "grey"])]
    _common_spec(B, tint, frame="silver")
    B.spec["Walls2"] = ("tex", "cmu", (0.92, 0.92, 0.9))
    B.spec["Accent"] = ("color", (0.06, 0.27, 0.63), 0.4, 0.2)
    B.spec["Roof"] = ("tex", "metal", (0.75, 0.75, 0.75))
    B.spec["Neon"] = ("neon", (1.0, 1.0, 0.97))
    # forecourt
    G.quad(B.b("Site"), (-W / 2, -D / 2, 0.04), (W / 2, -D / 2, 0.04), (W / 2, D / 2, 0.04), (-W / 2, D / 2, 0.04))
    # kiosk store at the back-left
    sw, sd, h = r.choice([46.0, 52.0, 58.0]), r.choice([32.0, 36.0]), 16.0
    store_left = kw.get("store_left", r.random() < 0.6)
    sx0, sy0 = (-W / 2 + 8.0) if store_left else (W / 2 - 8.0 - sw), D / 2 - 4.0 - sd
    _store_box(B, sx0, sy0, sw, sd, h, "wide11")
    G.box(B.b("Site"), sx0 - 1.0, sy0 - 6.0, -0.5, sx0 + sw + 1.0, sy0, 0.6, skip=("bottom",))
    if store_left:
        B.parking(sx0 + sw + 6.0, sy0 + 2.0, W / 2 - 2, D / 2 - 2.0, rows=("-y",), stall_d=18.0)
    else:
        B.parking(-W / 2 + 2, sy0 + 2.0, sx0 - 6.0, D / 2 - 2.0, rows=("-y",), stall_d=18.0)
    # canopy
    n_isl = kw.get("islands", r.choice([2, 3, 3, 4]))
    cw, cdp, cz, ct = 22.0 + n_isl * 18.0, r.choice([38.0, 42.0]), 17.0, r.choice([3.2, 3.6, 4.2])
    cx, cy = (8.0 if store_left else -8.0), -D / 2 + 46.0
    X0, X1, Y0, Y1 = cx - cw / 2, cx + cw / 2, cy - cdp / 2, cy + cdp / 2
    G.box(B.b("Trim"), X0, Y0, cz, X1, Y1, cz + ct, skip=())
    # fascia band texture on the 4 outer faces (tiles in u)
    fu0, fv0, fu1, fv1 = ATLAS["brands"]["fascia"]
    for (a, b_, nrm) in (((X0, Y0), (X1, Y0), (0, -1)), ((X1, Y0), (X1, Y1), (1, 0)), ((X1, Y1), (X0, Y1), (0, 1)), ((X0, Y1), (X0, Y0), (-1, 0))):
        L = math.hypot(b_[0] - a[0], b_[1] - a[1])
        o = (nrm[0] * 0.03, nrm[1] * 0.03)
        reps = max(1, round(L / 30.0))
        for k in range(reps):   # the fascia cell is only part of the atlas width: one quad per repeat
            pa = (a[0] + (b_[0] - a[0]) * k / reps + o[0], a[1] + (b_[1] - a[1]) * k / reps + o[1])
            pb = (a[0] + (b_[0] - a[0]) * (k + 1) / reps + o[0], a[1] + (b_[1] - a[1]) * (k + 1) / reps + o[1])
            G.quad(B.b("Brand"), (pa[0], pa[1], cz + 0.2), (pb[0], pb[1], cz + 0.2), (pb[0], pb[1], cz + ct - 0.2),
                   (pa[0], pa[1], cz + ct - 0.2), uv=(fu0, fv0, fu1, fv1))
    for k in range(2):
        for j in range(4):
            lx = X0 + cw * (j + 0.5) / 4
            ly = Y0 + cdp * (k + 0.5) / 2
            G.box(B.b("Neon"), lx - 2.5, ly - 1.2, cz - 0.05, lx + 2.5, ly + 1.2, cz, skip=("top",))
    Fl = G.Facade((cx - 9.0, Y0, 0), (1, 0, 0), (0, -1, 0), 18.0)
    B.brand(Fl, 9.0, cz + ct + 0.1, "gaslogo", 5.5, n=0.6, depth=0.5, frame="Accent")
    # columns + pump islands
    for k in range(n_isl):
        ix = X0 + cw * (k + 0.5) / n_isl
        G.box(B.b("Walls2"), ix - 1.2, cy - 1.2, 0.0, ix + 1.2, cy + 1.2, cz, skip=("bottom",))
        G.box(B.b("Trim"), ix - 2.6, cy - 12.0, 0.0, ix + 2.6, cy + 12.0, 0.7, skip=("bottom",))
        for sgn in (-1, 1):
            py = cy + sgn * 6.5
            dt = B.b("Details")
            G.box(dt, ix - 1.5, py - 1.0, 0.7, ix + 1.5, py + 1.0, 6.8)
            G.box(B.b("Accent"), ix - 1.6, py - 1.1, 6.8, ix + 1.6, py + 1.1, 8.0)
            G.box(B.b("Neon"), ix - 1.0, py - 1.05, 4.6, ix + 1.0, py + 1.05, 5.9)
            G.hcylinder(dt, (ix + 1.5, py, 5.0), (ix + 2.4, py, 2.2), 0.12, seg=4)
        for sgn in (-1, 1):
            B.bollard(ix, cy + sgn * 11.2, h=3.4)
    # price pylon at the street corner
    px, py = (W / 2 - 12.0) if store_left else (-W / 2 + 12.0), -D / 2 + 5.0
    Fp = G.Facade((px - 5.0, py, 0), (1, 0, 0), (0, -1, 0), 10.0)
    Fp.box(B.b("Walls2"), 0.0, 10.0, -1.0, 1.0, 0.0, 4.0)
    Fp.box(B.b("Accent"), 0.6, 9.4, -0.6, 0.6, 4.0, 26.0)
    B.brand(Fp, 5.0, 19.8, "gaslogo", 5.6, n=0.62, depth=0.0)
    B.brand(Fp, 5.0, 6.0, "gasprice", 12.8, n=0.62, depth=0.0)
    Fpb = G.Facade((px + 5.0, py, 0), (-1, 0, 0), (0, 1, 0), 10.0)
    B.brand(Fpb, 5.0, 19.8, "gaslogo", 5.6, n=0.62, depth=0.0)
    B.brand(Fpb, 5.0, 6.0, "gasprice", 12.8, n=0.62, depth=0.0)
    # air / water machine, lot lights, landscaping strip along the street
    G.box(B.b("Details"), -W / 2 + 70.0, D / 2 - 14.0, 0.0, -W / 2 + 73.0, D / 2 - 12.0, 5.5)
    G.quad(B.b("Lawn"), (-W / 2, -D / 2, 0.1), (W / 2 - 22, -D / 2, 0.1), (W / 2 - 22, -D / 2 + 4.0, 0.1), (-W / 2, -D / 2 + 4.0, 0.1))
    G.box(B.b("Trim"), -W / 2, -D / 2 + 4.0, 0.0, W / 2 - 22, -D / 2 + 4.6, 0.8)
    B.lot_light(-W / 2 + 4.0, -D / 2 + 30.0, h=24.0, arms=1)
    B.footprint, B.height = (W, D), 26.0
    B.tags = {"district": "commercial", "brand": "PUMP & GO", "pumps": 2 * n_isl}
    return B


def diner(seed=0, **kw):
    """Stainless-steel roadside diner with a ribbon of booth windows, red stripe, rooftop EAT sign, parking."""
    B = Building("diner", seed, kw.get("name"))
    r = B.rng
    bw, bd = kw.get("bw", r.choice([64.0, 72.0])), 28.0
    W, D = bw + 40.0, bd + 66.0
    stripe = kw.get("stripe", r.choice([(0.72, 0.06, 0.08), (0.05, 0.35, 0.55), (0.1, 0.45, 0.35)]))
    _common_spec(B, (1, 1, 1))
    B.spec.update({"Walls": ("color", (0.78, 0.79, 0.8), 0.22, 1.0), "Accent": ("color", stripe, 0.35, 0.1),
                   "Walls2": ("tex", "terrazzo", (0.95, 0.95, 0.95)), "Frames": ("color", (0.8, 0.8, 0.82), 0.15, 1.0),
                   "Neon": ("neon", (1.0, 0.2, 0.25) if stripe[0] > 0.5 else (0.2, 0.9, 1.0))})
    x0, x1 = -bw / 2, bw / 2
    y1 = D / 2 - 14.0
    y0 = y1 - bd
    rad = 7.0
    loop = G.rounded_rect(x0, y0, x1, y1, radii=(rad, rad, rad, rad), seg=4)
    wa, ac, fr, tr = B.b("Walls"), B.b("Accent"), B.b("Frames"), B.b("Trim")
    G.sweep(B.b("Walls2"), loop, [(0.0, 0.0), (0.0, 1.4)], closed=True)
    prof = [(0.0, 1.4)]
    z = 1.4
    while z < 4.6:
        prof += [(0.15, z + 0.05), (0.15, z + 0.35), (0.0, z + 0.4)]
        z += 0.4
    prof.append((0.0, 4.8))
    G.sweep(wa, loop, prof, closed=True)
    G.sweep(fr, loop, [(0.0, 4.8), (0.35, 4.8), (0.35, 5.2), (-0.4, 5.2)], closed=True)
    # window band 5.2..10.6, glass set back 0.4; mullions at loop vertices + every ~5 studs
    zg0, zg1 = 5.2, 10.6
    cell = ATLAS["windows"]["diner0"]
    nl = len(loop)
    for i in range(nl):
        a, b_ = loop[i], loop[(i + 1) % nl]
        L = math.hypot(b_[0] - a[0], b_[1] - a[1])
        if L < 1e-3:
            continue
        nx, ny = (b_[1] - a[1]) / L, -(b_[0] - a[0]) / L
        k = max(1, round(L / 6.0))
        for j in range(k):
            pa = (a[0] + (b_[0] - a[0]) * j / k - nx * 0.4, a[1] + (b_[1] - a[1]) * j / k - ny * 0.4)
            pb = (a[0] + (b_[0] - a[0]) * (j + 1) / k - nx * 0.4, a[1] + (b_[1] - a[1]) * (j + 1) / k - ny * 0.4)
            G.quad(B.b("Glass"), (pa[0], pa[1], zg0), (pb[0], pb[1], zg0), (pb[0], pb[1], zg1), (pa[0], pa[1], zg1), uv=cell)
            G.quad(B.b("WindowsLit"), (pa[0] + nx * 0.03, pa[1] + ny * 0.03, zg0), (pb[0] + nx * 0.03, pb[1] + ny * 0.03, zg0),
                   (pb[0] + nx * 0.03, pb[1] + ny * 0.03, zg1), (pa[0] + nx * 0.03, pa[1] + ny * 0.03, zg1), uv=cell)
            G.hcylinder(fr, (pa[0] + nx * 0.2, pa[1] + ny * 0.2, zg0), (pa[0] + nx * 0.2, pa[1] + ny * 0.2, zg1), 0.22, seg=4)
    G.sweep(fr, loop, [(-0.4, zg1), (0.35, zg1), (0.35, zg1 + 0.4), (0.0, zg1 + 0.4)], closed=True)
    G.sweep(wa, loop, [(0.0, zg1 + 0.4), (0.0, 11.6)], closed=True)
    G.sweep(ac, loop, [(0.0, 11.6), (0.12, 11.6), (0.12, 13.2), (0.0, 13.2)], closed=True)
    G.sweep(B.b("Neon"), loop, [(0.12, 12.2), (0.3, 12.2), (0.3, 12.5), (0.12, 12.5)], closed=True)
    G.sweep(wa, loop, [(0.0, 13.2), (1.2, 13.6), (1.2, 14.2), (0.0, 14.6)], closed=True)
    G.cap(B.b("Roof"), G.offset_loop(loop, 0.0), 14.6)
    # entrance vestibule
    F = G.Facade((-6.0, y0 - 6.0, 0), (1, 0, 0), (0, -1, 0), 12.0)
    G.box(B.b("Walls2"), -6.0, y0 - 6.0, 0.0, -2.0, y0, 11.0, skip=("bottom",))
    G.box(B.b("Walls2"), 2.0, y0 - 6.0, 0.0, 6.0, y0, 11.0, skip=("bottom",))
    G.box(B.b("Walls"), -6.6, y0 - 6.6, 11.0, 6.6, y0, 12.2)
    B.glass(F, 4.0, 8.0, 0.0, 8.5, -1.5, ATLAS["windows"]["diner0"], lit=True)
    F.box(B.b("Walls2"), 4.0, 8.0, -1.5, 0.0, 8.5, 11.0, skip=("back",))
    F.box(fr, 5.85, 6.15, -1.5, -1.1, 0.0, 8.5, skip=("back",))
    F.box(fr, 4.0, 4.3, -1.5, -1.1, 0.0, 8.5, skip=("back",))
    F.box(fr, 7.7, 8.0, -1.5, -1.1, 0.0, 8.5, skip=("back",))
    # roof sign on a frame
    Fs = G.Facade((-9.0, (y0 + y1) / 2, 0), (1, 0, 0), (0, -1, 0), 18.0)
    for u in (3.0, 15.0):
        Fs.box(B.b("Details"), u - 0.3, u + 0.3, -0.3, 0.3, 14.6, 20.0)
    Fs.box(ac, -0.6, 18.6, -0.6, 0.6, 20.0, 31.0)
    B.brand(Fs, 9.0, 20.5, "eat", 10.0, n=0.6, depth=0.0)
    Fs2 = G.Facade((9.0, (y0 + y1) / 2, 0), (-1, 0, 0), (0, 1, 0), 18.0)
    B.brand(Fs2, 9.0, 20.5, "eat", 10.0, n=0.6, depth=0.0)
    # name board on the front upper band (Sunset Diner / Donut Dash / Pizza Palace / Coral Cafe)
    nk = kw.get("sign", r.choice(["h0", "h8", "h10", "h6"]))
    Fn = G.Facade((x0 + rad, y0, 0), (1, 0, 0), (0, -1, 0), bw - 2 * rad)
    B.sign(Fn, (bw - 2 * rad) * (0.25 if r.random() < 0.5 else 0.75), 13.9, nk, height=2.6, n=0.4)
    G.sweep(B.b("Neon"), [(-9.6, (y0 + y1) / 2 - 0.6), (9.6, (y0 + y1) / 2 - 0.6), (9.6, (y0 + y1) / 2 + 0.6), (-9.6, (y0 + y1) / 2 + 0.6)],
            [(0.0, 31.0), (0.15, 31.0), (0.15, 31.4), (0.0, 31.4)], closed=True)
    B.hvac(x0 + 14, y1 - 8, 14.6, w=6, d=4, h=3)
    B.hvac(x1 - 14, y1 - 8, 14.6, w=5, d=4, h=2.6)
    # walks + parking
    G.box(B.b("Site"), x0 - 4.0, y0 - 8.0, -0.5, x1 + 4.0, y1 + 4.0, 0.6, skip=("bottom",))
    B.parking(-W / 2 + 2, -D / 2 + 6.0, W / 2 - 2, y0 - 8.0, rows=("+y", "-y"), stall_d=18.0)
    G.quad(B.b("Lawn"), (-W / 2, -D / 2, 0.08), (W / 2, -D / 2, 0.08), (W / 2, -D / 2 + 6.0, 0.08), (-W / 2, -D / 2 + 6.0, 0.08))
    B.lot_light(-W / 2 + 6, -D / 2 + 9, h=22.0)
    B.footprint, B.height = (W, D), 31.4
    B.tags = {"district": "commercial", "building": [bw, bd]}
    return B


ARCHS = {"strip": strip, "corner_store": corner_store, "gas": gas, "diner": diner}
