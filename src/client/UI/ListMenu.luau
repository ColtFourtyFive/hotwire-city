--!strict
-- ListMenu: GTA's "interaction menu" list (gta_ui_language §2.14, §5.13), the one shared component for shops, the
-- gear counter, garage / dealership / spray actions and the combat package's gun shop. Also embeddable as the
-- left-hand list of a pause-menu tab (ListMenu.embed).
--
--   local menu = ListMenu.new({ title = "Gear Shop", banner = "gear", subtitle = "Upgrades" })
--   menu:setItems({
--       { id = "nitro", label = "Nitro Tank", value = "$4,000", desc = "Longer boost." },
--       { id = "color", label = "Paint", options = { "Red", "Blue" }, optionIndex = 1 },
--       { id = "lock", label = "Garage Lock", value = "MAX", disabled = true },   -- greyed, not selectable action
--       { separator = true, label = "TOOLS" },                                     -- section line, skipped by nav
--   })
--   menu.Selected:Connect(function(item) ... end)       Enter / A / click on the selected row
--   menu.Changed:Connect(function(item, optionIndex) ... end)   < > on an options row
--   menu.Closed:Connect(function() ... end)              Backspace / B / the back button, or menu:close()
--   menu:open() / menu:close() / menu:isOpen() / menu:select(index) / menu:setSubtitle(text) / menu:destroy()
--
-- Look: header banner (Config/UIAssets banners.<key> art with a Damion title; an accent band without art), a black
-- subheader "TITLE ... 3/12", rows of white text on translucent black with the selected row inverted (white / black),
-- right-aligned prices, "< value >" selectors, a description box under the list. Desktop: top-left, 300 wide, 28 px
-- rows. Touch: a full-width bottom sheet sized by HudLayout (at least three 40 px rows, a two-line description and the
-- Back / Select buttons), every row in a ScrollingFrame that a finger drag scrolls; the first tap on a row selects it
-- and shows its description, a second tap on the selected row acts (no accidental purchases).
-- Input while open: Up / Down (D-pad, mouse wheel) move, Left / Right change options, Enter / A select, Backspace / B
-- back. Movement keys (WASD, thumbstick) stay free: you can walk away from a counter with the menu open.
-- ListMenu.ScreenListsChanged(count, widest) fires when own-screen lists open / close (the HUD moves the desktop help
-- box out of the list's corner).
-- Pure helpers (tests): step, counter, windowTop, cycle, scrollToShow, tapAction.

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent.Theme)
local Kit = require(script.Parent.Kit)
local HudLayout = require(script.Parent.HudLayout)
local Signal = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Util"):WaitForChild("Signal"))

local ListMenu = {}

-- Shop banner art behind the header title (UIAssets "banners.<shop>"). Off until per-shop key art exists: the first
-- sheet was one generic skyline that did not say which shop you are in, so headers are the Accent band with the
-- Damion title (gta_ui_language §5.13's fallback).
ListMenu.BANNER_ART = false
ListMenu.__index = ListMenu

local C = Theme.Colors

export type Item = {
	id: string?,
	label: string,
	value: string?,
	desc: string?,
	disabled: boolean?, -- shown greyed; Selected still fires (callers explain why it can't be bought)
	locked: boolean?, -- greyed + lock glyph
	separator: boolean?, -- a section caption; never selected
	options: { string }?,
	optionIndex: number?,
	color: Color3?, -- label colour (e.g. rarity)
	data: any?,
}

-------------------------------------------------------------------------------------------------------------------------
-- Pure helpers
-------------------------------------------------------------------------------------------------------------------------

local function selectable(item: Item?): boolean
	return item ~= nil and item.separator ~= true
end

-- Next selectable index from `index` in direction `dir` (+1 / -1), wrapping. Returns `index` when nothing else can be
-- selected, 0 for a list with no selectable rows.
function ListMenu.step(items: { Item }, index: number, dir: number): number
	local n = #items
	if n == 0 then
		return 0
	end
	local d = if dir < 0 then -1 else 1
	local i = if index >= 1 and index <= n then index else (if d > 0 then 0 else n + 1)
	for _ = 1, n do
		i += d
		if i > n then
			i = 1
		elseif i < 1 then
			i = n
		end
		if selectable(items[i]) then
			return i
		end
	end
	return if selectable(items[index]) then index else 0
end

-- First selectable index (0 when none).
function ListMenu.first(items: { Item }): number
	return ListMenu.step(items, 0, 1)
end

-- "3/12": position among the selectable rows.
function ListMenu.counter(items: { Item }, index: number): string
	local pos, total = 0, 0
	for i, item in items do
		if selectable(item) then
			total += 1
			if i == index then
				pos = total
			end
		end
	end
	return `{pos}/{total}`
end

-- Scroll window: the first visible row so `index` stays inside a window of `visible` rows (keeping `top` when it can).
function ListMenu.windowTop(index: number, count: number, visible: number, top: number): number
	if count <= visible then
		return 1
	end
	local t = math.clamp(top, 1, count - visible + 1)
	if index < t then
		t = index
	elseif index > t + visible - 1 then
		t = index - visible + 1
	end
	return math.clamp(t, 1, count - visible + 1)
end

-- Option index after a < / > press, wrapping.
function ListMenu.cycle(count: number, index: number, dir: number): number
	if count <= 0 then
		return 0
	end
	local i = ((if index >= 1 then index else 1) - 1 + (if dir < 0 then -1 else 1)) % count
	return i + 1
end

-- Touch lists scroll natively (a ScrollingFrame holding every row): the canvas offset that brings row `index`
-- (rowH tall) into a viewport viewH tall, keeping `canvasY` when the row is already fully visible.
function ListMenu.scrollToShow(index: number, rowH: number, viewH: number, canvasY: number): number
	if index < 1 or rowH <= 0 then
		return math.max(0, canvasY)
	end
	local top = (index - 1) * rowH
	if top < canvasY then
		return top
	elseif top + rowH > canvasY + viewH then
		return math.max(0, top + rowH - viewH)
	end
	return math.max(0, canvasY)
end

-- A tap / click on row `idx` while `selected` is the selected row: the first tap selects (and shows the
-- description), only a tap on the already-selected row acts. Separators do nothing.
function ListMenu.tapAction(items: { Item }, idx: number, selected: number): string
	if not selectable(items[idx]) then
		return "none"
	end
	return if idx == selected then "activate" else "select"
end

-- Own-screen lists that are open right now (the HUD moves the desktop help box out of their way).
local openScreens: { [any]: number } = {}
ListMenu.ScreenListsChanged = Signal.new() -- (count: number, widest: number)

local function fireScreens()
	local count, widest = 0, 0
	for _, w in openScreens do
		count += 1
		widest = math.max(widest, w)
	end
	ListMenu.ScreenListsChanged:Fire(count, widest)
end

-- (count, widest width) of the open own-screen lists.
function ListMenu.openScreens(): (number, number)
	local count, widest = 0, 0
	for _, w in openScreens do
		count += 1
		widest = math.max(widest, w)
	end
	return count, widest
end

-------------------------------------------------------------------------------------------------------------------------
-- Component
-------------------------------------------------------------------------------------------------------------------------

export type Opts = {
	title: string,
	banner: string?, -- Config/UIAssets banners cell ("gear", "garage", ...)
	subtitle: string?,
	parent: GuiObject?, -- embed into this frame (pause tabs) instead of an own screen
	visibleRows: number?,
	width: number?,
	bindKeys: boolean?, -- default true (embedded lists in pause tabs are driven by the pause menu's keys)
}

local seq = 0

function ListMenu.new(opts: Opts): any
	seq += 1
	local self = setmetatable({}, ListMenu) :: any
	self.opts = opts
	self.id = seq
	self.items = {} :: { Item }
	self.index = 0
	self.top = 1
	self.rows = {} :: { TextButton }
	self.Selected = Signal.new()
	self.Changed = Signal.new()
	self.Closed = Signal.new()
	self.Moved = Signal.new()
	self.opened = false
	self.built = false
	self.subtitle = opts.subtitle or opts.title
	return self
end

-- Embedded list (pause-menu tabs): renders into `parent`, no banner, no key bindings of its own.
function ListMenu.embed(parent: GuiObject, opts: Opts?): any
	local o: Opts = opts or { title = "" }
	o.parent = parent
	if o.bindKeys == nil then
		o.bindKeys = false
	end
	local m = ListMenu.new(o)
	m:open()
	return m
end

function ListMenu:_build()
	if self.built then
		return
	end
	self.built = true
	local opts: Opts = self.opts
	local touch = Kit.isTouch()
	self.touch = touch
	-- touch: every row lives in a ScrollingFrame (finger drags scroll natively); desktop: a window of rows moved by
	-- the keys and the mouse wheel, with the 3/12 counter
	self.scroll = touch
	local sheet = HudLayout.SHEET
	local rowH = if touch then sheet.row else 28
	self.rowH = rowH
	local root: Frame
	if opts.parent then
		root = Kit.new("Frame", {
			Name = "List",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Parent = opts.parent,
		})
		self.visible = opts.visibleRows or 12
	else
		local gui = Kit.screen("HC_List_" .. self.id, Theme.Layers.Menus, { touchMin = Theme.TouchMinScale })
		gui.Enabled = false
		self.gui = gui
		-- frees a locked mouse (shift-lock / first person) while the list is up so its rows can be clicked; a 1 px
		-- button: it must not swallow taps meant for the world or the touch controls
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
		if touch then
			root = Kit.new("Frame", {
				Name = "Sheet",
				BackgroundColor3 = C.Black,
				BackgroundTransparency = 0.15,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = UDim2.new(1, 0, 0, L.list.h),
				Parent = gui,
			})
			self.visible = HudLayout.sheetRows(L.list.h)
		else
			root = Kit.new("Frame", {
				Name = "Menu",
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(L.list.x, L.list.y),
				Size = UDim2.fromOffset(opts.width or L.list.w, 600),
				Parent = gui,
			})
			self.visible = opts.visibleRows or 10
		end
		self.screenWidth = if touch then 0 else (opts.width or L.list.w)
	end
	self.root = root
	local list = Kit.list(Enum.FillDirection.Vertical, 0, Enum.HorizontalAlignment.Left)
	list.Parent = root

	-- header banner (own screen only)
	if not opts.parent then
		local bannerH = if touch then sheet.header else 64
		local header = Kit.new("Frame", {
			Name = "Header",
			BackgroundColor3 = C.Accent,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, bannerH),
			LayoutOrder = 1,
			ClipsDescendants = true,
			Parent = root,
		})
		if opts.banner and ListMenu.BANNER_ART then
			local art = Kit.image("banners." .. opts.banner, {
				Name = "Art",
				Size = UDim2.fromScale(1, 1),
				ScaleType = Enum.ScaleType.Crop,
				Parent = header,
			})
			if art.Image ~= "" then
				header.BackgroundColor3 = C.Black
			end
		end
		Kit.script(opts.title, if touch then 30 else 36, {
			Name = "Title",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1, 1),
			TextXAlignment = Enum.TextXAlignment.Center,
			Parent = header,
		})
		if touch then
			local close = Kit.new("TextButton", {
				Name = "Back",
				AutoButtonColor = false,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -8, 0.5, 0),
				Size = UDim2.fromOffset(40, 40),
				BackgroundColor3 = C.Black,
				BackgroundTransparency = 0.4,
				Text = "X",
				TextSize = 22,
				FontFace = Theme.Fonts.Condensed,
				TextColor3 = C.Text,
				Parent = header,
			})
			close.Activated:Connect(function()
				self:close()
			end)
		end
	end

	-- subheader: TITLE ... 3/12
	local sub = Kit.new("Frame", {
		Name = "Subheader",
		BackgroundColor3 = C.Black,
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 24),
		LayoutOrder = 2,
		Parent = root,
	})
	Kit.padding(0, 10).Parent = sub
	self.subLabel = Kit.text(string.upper(self.subtitle), "condensedMedium", 13, {
		Name = "Caption",
		Size = UDim2.fromScale(0.75, 1),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = sub,
	})
	self.countLabel = Kit.text("0/0", "condensedMedium", 13, {
		Name = "Count",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromScale(0.25, 1),
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = sub,
	})

	local rowsFrame: GuiObject
	if self.scroll then
		rowsFrame = Kit.new("ScrollingFrame", {
			Name = "Rows",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			-- embedded (pause tab): fill the host under the subheader, above the rule + description box
			Size = if opts.parent
				then UDim2.new(1, 0, 1, -(24 + sheet.rule + sheet.desc))
				else UDim2.new(1, 0, 0, self.visible * rowH),
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ScrollBarThickness = 4,
			ScrollBarImageColor3 = C.TextDim,
			ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
			LayoutOrder = 3,
			Parent = root,
		})
	else
		rowsFrame = Kit.new("Frame", {
			Name = "Rows",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 3,
			Parent = root,
		})
	end
	Kit.list(Enum.FillDirection.Vertical, 0, Enum.HorizontalAlignment.Left).Parent = rowsFrame
	self.rowsFrame = rowsFrame

	-- separator line + description box (touch: a fixed two-line box so the sheet never grows off the screen)
	Kit.new("Frame", {
		Name = "Rule",
		BackgroundColor3 = C.Text,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, sheet.rule),
		LayoutOrder = 4,
		Parent = root,
	})
	local descBox = Kit.panel({
		Name = "Description",
		Size = if touch then UDim2.new(1, 0, 0, sheet.desc) else UDim2.fromScale(1, 0),
		AutomaticSize = if touch then Enum.AutomaticSize.None else Enum.AutomaticSize.Y,
		LayoutOrder = 5,
		Visible = false,
		Parent = root,
	})
	Kit.padding(6, 10).Parent = descBox
	self.descLabel = Kit.text("", "body", if touch then 16 else 13, {
		Name = "Text",
		Size = if touch then UDim2.fromScale(1, 1) else UDim2.fromScale(1, 0),
		AutomaticSize = if touch then Enum.AutomaticSize.None else Enum.AutomaticSize.Y,
		TextWrapped = true,
		TextTruncate = if touch then Enum.TextTruncate.AtEnd else Enum.TextTruncate.None,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = descBox,
	})
	self.descBox = descBox

	-- instructional buttons (also the touch controls)
	if not opts.parent then
		local hints = Kit.new("Frame", {
			Name = "Hints",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, if touch then sheet.hints else 30),
			LayoutOrder = 6,
			Parent = root,
		})
		Kit.list(Enum.FillDirection.Horizontal, 14, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center).Parent =
			hints
		local back =
			Kit.instructionButton(if touch then nil else "Backspace", "Back", { LayoutOrder = 1, Parent = hints })
		local sel = Kit.instructionButton(if touch then nil else "Enter", "Select", { LayoutOrder = 2, Parent = hints })
		back.Activated:Connect(function()
			self:close()
		end)
		sel.Activated:Connect(function()
			self:activate()
		end)
	end
end

function ListMenu:_row(i: number): TextButton
	local row = self.rows[i]
	if row then
		return row
	end
	row = Kit.row("", "", {
		Name = "Row" .. i,
		Size = UDim2.new(1, 0, 0, self.rowH),
		LayoutOrder = i,
		Parent = self.rowsFrame,
	})
	local label = row:FindFirstChild("Label") :: TextLabel
	local value = row:FindFirstChild("Value") :: TextLabel
	label.TextSize = if self.touch then 17 else 14
	value.TextSize = if self.touch then 17 else 15
	local lock = Kit.image("hud.lock", {
		Name = "Lock",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(14, 14),
		Visible = false,
		Parent = row,
	})
	lock.ImageColor3 = C.TextDisabled
	local slot = i
	row.MouseEnter:Connect(function()
		if self.touch then
			return -- taps fire MouseEnter too; on touch only a tap selects (see tapAction)
		end
		local idx = self.top + slot - 1
		if selectable(self.items[idx]) and idx ~= self.index then
			self:select(idx)
		end
	end)
	row.Activated:Connect(function()
		local idx = self.top + slot - 1
		local action = ListMenu.tapAction(self.items, idx, self.index)
		if action == "select" then
			self:select(idx) -- the first tap shows the description; a second tap buys / acts
		elseif action == "activate" then
			self:activate()
		end
	end)
	self.rows[i] = row
	return row
end

function ListMenu:_render()
	if not self.built then
		return
	end
	local items: { Item } = self.items
	local visible: number
	if self.scroll then
		-- every row is built; the ScrollingFrame shows a window of them
		visible = #items
		self.top = 1
		if not self.opts.parent then
			self.rowsFrame.Size = UDim2.new(1, 0, 0, math.max(1, math.min(self.visible, #items)) * self.rowH)
		end
	else
		visible = math.min(self.visible, #items)
		self.top = ListMenu.windowTop(math.max(1, self.index), #items, self.visible, self.top)
	end
	for i = 1, math.max(visible, #self.rows) do
		local row = if i <= visible then self:_row(i) else self.rows[i]
		if row then
			local idx = self.top + i - 1
			local item = items[idx]
			row.Visible = i <= visible and item ~= nil
			if item and i <= visible then
				local label = row:FindFirstChild("Label") :: TextLabel
				local value = row:FindFirstChild("Value") :: TextLabel
				local lock = row:FindFirstChild("Lock") :: ImageLabel
				local selected = idx == self.index
				local greyed = item.disabled == true or item.locked == true
				if item.separator then
					row.BackgroundColor3 = C.MenuHighlight
					row.BackgroundTransparency = 0.1
					label.Text = string.upper(Kit.sanitize(item.label))
					label.FontFace = Theme.Fonts.CondensedMedium
					label.TextColor3 = C.TextDim
					value.Text = ""
					lock.Visible = false
				else
					Kit.setRowSelected(row, selected, greyed)
					label.FontFace = Theme.Fonts.Body
					label.Text = Kit.sanitize(item.label)
					if item.color and not selected and not greyed then
						label.TextColor3 = item.color
					end
					local v = item.value or ""
					local opts = item.options
					if opts and #opts > 0 then
						local oi = math.clamp(item.optionIndex or 1, 1, #opts)
						v = if selected then `<  {opts[oi]}  >` else opts[oi]
					end
					value.Text = Kit.sanitize(v)
					value.FontFace = if string.find(v, "^%$") or string.find(v, "^R%$")
						then Theme.Fonts.Numeric
						else Theme.Fonts.Body
					lock.Visible = item.locked == true
					value.Position = if item.locked then UDim2.new(1, -18, 0, 0) else UDim2.fromScale(1, 0)
				end
			end
		end
	end
	self.countLabel.Text = ListMenu.counter(items, self.index)
	local item = items[self.index]
	local desc = if item and item.desc then Kit.sanitize(item.desc) else ""
	self.descBox.Visible = desc ~= ""
	self.descLabel.Text = desc
end

function ListMenu:setItems(items: { Item }, keepIndex: boolean?)
	self.items = items
	if not (keepIndex and selectable(items[self.index])) then
		self.index = ListMenu.first(items)
		self.top = 1
		if self.scroll and self.rowsFrame then
			(self.rowsFrame :: ScrollingFrame).CanvasPosition = Vector2.zero
		end
	end
	self:_render()
end

function ListMenu:getSelected(): Item?
	return self.items[self.index]
end

-- Touch: scroll the selected row into view (keys / gamepad on a touch device, focusSection, ...).
function ListMenu:_showSelected()
	if not (self.scroll and self.rowsFrame and self.index >= 1) then
		return
	end
	local sf = self.rowsFrame :: ScrollingFrame
	local row = self.rows[self.index] -- scroll mode builds every row: row i shows item i
	if not row then
		return
	end
	-- CanvasPosition is in the frame's own (pre-UIScale) units; the Absolute* sizes are screen pixels
	local s = row.AbsoluteSize.Y / self.rowH
	if not (s > 0) then
		return
	end
	local y = ListMenu.scrollToShow(self.index, self.rowH, sf.AbsoluteWindowSize.Y / s, sf.CanvasPosition.Y)
	sf.CanvasPosition = Vector2.new(0, y)
end

function ListMenu:select(index: number)
	if not selectable(self.items[index]) then
		return
	end
	self.index = index
	self:_render()
	self:_showSelected()
	self.Moved:Fire(self.items[index], index)
end

function ListMenu:move(dir: number)
	local nextIndex = ListMenu.step(self.items, self.index, dir)
	if nextIndex ~= 0 and nextIndex ~= self.index then
		self:select(nextIndex)
		ListMenu.tick()
	end
end

function ListMenu:change(dir: number)
	local item = self.items[self.index]
	if not item or not item.options or #item.options == 0 then
		return
	end
	item.optionIndex = ListMenu.cycle(#item.options, item.optionIndex or 1, dir)
	self:_render()
	ListMenu.tick()
	self.Changed:Fire(item, item.optionIndex)
end

function ListMenu:activate()
	local item = self.items[self.index]
	if selectable(item) then
		self.Selected:Fire(item, self.index)
	end
end

function ListMenu:setSubtitle(text: string)
	self.subtitle = text
	if self.subLabel then
		self.subLabel.Text = string.upper(Kit.sanitize(text))
	end
end

local ACTION = "HC_ListMenu"

function ListMenu:_bind()
	if self.opts.bindKeys == false then
		return
	end
	local name = ACTION .. self.id
	self.actionName = name
	ContextActionService:BindActionAtPriority(
		name,
		function(_, state: Enum.UserInputState, input: InputObject)
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			local k = input.KeyCode
			if k == Enum.KeyCode.Up or k == Enum.KeyCode.DPadUp then
				self:move(-1)
			elseif k == Enum.KeyCode.Down or k == Enum.KeyCode.DPadDown then
				self:move(1)
			elseif k == Enum.KeyCode.Left or k == Enum.KeyCode.DPadLeft then
				self:change(-1)
			elseif k == Enum.KeyCode.Right or k == Enum.KeyCode.DPadRight then
				self:change(1)
			elseif k == Enum.KeyCode.Return or k == Enum.KeyCode.KeypadEnter or k == Enum.KeyCode.ButtonA then
				self:activate()
			elseif k == Enum.KeyCode.Backspace or k == Enum.KeyCode.ButtonB then
				self:close()
			else
				return Enum.ContextActionResult.Pass
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value + 20,
		Enum.KeyCode.Up,
		Enum.KeyCode.Down,
		Enum.KeyCode.Left,
		Enum.KeyCode.Right,
		Enum.KeyCode.Return,
		Enum.KeyCode.KeypadEnter,
		Enum.KeyCode.Backspace,
		Enum.KeyCode.DPadUp,
		Enum.KeyCode.DPadDown,
		Enum.KeyCode.DPadLeft,
		Enum.KeyCode.DPadRight,
		Enum.KeyCode.ButtonA,
		Enum.KeyCode.ButtonB
	)
end

-- Mouse wheel over the list moves the selection (own screens and embedded lists alike).
function ListMenu:_hookWheel()
	if self.scroll then
		return -- touch lists scroll natively
	end
	if self.root and not self.wheelHooked then
		self.wheelHooked = true
		self.root.InputChanged:Connect(function(input: InputObject)
			if self.opened and input.UserInputType == Enum.UserInputType.MouseWheel then
				self:move(if input.Position.Z > 0 then -1 else 1)
			end
		end)
	end
end

function ListMenu:_unbind()
	if self.actionName then
		ContextActionService:UnbindAction(self.actionName)
		self.actionName = nil
	end
end

function ListMenu:open()
	self:_build()
	if self.opened then
		return
	end
	self.opened = true
	if self.gui then
		self.gui.Enabled = true
	end
	self.root.Visible = true
	if self.index == 0 then
		self.index = ListMenu.first(self.items)
	end
	self:_render()
	self:_bind()
	self:_hookWheel()
	if not self.opts.parent then
		Kit.open(self.root)
	end
	if self.gui then
		openScreens[self] = self.screenWidth or 0
		fireScreens()
	end
end

function ListMenu:close()
	if not self.opened then
		return
	end
	self.opened = false
	self:_unbind()
	if self.gui then
		self.gui.Enabled = false
	elseif self.root then
		self.root.Visible = false
	end
	if openScreens[self] then
		openScreens[self] = nil
		fireScreens()
	end
	self.Closed:Fire()
end

function ListMenu:isOpen(): boolean
	return self.opened
end

function ListMenu:destroy()
	self:_unbind()
	self.opened = false
	if openScreens[self] then
		openScreens[self] = nil
		fireScreens()
	end
	if self.gui then
		self.gui:Destroy()
	elseif self.root then
		self.root:Destroy()
	end
	self.Selected:DisconnectAll()
	self.Changed:DisconnectAll()
	self.Closed:DisconnectAll()
	self.Moved:DisconnectAll()
end

-- Navigation tick sound (SoundController "Click", if present). Overridable by the host.
function ListMenu.tick()
	local ok, mod = pcall(function()
		local players = game:GetService("Players")
		local ps = players.LocalPlayer:FindFirstChild("PlayerScripts")
		local client = ps and ps:FindFirstChild("Client")
		local controllers = client and client:FindFirstChild("Controllers")
		local sc = controllers and controllers:FindFirstChild("SoundController")
		return if sc then require(sc :: any) else nil
	end)
	if ok and mod and typeof(mod.play) == "function" then
		pcall(mod.play, "Click")
	end
end

return ListMenu
