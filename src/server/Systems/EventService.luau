--!strict
-- EventService (SPEC §6): server-wide "everyone rush over there" moments.
--
--   * HOT DROP   - every HOT_DROP_INTERVAL: countdown (Announce + HotDropState{active=false,startsAt,...}) with a giant
--                  neon beacon already standing on the landing spot, then a Legendary+ car drops out of the sky
--                  (VehicleService.spawn kind "HotDrop", anchored). First to hold the CLAIM prompt for HOT_DROP_HOLD
--                  seconds drives it away as Loot with +hotDrop wanted. Unclaimed drops vanish after the lifetime.
--   * CASH RAIN  - money bags fall around the Spawn Plaza; touching one (on foot or driving through it) pays
--                  max($250, CASH_RAIN_BAG_SECONDS of the collector's income). Each bag pays once.
--   * RUSH HOUR  - more traffic (getTrafficMultiplier) + luck boost (getLuck).
--   * 2X CASH    - getIncomeMultiplier() = 2 (GarageService applies it to every garage).
--   * SERVER LUCK - Robux product: luck x2 for 15 min for EVERYONE, duration stacks, buyer announced.
--
-- All timestamps sent to clients (startsAt / endsAt) are Workspace:GetServerTimeNow() seconds.
-- EventState payload: { [eventName]: endsAt } with eventName in hotDrop | rushHour | doubleCash | serverLuck | cashRain
-- (only active events are present). Sent to everyone on change and to each joining player.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Cars = require(Shared.Config.Cars)
local Events = require(Shared.Config.Events)
local Format = require(Shared.Util.Format)
local MapLayout = require(Shared.Util.MapLayout)
local Monetization = require(Shared.Config.Monetization)
local Net = require(Shared.Net)
local Police = require(Shared.Config.Police)
local Rarity = require(Shared.Config.Rarity)
local Rolls = require(Shared.Util.Rolls)
local Signal = require(Shared.Util.Signal)

local EventService = {}

-- Tunables that are not in Config/Events (presentation / pacing details) -------------------------------------------
EventService.FIRST_DELAYS = {
	hotDrop = { 150, 240 }, -- first hot drop comes sooner than the regular interval so new servers get a moment fast
	cashRain = { 300, 480 },
	rushHour = { 240, 420 },
	doubleCash = { 600, 1200 },
}
EventService.AUTO_GAP = 20 -- seconds between two automatic event starts (keeps banners from stacking)
EventService.EMPTY_SERVER_DELAY = 60 -- an event never auto-starts sooner than this after the first player joins
EventService.BEACON_HEIGHT = 300
EventService.BEACON_GAP = 16 -- the beam starts this high so the landed car underneath stays visible
EventService.DROP_HEIGHT = 90 -- the hot drop car falls from this high
EventService.DROP_TIME = 0.9
EventService.BAG_RADIUS = { 14, 58 } -- cash bags land in this ring around the plaza center
EventService.BAG_DROP_HEIGHT = { 55, 85 }
EventService.BAG_LINGER = 15 -- seconds leftover bags stay after the rain ends
EventService.BAG_ANCHOR_AFTER = 4 -- landed bags are anchored after this long (no physics cost)
EventService.BAG_PICKUP_RADIUS = 5.5
EventService.MIN_BAG_VALUE = 250
EventService.LUCK_REROLL_FRACTION = 0.5 -- share of out-of-view parked cars re-rolled when a luck event starts
EventService.LANDING_CLEAR_PLAYERS = 10 -- players on foot this close to the landing spot are nudged out...
EventService.LANDING_PUSH_PLAYERS = 14 -- ...to this distance
EventService.LANDING_CLEAR_CARS = 16 -- driverless cars this close are cleared / moved aside...
EventService.LANDING_PUSH_CARS = 18 -- ...to this distance (still inside the 40-stud intersection)

-- Lazy system access (no require cycles; tolerant of a missing/broken system) -------------------------------------
local systemCache: { [string]: any } = {}
local function sys(name: string): any
	local cached = systemCache[name]
	if cached then
		return cached
	end
	local parent = script.Parent
	local inst = parent and parent:FindFirstChild(name)
	if not inst then
		return nil
	end
	local ok, mod = pcall(require, inst)
	if ok and typeof(mod) == "table" then
		systemCache[name] = mod
		return mod
	end
	warn(("[EventService] could not load %s: %s"):format(name, tostring(mod)))
	return nil
end

-- Test seam: replace a system module seen by sys(). Never used at runtime.
function EventService._inject(name: string, mod: any)
	systemCache[name] = mod
end

-- Calls system.fn(...) under pcall. Returns (ok, result).
local function call(name: string, fnName: string, ...: any): (boolean, any)
	local mod = sys(name)
	local fn = mod and mod[fnName]
	if typeof(fn) ~= "function" then
		return false, nil
	end
	local ok, res = pcall(fn, ...)
	if not ok then
		warn(("[EventService] %s.%s failed: %s"):format(name, fnName, tostring(res)))
	end
	return ok, res
end

local function now(): number
	return Workspace:GetServerTimeNow()
end

local rng = Random.new()

---------------------------------------------------------------------------------------------------------------------
-- Pure helpers (exported for tests)
---------------------------------------------------------------------------------------------------------------------

function EventService._isActive(endsAt: number?, t: number): boolean
	return typeof(endsAt) == "number" and endsAt > t
end

-- Combined luck: server luck product x2, rush hour x RUSH_HOUR_LUCK, never below 1.
function EventService._luck(t: number, serverLuckEndsAt: number, rushHourEndsAt: number): number
	local luck = 1
	if serverLuckEndsAt > t then
		luck *= 2
	end
	if rushHourEndsAt > t then
		luck *= Events.RUSH_HOUR_LUCK
	end
	return math.max(1, luck)
end

function EventService._incomeMultiplier(t: number, doubleCashEndsAt: number): number
	return if doubleCashEndsAt > t then 2 else 1
end

function EventService._trafficMultiplier(t: number, rushHourEndsAt: number): number
	return if rushHourEndsAt > t then Events.RUSH_HOUR_TRAFFIC_MULT else 1
end

-- New end time when a duration is added to a (possibly running) timer: stacks onto the remaining time.
function EventService._stack(currentEndsAt: number, t: number, duration: number): number
	return math.max(currentEndsAt, t) + duration
end

-- Server-side hold check for a hold prompt: the hold began (t0), lasted at least ~`required` seconds and is not a
-- stale arm from long ago (a tap now + a Triggered much later with a locally zeroed HoldDuration).
function EventService._holdValid(t0: number?, t: number, required: number): boolean
	if t0 == nil then
		return false
	end
	local held = t - t0
	return held >= required * 0.9 and held <= required / 0.9 + 1.5
end

-- Cash one bag pays: CASH_RAIN_BAG_SECONDS of income, at least MIN_BAG_VALUE.
function EventService._bagValue(incomePerSec: number): number
	local income = if typeof(incomePerSec) == "number" and incomePerSec == incomePerSec then incomePerSec else 0
	return math.max(EventService.MIN_BAG_VALUE, math.floor(math.max(0, income) * Events.CASH_RAIN_BAG_SECONDS))
end

-- Rolls the hot drop car: weighted HOT_DROP_RARITY tier, any non-exclusive car of it, boosted mutation.
function EventService._rollHotDrop(r: Random): (string, Rarity.MutationId, Rarity.RarityId)
	local rarity: Rarity.RarityId = (Rolls.weighted(Events.HOT_DROP_RARITY :: any, r) :: any) or "Legendary"
	local def = Rolls.carOfRarity(rarity, "any", r)
	local mutation = Rolls.mutation(Events.HOT_DROP_MUTATION_BOOST, r)
	return def.id, mutation, def.rarity
end

-- Picks a landing point index: random, never the previous one, skipping blocked points when possible.
function EventService._pickDropIndex(
	count: number,
	lastIndex: number?,
	r: Random,
	isBlocked: ((number) -> boolean)?
): number
	if count <= 1 then
		return 1
	end
	local candidates = {}
	for i = 1, count do
		if i ~= lastIndex and not (isBlocked and isBlocked(i)) then
			table.insert(candidates, i)
		end
	end
	if #candidates == 0 then
		for i = 1, count do
			if i ~= lastIndex then
				table.insert(candidates, i)
			end
		end
	end
	return candidates[r:NextInteger(1, #candidates)]
end

-- Builds the EventState payload: only active events, value = endsAt.
function EventService._eventState(t: number, timers: { [string]: number }, hotDropEndsAt: number?): { [string]: number }
	local out: { [string]: number } = {}
	for name, endsAt in timers do
		if endsAt > t then
			out[name] = endsAt
		end
	end
	if hotDropEndsAt and hotDropEndsAt > t then
		out.hotDrop = hotDropEndsAt
	end
	return out
end

-- Resolves an admin / generic event name ("Hot Drop", "2x-cash", "rushhour", "luck"...) to a canonical name.
local EVENT_ALIASES: { [string]: string } = {
	hotdrop = "hotDrop",
	drop = "hotDrop",
	hot = "hotDrop",
	cashrain = "cashRain",
	rain = "cashRain",
	moneyrain = "cashRain",
	rushhour = "rushHour",
	rush = "rushHour",
	traffic = "rushHour",
	doublecash = "doubleCash",
	["2xcash"] = "doubleCash",
	x2cash = "doubleCash",
	double = "doubleCash",
	["2x"] = "doubleCash",
	luck = "serverLuck",
	serverluck = "serverLuck",
}

function EventService._resolveEvent(name: any): string?
	if typeof(name) ~= "string" or #name > 40 then
		return nil
	end
	local key = string.lower(name):gsub("[^%w]", "")
	return EVENT_ALIASES[key]
end

local function prop(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
end

local function vertical(pos: Vector3): CFrame
	-- Cylinder axis is local X; rotate so it stands up.
	return CFrame.new(pos) * CFrame.Angles(0, 0, math.pi / 2)
end

-- Builds the hot drop beacon (harness-compatible: pure instance construction). `groundCFrame` is on the road.
-- Children: Pillar, Core, Ring, RingInner, Glow (PointLight), Label (BillboardGui "BeaconGui" with Title/Sub).
function EventService._buildBeacon(groundCFrame: CFrame, color: Color3, rarityText: string): Model
	local base = groundCFrame.Position
	local h = EventService.BEACON_HEIGHT
	local model = Instance.new("Model")
	model.Name = "HotDropBeacon"

	local pillar = Instance.new("Part")
	pillar.Name = "Pillar"
	pillar.Shape = Enum.PartType.Cylinder
	-- the beam hovers above the landing car (so the car stays clearly visible) and reaches the sky
	local gap = EventService.BEACON_GAP
	local beamLen = h - gap
	pillar.Size = Vector3.new(beamLen, 7, 7)
	pillar.CFrame = vertical(base + Vector3.new(0, gap + beamLen / 2, 0))
	pillar.Material = Enum.Material.Neon
	pillar.Color = color
	pillar.Transparency = 0.62
	prop(pillar)
	pillar.Parent = model

	local core = Instance.new("Part")
	core.Name = "Core"
	core.Shape = Enum.PartType.Cylinder
	core.Size = Vector3.new(beamLen, 2.2, 2.2)
	core.CFrame = vertical(base + Vector3.new(0, gap + beamLen / 2, 0))
	core.Material = Enum.Material.Neon
	core.Color = color:Lerp(Color3.new(1, 1, 1), 0.55)
	core.Transparency = 0.3
	prop(core)
	core.Parent = model

	local ring = Instance.new("Part")
	ring.Name = "Ring"
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.3, 34, 34)
	ring.CFrame = vertical(base + Vector3.new(0, 0.2, 0))
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Transparency = 0.2
	prop(ring)
	ring.Parent = model

	local inner = Instance.new("Part")
	inner.Name = "RingInner"
	inner.Shape = Enum.PartType.Cylinder
	inner.Size = Vector3.new(0.34, 27, 27)
	inner.CFrame = vertical(base + Vector3.new(0, 0.22, 0))
	inner.Material = Enum.Material.SmoothPlastic
	inner.Color = Color3.fromRGB(24, 22, 40)
	inner.Transparency = 0.15
	prop(inner)
	inner.Parent = model

	-- four chevrons on the ring pointing at the center ("land here")
	for i = 0, 3 do
		local yaw = i * math.pi / 2
		local chev = Instance.new("WedgePart")
		chev.Name = "Chevron"
		chev.Size = Vector3.new(4, 0.4, 5)
		-- wedge slope faces local -Z; lay it flat and point it inward
		local at = base + Vector3.new(math.sin(yaw) * 15.5, 0.45, math.cos(yaw) * 15.5)
		chev.CFrame = CFrame.lookAt(at, base + Vector3.new(0, 0.45, 0))
		chev.Material = Enum.Material.Neon
		chev.Color = Color3.new(1, 1, 1)
		prop(chev)
		chev.Parent = model
	end

	local glow = Instance.new("Part")
	glow.Name = "Glow"
	glow.Size = Vector3.new(1, 1, 1)
	glow.CFrame = CFrame.new(base + Vector3.new(0, 9, 0))
	glow.Transparency = 1
	prop(glow)
	local light = Instance.new("PointLight")
	light.Name = "Light"
	light.Range = 48
	light.Brightness = 4
	light.Color = color
	light.Shadows = false
	light.Parent = glow
	glow.Parent = model

	local label = Instance.new("Part")
	label.Name = "Label"
	label.Size = Vector3.new(1, 1, 1)
	label.CFrame = CFrame.new(base + Vector3.new(0, 30, 0))
	label.Transparency = 1
	prop(label)
	local gui = Instance.new("BillboardGui")
	gui.Name = "BeaconGui"
	gui.Size = UDim2.fromOffset(260, 92)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 3000
	gui.LightInfluence = 0
	gui.Parent = label
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.fromScale(1, 0.6)
	title.Text = "🔥 HOT DROP"
	title.TextScaled = true
	title.FontFace = Font.fromEnum(Enum.Font.FredokaOne)
	title.TextColor3 = Color3.new(1, 1, 1)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(10, 11, 22)
	stroke.Parent = title
	title.Parent = gui
	local sub = Instance.new("TextLabel")
	sub.Name = "Sub"
	sub.BackgroundTransparency = 1
	sub.Position = UDim2.fromScale(0, 0.6)
	sub.Size = UDim2.fromScale(1, 0.4)
	sub.Text = rarityText
	sub.TextScaled = true
	sub.FontFace = Font.fromEnum(Enum.Font.FredokaOne)
	sub.TextColor3 = color
	local stroke2 = Instance.new("UIStroke")
	stroke2.Thickness = 2.5
	stroke2.Color = Color3.fromRGB(10, 11, 22)
	stroke2.Parent = sub
	sub.Parent = gui
	label.Parent = model

	model.PrimaryPart = ring
	return model
end

-- Builds one falling money bag (root part "CashBag" + welded "Tie" + billboard + sparkle). Unparented, unanchored.
function EventService._buildBag(position: Vector3): BasePart
	local bag = Instance.new("Part")
	bag.Name = "CashBag"
	bag.Shape = Enum.PartType.Ball
	bag.Size = Vector3.new(2.6, 2.6, 2.6)
	bag.CFrame = CFrame.new(position)
	bag.Color = Color3.fromRGB(214, 176, 104)
	bag.Material = Enum.Material.Fabric
	bag.CanCollide = true
	bag.CanQuery = false
	bag.CanTouch = true
	bag.CastShadow = true
	bag.Anchored = false
	bag:SetAttribute("CashBag", true)

	-- tied neck (thin neon band) + flared sack top: the classic cartoon money-bag silhouette
	local function deco(name: string, size: Vector3, offset: number, color: Color3, material: Enum.Material)
		local p = Instance.new("Part")
		p.Name = name
		p.Shape = Enum.PartType.Cylinder
		p.Size = size
		p.CFrame = CFrame.new(position + Vector3.new(0, offset, 0)) * CFrame.Angles(0, 0, math.pi / 2)
		p.Color = color
		p.Material = material
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Massless = true
		p.Anchored = false
		p.Parent = bag
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = bag
		weld.Part1 = p
		weld.Parent = p
	end
	deco("Tie", Vector3.new(0.35, 1.05, 1.05), 1.3, Color3.fromRGB(70, 235, 110), Enum.Material.Neon)
	deco("Top", Vector3.new(0.6, 1.7, 1.7), 1.75, Color3.fromRGB(214, 176, 104), Enum.Material.Fabric)

	local gui = Instance.new("BillboardGui")
	gui.Name = "BagGui"
	gui.Size = UDim2.fromScale(3.4, 3.4)
	gui.StudsOffset = Vector3.new(0, 3, 0)
	gui.MaxDistance = 260
	gui.LightInfluence = 0
	gui.Parent = bag
	local icon = Instance.new("TextLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.fromScale(1, 1)
	icon.Text = "💰"
	icon.TextScaled = true
	icon.Parent = gui

	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Name = "Sparkle"
	sparkle.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparkle.Rate = 5
	sparkle.Lifetime = NumberRange.new(0.5, 0.9)
	sparkle.Speed = NumberRange.new(1.5, 3)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle.LightEmission = 1
	sparkle.Color = ColorSequence.new(Color3.fromRGB(120, 255, 150), Color3.fromRGB(255, 225, 90))
	sparkle.Size = NumberSequence.new(0.55, 0)
	sparkle.Parent = bag
	return bag
end

---------------------------------------------------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------------------------------------------------

type HotDrop = {
	token: number,
	phase: string, -- "countdown" | "live"
	carId: string,
	mutation: Rarity.MutationId,
	rarity: Rarity.RarityId,
	cframe: CFrame,
	position: Vector3,
	pointIndex: number,
	startsAt: number,
	endsAt: number?,
	car: any?,
	beacon: Model?,
	prompt: Instance?,
	claimed: boolean,
}

type BagRec = { bag: BasePart, token: number, spawnedAt: number, collected: boolean, anchored: boolean }

local timers: { [string]: number } = { rushHour = 0, doubleCash = 0, serverLuck = 0, cashRain = 0 }
local nextAt: { [string]: number } =
	{ hotDrop = math.huge, cashRain = math.huge, rushHour = math.huge, doubleCash = math.huge }
local hotDrop: HotDrop? = nil
local hotDropToken = 0
local lastDropIndex: number? = nil
local rainToken = 0
local bags: { [BasePart]: BagRec } = {}
local lastAutoStart = -math.huge
local lastSignature = ""
local started = false

-- Fired whenever EventState changes: (state: {[name]: endsAt}).
EventService.Changed = Signal.new()
-- Fired when someone claims a hot drop: (player, car).
EventService.HotDropClaimed = Signal.new()

local function effectsFolder(): Folder
	local f = Workspace:FindFirstChild("Effects")
	if f and f:IsA("Folder") then
		return f
	end
	local folder = Instance.new("Folder")
	folder.Name = "Effects"
	folder.Parent = Workspace
	return folder
end

local function richEscape(s: string): string
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function carLabel(carId: string, mutation: string): string
	local def = Cars.get(carId)
	local name = if def then def.name else carId
	local mut = Rarity.getMutation(mutation :: any)
	if mut.label ~= "" then
		return mut.label .. " " .. name
	end
	return name
end

local function rarityColor(rarity: Rarity.RarityId): Color3
	local tier = Rarity.Tiers[rarity]
	local c = if tier then tier.color else Color3.fromRGB(255, 190, 40)
	if rarity == "Secret" then
		-- Secret's catalog color is near-black; a black beacon is invisible at night
		return Color3.fromRGB(190, 120, 255)
	end
	return c
end

local function announce(title: string, subtitle: string?, color: Color3?, sound: string?)
	Net.fireAll("Announce", title, subtitle, color, sound)
end

local function feed(text: string)
	Net.fireAll("EventFeed", text)
end

local function scheduleNext(name: string, range: { number })
	nextAt[name] = now() + rng:NextNumber(range[1], range[2])
end

---------------------------------------------------------------------------------------------------------------------
-- Public getters (cheap; called every income tick / spawn roll)
---------------------------------------------------------------------------------------------------------------------

function EventService.getLuck(): number
	return EventService._luck(now(), timers.serverLuck, timers.rushHour)
end

function EventService.getIncomeMultiplier(): number
	return EventService._incomeMultiplier(now(), timers.doubleCash)
end

function EventService.getTrafficMultiplier(): number
	return EventService._trafficMultiplier(now(), timers.rushHour)
end

-- Extra: is a timed event (rushHour/doubleCash/serverLuck/cashRain) or "hotDrop" currently running?
function EventService.isActive(name: string): boolean
	if name == "hotDrop" then
		return hotDrop ~= nil
	end
	local endsAt = timers[name]
	return endsAt ~= nil and endsAt > now()
end

-- Extra: current EventState payload.
function EventService.getState(): { [string]: number }
	local hd = hotDrop
	return EventService._eventState(now(), timers, if hd and hd.phase == "live" then hd.endsAt else nil)
end

local function hotDropPayload(): { [string]: any }
	local hd = hotDrop
	if not hd then
		return { active = false }
	end
	return {
		active = hd.phase == "live",
		position = hd.position,
		carId = hd.carId,
		mutation = hd.mutation,
		startsAt = hd.startsAt,
		endsAt = hd.endsAt,
	}
end

-- Extra: current HotDropState payload.
function EventService.getHotDropState(): { [string]: any }
	return hotDropPayload()
end

local function signature(state: { [string]: number }): string
	local parts = {}
	for name, endsAt in state do
		table.insert(parts, name .. "=" .. tostring(math.floor(endsAt)))
	end
	table.sort(parts)
	return table.concat(parts, ";")
end

local function broadcastEventState(force: boolean?)
	local state = EventService.getState()
	local sig = signature(state)
	if not force and sig == lastSignature then
		return
	end
	lastSignature = sig
	Net.fireAll("EventState", state)
	EventService.Changed:Fire(state)
end

local function broadcastHotDrop()
	Net.fireAll("HotDropState", hotDropPayload())
end

local function sendStateTo(player: Player)
	if player.Parent ~= Players then
		return
	end
	Net.fireClient("EventState", player, EventService.getState())
	Net.fireClient("HotDropState", player, hotDropPayload())
end

---------------------------------------------------------------------------------------------------------------------
-- Hot Drop
---------------------------------------------------------------------------------------------------------------------

local function setBeaconText(hd: HotDrop, title: string, sub: string?)
	local beacon = hd.beacon
	local label = beacon and beacon:FindFirstChild("Label")
	local gui = label and label:FindFirstChild("BeaconGui")
	if not gui then
		return
	end
	local t = gui:FindFirstChild("Title")
	if t and t:IsA("TextLabel") then
		t.Text = title
	end
	local s = gui:FindFirstChild("Sub")
	if sub and s and s:IsA("TextLabel") then
		s.Text = sub
	end
end

local function setBeaconLive(hd: HotDrop)
	local beacon = hd.beacon
	if not beacon then
		return
	end
	local pillar = beacon:FindFirstChild("Pillar")
	if pillar and pillar:IsA("BasePart") then
		pillar.Transparency = 0.4
	end
	local core = beacon:FindFirstChild("Core")
	if core and core:IsA("BasePart") then
		core.Transparency = 0.05
	end
	local glow = beacon:FindFirstChild("Glow")
	local light = glow and glow:FindFirstChild("Light")
	if light and light:IsA("PointLight") then
		light.Brightness = 7
	end
end

local function clearHotDrop(hd: HotDrop)
	if hotDrop ~= hd then
		return
	end
	hotDrop = nil
	if hd.beacon then
		hd.beacon:Destroy()
		hd.beacon = nil
	end
	if hd.prompt and hd.prompt.Parent then
		hd.prompt:Destroy()
	end
	hd.prompt = nil
	broadcastHotDrop()
	Net.fireAll("Waypoint", "hotdrop", nil)
	broadcastEventState()
	scheduleNext("hotDrop", Events.HOT_DROP_INTERVAL)
end

local function expireHotDrop(hd: HotDrop, reason: string)
	if hotDrop ~= hd or hd.claimed then
		return
	end
	local car = hd.car
	clearHotDrop(hd)
	if car and car.model and car.model.Parent then
		local ok = call("VehicleService", "destroy", car, "expired")
		if not ok and car.model then
			car.model:Destroy()
		end
	end
	if reason == "expired" then
		feed("Nobody claimed the hot drop. It's gone.")
	end
end

local function setKind(car: any, kind: string)
	local V = sys("VehicleService")
	if V and typeof(V.setKind) == "function" then
		local ok, err = pcall(V.setKind, car, kind)
		if ok then
			return
		end
		warn("[EventService] VehicleService.setKind failed: " .. tostring(err))
	end
	car.kind = kind
	if car.model then
		car.model:SetAttribute("Kind", kind)
	end
end

local function removeClaimPrompts(hd: HotDrop)
	if hd.prompt and hd.prompt.Parent then
		hd.prompt:Destroy()
	end
	hd.prompt = nil
	local car = hd.car
	if car and car.model then
		for _, d in car.model:GetDescendants() do
			if d:IsA("ProximityPrompt") and d:GetAttribute("HotDropClaim") == true then
				d:Destroy()
			end
		end
	end
end

-- Refusal reasons are shown to the player as toasts, so internal races (already claimed, stunned) refuse silently.
local function canClaim(hd: HotDrop, player: Player): (boolean, string?)
	if hotDrop ~= hd or hd.claimed or hd.phase ~= "live" then
		return false, nil
	end
	local car = hd.car
	if not car or not car.model or car.model.Parent == nil or car.kind ~= "HotDrop" then
		return false, nil
	end
	if player:GetAttribute("Stunned") == true then
		return false, nil
	end
	local DataService = sys("DataService")
	if DataService and typeof(DataService.isLoaded) == "function" and not DataService.isLoaded(player) then
		return false, "Still loading. Try again in a moment."
	end
	local V = sys("VehicleService")
	if V and typeof(V.getDriving) == "function" then
		local ok, driving = pcall(V.getDriving, player)
		if ok and driving ~= nil then
			return false, "Get out of your car first."
		end
	end
	return true, nil
end

local addClaimPrompt: (hd: HotDrop) -> ()

local function claimHotDrop(hd: HotDrop, player: Player)
	local ok = canClaim(hd, player)
	if not ok then
		return
	end
	local car = hd.car
	hd.claimed = true
	removeClaimPrompts(hd)

	setKind(car, "Loot")
	car.data = car.data or {}
	car.data.hotDrop = true
	car.data.hotDropClaimer = player.UserId
	if car.chassis and car.chassis:IsA("BasePart") then
		car.chassis.Anchored = false
	end
	-- seat() never throws; it returns (false, reason). On failure the drop stays claimable: no heat/stats/contract.
	local okCall, seated = call("VehicleService", "seat", car, player)
	if not okCall or seated ~= true then
		warn("[EventService] could not seat hot drop claimer; drop stays claimable")
		hd.claimed = false
		car.data.hotDropClaimer = nil
		setKind(car, "HotDrop")
		if car.chassis and car.chassis:IsA("BasePart") then
			car.chassis.Anchored = true
		end
		if hotDrop == hd and car.model and car.model.Parent then
			addClaimPrompt(hd)
		end
		return
	end

	call("WantedService", "addHeat", player, Police.Heat.hotDrop, "hotDrop")

	local DataService = sys("DataService")
	local data = DataService and DataService.get(player)
	if data and data.stats then
		data.stats.hotDrops = (data.stats.hotDrops or 0) + 1
		DataService.markDirty(player)
	end
	call("RewardsService", "progress", player, "hotDrop", 1)

	local label = carLabel(hd.carId, hd.mutation)
	local hex = rarityColor(hd.rarity):ToHex()
	feed(`<b>{richEscape(player.DisplayName)}</b> took the hot drop: <font color="#{hex}">{richEscape(label)}</font>.`)
	Net.fireClient(
		"Notify",
		player,
		"success",
		"You took the hot drop. Get it to your garage before the police catch up.",
		5
	)
	Net.fireClient("Sound", player, "CashBig", hd.position)
	Net.fireNear("Effect", hd.position, 400, "Confetti", { position = hd.position + Vector3.new(0, 4, 0) })
	-- warn now (not at the drop-off) when there is nowhere to park it; the claim itself is never blocked
	local okFree, free = call("GarageService", "freeSlots", player)
	if okFree and typeof(free) == "number" and free <= 0 then
		Net.fireClient(
			"Notify",
			player,
			"warning",
			"Your garage is full. Sell a car first, or take this one to the chop shop.",
			6
		)
	end
	EventService.HotDropClaimed:Fire(player, car)
	clearHotDrop(hd)
end

function addClaimPrompt(hd: HotDrop)
	local car = hd.car
	if not car then
		return
	end
	local def = Cars.get(hd.carId)
	local objectText = if def then carLabel(hd.carId, hd.mutation) else "Hot drop"
	local V = sys("VehicleService")
	if V and typeof(V.addStealPrompt) == "function" then
		local ok, res = pcall(V.addStealPrompt, car, {
			actionText = "Hotwire",
			holdDuration = Events.HOT_DROP_HOLD,
			objectText = objectText,
			canSteal = function(player: Player): (boolean, string?)
				return canClaim(hd, player)
			end,
			onStolen = function(player: Player)
				claimHotDrop(hd, player)
			end,
		})
		if ok then
			if typeof(res) == "Instance" then
				hd.prompt = res
				res:SetAttribute("HotDropClaim", true)
			end
			return
		end
		warn("[EventService] addStealPrompt failed: " .. tostring(res))
	end
	-- Fallback: our own prompt (server re-validates the hold window and the distance).
	local chassis = car.chassis
	if not chassis or not chassis:IsA("BasePart") then
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "HotDropPrompt"
	prompt.ActionText = "Hotwire" -- the same verb as the addStealPrompt path
	prompt.ObjectText = objectText
	prompt.HoldDuration = Events.HOT_DROP_HOLD
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt:SetAttribute("HotDropClaim", true)
	local began: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any -- weak: leavers drop out
	prompt.PromptButtonHoldBegan:Connect(function(player: Player)
		began[player] = os.clock()
	end)
	prompt.PromptButtonHoldEnded:Connect(function(player: Player)
		-- released early: the arm is void (a later Triggered without a fresh HoldBegan must not pass)
		local t0 = began[player]
		if t0 and os.clock() - t0 < Events.HOT_DROP_HOLD * 0.9 then
			began[player] = nil
		end
	end)
	prompt.Triggered:Connect(function(player: Player)
		local t0 = began[player]
		began[player] = nil
		if not EventService._holdValid(t0, os.clock(), Events.HOT_DROP_HOLD) then
			return
		end
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if
			not root
			or not root:IsA("BasePart")
			or chassis.Parent == nil
			or (root.Position - chassis.Position).Magnitude > prompt.MaxActivationDistance + 6
		then
			return
		end
		claimHotDrop(hd, player)
	end)
	prompt.Parent = chassis
	hd.prompt = prompt
end

-- Animates the anchored car falling onto its spot (server-side PivotTo over ~1s; one-off, cheap).
local function dropIn(model: Model, final: CFrame)
	local t0 = os.clock()
	local height = EventService.DROP_HEIGHT
	local duration = EventService.DROP_TIME
	while true do
		if model.Parent == nil then
			return
		end
		local a = math.clamp((os.clock() - t0) / duration, 0, 1)
		model:PivotTo(final + Vector3.new(0, height * (1 - a * a), 0))
		if a >= 1 then
			return
		end
		RunService.Heartbeat:Wait()
	end
end

local function isPointBlocked(cf: CFrame): boolean
	local V = sys("VehicleService")
	if not V or typeof(V.all) ~= "function" then
		return false
	end
	local ok, list = pcall(V.all)
	if not ok or typeof(list) ~= "table" then
		return false
	end
	for _, car in list do
		local model = car.model
		if model and model.Parent and (model:GetPivot().Position - cf.Position).Magnitude < 16 then
			return true
		end
	end
	return false
end

-- Where something standing at `pos` is moved so the landing car doesn't spawn inside it: straight out from
-- `center` to `radius` studs (random direction when it stands dead center), keeping its height.
function EventService._pushOut(center: Vector3, pos: Vector3, radius: number, r: Random?): Vector3
	local flatOff = Vector3.new(pos.X - center.X, 0, pos.Z - center.Z)
	local dir: Vector3
	if flatOff.Magnitude > 0.5 then
		dir = flatOff.Unit
	else
		local a = (r or rng):NextNumber(0, math.pi * 2)
		dir = Vector3.new(math.cos(a), 0, math.sin(a))
	end
	return Vector3.new(center.X, pos.Y, center.Z) + dir * radius
end

-- Right before the drop lands: nudge players off the spot and clear parked junk that drove/rolled in during the
-- countdown. Driverless traffic/unowned loot is removed; a player's own parked car is moved aside, never deleted.
local function clearLandingSpot(center: Vector3)
	for _, p in Players:GetPlayers() do
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local humanoid = char and char:FindFirstChildOfClass("Humanoid")
		if
			char
			and root
			and root:IsA("BasePart")
			and not (humanoid and humanoid.SeatPart)
			and (Vector3.new(root.Position.X - center.X, 0, root.Position.Z - center.Z)).Magnitude
				< EventService.LANDING_CLEAR_PLAYERS
		then
			local target = EventService._pushOut(center, root.Position, EventService.LANDING_PUSH_PLAYERS)
			char:PivotTo(CFrame.new(target) * root.CFrame.Rotation)
		end
	end
	local V = sys("VehicleService")
	if not V or typeof(V.all) ~= "function" then
		return
	end
	local ok, list = pcall(V.all)
	if not ok or typeof(list) ~= "table" then
		return
	end
	for _, car in list do
		local model = car.model
		if car.driver ~= nil or car.destroyed or not model or model.Parent == nil then
			continue
		end
		local pivot = model:GetPivot()
		local flatDist = Vector3.new(pivot.Position.X - center.X, 0, pivot.Position.Z - center.Z).Magnitude
		if flatDist >= EventService.LANDING_CLEAR_CARS then
			continue
		end
		if car.kind == "Traffic" or (car.kind == "Loot" and car.ownerUserId == nil) then
			call("TrafficService", "release", car, "cleared")
			call("VehicleService", "destroy", car, "cleared")
		elseif car.kind == "Owned" or car.kind == "Loot" then
			local target = EventService._pushOut(center, pivot.Position, EventService.LANDING_PUSH_CARS)
			call("VehicleService", "teleport", car, CFrame.new(target) * pivot.Rotation)
		end
	end
end

local function runHotDrop(hd: HotDrop)
	local color = rarityColor(hd.rarity)
	local label = carLabel(hd.carId, hd.mutation)

	-- Countdown: beacon goes up immediately so everyone can start driving there.
	local beacon = EventService._buildBeacon(hd.cframe, color, hd.rarity .. " · " .. label)
	beacon.Parent = effectsFolder()
	hd.beacon = beacon
	announce(
		"Hot drop",
		`A {hd.rarity} {label} lands in {Events.HOT_DROP_WARNING} seconds. It's marked on your map.`,
		color,
		"AirHorn"
	)
	broadcastHotDrop()

	while hotDrop == hd and now() < hd.startsAt do
		setBeaconText(hd, "Landing " .. Format.clock(math.ceil(hd.startsAt - now())), nil)
		task.wait(0.5)
	end
	if hotDrop ~= hd then
		return
	end

	-- Spawn the car (anchored, in the sky) and drop it in.
	local V = sys("VehicleService")
	if not V or typeof(V.spawn) ~= "function" then
		warn("[EventService] VehicleService.spawn unavailable; hot drop cancelled")
		clearHotDrop(hd)
		return
	end
	local okClear, clearErr = pcall(clearLandingSpot, hd.position)
	if not okClear then
		warn("[EventService] clearing the landing spot failed: " .. tostring(clearErr))
	end
	local ok, car = pcall(V.spawn, hd.carId, hd.mutation, hd.cframe, "HotDrop")
	if not ok or typeof(car) ~= "table" or not car.model then
		warn("[EventService] hot drop spawn failed: " .. tostring(car))
		clearHotDrop(hd)
		return
	end
	if hotDrop ~= hd then
		pcall(V.destroy, car, "cancelled")
		return
	end
	hd.car = car
	car.data = car.data or {}
	car.data.hotDrop = true
	local model: Model = car.model
	if car.chassis and car.chassis:IsA("BasePart") then
		car.chassis.Anchored = true
	end
	model:SetAttribute("HotDrop", true)
	local final = model:GetPivot()
	model:PivotTo(final + Vector3.new(0, EventService.DROP_HEIGHT, 0)) -- same frame as spawn: never seen on the ground
	dropIn(model, final)
	if hotDrop ~= hd or model.Parent == nil then
		return
	end

	hd.phase = "live"
	hd.endsAt = now() + Events.HOT_DROP_LIFETIME
	setBeaconLive(hd)
	addClaimPrompt(hd)
	local fxPos = hd.position + Vector3.new(0, 2, 0)
	Net.fireNear("Effect", fxPos, 500, "Confetti", { position = fxPos, rarity = hd.rarity })
	Net.fireNear("Effect", fxPos, 500, "CashBurst", { position = fxPos })
	Net.fireNear("Sound", fxPos, 400, "Crash", fxPos)
	announce("Hot drop", `The {label} is down. First one to hotwire it keeps it.`, color, "AirHorn")
	broadcastHotDrop()
	broadcastEventState()

	-- Live: wait for a claim, the timer, or the car being destroyed.
	local lastShown = -1
	while hotDrop == hd and not hd.claimed do
		local left = (hd.endsAt or 0) - now()
		if left <= 0 then
			expireHotDrop(hd, "expired")
			return
		end
		if model.Parent == nil then
			expireHotDrop(hd, "destroyed")
			return
		end
		local secs = math.ceil(left)
		if secs ~= lastShown then
			lastShown = secs
			setBeaconText(hd, "Hot drop " .. Format.clock(secs), nil)
		end
		task.wait(0.5)
	end
end

-- Starts a hot drop countdown now. Returns false if one is already running.
function EventService.startHotDrop(): boolean
	if hotDrop ~= nil then
		return false
	end
	local points = MapLayout.hotDropCFrames()
	if #points == 0 then
		return false
	end
	local index = EventService._pickDropIndex(#points, lastDropIndex, rng, function(i: number): boolean
		return isPointBlocked(points[i])
	end)
	lastDropIndex = index
	local cf = points[index]
	local carId, mutation, rarity = EventService._rollHotDrop(rng)
	hotDropToken += 1
	local hd: HotDrop = {
		token = hotDropToken,
		phase = "countdown",
		carId = carId,
		mutation = mutation,
		rarity = rarity,
		cframe = cf, -- MapLayout.hotDropCFrames() are already on the road surface
		position = cf.Position,
		pointIndex = index,
		startsAt = now() + Events.HOT_DROP_WARNING,
		endsAt = nil,
		car = nil,
		beacon = nil,
		prompt = nil,
		claimed = false,
	}
	hotDrop = hd
	nextAt.hotDrop = math.huge -- rescheduled when this drop ends
	task.spawn(function()
		local ok, err = pcall(runHotDrop, hd)
		if not ok then
			warn("[EventService] hot drop crashed: " .. tostring(err))
			if hotDrop == hd and not hd.claimed then
				expireHotDrop(hd, "error")
			end
		end
	end)
	return true
end

---------------------------------------------------------------------------------------------------------------------
-- Cash Rain
---------------------------------------------------------------------------------------------------------------------

local function playerFromHit(hit: Instance): Player?
	local node: Instance? = hit.Parent
	for _ = 1, 5 do
		if not node then
			return nil
		end
		local p = Players:GetPlayerFromCharacter(node)
		if p then
			return p
		end
		if node:IsA("Model") and node:GetAttribute("VehicleId") ~= nil then
			-- driving through a bag collects it for the driver
			local seat = node:FindFirstChild("DriverSeat")
			local occupant = if seat and seat:IsA("VehicleSeat") then seat.Occupant else nil
			return if occupant then Players:GetPlayerFromCharacter(occupant.Parent) else nil
		end
		node = node.Parent
	end
	return nil
end

local function collectBag(rec: BagRec, player: Player)
	if rec.collected or bags[rec.bag] ~= rec then
		return
	end
	local DataService = sys("DataService")
	if not DataService or not DataService.isLoaded(player) then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	rec.collected = true
	bags[rec.bag] = nil
	local pos = rec.bag.Position
	rec.bag:Destroy()
	local okIncome, income = call("GarageService", "incomePerSec", player)
	local amount = EventService._bagValue(if okIncome and typeof(income) == "number" then income else 0)
	DataService.addCash(player, amount, "cashRain")
	Net.fireClient("CashPopup", player, amount, pos)
	Net.fireClient("Sound", player, "Coin", pos)
	Net.fireNear("Effect", pos, 150, "CashBurst", { position = pos, amount = amount })
end

local function spawnBag(token: number, center: Vector3)
	local angle = rng:NextNumber(0, math.pi * 2)
	local radius = rng:NextNumber(EventService.BAG_RADIUS[1], EventService.BAG_RADIUS[2])
	local height = rng:NextNumber(EventService.BAG_DROP_HEIGHT[1], EventService.BAG_DROP_HEIGHT[2])
	local pos = center + Vector3.new(math.cos(angle) * radius, height, math.sin(angle) * radius)
	local bag = EventService._buildBag(pos)
	local rec: BagRec = { bag = bag, token = token, spawnedAt = os.clock(), collected = false, anchored = false }
	bags[bag] = rec
	bag.Touched:Connect(function(hit: BasePart)
		if rec.collected or bag.Parent == nil then
			return
		end
		local player = playerFromHit(hit)
		if player then
			collectBag(rec, player)
		end
	end)
	bag.Parent = effectsFolder()
	bag.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-4, 4), rng:NextNumber(-6, 6), rng:NextNumber(-4, 4))
	pcall(function()
		bag:SetNetworkOwner(nil) -- server simulates the fall so Touched is authoritative
	end)
end

local function clearBags(token: number?)
	for bag, rec in table.clone(bags) do
		if token == nil or rec.token == token then
			bags[bag] = nil
			rec.collected = true
			bag:Destroy()
		end
	end
end

local function rainLoop(token: number)
	local center = MapLayout.poiCenter("SpawnPlaza")
	local interval = Events.CASH_RAIN_DURATION / math.max(1, Events.CASH_RAIN_BAGS)
	local spawned = 0
	while rainToken == token and spawned < Events.CASH_RAIN_BAGS and now() < timers.cashRain do
		spawnBag(token, center)
		spawned += 1
		task.wait(interval)
	end
	while rainToken == token and now() < timers.cashRain do
		task.wait(0.5)
	end
	broadcastEventState()
	task.wait(EventService.BAG_LINGER)
	clearBags(token)
end

-- Polls players near bags (backup for Touched, which misses players already standing where a bag lands) and
-- anchors landed bags.
local function bagLoop()
	local r2 = EventService.BAG_PICKUP_RADIUS
	while true do
		task.wait(0.2)
		if next(bags) == nil then
			continue
		end
		local roots: { { player: Player, pos: Vector3 } } = {}
		for _, p in Players:GetPlayers() do
			local char = p.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				table.insert(roots, { player = p, pos = root.Position })
			end
		end
		local clock = os.clock()
		for bag, rec in table.clone(bags) do
			if rec.collected then
				continue
			end
			if bag.Parent == nil then
				bags[bag] = nil
				continue
			end
			local pos = bag.Position
			if pos.Y < -50 then
				bags[bag] = nil
				bag:Destroy()
				continue
			end
			for _, entry in roots do
				if (entry.pos - pos).Magnitude <= r2 then
					collectBag(rec, entry.player)
					break
				end
			end
			if
				not rec.collected
				and not rec.anchored
				and clock - rec.spawnedAt > EventService.BAG_ANCHOR_AFTER
				and bag.AssemblyLinearVelocity.Magnitude < 1
			then
				rec.anchored = true
				bag.Anchored = true
			end
		end
	end
end

function EventService.startCashRain(): boolean
	local t = now()
	if timers.cashRain > t then
		return false
	end
	timers.cashRain = t + Events.CASH_RAIN_DURATION
	rainToken += 1
	local token = rainToken
	announce(
		"Cash rain",
		"Money is coming down over the plaza for the next 45 seconds.",
		Color3.fromRGB(70, 235, 110),
		"CashDrop"
	)
	broadcastEventState()
	nextAt.cashRain = t
		+ Events.CASH_RAIN_DURATION
		+ rng:NextNumber(Events.CASH_RAIN_INTERVAL[1], Events.CASH_RAIN_INTERVAL[2])
	task.spawn(function()
		local ok, err = pcall(rainLoop, token)
		if not ok then
			warn("[EventService] cash rain crashed: " .. tostring(err))
			clearBags(token)
		end
	end)
	return true
end

---------------------------------------------------------------------------------------------------------------------
-- Timed events
---------------------------------------------------------------------------------------------------------------------

-- Luck only affects NEW rolls: when a luck event starts, ask StreetSpawnService to re-roll a share of the parked cars
-- nobody is looking at, so "rare cars are everywhere" is visible. Optional API (no-op when it doesn't exist).
local function rerollStreet()
	call("StreetSpawnService", "rerollOutOfView", EventService.LUCK_REROLL_FRACTION)
end

function EventService.startRushHour(): boolean
	local t = now()
	timers.rushHour = EventService._stack(timers.rushHour, t, Events.RUSH_HOUR_DURATION)
	announce(
		"Rush hour",
		"Heavy traffic citywide, and rarer cars parked on the street.",
		Color3.fromRGB(255, 190, 40),
		"Horn"
	)
	nextAt.rushHour = timers.rushHour + rng:NextNumber(Events.RUSH_HOUR_INTERVAL[1], Events.RUSH_HOUR_INTERVAL[2])
	broadcastEventState()
	rerollStreet()
	return true
end

function EventService.startDoubleCash(): boolean
	local t = now()
	timers.doubleCash = EventService._stack(timers.doubleCash, t, Events.DOUBLE_CASH_DURATION)
	announce(
		"Double cash",
		`Every garage pays double for the next {Format.clock(Events.DOUBLE_CASH_DURATION)}.`,
		Color3.fromRGB(70, 235, 110),
		"CashBig"
	)
	nextAt.doubleCash = timers.doubleCash
		+ rng:NextNumber(Events.DOUBLE_CASH_INTERVAL[1], Events.DOUBLE_CASH_INTERVAL[2])
	broadcastEventState()
	return true
end

-- Server Luck x2 (Robux product, also admin). Stacks duration. Never yields (ProcessReceipt-safe).
function EventService.activateServerLuck(player: Player?): boolean
	local t = now()
	timers.serverLuck = EventService._stack(timers.serverLuck, t, Monetization.SERVER_LUCK_DURATION)
	local who = if player then player.DisplayName else "Someone"
	local left = timers.serverLuck - t
	announce(
		"Server luck",
		`{richEscape(who)} doubled the odds of rare cars for everyone. {Format.clock(left)} left.`,
		Color3.fromRGB(80, 230, 120),
		"CashBig"
	)
	broadcastEventState()
	rerollStreet()
	return true
end

-- Generic entry point (AdminService): "hotdrop" | "cashrain" | "rushhour" | "doublecash" | "luck" (+ aliases).
function EventService.startEvent(name: string, player: Player?): (boolean, string)
	local canonical = EventService._resolveEvent(name)
	if canonical == "hotDrop" then
		local ok = EventService.startHotDrop()
		return ok, if ok then "Hot Drop incoming" else "A Hot Drop is already running"
	elseif canonical == "cashRain" then
		local ok = EventService.startCashRain()
		return ok, if ok then "Cash Rain started" else "Cash Rain already running"
	elseif canonical == "rushHour" then
		EventService.startRushHour()
		return true, "Rush Hour started"
	elseif canonical == "doubleCash" then
		EventService.startDoubleCash()
		return true, "2x Cash started"
	elseif canonical == "serverLuck" then
		EventService.activateServerLuck(player)
		return true, "Server Luck activated"
	end
	return false, "Unknown event " .. tostring(name)
end

-- Aliases AdminService probes for.
EventService.forceHotDrop = EventService.startHotDrop
EventService.forceRushHour = EventService.startRushHour
EventService.forceCashRain = EventService.startCashRain
EventService.forceDoubleCash = EventService.startDoubleCash

---------------------------------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------------------------------

local function scheduler()
	while true do
		task.wait(1)
		local t = now()
		broadcastEventState() -- picks up natural expiry (no-op when unchanged)
		if #Players:GetPlayers() == 0 then
			-- empty server: never fire the moment someone joins (they are still loading)
			for name, at in nextAt do
				if at < t + EventService.EMPTY_SERVER_DELAY then
					nextAt[name] = t + EventService.EMPTY_SERVER_DELAY
				end
			end
			continue
		end
		if t - lastAutoStart < EventService.AUTO_GAP then
			continue
		end
		if hotDrop == nil and t >= nextAt.hotDrop then
			if EventService.startHotDrop() then
				lastAutoStart = t
			end
		elseif timers.cashRain <= t and t >= nextAt.cashRain then
			if EventService.startCashRain() then
				lastAutoStart = t
			end
		elseif timers.rushHour <= t and t >= nextAt.rushHour then
			EventService.startRushHour()
			lastAutoStart = t
		elseif timers.doubleCash <= t and t >= nextAt.doubleCash then
			EventService.startDoubleCash()
			lastAutoStart = t
		end
	end
end

function EventService.init()
	effectsFolder()
	local V = sys("VehicleService")
	if V and V.Destroyed and typeof(V.Destroyed.Connect) == "function" then
		V.Destroyed:Connect(function(car: any, _reason: any)
			local hd = hotDrop
			if hd and hd.car == car and not hd.claimed then
				expireHotDrop(hd, "destroyed")
			end
		end)
	end
end

function EventService.start()
	if started then
		return
	end
	started = true
	local t = now()
	for name, range in EventService.FIRST_DELAYS do
		nextAt[name] = t + rng:NextNumber(range[1], range[2])
	end

	local function onPlayer(player: Player)
		sendStateTo(player)
		-- Re-send once the client has certainly booted (the first push can race client listeners).
		task.delay(6, sendStateTo, player)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end
	local DataService = sys("DataService")
	if DataService and DataService.Loaded then
		DataService.Loaded:Connect(function(player: Player)
			task.delay(2, sendStateTo, player)
		end)
	end

	task.spawn(bagLoop)
	scheduler()
end

return EventService
