--!nocheck
-- LightingService v2 runtime (headless): adopts one Sky/Atmosphere/effect of each class, cheap writes, Workspace
-- NightFactor / TimeOfDay attributes, sky face swaps + yaw, TimeOfDayLock / AtmosphereOffsetOverride, v1 contract.
return function(t)
	local H = t.H
	local fs = require("@lune/fs")
	local task = require("@lune/task")
	H.setMode("server")
	local Instance = H.roblox.Instance
	local Vector3 = H.roblox.Vector3
	local Look = H.require("src/shared/Config/Look")
	local L = H.require("src/server/Systems/LightingService")
	local Lighting = H.game:GetService("Lighting")
	local Workspace = H.workspace

	local function count(className)
		local n = 0
		for _, c in Lighting:GetChildren() do
			if c:IsA(className) then
				n += 1
			end
		end
		return n
	end

	t.test("never writes the deprecated Lighting.Technology", function()
		local src = fs.readFile("src/server/Systems/LightingService.luau")
		t.ok(not src:find("%.Technology%s*="), "no Technology assignment")
		t.ok(not src:find("Enum%.Technology"), "no Enum.Technology")
	end)

	t.test("init: one Sky / Atmosphere / effect of each class; DepthOfField and Blur off", function()
		for _, spec in
			{
				{ "Sky", "OldSky" },
				{ "Sky", "Sky" },
				{ "Atmosphere", "HotwireAtmosphere" },
				{ "BloomEffect", "TemplateBloom" },
				{ "SunRaysEffect", "SunRays" },
				{ "SunRaysEffect", "HotwireSunRays" },
				{ "DepthOfFieldEffect", "DepthOfField" },
			}
		do
			local i = Instance.new(spec[1])
			i.Name = spec[2]
			i.Parent = Lighting
		end
		L.init()
		for _, cls in { "Sky", "Atmosphere", "BloomEffect", "ColorCorrectionEffect", "SunRaysEffect" } do
			t.eq(count(cls), 1, "exactly one " .. cls)
		end
		t.ok(Lighting:FindFirstChild("Sky") ~= nil, "the place file's Sky (by name) is the one kept")
		t.ok(Lighting:FindFirstChild("SunRays") ~= nil, "SunRays kept by name")
		local dof = Lighting:FindFirstChildOfClass("DepthOfFieldEffect")
		t.eq(dof.Enabled, false, "world-wide depth of field disabled")
		local sky = Lighting:FindFirstChildOfClass("Sky")
		t.eq(sky.SunAngularSize, Look.SkyStyle.sunAngularSize)
		t.eq(Lighting.GlobalShadows, true)
		L.init() -- re-init stays at one of each
		t.eq(count("Sky"), 1)
		t.eq(count("Atmosphere"), 1)
		dof:Destroy()
	end)

	t.test("clock state: NightFactor + TimeOfDay attributes, IsNight / NightChanged with hysteresis", function()
		local fired = {}
		L.NightChanged:Connect(function(v)
			table.insert(fired, v)
		end)
		L.setClockTime(12)
		t.eq(Workspace:GetAttribute("NightFactor"), 0)
		t.near(Workspace:GetAttribute("TimeOfDay"), 12, 0.051)
		t.near(Lighting.ClockTime, 12, 0.01)
		t.eq(L.isNight(), false)
		L.setClockTime(23)
		t.eq(Workspace:GetAttribute("NightFactor"), 1)
		t.eq(L.isNight(), true)
		t.eq(Lighting:GetAttribute("IsNight"), true)
		t.eq(fired[#fired], true, "NightChanged(true)")
		-- just under the switch point on the way back: hysteresis keeps it night
		local on = Look.Night.lightsOn
		local h = Look.Night.duskStart
		while L.nightFactorAt(h) < on - Look.Night.hysteresis * 0.5 do
			h += 0.01
		end
		L.setClockTime(h)
		t.eq(L.isNight(), true, "hysteresis holds night just below lightsOn")
		L.setClockTime(12)
		t.eq(L.isNight(), false)
		t.eq(fired[#fired], false, "NightChanged(false)")
		t.near(L.getNightFactor(), 0, 1e-9)
	end)

	t.test("cheap writes: unchanged values are skipped, real changes written", function()
		t.eq(L._changed(nil, 1, 0.1), true, "never written")
		t.eq(L._changed(1, 1.05, 0.1), false)
		t.eq(L._changed(1, 1.2, 0.1), true)
		local c = H.roblox.Color3.fromRGB
		t.eq(L._changed(c(10, 10, 10), c(11, 10, 10), 1.5 / 255), false)
		t.eq(L._changed(c(10, 10, 10), c(13, 10, 10), 1.5 / 255), true)
		t.eq(L._changed(Vector3.new(0, 1, 0), Vector3.new(0, 1.5, 0), 1), false)
		t.eq(L._changed(1, c(1, 1, 1), 0.1), true, "type change")
		L.setClockTime(12)
		Lighting.Brightness = 0.123 -- simulated foreign write: the cache must not rewrite an unchanged look
		Workspace:SetAttribute("NightFactor", 0.77)
		L.setClockTime(12)
		t.near(Lighting.Brightness, 0.123, 1e-6, "skipped")
		t.eq(Workspace:GetAttribute("NightFactor"), 0.77, "attribute write skipped too")
		L.setClockTime(0)
		local night = L.lookAt(0)
		t.near(Lighting.Brightness, night.brightness, 0.03, "a real change is written")
		local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
		t.near(atmo.Density, night.atmosphere.density, 0.005, "night density applied")
		t.near(atmo.Haze, night.atmosphere.haze, 0.03, "night haze applied")
		local bloom = Lighting:FindFirstChildOfClass("BloomEffect")
		t.near(bloom.Threshold, night.bloom.threshold, 0.02, "night bloom threshold applied")
		L.setClockTime(12)
		t.near(Lighting.Brightness, Look.Presets.day.brightness, 0.03, "day restored")
	end)

	t.test("sky: faces swap on schedule, stars per sky, yaw follows the engine sun", function()
		local sky = Lighting:FindFirstChildOfClass("Sky")
		local real = L._sunDirection
		L._sunDirection = function()
			return Vector3.new(0.6, 0.3, 0.74) -- some sun direction (not overhead)
		end
		L.setClockTime(12)
		t.eq(Lighting:GetAttribute("Sky"), "day")
		t.eq(sky.SkyboxFt, Look.Skies.day.faces.Ft, "day faces")
		t.eq(sky.SkyboxUp, Look.Skies.day.faces.Up)
		local want = L.skyYaw(Look.Skies.day.glowAzimuth, 0.6, 0.74)
		t.near(sky.SkyboxOrientation.Y, want, 1e-3, "yaw aligns the day glow")
		L.setClockTime(23)
		t.eq(Lighting:GetAttribute("Sky"), "night")
		t.eq(sky.SkyboxBk, Look.Skies.night.faces.Bk, "night faces")
		t.eq(sky.StarCount, Look.Skies.night.starCount)
		L.setClockTime(17)
		t.eq(Lighting:GetAttribute("Sky"), "golden")
		t.eq(sky.SkyboxLf, Look.Skies.golden.faces.Lf, "golden faces")
		-- follow: the sun moved a little -> no rewrite under the epsilon, a real move -> rewrite
		local y0 = sky.SkyboxOrientation.Y
		L._sunDirection = function()
			return Vector3.new(0.61, 0.3, 0.735)
		end
		L.setClockTime(17.01)
		t.near(sky.SkyboxOrientation.Y, y0, 1e-6, "tiny sun move: orientation untouched")
		L._sunDirection = function()
			return Vector3.new(-0.7, 0.2, 0.68)
		end
		L.setClockTime(17.05)
		t.near(sky.SkyboxOrientation.Y, L.skyYaw(Look.Skies.golden.glowAzimuth, -0.7, 0.68), 1e-3, "follows")
		-- no engine sun (e.g. headless): faces still swap, yaw just stays
		L._sunDirection = function()
			return nil
		end
		L.setClockTime(12)
		t.eq(sky.SkyboxFt, Look.Skies.day.faces.Ft)
		L._sunDirection = real
	end)

	t.test("TimeOfDayLock holds the clock; AtmosphereOffsetOverride tunes Offset live", function()
		Workspace:SetAttribute("TimeOfDayLock", 17.3)
		t.near(L.getClockTime(), 17.3, 1e-6, "locked")
		Workspace:SetAttribute("TimeOfDayLock", nil)
		t.near(L.getClockTime(), 17.3, 0.02, "unlocking continues from the locked hour")
		Workspace:SetAttribute("AtmosphereOffsetOverride", 0.05)
		L.setClockTime(12)
		t.near(Lighting:FindFirstChildOfClass("Atmosphere").Offset, 0.05, 1e-6, "override applied")
		Workspace:SetAttribute("AtmosphereOffsetOverride", nil)
		L.setClockTime(12)
		t.near(Lighting:FindFirstChildOfClass("Atmosphere").Offset, Look.Presets.day.atmosphere.offset, 1e-6)
	end)

	t.test("v1 contract: StreetLight lights and NightGlow parts switch with the night", function()
		local folder = Instance.new("Folder")
		folder.Parent = Workspace
		local lamp = Instance.new("Part")
		lamp.Parent = folder
		local pl = Instance.new("PointLight")
		pl.Parent = lamp
		lamp:AddTag(L.TAG_STREET_LIGHT)
		local win = Instance.new("Part")
		win:SetAttribute("NightColor", H.roblox.Color3.fromRGB(255, 220, 160))
		win:SetAttribute("NightMaterial", "Neon")
		win:SetAttribute("DayColor", H.roblox.Color3.fromRGB(60, 70, 80))
		win:SetAttribute("DayMaterial", "Glass")
		win.Parent = folder
		win:AddTag(L.TAG_NIGHT_GLOW)
		L.setClockTime(12)
		L.setClockTime(23)
		task.wait()
		t.eq(pl.Enabled, true, "lamp on at night")
		t.eq(win.Material.Name, "Neon", "window lit")
		L.setClockTime(12)
		task.wait()
		t.eq(pl.Enabled, false, "lamp off by day")
		t.eq(win.Material.Name, "Glass")
		folder:Destroy()
	end)
end
