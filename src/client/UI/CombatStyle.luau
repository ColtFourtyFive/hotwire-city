--!strict
-- CombatStyle: the GTA presentation tokens the combat UI uses (gta_ui_language §3 palette, §4 typography, §5.0
-- layers), by their EXACT Theme v2 names.
-- TODO(integrate): use Theme v2 - when B2's Theme.luau v2 lands (detected by Theme.Colors.WastedRed), every token
-- below resolves to Theme.Colors / Theme.Fonts / Theme.Layers; until then the local fallback values apply.
-- Never pink, never cyan, never the rounded cartoon display font (kill list).

local Theme = require(script.Parent.Theme)

local CombatStyle = {}

local themeV2 = typeof((Theme :: any).Colors) == "table" and (Theme :: any).Colors.WastedRed ~= nil

local function hex(h: string): Color3
	return Color3.fromHex(h)
end

-- §3 palette (fallback values). Transparency notes: Panel 0.27, PanelLight 0.70, PauseTint 0.16.
local FALLBACK_COLORS: { [string]: Color3 } = {
	Text = hex("#F0F0F0"),
	TextPure = hex("#FFFFFF"),
	TextDim = hex("#9B9B9B"),
	TextMuted = hex("#8C8C8C"),
	TextDisabled = hex("#4D4D4D"),
	Outline = hex("#000000"),
	Panel = hex("#000000"),
	PanelLight = hex("#000000"),
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
	Gold = hex("#D6B563"),
	WastedRed = hex("#B3212F"),
	Accent = hex("#FF8A3D"),
	AccentDark = hex("#7A3A12"),
}

CombatStyle.Transparency = {
	Panel = 0.27,
	PanelLight = 0.70,
	PauseTint = 0.16,
	Row = 0.35,
	Card = 0.35,
}

CombatStyle.Colors = {} :: { [string]: Color3 }
for name, fallback in FALLBACK_COLORS do
	local v = if themeV2 then (Theme :: any).Colors[name] else nil
	CombatStyle.Colors[name] = if typeof(v) == "Color3" then v else fallback
end

-- §4 typography. Store fonts (Kanit, Damion) are Roblox-owned Creator Store families; Oswald / Montserrat are
-- built in. pcall: the Lune harness and old clients may not know Font.fromId.
local function fontFromId(id: number, weight: Enum.FontWeight?): Font?
	local ok, f = pcall(function()
		return if weight then Font.fromId(id, weight) else Font.fromId(id)
	end)
	return if ok then f else nil
end

local function family(path: string, weight: Enum.FontWeight): Font?
	local ok, f = pcall(Font.new, path, weight)
	return if ok then f else nil
end

local SARPANCH = family("rbxasset://fonts/families/Sarpanch.json", Enum.FontWeight.Heavy)
local FALLBACK_FONTS: { [string]: Font? } = {
	Display = fontFromId(12187373592, Enum.FontWeight.Heavy) or SARPANCH, -- Kanit Black (big messages)
	Numeric = fontFromId(12187373592, Enum.FontWeight.Heavy) or SARPANCH, -- cash / ammo digits
	Condensed = family("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.SemiBold),
	CondensedMedium = family("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Medium),
	Body = family("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Medium),
	BodyRegular = family("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Regular),
	Script = fontFromId(12187607722),
	DisplayFallback = SARPANCH,
}

CombatStyle.Fonts = {} :: { [string]: Font }
for name, fallback in FALLBACK_FONTS do
	local v = if themeV2 then (Theme :: any).Fonts and (Theme :: any).Fonts[name] else nil
	local chosen = if typeof(v) == "Font" then v else fallback
	if chosen then
		CombatStyle.Fonts[name] = chosen
	end
end

-- §5.0 DisplayOrder layers.
local FALLBACK_LAYERS: { [string]: number } = {
	HUD = 10,
	Feed = 11,
	Phone = 25,
	Wheel = 35,
	Pause = 45,
	Shard = 50,
	Fade = 60,
}
CombatStyle.Layers = {} :: { [string]: number }
for name, fallback in FALLBACK_LAYERS do
	local v = if themeV2 then (Theme :: any).Layers and (Theme :: any).Layers[name] else nil
	CombatStyle.Layers[name] = if typeof(v) == "number" then v else fallback
end

CombatStyle.SAFE = 20 -- design-px safe margin (§5.0)
CombatStyle.TweenFade = TweenInfo.new(0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
CombatStyle.TweenSlide = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
CombatStyle.TweenQuick = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
CombatStyle.isThemeV2 = themeV2

-- Font for a role with a guaranteed result (falls back to a built-in enum font).
function CombatStyle.font(name: string): Font
	local f = CombatStyle.Fonts[name]
	if f then
		return f
	end
	return Font.fromEnum(Enum.Font.SourceSansBold)
end

return CombatStyle
