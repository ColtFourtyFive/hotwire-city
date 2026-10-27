--!nocheck
-- client-core slice: pure helpers of StateController, SoundController, NotificationController, WaypointController.
return function(t)
	local H = t.H
	local Vector2 = H.roblox.Vector2
	local Vector3 = H.roblox.Vector3

	H.setMode("client")
	local StateController = H.require("src/client/Controllers/StateController")
	local SoundController = H.require("src/client/Controllers/SoundController")
	local NotificationController = H.require("src/client/Controllers/NotificationController")
	local WaypointController = H.require("src/client/Controllers/WaypointController")

	---------------------------------------------------------------------------------------------------------------
	-- StateController
	---------------------------------------------------------------------------------------------------------------

	t.test("StateController: onReady queues until the first snapshot, then runs immediately", function()
		t.eq(StateController.get(), nil, "no snapshot yet")
		t.eq(StateController.isReady(), false, "not ready")
		local got = nil
		StateController.onReady(function(snap)
			got = snap
		end)
		t.eq(got, nil, "queued")

		local changes = {}
		local conn = StateController.Changed:Connect(function(snap, prev)
			table.insert(changes, { snap = snap, prev = prev })
		end)
		local s1 = { cash = 10, settings = { sfx = true, music = false } }
		t.ok(StateController.applySnapshot(s1), "applied")
		t.eq(got, s1, "queued onReady ran with the snapshot")
		t.eq(StateController.get(), s1, "get returns it")
		t.eq(#changes, 1, "Changed fired once")
		t.eq(changes[1].prev, nil, "first previous is nil")

		local s2 = { cash = 20 }
		StateController.applySnapshot(s2)
		t.eq(#changes, 2, "Changed fired again")
		t.eq(changes[2].snap, s2)
		t.eq(changes[2].prev, s1, "previous passed along")

		local immediate = nil
		StateController.onReady(function(snap)
			immediate = snap
		end)
		t.eq(immediate, s2, "onReady after ready runs right away with the latest")
		conn:Disconnect()
	end)

	t.test("StateController: rejects junk and reads settings", function()
		t.eq(StateController.applySnapshot("nope"), false)
		t.eq(StateController.applySnapshot(nil), false)
		StateController.applySnapshot({ settings = { sfx = false, music = true, hideHud = "x" } })
		t.eq(StateController.getSetting("sfx"), false)
		t.eq(StateController.getSetting("music"), true)
		t.eq(StateController.getSetting("hideHud"), nil, "non-boolean ignored")
		t.eq(StateController.getSetting("missing"), nil)
	end)

	t.test("StateController: event / hot drop / theft sanitizers + signals", function()
		local ev = StateController.sanitizeEventState({ rushHour = 120, doubleCash = 0 / 0, [1] = 5, bad = "x" })
		t.eq(ev.rushHour, 120)
		t.eq(ev.doubleCash, nil, "NaN dropped")
		t.eq(ev.bad, nil, "non-number dropped")
		t.eq(ev[1], nil, "non-string key dropped")
		t.eq(next(StateController.sanitizeEventState(nil)), nil, "nil -> empty")

		local hd = StateController.sanitizeHotDrop({
			active = true,
			position = Vector3.new(1, 2, 3),
			carId = "x",
			endsAt = 50,
		})
		t.eq(hd.active, true)
		t.eq(hd.position, Vector3.new(1, 2, 3))
		t.eq(hd.carId, "x")
		t.eq(hd.endsAt, 50)
		t.eq(StateController.sanitizeHotDrop({ active = "yes", position = "here" }).active, false)
		t.eq(StateController.sanitizeHotDrop({ position = "here" }).position, nil)

		local fired = nil
		local conn = StateController.HotDropChanged:Connect(function(state)
			fired = state
		end)
		StateController.applyHotDrop({ active = true, position = Vector3.new(5, 0, 5) })
		t.ok(fired and fired.active, "HotDropChanged fired")
		t.eq(StateController.getHotDrop().active, true)
		conn:Disconnect()

		local th = StateController.sanitizeTheft({ active = true, endsAt = 99, carId = "c", targetPlot = 3 })
		t.eq(th.active, true)
		t.eq(th.targetPlot, 3)
		t.eq(th.dropped, false, "not dropped by default")
		t.eq(th.droppedEndsAt, nil)
		local dr = StateController.sanitizeTheft({
			active = true,
			endsAt = 99,
			carId = "c",
			mutation = "Gold",
			dropped = true,
			droppedEndsAt = 42,
		})
		t.eq(dr.dropped, true, "dropped survives sanitizing")
		t.eq(dr.droppedEndsAt, 42)
		t.eq(dr.mutation, "Gold")
		t.eq(StateController.sanitizeTheft({ active = true, dropped = "yes", droppedEndsAt = 0 / 0 }).dropped, false)
		t.eq(StateController.sanitizeTheft({ active = true, droppedEndsAt = 0 / 0 }).droppedEndsAt, nil, "NaN dropped")
		StateController.applyTheft(nil)
		t.eq(StateController.getTheft().active, false)
		StateController.applyEventState({ cashRain = 10 })
		t.eq(StateController.getEventState().cashRain, 10)
	end)

	---------------------------------------------------------------------------------------------------------------
	-- SoundController
	---------------------------------------------------------------------------------------------------------------

	t.test("SoundController.enginePitch follows 0.7 + 1.1 * speed/top (clamped)", function()
		t.near(SoundController.enginePitch(0, 100), 0.7, 1e-9)
		t.near(SoundController.enginePitch(50, 100), 1.25, 1e-9)
		t.near(SoundController.enginePitch(100, 100), 1.8, 1e-9)
		t.near(SoundController.enginePitch(1000, 100), 0.7 + 1.1 * 1.3, 1e-9, "nitro overshoot clamp")
		t.near(SoundController.enginePitch(-20, 100), 0.7, 1e-9, "negative clamps to idle")
		t.near(SoundController.enginePitch(50, 0), 1.25, 1e-9, "bad top speed falls back to 100")
	end)

	t.test("SoundController engine eligibility + top speed lookup", function()
		t.eq(SoundController.isEngineEligible("Parked", true), false)
		t.eq(SoundController.isEngineEligible("Dealership", true), false)
		t.eq(SoundController.isEngineEligible("HotDrop", true), false)
		t.eq(SoundController.isEngineEligible("Traffic", false), true, "AI traffic drives without a seated player")
		t.eq(SoundController.isEngineEligible("Police", false), true)
		t.eq(SoundController.isEngineEligible("Loot", false), false, "abandoned loot is silent")
		t.eq(SoundController.isEngineEligible("Loot", true), true)
		t.eq(SoundController.isEngineEligible(nil, true), true)

		t.eq(SoundController.topSpeedFor("rustbucket", "Loot"), 70)
		t.eq(SoundController.topSpeedFor(nil, "Police"), 118)
		t.eq(SoundController.topSpeedFor("police_unit", nil), 118)
		t.eq(SoundController.topSpeedFor("does_not_exist", "Loot"), 100)
	end)

	t.test("SoundController.selectNearest keeps only the N closest", function()
		local cands = {}
		for i = 1, 9 do
			table.insert(cands, { key = "car" .. i, dist = (10 - i) * 10 })
		end
		local chosen = SoundController.selectNearest(cands, 6)
		local n = 0
		for _ in chosen do
			n += 1
		end
		t.eq(n, 6, "six chosen")
		t.ok(chosen.car9 and chosen.car4, "closest kept")
		t.eq(chosen.car1, nil, "farthest dropped")
		t.eq(next(SoundController.selectNearest({}, 6)), nil, "empty ok")
	end)

	---------------------------------------------------------------------------------------------------------------
	-- NotificationController
	---------------------------------------------------------------------------------------------------------------

	t.test("NotificationController.trimOldest trims from the front", function()
		local list = { 1, 2, 3, 4, 5, 6 }
		local removed = NotificationController.trimOldest(list, 4)
		t.eq(#removed, 2)
		t.eq(removed[1], 1)
		t.eq(removed[2], 2)
		t.eq(#list, 4)
		t.eq(list[1], 3)
		t.eq(#NotificationController.trimOldest(list, 10), 0, "under max: nothing removed")
		t.eq(#NotificationController.trimOldest(list, 0), 4, "max 0 empties")
		t.eq(#list, 0)
	end)

	t.test("NotificationController formatting helpers", function()
		t.eq(NotificationController.formatCashDelta(1234), "+$1.23K")
		t.eq(NotificationController.formatCashDelta(1200), "+$1.2K")
		t.eq(NotificationController.formatCashDelta(250), "+$250")
		t.eq(NotificationController.formatCashDelta(-500), "-$500")
		t.eq(NotificationController.formatCashDelta(0 / 0), "+$0")
		t.eq(NotificationController.richEscape("<b>Tom & Jerry</b>"), "&lt;b&gt;Tom &amp; Jerry&lt;/b&gt;")
		t.eq(NotificationController.carLabel("rustbucket", "Gold"), "GOLD RUSTBUCKET")
		t.eq(NotificationController.carLabel("rustbucket", "None"), "RUSTBUCKET")
		t.eq(NotificationController.carLabel("mystery_car", "Bogus"), "MYSTERY_CAR")
		t.eq(NotificationController.carLabel(nil, nil), "CAR")
		local text = NotificationController.stolenAlertText("<Sneaky>", "rustbucket", "Diamond")
		t.ok(text:find("&lt;SNEAKY&gt;", 1, true), "thief escaped + upper: " .. text)
		t.ok(text:find("DIAMOND RUSTBUCKET", 1, true), "car label present")
		t.ok(text:find("IS STEALING YOUR", 1, true))
	end)

	t.test("NotificationController kind styles + banner pacing", function()
		local info = NotificationController.kindStyle("info")
		t.eq(NotificationController.kindStyle("nonsense"), info, "unknown kind falls back to info")
		t.eq(NotificationController.kindStyle(nil), info)
		for _, kind in { "info", "success", "error", "money", "warning" } do
			local style = NotificationController.kindStyle(kind)
			t.ok(typeof(style.color) == "Color3" and #style.icon > 0, kind .. " has color + icon")
		end
		t.ok(NotificationController.kindStyle("error").color ~= NotificationController.kindStyle("success").color)
		t.near(NotificationController.bannerHold(0) + 0.75, 3, 1e-9, "a lone banner lasts ~3s")
		t.ok(NotificationController.bannerHold(1) < NotificationController.bannerHold(0), "backlog speeds up")
		t.ok(NotificationController.bannerHold(5) <= NotificationController.bannerHold(1))
	end)

	---------------------------------------------------------------------------------------------------------------
	-- WaypointController
	---------------------------------------------------------------------------------------------------------------

	t.test("WaypointController.formatDistance uses 3 studs = 1 m", function()
		t.eq(WaypointController.formatDistance(735), "245m")
		t.eq(WaypointController.formatDistance(0), "0m")
		t.eq(WaypointController.formatDistance(4), "1m")
		t.eq(WaypointController.formatDistance(2994), "998m")
		t.eq(WaypointController.formatDistance(3600), "1.2km")
		t.eq(WaypointController.formatDistance(0 / 0), "0m")
		t.eq(WaypointController.formatDistance(-5), "0m")
	end)

	t.test("WaypointController.edgeArrow screen math", function()
		local vp = Vector2.new(1000, 600)
		local m = 50

		local on, pos, ang = WaypointController.edgeArrow(Vector3.new(500, 300, 10), vp, m)
		t.eq(on, true, "center is on screen")
		t.eq(pos, Vector2.new(500, 300))
		t.eq(ang, 0)

		on, pos, ang = WaypointController.edgeArrow(Vector3.new(1500, 300, 10), vp, m)
		t.eq(on, false, "right is off screen")
		t.near(pos.X, 950, 1e-6, "clamped to right margin")
		t.near(pos.Y, 300, 1e-6)
		t.near(ang, 90, 1e-6, "points right")

		on, pos, ang = WaypointController.edgeArrow(Vector3.new(-200, 300, 10), vp, m)
		t.near(pos.X, 50, 1e-6)
		t.near(ang, -90, 1e-6, "points left")

		on, pos, ang = WaypointController.edgeArrow(Vector3.new(500, -100, 10), vp, m)
		t.near(pos.Y, 50, 1e-6, "clamped to top margin")
		t.near(ang, 0, 1e-6, "points up")

		on, pos, ang = WaypointController.edgeArrow(Vector3.new(500, -100, 10), vp, m, 100)
		t.near(pos.Y, 100, 1e-6, "custom top margin respected")

		on, pos, ang = WaypointController.edgeArrow(Vector3.new(500, 900, 10), vp, m)
		t.near(pos.Y, 550, 1e-6)
		t.near(math.abs(ang), 180, 1e-6, "points down")

		-- behind the camera: projection is mirrored, so an "above center" projection means the target is below/behind
		on, pos, ang = WaypointController.edgeArrow(Vector3.new(500, 200, -10), vp, m)
		t.eq(on, false, "behind is never on screen")
		t.near(pos.Y, 550, 1e-6, "behind -> bottom edge")
		t.near(math.abs(ang), 180, 1e-6)

		on, pos, ang = WaypointController.edgeArrow(Vector3.new(500, 300, -5), vp, m)
		t.eq(on, false)
		t.near(pos.Y, 550, 1e-6, "dead behind -> bottom center")
		t.near(pos.X, 500, 1e-6)

		-- behind and to the right projects to the left; flipped back to the right
		on, pos, ang = WaypointController.edgeArrow(Vector3.new(100, 300, -10), vp, m)
		t.near(pos.X, 950, 1e-6, "behind-right -> right edge")

		-- diagonal: hits the bottom edge first, stays inside bounds
		on, pos, ang = WaypointController.edgeArrow(Vector3.new(1500, 900, 10), vp, m)
		t.near(pos.Y, 550, 1e-6, "diagonal clamps to bottom")
		t.ok(pos.X > 500 and pos.X <= 950, "diagonal x inside bounds")
		t.ok(ang > 90 and ang < 180, "diagonal angle down-right: " .. ang)

		-- camera-space direction (preferred path): same answers, no singularity in the camera plane
		on, pos, ang = WaypointController.edgeArrow(Vector3.new(1e9, 300, 0), vp, m, nil, Vector3.new(800, -10, 0))
		t.eq(on, false, "in the camera plane is off screen")
		t.near(pos.X, 950, 1e-6, "directly right -> right edge even though Z == 0")
		t.ok(ang > 80 and ang < 100, "points right: " .. ang)
		on, pos, ang = WaypointController.edgeArrow(Vector3.new(-1e9, 300, 0), vp, m, nil, Vector3.new(-800, -10, 0))
		t.near(pos.X, 50, 1e-6, "directly left -> left edge")
		on, pos, ang = WaypointController.edgeArrow(Vector3.new(500, 200, -10), vp, m, nil, Vector3.new(0, -5, 40))
		t.near(pos.Y, 550, 1e-6, "behind + below -> bottom edge")
		t.near(math.abs(ang), 180, 1e-6)
		on, pos, ang = WaypointController.edgeArrow(Vector3.new(500, 300, -5), vp, m, nil, Vector3.new(0, 0, 40))
		t.near(pos.Y, 550, 1e-6, "dead behind at eye level -> bottom")
		on, pos, ang = WaypointController.edgeArrow(Vector3.new(1500, 300, 10), vp, m, 80, Vector3.new(60, 0, -20))
		t.near(pos.X, 950, 1e-6, "in front off right agrees with projection")
		t.near(ang, 90, 1e-6)

		-- per-side insets table
		local ins = { left = 120, top = 70, right = 40, bottom = 30 }
		on, pos, ang = WaypointController.edgeArrow(Vector3.new(-500, 300, 10), vp, ins)
		t.near(pos.X, 120, 1e-6, "left inset")
		on, pos, ang = WaypointController.edgeArrow(Vector3.new(1500, 300, 10), vp, ins)
		t.near(pos.X, 960, 1e-6, "right inset")
		on, pos, ang = WaypointController.edgeArrow(Vector3.new(500, -900, 10), vp, ins)
		t.near(pos.Y, 70, 1e-6, "top inset")
		on, pos, ang = WaypointController.edgeArrow(Vector3.new(500, 2000, 10), vp, ins)
		t.near(pos.Y, 570, 1e-6, "bottom inset")
		-- degenerate tiny viewport never inverts
		on, pos, ang = WaypointController.edgeArrow(Vector3.new(500, 300, -1), Vector2.new(60, 40), 50)
		t.ok(pos.X == 30 and pos.Y == 20, "collapses to center")

		-- huge projected values stay finite
		on, pos, ang = WaypointController.edgeArrow(Vector3.new(1e12, -1e12, 1e-9), vp, m)
		t.ok(pos.X == pos.X and pos.Y == pos.Y and ang == ang, "finite result")
		t.ok(pos.X <= 950 and pos.Y >= 50, "clamped")
	end)

	t.test("WaypointController.hotDropVisible matches the server's countdown/live phases", function()
		local pos = Vector3.new(1, 0, 2)
		t.eq(WaypointController.hotDropVisible(nil, 100), false)
		t.eq(WaypointController.hotDropVisible({ active = false }, 100), false, "nothing scheduled")
		t.eq(WaypointController.hotDropVisible({ active = true }, 100), false, "no position")
		t.eq(
			WaypointController.hotDropVisible({ active = false, startsAt = 120, position = pos }, 100),
			true,
			"countdown"
		)
		t.eq(WaypointController.hotDropVisible({ active = false, startsAt = 80, position = pos }, 100), false, "stale")
		t.eq(WaypointController.hotDropVisible({ active = true, endsAt = 300, position = pos }, 100), true, "live")
		t.eq(WaypointController.hotDropVisible({ active = true, position = pos }, 100), true, "live, no expiry")
		t.eq(WaypointController.hotDropVisible({ active = true, endsAt = 90, position = pos }, 100), false, "expired")
	end)

	t.test("WaypointController icons + duplicate detection", function()
		t.eq(WaypointController.iconFor("home", "DROP OFF"), "🏠")
		t.eq(WaypointController.iconFor("hotdrop", "HOT DROP: X"), "🔥")
		t.eq(WaypointController.iconFor("stolen_car", "YOUR CAR"), "🚨")
		t.eq(WaypointController.iconFor("dealership", nil), "🏪")
		t.eq(WaypointController.iconFor("whatever", "SOMEWHERE"), "📍")
		local others = { Vector3.new(0, 0, 0), Vector3.new(100, 0, 0) }
		t.eq(WaypointController.isNearAny(Vector3.new(10, 0, 10), others, 30), true)
		t.eq(WaypointController.isNearAny(Vector3.new(50, 0, 0), others, 30), false)
		t.eq(WaypointController.isNearAny(Vector3.new(50, 0, 0), {}, 30), false)
		t.eq(WaypointController.iconFor("spray", "SPRAY $750"), "🎨")
		t.eq(WaypointController.iconFor("cashrain", "💰 CASH RAIN"), "💰")
	end)

	t.test("WaypointController spray waypoint: price matches WantedService, nearest booth wins", function()
		local Economy = H.require("src/shared/Config/Economy")
		local per = Economy.SPRAY_COST_PER_STAR
		t.eq(WaypointController.sprayCost(2, 0), 2 * per, "flat minimum per star")
		t.eq(WaypointController.sprayCost(3, nil), 3 * per)
		local rich = (per / Economy.SPRAY_INCOME_SECONDS) * 4 -- income where 15s of it is 4x the minimum
		t.eq(WaypointController.sprayCost(2, rich), math.floor(2 * rich * Economy.SPRAY_INCOME_SECONDS))
		t.eq(WaypointController.sprayCost(0, rich), 0)
		t.eq(WaypointController.sprayCost(1, 0 / 0), per, "NaN income")
		local booths = { Vector3.new(500, 0, 0), Vector3.new(-40, 0, 10) }
		t.eq(WaypointController.nearestIndex(booths, Vector3.new(0, 0, 0)), 2)
		t.eq(WaypointController.nearestIndex(booths, Vector3.new(400, 0, 0)), 1)
		t.eq(WaypointController.nearestIndex({}, Vector3.new(0, 0, 0)), nil)
	end)

	t.test("NotificationController toast anchor: below the PC player list; touch clears the button column", function()
		local desk = NotificationController.toastAnchor(false, 1, 1)
		t.ok(desk.Y.Scale >= 0.3, "desktop toasts start below the top-right player list")
		t.eq(desk.X.Scale, 1)
		local phone = NotificationController.toastAnchor(true, 0.55, 0.72)
		t.eq(phone.Y.Scale, 0, "touch: top-right corner")
		-- the right edge (real px) clears a 140-design-px column on the 0.55-scale combat/driving screens
		t.ok(-phone.X.Offset * 0.72 >= 140 * 0.55, "left of the action/driving buttons")
		local tablet = NotificationController.toastAnchor(true, 0.8, 0.8)
		t.ok(-tablet.X.Offset * 0.8 >= 140 * 0.8)
	end)

	t.test("NotificationController.pickStolenCar follows the victim's car, not the thief's name", function()
		local me = 77
		local cars = {
			{ victimUserId = 5, active = true, carId = "phantom", mutation = "None" },
			{ victimUserId = me, active = false, carId = "phantom", mutation = "None" },
			{ victimUserId = me, active = true, carId = "rocket", mutation = "Gold" },
			{ victimUserId = me, active = true, carId = "phantom", mutation = "None" },
		}
		t.eq(NotificationController.pickStolenCar(cars, me, "phantom", "None"), 4, "matches the alert's car")
		t.eq(NotificationController.pickStolenCar(cars, me, "rocket", "Gold"), 3)
		t.eq(NotificationController.pickStolenCar(cars, me, "unknown", nil), 3, "any of ours as a fallback")
		t.eq(NotificationController.pickStolenCar(cars, me, nil, nil), 3)
		t.eq(NotificationController.pickStolenCar(cars, 999, "phantom", "None"), nil, "not ours")
		t.eq(NotificationController.pickStolenCar({}, me, nil, nil), nil)
	end)

	t.test("EventsClient.stackTop sits under the HUD stack / theft alert banner", function()
		local EventsClient = H.require("src/client/Controllers/EventsClient")
		t.eq(EventsClient.stackTop(nil, nil, 0.72), 78, "classic spot under the cash pill")
		t.eq(EventsClient.stackTop(0, nil, 1), 78)
		t.eq(EventsClient.stackTop(76, nil, 1), 82, "just under the cash pill")
		t.eq(EventsClient.stackTop(134, 260, 1), 266, "below the alert banner when it reaches lower")
		t.eq(EventsClient.stackTop(110, nil, 0.5), 226, "real px are converted to this screen's scale")
		t.eq(EventsClient.stackTop(10, nil, 1), 78, "never above the default")
		t.eq(EventsClient.fitScale(100, 168, 600), 1, "room to spare")
		t.near(EventsClient.fitScale(268, 168, 388), 120 / 168, 1e-9, "shrinks to end above the bottom HUD")
		t.eq(EventsClient.fitScale(268, 168, 200), 0.6, "never below the readability floor")
		t.eq(EventsClient.fitScale(100, 0, 50), 1)
	end)

	H.setMode("server")
end
