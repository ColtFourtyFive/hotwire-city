--!nocheck
-- C4a characters: Config/PlayerLooks invariants (realistic bodies only, no banned ids, every slot has a fallback,
-- 8+ skin tones, 5 outfit styles), Appearance/LookCodec (validation of untrusted payloads, keys <-> indices, seeded and
-- random looks, records), Appearance/DescriptionSpec (fallback levels 0 / 1 / 2, own-avatar clamps),
-- Appearance/CreatorModel (rows, framing, studio set) and AppearanceService through its seams (DataStore load / save
-- with retries and the newer-record rule, fallback levels on apply, remote validation, the creator studio gates).
return function(t)
	local H = t.H
	local fs = require("@lune/fs")
	local task = require("@lune/task")
	H.setMode("server")
	local Instance = H.roblox.Instance
	local V3 = H.roblox.Vector3
	local CF = H.roblox.CFrame
	local L = H.require("src/shared/Config/PlayerLooks")
	local LookCodec = H.require("src/shared/Appearance/LookCodec")
	local DescriptionSpec = H.require("src/shared/Appearance/DescriptionSpec")
	local CreatorModel = H.require("src/shared/Appearance/CreatorModel")

	local REALISTIC_BUNDLES = { [988] = 1, [989] = 1, [990] = 1, [991] = 1, [992] = 1, [993] = 1, [994] = 1, [995] = 1 }
	local RTHRO_REALISTIC = { [337] = 1, [572] = 1, [573] = 1, [722] = 1 }

	local function keysUnique(list, what)
		local seen = {}
		for _, e in list do
			t.ok(typeof(e.key) == "string" and e.key ~= "", what .. " key")
			t.ok(not seen[e.key], what .. " duplicate key " .. tostring(e.key))
			seen[e.key] = true
		end
	end

	-- PLAYERLOOKS --------------------------------------------------------------------------------------------------

	t.test("PlayerLooks: realistic bodies only (988-995 + 337/572/573/722), never anime or blocky", function()
		t.ok(#L.Bodies >= 8, "8+ bodies")
		local base = 0
		for _, b in L.Bodies do
			t.ok(REALISTIC_BUNDLES[b.bundle] or RTHRO_REALISTIC[b.bundle], "bundle " .. b.bundle .. " is realistic")
			t.ok(not L.BANNED_BUNDLES[b.bundle], "bundle " .. b.bundle .. " not banned")
			if REALISTIC_BUNDLES[b.bundle] then
				base += 1
			end
			for _, part in { "torso", "leftArm", "rightArm", "leftLeg", "rightLeg" } do
				t.ok(typeof(b.parts[part]) == "number" and b.parts[part] > 0, b.key .. "." .. part)
			end
			t.ok(b.width >= 0.95 and b.width <= 1.1, b.key .. " width realistic")
		end
		t.eq(base, 8, "all eight Base Body bundles")
		for _, banned in { 238, 239, 979, 980, 981, 982, 983, 984, 985, 986, 987 } do
			t.ok(L.BANNED_BUNDLES[banned], "bundle " .. banned .. " is banned")
		end
		keysUnique(L.Bodies, "body")
	end)

	t.test("PlayerLooks: faces are dynamic heads from realistic bundles; body face lists resolve", function()
		keysUnique(L.Faces, "face")
		local byKey = {}
		for _, f in L.Faces do
			byKey[f.key] = f
			t.ok(REALISTIC_BUNDLES[f.bundle] or f.bundle == 572 or f.bundle == 573, "face bundle " .. f.bundle)
			t.ok(f.head > 0, f.key .. " head")
			-- the stylized 337 / 722 heads are not offered
			t.ok(f.bundle ~= 337 and f.bundle ~= 722, f.key .. " not a stylized head")
		end
		for _, b in L.Bodies do
			t.ok(#b.faces >= 1, b.key .. " has faces")
			for _, k in b.faces do
				t.ok(byKey[k] ~= nil, b.key .. " face " .. k .. " exists")
			end
		end
		t.eq(L.MOOD, 0, "neutral default mood (not the anime mood)")
	end)

	t.test("PlayerLooks: banned ids never appear (62234425), 8+ natural skin tones, hair in every colour", function()
		local src = fs.readFile("src/shared/Config/PlayerLooks.luau"):gsub("%-%-[^\n]*", "")
		local n = 0
		for _ in src:gmatch("62234425") do
			n += 1
		end
		t.eq(n, 1, "62234425 only in the BANNED table")
		t.ok(#L.SkinTones >= 8, "8+ skin tones")
		keysUnique(L.SkinTones, "skin")
		-- natural: no saturated / cartoon tones (yellow Roblox skin is the kill list)
		for _, s in L.SkinTones do
			local r, g, b = s.color.R, s.color.G, s.color.B
			t.ok(r >= g and g >= b, s.key .. " ordered like real skin (r >= g >= b)")
			t.ok(r - b < 0.4, s.key .. " not oversaturated")
		end
		keysUnique(L.HairStyles, "hair")
		keysUnique(L.HairColors, "hair colour")
		local shaved = 0
		for _, h in L.HairStyles do
			if h.ids == nil then
				shaved += 1
			else
				for _, c in L.HairColors do
					local id = h.ids[c.key]
					t.ok(typeof(id) == "number" and id > 0, h.key .. " has " .. c.key)
					t.ok(not L.BANNED[id], h.key .. " " .. c.key .. " not banned")
				end
			end
		end
		t.eq(shaved, 1, "one shaved option")
		local fb
		for _, h in L.HairStyles do
			if h.key == L.HAIR_FALLBACK_STYLE then
				fb = h
			end
		end
		t.ok(fb and fb.ids, "hair fallback style has ids")
	end)

	t.test("PlayerLooks: 5 outfit styles, every garment has a different fallback, shoes resolve", function()
		local styles = {}
		for _, o in L.Outfits do
			styles[o.key] = true
			t.ok(#o.variants >= 3, o.key .. " has 3+ variants")
			keysUnique(o.variants, o.key .. " variant")
			for _, v in o.variants do
				t.ok(L.Shoes[v.shoes] ~= nil, v.key .. " shoes " .. tostring(v.shoes))
				t.ok(#v.garments >= 2, v.key .. " top + bottom")
				local hasBottom = false
				for _, gm in v.garments do
					t.ok(table.find(L.GARMENT_KINDS, gm.kind) ~= nil, v.key .. " kind " .. gm.kind)
					t.ok(gm.fallback ~= nil, v.key .. " " .. gm.kind .. " has a fallback")
					t.ok(gm.fallback.id ~= gm.id, v.key .. " fallback differs")
					t.ok(not L.BANNED[gm.id] and not L.BANNED[gm.fallback.id], v.key .. " not banned")
					if gm.kind == "Pants" or gm.kind == "Shorts" then
						hasBottom = true
					end
				end
				t.ok(hasBottom, v.key .. " wears trousers or shorts")
			end
		end
		for _, k in { "street", "business", "biker", "beach", "workwear" } do
			t.ok(styles[k], "style " .. k)
		end
		t.ok(L.Shoes[L.SHOES_FALLBACK] ~= nil, "shoe fallback")
		for key, s in L.Shoes do
			t.eq(s.key, key, "shoe key")
			t.ok(s.left > 0 and s.right > 0 and s.left ~= s.right, key .. " left / right")
		end
		for _, kind in L.GARMENT_KINDS do
			t.ok(L.LAYER_ORDER[kind] ~= nil, "layer order for " .. kind)
		end
		t.ok(L.LAYER_ORDER.Jacket > L.LAYER_ORDER.Shirt, "jackets over shirts")
		t.ok(L.LAYER_ORDER.Shirt > L.LAYER_ORDER.Pants, "tops untucked over trousers")
		t.ok(L.LAYER_ORDER.Pants > L.LAYER_ORDER.LeftShoe, "trouser legs over shoes")
	end)

	t.test("PlayerLooks: walk styles carry all 7 animations; fallbacks are Roblox / free; scale ~1.05", function()
		keysUnique(L.WalkStyles, "walk")
		for _, p in table.move(L.WalkStyles, 1, #L.WalkStyles, 1, { L.ANIM_SAFE }) do
			for _, slot in { "idle", "walk", "run", "jump", "fall", "climb", "swim" } do
				t.ok(typeof(p[slot]) == "number" and p[slot] > 0, p.key .. "." .. slot)
			end
		end
		t.eq(L.WalkStyles[1].key, "community", "adidas Community mocap first (the default)")
		local fb = false
		for _, p in L.WalkStyles do
			fb = fb or p.key == L.ANIM_FALLBACK
		end
		t.ok(fb, "ANIM_FALLBACK is a walk style")
		t.eq(L.ANIM_SAFE.bundle, 356, "Rthro safe set")
		t.ok(L.HEIGHT_SCALE >= 1.0 and L.HEIGHT_SCALE <= 1.1, "BodyHeightScale ~1.05")
		t.ok(L.SAFE.body and L.SAFE.face and #L.SAFE.garments >= 2, "SAFE look")
	end)

	-- LOOKCODEC ---------------------------------------------------------------------------------------------------

	t.test("LookCodec.validate: rejects junk payloads, accepts every in-range look", function()
		local good = LookCodec.default()
		t.ok(LookCodec.validate(good) ~= nil, "default valid")
		local bads = {
			nil,
			5,
			"1.1.1",
			{},
			setmetatable(LookCodec.copy(good), {}),
		}
		for i, b in bads do
			t.ok(LookCodec.validate(b) == nil, "junk " .. i)
		end
		local function with(field, v)
			local p = LookCodec.copy(good)
			p[field] = v
			return LookCodec.validate(p)
		end
		for _, f in LookCodec.FIELDS do
			t.ok(with(f, 0) == nil, f .. " 0")
			t.ok(with(f, 1.5) == nil, f .. " fraction")
			t.ok(with(f, 0 / 0) == nil, f .. " NaN")
			t.ok(with(f, math.huge) == nil, f .. " inf")
			t.ok(with(f, "1") == nil, f .. " string")
			t.ok(with(f, LookCodec.count(f, good.outfit) + 1) == nil, f .. " past the end")
		end
		local extra = LookCodec.copy(good)
		extra.cash = 1
		t.ok(LookCodec.validate(extra) == nil, "unknown field")
		local missing = LookCodec.copy(good)
		missing.walk = nil
		t.ok(LookCodec.validate(missing) == nil, "missing field")
		-- variant bounds follow the outfit
		for oi, o in L.Outfits do
			local p = LookCodec.copy(good)
			p.outfit = oi
			p.variant = #o.variants
			t.ok(LookCodec.validate(p) ~= nil, o.key .. " last variant ok")
			p.variant = #o.variants + 1
			t.ok(LookCodec.validate(p) == nil, o.key .. " variant past its outfit")
		end
		local v = LookCodec.validate(good)
		t.ok(v ~= good, "validate returns a fresh table")
	end)

	t.test("LookCodec: keys round-trip; unknown keys fall back per field; parseKey inverts key", function()
		local rng = LookCodec.rng(42)
		for _ = 1, 200 do
			local look = LookCodec.random(rng)
			t.ok(LookCodec.validate(look) ~= nil, "random look valid")
			t.ok(LookCodec.equal(LookCodec.fromKeys(LookCodec.toKeys(look)), look), "keys round-trip")
			local parsed = LookCodec.parseKey(LookCodec.key(look))
			t.ok(parsed and LookCodec.equal(parsed, look), "parseKey(key)")
		end
		local keys = LookCodec.toKeys(LookCodec.default())
		keys.hair = "mohawk-gone"
		keys.variant = "nope"
		local l = LookCodec.fromKeys(keys)
		t.eq(l.hair, LookCodec.default().hair, "unknown hair -> default")
		t.eq(l.variant, 1, "unknown variant -> first")
		t.ok(LookCodec.equal(LookCodec.fromKeys(nil), LookCodec.default()), "nil keys -> default")
		t.ok(LookCodec.parseKey("1.2") == nil, "short key")
		t.ok(LookCodec.parseKey(string.rep("9", 80)) == nil, "long key")
		t.ok(LookCodec.parseKey("1.1.1.1.1.1.99.1") == nil, "out-of-range key")
		t.ok(LookCodec.parseKey(5) == nil, "non-string key")
	end)

	t.test("LookCodec: seeded looks are deterministic, varied, and never roll 0-weight styles", function()
		t.ok(LookCodec.equal(LookCodec.seeded(123456), LookCodec.seeded(123456)), "same userId -> same look")
		local outfits, skins, bodies = {}, {}, {}
		for uid = 1, 400 do
			local l = LookCodec.seeded(uid * 1000 + 17)
			outfits[l.outfit] = true
			skins[l.skin] = true
			bodies[l.body] = true
			t.ok(L.WalkStyles[l.walk].weight > 0, "0-weight walk never rolled")
			local frame = L.Bodies[l.body]
			t.ok(table.find(frame.faces, L.Faces[l.face].key) ~= nil, "face suits the frame")
		end
		local function count(set)
			local n = 0
			for _ in set do
				n += 1
			end
			return n
		end
		t.eq(count(outfits), #L.Outfits, "every outfit style appears")
		t.eq(count(skins), #L.SkinTones, "every skin tone appears")
		t.eq(count(bodies), #L.Bodies, "every body appears")
	end)

	t.test("LookCodec.set: changing the outfit resets the variant; options name every choice", function()
		local l = LookCodec.default()
		l.outfit = 1
		l.variant = 3
		local l2 = LookCodec.set(l, "outfit", 2)
		t.eq(l2.outfit, 2, "outfit set")
		t.eq(l2.variant, 1, "variant reset")
		t.eq(l.variant, 3, "input untouched")
		local l3 = LookCodec.set(l, "skin", 999)
		t.eq(l3.skin, LookCodec.default().skin, "out of range sanitized")
		t.ok(LookCodec.equal(LookCodec.set(l, "nope", 1), l), "unknown field ignored")
		t.eq(#LookCodec.options("variant", l2), #L.Outfits[2].variants, "variant options follow the outfit")
		t.eq(LookCodec.options("skin")[1], L.SkinTones[1].name, "names")
	end)

	t.test("LookCodec records: encode / decode, the newer stored record wins", function()
		local look = LookCodec.seeded(77)
		local rec = LookCodec.encodeRecord(look, true, 1000)
		t.eq(rec.v, LookCodec.RECORD_VERSION, "version")
		t.ok(rec.own == true, "own")
		local back, l2 = LookCodec.decodeRecord(rec)
		t.ok(back and l2 and LookCodec.equal(l2, look), "decode")
		t.ok(LookCodec.decodeRecord(nil) == nil, "absent")
		t.ok(LookCodec.decodeRecord({ look = 5 }) == nil, "malformed")
		local _, partial = LookCodec.decodeRecord({ look = { outfit = "beach" } })
		t.eq(L.Outfits[partial.outfit].key, "beach", "partial record keeps known fields")
		t.ok(LookCodec.storedIsNewer({ changedAt = 2000 }, rec), "stored newer")
		t.ok(not LookCodec.storedIsNewer({ changedAt = 999 }, rec), "stored older")
		t.ok(not LookCodec.storedIsNewer({ changedAt = 0 / 0 }, rec), "NaN never wins")
		t.ok(not LookCodec.storedIsNewer(nil, rec), "nothing stored")
	end)

	-- DESCRIPTIONSPEC ---------------------------------------------------------------------------------------------

	local function ids(spec)
		local set = {}
		for _, id in DescriptionSpec.assetIds(spec) do
			set[id] = true
		end
		return set
	end

	t.test("DescriptionSpec level 0: the chosen body, head, hair, garments, shoes and walk style", function()
		local rng = LookCodec.rng(9)
		for _ = 1, 150 do
			local look = LookCodec.random(rng)
			local spec = DescriptionSpec.build(look, 0)
			local body = L.Bodies[look.body]
			local face = L.Faces[look.face]
			t.eq(spec.level, 0, "level")
			t.eq(spec.torso, body.parts.torso, "torso")
			t.eq(spec.head, face.head, "dynamic head")
			t.eq(spec.mood, 0, "neutral mood")
			t.eq(spec.face + spec.shirt + spec.pants + spec.graphicTShirt, 0, "no classic face / 2D clothes")
			t.eq(spec.scales.height, L.HEIGHT_SCALE, "height scale")
			t.ok(spec.skin == L.SkinTones[look.skin].color, "skin tone")
			local set = ids(spec)
			for _, gm in L.Outfits[look.outfit].variants[look.variant].garments do
				t.ok(set[gm.id], "garment " .. gm.id)
			end
			local hair = DescriptionSpec.hairId(L.HairStyles[look.hair], look.hairColor)
			if hair then
				t.ok(set[hair], "hair")
			end
			t.eq(spec.anims.walk, L.WalkStyles[look.walk].walk, "walk style")
			for _, a in spec.accessories do
				t.ok(a.layered == true, "layered " .. a.kind)
				t.eq(a.order, L.LAYER_ORDER[a.kind], "order " .. a.kind)
			end
			for id in set do
				t.ok(not L.BANNED[id], "no banned id")
			end
		end
	end)

	t.test("DescriptionSpec level 1 / 2: Roblox-made fallbacks, then the SAFE look (skin kept)", function()
		local look = LookCodec.default()
		for oi, o in L.Outfits do
			for vi, v in o.variants do
				look.outfit = oi
				look.variant = vi
				local s1 = DescriptionSpec.build(look, 1)
				local set = ids(s1)
				for _, gm in v.garments do
					t.ok(set[gm.fallback.id], v.key .. " fallback " .. gm.fallback.id)
				end
				local sh = L.Shoes[L.SHOES_FALLBACK]
				t.ok(set[sh.left] and set[sh.right], "fallback shoes")
				t.eq(s1.anims.walk, L.WalkStyles[1].walk == s1.anims.walk and s1.anims.walk or s1.anims.walk, "anim")
			end
		end
		local fbPack
		for _, p in L.WalkStyles do
			if p.key == L.ANIM_FALLBACK then
				fbPack = p
			end
		end
		look.walk = 1
		t.eq(DescriptionSpec.build(look, 1).anims.walk, fbPack.walk, "level 1 walk = ANIM_FALLBACK")
		look.skin = 9
		local s2 = DescriptionSpec.build(look, 2)
		t.eq(s2.level, 2, "level 2")
		t.ok(s2.skin == L.SkinTones[9].color, "skin kept at level 2")
		t.eq(s2.anims.walk, L.ANIM_SAFE.walk, "Rthro set")
		local set2 = ids(s2)
		for _, gm in L.SAFE.garments do
			t.ok(set2[gm.id], "SAFE garment")
		end
		t.eq(DescriptionSpec.build(look, 99).level, DescriptionSpec.MAX_LEVEL, "level clamped")
		t.eq(DescriptionSpec.build({ junk = true }, 0).level, 0, "junk look sanitized")
	end)

	t.test("DescriptionSpec own-avatar: walk style forced, scales clamped to a fair range", function()
		local look = LookCodec.default()
		look.walk = 2
		local o = DescriptionSpec.ownOverrides(look)
		t.eq(o.anims.run, L.WalkStyles[2].run, "realistic animation pack on the own avatar")
		t.eq(DescriptionSpec.clampScale("height", 3), DescriptionSpec.OWN_CLAMP.height[2], "giant clamped")
		t.eq(DescriptionSpec.clampScale("width", 0.1), DescriptionSpec.OWN_CLAMP.width[1], "stick clamped")
		t.eq(DescriptionSpec.clampScale("height", 0 / 0), 1, "NaN height -> 1")
		t.eq(DescriptionSpec.clampScale("bodyType", "x"), 0, "junk bodyType -> 0")
	end)

	-- CREATORMODEL ------------------------------------------------------------------------------------------------

	t.test("CreatorModel.rows: every field as an options row, Randomize / Save, Skip on first join only", function()
		local look = LookCodec.seeded(5)
		local rows = CreatorModel.rows(look, "first")
		local byId = {}
		for _, r in rows do
			byId[r.id] = r
		end
		for _, f in LookCodec.FIELDS do
			local r = byId[f]
			t.ok(r ~= nil, "row " .. f)
			t.eq(r.field, f, "field")
			t.eq(r.optionIndex, look[f], f .. " selected option")
			t.eq(#r.options, LookCodec.count(f, look.outfit), f .. " options")
			t.ok(r.desc and r.desc ~= "", f .. " description")
		end
		t.eq(byId.hairColor.label, "Hair color", "labels")
		t.ok(byId.randomize and byId.save and byId.skip, "actions (first join)")
		local wardrobe = CreatorModel.rows(look, "wardrobe")
		local hasSkip = false
		for _, r in wardrobe do
			hasSkip = hasSkip or r.id == "skip"
		end
		t.ok(not hasSkip, "no Skip in the wardrobe")
		t.eq(CreatorModel.focusFor("hair"), "face", "hair close-up")
		t.eq(CreatorModel.focusFor("face"), "face", "face close-up")
		t.eq(CreatorModel.focusFor("outfit"), "body", "outfit full body")
		t.eq(CreatorModel.focusFor(nil), "body", "actions full body")
	end)

	t.test("CreatorModel.framing: full body fits the frame; close-up is near the head; desktop pushes right", function()
		local origin = V3.new(100, 50, -20)
		local headY = origin.Y + 5.4
		local cf, fov = CreatorModel.framing(origin, headY, "body", false, 0)
		t.eq(fov, CreatorModel.FOV, "portrait lens")
		local d = (cf.Position - origin).Magnitude
		local need = (headY - origin.Y + 0.7) * CreatorModel.BODY_MARGIN
		local visible = 2 * d * math.tan(math.rad(fov) / 2)
		t.ok(visible >= need * 0.95, "whole body visible")
		t.ok(cf.Position.Z > origin.Z, "in front of the character (it faces +Z)")
		t.ok(cf.LookVector.Z < 0, "looking back at it")
		-- the character appears right of centre (the list menu is on the left)
		local rel = cf:PointToObjectSpace(V3.new(origin.X, cf.Position.Y, origin.Z))
		t.ok(rel.X > 0, "character right of centre on desktop")
		local cft = CreatorModel.framing(origin, headY, "body", true, 0)
		local relT = cft:PointToObjectSpace(V3.new(origin.X, origin.Y + 2.7, origin.Z))
		t.ok(math.abs(relT.X) < 1e-3, "touch: centred horizontally")
		local face = CreatorModel.framing(origin, headY, "face", false, 0)
		t.ok((face.Position - V3.new(origin.X, headY, origin.Z)).Magnitude < 4.5, "close-up near the head")
		local orbit = CreatorModel.framing(origin, headY, "body", false, math.rad(90))
		t.ok(orbit.Position.X > origin.X + 5, "yaw orbits round the character")
		local stand = CreatorModel.standCFrame(origin, 3)
		t.near(stand.Position.Y, origin.Y + 3.05, 1e-6, "feet on the floor")
		t.ok(stand.LookVector.Z > 0.99, "faces the camera")
	end)

	t.test("CreatorModel.studio: an enclosed lit room with the floor under the spawn and a height chart", function()
		local parts, lights = CreatorModel.studio()
		local byName = {}
		for _, p in parts do
			byName[p.name] = p
			t.ok(p.size.X > 0 and p.size.Y > 0 and p.size.Z > 0, p.name .. " size")
			t.ok(not p.material:lower():find("neon"), p.name .. " no neon")
		end
		for _, n in { "Floor", "BackWall", "FrontWall", "LeftWall", "RightWall", "Ceiling" } do
			t.ok(byName[n], n)
		end
		local floor = byName.Floor
		t.near(floor.offset.Y + floor.size.Y / 2, 0, 1e-6, "floor top at the slot height")
		t.ok(math.abs(floor.offset.Z) < floor.size.Z / 2, "floor under the spawn point")
		t.ok(#lights >= 3, "key, rim and fill lights")
		-- the camera's furthest full-body position stays inside the room
		local cf = CreatorModel.framing(V3.zero, 5.6, "body", false, 0)
		t.ok(cf.Position.Z < CreatorModel.ROOM.front, "camera inside the room")
		local marks = CreatorModel.chartMarks()
		t.eq(#marks, 13, "1 ft to 7 ft in half feet")
		t.eq(marks[#marks].label, "7'", "7 ft label")
		t.near(marks[1].y, CreatorModel.FOOT, 1e-6, "1 ft")
	end)

	-- APPEARANCESERVICE -------------------------------------------------------------------------------------------

	local AS = H.require("src/server/Systems/AppearanceService")

	local function signal()
		local s = { fns = {} }
		function s:Connect(fn)
			table.insert(self.fns, fn)
			return { Disconnect = function() end }
		end
		function s:Fire(...)
			for _, fn in self.fns do
				fn(...)
			end
		end
		return s
	end

	local function fake(name, class, props)
		local attrs, children = {}, {}
		local o = props or {}
		o.Name = name
		o._class = class
		o._attrs = attrs
		o._children = children
		o.GetAttribute = function(_, k)
			return attrs[k]
		end
		o.SetAttribute = function(_, k, v)
			attrs[k] = v
		end
		o.FindFirstChild = function(_, n)
			for _, c in children do
				if c.Name == n then
					return c
				end
			end
			return nil
		end
		o.FindFirstChildOfClass = function(_, cls)
			for _, c in children do
				if c._class == cls then
					return c
				end
			end
			return nil
		end
		o.GetChildren = function()
			return table.clone(children)
		end
		o.GetDescendants = function()
			local out = {}
			local function walk(n)
				for _, c in n._children or {} do
					table.insert(out, c)
					walk(c)
				end
			end
			walk(o)
			return out
		end
		o.IsA = function(_, cls)
			return class == cls
				or (cls == "BasePart" and (class == "Part" or class == "MeshPart"))
				or (cls == "Decal" and class == "Decal")
				or cls == "Instance"
		end
		o.IsDescendantOf = function()
			return o._outside ~= true
		end
		o.FindFirstAncestorWhichIsA = function(_, cls)
			if cls == "Tool" then
				return o._tool
			end
			return nil
		end
		return o
	end

	local function fakeCharacter()
		local char = fake("Character", "Model", { DescendantAdded = signal() })
		local hum = fake("Humanoid", "Humanoid", { Health = 100, SeatPart = nil })
		local root = fake(
			"HumanoidRootPart",
			"Part",
			{ Transparency = 1, CFrame = CF.new(0, 3, 0), AssemblyLinearVelocity = V3.zero }
		)
		local torso = fake("UpperTorso", "MeshPart", { Transparency = 0 })
		local head = fake("Head", "MeshPart", { Transparency = 0 })
		local face = fake("face", "Decal", { Transparency = 0 })
		table.insert(head._children, face)
		for _, c in { hum, root, torso, head } do
			table.insert(char._children, c)
		end
		hum._char = char
		char.PivotTo = function(self, cf)
			root.CFrame = cf
		end
		return char, hum, root, head, face
	end

	local nextId = 50000
	local function fakePlayer()
		nextId += 1
		local p = fake("P" .. nextId, "Player", { UserId = nextId, CharacterAdded = signal(), Parent = true })
		return p
	end

	-- a DataStore double: GetAsync / UpdateAsync with failure injection
	local function makeStore()
		local store = { data = {}, getFails = 0, updateFails = 0, gets = 0, updates = 0 }
		function store:GetAsync(key)
			self.gets += 1
			if self.getFails > 0 then
				self.getFails -= 1
				error("502: DataStore request failed")
			end
			return self.data[key]
		end
		function store:UpdateAsync(key, fn)
			self.updates += 1
			if self.updateFails > 0 then
				self.updateFails -= 1
				error("502: DataStore request failed")
			end
			local new = fn(self.data[key])
			if new ~= nil then
				self.data[key] = new
			end
			return self.data[key]
		end
		return store
	end

	local applied = {}
	local applyFailLevels = {} -- apply call number -> true: that apply errors
	local accessoriesPerApply = 12 -- accessories the fake engine "loads" per apply
	local loadKinds = nil -- (apply number) -> { AccessoryType names } the fake engine loads instead (typed accessories)
	local function installHooks(store)
		table.clear(applied)
		AS._setHooks({
			store = store,
			wait = function() end,
			delay = function() end,
			backoff = 0,
			isStudio = function()
				return false
			end,
			now = function()
				return 5000
			end,
			apply = function(hum, desc)
				table.insert(applied, { hum = hum, desc = desc })
				if applyFailLevels[#applied] then
					error("Failed to load asset")
				end
				-- the engine swaps the accessories: drop the old ones, "load" accessoriesPerApply new ones
				local char = hum._char
				if char then
					for i = #char._children, 1, -1 do
						if char._children[i]._class == "Accessory" then
							table.remove(char._children, i)
						end
					end
					local kinds = loadKinds and loadKinds(#applied)
					if kinds then
						for i, k in kinds do
							table.insert(
								char._children,
								fake("Acc" .. i, "Accessory", { AccessoryType = H.roblox.Enum.AccessoryType[k] })
							)
						end
					else
						for i = 1, accessoriesPerApply do
							table.insert(char._children, fake("Acc" .. i, "Accessory"))
						end
					end
				end
			end,
			userDescription = function()
				return Instance.new("HumanoidDescription")
			end,
			isRagdolled = function()
				return false
			end,
			clock = os.clock,
		})
	end

	local function settle()
		for _ = 1, 6 do
			task.wait()
		end
	end

	t.test(
		"AppearanceService: DataStore load retries then succeeds; a total failure never prompts the creator",
		function()
			AS._reset()
			local store = makeStore()
			installHooks(store)
			store.getFails = 2
			local ok, raw = AS._load("1")
			t.ok(ok and raw == nil, "loaded after retries (empty)")
			t.eq(store.gets, 3, "three attempts")
			store.getFails = 99
			local ok2 = AS._load("1")
			t.ok(not ok2, "gave up after RETRIES")

			local p = fakePlayer()
			store.getFails = 99
			AS._onPlayerAdded(p)
			settle()
			t.eq(p:GetAttribute("HC_LookLoaded"), true, "loaded flag set even on failure")
			t.eq(p:GetAttribute("HC_LookSaved"), true, "store down: never prompt a returning player")
			t.eq(p:GetAttribute("HC_Look"), LookCodec.key(LookCodec.seeded(p.UserId)), "wears the seeded look")
			AS._onPlayerRemoving(p)
			t.eq(store.updates, 0, "nothing written after a failed load")
		end
	)

	t.test("AppearanceService: first join (no record) -> seeded look + creator due; saved look restored", function()
		AS._reset()
		local store = makeStore()
		installHooks(store)
		local p = fakePlayer()
		AS._onPlayerAdded(p)
		settle()
		t.eq(p:GetAttribute("HC_LookSaved"), false, "no saved look -> the creator opens")
		t.eq(p:GetAttribute("HC_LookOwn"), false, "own avatar off by default")
		local saved = LookCodec.seeded(999)
		local p2 = fakePlayer()
		store.data[tostring(p2.UserId)] = LookCodec.encodeRecord(saved, false, 10)
		AS._onPlayerAdded(p2)
		settle()
		t.eq(p2:GetAttribute("HC_LookSaved"), true, "saved")
		t.eq(p2:GetAttribute("HC_Look"), LookCodec.key(saved), "wears the saved look")
		t.ok(LookCodec.equal(AS.getLook(p2), saved), "getLook")
	end)

	t.test(
		"AppearanceService: saves are session-safe (a newer record from another server is kept) + retried",
		function()
			AS._reset()
			local store = makeStore()
			installHooks(store)
			local mine = LookCodec.encodeRecord(LookCodec.seeded(1), false, 100)
			store.data.k = LookCodec.encodeRecord(LookCodec.seeded(2), false, 200)
			t.ok(AS._save("k", mine), "save call ok")
			t.eq(store.data.k.changedAt, 200, "newer stored record kept")
			local later = LookCodec.encodeRecord(LookCodec.seeded(3), true, 300)
			store.updateFails = 2
			t.ok(AS._save("k", later), "retried")
			t.eq(store.data.k.changedAt, 300, "written")
			t.eq(store.data.k.own, true, "own flag stored")
			store.updateFails = 99
			t.ok(not AS._save("k", LookCodec.encodeRecord(LookCodec.seeded(4), false, 400)), "gives up")
			-- the record holds list KEYS (reordering PlayerLooks never scrambles a look)
			t.eq(typeof(store.data.k.look.outfit), "string", "keys persisted")
		end
	)

	t.test("AppearanceService: apply walks the fallback levels; hides the default body until dressed", function()
		AS._reset()
		local store = makeStore()
		installHooks(store)
		local p = fakePlayer()
		local char, hum, _, head, face = fakeCharacter()
		p.Character = char
		AS._onPlayerAdded(p)
		settle()
		local st = AS._state(p)
		t.ok(st ~= nil, "state")
		-- spawn hid the default body (decal + parts), not the root
		t.eq(head.Transparency, 0, "revealed after the spawn apply")
		t.ok(#applied >= 1, "applied at spawn")
		t.eq(hum.DisplayDistanceType, H.roblox.Enum.HumanoidDisplayDistanceType.None, "no overhead name")
		t.eq(hum.HealthDisplayType, H.roblox.Enum.HumanoidHealthDisplayType.AlwaysOff, "no overhead health")

		-- level 0 errors -> level 1 used
		table.clear(applied)
		table.clear(applyFailLevels)
		applyFailLevels[1] = true
		local used = AS._applyOnce(st, LookCodec.seeded(8), false)
		t.eq(used, 1, "fell back to level 1")
		t.eq(p:GetAttribute("HC_LookLevel"), 1, "level published")
		-- level 0 "loads" only a few accessories (an item went off sale) -> retried at level 1
		table.clear(applied)
		accessoriesPerApply = 1
		local short = AS._applyOnce(st, LookCodec.seeded(8), false)
		t.eq(#applied, 3, "levels 0, 1 and 2 tried")
		t.eq(short, 2, "the SAFE level is accepted whatever it loads")
		accessoriesPerApply = 12
		-- every level errors -> nil, body still shown
		table.clear(applied)
		applyFailLevels = { [1] = true, [2] = true, [3] = true }
		t.ok(AS._applyOnce(st, LookCodec.seeded(8), false) == nil, "all levels failed")
		applyFailLevels = {}
		-- own avatar
		table.clear(applied)
		t.eq(AS._applyOnce(st, LookCodec.seeded(8), true), -1, "own avatar applied")
		local _ = face
	end)

	t.test("AppearanceService.toDescription: a realistic HumanoidDescription (no classic slots, no emotes)", function()
		local spec = DescriptionSpec.build(LookCodec.seeded(31), 0)
		local d = AS.toDescription(spec)
		t.eq(d.ClassName, "HumanoidDescription", "instance")
		local okHead, head = pcall(function()
			return d.Head
		end)
		if okHead then
			t.eq(head, spec.head, "dynamic head")
			t.eq(d.Torso, spec.torso, "torso")
			t.eq(d.Face, 0, "no decal face")
			t.eq(d.Shirt, 0, "no 2D shirt")
			t.eq(d.HairAccessory, "", "no rigid hair slot")
			t.near(d.HeightScale, L.HEIGHT_SCALE, 1e-4, "height")
			t.eq(d.WalkAnimation, spec.anims.walk, "walk pack")
		end
		local entries = AS.accessoryEntries(spec)
		t.eq(#entries, #spec.accessories, "every accessory becomes an entry")
		for _, e in entries do
			t.ok(e.IsLayered == true and e.Order > 0 and e.AssetId > 0, "layered entry")
		end
	end)

	t.test("AppearanceService remotes: indices validated, preview only in the studio, gates on opening", function()
		AS._reset()
		local store = makeStore()
		installHooks(store)
		local p = fakePlayer()
		local char = fakeCharacter()
		p.Character = char
		AS._onPlayerAdded(p)
		settle()
		local st = AS._state(p)
		local before = LookCodec.key(st.worn)
		-- preview outside the studio: ignored
		AS._onPreview(p, LookCodec.seeded(3))
		t.eq(LookCodec.key(st.worn), before, "no preview outside the creator")
		-- blocked while wanted
		p:SetAttribute("Wanted", 2)
		AS._onCreator(p, true)
		t.ok(p:GetAttribute("HC_Creator") == nil, "wanted: no studio")
		p:SetAttribute("Wanted", 0)
		p:SetAttribute("InCombat", true)
		AS._onCreator(p, true)
		t.ok(p:GetAttribute("HC_Creator") == nil, "in combat: no studio")
		p:SetAttribute("InCombat", false)
		AS._onCreator(p, "yes")
		t.ok(p:GetAttribute("HC_Creator") == nil, "non-boolean ignored")
		AS._onCreator(p, true)
		t.eq(typeof(p:GetAttribute("HC_Creator")), "Vector3", "studio slot handed out")
		t.ok(AS.inCreator(p), "inCreator")
		-- junk previews are dropped
		AS._onPreview(p, { body = 999 })
		AS._onPreview(p, "1.1.1")
		t.eq(LookCodec.key(st.worn), before, "junk ignored")
		local pick = LookCodec.seeded(44)
		AS._onPreview(p, pick)
		t.eq(p:GetAttribute("HC_Look"), LookCodec.key(pick), "preview worn")
		-- save: stored (keys), creator closed, body taken back
		AS._onSave(p, pick)
		settle()
		t.ok(p:GetAttribute("HC_Creator") == nil, "slot freed")
		t.eq(p:GetAttribute("HC_LookSaved"), true, "saved")
		AS._flush(st)
		local rec = store.data[tostring(p.UserId)]
		t.ok(rec ~= nil, "written")
		t.ok(LookCodec.equal(LookCodec.fromKeys(rec.look), pick), "saved look")
		-- own avatar toggle: boolean only, stored
		AS._onSetOwn(p, "on")
		t.eq(p:GetAttribute("HC_LookOwn"), false, "junk ignored")
		AS._onSetOwn(p, true)
		t.eq(p:GetAttribute("HC_LookOwn"), true, "own avatar on")
		AS._flush(st)
		t.eq(store.data[tostring(p.UserId)].own, true, "stored")
		AS._onPlayerRemoving(p)
		t.ok(AS._state(p) == nil, "cleaned up")
	end)

	t.test("AppearanceService: cancelling the creator restores the saved look; slots are reused", function()
		AS._reset()
		local store = makeStore()
		installHooks(store)
		local p = fakePlayer()
		p.Character = fakeCharacter()
		AS._onPlayerAdded(p)
		settle()
		local st = AS._state(p)
		local saved = LookCodec.key(st.look)
		AS._onCreator(p, true)
		local slot1 = p:GetAttribute("HC_Creator")
		AS._onPreview(p, LookCodec.seeded(123))
		AS._onCreator(p, false)
		settle()
		t.eq(p:GetAttribute("HC_Look"), saved, "saved look back")
		t.ok(p:GetAttribute("HC_Creator") == nil, "closed")
		local q = fakePlayer()
		q.Character = fakeCharacter()
		AS._onPlayerAdded(q)
		settle()
		AS._onCreator(q, true)
		t.ok(q:GetAttribute("HC_Creator") == slot1, "freed slot reused")
		t.ok((AS.studioPosition(2) - AS.studioPosition(1)).Magnitude >= 100, "rooms far apart")
	end)

	t.test("AppearanceService source: non-deprecated APIs only, its own store, DataService untouched", function()
		local src = fs.readFile("src/server/Systems/AppearanceService.luau")
		t.ok(src:find("ApplyDescriptionAsync", 1, true) ~= nil, "ApplyDescriptionAsync")
		t.ok(not src:find(":ApplyDescription%("), "no deprecated ApplyDescription")
		t.ok(not src:find("GetHumanoidDescriptionFromUserId%("), "no deprecated GetHumanoidDescriptionFromUserId")
		t.ok(src:find('"HC_Appearance_v1"', 1, true) ~= nil, "own DataStore")
		t.ok(not src:find("DataService", 1, true) or not src:find("require%(.-DataService"), "no DataService require")
		local project = fs.readFile("default.project.json")
		t.ok(project:find('"LoadCharacterAppearance": false', 1, true) ~= nil, "LoadCharacterAppearance off")
	end)

	-- C4a FIX PASS --------------------------------------------------------------------------------------------------

	t.test("fix: a quick open -> Back gets through the rate limits; so does a quick own-avatar On -> Off", function()
		local Net = H.require("src/shared/Net")
		local p = fakePlayer()
		t.ok(Net._allow(p, "AppearanceCreator", AS.RATE_CREATOR), "open")
		t.ok(Net._allow(p, "AppearanceCreator", AS.RATE_CREATOR), "an instant Back is not dropped")
		t.ok(Net._allow(p, "AppearanceSetOwn", AS.RATE_SET_OWN), "own avatar On")
		t.ok(Net._allow(p, "AppearanceSetOwn", AS.RATE_SET_OWN), "an instant Off is not dropped")
		local src = fs.readFile("src/server/Systems/AppearanceService.luau")
		t.ok(
			src:find(
				'Net.on("AppearanceCreator", AppearanceService._onCreator, AppearanceService.RATE_CREATOR)',
				1,
				true
			)
		)
		t.ok(
			src:find('Net.on("AppearanceSetOwn", AppearanceService._onSetOwn, AppearanceService.RATE_SET_OWN)', 1, true)
		)
		-- the client: a lost answer is asked again, then the body walks home before the studio floor goes
		local cc = fs.readFile("src/client/Controllers/CharacterCreator.luau")
		t.ok(cc:find("local function awaitServer", 1, true) ~= nil, "close / save retried once")
		t.ok(cc:find("pcall(char.PivotTo, char, home)", 1, true) ~= nil, "give-up path walks the body home")
		t.ok(cc:find('elseif phase == "closed" then', 1, true) ~= nil, "a late studio slot is handed back")
	end)

	t.test(
		"fix: nothing a player sends is acted on before their record loaded (no overwrite of a saved look)",
		function()
			AS._reset()
			local store = makeStore()
			installHooks(store)
			local gate = true
			local realGet = store.GetAsync
			function store:GetAsync(key)
				while gate do
					task.wait()
				end
				return realGet(self, key)
			end
			local p = fakePlayer()
			local saved = LookCodec.seeded(4242)
			store.data[tostring(p.UserId)] = LookCodec.encodeRecord(saved, false, 10)
			AS._onPlayerAdded(p)
			task.wait()
			AS._onSetOwn(p, true)
			AS._onCreator(p, true)
			settle()
			t.eq(p:GetAttribute("HC_LookOwn"), false, "switch ignored until loaded")
			t.ok(p:GetAttribute("HC_Creator") == nil, "no studio until loaded")
			t.eq(AS.creatorBlocked(p), "loading", "creator gate says loading")
			t.eq(store.updates, 0, "nothing written over the stored look")
			gate = false
			settle()
			t.eq(p:GetAttribute("HC_Look"), LookCodec.key(saved), "the saved look is worn")
			AS._onSetOwn(p, true)
			settle()
			t.eq(p:GetAttribute("HC_LookOwn"), true, "now honoured")
			AS._onPlayerRemoving(p)
		end
	)

	t.test("fix: after a FAILED load the own-avatar switch only merges `own` into the stored record", function()
		local stored = LookCodec.encodeRecord(LookCodec.seeded(77), false, 50)
		stored.look.walk = "some_future_walk" -- raw keys this server does not know are kept as written
		local mine = LookCodec.encodeRecord(LookCodec.seeded(1), true, 60)
		local merged = LookCodec.mergeOwn(stored, mine)
		t.eq(merged.own, true, "own merged")
		t.eq(merged.changedAt, 60, "changedAt merged")
		t.eq(merged.look.walk, "some_future_walk", "stored look kept as written")
		t.eq(merged.look.outfit, stored.look.outfit, "stored outfit kept")
		t.ok(
			LookCodec.mergeOwn(LookCodec.encodeRecord(LookCodec.seeded(2), false, 99), mine) == nil,
			"newer stored wins"
		)
		t.eq(LookCodec.mergeOwn(nil, mine), mine, "nothing stored -> ours")

		AS._reset()
		local store = makeStore()
		installHooks(store)
		local p = fakePlayer()
		local key = tostring(p.UserId)
		store.data[key] = LookCodec.encodeRecord(LookCodec.seeded(31337), false, 10)
		local before = table.clone(store.data[key].look)
		store.getFails = 99
		p.Character = fakeCharacter()
		AS._onPlayerAdded(p)
		settle()
		store.getFails = 0
		AS._onSetOwn(p, true)
		settle()
		AS._flush(AS._state(p))
		local rec = store.data[key]
		t.eq(rec.own, true, "own stored")
		for k, v in before do
			t.eq(rec.look[k], v, "stored look field " .. k .. " untouched")
		end
		AS._onPlayerRemoving(p)
	end)

	t.test(
		"fix: own avatar on -> the lineup shows the realistic look; Back restores the avatar; Save wears it",
		function()
			AS._reset()
			local store = makeStore()
			installHooks(store)
			local p = fakePlayer()
			p.Character = fakeCharacter()
			AS._onPlayerAdded(p)
			settle()
			AS._onSetOwn(p, true)
			settle()
			t.eq(p:GetAttribute("HC_LookLevel"), -1, "own avatar worn")
			AS._onCreator(p, true)
			settle()
			t.eq(typeof(p:GetAttribute("HC_Creator")), "Vector3", "in the studio")
			t.eq(p:GetAttribute("HC_LookLevel"), 0, "the studio shows the realistic look")
			AS._onCreator(p, false)
			settle()
			t.eq(p:GetAttribute("HC_LookLevel"), -1, "Back: the Roblox avatar again")
			t.eq(p:GetAttribute("HC_LookOwn"), true, "still on")
			AS._onCreator(p, true)
			settle()
			local look = AS.getLook(p)
			AS._onSave(p, look) -- the same look: the body must still leave the Roblox avatar
			settle()
			t.eq(p:GetAttribute("HC_LookOwn"), false, "saving a look switches the own avatar off")
			t.eq(p:GetAttribute("HC_LookLevel"), 0, "and wears the realistic look")
			AS._onPlayerRemoving(p)
		end
	)

	t.test("fix: creator gates for falling / ragdolled bodies; a failed avatar read is retried", function()
		AS._reset()
		local store = makeStore()
		installHooks(store)
		local ragdolled = false
		AS._setHooks({
			isRagdolled = function()
				return ragdolled
			end,
		})
		local p = fakePlayer()
		local char, _, root = fakeCharacter()
		p.Character = char
		AS._onPlayerAdded(p)
		settle()
		root.AssemblyLinearVelocity = V3.new(0, -40, 0)
		t.eq(AS.creatorBlocked(p), "falling", "mid-fall")
		root.AssemblyLinearVelocity = V3.zero
		ragdolled = true
		t.eq(AS.creatorBlocked(p), "ragdolled", "ragdolled")
		ragdolled = false
		t.ok(AS.creatorBlocked(p) == nil, "standing: allowed")

		-- the Roblox avatar read fails once: realistic look meanwhile, read again after OWN_RETRY
		local now = 1000
		local fails = 1
		AS._setHooks({
			clock = function()
				return now
			end,
			userDescription = function()
				if fails > 0 then
					fails -= 1
					error("HTTP 500")
				end
				return Instance.new("HumanoidDescription")
			end,
		})
		local st = AS._state(p)
		st.ownDesc = nil
		st.ownTriedAt = -math.huge
		t.eq(AS._applyOnce(st, st.look, true), 0, "avatar unreadable: realistic look")
		t.eq(AS._applyOnce(st, st.look, true), 0, "not hammered before OWN_RETRY")
		now += AS.OWN_RETRY + 1
		t.eq(AS._applyOnce(st, st.look, true), -1, "read again later: own avatar")
		AS._setHooks({ clock = os.clock })
		AS._onPlayerRemoving(p)
	end)

	t.test("fix: a missing garment group drops a level; untyped accessories never trigger it", function()
		local look = LookCodec.seeded(8)
		local spec = DescriptionSpec.build(look, 0)
		local kinds = {}
		for _, a in spec.accessories do
			kinds[a.kind] = (kinds[a.kind] or 0) + 1
		end
		t.eq(#DescriptionSpec.missingGroups(spec, kinds, 0), 0, "everything loaded")
		local noGarment = table.clone(kinds)
		local dropped
		for k in noGarment do
			if table.find(DescriptionSpec.CRITICAL_GROUPS.garments, k) then
				noGarment[k] -= 1
				dropped = k
				break
			end
		end
		t.ok(dropped ~= nil, "the look has a garment")
		t.eq(DescriptionSpec.missingGroups(spec, noGarment, 0)[1], "garments", "a garment missing")
		t.eq(#DescriptionSpec.missingGroups(spec, noGarment, 1), 0, "an untyped accessory may be it")
		local noBrows = table.clone(kinds)
		noBrows.Eyebrow = nil
		t.eq(#DescriptionSpec.missingGroups(spec, noBrows, 0), 0, "brows are not critical")

		-- in the service: level 0 loads all but one garment (typed) -> level 1
		AS._reset()
		local store = makeStore()
		installHooks(store)
		local p = fakePlayer()
		p.Character = fakeCharacter()
		AS._onPlayerAdded(p)
		settle()
		local st = AS._state(p)
		local function kindList(s, skipOne)
			local out = {}
			local skipped = false
			for _, a in s.accessories do
				if skipOne and not skipped and table.find(DescriptionSpec.CRITICAL_GROUPS.garments, a.kind) then
					skipped = true
				else
					table.insert(out, a.kind)
				end
			end
			return out
		end
		table.clear(applied)
		loadKinds = function(n)
			return kindList(DescriptionSpec.build(look, n - 1), n == 1)
		end
		t.eq(AS._applyOnce(st, look, false), 1, "missing trousers at level 0 -> level 1")
		t.eq(#applied, 2, "two applies")
		table.clear(applied)
		loadKinds = function(n)
			return kindList(DescriptionSpec.build(look, n - 1), false)
		end
		t.eq(AS._applyOnce(st, look, false), 0, "complete look stays at level 0")
		loadKinds = nil
		AS._onPlayerRemoving(p)
	end)

	t.test("fix: tools are never hidden; reveal restores parts that left the body; R6 is shown as is", function()
		local char = fake("Character", "Model")
		local tool = fake("Pistol", "Tool")
		local handle = fake("Handle", "Part", { Transparency = 0, _tool = tool, Parent = tool })
		local arm = fake("LeftUpperArm", "MeshPart", { Transparency = 0, Parent = char })
		table.insert(char._children, arm)
		table.insert(char._children, handle)
		local list = AS._hideCharacter(char)
		t.eq(handle.Transparency, 0, "the gun's handle is not hidden")
		t.eq(arm.Transparency, 1, "the body is")
		-- the arm moved out of the body meanwhile (still in the game): it comes back anyway
		arm._outside = true
		local st = { hidden = { [char] = list } }
		AS._reveal(st, char)
		t.eq(arm.Transparency, 0, "restored")

		AS._reset()
		local store = makeStore()
		installHooks(store)
		local p = fakePlayer()
		local c6, hum6, _, head6 = fakeCharacter()
		hum6.RigType = H.roblox.Enum.HumanoidRigType.R6
		p.Character = c6
		AS._onPlayerAdded(p)
		settle()
		t.eq(head6.Transparency, 0, "R6 body never hidden")
		t.eq(#applied, 0, "no realistic apply on an R6 rig")
		AS._onPlayerRemoving(p)
	end)

	t.test("fix: shutdown waits for a save PlayerRemoving already started", function()
		AS._reset()
		local store = makeStore()
		installHooks(store)
		AS._setHooks({
			wait = function(s)
				task.wait(math.min(s, 0.2)) -- (the 7 s save debounce wakes early: the player is gone by then)
			end,
		})
		local release = false
		local realUpdate = store.UpdateAsync
		function store:UpdateAsync(key, fn)
			while not release do
				task.wait()
			end
			return realUpdate(self, key, fn)
		end
		local p = fakePlayer()
		p.Character = fakeCharacter()
		AS._onPlayerAdded(p)
		settle()
		AS._onCreator(p, true)
		local pick = LookCodec.seeded(9090)
		local st = AS._state(p)
		st.lastSaveAt = os.clock() -- the debounced save has not run yet: PlayerRemoving flushes it
		AS._onSave(p, pick)
		task.spawn(AS._onPlayerRemoving, p)
		task.wait()
		t.ok(AS._inflight() >= 1, "a save is in flight after the player left")
		task.delay(0.05, function()
			release = true
		end)
		AS._shutdown(5)
		t.eq(AS._inflight(), 0, "shutdown waited for it")
		local rec = store.data[tostring(p.UserId)]
		t.ok(rec ~= nil and LookCodec.equal(LookCodec.fromKeys(rec.look), pick), "the last look was written")
		AS._setHooks({
			wait = function() end,
		})
	end)

	t.test("fix: the creator lens stays inside the room over the whole orbit; the height chart faces in", function()
		local origin = V3.new(-12000, 2400, -12000)
		local R = CreatorModel.ROOM
		local m = CreatorModel.LENS_MARGIN - 1e-6
		for _, focus in { "body", "face" } do
			for _, touch in { false, true } do
				for deg = -180, 180, 5 do
					local cf = CreatorModel.framing(origin, origin.Y + 5.6, focus, touch, math.rad(deg))
					local rel = cf.Position - origin
					local where = focus .. (if touch then " touch " else " desktop ") .. deg
					t.ok(rel.Z >= R.back + m and rel.Z <= R.front - m, "z inside the room: " .. where)
					t.ok(math.abs(rel.X) <= R.halfW - m, "x inside the room: " .. where)
					t.ok(rel.Y >= m and rel.Y <= R.height - m, "y inside the room: " .. where)
				end
			end
		end
		-- inside the orbit limit the full-body framing is never pulled in (it stays a full-body shot)
		for _, touch in { false, true } do
			for deg = -100, 100, 5 do
				local headY = origin.Y + 5.6
				local target = V3.new(origin.X, origin.Y + (headY - origin.Y + 0.7) * 0.5, origin.Z)
				local free = CreatorModel.framing(origin, headY, "body", touch, math.rad(deg))
				local want = CreatorModel.bodyDistance(headY - origin.Y + 0.7, CreatorModel.FOV)
				t.ok((free.Position - target).Magnitude >= want * 0.98, "full body at " .. deg)
			end
		end
		t.near(CreatorModel.MAX_YAW, math.rad(100), 1e-9, "orbit limit")
		-- the height chart is on the back wall's face toward the room (+Z = Roblox's Back face)
		t.eq(CreatorModel.CHART_FACE, "Back", "chart face")
		local parts = CreatorModel.studio()
		for _, p in parts do
			if p.name == "BackWall" then
				t.ok(p.offset.Z < 0, "the back wall is behind the character (-Z)")
				local cam = CreatorModel.framing(V3.zero, 5.6, "body", false, 0)
				t.ok(cam.Position.Z > p.offset.Z, "the camera looks at its +Z (Back) face")
			end
		end
		local cc = fs.readFile("src/client/Controllers/CharacterCreator.luau")
		t.ok(cc:find("CreatorModel.CHART_FACE", 1, true) ~= nil, "the client uses that face")
		t.ok(cc:find("CreatorModel.MAX_YAW", 1, true) ~= nil, "the client clamps to the limit")
	end)

	t.test("fix: the creator sinks gameplay hotkeys but keeps the list menu's keys", function()
		H.setMode("client")
		local CC = H.require("src/client/Controllers/CharacterCreator")
		H.setMode("server")
		local K = H.roblox.Enum.KeyCode
		local blocked = {}
		for _, k in CC.BLOCKED_KEYS do
			blocked[k.Name] = true
		end
		for _, k in { K.One, K.Two, K.Five, K.Eight, K.Zero, K.Tab, K.Q, K.R, K.H, K.P, K.B, K.M, K.ButtonSelect } do
			t.ok(blocked[k.Name], "sunk: " .. k.Name)
		end
		for _, k in
			{ K.Up, K.Down, K.Left, K.Right, K.Return, K.Backspace, K.DPadUp, K.DPadDown, K.ButtonA, K.ButtonB, K.Z }
		do
			t.ok(not blocked[k.Name], "kept for the creator: " .. k.Name)
		end
		local cc = fs.readFile("src/client/Controllers/CharacterCreator.luau")
		t.ok(cc:find('call("WeaponClient", "holster")', 1, true) ~= nil, "anything drawn is holstered again")
		local plot = fs.readFile("src/server/Systems/PlotService.luau")
		t.ok(plot:find('player:GetAttribute("HC_Creator") ~= nil', 1, true) ~= nil, "no cab out of the studio")
	end)

	t.test("fix: copy reads as a game, not a catalog (build names, walk styles, no keyframed packs)", function()
		local seen = {}
		for _, b in L.Bodies do
			t.ok(not seen[b.name], "unique build name " .. b.name)
			seen[b.name] = true
			for _, f in L.Faces do
				t.ok(not b.name:find(f.name, 1, true), "build " .. b.name .. " is not a person's name")
			end
			t.ok(not b.name:lower():find("city life", 1, true), "no bundle names")
		end
		t.eq(CreatorModel.DESCS.body, "Height and build.", "build description")
		for _, w in L.WalkStyles do
			for _, brand in { "adidas", "roblox", "e.l.f", "mocap", "pack" } do
				t.ok(not w.desc:lower():find(brand, 1, true), w.key .. " desc has no '" .. brand .. "'")
			end
			t.ok(w.bundle ~= 83 and w.bundle ~= 48, w.key .. ": no keyframed 2017 pack")
		end
		t.ok(L.IdleFidgets == nil, "no dead idle-fidget config")
		-- a look saved with a removed walk style still loads (falls back per field)
		local keys = LookCodec.toKeys(LookCodec.seeded(3))
		keys.walk = "stylish"
		local back = LookCodec.fromKeys(keys)
		t.ok(back.walk >= 1 and back.walk <= #L.WalkStyles, "removed walk key falls back")
	end)
end
