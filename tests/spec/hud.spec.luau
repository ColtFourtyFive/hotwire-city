--!nocheck
-- HUDController + TutorialController pure logic: star fill/flash, cash trend, theft timer view, badges,
-- HOME button state, menu grid wrapping, tutorial state machine, target picking.
return function(t)
	local H = t.H
	local Vector3 = H.roblox.Vector3
	H.setMode("client")
	local HUD = H.require("src/client/Controllers/HUDController")
	local Tut = H.require("src/client/Controllers/TutorialController")
	local Economy = H.require("src/shared/Config/Economy")
	local EconomyMath = H.require("src/shared/Util/EconomyMath")
	H.setMode("server")

	-- Stars -------------------------------------------------------------------------------------------------------
	t.test("clampStars sanitizes", function()
		t.eq(HUD.clampStars(nil), 0)
		t.eq(HUD.clampStars("3"), 0)
		t.eq(HUD.clampStars(0 / 0), 0)
		t.eq(HUD.clampStars(-2), 0)
		t.eq(HUD.clampStars(2.6), 3)
		t.eq(HUD.clampStars(99), 5)
		t.eq(HUD.clampStars(4, 3), 3)
	end)

	t.test("starStates fill count matches stars", function()
		for stars = 0, 5 do
			local states = HUD.starStates(stars, nil)
			t.eq(#states, 5, "always 5 stars")
			local filled = 0
			for i, s in states do
				if s.filled then
					filled += 1
					t.ok(i <= stars, "filled stars are the leftmost")
				end
				t.ok(not s.changed, "first render never flashes")
			end
			t.eq(filled, stars, "filled count")
		end
	end)

	t.test("starStates flags gained and lost stars", function()
		local up = HUD.starStates(3, 1)
		t.ok(not up[1].changed and up[1].filled, "star 1 stays")
		t.ok(up[2].gained and up[3].gained, "stars 2-3 gained")
		t.ok(not up[4].changed and not up[4].filled, "star 4 untouched")
		local down = HUD.starStates(1, 4)
		t.ok(down[1].filled and not down[1].changed)
		for i = 2, 4 do
			t.ok(down[i].changed and not down[i].filled and not down[i].gained, "star " .. i .. " emptied")
		end
		t.ok(not down[5].changed)
		local same = HUD.starStates(2, 2)
		for _, s in same do
			t.ok(not s.changed)
		end
	end)

	-- Cash / theft ------------------------------------------------------------------------------------------------
	t.test("cashTrend", function()
		t.eq(HUD.cashTrend(100, nil), "none")
		t.eq(HUD.cashTrend(150, 100), "up")
		t.eq(HUD.cashTrend(50, 100), "down")
		t.eq(HUD.cashTrend(100.2, 100), "none")
	end)

	t.test("theftView text, fraction, urgency", function()
		local text, frac, urgent = HUD.theftView(1000 + 102, 1000, 150)
		t.eq(text, "1:42")
		t.near(frac, 102 / 150, 1e-6)
		t.ok(not urgent)
		text, frac, urgent = HUD.theftView(1000 + 9.2, 1000, 150)
		t.eq(text, "0:10", "rounds up so 0:00 only shows at the end")
		t.ok(urgent)
		text, frac = HUD.theftView(900, 1000, 150)
		t.eq(text, "0:00")
		t.eq(frac, 0)
		text = HUD.theftView(nil, 1000, 150)
		t.eq(text, "--:--")
	end)

	t.test("theftMode: delivery deadline vs dropped-car tow timer", function()
		local dropped, endsAt, total = HUD.theftMode({ active = true, endsAt = 500, dropped = false })
		t.eq(dropped, false)
		t.eq(endsAt, 500)
		t.eq(total, Economy.THEFT_TIME_LIMIT)
		dropped, endsAt, total = HUD.theftMode({ active = true, endsAt = 500, dropped = true, droppedEndsAt = 320 })
		t.eq(dropped, true, "knocked out of the car")
		t.eq(endsAt, 320, "the tow timer is the real deadline")
		t.eq(total, Economy.DROPPED_CAR_TIMEOUT)
		dropped, endsAt = HUD.theftMode({ active = true, endsAt = 500, dropped = true })
		t.eq(dropped, false, "dropped without a deadline falls back to the delivery timer")
		t.eq(endsAt, 500)
		dropped, endsAt = HUD.theftMode({ active = false, dropped = true, droppedEndsAt = 320 })
		t.eq(dropped, false, "inactive")
		t.eq(endsAt, nil)
		t.eq((HUD.theftMode(nil)), false)
		local _, nanEnds = HUD.theftMode({ active = true, endsAt = 0 / 0 })
		t.eq(nanEnds, nil, "NaN deadline")
		-- the dropped timer is always inside the urgent (red, pulsing) window
		local _, _, urgent = HUD.theftView(1000 + 12, 1000, Economy.DROPPED_CAR_TIMEOUT)
		t.ok(urgent)
	end)

	-- Badges ------------------------------------------------------------------------------------------------------
	t.test("playtimeClaimable", function()
		local first = Economy.PLAYTIME_REWARDS[1].minutes * 60
		t.ok(not HUD.playtimeClaimable(nil, 0))
		t.ok(not HUD.playtimeClaimable({ sessionSeconds = first - 5, claimed = {} }, 0))
		t.ok(HUD.playtimeClaimable({ sessionSeconds = first - 5, claimed = {} }, 6), "extrapolates elapsed time")
		t.ok(not HUD.playtimeClaimable({ sessionSeconds = first + 1, claimed = { ["1"] = true } }, 0))
		local second = Economy.PLAYTIME_REWARDS[2].minutes * 60
		t.ok(HUD.playtimeClaimable({ sessionSeconds = second, claimed = { ["1"] = true } }, 0))
	end)

	t.test("rebirthReady", function()
		local cost = EconomyMath.rebirthCost(0)
		t.ok(HUD.rebirthReady(cost, 0))
		t.ok(not HUD.rebirthReady(cost - 1, 0))
		t.ok(not HUD.rebirthReady(cost, 1), "cost grows with rebirths")
		t.ok(not HUD.rebirthReady(nil, 0))
	end)

	t.test("gearAffordable", function()
		local snap = { upgrades = { lock = 0, hotwire = 0, nitro = 0, armor = 0 }, tools = { bat = true } }
		local cheapest = math.huge
		for id in Economy.Upgrades do
			cheapest = math.min(cheapest, EconomyMath.upgradePrice(id, 0))
		end
		t.ok(not HUD.gearAffordable(snap, cheapest - 1))
		t.ok(HUD.gearAffordable(snap, cheapest))
		-- everything maxed + all tools owned -> nothing to buy
		local maxed = { upgrades = {}, tools = {} }
		for id, def in Economy.Upgrades do
			maxed.upgrades[id] = def.maxLevel
		end
		for id in Economy.Tools do
			maxed.tools[id] = true
		end
		t.ok(not HUD.gearAffordable(maxed, 1e15))
		-- the Zapper Pass owns the taser without writing tools.taser (MenuController.toolRows' rule)
		local passTaser = { upgrades = maxed.upgrades, tools = {}, passes = { taser = true } }
		for id in Economy.Tools do
			if id ~= "taser" then
				passTaser.tools[id] = true
			end
		end
		t.ok(not HUD.gearAffordable(passTaser, 1e15), "no badge for a pass-owned Zapper")
		passTaser.passes = {}
		t.ok(HUD.gearAffordable(passTaser, 1e15), "without the pass the Zapper is still for sale")
	end)

	t.test("touchMenuGrid: one strip of big cells when it fits, else wrap / smaller cells", function()
		-- 844x390 phone (canvas ~1535 x 603): a single row of 76 px cells fits left of the cash pill
		local cols, rows, cell = HUD.touchMenuGrid(7, 1535 / 2 - 168 - 12, 603 / 3 - 82, { 76, 62 }, 6)
		t.eq(cols, 7)
		t.eq(rows, 1)
		t.eq(cell, 76)
		-- 16:9 phone (canvas ~1213 wide): 76 px cells need 2 rows -> try 62 px; still 2 rows, smallest wins
		cols, rows, cell = HUD.touchMenuGrid(7, 1213 / 2 - 168 - 12, 576 / 3 - 82, { 76, 62 }, 6)
		t.eq(cell, 62)
		t.eq(rows, 2)
		t.eq(cols, 6)
		-- roomy tablet: big cells, one row
		cols, rows, cell = HUD.touchMenuGrid(7, 2000, 400, { 76, 62 }, 6)
		t.eq(cols, 7)
		t.eq(rows, 1)
		t.eq(cell, 76)
		-- degenerate width still yields a column
		cols, rows = HUD.touchMenuGrid(7, 10, 1000, { 76 }, 6)
		t.eq(cols, 1)
		t.eq(rows, 7)
		t.eq((HUD.touchMenuGrid(0, 100, 100, { 76 }, 6)), 0)
	end)

	t.test("vipChatPrefix tags VIP senders only", function()
		t.eq(HUD.vipChatPrefix(false, "Alex:"), nil)
		local p = HUD.vipChatPrefix(true, "Alex:")
		t.ok(p ~= nil and p:find("VIP", 1, true) ~= nil and p:sub(-5) == "Alex:", "prefix keeps the name")
		t.ok(HUD.vipChatPrefix(true, "") ~= nil)
		t.ok(HUD.vipChatPrefix(true, nil) ~= nil)
	end)

	t.test("countGarage / countDiscovered", function()
		t.eq(HUD.countGarage(nil), 0)
		t.eq(HUD.countGarage({ garage = { ["1"] = {}, ["3"] = {} } }), 2)
		t.eq(HUD.countDiscovered({ discovered = { a = true, b = false, c = true } }), 2)
	end)

	-- HOME + layout -----------------------------------------------------------------------------------------------
	t.test("homeState", function()
		local base = {
			hidden = false,
			focus = false,
			driving = false,
			inOwnGarage = false,
			hasPlot = true,
			wanted = 0,
			cooldownLeft = 0,
		}
		local function with(over)
			local c = table.clone(base)
			for k, v in over do
				c[k] = v
			end
			return HUD.homeState(c)
		end
		t.eq(with({}), "ready")
		t.eq(with({ driving = true }), "hidden")
		t.eq(with({ inOwnGarage = true }), "hidden")
		t.eq(with({ hidden = true }), "hidden")
		t.eq(with({ focus = true }), "hidden")
		t.eq(with({ hasPlot = false }), "hidden")
		t.eq(with({ wanted = 2 }), "wanted")
		t.eq(with({ wanted = 2, cooldownLeft = 5 }), "wanted", "wanted wins over cooldown")
		t.eq(with({ cooldownLeft = 5 }), "cooldown")
	end)

	t.test("gridFit wraps into columns", function()
		local cols, rows = HUD.gridFit(7, 600, 62, 6)
		t.eq(cols, 1)
		t.eq(rows, 7)
		cols, rows = HUD.gridFit(7, 300, 62, 6)
		t.eq(rows, 4)
		t.eq(cols, 2)
		cols, rows = HUD.gridFit(7, 10, 62, 6)
		t.eq(rows, 1)
		t.eq(cols, 7)
		cols, rows = HUD.gridFit(0, 300, 62, 6)
		t.eq(cols, 0)
	end)

	t.test("menu definitions are unique and resolvable", function()
		local seen = {}
		for _, list in { HUD.MENU, HUD.MENU_TOP_ROW } do
			for _, def in list do
				t.ok(not seen[def.id], "duplicate menu id " .. def.id)
				seen[def.id] = true
				t.ok(#def.names >= 1, def.id .. " needs a MenuController name")
				t.eq(HUD.menuNameCandidates(def.id)[1], def.names[1])
			end
		end
		t.ok(seen.GearShop and seen.Store and seen.Daily and seen.Settings, "core menus present")
		t.eq(HUD.menuNameCandidates("Nope")[1], "Nope")
	end)

	-- Tutorial ----------------------------------------------------------------------------------------------------
	local function ctx(over)
		local c = { elapsed = 0, driving = false, notDrivingFor = 0, delivered = false, collected = false }
		for k, v in over or {} do
			c[k] = v
		end
		return c
	end
	local MONEY, STEAL, DELIVER, COLLECT, DEALER, DONE = 1, 2, 3, 4, 5, Tut.DONE

	t.test("tutorial steps are well formed", function()
		t.eq(#Tut.STEPS, 5)
		t.eq(DONE, 6)
		local ids = {}
		for _, s in Tut.STEPS do
			ids[#ids + 1] = s.id
			t.ok(#s.icon > 0 and #s.title > 0 and #s.hint > 0, s.id .. " has icon/title/hint")
		end
		t.eq(table.concat(ids, ","), "money,steal,deliver,collect,dealer")
	end)

	t.test("tutorial happy path", function()
		t.eq(Tut.transition(MONEY, ctx({ elapsed = 1 })), MONEY)
		t.eq(Tut.transition(MONEY, ctx({ elapsed = 4 })), STEAL, "money auto-advances after 4s")
		t.eq(Tut.transition(STEAL, ctx({ elapsed = 60 })), STEAL, "waits for a steal")
		t.eq(Tut.transition(STEAL, ctx({ driving = true })), DELIVER)
		t.eq(Tut.transition(DELIVER, ctx({ driving = true, elapsed = 30 })), DELIVER)
		t.eq(Tut.transition(DELIVER, ctx({ delivered = true, notDrivingFor = 0.5 })), COLLECT)
		t.eq(Tut.transition(COLLECT, ctx({ elapsed = 3 })), COLLECT)
		t.eq(Tut.transition(COLLECT, ctx({ elapsed = 3, collected = true })), DEALER)
		t.eq(Tut.transition(DEALER, ctx({ elapsed = 8 })), DEALER, "dealer step waits for arrival, not a timer")
		t.eq(Tut.transition(DEALER, ctx({ elapsed = 3, nearDealer = true })), DONE, "arriving finishes")
		t.eq(Tut.transition(DEALER, ctx({ elapsed = 89 })), DEALER)
		t.eq(Tut.transition(DEALER, ctx({ elapsed = 90 })), DONE, "long timeout as a fallback")
		t.eq(Tut.transition(DONE, ctx()), DONE, "done is terminal")
	end)

	t.test("tutorial shortcuts and fallbacks", function()
		t.eq(Tut.transition(MONEY, ctx({ driving = true })), DELIVER, "already driving skips ahead")
		t.eq(Tut.transition(MONEY, ctx({ delivered = true })), COLLECT, "already delivered skips ahead")
		t.eq(Tut.transition(STEAL, ctx({ delivered = true })), COLLECT)
		t.eq(Tut.transition(DELIVER, ctx({ notDrivingFor = 1 })), DELIVER, "short exit tolerated")
		t.eq(Tut.transition(DELIVER, ctx({ notDrivingFor = 3 })), STEAL, "lost the car -> steal again")
		t.eq(Tut.transition(COLLECT, ctx({ elapsed = 20 })), DEALER, "collect times out")
		t.eq(Tut.transition(COLLECT, ctx({ driving = true, delivered = true })), COLLECT, "no regression")
	end)

	t.test("tutorial pickNearest only targets Parked cars", function()
		local origin = Vector3.new(0, 0, 0)
		local cands = {
			{ position = Vector3.new(5, 0, 0), kind = "Traffic" },
			{ position = Vector3.new(50, 0, 0), kind = "Parked" },
			{ position = Vector3.new(0, 0, 20), kind = "Parked" },
			{ position = Vector3.new(1, 0, 1), kind = "Police" },
		}
		t.eq(Tut.pickNearest(cands, origin), 3)
		t.eq(Tut.pickNearest(cands, origin, 10), nil, "maxDistance respected")
		t.eq(Tut.pickNearest({}, origin), nil)
	end)

	t.test("tutorial inFrontOfDoor matches the street-side test", function()
		local door = Vector3.new(0, 0, -44)
		local face = Vector3.new(0, 0, -1) -- out of the door
		t.ok(Tut.inFrontOfDoor(Vector3.new(30, 0, -90), door, face), "street side")
		t.ok(Tut.inFrontOfDoor(Vector3.new(60, 0, -41), door, face), "slack of 4 studs beside the door")
		t.ok(not Tut.inFrontOfDoor(Vector3.new(0, 0, 60), door, face), "behind the garage")
		t.ok(not Tut.inFrontOfDoor(Vector3.new(80, 0, 0), door, face), "beside the garage walls")
	end)

	t.test("tutorial shouldRun / hints / counts", function()
		t.ok(Tut.shouldRun({ tutorialDone = false }))
		t.ok(not Tut.shouldRun({ tutorialDone = true }))
		t.ok(not Tut.shouldRun({}), "unknown state never starts the tutorial")
		t.ok(not Tut.shouldRun(nil))
		local steal = Tut.STEPS[STEAL]
		t.eq(Tut.hintFor(steal, "touch"), steal.hintTouch)
		t.eq(Tut.hintFor(steal, "gamepad"), steal.hintPad)
		t.eq(Tut.hintFor(steal, "keyboard"), steal.hint)
		t.eq(Tut.hintFor(Tut.STEPS[MONEY], "touch"), Tut.STEPS[MONEY].hint, "falls back to the default hint")
		t.eq(Tut.keyFor("keyboard"), "E")
		t.eq(Tut.keyFor("gamepad"), "X")
		t.eq(Tut.keyFor("touch"), "TAP")
		t.eq(Tut.enterKeyFor("keyboard"), "F", "VehicleService EnterPrompt key")
		t.eq(Tut.enterKeyFor("gamepad"), "Y")
		t.eq(Tut.enterKeyFor("touch"), "TAP")
		t.ok(Tut.STEPS[DEALER].timed == nil, "dealer step is not a timed card")
		t.ok(Tut.alreadyDelivered({ tutorialDone = false, stats = { steals = 1 } }), "returning mid-tutorial player")
		t.ok(not Tut.alreadyDelivered({ tutorialDone = false, stats = { steals = 0 } }))
		t.ok(not Tut.alreadyDelivered({ tutorialDone = true, stats = { steals = 5 } }))
		t.ok(Tut.STEPS[STEAL].key == true, "steal step shows the keycap")
		t.eq(Tut.garageCount({ garage = { ["1"] = {}, ["2"] = {} } }), 2)
		t.eq(Tut.stealCount({ stats = { steals = 4 } }), 4)
		t.eq(Tut.stealCount({}), 0)
	end)

	t.test("tutorial v2: GTA help text + objective lines, no emoji", function()
		local RichText = H.require("src/client/UI/RichText")
		for _, s in Tut.STEPS do
			for _, txt in { s.title, s.hint, s.hintTouch or "", s.hintPad or "" } do
				t.eq(RichText.stripEmoji(txt), txt, s.id .. " has no emoji")
			end
			t.ok(s.icon:find(".", 1, true) ~= nil, s.id .. " icon is a UIAssets glyph key")
		end
		local steal = Tut.STEPS[STEAL]
		local kb = Tut.helpText(steal, "keyboard")
		t.ok(kb:find(RichText.key("E"), 1, true) ~= nil, "keyboard help carries the E key cap")
		t.ok(kb:find("{key}", 1, true) == nil, "placeholder replaced")
		t.ok(Tut.helpText(steal, "gamepad"):find(RichText.key("X"), 1, true) ~= nil, "pad gets X")
		local touch = Tut.helpText(steal, "touch")
		t.ok(touch:find("<mark", 1, true) == nil, "touch has no key cap")
		local back = Tut.helpText(steal, "keyboard", true)
		t.ok(back:find(RichText.key("F"), 1, true) ~= nil, "re-enter uses the F enter key")
		t.ok(Tut.objectiveText(steal, true):find("Get back in", 1, true) ~= nil)
		t.eq(Tut.objectiveText(steal, false), steal.title)
		t.eq(Tut.objectiveText(Tut.STEPS[MONEY], true), Tut.STEPS[MONEY].title, "re-enter only affects step 2")
		t.eq(Tut.helpText(Tut.STEPS[MONEY], "touch"), Tut.STEPS[MONEY].hint, "no key -> plain hint")
		t.ok(RichText.plain(Tut.STEPS[DELIVER].title):find("garage", 1, true) ~= nil, "objective names the garage")
	end)
end
