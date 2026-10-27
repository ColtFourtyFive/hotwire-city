--!strict
-- PauseMenu: the GTA pause-menu chrome (gta_ui_language §2.13, §5.12). MenuController fills the tabs.
--
--   local pause = PauseMenu.new({ tabs = { { id = "MAP", label = "Map" }, ... } })
--   pause:open(tabId?) / pause:close() / pause:isOpen() / pause:setTab(id) / pause:getTab()
--   pause:content(id): Frame          the content host of a tab (16%-84% W, 22%-82% H on desktop)
--   pause:setTransparent(on)          MAP: no backdrop / content panel (the full map draws beneath the chrome)
--   pause:setInfo(name, clock, cash)  the top-right player block
--   pause:setFooter({ { key, label, fn } })   instructional buttons bottom-right (tappable)
--   pause.TabChanged: Signal(id), pause.Opened: Signal(id), pause.Closed: Signal()
--
-- Look: camera blur + a near-black tint with a faint accent gradient (GTA's character tint), "HOTWIRE CITY" in Oswald
-- at 16% W / 13% H, a row of tabs at 18.7% H (selected = white with black text and an accent top rule), content
-- panels in black translucent, instructional buttons bottom-right. Touch: margins shrink to 3% and the tab row
-- scrolls horizontally.
-- Keys while open: Q / E (LB / RB) switch tabs, Backspace (B) closes. The host binds P / M to open it.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Theme = require(script.Parent.Theme)
local Kit = require(script.Parent.Kit)
local Signal = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Util"):WaitForChild("Signal"))

local PauseMenu = {}
PauseMenu.__index = PauseMenu

local C = Theme.Colors

export type TabDef = { id: string, label: string }

-- Content rect fractions (desktop GTA measurements; touch uses wider margins).
function PauseMenu.frame(
	touch: boolean
): { left: number, right: number, title: number, tabs: number, top: number, bottom: number }
	if touch then
		return { left = 0.03, right = 0.97, title = 0.06, tabs = 0.15, top = 0.25, bottom = 0.86 }
	end
	return { left = 0.16, right = 0.84, title = 0.13, tabs = 0.187, top = 0.235, bottom = 0.82 }
end

-- Index of the tab after a Q / E press (wrapping).
function PauseMenu.nextTab(count: number, index: number, dir: number): number
	if count <= 0 then
		return 0
	end
	return ((index - 1 + (if dir < 0 then -1 else 1)) % count) + 1
end

local ACTION = "HC_PauseMenu"

function PauseMenu.new(opts: { tabs: { TabDef }, title: string? }): any
	local self = setmetatable({}, PauseMenu) :: any
	self.tabs = opts.tabs
	self.title = opts.title or "HOTWIRE CITY"
	self.TabChanged = Signal.new()
	self.Opened = Signal.new()
	self.Closed = Signal.new()
	self.current = opts.tabs[1] and opts.tabs[1].id or ""
	self.opened = false
	self.contents = {} :: { [string]: Frame }
	self.tabButtons = {} :: { [string]: TextButton }
	return self
end

function PauseMenu:_build()
	if self.gui then
		return
	end
	local touch = Kit.isTouch()
	local F = PauseMenu.frame(touch)
	-- backdrop (whole screen)
	local back = Kit.screen("HC_PauseBack", Theme.Layers.Pause - 2, { insets = "none" })
	back.Enabled = false
	local tint = Kit.new("Frame", {
		Name = "Tint",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.Black,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Parent = back,
	})
	local accent = Kit.new("Frame", {
		Name = "AccentTint",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.Accent,
		BackgroundTransparency = 0.88,
		BorderSizePixel = 0,
		Parent = back,
	})
	Kit.new("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = accent,
	})
	self.back = back
	self.tint = tint
	self.accentTint = accent

	local gui = Kit.screen("HC_Pause", Theme.Layers.Pause, { touchMin = Theme.TouchMinScale })
	gui.Enabled = false
	self.gui = gui
	local root = Kit.new("Frame", {
		Name = "Root",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})
	self.root = root
	-- title: the game's lock-up (Kanit "HOTWIRE" + Damion "City" in Ignition Orange) like GTA's logo, else plain
	local titleSize = if touch then 28 else 34
	local title = Kit.new("Frame", {
		Name = "Title",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(F.left, F.tabs - 0.012),
		Size = UDim2.new(0.5, 0, 0, 44),
		BackgroundTransparency = 1,
		Parent = root,
	})
	Kit.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Bottom).Parent =
		title
	local word, tail = string.match(self.title, "^(%S+)%s+(%S+)$")
	if string.upper(self.title) == "HOTWIRE CITY" and word and tail then
		Kit.text(string.upper(word), "display", titleSize, {
			Name = "Word",
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, titleSize + 6),
			LayoutOrder = 1,
			Parent = title,
		})
		Kit.script(tail:sub(1, 1):upper() .. tail:sub(2):lower(), titleSize, {
			Name = "Script",
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, titleSize + 10),
			TextColor3 = C.Accent,
			LayoutOrder = 2,
			Parent = title,
		})
	else
		Kit.text(self.title, "condensed", titleSize, {
			Name = "Text",
			Size = UDim2.fromScale(1, 1),
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = title,
		})
	end
	-- top-right player block (touch: left of the close button)
	local info = Kit.new("Frame", {
		Name = "Info",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(F.right, if touch then -60 else 0, F.tabs - 0.012, 0),
		Size = UDim2.fromOffset(320, 48),
		BackgroundTransparency = 1,
		Parent = root,
	})
	local avatar = Kit.new("ImageLabel", {
		Name = "Avatar",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(46, 46),
		BackgroundColor3 = C.MenuHighlight,
		BorderSizePixel = 0,
		Image = "",
		Parent = info,
	})
	self.avatar = avatar
	self.nameLabel = Kit.text("", "condensedMedium", 16, {
		Name = "Name",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -54, 0, 0),
		Size = UDim2.new(1, -54, 0, 16),
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = info,
	})
	self.clockLabel = Kit.text("", "condensedMedium", 15, {
		Name = "Clock",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -54, 0, 16),
		Size = UDim2.new(1, -54, 0, 15),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = C.TextDim,
		Parent = info,
	})
	self.cashLabel = Kit.text("", "condensedMedium", 15, {
		Name = "Cash",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -54, 0, 31),
		Size = UDim2.new(1, -54, 0, 15),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = C.Green,
		Parent = info,
	})

	-- tabs
	local tabRow = Kit.new("ScrollingFrame", {
		Name = "Tabs",
		Position = UDim2.fromScale(F.left, F.tabs),
		Size = UDim2.new(F.right - F.left, 0, 0, if touch then 40 else 30),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 0,
		ScrollingDirection = Enum.ScrollingDirection.X,
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		CanvasSize = UDim2.new(),
		Parent = root,
	})
	Kit.list(Enum.FillDirection.Horizontal, 3, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Bottom).Parent =
		tabRow
	local n = #self.tabs
	for i, def in self.tabs do
		local tab = Kit.tab(def.label, {
			Name = "Tab_" .. def.id,
			LayoutOrder = i,
			Size = if touch then UDim2.fromOffset(130, 36) else UDim2.new(1 / n, -3, 0, 26),
			Parent = tabRow,
		})
		tab.TextSize = if touch then 18 else 15
		tab.Activated:Connect(function()
			self:setTab(def.id)
		end)
		self.tabButtons[def.id] = tab
	end

	-- content hosts
	local area = Kit.new("Frame", {
		Name = "Content",
		Position = UDim2.fromScale(F.left, F.top),
		Size = UDim2.fromScale(F.right - F.left, F.bottom - F.top),
		BackgroundTransparency = 1,
		Parent = root,
	})
	self.area = area
	for _, def in self.tabs do
		self.contents[def.id] = Kit.new("Frame", {
			Name = def.id,
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Visible = false,
			Parent = area,
		})
	end

	-- footer
	local footer = Kit.new("Frame", {
		Name = "Footer",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(F.right, 0, F.bottom, 10),
		Size = UDim2.new(F.right - F.left, 0, 0, if touch then 40 else 26),
		BackgroundTransparency = 1,
		Parent = root,
	})
	Kit.list(Enum.FillDirection.Horizontal, 18, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center).Parent =
		footer
	self.footer = footer
	if touch then
		local close = Kit.new("TextButton", {
			Name = "Close",
			AutoButtonColor = false,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(F.right, 0.02),
			Size = UDim2.fromOffset(48, 48),
			BackgroundColor3 = C.Black,
			BackgroundTransparency = 0.3,
			Text = "X",
			TextSize = 24,
			FontFace = Theme.Fonts.Condensed,
			TextColor3 = C.Text,
			Parent = root,
		})
		close.Activated:Connect(function()
			self:close()
		end)
	end
	self:setFooter({})
end

function PauseMenu:content(id: string): Frame
	self:_build()
	return self.contents[id]
end

function PauseMenu:setInfo(name: string, clock: string, cash: string)
	self:_build()
	self.nameLabel.Text = Kit.sanitize(name)
	self.clockLabel.Text = clock
	self.cashLabel.Text = cash
end

function PauseMenu:setAvatar(image: string)
	self:_build()
	self.avatar.Image = image
end

export type FooterButton = { key: string?, label: string, fn: (() -> ())? }

function PauseMenu:setFooter(buttons: { FooterButton })
	self:_build()
	for _, c in self.footer:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local touch = Kit.isTouch()
	local all = table.clone(buttons)
	table.insert(all, {
		key = if touch then nil else "Backspace",
		label = "Back",
		fn = function()
			self:close()
		end,
	})
	for i, b in all do
		local btn = Kit.instructionButton(if touch then nil else b.key, b.label, {
			LayoutOrder = i,
			Parent = self.footer,
		})
		if touch then
			btn.BackgroundColor3 = C.Black
			btn.BackgroundTransparency = 0.3
			btn.Size = UDim2.fromOffset(0, 36)
			Kit.padding(0, 10).Parent = btn
		end
		local fn = b.fn
		if fn then
			btn.Activated:Connect(fn)
		end
	end
end

function PauseMenu:setTransparent(on: boolean)
	self:_build()
	self.tint.Visible = not on
	self.accentTint.Visible = not on
end

function PauseMenu:getTab(): string
	return self.current
end

function PauseMenu:setTab(id: string)
	self:_build()
	if not self.contents[id] then
		return
	end
	self.current = id
	for tabId, btn in self.tabButtons do
		Kit.setTabSelected(btn, tabId == id)
	end
	for tabId, frame in self.contents do
		frame.Visible = tabId == id
	end
	self.TabChanged:Fire(id)
end

function PauseMenu:_index(): number
	for i, def in self.tabs do
		if def.id == self.current then
			return i
		end
	end
	return 1
end

function PauseMenu:_bind()
	ContextActionService:BindActionAtPriority(
		ACTION,
		function(_, state: Enum.UserInputState, input: InputObject)
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			local k = input.KeyCode
			if k == Enum.KeyCode.Q or k == Enum.KeyCode.ButtonL1 then
				self:setTab(self.tabs[PauseMenu.nextTab(#self.tabs, self:_index(), -1)].id)
			elseif k == Enum.KeyCode.E or k == Enum.KeyCode.ButtonR1 then
				self:setTab(self.tabs[PauseMenu.nextTab(#self.tabs, self:_index(), 1)].id)
			elseif k == Enum.KeyCode.Backspace or k == Enum.KeyCode.ButtonB then
				self:close()
			else
				return Enum.ContextActionResult.Pass
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value + 30,
		Enum.KeyCode.Q,
		Enum.KeyCode.E,
		Enum.KeyCode.ButtonL1,
		Enum.KeyCode.ButtonR1,
		Enum.KeyCode.Backspace,
		Enum.KeyCode.ButtonB
	)
end

function PauseMenu:open(tabId: string?)
	self:_build()
	if not self.opened then
		self.opened = true
		self.back.Enabled = true
		self.gui.Enabled = true
		local cam = Workspace.CurrentCamera
		if cam and not self.blur then
			local blur = Instance.new("BlurEffect")
			blur.Name = "HC_PauseBlur"
			blur.Size = 24
			blur.Parent = cam
			self.blur = blur
		end
		self:_bind()
		Kit.fadeTree(self.root, 1, 0)
		Kit.fadeTree(self.root, 0, 0.2)
		local player = Players.LocalPlayer
		if player and self.avatar.Image == "" then
			task.spawn(function()
				local ok, img = pcall(function()
					return Players:GetUserThumbnailAsync(
						player.UserId,
						Enum.ThumbnailType.HeadShot,
						Enum.ThumbnailSize.Size100x100
					)
				end)
				if ok and typeof(img) == "string" then
					self.avatar.Image = img
				end
			end)
		end
	end
	self:setTab(tabId or self.current)
	self.Opened:Fire(self.current)
end

function PauseMenu:close()
	if not self.opened then
		return
	end
	self.opened = false
	ContextActionService:UnbindAction(ACTION)
	self.back.Enabled = false
	self.gui.Enabled = false
	if self.blur then
		self.blur:Destroy()
		self.blur = nil
	end
	self.Closed:Fire()
end

function PauseMenu:isOpen(): boolean
	return self.opened
end

return PauseMenu
