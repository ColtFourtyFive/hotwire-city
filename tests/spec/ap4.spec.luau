--!nocheck
-- AP4 (atmosphere, loading screen, radio, vehicle fx): Config/Sounds radio tracks, SoundController stations,
-- VehicleFx remotes + VehicleFxService relay, EffectsController boost expiry, VehicleClient radio placement,
-- LightingService look + cheap writes, and the ReplicatedFirst loading screen wiring.
return function(t)
	local H = t.H
	local fs = require("@lune/fs")
	local luau = require("@lune/luau")
	local serde = require("@lune/serde")
	local Instance = H.roblox.Instance

	-- Config/Sounds radio --------------------------------------------------------------------------------------------
	H.setMode("client")
	local Sounds = H.require("src/shared/Config/Sounds")
	local SoundController = H.require("src/client/Controllers/SoundController")

	t.test("radio tracks: 6-10 public music ids, one-shot, quiet, named station + title", function()
		local count = 0
		for key, def in Sounds do
			if key:sub(1, 6) == "Radio_" then
				count += 1
				t.ok(def.id:match("^rbxassetid://%d+$") ~= nil, key .. " id")
				t.eq(def.looped, false, key .. " not looped (the station queues the next track)")
				t.ok(def.volume > 0 and def.volume <= 0.4, key .. " low 2D volume")
				t.ok(type(def.station) == "string" and #def.station > 0, key .. " station")
				t.ok(type(def.title) == "string" and #def.title > 0, key .. " title")
			else
				t.eq(def.station, nil, key .. " is not a radio track")
			end
		end
		t.ok(count >= 6 and count <= 10, "radio track count " .. count)
	end)

	t.test("SoundController.buildStations groups Radio_* by station (sorted) and ignores the rest", function()
		local stations = SoundController.buildStations(Sounds)
		t.ok(#stations >= 4, "at least 4 stations")
		local seen = {}
		for i, st in stations do
			if i > 1 then
				t.ok(stations[i - 1].name < st.name, "stations sorted by name")
			end
			t.ok(#st.tracks >= 1, st.name .. " has tracks")
			for j, key in st.tracks do
				t.eq(Sounds[key].station, st.name, key .. " belongs to " .. st.name)
				if j > 1 then
					t.ok(st.tracks[j - 1] < key, "tracks sorted")
				end
				seen[key] = true
			end
		end
		for key in Sounds do
			t.eq(seen[key] == true, key:sub(1, 6) == "Radio_", "coverage of " .. key)
		end
		local custom = SoundController.buildStations({
			Radio_B = { id = "rbxassetid://2", volume = 0.3, station = "ZED" },
			Radio_A = { id = "rbxassetid://1", volume = 0.3, station = "ZED" },
			Radio_C = { id = "rbxassetid://3", volume = 0.3, station = "ALPHA" },
			Radio_NoStation = { id = "rbxassetid://4", volume = 0.3 },
			Horn = { id = "rbxassetid://5", volume = 0.3, station = "NOPE" },
		})
		t.eq(#custom, 2)
		t.eq(custom[1].name, "ALPHA")
		t.eq(custom[2].tracks[1], "Radio_A")
		t.eq(custom[2].tracks[2], "Radio_B")
	end)

	t.test("SoundController.stepIndex wraps both ways and starts at 1", function()
		t.eq(SoundController.stepIndex(1, 1, 5), 2)
		t.eq(SoundController.stepIndex(5, 1, 5), 1)
		t.eq(SoundController.stepIndex(1, -1, 5), 5)
		t.eq(SoundController.stepIndex(0, 1, 5), 1, "unset index")
		t.eq(SoundController.stepIndex(9, -1, 5), 1, "out of range")
		t.eq(SoundController.stepIndex(1, 1, 0), 0, "no stations")
	end)

	t.test("SoundController radio API exists and is safe headless", function()
		for _, fn in { "setRadioOn", "stepRadio", "getRadio", "radioStations" } do
			t.eq(type(SoundController[fn]), "function", fn)
		end
		t.ok(SoundController.RadioChanged ~= nil, "RadioChanged signal")
		t.ok(#SoundController.radioStations() >= 4, "stations exposed")
		local station, title, playing = SoundController.getRadio()
		t.eq(station, nil, "nothing tuned before the first drive")
		t.eq(title, nil)
		t.eq(playing, false)
	end)

	-- Remotes ---------------------------------------------------------------------------------------------------------
	t.test("remotes: VehicleFx (client->server) + VehicleFxState (server->client), no duplicates", function()
		local Remotes = H.require("src/shared/Remotes")
		local all = {}
		for _, list in { Remotes.ServerToClient, Remotes.ClientToServer, Remotes.Functions } do
			for _, name in list do
				t.ok(not all[name], "duplicate remote " .. name)
				all[name] = true
			end
		end
		t.ok(table.find(Remotes.ClientToServer, "VehicleFx") ~= nil, "VehicleFx")
		t.ok(table.find(Remotes.ServerToClient, "VehicleFxState") ~= nil, "VehicleFxState")
	end)

	-- EffectsController -----------------------------------------------------------------------------------------------
	t.test("EffectsController.boostAlive: fresh boost with a driver only", function()
		local Effects = H.require("src/client/Controllers/EffectsController")
		t.eq(Effects.boostAlive(true, 10, 12, 77), true)
		t.eq(Effects.boostAlive(true, 12.5, 12, 77), false, "keep-alive stopped")
		t.eq(Effects.boostAlive(true, 10, 12, 0), false, "driver left")
		t.eq(Effects.boostAlive(true, 10, 12, nil), false, "no driver attribute")
		t.eq(Effects.boostAlive(false, 10, 12, 77), false, "boost off")
	end)

	-- VehicleClient radio placement -----------------------------------------------------------------------------------
	t.test("VehicleClient.radioLayout: right of the speedometer when it fits, else mirrored left", function()
		local VClient = H.require("src/client/Controllers/VehicleClient")
		local ax, off = VClient.radioLayout(1280, false, 1)
		t.eq(ax, 0, "desktop: right")
		t.ok(off > 0)
		ax = VClient.radioLayout(1535, true, 1.31)
		t.eq(ax, 0, "phone canvas (0.55 floor, boosted pill): right of the speedometer, clear of DRIFT")
		ax, off = VClient.radioLayout(1280, true, 1)
		t.eq(ax, 1, "tablet: right side would touch DRIFT -> left")
		t.ok(off < 0)
		ax = VClient.radioLayout(1033, true, 1.31)
		t.eq(ax, 1, "tiny phone canvas -> left")
		-- whatever side is chosen, the pill stays on screen
		for _, case in { { 1033, true, 1.31 }, { 1280, true, 1 }, { 1280, false, 1 }, { 1535, true, 1.31 } } do
			local w, touch, scale = case[1], case[2], case[3]
			local a, o = VClient.radioLayout(w, touch, scale)
			local width = 216 * scale
			local left = if a == 0 then w / 2 + o else w / 2 + o - width
			t.ok(left >= 0 and left + width <= w, "on screen at " .. w)
		end
	end)

	-- VehicleFxService ------------------------------------------------------------------------------------------------
	H.setMode("server")
	local Fx = H.require("src/server/Systems/VehicleFxService")

	t.test("VehicleFxService.decide: boost changes always, honks past the cooldown", function()
		local send, honk = Fx.decide(false, true, false, 0)
		t.ok(send and not honk, "boost on")
		send = Fx.decide(true, true, false, 99)
		t.ok(not send, "unchanged boost without a honk")
		send, honk = Fx.decide(true, true, true, 1)
		t.ok(send and honk, "honk")
		send, honk = Fx.decide(true, true, true, 0.1)
		t.ok(not send and not honk, "honk spam inside the cooldown")
		send, honk = Fx.decide(true, false, true, 0.1)
		t.ok(send and not honk, "boost off still goes out; the early honk doesn't")
	end)

	t.test("VehicleFxService relay: driver-only, state changes, keep-alive, final boost=false", function()
		local clock = 100
		local fired = {}
		local driving = {}
		Fx._setHooks({
			clock = function()
				return clock
			end,
			getDriving = function(p)
				return driving[p]
			end,
			fireNear = function(name, pos, radius, id, boost, honk)
				table.insert(fired, { name = name, pos = pos, radius = radius, id = id, boost = boost, honk = honk })
			end,
		})
		local players = Instance.new("Folder")
		local p = Instance.new("Player")
		p.Parent = players
		local model = Instance.new("Model")
		local chassis = Instance.new("Part")
		chassis.Position = H.roblox.Vector3.new(10, 2, 30)
		chassis.Parent = model
		model.Parent = H.workspace

		Fx._onVehicleFx(p, true, false)
		t.eq(#fired, 0, "on foot: ignored")

		local car = { id = 42, driver = p, chassis = chassis, destroyed = false }
		driving[p] = car
		Fx._onVehicleFx(p, "yes", false)
		Fx._onVehicleFx(p, true, nil)
		t.eq(#fired, 0, "bad args ignored")

		Fx._onVehicleFx(p, true, false)
		t.eq(#fired, 1, "boost start relayed")
		t.eq(fired[1].name, "VehicleFxState")
		t.eq(fired[1].id, 42)
		t.eq(fired[1].boost, true)
		t.eq(fired[1].honk, false)
		t.eq(fired[1].radius, Fx.RANGE)
		t.ok((fired[1].pos - chassis.Position).Magnitude < 1e-6, "at the car")

		Fx._onVehicleFx(p, true, false)
		t.eq(#fired, 1, "same state: dropped")
		clock += 0.5
		Fx._onVehicleFx(p, true, true)
		t.eq(#fired, 2, "horn relayed")
		t.eq(fired[2].honk, true)
		clock += 0.1
		Fx._onVehicleFx(p, true, true)
		t.eq(#fired, 2, "horn spam dropped")

		-- someone else's car / a passenger can't drive the fx
		local other = Instance.new("Player")
		other.Parent = players
		driving[other] = { id = 43, driver = p, chassis = chassis, destroyed = false }
		Fx._onVehicleFx(other, true, true)
		t.eq(#fired, 2, "not the driver")

		-- keep-alive while boosting
		clock += 0.2
		Fx._sweep()
		t.eq(#fired, 2, "keep-alive waits KEEPALIVE")
		clock += Fx.KEEPALIVE
		Fx._sweep()
		t.eq(#fired, 3, "keep-alive")
		t.eq(fired[3].boost, true)
		t.eq(fired[3].honk, false)

		-- left the seat: final boost=false, then forgotten
		driving[p] = nil
		Fx._sweep()
		t.eq(#fired, 4, "flames closed")
		t.eq(fired[4].boost, false)
		Fx._sweep()
		t.eq(#fired, 4, "state forgotten")

		-- boost off while still driving goes out once
		driving[p] = car
		Fx._onVehicleFx(p, true, false)
		Fx._onVehicleFx(p, false, false)
		t.eq(#fired, 6)
		t.eq(fired[6].boost, false)
		clock += 10
		Fx._sweep()
		t.eq(#fired, 6, "no keep-alive when not boosting")

		Fx._setHooks(nil)
		model:Destroy()
	end)

	-- LightingService -------------------------------------------------------------------------------------------------
	local L = H.require("src/server/Systems/LightingService")

	t.test("lighting look: golden hour, moody neon night, keys sorted + wrapping", function()
		for i = 2, #L.KEYS do
			t.ok(L.KEYS[i - 1].hour < L.KEYS[i].hour, "keys sorted")
		end
		local first, last = L.KEYS[1], L.KEYS[#L.KEYS]
		t.eq(first.hour, 0)
		t.eq(last.hour, 24)
		for k, v in first do
			if k ~= "hour" then
				t.ok(last[k] == v, "midnight wraps: " .. k)
			end
		end
		local noon, golden, night = L.lookAt(12), L.lookAt(16.4), L.lookAt(0)
		t.ok(L.START_HOUR >= 15.5 and L.START_HOUR <= 17.2, "servers start at golden hour")
		t.ok(not L.isNightHour(L.START_HOUR), "golden hour is day")
		local warm = function(c)
			return c.R - c.B
		end
		t.ok(warm(golden.tint) > warm(noon.tint) + 0.1, "golden tint is warmer than noon")
		t.ok(golden.rays > noon.rays, "golden sun rays")
		t.ok(night.density > noon.density, "thicker night atmosphere")
		t.ok(night.haze > noon.haze, "deeper night haze")
		t.ok(night.bloom > noon.bloom and night.bloomThreshold < noon.bloomThreshold, "neon blooms at night")
		t.ok(night.saturation > noon.saturation, "saturated night")
		t.ok(night.brightness > 1, "night stays readable")
		-- smooth: no big jump between consecutive 2 s env steps anywhere in the cycle
		local step = L.ENV_INTERVAL
		local prev = L.lookAt(L.hourAt(0))
		for s = step, L.CYCLE_SECONDS, step do
			local cur = L.lookAt(L.hourAt(s))
			t.ok(math.abs(cur.brightness - prev.brightness) < 0.2, "brightness step at " .. s)
			t.ok(math.abs(cur.haze - prev.haze) < 0.25, "haze step at " .. s)
			prev = cur
		end
	end)

	t.test("lighting writes: unchanged values are skipped", function()
		t.eq(L._changed(nil, 1, 0.1), true, "never written")
		t.eq(L._changed(1, 1.05, 0.1), false)
		t.eq(L._changed(1, 1.2, 0.1), true)
		local c = H.roblox.Color3.fromRGB
		t.eq(L._changed(c(10, 10, 10), c(11, 10, 10), 1.5 / 255), false)
		t.eq(L._changed(c(10, 10, 10), c(13, 10, 10), 1.5 / 255), true)
		t.eq(L._changed(1, c(1, 1, 1), 0.1), true, "type change")

		local Lighting = H.game:GetService("Lighting")
		L.init()
		L.setClockTime(12)
		local before = Lighting.Brightness
		Lighting.Brightness = 0.123 -- simulated foreign write: the cache must not rewrite an unchanged look
		L.setClockTime(12)
		t.near(Lighting.Brightness, 0.123, 1e-6, "skipped")
		L.setClockTime(0)
		t.ok(math.abs(Lighting.Brightness - L.lookAt(0).brightness) < 0.05, "a real change is written")
		local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
		t.ok(math.abs(atmo.Haze - L.lookAt(0).haze) < 0.05, "night haze applied")
		local bloom = Lighting:FindFirstChildOfClass("BloomEffect")
		t.ok(math.abs(bloom.Threshold - L.lookAt(0).bloomThreshold) < 0.02, "night bloom threshold applied")
		L.setClockTime(12)
		t.ok(math.abs(Lighting.Brightness - before) < 0.05, "day restored")
	end)

	-- Loading screen --------------------------------------------------------------------------------------------------
	t.test("loading screen: ReplicatedFirst mapping + script compiles and covers the contract", function()
		local project = serde.decode("json", fs.readFile("default.project.json"))
		local rf = project.tree.ReplicatedFirst
		t.ok(rf ~= nil, "ReplicatedFirst in the project")
		t.eq(rf["$className"], "ReplicatedFirst")
		t.eq(rf.Loading["$path"], "src/first")
		t.ok(project.tree.ReplicatedStorage.Shared ~= nil, "rest of the tree kept")
		local path = "src/first/LoadingScreen.client.luau"
		t.ok(fs.isFile(path), "LoadingScreen exists")
		local source = fs.readFile(path)
		local ok, err = pcall(luau.compile, source)
		t.ok(ok, "compiles: " .. tostring(err))
		local needles = {
			"RemoveDefaultLoadingScreen",
			"PreloadAsync",
			"IsLoaded",
			"AllReady",
			"loading_art",
			"logo_hotwire_city",
			"Hold E to hotwire",
			"Drive it into your DROP-OFF",
			"Lock your garage!",
			"Hot Drops = mythic cars",
			"Spray Shops lose the cops",
		}
		for _, needle in needles do
			t.ok(source:find(needle, 1, true) ~= nil, "mentions " .. needle)
		end
		local only = 0
		for _, f in fs.readDir("src/first") do
			if f:match("%.client%.luau$") then
				only += 1
			end
		end
		t.eq(only, 1, "the only LocalScript in ReplicatedFirst")
	end)
end
