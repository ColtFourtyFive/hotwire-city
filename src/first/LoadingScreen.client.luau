--!strict
-- LoadingScreen (AP4): the only LocalScript in ReplicatedFirst, so it runs before the rest of the game replicates.
--
--  * Replaces Roblox's default loading screen immediately with a navy gradient + "HOTWIRE CITY" wordmark (no assets
--    needed), then, once ReplicatedStorage.Shared.Config.Assets replicates, fades in the full-bleed
--    Images.loading_art and the Images.logo_hotwire_city logo as each finishes loading.
--  * Progress bar: ContentProvider:PreloadAsync of the key UI images (loading art, logo, billboard ads) blended with
--    game:IsLoaded() and the server AssetLibrary's AllReady attribute, eased so it never jumps or sits still.
--  * Rotating tips. Fades out once game:IsLoaded() and (ReplicatedStorage.AssetLibrary.AllReady or READY_TIMEOUT);
--    HARD_TIMEOUT is a last resort so nobody is ever stuck here.
--  * Mobile-safe: Scale sizes with min/max constraints, IgnoreGuiInset + no screen insets so the art is full-bleed
--    while the text stays centered.

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local READY_TIMEOUT = 12 -- seconds: stop waiting for AllReady (hero meshes keep streaming in behind the game)
local HARD_TIMEOUT = 25 -- seconds: leave even if game:IsLoaded() somehow never turns true
local MIN_SHOWN = 1.5 -- never just flash
local TIP_SECONDS = 3.2
local FADE_SECONDS = 0.6
local ASSETS_WAIT = 20 -- seconds to wait for Shared/Config/Assets to replicate

local TIPS = {
	"Hold E to hotwire",
	"Drive it into your DROP-OFF",
	"Lock your garage!",
	"Hot Drops = mythic cars",
	"Spray Shops lose the cops",
}
if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
	TIPS[1] = "Hold HOTWIRE to steal a car"
end

-- Palette mirrors client/UI/Theme (that module has not replicated yet when this runs).
local NAVY = Color3.fromRGB(18, 20, 38)
local NAVY_LIGHT = Color3.fromRGB(42, 46, 84)
local PINK = Color3.fromRGB(255, 52, 140)
local CYAN = Color3.fromRGB(0, 214, 255)
local WHITE = Color3.fromRGB(255, 255, 255)
local DIM = Color3.fromRGB(170, 176, 214)
local STROKE = Color3.fromRGB(10, 11, 22)
local DISPLAY_FONT = Font.fromEnum(Enum.Font.FredokaOne)
local BODY_FONT = Font.fromEnum(Enum.Font.GothamBold)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local startedAt = os.clock()

local function make(className: string, props: { [string]: any }): any
	local inst = Instance.new(className)
	for key, value in props do
		if key ~= "Parent" then
			(inst :: any)[key] = value
		end
	end
	if props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

local function textLabel(
	name: string,
	text: string,
	font: Font,
	color: Color3,
	maxSize: number,
	minSize: number,
	props: { [string]: any }
): any
	local label = make("TextLabel", {
		Name = name,
		BackgroundTransparency = 1,
		Text = text,
		FontFace = font,
		TextColor3 = color,
		TextScaled = true,
		TextWrapped = true,
	})
	for key, value in props do
		if key ~= "Parent" then
			label[key] = value
		end
	end
	make("UITextSizeConstraint", { MaxTextSize = maxSize, MinTextSize = minSize, Parent = label })
	make("UIStroke", {
		Color = STROKE,
		Thickness = math.max(1.5, maxSize / 14),
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = label,
	})
	label.Parent = props.Parent
	return label
end

---------------------------------------------------------------------------------------------------------------------
-- Build (no assets needed: this shows on the very first frame)
---------------------------------------------------------------------------------------------------------------------

local gui = make("ScreenGui", {
	Name = "HC_Loading",
	IgnoreGuiInset = true,
	ResetOnSpawn = false,
	DisplayOrder = 1000,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
pcall(function()
	(gui :: any).ScreenInsets = Enum.ScreenInsets.None
end)

local root = make("Frame", {
	Name = "Root",
	BackgroundColor3 = NAVY,
	BorderSizePixel = 0,
	Size = UDim2.fromScale(1, 1),
	Parent = gui,
})
make("UIGradient", {
	Color = ColorSequence.new(NAVY_LIGHT, NAVY),
	Rotation = 90,
	Parent = root,
})

local art = make("ImageLabel", {
	Name = "Art",
	BackgroundTransparency = 1,
	Size = UDim2.fromScale(1, 1),
	ScaleType = Enum.ScaleType.Crop,
	ImageTransparency = 1,
	Parent = root,
})

-- darken the lower half so the tip + bar read on any art
local shade = make("Frame", {
	Name = "Shade",
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.fromScale(0, 1),
	Size = UDim2.fromScale(1, 0.5),
	BackgroundColor3 = NAVY,
	BorderSizePixel = 0,
	Parent = root,
})
make("UIGradient", {
	Rotation = 90,
	Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0.15),
	}),
	Parent = shade,
})

local logoBox = make("Frame", {
	Name = "LogoBox",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.36),
	Size = UDim2.fromScale(0.72, 0.36),
	BackgroundTransparency = 1,
	Parent = root,
})
make("UISizeConstraint", { MaxSize = Vector2.new(900, 380), Parent = logoBox })
local logo = make("ImageLabel", {
	Name = "Logo",
	BackgroundTransparency = 1,
	Size = UDim2.fromScale(1, 1),
	ScaleType = Enum.ScaleType.Fit,
	ImageTransparency = 1,
	Parent = logoBox,
})
local wordmark = textLabel("Wordmark", "HOTWIRE CITY", DISPLAY_FONT, PINK, 110, 28, {
	Size = UDim2.fromScale(1, 0.62),
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	TextWrapped = false,
	Parent = logoBox,
})
make("UIGradient", {
	Color = ColorSequence.new(PINK, CYAN),
	Parent = wordmark,
})

local bottom = make("Frame", {
	Name = "Bottom",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.fromScale(0.5, 0.94),
	Size = UDim2.fromScale(0.8, 0.22),
	BackgroundTransparency = 1,
	Parent = root,
})
make("UISizeConstraint", { MinSize = Vector2.new(240, 84), MaxSize = Vector2.new(760, 150), Parent = bottom })

local tip = textLabel("Tip", "💡 " .. TIPS[1], DISPLAY_FONT, WHITE, 30, 14, {
	Size = UDim2.fromScale(1, 0.42),
	Parent = bottom,
})
local status = textLabel("Status", "LOADING", BODY_FONT, DIM, 16, 10, {
	Position = UDim2.fromScale(0, 0.48),
	Size = UDim2.fromScale(1, 0.18),
	Parent = bottom,
})
local track = make("Frame", {
	Name = "Track",
	Position = UDim2.fromScale(0, 0.74),
	Size = UDim2.fromScale(1, 0.18),
	BackgroundColor3 = NAVY_LIGHT,
	BorderSizePixel = 0,
	Parent = bottom,
})
make("UICorner", { CornerRadius = UDim.new(1, 0), Parent = track })
make("UIStroke", { Color = STROKE, Thickness = 2, Parent = track })
local fill = make("Frame", {
	Name = "Fill",
	Size = UDim2.fromScale(0.04, 1),
	BackgroundColor3 = WHITE,
	BorderSizePixel = 0,
	Parent = track,
})
make("UICorner", { CornerRadius = UDim.new(1, 0), Parent = fill })
make("UIGradient", { Color = ColorSequence.new(CYAN, PINK), Parent = fill })

gui.Parent = playerGui
ReplicatedFirst:RemoveDefaultLoadingScreen()

---------------------------------------------------------------------------------------------------------------------
-- Art + preload (background)
---------------------------------------------------------------------------------------------------------------------

local imagesTotal = 0
local imagesDone = 0
local preloadFinished = false

task.spawn(function()
	local ok, images = pcall(function(): any
		local sharedFolder = ReplicatedStorage:WaitForChild("Shared", ASSETS_WAIT)
		local config = sharedFolder and sharedFolder:WaitForChild("Config", ASSETS_WAIT)
		local module = config and config:WaitForChild("Assets", ASSETS_WAIT)
		if not (module and module:IsA("ModuleScript")) then
			return nil
		end
		local Assets: any = require(module :: any)
		return if type(Assets) == "table" and type(Assets.Images) == "table" then Assets.Images else nil
	end)
	if not ok or type(images) ~= "table" then
		preloadFinished = true
		return
	end
	local list: { string } = {}
	local function add(content: any)
		if typeof(content) == "string" and content ~= "" and not table.find(list, content) then
			table.insert(list, content)
		end
	end
	if typeof(images.loading_art) == "string" then
		art.Image = images.loading_art
	end
	if typeof(images.logo_hotwire_city) == "string" then
		logo.Image = images.logo_hotwire_city
	end
	-- on-screen art first, then the billboard ads every street shows
	add(images.loading_art)
	add(images.logo_hotwire_city)
	local ads: { string } = {}
	for key, content in images do
		if typeof(key) == "string" and string.sub(key, 1, 3) == "ad_" and typeof(content) == "string" then
			table.insert(ads, content)
		end
	end
	table.sort(ads)
	for _, content in ads do
		add(content)
	end
	imagesTotal = #list
	pcall(function()
		ContentProvider:PreloadAsync(list :: { any }, function()
			imagesDone = math.min(imagesTotal, imagesDone + 1)
		end)
	end)
	imagesDone = imagesTotal
	preloadFinished = true
end)

---------------------------------------------------------------------------------------------------------------------
-- Tips
---------------------------------------------------------------------------------------------------------------------

local finished = false

task.spawn(function()
	local index = 1
	while not finished do
		task.wait(TIP_SECONDS)
		if finished then
			break
		end
		index = index % #TIPS + 1
		local out = TweenService:Create(tip, TweenInfo.new(0.18), { TextTransparency = 1 })
		out:Play()
		out.Completed:Wait()
		if finished then
			break
		end
		tip.Text = "💡 " .. TIPS[index]
		TweenService:Create(tip, TweenInfo.new(0.18), { TextTransparency = 0 }):Play()
	end
end)

---------------------------------------------------------------------------------------------------------------------
-- Progress + exit
---------------------------------------------------------------------------------------------------------------------

local function assetsReady(): boolean
	local library = ReplicatedStorage:FindFirstChild("AssetLibrary")
	return library ~= nil and library:GetAttribute("AllReady") == true
end

-- 0..1: 5% base, images 35%, game loaded 30%, asset library 30% (time-credited while it streams so the bar keeps
-- moving; the last 3% only lands when AllReady does or the ready rule fires).
local function targetProgress(elapsed: number): number
	local p = 0.05
	if imagesTotal > 0 then
		p += 0.35 * (imagesDone / imagesTotal)
	elseif preloadFinished then
		p += 0.35
	end
	if game:IsLoaded() then
		p += 0.3
	end
	if assetsReady() then
		p += 0.3
	else
		p += 0.27 * math.clamp(elapsed / READY_TIMEOUT, 0, 1)
	end
	return math.clamp(p, 0, 1)
end

local shown = 0
local artShown = false
local logoShown = false
local leaving = false

local function fadeAll()
	local info = TweenInfo.new(FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local function fade(inst: Instance, props: { [string]: any })
		TweenService:Create(inst, info, props):Play()
	end
	for _, inst in gui:GetDescendants() do
		if inst:IsA("GuiObject") then
			fade(inst, { BackgroundTransparency = 1 })
		end
		if inst:IsA("ImageLabel") then
			fade(inst, { ImageTransparency = 1 })
		elseif inst:IsA("TextLabel") then
			fade(inst, { TextTransparency = 1 })
		elseif inst:IsA("UIStroke") then
			fade(inst, { Transparency = 1 })
		end
	end
	TweenService:Create(logoBox, info, { Position = UDim2.fromScale(0.5, 0.3) }):Play()
end

local connection: RBXScriptConnection? = nil
connection = RunService.RenderStepped:Connect(function(dt: number)
	if leaving then
		return
	end
	local elapsed = os.clock() - startedAt

	-- art / logo fade in once their images are actually loaded
	if not artShown and art.Image ~= "" and art.IsLoaded then
		artShown = true
		TweenService:Create(art, TweenInfo.new(0.5), { ImageTransparency = 0 }):Play()
	end
	if not logoShown and logo.Image ~= "" and logo.IsLoaded then
		logoShown = true
		wordmark.Visible = false
		TweenService:Create(logo, TweenInfo.new(0.35), { ImageTransparency = 0 }):Play()
	end

	local ready = elapsed >= MIN_SHOWN and game:IsLoaded() and (assetsReady() or elapsed >= READY_TIMEOUT)
	local target = if ready then 1 else targetProgress(elapsed)
	shown = math.max(shown, shown + (target - shown) * math.min(1, dt * (if ready then 10 else 3)))
	fill.Size = UDim2.fromScale(math.max(0.04, shown), 1)
	status.Text = string.format("LOADING  %d%%", math.floor(shown * 100 + 0.5))

	if (ready and shown >= 0.985) or elapsed >= HARD_TIMEOUT then
		leaving = true
		finished = true
		status.Text = "LET'S RIDE!"
		fill.Size = UDim2.fromScale(1, 1)
		task.delay(0.2, function()
			fadeAll()
			task.delay(FADE_SECONDS + 0.05, function()
				if connection then
					connection:Disconnect()
				end
				gui:Destroy()
			end)
		end)
	end
end)
