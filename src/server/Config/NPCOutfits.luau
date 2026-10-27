--!strict
-- NPC outfits (server-only: ServerScriptService.Server.Config.NPCOutfits), used by Systems/NPCService.
--
-- Roles / Pool are baked from assets/curation/vehicles-characters-props.json (roles "npc_*"); the "npc_" prefix is
-- dropped from the keys. Every catalog item is routed by its assetType: 11 Shirt / 12 Pants (classic clothing ids ->
-- HumanoidDescription.Shirt / .Pants), 8 HatAccessory / 41 HairAccessory / 42 FaceAccessory (comma-separated id
-- lists on the HumanoidDescription). An alternate is a partial outfit merged over its base (fields it names replace
-- the base's). tests/spec/npc.spec.luau re-parses the JSON with fromCuration() and asserts it equals this table, so
-- re-curating means regenerating the baked data below.
--
-- Looks: flat colors for the procedural R15 rig NPCService builds when the avatar catalog can't load (Lune harness,
-- asset outages) so every NPC still reads as its role.

local NPCOutfits = {}

export type Outfit = {
	name: string,
	Shirt: number,
	Pants: number,
	HatAccessory: { number },
	HairAccessory: { number },
	FaceAccessory: { number },
	alternates: { Outfit }?,
}

export type Pool = {
	hair: { number },
	hats: { number },
	face: { number },
	extraShirts: { number },
	hatsWithHair: { number }, -- hats that already include hair: never paired with a separate hair accessory
}

-- Values for HumanoidDescription (accessory lists already comma-joined).
export type DescriptionFields = {
	Shirt: number,
	Pants: number,
	HatAccessory: string,
	HairAccessory: string,
	FaceAccessory: string,
}

-- Procedural rig look. hat: "cap" | "police" | "toque" | "fedora" | "paper" | "straw" | "none"; hair: "short" |
-- "long" | "spiky" | "none".
export type Look = {
	shirt: Color3,
	pants: Color3,
	shoes: Color3,
	hat: string,
	hatColor: Color3,
	hair: string,
	hairColor: Color3,
	badge: boolean?,
	tie: Color3?,
}

NPCOutfits.FIELD_BY_ASSET_TYPE = {
	[11] = "Shirt",
	[12] = "Pants",
	[8] = "HatAccessory",
	[41] = "HairAccessory",
	[42] = "FaceAccessory",
} :: { [number]: string }

-- BAKED CURATION DATA (assets/curation/vehicles-characters-props.json) ---------------------------------------------

NPCOutfits.Roles = {
	car_salesman = {
		name = "Grey Suit w/ Black Vest [+]",
		Shirt = 6554200369,
		Pants = 6555797786,
		HatAccessory = { 19027209 },
		HairAccessory = { 62234425 },
		FaceAccessory = {},
		alternates = {
			{
				name = "White Suit w/ Black Vest [+] / White Suit 'n' Black Vest [-] (TIX Clothing +) - flashier",
				Shirt = 6553589977,
				Pants = 6555794614,
				HatAccessory = { 1029025 },
				HairAccessory = { 62234425 },
				FaceAccessory = {},
			},
		},
	},
	chef_vendor = {
		name = "White Chef Jacket",
		Shirt = 6602162100,
		Pants = 6602166195,
		HatAccessory = { 96678446 },
		HairAccessory = { 62234425 },
		FaceAccessory = {},
		alternates = {
			{
				name = "Swap hat -> Roblox 'Paper Hat' (newspaper street-vendor hat)",
				Shirt = 6602162100,
				Pants = 6602166195,
				HatAccessory = { 10476359 },
				HairAccessory = { 62234425 },
				FaceAccessory = {},
			},
			{
				name = "Swap hat -> Roblox 'Gourmet Chef' (puffy white toque)",
				Shirt = 6602162100,
				Pants = 6602166195,
				HatAccessory = { 12314404 },
				HairAccessory = { 62234425 },
				FaceAccessory = {},
			},
		},
	},
	civilian_beach = {
		name = "Summer Hawaiian Shirt (Red)",
		Shirt = 7024382762,
		Pants = 382537950,
		HatAccessory = {},
		HairAccessory = { 63690008 },
		FaceAccessory = { 51245241 },
		alternates = {},
	},
	civilian_hoodie = {
		name = "Denim Jacket with White Hoodie",
		Shirt = 398633584,
		Pants = 398635338,
		HatAccessory = {},
		HairAccessory = { 2956239660 },
		FaceAccessory = {},
		alternates = {},
	},
	civilian_pastel = {
		name = "Pastel Starburst Top with Gray Jacket",
		Shirt = 398634295,
		Pants = 382538503,
		HatAccessory = {},
		HairAccessory = { 376526888 },
		FaceAccessory = {},
		alternates = {},
	},
	civilian_pizza = {
		name = "I <3 Pizza Shirt",
		Shirt = 382537085,
		Pants = 398633812,
		HatAccessory = {},
		HairAccessory = { 376524487 },
		FaceAccessory = {},
		alternates = {},
	},
	civilian_plaid = {
		name = "Blue Plaid Shirt",
		Shirt = 398635081,
		Pants = 144076760,
		HatAccessory = { 68259961 },
		HairAccessory = { 376548738 },
		FaceAccessory = {},
		alternates = {},
	},
	civilian_teal = {
		name = "Teal Shirt",
		Shirt = 382537702,
		Pants = 398634487,
		HatAccessory = {},
		HairAccessory = { 451221329 },
		FaceAccessory = {},
		alternates = {},
	},
	civilian_tourist = {
		name = "Summer Hawaiian Shirt (Blue)",
		Shirt = 7024381748,
		Pants = 382537806,
		HatAccessory = { 236398519 },
		HairAccessory = {},
		FaceAccessory = {},
		alternates = {},
	},
	police_officer = {
		name = "Police",
		Shirt = 4196154381,
		Pants = 9670576178,
		HatAccessory = { 1081392 },
		HairAccessory = {},
		FaceAccessory = { 51245241 },
		alternates = {
			{
				name = "Police+ / Police- (Abandoned Era) navy set",
				Shirt = 2430770336,
				Pants = 2430769797,
				HatAccessory = { 1081392 },
				HairAccessory = {},
				FaceAccessory = { 51245241 },
			},
			{
				name = "Generic '90s Police Uniform + Trooper pants (Emergency Response Customs)",
				Shirt = 6098143235,
				Pants = 4586598212,
				HatAccessory = { 1081392 },
				HairAccessory = {},
				FaceAccessory = { 51245241 },
			},
		},
	},
} :: { [string]: Outfit }

NPCOutfits.Pool = {
	hair = { 63690008, 451221329, 376526888, 376524487, 376548738, 2956239660, 1103003368, 62234425 },
	hats = { 607702162, 68259961, 236398519, 5063815350, 1029025, 10476359 },
	face = { 51245241 },
	extraShirts = { 144076358 },
	hatsWithHair = { 236398519 },
} :: Pool

-- PROCEDURAL LOOKS ---------------------------------------------------------------------------------------------------

local rgb = Color3.fromRGB

NPCOutfits.SKIN_TONES = {
	rgb(255, 221, 180),
	rgb(241, 194, 125),
	rgb(224, 172, 105),
	rgb(198, 134, 66),
	rgb(141, 85, 36),
	rgb(255, 205, 148),
	rgb(234, 184, 146),
} :: { Color3 }

NPCOutfits.Looks = {
	police = {
		shirt = rgb(40, 90, 210),
		pants = rgb(26, 32, 70),
		shoes = rgb(20, 20, 26),
		hat = "police",
		hatColor = rgb(28, 50, 130),
		hair = "short",
		hairColor = rgb(60, 40, 25),
		badge = true,
		tie = rgb(20, 20, 26),
	},
	chef = {
		shirt = rgb(246, 246, 246),
		pants = rgb(128, 128, 136),
		shoes = rgb(30, 30, 34),
		hat = "toque",
		hatColor = rgb(255, 255, 255),
		hair = "short",
		hairColor = rgb(95, 60, 30),
	},
	salesman = {
		shirt = rgb(120, 122, 132),
		pants = rgb(98, 100, 110),
		shoes = rgb(25, 20, 18),
		hat = "fedora",
		hatColor = rgb(52, 54, 64),
		hair = "short",
		hairColor = rgb(95, 60, 30),
		tie = rgb(20, 20, 26),
	},
	gearkeeper = {
		shirt = rgb(240, 240, 236),
		pants = rgb(225, 225, 220),
		shoes = rgb(25, 20, 18),
		hat = "fedora",
		hatColor = rgb(30, 30, 36),
		hair = "short",
		hairColor = rgb(40, 30, 25),
		tie = rgb(20, 20, 26),
	},
} :: { [string]: Look }

-- Civilian fallback palettes (picked per rig).
NPCOutfits.CivilianShirts = {
	rgb(255, 85, 85),
	rgb(70, 160, 255),
	rgb(255, 200, 40),
	rgb(120, 220, 90),
	rgb(190, 110, 255),
	rgb(255, 140, 40),
	rgb(40, 200, 200),
	rgb(255, 120, 190),
} :: { Color3 }
NPCOutfits.CivilianPants = {
	rgb(52, 74, 128),
	rgb(40, 40, 48),
	rgb(110, 90, 70),
	rgb(70, 110, 80),
	rgb(150, 150, 160),
} :: { Color3 }
NPCOutfits.HairColors = {
	rgb(40, 30, 25),
	rgb(95, 60, 30),
	rgb(230, 190, 90),
	rgb(200, 80, 40),
	rgb(60, 60, 70),
} :: { Color3 }
NPCOutfits.HatColors = {
	rgb(220, 50, 50),
	rgb(40, 120, 255),
	rgb(255, 210, 0),
	rgb(255, 255, 255),
	rgb(35, 35, 45),
} :: { Color3 }

-- PURE HELPERS -------------------------------------------------------------------------------------------------------

local function emptyOutfit(name: string): Outfit
	return { name = name, Shirt = 0, Pants = 0, HatAccessory = {}, HairAccessory = {}, FaceAccessory = {} }
end

-- Routes one JSON outfit object ({ Shirt = item, HatAccessory = { item, ... }, ... }) by each item's assetType.
-- Returns the fields it saw (a partial outfit) so alternates can be merged over a base.
local function parseOutfitObject(obj: any): { [string]: any }
	local out: { [string]: any } = {}
	if type(obj) ~= "table" then
		return out
	end
	for _, val in obj do
		local items: { any } = if type(val) == "table" and val[1] ~= nil then val else { val }
		for _, item in items do
			if type(item) ~= "table" then
				continue
			end
			local field = NPCOutfits.FIELD_BY_ASSET_TYPE[tonumber(item.assetType) or -1]
			local id = tonumber(item.id)
			if field == nil or id == nil then
				continue
			end
			if field == "Shirt" or field == "Pants" then
				out[field] = id
			else
				local list = out[field]
				if list == nil then
					list = {}
					out[field] = list
				end
				table.insert(list, id)
			end
		end
	end
	return out
end

local function merged(base: Outfit, partial: { [string]: any }, name: string): Outfit
	local o = emptyOutfit(name)
	for _, f in { "Shirt", "Pants" } do
		local v = partial[f];
		(o :: any)[f] = if v ~= nil then v else (base :: any)[f]
	end
	for _, f in { "HatAccessory", "HairAccessory", "FaceAccessory" } do
		local v = partial[f];
		(o :: any)[f] = table.clone(if v ~= nil then v else (base :: any)[f])
	end
	return o
end

local function idList(items: any): { number }
	local out = {}
	if type(items) == "table" then
		for _, item in items do
			local id = type(item) == "table" and tonumber(item.id)
			if id then
				table.insert(out, id)
			end
		end
	end
	return out
end

-- Parses the curation JSON list into (roles keyed without "npc_", accessory pool). Non-npc and malformed entries are
-- skipped. Pure (the test harness feeds it the real JSON).
function NPCOutfits.fromCuration(list: { any }): ({ [string]: Outfit }, Pool?)
	local roles: { [string]: Outfit } = {}
	local pool: Pool? = nil
	for _, entry in list do
		if type(entry) ~= "table" or type(entry.role) ~= "string" then
			continue
		end
		local key = entry.role:match("^npc_(.+)$")
		if key == nil then
			continue
		end
		if key == "accessory_pool" then
			local hatsWithHair = {}
			if type(entry.hats) == "table" then
				for _, h in entry.hats do
					if type(h) == "table" and type(h.name) == "string" and h.name:lower():find("hair") then
						table.insert(hatsWithHair, tonumber(h.id) or 0)
					end
				end
			end
			pool = {
				hair = idList(entry.hair),
				hats = idList(entry.hats),
				face = idList(entry.face),
				extraShirts = idList(entry.extraShirts),
				hatsWithHair = hatsWithHair,
			}
			continue
		end
		local base = merged(emptyOutfit(""), parseOutfitObject(entry.outfit), tostring(entry.name or key))
		local alts: { Outfit } = {}
		if type(entry.alternates) == "table" then
			for _, a in entry.alternates do
				if type(a) == "table" then
					table.insert(alts, merged(base, parseOutfitObject(a.outfit), tostring(a.name or key)))
				end
			end
		end
		base.alternates = alts
		roles[key] = base
	end
	return roles, pool
end

local function joinIds(ids: { number }): string
	local parts = table.create(#ids)
	for i, id in ids do
		parts[i] = string.format("%d", id)
	end
	return table.concat(parts, ",")
end

-- HumanoidDescription values for an outfit (accessories as comma lists).
function NPCOutfits.descriptionFields(outfit: Outfit): DescriptionFields
	return {
		Shirt = outfit.Shirt or 0,
		Pants = outfit.Pants or 0,
		HatAccessory = joinIds(outfit.HatAccessory or {}),
		HairAccessory = joinIds(outfit.HairAccessory or {}),
		FaceAccessory = joinIds(outfit.FaceAccessory or {}),
	}
end

-- The outfit for a role key ("police_officer", "car_salesman", ...), or one of its alternates (1-based).
function NPCOutfits.get(key: string, alternate: number?): Outfit?
	local base = NPCOutfits.Roles[key]
	if base == nil or alternate == nil or alternate == 0 then
		return base
	end
	local alts = base.alternates
	return if alts then alts[alternate] else nil
end

-- Sorted civilian role keys ("civilian_*").
function NPCOutfits.civilians(): { string }
	local out = {}
	for key in NPCOutfits.Roles do
		if key:sub(1, 9) == "civilian_" then
			table.insert(out, key)
		end
	end
	table.sort(out)
	return out
end

-- Deterministic accessory-pool remix of a civilian: same clothes, a different pool hair, sometimes a pool hat (a hat
-- with built-in hair replaces the hair), sometimes sunglasses. seed: any integer.
function NPCOutfits.poolVariant(base: Outfit, pool: Pool, seed: number): Outfit
	local o = merged(base, {}, base.name .. " (remix)")
	local s = math.abs(math.floor(seed))
	local function pick<T>(list: { T }, salt: number): T?
		if #list == 0 then
			return nil
		end
		return list[((s * 7 + salt * 13) % #list) + 1]
	end
	local currentHair = base.HairAccessory[1]
	local hair = pick(pool.hair, 1)
	if hair == currentHair and #pool.hair > 1 then
		hair = pool.hair[(table.find(pool.hair, hair) or 1) % #pool.hair + 1]
	end
	o.HairAccessory = if hair then { hair } else {}
	o.HatAccessory = {}
	if s % 2 == 0 then
		local hat = pick(pool.hats, 3)
		if hat then
			o.HatAccessory = { hat }
			if table.find(pool.hatsWithHair, hat) then
				o.HairAccessory = {}
			end
		end
	end
	o.FaceAccessory = {}
	if s % 4 == 1 then
		local face = pick(pool.face, 5)
		if face then
			o.FaceAccessory = { face }
		end
	end
	return o
end

return NPCOutfits
