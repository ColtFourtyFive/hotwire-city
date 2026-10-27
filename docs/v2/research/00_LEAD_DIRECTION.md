# V2 Lead Direction (binding)

This file outranks every other research note or plan draft. If a draft conflicts with it, this file wins.

## The verdict that triggered v2

The user ran v1 in the real Roblox engine for the first time on 2026-10-27, through Studio via the operator. The screenshots are in `docs/v2/evidence/v1_real_engine/`. The user's words:

> "right now this look and feels NOTHING like GTA or the idea or vision… this is nowhere near close"
>
> "these look like some very basic rudimentary roblox game. nothing like the look and feel of GTA. so far off right now. we need serious work."

What the real-engine screenshots show:

- **`spawn_dealership.jpg`**
  - Everything is pastel pink, with neon-pink stripes on every edge.
  - Lighting is flat, with no depth.
  - The AI-generated building mesh is smeared, low-detail and textured with blotches.
  - The chunky "kids simulator" UI uses FredokaOne. A huge tutorial card sits in the centre of the screen.
  - The characters are default blocky dummies.
  - A hot-dog cart and a gold meme car are the hero objects.
- **`overview_high_haze.jpg`**: from the sky, the city is invisible. There is only brown haze, because Atmosphere density or haze is too high, or the camera sits inside geometry.
- **The console** shows `Asset content representation is being generated` failures for several freshly uploaded assets.

## User decisions (2026-10-27)

1. **Look: grounded GTA V realism.**
   - Real city scale and density.
   - Asphalt, concrete, brick and glass PBR materials.
   - Realistic cars under GTA-style parody brands.
   - Cinematic sun, haze and night lighting.
   - A minimal GTA-style HUD: minimap bottom-left with health and armor bars, cash and wanted stars top-right, small help text top-left.
   - Realistic NPC outfits.
2. **Combat: GTA-style guns, no gore.**
   - Weapons: pistols, SMGs, rifles, shotguns and melee.
   - Police shoot back at higher wanted levels.
   - No blood or dismemberment. A downed player gets a **WASTED** screen and respawns at the hospital. Getting caught gives **BUSTED**.
   - Maturity: Moderate, ages 13+. The experience is already age-rated 13+.

## What "GTA look & feel" means here (the acceptance checklist)

**World**
- A believable LA/Miami-inspired coastal city at real scale, with:
  - wide multi-lane avenues with lane markings, crosswalks, curbs, sidewalks and street furniture;
  - an elevated freeway with ramps and an overpass;
  - downtown glass towers forming a skyline;
  - a beach boardwalk and pier;
  - a port with cranes and containers;
  - hills with mansions and a giant hillside letter sign (a "Vinewood" parody, with our own name);
  - suburbs, an industrial zone, and a countryside or desert highway loop for speed.
- Dense and alive:
  - traffic that stops at lights;
  - pedestrians who walk, talk, flee and react;
  - parked cars on the streets;
  - planes and helicopters overhead.

**Materials and lighting**
- PBR MaterialVariants: cracked asphalt, concrete paving, brick, stucco, glass curtain walls, metal.
- Future lighting, a realistic sky (an HDRI skybox), golden-hour warmth, atmospheric perspective that does not hide the city, real shadows, wet-street reflections at night, and practical lights (street lamps, signs, headlights, police lights lighting the environment).

**Vehicles**
- Realistic proportions, glass, chrome, working lights and separately spinning wheels.
- Paint is customizable, using GTA-style brand parodies.
- Classes: sedans, coupes, muscle, sports, super, SUVs, trucks, vans, motorcycles (later), police, taxi, bus, ambulance and fire truck.
- Weight in driving: body roll, momentum, drifting with smoke and skids, crash sparks and deformation feedback.
- Meme cars (Rubber Ducky, Toilet Turbo, Couch…) are **not** core content. Keep at most a couple as hidden easter-egg collectibles, or remove them.

**Characters**
- Realistic outfits from the catalog: suits, jeans, hoodies, uniforms, cops in police uniforms.
- Animations: walking, idling, phone use, fleeing, hands up, cowering, aiming, shooting, entering cars.

**Presentation and UI**
- Follow GTA V's design language:
  - restrained;
  - condensed sans fonts (Oswald, Roboto Condensed or similar, as available in Roblox);
  - a heavy, Pricedown-like display font for WASTED, BUSTED and MISSION PASSED (use the closest Roblox font, never a kid font);
  - dark translucent panels.
- No chunky cartoon cards or giant centred tutorial boxes. Help text goes in a small box at the top left.
- Phone UI. Weapon wheel. A full-screen map with GPS.

**Camera and audio**
- A GTA-style third-person camera and chase cam.
- Realistic engine and gun audio.
- City ambience: sirens in the distance, horns, chatter.
- Radio stations.

**Police**
- A wanted level of 1–5 stars, with search cones and areas on the minimap.
- Patrol cars that ram and PIT.
- Roadblocks and spike strips.
- A helicopter with a searchlight and a sniper at 4★.
- SWAT vans at 5★.
- Escape by breaking line of sight and leaving the search area.

## Kill list (never again)

- Pastel-pink palettes and neon stripes on every edge.
- Kid-simulator UI: FredokaOne, chunky outlined cards, emoji icons.
- Blob-like AI meshes with smeared baked lighting.
- Flat lighting.
- Haze that hides the city.
- Default blocky NPCs.
- Meme vehicles as the main content.

## The vision (from the user's original chat, `original_brief.md`, which is binding)

The user's own words:

> "we are building GTA… steal cars, rob people, make money, buy guns and ammo, kill people, party up with friends or go solo… small missions… troll around… exactly the same as GTA"

The user also asked for **more** complexity, not less, and said time and complexity are not constraints.

The working title from that chat is **"Steal a Car: Heist City"**. The title is still open; Hotwire City is the current name.

Design pillars carried forward:

1. **The garage is a bank; the street is a casino.**
   - Parked cars earn money safely.
   - Driving your own car out earns 3–10× more, but it can be carjacked by players.
   - Car value = rarity × paint finish × level × upgrades.
   - Cars are upgraded and levelled **per car**.
   - Other players can steal your upgraded car and keep it. This needs fair-play protections: insurance, revenge targets and a recovery window.
2. **A full GTA sandbox.** Guns and ammo on a ladder from pistol to rifle, robbing stores and players' carried cash, missions, free roam, trolling, crews of 2–4 or solo.
3. **Shared server clock events.**
   - An armored truck every ~5 minutes.
   - A bank heist every ~30 minutes, done as a crew with roles.
   - Hot Drops.
   - Wanted stars multiply payouts, up to 3×. At 5★ the server gets a bounty on you.
4. **Progression.** Districts act as soft gates, ending at the Airport. Then rebirth and seasons.
5. **Viral layers.** "1 in X" rarity reveals, paint finishes, limited numbered cars, pink-slip races, jailbreaks, trading, weekly live events.

Ruled out:
- an exact GTA clone that uses Rockstar or GTA names;
- realistic blood;
- open PvP without protections;
- total loss of a car when it's stolen;
- pay-to-win.

## What stays from v1

The anti-exploit, data, economy, theft, garage and police foundations in `src/` stay and are refactored, not thrown away. The steal → escape → deliver → garage-income loop stays as the progression spine inside the GTA sandbox.

## Quality bar and references

| Area | References |
|---|---|
| Overall look | GTA V and the GTA VI trailers |
| Realism on Roblox | Southwest Florida, Greenville, Emergency Response: Liberty County (ER:LC) |
| Systems and chases | Jailbreak, Mad City |

Evidence standard: every visual milestone is verified by Studio operator screenshots, compared side by side with GTA reference images.
