--!strict
-- PromptStyle: Roblox's ProximityPrompt bubbles redrawn in GTA's language (C4b de-Robloxify, docs/v2/DEROBLOX_AUDIT.md).
--
-- The engine's default prompt (a grey rounded key circle with outlined white text, floating over every car, counter and
-- garage pad) is the most "Roblox" thing in the core loop. GTA puts an interaction in the top-left help box instead:
--     Halden Wren
--     Hold [E] to hotwire.
-- Every prompt the engine shows is switched to Style = Custom and drawn here:
--   * Keyboard / gamepad: the HUD help box (hooks.help, urgent: it pushes a tutorial hint back and that hint returns
--     when the prompt goes). The object is the first line, then one line per prompt in sentence case with its key cap
--     (several prompts on one car, e.g. Drive [E] + Sell [F], share the box). A thin Ignition Orange rule under the
--     text fills while a hold prompt is held (hooks.progress -> HelpText).
--   * Touch: the same help box (the caption replaces the key cap) plus one flat black circle button per prompt
--     (Kit.circleButton, gta_ui_language §7) in the right-hand cluster, above PHONE / MAP on foot and above the horn
--     row while driving. A press holds the prompt through ProximityPrompt:InputHoldBegin / InputHoldEnd.
-- Input stays the engine's: KeyboardKeyCode / GamepadKeyCode trigger a Custom prompt exactly as before, so a fault here
-- can never stop a hotwire. Any error puts prompts back on the default style and re-enables the engine's prompt layer.
-- While this runs the engine's default prompt layer (PlayerGui "ProximityPrompts") is disabled, so a prompt that was
-- already up when it was switched never draws twice. Hidden while a menu holds the cursor (UI/UIFocus).
--
--   PromptStyle.start(hooks)   hooks = { help(text, opts) -> any, clear(id), progress(id, fraction?), layout()? }
--   PromptStyle.ENABLED        one-line kill switch (job 0017 re-test)
--   Pure (tests): actionPhrase(action), objectName(object), keyLabel(keyName, input), line(entry, input),
--   helpText(entries, input), touchRects(L, count, driving), holdFraction(startedAt, duration, now)

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent.Theme)
local Kit = require(script.Parent.Kit)
local RichText = require(script.Parent.RichText)
local HudLayout = require(script.Parent.HudLayout)
local UIFocus = require(script.Parent.UIFocus)

local PromptStyle = {}

PromptStyle.ENABLED = true
PromptStyle.HELP_ID = "prompt"
PromptStyle.MAX_LINES = 3
PromptStyle.TOUCH_SIZE = 64
PromptStyle.TOUCH_GAP = 12
PromptStyle.DEFAULT_LAYER = "ProximityPrompts" -- the engine's default prompt ScreenGui in PlayerGui

-- First words that already read as a verb ("Hotwire" -> "hold E to hotwire"); anything else is a place or a noun
-- ("Gear Shop" -> "press E to open Gear Shop").
local VERBS: { [string]: boolean } = {}
for _, v in
	{
		"hotwire",
		"steal",
		"carjack",
		"drive",
		"sell",
		"buy",
		"browse",
		"unlock",
		"recover",
		"get",
		"enter",
		"exit",
		"open",
		"collect",
		"lock",
		"shop",
		"rob",
		"take",
		"claim",
		"repair",
		"spray",
		"park",
		"store",
		"talk",
		"call",
		"deliver",
		"use",
		"pick",
		"search",
		"hack",
		"break",
		"cut",
		"grab",
		"loot",
		"mug",
		"pay",
		"start",
		"join",
		"leave",
		"ring",
		"knock",
		"sit",
		"change",
		"pump",
		"withdraw",
		"deposit",
	}
do
	VERBS[v] = true
end
PromptStyle.VERBS = VERBS

-------------------------------------------------------------------------------------------------------------------------
-- Pure helpers
-------------------------------------------------------------------------------------------------------------------------

local function isAllCaps(word: string): boolean
	local letters = word:gsub("[^%a]", "")
	return #letters >= 2 and letters == string.upper(letters)
end

-- The action in GTA sentence case, ready for "to ...": "Hotwire" -> "hotwire", "UNLOCK $1.5K" -> "unlock for $1.5K",
-- "Sell $1,200" -> "sell for $1,200", "Recover!" -> "recover", "Gear Shop" -> "open Gear Shop". Never empty.
function PromptStyle.actionPhrase(action: any): string
	if typeof(action) ~= "string" then
		return "interact"
	end
	local s = RichText.clean(action)
	s = s:gsub("[!%.%s]+$", "")
	s = s:gsub("^%s+", "")
	if s == "" then
		return "interact"
	end
	local words = string.split(s, " ")
	local first = string.lower(words[1])
	if not VERBS[first] then
		return "open " .. s
	end
	for i, w in words do
		if isAllCaps(w) and not string.find(w, "[%d%$]") then
			words[i] = string.lower(w)
		elseif i == 1 then
			words[i] = string.lower(string.sub(w, 1, 1)) .. string.sub(w, 2)
		end
	end
	-- "sell $1,200" -> "sell for $1,200" (a bare price after the verb)
	if #words >= 2 and string.sub(words[2], 1, 1) == "$" then
		table.insert(words, 2, "for")
	end
	return table.concat(words, " ")
end

-- The object line: shouting shop signs become title case ("FREEDOM ARMS" -> "Freedom Arms"); names stay as written.
function PromptStyle.objectName(object: any): string
	if typeof(object) ~= "string" then
		return ""
	end
	local s = RichText.clean(object)
	if not isAllCaps(s) then
		return s
	end
	local words = string.split(s, " ")
	for i, w in words do
		if isAllCaps(w) and not string.find(w, "%d") then
			words[i] = string.upper(string.sub(w, 1, 1)) .. string.lower(string.sub(w, 2))
		end
	end
	return table.concat(words, " ")
end

-- Key-cap text for a KeyCode name: keyboard as is ("E"); gamepad without the "Button" prefix ("ButtonX" -> "X",
-- "ButtonL1" -> "LB", "ButtonR1" -> "RB").
local PAD_NAMES: { [string]: string } = { ButtonL1 = "LB", ButtonR1 = "RB", ButtonL2 = "LT", ButtonR2 = "RT" }
function PromptStyle.keyLabel(keyName: string?, input: string): string
	if typeof(keyName) ~= "string" or keyName == "" or keyName == "Unknown" then
		return if input == "gamepad" then "X" else "E"
	end
	if input == "gamepad" then
		return PAD_NAMES[keyName] or (keyName:gsub("^Button", ""))
	end
	return keyName
end

export type Entry = {
	action: string, -- ProximityPrompt.ActionText
	object: string, -- ProximityPrompt.ObjectText
	hold: number, -- HoldDuration (seconds; 0 = press)
	key: string?, -- KeyboardKeyCode.Name
	pad: string?, -- GamepadKeyCode.Name
}

-- One instruction line (GTA rich-text tags for UI/HelpText): "Hold <key>E</key> to hotwire." / touch: "Hold
-- <b>HOTWIRE</b>." (the on-screen button's caption).
function PromptStyle.line(e: Entry, input: string): string
	local hold = typeof(e.hold) == "number" and e.hold > 0
	local phrase = PromptStyle.actionPhrase(e.action)
	if input == "touch" then
		local caption = RichText.escape(string.upper(RichText.clean(e.action or "")))
		return `{if hold then "Hold" else "Tap"} <b>{caption}</b>.`
	end
	local name = PromptStyle.keyLabel(if input == "gamepad" then e.pad else e.key, input)
	return `{if hold then "Hold" else "Press"} <key>{RichText.escape(name)}</key> to {RichText.escape(phrase)}.`
end

-- The whole help-box text for the prompts on screen (nil when there are none): each object once in bold, its
-- instructions under it, at most MAX_LINES instructions.
function PromptStyle.helpText(entries: { Entry }, input: string): string?
	local lines: { string } = {}
	local count = 0
	local lastObject: string? = nil
	for _, e in entries do
		if count >= PromptStyle.MAX_LINES then
			break
		end
		local object = PromptStyle.objectName(e.object)
		if object ~= "" and object ~= lastObject then
			table.insert(lines, `<b>{RichText.escape(object)}</b>`)
		end
		lastObject = object
		table.insert(lines, PromptStyle.line(e, input))
		count += 1
	end
	if count == 0 then
		return nil
	end
	return table.concat(lines, "\n")
end

export type Rect = { x: number, y: number, w: number, h: number }

-- Touch buttons (design px): a row growing leftwards from the right-hand cluster, above PHONE / MAP on foot and above
-- the horn / exit row while driving (nothing in the thumbstick half). Pure.
function PromptStyle.touchRects(L: any, count: number, driving: boolean): { Rect }
	local S, G = PromptStyle.TOUCH_SIZE, PromptStyle.TOUCH_GAP
	local w = if typeof(L) == "table" and typeof(L.w) == "number" then L.w else 1280
	local h = if typeof(L) == "table" and typeof(L.h) == "number" then L.h else 720
	local buttons = if typeof(L) == "table" and typeof(L.buttons) == "table" then L.buttons else {}
	local names = if driving then { "horn", "exit", "spikes" } else { "phone", "map" }
	local top: number? = nil
	local right: number? = nil
	for _, name in names do
		local b = buttons[name]
		if typeof(b) == "table" then
			top = if top then math.min(top, b.y) else b.y
			right = if right then math.max(right, b.x + b.w) else b.x + b.w
		end
	end
	local edge = right or (w - 20)
	local bottom = if top then top - G else h - 200
	local out: { Rect } = {}
	for i = 1, math.max(0, count) do
		local x = edge - i * S - (i - 1) * G
		table.insert(out, { x = x, y = bottom - S, w = S, h = S })
	end
	return out
end

-- How far a hold has filled (0..1; pure). A zero or bad duration reads full.
function PromptStyle.holdFraction(startedAt: number, duration: number, now: number): number
	if typeof(duration) ~= "number" or duration ~= duration or duration <= 0 then
		return 1
	end
	return math.clamp((now - startedAt) / duration, 0, 1)
end

-------------------------------------------------------------------------------------------------------------------------
-- Runtime
-------------------------------------------------------------------------------------------------------------------------

export type Hooks = {
	help: (text: string, opts: any) -> any,
	clear: (id: string) -> (),
	progress: (id: string, fraction: number?) -> (),
	layout: (() -> any)?,
}

type Shown = { order: number, conns: { RBXScriptConnection } }

local player = Players.LocalPlayer
local hooks: Hooks? = nil
local started = false
local failed = false
local shown: { [ProximityPrompt]: Shown } = {}
local seq = 0
local helpUp = false
local held: { prompt: ProximityPrompt, startedAt: number, duration: number }? = nil
local holdConn: RBXScriptConnection? = nil
local touchGui: ScreenGui? = nil
local touchButtons: { TextButton } = {}
local touchPrompts: { ProximityPrompt? } = {}
local pressInputs: { [number]: InputObject } = {}
local defaultLayer: ScreenGui? = nil
local refreshQueued = false

local function setDefaultLayer(enabled: boolean)
	local layer = defaultLayer
	if layer and layer.Parent then
		pcall(function()
			layer.Enabled = enabled
		end)
	end
end

local function order(): { ProximityPrompt }
	local list: { ProximityPrompt } = {}
	for prompt in shown do
		if prompt.Parent and prompt.Enabled then
			table.insert(list, prompt)
		end
	end
	table.sort(list, function(a: ProximityPrompt, b: ProximityPrompt): boolean
		local sa, sb = shown[a], shown[b]
		local oa = if sa then sa.order else 0
		local ob = if sb then sb.order else 0
		return oa < ob
	end)
	return list
end

local function entryOf(prompt: ProximityPrompt): Entry
	return {
		action = prompt.ActionText,
		object = prompt.ObjectText,
		hold = prompt.HoldDuration,
		key = prompt.KeyboardKeyCode.Name,
		pad = prompt.GamepadKeyCode.Name,
	}
end

local function stopHold()
	held = nil
	if holdConn then
		holdConn:Disconnect()
		holdConn = nil
	end
	local h = hooks
	if h then
		pcall(h.progress, PromptStyle.HELP_ID, nil)
	end
end

local function ensureTouchGui(): ScreenGui
	local gui = touchGui
	if gui and gui.Parent then
		return gui
	end
	local g = Kit.screen("HC_Prompts", Theme.Layers.HUD + 3, { touchMin = Theme.TouchMinScale })
	touchGui = g
	return g
end

local function holdBegin(i: number)
	local prompt = touchPrompts[i]
	if prompt and prompt.Parent then
		pcall(function()
			prompt:InputHoldBegin()
		end)
	end
end

local function holdEnd(i: number)
	local prompt = touchPrompts[i]
	if prompt and prompt.Parent then
		pcall(function()
			prompt:InputHoldEnd()
		end)
	end
end

local function touchButton(i: number): TextButton
	local b = touchButtons[i]
	if b and b.Parent then
		return b
	end
	local btn = Kit.circleButton("", PromptStyle.TOUCH_SIZE, nil, {
		Name = "Prompt" .. i,
		Visible = false,
		Parent = ensureTouchGui(),
	})
	btn.InputBegan:Connect(function(input: InputObject)
		local t = input.UserInputType
		if t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1 then
			pressInputs[i] = input
			holdBegin(i)
		end
	end)
	touchButtons[i] = btn
	return btn
end

-- A press ends wherever the finger lifts (a thumb that slides off the button still releases the hold).
local function onInputEnded(input: InputObject)
	for i, pressed in pressInputs do
		if pressed == input then
			pressInputs[i] = nil
			holdEnd(i)
		end
	end
end

local function layoutTouch(list: { ProximityPrompt })
	local touch = Kit.isTouch()
	if not touch then
		for _, b in touchButtons do
			b.Visible = false
		end
		table.clear(touchPrompts)
		return
	end
	local gui = ensureTouchGui()
	local L: any = nil
	local h = hooks
	if h and h.layout then
		local ok, res = pcall(h.layout)
		if ok and typeof(res) == "table" and res.touch == true then
			L = res
		end
	end
	if not L then
		local canvas = Kit.canvasSize(gui)
		L = HudLayout.compute(canvas.X, canvas.Y, true)
	end
	local count = math.min(#list, PromptStyle.MAX_LINES)
	local rects = PromptStyle.touchRects(L, count, player:GetAttribute("Driving") == true)
	for i = 1, math.max(count, #touchButtons) do
		local prompt = if i <= count then list[i] else nil
		if prompt then
			local btn = touchButton(i)
			local r = rects[i]
			btn.Position = UDim2.fromOffset(r.x, r.y)
			btn.Size = UDim2.fromOffset(r.w, r.h)
			local cap = btn:FindFirstChild("Caption")
			if cap and cap:IsA("TextLabel") then
				cap.Text = string.upper(RichText.clean(prompt.ActionText))
				cap.TextScaled = true
			end
			btn.Visible = true
			if touchPrompts[i] ~= prompt then
				holdEnd(i) -- a different prompt took this slot mid-press
				pressInputs[i] = nil
			end
			touchPrompts[i] = prompt
		else
			local b = touchButtons[i]
			if b then
				b.Visible = false
			end
			touchPrompts[i] = nil
			pressInputs[i] = nil
		end
	end
end

local function refresh()
	local h = hooks
	if not h or failed then
		return
	end
	local list = if UIFocus.any() then {} else order()
	local entries: { Entry } = {}
	for _, prompt in list do
		table.insert(entries, entryOf(prompt))
	end
	local text = PromptStyle.helpText(entries, Kit.inputKind())
	if text then
		pcall(h.help, text, { id = PromptStyle.HELP_ID, duration = math.huge, urgent = true })
		helpUp = true
	elseif helpUp then
		helpUp = false
		pcall(h.clear, PromptStyle.HELP_ID)
	end
	local current = held
	if current and not shown[current.prompt] then
		stopHold()
	end
	layoutTouch(list)
end

-- Coalesces bursts (several prompts showing in one frame, ActionText price ticks) into one refresh.
local function queueRefresh()
	if refreshQueued then
		return
	end
	refreshQueued = true
	task.defer(function()
		refreshQueued = false
		local ok, err = pcall(refresh)
		if not ok then
			warn("[PromptStyle] refresh failed: " .. tostring(err))
		end
	end)
end

local function giveUp(err: any)
	if failed then
		return
	end
	failed = true
	warn("[PromptStyle] falling back to the default prompts: " .. tostring(err))
	for prompt, rec in shown do
		for _, c in rec.conns do
			c:Disconnect()
		end
		pcall(function()
			prompt.Style = Enum.ProximityPromptStyle.Default
		end)
	end
	table.clear(shown)
	setDefaultLayer(true)
	local h = hooks
	if h and helpUp then
		pcall(h.clear, PromptStyle.HELP_ID)
	end
	for _, b in touchButtons do
		b.Visible = false
	end
end

local onHidden: (ProximityPrompt) -> ()

local function onShown(prompt: ProximityPrompt)
	if failed or shown[prompt] then
		return
	end
	if prompt.Style ~= Enum.ProximityPromptStyle.Custom then
		prompt.Style = Enum.ProximityPromptStyle.Custom
	end
	seq += 1
	local conns: { RBXScriptConnection } = {}
	for _, prop in { "ActionText", "ObjectText", "HoldDuration", "KeyboardKeyCode", "GamepadKeyCode", "Enabled" } do
		table.insert(conns, prompt:GetPropertyChangedSignal(prop):Connect(queueRefresh))
	end
	shown[prompt] = { order = seq, conns = conns }
	-- a prompt destroyed while it is up (car despawned) may never send PromptHidden
	table.insert(
		conns,
		prompt.Destroying:Connect(function()
			onHidden(prompt)
		end)
	)
	queueRefresh()
end

function onHidden(prompt: ProximityPrompt)
	local rec = shown[prompt]
	if not rec then
		return
	end
	for _, c in rec.conns do
		c:Disconnect()
	end
	shown[prompt] = nil
	local current = held
	if current and current.prompt == prompt then
		stopHold()
	end
	queueRefresh()
end

local function onHoldBegan(prompt: ProximityPrompt)
	if not shown[prompt] then
		return
	end
	stopHold()
	local rec = { prompt = prompt, startedAt = os.clock(), duration = prompt.HoldDuration }
	held = rec
	holdConn = RunService.Heartbeat:Connect(function()
		local h = hooks
		if held ~= rec or not h then
			return
		end
		pcall(h.progress, PromptStyle.HELP_ID, PromptStyle.holdFraction(rec.startedAt, rec.duration, os.clock()))
	end)
end

local function watchDefaultLayer()
	local pg = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 10)
	if not pg then
		return
	end
	local function consider(child: Instance)
		if child.Name == PromptStyle.DEFAULT_LAYER and child:IsA("ScreenGui") then
			defaultLayer = child
			setDefaultLayer(failed)
		end
	end
	local existing = pg:FindFirstChild(PromptStyle.DEFAULT_LAYER)
	if existing then
		consider(existing)
	end
	pg.ChildAdded:Connect(consider)
end

local function guarded(fn: (ProximityPrompt) -> ()): (ProximityPrompt) -> ()
	return function(prompt: ProximityPrompt)
		if failed then
			return
		end
		local ok, err = pcall(fn, prompt)
		if not ok then
			giveUp(err)
		end
	end
end

function PromptStyle.start(h: Hooks)
	if started or not PromptStyle.ENABLED then
		return
	end
	if typeof(h) ~= "table" or typeof(h.help) ~= "function" then
		return
	end
	started = true
	hooks = h
	ProximityPromptService.PromptShown:Connect(guarded(onShown))
	ProximityPromptService.PromptHidden:Connect(guarded(onHidden))
	ProximityPromptService.PromptButtonHoldBegan:Connect(function(prompt: ProximityPrompt, who: Player)
		if who == player and not failed then
			pcall(onHoldBegan, prompt)
		end
	end)
	ProximityPromptService.PromptButtonHoldEnded:Connect(function(prompt: ProximityPrompt, who: Player)
		local current = held
		if who == player and current and current.prompt == prompt then
			stopHold()
		end
	end)
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, who: Player)
		local current = held
		if who == player and current and current.prompt == prompt then
			stopHold()
		end
	end)
	UIFocus.Changed:Connect(queueRefresh)
	UserInputService.InputEnded:Connect(onInputEnded)
	pcall(function()
		UserInputService.LastInputTypeChanged:Connect(function()
			if next(shown) ~= nil then
				queueRefresh()
			end
		end)
	end)
	player:GetAttributeChangedSignal("Driving"):Connect(queueRefresh)
	task.spawn(watchDefaultLayer)
end

-- Tests only.
function PromptStyle._state(): { failed: boolean, shown: number, started: boolean }
	local n = 0
	for _ in shown do
		n += 1
	end
	return { failed = failed, shown = n, started = started }
end

return PromptStyle
