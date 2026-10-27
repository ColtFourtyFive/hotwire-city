"""The production building set: every variant the game loads, sized from the v2 parcel contract
(tools/world/gen/Places.luau section 13; parcel stats in docs/v2/early/buildings/README.md).

Each variant is one uploaded Model (one MeshPart per material role). Runtime (src/server/Systems/BuildingService.luau)
picks a variant per parcel by family / footprint / height (deterministic by parcel seed), re-skins the wall material
and colour from the district palette, and only scales within tolerances, so a few dozen meshes dress ~1,100 lots.

Families (Config/Buildings.Families maps parcel use + style onto them):
  tower    planned skyline towers (160 x 160 lots, podium + setback + crown) and free-standing towers / slabs
  office   modern office / hotel mid-rise (tower archetype, 4-11 floors)
  midtown  brick / stucco walk-ups, lofts, apartments and street retail (0-11 floors); rows are composed of several
  deco     Palmera Beach art-deco hotels, apartments, cafes
  retail   suburban retail on its own lot: strip malls, convenience stores, diners
  house    single-family houses with yard / driveway (ranch, Spanish, two-storey tract)
  mansion  modern hillside mansions on a plinth (parcel use "mansion")
  villa    two-storey Spanish / tract villas with pool (parcel use "villa")
  industrial  warehouses, sheds, hangars, factories (truck court in front)
"""

V = []


def add(key, arch, family, seed, **kw):
    V.append({"key": key, "arch": arch, "family": family, "seed": seed, "kw": kw})


# ---------------------------------------------------------------------------------------------------------------- tower
# Planned skyline (160 x 160 lots; podium 40-70 studs, shaft setback 10-19). Hero heights follow the tower plan's
# top 12 (each with its own crown) and a ladder of generic planned heights for the 220-360 group.
HERO = [  # (height, crown, style, W)
    (640, "slant", "curtain", 160), (600, "stepped", "fins", 160), (570, "helipad", "grid", 160),
    (520, "lit_band", "curtain", 160), (495, "mech", "ribbon", 160), (475, "spire", "curtain", 160),
    (455, "slant", "fins", 180), (440, "stepped", "grid", 160), (415, "helipad", "ribbon", 160),
    (395, "lit_band", "fins", 160), (375, "mech", "curtain", 160), (350, "spire", "grid", 160),
]
for i, (h, crown, style, w) in enumerate(HERO):
    add(f"tower_hero{h}", "tower", "tower", 100 + i, W=w, D=160, target_h=h, crown=crown, style=style,
        podium_h=52 + (i % 3) * 8, inset=12 + (i % 4) * 2, setbacks=1 if h >= 440 else (i % 2), planned=True)
for i, h in enumerate([230, 260, 290, 320, 350]):
    for j, (crown, style) in enumerate((("mech", ["ribbon", "curtain", "grid", "fins", "ribbon"][i]),
                                        ("flat", ["grid", "fins", "curtain", "ribbon", "curtain"][i]))):
        add(f"tower_p{h}{'ab'[j]}", "tower", "tower", 200 + i * 2 + j, W=160, D=160, target_h=h, crown=crown,
            style=style, podium_h=44 + 10 * j, inset=14, setbacks=0, planned=True)
# free-standing towers and slabs (not in the plan): wide-shallow slabs, slim towers, blocks, big bases
for key, w, d, h, crown, style in (("slab170", 140, 84, 170, "flat", "ribbon"), ("slab210", 140, 84, 210, "mech", "grid"),
                                   ("slab250", 150, 86, 250, "flat", "curtain"), ("slab290", 140, 84, 290, "mech", "fins"),
                                   ("slim185", 76, 84, 185, "mech", "curtain"), ("slim235", 76, 84, 235, "flat", "grid"),
                                   ("block200", 110, 84, 200, "flat", "fins"), ("block245", 110, 90, 245, "mech", "ribbon"),
                                   ("big190", 172, 176, 190, "flat", "grid"), ("big235", 172, 176, 235, "mech", "curtain")):
    add(f"tower_{key}", "tower", "tower", 300 + len(V), W=w, D=d, target_h=h, crown=crown, style=style, setbacks=0)

# --------------------------------------------------------------------------------------------------------------- office
for key, w, d, floors, crown, style in (("w60f4", 60, 60, 4, "flat", "ribbon"), ("w60f7", 60, 60, 7, "mech", "grid"),
                                        ("w60f11", 60, 64, 11, "flat", "curtain"), ("w90f4", 90, 84, 4, "flat", "grid"),
                                        ("w90f7", 90, 84, 7, "flat", "curtain"), ("w90f9", 90, 84, 9, "mech", "ribbon"),
                                        ("w90f11", 90, 84, 11, "flat", "fins"), ("w130f4", 130, 84, 4, "flat", "ribbon"),
                                        ("w130f7", 130, 84, 7, "mech", "grid"), ("w130f11", 130, 90, 11, "flat", "curtain")):
    add(f"office_{key}", "tower", "office", 400 + len(V), W=w, D=d, floors=floors, crown=crown, style=style,
        setbacks=0, inset=4.0)

# -------------------------------------------------------------------------------------------------------------- midtown
WALLS = ["brick_red", "stucco", "brick_tan", "brick_painted", "brick_red", "stucco", "brick_tan", "stucco"]
for wi, (w, d) in enumerate(((44, 50), (60, 62), (78, 72))):
    for fi, floors in enumerate((0, 1, 2, 3, 4, 6, 8, 11)):
        wall = WALLS[(wi * 3 + fi) % len(WALLS)]
        esc = "front" if (wi + fi) % 3 == 0 else "back"
        add(f"midtown_w{w}f{floors}", "midtown", "midtown", 500 + wi * 10 + fi, W=w, D=d, floors=floors, wall=wall,
            escape=esc, balconies=(wi + fi) % 2 == 0 and floors <= 8)
        if floors <= 1:   # street retail is the most repeated: a second seed per width (other shops, signs, walls)
            add(f"midtown_w{w}f{floors}b", "midtown", "midtown", 540 + wi * 10 + fi, W=w, D=d, floors=floors,
                wall=WALLS[(wi * 3 + fi + 3) % len(WALLS)], escape=None, balconies=False)

# shallow row buildings for the many 25-40 deep lots (corner cut-offs, lots backed by another road)
for wi, w in enumerate((50, 74)):
    for fi, floors in enumerate((0, 1, 2, 4, 7, 10)):
        add(f"midtown_w{w}f{floors}s", "midtown", "midtown", 560 + wi * 10 + fi, W=w, D=32, floors=floors,
            wall=WALLS[(wi * 5 + fi + 2) % len(WALLS)], escape="front" if (fi % 3 == 1) else None,
            balconies=fi % 2 == 1 and floors <= 7)
# slim tall in-fill towers (45-56 wide, 170-200 tall: midtown office / apartment towers)
add("tower_slim170n", "tower", "tower", 390, W=54, D=56, target_h=170, crown="flat", style="ribbon", setbacks=0, inset=3.0)
add("tower_slim195n", "tower", "tower", 391, W=54, D=60, target_h=195, crown="mech", style="curtain", setbacks=0, inset=3.0)

# ----------------------------------------------------------------------------------------------------------------- deco
for w, floors in ((50, 2), (50, 3), (50, 4), (66, 2), (66, 3), (66, 4), (66, 6), (66, 8), (84, 3), (84, 4), (84, 6)):
    add(f"deco_w{w}f{floors}", "deco", "deco", 600 + w + floors, W=w, D=52 if w > 50 else 46, floors=floors)
for w, floors in ((66, 2), (84, 4), (100, 3), (100, 5)):   # shallow beachfront fronts (lots 30-40 deep)
    add(f"deco_w{w}f{floors}s", "deco", "deco", 650 + w + floors, W=w, D=24, floors=floors)

# --------------------------------------------------------------------------------------------------------------- retail
# mini-malls with one stall row along the storefronts (suburban retail lots are 60-110 deep)
add("retail_strip3", "strip", "retail", 701, units=3, unit_w=24.0, bd=40.0, canopy="flat", park_d=32.0)
add("retail_strip4", "strip", "retail", 702, units=4, unit_w=24.0, bd=40.0, canopy="mansard", park_d=32.0)
add("retail_strip5", "strip", "retail", 703, units=5, unit_w=24.0, bd=44.0, canopy="flat", park_d=62.0)
add("retail_store44", "corner_store", "retail", 711, W=44.0, bd=36.0)
add("retail_store50", "corner_store", "retail", 712, W=50.0, bd=40.0)
add("retail_store56", "corner_store", "retail", 713, W=56.0, bd=40.0)
add("retail_diner64", "diner", "retail", 721, bw=64.0)
add("retail_diner72", "diner", "retail", 722, bw=72.0)
# (gas stations: no parcel use maps to one; the forecourt POIs belong to the world builder)

# ---------------------------------------------------------------------------------------------------------------- house
for si, style in enumerate(("ranch", "spanish", "tract2")):
    for li, (w, d, sb, gw, hw, hd) in enumerate(((46, 62, 8, 13, 26, 30), (58, 80, 12, 23, 28, 34), (72, 100, 18, 23, 40, 38))):
        add(f"house_{style}{w}", "house", "house", 800 + si * 10 + li, style=style, W=w, D=d, setback=sb, garage_w=gw,
            hw=hw, hd=hd, pool=li == 2 and si != 2)
# narrow (36-wide townhouse-style) and shallow (lots 28-45 deep) houses
add("house_tract236", "house", "house", 821, style="tract2", W=36, D=64, setback=8, garage_w=11, hw=18, hd=30)
add("house_spanish38", "house", "house", 822, style="spanish", floors=2, W=38, D=60, setback=8, garage_w=11, hw=20, hd=30)
add("house_ranch56s", "house", "house", 823, style="ranch", W=56, D=38, setback=4, garage_w=13, hw=32, hd=26, porch=False)
add("house_spanish70s", "house", "house", 824, style="spanish", W=70, D=40, setback=4, garage_w=23, hw=38, hd=28)
add("house_tract262s", "house", "house", 825, style="tract2", W=62, D=40, setback=4, garage_w=23, hw=30, hd=28)
add("house_ranch84s", "house", "house", 826, style="ranch", W=84, D=40, setback=4, garage_w=23, hw=50, hd=28, porch=True)
add("house_villa84", "house", "villa", 831, style="spanish", floors=2, W=84, D=96, setback=16, hw=50, hd=40, pool=True)
add("house_villa96", "house", "villa", 832, style="spanish", floors=2, W=96, D=110, setback=20, hw=58, hd=44, pool=True)
add("house_villa90b", "house", "villa", 833, style="spanish", floors=2, W=90, D=100, setback=18, hw=54, hd=42, pool=True)
add("house_villa110", "house", "villa", 834, style="tract2", floors=2, W=110, D=110, setback=22, hw=66, hd=46, pool=True)
add("house_villa76s", "house", "villa", 835, style="spanish", floors=2, W=76, D=50, setback=6, hw=44, hd=34, pool=False)
# second seeds of the most-used house shapes (variety within one street)
add("house_tract262t", "house", "house", 841, style="tract2", W=62, D=40, setback=4, garage_w=23, hw=30, hd=28)
add("house_ranch62s", "house", "house", 842, style="ranch", W=62, D=42, setback=4, garage_w=23, hw=32, hd=28)
add("house_spanish58b", "house", "house", 843, style="spanish", W=58, D=80, setback=12, garage_w=23, hw=28, hd=34)
add("house_tract258b", "house", "house", 844, style="tract2", W=58, D=78, setback=12, garage_w=23, hw=28, hd=34)

# -------------------------------------------------------------------------------------------------------------- mansion
for i, (w, d) in enumerate(((96, 84), (110, 96), (130, 110), (150, 120))):
    for j in range(2):
        add(f"mansion_w{w}{'ab'[j]}", "mansion", "mansion", 900 + i * 2 + j, W=w, D=d, gw=min(72.0, w - 34.0),
            pool_w=min(48.0, w * 0.36))

# ----------------------------------------------------------------------------------------------------------- industrial
for key, bw, bd, h, style, court in (("shed60", 60, 44, 22, "metal", 40), ("shed90", 90, 60, 28, "metal", 50),
                                     ("wh110", 110, 70, 34, "tiltup", 86), ("wh130", 130, 80, 34, "metal", 86),
                                     ("wh150", 150, 90, 38, "tiltup", 86), ("wh200", 200, 110, 44, "tiltup", 86),
                                     ("wh240", 240, 140, 44, "metal", 86), ("urban80", 80, 70, 36, "tiltup", 24),
                                     ("urban120", 120, 90, 40, "tiltup", 30), ("hangar140", 140, 110, 50, "metal", 30),
                                     ("urban60s", 60, 34, 34, "tiltup", 12), ("urban100s", 100, 38, 42, "tiltup", 12),
                                     ("factory160", 160, 100, 56, "tiltup", 60), ("factory220", 220, 130, 60, "tiltup", 70)):
    add(f"industrial_{key}", "warehouse", "industrial", 1000 + len(V), bw=float(bw), bd=float(bd), h=float(h),
        style=style, court=float(court))

KEYS = [v["key"] for v in V]
assert len(KEYS) == len(set(KEYS)), "duplicate variant keys"
