--!nocheck
-- Dump CarBuilder v2 rigs for the Blender evidence renders (render_roster.py street).
--   lune run tools/blender/carpipe/rig_dump.luau [vid,vid,...] [--steer 0.35]
-- For each vehicle: a stand-in template laid out like the Open Cloud import (CarTemplates.prepare solves it), the
-- car built by CarBuilder exactly as the game does, then the wheels posed with WheelAnimator.wheelC0 (front wheels
-- steered by --steer radians, every wheel spun a little). Writes assets/vehicles/_rig/rig.json: per car, per MeshPart,
-- the template (built-pose) CFrame and the rigged CFrame, both in the car's ground frame (ground y = 0, front -Z).
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local H = require("../../../tests/harness")

local Instance = H.roblox.Instance
local CFrame = H.roblox.CFrame

H.setMode("server")
local Vehicles = H.require("src/shared/Config/Vehicles")
local Cars = H.require("src/shared/Config/Cars")
local CarBuilder = H.require("src/shared/Vehicle/CarBuilder")
local CarTemplates = H.require("src/shared/Vehicle/CarTemplates")
H.setMode("client")
local WheelAnimator = H.require("src/client/Controllers/WheelAnimator")
H.setMode("server")
Vehicles = H.require("src/shared/Config/Vehicles")
Cars = H.require("src/shared/Config/Cars")
CarBuilder = H.require("src/shared/Vehicle/CarBuilder")
CarTemplates = H.require("src/shared/Vehicle/CarTemplates")

local ids = {}
local steer = 0.35
local args = process.args
local i = 1
while i <= #args do
	if args[i] == "--steer" then
		steer = tonumber(args[i + 1]) or steer
		i += 1
	else
		for id in string.gmatch(args[i], "[^,]+") do
			table.insert(ids, id)
		end
	end
	i += 1
end
if #ids == 0 then
	for _, s in Vehicles.List do
		table.insert(ids, s.id)
	end
end

local function fakeImport(spec)
	local root = Instance.new("Model")
	for name, box in spec.parts do
		local node = Instance.new("Model")
		node.Name = name .. "_Node"
		node.Parent = root
		local mp = Instance.new("MeshPart")
		mp.Name = name
		mp.Size = box.size
		mp.CFrame = CFrame.new(-box.center.X, box.center.Y, -box.center.Z)
		mp.Parent = node
	end
	return root
end

local function comps(cf)
	return { cf:GetComponents() }
end

local folder = Instance.new("Folder")
folder.Name = CarTemplates.FOLDER_NAME
H.replicated[CarTemplates.FOLDER_NAME] = folder

local defFor = {}
for _, def in Cars.List do
	if def.vehicle and not defFor[def.vehicle] then
		defFor[def.vehicle] = def
	end
end
for _, def in Cars.PoliceUnits do
	defFor[def.vehicle] = def
end

local out = { order = ids, steer = steer, cars = {} }
for _, vid in ids do
	local spec = Vehicles.get(vid)
	assert(spec, "unknown vehicle " .. vid)
	local tpl = CarTemplates.prepare(fakeImport(spec), spec)
	CarTemplates.publish(vid, tpl)
	local def = defFor[vid]
	local m = CarBuilder.buildDef(def, "None")
	assert(m:GetAttribute("MeshCar") == true, vid .. " did not build as a mesh car")
	local chassis = m.PrimaryPart
	local ground = chassis.CFrame * CFrame.new(0, -m:GetAttribute("RideHeight"), 0)
	-- pose the wheels as WheelAnimator would (steer the front pair, a little spin everywhere)
	for _, w in spec.wheels do
		local weld = chassis:FindFirstChild("WheelWeld_" .. w.key)
		local part = m:FindFirstChild("Wheel_" .. w.key)
		local wheelCF = weld.C0 * weld.C1:Inverse()
		local front = string.sub(w.key, 1, 1) == "F"
		local c0 = WheelAnimator.wheelC0(
			wheelCF.Position,
			wheelCF.Rotation,
			weld.C1,
			0,
			if front then steer else 0,
			0.6 * WheelAnimator.spinSign(wheelCF.Rotation)
		)
		weld.C0 = c0
		part.CFrame = chassis.CFrame * c0 * weld.C1:Inverse()
	end
	local parts = {}
	for _, p in m:GetChildren() do
		if p:IsA("MeshPart") then
			local role = p.Name
			local key = p:GetAttribute("WheelKey")
			local src = if key then "Wheel" .. key elseif role == "TaxiSign" then "Sign" else role
			local built = tpl:FindFirstChild(src)
			parts[src] = {
				rig = comps(ground:ToObjectSpace(p.CFrame)),
				built = comps(built.CFrame),
				center = { p.CFrame.Position.X, p.CFrame.Position.Y, p.CFrame.Position.Z },
			}
		end
	end
	out.cars[vid] = {
		carId = def.id,
		paint = { math.floor(def.color.R * 255 + 0.5), math.floor(def.color.G * 255 + 0.5), math.floor(def.color.B * 255 + 0.5) },
		rideHeight = m:GetAttribute("RideHeight"),
		parts = parts,
	}
end
H.replicated[CarTemplates.FOLDER_NAME] = nil
fs.writeDir("assets/vehicles/_rig")
fs.writeFile("assets/vehicles/_rig/rig.json", serde.encode("json", out, true))
print(("rig dump: %d cars -> assets/vehicles/_rig/rig.json"):format(#ids))
