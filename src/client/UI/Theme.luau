--!strict
-- Visual language for every screen: bold cartoon-heist look (deep navy panels, hot pink + cyan accents,
-- chunky rounded type). Change colors/fonts here, never inline in controllers.

local Theme = {}

Theme.Colors = {
	Background = Color3.fromRGB(18, 20, 38),
	Panel = Color3.fromRGB(28, 31, 58),
	PanelLight = Color3.fromRGB(42, 46, 84),
	Stroke = Color3.fromRGB(10, 11, 22),
	Text = Color3.fromRGB(255, 255, 255),
	TextDim = Color3.fromRGB(170, 176, 214),
	Primary = Color3.fromRGB(255, 52, 140), -- hot pink
	Secondary = Color3.fromRGB(0, 214, 255), -- cyan
	Cash = Color3.fromRGB(70, 235, 110),
	CashDark = Color3.fromRGB(25, 140, 60),
	Warning = Color3.fromRGB(255, 190, 40),
	Danger = Color3.fromRGB(255, 70, 70),
	Police = Color3.fromRGB(40, 110, 255),
	Gold = Color3.fromRGB(255, 205, 50),
	Disabled = Color3.fromRGB(90, 92, 110),
}

Theme.Fonts = {
	Display = Font.fromEnum(Enum.Font.FredokaOne), -- titles, numbers, banners
	Body = Font.fromEnum(Enum.Font.GothamBold),
	BodyHeavy = Font.fromEnum(Enum.Font.GothamBlack),
}

Theme.Corner = UDim.new(0, 14)
Theme.CornerSmall = UDim.new(0, 8)
Theme.StrokeThickness = 3
Theme.TweenFast = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
Theme.TweenMedium = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
Theme.TweenPop = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- ZIndex/DisplayOrder layers (ScreenGui.DisplayOrder)
Theme.Layers = {
	World = 0, -- billboards are not ScreenGuis, listed for reference
	HUD = 10,
	Menus = 20,
	Banners = 30,
	Toasts = 40,
	Overlay = 50, -- busted screen, fades
}

return Theme
