# Job 0007 report: lighting lab round 2 (Haze vs Offset, four HDRI skies, sky yaw sign)

- **Studio:** 0.744.0.7441077, Hotwire City place 106226892419530, Edit mode only. Play was never started, and the place was not saved.
- **Code:** `main` is at **`289952c`** ("stylua after v2/look merge").
  - The merge added ~330 lines to `default.project.json`, including a **Lighting** node. Rojo synced it.
  - Studio had been restarted (new studio id `87e98a63…`) and had **rejoined Team Create**.
- **Editor Quality Level:** **Level21** (the maximum). It was already set; I left it.
- **CLEANUP:** done and verified.
  - `Workspace.HCLightingLab` is gone, and the Workspace is back to Terrain, SpawnLocation, Baseplate and Camera. Baseplate transparency is 0.
  - Lighting is back to its 10 original children and ClockTime 11, the saved value.
  - All of my `_G` helpers are cleared.

## ⚠️ Problems with the place itself (read first)

1. **Rojo's Lighting sync is broken.**
   - The Output shows `[Rojo-Warn] Could not swap instances Lighting and Lighting during sync replacement: Cannot change Parent of type Lighting`.
   - Lighting now holds **duplicates**: `Sky ×2, Atmosphere ×2, Bloom ×2, SunRays ×2`, plus `ColorCorrection` and `DepthOfField`.
   - **`LightingStyle` reads `Soft`**, while `default.project.json` sets `"LightingStyle": "Realistic"`. The property sync did not apply.
   - Rojo cannot re-parent a service. Consider letting LightingService create the children at runtime, or giving the project file `$properties` only, with no Lighting children.
2. **The place has no MaterialVariants:** `MaterialService` has 0 children. S4 was skipped.

## S0: sky yaw sign → **yawSign = +1**

| Shot | Visible face |
|---|---|
| `s0_yaw0.png` (yaw 0, facing −Z) | **FT "−Z"**. RT shows at the right edge. |
| `s0_yaw90.png` (yaw 90, facing −Z) | **LF "−X"**. FT shows at the right edge. |

- This matches `CFrame.Angles` with **yawSign = +1**: yaw 0 shows Ft, yaw 90 shows Lf.
- Both labels read normally, not mirrored.
- `*_noatm.png` are the same shots with the Atmosphere removed, for legibility.
- **Side finding:**
  - On the first S0 shot, the **day Atmosphere (Density 0.27, Haze 0.9) almost completely hid the test-kit sky**; see `s0_yaw0_streaming_race.png`.
  - It was partly a texture-streaming race: the HDRI skies load on first use, so I pre-warmed all four.
  - But the haze still strongly washes out the sky near the horizon. That is expected, and fine for HDRI skies.

## S1: Haze × Offset grid (day, Density 0.27, ClockTime 14.2)

**Main finding: Offset makes no visible difference at Density 0.27.**
- Across Offset 0 / 0.25 / 0.5 at every Haze, the `skyline` shots are pixel-identical in mean colour in every region I sampled: sky, haze band, horizon band, far towers and grass. Example at Haze 0.8: sky band (149,151,153), far towers (97,105,114) in all three.
- `elevated` differs by only 1–3 levels.
- I added a control at **Offset 1.0** (`control_h0.4_o1.0_skyline.png`), which is also identical.
- To prove the captures weren't stale, I also took **Haze 3.0** (`control_h3.0_o0.0_skyline.png`): the whole sky turns grey.
- **Conclusion:** at this Density, Offset can't be tuned from these cameras. **Lock `Look.Tuning.offset` to whatever the old value was (0.25) and stop tuning it.**

**Haze effect** (the only knob that moved anything):
- The sky band just above the horizon goes from (159,159,161) at Haze 0.4, to (149,151,153) at 0.8, to (141,143,145) at 1.2. It gets darker and greyer.
- The painted HDRI clouds stay visible at every value.
- The far towers (450–950 studs) stay readable in every cell. Their colour barely changes, because Density 0.27 sets the distance fade.

**A hard horizon band** appears in every cell: the 2400-stud ground ends and the flat grey Atmosphere band starts. This is a lab artefact; in the real map, terrain or sea would continue to the horizon.

**Best pair:**
- **Haze 0.8, Offset 0.25** (the current preset): hazy but readable, with a white-grey horizon. Closest to GTA V midday.
- Haze 1.2 starts greying the lower sky too much.

## S2: the four skies

**Sun elevations** (lat 34) from `GetSunDirection()`:

| Time | 17.4 h | 18.0 h | 18.3 h | 18.7 h | 19.2 h | 20.0 h | 22.5 h |
|---|---|---|---|---|---|---|---|
| Elevation | 8.8° | 0° | −4.4° | −10.3° | −17.7° | −29.4° | −65.3° |

### Day (14.2 h, yaw 142.9)
- A good GTA midday: painted cumulus, white-grey horizon, crisp shadows.
- In `s2_day_sunward_high.png`, the sky's bright glow sits **at the top of the frame, in the engine-sun direction** (the sun is ~55° up).
- There is **no second sun**: the painted sun is gone.

### Golden (17.4 h, yaw 138.9)
- **Excellent.** In `s2_golden_sunward_high.png` the **engine sun disc sits exactly inside the HDRI's warm glow**, with no second sun.
- Warm but not orange, with golden cloud edges.
- The street reads strongly GTA, with warm facades and long shadows.

### Blue hour (18.7 h, yaw 133.4) ❌ fails
- The sky renders **near-black with a purple/magenta cast**, not blue; see `s2_blue_sunward_high.png`.
- The street reads as full night, not dusk.
- At sun −10.3° the engine already dims the skybox heavily.

### Night (22.5 h, yaw −72.6) ❌ fails
- The sky is **pure black**: no city glow, no clouds, nothing. See `s2_night_sunward_high.png`, `s2_night_skyline.png`.
- **Diagnosis** (`diag_*`):
  - Removing the Atmosphere is still black.
  - **The same night sky at ClockTime 14.2 renders well** (`diag_nightsky_at_daytime.png`): moonlit clouds, a few stars and a warm city-glow band at the horizon.
- So **the engine blacks out the skybox texture when the sun is far below the horizon.** At a real night ClockTime, no night HDRI can be seen.
- **Recommendation for LightingService:** for "night" and "blue hour", keep the real ClockTime only for the sun/moon direction, but hold the sky visible. Options:
  - **(a)** Clamp `ClockTime` to about 18.0–18.3 (sun at or just below the horizon). Then use Brightness, ExposureCompensation, OutdoorAmbient and ColorCorrection to make it read as night.
  - **(b)** Accept that the night sky stays black, and lean on lit windows and fog colour.
- Option (a) is the only way the night HDRI shows. It needs its own lab round to check the shadow direction and the moon.

## S3: sky swap under the haze bump (16.75 h, Haze 1.05 + 0.2)

- `s3_swap_golden.png` vs `s3_swap_day.png`: **the swap is clearly visible**. The sky changes from thin, wispy high clouds over warm haze to big white cumulus. The bumped Haze (1.2) doesn't hide it.
- **The scene lighting also changes** even though the preset is identical: facade tones and shadow contrast shift. The sky feeds ambient and specular light.
- **Recommendation:** a hard swap will pop. Cross-fade between the two (two Sky objects can't blend, so fade through a short haze peak, about 1.5, for 1–2 s), or swap at a moment when the camera faces away.
- The golden sky's glow sits plausibly under the sun.

## S4: materials — **skipped**

`MaterialService` has 0 children and `HC_Asphalt` is missing, so the place has not been republished from a `v2/look` build.

## S5: volumetric clouds A/B

- `s5_clouds0.png` (cover 0) and `s5_clouds1.png` (cover 0.32) show **no visible volumetric clouds in either**.
- Volumetric `Clouds` may not render, or may only render faintly, in Edit-mode captures at this camera height. They need checking in Play.
- clouds0 came out warmer and more washed-out, probably light-probe lag after the previous sky change.
- **Verdict:** I can't judge from Edit mode. The painted HDRI cumulus already reads well alone, so **0 is the safe default**.

## S6: lit windows at night (17 of 49 windows lit)

- **Good:** the city is no longer dead. Warm and cool windows, a mix of brightness, glow on the street.
- **Too strong:**
  - Neon plus night Bloom (intensity 1.0, threshold 1.05) turns lit windows into **glowing slabs**. The office's lit ribbon windows read as huge light bars.
  - The lit far towers are **whole glowing columns**, because each tower is one glass part and it lights in full.
- **Distribution:** about 35% lit. The share is fine, but the tower facade and the ribbon windows are each one part, so lighting is all-or-nothing per facade.
- **Recommendations:**
  - Brightness factor about 0.25–0.4 (not 0.55–1.0), or use `SurfaceGui` / emissive `Decal` window textures instead of Neon.
  - Cap the bloom on windows.
  - Light individual window cells, not whole facade parts.
  - The warm/cool mix (70/30) reads correctly.

## Step 11: Lighting and MaterialService

- `Lighting.LightingStyle` = **Soft**. The project file wants `Realistic`, and the sync failed; see above.
- `Lighting.PrioritizeLightingQuality` = **true**.
- `Lighting.Technology`: **not readable** from `execute_luau` ("lacking capability RobloxScript"). The Lighting attributes show `RBX_OriginalTechnologyOnFileLoad = 3` and `RBX_LightingTechnologyUnifiedMigration = true`.
- `MaterialService`: **0 children**. `Use2022Materials` is **not readable** (RobloxScript capability).
- `inspect_instance` returns an empty property list for both services, so I read the values with `pcall` in `execute_luau`.

## Files

- 56 PNGs:
  - **Job shots:** `s0_*`, `s1_h*_o*_{elevated,skyline}` (18), `s2_<sky>_{street,elevated,skyline,sunward}`, `s3_swap_*`, `s5_clouds*`, `s6_*`.
  - **Extras:**
    - `*_noatm`: S0 shots repeated without the Atmosphere.
    - `s0_yaw0_streaming_race`: the first S0 shot, taken before the skies were pre-warmed.
    - `control_*`: the Offset 1.0 and Haze 3.0 controls from S1.
    - `extra_*_street`: street shots at Offset 0 vs 1.0.
    - `s2_*_sunward_high`: sunward camera at 250 studs, looking up 20 studs, so the sky is visible over the buildings.
    - `diag_*`: the night-sky diagnosis.
- `console.txt`: the session's complete Output (three lines). This Studio session has not written a log file, so it was read through LogService.
