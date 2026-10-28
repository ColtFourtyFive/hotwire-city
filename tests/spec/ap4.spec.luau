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

	t.test("radio tracks: 6-24 public music ids, one-shot, quiet, named station + title", function()
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
		-- C3 audio: 6 stations x 3 tracks (Roblox-licensed APM, audited); a cap keeps the stream budget sane
		t.ok(count >= 6 and count <= 24, "radio track count " .. count)
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

	t.test("SoundController.stepRadio: label retunes per press, the track waits for RADIO_TUNE_DELAY", function()
		H.setMode("client") -- fresh module state (nothing tuned yet)
		local SC = H.require("src/client/Controllers/SoundController")
		local seen = {}
		SC.RadioChanged:Connect(function(station, title)
			table.insert(seen, { station = station, title = title })
		end)
		local names = SC.radioStations()
		SC.stepRadio(1)
		SC.stepRadio(1)
		SC.stepRadio(-1)
		t.eq(#seen, 3, "one label update per press")
		t.eq(seen[1].station, names[1])
		t.eq(seen[2].station, names[2])
		t.eq(seen[3].station, names[1], "back one")
		t.eq(seen[3].title, nil, "no track title until the new station's track starts")
		local station, title, playing = SC.getRadio()
		t.eq(station, names[1])
		t.eq(title, nil)
		t.eq(playing, false, "silent radio: retune only (no deck touched headless)")
		t.ok(SC.RADIO_TUNE_DELAY > 0.2 and SC.RADIO_TUNE_DELAY <= 1, "debounce window")
		H.setMode("client")
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
	-- design-canvas x span of a radioLayout result
	local function radioSpan(w, layout, scale)
		local width = layout.width * scale
		local left = if layout.anchorX == 0 then w / 2 + layout.offsetX else w / 2 + layout.offsetX - width
		return left, left + width
	end

	t.test("VehicleClient.radioLayout: desktop pill right of the speedometer, else mirrored left", function()
		local VClient = H.require("src/client/Controllers/VehicleClient")
		local L = VClient.radioLayout(1280, false, 1)
		t.eq(L.anchorX, 0, "desktop: right")
		t.ok(L.offsetX > 0)
		t.eq(L.width, 216, "full pill")
		t.eq(L.compact, false, "◀ ▶ + track line")
		t.eq(L.tap, false)
		L = VClient.radioLayout(700, false, 1)
		t.eq(L.anchorX, 1, "narrow desktop window: mirrored left (no thumbstick on desktop)")
		t.ok(L.offsetX < 0)
		for _, w in { 808, 1280, 1920 } do -- 808 = a 444 px window at the 0.55 floor
			local left, right = radioSpan(w, VClient.radioLayout(w, false, 1), 1)
			t.ok(left >= 0 and right <= w, "on screen at " .. w)
		end
	end)

	t.test("VehicleClient.radioLayout: touch never puts a radio button in the thumbstick zone or on DRIFT", function()
		local VClient = H.require("src/client/Controllers/VehicleClient")
		-- { canvas width, pill scale = phone text boost }: 4:3 / 16:10 tablets (1280, 1), iPhone SE 2/3 (667 px at the
		-- 0.55 floor: 1213, 1.31), notched 844x390 inside its ~47 px safe-area insets (1364, 1.31), Pro Max inside its
		-- insets (1363, 1.21), wide 20:9 Android (1455, 1.31), 640-wide Android (1164, 1.31), 568-wide phone
		-- (1033, 1.31), portrait phone (682, 1.31)
		local cases = {
			{ 1280, 1 },
			{ 1213, 1.31 },
			{ 1364, 1.31 },
			{ 1363, 1.206 },
			{ 1455, 1.31 },
			{ 1164, 1.31 },
			{ 1033, 1.31 },
			{ 682, 1.31 },
		}
		for _, case in cases do
			local w, scale = case[1], case[2]
			local L = VClient.radioLayout(w, true, scale)
			local left, right = radioSpan(w, L, scale)
			local at = " at " .. w .. "/" .. scale
			t.eq(L.compact, true, "touch: compact pill (no ◀ ▶ buttons)" .. at)
			t.ok(left >= 0 and right <= w, "on screen" .. at)
			if L.tap then
				t.ok(left >= 0.4 * w, "tap target outside the thumbstick zone (left 40%)" .. at)
				t.ok(left >= w / 2 + 170, "right of the speedometer" .. at)
				t.ok(right <= w - 256, "clear of DRIFT (x W-256..W-156)" .. at)
				t.ok(L.width >= 100 and L.width <= 216, "readable width" .. at)
			end
		end
		local tablet = VClient.radioLayout(1280, true, 1)
		t.eq(tablet.tap, true, "tablet: tap pill between the speedometer and DRIFT")
		t.ok(tablet.width <= 202 and tablet.width >= 200, "tablet: shrunk to the 202 px slot")
		t.eq(VClient.radioLayout(1213, true, 1.31).tap, true, "iPhone SE: still fits on the right")
		local notched = VClient.radioLayout(1364, true, 1.31)
		t.eq(notched.tap, true, "notched phone, real (inset) canvas: right")
		local _, notchedRight = radioSpan(1364, notched, 1.31)
		t.ok(notchedRight <= 1364 - 256 - 6, "notched phone: clear of DRIFT's left edge")
		local tiny = VClient.radioLayout(1033, true, 1.31)
		t.eq(tiny.tap, false, "too narrow: display-only pill (touches fall through to the thumbstick)")
		t.eq(tiny.anchorX, 1, "display-only pill left of the speedometer")
		-- a bad scale never breaks placement
		t.eq(VClient.radioLayout(1280, true, 0 / 0).width, VClient.radioLayout(1280, true, 1).width, "NaN scale = 1")
	end)

	t.test("VehicleClient.canvasWidth: the DrivingUI (safe-area) canvas, viewport only as a fallback", function()
		local VClient = H.require("src/client/Controllers/VehicleClient")
		t.near(VClient.canvasWidth(750, 844, 0.55), 750 / 0.55, 1e-9, "gui width wins over the viewport")
		t.near(VClient.canvasWidth(0, 844, 0.55), 844 / 0.55, 1e-9, "gui not sized yet: viewport")
		t.near(VClient.canvasWidth(1280, 1280, 0), 1280, 1e-9, "bad scale = 1")
	end)

	-- VehicleFxService ------------------------------------------------------------------------------------------------
	H.setMode("server")
	local Fx = H.require("src/server/Systems/VehicleFxService")

	t.test("VehicleFxService.decide: boost stops always, starts spaced, honks past the cooldown", function()
		local send, honk, boost = Fx.decide(false, true, false, 0)
		t.ok(send and not honk and boost, "boost on")
		send = Fx.decide(true, true, false, 99)
		t.ok(not send, "unchanged boost without a honk")
		send, honk = Fx.decide(true, true, true, 1)
		t.ok(send and honk, "honk")
		send, honk = Fx.decide(true, true, true, 0.1)
		t.ok(not send and not honk, "honk spam inside the cooldown")
		send, honk, boost = Fx.decide(true, false, true, 0.1)
		t.ok(send and not honk and not boost, "boost off still goes out; the early honk doesn't")
		t.ok(Fx.HONK_COOLDOWN >= 0.35, "server horn cooldown matches the client's 0.35 s")
		-- toggle spam: a start right after the previous start is dropped (flames stay off)
		send, honk, boost = Fx.decide(false, true, false, 99, Fx.MIN_BOOST_EDGE * 0.5)
		t.ok(not send and not boost, "boost start spam dropped")
		send, honk, boost = Fx.decide(false, true, true, 99, Fx.MIN_BOOST_EDGE * 0.5)
		t.ok(send and honk and not boost, "the honk still goes out, the flames don't")
		send, honk, boost = Fx.decide(false, true, false, 99, Fx.MIN_BOOST_EDGE)
		t.ok(send and boost, "a start past MIN_BOOST_EDGE goes out")
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
			fireNear = function(name, except, pos, radius, id, boost, honk)
				table.insert(
					fired,
					{ name = name, except = except, pos = pos, radius = radius, id = id, boost = boost, honk = honk }
				)
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
		t.eq(fired[1].except, p, "the sender's own client is skipped")
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

	t.test("VehicleFxService: an endless boost is cut at MAX_BOOST unless the driver has Infinite Nitro", function()
		local clock = 500
		local fired = {}
		local infinite = false
		local players = Instance.new("Folder")
		local p = Instance.new("Player")
		p.Parent = players
		local model = Instance.new("Model")
		local chassis = Instance.new("Part")
		chassis.Parent = model
		model.Parent = H.workspace
		chassis.Position = H.roblox.Vector3.new(0, 2, 0)
		local car = { id = 7, driver = p, chassis = chassis, destroyed = false }
		Fx._setHooks({
			clock = function()
				return clock
			end,
			getDriving = function()
				return car
			end,
			infiniteNitro = function()
				return infinite
			end,
			fireNear = function(_name, _except, _pos, _radius, _id, boost, honk)
				table.insert(fired, { boost = boost, honk = honk })
			end,
		})
		Fx._onVehicleFx(p, true, false)
		t.eq(#fired, 1, "boost on")
		while clock < 500 + Fx.MAX_BOOST - 1 do
			clock += 0.5
			Fx._sweep()
		end
		t.eq(fired[#fired].boost, true, "keep-alives while under MAX_BOOST")
		clock += 2
		Fx._sweep()
		t.eq(fired[#fired].boost, false, "cut after MAX_BOOST")
		local n = #fired
		clock += 1
		Fx._onVehicleFx(p, true, false)
		t.eq(#fired, n, "a cut boost stays off while the client still reports it")
		Fx._onVehicleFx(p, false, false)
		clock += 1
		Fx._onVehicleFx(p, true, false)
		t.eq(fired[#fired].boost, true, "a fresh start after a stop works again")

		-- Infinite Nitro: never cut
		infinite = true
		clock += Fx.MAX_BOOST * 3
		Fx._sweep()
		t.eq(fired[#fired].boost, true, "Infinite Nitro keeps the flames")
		Fx._setHooks(nil)
		model:Destroy()
	end)

	-- LightingService (v2 look + cheap-write tests live in tests/spec/look.spec.luau and lighting.spec.luau) ---------
	local L = H.require("src/server/Systems/LightingService")

	t.test("one Clouds under Terrain: LightingService adopts MapBuilder's", function()
		local terrain = H.workspace:FindFirstChildOfClass("Terrain")
		for _, c in terrain:GetChildren() do
			if c:IsA("Clouds") then
				c:Destroy()
			end
		end
		local MapBuilder = H.require("src/server/Systems/MapBuilder")
		MapBuilder.buildTerrain(terrain)
		L.init()
		L.init() -- re-init doesn't add another either
		local n = 0
		for _, c in terrain:GetChildren() do
			if c:IsA("Clouds") then
				n += 1
			end
		end
		t.eq(n, 1, "a single Clouds instance")
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
			"garage drop-off",
			"Lock your garage",
			"Hot Drops put rare cars",
			"Spray Shops clear your wanted level",
		}
		for _, needle in needles do
			t.ok(source:find(needle, 1, true) ~= nil, "mentions " .. needle)
		end
		-- the tutorial waits for this overlay's ScreenGui (by name) before step 1
		H.setMode("client")
		local Tut = H.require("src/client/Controllers/TutorialController")
		t.ok(source:find('Name = "' .. Tut.LOADING_GUI .. '"', 1, true) ~= nil, "TutorialController watches its gui")
		local playerGui = H.localPlayer:FindFirstChildOfClass("PlayerGui")
		t.eq(Tut.loadingScreenUp(), false, "no overlay")
		local overlay = Instance.new("ScreenGui")
		overlay.Name = Tut.LOADING_GUI
		overlay.Parent = playerGui
		t.eq(Tut.loadingScreenUp(), true, "overlay up")
		overlay:Destroy()
		t.eq(Tut.loadingScreenUp(), false, "overlay faded + destroyed")
		H.setMode("server")
		local only = 0
		for _, f in fs.readDir("src/first") do
			if f:match("%.client%.luau$") then
				only += 1
			end
		end
		t.eq(only, 1, "the only LocalScript in ReplicatedFirst")
	end)
end
