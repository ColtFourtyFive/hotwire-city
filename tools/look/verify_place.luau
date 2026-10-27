--!nocheck
-- Verifies the look inside a BUILT place (what Roblox will load), not just default.project.json:
--   MaterialService: Use2022Materials, every <Material>Name override -> an existing HC_ variant with that BaseMaterial,
--                    every variant has Image-id colour/normal/roughness maps, StudsPerTile, MaterialPattern
--   Lighting:        LightingStyle Realistic, PrioritizeLightingQuality, GlobalShadows, Environment scales, one Sky
--                    with all six faces = Look.Skies.day, one Atmosphere within the lab caps, Bloom/CC/SunRays
-- Usage: rojo build -o build/HotwireCity.rbxlx && lune run tools/look/verify_place.luau [build/HotwireCity.rbxlx]
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local Look = require("../../src/shared/Config/Look")

local path = process.args[1] or "build/HotwireCity.rbxlx"
local game = roblox.deserializePlace(fs.readFile(path))
local problems = {}
local function check(cond, msg)
	if not cond then
		table.insert(problems, msg)
	end
end
local function contentUri(v)
	-- Content (new) or ContentId (string) depending on the property
	if typeof(v) == "string" then
		return v
	end
	local ok, uri = pcall(function()
		return v.Uri
	end)
	if ok and uri then
		return uri
	end
	return tostring(v)
end

-- MaterialService ------------------------------------------------------------------------------------------------
local ms = game:GetService("MaterialService")
local variants = {}
for _, c in ms:GetChildren() do
	if c:IsA("MaterialVariant") then
		variants[c.Name] = c
	end
end
local nVariants, nOverrides = 0, 0
for name, def in Look.Materials do
	local v = variants[name]
	check(v ~= nil, "missing MaterialVariant " .. name)
	if v then
		nVariants += 1
		check(v.BaseMaterial.Name == def.baseMaterial, name .. " BaseMaterial " .. v.BaseMaterial.Name)
		check(contentUri(v.ColorMapContent) == def.colorMap, name .. " ColorMap " .. contentUri(v.ColorMapContent))
		check(contentUri(v.NormalMapContent) == def.normalMap, name .. " NormalMap")
		check(contentUri(v.RoughnessMapContent) == def.roughnessMap, name .. " RoughnessMap")
		if def.metalnessMap then
			check(contentUri(v.MetalnessMapContent) == def.metalnessMap, name .. " MetalnessMap")
		end
		check(math.abs(v.StudsPerTile - def.studsPerTile) < 1e-3, name .. " StudsPerTile " .. v.StudsPerTile)
		check(v.MaterialPattern.Name == def.pattern, name .. " MaterialPattern " .. v.MaterialPattern.Name)
	end
	if def.override then
		local prop = def.baseMaterial .. "Name"
		local ok, val = pcall(function()
			return ms[prop]
		end)
		check(ok and val == name, "override " .. prop .. " = " .. tostring(val))
		if ok and val == name then
			nOverrides += 1
		end
	end
end
local ok2022, use2022 = pcall(function()
	return ms.Use2022MaterialsXml
end)
check(ok2022 and use2022 == true, "MaterialService.Use2022Materials(Xml) = " .. tostring(use2022))

-- Lighting -------------------------------------------------------------------------------------------------------
local lighting = game:GetService("Lighting")
check(lighting.LightingStyle.Name == "Realistic", "LightingStyle " .. lighting.LightingStyle.Name)
check(lighting.PrioritizeLightingQuality == true, "PrioritizeLightingQuality")
check(lighting.GlobalShadows == true, "GlobalShadows")
check(lighting.EnvironmentDiffuseScale == 1 and lighting.EnvironmentSpecularScale == 1, "Environment scales")
local counts = {}
for _, c in lighting:GetChildren() do
	counts[c.ClassName] = (counts[c.ClassName] or 0) + 1
end
for _, cls in { "Sky", "Atmosphere", "BloomEffect", "ColorCorrectionEffect", "SunRaysEffect" } do
	check(counts[cls] == 1, "Lighting has " .. tostring(counts[cls]) .. " " .. cls)
end
local sky = lighting:FindFirstChildOfClass("Sky")
if sky then
	for face, long in { Bk = "Back", Dn = "Down", Ft = "Front", Lf = "Left", Rt = "Right", Up = "Up" } do
		local uri = contentUri(sky["Skybox" .. long .. "Content"])
		check(uri == Look.Skies.day.faces[face], "Sky " .. face .. " = " .. uri)
	end
end
local atmo = lighting:FindFirstChildOfClass("Atmosphere")
if atmo then
	check(atmo.Density <= Look.Caps.densityMax + 1e-6, "Atmosphere.Density " .. atmo.Density)
	check(atmo.Haze <= Look.Caps.hazeMax + 1e-6, "Atmosphere.Haze " .. atmo.Haze)
end

-- the deprecated Technology must not be in the file (an .rbxlx is XML; a binary .rbxl is skipped here)
local raw = fs.readFile(path)
local techInFile = raw:sub(1, 6) == "<roblox" and raw:find('name="Technology"', 1, true) ~= nil
check(not techInFile, "deprecated Lighting.Technology is serialized in the place")
print(
	("place %s: %d MaterialVariants, %d overrides, LightingStyle %s, PrioritizeLightingQuality %s, Technology in file: %s, Sky faces day, Atmosphere %.2f/%.2f/%.2f"):format(
		path,
		nVariants,
		nOverrides,
		lighting.LightingStyle.Name,
		tostring(lighting.PrioritizeLightingQuality),
		tostring(techInFile),
		atmo and atmo.Density or -1,
		atmo and atmo.Offset or -1,
		atmo and atmo.Haze or -1
	)
)
for _, p in problems do
	print("PROBLEM " .. p)
end
print(#problems == 0 and "OK" or ("%d problems"):format(#problems))
process.exit(#problems == 0 and 0 or 1)
