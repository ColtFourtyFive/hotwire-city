# Job 0002: Lighting & materials lab (Edit mode, real engine)

**Goal:** calibrate a GTA-V-like look (lighting, atmosphere, materials, scale) in the real engine before the v2 world is built. Everything runs in **Edit mode**, with no Play.

At the end, the place must be exactly as it was before. The cleanup script restores it. **Do not save the place.**

## Steps

1. If Studio lets you, set **File → Studio Settings → Rendering → Editor Quality Level** to the maximum. Write the value you used in the report.
2. Run **SETUP** (below) with `execute_luau` (`datamodel_type` = Edit).
3. For each preset — `day_clear`, `golden_hour`, `night`, `overcast` — in that order:
   1. Run **PRESET**, replacing `PRESET_NAME` with the preset name.
   2. Take three `screen_capture` shots, named `<preset>_<cam>.png`:

      | Cam | Camera position | Look at |
      |---|---|---|
      | `street` | (12, 7, -130) | (12, 22, 60) |
      | `elevated` | (-190, 150, -270) | (40, 30, 90) |
      | `skyline` | (0, 320, -760) | (0, 70, 200) |

4. Run **CLEANUP**. Check that `Workspace.HCLightingLab` is gone and that the Baseplate is visible again.
5. In `report.md`, give your honest impression of each preset: realism, haze, shadows, and how close it gets to a GTA V street.

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
pcall(function() Lighting.Technology = Enum.Technology.Future end)

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
-- ground, road, markings, curbs, sidewalks
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
-- street lamps
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
-- brick mid-rise (road side x>0, facade at x=41 facing -X)
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
-- glass tower
part("Tower", Vector3.new(60, 220, 60), CFrame.new(71, 110.8, 95), C(64, 90, 106), Enum.Material.Glass, { Reflectance = 0.35 })
for z = 66, 124, 6 do part("Mullion", Vector3.new(0.6, 220, 0.4), CFrame.new(40.8, 110.8, z), C(170, 175, 180), Enum.Material.Metal) end
for y = 12, 216, 12 do
	part("Spandrel", Vector3.new(0.7, 1.2, 60.4), CFrame.new(40.8, y, 95), C(40, 46, 52), Enum.Material.Metal)
	part("SpandrelS", Vector3.new(60.4, 1.2, 0.7), CFrame.new(71, y, 64.8), C(40, 46, 52), Enum.Material.Metal)
end
for x = 42, 100, 6 do part("MullionS", Vector3.new(0.4, 220, 0.6), CFrame.new(x, 110.8, 64.8), C(170, 175, 180), Enum.Material.Metal) end
-- concrete office with ribbon windows (x<0, facade at x=-41 facing +X)
part("Office", Vector3.new(60, 100, 80), CFrame.new(-71, 50.8, -20), C(176, 172, 164), Enum.Material.Concrete)
for floor = 1, 7 do
	part("Ribbon", Vector3.new(0.4, 6.5, 78), CFrame.new(-40.85, 0.8 + 12 * floor + 4, -20), C(66, 84, 98), Enum.Material.Glass, { Reflectance = 0.3 })
end
-- stucco shop
part("Shop", Vector3.new(40, 24, 50), CFrame.new(-61, 12.8, 65), C(232, 212, 180), Enum.Material.Plaster)
part("ShopGlass", Vector3.new(0.3, 9, 40), CFrame.new(-40.85, 5.5, 65), C(60, 75, 85), Enum.Material.Glass, { Reflectance = 0.3 })
part("ShopSign", Vector3.new(0.8, 4, 30), CFrame.new(-40.6, 15, 65), C(28, 30, 34), Enum.Material.SmoothPlastic)
-- far skyline masses for atmospheric perspective
local seed = 7
local function rnd(a, b) seed = (seed * 1103515245 + 12345) % 2147483648; return a + (b - a) * (seed / 2147483648) end
for i = 1, 26 do
	local h = rnd(50, 300)
	local mat = (i % 3 == 0) and Enum.Material.Glass or Enum.Material.Concrete
	local col = (i % 3 == 0) and C(70, 92, 110) or C(rnd(150, 200), rnd(145, 190), rnd(135, 180))
	part("Far", Vector3.new(rnd(40, 80), h, rnd(40, 80)), CFrame.new(rnd(-500, 500), h / 2, rnd(450, 950)), col, mat, mat == Enum.Material.Glass and { Reflectance = 0.3 } or nil)
end
return "lab built: " .. #lab:GetChildren() .. " parts"
```

## PRESET

Replace `PRESET_NAME` with the preset name before running it.

```lua
local NAME = "PRESET_NAME"
local Lighting = game:GetService("Lighting")
local C = Color3.fromRGB
for _, c in Lighting:GetChildren() do if c.Name:sub(1, 6) == "HCLab_" then c:Destroy() end end
local terrain = workspace:FindFirstChildOfClass("Terrain")
for _, c in terrain:GetChildren() do if c.Name == "HCLab_Clouds" then c:Destroy() end end
local P = {
	day_clear = { clock = 14.2, bright = 3, amb = C(0, 0, 0), out = C(118, 124, 138), exp = 0, atm = { 0.32, 0.12, C(196, 210, 226), C(112, 124, 146), 0.35, 0.9 },
		bloom = { 0.55, 22, 1.7 }, cc = { 0.02, 0.12, 0.06, C(255, 250, 242) }, rays = { 0.05, 0.55 }, cloud = { 0.55, 0.45 }, night = false },
	golden_hour = { clock = 17.6, bright = 3.4, amb = C(0, 0, 0), out = C(132, 112, 98), exp = 0.05, atm = { 0.36, 0.08, C(255, 212, 168), C(196, 132, 104), 0.7, 1.3 },
		bloom = { 0.8, 28, 1.35 }, cc = { 0.01, 0.15, 0.12, C(255, 236, 214) }, rays = { 0.12, 0.6 }, cloud = { 0.5, 0.5 }, night = false },
	night = { clock = 22.4, bright = 1.2, amb = C(8, 9, 14), out = C(58, 66, 92), exp = 0.35, atm = { 0.4, 0.15, C(70, 80, 110), C(38, 40, 66), 0, 1.1 },
		bloom = { 1.1, 30, 0.95 }, cc = { 0, 0.18, 0.08, C(226, 232, 255) }, rays = { 0, 0.5 }, cloud = { 0.4, 0.4 }, night = true },
	overcast = { clock = 12.5, bright = 1.6, amb = C(10, 10, 12), out = C(150, 150, 156), exp = 0.1, atm = { 0.42, 0.1, C(204, 206, 212), C(150, 152, 160), 0, 2 },
		bloom = { 0.3, 20, 2 }, cc = { 0, 0.06, -0.15, C(246, 248, 255) }, rays = { 0, 0.5 }, cloud = { 0.95, 0.8 }, night = false },
}
local p = P[NAME]
assert(p, "unknown preset " .. NAME)
Lighting.ClockTime = p.clock; Lighting.Brightness = p.bright; Lighting.Ambient = p.amb; Lighting.OutdoorAmbient = p.out
Lighting.ExposureCompensation = p.exp; Lighting.GeographicLatitude = 34; Lighting.GlobalShadows = true; Lighting.ShadowSoftness = 0.15
Lighting.EnvironmentDiffuseScale = 1; Lighting.EnvironmentSpecularScale = 1
local a = Instance.new("Atmosphere"); a.Name = "HCLab_Atmosphere"
a.Density, a.Offset, a.Color, a.Decay, a.Glare, a.Haze = p.atm[1], p.atm[2], p.atm[3], p.atm[4], p.atm[5], p.atm[6]; a.Parent = Lighting
local sky = Instance.new("Sky"); sky.Name = "HCLab_Sky"; sky.SunAngularSize = 14; sky.MoonAngularSize = 9; sky.Parent = Lighting
local b = Instance.new("BloomEffect"); b.Name = "HCLab_Bloom"; b.Intensity, b.Size, b.Threshold = p.bloom[1], p.bloom[2], p.bloom[3]; b.Parent = Lighting
local cc = Instance.new("ColorCorrectionEffect"); cc.Name = "HCLab_CC"; cc.Brightness, cc.Contrast, cc.Saturation, cc.TintColor = p.cc[1], p.cc[2], p.cc[3], p.cc[4]; cc.Parent = Lighting
local r = Instance.new("SunRaysEffect"); r.Name = "HCLab_Rays"; r.Intensity, r.Spread = p.rays[1], p.rays[2]; r.Parent = Lighting
local cl = Instance.new("Clouds"); cl.Name = "HCLab_Clouds"; cl.Cover, cl.Density = p.cloud[1], p.cloud[2]; cl.Parent = terrain
local lab = workspace:FindFirstChild("HCLightingLab")
for _, d in lab:GetDescendants() do
	if d:IsA("BasePart") and d:GetAttribute("Lamp") then
		d.Material = p.night and Enum.Material.Neon or Enum.Material.Glass
		d.Color = p.night and C(255, 214, 170) or C(235, 235, 230)
		d:FindFirstChildOfClass("SpotLight").Enabled = p.night
	elseif d:IsA("BasePart") and d.Name == "Road" then
		d.Reflectance = p.night and 0.12 or 0
	end
end
return "preset " .. NAME .. " applied"
```

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
return "cleaned"
```
