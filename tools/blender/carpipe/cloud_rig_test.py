#!/usr/bin/env python3
"""Real-engine rig test of the Vehicles v2 cars (Open Cloud Luau Execution, read-only: nothing is uploaded or saved).

The execution server runs only the task script, so this bundles THIS checkout's modules into it (Config/Cars,
CarAliases, Rarity, Vehicles, Vehicle, Economy, Util/Signal, Vehicle/CarTemplates, MeshCar, CarBuilder,
VehicleController, each wrapped as a function with a stand-in `script` node and `require`), then in the engine:
  1. CarTemplates.loadAll(): every uploaded car Model through InsertService + prepare (the runtime path);
  2. CarBuilder builds one catalog car per vehicle on a baseplate (+ the two police units);
  3. per car: mesh car or fallback, part count, AssemblyMass, wheel MeshParts on their welds and on the ground plane,
     the four suspension attachments, the seat, and one server VehicleController step at full throttle (no error);
  4. one procedural car converted in place once its template exists (CarBuilder.applyMesh).
The execution server does not step physics (no PreSimulation ticks; a free part never falls), so driving itself
stays a Studio playtest item.

    python3 tools/blender/carpipe/cloud_rig_test.py [--only nami,wren]

Writes docs/v2/early/vehicles/cloud_rig.json. The API key is never printed.
"""
import argparse
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import cloud_smoke as cs  # noqa: E402

UNIVERSE, PLACE = "10773288390", "106226892419530"
MODULES = [
    "Config/Rarity", "Config/CarAliases", "Config/Cars", "Config/Vehicles", "Config/Vehicle", "Config/Economy",
    "Util/Signal", "Vehicle/CarTemplates", "Vehicle/MeshCar", "Vehicle/CarBuilder", "Vehicle/VehicleController",
]

PRELUDE = r'''
local __mods, __cache = {}, {}
local function __node(name, parent)
	local n = { __name = name, Parent = parent }
	return n
end
local Shared = __node("Shared", nil)
for _, folder in { "Config", "Util", "Vehicle" } do
	Shared[folder] = __node(folder, Shared)
end
local function __leaf(path)
	local folder, name = string.match(path, "^(%w+)/(%w+)$")
	local n = __node(name, Shared[folder])
	n.__path = path
	Shared[folder][name] = n
	return n
end
local __realRequire = require
local function __require(node)
	if type(node) == "table" and node.__path then
		local hit = __cache[node.__path]
		if hit ~= nil then
			return hit
		end
		local f = __mods[node.__path]
		assert(f, "bundle has no module " .. node.__path)
		local res = f(node)
		__cache[node.__path] = res
		return res
	end
	return __realRequire(node)
end
'''

TEST = r'''
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Cars = __require(Shared.Config.Cars)
local Vehicles = __require(Shared.Config.Vehicles)
local CarTemplates = __require(Shared.Vehicle.CarTemplates)
local CarBuilder = __require(Shared.Vehicle.CarBuilder)
local VehicleController = __require(Shared.Vehicle.VehicleController)
local ONLY = HttpService:JSONDecode([==[__ONLY__]==])
local report = { cars = {}, templates = {} }
local t0 = os.clock()

local base = Instance.new("Part")
base.Name = "RigTestGround"
base.Size = Vector3.new(2048, 4, 2048)
base.CFrame = CFrame.new(0, -2, 0)
base.Anchored = true
base.Parent = workspace

CarTemplates.loadAll()
report.loadSeconds = os.clock() - t0
for _, s in Vehicles.List do
	report.templates[s.id] = CarTemplates.get(s.id) ~= nil
end

-- one def per vehicle (+ police units)
local defs, seen = {}, {}
for _, def in Cars.List do
	if def.vehicle and not seen[def.vehicle] and (#ONLY == 0 or table.find(ONLY, def.vehicle)) then
		seen[def.vehicle] = true
		table.insert(defs, def)
	end
end
for _, def in Cars.PoliceUnits do
	if #ONLY == 0 or table.find(ONLY, def.vehicle) then
		table.insert(defs, def)
	end
end

local rigs = {}
for i, def in defs do
	local entry = { carId = def.id, vehicle = def.vehicle }
	local ok, err = pcall(function()
		local m = CarBuilder.buildDef(def, "None")
		entry.meshCar = m:GetAttribute("MeshCar") == true
		local parts = 0
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				parts += 1
			end
		end
		entry.parts = parts
		local ride = m:GetAttribute("RideHeight")
		entry.rideHeight = ride
		local x = ((i - 1) % 6) * 60 - 150
		local z = math.floor((i - 1) / 6) * 120 - 300
		m:PivotTo(CFrame.new(x, ride + 0.3, z))
		m.Name = def.id .. "_" .. i
		m.Parent = workspace
		local ctrl = VehicleController.new(m, def, { isServer = true })
		table.insert(rigs, { model = m, ctrl = ctrl, entry = entry, start = m.PrimaryPart.Position })
		entry.mass = m.PrimaryPart.AssemblyMass
	end)
	if not ok then
		entry.error = tostring(err)
	end
	table.insert(report.cars, entry)
end

-- static rig checks in the engine (the execution server does not step physics: no PreSimulation ticks, an
-- unanchored part never falls; probed 2026-10-27, so driving stays a Studio playtest item)
for _, r in rigs do
	local m, e = r.model, r.entry
	local chassis = m.PrimaryPart
	local ground = chassis.CFrame * CFrame.new(0, -m:GetAttribute("RideHeight"), 0)
	local worst, wheels = 0, 0
	for _, d in m:GetChildren() do
		if d:IsA("MeshPart") and string.match(d.Name, "^Wheel_") then
			wheels += 1
			local bottom = ground:PointToObjectSpace(d.Position).Y - d.Size.Y / 2
			worst = math.max(worst, math.abs(bottom))
			local weld = chassis:FindFirstChild("WheelWeld_" .. string.sub(d.Name, 7))
			if not (weld and weld:IsA("Weld") and weld.Part1 == d) then
				e.weldError = d.Name
			end
		end
	end
	e.wheels = wheels
	e.wheelGroundError = worst
	local seat = m:FindFirstChild("DriverSeat")
	e.seat = seat ~= nil and seat:IsA("VehicleSeat")
	e.attachments = 0
	for _, k in { "FL", "FR", "RL", "RR" } do
		if chassis:FindFirstChild("Wheel" .. k) then
			e.attachments += 1
		end
	end
	local ok, err = pcall(function()
		r.ctrl:setInput({ throttle = 1, steer = 0, handbrake = false, nitro = false })
		r.ctrl:step(1 / 60)
	end)
	e.controllerStep = ok
	e.stepError = if ok then nil else tostring(err)
	r.ctrl:destroy()
end

-- late arrival: a procedural car converted in place once its template exists
local conv = {}
local okConv, errConv = pcall(function()
	local def = Cars.ById.hot_hatch
	local folder = CarTemplates.folder()
	local tpl = CarTemplates.get(def.vehicle)
	tpl.Parent = nil -- hide it: the build falls back to the procedural car
	local m = CarBuilder.buildDef(def, "Gold")
	tpl.Parent = folder
	conv.pendingBefore = m:GetAttribute("MeshPending")
	m:PivotTo(CFrame.new(0, m:GetAttribute("RideHeight"), 400))
	m.PrimaryPart.Anchored = true
	m.Parent = workspace
	local chassis = m.PrimaryPart
	conv.applied = CarBuilder.applyMesh(m)
	conv.sameChassis = m.PrimaryPart == chassis
	conv.meshCar = m:GetAttribute("MeshCar") == true
	local fl = m:FindFirstChild("Wheel_FL")
	conv.wheelBottom = fl and (fl.Position.Y - m:GetAttribute("WheelRadius")) or nil
end)
conv.error = if okConv then nil else tostring(errConv)
report.convert = conv
report.seconds = os.clock() - t0
return HttpService:JSONEncode(report)
'''


def bundle(only):
    out = [PRELUDE]
    for m in MODULES:
        src = open(os.path.join(ROOT, "src", "shared", m + ".luau")).read()
        src = re.sub(r"^--!strict\s*\n", "", src)
        src = re.sub(r"(?m)^export type ", "type ", src)
        out.append(f'__leaf("{m}")\n__mods["{m}"] = function(script)\nlocal require = __require\n{src}\nend\n')
    out.append(TEST.replace("__ONLY__", json.dumps(only)))
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--dump", help="write the bundled script here and stop")
    a = ap.parse_args()
    only = [x for x in a.only.split(",") if x]
    script = bundle(only)
    if a.dump:
        open(a.dump, "w").write(script)
        print("bundle", len(script), "bytes ->", a.dump)
        return
    url = f"https://apis.roblox.com/cloud/v2/universes/{UNIVERSE}/places/{PLACE}/luau-execution-session-tasks"
    st, body = cs.call("POST", url, json.dumps({"script": script, "timeout": "300s"}).encode(), "application/json")
    if st != 200:
        print("task:", st, body[:600])
        sys.exit(3)
    task_path = json.loads(body)["path"]
    while True:
        time.sleep(5)
        info = json.loads(cs.call("GET", f"https://apis.roblox.com/cloud/v2/{task_path}")[1])
        if info.get("state") in ("COMPLETE", "FAILED", "CANCELLED"):
            break
    if info.get("state") != "COMPLETE":
        print(info.get("state"), json.dumps(info.get("error", info), indent=1)[:3000])
        sys.exit(4)
    report = json.loads(info["output"]["results"][0])
    report["testedAt"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    out = os.path.join(ROOT, "docs", "v2", "early", "vehicles", "cloud_rig.json")
    json.dump(report, open(out, "w"), indent=1, sort_keys=True)
    print("templates ready: %d / %d (%.1fs)" % (sum(1 for v in report["templates"].values() if v),
                                                len(report["templates"]), report.get("loadSeconds", 0)))
    for c in report["cars"]:
        print("%-22s %-22s mesh=%s parts=%s mass=%s wheels=%s att=%s groundErr=%.3f seat=%s step=%s %s" % (
            c["carId"], c.get("vehicle"), c.get("meshCar"), c.get("parts"), round(c.get("mass") or 0),
            c.get("wheels"), c.get("attachments"), c.get("wheelGroundError") or -1, c.get("seat"),
            c.get("controllerStep"), c.get("error") or c.get("stepError") or c.get("weldError") or ""))
    print("convert:", report.get("convert"))
    print("wrote", out)


if __name__ == "__main__":
    main()
