--!strict
-- Kit v2: the UI construction kit in GTA V's presentation language (docs/v2/research/gta_ui_language.md §4-§5).
-- Every controller builds its UI with these helpers so the whole game shares one look: flat black translucent panels,
-- no rounded corners, no gradients, no outlines on body text, Kanit / Oswald / Montserrat / Damion type, fades and
-- short slides instead of bounces, and no emoji anywhere (text passed through Kit is stripped of them).
--
-- Sizes are design px on a 1280x720 canvas that Kit.screen scales with a UIScale.
--
-- v1 entry points (label, panel, button, iconButton, progressBar, window, open, close, juice, pop, tweenNumber,
-- corner, stroke, gradient, ...) keep their signatures so older consumers compile; they now draw the v2 look.
-- New: text / numeric / script, key / keycap, instructionButton, tab + setTabSelected, row + setRowSelected,
-- circleButton, image / blip, fadeTree, inputKind, sanitize.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Theme = require(script.Parent.Theme)
local RichText = require(script.Parent.RichText)

local Kit = {}

local player = Players.LocalPlayer
local C = Theme.Colors

export type Props = { [string]: any }

-- Generic constructor: Kit.new("Frame", { Size = ..., Parent = ... }, { children })
function Kit.new(className: string, props: Props?, children: { Instance }?): any
	local inst = Instance.new(className)
	local parent = nil
	if props then
		for k, v in props do
			if k == "Parent" then
				parent = v
			else
				(inst :: any)[k] = v
			end
		end
	end
	if children then
		for _, c in children do
			c.Parent = inst
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function apply(inst: any, props: Props?)
	if props then
		for k, v in props do
			if k ~= "Parent" then
				inst[k] = v
			end
		end
		if props.Parent then
			inst.Parent = props.Parent
		end
	end
end

-- Text safe for display: emoji removed (kill list), gaps tidied only when something was removed.
function Kit.sanitize(text: any): string
	if typeof(text) ~= "string" then
		return if text == nil then "" else tostring(text)
	end
	local stripped = RichText.stripEmoji(text)
	if stripped == text then
		return text
	end
	return RichText.clean(stripped)
end

function Kit.corner(radius: UDim?): UICorner
	return Kit.new("UICorner", { CornerRadius = radius or Theme.Corner })
end

function Kit.stroke(color: Color3?, thickness: number?, mode: Enum.ApplyStrokeMode?): UIStroke
	return Kit.new("UIStroke", {
		Color = color or C.Outline,
		Thickness = thickness or Theme.StrokeThickness,
		ApplyStrokeMode = mode or Enum.ApplyStrokeMode.Border,
		LineJoinMode = Enum.LineJoinMode.Miter,
	})
end

function Kit.padding(px: number, horizontal: number?): UIPadding
	local v = UDim.new(0, px)
	local h = UDim.new(0, horizontal or px)
	return Kit.new("UIPadding", { PaddingTop = v, PaddingBottom = v, PaddingLeft = h, PaddingRight = h })
end

-- Kept for older consumers. v2 never puts gradients on text or panels (brand gradient: loading / key art only).
function Kit.gradient(top: Color3, bottom: Color3, rotation: number?): UIGradient
	return Kit.new("UIGradient", {
		Color = ColorSequence.new(top, bottom),
		Rotation = rotation or 90,
	})
end

function Kit.list(
	direction: Enum.FillDirection?,
	padding: number?,
	hAlign: Enum.HorizontalAlignment?,
	vAlign: Enum.VerticalAlignment?
): UIListLayout
	return Kit.new("UIListLayout", {
		FillDirection = direction or Enum.FillDirection.Vertical,
		Padding = UDim.new(0, padding or 8),
		HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Center,
		VerticalAlignment = vAlign or Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
end

-- True when the player is (primarily) on a touch screen. PreferredInput when the engine has it, else the classic
-- "touch without a mouse" test.
function Kit.isTouch(): boolean
	local ok, preferred = pcall(function()
		return (UserInputService :: any).PreferredInput
	end)
	if ok and typeof(preferred) == "EnumItem" then
		return preferred.Name == "Touch"
	end
	return UserInputService.TouchEnabled == true and UserInputService.MouseEnabled ~= true
end

export type InputKind = "keyboard" | "gamepad" | "touch"

-- Which glyph set to show in help text / instructional buttons.
function Kit.inputKind(): InputKind
	local ok, preferred = pcall(function()
		return (UserInputService :: any).PreferredInput
	end)
	if ok and typeof(preferred) == "EnumItem" then
		if preferred.Name == "Touch" then
			return "touch"
		elseif preferred.Name == "Gamepad" then
			return "gamepad"
		end
		return "keyboard"
	end
	local okLast, last = pcall(function()
		return UserInputService:GetLastInputType()
	end)
	if okLast and typeof(last) == "EnumItem" and string.find(last.Name, "Gamepad", 1, true) then
		return "gamepad"
	end
	return if Kit.isTouch() then "touch" else "keyboard"
end

-- The UIScale every Kit.screen uses: 1280x720 design canvas fit into the viewport, clamped to 0.55..1.6.
-- touchMin raises the floor on touch devices so text stays readable on phones (Theme.TouchMinScale).
function Kit.uiScale(touchMin: number?): number
	local cam = Workspace.CurrentCamera
	local s = 1
	if cam then
		local vp = cam.ViewportSize
		if vp.X >= 1 and vp.Y >= 1 then
			s = math.clamp(math.min(vp.X / 1280, vp.Y / 720), 0.55, 1.6)
		end
	end
	if touchMin and Kit.isTouch() then
		s = math.max(s, touchMin)
	end
	return s
end

export type ScreenOpts = {
	touchMin: number?,
	-- "core" (default): CoreUISafeInsets, clear of the Roblox top bar and notches (HUD, menus, phone).
	-- "none": the whole screen (big-message band, blur tint, letterbox, fades); IgnoreGuiInset too.
	-- "device": DeviceSafeInsets (notches only).
	insets: string?,
	parent: Instance?,
}

local INSETS: { [string]: Enum.ScreenInsets } = {
	core = Enum.ScreenInsets.CoreUISafeInsets,
	none = Enum.ScreenInsets.None,
	device = Enum.ScreenInsets.DeviceSafeInsets,
}

-- ScreenGui with automatic UIScale so a 1280x720 design looks right on phones and 4K.
function Kit.screen(name: string, displayOrder: number, opts: ScreenOpts?): ScreenGui
	local insets = if opts and opts.insets then opts.insets else "core"
	local gui = Kit.new("ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		IgnoreGuiInset = insets == "none",
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = displayOrder,
	})
	pcall(function()
		gui.ScreenInsets = INSETS[insets] or Enum.ScreenInsets.CoreUISafeInsets
	end)
	gui.Parent = if opts and opts.parent then opts.parent else player:WaitForChild("PlayerGui")
	local scale = Kit.new("UIScale", { Parent = gui })
	local touchMin = if opts then opts.touchMin else nil
	local function update()
		scale.Scale = Kit.uiScale(touchMin)
	end
	update()
	-- these outlive the gui unless dropped with it (list menus are created and destroyed per shop visit)
	local conns: { RBXScriptConnection } = {}
	local cam = Workspace.CurrentCamera
	if cam then
		table.insert(conns, cam:GetPropertyChangedSignal("ViewportSize"):Connect(update))
	end
	if touchMin then
		pcall(function()
			table.insert(conns, UserInputService.LastInputTypeChanged:Connect(update))
		end)
	end
	pcall(function()
		gui.Destroying:Once(function()
			for _, c in conns do
				c:Disconnect()
			end
			table.clear(conns)
		end)
	end)
	return gui
end

-- Design-px size of a Kit.screen's canvas (its AbsoluteSize / UIScale); 1280x720 until it has been laid out.
function Kit.canvasSize(gui: ScreenGui): Vector2
	local ok, abs = pcall(function(): Vector2
		return gui.AbsoluteSize
	end)
	local scale = gui:FindFirstChildOfClass("UIScale")
	local s = if scale and scale.Scale > 0 then scale.Scale else 1
	if not ok or typeof(abs) ~= "Vector2" or abs.X < 1 or abs.Y < 1 then
		return Vector2.new(1280, 720)
	end
	return Vector2.new(abs.X / s, abs.Y / s)
end

-------------------------------------------------------------------------------------------------------------------------
-- Text
-------------------------------------------------------------------------------------------------------------------------

export type TextRole =
	"body"
	| "bodyRegular"
	| "bodyBold"
	| "condensed"
	| "condensedMedium"
	| "numeric"
	| "display"
	| "script"

local ROLE_FONT: { [string]: Font } = {
	body = Theme.Fonts.Body,
	bodyRegular = Theme.Fonts.BodyRegular,
	bodyBold = Theme.Fonts.BodyBold,
	condensed = Theme.Fonts.Condensed,
	condensedMedium = Theme.Fonts.CondensedMedium,
	numeric = Theme.Fonts.Numeric,
	display = Theme.Fonts.Display,
	script = Theme.Fonts.Script,
}

-- Text label in a role. Numeric / display get the 2 px contextual outline (cash, ammo, timers), script a soft 1 px
-- one; body / condensed text has no outline (§4: no stroke on body text).
function Kit.text(text: string, role: TextRole, size: number, props: Props?): TextLabel
	local lbl = Kit.new("TextLabel", {
		BackgroundTransparency = 1,
		Text = Kit.sanitize(text),
		TextSize = size,
		FontFace = ROLE_FONT[role] or Theme.Fonts.Body,
		TextColor3 = C.Text,
		Size = UDim2.new(1, 0, 0, math.ceil(size * 1.25)),
		TextWrapped = false,
		RichText = true,
	})
	if role == "numeric" or role == "display" then
		Kit.new("UIStroke", {
			Name = "Outline",
			Color = C.Outline,
			Thickness = Theme.TextStroke,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
			Parent = lbl,
		})
	elseif role == "script" then
		Kit.new("UIStroke", {
			Name = "Outline",
			Color = C.Outline,
			Thickness = 1,
			Transparency = 0.6,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
			Parent = lbl,
		})
	end
	apply(lbl, props)
	return lbl
end

-- Kanit Black numbers with the 2 px outline (cash, ammo, timers, speed).
function Kit.numeric(text: string, size: number, props: Props?): TextLabel
	return Kit.text(text, "numeric", size, props)
end

-- Damion script line (vehicle / district / street names).
function Kit.script(text: string, size: number, props: Props?): TextLabel
	return Kit.text(text, "script", size, props)
end

-- v1 label: Montserrat body text, wrapped, rich text, no automatic outline any more.
function Kit.label(text: string, size: number, props: Props?): TextLabel
	local lbl = Kit.new("TextLabel", {
		BackgroundTransparency = 1,
		Text = Kit.sanitize(text),
		TextSize = size,
		FontFace = Theme.Fonts.Body,
		TextColor3 = C.Text,
		Size = UDim2.new(1, 0, 0, size + 6),
		TextWrapped = true,
		RichText = true,
	})
	apply(lbl, props)
	return lbl
end

-- RichText key cap string ("Hold " .. Kit.key("E") .. " to hotwire").
function Kit.key(name: string): string
	return RichText.key(name)
end

-------------------------------------------------------------------------------------------------------------------------
-- Panels and controls
-------------------------------------------------------------------------------------------------------------------------

-- Flat GTA panel: black at 73% (INGAME_BG), no corner, no stroke, no gradient.
function Kit.panel(props: Props?): Frame
	local f = Kit.new("Frame", {
		BackgroundColor3 = C.Black,
		BackgroundTransparency = Theme.Alpha.Panel,
		BorderSizePixel = 0,
	})
	apply(f, props)
	return f
end

-- Hover feedback for any GuiButton: the background lightens a touch while the pointer is over it. No scaling.
function Kit.juice(button: GuiButton)
	local base: number? = nil
	button.MouseEnter:Connect(function()
		base = button.BackgroundTransparency
		if button.BackgroundTransparency < 1 then
			TweenService:Create(button, Theme.TweenFast, {
				BackgroundTransparency = math.max(0, button.BackgroundTransparency - 0.15),
			}):Play()
		end
	end)
	button.MouseLeave:Connect(function()
		if base then
			TweenService:Create(button, Theme.TweenFast, { BackgroundTransparency = base }):Play()
			base = nil
		end
	end)
end

local NEUTRAL: { Color3 } = { C.Panel, C.PanelLight, C.Background, C.Black, C.MenuHighlight, C.MenuDark }
local function isNeutral(c: Color3): boolean
	for _, n in NEUTRAL do
		if n == c then
			return true
		end
	end
	return false
end

-- Flat button (instruction style): black translucent, Oswald uppercase, hover inverts to white with black text. A
-- meaningful `color` (not a panel grey) becomes a 3 px rule along the bottom. Returns the TextButton (.Activated).
function Kit.button(text: string, color: Color3?, props: Props?): TextButton
	local btn = Kit.new("TextButton", {
		AutoButtonColor = false,
		BackgroundColor3 = C.Black,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		Text = string.upper(Kit.sanitize(text)),
		TextSize = 18,
		FontFace = Theme.Fonts.CondensedMedium,
		TextColor3 = C.Text,
		Size = UDim2.fromOffset(180, 40),
		RichText = true,
	})
	Kit.new("UIStroke", {
		Name = "Edge",
		Color = C.Text,
		Transparency = 0.82,
		Thickness = 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = btn,
	})
	local rule: Frame? = nil
	if color and not isNeutral(color) then
		rule = Kit.new("Frame", {
			Name = "Rule",
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, 3),
			Parent = btn,
		})
	end
	apply(btn, props)
	local restText = btn.TextColor3
	local restBg = btn.BackgroundColor3
	local restAlpha = btn.BackgroundTransparency
	-- pcall: headless builds (Lune instances have no mouse events) still get the button
	pcall(function()
		btn.MouseEnter:Connect(function()
			restText, restBg, restAlpha = btn.TextColor3, btn.BackgroundColor3, btn.BackgroundTransparency
			btn.BackgroundColor3 = C.TextPure
			btn.BackgroundTransparency = 0
			btn.TextColor3 = C.Black
			if rule then
				rule.Visible = false
			end
		end)
		btn.MouseLeave:Connect(function()
			btn.BackgroundColor3 = restBg
			btn.BackgroundTransparency = restAlpha
			btn.TextColor3 = restText
			if rule then
				rule.Visible = true
			end
		end)
	end)
	return btn
end

-- Round touch button (§7): a flat black circle with a white glyph / caption, >= 8% of the screen height.
-- `image` (a UIAssets key or content id) replaces the glyph text when given.
function Kit.circleButton(caption: string, size: number, image: string?, props: Props?): TextButton
	local btn = Kit.new("TextButton", {
		AutoButtonColor = false,
		BackgroundColor3 = C.Black,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Text = "",
		Size = UDim2.fromOffset(size, size),
	})
	Kit.new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = btn })
	Kit.new("UIStroke", {
		Color = C.Text,
		Transparency = 0.7,
		Thickness = 1.5,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = btn,
	})
	local glyph = if image then Kit.image(image) else nil
	if glyph then
		glyph.Name = "Icon"
		glyph.AnchorPoint = Vector2.new(0.5, 0.5)
		glyph.Position = UDim2.fromScale(0.5, 0.42)
		glyph.Size = UDim2.fromScale(0.46, 0.46)
		glyph.ImageColor3 = C.Text
		glyph.Parent = btn
	end
	-- touch buttons sit on the 0.72 UIScale floor: 14 design px keeps the caption >= 10 real px (§7 asks >= 11.5 for
	-- body text; a one-word caption under a glyph reads at this size)
	Kit.text(caption, "condensedMedium", math.max(14, math.floor(size * 0.2)), {
		Name = "Caption",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, if glyph then 0.78 else 0.5),
		Size = UDim2.fromScale(0.9, 0.3),
		TextScaled = false,
		Text = string.upper(Kit.sanitize(caption)),
		Parent = btn,
	})
	apply(btn, props)
	btn.MouseButton1Down:Connect(function()
		btn.BackgroundTransparency = 0.1
	end)
	btn.MouseButton1Up:Connect(function()
		btn.BackgroundTransparency = 0.35
	end)
	btn.MouseLeave:Connect(function()
		btn.BackgroundTransparency = 0.35
	end)
	return btn
end

-- v1 icon tile (emoji + caption) -> a flat circle with the caption; any emoji icon is dropped (kill list).
function Kit.iconButton(icon: string, caption: string, color: Color3?): TextButton
	local btn = Kit.circleButton(caption, 64, nil)
	local glyph = Kit.sanitize(icon)
	if glyph ~= "" then
		local cap = btn:FindFirstChild("Caption")
		if cap and cap:IsA("TextLabel") then
			cap.Position = UDim2.fromScale(0.5, 0.74)
		end
		Kit.text(glyph, "condensed", 24, {
			Name = "Icon",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.4),
			Size = UDim2.fromScale(0.8, 0.45),
			Parent = btn,
		})
	end
	if color and not isNeutral(color) then
		local edge = btn:FindFirstChildOfClass("UIStroke")
		if edge then
			edge.Color = color
			edge.Transparency = 0.2
		end
	end
	return btn
end

-- Flat progress bar: a darkened track + the fill, no corners. Returns (track, setFraction(fraction, tween?)).
function Kit.progressBar(fill: Color3, props: Props?): (Frame, (number, boolean?) -> ())
	local bg = Kit.new("Frame", {
		BackgroundColor3 = fill:Lerp(C.Black, 0.6),
		BackgroundTransparency = 0.15,
		Size = UDim2.fromOffset(200, 6),
		BorderSizePixel = 0,
		ClipsDescendants = true,
	})
	local bar = Kit.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = fill,
		Size = UDim2.fromScale(0, 1),
		BorderSizePixel = 0,
		Parent = bg,
	})
	apply(bg, props)
	local function set(fraction: number, tween: boolean?)
		local f = if fraction == fraction then math.clamp(fraction, 0, 1) else 0
		local target = UDim2.fromScale(f, 1)
		if tween then
			TweenService:Create(bar, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = target,
			}):Play()
		else
			bar.Size = target
		end
	end
	return bg, set
end

-- GTA key cap (white, black bold text). `name` like "E", "ENTER", "ESC". Returns a Frame sized to fit.
function Kit.keycap(name: string, height: number?): Frame
	local h = height or 20
	local label = string.upper(name)
	local w = math.max(h, #label * math.floor(h * 0.5) + 10)
	local cap = Kit.new("Frame", {
		Name = "KeyCap",
		BackgroundColor3 = C.TextPure,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(w, h),
	})
	Kit.new("UICorner", { CornerRadius = Theme.CornerSmall, Parent = cap })
	Kit.new("TextLabel", {
		Name = "Key",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = label,
		TextSize = math.floor(h * 0.62),
		FontFace = Theme.Fonts.BodyBold,
		TextColor3 = C.Black,
		Parent = cap,
	})
	return cap
end

-- Instructional button (pause / list footers, §5.12): "<label> [KEY]" — clickable, so touch can use it too.
function Kit.instructionButton(key: string?, label: string, props: Props?): TextButton
	local btn = Kit.new("TextButton", {
		Name = "Instruction",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Text = "",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 24),
	})
	Kit.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center).Parent =
		btn
	local text = Kit.text(label, "body", 14, {
		Name = "Label",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 24),
		LayoutOrder = 1,
		Parent = btn,
	})
	text.TextXAlignment = Enum.TextXAlignment.Right
	if key and key ~= "" then
		local cap = Kit.keycap(key, 20)
		cap.LayoutOrder = 2
		cap.Parent = btn
	end
	apply(btn, props)
	pcall(function() -- headless builds: no mouse events
		btn.MouseEnter:Connect(function()
			text.TextColor3 = C.TextPure
		end)
		btn.MouseLeave:Connect(function()
			text.TextColor3 = C.Text
		end)
	end)
	return btn
end

-- Pause-menu tab: black translucent, Oswald uppercase; Kit.setTabSelected inverts it with an accent top rule.
function Kit.tab(text: string, props: Props?): TextButton
	local tab = Kit.new("TextButton", {
		Name = "Tab",
		AutoButtonColor = false,
		BackgroundColor3 = C.Black,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		Text = string.upper(Kit.sanitize(text)),
		TextSize = 15,
		FontFace = Theme.Fonts.CondensedMedium,
		TextColor3 = C.Text,
		Size = UDim2.fromOffset(140, 26),
	})
	Kit.new("Frame", {
		Name = "Rule",
		BackgroundColor3 = C.Accent,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, 0, 0, 3),
		Visible = false,
		Parent = tab,
	})
	apply(tab, props)
	return tab
end

function Kit.setTabSelected(tab: GuiButton, selected: boolean)
	local t = tab :: any
	t.BackgroundColor3 = if selected then C.TextPure else C.Black
	t.BackgroundTransparency = if selected then 0 else 0.3
	if tab:IsA("TextButton") then
		tab.TextColor3 = if selected then C.Black else C.Text
	end
	local rule = tab:FindFirstChild("Rule")
	if rule and rule:IsA("GuiObject") then
		rule.Visible = selected
	end
end

-- Interaction-menu row (§5.13): label left (Montserrat), optional value right (Kanit), black translucent; the selected
-- row inverts (white background, black text). Children: Label, Value.
function Kit.row(label: string, value: string?, props: Props?): TextButton
	local row = Kit.new("TextButton", {
		Name = "Row",
		AutoButtonColor = false,
		BackgroundColor3 = C.Black,
		BackgroundTransparency = Theme.Alpha.Row,
		BorderSizePixel = 0,
		Text = "",
		Size = UDim2.new(1, 0, 0, 28),
	})
	Kit.padding(0, 10).Parent = row
	Kit.text(label, "body", 14, {
		Name = "Label",
		Size = UDim2.fromScale(0.62, 1),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	})
	Kit.text(value or "", "body", 14, {
		Name = "Value",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromScale(0.38, 1),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	})
	apply(row, props)
	return row
end

-- Selected / normal / disabled row colours.
function Kit.setRowSelected(row: GuiObject, selected: boolean, disabled: boolean?)
	row.BackgroundColor3 = if selected then C.TextPure else C.Black
	row.BackgroundTransparency = if selected then 0 else Theme.Alpha.Row
	local textColor = if selected then C.Black elseif disabled then C.TextDisabled else C.Text
	for _, name in { "Label", "Value" } do
		local l = row:FindFirstChild(name)
		if l and l:IsA("TextLabel") then
			l.TextColor3 = textColor
		end
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Images (Config/UIAssets sprites, Config/Minimap blip atlas)
-------------------------------------------------------------------------------------------------------------------------

local uiAssets: any = nil
local function assets(): any
	if uiAssets == nil then
		local ok, mod = pcall(function()
			local shared = ReplicatedStorage:FindFirstChild("Shared")
			local config = shared and shared:FindFirstChild("Config")
			local m = config and config:FindFirstChild("UIAssets")
			return if m then require(m :: any) else nil
		end)
		uiAssets = if ok and mod then mod else false
	end
	return if uiAssets == false then nil else uiAssets
end

-- (content id, rect offset, rect size) for a UIAssets key: a whole image ("loading_1") or a sheet cell
-- ("hud.star_fill"). Raw "rbxassetid://" strings pass through. nil when the art is not uploaded.
function Kit.resolveImage(key: string): (string?, Vector2?, Vector2?)
	if string.sub(key, 1, 13) == "rbxassetid://" or string.sub(key, 1, 11) == "rbxasset://" then
		return key, nil, nil
	end
	local A = assets()
	if not A then
		return nil, nil, nil
	end
	local sheetName, cell = string.match(key, "^(%w+)%.(.+)$")
	if sheetName and cell then
		local sheet = A.Sheets and A.Sheets[sheetName]
		local c = sheet and sheet.cells and sheet.cells[cell]
		if sheet and c and typeof(sheet.image) == "string" and sheet.image ~= "" then
			return sheet.image, Vector2.new(c[1], c[2]), Vector2.new(c[3], c[4])
		end
		return nil, nil, nil
	end
	local id = A.Images and A.Images[key]
	return if typeof(id) == "string" and id ~= "" then id else nil, nil, nil
end

-- ImageLabel for a UIAssets key (see resolveImage); an empty transparent label when the art is missing.
function Kit.image(key: string, props: Props?): ImageLabel
	local id, offset, size = Kit.resolveImage(key)
	local img = Kit.new("ImageLabel", {
		Name = key,
		BackgroundTransparency = 1,
		Image = id or "",
		ScaleType = Enum.ScaleType.Fit,
	})
	if offset and size then
		img.ImageRectOffset = offset
		img.ImageRectSize = size
	end
	apply(img, props)
	return img
end

-- Point an existing ImageLabel at another UIAssets key.
function Kit.setImage(img: ImageLabel, key: string)
	local id, offset, size = Kit.resolveImage(key)
	img.Image = id or ""
	img.ImageRectOffset = offset or Vector2.zero
	img.ImageRectSize = size or Vector2.zero
end

local minimapConfig: any = nil
-- Blip glyph from the minimap atlas (Config/Minimap ATLAS + ATLAS_CELLS), tinted with ImageColor3.
function Kit.blip(icon: string, size: number, props: Props?): ImageLabel
	if minimapConfig == nil then
		local ok, mod = pcall(function()
			local m = ReplicatedStorage:FindFirstChild("Shared")
			m = m and m:FindFirstChild("Config")
			m = m and m:FindFirstChild("Minimap")
			return if m then require(m :: any) else nil
		end)
		minimapConfig = if ok and mod then mod else false
	end
	local cfg = if minimapConfig == false then nil else minimapConfig
	local cell = cfg and cfg.ATLAS_CELLS and (cfg.ATLAS_CELLS[icon] or cfg.ATLAS_CELLS.dot)
	local img = Kit.new("ImageLabel", {
		Name = "Blip",
		BackgroundTransparency = 1,
		Image = if cfg then cfg.ATLAS else "",
		Size = UDim2.fromOffset(size, size),
		ScaleType = Enum.ScaleType.Fit,
	})
	if cell then
		img.ImageRectOffset = Vector2.new(cell[1], cell[2])
		img.ImageRectSize = Vector2.new(cell[3], cell[4])
	end
	apply(img, props)
	return img
end

-------------------------------------------------------------------------------------------------------------------------
-- Windows (v1 modal API) and motion
-------------------------------------------------------------------------------------------------------------------------

-- v1 modal window, GTA-styled: a flat dark panel with a near-black header strip, an accent top rule, an Oswald title
-- and a flat "X". Returns (window, scrolling body, close button). Starts hidden: Kit.open / Kit.close.
function Kit.window(parent: Instance, title: string, accent: Color3?, size: UDim2?): (Frame, ScrollingFrame, TextButton)
	local win = Kit.panel({
		Name = title,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.52),
		Size = size or UDim2.fromOffset(640, 440),
		BackgroundTransparency = 0.18,
		Visible = false,
		Parent = parent,
	})
	Kit.new("UIScale", { Parent = win })
	local header = Kit.new("Frame", {
		Name = "Header",
		BackgroundColor3 = C.MenuHighlight,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 44),
		Parent = win,
	})
	Kit.new("Frame", {
		Name = "Rule",
		BackgroundColor3 = if accent and not isNeutral(accent) then accent else C.Accent,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 3),
		Parent = header,
	})
	Kit.text(string.upper(Kit.sanitize(title)), "condensed", 22, {
		Name = "Title",
		Size = UDim2.new(1, -80, 1, 0),
		Position = UDim2.fromOffset(16, 1),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = header,
	})
	local close = Kit.new("TextButton", {
		Name = "Close",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 1),
		Size = UDim2.fromOffset(32, 32),
		BackgroundColor3 = C.Black,
		BackgroundTransparency = 1,
		Text = "X",
		TextSize = 20,
		FontFace = Theme.Fonts.Condensed,
		TextColor3 = C.TextDim,
		Parent = header,
	})
	close.MouseEnter:Connect(function()
		close.TextColor3 = C.TextPure
	end)
	close.MouseLeave:Connect(function()
		close.TextColor3 = C.TextDim
	end)
	local body = Kit.new("ScrollingFrame", {
		Name = "Body",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 48),
		Size = UDim2.new(1, 0, 1, -52),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = C.TextDim,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = win,
	})
	Kit.padding(14).Parent = body
	close.Activated:Connect(function()
		Kit.close(win)
	end)
	return win, body, close
end

local SLIDE = 8
local openInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function basePosition(win: GuiObject): UDim2
	local stored = win:GetAttribute("KitBaseY")
	if typeof(stored) ~= "number" then
		win:SetAttribute("KitBaseY", win.Position.Y.Offset)
		return win.Position
	end
	local p = win.Position
	return UDim2.new(p.X.Scale, p.X.Offset, p.Y.Scale, stored)
end

-- Show a window / panel: an 8 px slide up with a fade-in feel (0.2 s). No scale pop.
function Kit.open(win: GuiObject)
	local base = basePosition(win)
	local scale = win:FindFirstChildOfClass("UIScale")
	if scale then
		scale.Scale = 1
	end
	win.Position = UDim2.new(base.X.Scale, base.X.Offset, base.Y.Scale, base.Y.Offset + SLIDE)
	win.Visible = true
	TweenService:Create(win, openInfo, { Position = base }):Play()
end

function Kit.close(win: GuiObject)
	local base = basePosition(win)
	local t = TweenService:Create(win, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Position = UDim2.new(base.X.Scale, base.X.Offset, base.Y.Scale, base.Y.Offset + SLIDE),
	})
	t.Completed:Once(function()
		win.Visible = false
		win.Position = base
	end)
	t:Play()
end

-- Animate a number in a TextLabel from its current value to `target` (uses an attribute to remember).
function Kit.tweenNumber(label: TextLabel, target: number, formatter: (number) -> string, duration: number?)
	local from = label:GetAttribute("Value")
	local start = if typeof(from) == "number" then from else target
	label:SetAttribute("Value", target)
	local d = duration or 0.4
	local t0 = os.clock()
	local token = (label:GetAttribute("TweenToken") or 0) + 1
	label:SetAttribute("TweenToken", token)
	task.spawn(function()
		while true do
			if label:GetAttribute("TweenToken") ~= token then
				return
			end
			local a = math.clamp((os.clock() - t0) / d, 0, 1)
			local eased = 1 - (1 - a) ^ 3
			label.Text = formatter(start + (target - start) * eased)
			if a >= 1 then
				return
			end
			task.wait()
		end
	end)
end

-- Subtle settle animation (v1 "pop"): from `amount` (clamped to 0.9..1.15, §5.0) back to 1 over 0.15 s, no overshoot.
function Kit.pop(gui: GuiObject, amount: number?)
	local scale = gui:FindFirstChildOfClass("UIScale") or Kit.new("UIScale", { Parent = gui })
	scale.Scale = math.clamp(amount or 1.08, 0.9, 1.15)
	TweenService:Create(scale, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
end

-- Fade a whole subtree to `alpha` (0 = as built, 1 = invisible) over `seconds`. Each element's built transparency is
-- remembered on first use, so fading back in restores the design (panels stay at their 0.27, etc.).
local baseAlpha: { [Instance]: { [string]: number } } = setmetatable({}, { __mode = "k" }) :: any
local FADE_PROPS: { [string]: { string } } = {
	TextLabel = { "TextTransparency", "BackgroundTransparency", "TextStrokeTransparency" },
	TextButton = { "TextTransparency", "BackgroundTransparency" },
	TextBox = { "TextTransparency", "BackgroundTransparency" },
	ImageLabel = { "ImageTransparency", "BackgroundTransparency" },
	ImageButton = { "ImageTransparency", "BackgroundTransparency" },
	Frame = { "BackgroundTransparency" },
	ScrollingFrame = { "BackgroundTransparency", "ScrollBarImageTransparency" },
	UIStroke = { "Transparency" },
}
function Kit.fadeTree(root: Instance, alpha: number, seconds: number?)
	local info = TweenInfo.new(seconds or 0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
	local function fadeOne(inst: Instance)
		local props = FADE_PROPS[inst.ClassName]
		if not props then
			return
		end
		local base = baseAlpha[inst]
		if not base then
			base = {}
			for _, p in props do
				base[p] = (inst :: any)[p]
			end
			baseAlpha[inst] = base
		end
		local goal = {}
		for p, b in base do
			goal[p] = b + (1 - b) * math.clamp(alpha, 0, 1)
		end
		if seconds == 0 then
			for p, v in goal do
				(inst :: any)[p] = v
			end
		else
			TweenService:Create(inst, info, goal):Play()
		end
	end
	fadeOne(root)
	for _, d in root:GetDescendants() do
		fadeOne(d)
	end
end

return Kit
