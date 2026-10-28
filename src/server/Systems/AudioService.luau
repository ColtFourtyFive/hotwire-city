--!strict
-- AudioService (PLAN C3 · audio): the only server part of the audio package. Purely cosmetic.
--
-- * RadioTune(station: string) from a driver's client (Audio/Radio): the station their car radio settled on, "" for
--   off. Validated: a string of at most 32 chars, "" or a real station name (Shared/Audio/RadioDial.buildStations over
--   Config/Sounds), the sender drives a live car (VehicleService.getDriving, lazy), Net rate limit RATE/s. Writes the
--   car model's "RadioStation" attribute (cleared for "" / off); other clients play a muffled copy of that station
--   near the car on the shared station clock.
-- * Sweep every SWEEP s: a driver who left the car / switched cars / left the game has the attribute cleared, so a
--   parked car never keeps playing for passers-by.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Sounds = require(Shared:WaitForChild("Config"):WaitForChild("Sounds"))
local RadioDial = require(Shared:WaitForChild("Audio"):WaitForChild("RadioDial"))

local AudioService = {}

AudioService.RATE = 4 -- RadioTune per second per player (the client sends once per settled station)
AudioService.SWEEP = 1
AudioService.ATTRIBUTE = "RadioStation"

local stations = RadioDial.buildStations(Sounds :: any)
local tuned: { [Player]: Model } = {} -- the car whose attribute this player set

-- Test seam (Lune harness): fake VehicleService.getDriving.
local hooks: { getDriving: ((Player) -> any)? } = { getDriving = nil }
function AudioService._setHooks(overrides: { [string]: any }?)
	hooks.getDriving = if overrides then overrides.getDriving else nil
	table.clear(tuned)
end

local vehicleService: any = nil
local function getDriving(player: Player): any
	if hooks.getDriving then
		return hooks.getDriving(player)
	end
	if vehicleService == nil then
		local ms = script.Parent and script.Parent:FindFirstChild("VehicleService")
		local ok, mod = false, nil
		if ms and ms:IsA("ModuleScript") then
			ok, mod = pcall(require, ms)
		end
		vehicleService = if ok and type(mod) == "table" then mod else false
	end
	local vs = vehicleService
	if not vs or type(vs.getDriving) ~= "function" then
		return nil
	end
	local ok, car = pcall(vs.getDriving, player)
	return if ok then car else nil
end

-- The live car model this player drives, or nil.
local function drivenModel(player: Player): Model?
	local car = getDriving(player)
	if type(car) ~= "table" or car.destroyed or car.driver ~= player then
		return nil
	end
	local model = car.model
	if typeof(model) ~= "Instance" or not model:IsA("Model") or model.Parent == nil then
		return nil
	end
	return model
end

-- Is `name` an acceptable RadioTune payload? ("" = off, else a station name.)
function AudioService.validStation(name: any): boolean
	if not Net.isString(name, 32) then
		return false
	end
	return name == "" or RadioDial.find(stations, name) ~= nil
end

local function clear(player: Player)
	local model = tuned[player]
	tuned[player] = nil
	if model and model:GetAttribute(AudioService.ATTRIBUTE) ~= nil then
		model:SetAttribute(AudioService.ATTRIBUTE, nil)
	end
end

local function onRadioTune(player: Player, name: any)
	if not AudioService.validStation(name) then
		return
	end
	local model = drivenModel(player)
	if not model then
		return
	end
	local previous = tuned[player]
	if previous and previous ~= model then
		clear(player)
	end
	tuned[player] = model
	local value = if name == "" then nil else name
	if model:GetAttribute(AudioService.ATTRIBUTE) ~= value then
		model:SetAttribute(AudioService.ATTRIBUTE, value)
	end
end

local function sweep()
	for player, model in tuned do
		if player.Parent == nil or model.Parent == nil or drivenModel(player) ~= model then
			clear(player)
		end
	end
end

AudioService._onRadioTune = onRadioTune
AudioService._sweep = sweep

function AudioService.init()
	Net.on("RadioTune", onRadioTune, AudioService.RATE)
	Players.PlayerRemoving:Connect(clear)
end

function AudioService.start()
	while true do
		task.wait(AudioService.SWEEP)
		if next(tuned) ~= nil then
			local ok, err = pcall(sweep)
			if not ok then
				warn("[AudioService] sweep failed: " .. tostring(err))
			end
		end
	end
end

return AudioService
