# Job 0012: The new night, late-night, dusk and dawn skies and the clearer golden hour (vibe rows 12 and 13)

The lead publishes a place with the **v2 world** (as in job 0018, place v33 or later) plus branch `v2/look-night`, and names the version. It answers two rows of `docs/v2/VIBE_ROUTING.md`:
- **Row 12, the night sky reads dark reddish-brown.** At the held night clock (engine sun −3°) the engine renders any skybox about 20× darker and strongly red. The old navy-grey night faces came out at about (5, 1, 1): near-black with a red cast. The fix is four procedural skies pre-compensated for that cast. **Their raw faces look pale cyan; that is intended.** In game they should read as:
  - `night` (19:30–00:00): a deep blue-black zenith, a cool blue-grey horizon, subtle stars, and a faint warm city glow only just above the **east** (inland) horizon;
  - `nightLate` (00:00–05:00): the same, slightly deeper, with a fainter glow and a few more stars. It swaps in at midnight, in the same tick as the engine-clock jump;
  - `blue` (dusk, 18:21–19:30): an amber band low on the **west** (sun) side, then a warm grey, a pale blue, a clear mid blue and a deep blue overhead; a lighter blue horizon opposite;
  - `dawn` (05:00–05:39): the same on the **east** side, in a paler peach-gold.
- **Row 13, a grey haze wall at golden hour.** The golden presets now have thinner fog (Density 0.13, was 0.18), Haze 0.5 (was 0.8), Offset 0.4, a strong warm Glare, a light warm-cream Color and a light rose-grey Decay. The blue hour now runs at Exposure +1.0 (was +0.6), so its sky is never darker than the night's.
- **Expected look (simulated, sky only):** `docs/v2/evidence/look_night/job0012_sim.png`. Real frames from jobs 0011 and 0018 with the sky replaced: `in_context.png`.

Judge only the sky, the haze and how they sit with the city's light. Do not judge buildings, roads or the avatar.

## Steps

1. **Open the place.**
   - Close the current place without saving. Run **File → Open from Roblox → Hotwire City** and use the version the lead names. Write the version in the report.
   - **Do not connect Rojo**; live-sync confounded jobs 0007 and 0009. Run only **one** Play session.
   - Run **PROBE** in Edit. Expect `nightLate@0.00` first in the schedule and night Ft `rbxassetid://102872066736317`.
2. **Start Play (solo)** and wait **90 s**; the v2 world builds in chunks.
   - On the **Client**, run `settings().Rendering.QualityLevel = Enum.QualityLevel.Level21`. Everything below is at Level 21 unless it says Automatic.
3. **Shoot the six lock hours.** For each hour t below:
   - On the **Server**, run `workspace:SetAttribute("TimeOfDayLock", t)`.
   - Wait **5 s**: the sky swaps, and the exposure and grade settle within about 1 s.
   - On the **Client**, run **PROBE** and copy its line into the report.
   - Capture `downtown_street`, `overview_low_sw` and `sky_up` (CAMERA below). Name the files `<prefix>_<camera>.png`.

   | t | Prefix | Expected sky | Extra |
   |---|---|---|---|
   | `17.6` | `t1760` | `day` (golden light) | Also `t1760_overview_low_sw_auto` at **Automatic** (see 3a) |
   | `19.0` | `t1900` | `blue` (dusk) | Also `t1900_aerial_west`: the amber is on the west side |
   | `20.5` | `t2030` | `night` | |
   | `22.5` | `t2230` | `night` | Job 0018's `n02` / `n04` hour |
   | `2.0` | `t0200` | `nightLate` (engine sun now held in the east) | |
   | `5.5` | `t0530` | `dawn` | |

   **3a. Golden hour at both qualities.** At 17.6, after the three Level 21 shots:
   - On the Client, run `settings().Rendering.QualityLevel = Enum.QualityLevel.Automatic`, wait 10 s, and capture `t1760_overview_low_sw_auto`.
   - Then the old golden Atmosphere at Automatic, for an A/B against job 0018's `g13`: run **OLDGOLDEN** on the Server, wait 3 s, and capture `t1760_overview_low_sw_auto_old`.
   - Set the Client back to Level 21, wait 10 s, and capture `t1760_overview_low_sw_old` (the old golden Atmosphere at Level 21).
   - Run **CLEAR**, then set `TimeOfDayLock` to 17.6 again before moving on.
4. **The swaps.** Capture `overview_low_sw` only, at each lock:

   | Locks | Prefix | What it shows |
   |---|---|---|
   | 19.40, 19.60 | `swap_dusk_<hhmm>` | blue → night |
   | 23.95, 0.05 | `swap_midnight_<hhmm>` | night → nightLate, with the engine-clock jump |
   | 4.90, 5.10 | `swap_dawn_<hhmm>` | nightLate → dawn |

   Then watch two swaps live, and run **CLEAR** after each:
   - Lock 19.3, wait 5 s, set `TimeOfDayLock` to `nil`. The swap comes about 17 s later.
   - Lock 23.8, wait 5 s, set it to `nil`. The swap comes about 7 s later.
   - For each, write one or two lines: did you notice the swap? Was it a pop or a dim? Did the city's light change with it?
5. **A/B at dusk.** Lock 19.0, set `workspace:SetAttribute("SkyOverride", "night")`, and capture `ab_1900_night_overview_low_sw` and `ab_1900_night_aerial_west`. Compare with `t1900_*`: does the dusk sky read as blue hour, not night? Run **CLEAR**.
6. **Calibration: a higher dusk sun.** Lock 19.0 and, for each of `18.10` and `18.05`:
   - Run `workspace:SetAttribute("EngineClockOverride", x)`, wait 3 s, run PROBE, and capture `cal_<x>_aerial_west` and `cal_<x>_sky_up`.
   - Run **CLEAR** at the end. These measure how much brighter the engine draws the sky with its sun at −1.5° and −0.75° instead of −3°. They are data only; nothing in the place uses them yet.
7. **Console.** Run `get_console_output` and save it as `console.txt`.
   - Search it for every sky id below. Do any show `Failed to load` or `403`?
   - In job 0011 the night faces 403'd and the engine silently kept the cached day faces. If any face fails, the shots show the wrong sky, so **say so at the top of the report**.
   - Set the Client QualityLevel back to Automatic, then stop Play.
8. **Write `report.md`.**
   - **Night (20.5, 22.5, 2.0):** a clear GTA V-style night? Blue-black zenith (not black, not brown), cool horizon, stars visible but subtle, warm glow only near the east horizon. Is 2.0 a touch deeper than 22.5?
   - **Dusk and dawn (19.0, 5.5):** blue hour? Warm on the sun side, a visible warm-to-blue gradient, deep blue overhead.
   - **Any reddish-brown, maroon, purple, cyan or teal cast in the sky?** Name the region: zenith, sun side, opposite side.
   - **Golden hour (17.6):** at Level 21, is the long view clear and warm with gentle depth, or still a grey wall? Any sepia? A warm glow round the sun? At Automatic, how far does the city draw, and does the empty band read warm or grey? Compare new vs `_old` at each quality.
   - Any visible seams or edges between faces? Check `sky_up` and the face corners.
   - Anything worse than job 0018?
   - Then the swap verdict (step 4), the A/B verdict (step 5), and one line on the calibration shots (step 6).

Do not save or publish. Push to `studio-results` under `studio/results/0012/`, then write `DONE`.

The night, dusk and dawn shots are calibration data too. The lead adds them to `tools/look/sky_calibration.json` and re-runs `python3 -I tools/look/procedural_sky.py fit`, using the PROBE line's exposure, tint, yaw and clock. The zenith and the sun side have not been measured yet, so `sky_up`, `aerial_west` and the 19.0 / 5.5 shots matter most.

## Sky ids (Image assets)

| Sky | Ft | Bk | Lf | Rt | Up | Dn |
|---|---|---|---|---|---|---|
| night | 102872066736317 | 94984348100656 | 95939202131007 | 95896070267520 | 88812082275800 | shared |
| nightLate | 93141238500720 | 110094107388282 | 88251663305809 | 74764785598053 | 85952127286680 | shared |
| blue | 79742849062319 | 97757961136617 | 129863789995610 | 86621266446209 | 135650798270190 | shared |
| dawn | 129901905692620 | 98043044936404 | 123519574914603 | 73235550196971 | 78912621534818 | shared |

The shared Dn is `98952593275525` (unchanged). All the others were uploaded on 2026-10-28 as Image assets and read `Reviewing` at upload. The first build's night, blue and dawn ids (night Ft `139435704740562`) are superseded: if PROBE shows one of them, the place is stale.

## CAMERA (Client)

Job 0018's framings on the v2 world. If the place still has the v1 world, use job 0011's cameras instead and say so: `downtown_street` (60, 12, 160) → (60, 40, 0); `overview_low_sw` (−700, 180, −700) → (0, 20, 0).

```lua
-- set CAM to one of the names below
local CAMS = {
	downtown_street = { Vector3.new(-342, 20.6, -222), Vector3.new(-100, 40, -222) }, -- Crown Blvd, facing east
	overview_low_sw = { Vector3.new(-1400, 260, 1400), Vector3.new(-250, 30, -150) }, -- job 0018 t13 / g13
	sky_up = { Vector3.new(-330, 18, -222), Vector3.new(-330, 1018, -222) }, -- straight up; image top = north (-Z)
	aerial_west = { Vector3.new(-1400, 260, 1400), Vector3.new(-2400, 250, 1400) }, -- level, facing the sea (west)
}
local c = CAMS[CAM]
local cam = workspace.CurrentCamera
cam.CameraType = Enum.CameraType.Scriptable
cam.FieldOfView = 70
cam.CFrame = CFrame.lookAt(c[1], c[2], CAM == "sky_up" and Vector3.new(0, 0, -1) or Vector3.yAxis)
```

To give control back, set `workspace.CurrentCamera.CameraType = Enum.CameraType.Custom`.

## PROBE (Edit or Client)

```lua
local L = game:GetService("Lighting")
local Look = require(game:GetService("ReplicatedStorage").Shared.Config.Look)
local sky = L:FindFirstChildOfClass("Sky")
local cc = L:FindFirstChildOfClass("ColorCorrectionEffect")
local a = L:FindFirstChildOfClass("Atmosphere")
local sched = {}
for _, e in Look.SkySchedule do table.insert(sched, ("%s@%.2f"):format(e.sky, e.hour)) end
local q = "?"
pcall(function() q = tostring(settings().Rendering.QualityLevel) end)
return ("schedule [%s] | night Ft %s | TimeOfDay %s | Sky %s | Ft %s | ClockTime %.3f | Exposure %.3f | Tint %s | Saturation %s | Contrast %s | Yaw %.2f | Atmo D %.3f O %.2f H %.2f G %.2f C %s Dc %s | Moon %s | Quality %s"):format(
	table.concat(sched, " "), tostring(Look.Skies.night and Look.Skies.night.faces.Ft),
	tostring(workspace:GetAttribute("TimeOfDay")), tostring(L:GetAttribute("Sky")),
	tostring(sky and sky.SkyboxFt), L.ClockTime, L.ExposureCompensation,
	cc and tostring(cc.TintColor) or "?", cc and tostring(cc.Saturation) or "?", cc and tostring(cc.Contrast) or "?",
	sky and sky.SkyboxOrientation.Y or 0,
	a and a.Density or -1, a and a.Offset or -1, a and a.Haze or -1, a and a.Glare or -1,
	a and tostring(a.Color) or "?", a and tostring(a.Decay) or "?",
	tostring(sky and sky.MoonAngularSize), q)
```

## OLDGOLDEN (Server): job 0018's golden Atmosphere, for the A/B

```lua
workspace:SetAttribute("AtmosphereDensityOverride", 0.18)
workspace:SetAttribute("AtmosphereHazeOverride", 0.8)
workspace:SetAttribute("AtmosphereOffsetOverride", 0.25)
workspace:SetAttribute("AtmosphereGlareOverride", 0.45)
workspace:SetAttribute("AtmosphereColorOverride", Color3.fromRGB(218, 211, 200))
workspace:SetAttribute("AtmosphereDecayOverride", Color3.fromRGB(126, 126, 134))
```

## CLEAR (Server)

```lua
for _, n in { "TimeOfDayLock", "SkyOverride", "ExposureOverride", "TintOverride", "SaturationOverride",
	"MoonSizeOverride", "EngineClockOverride", "AtmosphereDensityOverride", "AtmosphereHazeOverride",
	"AtmosphereOffsetOverride", "AtmosphereGlareOverride", "AtmosphereColorOverride", "AtmosphereDecayOverride" } do
	workspace:SetAttribute(n, nil)
end
```
