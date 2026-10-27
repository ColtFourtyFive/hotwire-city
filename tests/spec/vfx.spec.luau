--!nocheck
-- VFX library: Config/VFX preset + texture shape, VFXLibrary pure helpers, budget, burst pooling, streams, trails.
local fs = require("@lune/fs")
local serde = require("@lune/serde")

return function(t)
	local H = t.H
	local Vector3 = H.roblox.Vector3
	local Color3 = H.roblox.Color3
	local Instance = H.roblox.Instance
	local Enum = H.roblox.Enum

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
		t.ok(VFX.MAX_DISTANCE == 250, "far effects cut at 250 studs")
		for i = 2, #VFX.GEAR_SHIFTS do
			t.ok(VFX.GEAR_SHIFTS[i] > VFX.GEAR_SHIFTS[i - 1], "gear shifts ascend")
		end
		for mat, c in VFX.SurfaceDust do
			t.ok(isEnumName(Enum.Material, mat), mat .. " is a Material")
			t.eq(typeof(c), "Color3", mat)
		end
		t.ok(#VFX.CONFETTI_COLORS >= 4, "confetti colors")
		t.ok(VFX.Presets.Confetti.pool >= #VFX.CONFETTI_COLORS, "a confetti slot per color (no live recolor)")
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
	-- Burst pools (emission is recorded: the harness has no ParticleEmitter:Emit)
	---------------------------------------------------------------------------------------------------------------

	local emitted = {}
	local function recorder(e, n)
		table.insert(emitted, { emitter = e, n = n })
	end

	local function freshLib(tier)
		Lib._reset()
		Lib._setEmitter(recorder)
		Lib._setCamera(Vector3.new(0, 0, 0))
		Lib.setQualityOverride(tier or "high")
		table.clear(emitted)
	end

	t.test("burst: pooled ring per preset, slots built once and reused", function()
		freshLib("high")
		local preset = VFX.Presets.Sparks
		for i = 1, preset.pool * 3 do
			t.eq(Lib.burst("Sparks", Vector3.new(i, 0, 0)), preset.count, "full count on high")
		end
		local built, size = Lib._poolInfo("Sparks")
		t.eq(size, preset.pool)
		t.eq(built, preset.pool, "never more emitters than pool slots")
		local distinct = {}
		for _, rec in emitted do
			distinct[rec.emitter] = true
		end
		local n = 0
		for _ in distinct do
			n += 1
		end
		t.eq(n, preset.pool, "bursts rotate through every slot")
		local host = H.workspace:FindFirstChild("ClientVFX"):FindFirstChild("VFXHost")
		t.ok(host ~= nil and host.Anchored and host.Transparency == 1, "one invisible anchored host")
		local e = emitted[1].emitter
		t.eq(e.Enabled, false, "pooled emitters never emit on their own")
		t.eq(e.Texture, VFX.Textures.spark_streak)
		t.eq(e.Orientation, Enum.ParticleOrientation.VelocityParallel)
		Lib._setEmitter(nil)
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
			Lib._setEmitter(nil)
		end
	)

	t.test("burst: overrides (color, scale, direction) and the budget cap", function()
		freshLib("high")
		local c = Color3.fromRGB(10, 200, 30)
		Lib.burst("Confetti", Vector3.zero, { color = c, scale = 2, direction = Vector3.new(1, 0, 0) })
		local rec = emitted[#emitted]
		local e = rec.emitter
		t.eq(e.Color.Keypoints[1].Value, c, "constant color override")
		t.near(e.Size.Keypoints[1].Value, VFX.Presets.Confetti.size[1].v * 2, 1e-6, "size scaled")
		local att = e.Parent
		t.near((att.WorldCFrame.UpVector - Vector3.new(1, 0, 0)).Magnitude, 0, 1e-4, "aimed along direction")
		-- same slot again without overrides: preset look restored
		for _ = 1, VFX.Presets.Confetti.pool - 1 do
			Lib.burst("Confetti", Vector3.zero)
		end
		Lib.burst("Confetti", Vector3.zero)
		t.eq(emitted[#emitted].emitter, e, "ring wrapped to the first slot")
		t.near(e.Size.Keypoints[1].Value, VFX.Presets.Confetti.size[1].v, 1e-6, "scale reset")
		t.eq(e.Color.Keypoints[1].Value, Color3.new(1, 1, 1), "color reset to the preset")
		-- cap: fill the budget, then bursts are refused until particles expire
		Lib._reset()
		Lib.setQualityOverride("high")
		Lib.quality() -- latch the tier (it sets the cap), then shrink the cap for the test
		Lib.budget.cap = 30
		t.eq(Lib.burst("Sparks", Vector3.zero), 26)
		t.eq(Lib.burst("Sparks", Vector3.zero), 4, "clipped to the cap")
		t.eq(Lib.burst("Sparks", Vector3.zero), 0, "full")
		Lib._setEmitter(nil)
	end)

	---------------------------------------------------------------------------------------------------------------
	-- Streams / trails / beams
	---------------------------------------------------------------------------------------------------------------

	t.test("stream: rate from tier x intensity, load accounted, off releases the budget", function()
		freshLib("medium")
		local att = Instance.new("Attachment")
		local s = Lib.stream("TireSmoke", att)
		t.ok(s ~= nil and s.emitter.Parent == att, "emitter on the caller's attachment")
		t.eq(s.emitter.Enabled, false, "starts off")
		t.eq(s.emitter.FlipbookLayout, Enum.ParticleFlipbookLayout.Grid4x4)
		t.eq(s.emitter.FlipbookMode, Enum.ParticleFlipbookMode.OneShot)
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

	t.test("trail + beam rigs: attachments placed, start disabled, preset applied", function()
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
		end
	end)

	t.test("WheelAnimator.wantsHeadlights: moving cars light up at night, parked ones stay dark", function()
		local WA = H.require("src/client/Controllers/WheelAnimator")
		t.eq(WA.wantsHeadlights("Traffic", nil), true)
		t.eq(WA.wantsHeadlights("Police", 0), true)
		t.eq(WA.wantsHeadlights("Loot", 42), true, "driven loot car")
		t.eq(WA.wantsHeadlights("Owned", 7), true)
		t.eq(WA.wantsHeadlights("Parked", nil), false)
		t.eq(WA.wantsHeadlights("Loot", 0), false, "abandoned")
		t.eq(WA.wantsHeadlights("HotDrop", nil), false)
		t.ok(WA.LOW_TIER.HEADLIGHT_CARS < WA.HEADLIGHT_CARS, "phones light fewer cars")
	end)

	t.test("controllers using the library still load headlessly", function()
		for _, path in
			{
				"src/client/Controllers/EffectsController",
				"src/client/Controllers/WheelAnimator",
				"src/client/Controllers/CombatClient",
			}
		do
			local ok, err = pcall(H.require, path)
			t.ok(ok, path .. ": " .. tostring(err))
		end
		Lib._setCamera(nil)
		Lib._reset()
	end)
end
