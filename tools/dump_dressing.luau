--!nocheck
-- Dump a dressed garage / the dealership showroom (parts + AssetSlot/LootSlot placeholders + decals + display cars)
-- to JSON for tools/preview_slots.py, which swaps every slot for its decimated kit GLB.
--
--   lune run tools/dump_dressing.luau garage <plotIndex> <lootTier 0..4> out.json
--   lune run tools/dump_dressing.luau dealer out.json
--
-- Contracts used: PlotService.buildGarageModel / _lootTierModels / _applyLootTier,
--                 DealershipService.buildShowroom / buildDressing, MapBuilder.build (dealer surroundings).
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local Harness = require("../tests/harness")

local roblox = Harness.roblox
local Instance = roblox.Instance
local CFrame = roblox.CFrame

local args = process.args
local kind = args[1]
local Assets = Harness.require("src/shared/Config/Assets")
local Cars = Harness.require("src/shared/Config/Cars")

local function comps(cf)
	return { cf:GetComponents() }
end

local function slotOf(inst)
	local node = inst.Parent
	while node do
		if node:IsA("Model") and (node:HasTag("AssetSlot") or node:HasTag("LootSlot")) then
			return node
		end
		node = node.Parent
	end
	return nil
end

local function defOf(cat, role)
	local t = Assets[cat]
	local d = t and t[role]
	if not d then
		return nil
	end
	return { fit = d.fit, size = d.size, yaw = d.yaw or 0 }
end

-- Every BasePart under `roots` (+ which slot it belongs to) and every slot.
local function dump(roots, cars, extra, keep)
	local parts, slots, slotIndex = {}, {}, {}
	local function addSlot(m)
		if slotIndex[m] then
			return slotIndex[m]
		end
		local cat, role = m:GetAttribute("Category"), m:GetAttribute("Role")
		local fp = m:GetAttribute("Footprint")
		table.insert(slots, {
			name = m.Name,
			category = cat,
			role = role,
			fit = m:GetAttribute("Fit"),
			tier = m:GetAttribute("LootTier"),
			loot = m:HasTag("LootSlot"),
			cframe = comps(m.WorldPivot),
			footprint = if fp then { fp.X, fp.Y, fp.Z } else nil,
			def = defOf(cat, role),
		})
		slotIndex[m] = #slots
		return #slots
	end
	for _, root in roots do
		for _, d in root:GetDescendants() do
			if d:IsA("Model") and (d:HasTag("AssetSlot") or d:HasTag("LootSlot")) then
				if not keep or keep(d.WorldPivot.Position, 0) then
					addSlot(d)
				end
			end
		end
		for _, p in root:GetDescendants() do
			if p:IsA("BasePart") and (not keep or keep(p.CFrame.Position, math.max(p.Size.X, p.Size.Y, p.Size.Z))) then
				local shape = "Block"
				if p:IsA("Part") then
					shape = p.Shape.Name
				elseif p:IsA("WedgePart") then
					shape = "Wedge"
				elseif p:IsA("CornerWedgePart") then
					shape = "CornerWedge"
				end
				local decals = {}
				for _, c in p:GetChildren() do
					if c:IsA("Decal") then
						table.insert(decals, { face = c.Face.Name, texture = c.Texture })
					end
				end
				local s = slotOf(p)
				table.insert(parts, {
					name = p.Name,
					shape = shape,
					size = { p.Size.X, p.Size.Y, p.Size.Z },
					cframe = comps(p.CFrame),
					color = { math.floor(p.Color.R * 255), math.floor(p.Color.G * 255), math.floor(p.Color.B * 255) },
					transparency = p.Transparency,
					material = p.Material.Name,
					slot = if s then addSlot(s) else nil,
					decals = if #decals > 0 then decals else nil,
				})
			end
		end
	end
	local carList = {}
	for _, c in cars or {} do
		table.insert(carList, { carId = c.carId, cframe = comps(c.cframe), def = defOf("Hero", c.carId) })
	end
	local out = { parts = parts, slots = slots, cars = carList }
	for k, v in extra or {} do
		out[k] = v
	end
	return out
end

local function write(out, path)
	fs.writeFile(path, serde.encode("json", out))
	print(("wrote %s (%d parts, %d slots, %d cars)"):format(path, #out.parts, #out.slots, #out.cars))
end

-- Hero-meshed cars only (the preview has their GLBs), cheapest first.
local function heroCars()
	local ids = {}
	for _, def in Cars.List do
		if Assets.Hero[def.id] then
			table.insert(ids, def.id)
		end
	end
	return ids
end

if kind == "garage" then
	local index = tonumber(args[2]) or 1
	local tier = tonumber(args[3]) or 4
	local out = args[4]
	local PlotService = Harness.require("src/server/Systems/PlotService")
	local MapLayout = Harness.require("src/shared/Util/MapLayout")
	local model = PlotService.buildGarageModel(index)
	PlotService._applyLootTier(model, PlotService._lootTierModels(model), tier)
	-- a few parked cars (pricier ones in the back rows) so the bays read as a garage
	local ids = heroCars()
	local cars = {}
	local parked = { 1, 2, 3, 4, 5, 6, 8, 9, 12 }
	for i, slot in parked do
		local id = ids[((index * 5 + i * 7) % #ids) + 1]
		local cf = MapLayout.slotWorld(index, slot) * CFrame.new(0, PlotService.PAD_TOP, 0)
		table.insert(cars, { carId = id, cframe = cf })
	end
	write(
		dump({ model }, cars, {
			origin = comps(MapLayout.plotOrigin(index)),
			title = ("garage %d, loot tier %d"):format(index, tier),
		}),
		out
	)
elseif kind == "dealer" then
	local out = args[2]
	local MapBuilder = Harness.require("src/server/Systems/MapBuilder")
	local Dealer = Harness.require("src/server/Systems/DealershipService")
	local MapLayout = Harness.require("src/shared/Util/MapLayout")
	local map = MapBuilder.build(Harness.workspace)
	local c = MapLayout.poiCenter("Dealership")
	-- keep the dealership + spawn plaza blocks (and their sidewalks / roads); the dealer's own folder is all kept
	local function keepMap(pos, extent)
		return extent <= 260 and pos.X > c.X - 250 and pos.X < c.X + 110 and pos.Z > c.Z - 110 and pos.Z < c.Z + 110
	end
	local folder = Instance.new("Folder")
	Dealer.buildShowroom(folder)
	Dealer.buildDressing(folder)
	local ids = heroCars()
	local cars = {}
	local picks = { 4, 11, 17, 22, 26, 28, 30, 32 }
	for i, pad in MapLayout.dealerPads() do
		local id = ids[((picks[i] - 1) % #ids) + 1]
		table.insert(cars, { carId = id, cframe = pad * CFrame.new(0, Dealer.TURNTABLE_HEIGHT, 0) })
	end
	local a = dump({ map }, {}, nil, keepMap)
	local b = dump({ folder }, cars, { origin = comps(CFrame.new(c)), title = "dealership" })
	-- merge: renumber b's slot references after a's slots
	for _, p in b.parts do
		if p.slot then
			p.slot += #a.slots
		end
		table.insert(a.parts, p)
	end
	for _, s in b.slots do
		table.insert(a.slots, s)
	end
	b.parts, b.slots = a.parts, a.slots
	write(b, out)
else
	print("usage: see header")
	process.exit(1)
end
