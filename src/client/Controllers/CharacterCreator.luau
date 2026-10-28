--!strict
-- CharacterCreator (C4a characters; gta_ui_language §2.14 / §5.13 list menus): GTA Online's character creator.
--
-- When: on first join (AppearanceService says no look was saved: HC_LookLoaded and not HC_LookSaved) and from
-- Pause > Settings > Wardrobe (CharacterCreator.open("wardrobe"); the phone's Settings app opens that tab).
--
-- Flow: AppearanceCreator(true) -> the server checks we may (on foot, alive, not wanted / in combat) and hands us a
-- studio slot far off the island (HC_Creator, a Vector3). We fade to black, build a local lineup room there (a
-- concrete room with a height chart, key / rim / fill lights: CreatorModel.studio), stand our body on its floor (our
-- client owns the character's physics; the server takes us back to where we stood when we leave), freeze the
-- controls, hide the HUD and take a Scriptable orbit camera (CreatorModel.framing: full body, or a head close-up for
-- the face / hair rows). The list menu (UI/ListMenu) edits the look: every change is sent as AppearancePreview (look
-- indices only; the server validates them against PlayerLooks, rate-limits, and dresses the body), Randomize rolls
-- a realistic look, Save sends AppearanceSave (the server stores and wears it, then frees the slot), Skip (first
-- join) saves the look already worn, Back cancels (the wardrobe: the saved look comes back) or, on first join, skips.
-- Drag (mouse / finger) or the right stick orbits (+-CreatorModel.MAX_YAW, the lens never leaves the room); Z (or the
-- ZOOM button) toggles the close-up.
-- While it is open every gameplay hotkey is sunk (weapon slots, the weapon wheel, reload, surrender, the pause menu,
-- the phone, the map: HC_CreatorBlock through ContextActionService, so their UserInputService handlers see the key as
-- processed) and anything drawn anyway is holstered again.
-- Leaving: the server takes the body back. If its answer does not come (a dropped remote, a lost packet) the request
-- is sent again after SAVE_TIMEOUT; after a second SAVE_TIMEOUT we leave anyway and walk the body back to where it
-- stood ourselves (our client owns its physics) before the local floor goes, so nobody falls out of the sky.
-- A studio slot the server hands out after we stopped waiting is handed straight back (AppearanceCreator false).
--
-- Fast path: a new player is in the city in a few seconds with Skip; the whole thing never waits on the store.
-- A cinematic intro that is playing (CinematicController.isPlaying, if present) is let finish first. A first-join
-- creator that could not open (in a car, the server said no) is offered again every AUTO_RETRY s until it opens.
-- API: open(mode?) -> boolean, close(), isOpen(), isPending() (the first-join creator is due / open), Closed: Signal,
-- ownAvatar(), setOwnAvatar(on), OwnChanged: Signal (the own-avatar setting changed: Settings redraws).

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))
local Appearance = Shared:WaitForChild("Appearance")
local LookCodec = require(Appearance:WaitForChild("LookCodec"))
local CreatorModel = require(Appearance:WaitForChild("CreatorModel"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))
local ListMenu = require(UI:WaitForChild("ListMenu"))
local UISound = require(UI:WaitForChild("UISound"))

local CharacterCreator = {}

local player = Players.LocalPlayer
local C = Theme.Colors

CharacterCreator.Closed = Signal.new() -- (saved: boolean)
CharacterCreator.OwnChanged = Signal.new() -- (on: boolean) the own-avatar setting (as shown) changed
CharacterCreator.REQUEST_TIMEOUT = 4 -- seconds to wait for the studio slot
CharacterCreator.SAVE_TIMEOUT = 6 -- seconds to wait for the server to take us back (then once more, then we leave)
CharacterCreator.AUTO_RETRY = 4 -- seconds between first-join creator attempts that could not open
CharacterCreator.HOLSTER_CHECK = 0.5 -- seconds between checks that nothing was drawn in the studio
CharacterCreator.OWN_DEBOUNCE = 0.35 -- seconds a run of own-avatar toggles settles before one is sent
CharacterCreator.BLOCK_ACTION = "HC_CreatorBlock"
-- Gameplay hotkeys sunk while the creator is open (the list menu keeps the arrows, Enter, Backspace, the D-pad, A, B)
CharacterCreator.BLOCKED_KEYS = {
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three,
	Enum.KeyCode.Four,
	Enum.KeyCode.Five,
	Enum.KeyCode.Six,
	Enum.KeyCode.Seven,
	Enum.KeyCode.Eight,
	Enum.KeyCode.Nine,
	Enum.KeyCode.Zero,
	Enum.KeyCode.Tab, -- weapon wheel
	Enum.KeyCode.Q,
	Enum.KeyCode.E,
	Enum.KeyCode.R, -- reload
	Enum.KeyCode.F,
	Enum.KeyCode.G,
	Enum.KeyCode.H, -- surrender
	Enum.KeyCode.P, -- pause menu
	Enum.KeyCode.B, -- phone
	Enum.KeyCode.M, -- map
	Enum.KeyCode.ButtonL1,
	Enum.KeyCode.ButtonR1,
	Enum.KeyCode.ButtonL2,
	Enum.KeyCode.ButtonR2,
	Enum.KeyCode.ButtonX,
	Enum.KeyCode.ButtonY,
	Enum.KeyCode.ButtonSelect,
}
CharacterCreator.PREVIEW_DEBOUNCE = 0.18
CharacterCreator.CINEMATIC_WAIT = 45
CharacterCreator.ORBIT_DEG_PER_PX = 0.35
CharacterCreator.ORBIT_STICK_DEG = 140
CharacterCreator.CAMERA_SMOOTH = 10 -- 1/s exponential approach of the camera

type Phase = "closed" | "requesting" | "open" | "saving"

type Session = {
	mode: CreatorModel.Mode,
	origin: Vector3,
	look: LookCodec.Look,
	sent: string, -- LookCodec.key of the last preview sent
	previewAt: number,
	previewDue: boolean,
	yaw: number,
	zoomFace: boolean?, -- nil = follow the selected row
	focus: CreatorModel.Focus,
	camCF: CFrame?,
	studio: Model?,
	menu: any,
	footer: ScreenGui?,
	dragging: boolean,
	stick: number,
	conns: { RBXScriptConnection },
	savedFov: number,
	hudHidden: boolean,
	controlsOff: boolean,
	rng: Random,
	saved: boolean, -- the pending close is a save (false: a wardrobe cancel)
	returnCF: CFrame?, -- where the body stood before the studio (the way home if the server never answers)
	blocked: boolean, -- the hotkey sink is bound
	holsterAt: number,
}

local phase: Phase = "closed"
local session: Session? = nil
local pendingMode: CreatorModel.Mode = "wardrobe"
local requestToken = 0 -- each open() request; a timeout only cancels its own request
local fadeGui: ScreenGui? = nil
local fadeFrame: Frame? = nil
local autoOpened = false

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

local function help(text: string)
	call("HUDController", "help", text)
end

-- FADE -----------------------------------------------------------------------------------------------------------------

local function fade(alpha: number, seconds: number)
	if not fadeGui then
		local gui = Kit.screen("HC_CreatorFade", Theme.Layers.Fade, { insets = "none" })
		fadeFrame = Kit.new("Frame", {
			Name = "Black",
			BackgroundColor3 = C.Black,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			Parent = gui,
		})
		fadeGui = gui
	end
	local f = fadeFrame :: Frame
	local tween =
		TweenService:Create(f, TweenInfo.new(seconds, Enum.EasingStyle.Sine), { BackgroundTransparency = 1 - alpha })
	tween:Play()
	if seconds > 0 then
		task.wait(seconds)
	end
end

-- CONTROLS / HUD -------------------------------------------------------------------------------------------------------

local function controls(): any
	local ps = player:FindFirstChild("PlayerScripts")
	local pm = ps and ps:FindFirstChild("PlayerModule")
	if not pm then
		return nil
	end
	local ok, mod = pcall(require, pm :: any)
	if ok and typeof(mod) == "table" and typeof(mod.GetControls) == "function" then
		local ok2, c = pcall(mod.GetControls, mod)
		if ok2 then
			return c
		end
	end
	return nil
end

local function setControls(on: boolean)
	local c = controls()
	if c then
		pcall(function()
			if on then
				c:Enable()
			else
				c:Disable()
			end
		end)
	end
end

-- STUDIO ---------------------------------------------------------------------------------------------------------------

local function buildChart(wall: BasePart)
	local sg = Instance.new("SurfaceGui")
	sg.Name = "HeightChart"
	sg.Face = (Enum.NormalId :: any)[CreatorModel.CHART_FACE] -- the face toward the room (+Z), not the outside
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 40
	sg.LightInfluence = 1
	sg.Parent = wall
	local wallH = wall.Size.Y
	local width = CreatorModel.CHART_WIDTH / wall.Size.X
	for _, m in CreatorModel.chartMarks() do
		local yScale = 1 - m.y / wallH
		Kit.new("Frame", {
			Name = "Line",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, yScale),
			Size = UDim2.new(width, 0, 0, if m.major then 5 else 2),
			BackgroundColor3 = Color3.fromRGB(220, 220, 214),
			BackgroundTransparency = if m.major then 0.05 else 0.35,
			BorderSizePixel = 0,
			Parent = sg,
		})
		if m.label then
			for _, side in { -1, 1 } do
				Kit.new("TextLabel", {
					Name = "Label",
					AnchorPoint = Vector2.new(0.5, 1),
					Position = UDim2.fromScale(0.5 + side * (width / 2 + 0.03), yScale),
					Size = UDim2.fromOffset(120, 64),
					BackgroundTransparency = 1,
					FontFace = Theme.Fonts.Condensed,
					TextSize = 56,
					TextColor3 = Color3.fromRGB(225, 225, 218),
					Text = m.label,
					Parent = sg,
				})
			end
		end
	end
end

local function buildStudio(origin: Vector3): Model
	local model = Instance.new("Model")
	model.Name = "HC_CreatorStudio"
	local parts, lights = CreatorModel.studio()
	for _, spec in parts do
		local p = Instance.new("Part")
		p.Name = spec.name
		p.Anchored = true
		p.CanCollide = spec.collide
		p.CanQuery = spec.collide
		p.CanTouch = false
		p.Size = spec.size
		p.CFrame = CFrame.new(origin + spec.offset)
		p.Color = spec.color
		p.Transparency = spec.transparency
		pcall(function()
			p.Material = (Enum.Material :: any)[spec.material]
		end)
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = model
		if spec.name == "BackWall" then
			buildChart(p)
		end
	end
	for _, l in lights do
		local holder = Instance.new("Part")
		holder.Name = "Light_" .. l.name
		holder.Anchored = true
		holder.CanCollide = false
		holder.CanQuery = false
		holder.CanTouch = false
		holder.CastShadow = false
		holder.Transparency = 1
		holder.Size = Vector3.new(0.2, 0.2, 0.2)
		local at = origin + l.offset
		local aim = l.aim
		holder.CFrame = if aim then CFrame.lookAt(at, origin + aim) else CFrame.new(at)
		holder.Parent = model
		if l.kind == "Spot" then
			local s = Instance.new("SpotLight")
			s.Face = Enum.NormalId.Front
			s.Brightness = l.brightness
			s.Range = l.range
			s.Angle = l.angle or 60
			s.Color = l.color
			s.Shadows = true
			s.Parent = holder
		else
			local pl = Instance.new("PointLight")
			pl.Brightness = l.brightness
			pl.Range = l.range
			pl.Color = l.color
			pl.Shadows = false
			pl.Parent = holder
		end
	end
	model.Parent = Workspace
	return model
end

local function placeBody(origin: Vector3)
	local char, hum, root = characterParts()
	if not char or not hum or not root then
		return
	end
	local hip = hum.HipHeight + root.Size.Y / 2
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	pcall(char.PivotTo, char, CreatorModel.standCFrame(origin, hip))
end

-- CAMERA ---------------------------------------------------------------------------------------------------------------

local function headY(s: Session): number
	local char = player.Character
	local head = char and char:FindFirstChild("Head")
	if head and head:IsA("BasePart") and (head.Position - s.origin).Magnitude < 20 then
		return head.Position.Y
	end
	return s.origin.Y + 5.2
end

local function stepCamera(s: Session, dt: number)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	if cam.CameraType ~= Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Scriptable
	end
	if math.abs(s.stick) > 0.15 then
		s.yaw -= math.rad(CharacterCreator.ORBIT_STICK_DEG) * s.stick * dt
	end
	s.yaw = math.clamp(s.yaw, -CreatorModel.MAX_YAW, CreatorModel.MAX_YAW)
	local item = s.menu and s.menu:getSelected()
	local focus: CreatorModel.Focus = if s.zoomFace == nil
		then CreatorModel.focusFor(item and item.data and item.data.field)
		elseif s.zoomFace then "face"
		else "body"
	s.focus = focus
	local target, fov = CreatorModel.framing(s.origin, headY(s), focus, Kit.isTouch(), s.yaw)
	local k = 1 - math.exp(-CharacterCreator.CAMERA_SMOOTH * dt)
	local current = s.camCF or target
	local cf = current:Lerp(target, k)
	s.camCF = cf
	cam.CFrame = cf
	cam.FieldOfView = cam.FieldOfView + (fov - cam.FieldOfView) * k
end

-- MENU -----------------------------------------------------------------------------------------------------------------

local function toItems(s: Session): { any }
	local items = {}
	for _, r in CreatorModel.rows(s.look, s.mode) do
		table.insert(items, {
			id = r.id,
			label = r.label,
			separator = r.separator,
			options = r.options,
			optionIndex = r.optionIndex,
			value = r.value,
			desc = r.desc,
			data = { field = r.field },
		})
	end
	return items
end

local function refreshMenu(s: Session)
	if s.menu then
		s.menu:setItems(toItems(s), true)
	end
end

local function queuePreview(s: Session)
	s.previewDue = true
	s.previewAt = os.clock() + CharacterCreator.PREVIEW_DEBOUNCE
end

local function flushPreview(s: Session)
	if not s.previewDue or os.clock() < s.previewAt then
		return
	end
	s.previewDue = false
	local key = LookCodec.key(s.look)
	if key ~= s.sent then
		s.sent = key
		Net.fire("AppearancePreview", LookCodec.copy(s.look))
	end
end

local finish: (saved: boolean) -> ()

-- Wait for the server to free the slot (HC_Creator -> nil: onCreatorAttr finishes). No answer after SAVE_TIMEOUT:
-- `send` again (a dropped or lost remote); still none after another SAVE_TIMEOUT: leave on our own (finish() walks
-- the body back to where it stood before the floor goes).
local function awaitServer(s: Session, send: () -> ())
	send()
	task.delay(CharacterCreator.SAVE_TIMEOUT, function()
		if phase ~= "saving" or session ~= s then
			return
		end
		send()
		task.delay(CharacterCreator.SAVE_TIMEOUT, function()
			if phase == "saving" and session == s then
				finish(s.saved)
			end
		end)
	end)
end

local function save(s: Session)
	if phase ~= "open" then
		return
	end
	phase = "saving"
	s.saved = true
	s.previewDue = false
	local look = LookCodec.copy(s.look)
	-- (a repeated save is harmless: the server ignores one once the slot is freed)
	awaitServer(s, function()
		Net.fire("AppearanceSave", look)
	end)
	pcall(UISound.play, "Click")
end

local function cancel(s: Session)
	if phase ~= "open" then
		return
	end
	if s.mode == "first" then
		save(s) -- backing out of the first-join creator keeps the look you are wearing
		return
	end
	phase = "saving"
	awaitServer(s, function()
		Net.fire("AppearanceCreator", false)
	end)
end

-- Gameplay hotkeys do nothing in the studio (see BLOCKED_KEYS).
local function sinkAction(): Enum.ContextActionResult
	return Enum.ContextActionResult.Sink
end

local function setBlocked(s: Session, on: boolean)
	if on == s.blocked then
		return
	end
	s.blocked = on
	if on then
		ContextActionService:BindActionAtPriority(
			CharacterCreator.BLOCK_ACTION,
			sinkAction,
			false,
			Enum.ContextActionPriority.High.Value + 50,
			table.unpack(CharacterCreator.BLOCKED_KEYS)
		)
	else
		ContextActionService:UnbindAction(CharacterCreator.BLOCK_ACTION)
	end
end

local function buildMenu(s: Session)
	local menu = ListMenu.new({
		title = "Character",
		subtitle = if s.mode == "first" then "Create your character" else "Wardrobe",
		visibleRows = 14,
	})
	menu:setItems(toItems(s))
	menu.Changed:Connect(function(item: any, optionIndex: number)
		local field = item and item.data and item.data.field
		if typeof(field) ~= "string" or phase ~= "open" then
			return
		end
		s.look = LookCodec.set(s.look, field, optionIndex)
		if field == "outfit" then
			refreshMenu(s) -- the variant row lists this style's outfits
		end
		queuePreview(s)
	end)
	menu.Selected:Connect(function(item: any)
		if phase ~= "open" or not item then
			return
		end
		if item.id == "randomize" then
			s.look = LookCodec.random(function(): number
				return s.rng:NextNumber()
			end)
			refreshMenu(s)
			queuePreview(s)
		elseif item.id == "save" or item.id == "skip" then
			save(s)
		end
	end)
	menu.Closed:Connect(function()
		if phase == "open" and session == s then
			cancel(s)
		end
	end)
	menu:open()
	s.menu = menu
end

local function buildFooter(s: Session)
	local gui = Kit.screen("HC_CreatorFooter", Theme.Layers.Menus + 1, { touchMin = Theme.TouchMinScale })
	local row = Kit.new("Frame", {
		Name = "Footer",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -Theme.SAFE, 1, -Theme.SAFE),
		Size = UDim2.fromOffset(600, 30),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	Kit.list(Enum.FillDirection.Horizontal, 14, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center).Parent =
		row
	local touch = Kit.isTouch()
	local zoom = Kit.instructionButton(if touch then nil else "Z", "Zoom", { LayoutOrder = 1, Parent = row })
	zoom.Activated:Connect(function()
		s.zoomFace = not (s.focus == "face")
	end)
	Kit.instructionButton(nil, if touch then "Drag to turn" else "Drag to rotate", { LayoutOrder = 2, Parent = row })
	if touch then
		-- the touch bottom sheet owns the bottom: the footer sits at the top right
		row.AnchorPoint = Vector2.new(1, 0)
		row.Position = UDim2.new(1, -Theme.SAFE, 0, Theme.SAFE)
	end
	s.footer = gui
end

-- INPUT ----------------------------------------------------------------------------------------------------------------

local function bindInput(s: Session)
	table.insert(
		s.conns,
		UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if processed then
				return
			end
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.MouseButton2
				or input.UserInputType == Enum.UserInputType.Touch
			then
				s.dragging = true
			elseif input.KeyCode == Enum.KeyCode.Z or input.KeyCode == Enum.KeyCode.ButtonR3 then
				s.zoomFace = not (s.focus == "face")
			end
		end)
	)
	table.insert(
		s.conns,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.MouseButton2
				or input.UserInputType == Enum.UserInputType.Touch
			then
				s.dragging = false
			elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
				s.stick = 0
			end
		end)
	)
	table.insert(
		s.conns,
		UserInputService.InputChanged:Connect(function(input: InputObject, processed: boolean)
			if input.KeyCode == Enum.KeyCode.Thumbstick2 then
				s.stick = input.Position.X
				return
			end
			if not s.dragging or processed then
				return
			end
			if
				input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch
			then
				s.yaw -= math.rad(CharacterCreator.ORBIT_DEG_PER_PX) * input.Delta.X
			end
		end)
	)
end

-- OPEN / CLOSE ---------------------------------------------------------------------------------------------------------

local function enter(origin: Vector3)
	if phase ~= "requesting" then
		return
	end
	local mode = pendingMode
	local current = LookCodec.parseKey(player:GetAttribute("HC_Look")) or LookCodec.default()
	local cam = Workspace.CurrentCamera
	local _, _, root0 = characterParts()
	local s: Session = {
		mode = mode,
		origin = origin,
		look = current,
		sent = LookCodec.key(current),
		previewAt = 0,
		previewDue = false,
		yaw = 0,
		zoomFace = nil,
		focus = "body",
		camCF = nil,
		studio = nil,
		menu = nil,
		footer = nil,
		dragging = false,
		stick = 0,
		conns = {},
		savedFov = if cam then cam.FieldOfView else 58,
		hudHidden = false,
		controlsOff = false,
		rng = Random.new(),
		saved = false,
		-- where we stand now, before anything moves us (the server keeps its own copy and normally takes us back)
		returnCF = if root0 and (root0.Position - origin).Magnitude > 60 then root0.CFrame else nil,
		blocked = false,
		holsterAt = 0,
	}
	session = s
	phase = "open"
	setBlocked(s, true)
	fade(1, 0.25)
	if session ~= s then
		return
	end
	call("WeaponClient", "holster")
	call("ShoulderCamera", "setSuspended", "creator", true)
	call("MenuController", "closeAll")
	call("PhoneController", "close")
	call("HUDController", "setLocalHidden", true)
	s.hudHidden = true
	setControls(false)
	s.controlsOff = true
	s.studio = buildStudio(origin)
	placeBody(origin)
	buildMenu(s)
	buildFooter(s)
	bindInput(s)
	table.insert(
		s.conns,
		RunService.RenderStepped:Connect(function(dt: number)
			if session ~= s then
				return
			end
			flushPreview(s)
			stepCamera(s, dt)
		end)
	)
	-- keep the body on the studio floor if physics or a late apply moves it off; nothing stays drawn in the studio
	table.insert(
		s.conns,
		RunService.Heartbeat:Connect(function()
			if session ~= s then
				return
			end
			local _, _, root = characterParts()
			if root and (root.Position - s.origin).Magnitude > 12 and phase == "open" then
				placeBody(s.origin)
			end
			local now = os.clock()
			if now - s.holsterAt >= CharacterCreator.HOLSTER_CHECK then
				s.holsterAt = now
				if call("WeaponClient", "equipped") ~= nil then
					call("WeaponClient", "holster")
				end
			end
		end)
	)
	task.wait(0.15)
	fade(0, 0.35)
end

finish = function(saved: boolean)
	local s = session
	session = nil
	phase = "closed"
	if not s then
		return
	end
	for _, c in s.conns do
		c:Disconnect()
	end
	table.clear(s.conns)
	setBlocked(s, false)
	task.spawn(function()
		fade(1, 0.2)
		-- still in the studio (the server never took us back, or not yet): walk the body home ourselves before its
		-- floor goes, and hand the slot back should the server still hold it
		local char, _, root = characterParts()
		local home = s.returnCF
		if char and root and home and (root.Position - s.origin).Magnitude < 60 then
			root.AssemblyLinearVelocity = Vector3.zero
			pcall(char.PivotTo, char, home)
		end
		if typeof(player:GetAttribute("HC_Creator")) == "Vector3" then
			Net.fire("AppearanceCreator", false)
		end
		if s.menu then
			pcall(function()
				s.menu:destroy()
			end)
		end
		if s.footer then
			s.footer:Destroy()
		end
		if s.studio then
			s.studio:Destroy()
		end
		local cam = Workspace.CurrentCamera
		local _, hum = characterParts()
		if cam then
			cam.CameraType = Enum.CameraType.Custom
			if hum then
				cam.CameraSubject = hum
			end
			cam.FieldOfView = s.savedFov
		end
		if s.controlsOff then
			setControls(true)
		end
		if s.hudHidden then
			call("HUDController", "setLocalHidden", false)
		end
		call("ShoulderCamera", "setSuspended", "creator", false)
		call("FootCamera", "snap")
		task.wait(0.2)
		fade(0, 0.35)
		if saved and s.mode == "first" then
			help("Change your look any time: Pause > Settings > Wardrobe.")
		end
		CharacterCreator.Closed:Fire(saved)
	end)
end

local function onCreatorAttr()
	local v = player:GetAttribute("HC_Creator")
	if typeof(v) == "Vector3" then
		if phase == "requesting" then
			task.spawn(enter, v)
		elseif phase == "closed" then
			-- a slot for a request we already gave up on: hand it straight back (the server would otherwise keep us
			-- "in the creator": no wardrobe, no own-avatar switch, a hidden name tag)
			Net.fire("AppearanceCreator", false)
		end
	elseif phase == "open" or phase == "saving" then
		-- the server freed the slot: saved, cancelled, or we respawned
		local s = session
		finish(phase == "saving" and s ~= nil and s.saved)
	end
end

-- PUBLIC ---------------------------------------------------------------------------------------------------------------

function CharacterCreator.isOpen(): boolean
	return phase ~= "closed"
end

-- The first-join creator is due (no saved look yet) or open: a cinematic intro can wait for Closed.
function CharacterCreator.isPending(): boolean
	if phase ~= "closed" then
		return true
	end
	return player:GetAttribute("HC_LookLoaded") == true and player:GetAttribute("HC_LookSaved") == false
end

local maybeAutoOpen: () -> ()

-- Why the creator cannot open right now (client-side view of the server's gates), or nil.
local function localBlock(): string?
	local _, hum, root = characterParts()
	if not hum or not root or hum.Health <= 0 then
		return ""
	end
	if player:GetAttribute("HC_LookLoaded") ~= true then
		return "Your look is still loading."
	end
	if hum.SeatPart ~= nil then
		return "Get out of the vehicle to change your look."
	end
	local wanted = player:GetAttribute("Wanted")
	if typeof(wanted) == "number" and wanted > 0 then
		return "Lose the cops before you change your look."
	end
	if player:GetAttribute("InCombat") == true then
		return "You can't change your look in the middle of a fight."
	end
	if root.AssemblyLinearVelocity.Y < -20 or hum.FloorMaterial == Enum.Material.Air then
		return "Get your feet on the ground first."
	end
	return nil
end

-- Ask for the creator ("first" = the first-join flow with Skip, "wardrobe" = Settings). Returns false when it cannot
-- open right now (the reason is shown as help text; never for the automatic first-join attempts).
function CharacterCreator.open(mode: CreatorModel.Mode?): boolean
	if phase ~= "closed" then
		return false
	end
	local m: CreatorModel.Mode = mode or "wardrobe"
	local quiet = m == "first"
	local why = localBlock()
	if why ~= nil then
		if why ~= "" and not quiet then
			help(why)
		end
		return false
	end
	pendingMode = m
	phase = "requesting"
	requestToken += 1
	local token = requestToken
	Net.fire("AppearanceCreator", true)
	task.delay(CharacterCreator.REQUEST_TIMEOUT, function()
		if phase == "requesting" and requestToken == token then
			phase = "closed"
			if m == "first" then
				-- the server said no (or never answered): offer the first-join creator again shortly
				autoOpened = false
				task.delay(CharacterCreator.AUTO_RETRY, function()
					maybeAutoOpen()
				end)
			else
				help("You can't change your look right now.")
			end
		end
	end)
	if typeof(player:GetAttribute("HC_Creator")) == "Vector3" then
		onCreatorAttr()
	end
	return true
end

function CharacterCreator.close()
	local s = session
	if s then
		cancel(s)
	end
end

-- Settings > "Use my Roblox avatar" (MenuController's SETTINGS tab): the value now (an optimistic local value from a
-- change until a few seconds after it was sent, then the server's HC_LookOwn) and the switch. A run of quick toggles
-- settles for OWN_DEBOUNCE s and only the last value is sent; OwnChanged fires whenever the shown value may differ.
local ownOverride: { value: boolean, at: number }? = nil
local ownSendToken = 0
CharacterCreator.OWN_OVERRIDE_TTL = 4

function CharacterCreator.ownAvatar(): boolean
	local o = ownOverride
	if o and os.clock() - o.at < CharacterCreator.OWN_OVERRIDE_TTL then
		return o.value
	end
	return player:GetAttribute("HC_LookOwn") == true
end

function CharacterCreator.setOwnAvatar(on: boolean)
	local value = on == true
	ownOverride = { value = value, at = os.clock() + CharacterCreator.OWN_DEBOUNCE }
	ownSendToken += 1
	local token = ownSendToken
	CharacterCreator.OwnChanged:Fire(value)
	task.delay(CharacterCreator.OWN_DEBOUNCE, function()
		if ownSendToken == token then
			Net.fire("AppearanceSetOwn", value)
		end
	end)
	-- once the optimistic value lapses the server's value shows: redraw then
	task.delay(CharacterCreator.OWN_DEBOUNCE + CharacterCreator.OWN_OVERRIDE_TTL + 0.05, function()
		if ownSendToken == token then
			CharacterCreator.OwnChanged:Fire(CharacterCreator.ownAvatar())
		end
	end)
end

-- First join: open once the look has loaded and none was saved (after any intro cinematic). An attempt that cannot
-- open (in a car, wanted, mid-air, or the server refused: see open) is retried every AUTO_RETRY s.
function maybeAutoOpen()
	if autoOpened or phase ~= "closed" then
		return
	end
	if player:GetAttribute("HC_LookLoaded") ~= true or player:GetAttribute("HC_LookSaved") ~= false then
		return
	end
	autoOpened = true
	task.spawn(function()
		local deadline = os.clock() + CharacterCreator.CINEMATIC_WAIT
		while os.clock() < deadline and call("CinematicController", "isPlaying") == true do
			task.wait(0.5)
		end
		-- the body may still be spawning
		local t0 = os.clock()
		while os.clock() - t0 < 10 do
			local _, hum, root = characterParts()
			if hum and root and hum.Health > 0 then
				break
			end
			task.wait(0.2)
		end
		if player:GetAttribute("HC_LookSaved") == false and phase == "closed" then
			if not CharacterCreator.open("first") then
				autoOpened = false
				task.delay(CharacterCreator.AUTO_RETRY, function()
					maybeAutoOpen()
				end)
			end
		end
	end)
end

function CharacterCreator.init() end

function CharacterCreator.start()
	player:GetAttributeChangedSignal("HC_Creator"):Connect(onCreatorAttr)
	player:GetAttributeChangedSignal("HC_LookLoaded"):Connect(maybeAutoOpen)
	player:GetAttributeChangedSignal("HC_LookSaved"):Connect(maybeAutoOpen)
	player:GetAttributeChangedSignal("HC_LookOwn"):Connect(function()
		CharacterCreator.OwnChanged:Fire(CharacterCreator.ownAvatar())
	end)
	player.CharacterAdded:Connect(function()
		if phase ~= "closed" then
			finish(false)
		end
		task.delay(1, maybeAutoOpen)
	end)
	maybeAutoOpen()
end

return CharacterCreator
