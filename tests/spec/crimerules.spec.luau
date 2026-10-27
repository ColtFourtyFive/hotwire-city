--!nocheck
-- Combat v2 crimes and side rules (gta_combat §8, §9.5): CrimeRules heat / menace / revenge / bounty / witnesses,
-- Ragdoll joint conversion (joints never break), VehicleService tire hits.
return function(t)
	local H = t.H
	local V3 = H.roblox.Vector3
	local CF = H.roblox.CFrame
	local Instance = H.roblox.Instance
	local Police = H.require("src/shared/Config/Police")
	local Economy = H.require("src/shared/Config/Economy")
	local CrimeRules = H.require("src/shared/Combat/CrimeRules")
	local Ragdoll = H.require("src/shared/Combat/Ragdoll")
	local VehicleService = H.require("src/server/Systems/VehicleService")
	local CombatService = H.require("src/server/Systems/CombatService")

	t.test("starsAfter: floors, adds, copDown escalation, clamps", function()
		t.eq(CrimeRules.starsAfter(0, "gunfire"), 1, "gunfire puts you at 1")
		t.eq(CrimeRules.starsAfter(3, "gunfire"), 3, "gunfire never stacks per shot")
		t.eq(CrimeRules.starsAfter(0, "brandish"), 1)
		t.eq(CrimeRules.starsAfter(1, "brandish"), 2, "brandishing while wanted escalates")
		t.eq(CrimeRules.starsAfter(0, "copShot"), 2)
		t.eq(CrimeRules.starsAfter(0, "copDown", 1), 3, "first cop down: 3 stars")
		t.eq(CrimeRules.starsAfter(3, "copDown", 1 + Police.COPS_DOWNED_PER_EXTRA_STAR), 4, "+1 per 3 more")
		t.eq(CrimeRules.starsAfter(0, "heliDown"), 5)
		t.eq(CrimeRules.starsAfter(5, "pedDown"), 5, "never above 5")
		t.eq(CrimeRules.starsAfter(1, "pedDown", nil, true), Police.PED_HEAT_CAP, "pedestrians alone cap the heat")
		t.eq(CrimeRules.starsAfter(4, "pedDown", nil, true), 4, "the cap never lowers stars")
		t.eq(CrimeRules.starsAfter(0, "pvpDown"), 2)
	end)

	t.test("v1 rules re-exported by CombatService", function()
		local ctx = {
			attackerInOwnGarage = false,
			victimInAttackerGarage = false,
			victimStealingFromAttacker = false,
			victimWanted = 0,
		}
		t.ok(CrimeRules.shouldAddAssaultHeat(ctx))
		t.eq(CombatService.shouldAddAssaultHeat(ctx), true)
		ctx.victimWanted = 2
		t.ok(not CrimeRules.shouldAddAssaultHeat(ctx), "vigilante")
		t.ok(CrimeRules.countsAsThiefBonk("Stolen", 0))
		t.ok(CrimeRules.countsAsThiefBonk("Loot", 1))
		t.ok(not CrimeRules.countsAsThiefBonk("Loot", 0))
		t.eq(CombatService.countsAsThiefBonk("Stolen", 0), true)
	end)

	t.test("menace: 3 downs or 2 rookie downs in 5 minutes; history pruned", function()
		local h = { { t = 0, rookie = false }, { t = 10, rookie = false } }
		t.ok(not CrimeRules.isMenace(h, 20))
		table.insert(h, { t = 30, rookie = false })
		t.ok(CrimeRules.isMenace(h, 40))
		local r = { { t = 0, rookie = true }, { t = 5, rookie = true } }
		t.ok(CrimeRules.isMenace(r, 10), "rookie hunting")
		local old = { { t = 0, rookie = false }, { t = 1, rookie = false }, { t = 2, rookie = false } }
		t.ok(not CrimeRules.isMenace(old, 1000), "old downs expire")
		t.eq(#old, 0, "pruned in place")
	end)

	t.test("revenge immunity and bounties", function()
		t.ok(CrimeRules.revengeTriggered({ 0, 100 }, 120))
		t.ok(not CrimeRules.revengeTriggered({ 0, 100 }, 400), "too spread out")
		t.eq(CrimeRules.bounty(3, 1e6, 100), 0, "below 4 stars")
		local b = CrimeRules.bounty(4, 10000, 1000)
		t.eq(
			b,
			math.floor(
				math.min(10000 * Economy.BOUNTY_CASH_FRACTION, 4 * Economy.BOUNTY_INCOME_SECONDS_PER_STAR * 1000)
			)
		)
		t.ok(CrimeRules.bountyPairReady(nil, 0))
		t.ok(not CrimeRules.bountyPairReady(0, 10))
		t.ok(CrimeRules.bountyPairReady(0, Economy.BOUNTY_PAIR_COOLDOWN))
	end)

	t.test("witnesses: peds within 60, cops within 120 (gunshots heard)", function()
		local pos = V3.new(0, 0, 0)
		t.ok(CrimeRules.witnessed(pos, { V3.new(30, 0, 0) }, {}, false))
		t.ok(not CrimeRules.witnessed(pos, { V3.new(90, 0, 0) }, {}, false))
		t.ok(CrimeRules.witnessed(pos, {}, { V3.new(100, 0, 0) }, true))
		t.ok(not CrimeRules.witnessed(pos, {}, {}, true), "nobody around")
	end)

	t.test("Ragdoll: motors become limited ball sockets (root stays), restore stands back up", function()
		local model = Instance.new("Model")
		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Parent = model
		local torso = Instance.new("Part")
		torso.Name = "UpperTorso"
		torso.Parent = model
		local arm = Instance.new("Part")
		arm.Name = "LeftUpperArm"
		arm.Parent = model
		local rootJoint = Instance.new("Motor6D")
		rootJoint.Name = "Root"
		rootJoint.Part0 = root
		rootJoint.Part1 = torso
		rootJoint.Parent = torso
		local shoulder = Instance.new("Motor6D")
		shoulder.Name = "LeftShoulder"
		shoulder.Part0 = torso
		shoulder.Part1 = arm
		shoulder.C0 = CF.new(-1, 0.5, 0)
		shoulder.Parent = arm
		t.eq(Ragdoll.enable(model), 1, "only the shoulder converts")
		t.ok(Ragdoll.isRagdolled(model))
		t.eq(shoulder.Enabled, false, "motor disabled, not destroyed")
		t.eq(rootJoint.Enabled, true)
		local bs = arm:FindFirstChild(Ragdoll.TAG_PREFIX_BS .. "LeftShoulder")
		t.ok(bs ~= nil and bs.LimitsEnabled, "limited socket")
		t.eq(bs.UpperAngle, Ragdoll.limitsFor("LeftShoulder").upper)
		t.eq(arm.Parent, model, "limb stays attached (no gore)")
		t.eq(Ragdoll.enable(model), 0, "idempotent")
		t.eq(Ragdoll.restore(model), 1)
		t.ok(not Ragdoll.isRagdolled(model))
		t.eq(shoulder.Enabled, true)
	end)

	t.test("VehicleService._isTireHit: wheel parts or near a hub", function()
		local hubs = { V3.new(3, 1, 5), V3.new(-3, 1, 5) }
		t.ok(VehicleService._isTireHit("WheelFL", V3.new(100, 0, 0), {}))
		t.ok(VehicleService._isTireHit("Body", V3.new(3, 1.5, 5.5), hubs))
		t.ok(not VehicleService._isTireHit("Body", V3.new(0, 2, 0), hubs))
		t.ok(not VehicleService._isTireHit(nil, V3.new(0, 2, 0), hubs))
	end)
end
