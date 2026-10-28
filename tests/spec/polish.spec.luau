--!nocheck
-- C4b polish (job 0006 fixes + the de-Robloxify pass, docs/v2/DEROBLOX_AUDIT.md):
--   bug 1  phone apps: the app page frame never shadows Phone:page()
--   bug 2  WASTED / BUSTED: the band is always drawn; WASTED always has a subtitle; money in red
--   bug 3  gun-shop rows take mouse clicks (hit-test + dedupe; the chat window steps aside)
--   bug 4  one shared UI-focus state: no firing / aiming while any menu holds the cursor
--   bug 5  one arrest = one bail charge (repro at the playtest's numbers) + the structured [Bust] log
--   nits   help text expires, event rows at the feed position (no pills, emoji or shouting), vehicle name, counter
--   audit  CoreGui / bubbles / Esc bridge, leaderboard billboards, lock bar, config display names, kid copy
local fs = require("@lune/fs")

local function emojiIn(src: string): number?
	for _, cp in utf8.codes(src) do
		if (cp >= 0x1F000 and cp <= 0x1FAFF) or (cp >= 0x2600 and cp <= 0x27BF) or cp == 0x2B50 then
			return cp
		end
	end
	return nil
end

-- Non-comment source lines.
local function codeLines(path: string): { string }
	local out = {}
	for line in string.gmatch(fs.readFile(path), "[^\n]+") do
		if not string.match(line, "^%s*%-%-") then
			table.insert(out, line)
		end
	end
	return out
end

return function(t)
	local H = t.H
	local Vector2 = H.roblox.Vector2
	local Vector3 = H.roblox.Vector3
	local CFrame = H.roblox.CFrame
	local Enum = H.roblox.Enum

	---------------------------------------------------------------------------------------------------------------------
	-- Bug 1: phone apps
	---------------------------------------------------------------------------------------------------------------------

	t.test("bug 1: Phone:page() stays a method; the app page is phone.pageFrame", function()
		H.setMode("client")
		local Phone = H.require("src/client/UI/Phone")
		t.eq(typeof(Phone.page), "function")
		-- a built phone, minus the engine: page() must hand the frame to the app builder, twice in a row
		local cleared = 0
		local frame = {
			Visible = false,
			CanvasPosition = nil,
			GetChildren = function()
				cleared += 1
				return {}
			end,
		}
		local fake = setmetatable({
			gui = true, -- _build() returns early
			grid = { Visible = true },
			highlight = { Visible = true },
			titleLabel = { Text = "" },
			pageFrame = frame,
		}, Phone)
		local got = {}
		fake:page("Jobs", function(f)
			table.insert(got, f)
		end)
		fake:page("Codes", function(f)
			table.insert(got, f)
		end)
		t.eq(#got, 2, "both apps opened (job 0006: 'attempt to call a Instance value')")
		t.eq(got[1], frame)
		t.eq(fake.titleLabel.Text, "Codes")
		t.eq(frame.Visible, true)
		t.eq(fake.grid.Visible, false)
		t.eq(cleared, 2, "the previous app's rows are cleared")
		t.eq(typeof(fake.page), "function", "no instance field shadows the method")
		H.setMode("server")
	end)

	t.test("bug 1 (class): no self.<field> in Phone / ListMenu / PauseMenu shadows one of its methods", function()
		for _, spec in
			{
				{ "src/client/UI/Phone.luau", "Phone" },
				{ "src/client/UI/ListMenu.luau", "ListMenu" },
				{ "src/client/UI/PauseMenu.luau", "PauseMenu" },
			}
		do
			local src = fs.readFile(spec[1])
			local methods = {}
			for name in string.gmatch(src, "function " .. spec[2] .. ":([%w_]+)%(") do
				methods[name] = true
			end
			t.ok(next(methods) ~= nil, spec[1] .. ": methods found")
			for _, line in codeLines(spec[1]) do
				local field = string.match(line, "self%.([%w_]+)%s*=[^=]")
				if field then
					t.ok(
						not methods[field],
						("%s: self.%s = ... shadows %s:%s()"):format(spec[1], field, spec[2], field)
					)
				end
			end
		end
	end)

	---------------------------------------------------------------------------------------------------------------------
	-- Bug 2: the shard band
	---------------------------------------------------------------------------------------------------------------------

	t.test("bug 2: the band is always drawn (the plain 19.5% band unless the keystone art has loaded)", function()
		H.setMode("client")
		local Shard = H.require("src/client/UI/Shard")
		t.eq(Shard.bandPlan(false, false), "frame", "no art configured")
		t.eq(Shard.bandPlan(true, false), "frame", "art configured but not loaded: job 0006 showed no band at all")
		t.eq(Shard.bandPlan(true, true), "keystone")
		t.near(Shard.bandHeight("frame"), 0.195, 1e-9, "gta_ui_language §5.9 base band")
		t.near(Shard.bandHeight("keystone"), 0.23, 1e-9)
		local src = fs.readFile("src/client/UI/Shard.luau")
		t.ok(string.find(src, "Position = UDim2.fromScale(0.5, 0.488)", 1, true) ~= nil, "band centred at 48.8% H")
		t.ok(string.find(src, "pickBand(u)", 1, true) ~= nil, "every shard picks its band")
		-- wasted / busted alpha ~0.5 (re-measured 0.48-0.58)
		local ok = string.find(src, "alpha = 0.5", 1, true) ~= nil or string.find(src, "alpha = 0.50", 1, true) ~= nil
		t.ok(ok, "wasted / busted band at ~50% black")
		H.setMode("server")
	end)

	t.test("bug 2: WASTED always has a subtitle; BUSTED's bail is styled; dynamic parts escaped", function()
		H.setMode("client")
		local DS = H.require("src/client/Controllers/DeathScreenController")
		t.eq(DS._wastedSubtitle({}), "Taken to the hospital", "never empty (job 0006: no subtitle)")
		t.eq(DS._wastedSubtitle({ hospital = "Mount Mercy" }), "Taken to Mount Mercy")
		t.eq(DS._wastedSubtitle({ bill = 900 }), "Hospital bill  <r>-$900</r>")
		t.eq(DS._wastedSubtitle({ by = "<b>x</b>" }), "Downed by &lt;b&gt;x&lt;/b&gt;", "names escaped")
		t.eq(DS._bustedSubtitle(3600, nil), "Bail  <r>-$3,600</r>")
		t.eq(DS._bustedSubtitle(0, "Halden Wren"), "Released without bail   ·   Halden Wren impounded")
		t.ok(DS.VIGNETTE_EDGE >= 0.4, "the edge vignette no longer buries the band")
		H.setMode("server")
	end)

	---------------------------------------------------------------------------------------------------------------------
	-- Bug 3: gun-shop clicks
	---------------------------------------------------------------------------------------------------------------------

	t.test("bug 3: gun-shop rows are hit-tested by rect; one activation per click", function()
		H.setMode("client")
		local Shop = H.require("src/client/Controllers/GunShopUI")
		local rects = {}
		for i = 1, 8 do
			-- 300 x 28 rows from y = 120 (the list menu geometry, §5.13)
			rects[i] = { x = 16, y = 120 + (i - 1) * 28, w = 300, h = 28, visible = i <= 8 }
		end
		t.eq(Shop._hitRow(Vector2.new(100, 120 + 7 * 28 + 10), rects), 8, "Row8 (Med Kit in job 0006)")
		t.eq(Shop._hitRow(Vector2.new(100, 121), rects), 1)
		t.eq(Shop._hitRow(Vector2.new(400, 130), rects), nil, "right of the menu")
		t.eq(Shop._hitRow(Vector2.new(100, 120 + 8 * 28), rects), nil, "below the last row (edges are half-open)")
		rects[3].visible = false
		t.eq(Shop._hitRow(Vector2.new(100, 120 + 2 * 28 + 5), rects), nil, "hidden rows never take clicks")
		t.eq(Shop._mouseDedupe(true, true), false, "the press already bought: the release does nothing")
		t.eq(Shop._mouseDedupe(true, false), true, "a click the hit-test missed still works through Activated")
		t.eq(Shop._mouseDedupe(false, true), true, "touch / gamepad activations always run")
		local src = fs.readFile("src/client/Controllers/GunShopUI.luau")
		for _, needle in { "Active = true", 'UIFocus.set("gunshop", true)', 'UIFocus.set("gunshop", false)' } do
			t.ok(string.find(src, needle, 1, true) ~= nil, "GunShopUI: " .. needle)
		end
		H.setMode("server")
	end)

	---------------------------------------------------------------------------------------------------------------------
	-- Bug 4: one UI-focus state gates the gun
	---------------------------------------------------------------------------------------------------------------------

	t.test("bug 4: UIFocus policies, set / clear, Changed", function()
		H.setMode("client")
		local UIFocus = H.require("src/client/UI/UIFocus")
		UIFocus._reset()
		t.eq(UIFocus.firePolicy({}), false)
		t.eq(UIFocus.firePolicy({ phone = true }), true)
		t.eq(UIFocus.chatPolicy({ phone = true }), false, "the phone sits bottom-right: chat stays")
		t.eq(UIFocus.chatPolicy({ gunshop = true }), true, "the shop rows sit under the chat window")
		t.eq(UIFocus.chatPolicy({ ["list:gear"] = true }), true)
		t.eq(UIFocus.chatPolicy({ pause = true }), true)
		local events = {}
		local conn = UIFocus.Changed:Connect(function(any)
			table.insert(events, any)
		end)
		UIFocus.set("phone", true)
		UIFocus.set("phone", true) -- no change, no event
		t.eq(UIFocus.blocksFire(), true)
		t.eq(UIFocus.hidesChat(), false)
		UIFocus.set("gunshop", true)
		t.eq(UIFocus.hidesChat(), true)
		t.eq(table.concat(UIFocus.ids(), ","), "gunshop,phone")
		UIFocus.set("phone", false)
		UIFocus.set("gunshop", false)
		t.eq(UIFocus.blocksFire(), false)
		t.eq(#events, 4)
		t.eq(events[4], false)
		UIFocus.set("", true)
		t.eq(UIFocus.any(), false, "empty ids are ignored")
		conn:Disconnect()
		UIFocus._reset()
		H.setMode("server")
	end)

	t.test("bug 4: fire / aim presses are dropped while a menu holds the cursor (every host registers)", function()
		H.setMode("client")
		local WeaponClient = H.require("src/client/Controllers/WeaponClient")
		t.eq(WeaponClient._triggerAllowed(false, false), true)
		t.eq(WeaponClient._triggerAllowed(false, true), false, "phone open: a click that misses it never fires")
		t.eq(WeaponClient._triggerAllowed(true, false), false, "GUI-processed")
		local needles = {
			{ "src/client/Controllers/WeaponClient.luau", { "UIFocus.blocksFire()", "UIFocus.Changed:Connect" } },
			{ "src/client/Controllers/CombatClient.luau", { "UIFocus.blocksFire()" } },
			{ "src/client/UI/Phone.luau", { 'UIFocus.set("phone", true)', 'UIFocus.set("phone", false)' } },
			{ "src/client/UI/PauseMenu.luau", { 'UIFocus.set("pause", true)', 'UIFocus.set("pause", false)' } },
			{ "src/client/UI/ListMenu.luau", { 'UIFocus.set("list:" .. tostring(self.id), true)' } },
		}
		for _, c in needles do
			local src = fs.readFile(c[1])
			for _, needle in c[2] do
				t.ok(string.find(src, needle, 1, true) ~= nil, c[1] .. ": " .. needle)
			end
		end
		H.setMode("server")
	end)

	---------------------------------------------------------------------------------------------------------------------
	-- Bug 5: one arrest, one bail
	---------------------------------------------------------------------------------------------------------------------

	local Wanted = H.require("src/server/Systems/WantedService")
	local Economy = H.require("src/shared/Config/Economy")

	local function fakePlayer(name, userId)
		local attrs = {}
		local root = {
			CFrame = CFrame.new(5000, 10, 5000),
			IsA = function(_, cls)
				return cls == "BasePart"
			end,
		}
		return {
			Name = name,
			DisplayName = name,
			UserId = userId,
			Parent = nil,
			Character = {
				FindFirstChild = function(_, n)
					return if n == "HumanoidRootPart" then root else nil
				end,
			},
			SetAttribute = function(_, k, v)
				attrs[k] = v
			end,
			GetAttribute = function(_, k)
				return attrs[k]
			end,
			IsA = function(_, cls)
				return cls == "Player" or cls == "Instance"
			end,
		}
	end

	local clock = 0
	local datas = {}
	local fired = {}
	local logs = {}
	local spendMode = "normal" -- "normal" | "balance" | "throwAfter" | "refuse"
	local spendCalls = 0
	local addCalls = 0
	local mocks = {
		DataService = {
			get = function(p)
				return datas[p]
			end,
			spendCash = function(p, amount)
				spendCalls += 1
				local d = datas[p]
				if spendMode == "refuse" or not d or d.cash < amount then
					return false
				end
				d.cash -= amount
				if spendMode == "balance" then
					return d.cash
				elseif spendMode == "throwAfter" then
					error("markDirty exploded")
				end
				return true
			end,
			addCash = function(p, amount)
				addCalls += 1
				datas[p].cash = math.max(0, datas[p].cash + amount)
				return datas[p].cash
			end,
			markDirty = function() end,
		},
		GarageService = {
			incomePerSec = function()
				return 6 -- job 0006: the bail read $3,600 = 600 s x $6/s (10% of $64,886 is more)
			end,
		},
		PoliceService = {
			isSeen = function()
				return true
			end,
			copsNear = function()
				return true
			end,
		},
		VehicleService = {
			getDriving = function()
				return nil
			end,
			eject = function() end,
			destroy = function() end,
		},
	}
	Wanted._setHooks({
		isTest = true,
		clock = function()
			return clock
		end,
		system = function(name)
			return mocks[name]
		end,
		fireClient = function(name, player, ...)
			table.insert(fired, { name = name, player = player, args = { ... } })
		end,
		fireAll = function() end,
		fireNear = function() end,
		log = function(line)
			table.insert(logs, line)
		end,
	})

	local function bustedRemotes(p)
		local out = {}
		for _, f in fired do
			if f.name == "Busted" and f.player == p then
				table.insert(out, f.args[1])
			end
		end
		return out
	end

	t.test("bug 5 repro: -$7,200 at the playtest's numbers is two arrests at $3,600, each shown and logged", function()
		clock = 10000
		table.clear(fired)
		table.clear(logs)
		spendMode = "normal"
		local p = fakePlayer("illintent1", 9001)
		datas[p] = { cash = 64886, stats = { busted = 0 } }
		Wanted._addPlayer(p)
		-- step 10: drive with 2 stars, get out; officers close in off-camera (PoliceService.bustPass -> bust(player))
		Wanted.addHeat(p, 2, "carjack")
		t.eq(Wanted.bust(p), true)
		t.eq(datas[p].cash, 61286, "first arrest: bail capped at 600 s of income")
		-- step 11: stars again, stand still by an officer: the police bust lands before the 1 s surrender hold
		clock += 9
		Wanted.addHeat(p, 2, "carjack")
		t.eq(Wanted.bust(p), true)
		t.eq(datas[p].cash, 57686, "64,886 -> 57,686 (-7,200), exactly the playtest's numbers")
		local shown = bustedRemotes(p)
		t.eq(#shown, 2, "two BUSTED screens (the first was off-camera)")
		t.eq(shown[1], 3600)
		t.eq(shown[2], 3600, "each screen shows exactly what it charged")
		t.eq(#logs, 2, "one [Bust] line per arrest")
		t.ok(string.find(logs[1], "cash=64886->61286 bail=3600", 1, true) ~= nil, logs[1])
		t.ok(string.find(logs[2], "cash=61286->57686 bail=3600", 1, true) ~= nil, logs[2])
		t.ok(string.find(logs[2], "sinceLast=9.0", 1, true) ~= nil, "the second line says how soon after the first")
		t.eq(datas[p].stats.busted, 2)
		-- a real surrender is half price, so the deliberate one in job 0006 was the police, not the surrender
		clock += 9
		Wanted.addHeat(p, 1, "carjack")
		local before = datas[p].cash
		t.eq(Wanted.surrender(p), true)
		t.eq(before - datas[p].cash, math.floor(3600 * Economy.SURRENDER_PENALTY_MULT), "surrender: half the bail")
		t.ok(string.find(logs[3], "reason=surrender", 1, true) ~= nil, logs[3])
		Wanted._removePlayer(p)
	end)

	t.test("bug 5: every bust path at once (police + surrender + reset) charges once", function()
		clock = 20000
		table.clear(fired)
		table.clear(logs)
		spendMode = "normal"
		local p = fakePlayer("Racer", 9002)
		datas[p] = { cash = 50000, stats = { busted = 0 } }
		Wanted._addPlayer(p)
		Wanted.addHeat(p, 2, "carjack")
		local a = Wanted.bust(p) -- PoliceService.bustPass
		local b = Wanted.surrender(p) -- the hold-H remote in the same frame
		local c = Wanted._onDied(p, Vector3.new(5000, 10, 5000)) -- DamageService: a reset with stars
		t.eq(a, true)
		t.eq(b, false, "already busted: stars are 0")
		t.eq(c, false)
		t.eq(datas[p].cash, 50000 - 3600, "one bail")
		t.eq(#bustedRemotes(p), 1)
		t.eq(#logs, 1)
		Wanted._removePlayer(p)
	end)

	t.test("bug 5: spendCash is the only charge (throws after deducting, returns a balance, refuses)", function()
		local function run(mode, cash)
			clock += 100
			table.clear(fired)
			table.clear(logs)
			spendMode = mode
			spendCalls, addCalls = 0, 0
			local p = fakePlayer("Mode" .. mode, 9100 + #mode)
			datas[p] = { cash = cash, stats = { busted = 0 } }
			Wanted._addPlayer(p)
			Wanted.addHeat(p, 1, "carjack")
			Wanted.bust(p)
			local shown = bustedRemotes(p)[1]
			Wanted._removePlayer(p)
			return datas[p].cash, shown
		end
		local cash, shown = run("throwAfter", 40000)
		t.eq(cash, 40000 - 3600, "v1 charged again through addCash: -$7,200")
		t.eq(shown, 3600, "the screen shows what left the wallet")
		t.eq(addCalls, 0)
		cash, shown = run("balance", 40000)
		t.eq(cash, 40000 - 3600, "a DataService returning the new balance is charged once")
		t.eq(shown, 3600)
		t.eq(addCalls, 0)
		cash, shown = run("refuse", 40000)
		t.eq(cash, 40000, "refused (not loaded): nothing taken")
		t.eq(shown, 0, "and nothing shown")
		t.eq(addCalls, 0, "no addCash second pass")
		spendMode = "normal"
	end)

	t.test("bug 5: _bailPaid and the [Bust] line format", function()
		t.eq(Wanted._bailPaid(true, true, 100, 90, 10), true)
		t.eq(Wanted._bailPaid(true, 90, 100, 90, 10), true, "balance return, wallet moved")
		t.eq(Wanted._bailPaid(false, "boom", 100, 90, 10), true, "threw after deducting")
		t.eq(Wanted._bailPaid(false, "boom", 100, 100, 10), false, "threw before deducting")
		t.eq(Wanted._bailPaid(true, false, 100, 100, 10), false)
		t.eq(Wanted._bailPaid(true, true, 100, 100, 0), false, "no bail")
		local line = Wanted._formatBust({
			id = 7,
			userId = 42,
			reason = "police",
			stars = 2,
			peak = 3,
			cashBefore = 64886,
			cashAfter = 61286,
			bail = 3600,
			mult = 1,
			car = "Halden Wren",
			sinceLast = nil,
		})
		t.eq(
			line,
			"[Bust] id=7 user=42 reason=police stars=2 peak=3 cash=64886->61286 bail=3600 mult=1 car=Halden_Wren sinceLast=-"
		)
		-- the police only ever arrest through WantedService.bust (no bail of their own)
		local police = fs.readFile("src/server/Systems/PoliceService.luau")
		t.ok(not string.find(police, "spendCash", 1, true), "PoliceService never charges cash itself")
		t.ok(string.find(police, "pcall(WantedService.bust, player)", 1, true) ~= nil)
	end)

	---------------------------------------------------------------------------------------------------------------------
	-- Nits
	---------------------------------------------------------------------------------------------------------------------

	t.test("nit: tutorial help text shows ~8 s and re-shows only for a new hint", function()
		H.setMode("client")
		local Tut = H.require("src/client/Controllers/TutorialController")
		t.eq(Tut.HELP_SECONDS, 8)
		t.eq(Tut.helpAction(nil, "Hold E to hotwire it."), "show")
		t.eq(Tut.helpAction("Hold E to hotwire it.", "Hold E to hotwire it."), "none", "same hint: stays expired")
		t.eq(Tut.helpAction("Hold E to hotwire it.", "Follow the yellow route."), "show")
		t.eq(Tut.helpAction("x", nil), "clear")
		t.eq(Tut.helpAction(nil, nil), "none")
		t.eq(Tut.helpAction(nil, ""), "none")
		local src = fs.readFile("src/client/Controllers/TutorialController.luau")
		t.ok(not string.find(src, "duration = math.huge", 1, true), "no endless tutorial help")
		H.setMode("server")
	end)

	t.test("nit: event rows at the feed position, sentence case, no emoji / CLAIM IT / exclamation", function()
		H.setMode("client")
		local Events = H.require("src/client/Controllers/EventsClient")
		t.eq(Events.pillText("rushHour", 72), "Rush hour 1:12")
		t.eq(Events.pillText("doubleCash", 240.2), "Double cash 4:01")
		local v = Events.rowView("cashRain", 8)
		t.eq(v.label, "Cash rain at the plaza")
		t.eq(v.value, "0:08")
		t.eq(v.urgent, true, "red in the last 10 s, like GTA's timer bars")
		t.eq(Events.rowView("rushHour", 60).urgent, false)
		local drop = Events.hotDropView({ active = true, position = Vector3.new(0, 0, 0), endsAt = 160 }, 100, 1500)
		t.eq(drop.label, "Hot drop")
		t.eq(drop.value, "1:00")
		t.ok(string.find(drop.sub, "420 m", 1, true) ~= nil, "metres, never studs: " .. drop.sub)
		local count = Events.hotDropView({ startsAt = 110, position = Vector3.new(0, 0, 0) }, 100, 10)
		t.eq(count.label, "Hot drop lands in")
		t.ok(string.find(count.sub, "At the drop", 1, true) ~= nil)
		t.eq(Events.getBottom(), nil, "nothing at the top of the screen any more")
		for name, def in Events.Events do
			t.ok(emojiIn(def.label) == nil, name .. ": emoji")
			t.ok(not string.find(def.label, "!", 1, true), name .. ": exclamation")
			t.ok(string.upper(def.label) ~= def.label, name .. ": shouting")
		end
		local src = fs.readFile("src/client/Controllers/EventsClient.luau")
		t.ok(emojiIn(src) == nil, "EventsClient: no emoji")
		t.ok(not string.find(src, "CLAIM IT", 1, true), "no CLAIM IT")
		t.ok(string.find(src, "getFeedHost", 1, true) ~= nil, "rows live in the HUD's feed host (above the radar)")
		H.setMode("server")
	end)

	t.test("nit: the server's event copy is GTA feed copy (no emoji, shouting or CLAIM)", function()
		-- the hot drop marker, its effects and the event sounds belong to C5 vibe / C3 audio (DEROBLOX_AUDIT.md)
		for _, line in codeLines("src/server/Systems/EventService.luau") do
			if string.find(line, "announce(", 1, true) or string.find(line, "feed(", 1, true) then
				t.ok(emojiIn(line) == nil, "emoji: " .. line)
				t.ok(not string.find(line, "!", 1, true) or string.find(line, "~=", 1, true), "shouting: " .. line)
			end
			if string.find(line, "ActionText", 1, true) or string.find(line, "actionText", 1, true) then
				t.ok(not string.find(line, "CLAIM", 1, true), "CLAIM: " .. line)
			end
		end
	end)

	t.test("nit: vehicle name = model large + brand small, out after 3 s", function()
		H.setMode("client")
		local VC = H.require("src/client/Controllers/VehicleClient")
		t.eq(VC.VEHICLE_NAME_HOLD, 3)
		local m, b = VC.vehicleNameParts({ name = "Kronberg K8", brand = "Kronberg", model = "K8" })
		t.eq(m, "K8")
		t.eq(b, "Kronberg")
		m, b = VC.vehicleNameParts({ name = "Soccer Mom SUV" })
		t.eq(m, "Soccer Mom SUV", "a v1 name is never split into a fake brand")
		t.eq(b, "")
		m, b = VC.vehicleNameParts(nil)
		t.eq(m, "")
		t.eq(b, "")
		H.setMode("server")
	end)

	t.test("nit: the fallback gun counter is a shop counter, not a black block", function()
		local Shop = H.require("src/server/Systems/ShopService")
		local pieces = Shop._counterPieces()
		local names = {}
		for _, p in pieces do
			names[p[1]] = p
			t.ok(p[5] ~= Enum.Material.Neon, p[1] .. ": no neon")
		end
		for _, need in { "Counter", "Top", "Display", "Wall", "Rack", "Sign", "Awning" } do
			t.ok(names[need] ~= nil, "piece " .. need)
		end
		t.eq(names.Counter[7], true, "the counter collides (the prompt sits on it)")
		t.ok(names.Display[6] > 0, "glass display front")
		t.eq(Shop.FALLBACK_SIGN.guns, "FREEDOM ARMS")
		t.ok(emojiIn(Shop.FALLBACK_SIGN.gear) == nil)
	end)

	---------------------------------------------------------------------------------------------------------------------
	-- De-Robloxify (docs/v2/DEROBLOX_AUDIT.md)
	---------------------------------------------------------------------------------------------------------------------

	t.test("audit: CoreGui off, chat at GTA Online's spot, no bubbles over heads", function()
		H.setMode("client")
		local Core = H.require("src/client/UI/CoreGuiSetup")
		local off = table.concat(Core.DISABLED, ",")
		for _, kind in { "PlayerList", "Health", "EmotesMenu", "SelfView" } do
			t.ok(string.find(off, kind, 1, true) ~= nil, kind .. " off")
		end
		t.eq(Core.BUBBLE.Enabled, false, "VIBE row 17: no speech balloons")
		t.eq(Core.BUBBLE.TailVisible, false)
		t.eq(Core.CHAT_WINDOW.HorizontalAlignment, Enum.HorizontalAlignment.Left)
		t.eq(Core.CHAT_WINDOW.VerticalAlignment, Enum.VerticalAlignment.Center)
		t.eq(Core.chatEnabledFor(true), false, "the chat steps aside for left-side menus (bug 3)")
		t.eq(Core.chatEnabledFor(false), true)
		H.setMode("server")
	end)

	t.test(
		"audit: Esc bridge (VIBE row 20): first-minute close opens the pause MAP, one hint, never over a menu",
		function()
			H.setMode("client")
			local Core = H.require("src/client/UI/CoreGuiSetup")
			t.eq(Core.ESC_WINDOW, 60)
			t.eq(Core.escAction(5, 0, false, false), "pause")
			t.eq(Core.escAction(60, 0, true, false), "pause", "inclusive")
			t.eq(Core.escAction(61, 0, false, false), "hint", "later: just name the keys, once")
			t.eq(Core.escAction(61, 0, true, false), "none")
			t.eq(Core.escAction(5, 0, false, true), "none", "a menu of ours is up")
			t.eq(Core.escAction(0 / 0, 0, true, false), "none", "NaN")
			local hint = Core.escHint()
			t.ok(string.find(hint, "P", 1, true) ~= nil and string.find(hint, "M", 1, true) ~= nil, hint)
			t.ok(not string.find(hint, "!", 1, true))
			local hud = fs.readFile("src/client/Controllers/HUDController.luau")
			t.ok(string.find(hud, 'pcall(menu.openPause, "MAP")', 1, true) ~= nil, "HUDController wires openPause")
			H.setMode("server")
		end
	)

	t.test("audit: leaderboard boards are matte street billboards (no FredokaOne, emoji, gradients, neon)", function()
		local LB = H.require("src/server/Systems/LeaderboardService")
		t.eq(LB._rankText(1), "01")
		t.eq(LB._rankText(10), "10")
		t.eq(LB._footerText(true), "Global  ·  updated every 2 minutes")
		t.eq(LB._footerText(false), "This server  ·  live")
		local src = fs.readFile("src/server/Systems/LeaderboardService.luau")
		t.ok(emojiIn(src) == nil, "emoji")
		for _, bad in { "Fredoka", "UIGradient", "UICorner", "Material.Neon", "TOP EARNERS", "TOP THIEVES" } do
			t.ok(not string.find(src, bad, 1, true), "LeaderboardService: " .. bad)
		end
		t.ok(not string.find(src, "255, 52, 140", 1, true), "no hot pink")
	end)

	t.test("audit: the garage lock is a flat GTA instruction bar (VIBE row 18)", function()
		H.setMode("client")
		local GC = H.require("src/client/Controllers/GarageClient")
		local text, rule = GC._lockView("ready", nil)
		t.eq(text, "LOCK GARAGE")
		t.eq(rule, "TextDim")
		text, rule = GC._lockView("intruder", nil)
		t.eq(text, "INTRUDER  ·  LOCK GARAGE")
		t.eq(rule, "Red")
		text, rule = GC._lockView("locked", 272.2)
		t.eq(text, "LOCKED  4:33")
		t.eq(rule, "Blue")
		text = GC._lockView("cooldown", 11.4)
		t.eq(text, "LOCK READY IN 12 S")
		for _, s in { "ready", "intruder", "locked", "cooldown" } do
			local tx = GC._lockView(s, 30)
			t.ok(emojiIn(tx) == nil and not string.find(tx, "!", 1, true), s .. ": " .. tx)
		end
		local src = fs.readFile("src/client/Controllers/GarageClient.luau")
		t.ok(not string.find(src, "LOCK NOW!", 1, true), "no LOCK NOW!")
		t.ok(not string.find(src, "Kit.pop(btn", 1, true), "no pulsing")
		H.setMode("server")
	end)

	t.test("audit: config display names are grounded (no emoji, no shouting, no fantasy gadgets)", function()
		local Monetization = H.require("src/shared/Config/Monetization")
		for key, def in Monetization.Passes do
			t.ok(emojiIn(def.name) == nil, key .. " name")
			t.ok(not string.find(def.description, "EVERYONE", 1, true), key .. ": caps")
			t.ok(not string.find(def.description, "Ever.", 1, true), key .. ": kid copy")
		end
		for key, def in Monetization.Products do
			t.ok(not string.find(def.description, "EVERYONE", 1, true), key .. ": caps")
		end
		t.eq(Monetization.Passes.taser and Monetization.Passes.taser.name or "Stun Gun Pass", "Stun Gun Pass")
		for id, def in Economy.Upgrades do
			t.ok(not string.find(def.name, "Laser", 1, true), id .. ": " .. def.name)
			t.ok(emojiIn(def.name) == nil and emojiIn(def.description) == nil, id)
		end
	end)

	t.test("audit: the polish-owned client files carry no emoji, FredokaOne or neon", function()
		for _, path in
			{
				"src/client/UI/Phone.luau",
				"src/client/UI/Shard.luau",
				"src/client/UI/UIFocus.luau",
				"src/client/UI/CoreGuiSetup.luau",
				"src/client/UI/PromptStyle.luau",
				"src/client/UI/HelpText.luau",
				"src/client/UI/ListMenu.luau",
				"src/client/UI/PauseMenu.luau",
				"src/client/Controllers/EventsClient.luau",
				"src/client/Controllers/DeathScreenController.luau",
				"src/client/Controllers/GunShopUI.luau",
				"src/client/Controllers/TutorialController.luau",
				"src/client/Controllers/VehicleClient.luau",
			}
		do
			local src = fs.readFile(path)
			local cp = emojiIn(src)
			t.ok(cp == nil, ("%s: emoji U+%X"):format(path, cp or 0))
			t.ok(not string.find(src, "Fredoka", 1, true), path .. ": FredokaOne")
			t.ok(not string.find(src, "Material.Neon", 1, true), path .. ": neon")
		end
	end)

	---------------------------------------------------------------------------------------------------------------------
	-- De-Robloxify, round 2: the feed's voice, comic words, metres, ProximityPrompts as GTA help text
	---------------------------------------------------------------------------------------------------------------------

	t.test("audit: the feed never shouts (RichText.calm) and announcements use the feed blip", function()
		H.setMode("client")
		local RichText = H.require("src/client/UI/RichText")
		t.eq(RichText.calm("Your garage is full!"), "Your garage is full.")
		t.eq(RichText.calm("STOLEN!!!"), "STOLEN.")
		t.eq(RichText.calm("Really?!"), "Really?")
		t.eq(RichText.calm("Done.!"), "Done.")
		t.eq(RichText.calm("Nobody came\u{2026}!"), "Nobody came\u{2026}")
		t.eq(RichText.calm("Nice! You got it"), "Nice. You got it")
		t.eq(
			RichText.calm('<b>Ann</b> took it: <font color="#D6B563">Gold</font>!'),
			'<b>Ann</b> took it: <font color="#D6B563">Gold</font>.'
		)
		t.eq(RichText.calm("Already calm."), "Already calm.")
		t.eq(RichText.calm(nil), "")
		local Notif = H.require("src/client/Controllers/NotificationController")
		t.eq(Notif.announceSound("AirHorn"), "Notify", "no air horn for a server event")
		t.eq(Notif.announceSound("Horn"), "Notify")
		t.eq(Notif.announceSound("CashDrop"), "Notify")
		t.eq(Notif.announceSound(nil), "Notify")
		t.eq(Notif.announceSound(""), "", "silent stays silent")
		t.eq(Notif.announceSound("Notify"), "Notify")
		local src = fs.readFile("src/client/Controllers/NotificationController.luau")
		t.ok(string.find(src, "body = RichText.calm(text)", 1, true) ~= nil, "toasts are calmed")
		t.ok(string.find(src, "body = RichText.calm(richText)", 1, true) ~= nil, "the event feed is calmed")
		t.ok(string.find(src, "sound = NotificationController.announceSound(sound)", 1, true) ~= nil, "announce sound")
		H.setMode("server")
	end)

	t.test("audit: no comic KAPOW / BONK / ZAP words over the world, no sparkle emoji on paint labels", function()
		H.setMode("client")
		local Effects = H.require("src/client/Controllers/EffectsController")
		t.eq(Effects.COMIC_TEXT, false)
		local src = fs.readFile("src/client/Controllers/EffectsController.luau")
		t.ok(string.find(src, "if not EffectsController.COMIC_TEXT then", 1, true) ~= nil, "showComic is gated")
		for _, line in codeLines("src/client/Controllers/EffectsController.luau") do
			if string.find(line, "mut.Text", 1, true) then
				t.ok(emojiIn(line) == nil, "paint label: " .. line)
			end
		end
		H.setMode("server")
	end)

	t.test("audit: player-facing copy says metres, never studs", function()
		for id, def in Economy.Tools do
			t.ok(not string.find(string.lower(def.description), "stud", 1, true), id .. ": " .. def.description)
		end
		t.ok(string.find(Economy.Tools.taser.description, "17 metres", 1, true) ~= nil, "60 studs x 0.28")
	end)

	t.test("audit: help box hold rule only for the entry that asked for it", function()
		H.setMode("client")
		local HelpText = H.require("src/client/UI/HelpText")
		t.eq(HelpText.progressFor("prompt", "prompt", 0.4), 0.4)
		t.eq(HelpText.progressFor("prompt", "prompt", 1.7), 1, "clamped")
		t.eq(HelpText.progressFor("prompt", "prompt", -1), 0)
		t.eq(HelpText.progressFor("tutorial", "prompt", 0.4), nil, "another message is on screen")
		t.eq(HelpText.progressFor(nil, "prompt", 0.4), nil)
		t.eq(HelpText.progressFor("prompt", nil, 0.4), nil)
		t.eq(HelpText.progressFor("prompt", "prompt", nil), nil)
		t.eq(HelpText.progressFor("prompt", "prompt", 0 / 0), nil, "NaN")
		H.setMode("server")
	end)

	t.test("audit: PromptStyle action phrases read like GTA help text", function()
		H.setMode("client")
		local P = H.require("src/client/UI/PromptStyle")
		t.eq(P.actionPhrase("Hotwire"), "hotwire")
		t.eq(P.actionPhrase("Carjack"), "carjack")
		t.eq(P.actionPhrase("Get in"), "get in")
		t.eq(P.actionPhrase("Recover!"), "recover", "no shouting")
		t.eq(P.actionPhrase("Sell $1.2K"), "sell for $1.2K")
		t.eq(P.actionPhrase("Buy $12,500"), "buy for $12,500")
		t.eq(P.actionPhrase("UNLOCK $1.5K"), "unlock for $1.5K", "caps calmed, price kept")
		t.eq(P.actionPhrase("Gear Shop"), "open Gear Shop", "a place, not a verb")
		t.eq(P.actionPhrase("Browse"), "browse")
		t.eq(P.actionPhrase(""), "interact")
		t.eq(P.actionPhrase(nil), "interact")
		t.eq(P.objectName("FREEDOM ARMS"), "Freedom Arms", "a shouting sign in title case")
		t.eq(P.objectName("Halden Wren"), "Halden Wren")
		t.eq(P.objectName("Upgrades & Tools"), "Upgrades & Tools")
		t.eq(P.objectName(nil), "")
		t.eq(P.keyLabel("E", "keyboard"), "E")
		t.eq(P.keyLabel("ButtonX", "gamepad"), "X")
		t.eq(P.keyLabel("ButtonR1", "gamepad"), "RB")
		t.eq(P.keyLabel(nil, "keyboard"), "E")
		t.eq(P.keyLabel("Unknown", "gamepad"), "X")
		H.setMode("server")
	end)

	t.test("audit: PromptStyle help text (object once, one line per prompt, key caps, touch captions)", function()
		H.setMode("client")
		local P = H.require("src/client/UI/PromptStyle")
		local steal = { action = "Hotwire", object = "Halden Wren", hold = 1.8, key = "E", pad = "ButtonX" }
		t.eq(P.helpText({ steal }, "keyboard"), "<b>Halden Wren</b>\nHold <key>E</key> to hotwire.")
		t.eq(P.helpText({ steal }, "gamepad"), "<b>Halden Wren</b>\nHold <key>X</key> to hotwire.")
		t.eq(P.helpText({ steal }, "touch"), "<b>Halden Wren</b>\nHold <b>HOTWIRE</b>.")
		local drive = { action = "Drive", object = "Kronberg K8", hold = 0, key = "E", pad = "ButtonX" }
		local sell = { action = "Sell $4,250", object = "Kronberg K8", hold = 1, key = "F", pad = "ButtonY" }
		t.eq(
			P.helpText({ drive, sell }, "keyboard"),
			"<b>Kronberg K8</b>\nPress <key>E</key> to drive.\nHold <key>F</key> to sell for $4,250.",
			"one object line for both prompts"
		)
		local shop = { action = "Browse", object = "FREEDOM ARMS", hold = 0, key = "E" }
		t.eq(P.helpText({ shop }, "keyboard"), "<b>Freedom Arms</b>\nPress <key>E</key> to browse.")
		t.eq(P.helpText({}, "keyboard"), nil)
		local many = {}
		for i = 1, 5 do
			many[i] = { action = "Drive", object = "Car " .. i, hold = 0, key = "E" }
		end
		local text = P.helpText(many, "keyboard")
		local _, lines = string.gsub(text, "to drive", "")
		t.eq(lines, P.MAX_LINES, "at most MAX_LINES instructions")
		local evil = { action = "<b>Hack</b>", object = "<font>X</font>", hold = 0, key = "E" }
		local safe = P.helpText({ evil }, "keyboard")
		t.ok(not string.find(safe, "<font>", 1, true), "object text is escaped: " .. safe)
		for _, e in { steal, drive, sell, shop } do
			local s = P.helpText({ e }, "keyboard")
			t.ok(emojiIn(s) == nil and not string.find(s, "!", 1, true), s)
		end
		H.setMode("server")
	end)

	t.test(
		"audit: PromptStyle touch buttons sit in the right-hand cluster, clear of every other touch button",
		function()
			H.setMode("client")
			local P = H.require("src/client/UI/PromptStyle")
			local HudLayout = H.require("src/client/UI/HudLayout")
			for _, size in { { 1280, 720 }, { 844, 390 }, { 1024, 768 }, { 2000, 900 } } do
				local L = HudLayout.compute(size[1], size[2], true)
				local jump = HudLayout.jumpButton(L.w, L.h, 1)
				for _, driving in { false, true } do
					local rects = P.touchRects(L, 3, driving)
					t.eq(#rects, 3)
					for i, r in rects do
						local where = ("%dx%d driving=%s #%d"):format(size[1], size[2], tostring(driving), i)
						t.ok(HudLayout.inside(r, L.w, L.h), where .. ": on screen")
						t.ok(r.x >= L.w * 0.5, where .. ": right half (the thumbstick owns the left)")
						-- on foot only: the driving cluster (NITRO / DRIFT) already owns the jump button's corner in a car
						t.ok(driving or not HudLayout.overlaps(r, jump), where .. ": clear of the jump button")
						for name, b in L.buttons do
							local relevant = if driving
								then name ~= "phone" and name ~= "map"
								else name == "phone" or name == "map"
							if relevant then
								t.ok(not HudLayout.overlaps(r, b), where .. ": clear of " .. name)
							end
						end
						for j, other in rects do
							if j ~= i then
								t.ok(not HudLayout.overlaps(r, other), where .. ": clear of prompt " .. j)
							end
						end
					end
				end
			end
			t.eq(#P.touchRects(nil, 2, false), 2, "no layout: still placed")
			t.eq(#P.touchRects({}, 0, false), 0)
			H.setMode("server")
		end
	)

	t.test("audit: PromptStyle hold fill, kill switch and wiring", function()
		H.setMode("client")
		local P = H.require("src/client/UI/PromptStyle")
		t.near(P.holdFraction(10, 2, 11), 0.5, 1e-9)
		t.eq(P.holdFraction(10, 2, 13), 1)
		t.eq(P.holdFraction(10, 2, 9), 0)
		t.eq(P.holdFraction(10, 0, 10), 1, "a press fills at once")
		t.eq(P.holdFraction(10, 0 / 0, 10), 1)
		t.eq(P.ENABLED, true)
		t.eq(P.DEFAULT_LAYER, "ProximityPrompts")
		local core = fs.readFile("src/client/UI/CoreGuiSetup.luau")
		t.ok(string.find(core, "PromptStyle.start", 1, true) ~= nil, "CoreGuiSetup starts PromptStyle")
		local hud = fs.readFile("src/client/Controllers/HUDController.luau")
		t.ok(string.find(hud, "progress = HUDController.helpProgress", 1, true) ~= nil, "HUD passes the hooks")
		t.ok(string.find(hud, "function HUDController.helpProgress", 1, true) ~= nil)
		-- input is never ours: the prompt keys stay the engine's, the touch button only holds / releases
		local src = fs.readFile("src/client/UI/PromptStyle.luau")
		t.ok(string.find(src, "InputHoldBegin", 1, true) ~= nil and string.find(src, "InputHoldEnd", 1, true) ~= nil)
		t.ok(not string.find(src, "KeyboardKeyCode =", 1, true), "never rebinds a prompt key")
		t.ok(emojiIn(src) == nil)
		-- nothing else in the client styles prompts (one owner)
		for _, path in
			{
				"src/client/Controllers/EffectsController.luau",
				"src/client/Controllers/DealershipClient.luau",
				"src/client/Controllers/VehicleClient.luau",
			}
		do
			t.ok(not string.find(fs.readFile(path), "ProximityPromptStyle", 1, true), path)
		end
		H.setMode("server")
	end)
end
