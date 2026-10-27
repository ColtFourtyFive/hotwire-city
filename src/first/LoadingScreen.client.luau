--!strict
-- LoadingScreen (AP4; v2 GTA presentation, gta_ui_language §5.16): the only LocalScript in ReplicatedFirst, so it runs
-- before the rest of the game replicates.
--
--  * Replaces Roblox's default loading screen on the first frame with plain black + the HOTWIRE City text wordmark
--    (Kanit Black + Damion; no images needed), then, once ReplicatedStorage.Shared.Config.UIAssets replicates,
--    crossfades the full-bleed key art panels (UIAssets.LOADING, a slow Ken Burns push on each) and swaps in the
--    wordmark image. Older builds without UIAssets fall back to Assets.Images.loading_art / logo_hotwire_city.
--  * GTA layout: wordmark bottom-left, one tip line under it ("TIP" in Oswald orange + Montserrat text), a spinner
--    with "LOADING 54%" bottom-right, and a thin 2 px orange progress rule along the bottom edge.
--  * Progress: ContentProvider:PreloadAsync of the key art, the HUD sprite sheets and the display fonts (Kanit,
--    Damion, Oswald, Montserrat), blended with game:IsLoaded() and the server AssetLibrary's AllReady attribute,
--    eased so it never jumps or sits still. Fades out once game:IsLoaded() and (AllReady or READY_TIMEOUT);
--    HARD_TIMEOUT is a last resort so nobody is ever stuck here.
--  * Mobile-safe: IgnoreGuiInset + no screen insets so the art is full-bleed; text and spinner keep a safe margin
--    and scale with the viewport (UIScale = min(w / 1280, h / 720) clamped like Kit.screen).
-- The ScreenGui is named "HC_Loading": TutorialController waits for it to disappear before step 1.

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local READY_TIMEOUT = 12 -- seconds: stop waiting for AllReady (hero meshes keep streaming in behind the game)
local HARD_TIMEOUT = 25 -- seconds: leave even if game:IsLoaded() somehow never turns true
local MIN_SHOWN = 1.5 -- never just flash
local TIP_SECONDS = 5
local PANEL_SECONDS = 6 -- each key art panel holds this long (crossfade included)
local CROSSFADE = 1.2
local KEN_BURNS = 1.08 -- each panel slowly pushes in to this scale
local FADE_SECONDS = 0.6
local ASSETS_WAIT = 20 -- seconds to wait for Shared/Config to replicate
local SAFE = 32 -- design px margin for text and the spinner

local TIPS = {
	"Hold E to hotwire a parked car, then drive it home.",
	"Drive a stolen car into your garage drop-off to keep it. Every stored car earns cash.",
	"Lock your garage with the laser gate so other players cannot take your cars.",
	"Hot Drops put rare cars somewhere in the city. Follow the gold marker before anyone else.",
	"Spray Shops clear your wanted level for a fee.",
	"Open the phone to call a cab home, take jobs and claim daily rewards.",
	"Prestige keeps your best cars and raises your income for good.",
}
if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
	TIPS[1] = "Hold the HOTWIRE prompt next to a parked car, then drive it home."
end

-- Palette + fonts mirror client/UI/Theme (that module has not replicated yet when this runs).
local BLACK = Color3.fromRGB(0, 0, 0)
local TEXT = Color3.fromRGB(240, 240, 240)
local DIM = Color3.fromRGB(155, 155, 155)
local ACCENT = Color3.fromRGB(255, 138, 61) -- Ignition Orange
local KANIT = 12187373592
local DAMION = 12187607722
local FONT_DISPLAY = Font.fromId(KANIT, Enum.FontWeight.Heavy)
local FONT_SCRIPT = Font.fromId(DAMION)
local FONT_CONDENSED = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.SemiBold)
local FONT_BODY = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Medium)

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
	BackgroundColor3 = BLACK,
	BorderSizePixel = 0,
	ClipsDescendants = true,
	Size = UDim2.fromScale(1, 1),
	Parent = gui,
})

-- two key-art layers that take turns (A shows, B fades in over it, swap)
local function panel(name: string, z: number): ImageLabel
	return make("ImageLabel", {
		Name = name,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		ScaleType = Enum.ScaleType.Crop,
		ImageTransparency = 1,
		ZIndex = z,
		Parent = root,
	})
end
local art = panel("Art", 1)
local artNext = panel("ArtNext", 2)

-- bottom shade so the wordmark, tip and spinner read on any art
local shade = make("Frame", {
	Name = "Shade",
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.fromScale(0, 1),
	Size = UDim2.fromScale(1, 0.45),
	BackgroundColor3 = BLACK,
	BorderSizePixel = 0,
	ZIndex = 3,
	Parent = root,
})
make("UIGradient", {
	Rotation = 90,
	Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0.2),
	}),
	Parent = shade,
})

-- design-px overlay (1280 x 720 reference), scaled like Kit.screen so text stays readable on phones
local overlay = make("Frame", {
	Name = "Overlay",
	BackgroundTransparency = 1,
	Size = UDim2.fromScale(1, 1),
	ZIndex = 4,
	Parent = root,
})
local overlayScale = make("UIScale", { Parent = overlay })
local function rescale()
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local s = math.clamp(math.min(vp.X / 1280, vp.Y / 720), 0.72, 1.6)
	overlayScale.Scale = s
	overlay.Size = UDim2.fromOffset(vp.X / s, vp.Y / s)
end
rescale()

-- wordmark: image once UIAssets arrives; until then the same lock-up in text
local markBox = make("Frame", {
	Name = "Wordmark",
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, SAFE, 1, -SAFE - 34),
	Size = UDim2.fromOffset(360, 90),
	ZIndex = 5,
	Parent = overlay,
})
local markText = make("TextLabel", {
	Name = "Hotwire",
	BackgroundTransparency = 1,
	Size = UDim2.fromScale(0.78, 0.7),
	Text = "HOTWIRE",
	FontFace = FONT_DISPLAY,
	TextColor3 = TEXT,
	TextScaled = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	ZIndex = 5,
	Parent = markBox,
})
make("UIStroke", { Color = BLACK, Thickness = 2, Parent = markText })
local markScript = make("TextLabel", {
	Name = "City",
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.fromScale(0.92, 1),
	Size = UDim2.fromScale(0.42, 0.55),
	Text = "City",
	FontFace = FONT_SCRIPT,
	TextColor3 = ACCENT,
	TextScaled = true,
	Rotation = -6,
	ZIndex = 6,
	Parent = markBox,
})
local logo = make("ImageLabel", {
	Name = "Logo",
	BackgroundTransparency = 1,
	Size = UDim2.fromScale(1, 1),
	ScaleType = Enum.ScaleType.Fit,
	ImageTransparency = 1,
	ZIndex = 7,
	Parent = markBox,
})

-- tip line: "TIP" in Oswald orange, the text in Montserrat
local tipRow = make("Frame", {
	Name = "TipRow",
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, SAFE, 1, -SAFE),
	Size = UDim2.new(0.62, 0, 0, 22),
	ZIndex = 5,
	Parent = overlay,
})
make("TextLabel", {
	Name = "Label",
	BackgroundTransparency = 1,
	Size = UDim2.new(0, 34, 1, 0),
	Text = "TIP",
	FontFace = FONT_CONDENSED,
	TextSize = 17,
	TextColor3 = ACCENT,
	TextXAlignment = Enum.TextXAlignment.Left,
	ZIndex = 5,
	Parent = tipRow,
})
local tip = make("TextLabel", {
	Name = "Tip",
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(38, 0),
	Size = UDim2.new(1, -38, 1, 0),
	Text = TIPS[1],
	FontFace = FONT_BODY,
	TextSize = 16,
	TextColor3 = TEXT,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextTruncate = Enum.TextTruncate.AtEnd,
	ZIndex = 5,
	Parent = tipRow,
})

-- spinner + status bottom-right
local spinner = make("ImageLabel", {
	Name = "Spinner",
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -SAFE, 1, -SAFE + 2),
	Size = UDim2.fromOffset(26, 26),
	ImageColor3 = TEXT,
	ImageTransparency = 1,
	ZIndex = 5,
	Parent = overlay,
})
local status = make("TextLabel", {
	Name = "Status",
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -SAFE - 36, 1, -SAFE),
	Size = UDim2.fromOffset(220, 22),
	Text = "LOADING",
	FontFace = FONT_CONDENSED,
	TextSize = 17,
	TextColor3 = DIM,
	TextXAlignment = Enum.TextXAlignment.Right,
	ZIndex = 5,
	Parent = overlay,
})

-- thin progress rule along the very bottom edge (full-bleed, real pixels)
local track = make("Frame", {
	Name = "Track",
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.fromScale(0, 1),
	Size = UDim2.new(1, 0, 0, 2),
	BackgroundColor3 = BLACK,
	BackgroundTransparency = 0.5,
	BorderSizePixel = 0,
	ZIndex = 6,
	Parent = root,
})
local fill = make("Frame", {
	Name = "Fill",
	Size = UDim2.fromScale(0.02, 1),
	BackgroundColor3 = ACCENT,
	BorderSizePixel = 0,
	ZIndex = 6,
	Parent = track,
})

gui.Parent = playerGui
ReplicatedFirst:RemoveDefaultLoadingScreen()

---------------------------------------------------------------------------------------------------------------------
-- Art + preload (background)
---------------------------------------------------------------------------------------------------------------------

local imagesTotal = 0
local imagesDone = 0
local preloadFinished = false
local panels: { string } = {} -- key art, in order

local function configModule(name: string): any
	local ok, mod = pcall(function(): any
		local sharedFolder = ReplicatedStorage:WaitForChild("Shared", ASSETS_WAIT)
		local config = sharedFolder and sharedFolder:WaitForChild("Config", ASSETS_WAIT)
		local module = config and config:WaitForChild(name, 5)
		if not (module and module:IsA("ModuleScript")) then
			return nil
		end
		return require(module :: any)
	end)
	return if ok and type(mod) == "table" then mod else nil
end

task.spawn(function()
	local list: { any } = {}
	local function add(content: any)
		if typeof(content) == "string" and content ~= "" and not table.find(list, content) then
			table.insert(list, content)
		end
	end

	local UIAssets = configModule("UIAssets")
	local images = if UIAssets and type(UIAssets.Images) == "table" then UIAssets.Images else nil
	if images and type(UIAssets.LOADING) == "table" then
		for _, key in UIAssets.LOADING do
			local id = images[key]
			if typeof(id) == "string" and id ~= "" then
				table.insert(panels, id)
			end
		end
		if typeof(images.wordmark) == "string" then
			logo.Image = images.wordmark
		end
		local sheets = UIAssets.Sheets
		if type(sheets) == "table" and type(sheets.hud) == "table" then
			spinner.Image = sheets.hud.image
			local cell = type(sheets.hud.cells) == "table" and sheets.hud.cells.spinner
			if type(cell) == "table" then
				spinner.ImageRectOffset = Vector2.new(cell[1], cell[2])
				spinner.ImageRectSize = Vector2.new(cell[3], cell[4])
			end
		end
	end
	-- older builds: the v1 Assets.Images loading_art + logo_hotwire_city
	if #panels == 0 then
		local Assets = configModule("Assets")
		local v1 = if Assets and type(Assets.Images) == "table" then Assets.Images else nil
		if v1 then
			if typeof(v1.loading_art) == "string" then
				table.insert(panels, v1.loading_art)
			end
			if logo.Image == "" and typeof(v1.logo_hotwire_city) == "string" then
				logo.Image = v1.logo_hotwire_city
			end
		end
	end
	if panels[1] then
		art.Image = panels[1]
	end
	if panels[2] then
		artNext.Image = panels[2]
	end

	-- on-screen art first, then the rest of the panels, the HUD sheets and the display fonts
	for _, id in panels do
		add(id)
	end
	add(logo.Image)
	if UIAssets and type(UIAssets.Sheets) == "table" then
		for _, sheet in UIAssets.Sheets do
			if type(sheet) == "table" then
				add(sheet.image)
			end
		end
	end
	for _, face in { FONT_DISPLAY, FONT_SCRIPT, FONT_CONDENSED, FONT_BODY } do
		-- PreloadAsync loads a TextLabel's font face
		table.insert(list, make("TextLabel", { FontFace = face, Text = "Aa" }))
	end
	imagesTotal = #list
	pcall(function()
		ContentProvider:PreloadAsync(list, function()
			imagesDone = math.min(imagesTotal, imagesDone + 1)
		end)
	end)
	imagesDone = imagesTotal
	preloadFinished = true
end)

---------------------------------------------------------------------------------------------------------------------
-- Key art crossfade + tips
---------------------------------------------------------------------------------------------------------------------

local finished = false

-- slow push-in on whichever panel is showing
local function kenBurns(img: ImageLabel, seconds: number)
	img.Size = UDim2.fromScale(1, 1)
	img.Position = UDim2.fromScale(0.5, 0.5)
	local drift = if math.random() < 0.5 then -0.015 else 0.015
	TweenService:Create(img, TweenInfo.new(seconds, Enum.EasingStyle.Linear), {
		Size = UDim2.fromScale(KEN_BURNS, KEN_BURNS),
		Position = UDim2.fromScale(0.5 + drift, 0.5),
	}):Play()
end

task.spawn(function()
	-- first panel: fade in once loaded
	local waited = 0
	while not finished and not (art.Image ~= "" and art.IsLoaded) and waited < HARD_TIMEOUT do
		waited += task.wait(0.1)
	end
	if finished then
		return
	end
	kenBurns(art, PANEL_SECONDS + CROSSFADE)
	TweenService:Create(art, TweenInfo.new(0.6), { ImageTransparency = 0 }):Play()
	local index = 1
	while not finished do
		task.wait(PANEL_SECONDS - CROSSFADE)
		if finished or #panels < 2 then
			break
		end
		index = index % #panels + 1
		artNext.Image = panels[index]
		kenBurns(artNext, PANEL_SECONDS + CROSSFADE)
		local inTween = TweenService:Create(artNext, TweenInfo.new(CROSSFADE), { ImageTransparency = 0 })
		inTween:Play()
		inTween.Completed:Wait()
		if finished then
			break
		end
		-- swap roles: the front panel becomes the back one
		art.Image = artNext.Image
		art.Size = artNext.Size
		art.Position = artNext.Position
		art.ImageTransparency = 0
		kenBurns(art, PANEL_SECONDS)
		artNext.ImageTransparency = 1
	end
end)

task.spawn(function()
	local index = 1
	while not finished do
		task.wait(TIP_SECONDS)
		if finished then
			break
		end
		index = index % #TIPS + 1
		local out = TweenService:Create(tip, TweenInfo.new(0.2), { TextTransparency = 1 })
		out:Play()
		out.Completed:Wait()
		if finished then
			break
		end
		tip.Text = TIPS[index]
		TweenService:Create(tip, TweenInfo.new(0.2), { TextTransparency = 0 }):Play()
	end
end)

---------------------------------------------------------------------------------------------------------------------
-- Progress + exit
---------------------------------------------------------------------------------------------------------------------

local function assetsReady(): boolean
	local library = ReplicatedStorage:FindFirstChild("AssetLibrary")
	return library ~= nil and library:GetAttribute("AllReady") == true
end

-- 0..1: 5% base, images + fonts 35%, game loaded 30%, asset library 30% (time-credited while it streams so the bar
-- keeps moving; the last 3% only lands when AllReady does or the ready rule fires).
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
local logoShown = false
local spinnerShown = false
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
end

local connection: RBXScriptConnection? = nil
connection = RunService.RenderStepped:Connect(function(dt: number)
	if leaving then
		return
	end
	local elapsed = os.clock() - startedAt
	rescale()

	-- wordmark image / spinner fade in once their images are actually loaded
	if not logoShown and logo.Image ~= "" and logo.IsLoaded then
		logoShown = true
		markText.Visible = false
		markScript.Visible = false
		TweenService:Create(logo, TweenInfo.new(0.35), { ImageTransparency = 0 }):Play()
	end
	if not spinnerShown and spinner.Image ~= "" and spinner.IsLoaded then
		spinnerShown = true
		spinner.ImageTransparency = 0
	end
	spinner.Rotation = (spinner.Rotation + dt * 300) % 360

	local ready = elapsed >= MIN_SHOWN and game:IsLoaded() and (assetsReady() or elapsed >= READY_TIMEOUT)
	local target = if ready then 1 else targetProgress(elapsed)
	shown = math.max(shown, shown + (target - shown) * math.min(1, dt * (if ready then 10 else 3)))
	fill.Size = UDim2.fromScale(math.max(0.02, shown), 1)
	status.Text = string.format("LOADING  %d%%", math.floor(shown * 100 + 0.5))

	if (ready and shown >= 0.985) or elapsed >= HARD_TIMEOUT then
		leaving = true
		finished = true
		status.Text = "LOADING  100%"
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
