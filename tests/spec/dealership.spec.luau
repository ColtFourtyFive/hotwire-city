--!nocheck
-- DealershipService fix-phase rules: rarity-scaled heist heat, server-side hold validation, robbed-pad restock and
-- the countdown sign clearing MapBuilder's canopy. (Older dealer tests live in theft.spec.)
return function(t)
	local H = t.H
	H.setMode("server")
	local Dealer = H.require("src/server/Systems/DealershipService")
	local PoliceConfig = H.require("src/shared/Config/Police")
	local MapLayout = H.require("src/shared/Util/MapLayout")
	local R = H.roblox

	t.test("dealer steal heat scales with rarity (DECISIONS #2)", function()
		local floor = PoliceConfig.Heat.dealerSteal
		t.eq(Dealer._stealHeat("rustbucket"), floor, "Common: the flat minimum")
		t.eq(Dealer._stealHeat("viper_strike"), floor, "Rare")
		t.eq(Dealer._stealHeat("raging_bull"), floor, "Epic")
		t.eq(Dealer._stealHeat("hyperion_x"), 3, "Legendary")
		t.eq(Dealer._stealHeat("night_raven"), 4, "Mythic")
		t.eq(Dealer._stealHeat("rubber_ducky"), 4, "Secret")
		t.eq(Dealer._stealHeat("not_a_car"), floor, "unknown car")
		for _, id in { "rustbucket", "hyperion_x", "night_raven", "rubber_ducky" } do
			local h = Dealer._stealHeat(id)
			t.ok(h >= floor and h <= 5, id .. " heat in range")
		end
	end)

	t.test("server-side hold validation (SEC-2)", function()
		local req = 2
		t.eq(Dealer._holdOk(nil, 10, req, req), false, "no live hold")
		t.eq(Dealer._holdOk(10, 10.5, req, req), false, "released early")
		t.eq(Dealer._holdOk(10, 10 + req * Dealer.HOLD_TOLERANCE, req, req), true, "latency tolerance")
		t.eq(Dealer._holdOk(10, 12.1, req, req), true, "normal hold")
		t.eq(Dealer._holdOk(10, 10 + req * 1.25 + Dealer.HOLD_MAX_EXTRA + 0.01, req, req), false, "stale tap")
		t.eq(Dealer._holdOk(10, 60, req, req), false, "tap long ago, trigger now")
		-- a 0.5x hotwire multiplier: the client may still show the unscaled base before the attribute replicates
		t.eq(Dealer._holdOk(10, 10 + 4.5, 2, 4), true, "base hold still accepted")
		t.eq(Dealer._holdOk(10, 10 + 4 * 1.25 + Dealer.HOLD_MAX_EXTRA + 0.01, 2, 4), false, "but not forever")
		-- buy hold: looser tolerance
		local b = Dealer.BUY_HOLD
		t.eq(Dealer._holdOk(0, b * 0.85, b, b, Dealer.BUY_HOLD_TOLERANCE), true, "buy latency")
		t.eq(Dealer._holdOk(0, b * 0.5, b, b, Dealer.BUY_HOLD_TOLERANCE), false, "buy released early")
		t.eq(Dealer._holdOk(0, 30, b, b, Dealer.BUY_HOLD_TOLERANCE), false, "stale buy tap")
	end)

	t.test("a robbed pad waits for the global restock, a sold one refills (F1)", function()
		local now = 1000
		local nextGlobal = Dealer._nextGlobal(now)
		t.eq(Dealer._padRestockAt(now + 10, nextGlobal), now + 10 + Dealer.PAD_RESTOCK, "sold")
		t.eq(Dealer._padRestockAt(now + 10, nextGlobal, false), now + 10 + Dealer.PAD_RESTOCK, "sold (explicit)")
		t.eq(Dealer._padRestockAt(now + 10, nextGlobal, true), nextGlobal, "stolen")
	end)

	t.test("restock sign clears the back canopy and stays above the cars", function()
		local folder = R.Instance.new("Folder")
		local floorY = MapLayout.poiCenter("Dealership").Y + 0.2 -- runtime floor: raycast onto MapBuilder's pads
		local floorYs = {}
		for i = 1, #MapLayout.dealerPads() do
			floorYs[i] = floorY
		end
		local _, board = Dealer.buildShowroom(folder, floorYs)
		local sign = board.Parent
		local top = -math.huge
		for _, p in sign:GetDescendants() do
			if p:IsA("BasePart") then
				top = math.max(top, p.CFrame.Position.Y + p.Size.Y / 2)
			end
		end
		local curb = MapLayout.poiCenter("Dealership").Y
		t.ok(top <= curb + 17.7 - 0.25, ("sign top %.2f clears the light panel / canopy"):format(top - curb))
		t.ok(board.CFrame.Position.Y - board.Size.Y / 2 >= floorY + 8, "above the cars")
	end)
end
