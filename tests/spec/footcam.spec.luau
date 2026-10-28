--!nocheck
-- C4a characters: the on-foot GTA feel. Appearance/FootTuning (speeds, stamina, sprint arbitration with the stun /
-- weapon-wheel writers, the default-camera post-process maths: lag spring, collision pull-in, recentre, FOV, zoom
-- limits, who owns the camera), FootService (server fall damage + ragdoll through its seams), the touch SPRINT button
-- placement on the shared HUD layout, the name-tag rules, and the client controllers' public defaults.
return function(t)
	local H = t.H
	local fs = require("@lune/fs")
	local V3 = H.roblox.Vector3
	local F = H.require("src/shared/Appearance/FootTuning")

	-- MOVEMENT ----------------------------------------------------------------------------------------------------

	t.test("speeds: walk ~10, jog ~16 (default), sprint ~24; aiming walks", function()
		t.eq(F.speedFor("walk"), 10, "walk")
		t.eq(F.speedFor("jog"), 16, "jog")
		t.eq(F.speedFor("sprint"), 24, "sprint")
		t.ok(F.speedFor("sprint", true) <= F.WALK, "aiming slows to a walk")
		t.eq(F.JUMP_HEIGHT, 4.5, "short, heavy jump")
		local project = fs.readFile("default.project.json")
		t.ok(project:find('"CharacterWalkSpeed": 16', 1, true) ~= nil, "spawn speed = jog")
		t.ok(project:find('"CharacterJumpHeight": 4.5', 1, true) ~= nil, "JumpHeight 4.5")
		t.ok(project:find('"CharacterUseJumpPower": false', 1, true) ~= nil, "JumpHeight, not JumpPower")
		t.ok(project:find('"EnableMouseLockOption": false', 1, true) ~= nil, "Shift is sprint, not shift-lock")
		t.ok(project:find('"Gravity": 196.2', 1, true) ~= nil, "gravity unchanged (vehicle tuning)")
		t.ok(project:find('"NameDisplayDistance": 0', 1, true) ~= nil, "no Roblox overhead names")
	end)

	t.test("modeFor: sprint needs input, movement, stamina and no aim; walk key", function()
		t.eq(F.modeFor(true, false, true, false, false), "sprint", "sprint")
		t.eq(F.modeFor(true, false, false, false, false), "jog", "standing still")
		t.eq(F.modeFor(true, false, true, true, false), "jog", "aiming")
		t.eq(F.modeFor(true, false, true, false, true), "jog", "exhausted")
		t.eq(F.modeFor(false, true, true, false, false), "walk", "walk key")
		t.eq(F.modeFor(false, false, true, false, false), "jog", "default jog")
	end)

	t.test("stamina: drains in ~9 s, refills after a pause, exhaustion needs a recovery margin", function()
		local s, ex, since = 1, false, 0
		local secs = 0
		while s > 0 and secs < 30 do
			s, ex, since = F.stepStamina(s, true, ex, since, 0.1)
			secs += 0.1
		end
		t.near(secs, 1 / F.STAMINA_DRAIN, 0.15, "drain time")
		t.ok(ex, "exhausted when dry")
		-- no refill during the delay
		local s2, ex2, since2 = F.stepStamina(0, false, true, 0, F.STAMINA_REGEN_DELAY * 0.5)
		t.eq(s2, 0, "pause before refilling")
		-- refill; exhaustion clears only above STAMINA_RECOVER
		for _ = 1, 20 do
			s2, ex2, since2 = F.stepStamina(s2, false, ex2, since2, 0.1)
		end
		t.ok(s2 > 0 and s2 < F.STAMINA_RECOVER and ex2, "still exhausted while low")
		for _ = 1, 100 do
			s2, ex2, since2 = F.stepStamina(s2, false, ex2, since2, 0.1)
		end
		t.eq(s2, 1, "full")
		t.ok(not ex2, "recovered")
		local s3 = F.stepStamina(0 / 0, false, false, 99, 0.1)
		t.eq(s3, 1, "NaN stamina -> full")
	end)

	t.test("mayWrite: never fights the stun freeze (0) or the weapon wheel's half speed", function()
		local ours = F.ownSpeeds()
		t.ok(F.mayWrite(18, nil, ours), "first write")
		t.ok(F.mayWrite(16, 16, ours), "still ours")
		t.ok(F.mayWrite(24, 16, ours), "restored to one of ours")
		t.ok(not F.mayWrite(0, 16, ours), "stun freeze left alone")
		for _, v in ours do
			t.ok(not F.mayWrite(v * 0.5, v, ours) or table.find(ours, v * 0.5) ~= nil, "wheel slow walk left alone")
		end
		t.ok(not F.mayWrite(0, 4.5, { F.JUMP_HEIGHT }), "jump freeze left alone")
		t.eq(F.jumpHeightFor(0.1), 0, "landing cooldown")
		t.eq(F.jumpHeightFor(F.JUMP_COOLDOWN + 0.01), F.JUMP_HEIGHT, "jump back")
	end)

	-- CAMERA ------------------------------------------------------------------------------------------------------

	t.test("camera numbers: FOV 58 on foot with a sprint kick; shoulder offset right; zoom range", function()
		t.ok(F.FOV >= 55 and F.FOV <= 60, "vertical FOV 55-60 on foot")
		t.ok(F.targetFov(true) > F.targetFov(false), "sprint kick")
		t.ok(F.SHOULDER > 0, "slightly right")
		t.eq(F.shoulderAt(F.DIST_MAX), F.SHOULDER, "full offset at range")
		t.eq(F.shoulderAt(F.FIRST_PERSON), 0, "none in first person")
		t.ok(F.shoulderAt((F.FIRST_PERSON + F.DIST_MIN) / 2) < F.SHOULDER, "fades in between")
		local mn, mx = F.zoomLimits(false)
		t.eq(mx, F.DIST_MAX, "foot max zoom")
		t.ok(mn <= F.FIRST_PERSON, "first person allowed")
		local _, cmx = F.zoomLimits(true)
		t.ok(cmx > F.DIST_MAX, "the chase cam gets room")
		t.ok(F.DIST_DEFAULT >= F.DIST_MIN and F.DIST_DEFAULT <= F.DIST_MAX, "default inside the range")
	end)

	t.test("smoothDamp: the lag spring converges without overshoot; bigger smooth time lags more", function()
		local x, v = 0, 0
		local prev = 0
		for _ = 1, 120 do
			x, v = F.smoothDamp(x, 10, v, F.LAG_XZ, 1 / 60)
			t.ok(x >= prev - 1e-9 and x <= 10 + 1e-6, "monotonic, no overshoot")
			prev = x
		end
		t.near(x, 10, 1e-3, "converged in 2 s")
		local a = F.smoothDamp(0, 10, 0, F.LAG_XZ, 1 / 60)
		local b = F.smoothDamp(0, 10, 0, F.LAG_Y, 1 / 60)
		t.ok(b < a, "vertical lags more than horizontal")
	end)

	t.test("collisionStep: pulls in at once and never past a wall, eases back out without popping", function()
		local d, v = 11, 0
		-- a wall at 3 studs: never further than the wall, even on the first frame
		d, v = F.collisionStep(d, v, 11, 3, 1 / 60)
		t.ok(d <= 3 + 1e-9, "clamped to the wall")
		for _ = 1, 10 do
			d, v = F.collisionStep(d, v, 11, 3, 1 / 60)
			t.ok(d <= 3 + 1e-9, "stays in front of the wall")
		end
		-- wall gone: eases out (no single-frame pop)
		local before = d
		d, v = F.collisionStep(d, v, 11, nil, 1 / 60)
		t.ok(d > before and d - before < 2, "eases out, no pop")
		for _ = 1, 240 do
			d, v = F.collisionStep(d, v, 11, nil, 1 / 60)
		end
		t.near(d, 11, 0.05, "back to the zoom")
		local tight = F.collisionStep(5, 0, 11, 0.1, 1 / 60)
		t.eq(tight, F.MIN_DIST, "minimum distance")
		t.ok(F.isThin(V3.new(0.5, 12, 0.5)), "lamp post is thin")
		t.ok(not F.isThin(V3.new(20, 12, 1)), "wall is not")
	end)

	t.test("recentre: swings behind a running player after a pause, never when running at the lens", function()
		t.ok(F.shouldRecenter(16, 2, false, 0.5), "running, idle camera")
		t.ok(not F.shouldRecenter(8, 2, false, 0.5), "walking")
		t.ok(not F.shouldRecenter(16, 0.2, false, 0.5), "player just moved the camera")
		t.ok(not F.shouldRecenter(16, 2, true, 0.5), "first person")
		t.ok(not F.shouldRecenter(16, 2, false, math.rad(170)), "running back toward the lens")
		local yaw = 0
		for _ = 1, 600 do
			yaw = F.recenterYaw(yaw, math.rad(90), 1 / 60)
		end
		t.near(yaw, math.rad(90), 1e-3, "converges on the heading")
		t.near(F.angleDelta(math.rad(170), math.rad(-170)), math.rad(20), 1e-9, "shortest way round")
		t.near(F.yawOf(0, -1), 0, 1e-9, "-Z is yaw 0")
		t.ok(F.lookInput(0, 0, 0.01, 0), "yaw change = input")
		t.ok(not F.lookInput(0, 0, 0, 0), "no change")
		t.ok(not F.lookInput(nil, nil, 1, 1), "first frame is not input")
	end)

	t.test("footCamActive: a Scriptable camera, a seat, the shoulder cam or the creator always win", function()
		local base = {
			cameraType = "Custom",
			alive = true,
			seated = false,
			shoulderEngaged = false,
			creatorOpen = false,
			subjectIsHumanoid = true,
		}
		t.ok(F.footCamActive(base), "on foot")
		for k, v in
			{
				cameraType = "Scriptable",
				alive = false,
				seated = true,
				shoulderEngaged = true,
				creatorOpen = true,
				subjectIsHumanoid = false,
			}
		do
			local c = table.clone(base)
			c[k] = v
			t.ok(not F.footCamActive(c), k .. " wins over the foot camera")
		end
		-- ShoulderCamera's public API (combat owns aiming) is untouched
		local src = fs.readFile("src/client/Controllers/ShoulderCamera.luau")
		t.ok(src:find("function ShoulderCamera.setSuspended(reason: string, on: boolean)", 1, true) ~= nil, "API")
	end)

	-- FALLS -------------------------------------------------------------------------------------------------------

	t.test("fallDamage: none under ~4 m, a ragdoll from ~7 m, lethal from ~17 m", function()
		local g = 196.2
		local function hit(h)
			return F.fallDamage(F.speedFromDrop(h, g), g)
		end
		local d0, r0 = hit(F.FALL_SAFE - 1)
		t.eq(d0, 0, "safe drop")
		t.eq(r0, 0, "no ragdoll")
		local d1, r1 = hit(F.FALL_SAFE + 2)
		t.ok(d1 > 0 and d1 < 30, "a sting")
		t.eq(r1, 0, "no ragdoll on a small drop")
		local d2, r2 = hit(F.FALL_RAGDOLL + 4)
		t.ok(d2 > d1 and d2 < 100, "hurts")
		t.ok(r2 >= F.RAGDOLL_MIN and r2 <= F.RAGDOLL_MAX, "brief ragdoll")
		local d3, _, lethal3 = hit(F.FALL_LETHAL + 1)
		t.eq(d3, 100, "lethal")
		t.ok(lethal3, "flagged lethal")
		local _, _, lethal2 = hit(F.FALL_RAGDOLL + 4)
		t.ok(not lethal2, "a survivable fall is not")
		local DM = H.require("src/shared/Combat/DamageModel")
		t.eq(F.FALL_THROUGH_ARMOR, DM.MAX_HEALTH + DM.MAX_ARMOR, "a lethal fall deals health + armor")
		t.near(F.dropFromSpeed(F.speedFromDrop(20, g), g), 20, 1e-9, "inverse")
		t.eq(F.landingImpact(-5, 0, g), 0, "slow landing ignored")
		local fast = -F.speedFromDrop(30, g)
		t.near(F.landingImpact(fast, 0, g), -fast, 1e-9, "hard landing")
		t.eq(F.landingImpact(fast, fast * 0.9, g), 0, "still falling")
	end)

	t.test("FootService: hard landings hurt and ragdoll; seats, spawns, water and ragdolls are ignored", function()
		H.setMode("server")
		local FS = H.require("src/server/Systems/FootService")
		local damage = {}
		local delayed = {}
		local water = false
		local waterChar = nil
		local now = 1000
		FS._setHooks({
			gravity = function()
				return 196.2
			end,
			serverTime = function()
				return now
			end,
			damage = function(p, amount)
				table.insert(damage, amount)
				return amount >= 100
			end,
			inWater = function(_pos, c)
				waterChar = c
				return water
			end,
			delay = function(s, fn)
				table.insert(delayed, { s = s, fn = fn })
			end,
		})
		local function fakePart(props)
			local o = props or {}
			o.Name = o.Name or "Part"
			o.IsA = function(_, c)
				return c == "BasePart"
			end
			return o
		end
		local attrs = {}
		local hum = { Health = 100, SeatPart = nil, RequiresNeck = true }
		local root =
			fakePart({ Name = "HumanoidRootPart", AssemblyLinearVelocity = V3.zero, Position = V3.new(0, 5, 0) })
		local char = {
			Name = "Char",
			GetAttribute = function(_, k)
				return attrs[k]
			end,
			SetAttribute = function(_, k, v)
				attrs[k] = v
			end,
			FindFirstChildOfClass = function(_, c)
				return if c == "Humanoid" then hum else nil
			end,
			FindFirstChild = function(_, n)
				return if n == "HumanoidRootPart" then root else nil
			end,
			GetDescendants = function()
				return {}
			end,
			GetChildren = function()
				return {}
			end,
		}
		local pattrs = {}
		local p = {
			Name = "Faller",
			Character = char,
			GetAttribute = function(_, k)
				return pattrs[k]
			end,
		}
		FS._track(p)
		local function fall(h, t0)
			root.AssemblyLinearVelocity = V3.new(0, -F.speedFromDrop(h, 196.2), 0)
			FS._sample(p, t0)
			root.AssemblyLinearVelocity = V3.zero
			return FS._sample(p, t0 + 0.02)
		end
		FS._sample(p, 0) -- spawn
		t.eq(fall(40, 1), 0, "spawn grace")
		t.eq(#damage, 0, "no damage in the grace")
		local impact = fall(F.FALL_RAGDOLL + 6, 10)
		t.ok(impact > 0, "landing detected")
		t.eq(#damage, 1, "damaged")
		t.ok(typeof(attrs[FS.ATTR]) == "number" and attrs[FS.ATTR] > now, "ragdolled (attribute for the client)")
		t.ok(FS.isRagdolled(p), "isRagdolled")
		t.eq(fall(F.FALL_RAGDOLL + 6, 20), 0, "no second hit while ragdolled")
		-- stand up
		for _, d in delayed do
			d.fn()
		end
		t.ok(attrs[FS.ATTR] == nil, "got up")
		hum.SeatPart = {}
		t.eq(fall(40, 30), 0, "seated")
		hum.SeatPart = nil
		FS._sample(p, 30.5)
		t.eq(fall(40, 30.6), 0, "seat grace (leaving a moving car is not a fall)")
		water = true
		fall(40, 40)
		t.eq(#damage, 1, "water landing is free")
		t.eq(waterChar, char, "the water check is told whose body to ignore")
		water = false
		fall(F.FALL_LETHAL + 5, 50)
		t.eq(damage[#damage], F.FALL_THROUGH_ARMOR, "lethal fall goes through armor")
		-- in the creator studio (its teleports stop the body dead) and just after: no landing
		local before = #damage
		pattrs.HC_Creator = V3.new(-12000, 2400, -12000)
		t.eq(fall(40, 60), 0, "in the studio")
		pattrs.HC_Creator = nil
		FS._sample(p, 60.5)
		t.eq(fall(40, 60.6), 0, "grace after the studio")
		t.eq(#damage, before, "no damage from the studio teleports")
		local src = fs.readFile("src/server/Systems/FootService.luau")
		t.ok(
			src:find("FilterDescendantsInstances = if char then { char } else {}", 1, true) ~= nil,
			"own body excluded"
		)
		t.ok(src:find("ReadVoxels", 1, true) ~= nil, "terrain water at the root")
		H.setMode("server")
	end)

	-- TOUCH / TAGS ------------------------------------------------------------------------------------------------

	t.test("sprintRect: left of the jump / phone column where FIRE goes; above FIRE when armed", function()
		local HudLayout = H.require("src/client/UI/HudLayout")
		local L = HudLayout.compute(1280, 720, true, { scale = 1 })
		local jump = HudLayout.jumpButton(L.w, L.h, 1)
		local edge = jump.x
		for _, n in { "phone", "map" } do
			if L.buttons[n] then
				edge = math.min(edge, L.buttons[n].x)
			end
		end
		local bottom = jump.y + jump.h
		local un = F.sprintRect(edge, bottom, false, 110)
		t.ok(un.x + un.w <= edge, "left of the column")
		t.near(un.y + un.h, bottom, 1e-9, "level with the jump button")
		-- on foot only PHONE / MAP are up (the driving cluster hides with the sprint button)
		for _, name in { "phone", "map" } do
			local b = L.buttons[name]
			if b then
				t.ok(not HudLayout.overlaps(un, b), "no overlap with " .. name)
			end
		end
		t.ok(not HudLayout.overlaps(un, jump), "no overlap with jump")
		-- armed: clear of every combat touch button (WeaponClient.touchRects on the same layout)
		H.setMode("client")
		local WC = H.require("src/client/Controllers/WeaponClient")
		local rects = WC.touchRects(L, jump)
		local armed = F.sprintRect(edge, bottom, true, WC.FIRE_BUTTON)
		for name, r in rects do
			t.ok(not HudLayout.overlaps(armed, r), "armed: clear of " .. name)
		end
		t.ok(armed.y + armed.h <= rects.fire.y, "above FIRE")
		t.ok(HudLayout.inside(armed, L.w, L.h) and HudLayout.inside(un, L.w, L.h), "on screen")
		-- the FIRE rect is in use for ANYTHING in hand (FIRE gun, HIT melee / fists, STUN taser): SPRINT moves up
		t.ok(HudLayout.overlaps(un, rects.fire), "(the empty-hands spot is where FIRE / HIT / STUN go)")
		t.ok(not F.fireRectInUse(nil), "empty hands")
		for _, id in { "pistol", "bat", "fists", "taser" } do
			t.ok(F.fireRectInUse(id), id .. " uses the FIRE rect")
		end
		local fm = fs.readFile("src/client/Controllers/FootMovement.luau")
		t.ok(
			fm:find('F%a*%.fireRectInUse%(call%("WeaponClient", "equipped"%)%)') ~= nil,
			"FootMovement asks equipped()"
		)
		t.ok(not fm:find('"isGunDrawn"', 1, true), "not only guns")
		H.setMode("server")
	end)

	t.test("name tags: within 40 studs, fading out, none in combat / streamer mode / creator", function()
		t.eq(F.TAG_DISTANCE, 40, "40 studs")
		t.ok(F.tagVisible(10, false, false, false), "close")
		t.ok(not F.tagVisible(41, false, false, false), "too far")
		t.ok(not F.tagVisible(10, true, false, false), "in combat")
		t.ok(not F.tagVisible(10, false, true, false), "HUD hidden")
		t.ok(not F.tagVisible(10, false, false, true), "target in the creator")
		t.eq(F.tagFade(10), 0, "opaque near")
		t.ok(F.tagFade(35) > 0 and F.tagFade(35) < 1, "fading")
		t.eq(F.tagFade(40), 1, "gone at the edge")
		t.ok(F.TAG_SIZE <= 14, "small text")
		-- measured from the local character; the engine's camera-based MaxDistance never cuts a tag sooner
		H.setMode("client")
		local NT = H.require("src/client/Controllers/NameTags")
		H.setMode("server")
		t.ok(NT.MAX_DISTANCE >= F.TAG_DISTANCE + F.DIST_MAX, "MaxDistance covers the camera's distance")
		local src = fs.readFile("src/client/Controllers/NameTags.luau")
		t.ok(src:find('player:WaitForChild("PlayerGui")', 1, true) ~= nil, "tags parented straight to PlayerGui")
		t.ok(not src:find('Instance.new("Folder")', 1, true), "no Folder (cleared on the local respawn)")
		t.ok(src:find("t.gui.Parent == nil", 1, true) ~= nil, "a tag that lost its parent is rebuilt")
		t.ok(src:find('FindFirstChild("HumanoidRootPart")', 1, true) ~= nil, "range from the character")
	end)

	t.test("emotes: /e and /emote are swallowed; default emote tracks are stopped", function()
		H.setMode("client")
		local FM = H.require("src/client/Controllers/FootMovement")
		H.setMode("server")
		for _, e in { "wave", "point", "dance", "dance2", "dance3", "laugh", "cheer" } do
			t.ok(FM.DEFAULT_EMOTES[e], e .. " stopped")
		end
		local src = fs.readFile("src/client/Controllers/FootMovement.luau")
		t.ok(src:find('cmd.PrimaryAlias = "/e"', 1, true) ~= nil, "/e swallowed")
		t.ok(src:find('cmd.SecondaryAlias = "/emote"', 1, true) ~= nil, "/emote swallowed")
		t.ok(src:find("AnimationPlayed", 1, true) ~= nil, "tracks watched")
		t.ok(src:find("OWN_SPEEDS", 1, true) ~= nil, "no per-frame speed table")
		t.ok(F.isThin(V3.new(0.3, 0.3, 9)), "isThin still right without its table")
		t.ok(not F.isThin(V3.new(0.3, 9, 9)), "one thin axis is a wall")
	end)

	t.test("mouse: captured on foot (desktop), handed to the shoulder cam, freed for any Modal UI", function()
		H.setMode("client")
		local FC = H.require("src/client/Controllers/FootCamera")
		H.setMode("server")
		t.eq(FC.mouseCaptured(), false, "not captured before start")
		FC.setCursor("test", true)
		FC.setCursor("test", false)
		local src = fs.readFile("src/client/Controllers/FootCamera.luau")
		t.ok(src:find("Enum.MouseBehavior.LockCenter", 1, true) ~= nil, "LockCenter on foot")
		t.ok(src:find("MouseIconEnabled = false", 1, true) ~= nil, "no cursor on foot")
		t.ok(src:find("Modal == true", 1, true) ~= nil, "Modal buttons free it")
		t.ok(src:find("MenuIsOpen", 1, true) ~= nil, "Roblox's menu frees it")
		t.ok(src:find("if shoulderEngaged() then", 1, true) ~= nil, "the shoulder cam owns it while a gun is out")
		t.ok(src:find("UserInputService.MouseEnabled and UserInputService.KeyboardEnabled", 1, true) ~= nil)
		for _, f in { "src/client/UI/PauseMenu.luau", "src/client/UI/Phone.luau", "src/client/UI/ListMenu.luau" } do
			t.ok(fs.readFile(f):find("Modal = true", 1, true) ~= nil, f .. " carries a Modal button")
		end
	end)

	-- CLIENT CONTROLLERS ------------------------------------------------------------------------------------------

	t.test("client controllers: public defaults before start (no sprint, full stamina, creator closed)", function()
		H.setMode("client")
		local FM = H.require("src/client/Controllers/FootMovement")
		local FC = H.require("src/client/Controllers/FootCamera")
		local CC = H.require("src/client/Controllers/CharacterCreator")
		local NT = H.require("src/client/Controllers/NameTags")
		t.eq(FM.isSprinting(), false, "not sprinting")
		t.eq(FM.getStamina(), 1, "full stamina")
		t.eq(FM.mode(), "jog", "jog by default")
		t.eq(FC.isActive(), false, "foot camera idle")
		FC.setSuspended("test", true)
		FC.setSuspended("test", false)
		t.eq(CC.isOpen(), false, "creator closed")
		t.eq(CC.ownAvatar(), false, "own avatar off by default")
		t.eq(NT.count(), 0, "no tags")
		H.setMode("server")
	end)

	t.test("integration: boot ORDER lists the new systems / controllers; HUD reads Stamina", function()
		local server = fs.readFile("src/server/init.server.luau")
		t.ok(server:find('"AppearanceService"', 1, true) ~= nil, "AppearanceService in ORDER")
		t.ok(server:find('"FootService"', 1, true) ~= nil, "FootService in ORDER")
		local client = fs.readFile("src/client/init.client.luau")
		for _, n in { "FootCamera", "FootMovement", "NameTags", "CharacterCreator" } do
			t.ok(client:find('"' .. n .. '"', 1, true) ~= nil, n .. " in ORDER")
		end
		local hud = fs.readFile("src/client/Controllers/HUDController.luau")
		t.ok(hud:find('attrNumber("Stamina")', 1, true) ~= nil, "the third bar reads the Stamina attribute")
		local menu = fs.readFile("src/client/Controllers/MenuController.luau")
		t.ok(menu:find('label = "Wardrobe"', 1, true) ~= nil, "Settings > Wardrobe")
		t.ok(menu:find('label = "Use my Roblox avatar"', 1, true) ~= nil, "Settings > own avatar")
		local remotes = H.require("src/shared/Remotes")
		for _, n in { "AppearanceCreator", "AppearancePreview", "AppearanceSave", "AppearanceSetOwn" } do
			t.ok(table.find(remotes.ClientToServer, n) ~= nil, n .. " remote")
		end
	end)
end
