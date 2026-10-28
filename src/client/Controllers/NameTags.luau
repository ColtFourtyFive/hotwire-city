--!strict
-- NameTags (C4a characters; VIBE row 17, gta_ui_language §8): GTA Online-style player names instead of Roblox's
-- overhead name and health bar (those are off: StarterPlayer NameDisplayDistance / HealthDisplayDistance 0, and
-- AppearanceService sets every player Humanoid's DisplayDistanceType None + HealthDisplayType AlwaysOff).
--
--   * Small white Montserrat text (FootTuning.TAG_SIZE px) a little above the head, no panel, no health bar.
--   * Only within FootTuning.TAG_DISTANCE (40) studs, fading out over the last quarter; walls hide it (not AlwaysOnTop).
--   * None while you are in combat (InCombat attribute) or have a gun drawn, none in streamer mode / photo mode
--     (HUDController.isHidden), none on a player in the character creator studio (HC_Creator).
-- One BillboardGui per other player, kept in PlayerGui (adornee = their Head), rebuilt on respawn. Visibility is
-- re-evaluated 10x a second (FootTuning.tagVisible / tagFade); only changed properties are written.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local FootTuning = require(Shared:WaitForChild("Appearance"):WaitForChild("FootTuning"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))

local NameTags = {}

local player = Players.LocalPlayer
local C = Theme.Colors

NameTags.HEIGHT = 1.35 -- studs above the head's centre
NameTags.TICK = 0.1

type Tag = { gui: BillboardGui, label: TextLabel, head: BasePart, shown: boolean, fade: number }

local tags: { [Player]: Tag } = {}
local folder: Folder? = nil

local lazyCache: { [string]: any } = {}
local function lazy(name: string): any
	local cached = lazyCache[name]
	if cached then
		return cached
	end
	local mod = script.Parent:FindFirstChild(name)
	if not mod then
		return nil
	end
	local ok, res = pcall(require, mod :: any)
	if ok and typeof(res) == "table" then
		lazyCache[name] = res
		return res
	end
	return nil
end

local function call(name: string, fn: string, ...: any): any
	local mod = lazy(name)
	if mod and typeof(mod[fn]) == "function" then
		local ok, res = pcall(mod[fn], ...)
		if ok then
			return res
		end
	end
	return nil
end

local function getFolder(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = "HC_NameTags"
	nf.Parent = player:WaitForChild("PlayerGui")
	folder = nf
	return nf
end

local function drop(p: Player)
	local t = tags[p]
	if t then
		tags[p] = nil
		t.gui:Destroy()
	end
end

local function build(p: Player, head: BasePart)
	drop(p)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Tag_" .. tostring(p.UserId)
	gui.Adornee = head
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = FootTuning.TAG_DISTANCE + 2
	gui.ResetOnSpawn = false
	gui.Size = UDim2.fromOffset(220, FootTuning.TAG_SIZE + 6)
	gui.StudsOffsetWorldSpace = Vector3.new(0, NameTags.HEIGHT, 0)
	gui.Enabled = false
	local label = Kit.new("TextLabel", {
		Name = "Name",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		FontFace = Theme.Fonts.BodyBold,
		TextSize = FootTuning.TAG_SIZE,
		TextColor3 = C.Text,
		TextStrokeColor3 = C.Black,
		TextStrokeTransparency = 0.55,
		Text = Kit.sanitize(p.DisplayName),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = gui,
	})
	gui.Parent = getFolder()
	tags[p] = { gui = gui, label = label, head = head, shown = false, fade = 0 }
end

local function watch(p: Player)
	if p == player then
		return
	end
	local function onCharacter(char: Model)
		task.spawn(function()
			local head = char:WaitForChild("Head", 10)
			if head and head:IsA("BasePart") and p.Character == char then
				build(p, head)
			end
		end)
		-- a new Head (ApplyDescriptionAsync swaps the body parts) re-adorns the tag
		char.ChildAdded:Connect(function(child: Instance)
			if child.Name == "Head" and child:IsA("BasePart") and p.Character == char then
				local t = tags[p]
				if t then
					t.head = child
					t.gui.Adornee = child
				else
					build(p, child)
				end
			end
		end)
	end
	p.CharacterAdded:Connect(onCharacter)
	p.CharacterRemoving:Connect(function()
		drop(p)
	end)
	if p.Character then
		onCharacter(p.Character)
	end
end

local function localBlocked(): boolean
	if player:GetAttribute("InCombat") == true then
		return true
	end
	if call("ShoulderCamera", "isEngaged") == true then
		return true
	end
	return call("HUDController", "isHidden") == true or call("CharacterCreator", "isOpen") == true
end

local function refresh()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local camPos = cam.CFrame.Position
	local blocked = localBlocked()
	for p, t in tags do
		if not p.Parent or not t.head.Parent then
			drop(p)
			continue
		end
		local d = (t.head.Position - camPos).Magnitude
		local targetHidden = p:GetAttribute("HC_Creator") ~= nil
		local show = FootTuning.tagVisible(d, false, blocked, targetHidden)
		if show ~= t.shown then
			t.shown = show
			t.gui.Enabled = show
		end
		if show then
			local fade = math.floor(FootTuning.tagFade(d) * 20 + 0.5) / 20
			if fade ~= t.fade then
				t.fade = fade
				t.label.TextTransparency = fade
				t.label.TextStrokeTransparency = 0.55 + 0.45 * fade
			end
		end
	end
end

-- PUBLIC ---------------------------------------------------------------------------------------------------------------

-- Number of tags currently drawn (tests / diagnostics).
function NameTags.count(): number
	local n = 0
	for _, t in tags do
		if t.shown then
			n += 1
		end
	end
	return n
end

function NameTags.init() end

function NameTags.start()
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(drop)
	for _, p in Players:GetPlayers() do
		watch(p)
	end
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < NameTags.TICK then
			return
		end
		acc = 0
		local ok, err = pcall(refresh)
		if not ok then
			warn("[NameTags] " .. tostring(err))
		end
	end)
end

return NameTags
