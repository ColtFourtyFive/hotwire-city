--!strict
-- Tiny UI construction kit. Every controller builds its UI with these helpers so the whole game
-- shares one look. All sizes are in Scale or Offset that is later scaled by the ScreenGui's UIScale.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Theme = require(script.Parent.Theme)

local Kit = {}

local player = Players.LocalPlayer

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

function Kit.corner(radius: UDim?): UICorner
	return Kit.new("UICorner", { CornerRadius = radius or Theme.Corner })
end

function Kit.stroke(color: Color3?, thickness: number?, mode: Enum.ApplyStrokeMode?): UIStroke
	return Kit.new("UIStroke", {
		Color = color or Theme.Colors.Stroke,
		Thickness = thickness or Theme.StrokeThickness,
		ApplyStrokeMode = mode or Enum.ApplyStrokeMode.Border,
		LineJoinMode = Enum.LineJoinMode.Round,
	})
end

function Kit.padding(px: number): UIPadding
	local u = UDim.new(0, px)
	return Kit.new("UIPadding", { PaddingTop = u, PaddingBottom = u, PaddingLeft = u, PaddingRight = u })
end

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

-- ScreenGui with automatic UIScale so a 1280x720 design looks right on phones and 4K.
function Kit.screen(name: string, displayOrder: number): ScreenGui
	local gui = Kit.new("ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = displayOrder,
		Parent = player:WaitForChild("PlayerGui"),
	})
	local scale = Kit.new("UIScale", { Parent = gui })
	local function update()
		local cam = Workspace.CurrentCamera
		if not cam then
			return
		end
		local vp = cam.ViewportSize
		local s = math.min(vp.X / 1280, vp.Y / 720)
		scale.Scale = math.clamp(s, 0.55, 1.6)
	end
	update()
	local cam = Workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(update)
	end
	return gui
end

-- Text label with display font + outline stroke (readable on any background).
function Kit.label(text: string, size: number, props: Props?): TextLabel
	local lbl = Kit.new("TextLabel", {
		BackgroundTransparency = 1,
		Text = text,
		TextSize = size,
		FontFace = Theme.Fonts.Display,
		TextColor3 = Theme.Colors.Text,
		Size = UDim2.new(1, 0, 0, size + 6),
		TextWrapped = true,
		RichText = true,
	})
	Kit.stroke(Theme.Colors.Stroke, math.max(1.5, size / 14), Enum.ApplyStrokeMode.Contextual).Parent = lbl
	if props then
		for k, v in props do
			(lbl :: any)[k] = v
		end
	end
	return lbl
end

-- Rounded panel with dark stroke and subtle vertical gradient.
function Kit.panel(props: Props?): Frame
	local f = Kit.new("Frame", {
		BackgroundColor3 = Theme.Colors.Panel,
		BorderSizePixel = 0,
	})
	Kit.corner().Parent = f
	Kit.stroke().Parent = f
	Kit.gradient(Color3.new(1, 1, 1), Color3.fromRGB(200, 200, 215)).Parent = f
	if props then
		for k, v in props do
			(f :: any)[k] = v
		end
	end
	return f
end

-- Hover/press juice for any GuiButton.
function Kit.juice(button: GuiButton)
	local scale = button:FindFirstChildOfClass("UIScale") or Kit.new("UIScale", { Parent = button })
	button.MouseEnter:Connect(function()
		TweenService:Create(scale, Theme.TweenFast, { Scale = 1.06 }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(scale, Theme.TweenFast, { Scale = 1 }):Play()
	end)
	button.MouseButton1Down:Connect(function()
		TweenService:Create(scale, Theme.TweenFast, { Scale = 0.92 }):Play()
	end)
	button.MouseButton1Up:Connect(function()
		TweenService:Create(scale, Theme.TweenPop, { Scale = 1 }):Play()
	end)
end

-- Big chunky button. color = fill; returns the TextButton (connect .Activated).
function Kit.button(text: string, color: Color3?, props: Props?): TextButton
	local btn = Kit.new("TextButton", {
		AutoButtonColor = false,
		BackgroundColor3 = color or Theme.Colors.Primary,
		Text = text,
		TextSize = 22,
		FontFace = Theme.Fonts.Display,
		TextColor3 = Theme.Colors.Text,
		Size = UDim2.fromOffset(180, 52),
		RichText = true,
	})
	Kit.corner().Parent = btn
	Kit.stroke().Parent = btn
	Kit.new("UIStroke", {
		Color = Theme.Colors.Stroke,
		Thickness = 2,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = btn,
	})
	Kit.gradient(Color3.new(1, 1, 1), Color3.fromRGB(185, 185, 185)).Parent = btn
	if props then
		for k, v in props do
			(btn :: any)[k] = v
		end
	end
	Kit.juice(btn)
	return btn
end

-- Square icon button with emoji + small caption underneath (side menu buttons).
function Kit.iconButton(icon: string, caption: string, color: Color3?): TextButton
	local btn = Kit.new("TextButton", {
		AutoButtonColor = false,
		BackgroundColor3 = color or Theme.Colors.PanelLight,
		Size = UDim2.fromOffset(64, 64),
		Text = "",
	})
	Kit.corner(UDim.new(0, 16)).Parent = btn
	Kit.stroke().Parent = btn
	Kit.gradient(Color3.new(1, 1, 1), Color3.fromRGB(180, 180, 195)).Parent = btn
	Kit.new("TextLabel", {
		Name = "Icon",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0.72),
		Text = icon,
		TextScaled = true,
		FontFace = Theme.Fonts.Display,
		TextColor3 = Theme.Colors.Text,
		Parent = btn,
	})
	local cap = Kit.label(caption, 13, {
		Name = "Caption",
		Position = UDim2.new(0, 0, 1, -16),
		Size = UDim2.new(1, 0, 0, 16),
	})
	cap.Parent = btn
	Kit.juice(btn)
	return btn
end

-- Horizontal progress bar. Returns (container, setFraction(fraction, tween?)).
function Kit.progressBar(fill: Color3, props: Props?): (Frame, (number, boolean?) -> ())
	local bg = Kit.new("Frame", {
		BackgroundColor3 = Theme.Colors.Background,
		Size = UDim2.fromOffset(200, 16),
		BorderSizePixel = 0,
	})
	Kit.corner(UDim.new(1, 0)).Parent = bg
	Kit.stroke(Theme.Colors.Stroke, 2).Parent = bg
	local bar = Kit.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = fill,
		Size = UDim2.fromScale(0, 1),
		BorderSizePixel = 0,
		Parent = bg,
	})
	Kit.corner(UDim.new(1, 0)).Parent = bar
	Kit.gradient(Color3.new(1, 1, 1), Color3.fromRGB(170, 170, 170)).Parent = bar
	if props then
		for k, v in props do
			(bg :: any)[k] = v
		end
	end
	local function set(fraction: number, tween: boolean?)
		local target = UDim2.fromScale(math.clamp(fraction, 0, 1), 1)
		if tween then
			TweenService:Create(bar, Theme.TweenMedium, { Size = target }):Play()
		else
			bar.Size = target
		end
	end
	return bg, set
end

-- Modal window with title + close button + scrolling body. Returns (window, body, close).
-- The window starts hidden; call Kit.open(window) / Kit.close(window).
function Kit.window(parent: Instance, title: string, accent: Color3?, size: UDim2?): (Frame, ScrollingFrame, TextButton)
	local win = Kit.panel({
		Name = title,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.52),
		Size = size or UDim2.fromOffset(640, 440),
		Visible = false,
		Parent = parent,
	})
	Kit.new("UIScale", { Parent = win })
	local header = Kit.new("Frame", {
		Name = "Header",
		BackgroundColor3 = accent or Theme.Colors.Primary,
		Size = UDim2.new(1, 0, 0, 56),
		BorderSizePixel = 0,
		Parent = win,
	})
	Kit.corner().Parent = header
	Kit.gradient(Color3.new(1, 1, 1), Color3.fromRGB(170, 170, 170)).Parent = header
	-- square off the header's bottom corners
	Kit.new("Frame", {
		BackgroundColor3 = accent or Theme.Colors.Primary,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 1, -14),
		Size = UDim2.new(1, 0, 0, 14),
		Parent = header,
	})
	Kit.label(title, 30, {
		Name = "Title",
		Size = UDim2.new(1, -120, 1, 0),
		Position = UDim2.fromOffset(20, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 2,
	}).Parent =
		header
	local close = Kit.button("X", Theme.Colors.Danger, {
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(42, 42),
		ZIndex = 3,
	})
	close.Parent = header
	local body = Kit.new("ScrollingFrame", {
		Name = "Body",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 60),
		Size = UDim2.new(1, 0, 1, -64),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = Theme.Colors.TextDim,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = win,
	})
	Kit.padding(14).Parent = body
	close.Activated:Connect(function()
		Kit.close(win)
	end)
	return win, body, close
end

function Kit.open(win: GuiObject)
	local scale = win:FindFirstChildOfClass("UIScale")
	win.Visible = true
	if scale then
		scale.Scale = 0.7
		TweenService:Create(scale, Theme.TweenPop, { Scale = 1 }):Play()
	end
end

function Kit.close(win: GuiObject)
	local scale = win:FindFirstChildOfClass("UIScale")
	if scale then
		local t = TweenService:Create(scale, Theme.TweenFast, { Scale = 0.7 })
		t.Completed:Once(function()
			win.Visible = false
			scale.Scale = 1
		end)
		t:Play()
	else
		win.Visible = false
	end
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

-- Pop scale animation (for "+$" text, purchase success, etc).
function Kit.pop(gui: GuiObject, amount: number?)
	local scale = gui:FindFirstChildOfClass("UIScale") or Kit.new("UIScale", { Parent = gui })
	scale.Scale = amount or 1.25
	TweenService:Create(scale, Theme.TweenPop, { Scale = 1 }):Play()
end

return Kit
