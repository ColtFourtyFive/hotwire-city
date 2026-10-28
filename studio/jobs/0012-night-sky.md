# Job 0012: The new night, dusk and dawn skies on the real place (backlog 14)

The lead uploads branch `v2/look-night` as a Saved version. It answers job 0011's "the night sky is still
reddish-brown" and "blue hour reads as night":
- **Diagnosis.** At the held night clock (engine sun −3°) the engine renders any skybox about 20× darker and strongly
  red (R/G 2.8). That turned the navy-grey night HDRI maroon, and the blue grade could not pull it back. Fitted on
  0009's and 0011's night shots (`docs/v2/research/lighting_lab.md`, round 5).
- **New skies.** Three procedural skies, pre-compensated for that cast. **Their raw faces look pale cyan; that is
  intended.** In game they should read as:
  - `night`: a deep blue-black zenith, a cool blue-grey horizon, subtle stars, and a faint warm city glow only just
    above the east (inland) horizon;
  - `blue` (dusk): warm amber on the west (sun) side horizon, a teal band above it, and deep blue overhead;
  - `dawn`: the same on the east side, in a paler peach-gold.
- **Schedule** (game hours): `dawn` 05:00, `day` 05:39, `blue` 18:21, `night` 19:30. Each swap sits under a short
  exposure dip (0.35 EV for the twilight ↔ night swaps). There is no sky swap at the midnight engine-clock jump.
- **Simulated expectation:** `docs/v2/evidence/look_night/job0012_sim.png`. It shows the same five hours and three
  cameras, sky only.

The world is still v1, so judge only the sky, and how the sky sits with the city's light.

## Steps

1. **Open the place.**
   - Close the current place without saving. Run **File → Open from Roblox → Hotwire City** and use the version the
     lead names. Write the version number in the report.
   - **Do not connect Rojo**, because live-sync confounded jobs 0007 and 0009.
   - Run only **one** Play session.
   - Run **PROBE** below in Edit. Expect `dawn` in the schedule and night Ft `rbxassetid://139435704740562`.
2. **Start Play (solo)** and wait 45 s.
   - On the Client, run `settings().Rendering.QualityLevel = Enum.QualityLevel.Level21`, as in job 0011. At Automatic
     the overviews are draw-distance grey.
3. **Shoot the five lock hours.** For each hour t below:
   - On the **Server**, run `workspace:SetAttribute("TimeOfDayLock", t)`.
   - Wait **5 s**: the sky swaps, and the exposure and grade settle within about 1 s.
   - On the **Client**, run **PROBE** and copy its line into the report.
   - Capture the three cameras from the Client (CAMERA below). Name the files `<prefix>_<camera>.png`.

   | t | Prefix | Expected sky |
   |---|---|---|
   | `19.0` | `t1900` | `blue` (dusk) |
   | `20.5` | `t2030` | `night` |
   | `22.5` | `t2230` | `night` |
   | `2.0` | `t0200` | `night` (engine sun now held in the east) |
   | `5.5` | `t0530` | `dawn` |

   Cameras: `downtown_street`, `overview_low_sw`, and `sky_up` (straight up from the downtown street).
4. **The swaps.** Capture `overview_low_sw` only, at each lock below:

   | Locks | Prefix | What it shows |
   |---|---|---|
   | 19.40, 19.49, 19.51, 19.60 | `swap_dusk_<hhmm>` | blue → night |
   | 4.90, 4.99, 5.01, 5.10 | `swap_dawn_<hhmm>` | night → dawn |

   Then watch one swap live:
   - Set `TimeOfDayLock` to 19.3, wait 5 s, then set it to `nil`. The clock runs on from 19.3 and swaps at 19.5,
     about 17 s later.
   - Describe it in one or two lines: did you notice the swap? Was it a pop or a dim? Did the city's light change with it?
   - Run **CLEAR** afterwards.
5. **A/B at dusk.** Lock 19.0 and set `workspace:SetAttribute("SkyOverride", "night")`.
   - Capture `ab_1900_night_overview_low_sw` and `ab_1900_night_downtown_street`.
   - This is the night sky at the dusk grade. Compare it with `t1900_*`: does the dusk sky read as blue hour, and not
     as the night?
   - Run **CLEAR**.
6. **Console.** Run `get_console_output` and save it as `console.txt`.
   - Search it for the new sky ids (table below). Do any show `Failed to load` or `403`?
   - In job 0011 the night faces 403'd, and the engine silently kept the cached day faces. If that happens again, the
     shots show the wrong sky, so say so prominently.
   - Set the client QualityLevel back to Automatic, then stop Play.
7. **Write `report.md`.** For each lock hour:
   - Does the night read as a clear GTA V-style night: a blue-black zenith (not black, not brown), a cool horizon,
     stars visible but subtle, and the warm glow only near the east horizon?
   - Does dusk or dawn read as blue hour: warm at the horizon on the sun side, deep blue overhead, with a visible
     gradient?
   - **Any reddish-brown, maroon, purple, cyan or teal cast in the sky?** Name the region: zenith, the sun side, or
     the opposite side.
   - Are there visible seams or edges between faces? Look at `sky_up` and the face corners.
   - Is anything still worse than job 0011?
   - Then give the swap verdict (step 4) and the A/B verdict (step 5).

Do not save or publish.

The shots are calibration data too. The lead adds them to `tools/look/sky_calibration.json` and re-runs
`python3 -I tools/look/procedural_sky.py fit`, using the PROBE line's exposure, tint and yaw. The zenith and the
sun side have not been measured yet, so `sky_up` and the 19.0 / 5.5 shots matter most.

## Sky ids (Image assets)

| Sky | Ft | Bk | Lf | Rt | Up | Dn |
|---|---|---|---|---|---|---|
| night | 139435704740562 | 86999547269242 | 125463269368696 | 99753931935148 | 109124646573605 | shared |
| blue | 105412262655867 | 70683400363590 | 140732642740499 | 117518356221659 | 101185202023069 | shared |
| dawn | 104691054390275 | 88297669138388 | 115868303766379 | 137318548242974 | 115259817645274 | shared |

The shared Dn is `98952593275525`. All were uploaded on 2026-10-27 as Image assets and read `Reviewing` at upload.

## CAMERA (Client)

```lua
-- set CAM to one of the names below
local CAMS = {
	downtown_street = { Vector3.new(60, 12, 160), Vector3.new(60, 40, 0) },
	overview_low_sw = { Vector3.new(-700, 180, -700), Vector3.new(0, 20, 0) },
	sky_up = { Vector3.new(60, 12, 160), Vector3.new(60, 1000, 160) }, -- image top = north (-Z)
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
local sched = {}
for _, e in Look.SkySchedule do table.insert(sched, ("%s@%.2f"):format(e.sky, e.hour)) end
return ("schedule [%s] | night Ft %s | TimeOfDay %s | Sky %s | Ft %s | ClockTime %.3f | Exposure %.3f | Tint %s | Saturation %s | Contrast %s | Yaw %.2f | Haze %s | Moon %s"):format(
	table.concat(sched, " "), tostring(Look.Skies.night and Look.Skies.night.faces.Ft),
	tostring(workspace:GetAttribute("TimeOfDay")), tostring(L:GetAttribute("Sky")),
	tostring(sky and sky.SkyboxFt), L.ClockTime, L.ExposureCompensation,
	cc and tostring(cc.TintColor) or "?", cc and tostring(cc.Saturation) or "?", cc and tostring(cc.Contrast) or "?",
	sky and sky.SkyboxOrientation.Y or 0,
	tostring(L:FindFirstChildOfClass("Atmosphere") and L:FindFirstChildOfClass("Atmosphere").Haze),
	tostring(sky and sky.MoonAngularSize))
```

## CLEAR (Server)

```lua
for _, n in { "TimeOfDayLock", "SkyOverride", "ExposureOverride", "TintOverride", "SaturationOverride",
	"MoonSizeOverride", "EngineClockOverride" } do
	workspace:SetAttribute(n, nil)
end
```
