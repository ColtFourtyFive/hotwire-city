--!strict
-- AssetClient: the client half of the hero-shell late arrival (docs/ART_PASS.md AP1).
--   * Server-built cars are skinned on the server (CarBuilder.applyShell at build time, AssetLibrary.reskin when a
--     template loads later) and replicate as they are, so nothing here touches Workspace cars.
--   * Models built on this client (the Index detail-view preview; CarBuilder tags them CarBuilder.CLIENT_TAG
--     "ClientCar") are built before ReplicatedStorage.AssetLibrary.Hero.<key> may exist: when a Hero template
--     replicates in, every tagged model with that CarId that still has no shell gets CarBuilder.applyShell. Models
--     built with opts.noShell (attribute CarBuilder.NO_SHELL_ATTR: the Index card grid) stay procedural.
--   * Deferred signals: the template may still be mid-replication when ChildAdded runs, so a model that could not be
--     dressed yet is retried a few times.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CarBuilder = require(Shared:WaitForChild("Vehicle"):WaitForChild("CarBuilder"))

local AssetClient = {}

AssetClient.RETRY_DELAY = 1 -- seconds between attempts for a template that is not usable yet
AssetClient.MAX_ATTEMPTS = 4

local watchedHero: Instance? = nil
local scheduled: { [string]: boolean } = {}

-- Dress every client-built car with CarId `key` that has no shell yet. Returns (dressed, stillBare): stillBare counts
-- matching models applyShell could not dress (template not usable yet).
function AssetClient.reskin(key: string): (number, number)
	local dressed, bare = 0, 0
	for _, inst in CollectionService:GetTagged(CarBuilder.CLIENT_TAG) do
		if
			inst:IsA("Model")
			and inst.Parent ~= nil
			and inst:GetAttribute("HeroMesh") ~= true
			and inst:GetAttribute(CarBuilder.NO_SHELL_ATTR) ~= true
			and CarBuilder.shellKey(inst) == key
		then
			local ok, applied = pcall(CarBuilder.applyShell, inst)
			if ok and applied then
				dressed += 1
			else
				bare += 1
				if not ok then
					warn(("[AssetClient] re-skin %s failed: %s"):format(key, tostring(applied)))
				end
			end
		end
	end
	return dressed, bare
end

local function schedule(key: string)
	if scheduled[key] then
		return
	end
	scheduled[key] = true
	task.spawn(function()
		for attempt = 1, AssetClient.MAX_ATTEMPTS do
			local _, bare = AssetClient.reskin(key)
			if bare == 0 or attempt == AssetClient.MAX_ATTEMPTS then
				break
			end
			task.wait(AssetClient.RETRY_DELAY)
		end
		scheduled[key] = nil
	end)
end

local function watchHero(hero: Instance)
	if watchedHero then
		return
	end
	watchedHero = hero
	hero.ChildAdded:Connect(function(child: Instance)
		if child:IsA("Model") then
			schedule(child.Name)
		end
	end)
	-- templates that replicated before we connected (models built since then already wear them; this is cheap)
	for _, child in hero:GetChildren() do
		if child:IsA("Model") then
			schedule(child.Name)
		end
	end
end

local function watchRoot(root: Instance)
	local hero = root:FindFirstChild("Hero")
	if hero then
		watchHero(hero)
		return
	end
	local conn: RBXScriptConnection? = nil
	conn = root.ChildAdded:Connect(function(child: Instance)
		if child.Name == "Hero" then
			if conn then
				conn:Disconnect()
				conn = nil
			end
			watchHero(child)
		end
	end)
end

function AssetClient.init() end

function AssetClient.start()
	local root = ReplicatedStorage:FindFirstChild("AssetLibrary")
	if root then
		watchRoot(root)
		return
	end
	local conn: RBXScriptConnection? = nil
	conn = ReplicatedStorage.ChildAdded:Connect(function(child: Instance)
		if child.Name == "AssetLibrary" then
			if conn then
				conn:Disconnect()
				conn = nil
			end
			watchRoot(child)
		end
	end)
end

return AssetClient
