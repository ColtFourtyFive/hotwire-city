--!strict
-- PromptStyle: Roblox's ProximityPrompt bubbles redrawn in GTA's language (C4b de-Robloxify, docs/v2/DEROBLOX_AUDIT.md).
--
-- The engine's default prompt (a grey rounded key circle with outlined white text, floating over every car, counter and
-- garage pad) is the most "Roblox" thing in the core loop. GTA puts an interaction in the top-left help box instead:
--     Halden Wren
--     Hold [E] to hotwire.
-- Every prompt the engine shows is switched to Style = Custom and drawn here:
--   * Keyboard / gamepad: the HUD help box (hooks.help, urgent: it pushes a tutorial hint back and that hint returns
--     for the time it had left when the prompt goes). The object is the first line, then one line per prompt in
--     sentence case with its key cap (several prompts on one car, e.g. Drive [E] + Sell [F], share the box). A thin
--     Ignition Orange rule under the text fills while a hold prompt is held (hooks.progress -> HelpText).
--   * Touch (only with PromptStyle.TOUCH_ENABLED, OFF until Studio job 0017 step 10 passes on a device): the same help
--     box (the caption replaces the key cap) plus one flat black circle button per prompt (Kit.circleButton,
--     gta_ui_language §7) in the right-hand cluster, above PHONE / MAP on foot and above the horn row while driving.
--     A press holds the prompt through ProximityPrompt:InputHoldBegin / InputHoldEnd. With it off, touch players keep
--     the engine's own tappable bubbles: a silent fault here must never block a touch hotwire.
-- Who draws (PromptStyle.mode): this module ("custom") or the engine ("default"). The engine draws on touch (above),
-- while the HUD is hidden in streamer mode (hooks.hidden: the help box is off, the prompts must not vanish with it),
-- and for good after any error (giveUp, also from a failing refresh / hold). Every switch puts the prompts this module
-- ever set to Custom on the style the new mode needs and shows the ones on screen again (ProximityPromptService off
-- for RESHOW_FRAMES frames), because the engine's default layer only builds a bubble when a prompt is shown. The first
-- switch at start does the same for prompts that were already up before this ran.
-- Input stays the engine's: KeyboardKeyCode / GamepadKeyCode trigger a Custom prompt exactly as before, so a fault here
-- can never stop a hotwire. While this draws, the engine's default prompt layer (PlayerGui "ProximityPrompts") is
-- disabled, so a prompt that was already up when it was switched never draws twice. Nothing draws while a menu or
-- the photo viewfinder holds the cursor (UI/UIFocus).
--
--   PromptStyle.start(hooks)   hooks = { help(text, opts) -> any, clear(id), progress(id, fraction?), layout()?,
--                              hidden()?, visibility: Signal? }
--   PromptStyle.ENABLED        one-line kill switch (job 0017 re-test)   PromptStyle.TOUCH_ENABLED   touch drawing
--   Pure (tests): actionPhrase(action), objectName(object), keyLabel(keyName, input), line(entry, input),
--   helpText(entries, input), touchRects(L, count, driving), holdFraction(startedAt, duration, now),
--   mode(failed, input, touchEnabled, hudHidden)

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
-- Touch drawing (help box + HOTWIRE-style buttons). Off until job 0017 step 10 passes on a real device: until then touch
-- players keep the engine's own tappable bubbles (review: a silent fault would block every touch hotwire).
PromptStyle.TOUCH_ENABLED = false
-- Frames the prompt service stays off for a re-show (it has to evaluate once with prompts off).
PromptStyle.RESHOW_FRAMES = 2
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

export type Mode = "custom" | "default"

-- Who draws the prompts (pure): "custom" = this module (help box, touch buttons), "default" = the engine's bubbles.
-- The engine draws after a failure, on touch unless touch drawing is on, and while the HUD is hidden in streamer mode
-- (the help box is off with it; the prompts must not vanish).
function PromptStyle.mode(failed: boolean, input: string, touchEnabled: boolean, hudHidden: boolean): Mode
	if failed then
		return "default"
	end
	if input == "touch" and not touchEnabled then
		return "default"
	end
	if hudHidden then
		return "default"
	end
	return "custom"
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
	-- true while the HUD (and its help box) is hidden in streamer mode: the engine draws the prompts then
	hidden: (() -> boolean)?,
	-- fires when hidden() may have changed (HUDController.VisibilityChanged)
	visibility: any?,
}

type Shown = { order: number, conns: { RBXScriptConnection } }

local player = Players.LocalPlayer
local hooks: Hooks? = nil
local started = false
local failed = false
local mode: Mode = "default" -- nothing is switched before start
local shown: { [ProximityPrompt]: Shown } = {} -- every prompt on screen, in both modes
-- Every prompt this module set to Custom (a strong set: weak Instance keys can drop while the prompt still exists).
-- Each one goes back to Default whenever the engine has to draw (mode "default", giveUp). Pruned of removed prompts.
local styled: { [ProximityPrompt]: boolean } = {}
local styledCount = 0
local pruneAt = 256
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
local reshowing = false

local function setDefaultLayer(enabled: boolean)
	local layer = defaultLayer
	if layer and layer.Parent then
		pcall(function()
			layer.Enabled = enabled
		end)
	end
end

local function prune()
	local n = 0
	for prompt in styled do
		if prompt.Parent == nil then
			styled[prompt] = nil
		else
			n += 1
		end
	end
	styledCount = n
	pruneAt = math.max(256, n * 2)
end

local function setCustom(prompt: ProximityPrompt)
	if not styled[prompt] then
		styled[prompt] = true
		styledCount += 1
		if styledCount > pruneAt then
			prune()
		end
	end
	if prompt.Style ~= Enum.ProximityPromptStyle.Custom then
		prompt.Style = Enum.ProximityPromptStyle.Custom
	end
end

-- Back to the engine's bubble (only prompts this module switched; one the engine refuses stays in the set).
local function restore(prompt: ProximityPrompt)
	if not styled[prompt] then
		return
	end
	local ok = pcall(function()
		if prompt.Style == Enum.ProximityPromptStyle.Custom then
			prompt.Style = Enum.ProximityPromptStyle.Default
		end
	end)
	if ok then
		styled[prompt] = nil
		styledCount = math.max(0, styledCount - 1)
	end
end

local function restoreAll()
	local list: { ProximityPrompt } = {}
	for prompt in styled do
		table.insert(list, prompt)
	end
	for _, prompt in list do
		restore(prompt)
	end
end

-- Hide and show every prompt on screen again: the engine's default layer builds a bubble only on PromptShown, so a
-- prompt whose style changed while it was up needs a fresh show. Turning the service off for RESHOW_FRAMES frames does
-- that for all of them at once, with no per-prompt property left to fight the server over. If prompts are already off
-- (CombatClient's stun), they show afresh when it turns them back on. A stun that starts inside the window finds the
-- service already off and leaves it to us: it comes back on only once the stun is over.
local function reshowAll()
	if reshowing then
		return
	end
	local on = false
	pcall(function()
		on = ProximityPromptService.Enabled
	end)
	if not on then
		return
	end
	reshowing = true
	pcall(function()
		ProximityPromptService.Enabled = false
	end)
	task.spawn(function()
		for _ = 1, PromptStyle.RESHOW_FRAMES do
			RunService.Heartbeat:Wait()
		end
		while player:GetAttribute("Stunned") == true do
			player:GetAttributeChangedSignal("Stunned"):Wait()
		end
		reshowing = false
		pcall(function()
			if not ProximityPromptService.Enabled then
				ProximityPromptService.Enabled = true
			end
		end)
	end)
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

local function hideTouch()
	for i, b in touchButtons do
		b.Visible = false
		if pressInputs[i] then
			holdEnd(i)
		end
	end
	table.clear(touchPrompts)
	table.clear(pressInputs)
end

local function layoutTouch(list: { ProximityPrompt })
	if not Kit.isTouch() or #list == 0 then
		hideTouch()
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

-- Takes down everything this module draws (help line, hold rule, touch buttons).
local function clearDrawn()
	local h = hooks
	if h and helpUp then
		helpUp = false
		pcall(h.clear, PromptStyle.HELP_ID)
	end
	if held then
		stopHold()
	end
	hideTouch()
end

local function hudHidden(): boolean
	local h = hooks
	local fn = if h then h.hidden else nil
	if not fn then
		return false
	end
	local ok, v = pcall(fn)
	return ok and v == true
end

-- Switches who draws (PromptStyle.mode) when the input kind, the HUD's streamer state or a failure changed it.
local function applyMode()
	local want = PromptStyle.mode(failed, Kit.inputKind(), PromptStyle.TOUCH_ENABLED, hudHidden())
	if want == mode then
		return
	end
	mode = want
	if want == "custom" then
		for prompt in shown do
			setCustom(prompt)
		end
		setDefaultLayer(false)
	else
		clearDrawn()
		restoreAll()
		setDefaultLayer(true)
	end
	-- the engine builds a bubble only on PromptShown: show what is on screen again under the new style
	reshowAll()
end

local function refresh()
	local h = hooks
	if not h then
		return
	end
	applyMode()
	if mode ~= "custom" then
		clearDrawn()
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

local giveUp: (err: any) -> ()

-- Coalesces bursts (several prompts showing in one frame, ActionText price ticks) into one refresh. A failing refresh
-- (the whole render path: help text, touch layout) hands the prompts back to the engine for good.
local function queueRefresh()
	if refreshQueued or failed then
		return
	end
	refreshQueued = true
	task.defer(function()
		refreshQueued = false
		if failed then
			return
		end
		local ok, err = pcall(refresh)
		if not ok then
			giveUp(err)
		end
	end)
end

-- Any error: every prompt this module ever switched goes back to Default, the engine's layer comes back on and the
-- prompts on screen are shown again, so they get their bubbles now (not after a walk away and back).
function giveUp(err: any)
	if failed then
		return
	end
	failed = true
	warn("[PromptStyle] falling back to the default prompts: " .. tostring(err))
	pcall(clearDrawn)
	for _, rec in shown do
		for _, c in rec.conns do
			c:Disconnect()
		end
	end
	table.clear(shown)
	mode = "default"
	restoreAll()
	setDefaultLayer(true)
	pcall(reshowAll)
end

local onHidden: (ProximityPrompt) -> ()

local function onShown(prompt: ProximityPrompt)
	if shown[prompt] then
		return
	end
	if mode == "custom" then
		setCustom(prompt)
	elseif styled[prompt] then
		-- still Custom from an earlier custom spell: the engine draws it now
		restore(prompt)
		reshowAll()
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
	if not shown[prompt] or mode ~= "custom" then
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
			setDefaultLayer(mode ~= "custom")
		end
	end
	local existing = pg:FindFirstChild(PromptStyle.DEFAULT_LAYER)
	if existing then
		consider(existing)
	end
	pg.ChildAdded:Connect(consider)
end

-- Engine events run through here. Once failed, a prompt still on Custom (this module's) goes back to Default.
local function guarded(fn: (ProximityPrompt) -> ()): (ProximityPrompt) -> ()
	return function(prompt: ProximityPrompt)
		if failed then
			if styled[prompt] then
				restore(prompt)
			end
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
			local ok, err = pcall(onHoldBegan, prompt)
			if not ok then
				giveUp(err)
			end
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
	-- the input kind decides the mode (touch) and the key caps; mouse / keyboard flicker alone changes neither
	local lastKind = Kit.inputKind()
	pcall(function()
		UserInputService.LastInputTypeChanged:Connect(function()
			local kind = Kit.inputKind()
			if kind ~= lastKind or next(shown) ~= nil then
				lastKind = kind
				queueRefresh()
			end
		end)
	end)
	local vis: any = h.visibility
	if typeof(vis) == "table" and typeof(vis.Connect) == "function" then
		pcall(function()
			vis:Connect(queueRefresh)
		end)
	end
	player:GetAttributeChangedSignal("Driving"):Connect(queueRefresh)
	task.spawn(watchDefaultLayer)
	-- Pick the mode now. The switch to "custom" shows what is already on screen again: a prompt shown before this ran
	-- (a spawn next to the garage's Drive / Sell pads) would otherwise lose its bubble and never get help text.
	task.defer(function()
		if failed then
			return
		end
		local ok, err = pcall(applyMode)
		if not ok then
			giveUp(err)
		end
	end)
end

-- Tests only.
function PromptStyle._state(): { failed: boolean, shown: number, started: boolean, styled: number, mode: Mode }
	local n = 0
	for _ in shown do
		n += 1
	end
	local m = 0
	for _ in styled do
		m += 1
	end
	return { failed = failed, shown = n, started = started, styled = m, mode = mode }
end

-- Tests only: the runtime without the engine (a prompt's show / hide, a failure, the HUD hooks).
function PromptStyle._test(): any
	return {
		onShown = guarded(onShown),
		onHidden = guarded(onHidden),
		giveUp = function(err: any)
			giveUp(err)
		end,
		applyMode = applyMode,
		setHooks = function(hk: any)
			hooks = hk
		end,
		reset = function()
			failed = false
			mode = "default"
			table.clear(shown)
			table.clear(styled)
			styledCount = 0
			helpUp = false
			held = nil
			reshowing = false
		end,
	}
end

return PromptStyle
