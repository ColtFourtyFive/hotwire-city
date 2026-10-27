--!strict
-- DeathScreenController (gta_combat §7, gta_ui_language §5.9): the WASTED and BUSTED big-message sequences.
--
--  * HC_Shard (DisplayOrder 50): a full-width black band at 48.8% H, 19.5% H tall, ~50% opaque; lowercase title in the
--    heavy display face (`wasted` WastedRed #B3212F, `busted` Blue #5DB6E5), no stroke, TextScaled up to 110;
--    Montserrat 18 subtitle inside the band ("Hospital bill -$X", "Bail -$X · <Car> impounded"). No cartoon stamps,
--    no police lights, no emoji.
--  * Grade (local, under workspace.CurrentCamera): ColorCorrection saturation 0 -> -1, contrast +0.3, brightness -0.05
--    over 0.6 s, blur 3, dark edge vignette; SFX muffled (HighGain -25, MidGain -10); deep impact + reverse whoosh.
--  * WASTED: t=1.0 grade + a slow dolly up and back (2 studs/s) with a 6 degree dutch tilt and FOV -10 over 5 s;
--    t=1.2 shard; t=4.4 HC_Fade (DisplayOrder 60) to black; after the server respawns us (5 s): fade in 0.6 s, grade
--    off, feed "Treated at <Hospital>. Bill -$X".
--  * BUSTED (alive): grade + a 3/4 camera on us and the nearest officer, shard at 0.15 s, the world (not the band)
--    fades to black over the server's release teleport (1.1 s) and back, the shard holds to 4 s, feed "Released from
--    Police HQ. Bail -$X". BUSTED after dying while wanted follows the WASTED timing.
--  * While our shard is up, the v1 cartoon overlay (HUDController's HC_Busted) is switched off.
-- Remotes: Wasted({ by, police, bill, hospital }), Busted(lostCash, carLabel?).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Style = require(UI:WaitForChild("CombatStyle"))

local DeathScreenController = {}

DeathScreenController.GRADE_AT = 1.0
DeathScreenController.SHARD_AT = 1.2
DeathScreenController.FADE_AT = 4.4
DeathScreenController.FADE_TIME = 0.6
DeathScreenController.BUSTED_SHARD_AT = 0.15
DeathScreenController.BUSTED_BLACK_AT = 0.6
DeathScreenController.BUSTED_REVEAL_AT = 1.7
DeathScreenController.BUSTED_OUT_AT = 4.0
DeathScreenController.SAFETY = 9 -- clean up even if no respawn arrives
DeathScreenController.BAND_Y = 0.488
DeathScreenController.BAND_H = 0.195
DeathScreenController.BAND_ALPHA = 0.5

local player = Players.LocalPlayer

-- PURE -------------------------------------------------------------------------------------------------------------------

local function money(n: number): string
	return "$" .. Format.commas(math.max(0, math.floor(n)))
end

-- Subtitle under "wasted".
function DeathScreenController._wastedSubtitle(info: { [string]: any }): string
	local parts = {}
	local by = info.by
	if typeof(by) == "string" and by ~= "" then
		table.insert(parts, "Downed by " .. by)
	end
	local bill = info.bill
	if typeof(bill) == "number" and bill > 0 then
		table.insert(parts, "Hospital bill  -" .. money(bill))
	end
	return table.concat(parts, "   ·   ")
end

-- Subtitle under "busted".
function DeathScreenController._bustedSubtitle(lost: number, carLabel: string?): string
	local s = if lost > 0 then "Bail  -" .. money(lost) else "Released without bail"
	if carLabel and carLabel ~= "" then
		s ..= "   ·   " .. carLabel .. " impounded"
	end
	return s
end

-- Feed line after the respawn / release.
function DeathScreenController._feedText(kind: string, place: string?, amount: number, carLabel: string?): string
	if kind == "wasted" then
		local where = if place and place ~= "" then place else "the hospital"
		return if amount > 0
			then ("Treated at %s. Bill -%s"):format(where, money(amount))
			else ("Treated at %s."):format(where)
	end
	local s = if amount > 0
		then ("Released from Police HQ. Bail -%s"):format(money(amount))
		else "Released from Police HQ."
	if carLabel and carLabel ~= "" then
		s ..= " " .. carLabel .. " impounded."
	end
	return s
end

-- Camera CFrame for the wasted drift, `e` seconds in (pure; tested).
function DeathScreenController._driftCFrame(start: CFrame, target: Vector3, e: number): CFrame
	local back = -start.LookVector
	local flatBack = Vector3.new(back.X, 0, back.Z)
	flatBack = if flatBack.Magnitude > 1e-3 then flatBack.Unit else Vector3.new(0, 0, 1)
	local pos = start.Position + flatBack * (2 * e) + Vector3.new(0, 0.8 * e, 0)
	local roll = math.rad(6) * math.min(e / 1.5, 1)
	return CFrame.lookAt(pos, target) * CFrame.Angles(0, 0, roll)
end

-- STATE ------------------------------------------------------------------------------------------------------------------

type View = {
	shard: ScreenGui,
	band: Frame,
	title: TextLabel,
	titleScale: UIScale,
	subtitle: TextLabel,
	worldFade: Frame,
	vignette: Frame,
	fadeGui: ScreenGui,
	fade: Frame,
}

local view: View? = nil
local token = 0
local active: string? = nil
local awaitingRespawn = false
local pendingFeed: string? = nil
local driftConn: RBXScriptConnection? = nil
local savedFov: number? = nil
local grade: ColorCorrectionEffect? = nil
local blur: BlurEffect? = nil
local v1Overlay: { gui: ScreenGui, was: boolean }? = nil

local function lazy(name: string): any
	local mod = script.Parent:FindFirstChild(name)
	if not mod then
		return nil
	end
	local ok, res = pcall(require, mod :: any)
	return if ok and typeof(res) == "table" then res else nil
end

local function play(key: string)
	local snd = lazy("SoundController")
	if snd and typeof(snd.play) == "function" then
		pcall(snd.play, key)
	end
end

local function muffle(on: boolean)
	local snd = lazy("SoundController")
	if snd and typeof(snd.setMuffle) == "function" then
		if on then
			pcall(snd.setMuffle, -25, -10, "death")
		else
			pcall(snd.setMuffle, nil, nil, "death")
		end
	end
end

local function feed(text: string)
	local n = lazy("NotificationController")
	if n and typeof(n.feed) == "function" then
		pcall(n.feed, text)
	elseif n and typeof(n.toast) == "function" then
		pcall(n.toast, "info", text)
	end
end

local function edge(parent: Instance, size: UDim2, pos: UDim2, anchor: Vector2, rotation: number)
	local f = Kit.new("Frame", {
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
			NumberSequenceKeypoint.new(0, 0.15),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = f,
	})
end

local function fullScreen(name: string, order: number): ScreenGui
	local gui = Kit.new("ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = order,
		Enabled = false,
		Parent = player:WaitForChild("PlayerGui"),
	}) :: ScreenGui
	pcall(function()
		(gui :: any).ScreenInsets = Enum.ScreenInsets.None
	end)
	return gui
end

local function build(): View
	local shard = fullScreen("HC_Shard", Style.Layers.Shard)
	local worldFade = Kit.new("Frame", {
		Name = "WorldFade",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 1,
		Parent = shard,
	}) :: Frame
	local vignette = Kit.new("Frame", {
		Name = "Vignette",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 2,
		Visible = false,
		Parent = shard,
	}) :: Frame
	edge(vignette, UDim2.fromScale(1, 0.28), UDim2.fromScale(0, 0), Vector2.zero, 90)
	edge(vignette, UDim2.fromScale(1, 0.28), UDim2.fromScale(0, 1), Vector2.new(0, 1), -90)
	edge(vignette, UDim2.fromScale(0.22, 1), UDim2.fromScale(0, 0), Vector2.zero, 0)
	edge(vignette, UDim2.fromScale(0.22, 1), UDim2.fromScale(1, 0), Vector2.new(1, 0), 180)
	local band = Kit.new("Frame", {
		Name = "Band",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, DeathScreenController.BAND_Y),
		Size = UDim2.fromScale(1, 0),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = DeathScreenController.BAND_ALPHA,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = shard,
	}) :: Frame
	local title = Kit.new("TextLabel", {
		Name = "Title",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromScale(0.5, 0.62),
		BackgroundTransparency = 1,
		Text = "",
		TextScaled = true,
		TextTransparency = 1,
		FontFace = Style.font("Display"),
		TextColor3 = Style.Colors.WastedRed,
		ZIndex = 4,
		Parent = band,
	}) :: TextLabel
	Kit.new("UITextSizeConstraint", { MaxTextSize = 110, Parent = title })
	local titleScale = Kit.new("UIScale", { Scale = 1, Parent = title }) :: UIScale
	local subtitle = Kit.new("TextLabel", {
		Name = "Subtitle",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.86),
		Size = UDim2.fromScale(0.8, 0.18),
		BackgroundTransparency = 1,
		Text = "",
		TextTransparency = 1,
		TextSize = 18,
		FontFace = Style.font("Body"),
		TextColor3 = Style.Colors.Text,
		ZIndex = 4,
		Parent = band,
	}) :: TextLabel
	local fadeGui = fullScreen("HC_Fade", Style.Layers.Fade)
	local fade = Kit.new("Frame", {
		Name = "Black",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = fadeGui,
	}) :: Frame
	return {
		shard = shard,
		band = band,
		title = title,
		titleScale = titleScale,
		subtitle = subtitle,
		worldFade = worldFade,
		vignette = vignette,
		fadeGui = fadeGui,
		fade = fade,
	}
end

local function getView(): View
	local v = view
	if not v then
		v = build()
		view = v
	end
	return v :: View
end

-- EFFECTS --------------------------------------------------------------------------------------------------------------

local function tween(inst: Instance, t: number, props: { [string]: any })
	TweenService:Create(inst, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

local function setGrade(on: boolean, time: number)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	if on then
		local g = grade
		if not g or g.Parent ~= cam then
			g = Instance.new("ColorCorrectionEffect")
			g.Name = "HC_DeathGrade"
			g.Parent = cam
			grade = g
		end
		local b = blur
		if not b or b.Parent ~= cam then
			b = Instance.new("BlurEffect")
			b.Name = "HC_DeathBlur"
			b.Size = 0
			b.Parent = cam
			blur = b
		end
		tween(g :: ColorCorrectionEffect, time, { Saturation = -1, Contrast = 0.3, Brightness = -0.05 })
		tween(b :: BlurEffect, time, { Size = 3 })
		muffle(true)
	else
		if grade then
			tween(grade, time, { Saturation = 0, Contrast = 0, Brightness = 0 })
		end
		if blur then
			tween(blur, time, { Size = 0 })
		end
		muffle(false)
	end
	local v = getView()
	v.vignette.Visible = on
end

local function stopDrift()
	if driftConn then
		driftConn:Disconnect()
		driftConn = nil
	end
end

local function restoreCamera()
	stopDrift()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	if cam.CameraType == Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Custom
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		cam.CameraSubject = hum
	end
	if savedFov then
		cam.FieldOfView = savedFov
		savedFov = nil
	end
end

local function startDrift(target: Vector3)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	stopDrift()
	savedFov = cam.FieldOfView
	local startFov = cam.FieldOfView
	local start = cam.CFrame
	cam.CameraType = Enum.CameraType.Scriptable
	local t0 = os.clock()
	driftConn = RunService.RenderStepped:Connect(function()
		local e = os.clock() - t0
		cam.CFrame = DeathScreenController._driftCFrame(start, target, e)
		cam.FieldOfView = startFov - 10 * math.min(e / 5, 1)
	end)
end

local function nearestOfficer(pos: Vector3): Vector3?
	local npcs = Workspace:FindFirstChild("NPCs")
	local best: Vector3? = nil
	local bestD = 60
	if npcs then
		for _, m in npcs:GetChildren() do
			local r = m:FindFirstChild("HumanoidRootPart")
			if m.Name == "Officer" and r and r:IsA("BasePart") then
				local d = (r.Position - pos).Magnitude
				if d < bestD then
					bestD = d
					best = r.Position
				end
			end
		end
	end
	return best
end

local function arrestShot(root: BasePart)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	stopDrift()
	savedFov = cam.FieldOfView
	local cop = nearestOfficer(root.Position)
	local focus = if cop then (root.Position + cop) / 2 else root.Position
	local across = if cop then (cop - root.Position) else root.CFrame.LookVector
	local flat = Vector3.new(across.X, 0, across.Z)
	flat = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, 1)
	local side = flat:Cross(Vector3.yAxis)
	local camPos = focus + side * 10 - flat * 4 + Vector3.new(0, 3.5, 0)
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = CFrame.lookAt(camPos, focus + Vector3.new(0, 1, 0))
	cam.FieldOfView = 55
end

local function suppressV1(on: boolean)
	if on then
		local pg = player:FindFirstChildOfClass("PlayerGui")
		local g = pg and pg:FindFirstChild("HC_Busted")
		if g and g:IsA("ScreenGui") then
			if not v1Overlay then
				v1Overlay = { gui = g, was = g.Enabled }
			end
			g.Enabled = false
		end
	else
		local o = v1Overlay
		v1Overlay = nil
		if o and o.gui.Parent then
			-- leave the cartoon stamp's leftovers hidden: they finish their own tweens and clean up
			task.delay(2, function()
				if o.gui.Parent and not active then
					o.gui.Enabled = o.was
				end
			end)
		end
	end
end

-- SHARD ----------------------------------------------------------------------------------------------------------------

local function shardIn(titleText: string, color: Color3, subtitle: string)
	local v = getView()
	v.shard.Enabled = true
	v.title.Text = titleText
	v.title.TextColor3 = color
	v.title.TextTransparency = 1
	v.subtitle.Text = subtitle
	v.subtitle.TextTransparency = 1
	local cam = Workspace.CurrentCamera
	local vpY = if cam then cam.ViewportSize.Y else 720
	v.subtitle.TextSize = math.clamp(math.floor(18 * vpY / 720), 13, 30)
	v.band.Size = UDim2.fromScale(1, 0)
	v.band.BackgroundTransparency = DeathScreenController.BAND_ALPHA
	tween(v.band, 0.25, { Size = UDim2.fromScale(1, DeathScreenController.BAND_H) })
	v.titleScale.Scale = 1.12
	tween(v.titleScale, 0.35, { Scale = 1 })
	tween(v.title, 0.35, { TextTransparency = 0 })
	tween(v.subtitle, 0.5, { TextTransparency = 0 })
end

local function shardOut(time: number)
	local v = getView()
	tween(v.band, time, { BackgroundTransparency = 1 })
	tween(v.title, time, { TextTransparency = 1 })
	tween(v.subtitle, time, { TextTransparency = 1 })
	local my = token
	task.delay(time + 0.05, function()
		if my == token and not active then
			v.shard.Enabled = false
		end
	end)
end

local function fadeBlack(on: boolean, time: number)
	local v = getView()
	if on then
		v.fadeGui.Enabled = true
	end
	tween(v.fade, time, { BackgroundTransparency = if on then 0 else 1 })
	if not on then
		task.delay(time + 0.05, function()
			if v.fade.BackgroundTransparency >= 0.99 then
				v.fadeGui.Enabled = false
			end
		end)
	end
end

local function finish(time: number)
	active = nil
	awaitingRespawn = false
	restoreCamera()
	setGrade(false, time)
	local v = getView()
	v.worldFade.BackgroundTransparency = 1
	shardOut(time)
	fadeBlack(false, time)
	suppressV1(false)
	local text = pendingFeed
	pendingFeed = nil
	if text then
		feed(text)
	end
end

-- SEQUENCES ----------------------------------------------------------------------------------------------------------------

local function rootPosition(): Vector3?
	local char = player.Character
	local root = char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Head"))
	return if root and root:IsA("BasePart") then root.Position else nil
end

-- The dead variant (wasted, or busted after dying while wanted): ends when the next character spawns.
local function deadSequence(kind: string, titleText: string, color: Color3, subtitle: string)
	token += 1
	local my = token
	active = kind
	awaitingRespawn = true
	local target = rootPosition()
	task.delay(DeathScreenController.GRADE_AT, function()
		if my ~= token then
			return
		end
		setGrade(true, 0.6)
		if target then
			startDrift(target)
		end
		play(if kind == "wasted" then "Wasted" else "Busted")
		play("WastedImpact")
	end)
	task.delay(DeathScreenController.SHARD_AT, function()
		if my == token then
			shardIn(titleText, color, subtitle)
		end
	end)
	task.delay(DeathScreenController.FADE_AT, function()
		if my == token then
			fadeBlack(true, DeathScreenController.FADE_TIME)
		end
	end)
	task.delay(DeathScreenController.SAFETY, function()
		if my == token and active then
			finish(0.6)
		end
	end)
end

function DeathScreenController.showWasted(info: { [string]: any })
	local bill = if typeof(info.bill) == "number" then info.bill else 0
	pendingFeed = DeathScreenController._feedText(
		"wasted",
		if typeof(info.hospital) == "string" then info.hospital else nil,
		bill,
		nil
	)
	deadSequence("wasted", "wasted", Style.Colors.WastedRed, DeathScreenController._wastedSubtitle(info))
end

function DeathScreenController.showBusted(lost: number, carLabel: string?)
	suppressV1(true)
	task.defer(suppressV1, true) -- HUDController may build its overlay after us
	local subtitle = DeathScreenController._bustedSubtitle(lost, carLabel)
	pendingFeed = DeathScreenController._feedText("busted", nil, lost, carLabel)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or hum.Health <= 0 or not root or not root:IsA("BasePart") then
		deadSequence("busted", "busted", Style.Colors.Blue, subtitle)
		return
	end
	token += 1
	local my = token
	active = "busted"
	setGrade(true, 0.4)
	arrestShot(root)
	play("Busted")
	play("Handcuffs")
	local v = getView()
	task.delay(DeathScreenController.BUSTED_SHARD_AT, function()
		if my == token then
			shardIn("busted", Style.Colors.Blue, subtitle)
		end
	end)
	task.delay(DeathScreenController.BUSTED_BLACK_AT, function()
		if my == token then
			tween(v.worldFade, 0.4, { BackgroundTransparency = 0 })
		end
	end)
	task.delay(DeathScreenController.BUSTED_REVEAL_AT, function()
		if my == token then
			restoreCamera()
			tween(v.worldFade, 0.6, { BackgroundTransparency = 1 })
		end
	end)
	task.delay(DeathScreenController.BUSTED_OUT_AT, function()
		if my == token then
			finish(0.45)
		end
	end)
end

function DeathScreenController.isActive(): boolean
	return active ~= nil
end

function DeathScreenController.init() end

function DeathScreenController.start()
	pcall(Net.listen, "Wasted", function(info: any)
		DeathScreenController.showWasted(if typeof(info) == "table" then info else {})
	end)
	pcall(Net.listen, "Busted", function(lost: any, carLabel: any)
		DeathScreenController.showBusted(
			if typeof(lost) == "number" then lost else 0,
			if typeof(carLabel) == "string" then carLabel else nil
		)
	end)
	player.CharacterAdded:Connect(function()
		if active and awaitingRespawn then
			local my = token
			-- the new character is in place: reveal it
			task.delay(0.25, function()
				if my == token and active then
					finish(DeathScreenController.FADE_TIME)
				end
			end)
		end
	end)
end

return DeathScreenController
