--!nocheck
-- CombatService pure helpers (target cone, cooldowns, assault heat, spike sweep, player matching), tool + spike strip
-- builders, and EffectsController pure helpers (rarity tag rules, lightning bolt polyline, tag text).
return function(t)
	local H = t.H
	local V3 = H.roblox.Vector3
	local CF = H.roblox.CFrame
	local CombatService = H.require("src/server/Systems/CombatService")
	local Economy = H.require("src/shared/Config/Economy")

	local FWD = V3.new(0, 0, -1)

	t.test("selectTarget: nearest player in the front cone", function()
		local origin = V3.new(0, 0, 0)
		local cands = {
			{ key = "far", position = V3.new(0, 0, -8) },
			{ key = "near", position = V3.new(1, 0, -5) },
			{ key = "behind", position = V3.new(0, 0, 4) },
		}
		t.eq(CombatService.selectTarget(origin, { FWD }, cands, 9, 0.3, 3), "near")
	end)

	t.test("selectTarget: ignores targets behind, outside the cone and out of range", function()
		local origin = V3.new(0, 0, 0)
		t.eq(CombatService.selectTarget(origin, { FWD }, { { key = "b", position = V3.new(0, 0, 6) } }, 9, 0.3, 3), nil)
		-- 80 degrees off the look direction: dot ~0.17 < 0.3
		local side = V3.new(math.sin(math.rad(80)), 0, -math.cos(math.rad(80))) * 6
		t.eq(CombatService.selectTarget(origin, { FWD }, { { key = "s", position = side } }, 9, 0.3, 3), nil)
		t.eq(
			CombatService.selectTarget(origin, { FWD }, { { key = "f", position = V3.new(0, 0, -12) } }, 9, 0.3, 3),
			nil
		)
		t.eq(CombatService.selectTarget(origin, { FWD }, {}, 9, 0.3, 3), nil)
	end)

	t.test("selectTarget: point blank hits regardless of facing", function()
		local origin = V3.new(0, 0, 0)
		t.eq(
			CombatService.selectTarget(origin, { FWD }, { { key = "pb", position = V3.new(0, 0, 2) } }, 9, 0.3, 3),
			"pb"
		)
		-- directly above (no horizontal offset) also counts
		t.eq(
			CombatService.selectTarget(origin, { FWD }, { { key = "up", position = V3.new(0, 5, 0) } }, 9, 0.3, 3),
			"up"
		)
	end)

	t.test("selectTarget: a second forward (aim direction) widens the cone", function()
		local origin = V3.new(0, 0, 0)
		local right = { { key = "r", position = V3.new(6, 0, 0) } }
		t.eq(CombatService.selectTarget(origin, { FWD }, right, 9, 0.3, 3), nil)
		t.eq(CombatService.selectTarget(origin, { FWD, V3.new(10, 3, 0) }, right, 9, 0.3, 3), "r")
	end)

	t.test("cooldownFor: per tool, Zapper Pass halves only the Zapper", function()
		t.near(CombatService.cooldownFor("bat", false), Economy.Tools.bat.cooldown)
		t.near(CombatService.cooldownFor("bat", true), Economy.Tools.bat.cooldown)
		t.near(CombatService.cooldownFor("taser", false), Economy.Tools.taser.cooldown)
		t.near(CombatService.cooldownFor("taser", true), Economy.Tools.taser.cooldown * 0.5)
		t.near(CombatService.cooldownFor("spikes", true), Economy.Tools.spikes.cooldown)
		t.eq(CombatService.cooldownFor("nope", false), math.huge)
	end)

	t.test("cooldown bookkeeping: ready, start, tolerance, per tool", function()
		local book = {}
		t.ok(CombatService.cooldownReady(book, "bat", 100), "fresh book is ready")
		CombatService.startCooldown(book, "bat", 100, 0.8)
		t.ok(not CombatService.cooldownReady(book, "bat", 100.5), "mid cooldown")
		t.ok(CombatService.cooldownReady(book, "bat", 100.8), "exactly at end")
		t.ok(CombatService.cooldownReady(book, "bat", 100.7, 0.12), "within jitter tolerance")
		t.ok(not CombatService.cooldownReady(book, "bat", 100.6, 0.12), "outside tolerance")
		t.ok(CombatService.cooldownReady(book, "taser", 100.1), "tools are independent")
	end)

	t.test("assault heat rules", function()
		local base = {
			attackerInOwnGarage = false,
			victimInAttackerGarage = false,
			victimStealingFromAttacker = false,
			victimWanted = 0,
		}
		t.ok(CombatService.shouldAddAssaultHeat(base), "random street bonk is assault")
		local function with(k, v)
			local c = table.clone(base)
			c[k] = v
			return c
		end
		t.ok(not CombatService.shouldAddAssaultHeat(with("attackerInOwnGarage", true)), "defending home")
		t.ok(not CombatService.shouldAddAssaultHeat(with("victimInAttackerGarage", true)), "raider in garage")
		t.ok(not CombatService.shouldAddAssaultHeat(with("victimStealingFromAttacker", true)), "thief of your car")
		t.ok(not CombatService.shouldAddAssaultHeat(with("victimWanted", 2)), "wanted criminal")
	end)

	t.test("defend contract: any thief bonked out of a Stolen car, or a wanted Loot driver", function()
		local counts = CombatService.countsAsThiefBonk
		t.ok(counts("Stolen", 0), "player thief (any attacker, not just the victim)")
		t.ok(counts("Stolen", 3))
		t.ok(counts("Loot", 1), "wanted car thief")
		t.ok(not counts("Loot", 0), "clean loot driver")
		t.ok(not counts("Owned", 5), "own car")
		t.ok(not counts("Traffic", 2))
		t.ok(not counts(nil, 2))
	end)

	t.test("segmentCrossesStrip: swept crossing, misses and height", function()
		local hw, hd, h = 8.5, 2.5, 9
		-- driving straight across the strip between two samples (never inside the footprint at a sample)
		t.ok(CombatService.segmentCrossesStrip(V3.new(0, 2, -10), V3.new(0, 2, 10), hw, hd, h), "swept cross")
		-- sitting on it
		t.ok(CombatService.segmentCrossesStrip(V3.new(3, 2, 0.5), V3.new(3, 2, 0.5), hw, hd, h), "stationary on")
		-- passing beside it
		t.ok(not CombatService.segmentCrossesStrip(V3.new(12, 2, -10), V3.new(12, 2, 10), hw, hd, h), "beside")
		-- flying over it
		t.ok(not CombatService.segmentCrossesStrip(V3.new(0, 20, -10), V3.new(0, 20, 10), hw, hd, h), "airborne")
		-- not reaching it yet
		t.ok(not CombatService.segmentCrossesStrip(V3.new(0, 2, -20), V3.new(0, 2, -5), hw, hd, h), "short")
		-- diagonal that enters the lane edge right at the strip
		t.ok(CombatService.segmentCrossesStrip(V3.new(-14, 2, -6), V3.new(-2, 2, 6), hw, hd, h), "diagonal")
	end)

	t.test("isSamePlayer accepts Player or userId", function()
		local fake = { UserId = 42 }
		t.ok(CombatService.isSamePlayer(fake, fake))
		t.ok(CombatService.isSamePlayer(42, fake))
		t.ok(not CombatService.isSamePlayer(7, fake))
		t.ok(not CombatService.isSamePlayer(nil, fake))
	end)

	t.test("buildTool: every gadget is a Tool with a welded Handle + ToolId", function()
		for _, id in Economy.GadgetOrder do
			local tool = CombatService.buildTool(id)
			t.ok(tool ~= nil, id .. " builds")
			t.eq(tool.ClassName, "Tool", id)
			t.eq(tool:GetAttribute("ToolId"), id, id .. " ToolId")
			t.ok(tool.RequiresHandle, id .. " RequiresHandle")
			t.ok(not tool.CanBeDropped, id .. " not droppable")
			t.ok(#tool.ToolTip > 0, id .. " ToolTip")
			local handle = tool:FindFirstChild("Handle")
			t.ok(handle and handle:IsA("BasePart"), id .. " Handle")
			local parts = 0
			for _, d in tool:GetDescendants() do
				if d:IsA("BasePart") then
					parts += 1
					t.ok(not d.Anchored, id .. " part anchored: " .. d.Name)
					t.ok(not d.CanCollide, id .. " part collides: " .. d.Name)
					if d ~= handle then
						local w = d:FindFirstChildOfClass("WeldConstraint")
						t.ok(w and w.Part0 == handle and w.Part1 == d, id .. " part not welded: " .. d.Name)
					end
				end
			end
			t.ok(parts >= 4 and parts <= 16, id .. " part count " .. parts)
		end
		t.eq(CombatService.buildTool("rocket_launcher"), nil)
		t.eq(CombatService.buildTool("bat"), nil, "the bat is a WeaponService melee weapon in v2")
	end)

	t.test("buildTool: realistic stun gun (no neon, muzzle on the handle)", function()
		local zap = CombatService.buildTool("taser")
		t.ok(zap.Handle:FindFirstChild("Muzzle"), "muzzle attachment")
		t.eq(zap.Name, Economy.Tools.taser.name)
		for _, d in zap:GetDescendants() do
			if d:IsA("BasePart") then
				t.ok(d.Material ~= H.roblox.Enum.Material.Neon, "no neon: " .. d.Name)
			end
		end
	end)

	t.test("buildSpikeStrip: anchored, flat on the ground, trigger volume", function()
		local ground = CF.new(10, 0, 20) * CF.Angles(0, math.rad(30), 0)
		local model = CombatService.buildSpikeStrip(ground)
		t.eq(model.Name, "SpikeStrip")
		t.ok(model.PrimaryPart and model.PrimaryPart.Name == "Base", "PrimaryPart")
		local trigger = model:FindFirstChild("Trigger")
		t.ok(trigger and trigger.Transparency == 1 and trigger.CanTouch and not trigger.CanCollide, "trigger")
		local spikes = 0
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				t.ok(d.Anchored, "anchored " .. d.Name)
				if d.Name ~= "Trigger" then
					t.ok(not d.CanCollide and not d.CanQuery, "no collide/query " .. d.Name)
					local localPos = ground:PointToObjectSpace(d.CFrame.Position)
					t.ok(localPos.Y > -0.01 and localPos.Y < 1.2, "sits on the ground " .. d.Name)
				end
				if d.Name == "Spike" then
					spikes += 1
					t.eq(d.Material, H.roblox.Enum.Material.Metal, "steel spike (no neon)")
				end
			end
		end
		t.ok(spikes >= 6, "spikes " .. spikes)
	end)

	-- EffectsController pure helpers ------------------------------------------------------------------------------
	local okFx, Effects = pcall(H.require, "src/client/Controllers/EffectsController")
	t.test("EffectsController loads headless", function()
		t.ok(okFx, tostring(Effects))
	end)
	if not okFx then
		return
	end

	t.test("rarity tags: Rare+ street/traffic/hot drop/unoccupied loot within range", function()
		local show = Effects.shouldShowRarityTag
		t.ok(show("Parked", 3, false, 50), "rare parked")
		t.ok(show("Traffic", 6, true, 149), "mythic traffic (NPC driver)")
		t.ok(show("HotDrop", 5, false, 10), "hot drop")
		t.ok(show("Loot", 4, false, 10), "dropped loot")
		t.ok(not show("Loot", 4, true, 10), "loot being driven")
		t.ok(not show("Parked", 2, false, 10), "uncommon")
		t.ok(not show("Parked", 4, false, 151), "too far")
		t.ok(not show("Owned", 7, false, 10), "owned")
		t.ok(not show("Police", 3, false, 10), "police")
		t.ok(not show(nil, 5, false, 10), "no kind")
	end)

	t.test("heli renderer: extrapolates the published pose, bounded", function()
		local CF = H.roblox.CFrame
		local target = CF.new(10, 80, 0)
		local vel = V3.new(100, 0, 0)
		local g0 = Effects.heliGoal(target, vel, 0)
		t.near((g0.Position - target.Position).Magnitude, 0, 1e-9, "fresh sample: the sample itself")
		local g1 = Effects.heliGoal(target, vel, 0.1)
		t.near(g1.Position.X, 20, 1e-6, "carried along the velocity")
		local g2 = Effects.heliGoal(target, vel, 5)
		t.near(g2.Position.X, 10 + 100 * 0.25, 1e-6, "extrapolation is capped")
		t.near(Effects.heliGoal(target, vel, -1).Position.X, 10, 1e-6, "no negative lead")
	end)

	t.test("boltPoints: pinned ends, bounded jitter", function()
		local a, b = V3.new(0, 5, 0), V3.new(40, 5, 0)
		local pts = Effects.boltPoints(a, b, 8, 2, H.Random.new(7))
		t.eq(#pts, 9, "segments + 1 points")
		t.eq(pts[1], a)
		t.eq(pts[9], b)
		for i = 2, 8 do
			local p = pts[i]
			t.near(p.X, (i - 1) * 5, 1e-6, "x along the bolt")
			local off = math.sqrt((p.Y - 5) ^ 2 + p.Z ^ 2)
			t.ok(off <= 2 * math.sqrt(2) + 1e-6, "jitter bounded")
		end
		-- degenerate and vertical bolts don't explode
		t.eq(#Effects.boltPoints(a, a, 8, 2, H.Random.new(1)), 2)
		t.eq(#Effects.boltPoints(a, a + V3.new(0, 30, 0), 6, 2, H.Random.new(1)), 7)
	end)

	t.test("tagText: rarity, name and income", function()
		local Cars = H.require("src/shared/Config/Cars")
		local Rarity = H.require("src/shared/Config/Rarity")
		local def
		for _, d in Cars.List do
			if Rarity.Tiers[d.rarity].order == 4 then
				def = d
				break
			end
		end
		t.ok(def, "an Epic car exists")
		local text = Effects.tagText(def.id, "Gold")
		t.ok(text:find("EPIC", 1, true), text)
		t.ok(text:find(def.name, 1, true), text)
		t.ok(text:find("/s", 1, true), text)
		t.eq(Effects.tagText("not_a_car", "None"), nil)
	end)
end
