--!nocheck
-- UI v2 review fixes: the touch feed under the help box, the phone-open layout (cash / stars / delivery timer stay
-- visible), the touch bottom sheet and its scrolling / tap rules, the help-text fade race, the streamer-mode way back,
-- touch phone sizes, the cab flow (client rules + the server's GoHome charge), detail-pane rebuild signatures and the
-- STATS player list.
return function(t)
	local H = t.H
	local Instance = H.roblox.Instance
	local Vector3 = H.roblox.Vector3
	H.setMode("client")
	local HudLayout = H.require("src/client/UI/HudLayout")
	local HelpText = H.require("src/client/UI/HelpText")
	local ListMenu = H.require("src/client/UI/ListMenu")
	local Phone = H.require("src/client/UI/Phone")
	local Shard = H.require("src/client/UI/Shard")
	local HUD = H.require("src/client/Controllers/HUDController")
	local PhoneC = H.require("src/client/Controllers/PhoneController")
	local Menu = H.require("src/client/Controllers/MenuController")
	local Waypoint = H.require("src/client/Controllers/WaypointController")
	H.setMode("server")
	local Economy = H.require("src/shared/Config/Economy")
	local PlotService = H.require("src/server/Systems/PlotService")

	local DESKTOP = { { 1280, 720 }, { 1920 / 1.5, 1080 / 1.5 }, { 1280, 960 }, { 1536, 720 }, { 1280, 800 } }
	local TOUCH =
		{ { 1042, 461 }, { 1111, 419 }, { 926, 443 }, { 1172, 380 }, { 1280, 720 }, { 1440, 900 }, { 980, 500 } }
	-- the tallest help box we expect on touch: four wrapped lines of 18 px text plus padding
	local HELP_MAX_TOUCH = 4 * 20 + 20

	local function overlaps(a, b)
		return HudLayout.overlaps(a, b)
	end

	-- Touch feed vs help ----------------------------------------------------------------------------------------------
	t.test("HudLayout.feedTop: on touch the feed stacks under the help box and never covers it", function()
		for _, c in TOUCH do
			local w, h = c[1], c[2]
			local tag = (" at %dx%d"):format(w, h)
			local L = HudLayout.compute(w, h, true)
			t.eq(HudLayout.feedTop(L, 0), L.help.y, "no help: the feed takes its place" .. tag)
			for _, helpH in { 46, 70, HELP_MAX_TOUCH } do
				local help = HudLayout.rect(L.help.x, L.help.y, L.help.w, helpH)
				local y = HudLayout.feedTop(L, helpH)
				local feed = HudLayout.rect(L.feed.x, y, L.feed.w, 60 * L.feedMax + 4)
				t.ok(not overlaps(help, feed), ("help %d vs feed%s"):format(helpH, tag))
				t.ok(y >= help.y + help.h, "feed below the help box" .. tag)
				t.ok(HudLayout.inside(feed, w, h), "two feed cards still fit" .. tag)
				t.ok(not overlaps(feed, L.radar) and not overlaps(feed, L.bars), "feed clear of the radar" .. tag)
				t.ok(not overlaps(help, L.radar) and not overlaps(help, L.bars), "help clear of the radar" .. tag)
			end
			t.eq(HudLayout.feedTop(L, 0 / 0), L.help.y, "NaN height reads as hidden")
		end
		local D = HudLayout.compute(1280, 720, false)
		t.eq(HudLayout.feedTop(D, 80), D.feed.y, "desktop feed stays above the radar")
	end)

	-- Phone open ------------------------------------------------------------------------------------------------------
	t.test(
		"HudLayout.withPhone (touch): cash, stars and ammo step left of the phone; the top-centre column follows",
		function()
			for _, c in TOUCH do
				local w, h = c[1], c[2]
				local tag = (" at %dx%d"):format(w, h)
				local L = HudLayout.withPhone(HudLayout.compute(w, h, true))
				for _, k in { "stars", "cash", "delta", "ammo", "arrest" } do
					t.ok(not overlaps(L[k], L.phone), k .. " clear of the phone" .. tag)
					t.ok(HudLayout.inside(L[k], w, h), k .. " on screen" .. tag)
					t.ok(not overlaps(L[k], L.radar), k .. " clear of the radar" .. tag)
				end
				local top = { "objective", "radio", "timers" }
				for _, a in top do
					t.ok(HudLayout.inside(L[a], w, h), a .. " on screen" .. tag)
					t.ok(not overlaps(L[a], L.radar), a .. " clear of the radar" .. tag)
					for _, b in { "stars", "cash", "delta", "ammo", "arrest" } do
						t.ok(not overlaps(L[a], L[b]), ("%s vs %s%s"):format(a, b, tag))
					end
				end
			end
			-- a tablet's phone never reaches the right-hand block: nothing moves
			local tab = HudLayout.compute(1440, 900, true)
			local open = HudLayout.withPhone(tab)
			t.eq(open.cash.x, tab.cash.x, "tablet keeps the block where it is")
		end
	)

	t.test(
		"HudLayout.withPhone (desktop): the delivery timer moves left of the phone, clear of the objective",
		function()
			for _, c in DESKTOP do
				local w, h = c[1], c[2]
				local tag = (" at %dx%d"):format(w, h)
				local base = HudLayout.compute(w, h, false)
				local L = HudLayout.withPhone(base)
				for _, k in { "timers", "timersDriving" } do
					t.ok(not overlaps(L[k], L.phone), k .. " clear of the phone" .. tag)
					t.ok(not overlaps(L[k], L.objective), k .. " clear of the objective line" .. tag)
					t.ok(HudLayout.inside(L[k], w, h), k .. " on screen" .. tag)
				end
				for _, k in { "stars", "cash", "delta", "ammo" } do
					t.ok(not overlaps(L[k], L.phone), k .. " clear of the phone" .. tag)
				end
				t.eq(L.cash.x, base.cash.x, "desktop cash does not move" .. tag)
			end
		end
	)

	-- Driving phone button ----------------------------------------------------------------------------------------------
	t.test("HudLayout: the touch PHONE button joins the driving cluster without covering anything", function()
		for _, c in TOUCH do
			local w, h = c[1], c[2]
			local tag = (" at %dx%d"):format(w, h)
			local L = HudLayout.compute(w, h, true)
			local p = L.buttons.phoneDriving
			t.ok(p ~= nil, "phoneDriving" .. tag)
			t.ok(p.x >= w * 0.4, "right of the thumbstick zone" .. tag)
			t.ok(p.w >= 56 and p.h >= 56, "as big as the on-foot PHONE button" .. tag)
			for _, k in { "nitro", "drift", "horn", "exit", "radio", "spikes" } do
				t.ok(not overlaps(p, L.buttons[k]), "vs " .. k .. tag)
			end
			for _, k in { "stars", "cash", "delta", "ammo", "arrest", "speed", "driftText", "timers", "radio" } do
				t.ok(not overlaps(p, L[k]), "vs " .. k .. tag)
			end
		end
	end)

	-- Touch bottom sheet --------------------------------------------------------------------------------------------------
	t.test("HudLayout touch sheet: header, three rows, description and Back / Select all fit", function()
		local S = HudLayout.SHEET
		t.eq(HudLayout.sheetHeight(0), S.header + S.sub + S.rule + S.desc + S.hints)
		t.eq(HudLayout.sheetRows(HudLayout.sheetHeight(5)), 5)
		t.eq(HudLayout.sheetRows(10), S.minRows, "never fewer than the minimum")
		for _, c in TOUCH do
			local w, h = c[1], c[2]
			local tag = (" at %dx%d"):format(w, h)
			local L = HudLayout.compute(w, h, true)
			local rows = HudLayout.sheetRows(L.list.h)
			t.ok(rows >= 3, "at least three rows" .. tag)
			t.ok(HudLayout.sheetHeight(rows) <= L.list.h, "everything fits the sheet" .. tag)
			t.ok(L.list.h >= math.floor(h * 0.42 + 0.5) - 1 or L.list.h == h - 40, "about 40% H or more" .. tag)
			t.ok(HudLayout.inside(L.list, w, h), "sheet on screen" .. tag)
		end
	end)

	t.test("HudLayout.helpBesideList: the desktop help box steps right of an open list menu", function()
		for _, c in DESKTOP do
			local w, h = c[1], c[2]
			local L = HudLayout.compute(w, h, false)
			local r = HudLayout.helpBesideList(L)
			local list = HudLayout.rect(L.list.x, L.list.y, L.list.w, 600)
			t.ok(not overlaps(r, list), "help clear of the list")
			t.ok(HudLayout.inside(HudLayout.rect(r.x, r.y, r.w, 120), w, h), "help on screen")
			t.ok(not overlaps(HudLayout.rect(r.x, r.y, r.w, 120), L.stars), "help clear of the stars")
			local wide = HudLayout.helpBesideList(L, 360)
			t.eq(wide.x, L.list.x + 360 + 10, "a wider list pushes it further")
		end
	end)

	-- List menu touch rules -------------------------------------------------------------------------------------------
	t.test("ListMenu.scrollToShow keeps the selected row in the scrolled window", function()
		t.eq(ListMenu.scrollToShow(1, 40, 120, 0), 0, "first row at the top")
		t.eq(ListMenu.scrollToShow(3, 40, 120, 0), 0, "already visible")
		t.eq(ListMenu.scrollToShow(4, 40, 120, 0), 40, "one row below: scroll one row")
		t.eq(ListMenu.scrollToShow(9, 40, 120, 0), 240, "far below: the row ends at the bottom")
		t.eq(ListMenu.scrollToShow(2, 40, 120, 200), 40, "above the window: the row goes to the top")
		t.eq(ListMenu.scrollToShow(6, 40, 120, 120), 120, "inside: keep the scroll")
		t.eq(ListMenu.scrollToShow(0, 40, 120, 80), 80, "no selection: keep the scroll")
	end)

	t.test("ListMenu.tapAction: the first tap selects, a tap on the selected row acts", function()
		local items = { { id = "a", label = "A" }, { separator = true, label = "S" }, { id = "b", label = "B" } }
		t.eq(ListMenu.tapAction(items, 3, 1), "select", "no buying without seeing the description first")
		t.eq(ListMenu.tapAction(items, 1, 1), "activate")
		t.eq(ListMenu.tapAction(items, 2, 1), "none", "separators do nothing")
		t.eq(ListMenu.tapAction(items, 9, 1), "none", "out of range")
	end)

	t.test("ListMenu.openScreens starts empty and the HUD can subscribe", function()
		local count, widest = ListMenu.openScreens()
		t.eq(count, 0)
		t.eq(widest, 0)
		t.ok(ListMenu.ScreenListsChanged ~= nil and ListMenu.ScreenListsChanged.Connect ~= nil)
	end)

	-- Help text fade race ------------------------------------------------------------------------------------------------
	t.test("HelpText.fadeAction: a message during the fade-out fades back in", function()
		t.eq(HelpText.fadeAction(false, false, true), "in", "hidden box fades in")
		t.eq(HelpText.fadeAction(true, true, true), "resume", "still fading out: fade back in")
		t.eq(HelpText.fadeAction(true, false, true), "none", "already shown: only the text changes")
		t.eq(HelpText.fadeAction(true, false, false), "out")
		t.eq(HelpText.fadeAction(false, false, false), "out")
	end)

	-- HUD -------------------------------------------------------------------------------------------------------------------
	t.test("HUD.starLook matches starVisual (tuple form for the per-frame loop)", function()
		for i = 1, 5 do
			for _, seen in { true, false } do
				for _, tt in { 0, 0.1, 0.4, 0.8 } do
					local sprite, color, transparency = HUD.starLook(i, 3, seen, tt)
					local v = HUD.starVisual(i, 3, seen, tt)
					t.ok(v.sprite == sprite and v.color == color and v.transparency == transparency)
				end
			end
		end
	end)

	t.test("HUD.showHudToggle: streamer mode on touch always has a way back", function()
		t.eq(HUD.showHudToggle(true, false, false, true), true, "streamer mode on touch")
		t.eq(HUD.showHudToggle(true, false, false, false), false, "desktop has P / B")
		t.eq(HUD.showHudToggle(false, false, false, true), false, "HUD on")
		t.eq(HUD.showHudToggle(true, true, false, true), false, "photo mode has its own Exit")
		t.eq(HUD.showHudToggle(true, false, true, true), false, "the pause menu has its own close")
		t.ok(typeof(HUD.currentHelp) == "function", "VehicleClient checks the controls help is on screen")
	end)

	-- Phone sizes --------------------------------------------------------------------------------------------------------
	t.test("Phone.metrics: touch text >= 11.5 real px, rows / soft keys >= 30 real px, the grid fits", function()
		local screenH = HudLayout.PHONE.h - 38
		for _, c in TOUCH do
			local L = HudLayout.compute(c[1], c[2], true)
			local real = 0.72 * L.phoneScale
			local M = Phone.metrics(true, real)
			local tag = (" at %dx%d"):format(c[1], c[2])
			if real >= 11.5 / 17 then
				for _, k in { "label", "sub", "value", "paragraph", "caption", "status" } do
					t.ok(M[k] * real >= 11.5 - 1e-6, ("%s %d -> %.1f real px%s"):format(k, M[k], M[k] * real, tag))
				end
			end
			t.ok(M.row * real >= 30 - 1e-6 or M.row >= 44, "row tall enough" .. tag)
			t.ok(M.softKey * real >= 30 - 1e-6 or M.softKey >= 44, "soft key tall enough" .. tag)
			t.ok(
				44 + 4 + 2 * M.tilePitch + M.tileH <= screenH - M.keyBar + 1e-6,
				"3 x 3 grid above the soft keys" .. tag
			)
			t.ok(6 + M.icon + 2 + M.caption + 4 <= M.tileH + 2, "icon + caption inside a tile" .. tag)
			t.ok(M.rowSub > M.row, "two-line rows are taller")
		end
		local D = Phone.metrics(false, 1)
		t.eq(D.label, 11, "desktop keeps the GTA-small phone")
		t.eq(D.row, 26)
		t.ok(44 + 4 + 2 * D.tilePitch + D.tileH <= screenH - D.keyBar + 1e-6, "desktop grid fits")
		t.ok(Phone.sizes() ~= nil, "sizes() before the phone is built")
	end)

	-- Cab ---------------------------------------------------------------------------------------------------------------
	t.test("PhoneController.cabState: stunned and down are refused before the server is asked", function()
		local base = {
			hasPlot = true,
			alive = true,
			wanted = 0,
			driving = false,
			stunned = false,
			inOwnGarage = false,
			cooldownLeft = 0,
			cash = 1000,
			fee = 150,
		}
		local function with(over)
			local c = table.clone(base)
			for k, v in over do
				c[k] = v
			end
			return c
		end
		t.eq(PhoneC.cabState(base), "ready")
		t.eq(PhoneC.cabState(with({ stunned = true })), "stunned")
		t.eq(PhoneC.cabState(with({ alive = false, wanted = 2 })), "down", "dead first")
		t.eq(PhoneC.cabState(with({ stunned = true, wanted = 1 })), "wanted", "the cops are the bigger problem")
		t.eq(PhoneC.cabState(with({ stunned = true, driving = true })), "driving")
		t.eq(PhoneC.cabState(with({ stunned = nil, alive = nil })), "ready", "missing fields read as fine")
		for _, state in { "ready", "noplot", "down", "wanted", "driving", "stunned", "home", "cooldown", "broke" } do
			t.ok(typeof(PhoneC.CAB_REPLY[state]) == "string", "reply for " .. state)
			t.ok(not PhoneC.CAB_REPLY[state]:find("!", 1, true), "no exclamation marks: " .. state)
		end
		-- a ride is the server's word (the CabRides counter), never a guess from the character's movement
		t.ok(PhoneC.cabConfirmed(nil, 1), "first ride")
		t.ok(PhoneC.cabConfirmed(3, 4), "next ride")
		t.ok(not PhoneC.cabConfirmed(4, 4), "nothing new (a respawn / fall / fling)")
		t.ok(not PhoneC.cabConfirmed(nil, nil), "never confirmed")
		t.ok(not PhoneC.cabConfirmed(2, "3"), "junk")
		t.eq(PlotService.GO_HOME_COOLDOWN, Economy.CAB_COOLDOWN, "one cooldown, shared by server and phone")
	end)

	t.test("PlotService GoHome: charges the cab fee only on a ride, refuses with a notice otherwise", function()
		local fee = Economy.CAB_FEE
		t.ok(fee > 0, "the cab costs money")
		local clock = 1000
		local notices, moves, spent, streams, refunded = {}, 0, 0, 0, 0
		local cash = 1000
		local duringStream: (() -> ())? = nil
		PlotService._setGoHomeHooks({
			clock = function()
				return clock
			end,
			plotOf = function()
				return 1
			end,
			notify = function(_p, kind, text)
				table.insert(notices, { kind = kind, text = text })
			end,
			sound = function() end,
			move = function()
				moves += 1
			end,
			-- the garage streams in before the drop-off (a yield in the game): the test may change things meanwhile
			stream = function()
				streams += 1
				if duringStream then
					duringStream()
				end
			end,
			system = function(name)
				if name == "DataService" then
					return {
						spendCash = function(_p, amount)
							if cash < amount then
								return false
							end
							cash -= amount
							spent += amount
							return true
						end,
						addCash = function(_p, amount, reason)
							t.eq(reason, "refund")
							cash += amount
							refunded += amount
						end,
					}
				end
				return nil
			end,
		})
		local p = Instance.new("Player")
		local char = Instance.new("Model")
		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Parent = char
		local hum = Instance.new("Humanoid")
		hum.Parent = char
		hum.Health = 100
		p.Character = char
		local function last()
			return notices[#notices]
		end

		-- wanted / driving / stunned: refused, nothing charged, no cooldown
		p:SetAttribute("Wanted", 2)
		PlotService._onGoHome(p)
		t.ok(last() and last().text:find("cops", 1, true) ~= nil, "wanted notice")
		p:SetAttribute("Wanted", 0)
		p:SetAttribute("Driving", true)
		PlotService._onGoHome(p)
		t.ok(last().text:find("car", 1, true) ~= nil, "driving notice")
		p:SetAttribute("Driving", false)
		p:SetAttribute("Stunned", true)
		local before = #notices
		PlotService._onGoHome(p)
		t.eq(#notices, before + 1, "stunned now gets a notice too")
		p:SetAttribute("Stunned", false)
		t.eq(spent, 0, "nothing charged for refusals")
		t.eq(moves, 0, "no teleport for refusals")

		-- too poor: no teleport, no cooldown
		cash = fee - 1
		PlotService._onGoHome(p)
		t.eq(moves, 0, "no ride below the fare")
		t.eq(spent, 0)
		t.ok(last().text:find("costs", 1, true) ~= nil, "fare notice")

		-- the fee failure set no cooldown: with the money, the very next call rides
		cash = 1000
		PlotService._onGoHome(p)
		t.eq(moves, 1, "ride")
		t.eq(streams, 1, "streamed the garage in first")
		t.eq(spent, fee, "charged once")
		t.eq(cash, 1000 - fee)
		t.eq(p:GetAttribute("CabRides"), 1, "the ride is confirmed to the phone")

		-- cooldown: refused and free
		clock += PlotService.GO_HOME_COOLDOWN - 1
		PlotService._onGoHome(p)
		t.eq(moves, 1, "still on cooldown")
		t.eq(spent, fee, "the cooldown refusal is free")
		t.ok(last().text:find("free in", 1, true) ~= nil, "cooldown notice")
		clock += 2
		PlotService._onGoHome(p)
		t.eq(moves, 2, "next ride after the cooldown")
		t.eq(spent, 2 * fee)
		t.eq(p:GetAttribute("CabRides"), 2)

		-- spotted by a cop while the garage streams in: no ride, fare refunded, no cooldown, no confirmation
		clock += 100
		duringStream = function()
			p:SetAttribute("Wanted", 1)
		end
		PlotService._onGoHome(p)
		t.eq(moves, 2, "no drop-off for a wanted player")
		t.eq(refunded, fee, "fare refunded")
		t.eq(cash, 1000 - 2 * fee, "net: nothing charged")
		t.ok(last().text:find("refunded", 1, true) ~= nil, "refund notice")
		t.eq(p:GetAttribute("CabRides"), 2, "not confirmed")
		duringStream = nil
		p:SetAttribute("Wanted", 0)
		PlotService._onGoHome(p)
		t.eq(moves, 3, "the refused ride set no cooldown")

		-- dead: silent no-op
		clock += 100
		hum.Health = 0
		local spentBefore = spent
		PlotService._onGoHome(p)
		t.eq(moves, 3, "no ride while dead")
		t.eq(spent, spentBefore)

		PlotService._setGoHomeHooks(nil)
		p:Destroy()
		char:Destroy()
	end)

	-- Pause detail pane + players ------------------------------------------------------------------------------------------
	t.test("MenuController.detailSignature: the pane rebuilds only when what it shows changes", function()
		local item = { id = "gift1", label = "5 min  $500", value = "4:59", disabled = true }
		local a = Menu.detailSignature(item, "x")
		t.eq(Menu.detailSignature(table.clone(item), "x"), a, "same row, same pane")
		local ticked = table.clone(item)
		ticked.value = "4:58"
		t.ok(Menu.detailSignature(ticked, "x") ~= a, "the shown value changed")
		t.ok(Menu.detailSignature(item, "y") ~= a, "hidden state (a confirm) changed")
		local opt = { id = "music", label = "Music", optionIndex = 1 }
		local flipped = table.clone(opt)
		flipped.optionIndex = 2
		t.ok(Menu.detailSignature(opt) ~= Menu.detailSignature(flipped), "a setting flipped")
		t.eq(Menu.detailSignature(nil), "")
	end)

	t.test("MenuController.playerRows: the STATS player list (you first, then the richest)", function()
		local rows = Menu.playerRows({
			{ userId = 2, name = "Bea", cash = 500, steals = 1, rebirths = 0, wanted = 0, isYou = false },
			{ userId = 3, name = "Cal", cash = 9000, steals = 4, rebirths = 1, wanted = 3, isYou = false },
			{ userId = 1, name = "Me", cash = 10, steals = 0, rebirths = 0, wanted = 0, isYou = true },
		})
		t.eq(#rows, 3)
		t.eq(rows[1].label, "Me  (you)")
		t.eq(rows[2].label, "Cal", "richest next")
		t.eq(rows[3].label, "Bea")
		t.eq(rows[2].id, "player:3")
		t.eq(rows[2].data.section, "players")
		t.ok(rows[2].value:find("9", 1, true) ~= nil, "cash shown")
		t.eq(#Menu.playerRows({}), 0)
	end)

	-- Misc --------------------------------------------------------------------------------------------------------------------
	t.test("Shard black curtain lifts itself; waypoint flags match the style table", function()
		t.ok(Shard.MAX_BLACK_SECONDS > 0 and Shard.MAX_BLACK_SECONDS <= 10, "a forgotten curtain lifts within seconds")
		for _, tracked in { true, false } do
			for _, d in { 0, 4, 120, 2000, 0 / 0 } do
				local corona, chevron, height = Waypoint.markerFlags(tracked, d)
				local s = Waypoint.markerStyle(tracked, d)
				t.ok(s.corona == corona and s.chevron == chevron and s.chevronHeight == height)
			end
		end
	end)
end
