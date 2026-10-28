--!nocheck
-- Dumps what the real-engine check (tools/characters/cloud_looks.py) and the lineup sheet (lineup.py) need, from the
-- same pure modules the game uses (Config/PlayerLooks, Appearance/LookCodec, Appearance/DescriptionSpec):
--   items    every accessory id a look can wear (kind, layered, order, roles)
--   bodies   body part sets, faces (dynamic heads), walk styles (animation sets)
--   lineup   8 generated looks chosen for variety (every outfit style, different skin tones / bodies / hair), with
--            their level-0 HumanoidDescription spec and the item names, plus the level 1 / 2 fallbacks of the first
-- usage (repo root): lune run tools/characters/dump_specs.luau OUT.json

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Harness = require("../../tests/harness")

local L = Harness.require("src/shared/Config/PlayerLooks")
local LookCodec = Harness.require("src/shared/Appearance/LookCodec")
local DescriptionSpec = Harness.require("src/shared/Appearance/DescriptionSpec")

local function color(c)
	return { math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5) }
end

local function specJson(spec)
	local acc = {}
	for _, a in spec.accessories do
		table.insert(acc, { id = a.id, kind = a.kind, layered = a.layered, order = a.order })
	end
	return {
		level = spec.level,
		head = spec.head,
		torso = spec.torso,
		leftArm = spec.leftArm,
		rightArm = spec.rightArm,
		leftLeg = spec.leftLeg,
		rightLeg = spec.rightLeg,
		mood = spec.mood,
		skin = color(spec.skin),
		scales = spec.scales,
		accessories = acc,
		anims = spec.anims,
	}
end

-- every accessory (and its kind) any look can produce, levels 0..2
local items, seen = {}, {}
local function addItem(a, role)
	local k = tostring(a.id)
	if seen[k] then
		if #seen[k].roles < 6 then
			table.insert(seen[k].roles, role)
		end
		return
	end
	local e = { id = a.id, kind = a.kind, layered = a.layered, order = a.order, roles = { role } }
	seen[k] = e
	table.insert(items, e)
end
for oi, o in L.Outfits do
	for vi in o.variants do
		for level = 0, 2 do
			local look = LookCodec.default()
			look.outfit = oi
			look.variant = vi
			local spec = DescriptionSpec.build(look, level)
			for _, a in spec.accessories do
				addItem(a, o.variants[vi].key .. "@" .. level)
			end
		end
	end
end
for hi, h in L.HairStyles do
	for ci, c in L.HairColors do
		local look = LookCodec.default()
		look.hair = hi
		look.hairColor = ci
		local id = h.ids and DescriptionSpec.hairId(h, ci)
		if id then
			addItem({ id = id, kind = "Hair", layered = true, order = L.LAYER_ORDER.Hair }, "hair:" .. h.key .. ":" .. c.key)
		end
	end
end
for _, f in L.Faces do
	if f.eyebrows then
		addItem({ id = f.eyebrows, kind = "Eyebrow", layered = true, order = L.LAYER_ORDER.Eyebrow }, "face:" .. f.key)
	end
	if f.eyelashes then
		addItem({ id = f.eyelashes, kind = "Eyelash", layered = true, order = L.LAYER_ORDER.Eyelash }, "face:" .. f.key)
	end
end
for key, s in L.Shoes do
	addItem({ id = s.left, kind = "LeftShoe", layered = true, order = L.LAYER_ORDER.LeftShoe }, "shoes:" .. key)
	addItem({ id = s.right, kind = "RightShoe", layered = true, order = L.LAYER_ORDER.RightShoe }, "shoes:" .. key)
end

local bodies = {}
for _, b in L.Bodies do
	table.insert(bodies, { key = b.key, bundle = b.bundle, parts = b.parts })
end
local faces = {}
for _, f in L.Faces do
	table.insert(faces, { key = f.key, bundle = f.bundle, head = f.head })
end
local anims = {}
local packs = table.clone(L.WalkStyles)
table.insert(packs, L.ANIM_SAFE)
for _, p in packs do
	table.insert(anims, {
		key = p.key,
		idle = p.idle,
		walk = p.walk,
		run = p.run,
		jump = p.jump,
		fall = p.fall,
		climb = p.climb,
		swim = p.swim,
	})
end

-- 8 varied looks: greedy over a fixed seed sequence (deterministic)
local lineup = {}
local usedSkin, usedBody, usedHair, styleCount, usedVariant = {}, {}, {}, {}, {}
local seed = 0
while #lineup < 8 and seed < 20000 do
	seed += 1
	local look = LookCodec.seeded(seed * 7 + 3)
	local style = L.Outfits[look.outfit].key
	local variant = L.Outfits[look.outfit].variants[look.variant].key
	local wantStyle = (styleCount[style] or 0) < (if #lineup < 5 then 1 else 2)
	local ok = wantStyle
		and not usedSkin[look.skin]
		and not usedBody[look.body]
		and not usedHair[look.hair]
		and not usedVariant[variant]
		and L.HairStyles[look.hair].ids ~= nil -- show hair on the sheet
	if ok then
		usedSkin[look.skin] = true
		usedBody[look.body] = true
		usedHair[look.hair] = true
		usedVariant[variant] = true
		styleCount[style] = (styleCount[style] or 0) + 1
		local spec = DescriptionSpec.build(look, 0)
		local outfit = L.Outfits[look.outfit]
		table.insert(lineup, {
			seed = seed * 7 + 3,
			key = LookCodec.key(look),
			keys = LookCodec.toKeys(look),
			labels = {
				body = L.Bodies[look.body].name,
				face = L.Faces[look.face].name,
				skin = L.SkinTones[look.skin].name,
				hair = L.HairStyles[look.hair].name,
				hairColor = L.HairColors[look.hairColor].name,
				outfit = outfit.name,
				variant = outfit.variants[look.variant].name,
				walk = L.WalkStyles[look.walk].name,
			},
			bodyBundle = L.Bodies[look.body].bundle,
			spec = specJson(spec),
		})
	end
end

local fallbacks = {}
if lineup[1] then
	local look = LookCodec.parseKey(lineup[1].key)
	for level = 1, 2 do
		table.insert(fallbacks, specJson(DescriptionSpec.build(look, level)))
	end
end

local out = {
	items = items,
	bodies = bodies,
	faces = faces,
	anims = anims,
	lineup = lineup,
	fallbacks = fallbacks,
	heightScale = L.HEIGHT_SCALE,
}
fs.writeFile(process.args[1], serde.encode("json", out, true))
print(
	("dumped %d accessories, %d bodies, %d faces, %d walk styles, %d lineup looks -> %s"):format(
		#items,
		#bodies,
		#faces,
		#anims,
		#lineup,
		process.args[1]
	)
)
