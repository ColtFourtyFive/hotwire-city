--!strict
-- WeaponWheel (gta_ui_language §5.10, gta_combat §11.1 / §11.4): the GTA VI card wheel, `HC_Wheel` (DisplayOrder 35).
--
--  * Open: hold Tab (PC) or LB (pad), on foot. Touch: the weapon button (WeaponClient) toggles it; tap a card; tap
--    the backdrop to close. Double-tap Tab holsters.
--  * 8 cards (128x84) on a 190 px ring, clockwise from the top: Pistols, SMGs, Rifles, Shotguns, Unarmed / melee,
--    Tools (taser, spike strip), Items (med kit), Special. Empty slots show "+".
--  * Selection: mouse movement (virtual cursor, 40 px dead zone) or the right stick angle; Q / E, the mouse wheel or
--    D-pad left / right cycle inside a slot ("<  1 / 3  >" in the centre).
--  * Release (or click / A) equips through WeaponClient -> the server-validated WeaponEquip remote. Choosing the med
--    kit sends UseMedKit.
--  * While open: camera blur 16, grade (saturation -0.3, brightness -0.08), SFX muffle (HighGain -12), walk speed 50%,
--    and ContextActionService sinks look / fire / zoom. The world keeps running (multiplayer: no slow motion).
--  * Closed: D-pad left / right cycles inside the current slot; the mouse wheel cycles weapons while a gun is drawn.
-- Public: isOpen(), open(mode), close(commit), toggle(); pure helpers _slotOffset, _slotFromVector, _entries.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Trove = require(Shared:WaitForChild("Util"):WaitForChild("Trove"))
local Weapons = require(Shared:WaitForChild("Config"):WaitForChild("Weapons"))
local Economy = require(Shared:WaitForChild("Config"):WaitForChild("Economy"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))
local Style = require(UI:WaitForChild("CombatStyle"))
local WeaponPreview = require(UI:WaitForChild("WeaponPreview"))

local ShoulderCamera = require(script.Parent:WaitForChild("ShoulderCamera"))
local WeaponClient = require(script.Parent:WaitForChild("WeaponClient"))

local WeaponWheel = {}

WeaponWheel.RADIUS = 190
WeaponWheel.CARD_W = 128
WeaponWheel.CARD_H = 84
WeaponWheel.DEAD_ZONE = 40
WeaponWheel.CURSOR_MAX = 200
WeaponWheel.STICK_DEAD = 0.45
WeaponWheel.WALK_MULT = 0.5
WeaponWheel.DOUBLE_TAP = 0.3
WeaponWheel.BLUR = 16
WeaponWheel.MUFFLE = -12

local ACTION = "HC_WeaponWheel"
local CARD_BG = Color3.fromHex("#141414")

local player = Players.LocalPlayer

-- PURE ---------------------------------------------------------------------------------------------------------------

-- Offset (px, y down) of a slot's card centre from the wheel centre. Slot 1 is the top, clockwise in 45 degree steps.
function WeaponWheel._slotOffset(slot: number, radius: number): Vector2
	local a = math.rad((slot - 1) * 45)
	return Vector2.new(math.sin(a) * radius, -math.cos(a) * radius)
end

-- Slot under a screen-space vector from the centre (y down), or nil inside the dead zone.
function WeaponWheel._slotFromVector(v: Vector2, deadZone: number): number?
	if v.Magnitude < deadZone then
		return nil
	end
	local deg = math.deg(math.atan2(v.X, -v.Y)) -- 0 = up, clockwise positive
	return math.floor(((deg + 22.5) % 360) / 45) + 1
end

-- Ids shown in a slot. owned: weapon ownership map (fists included); gadgets: owned gadget ids; medkits: count.
function WeaponWheel._entries(
	slot: number,
	owned: { [string]: boolean },
	gadgets: { string },
	medkits: number
): { string }
	if slot == 6 then
		local out = {}
		for _, g in Weapons.GADGETS do
			if table.find(gadgets, g) then
				table.insert(out, g)
			end
		end
		return out
	elseif slot == 7 then
		return if medkits > 0 then { "medkit" } else {}
	end
	return Weapons.inSlot(slot, owned)
end

-- STATE --------------------------------------------------------------------------------------------------------------

type Card = {
	button: TextButton,
	stroke: UIStroke,
	strip: Frame,
	slotLabel: TextLabel,
	ammo: TextLabel,
	count: TextLabel,
	plus: TextLabel,
	icon: ViewportFrame,
	preview: WeaponPreview.Preview,
}

type View = {
	gui: ScreenGui,
	backdrop: TextButton,
	ring: Frame,
	scale: UIScale,
	cards: { Card },
	name: TextLabel,
	category: TextLabel,
	ammo: TextLabel,
	cycle: TextLabel,
	prev: TextButton,
	nextB: TextButton,
}

local view: View? = nil
local open = false
local mode: "hold" | "toggle" = "hold"
local openedAt = 0
local cursor = Vector2.zero
local hovered: number? = nil
local entries: { { string } } = {}
local choice: { [number]: number } = {}
local lastTabUp = -math.huge
local lastOpenDuration = math.huge
local walkSaved: { hum: Humanoid, speed: number }? = nil
local blur: BlurEffect? = nil
local grade: ColorCorrectionEffect? = nil

local function lazy(name: string): any
	local mod = script.Parent:FindFirstChild(name)
	if not mod then
		return nil
	end
	local ok, res = pcall(require, mod :: any)
	return if ok and typeof(res) == "table" then res else nil
end

local function humanoid(): Humanoid?
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function canOpen(): boolean
	local hum = humanoid()
	return hum ~= nil and hum.Health > 0 and hum.SeatPart == nil and player:GetAttribute("Stunned") ~= true
end

function WeaponWheel.isOpen(): boolean
	return open
end

local function labelFor(id: string): (string, string)
	if id == "medkit" then
		return Weapons.MedKit.name, "ITEMS"
	end
	local def = Weapons.get(id)
	if def then
		return def.name, Weapons.CLASS_LABEL[def.class] or ""
	end
	local tool = Economy.Tools[id]
	return if tool then tool.name else id, "TOOLS"
end

local function ammoText(id: string): string
	if id == "medkit" then
		return "x" .. WeaponClient.medkits()
	end
	local def = Weapons.get(id)
	if not def or not Weapons.isGun(def) then
		return ""
	end
	local a = WeaponClient.inventory()[id]
	if not a then
		return ""
	end
	return ("%d / %d"):format(a.mag, a.reserve)
end

local function currentEntry(slot: number): string?
	local list = entries[slot]
	if not list or #list == 0 then
		return nil
	end
	local idx = math.clamp(choice[slot] or 1, 1, #list)
	return list[idx]
end

local function refreshEntries()
	local owned = WeaponClient.ownedMap()
	local gadgets = WeaponClient.gadgets()
	local equipped = WeaponClient.equipped()
	for slot = 1, 8 do
		local list = WeaponWheel._entries(slot, owned, gadgets, WeaponClient.medkits())
		entries[slot] = list
		local idx = if equipped then table.find(list, equipped) else nil
		if idx and not open then
			choice[slot] = idx
		elseif not choice[slot] or choice[slot] > #list then
			choice[slot] = 1
		end
	end
end

-- VIEW -----------------------------------------------------------------------------------------------------------------

local function render()
	local v = view
	if not v then
		return
	end
	for slot, card in v.cards do
		local list = entries[slot] or {}
		local id = currentEntry(slot)
		local selected = hovered == slot
		local info = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(card.button, info, {
			BackgroundColor3 = if selected then Style.Colors.Text else CARD_BG,
			BackgroundTransparency = if selected then 0.1 else Style.Transparency.Card,
		}):Play()
		card.stroke.Thickness = if selected then 2 else 1
		card.stroke.Transparency = if selected then 0 else 0.85
		card.strip.Visible = selected
		local ink = if selected then Color3.new(0, 0, 0) else Style.Colors.Text
		card.icon.ImageColor3 = ink
		card.ammo.TextColor3 = ink
		card.slotLabel.TextColor3 = if selected then Color3.fromRGB(60, 60, 60) else Style.Colors.TextDim
		card.count.TextColor3 = card.slotLabel.TextColor3
		card.plus.Visible = id == nil
		card.icon.Visible = id ~= nil
		WeaponPreview.show(card.preview, if id == "medkit" then nil else id)
		card.ammo.Text = if id then ammoText(id) else ""
		card.count.Text = if #list > 1 then ("%d/%d"):format(math.clamp(choice[slot] or 1, 1, #list), #list) else ""
		if id == "medkit" then
			card.plus.Visible = true
			card.plus.Text = "MED"
			card.plus.TextColor3 = ink
		else
			card.plus.Text = "+"
			card.plus.TextColor3 = Style.Colors.TextDim
		end
	end
	local slot = hovered
	local id = if slot then currentEntry(slot) else nil
	if slot and id then
		local name, category = labelFor(id)
		v.name.Text = string.upper(name)
		v.category.Text = category
		v.ammo.Text = ammoText(id)
		local list = entries[slot]
		local many = #list > 1
		v.cycle.Text = if many then ("<   %d / %d   >"):format(choice[slot] or 1, #list) else ""
		v.prev.Visible = many
		v.nextB.Visible = many
	else
		local cur = WeaponClient.equipped()
		local name = if cur then labelFor(cur) else "Unarmed"
		v.name.Text = string.upper(name)
		v.category.Text = if slot then Weapons.WHEEL_SLOTS[slot].label else ""
		v.ammo.Text = if cur then ammoText(cur) else ""
		v.cycle.Text = ""
		v.prev.Visible = false
		v.nextB.Visible = false
	end
end

local function text(parent: Instance, props: { [string]: any }): TextLabel
	local base: { [string]: any } = {
		BackgroundTransparency = 1,
		TextColor3 = Style.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = parent,
	}
	for k, val in props do
		base[k] = val
	end
	return Kit.new("TextLabel", base) :: TextLabel
end

local function buildCard(parent: Instance, slot: number): Card
	local off = WeaponWheel._slotOffset(slot, WeaponWheel.RADIUS)
	local button = Kit.new("TextButton", {
		Name = "Slot" .. slot,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(off.X, off.Y),
		Size = UDim2.fromOffset(WeaponWheel.CARD_W, WeaponWheel.CARD_H),
		BackgroundColor3 = CARD_BG,
		BackgroundTransparency = Style.Transparency.Card,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		Parent = parent,
	}) :: TextButton
	local stroke = Kit.new("UIStroke", {
		Color = Style.Colors.Text,
		Transparency = 0.85,
		Thickness = 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = button,
	}) :: UIStroke
	local strip = Kit.new("Frame", {
		Name = "Accent",
		Size = UDim2.new(1, 0, 0, 3),
		BackgroundColor3 = Style.Colors.Accent,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 3,
		Parent = button,
	}) :: Frame
	local slotLabel = text(button, {
		Name = "SlotLabel",
		Position = UDim2.fromOffset(6, 5),
		Size = UDim2.new(1, -12, 0, 12),
		Text = Weapons.WHEEL_SLOTS[slot].label,
		FontFace = Style.font("CondensedMedium"),
		TextSize = 11,
		TextColor3 = Style.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 2,
	})
	local icon = Kit.new("ViewportFrame", {
		Name = "Icon",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(WeaponWheel.CARD_W - 20, 40),
		BackgroundTransparency = 1,
		ImageColor3 = Style.Colors.Text,
		ZIndex = 2,
		Parent = button,
	}) :: ViewportFrame
	local ammo = text(button, {
		Name = "Ammo",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -6, 1, -4),
		Size = UDim2.new(0.7, 0, 0, 16),
		FontFace = Style.font("Numeric"),
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "",
		ZIndex = 2,
	})
	local count = text(button, {
		Name = "Count",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 6, 1, -5),
		Size = UDim2.fromOffset(40, 14),
		FontFace = Style.font("CondensedMedium"),
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		ZIndex = 2,
	})
	local plus = text(button, {
		Name = "Plus",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.55),
		Size = UDim2.fromOffset(80, 30),
		FontFace = Style.font("Numeric"),
		TextSize = 26,
		TextColor3 = Style.Colors.TextDim,
		Text = "+",
		ZIndex = 2,
	})
	return {
		button = button,
		stroke = stroke,
		strip = strip,
		slotLabel = slotLabel,
		ammo = ammo,
		count = count,
		plus = plus,
		icon = icon,
		preview = WeaponPreview.new(icon, true),
	}
end

local cycle: (number) -> () = function() end
local commit: () -> () = function() end

local function build(): View
	local gui = Kit.new("ScreenGui", {
		Name = "HC_Wheel",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = Style.Layers.Wheel,
		Enabled = false,
		Parent = player:WaitForChild("PlayerGui"),
	}) :: ScreenGui
	pcall(function()
		(gui :: any).ScreenInsets = Enum.ScreenInsets.None
	end)
	local backdrop = Kit.new("TextButton", {
		Name = "Backdrop",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.72,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		Parent = gui,
	}) :: TextButton
	local ring = Kit.new("Frame", {
		Name = "Ring",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(0, 0),
		BackgroundTransparency = 1,
		Parent = gui,
	}) :: Frame
	local scale = Kit.new("UIScale", { Scale = 1, Parent = ring }) :: UIScale
	local cards: { Card } = {}
	for slot = 1, 8 do
		local card = buildCard(ring, slot)
		cards[slot] = card
		card.button.Activated:Connect(function()
			if not open then
				return
			end
			local list = entries[slot] or {}
			if hovered == slot and #list > 1 and mode == "toggle" then
				commit()
				return
			end
			hovered = slot
			if #list <= 1 then
				commit()
			else
				render()
			end
		end)
		card.button.MouseEnter:Connect(function()
			if open and not UserInputService.TouchEnabled then
				hovered = slot
				render()
			end
		end)
	end
	local name = text(ring, {
		Name = "WeaponName",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(0, -18),
		Size = UDim2.fromOffset(230, 30),
		FontFace = Style.font("Condensed"),
		TextSize = 26,
		Text = "",
	})
	local category = text(ring, {
		Name = "Category",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(0, 6),
		Size = UDim2.fromOffset(230, 18),
		FontFace = Style.font("CondensedMedium"),
		TextSize = 15,
		TextColor3 = Style.Colors.TextDim,
		Text = "",
	})
	local ammo = text(ring, {
		Name = "Ammo",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(0, 28),
		Size = UDim2.fromOffset(230, 20),
		FontFace = Style.font("Numeric"),
		TextSize = 18,
		Text = "",
	})
	local cycleLabel = text(ring, {
		Name = "Cycle",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(0, 52),
		Size = UDim2.fromOffset(160, 20),
		FontFace = Style.font("CondensedMedium"),
		TextSize = 16,
		Text = "",
	})
	local function arrow(nameStr: string, x: number, dir: number): TextButton
		local b = Kit.new("TextButton", {
			Name = nameStr,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(x, 52),
			Size = UDim2.fromOffset(40, 36),
			BackgroundTransparency = 1,
			Text = "",
			Visible = false,
			Parent = ring,
		}) :: TextButton
		b.Activated:Connect(function()
			cycle(dir)
		end)
		return b
	end
	local prev = arrow("Prev", -62, -1)
	local nextB = arrow("Next", 62, 1)
	backdrop.Activated:Connect(function()
		if mode == "toggle" then
			WeaponWheel.close(false)
		else
			WeaponWheel.close(true)
		end
	end)
	return {
		gui = gui,
		backdrop = backdrop,
		ring = ring,
		scale = scale,
		cards = cards,
		name = name,
		category = category,
		ammo = ammo,
		cycle = cycleLabel,
		prev = prev,
		nextB = nextB,
	}
end

-- EFFECTS --------------------------------------------------------------------------------------------------------------

local function setBackdrop(on: boolean)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	if on then
		local b = blur
		if not b or b.Parent ~= cam then
			b = Instance.new("BlurEffect")
			b.Name = "HC_WheelBlur"
			b.Size = 0
			b.Parent = cam
			blur = b
		end
		local g = grade
		if not g or g.Parent ~= cam then
			g = Instance.new("ColorCorrectionEffect")
			g.Name = "HC_WheelGrade"
			g.Parent = cam
			grade = g
		end
		local info = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(b :: BlurEffect, info, { Size = WeaponWheel.BLUR }):Play()
		TweenService:Create(g :: ColorCorrectionEffect, info, { Saturation = -0.3, Brightness = -0.08 }):Play()
	else
		local info = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		if blur then
			TweenService:Create(blur, info, { Size = 0 }):Play()
		end
		if grade then
			TweenService:Create(grade, info, { Saturation = 0, Brightness = 0 }):Play()
		end
	end
	local snd = lazy("SoundController")
	if snd and typeof(snd.setMuffle) == "function" then
		pcall(snd.setMuffle, if on then WeaponWheel.MUFFLE else nil, 0, "wheel")
	end
end

local function setSlowWalk(on: boolean)
	if on then
		local hum = humanoid()
		if hum and not walkSaved then
			walkSaved = { hum = hum, speed = hum.WalkSpeed }
			hum.WalkSpeed = hum.WalkSpeed * WeaponWheel.WALK_MULT
		end
	else
		local saved = walkSaved
		walkSaved = nil
		if
			saved
			and saved.hum.Parent
			and math.abs(saved.hum.WalkSpeed - saved.speed * WeaponWheel.WALK_MULT) < 0.01
		then
			saved.hum.WalkSpeed = saved.speed
		end
	end
end

-- INPUT WHILE OPEN ---------------------------------------------------------------------------------------------------------

cycle = function(dir: number)
	local slot = hovered
	if not slot then
		return
	end
	local list = entries[slot] or {}
	if #list <= 1 then
		return
	end
	choice[slot] = ((choice[slot] or 1) - 1 + dir) % #list + 1
	render()
end

local function hoverFrom(v: Vector2)
	local slot = WeaponWheel._slotFromVector(v, WeaponWheel.DEAD_ZONE)
	if slot ~= hovered and slot ~= nil then
		hovered = slot
		render()
	end
end

local function onAction(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	local t = input.UserInputType
	local key = input.KeyCode
	if t == Enum.UserInputType.MouseMovement then
		cursor += Vector2.new(input.Delta.X, input.Delta.Y)
		if cursor.Magnitude > WeaponWheel.CURSOR_MAX then
			cursor = cursor.Unit * WeaponWheel.CURSOR_MAX
		end
		hoverFrom(cursor)
	elseif key == Enum.KeyCode.Thumbstick2 then
		local s = Vector2.new(input.Position.X, -input.Position.Y)
		if s.Magnitude >= WeaponWheel.STICK_DEAD then
			hoverFrom(s * WeaponWheel.CURSOR_MAX)
		end
	elseif t == Enum.UserInputType.MouseWheel then
		if state == Enum.UserInputState.Change then
			cycle(if input.Position.Z > 0 then -1 else 1)
		end
	elseif state == Enum.UserInputState.Begin then
		if key == Enum.KeyCode.Q or key == Enum.KeyCode.DPadLeft then
			cycle(-1)
		elseif key == Enum.KeyCode.E or key == Enum.KeyCode.DPadRight then
			cycle(1)
		elseif t == Enum.UserInputType.MouseButton1 or key == Enum.KeyCode.ButtonA then
			commit()
		end
	end
	return Enum.ContextActionResult.Sink
end

local function bindInput(on: boolean)
	if on then
		ContextActionService:BindActionAtPriority(
			ACTION,
			onAction,
			false,
			Enum.ContextActionPriority.High.Value + 100,
			Enum.UserInputType.MouseMovement,
			Enum.UserInputType.MouseWheel,
			Enum.UserInputType.MouseButton1,
			Enum.UserInputType.MouseButton2,
			Enum.KeyCode.Thumbstick2,
			Enum.KeyCode.ButtonR2,
			Enum.KeyCode.ButtonL2,
			Enum.KeyCode.ButtonA,
			Enum.KeyCode.Q,
			Enum.KeyCode.E,
			Enum.KeyCode.DPadLeft,
			Enum.KeyCode.DPadRight
		)
	else
		ContextActionService:UnbindAction(ACTION)
	end
end

-- OPEN / CLOSE ---------------------------------------------------------------------------------------------------------

local function apply(id: string?)
	if not id then
		return
	end
	if id == "medkit" then
		Net.fire("UseMedKit")
		return
	end
	if id == WeaponClient.equipped() then
		return
	end
	WeaponClient.select(id)
end

commit = function()
	local slot = hovered
	WeaponWheel.close(false)
	if slot then
		apply(currentEntry(slot))
	end
end

function WeaponWheel.open(how: ("hold" | "toggle")?)
	if open or not canOpen() then
		return
	end
	local v = view
	if not v then
		v = build()
		view = v
	end
	local vv = v :: View
	refreshEntries() -- while still closed: each slot starts on the weapon we hold
	open = true
	mode = how or "hold"
	openedAt = os.clock()
	cursor = Vector2.zero
	local cur = WeaponClient.equipped()
	hovered = nil
	if cur then
		for slot = 1, 8 do
			if table.find(entries[slot], cur) then
				hovered = slot
				break
			end
		end
	end
	vv.scale.Scale = Kit.uiScale((Theme :: any).TouchMinScale or 0.72)
	vv.gui.Enabled = true
	render()
	ShoulderCamera.setSuspended("wheel", true)
	setBackdrop(true)
	setSlowWalk(true)
	bindInput(true)
	local snd = lazy("SoundController")
	if snd then
		pcall(snd.play, "Click")
	end
end

function WeaponWheel.close(doCommit: boolean)
	if not open then
		return
	end
	local slot = hovered
	open = false
	lastOpenDuration = os.clock() - openedAt
	bindInput(false)
	setSlowWalk(false)
	setBackdrop(false)
	ShoulderCamera.setSuspended("wheel", false)
	local v = view
	if v then
		v.gui.Enabled = false
	end
	if doCommit and slot then
		apply(currentEntry(slot))
	end
end

function WeaponWheel.toggle()
	if open then
		WeaponWheel.close(false)
	else
		WeaponWheel.open("toggle")
	end
end

-- Closed-wheel cycling: next / previous entry in the slot of the equipped weapon.
local function quickCycle(dir: number)
	refreshEntries()
	local cur = WeaponClient.equipped()
	if not cur then
		return
	end
	for slot = 1, 8 do
		local list = entries[slot]
		local idx = table.find(list, cur)
		if idx and #list > 1 then
			local nextId = list[(idx - 1 + dir) % #list + 1]
			if nextId ~= "medkit" then
				WeaponClient.select(nextId)
			end
			return
		end
	end
end

-- Mouse-wheel cycling across every owned weapon (wheel order) while a gun is drawn.
local function cycleAll(dir: number)
	refreshEntries()
	local all: { string } = {}
	for slot = 1, 5 do
		for _, id in entries[slot] do
			table.insert(all, id)
		end
	end
	if #all < 2 then
		return
	end
	local cur = WeaponClient.equipped()
	local idx = if cur then table.find(all, cur) else nil
	local nextId = all[if idx then (idx - 1 + dir) % #all + 1 else 1]
	WeaponClient.select(nextId)
end

function WeaponWheel.init() end

function WeaponWheel.start()
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		local key = input.KeyCode
		if key == Enum.KeyCode.Tab or key == Enum.KeyCode.ButtonL1 then
			local hum = humanoid()
			if not hum or hum.SeatPart ~= nil then
				return -- L1 drops spikes while driving (CombatClient)
			end
			local now = os.clock()
			if key == Enum.KeyCode.Tab and now - lastTabUp < WeaponWheel.DOUBLE_TAP and lastOpenDuration < 0.25 then
				lastTabUp = -math.huge
				WeaponClient.holster()
				return
			end
			if open and mode == "toggle" then
				WeaponWheel.close(false)
			else
				WeaponWheel.open("hold")
			end
		elseif not open and (key == Enum.KeyCode.DPadLeft or key == Enum.KeyCode.DPadRight) then
			local hum = humanoid()
			if hum and hum.SeatPart == nil then
				quickCycle(if key == Enum.KeyCode.DPadLeft then -1 else 1)
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		local key = input.KeyCode
		if key == Enum.KeyCode.Tab or key == Enum.KeyCode.ButtonL1 then
			if key == Enum.KeyCode.Tab then
				lastTabUp = os.clock()
			end
			if open and mode == "hold" then
				WeaponWheel.close(true)
			end
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject, processed: boolean)
		if processed or open then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel and ShoulderCamera.isEngaged() then
			cycleAll(if input.Position.Z > 0 then -1 else 1)
		end
	end)
	WeaponClient.Changed:Connect(function()
		if open then
			refreshEntries()
			render()
		end
	end)
	player.CharacterAdded:Connect(function()
		WeaponWheel.close(false)
	end)
	-- per-character connections live in a Trove cleaned when the character goes, so old bodies are never kept alive
	local charTrove = Trove.new()
	local function watchSeat(char: Model)
		charTrove:Clean()
		local hum = char:WaitForChild("Humanoid", 10)
		if player.Character ~= char then
			return -- replaced while we waited
		end
		if hum and hum:IsA("Humanoid") then
			charTrove:Connect(hum.Seated, function(active: boolean)
				if active then
					WeaponWheel.close(false)
				end
			end)
			charTrove:Connect(hum.Died, function()
				WeaponWheel.close(false)
			end)
		end
	end
	player.CharacterAdded:Connect(watchSeat)
	player.CharacterRemoving:Connect(function()
		charTrove:Clean()
	end)
	if player.Character then
		task.spawn(watchSeat, player.Character)
	end
	-- Tab is ours (gta_ui_language §8: no CoreGui leaderboard). The CoreGui may not be registered yet at boot: retry.
	task.spawn(function()
		for _ = 1, 10 do
			if pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.PlayerList, false) then
				return
			end
			task.wait(1)
		end
	end)
end

return WeaponWheel
