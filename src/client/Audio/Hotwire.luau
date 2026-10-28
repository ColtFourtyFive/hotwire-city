--!strict
-- Hotwire (PLAN C3 · audio): the crackle of wires being shorted while the local player holds a steal prompt.
--
-- The steal prompts are server-made ProximityPrompts (StreetSpawnService / TheftService "Hotwire", GarageService
-- "StealPrompt"); this listens to ProximityPromptService's hold events on this client, so nothing in those systems
-- changes. While a matching prompt is held, HotwireCrackle loops at the prompt (its part or attachment); it stops on
-- release, trigger, or after MAX_HOLD seconds. The starter that follows is LocalCar's; it skips the key click on a car
-- entered right after a steal prompt triggered (recent()).

local ProximityPromptService = game:GetService("ProximityPromptService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sounds = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Sounds"))

local Apply = require(script.Parent:WaitForChild("Apply"))
local Groups = require(script.Parent:WaitForChild("Groups"))
local Voices = require(script.Parent:WaitForChild("Voices"))

local Hotwire = {}

Hotwire.MAX_HOLD = 12
Hotwire.WORDS = { "hotwire", "steal", "break in" }

local player = Players.LocalPlayer
local att: Attachment? = nil
local sound: Sound? = nil
local holding: ProximityPrompt? = nil
local token = 0
local lastHotwire = -math.huge

-- Is this a car-steal prompt? (pure on its two strings; exported for tests)
function Hotwire.isStealPrompt(name: string, actionText: string): boolean
	if name == "StealPrompt" then
		return true
	end
	local text = string.lower(actionText)
	for _, w in Hotwire.WORDS do
		if string.find(text, w, 1, true) then
			return true
		end
	end
	return false
end

local function positionOf(prompt: ProximityPrompt): Vector3?
	local parent = prompt.Parent
	if parent and parent:IsA("BasePart") then
		return parent.Position
	elseif parent and parent:IsA("Attachment") then
		return parent.WorldPosition
	elseif parent and parent:IsA("Model") then
		return parent:GetPivot().Position
	end
	return nil
end

local function stop()
	token += 1
	holding = nil
	local s = sound
	if s and s.IsPlaying then
		s:Stop()
	end
end

local function begin(prompt: ProximityPrompt, who: Player?)
	if who ~= nil and who ~= player then
		return
	end
	if not Hotwire.isStealPrompt(prompt.Name, prompt.ActionText) or not Groups.isOn("sfx") then
		return
	end
	local pos = positionOf(prompt)
	if not pos then
		return
	end
	if not sound then
		local a, s = Voices.loopAt("HC_Hotwire")
		local d = Sounds.HotwireCrackle
		if d then
			Apply.def(s, d, Groups.get("sfx"))
			s.Looped = true
		end
		s.RollOffMaxDistance = 60
		att, sound = a, s
	end
	local s = sound :: Sound
	local emitter = att
	if emitter then
		emitter.WorldPosition = pos
	end
	holding = prompt
	token += 1
	local my = token
	local d = Sounds.HotwireCrackle
	s.TimePosition = if d then Apply.startTime(d :: any) else 0
	s:Play()
	task.delay(Hotwire.MAX_HOLD, function()
		if my == token then
			stop()
		end
	end)
end

local function finish(prompt: ProximityPrompt, who: Player?)
	if who ~= nil and who ~= player then
		return
	end
	if prompt == holding then
		stop()
	end
end

local function triggered(prompt: ProximityPrompt, who: Player?)
	if (who == nil or who == player) and Hotwire.isStealPrompt(prompt.Name, prompt.ActionText) then
		lastHotwire = os.clock()
	end
	finish(prompt, who)
end

-- Did the local player just finish hotwiring a car (a steal prompt triggered within `seconds`)? LocalCar skips the
-- key click on such a car: it was started with the wires.
function Hotwire.recent(seconds: number): boolean
	return os.clock() - lastHotwire <= seconds
end

function Hotwire.start()
	ProximityPromptService.PromptButtonHoldBegan:Connect(begin)
	ProximityPromptService.PromptButtonHoldEnded:Connect(finish)
	ProximityPromptService.PromptTriggered:Connect(triggered)
end

return Hotwire
