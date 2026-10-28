--!strict
-- THE server entry point. Every system is a ModuleScript in ./Systems exposing optional init() and start().
-- Phase 1: init() runs synchronously for every system in ORDER (create instances, connect signals).
-- Phase 2: start() runs for every system in its own thread (loops, PlayerAdded handling).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)

-- Explicit order: world first, data second, then everything that depends on them.
local ORDER = {
	"MapBuilder",
	"AssetLibrary",
	"MapDresser",
	"LightingService",
	"DataService",
	"AppearanceService", -- C4a characters: realistic player looks (own DataStore HC_Appearance_v1), creator studio
	"MonetizationService",
	"PlotService",
	"VehicleService",
	"GarageService",
	"WantedService",
	"PoliceService",
	"TheftService",
	"DealershipService",
	"StreetSpawnService",
	"TrafficService",
	"NPCService",
	"CombatService",
	"HitboxHistory", -- combat v2 (gta_combat §13): lag-compensation history
	"DamageService", -- health / armor authority, PvP rules, WASTED
	"FootService", -- C4a characters: fall damage + brief ragdoll on big falls
	"WeaponService", -- inventory, tools, shot validation, melee
	"PoliceCombatService", -- on-foot officers, firing director, roadblocks
	"EventService",
	"RewardsService",
	"RebirthService",
	"ShopService",
	"LeaderboardService",
	"AdminService",
	"VehicleFxService",
}

Net.init()

local systemsFolder = script:WaitForChild("Systems")
local loaded: { { name: string, module: any } } = {}
local seen: { [string]: boolean } = {}

local function load(name: string)
	local moduleScript = systemsFolder:FindFirstChild(name)
	if not moduleScript or not moduleScript:IsA("ModuleScript") then
		warn("[Server] missing system " .. name)
		return
	end
	local ok, result = pcall(require, moduleScript)
	if not ok then
		warn(("[Server] failed to require %s: %s"):format(name, tostring(result)))
		return
	end
	seen[name] = true
	table.insert(loaded, { name = name, module = result })
end

for _, name in ORDER do
	load(name)
end
-- any extra systems not in ORDER load last (alphabetical for determinism)
local extras = {}
for _, child in systemsFolder:GetChildren() do
	if child:IsA("ModuleScript") and not seen[child.Name] then
		table.insert(extras, child.Name)
	end
end
table.sort(extras)
for _, name in extras do
	load(name)
end

for _, entry in loaded do
	local init = entry.module.init
	if typeof(init) == "function" then
		local ok, err = pcall(init)
		if not ok then
			warn(("[Server] %s.init failed: %s"):format(entry.name, tostring(err)))
		end
	end
end

for _, entry in loaded do
	local start = entry.module.start
	if typeof(start) == "function" then
		task.spawn(function()
			local ok, err = pcall(start)
			if not ok then
				warn(("[Server] %s.start failed: %s"):format(entry.name, tostring(err)))
			end
		end)
	end
end

print(("[Server] Hotwire City booted with %d systems"):format(#loaded))
