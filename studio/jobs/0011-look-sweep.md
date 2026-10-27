# Job 0011: Look sweep on the real place (version 31): fog density, night exposure, golden grade, overrides

The lead uploaded branch `v2/look-fix3` as Saved **version 31**. It answers job 0009:
- **Base-material overrides** are applied at runtime too: `MaterialService:SetBaseMaterialOverride` on the server
  (`LightingService.init`) and on every client (`LookClient.init`), via `Util/MaterialOverrides`.
- **`Technology = Future`** is back in the place file. A headless server of v31 now reads `LightingStyle = Realistic`
  and `PrioritizeLightingQuality = true`; v30 read Soft and false.
- **Fog density** is lower: day 0.16 (was 0.27), golden 0.18, night 0.12.
- **Night** is lifted about two stops: Exposure +0.8, Brightness 1.2, a brighter OutdoorAmbient, and a blue night grade
  (212, 226, 255) to cancel the reddish-brown sky.
- **Golden hour** uses a warm-but-neutral grade, and the engine moon is small (1.5°) and hidden while the sun is up.

This job checks all of that in Studio and sweeps the new values with live override attributes. The world is still v1,
so judge only fog, sky, exposure, grade and the moon.

## Steps

1. **Open the place.**
   - Close the current place without saving. Run **File → Open from Roblox → Hotwire City** and check it is version 31
     or later (Version History). The place already contains the code.
   - **Do not connect Rojo.** Live-sync confounded jobs 0007 and 0009 (duplicate Lighting children, MaterialService).
   - Run only **one** Play session. In 0009 a second Studio instance in Play took the DataService session lock and
     kicked the first one.
2. **Inspect in Edit** with `execute_luau` (`datamodel_type` = Edit). Run **PROBE** below and write its line in the report.
   It reads LightingStyle, PrioritizeLightingQuality and every base-material override as loaded from the file.
   - Expect `LightingStyle = Realistic` and `PrioritizeLightingQuality = true`.
   - Job 0009 read the stock override names here. A headless server of v30 and v31 reads 16/16 active. Report what
     Studio reads now.
3. **Start Play (solo)** and wait 45 s. Then:
   - Run **PROBE** on the **Server** and on the **Client**. Expect `16/16 active` and `HCOverridesActive = 16` on both.
   - Find the console lines `[MaterialOverrides] server: …` and `[MaterialOverrides] client: …` and copy them into the
     report.
4. **PBR check.** v1 uses none of the overridden materials, so run **PBRCHECK** on the Server. It adds four test slabs
   near the spawn: Asphalt, Brick, Concrete and Pavement. Capture `pbr_check` from the camera the script prints.
   - Do they show the HC_ PBR maps (asphalt aggregate, brick bond, sidewalk joints), or plain stock materials?
   - Run `PBRCHECK_CLEAN` afterwards.
5. **Run the sweeps.**
   - Set each lock and override with `execute_luau` on the **Server**, and run **CLEAR** between groups.
   - After each setting, wait 3 s, then capture the listed cameras from the **Client** (CAMERA below).
   - Name the files `<group>_<variant>_<camera>.png`.

   **A. Noon fog density.** Lock: `workspace:SetAttribute("TimeOfDayLock", 13)`.

   | Variant | Override |
   |---|---|
   | `d012` | `workspace:SetAttribute("AtmosphereDensityOverride", 0.12)` |
   | `d016` | `workspace:SetAttribute("AtmosphereDensityOverride", 0.16)` (the new day default) |
   | `d020` | `workspace:SetAttribute("AtmosphereDensityOverride", 0.2)` |
   | `d027` | `workspace:SetAttribute("AtmosphereDensityOverride", 0.27)` (the old value: the 0009 grey wall) |

   Cameras: `overview_high` and `overview_low_sw`.

   **B. Night exposure and tint.** Lock: `workspace:SetAttribute("TimeOfDayLock", 22.5)`.

   | Variant | Override |
   |---|---|
   | `n_default` | none (Exposure +0.8, Brightness 1.2, tint (212, 226, 255)) |
   | `n_exp04` | `workspace:SetAttribute("ExposureOverride", 0.4)` |
   | `n_exp12` | `workspace:SetAttribute("ExposureOverride", 1.2)` |
   | `n_tintold` | `workspace:SetAttribute("TintOverride", Color3.fromRGB(228, 236, 255))` (0009's milder tint) |
   | `n_tintblue` | `workspace:SetAttribute("TintOverride", Color3.fromRGB(196, 216, 255))` (stronger blue) |

   Remove the previous override before the next variant: set it to `nil`, or run CLEAR and set the lock again.
   Cameras: `overview_low_sw` and `downtown_street`.

   **C. Golden hour.** Lock: `workspace:SetAttribute("TimeOfDayLock", 17.6)`.

   | Variant | Override |
   |---|---|
   | `g_default` | none (new warm-but-neutral grade, moon hidden) |
   | `g_sepia` | `TintOverride = Color3.fromRGB(255, 244, 230)` and `SaturationOverride = 0.07` (0009's grade, for A/B) |
   | `g_moon6` | `workspace:SetAttribute("MoonSizeOverride", 6)` (0009's moon size, to see the moon is really hidden in `g_default`) |
   | `g_d012` | `workspace:SetAttribute("AtmosphereDensityOverride", 0.12)` |

   Cameras: `overview_low_sw` and `downtown_street`.

   **D. Blue hour.** Lock: `workspace:SetAttribute("TimeOfDayLock", 18.8)`. One variant, `b_default`.
   Cameras: `overview_low_sw` and `downtown_street`. Is it between golden and night, never darker than `n_default`? Is
   the small moon visible on the east horizon?
6. Run **CLEAR**. Run `get_console_output` and save it as `console.txt`. Stop Play.
7. Write **`report.md`**:
   - The PROBE lines for Edit, Server and Client.
   - The PBR verdict.
   - **A:** pick one density: the one that keeps downtown readable from both overview cameras with gentle aerial
     perspective, not a flat grey band. v1 downtown is at the map centre, about 1,000 studs from `overview_low_sw` and
     about 1,300 from `overview_high`. The far side of the map, 1,500–2,500 studs out, stands in for the v2 skyline:
     is it still readable?
   - **B:** pick one exposure and one tint. Streets and silhouettes should be readable and the sky visible, but it must
     still read clearly as night. Is the sky still reddish-brown?
   - **C:** does `g_default` read warm-but-neutral rather than sepia? Is the moon gone? Pick one density for golden.
   - **D:** the blue-hour verdict.
   - Any errors in the console.

Do not save or publish.

## CAMERA (Client)

```lua
-- set CAM to one of the names below
local CAMS = {
	overview_high = { Vector3.new(0, 900, 900), Vector3.new(0, 0, 0) },
	overview_low_sw = { Vector3.new(-700, 180, -700), Vector3.new(0, 20, 0) },
}
local c = CAMS[CAM]
local cam = workspace.CurrentCamera
cam.CameraType = Enum.CameraType.Scriptable
cam.FieldOfView = 70
cam.CFrame = CFrame.lookAt(c[1], c[2])
```

`downtown_street` is the job 0001 / 0009 camera; use the same position as before. To give control back, set
`workspace.CurrentCamera.CameraType = Enum.CameraType.Custom`.

## PROBE (Edit, Server or Client)

```lua
local MS = game:GetService("MaterialService")
local L = game:GetService("Lighting")
local Look = require(game:GetService("ReplicatedStorage").Shared.Config.Look)
local ok, n, off = 0, 0, {}
for base, want in Look.Overrides do
	n += 1
	local got = MS:GetBaseMaterialOverride(Enum.Material[base])
	if got == want then ok += 1 else table.insert(off, base .. "=" .. got) end
end
local variants = 0
for _, c in MS:GetChildren() do if c:IsA("MaterialVariant") then variants += 1 end end
return ("overrides %d/%d active (HCOverridesActive=%s) not active: [%s] | variants %d | LightingStyle %s | PrioritizeLightingQuality %s | Density %s | Exposure %s | Moon %s"):format(
	ok, n, tostring(MS:GetAttribute("HCOverridesActive")), table.concat(off, ", "), variants,
	tostring(L.LightingStyle), tostring(L.PrioritizeLightingQuality),
	tostring(L:FindFirstChildOfClass("Atmosphere") and L:FindFirstChildOfClass("Atmosphere").Density),
	tostring(L.ExposureCompensation), tostring(L:FindFirstChildOfClass("Sky") and L:FindFirstChildOfClass("Sky").MoonAngularSize))
```

## PBRCHECK / PBRCHECK_CLEAN (Server)

```lua
-- PBRCHECK: four 24 x 1 x 24 slabs in a row, 30 studs above the spawn, so nothing of v1 covers them
local spawn = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
local base = (spawn and spawn.Position or Vector3.zero) + Vector3.new(0, 30, 0)
local folder = Instance.new("Folder")
folder.Name = "HCPbrCheck"
folder.Parent = workspace
for i, m in { "Asphalt", "Brick", "Concrete", "Pavement" } do
	local p = Instance.new("Part")
	p.Anchored = true
	p.Size = Vector3.new(24, 1, 24)
	p.Position = base + Vector3.new((i - 2.5) * 26, 0, 0)
	p.Material = Enum.Material[m]
	local def = require(game:GetService("ReplicatedStorage").Shared.Config.Look).Materials[game:GetService("MaterialService"):GetBaseMaterialOverride(Enum.Material[m])]
	p.Color = def and Color3.fromRGB(def.color[1], def.color[2], def.color[3]) or Color3.fromRGB(160, 160, 160)
	p.Name = m
	p.Parent = folder
end
return ("camera: position %s look at %s"):format(tostring(base + Vector3.new(0, 14, 22)), tostring(base))
```

```lua
-- PBRCHECK_CLEAN
local f = workspace:FindFirstChild("HCPbrCheck")
if f then f:Destroy() end
```

## CLEAR (Server)

```lua
for _, n in { "TimeOfDayLock", "AtmosphereDensityOverride", "AtmosphereHazeOverride", "ExposureOverride",
	"BrightnessOverride", "OutdoorAmbientOverride", "TintOverride", "SaturationOverride", "MoonSizeOverride" } do
	workspace:SetAttribute(n, nil)
end
```

All overrides are listed in `tools/look/README.md` ("Live overrides") and in `LightingService.OVERRIDE_ATTRIBUTES`.
Each one replaces a single look value within about 1 s.
