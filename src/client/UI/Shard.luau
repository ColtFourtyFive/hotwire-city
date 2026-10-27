--!strict
-- Shard: GTA "big message" shards (gta_ui_language §2.10, §5.9). Shared by every package: HUDController.shard(...)
-- forwards here, the combat package's DeathScreen calls it for WASTED, the arrest flow for BUSTED, deliveries and jobs
-- for "delivered" / "job complete", rare reveals for "legendary" etc.
--
--   Shard.show(kind, title?, subtitle?, opts?) -> token
--       kind     "wasted" | "busted" | "failed" | "passed" | "delivered" | "job" | "reveal" | a rarity id
--                ("legendary", "mythic", ...) | anything else (white title)
--       title    overrides the default lowercase word ("wasted", "busted", "mission passed", ...)
--       subtitle Montserrat line under the title (rich text; GTA colour tags via UI/RichText)
--       opts     { rows = { {label, value} }, total = {label, value}?, hold = seconds?, grade = boolean?,
--                  sound = boolean?, fadeOut = "fade" | "black" | nil, onDone = function? }
--                fadeOut = "black" drops the HC_Fade curtain when the shard ends; it lifts by itself on the next
--                LocalPlayer.CharacterAdded (and never stays down longer than Shard.MAX_BLACK_SECONDS). A respawn
--                that comes before the shard ends (short RespawnTime) ends a graded / black-out shard right away:
--                no curtain over a live player, no grey grade after the respawn.
--   Shard.hide(fast?)            fades the current shard out (also removes the grade)
--   Shard.isShowing(): boolean
--   Shard.setGrade(on, seconds?) the death / arrest grade: ColorCorrection Saturation -1 / Contrast 0.3 /
--                                Brightness -0.05, a light blur, the vignette and a muffled world mix (local only:
--                                effects live under workspace.CurrentCamera, the EQ on the HC_SFX / HC_Music groups)
--   Shard.fadeBlack(on, seconds?) the HC_Fade black curtain (respawn cut); a curtain that is not lifted by the caller
--                                lifts itself after Shard.MAX_BLACK_SECONDS
--   Shard.style(kind)            pure: { title, color, alpha, grade, hold, sound } (unit-tested)
--   Shard.textMetrics(vpX, vpY)  pure: the title's UIScale (its text is laid out on the 1280x720 design canvas,
--                                where Roblox's 100 px text cap is ~14% H) and the subtitle's max text size
--
-- Look: a full-width translucent black band with GTA's slight keystone (15.5% of the screen height at the left edge,
-- 23% at the right; the keystone sprite from Config/UIAssets, a plain 19.5% band without it) centred at 48.8% H;
-- the title in lowercase Kanit Black, no outline; no stamps, shakes, confetti or Back easing.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Theme = require(script.Parent.Theme)
local Kit = require(script.Parent.Kit)
local RichText = require(script.Parent.RichText)
local UISound = require(script.Parent.UISound)

local Shard = {}

local C = Theme.Colors

export type Style = {
	title: string,
	color: Color3,
	alpha: number, -- band BackgroundTransparency / ImageTransparency
	grade: boolean, -- grayscale the world
	hold: number, -- seconds fully shown
	sound: string?, -- Config/UIAssets.Sounds key
}

local STYLES: { [string]: Style } = {
	wasted = { title = "wasted", color = C.WastedRed, alpha = 0.5, grade = true, hold = 4.3, sound = "wasted" },
	busted = { title = "busted", color = C.Blue, alpha = 0.5, grade = true, hold = 4.3, sound = "busted" },
	failed = { title = "failed", color = C.Red, alpha = 0.5, grade = false, hold = 3.5, sound = "busted" },
	passed = { title = "mission passed", color = C.Yellow, alpha = 0.45, grade = false, hold = 4, sound = "passed" },
	delivered = { title = "delivered", color = C.Yellow, alpha = 0.45, grade = false, hold = 3.5, sound = "passed" },
	job = { title = "job complete", color = C.Yellow, alpha = 0.45, grade = false, hold = 3.5, sound = "passed" },
	reveal = { title = "rare", color = C.Text, alpha = 0.45, grade = false, hold = 3, sound = "passed" },
}

-- Rarity reveals use the rarity hue (Theme.Rarity).
for rarity, color in Theme.Rarity do
	STYLES[string.lower(rarity)] = {
		title = string.lower(rarity),
		color = color,
		alpha = 0.45,
		grade = false,
		hold = 3,
		sound = "passed",
	}
end

function Shard.style(kind: any): Style
	local k = if typeof(kind) == "string" then string.lower(kind) else ""
	return STYLES[k] or { title = k, color = C.Text, alpha = 0.45, grade = false, hold = 3, sound = nil }
end

-- The title is laid out on the 1280x720 design canvas (TITLE_W x TITLE_H, TextScaled up to Roblox's 100 px cap,
-- ~14% of 720) and scaled to the screen by a UIScale; the subtitle's cap follows the screen height (18 design px).
local TITLE_W, TITLE_H = 794, 101
function Shard.textMetrics(vpX: number, vpY: number): (number, number)
	local x = if vpX == vpX and vpX >= 1 then vpX else 1280
	local y = if vpY == vpY and vpY >= 1 then vpY else 720
	local scale = math.min(y / 720, 0.9 * x / TITLE_W)
	return scale, math.max(12, math.floor(0.025 * y + 0.5))
end

-- Seconds before each extra row of a passed-style shard appears (0.15 s apart after the band is in).
function Shard.rowDelay(index: number): number
	return 0.6 + 0.15 * (math.max(1, index) - 1)
end

-------------------------------------------------------------------------------------------------------------------------
-- View
-------------------------------------------------------------------------------------------------------------------------

type Ui = {
	gui: ScreenGui,
	band: GuiObject,
	bandImage: boolean,
	title: TextLabel,
	titleScale: UIScale,
	subtitle: TextLabel,
	subtitleFit: UITextSizeConstraint,
	rows: Frame,
	vignette: ImageLabel,
	fadeGui: ScreenGui,
	curtain: Frame,
}

local ui: Ui? = nil
local token = 0
local showing = false
local baseScale = 1 -- the title's screen scale (textMetrics)
local gradeEffects: { Instance } = {}
local gradeOn = false

local function tween(inst: Instance, seconds: number, props: { [string]: any }, style: Enum.EasingStyle?): Tween
	local t = TweenService:Create(
		inst,
		TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		props
	)
	t:Play()
	return t
end

local function build(): Ui
	local gui = Kit.screen("HC_Shard", Theme.Layers.Shard, { insets = "none" })
	gui.Enabled = false
	local scale = gui:FindFirstChildOfClass("UIScale")
	if scale then
		scale:Destroy() -- the band and text are sized in screen fractions
	end
	local bandId = Kit.resolveImage("shard_band")
	local band: GuiObject
	if bandId then
		band = Kit.image("shard_band", {
			Name = "Band",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.488),
			Size = UDim2.fromScale(1, 0.23),
			ScaleType = Enum.ScaleType.Stretch,
			ImageColor3 = C.Black,
			ImageTransparency = 1,
			Parent = gui,
		})
	else
		band = Kit.new("Frame", {
			Name = "Band",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.488),
			Size = UDim2.fromScale(1, 0.195),
			BackgroundColor3 = C.Black,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = gui,
		})
	end
	local title = Kit.new("TextLabel", {
		Name = "Title",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.468),
		Size = UDim2.fromOffset(TITLE_W, TITLE_H),
		BackgroundTransparency = 1,
		Text = "",
		TextScaled = true,
		FontFace = Theme.Fonts.Display,
		TextColor3 = C.Text,
		TextTransparency = 1,
		ZIndex = 3,
		Parent = gui,
	})
	Kit.new("UITextSizeConstraint", { MaxTextSize = 100, MinTextSize = 24, Parent = title })
	local titleScale = Kit.new("UIScale", { Parent = title })
	local subtitle = Kit.new("TextLabel", {
		Name = "Subtitle",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.538),
		Size = UDim2.fromScale(0.8, 0.034),
		BackgroundTransparency = 1,
		Text = "",
		TextScaled = true,
		RichText = true,
		FontFace = Theme.Fonts.Body,
		TextColor3 = C.Text,
		TextTransparency = 1,
		ZIndex = 3,
		Parent = gui,
	})
	local subtitleFit = Kit.new("UITextSizeConstraint", { MaxTextSize = 22, MinTextSize = 12, Parent = subtitle })
	local rows = Kit.new("Frame", {
		Name = "Rows",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.61),
		Size = UDim2.fromScale(0.36, 0.3),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = gui,
	}, { Kit.list(Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Center) })
	Kit.new("UISizeConstraint", { MinSize = Vector2.new(320, 0), MaxSize = Vector2.new(520, 400), Parent = rows })
	local vignette = Kit.image("vignette", {
		Name = "Vignette",
		Size = UDim2.fromScale(1, 1),
		ScaleType = Enum.ScaleType.Stretch,
		ImageTransparency = 1,
		ZIndex = 1,
		Parent = gui,
	})
	local fadeGui = Kit.screen("HC_Fade", Theme.Layers.Fade, { insets = "none" })
	fadeGui.Enabled = false
	local curtain = Kit.new("Frame", {
		Name = "Curtain",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.Black,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = fadeGui,
	})
	return {
		gui = gui,
		band = band,
		bandImage = bandId ~= nil,
		title = title,
		titleScale = titleScale,
		subtitle = subtitle,
		subtitleFit = subtitleFit,
		rows = rows,
		vignette = vignette,
		fadeGui = fadeGui,
		curtain = curtain,
	}
end

local function getUi(): Ui
	local u = ui
	if u and u.gui.Parent then
		return u
	end
	local built = build()
	ui = built
	return built
end

local function setBandAlpha(u: Ui, alpha: number, seconds: number)
	local prop = if u.bandImage then "ImageTransparency" else "BackgroundTransparency"
	if seconds <= 0 then
		(u.band :: any)[prop] = alpha
	else
		tween(u.band, seconds, { [prop] = alpha })
	end
end

-- Settings > Sound effects applies (UI/UISound).
local function playSound(key: string?)
	if key then
		UISound.play(key)
	end
end

-- Size the title (UIScale over the design-canvas layout) and the subtitle cap for the current screen.
local function fitText(u: Ui)
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local scale, subMax = Shard.textMetrics(vp.X, vp.Y)
	baseScale = scale
	u.titleScale.Scale = scale
	u.subtitleFit.MaxTextSize = subMax
end

local function row(parent: Instance, label: string, value: string, color: Color3, order: number): Frame
	local f = Kit.new("Frame", {
		Name = "Row",
		BackgroundColor3 = C.Black,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 30),
		LayoutOrder = order,
		Parent = parent,
	})
	Kit.padding(0, 12).Parent = f
	Kit.text(string.upper(label), "condensedMedium", 18, {
		Name = "Label",
		Size = UDim2.fromScale(0.6, 1),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.TextDim,
		TextTransparency = 1,
		Parent = f,
	})
	Kit.numeric(value, 22, {
		Name = "Value",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromScale(0.4, 1),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = color,
		TextTransparency = 1,
		Parent = f,
	})
	return f
end

-- Grade the world for wasted / busted (local only).
function Shard.setGrade(on: boolean, seconds: number?)
	local t = seconds or 0.6
	if on == gradeOn then
		return
	end
	gradeOn = on
	local u = getUi()
	if on then
		local cam = Workspace.CurrentCamera
		local parent: Instance = cam or Lighting
		local cc = Instance.new("ColorCorrectionEffect")
		cc.Name = "HC_DeathGrade"
		cc.Parent = parent
		local blur = Instance.new("BlurEffect")
		blur.Name = "HC_DeathBlur"
		blur.Size = 0
		blur.Parent = parent
		tween(cc, t, { Saturation = -1, Contrast = 0.3, Brightness = -0.05 }, Enum.EasingStyle.Sine)
		tween(blur, t, { Size = 3 }, Enum.EasingStyle.Sine)
		table.insert(gradeEffects, cc)
		table.insert(gradeEffects, blur)
		for _, name in { "HC_SFX", "HC_Music" } do
			local group = SoundService:FindFirstChild(name)
			if group and group:IsA("SoundGroup") then
				local eq = Instance.new("EqualizerSoundEffect")
				eq.Name = "HC_ShardMuffle"
				eq.HighGain = -25
				eq.MidGain = -10
				eq.LowGain = 0
				eq.Parent = group
				table.insert(gradeEffects, eq)
			end
		end
		u.gui.Enabled = true
		tween(u.vignette, t, { ImageTransparency = 0.15 })
	else
		local effects = gradeEffects
		gradeEffects = {}
		for _, e in effects do
			if e:IsA("ColorCorrectionEffect") then
				tween(e, t, { Saturation = 0, Contrast = 0, Brightness = 0 })
			elseif e:IsA("BlurEffect") then
				tween(e, t, { Size = 0 })
			end
		end
		tween(u.vignette, t, { ImageTransparency = 1 })
		task.delay(t + 0.05, function()
			for _, e in effects do
				e:Destroy()
			end
		end)
	end
end

-- The curtain never stays down longer than this: a caller that forgets fadeBlack(false) (or whose respawn never
-- comes) must not leave the player on a black screen.
Shard.MAX_BLACK_SECONDS = 8
local curtainToken = 0

-- Black curtain for respawn cuts (§5.9: HC_Fade 0.6 s). fadeBlack(true) lifts itself after MAX_BLACK_SECONDS.
function Shard.fadeBlack(on: boolean, seconds: number?)
	local u = getUi()
	local t = seconds or 0.6
	curtainToken += 1
	local my = curtainToken
	if on then
		u.fadeGui.Enabled = true
		tween(u.curtain, t, { BackgroundTransparency = 0 }, Enum.EasingStyle.Sine)
		task.delay(t + Shard.MAX_BLACK_SECONDS, function()
			if my == curtainToken then
				Shard.fadeBlack(false)
			end
		end)
	else
		local tw = tween(u.curtain, t, { BackgroundTransparency = 1 }, Enum.EasingStyle.Sine)
		tw.Completed:Once(function()
			if u.curtain.BackgroundTransparency >= 0.99 then
				u.fadeGui.Enabled = false
			end
		end)
	end
end

export type ShowOpts = {
	rows: { { any } }?,
	total: { any }?,
	hold: number?,
	grade: boolean?,
	sound: boolean?,
	fadeOut: string?,
	onDone: (() -> ())?,
}

function Shard.show(kind: string, title: string?, subtitle: string?, opts: ShowOpts?): number
	local o: ShowOpts = opts or {}
	local style = Shard.style(kind)
	local u = getUi()
	token += 1
	local my = token
	showing = true
	for _, child in u.rows:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	u.gui.Enabled = true
	fitText(u)
	u.title.Text = string.lower(Kit.sanitize(title or style.title))
	u.title.TextColor3 = style.color
	u.subtitle.Text = RichText.format(Kit.sanitize(subtitle or ""))
	-- band: grows from a line to its height
	local full = if u.bandImage then 0.23 else 0.195
	u.band.Size = UDim2.fromScale(1, 0)
	setBandAlpha(u, style.alpha, 0)
	tween(u.band, 0.25, { Size = UDim2.fromScale(1, full) })
	u.title.TextTransparency = 1
	u.subtitle.TextTransparency = 1
	u.titleScale.Scale = baseScale * 1.12
	task.delay(0.1, function()
		if token ~= my then
			return
		end
		tween(u.title, 0.35, { TextTransparency = 0 })
		tween(u.titleScale, 0.35, { Scale = baseScale })
		tween(u.subtitle, 0.35, { TextTransparency = 0 })
	end)
	local wantGrade = if o.grade ~= nil then o.grade else style.grade
	if wantGrade then
		Shard.setGrade(true)
	end
	if o.sound ~= false then
		playSound(style.sound)
	end
	-- result rows (passed / delivered): reveal 0.15 s apart, TOTAL in yellow last
	local rows: { { any } } = table.clone(o.rows or {})
	if o.total then
		table.insert(rows, { o.total[1], o.total[2], C.Yellow })
	end
	for i, r in rows do
		local f = row(u.rows, tostring(r[1]), tostring(r[2]), if typeof(r[3]) == "Color3" then r[3] else C.Text, i)
		task.delay(Shard.rowDelay(i), function()
			if token ~= my or not f.Parent then
				return
			end
			tween(f, 0.2, { BackgroundTransparency = 0.45 })
			for _, l in f:GetChildren() do
				if l:IsA("TextLabel") then
					tween(l, 0.2, { TextTransparency = 0 })
				end
			end
		end)
	end

	local done = false
	local function finish()
		if done then
			return
		end
		done = true
		if o.onDone then
			task.spawn(o.onDone)
		end
	end
	-- Death / arrest shards watch for the respawn from the start: with a short RespawnTime the character is back before
	-- the shard ends, and the player must not sit under a grey grade or a black curtain after that.
	local blackOut = o.fadeOut == "black"
	local respawned = false
	local curtainMine: number? = nil
	local lp = Players.LocalPlayer
	if (blackOut or wantGrade) and lp then
		lp.CharacterAdded:Once(function()
			respawned = true
			if token == my then
				Shard.hide(true)
				finish()
			elseif curtainMine ~= nil and curtainMine == curtainToken then
				task.delay(0.3, function()
					if curtainMine == curtainToken then
						Shard.fadeBlack(false)
					end
				end)
			end
		end)
	end

	local hold = (o.hold or style.hold) + (if #rows > 0 then Shard.rowDelay(#rows) else 0)
	task.delay(0.35 + hold, function()
		if token ~= my then
			return
		end
		if blackOut and not respawned then
			-- the respawn cut: the curtain lifts on the next spawn (or after MAX_BLACK_SECONDS, see fadeBlack)
			Shard.fadeBlack(true)
			curtainMine = curtainToken
		end
		Shard.hide()
		finish()
	end)
	return my
end

function Shard.hide(fast: boolean?)
	local u = ui
	if not u then
		return
	end
	token += 1
	local my = token
	showing = false
	local t = if fast then 0.15 else 0.45
	setBandAlpha(u, 1, t)
	tween(u.title, t, { TextTransparency = 1 })
	tween(u.subtitle, t, { TextTransparency = 1 })
	for _, f in u.rows:GetChildren() do
		if f:IsA("Frame") then
			Kit.fadeTree(f, 1, t)
		end
	end
	Shard.setGrade(false, t + 0.15)
	task.delay(t + 0.2, function()
		if token == my and not gradeOn then
			u.gui.Enabled = false
		end
	end)
end

function Shard.isShowing(): boolean
	return showing
end

-- The local player (for consumers that only have Shard).
Shard.player = Players.LocalPlayer

return Shard
