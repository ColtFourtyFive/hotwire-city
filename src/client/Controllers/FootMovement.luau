--!strict
-- FootMovement (C4a characters; gta_realism_gap §2.14, VIBE row 4): GTA on-foot movement for the local character.
--
--   * Speeds (FootTuning): walk 10 (hold Left Alt, or a light stick tilt), jog 16 (default), sprint 24 (hold Shift;
--     click L3 on a gamepad, tap the SPRINT button on touch: both toggle until you stop or run dry), aiming a gun
--     slows to a walk (9). Sprinting costs stamina: the HUD's third bar reads the local "Stamina" player attribute
--     (HUDController.abilityNow: nitro while driving, stamina on foot), refilling after a short pause.
--   * A short, heavy jump (JumpHeight 4.5, Humanoid.UseJumpPower off via StarterPlayer) with a landing cooldown (no
--     bunny hopping). Gravity stays 196.2 (vehicle tuning).
--   * WalkSpeed / JumpHeight are shared with CombatClient's stun freeze and WeaponWheel's slow walk: this controller
--     writes only while the humanoid still holds a value it wrote (FootTuning.mayWrite) and never while "Stunned".
--   * Falls: the server (FootService) deals the damage and may ragdoll the body (character attribute HC_RagdollUntil);
--     the owning client holds the humanoid in the Physics state meanwhile, then gets up.
--   * No Roblox emotes: the chat "/e" emote command is switched off (the emote wheel CoreGui is already off in
--     HUDController, and AppearanceService clears the description's emotes).
--   * Touch: a SPRINT button on the shared HUD touch layout (FootTuning.sprintRect from WeaponClient.touchLayoutFor):
--     left of the jump button where FIRE goes, and above FIRE while a gun is drawn. Hidden when driving, dead, in the
--     creator or with the HUD hidden.
-- API: isSprinting(), getStamina(), mode() -> "walk" | "jog" | "sprint".

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local FootTuning = require(Shared:WaitForChild("Appearance"):WaitForChild("FootTuning"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))

local FootMovement = {}

local player = Players.LocalPlayer
local C = Theme.Colors

FootMovement.STAMINA_ATTR = "Stamina"
FootMovement.RAGDOLL_ATTR = "HC_RagdollUntil"

type State = {
	mode: FootTuning.MoveMode,
	stamina: number,
	exhausted: boolean,
	sinceSprint: number,
	shiftHeld: boolean,
	altHeld: boolean,
	toggle: boolean, -- gamepad L3 / touch SPRINT toggle
	lastSpeed: number?,
	lastJump: number?,
	landedAt: number,
	shownStamina: number,
	ragdolled: boolean,
}

local st: State = {
	mode = "jog",
	stamina = 1,
	exhausted = false,
	sinceSprint = math.huge,
	shiftHeld = false,
	altHeld = false,
	toggle = false,
	lastSpeed = nil,
	lastJump = nil,
	landedAt = -math.huge,
	shownStamina = -1,
	ragdolled = false,
}

local touchGui: ScreenGui? = nil
local sprintButton: TextButton? = nil

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

local function characterParts(): (Model?, Humanoid?, BasePart?)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return char, hum, if root and root:IsA("BasePart") then root else nil
end

local function serverNow(): number
	local ok, t = pcall(function()
		return Workspace:GetServerTimeNow()
	end)
	return if ok and typeof(t) == "number" then t else os.time()
end

-- PUBLIC ----------------------------------------------------------------------------------------------------------------

function FootMovement.isSprinting(): boolean
	return st.mode == "sprint"
end

function FootMovement.getStamina(): number
	return st.stamina
end

function FootMovement.mode(): FootTuning.MoveMode
	return st.mode
end

-- STEP -----------------------------------------------------------------------------------------------------------------

local function publishStamina()
	local s = math.floor(st.stamina * 100 + 0.5) / 100
	if s ~= st.shownStamina then
		st.shownStamina = s
		player:SetAttribute(FootMovement.STAMINA_ATTR, s)
	end
end

local function writeSpeed(hum: Humanoid, speed: number)
	if not FootTuning.mayWrite(hum.WalkSpeed, st.lastSpeed, FootTuning.ownSpeeds()) then
		return
	end
	if math.abs(hum.WalkSpeed - speed) > 0.01 then
		hum.WalkSpeed = speed
	end
	st.lastSpeed = speed
end

local function writeJump(hum: Humanoid, height: number)
	if hum.UseJumpPower then
		hum.UseJumpPower = false
	end
	if not FootTuning.mayWrite(hum.JumpHeight, st.lastJump, { FootTuning.JUMP_HEIGHT }) then
		return
	end
	if math.abs(hum.JumpHeight - height) > 0.01 then
		hum.JumpHeight = height
	end
	st.lastJump = height
end

-- The fall ragdoll (FootService): hold the Physics state until the server clears the attribute, then get up.
local function stepRagdoll(char: Model, hum: Humanoid)
	local untilT = char:GetAttribute(FootMovement.RAGDOLL_ATTR)
	local on = typeof(untilT) == "number" and untilT > serverNow() - 0.25 and hum.Health > 0
	if on then
		if hum:GetState() ~= Enum.HumanoidStateType.Physics then
			hum:ChangeState(Enum.HumanoidStateType.Physics)
		end
		st.ragdolled = true
	elseif st.ragdolled then
		st.ragdolled = false
		if hum.Health > 0 then
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
	end
end

local function step(dt: number)
	local char, hum, root = characterParts()
	local now = os.clock()
	if not char or not hum or not root or hum.Health <= 0 then
		st.mode = "jog"
		st.toggle = false
		st.stamina, st.exhausted, st.sinceSprint =
			FootTuning.stepStamina(st.stamina, false, st.exhausted, st.sinceSprint, dt)
		publishStamina()
		return
	end
	stepRagdoll(char, hum)
	local seated = hum.SeatPart ~= nil
	local blocked = seated
		or st.ragdolled
		or player:GetAttribute("Stunned") == true
		or call("CharacterCreator", "isOpen") == true
	local moving = hum.MoveDirection.Magnitude > 0.1
	local aiming = call("ShoulderCamera", "isAiming") == true
	if not moving or blocked then
		st.toggle = false
	end
	local sprintIn = st.shiftHeld or st.toggle
	local mode: FootTuning.MoveMode = if blocked
		then "jog"
		else FootTuning.modeFor(sprintIn, st.altHeld, moving, aiming, st.exhausted)
	st.mode = mode
	local sprinting = mode == "sprint" and root.AssemblyLinearVelocity.Magnitude > FootTuning.JOG * 0.6
	st.stamina, st.exhausted, st.sinceSprint =
		FootTuning.stepStamina(st.stamina, sprinting, st.exhausted, st.sinceSprint, dt)
	if st.exhausted then
		st.toggle = false
	end
	publishStamina()
	if seated or player:GetAttribute("Stunned") == true then
		return -- the car / the stun freeze own the humanoid now
	end
	writeSpeed(hum, FootTuning.speedFor(mode, aiming))
	writeJump(hum, FootTuning.jumpHeightFor(now - st.landedAt))
end

-- INPUT ----------------------------------------------------------------------------------------------------------------

local function onInputBegan(input: InputObject, processed: boolean)
	if input.KeyCode == Enum.KeyCode.LeftShift then
		if not processed then
			st.shiftHeld = true
		end
	elseif input.KeyCode == Enum.KeyCode.LeftAlt then
		if not processed then
			st.altHeld = true
		end
	elseif input.KeyCode == Enum.KeyCode.ButtonL3 and not processed then
		st.toggle = not st.toggle
	end
end

local function onInputEnded(input: InputObject)
	if input.KeyCode == Enum.KeyCode.LeftShift then
		st.shiftHeld = false
	elseif input.KeyCode == Enum.KeyCode.LeftAlt then
		st.altHeld = false
	end
end

-- TOUCH SPRINT BUTTON --------------------------------------------------------------------------------------------------

local function placeTouch()
	local gui, btn = touchGui, sprintButton
	if not gui or not btn then
		return
	end
	local _, hum = characterParts()
	local hudHidden = call("HUDController", "isHidden") == true
	local show = hum ~= nil
		and hum.Health > 0
		and hum.SeatPart == nil
		and not hudHidden
		and call("CharacterCreator", "isOpen") ~= true
	btn.Visible = show
	if not show then
		return
	end
	local wc = lazy("WeaponClient")
	local edge, bottom = nil :: number?, nil :: number?
	local fireSize = 110
	local armed = false
	if wc and typeof(wc.touchLayoutFor) == "function" then
		local ok, L, jump = pcall(wc.touchLayoutFor, gui)
		if ok and typeof(L) == "table" and typeof(jump) == "table" then
			local e = jump.x
			for _, name in { "phone", "map" } do
				local b = L.buttons and L.buttons[name]
				if b then
					e = math.min(e, b.x)
				end
			end
			edge = e
			bottom = jump.y + jump.h
		end
		if typeof(wc.FIRE_BUTTON) == "number" then
			fireSize = wc.FIRE_BUTTON
		end
		armed = call("WeaponClient", "isGunDrawn") == true
	end
	if not edge or not bottom then
		local canvas = Kit.canvasSize(gui)
		edge = canvas.X - 190
		bottom = canvas.Y - 20
	end
	local r = FootTuning.sprintRect(edge :: number, bottom :: number, armed, fireSize)
	btn.Position = UDim2.fromOffset(r.x, r.y)
	btn.Size = UDim2.fromOffset(r.w, r.h)
	local on = st.toggle or st.mode == "sprint"
	btn.BackgroundColor3 = if on then C.Accent else C.Black
end

local function buildTouch()
	local gui = Kit.screen("HC_FootTouch", Theme.Layers.HUD + 2, { touchMin = Theme.TouchMinScale })
	local btn = Kit.circleButton("Sprint", FootTuning.SPRINT_BUTTON, nil, { Name = "Sprint", Parent = gui })
	btn.Activated:Connect(function()
		st.toggle = not st.toggle
	end)
	touchGui = gui
	sprintButton = btn
	placeTouch()
end

-- LIFECYCLE ------------------------------------------------------------------------------------------------------------

local function disableChatEmotes()
	pcall(function()
		local cmds = TextChatService:FindFirstChild("TextChatCommands")
		local emote = cmds and cmds:FindFirstChild("RBXEmoteCommand")
		if emote and emote:IsA("TextChatCommand") then
			emote.Enabled = false
		end
	end)
end

local function onCharacter(char: Model)
	st.lastSpeed = nil
	st.lastJump = nil
	st.toggle = false
	st.ragdolled = false
	st.landedAt = -math.huge
	local hum = char:WaitForChild("Humanoid", 10)
	if not hum or not hum:IsA("Humanoid") then
		return
	end
	hum.StateChanged:Connect(function(_old: Enum.HumanoidStateType, new: Enum.HumanoidStateType)
		if new == Enum.HumanoidStateType.Landed then
			st.landedAt = os.clock()
		end
	end)
end

function FootMovement.init() end

function FootMovement.start()
	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
	disableChatEmotes()
	task.delay(5, disableChatEmotes) -- the default commands can be created after the client starts
	publishStamina()
	RunService.Heartbeat:Connect(function(dt: number)
		local ok, err = pcall(step, dt)
		if not ok then
			warn("[FootMovement] " .. tostring(err))
		end
	end)
	if UserInputService.TouchEnabled then
		local ok, err = pcall(buildTouch)
		if not ok then
			warn("[FootMovement] touch: " .. tostring(err))
		end
		local acc = 0
		RunService.Heartbeat:Connect(function(dt: number)
			acc += dt
			if acc >= 0.25 then
				acc = 0
				pcall(placeTouch)
			end
		end)
	end
end

return FootMovement
