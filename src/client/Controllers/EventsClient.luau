--!strict
-- EventsClient (SPEC §7; C4b polish, gta_ui_language §2.8 / §5.7): server events in GTA's language.
--
--   * No more mid-screen pills or banners (job 0006: the orange HOT DROP / RUSH HOUR / CASH RAIN pills covered the
--     crosshair area). Each live event is one quiet row pinned at the GTA feed position, above the radar (in the HUD's
--     feed host, under the newest feed cards; touch: under the help box): a translucent black row, a thin colour rule
--     on the left, the event in sentence case ("Rush hour", "Double cash", "Cash rain at the plaza") and its time left
--     in Kanit, red in the last 10 s. No emoji, no shouting, no pop animations.
--   * The hot drop row has a second grey line: rarity (small, in its GTA hue) + car + distance in metres, or "At the
--     drop" once you are there. The start / landing announcements are the server's Announce feed cards (EventService).
--   * Waypoints: WaypointController.set("hotdrop", ...) for the drop and "cashrain" on the plaza while it lasts (a
--     soft Beam only when WaypointController is missing).
-- Reads state from StateController when available (it caches pushes that arrived before we started), else listens
-- to the remotes directly. Timestamps are Workspace:GetServerTimeNow() based. Presentation only.
-- Public: getBottom(): number? (v1 API, always nil now: nothing sits at the top any more).
-- Pure helpers (tests): Events (alias Pills), pillText, rowView, hotDropView, hotDropPhase, distanceText, dropLine,
--   rarityColor, waypointLabel, carText, stackTop, fitScale (v1 layout maths, kept for the clientcore spec).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared: any = ReplicatedStorage:WaitForChild("Shared")
local Cars = require(Shared.Config.Cars)
local Format = require(Shared.Util.Format)
local MapLayout = require(Shared.Util.MapLayout)
local Net = require(Shared.Net)
local Rarity = require(Shared.Config.Rarity)

local UI: any = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local HudLayout = require(UI.HudLayout)
local RichText = require(UI.RichText)

local player = Players.LocalPlayer
local C = Theme.Colors

local EventsClient = {}

export type EventDef = { label: string, color: Color3, order: number, timer: boolean }

-- Sentence case, like GTA's feed. `timer` = show the time left.
EventsClient.Events = {
	rushHour = { label = "Rush hour", color = C.Yellow, order = 1, timer = true },
	doubleCash = { label = "Double cash", color = C.Green, order = 2, timer = true },
	serverLuck = { label = "Server luck x2", color = C.Blue, order = 3, timer = true },
	cashRain = { label = "Cash rain at the plaza", color = C.Green, order = 4, timer = true },
} :: { [string]: EventDef }
EventsClient.Pills = EventsClient.Events -- v1 name

local BLINK_UNDER = 10 -- the time turns red in the last seconds (GTA timer bars)
local TOP_DEFAULT = 78 -- v1 layout maths (stackTop), design px
local STACK_GAP = 6
local MIN_FIT = 0.6
local CASH_RAIN_WAYPOINT = "cashrain"
local METRES_PER_STUD = 0.28 -- gta_realism_gap §1 (the HUD never says "studs")
local AT_DROP = 30 -- studs: "At the drop"
local ROW_ORDER = 100000 -- pinned under every feed card (the feed host sorts by LayoutOrder)

---------------------------------------------------------------------------------------------------------------------
-- Pure helpers (exported for tests)
---------------------------------------------------------------------------------------------------------------------

-- "Rush hour 1:12" (the row's label and time on one line; nil for an unknown event).
function EventsClient.pillText(name: string, secondsLeft: number): string?
	local def = EventsClient.Events[name]
	if not def then
		return nil
	end
	if def.timer then
		return `{def.label} {Format.clock(math.ceil(math.max(0, secondsLeft)))}`
	end
	return def.label
end

export type RowView = { label: string, value: string, color: Color3, urgent: boolean }

-- What an event row shows (nil for an unknown event).
function EventsClient.rowView(name: string, secondsLeft: number): RowView?
	local def = EventsClient.Events[name]
	if not def then
		return nil
	end
	local left = math.max(0, secondsLeft)
	return {
		label = def.label,
		value = if def.timer then Format.clock(math.ceil(left)) else "",
		color = def.color,
		urgent = def.timer and left <= BLINK_UNDER,
	}
end

export type HotDropPhase = "none" | "countdown" | "live"

-- Phase of a sanitized HotDropState at server time `t`.
function EventsClient.hotDropPhase(state: any, t: number): HotDropPhase
	if typeof(state) ~= "table" then
		return "none"
	end
	if state.active == true and typeof(state.position) == "Vector3" then
		if typeof(state.endsAt) == "number" and state.endsAt < t - 2 then
			return "none" -- stale
		end
		return "live"
	end
	if typeof(state.startsAt) == "number" and typeof(state.position) == "Vector3" then
		if state.startsAt < t - 15 then
			return "none" -- the landing never came (server hiccup)
		end
		return "countdown"
	end
	return "none"
end

-- "420 m" / "1.3 km" from studs (GTA shows metric distances; never "studs").
function EventsClient.distanceText(studs: number): string
	local m = math.max(0, studs) * METRES_PER_STUD
	if m >= 1000 then
		return ("%.1f km"):format(m / 1000)
	end
	return ("%d m"):format(math.floor(m / 10 + 0.5) * 10)
end

-- GTA hue for a hot drop car's rarity (Theme.Rarity: small labels only, never glowing frames).
function EventsClient.rarityColor(carId: string?): Color3
	local def = if carId then Cars.get(carId) else nil
	local hue = def and (Theme.Rarity :: any)[def.rarity]
	return if typeof(hue) == "Color3" then hue else C.Yellow
end

-- "Legendary Halden Wren" as rich text: the rarity in its hue, the car in white (sentence case, no "MYSTERY CAR").
function EventsClient.dropLine(carId: string?, mutation: string?): string
	local def = if carId then Cars.get(carId) else nil
	if not def then
		return "Unknown car"
	end
	local mut = Rarity.getMutation((mutation or "None") :: any)
	local name = RichText.escape(if mut.label ~= "" then mut.label .. " " .. def.name else def.name)
	return RichText.color(RichText.escape(tostring(def.rarity)), EventsClient.rarityColor(carId)) .. " " .. name
end

export type DropView = { label: string, value: string, sub: string, urgent: boolean }

-- The hot drop row for a state at server time `t`, `distance` studs away (nil = unknown). nil when no drop.
function EventsClient.hotDropView(state: any, t: number, distance: number?): DropView?
	local phase = EventsClient.hotDropPhase(state, t)
	if phase == "none" then
		return nil
	end
	local left = if phase == "countdown" then (state.startsAt or t) - t else (state.endsAt or t) - t
	local secs = math.max(0, math.ceil(left))
	local whereText = if distance == nil
		then "Marked on your map"
		elseif distance < AT_DROP then "At the drop"
		else EventsClient.distanceText(distance)
	return {
		label = if phase == "countdown" then "Hot drop lands in" else "Hot drop",
		value = Format.clock(secs),
		sub = EventsClient.dropLine(state.carId, state.mutation) .. "  ·  " .. whereText,
		urgent = phase == "live" and secs <= BLINK_UNDER,
	}
end

function EventsClient.waypointLabel(carId: string?): string
	local def = if carId then Cars.get(carId) else nil
	return if def then "Hot drop: " .. def.name else "Hot drop"
end

-- v1 helper (kept: other packages' specs pin it): "COMMON • GOLD <name>".
function EventsClient.carText(carId: string?, mutation: string?): string
	local def = if carId then Cars.get(carId) else nil
	if not def then
		return "MYSTERY CAR"
	end
	local mut = Rarity.getMutation((mutation or "None") :: any)
	local name = if mut.label ~= "" then mut.label .. " " .. def.name else def.name
	return string.upper(def.rarity) .. " • " .. name
end

-- v1 layout maths (the top-centre stack is gone; kept for the clientcore spec).
function EventsClient.stackTop(hudBottom: number?, alertBottom: number?, scale: number): number
	local s = if scale > 0 then scale else 1
	local real = math.max(hudBottom or 0, alertBottom or 0)
	if real <= 0 then
		return TOP_DEFAULT
	end
	return math.max(TOP_DEFAULT, math.ceil(real / s) + STACK_GAP)
end

function EventsClient.fitScale(top: number, needed: number, limit: number): number
	if needed <= 0 then
		return 1
	end
	return math.clamp((limit - top) / needed, MIN_FIT, 1)
end

---------------------------------------------------------------------------------------------------------------------
-- Lazy controllers
---------------------------------------------------------------------------------------------------------------------

local lazyCache: { [string]: any } = {}
local function lazyController(name: string): any
	local cached = lazyCache[name]
	if cached ~= nil then
		return cached or nil
	end
	local mod = script.Parent:FindFirstChild(name)
	if not mod then
		return nil -- not built (yet); look again next time
	end
	local ok, result = pcall(require, mod :: any)
	lazyCache[name] = if ok and typeof(result) == "table" then result else false
	return if ok and typeof(result) == "table" then result else nil
end

local function hudHidden(): boolean
	local hud = lazyController("HUDController")
	if hud and typeof(hud.isHidden) == "function" then
		local ok, v = pcall(hud.isHidden)
		if ok then
			return v == true
		end
	end
	return false
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

---------------------------------------------------------------------------------------------------------------------
-- Rows at the feed position
---------------------------------------------------------------------------------------------------------------------

type Row = { frame: Frame, rule: Frame, label: TextLabel, value: TextLabel, sub: TextLabel?, closing: boolean }

local rows: { [string]: Row } = {}
local fallbackHost: Frame? = nil

-- The HUD's feed host (above the radar; touch: under the help box) and the feed width; a small own screen at the same
-- spot until the HUD exists.
local function feedHost(): (Frame, number)
	local touch = Kit.isTouch()
	local width = if touch then HudLayout.FEED_W_TOUCH else HudLayout.FEED_W
	local hud = lazyController("HUDController")
	if hud and typeof(hud.getFeedHost) == "function" then
		local ok, host = pcall(hud.getFeedHost)
		if ok and typeof(host) == "Instance" and host:IsA("Frame") then
			if typeof(hud.getLayout) == "function" then
				local okL, L = pcall(hud.getLayout)
				if okL and typeof(L) == "table" and typeof(L.feed) == "table" then
					width = L.feed.w
				end
			end
			return host, width
		end
	end
	local f = fallbackHost
	if f and f.Parent then
		return f, width
	end
	local gui = Kit.screen("HC_Events", Theme.Layers.Feed, { touchMin = Theme.TouchMinScale })
	local L = HudLayout.compute(1280, 720, touch)
	local host = Kit.new("Frame", {
		Name = "Events",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(L.feed.x, L.feed.y),
		Size = UDim2.fromOffset(L.feed.w, L.feed.h),
		Parent = gui,
	}, {
		Kit.list(
			Enum.FillDirection.Vertical,
			4,
			Enum.HorizontalAlignment.Left,
			if touch then Enum.VerticalAlignment.Top else Enum.VerticalAlignment.Bottom
		),
	})
	fallbackHost = host
	return host, width
end

local function makeRow(id: string, order: number, twoLines: boolean): Row
	local host, width = feedHost()
	local touch = Kit.isTouch()
	local lineH = if touch then 28 else 26
	local frame = Kit.panel({
		Name = "Event_" .. id,
		Size = UDim2.fromOffset(width, if twoLines then lineH + 16 else lineH),
		LayoutOrder = ROW_ORDER + order,
		Active = false,
		Parent = host,
	})
	local rule = Kit.new("Frame", {
		Name = "Rule",
		Size = UDim2.new(0, 3, 1, 0),
		BackgroundColor3 = C.Text,
		BorderSizePixel = 0,
		Parent = frame,
	})
	local label = Kit.text("", "body", if touch then 14 else 13, {
		Name = "Label",
		Position = UDim2.fromOffset(11, 0),
		Size = UDim2.new(1, -78, 0, lineH),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = frame,
	})
	local value = Kit.text("", "numeric", if touch then 17 else 16, {
		Name = "Value",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 0),
		Size = UDim2.fromOffset(64, lineH),
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = frame,
	})
	local outline = value:FindFirstChild("Outline")
	if outline then
		outline:Destroy() -- digits on a panel need no outline (GTA timer bars)
	end
	local sub: TextLabel? = nil
	if twoLines then
		sub = Kit.text("", "body", if touch then 13 else 12, {
			Name = "Sub",
			Position = UDim2.fromOffset(11, lineH - 6),
			Size = UDim2.new(1, -19, 0, 18),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = C.TextDim,
			Parent = frame,
		})
	end
	Kit.fadeTree(frame, 1, 0)
	Kit.fadeTree(frame, 0, 0.25)
	return { frame = frame, rule = rule, label = label, value = value, sub = sub, closing = false }
end

local function ensureRow(id: string, order: number, twoLines: boolean): Row
	local row = rows[id]
	if row and not row.closing and row.frame.Parent then
		local host = feedHost()
		if row.frame.Parent ~= host then
			row.frame.Parent = host -- the HUD (re)built its feed host
		end
		return row
	end
	local made = makeRow(id, order, twoLines)
	rows[id] = made
	return made
end

local function closeRow(id: string)
	local row = rows[id]
	if not row or row.closing then
		return
	end
	row.closing = true
	rows[id] = nil
	Kit.fadeTree(row.frame, 1, 0.3)
	task.delay(0.32, function()
		row.frame:Destroy()
	end)
end

local eventState: { [string]: number } = {}
local hotDrop: any = { active = false }

local function updateRows(t: number)
	for name, endsAt in eventState do
		local def = EventsClient.Events[name]
		local view = EventsClient.rowView(name, endsAt - t)
		if def and view and endsAt > t then
			local row = ensureRow(name, def.order, false)
			row.label.Text = view.label
			row.value.Text = view.value
			row.value.TextColor3 = if view.urgent then C.Red else C.Text
			row.rule.BackgroundColor3 = view.color
		end
	end
	for id in rows do
		if id ~= "hotDrop" then
			local endsAt = eventState[id]
			if not endsAt or endsAt <= t then
				closeRow(id)
			end
		end
	end
	-- hot drop
	local dist: number? = nil
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") and typeof(hotDrop.position) == "Vector3" then
		dist = (root.Position - hotDrop.position).Magnitude
	end
	local drop = EventsClient.hotDropView(hotDrop, t, dist)
	if drop then
		local row = ensureRow("hotDrop", 0, true)
		row.label.Text = drop.label
		row.value.Text = drop.value
		row.value.TextColor3 = if drop.urgent then C.Red else C.Text
		row.rule.BackgroundColor3 = EventsClient.rarityColor(hotDrop.carId)
		local sub = row.sub
		if sub then
			sub.Text = drop.sub
		end
	else
		closeRow("hotDrop")
	end
end

-- v1 API: real px bottom of a top-of-screen stack. Nothing sits at the top any more.
function EventsClient.getBottom(): number?
	return nil
end

---------------------------------------------------------------------------------------------------------------------
-- Waypoint (WaypointController if present, else a soft local Beam)
---------------------------------------------------------------------------------------------------------------------

local beamParts: { Instance } = {}
local beamTarget: Vector3? = nil
local beamColor: Color3 = C.Yellow

local function clearBeam()
	for _, inst in beamParts do
		inst:Destroy()
	end
	table.clear(beamParts)
end

local function buildBeam()
	clearBeam()
	local target = beamTarget
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not target or not root or not root:IsA("BasePart") then
		return
	end
	local cam = Workspace.CurrentCamera
	local anchor = Instance.new("Part")
	anchor.Name = "HotDropWaypoint"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = CFrame.new(target + Vector3.new(0, 6, 0))
	anchor.Parent = cam or Workspace
	local a1 = Instance.new("Attachment")
	a1.Parent = anchor
	local a0 = Instance.new("Attachment")
	a0.Name = "HotDropBeamFrom"
	a0.Position = Vector3.new(0, -2, 0)
	a0.Parent = root
	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Color = ColorSequence.new(beamColor)
	beam.LightEmission = 0.2
	beam.LightInfluence = 0.6
	beam.FaceCamera = true
	beam.Width0 = 0.6
	beam.Width1 = 1.2
	beam.Segments = 1
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.9),
		NumberSequenceKeypoint.new(0.15, 0.55),
		NumberSequenceKeypoint.new(1, 0.45),
	})
	beam.Parent = anchor
	table.insert(beamParts, anchor)
	table.insert(beamParts, a0)
end

-- WaypointController auto-clears "hotdrop" whenever HotDropState is not active (i.e. during the countdown), which
-- can race our countdown waypoint depending on handler order: re-assert it while a drop is pending/live.
local function ensureWaypoint(t: number)
	if EventsClient.hotDropPhase(hotDrop, t) == "none" then
		return
	end
	local wc = lazyController("WaypointController")
	if wc and typeof(wc.has) == "function" and typeof(wc.set) == "function" then
		local ok, has = pcall(wc.has, "hotdrop")
		if ok and not has then
			pcall(
				wc.set,
				"hotdrop",
				hotDrop.position,
				EventsClient.rarityColor(hotDrop.carId),
				EventsClient.waypointLabel(hotDrop.carId)
			)
		end
	end
end

local function setWaypoint(position: Vector3?, color: Color3)
	local wc = lazyController("WaypointController")
	if wc and typeof(wc.set) == "function" then
		clearBeam()
		beamTarget = nil
		if position then
			pcall(wc.set, "hotdrop", position, color, EventsClient.waypointLabel(hotDrop.carId))
		elseif typeof(wc.clear) == "function" then
			pcall(wc.clear, "hotdrop")
		else
			pcall(wc.set, "hotdrop", nil)
		end
		return
	end
	if position == beamTarget and color == beamColor then
		return
	end
	beamTarget = position
	beamColor = color
	buildBeam()
end

---------------------------------------------------------------------------------------------------------------------
-- State handling
---------------------------------------------------------------------------------------------------------------------

local lastPhase: HotDropPhase = "none"

local function onHotDrop(state: any)
	hotDrop = if typeof(state) == "table" then state else { active = false }
	local t = serverNow()
	local phase = EventsClient.hotDropPhase(hotDrop, t)
	if phase == "none" then
		setWaypoint(nil, C.Yellow)
	else
		setWaypoint(hotDrop.position, EventsClient.rarityColor(hotDrop.carId))
	end
	lastPhase = phase
	updateRows(t)
end

-- Cash rain lasts 45 s at the plaza and players spawn in their garages: mark the plaza while it is on.
local cashRainMarked = false
local function updateCashRainWaypoint(t: number)
	local endsAt = eventState.cashRain
	local want = typeof(endsAt) == "number" and endsAt > t
	if want == cashRainMarked then
		return
	end
	local wc = lazyController("WaypointController")
	if not wc then
		return
	end
	if want then
		local ok, plaza = pcall(MapLayout.poiCenter, "SpawnPlaza")
		if ok and typeof(plaza) == "Vector3" and typeof(wc.set) == "function" then
			pcall(wc.set, CASH_RAIN_WAYPOINT, plaza, C.Green, "Cash rain")
			cashRainMarked = true
		end
	else
		if typeof(wc.clear) == "function" then
			pcall(wc.clear, CASH_RAIN_WAYPOINT)
		end
		cashRainMarked = false
	end
end

local function onEventState(state: any)
	local clean: { [string]: number } = {}
	if typeof(state) == "table" then
		for k, v in state do
			if typeof(k) == "string" and typeof(v) == "number" and v == v then
				clean[k] = v
			end
		end
	end
	eventState = clean
	local t = serverNow()
	updateRows(t)
	updateCashRainWaypoint(t)
end

function EventsClient.init() end

function EventsClient.start()
	local sc = lazyController("StateController")
	if sc and sc.HotDropChanged and sc.EventStateChanged then
		sc.HotDropChanged:Connect(onHotDrop)
		sc.EventStateChanged:Connect(onEventState)
		if typeof(sc.getHotDrop) == "function" then
			onHotDrop(sc.getHotDrop())
		end
		if typeof(sc.getEventState) == "function" then
			onEventState(sc.getEventState())
		end
	else
		Net.listen("HotDropState", onHotDrop)
		Net.listen("EventState", onEventState)
	end

	player.CharacterAdded:Connect(function()
		task.wait(0.5)
		if beamTarget then
			buildBeam()
		end
	end)

	while true do
		task.wait(0.25)
		local t = serverNow()
		local fb = fallbackHost
		if fb then
			local gui = fb:FindFirstAncestorOfClass("ScreenGui")
			if gui then
				gui.Enabled = not hudHidden()
			end
		end
		updateRows(t)
		ensureWaypoint(t)
		updateCashRainWaypoint(t)
		if lastPhase ~= "none" and EventsClient.hotDropPhase(hotDrop, t) == "none" then
			lastPhase = "none"
			setWaypoint(nil, C.Yellow)
		end
	end
end

return EventsClient
