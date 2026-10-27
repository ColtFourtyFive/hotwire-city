--!strict
-- Phone: the parody handset (gta_ui_language §2.12, §5.11). PhoneController fills the apps.
--
--   local phone = Phone.new()
--   phone:setApps({ { id = "contacts", title = "Contacts", icon = "apps.contacts" }, ... })   3 x 3 grid
--   phone:open() / phone:close() / phone:toggle() / phone:isOpen()
--   phone:home()                                  back to the app grid
--   phone:page(title, build: (Frame) -> ())       open an app screen: `build` fills a scrolling frame
--   phone:setBadge(appId, count)                  red unread counts on the tiles (0 hides)
--   phone:setClock(text)                          status-row clock ("Tue 18:42")
--   phone.AppOpened: Signal(appId), phone.Closed: Signal(), phone.BackPressed: Signal()
--   Phone.row(parent, label, value?, opts?) -> TextButton   a list row inside an app page
--
-- Look: our own handset shell (Config/UIAssets phone_shell, 9-slice) bottom-right, sliding up from below; a status
-- row (signal, clock, battery); an Ignition Orange title bar with black Oswald text; a 3 x 3 grid of glossy app icons
-- with Oswald captions; the selection is an orange rounded square (the one place a corner radius is allowed); soft
-- keys at the bottom (select / back). Desktop 176 x 330 design px at (W - 36, H - 16); touch larger, right side.
-- Keys while open: arrows / D-pad move the selection, Enter / A open, Backspace / B back (home, then close).
-- Sizes come from Phone.metrics: on touch every text is >= 11.5 real px (§7) after the 0.72 UIScale floor and the
-- phone's own scale, and rows / soft keys are >= 30 real px tall; Phone.sizes() hands them to PhoneController.
-- Pure helpers (tests): gridMove, gridCell, metrics.

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)
local Kit = require(script.Parent.Kit)
local HudLayout = require(script.Parent.HudLayout)
local Signal = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Util"):WaitForChild("Signal"))

local Phone = {}
Phone.__index = Phone

local C = Theme.Colors
local COLS = 3

export type AppDef = { id: string, title: string, icon: string }

-- Grid cell (column, row; 1-based) of app index i.
function Phone.gridCell(i: number): (number, number)
	return ((i - 1) % COLS) + 1, math.floor((i - 1) / COLS) + 1
end

-- Selection after an arrow press on a grid of `count` apps (no wrap across rows; clamps at the edges).
function Phone.gridMove(count: number, index: number, dx: number, dy: number): number
	if count <= 0 then
		return 0
	end
	local col, row = Phone.gridCell(math.clamp(index, 1, count))
	local rows = math.ceil(count / COLS)
	col = math.clamp(col + dx, 1, COLS)
	row = math.clamp(row + dy, 1, rows)
	local i = (row - 1) * COLS + col
	return math.clamp(i, 1, count)
end

export type Metrics = {
	label: number, -- row label (bold)
	sub: number, -- row second line, timestamps
	value: number, -- row value
	paragraph: number, -- message bodies, intros
	caption: number, -- app tile captions
	status: number, -- status-row clock
	title: number, -- title bar
	row: number, -- row height (one line)
	rowSub: number, -- row height with a second line
	softKey: number, -- soft-key glyph size
	keyBar: number, -- soft-key bar height
	tileH: number, -- app tile height
	tilePitch: number, -- app tile row pitch
	icon: number, -- app icon size
	field: number, -- text box height (Codes)
}

local MIN_TEXT_REAL = 11.5 -- §7: smallest readable text on a phone, real px
local MIN_TAP_REAL = 30 -- ~8% of a 375 px tall phone screen

-- In-phone design sizes. `realScale` = real px per in-phone px (the screen UIScale x the phone's own UIScale). Touch
-- sizes grow until text reaches MIN_TEXT_REAL and rows / soft keys MIN_TAP_REAL (capped so the 176 px handset still
-- lays out); desktop keeps the GTA-small phone.
function Phone.metrics(touch: boolean, realScale: number): Metrics
	local H = HudLayout.PHONE.h
	local screenH = H - 38
	local gridTop = 44
	if not touch then
		local keyBar = 26
		local pitch = math.floor((screenH - gridTop - keyBar - 4) / 3)
		return {
			label = 11,
			sub = 10,
			value = 11,
			paragraph = 11,
			caption = 10,
			status = 11,
			title = 15,
			row = 26,
			rowSub = 38,
			softKey = 18,
			keyBar = keyBar,
			tileH = pitch - 2,
			tilePitch = pitch,
			icon = 42,
			field = 26,
		}
	end
	local s = if realScale == realScale and realScale > 0 then realScale else 1
	local text = math.clamp(math.ceil(MIN_TEXT_REAL / s), 12, 17)
	local tap = math.clamp(math.ceil(MIN_TAP_REAL / s), 34, 44)
	local row = math.max(36, tap)
	local keyBar = tap + 4
	local pitch = math.floor((screenH - gridTop - keyBar - 4) / 3) -- tiles start 4 px into the grid
	local tileH = pitch - 2
	local caption = text
	return {
		label = text + 1,
		sub = text,
		value = text,
		paragraph = text + 1,
		caption = caption,
		status = text,
		title = 17,
		row = row,
		rowSub = row + text,
		softKey = tap,
		keyBar = keyBar,
		tileH = tileH,
		tilePitch = pitch,
		icon = math.clamp(tileH - (caption + 2) - 8, 28, 42),
		field = row,
	}
end

local active: Metrics = Phone.metrics(false, 1)

-- The sizes the built phone uses (PhoneController lays its app pages out with them).
function Phone.sizes(): Metrics
	return active
end

local ACTION = "HC_Phone"

function Phone.new(): any
	local self = setmetatable({}, Phone) :: any
	self.apps = {} :: { AppDef }
	self.tiles = {} :: { [string]: Frame }
	self.badges = {} :: { [string]: Frame }
	self.index = 1
	self.opened = false
	self.inPage = false
	self.AppOpened = Signal.new()
	self.Closed = Signal.new()
	self.BackPressed = Signal.new()
	return self
end

function Phone:_build()
	if self.gui then
		return
	end
	local touch = Kit.isTouch()
	local gui = Kit.screen("HC_Phone", Theme.Layers.Phone, { touchMin = Theme.TouchMinScale })
	gui.Enabled = false
	self.gui = gui
	-- frees a locked mouse (shift-lock / first person) while the phone is up so its tiles and rows can be clicked; a
	-- 1 px button: it must not swallow taps meant for the world or the touch controls
	Kit.new("TextButton", {
		Name = "Modal",
		Modal = true,
		BackgroundTransparency = 1,
		Text = "",
		Size = UDim2.fromOffset(1, 1),
		Parent = gui,
	})
	local canvas = Kit.canvasSize(gui)
	local L = HudLayout.compute(canvas.X, canvas.Y, touch)
	local W, H = HudLayout.PHONE.w, HudLayout.PHONE.h
	active = Phone.metrics(touch, Kit.uiScale(Theme.TouchMinScale) * L.phoneScale)
	local M = active
	local holder = Kit.new("Frame", {
		Name = "Phone",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -(L.w - L.phone.x - L.phone.w), 1, -(L.h - L.phone.y - L.phone.h)),
		Size = UDim2.fromOffset(W, H),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	Kit.new("UIScale", { Scale = L.phoneScale, Parent = holder })
	self.holder = holder
	self.restPosition = holder.Position
	-- screen (under the shell's transparent window)
	local screen = Kit.new("Frame", {
		Name = "Screen",
		Position = UDim2.fromOffset(6, 16),
		Size = UDim2.fromOffset(W - 12, H - 38),
		BackgroundColor3 = Color3.fromRGB(16, 18, 22),
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = holder,
	})
	Kit.new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Color3.fromRGB(44, 40, 58), Color3.fromRGB(12, 12, 16)),
		Parent = screen,
	})
	self.screen = screen
	local shellId = Kit.resolveImage("phone_shell")
	if shellId then
		local shell = Kit.image("phone_shell", {
			Name = "Shell",
			Size = UDim2.fromScale(1, 1),
			ScaleType = Enum.ScaleType.Slice,
			ZIndex = 5,
			Parent = holder,
		})
		pcall(function()
			local A = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("UIAssets"))
			shell.SliceCenter = A.PHONE_SLICE
			shell.SliceScale = 0.34
		end)
	else
		local frame = Kit.new("Frame", {
			Name = "Shell",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			ZIndex = 5,
			Parent = holder,
		})
		Kit.new("UICorner", { CornerRadius = UDim.new(0, 18), Parent = frame })
		Kit.new("UIStroke", { Color = Color3.fromRGB(24, 24, 28), Thickness = 6, Parent = frame })
	end
	-- status row
	local status = Kit.new("Frame", {
		Name = "Status",
		Size = UDim2.new(1, 0, 0, 16),
		BackgroundColor3 = C.Black,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		Parent = screen,
	})
	Kit.image("hud.signal", {
		Size = UDim2.fromOffset(12, 12),
		Position = UDim2.fromOffset(6, 2),
		Parent = status,
	})
	self.clock = Kit.text("", "condensedMedium", M.status, {
		Name = "Clock",
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = status,
	})
	Kit.image("hud.battery", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 2),
		Size = UDim2.fromOffset(14, 12),
		Parent = status,
	})
	-- title bar
	local titleBar = Kit.new("Frame", {
		Name = "TitleBar",
		Position = UDim2.fromOffset(0, 16),
		Size = UDim2.new(1, 0, 0, 24),
		BackgroundColor3 = C.Accent,
		BorderSizePixel = 0,
		Parent = screen,
	})
	self.titleLabel = Kit.text("Fone", "condensed", M.title, {
		Name = "Title",
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromOffset(8, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.Black,
		Parent = titleBar,
	})
	-- home grid
	local grid = Kit.new("Frame", {
		Name = "Home",
		Position = UDim2.fromOffset(0, 44),
		Size = UDim2.new(1, 0, 1, -44 - M.keyBar),
		BackgroundTransparency = 1,
		Parent = screen,
	})
	self.grid = grid
	local highlight = Kit.new("Frame", {
		Name = "Selection",
		Size = UDim2.fromOffset(52, M.tileH - 8),
		BackgroundColor3 = C.Accent,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		ZIndex = 1,
		Parent = grid,
	})
	Kit.new("UICorner", { CornerRadius = Theme.CornerPhone, Parent = highlight })
	self.highlight = highlight
	-- app page
	local page = Kit.new("ScrollingFrame", {
		Name = "Page",
		Position = UDim2.fromOffset(0, 40),
		Size = UDim2.new(1, 0, 1, -40 - M.keyBar),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 2,
		ScrollBarImageColor3 = C.TextDim,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Visible = false,
		Parent = screen,
	})
	Kit.list(Enum.FillDirection.Vertical, 1, Enum.HorizontalAlignment.Center).Parent = page
	self.page = page
	-- soft keys
	local keys = Kit.new("Frame", {
		Name = "SoftKeys",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, M.keyBar),
		BackgroundColor3 = C.Black,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		Parent = screen,
	})
	local function softKey(icon: string, color: Color3, anchor: number, fn: () -> ())
		local b = Kit.new("ImageButton", {
			AnchorPoint = Vector2.new(anchor, 0.5),
			Position = UDim2.new(anchor, if anchor == 0 then 10 else -10, 0.5, 0),
			Size = UDim2.fromOffset(M.softKey, M.softKey),
			BackgroundTransparency = 1,
			Image = "",
			Parent = keys,
		})
		local id, off, size = Kit.resolveImage(icon)
		b.Image = id or ""
		if off and size then
			b.ImageRectOffset = off
			b.ImageRectSize = size
		end
		b.ImageColor3 = color
		b.Activated:Connect(fn)
	end
	softKey("hud.check", C.Green, 0, function()
		self:activate()
	end)
	softKey("hud.back", C.Red, 1, function()
		self:back()
	end)
	self:_layoutGrid()
end

function Phone:_layoutGrid()
	for _, t in self.tiles do
		t:Destroy()
	end
	self.tiles = {}
	self.badges = {}
	local M = active
	local gridW = HudLayout.PHONE.w - 12
	local cellW = gridW / COLS
	for i, app in self.apps do
		local col, row = Phone.gridCell(i)
		local tile = Kit.new("TextButton", {
			Name = "App_" .. app.id,
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			Text = "",
			Position = UDim2.fromOffset((col - 1) * cellW, (row - 1) * M.tilePitch + 4),
			Size = UDim2.fromOffset(cellW, M.tileH),
			ZIndex = 2,
			Parent = self.grid,
		})
		Kit.image(app.icon, {
			Name = "Icon",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 6),
			Size = UDim2.fromOffset(M.icon, M.icon),
			ZIndex = 2,
			Parent = tile,
		})
		Kit.text(string.upper(app.title), "condensedMedium", M.caption, {
			Name = "Caption",
			Position = UDim2.fromOffset(0, 6 + M.icon + 2),
			Size = UDim2.new(1, 0, 0, M.caption + 4),
			ZIndex = 2,
			Parent = tile,
		})
		local badge = Kit.new("Frame", {
			Name = "Badge",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 20, 0, 8),
			Size = UDim2.fromOffset(16, 16),
			BackgroundColor3 = C.Red,
			BorderSizePixel = 0,
			Visible = false,
			ZIndex = 3,
			Parent = tile,
		})
		Kit.new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = badge })
		Kit.text("", "numeric", 11, {
			Name = "Count",
			Size = UDim2.fromScale(1, 1),
			ZIndex = 4,
			Parent = badge,
		})
		local slot = i
		tile.MouseEnter:Connect(function()
			self:_select(slot)
		end)
		tile.Activated:Connect(function()
			self:_select(slot)
			self:activate()
		end)
		self.tiles[app.id] = tile
		self.badges[app.id] = badge
	end
	self:_select(math.clamp(self.index, 1, math.max(1, #self.apps)))
end

function Phone:_select(i: number)
	self.index = i
	local app = self.apps[i]
	local tile = app and self.tiles[app.id]
	if tile and self.highlight then
		self.highlight.Visible = not self.inPage
		self.highlight.Position = tile.Position + UDim2.fromOffset((tile.Size.X.Offset - 52) / 2, 2)
	end
end

function Phone:setApps(apps: { AppDef })
	self.apps = apps
	if self.gui then
		self:_layoutGrid()
	end
end

function Phone:setBadge(appId: string, count: number)
	self:_build()
	local b = self.badges[appId]
	if not b then
		return
	end
	b.Visible = count > 0
	local label = b:FindFirstChild("Count")
	if label and label:IsA("TextLabel") then
		label.Text = if count > 9 then "9+" else tostring(count)
	end
end

function Phone:setClock(text: string)
	if self.clock then
		self.clock.Text = text
	end
end

function Phone:home()
	self:_build()
	self.inPage = false
	self.page.Visible = false
	self.grid.Visible = true
	self.titleLabel.Text = "Fone"
	self:_select(self.index)
end

-- Opens an app screen. `build(page)` fills the scrolling page (rows via Phone.row).
function Phone:page(title: string, build: (ScrollingFrame) -> ())
	self:_build()
	self.inPage = true
	self.grid.Visible = false
	self.highlight.Visible = false
	for _, c in self.page:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	self.page.CanvasPosition = Vector2.zero
	self.titleLabel.Text = Kit.sanitize(title)
	self.page.Visible = true
	build(self.page)
end

function Phone:activate()
	if self.inPage then
		return
	end
	local app = self.apps[self.index]
	if app then
		self.AppOpened:Fire(app.id)
	end
end

function Phone:back()
	if self.inPage then
		self.BackPressed:Fire()
		self:home()
	else
		self:close()
	end
end

function Phone:_bind()
	ContextActionService:BindActionAtPriority(
		ACTION,
		function(_, state: Enum.UserInputState, input: InputObject)
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			local k = input.KeyCode
			local n = #self.apps
			if not self.inPage and (k == Enum.KeyCode.Up or k == Enum.KeyCode.DPadUp) then
				self:_select(Phone.gridMove(n, self.index, 0, -1))
			elseif not self.inPage and (k == Enum.KeyCode.Down or k == Enum.KeyCode.DPadDown) then
				self:_select(Phone.gridMove(n, self.index, 0, 1))
			elseif not self.inPage and (k == Enum.KeyCode.Left or k == Enum.KeyCode.DPadLeft) then
				self:_select(Phone.gridMove(n, self.index, -1, 0))
			elseif not self.inPage and (k == Enum.KeyCode.Right or k == Enum.KeyCode.DPadRight) then
				self:_select(Phone.gridMove(n, self.index, 1, 0))
			elseif k == Enum.KeyCode.Return or k == Enum.KeyCode.KeypadEnter or k == Enum.KeyCode.ButtonA then
				self:activate()
			elseif k == Enum.KeyCode.Backspace or k == Enum.KeyCode.ButtonB then
				self:back()
			else
				return Enum.ContextActionResult.Pass
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value + 25,
		Enum.KeyCode.Up,
		Enum.KeyCode.Down,
		Enum.KeyCode.Left,
		Enum.KeyCode.Right,
		Enum.KeyCode.DPadUp,
		Enum.KeyCode.DPadDown,
		Enum.KeyCode.DPadLeft,
		Enum.KeyCode.DPadRight,
		Enum.KeyCode.Return,
		Enum.KeyCode.KeypadEnter,
		Enum.KeyCode.ButtonA,
		Enum.KeyCode.Backspace,
		Enum.KeyCode.ButtonB
	)
end

function Phone:open()
	self:_build()
	if self.opened then
		return
	end
	self.opened = true
	self.gui.Enabled = true
	self:home()
	self:_bind()
	local rest = self.restPosition
	self.holder.Position = UDim2.new(rest.X.Scale, rest.X.Offset, 1, 360)
	TweenService:Create(self.holder, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		Position = rest,
	}):Play()
end

function Phone:close()
	if not self.opened then
		return
	end
	self.opened = false
	ContextActionService:UnbindAction(ACTION)
	local rest = self.restPosition
	local t = TweenService:Create(self.holder, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Position = UDim2.new(rest.X.Scale, rest.X.Offset, 1, 360),
	})
	t.Completed:Once(function()
		if not self.opened then
			self.gui.Enabled = false
		end
	end)
	t:Play()
	self.Closed:Fire()
end

function Phone:toggle()
	if self.opened then
		self:close()
	else
		self:open()
	end
end

function Phone:isOpen(): boolean
	return self.opened
end

export type RowOpts = { color: Color3?, sub: string?, icon: string?, height: number?, order: number? }

-- A tappable row inside an app page: label (Montserrat), optional right value, optional grey second line / icon.
function Phone.row(parent: Instance, label: string, value: string?, opts: RowOpts?): TextButton
	local o: RowOpts = opts or {}
	local M = active
	local h = math.max(o.height or 0, if o.sub then M.rowSub else M.row)
	local lineH = M.label + 4
	local row = Kit.new("TextButton", {
		Name = "Row",
		AutoButtonColor = false,
		BackgroundColor3 = C.Black,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Text = "",
		Size = UDim2.new(1, -6, 0, h),
		LayoutOrder = o.order or 0,
		Parent = parent,
	})
	local left = 6
	if o.icon then
		Kit.image(o.icon, {
			Name = "Icon",
			Position = UDim2.fromOffset(4, (h - 28) / 2),
			Size = UDim2.fromOffset(28, 28),
			Parent = row,
		})
		left = 38
	end
	Kit.text(label, "bodyBold", M.label, {
		Name = "Label",
		Position = UDim2.fromOffset(left, if o.sub then 4 else 0),
		Size = UDim2.new(0.68, -left, 0, if o.sub then lineH else h),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = o.color or C.Text,
		Parent = row,
	})
	if o.sub then
		Kit.text(o.sub, "body", M.sub, {
			Name = "Sub",
			Position = UDim2.fromOffset(left, 4 + lineH),
			Size = UDim2.new(1, -left - 6, 0, M.sub + 4),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = C.TextDim,
			Parent = row,
		})
	end
	if value then
		Kit.text(value, "condensedMedium", M.value, {
			Name = "Value",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -6, 0, if o.sub then 4 else 0),
			Size = UDim2.new(0.4, 0, 0, if o.sub then lineH else h),
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = row,
		})
	end
	row.MouseEnter:Connect(function()
		row.BackgroundColor3 = C.TextPure
		row.BackgroundTransparency = 0
		for _, l in row:GetChildren() do
			if l:IsA("TextLabel") then
				l:SetAttribute("Rest", l.TextColor3:ToHex())
				l.TextColor3 = C.Black
			end
		end
	end)
	row.MouseLeave:Connect(function()
		row.BackgroundColor3 = C.Black
		row.BackgroundTransparency = 0.45
		for _, l in row:GetChildren() do
			local rest = l:GetAttribute("Rest")
			if l:IsA("TextLabel") and typeof(rest) == "string" then
				l.TextColor3 = Color3.fromHex(rest)
			end
		end
	end)
	return row
end

-- A wrapped paragraph inside an app page (message bodies, descriptions).
function Phone.paragraph(parent: Instance, text: string, opts: RowOpts?): TextLabel
	local o: RowOpts = opts or {}
	local l = Kit.text(text, "body", active.paragraph, {
		Name = "Paragraph",
		Size = UDim2.new(1, -12, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = o.color or C.Text,
		LayoutOrder = o.order or 0,
		Parent = parent,
	})
	return l
end

return Phone
