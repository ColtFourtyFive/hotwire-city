--!strict
-- DescriptionSpec (C4a characters): a Look (Appearance/LookCodec) -> the plain data of a HumanoidDescription, pure and
-- deterministic. AppearanceService turns a Spec into the real HumanoidDescription (toDescription) and applies it with
-- Humanoid:ApplyDescriptionAsync; the tests and tools/characters read the same Spec.
--
-- Fallback levels (PlayerLooks rules: every slot has a fallback):
--   0  the look as chosen
--   1  every garment, the hair and the shoes on their Roblox-made fallback, the walk style on PlayerLooks.ANIM_FALLBACK
--      (used when level 0 fails to apply: an item went off sale, was deleted or failed to load)
--   2  SAFE: the Base Body's own tank top and shorts on the SAFE body and face, white sneakers, no hair, the Rthro
--      animation set (PlayerLooks.ANIM_SAFE); only the skin tone is kept
--
-- Own-avatar mode ("Use my Roblox avatar") keeps the player's own HumanoidDescription; `ownOverrides` gives what we
-- still force on it: the realistic walk style (animations), no emotes and scales clamped into a fair range.

local PlayerLooks = require(script.Parent.Parent.Config.PlayerLooks)
local LookCodec = require(script.Parent.LookCodec)

local DescriptionSpec = {}

export type AccessorySpec = { id: number, kind: string, layered: boolean, order: number }

export type Anims = {
	idle: number,
	walk: number,
	run: number,
	jump: number,
	fall: number,
	climb: number,
	swim: number,
}

export type Scales = {
	height: number,
	width: number,
	depth: number,
	head: number,
	bodyType: number,
	proportion: number,
}

export type Spec = {
	level: number,
	head: number,
	torso: number,
	leftArm: number,
	rightArm: number,
	leftLeg: number,
	rightLeg: number,
	mood: number,
	skin: Color3,
	scales: Scales,
	accessories: { AccessorySpec },
	anims: Anims,
	-- classic slots we always clear (no 2D shirts, no decal face, no emotes)
	face: number,
	shirt: number,
	pants: number,
	graphicTShirt: number,
}

DescriptionSpec.MAX_LEVEL = 2

-- Fair-play clamps for own-avatar mode (hitboxes and silhouettes stay close to the realistic bodies).
DescriptionSpec.OWN_CLAMP = {
	height = { 0.95, 1.1 },
	width = { 0.75, 1.0 },
	depth = { 0.8, 1.0 },
	head = { 0.95, 1.0 },
	bodyType = { 0, 1 },
	proportion = { 0, 1 },
}

local function orderOf(kind: string): number
	return PlayerLooks.LAYER_ORDER[kind] or 8
end

local function layered(id: number, kind: string): AccessorySpec
	return { id = id, kind = kind, layered = true, order = orderOf(kind) }
end

local function animsOf(pack: PlayerLooks.AnimPack): Anims
	return {
		idle = pack.idle,
		walk = pack.walk,
		run = pack.run,
		jump = pack.jump,
		fall = pack.fall,
		climb = pack.climb,
		swim = pack.swim,
	}
end

local function packByKey(key: string): PlayerLooks.AnimPack?
	for _, p in PlayerLooks.WalkStyles do
		if p.key == key then
			return p
		end
	end
	if PlayerLooks.ANIM_SAFE.key == key then
		return PlayerLooks.ANIM_SAFE
	end
	return nil
end

local function bodyByKey(key: string): PlayerLooks.Body
	for _, b in PlayerLooks.Bodies do
		if b.key == key then
			return b
		end
	end
	return PlayerLooks.Bodies[1]
end

local function faceByKey(key: string): PlayerLooks.Face
	for _, f in PlayerLooks.Faces do
		if f.key == key then
			return f
		end
	end
	return PlayerLooks.Faces[1]
end

local function hairStyleByKey(key: string): PlayerLooks.HairStyle?
	for _, h in PlayerLooks.HairStyles do
		if h.key == key then
			return h
		end
	end
	return nil
end

-- The hair accessory id for a style + colour index (nil for a shaved head or an unknown colour).
function DescriptionSpec.hairId(style: PlayerLooks.HairStyle, colorIndex: number): number?
	local ids = style.ids
	local color = PlayerLooks.HairColors[colorIndex]
	if not ids or not color then
		return nil
	end
	return ids[color.key]
end

local function shoesOf(key: string): PlayerLooks.Shoes
	return PlayerLooks.Shoes[key] or PlayerLooks.Shoes[PlayerLooks.SHOES_FALLBACK]
end

local function addShoes(out: { AccessorySpec }, shoes: PlayerLooks.Shoes)
	table.insert(out, layered(shoes.left, "LeftShoe"))
	table.insert(out, layered(shoes.right, "RightShoe"))
end

local function addFace(out: { AccessorySpec }, face: PlayerLooks.Face)
	if face.eyebrows then
		table.insert(out, layered(face.eyebrows, "Eyebrow"))
	end
	if face.eyelashes then
		table.insert(out, layered(face.eyelashes, "Eyelash"))
	end
end

local function scalesFor(body: PlayerLooks.Body): Scales
	return {
		height = PlayerLooks.HEIGHT_SCALE,
		width = body.width,
		depth = body.width,
		head = PlayerLooks.HEAD_SCALE,
		bodyType = 0,
		proportion = 0,
	}
end

-- The Spec for a look at a fallback level (0 = as chosen). Never fails: the look is sanitized first.
function DescriptionSpec.build(look: LookCodec.Look, level: number?): Spec
	local l = LookCodec.sanitize(look)
	local lvl = math.clamp(math.floor(level or 0), 0, DescriptionSpec.MAX_LEVEL)
	local skin = PlayerLooks.SkinTones[l.skin].color
	local accessories: { AccessorySpec } = {}

	local body: PlayerLooks.Body
	local face: PlayerLooks.Face
	local anims: Anims
	if lvl >= 2 then
		local safe = PlayerLooks.SAFE
		body = bodyByKey(safe.body)
		face = faceByKey(safe.face)
		addFace(accessories, face)
		for _, gmt in safe.garments do
			table.insert(accessories, layered(gmt.id, gmt.kind))
		end
		addShoes(accessories, shoesOf(safe.shoes))
		anims = animsOf(PlayerLooks.ANIM_SAFE)
	else
		body = PlayerLooks.Bodies[l.body]
		face = PlayerLooks.Faces[l.face]
		addFace(accessories, face)
		-- hair
		local style = PlayerLooks.HairStyles[l.hair]
		local hair = DescriptionSpec.hairId(style, l.hairColor)
		if lvl >= 1 and hair ~= nil then
			local fb = hairStyleByKey(PlayerLooks.HAIR_FALLBACK_STYLE)
			hair = if fb then DescriptionSpec.hairId(fb, 1) else nil
		end
		if hair then
			table.insert(accessories, layered(hair, "Hair"))
		end
		-- clothes
		local variant = PlayerLooks.Outfits[l.outfit].variants[l.variant]
		for _, gmt in variant.garments do
			if lvl >= 1 and gmt.fallback then
				table.insert(accessories, layered(gmt.fallback.id, gmt.fallback.kind or gmt.kind))
			else
				table.insert(accessories, layered(gmt.id, gmt.kind))
			end
		end
		addShoes(accessories, shoesOf(if lvl >= 1 then PlayerLooks.SHOES_FALLBACK else variant.shoes))
		-- walk style
		local pack = PlayerLooks.WalkStyles[l.walk]
		if lvl >= 1 then
			pack = packByKey(PlayerLooks.ANIM_FALLBACK) or PlayerLooks.ANIM_SAFE
		end
		anims = animsOf(pack)
	end

	return {
		level = lvl,
		head = face.head,
		torso = body.parts.torso,
		leftArm = body.parts.leftArm,
		rightArm = body.parts.rightArm,
		leftLeg = body.parts.leftLeg,
		rightLeg = body.parts.rightLeg,
		mood = PlayerLooks.MOOD,
		skin = skin,
		scales = scalesFor(body),
		accessories = accessories,
		anims = anims,
		face = 0,
		shirt = 0,
		pants = 0,
		graphicTShirt = 0,
	}
end

-- Every asset id a Spec references (body parts, head, accessories, animations), for logging and the tests.
function DescriptionSpec.assetIds(spec: Spec): { number }
	local out = { spec.head, spec.torso, spec.leftArm, spec.rightArm, spec.leftLeg, spec.rightLeg }
	for _, a in spec.accessories do
		table.insert(out, a.id)
	end
	for _, k in { "idle", "walk", "run", "jump", "fall", "climb", "swim" } do
		table.insert(out, (spec.anims :: any)[k])
	end
	if spec.mood > 0 then
		table.insert(out, spec.mood)
	end
	return out
end

-- Own-avatar mode: what we force on the player's own description.
export type OwnOverrides = { anims: Anims, clamp: typeof(DescriptionSpec.OWN_CLAMP) }

function DescriptionSpec.ownOverrides(look: LookCodec.Look): OwnOverrides
	local l = LookCodec.sanitize(look)
	return { anims = animsOf(PlayerLooks.WalkStyles[l.walk]), clamp = DescriptionSpec.OWN_CLAMP }
end

-- Clamp one own-avatar scale value (non-numbers -> 1, or 0 for bodyType / proportion).
function DescriptionSpec.clampScale(name: string, value: any): number
	local range = (DescriptionSpec.OWN_CLAMP :: any)[name]
	local default = if name == "bodyType" or name == "proportion" then 0 else 1
	if typeof(value) ~= "number" or value ~= value then
		return default
	end
	if not range then
		return value
	end
	return math.clamp(value, range[1], range[2])
end

return DescriptionSpec
