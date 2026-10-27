--!nocheck
-- Hero-shell QA dump (docs/ART_PASS.md AP1). For each car: the procedural build, then the same car dressed by the real
-- CarBuilder.applyShell from a template made by the real AssetLibrary._normalize out of a fake import whose MeshPart
-- has the GLB's bounding box. tools/shell_lineup.py maps the GLB triangles into the dumped shell MeshPart and renders
-- procedural vs shell side by side.
--
--   lune run tools/shell_lineup.luau in.json out.json
--   in.json: { "<carId>": { "min": [x,y,z], "max": [x,y,z] } }   (native GLB bounds, glTF axes = Roblox axes)
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local Harness = require("../tests/harness")

local Instance = Harness.roblox.Instance
local Vector3 = Harness.roblox.Vector3
local CFrame = Harness.roblox.CFrame

local input = serde.decode("json", fs.readFile(process.args[1]))
local out = process.args[2]

local AssetLibrary = Harness.require("src/server/Systems/AssetLibrary")
local Assets = Harness.require("src/shared/Config/Assets")
local CarBuilder = Harness.require("src/shared/Vehicle/CarBuilder")
local Cars = Harness.require("src/shared/Config/Cars")

local function build(id, opts)
	if id == "police_unit" then
		return CarBuilder.buildDef(Cars.Police, "None", opts)
	end
	return CarBuilder.build(id, "None", opts)
end

local function cf(c)
	return { c:GetComponents() }
end

local function vec(v)
	return { v.X, v.Y, v.Z }
end

local cars = {}
local keys = {}
for key in input do
	table.insert(keys, key)
end
table.sort(keys)
for _, key in keys do
	local b = input[key]
	local mn = Vector3.new(b.min[1], b.min[2], b.min[3])
	local mx = Vector3.new(b.max[1], b.max[2], b.max[3])
	-- fake import: one MeshPart filling the GLB bounds (as the Roblox importer centers a mesh in its part)
	local raw = Instance.new("Model")
	local mesh = Instance.new("MeshPart")
	mesh.Name = "Mesh"
	mesh.Size = mx - mn
	mesh.CFrame = CFrame.new((mn + mx) / 2)
	mesh.TextureID = "rbxassetid://1"
	mesh.Parent = raw
	local template = AssetLibrary._normalize(raw, key, Assets.Hero[key])

	local plain = build(key, { forDisplay = true })

	local lib = Instance.new("Folder")
	lib.Name = "AssetLibrary"
	local hero = Instance.new("Folder")
	hero.Name = "Hero"
	hero.Parent = lib
	template.Parent = hero
	Harness.replicated.AssetLibrary = lib
	local dressed = build(key, { forDisplay = true })
	local seat = build(key, nil):FindFirstChild("DriverSeat") -- dressed drivable car (open-top shells move the seat)
	Harness.replicated.AssetLibrary = nil

	local shellPart = dressed:FindFirstChild(CarBuilder.SHELL_NAME):FindFirstChild("Mesh")
	local visible = {}
	for _, p in Harness.dumpParts(dressed) do
		if p.transparency < 0.95 and p.name ~= "Mesh" then
			table.insert(visible, p)
		end
	end
	local wheels = {}
	for _, k in { "FL", "FR", "RL", "RR" } do
		local w = plain:FindFirstChild("Wheel_" .. k)
		if w then
			table.insert(wheels, { pos = vec(w.CFrame.Position), r = w.Size.Y / 2, width = w.Size.X })
		end
	end
	table.insert(cars, {
		key = key,
		attrs = {
			Length = plain:GetAttribute("Length"),
			Width = plain:GetAttribute("Width"),
			Height = plain:GetAttribute("Height"),
			RideHeight = plain:GetAttribute("RideHeight"),
			ShellHeight = dressed:GetAttribute("ShellHeight"),
			ShellScale = dressed:FindFirstChild(CarBuilder.SHELL_NAME):GetAttribute("ShellScale"),
		},
		procedural = Harness.dumpParts(plain),
		shell = { cframe = cf(shellPart.CFrame), size = vec(shellPart.Size), native = { b.min, b.max } },
		extras = visible, -- what stays visible next to the shell (police sirens)
		wheels = wheels,
		seatTop = if seat then vec(seat.CFrame.Position + Vector3.new(0, seat.Size.Y / 2, 0)) else nil,
	})
	print(
		("%-18s L=%.2f shell=%.2fx%.2fx%.2f scale=%.3f roof=%.2f (procedural H %.2f)"):format(
			key,
			plain:GetAttribute("Length"),
			shellPart.Size.X,
			shellPart.Size.Y,
			shellPart.Size.Z,
			dressed:FindFirstChild(CarBuilder.SHELL_NAME):GetAttribute("ShellScale"),
			dressed:GetAttribute("ShellHeight"),
			plain:GetAttribute("Height")
		)
	)
end
fs.writeFile(out, serde.encode("json", { cars = cars }))
print("wrote " .. out)
