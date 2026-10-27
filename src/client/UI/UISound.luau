--!strict
-- UISound: one-shot interface sounds by Config/UIAssets.Sounds key (help beep, shard stings, camera shutter, phone
-- vibrate). They honour Settings > Sound effects like every other sound: nothing plays while SoundController says
-- sfx is off, and each one goes through a SoundGroup the setting mutes (HC_UI when the SoundController made one: it
-- sits outside the HC_SFX death / weapon-wheel muffle; HC_SFX otherwise).
--
--   UISound.play(key, opts?) -> Sound?     opts = { volume = number?, life = seconds? }
--   UISound.groupFor(soundService) -> SoundGroup?   (pure lookup, tests)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local UISound = {}

type SoundDef = { id: string, volume: number, length: number? }

local assets: { [string]: SoundDef }? = nil
local function defs(): { [string]: SoundDef }
	local cached = assets
	if cached then
		return cached
	end
	local ok, mod = pcall(function()
		local shared = ReplicatedStorage:FindFirstChild("Shared")
		local config = shared and shared:FindFirstChild("Config")
		local m = config and config:FindFirstChild("UIAssets")
		return if m then require(m :: any) else nil
	end)
	local list = if ok and typeof(mod) == "table" and typeof(mod.Sounds) == "table" then mod.Sounds else {}
	assets = list
	return list
end

-- Is "Sound effects" on? (SoundController keeps the setting; without one, yes.)
local function sfxOn(): boolean
	local controllers = script.Parent.Parent:FindFirstChild("Controllers")
	local mod = controllers and controllers:FindFirstChild("SoundController")
	if not (mod and mod:IsA("ModuleScript")) then
		return true
	end
	local ok, sc = pcall(require, mod :: any)
	if not ok or typeof(sc) ~= "table" or typeof(sc.isEnabled) ~= "function" then
		return true
	end
	local okOn, on = pcall(sc.isEnabled, "sfx")
	return not okOn or on ~= false
end

-- The SoundGroup UI one-shots play through: HC_UI (outside the world muffle) when it exists, else HC_SFX.
function UISound.groupFor(service: Instance): SoundGroup?
	for _, name in { "HC_UI", "HC_SFX" } do
		local g = service:FindFirstChild(name)
		if g and g:IsA("SoundGroup") then
			return g
		end
	end
	return nil
end

export type PlayOpts = { volume: number?, life: number? }

function UISound.play(key: string, opts: PlayOpts?): Sound?
	local def = defs()[key]
	if not def or not sfxOn() then
		return nil
	end
	local s = Instance.new("Sound")
	s.Name = "HC_UI_" .. key
	s.SoundId = def.id
	s.Volume = if opts and opts.volume then opts.volume else def.volume
	s.SoundGroup = UISound.groupFor(SoundService)
	s.Parent = SoundService
	s:Play()
	local life = if opts and opts.life then opts.life else (def.length or 8)
	task.delay(life, function()
		if not s.Parent then
			return
		end
		if def.length then
			-- trimmed sting: fade the tail instead of cutting it
			TweenService:Create(s, TweenInfo.new(0.4), { Volume = 0 }):Play()
			task.wait(0.45)
		end
		s:Destroy()
	end)
	return s
end

return UISound
