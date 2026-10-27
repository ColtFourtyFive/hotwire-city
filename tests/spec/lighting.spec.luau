--!nocheck
-- LightingService v2 runtime (headless): adopts one Sky/Atmosphere/effect of each class, cheap writes, Workspace
-- NightFactor / TimeOfDay attributes, sky face swaps + per-sky stars / discs / clouds, rate-limited yaw, the parked
-- night glow, TimeOfDayLock / AtmosphereOffsetOverride / CloudsOverride, lit windows (LitWindow + v1 glass NightGlow),
-- terrain water + material colours, wet streets, and the v1 contract.
return function(t)
	local H = t.H
	local fs = require("@lune/fs")
	local task = require("@lune/task")
	H.setMode("server")
	local Instance = H.roblox.Instance
	local Vector3 = H.roblox.Vector3
	local Color3 = H.roblox.Color3
	local Enum = H.roblox.Enum
	local Look = H.require("src/shared/Config/Look")
	local L = H.require("src/server/Systems/LightingService")
	local Lighting = H.game:GetService("Lighting")
	local Workspace = H.workspace
	local CollectionService = H.game:GetService("CollectionService")

	-- Terrain:SetMaterialColor does nothing headless: record the calls through the hook
	local terrainColors = {}
	L._setTerrainColor = function(_terrain, mat, c)
		terrainColors[mat.Name] = c
	end

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
		t.near(Lighting.GeographicLatitude, Look.Sun.latitude, 1e-6, "latitude of the measured sun model")
		L.init() -- re-init stays at one of each
		t.eq(count("Sky"), 1)
		t.eq(count("Atmosphere"), 1)
		dof:Destroy()
	end)

	t.test("init: terrain water and terrain material colours from Config/Look", function()
		table.clear(terrainColors)
		L.init()
		local terrain = Workspace:FindFirstChildOfClass("Terrain")
		local w = Look.Water
		t.eq(terrain.WaterColor, Color3.fromRGB(w.color[1], w.color[2], w.color[3]), "water colour")
		t.near(terrain.WaterTransparency, w.transparency, 1e-6)
		t.near(terrain.WaterReflectance, w.reflectance, 1e-6)
		t.near(terrain.WaterWaveSize, w.waveSize, 1e-6)
		local n = 0
		for name, c in Look.TerrainColors do
			n += 1
			t.eq(terrainColors[name], Color3.fromRGB(c[1], c[2], c[3]), "terrain colour " .. name)
		end
		t.ok(n >= 10, "terrain colours applied: " .. n)
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
		local c = Color3.fromRGB
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

	t.test("sky: faces swap on schedule with per-sky stars / sun-moon discs; parked night glow", function()
		local sky = Lighting:FindFirstChildOfClass("Sky")
		local real = L._sunDirection
		L._sunDirection = function()
			return Vector3.new(0.6, 0.3, 0.74) -- some sun direction (not overhead)
		end
		L.setClockTime(12)
		t.eq(Lighting:GetAttribute("Sky"), "day")
		t.eq(sky.SkyboxFt, Look.Skies.day.faces.Ft, "day faces")
		t.eq(sky.SkyboxUp, Look.Skies.day.faces.Up)
		t.eq(sky.CelestialBodiesShown, true, "engine sun disc by day")
		local want = L.skyYaw(Look.Skies.day.glowAzimuth, 0.6, 0.74)
		t.near(sky.SkyboxOrientation.Y, want, 1e-3, "an admin jump snaps the yaw onto the sun")
		L.setClockTime(23)
		t.eq(Lighting:GetAttribute("Sky"), "night")
		t.eq(sky.SkyboxBk, Look.Skies.night.faces.Bk, "night faces")
		t.eq(sky.StarCount, Look.Skies.night.starCount)
		t.eq(sky.CelestialBodiesShown, false, "no engine moon over the night deck")
		t.near(
			sky.SkyboxOrientation.Y,
			L.yawToward(Look.Skies.night.horizonGlowAzimuth, Look.SkyStyle.fixedGlowAzimuth),
			1e-3,
			"night city glow parked inland"
		)
		L.setClockTime(17)
		t.eq(Lighting:GetAttribute("Sky"), "golden")
		t.eq(sky.SkyboxLf, Look.Skies.golden.faces.Lf, "golden faces")
		t.eq(sky.CelestialBodiesShown, true)
		L._sunDirection = real
	end)

	t.test("sky follow: eases toward the sun at maxYawRate per second, tiny moves not rewritten", function()
		local sky = Lighting:FindFirstChildOfClass("Sky")
		local real = L._sunDirection
		local sun = Vector3.new(0.6, 0.3, 0.74)
		L._sunDirection = function()
			return sun
		end
		L.setClockTime(17) -- golden, snapped
		local glow = Look.Skies.golden.glowAzimuth
		local y0 = sky.SkyboxOrientation.Y
		t.near(y0, L.skyYaw(glow, sun.X, sun.Z), 1e-3)
		-- the sun jumps 40 deg of azimuth: the sky turns maxYawRate * dt per tick, not all at once
		sun = Vector3.new(-0.2, 0.3, 0.93)
		local target = L.skyYaw(glow, sun.X, sun.Z)
		L._applySky(17.01, 1)
		local y1 = sky.SkyboxOrientation.Y
		t.near(math.abs(L.wrapDeg(y1 - y0)), Look.SkyStyle.maxYawRate, 1e-3, "one second of turning")
		t.ok(math.abs(L.wrapDeg(target - y1)) < math.abs(L.wrapDeg(target - y0)), "toward the target")
		for _ = 1, 400 do
			L._applySky(17.01, 1)
		end
		t.near(sky.SkyboxOrientation.Y, target, 1e-3, "converges on the sun")
		-- a sub-epsilon move is not written
		sky.SkyboxOrientation = Vector3.new(0, 123, 0) -- foreign write, to see whether the next tick rewrites
		sun = Vector3.new(-0.2001, 0.3, 0.93)
		L._applySky(17.02, 0.25)
		t.near(sky.SkyboxOrientation.Y, 123, 1e-6, "tiny sun move: orientation untouched")
		-- no engine sun (headless): the measured model drives the yaw
		L._sunDirection = function()
			return nil
		end
		L.setClockTime(12)
		t.eq(sky.SkyboxFt, Look.Skies.day.faces.Ft)
		local mx, _, mz = L.sunDirectionAt(12, Lighting.GeographicLatitude)
		t.near(sky.SkyboxOrientation.Y, L.skyYaw(Look.Skies.day.glowAzimuth, mx, mz), 1e-3, "model sun")
		L._sunDirection = real
	end)

	t.test("clouds: no volumetric layer under painted-cloud skies, CloudsOverride for lab A/B", function()
		local clouds = Workspace:FindFirstChildOfClass("Terrain"):FindFirstChildOfClass("Clouds")
		t.ok(clouds ~= nil, "clouds adopted/created")
		L.setClockTime(12)
		t.near(clouds.Cover, Look.Presets.day.clouds.cover * Look.Skies.day.clouds, 0.011, "day cover share")
		local blueMid = (Look.SkySchedule[5].hour + Look.SkySchedule[6].hour) / 2
		L.setClockTime(blueMid)
		t.ok(clouds.Cover > 0.2, "volumetric clouds over the clear blue-hour sky: " .. clouds.Cover)
		Workspace:SetAttribute("CloudsOverride", 0)
		L.setClockTime(blueMid + 0.01)
		t.near(clouds.Cover, 0, 1e-6, "override 0 hides them")
		Workspace:SetAttribute("CloudsOverride", nil)
		L.setClockTime(12)
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
		local sign = Instance.new("Part")
		sign:SetAttribute("NightColor", Color3.fromRGB(255, 220, 160))
		sign:SetAttribute("NightMaterial", "Neon")
		sign:SetAttribute("DayColor", Color3.fromRGB(60, 70, 80))
		sign:SetAttribute("DayMaterial", "SmoothPlastic")
		sign.Parent = folder
		sign:AddTag(L.TAG_NIGHT_GLOW)
		L.setClockTime(12)
		L.setClockTime(23)
		task.wait()
		t.eq(pl.Enabled, true, "lamp on at night")
		t.eq(sign.Material.Name, "Neon", "sign lit")
		L.setClockTime(12)
		task.wait()
		t.eq(pl.Enabled, false, "lamp off by day")
		t.eq(sign.Material.Name, "SmoothPlastic")
		folder:Destroy()
	end)

	t.test("lit windows: ~share lit at night, warm + cool, filling in over dusk, day look restored", function()
		local folder = Instance.new("Folder")
		folder.Parent = Workspace
		local parts = {}
		for i = 0, 19 do
			for j = 0, 9 do
				local p = Instance.new("Part")
				p.Size = Vector3.new(5, 7, 0.4)
				p.CFrame = H.roblox.CFrame.new(400 + i * 6, 10 + j * 12, 250)
				p.Material = Enum.Material.SmoothPlastic
				p.Color = Color3.fromRGB(40, 48, 56)
				p.Parent = folder
				p:AddTag(L.TAG_LIT_WINDOW)
				table.insert(parts, p)
			end
		end
		-- a v1 glass NightGlow band is adopted as a window; a StreetLight bulb never is
		local band = Instance.new("Part")
		band.CFrame = H.roblox.CFrame.new(-300, 30, 90)
		band.Material = Enum.Material.Glass
		band:SetAttribute("DayColor", band.Color)
		band:SetAttribute("DayMaterial", "Glass")
		band:SetAttribute("NightColor", Color3.fromRGB(255, 208, 120))
		band:SetAttribute("NightMaterial", "Neon")
		band.Parent = folder
		band:AddTag(L.TAG_NIGHT_GLOW)
		local bulb = Instance.new("Part")
		bulb:SetAttribute("DayMaterial", "Glass")
		bulb:SetAttribute("NightMaterial", "Neon")
		bulb.Parent = folder
		bulb:AddTag(L.TAG_NIGHT_GLOW)
		bulb:AddTag(L.TAG_STREET_LIGHT)
		L.setClockTime(12)
		L.init() -- registers the tagged parts (live servers also pick up late tags via the added signals)
		local n = L.windowStats()
		t.eq(n, #parts + 1, "LitWindow parts + the adopted glass band (not the street-light bulb)")
		local function litCount()
			local lit, warm = 0, 0
			for _, p in parts do
				if p.Material == Enum.Material.Neon then
					lit += 1
					if p.Color.R > p.Color.B then
						warm += 1
					end
				end
			end
			return lit, warm
		end
		L.setClockTime(12)
		t.eq((litCount()), 0, "all dark by day")
		t.eq(parts[1]:GetAttribute("DayMaterial"), "SmoothPlastic", "day look captured")
		-- mid dusk: some on, not all
		local mid = Look.Night.duskStart
		while L.nightFactorAt(mid) < 0.5 do
			mid += 0.02
		end
		L.setClockTime(mid)
		task.wait()
		local midLit = litCount()
		L.setClockTime(23)
		task.wait()
		local lit, warm = litCount()
		t.ok(lit / #parts > 0.35 and lit / #parts < 0.65, "about half lit at night: " .. lit)
		t.ok(warm > 0 and warm < lit, "warm and cool windows: " .. warm .. "/" .. lit)
		t.ok(midLit > 0 and midLit < lit, "windows fill in over dusk: " .. midLit .. " of " .. lit)
		local p = L.windowParams(-300, 30, 90)
		t.eq(band.Material == Enum.Material.Neon, p.lit, "adopted v1 band follows its own hash")
		t.eq(bulb.Material.Name, "Neon", "street-light bulb keeps the v1 glow")
		L.setClockTime(12)
		task.wait()
		t.eq((litCount()), 0, "dark again by day")
		t.eq(parts[1].Material, Enum.Material.SmoothPlastic, "day material restored")
		t.eq(parts[1].Color, Color3.fromRGB(40, 48, 56), "day colour restored")
		t.eq(band.Material, Enum.Material.Glass)
		folder:Destroy()
		L.setClockTime(12.01)
		t.eq((L.windowStats()), 0, "destroyed windows are dropped")
	end)

	t.test("wet streets: applied at init when starting at night, switched at the threshold", function()
		local calls = {}
		local realHook = L._setAsphaltOverride
		L._setAsphaltOverride = function(name)
			table.insert(calls, name)
		end
		local w = Look.WetStreets
		local was = w.enabled
		w.enabled = true
		Workspace:SetAttribute("TimeOfDayLock", 23)
		L.init()
		Workspace:SetAttribute("TimeOfDayLock", nil)
		t.eq(calls[#calls], w.wet, "a server that starts at night has wet streets")
		t.eq(L.isWet(), true)
		L.setClockTime(12)
		t.eq(calls[#calls], w.dry, "dry by day")
		local h = Look.Night.duskStart
		while L.nightFactorAt(h) < w.nightFactor + Look.Night.hysteresis do
			h += 0.01
		end
		L.setClockTime(h - 0.03)
		t.eq(L.isWet(), false, "not yet")
		L.setClockTime(h + 0.01)
		t.eq(L.isWet(), true, "wet past Look.WetStreets.nightFactor")
		w.enabled = was
		L._setAsphaltOverride = realHook
		L.setClockTime(12)
	end)
end
