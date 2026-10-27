--!strict
-- CarTemplates: the uploaded v2 car Models (Config/Vehicles), loaded once and normalized into CarBuilder's built pose.
--
-- Server: CarTemplates.loadAll() (VehicleService.start) loads every Vehicles entry with an assetId through
-- InsertService:LoadAsset (owned uploads), normalizes it with prepare() and publishes it as
-- ReplicatedStorage.VehicleTemplates.<vehicleId> (attribute Ready = true). Clients clone the same templates for the
-- Index / garage previews they build themselves. Ready fires (vehicleId, template) per car; AllReady once at the end.
--
-- What the Open Cloud GLB importer makes of a carpipe GLB (real-engine probe, docs/v2/early/vehicles/cloud_probe.json):
-- a root Model, one "<Object>_Node" Model per GLB object, each holding one MeshPart named after the object (Body,
-- Body2, Glass, Trim, Interior, LightsFront, LightsRear, SirenRed, SirenBlue, Sign, WheelFL..). The geometry arrives
-- turned 180 degrees about Y (front at +Z) with identity part rotations; colours are dropped (grey Plastic); the
-- Trim / Interior / Wheel PBR sets become SurfaceAppearances; Lights / Sign base maps become TextureIDs.
--
-- prepare() does not assume any of that: it solves the import frame from the four wheel MeshParts against the spec's
-- wheel centres (yaw + translation + uniform scale), so a re-export with another convention still lands right. Every
-- MeshPart of a known role is moved into the BUILT POSE (ground y = 0, centred between the wheels, front -Z), made
-- non-colliding / anchored (it is a template) and parented directly under the template Model (WorldPivot identity).
-- Unknown parts, scripts, sounds, lights and GUIs are dropped. A template without its four wheels or its Body is
-- rejected (nil): CarBuilder then keeps the v1 procedural car for that vehicle.
--
-- Pure instance work except loadAll / waitFor (harness-friendly: tests hand prepare() fake imported trees).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = script.Parent.Parent
local Vehicles = require(Shared.Config.Vehicles)
local Signal = require(Shared.Util.Signal)

type Spec = Vehicles.Spec

local CarTemplates = {}

CarTemplates.FOLDER_NAME = "VehicleTemplates"
CarTemplates.LOAD_TIMEOUT = 25 -- seconds per asset before it is given up (the procedural car stays)
CarTemplates.MAX_PARALLEL = 4
CarTemplates.SCALE_TOLERANCE = 0.02 -- a solved scale this close to 1 is treated as exactly 1
-- MeshPart names a carpipe GLB can contain (anything else in an upload is dropped)
CarTemplates.ROLES = {
	Body = true,
	Body2 = true,
	Glass = true,
	Trim = true,
	Interior = true,
	LightsFront = true,
	LightsRear = true,
	SirenRed = true,
	SirenBlue = true,
	Sign = true,
} :: { [string]: boolean }
CarTemplates.MAIN_WHEELS = { "FL", "FR", "RL", "RR" }

CarTemplates.Ready = Signal.new() -- (vehicleId: string, template: Model)
CarTemplates.AllReady = Signal.new() -- ()

local KEEP_CLASSES = { "SurfaceAppearance" }

-- Is `name` a wheel MeshPart name ("WheelFL", "WheelML", "WheelMR2" ...)? Returns its key ("FL") or nil.
function CarTemplates.wheelKey(name: string): string?
	local key = string.match(name, "^Wheel(%u%u%d?)$")
	return key
end

-- The rigid transform (yaw about Y + translation + uniform scale) that maps the imported wheel positions onto the
-- spec's built-pose wheel part centres. `got` / `want` are keyed "FL", "FR", "RL", "RR". Returns (cframe, scale)
-- such that built = cframe * (scale * (imported - pivot)) + ... expressed as: builtPos = cf:PointToWorldSpace(
-- (importedPos - pivot) * scale) with `pivot` the imported wheel centroid; nil when the wheels are degenerate.
function CarTemplates.solveFrame(got: { [string]: Vector3 }, want: { [string]: Vector3 }): (CFrame?, number, Vector3)
	local gf, gr = (got.FL + got.FR) / 2, (got.RL + got.RR) / 2
	local wf, wr = (want.FL + want.FR) / 2, (want.RL + want.RR) / 2
	local gd = Vector3.new(gf.X - gr.X, 0, gf.Z - gr.Z)
	local wd = Vector3.new(wf.X - wr.X, 0, wf.Z - wr.Z)
	if gd.Magnitude < 1e-3 or wd.Magnitude < 1e-3 then
		return nil, 1, Vector3.zero
	end
	local scale = wd.Magnitude / gd.Magnitude
	if math.abs(scale - 1) <= CarTemplates.SCALE_TOLERANCE then
		scale = 1
	end
	-- yaw that turns the imported rear->front direction onto the spec's
	local yaw = math.atan2(-wd.X, -wd.Z) - math.atan2(-gd.X, -gd.Z)
	local gc = (gf + gr) / 2
	local wc = (wf + wr) / 2
	local rot = CFrame.Angles(0, yaw, 0)
	return CFrame.new(wc) * rot, scale, gc
end

local function strip(inst: Instance)
	for _, d in inst:GetDescendants() do
		if
			d:IsA("LuaSourceContainer")
			or d:IsA("Sound")
			or d:IsA("Light")
			or d:IsA("GuiBase3d")
			or d:IsA("LayerCollector")
			or d:IsA("ProximityPrompt")
			or d:IsA("ClickDetector")
			or d:IsA("JointInstance")
			or d:IsA("Constraint")
		then
			d:Destroy()
		end
	end
end

local function keepChildren(part: BasePart)
	for _, c in part:GetChildren() do
		local keep = false
		for _, cls in KEEP_CLASSES do
			if c:IsA(cls) then
				keep = true
			end
		end
		if not keep then
			c:Destroy()
		end
	end
end

-- Normalize an imported car (InsertService container, or any tree holding the MeshParts) into a template Model in the
-- built pose (see the header). Returns nil when the wheels or the Body are missing or degenerate.
function CarTemplates.prepare(raw: Instance, spec: Spec): Model?
	strip(raw)
	local byName: { [string]: BasePart } = {}
	for _, d in raw:GetDescendants() do
		if d:IsA("BasePart") and byName[d.Name] == nil then
			local key = CarTemplates.wheelKey(d.Name)
			if CarTemplates.ROLES[d.Name] or key then
				byName[d.Name] = d
			end
		end
	end
	if not byName.Body then
		return nil
	end
	local got: { [string]: Vector3 } = {}
	local want: { [string]: Vector3 } = {}
	local specWheels: { [string]: Vehicles.Wheel } = {}
	for _, w in spec.wheels do
		specWheels[w.key] = w
	end
	for _, key in CarTemplates.MAIN_WHEELS do
		local part = byName["Wheel" .. key]
		local sw = specWheels[key]
		if not part or not sw then
			return nil
		end
		got[key] = part.CFrame.Position
		want[key] = sw.partCenter
	end
	local frame, scale, pivot = CarTemplates.solveFrame(got, want)
	if not frame then
		return nil
	end

	local model = Instance.new("Model")
	model.Name = spec.id
	local names = {}
	for name in byName do
		table.insert(names, name)
	end
	table.sort(names) -- deterministic child order
	for _, name in names do
		local part = byName[name]
		local rel = part.CFrame
		local pos = frame:PointToWorldSpace((rel.Position - pivot) * scale)
		part.CFrame = CFrame.new(pos) * frame.Rotation * rel.Rotation
		if scale ~= 1 then
			part.Size *= scale
		end
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.CastShadow = true
		keepChildren(part)
		part.Parent = model
	end
	model.WorldPivot = CFrame.new()
	model:SetAttribute("Vehicle", spec.id)
	model:SetAttribute("TemplateScale", scale)
	if raw.Parent == nil and raw ~= model then
		raw:Destroy()
	end
	return model
end

-- The templates folder (created on the server by loadAll; clients find the replicated one). nil when absent.
function CarTemplates.folder(): Folder?
	local f = ReplicatedStorage:FindFirstChild(CarTemplates.FOLDER_NAME)
	if f and f:IsA("Folder") then
		return f
	end
	return nil
end

-- The ready template of a vehicle, or nil (not uploaded, still loading, failed, or the Lune harness).
function CarTemplates.get(vehicleId: string?): Model?
	if vehicleId == nil then
		return nil
	end
	local f = CarTemplates.folder()
	local t = f and f:FindFirstChild(vehicleId)
	if t and t:IsA("Model") and t:GetAttribute("Ready") == true then
		return t
	end
	return nil
end

-- Publish a prepared template (also used by tests to stand in for a load).
function CarTemplates.publish(vehicleId: string, template: Model): Model
	local f = CarTemplates.folder()
	if not f then
		local nf = Instance.new("Folder")
		nf.Name = CarTemplates.FOLDER_NAME
		nf.Parent = ReplicatedStorage
		f = nf
	end
	local old = (f :: Folder):FindFirstChild(vehicleId)
	if old and old ~= template then
		old:Destroy()
	end
	template.Name = vehicleId
	template:SetAttribute("Ready", true)
	template.Parent = f
	CarTemplates.Ready:Fire(vehicleId, template)
	return template
end

-- Server: load one vehicle's Model (yields). Returns the published template or nil.
function CarTemplates.load(spec: Spec): Model?
	if spec.assetId <= 0 then
		return nil
	end
	local done, raw = false, nil :: Instance?
	task.spawn(function()
		local ok, res = pcall(function()
			return game:GetService("InsertService"):LoadAsset(spec.assetId)
		end)
		if ok and typeof(res) == "Instance" then
			raw = res
		elseif not ok then
			warn(("[CarTemplates] %s (%d) failed to load: %s"):format(spec.id, spec.assetId, tostring(res)))
		end
		done = true
	end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < CarTemplates.LOAD_TIMEOUT do
		task.wait(0.1)
	end
	local container = raw
	if not container then
		warn(("[CarTemplates] %s unavailable; the procedural car stands in"):format(spec.id))
		return nil
	end
	local ok, model = pcall(CarTemplates.prepare, container, spec)
	if not ok or not model then
		warn(("[CarTemplates] %s: bad template (%s); the procedural car stands in"):format(spec.id, tostring(model)))
		return nil
	end
	return CarTemplates.publish(spec.id, model)
end

local loading = false
local allDone = false

-- Server: load every uploaded vehicle, MAX_PARALLEL at a time, in Vehicles.List order (call from a start() thread).
function CarTemplates.loadAll()
	if loading then
		return
	end
	loading = true
	local queue: { Spec } = {}
	for _, spec in Vehicles.List do
		if spec.assetId > 0 then
			table.insert(queue, spec)
		end
	end
	local nextIndex, running = 1, 0
	local finished = 0
	local function worker()
		while nextIndex <= #queue do
			local spec = queue[nextIndex]
			nextIndex += 1
			pcall(CarTemplates.load, spec)
			finished += 1
		end
		running -= 1
	end
	for _ = 1, math.min(CarTemplates.MAX_PARALLEL, #queue) do
		running += 1
		task.spawn(worker)
	end
	while running > 0 do
		task.wait(0.2)
	end
	allDone = true
	local f = CarTemplates.folder()
	if f then
		f:SetAttribute("AllReady", true)
	end
	CarTemplates.AllReady:Fire()
	print(("[CarTemplates] %d / %d car templates ready"):format(CarTemplates.readyCount(), #queue))
	return finished
end

function CarTemplates.isAllDone(): boolean
	return allDone
end

function CarTemplates.readyCount(): number
	local f = CarTemplates.folder()
	local n = 0
	if f then
		for _, c in f:GetChildren() do
			if c:IsA("Model") and c:GetAttribute("Ready") == true then
				n += 1
			end
		end
	end
	return n
end

return CarTemplates
