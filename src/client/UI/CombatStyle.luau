--!strict
-- CombatStyle: the GTA presentation tokens the combat UI uses (gta_ui_language §3 palette, §4 typography, §5.0
-- layers). Since the Wave B merge every token IS the Theme v2 token of the same name (Theme.Colors, Theme.Fonts,
-- Theme.Layers, Theme.Alpha); this module only adds the combat-only names (the wheel-card alpha, the quick tween)
-- and a font lookup that never returns nil. Change colours / fonts in Theme.luau, never here.
-- Never pink, never cyan, never the rounded cartoon display font (kill list).

local Theme = require(script.Parent.Theme)

local CombatStyle = {}

CombatStyle.Colors = Theme.Colors :: { [string]: Color3 }
CombatStyle.Fonts = Theme.Fonts :: { [string]: Font }
CombatStyle.Layers = Theme.Layers :: { [string]: number }

-- BackgroundTransparency tokens (Theme.Alpha) plus Card: the weapon-wheel slot card, drawn like a list row.
CombatStyle.Transparency = {
	Panel = Theme.Alpha.Panel,
	PanelLight = Theme.Alpha.PanelLight,
	PauseTint = Theme.Alpha.PauseTint,
	Row = Theme.Alpha.Row,
	Card = Theme.Alpha.Row,
}

CombatStyle.SAFE = Theme.SAFE -- design-px safe margin (§5.0)
CombatStyle.TweenFade = Theme.TweenFade
CombatStyle.TweenSlide = Theme.TweenSlide
CombatStyle.TweenQuick = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
CombatStyle.isThemeV2 = true

-- Font for a role with a guaranteed result (falls back to a built-in enum font).
function CombatStyle.font(name: string): Font
	local f = CombatStyle.Fonts[name]
	if f then
		return f
	end
	return Font.fromEnum(Enum.Font.SourceSansBold)
end

return CombatStyle
