--!nocheck
-- C3 audio (PLAN): the pure audio modules (Shared/Audio: EngineModel, EngineClass, Ambience, Mix, RadioDial, Siren),
-- Config/Sounds shape and its audit coverage (docs/v2/evidence/audio_audit.json), AudioService's RadioTune validation,
-- and SoundController / Hotwire / Radio helpers that run headless.
local fs = require("@lune/fs")
local serde = require("@lune/serde")

return function(t)
	local H = t.H
	local Vector3 = H.roblox.Vector3
	local Instance = H.roblox.Instance

	H.setMode("client")
	local EngineModel = H.require("src/shared/Audio/EngineModel")
	local EngineClass = H.require("src/shared/Audio/EngineClass")
	local Ambience = H.require("src/shared/Audio/Ambience")
	local Mix = H.require("src/shared/Audio/Mix")
	local RadioDial = H.require("src/shared/Audio/RadioDial")
	local Siren = H.require("src/shared/Audio/Siren")
	local Sounds = H.require("src/shared/Config/Sounds")
	local VFX = H.require("src/shared/Config/VFX")
	local Cars = H.require("src/shared/Config/Cars")

	-- deterministic random source
	local function seq(values)
		local i = 0
		return function()
			i = i % #values + 1
			return values[i]
		end
	end

	---------------------------------------------------------------------------------------------------------------
	-- EngineModel
	---------------------------------------------------------------------------------------------------------------

	t.test("EngineModel: shift points match the backfire VFX gearbox; a profile + 3 layers per engine set", function()
		t.eq(#EngineModel.SHIFTS, #VFX.GEAR_SHIFTS)
		for i, s in VFX.GEAR_SHIFTS do
			t.eq(EngineModel.SHIFTS[i], s, "shift " .. i)
		end
		for _, set in EngineClass.SETS do
			local p = EngineModel.PROFILES[set]
			t.ok(p ~= nil, set .. " profile")
			t.ok(p.idleRpm < p.shiftRpm and p.shiftRpm <= p.redline, set .. " rpm order")
			local keys = EngineClass.keysFor(set)
			for _, k in { keys.idle, keys.on, keys.off } do
				local def = Sounds[k]
				t.ok(def ~= nil, k .. " in Config/Sounds")
				t.eq(def.looped, true, k .. " loops")
			end
		end
		t.eq(EngineModel.profileFor("nope"), EngineModel.PROFILES.sedan, "unknown -> sedan")
	end)

	t.test("EngineModel.gearFor: up at a shift point, down only past the hysteresis", function()
		local S = EngineModel.SHIFTS
		t.eq(EngineModel.gearFor(0, 0.1, S), 0)
		t.eq(EngineModel.gearFor(0, 0.23, S), 1)
		t.eq(EngineModel.gearFor(0, 0.9, S), 4, "straight to the right gear")
		t.eq(EngineModel.gearFor(1, 0.20, S), 1, "inside the hysteresis band: hold")
		t.eq(EngineModel.gearFor(1, 0.17, S), 0, "below the band: down")
		t.eq(EngineModel.gearFor(4, 0.1, S), 3, "one gear down per step")
	end)

	t.test("EngineModel.step: upshift = shifted, dip, pop on a pops car; dip gain < 1 mid-shift", function()
		local p = EngineModel.PROFILES.muscle
		local st = EngineModel.newState(p)
		local frac = 0
		local upshifts, pops = 0, 0
		local minGain = 1
		for _ = 1, 600 do
			frac = math.min(1, frac + 0.004)
			EngineModel.step(st, p, 1 / 60, frac, 1, true, false)
			if st.shifted == 1 then
				upshifts += 1
			end
			if st.pop then
				pops += 1
			end
			minGain = math.min(minGain, EngineModel.dipGain(st, p))
		end
		t.eq(upshifts, 4, "four upshifts through the box")
		t.ok(pops >= 4, "muscle pops on upshifts under throttle")
		t.ok(minGain < 0.8, "volume dips during a shift")
		t.ok(st.rpm <= p.redline + 1e-6, "never past the redline")
		-- a sedan never pops
		local q = EngineModel.PROFILES.sedan
		local s2 = EngineModel.newState(q)
		local any = false
		for i = 1, 400 do
			EngineModel.step(s2, q, 1 / 60, math.min(1, i * 0.003), 1, true, false)
			any = any or s2.pop
		end
		t.eq(any, false, "no pops on a sedan")
	end)

	t.test("EngineModel.step: revs at a standstill when held, falls back to idle when released", function()
		local p = EngineModel.PROFILES.sports
		local st = EngineModel.newState(p)
		for _ = 1, 120 do
			EngineModel.step(st, p, 1 / 60, 0, 1, true, true)
		end
		t.eq(st.free, true, "held at a standstill = free revving")
		t.ok(st.rpm > p.redline * 0.85, "revs up toward the redline")
		local bounced = false
		for _ = 1, 120 do
			EngineModel.step(st, p, 1 / 60, 0, 1, true, true)
			bounced = bounced or st.limiter
		end
		t.ok(bounced, "bounces off the limiter")
		for _ = 1, 240 do
			EngineModel.step(st, p, 1 / 60, 0, 0, true, true)
		end
		t.near(st.rpm, p.idleRpm, 60, "back to idle")
	end)

	t.test("EngineModel.mix: idle layer at idle, on-load under throttle, off-load coasting; reset in place", function()
		local p = EngineModel.PROFILES.sedan
		local st = EngineModel.newState(p)
		local m = EngineModel.newMix()
		EngineModel.mix(st, p, m)
		t.ok(m.idle > 0.9 and m.on < 0.05, "idle")
		st.rpm = p.idleRpm + (p.redline - p.idleRpm) * 0.6
		st.load = 1
		EngineModel.mix(st, p, m)
		t.ok(m.on > 0.9 and m.off < 0.05 and m.idle < 0.05, "on load")
		st.load = 0
		EngineModel.mix(st, p, m)
		t.ok(m.off > 0.5 and m.on < 0.05, "off load")
		t.ok(m.onPitch >= p.pitchMin and m.onPitch <= p.pitchMax, "pitch clamped")
		st.gear, st.dipT = 3, 0.1
		EngineModel.reset(st, p)
		t.eq(st.gear, 0)
		t.eq(st.dipT, 0)
		t.eq(st.rpm, p.idleRpm)
	end)

	t.test("EngineModel: throttle guess and the remote-engine LOD budget", function()
		t.eq(EngineModel.inferThrottle(0, 0.5, 1 / 30), 0, "stopped")
		t.ok(EngineModel.inferThrottle(40, 41, 1 / 30) > 0.9, "accelerating hard")
		t.ok(EngineModel.inferThrottle(40, 39, 1 / 30) < 0.35, "slowing")
		t.eq(EngineModel.lod(10), 3)
		t.eq(EngineModel.lod(EngineModel.FULL_RANGE), 3)
		t.eq(EngineModel.lod(EngineModel.FULL_RANGE + 1), 1)
		t.eq(EngineModel.lod(EngineModel.MAX_RANGE), 1)
		t.eq(EngineModel.lod(EngineModel.MAX_RANGE + 1), 0)
		t.ok(EngineModel.FULL_RANGE == 60 and EngineModel.MAX_RANGE == 250, "brief: 60 / ~250 studs")
	end)

	---------------------------------------------------------------------------------------------------------------
	-- EngineClass
	---------------------------------------------------------------------------------------------------------------

	t.test("EngineClass.resolve: attribute > police > class > style > sedan; read defensively", function()
		t.eq(EngineClass.resolve("super", "Loot", { class = "sedan" }), "super", "EngineClass attribute wins")
		t.eq(EngineClass.resolve("Truck", nil, nil), "truck", "case-insensitive")
		t.eq(EngineClass.resolve(42, nil, { style = "muscle" }), "muscle", "junk attribute ignored")
		t.eq(EngineClass.resolve(nil, "Police", { class = "sports" }), "police", "police kind")
		t.eq(EngineClass.resolve(nil, nil, { class = "police_suv" }), "police", "police class")
		t.eq(EngineClass.resolve(nil, nil, { class = "pickup", style = "sports" }), "truck", "class before style")
		t.eq(EngineClass.resolve(nil, nil, { style = "hyper" }), "super")
		t.eq(EngineClass.resolve(nil, nil, { class = "spaceship" }), "sedan", "unknown class -> sedan")
		t.eq(EngineClass.resolve(nil, nil, nil), "sedan", "no catalog entry -> sedan")
		-- every catalog car resolves to a known set
		for _, def in Cars.List do
			local set = EngineClass.resolve(nil, nil, def)
			t.ok(EngineModel.PROFILES[set] ~= nil, def.id .. " -> " .. set)
		end
	end)

	t.test("EngineClass: horns exist per set; engine eligibility by kind / driver", function()
		for _, set in EngineClass.SETS do
			local horn = EngineClass.hornFor(set)
			t.ok(Sounds[horn] ~= nil, set .. " horn " .. horn)
		end
		t.eq(EngineClass.isEngineEligible("Parked", true), false)
		t.eq(EngineClass.isEngineEligible("Traffic", false), true)
		t.eq(EngineClass.isEngineEligible("Loot", false), false)
		t.eq(EngineClass.isEngineEligible(nil, true), true)
	end)

	---------------------------------------------------------------------------------------------------------------
	-- Ambience
	---------------------------------------------------------------------------------------------------------------

	t.test("Ambience: every WorldLayout district has a bed; every bed has day + night loops", function()
		local WorldLayout = H.require("src/shared/Config/WorldLayout")
		local ids = {}
		for x = -6000, 6000, 400 do
			for z = -5000, 4800, 400 do
				ids[WorldLayout.districtAt(x, z)] = true
			end
		end
		for id in ids do
			t.ok(Ambience.DISTRICT_BEDS[id] ~= nil, "district " .. id .. " mapped to a bed")
		end
		for _, bed in Ambience.BEDS do
			local keys = Ambience.KEYS[bed]
			t.ok(Sounds[keys.day] and Sounds[keys.day].looped, keys.day)
			t.ok(Sounds[keys.night] and Sounds[keys.night].looped, keys.night)
		end
		t.ok(Sounds[Ambience.FREEWAY_KEY] ~= nil, "freeway loop")
		t.eq(Ambience.bedFor("beach"), "Beach")
		t.eq(Ambience.bedFor(nil), Ambience.DEFAULT_BED)
		t.eq(Ambience.bedFor("atlantis"), Ambience.DEFAULT_BED)
	end)

	t.test("Ambience: equal-power day / night, freeway level falls off with distance", function()
		for _, nf in { 0, 0.25, 0.5, 0.75, 1 } do
			local d, n = Ambience.dayNight(nf)
			t.near(d * d + n * n, 1, 1e-9, "equal power at " .. nf)
		end
		local d0, n0 = Ambience.dayNight(0)
		t.ok(d0 == 1 and n0 == 0)
		t.eq(Ambience.freewayLevel(0), 1)
		t.eq(Ambience.freewayLevel(Ambience.FREEWAY_FAR + 10), 0)
		t.ok(Ambience.freewayLevel(150) < Ambience.freewayLevel(80), "monotonic")
	end)

	t.test("Ambience: freeway segment grid finds the nearest centreline (and the real freeways)", function()
		local edges = {
			{ class = "freeway", points = { Vector3.new(0, 0, 0), Vector3.new(1000, 0, 0) } },
			{ class = "street", points = { Vector3.new(0, 0, 50), Vector3.new(1000, 0, 50) } },
		}
		local g = Ambience.buildSegments(edges, nil, 128)
		t.near(Ambience.nearestDistance(g, 500, 30, 300), 30, 1e-6, "perpendicular distance to the freeway only")
		t.near(Ambience.nearestDistance(g, -40, 0, 300), 40, 1e-6, "past the end: to the endpoint")
		t.eq(Ambience.nearestDistance(g, 500, 900, 300), math.huge, "beyond the search radius")
		local WorldLayout = H.require("src/shared/Config/WorldLayout")
		local real = Ambience.buildSegments(WorldLayout.Edges)
		t.ok(#real.ax > 10, "WorldLayout has freeway segments")
		local a = Vector3.new(real.ax[1], 0, real.az[1])
		t.ok(Ambience.nearestDistance(real, a.X, a.Z, 50) < 1, "a freeway point is on a freeway")
	end)

	t.test("Ambience one-shots: keys exist, bed + time rules, cooldowns and a global gap", function()
		for _, o in Ambience.ONESHOTS do
			for _, k in o.keys do
				t.ok(Sounds[k] ~= nil, "one-shot " .. k)
			end
			t.ok(o.gap[1] > 0 and o.gap[2] >= o.gap[1], "gap range")
		end
		local rand = seq({ 0.1, 0.5, 0.9, 0.3, 0.7 })
		local s = Ambience.newScheduler(0, rand)
		local got = {}
		local now = 0
		for _ = 1, 4000 do
			now += 0.5
			local key, dist = Ambience.pickOneShot(s, now, "Beach", false, rand)
			if key then
				table.insert(got, { key = key, at = now, dist = dist })
			end
		end
		t.ok(#got > 10, "beach one-shots happen")
		for i, g in got do
			t.ok(not g.key:find("Coyote") and not g.key:find("Dog") and not g.key:find("Clank"), "beach-only kinds")
			if i > 1 then
				t.ok(g.at - got[i - 1].at >= Ambience.GLOBAL_GAP - 1e-6, "global gap")
			end
		end
		-- night in the hills: coyotes allowed, gulls (day, beach) never
		local s2 = Ambience.newScheduler(0, rand)
		local coyote = false
		now = 0
		for _ = 1, 4000 do
			now += 0.5
			local key = Ambience.pickOneShot(s2, now, "Wild", true, rand)
			if key then
				t.ok(not key:find("Gull"), "no gulls in the hills at night")
				coyote = coyote or key == "Amb_Coyote"
			end
		end
		t.ok(coyote, "coyotes at night in the hills")
	end)

	---------------------------------------------------------------------------------------------------------------
	-- Mix
	---------------------------------------------------------------------------------------------------------------

	t.test("Mix: toggles, master x channel sliders x ducks", function()
		local vols = Mix.defaultVolumes()
		local on = { sfx = true, music = true }
		t.near(Mix.groupVolume("sfx", vols, on, {}), Mix.BASE.sfx, 1e-9)
		vols.master = 0.5
		vols.music = 0.5
		t.near(Mix.groupVolume("music", vols, on, {}), Mix.BASE.music * 0.25, 1e-9)
		t.eq(Mix.groupVolume("vehicles", vols, { sfx = false, music = true }, {}), 0, "sfx toggle gates vehicles")
		t.eq(Mix.groupVolume("ui", vols, { sfx = false, music = true }, {}), 0, "...and the interface")
		t.ok(Mix.groupVolume("music", vols, { sfx = false, music = true }, {}) > 0, "music has its own toggle")
		t.eq(Mix.groupVolume("music", vols, { sfx = true, music = false }, {}), 0)
		t.near(Mix.duckGain({ bigMessage = 1 }, "music"), Mix.DUCKS.bigMessage.music, 1e-9)
		t.near(Mix.duckGain({ bigMessage = 1, pause = 1 }, "music"), 0.2 * 0.35, 1e-9, "ducks multiply")
		t.near(Mix.duckGain({ pause = 0.5 }, "music"), 1 - 0.65 * 0.5, 1e-9, "half-faded duck")
		t.eq(Mix.duckGain({ gunfire = 1 }, "ui"), 1, "the interface is never ducked by gunfire")
		t.eq(Mix.duckGain({ pause = 1 }, "ui"), 1, "...or by the pause menu")
	end)

	t.test("Mix sliders: steps <-> volume, labels, clamped at the ends (no wrap)", function()
		t.eq(Mix.stepToVolume(1), 0)
		t.eq(Mix.stepToVolume(Mix.STEPS), 1)
		for i = 1, Mix.STEPS do
			t.eq(Mix.volumeToStep(Mix.stepToVolume(i)), i, "round trip " .. i)
		end
		local labels = Mix.stepLabels()
		t.eq(#labels, Mix.STEPS)
		t.eq(labels[1], "0%")
		t.eq(labels[Mix.STEPS], "100%")
		t.eq(Mix.sliderStep(Mix.STEPS, 1, Mix.STEPS), Mix.STEPS, "Right at 100 % stays")
		t.eq(Mix.sliderStep(1, Mix.STEPS, Mix.STEPS), 1, "Left at 0 % stays")
		t.eq(Mix.sliderStep(5, 6, Mix.STEPS), 6)
		t.eq(Mix.sliderStep(5, 4, Mix.STEPS), 4)
		local channels = {}
		for _, c in Mix.CHANNELS do
			channels[c] = true
		end
		for _, s in Mix.SLIDERS do
			t.ok(channels[s.channel], s.channel .. " is a mix channel")
			t.ok(#s.label > 0 and #s.desc > 0, s.channel .. " copy")
		end
		t.eq(#Mix.SLIDERS, 6, "master + 5 channels")
	end)

	t.test("Mix: voice cap admits, steals only lower priority", function()
		t.ok(Mix.MAX_VOICES >= 24 and Mix.MAX_VOICES <= 64, "a sane global cap")
		local ok, steal = Mix.admit(3, 40, 1, nil)
		t.ok(ok and not steal, "room")
		ok, steal = Mix.admit(40, 40, Mix.PRIORITY.ui, Mix.PRIORITY.ambient)
		t.ok(ok and steal, "full: UI steals an ambient voice")
		ok = Mix.admit(40, 40, Mix.PRIORITY.ambient, Mix.PRIORITY.ambient)
		t.eq(ok, false, "full: equal priority is refused")
	end)

	t.test("Mix: reverb by cover, impacts by crash size, squeal / wind / rumble / scrape levels", function()
		t.eq(Mix.reverbFor(0, 5, false, false), "NoReverb")
		t.eq(Mix.reverbFor(3, 5, false, false), "Alley", "under a deck")
		t.eq(Mix.reverbFor(5, 5, false, false), "ParkingLot", "roofed")
		t.eq(Mix.reverbFor(0, 5, false, true), "ParkingLot", "garage")
		t.eq(Mix.reverbFor(0, 5, true, false), "Hallway", "tunnel")
		for _, name in { "NoReverb", "Alley", "ParkingLot", "Hallway" } do
			t.ok(H.roblox.Enum.ReverbType[name] ~= nil, name .. " is a ReverbType")
		end
		local l, h, g = Mix.impactLayers(10)
		t.ok(not l and not h and not g, "a bump is silent")
		l, h, g = Mix.impactLayers(30)
		t.ok(l and not h and not g, "light thud")
		l, h, g = Mix.impactLayers(60)
		t.ok(not l and h and not g, "heavy crunch")
		local _, _, glass, gain = Mix.impactLayers(120)
		t.ok(glass and gain > 1, "glass on a big one, louder")
		t.eq(Mix.squealLevel(30, false, true), 0, "airborne")
		t.eq(Mix.squealLevel(6, true, false), 0, "grip")
		t.ok(Mix.squealLevel(6, true, true) > 0, "drifting squeals earlier")
		t.ok(Mix.squealLevel(30, true, false) > Mix.squealLevel(12, true, false), "more slip, more squeal")
		t.eq(Mix.windLevel(30, 100), 0)
		t.ok(Mix.windLevel(100, 100) >= 1)
		t.eq(Mix.rumbleLevel("Asphalt", 60), 0, "paved")
		t.eq(Mix.rumbleLevel("Sand", 2), 0, "stopped")
		t.ok(Mix.rumbleLevel("Sand", 60) > 0.5)
		for name in VFX.SurfaceDust do
			t.ok(Mix.RUMBLE[name] ~= nil, name .. ": dust VFX surface also rumbles")
		end
		t.eq(Mix.scrapeLevel(false, 50), 0)
		t.ok(Mix.scrapeLevel(true, 50) > 0.5)
	end)

	t.test("Mix.suddenDrop: crash detection for remote cars, decaying peak", function()
		local peak = 0
		local crashed
		crashed, _, peak = Mix.suddenDrop(peak, 80, 1 / 60)
		t.eq(crashed, false)
		t.eq(peak, 80)
		local drop
		crashed, drop, peak = Mix.suddenDrop(peak, 20, 1 / 60)
		t.ok(crashed and drop >= 50, "80 -> 20 in a frame is a crash")
		t.eq(peak, 20, "peak resets after a crash")
		crashed = Mix.suddenDrop(80, 60, 1)
		t.eq(crashed, false, "a slow brake over a second decays the peak instead")
	end)

	t.test("Mix.channelFor: keys land on the right channel", function()
		t.eq(Mix.channelFor("Click", false), "ui")
		t.eq(Mix.channelFor("Shot_Pistol", true), "sfx")
		t.eq(Mix.channelFor("Horn_Truck", true), "vehicles")
		t.eq(Mix.channelFor("Siren_Tone", true), "vehicles")
		t.eq(Mix.channelFor("Amb_Dog1", true), "ambience")
		t.eq(Mix.channelFor("Amb_Plane1", false), "ambience", "2D ambience stays ambience")
		t.eq(Mix.channelFor("Radio_Aura", false), "music")
		t.eq(Mix.channelFor("Impact_Heavy1", true), "sfx")
	end)

	---------------------------------------------------------------------------------------------------------------
	-- RadioDial
	---------------------------------------------------------------------------------------------------------------

	t.test("RadioDial: 4-6 stations from Config/Sounds with audited lengths; OFF on the dial", function()
		local stations = RadioDial.buildStations(Sounds)
		t.ok(#stations >= 4 and #stations <= 6, "station count " .. #stations)
		for _, st in stations do
			t.eq(#st.lengths, #st.tracks, st.name .. " lengths")
			for i, key in st.tracks do
				t.ok(type(Sounds[key].length) == "number", key .. " has an audited length")
				t.eq(st.lengths[i], Sounds[key].length)
			end
			t.ok(st.name:upper() == st.name, "station names are upper-case parodies")
		end
		local n = #stations
		t.eq(RadioDial.step(0, 1, n), 1, "unset -> first station")
		t.eq(RadioDial.step(n, 1, n), n + 1, "after the last station: OFF")
		t.ok(RadioDial.isOff(n + 1, n))
		t.eq(RadioDial.step(n + 1, 1, n), 1, "OFF -> wraps to the first")
		t.eq(RadioDial.step(1, -1, n), n + 1, "back from the first: OFF")
		t.eq(RadioDial.find(stations, stations[2].name), 2)
		t.eq(RadioDial.find(stations, "NOPE FM"), nil)
	end)

	t.test("RadioDial.trackAt: a shared live clock, deterministic, wraps, guards track ends", function()
		local lengths = { 100, 50, 30 }
		local i, off = RadioDial.trackAt(lengths, 10, 0)
		t.eq(i, 1)
		t.eq(off, 10)
		i, off = RadioDial.trackAt(lengths, 120, 0)
		t.eq(i, 2)
		t.eq(off, 20)
		i, off = RadioDial.trackAt(lengths, 180 + 5, 0)
		t.eq(i, 1, "wraps after the playlist")
		t.eq(off, 5)
		i, off = RadioDial.trackAt(lengths, 99.5, 0)
		t.eq(i, 2, "half a second from the end: the next track")
		t.eq(off, 0)
		i = RadioDial.trackAt(lengths, 179.5, 0)
		t.eq(i, 1, "...wrapping at the playlist end")
		local a1, b1 = RadioDial.trackAt(lengths, 1234.5, 77)
		local a2, b2 = RadioDial.trackAt(lengths, 1234.5, 77)
		t.ok(a1 == a2 and b1 == b2, "every client computes the same")
		t.eq(RadioDial.trackAt({}, 5, 0), 0, "empty station")
		t.ok(RadioDial.salt("NEON FM") ~= RadioDial.salt("CHILL WAVES"), "stations are offset from each other")
	end)

	t.test("RadioDial: police start on OFF, others random; memory per car with eviction", function()
		local n = 6
		t.eq(
			RadioDial.defaultFor(true, n, function()
				return 0.5
			end),
			n + 1
		)
		t.eq(
			RadioDial.defaultFor(false, n, function()
				return 0.999999
			end),
			n
		)
		t.eq(
			RadioDial.defaultFor(false, n, function()
				return 0
			end),
			1
		)
		local m = RadioDial.newMemory()
		RadioDial.remember(m, 101, 3)
		t.eq(
			RadioDial.startFor(m, 101, false, n, function()
				return 0
			end),
			3,
			"remembered"
		)
		t.eq(
			RadioDial.startFor(m, 202, true, n, function()
				return 0
			end),
			n + 1,
			"new police car: OFF"
		)
		for k = 1, RadioDial.MEMORY + 5 do
			RadioDial.remember(m, 1000 + k, 2)
		end
		t.eq(RadioDial.recall(m, 101), nil, "oldest forgotten")
		t.eq(RadioDial.recall(m, 1000 + RadioDial.MEMORY + 5), 2)
		t.eq(#m.order, RadioDial.MEMORY)
	end)

	---------------------------------------------------------------------------------------------------------------
	-- Siren
	---------------------------------------------------------------------------------------------------------------

	t.test("Siren: pattern sweeps stay in range, hi-lo is two-tone, machine switches with intensity", function()
		for _, pat in Siren.PATTERNS do
			for k = 0, 100 do
				local v = Siren.pitchAt(pat, k * 0.037)
				t.ok(v >= Siren.LOW - 1e-9 and v <= 1 + 1e-9, pat .. " in range")
			end
		end
		local seen = {}
		for k = 0, 40 do
			seen[Siren.pitchAt("hilo", k * 0.05)] = true
		end
		local count = 0
		for _ in seen do
			count += 1
		end
		t.eq(count, 2, "hi-lo has two tones")
		local w0, y0, h0 = Siren.weights(0)
		local w1, y1, h1 = Siren.weights(1)
		t.ok(w0 > y0 and w0 > h0, "cruising: mostly wail")
		t.ok(y1 + h1 > w1, "on the suspect: mostly yelp / hi-lo")
		local rand = seq({ 0.95, 0.2, 0.6, 0.05, 0.4 })
		local st = Siren.newState(rand)
		local patterns = {}
		for _ = 1, 3000 do
			patterns[Siren.step(st, 1 / 30, 1, rand)] = true
		end
		t.ok(patterns.wail and patterns.yelp and patterns.hilo, "all three patterns during a chase")
	end)

	t.test("Siren: Doppler, SirenMode / SirenOn attributes, wanted bed + dispatch timing", function()
		t.ok(Siren.doppler(60) > 1, "approaching: higher")
		t.ok(Siren.doppler(-60) < 1, "receding: lower")
		t.eq(Siren.doppler(0), 1)
		t.eq(Siren.doppler(100000), Siren.DOPPLER_MAX, "clamped")
		local closing =
			Siren.closingSpeed(Vector3.new(0, 0, 0), Vector3.new(50, 0, 0), Vector3.new(100, 0, 0), Vector3.zero)
		t.near(closing, 50, 1e-9)
		local known, pat = Siren.fromAttr("yelp")
		t.ok(known and pat == "yelp")
		known, pat = Siren.fromAttr("lights")
		t.ok(known and pat == nil, "lights only: silent")
		known = Siren.fromAttr(nil)
		t.eq(known, false, "no attribute: the client machine decides")
		t.eq(Siren.isOn(nil, nil), true)
		t.eq(Siren.isOn(false, nil), false, "v1 Siren=false")
		t.eq(Siren.isOn(nil, false), false, "v2 SirenOn=false")
		t.eq(Siren.distantLevel(0, math.huge), 0, "not wanted: silent")
		t.ok(Siren.distantLevel(5, math.huge) > Siren.distantLevel(1, math.huge), "more stars, louder")
		t.ok(Siren.distantLevel(3, 30) < Siren.distantLevel(3, 400), "steps aside for close units")
		local lo1, hi5 = math.huge, 0
		for _, r in { 0, 0.5, 0.999 } do
			lo1 = math.min(
				lo1,
				Siren.dispatchGap(1, function()
					return r
				end)
			)
			hi5 = math.max(
				hi5,
				Siren.dispatchGap(5, function()
					return r
				end)
			)
		end
		t.ok(lo1 >= 8 and hi5 <= 10, "5 stars is busier than 1")
	end)

	---------------------------------------------------------------------------------------------------------------
	-- Config/Sounds + audit coverage
	---------------------------------------------------------------------------------------------------------------

	t.test("Config/Sounds: ids, volumes, regions inside sane bounds; dispatch keys are not voice clips", function()
		for key, def in Sounds do
			t.ok(type(def.id) == "string", key .. " id")
			t.ok(def.id:match("^rbxassetid://%d+$") or def.id:match("^rbxasset://"), key .. " id format")
			t.ok(def.volume > 0 and def.volume <= 6, key .. " volume (quiet takes compensated; Roblox max 10)")
			if def.loopStart or def.loopEnd then
				t.ok((def.loopStart or 0) < (def.loopEnd or math.huge), key .. " loop region")
				t.eq(def.looped, true, key .. " has a loop region and loops")
			end
			if def.start and def.stop then
				t.ok(def.start < def.stop, key .. " playback region")
			end
		end
		for _, key in { "PoliceRadio", "PoliceRadioFeed" } do
			local id = Sounds[key].id
			t.ok(id ~= "rbxassetid://9117744553" and id ~= "rbxassetid://9117748943", key .. ": no dispatcher voice")
		end
	end)

	t.test("audio_audit.json covers every Config/Sounds asset id with no hard failure", function()
		local raw = fs.readFile("docs/v2/evidence/audio_audit.json")
		local rows = serde.decode("json", raw)
		local audited = {}
		for _, row in rows do
			audited["rbxassetid://" .. tostring(math.floor(row.id))] = row
		end
		for key, def in Sounds do
			if def.id:match("^rbxassetid://") then
				local row = audited[def.id]
				t.ok(row ~= nil, key .. " (" .. def.id .. ") is in the audit: re-run tools/audio/audit.py")
				if row then
					t.eq(#(row.hard or {}), 0, key .. " has no hard audit failure")
				end
			end
		end
	end)

	---------------------------------------------------------------------------------------------------------------
	-- Runtime helpers that run headless
	---------------------------------------------------------------------------------------------------------------

	t.test("SoundController: preload = short one-shots only (audited durations); owns the local car's tyres", function()
		H.setMode("client")
		local SC = H.require("src/client/Controllers/SoundController")
		local ids = SC.preloadIds(Sounds)
		local seen = {}
		for _, id in ids do
			t.ok(not seen[id], "unique " .. id)
			seen[id] = true
		end
		local duration = {}
		for _, row in serde.decode("json", fs.readFile("docs/v2/evidence/audio_audit.json")) do
			duration["rbxassetid://" .. tostring(math.floor(row.id))] = row.info and row.info.duration
		end
		local total = 0
		for _, id in ids do
			local dur = duration[id]
			if dur then
				total += dur
				t.ok(dur <= 6, id .. " preloaded but " .. dur .. " s long")
			end
		end
		t.ok(total < 240, ("preload at join stays small: %.0f s of audio"):format(total))
		for key, def in Sounds do
			local streams = key:sub(1, 6) == "Radio_" or key:sub(1, 4) == "Amb_" or def.looped == true or def.stream
			t.eq(SC.isPreloaded(key, def), not streams, key .. (if streams then " streams" else " preloads"))
			if streams then
				local shared = false
				for k2, d2 in Sounds do
					if d2.id == def.id and SC.isPreloaded(k2, d2) then
						shared = true
					end
				end
				t.ok(shared or not seen[def.id], key .. " is not downloaded at join")
			end
		end
		for _, key in { "Shot_Pistol", "Impact_Heavy1", "Pop_Backfire1", "Click", "Wasted", "CarDoor" } do
			t.ok(seen[Sounds[key].id], key .. " preloaded")
		end
		for _, key in { "Eng_Sedan_On", "Amb_City_Day", "Siren_Tone", "Crash", "Radio_Aura" } do
			t.ok(not seen[Sounds[key].id], key .. " streams")
		end
		t.eq(SC.ownsLocalTyres, true)
		for _, fn in { "playImpact", "setVolume", "getVolume", "duck", "setMuffle", "playLoop", "stopLoop" } do
			t.eq(type(SC[fn]), "function", fn)
		end
	end)

	t.test("SoundController: volume sliders round-trip through the mix; RADIO OFF is on the dial", function()
		H.setMode("client")
		local SC = H.require("src/client/Controllers/SoundController")
		SC.setVolume("vehicles", 0.3)
		t.near(SC.getVolume("vehicles"), 0.3, 1e-9)
		SC.setVolume("master", 2)
		t.eq(SC.getVolume("master"), 1, "clamped")
		local names = SC.radioStations()
		for _ = 1, #names do
			SC.stepRadio(1)
		end
		t.eq(SC.getRadio(), names[#names])
		SC.stepRadio(1)
		local station, title, playing = SC.getRadio()
		t.eq(station, RadioDial.OFF_LABEL, "one past the last station: RADIO OFF")
		t.eq(title, nil)
		t.eq(playing, false)
		H.setMode("client")
	end)

	t.test("Radio.clockTrack: the station's track at a server time, inside the track", function()
		H.setMode("client")
		local Radio = H.require("src/client/Audio/Radio")
		local stations = Radio.stations()
		for i, st in stations do
			for _, tm in { 0, 1000, 123456.7 } do
				local key, offset = Radio.clockTrack(i, tm)
				t.ok(table.find(st.tracks, key) ~= nil, st.name .. " plays its own track")
				t.ok(offset >= 0 and offset < Sounds[key].length, "offset inside the track")
			end
		end
		t.eq(Radio.clockTrack(99, 0), nil, "no such station")
	end)

	t.test("Hotwire.isStealPrompt: the steal prompts, nothing else", function()
		H.setMode("client")
		local Hotwire = H.require("src/client/Audio/Hotwire")
		t.ok(Hotwire.isStealPrompt("StealPrompt", "Recover"))
		t.ok(Hotwire.isStealPrompt("Prompt", "Hotwire"))
		t.ok(Hotwire.isStealPrompt("X", "STEAL"))
		t.eq(Hotwire.isStealPrompt("Shop", "Gear Shop"), false)
		t.eq(Hotwire.isStealPrompt("HotDrop", "CLAIM HOT DROP"), false)
	end)

	---------------------------------------------------------------------------------------------------------------
	-- AudioService (server): RadioTune validation
	---------------------------------------------------------------------------------------------------------------

	t.test("AudioService: RadioTune only from the driver, only real stations; cleared when they leave", function()
		H.setMode("server")
		local AS = H.require("src/server/Systems/AudioService")
		local stations = RadioDial.buildStations(Sounds)
		t.eq(AS.validStation(""), true, "off")
		t.eq(AS.validStation(stations[1].name), true)
		t.eq(AS.validStation("FREE ROBUX FM"), false, "unknown station")
		t.eq(AS.validStation(42), false)
		t.eq(AS.validStation(string.rep("A", 40)), false, "too long")

		local players = Instance.new("Folder")
		local p = Instance.new("Player")
		p.Parent = players
		local holder = Instance.new("Folder")
		local model = Instance.new("Model")
		model.Parent = holder
		local driving = {}
		AS._setHooks({
			getDriving = function(pl)
				return driving[pl]
			end,
		})
		AS._onRadioTune(p, stations[2].name)
		t.eq(model:GetAttribute("RadioStation"), nil, "not driving: ignored")
		driving[p] = { model = model, driver = p, destroyed = false }
		AS._onRadioTune(p, "NOT A STATION")
		t.eq(model:GetAttribute("RadioStation"), nil, "bad station: ignored")
		AS._onRadioTune(p, stations[2].name)
		t.eq(model:GetAttribute("RadioStation"), stations[2].name, "the car carries the station")
		AS._onRadioTune(p, "")
		t.eq(model:GetAttribute("RadioStation"), nil, "radio off clears it")
		AS._onRadioTune(p, stations[1].name)
		driving[p] = nil
		AS._sweep()
		t.eq(model:GetAttribute("RadioStation"), nil, "left the car: cleared")
		AS._setHooks(nil)
		H.setMode("client")
	end)

	t.test("remotes: RadioTune registered once (client -> server)", function()
		local Remotes = H.require("src/shared/Remotes")
		local n = 0
		for _, name in Remotes.ClientToServer do
			if name == "RadioTune" then
				n += 1
			end
		end
		t.eq(n, 1)
	end)

	---------------------------------------------------------------------------------------------------------------
	-- C3 review fixes
	---------------------------------------------------------------------------------------------------------------

	local function auditRows()
		local byId = {}
		for _, row in serde.decode("json", fs.readFile("docs/v2/evidence/audio_audit.json")) do
			byId["rbxassetid://" .. tostring(math.floor(row.id))] = row
		end
		return byId
	end

	-- measured RMS of what a key plays (its region's when it has one), from the audit
	local function rmsOf(rows, key, def)
		local row = rows[def.id]
		local info = row and row.info
		if not info then
			return nil
		end
		local reg = info.regions and info.regions[key]
		return if reg and reg.region_rms_db then reg.region_rms_db else info.rms_db
	end

	t.test("loudness: beds, ambient one-shots and radio tracks sit at their target (audited RMS)", function()
		local rows = auditRows()
		local byStation = {}
		for key, def in Sounds do
			local normalised = key:sub(1, 4) == "Amb_" or key:sub(1, 6) == "Radio_"
			if normalised then
				t.ok(type(def.loudness) == "number", key .. " carries a loudness target")
			end
			if def.loudness then
				local rms = rmsOf(rows, key, def)
				t.ok(rms ~= nil, key .. " measured")
				if rms then
					local eff = rms + 20 * math.log10(def.volume)
					t.ok(
						math.abs(eff - def.loudness) <= 1.5,
						("%s effective %.1f dB vs %d"):format(key, eff, def.loudness)
					)
					if def.station then
						local s = byStation[def.station] or { lo = math.huge, hi = -math.huge }
						s.lo, s.hi = math.min(s.lo, eff), math.max(s.hi, eff)
						byStation[def.station] = s
					end
				end
			end
		end
		for name, s in byStation do
			t.ok(s.hi - s.lo <= 2, name .. ": tracks within 2 dB of each other")
		end
		-- beds and the freeway: the freeway cuts through, one-shots sit just under the bed
		t.ok(Sounds.Amb_Freeway.loudness > Sounds.Amb_City_Day.loudness, "freeway above the bed")
		t.ok(Sounds.Amb_Dog1.loudness <= Sounds.Amb_City_Day.loudness, "one-shots at or under the bed")
		-- door and key click on a level with the slam (no longer ~13 dB under it)
		local slam = rmsOf(rows, "DoorSlam", Sounds.DoorSlam) + 20 * math.log10(Sounds.DoorSlam.volume)
		local door = rmsOf(rows, "CarDoor", Sounds.CarDoor) + 20 * math.log10(Sounds.CarDoor.volume)
		t.ok(math.abs(door - slam) <= 3, ("door %.1f vs slam %.1f dB"):format(door, slam))
	end)

	t.test("audit: no SEAM or LEVEL flags; no unreviewed voice in any id; the night bed has no singing", function()
		local rows = auditRows()
		for key, def in Sounds do
			local row = rows[def.id]
			if row then
				for _, flag in row.flags or {} do
					t.ok(flag ~= "SEAM" and flag ~= "LEVEL", key .. ": " .. flag)
					t.ok(flag ~= "VOICE?", key .. ": a description mentions voices (content safety)")
				end
				if key:sub(1, 4) == "Amb_" and row.meta and row.meta.description then
					local text = string.lower(row.meta.description)
					for _, w in { "singing", "voices?", "walla", "talk%a*", "crowds?", "kids", "people" } do
						t.ok(not text:find("%f[%a]" .. w .. "%f[%A]"), key .. " description mentions " .. w)
					end
				end
			end
		end
		t.ok(Sounds.Amb_City_Night.id ~= "rbxassetid://9112759731", "the singing night bed is gone")
		t.ok(Sounds.TireScreech.id ~= "rbxassetid://9120398722", "the squeal is no longer a wet skid")
		t.eq(Sounds.Siren_Yelp, nil, "the unused yelp take is gone")
		local wildDay = rows[Sounds.Amb_Wild_Day.id]
		t.ok(wildDay and string.lower(wildDay.meta.description):find("wind", 1, true), "the hills day bed has wind")
	end)

	t.test("EngineModel: reverse stays in first gear (no shifts, pops or blow-offs), below the limiter", function()
		local p = EngineModel.PROFILES.sports
		local st = EngineModel.newState(p)
		local shifted, pops, blow, limiter = false, false, false, false
		for i = 1, 180 do
			local speed = math.min(45, i * 0.5)
			local frac = EngineModel.reverseFrac(speed, 45)
			t.ok(frac < EngineModel.SHIFTS[1], "below the first shift point")
			EngineModel.step(st, p, 1 / 60, frac, 1, true, false, true)
			shifted = shifted or st.shifted ~= 0
			pops = pops or st.pop
			blow = blow or st.blowoff
			limiter = limiter or st.limiter
		end
		t.eq(st.gear, 0)
		t.ok(not shifted and not pops and not blow and not limiter, "no gearbox events backing up")
		t.ok(st.rpm > p.idleRpm + (p.shiftRpm - p.idleRpm) * 0.8, "full reverse revs high in first")
		-- the same throttle going forwards runs through the box
		local fwd = EngineModel.newState(p)
		local up = false
		for i = 1, 180 do
			EngineModel.step(fwd, p, 1 / 60, math.min(1, i * 0.005), 1, true, false)
			up = up or fwd.shifted == 1
		end
		t.ok(up, "forwards still shifts")
	end)

	t.test("EngineModel: remote engines crossfade three layers into the dominant one over 50-75 studs", function()
		t.eq(EngineModel.farBlend(EngineModel.FAR_FROM), 0)
		t.eq(EngineModel.farBlend(EngineModel.FAR_TO), 1)
		local mid = EngineModel.farBlend((EngineModel.FAR_FROM + EngineModel.FAR_TO) / 2)
		t.ok(mid > 0.3 and mid < 0.7, "smooth in between")
		local m = { idle = 0.9, on = 0.1, off = 0.2, idlePitch = 1, onPitch = 0.55, offPitch = 0.55, gain = 1 }
		local i0, o0, f0 = EngineModel.remoteLayers(m, 0)
		t.ok(i0 == 0.9 and o0 == 0.1 and f0 == 0.2, "close: the full mix")
		local i1, o1, f1 = EngineModel.remoteLayers(m, 1)
		t.ok(i1 == 0.9 and o1 == 0 and f1 == 0, "far: an idling car stays on its idle take")
		m.idle, m.on, m.off = 0, 0.8, 0.3
		local _, on1, off1 = EngineModel.remoteLayers(m, 1)
		t.ok(on1 == 0.8 and off1 == 0, "far: a car on throttle keeps the on-load take")
		-- continuous across the blend: no level step at any distance
		local prev = nil
		for d = 40, 90 do
			local a, b, c = EngineModel.remoteLayers(m, EngineModel.farBlend(d))
			local total = a + b + c
			if prev then
				t.ok(math.abs(total - prev) < 0.05, "no jump at " .. d)
			end
			prev = total
		end
	end)

	t.test("Ambience: one-shots are quieter at the far end of their range; pickOneShot returns the gain", function()
		t.eq(Ambience.distanceGain(30, 30, 120), 1)
		t.near(Ambience.distanceGain(120, 30, 120), Ambience.FAR_GAIN, 1e-9)
		t.eq(Ambience.distanceGain(0, 0, 0), 1, "2D")
		local s = Ambience.newScheduler(0, seq({ 0.5 }))
		local key, dist, gain = Ambience.pickOneShot(s, 1000, "City", false, seq({ 0.1, 0.9, 0.3 }))
		t.ok(key ~= nil, "something is due")
		t.ok(gain >= Ambience.FAR_GAIN and gain <= 1, "gain in range")
		t.ok(dist >= 0, "distance")
	end)

	t.test("Mix: crash tiers, bump threshold, one crash heard once", function()
		local l, h = Mix.impactLayers(45)
		t.ok(l and not h, "a 40-55 crash is a thud, not a crunch")
		l, h = Mix.impactLayers(Mix.HEAVY_FROM)
		t.ok(not l and h, "heavy from HEAVY_FROM")
		t.ok(Mix.BUMP_DROP < Mix.CRASH_DROP, "bumps below VehicleClient's crash threshold")
		local bumped = Mix.suddenDrop(60, 35, 1 / 60, Mix.BUMP_DROP)
		t.eq(bumped, true, "a 25 drop is a bump")
		t.eq((Mix.suddenDrop(60, 35, 1 / 60)), false, "...but not a crash")
		local memo = Mix.newImpactMemo()
		local pos = Vector3.new(0, 0, 0)
		local a, b, c = Mix.dedupeImpact(memo, 10, pos, false, true, false)
		t.ok(not a and b and not c, "first report plays")
		a, b, c = Mix.dedupeImpact(memo, 10.1, pos + Vector3.new(5, 0, 0), false, true, false)
		t.ok(not a and not b and not c, "the rammed car's report of the same crash is silent")
		a, b, c = Mix.dedupeImpact(memo, 10.2, pos, false, true, true)
		t.ok(not b and c, "a bigger report adds only its glass")
		a, b = Mix.dedupeImpact(memo, 11, pos, false, true, false)
		t.ok(b, "a later crash plays again")
		a, b = Mix.dedupeImpact(memo, 11.1, pos + Vector3.new(100, 0, 0), false, true, false)
		t.ok(b, "a crash elsewhere plays")
	end)

	t.test("Mix: loops count against the cap, but one-shots always get MIN_ONESHOTS voices", function()
		local ok, steal = Mix.admit(Mix.MAX_VOICES, Mix.MAX_VOICES, Mix.PRIORITY.ui, nil, 2)
		t.ok(ok and not steal, "loops fill the cap: a UI click still plays")
		ok = Mix.admit(Mix.MAX_VOICES, Mix.MAX_VOICES, Mix.PRIORITY.ambient, Mix.PRIORITY.ambient, Mix.MIN_ONESHOTS)
		t.eq(ok, false, "full with enough one-shots: an equal priority is refused")
		ok, steal =
			Mix.admit(Mix.MAX_VOICES, Mix.MAX_VOICES, Mix.PRIORITY.gunshot, Mix.PRIORITY.ambient, Mix.MIN_ONESHOTS)
		t.ok(ok and steal, "a gunshot steals an ambient one-shot")
		t.ok(not Mix.SLIDERS[2].desc:lower():find("footstep", 1, true), "no footsteps promised")
	end)

	t.test("Groups: an untimed duck is a hold that an older timer cannot release", function()
		H.setMode("client")
		local Groups = H.require("src/client/Audio/Groups")
		Groups.duck("bigMessage", true) -- the death muffle
		Groups.duck("bigMessage", true, 0) -- the WASTED sting's timed duck, expiring at once
		Groups.step(1 / 60)
		t.eq(Groups.isDucked("bigMessage"), true, "still held during the death screen")
		Groups.duck("bigMessage", false)
		t.eq(Groups.isDucked("bigMessage"), false, "released on respawn")
		Groups.duck("retune", true, 0)
		Groups.step(1 / 60)
		t.eq(Groups.isDucked("retune"), false, "a timed duck alone releases itself")
	end)

	t.test("Hotwire.recent: false until a steal prompt triggers", function()
		H.setMode("client")
		local Hotwire = H.require("src/client/Audio/Hotwire")
		t.eq(Hotwire.recent(2.5), false)
	end)
end
