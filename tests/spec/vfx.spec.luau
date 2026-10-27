--!nocheck
-- VFX library: Config/VFX preset + texture shape, VFXLibrary pure helpers, budget, burst pooling (no live re-look),
-- attached bursts, streams (priority + rebalance + tier changes), trails; the effect math of VehicleClient /
-- WheelAnimator (tyre smoke, skid contact, speed-line ring, water parts, headlight picks, hero cones) and
-- EffectsController's handler -> preset wiring + siren glare lifecycle.
local fs = require("@lune/fs")
local serde = require("@lune/serde")

return function(t)
	local H = t.H
	local Vector3 = H.roblox.Vector3
	local Color3 = H.roblox.Color3
	local Instance = H.roblox.Instance
	local Enum = H.roblox.Enum
	local CFrame = H.roblox.CFrame
	local Vector2 = H.roblox.Vector2

	H.setMode("client")
	local VFX = H.require("src/shared/Config/VFX")
	local Lib = H.require("src/client/Controllers/VFXLibrary")

	local function checkSeq(keys, label, lo, hi)
		t.ok(type(keys) == "table" and #keys >= 2, label .. ": >= 2 keypoints")
		t.ok(#keys <= 20, label .. ": <= 20 keypoints (engine limit)")
		t.eq(keys[1].t, 0, label .. ": starts at t=0")
		t.eq(keys[#keys].t, 1, label .. ": ends at t=1")
		for i = 2, #keys do
			t.ok(keys[i].t > keys[i - 1].t, label .. ": strictly increasing times")
		end
		for _, k in keys do
			t.ok(type(k.v) == "number" and k.v == k.v, label .. ": numeric value")
			if lo then
				t.ok(k.v >= lo and k.v <= hi, label .. (": value in [%s, %s]"):format(lo, hi))
			end
			if k.e then
				t.ok(k.e >= 0 and k.e <= math.max(k.v, 0) + 1e-9, label .. ": 0 <= envelope <= value")
			end
		end
	end

	local function checkRange(r, label)
		t.ok(type(r) == "table" and #r >= 1 and #r <= 2, label .. ": {min, max}")
		t.ok((r[2] or r[1]) >= r[1], label .. ": min <= max")
	end

	local function isEnumName(enum, name)
		if name == nil then
			return true
		end
		for _, item in enum:GetEnumItems() do
			if item.Name == name then
				return true
			end
		end
		return false
	end

	---------------------------------------------------------------------------------------------------------------
	-- Config shape
	---------------------------------------------------------------------------------------------------------------

	t.test("VFX: every texture key has an uploaded rbxassetid and a fallback entry", function()
		local count = 0
		for key, id in VFX.Textures do
			count += 1
			t.ok(id:match("^rbxassetid://%d+$") ~= nil, key .. " id format")
			t.ok(VFX.Fallback[key] ~= nil, key .. " has a fallback entry")
		end
		t.ok(count >= 25, "full texture set uploaded (" .. count .. ")")
	end)

	t.test("VFX: Textures match assets/vfx/manifest.json (gen_luau.py is up to date)", function()
		local man = serde.decode("json", fs.readFile("assets/vfx/manifest.json"))
		for key, entry in man do
			t.eq(VFX.Textures[key], "rbxassetid://" .. tostring(entry.assetId), key)
			t.eq(entry.assetType, "Image", key .. " uploaded as an Image (Decal ids do not resolve as textures)")
			t.ok(fs.isFile(entry.file), key .. " source png exists")
		end
	end)

	t.test("VFX: particle presets are well formed", function()
		local n = 0
		for name, p in VFX.Presets do
			n += 1
			local label = "Preset " .. name
			t.ok(VFX.Textures[p.texture] ~= nil or VFX.Fallback[p.texture] ~= nil, label .. ": known texture")
			t.ok(p.kind == "burst" or p.kind == "stream", label .. ": kind")
			if p.kind == "burst" then
				t.ok(type(p.count) == "number" and p.count >= 1, label .. ": burst count")
				t.ok(p.pool == nil or (p.pool >= 1 and p.pool <= 8), label .. ": pool size")
			else
				t.ok(type(p.rate) == "number" and p.rate > 0, label .. ": stream rate")
			end
			checkRange(p.lifetime, label .. ".lifetime")
			t.ok(p.lifetime[1] > 0 and (p.lifetime[2] or p.lifetime[1]) <= 5, label .. ": lifetime 0..5 s")
			if p.speed then
				checkRange(p.speed, label .. ".speed")
			end
			if p.rotation then
				checkRange(p.rotation, label .. ".rotation")
			end
			if p.rotSpeed then
				checkRange(p.rotSpeed, label .. ".rotSpeed")
			end
			checkSeq(p.size, label .. ".size", 0, 60)
			checkSeq(p.transparency, label .. ".transparency", 0, 1)
			if p.squash then
				checkSeq(p.squash, label .. ".squash", -3, 3)
			end
			if p.color then
				t.ok(#p.color >= 2 and #p.color <= 20, label .. ".color keypoints")
				t.eq(p.color[1].t, 0, label .. ".color starts at 0")
				t.eq(p.color[#p.color].t, 1, label .. ".color ends at 1")
				for _, k in p.color do
					t.eq(typeof(k.c), "Color3", label .. ".color Color3")
				end
			end
			t.ok(isEnumName(Enum.ParticleOrientation, p.orientation), label .. ": orientation enum")
			t.ok(isEnumName(Enum.NormalId, p.emissionDirection), label .. ": emissionDirection enum")
			if p.lightEmission then
				t.ok(p.lightEmission >= 0 and p.lightEmission <= 1, label .. ": lightEmission")
			end
			if p.lightInfluence then
				t.ok(p.lightInfluence >= 0 and p.lightInfluence <= 1, label .. ": lightInfluence")
			end
		end
		t.ok(n >= 18, "preset count")
	end)

	t.test(
		"VFX: flipbook textures are only used with their own layout (and flat textures never as flipbooks)",
		function()
			for name, p in VFX.Presets do
				local layout = VFX.FlipbookLayouts[p.texture]
				if layout then
					t.ok(
						p.flipbook ~= nil,
						name .. " uses flipbook texture " .. p.texture .. " without flipbook settings"
					)
					t.eq(p.flipbook.layout, layout, name .. " layout")
					t.ok(isEnumName(Enum.ParticleFlipbookMode, p.flipbook.mode), name .. " flipbook mode")
					if p.flipbook.fps then
						t.ok(
							p.flipbook.fps[1] > 0 and (p.flipbook.fps[2] or p.flipbook.fps[1]) <= 30,
							name .. " fps <= 30"
						)
					end
				else
					t.eq(p.flipbook, nil, name .. " flat texture marked as flipbook")
				end
			end
		end
	)

	t.test("VFX: trails / beams / sprites / quality tiers / surfaces", function()
		for name, p in VFX.Trails do
			t.ok(VFX.Textures[p.texture] ~= nil, name .. " texture")
			t.ok(p.lifetime > 0 and p.minLength > 0 and p.width > 0, name .. " numbers")
			t.ok(isEnumName(Enum.TextureMode, p.textureMode), name .. " texture mode")
			checkSeq(p.transparency, name .. ".transparency", 0, 1)
		end
		for name, p in VFX.Beams do
			t.ok(VFX.Textures[p.texture] ~= nil, name .. " texture")
			t.ok(p.length > 0 and p.width0 > 0 and p.width1 > 0 and p.segments >= 1, name .. " numbers")
			t.ok(isEnumName(Enum.TextureMode, p.textureMode), name .. " texture mode")
			checkSeq(p.transparency, name .. ".transparency", 0, 1)
		end
		for name, p in VFX.Sprites do
			t.ok(VFX.Textures[p.texture] ~= nil and p.size > 0, name)
		end
		local hi, mid, lo = VFX.Quality.high, VFX.Quality.medium, VFX.Quality.low
		t.ok(hi.maxParticles > mid.maxParticles and mid.maxParticles > lo.maxParticles, "caps decrease")
		t.ok(hi.rate >= mid.rate and mid.rate >= lo.rate and lo.rate > 0, "rates decrease")
		t.ok(hi.count >= mid.count and mid.count >= lo.count and lo.count > 0, "counts decrease")
		t.ok(hi.sizeScale == 1 and mid.sizeScale < 1 and lo.sizeScale <= mid.sizeScale and lo.sizeScale > 0, "sizes")
		t.ok(VFX.STREAM_SHARE > 0 and VFX.STREAM_SHARE < 1, "streams leave burst headroom")
		t.ok(VFX.POOL_HARD_CAP >= 8 and VFX.POOL_HARD_CAP <= 16, "pool hard cap")
		t.ok(VFX.MAX_DISTANCE == 250, "far effects cut at 250 studs")
		for i = 2, #VFX.GEAR_SHIFTS do
			t.ok(VFX.GEAR_SHIFTS[i] > VFX.GEAR_SHIFTS[i - 1], "gear shifts ascend")
		end
		for mat, c in VFX.SurfaceDust do
			t.ok(isEnumName(Enum.Material, mat), mat .. " is a Material")
			t.eq(typeof(c), "Color3", mat)
		end
		t.ok(#VFX.CONFETTI_COLORS >= 4, "confetti colors")
		-- one confetti event = one burst per palette colour; two overlapping events reuse those looks (no growth)
		t.ok(VFX.Presets.Confetti.pool >= #VFX.CONFETTI_COLORS, "a confetti slot per palette colour")
		for name, p in VFX.Presets do
			if p.tierSize or p.cost then
				t.eq(p.kind, "stream", name .. ": tierSize / cost are stream fields")
			end
			if p.velocityInheritance then
				t.ok(p.velocityInheritance >= 0 and p.velocityInheritance <= 1, name .. ": velocityInheritance 0..1")
			end
		end
	end)

	-- mean of size^2 over a particle's life (piecewise-linear keys, envelope ignored): its average screen area
	local function meanArea(keys, scale)
		local total = 0
		for i = 2, #keys do
			local a, b = keys[i - 1].v * scale, keys[i].v * scale
			total += (a * a + a * b + b * b) / 3 * (keys[i].t - keys[i - 1].t)
		end
		return total
	end

	t.test("VFX: drift smoke fill rate is bounded on phones (size tiers, cost, end size)", function()
		local p = VFX.Presets.TireSmoke
		t.eq(p.tierSize, true, "tyre smoke shrinks with the quality tier")
		t.ok((p.cost or 1) > 1, "big smoke weighs more than a spark in the stream budget")
		local last = p.size[#p.size]
		for _, tierName in { "medium", "low" } do
			local k = VFX.Quality[tierName].sizeScale
			t.ok((last.v + (last.e or 0)) * k <= 8, tierName .. ": end size (+ envelope) <= 8 studs")
		end
		-- v2 shipped ~53.6 studs^2 average per puff on every tier; medium (phones) must stay well under half of it
		t.ok(meanArea(p.size, VFX.Quality.medium.sizeScale) < 53.6 / 2, "medium mean area")
		t.ok(meanArea(p.size, 1) < 40, "high mean area")
	end)

	t.test("VFX: nitro flame and backfire ride the car (no world-space wake behind a boosting car)", function()
		local flame = VFX.Presets.NitroFlame
		t.eq(flame.lockedToPart, true, "flame locked to the exhaust")
		t.ok(
			flame.orientation == nil or flame.orientation == "FacingCamera",
			"camera-facing: visible from the chase cam"
		)
		local back = VFX.Presets.Backfire
		t.eq(back.velocityInheritance, 1, "the pop keeps the car's velocity")
		t.eq(back.emissionDirection, "Back", "out of the tailpipe (+Z = car rear) of its exhaust attachment")
		t.ok(VFX.Presets.NitroCore.lockedToPart == true, "core glow locked too")
	end)

	---------------------------------------------------------------------------------------------------------------
	-- Pure helpers
	---------------------------------------------------------------------------------------------------------------

	t.test("VFXLibrary.qualityTier maps SavedQualityLevel + device", function()
		t.eq(Lib.qualityTier(0, true), "medium", "automatic phone")
		t.eq(Lib.qualityTier(0, false), "high", "automatic desktop")
		t.eq(Lib.qualityTier(1, false), "low")
		t.eq(Lib.qualityTier(3, false), "low")
		t.eq(Lib.qualityTier(4, true), "medium")
		t.eq(Lib.qualityTier(7, false), "medium")
		t.eq(Lib.qualityTier(8, true), "high")
		t.eq(Lib.qualityTier(10, false), "high")
	end)

	t.test("VFXLibrary.scaledCount / streamScale / streamLoad / streamRate", function()
		t.eq(Lib.scaledCount(10, 1), 10)
		t.eq(Lib.scaledCount(10, 0.45), 5)
		t.eq(Lib.scaledCount(1, 0.1), 1, "never rounds a requested particle away")
		t.eq(Lib.scaledCount(0, 1), 0)
		t.eq(Lib.scaledCount(5, 0), 0)
		t.eq(Lib.streamScale(1000, 100), 1)
		t.eq(Lib.streamScale(1000, 600), 1)
		t.near(Lib.streamScale(1000, 1200), 0.5, 1e-9)
		t.eq(Lib.streamScale(1000, 1e6), 0.25, "floor")
		t.near(Lib.streamLoad(40, { 1, 2 }), 60, 1e-9)
		t.near(Lib.streamRate(30, 1, 1, 0.65, 900, 0), 19.5, 1e-9)
		t.near(Lib.streamRate(30, 0.8, 0.5, 1, 1000, 1200), 30 * 0.8 * 0.5 * 0.5, 1e-9)
		t.eq(Lib.streamRate(30, 1, -1, 1, 1000, 0), 0)
	end)

	t.test("VFXLibrary.streamShares: priority (local car) streams first, the rest share what is left", function()
		local p, o = Lib.streamShares(1000, 0, 300)
		t.eq(p, 1)
		t.eq(o, 1, "under the 60% share: nothing throttled")
		p, o = Lib.streamShares(1000, 400, 400)
		t.eq(p, 1, "priority load fits: full rate")
		t.near(o, 0.5, 1e-9, "others get the 200 left of 600")
		p, o = Lib.streamShares(1000, 900, 100)
		t.near(p, 600 / 900, 1e-9, "priority alone over the share: scaled to fit")
		t.eq(o, VFX.MIN_STREAM_SCALE, "others at the floor")
		p, o = Lib.streamShares(1000, 0, 0)
		t.ok(p == 1 and o == 1, "idle")
	end)

	t.test(
		"VFXLibrary.pickSlot: same look first, then an idle slot, then grow, never re-look live particles",
		function()
			local red, blue = Color3.fromRGB(255, 0, 0), Color3.fromRGB(0, 0, 255)
			local slots = {
				{ scale = 1, color = red, busyUntil = 10, emittedAt = 5 },
				{ scale = 1, color = blue, busyUntil = 3, emittedAt = 1 },
			}
			t.eq(Lib.pickSlot(slots, 1, red, 6, 4), 1, "same look while busy: reused (nothing rewritten)")
			t.eq(Lib.pickSlot(slots, 0.6, nil, 6, 4), 2, "other look: the idle slot is re-looked")
			slots[2].busyUntil = 9
			t.eq(Lib.pickSlot(slots, 0.6, nil, 6, 4), 3, "every slot busy: grow")
			t.eq(Lib.pickSlot(slots, 0.6, nil, 6, 2), nil, "busy at the cap: skip the burst")
			t.eq(Lib.pickSlot(slots, 1, red, 5, 4), 3, "same look emitted this very frame: a fresh slot when possible")
			t.eq(Lib.pickSlot(slots, 1, red, 5, 2), 1, "...else share it")
			t.eq(Lib.pickSlot({}, 1, nil, 0, 3), 1, "an empty pool builds slot 1")
			t.eq(Lib.quantizeScale(0.6), 0.6)
			t.near(Lib.quantizeScale(0.4512), 0.45, 1e-9, "near-equal scales share a look")
			t.eq(Lib.quantizeScale(0.001), 0.05, "floor")
			t.eq(Lib.maxSlots(3), 6, "busy pools grow to 2x")
			t.eq(Lib.maxSlots(8), VFX.POOL_HARD_CAP, "...at most the hard cap")
		end
	)

	t.test("VFXLibrary.gearOf / nextGear: upshift pops once, hysteresis on the way down", function()
		local shifts = { 0.2, 0.4, 0.6 }
		t.eq(Lib.gearOf(0, shifts), 0)
		t.eq(Lib.gearOf(0.2, shifts), 1)
		t.eq(Lib.gearOf(0.59, shifts), 2)
		t.eq(Lib.gearOf(0.95, shifts), 3)
		local g, up = Lib.nextGear(0, 0.25, shifts, 0.04)
		t.eq(g, 1)
		t.eq(up, true, "crossing 0.2 upshifts")
		g, up = Lib.nextGear(g, 0.19, shifts, 0.04)
		t.eq(g, 1, "hovering just under the shift point keeps the gear")
		t.eq(up, false)
		g, up = Lib.nextGear(g, 0.21, shifts, 0.04)
		t.eq(up, false, "no second pop when bouncing around the shift point")
		g, up = Lib.nextGear(g, 0.1, shifts, 0.04)
		t.eq(g, 0, "dropped below the hysteresis band")
		t.eq(up, false)
		g, up = Lib.nextGear(0, 0.7, shifts, 0.04)
		t.eq(g, 3)
		t.eq(up, true)
		g = Lib.nextGear(3, 0.05, shifts, 0.04)
		t.eq(g, 0, "big drop goes all the way down")
	end)

	t.test("VFXLibrary.dustColor / texture fallback / sequences", function()
		t.ok(Lib.dustColor("Sand") ~= nil and Lib.dustColor("Grass") ~= nil, "dirt surfaces")
		t.eq(Lib.dustColor("Asphalt"), nil, "paved: no dust")
		t.eq(Lib.dustColor("SmoothPlastic"), nil)
		t.eq(Lib.texture("glow_dot"), VFX.Textures.glow_dot)
		t.eq(Lib.texture("nope"), "")
		local seq = Lib.numberSequence({ VFX.K(0, 2, 1), VFX.K(1, 4, 0) }, 2)
		t.eq(#seq.Keypoints, 2)
		t.near(seq.Keypoints[1].Value, 4, 1e-6, "scaled value")
		t.near(seq.Keypoints[1].Envelope, 2, 1e-6, "scaled envelope")
		local cs = Lib.colorSequence({ VFX.C(0, 255, 0, 0), VFX.C(1, 0, 0, 255) })
		t.eq(#cs.Keypoints, 2)
	end)

	t.test("VFXLibrary.alignUp points +Y (EmissionDirection Top) along the direction", function()
		local p = Vector3.new(1, 2, 3)
		for _, d in { Vector3.new(1, 0, 0), Vector3.new(0, 0, -1), Vector3.new(0.3, 0.5, -0.8), Vector3.new(0, -1, 0) } do
			local cf = Lib.alignUp(p, d)
			t.near((cf.UpVector - d.Unit).Magnitude, 0, 1e-4, "up along " .. tostring(d))
			t.near((cf.Position - p).Magnitude, 0, 1e-6, "position kept")
		end
		local cf = Lib.alignUp(p, nil)
		t.near(cf.UpVector.Y, 1, 1e-6, "no direction: world up")
		cf = Lib.alignUp(p, Vector3.new(0, 1, 0))
		t.near(cf.UpVector.Y, 1, 1e-6, "straight up (lookAt degenerate case)")
	end)

	---------------------------------------------------------------------------------------------------------------
	-- Budget
	---------------------------------------------------------------------------------------------------------------

	t.test("Budget: reserve caps live particles, expiry frees them, stream load counts", function()
		local b = Lib.newBudget(100)
		t.eq(b:reserve(60, 0, 1), 60)
		t.eq(b:reserve(60, 0.5, 1), 40, "only what fits")
		t.eq(b:reserve(5, 0.6, 1), 0, "full")
		t.eq(b:live(0.6), 100)
		t.eq(b:live(1.01), 40, "first burst expired")
		t.eq(b:reserve(10, 1.01, 1), 10)
		b.streamLoad = 45
		t.eq(b:reserve(10, 1.01, 1), 5, "streams eat into burst room")
		t.eq(b:live(3), 0, "all expired")
		t.eq(b:reserve(500, 3, 1), 55)
	end)

	---------------------------------------------------------------------------------------------------------------
	-- Burst pools (emission is recorded: the harness has no ParticleEmitter:Emit; time is driven explicitly)
	---------------------------------------------------------------------------------------------------------------

	local emitted = {}
	local function recorder(e, n)
		table.insert(emitted, { emitter = e, n = n })
	end
	local now = 100
	local function clockFn()
		return now
	end

	local function freshLib(tier)
		Lib._reset()
		Lib._setEmitter(recorder)
		Lib._setCamera(Vector3.new(0, 0, 0))
		now = 100
		Lib._setClock(clockFn)
		Lib.setQualityOverride(tier or "high")
		table.clear(emitted)
	end

	local function distinctEmitters(list)
		local seen, n = {}, 0
		for _, rec in list do
			if not seen[rec.emitter] then
				seen[rec.emitter] = true
				n += 1
			end
		end
		return n
	end

	t.test("burst: one emitter per look, reused across frames; busy pools grow only to their cap", function()
		freshLib("high")
		local preset = VFX.Presets.Sparks
		for i = 1, 10 do
			now += 0.05
			t.eq(Lib.burst("Sparks", Vector3.new(i, 0, 0)), preset.count, "full count on high")
		end
		local built, size, max = Lib._poolInfo("Sparks")
		t.eq(size, preset.pool)
		t.eq(built, 1, "same look every frame: one emitter serves every burst")
		t.eq(distinctEmitters(emitted), 1)
		for i = 1, 20 do
			now += 0.01
			Lib.burst("Sparks", Vector3.zero, { count = 1, color = Color3.fromRGB(i * 10, 0, 0) })
		end
		built = Lib._poolInfo("Sparks")
		t.eq(max, math.min(VFX.POOL_HARD_CAP, preset.pool * 2))
		t.eq(built, max, "20 different looks in flight: grown to the cap, never past it")
		local host = H.workspace:FindFirstChild("ClientVFX"):FindFirstChild("VFXHost")
		t.ok(host ~= nil and host.Anchored and host.Transparency == 1, "one invisible anchored host")
		local e = emitted[1].emitter
		t.eq(e.Enabled, false, "pooled emitters never emit on their own")
		t.eq(e.Texture, VFX.Textures.spark_streak)
		t.eq(e.Orientation, Enum.ParticleOrientation.VelocityParallel)
	end)

	t.test("burst: a second confetti event 1 s later leaves the first one's colours in the air alone", function()
		freshLib("high")
		local function confetti(scale)
			for _, c in VFX.CONFETTI_COLORS do
				Lib.burst("Confetti", Vector3.new(0, 0, 10), { count = 10, color = c, scale = scale })
			end
		end
		confetti(nil)
		local first = {}
		for _, rec in emitted do
			first[rec.emitter] = rec.emitter.Color.Keypoints[1].Value
		end
		now += 1
		confetti(nil)
		now += 0.5
		confetti(1.3) -- a bigger (BigSteal-like) burst while both are still falling
		local size0 = VFX.Presets.Confetti.size[1].v
		for e, c in first do
			t.eq(e.Color.Keypoints[1].Value, c, "first burst keeps its colour")
			t.near(e.Size.Keypoints[1].Value, size0, 1e-6, "...and its size")
		end
		local built = Lib._poolInfo("Confetti")
		t.eq(built, 2 * #VFX.CONFETTI_COLORS, "two looks per colour in flight, one emitter each")
	end)

	t.test("burst: a wreck's debris keeps its colour + size while tyre pops and crash debris follow", function()
		freshLib("high")
		local carColor = Color3.fromRGB(200, 30, 30)
		Lib.burst("Debris", Vector3.new(0, 0, 10), { color = carColor })
		local wreck = emitted[1].emitter
		for _ = 1, 3 do
			now += 0.4
			Lib.burst("Debris", Vector3.new(0, 0, 12), { count = 8, scale = 0.6, color = Color3.fromRGB(30, 30, 36) })
		end
		now += 0.1
		Lib.burst("Debris", Vector3.new(0, 0, 14), { count = 5, scale = 0.6 })
		t.eq(wreck.Color.Keypoints[1].Value, carColor, "colour")
		t.near(wreck.Size.Keypoints[1].Value, VFX.Presets.Debris.size[1].v, 1e-6, "size (1.2, not 0.72)")
	end)

	t.test("burst: a pool busy with other looks at its cap skips; idle slots are re-looked later", function()
		freshLib("high")
		local _, _, max = Lib._poolInfo("ImpactStar")
		Lib.burst("ImpactStar", Vector3.zero) -- builds the pool record
		_, _, max = Lib._poolInfo("ImpactStar")
		for i = 1, max - 1 do
			Lib.burst("ImpactStar", Vector3.zero, { color = Color3.fromRGB(i, 0, 0) })
		end
		local looks = {}
		for _, rec in emitted do
			looks[rec.emitter] = rec.emitter.Color.Keypoints[1].Value
		end
		t.eq(Lib.burst("ImpactStar", Vector3.zero, { color = Color3.fromRGB(0, 255, 0) }), 0, "skipped")
		for e, c in looks do
			t.eq(e.Color.Keypoints[1].Value, c, "nothing in the air re-looked")
		end
		now += VFX.Presets.ImpactStar.lifetime[2] + 0.01
		t.eq(Lib.burst("ImpactStar", Vector3.zero, { color = Color3.fromRGB(0, 255, 0) }), 1, "idle: re-looked")
		t.eq(Lib._poolInfo("ImpactStar"), max, "no growth past the cap")
	end)

	t.test("burst: the same look twice in one frame uses two emitters (each Emit at its own spot)", function()
		freshLib("high")
		Lib.burst("Sparks", Vector3.new(0, 0, 5))
		Lib.burst("Sparks", Vector3.new(0, 0, 9))
		t.ok(emitted[1].emitter ~= emitted[2].emitter, "second burst of the frame on a fresh slot")
		now += 0.02
		Lib.burst("Sparks", Vector3.new(0, 0, 7))
		t.eq(emitted[3].emitter, emitted[1].emitter, "next frame: the first slot again")
	end)

	t.test(
		"burst: quality scales counts, distance culls (force overrides), unknown / stream presets refused",
		function()
			freshLib("low")
			local n = Lib.burst("WreckSmoke", Vector3.new(0, 0, 10))
			t.eq(n, Lib.scaledCount(VFX.Presets.WreckSmoke.count, VFX.Quality.low.count), "low tier count")
			t.eq(Lib.burst("WreckSmoke", Vector3.new(0, 0, 251)), 0, "beyond 250 studs: culled")
			t.ok(Lib.burst("WreckSmoke", Vector3.new(0, 0, 251), { force = true }) > 0, "force ignores distance")
			t.eq(Lib.burst("Nope", Vector3.zero), 0, "unknown preset")
			t.eq(Lib.burst("TireSmoke", Vector3.zero), 0, "streams can't burst")
			t.eq(
				Lib.burst("ImpactStar", Vector3.zero, { count = 5 }),
				Lib.scaledCount(5, VFX.Quality.low.count),
				"explicit count still quality-scaled"
			)
		end
	)

	t.test("burst: overrides (color, scale, direction), look restored on an idle slot, the budget cap", function()
		freshLib("high")
		local c = Color3.fromRGB(10, 200, 30)
		Lib.burst("Confetti", Vector3.zero, { color = c, scale = 2, direction = Vector3.new(1, 0, 0) })
		local e = emitted[#emitted].emitter
		t.eq(e.Color.Keypoints[1].Value, c, "constant color override")
		t.near(e.Size.Keypoints[1].Value, VFX.Presets.Confetti.size[1].v * 2, 1e-6, "size scaled")
		local att = e.Parent
		t.near((att.WorldCFrame.UpVector - Vector3.new(1, 0, 0)).Magnitude, 0, 1e-4, "aimed along direction")
		-- once its particles died, a plain burst re-looks that slot: the preset look comes back
		now += VFX.Presets.Confetti.lifetime[2] + 0.01
		Lib.burst("Confetti", Vector3.zero)
		t.eq(emitted[#emitted].emitter, e, "idle slot reused")
		t.near(e.Size.Keypoints[1].Value, VFX.Presets.Confetti.size[1].v, 1e-6, "scale reset")
		t.eq(e.Color.Keypoints[1].Value, Color3.new(1, 1, 1), "color reset to the preset")
		now += 0.1
		Lib.burst("Confetti", Vector3.zero, { scale = 1.01 })
		t.eq(emitted[#emitted].emitter, e, "scale 1.01 snaps to the same look")
		-- cap: fill the budget, then bursts are refused until particles expire
		Lib._reset()
		Lib.setQualityOverride("high")
		Lib.quality() -- latch the tier (it sets the cap), then shrink the cap for the test
		Lib.budget.cap = 30
		t.eq(Lib.burst("Sparks", Vector3.zero), 26)
		t.eq(Lib.burst("Sparks", Vector3.zero), 4, "clipped to the cap")
		t.eq(Lib.burst("Sparks", Vector3.zero), 0, "full")
		now += VFX.Presets.Sparks.lifetime[2] + 0.01
		t.eq(Lib.burst("Sparks", Vector3.zero), 26, "expired particles free the budget")
	end)

	---------------------------------------------------------------------------------------------------------------
	-- Attached bursts
	---------------------------------------------------------------------------------------------------------------

	t.test("attach + emit: a burst preset riding the caller's attachment (exhaust backfire)", function()
		freshLib("medium")
		local part = Instance.new("Part")
		local exhaust = Instance.new("Attachment")
		exhaust.Parent = part
		exhaust.WorldPosition = Vector3.new(0, 0, 20)
		local a = Lib.attach("Backfire", exhaust)
		t.ok(a ~= nil and a.emitter.Parent == exhaust, "emitter on the exhaust")
		t.eq(a.emitter.Enabled, false, "bursts only")
		t.eq(a.emitter.EmissionDirection, Enum.NormalId.Back, "out of the tailpipe")
		t.eq(a.emitter.VelocityInheritance, 1, "keeps the car's velocity")
		t.eq(Lib.emit(a, 3), Lib.scaledCount(3, VFX.Quality.medium.count), "quality-scaled")
		t.eq(emitted[#emitted].emitter, a.emitter, "emitted from its own emitter")
		t.eq(Lib.emit(a), Lib.scaledCount(VFX.Presets.Backfire.count, VFX.Quality.medium.count), "preset count")
		exhaust.WorldPosition = Vector3.new(0, 0, 400)
		t.eq(Lib.emit(a), 0, "far: culled")
		t.ok(Lib.emit(a, nil, true) > 0, "force")
		t.eq(Lib.attach("TireSmoke", exhaust), nil, "streams are not bursts")
		t.eq(Lib.emit(nil), 0)
		a.emitter.Parent = nil
		t.eq(Lib.emit(a, nil, true), 0, "destroyed with its car")
	end)

	---------------------------------------------------------------------------------------------------------------
	-- Streams / trails / beams
	---------------------------------------------------------------------------------------------------------------

	t.test("stream: rate from tier x intensity, tier size, load accounted, off releases the budget", function()
		freshLib("medium")
		local att = Instance.new("Attachment")
		local s = Lib.stream("TireSmoke", att)
		t.ok(s ~= nil and s.emitter.Parent == att, "emitter on the caller's attachment")
		t.eq(s.emitter.Enabled, false, "starts off")
		t.eq(s.emitter.FlipbookLayout, Enum.ParticleFlipbookLayout.Grid4x4)
		t.eq(s.emitter.FlipbookMode, Enum.ParticleFlipbookMode.OneShot)
		local keys = VFX.Presets.TireSmoke.size
		t.near(
			s.emitter.Size.Keypoints[#keys].Value,
			keys[#keys].v * VFX.Quality.medium.sizeScale,
			1e-5,
			"smaller puffs on medium"
		)
		Lib.setStream(s, true, 1)
		t.eq(s.emitter.Enabled, true)
		t.near(s.emitter.Rate, VFX.Presets.TireSmoke.rate * VFX.Quality.medium.rate, 1e-6)
		t.ok(Lib.budget.streamLoad > 0, "load counted")
		local rate = s.emitter.Rate
		Lib.setStream(s, true, 1.02)
		t.eq(s.emitter.Rate, rate, "tiny intensity change: no property write")
		Lib.setStream(s, true, 0.5)
		t.near(s.emitter.Rate, rate * 0.5, 1e-6, "big change written")
		Lib.setStream(s, false)
		t.eq(s.emitter.Enabled, false)
		t.eq(Lib.budget.streamLoad, 0, "off: load released")
		t.eq(Lib.stream("Sparks", att), nil, "burst presets can't stream")
		-- an emitter destroyed with its car drops out of the budget on the next call
		Lib.setStream(s, true)
		s.emitter.Parent = nil
		Lib.setStream(s, true)
		t.eq(Lib.budget.streamLoad, 0, "orphaned stream forgotten")
	end)

	t.test("stream: the local car's smoke keeps full rate when observers' smoke fills the budget", function()
		freshLib("high")
		Lib.quality()
		Lib.budget.cap = 200 -- streams may use 120
		local p = VFX.Presets.TireSmoke
		local perStream = Lib.streamLoad(p.rate, p.lifetime) * p.cost
		local observers = {}
		for i = 1, 3 do
			local s = Lib.stream("TireSmoke", Instance.new("Attachment"))
			observers[i] = s
			Lib.setStream(s, true)
		end
		local early = 120 / (3 * perStream)
		for _, s in observers do
			t.near(s.emitter.Rate, p.rate * early, 1e-6, "observers share the stream budget")
		end
		local mine = Lib.stream("TireSmoke", Instance.new("Attachment"), { priority = true })
		Lib.setStream(mine, true)
		t.near(mine.emitter.Rate, p.rate, 1e-6, "ours started last and still runs at full rate")
		for _, s in observers do
			t.near(s.emitter.Rate, p.rate * VFX.MIN_STREAM_SCALE, 1e-6, "running observers re-rated down")
		end
		Lib.setStream(mine, false)
		for _, s in observers do
			t.near(s.emitter.Rate, p.rate * early, 1e-6, "...and back up once ours stops")
		end
	end)

	t.test("rebalance: a tier change re-rates running streams, resizes smoke, shortens trails", function()
		freshLib("high")
		local att = Instance.new("Attachment")
		local part = Instance.new("Part")
		local smoke = Lib.stream("TireSmoke", att, { priority = true })
		local core = Lib.stream("NitroCore", att)
		Lib.setStream(smoke, true)
		Lib.setStream(core, true)
		local rig = Lib.trail("SkidMark", part, Vector3.zero)
		local keys = VFX.Presets.TireSmoke.size
		t.near(smoke.emitter.Rate, VFX.Presets.TireSmoke.rate, 1e-6)
		t.near(smoke.emitter.Size.Keypoints[#keys].Value, keys[#keys].v, 1e-5)
		Lib.setQualityOverride("low")
		Lib.rebalance()
		t.near(smoke.emitter.Rate, VFX.Presets.TireSmoke.rate * VFX.Quality.low.rate, 1e-6, "running stream re-rated")
		t.near(core.emitter.Rate, VFX.Presets.NitroCore.rate * VFX.Quality.low.rate, 1e-6)
		t.near(
			smoke.emitter.Size.Keypoints[#keys].Value,
			keys[#keys].v * VFX.Quality.low.sizeScale,
			1e-5,
			"tierSize smoke shrunk"
		)
		local coreKeys = VFX.Presets.NitroCore.size
		t.near(core.emitter.Size.Keypoints[#coreKeys].Value, coreKeys[#coreKeys].v, 1e-5, "other streams keep size")
		t.near(rig.trail.Lifetime, VFX.Trails.SkidMark.lifetime * VFX.Quality.low.trailLife, 1e-6, "trails shorter")
		Lib.setQualityOverride(nil)
	end)

	t.test("trail + beam rigs: attachments placed, start disabled, preset applied, height follows", function()
		freshLib("high")
		local part = Instance.new("Part")
		local rig = Lib.trail("SkidMark", part, Vector3.new(2, -1, 4))
		t.ok(rig ~= nil, "trail")
		local w = VFX.Trails.SkidMark.width
		t.near((rig.a0.Position - Vector3.new(2 - w / 2, -1, 4)).Magnitude, 0, 1e-4, "a0 left of the contact point")
		t.near((rig.a1.Position - Vector3.new(2 + w / 2, -1, 4)).Magnitude, 0, 1e-4, "a1 right of it")
		t.eq(rig.trail.Enabled, false)
		t.eq(rig.trail.FaceCamera, false, "lies flat on the road")
		t.eq(rig.trail.Texture, VFX.Textures.skid_mark)
		t.near(rig.trail.Lifetime, VFX.Trails.SkidMark.lifetime, 1e-6)
		Lib.setTrailHeight(rig, -1.6)
		t.near((rig.a0.Position - Vector3.new(2 - w / 2, -1.6, 4)).Magnitude, 0, 1e-4, "a0 follows the road")
		t.near((rig.a1.Position - Vector3.new(2 + w / 2, -1.6, 4)).Magnitude, 0, 1e-4, "a1 too")
		Lib.setTrailHeight(rig, -1.605)
		t.near(rig.a0.Position.Y, -1.6, 1e-4, "sub-centistud wobble: no write")
		local beam = Lib.beam("NitroJet", part, Vector3.new(0, 0, 3), Vector3.new(0, 0, 1))
		t.ok(beam ~= nil, "beam")
		t.near((beam.a1.Position - Vector3.new(0, 0, 3 + VFX.Beams.NitroJet.length)).Magnitude, 0, 1e-4, "length")
		t.eq(beam.beam.Enabled, false)
		t.eq(beam.beam.Texture, VFX.Textures.nitro_jet)
		Lib.setQualityOverride("low")
		local lowRig = Lib.trail("SkidMark", part, Vector3.zero)
		t.near(lowRig.trail.Lifetime, VFX.Trails.SkidMark.lifetime * VFX.Quality.low.trailLife, 1e-6, "short on low")
		Lib.setQualityOverride(nil)
	end)

	t.test("sprite: siren glare starts hidden, pulled toward the camera, in PlayerGui", function()
		local part = Instance.new("Part")
		local gui, img = Lib.sprite("SirenGlare", part, Color3.fromRGB(255, 0, 0))
		t.ok(gui ~= nil and img ~= nil, "built")
		t.eq(gui.Enabled, false)
		t.eq(gui.Adornee, part)
		t.near(gui.StudsOffset.Z, VFX.Sprites.SirenGlare.towardCamera, 1e-6, "not cut in half by the roof")
		t.eq(gui.Parent, H.localPlayer:FindFirstChild("PlayerGui"))
		gui:Destroy()
	end)

	t.test("configure: every preset applies to a real ParticleEmitter without errors", function()
		for name, p in VFX.Presets do
			local e = Instance.new("ParticleEmitter")
			local ok, err = pcall(Lib.configure, e, p)
			t.ok(ok, name .. ": " .. tostring(err))
			if p.flipbook then
				t.eq(e.FlipbookLayout.Name, p.flipbook.layout, name .. " layout applied")
			else
				t.eq(e.FlipbookLayout, Enum.ParticleFlipbookLayout.None, name .. " no flipbook")
			end
			t.eq(e.LockedToPart, p.lockedToPart == true, name .. " LockedToPart")
			t.eq(e.VelocityInheritance, p.velocityInheritance or 0, name .. " VelocityInheritance")
		end
	end)

	---------------------------------------------------------------------------------------------------------------
	-- VehicleClient effect math
	---------------------------------------------------------------------------------------------------------------

	local VC = H.require("src/client/Controllers/VehicleClient")
	local VCtl = H.require("src/shared/Vehicle/VehicleController")

	t.test("VehicleClient.tyreSmoke: only a sliding tyre on the ground smokes", function()
		local on, level = VC.tyreSmoke(true, true, 18)
		t.eq(on, true)
		t.near(level, 0.8, 1e-9, "18 studs/s sideways")
		on = VC.tyreSmoke(true, false, 30)
		t.eq(on, false, "lifted rear tyre: no smoke while the car still drifts")
		on = VC.tyreSmoke(false, true, 30)
		t.eq(on, false, "gripping")
		local _, big = VC.tyreSmoke(true, true, 200)
		t.eq(big, 1.3, "level capped")
		local _, small = VC.tyreSmoke(true, true, 0)
		t.eq(small, 0.5, "level floor")
	end)

	t.test("VehicleClient.skidContactY: the mark sits on the road through suspension travel", function()
		local hubY, r = -1, 1.2
		local rest = VC.skidContactY(hubY, r, nil)
		t.near(rest, hubY - r - VCtl.RIDE_LIFT + 0.04, 1e-9, "at rest the car rides RIDE_LIFT above its built pose")
		t.near(VC.skidContactY(hubY, r, -VCtl.RIDE_LIFT), rest, 1e-9, "controller offset at equilibrium")
		t.near(VC.skidContactY(hubY, r, 0.5), hubY - r + 0.5 + 0.04, 1e-9, "compressed: road closer to the body")
		t.near(VC.skidContactY(hubY, r, -0.7), hubY - r - 0.7 + 0.04, 1e-9, "drooped")
		t.near(VC.skidContactY(hubY, r, 0 / 0), rest, 1e-9, "NaN offset: rest")
	end)

	-- normalised screen radius of a camera-space point (vertical FOV in degrees, aspect = width / height)
	local function screenRadius(p, fov, aspect)
		local tanV = math.tan(math.rad(fov) / 2)
		local nx = p.X / (-p.Z * tanV * aspect)
		local ny = p.Y / (-p.Z * tanV)
		return math.sqrt(nx * nx + ny * ny), nx, ny
	end

	t.test("VehicleClient speed-line ring: spawns near the screen edge, none into the touch corners", function()
		local desk = VC.speedLineSlots(8, false)
		t.eq(#desk, 8, "desktop: full ring")
		local touch = VC.speedLineSlots(8, true)
		t.eq(#touch, 6, "touch: the two downward slots dropped")
		for _, a in touch do
			t.ok(math.sin(a) >= -0.7, "no slot sweeps into the thumbstick / pedal corners")
		end
		for _, fov in { 70, 85, 96, 110 } do
			for _, aspect in { 4 / 3, 16 / 9, 2.16 } do
				for _, a in desk do
					local p = VC.speedLinePos(a, fov, aspect, 28, 0.62)
					t.near(p.Z, -28, 1e-9, "ahead of the camera")
					local radius = screenRadius(p, fov, aspect)
					t.ok(
						radius >= 0.55,
						("ring at %.2f of the screen (fov %d, aspect %.2f)"):format(radius, fov, aspect)
					)
					t.ok(radius <= 0.7, "still on screen")
				end
			end
		end
		local p = VC.speedLinePos(0, 96, 0 / 0, 28, 0.62)
		t.ok(p.X == p.X, "bad aspect falls back")
	end)

	t.test("VehicleClient.inWaterVolume: in the Stunt Park pool, not over or beside it", function()
		local size = Vector3.new(30, 1.4, 22)
		local above = 1.2 + 1.5
		t.eq(VC.inWaterVolume(Vector3.new(0, 1.3, 0), size, above), true, "wheels on the pool floor")
		t.eq(VC.inWaterVolume(Vector3.new(14, 2, -10), size, above), true, "near a corner")
		t.eq(VC.inWaterVolume(Vector3.new(0, 0.7 + above + 0.5, 0), size, above), false, "jumping over it")
		t.eq(VC.inWaterVolume(Vector3.new(16, 0, 0), size, above), false, "beside it")
		t.eq(VC.inWaterVolume(Vector3.new(0, -4, 0), size, above), false, "far under it")
	end)

	---------------------------------------------------------------------------------------------------------------
	-- WheelAnimator effect logic
	---------------------------------------------------------------------------------------------------------------

	local WA = H.require("src/client/Controllers/WheelAnimator")

	t.test("WheelAnimator.wantsHeadlights: moving cars light up at night, parked ones stay dark", function()
		t.eq(WA.wantsHeadlights("Traffic", nil), true)
		t.eq(WA.wantsHeadlights("Police", 0), true)
		t.eq(WA.wantsHeadlights("Loot", 42), true, "driven loot car")
		t.eq(WA.wantsHeadlights("Owned", 7), true)
		t.eq(WA.wantsHeadlights("Parked", nil), false)
		t.eq(WA.wantsHeadlights("Loot", 0), false, "abandoned")
		t.eq(WA.wantsHeadlights("HotDrop", nil), false)
		t.ok(WA.LOW_TIER.HEADLIGHT_CARS < WA.HEADLIGHT_CARS, "phones light fewer cars")
	end)

	t.test("WheelAnimator.pickHeadlights + headlightChanges: nearest wanted cars, cleanup of the rest", function()
		local a = { dist = 10, ok = true }
		local b = { dist = 20, ok = false }
		local c = { dist = 30, ok = true }
		local d = { dist = 40, ok = true }
		local far = { dist = 200, ok = true }
		local list = { a, b, c, d, far }
		local function wants(x)
			return x.ok
		end
		local day = WA.pickHeadlights(list, false, 8, 180, wants)
		t.eq(next(day), nil, "day: none")
		local two = WA.pickHeadlights(list, true, 2, 180, wants)
		t.ok(two[a] and two[c] and not two[b] and not two[d], "the two nearest that want lights")
		local all = WA.pickHeadlights(list, true, 8, 180, wants)
		t.ok(all[a] and all[c] and all[d] and not all[far], "range cut")
		local alive = { [a] = true, [c] = true, [d] = false }
		local off, on = WA.headlightChanges({ [a] = true, [d] = true }, { [c] = true, [d] = true }, function(x)
			return alive[x] == true
		end)
		local offSet, onSet = {}, {}
		for _, x in off do
			offSet[x] = true
		end
		for _, x in on do
			onSet[x] = true
		end
		t.ok(offSet[a] and offSet[d] and not offSet[c], "unwanted and despawned cars go dark")
		t.ok(onSet[c] and not onSet[d], "newly wanted cars light up (lit ones are not re-sent)")
	end)

	t.test("WheelAnimator hero cones: shell front face, lamp x / y kept; skid height from the contact", function()
		local chassisCF = CFrame.new(10, 3, -40) * CFrame.Angles(0, math.rad(35), 0)
		local nose = Instance.new("Part")
		nose.Size = Vector3.new(4, 2, 2)
		nose.CFrame = chassisCF * CFrame.new(0, 0, -5) * CFrame.Angles(0, math.rad(90), 0) -- 4 studs along chassis Z
		local tail = Instance.new("Part")
		tail.Size = Vector3.new(4, 2, 6)
		tail.CFrame = chassisCF * CFrame.new(0, 0, 2)
		t.near(WA.frontZ({ nose, tail }, chassisCF), -7, 1e-4, "frontmost box face in chassis space")
		t.eq(WA.frontZ({}, chassisCF), nil)
		local lamp = Vector3.new(1.3, 0.4, -6.2)
		local o = WA.heroConeOrigin(lamp, -7)
		t.near(o.X, 1.3, 1e-5)
		t.near(o.Y, 0.4, 1e-5)
		t.ok(o.Z > -7 and o.Z < -6.5, "just inside the shell's nose")
		t.eq(WA.heroConeOrigin(lamp, nil), lamp, "no shell: the lamp itself")
		t.near(WA.skidY(-2.5), -2.46, 1e-9)
	end)

	---------------------------------------------------------------------------------------------------------------
	-- EffectsController: handler -> preset wiring, siren glare lifecycle
	---------------------------------------------------------------------------------------------------------------

	t.test("EffectsController: every effect fires its presets; a far wreck keeps its fireball", function()
		freshLib("high")
		local E = H.require("src/client/Controllers/EffectsController")
		E._setGround(function(pos)
			return pos.Y - 1
		end)
		pcall(function()
			H.workspace.CurrentCamera.ViewportSize = Vector2.new(1280, 720)
		end)
		local function presetsOf(name, data)
			table.clear(emitted)
			now += 5 -- every pool idle again
			E.play(name, data)
			local got = {}
			for _, rec in emitted do
				local preset = rec.emitter.Name:sub(5)
				got[preset] = (got[preset] or 0) + 1
			end
			return got
		end
		local at = { position = Vector3.new(0, 0, 30) }
		local cases = {
			CarWreck = { "Fireball", "WreckSmoke", "Debris", "Sparks", "Shockwave", "Flash", "ImpactStar" },
			Confetti = { "Confetti", "Sparkle", "Shockwave" },
			Bonk = { "ImpactStar", "Sparks", "Shockwave", "Sparkle" },
			TirePop = { "Debris", "DustPuff", "ImpactStar" },
			SpikeDrop = { "DustPuff", "Sparks" },
			CashBurst = { "CashFlutter", "Coins", "Sparkle", "Flash" },
			BigSteal = { "Confetti", "CashFlutter", "Coins", "Shockwave", "Sparkle", "Flash" },
		}
		for name, list in cases do
			local got = presetsOf(name, at)
			for _, preset in list do
				t.ok(got[preset] ~= nil, name .. " fires " .. preset)
			end
		end
		local zap = presetsOf("Zap", { from = Vector3.new(0, 2, 0), to = Vector3.new(0, 2, 20), hit = true })
		t.ok(zap.Sparks and zap.Flash == 2 and zap.Shockwave, "Zap: sparks, two flashes, a hit ring")
		t.eq(presetsOf("Confetti", at).Confetti, #VFX.CONFETTI_COLORS, "one confetti burst per palette colour")
		-- 300 studs out: inside the effect cull (380), past the library's own 250: the particles still come
		local far = presetsOf("CarWreck", { position = Vector3.new(0, 0, 320) })
		t.ok(far.Fireball and far.WreckSmoke and far.Debris, "far wreck: fireball + smoke + debris, not just a comic")
		E._setGround(nil)
	end)

	t.test("EffectsController sirens: glare built once, flips with the phase, hides, dies with the car", function()
		local E = H.require("src/client/Controllers/EffectsController")
		local S = E._sirens
		local model = Instance.new("Model")
		local body = Instance.new("Part")
		body.Name = "Chassis"
		body.Parent = model
		model.PrimaryPart = body
		local red = Instance.new("Part")
		red.Name = "SirenRed"
		red.Parent = model
		local blue = Instance.new("Part")
		blue.Name = "SirenBlue"
		blue.Parent = model
		model.Parent = H.workspace
		S.track(model)
		S.update(true)
		local rec = S.record(model)
		t.ok(rec ~= nil and rec.glareBuilt, "built on the first nearby flash")
		local gr, gb = rec.glareRed, rec.glareBlue
		t.ok(gr ~= nil and gb ~= nil, "a sprite per colour")
		t.eq(gr.Enabled, true, "red phase")
		t.eq(gb.Enabled, false)
		S.update(false)
		t.eq(gr.Enabled, false, "blue phase")
		t.eq(gb.Enabled, true)
		t.eq(rec.glareRed, gr, "never rebuilt per tick")
		model:SetAttribute("Siren", false)
		S.update(true)
		t.ok(not gr.Enabled and not gb.Enabled, "siren off: glare hidden")
		model:SetAttribute("Siren", nil)
		S.update(true)
		t.eq(gr.Enabled, true, "back on")
		model.Parent = nil
		S.update(true)
		t.eq(S.record(model), nil, "record dropped with the car")
		t.eq(gr.Parent, nil, "sprites destroyed")
		t.eq(gb.Parent, nil)
	end)

	t.test("controllers using the library still load headlessly", function()
		for _, path in
			{
				"src/client/Controllers/EffectsController",
				"src/client/Controllers/WheelAnimator",
				"src/client/Controllers/CombatClient",
				"src/client/Controllers/VehicleClient",
			}
		do
			local ok, err = pcall(H.require, path)
			t.ok(ok, path .. ": " .. tostring(err))
		end
		Lib._setEmitter(nil)
		Lib._setCamera(nil)
		Lib._setClock(nil)
		Lib.setQualityOverride(nil)
		Lib._reset()
	end)
end
