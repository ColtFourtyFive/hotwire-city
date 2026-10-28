--!strict
-- NotificationController v2 (gta_ui_language §2.8, §5.7, §5.15): every transient message, in GTA's feed.
--
--  * post({ title?, subtitle?, body, portrait?, key?, sound?, duration?, color? })   the core: a feed card stacked
--      above the radar (desktop; under the help text on touch) in the HUD's feed host. Contact cards carry a portrait
--      (Config/UIAssets portraits.<id>), the sender in Oswald and a grey subject line; plain cards are just the body.
--      Translucent black, no corners; slides in 12 px, lives 6 s, fades out; at most 4 (touch 2) at once; repeats
--      merge with a grey "(x3)". Never takes touches. No emoji: everything passes through Kit.sanitize.
--  * toast(kind, text, duration?)     the v1 API (Notify remote): a plain feed card; errors read red, money green.
--  * feed(richText)                   EventFeed remote: server rich text (bold names etc.) as a plain card.
--  * announce(title, subtitle?, color?, sound?)   Announce remote (other players' big moments, server events): a feed
--      card with the title as the sender line. The big centre shard is reserved for your own moments (UI/Shard).
--      C4b: the feed blip, never the server's air horn (announceSound); toast / feed / announce text is calmed
--      (RichText.calm: no "!").
--  * cashPopup(amount, worldPos?)     CashPopup remote: the HUD cash delta covers the number; with a world position
--      (collect pad, cash pickups) a small Montserrat "+$1,200" rises there and fades.
--  * offlineEarnings(amount, seconds) OfflineEarnings remote: an email from Garage Security ("Garage income while you
--      were away"), the feed card, and the HUD's +$ delta rolling the cash up.
--  * carStolenAlert(thief, carId, mutation, active)   CarStolenAlert remote: a Garage Security text + feed card, a
--      red GPS route and blip that follow the car itself (WaypointController.track), help text, a quiet alarm loop.
--      No full-screen vignette.
--  Streamer mode: the feed lives in the HUD's screen, so it hides with it.
--  Public: post, toast, feed, announce, cashPopup, offlineEarnings, carStolenAlert, isAlertActive(),
--  getAlertBottom(): number? (nil: no banner any more), isOfflineOpen() (false: no modal any more).
--  Pure helpers (tests): kindStyle, announceSound, trimOldest, formatCashDelta, richEscape, carLabel, stolenAlertText, alertSubtitle,
--  bannerHold, toastAnchor, pickStolenCar, mergeKey.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Config = Shared:WaitForChild("Config")
local Cars = require(Config:WaitForChild("Cars"))
local Rarity = require(Config:WaitForChild("Rarity"))
local Economy = require(Config:WaitForChild("Economy"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))
local HudLayout = require(UI:WaitForChild("HudLayout"))
local RichText = require(UI:WaitForChild("RichText"))

-- Earlier in the client ORDER: safe to require directly.
local SoundController = require(script.Parent:WaitForChild("SoundController"))

local NotificationController = {}

local player = Players.LocalPlayer
local C = Theme.Colors

local FEED_LIFETIME = 6
local TOAST_ANCHOR_DESKTOP = UDim2.new(1, -14, 0.36, 0) -- v1 toast anchor (toastAnchor helper, kept for tests)
local TOAST_TOP_TOUCH = 8
local TOUCH_CONTROLS_WIDTH = 140
local BANNER_TOTAL_SECONDS = 3
local ALERT_SAFETY_SECONDS = (Economy.THEFT_TIME_LIMIT or 150) + (Economy.DROPPED_CAR_TIMEOUT or 20) + 20
local ALERT_CAR_RESCAN = 0.5 -- seconds between scans for the stolen car model (the waypoint getter runs per frame)
local ALERT_WAYPOINT_ID = "stolen_car"
local ALERT_HELP_ID = "stolen_car"
local WORLD_POPUP_POOL = 4

export type ToastKind = "info" | "success" | "error" | "money" | "warning"
export type KindStyle = { color: Color3, icon: string, sound: string? }

-- icon = a Config/UIAssets hud glyph (small marker, never an emoji); color = the card's text colour.
local KIND_STYLES: { [string]: KindStyle } = {
	info = { color = C.Text, icon = "bubble", sound = "Notify" },
	success = { color = C.Text, icon = "check", sound = "Notify" },
	money = { color = C.Green, icon = "cash", sound = nil }, -- the server plays its own cash sound
	warning = { color = C.Yellow, icon = "bubble", sound = "Notify" },
	error = { color = C.Red, icon = "minus", sound = "Click" },
}

-------------------------------------------------------------------------------------------------------------------------
-- Pure helpers (exported for tests)
-------------------------------------------------------------------------------------------------------------------------

function NotificationController.kindStyle(kind: any): KindStyle
	return KIND_STYLES[if typeof(kind) == "string" then kind else "info"] or KIND_STYLES.info
end

-- The sound an announcement card makes (C4b de-Robloxify). Server events name v1 sounds (air horns, cash fanfares,
-- car horns); GTA's feed gives every card the same quiet blip, so anything outside this short list plays "Notify".
-- "" stays silent.
NotificationController.ANNOUNCE_SOUNDS = { Notify = true, Click = true } :: { [string]: boolean }
function NotificationController.announceSound(sound: string?): string
	if sound == "" then
		return ""
	end
	return if typeof(sound) == "string" and NotificationController.ANNOUNCE_SOUNDS[sound] then sound else "Notify"
end

-- Removes the oldest entries (front of the list) until #list <= max. Returns the removed entries, oldest first.
function NotificationController.trimOldest<T>(list: { T }, max: number): { T }
	local removed: { T } = {}
	while #list > math.max(0, max) do
		table.insert(removed, table.remove(list, 1) :: T)
	end
	return removed
end

-- 1234 -> "+$1.23K", -500 -> "-$500"
function NotificationController.formatCashDelta(amount: number): string
	if amount ~= amount then
		amount = 0
	end
	if amount < 0 then
		return "-" .. Format.cash(-amount)
	end
	return "+" .. Format.cash(amount)
end

-- Escapes text for RichText labels (player names may contain < > &).
function NotificationController.richEscape(text: string): string
	return RichText.escape(text)
end

-- "GOLD PHANTOM GT" style label for a car + mutation (falls back to the raw id).
function NotificationController.carLabel(carId: any, mutation: any): string
	local def = if typeof(carId) == "string" then Cars.get(carId) else nil
	local name = if def then def.name elseif typeof(carId) == "string" then carId else "CAR"
	local mut = if typeof(mutation) == "string" and mutation ~= "None" then Rarity.Mutations[mutation :: any] else nil
	local prefix = if mut and mut.label ~= "" then mut.label .. " " else ""
	return string.upper(prefix .. name)
end

-- Rich-text line for the stolen-car alert (GTA keyword colours: the thief red, your car blue).
function NotificationController.stolenAlertText(thiefName: string, carId: any, mutation: any): string
	local thief = NotificationController.richEscape(string.upper(thiefName))
	local car = NotificationController.richEscape(NotificationController.carLabel(carId, mutation))
	return ('<font color="#E03232">%s</font> IS STEALING YOUR <font color="#5DB6E5">%s</font>!'):format(thief, car)
end

-- Stolen-car alert subtitle (F3): how long the thief has left (endsAt, server time), or, while the car sits dropped,
-- the tow countdown and a nudge to Recover it. Times unknown -> the plain call to action.
function NotificationController.alertSubtitle(
	endsAt: number?,
	dropped: boolean,
	droppedEndsAt: number?,
	now: number
): string
	if dropped and droppedEndsAt and droppedEndsAt == droppedEndsAt then
		return `Dropped. Run to it and RECOVER it: {Format.clock(math.ceil(math.max(0, droppedEndsAt - now)))}`
	end
	if endsAt and endsAt == endsAt and endsAt > now then
		return `{Format.clock(math.ceil(endsAt - now))} left. Chase them down and BONK them to get it back.`
	end
	return "Chase them down and BONK them to get it back."
end

-- Seconds a v1 banner stayed fully visible given the backlog (kept for tests and the feed's hold tuning).
function NotificationController.bannerHold(queued: number): number
	if queued >= 3 then
		return 1.1
	elseif queued >= 1 then
		return 1.6
	end
	return BANNER_TOTAL_SECONDS - 0.75
end

-- v1 toast stack anchor (kept for tests; v2 feed cards follow UI/HudLayout).
function NotificationController.toastAnchor(touch: boolean, controlsScale: number, toastScale: number): UDim2
	if not touch then
		return TOAST_ANCHOR_DESKTOP
	end
	local s = if toastScale > 0 then toastScale else 1
	return UDim2.new(1, -math.ceil((TOUCH_CONTROLS_WIDTH * controlsScale + 8) / s), 0, TOAST_TOP_TOUCH)
end

export type CarInfo = { victimUserId: any, active: any, carId: any, mutation: any }

-- Which car (index) is the local victim's stolen car: TheftActive + TheftVictimUserId == me, preferring the one that
-- matches the alert's car id + mutation. nil when none.
function NotificationController.pickStolenCar(
	cars: { CarInfo },
	myUserId: number,
	carId: string?,
	mutation: string?
): number?
	local fallback: number? = nil
	for i, c in cars do
		if c.active == true and c.victimUserId == myUserId then
			if carId == nil or (c.carId == carId and (c.mutation or "None") == (mutation or "None")) then
				return i
			end
			fallback = fallback or i
		end
	end
	return fallback
end

-- Feed merge key: an explicit key, else the readable text (identical posts merge into "(x2)").
function NotificationController.mergeKey(post: any): string
	if typeof(post) ~= "table" then
		return ""
	end
	if typeof(post.key) == "string" and post.key ~= "" then
		return post.key
	end
	return (if typeof(post.title) == "string" then post.title else "")
		.. "|"
		.. RichText.plain(if typeof(post.body) == "string" then post.body else "")
end

-------------------------------------------------------------------------------------------------------------------------
-- Utilities
-------------------------------------------------------------------------------------------------------------------------

local function tween(inst: Instance, info: TweenInfo, props: { [string]: any }): Tween
	local t = TweenService:Create(inst, info, props)
	t:Play()
	return t
end

local function lazyController(name: string): any
	local mod = script.Parent:FindFirstChild(name)
	if not mod or not mod:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, mod :: any)
	return if ok and typeof(result) == "table" then result else nil
end

local lastSoundAt: { [string]: number } = {}
local function playSound(key: string?, minGap: number?)
	if not key then
		return
	end
	local now = os.clock()
	if now - (lastSoundAt[key] or -math.huge) < (minGap or 0.08) then
		return
	end
	lastSoundAt[key] = now
	pcall(SoundController.play, key)
end

-------------------------------------------------------------------------------------------------------------------------
-- Feed
-------------------------------------------------------------------------------------------------------------------------

type Card = {
	key: string,
	frame: Frame,
	body: TextLabel,
	count: number,
	baseText: string,
	token: number,
	closing: boolean,
}

local cards: { Card } = {}
local cardOrder = 0
local fallbackHost: Frame? = nil

-- The HUD's feed host (above the radar / under the help text); a fallback screen until the HUD exists.
local function feedHost(): (Frame, number, number)
	local hud = lazyController("HUDController")
	local touch = Kit.isTouch()
	local width = if touch then HudLayout.FEED_W_TOUCH else HudLayout.FEED_W
	local max = if touch then 2 else 4
	if hud and typeof(hud.getFeedHost) == "function" then
		local ok, host = pcall(hud.getFeedHost)
		if ok and typeof(host) == "Instance" and host:IsA("Frame") then
			if typeof(hud.getLayout) == "function" then
				local okL, L = pcall(hud.getLayout)
				if okL and typeof(L) == "table" then
					width, max = L.feed.w, L.feedMax
				end
			end
			return host, width, max
		end
	end
	local f = fallbackHost
	if f and f.Parent then
		return f, width, max
	end
	local gui = Kit.screen("HC_Feed", Theme.Layers.Feed, { touchMin = Theme.TouchMinScale })
	local L = HudLayout.compute(1280, 720, touch)
	local host = Kit.new("Frame", {
		Name = "Feed",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(L.feed.x, L.feed.y),
		Size = UDim2.fromOffset(L.feed.w, L.feed.h),
		Parent = gui,
	}, { Kit.list(Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Bottom) })
	fallbackHost = host
	return host, width, max
end

local function closeCard(card: Card)
	if card.closing then
		return
	end
	card.closing = true
	local idx = table.find(cards, card)
	if idx then
		table.remove(cards, idx)
	end
	Kit.fadeTree(card.frame, 1, 0.3)
	task.delay(0.32, function()
		card.frame:Destroy()
	end)
end

local function armCard(card: Card, life: number)
	card.token += 1
	local token = card.token
	task.delay(life, function()
		if card.token == token then
			closeCard(card)
		end
	end)
end

export type Post = {
	title: string?,
	subtitle: string?,
	body: string,
	portrait: string?, -- Config/UIAssets key, e.g. "portraits.security"
	key: string?,
	sound: string?,
	duration: number?,
	color: Color3?, -- body colour
	titleColor: Color3?,
}

-- Posts a feed card. Returns nothing; identical posts merge.
function NotificationController.post(p: Post)
	if typeof(p) ~= "table" or typeof(p.body) ~= "string" then
		return
	end
	local body = Kit.sanitize(p.body)
	if body == "" and not p.title then
		return
	end
	local key = NotificationController.mergeKey(p)
	local life = if typeof(p.duration) == "number" then math.clamp(p.duration, 2, 15) else FEED_LIFETIME
	for _, card in cards do
		if card.key == key and not card.closing then
			card.count += 1
			card.body.Text = card.baseText .. ` <font color="#9B9B9B">(x{card.count})</font>`
			armCard(card, life)
			return
		end
	end
	local host, width, max = feedHost()
	cardOrder += 1
	local frame = Kit.panel({
		Name = "FeedCard",
		Size = UDim2.fromOffset(width, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = cardOrder,
		Active = false,
		Parent = host,
	})
	Kit.padding(6, 8).Parent = frame
	Kit.list(Enum.FillDirection.Vertical, 3, Enum.HorizontalAlignment.Left).Parent = frame
	if p.title then
		local head = Kit.new("Frame", {
			Name = "Head",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, if p.portrait then 40 else 20),
			LayoutOrder = 1,
			Parent = frame,
		})
		local left = 0
		if p.portrait then
			Kit.image(p.portrait, {
				Name = "Portrait",
				Size = UDim2.fromOffset(40, 40),
				ScaleType = Enum.ScaleType.Crop,
				Parent = head,
			})
			left = 48
		end
		Kit.text(Kit.sanitize(p.title), "condensed", 15, {
			Name = "Sender",
			Position = UDim2.fromOffset(left, if p.portrait then 2 else 0),
			Size = UDim2.new(1, -left, 0, 20),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = p.titleColor or C.Text,
			Parent = head,
		})
		if p.subtitle then
			Kit.text(Kit.sanitize(p.subtitle), "body", 12, {
				Name = "Subject",
				Position = UDim2.fromOffset(left, 22),
				Size = UDim2.new(1, -left, 0, 15),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = C.TextDim,
				Parent = head,
			})
		end
	end
	local bodyLabel = Kit.text(body, "body", 13, {
		Name = "Body",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = p.color or C.Text,
		LayoutOrder = 2,
		MaxVisibleGraphemes = 160, -- ~3 lines at the feed width
		Visible = body ~= "",
		Parent = frame,
	})
	local card: Card = {
		key = key,
		frame = frame,
		body = bodyLabel,
		count = 1,
		baseText = body,
		token = 0,
		closing = false,
	}
	table.insert(cards, card)
	-- enter: 12 px slide + fade
	Kit.fadeTree(frame, 1, 0)
	Kit.fadeTree(frame, 0, 0.2)
	local pad = frame:FindFirstChildOfClass("UIPadding")
	if pad then
		pad.PaddingLeft = UDim.new(0, -4)
		tween(
			pad,
			TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ PaddingLeft = UDim.new(0, 8) }
		)
	end
	armCard(card, life)
	local live = {}
	for _, c in cards do
		if not c.closing then
			table.insert(live, c)
		end
	end
	for _, old in NotificationController.trimOldest(live, max) do
		closeCard(old)
	end
	playSound(if p.sound == nil then "Notify" elseif p.sound == "" then nil else p.sound, 0.25)
end

-- v1 API: Notify remote. Server copy is calmed first (RichText.calm: GTA's feed never shouts; C4b).
function NotificationController.toast(kind: string, text: string, duration: number?)
	local style = NotificationController.kindStyle(kind)
	NotificationController.post({
		body = RichText.calm(text),
		color = style.color,
		sound = style.sound or "",
		duration = duration,
	})
end

-- EventFeed remote (server rich text: bold names, rarity colours).
function NotificationController.feed(richText: string)
	NotificationController.post({ body = RichText.calm(richText), sound = "", duration = 7 })
end

-- Announce remote: other players' big moments / server events, as a sender-line card (the shard is for your own).
function NotificationController.announce(title: string, subtitle: string?, color: Color3?, sound: string?)
	NotificationController.post({
		title = string.upper(Kit.sanitize(RichText.calm(title))),
		body = RichText.calm(subtitle or ""),
		titleColor = color,
		sound = NotificationController.announceSound(sound),
		duration = 6,
	})
end

-------------------------------------------------------------------------------------------------------------------------
-- Cash pops (world only, small)
-------------------------------------------------------------------------------------------------------------------------

type WorldPopup = { anchor: Attachment, gui: BillboardGui, label: TextLabel, busy: boolean }
local popups: { WorldPopup } = {}
local fxAnchor: Part? = nil

local function getFxAnchor(): Part
	local a = fxAnchor
	if a and a.Parent then
		return a
	end
	local part = Instance.new("Part")
	part.Name = "HC_CashFx"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Parent = Workspace
	fxAnchor = part
	return part
end

local function acquirePopup(): WorldPopup?
	for _, p in popups do
		if not p.busy then
			return p
		end
	end
	if #popups >= WORLD_POPUP_POOL then
		return nil
	end
	local att = Instance.new("Attachment")
	att.Parent = getFxAnchor()
	local gui = Kit.new("BillboardGui", {
		Name = "CashPop",
		Adornee = att,
		AlwaysOnTop = true,
		LightInfluence = 0,
		Size = UDim2.fromOffset(180, 40),
		MaxDistance = 120,
		Enabled = false,
		Parent = player:FindFirstChildOfClass("PlayerGui"),
	})
	local label = Kit.text("", "bodyBold", 22, {
		Size = UDim2.fromScale(1, 1),
		TextColor3 = C.Green,
		Parent = gui,
	})
	Kit.new("UIStroke", { Color = C.Black, Thickness = 1.5, Transparency = 0.3, Parent = label })
	local p: WorldPopup = { anchor = att, gui = gui, label = label, busy = false }
	table.insert(popups, p)
	return p
end

function NotificationController.cashPopup(amount: number, worldPosition: Vector3?)
	if typeof(amount) ~= "number" or amount ~= amount or amount == 0 or not worldPosition then
		return -- the HUD's cash delta line shows every change
	end
	local p = acquirePopup()
	if not p then
		return
	end
	p.busy = true
	p.anchor.WorldPosition = worldPosition + Vector3.new(0, 3, 0)
	p.label.Text = (if amount < 0 then "-$" else "+$") .. Format.commas(math.abs(amount))
	p.label.TextColor3 = if amount < 0 then C.Red else C.Green
	p.label.TextTransparency = 0
	p.gui.Enabled = true
	p.gui.StudsOffsetWorldSpace = Vector3.zero
	tween(p.gui, TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		StudsOffsetWorldSpace = Vector3.new(0, 3, 0),
	})
	tween(p.label, TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.In, 0, false, 0.7), {
		TextTransparency = 1,
	})
	task.delay(1.25, function()
		p.gui.Enabled = false
		p.busy = false
	end)
end

-------------------------------------------------------------------------------------------------------------------------
-- Offline earnings (email + feed + cash delta)
-------------------------------------------------------------------------------------------------------------------------

function NotificationController.isOfflineOpen(): boolean
	return false
end

function NotificationController.offlineEarnings(amount: number, seconds: number?)
	if typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return
	end
	local away = if typeof(seconds) == "number" and seconds > 0 then Format.duration(seconds) else nil
	local body = `Garage income while you were away{if away then " (" .. away .. ")" else ""}: <font color="#72CC72">+$`
		.. Format.commas(amount)
		.. "</font>"
	local phone = lazyController("PhoneController")
	if phone and typeof(phone.text) == "function" then
		pcall(phone.text, "security", body, { kind = "email" })
	else
		NotificationController.post({
			title = "Garage Security",
			subtitle = "New email",
			body = body,
			portrait = "portraits.security",
		})
	end
	-- roll the HUD cash up from the pre-grant value
	local hud = lazyController("HUDController")
	if hud and typeof(hud.holdCash) == "function" and typeof(hud.releaseCash) == "function" then
		pcall(hud.holdCash, amount)
		task.delay(2.5, function()
			pcall(hud.releaseCash)
		end)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Stolen-car alert
-------------------------------------------------------------------------------------------------------------------------

type AlertRec = { thief: string, carId: string, mutation: string, token: number }

local alerts: { AlertRec } = {}
local alertToken = 0
local alertSiren: Sound? = nil
local alertLastCar: Model? = nil
local alertCar: Model? = nil
local alertCarScanAt = -math.huge

local function findPlayerByName(name: string): Player?
	for _, p in Players:GetPlayers() do
		if p.Name == name then
			return p
		end
	end
	for _, p in Players:GetPlayers() do
		if p.DisplayName == name then
			return p
		end
	end
	return nil
end

local function resetAlertCar()
	alertLastCar = nil
	alertCar = nil
	alertCarScanAt = -math.huge
end

local function isOurStolenCar(model: Model?): boolean
	return model ~= nil
		and model.Parent ~= nil
		and model:GetAttribute("TheftActive") == true
		and model:GetAttribute("TheftVictimUserId") == player.UserId
end

local function findStolenCar(rec: AlertRec): Model?
	local cached = alertCar
	if isOurStolenCar(cached) then
		return cached
	end
	local now = os.clock()
	if now - alertCarScanAt < ALERT_CAR_RESCAN then
		return nil
	end
	alertCarScanAt = now
	local models: { Model } = {}
	local infos: { CarInfo } = {}
	for _, inst in CollectionService:GetTagged("Vehicle") do
		if inst:IsA("Model") and inst:GetAttribute("TheftActive") == true then
			table.insert(models, inst)
			table.insert(infos, {
				victimUserId = inst:GetAttribute("TheftVictimUserId"),
				active = true,
				carId = inst:GetAttribute("CarId"),
				mutation = inst:GetAttribute("Mutation"),
			})
		end
	end
	local idx = NotificationController.pickStolenCar(
		infos,
		player.UserId,
		if rec.carId ~= "" then rec.carId else nil,
		rec.mutation
	)
	alertCar = if idx then models[idx] else nil
	return alertCar
end

-- Position of the stolen car for the live waypoint; falls back to the thief found by (display) name.
local function thiefPosition(): Vector3?
	local rec = alerts[#alerts]
	if not rec then
		return nil
	end
	local car = findStolenCar(rec)
	if car then
		return car:GetPivot().Position
	end
	local thief = findPlayerByName(rec.thief)
	local char = thief and thief.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	if seat then
		local model = seat:FindFirstAncestorOfClass("Model")
		if model and model ~= char then
			alertLastCar = model
			return model:GetPivot().Position
		end
		return seat.Position
	end
	local lastCar = alertLastCar
	if lastCar and lastCar.Parent then
		return lastCar:GetPivot().Position
	end
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

local function setAlertWaypoint(on: boolean)
	local wp = lazyController("WaypointController")
	if not wp then
		return
	end
	if on and typeof(wp.track) == "function" then
		pcall(wp.track, ALERT_WAYPOINT_ID, thiefPosition, C.Red, "YOUR CAR")
	elseif not on and typeof(wp.clear) == "function" then
		pcall(wp.clear, ALERT_WAYPOINT_ID)
	end
end

local function setAlertHelp(rec: AlertRec?)
	local hud = lazyController("HUDController")
	if not hud then
		return
	end
	if rec then
		if typeof(hud.help) == "function" then
			local car = NotificationController.carLabel(rec.carId, rec.mutation)
			local key = if Kit.inputKind() == "touch" then "the PHONE button" else RichText.key("B")
			pcall(
				hud.help,
				`Your <blue>{RichText.escape(car)}</blue> is being stolen. Follow the <r>red route</r> and chase the thief, or check the phone ({key}).`,
				{ id = ALERT_HELP_ID, duration = math.huge, urgent = true }
			)
		end
	elseif typeof(hud.clearHelp) == "function" then
		pcall(hud.clearHelp, ALERT_HELP_ID)
	end
end

local function refreshAlert()
	if #alerts > 0 then
		if not alertSiren then
			local ok, snd = pcall(SoundController.playLoop, "Siren")
			if ok and snd then
				snd.Volume *= 0.35
				alertSiren = snd
			end
		end
		setAlertWaypoint(true)
		setAlertHelp(alerts[#alerts])
	else
		if alertSiren then
			pcall(SoundController.stopLoop, alertSiren)
			alertSiren = nil
		end
		resetAlertCar()
		setAlertWaypoint(false)
		setAlertHelp(nil)
	end
end

local function securityText(body: string)
	local phone = lazyController("PhoneController")
	if phone and typeof(phone.text) == "function" then
		pcall(phone.text, "security", body, { sound = "Notify" })
	else
		NotificationController.post({
			title = "Garage Security",
			subtitle = "Alert",
			body = body,
			portrait = "portraits.security",
		})
	end
end

function NotificationController.carStolenAlert(thiefName: string, carId: string, mutation: string, active: boolean)
	local thief = if typeof(thiefName) == "string" and thiefName ~= "" then thiefName else "SOMEONE"
	local car = if typeof(carId) == "string" then carId else ""
	local mut = if typeof(mutation) == "string" then mutation else "None"

	if active == true then
		-- replace an alert for the same car (e.g. another thief took over the theft)
		for i = #alerts, 1, -1 do
			if alerts[i].carId == car and alerts[i].mutation == mut then
				table.remove(alerts, i)
			end
		end
		alertToken += 1
		local rec: AlertRec = { thief = thief, carId = car, mutation = mut, token = alertToken }
		table.insert(alerts, rec)
		resetAlertCar()
		securityText(NotificationController.stolenAlertText(thief, car, mut))
		task.delay(ALERT_SAFETY_SECONDS, function()
			local idx = table.find(alerts, rec)
			if idx then
				table.remove(alerts, idx)
				refreshAlert()
			end
		end)
		refreshAlert()
	else
		local removedAny = false
		for i = #alerts, 1, -1 do
			if alerts[i].carId == car and alerts[i].mutation == mut then
				table.remove(alerts, i)
				removedAny = true
			end
		end
		if not removedAny then
			table.clear(alerts) -- unknown payload: never leave an alarm stuck on
		end
		refreshAlert()
	end
end

-- True while at least one "your car is being stolen" alarm is active.
function NotificationController.isAlertActive(): boolean
	return #alerts > 0
end

-- v1 banner bottom (EventsClient stacked under it). There is no banner in v2.
function NotificationController.getAlertBottom(): number?
	return nil
end

-------------------------------------------------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------------------------------------------------

local function safeListen(name: string, handler: (...any) -> ())
	local ok, err = pcall(Net.listen, name, handler)
	if not ok then
		warn(("[NotificationController] could not listen to %s: %s"):format(name, tostring(err)))
	end
end

function NotificationController.init() end

function NotificationController.start()
	safeListen("Notify", function(kind: any, text: any, duration: any)
		if typeof(text) ~= "string" then
			return
		end
		NotificationController.toast(
			if typeof(kind) == "string" then kind else "info",
			text,
			if typeof(duration) == "number" then duration else nil
		)
	end)
	safeListen("Announce", function(title: any, subtitle: any, color: any, sound: any)
		if typeof(title) ~= "string" then
			return
		end
		NotificationController.announce(
			title,
			if typeof(subtitle) == "string" then subtitle else nil,
			if typeof(color) == "Color3" then color else nil,
			if typeof(sound) == "string" then sound else nil
		)
	end)
	safeListen("EventFeed", function(richText: any)
		if typeof(richText) == "string" then
			NotificationController.feed(richText)
		end
	end)
	safeListen("CashPopup", function(amount: any, worldPosition: any)
		if typeof(amount) == "number" then
			NotificationController.cashPopup(amount, if typeof(worldPosition) == "Vector3" then worldPosition else nil)
		end
	end)
	safeListen("OfflineEarnings", function(amount: any, seconds: any)
		if typeof(amount) == "number" then
			NotificationController.offlineEarnings(amount, if typeof(seconds) == "number" then seconds else 0)
		end
	end)
	safeListen("CarStolenAlert", function(thiefName: any, carId: any, mutation: any, active: any)
		NotificationController.carStolenAlert(thiefName, carId, mutation, active == true)
	end)

	if player then
		player.CharacterAdded:Connect(function()
			resetAlertCar()
		end)
	end
end

return NotificationController
