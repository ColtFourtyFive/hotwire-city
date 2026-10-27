# Job 0007: Lighting lab round 2 — Haze vs Offset, the four HDRI skies, sky yaw sign (Edit mode, real engine)

**Status: draft** (branch `v2/look`). Round 1 was job 0002 (`docs/v2/research/lighting_lab.md`).

**Goal.**

1. Separate **Atmosphere.Haze** from **Atmosphere.Offset** (round 1 never varied Offset: every preset used 0.08–0.15), on a 3 × 3 grid, so LightingService v2 can lock `Look.Tuning.offset` and the per-preset Haze.
2. See the **four HDRI skies** (day, golden, blue, night: `src/shared/Config/Look.luau` → `Look.Skies`) on the lab street with their lighting presets.
3. Verify the **SkyboxOrientation sign** that LightingService uses to put each sky's sun glow on the engine sun (`Look.SkyStyle.yawSign`).
4. (Only if the place was republished from a `v2/look` build) look at the **PBR MaterialVariants** and the base-material overrides.

Everything runs in **Edit mode** with `execute_luau` (`datamodel_type` = Edit); no Play. At the end the place must be exactly as before: run CLEANUP. **Do not save the place.**

> **Materials need the published place.** `MaterialVariant.ColorMap/NormalMap/RoughnessMap/MetalnessMap` and `BaseMaterial` are PluginSecurity, and `MaterialService.<Material>Name` is NotScriptable, so `execute_luau` **cannot create or fill MaterialVariants or set the overrides**. They only exist once the lead builds `v2/look` (`rojo build`) and publishes it (Open Cloud place publish), and the operator reopens the place. Step S4 checks for them and is skipped if they are missing. Steps S0–S3 (Atmosphere, Sky, lighting) need nothing published: Sky faces, SkyboxOrientation, Atmosphere and post effects are scriptable.

## Steps

1. **Editor Quality Level** to the maximum (File → Studio Settings → Rendering). Write the value in the report.
2. Run **SETUP** (identical to job 0002, so shots are comparable with round 1).
3. **S0 – sky yaw sign.** Run **S0** (it swaps in the job-0005 test kit). Take two shots from camera `sky_ft`: (0, 6, 0) looking at (0, 30, −200), i.e. facing −Z and up a little:
   - `s0_yaw0.png` after `S0("0")`;
   - `s0_yaw90.png` after `S0("90")`.

   Report which test-kit face label is in front of the camera in each shot. Expected with `yawSign = +1` (CFrame.Angles convention): yaw 0 shows **Ft**, yaw 90 shows **Lf**. If yaw 90 shows **Rt**, the sign is −1. Either way, write the answer in the report.
4. **S1 – Haze × Offset grid** (day preset, Density fixed at 0.27, day HDRI sky, ClockTime 14.2 as in round 1). For each Haze in {0.4, 0.8, 1.2} and Offset in {0.0, 0.25, 0.5}, run `S1(haze, offset)` and take two shots: `elevated` and `skyline` (cameras below), named `s1_h<haze>_o<offset>_<cam>.png`, e.g. `s1_h0.8_o0.25_skyline.png` (18 shots).
5. **S2 – four skies.** For each of `day`, `golden`, `blue`, `night`, run **S2** with that name and take `street`, `elevated`, `skyline` and `sunward` (the script prints the sunward camera; it looks at the horizon under the engine sun) → `s2_<name>_<cam>.png` (16 shots). S2 also sets SkyboxOrientation from `Lighting:GetSunDirection()` exactly as LightingService does.
6. **S3 – haze bump at a sky swap.** Run **S3** with `"golden"`: the 15.8 h swap frame with Haze at the bumped value. Take `elevated` → `s3_swap_golden.png`; then run S3 with `"day"` and take `elevated` again → `s3_swap_day.png`. Report how visible the change is.
7. **S4 – materials (only if published).** Run **S4** with `"day"`. If it returns `"materials not in place"`, skip to CLEANUP and say so in the report. Otherwise take `street` and `elevated`, then run S4 with `"golden"` and take the same two shots → `s4_<preset>_<cam>.png`.
8. Run **CLEANUP**; check `Workspace.HCLightingLab` is gone and the Baseplate is visible.
9. Use `inspect_instance` on `Lighting` and report `LightingStyle`, `PrioritizeLightingQuality` and whether `Technology` is readable; and on `MaterialService`: number of children and `Use2022Materials`.

### Cameras

| Cam | Position | Look at |
|---|---|---|
| `street` | (12, 7, −130) | (12, 22, 60) |
| `elevated` | (−190, 150, −270) | (40, 30, 90) |
| `skyline` | (0, 320, −760) | (0, 70, 200) |
| `sky_ft` | (0, 6, 0) | (0, 30, −200) |
| `sunward` | printed by S2 | printed by S2 |

## What to report (`report.md`)

- S0: the face seen at yaw 0 and yaw 90 → **yawSign**.
- S1: for each Offset column, how far the far towers (450–950 studs) and the skyline stay readable, whether there is a hard horizon band, ghosting through near objects, and which Haze/Offset pair looks most like GTA V's midday (hazy but readable). Name the best pair.
- S2: per sky: does it read as GTA (whiter horizon by day; warm but not orange golden hour; blue hour not purple; night dark navy-grey with city glow)? Is the painted-out HDRI sun gone (no second sun)? In `sunward`, does the sky's glow sit around the engine sun?
- S3: how visible the golden → day swap is under the haze bump.
- S4: material realism at street and elevated heights, tiling or repetition, normal-map direction (bumps should look raised, not dented), and whether the recommended Part colours look right.

## SETUP

```lua
local Lighting = game:GetService("Lighting")
local saved = { props = {}, children = {}, cloud = nil, hidden = {} }
_G.HCLabSaved = saved
for _, p in { "ClockTime", "Brightness", "Ambient", "OutdoorAmbient", "ExposureCompensation", "EnvironmentDiffuseScale",
	"EnvironmentSpecularScale", "GlobalShadows", "ShadowSoftness", "GeographicLatitude", "ColorShift_Top", "ColorShift_Bottom" } do
	saved.props[p] = Lighting[p]
end
for _, c in Lighting:GetChildren() do
	if c:IsA("Atmosphere") or c:IsA("Sky") or c:IsA("PostEffect") then
		table.insert(saved.children, c)
		c.Parent = nil
	end
end
local terrain = workspace:FindFirstChildOfClass("Terrain")
local cl = terrain and terrain:FindFirstChildOfClass("Clouds")
if cl then saved.cloud = cl; cl.Parent = nil end
for _, n in { "Baseplate", "SpawnLocation" } do
	local p = workspace:FindFirstChild(n)
	if p and p:IsA("BasePart") then table.insert(saved.hidden, { p, p.Transparency, p.CanCollide }); p.Transparency = 1 end
end

local lab = Instance.new("Folder"); lab.Name = "HCLightingLab"; lab.Parent = workspace
local function part(name, size, cf, color, mat, extra)
	local p = Instance.new("Part")
	p.Name = name; p.Anchored = true; p.Size = size; p.CFrame = cf; p.Color = color; p.Material = mat
	p.TopSurface = Enum.SurfaceType.Smooth; p.BottomSurface = Enum.SurfaceType.Smooth
	if extra then for k, v in extra do p[k] = v end end
	p.Parent = lab
	return p
end
local C = Color3.fromRGB
part("Ground", Vector3.new(2400, 1, 2400), CFrame.new(0, -0.5, 0), C(92, 112, 64), Enum.Material.Grass)
part("Road", Vector3.new(52, 0.4, 1000), CFrame.new(0, 0.2, 0), C(52, 53, 56), Enum.Material.Asphalt)
for _, x in { -0.5, 0.5 } do part("CenterLine", Vector3.new(0.45, 0.42, 1000), CFrame.new(x, 0.21, 0), C(222, 180, 40), Enum.Material.SmoothPlastic) end
for _, x in { -12.8, 12.8 } do
	for z = -495, 495, 18 do part("LaneDash", Vector3.new(0.45, 0.42, 9), CFrame.new(x, 0.21, z), C(225, 225, 220), Enum.Material.SmoothPlastic) end
end
for _, x in { -25.2, 25.2 } do part("EdgeLine", Vector3.new(0.45, 0.42, 1000), CFrame.new(x, 0.21, 0), C(225, 225, 220), Enum.Material.SmoothPlastic) end
for _, s in { -1, 1 } do
	part("Curb", Vector3.new(1.2, 0.9, 1000), CFrame.new(s * 26.6, 0.45, 0), C(168, 166, 160), Enum.Material.Concrete)
	part("Sidewalk", Vector3.new(14, 0.8, 1000), CFrame.new(s * 34.2, 0.4, 0), C(160, 157, 150), Enum.Material.Pavement)
end
for z = -440, 440, 40 do
	for _, s in { -1, 1 } do
		local x = s * 28.6
		part("LampPole", Vector3.new(0.6, 20, 0.6), CFrame.new(x, 10.8, z), C(48, 50, 54), Enum.Material.Metal)
		part("LampArm", Vector3.new(6, 0.4, 0.4), CFrame.new(x - s * 3, 20.6, z), C(48, 50, 54), Enum.Material.Metal)
		local head = part("LampHead", Vector3.new(2.4, 0.6, 1.2), CFrame.new(x - s * 6, 20.3, z), C(235, 235, 230), Enum.Material.Glass)
		local L = Instance.new("SpotLight"); L.Face = Enum.NormalId.Bottom; L.Angle = 120; L.Range = 48; L.Brightness = 4
		L.Color = C(255, 208, 160); L.Shadows = true; L.Parent = head
		head:SetAttribute("Lamp", true)
	end
end
part("BrickBlock", Vector3.new(40, 60, 70), CFrame.new(61, 30.8, -5), C(138, 70, 56), Enum.Material.Brick)
for floor = 1, 4 do
	for z = -34, 24, 8 do
		local y = 0.8 + 12 * floor + 5
		part("Win", Vector3.new(0.3, 6.5, 4), CFrame.new(40.9, y, z), C(70, 88, 100), Enum.Material.Glass, { Reflectance = 0.25 })
		part("Sill", Vector3.new(0.9, 0.5, 4.8), CFrame.new(40.7, y - 3.6, z), C(200, 196, 186), Enum.Material.Concrete)
		part("Lintel", Vector3.new(0.6, 0.7, 4.8), CFrame.new(40.8, y + 3.6, z), C(200, 196, 186), Enum.Material.Concrete)
	end
end
part("Storefront", Vector3.new(0.3, 8.5, 56), CFrame.new(40.85, 5.4, -5), C(60, 75, 85), Enum.Material.Glass, { Reflectance = 0.3 })
part("Awning", Vector3.new(5, 0.6, 58), CFrame.new(38.5, 11.2, -5) * CFrame.Angles(0, 0, math.rad(-12)), C(30, 70, 52), Enum.Material.Fabric)
part("Cornice", Vector3.new(2.2, 2, 72), CFrame.new(40.4, 60, -5), C(205, 200, 188), Enum.Material.Concrete)
part("Tower", Vector3.new(60, 220, 60), CFrame.new(71, 110.8, 95), C(64, 90, 106), Enum.Material.Glass, { Reflectance = 0.35 })
for z = 66, 124, 6 do part("Mullion", Vector3.new(0.6, 220, 0.4), CFrame.new(40.8, 110.8, z), C(170, 175, 180), Enum.Material.Metal) end
for y = 12, 216, 12 do
	part("Spandrel", Vector3.new(0.7, 1.2, 60.4), CFrame.new(40.8, y, 95), C(40, 46, 52), Enum.Material.Metal)
	part("SpandrelS", Vector3.new(60.4, 1.2, 0.7), CFrame.new(71, y, 64.8), C(40, 46, 52), Enum.Material.Metal)
end
for x = 42, 100, 6 do part("MullionS", Vector3.new(0.4, 220, 0.6), CFrame.new(x, 110.8, 64.8), C(170, 175, 180), Enum.Material.Metal) end
part("Office", Vector3.new(60, 100, 80), CFrame.new(-71, 50.8, -20), C(176, 172, 164), Enum.Material.Concrete)
for floor = 1, 7 do
	part("Ribbon", Vector3.new(0.4, 6.5, 78), CFrame.new(-40.85, 0.8 + 12 * floor + 4, -20), C(66, 84, 98), Enum.Material.Glass, { Reflectance = 0.3 })
end
part("Shop", Vector3.new(40, 24, 50), CFrame.new(-61, 12.8, 65), C(232, 212, 180), Enum.Material.Plaster)
part("ShopGlass", Vector3.new(0.3, 9, 40), CFrame.new(-40.85, 5.5, 65), C(60, 75, 85), Enum.Material.Glass, { Reflectance = 0.3 })
part("ShopSign", Vector3.new(0.8, 4, 30), CFrame.new(-40.6, 15, 65), C(28, 30, 34), Enum.Material.SmoothPlastic)
local seed = 7
local function rnd(a, b) seed = (seed * 1103515245 + 12345) % 2147483648; return a + (b - a) * (seed / 2147483648) end
for i = 1, 26 do
	local h = rnd(50, 300)
	local mat = (i % 3 == 0) and Enum.Material.Glass or Enum.Material.Concrete
	local col = (i % 3 == 0) and C(70, 92, 110) or C(rnd(150, 200), rnd(145, 190), rnd(135, 180))
	part("Far", Vector3.new(rnd(40, 80), h, rnd(40, 80)), CFrame.new(rnd(-500, 500), h / 2, rnd(450, 950)), col, mat, mat == Enum.Material.Glass and { Reflectance = 0.3 } or nil)
end

-- round-2 helpers shared by S0..S4 (kept in _G for the following execute_luau calls)
local LAB = {}
_G.HCLab2 = LAB
LAB.SKIES = { -- Config/Look.luau -> Look.Skies (Image asset ids; glow azimuth in degrees, 0 = -Z, 90 = +X)
	day = { glow = 34.1, stars = 0, Bk = 114889706466400, Dn = 126778055421344, Ft = 83431819292615, Lf = 85390262765714, Rt = 79010093641079, Up = 80903012956799 },
	golden = { glow = 38.3, stars = 0, Bk = 114964142574668, Dn = 108812301015843, Ft = 107623397205280, Lf = 114739838025939, Rt = 117183852251891, Up = 115058423870433 },
	blue = { glow = 32.7, stars = 500, Bk = 88562914711616, Dn = 117299015005250, Ft = 122246640713360, Lf = 79579945003167, Rt = 96569696092312, Up = 128421368724949 },
	night = { glow = 35.5, stars = 400, Bk = 90717854341912, Dn = 71763556424955, Ft = 98461351795375, Lf = 79552634608475, Rt = 79230279114248, Up = 80685099604519 },
	testkit = { glow = 0, stars = 0, Ft = 125021145685093, Rt = 79998295024603, Bk = 133950846661312, Lf = 128567569050109, Up = 98950637562746, Dn = 83560359428904 },
}
LAB.PRESETS = { -- Config/Look.luau -> Look.Presets (clock = the hour shot here)
	day = { clock = 14.2, bright = 3.0, exp = 0, amb = C(14, 14, 16), out = C(120, 124, 132), soft = 0.12, atm = { 0.27, 0.25, 0.9, 0.25, C(200, 199, 194), C(128, 130, 134) }, bloom = { 0.45, 24, 1.75 }, cc = { 0, 0.1, 0.02, C(255, 252, 246) }, rays = { 0.04, 0.6 }, cloud = { 0.32, 0.42, C(246, 246, 244) }, night = false },
	golden = { clock = 17.4, bright = 3.1, exp = 0.05, amb = C(18, 14, 12), out = C(130, 112, 100), soft = 0.18, atm = { 0.27, 0.3, 1.05, 0.55, C(234, 212, 184), C(128, 124, 140) }, bloom = { 0.6, 28, 1.5 }, cc = { 0, 0.12, 0.07, C(255, 244, 230) }, rays = { 0.11, 0.65 }, cloud = { 0.34, 0.45, C(255, 226, 200) }, night = false },
	blue = { clock = 18.7, bright = 1.3, exp = 0.28, amb = C(12, 12, 17), out = C(88, 88, 104), soft = 0.25, atm = { 0.25, 0.2, 0.8, 0.1, C(132, 130, 142), C(74, 74, 90) }, bloom = { 0.9, 30, 1.2 }, cc = { 0, 0.13, -0.02, C(244, 244, 255) }, rays = { 0.02, 0.6 }, cloud = { 0.32, 0.42, C(128, 126, 140) }, night = true },
	night = { clock = 22.5, bright = 1.0, exp = 0.3, amb = C(8, 9, 12), out = C(50, 56, 70), soft = 0.3, atm = { 0.22, 0.15, 0.5, 0, C(46, 52, 64), C(22, 24, 32) }, bloom = { 1.0, 30, 1.05 }, cc = { 0, 0.15, -0.05, C(236, 240, 255) }, rays = { 0, 0.5 }, cloud = { 0.3, 0.4, C(52, 56, 68) }, night = true },
}
function LAB.clear()
	for _, c in Lighting:GetChildren() do if c.Name:sub(1, 6) == "HCLab_" then c:Destroy() end end
	for _, c in terrain:GetChildren() do if c.Name == "HCLab_Clouds" then c:Destroy() end end
end
function LAB.sky(name, yaw)
	local s = LAB.SKIES[name]
	local sky = Lighting:FindFirstChild("HCLab_Sky") or Instance.new("Sky")
	sky.Name = "HCLab_Sky"
	for _, f in { "Bk", "Dn", "Ft", "Lf", "Rt", "Up" } do sky["Skybox" .. f] = "rbxassetid://" .. s[f] end
	sky.StarCount = s.stars; sky.SunAngularSize = 10; sky.MoonAngularSize = 6
	sky.SkyboxOrientation = Vector3.new(0, yaw or 0, 0)
	sky.Parent = Lighting
	return sky
end
function LAB.yawFor(name, sign) -- LightingService.skyYaw: sign * (glow azimuth - engine sun azimuth)
	local d = Lighting:GetSunDirection()
	local az = math.deg(math.atan2(d.X, -d.Z))
	local y = (sign or 1) * (LAB.SKIES[name].glow - az)
	return (y + 180) % 360 - 180, d
end
function LAB.apply(p, atmOverride)
	LAB.clear()
	Lighting.ClockTime = p.clock; Lighting.Brightness = p.bright; Lighting.ExposureCompensation = p.exp
	Lighting.Ambient = p.amb; Lighting.OutdoorAmbient = p.out; Lighting.ShadowSoftness = p.soft
	Lighting.GeographicLatitude = 34; Lighting.GlobalShadows = true
	Lighting.EnvironmentDiffuseScale = 1; Lighting.EnvironmentSpecularScale = 1
	local atm = atmOverride or p.atm
	local a = Instance.new("Atmosphere"); a.Name = "HCLab_Atmosphere"
	a.Density, a.Offset, a.Haze, a.Glare, a.Color, a.Decay = atm[1], atm[2], atm[3], atm[4], atm[5], atm[6]; a.Parent = Lighting
	local b = Instance.new("BloomEffect"); b.Name = "HCLab_Bloom"; b.Intensity, b.Size, b.Threshold = p.bloom[1], p.bloom[2], p.bloom[3]; b.Parent = Lighting
	local cc = Instance.new("ColorCorrectionEffect"); cc.Name = "HCLab_CC"; cc.Brightness, cc.Contrast, cc.Saturation, cc.TintColor = p.cc[1], p.cc[2], p.cc[3], p.cc[4]; cc.Parent = Lighting
	local r = Instance.new("SunRaysEffect"); r.Name = "HCLab_Rays"; r.Intensity, r.Spread = p.rays[1], p.rays[2]; r.Parent = Lighting
	local cl = Instance.new("Clouds"); cl.Name = "HCLab_Clouds"; cl.Cover, cl.Density, cl.Color = p.cloud[1], p.cloud[2], p.cloud[3]; cl.Parent = terrain
	for _, d in lab:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute("Lamp") then
			d.Material = p.night and Enum.Material.Neon or Enum.Material.Glass
			d.Color = p.night and C(255, 214, 170) or C(235, 235, 230)
			d:FindFirstChildOfClass("SpotLight").Enabled = p.night
		end
	end
end
return "lab built: " .. #lab:GetChildren() .. " parts"
```

## S0 (sky yaw sign)

Replace `YAW` with `0`, then with `90`.

```lua
local LAB = _G.HCLab2
LAB.apply(LAB.PRESETS.day)
LAB.sky("testkit", YAW)
return "test kit sky at yaw " .. YAW .. " (expect Ft at 0, Lf at 90 when yawSign = +1)"
```

## S1 (Haze x Offset grid)

Replace `HAZE` and `OFFSET` (Haze 0.4 / 0.8 / 1.2; Offset 0.0 / 0.25 / 0.5).

```lua
local LAB = _G.HCLab2
local p = LAB.PRESETS.day
local atm = { 0.27, OFFSET, HAZE, 0.25, p.atm[5], p.atm[6] }
LAB.apply(p, atm)
LAB.sky("day", (LAB.yawFor("day")))
return ("day sky, Density 0.27, Haze %.2f, Offset %.2f"):format(HAZE, OFFSET)
```

## S2 (four skies)

Replace `SKY_NAME` with `"day"`, `"golden"`, `"blue"`, `"night"`. If S0 showed `yawSign = -1`, change the `1` in `yawFor(NAME, 1)` to `-1`.

```lua
local LAB = _G.HCLab2
local NAME = SKY_NAME
LAB.apply(LAB.PRESETS[NAME])
local yaw, sun = LAB.yawFor(NAME, 1)
LAB.sky(NAME, yaw)
local flat = Vector3.new(sun.X, 0, sun.Z)
flat = flat.Magnitude > 0.01 and flat.Unit or Vector3.new(0, 0, -1)
local pos = Vector3.new(0, 7, 0)
local at = pos + flat * 300 + Vector3.new(0, 25, 0)
return ("%s at %.1f h: SkyboxOrientation.Y = %.1f, sun dir (%.2f, %.2f, %.2f); sunward cam (0, 7, 0) -> (%.0f, %.0f, %.0f)")
	:format(NAME, LAB.PRESETS[NAME].clock, yaw, sun.X, sun.Y, sun.Z, at.X, at.Y, at.Z)
```

## S3 (sky swap under the haze bump)

Replace `WHICH` with `"golden"`, then with `"day"`.

```lua
local LAB = _G.HCLab2
local p = table.clone(LAB.PRESETS.day)
p.clock = 15.8
local atm = table.clone(p.atm)
atm[3] = math.min(1.2, atm[3] + 0.2) -- Look.SkySwap.hazeBoost at the swap, capped by Look.Caps.hazeMax
LAB.apply(p, atm)
LAB.sky(WHICH, (LAB.yawFor(WHICH)))
return "swap frame with " .. WHICH .. " sky, Haze " .. atm[3]
```

## S4 (materials; needs the place published from a v2/look build)

Replace `PRESET` with `"day"`, then `"golden"`. It applies the recommended Part colours (`Look.Materials[*].color`) to the lab parts whose materials are globally overridden, and turns the glass into `HC_WindowGlass`.

```lua
local MaterialService = game:GetService("MaterialService")
if not MaterialService:FindFirstChild("HC_Asphalt") then
	return "materials not in place (MaterialVariants need the published v2/look build; execute_luau cannot create them)"
end
local LAB = _G.HCLab2
LAB.apply(LAB.PRESETS[PRESET])
LAB.sky(PRESET, (LAB.yawFor(PRESET)))
local C = Color3.fromRGB
local colour = { -- Look.Materials[*].color for the overridden base materials
	Asphalt = C(103, 103, 106), Pavement = C(200, 197, 188), Concrete = C(186, 183, 176), Brick = C(177, 141, 124),
	Plaster = C(232, 214, 196), Grass = C(146, 161, 109),
}
local lab = workspace.HCLightingLab
for _, d in lab:GetDescendants() do
	if d:IsA("BasePart") then
		local c = colour[d.Material.Name]
		if c and d.Name ~= "CenterLine" then d.Color = c end
		if d.Material == Enum.Material.Glass and not d:GetAttribute("Lamp") then
			d.Material = Enum.Material.SmoothPlastic
			d.MaterialVariant = "HC_WindowGlass"
			d.Color = C(45, 55, 63)
			d.Reflectance = 0
		end
	end
end
local overrides = {}
for _, m in { Enum.Material.Asphalt, Enum.Material.Pavement, Enum.Material.Concrete, Enum.Material.Brick, Enum.Material.Plaster, Enum.Material.Grass } do
	table.insert(overrides, m.Name .. "=" .. tostring(MaterialService:GetBaseMaterialOverride(m)))
end
return "materials applied; overrides: " .. table.concat(overrides, ", ")
```

(The stucco shop uses a beige tint, (232, 214, 196), instead of the near-white default, to show that HC_Stucco takes its colour from Part.Color.)

## CLEANUP

```lua
local Lighting = game:GetService("Lighting")
local saved = _G.HCLabSaved
local lab = workspace:FindFirstChild("HCLightingLab"); if lab then lab:Destroy() end
for _, c in Lighting:GetChildren() do if c.Name:sub(1, 6) == "HCLab_" then c:Destroy() end end
local terrain = workspace:FindFirstChildOfClass("Terrain")
for _, c in terrain:GetChildren() do if c.Name == "HCLab_Clouds" then c:Destroy() end end
if saved then
	for k, v in saved.props do Lighting[k] = v end
	for _, c in saved.children do c.Parent = Lighting end
	if saved.cloud then saved.cloud.Parent = terrain end
	for _, h in saved.hidden do h[1].Transparency = h[2]; h[1].CanCollide = h[3] end
end
_G.HCLabSaved = nil
_G.HCLab2 = nil
return "cleaned"
```
