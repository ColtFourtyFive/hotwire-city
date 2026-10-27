--!nocheck
-- UI v2 pure logic, part 2: HUD stars / cash / bars, the help-text queue, the GTA list menu, phone grid, shard styles,
-- pause tabs, radar edge clamping, phone cab rules + inbox, menu routing, feed merging, and the generated UIAssets
-- block against assets/ui/manifest.json + cells.json.
return function(t)
	local H = t.H
	local fs = require("@lune/fs")
	local serde = require("@lune/serde")
	H.setMode("client")
	local HUD = H.require("src/client/Controllers/HUDController")
	local HelpText = H.require("src/client/UI/HelpText")
	local ListMenu = H.require("src/client/UI/ListMenu")
	local Phone = H.require("src/client/UI/Phone")
	local Shard = H.require("src/client/UI/Shard")
	local PauseMenu = H.require("src/client/UI/PauseMenu")
	local Theme = H.require("src/client/UI/Theme")
	local Minimap = H.require("src/client/Controllers/MinimapController")
	local PhoneC = H.require("src/client/Controllers/PhoneController")
	local Menu = H.require("src/client/Controllers/MenuController")
	local Notif = H.require("src/client/Controllers/NotificationController")
	local UIAssets = H.require("src/shared/Config/UIAssets")
	H.setMode("server")
	local C = Theme.Colors

	-- HUD ---------------------------------------------------------------------------------------------------------
	t.test("HUD.starVisual: filled white while seen, white/grey flash while searching, hollow slots", function()
		local seen = HUD.starVisual(1, 3, true, 0.5)
		t.eq(seen.sprite, "hud.star_fill")
		t.ok(seen.color == C.Text and seen.transparency == 0)
		local hollow = HUD.starVisual(4, 3, true, 0)
		t.eq(hollow.sprite, "hud.star_hollow")
		t.eq(hollow.transparency, 0.3)
		local phaseA = HUD.starVisual(2, 3, false, 0.1)
		local phaseB = HUD.starVisual(2, 3, false, 0.45)
		t.ok(phaseA.color ~= phaseB.color, "searching stars alternate")
		t.ok(phaseA.color == C.TextDim or phaseB.color == C.TextDim, "one phase is grey")
		t.eq(HUD.starVisual(5, 3, false, 0.45).sprite, "hud.star_hollow", "unfilled slots never flash")
	end)

	t.test("HUD cash text: commas, never K / M; signed deltas; merged gains", function()
		t.eq(HUD.formatCash(15150), "$15,150")
		t.eq(HUD.formatCash(0), "$0")
		t.eq(HUD.formatCash(1234567), "$1,234,567")
		t.eq(HUD.formatCash(-500), "-$500")
		t.eq(HUD.formatCash(0 / 0), "$0")
		t.eq(HUD.formatDelta(700), "+$700")
		t.eq(HUD.formatDelta(-5000), "-$5,000")
		local v, merged = HUD.mergeDelta(100, 10, 50, 10.5)
		t.eq(v, 150)
		t.ok(merged, "same direction inside the window merges")
		v, merged = HUD.mergeDelta(100, 10, -50, 10.5)
		t.eq(v, -50)
		t.ok(not merged, "a loss starts a new delta")
		v, merged = HUD.mergeDelta(100, 10, 50, 12)
		t.eq(v, 50)
		t.ok(not merged, "outside the window starts a new delta")
		v, merged = HUD.mergeDelta(0, 0, 25, 0)
		t.eq(v, 25)
		t.ok(not merged)
	end)

	t.test("HUD.barFractions: health / armour / ability, clamped, junk-safe", function()
		local h, a, ab = HUD.barFractions(50, 100, 25, 100, 0.5)
		t.near(h, 0.5, 1e-9)
		t.near(a, 0.25, 1e-9)
		t.near(ab, 0.5, 1e-9)
		h, a, ab = HUD.barFractions(nil, nil, nil, nil, nil)
		t.eq(h, 1, "unknown health reads full")
		t.eq(a, 0, "no armour attribute reads empty")
		t.eq(ab, 1)
		h, a = HUD.barFractions(250, 100, 80, 0)
		t.eq(h, 1, "clamped")
		t.near(a, 0.8, 1e-9, "max 0 -> /100")
		h = HUD.barFractions(0 / 0, 100)
		t.eq(h, 1, "NaN")
		local _, _, neg = HUD.barFractions(10, 100, 0, 100, -3)
		t.eq(neg, 0)
	end)

	-- Help text queue ------------------------------------------------------------------------------------------------
	t.test("HelpText.Queue: one at a time, dedupe, urgent jumps, expiry, persistent entries", function()
		local Q = HelpText.Queue
		local q = Q.new()
		t.ok(Q.push(q, { text = "first" }, 0), "shown")
		t.ok(not Q.push(q, { text = "second" }, 1), "queued behind")
		t.eq(Q.current(q).text, "first")
		t.ok(not Q.push(q, { text = "first" }, 2), "same text dedupes (refreshes)")
		t.eq(#q.waiting, 1)
		t.ok(not Q.tick(q, 9), "8 s default not up yet (refreshed at 2)")
		t.ok(Q.tick(q, 10.1), "expired")
		t.eq(Q.current(q).text, "second")
		Q.push(q, { id = "x", text = "urgent", urgent = true }, 11)
		t.eq(Q.current(q).id, "x", "urgent jumps the queue")
		t.eq(q.waiting[1].text, "second", "the interrupted one goes back to the front")
		Q.clear(q, "x", 12)
		t.eq(Q.current(q).text, "second")
		Q.push(q, { id = "tut", text = "stay", duration = math.huge }, 13)
		Q.clear(q, nil, 14)
		t.eq(Q.current(q).id, "tut")
		t.ok(not Q.tick(q, 1e6), "math.huge never expires")
		t.ok(Q.push(q, { id = "tut", text = "changed" }, 15), "same id updates the text in place")
		t.eq(Q.current(q).text, "changed")
		Q.clear(q, "tut", 16)
		t.eq(Q.current(q), nil)
		t.ok(not Q.clear(q, nil, 17), "clearing an empty queue is a no-op")
	end)

	-- List menu -------------------------------------------------------------------------------------------------------
	t.test("ListMenu: wrap-around selection skips separators; counter; scroll window; option cycling", function()
		local items = {
			{ id = "a", label = "A" },
			{ separator = true, label = "" },
			{ id = "b", label = "B", disabled = true },
			{ id = "c", label = "C" },
		}
		t.eq(ListMenu.first(items), 1)
		t.eq(ListMenu.step(items, 1, 1), 3, "separator skipped; disabled rows can be highlighted")
		t.eq(ListMenu.step(items, 4, 1), 1, "wraps to the top")
		t.eq(ListMenu.step(items, 1, -1), 4, "wraps to the bottom")
		t.eq(ListMenu.step({}, 1, 1), 0)
		t.eq(ListMenu.step({ { separator = true } }, 1, 1), 0, "nothing selectable")
		t.eq(ListMenu.counter(items, 3), "2/3")
		t.eq(ListMenu.counter(items, 4), "3/3")
		t.eq(ListMenu.windowTop(1, 5, 10, 1), 1, "short list never scrolls")
		t.eq(ListMenu.windowTop(12, 20, 10, 1), 3, "scrolls down to keep the row visible")
		t.eq(ListMenu.windowTop(5, 20, 10, 3), 3, "keeps the window while the row is inside it")
		t.eq(ListMenu.windowTop(2, 20, 10, 8), 2, "scrolls up")
		t.eq(ListMenu.windowTop(20, 20, 10, 50), 11, "clamped to the end")
		t.eq(ListMenu.cycle(3, 3, 1), 1)
		t.eq(ListMenu.cycle(3, 1, -1), 3)
		t.eq(ListMenu.cycle(3, 0, 1), 2, "unset index starts from 1")
		t.eq(ListMenu.cycle(0, 1, 1), 0)
	end)

	-- Phone grid ------------------------------------------------------------------------------------------------------
	t.test("Phone 3x3 grid: cells and clamped arrow moves", function()
		local c, r = Phone.gridCell(1)
		t.ok(c == 1 and r == 1)
		c, r = Phone.gridCell(6)
		t.ok(c == 3 and r == 2)
		c, r = Phone.gridCell(7)
		t.ok(c == 1 and r == 3)
		t.eq(Phone.gridMove(9, 5, 1, 0), 6)
		t.eq(Phone.gridMove(9, 6, 1, 0), 6, "no wrap across rows")
		t.eq(Phone.gridMove(9, 2, 0, 1), 5)
		t.eq(Phone.gridMove(9, 8, 0, 1), 8, "bottom edge")
		t.eq(Phone.gridMove(8, 6, 0, 1), 8, "short last row clamps to the last app")
		t.eq(Phone.gridMove(0, 1, 1, 0), 0)
		t.eq(Phone.gridMove(9, 99, -1, 0), 8, "out-of-range index clamps first")
	end)

	-- Shard ----------------------------------------------------------------------------------------------------------
	t.test("Shard styles: GTA words, colours and grading", function()
		local w = Shard.style("WASTED")
		t.eq(w.title, "wasted")
		t.ok(w.color == C.WastedRed and w.grade == true, "wasted is red with the desaturated grade")
		local b = Shard.style("busted")
		t.ok(b.title == "busted" and b.grade == true)
		t.eq(Shard.style("passed").title, "mission passed")
		t.eq(Shard.style("job").title, "job complete")
		t.ok(Shard.style("job").color == C.Yellow)
		local unknown = Shard.style("something")
		t.eq(unknown.title, "something", "unknown kinds use their own word")
		t.eq(Shard.style(nil).title, "")
		t.near(Shard.rowDelay(1), 0.6, 1e-9)
		t.near(Shard.rowDelay(3), 0.9, 1e-9, "rows 0.15 s apart")
		t.near(Shard.rowDelay(-4), 0.6, 1e-9)
	end)

	-- Pause menu ------------------------------------------------------------------------------------------------------
	t.test("PauseMenu: Q / E tab wrapping and the GTA frame proportions", function()
		t.eq(PauseMenu.nextTab(6, 6, 1), 1)
		t.eq(PauseMenu.nextTab(6, 1, -1), 6)
		t.eq(PauseMenu.nextTab(6, 3, 1), 4)
		t.eq(PauseMenu.nextTab(0, 1, 1), 0)
		local d = PauseMenu.frame(false)
		t.near(d.left, 0.16, 1e-9, "desktop content starts at 16% width")
		t.ok(d.title < d.tabs and d.tabs < d.top and d.top < d.bottom, "title, tabs, body stack downward")
		local m = PauseMenu.frame(true)
		t.ok(m.left < d.left and m.right > d.right, "touch uses (almost) the full width")
		t.eq(#Menu.PAUSE_TABS, 6)
		local ids = {}
		for _, tab in Menu.PAUSE_TABS do
			table.insert(ids, tab.id)
		end
		t.eq(table.concat(ids, ","), "MAP,JOBS,GARAGE,STATS,STORE,SETTINGS")
	end)

	-- Radar -----------------------------------------------------------------------------------------------------------
	t.test("Minimap edge clamping, district title case, POI colours", function()
		local x, y, out = Minimap.clampToRect(10, 10, -50, 50, -40, 40)
		t.ok(x == 10 and y == 10 and not out, "inside stays put")
		x, y, out = Minimap.clampToRect(200, 0, -50, 50, -40, 40)
		t.ok(out, "outside flagged")
		t.near(x, 50, 1e-6)
		t.near(y, 0, 1e-6)
		x, y = Minimap.clampToRect(100, 100, -50, 50, -40, 40)
		t.near(y, 40, 1e-6, "clamped along the ray to the nearer edge")
		t.near(x, 40, 1e-6)
		x, y = Minimap.clampToRect(-300, -60, -50, 50, -40, 40)
		t.near(x, -50, 1e-6)
		t.near(y, -10, 1e-6)
		t.eq(Minimap.titleCase("DOWNTOWN"), "Downtown")
		t.eq(Minimap.titleCase("port of hotwire"), "Port Of Hotwire")
		t.eq(Minimap.titleCase("o'neil HEIGHTS"), "O'neil Heights")
		local fallback = C.Gold
		t.ok(Minimap.poiColor("police", fallback) == C.Blue, "police HQ blue")
		t.ok(Minimap.poiColor("dealership", fallback) == C.Text, "shops white")
		t.ok(Minimap.poiColor("nope", fallback) == fallback)
	end)

	-- Phone: cab + inbox ----------------------------------------------------------------------------------------------
	t.test("PhoneController.cabState: the server's GoHome rules, in the order a player should hear them", function()
		local base = {
			hasPlot = true,
			wanted = 0,
			driving = false,
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
		t.eq(PhoneC.cabState(with({ hasPlot = false, wanted = 3 })), "noplot")
		t.eq(PhoneC.cabState(with({ wanted = 1, driving = true })), "wanted", "blocked while wanted >= 1")
		t.eq(PhoneC.cabState(with({ driving = true })), "driving")
		t.eq(PhoneC.cabState(with({ inOwnGarage = true })), "home")
		t.eq(PhoneC.cabState(with({ cooldownLeft = 4 })), "cooldown")
		t.eq(PhoneC.cabState(with({ cash = 149 })), "broke")
		t.eq(PhoneC.cabState(with({ cash = 150 })), "ready", "exact fare is enough")
		for state in { ready = 1, noplot = 1, wanted = 1, driving = 1, home = 1, cooldown = 1, broke = 1 } do
			t.ok(typeof(PhoneC.CAB_REPLY[state]) == "string", "dispatcher reply for " .. state)
		end
	end)

	t.test("PhoneController inbox: unread count, threads, latest per contact", function()
		local msgs = {
			{ id = 1, contact = "cab", body = "a", at = 0, read = true },
			{ id = 2, contact = "security", body = "b", at = 0, read = false },
			{ id = 3, contact = "cab", body = "c", at = 0, read = false },
		}
		t.eq(PhoneC.unread(msgs), 2)
		t.eq(PhoneC.unread({}), 0)
		local thread = PhoneC.threadOf(msgs, "cab")
		t.eq(#thread, 2)
		t.eq(thread[1].id, 1, "oldest first")
		local latest = PhoneC.latestByContact(msgs)
		t.eq(latest.cab.id, 3)
		t.eq(latest.security.id, 2)
	end)

	-- Menu routing + feed ---------------------------------------------------------------------------------------------
	t.test("MenuController: v1 menu names route to pause tabs / list / phone", function()
		t.eq(Menu.routeOf("GearShop").kind, "list")
		t.eq(Menu.routeOf("Store").tab, "STORE")
		t.eq(Menu.routeOf("Index").tab, "GARAGE")
		local daily = Menu.routeOf("Daily")
		t.ok(daily.tab == "JOBS" and daily.focus == "daily")
		local rebirth = Menu.routeOf("Rebirth")
		t.ok(rebirth.tab == "STATS" and rebirth.focus == "prestige", "Rebirth is Prestige under STATS")
		t.eq(Menu.routeOf("Codes").kind, "phone")
		t.eq(Menu.routeOf("nope"), nil)
		t.eq(Menu.dailyRowValue("claimed"), "CLAIMED")
		t.eq(Menu.dailyRowValue("ready"), "CLAIM")
		t.eq(Menu.dailyRowValue("next", "4:12:09"), "4:12:09")
		t.eq(Menu.dailyRowValue("next"), "TOMORROW")
		t.eq(Menu.dailyRowValue("locked"), "")
	end)

	t.test("NotificationController.mergeKey: explicit key, else title + plain body", function()
		t.eq(Notif.mergeKey({ key = "cash", title = "x" }), "cash")
		t.eq(Notif.mergeKey({ title = "Garage", body = "Car <y>stored</y>." }), "Garage|Car stored.")
		t.eq(Notif.mergeKey({ title = "Garage", body = "Car stored." }), "Garage|Car stored.", "tags ignored")
		t.eq(Notif.mergeKey(nil), "")
		t.eq(Notif.mergeKey({}), "|")
	end)

	-- Generated asset ids ---------------------------------------------------------------------------------------------
	t.test("UIAssets GENERATED block matches assets/ui/manifest.json + cells.json", function()
		local manifest = serde.decode("json", fs.readFile("assets/ui/manifest.json"))
		local cells = serde.decode("json", fs.readFile("assets/ui/cells.json"))
		local seen = 0
		for key, entry in manifest do
			local id = "rbxassetid://" .. string.format("%d", entry.assetId)
			local sheet = UIAssets.Sheets[key]
			if sheet then
				t.eq(sheet.image, id, "sheet " .. key)
			else
				t.eq(UIAssets.Images[key], id, "image " .. key)
			end
			t.ok(fs.isFile(entry.file), "png on disk: " .. entry.file)
			seen += 1
		end
		t.ok(seen >= 15, "every uploaded image is listed: " .. seen)
		for sheetName, sheet in UIAssets.Sheets do
			local src = cells[sheetName]
			t.ok(src ~= nil, "cells.json has " .. sheetName)
			for cell, r in sheet.cells do
				local want = src[cell]
				t.ok(
					want ~= nil and want[1] == r[1] and want[2] == r[2] and want[3] == r[3] and want[4] == r[4],
					sheetName .. "." .. cell .. " rect matches"
				)
			end
		end
		for _, key in UIAssets.LOADING do
			t.ok(UIAssets.Images[key] ~= nil and UIAssets.Images[key] ~= "", "loading panel " .. key)
		end
	end)
end
