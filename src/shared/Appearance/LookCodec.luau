--!strict
-- LookCodec (C4a characters): a player's look in its three shapes, pure and deterministic (no Instances, no
-- services, no Random).
--
--   Look    1-based INDICES into Config/PlayerLooks lists: what the creator edits and the remotes carry. The server
--           re-validates every payload with LookCodec.validate (indices only, every field in range).
--   Keys    the same choice as list KEYS: what is persisted (HC_Appearance_v1), so reordering or extending
--           PlayerLooks never scrambles a saved look; an unknown key falls back to that field's default.
--   Record  the DataStore value: { v, look = Keys, own = "use my Roblox avatar", changedAt }.
--
-- Also: weighted random looks (an injectable 0..1 rng), a look seeded by userId (the same "random" look on every
-- server until the player saves their own), option labels / cycling for the creator rows, and the session-safe
-- merge rule for saves (a stored record changed later than ours wins).

local PlayerLooks = require(script.Parent.Parent.Config.PlayerLooks)

local LookCodec = {}

export type Look = {
	body: number,
	face: number,
	skin: number,
	hair: number,
	hairColor: number,
	outfit: number,
	variant: number,
	walk: number,
}

export type Keys = {
	body: string,
	face: string,
	skin: string,
	hair: string,
	hairColor: string,
	outfit: string,
	variant: string,
	walk: string,
}

export type Record = { v: number, look: Keys, own: boolean, changedAt: number }

LookCodec.RECORD_VERSION = 1

-- Creator row order.
LookCodec.FIELDS = { "body", "face", "skin", "hair", "hairColor", "outfit", "variant", "walk" }

local FIELD_SET: { [string]: boolean } = {}
for _, f in LookCodec.FIELDS do
	FIELD_SET[f] = true
end

-------------------------------------------------------------------------------------------------------------------------
-- Lists
-------------------------------------------------------------------------------------------------------------------------

local function listFor(field: string, outfit: number?): { any }
	if field == "body" then
		return PlayerLooks.Bodies
	elseif field == "face" then
		return PlayerLooks.Faces
	elseif field == "skin" then
		return PlayerLooks.SkinTones
	elseif field == "hair" then
		return PlayerLooks.HairStyles
	elseif field == "hairColor" then
		return PlayerLooks.HairColors
	elseif field == "outfit" then
		return PlayerLooks.Outfits
	elseif field == "variant" then
		local o = PlayerLooks.Outfits[outfit or 1] or PlayerLooks.Outfits[1]
		return o.variants
	elseif field == "walk" then
		return PlayerLooks.WalkStyles
	end
	return {}
end
LookCodec.listFor = listFor

-- Number of choices for a field (variant depends on the outfit).
function LookCodec.count(field: string, outfit: number?): number
	return #listFor(field, outfit)
end

local function isIndex(v: any, n: number): boolean
	return typeof(v) == "number" and v == v and v % 1 == 0 and v >= 1 and v <= n
end

-------------------------------------------------------------------------------------------------------------------------
-- Defaults / validation
-------------------------------------------------------------------------------------------------------------------------

function LookCodec.default(): Look
	return { body = 1, face = 1, skin = 4, hair = 1, hairColor = 1, outfit = 1, variant = 1, walk = 1 }
end

function LookCodec.copy(look: Look): Look
	return {
		body = look.body,
		face = look.face,
		skin = look.skin,
		hair = look.hair,
		hairColor = look.hairColor,
		outfit = look.outfit,
		variant = look.variant,
		walk = look.walk,
	}
end

-- Validates an UNTRUSTED payload (a remote argument): a plain table holding exactly the known fields, each an
-- integer index in range (variant within its outfit). Returns a fresh Look, or nil and why.
function LookCodec.validate(payload: any): (Look?, string?)
	if typeof(payload) ~= "table" then
		return nil, "not a table"
	end
	if getmetatable(payload) ~= nil then
		return nil, "metatable"
	end
	local n = 0
	for k in payload do
		n += 1
		if n > #LookCodec.FIELDS or typeof(k) ~= "string" or not FIELD_SET[k] then
			return nil, "unexpected field"
		end
	end
	local out: { [string]: number } = {}
	for _, f in LookCodec.FIELDS do
		local v = payload[f]
		local limit = if f == "variant" then LookCodec.count("variant", payload.outfit) else LookCodec.count(f)
		if f == "variant" and not isIndex(payload.outfit, LookCodec.count("outfit")) then
			return nil, "bad outfit"
		end
		if not isIndex(v, limit) then
			return nil, "bad " .. f
		end
		out[f] = v
	end
	return (out :: any) :: Look, nil
end

-- Clamps anything look-shaped into a valid Look (never fails; for server-internal data).
function LookCodec.sanitize(look: any): Look
	local d = LookCodec.default()
	if typeof(look) ~= "table" then
		return d
	end
	local out = LookCodec.copy(d)
	for _, f in LookCodec.FIELDS do
		local v = look[f]
		local limit = if f == "variant" then LookCodec.count("variant", out.outfit) else LookCodec.count(f)
		if isIndex(v, limit) then
			(out :: any)[f] = v
		end
	end
	return out
end

function LookCodec.equal(a: Look, b: Look): boolean
	for _, f in LookCodec.FIELDS do
		if (a :: any)[f] ~= (b :: any)[f] then
			return false
		end
	end
	return true
end

-- Canonical string ("1.4.3...") for change detection and logs.
function LookCodec.key(look: Look): string
	local parts = table.create(#LookCodec.FIELDS)
	for i, f in LookCodec.FIELDS do
		parts[i] = tostring((look :: any)[f])
	end
	return table.concat(parts, ".")
end

-- The inverse of `key` (the replicated "HC_Look" player attribute): a validated Look, or nil for anything malformed.
function LookCodec.parseKey(s: any): Look?
	if typeof(s) ~= "string" or #s > 64 then
		return nil
	end
	local parts = string.split(s, ".")
	if #parts ~= #LookCodec.FIELDS then
		return nil
	end
	local payload: { [string]: number } = {}
	for i, f in LookCodec.FIELDS do
		local n = tonumber(parts[i])
		if n == nil then
			return nil
		end
		payload[f] = n
	end
	local look = LookCodec.validate(payload)
	return look
end

-------------------------------------------------------------------------------------------------------------------------
-- Keys <-> indices
-------------------------------------------------------------------------------------------------------------------------

local function indexOfKey(list: { any }, key: any): number?
	if typeof(key) ~= "string" then
		return nil
	end
	for i, e in list do
		if e.key == key then
			return i
		end
	end
	return nil
end

function LookCodec.toKeys(look: Look): Keys
	local l = LookCodec.sanitize(look)
	return {
		body = PlayerLooks.Bodies[l.body].key,
		face = PlayerLooks.Faces[l.face].key,
		skin = PlayerLooks.SkinTones[l.skin].key,
		hair = PlayerLooks.HairStyles[l.hair].key,
		hairColor = PlayerLooks.HairColors[l.hairColor].key,
		outfit = PlayerLooks.Outfits[l.outfit].key,
		variant = PlayerLooks.Outfits[l.outfit].variants[l.variant].key,
		walk = PlayerLooks.WalkStyles[l.walk].key,
	}
end

-- Unknown / missing keys keep that field's default (a removed item never breaks a saved look).
function LookCodec.fromKeys(keys: any): Look
	local out = LookCodec.default()
	if typeof(keys) ~= "table" then
		return out
	end
	local function pick(field: string, list: { any })
		local i = indexOfKey(list, keys[field])
		if i then
			(out :: any)[field] = i
		end
	end
	pick("body", PlayerLooks.Bodies)
	pick("face", PlayerLooks.Faces)
	pick("skin", PlayerLooks.SkinTones)
	pick("hair", PlayerLooks.HairStyles)
	pick("hairColor", PlayerLooks.HairColors)
	pick("outfit", PlayerLooks.Outfits)
	pick("walk", PlayerLooks.WalkStyles)
	local vi = indexOfKey(PlayerLooks.Outfits[out.outfit].variants, keys.variant)
	out.variant = vi or 1
	return out
end

-------------------------------------------------------------------------------------------------------------------------
-- Random looks
-------------------------------------------------------------------------------------------------------------------------

export type Rng = () -> number -- uniform in [0, 1)

-- Deterministic generator (Park-Miller) so a seeded look is identical on the server, the client and in Lune.
function LookCodec.rng(seed: number): Rng
	local s = math.floor(math.abs(seed)) % 2147483646 + 1
	return function(): number
		s = (s * 48271) % 2147483647
		return (s - 1) / 2147483646
	end
end

local function weighted(list: { any }, r: number, weightOf: ((any) -> number)?): number
	local total = 0
	for _, e in list do
		total += math.max(0, if weightOf then weightOf(e) else (e.weight or 1))
	end
	if total <= 0 then
		return math.clamp(math.floor(r * #list) + 1, 1, #list)
	end
	local target = r * total
	local acc = 0
	for i, e in list do
		acc += math.max(0, if weightOf then weightOf(e) else (e.weight or 1))
		if target < acc then
			return i
		end
	end
	return #list
end
LookCodec._weighted = weighted

-- A realistic random look: the body by weight, a face that suits the frame, any skin tone, hair by weight (the
-- colour by its own weights), any outfit and variant, a walk style by weight (0-weight styles never rolled).
function LookCodec.random(rng: Rng): Look
	local body = weighted(PlayerLooks.Bodies, rng())
	local frame = PlayerLooks.Bodies[body]
	local faceKey = frame.faces[math.clamp(math.floor(rng() * #frame.faces) + 1, 1, #frame.faces)]
	local face = indexOfKey(PlayerLooks.Faces, faceKey) or 1
	local skin = math.clamp(math.floor(rng() * #PlayerLooks.SkinTones) + 1, 1, #PlayerLooks.SkinTones)
	local hair = weighted(PlayerLooks.HairStyles, rng())
	local hairColor = weighted(PlayerLooks.HairColors, rng())
	local outfit = math.clamp(math.floor(rng() * #PlayerLooks.Outfits) + 1, 1, #PlayerLooks.Outfits)
	local nv = #PlayerLooks.Outfits[outfit].variants
	local variant = math.clamp(math.floor(rng() * nv) + 1, 1, nv)
	local walk = weighted(PlayerLooks.WalkStyles, rng())
	return {
		body = body,
		face = face,
		skin = skin,
		hair = hair,
		hairColor = hairColor,
		outfit = outfit,
		variant = variant,
		walk = walk,
	}
end

-- The look a player wears before saving one: random, but the same for that userId everywhere.
function LookCodec.seeded(userId: number): Look
	local rng = LookCodec.rng(userId * 7919 + 104729)
	rng() -- decorrelate small seeds
	return LookCodec.random(rng)
end

-------------------------------------------------------------------------------------------------------------------------
-- Creator helpers
-------------------------------------------------------------------------------------------------------------------------

-- Display names of a field's options (variant names depend on the outfit).
function LookCodec.options(field: string, look: Look?): { string }
	local list = listFor(field, if look then look.outfit else nil)
	local out = table.create(#list)
	for i, e in list do
		out[i] = e.name
	end
	return out
end

-- A copy of `look` with `field` set to `index`; changing the outfit resets the variant to its first entry.
function LookCodec.set(look: Look, field: string, index: number): Look
	local out = LookCodec.copy(look)
	if not FIELD_SET[field] then
		return out
	end
	(out :: any)[field] = index
	if field == "outfit" then
		out.variant = 1
	end
	return LookCodec.sanitize(out)
end

-------------------------------------------------------------------------------------------------------------------------
-- Records (DataStore HC_Appearance_v1)
-------------------------------------------------------------------------------------------------------------------------

function LookCodec.encodeRecord(look: Look, own: boolean, changedAt: number): Record
	return { v = LookCodec.RECORD_VERSION, look = LookCodec.toKeys(look), own = own == true, changedAt = changedAt }
end

-- A stored value -> (Record, Look). nil when absent or unusable (a first-time player).
function LookCodec.decodeRecord(raw: any): (Record?, Look?)
	if typeof(raw) ~= "table" or typeof(raw.look) ~= "table" then
		return nil, nil
	end
	local look = LookCodec.fromKeys(raw.look)
	local changedAt = if typeof(raw.changedAt) == "number" and raw.changedAt == raw.changedAt then raw.changedAt else 0
	local rec: Record = {
		v = if typeof(raw.v) == "number" then raw.v else LookCodec.RECORD_VERSION,
		look = LookCodec.toKeys(look),
		own = raw.own == true,
		changedAt = changedAt,
	}
	return rec, look
end

-- Session-safe save rule (UpdateAsync transform): keep the stored record when it was changed after ours (the player
-- changed their look on another server in the meantime).
function LookCodec.storedIsNewer(stored: any, mine: Record): boolean
	return typeof(stored) == "table"
		and typeof(stored.changedAt) == "number"
		and stored.changedAt == stored.changedAt
		and stored.changedAt > mine.changedAt
end

-- The record to write when this server never read the stored look (its load failed) and the player only flipped the
-- own-avatar switch: the stored look (its raw keys, as written) is kept and only `own` / `changedAt` change. nil =
-- keep the stored record untouched (it is newer). Nothing usable stored -> `mine`.
function LookCodec.mergeOwn(stored: any, mine: Record): Record?
	if LookCodec.storedIsNewer(stored, mine) then
		return nil
	end
	if typeof(stored) ~= "table" or typeof(stored.look) ~= "table" then
		return mine
	end
	return {
		v = if typeof(stored.v) == "number" then stored.v else LookCodec.RECORD_VERSION,
		look = table.clone(stored.look),
		own = mine.own,
		changedAt = mine.changedAt,
	}
end

return LookCodec
