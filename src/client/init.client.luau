--!strict
-- THE client entry point. Every controller is a ModuleScript in ./Controllers exposing optional init() and start().
-- Same two-phase boot as the server.

local Players = game:GetService("Players")

local ORDER = {
	"StateController",
	"AssetClient",
	"SoundController",
	"NotificationController",
	"HUDController",
	"MenuController",
	"PhoneController",
	"VehicleClient",
	"WheelAnimator",
	"GarageClient",
	"DealershipClient",
	"WaypointController",
	"MinimapController",
	"MapScreenController",
	"CombatClient",
	"EffectsController",
	"EventsClient",
	"TutorialController",
}

local controllersFolder = script:WaitForChild("Controllers")
local loaded: { { name: string, module: any } } = {}
local seen: { [string]: boolean } = {}

local function load(name: string)
	local moduleScript = controllersFolder:FindFirstChild(name)
	if not moduleScript or not moduleScript:IsA("ModuleScript") then
		warn("[Client] missing controller " .. name)
		return
	end
	local ok, result = pcall(require, moduleScript)
	if not ok then
		warn(("[Client] failed to require %s: %s"):format(name, tostring(result)))
		return
	end
	seen[name] = true
	table.insert(loaded, { name = name, module = result })
end

for _, name in ORDER do
	load(name)
end
local extras = {}
for _, child in controllersFolder:GetChildren() do
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
			warn(("[Client] %s.init failed: %s"):format(entry.name, tostring(err)))
		end
	end
end

for _, entry in loaded do
	local start = entry.module.start
	if typeof(start) == "function" then
		task.spawn(function()
			local ok, err = pcall(start)
			if not ok then
				warn(("[Client] %s.start failed: %s"):format(entry.name, tostring(err)))
			end
		end)
	end
end

print(("[Client] %s ready with %d controllers"):format(Players.LocalPlayer.Name, #loaded))
