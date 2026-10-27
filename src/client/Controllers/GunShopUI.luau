--!strict
-- GunShopUI (gta_combat §5.1, gta_ui_language §5.13): the FREEDOM ARMS counter as a GTA interaction list menu.
--
--  * Opened by the server (OpenUI "GunShop") at a gun-store counter; closes on Back at the top level, on leaving the
--    store zone (MapLayout gunstore box), on death / respawn or on entering a car.
--  * List menu, top-left at (SAFE, SAFE), 300 wide: header band (Accent + Damion title), MenuHighlight subheader
--    (TITLE ... 3/12), 28 px rows (selected = white bg / black text, prices right in Kanit), description box, key
--    hints. Touch (gta_ui_language §7): a full-width bottom sheet, SHEET_HEIGHT of the screen: the list on the left
--    half (subheader with a BACK button, 3-4 rows of 40 px), the preview (or the description) on the right half. The
--    thumbstick, stars, cash and weapon button stay clear.
--  * Menus: categories -> weapons (BUY / OWNED -> weapon page: magazine, fill ammo, tints), Ammunition, Body Armor,
--    Med Kit, Weapon Tints. Preview panel to the right: turntable model (ViewportFrame), Damage / Fire Rate /
--    Accuracy / Range / Clip bars and the price.
--  * Every purchase is a request; the server (ShopService) checks the zone, ownership, caps and cash.
--  * Input while open (ContextActionService, high priority): W/S, arrows, D-pad, mouse wheel move; Enter / A
--    select; Backspace / B back. Movement keys are sunk so the player stays at the counter.
-- Public: isOpen(), open(), close(); pure helpers _menu(menuId, ctx) and _ammoQuote(def, reserve, full).

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Weapons = require(Shared:WaitForChild("Config"):WaitForChild("Weapons"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local MapLayout = require(Shared:WaitForChild("Util"):WaitForChild("MapLayout"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))
local Style = require(UI:WaitForChild("CombatStyle"))
local WeaponPreview = require(UI:WaitForChild("WeaponPreview"))

local WeaponClient = require(script.Parent:WaitForChild("WeaponClient"))

local GunShopUI = {}

GunShopUI.WIDTH = 300
GunShopUI.ROW_H = 28
GunShopUI.ROW_H_TOUCH = 40
GunShopUI.MAX_ROWS = 10
GunShopUI.MAX_ROWS_TOUCH = 4
GunShopUI.SHEET_HEIGHT = 0.4 -- touch: the sheet's share of the screen height
GunShopUI.LAYER = 20
GunShopUI.STORE_NAME = "Freedom Arms"

local ACTION = "HC_GunShop"
local player = Players.LocalPlayer

export type Row = {
	label: string,
	value: string?,
	action: string, -- "open" | "buy" | "ammo" | "fullammo" | "armor" | "medkit" | "tint" | "none"
	arg: string?,
	arg2: string?,
	weapon: string?, -- preview this weapon
	locked: boolean?,
	description: string?,
}
export type Menu = { id: string, title: string, rows: { Row } }
export type Ctx = {
	cash: number,
	owned: { [string]: { mag: number, reserve: number, tint: string? } },
	tintsOwned: { [string]: boolean },
	armor: number,
	medkits: number,
}

-- PURE -------------------------------------------------------------------------------------------------------------------

local function money(n: number): string
	return "$" .. Format.commas(math.floor(n))
end

-- Rounds and price of an ammo purchase (mirrors ShopService._ammoQuote): one box, or enough boxes to fill the reserve.
function GunShopUI._ammoQuote(def: Weapons.WeaponDef, reserve: number, full: boolean): (number, number)
	if not Weapons.isGun(def) or not def.ammoPerPurchase or not def.ammoPrice then
		return 0, 0
	end
	local space = math.max(0, (def.reserveCap or 0) - reserve)
	if space <= 0 then
		return 0, 0
	end
	local per = def.ammoPerPurchase
	local boxes = if full then math.ceil(space / per) else 1
	return math.min(space, boxes * per), boxes * def.ammoPrice
end

local function titleCase(s: string): string
	return (string.lower(s):gsub("^%l", string.upper):gsub(" %l", string.upper))
end

-- The rows of a menu for the given player context.
function GunShopUI._menu(menuId: string, ctx: Ctx): Menu
	local rows: { Row } = {}
	if menuId == "root" then
		for _, class in Weapons.SHOP_CLASSES do
			table.insert(rows, {
				label = titleCase(Weapons.CLASS_LABEL[class] or class),
				action = "open",
				arg = "class:" .. class,
			})
		end
		table.insert(
			rows,
			{ label = "Ammunition", action = "open", arg = "ammo", description = "Magazines for the guns you own." }
		)
		table.insert(rows, {
			label = "Body Armor",
			action = "open",
			arg = "armor",
			description = "Plates are lost when you are wasted or busted.",
		})
		local mk = Weapons.MedKit
		local full = ctx.medkits >= mk.carry
		table.insert(rows, {
			label = mk.name,
			value = if full then "FULL" else money(mk.price),
			action = if full then "none" else "medkit",
			locked = full,
			description = mk.description .. (" You carry %d."):format(ctx.medkits),
		})
		table.insert(rows, {
			label = "Weapon Tints",
			action = "open",
			arg = "tints",
			description = "Cosmetic finishes. Bought once, any gun can wear them.",
		})
		return { id = menuId, title = "CATEGORIES", rows = rows }
	end
	local class = string.match(menuId, "^class:(.+)$")
	if class then
		for _, def in Weapons.shopList() do
			if def.class == class then
				local owned = ctx.owned[def.id] ~= nil
				local gun = Weapons.isGun(def)
				table.insert(rows, {
					label = def.name,
					value = if owned then "OWNED" else money(def.price),
					action = if owned then (if gun then "open" else "none") else "buy",
					arg = if owned then "weapon:" .. def.id else def.id,
					weapon = def.id,
					description = def.description,
				})
			end
		end
		return { id = menuId, title = Weapons.CLASS_LABEL[class] or string.upper(class), rows = rows }
	end
	local wid = string.match(menuId, "^weapon:(.+)$")
	if wid then
		local def = Weapons.get(wid)
		local a = ctx.owned[wid]
		if def and a then
			local rounds, price = GunShopUI._ammoQuote(def, a.reserve, false)
			local fullRounds, fullPrice = GunShopUI._ammoQuote(def, a.reserve, true)
			local reserveLine = ("In reserve: %d / %d."):format(a.reserve, def.reserveCap or 0)
			table.insert(rows, {
				label = "Magazine",
				value = if rounds > 0 then ("%s  x%d"):format(money(price), rounds) else "FULL",
				action = if rounds > 0 then "ammo" else "none",
				arg = wid,
				weapon = wid,
				locked = rounds <= 0,
				description = reserveLine,
			})
			table.insert(rows, {
				label = "Fill Ammo",
				value = if fullRounds > 0 then money(fullPrice) else "FULL",
				action = if fullRounds > 0 then "fullammo" else "none",
				arg = wid,
				weapon = wid,
				locked = fullRounds <= 0,
				description = reserveLine,
			})
			table.insert(rows, { label = "Tints", action = "open", arg = "tint:" .. wid, weapon = wid })
		end
		return { id = menuId, title = if def then string.upper(def.name) else "WEAPON", rows = rows }
	end
	if menuId == "ammo" then
		for _, def in Weapons.List do
			local a = ctx.owned[def.id]
			if a and Weapons.isGun(def) then
				local rounds, price = GunShopUI._ammoQuote(def, a.reserve, false)
				table.insert(rows, {
					label = def.name,
					value = if rounds > 0 then ("%s  x%d"):format(money(price), rounds) else "FULL",
					action = if rounds > 0 then "ammo" else "none",
					arg = def.id,
					weapon = def.id,
					locked = rounds <= 0,
					description = ("In reserve: %d / %d."):format(a.reserve, def.reserveCap or 0),
				})
			end
		end
		if #rows == 0 then
			table.insert(rows, { label = "No guns owned yet", action = "none", locked = true })
		end
		return { id = menuId, title = "AMMUNITION", rows = rows }
	end
	if menuId == "armor" then
		for _, id in Weapons.ArmorOrder do
			local def = Weapons.Armor[id]
			local full = ctx.armor >= 100
			table.insert(rows, {
				label = def.name,
				value = if full then "FULL" else money(def.price),
				action = if full then "none" else "armor",
				arg = id,
				locked = full,
				description = ("%s Current armor %d / 100."):format(def.description, math.floor(ctx.armor)),
			})
		end
		return { id = menuId, title = "BODY ARMOR", rows = rows }
	end
	if menuId == "tints" then
		for _, def in Weapons.List do
			if ctx.owned[def.id] and Weapons.isGun(def) then
				table.insert(rows, { label = def.name, action = "open", arg = "tint:" .. def.id, weapon = def.id })
			end
		end
		if #rows == 0 then
			table.insert(rows, { label = "No guns owned yet", action = "none", locked = true })
		end
		return { id = menuId, title = "WEAPON TINTS", rows = rows }
	end
	local tw = string.match(menuId, "^tint:(.+)$")
	if tw then
		local a = ctx.owned[tw]
		local current = (a and a.tint) or "black"
		local list = {}
		for _, t in Weapons.Tints do
			table.insert(list, t)
		end
		table.sort(list, function(x, y)
			return x.order < y.order
		end)
		for _, t in list do
			local have = t.price <= 0 or ctx.tintsOwned[t.id] == true
			table.insert(rows, {
				label = t.name,
				value = if current == t.id then "EQUIPPED" elseif have then "OWNED" else money(t.price),
				action = if current == t.id then "none" else "tint",
				arg = tw,
				arg2 = t.id,
				weapon = tw,
				description = if have then "Apply this finish." else "Cosmetic only. Bought once for every gun.",
			})
		end
		local def = Weapons.get(tw)
		return { id = menuId, title = if def then string.upper(def.name) .. " TINTS" else "TINTS", rows = rows }
	end
	return { id = menuId, title = "", rows = rows }
end

-- VIEW -------------------------------------------------------------------------------------------------------------------

type RowView = { button: TextButton, label: TextLabel, value: TextLabel }
type StatView = { holder: Frame, fill: Frame }
type View = {
	gui: ScreenGui,
	sheet: Frame, -- touch only: the bottom sheet that holds the menu and the preview
	menu: Frame,
	header: Frame,
	cash: TextLabel,
	subTitle: TextLabel,
	subCount: TextLabel,
	rowsFrame: Frame,
	rows: { RowView },
	description: TextLabel,
	descBox: Frame,
	hints: TextLabel,
	back: TextButton,
	preview: Frame,
	previewLayout: UIListLayout,
	viewport: ViewportFrame,
	previewModel: WeaponPreview.Preview,
	previewName: TextLabel,
	previewPrice: TextLabel,
	stats: { StatView },
}

local view: View? = nil
local isOpenFlag = false
local stack: { { id: string, index: number } } = {}
local current: Menu? = nil
local selected = 1
local scroll = 0
local yaw = 0
local turntable: RBXScriptConnection? = nil

local STAT_LABELS = { "DAMAGE", "FIRE RATE", "ACCURACY", "RANGE", "CLIP" }

local function touch(): boolean
	return Kit.isTouch()
end

local function rowHeight(): number
	return if touch() then GunShopUI.ROW_H_TOUCH else GunShopUI.ROW_H
end

-- Rows that fit the touch sheet (pure, tested): SHEET_HEIGHT of the design canvas minus the sheet padding (16) and
-- the subheader (24), at ROW_H_TOUCH each; 3 on a short phone up to MAX_ROWS_TOUCH.
function GunShopUI._touchRows(canvasHeight: number): number
	local inner = canvasHeight * GunShopUI.SHEET_HEIGHT - 16 - 24
	return math.clamp(math.floor(inner / GunShopUI.ROW_H_TOUCH), 3, GunShopUI.MAX_ROWS_TOUCH)
end

local function maxRows(): number
	if not touch() then
		return GunShopUI.MAX_ROWS
	end
	local v = view
	if not v then
		return GunShopUI.MAX_ROWS_TOUCH
	end
	local sc = v.gui:FindFirstChildOfClass("UIScale")
	local scale = if sc and sc.Scale > 0 then sc.Scale else 1
	return GunShopUI._touchRows(v.gui.AbsoluteSize.Y / scale)
end

local function lazy(name: string): any
	local mod = script.Parent:FindFirstChild(name)
	if not mod then
		return nil
	end
	local ok, res = pcall(require, mod :: any)
	return if ok and typeof(res) == "table" then res else nil
end

-- A drawn gun's shoulder camera locks and hides the cursor: suspend it while the shop is up (ShoulderCamera contract).
local function suspendShoulderCamera(on: boolean)
	local cam = lazy("ShoulderCamera")
	if cam and typeof(cam.setSuspended) == "function" then
		pcall(cam.setSuspended, "gunshop", on)
	end
end

local function ctxNow(): Ctx
	local state = lazy("StateController")
	local snap = if state and typeof(state.get) == "function" then state.get() else nil
	local owned: { [string]: { mag: number, reserve: number, tint: string? } } = {}
	for id, a in WeaponClient.inventory() do
		owned[id] = { mag = a.mag, reserve = a.reserve, tint = a.tint }
	end
	local armor = player:GetAttribute("Armor")
	return {
		cash = if snap and typeof(snap.cash) == "number" then snap.cash else 0,
		owned = owned,
		tintsOwned = if snap and typeof(snap.tintsOwned) == "table" then snap.tintsOwned else {},
		armor = if typeof(armor) == "number" then armor else 0,
		medkits = WeaponClient.medkits(),
	}
end

local function label(parent: Instance, props: { [string]: any }): TextLabel
	local base: { [string]: any } = {
		BackgroundTransparency = 1,
		TextColor3 = Style.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = parent,
	}
	for k, v in props do
		base[k] = v
	end
	return Kit.new("TextLabel", base) :: TextLabel
end

local activateRow: (number) -> () = function() end
local goBack: () -> () = function() end

local function build(): View
	local gui = Kit.screen("HC_GunShop", GunShopUI.LAYER, { touchMin = Theme.TouchMinScale })
	gui.Enabled = false
	pcall(function()
		(gui :: any).ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	end)
	-- frees a locked mouse (shift-lock / first person) while the shop is up, as UI/ListMenu does; a 1 px button so it
	-- never swallows taps meant for the world or the touch controls
	Kit.new("TextButton", {
		Name = "Modal",
		Modal = true,
		BackgroundTransparency = 1,
		Text = "",
		Size = UDim2.fromOffset(1, 1),
		Parent = gui,
	})
	local W = GunShopUI.WIDTH
	local menu = Kit.new("Frame", {
		Name = "Menu",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(W, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = gui,
	}) :: Frame
	Kit.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = menu })
	local header = Kit.new("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, 64),
		BackgroundColor3 = Style.Colors.Accent,
		BorderSizePixel = 0,
		LayoutOrder = 1,
		Parent = menu,
	}) :: Frame
	label(header, {
		Name = "Title",
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -28, 1, -8),
		Text = GunShopUI.STORE_NAME,
		FontFace = Style.font("Script"),
		TextSize = 34,
		TextColor3 = Style.Colors.TextPure,
	})
	label(header, {
		Name = "Tagline",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -6),
		Size = UDim2.new(1, -32, 0, 12),
		Text = "GUNS & AMMO",
		FontFace = Style.font("CondensedMedium"),
		TextSize = 11,
		TextColor3 = Color3.new(0, 0, 0),
	})
	local cash = label(header, {
		Name = "Cash",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 8),
		Size = UDim2.fromOffset(140, 18),
		TextXAlignment = Enum.TextXAlignment.Right,
		FontFace = Style.font("Numeric"),
		TextSize = 16,
		TextColor3 = Style.Colors.TextPure,
		Text = "",
	})
	local sub = Kit.new("Frame", {
		Name = "Subheader",
		Size = UDim2.new(1, 0, 0, 24),
		BackgroundColor3 = Style.Colors.MenuHighlight,
		BorderSizePixel = 0,
		LayoutOrder = 2,
		Parent = menu,
	}) :: Frame
	local subTitle = label(sub, {
		Position = UDim2.fromOffset(10, 0),
		Size = UDim2.new(1, -80, 1, 0),
		FontFace = Style.font("Condensed"),
		TextSize = 13,
		Text = "",
	})
	local subCount = label(sub, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 0),
		Size = UDim2.fromOffset(60, 24),
		FontFace = Style.font("Condensed"),
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "",
	})
	local back = Kit.new("TextButton", {
		Name = "Back",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -74, 0.5, 0),
		Size = UDim2.fromOffset(64, 22),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "BACK",
		TextColor3 = Style.Colors.Text,
		FontFace = Style.font("Condensed"),
		TextSize = 13,
		Visible = false,
		Parent = sub,
	}) :: TextButton
	back.Activated:Connect(function()
		goBack()
	end)
	local rowsFrame = Kit.new("Frame", {
		Name = "Rows",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 3,
		Parent = menu,
	}) :: Frame
	Kit.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = rowsFrame })
	local rows: { RowView } = {}
	for i = 1, math.max(GunShopUI.MAX_ROWS, GunShopUI.MAX_ROWS_TOUCH) do
		local b = Kit.new("TextButton", {
			Name = "Row" .. i,
			Size = UDim2.new(1, 0, 0, GunShopUI.ROW_H),
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = Style.Transparency.Row,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Text = "",
			LayoutOrder = i,
			Visible = false,
			Parent = rowsFrame,
		}) :: TextButton
		local l = label(b, {
			Name = "Label",
			Position = UDim2.fromOffset(10, 0),
			Size = UDim2.new(0.62, -10, 1, 0),
			FontFace = Style.font("Body"),
			TextSize = 14,
			Text = "",
		})
		local val = label(b, {
			Name = "Value",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 0),
			Size = UDim2.fromScale(0.38, 1),
			FontFace = Style.font("Numeric"),
			TextSize = 15,
			TextXAlignment = Enum.TextXAlignment.Right,
			Text = "",
		})
		local idx = i
		b.MouseEnter:Connect(function()
			if isOpenFlag and not UserInputService.TouchEnabled then
				local target = scroll + idx
				if target ~= selected then
					selected = target
					GunShopUI._render()
				end
			end
		end)
		b.Activated:Connect(function()
			if isOpenFlag then
				selected = scroll + idx
				activateRow(selected)
			end
		end)
		rows[i] = { button = b, label = l, value = val }
	end
	local descBox = Kit.new("Frame", {
		Name = "Description",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Style.Colors.Panel,
		BackgroundTransparency = Style.Transparency.Panel,
		BorderSizePixel = 0,
		LayoutOrder = 4,
		Parent = menu,
	}) :: Frame
	Kit.new("UIPadding", {
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 10),
		Parent = descBox,
	})
	local description = label(descBox, {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		FontFace = Style.font("Body"),
		TextSize = 13,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None,
		Text = "",
	})
	Kit.new("UITextSizeConstraint", { MaxTextSize = 13, Parent = description })
	local hints = label(menu, {
		Name = "Hints",
		Size = UDim2.new(1, 0, 0, 20),
		LayoutOrder = 5,
		FontFace = Style.font("Body"),
		TextSize = 12,
		TextColor3 = Style.Colors.TextDim,
		Text = "Enter  Select     Backspace  Back     W / S  Move",
	})

	-- touch bottom sheet (layout() moves the menu, the description and the preview into it)
	local sheet = Kit.new("Frame", {
		Name = "Sheet",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, GunShopUI.SHEET_HEIGHT),
		BackgroundColor3 = Style.Colors.Panel,
		BackgroundTransparency = Style.Transparency.Panel,
		BorderSizePixel = 0,
		Visible = false,
		Parent = gui,
	}) :: Frame
	Kit.new("UIPadding", {
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
		Parent = sheet,
	})

	-- preview panel: the model, then an info column (name, stat bars, price); side by side in the touch sheet
	local preview = Kit.new("Frame", {
		Name = "Preview",
		Position = UDim2.fromOffset(Style.SAFE + W + 12, Style.SAFE),
		Size = UDim2.fromOffset(280, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Style.Colors.Panel,
		BackgroundTransparency = Style.Transparency.Panel,
		BorderSizePixel = 0,
		Visible = false,
		Parent = gui,
	}) :: Frame
	local previewLayout =
		Kit.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = preview }) :: UIListLayout
	Kit.new("UIPadding", {
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 10),
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
		Parent = preview,
	})
	local viewport = Kit.new("ViewportFrame", {
		Name = "Model",
		Size = UDim2.fromOffset(256, 120),
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Parent = preview,
	}) :: ViewportFrame
	local info = Kit.new("Frame", {
		Name = "Info",
		Size = UDim2.fromOffset(256, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = preview,
	}) :: Frame
	Kit.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = info })
	local previewName = label(info, {
		Name = "Name",
		Size = UDim2.fromOffset(256, 24),
		FontFace = Style.font("Condensed"),
		TextSize = 20,
		LayoutOrder = 2,
		Text = "",
	})
	local stats: { StatView } = {}
	for i, name in STAT_LABELS do
		local holder = Kit.new("Frame", {
			Name = "Stat" .. i,
			Size = UDim2.fromOffset(256, 18),
			BackgroundTransparency = 1,
			LayoutOrder = 2 + i,
			Parent = info,
		})
		label(holder, {
			Size = UDim2.fromOffset(90, 18),
			FontFace = Style.font("CondensedMedium"),
			TextSize = 12,
			TextColor3 = Style.Colors.TextDim,
			Text = name,
		})
		local track = Kit.new("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 96, 0.5, 0),
			Size = UDim2.fromOffset(160, 6),
			BackgroundColor3 = Style.Colors.MenuDark,
			BorderSizePixel = 0,
			Parent = holder,
		})
		local fill = Kit.new("Frame", {
			Size = UDim2.fromScale(0.5, 1),
			BackgroundColor3 = Style.Colors.Text,
			BorderSizePixel = 0,
			Parent = track,
		}) :: Frame
		stats[i] = { holder = holder :: Frame, fill = fill }
	end
	local previewPrice = label(info, {
		Name = "Price",
		Size = UDim2.fromOffset(256, 28),
		FontFace = Style.font("Numeric"),
		TextSize = 22,
		LayoutOrder = 10,
		Text = "",
	})
	return {
		gui = gui,
		sheet = sheet,
		menu = menu,
		header = header,
		cash = cash,
		subTitle = subTitle,
		subCount = subCount,
		rowsFrame = rowsFrame,
		rows = rows,
		description = description,
		descBox = descBox,
		hints = hints,
		back = back,
		preview = preview,
		previewLayout = previewLayout,
		viewport = viewport,
		previewModel = WeaponPreview.new(viewport, false),
		previewName = previewName,
		previewPrice = previewPrice,
		stats = stats,
	}
end

-- The ScreenGui's UIScale also shrinks scale-sized frames: a full-width sheet is 1 / scale wide (pure, tested).
function GunShopUI._sheetSize(uiScale: number, heightShare: number): UDim2
	local s = if uiScale > 0 then uiScale else 1
	return UDim2.fromScale(1 / s, heightShare / s)
end

local function uiScaleOf(gui: ScreenGui): number
	local s = gui:FindFirstChildOfClass("UIScale")
	return if s and s.Scale > 0 then s.Scale else 1
end

local function layout(v: View)
	local t = touch()
	local W = GunShopUI.WIDTH
	v.hints.Visible = not t
	v.back.Visible = t
	v.header.Visible = not t -- the HUD's cash stays visible above the sheet
	v.sheet.Visible = t
	if t then
		v.sheet.Size = GunShopUI._sheetSize(uiScaleOf(v.gui), GunShopUI.SHEET_HEIGHT)
		v.menu.Parent = v.sheet
		v.menu.AnchorPoint = Vector2.zero
		v.menu.Position = UDim2.new()
		v.menu.AutomaticSize = Enum.AutomaticSize.None
		v.menu.Size = UDim2.new(0.5, -8, 1, 0)
		v.descBox.Parent = v.sheet
		v.descBox.AnchorPoint = Vector2.new(1, 0)
		v.descBox.Position = UDim2.fromScale(1, 0)
		v.descBox.Size = UDim2.new(0.5, -8, 0, 0)
		v.preview.Parent = v.sheet
		v.preview.AnchorPoint = Vector2.new(1, 0)
		v.preview.Position = UDim2.fromScale(1, 0)
		v.preview.AutomaticSize = Enum.AutomaticSize.None
		v.preview.Size = UDim2.new(0.5, -8, 1, 0)
		v.preview.BackgroundTransparency = 1 -- the sheet is the panel
		v.previewLayout.FillDirection = Enum.FillDirection.Horizontal
		v.previewLayout.Padding = UDim.new(0, 12)
		v.viewport.Size = UDim2.fromOffset(150, 110)
	else
		v.menu.Parent = v.gui
		v.menu.AnchorPoint = Vector2.zero
		v.menu.Position = UDim2.fromOffset(Style.SAFE, Style.SAFE)
		v.menu.Size = UDim2.fromOffset(W, 0)
		v.menu.AutomaticSize = Enum.AutomaticSize.Y
		v.descBox.Parent = v.menu
		v.descBox.AnchorPoint = Vector2.zero
		v.descBox.Position = UDim2.new()
		v.descBox.Size = UDim2.fromScale(1, 0)
		v.preview.Parent = v.gui
		v.preview.AnchorPoint = Vector2.zero
		v.preview.Position = UDim2.fromOffset(Style.SAFE + W + 12, Style.SAFE)
		v.preview.Size = UDim2.fromOffset(280, 0)
		v.preview.AutomaticSize = Enum.AutomaticSize.Y
		v.preview.BackgroundTransparency = Style.Transparency.Panel
		v.previewLayout.FillDirection = Enum.FillDirection.Vertical
		v.previewLayout.Padding = UDim.new(0, 0)
		v.viewport.Size = UDim2.fromOffset(256, 120)
	end
	for _, r in v.rows do
		r.button.Size = UDim2.new(1, 0, 0, rowHeight())
	end
end

function GunShopUI._render()
	local v = view
	local m = current
	if not v or not m then
		return
	end
	local ctx = ctxNow()
	v.cash.Text = money(ctx.cash)
	v.subTitle.Text = m.title
	local n = #m.rows
	selected = math.clamp(selected, 1, math.max(n, 1))
	v.subCount.Text = if n > 0 then ("%d/%d"):format(selected, n) else ""
	local visible = maxRows()
	if selected <= scroll then
		scroll = selected - 1
	elseif selected > scroll + visible then
		scroll = selected - visible
	end
	scroll = math.clamp(scroll, 0, math.max(0, n - visible))
	local C = Style.Colors
	for i, rv in v.rows do
		local idx = scroll + i
		local row = m.rows[idx]
		if row and i <= visible then
			rv.button.Visible = true
			local sel = idx == selected
			rv.button.BackgroundColor3 = if sel then C.TextPure else Color3.new(0, 0, 0)
			rv.button.BackgroundTransparency = if sel then 0 else Style.Transparency.Row
			local ink = if sel then Color3.new(0, 0, 0) elseif row.locked then C.TextDisabled else C.Text
			rv.label.TextColor3 = ink
			rv.value.TextColor3 = ink
			rv.label.Text = row.label
			rv.value.Text = if row.action == "open" then ">" else row.value or ""
		else
			rv.button.Visible = false
		end
	end
	local row = m.rows[selected]
	local desc = if row then row.description else nil
	v.description.Text = desc or ""
	-- preview
	local wid = if row then row.weapon else nil
	local def = if wid then Weapons.get(wid) else nil
	v.preview.Visible = def ~= nil
	-- touch: the description shares the sheet's right half with the preview, which wins
	v.descBox.Visible = desc ~= nil and desc ~= "" and not (touch() and def ~= nil)
	if def then
		local owned = ctx.owned[def.id]
		local tint = if row and row.action == "tint" and row.arg2 then row.arg2 elseif owned then owned.tint else nil
		WeaponPreview.show(v.previewModel, def.id, tint)
		v.previewName.Text = string.upper(def.name)
		local bars = Weapons.statBars(def)
		local values = { bars.damage, bars.rate, bars.accuracy, bars.range, bars.clip }
		for i, s in v.stats do
			s.fill.Size = UDim2.fromScale(values[i], 1)
			s.holder.Visible = Weapons.isGun(def) or i == 1 or i == 2
		end
		v.previewPrice.Text = if owned then "OWNED" else money(def.price)
	end
end

-- NAVIGATION -----------------------------------------------------------------------------------------------------------------

local function openMenu(id: string, keepIndex: number?)
	current = GunShopUI._menu(id, ctxNow())
	selected = keepIndex or 1
	scroll = 0
	GunShopUI._render()
end

local function refresh()
	local m = current
	if not m then
		return
	end
	current = GunShopUI._menu(m.id, ctxNow())
	GunShopUI._render()
end

local function play(key: string)
	local snd = lazy("SoundController")
	if snd and typeof(snd.play) == "function" then
		pcall(snd.play, key)
	end
end

activateRow = function(index: number)
	local m = current
	local row = m and m.rows[index]
	if not m or not row then
		return
	end
	local a = row.action
	if a == "open" and row.arg then
		table.insert(stack, { id = m.id, index = index })
		openMenu(row.arg)
		play("Click")
	elseif a == "buy" and row.arg then
		Net.fire("BuyWeapon", row.arg)
	elseif a == "ammo" and row.arg then
		Net.fire("BuyAmmo", row.arg, false)
	elseif a == "fullammo" and row.arg then
		Net.fire("BuyAmmo", row.arg, true)
	elseif a == "armor" and row.arg then
		Net.fire("BuyArmor", row.arg)
	elseif a == "medkit" then
		Net.fire("BuyMedKit")
	elseif a == "tint" and row.arg and row.arg2 then
		Net.fire("SetWeaponTint", row.arg, row.arg2)
	else
		play("ClickBright")
	end
end

goBack = function()
	local top = table.remove(stack)
	if top then
		openMenu(top.id, top.index)
		play("Click")
	else
		GunShopUI.close()
	end
end

local function move(dir: number)
	local m = current
	if not m or #m.rows == 0 then
		return
	end
	selected = (selected - 1 + dir) % #m.rows + 1
	GunShopUI._render()
	play("Click")
end

local function onAction(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	local key = input.KeyCode
	if input.UserInputType == Enum.UserInputType.MouseWheel then
		if state == Enum.UserInputState.Change then
			move(if input.Position.Z > 0 then -1 else 1)
		end
		return Enum.ContextActionResult.Sink
	end
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Sink
	end
	if key == Enum.KeyCode.Up or key == Enum.KeyCode.W or key == Enum.KeyCode.DPadUp then
		move(-1)
	elseif key == Enum.KeyCode.Down or key == Enum.KeyCode.S or key == Enum.KeyCode.DPadDown then
		move(1)
	elseif key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter or key == Enum.KeyCode.ButtonA then
		activateRow(selected)
	elseif key == Enum.KeyCode.Backspace or key == Enum.KeyCode.ButtonB then
		goBack()
	end
	return Enum.ContextActionResult.Sink
end

local function bind(on: boolean)
	if on then
		ContextActionService:BindActionAtPriority(
			ACTION,
			onAction,
			false,
			Enum.ContextActionPriority.High.Value + 50,
			Enum.KeyCode.Up,
			Enum.KeyCode.Down,
			Enum.KeyCode.Left,
			Enum.KeyCode.Right,
			Enum.KeyCode.W,
			Enum.KeyCode.A,
			Enum.KeyCode.S,
			Enum.KeyCode.D,
			Enum.KeyCode.Space,
			Enum.KeyCode.Return,
			Enum.KeyCode.KeypadEnter,
			Enum.KeyCode.Backspace,
			Enum.KeyCode.DPadUp,
			Enum.KeyCode.DPadDown,
			Enum.KeyCode.ButtonA,
			Enum.KeyCode.ButtonB,
			Enum.UserInputType.MouseWheel
		)
	else
		ContextActionService:UnbindAction(ACTION)
	end
end

function GunShopUI.isOpen(): boolean
	return isOpenFlag
end

function GunShopUI.open()
	local v = view
	if not v then
		local built = build()
		v = built
		view = built
		-- a rotation / input switch changes the UIScale: the touch sheet's size compensates for it
		local sc = built.gui:FindFirstChildOfClass("UIScale")
		if sc then
			sc:GetPropertyChangedSignal("Scale"):Connect(function()
				if isOpenFlag then
					layout(built)
				end
			end)
		end
	end
	local vv = v :: View
	layout(vv)
	table.clear(stack)
	isOpenFlag = true
	vv.gui.Enabled = true
	suspendShoulderCamera(true)
	openMenu("root")
	bind(true)
	if turntable then
		turntable:Disconnect()
	end
	turntable = RunService.RenderStepped:Connect(function(dt: number)
		if vv.preview.Visible then
			yaw += dt * 0.6
			WeaponPreview.setYaw(vv.previewModel, yaw)
		end
	end)
	local wheel = lazy("WeaponWheel")
	if wheel and typeof(wheel.close) == "function" then
		pcall(wheel.close, false)
	end
end

function GunShopUI.close()
	if not isOpenFlag then
		return
	end
	isOpenFlag = false
	bind(false)
	suspendShoulderCamera(false)
	if turntable then
		turntable:Disconnect()
		turntable = nil
	end
	local v = view
	if v then
		v.gui.Enabled = false
		WeaponPreview.show(v.previewModel, nil)
	end
	current = nil
end

local function inStore(): boolean
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	local z = MapLayout.safeZoneAt(root.Position)
	return z ~= nil and z.kind == "gunstore"
end

function GunShopUI.init() end

function GunShopUI.start()
	pcall(Net.listen, "OpenUI", function(name: any)
		if name == "GunShop" then
			GunShopUI.open()
		elseif isOpenFlag and typeof(name) == "string" then
			GunShopUI.close()
		end
	end)
	WeaponClient.Changed:Connect(function()
		if isOpenFlag then
			refresh()
		end
	end)
	local state = lazy("StateController")
	if state and state.Changed then
		state.Changed:Connect(function()
			if isOpenFlag then
				refresh()
			end
		end)
	end
	player:GetAttributeChangedSignal("Armor"):Connect(function()
		if isOpenFlag then
			refresh()
		end
	end)
	player.CharacterAdded:Connect(function()
		GunShopUI.close()
	end)
	local outside = 0
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		if not isOpenFlag then
			outside = 0
			return
		end
		acc += dt
		if acc < 0.25 then
			return
		end
		local step = acc
		acc = 0
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 or hum.SeatPart ~= nil then
			GunShopUI.close()
			return
		end
		if inStore() then
			outside = 0
		else
			outside += step
			if outside > 0.75 then
				GunShopUI.close()
			end
		end
	end)
end

return GunShopUI
