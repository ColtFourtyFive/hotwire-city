--!nocheck
-- Lune test harness: runs game ModuleScripts outside Roblox.
-- Emulates the Rojo tree (`script`, `script.Parent.X`, `game:GetService("ReplicatedStorage").Shared`) from the
-- filesystem, provides Roblox datatypes via @lune/roblox, and shims a few engine APIs Lune lacks
-- (Model:PivotTo/GetPivot, Random, TweenInfo, CollectionService, RunService, Players...).
-- Usage (from repo root):  lune run tests/run.luau

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

local Harness = {}

-- Random shim (xorshift-ish, deterministic) ----------------------------------------------------------------
local RandomShim = {}
RandomShim.__index = RandomShim
function RandomShim.new(seed: number?)
	local s = math.floor(seed or os.clock() * 1e6) % 2147483647
	if s <= 0 then
		s = s + 2147483646
	end
	return setmetatable({ _s = s }, RandomShim)
end
function RandomShim:_next(): number
	self._s = (self._s * 16807) % 2147483647
	return self._s / 2147483647
end
function RandomShim:NextNumber(min: number?, max: number?): number
	local r = self:_next()
	if min and max then
		return min + (max - min) * r
	end
	return r
end
function RandomShim:NextInteger(min: number, max: number): number
	return min + math.floor(self:_next() * (max - min + 1))
end
function RandomShim:NextUnitVector()
	return roblox.Vector3.new(self:NextNumber(-1, 1), self:NextNumber(-1, 1), self:NextNumber(-1, 1)).Unit
end

local function TweenInfoShim(...)
	return { args = { ... } }
end

-- Engine method shims on Lune instances -------------------------------------------------------------------
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

local function partsOf(inst)
	local out = {}
	if inst:IsA("BasePart") then
		table.insert(out, inst)
	end
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(out, d)
		end
	end
	return out
end

pcall(roblox.implementMethod, "Model", "GetPivot", function(self)
	if self.PrimaryPart then
		return self.PrimaryPart.CFrame
	end
	local ok, wp = pcall(function()
		return self.WorldPivot
	end)
	if ok and wp then
		return wp
	end
	local parts = partsOf(self)
	if #parts > 0 then
		return parts[1].CFrame
	end
	return CFrame.new()
end)
pcall(roblox.implementMethod, "Model", "PivotTo", function(self, target)
	local current = self:GetPivot()
	local delta = target * current:Inverse()
	for _, p in partsOf(self) do
		p.CFrame = delta * p.CFrame
	end
	pcall(function()
		self.WorldPivot = target
	end)
end)
pcall(roblox.implementMethod, "BasePart", "GetPivot", function(self)
	return self.CFrame
end)
pcall(roblox.implementMethod, "BasePart", "PivotTo", function(self, target)
	self.CFrame = target
end)
pcall(roblox.implementMethod, "Model", "GetExtentsSize", function(self)
	local minV, maxV
	for _, p in partsOf(self) do
		local half = p.Size / 2
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local w = p.CFrame * Vector3.new(half.X * sx, half.Y * sy, half.Z * sz)
					minV = if minV then minV:Min(w) else w
					maxV = if maxV then maxV:Max(w) else w
				end
			end
		end
	end
	if not minV then
		return Vector3.zero
	end
	return maxV - minV
end)
pcall(roblox.implementMethod, "Model", "GetBoundingBox", function(self)
	local size = self:GetExtentsSize()
	return self:GetPivot(), size
end)
-- recorded terrain ops (no-op)
Harness.terrainOps = {}
for _, m in { "FillBlock", "FillBall", "FillCylinder", "FillWedge", "FillRegion" } do
	pcall(roblox.implementMethod, "Terrain", m, function(_self, ...)
		table.insert(Harness.terrainOps, { m, ... })
	end)
end
-- voxel writes are counted, not kept (MapBuilder v2 writes thousands of chunks)
Harness.voxelWrites = 0
pcall(roblox.implementMethod, "Terrain", "WriteVoxels", function()
	Harness.voxelWrites += 1
end)
pcall(roblox.implementMethod, "Terrain", "Clear", function()
	table.clear(Harness.terrainOps)
	Harness.voxelWrites = 0
end)
pcall(roblox.implementMethod, "Instance", "WaitForChild", function(self, name)
	return self:FindFirstChild(name)
end)
pcall(roblox.implementMethod, "BasePart", "SetNetworkOwner", function() end)
pcall(roblox.implementMethod, "BasePart", "SetNetworkOwnershipAuto", function() end)
pcall(roblox.implementMethod, "BasePart", "ApplyImpulse", function() end)
pcall(roblox.implementMethod, "BasePart", "ApplyImpulseAtPosition", function() end)
pcall(roblox.implementMethod, "BasePart", "ApplyAngularImpulse", function() end)
pcall(roblox.implementMethod, "Seat", "Sit", function() end)
pcall(roblox.implementMethod, "VehicleSeat", "Sit", function() end)
pcall(roblox.implementMethod, "Workspace", "GetServerTimeNow", function()
	return os.time()
end)

-- Fake services -----------------------------------------------------------------------------------------------
local game = roblox.Instance.new("DataModel")
Harness.game = game
local workspaceInst = game:GetService("Workspace")
pcall(function()
	local terrain = roblox.Instance.new("Terrain")
	terrain.Parent = workspaceInst
end)

-- MaterialService: Lune has no Get/SetBaseMaterialOverride. The stub behaves like the real engine of job 0009: with
-- no override set, GetBaseMaterialOverride reads back the STOCK material name (the place file's <Material>Name
-- properties are NOT honoured), SetBaseMaterialOverride with any name does not error (engine probe 2026-10-27).
-- Tests can inspect / reset Harness.materialOverrides (base material name -> variant) and make the next Set calls fail
-- with Harness.materialOverrideError. The place file's MaterialVariants (default.project.json) are created as Rojo
-- builds them (name + BaseMaterial), so Util/MaterialOverrides finds them.
Harness.materialOverrides = {}
Harness.materialOverrideError = nil
pcall(roblox.implementMethod, "MaterialService", "GetBaseMaterialOverride", function(_self, material)
	return Harness.materialOverrides[material.Name] or material.Name
end)
pcall(roblox.implementMethod, "MaterialService", "SetBaseMaterialOverride", function(_self, material, name)
	if Harness.materialOverrideError then
		error(Harness.materialOverrideError)
	end
	Harness.materialOverrides[material.Name] = name
end)
do
	local serde = require("@lune/serde")
	local ok, project = pcall(function()
		return serde.decode("json", fs.readFile("default.project.json"))
	end)
	local msNode = ok and project.tree and project.tree.MaterialService
	if msNode then
		local ms = game:GetService("MaterialService")
		for name, node in msNode do
			if type(node) == "table" and node["$className"] == "MaterialVariant" then
				local v = roblox.Instance.new("MaterialVariant")
				v.Name = name
				pcall(function()
					v.BaseMaterial = (roblox.Enum.Material :: any)[node["$properties"].BaseMaterial]
				end)
				v.Parent = ms
			end
		end
	end
end

local function makeSignal()
	local handlers = {}
	return {
		Connect = function(_, fn)
			table.insert(handlers, fn)
			return { Disconnect = function() end, Connected = true }
		end,
		Once = function(_, fn)
			table.insert(handlers, fn)
			return { Disconnect = function() end, Connected = true }
		end,
		Wait = function() end,
		Fire = function(_, ...)
			for _, h in handlers do
				h(...)
			end
		end,
	}
end

local CollectionServiceShim = {
	AddTag = function(_, inst, tag)
		inst:AddTag(tag)
	end,
	RemoveTag = function(_, inst, tag)
		inst:RemoveTag(tag)
	end,
	HasTag = function(_, inst, tag)
		return inst:HasTag(tag)
	end,
	GetTagged = function(_, tag)
		local out = {}
		for _, d in game:GetDescendants() do
			if d:HasTag(tag) then
				table.insert(out, d)
			end
		end
		return out
	end,
	GetInstanceAddedSignal = function()
		return makeSignal()
	end,
	GetInstanceRemovedSignal = function()
		return makeSignal()
	end,
}

local RunServiceShim = {
	IsServer = function()
		return Harness.isServer
	end,
	IsClient = function()
		return not Harness.isServer
	end,
	IsStudio = function()
		return true
	end,
	Heartbeat = makeSignal(),
	PreSimulation = makeSignal(),
	PostSimulation = makeSignal(),
	PreRender = makeSignal(),
	RenderStepped = makeSignal(),
	Stepped = makeSignal(),
}

local PlayersShim = {
	PlayerAdded = makeSignal(),
	PlayerRemoving = makeSignal(),
	GetPlayers = function()
		return {}
	end,
	LocalPlayer = nil,
}

local TweenServiceShim = {
	Create = function()
		return { Play = function() end, Cancel = function() end, Completed = makeSignal() }
	end,
}

Harness.isServer = true

-- "Magic" stub: any member access returns another stub, calls return stubs, Connect returns a connection.
-- Lets modules that touch engine services at require-time load headlessly.
local function magic(label: string)
	local t = {}
	return setmetatable(t, {
		__index = function(_, k)
			if k == "Connect" or k == "Once" or k == "ConnectParallel" then
				return function()
					return { Disconnect = function() end, Connected = true }
				end
			elseif k == "Wait" then
				return function() end
			end
			local child = magic(label .. "." .. tostring(k))
			rawset(t, k, child)
			return child
		end,
		__call = function()
			return magic(label .. "()")
		end,
		__tostring = function()
			return "Magic(" .. label .. ")"
		end,
	})
end
Harness.magic = magic
local MAGIC_SERVICES = {
	"DataStoreService",
	"MarketplaceService",
	"UserInputService",
	"ContextActionService",
	"TextChatService",
	"ProximityPromptService",
	"ContentProvider",
	"AssetService",
	"GuiService",
	"PhysicsService",
	"SocialService",
	"PolicyService",
	"GroupService",
	"MessagingService",
	"MemoryStoreService",
	"BadgeService",
	"InsertService",
	"HttpService",
	"Debris",
	"StarterGui",
	"TeleportService",
	"PathfindingService",
	"VRService",
	"HapticService",
	"Chat",
	"AnalyticsService",
	"LocalizationService",
	"StarterPlayer",
	"ServerStorage",
	"ServerScriptService",
}

-- Virtual Rojo tree ----------------------------------------------------------------------------------------------
local ROOT = (function()
	-- repo root = parent of tests/
	local cwd = process and process.cwd or "."
	return "."
end)()

local nodeCache = {}
local moduleCache = {}

local NodeMT = {}

local function makeNode(path: string, name: string, kind: string, parent)
	local key = path
	if nodeCache[key] then
		return nodeCache[key]
	end
	local node = setmetatable({ __path = path, __name = name, __kind = kind, __parent = parent }, NodeMT)
	nodeCache[key] = node
	return node
end

-- Preload the whole src tree synchronously (Lune fs calls yield, which is illegal inside metamethods).
local FILES: { [string]: string } = {}
local DIRS: { [string]: { string } } = {}
local function scan(dir: string)
	local entries = fs.readDir(dir)
	table.sort(entries)
	DIRS[dir] = entries
	for _, e in entries do
		local p = dir .. "/" .. e
		if fs.isDir(p) then
			scan(p)
		elseif e:match("%.luau?$") then
			FILES[p] = fs.readFile(p)
		end
	end
end
scan(ROOT .. "/src")

local function isFile(p: string): boolean
	return FILES[p] ~= nil
end
local function isDir(p: string): boolean
	return DIRS[p] ~= nil
end

local function childOf(node, name: string)
	local base = rawget(node, "__path")
	local kind = rawget(node, "__kind")
	if kind == "file" then
		return nil
	end
	local dir = base
	for _, ext in { ".luau", ".lua" } do
		local p = dir .. "/" .. name .. ext
		if isFile(p) then
			return makeNode(p, name, "file", node)
		end
	end
	local d = dir .. "/" .. name
	if isDir(d) then
		if isFile(d .. "/init.luau") then
			return makeNode(d, name, "initdir", node)
		end
		return makeNode(d, name, "dir", node)
	end
	return nil
end

NodeMT.__index = function(node, key)
	if key == "Parent" then
		return rawget(node, "__parent")
	elseif key == "Name" then
		return rawget(node, "__name")
	elseif key == "WaitForChild" or key == "FindFirstChild" then
		return function(self, name)
			return childOf(self, name)
		end
	elseif key == "IsA" then
		return function(self, cls)
			local k = rawget(self, "__kind")
			if cls == "ModuleScript" then
				return k == "file" or k == "initdir"
			elseif cls == "Folder" then
				return k == "dir"
			end
			return false
		end
	elseif key == "GetChildren" then
		return function(self)
			local out = {}
			local k = rawget(self, "__kind")
			if k == "file" then
				return out
			end
			for _, entry in DIRS[rawget(self, "__path")] or {} do
				local nm = entry:gsub("%.luau$", ""):gsub("%.lua$", "")
				if nm ~= "init" and not nm:find("%.server$") and not nm:find("%.client$") then
					local c = childOf(self, nm)
					if c then
						table.insert(out, c)
					end
				end
			end
			return out
		end
	end
	local c = childOf(node, key)
	if c == nil then
		error(("%s is not a valid member of %s"):format(tostring(key), rawget(node, "__path")), 2)
	end
	return c
end
NodeMT.__tostring = function(node)
	return "Node(" .. rawget(node, "__path") .. ")"
end

local sharedNode = makeNode(ROOT .. "/src/shared", "Shared", "dir", nil)
local serverNode = makeNode(ROOT .. "/src/server", "Server", "dir", nil)
local clientNode = makeNode(ROOT .. "/src/client", "Client", "dir", nil)

-- Extra ReplicatedStorage children a test can install, name -> Instance (e.g. a fake AssetLibrary template folder:
-- Harness.replicated.AssetLibrary = folder). Clear the entry when done.
Harness.replicated = {}

local ReplicatedStorageShim = setmetatable({}, {
	__index = function(_, k)
		if k == "Shared" then
			return sharedNode
		elseif k == "WaitForChild" or k == "FindFirstChild" then
			return function(_, name)
				if name == "Shared" then
					return sharedNode
				end
				return Harness.replicated[name]
			end
		end
		return Harness.replicated[k]
	end,
})

-- ServerScriptService.Server = the src/server tree (e.g. Config/WorldLayout's server-only data); anything else is magic.
local sssMagic = magic("ServerScriptService")
local ServerScriptServiceShim = setmetatable({}, {
	__index = function(_, k)
		if k == "Server" then
			return serverNode
		elseif k == "WaitForChild" or k == "FindFirstChild" then
			return function(_, name)
				if name == "Server" then
					return serverNode
				end
				return nil
			end
		end
		return sssMagic[k]
	end,
})

local services = {
	ReplicatedStorage = ReplicatedStorageShim,
	ServerScriptService = ServerScriptServiceShim,
	CollectionService = CollectionServiceShim,
	RunService = RunServiceShim,
	Players = PlayersShim,
	TweenService = TweenServiceShim,
}

for _, name in MAGIC_SERVICES do
	if services[name] == nil then
		services[name] = magic(name)
	end
end

-- client-mode LocalPlayer
local localPlayer = roblox.Instance.new("Player")
localPlayer.Name = "HarnessPlayer"
for _, cls in { "PlayerGui", "Backpack", "PlayerScripts" } do
	local c = roblox.Instance.new(cls)
	c.Parent = localPlayer
end
Harness.localPlayer = localPlayer

-- Switch between server and client emulation (clears the module cache).
function Harness.setMode(mode: string)
	Harness.isServer = mode == "server"
	PlayersShim.LocalPlayer = if mode == "client" then localPlayer else nil
	table.clear(moduleCache)
end

local gameProxy = setmetatable({}, {
	__index = function(_, k)
		if k == "GetService" then
			return function(_, name)
				if services[name] then
					return services[name]
				end
				return game:GetService(name)
			end
		elseif k == "Workspace" then
			return workspaceInst
		end
		return (game :: any)[k]
	end,
})

local requireNode

local function makeEnv(node)
	local env = {
		script = node,
		game = gameProxy,
		workspace = workspaceInst,
		Instance = roblox.Instance,
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		BrickColor = roblox.BrickColor,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
		Enum = roblox.Enum,
		Font = roblox.Font,
		Rect = roblox.Rect,
		Ray = roblox.Ray,
		Region3 = roblox.Region3,
		NumberRange = roblox.NumberRange,
		NumberSequence = roblox.NumberSequence,
		NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
		ColorSequence = roblox.ColorSequence,
		ColorSequenceKeypoint = roblox.ColorSequenceKeypoint,
		PhysicalProperties = roblox.PhysicalProperties,
		RaycastParams = roblox.RaycastParams,
		OverlapParams = roblox.OverlapParams,
		Faces = roblox.Faces,
		Axes = roblox.Axes,
		TweenInfo = { new = TweenInfoShim },
		Random = RandomShim,
		task = task,
		typeof = typeof,
		require = function(target)
			return requireNode(target)
		end,
		warn = function(...)
			print("[warn]", ...)
		end,
		tick = os.clock,
	}
	return setmetatable(env, { __index = _G })
end

function requireNode(node)
	if type(node) ~= "table" or getmetatable(node) ~= NodeMT then
		error("harness require: expected a module node, got " .. tostring(node))
	end
	local path = rawget(node, "__path")
	local kind = rawget(node, "__kind")
	local file = if kind == "initdir" then path .. "/init.luau" else path
	if moduleCache[file] ~= nil then
		return moduleCache[file]
	end
	local source = FILES[file]
	if not source then
		error("harness: no such module file " .. file)
	end
	local chunk = luau.load(source, { debugName = file, environment = makeEnv(node) })
	local result = chunk()
	moduleCache[file] = result
	return result
end

-- Public API -------------------------------------------------------------------------------------------------------
Harness.shared = sharedNode
Harness.server = serverNode
Harness.client = clientNode
Harness.roblox = roblox
Harness.workspace = workspaceInst
Harness.Random = RandomShim

-- require by slash path relative to repo root, e.g. Harness.require("src/shared/Util/Format")
function Harness.require(relPath: string)
	local parts = string.split(relPath, "/")
	local node
	if parts[1] == "src" and parts[2] == "shared" then
		node = sharedNode
	elseif parts[1] == "src" and parts[2] == "server" then
		node = serverNode
	elseif parts[1] == "src" and parts[2] == "client" then
		node = clientNode
	else
		error("path must start with src/shared, src/server or src/client")
	end
	for i = 3, #parts do
		node = (node :: any)[parts[i]]
	end
	return requireNode(node)
end

-- Serialize every BasePart under `root` to a JSON-able list (for tools/render.py).
function Harness.dumpParts(root): { any }
	local out = {}
	for _, p in partsOf(root) do
		local cf = p.CFrame
		local c = { cf:GetComponents() }
		local shape = "Block"
		if p:IsA("Part") then
			shape = p.Shape.Name
		elseif p:IsA("WedgePart") then
			shape = "Wedge"
		elseif p:IsA("CornerWedgePart") then
			shape = "CornerWedge"
		elseif p:IsA("TrussPart") then
			shape = "Block"
		end
		table.insert(out, {
			name = p.Name,
			shape = shape,
			size = { p.Size.X, p.Size.Y, p.Size.Z },
			cframe = c,
			color = { math.floor(p.Color.R * 255), math.floor(p.Color.G * 255), math.floor(p.Color.B * 255) },
			transparency = p.Transparency,
			material = p.Material.Name,
			canCollide = p.CanCollide,
		})
	end
	return out
end

return Harness
