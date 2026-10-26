--!strict
-- AdminService: developer/QA commands. Server-side admin check on EVERY call.
--
-- Admins: the experience owner (user games), the group owner (rank 255, group games), ADMIN_USER_IDS, and
-- everyone in Studio. Commands arrive through the AdminCommand remote and the TextChatService command
-- "/hc ..." (alias "/admin ..."). All calls into other systems are lazy requires wrapped in pcall.
--
--   help                          list commands
--   cash <n>                      add cash (1000, 2.5k, 3m, 1e9; negative removes). Not counted as earned.
--   car <carId> [mutation]        store a car in your garage (e.g. "car hyperion_x Gold")
--   spawn <carId> [mutation]      spawn a drivable loot car in front of you and seat you
--   give <player> <carId> [mut]   store a car in someone else's garage
--   wanted <0-5>                  set your wanted level
--   hotdrop                       force a Hot Drop now
--   event <rushhour|cashrain|doublecash|luck>
--   rebirth                       top up cash to the rebirth cost and rebirth
--   reset                         wipe your own data back to a new player (keeps purchase receipts)
--   slots <n>                     set unlocked garage slots
--   pass <key> [on|off|clear]     session-only gamepass override for testing
--   tp <poi>                      teleport to a point of interest (dealership, policehq, chopshop...)
--   tutorial                      replay the tutorial
--   save                          force-save your data

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage.Shared
local Cars = require(Shared.Config.Cars)
local Economy = require(Shared.Config.Economy)
local MapConfig = require(Shared.Config.Map)
local Monetization = require(Shared.Config.Monetization)
local Rarity = require(Shared.Config.Rarity)
local EconomyMath = require(Shared.Util.EconomyMath)
local Format = require(Shared.Util.Format)
local MapLayout = require(Shared.Util.MapLayout)
local Net = require(Shared.Net)

local DataService = require(script.Parent.DataService)

local AdminService = {}

-- Extra admins by UserId (e.g. co-developers / QA testers).
local ADMIN_USER_IDS: { [number]: boolean } = {}

local MAX_CASH_COMMAND = 1e15
local adminCache: { [Player]: boolean } = {}

---------------------------------------------------------------------------------------------------------------
-- Pure parsing helpers (tested)
---------------------------------------------------------------------------------------------------------------

local SUFFIX: { [string]: number } = { k = 1e3, m = 1e6, b = 1e9, t = 1e12, qa = 1e15 }

-- "1000" | "1,000" | "2.5k" | "3M" | "1e6" | "-500" -> number (nil if invalid / non-finite)
function AdminService._parseAmount(s: string?): number?
	if typeof(s) ~= "string" then
		return nil
	end
	local str = string.lower(string.gsub(s, ",", ""))
	local n = tonumber(str)
	if not n then
		local numPart, suffix = string.match(str, "^(%-?%d*%.?%d+)(%a+)$")
		local mult = suffix and SUFFIX[suffix]
		local base = numPart and tonumber(numPart)
		if base and mult then
			n = base * mult
		end
	end
	if not n or n ~= n or n == math.huge or n == -math.huge then
		return nil
	end
	return n
end

-- Splits "/hc car hyperion_x Gold" or "car hyperion_x Gold" into ("car", {"hyperion_x", "Gold"}).
function AdminService._parse(text: string): (string?, { string })
	local words = {}
	for word in string.gmatch(text, "%S+") do
		table.insert(words, word)
	end
	local first = words[1]
	if first then
		local lower = string.lower(first)
		if lower == "/hc" or lower == "/admin" or lower == "hc" then
			table.remove(words, 1)
		end
	end
	local cmd = words[1]
	if not cmd then
		return nil, {}
	end
	table.remove(words, 1)
	return string.lower((string.gsub(cmd, "^[/!:]", ""))), words
end

local function normalize(s: string): string
	return (string.gsub(string.lower(s), "[%s_%-]", ""))
end

-- Car id from an exact id, case-insensitive id/name ("Hyperion X"), or a unique prefix.
function AdminService._resolveCar(query: string?): string?
	if typeof(query) ~= "string" or query == "" then
		return nil
	end
	if Cars.get(query) then
		return query
	end
	local q = normalize(query)
	for _, def in Cars.List do
		if normalize(def.id) == q or normalize(def.name) == q then
			return def.id
		end
	end
	local match: string? = nil
	for _, def in Cars.List do
		if string.sub(normalize(def.id), 1, #q) == q or string.sub(normalize(def.name), 1, #q) == q then
			if match and match ~= def.id then
				return nil -- ambiguous
			end
			match = def.id
		end
	end
	return match
end

-- Mutation id (case-insensitive). nil input -> "None"; invalid -> nil.
function AdminService._resolveMutation(query: string?): Rarity.MutationId?
	if query == nil or query == "" then
		return "None"
	end
	local q = string.lower(query :: string)
	for _, id in Rarity.MutationOrder do
		if string.lower(id) == q then
			return id
		end
	end
	return nil
end

local EVENT_ALIASES: { [string]: string } = {
	rushhour = "rushHour",
	rush = "rushHour",
	cashrain = "cashRain",
	rain = "cashRain",
	doublecash = "doubleCash",
	double = "doubleCash",
	["2x"] = "doubleCash",
	x2 = "doubleCash",
	luck = "serverLuck",
	serverluck = "serverLuck",
	hotdrop = "hotDrop",
	drop = "hotDrop",
}

function AdminService._resolveEvent(query: string?): string?
	if typeof(query) ~= "string" then
		return nil
	end
	return EVENT_ALIASES[normalize(query)]
end

---------------------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------------------

local function trySystem(name: string): any
	local parent = script.Parent
	local mod = parent and parent:FindFirstChild(name)
	if not mod or not mod:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, mod)
	if ok and typeof(result) == "table" then
		return result
	end
	return nil
end

local function callSystem(name: string, fnName: string, ...: any): (boolean, ...any)
	local mod = trySystem(name)
	if not mod then
		return false, ("%s is not available"):format(name)
	end
	local fn = mod[fnName]
	if typeof(fn) ~= "function" then
		return false, ("%s.%s does not exist"):format(name, fnName)
	end
	return pcall(fn, ...)
end

-- Try a list of candidate function names on a system (for APIs the spec does not pin down).
local function callFirst(name: string, fnNames: { string }, ...: any): (boolean, string)
	local mod = trySystem(name)
	if not mod then
		return false, name .. " is not available"
	end
	for _, fnName in fnNames do
		local fn = mod[fnName]
		if typeof(fn) == "function" then
			local ok, err = pcall(fn, ...)
			if ok then
				return true, name .. "." .. fnName
			end
			return false, ("%s.%s failed: %s"):format(name, fnName, tostring(err))
		end
	end
	return false, ("%s has none of: %s"):format(name, table.concat(fnNames, ", "))
end

local function rootPart(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local groundParams: RaycastParams? = nil -- created on first use (cached)

local function groundInFront(player: Player, distance: number): CFrame?
	local root = rootPart(player)
	if not root then
		return nil
	end
	local look = root.CFrame.LookVector * Vector3.new(1, 0, 1)
	look = if look.Magnitude > 0.1 then look.Unit else Vector3.new(0, 0, -1)
	local exclude: { Instance } = {}
	if player.Character then
		table.insert(exclude, player.Character)
	end
	local vehicles = workspace:FindFirstChild("Vehicles")
	if vehicles then
		table.insert(exclude, vehicles)
	end
	local params = groundParams
	if not params then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.IgnoreWater = true
		groundParams = params
	end
	params.FilterDescendantsInstances = exclude
	local origin = root.Position + look * distance + Vector3.new(0, 12, 0)
	local hit = workspace:Raycast(origin, Vector3.new(0, -80, 0), params)
	local pos = if hit then hit.Position else root.Position + look * distance - Vector3.new(0, 3, 0)
	return CFrame.lookAt(pos, pos + look)
end

local function findPlayer(query: string, caller: Player): Player?
	local q = string.lower(query)
	if q == "me" then
		return caller
	end
	local prefixMatch: Player? = nil
	local ambiguous = false
	for _, p in Players:GetPlayers() do
		local n, d = string.lower(p.Name), string.lower(p.DisplayName)
		if n == q or d == q then
			return p
		end
		if string.sub(n, 1, #q) == q or string.sub(d, 1, #q) == q then
			if prefixMatch and prefixMatch ~= p then
				ambiguous = true
			end
			prefixMatch = p
		end
	end
	return if ambiguous then nil else prefixMatch
end

local function refreshGarage(player: Player)
	callSystem("GarageService", "refresh", player)
	DataService.markDirty(player)
end

local function storeCarFor(target: Player, carId: string, mutation: Rarity.MutationId): (boolean, string)
	local ok, stored, info = callSystem("GarageService", "storeCar", target, carId, mutation)
	if not ok then
		return false, "storeCar failed: " .. tostring(stored)
	end
	if stored ~= true then
		return false, "Garage full (" .. tostring(info) .. ")"
	end
	local data = DataService.get(target)
	if data then
		data.discovered[carId] = true
		DataService.markDirty(target)
	end
	local def = Cars.get(carId)
	local label = (if mutation ~= "None" then mutation .. " " else "") .. (if def then def.name else carId)
	return true, ("Stored %s in slot %s"):format(label, tostring(info))
end

---------------------------------------------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------------------------------------------

type Command = { usage: string, run: (Player, { string }) -> (boolean, string) }

local commands: { [string]: Command } = {}
local commandOrder: { string } = {}

local function command(name: string, usage: string, run: (Player, { string }) -> (boolean, string))
	commands[name] = { usage = usage, run = run }
	table.insert(commandOrder, name)
end

command("help", "help", function(_player, _args)
	local usages = {}
	for _, name in commandOrder do
		table.insert(usages, commands[name].usage)
	end
	return true, "/hc " .. table.concat(usages, " | ")
end)

command("cash", "cash <amount>", function(player, args)
	local amount = AdminService._parseAmount(args[1])
	if not amount or amount == 0 or math.abs(amount) > MAX_CASH_COMMAND then
		return false, "Usage: cash <amount> (e.g. 5000, 2.5m)"
	end
	local balance = DataService.addCash(player, amount, "admin")
	if not balance then
		return false, "Data not loaded"
	end
	return true, ("%s%s cash -> %s"):format(if amount > 0 then "+" else "", Format.cash(amount), Format.cash(balance))
end)

command("car", "car <carId> [mutation]", function(player, args)
	local carId = AdminService._resolveCar(args[1])
	if not carId then
		return false, "Unknown car '" .. tostring(args[1]) .. "'"
	end
	local mutation = AdminService._resolveMutation(args[2])
	if not mutation then
		return false, "Unknown mutation '" .. tostring(args[2]) .. "'"
	end
	return storeCarFor(player, carId, mutation)
end)

command("spawn", "spawn <carId> [mutation]", function(player, args)
	local carId = AdminService._resolveCar(args[1])
	if not carId then
		return false, "Unknown car '" .. tostring(args[1]) .. "'"
	end
	local mutation = AdminService._resolveMutation(args[2])
	if not mutation then
		return false, "Unknown mutation '" .. tostring(args[2]) .. "'"
	end
	local cf = groundInFront(player, 14)
	if not cf then
		return false, "No character"
	end
	local ok, car = callSystem("VehicleService", "spawn", carId, mutation, cf, "Loot", { ownerUserId = player.UserId })
	if not ok or typeof(car) ~= "table" then
		return false, "VehicleService.spawn failed: " .. tostring(car)
	end
	local okSeat, err = callSystem("VehicleService", "seat", car, player)
	if not okSeat then
		return true, "Spawned " .. carId .. " (could not seat you: " .. tostring(err) .. ")"
	end
	return true, "Spawned " .. carId .. " - drive it home to keep it!"
end)

command("give", "give <player> <carId> [mutation]", function(player, args)
	local target = args[1] and findPlayer(args[1], player)
	if not target then
		return false, "No unique player matches '" .. tostring(args[1]) .. "'"
	end
	if not DataService.isLoaded(target) then
		return false, target.Name .. "'s data is not loaded"
	end
	local carId = AdminService._resolveCar(args[2])
	if not carId then
		return false, "Unknown car '" .. tostring(args[2]) .. "'"
	end
	local mutation = AdminService._resolveMutation(args[3])
	if not mutation then
		return false, "Unknown mutation '" .. tostring(args[3]) .. "'"
	end
	local ok, msg = storeCarFor(target, carId, mutation)
	if ok and target ~= player then
		Net.fireClient("Notify", target, "success", "🎁 An admin gave you a " .. carId .. "!", 5)
	end
	return ok, target.Name .. ": " .. msg
end)

command("wanted", "wanted <0-5>", function(player, args)
	local n = AdminService._parseAmount(args[1])
	if not n or n < 0 or n > 5 or n % 1 ~= 0 then
		return false, "Usage: wanted <0-5>"
	end
	local okClear, err = callSystem("WantedService", "clear", player, "admin")
	if not okClear then
		return false, "WantedService.clear: " .. tostring(err)
	end
	if n > 0 then
		local okHeat, err2 = callSystem("WantedService", "addHeat", player, n, "admin")
		if not okHeat then
			return false, "WantedService.addHeat: " .. tostring(err2)
		end
	end
	return true, ("Wanted level set to %d"):format(n)
end)

local EVENT_FUNCTIONS: { [string]: { string } } = {
	hotDrop = { "forceHotDrop", "startHotDrop", "triggerHotDrop", "spawnHotDrop" },
	rushHour = { "startRushHour", "forceRushHour" },
	cashRain = { "startCashRain", "forceCashRain" },
	doubleCash = { "startDoubleCash", "forceDoubleCash" },
}
local GENERIC_EVENT_FUNCTIONS = { "startEvent", "forceEvent", "triggerEvent" }

local function runEvent(player: Player, eventName: string): (boolean, string)
	if eventName == "serverLuck" then
		local ok, err = callSystem("EventService", "activateServerLuck", player)
		return ok, if ok then "Server Luck x2 activated" else "activateServerLuck: " .. tostring(err)
	end
	local specific = EVENT_FUNCTIONS[eventName]
	if specific then
		local ok, used = callFirst("EventService", specific)
		if ok then
			return true, eventName .. " started via " .. used
		end
	end
	local ok, used = callFirst("EventService", GENERIC_EVENT_FUNCTIONS, eventName)
	if ok then
		return true, eventName .. " started via " .. used
	end
	return false, "Could not start " .. eventName .. " (" .. used .. ")"
end

command("hotdrop", "hotdrop", function(player, _args)
	return runEvent(player, "hotDrop")
end)

command("event", "event <rushhour|cashrain|doublecash|luck>", function(player, args)
	local eventName = AdminService._resolveEvent(args[1])
	if not eventName then
		return false, "Usage: event <rushhour|cashrain|doublecash|luck>"
	end
	return runEvent(player, eventName)
end)

command("rebirth", "rebirth", function(player, _args)
	local data = DataService.get(player)
	if not data or not DataService.isLoaded(player) then
		return false, "Data not loaded"
	end
	local cost = EconomyMath.rebirthCost(data.rebirths)
	if data.cash < cost then
		DataService.addCash(player, cost - data.cash, "admin")
	end
	local ok, used = callFirst("RebirthService", { "rebirth", "doRebirth", "performRebirth", "forceRebirth" }, player)
	if ok then
		return true, "Rebirthed via " .. used
	end
	return true, ("Cash topped up to %s - open the Rebirth menu to rebirth (%s)"):format(Format.cash(cost), used)
end)

command("reset", "reset", function(player, _args)
	if not DataService.resetData(player) then
		return false, "Data not loaded"
	end
	refreshGarage(player)
	task.spawn(DataService.saveNow, player)
	return true, "Your data was reset to a brand-new player"
end)

command("slots", "slots <n>", function(player, args)
	local n = AdminService._parseAmount(args[1])
	local maxSlots = Economy.MAX_SLOTS + Economy.PASS_EXTRA_SLOTS
	if not n or n % 1 ~= 0 or n < Economy.START_SLOTS or n > maxSlots then
		return false, ("Usage: slots <%d-%d>"):format(Economy.START_SLOTS, maxSlots)
	end
	local data = DataService.get(player)
	if not data then
		return false, "Data not loaded"
	end
	data.slotsUnlocked = n
	refreshGarage(player)
	return true, ("Unlocked slots set to %d"):format(n)
end)

command("pass", "pass <key> [on|off|clear]", function(player, args)
	local key = args[1] and string.lower(args[1])
	if not key or not Monetization.Passes[key] then
		return false, "Usage: pass <" .. table.concat(Monetization.PassOrder, "|") .. "> [on|off|clear]"
	end
	local mode = string.lower(args[2] or "on")
	local value: boolean? = if mode == "off" then false elseif mode == "clear" then nil else true
	local ok, err = callSystem("MonetizationService", "setPassOverride", player, key, value)
	if not ok then
		return false, "setPassOverride: " .. tostring(err)
	end
	return true, ("Pass %s -> %s (this session only)"):format(key, mode)
end)

command("tp", "tp <poi>", function(player, args)
	local q = args[1] and normalize(args[1])
	local root = rootPart(player)
	if not q or not root then
		return false, "Usage: tp <spawnplaza|dealership|policehq|gearshop|chopshop|stuntpark|park|pier|garage>"
	end
	local target: Vector3? = nil
	if q == "garage" or q == "home" then
		local plotIndex = player:GetAttribute("PlotIndex")
		if typeof(plotIndex) == "number" and MapConfig.Plots[plotIndex] then
			target = MapLayout.plotToWorld(plotIndex, MapConfig.Garage.OWNER_SPAWN).Position
		end
	else
		for name in MapConfig.Blocks do
			if normalize(name) == q or string.sub(normalize(name), 1, #q) == q then
				target = MapLayout.poiCenter(name)
				break
			end
		end
	end
	if not target then
		return false, "Unknown place '" .. args[1] .. "'"
	end
	local character = player.Character
	if character then
		character:PivotTo(CFrame.new(target + Vector3.new(0, 5, 0)))
	end
	return true, "Teleported to " .. args[1]
end)

command("tutorial", "tutorial", function(player, _args)
	local data = DataService.get(player)
	if not data then
		return false, "Data not loaded"
	end
	data.tutorialDone = false
	DataService.markDirty(player)
	return true, "Tutorial will replay (rejoin or it restarts if your client listens)"
end)

command("save", "save", function(player, _args)
	if DataService.isMemoryMode() then
		return true, "Studio in-memory mode: nothing to save"
	end
	local ok = DataService.saveNow(player)
	return ok, if ok then "Saved" else "Save failed (see server output)"
end)

---------------------------------------------------------------------------------------------------------------
-- Admin check + dispatch
---------------------------------------------------------------------------------------------------------------

-- True if this player may run admin commands. Server-side only; may yield once (group rank lookup).
function AdminService.isAdmin(player: Player): boolean
	if RunService:IsStudio() then
		return true
	end
	if ADMIN_USER_IDS[player.UserId] then
		return true
	end
	local cached = adminCache[player]
	if cached ~= nil then
		return cached
	end
	local result = false
	if game.CreatorType == Enum.CreatorType.User then
		result = player.UserId == game.CreatorId
	elseif game.CreatorType == Enum.CreatorType.Group then
		local ok, rank = pcall(function()
			return player:GetRankInGroup(game.CreatorId)
		end)
		if not ok then
			return false -- don't cache a failed lookup
		end
		result = rank == 255
	end
	adminCache[player] = result
	return result
end

-- Runs a command line for a player. Returns (ok, message). Non-admins always get (false, "").
function AdminService.run(player: Player, text: string): (boolean, string)
	if typeof(text) ~= "string" or #text == 0 or #text > 200 then
		return false, ""
	end
	if not AdminService.isAdmin(player) then
		return false, ""
	end
	local name, args = AdminService._parse(text)
	if not name then
		return false, "Type /hc help"
	end
	local cmd = commands[name]
	if not cmd then
		return false, "Unknown command '" .. name .. "'. Type /hc help"
	end
	print(("[Admin] %s (%d): %s"):format(player.Name, player.UserId, text))
	local ok, success, message = pcall(cmd.run, player, args)
	if not ok then
		return false, "Command error: " .. tostring(success)
	end
	return success, message
end

local function execute(player: Player, text: string)
	if player.Parent ~= Players then
		return
	end
	local ok, message = AdminService.run(player, text)
	if message ~= "" and player.Parent == Players then
		Net.fireClient("Notify", player, if ok then "success" else "error", message, if ok then 4 else 6)
	end
end

local function setupChatCommand()
	local ok, err = pcall(function()
		local existing = TextChatService:FindFirstChild("HotwireAdminCommand", true)
		if existing then
			existing:Destroy()
		end
		local cmd = Instance.new("TextChatCommand")
		cmd.Name = "HotwireAdminCommand"
		cmd.PrimaryAlias = "/hc"
		cmd.SecondaryAlias = "/admin"
		pcall(function()
			cmd.AutocompleteVisible = false
		end)
		cmd.Triggered:Connect(function(textSource: TextSource, unfilteredText: string)
			local player = Players:GetPlayerByUserId(textSource.UserId)
			if player then
				task.spawn(execute, player, unfilteredText)
			end
		end)
		local folder = TextChatService:FindFirstChild("TextChatCommands")
		cmd.Parent = folder or TextChatService
	end)
	if not ok then
		warn("[Admin] chat command unavailable: " .. tostring(err))
	end
end

function AdminService.init()
	Net.on("AdminCommand", function(player: Player, text: any)
		if not Net.isString(text, 200) then
			return
		end
		task.spawn(execute, player, text)
	end, 4)
end

function AdminService.start()
	setupChatCommand()
	Players.PlayerRemoving:Connect(function(player: Player)
		adminCache[player] = nil
	end)
end

return AdminService
