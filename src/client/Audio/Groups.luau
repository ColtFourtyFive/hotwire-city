--!strict
-- Groups (PLAN C3 · audio): the mixer at runtime. One flat SoundGroup per channel under SoundService (HC_SFX,
-- HC_Vehicles, HC_Ambience, HC_Music, HC_UI; UI/UISound finds HC_UI by name), volumes from Shared/Audio/Mix:
-- settings toggles x master x channel slider x ducks. Ducks fade in / out (step(dt), called by SoundController's
-- render loop); a timed duck releases itself. Volumes are written only when they change.

local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Mix = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Audio"):WaitForChild("Mix"))

local Groups = {}

Groups.DUCK_IN = 3 -- fade per second into a duck
Groups.DUCK_OUT = 1.2 -- ...and back out

local volumes = Mix.defaultVolumes()
local toggles: Mix.Toggles = { sfx = true, music = true }
local duckTarget: { [string]: number } = {}
local duckFade: { [string]: number } = {}
local duckUntil: { [string]: number } = {}
local groups: { [string]: SoundGroup } = {}
local applied: { [string]: number } = {}
local CHANNELS = { "sfx", "vehicles", "ambience", "music", "ui" }

-- The SoundGroup of a channel ("sfx" | "vehicles" | "ambience" | "music" | "ui"), made on first use.
function Groups.get(channel: string): SoundGroup
	local g = groups[channel]
	if g and g.Parent then
		return g
	end
	local name = Mix.GROUPS[channel] or Mix.GROUPS.sfx
	local existing = SoundService:FindFirstChild(name)
	if existing and existing:IsA("SoundGroup") then
		g = existing
	else
		local made = Instance.new("SoundGroup")
		made.Name = name
		made.Parent = SoundService
		g = made
	end
	groups[channel] = g :: SoundGroup
	applied[channel] = -1
	return g :: SoundGroup
end

function Groups.volumeOf(channel: string): number
	return Mix.groupVolume(channel, volumes, toggles, duckFade)
end

function Groups.apply()
	for _, channel in CHANNELS do
		local g = Groups.get(channel)
		local v = Groups.volumeOf(channel)
		if math.abs((applied[channel] or -1) - v) > 0.001 then
			applied[channel] = v
			g.Volume = v
		end
	end
end

function Groups.setToggle(name: string, on: boolean)
	if name == "music" then
		toggles.music = on
	elseif name == "sfx" then
		toggles.sfx = on
	end
	Groups.apply()
end

function Groups.isOn(name: string): boolean
	return if name == "music" then toggles.music else toggles.sfx
end

-- Slider volume 0..1 of a channel ("master" included).
function Groups.setVolume(channel: string, v: number)
	if typeof(v) ~= "number" or v ~= v then
		return
	end
	volumes[channel] = math.clamp(v, 0, 1)
	Groups.apply()
end

function Groups.getVolume(channel: string): number
	return volumes[channel] or 1
end

-- Start (on = true) or release a duck. seconds: release automatically after that long.
function Groups.duck(reason: string, on: boolean, seconds: number?)
	duckTarget[reason] = if on then 1 else 0
	if duckFade[reason] == nil then
		duckFade[reason] = 0
	end
	if on and seconds then
		duckUntil[reason] = os.clock() + seconds
	elseif not on then
		duckUntil[reason] = nil
	end
end

-- Immediate duck depth (no fade): gunfire ducks are short and must bite at once.
function Groups.duckNow(reason: string, seconds: number)
	duckFade[reason] = 1
	Groups.duck(reason, true, seconds)
	Groups.apply()
end

function Groups.step(dt: number)
	local now = os.clock()
	local changed = false
	for reason, target in duckTarget do
		local untilAt = duckUntil[reason]
		if untilAt and now >= untilAt then
			duckUntil[reason] = nil
			duckTarget[reason] = 0
			target = 0
		end
		local cur = duckFade[reason] or 0
		if cur ~= target then
			local rate = if target > cur then Groups.DUCK_IN else Groups.DUCK_OUT
			duckFade[reason] = Mix.approach(cur, target, rate, dt)
			changed = true
		end
	end
	if changed then
		Groups.apply()
	end
end

-- Snapshot for tests / debug.
function Groups.state(): { [string]: any }
	return { volumes = volumes, toggles = toggles, ducks = duckFade }
end

return Groups
