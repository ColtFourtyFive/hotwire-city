--!strict
-- Thin wrapper around the remotes listed in Shared/Remotes.
-- Server: Net.init() creates every remote; Net.on(name, handler, rateLimitPerSecond?) wraps handlers with
-- per-player rate limiting and pcall so one bad payload can never kill a system.
-- Client: Net.fire / Net.listen / Net.invoke.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = require(script.Parent.Remotes)

local IS_SERVER = RunService:IsServer()
local FOLDER_NAME = "Remotes"

local Net = {}

local folder: Folder? = nil
local events: { [string]: RemoteEvent } = {}
local functions: { [string]: RemoteFunction } = {}

local function getFolder(): Folder
	if folder then
		return folder
	end
	if IS_SERVER then
		local f = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if not f then
			f = Instance.new("Folder")
			f.Name = FOLDER_NAME
			f.Parent = ReplicatedStorage
		end
		folder = f :: Folder
	else
		folder = ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder
	end
	return folder :: Folder
end

local function getEvent(name: string): RemoteEvent
	local ev = events[name]
	if ev then
		return ev
	end
	local f = getFolder()
	local found = if IS_SERVER then f:FindFirstChild(name) else f:WaitForChild(name, 30)
	assert(found and found:IsA("RemoteEvent"), "Unknown RemoteEvent: " .. name)
	events[name] = found
	return found
end

local function getFunction(name: string): RemoteFunction
	local fn = functions[name]
	if fn then
		return fn
	end
	local f = getFolder()
	local found = if IS_SERVER then f:FindFirstChild(name) else f:WaitForChild(name, 30)
	assert(found and found:IsA("RemoteFunction"), "Unknown RemoteFunction: " .. name)
	functions[name] = found
	return found
end

-- SERVER ---------------------------------------------------------------------------------

-- Creates all remotes. Call once, first thing, from the server entry point.
function Net.init()
	assert(IS_SERVER, "Net.init is server-only")
	local f = getFolder()
	for _, list in { Remotes.ServerToClient, Remotes.ClientToServer } do
		for _, name in list do
			if not f:FindFirstChild(name) then
				local ev = Instance.new("RemoteEvent")
				ev.Name = name
				ev.Parent = f
			end
		end
	end
	for _, name in Remotes.Functions do
		if not f:FindFirstChild(name) then
			local fn = Instance.new("RemoteFunction")
			fn.Name = name
			fn.Parent = f
		end
	end
end

-- per-player, per-remote token buckets
local buckets: { [Player]: { [string]: { tokens: number, last: number } } } = {}

-- Bucket capacity: 2 seconds' worth, but never below 1 token so a sub-1/s rate can still fire.
function Net._bucketCap(perSecond: number): number
	return math.max(1, perSecond * 2)
end

local function allow(player: Player, name: string, perSecond: number): boolean
	local byPlayer = buckets[player]
	if not byPlayer then
		byPlayer = {}
		buckets[player] = byPlayer
	end
	local now = os.clock()
	local b = byPlayer[name]
	if not b then
		-- new buckets start with at least 1 token: the first call of any remote always goes through
		b = { tokens = math.max(1, perSecond), last = now }
		byPlayer[name] = b
	end
	b.tokens = math.min(Net._bucketCap(perSecond), b.tokens + (now - b.last) * perSecond)
	b.last = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end

if IS_SERVER then
	Players.PlayerRemoving:Connect(function(player)
		buckets[player] = nil
	end)
end

-- Listen to a client->server RemoteEvent. Handler gets (player, ...args). Args are UNTRUSTED.
function Net.on(name: string, handler: (Player, ...any) -> (), rateLimitPerSecond: number?)
	assert(IS_SERVER, "Net.on is server-only")
	local rate = rateLimitPerSecond or 8
	getEvent(name).OnServerEvent:Connect(function(player: Player, ...)
		if not allow(player, name, rate) then
			return
		end
		local ok, err = pcall(handler, player, ...)
		if not ok then
			warn(("[Net] handler %s errored for %s: %s"):format(name, player.Name, tostring(err)))
		end
	end)
end

-- Handle a RemoteFunction. Handler gets (player, ...args) and returns a value. Errors return nil.
function Net.handle(name: string, handler: (Player, ...any) -> any, rateLimitPerSecond: number?)
	assert(IS_SERVER, "Net.handle is server-only")
	local rate = rateLimitPerSecond or 4
	getFunction(name).OnServerInvoke = function(player: Player, ...)
		if not allow(player, name, rate) then
			return nil
		end
		local ok, result = pcall(handler, player, ...)
		if not ok then
			warn(("[Net] function %s errored for %s: %s"):format(name, player.Name, tostring(result)))
			return nil
		end
		return result
	end
end

function Net.fireClient(name: string, player: Player, ...: any)
	getEvent(name):FireClient(player, ...)
end

function Net.fireAll(name: string, ...: any)
	getEvent(name):FireAllClients(...)
end

function Net.fireAllExcept(name: string, except: Player, ...: any)
	local ev = getEvent(name)
	for _, p in Players:GetPlayers() do
		if p ~= except then
			ev:FireClient(p, ...)
		end
	end
end

-- Fire to every player whose character is within radius of position.
function Net.fireNear(name: string, position: Vector3, radius: number, ...: any)
	local ev = getEvent(name)
	for _, p in Players:GetPlayers() do
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and (root.Position - position).Magnitude <= radius then
			ev:FireClient(p, ...)
		end
	end
end

-- CLIENT ---------------------------------------------------------------------------------

function Net.fire(name: string, ...: any)
	assert(not IS_SERVER, "Net.fire is client-only")
	getEvent(name):FireServer(...)
end

function Net.listen(name: string, handler: (...any) -> ()): RBXScriptConnection
	assert(not IS_SERVER, "Net.listen is client-only")
	return getEvent(name).OnClientEvent:Connect(handler)
end

function Net.invoke(name: string, ...: any): any
	assert(not IS_SERVER, "Net.invoke is client-only")
	local fn = getFunction(name)
	local ok, result = pcall(fn.InvokeServer, fn, ...)
	if ok then
		return result
	end
	warn("[Net] invoke failed", name, result)
	return nil
end

-- VALIDATION HELPERS (server) -------------------------------------------------------------

function Net.isInt(v: any, min: number, max: number): boolean
	return typeof(v) == "number" and v == v and v % 1 == 0 and v >= min and v <= max
end

function Net.isString(v: any, maxLen: number): boolean
	return typeof(v) == "string" and #v <= maxLen
end

function Net.isFiniteVector(v: any): boolean
	if typeof(v) ~= "Vector3" then
		return false
	end
	local x, y, z = v.X, v.Y, v.Z
	return x == x and y == y and z == z and math.abs(x) < 1e5 and math.abs(y) < 1e5 and math.abs(z) < 1e5
end

return Net
