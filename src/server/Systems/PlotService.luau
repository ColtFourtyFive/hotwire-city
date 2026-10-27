--!strict
-- PlotService: builds the 8 player garages (Workspace.Plots.Plot<i>), assigns one to each player on join,
-- moves characters home on spawn, and runs the timed laser lock (gate, countdown, intruder push-out).
--
-- Spawning: each plot gets a "PlotSpawn" SpawnLocation at OwnerSpawn and the owner's RespawnLocation points at it,
-- so characters appear in their garage (no plaza flash); onCharacter still pivots them home as a fallback. A player
-- busted for dying while wanted (WantedService.consumeRespawnAtHQ) respawns at Police HQ instead.
-- Lock push-out (DECISIONS #9): a non-owner driving a car stolen FROM THIS GARAGE is ejected (the car stays inside,
-- "dropped", for the owner to Recover) and pushed out on foot; other cars leave with their driver through
-- VehicleService.teleport (never a raw PivotTo, which the anti-teleport watchdog would rewind).
--
-- Geometry comes from Config/Map.Garage + Util/MapLayout. Plot-local frame: origin = block center at curb
-- height, local -Z points OUT of the front door. `buildGarageModel` is pure instance construction so the Lune
-- harness (tests/harness.luau, tools/dump.luau) can build and render it headlessly.
--
-- Names other systems rely on (direct children of Plot<i>):
--   Pad1..Pad12 (Part; SurfaceGui "PadGui"; child Part "Sign" with SurfaceGui "SignGui"; attributes Slot, Locked,
--   Price, PassOnly, NextUnlock, State), Dropoff, DropoffMark, CollectPad, CollectSign, LockButton, LockSign, Gate
--   (children Beam1..Beam5, SurfaceGuis "CountdownGui"/"CountdownGuiBack"), StatusLight, Sign (SurfaceGui
--   "SignGui" -> TextLabel "OwnerName" / "Stats"), Display (Folder), OwnerSpawn, Building (Folder of decor),
--   Dressing (Folder of kit-prop slots), Loot (Model: the wealth corner, Tier1..Tier4 Models shown by income).
-- Plot model attributes: PlotIndex, Accent, OwnerUserId (0 = vacant), OwnerName, Locked, LockEndsAt,
--   LockReadyAt (both Workspace:GetServerTimeNow() based), LootTier. GarageService adds CarCount, Uncollected,
--   IncomePerSec.
--
-- Art pass (docs/ART_PASS.md AP2b): wall props are Models tagged "AssetSlot" (attributes Category, Role, Fit,
-- Footprint; WorldPivot = the ground CFrame the asset stands on, LookVector = the asset's front) that MapDresser swaps
-- for kit meshes; the procedural placeholder inside each slot is the fallback. Loot slots carry the same attributes
-- but tag "LootSlot": PlotService dresses those itself (AssetLibrary templates) because it also shows/hides them by
-- the owner's IncomePerSec tier, and a hidden tier is not in Workspace when MapDresser runs. Every slot keeps clear of
-- the pads (+ the longest car), the aisle, drop-off, collect pad, lock button, door path and OwnerSpawn (garage spec).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Assets = require(Shared.Config.Assets)
local EconomyMath = require(Shared.Util.EconomyMath)
local Format = require(Shared.Util.Format)
local MapConfig = require(Shared.Config.Map)
local MapLayout = require(Shared.Util.MapLayout)
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)

local G = MapConfig.Garage

local PlotService = {}

-- Public constants ------------------------------------------------------------------------------------------
PlotService.FLOOR_LIFT = 0.05 -- garage floor top sits this far above CURB_TOP (avoids z-fighting with the lot)
PlotService.PAD_THICKNESS = 0.2
PlotService.PAD_TOP = PlotService.FLOOR_LIFT + PlotService.PAD_THICKNESS -- display cars rest on this (plot-local y)
PlotService.LOCK_REARM = 15 -- min seconds after a lock ends before the button re-arms (see _rearmSeconds)
PlotService.REARM_FRACTION = 0.5 -- ...or this fraction of the last button lock, whichever is longer (DECISIONS #8)
PlotService.MAX_LOCK_SECONDS = 3600 -- stacked locks (Lockdown purchases) never reach further ahead than this
PlotService.GO_HOME_COOLDOWN = 20
PlotService.PUSH_INTERVAL = 0.5
PlotService.TAG_SLOT = "AssetSlot" -- MapDresser contract (wall props)
PlotService.TAG_LOOT = "LootSlot" -- dressed + toggled by PlotService (loot corner)
-- Owner IncomePerSec needed for loot tiers 1..4 (tier 0 = the safe every garage has).
PlotService.LOOT_TIERS = { 100, 1000, 10000, 100000 } :: { number }
-- Keep-out around every parking slot: the longest car (stretch limo) x the pad depth, centered on the slot.
PlotService.CAR_FOOTPRINT = Vector3.new(18, 0, G.SLOT_PAD_SIZE.Z)

-- One neon accent per plot (sign trim, wall strips, aisle lines, couch...).
PlotService.ACCENTS = {
	Color3.fromRGB(255, 52, 140), -- hot pink
	Color3.fromRGB(0, 214, 255), -- cyan
	Color3.fromRGB(120, 255, 60), -- lime
	Color3.fromRGB(255, 140, 30), -- orange
	Color3.fromRGB(170, 80, 255), -- purple
	Color3.fromRGB(255, 225, 40), -- yellow
	Color3.fromRGB(255, 60, 60), -- red
	Color3.fromRGB(60, 120, 255), -- blue
} :: { Color3 }

PlotService.PlotAssigned = Signal.new() -- (player, index)
PlotService.PlotReleased = Signal.new() -- (player, index)

export type PlotInfo = {
	index: number,
	model: Model,
	display: Folder,
	origin: CFrame,
	owner: Player?,
	lockedUntil: number, -- os.clock() deadline (0 = unlocked)
	lockReadyAt: number, -- os.clock() when the lock button re-arms
}

-- Palette -----------------------------------------------------------------------------------------------------
local C = {
	floor = Color3.fromRGB(62, 66, 84),
	apron = Color3.fromRGB(150, 152, 162),
	pad = Color3.fromRGB(94, 100, 128),
	wall = Color3.fromRGB(236, 230, 214),
	plinth = Color3.fromRGB(52, 55, 70),
	roof = Color3.fromRGB(88, 92, 110),
	glass = Color3.fromRGB(150, 215, 255),
	hazard = Color3.fromRGB(255, 200, 40),
	dark = Color3.fromRGB(28, 31, 58),
	header = Color3.fromRGB(40, 42, 56),
	light = Color3.fromRGB(255, 246, 225),
	cash = Color3.fromRGB(70, 235, 110),
	cashDark = Color3.fromRGB(25, 140, 60),
	lock = Color3.fromRGB(255, 60, 70),
	laser = Color3.fromRGB(255, 30, 50),
	open = Color3.fromRGB(70, 235, 110),
	metal = Color3.fromRGB(96, 100, 116),
	tire = Color3.fromRGB(34, 34, 40),
	toolbox = Color3.fromRGB(205, 45, 45),
	peg = Color3.fromRGB(196, 156, 104),
	white = Color3.new(1, 1, 1),
	pilaster = Color3.fromRGB(206, 198, 180),
	acUnit = Color3.fromRGB(190, 196, 206),
	window = Color3.fromRGB(70, 110, 150),
	lift = Color3.fromRGB(40, 110, 225),
	gold = Color3.fromRGB(255, 196, 46),
	safe = Color3.fromRGB(64, 76, 100),
	safeDoor = Color3.fromRGB(96, 110, 140),
	bill = Color3.fromRGB(70, 190, 96),
	billLight = Color3.fromRGB(150, 230, 150),
	burlap = Color3.fromRGB(176, 120, 64),
	cardboard = Color3.fromRGB(196, 150, 96),
	logoBg = Color3.fromRGB(18, 20, 38), -- matches the logo art's background
}

local FONT = Font.fromEnum(Enum.Font.FredokaOne)
local FONT_BODY = Font.fromEnum(Enum.Font.GothamBlack)

-- Instance helpers (harness-safe: only Instance.new + properties) ----------------------------------------------
type PartOpts = {
	material: Enum.Material?,
	collide: boolean?,
	transparency: number?,
	shape: Enum.PartType?,
	shadow: boolean?,
	touch: boolean?,
	query: boolean?,
	class: string?,
}

local function makePart(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	opts: PartOpts?
): BasePart
	local o: PartOpts = opts or {}
	local p = Instance.new(o.class or "Part") :: BasePart
	p.Name = name
	p.Anchored = true
	if o.shape and p:IsA("Part") then
		p.Shape = o.shape
	end
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = o.material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = if o.collide == nil then true else o.collide
	p.Transparency = o.transparency or 0
	p.CastShadow = if o.shadow == nil then true else o.shadow
	p.CanTouch = o.touch == true
	p.CanQuery = if o.query == nil then p.CanCollide else o.query
	p.Parent = parent
	return p
end

-- Non-collidable, non-queryable decoration.
local function deco(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?
): BasePart
	return makePart(parent, name, size, cf, color, {
		material = material,
		collide = false,
		query = false,
		shadow = material ~= Enum.Material.Neon,
	})
end

local function neon(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3): BasePart
	return deco(parent, name, size, cf, color, Enum.Material.Neon)
end

-- GUI budget (PERF-12): ~35 SurfaceGuis per plot. Small interior pads / signs / buttons render only up close
-- (NEAR_GUI); banners, murals, the gate countdown and the owner sign keep the long default range.
local FAR_GUI = 400
local NEAR_GUI = 160

local function surfaceGui(
	parent: BasePart,
	name: string,
	face: Enum.NormalId,
	pixelsPerStud: number,
	maxDistance: number?
): SurfaceGui
	local sg = Instance.new("SurfaceGui")
	sg.Name = name
	sg.Face = face
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = pixelsPerStud
	sg.LightInfluence = 0
	sg.Brightness = 1.6
	sg.ClipsDescendants = true
	sg.MaxDistance = maxDistance or FAR_GUI
	sg.ResetOnSpawn = false
	sg.Parent = parent
	return sg
end

local function textLabel(
	parent: Instance,
	name: string,
	text: string,
	color: Color3,
	pos: UDim2,
	size: UDim2,
	strokeColor: Color3?,
	strokeThickness: number?
): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.Text = text
	t.TextColor3 = color
	t.FontFace = FONT
	t.TextScaled = true
	t.RichText = true
	t.Position = pos
	t.Size = size
	t.AnchorPoint = Vector2.new(0, 0)
	local stroke = Instance.new("UIStroke")
	stroke.Color = strokeColor or Color3.fromRGB(10, 11, 22)
	stroke.Thickness = strokeThickness or 4
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = t
	t.Parent = parent
	return t
end

local function frame(
	parent: Instance,
	name: string,
	color: Color3,
	transparency: number,
	pos: UDim2,
	size: UDim2
): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundColor3 = color
	f.BackgroundTransparency = transparency
	f.BorderSizePixel = 0
	f.Position = pos
	f.Size = size
	f.Parent = parent
	return f
end

local function corner(parent: Instance, scale: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(scale, 0)
	c.Parent = parent
end

local function uiStroke(parent: Instance, color: Color3, thickness: number)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
end

local FULL = UDim2.fromScale(1, 1)
local ZERO = UDim2.fromScale(0, 0)

-- Pure helpers (exposed for tests) ------------------------------------------------------------------------------

-- Lock duration in seconds for a lock upgrade level + rebirth count.
function PlotService._lockDuration(level: number, rebirths: number): number
	return EconomyMath.upgradeValue("lock", level) + 10 * math.max(0, rebirths)
end

-- Seconds the lock button stays disarmed after a lock of `lastDuration` ends: proportional, so an AFK owner tapping
-- the button can't keep the garage locked ~90% of the time (DECISIONS #8).
function PlotService._rearmSeconds(lastDuration: number): number
	local d = if typeof(lastDuration) == "number" and lastDuration == lastDuration then lastDuration else 0
	return math.max(PlotService.LOCK_REARM, PlotService.REARM_FRACTION * math.max(0, d))
end

-- New lock deadline when `seconds` are added at `now`: a purchase stacks on a running lock (DECISIONS #7), capped
-- at MAX_LOCK_SECONDS ahead.
function PlotService._stackLock(lockedUntil: number, now: number, seconds: number): number
	return math.min(math.max(lockedUntil, now) + seconds, now + PlotService.MAX_LOCK_SECONDS)
end

-- Should the lock push-out eject this vehicle's driver instead of moving the car? Only a car stolen from this
-- garage's owner: the thief leaves on foot and the car stays inside, "dropped", for the owner to Recover.
function PlotService._ejectOnLock(kind: any, theftVictimUserId: any, ownerUserId: number?): boolean
	return kind == "Stolen" and ownerUserId ~= nil and ownerUserId ~= 0 and theftVictimUserId == ownerUserId
end

-- Spread push-out spots across the driveway so several intruders don't stack.
function PlotService._drivewayOffset(n: number): Vector3
	local slots = { 0, -7, 7, -14, 14 }
	local x = slots[((n - 1) % #slots) + 1]
	return Vector3.new(x, 0, G.FRONT_Z - 12)
end

function PlotService.accentFor(index: number): Color3
	local list = PlotService.ACCENTS
	return list[((index - 1) % #list) + 1]
end

-- Builder ---------------------------------------------------------------------------------------------------------

local function buildPad(model: Model, origin: CFrame, accent: Color3, slot: number)
	local slotCf = MapLayout.slotLocal(slot)
	local padSize = G.SLOT_PAD_SIZE
	-- Pad frame: rotated 180 so the part's Front (-Z) points at the wall; Top-face text then reads from the aisle.
	local padLocal = slotCf
		* CFrame.new(0, PlotService.FLOOR_LIFT + PlotService.PAD_THICKNESS / 2, 0)
		* CFrame.Angles(0, math.pi, 0)
	local pad = makePart(
		model,
		"Pad" .. slot,
		Vector3.new(padSize.Z, PlotService.PAD_THICKNESS, padSize.X),
		origin * padLocal,
		C.pad,
		{ material = Enum.Material.SmoothPlastic, collide = true, query = false, shadow = false }
	)
	pad:SetAttribute("Slot", slot)
	pad:SetAttribute("Locked", false)
	pad:SetAttribute("Price", 0)
	pad:SetAttribute("PassOnly", false)
	pad:SetAttribute("NextUnlock", false)
	pad:SetAttribute("State", "Empty")
	CollectionService:AddTag(pad, "GaragePad")

	-- Floor paint: border + big slot number; "Lock" overlay shown by GarageClient for locked pads. A floor decal
	-- seen at grazing angles: 12 px/stud is plenty (strokes are in pixels, so they scale with it).
	local gui = surfaceGui(pad, "PadGui", Enum.NormalId.Top, 12, NEAR_GUI)
	local root = frame(gui, "Root", C.white, 1, ZERO, FULL)
	local border = frame(root, "Border", C.white, 1, UDim2.fromScale(0.04, 0.03), UDim2.fromScale(0.92, 0.94))
	uiStroke(border, Color3.fromRGB(235, 238, 255), 3)
	corner(border, 0.06)
	textLabel(
		root,
		"Number",
		tostring(slot),
		Color3.fromRGB(235, 238, 255),
		UDim2.fromScale(0.15, 0.3),
		UDim2.fromScale(0.7, 0.4),
		C.dark,
		2
	)
	local lock =
		frame(root, "Lock", Color3.fromRGB(70, 18, 30), 0.15, UDim2.fromScale(0.04, 0.03), UDim2.fromScale(0.92, 0.94))
	lock.Visible = false
	corner(lock, 0.06)
	uiStroke(lock, C.lock, 3)
	textLabel(lock, "Icon", "🔒", C.white, UDim2.fromScale(0.2, 0.12), UDim2.fromScale(0.6, 0.42), nil, 2)
	textLabel(lock, "Price", "", C.hazard, UDim2.fromScale(0.08, 0.58), UDim2.fromScale(0.84, 0.28), nil, 2)

	-- Bay sign on the side wall behind the pad (vertical => text orientation is unambiguous).
	local face = slotCf.LookVector -- toward the aisle
	local wallX = (G.HALF_WIDTH - G.WALL_THICKNESS - 0.2) * (if slotCf.Position.X < 0 then -1 else 1)
	local signPos = Vector3.new(wallX, 8.5, slotCf.Position.Z)
	local sign = makePart(
		pad,
		"Sign",
		Vector3.new(7, 3.6, 0.4),
		origin * CFrame.lookAt(signPos, signPos + face),
		C.dark,
		{ collide = false, query = false, shadow = false }
	)
	local sgui = surfaceGui(sign, "SignGui", Enum.NormalId.Front, 20, NEAR_GUI)
	local sroot = frame(sgui, "Root", C.dark, 0, ZERO, FULL)
	uiStroke(sroot, accent, 5)
	textLabel(
		sroot,
		"Number",
		tostring(slot),
		C.white,
		UDim2.fromScale(0.04, 0.08),
		UDim2.fromScale(0.36, 0.84),
		C.dark,
		3
	)
	textLabel(sroot, "Status", "", accent, UDim2.fromScale(0.42, 0.22), UDim2.fromScale(0.54, 0.56), C.dark, 2)
end

-- Kit dressing ------------------------------------------------------------------------------------------------------

-- Normalized kit dims per stud of `fit` (W, H, D with the front facing -Z; from `python3 tools/kitgeo.py dims`).
-- Sizes the procedural placeholders and the keep-out checks; the meshes themselves come from Config/Assets.
local KIT_DIMS: { [string]: Vector3 } = {
	car_lift = Vector3.new(1, 0.955, 0.288),
	tool_chest = Vector3.new(0.843, 1, 0.585),
	tire_stack = Vector3.new(0.696, 1, 0.658),
	oil_barrels = Vector3.new(1, 0.777, 0.752),
	workbench = Vector3.new(0.997, 1, 0.554),
	garage_shelf = Vector3.new(0.881, 1, 0.353),
	safe_vault = Vector3.new(0.791, 1, 0.864),
	money_pile = Vector3.new(1, 0.522, 0.866),
	gold_bars = Vector3.new(1, 0.615, 0.725),
	trophy = Vector3.new(1, 0.956, 0.513),
	money_bag = Vector3.new(0.898, 1, 0.616),
}

export type DressSpot = {
	name: string,
	role: string, -- Config/Assets.Props key
	fit: number, -- studs along the role's `fit` dimension
	cf: CFrame, -- plot-local ground CFrame (LookVector = the asset's front)
	size: Vector3, -- W, H, D of the placed asset in its own frame
	tier: number?, -- loot tier (0 = always shown); nil = wall prop dressed by MapDresser
}

-- Interior wall faces (the wainscot) in plot-local space.
local IN_X = G.HALF_WIDTH - G.WALL_THICKNESS - 0.2
local IN_FZ = G.FRONT_Z + G.WALL_THICKNESS + 0.2
local IN_BZ = G.BACK_Z - G.WALL_THICKNESS - 0.2
local WALL_GAP = 0.1

local function dims(role: string, fit: number): Vector3
	return (KIT_DIMS[role] or Vector3.one) * fit
end

local function spotAt(name: string, role: string, fit: number, pos: Vector3, facing: Vector3, tier: number?): DressSpot
	return {
		name = name,
		role = role,
		fit = fit,
		cf = CFrame.lookAt(pos, pos + facing),
		size = dims(role, fit),
		tier = tier,
	}
end

-- Against the front wall (beside the door), facing into the garage.
local function onFrontWall(name: string, role: string, fit: number, x: number): DressSpot
	local d = dims(role, fit).Z
	return spotAt(name, role, fit, Vector3.new(x, 0, IN_FZ + d / 2 + WALL_GAP), Vector3.zAxis)
end

-- Against a side wall (side = -1 left / +1 right), facing the aisle.
local function onSideWall(name: string, role: string, fit: number, side: number, z: number): DressSpot
	local d = dims(role, fit).Z
	return spotAt(name, role, fit, Vector3.new(side * (IN_X - d / 2 - WALL_GAP), 0, z), Vector3.new(-side, 0, 0))
end

-- Against the back wall at height y, facing the door.
local function onBackWall(name: string, role: string, fit: number, x: number, y: number, tier: number?): DressSpot
	local d = dims(role, fit).Z
	return spotAt(name, role, fit, Vector3.new(x, y, IN_BZ - d / 2 - WALL_GAP), -Vector3.zAxis, tier)
end

-- Where every kit prop of plot `index` stands (plot-local). Pure + deterministic. Left/right as seen from inside,
-- facing the door: odd plots put the car lift in the front-left (-X) corner, even plots front-right; every third plot
-- runs a second lift in the other corner (its tool chest and barrels move to the side wall, the tire stack to the back
-- corner). The shelf always stands right of the door (the lock button owns the left), the workbench beside the lift;
-- the loot corner flanks the collect pad.
function PlotService._dressLayout(index: number): { DressSpot }
	local side = if index % 2 == 1 then -1 else 1 -- lift corner
	local other = -side
	local twoLifts = index % 3 == 0
	local liftW = dims("car_lift", 14).X
	local liftX = IN_X - liftW / 2 - 0.3
	local spots: { DressSpot } = {
		onFrontWall("CarLift", "car_lift", 14, side * liftX),
		onSideWall("Workbench", "workbench", 8, side, -32.6),
		onFrontWall("Shelf", "garage_shelf", 9, 25.5),
	}
	if twoLifts then
		table.insert(spots, onFrontWall("CarLift2", "car_lift", 14, other * liftX))
		table.insert(spots, onSideWall("ToolChest", "tool_chest", 5, other, -35))
		table.insert(spots, onSideWall("OilBarrels", "oil_barrels", 5, other, -30))
		table.insert(spots, onSideWall("TireStack", "tire_stack", 5, other, 43.5))
	else
		local barrelsW = dims("oil_barrels", 5).X
		table.insert(spots, onFrontWall("OilBarrels", "oil_barrels", 5, other * (IN_X - barrelsW / 2 - 0.2)))
		table.insert(spots, onFrontWall("TireStack", "tire_stack", 5, other * 37.7))
		table.insert(spots, onSideWall("ToolChest", "tool_chest", 5, other, -33.5))
	end

	-- Loot corner: the safe (always) right of the collect pad, then cash, gold on the safe + a money bag left of the
	-- pad, a giant trophy, and finally a second cash heap + gold stack. Tier t needs LOOT_TIERS[t] $/s.
	local cx = G.COLLECT_CENTER.X
	local cash = onBackWall("LootCash", "money_pile", 5, cx + 15.5, 0, 1)
	local heapTop = cash.cf.Position + Vector3.new(0, cash.size.Y * 0.8, 0) -- tier 4 heaps more cash on top
	table.insert(spots, onBackWall("LootSafe", "safe_vault", 5.3, cx + 10.4, 0, 0))
	table.insert(spots, cash)
	table.insert(spots, onBackWall("LootGold", "gold_bars", 3, cx + 10.4, dims("safe_vault", 5.3).Y, 2))
	table.insert(spots, onBackWall("LootBag", "money_bag", 3, cx - 8.9, 0, 2))
	table.insert(spots, onBackWall("LootTrophy", "trophy", 5, cx + 21.2, 0, 3))
	table.insert(spots, spotAt("LootCash2", "money_pile", 4, heapTop, Vector3.xAxis, 4))
	table.insert(spots, spotAt("LootGold2", "gold_bars", 2.6, Vector3.new(cx - 8.9, 0, 42.3), -Vector3.zAxis, 4))
	return spots
end

-- Procedural placeholders (the fallback when a mesh never loads): non-colliding, shadowless, roughly the mesh's
-- silhouette and palette. `b` = world ground CFrame (front = -Z), `s` = W/H/D.
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2) -- cylinder axis (local X) -> Y

local function prop(
	m: Model,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	shape: Enum.PartType?
): BasePart
	return makePart(m, name, size, cf, color, {
		material = material,
		shape = shape,
		collide = false,
		query = false,
		shadow = false,
	})
end

local PLACEHOLDER: { [string]: (m: Model, b: CFrame, s: Vector3, accent: Color3) -> () } = {
	car_lift = function(m, b, s)
		local postW = 1.4
		for _, sx in { -1, 1 } do
			local x = sx * (s.X / 2 - postW / 2)
			prop(m, "Post", Vector3.new(postW, s.Y, 1.8), b * CFrame.new(x, s.Y / 2, 0), C.lift, Enum.Material.Metal)
			prop(
				m,
				"Arm",
				Vector3.new(4.2, 0.4, 0.8),
				b * CFrame.new(x - sx * (postW / 2 + 2.1), 3.2, -0.6),
				C.hazard,
				Enum.Material.Metal
			)
		end
		prop(m, "Beam", Vector3.new(s.X, 0.9, 1), b * CFrame.new(0, s.Y - 0.45, 0), C.lift, Enum.Material.Metal)
	end,
	tool_chest = function(m, b, s)
		local h = s.Y - 0.5
		prop(m, "Body", Vector3.new(s.X, h, s.Z), b * CFrame.new(0, 0.5 + h / 2, 0), C.toolbox, Enum.Material.Metal)
		prop(
			m,
			"Drawers",
			Vector3.new(s.X - 0.5, h * 0.6, 0.12),
			b * CFrame.new(0, 0.5 + h * 0.4, -s.Z / 2 - 0.06),
			C.toolbox:Lerp(C.dark, 0.35),
			Enum.Material.Metal
		)
	end,
	tire_stack = function(m, b, s)
		local th = s.Y / 3
		local dia = math.min(s.X, s.Z)
		for k = 0, 2 do
			local cf = b * CFrame.new(0, th * (k + 0.5), 0) * UPRIGHT
			prop(m, "Tire", Vector3.new(th - 0.08, dia, dia), cf, C.tire, Enum.Material.Rubber, Enum.PartType.Cylinder)
		end
	end,
	oil_barrels = function(m, b, s)
		local dia = s.X * 0.36
		local spots = { { -0.31, 0.22 }, { 0.03, -0.24 }, { 0.32, 0.21 } }
		local colors = { Color3.fromRGB(40, 90, 220), Color3.fromRGB(215, 40, 40), Color3.fromRGB(250, 200, 40) }
		for i, p in spots do
			local cf = b * CFrame.new(p[1] * s.X, s.Y / 2, p[2] * s.Z) * UPRIGHT
			prop(m, "Barrel", Vector3.new(s.Y, dia, dia), cf, colors[i], Enum.Material.Metal, Enum.PartType.Cylinder)
		end
	end,
	workbench = function(m, b, s)
		prop(
			m,
			"Cabinet",
			Vector3.new(s.X - 0.4, 3, s.Z - 0.6),
			b * CFrame.new(0, 1.5, 0.1),
			C.toolbox,
			Enum.Material.Metal
		)
		prop(m, "BenchTop", Vector3.new(s.X, 0.45, s.Z), b * CFrame.new(0, 3.2, 0), C.peg, Enum.Material.Wood)
		local ph = s.Y - 3.45
		prop(
			m,
			"Pegboard",
			Vector3.new(s.X - 0.4, ph, 0.3),
			b * CFrame.new(0, 3.45 + ph / 2, s.Z / 2 - 0.15),
			C.peg,
			Enum.Material.Wood
		)
	end,
	garage_shelf = function(m, b, s, accent)
		for _, sx in { -1, 1 } do
			local cf = b * CFrame.new(sx * (s.X / 2 - 0.175), s.Y / 2, 0)
			prop(m, "Upright", Vector3.new(0.35, s.Y, s.Z), cf, C.metal, Enum.Material.Metal)
		end
		for _, f in { 0.06, 0.48, 0.9 } do
			prop(
				m,
				"Board",
				Vector3.new(s.X - 0.7, 0.25, s.Z),
				b * CFrame.new(0, s.Y * f, 0),
				C.acUnit,
				Enum.Material.Metal
			)
		end
		prop(m, "Box", Vector3.new(s.X * 0.3, 1.6, s.Z * 0.8), b * CFrame.new(-s.X * 0.2, s.Y * 0.48 + 0.92, 0), accent)
	end,
	safe_vault = function(m, b, s)
		prop(m, "Body", s, b * CFrame.new(0, s.Y / 2, 0), C.safe, Enum.Material.Metal)
		prop(
			m,
			"Door",
			Vector3.new(s.X * 0.78, s.Y * 0.78, 0.15),
			b * CFrame.new(0, s.Y / 2, -s.Z / 2 - 0.075),
			C.safeDoor,
			Enum.Material.Metal
		)
		local dial = s.X * 0.28
		prop(
			m,
			"Dial",
			Vector3.new(0.25, dial, dial),
			b * CFrame.new(s.X * 0.12, s.Y * 0.55, -s.Z / 2 - 0.2) * CFrame.Angles(0, math.pi / 2, 0),
			C.gold,
			Enum.Material.Metal,
			Enum.PartType.Cylinder
		)
	end,
	money_pile = function(m, b, s)
		prop(m, "Bills", Vector3.new(s.X, s.Y * 0.42, s.Z) * 0.96, b * CFrame.new(0, s.Y * 0.2, 0), C.bill)
		prop(
			m,
			"Bills",
			Vector3.new(s.X * 0.68, s.Y * 0.34, s.Z * 0.68),
			b * CFrame.new(0.2, s.Y * 0.57, 0) * CFrame.Angles(0, 0.3, 0),
			C.bill
		)
		prop(
			m,
			"Bills",
			Vector3.new(s.X * 0.38, s.Y * 0.24, s.Z * 0.4),
			b * CFrame.new(-0.3, s.Y * 0.86, 0.1) * CFrame.Angles(0, -0.2, 0),
			C.billLight
		)
	end,
	gold_bars = function(m, b, s)
		local h = s.Y / 3
		for k, f in { { 1, 1 }, { 0.68, 0.72 }, { 0.36, 0.44 } } do
			local bar =
				prop(m, "Gold", Vector3.new(s.X * f[1], h, s.Z * f[2]), b * CFrame.new(0, h * (k - 0.5), 0), C.gold)
			bar.Reflectance = 0.15
		end
	end,
	trophy = function(m, b, s)
		local base = Color3.fromRGB(30, 30, 36)
		prop(m, "Base", Vector3.new(s.X * 0.5, s.Y * 0.16, s.Z * 0.9), b * CFrame.new(0, s.Y * 0.08, 0), base)
		prop(
			m,
			"Stem",
			Vector3.new(0.6, s.Y * 0.26, 0.6),
			b * CFrame.new(0, s.Y * 0.29, 0),
			C.gold,
			Enum.Material.Metal
		)
		local cupH = s.Y * 0.42
		local cup = prop(
			m,
			"Cup",
			Vector3.new(cupH, s.Z * 0.95, s.Z * 0.95),
			b * CFrame.new(0, s.Y * 0.42 + cupH / 2, 0) * UPRIGHT,
			C.gold,
			Enum.Material.SmoothPlastic,
			Enum.PartType.Cylinder
		)
		cup.Reflectance = 0.2
		for _, sx in { -1, 1 } do
			local cf = b * CFrame.new(sx * s.X * 0.32, s.Y * 0.66, 0)
			prop(m, "Handle", Vector3.new(s.X * 0.12, s.Y * 0.3, 0.4), cf, C.gold, Enum.Material.Metal)
		end
	end,
	money_bag = function(m, b, s)
		local dia = math.min(s.X, s.Y * 0.8)
		prop(
			m,
			"Sack",
			Vector3.new(dia, dia, dia),
			b * CFrame.new(0, dia / 2, 0),
			C.burlap,
			Enum.Material.Fabric,
			Enum.PartType.Ball
		)
		prop(m, "Tie", Vector3.new(0.8, 0.8, 0.8), b * CFrame.new(0, dia + 0.3, 0), C.burlap:Lerp(C.dark, 0.3))
	end,
}

-- One slot Model: placeholder parts + the AssetSlot/LootSlot contract (WorldPivot set once the parts exist).
local function slotModel(parent: Instance, spot: DressSpot, origin: CFrame, accent: Color3): Model
	local m = Instance.new("Model")
	m.Name = spot.name
	local base = origin * CFrame.new(0, PlotService.FLOOR_LIFT, 0) * spot.cf
	local build = PLACEHOLDER[spot.role]
	if build then
		build(m, base, spot.size, accent)
	end
	m.WorldPivot = base
	m:SetAttribute("Category", "Props")
	m:SetAttribute("Role", spot.role)
	m:SetAttribute("Fit", spot.fit)
	m:SetAttribute("Footprint", spot.size)
	if spot.tier ~= nil then
		m:SetAttribute("LootTier", spot.tier)
		CollectionService:AddTag(m, PlotService.TAG_LOOT)
	else
		CollectionService:AddTag(m, PlotService.TAG_SLOT)
	end
	m.Parent = parent
	return m
end

-- A framed ad poster on the inside of the front wall (Decal art from Config/Assets.Images).
local function poster(parent: Instance, origin: CFrame, x: number, image: string, accent: Color3)
	local w, h = 13, 7.3 -- the ad art is 16:9
	local y = 15.4 -- above the lock sign / shelf, below the ceiling lights
	local inward = CFrame.Angles(0, math.pi, 0) -- Front face looks into the garage (+Z)
	local wallZ = G.FRONT_Z + G.WALL_THICKNESS
	deco(
		parent,
		"PosterFrame",
		Vector3.new(w + 0.8, h + 0.8, 0.16),
		origin * CFrame.new(x, y, wallZ + 0.24) * inward,
		accent
	)
	local art =
		deco(parent, "Poster", Vector3.new(w, h, 0.1), origin * CFrame.new(x, y, wallZ + 0.37) * inward, C.white)
	local d = Instance.new("Decal")
	d.Name = "Art"
	d.Face = Enum.NormalId.Front
	d.Texture = image
	d.Parent = art
end

-- Garage income tier -> loot tier (0..#LOOT_TIERS).
function PlotService._lootTier(incomePerSec: any): number
	local ips = if typeof(incomePerSec) == "number" and incomePerSec == incomePerSec then incomePerSec else 0
	local tier = 0
	for i, need in PlotService.LOOT_TIERS do
		if ips >= need then
			tier = i
		end
	end
	return tier
end

-- The Tier1..TierN Models of a freshly built garage (all still parented to Loot), in tier order.
function PlotService._lootTierModels(model: Model): { Model }
	local out = {}
	local loot = model:FindFirstChild("Loot")
	if loot then
		for t = 1, #PlotService.LOOT_TIERS do
			local tm = loot:FindFirstChild("Tier" .. t)
			if tm and tm:IsA("Model") then
				out[t] = tm
			end
		end
	end
	return out
end

-- Shows tiers 1..tier of the loot corner and parks the rest outside the DataModel (they keep their dressing).
function PlotService._applyLootTier(model: Model, tierModels: { Model }, tier: number)
	local loot = model:FindFirstChild("Loot")
	for t, tm in tierModels do
		local want: Instance? = if t <= tier then loot else nil
		if tm.Parent ~= want then
			tm.Parent = want
		end
	end
	model:SetAttribute("LootTier", tier)
end

-- Builds one complete garage model (no player state). Harness-compatible.
function PlotService.buildGarageModel(index: number): Model
	local origin = MapLayout.plotOrigin(index)
	local accent = PlotService.accentFor(index)
	local function L(x: number, y: number, z: number): CFrame
		return origin * CFrame.new(x, y, z)
	end
	local LIFT = PlotService.FLOOR_LIFT
	local HW = G.HALF_WIDTH
	local T = G.WALL_THICKNESS
	local H = G.WALL_HEIGHT
	local FZ, BZ = G.FRONT_Z, G.BACK_Z
	local depth = BZ - FZ
	local midZ = (BZ + FZ) / 2
	local doorHalf = G.DOOR_WIDTH / 2
	local DH = G.DOOR_HEIGHT

	local model = Instance.new("Model")
	model.Name = "Plot" .. index
	model.WorldPivot = origin
	model:SetAttribute("PlotIndex", index)
	model:SetAttribute("Accent", accent)
	model:SetAttribute("OwnerUserId", 0)
	model:SetAttribute("OwnerName", "")
	model:SetAttribute("Locked", false)
	model:SetAttribute("LockEndsAt", 0)
	model:SetAttribute("LockReadyAt", 0)
	CollectionService:AddTag(model, "Plot")

	local building = Instance.new("Folder")
	building.Name = "Building"
	building.Parent = model

	-- Floor + driveway ---------------------------------------------------------------------------------------
	local slabDepth = MapConfig.CURB_HEIGHT + 1 -- reaches below road level so nothing ever shows a gap
	local floor = makePart(
		model,
		"Floor",
		Vector3.new(HW * 2, slabDepth, depth),
		L(0, LIFT - slabDepth / 2, midZ),
		C.floor,
		{ material = Enum.Material.Concrete, shadow = false }
	)
	floor.CanQuery = true
	local lotEdge = -(MapConfig.GRID_SPACING - MapConfig.ROAD_WIDTH) / 2 -- front edge of the block (-60)
	local apronLen = FZ - lotEdge
	local apronW = G.DOOR_WIDTH + 6
	makePart(
		building,
		"Driveway",
		Vector3.new(apronW, slabDepth, apronLen),
		L(0, LIFT - slabDepth / 2 - 0.01, lotEdge + apronLen / 2),
		C.apron,
		{ material = Enum.Material.Concrete, shadow = false }
	)
	for _, sx in { -1, 1 } do
		neon(
			building,
			"DrivewayLine",
			Vector3.new(0.6, 0.06, apronLen),
			L(sx * (apronW / 2 - 1), LIFT + 0.03, lotEdge + apronLen / 2),
			accent
		)
	end
	-- curb ramp from road level up onto the lot (wedge: tall face at +Z = toward the garage)
	local curb = MapConfig.CURB_HEIGHT + LIFT
	makePart(
		building,
		"CurbRamp",
		Vector3.new(apronW, curb, 4),
		L(0, LIFT - curb / 2, lotEdge - 2),
		C.apron,
		{ class = "WedgePart", material = Enum.Material.Concrete, shadow = false }
	)

	-- Walls ------------------------------------------------------------------------------------------------------
	local wallY = H / 2
	makePart(building, "WallLeft", Vector3.new(T, H, depth), L(-HW + T / 2, wallY, midZ), C.wall)
	makePart(building, "WallRight", Vector3.new(T, H, depth), L(HW - T / 2, wallY, midZ), C.wall)
	makePart(building, "WallBack", Vector3.new(HW * 2 - T * 2, H, T), L(0, wallY, BZ - T / 2), C.wall)
	local segW = HW - doorHalf
	makePart(building, "WallFrontL", Vector3.new(segW, H, T), L(-(doorHalf + segW / 2), wallY, FZ + T / 2), C.wall)
	makePart(building, "WallFrontR", Vector3.new(segW, H, T), L(doorHalf + segW / 2, wallY, FZ + T / 2), C.wall)
	makePart(
		building,
		"WallFrontTop",
		Vector3.new(G.DOOR_WIDTH, H - DH, T),
		L(0, DH + (H - DH) / 2, FZ + T / 2),
		C.wall
	)
	-- dark plinth band around the outside
	local pl = 2.4
	deco(building, "Plinth", Vector3.new(0.3, pl, depth + 0.6), L(-HW - 0.15, pl / 2, midZ), C.plinth)
	deco(building, "Plinth", Vector3.new(0.3, pl, depth + 0.6), L(HW + 0.15, pl / 2, midZ), C.plinth)
	deco(building, "Plinth", Vector3.new(HW * 2 + 0.6, pl, 0.3), L(0, pl / 2, BZ + 0.15), C.plinth)
	for _, sx in { -1, 1 } do
		deco(
			building,
			"Plinth",
			Vector3.new(segW - 2.2, pl, 0.3),
			L(sx * (doorHalf + 2.2 + (segW - 2.2) / 2), pl / 2, FZ - 0.15),
			C.plinth
		)
	end
	-- interior wainscot (darker lower walls make the floor + cars pop)
	local ws = 5
	deco(building, "Wainscot", Vector3.new(0.2, ws, depth - T * 2), L(-HW + T + 0.1, ws / 2, midZ), C.header)
	deco(building, "Wainscot", Vector3.new(0.2, ws, depth - T * 2), L(HW - T - 0.1, ws / 2, midZ), C.header)
	deco(building, "Wainscot", Vector3.new(HW * 2 - T * 2, ws, 0.2), L(0, ws / 2, BZ - T - 0.1), C.header)
	for _, sx in { -1, 1 } do
		deco(
			building,
			"Wainscot",
			Vector3.new(segW - T, ws, 0.2),
			L(sx * (doorHalf + (segW - T) / 2), ws / 2, FZ + T + 0.1),
			C.header
		)
	end
	-- accent neon strips: interior (waist height) + exterior (under the roof edge) + front corner pillars
	local stripY = 12
	neon(building, "WallStrip", Vector3.new(0.2, 0.5, depth - T * 2), L(-HW + T + 0.12, stripY, midZ), accent)
	neon(building, "WallStrip", Vector3.new(0.2, 0.5, depth - T * 2), L(HW - T - 0.12, stripY, midZ), accent)
	neon(building, "WallStrip", Vector3.new(HW * 2 - T * 2, 0.5, 0.2), L(0, stripY, BZ - T - 0.12), accent)
	for _, sx in { -1, 1 } do
		neon(
			building,
			"WallStrip",
			Vector3.new(segW - T, 0.5, 0.2),
			L(sx * (doorHalf + (segW - T) / 2), stripY, FZ + T + 0.12),
			accent
		)
	end
	neon(building, "TrimStrip", Vector3.new(0.2, 0.6, depth + 2), L(-HW - 1.1, H - 0.6, midZ), accent)
	neon(building, "TrimStrip", Vector3.new(0.2, 0.6, depth + 2), L(HW + 1.1, H - 0.6, midZ), accent)
	neon(building, "TrimStrip", Vector3.new(HW * 2 + 2.4, 0.6, 0.2), L(0, H - 0.6, BZ + 1.1), accent)
	neon(building, "TrimStrip", Vector3.new(HW * 2 + 2.4, 0.6, 0.2), L(0, H - 0.6, FZ - 1.1), accent)
	for _, sx in { -1, 1 } do
		neon(building, "CornerPillar", Vector3.new(0.5, H - 1, 0.5), L(sx * (HW + 0.1), (H - 1) / 2, FZ - 0.1), accent)
	end
	-- showroom windows either side of the door (fake: glass panels on the facade)
	for _, sx in { -1, 1 } do
		local wx = sx * (doorHalf + segW / 2)
		local wy, ww, wh = 10.5, 18, 8
		local fz = FZ - 0.15
		makePart(building, "Window", Vector3.new(ww, wh, 0.2), L(wx, wy, fz), C.window, {
			material = Enum.Material.Glass,
			collide = false,
			query = false,
			shadow = false,
		})
		deco(building, "WindowFrame", Vector3.new(ww + 1.2, 0.6, 0.5), L(wx, wy + wh / 2 + 0.3, fz - 0.1), C.header)
		deco(building, "WindowFrame", Vector3.new(ww + 1.2, 0.6, 0.5), L(wx, wy - wh / 2 - 0.3, fz - 0.1), C.header)
		deco(building, "WindowFrame", Vector3.new(0.6, wh, 0.5), L(wx - ww / 2 - 0.3, wy, fz - 0.1), C.header)
		deco(building, "WindowFrame", Vector3.new(0.6, wh, 0.5), L(wx + ww / 2 + 0.3, wy, fz - 0.1), C.header)
		deco(building, "WindowFrame", Vector3.new(0.4, wh, 0.3), L(wx, wy, fz - 0.1), C.header)
		neon(building, "WindowSill", Vector3.new(ww + 1.2, 0.3, 0.8), L(wx, wy - wh / 2 - 0.75, fz - 0.3), accent)
	end
	-- exterior pilasters give the box an industrial rhythm
	for _, z in { -32, -16, 0, 16, 32 } do
		for _, sx in { -1, 1 } do
			deco(building, "Pilaster", Vector3.new(0.8, H - 1, 1.8), L(sx * (HW + 0.4), (H - 1) / 2, z), C.pilaster)
		end
	end
	for _, x in { -32, -16, 0, 16, 32 } do
		deco(building, "Pilaster", Vector3.new(1.8, H - 1, 0.8), L(x, (H - 1) / 2, BZ + 0.4), C.pilaster)
	end

	-- Roof with two skylight strips ------------------------------------------------------------------------------
	local ov = 1 -- overhang
	local roofY = H + 0.5
	local rz0, rz1 = FZ - ov, BZ + ov
	local roofDepth = rz1 - rz0
	local roofMidZ = (rz0 + rz1) / 2
	local skyIn, skyOut = 6, 14 -- skylight strips at |x| in [6, 14]
	local skyZ0, skyZ1 = FZ + 8, BZ - 8
	local sideW = (HW + ov) - skyOut
	for _, sx in { -1, 1 } do
		makePart(
			building,
			"Roof",
			Vector3.new(sideW, 1, roofDepth),
			L(sx * (skyOut + sideW / 2), roofY, roofMidZ),
			C.roof
		)
		local sw = skyOut - skyIn
		local cx = sx * (skyIn + sw / 2)
		makePart(building, "Roof", Vector3.new(sw, 1, skyZ0 - rz0), L(cx, roofY, (rz0 + skyZ0) / 2), C.roof)
		makePart(building, "Roof", Vector3.new(sw, 1, rz1 - skyZ1), L(cx, roofY, (skyZ1 + rz1) / 2), C.roof)
		makePart(
			building,
			"Skylight",
			Vector3.new(sw, 0.6, skyZ1 - skyZ0),
			L(cx, roofY, (skyZ0 + skyZ1) / 2),
			C.glass,
			{ material = Enum.Material.Glass, transparency = 0.45, shadow = false }
		)
		-- skylight frame rails
		for _, ex in { skyIn, skyOut } do
			deco(
				building,
				"SkylightRail",
				Vector3.new(0.6, 0.8, skyZ1 - skyZ0 + 0.6),
				L(sx * ex, roofY + 0.7, (skyZ0 + skyZ1) / 2),
				C.metal,
				Enum.Material.Metal
			)
		end
	end
	makePart(building, "Roof", Vector3.new(skyIn * 2, 1, roofDepth), L(0, roofY, roofMidZ), C.roof)
	-- parapet (accent colored) around the roof edge
	local parY = H + 1.7
	deco(building, "Parapet", Vector3.new(HW * 2 + ov * 2, 1.4, 1), L(0, parY, rz0 + 0.5), accent)
	deco(building, "Parapet", Vector3.new(HW * 2 + ov * 2, 1.4, 1), L(0, parY, rz1 - 0.5), accent)
	deco(building, "Parapet", Vector3.new(1, 1.4, roofDepth - 2), L(-(HW + ov) + 0.5, parY, roofMidZ), accent)
	deco(building, "Parapet", Vector3.new(1, 1.4, roofDepth - 2), L(HW + ov - 0.5, parY, roofMidZ), accent)

	-- rooftop AC units
	for i, ac in { { -30, 28 }, { 28, 34 } } do
		makePart(
			building,
			"ACUnit",
			Vector3.new(7, 3, 5.5),
			L(ac[1], roofY + 2, ac[2]),
			C.acUnit,
			{ collide = false, query = false }
		)
		makePart(
			building,
			"ACFan",
			Vector3.new(0.3, 4, 4),
			L(ac[1] + (if i == 1 then -1 else 1), roofY + 3.6, ac[2]) * CFrame.Angles(0, 0, math.pi / 2),
			C.header,
			{ shape = Enum.PartType.Cylinder, material = Enum.Material.Metal, collide = false, query = false }
		)
	end

	-- Ceiling light bars (the interior would be dark otherwise)
	for i, z in { -22, 6, 32 } do
		local bar = neon(building, "LightBar", Vector3.new(3, 0.5, 16), L(0, H - 0.8, z), C.light)
		local hanger =
			deco(building, "LightHanger", Vector3.new(0.3, 0.6, 12), L(0, H - 0.3, z), C.metal, Enum.Material.Metal)
		hanger.CastShadow = false
		local light = Instance.new("PointLight")
		light.Name = "Light" .. i
		light.Range = 42
		light.Brightness = 1.4
		light.Color = C.light
		light.Shadows = false
		light.Parent = bar
	end

	-- Aisle neon edge lines along the pad rows
	local padInner = G.SLOT_X - G.SLOT_PAD_SIZE.X / 2
	local rowZ0 = G.SLOT_ZS[1] - G.SLOT_PAD_SIZE.Z / 2 - 1
	local rowZ1 = G.SLOT_ZS[#G.SLOT_ZS] + G.SLOT_PAD_SIZE.Z / 2 + 1
	for _, sx in { -1, 1 } do
		neon(
			building,
			"AisleLine",
			Vector3.new(0.5, 0.06, rowZ1 - rowZ0),
			L(sx * (padInner - 0.6), LIFT + 0.03, (rowZ0 + rowZ1) / 2),
			accent
		)
	end

	-- Parking pads -------------------------------------------------------------------------------------------------
	for slot = 1, MapLayout.maxPhysicalSlots() do
		buildPad(model, origin, accent, slot)
	end

	-- Drive-out turntable marking (owner cars spawn here) + back-wall banners
	local dov = G.DRIVE_OUT_SPAWN
	local disc = CFrame.Angles(0, 0, math.pi / 2)
	makePart(building, "DriveOutRing", Vector3.new(0.06, 20, 20), L(dov.X, LIFT + 0.03, dov.Z) * disc, accent, {
		shape = Enum.PartType.Cylinder,
		material = Enum.Material.Neon,
		collide = false,
		query = false,
		shadow = false,
	})
	makePart(
		building,
		"DriveOutDisc",
		Vector3.new(0.1, 18.6, 18.6),
		L(dov.X, LIFT + 0.05, dov.Z) * disc,
		accent:Lerp(C.floor, 0.78),
		{
			shape = Enum.PartType.Cylinder,
			collide = false,
			query = false,
			shadow = false,
		}
	)
	-- city logo painted inside the turntable ring (Top-face art reads upright from the owner spawn)
	local logoArt = Assets.Images.logo_hotwire_city
	if logoArt then
		local mat = makePart(
			building,
			"FloorLogo",
			Vector3.new(14, 0.04, 7.9),
			L(dov.X, LIFT + 0.12, dov.Z),
			C.logoBg,
			{ collide = false, transparency = 1, query = false, shadow = false }
		)
		local d = Instance.new("Decal")
		d.Name = "Logo"
		d.Face = Enum.NormalId.Top
		d.Texture = logoArt
		d.Transparency = 0.08
		d.Parent = mat
	end
	for _, sx in { -1, 1 } do
		local bpos = Vector3.new(sx * 32, 13, BZ - T - 0.15)
		local banner = deco(
			building,
			"Banner",
			Vector3.new(7, 12, 0.2),
			origin * CFrame.lookAt(bpos, bpos - Vector3.zAxis),
			accent
		)
		local bgui = surfaceGui(banner, "BannerGui", Enum.NormalId.Front, 10)
		textLabel(
			bgui,
			"Icon",
			if sx < 0 then "🏁" else "💰",
			C.white,
			UDim2.fromScale(0.1, 0.1),
			UDim2.fromScale(0.8, 0.35),
			C.dark,
			3
		)
		textLabel(
			bgui,
			"Text",
			if sx < 0 then "STEAL" else "STACK",
			C.white,
			UDim2.fromScale(0.05, 0.55),
			UDim2.fromScale(0.9, 0.3),
			C.dark,
			3
		)
	end

	-- Drop-off zone --------------------------------------------------------------------------------------------------
	local dc = G.DROPOFF_CENTER
	local ds = G.DROPOFF_SIZE
	local zone = makePart(
		model,
		"Dropoff",
		ds,
		L(dc.X, ds.Y / 2, dc.Z),
		C.hazard,
		{ collide = false, transparency = 1, query = false, shadow = false }
	)
	zone.CanTouch = false
	local mark = makePart(
		model,
		"DropoffMark",
		Vector3.new(ds.X, 0.06, ds.Z),
		L(dc.X, LIFT + 0.03, dc.Z) * CFrame.Angles(0, math.pi, 0),
		Color3.fromRGB(40, 42, 58),
		{ collide = false, query = false, shadow = false }
	)
	local hx, hz = ds.X / 2, ds.Z / 2
	neon(building, "DropoffEdge", Vector3.new(ds.X, 0.08, 0.7), L(dc.X, LIFT + 0.04, dc.Z - hz + 0.35), C.hazard)
	neon(building, "DropoffEdge", Vector3.new(ds.X, 0.08, 0.7), L(dc.X, LIFT + 0.04, dc.Z + hz - 0.35), C.hazard)
	neon(building, "DropoffEdge", Vector3.new(0.7, 0.08, ds.Z), L(dc.X - hx + 0.35, LIFT + 0.04, dc.Z), C.hazard)
	neon(building, "DropoffEdge", Vector3.new(0.7, 0.08, ds.Z), L(dc.X + hx - 0.35, LIFT + 0.04, dc.Z), C.hazard)
	-- chevrons pointing into the garage (+Z)
	for _, cz in { dc.Z - 4.5, dc.Z } do
		for _, sx in { -1, 1 } do
			local a = Vector3.new(0, 0, cz + 2.2)
			local b = Vector3.new(sx * 5, 0, cz - 2.2)
			local mid = (a + b) / 2
			local len = (b - a).Magnitude
			neon(
				building,
				"Chevron",
				Vector3.new(1.1, 0.08, len + 1),
				origin * CFrame.lookAt(mid + Vector3.new(0, LIFT + 0.05, 0), b + Vector3.new(0, LIFT + 0.05, 0)),
				C.hazard
			)
		end
	end
	local mgui = surfaceGui(mark, "DropoffGui", Enum.NormalId.Top, 12, NEAR_GUI)
	textLabel(mgui, "Label", "DROP-OFF", C.hazard, UDim2.fromScale(0.08, 0.04), UDim2.fromScale(0.84, 0.3), C.dark, 4)
	-- hanging sign just inside the door, readable from the street
	local hang = makePart(
		model,
		"DropoffSign",
		Vector3.new(18, 3, 0.4),
		L(0, DH - 1.6, FZ + T + 1.5),
		C.dark,
		{ collide = false, query = false, shadow = false }
	)
	local hgui = surfaceGui(hang, "SignGui", Enum.NormalId.Front, 20, 250) -- readable from the street
	local hroot = frame(hgui, "Root", C.dark, 0, ZERO, FULL)
	uiStroke(hroot, C.hazard, 6)
	textLabel(
		hroot,
		"Label",
		"⬇ DROP-OFF ⬇",
		C.hazard,
		UDim2.fromScale(0.04, 0.1),
		UDim2.fromScale(0.92, 0.8),
		C.dark,
		3
	)
	for _, sx in { -1, 1 } do
		deco(building, "SignCable", Vector3.new(0.2, H - DH, 0.2), L(sx * 8, DH + (H - DH) / 2, FZ + T + 1.5), C.metal)
	end

	-- Collect pad + sign on the back wall ---------------------------------------------------------------------------
	local cc = G.COLLECT_CENTER
	local cs = G.COLLECT_SIZE
	makePart(
		building,
		"CollectRim",
		Vector3.new(cs.X + 1.6, cs.Y * 0.6, cs.Z + 1.6),
		L(cc.X, LIFT + cs.Y * 0.3, cc.Z),
		C.cashDark,
		{ collide = true, query = false, shadow = false }
	)
	local collect = makePart(
		model,
		"CollectPad",
		cs,
		L(cc.X, LIFT + cs.Y / 2 + 0.02, cc.Z) * CFrame.Angles(0, math.pi, 0),
		C.cash,
		{ material = Enum.Material.Neon, collide = true, query = false, shadow = false, touch = true }
	)
	local cgui = surfaceGui(collect, "PadGui", Enum.NormalId.Top, 16, NEAR_GUI)
	textLabel(
		cgui,
		"Label",
		"$ COLLECT $",
		C.white,
		UDim2.fromScale(0.06, 0.36),
		UDim2.fromScale(0.88, 0.28),
		C.cashDark,
		4
	)
	local cpos = Vector3.new(cc.X, 9.5, BZ - T - 0.25)
	local csign = makePart(
		model,
		"CollectSign",
		Vector3.new(18, 5.5, 0.4),
		origin * CFrame.lookAt(cpos, cpos - Vector3.zAxis),
		C.dark,
		{ collide = false, query = false, shadow = false }
	)
	local csg = surfaceGui(csign, "SignGui", Enum.NormalId.Front, 20, NEAR_GUI)
	local croot = frame(csg, "Root", C.dark, 0, ZERO, FULL)
	uiStroke(croot, C.cash, 8)
	textLabel(croot, "Title", "💰 COLLECT", C.cash, UDim2.fromScale(0.05, 0.08), UDim2.fromScale(0.9, 0.5), C.dark, 4)
	textLabel(
		croot,
		"Amount",
		"Step on the pad!",
		C.white,
		UDim2.fromScale(0.08, 0.6),
		UDim2.fromScale(0.84, 0.32),
		C.dark,
		3
	)

	-- Lock button + sign ---------------------------------------------------------------------------------------------
	local lb = G.LOCK_BUTTON
	local lockDepth = 4
	makePart(
		building,
		"LockBase",
		Vector3.new(7.2, 0.3, lockDepth + 0.8),
		L(lb.X, LIFT + 0.15, lb.Z + 0.4),
		C.header,
		{ collide = true, query = false, shadow = false }
	)
	local lockBtn = makePart(
		model,
		"LockButton",
		Vector3.new(6, 0.5, lockDepth),
		L(lb.X, LIFT + 0.25, lb.Z + 0.4) * CFrame.Angles(0, math.pi, 0),
		C.lock,
		{ material = Enum.Material.Neon, collide = true, query = false, shadow = false, touch = true }
	)
	local lgui = surfaceGui(lockBtn, "PadGui", Enum.NormalId.Top, 20, NEAR_GUI)
	textLabel(lgui, "Label", "🔒", C.white, UDim2.fromScale(0.3, 0.1), UDim2.fromScale(0.4, 0.8))
	local lpos = Vector3.new(lb.X, 6.5, FZ + T + 0.25)
	local lsign = makePart(
		model,
		"LockSign",
		Vector3.new(9, 4, 0.4),
		origin * CFrame.lookAt(lpos, lpos + Vector3.zAxis),
		C.dark,
		{ collide = false, query = false, shadow = false }
	)
	local lsg = surfaceGui(lsign, "SignGui", Enum.NormalId.Front, 24, NEAR_GUI)
	local lroot = frame(lsg, "Root", C.dark, 0, ZERO, FULL)
	uiStroke(lroot, C.lock, 8)
	textLabel(
		lroot,
		"Title",
		"🔒 LASER LOCK",
		C.lock,
		UDim2.fromScale(0.05, 0.08),
		UDim2.fromScale(0.9, 0.46),
		C.dark,
		3
	)
	textLabel(
		lroot,
		"Status",
		"STEP ON THE BUTTON",
		C.white,
		UDim2.fromScale(0.08, 0.6),
		UDim2.fromScale(0.84, 0.3),
		C.dark,
		3
	)

	-- Door frame, laser gate, status light ---------------------------------------------------------------------------
	for _, sx in { -1, 1 } do
		makePart(
			building,
			"DoorPost",
			Vector3.new(2.2, DH + 1, 3),
			L(sx * (doorHalf + 0.9), (DH + 1) / 2, FZ + 0.5),
			C.hazard
		)
		-- laser emitter heads on the post faces
		for b = 1, 5 do
			neon(
				building,
				"Emitter",
				Vector3.new(0.3, 0.5, 0.5),
				L(sx * (doorHalf - 0.35), 1.5 + (b - 1) * 3, FZ + T / 2),
				C.laser
			)
		end
	end
	makePart(building, "DoorHeader", Vector3.new(G.DOOR_WIDTH + 4.6, 2.2, 3), L(0, DH + 0.9, FZ + 0.5), C.header)
	makePart(
		building,
		"ShutterRoll",
		Vector3.new(G.DOOR_WIDTH, 3, 3),
		L(0, DH + 1.6, FZ + T + 1.6),
		C.metal,
		{ shape = Enum.PartType.Cylinder, material = Enum.Material.Metal, collide = false, query = false }
	)
	local status = neon(model, "StatusLight", Vector3.new(G.DOOR_WIDTH - 6, 0.7, 0.2), L(0, DH + 0.9, FZ - 1.1), C.open)
	status.CastShadow = false

	local gate = makePart(
		model,
		"Gate",
		Vector3.new(G.DOOR_WIDTH, DH, 0.4),
		L(0, LIFT + DH / 2, FZ + T / 2),
		C.laser,
		{ material = Enum.Material.Neon, collide = false, transparency = 1, query = false, shadow = false }
	)
	for b = 1, 5 do
		local beam =
			neon(gate, "Beam" .. b, Vector3.new(G.DOOR_WIDTH, 0.22, 0.22), L(0, 1.5 + (b - 1) * 3, FZ + T / 2), C.laser)
		beam.Transparency = 1
	end
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local gg =
			surfaceGui(gate, if face == Enum.NormalId.Front then "CountdownGui" else "CountdownGuiBack", face, 10)
		gg.Enabled = false
		gg.AlwaysOnTop = false
		local box =
			frame(gg, "Box", Color3.fromRGB(30, 6, 12), 0.25, UDim2.fromScale(0.28, 0.3), UDim2.fromScale(0.44, 0.34))
		corner(box, 0.2)
		uiStroke(box, C.laser, 4)
		textLabel(
			box,
			"Time",
			"🔒 0:00",
			C.white,
			UDim2.fromScale(0.06, 0.08),
			UDim2.fromScale(0.88, 0.84),
			C.laser,
			3
		)
	end

	-- Owner sign above the door -----------------------------------------------------------------------------------
	local sp = G.SIGN
	local signSize = Vector3.new(46, 9, 4)
	local sign = makePart(model, "Sign", signSize, L(sp.X, sp.Y, sp.Z), C.dark, { collide = true, query = false })
	local front = sp.Z - signSize.Z / 2 - 0.06
	neon(sign, "SignTrim", Vector3.new(signSize.X, 0.45, 0.12), L(sp.X, sp.Y + signSize.Y / 2 - 0.25, front), accent)
	neon(sign, "SignTrim", Vector3.new(signSize.X, 0.45, 0.12), L(sp.X, sp.Y - signSize.Y / 2 + 0.25, front), accent)
	neon(sign, "SignTrim", Vector3.new(0.45, signSize.Y, 0.12), L(sp.X - signSize.X / 2 + 0.25, sp.Y, front), accent)
	neon(sign, "SignTrim", Vector3.new(0.45, signSize.Y, 0.12), L(sp.X + signSize.X / 2 - 0.25, sp.Y, front), accent)
	local sgui = surfaceGui(sign, "SignGui", Enum.NormalId.Front, 14)
	local owner = textLabel(
		sgui,
		"OwnerName",
		"VACANT GARAGE",
		C.white,
		UDim2.fromScale(0.04, 0.08),
		UDim2.fromScale(0.92, 0.56),
		C.dark,
		5
	)
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new(C.white, accent)
	grad.Rotation = 90
	grad.Parent = owner
	local stats = textLabel(
		sgui,
		"Stats",
		"#" .. index .. "  •  Join to claim!",
		accent,
		UDim2.fromScale(0.1, 0.66),
		UDim2.fromScale(0.8, 0.28),
		C.dark,
		3
	)
	stats.FontFace = FONT_BODY
	-- city logo on a backing board crowning the owner sign (art on both faces: street + rooftop side)
	local logo = Assets.Images.logo_hotwire_city
	if logo then
		local crownW, crownH = 17, 9.5 -- 16:9 like the logo art
		local signTop = sp.Y + signSize.Y / 2
		local crown = makePart(
			building,
			"SignLogo",
			Vector3.new(crownW, crownH, 0.8),
			L(sp.X, signTop + 0.35 + crownH / 2, sp.Z),
			C.logoBg,
			{ collide = false, query = false, shadow = false }
		)
		neon(building, "SignLogoTrim", Vector3.new(crownW + 0.6, 0.35, 1), L(sp.X, signTop + 0.17, sp.Z), accent)
		for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
			local d = Instance.new("Decal")
			d.Name = "Logo"
			d.Face = face
			d.Texture = logo
			d.Parent = crown
		end
	end

	-- Side wall murals (visible from the street)
	for _, face in { Enum.NormalId.Left, Enum.NormalId.Right } do
		local wall = building:FindFirstChild(if face == Enum.NormalId.Left then "WallLeft" else "WallRight") :: BasePart
		local mg = surfaceGui(wall, "Mural", face, 6)
		textLabel(
			mg,
			"Label",
			"HOTWIRE GARAGE #" .. index,
			accent,
			UDim2.fromScale(0.08, 0.25),
			UDim2.fromScale(0.84, 0.4),
			C.dark,
			4
		)
	end
	local backWall = building:FindFirstChild("WallBack") :: BasePart
	local bg = surfaceGui(backWall, "Mural", Enum.NormalId.Front, 6)
	textLabel(bg, "Label", "HOTWIRE CITY", accent, UDim2.fromScale(0.2, 0.04), UDim2.fromScale(0.6, 0.22), C.dark, 4)

	-- Hangout props --------------------------------------------------------------------------------------------------
	local couchColor = accent:Lerp(Color3.new(0, 0, 0), 0.35)
	local cushion = accent:Lerp(Color3.new(1, 1, 1), 0.15)
	local couchX, couchZ = -17.5, BZ - T - 3.4 -- left of the collect pad (the loot corner is on its right)
	makePart(
		building,
		"CouchSeat",
		Vector3.new(10, 1.8, 4),
		L(couchX, LIFT + 0.9, couchZ),
		cushion,
		{ material = Enum.Material.Fabric }
	)
	makePart(
		building,
		"CouchBack",
		Vector3.new(10, 3.4, 1.2),
		L(couchX, LIFT + 1.7, couchZ + 2.2),
		couchColor,
		{ material = Enum.Material.Fabric }
	)
	for _, sx in { -1, 1 } do
		makePart(
			building,
			"CouchArm",
			Vector3.new(1.2, 2.6, 4.6),
			L(couchX + sx * 5.6, LIFT + 1.3, couchZ + 0.3),
			couchColor,
			{ material = Enum.Material.Fabric }
		)
	end
	deco(
		building,
		"Rug",
		Vector3.new(14, 0.06, 7),
		L(couchX, LIFT + 0.03, couchZ - 3.6),
		accent:Lerp(C.dark, 0.6),
		Enum.Material.Fabric
	)
	-- Kit dressing: wall-prop slots (MapDresser) + the loot corner (dressed and toggled here) ------------------------
	local dressing = Instance.new("Folder")
	dressing.Name = "Dressing"
	dressing.Parent = model
	local loot = Instance.new("Model")
	loot.Name = "Loot"
	loot.Parent = model
	local tierModels: { Model } = {}
	for t = 1, #PlotService.LOOT_TIERS do
		local tm = Instance.new("Model")
		tm.Name = "Tier" .. t
		tm:SetAttribute("LootTier", t)
		tm.Parent = loot
		tierModels[t] = tm
	end
	for _, spot in PlotService._dressLayout(index) do
		local parent: Instance = if spot.tier == nil
			then dressing
			elseif spot.tier == 0 then loot
			else tierModels[spot.tier] or loot
		slotModel(parent, spot, origin, accent)
	end
	-- a warm glow over the pile once the trophy shows up
	local glowAt = G.COLLECT_CENTER + Vector3.new(16, 7, 2)
	local glow = makePart(
		tierModels[math.min(3, #tierModels)] or loot,
		"LootGlow",
		Vector3.new(0.4, 0.4, 0.4),
		L(glowAt.X, glowAt.Y, glowAt.Z),
		C.gold,
		{ collide = false, transparency = 1, query = false, shadow = false }
	)
	local glowLight = Instance.new("PointLight")
	glowLight.Color = C.gold
	glowLight.Range = 16
	glowLight.Brightness = 1.3
	glowLight.Shadows = false
	glowLight.Parent = glow
	model:SetAttribute("LootTier", #PlotService.LOOT_TIERS)

	-- two different ad posters inside the front wall, either side of the door (deterministic per plot)
	local ads = Assets.billboardAds()
	if #ads > 0 then
		local first = ((index - 1) * 3) % #ads + 1
		local second = ((index - 1) * 3 + 4) % #ads + 1
		poster(building, origin, -24.9, ads[first], accent)
		poster(building, origin, 24.9, ads[if second == first then first % #ads + 1 else second], accent)
	end

	-- Display folder + owner spawn ----------------------------------------------------------------------------------
	local display = Instance.new("Folder")
	display.Name = "Display"
	display.Parent = model
	local os_ = G.OWNER_SPAWN
	makePart(
		model,
		"OwnerSpawn",
		Vector3.new(4, 1, 4),
		L(os_.X, LIFT + 0.5, os_.Z),
		C.white,
		{ collide = false, transparency = 1, query = false, shadow = false }
	)

	return model
end

-- Runtime ---------------------------------------------------------------------------------------------------------

type PlotState = PlotInfo & {
	gate: BasePart,
	beams: { BasePart },
	countdown: { TextLabel },
	countdownGuis: { SurfaceGui },
	lockStatus: TextLabel?,
	statusLight: BasePart?,
	signName: TextLabel?,
	signStats: TextLabel?,
	zoneCf: CFrame,
	zoneSize: Vector3,
	lockedVisual: boolean,
	lastShown: number,
	lastLockDuration: number, -- seconds of the last button lock (sets the proportional re-arm)
	spawn: SpawnLocation?, -- "PlotSpawn": the owner's RespawnLocation
	lootTierModels: { Model }, -- Loot.Tier1..N (parented to Loot only while unlocked)
	lootSlots: { Model }, -- every LootSlot of every tier (dressed even while hidden)
	lootTier: number, -- tier currently shown (-1 = not applied yet)
}

local plots: { PlotState } = {}
local playerPlot: { [Player]: number } = {}
local goHomeAt: { [Player]: number } = {}
local notifyAt: { [Player]: number } = {}
local plotsFolder: Folder? = nil

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
	if ok and mod then
		systemCache[name] = mod
		return mod
	end
	return nil
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function notify(player: Player, kind: string, text: string, debounce: boolean?)
	if debounce then
		local now = os.clock()
		if (notifyAt[player] or 0) > now then
			return
		end
		notifyAt[player] = now + 2.5
	end
	Net.fireClient("Notify", player, kind, text)
end

local function sound(player: Player, key: string, pos: Vector3?)
	Net.fireClient("Sound", player, key, pos)
end

local function rootOf(player: Player): (BasePart?, Humanoid?)
	local char = player.Character
	if not char then
		return nil, nil
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	local hum = char:FindFirstChildOfClass("Humanoid")
	if root and root:IsA("BasePart") then
		return root, hum
	end
	return nil, hum
end

local function playerFromHit(hit: BasePart): Player?
	local node: Instance? = hit.Parent
	for _ = 1, 3 do
		if not node then
			return nil
		end
		local p = Players:GetPlayerFromCharacter(node)
		if p then
			return p
		end
		node = node.Parent
	end
	return nil
end

function PlotService.ownerSpawnCFrame(index: number): CFrame
	return MapLayout.plotToWorld(index, G.OWNER_SPAWN + Vector3.new(0, PlotService.FLOOR_LIFT, 0))
end

local function characterHeight(char: Model): number
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if hum and root and root:IsA("BasePart") and hum.RigType == Enum.HumanoidRigType.R15 then
		return hum.HipHeight + root.Size.Y / 2 + 0.25
	end
	return 3.25
end

local function moveCharacterHome(player: Player)
	local index = playerPlot[player]
	local char = player.Character
	if not index or not char or not char.Parent then
		return
	end
	local cf = PlotService.ownerSpawnCFrame(index) * CFrame.new(0, characterHeight(char), 0)
	char:PivotTo(cf)
	local root = char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.AssemblyLinearVelocity = Vector3.zero
	end
end

-- Loot corner ------------------------------------------------------------------------------------------------------

local function ownerIncome(st: PlotState): number
	local owner = st.owner
	local ips = owner and owner:GetAttribute("IncomePerSec")
	if typeof(ips) ~= "number" then
		ips = st.model:GetAttribute("IncomePerSec")
	end
	return if typeof(ips) == "number" then ips else 0
end

-- Show the loot tiers the owner's income has unlocked (vacant garages keep just the safe).
local function updateLoot(st: PlotState)
	local tier = if st.owner then PlotService._lootTier(ownerIncome(st)) else 0
	if tier ~= st.lootTier then
		st.lootTier = tier
		PlotService._applyLootTier(st.model, st.lootTierModels, tier)
	end
end

-- Swap one loot placeholder for its AssetLibrary mesh (scaled to the slot's Fit). False while the template is missing:
-- the placeholder simply stays (procedural fallback).
local function dressLootSlot(slot: Model): boolean
	if slot:GetAttribute("Dressed") == true then
		return true
	end
	local AssetLibrary = sys("AssetLibrary")
	local role = slot:GetAttribute("Role")
	if not AssetLibrary or typeof(AssetLibrary.get) ~= "function" or typeof(role) ~= "string" then
		return false
	end
	local okGet, template = pcall(AssetLibrary.get, "Props", role)
	if not okGet or typeof(template) ~= "Instance" or not template:IsA("Model") then
		return false
	end
	local def = Assets.Props[role]
	local fit = slot:GetAttribute("Fit")
	local ground = slot:GetPivot()
	local ok, res = pcall(function(): Model
		local c = (template :: Model):Clone()
		if def and typeof(fit) == "number" and fit > 0 and math.abs(fit - def.size) > 1e-3 then
			c:ScaleTo(c:GetScale() * fit / def.size)
		end
		c:PivotTo(ground)
		return c
	end)
	if not ok or typeof(res) ~= "Instance" then
		warn(("[PlotService] loot mesh %s failed: %s"):format(role, tostring(res)))
		return false
	end
	local mesh = res :: Model
	for _, d in mesh:GetDescendants() do
		if d:IsA("BasePart") then
			d.CastShadow = false
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
	-- the placeholder goes only once the mesh stands in its place
	for _, child in slot:GetChildren() do
		if child:IsA("BasePart") then
			child:Destroy()
		end
	end
	mesh.Name = "Mesh"
	mesh.Parent = slot
	slot.WorldPivot = ground
	slot:SetAttribute("Dressed", true)
	return true
end

-- Dress every loot slot (of every plot, hidden tiers included) whose role is `role` (nil = all).
local function dressLoot(role: string?)
	for _, st in plots do
		for _, slot in st.lootSlots do
			if role == nil or slot:GetAttribute("Role") == role then
				dressLootSlot(slot)
			end
		end
	end
end

-- Hand each garage's wall-prop slots to MapDresser (docs/ART_PASS.md AP2: dressAll(root) is its entry point for
-- systems that tag their own slots). `lateOnly` waits for the first full pass so boot doesn't dress piecemeal.
local wallPassDone = false
local function dressWallProps(lateOnly: boolean)
	if lateOnly and not wallPassDone then
		return
	end
	wallPassDone = true
	local MapDresser = sys("MapDresser")
	if not MapDresser or typeof(MapDresser.dressAll) ~= "function" then
		return
	end
	for _, st in plots do
		local dressing = st.model:FindFirstChild("Dressing")
		if dressing then
			local ok, err = pcall(MapDresser.dressAll, dressing)
			if not ok then
				warn("[PlotService] wall props: " .. tostring(err))
			end
		end
	end
end

local function setSign(st: PlotState)
	if st.signName then
		st.signName.Text = if st.owner then `{st.owner.DisplayName}'s Garage` else "VACANT GARAGE"
	end
	if st.signStats then
		if st.owner then
			local ips = st.owner:GetAttribute("IncomePerSec")
			local cars = st.model:GetAttribute("CarCount")
			st.signStats.Text = `💰 {Format.cash(if typeof(ips) == "number" then ips else 0)}/s   🚗 {if typeof(
					cars
				) == "number"
				then cars
				else 0}`
		else
			st.signStats.Text = `#{st.index}  •  Join to claim!`
		end
	end
end

local function applyLockVisual(st: PlotState, locked: boolean)
	st.lockedVisual = locked
	st.gate.CanCollide = locked
	st.gate.Transparency = if locked then 0.82 else 1
	for _, b in st.beams do
		b.Transparency = if locked then 0 else 1
	end
	for _, g in st.countdownGuis do
		g.Enabled = locked
	end
	if st.statusLight then
		st.statusLight.Color = if locked then C.laser else C.open
	end
	st.model:SetAttribute("Locked", locked)
	if not locked then
		st.model:SetAttribute("LockEndsAt", 0)
		if st.lockStatus then
			st.lockStatus.Text = "STEP ON THE BUTTON"
		end
	end
	st.lastShown = -1
end

local function updateCountdown(st: PlotState, now: number)
	local remaining = math.max(0, math.ceil(st.lockedUntil - now))
	if remaining == st.lastShown then
		return
	end
	st.lastShown = remaining
	local text = "🔒 " .. Format.clock(remaining)
	for _, lbl in st.countdown do
		lbl.Text = text
	end
	if st.lockStatus then
		st.lockStatus.Text = "LOCKED " .. Format.clock(remaining)
	end
end

-- VehicleService car for a model (nil if VehicleService isn't loaded or the model isn't one of its cars).
local function vehicleOf(carModel: Model): (any, any)
	local VS = sys("VehicleService")
	if not VS or typeof(VS.fromModel) ~= "function" then
		return nil, nil
	end
	local ok, car = pcall(VS.fromModel, carModel)
	return VS, if ok and type(car) == "table" then car else nil
end

-- Is this driven car stolen from the plot's owner (TheftService replicates Kind / TheftVictimUserId)?
local function stolenFromOwner(st: PlotState, carModel: Model, car: any): boolean
	local owner = st.owner
	if not owner then
		return false
	end
	local victim = carModel:GetAttribute("TheftVictimUserId")
	if victim == nil and car and type(car.data) == "table" and type(car.data.theft) == "table" then
		victim = car.data.theft.victimUserId
	end
	local kind = carModel:GetAttribute("Kind")
	if kind == nil and car then
		kind = car.kind
	end
	return PlotService._ejectOnLock(kind, victim, owner.UserId)
end

-- Teleport anyone who isn't the owner out of a locked garage. A thief in a car stolen from this garage is ejected
-- and leaves on foot (the car stays inside for the owner to Recover); any other car leaves with its driver.
local function pushOut(st: PlotState)
	local n = 0
	for _, p in Players:GetPlayers() do
		if p == st.owner then
			continue
		end
		local root, hum = rootOf(p)
		if not root or not MapLayout.isInBox(st.zoneCf, st.zoneSize, root.Position) then
			continue
		end
		n += 1
		local spot = MapLayout.plotToWorld(st.index, PlotService._drivewayOffset(n))
		local seat = hum and hum.SeatPart
		local carModel = seat and seat:IsA("VehicleSeat") and seat:FindFirstAncestorWhichIsA("Model")
		local driven = false
		if carModel and carModel ~= p.Character and CollectionService:HasTag(carModel, "Vehicle") then
			driven = true
		end
		local VS: any, car: any = nil, nil
		if driven and carModel then
			VS, car = vehicleOf(carModel)
			if stolenFromOwner(st, carModel, car) then
				-- the eject fires DriverChanged -> TheftService marks the car dropped (Recover prompt for the owner)
				if car and typeof(VS.eject) == "function" then
					local okEject, errEject = pcall(VS.eject, car)
					if not okEject then
						warn("[PlotService] eject failed: " .. tostring(errEject))
					end
				end
				driven = false -- push the thief out on foot below
			end
		end
		if driven and carModel then
			local ride = carModel:GetAttribute("RideHeight")
			local target = spot * CFrame.new(0, (if typeof(ride) == "number" then ride else 2) + 0.5, -2)
			-- zero velocity first: teleport re-baselines the watchdog / crash damage from the current velocity
			local primary = carModel.PrimaryPart
			if primary then
				primary.AssemblyLinearVelocity = Vector3.zero
				primary.AssemblyAngularVelocity = Vector3.zero
			end
			local moved = false
			if car and typeof(VS.teleport) == "function" then
				local okTp, errTp = pcall(VS.teleport, car, target)
				moved = okTp
				if not okTp then
					warn("[PlotService] teleport failed: " .. tostring(errTp))
				end
			end
			if not moved then
				carModel:PivotTo(target) -- not a VehicleService car: nothing watches it
			end
		else
			if seat then
				local weld = seat:FindFirstChild("SeatWeld")
				if weld then
					weld:Destroy()
				end
			end
			local char = p.Character
			if char then
				char:PivotTo(spot * CFrame.new(0, characterHeight(char), 0))
				root.AssemblyLinearVelocity = Vector3.zero
			end
		end
		notify(p, "warning", "🔒 This garage is laser-locked!", true)
	end
end

local function unlock(st: PlotState, expired: boolean)
	st.lockedUntil = 0
	if st.lockedVisual then
		applyLockVisual(st, false)
		if expired then
			local rearm = PlotService._rearmSeconds(st.lastLockDuration)
			st.lockReadyAt = os.clock() + rearm
			st.model:SetAttribute("LockReadyAt", serverNow() + rearm)
			local owner = st.owner
			if owner then
				notify(owner, "warning", "🔓 Your laser lock is OFF — guard your cars!")
			end
		end
	end
end

function PlotService.isLocked(index: number): boolean
	local st = plots[index]
	return st ~= nil and st.lockedUntil > os.clock()
end

function PlotService.lockSecondsLeft(index: number): number
	local st = plots[index]
	if not st then
		return 0
	end
	return math.max(0, st.lockedUntil - os.clock())
end

-- Locks (or extends the lock on) a garage. Returns false when nothing was locked (bad plot / duration), so the
-- Lockdown product never charges for nothing.
function PlotService.lockFor(index: number, seconds: number): boolean
	local st = plots[index]
	if not st or typeof(seconds) ~= "number" or seconds ~= seconds or seconds <= 0 then
		return false
	end
	local now = os.clock()
	st.lockedUntil = PlotService._stackLock(st.lockedUntil, now, seconds)
	st.model:SetAttribute("LockEndsAt", serverNow() + (st.lockedUntil - now))
	if not st.lockedVisual then
		applyLockVisual(st, true)
	end
	updateCountdown(st, now)
	local ok, err = pcall(pushOut, st)
	if not ok then
		warn("[PlotService] pushOut failed: " .. tostring(err))
	end
	return true
end

function PlotService.lockDurationFor(player: Player): number
	local DataService = sys("DataService")
	local data = DataService and DataService.get(player)
	local level = 0
	local rebirths = 0
	if data then
		level = (data.upgrades and data.upgrades.lock) or 0
		rebirths = data.rebirths or 0
	end
	return PlotService._lockDuration(level, rebirths)
end

function PlotService.isInside(player: Player, index: number): boolean
	local st = plots[index]
	local root = rootOf(player)
	return st ~= nil and root ~= nil and MapLayout.isInBox(st.zoneCf, st.zoneSize, root.Position)
end

-- Owner pressed the lock (button touch or LockGarage remote). Returns true if the garage got locked.
function PlotService.tryLock(player: Player, fromTouch: boolean?): boolean
	local index = playerPlot[player]
	local st = index and plots[index]
	if not st or st.owner ~= player then
		return false
	end
	local _, hum = rootOf(player)
	if not hum or hum.Health <= 0 then
		return false
	end
	if not PlotService.isInside(player, st.index) then
		notify(player, "error", "Get inside your garage to lock it!", fromTouch)
		return false
	end
	local now = os.clock()
	if st.lockedUntil > now then
		notify(player, "info", "🔒 Already locked: " .. Format.clock(st.lockedUntil - now), true)
		return false
	end
	if st.lockReadyAt > now then
		notify(player, "warning", "⏳ Lock recharging: " .. math.ceil(st.lockReadyAt - now) .. "s", true)
		return false
	end
	local duration = PlotService.lockDurationFor(player)
	st.lastLockDuration = duration -- only button locks set the re-arm; a Lockdown purchase (lockFor) doesn't
	PlotService.lockFor(st.index, duration)
	notify(player, "success", `🔒 Garage locked for {math.floor(duration)}s!`)
	sound(player, "ClickBright")
	return true
end

function PlotService.getPlot(player: Player): PlotInfo?
	local index = playerPlot[player]
	return if index then plots[index] else nil
end

function PlotService.getPlotIndex(player: Player): number?
	return playerPlot[player]
end

function PlotService.getOwner(index: number): Player?
	local st = plots[index]
	return if st then st.owner else nil
end

function PlotService.plotAt(position: Vector3): number?
	return MapLayout.plotAt(position)
end

function PlotService.getPlotModel(index: number): Model?
	local st = plots[index]
	return if st then st.model else nil
end

function PlotService.getDisplayFolder(index: number): Folder?
	local st = plots[index]
	return if st then st.display else nil
end

function PlotService.getPlotsFolder(): Folder?
	return plotsFolder
end

-- Reset every pad to the neutral (vacant) look.
local function resetPads(st: PlotState)
	for slot = 1, MapLayout.maxPhysicalSlots() do
		local pad = st.model:FindFirstChild("Pad" .. slot)
		if pad then
			pad:SetAttribute("Locked", false)
			pad:SetAttribute("Price", 0)
			pad:SetAttribute("PassOnly", false)
			pad:SetAttribute("NextUnlock", false)
			pad:SetAttribute("State", "Empty")
		end
	end
end

local function assign(player: Player): number?
	if playerPlot[player] then
		return playerPlot[player]
	end
	for _, st in plots do
		if st.owner == nil then
			st.owner = player
			playerPlot[player] = st.index
			st.lockedUntil = 0
			st.lockReadyAt = 0
			st.lastLockDuration = 0
			st.model:SetAttribute("OwnerUserId", player.UserId)
			st.model:SetAttribute("OwnerName", player.DisplayName)
			st.model:SetAttribute("LockReadyAt", 0)
			player:SetAttribute("PlotIndex", st.index)
			local spawnPad = st.spawn
			if spawnPad then
				-- spawn straight into the garage (no plaza flash, SPAWN-FLASH); onCharacter still pivots as a fallback
				spawnPad.Enabled = true
				pcall(function()
					player.RespawnLocation = spawnPad
				end)
			end
			setSign(st)
			updateLoot(st)
			PlotService.PlotAssigned:Fire(player, st.index)
			return st.index
		end
	end
	warn(("[PlotService] no free plot for %s"):format(player.Name))
	return nil
end

local function release(player: Player)
	local index = playerPlot[player]
	playerPlot[player] = nil
	goHomeAt[player] = nil
	notifyAt[player] = nil
	if not index then
		return
	end
	local st = plots[index]
	if not st or st.owner ~= player then
		return
	end
	unlock(st, false)
	st.owner = nil
	st.lockReadyAt = 0
	st.lastLockDuration = 0
	local spawnPad = st.spawn
	if spawnPad then
		spawnPad.Enabled = false -- a vacant garage is never a random spawn
		pcall(function()
			if player.RespawnLocation == spawnPad then
				player.RespawnLocation = nil
			end
		end)
	end
	st.model:SetAttribute("OwnerUserId", 0)
	st.model:SetAttribute("OwnerName", "")
	st.model:SetAttribute("LockReadyAt", 0)
	for _, child in st.display:GetChildren() do
		child:Destroy()
	end
	resetPads(st)
	setSign(st)
	updateLoot(st)
	PlotService.PlotReleased:Fire(player, index)
end

-- True once after the player was busted for dying while wanted: that spawn goes to Police HQ, so resetting is no
-- free escape into the safe garage (WantedService owns the rule; F3).
local function respawnAtHQ(player: Player): boolean
	local WantedService = sys("WantedService")
	if not WantedService or typeof(WantedService.consumeRespawnAtHQ) ~= "function" then
		return false
	end
	local ok, res = pcall(WantedService.consumeRespawnAtHQ, player)
	return ok and res == true
end

local function onCharacter(player: Player, char: Model)
	task.defer(function()
		local root = char:WaitForChild("HumanoidRootPart", 10)
		if not root or not root:IsA("BasePart") or char.Parent == nil or player.Character ~= char then
			return
		end
		if respawnAtHQ(player) then
			local jitter = Vector3.new(math.random(-40, 40) / 10, 0, math.random(-40, 40) / 10)
			char:PivotTo(MapLayout.bustedReleaseCFrame() + jitter)
			root.AssemblyLinearVelocity = Vector3.zero
			return
		end
		-- normally the engine already spawned it on the plot's SpawnLocation; pivot only if it landed elsewhere
		local index = playerPlot[player]
		if index then
			local offset = root.Position - PlotService.ownerSpawnCFrame(index).Position
			if Vector3.new(offset.X, 0, offset.Z).Magnitude <= 8 and math.abs(offset.Y) <= 8 then
				return
			end
		end
		moveCharacterHome(player)
	end)
end

local function onGoHome(player: Player)
	local index = playerPlot[player]
	if not index then
		return
	end
	local root, hum = rootOf(player)
	if not root or not hum or hum.Health <= 0 then
		return
	end
	if hum.SeatPart or player:GetAttribute("Driving") == true then
		notify(player, "error", "Hop out of the car first!")
		return
	end
	local wanted = player:GetAttribute("Wanted")
	if typeof(wanted) == "number" and wanted > 0 then
		notify(player, "error", "🚔 Can't go home with the cops on your tail!")
		return
	end
	if player:GetAttribute("Stunned") == true then
		return
	end
	local now = os.clock()
	local readyAt = goHomeAt[player] or 0
	if now < readyAt then
		notify(player, "warning", `🏠 Go Home ready in {math.ceil(readyAt - now)}s`)
		return
	end
	goHomeAt[player] = now + PlotService.GO_HOME_COOLDOWN
	moveCharacterHome(player)
	sound(player, "Whoosh")
end

function PlotService.init()
	local folder = Workspace:FindFirstChild("Plots")
	if not folder then
		local f = Instance.new("Folder")
		f.Name = "Plots"
		f.Parent = Workspace
		folder = f
	end
	plotsFolder = folder :: Folder
	for index = 1, MapLayout.plotCount() do
		local old = (folder :: Folder):FindFirstChild("Plot" .. index)
		if old then
			old:Destroy()
		end
		local model = PlotService.buildGarageModel(index)
		local zoneCf, zoneSize = MapLayout.plotInteriorZone(index)
		local gate = model:FindFirstChild("Gate") :: BasePart
		local beams = {}
		local countdown = {}
		local guis = {}
		for _, child in gate:GetChildren() do
			if child:IsA("BasePart") then
				table.insert(beams, child)
			elseif child:IsA("SurfaceGui") then
				table.insert(guis, child)
				local t = child:FindFirstChild("Time", true)
				if t and t:IsA("TextLabel") then
					table.insert(countdown, t)
				end
			end
		end
		local signGui = (model:FindFirstChild("Sign") :: BasePart):FindFirstChild("SignGui")
		local lockSign = model:FindFirstChild("LockSign")
		local lockStatus = lockSign and lockSign:FindFirstChild("Status", true)
		local st: PlotState = {
			index = index,
			model = model,
			display = model:FindFirstChild("Display") :: Folder,
			origin = MapLayout.plotOrigin(index),
			owner = nil,
			lockedUntil = 0,
			lockReadyAt = 0,
			gate = gate,
			beams = beams,
			countdown = countdown,
			countdownGuis = guis,
			lockStatus = if lockStatus and lockStatus:IsA("TextLabel") then lockStatus else nil,
			statusLight = model:FindFirstChild("StatusLight") :: BasePart?,
			signName = signGui and signGui:FindFirstChild("OwnerName") :: TextLabel?,
			signStats = signGui and signGui:FindFirstChild("Stats") :: TextLabel?,
			zoneCf = zoneCf,
			zoneSize = zoneSize,
			lockedVisual = false,
			lastShown = -1,
			lastLockDuration = 0,
			spawn = nil,
			lootTierModels = PlotService._lootTierModels(model),
			lootSlots = {},
			lootTier = -1,
		}
		-- The owner's RespawnLocation (set in assign). Invisible, flush with the floor at OwnerSpawn; Neutral because
		-- teamless players can only use neutral spawns; disabled while the garage is vacant.
		local spawnPad = Instance.new("SpawnLocation")
		spawnPad.Name = "PlotSpawn"
		spawnPad.Anchored = true
		spawnPad.Size = Vector3.new(4, 0.2, 4)
		spawnPad.CFrame = PlotService.ownerSpawnCFrame(index) * CFrame.new(0, -0.1, 0)
		spawnPad.Transparency = 1
		spawnPad.CanCollide = false
		spawnPad.CanQuery = false
		spawnPad.CanTouch = false
		spawnPad.CastShadow = false
		spawnPad.Neutral = true
		spawnPad.Duration = 0
		spawnPad.AllowTeamChangeOnTouch = false
		spawnPad.Enabled = false
		spawnPad.Parent = model
		st.spawn = spawnPad
		local lootRoot = model:FindFirstChild("Loot")
		if lootRoot then
			for _, d in lootRoot:GetDescendants() do
				if d:IsA("Model") and CollectionService:HasTag(d, PlotService.TAG_LOOT) then
					table.insert(st.lootSlots, d)
				end
			end
		end
		updateLoot(st) -- vacant: just the safe (before the model enters Workspace)
		plots[index] = st
		model.Parent = folder

		local lockButton = model:FindFirstChild("LockButton")
		if lockButton and lockButton:IsA("BasePart") then
			lockButton.Touched:Connect(function(hit: BasePart)
				local p = playerFromHit(hit)
				if p and p == st.owner then
					PlotService.tryLock(p, true)
				end
			end)
		end
	end

	Net.on("GoHome", onGoHome, 1)
	Net.on("LockGarage", function(player: Player)
		PlotService.tryLock(player, false)
	end, 2)
end

function PlotService.start()
	-- Loot meshes: dress what AssetLibrary already holds, then each Props template as it lands (wall-prop slots are
	-- MapDresser's). Idempotent per slot, so a template landing between Connect and the first pass is harmless.
	local AssetLibrary = sys("AssetLibrary")
	local ready = AssetLibrary and AssetLibrary.Ready
	if ready and typeof(ready.Connect) == "function" then
		ready:Connect(function(cat: string, key: string)
			if cat == "Props" then
				dressLoot(key)
				dressWallProps(true)
			end
		end)
	end
	dressLoot(nil)
	-- Wall props: MapDresser's public dressAll on each garage's Dressing folder once the kit has loaded (idempotent:
	-- a dressed slot is replaced by its clone, so a MapDresser pass over all of Workspace finds nothing left here).
	task.spawn(function()
		if AssetLibrary and typeof(AssetLibrary.waitAll) == "function" then
			pcall(AssetLibrary.waitAll, 30)
		end
		dressWallProps(false)
	end)

	local handled: { [Player]: boolean } = {}
	local function onPlayer(player: Player)
		if handled[player] then
			return
		end
		handled[player] = true
		assign(player)
		player.CharacterAdded:Connect(function(char)
			onCharacter(player, char)
		end)
		if player.Character then
			onCharacter(player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	Players.PlayerRemoving:Connect(function(player: Player)
		handled[player] = nil
		release(player)
	end)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayer, p)
	end

	local lastPush = 0
	local lastSign = 0
	while true do
		task.wait(0.25)
		local now = os.clock()
		local doPush = now - lastPush >= PlotService.PUSH_INTERVAL
		if doPush then
			lastPush = now
		end
		local doSign = now - lastSign >= 2
		if doSign then
			lastSign = now
		end
		for _, st in plots do
			if st.lockedUntil > 0 then
				if st.lockedUntil <= now then
					unlock(st, true)
				else
					updateCountdown(st, now)
					if doPush then
						local ok, err = pcall(pushOut, st)
						if not ok then
							warn("[PlotService] pushOut failed: " .. tostring(err))
						end
					end
				end
			end
			if doSign then
				updateLoot(st)
			end
			if doSign and st.owner then
				setSign(st)
			end
		end
	end
end

return PlotService
