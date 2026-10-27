"""City art pack spec: every brand, billboard, sign, poster, graffiti piece and loading panel.

One source of truth for tools/cityart/process.py (raw -> final PNG), upload.py (PNG -> rbxassetid) and
gen_config.py (manifest -> src/shared/Config/CityArt.luau). All brands are our own parodies; no real brands,
no Rockstar/GTA names, no alcohol, gambling, smoking, romance or violence.

District ids match WorldLayout.Districts: downtown, midtown, beach, hills, foundry, rust, southgate, port,
airport, cactus, mesa.
"""

# Final pixel size per aspect (Roblox-friendly: longest side <= 1024).
SIZES = {
    "1:1": (512, 512),
    "2:1": (1024, 512),
    "1:2": (512, 1024),
    "8:3": (1024, 384),
    "2:3": (683, 1024),
    "16:9": (1024, 576),
}

# key -> brand. `logo` is the raw file stem; `station` is the exact radio station name in Config/Sounds.
BRANDS = {
    "patty_wagon": dict(name="Patty Wagon", category="fast_food", colors=["#B3121B", "#F2B705", "#FFF4DC"],
                        tagline="Feed the beast.", districts=["midtown", "southgate", "beach", "rust"]),
    "bean_there": dict(name="Bean There Coffee Co.", category="coffee", colors=["#1F4D3A", "#F3E9D2", "#C47F3A"],
                       tagline="Coffee so strong it has a record.", districts=["downtown", "midtown", "foundry"]),
    "nitro_cola": dict(name="Nitro Cola", category="cola", colors=["#D7141A", "#FFFFFF", "#1A1A1A"],
                       tagline="Tastes like a speeding ticket.", districts=[]),
    "overvolt": dict(name="Overvolt", category="energy_drink", colors=["#A6FF00", "#111111"],
                     tagline="Sleep is a myth.", districts=[]),
    "petrolux": dict(name="Petrolux", category="gas", colors=["#12355B", "#F2C14E"],
                     tagline="Fill up. Feel rich. Briefly.", districts=["midtown", "foundry", "beach", "mesa"],
                     poiBrand="Petrolux"),
    "sunburst": dict(name="Sunburst Gas", category="gas", colors=["#FF7A00", "#FFC20E", "#FFFFFF"],
                     tagline="Sunshine by the gallon.", districts=["southgate", "rust", "hills", "mesa"],
                     poiBrand="Sunburst"),
    "fuel_rush": dict(name="Fuel Rush", category="gas", colors=["#E10600", "#111111", "#FFFFFF"],
                      tagline="Gas. Snacks. Questionable hot dogs.", districts=["cactus", "mesa"],
                      poiBrand="Fuel Rush"),
    "coinstack": dict(name="Coinstack Savings", category="bank", colors=["#0E6E6E", "#D6B563"],
                      tagline="Your money is safe with us.*", districts=["midtown", "beach", "southgate", "foundry", "mesa"],
                      poiBrand="Coinstack"),
    "pinnacle_reserve": dict(name="Pinnacle Reserve Bank", category="bank", colors=["#0B1F3A", "#9699A1"],
                             tagline="Too big to fail.", districts=["downtown"]),
    "onebar": dict(name="OneBar Wireless", category="phone_carrier", colors=["#1E6BFF", "#9B9B9B", "#FFFFFF"],
                   tagline="Coverage. Mostly.", districts=["downtown", "midtown", "southgate"]),
    "vantara": dict(name="Vantara", category="car_maker", colors=["#B3121B", "#C0C0C0"],
                    tagline="You can't afford this. That's the point.", districts=["midtown", "hills"], segment="super"),
    "brutus": dict(name="Brutus Motors", category="car_maker", colors=["#111111", "#C0C0C0", "#C8102E"],
                   tagline="More horsepower than sense.", districts=["foundry", "rust", "cactus"], segment="muscle"),
    "kazoku": dict(name="Kazoku", category="car_maker", colors=["#D7141A", "#111111", "#FFFFFF"],
                   tagline="Built by family. Tuned by strangers.", districts=["southgate", "midtown"], segment="tuner"),
    "hotwire_motors": dict(name="Hotwire Motors", category="dealership", colors=["#FF8A3D", "#1E1E1E"],
                           tagline="Pre-owned. Pre-loved. Probably paid for.", districts=["midtown"]),
    "drip_district": dict(name="Drip District", category="fashion", colors=["#111111", "#FFFFFF", "#FF8A3D"],
                          tagline="Act rich.", districts=["midtown", "downtown", "beach"]),
    "iron_tide": dict(name="Iron Tide Fitness", category="gym", colors=["#13294B", "#2EC4B6"],
                      tagline="It's always summer. No excuses.", districts=["beach", "downtown"]),
    "cureall": dict(name="CureAll Pharmacy", category="pharmacy", colors=["#2BA84A", "#4D4D4D", "#FFFFFF"],
                    tagline="We have something for that.", districts=["midtown", "southgate", "downtown"]),
    "neon_fm": dict(name="Neon FM", category="radio", colors=["#FF2E88", "#2DE2E6", "#3A2E6E"],
                    tagline="24/7 synth. Zero talking.", districts=[], station="NEON FM"),
    "bass_drop": dict(name="Bass Drop 101", category="radio", colors=["#7B2FF7", "#FFFFFF", "#111111"],
                      tagline="Louder than your neighbors.", districts=[], station="BASS DROP 101"),
    "quikstop": dict(name="QuikStop 24", category="convenience", colors=["#D7141A", "#12924A", "#FFFFFF"],
                     tagline="Open 24 hours. Awake for 6.", districts=["southgate", "rust", "hills"],
                     poiBrand="QuikStop 24"),
    "sipngo": dict(name="Sip-N-Go", category="convenience", colors=["#1B4DB1", "#FF8A1D", "#FFFFFF"],
                   tagline="Brain freeze: $1.99", districts=["beach", "foundry", "downtown"], poiBrand="Sip-N-Go"),
    "lucky_mart": dict(name="Lucky Mart", category="convenience", colors=["#1E8C3A", "#FFD23F"],
                       tagline="Prices so low it's suspicious.", districts=["midtown", "mesa"], poiBrand="Lucky Mart"),
    "borrowed_wheels": dict(name="Borrowed Wheels Car Rental", category="rental", colors=["#FFC20E", "#111111"],
                            tagline="It's not stealing if you bring it back.", districts=["airport", "midtown", "beach"]),
    "overshare": dict(name="Overshare", category="tech", colors=["#6C3CF0", "#FF6B6B", "#2B2B2B"],
                      tagline="Post it before you think it.", districts=[]),
}
# raw stem for each logo (iron_tide was rerolled: the first mark read like a scope reticle)
LOGO_RAW = {k: "logo_" + k for k in BRANDS}
LOGO_RAW["iron_tide"] = "logo_iron_tide_v2"
LOGO_RAW["patty_wagon"] = "pilot_logo_med"
# logos whose generator left a soft semi-transparent halo; process.py hard-cuts it
LOGO_DEHALO = {"quikstop", "lucky_mart"}

# Billboards: wide 2:1 (generated 16:9, cropped) and portrait 1:2 (generated 9:16, cropped).
# o = crop offset along the cropped axis (0 = top/left, 0.5 = centre, 1 = bottom/right).
BILLBOARDS = [
    dict(id="bb_overvolt", raw="pilot_bb_high", brand="overvolt", aspect="2:1", copy="SLEEP IS A MYTH."),
    dict(id="bb_patty_wagon", brand="patty_wagon", aspect="2:1", copy="FEED THE BEAST."),
    dict(id="bb_nitro_cola", brand="nitro_cola", aspect="2:1", copy="TASTES LIKE A SPEEDING TICKET."),
    dict(id="bb_onebar", brand="onebar", aspect="2:1", copy="COVERAGE. MOSTLY."),
    dict(id="bb_coinstack", brand="coinstack", aspect="2:1", copy="YOUR MONEY IS SAFE WITH US.*"),
    dict(id="bb_vantara", brand="vantara", aspect="2:1", o=0.2, copy="YOU CAN'T AFFORD THIS. THAT'S THE POINT."),
    dict(id="bb_brutus", brand="brutus", aspect="2:1", copy="MORE HORSEPOWER THAN SENSE."),
    dict(id="bb_kazoku", brand="kazoku", aspect="2:1", bokeh=(560, -40, 1100, 180), copy="BUILT BY FAMILY. TUNED BY STRANGERS."),
    dict(id="bb_borrowed_wheels", brand="borrowed_wheels", aspect="2:1", blur=[(598, 326, 50, 24)], copy="IT'S NOT STEALING IF YOU BRING IT BACK."),
    dict(id="bb_cureall", brand="cureall", aspect="2:1", copy="WE HAVE SOMETHING FOR THAT."),
    dict(id="bb_bean_there", brand="bean_there", aspect="2:1", copy="COFFEE SO STRONG IT HAS A RECORD."),
    dict(id="bb_overshare", brand="overshare", aspect="2:1", copy="EVERYONE IS WATCHING. ISN'T THAT NICE?"),
    dict(id="bb_hotwire_motors", brand="hotwire_motors", aspect="2:1", fix="hotwire_motors_bar",
         blur=[(238, 373, 15, 10), (495, 368, 14, 9), (695, 338, 13, 9), (838, 362, 12, 8), (937, 357, 12, 8), (1012, 337, 12, 9)],
         copy="PRE-OWNED. PRE-LOVED. PROBABLY PAID FOR."),
    dict(id="bb_petrolux", brand="petrolux", aspect="2:1", copy="FILL UP. FEEL RICH. BRIEFLY."),
    dict(id="bb_drip_district", brand="drip_district", aspect="2:1", o=0.3, copy="THIS HOODIE COSTS MORE THAN YOUR CAR."),
    dict(id="bb_neon_fm", brand="neon_fm", aspect="2:1", copy="24/7 SYNTH. ZERO TALKING."),
    dict(id="bb_iron_tide", brand="iron_tide", aspect="2:1", copy="IT'S ALWAYS SUMMER. NO EXCUSES."),
    dict(id="bb_tourism", brand=None, aspect="2:1", o=0.3, copy="SUN. SURF. LOCK YOUR DOORS."),
    dict(id="bbp_overvolt", brand="overvolt", aspect="1:2", copy="BLINK LESS."),
    dict(id="bbp_sunburst", brand="sunburst", aspect="1:2", copy="SUNSHINE BY THE GALLON."),
    dict(id="bbp_fuel_rush", brand="fuel_rush", aspect="1:2", copy="GAS. SNACKS. QUESTIONABLE HOT DOGS."),
    dict(id="bbp_quikstop", brand="quikstop", aspect="1:2", copy="OPEN 24 HOURS. AWAKE FOR 6."),
    dict(id="bbp_sipngo", brand="sipngo", aspect="1:2", copy="BRAIN FREEZE: $1.99"),
    dict(id="bbp_lucky_mart", brand="lucky_mart", aspect="1:2", copy="PRICES SO LOW IT'S SUSPICIOUS."),
    dict(id="bbp_pinnacle_reserve", brand="pinnacle_reserve", aspect="1:2", copy="TOO BIG TO FAIL."),
    dict(id="bbp_bass_drop", brand="bass_drop", aspect="1:2", copy="LOUDER THAN YOUR NEIGHBORS."),
    dict(id="bbp_onebar", brand="onebar", aspect="1:2", copy="5G* (*5 GLITCHES PER MINUTE)"),
    dict(id="bbp_bean_there", brand="bean_there", aspect="1:2", copy="WE SPELL YOUR NAME WRONG ON PURPOSE."),
    dict(id="bbp_patty_wagon", brand="patty_wagon", aspect="1:2", copy="BREAKFAST AT 3 AM. WE DON'T JUDGE."),
    dict(id="bbp_drip_district", brand="drip_district", aspect="1:2", copy="ACT RICH."),
]

# Storefront signs. kind: fascia (8:3 box/channel-letter band), awning (2:1 valance), painted (2:1 board),
# pylon (1:2 roadside sign). poiBrand / poi tie a sign to WorldLayout POIs (POI.brand / POI.name prefix).
SIGNS = [
    dict(id="sign_quikstop", brand="quikstop", kind="fascia", districts=["southgate", "rust", "hills"], poiBrand="QuikStop 24"),
    dict(id="sign_sipngo", brand="sipngo", kind="fascia", districts=["beach", "foundry", "downtown"], poiBrand="Sip-N-Go"),
    dict(id="sign_lucky_mart", brand="lucky_mart", kind="fascia", districts=["midtown", "mesa"], poiBrand="Lucky Mart"),
    dict(id="sign_petrolux", brand="petrolux", kind="fascia", districts=["midtown", "foundry", "beach", "mesa"], poiBrand="Petrolux", use="gas_canopy"),
    dict(id="sign_sunburst", brand="sunburst", kind="fascia", districts=["southgate", "rust", "hills", "mesa"], poiBrand="Sunburst", use="gas_canopy"),
    dict(id="sign_fuel_rush", brand="fuel_rush", kind="fascia", districts=["cactus"], poiBrand="Fuel Rush", use="gas_canopy"),
    dict(id="sign_coinstack", brand="coinstack", kind="fascia", districts=["midtown", "beach", "southgate", "foundry", "mesa"], poiBrand="Coinstack"),
    dict(id="sign_pinnacle_reserve", brand="pinnacle_reserve", kind="fascia", districts=["downtown"], poi="Pinnacle Reserve Bank"),
    dict(id="sign_patty_wagon", brand="patty_wagon", kind="fascia", districts=["midtown", "southgate", "beach", "rust"]),
    dict(id="sign_cureall", brand="cureall", kind="fascia", districts=["midtown", "southgate", "downtown"]),
    dict(id="sign_onebar", brand="onebar", kind="fascia", districts=["downtown", "midtown", "southgate"]),
    dict(id="sign_drip_district", brand="drip_district", kind="fascia", districts=["midtown", "downtown", "beach"]),
    dict(id="sign_iron_tide", brand="iron_tide", kind="fascia", districts=["beach", "downtown"]),
    dict(id="sign_borrowed_wheels", brand="borrowed_wheels", kind="fascia", districts=["airport", "midtown", "beach"]),
    dict(id="sign_hotwire_motors", brand="hotwire_motors", kind="fascia", districts=["midtown"], poi="Hotwire Motors"),
    dict(id="sign_legendaire", name="Legendaire Autos", kind="fascia", districts=["midtown"], poiBrand="Legendaire", poi="Legendaire Autos"),
    dict(id="sign_hotwire_customs", name="Hotwire Customs", kind="fascia", districts=["rust", "beach", "mesa"], poiBrand="Hotwire Customs"),
    dict(id="sign_fresh_coat", name="Fresh Coat Paint & Body", kind="fascia", districts=["midtown", "southgate", "foundry", "hills"], poiBrand="Fresh Coat"),
    dict(id="sign_lock_load", name="Lock & Load Sporting Goods", kind="fascia", districts=["southgate", "foundry", "beach", "mesa"], poiBrand="Lock & Load"),
    dict(id="sign_glitter_gold", name="Glitter & Gold Jewelers", kind="fascia", districts=["midtown"], poi="Glitter & Gold Jewelers"),
    dict(id="sign_stackhouse", name="Stackhouse Security", kind="fascia", districts=["rust"], poi="Stackhouse Security Depot"),
    dict(id="sign_dockside_salvage", name="Dockside Salvage", kind="fascia", districts=["port"], poi="Dockside Salvage"),
    dict(id="sign_mount_mercy", name="Mount Mercy Medical Center", kind="fascia", districts=["downtown"], poi="Mount Mercy Medical Center"),
    dict(id="sign_muscle_beach", name="Muscle Beach Gym", kind="fascia", districts=["beach"], poi="Muscle Beach Gym"),
    dict(id="sign_foundry_records", name="Foundry Records", kind="fascia", districts=["foundry"]),
    dict(id="sign_spin_city", name="Spin City Laundromat", kind="fascia", districts=["southgate", "rust"]),
    dict(id="awning_bean_there", raw="awning_bean_there", brand="bean_there", kind="awning", districts=["downtown", "midtown", "foundry"]),
    dict(id="awning_taco_tsunami", name="Taco Tsunami", kind="awning", districts=["beach"]),
    dict(id="awning_fade_away", name="Fade Away Barbers", kind="awning", districts=["southgate", "foundry"]),
    dict(id="awning_glazed_confused", name="Glazed & Confused Donuts", kind="awning", districts=["southgate", "midtown"]),
    dict(id="awning_palmera_surf", name="Palmera Surf Co.", kind="awning", districts=["beach"]),
    dict(id="sign_rustys_chop", name="Rusty's Chop Shop", kind="painted", districts=["rust"], poi="Rusty's Chop Shop"),
    dict(id="pylon_sleepy_cactus", name="Sleepy Cactus Motel", kind="pylon", districts=["cactus"], poi="Sleepy Cactus Motel"),
    dict(id="pylon_rattlesnake_diner", name="Rattlesnake Diner", kind="pylon", districts=["cactus"], poi="Rattlesnake Diner"),
]
SIGN_ASPECT = {"fascia": "8:3", "awning": "2:1", "painted": "2:1", "pylon": "1:2"}

# Street posters, flyers and bus-shelter ads (all 2:3).
POSTERS = [
    dict(id="flyer_missing_car", kind="flyer", districts=["midtown", "southgate"], title="Missing: my car"),
    dict(id="flyer_lost_cat", kind="flyer", districts=["southgate", "beach"], title="Lost cat: Sir Fluffington"),
    dict(id="flyer_for_rent", kind="flyer", districts=["downtown", "midtown"], title="For rent: 1 bed, 0 windows"),
    dict(id="poster_synth_night", kind="poster", brand="neon_fm", districts=["beach", "foundry"], title="Sunset Synth Night"),
    dict(id="poster_mayor", kind="poster", districts=["downtown", "midtown", "southgate"], title="Re-elect Mayor Buck Hansen"),
    dict(id="poster_arena", kind="poster", districts=["southgate", "downtown"], title="Hammerheads vs Scorpions"),
    dict(id="poster_speedway", kind="poster", districts=["cactus", "mesa", "rust"], title="Dustbowl Speedway"),
    dict(id="poster_hcpd_psa", kind="poster", districts=["downtown", "midtown", "southgate"], title="Lock it or lose it"),
    dict(id="bus_overshare", kind="busstop", brand="overshare", title="Delete nothing."),
    dict(id="bus_kazoku", kind="busstop", brand="kazoku", title="0 to 60 in yes."),
    dict(id="bus_cureall", raw="bus_cureall_v2", kind="busstop", brand="cureall", title="Allergies? Aisle 4."),
    dict(id="bus_iron_tide", raw="bus_iron_tide_v2", kind="busstop", brand="iron_tide", title="Do you even lift?"),
    dict(id="bus_sipngo", kind="busstop", brand="sipngo", title="May cause brain freeze."),
    dict(id="bus_borrowed_wheels", kind="busstop", brand="borrowed_wheels", title="Return it full. Or at all."),
]

# Graffiti: tags/stencils have alpha (decals over any wall); murals are opaque wall paintings. No gang imagery.
GRAFFITI = [
    dict(id="tag_hotwire", kind="tag", aspect="2:1", alpha=True, districts=["rust", "foundry", "southgate"]),
    dict(id="tag_palmera", kind="tag", aspect="2:1", alpha=True, districts=["beach"]),
    dict(id="tag_southgate", kind="tag", aspect="2:1", alpha=True, districts=["southgate"]),
    dict(id="tag_hotwire_city_script", kind="tag", aspect="2:1", alpha=True, districts=["beach", "midtown", "foundry"]),
    dict(id="stencil_sir_fluffington", kind="stencil", aspect="1:1", alpha=True, districts=["foundry", "southgate", "midtown"]),
    dict(id="stencil_foundry_key", kind="stencil", aspect="1:1", alpha=True, districts=["foundry"]),
    dict(id="mural_palmera_postcard", kind="mural", aspect="2:1", alpha=False, districts=["beach"]),
    dict(id="mural_foundry_face", kind="mural", aspect="2:1", alpha=False, districts=["foundry"]),
    dict(id="mural_coast_cruiser", raw="mural_coast_cruiser_v2", kind="mural", aspect="2:1", alpha=False, districts=["southgate", "beach"]),
    dict(id="mural_whale", kind="mural", aspect="2:1", alpha=False, districts=["beach", "port"]),
]

# Loading-screen key art (16:9) with the HOTWIRE CITY wordmark composited by process.py.
LOADING = [
    dict(id="loading_crew", title="The Crew"),
    dict(id="loading_chase", title="The Chase", wordmark="top"),
    dict(id="loading_hotwire", raw="loading_hotwire_v1", title="Hotwired"),
]


# CONTENT SAFETY (docs/v2/CONTENT_SAFETY.md): removed after the 2026-10-27 account moderation ("Privacy: Giving PII"
# on photoreal people). Never re-add photoreal people, faces, phone numbers, names or political content.
EXCLUDED = {
    "bb_overshare", "bus_iron_tide", "bb_iron_tide", "bus_overshare", "bb_drip_district", "bbp_drip_district",
    "poster_arena", "poster_mayor", "flyer_missing_car", "flyer_lost_cat", "flyer_for_rent", "bbp_bean_there",
    "loading_crew", "loading_hotwire", "loading_chase",
}


def _keep(item):
    return item["id"] not in EXCLUDED


BILLBOARDS = [b for b in BILLBOARDS if _keep(b)]
SIGNS = [s for s in SIGNS if _keep(s)]
POSTERS = [p for p in POSTERS if _keep(p)]
GRAFFITI = [g for g in GRAFFITI if _keep(g)]
LOADING = [x for x in LOADING if _keep(x)]


def all_items():
    """Yield (category, item) with raw stem, aspect and final file path filled in."""
    for k in BRANDS:
        yield "logos", dict(id="logo_" + k, raw=LOGO_RAW[k], aspect="1:1", alpha=True, brand=k)
    for b in BILLBOARDS:
        yield "billboards", dict(b, raw=b.get("raw", b["id"]), alpha=False)
    for s in SIGNS:
        yield "signs", dict(s, raw=s.get("raw", s["id"]), aspect=SIGN_ASPECT[s["kind"]], alpha=False)
    for p in POSTERS:
        yield "posters", dict(p, raw=p.get("raw", p["id"]), aspect="2:3", alpha=False)
    for g in GRAFFITI:
        yield "graffiti", dict(g, raw=g.get("raw", g["id"]))
    for item in LOADING:
        yield "loading", dict(item, raw=item.get("raw", item["id"]), aspect="16:9", alpha=False)
