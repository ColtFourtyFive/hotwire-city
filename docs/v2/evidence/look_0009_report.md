# Job 0009 report: the v2 look on the real place (version 29/30)

## Setup

- **Studio:** 0.744.0.7441077. The place was reopened from Roblox (Team Create off) by the owner at my request.
  - `game.PlaceVersion` reads 0 in Edit, which is normal there.
  - The place content matches version 29+: 22 MaterialVariants and the HDRI day sky.
- **Code:**
  - `main` was at `e59a823` when the job started. The lead then announced version 30, so I pulled `2e5b890` (the v30 lighting fixes).
  - Rojo live-synced it, and I confirmed the new `LightingService` was present (night clock hold and dedupe) before the shots.
  - The v30 changes are code plus a project-file tweak, so this session matches v30.
- **Shots:** Play (solo), 45 s wait. Locks were set with `workspace:SetAttribute("TimeOfDayLock", …)` on the Server, 5 s before each set of shots.
- **Not saved or published.**

## Step 2: inspection

### MaterialService
- **22 children.** All are HC_ variants, with base materials as expected:
  - Asphalt: HC_Asphalt, HC_AsphaltWet, HC_AsphaltWorn.
  - Concrete: HC_Concrete, HC_ConcreteModern.
  - Brick: HC_BrickRed, HC_BrickTan.
  - Plaster: HC_Stucco.
  - Pavement: HC_Sidewalk.
  - Grass and ground: HC_Grass, HC_GrassLeafy, HC_DryGrass.
  - Metal: HC_CorrugatedMetal, HC_RustyMetal.
  - Roof: HC_RoofTiles, HC_GravelRoof.
  - Rock and sand: HC_Rock, HC_RockSlate, HC_Sand.
  - Other: HC_WoodPlanks, HC_Terrazzo, HC_WindowGlass.
- **⚠️ No base-material overrides are active.**
  - `MaterialService:GetBaseMaterialOverride(m)` returns the stock material name for Asphalt, Pavement, Concrete, Brick, Plaster, Grass, Metal, Wood, Sand, Cobblestone and Slate. It's the same in Edit, on the Server and on the Client.
  - `MaterialService.AsphaltName` isn't a scriptable member.
  - So the uploaded place has the variants, but the per-material overrides (`AsphaltName = "HC_Asphalt"` and so on) did not survive the upload or weren't set.
- **⚠️ The v1 world uses none of the overridden materials anyway.**
  - Of 8,883 parts: SmoothPlastic 6,473, Plastic 1,029, Neon 785, Glass 203, CorrodedMetal 150, Wood 96, Grass 87, Metal 86.
  - There is no Asphalt, Brick, Concrete, Pavement or Plaster, and **0 parts set `MaterialVariant`**.
  - **So no PBR material can appear on v1 at all.** That waits for the v2 world, or for parts to be retagged.

### Lighting (Edit, as reopened)
- **`LightingStyle = Soft`.** The value Studio sees is still Soft, not Realistic.
- `PrioritizeLightingQuality = true`.
- **Children in Edit:** Sky ×2, Atmosphere ×2, Bloom ×2, SunRays ×2, ColorCorrection and DepthOfField. The duplicates are saved in the place.
  - Both Skies are the HDRI day sky (Ft `109667193500398`).
  - Both Atmospheres are D 0.27 / O 0.25 / H 0.90.
- **At runtime, v30's LightingService dedupes:** the console shows `[LightingService] destroyed 4 duplicate Lighting effect(s)`. Server and Client then have exactly one each of Sky, Atmosphere, Bloom, ColorCorrection, SunRays and DepthOfField. ✅

## Step 4: shots, before and after

Before shots from job 0001 are copied in as `before_0001_*.png`. In 0001, `downtown_street` was taken at daytime, and the other two at 0001's night (ClockTime ≈ 19.9).

### Noon (lock 13)
- **`noon_overview_low_sw`:**
  - The **HDRI day sky is a big improvement** on 0001's flat purple: realistic cumulus and a natural pale horizon.
  - **But the far haze is still a flat grey wall.** Beyond about 350–400 studs, everything fades into a uniform grey band, so downtown (≈1000 studs from this camera) is hidden. Same problem as 0001's `overview_high`.
  - The suburban blocks in front read clean and well lit, with better contrast than 0001.
- **`noon_downtown_street`:**
  - The camera is inside the dealership canopy, as in 0001.
  - The sky behind the towers is a **flat purple-grey**, not the HDRI. Seen through the canopy gap, the haze hides it.
  - Colours look the same as v1: neon pink, cyan and white plastic. Lighting is softer and a little greyer.
- **`noon_spawn_player_view`:**
  - **Behaviour change since 0001: the player now spawns inside their own garage** (0001 spawned outside by a parked car).
  - Interior lighting is even and readable. There is nothing sky-related to judge.
- **`noon_asphalt_close`** (road `Map.Roads.Road_X-5` from 6 studs):
  - The road is **SmoothPlastic `#3A3D50` with the old tile-grid texture**. No PBR asphalt, as expected from the material scan.
  - A sun shadow falls across it with **jagged, stair-stepped edges**: shadow-map aliasing, worse than Future would give.
- **`noon_brick_close`:**
  - **v1 has no brick walls.** I used the Police HQ facade instead.
  - It is a stylised mesh with a **soft, blurry baked texture** and chunky blue window frames, so there is no material realism to judge.

### Golden hour (lock 17.6)
- The engine clock was 17.60, Brightness 2.79, Haze 0.80.
- **The sky stays the day HDRI**, because v30 dropped the golden swap. The **atmosphere turns brown/sepia**, which reads as dusty, smoggy LA, not warm golden.
- **`golden_overview_low_sw`:** a **large pale moon disc** sits on the horizon, opposite the sun. It reads odd next to a bright cumulus day sky.
- **`golden_downtown_street`:** warmer and a little darker than noon, with the neon still strong. A mild improvement.
- **`golden_spawn_player_view`:** the garage interior goes dark charcoal. Neon trim pops more.

### Night (lock 22.5)
The v30 clock hold works:
- The engine clock is held at **18.20** (sun −2.9°).
- The night sky is applied (Ft `98461351795375`, yaw −72.6).
- Exposure −0.30, Brightness 0.40, Haze 0.35.

**❌ But it is far too dark:**
- **`night_downtown_street`:** almost black. Only the neon strips, rings and billboards show.
- **`night_overview_low_sw`:** **completely black.** No sky, no buildings, no streets — only the HUD.

**Diagnosis** (`diag_night_exposure2_overview.png`):
- I set Exposure +2 and Brightness 2 on the client for one capture, then restored the values.
- **The night HDRI then shows** (dark red-brown clouds), and the whole city reads well.
- So the skybox is **not** blacked out any more. The night preset is simply **exposed about 2 stops too dark**.
- **Suggested starting point:** Brightness about 1.2, Exposure about +0.6 to +1.0, and an OutdoorAmbient lift. Then retune by eye.
- **Sky colour:** the night sky reads **reddish-brown**, not the navy-grey the lab showed at a daytime clock. Expect a colour-correction tint toward blue.

**`night_spawn_player_view` was not captured**, because Play ended first; see below.

## Errors and console (`console.txt`)

**Play was ended by a kick:** `[DataService] session lost for 11686693147 (profile opened elsewhere)`, then `Server Kick Message: Your Hotwire City save was opened on another server. Please rejoin!`.
- A **second Studio instance** (id `34a9b371…`) appeared, in **Play** mode on the same place. I didn't start it.
- Its server loaded the same player profile and stole the session lock.
- **The DataService session lock is working as designed.** Avoid two simultaneous Play sessions for the same account.

**Other console lines:**
- 20 old v1 asset IDs fail with "Asset type does not match requested type", each logged three times. Seen since 0001.
- `rbxassetid://203785492` (type mismatch) and **`rbxassetid://4542793421`: "User is not authorized to access Asset"**. The second is new, private or owned by someone else; ×6.
- `[AssetLibrary] Props/flower_bed unavailable; using procedural fallback`.
- **No script errors** on Server or Client.

## Verdict

- **Better:**
  - The HDRI day sky (in the open view).
  - Runtime Lighting dedupe.
  - The night clock hold: no black skybox any more.
- **Unchanged:**
  - Materials. Nothing on v1 uses the overridden base materials, and the overrides aren't active either.
- **Worse or broken:**
  - Night exposure: too dark, nearly unplayable from above.
  - The golden atmosphere reads sepia and brown, and a big moon shows at the golden-hour horizon.
- **Still open:**
  - The far haze wall hides the city from overview heights.
  - `LightingStyle` is still Soft.
  - Jagged shadows.
