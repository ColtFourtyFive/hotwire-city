--!strict
-- Loads optional runtime art (Config/Assets) at boot, sanitizes and normalizes it, and publishes templates to
-- ReplicatedStorage.AssetLibrary.<Category>.<key> so both server and client builders can clone them.
--
-- Normalized template contract:
--   Model named <key>, PrimaryPart "AssetRoot" (invisible, anchored, 1x1x1) at the asset's bottom-center,
--   identity rotation; the asset's front faces -Z; scaled per its AssetDef; every BasePart Anchored=true,
--   CanCollide = def.collide or false, CanTouch=false, CanQuery = def.collide or false. No scripts/sounds/prompts.
-- Consumers: model:PivotTo(groundCFrame) places it standing on that point.

local AssetService = game:GetService("AssetService")
local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(ReplicatedStorage.Shared.Config.Assets)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local AssetLibrary = {}

AssetLibrary.Ready = Signal.new() -- (category: string, key: string, template: Model)
AssetLibrary.AllReady = Signal.new() -- ()

local root: Folder
local templates: { [string]: { [string]: Model } } = {}
local pending = 0
local allDone = false

local REMOVE_CLASSES = {
	"LuaSourceContainer",
	"Sound",
	"ProximityPrompt",
	"ClickDetector",
	"Humanoid",
	"Tool",
	"BillboardGui",
	"ScreenGui",
	"Explosion",
	"Fire",
	"Smoke",
	"ForceField",
	"BodyMover",
	"JointInstance",
	"Constraint",
	"Attachment",
	"Camera",
	"Configuration",
	"ValueBase",
	"Script",
}

local function sanitize(model: Instance)
	for _, d in model:GetDescendants() do
		local remove = false
		for _, cls in REMOVE_CLASSES do
			if d:IsA(cls) then
				remove = true
				break
			end
		end
		if remove then
			pcall(function()
				d:Destroy()
			end)
		end
	end
end

local function worldBounds(model: Instance): (Vector3?, Vector3?)
	local minV: Vector3? = nil
	local maxV: Vector3? = nil
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 1 then
			local cf, half = d.CFrame, d.Size / 2
			for sx = -1, 1, 2 do
				for sy = -1, 1, 2 do
					for sz = -1, 1, 2 do
						local w = cf * Vector3.new(half.X * sx, half.Y * sy, half.Z * sz)
						minV = if minV then minV:Min(w) else w
						maxV = if maxV then maxV:Max(w) else w
					end
				end
			end
		end
	end
	return minV, maxV
end

local function loadRaw(id: number, source: string): Instance?
	local function viaInsert(): Instance?
		local ok, result = pcall(function()
			return InsertService:LoadAsset(id)
		end)
		return if ok then result else nil
	end
	local function viaAssetService(): Instance?
		local ok, result = pcall(function()
			return (AssetService :: any):LoadAssetAsync(id)
		end)
		return if ok then result else nil
	end
	if source == "owned" then
		return viaInsert() or viaAssetService()
	end
	return viaAssetService() or viaInsert()
end

-- Turns a raw loaded container into a normalized template Model (or nil if it has no visible parts).
function AssetLibrary._normalize(raw: Instance, key: string, def: Assets.AssetDef): Model?
	sanitize(raw)
	local model = Instance.new("Model")
	model.Name = key
	for _, child in raw:GetChildren() do
		child.Parent = model
	end
	raw:Destroy()

	local parts = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
			d.Anchored = true
			d.CanCollide = def.collide == true
			d.CanQuery = def.collide == true
			d.CanTouch = false
			d.Massless = true
			d.CastShadow = def.castShadow ~= false
		end
	end
	if #parts == 0 then
		model:Destroy()
		return nil
	end

	-- root at bottom-center with identity rotation
	local minV, maxV = worldBounds(model)
	if not minV or not maxV then
		model:Destroy()
		return nil
	end
	local rootPart = Instance.new("Part")
	rootPart.Name = "AssetRoot"
	rootPart.Size = Vector3.one
	rootPart.Transparency = 1
	rootPart.Anchored = true
	rootPart.CanCollide = false
	rootPart.CanQuery = false
	rootPart.CanTouch = false
	local center = (minV + maxV) / 2
	rootPart.CFrame = CFrame.new(center.X, minV.Y, center.Z)
	rootPart.Parent = model
	model.PrimaryPart = rootPart

	-- orient so the front faces -Z, then re-center on the new bounds
	local yaw = math.rad(def.yaw or 0)
	model:PivotTo(CFrame.Angles(0, yaw, 0))
	minV, maxV = worldBounds(model)
	assert(minV and maxV, "asset has no visible parts after rotation")
	local size = maxV - minV
	local c2 = (minV + maxV) / 2
	-- move parts so the root sits exactly at the new bottom-center
	local offset = Vector3.new(-c2.X, -minV.Y, -c2.Z)
	for _, p in parts do
		p.CFrame = p.CFrame + offset
	end
	rootPart.CFrame = CFrame.new()

	local current: number
	if def.fit == "length" then
		current = math.max(size.Z, 0.01)
	elseif def.fit == "height" then
		current = math.max(size.Y, 0.01)
	elseif def.fit == "footprint" then
		current = math.max(size.X, size.Z, 0.01)
	else
		current = math.max(size.X, size.Y, size.Z, 0.01)
	end
	local factor = def.size / current
	if factor > 0 and math.abs(factor - 1) > 1e-3 then
		pcall(function()
			model:ScaleTo(model:GetScale() * factor)
		end)
	end
	model:SetAttribute("AssetKey", key)
	return model
end

local function category(name: string): Folder
	local f = root:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = root
	end
	return f :: Folder
end

local function loadEntry(cat: string, key: string, def: Assets.AssetDef)
	for _, id in def.ids do
		local raw: Instance? = nil
		local done = false
		task.spawn(function()
			raw = loadRaw(id, def.source)
			done = true
		end)
		local t0 = os.clock()
		while not done and os.clock() - t0 < Assets.LOAD_TIMEOUT do
			task.wait(0.1)
		end
		if raw then
			local ok, result = pcall(AssetLibrary._normalize, raw, key, def)
			if ok and result then
				result.Parent = category(cat)
				templates[cat] = templates[cat] or {}
				templates[cat][key] = result
				AssetLibrary.Ready:Fire(cat, key, result)
				return
			elseif not ok then
				warn(("[AssetLibrary] normalize %s/%s (%d) failed: %s"):format(cat, key, id, tostring(result)))
			end
		end
	end
	warn(("[AssetLibrary] %s/%s unavailable; using procedural fallback"):format(cat, key))
end

function AssetLibrary.init()
	local existing = ReplicatedStorage:FindFirstChild("AssetLibrary")
	if existing then
		root = existing :: Folder
	else
		root = Instance.new("Folder")
		root.Name = "AssetLibrary"
		root.Parent = ReplicatedStorage
	end
end

function AssetLibrary.start()
	local queue: { { cat: string, key: string, def: Assets.AssetDef } } = {}
	for key, def in Assets.Hero do
		table.insert(queue, { cat = "Hero", key = key, def = def })
	end
	for key, def in Assets.Props do
		table.insert(queue, { cat = "Props", key = key, def = def })
	end
	for key, def in Assets.Buildings do
		table.insert(queue, { cat = "Buildings", key = key, def = def })
	end
	pending = #queue
	local running = 0
	for _, item in queue do
		while running >= Assets.LOAD_CONCURRENCY do
			task.wait(0.05)
		end
		running += 1
		task.spawn(function()
			loadEntry(item.cat, item.key, item.def)
			running -= 1
			pending -= 1
		end)
	end
	while pending > 0 do
		task.wait(0.1)
	end
	allDone = true
	root:SetAttribute("AllReady", true)
	AssetLibrary.AllReady:Fire()
end

-- Template (do not modify) or nil when unavailable.
function AssetLibrary.get(cat: string, key: string): Model?
	local byCat = templates[cat]
	return byCat and byCat[key] or nil
end

-- A placed clone standing on groundCFrame (nil when unavailable).
function AssetLibrary.clone(cat: string, key: string, groundCFrame: CFrame?, parent: Instance?): Model?
	local template = AssetLibrary.get(cat, key)
	if not template then
		return nil
	end
	local c = template:Clone()
	if groundCFrame then
		c:PivotTo(groundCFrame)
	end
	if parent then
		c.Parent = parent
	end
	return c
end

function AssetLibrary.isAllReady(): boolean
	return allDone
end

-- Waits (yields) until every asset finished loading or `timeout` seconds pass.
function AssetLibrary.waitAll(timeout: number?): boolean
	local t0 = os.clock()
	while not allDone and os.clock() - t0 < (timeout or 30) do
		task.wait(0.1)
	end
	return allDone
end

return AssetLibrary
