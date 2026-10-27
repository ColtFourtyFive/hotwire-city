--!nocheck
-- The v2 look (pure): Config/Look presets + LightingService interpolation, the 24-minute clock, the engine sun model
-- (vs the real-engine probe), the sky-swap schedule against sun elevation, NightFactor, rate-limited sky yaw, cloud
-- share per sky, lit-window spread, wet streets, the client sky preload order, and that the generated Look data
-- matches what default.project.json bakes into the place (MaterialService variants/overrides, Lighting, default Sky).
return function(t)
	local H = t.H
	local fs = require("@lune/fs")
	local serde = require("@lune/serde")
	H.setMode("server")
	local Look = H.require("src/shared/Config/Look")
	local L = H.require("src/server/Systems/LightingService")

	local function lum(c)
		return 0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3]
	end
	local function chroma(c)
		return math.max(c[1], c[2], c[3]) - math.min(c[1], c[2], c[3])
	end

	-- Clock ------------------------------------------------------------------------------------------------------------
	t.test("clock: 24-minute day, inverse, wraps, night fast and day slow", function()
		t.eq(L.CYCLE_SECONDS, 24 * 60)
		t.near(L.hourAt(0), 0, 1e-9, "midnight at t=0")
		t.near(L.hourAt(L.CYCLE_SECONDS), 0, 1e-9, "wraps")
		local last = L.SEGMENTS[#L.SEGMENTS]
		t.near(last.t1, L.CYCLE_SECONDS, 1e-6, "segments fill the cycle")
		for _, h in { 0, 2, 4.5, 5.3, 6.2, 8.5, 12, 15.99, 16, 18.4, 20, 23.9 } do
			t.near(L.hourAt(L.timeForHour(h)), h, 1e-6, "inverse at " .. h)
		end
		-- monotonic within a cycle
		local prev = -1
		for s = 0, L.CYCLE_SECONDS - 1, 5 do
			local h = L.hourAt(s)
			t.ok(h > prev, "monotonic at " .. s)
			prev = h
		end
		local function secs(a, b)
			return L.timeForHour(b) - L.timeForHour(a)
		end
		local nightSecs = secs(0, 4.5) + (L.CYCLE_SECONDS - L.timeForHour(20))
		local daySecs = secs(8.5, 16)
		t.ok(nightSecs > 200 and nightSecs < 330, "night ~4-5 real minutes: " .. nightSecs)
		t.ok(daySecs > 420 and daySecs < 560, "day ~7-9 real minutes: " .. daySecs)
		t.ok(secs(16, 20) / 4 > secs(8.5, 16) / 7.5, "golden/dusk hours run slower than midday")
		t.ok(Look.Cycle.startHour >= 10 and Look.Cycle.startHour <= 13, "servers start in daylight")
		t.near(L.nightFactorAt(Look.Cycle.startHour), 0, 1e-9, "start hour is full day")
	end)

	-- Presets ----------------------------------------------------------------------------------------------------------
	t.test("presets: keys sorted, wrap at midnight, every key names a preset", function()
		local keys = Look.Keys
		t.eq(keys[1].hour, 0)
		t.eq(keys[#keys].hour, 24)
		t.eq(keys[1].preset, keys[#keys].preset, "midnight wraps to the same preset")
		for i = 2, #keys do
			t.ok(keys[i - 1].hour <= keys[i].hour, "keys sorted at " .. i)
		end
		local used = {}
		for _, k in keys do
			t.ok(Look.Presets[k.preset] ~= nil, "unknown preset " .. tostring(k.preset))
			used[k.preset] = true
		end
		for _, name in { "night", "blueMorning", "goldenMorning", "day", "goldenEvening", "blueEvening" } do
			t.ok(used[name], "preset in the cycle: " .. name)
		end
	end)

	t.test("presets: lab caps and colour rules (neutral haze, no purple/orange/teal, restrained grade)", function()
		for name, p in Look.Presets do
			local a = p.atmosphere
			t.ok(a.density >= 0.2 and a.density <= Look.Caps.densityMax, name .. " density " .. a.density)
			t.ok(a.haze <= Look.Caps.hazeMax, name .. " haze " .. a.haze)
			t.ok(a.offset >= 0.1, name .. " offset")
			-- haze colour: never purple (blue AND red well above green) and never saturated orange/teal
			local c = a.color
			t.ok(not (c[3] > c[2] + 12 and c[1] > c[2] + 4), name .. " atmosphere is purple")
			t.ok(chroma(c) <= 52, name .. " atmosphere too saturated: " .. chroma(c))
			for _, ch in p.colorCorrection.tint do
				t.ok(ch >= 225, name .. " tint channel below 225")
			end
			t.ok(p.colorCorrection.saturation <= 0.1, name .. " saturation > +0.10")
			t.ok(p.bloom.threshold >= 1.0, name .. " bloom threshold")
		end
		local day, night = Look.Presets.day, Look.Presets.night
		t.ok(chroma(day.atmosphere.color) <= 12, "day haze is neutral grey")
		t.ok(day.atmosphere.color[1] >= day.atmosphere.color[3], "day haze leans warm, not blue")
		t.ok(night.atmosphere.density < day.atmosphere.density, "lower density at night")
		t.ok(lum(night.atmosphere.color) < 70, "night haze is dark")
		t.ok(night.atmosphere.color[3] >= night.atmosphere.color[1], "night haze is navy-grey")
	end)

	t.test("lookAt: interpolates between keys, smooth over the whole cycle, caps always hold", function()
		local noon = L.lookAt(12)
		t.near(noon.brightness, Look.Presets.day.brightness, 1e-9, "plateau = day preset")
		t.near(noon.atmosphere.density, Look.Presets.day.atmosphere.density, 1e-9)
		local mid = L.lookAt(16.35) -- halfway between day (15.4) and goldenEvening (17.3)
		local d, g = Look.Presets.day, Look.Presets.goldenEvening
		t.ok(mid.brightness > math.min(d.brightness, g.brightness) - 1e-9, "between keys (lo)")
		t.ok(mid.brightness < math.max(d.brightness, g.brightness) + 1e-9, "between keys (hi)")
		t.ok(mid.colorCorrection.tint[3] < d.colorCorrection.tint[3], "warming toward golden")
		local midnight = L.lookAt(0)
		t.near(midnight.brightness, Look.Presets.night.brightness, 1e-9, "midnight = night preset")
		t.near(L.lookAt(24).brightness, midnight.brightness, 1e-9, "24 wraps to 0")
		-- golden is warmer than noon, night darker than noon
		local golden = L.lookAt(17.3)
		t.ok(
			golden.colorCorrection.tint[1] - golden.colorCorrection.tint[3]
				> noon.colorCorrection.tint[1] - noon.colorCorrection.tint[3],
			"golden tint warmer"
		)
		t.ok(golden.sunRays.intensity > noon.sunRays.intensity, "golden sun rays")
		t.ok(midnight.brightness < noon.brightness, "night darker")
		t.ok(midnight.atmosphere.density < noon.atmosphere.density, "thinner night atmosphere")
		-- no big jumps between consecutive env steps, caps hold everywhere (incl. the sky-swap haze bump)
		local prev = L.lookAt(L.hourAt(0))
		for s = Look.Cycle.envInterval, L.CYCLE_SECONDS, Look.Cycle.envInterval do
			local cur = L.lookAt(L.hourAt(s))
			t.ok(math.abs(cur.brightness - prev.brightness) < 0.15, "brightness step at " .. s)
			t.ok(math.abs(cur.atmosphere.haze - prev.atmosphere.haze) < 0.1, "haze step at " .. s)
			t.ok(cur.atmosphere.haze <= Look.Caps.hazeMax + 1e-9, "haze cap at " .. s)
			t.ok(cur.atmosphere.density <= Look.Caps.densityMax + 1e-9, "density cap at " .. s)
			prev = cur
		end
		-- lookAt never mutates the preset tables
		local before = Look.Presets.day.atmosphere.haze
		L.lookAt(15.8)
		t.eq(Look.Presets.day.atmosphere.haze, before, "presets untouched")
	end)

	t.test("lookAt: tuning (offset override, haze/density scale) and caps", function()
		local tuned = L.lookAt(12, { offset = 0.42, hazeScale = 5, densityScale = 5 })
		t.near(tuned.atmosphere.offset, 0.42, 1e-9, "offset override")
		t.near(tuned.atmosphere.haze, Look.Caps.hazeMax, 1e-9, "haze capped")
		t.near(tuned.atmosphere.density, Look.Caps.densityMax, 1e-9, "density capped")
		local plain = L.lookAt(12)
		t.near(plain.atmosphere.offset, Look.Presets.day.atmosphere.offset, 1e-9, "no override by default")
	end)

	-- NightFactor ------------------------------------------------------------------------------------------------------
	t.test("NightFactor: 0 by day, 1 at night, smooth monotonic ramps at dusk and dawn", function()
		t.eq(L.nightFactorAt(12), 0)
		t.eq(L.nightFactorAt(Look.Night.dawnEnd), 0)
		t.eq(L.nightFactorAt(Look.Night.duskStart), 0)
		t.eq(L.nightFactorAt(23), 1)
		t.eq(L.nightFactorAt(2), 1)
		t.eq(L.nightFactorAt(Look.Night.duskFull), 1)
		local mid = (Look.Night.duskStart + Look.Night.duskFull) / 2
		t.near(L.nightFactorAt(mid), 0.5, 1e-9, "half way through dusk")
		local prev = 0
		for h = Look.Night.duskStart, Look.Night.duskFull, 0.05 do
			local f = L.nightFactorAt(h)
			t.ok(f >= prev - 1e-9 and f <= 1, "dusk ramp monotonic at " .. h)
			prev = f
		end
		prev = 1
		for h = Look.Night.dawnFull, Look.Night.dawnEnd, 0.05 do
			local f = L.nightFactorAt(h)
			t.ok(f <= prev + 1e-9 and f >= 0, "dawn ramp monotonic at " .. h)
			prev = f
		end
		t.ok(L.nightFactorAt(24) == L.nightFactorAt(0), "wraps")
	end)

	-- Sky schedule -----------------------------------------------------------------------------------------------------
	t.test("sky schedule: sorted, every sky exists, right sky at the right time, wraps", function()
		local sched = Look.SkySchedule
		for i = 2, #sched do
			t.ok(sched[i - 1].hour < sched[i].hour, "schedule sorted")
		end
		for _, e in sched do
			t.ok(Look.Skies[e.sky] ~= nil, "schedule names a generated sky: " .. e.sky)
		end
		t.eq(L.skyAt(12), "day")
		t.eq(L.skyAt(17), "golden")
		t.eq(L.skyAt(7), "golden")
		t.eq(L.skyAt(18.8), "blue")
		t.eq(L.skyAt(5.5), "blue")
		t.eq(L.skyAt(23), "night")
		t.eq(L.skyAt(1), "night", "wraps over midnight")
		t.eq(L.skyAt(sched[1].hour - 0.01), sched[#sched].sky, "before the first entry = the last sky")
		local afterNoon
		for _, e in sched do
			if e.hour > 12 and afterNoon == nil then
				afterNoon = e
			end
		end
		local dt, nextSky = L.nextSkySwap(12)
		t.near(dt, afterNoon.hour - 12, 1e-9)
		t.eq(nextSky, "golden")
		local dt2, nextSky2 = L.nextSkySwap(23)
		t.near(dt2, sched[1].hour + 1, 1e-9, "next swap wraps")
		t.eq(nextSky2, sched[1].sky)
	end)

	t.test("sky swaps happen where they are hard to see", function()
		for _, e in Look.SkySchedule do
			local before = L.skyAt(e.hour - 0.01)
			local after = e.sky
			local pair = before .. ">" .. after
			if pair == "night>blue" or pair == "blue>night" then
				t.ok(L.nightFactorAt(e.hour) >= 0.5, pair .. " swaps in the dark (NightFactor)")
			end
			if before == "blue" or after == "blue" then
				-- blue-hour swaps happen with the sun below the horizon (Look.Sun: measured sunrise / sunset)
				t.ok(
					e.hour <= Look.Sun.rise or e.hour >= Look.Sun.set,
					pair .. " swaps with the sun below the horizon at " .. e.hour
				)
				t.ok(L.sunElevationAt(e.hour) <= 0, pair .. " sun elevation <= 0 at " .. e.hour)
			end
			if pair == "golden>day" or pair == "day>golden" then
				-- the golden HDRI (its own sun at ~8 deg) must not sit under a high engine sun ("two suns"), and the
				-- day sky must not show a sun skimming the horizon
				local el = L.sunElevationAt(e.hour)
				t.ok(el >= 15 and el <= 20, pair .. " at sun elevation 15..20 deg, got " .. el)
				local look = L.lookAt(e.hour)
				local g = if e.hour < 12 then Look.Presets.goldenMorning else Look.Presets.goldenEvening
				local d = Look.Presets.day
				local share = (look.colorCorrection.tint[3] - d.colorCorrection.tint[3])
					/ (g.colorCorrection.tint[3] - d.colorCorrection.tint[3])
				t.ok(share >= 0.6, pair .. ": the light is still mostly golden at the swap (" .. share .. ")")
			end
			-- every swap sits on a haze bump (capped)
			t.ok(L.swapHazeAt(e.hour) >= Look.SkySwap.hazeBoost - 1e-9, "haze bump at " .. pair)
			local look = L.lookAt(e.hour)
			t.ok(look.atmosphere.haze <= Look.Caps.hazeMax + 1e-9, "bump stays under the cap at " .. pair)
		end
		t.ok(L.swapHazeAt(12) < 0.01, "no bump at noon")
		-- the blue-hour sky only shows while it is getting dark / light
		for h = 0, 23.9, 0.1 do
			if L.skyAt(h) == "blue" then
				local f = L.nightFactorAt(h)
				t.ok(f > 0 and f < 1 or (h > 18 and h < 19.6) or (h > 4.8 and h < 6.4), "blue sky at twilight " .. h)
			end
			if L.skyAt(h) == "day" then
				t.eq(L.nightFactorAt(h), 0, "day sky only in daylight " .. h)
				t.ok(L.sunElevationAt(h) >= 18, "day sky only with the sun up high " .. h)
			end
			if L.skyAt(h) == "golden" then
				local el = L.sunElevationAt(h)
				t.ok(el > -2 and el < 19, "golden sky only with a low sun " .. h .. " (" .. el .. ")")
			end
			if L.skyAt(h) == "night" or L.skyAt(h) == "blue" then
				t.ok(L.sunElevationAt(h) < 0, "blue / night sky only with the sun down " .. h)
			end
		end
	end)

	-- Sun model (measured in the real engine) --------------------------------------------------------------------------
	t.test("sun model: reproduces every engine GetSunDirection sample (tools/look/sun_probe_result.json)", function()
		local probe = serde.decode("json", fs.readFile("tools/look/sun_probe_result.json"))
		t.ok(#probe.samples >= 100, "probe samples: " .. #probe.samples)
		local worst = 0
		for _, s in probe.samples do
			local x, y, z = L.sunDirectionAt(s.h, s.lat)
			local dot = math.clamp(x * s.x + y * s.y + z * s.z, -1, 1)
			worst = math.max(worst, math.deg(math.acos(dot)))
			-- the moon is the sun's antipode
			t.near(s.mel, -s.el, 0.05, "moon opposite the sun at " .. s.h)
		end
		t.ok(worst < 0.2, "model within 0.2 deg of the engine everywhere, worst " .. worst)
		t.near(L.sunElevationAt(Look.Sun.rise), 0, 1e-9, "rises at Look.Sun.rise")
		t.near(L.sunElevationAt(Look.Sun.set), 0, 1e-9, "sets at Look.Sun.set")
		t.near(L.sunElevationAt(12), 90 - (Look.Sun.latitude - Look.Sun.tiltOffset), 1e-6, "noon culmination")
		t.ok(L.sunElevationAt(Look.Sun.rise - 0.05) < 0 and L.sunElevationAt(Look.Sun.rise + 0.05) > 0, "rise sign")
		t.ok(L.sunElevationAt(Look.Sun.set - 0.05) > 0 and L.sunElevationAt(Look.Sun.set + 0.05) < 0, "set sign")
	end)

	-- Volumetric clouds per sky ----------------------------------------------------------------------------------------
	t.test("clouds: per-sky cover share, blended across swaps (no pop)", function()
		for name, def in Look.Skies do
			t.ok(def.clouds >= 0 and def.clouds <= 1, name .. " clouds share")
		end
		t.near(L.cloudScaleAt(12), Look.Skies.day.clouds, 1e-9, "day sky share at noon")
		t.near(L.cloudScaleAt(1), Look.Skies.night.clouds, 1e-9, "night share")
		local blueMid = (Look.SkySchedule[5].hour + Look.SkySchedule[6].hour) / 2
		t.near(L.cloudScaleAt(blueMid), Look.Skies.blue.clouds, 1e-9, "blue share mid blue hour")
		local prev = L.cloudScaleAt(0)
		for s = 1, L.CYCLE_SECONDS do
			local cur = L.cloudScaleAt(L.hourAt(s))
			t.ok(math.abs(cur - prev) < 0.08, "cloud share step at " .. s)
			prev = cur
		end
	end)

	-- Sky yaw following ------------------------------------------------------------------------------------------------
	t.test("sky follow: rate-limited, never spins with the noon sun sweep", function()
		t.near(L.stepYaw(10, 20, 3), 13, 1e-9, "limited step")
		t.near(L.stepYaw(10, 12, 3), 12, 1e-9, "reaches the target")
		t.near(L.stepYaw(178, -178, 3), -179, 1e-9, "short way round across +-180")
		t.near(L.stepYaw(0, 90, math.huge), 90, 1e-9, "huge step snaps")
		-- simulate the day sky from its swap to the golden swap at the clock rate
		local def = Look.Skies.day
		local dtTick = Look.Cycle.clockInterval
		local rate = Look.SkyStyle.maxYawRate
		local t0 = L.timeForHour(Look.SkySchedule[3].hour)
		local x, _, z = L.sunDirectionAt(L.hourAt(t0))
		local cur = L.skyYaw(def.glowAzimuth, x, z)
		local maxStep, maxTargetStep = 0, 0
		local prevTarget = cur
		local tEnd = L.timeForHour(Look.SkySchedule[4].hour)
		local s = t0
		while s < tEnd do
			s += dtTick
			local sx, _, sz = L.sunDirectionAt(L.hourAt(s))
			local target = L.skyYaw(def.glowAzimuth, sx, sz)
			maxTargetStep = math.max(maxTargetStep, math.abs(L.wrapDeg(target - prevTarget)))
			prevTarget = target
			local nxt = L.stepYaw(cur, target, rate * dtTick)
			maxStep = math.max(maxStep, math.abs(L.wrapDeg(nxt - cur)))
			cur = nxt
		end
		t.ok(maxStep <= rate * dtTick + 1e-9, "sky never turns faster than maxYawRate: " .. maxStep)
		t.ok(
			maxTargetStep / dtTick > 2 * rate,
			"(the raw noon sweep would be much faster: " .. maxTargetStep / dtTick .. ")"
		)
		t.ok(rate <= 0.5, "maxYawRate reads as cloud drift")
		t.ok(Look.SkyStyle.yawEpsilon < rate * dtTick, "every tick's step can be written (smooth)")
	end)

	t.test("night sky: the city glow is parked inland (fixedGlowAzimuth), with the CFrame.Angles convention", function()
		local night = Look.Skies.night
		t.eq(night.followSun, false)
		local yaw = L.yawToward(night.horizonGlowAzimuth, Look.SkyStyle.fixedGlowAzimuth, 1)
		local cf = H.roblox.CFrame
		local a = math.rad(night.horizonGlowAzimuth)
		local dir = H.roblox.Vector3.new(math.sin(a), 0, -math.cos(a))
		local rotated = cf.Angles(0, math.rad(yaw), 0) * dir
		t.near(L.azimuthOf(rotated.X, rotated.Z), Look.SkyStyle.fixedGlowAzimuth, 1e-4, "glow lands inland")
	end)

	-- Lit windows ------------------------------------------------------------------------------------------------------
	t.test("windows: deterministic per position, ~share lit, warm/cool mix, thresholds spread over dusk", function()
		local W = Look.Windows
		local n, lit, warm = 0, 0, 0
		local buckets = { 0, 0, 0, 0 }
		for i = 0, 59 do
			for j = 0, 49 do
				-- a facade grid: 6-stud window bays, 12-stud floors, on a building at an odd offset
				local p = L.windowParams(137.25 + i * 6, 14 + j * 12, -402.5)
				n += 1
				t.ok(p.threshold >= W.onBand[1] and p.threshold <= W.onBand[2], "threshold in band")
				t.ok(p.brightness >= W.brightness[1] and p.brightness <= W.brightness[2], "brightness in range")
				if p.lit then
					lit += 1
					if p.warm then
						warm += 1
					end
				end
				local b =
					math.clamp(math.floor((p.threshold - W.onBand[1]) / (W.onBand[2] - W.onBand[1]) * 4) + 1, 1, 4)
				buckets[b] += 1
			end
		end
		t.near(lit / n, W.share, 0.04, "lit share")
		t.near(warm / lit, W.warmShare, 0.05, "warm share among lit")
		for b = 1, 4 do
			t.near(buckets[b] / n, 0.25, 0.05, "thresholds spread evenly, quarter " .. b)
		end
		t.ok(W.share >= 0.3 and W.share <= 0.6, "30-60 % of windows lit (gta_realism_gap)")
		local a, b = L.windowParams(10, 20, 30), L.windowParams(10, 20, 30)
		t.eq(a.lit, b.lit)
		t.eq(a.threshold, b.threshold, "deterministic")
		t.eq(L.windowParams(10.1, 20, 30).threshold, a.threshold, "half-stud rounding absorbs float noise")
		t.ok(L.windowParams(16, 20, 30).threshold ~= a.threshold, "neighbours differ")
		t.ok(W.onBand[2] <= 1 and W.onBand[1] > 0, "all lit windows are on by full night, none at day")
	end)

	-- Wet streets -----------------------------------------------------------------------------------------------------
	t.test("wet streets: switch at Look.WetStreets.nightFactor with hysteresis", function()
		local w, hys = Look.WetStreets, Look.Night.hysteresis
		t.eq(L.wetAt(0, false), false)
		t.eq(L.wetAt(1, false), true)
		t.eq(L.wetAt(w.nightFactor, false), false, "needs +hysteresis to turn on")
		t.eq(L.wetAt(w.nightFactor + hys, false), true)
		t.eq(L.wetAt(w.nightFactor, true), true, "stays wet just under")
		t.eq(L.wetAt(w.nightFactor - hys, true), false)
		t.eq(Look.Materials[w.wet].color[1], Look.Materials[w.dry].color[1], "wet variant uses the dry Part.Color")
		t.ok(Look.Materials[w.wet].colorMap ~= Look.Materials[w.dry].colorMap, "wet variant has its own darker map")
	end)

	t.test("sky yaw: puts the sky glow azimuth on the engine sun azimuth", function()
		t.near(L.azimuthOf(0, -1), 0, 1e-9, "-Z = 0")
		t.near(L.azimuthOf(1, 0), 90, 1e-9, "+X = 90")
		t.near(math.abs(L.azimuthOf(0, 1)), 180, 1e-9, "+Z = 180")
		t.near(L.skyYaw(34, 0, -1, 1), 34, 1e-9, "sun at -Z: rotate the glow (34) back to 0")
		t.near(L.skyYaw(34, 1, 0, 1), 34 - 90, 1e-9)
		t.near(L.skyYaw(34, 1, 0, -1), 90 - 34, 1e-9, "sign flips the convention")
		t.eq(L.skyYaw(30, 0.001, 0.001, 1), nil, "sun overhead: no azimuth")
		for _, a in { -350, -180, 0, 179, 180, 181, 540 } do
			local w = L.wrapDeg(a)
			t.ok(w > -180 and w <= 180, "wrap " .. a)
		end
		-- applying the yaw with the CFrame.Angles(0, y, 0) convention moves the glow onto the sun
		local cf = H.roblox.CFrame
		local glowAz, sunX, sunZ = 38.3, -0.6, 0.8
		local yaw = L.skyYaw(glowAz, sunX, sunZ, 1)
		local dir = H.roblox.Vector3.new(math.sin(math.rad(glowAz)), 0, -math.cos(math.rad(glowAz)))
		local rotated = cf.Angles(0, math.rad(yaw), 0) * dir
		t.near(L.azimuthOf(rotated.X, rotated.Z), L.azimuthOf(sunX, sunZ), 1e-4, "glow lands on the sun")
	end)

	-- Generated data <-> place file -----------------------------------------------------------------------------------
	local project = serde.decode("json", fs.readFile("default.project.json"))
	local tree = project.tree

	t.test("generated materials: complete, Image ids, overrides consistent with the place file", function()
		local ms = tree.MaterialService
		t.ok(ms ~= nil, "MaterialService in default.project.json")
		t.eq(ms["$properties"].Use2022Materials, true, "2022 materials on")
		local n = 0
		for name, m in Look.Materials do
			n += 1
			t.ok(name:sub(1, 3) == "HC_", "HC_ prefix: " .. name)
			for _, prop in { "colorMap", "normalMap", "roughnessMap" } do
				t.ok(type(m[prop]) == "string" and m[prop]:match("^rbxassetid://%d+$"), name .. " " .. prop)
			end
			t.ok(m.studsPerTile > 1 and m.studsPerTile < 40, name .. " studsPerTile")
			t.ok(m.pattern == "Regular" or m.pattern == "Organic", name .. " pattern")
			t.eq(#m.color, 3, name .. " colour")
			local node = ms[name]
			t.ok(node ~= nil, "variant baked into the place: " .. name)
			t.eq(node["$className"], "MaterialVariant")
			local p = node["$properties"]
			t.eq(p.BaseMaterial, m.baseMaterial, name .. " BaseMaterial")
			t.eq(p.ColorMap, m.colorMap, name .. " ColorMap")
			t.eq(p.NormalMap, m.normalMap, name .. " NormalMap")
			t.eq(p.RoughnessMap, m.roughnessMap, name .. " RoughnessMap")
			t.eq(p.MetalnessMap, m.metalnessMap, name .. " MetalnessMap")
			t.near(p.StudsPerTile, m.studsPerTile, 1e-6, name .. " StudsPerTile")
			t.eq(p.MaterialPattern, m.pattern, name .. " MaterialPattern")
			if m.override then
				t.eq(ms["$properties"][m.baseMaterial .. "Name"], name, "override " .. m.baseMaterial)
				t.eq(Look.Overrides[m.baseMaterial], name)
			end
		end
		t.ok(n >= 18, "at least the 18 required materials: " .. n)
		for _, base in { "Asphalt", "Concrete", "Brick", "Plaster", "Grass", "Sand", "Rock", "CorrodedMetal" } do
			t.ok(Look.Overrides[base] ~= nil, "override for " .. base)
		end
		t.eq(Look.Overrides.Metal, nil, "no global Metal override (lamp poles, cars, guns use Metal)")
		local glass = Look.Materials.HC_WindowGlass
		t.eq(glass.baseMaterial, "SmoothPlastic", "glass variant base (no GlassName slot)")
		t.ok(glass.metalnessMap ~= nil, "glass is a (tinted) mirror: metalness map")
		t.ok(lum(glass.color) > 100 and chroma(glass.color) < 40, "glass tint is a light blue-grey, not dark slate")
		-- terrain colours only for materials Terrain:SetMaterialColor accepts (engine probe)
		for name in Look.TerrainColors do
			t.ok(
				name ~= "Marble"
					and name ~= "Pebble"
					and name ~= "Plaster"
					and name ~= "ClayRoofTiles"
					and name ~= "CorrodedMetal",
				"terrain colour for a part-only material: " .. name
			)
		end
		t.ok(Look.TerrainColors.Grass ~= nil and Look.TerrainColors.Sand ~= nil, "lawn + seabed colours")
		-- big flat materials tile large enough not to read as a board-game track / repeating cliff
		t.ok(Look.Materials.HC_Asphalt.studsPerTile >= 14, "asphalt tile >= 14 studs")
		t.ok(Look.Materials.HC_Rock.studsPerTile >= 28, "rock tile ~32 studs")
		t.ok(Look.Materials.HC_RockSlate.colorMap ~= Look.Materials.HC_Rock.colorMap, "Slate has its own rock")
		-- every <X>Name override in the file points at a variant with that BaseMaterial
		for prop, variant in ms["$properties"] do
			if prop ~= "Use2022Materials" then
				local base = prop:sub(1, #prop - 4)
				t.eq(ms[variant]["$properties"].BaseMaterial, base, prop .. " -> " .. variant)
			end
		end
	end)

	t.test("generated decals and skies: Image ids for every face and decal", function()
		local nd = 0
		for name, d in Look.Decals do
			nd += 1
			t.ok(d.image:match("^rbxassetid://%d+$"), "decal id " .. name)
		end
		t.ok(nd >= 15, "decals: " .. nd)
		for _, need in
			{ "line_white_dash", "line_yellow_double", "crosswalk_bars_white", "stop_line_white", "arrow_left" }
		do
			t.ok(Look.Decals[need] ~= nil, "decal " .. need)
		end
		for _, sky in { "day", "golden", "blue", "night" } do
			local s = Look.Skies[sky]
			t.ok(s ~= nil, "sky " .. sky)
			for _, f in { "Bk", "Dn", "Ft", "Lf", "Rt", "Up" } do
				t.ok(s.faces[f]:match("^rbxassetid://%d+$"), sky .. " face " .. f)
			end
			t.ok(type(s.glowAzimuth) == "number", sky .. " glow azimuth")
			t.ok(type(s.horizonGlowAzimuth) == "number", sky .. " horizon glow azimuth")
			t.ok(type(s.celestialBodiesShown) == "boolean", sky .. " celestial flag")
		end
		-- overcast / light-polluted skies: no stars; the night deck already has its moonlit clouds (no second moon)
		t.eq(Look.Skies.night.starCount, 0, "no stars over the night cloud deck")
		t.eq(Look.Skies.blue.starCount, 0, "no stars at blue hour over the city")
		t.eq(Look.Skies.night.celestialBodiesShown, false, "no engine moon disc over the night deck")
		t.eq(Look.Skies.day.celestialBodiesShown, true, "engine sun disc by day (the HDRI sun is painted out)")
		-- skies with painted clouds do not get a second volumetric layer
		t.eq(Look.Skies.day.clouds, 0)
		t.eq(Look.Skies.golden.clouds, 0)
		t.eq(Look.Skies.night.clouds, 0)
	end)

	t.test("water: deep green-blue, reflective (no tropical-pool cyan)", function()
		local w = Look.Water
		t.ok(w.color[3] < 120 and w.color[2] < 110, "dark water")
		t.ok(chroma(w.color) < 70, "not saturated cyan")
		t.ok(w.reflectance >= 0.8, "reflective")
		t.ok(w.transparency <= 0.35, "transparency")
	end)

	t.test("place file Lighting: Realistic + quality, no Technology, day preset + day sky baked in", function()
		local lt = tree.Lighting
		local p = lt["$properties"]
		t.eq(p.Technology, nil, "deprecated Technology removed")
		t.eq(p.LightingStyle, "Realistic")
		t.eq(p.PrioritizeLightingQuality, true)
		t.eq(p.GlobalShadows, true)
		t.eq(p.EnvironmentDiffuseScale, 1)
		t.eq(p.EnvironmentSpecularScale, 1)
		local day = Look.Presets.day
		t.near(p.Brightness, day.brightness, 1e-6)
		t.near(p.ShadowSoftness, day.shadowSoftness, 1e-6)
		t.near(p.ClockTime, Look.Cycle.startHour, 1e-6)
		t.near(p.OutdoorAmbient[1] * 255, day.outdoorAmbient[1], 0.6)
		local a = lt.Atmosphere["$properties"]
		t.near(a.Density, day.atmosphere.density, 1e-6)
		t.near(a.Haze, day.atmosphere.haze, 1e-6)
		t.near(a.Offset, day.atmosphere.offset, 1e-6)
		t.eq(lt.Bloom["$className"], "BloomEffect")
		t.eq(lt.ColorCorrection["$className"], "ColorCorrectionEffect")
		t.eq(lt.SunRays["$className"], "SunRaysEffect")
		local sky = lt.Sky["$properties"]
		for _, f in { "Bk", "Dn", "Ft", "Lf", "Rt", "Up" } do
			t.eq(sky["Skybox" .. f], Look.Skies.day.faces[f], "default sky = day sky " .. f)
		end
		t.eq(sky.SunAngularSize, Look.SkyStyle.sunAngularSize)
		t.eq(sky.StarCount, Look.Skies.day.starCount)
		t.eq(sky.CelestialBodiesShown, Look.Skies.day.celestialBodiesShown)
		t.eq(p.GeographicLatitude, Look.Sun.latitude, "the measured sun model's latitude")
	end)

	-- Client sky preload -----------------------------------------------------------------------------------------------
	t.test("LookClient: preloads every sky face, the sky that comes up next first", function()
		H.setMode("client")
		local LookClient = H.require("src/client/Controllers/LookClient")
		H.setMode("server")
		local order = LookClient.skyOrder("day")
		t.eq(order[1], "golden", "after day comes golden")
		t.eq(order[#order], "day", "the sky already on screen goes last")
		local seen = {}
		for _, name in order do
			t.ok(not seen[name], "no duplicates: " .. name)
			seen[name] = true
		end
		for name in Look.Skies do
			t.ok(seen[name], "every sky preloaded: " .. name)
		end
		local ids = LookClient.skyAssetList("night")
		local want = 0
		for _ in Look.Skies do
			want += 6
		end
		t.eq(#ids, want, "six faces per sky")
		t.eq(ids[1], Look.Skies.blue.faces.Bk, "night -> blue first")
		t.eq(#LookClient.skyOrder(nil), #order, "unknown current sky: all skies")
	end)
end
