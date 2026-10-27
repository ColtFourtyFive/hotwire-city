--!strict
-- CombatHUD (gta_combat §11.5, gta_ui_language §5.2 / §5.4): the combat layer of the GTA HUD.
--
--  * Health / armour / ability bars (192x6, split 50/25/25, 2 px gaps) under the radar, bottom-left; top-left under
--    the radar on touch (§7). Health #359A47 on a dark track; under 25% it turns Damage red and pulses at 1.5 Hz.
--    Armour Blue #5DB6E5 from the server's Armor attribute. The third (yellow) slot is the ability bar: setAbility().
--    The bars snap under B2's v2 radar (HC_HUD > Minimap) or the v1 radar (HC_Minimap > Radar) when either exists;
--    setBarsAnchor(frame) overrides that.
--  * Ammo top-right under the cash: clip in Text, reserve in TextDim, Kanit 26 (guns only). When B2's HUDController
--    is up (HC_HUD) the ammo goes through HUDController.setAmmo into its own line under the cash / delta lines, and
--    setAbility is forwarded to HUDController.setAbility; our label is only the fallback without it. The weapon
--    silhouette shows under the ammo line for 2 s after a switch (desktop; on touch WeaponClient's weapon button
--    takes that spot).
--  * Hidden with the HUD (HUDController.VisibilityChanged): streamer mode, photo mode and the pause menu hide the
--    bars / ammo / icon layer; the crosshair layer stays in streamer mode (you still have to aim).
--  * Crosshair (own full-screen gui, so its centre is the camera's centre): a 4 px dot that turns Red over a person,
--    four ticks that open with the live spread (SMGs, rifles, shotguns), and the marksman's scope overlay instead
--    while scoped.
--  * Hit markers from HitConfirm: thin white x (body), thick white x (head), Blue x (armour only), thick Red x (down);
--    80 ms then a fade, plus a quiet tick.
--  * Damage direction from DamageTaken: up to 4 red arcs around the crosshair that point at the shooter and fade over
--    1.5 s. No blood, no red screen overlay.
--  * Low health (< 30): local desaturation down to -0.5 and a dark edge vignette.
--  * Spawn protection: a faint white Highlight on every protected player (Protected attribute).
-- The Health CoreGui is disabled (these bars replace it).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Weapons = require(Shared:WaitForChild("Config"):WaitForChild("Weapons"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))
local Style = require(UI:WaitForChild("CombatStyle"))
local WeaponPreview = require(UI:WaitForChild("WeaponPreview"))

local ShoulderCamera = require(script.Parent:WaitForChild("ShoulderCamera"))
local WeaponClient = require(script.Parent:WaitForChild("WeaponClient"))

local CombatHUD = {}

CombatHUD.BAR_W = 192
CombatHUD.BAR_W_TOUCH = 168
CombatHUD.BAR_H = 6
CombatHUD.GAP = 2
CombatHUD.LOW_HEALTH = 0.25 -- bar turns red + pulses below this fraction
CombatHUD.LOW_GRADE_HP = 30 -- desaturation starts below this many HP
CombatHUD.ARC_LIFE = 1.5
CombatHUD.ARC_RADIUS = 120
CombatHUD.MARKER_HOLD = 0.08
CombatHUD.ICON_TIME = 2

local player = Players.LocalPlayer

-- PURE -----------------------------------------------------------------------------------------------------------------

-- Pixel offset of a spread tick from the screen centre: spread (deg, half-angle), vertical FOV (deg), viewport height.
function CombatHUD._spreadPixels(spreadDeg: number, fovDeg: number, viewportY: number): number
	local half = math.tan(math.rad(math.clamp(fovDeg, 1, 120)) / 2)
	return math.tan(math.rad(math.clamp(spreadDeg, 0, 45))) / half * (viewportY / 2)
end

-- Screen angle (degrees, 0 = straight ahead / up on screen, clockwise) from the camera's flat look to a world point.
function CombatHUD._arcAngle(camCF: CFrame, from: Vector3): number
	local look = camCF.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	local to = from - camCF.Position
	local flatTo = Vector3.new(to.X, 0, to.Z)
	if flatLook.Magnitude < 1e-3 or flatTo.Magnitude < 1e-3 then
		return 0
	end
	local a = math.atan2(flatLook.X, flatLook.Z)
	local b = math.atan2(flatTo.X, flatTo.Z)
	local d = math.deg(a - b)
	return (d + 180) % 360 - 180
end

-- Desaturation strength 0..1 for the low-health grade.
function CombatHUD._lowHealthK(health: number): number
	return math.clamp((CombatHUD.LOW_GRADE_HP - health) / 20, 0, 1)
end

local function hexOf(c: Color3): string
	return ("%02X%02X%02X"):format(
		math.floor(c.R * 255 + 0.5),
		math.floor(c.G * 255 + 0.5),
		math.floor(c.B * 255 + 0.5)
	)
end

-- Ammo readout (RichText): clip in Text, reserve in TextDim.
function CombatHUD._ammoText(mag: number, reserve: number): string
	return ('%d  <font color="#%s">%d</font>'):format(mag, hexOf(Style.Colors.TextDim), reserve)
end

-- STATE ------------------------------------------------------------------------------------------------------------------

type Segment = { track: Frame, fill: Frame, frac: number }
type Arc = { holder: Frame, bar: Frame, from: Vector3?, born: number }

type View = {
	hud: ScreenGui,
	bars: Frame,
	health: Segment,
	armor: Segment,
	ability: Segment,
	ammo: TextLabel,
	icon: ViewportFrame,
	iconPreview: WeaponPreview.Preview,
	center: ScreenGui,
	dot: Frame,
	ticks: { Frame },
	marker: Frame,
	markerBars: { Frame },
	arcs: { Arc },
	scope: Frame,
	scopeRing: Frame,
	scopeRingStroke: UIStroke,
	vignette: Frame,
}

local view: View? = nil
local hudCtl: any = nil -- B2's HUDController when it is running (owns the ammo line and the bars)
local hudOwnsAmmo = false
local sentMag = -2 -- last values sent to HUDController.setAmmo (-1 = hidden), so it is called on change only
local sentReserve = -2
local barsAnchor: GuiObject? = nil
local barsAnchorManual = false
local ability: number? = nil
local lastEquipped: string? = nil
local iconUntil = 0
local markerUntil = 0
local markerFade = 0
local lowGrade: ColorCorrectionEffect? = nil
local castParams: RaycastParams? = nil
local castFilterDirty = true
local overAt = -math.huge -- the crosshair's "over a person" raycast runs at OVER_RATE, not every frame
local overResult = false
local vignetteEdges: { Frame }? = nil
local protectedHighlights: { [Player]: Highlight } = {}

CombatHUD.OVER_INTERVAL = 1 / 12
local CAST_EXCLUDE = { ClientFX = true, Effects = true, HC_ClientSounds = true }
local TICK_DIRS = { Vector2.new(0, -1), Vector2.new(0, 1), Vector2.new(-1, 0), Vector2.new(1, 0) }

local function lazy(name: string): any
	local mod = script.Parent:FindFirstChild(name)
	if not mod then
		return nil
	end
	local ok, res = pcall(require, mod :: any)
	return if ok and typeof(res) == "table" then res else nil
end

local function isTouch(): boolean
	return Kit.isTouch()
end

-- BUILD ------------------------------------------------------------------------------------------------------------------

local function segment(
	parent: Instance,
	name: string,
	order: number,
	width: UDim,
	color: Color3,
	track: Color3
): Segment
	local t = Kit.new("Frame", {
		Name = name,
		Size = UDim2.new(width, UDim.new(1, 0)),
		BackgroundColor3 = track,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = parent,
	}) :: Frame
	local f = Kit.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = t,
	}) :: Frame
	return { track = t, fill = f, frac = 1 }
end

local function placeBars()
	local v = view
	if not v then
		return
	end
	local anchor = barsAnchor
	if anchor and anchor.Parent then
		-- a radar that already draws its own bars keeps them: ours hide (no duplicates)
		local theirs = anchor:FindFirstChild("Bars")
		v.bars.Visible = theirs == nil
		v.bars.Parent = anchor
		v.bars.AnchorPoint = Vector2.new(0, 0)
		v.bars.Position = UDim2.new(0, 0, 1, 4)
		v.bars.Size = UDim2.new(1, 0, 0, CombatHUD.BAR_H)
		return
	end
	v.bars.Visible = true
	v.bars.Parent = v.hud
	if isTouch() then
		v.bars.AnchorPoint = Vector2.new(0, 0)
		v.bars.Position = UDim2.fromOffset(Style.SAFE, Style.SAFE + 118 + 4)
		v.bars.Size = UDim2.fromOffset(CombatHUD.BAR_W_TOUCH, CombatHUD.BAR_H)
	else
		v.bars.AnchorPoint = Vector2.new(0, 1)
		v.bars.Position = UDim2.new(0, Style.SAFE, 1, -(Style.SAFE + 4))
		v.bars.Size = UDim2.fromOffset(CombatHUD.BAR_W, CombatHUD.BAR_H)
	end
end

local function line(parent: Instance, w: number, h: number, color: Color3): Frame
	local f = Kit.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(w, h),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = parent,
	}) :: Frame
	Kit.new("UIStroke", { Color = Color3.new(0, 0, 0), Transparency = 0.6, Thickness = 1, Parent = f })
	return f
end

local function edge(parent: Instance, name: string, size: UDim2, pos: UDim2, anchor: Vector2, rotation: number)
	local f = Kit.new("Frame", {
		Name = name,
		AnchorPoint = anchor,
		Position = pos,
		Size = size,
		BackgroundColor3 = Color3.new(0, 0, 0),
		BorderSizePixel = 0,
		Parent = parent,
	})
	Kit.new("UIGradient", {
		Rotation = rotation,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = f,
	})
end

local function build(): View
	-- HUD layer (design canvas, corner anchored)
	local hud = Kit.screen("HC_CombatHUD", Style.Layers.HUD, { touchMin = Theme.TouchMinScale })
	pcall(function()
		(hud :: any).ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	end)
	local bars = Kit.new("Frame", {
		Name = "HC_CombatBars",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(CombatHUD.BAR_W, CombatHUD.BAR_H),
		Parent = hud,
	}) :: Frame
	Kit.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, CombatHUD.GAP),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = bars,
	})
	local C = Style.Colors
	-- 50 / 25 / 25 of the width with two 2 px gaps
	local health = segment(bars, "Health", 1, UDim.new(0.5, -2), C.Health, C.HealthTrack)
	local armor = segment(bars, "Armor", 2, UDim.new(0.25, -1), C.Blue, C.BlueDark)
	local abilitySeg = segment(bars, "Ability", 3, UDim.new(0.25, -1), C.Yellow, C.YellowDark)
	abilitySeg.fill.Size = UDim2.fromScale(0, 1)
	abilitySeg.frac = 0
	local ammo = Kit.new("TextLabel", {
		Name = "Ammo",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -Style.SAFE, 0, 92),
		Size = UDim2.fromOffset(200, 28),
		BackgroundTransparency = 1,
		RichText = true,
		Text = "",
		TextColor3 = C.Text,
		FontFace = Style.font("Numeric"),
		TextSize = 26,
		TextXAlignment = Enum.TextXAlignment.Right,
		Visible = false,
		Parent = hud,
	}) :: TextLabel
	Kit.new("UIStroke", {
		Color = Color3.new(0, 0, 0),
		Thickness = 2,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Transparency = 0.2,
		Parent = ammo,
	})
	local icon = Kit.new("ViewportFrame", {
		Name = "WeaponIcon",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -Style.SAFE, 0, 124),
		Size = UDim2.fromOffset(96, 40),
		ImageColor3 = C.Text,
		Visible = false,
		Parent = hud,
	}) :: ViewportFrame

	-- centre layer (true viewport centre = the aim ray)
	local center = Kit.new("ScreenGui", {
		Name = "HC_Crosshair",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = Style.Layers.HUD,
		Parent = player:WaitForChild("PlayerGui"),
	}) :: ScreenGui
	pcall(function()
		(center :: any).ScreenInsets = Enum.ScreenInsets.None
	end)
	-- low-health vignette (edges darken)
	local vignette = Kit.new("Frame", {
		Name = "Vignette",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = center,
	}) :: Frame
	edge(vignette, "Top", UDim2.fromScale(1, 0.3), UDim2.fromScale(0, 0), Vector2.zero, 90)
	edge(vignette, "Bottom", UDim2.fromScale(1, 0.3), UDim2.fromScale(0, 1), Vector2.new(0, 1), -90)
	edge(vignette, "Left", UDim2.fromScale(0.25, 1), UDim2.fromScale(0, 0), Vector2.zero, 0)
	edge(vignette, "Right", UDim2.fromScale(0.25, 1), UDim2.fromScale(1, 0), Vector2.new(1, 0), 180)
	-- scope: black outside a circle (four frames + a thick ring stroke that rounds the window's corners)
	local scope = Kit.new("Frame", {
		Name = "Scope",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = center,
	}) :: Frame
	local black = Color3.new(0, 0, 0)
	local function block(anchor: Vector2, pos: UDim2, size: UDim2)
		Kit.new("Frame", {
			AnchorPoint = anchor,
			Position = pos,
			Size = size,
			BackgroundColor3 = black,
			BorderSizePixel = 0,
			Parent = scope,
		})
	end
	-- window = a square of side 0.9 H, centred; the blocks fill the rest
	block(Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.05))
	block(Vector2.new(0, 1), UDim2.fromScale(0, 1), UDim2.fromScale(1, 0.05))
	local ring = Kit.new("Frame", {
		Name = "Ring",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.9, 0.9),
		BackgroundTransparency = 1,
		Parent = scope,
	}) :: Frame
	Kit.new("UIAspectRatioConstraint", { AspectRatio = 1, DominantAxis = Enum.DominantAxis.Height, Parent = ring })
	Kit.new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = ring })
	local ringStroke = Kit.new("UIStroke", {
		Color = black,
		Thickness = 200,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = ring,
	}) :: UIStroke
	for _, spec in
		{
			{ UDim2.fromScale(0.5, 0.5), UDim2.new(1, 0, 0, 1) },
			{ UDim2.fromScale(0.5, 0.5), UDim2.new(0, 1, 1, 0) },
		}
	do
		Kit.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = spec[1],
			Size = spec[2],
			BackgroundColor3 = black,
			BackgroundTransparency = 0.2,
			BorderSizePixel = 0,
			Parent = ring,
		})
	end
	-- side blocks are sized every frame from the window size (aspect dependent)
	local leftBlock = Kit.new("Frame", {
		Name = "LeftBlock",
		BackgroundColor3 = black,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0.5, 1),
		Parent = scope,
	}) :: Frame
	local rightBlock = Kit.new("Frame", {
		Name = "RightBlock",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		BackgroundColor3 = black,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0.5, 1),
		Parent = scope,
	}) :: Frame
	ring:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		local w = ring.AbsoluteSize.X
		local vp = center.AbsoluteSize.X
		local side = math.max(0, (vp - w) / 2 + 1)
		leftBlock.Size = UDim2.new(0, side, 1, 0)
		rightBlock.Size = UDim2.new(0, side, 1, 0)
		ringStroke.Thickness = math.ceil(w * 0.22)
	end)

	local dot = Kit.new("Frame", {
		Name = "Dot",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(4, 4),
		BackgroundColor3 = C.TextPure,
		BorderSizePixel = 0,
		Visible = false,
		Parent = center,
	}) :: Frame
	Kit.new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = dot })
	Kit.new("UIStroke", { Color = black, Transparency = 0.5, Thickness = 1, Parent = dot })
	local ticks: { Frame } = {}
	for i = 1, 4 do
		local vertical = i <= 2
		local tick = line(center, if vertical then 2 else 7, if vertical then 7 else 2, C.TextPure)
		tick.BackgroundTransparency = 0.25
		tick.Visible = false
		tick.Position = UDim2.fromScale(0.5, 0.5)
		ticks[i] = tick
	end
	local marker = Kit.new("Frame", {
		Name = "HitMarker",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(0, 0),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = center,
	}) :: Frame
	local markerBars: { Frame } = {}
	for i = 1, 4 do
		local a = math.rad(45 + (i - 1) * 90)
		local bar = line(marker, 2, 8, C.TextPure)
		bar.Position = UDim2.fromOffset(math.sin(a) * 9, -math.cos(a) * 9)
		bar.Rotation = math.deg(a)
		markerBars[i] = bar
	end
	local arcs: { Arc } = {}
	for i = 1, 4 do
		local holder = Kit.new("Frame", {
			Name = "DamageArc" .. i,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(2 * CombatHUD.ARC_RADIUS + 12, 2 * CombatHUD.ARC_RADIUS + 12),
			BackgroundTransparency = 1,
			Visible = false,
			Parent = center,
		}) :: Frame
		local bar = Kit.new("Frame", {
			Name = "Arc",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0),
			Size = UDim2.fromOffset(110, 6),
			BackgroundColor3 = C.Damage,
			BackgroundTransparency = 0.3,
			BorderSizePixel = 0,
			Parent = holder,
		}) :: Frame
		Kit.new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = bar })
		Kit.new("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.3, 0),
				NumberSequenceKeypoint.new(0.7, 0),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Parent = bar,
		})
		arcs[i] = { holder = holder, bar = bar, from = nil, born = -math.huge }
	end
	return {
		hud = hud,
		bars = bars,
		health = health,
		armor = armor,
		ability = abilitySeg,
		ammo = ammo,
		icon = icon,
		iconPreview = WeaponPreview.new(icon, true),
		center = center,
		dot = dot,
		ticks = ticks,
		marker = marker,
		markerBars = markerBars,
		arcs = arcs,
		scope = scope,
		scopeRing = ring,
		scopeRingStroke = ringStroke,
		vignette = vignette,
	}
end

-- PUBLIC -----------------------------------------------------------------------------------------------------------------

-- Put the bars under another HUD frame (B2's radar). nil returns them to the default corner.
function CombatHUD.setBarsAnchor(frame: GuiObject?)
	barsAnchor = frame
	barsAnchorManual = frame ~= nil
	placeBars()
end

-- Ability (third, yellow) bar fill 0..1; nil empties it (HUDController: nil = its automatic nitro / stamina).
function CombatHUD.setAbility(fraction: number?)
	ability = if fraction then math.clamp(fraction, 0, 1) else nil
	if hudCtl and typeof(hudCtl.setAbility) == "function" then
		pcall(hudCtl.setAbility, ability)
	end
end

-- Hit marker (also driven by HitConfirm). kind: "body" | "head" | "armor" | "down".
function CombatHUD.hitMarker(kind: string)
	local v = view
	if not v then
		return
	end
	local C = Style.Colors
	local color = if kind == "down" then C.Red elseif kind == "armor" then C.Blue else C.TextPure
	local thick = kind == "head" or kind == "down"
	for _, bar in v.markerBars do
		bar.BackgroundColor3 = color
		bar.BackgroundTransparency = 0
		bar.Size = UDim2.fromOffset(if thick then 3 else 2, if thick then 10 else 8)
	end
	v.marker.Visible = true
	markerUntil = os.clock() + CombatHUD.MARKER_HOLD
	markerFade = markerUntil + 0.12
	local snd = lazy("SoundController")
	if snd then
		pcall(snd.play, "HitTick")
	end
end

-- Damage arc toward a world position.
function CombatHUD.damageFrom(from: Vector3?)
	local v = view
	if not v or not from then
		return
	end
	local oldest: Arc = v.arcs[1]
	for _, arc in v.arcs do
		if arc.born < oldest.born then
			oldest = arc
		end
	end
	oldest.from = from
	oldest.born = os.clock()
	oldest.holder.Visible = true
end

-- UPDATE ---------------------------------------------------------------------------------------------------------------

local function setFill(seg: Segment, frac: number)
	frac = math.clamp(frac, 0, 1)
	if math.abs(seg.frac - frac) < 0.002 then
		return
	end
	seg.frac = frac
	TweenService:Create(seg.fill, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(frac, 1),
	}):Play()
end

-- Built once; the filter only changes on a new character or a new top-level effects folder.
local function getCastParams(): RaycastParams
	local p = castParams
	if not p then
		p = RaycastParams.new()
		p.FilterType = Enum.RaycastFilterType.Exclude
		p.IgnoreWater = true
		castParams = p
	end
	if castFilterDirty then
		castFilterDirty = false
		local list: { Instance } = {}
		if player.Character then
			table.insert(list, player.Character)
		end
		for name in CAST_EXCLUDE do
			local f = Workspace:FindFirstChild(name)
			if f then
				table.insert(list, f)
			end
		end
		p.FilterDescendantsInstances = list
	end
	return p
end

local function overPersonNow(range: number): boolean
	local cam = Workspace.CurrentCamera
	if not cam then
		return false
	end
	local res = Workspace:Raycast(cam.CFrame.Position, cam.CFrame.LookVector * range, getCastParams())
	if not res then
		return false
	end
	local model = res.Instance:FindFirstAncestorOfClass("Model")
	while model do
		local hum = model:FindFirstChildOfClass("Humanoid")
		if hum then
			return hum.Health > 0
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return false
end

-- Throttled: the dot's colour can lag a twelfth of a second.
local function overPerson(range: number, now: number): boolean
	if now - overAt >= CombatHUD.OVER_INTERVAL then
		overAt = now
		overResult = overPersonNow(range)
	end
	return overResult
end

local function updateBars(v: View, now: number)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hp = if hum then hum.Health else 0
	local maxHp = if hum and hum.MaxHealth > 0 then hum.MaxHealth else 100
	local frac = hp / maxHp
	setFill(v.health, frac)
	local C = Style.Colors
	if frac < CombatHUD.LOW_HEALTH and hp > 0 then
		v.health.fill.BackgroundColor3 = C.Damage
		v.health.fill.BackgroundTransparency = 0.2 + 0.2 * math.sin(now * math.pi * 3)
	else
		v.health.fill.BackgroundColor3 = C.Health
		v.health.fill.BackgroundTransparency = 0
	end
	local armor = player:GetAttribute("Armor")
	setFill(v.armor, (if typeof(armor) == "number" then armor else 0) / 100)
	setFill(v.ability, ability or 0)
	return hp
end

local function updateLowHealth(v: View, hp: number, alive: boolean)
	local k = if alive then CombatHUD._lowHealthK(hp) else 0
	local cam = Workspace.CurrentCamera
	if k > 0 and cam then
		local g = lowGrade
		if not g or g.Parent ~= cam then
			g = Instance.new("ColorCorrectionEffect")
			g.Name = "HC_LowHealth"
			g.Parent = cam
			lowGrade = g
		end
		local gg = g :: ColorCorrectionEffect
		gg.Saturation = -0.5 * k
		gg.Contrast = 0.05 * k
		gg.Enabled = true
	elseif lowGrade then
		lowGrade.Enabled = false
	end
	v.vignette.Visible = k > 0
	if k > 0 then
		local edges = vignetteEdges
		if not edges then
			local list: { Frame } = {}
			for _, f in v.vignette:GetChildren() do
				if f:IsA("Frame") then
					table.insert(list, f)
				end
			end
			edges = list
			vignetteEdges = list
		end
		local alpha = 1 - 0.65 * k
		for _, f in edges :: { Frame } do
			if f.BackgroundTransparency ~= alpha then
				f.BackgroundTransparency = alpha
			end
		end
	end
end

-- Ammo: HUDController's line when it owns it (called on change only), else our fallback label.
local function showAmmo(v: View, gun: boolean, mag: number, reserve: number)
	if hudOwnsAmmo then
		if v.ammo.Visible then
			v.ammo.Visible = false
		end
		local m = if gun then mag else -1
		local r = if gun then reserve else -1
		if m ~= sentMag or r ~= sentReserve then
			sentMag, sentReserve = m, r
			pcall(hudCtl.setAmmo, if gun then mag else nil, if gun then reserve else nil)
		end
		return
	end
	v.ammo.Visible = gun
	if gun then
		v.ammo.Text = CombatHUD._ammoText(mag, reserve)
	end
end

local function updateWeapon(v: View, now: number)
	local st = WeaponClient.getState()
	local def: Weapons.WeaponDef? = st.def
	local gun = Weapons.isGun(def)
	showAmmo(v, gun, st.mag, st.reserve)
	-- switch icon
	local eq = WeaponClient.equipped()
	if eq ~= lastEquipped then
		lastEquipped = eq
		if eq and eq ~= "fists" and not isTouch() then
			WeaponPreview.show(v.iconPreview, eq)
			iconUntil = now + CombatHUD.ICON_TIME
		else
			iconUntil = 0
		end
	end
	v.icon.Visible = now < iconUntil
	-- crosshair / scope
	local engaged = gun and ShoulderCamera.isEngaged()
	local scoped = engaged and def ~= nil and def.scoped == true and ShoulderCamera.isAiming()
	v.scope.Visible = scoped
	v.dot.Visible = engaged and not scoped
	local showTicks = engaged
		and not scoped
		and def ~= nil
		and (def.class == "SMG" or def.class == "Rifle" or def.class == "Shotgun")
	local cam = Workspace.CurrentCamera
	if v.dot.Visible and def then
		v.dot.BackgroundColor3 = if overPerson(def.maxRange, now) then Style.Colors.Red else Style.Colors.TextPure
	end
	-- spread once per frame, no per-tick allocations
	local px = 0
	if showTicks and cam then
		px = math.clamp(CombatHUD._spreadPixels(st.spread, cam.FieldOfView, cam.ViewportSize.Y), 4, 140) + 4
	end
	for i, tick in v.ticks do
		if tick.Visible ~= showTicks then
			tick.Visible = showTicks
		end
		if showTicks and cam then
			local d = TICK_DIRS[i]
			tick.Position = UDim2.new(0.5, d.X * px, 0.5, d.Y * px)
		end
	end
end

local function updateMarker(v: View, now: number)
	if not v.marker.Visible then
		return
	end
	if now >= markerFade then
		v.marker.Visible = false
	elseif now > markerUntil then
		local k = (now - markerUntil) / (markerFade - markerUntil)
		for _, bar in v.markerBars do
			bar.BackgroundTransparency = k
		end
	end
end

local function updateArcs(v: View, now: number)
	local cam = Workspace.CurrentCamera
	for _, arc in v.arcs do
		if arc.holder.Visible then
			local age = now - arc.born
			if age >= CombatHUD.ARC_LIFE or not cam or not arc.from then
				arc.holder.Visible = false
			else
				arc.holder.Rotation = CombatHUD._arcAngle(cam.CFrame, arc.from :: Vector3)
				arc.bar.BackgroundTransparency = 0.3 + 0.7 * (age / CombatHUD.ARC_LIFE)
			end
		end
	end
end

local function updateProtected()
	local now = Workspace:GetServerTimeNow()
	for _, p in Players:GetPlayers() do
		local untilT = p:GetAttribute("Protected")
		local on = typeof(untilT) == "number" and untilT > now
		local char = p.Character
		local h = protectedHighlights[p]
		if on and char then
			if not h or h.Parent ~= char then
				local nh = Instance.new("Highlight")
				nh.Name = "HC_Protected"
				nh.FillColor = Color3.new(1, 1, 1)
				nh.FillTransparency = 0.88
				nh.OutlineColor = Color3.new(1, 1, 1)
				nh.OutlineTransparency = 0.45
				nh.DepthMode = Enum.HighlightDepthMode.Occluded
				nh.Parent = char
				protectedHighlights[p] = nh
			end
		elseif h then
			h:Destroy()
			protectedHighlights[p] = nil
		end
	end
end

-- Where the weapon icon goes: under HUDController's ammo line (design px on the same Kit.screen canvas), else under
-- our own label. Pure (tests).
function CombatHUD._iconPosition(ammoRect: { x: number, y: number, w: number, h: number }?): UDim2
	if ammoRect then
		return UDim2.fromOffset(ammoRect.x + ammoRect.w, ammoRect.y + ammoRect.h + 2)
	end
	return UDim2.new(1, -Style.SAFE, 0, 124)
end

local function placeIcon()
	local v = view
	if not v then
		return
	end
	local rect: { x: number, y: number, w: number, h: number }? = nil
	if hudOwnsAmmo and typeof(hudCtl.getLayout) == "function" then
		local ok, L = pcall(hudCtl.getLayout)
		if ok and typeof(L) == "table" and typeof(L.ammo) == "table" then
			rect = L.ammo
		end
	end
	v.icon.Position = CombatHUD._iconPosition(rect)
end

-- HUDController owns the ammo line once its HC_HUD exists (it mounts in its own start()).
local function refreshHudOwnership()
	local pg = player:FindFirstChildOfClass("PlayerGui")
	local owns = hudCtl ~= nil
		and typeof(hudCtl.setAmmo) == "function"
		and pg ~= nil
		and pg:FindFirstChild("HC_HUD") ~= nil
	if owns ~= hudOwnsAmmo then
		hudOwnsAmmo = owns
		sentMag, sentReserve = -2, -2
		placeIcon()
	end
end

-- Streamer mode / photo mode / pause hide the bars, ammo and icon; only photo mode and pause hide the crosshair.
local function applyHudHidden()
	local v = view
	if not v or not hudCtl or typeof(hudCtl.hiddenState) ~= "function" then
		return
	end
	local ok, streamer, photo, paused = pcall(hudCtl.hiddenState)
	if not ok then
		return
	end
	v.hud.Enabled = not (streamer or photo or paused)
	v.center.Enabled = not (photo or paused)
end

-- Find a radar frame to hang the bars under (B2's v2 HUD first, then the v1 radar).
local function findRadar(): GuiObject?
	local pg = player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return nil
	end
	local hud = pg:FindFirstChild("HC_HUD")
	local mm = hud and hud:FindFirstChild("Minimap", true)
	if mm and mm:IsA("GuiObject") then
		return mm
	end
	local v1 = pg:FindFirstChild("HC_Minimap")
	local radar = v1 and v1:FindFirstChild("Radar")
	if radar and radar:IsA("GuiObject") then
		return radar
	end
	return nil
end

function CombatHUD.init() end

function CombatHUD.start()
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
	end)
	local v = build()
	view = v
	placeBars()
	hudCtl = lazy("HUDController")
	refreshHudOwnership()
	if hudCtl then
		if typeof(hudCtl.LayoutChanged) == "table" then
			hudCtl.LayoutChanged:Connect(placeIcon)
		end
		if typeof(hudCtl.VisibilityChanged) == "table" then
			hudCtl.VisibilityChanged:Connect(applyHudHidden)
		end
		applyHudHidden()
	end
	pcall(Net.listen, "HitConfirm", function(kind: any)
		if typeof(kind) == "string" then
			CombatHUD.hitMarker(kind)
		end
	end)
	pcall(Net.listen, "DamageTaken", function(from: any, amount: any)
		if typeof(from) == "Vector3" and Net.isFiniteVector(from) then
			CombatHUD.damageFrom(from)
		end
		if typeof(amount) == "number" and amount > 0 and ShoulderCamera.isEngaged() then
			ShoulderCamera.shake(0.12)
		end
	end)
	player.CharacterAdded:Connect(function()
		castFilterDirty = true
	end)
	Workspace.ChildAdded:Connect(function(child: Instance)
		if CAST_EXCLUDE[child.Name] then
			castFilterDirty = true
		end
	end)
	local slowAcc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		local now = os.clock()
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local hp = updateBars(v, now)
		updateLowHealth(v, hp, hum ~= nil and hum.Health > 0)
		updateWeapon(v, now)
		updateMarker(v, now)
		updateArcs(v, now)
		slowAcc += dt
		if slowAcc >= 0.25 then
			slowAcc = 0
			updateProtected()
			refreshHudOwnership()
			if not barsAnchorManual then
				local radar = findRadar()
				if radar ~= barsAnchor then
					barsAnchor = radar
					placeBars()
				end
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(p: Player)
		local h = protectedHighlights[p]
		if h then
			h:Destroy()
			protectedHighlights[p] = nil
		end
	end)
end

return CombatHUD
