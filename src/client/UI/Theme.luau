--!strict
-- Visual language v2 (docs/v2/research/gta_ui_language.md §3-§5): GTA V's restrained HUD. Dark translucent panels
-- with no rounded corners or chrome, white text, colour only where it means something (red = enemy / wanted /
-- -cash, blue = friendly / armour / busted, yellow = destination / objective, green = pickup / +cash, purple = your
-- waypoint), one brand accent (Ignition Orange) used sparingly. Change colours / fonts here, never inline.
--
-- Fonts (§4): Kanit Black (Roblox Store family 12187373592) stands in for Pricedown (big messages, cash, ammo, timers),
-- Oswald for Chalet Comprime (titles, tabs, labels), Montserrat for Chalet London (help text, subtitles, feed, rows),
-- Damion (Store 12187607722) for SignPainter (vehicle / district / street names). No FredokaOne, no emoji anywhere.
--
-- The v1 colour names (Primary, Secondary, Cash, Danger, Police, Warning, Background, PanelLight, Stroke, ...) are kept
-- as aliases of the v2 tokens so every older consumer keeps compiling and picks up the new look.

local Theme = {}

local function hex(s: string): Color3
	return Color3.fromHex(s)
end

Theme.Colors = {
	-- v2 tokens (GTA V hudcolor.dat, §3)
	Text = hex("#F0F0F0"),
	TextPure = hex("#FFFFFF"),
	TextDim = hex("#9B9B9B"),
	TextMuted = hex("#8C8C8C"),
	TextDisabled = hex("#4D4D4D"),
	Outline = hex("#000000"),
	Black = hex("#000000"),
	MenuHighlight = hex("#1E1E1E"),
	MenuDark = hex("#3C3C3C"),
	Red = hex("#E03232"),
	RedDark = hex("#701919"),
	Damage = hex("#EB2427"),
	Blue = hex("#5DB6E5"),
	BlueDark = hex("#2F5C73"),
	Yellow = hex("#F0C850"),
	YellowDark = hex("#7E6B29"),
	Green = hex("#72CC72"),
	Health = hex("#359A47"),
	HealthTrack = hex("#1B4D24"),
	Waypoint = hex("#A44CF2"),
	WaypointLight = hex("#D2A6F9"),
	WaypointDark = hex("#522679"),
	Orange = hex("#FF8555"),
	Purple = hex("#8466E2"),
	Gold = hex("#D6B563"),
	Silver = hex("#9699A1"),
	Bronze = hex("#B48261"),
	Platinum = hex("#A6DDBE"),
	Freemode = hex("#2D6EB9"),
	FreemodeDark = hex("#16375C"),
	BlipDefault = hex("#9FC9A6"),
	WastedRed = hex("#B3212F"),
	Accent = hex("#FF8A3D"), -- Ignition Orange: the "character colour" (selected tab rule, phone header, focus)
	AccentDark = hex("#7A3A12"),

	-- v1 names -> v2 tokens (migration aliases; prefer the v2 names in new code)
	Background = hex("#141414"),
	Panel = hex("#000000"), -- with Theme.Alpha.Panel transparency
	PanelLight = hex("#1E1E1E"),
	Stroke = hex("#000000"),
	Primary = hex("#FF8A3D"), -- was hot pink
	Secondary = hex("#5DB6E5"), -- was cyan
	Cash = hex("#72CC72"),
	CashDark = hex("#1B4D24"),
	Warning = hex("#F0C850"),
	Danger = hex("#E03232"),
	Police = hex("#5DB6E5"),
	Disabled = hex("#4D4D4D"),
}

-- BackgroundTransparency for the GTA alpha tokens (1 - a/255).
Theme.Alpha = {
	Panel = 0.27, -- INGAME_BG rgba(0,0,0,186): help box, feed, rows, timer bars
	PanelLight = 0.70, -- PANEL_LIGHT rgba(0,0,0,77)
	PauseTint = 0.16, -- PAUSEMAP_TINT rgba(0,0,0,215)
	Row = 0.35, -- list-menu rows / tabs
	Band = 0.5, -- big-message band (wasted / busted / failed)
	BandPassed = 0.45,
}

-- §3 rarity hues (small labels and underlines, never glowing frames).
Theme.Rarity = {
	Common = hex("#9B9B9B"),
	Uncommon = hex("#72CC72"),
	Rare = hex("#5DB6E5"),
	Epic = hex("#8466E2"),
	Legendary = hex("#D6B563"),
	Mythic = hex("#E03232"),
	Secret = hex("#F0F0F0"),
	Exclusive = hex("#FF8A3D"),
}

local KANIT = 12187373592
local DAMION = 12187607722
Theme.FontIds = { Kanit = KANIT, Damion = DAMION }

local function family(name: string, weight: Enum.FontWeight): Font
	return Font.new("rbxasset://fonts/families/" .. name .. ".json", weight)
end

Theme.Fonts = {
	-- big messages, cash, ammo, timers, speed digits (Pricedown stand-in)
	Display = Font.fromId(KANIT, Enum.FontWeight.Heavy),
	Numeric = Font.fromId(KANIT, Enum.FontWeight.Heavy),
	-- titles, tabs, list headers, labels, phone header (Chalet Comprime stand-in)
	Condensed = family("Oswald", Enum.FontWeight.SemiBold),
	CondensedMedium = family("Oswald", Enum.FontWeight.Medium),
	CondensedRegular = family("Oswald", Enum.FontWeight.Regular),
	-- help text, subtitles, objectives, feed, menu rows, phone body (Chalet London stand-in)
	Body = family("Montserrat", Enum.FontWeight.Medium),
	BodyRegular = family("Montserrat", Enum.FontWeight.Regular),
	BodyBold = family("Montserrat", Enum.FontWeight.SemiBold),
	BodyHeavy = family("Montserrat", Enum.FontWeight.Bold), -- v1 name (was GothamBlack)
	-- vehicle / district / street names, signatures (SignPainter stand-in)
	Script = Font.fromId(DAMION),
	-- if a Store font is blocked: closest built-in heavy display face
	DisplayFallback = family("Sarpanch", Enum.FontWeight.Heavy),
	Mono = family("RobotoMono", Enum.FontWeight.Medium),
}

-- Every Store font face the loading screen preloads (no fallback flash).
Theme.PreloadFonts = { Theme.Fonts.Display, Theme.Fonts.Script }

-- No rounded corners in v2 (key caps and the phone selection tile are the only exceptions).
Theme.Corner = UDim.new(0, 0)
Theme.CornerSmall = UDim.new(0, 2)
Theme.CornerPhone = UDim.new(0, 6)
Theme.StrokeThickness = 0
Theme.TextStroke = 2 -- numeric (Kanit) outline

-- Motion (§5.0): fades and short slides only. No Back / Elastic easing, no wiggle, no scale-pop above 1.15.
Theme.TweenFast = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
Theme.TweenMedium = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
Theme.TweenFade = TweenInfo.new(0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
Theme.TweenSlide = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
-- v1 name kept for older consumers; it no longer overshoots.
Theme.TweenPop = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Kit.screen(..., { touchMin = Theme.TouchMinScale }): phones otherwise sit at the 0.55 UIScale floor, where 16 px design
-- text renders at ~9 real px. 0.72 keeps 16 px help text at ~11.5 real px (18 px objectives at ~13).
Theme.TouchMinScale = 0.72

-- Safe margin (design px on the 1280x720 canvas, inside CoreUISafeInsets): ~1.6% W / 2.8% H.
Theme.SAFE = 20

-- ScreenGui.DisplayOrder layers (§5.0). v1 names kept.
Theme.Layers = {
	World = 0, -- billboards are not ScreenGuis, listed for reference
	HUD = 10, -- HC_HUD: minimap, bars, stars, cash, ammo, help, objective, location, timers
	Feed = 11,
	HUDTop = 12, -- non-interactive guidance drawn over the driving / combat HUD
	Menus = 20, -- list menus (shops, garage, dealership)
	Phone = 25,
	Banners = 30,
	Wheel = 35,
	Toasts = 40,
	Pause = 45,
	Shard = 50,
	Overlay = 50, -- v1 name
	Fade = 60,
}

-- Rich-text keyword colours (§2.7, Rockstar's ~r~ ~b~ ~y~ ~g~ ~c~ codes) for UI/RichText tags.
Theme.TextCodes = {
	r = "#E03232", -- enemies, wanted
	b = "#5DB6E5", -- friendlies, your car
	y = "#F0C850", -- destinations
	g = "#72CC72", -- pickups, cash
	p = "#A44CF2", -- your waypoint
	o = "#FF8A3D", -- brand accent
	c = "#8C8C8C", -- off-screen speaker
	w = "#F0F0F0",
}

return Theme
