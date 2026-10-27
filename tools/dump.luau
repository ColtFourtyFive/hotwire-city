--!nocheck
-- Build game geometry headlessly in Lune and dump parts to JSON for tools/render.py.
--
--   lune run tools/dump.luau car <carId|police|all> [mutation] out.json
--   lune run tools/dump.luau map out.json
--   lune run tools/dump.luau plot <index> out.json
--   lune run tools/dump.luau mapslots out.json   (art pass: AssetSlots + their resolved kit key, every part with its
--                                                 slot index, Billboard boards + ad image, terrain ops; see
--                                                 tools/preview_dressed.py)
--
-- Contracts used: Shared/Vehicle/CarBuilder.build(carId, mutation, {forDisplay=true}) / .buildDef(def, ...)
--                 Server/Systems/MapBuilder.build(parent) -> Folder
--                 Server/Systems/PlotService.buildGarageModel(index) -> Model
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local Harness = require("../tests/harness")

local args = process.args
local kind = args[1]
local Instance = Harness.roblox.Instance

local function writeGroups(groups, out)
	fs.writeFile(out, serde.encode("json", { groups = groups }))
	print("wrote " .. out)
end

if kind == "car" then
	local which, mutation, out = args[2], args[3] or "None", args[4] or args[3]
	if args[4] == nil then
		mutation = "None"
		out = args[3]
	end
	local CarBuilder = Harness.require("src/shared/Vehicle/CarBuilder")
	local Cars = Harness.require("src/shared/Config/Cars")
	local ids = {}
	if which == "all" then
		for _, def in Cars.List do
			table.insert(ids, def.id)
		end
		table.insert(ids, "police")
	else
		ids = string.split(which, ",")
	end
	local groups = {}
	for _, id in ids do
		local model
		if id == "police" then
			model = CarBuilder.buildDef(Cars.Police, mutation, { forDisplay = true })
		else
			model = CarBuilder.build(id, mutation, { forDisplay = true })
		end
		local parts = Harness.dumpParts(model)
		table.insert(groups, {
			title = ("%s (%d parts, ride %.2f, wheel r %.2f)"):format(
				id,
				#parts,
				model:GetAttribute("RideHeight") or -1,
				model:GetAttribute("WheelRadius") or -1
			),
			parts = parts,
		})
	end
	writeGroups(groups, out)
elseif kind == "map" then
	local out = args[2]
	local MapBuilder = Harness.require("src/server/Systems/MapBuilder")
	local folder = MapBuilder.build(Harness.workspace)
	local parts = Harness.dumpParts(folder)
	print(("map parts: %d"):format(#parts))
	writeGroups({ { title = ("map (%d parts)"):format(#parts), parts = parts } }, out)
elseif kind == "plot" then
	local index = tonumber(args[2])
	local out = args[3]
	local PlotService = Harness.require("src/server/Systems/PlotService")
	local model = PlotService.buildGarageModel(index)
	local parts = Harness.dumpParts(model)
	writeGroups({ { title = ("plot %d (%d parts)"):format(index, #parts), parts = parts } }, out)
elseif kind == "mapslots" then
	local out = args[2]
	local MapBuilder = Harness.require("src/server/Systems/MapBuilder")
	local MapDresser = Harness.require("src/server/Systems/MapDresser")
	local Assets = Harness.require("src/shared/Config/Assets")
	local folder = MapBuilder.build(Harness.workspace)
	table.clear(Harness.terrainOps)
	local terrain = Harness.workspace:FindFirstChildOfClass("Terrain")
	MapBuilder.buildTerrain(terrain)
	local slotOf = {}
	local slots = {}
	for i, m in MapBuilder.slots(folder) do
		local _, key = MapDresser.resolve(m)
		local boxes = {}
		for _, b in MapBuilder.slotBoxes(m) do
			table.insert(boxes, { cframe = { b.cframe:GetComponents() }, size = { b.size.X, b.size.Y, b.size.Z } })
		end
		table.insert(slots, {
			name = m.Name,
			path = m:GetFullName(),
			category = m:GetAttribute("Category"),
			role = m:GetAttribute("Role"),
			key = key or "",
			fit = m:GetAttribute("Fit"),
			yaw = m:GetAttribute("Yaw") or 0,
			cframe = { m:GetPivot():GetComponents() },
			boxes = boxes,
		})
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				slotOf[d] = i
			end
		end
	end
	local parts = {}
	for _, d in folder:GetDescendants() do
		if d:IsA("BasePart") then
			local shape = "Block"
			if d:IsA("Part") then
				shape = d.Shape.Name
			elseif d:IsA("WedgePart") then
				shape = "Wedge"
			elseif d:IsA("CornerWedgePart") then
				shape = "CornerWedge"
			end
			table.insert(parts, {
				name = d.Name,
				shape = shape,
				size = { d.Size.X, d.Size.Y, d.Size.Z },
				cframe = { d.CFrame:GetComponents() },
				color = { math.floor(d.Color.R * 255), math.floor(d.Color.G * 255), math.floor(d.Color.B * 255) },
				transparency = d.Transparency,
				material = d.Material.Name,
				canCollide = d.CanCollide,
				slot = slotOf[d] or 0,
				nightGlow = d:HasTag("NightGlow"),
			})
		end
	end
	local mapPartCount = #parts
	-- garages (PlotService) for context in the preview; skipped quietly if PlotService can't build headlessly
	local okPlots, PlotService = pcall(Harness.require, "src/server/Systems/PlotService")
	if okPlots and PlotService and PlotService.buildGarageModel then
		for i = 1, 8 do
			local ok, model = pcall(PlotService.buildGarageModel, i)
			if ok and model then
				for _, p in Harness.dumpParts(model) do
					p.slot = 0
					p.garage = true
					table.insert(parts, p)
				end
				model:Destroy()
			end
		end
	end
	local ads = Assets.billboardAds()
	local boards = {}
	for _, d in folder:GetDescendants() do
		if d:IsA("BasePart") and d:HasTag("Billboard") then
			table.insert(boards, {
				cframe = { d.CFrame:GetComponents() },
				size = { d.Size.X, d.Size.Y, d.Size.Z },
				back = d:GetAttribute("AdBack") == true,
				image = MapDresser.adFor(d, ads) or "",
			})
		end
	end
	local images = {}
	for _, d in folder:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute("Image") then
			table.insert(images, {
				cframe = { d.CFrame:GetComponents() },
				size = { d.Size.X, d.Size.Y, d.Size.Z },
				image = d:GetAttribute("Image"),
			})
		end
	end
	local ops = {}
	for _, op in Harness.terrainOps do
		if op[1] == "FillBlock" then
			table.insert(ops, {
				cframe = { op[2]:GetComponents() },
				size = { op[3].X, op[3].Y, op[3].Z },
				material = op[4].Name,
			})
		end
	end
	local nb, np = 0, 0
	for _, sl in slots do
		if sl.category == "Buildings" then
			nb += 1
		else
			np += 1
		end
	end
	local slotParts = 0
	for _, p in parts do
		if p.slot > 0 then
			slotParts += 1
		end
	end
	local garageParts = #parts - mapPartCount
	print(
		(
			"map parts: %d (%d in placeholders, %d remain dressed); slots: %d buildings, %d props; boards %d; "
			.. "+%d garage parts (context)"
		):format(mapPartCount, slotParts, mapPartCount - slotParts, nb, np, #boards, garageParts)
	)
	fs.writeFile(
		out,
		serde.encode("json", { slots = slots, parts = parts, boards = boards, images = images, terrain = ops })
	)
	print("wrote " .. out)
else
	print("usage: see header")
	process.exit(1)
end
