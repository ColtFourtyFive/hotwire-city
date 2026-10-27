#!/usr/bin/env python3
"""Hero renders of the building kit in GTA-like late-afternoon light (and night), written to docs/v2/proto/buildkit/.

    python3 -I tools/blender/buildkit/render_kit.py --scene midtown            # one scene
    python3 -I tools/blender/buildkit/render_kit.py --all                       # every scene (one process each)
    python3 -I tools/blender/buildkit/render_kit.py --scene block --samples 64 --res 960 540

Each scene builds a small slice of city around the archetype (street, sidewalks, parked cars, lamps, palms,
neighbouring variants) so the buildings are judged in context, never floating on a void. Props are preview-only.
"""
import argparse, math, os, random, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
OUT = os.path.join(ROOT, "docs", "v2", "proto", "buildkit")

import bpy  # noqa: E402
import build as BK  # noqa: E402
import bk_scene as S  # noqa: E402

ROAD_W, SIDE_W = 48.0, 14.0


def col():
    return bpy.context.scene.collection


def place(arch, seed, x, y, rot=0.0, night=False, **kw):
    """Instantiate an archetype with its lot origin at (x, y); rot=0 -> front faces -Y, rot=180 -> +Y."""
    B = BK.build(arch, seed, **kw)
    BK.instantiate(B, col(), loc=(x, y, 0.0), rot_z=rot, night=night)
    return B


def north_lot_y(D):
    return ROAD_W / 2 + SIDE_W + D / 2


def avenue(x0, x1, night=False, lamps=60.0, palms=None, cars=True, seed=0, far_w=40.0, palm_kind="fan", side_w=SIDE_W,
           no_cars=None, clear=None, no_cars_n=None):
    """clear=(x, y, r): keep lamps/palms out of a radius around the camera."""
    ok = (lambda px, py: clear is None or math.hypot(px - clear[0], py - clear[1]) > clear[2])
    """East-west avenue centred on y=0 with sidewalks both sides (lots start at |y| = ROAD_W/2 + SIDE_W)."""
    c = col()
    S.road(c, x0, -ROAD_W / 2, x1, ROAD_W / 2, axis="x")
    for sgn in (-1, 1):
        y0, y1 = sorted((sgn * ROAD_W / 2, sgn * (ROAD_W / 2 + side_w)))
        S.sidewalk_block(c, x0, y0, x1, y1)
        S.ground(c, x0, (y1 if sgn > 0 else y0 - far_w), x1, (y1 + far_w if sgn > 0 else y0), "sidewalk", z=0.6) if far_w else None
    r = random.Random(seed)
    x = x0 + 20
    k = 0
    while x < x1 - 10:
        for sgn in (-1, 1):
            if k % 2 == (0 if sgn > 0 else 1) and ok(x, sgn * (ROAD_W / 2 + 2.0)):
                S.street_lamp(c, x, sgn * (ROAD_W / 2 + 2.0), facing=(0, -sgn), night=night)
        if palms:
            for sgn in (-1, 1):
                hh, sd = r.uniform(*palms), r.randint(0, 999)
                if ok(x + lamps / 2, sgn * (ROAD_W / 2 + 3.2)):
                    S.palm(c, x + lamps / 2, sgn * (ROAD_W / 2 + 3.2), h=hh, seed=sd, kind=palm_kind)
        x += lamps
        k += 1
    if cars:
        nc = no_cars or (x0 - 1, x0 - 1)
        if no_cars_n:   # keep the kerb in front of the hero lot clear
            S.parked_row(c, x0 + 10, no_cars_n[0], ROAD_W / 2 - 4.2, heading=180, seed=seed + 1, prob=0.55)
            S.parked_row(c, no_cars_n[1], x1 - 10, ROAD_W / 2 - 4.2, heading=180, seed=seed + 3, prob=0.55)
        else:
            S.parked_row(c, x0 + 10, x1 - 10, ROAD_W / 2 - 4.2, heading=180, seed=seed + 1, prob=0.55)
        S.parked_row(c, max(x0 + 10, nc[1]), x1 - 10, -ROAD_W / 2 + 4.2, heading=0, seed=seed + 2, prob=0.55)
        # a few moving-lane cars for life
        for k in range(3):
            S.car(c, r.uniform(x0 + 40, x1 - 40), r.choice([-1, 1]) * 9.0, heading=r.choice([0, 180]), seed=r.randint(0, 999))


def at_z(z, fn, *args, **kw):
    """Run a prop function and lift everything it created by z (props on terrain)."""
    before = set(bpy.data.objects)
    fn(*args, **kw)
    for ob in set(bpy.data.objects) - before:
        if ob.parent is None:
            ob.location.z += z


def backdrop(x0, x1, y, kinds=(("midtown", {"floors": 3}),), seed=0, rot=0.0, gap=6.0):
    """Row of filler buildings far behind the hero so the horizon is city, not void."""
    r = random.Random(seed)
    x = x0
    tries = 0
    while x < x1 and tries < 60:
        tries += 1
        arch, kw = kinds[r.randrange(len(kinds))]
        B = BK.build(arch, r.randint(100, 999), **kw)
        W, D = B.footprint
        if x + W > x1:
            continue
        BK.instantiate(B, col(), loc=(x + W / 2, y + D / 2 * (1 if rot == 0 else -1), 0), rot_z=rot)
        x += W + gap


def lot_cars(B, x, y, rot, frac=0.6, seed=0):
    r = random.Random(seed)
    cr, sr = math.cos(math.radians(rot)), math.sin(math.radians(rot))
    for (sx, sy, h) in B.spawns:
        if r.random() < frac:
            S.car(col(), x + sx * cr - sy * sr, y + sx * sr + sy * cr, heading=h + rot, seed=r.randint(0, 9999))


def finish(name, cam_loc, cam_target, lens, samples, res, night=False, haze=(0.66, 0.72, 0.80), haze_amt=0.5,
           exposure=None, shift_y=0.0):
    S.camera(cam_loc, cam_target, lens, shift_y=shift_y)
    if exposure is not None:
        bpy.context.scene.view_settings.exposure = exposure
    S.haze(color=haze if not night else (0.05, 0.07, 0.12), amount=haze_amt, night=night)
    path = os.path.join(OUT, name + ".png")
    t = time.time()
    S.render(path, samples=samples, res=res)
    print("RENDERED", path, "%.0fs" % (time.time() - t))
    return path


# ============================================================================================= scenes
def sc_downtown(a, night=False):
    S.reset(a.res)
    if night:
        S.night()
    else:
        S.world("sky_late_afternoon", sun_az=-150.0)
    avenue(-460, 420, night=night, lamps=70, palms=(50, 64), palm_kind="fan", seed=3, far_w=0, no_cars=(-460, -330),
           clear=(-392, -7, 75))
    specs = [("tower", 3, -330), ("tower", 7, -230), ("tower", 1, -120), ("tower", 12, -10), ("tower", 5, 100), ("tower", 9, 210)]
    for (arch, sd, x) in specs:
        B = BK.build(arch, sd)
        BK.instantiate(B, col(), loc=(x, north_lot_y(B.footprint[1]), 0), rot_z=0, night=night)
    for (arch, sd, x) in [("tower", 4, -290), ("tower", 11, -180), ("tower", 8, -70), ("tower", 2, 40), ("tower", 6, 150)]:
        B = BK.build(arch, sd)
        BK.instantiate(B, col(), loc=(x, -north_lot_y(B.footprint[1]), 0), rot_z=180, night=night)
    S.ground(col(), -600, -600, 600, 600, "sidewalk", z=-0.05)
    return finish("downtown_night" if night else "downtown_street", (-392, -7, 6.0), (0, 14, 92), 18, a.samples, a.res,
                  night=night, haze_amt=0.6)


def sc_midtown(a, night=False):
    S.reset(a.res)
    if night:
        S.night()
    else:
        S.world("sky_late_afternoon", sun_az=-140.0)
    avenue(-520, 520, night=night, lamps=60, palms=(46, 62), seed=5, far_w=0, no_cars=(-520, -150),
           clear=(-205, -30, 50))
    x = -330.0
    seeds = [15, 16, 3, 1, 6, 2, 8, 11, 7, 12]
    for i, sd in enumerate(seeds):
        party = ["left", "right"]
        B = BK.build("midtown", sd, party=party, D=40)
        W, D = B.footprint
        BK.instantiate(B, col(), loc=(x + W / 2, north_lot_y(D), 0), rot_z=0, night=night)
        x += W
    x = -150.0
    for i, sd in enumerate([4, 9, 5, 10, 13, 14, 17]):
        B = BK.build("midtown", sd, party=["left", "right"], D=40)
        W, D = B.footprint
        BK.instantiate(B, col(), loc=(x + W / 2, -north_lot_y(D), 0), rot_z=180, night=night)
        x += W
    S.ground(col(), -600, -600, 600, 600, "sidewalk", z=-0.05)
    return finish("midtown_night" if night else "midtown_street", (-205, -30, 6.0), (-40, 60, 48), 20, a.samples, a.res,
                  night=night)


def sc_single_lot(a, arch, seed, name, cam, target, lens=22, sun=-130.0, neighbours=(), palms=(42, 56), kw=None,
                  cars_frac=0.6):
    S.reset(a.res)
    S.world("sky_late_afternoon", sun_az=sun)
    B = BK.build(arch, seed, **(kw or {}))
    W, D = B.footprint
    avenue(-320, 320, lamps=64, palms=palms, seed=seed + 11, far_w=0, clear=(cam[0], cam[1], 55),
           no_cars=(cam[0] - 40, cam[0] + 40), no_cars_n=(-W / 2 - 30, W / 2 + 10))
    y = north_lot_y(D)
    BK.instantiate(B, col(), loc=(0, y, 0), rot_z=0)
    lot_cars(B, 0, y, 0, frac=cars_frac * 0.7, seed=seed)
    xl, xr = -W / 2, W / 2
    for k, (na, ns) in enumerate(neighbours):
        Bn = BK.build(na, ns)
        Wn, Dn = Bn.footprint
        if k % 2 == 0:
            x = xr + Wn / 2 + 4
            xr = x + Wn / 2
        else:
            x = xl - Wn / 2 - 4
            xl = x - Wn / 2
        BK.instantiate(Bn, col(), loc=(x, north_lot_y(Dn), 0), rot_z=0)
        lot_cars(Bn, x, north_lot_y(Dn), 0, frac=0.5, seed=ns + 7)
    # fill the rest of the frontage + a second row behind so the horizon reads as city
    fill = (("midtown", {"floors": 2, "D": 40}), ("midtown", {"floors": 3, "D": 40}), ("corner_store", {}), ("strip", {"units": 3}))
    backdrop(xr + 6, 420, ROAD_W / 2 + SIDE_W, fill, seed=seed + 1)
    backdrop(-420, xl - 6, ROAD_W / 2 + SIDE_W, fill, seed=seed + 2)
    backdrop(-420, 420, ROAD_W / 2 + SIDE_W + max(D, 130) + 20, fill + (("warehouse", {}),), seed=seed + 3)
    S.ground(col(), -700, -700, 700, 700, "sidewalk", z=-0.05)
    return finish(name, cam, target, lens, a.samples, a.res)


def sc_strip(a):
    return sc_single_lot(a, "strip", 2, "strip_mall", (-100, -30, 7.5), (2, 110, 12), lens=30,
                         neighbours=(("corner_store", 1),), kw={"units": 5})


def sc_gas(a):
    return sc_single_lot(a, "gas", 1, "gas_station", (-112, -30, 7.5), (2, 92, 10), lens=30, neighbours=(("diner", 2),),
                         cars_frac=0.4)


def sc_diner(a):
    return sc_single_lot(a, "diner", 1, "diner", (-62, -28, 6.0), (2, 94, 10), lens=36, neighbours=(("gas", 3),))


def sc_store(a):
    return sc_single_lot(a, "corner_store", 2, "corner_store", (-64, -30, 6.0), (0, 90, 8), lens=34,
                         neighbours=(("strip", 4), ("diner", 3)))


def sc_deco(a, night=False):
    S.reset(a.res)
    if night:
        S.night()
    else:
        S.world("sky_late_afternoon", sun_az=-125.0)
    c = col()
    # Ocean Drive: hotels on the north side, promenade + beach + sea to the south
    S.road(c, -320, -ROAD_W / 2, 320, ROAD_W / 2 - 8, axis="x")
    S.sidewalk_block(c, -320, ROAD_W / 2 - 8, 320, ROAD_W / 2 + SIDE_W - 8)
    S.sidewalk_block(c, -320, -ROAD_W / 2 - 18, 320, -ROAD_W / 2)
    S.ground(c, -900, -ROAD_W / 2 - 110, 900, -ROAD_W / 2 - 18, "sand", z=0.3)
    S.ground(c, -1600, -4000, 1600, -ROAD_W / 2 - 110, "sea", z=-0.05)
    r = random.Random(4)
    for x in range(-300, 320, 34):
        px, py = x + r.uniform(-4, 4), -ROAD_W / 2 - 9 + r.uniform(-3, 3)
        hh = r.uniform(34, 52)
        if math.hypot(px + 215, py + 50) > 40:
            S.palm(c, px, py, h=hh, seed=x + 999, kind="fan")
    for x in range(-290, 320, 70):
        S.street_lamp(c, x, ROAD_W / 2 - 10, facing=(0, -1), night=night)
    S.parked_row(c, -300, 300, ROAD_W / 2 - 12.5, heading=180, seed=9, prob=0.6)
    S.car(c, -40, -10, heading=0, seed=33)
    x = -250.0
    for i, sd in enumerate((3, 0, 1, 5, 2, 6)):
        B = BK.build("deco", sd, blade=(i + 1) % 4)
        W, D = B.footprint
        BK.instantiate(B, c, loc=(x + W / 2, ROAD_W / 2 + SIDE_W - 8 + D / 2, 0), rot_z=0, night=night)
        x += W + 6
    S.ground(c, -700, ROAD_W / 2, 700, 700, "sidewalk", z=-0.05)
    return finish("deco_night" if night else "deco_beach", (-215, -50, 7.0), (-20, 60, 30), 22, a.samples, a.res,
                  night=night)


def sc_suburbs(a):
    S.reset(a.res)
    S.world("sky_late_afternoon", sun_az=-135.0)
    c = col()
    rw = 30.0
    S.road(c, -400, -rw / 2, 400, rw / 2, axis="x", lanes=False)
    for sgn in (-1, 1):
        y0, y1 = sorted((sgn * rw / 2, sgn * (rw / 2 + 10)))
        S.sidewalk_block(c, -400, y0, 400, y1, h=0.5)
    r = random.Random(12)
    x = -230.0
    for sd in (1, 4, 2, 7, 3, 9, 5):
        B = BK.build("house", sd)
        W, D = B.footprint
        y = rw / 2 + 10 + D / 2
        BK.instantiate(B, c, loc=(x + W / 2, y, 0), rot_z=0)
        S.tree(c, x + r.uniform(8, W - 8), rw / 2 + 10 + r.uniform(8, 16), h=r.uniform(20, 30), seed=sd * 13)
        if r.random() < 0.7:
            S.car(c, x + W / 2 + r.choice([-1, 1]) * 18 + r.uniform(-2, 2), rw / 2 + 10 + 14, heading=90, seed=sd + 50)
        for k in range(3):
            S.bush(c, x + r.uniform(4, W - 4), y - D / 2 + r.uniform(22, 26), w=r.uniform(3, 6), h=r.uniform(2.5, 4), seed=sd * 7 + k)
        x += W
    x = -200.0
    for sd in (6, 8, 10, 11, 13):
        B = BK.build("house", sd)
        W, D = B.footprint
        BK.instantiate(B, c, loc=(x + W / 2, -(rw / 2 + 10 + D / 2), 0), rot_z=180)
        S.tree(c, x + r.uniform(8, W - 8), -(rw / 2 + 10 + r.uniform(8, 16)), h=r.uniform(20, 30), seed=sd * 17)
        x += W
    for xx in range(-380, 400, 90):
        if abs(xx + 175) > 45:
            S.street_lamp(c, xx, rw / 2 + 1.5, facing=(0, -1), h=22)
    S.parked_row(c, -300, 300, -rw / 2 + 4, heading=0, seed=21, prob=0.25)
    for xx in (-60, 100, 230):
        S.palm(c, xx, rw / 2 + 6, h=r.uniform(55, 70), seed=xx + 5, kind="fan")
    S.ground(c, -700, -700, 700, 700, "grass", z=-0.05)
    return finish("suburbs_street", (-175, -4, 6.0), (-40, 62, 14), 20, a.samples, a.res)


def sc_industrial(a):
    S.reset(a.res)
    S.world("sky_late_afternoon", sun_az=-140.0)
    cam = (-175, -30, 7.0)
    avenue(-520, 520, lamps=90, palms=None, seed=31, far_w=0, clear=(cam[0], cam[1], 30), no_cars=(-520, -100))
    B = BK.build("warehouse", 1)
    W, D = B.footprint
    BK.instantiate(B, col(), loc=(-W / 2 - 4, north_lot_y(D), 0), rot_z=0)
    lot_cars(B, -W / 2 - 4, north_lot_y(D), 0, frac=0.5, seed=3)
    B2 = BK.build("warehouse", 4, style="tiltup")
    W2, D2 = B2.footprint
    BK.instantiate(B2, col(), loc=(W2 / 2 + 4, north_lot_y(D2), 0), rot_z=0)
    lot_cars(B2, W2 / 2 + 4, north_lot_y(D2), 0, frac=0.4, seed=4)
    B3 = BK.build("warehouse", 6)
    W3, D3 = B3.footprint
    BK.instantiate(B3, col(), loc=(-W - 8 - W3 / 2, north_lot_y(D3), 0), rot_z=0)
    backdrop(-520, 520, ROAD_W / 2 + SIDE_W + 175, (("warehouse", {}), ("warehouse", {"style": "tiltup"})), seed=8)
    backdrop(W2 + 12, 520, ROAD_W / 2 + SIDE_W, (("warehouse", {}),), seed=9)
    S.ground(col(), -700, -700, 700, 700, "sidewalk", z=-0.05)
    return finish("industrial_warehouse", cam, (-70, 110, 16), 26, a.samples, a.res)


def sc_mansion(a):
    S.reset(a.res)
    S.world("sky_late_afternoon", sun_az=-120.0)
    c = col()
    B = BK.build("mansion", 2)
    W, D = B.footprint
    base = 40.0     # lot grade above the valley road
    LY = 140.0      # lot centre y

    def hz(x, y):
        # hillside rising to +Y with gentle ridges; the lot is a cut terrace at z=base
        t = (y + 40) / 160.0
        z = base * max(0.0, min(1.35, t)) ** 1.4 + 7 * math.sin(x * 0.018 + 1.3) * max(0, t) + 3 * math.sin(x * 0.07 + y * 0.05) * max(0, t)
        dy = y - LY
        if -W / 2 - 14 < x < W / 2 + 14 and -D / 2 - 30 < dy < D / 2 + 12:
            z = (base - B.base_depth) if dy < -D / 2 + 21 else base
        return z

    def in_lot(x, y):   # the lot brings its own ground: flat deck level + flat apron below the plinth
        return -W / 2 - 4 < x < W / 2 + 4 and LY - D / 2 - 26 < y < LY + D / 2 + 4
    S.hill(c, -600, -120, 600, 520, hz, nx=150, ny=90, kind="drygrass", skip=in_lot)
    S.ground(c, -W / 2 - 6, LY - D / 2 + 21, W / 2 + 6, LY + D / 2 + 6, "drygrass", z=base - 0.3)
    S.ground(c, -W / 2 - 6, LY - D / 2 - 28, W / 2 + 6, LY - D / 2 + 21, "drygrass", z=base - B.base_depth - 0.2)
    BK.instantiate(B, c, loc=(0, LY, base), rot_z=0)
    r = random.Random(7)
    for k in range(420):
        x, y = r.uniform(-330, 330), r.uniform(-5, 420)
        if abs(x) < W / 2 + 16 and LY - D / 2 - 32 < y < LY + D / 2 + 14:
            continue
        zz = hz(x, y) - 0.4
        q = r.random()
        if q < 0.72:
            at_z(zz, S.bush, c, x, y, w=r.uniform(4, 10), h=r.uniform(3, 7), seed=k, n=150)
        elif q < 0.93:
            at_z(zz, S.tree, c, x, y, h=r.uniform(16, 28), seed=k)
        else:
            at_z(zz, S.palm, c, x, y, h=r.uniform(40, 60), seed=k, kind="fan")
    for x in (-W / 2 + 4, W / 2 - 4):
        at_z(base, S.palm, c, x, LY + D / 2 - 8, h=44, seed=int(x) + 3, kind="fan")
    S.road(c, -600, -40, 600, -10, axis="x", lanes=False, z=0.15)
    S.car(c, 30, -25, heading=0, seed=77, rgb=(0.02, 0.02, 0.025))
    for k in range(120):   # extra chaparral on the near slope
        x, y = r.uniform(-200, 160), r.uniform(-5, LY - D / 2 - 34)
        at_z(hz(x, y) - 0.4, S.bush, c, x, y, w=r.uniform(3, 8), h=r.uniform(2.5, 6), seed=1000 + k, n=120)
    return finish("hills_mansion", (-92, 0, 62.0), (0, LY - 8, 40), 30, a.samples, a.res, haze_amt=0.45)


def sc_block(a, night=False):
    """Wide establishing shot: a district sampler on a street grid - towers behind, midtown, retail, beach deco,
    suburbs and industrial at the edges."""
    S.reset(a.res)
    if night:
        S.night(0.05)
    else:
        S.world("sky_late_afternoon", sun_az=-145.0)
    c = col()
    BW = 260.0          # block size (between street centrelines 260 + 48)
    P = BW + ROAD_W
    xs = [-3, -2, -1, 0, 1, 2, 3]
    ys = [-1, 0, 1, 2, 3]
    for i in range(len(xs) + 1):
        x = (xs[0] - 0.5 + i) * P
        S.road(c, x - ROAD_W / 2, (ys[0] - 0.5) * P - ROAD_W / 2, x + ROAD_W / 2, (ys[-1] + 0.5) * P + ROAD_W / 2, axis="y", lanes=True)
    for j in range(len(ys) + 1):
        y = (ys[0] - 0.5 + j) * P
        S.road(c, (xs[0] - 0.5) * P - ROAD_W / 2, y - ROAD_W / 2, (xs[-1] + 0.5) * P + ROAD_W / 2, y + ROAD_W / 2, axis="x",
               lanes=True, z=0.012)
    r = random.Random(42)

    def block(ix, iy, fill):
        cx, cy = ix * P, iy * P
        S.sidewalk_block(c, cx - BW / 2, cy - BW / 2, cx + BW / 2, cy + BW / 2)
        fill(cx, cy)

    def row(cx, cy, items, side=-1, gap=2.0):
        """Fill one side of a block along X; side=-1 -> lots front the south street."""
        x = cx - BW / 2 + 14
        for (arch, sd, kw) in items:
            B = BK.build(arch, sd, **kw)
            W, D = B.footprint
            if x + W > cx + BW / 2 - 14:
                break
            y = cy - BW / 2 + 14 + D / 2 if side < 0 else cy + BW / 2 - 14 - D / 2
            BK.instantiate(B, c, loc=(x + W / 2, y, 0.6), rot_z=0 if side < 0 else 180, night=night)
            x += W + gap

    def towers(cx, cy):
        k = r.randint(0, 50)
        row(cx, cy, [("tower", k, {}), ("tower", k + 1, {}), ("tower", k + 2, {})], -1, gap=8)
        row(cx, cy, [("tower", k + 3, {}), ("tower", k + 4, {}), ("tower", k + 5, {})], 1, gap=8)

    def midtown(cx, cy):
        k = r.randint(0, 50)
        row(cx, cy, [("midtown", k + i, {"party": ["left", "right"], "D": 40}) for i in range(6)], -1, gap=0)
        row(cx, cy, [("midtown", k + 10 + i, {"party": ["left", "right"], "D": 40}) for i in range(6)], 1, gap=0)

    def retail(cx, cy):
        row(cx, cy, [("gas", 1, {}), ("diner", 2, {})], -1, gap=4)
        row(cx, cy, [("strip", 3, {"units": 4}), ("corner_store", 1, {})], 1, gap=4)

    def deco(cx, cy):
        row(cx, cy, [("deco", i, {}) for i in range(4)], -1, gap=4)
        row(cx, cy, [("deco", 10 + i, {}) for i in range(4)], 1, gap=4)

    def suburbs(cx, cy):
        row(cx, cy, [("house", i, {}) for i in range(4)], -1, gap=0)
        row(cx, cy, [("house", 10 + i, {}) for i in range(4)], 1, gap=0)
        for k in range(10):
            S.tree(c, cx + r.uniform(-BW / 2 + 16, BW / 2 - 16), cy + r.uniform(-20, 20), h=r.uniform(20, 30), seed=r.randint(0, 999))

    def industrial(cx, cy):
        row(cx, cy, [("warehouse", 1, {})], -1)
        row(cx, cy, [("warehouse", 2, {"style": "tiltup"})], 1)

    layout = {(-2, 2): towers, (-1, 2): towers, (0, 2): towers, (1, 2): towers, (2, 2): midtown,
              (-2, 1): midtown, (-1, 1): towers, (0, 1): midtown, (1, 1): midtown, (2, 1): industrial,
              (-2, 0): retail, (-1, 0): midtown, (0, 0): retail, (1, 0): suburbs, (2, 0): industrial,
              (-2, -1): deco, (-1, -1): deco, (0, -1): suburbs, (1, -1): suburbs, (2, -1): suburbs,
              (-3, -1): deco, (-3, 0): midtown, (-3, 1): midtown, (-3, 2): towers, (-3, 3): midtown,
              (-2, 3): midtown, (-1, 3): towers, (0, 3): midtown, (1, 3): industrial, (2, 3): industrial,
              (3, -1): suburbs, (3, 0): suburbs, (3, 1): industrial, (3, 2): industrial, (3, 3): suburbs}
    for (ix, iy), f in layout.items():
        block(ix, iy, f)
    # avenue palms + lamps
    for i in range(len(xs) + 1):
        x = (xs[0] - 0.5 + i) * P
        for y in range(int((ys[0] - 0.5) * P), int((ys[-1] + 0.5) * P), 70):
            S.palm(c, x + ROAD_W / 2 + 4, y + 20, h=r.uniform(40, 56), seed=r.randint(0, 999))
            if night:
                S.street_lamp(c, x - ROAD_W / 2 - 2, y, facing=(1, 0), night=True)
    for k in range(40):
        S.car(c, r.choice([(xs[0] - 0.5 + i) * P for i in range(len(xs) + 1)]) + r.choice([-9, 9]),
              r.uniform((ys[0] - 0.5) * P, (ys[-1] + 0.5) * P), heading=r.choice([90, 270]), seed=k)
    ybeach = (ys[0] - 0.5) * P - ROAD_W / 2
    S.ground(c, -30000, ybeach - 40, 30000, 30000, "drygrass", z=-0.05, tile=40.0)
    S.ground(c, -30000, ybeach - 200, 30000, ybeach - 40, "sand", z=-0.05)
    S.ground(c, -30000, -30000, 30000, ybeach - 200, "sea", z=-0.1)
    for x in range(int((xs[0] - 0.5) * P), int((xs[-1] + 0.5) * P), 46):
        S.palm(c, x + r.uniform(-6, 6), ybeach - 22 + r.uniform(-6, 6), h=r.uniform(40, 56), seed=r.randint(0, 999))
    # mountains behind downtown (the Vinewood-hills backdrop) so the horizon is land, not a table edge
    S.hill(c, -12000, 3200, 12000, 12000, lambda x, y: max(0.0, min(1.0, (y - 3200) / 2500) * (
        420 + 160 * math.sin(x * 0.0009 + 0.7) + 90 * math.sin(x * 0.0027 + y * 0.0013) + 40 * math.sin(x * 0.011))),
           nx=120, ny=30, kind="drygrass")
    bpy.context.scene.world.mist_settings.depth = 4200.0
    return finish("block_night" if night else "block_wide", (-900, -760, 175), (40, 420, 70), 30, a.samples, a.res,
                  night=night, haze_amt=0.6)


VARIANTS = {  # arch: (seeds, extra kw, camera height factor)
    "tower": ([0, 1, 2, 3, 4], {}, 0.9), "midtown": ([0, 1, 2, 3, 4], {}, 0.8), "strip": ([0, 1, 2], {}, 1.4),
    "corner_store": ([0, 1, 2, 3], {}, 1.4), "gas": ([0, 1, 2], {}, 1.4), "diner": ([0, 1, 2], {}, 1.4),
    "deco": ([0, 1, 2, 3, 4], {}, 1.0), "house": ([0, 1, 2, 3, 4, 5], {}, 1.6), "warehouse": ([0, 1, 2], {}, 1.4),
    "mansion": ([0, 1, 3], {}, 1.4)}


def sc_variants(a, arch):
    """Several seeds of one archetype side by side, elevated 3/4 view: shows the parametric range."""
    S.reset(a.res)
    S.world("sky_late_afternoon", sun_az=-135.0)
    seeds, kw, hf = VARIANTS[arch]
    Bs = [BK.build(arch, sd, **kw) for sd in seeds]
    gap = 10.0
    total = sum(B.footprint[0] for B in Bs) + gap * (len(Bs) - 1)
    x = -total / 2
    Hmax = max(B.height for B in Bs)
    Dmax = max(B.footprint[1] for B in Bs)
    for B in Bs:
        W, D = B.footprint
        y = ROAD_W / 2 + SIDE_W + D / 2
        z = 0.0
        BK.instantiate(B, col(), loc=(x + W / 2, y, z), rot_z=0)
        if B.spawns:
            lot_cars(B, x + W / 2, y, 0, frac=0.4, seed=B.seed)
        x += W + gap
    avenue(-total / 2 - 80, total / 2 + 80, lamps=80, palms=None, cars=False, far_w=0)
    S.ground(col(), -3000, -3000, 3000, 3000, "grass" if arch in ("house", "mansion") else "sidewalk", z=-0.05)
    span = max(total, Hmax * 1.6)
    dist = span * 0.95
    cam = (-total * 0.18, ROAD_W / 2 + SIDE_W - dist, max(14.0, min(Hmax * hf, dist * 0.45)))
    tgt = (0.0, ROAD_W / 2 + SIDE_W + Dmax * 0.35, Hmax * 0.35)
    return finish("variants_" + arch, cam, tgt, 30, a.samples, a.res, haze_amt=0.35)


SCENES = {"downtown": sc_downtown, "midtown": sc_midtown, "strip": sc_strip, "gas": sc_gas, "diner": sc_diner,
          "store": sc_store, "deco": sc_deco, "suburbs": sc_suburbs, "industrial": sc_industrial,
          "mansion": sc_mansion, "block": sc_block,
          "deco_night": lambda a: sc_deco(a, night=True), "downtown_night": lambda a: sc_downtown(a, night=True),
          "block_night": lambda a: sc_block(a, night=True), "midtown_night": lambda a: sc_midtown(a, night=True)}
for _arch in VARIANTS:
    SCENES["variants_" + _arch] = (lambda ar: (lambda a: sc_variants(a, ar)))(_arch)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scene")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--samples", type=int, default=48)
    ap.add_argument("--res", type=int, nargs=2, default=(960, 540))
    a = ap.parse_args()
    a.res = tuple(a.res)
    if a.all:
        for name in SCENES:
            subprocess.run([sys.executable, "-I", os.path.abspath(__file__), "--scene", name, "--samples", str(a.samples),
                            "--res", str(a.res[0]), str(a.res[1])], check=False)
        return
    SCENES[a.scene](a)


if __name__ == "__main__":
    main()
