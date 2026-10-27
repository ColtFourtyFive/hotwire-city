--!strict
-- CombatClient (gta_combat §13.2): the gadgets (Kessler stun gun, Stinger spike strip), knockback and stun on the
-- client. Guns and melee live in WeaponClient; the bat is a WeaponService melee weapon now.
--  * Tool.Activated on a gadget Tool (ToolId attribute) -> Net.fire("ToolAction", toolId, aim). The stun gun aims at
--    the crosshair (screen centre while the shoulder camera is engaged, the mouse / last tap otherwise) with a gentle
--    player assist. Local feedback: the "Lunge" tool animation and a small blue-white spark at the muzzle.
--  * Touch: a flat black STUN button (with a cooldown ring) while the stun gun is out, and a SPIKES button while
--    driving (also key G / gamepad L1). Flat Panel circles with white condensed text (gta_ui_language §7); no emoji.
--  * Knockback remote -> AssemblyLinearVelocity on our HumanoidRootPart + PlatformStand, short camera shake.
--  * While our Stunned attribute is true: WalkSpeed / Jump 0 and prompts off; restored afterwards. (The v1 cartoon
--    stars over stunned players are gone.)
-- Public: activate(toolId), cooldownRemaining(toolId).

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Economy = require(Shared:WaitForChild("Config"):WaitForChild("Economy"))
local Trove = require(Shared:WaitForChild("Util"):WaitForChild("Trove"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Style = require(UI:WaitForChild("CombatStyle"))
local VFXLibrary = require(script.Parent:WaitForChild("VFXLibrary"))

local CombatClient = {}

local player = Players.LocalPlayer
local rng = Random.new()

local CAPTIONS: { [string]: string } = {
	taser = "STUN",
	spikes = "SPIKES",
}

local TOUCH_AIM_MEMORY = 0.45 -- seconds a tap position stays the aim point
local ASSIST_RADIUS_MOUSE = 60 -- px
local ASSIST_RADIUS_TOUCH = 170 -- px (touch + gamepad are imprecise)
local SPARK_COLOR = Color3.fromRGB(190, 225, 255)
-- SPIKES touch button (92 px): spans x W-236..W-144, y H-262..H-170 on the design canvas, left of VehicleClient's
-- HORN (x W-124..W-40) and EXIT (H-354..H-270), above DRIFT (top H-128) and NITRO (top H-150).
local SPIKE_BUTTON_SIZE = 92
local SPIKE_BUTTON_ANCHOR = Vector2.new(1, 1)
local SPIKE_BUTTON_POSITION = UDim2.new(1, -144, 1, -170)
-- STUN button: on foot it sits where WeaponClient's FIRE button would (a gadget is not a gun, so FIRE is hidden).
local ACTION_BUTTON_SIZE = 100
local ACTION_BUTTON_POSITION = UDim2.new(1, -28, 1, -170)

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
	caption: TextLabel,
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

local function toast(kind: string, text: string)
	if notificationController == nil then
		notificationController = lazyController("NotificationController")
	end
	if notificationController and typeof(notificationController.toast) == "function" then
		pcall(notificationController.toast, kind, text)
	end
end

local function playSound(key: string, position: Vector3?)
	if soundController == nil then
		soundController = lazyController("SoundController")
	end
	if soundController and typeof(soundController.play) == "function" then
		pcall(soundController.play, key, position)
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

-- Cooldown of a gadget (the Zapper Pass halves the stun gun's). Pure apart from the pass lookup.
function CombatClient.cooldownFor(toolId: string, pass: boolean?): number
	local def = Economy.Tools[toolId]
	if not def then
		return 1
	end
	if toolId == "taser" and pass then
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
-- aim (stun gun)
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
	for _, name in { "ClientFX", "Effects" } do
		local f = Workspace:FindFirstChild(name)
		if f then
			table.insert(exclude, f)
		end
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

local function computeAim(toolId: string): Vector3?
	local camera = Workspace.CurrentCamera
	local character, _, root = getCharacterParts()
	if not camera or not root then
		return nil
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

local function taserFeedback(tool: Tool?)
	if not tool then
		return
	end
	playToolAnim(tool, "Lunge")
	local handle = tool:FindFirstChild("Handle")
	local muzzle = handle and handle:FindFirstChild("Muzzle")
	if muzzle and muzzle:IsA("Attachment") and handle and handle:IsA("BasePart") then
		pcall(VFXLibrary.burst, "Sparks", muzzle.WorldPosition, {
			count = 6,
			scale = 0.35,
			color = SPARK_COLOR,
			direction = handle.CFrame.LookVector,
		})
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

local function activate(toolId: string, tool: Tool?)
	if not Economy.Tools[toolId] or toolId == "bat" then
		return
	end
	if isStunned() then
		return
	end
	local now = os.clock()
	if (cooldownEnds[toolId] or 0) > now + 0.05 then
		return
	end
	if toolId == "spikes" and not isDriving() then
		toast("warning", "Get in a car to drop the spike strip.")
		return
	end
	local aim = if toolId == "spikes" then nil else computeAim(toolId)
	Net.fire("ToolAction", toolId, aim)
	local duration = CombatClient.cooldownFor(toolId, hasTaserPass())
	cooldownEnds[toolId] = now + duration
	cooldownLength[toolId] = duration
	if toolId == "taser" then
		taserFeedback(tool)
	end
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
-- UI: flat black circles with a thin cooldown ring
-------------------------------------------------------------------------------------------------------------------------

local function makeRoundButton(parent: Instance, name: string, size: number): RoundButton
	local button = Kit.new("TextButton", {
		Name = name,
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = Style.Colors.Panel,
		BackgroundTransparency = 0.35,
		Size = UDim2.fromOffset(size, size),
		Visible = false,
		Parent = parent,
	}) :: TextButton
	Kit.new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = button })
	Kit.new("UIStroke", { Color = Style.Colors.Text, Transparency = 0.7, Thickness = 1, Parent = button })

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
			BackgroundColor3 = Style.Colors.Text,
			BackgroundTransparency = 0.82,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(2, 1),
			Position = UDim2.fromScale(if isRight then -1 else 0, 0),
			ZIndex = 2,
			Parent = clip,
		})
		Kit.new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = disc })
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

	local caption = Kit.new("TextLabel", {
		Name = "Caption",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.9, 0.4),
		Text = "",
		RichText = true,
		TextColor3 = Style.Colors.Text,
		FontFace = Style.font("Condensed"),
		TextSize = math.floor(size * 0.22),
		ZIndex = 4,
		Parent = button,
	}) :: TextLabel

	local function setFill(f: number)
		local a = math.clamp(f, 0, 1) * 360
		rightGrad.Rotation = math.clamp(a, 0, 180)
		leftGrad.Rotation = math.clamp(a, 180, 360)
	end
	setFill(1)
	return { button = button, caption = caption, setFill = setFill, ready = true }
end

local function styleButton(rb: RoundButton, toolId: string, keyHint: string?)
	local caption = CAPTIONS[toolId]
	if not caption then
		return
	end
	rb.caption.Text = if keyHint then `{caption} <font size="11">{keyHint}</font>` else caption
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
			rb.caption.TextTransparency = 0.5
		end
	elseif not rb.ready then
		rb.ready = true
		rb.setFill(1)
		rb.caption.TextTransparency = 0
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
		local show = id == "taser" and not driving and UserInputService.TouchEnabled
		if show and id then
			styleButton(actionButton, id, nil)
		end
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
	shakeCamera(0.3, 0.4)
	playSound("BodyFall", root.Position)
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
-- lifecycle
-------------------------------------------------------------------------------------------------------------------------

function CombatClient.init() end

-- Activate a gadget by id from code (e.g. another controller's button). Same checks as a real activation.
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
	-- UI (named HC_Gadgets: CombatHUD is the gun HUD's controller now)
	local gui = Kit.screen("HC_Gadgets", Style.Layers.HUD)
	local ab = makeRoundButton(gui, "StunButton", ACTION_BUTTON_SIZE)
	ab.button.AnchorPoint = Vector2.new(1, 1)
	ab.button.Position = ACTION_BUTTON_POSITION
	actionButton = ab
	ab.button.Activated:Connect(function()
		local tool = equippedTool
		if tool and tool.Parent == player.Character then
			tool:Activate()
		end
	end)
	local sb = makeRoundButton(gui, "SpikeButton", SPIKE_BUTTON_SIZE)
	-- bottom-anchored like the rest of DrivingUI's touch cluster: left of HORN, above DRIFT, clear of EXIT
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

	-- per-frame: cooldown rings (early-out when hidden)
	local refreshAcc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		local now = os.clock()
		updateCooldownVisual(actionButton, equippedToolId(), now)
		updateCooldownVisual(spikeButton, "spikes", now)
		refreshAcc += dt
		if refreshAcc >= 0.5 then
			refreshAcc = 0
			refreshButtons()
		end
	end)
end

return CombatClient
