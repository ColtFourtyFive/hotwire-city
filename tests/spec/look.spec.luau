--!nocheck
-- The v2 look (pure): Config/Look presets + LightingService interpolation, the 24-minute game clock, the engine clock
-- mapping (lab round 2: the engine sun never goes deep below the horizon), the engine sun model (vs the real-engine
-- probe), the sky-swap schedule against the engine sun, the swap / jump exposure dip, NightFactor continuity, the
-- locked day Atmosphere, the faked night, rate-limited sky yaw, cloud share per sky, lit-window spread + the building
-- package's window helper, wet streets, the client sky preload order, and that the generated Look data matches what
-- default.project.json bakes into the place (MaterialService variants/overrides, Lighting, default Sky). Job 0009 /
-- look-fix3: one fog Density per preset, the lifted night, the neutral golden grade, the moon, the sweep overrides,
-- Technology = Future in the file and the client's runtime base-material overrides.
return function(t)
	local H = t.H
	local fs = require("@lune/fs")
	local serde = require("@lune/serde")
	H.setMode("server")
	local Look = H.require("src/shared/Config/Look")
	local L = H.require("src/server/Systems/LightingService")
	local Color3 = H.roblox.Color3

	local function lum(c)
		return 0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3]
	end
	local function chroma(c)
		return math.max(c[1], c[2], c[3]) - math.min(c[1], c[2], c[3])
	end
	-- the two night skies: `night` (evening hold, before the midnight jump) and `nightLate` (morning hold, after it)
	local function isNight(sky)
		return sky == "night" or sky == "nightLate"
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
			t.ok(a.density >= 0.1 and a.density <= Look.Caps.densityMax, name .. " density " .. a.density)
			t.ok(a.haze <= Look.Caps.hazeMax, name .. " haze " .. a.haze)
			t.ok(a.offset >= 0.1, name .. " offset")
			-- haze colour: never purple (blue AND red well above green) and never saturated orange/teal
			local c = a.color
			t.ok(not (c[3] > c[2] + 12 and c[1] > c[2] + 4), name .. " atmosphere is purple")
			t.ok(chroma(c) <= 52, name .. " atmosphere too saturated: " .. chroma(c))
			-- a restrained grade; only the night grade is a clear blue tint (it cancels the engine's reddish-brown
			-- cast on the held night sky, job 0009)
			local minTint = if name == "night" then 200 else 225
			for _, ch in p.colorCorrection.tint do
				t.ok(ch >= minTint, name .. " tint channel below " .. minTint)
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

	t.test("presets: one fog Density per preset, low enough for a readable skyline (job 0009)", function()
		local D = Look.AtmosphereDensity
		for name, p in Look.Presets do
			t.ok(type(D[name]) == "number", "Look.AtmosphereDensity." .. name)
			t.eq(p.atmosphere.density, D[name], name .. " reads its Density from Look.AtmosphereDensity")
		end
		for name in D do
			t.ok(Look.Presets[name] ~= nil, "AtmosphereDensity names a preset: " .. name)
		end
		-- job 0009: at 0.27 the far haze was a flat grey wall beyond ~400 studs and hid downtown (city ~3 km); the
		-- sunlit presets now sit in the 0.12-0.2 band job 0011 sweeps
		for _, name in { "day", "goldenMorning", "goldenEvening" } do
			t.ok(D[name] >= 0.12 and D[name] <= 0.2, name .. " Density in 0.12-0.2: " .. D[name])
		end
		t.ok(D.night <= D.day, "night fog no denser than day (far city lights read through it)")
		t.near(L.lookAt(12).atmosphere.density, D.day, 1e-9, "noon = day Density (no scaling by default)")
		t.eq(Look.Tuning.densityScale, 1)
	end)

	t.test("presets: day Atmosphere locked at Offset 0.25 / Haze 0.8 (lab round 2 S1)", function()
		local lock = Look.AtmosphereLock
		t.eq(lock.offset, 0.25, "Offset locked (no visible effect at Density 0.27)")
		t.eq(lock.haze, 0.8, "Haze locked (best pair with Offset 0.25)")
		t.eq(Look.Tuning.offset, nil, "no global Offset tuning on top of the lock")
		local a = Look.Presets.day.atmosphere
		t.eq(a.offset, lock.offset, "day Offset")
		t.eq(a.haze, lock.haze, "day Haze")
		-- lookAt holds the lock over the whole day plateau (first day key .. last day key)
		local from, to
		for _, k in Look.Keys do
			if k.preset == "day" then
				from = from or k.hour
				to = k.hour
			end
		end
		t.ok(from ~= nil and to > from, "a day plateau")
		for h = from, to, 0.05 do
			local at = L.lookAt(h).atmosphere
			t.near(at.offset, lock.offset, 1e-9, "Offset at " .. h)
			t.near(at.haze, lock.haze, 1e-9, "Haze at " .. h)
		end
		-- no swap haze bump on top any more
		for _, e in Look.SkySchedule do
			t.ok(L.lookAt(e.hour).atmosphere.haze <= lock.haze + 1e-9, "no haze bump at the swap at " .. e.hour)
		end
	end)

	t.test("presets: golden hour Atmosphere is a clear, warm long view (job 0018 row 13: no grey haze wall)", function()
		local day = Look.Presets.day.atmosphere
		local G = Look.GoldenAtmosphere
		-- job 0018's g13 (17.6, low SW aerial): Density 0.18 + Haze 0.8 + a dull (126, 126, 134) Decay read as a grey
		-- wall facing away from the low sun
		local oldDecay = { 126, 126, 134 }
		for _, name in { "goldenMorning", "goldenEvening" } do
			local a = Look.Presets[name].atmosphere
			t.ok(a.density < day.density, name .. " thinner fog than noon: " .. a.density)
			t.ok(a.density >= 0.1 and a.density <= 0.14, name .. " Density in job 0011's crisp-but-gentle band")
			t.eq(a.haze, G.haze, name .. " Haze from Look.GoldenAtmosphere")
			t.eq(a.offset, G.offset, name .. " Offset from Look.GoldenAtmosphere")
			t.ok(a.haze < day.haze, name .. " thinner horizon band than noon")
			t.ok(a.haze >= 0.3, name .. " keeps some Haze (Glare needs it)")
			t.ok(a.offset >= day.offset, name .. " far towers silhouette, not fade")
			t.ok(a.glare >= 0.6 and a.glare > day.glare, name .. " a warm glow round the low sun: " .. a.glare)
			-- toward the sun: a light warm cream, still short of job 0009's sepia (234, 212, 184), chroma 50
			t.ok(a.color[1] > a.color[3], name .. " haze toward the sun is warm")
			t.ok(lum(a.color) >= 190, name .. " haze toward the sun is light")
			t.ok(chroma(a.color) <= 40, name .. " haze not sepia, chroma " .. chroma(a.color))
			-- away from the sun: a light rose-grey, never the old dull grey-blue
			t.ok(a.decay[1] >= a.decay[3], name .. " decay is not blue-grey")
			t.ok(chroma(a.decay) <= 16, name .. " decay near-neutral")
			t.ok(lum(a.decay) > lum(oldDecay) + 8, name .. " decay lighter than job 0018's smog wall")
		end
		-- the vibe audit's shot at 17.6 gets that look (between the golden and blue-hour keys)
		local a = L.lookAt(17.6).atmosphere
		t.ok(a.density <= 0.14, "17.6 Density " .. a.density)
		t.ok(a.haze <= 0.6, "17.6 Haze " .. a.haze)
		t.ok(a.glare >= 0.6, "17.6 Glare " .. a.glare)
		-- the other presets are untouched by the golden tuning
		t.eq(Look.Presets.day.atmosphere.density, 0.16, "day Density unchanged")
		t.eq(Look.Presets.night.atmosphere.density, Look.AtmosphereDensity.night, "night Density unchanged")
	end)

	t.test("presets: the held night is lifted ~2 stops (job 0009), still clearly night, cool; no purple fog", function()
		local day, night = Look.Presets.day, Look.Presets.night
		-- job 0009: Exposure -0.3 / Brightness 0.4 / OutdoorAmbient (40, 46, 60) at the held -3 deg engine sun was
		-- nearly black (overview completely black); Exposure +2 / Brightness 2 showed a readable city. The engine
		-- darkens that world itself, so the night preset LIFTS it (report: Brightness ~1.2, Exposure +0.6..+1.0)
		t.ok(night.exposure >= 0.6 and night.exposure <= 1.0, "night exposure lifted: " .. night.exposure)
		t.ok(night.brightness >= 1.0 and night.brightness <= 1.5, "moonlight-level key: " .. night.brightness)
		local oldOutdoor = { 40, 46, 60 }
		t.ok(lum(night.outdoorAmbient) >= 1.3 * lum(oldOutdoor), "OutdoorAmbient lifted over job 0009's")
		local lift = (night.exposure + 0.3) + math.log(lum(night.outdoorAmbient) / lum(oldOutdoor), 2)
		t.ok(lift >= 1.5 and lift <= 2.5, "ambient-lit surfaces ~2 stops brighter than job 0009: " .. lift)
		-- ... and still clearly night
		t.ok(night.brightness <= 0.5 * day.brightness, "a faint key light")
		t.ok(lum(night.outdoorAmbient) < 0.65 * lum(day.outdoorAmbient), "dark OutdoorAmbient")
		t.ok(lum(night.ambient) < 1.5 * lum(day.ambient), "dark Ambient")
		t.ok(night.outdoorAmbient[3] > night.outdoorAmbient[1], "cool ambient")
		t.ok(night.colorCorrection.saturation < 0, "night grade desaturated ...")
		t.ok(night.colorCorrection.saturation >= -0.3, "... only moderately")
		-- the engine tints the held night sky reddish-brown (job 0009): a clear blue night grade cancels it
		local tint = night.colorCorrection.tint
		local cool = tint[3] - tint[1]
		t.ok(cool >= 30 and cool <= 60, "clear blue night tint, B - R = " .. cool)
		t.ok(tint[2] > tint[1] and tint[3] >= tint[2], "tint ordered R < G <= B")
		t.ok(night.atmosphere.haze < day.atmosphere.haze, "thin night haze keeps the night HDRI visible")
		t.ok(night.bloom.threshold >= 1.2, "night bloom threshold: lit windows do not bloom into slabs")
		-- blue hour sits between golden and night and is never darker than the night (same held engine sun)
		for _, name in { "blueMorning", "blueEvening" } do
			local p = Look.Presets[name]
			t.ok(math.abs(p.exposure - night.exposure) <= 0.5, name .. " exposure near the night's")
			t.ok(p.exposure > day.exposure, name .. " lifted like the night")
			-- job 0018: at +0.6 the dusk sky rendered darker than the night sky (the engine's sky ceiling scales with
			-- exposure), so its warm-to-blue gradient could not read; the twilight sky needs at least the night's EV
			t.ok(p.exposure >= night.exposure, name .. " sky never darker than the night's: EV " .. p.exposure)
			t.ok(lum(p.outdoorAmbient) > 1.2 * lum(night.outdoorAmbient), name .. " brighter ambient than night")
			t.ok(p.brightness > night.brightness, name .. " key light above night")
			t.ok(p.brightness < Look.Presets.goldenEvening.brightness, name .. " key light below golden")
		end
		-- twilight / night fog, decay and cloud colours: never magenta (red above green), only slightly blue
		for _, name in { "blueMorning", "blueEvening", "night" } do
			local p = Look.Presets[name]
			for label, c in { color = p.atmosphere.color, decay = p.atmosphere.decay, clouds = p.clouds.color } do
				t.ok(c[1] <= c[2], name .. " " .. label .. " has a magenta / purple cast")
				t.ok(c[3] - c[2] <= 16, name .. " " .. label .. " is too blue")
				t.ok(chroma(c) <= 24, name .. " " .. label .. " is too saturated")
			end
		end
		-- exposure over the whole cycle (incl. the swap / jump dips) stays a moderate grade
		local minExp, maxExp = math.huge, -math.huge
		for s = 0, L.CYCLE_SECONDS, 5 do
			local e = L.lookAt(L.hourAt(s)).exposure
			minExp = math.min(minExp, e)
			maxExp = math.max(maxExp, e)
		end
		t.ok(minExp >= -1, "deepest exposure " .. minExp)
		t.ok(maxExp <= 1.2, "highest exposure " .. maxExp)
	end)

	t.test("presets: golden hour warm-but-neutral, no sepia (job 0009)", function()
		local day = Look.Presets.day
		local dayWarmth = day.colorCorrection.tint[1] - day.colorCorrection.tint[3]
		for _, name in { "goldenMorning", "goldenEvening" } do
			local p = Look.Presets[name]
			local c = p.atmosphere.color
			-- job 0009: (234, 212, 184) haze (chroma 50) + (255, 244, 230) tint + saturation 0.07 read sepia / brown.
			-- Since job 0018 the haze is a light warm cream again, but thinner (Look.GoldenAtmosphere) and short of it
			t.ok(chroma(c) <= 40, name .. " haze short of sepia, chroma " .. chroma(c))
			t.ok(c[1] >= c[3], name .. " haze leans warm, not blue")
			local tint = p.colorCorrection.tint
			local warmth = tint[1] - tint[3]
			t.ok(warmth <= 16, name .. " faint warm tint, R - B = " .. warmth)
			t.ok(warmth >= dayWarmth, name .. " at least as warm as noon")
			t.ok(p.colorCorrection.saturation <= 0.02, name .. " no saturation boost")
			t.ok(chroma(p.outdoorAmbient) <= 16, name .. " ambient near-neutral")
		end
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
		-- no big jumps between consecutive env steps (incl. the swap / jump exposure dips), caps hold everywhere
		local prev = L.lookAt(L.hourAt(0))
		for s = Look.Cycle.envInterval, L.CYCLE_SECONDS, Look.Cycle.envInterval do
			local cur = L.lookAt(L.hourAt(s))
			t.ok(math.abs(cur.brightness - prev.brightness) < 0.15, "brightness step at " .. s)
			t.ok(math.abs(cur.exposure - prev.exposure) < 0.05, "exposure step at " .. s)
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

	t.test("NightFactor: continuous over the whole game cycle (decoupled from the engine clock jump)", function()
		-- per real second of the 24-minute cycle, NightFactor (game hour) never steps
		local prev = L.nightFactorAt(L.hourAt(0))
		local maxStep = 0
		for s = 1, L.CYCLE_SECONDS do
			local f = L.nightFactorAt(L.hourAt(s))
			maxStep = math.max(maxStep, math.abs(f - prev))
			prev = f
		end
		t.ok(maxStep < 0.03, "NightFactor per-second step " .. maxStep)
		-- across the engine-clock jump it stays at full night on both sides, although Lighting.ClockTime jumps from
		-- the evening to the morning horizon (computed from the engine clock it would be ~0.2 / ~0.9 instead)
		local j = Look.EngineClock.jumpHour
		t.eq(L.nightFactorAt(j - 0.01), 1, "full night before the jump")
		t.eq(L.nightFactorAt(j + 0.01), 1, "full night after the jump")
		t.ok(L.nightFactorAt(L.engineClockAt(j - 0.01)) < 0.5, "(NightFactor of the engine clock would be wrong)")
		-- street lights are on (NightFactor >= lightsOn) whenever the game says night, all night long
		for h = Look.Night.duskFull, Look.Night.duskFull + 9.4, 0.1 do
			t.eq(L.nightFactorAt(h), 1, "full night at game hour " .. h % 24)
		end
	end)

	-- Engine clock (lab round 2) ---------------------------------------------------------------------------------------
	t.test("engine clock: the game hour by day, held near the horizon at night, one invisible jump", function()
		local E = Look.EngineClock
		-- the lab rule: hold ~18.0-18.3 for the first half of the night, ~5.7-6.0 for the second
		t.ok(E.eveningHold >= 18.0 and E.eveningHold <= 18.3, "evening hold " .. E.eveningHold)
		t.ok(E.morningHold >= 5.7 and E.morningHold <= 6.0, "morning hold " .. E.morningHold)
		local holdEve, holdMorn = L.sunElevationAt(E.eveningHold), L.sunElevationAt(E.morningHold)
		t.ok(holdEve < 0 and holdEve > E.minElevation, "evening hold just below the horizon: " .. holdEve)
		t.ok(holdMorn < 0 and holdMorn > E.minElevation, "morning hold just below the horizon: " .. holdMorn)
		t.ok(E.minElevation > -10, "the threshold stays above the lab's near-black -10 deg")
		-- by day the engine IS the game clock
		for h = E.morningHold + E.ease / 2, E.eveningHold - E.ease / 2, 0.05 do
			t.near(L.engineClockAt(h), h, 1e-9, "engine = game at " .. h)
		end
		t.near(L.engineClockAt(Look.Cycle.startHour), Look.Cycle.startHour, 1e-9, "servers start on the game clock")
		t.near(L.engineClockAt(12), 12, 1e-9)
		-- the holds
		t.near(L.engineClockAt(21), E.eveningHold, 1e-9, "first half of the night: evening hold")
		t.near(L.engineClockAt(E.jumpHour - 0.001), E.eveningHold, 1e-9)
		t.near(L.engineClockAt(E.jumpHour), E.morningHold, 1e-9, "second half: morning hold")
		t.near(L.engineClockAt(3), E.morningHold, 1e-9)
		t.near(L.engineClockAt(24), L.engineClockAt(0), 1e-9, "wraps")
		-- C1 easing: full speed where the ease starts, (almost) stopped where the hold starts -> no visible halt
		local eve0, eve1 = E.eveningHold - E.ease / 2, E.eveningHold + E.ease / 2
		local morn0, morn1 = E.morningHold - E.ease / 2, E.morningHold + E.ease / 2
		local eps = 0.001
		t.near((L.engineClockAt(eve0 + eps) - L.engineClockAt(eve0)) / eps, 1, 0.01, "slope 1 entering the ease")
		t.near((L.engineClockAt(eve1) - L.engineClockAt(eve1 - eps)) / eps, 0, 0.01, "slope 0 reaching the hold")
		t.near((L.engineClockAt(morn0 + eps) - L.engineClockAt(morn0)) / eps, 0, 0.01, "slope 0 leaving the hold")
		t.near((L.engineClockAt(morn1) - L.engineClockAt(morn1 - eps)) / eps, 1, 0.01, "slope 1 back on the game clock")
		-- the jump sits inside the night hold, in full night
		t.ok((E.jumpHour - eve1) % 24 > 0 and (morn0 - E.jumpHour) % 24 > 0, "jumpHour inside the night hold")
		-- what the engine renders, tick by tick (Look.Cycle.clockInterval) over a whole cycle
		local dtTick = Look.Cycle.clockInterval
		local prevGame = L.hourAt(0)
		local prev = L.engineClockAt(prevGame)
		local jumps, minEl = 0, math.huge
		for s = dtTick, L.CYCLE_SECONDS, dtTick do
			local g = L.hourAt(s)
			local e = L.engineClockAt(g)
			local el = L.sunElevationAt(e)
			minEl = math.min(minEl, el)
			t.ok(el >= E.minElevation, "engine sun " .. el .. " deg below the threshold at game " .. g)
			local dGame = (g - prevGame) % 24
			local dEngine = (e - prev) % 24
			if dEngine > dGame + 1e-9 then
				-- the jump: ONE write between the two holds (no deep-night ClockTime is ever rendered), in full
				-- night, under the exposure dip, while no sun-following sky is up to spin
				jumps += 1
				t.near(prev, E.eveningHold, 1e-9, "jumps from the evening hold")
				t.near(e, E.morningHold, 1e-9, "... straight to the morning hold")
				t.eq(L.nightFactorAt(prevGame), 1, "full night before the jump")
				t.eq(L.nightFactorAt(g), 1, "full night after the jump")
				t.ok(L.swapDipAt(g) >= 0.9 * Look.SkySwap.exposureDip, "the jump is under the exposure dip")
				t.eq(Look.Skies[L.skyAt(g)].followSun, false, "a fixed sky is up at the jump")
			else
				t.ok(dEngine <= dGame + 1e-9, "the engine clock never outruns the game clock at " .. g)
			end
			prevGame, prev = g, e
		end
		t.eq(jumps, 1, "exactly one jump per cycle")
		t.ok(minEl > -4, "deepest engine sun of the cycle ~-3 deg: " .. minEl)
		-- whenever the game says lights on, the engine sun is down (and the lamps make sense)
		for h = 0, 23.95, 0.05 do
			if L.nightFactorAt(h) >= Look.Night.lightsOn then
				t.ok(L.sunElevationAt(L.engineClockAt(h)) < 0, "lights on with the engine sun up at " .. h)
			end
		end
	end)

	-- Sky schedule -----------------------------------------------------------------------------------------------------
	t.test("sky schedule: sorted, every sky exists, right sky at the right game hour, wraps", function()
		local sched = Look.SkySchedule
		for i = 2, #sched do
			t.ok(sched[i - 1].hour < sched[i].hour, "schedule sorted")
		end
		for _, e in sched do
			t.ok(Look.Skies[e.sky] ~= nil, "schedule names a generated sky: " .. e.sky)
		end
		t.eq(L.skyAt(12), "day")
		t.eq(L.skyAt(17.3), "day", "golden hour: golden light under the day sky")
		t.eq(L.skyAt(7), "day")
		t.eq(L.skyAt(18.8), "blue")
		t.eq(L.skyAt(5.3), "dawn", "its own dawn sky (warm on the east side)")
		t.eq(L.skyAt(19.6), "night")
		t.eq(L.skyAt(23), "night")
		t.eq(L.skyAt(23.99), "night", "the evening-hold night until the jump")
		t.eq(L.skyAt(0), "nightLate", "the late night from the jump on")
		t.eq(L.skyAt(1), "nightLate", "wraps over midnight")
		t.eq(L.skyAt(4.99), "nightLate")
		t.eq(L.skyAt(Look.EngineClock.jumpHour - 0.01), "night", "night before the jump")
		t.eq(L.skyAt(Look.EngineClock.jumpHour + 0.01), "nightLate", "nightLate after the jump")
		t.eq(L.skyAt(sched[1].hour - 0.01), sched[#sched].sky, "before the first entry = the last sky")
		t.eq(L.skyAt(24), L.skyAt(0), "24 wraps to 0")
		local afterNoon
		for _, e in sched do
			if e.hour > 12 and afterNoon == nil then
				afterNoon = e
			end
		end
		local dt, nextSky = L.nextSkySwap(12)
		t.near(dt, afterNoon.hour - 12, 1e-9)
		t.eq(nextSky, "blue")
		local dt2, nextSky2 = L.nextSkySwap(23)
		t.near(dt2, sched[1].hour + 1, 1e-9, "next swap wraps")
		t.eq(nextSky2, sched[1].sky)
	end)

	t.test("sky swaps: few, never day <-> golden, engine sun below the horizon, under an exposure dip", function()
		local sched = Look.SkySchedule
		t.ok(#sched <= 5, "at most five swaps a day (was six; the fifth is the hidden one at the jump)")
		for _, e in sched do
			local before = L.skyAt(e.hour - 0.01)
			local pair = before .. ">" .. e.sky
			t.ok(before ~= e.sky, "a real swap at " .. e.hour)
			-- lab round 2 S3: day <-> golden pops visibly and cannot be hidden with the sun up
			t.ok(pair ~= "day>golden" and pair ~= "golden>day", "no day <-> golden swap")
			-- every swap with the ENGINE sun below the horizon (what the engine renders, not the game hour)
			local el = L.sunElevationAt(L.engineClockAt(e.hour))
			t.ok(el <= -1 and el >= Look.EngineClock.minElevation, pair .. " engine sun " .. el .. " at the swap")
			if isNight(before) or isNight(e.sky) then
				t.ok(L.nightFactorAt(e.hour) >= 0.9, pair .. " swaps in the dark")
			end
			-- masked: the swap's own exposure dip (or the default) at the swap, a short gentle one
			local depth = e.dip or Look.SkySwap.exposureDip
			t.near(L.swapDipAt(e.hour), depth, 1e-6, "exposure dip at " .. pair)
			t.ok(depth >= Look.SkySwap.exposureDip and depth <= 0.5, pair .. " dip depth " .. depth)
			-- twilight <-> night changes the most (the sun-side glow goes): a deeper dip than day <-> twilight
			local twilightNight = isNight(before) ~= isNight(e.sky)
			if twilightNight then
				t.ok(depth > Look.SkySwap.exposureDip, pair .. " gets a deeper dip")
			end
		end
		t.ok(L.swapDipAt(12) < 1e-6, "no dip at noon")
		t.ok(L.swapDipAt(Look.EngineClock.jumpHour) >= Look.SkySwap.exposureDip - 1e-9, "the engine jump is masked too")
		-- the dips are short: gone 3 widths away from every swap and the jump
		local marks = { Look.EngineClock.jumpHour }
		for _, e in sched do
			table.insert(marks, e.hour)
		end
		for h = 0, 23.95, 0.05 do
			local near = math.huge
			for _, m in marks do
				local d = math.abs(h - m)
				near = math.min(near, d, 24 - d)
			end
			if near > 3 * Look.SkySwap.width then
				t.ok(L.swapDipAt(h) < 0.01, "no dip away from the swaps at " .. h)
			end
		end
		-- the sky over the cycle
		for h = 0, 23.95, 0.05 do
			local sky = L.skyAt(h)
			local el = L.sunElevationAt(L.engineClockAt(h))
			t.ok(sky ~= "golden", "golden is not scheduled at " .. h)
			if sky == "day" then
				t.ok(el >= -2, "day sky only around a risen engine sun at " .. h .. " (" .. el .. ")")
			elseif sky == "blue" or sky == "dawn" then
				t.ok(el < 0, sky .. " sky only with the engine sun down at " .. h)
				t.ok(L.nightFactorAt(h) > 0, sky .. " sky only at twilight at " .. h)
				t.eq(sky == "dawn", h < 12, "dawn in the morning, blue (dusk) in the evening at " .. h)
				t.eq(Look.Skies[sky].followSun, true, sky .. " glow follows the engine sun")
			elseif isNight(sky) then
				t.ok(L.nightFactorAt(h) >= 0.9, sky .. " sky only in the dark at " .. h)
				t.ok(el < 0, sky .. " sky with the engine sun down at " .. h)
				t.eq(Look.Skies[sky].followSun, false, sky .. " parks its city glow (does not follow the sun)")
			end
		end
		-- the golden faces are still generated (Look.Skies), just not scheduled
		t.ok(Look.Skies.golden ~= nil, "golden sky kept in the generated data")
	end)

	t.test("swap dip: per-entry depth, a gaussian around each swap, overlapping dips never add up", function()
		local S = Look.SkySwap
		local deep
		for _, e in Look.SkySchedule do
			if e.dip then
				deep = e
			end
		end
		t.ok(deep ~= nil, "at least one swap has its own (deeper) dip")
		t.near(L.swapDipAt(deep.hour), deep.dip, 1e-9, "full depth at the swap")
		t.near(L.swapDipAt(deep.hour + S.width), deep.dip * math.exp(-1), 1e-9, "1/e one width away")
		t.near(L.swapDipAt(deep.hour - S.width), L.swapDipAt(deep.hour + S.width), 1e-9, "symmetric")
		t.near(L.swapDipAt(deep.hour + 24), L.swapDipAt(deep.hour), 1e-9, "game hours wrap")
		-- the deepest of all dips anywhere, never a sum
		local maxDepth = S.exposureDip
		for _, e in Look.SkySchedule do
			maxDepth = math.max(maxDepth, e.dip or S.exposureDip)
		end
		for h = 0, 23.99, 0.01 do
			t.ok(L.swapDipAt(h) <= maxDepth + 1e-9, "dips never add up at " .. h)
		end
		-- the dip lands in the look's exposure (and nowhere else)
		local h = deep.hour
		local lookAt = L.lookAt(h)
		local keys = Look.Keys
		local a, b = keys[1], keys[#keys]
		for i = 1, #keys - 1 do
			if h >= keys[i].hour and h <= keys[i + 1].hour then
				a, b = keys[i], keys[i + 1]
			end
		end
		local t0 = (h - a.hour) / (b.hour - a.hour)
		t0 = t0 * t0 * (3 - 2 * t0)
		local undipped = Look.Presets[a.preset].exposure
			+ (Look.Presets[b.preset].exposure - Look.Presets[a.preset].exposure) * t0
		t.near(lookAt.exposure, undipped - deep.dip, 1e-6, "exposure dipped by the swap's depth")
	end)

	t.test("skyFor: a valid SkyOverride wins, anything else falls back to the schedule", function()
		for _, h in { 1, 5.3, 12, 18.8, 23 } do
			t.eq(L.skyFor(h, nil), L.skyAt(h), "no override at " .. h)
			t.eq(L.skyFor(h, "golden"), "golden", "a generated sky, even an unscheduled one, at " .. h)
			t.eq(L.skyFor(h, "night"), "night")
			t.eq(L.skyFor(h, "noSuchSky"), L.skyAt(h), "unknown name ignored at " .. h)
			t.eq(L.skyFor(h, 3), L.skyAt(h), "wrong type ignored")
			t.eq(L.skyFor(h, true), L.skyAt(h), "wrong type ignored")
		end
		t.ok(L.OVERRIDE_ATTRIBUTES.SkyOverride ~= nil, "documented with the other lab overrides")
	end)

	t.test("night skies: each under its own engine hold, night -> nightLate in the jump's tick", function()
		local E = Look.EngineClock
		-- every scheduled night hour: the night sky built for the hold the engine is actually at
		for h = 0, 23.95, 0.05 do
			local sky = L.skyAt(h)
			if sky == "night" then
				t.near(L.engineClockAt(h), E.eveningHold, 1e-9, "night under the evening hold at " .. h)
			elseif sky == "nightLate" then
				t.near(L.engineClockAt(h), E.morningHold, 1e-9, "nightLate under the morning hold at " .. h)
			end
		end
		-- tick by tick over a whole cycle (Look.Cycle.clockInterval): the engine-clock jump and the night -> nightLate
		-- swap happen in the SAME tick (one exposure dip hides both), and the night skies never swap without the jump
		local dtTick = Look.Cycle.clockInterval
		local prevGame = L.hourAt(0)
		local prevClock, prevSky = L.engineClockAt(prevGame), L.skyAt(prevGame)
		local jumps, nightSwaps = 0, 0
		for s = dtTick, L.CYCLE_SECONDS, dtTick do
			local g = L.hourAt(s)
			local clock, sky = L.engineClockAt(g), L.skyAt(g)
			local jumped = (clock - prevClock) % 24 > (g - prevGame) % 24 + 1e-9
			local swapped = prevSky ~= sky and isNight(prevSky) and isNight(sky)
			if jumped then
				jumps += 1
				t.eq(prevSky, "night", "the evening-hold sky up before the jump")
				t.eq(sky, "nightLate", "the morning-hold sky up after the jump, same tick")
				t.ok(L.swapDipAt(g) >= 0.25, "jump + swap under a dip: " .. L.swapDipAt(g))
			end
			if swapped then
				nightSwaps += 1
				t.ok(jumped, "night <-> nightLate only together with the clock jump (game " .. g .. ")")
			end
			prevGame, prevClock, prevSky = g, clock, sky
		end
		t.eq(jumps, 1, "one jump per cycle")
		t.eq(nightSwaps, 1, "one night -> nightLate swap per cycle")
		-- the late night reads as the same night, slightly deeper: same flags as the night sky
		local n, nl = Look.Skies.night, Look.Skies.nightLate
		t.eq(nl.followSun, n.followSun, "nightLate parks its glow like the night")
		t.eq(nl.horizonGlowAzimuth, n.horizonGlowAzimuth, "the city glow stays on the same (inland) side")
		t.eq(nl.celestialBodiesShown, false, "no engine moon over the late night either")
	end)

	t.test("procedural skies: built for the exposure, grade and engine hold they are scheduled under", function()
		-- tools/look/procedural_sky.py pre-compensates each face for ONE render state (assets/sky/skies.json grading).
		-- Change a twilight / night preset or the schedule without rebuilding (and re-uploading) and the sky drifts
		-- from its target colours (Config/Look presets note)
		local meta = serde.decode("json", fs.readFile("assets/sky/skies.json")).skies
		local n = 0
		for name, s in meta do
			local g = s.grading
			if g and g.reference_hour ~= nil then
				n += 1
				local look = L.lookAt(g.reference_hour)
				t.near(look.exposure, g.exposure, 0.01, name .. " built for the current exposure")
				for i = 1, 3 do
					t.near(look.colorCorrection.tint[i], g.grade.tint[i], 0.6, name .. " built for the current tint")
				end
				t.near(look.colorCorrection.saturation, g.grade.saturation, 0.002, name .. " saturation")
				t.near(look.colorCorrection.contrast, g.grade.contrast, 0.002, name .. " contrast")
				t.eq(L.skyAt(g.reference_hour), name, name .. " is the scheduled sky at its reference hour")
				-- over its whole scheduled window the engine sits on (or, at the twilight edges, eases to) its hold
				local clock = g.reference_clocks[1]
				for h = 0, 23.95, 0.05 do
					if L.skyAt(h) == name then
						local tol = if isNight(name) then 1e-9 else 0.15
						t.near(L.engineClockAt(h), clock, tol, name .. " under its reference clock at " .. h)
					end
				end
				t.eq(Look.Skies[name].starCount, s.starCount, name .. " generated data matches skies.json")
			end
		end
		t.eq(n, 4, "four procedural skies: night, nightLate, blue, dawn")
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
		local sched = Look.SkySchedule
		local blueMid
		for i, e in sched do
			if e.sky == "blue" and e.hour > 12 then
				blueMid = (e.hour + sched[i % #sched + 1].hour) / 2
			end
		end
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
		-- simulate the day sky from its swap to the next swap at the clock rate, under the ENGINE sun
		local def = Look.Skies.day
		local dtTick = Look.Cycle.clockInterval
		local rate = Look.SkyStyle.maxYawRate
		local sched = Look.SkySchedule
		local dayFrom, dayTo
		for i, e in sched do
			if e.sky == "day" then
				dayFrom, dayTo = e.hour, sched[i % #sched + 1].hour
			end
		end
		local t0 = L.timeForHour(dayFrom)
		local x, _, z = L.sunDirectionAt(L.engineClockAt(L.hourAt(t0)))
		local cur = L.skyYaw(def.glowAzimuth, x, z)
		local maxStep, maxTargetStep = 0, 0
		local prevTarget = cur
		local tEnd = L.timeForHour(dayTo)
		local s = t0
		while s < tEnd do
			s += dtTick
			local sx, _, sz = L.sunDirectionAt(L.engineClockAt(L.hourAt(s)))
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
				t.ok(p.level >= 0 and p.level < 1, "level in 0..1")
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
		-- dim (lab round 2 S6): Neon only on small cells and only at colour x <= 0.4; bigger parts never Neon
		t.ok(W.brightness[2] <= 0.4, "Neon window brightness <= 0.4 (was 0.55-1.0: glowing slabs)")
		t.ok(W.facadeMaterial ~= "Neon", "facade-sized parts are never lit as Neon")
		t.ok(W.maxNeonArea >= 6 * 12 and W.maxNeonArea < 200, "a window cell fits, a facade band does not")
		t.eq(L.largestFaceArea(H.roblox.Vector3.new(6, 12, 0.5)), 72)
		t.eq(L.largestFaceArea(H.roblox.Vector3.new(1, 12, 40)), 480)
	end)

	t.test("windowEmissive: dim lit-window helper + config for the building package", function()
		local E = Look.Night.windowEmissive
		local W = Look.Windows
		t.ok(E.material == "SmoothPlastic" or E.material == "Glass", "recommended cell material is not Neon")
		t.ok(E.neonFactor[1] >= 0.25 - 1e-9 and E.neonFactor[2] <= 0.4 + 1e-9, "Neon only at lab S6's 0.25-0.4")
		t.ok(E.factor[1] < E.factor[2] and E.factor[2] <= 1, "factor range")
		t.ok(E.litFraction >= 0.3 and E.litFraction <= 0.5, "lab S6: ~35 % lit reads fine")
		t.near(E.warmShare, 0.7, 1e-9, "70 / 30 warm / cool reads correctly (lab S6)")
		t.ok(E.fadeIn[1] > 0 and E.fadeIn[2] <= 1 and E.fadeIn[1] < E.fadeIn[2], "fades in over dusk")
		-- the LitWindow system uses the same pick, share, colours and dim factors
		t.eq(W.share, E.litFraction)
		t.eq(W.warmShare, E.warmShare)
		t.eq(W.brightness, E.neonFactor)
		t.eq(W.facadeMaterial, E.material)
		t.eq(W.maxNeonArea, E.maxNeonArea)
		-- the helper over a facade grid of cells
		local dayColor = Color3.fromRGB(40, 48, 56)
		local black = Color3.new(0, 0, 0)
		local n, lit, warm = 0, 0, 0
		local sample
		for i = 0, 39 do
			for j = 0, 29 do
				local x, y, z = 52.5 + i * 6, 8 + j * 12, 311
				local isLit, cDay = L.windowEmissiveColor(x, y, z, 0, dayColor)
				local isLit2, cNight = L.windowEmissiveColor(x, y, z, 1, dayColor)
				local _, cMid = L.windowEmissiveColor(x, y, z, (E.fadeIn[1] + E.fadeIn[2]) / 2, dayColor)
				n += 1
				t.eq(isLit, isLit2, "lit is per cell, not per NightFactor")
				t.eq(isLit, L.windowParams(x, y, z).lit, "same pick as the LitWindow system")
				t.eq(cDay, dayColor, "every cell shows its day colour by day")
				if isLit then
					lit += 1
					t.ok(cNight ~= dayColor, "a lit cell changes at night")
					local p = L.windowParams(x, y, z)
					local k = E.factor[1] + (E.factor[2] - E.factor[1]) * p.level
					local base = if p.warm then E.warm else E.cool
					t.near(cNight.R, base[1] / 255 * k, 1e-6, "night colour = warm/cool x factor (R)")
					t.near(cNight.B, base[3] / 255 * k, 1e-6, "night colour = warm/cool x factor (B)")
					-- faded in by NightFactor: half way it sits between the day and the night colour
					t.ok(math.abs(cMid.R - dayColor.R) < math.abs(cNight.R - dayColor.R) + 1e-9, "fade (R)")
					if p.warm then
						warm += 1
						sample = sample or { x, y, z }
					end
				else
					t.eq(cNight, dayColor, "an unlit cell keeps its day colour at night")
				end
			end
		end
		t.near(lit / n, E.litFraction, 0.04, "lit share of cells")
		t.near(warm / lit, E.warmShare, 0.06, "warm share among lit cells")
		-- default day colour is black; Neon gets the dim range
		local x, y, z = sample[1], sample[2], sample[3]
		local _, soft = L.windowEmissiveColor(x, y, z, 1)
		local _, neon = L.windowEmissiveColor(x, y, z, 1, nil, "Neon")
		local _, dark = L.windowEmissiveColor(x, y, z, 0)
		t.eq(dark, black, "no day colour: black by day")
		t.ok(neon.R < soft.R, "Neon cells are dimmer than SmoothPlastic / Glass cells")
		t.ok(math.max(neon.R, neon.G, neon.B) <= E.neonFactor[2] + 1e-6, "a Neon cell stays at colour x <= 0.4")
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
		t.eq(Look.SkyStyle.yawSign, 1, "yawSign +1 is engine-verified (lab round 2 S0: yaw 0 shows Ft, 90 shows Lf)")
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

	-- Moon (job 0009: a big moon disc on the golden-hour horizon) ----------------------------------------------------
	t.test("moon: small, hidden while the engine sun is up, shown only at twilight", function()
		local S = Look.SkyStyle
		t.ok(S.moonAngularSize > 0 and S.moonAngularSize <= 2, "small moon: " .. S.moonAngularSize)
		t.eq(L.moonSizeAt(60), 0, "noon: hidden")
		t.eq(L.moonSizeAt(5.9), 0, "golden hour (engine 17.6): hidden")
		t.eq(L.moonSizeAt(0), 0, "sunset: hidden")
		t.eq(L.moonSizeAt(-3), S.moonAngularSize, "held twilight sun: shown")
		-- over the game cycle: never with the sun up, never under the day sky
		local shown = 0
		for h = 0, 23.95, 0.05 do
			local el = L.sunElevationAt(L.engineClockAt(h))
			local size = L.moonSizeAt(el)
			if size > 0 then
				shown += 1
				t.ok(el < 0, "moon with the engine sun up at " .. h)
				t.ok(L.skyAt(h) ~= "day", "moon under the day sky at " .. h)
			end
		end
		t.ok(shown > 0, "the moon still shows at twilight")
	end)

	-- Sweep overrides (studio job 0011) --------------------------------------------------------------------------------
	t.test("withOverrides: each attribute replaces one look value, wrong types ignored, none = unchanged", function()
		local base = L.lookAt(12)
		local plain = L.withOverrides(L.lookAt(12), function()
			return nil
		end)
		t.eq(plain.exposure, base.exposure)
		t.eq(plain.atmosphere.density, base.atmosphere.density)
		t.eq(plain.colorCorrection.tint[1], base.colorCorrection.tint[1])
		local attrs = {
			AtmosphereDensityOverride = 0.12,
			AtmosphereHazeOverride = 0.6,
			AtmosphereGlareOverride = 0.9,
			AtmosphereColorOverride = Color3.fromRGB(230, 210, 190),
			AtmosphereDecayOverride = Color3.fromRGB(150, 140, 140),
			ExposureOverride = 1.25,
			BrightnessOverride = 2.2,
			OutdoorAmbientOverride = Color3.fromRGB(10, 20, 30),
			TintOverride = Color3.fromRGB(200, 220, 255),
			SaturationOverride = -0.3,
		}
		local o = L.withOverrides(L.lookAt(22), function(n)
			return attrs[n]
		end)
		t.near(o.atmosphere.density, 0.12, 1e-9)
		t.near(o.atmosphere.haze, 0.6, 1e-9)
		t.near(o.atmosphere.glare, 0.9, 1e-9, "glare (job 0012 golden sweep)")
		t.near(o.atmosphere.color[1], 230, 1e-3, "atmosphere colour")
		t.near(o.atmosphere.decay[3], 140, 1e-3, "atmosphere decay")
		t.near(o.exposure, 1.25, 1e-9, "exposure replaced (no swap dip on top)")
		t.near(o.brightness, 2.2, 1e-9)
		t.near(o.outdoorAmbient[2], 20, 1e-3)
		t.near(o.colorCorrection.tint[1], 200, 1e-3)
		t.near(o.colorCorrection.tint[3], 255, 1e-3)
		t.near(o.colorCorrection.saturation, -0.3, 1e-9)
		t.near(o.atmosphere.offset, L.lookAt(22).atmosphere.offset, 1e-9, "untouched values stay")
		local wrong = L.withOverrides(L.lookAt(12), function(n)
			return if n == "ExposureOverride" then "2" elseif n == "TintOverride" then 5 else nil
		end)
		t.eq(wrong.exposure, base.exposure, "a string is ignored")
		t.eq(wrong.colorCorrection.tint[1], base.colorCorrection.tint[1], "a number for a Color3 is ignored")
		local documented = 0
		for name, what in L.OVERRIDE_ATTRIBUTES do
			documented += 1
			t.ok(name:match("Override$") ~= nil and type(what) == "string", "documented override " .. name)
		end
		t.ok(documented >= 8, "sweep overrides documented: " .. documented)
		t.eq(L.OVERRIDE_ATTRIBUTES.AtmosphereDensityOverride ~= nil, true)
		t.eq(L.OVERRIDE_ATTRIBUTES.ExposureOverride ~= nil, true)
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
		for _, sky in { "day", "golden", "blue", "night", "nightLate", "dawn" } do
			local s = Look.Skies[sky]
			t.ok(s ~= nil, "sky " .. sky)
			for _, f in { "Bk", "Dn", "Ft", "Lf", "Rt", "Up" } do
				t.ok(s.faces[f]:match("^rbxassetid://%d+$"), sky .. " face " .. f)
			end
			t.ok(type(s.glowAzimuth) == "number", sky .. " glow azimuth")
			t.ok(type(s.horizonGlowAzimuth) == "number", sky .. " horizon glow azimuth")
			t.ok(type(s.celestialBodiesShown) == "boolean", sky .. " celestial flag")
		end
		-- the procedural skies paint their own (pre-compensated) stars: the engine's would come out red-brown at the held
		-- clock; no engine moon over the night sky (it would sit on the -3 deg sun's antipode all night)
		for _, sky in { "night", "nightLate", "blue", "dawn" } do
			t.eq(Look.Skies[sky].starCount, 0, "no engine stars on " .. sky)
		end
		t.eq(Look.Skies.night.celestialBodiesShown, false, "no engine moon disc over the night sky")
		t.eq(Look.Skies.nightLate.celestialBodiesShown, false, "... nor over the late night")
		-- the four procedural skies share one Dn face (one texture to load)
		t.eq(Look.Skies.night.faces.Dn, Look.Skies.blue.faces.Dn, "shared Dn")
		t.eq(Look.Skies.night.faces.Dn, Look.Skies.dawn.faces.Dn, "shared Dn")
		t.eq(Look.Skies.night.faces.Dn, Look.Skies.nightLate.faces.Dn, "shared Dn")
		-- ... and nothing else: each has its own five faces (job 0012 must see which one is up)
		for _, f in { "Bk", "Ft", "Lf", "Rt", "Up" } do
			t.ok(Look.Skies.night.faces[f] ~= Look.Skies.nightLate.faces[f], "night / nightLate own " .. f)
		end
		t.eq(Look.Skies.dawn.clouds, 0)
		t.eq(Look.Skies.blue.clouds, 0)
		t.eq(Look.Skies.nightLate.clouds, 0)
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

	t.test("place file Lighting: Technology Future + Realistic + quality, day preset + day sky baked in", function()
		local lt = tree.Lighting
		local p = lt["$properties"]
		-- the engine derives LightingStyle from the legacy Technology when a place loads: without it a real server
		-- read Soft although the file said Realistic (jobs 0007 / 0009)
		t.eq(p.Technology, "Future", "legacy Technology = Future (maps to Realistic + quality on load)")
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
		-- the place file's Atmosphere is only the edit-mode / first-frame value: LightingService.init writes the preset
		t.near(a.Density, day.atmosphere.density, 1e-6, "place-file Density = Look.AtmosphereDensity.day")
		t.near(a.Offset, day.atmosphere.offset, 1e-6)
		t.near(a.Haze, day.atmosphere.haze, 1e-6, "place-file day Haze = the locked preset")
		t.eq(lt.Bloom["$className"], "BloomEffect")
		t.eq(lt.ColorCorrection["$className"], "ColorCorrectionEffect")
		t.eq(lt.SunRays["$className"], "SunRaysEffect")
		local sky = lt.Sky["$properties"]
		for _, f in { "Bk", "Dn", "Ft", "Lf", "Rt", "Up" } do
			t.eq(sky["Skybox" .. f], Look.Skies.day.faces[f], "default sky = day sky " .. f)
		end
		t.eq(sky.SunAngularSize, Look.SkyStyle.sunAngularSize)
		t.eq(sky.MoonAngularSize, L.moonSizeAt(L.sunElevationAt(Look.Cycle.startHour)), "moon as at the start hour")
		t.eq(sky.MoonAngularSize, 0, "no moon in the daylight the place starts in")
		t.eq(sky.StarCount, Look.Skies.day.starCount)
		t.eq(sky.CelestialBodiesShown, Look.Skies.day.celestialBodiesShown)
		t.eq(p.GeographicLatitude, Look.Sun.latitude, "the measured sun model's latitude")
	end)

	-- Client sky preload -----------------------------------------------------------------------------------------------
	t.test("LookClient: preloads every scheduled sky face, the sky that comes up next first", function()
		H.setMode("client")
		local LookClient = H.require("src/client/Controllers/LookClient")
		H.setMode("server")
		local scheduled, nScheduled = {}, 0
		for _, e in Look.SkySchedule do
			if not scheduled[e.sky] then
				scheduled[e.sky] = true
				nScheduled += 1
			end
		end
		local order = LookClient.skyOrder("day")
		t.eq(order[1], "blue", "after day comes blue (dusk)")
		t.eq(order[#order], "day", "the sky already on screen goes last")
		local seen = {}
		for _, name in order do
			t.ok(not seen[name], "no duplicates: " .. name)
			seen[name] = true
		end
		for name in Look.Skies do
			t.eq(seen[name] == true, scheduled[name] == true, "preloaded iff scheduled: " .. name)
		end
		t.eq(seen.golden, nil, "the unscheduled golden sky is not preloaded")
		local ids = LookClient.skyAssetList("night")
		local unique, nUnique = {}, 0
		for name in scheduled do
			for _, f in { "Bk", "Dn", "Ft", "Lf", "Rt", "Up" } do
				local id = Look.Skies[name].faces[f]
				if not unique[id] then
					unique[id] = true
					nUnique += 1
				end
			end
		end
		t.ok(nUnique < 6 * nScheduled, "some faces are shared (the procedural skies' Dn)")
		t.eq(#ids, nUnique, "every distinct scheduled face once")
		local listed = {}
		for _, id in ids do
			t.ok(not listed[id], "listed once: " .. id)
			listed[id] = true
			t.ok(unique[id], "a scheduled sky's face")
		end
		t.eq(LookClient.skyOrder("night")[1], "nightLate", "after night comes nightLate (midnight)")
		t.eq(ids[1], Look.Skies.nightLate.faces.Bk, "night -> nightLate first")
		-- the shared Dn is fetched with the first sky that needs it, not again with the night sky at the end
		local dnAt
		for i, id in ids do
			if id == Look.Skies.dawn.faces.Dn then
				dnAt = i
			end
		end
		t.ok(dnAt ~= nil and dnAt <= 6, "shared Dn with the first sky: " .. tostring(dnAt))
		t.eq(#LookClient.skyOrder(nil), nScheduled, "unknown current sky: every scheduled sky")
		local fromGolden = LookClient.skyOrder("golden")
		t.eq(fromGolden[#fromGolden], "golden", "a sky already on screen goes last even if unscheduled")
	end)

	-- Base-material overrides on the client (job 0009: the file's <Material>Name properties are not honoured) ----------
	t.test("LookClient.init: every base-material override applied, a late variant on arrival", function()
		H.setMode("client")
		local LookClient = H.require("src/client/Controllers/LookClient")
		local MO = H.require("src/shared/Util/MaterialOverrides")
		H.setMode("server")
		local MS = H.game:GetService("MaterialService")
		local Enum = H.roblox.Enum
		-- a fresh client: nothing overridden (the engine reads back the stock names)
		table.clear(H.materialOverrides)
		t.eq(MS:GetBaseMaterialOverride(Enum.Material.Asphalt), "Asphalt", "stock name before (job 0009)")
		LookClient.init()
		local n = 0
		for base, variant in Look.Overrides do
			n += 1
			t.eq(MS:GetBaseMaterialOverride(Enum.Material[base]), variant, "client override " .. base)
		end
		t.ok(n >= 16, "every override: " .. n)
		t.eq(MS:GetAttribute(MO.ATTRIBUTE), n, "published count")
		t.eq(#LookClient.pendingOverrides(), 0, "nothing pending")
		-- idempotent: a second pass writes nothing
		local r = LookClient.applyMaterialOverrides()
		t.eq(#r.set, 0, "no rewrite")
		t.eq(#r.already, n, "all already active")
		-- a variant that has not replicated yet: pending, then applied on MaterialService.ChildAdded
		table.clear(H.materialOverrides)
		local sand = MS:FindFirstChild("HC_Sand")
		sand.Parent = nil
		local r2 = LookClient.applyMaterialOverrides()
		t.eq(#r2.missing, 1, "one missing")
		t.eq(LookClient.pendingOverrides()[1], "Sand -> HC_Sand")
		t.eq(MS:GetBaseMaterialOverride(Enum.Material.Sand), "Sand", "not pointed at a missing variant")
		t.eq(MS:GetBaseMaterialOverride(Enum.Material.Asphalt), "HC_Asphalt", "the others applied")
		sand.Parent = MS
		LookClient._onMaterialAdded(sand)
		t.eq(MS:GetBaseMaterialOverride(Enum.Material.Sand), "HC_Sand", "late variant applied")
		t.eq(#LookClient.pendingOverrides(), 0)
		t.eq(MS:GetAttribute(MO.ATTRIBUTE), n)
	end)
end
