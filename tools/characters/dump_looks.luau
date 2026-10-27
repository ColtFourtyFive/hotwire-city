--!nocheck
-- Dumps every catalog id in src/shared/Config/PlayerLooks.luau with the asset type it must have, for
-- tools/characters/verify_looks.py.  usage (repo root): lune run tools/characters/dump_looks.luau OUT.json

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Harness = require("../../tests/harness")

local L = Harness.require("src/shared/Config/PlayerLooks")

-- Roblox AssetType ids
local T = {
	Torso = 27,
	RightArm = 28,
	LeftArm = 29,
	LeftLeg = 30,
	RightLeg = 31,
	Hair = 41,
	Eyebrow = 76,
	Eyelash = 77,
	Mood = 78,
	DynamicHead = 79,
	TShirt = 64,
	Shirt = 65,
	Pants = 66,
	Jacket = 67,
	Sweater = 68,
	Shorts = 69,
	LeftShoe = 70,
	RightShoe = 71,
	DressSkirt = 72,
	Climb = 48,
	Fall = 50,
	Idle = 51,
	Jump = 52,
	Run = 53,
	Swim = 54,
	Walk = 55,
	Animation = 24,
	Emote = 61,
}

local out = {}
local seen = {}
local function add(id, typeName, role)
	if typeof(id) ~= "number" or id <= 0 then
		return
	end
	local key = tostring(id)
	if seen[key] then
		table.insert(seen[key].roles, role)
		return
	end
	local e = { id = id, type = T[typeName], typeName = typeName, roles = { role } }
	seen[key] = e
	table.insert(out, e)
end

for _, b in L.Bodies do
	add(b.parts.torso, "Torso", "body:" .. b.key)
	add(b.parts.leftArm, "LeftArm", "body:" .. b.key)
	add(b.parts.rightArm, "RightArm", "body:" .. b.key)
	add(b.parts.leftLeg, "LeftLeg", "body:" .. b.key)
	add(b.parts.rightLeg, "RightLeg", "body:" .. b.key)
end
for _, f in L.Faces do
	add(f.head, "DynamicHead", "face:" .. f.key)
	add(f.eyebrows, "Eyebrow", "face:" .. f.key)
	add(f.eyelashes, "Eyelash", "face:" .. f.key)
end
for _, h in L.HairStyles do
	if h.ids then
		for color, id in h.ids do
			add(id, "Hair", "hair:" .. h.key .. ":" .. color)
		end
	end
end
for key, s in L.Shoes do
	add(s.left, "LeftShoe", "shoes:" .. key)
	add(s.right, "RightShoe", "shoes:" .. key)
end
for _, o in L.Outfits do
	for _, v in o.variants do
		for _, gmt in v.garments do
			add(gmt.id, gmt.kind, "outfit:" .. v.key)
			if gmt.fallback then
				add(gmt.fallback.id, gmt.fallback.kind or gmt.kind, "fallback:" .. v.key)
			end
		end
	end
end
for _, gmt in L.SAFE.garments do
	add(gmt.id, gmt.kind, "safe")
end
local packs = table.clone(L.WalkStyles)
table.insert(packs, L.ANIM_SAFE)
for _, p in packs do
	for _, slot in { "idle", "walk", "run", "jump", "fall", "climb", "swim" } do
		local name = string.upper(string.sub(slot, 1, 1)) .. string.sub(slot, 2)
		add(p[slot], name, "anim:" .. p.key)
	end
end
for _, f in L.IdleFidgets or {} do
	add(f.anim, "Animation", "fidget:" .. f.key)
	add(f.emote, "Emote", "fidget-emote:" .. f.key)
end
if L.MOOD and L.MOOD > 0 then
	add(L.MOOD, "Mood", "mood")
end

fs.writeFile(process.args[1], serde.encode("json", out, true))
print(("dumped %d ids -> %s"):format(#out, process.args[1]))
