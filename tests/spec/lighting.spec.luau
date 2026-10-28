--!nocheck
-- LightingService v2 runtime (headless): dedupes Lighting to one Sky/Atmosphere/effect of each class (init and late
-- additions, the owned instance kept), cheap writes, the engine ClockTime vs the game-hour Workspace NightFactor /
-- TimeOfDay attributes (held at night, one jump, EngineClockOverride), sky face swaps + per-sky stars / discs /
-- clouds, rate-limited yaw, the parked night glow, TimeOfDayLock / AtmosphereOffsetOverride / CloudsOverride, dim lit
-- windows (LitWindow + v1 glass NightGlow; facade-sized parts never Neon), terrain water + material colours, wet
-- streets, the v1 contract, the runtime base-material overrides (job 0009), the job 0011 sweep overrides and the moon.
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

	local MANAGED = { "Sky", "Atmosphere", "BloomEffect", "ColorCorrectionEffect", "SunRaysEffect" }
	local function isManaged(inst)
		for _, cls in MANAGED do
			if inst:IsA(cls) then
				return true
			end
		end
		return false
	end
	local function add(className, name)
		local i = Instance.new(className)
		i.Name = name
		i.Parent = Lighting
		return i
	end

	t.test("init on a fresh place: the place file's instances (by name) are kept, strays destroyed", function()
		for _, c in Lighting:GetChildren() do
			if isManaged(c) then
				c:Destroy()
			end
		end
		local stray = add("Sky", "OldSky")
		local placeSky = add("Sky", "Sky")
		add("Atmosphere", "HotwireAtmosphere")
		local placeAtmo = add("Atmosphere", "Atmosphere")
		add("BloomEffect", "TemplateBloom")
		add("SunRaysEffect", "SunRays")
		add("SunRaysEffect", "HotwireSunRays")
		local dof = add("DepthOfFieldEffect", "DepthOfField")
		L.init()
		for _, cls in MANAGED do
			t.eq(count(cls), 1, "exactly one " .. cls)
		end
		t.eq(Lighting:FindFirstChildOfClass("Sky"), placeSky, "the place file's Sky (by name) is the one kept")
		t.eq(stray.Parent, nil, "the stray Sky is destroyed")
		t.eq(Lighting:FindFirstChildOfClass("Atmosphere"), placeAtmo, "Atmosphere kept by name")
		t.ok(Lighting:FindFirstChild("SunRays") ~= nil, "SunRays kept by name")
		t.ok(Lighting:FindFirstChildOfClass("ColorCorrectionEffect") ~= nil, "a missing effect is created")
		for _, cls in MANAGED do
			t.eq(Lighting:FindFirstChildOfClass(cls):GetAttribute(L.OWNED_ATTRIBUTE), true, cls .. " marked owned")
		end
		t.eq(dof.Enabled, false, "world-wide depth of field disabled")
		t.eq(dof.Parent, Lighting, "depth of field is not a managed class: disabled, not destroyed")
		t.eq(placeSky.SunAngularSize, Look.SkyStyle.sunAngularSize)
		t.eq(Lighting.GlobalShadows, true)
		t.near(Lighting.GeographicLatitude, Look.Sun.latitude, 1e-6, "latitude of the measured sun model")
		L.init() -- re-init stays at one of each
		t.eq(count("Sky"), 1)
		t.eq(count("Atmosphere"), 1)
		dof:Destroy()
	end)

	t.test("dedupe: Team Create duplicates (every class doubled) -> exactly one each, the owned ones kept", function()
		L.init()
		local owned = {}
		for _, cls in MANAGED do
			owned[cls] = Lighting:FindFirstChildOfClass(cls)
		end
		-- what job 0007 found after Rojo failed to swap the Lighting node: Sky x2, Atmosphere x2, Bloom x2, SunRays x2
		-- (the newcomers carry the SAME names as the place file's), plus a disabled duplicate ColorCorrection
		add("Sky", "Sky")
		add("Atmosphere", "Atmosphere")
		add("BloomEffect", "Bloom")
		add("SunRaysEffect", "SunRays")
		add("ColorCorrectionEffect", "ColorCorrection")
		owned.ColorCorrectionEffect.Enabled = false -- e.g. the copy that survived was the disabled one
		local destroyed = L.dedupe()
		t.eq(destroyed, 5, "five duplicates destroyed")
		for _, cls in MANAGED do
			t.eq(count(cls), 1, "exactly one " .. cls)
			t.eq(Lighting:FindFirstChildOfClass(cls), owned[cls], "the owned " .. cls .. " survives (not the newcomer)")
		end
		t.eq(owned.ColorCorrectionEffect.Enabled, true, "kept post effects are enabled")
		t.eq(owned.BloomEffect.Enabled, true)
		t.eq(owned.SunRaysEffect.Enabled, true)
		t.eq(L.dedupe(), 0, "idempotent")
		-- a duplicate added while running (Lighting.ChildAdded -> deferred handler) is destroyed too
		local late = add("Atmosphere", "LateAtmosphere")
		L._onLightingChildAdded(late)
		t.eq(late.Parent, nil, "late duplicate destroyed")
		t.eq(Lighting:FindFirstChildOfClass("Atmosphere"), owned.Atmosphere)
		local folder = add("Folder", "NotAnEffect")
		L._onLightingChildAdded(folder)
		t.eq(folder.Parent, Lighting, "other children are left alone")
		folder:Destroy()
		-- the owned Sky is deleted and another appears: it is adopted and fully configured on the next apply
		L.setClockTime(12)
		owned.Sky:Destroy()
		local fresh = add("Sky", "RojoSky")
		L._onLightingChildAdded(fresh)
		t.eq(fresh:GetAttribute(L.OWNED_ATTRIBUTE), true, "the replacement is owned")
		t.eq(fresh.SunAngularSize, Look.SkyStyle.sunAngularSize, "static sky setup applied")
		L.setClockTime(12)
		t.eq(fresh.SkyboxFt, Look.Skies.day.faces.Ft, "faces written to the replacement (write cache reset)")
		t.eq(count("Sky"), 1)
	end)

	t.test("init: base-material overrides applied on the server (job 0009), idempotent, failures summarised", function()
		local MS = H.game:GetService("MaterialService")
		local MO = H.require("src/shared/Util/MaterialOverrides")
		-- the real engine of job 0009: the file's <Material>Name properties are not honoured -> stock names
		table.clear(H.materialOverrides)
		t.eq(MS:GetBaseMaterialOverride(Enum.Material.Asphalt), "Asphalt", "stock name before init")
		L.init()
		local n = 0
		for base, variant in Look.Overrides do
			n += 1
			t.eq(MS:GetBaseMaterialOverride(Enum.Material[base]), variant, "server override " .. base)
		end
		t.ok(n >= 16, "every override: " .. n)
		t.eq(MS:GetAttribute(MO.ATTRIBUTE), n, "MaterialService HCOverridesActive")
		t.eq(MO.countActive(), n)
		-- idempotent: re-init writes nothing
		local writes = 0
		local realSet = MO._set
		MO._set = function(mat, name)
			writes += 1
			realSet(mat, name)
		end
		L.init()
		t.eq(writes, 0, "already-active overrides are not set again")
		local r = MO.apply("server")
		t.eq(#r.already, n)
		MO._set = realSet
		-- an engine error is caught and reported, never thrown; a missing variant is not pointed at
		table.clear(H.materialOverrides)
		H.materialOverrideError = "boom"
		local okInit = pcall(L.init)
		H.materialOverrideError = nil
		t.ok(okInit, "init survives SetBaseMaterialOverride errors")
		local r2 = MO.apply("server", { Asphalt = "HC_Asphalt", Brick = "HC_Missing", Bogus = "HC_Sand" }, true)
		t.eq(#r2.set, 1, "Asphalt set")
		t.eq(#r2.missing, 1, "the missing variant is listed")
		t.eq(r2.pending.HC_Missing, "Brick")
		t.eq(#r2.failed, 1, "a bad base material fails cleanly")
		t.ok(r2.failed[1]:find("Bogus", 1, true) ~= nil, "failure names the material")
		t.eq(MS:GetBaseMaterialOverride(Enum.Material.Brick), "Brick", "Brick not pointed at a missing variant")
		t.ok(MO.summary("server", r2):find("missing variant: Brick -> HC_Missing", 1, true) ~= nil, "summary")
		L.init() -- back to all active
		t.eq(MO.countActive(), n)
	end)

	t.test("sweep overrides (job 0011): Workspace attributes replace look values live, cleared = the look", function()
		L.setClockTime(12)
		local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
		local cc = Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
		t.near(atmo.Density, Look.AtmosphereDensity.day, 0.005, "day Density from Look.AtmosphereDensity")
		Workspace:SetAttribute("AtmosphereDensityOverride", 0.27)
		Workspace:SetAttribute("ExposureOverride", 1.5)
		Workspace:SetAttribute("TintOverride", Color3.fromRGB(200, 220, 255))
		Workspace:SetAttribute("BrightnessOverride", 2)
		Workspace:SetAttribute("SaturationOverride", -0.25)
		Workspace:SetAttribute("OutdoorAmbientOverride", Color3.fromRGB(90, 100, 120))
		Workspace:SetAttribute("AtmosphereHazeOverride", 0.5)
		L.setClockTime(12)
		t.near(atmo.Density, 0.27, 1e-6, "density override")
		t.near(atmo.Haze, 0.5, 1e-6, "haze override")
		t.near(Lighting.ExposureCompensation, 1.5, 1e-6, "exposure override")
		t.near(Lighting.Brightness, 2, 1e-6, "brightness override")
		t.near(cc.Saturation, -0.25, 1e-6, "saturation override")
		t.near(cc.TintColor.R * 255, 200, 1, "tint override")
		t.near(Lighting.OutdoorAmbient.G * 255, 100, 1, "outdoor ambient override")
		for name in L.OVERRIDE_ATTRIBUTES do
			Workspace:SetAttribute(name, nil)
		end
		L.setClockTime(12)
		t.near(atmo.Density, Look.Presets.day.atmosphere.density, 0.005, "back to the preset")
		t.near(Lighting.ExposureCompensation, Look.Presets.day.exposure, 0.011)
		t.near(cc.TintColor.B * 255, Look.Presets.day.colorCorrection.tint[3], 1.6)
	end)

	t.test("moon: hidden while the engine sun is up, small at twilight, MoonSizeOverride", function()
		local sky = Lighting:FindFirstChildOfClass("Sky")
		local real = L._sunDirection
		L._sunDirection = function()
			return nil -- headless: the measured model at the engine clock
		end
		L.setClockTime(12)
		t.eq(sky.MoonAngularSize, 0, "noon: no moon")
		L.setClockTime(17.6) -- job 0009's golden lock: a big moon sat on the horizon
		t.eq(sky.MoonAngularSize, 0, "golden hour: no moon")
		L.setClockTime(18.8)
		t.eq(Lighting:GetAttribute("Sky"), "blue")
		t.near(sky.MoonAngularSize, Look.SkyStyle.moonAngularSize, 1e-6, "twilight: a small moon")
		Workspace:SetAttribute("MoonSizeOverride", 4)
		L.setClockTime(12.01)
		t.near(sky.MoonAngularSize, 4, 1e-6, "override shows it at noon")
		Workspace:SetAttribute("MoonSizeOverride", nil)
		L.setClockTime(12)
		t.eq(sky.MoonAngularSize, 0)
		L._sunDirection = real
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
		t.near(Lighting.ClockTime, 12, 0.01, "by day the engine clock is the game hour")
		t.eq(L.isNight(), false)
		L.setClockTime(23)
		t.eq(Workspace:GetAttribute("NightFactor"), 1)
		t.near(Workspace:GetAttribute("TimeOfDay"), 23, 0.051, "TimeOfDay is the GAME hour")
		t.near(Lighting.ClockTime, Look.EngineClock.eveningHold, 1e-3, "engine clock held near the evening horizon")
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

	t.test("engine clock: held at night (no writes), one jump at full night, EngineClockOverride", function()
		local E = Look.EngineClock
		L.setClockTime(21)
		t.near(Lighting.ClockTime, E.eveningHold, 1e-3, "evening hold")
		t.near(L.getEngineClockTime(), E.eveningHold, 1e-3)
		t.near(L.getClockTime(), 21, 0.02, "getClockTime is the game hour")
		Lighting.ClockTime = 3.33 -- foreign write: a held engine clock is not rewritten every tick
		L.setClockTime(22.5)
		t.near(Lighting.ClockTime, 3.33, 1e-6, "the hold costs no writes")
		t.eq(Workspace:GetAttribute("NightFactor"), 1)
		L.setClockTime(E.jumpHour + 0.01)
		t.near(Lighting.ClockTime, E.morningHold, 1e-3, "jumped to the morning hold")
		t.eq(Workspace:GetAttribute("NightFactor"), 1, "still full night: NightFactor follows the game hour")
		t.eq(Lighting:GetAttribute("Sky"), "night", "the fixed night sky is up across the jump")
		L.setClockTime(3)
		t.near(Lighting.ClockTime, E.morningHold, 1e-3, "morning hold")
		-- the lab override pins the engine clock without touching the game hour
		Workspace:SetAttribute("EngineClockOverride", 18.05)
		L.setClockTime(2)
		t.near(Lighting.ClockTime, 18.05, 1e-6, "override applied")
		t.near(Workspace:GetAttribute("TimeOfDay"), 2, 0.051, "game hour untouched")
		t.eq(Workspace:GetAttribute("NightFactor"), 1)
		Workspace:SetAttribute("EngineClockOverride", nil)
		L.setClockTime(12)
		t.near(Lighting.ClockTime, 12, 1e-3, "back on the game clock by day")
		-- the dusk ease: between the game hour and the hold, never past it
		L.setClockTime(18.5)
		t.ok(
			Lighting.ClockTime > 18 and Lighting.ClockTime < E.eveningHold,
			"easing into the hold: " .. Lighting.ClockTime
		)
		L.setClockTime(12)
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
		L.setClockTime(18.8)
		t.eq(Lighting:GetAttribute("Sky"), "blue")
		t.eq(sky.SkyboxLf, Look.Skies.blue.faces.Lf, "blue faces")
		t.eq(sky.CelestialBodiesShown, Look.Skies.blue.celestialBodiesShown)
		L.setClockTime(17.3)
		t.eq(Lighting:GetAttribute("Sky"), "day", "golden hour under the day sky (no day <-> golden swap)")
		t.eq(sky.SkyboxLf, Look.Skies.day.faces.Lf)
		L.setClockTime(5.3)
		t.eq(Lighting:GetAttribute("Sky"), "dawn", "its own dawn sky before sunrise")
		t.eq(sky.SkyboxFt, Look.Skies.dawn.faces.Ft, "dawn faces")
		t.eq(sky.CelestialBodiesShown, Look.Skies.dawn.celestialBodiesShown)
		L._sunDirection = real
	end)

	t.test("sky: SkyOverride forces a sky with its own settings; unknown / wrong-typed values are ignored", function()
		local sky = Lighting:FindFirstChildOfClass("Sky")
		local real = L._sunDirection
		L._sunDirection = function()
			return Vector3.new(-0.98, -0.05, 0.18) -- the held evening sun (west, -3 deg)
		end
		L.setClockTime(19.0)
		t.eq(Lighting:GetAttribute("Sky"), "blue", "the schedule at 19.0")
		Workspace:SetAttribute("SkyOverride", "night")
		L._applySky(19.0, 0.25)
		t.eq(Lighting:GetAttribute("Sky"), "night", "forced")
		t.eq(sky.SkyboxUp, Look.Skies.night.faces.Up, "the forced sky's faces")
		t.eq(sky.CelestialBodiesShown, Look.Skies.night.celestialBodiesShown, "the forced sky's own discs")
		t.near(
			sky.SkyboxOrientation.Y,
			L.yawToward(Look.Skies.night.horizonGlowAzimuth, Look.SkyStyle.fixedGlowAzimuth),
			1e-3,
			"the forced sky's own yaw rule (parked, not following the sun)"
		)
		Workspace:SetAttribute("SkyOverride", "noSuchSky")
		L._applySky(19.0, 0.25)
		t.eq(Lighting:GetAttribute("Sky"), "blue", "an unknown name falls back to the schedule")
		t.eq(sky.SkyboxUp, Look.Skies.blue.faces.Up)
		Workspace:SetAttribute("SkyOverride", 3)
		L._applySky(19.0, 0.25)
		t.eq(Lighting:GetAttribute("Sky"), "blue", "a wrong-typed value is ignored")
		Workspace:SetAttribute("SkyOverride", nil)
		L.setClockTime(12)
		t.eq(Lighting:GetAttribute("Sky"), "day")
		L._sunDirection = real
	end)

	t.test("sky follow: eases toward the sun at maxYawRate per second, tiny moves not rewritten", function()
		local sky = Lighting:FindFirstChildOfClass("Sky")
		local real = L._sunDirection
		local sun = Vector3.new(0.6, 0.3, 0.74)
		L._sunDirection = function()
			return sun
		end
		L.setClockTime(17) -- day sky (follows the sun), snapped
		local glow = Look.Skies.day.glowAzimuth
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
		local sched = Look.SkySchedule
		local blueMid
		for i, e in sched do
			if e.sky == "blue" and e.hour > 12 then
				blueMid = (e.hour + sched[i % #sched + 1].hour) / 2
			end
		end
		L.setClockTime(blueMid)
		local blueCover = Look.Presets.blueEvening.clouds.cover * Look.Skies.blue.clouds
		t.near(clouds.Cover, blueCover, 0.03, "blue-hour cover share: " .. clouds.Cover)
		-- backlog 14: the procedural dusk / dawn / night skies are clear (the gradient and stars stay visible)
		t.near(clouds.Cover, 0, 1e-6, "no volumetric layer over the clear dusk sky")
		L.setClockTime(23)
		t.near(clouds.Cover, 0, 1e-6, "none over the clear night sky")
		-- the lab multiplier: wherever a sky keeps a share, CloudsOverride scales it (0 hides it)
		local hour
		for h = 0, 23.5, 0.5 do
			if hour == nil and L.cloudScaleAt(h) > 0.5 then
				hour = h
			end
		end
		if hour then
			Workspace:SetAttribute("CloudsOverride", 0)
			L.setClockTime(hour)
			t.near(clouds.Cover, 0, 1e-6, "override 0 hides them")
			Workspace:SetAttribute("CloudsOverride", nil)
		end
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
		-- v1 facade-sized glass (ribbon windows, whole towers): lab round 2 S6 saw these glow as slabs / columns
		local facades = {}
		for i = 0, 23 do
			local f = Instance.new("Part")
			f.Size = Vector3.new(40, 12, 1)
			f.CFrame = H.roblox.CFrame.new(-600 + i * 47, 24 + (i % 3) * 12, -150)
			f.Material = Enum.Material.Glass
			f:SetAttribute("DayColor", f.Color)
			f:SetAttribute("DayMaterial", "Glass")
			f:SetAttribute("NightColor", Color3.fromRGB(255, 208, 120))
			f:SetAttribute("NightMaterial", "Neon")
			f.Parent = folder
			f:AddTag(L.TAG_NIGHT_GLOW)
			table.insert(facades, f)
		end
		L.setClockTime(12)
		L.init() -- registers the tagged parts (live servers also pick up late tags via the added signals)
		local n = L.windowStats()
		t.eq(n, #parts + 1 + #facades, "LitWindow parts + the adopted glass band + facades (not the street-light bulb)")
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
		-- dim: a lit Neon cell is at colour x <= 0.4 (lab round 2 S6), and facade-sized parts are never Neon
		for _, part in parts do
			if part.Material == Enum.Material.Neon then
				t.ok(
					math.max(part.Color.R, part.Color.G, part.Color.B) <= Look.Windows.brightness[2] + 1e-6,
					"dim Neon"
				)
			end
		end
		local facadeLit = 0
		for _, f in facades do
			t.ok(f.Material ~= Enum.Material.Neon, "a facade part never lights as Neon")
			local fp = L.windowParams(f.CFrame.Position.X, f.CFrame.Position.Y, f.CFrame.Position.Z)
			if fp.lit then
				facadeLit += 1
				t.eq(f.Material.Name, Look.Windows.facadeMaterial, "lit facade uses the non-emissive material")
			else
				t.eq(f.Material, Enum.Material.Glass, "unlit facade keeps its glass")
			end
		end
		t.ok(facadeLit > 0 and facadeLit < #facades, "some facades lit, some not: " .. facadeLit)
		L.setClockTime(12)
		task.wait()
		t.eq((litCount()), 0, "dark again by day")
		t.eq(parts[1].Material, Enum.Material.SmoothPlastic, "day material restored")
		t.eq(parts[1].Color, Color3.fromRGB(40, 48, 56), "day colour restored")
		t.eq(band.Material, Enum.Material.Glass)
		for _, f in facades do
			t.eq(f.Material, Enum.Material.Glass, "facade glass restored by day")
		end
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
