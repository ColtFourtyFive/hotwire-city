--!strict
-- CombatClient (SPEC §7): combat tool feel on the client.
--  * Tool.Activated (any Tool with a ToolId attribute) -> Net.fire("ToolAction", toolId, aim)
--    aim: mouse hit (PC), last tap / screen center (touch), camera look (gamepad) + gentle aim assist.
--  * Local juice: real swing/lunge animation through the default Animate script's "toolanim" StringValue (replicates
--    to everyone because it plays on our own Animator), bat swing trail + glints off the barrel, Zapper coil flash +
--    muzzle sparks / glow at the tip (VFXLibrary presets). Impacts (BONK star, ZAP sparks) are EffectsController's,
--    from the server's Effect broadcast, so nobody sees them twice.
--  * Big round touch button with a cooldown ring for the equipped tool (also from a car seat, next to DrivingUI's
--    cluster), and a SPIKES button while driving (also key G / gamepad L1); both bottom-anchored like DrivingUI.
--  * Knockback remote -> AssemblyLinearVelocity on our HumanoidRootPart + PlatformStand ragdoll-lite, camera shake.
--  * While our player attribute Stunned is true: WalkSpeed/Jump 0 and prompts off; restored afterwards.
--  * Cartoon stars spin above the head of EVERY stunned player (attribute replicated by the server).

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Economy = require(Shared:WaitForChild("Config"):WaitForChild("Economy"))
local Trove = require(Shared:WaitForChild("Util"):WaitForChild("Trove"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))
local VFXLibrary = require(script.Parent:WaitForChild("VFXLibrary"))

local CombatClient = {}

local player = Players.LocalPlayer
local rng = Random.new()

local TOOL_VISUALS: { [string]: { icon: string, caption: string, color: Color3 } } = {
	bat = { icon = "🏏", caption = "BONK", color = Theme.Colors.Primary },
	taser = { icon = "⚡", caption = "ZAP", color = Theme.Colors.Secondary },
	spikes = { icon = "📌", caption = "SPIKES", color = Theme.Colors.Warning },
}

local TOUCH_AIM_MEMORY = 0.45 -- seconds a tap position stays the aim point
local ASSIST_RADIUS_MOUSE = 60 -- px
local ASSIST_RADIUS_TOUCH = 170 -- px (touch + gamepad are imprecise)
local BAT_AUTO_TARGET = Economy.BAT_RANGE + 1.5
-- SPIKES touch button (92 px): spans x W-236..W-144, y H-262..H-170 on the design canvas, left of VehicleClient's
-- HORN (x W-124..W-40) and EXIT (H-354..H-270), above DRIFT (top H-128) and NITRO (top H-150).
local SPIKE_BUTTON_SIZE = 92
local SPIKE_BUTTON_ANCHOR = Vector2.new(1, 1)
local SPIKE_BUTTON_POSITION = UDim2.new(1, -144, 1, -170)
-- Action (BONK / ZAP) button: on foot it clears the touch jump button; in a car (tool still equipped: a victim can
-- swing at the thief from the seat) it moves left of EXIT, above SPIKES (x W-244..W-144, y H-382..H-282).
local ACTION_BUTTON_SIZE = 100
local ACTION_BUTTON_POSITION = UDim2.new(1, -28, 1, -290)
local ACTION_BUTTON_DRIVING_POSITION = UDim2.new(1, -144, 1, -282)

-- state
local cooldownEnds: { [string]: number } = {}
local cooldownLength: { [string]: number } = {}
local hookedTools: { [Tool]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local equippedTool: Tool? = nil
local lastTouchPos: Vector2? = nil
local lastTouchAt = -math.huge
local aimParams: RaycastParams? = nil
local knockToken = 0
local knockedDown = false
local frozen: { humanoid: Humanoid, walk: number, jumpPower: number, jumpHeight: number }? = nil
local promptsDisabledByUs = false
local shakeConn: RBXScriptConnection? = nil
local stateController: any = nil
local notificationController: any = nil
local soundController: any = nil

type RoundButton = {
	button: TextButton,
	icon: TextLabel,
	caption: TextLabel,
	inner: Frame,
	setFill: (number) -> (),
	ready: boolean,
}
local actionButton: RoundButton? = nil
local spikeButton: RoundButton? = nil

-------------------------------------------------------------------------------------------------------------------------
-- helpers
-------------------------------------------------------------------------------------------------------------------------

local function lazyController(name: string): any
	local folder = script.Parent
	local mod = folder and folder:FindFirstChild(name)
	if not mod then
		return false
	end
	local ok, result = pcall(require, mod :: any)
	return if ok and typeof(result) == "table" then result else false
end

local function playSound(key: string, position: Vector3?)
	if soundController == nil then
		soundController = lazyController("SoundController")
	end
	if soundController and typeof(soundController.play) == "function" then
		pcall(soundController.play, key, position)
	end
end

local function toast(kind: string, text: string)
	if notificationController == nil then
		notificationController = lazyController("NotificationController")
	end
	if notificationController and typeof(notificationController.toast) == "function" then
		pcall(notificationController.toast, kind, text)
	end
end

local function hasTaserPass(): boolean
	if stateController == nil then
		stateController = lazyController("StateController")
	end
	if stateController and typeof(stateController.get) == "function" then
		local ok, snap = pcall(stateController.get)
		if ok and typeof(snap) == "table" and typeof(snap.passes) == "table" then
			return snap.passes.taser == true
		end
	end
	return false
end

local function cooldownFor(toolId: string): number
	local def = Economy.Tools[toolId]
	if not def then
		return 1
	end
	if toolId == "taser" and hasTaserPass() then
		return def.cooldown * 0.5
	end
	return def.cooldown
end

local function getCharacterParts(): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	return character, humanoid, if root and root:IsA("BasePart") then root else nil
end

local function isStunned(): boolean
	return player:GetAttribute("Stunned") == true
end

local function isDriving(): boolean
	if player:GetAttribute("Driving") == true then
		return true
	end
	local _, humanoid = getCharacterParts()
	return humanoid ~= nil and humanoid.SeatPart ~= nil and humanoid.SeatPart:IsA("VehicleSeat")
end

local function findOwnedTool(toolId: string): Tool?
	for _, container in { player.Character, player:FindFirstChildOfClass("Backpack") } do
		if container then
			for _, child in (container :: Instance):GetChildren() do
				if child:IsA("Tool") and child:GetAttribute("ToolId") == toolId then
					return child
				end
			end
		end
	end
	return nil
end

-------------------------------------------------------------------------------------------------------------------------
-- aim
-------------------------------------------------------------------------------------------------------------------------

local function getAimParams(character: Model?): RaycastParams
	local params = aimParams
	if not params then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.IgnoreWater = true
		aimParams = params
	end
	local exclude: { Instance } = {}
	if character then
		table.insert(exclude, character)
	end
	local fx = Workspace:FindFirstChild("ClientFX")
	if fx then
		table.insert(exclude, fx)
	end
	local effects = Workspace:FindFirstChild("Effects")
	if effects then
		table.insert(exclude, effects)
	end
	params.FilterDescendantsInstances = exclude
	return params
end

local function isGamepad(t: Enum.UserInputType): boolean
	return t.Name:sub(1, 7) == "Gamepad"
end

-- Screen point (viewport coordinates) the player is aiming at, plus whether input is imprecise (touch/gamepad).
local function aimScreenPoint(camera: Camera): (Vector2, boolean)
	local last = UserInputService:GetLastInputType()
	if last == Enum.UserInputType.Touch then
		if lastTouchPos and os.clock() - lastTouchAt < TOUCH_AIM_MEMORY then
			return lastTouchPos, true
		end
		return camera.ViewportSize / 2, true
	elseif isGamepad(last) then
		return camera.ViewportSize / 2, true
	end
	if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
		return camera.ViewportSize / 2, false
	end
	return UserInputService:GetMouseLocation(), false
end

-- Nearest other player's root whose screen position is within `radius` px of `screenPoint` and within `range` studs.
local function assistTarget(
	camera: Camera,
	screenPoint: Vector2,
	radius: number,
	origin: Vector3,
	range: number
): BasePart?
	local best: BasePart? = nil
	local bestScore = radius
	for _, other in Players:GetPlayers() do
		if other ~= player then
			local character = other.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") and (root.Position - origin).Magnitude <= range then
				local sp, onScreen = camera:WorldToViewportPoint(root.Position)
				if onScreen and sp.Z > 0 then
					local d = (Vector2.new(sp.X, sp.Y) - screenPoint).Magnitude
					if d < bestScore then
						bestScore = d
						best = root
					end
				end
			end
		end
	end
	return best
end

local function nearestPlayerRoot(origin: Vector3, range: number): BasePart?
	local best: BasePart? = nil
	local bestDist = range
	for _, other in Players:GetPlayers() do
		if other ~= player then
			local character = other.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
				local d = (root.Position - origin).Magnitude
				if d < bestDist then
					bestDist = d
					best = root
				end
			end
		end
	end
	return best
end

local function computeAim(toolId: string): Vector3?
	local camera = Workspace.CurrentCamera
	local character, humanoid, root = getCharacterParts()
	if not camera or not root then
		return nil
	end
	if toolId == "bat" then
		-- forgiving melee: auto-target the nearest player in reach and turn to face them
		local target = nearestPlayerRoot(root.Position, BAT_AUTO_TARGET)
		if target then
			if humanoid and not humanoid.SeatPart and not humanoid.PlatformStand then
				local look = Vector3.new(target.Position.X, root.Position.Y, target.Position.Z)
				if (look - root.Position).Magnitude > 0.2 then
					root.CFrame = CFrame.lookAt(root.Position, look)
				end
			end
			return target.Position
		end
	end
	local screenPoint, imprecise = aimScreenPoint(camera)
	if toolId == "taser" then
		local assist = assistTarget(
			camera,
			screenPoint,
			if imprecise then ASSIST_RADIUS_TOUCH else ASSIST_RADIUS_MOUSE,
			root.Position,
			Economy.TASER_RANGE + 4
		)
		if assist then
			return assist.Position
		end
	end
	local ray = camera:ViewportPointToRay(screenPoint.X, screenPoint.Y)
	local result = Workspace:Raycast(ray.Origin, ray.Direction * 1000, getAimParams(character))
	return if result then result.Position else ray.Origin + ray.Direction * 300
end

-------------------------------------------------------------------------------------------------------------------------
-- local feedback
-------------------------------------------------------------------------------------------------------------------------

-- The default Animate script plays its "toolslash"/"toollunge" animation when a StringValue named toolanim appears.
local function playToolAnim(tool: Tool, anim: string)
	local sv = Instance.new("StringValue")
	sv.Name = "toolanim"
	sv.Value = anim
	sv.Parent = tool
	task.delay(1, function()
		if sv.Parent then
			sv:Destroy()
		end
	end)
end

local function swingFeedback(toolId: string, tool: Tool?)
	if toolId == "bat" then
		playSound("Whoosh")
		if tool then
			playToolAnim(tool, "Slash")
			local handle = tool:FindFirstChild("Handle")
			local trail = handle and handle:FindFirstChild("SwingTrail")
			if trail and trail:IsA("Trail") then
				trail.Enabled = true
				task.delay(0.3, function()
					if trail.Parent then
						trail.Enabled = false
					end
				end)
			end
			local cap = tool:FindFirstChild("Cap")
			if cap and cap:IsA("BasePart") then
				pcall(
					VFXLibrary.burst,
					"Sparkle",
					cap.Position,
					{ count = 5, scale = 0.6, color = Theme.Colors.Primary }
				)
			end
		end
	elseif toolId == "taser" then
		if tool then
			playToolAnim(tool, "Lunge")
			local tip = tool:FindFirstChild("Tip")
			local glow = tip and tip:FindFirstChild("Glow")
			if glow and glow:IsA("PointLight") then
				glow.Brightness = 8
				TweenService:Create(glow, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Brightness = 1.2,
				}):Play()
			end
			if tip and tip:IsA("BasePart") then
				local handle = tool:FindFirstChild("Handle")
				local forward = if handle and handle:IsA("BasePart") then handle.CFrame.LookVector else nil
				pcall(VFXLibrary.burst, "Sparks", tip.Position, {
					count = 10,
					scale = 0.5,
					color = Color3.fromRGB(170, 255, 150),
					direction = forward,
				})
				pcall(VFXLibrary.burst, "Flash", tip.Position, { scale = 0.3, color = Color3.fromRGB(150, 255, 140) })
			end
			for _, child in tool:GetChildren() do
				if child:IsA("BasePart") and child.Name:sub(1, 4) == "Coil" then
					local original = child.Color
					child.Color = Color3.new(1, 1, 1)
					TweenService:Create(child, TweenInfo.new(0.4), { Color = original }):Play()
				end
			end
		end
	end
end

local function shakeCamera(duration: number, magnitude: number)
	local _, humanoid = getCharacterParts()
	if not humanoid then
		return
	end
	if shakeConn then
		shakeConn:Disconnect()
		shakeConn = nil
	end
	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.PreRender:Connect(function()
		local k = 1 - (os.clock() - t0) / duration
		if k <= 0 or not humanoid.Parent then
			if humanoid.Parent then
				humanoid.CameraOffset = Vector3.zero
			end
			conn:Disconnect()
			if shakeConn == conn then
				shakeConn = nil
			end
			return
		end
		humanoid.CameraOffset = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), 0) * magnitude * k
	end)
	shakeConn = conn
end

-------------------------------------------------------------------------------------------------------------------------
-- activation
-------------------------------------------------------------------------------------------------------------------------

local refreshButtons: () -> () = function() end -- assigned below (needs the UI helpers)

local function denyPulse(rb: RoundButton?)
	if rb then
		Kit.pop(rb.button, 0.85)
	end
end

local function activate(toolId: string, tool: Tool?)
	if not Economy.Tools[toolId] then
		return
	end
	if isStunned() then
		return
	end
	local now = os.clock()
	if (cooldownEnds[toolId] or 0) > now + 0.05 then
		denyPulse(
			if toolId == "spikes" and spikeButton and spikeButton.button.Visible then spikeButton else actionButton
		)
		return
	end
	if toolId == "spikes" and not isDriving() then
		toast("warning", "Hop in a car to drop spikes!")
		return
	end
	local aim = if toolId == "spikes" then nil else computeAim(toolId)
	Net.fire("ToolAction", toolId, aim)
	local duration = cooldownFor(toolId)
	cooldownEnds[toolId] = now + duration
	cooldownLength[toolId] = duration
	swingFeedback(toolId, tool)
end

local function hookTool(tool: Tool)
	if hookedTools[tool] then
		return
	end
	local id = tool:GetAttribute("ToolId")
	if typeof(id) ~= "string" then
		return
	end
	hookedTools[tool] = true
	tool.Activated:Connect(function()
		activate(id, tool)
	end)
	tool.Equipped:Connect(function()
		equippedTool = tool
		refreshButtons()
	end)
	tool.Unequipped:Connect(function()
		if equippedTool == tool then
			equippedTool = nil
		end
		refreshButtons()
	end)
	if tool.Parent and tool.Parent == player.Character then
		equippedTool = tool
	end
end

local function watchContainer(container: Instance, trove: Trove.Trove)
	for _, child in container:GetChildren() do
		if child:IsA("Tool") then
			hookTool(child)
		end
	end
	trove:Connect(container.ChildAdded, function(child: Instance)
		if child:IsA("Tool") then
			hookTool(child)
			refreshButtons()
		end
	end)
	trove:Connect(container.ChildRemoved, function(child: Instance)
		if child == equippedTool and child.Parent ~= player.Character then
			equippedTool = nil
		end
		refreshButtons()
	end)
end

-------------------------------------------------------------------------------------------------------------------------
-- UI: round buttons with a radial cooldown ring
-------------------------------------------------------------------------------------------------------------------------

local function makeRoundButton(parent: Instance, name: string, color: Color3, size: number): RoundButton
	local button = Kit.new("TextButton", {
		Name = name,
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = Theme.Colors.Stroke,
		BackgroundTransparency = 0.15,
		Size = UDim2.fromOffset(size, size),
		Visible = false,
		Parent = parent,
	}) :: TextButton
	Kit.corner(UDim.new(1, 0)).Parent = button
	Kit.stroke(Theme.Colors.Stroke, 3).Parent = button

	-- two clipped halves; each holds a full disc whose UIGradient hides one side -> clockwise radial fill
	local function half(isRight: boolean): UIGradient
		local clip = Kit.new("Frame", {
			Name = if isRight then "RightClip" else "LeftClip",
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			Size = UDim2.fromScale(0.5, 1),
			Position = UDim2.fromScale(if isRight then 0.5 else 0, 0),
			ZIndex = 2,
			Parent = button,
		})
		local disc = Kit.new("Frame", {
			Name = "Disc",
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(2, 1),
			Position = UDim2.fromScale(if isRight then -1 else 0, 0),
			ZIndex = 2,
			Parent = clip,
		})
		Kit.corner(UDim.new(1, 0)).Parent = disc
		return Kit.new("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.499, 0),
				NumberSequenceKeypoint.new(0.5, 1),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Rotation = if isRight then 0 else 180,
			Parent = disc,
		}) :: UIGradient
	end
	local rightGrad = half(true)
	local leftGrad = half(false)

	local inner = Kit.new("Frame", {
		Name = "Inner",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.8, 0.8),
		BackgroundColor3 = Theme.Colors.PanelLight,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = button,
	}) :: Frame
	Kit.corner(UDim.new(1, 0)).Parent = inner
	Kit.stroke(Theme.Colors.Stroke, 2).Parent = inner
	Kit.gradient(Color3.new(1, 1, 1), Color3.fromRGB(175, 175, 195)).Parent = inner

	local icon = Kit.new("TextLabel", {
		Name = "Icon",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.62, 0.62),
		Text = "",
		TextScaled = true,
		FontFace = Theme.Fonts.Display,
		TextColor3 = Theme.Colors.Text,
		ZIndex = 4,
		Parent = inner,
	}) :: TextLabel

	local caption = Kit.label("", 16, {
		Name = "Caption",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, 2),
		Size = UDim2.new(1.6, 0, 0, 20),
		ZIndex = 4,
	})
	caption.Parent = button

	local function setFill(f: number)
		local a = math.clamp(f, 0, 1) * 360
		rightGrad.Rotation = math.clamp(a, 0, 180)
		leftGrad.Rotation = math.clamp(a, 180, 360)
	end
	setFill(1)
	Kit.juice(button)
	return { button = button, icon = icon, caption = caption, inner = inner, setFill = setFill, ready = true }
end

local function styleButton(rb: RoundButton, toolId: string, keyHint: string?)
	local v = TOOL_VISUALS[toolId]
	if not v then
		return
	end
	rb.icon.Text = v.icon
	rb.caption.Text = if keyHint then `{v.caption} <font size="12">[{keyHint}]</font>` else v.caption
	for _, clip in rb.button:GetChildren() do
		local disc = clip:FindFirstChild("Disc")
		if disc and disc:IsA("Frame") then
			disc.BackgroundColor3 = v.color
		end
	end
end

local function updateCooldownVisual(rb: RoundButton?, toolId: string?, now: number)
	if not rb or not toolId or not rb.button.Visible then
		return
	end
	local ends = cooldownEnds[toolId] or 0
	local length = cooldownLength[toolId] or 1
	local remaining = ends - now
	if remaining > 0 then
		rb.setFill(1 - remaining / math.max(length, 0.01))
		if rb.ready then
			rb.ready = false
			rb.icon.TextTransparency = 0.45
		end
	elseif not rb.ready then
		rb.ready = true
		rb.setFill(1)
		rb.icon.TextTransparency = 0
		Kit.pop(rb.button, 1.18)
	end
end

local function equippedToolId(): string?
	local tool = equippedTool
	if tool and tool.Parent == player.Character then
		local id = tool:GetAttribute("ToolId")
		if typeof(id) == "string" then
			return id
		end
	end
	return nil
end

refreshButtons = function()
	local driving = isDriving()
	local id = equippedToolId()
	local keyboard = UserInputService.KeyboardEnabled
	if actionButton then
		local show = id ~= nil
		if show and id then
			styleButton(actionButton, id, nil)
		end
		actionButton.button.Position = if driving then ACTION_BUTTON_DRIVING_POSITION else ACTION_BUTTON_POSITION
		actionButton.button.Visible = show
	end
	if spikeButton then
		local show = driving and findOwnedTool("spikes") ~= nil
		if show then
			styleButton(spikeButton, "spikes", if keyboard then "G" else nil)
		end
		spikeButton.button.Visible = show
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- knockback / stun
-------------------------------------------------------------------------------------------------------------------------

local function endKnockdown()
	if not knockedDown then
		return
	end
	knockedDown = false
	local _, humanoid = getCharacterParts()
	if humanoid and humanoid.Parent then
		humanoid.PlatformStand = false
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
end

local function applyKnockback(velocity: Vector3, stunSeconds: number)
	local _, humanoid, root = getCharacterParts()
	if not humanoid or not root or humanoid.Health <= 0 then
		return
	end
	knockToken += 1
	local token = knockToken
	-- the server ejects us from a car first; give that a moment to replicate
	local t0 = os.clock()
	while humanoid.SeatPart and os.clock() - t0 < 0.5 do
		task.wait()
	end
	if token ~= knockToken or not root.Parent then
		return
	end
	if humanoid.SeatPart then
		humanoid.Sit = false
		task.wait()
	end
	knockedDown = true
	humanoid.PlatformStand = true
	root.AssemblyLinearVelocity = velocity
	root.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-5, 5), rng:NextNumber(-9, 9), rng:NextNumber(-5, 5))
	shakeCamera(0.35, 0.55)
	task.delay(math.max(stunSeconds, 0.3), function()
		if token == knockToken then
			endKnockdown()
		end
	end)
end

local function applyStunState()
	local stunned = isStunned()
	local _, humanoid = getCharacterParts()
	if stunned then
		if humanoid and not frozen then
			frozen = {
				humanoid = humanoid,
				walk = humanoid.WalkSpeed,
				jumpPower = humanoid.JumpPower,
				jumpHeight = humanoid.JumpHeight,
			}
			humanoid.WalkSpeed = 0
			humanoid.JumpPower = 0
			humanoid.JumpHeight = 0
		end
		if ProximityPromptService.Enabled then
			ProximityPromptService.Enabled = false
			promptsDisabledByUs = true
		end
	else
		local f = frozen
		if f then
			frozen = nil
			if f.humanoid.Parent then
				f.humanoid.WalkSpeed = if f.walk > 0 then f.walk else 18
				f.humanoid.JumpPower = f.jumpPower
				f.humanoid.JumpHeight = f.jumpHeight
			end
		end
		if promptsDisabledByUs then
			promptsDisabledByUs = false
			ProximityPromptService.Enabled = true
		end
		endKnockdown()
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- stun stars over every stunned player
-------------------------------------------------------------------------------------------------------------------------

type StarRig = { gui: BillboardGui, stars: { TextLabel }, phase: number }
local starRigs: { [Player]: StarRig } = {}

local function removeStars(p: Player)
	local rig = starRigs[p]
	if rig then
		starRigs[p] = nil
		rig.gui:Destroy()
	end
end

local function addStars(p: Player)
	local character = p.Character
	local head = character and character:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	removeStars(p)
	local gui = Kit.new("BillboardGui", {
		Name = "StunStars",
		Adornee = head,
		Size = UDim2.fromScale(3.6, 1.8),
		StudsOffsetWorldSpace = Vector3.new(0, 1.9, 0),
		LightInfluence = 0,
		MaxDistance = 160,
		ResetOnSpawn = false,
	}) :: BillboardGui
	local stars: { TextLabel } = {}
	for i = 1, 3 do
		local star = Kit.new("TextLabel", {
			Name = "Star" .. i,
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromScale(0.3, 0.6),
			Text = "★",
			TextScaled = true,
			FontFace = Theme.Fonts.Display,
			TextColor3 = if i == 2 then Color3.fromRGB(255, 255, 255) else Theme.Colors.Gold,
			Parent = gui,
		}) :: TextLabel
		Kit.stroke(Theme.Colors.Stroke, 2, Enum.ApplyStrokeMode.Contextual).Parent = star
		table.insert(stars, star)
	end
	gui.Parent = head
	starRigs[p] = { gui = gui, stars = stars, phase = rng:NextNumber(0, math.pi * 2) }
end

local function updateStarsFor(p: Player)
	if p:GetAttribute("Stunned") == true then
		local rig = starRigs[p]
		if not rig or not rig.gui.Parent then
			addStars(p)
		end
	else
		removeStars(p)
	end
end

local function stepStars()
	if next(starRigs) == nil then
		return
	end
	local t = os.clock() * 5
	for p, rig in starRigs do
		if not rig.gui.Parent or not p.Parent then
			starRigs[p] = nil
			if rig.gui.Parent then
				rig.gui:Destroy()
			end
			continue
		end
		for i, star in rig.stars do
			local a = t + rig.phase + (i - 1) * (math.pi * 2 / 3)
			local depth = (math.sin(a) + 1) / 2 -- 0 back .. 1 front
			star.Position = UDim2.fromScale(0.5 + math.cos(a) * 0.36, 0.5 + math.sin(a) * 0.16)
			local s = 0.2 + depth * 0.14
			star.Size = UDim2.fromScale(s, s * 2)
			star.ZIndex = if depth > 0.5 then 2 else 1
			star.Rotation = math.deg(a) * 0.6
			star.TextTransparency = 0.35 * (1 - depth)
		end
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- lifecycle
-------------------------------------------------------------------------------------------------------------------------

function CombatClient.init() end

-- Activate a combat tool by id from code (e.g. another controller's button). Same checks as a real activation.
function CombatClient.activate(toolId: string)
	local tool = findOwnedTool(toolId)
	if toolId ~= "spikes" and not tool then
		return
	end
	if tool and tool.Parent == player.Character and toolId ~= "spikes" then
		tool:Activate()
		return
	end
	activate(toolId, tool)
end

-- Seconds until toolId is ready again locally (0 when ready).
function CombatClient.cooldownRemaining(toolId: string): number
	return math.max(0, (cooldownEnds[toolId] or 0) - os.clock())
end

function CombatClient.start()
	-- UI
	local gui = Kit.screen("CombatHUD", Theme.Layers.HUD)
	local ab = makeRoundButton(gui, "ActionButton", Theme.Colors.Primary, ACTION_BUTTON_SIZE)
	ab.button.AnchorPoint = Vector2.new(1, 1)
	ab.button.Position = ACTION_BUTTON_POSITION -- clears the touch jump button on phones and tablets
	actionButton = ab
	ab.button.Activated:Connect(function()
		local tool = equippedTool
		if tool and tool.Parent == player.Character then
			tool:Activate()
		end
	end)
	local sb = makeRoundButton(gui, "SpikeButton", Theme.Colors.Warning, SPIKE_BUTTON_SIZE)
	-- bottom-anchored like the rest of DrivingUI's touch cluster: left of HORN, above DRIFT, clear of EXIT at every
	-- canvas height (a Scale-anchored button slid onto EXIT on phones, where the UIScale floor shrinks the canvas)
	sb.button.AnchorPoint = SPIKE_BUTTON_ANCHOR
	sb.button.Position = SPIKE_BUTTON_POSITION
	spikeButton = sb
	sb.button.Activated:Connect(function()
		activate("spikes", findOwnedTool("spikes"))
	end)

	-- input
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if input.UserInputType == Enum.UserInputType.Touch then
			if not processed then
				-- InputObject positions exclude the top-bar inset; convert to viewport coordinates
				local inset = GuiService:GetGuiInset()
				lastTouchPos = Vector2.new(input.Position.X, input.Position.Y) + inset
				lastTouchAt = os.clock()
			end
			return
		end
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.G or input.KeyCode == Enum.KeyCode.ButtonL1 then
			if isDriving() and findOwnedTool("spikes") then
				activate("spikes", findOwnedTool("spikes"))
			end
		end
	end)

	-- knockback
	Net.listen("Knockback", function(velocity: any, stunSeconds: any)
		if typeof(velocity) ~= "Vector3" or not Net.isFiniteVector(velocity) then
			return
		end
		local stun = if typeof(stunSeconds) == "number" and stunSeconds == stunSeconds
			then math.clamp(stunSeconds, 0, 6)
			else 1
		local v = velocity
		if v.Magnitude > 250 then
			v = v.Unit * 250
		end
		task.spawn(applyKnockback, v, stun)
	end)

	-- our own stun state + per-character tool hooks
	player:GetAttributeChangedSignal("Stunned"):Connect(applyStunState)
	player:GetAttributeChangedSignal("Driving"):Connect(refreshButtons)

	local charTrove = Trove.new()
	local function onCharacter(character: Model)
		charTrove:Clean()
		equippedTool = nil
		frozen = nil
		knockedDown = false
		if shakeConn then
			shakeConn:Disconnect()
			shakeConn = nil
		end
		watchContainer(character, charTrove)
		local backpack = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 10)
		if backpack and player.Character == character then
			watchContainer(backpack, charTrove)
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") and player.Character == character then
			charTrove:Connect(humanoid:GetPropertyChangedSignal("SeatPart"), refreshButtons)
		end
		applyStunState()
		refreshButtons()
	end
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end

	-- stars for every stunned player
	local playerTroves: { [Player]: Trove.Trove } = {}
	local function watchPlayer(p: Player)
		if playerTroves[p] then
			return
		end
		local t = Trove.new()
		playerTroves[p] = t
		t:Connect(p:GetAttributeChangedSignal("Stunned"), function()
			updateStarsFor(p)
		end)
		t:Connect(p.CharacterAdded, function()
			removeStars(p)
			task.defer(updateStarsFor, p)
		end)
		updateStarsFor(p)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(function(p: Player)
		local t = playerTroves[p]
		if t then
			t:Destroy()
			playerTroves[p] = nil
		end
		removeStars(p)
	end)
	for _, p in Players:GetPlayers() do
		watchPlayer(p)
	end

	-- per-frame: cooldown rings + star orbits (both early-out when idle)
	local refreshAcc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		local now = os.clock()
		updateCooldownVisual(actionButton, equippedToolId(), now)
		updateCooldownVisual(spikeButton, "spikes", now)
		stepStars()
		refreshAcc += dt
		if refreshAcc >= 0.5 then
			refreshAcc = 0
			refreshButtons()
		end
	end)
end

return CombatClient
