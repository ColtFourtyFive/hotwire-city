--!strict
-- AppearanceService (C4a characters): every player spawns as a realistic GTA-style character, not their Roblox avatar.
--
--   * StarterPlayer.LoadCharacterAppearance = false (default.project.json); on CharacterAdded the body is hidden at
--     once (no blocky-avatar flash), the saved look is turned into a HumanoidDescription (Appearance/DescriptionSpec)
--     and applied with Humanoid:ApplyDescriptionAsync, then the body is revealed. A failed apply walks the fallback
--     levels (0 as chosen -> 1 Roblox-made fallbacks -> 2 SAFE), and a level-0 apply that loads fewer accessories
--     than asked is retried at level 1 (an item went off sale / was deleted).
--   * A player with no saved look wears a random realistic look seeded by their userId (the same everywhere) until
--     they save one in the character creator (client CharacterCreator).
--   * "Use my Roblox avatar" (off by default): the player's own HumanoidDescription, still with the realistic walk
--     style, no emotes and scales clamped into a fair range (DescriptionSpec.ownOverrides / clampScale).
--   * Default overhead name / health displays are off (DisplayDistanceType None, HealthDisplayType AlwaysOff); the
--     client's NameTags draws subtle GTA tags instead.
--
-- Persistence: its own DataStore HC_Appearance_v1, key = tostring(userId), value = LookCodec.Record (list KEYS, so
-- reordering PlayerLooks never scrambles a look). Load: GetAsync with retries. Save: UpdateAsync that keeps a stored
-- record changed later than ours (the player saved on another server meanwhile), with retries; debounced
-- (SAVE_DEBOUNCE s per player), flushed on leave and on BindToClose. Studio without API access -> memory, one warning.
-- DataService is NOT touched (the loop v2 data cutover owns its schema).
--
-- Character creator (studio): AppearanceCreator(true) puts the player in a creator slot. The slot is a far-away
-- studio position (HC_Creator player attribute, a Vector3) where the CLIENT builds a local lineup room and moves its
-- own character (client physics owns it, so the local floor holds it); the server records where they stood and puts
-- them back there on AppearanceCreator(false) / AppearanceSave. Only on foot, alive, not wanted, not in combat.
--
-- Replicated player attributes (read by CharacterCreator / NameTags / tests):
--   HC_LookLoaded (bool), HC_LookSaved (bool: a look was saved; false = first join, the creator opens),
--   HC_Look (LookCodec.key string of the look being worn: saved, or the creator preview), HC_LookOwn (bool),
--   HC_LookLevel (number: fallback level of the last apply), HC_Creator (Vector3 while in the creator, else nil).
--
-- Remotes (all validated, rate-limited): AppearanceCreator(open: boolean), AppearancePreview(look),
--   AppearanceSave(look), AppearanceSetOwn(on: boolean). `look` = LookCodec indices only (LookCodec.validate).
-- API: getLook(player): Look, isOwn(player): boolean, inCreator(player): boolean, toDescription(spec),
--   reapply(player), Applied: Signal(player, level).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local LookCodec = require(Shared.Appearance.LookCodec)
local DescriptionSpec = require(Shared.Appearance.DescriptionSpec)

local AppearanceService = {}

AppearanceService.STORE_NAME = "HC_Appearance_v1"
AppearanceService.SAVE_DEBOUNCE = 7 -- seconds between writes of one key (DataStore: 1 write / 6 s / key)
AppearanceService.LOAD_WAIT = 6 -- seconds a spawn waits for the record before wearing the seeded look
AppearanceService.RETRIES = 4
AppearanceService.STUDIO_BASE = Vector3.new(-12000, 2400, -12000) -- far off the island, above everything
AppearanceService.STUDIO_PITCH = 120 -- studs between creator slots (rooms are 40 wide and closed)
AppearanceService.MAX_SLOTS = 64
AppearanceService.MIN_ACCESSORY_SHARE = 0.75 -- a level-0 apply loading fewer than this share of accessories retries
AppearanceService.HIDE_MAX = 8 -- seconds a new body may stay hidden while its look loads (a stalled apply shows it)

AppearanceService.Applied = Signal.new() -- (player, level)

type Look = LookCodec.Look

type Creator = { slot: number, returnCF: CFrame, first: boolean }

type PState = {
	player: Player,
	loaded: boolean,
	loadFailed: boolean,
	hasSaved: boolean,
	look: Look, -- the saved (or seeded) look
	own: boolean,
	changedAt: number,
	dirty: boolean,
	saveScheduled: boolean,
	lastSaveAt: number,
	creator: Creator?,
	worn: Look, -- what the character wears now (the creator preview while in the studio)
	applying: boolean,
	pending: { look: Look, own: boolean }?,
	hidden: { [Model]: { [Instance]: number } }, -- parts / decals hidden until the look is on -> their transparency
	spawned: Model?, -- the character whose spawn apply has been queued
	ownDesc: HumanoidDescription?,
	ownFetched: boolean,
}

local states: { [Player]: PState } = {}
local slots: { [number]: Player } = {}

-- Test seams ------------------------------------------------------------------------------------------------------------

local hooks = {
	clock = os.clock,
	now = function(): number
		return os.time()
	end,
	wait = function(s: number)
		task.wait(s)
	end,
	store = nil :: any, -- injected DataStore-like { GetAsync, UpdateAsync } (tests)
	apply = function(humanoid: Humanoid, desc: HumanoidDescription)
		(humanoid :: any):ApplyDescriptionAsync(desc)
	end,
	userDescription = function(userId: number): HumanoidDescription?
		return (Players :: any):GetHumanoidDescriptionFromUserIdAsync(userId)
	end,
	isStudio = function(): boolean
		return RunService:IsStudio()
	end,
	delay = function(seconds: number, fn: () -> ())
		task.delay(seconds, fn)
	end,
	backoff = 1,
}

function AppearanceService._setHooks(overrides: { [string]: any })
	for k, v in overrides do
		(hooks :: any)[k] = v
	end
end

function AppearanceService._state(player: Player): PState?
	return states[player]
end

function AppearanceService._reset()
	table.clear(states)
	table.clear(slots)
end

-------------------------------------------------------------------------------------------------------------------------
-- HumanoidDescription
-------------------------------------------------------------------------------------------------------------------------

local ANIM_PROPS = {
	idle = "IdleAnimation",
	walk = "WalkAnimation",
	run = "RunAnimation",
	jump = "JumpAnimation",
	fall = "FallAnimation",
	climb = "ClimbAnimation",
	swim = "SwimAnimation",
}

local RIGID_SLOTS = {
	"HatAccessory",
	"HairAccessory",
	"FaceAccessory",
	"NeckAccessory",
	"ShouldersAccessory",
	"FrontAccessory",
	"BackAccessory",
	"WaistAccessory",
}

local function setProp(inst: Instance, prop: string, value: any)
	pcall(function()
		(inst :: any)[prop] = value
	end)
end

-- Accessory entries for HumanoidDescription:SetAccessories (layered clothing, hair, brows, lashes, shoes).
function AppearanceService.accessoryEntries(spec: DescriptionSpec.Spec): { { [string]: any } }
	local out = {}
	for _, a in spec.accessories do
		local okType, accessoryType = pcall(function()
			return (Enum.AccessoryType :: any)[a.kind]
		end)
		if okType and accessoryType then
			table.insert(out, {
				AccessoryType = accessoryType,
				AssetId = a.id,
				IsLayered = a.layered,
				Order = a.order,
			})
		end
	end
	return out
end

-- A Spec -> a HumanoidDescription (realistic body, dynamic head, one skin tone, layered outfit, walk style, no
-- classic face / shirt / pants, no rigid accessories, no emotes).
function AppearanceService.toDescription(spec: DescriptionSpec.Spec): HumanoidDescription
	local d = Instance.new("HumanoidDescription")
	setProp(d, "Head", spec.head)
	setProp(d, "Torso", spec.torso)
	setProp(d, "LeftArm", spec.leftArm)
	setProp(d, "RightArm", spec.rightArm)
	setProp(d, "LeftLeg", spec.leftLeg)
	setProp(d, "RightLeg", spec.rightLeg)
	setProp(d, "MoodAnimation", spec.mood)
	for _, prop in { "HeadColor", "TorsoColor", "LeftArmColor", "RightArmColor", "LeftLegColor", "RightLegColor" } do
		setProp(d, prop, spec.skin)
	end
	setProp(d, "HeightScale", spec.scales.height)
	setProp(d, "WidthScale", spec.scales.width)
	setProp(d, "DepthScale", spec.scales.depth)
	setProp(d, "HeadScale", spec.scales.head)
	setProp(d, "BodyTypeScale", spec.scales.bodyType)
	setProp(d, "ProportionScale", spec.scales.proportion)
	for key, prop in ANIM_PROPS do
		setProp(d, prop, (spec.anims :: any)[key])
	end
	setProp(d, "Face", spec.face)
	setProp(d, "Shirt", spec.shirt)
	setProp(d, "Pants", spec.pants)
	setProp(d, "GraphicTShirt", spec.graphicTShirt)
	for _, slot in RIGID_SLOTS do
		setProp(d, slot, "")
	end
	pcall(function()
		(d :: any):SetAccessories(AppearanceService.accessoryEntries(spec), false)
	end)
	pcall(function()
		(d :: any):SetEmotes({});
		(d :: any):SetEquippedEmotes({})
	end)
	return d
end

-- The player's own avatar with what we still force on it (walk style, fair scales, no emotes).
function AppearanceService.ownDescription(base: HumanoidDescription, look: Look): HumanoidDescription
	local d = base:Clone()
	local o = DescriptionSpec.ownOverrides(look)
	for key, prop in ANIM_PROPS do
		setProp(d, prop, (o.anims :: any)[key])
	end
	for name, prop in
		{
			height = "HeightScale",
			width = "WidthScale",
			depth = "DepthScale",
			head = "HeadScale",
			bodyType = "BodyTypeScale",
			proportion = "ProportionScale",
		} :: { [string]: string }
	do
		local okGet, v = pcall(function()
			return (d :: any)[prop]
		end)
		setProp(d, prop, DescriptionSpec.clampScale(name, if okGet then v else nil))
	end
	pcall(function()
		(d :: any):SetEmotes({});
		(d :: any):SetEquippedEmotes({})
	end)
	return d
end

-------------------------------------------------------------------------------------------------------------------------
-- Attributes
-------------------------------------------------------------------------------------------------------------------------

local function publish(st: PState)
	local p = st.player
	p:SetAttribute("HC_LookLoaded", st.loaded)
	p:SetAttribute("HC_LookSaved", st.hasSaved)
	p:SetAttribute("HC_Look", LookCodec.key(st.worn))
	p:SetAttribute("HC_LookOwn", st.own)
	p:SetAttribute(
		"HC_Creator",
		if st.creator then AppearanceService.studioPosition((st.creator :: Creator).slot) else nil
	)
end

-------------------------------------------------------------------------------------------------------------------------
-- DataStore
-------------------------------------------------------------------------------------------------------------------------

local storeMode: "pending" | "live" | "memory" = "pending"
local liveStore: any = nil
local memory: { [string]: any } = {}
local warnedMemory = false

local function isApiAccessError(err: any): boolean
	local msg = tostring(err)
	return msg:find("403", 1, true) ~= nil
		or msg:find("StudioAccessToApisNotAllowed", 1, true) ~= nil
		or msg:find("API", 1, true) ~= nil
		or msg:find("publish", 1, true) ~= nil
end

local function useMemory(reason: string)
	storeMode = "memory"
	if not warnedMemory then
		warnedMemory = true
		warn("[AppearanceService] DataStores unavailable (" .. reason .. "): looks are kept in memory only.")
	end
end

local function getStore(): any
	if hooks.store then
		return hooks.store
	end
	if storeMode == "memory" then
		return nil
	end
	if liveStore then
		return liveStore
	end
	local ok, res = pcall(function()
		return DataStoreService:GetDataStore(AppearanceService.STORE_NAME)
	end)
	if ok and res then
		liveStore = res
		storeMode = "live"
		return res
	end
	useMemory(tostring(res))
	return nil
end

local function keyOf(player: Player): string
	return tostring(player.UserId)
end

-- (ok, raw value)
function AppearanceService._load(key: string): (boolean, any)
	for attempt = 1, AppearanceService.RETRIES do
		local store = getStore()
		if not store then
			return true, memory[key]
		end
		local ok, res = pcall(function()
			return store:GetAsync(key)
		end)
		if ok then
			return true, res
		end
		if hooks.isStudio() and isApiAccessError(res) then
			useMemory(tostring(res))
			return true, memory[key]
		end
		warn(("[AppearanceService] load %s failed (attempt %d): %s"):format(key, attempt, tostring(res)))
		if attempt < AppearanceService.RETRIES then
			hooks.wait(math.min(2 ^ attempt, 8) * hooks.backoff)
		end
	end
	return false, nil
end

-- Writes `rec` unless the stored record is newer. Returns true when the store holds `rec` or something newer.
function AppearanceService._save(key: string, rec: LookCodec.Record): boolean
	for attempt = 1, AppearanceService.RETRIES do
		local store = getStore()
		if not store then
			if not LookCodec.storedIsNewer(memory[key], rec) then
				memory[key] = rec
			end
			return true
		end
		local ok, err = pcall(function()
			store:UpdateAsync(key, function(old: any): any
				if LookCodec.storedIsNewer(old, rec) then
					return nil -- keep the newer look saved on another server
				end
				return rec
			end)
		end)
		if ok then
			return true
		end
		if hooks.isStudio() and isApiAccessError(err) then
			useMemory(tostring(err))
			memory[key] = rec
			return true
		end
		warn(("[AppearanceService] save %s failed (attempt %d): %s"):format(key, attempt, tostring(err)))
		if attempt < AppearanceService.RETRIES then
			hooks.wait(math.min(2 ^ attempt, 8) * hooks.backoff)
		end
	end
	return false
end

local function flush(st: PState): boolean
	if not st.dirty then
		return true
	end
	st.dirty = false
	st.lastSaveAt = hooks.clock()
	local rec = LookCodec.encodeRecord(st.look, st.own, st.changedAt)
	local ok = AppearanceService._save(keyOf(st.player), rec)
	if not ok then
		st.dirty = true -- retried by the next change, on leave or on shutdown
	end
	return ok
end
AppearanceService._flush = flush

local function queueSave(st: PState)
	st.dirty = true
	if st.saveScheduled then
		return
	end
	st.saveScheduled = true
	local waitFor = math.max(0, st.lastSaveAt + AppearanceService.SAVE_DEBOUNCE - hooks.clock())
	task.spawn(function()
		if waitFor > 0 then
			hooks.wait(waitFor)
		end
		st.saveScheduled = false
		if states[st.player] == st then
			flush(st)
		end
	end)
end

-------------------------------------------------------------------------------------------------------------------------
-- Applying looks
-------------------------------------------------------------------------------------------------------------------------

-- Hides one part / decal (remembering its transparency) while the character's look is not on yet.
local function hideOne(list: { [Instance]: number }, d: Instance)
	if list[d] ~= nil then
		return
	end
	if d:IsA("BasePart") then
		if d.Name ~= "HumanoidRootPart" and d.Transparency < 1 then
			list[d] = d.Transparency
			d.Transparency = 1
		end
	elseif d:IsA("Decal") then
		if d.Transparency < 1 then
			list[d] = d.Transparency
			d.Transparency = 1
		end
	end
end

local function hideCharacter(char: Model): { [Instance]: number }
	local list: { [Instance]: number } = {}
	for _, d in char:GetDescendants() do
		hideOne(list, d)
	end
	return list
end
AppearanceService._hideCharacter = hideCharacter

-- Shows everything hideCharacter hid (and every part the look added meanwhile) at its own transparency.
local function reveal(st: PState, char: Model)
	local list = st.hidden[char]
	if not list then
		return
	end
	st.hidden[char] = nil
	for inst, was in list do
		if inst:IsDescendantOf(char) then
			if inst:IsA("BasePart") then
				inst.Transparency = was
			elseif inst:IsA("Decal") then
				-- a classic face decal never comes back on a realistic (dynamic) head
				local head = inst.Parent
				local dynamic = head ~= nil and head:FindFirstChildOfClass("FaceControls") ~= nil
				if dynamic and inst.Name == "face" then
					inst:Destroy()
				else
					inst.Transparency = was
				end
			end
		end
	end
end
AppearanceService._reveal = reveal

local function countAccessories(char: Model): number
	local n = 0
	for _, c in char:GetChildren() do
		if c:IsA("Accessory") then
			n += 1
		end
	end
	return n
end

-- Removes classic face decals from a dynamic head (realistic looks only).
local function stripFaceDecals(char: Model)
	local head = char:FindFirstChild("Head")
	if head and head:FindFirstChildOfClass("FaceControls") then
		for _, c in head:GetChildren() do
			if c:IsA("Decal") and c.Name == "face" then
				c:Destroy()
			end
		end
	end
end

local function tryApply(hum: Humanoid, desc: HumanoidDescription): (boolean, string?)
	local ok, err = pcall(hooks.apply, hum, desc)
	desc:Destroy()
	return ok, if ok then nil else tostring(err)
end

local function ownBase(st: PState): HumanoidDescription?
	if not st.ownFetched then
		st.ownFetched = true
		local ok, res = pcall(hooks.userDescription, st.player.UserId)
		if ok and typeof(res) == "Instance" and res:IsA("HumanoidDescription") then
			st.ownDesc = res
		else
			warn("[AppearanceService] could not read the Roblox avatar of " .. st.player.Name .. ": " .. tostring(res))
		end
	end
	return st.ownDesc
end

-- Applies a look to the player's current character. Returns the level used (-1 = own avatar, nil = failed).
local function applyOnce(st: PState, look: Look, own: boolean): number?
	local player = st.player
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not char or not hum or hum.Health <= 0 then
		if char then
			reveal(st, char)
		end
		return nil
	end
	local used: number? = nil
	if own then
		local base = ownBase(st)
		if base then
			local ok, err = tryApply(hum, AppearanceService.ownDescription(base, look))
			if ok then
				used = -1
			else
				warn("[AppearanceService] own avatar failed for " .. player.Name .. ": " .. tostring(err))
			end
		end
	end
	if used == nil then
		for level = 0, DescriptionSpec.MAX_LEVEL do
			if player.Character ~= char then
				return nil -- respawned meanwhile: the new character has its own apply queued
			end
			local spec = DescriptionSpec.build(look, level)
			local ok, err = tryApply(hum, AppearanceService.toDescription(spec))
			if ok then
				local want = #spec.accessories
				local got = countAccessories(char)
				if
					level < DescriptionSpec.MAX_LEVEL
					and want > 0
					and got < want * AppearanceService.MIN_ACCESSORY_SHARE
				then
					warn(
						("[AppearanceService] %s: look %s level %d loaded %d of %d accessories; trying level %d"):format(
							player.Name,
							LookCodec.key(look),
							level,
							got,
							want,
							level + 1
						)
					)
				else
					used = level
					break
				end
			else
				warn(
					("[AppearanceService] %s: look %s level %d failed: %s"):format(
						player.Name,
						LookCodec.key(look),
						level,
						tostring(err)
					)
				)
			end
		end
		if used ~= nil and player.Character == char then
			stripFaceDecals(char)
		end
	end
	if player.Character == char then
		reveal(st, char)
	end
	if used ~= nil then
		player:SetAttribute("HC_LookLevel", used)
		AppearanceService.Applied:Fire(player, used)
	end
	return used
end
AppearanceService._applyOnce = applyOnce

-- Queue an apply (latest wins; one apply at a time per player).
local function requestApply(st: PState, look: Look, own: boolean)
	st.pending = { look = look, own = own }
	if st.applying then
		return
	end
	st.applying = true
	task.spawn(function()
		while st.pending and states[st.player] == st do
			local job = st.pending :: { look: Look, own: boolean }
			st.pending = nil
			local ok, err = pcall(applyOnce, st, job.look, job.own)
			if not ok then
				warn("[AppearanceService] apply errored: " .. tostring(err))
			end
		end
		st.applying = false
	end)
end
AppearanceService._requestApply = requestApply

function AppearanceService.reapply(player: Player)
	local st = states[player]
	if st then
		requestApply(st, st.worn, st.own and st.creator == nil)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Creator studio slots
-------------------------------------------------------------------------------------------------------------------------

function AppearanceService.studioPosition(slot: number): Vector3
	return AppearanceService.STUDIO_BASE + Vector3.new((slot - 1) * AppearanceService.STUDIO_PITCH, 0, 0)
end

local function takeSlot(player: Player): number?
	for i = 1, AppearanceService.MAX_SLOTS do
		if slots[i] == nil or slots[i].Parent == nil then
			slots[i] = player
			return i
		end
	end
	return nil
end

local function freeSlot(player: Player)
	for i, p in slots do
		if p == player then
			slots[i] = nil
		end
	end
end

local function attrNumber(player: Player, name: string): number
	local v = player:GetAttribute(name)
	return if typeof(v) == "number" then v else 0
end

-- Why the player cannot open the creator right now (nil = they can).
function AppearanceService.creatorBlocked(player: Player): string?
	local st = states[player]
	if not st then
		return "no state"
	end
	if st.creator then
		return "already open"
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or not root or hum.Health <= 0 then
		return "not alive"
	end
	if hum.SeatPart ~= nil or player:GetAttribute("Driving") == true then
		return "in a vehicle"
	end
	if attrNumber(player, "Wanted") > 0 then
		return "wanted"
	end
	if player:GetAttribute("InCombat") == true or player:GetAttribute("Stunned") == true then
		return "in combat"
	end
	if attrNumber(player, "BustProgress") > 0 then
		return "being arrested"
	end
	return nil
end

local function closeCreator(st: PState, saved: boolean)
	local c = st.creator
	if not c then
		return
	end
	st.creator = nil
	freeSlot(st.player)
	local char = st.player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if char and root and root:IsA("BasePart") then
		pcall(function()
			(st.player :: any):RequestStreamAroundAsync(c.returnCF.Position, 4)
		end)
		root.AssemblyLinearVelocity = Vector3.zero
		pcall(char.PivotTo, char, c.returnCF)
	end
	if not saved and not LookCodec.equal(st.worn, st.look) then
		requestApply(st, st.look, st.own)
	end
	st.worn = LookCodec.copy(st.look)
	publish(st)
end

function AppearanceService.inCreator(player: Player): boolean
	local st = states[player]
	return st ~= nil and st.creator ~= nil
end

-------------------------------------------------------------------------------------------------------------------------
-- Remote handlers (args UNTRUSTED)
-------------------------------------------------------------------------------------------------------------------------

function AppearanceService._onCreator(player: Player, open: any)
	local st = states[player]
	if not st or typeof(open) ~= "boolean" then
		return
	end
	if not open then
		closeCreator(st, false)
		return
	end
	if AppearanceService.creatorBlocked(player) ~= nil then
		publish(st) -- the client resyncs (HC_Creator stays nil)
		return
	end
	local slot = takeSlot(player)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not slot or not root or not root:IsA("BasePart") then
		return
	end
	st.creator = { slot = slot, returnCF = root.CFrame, first = not st.hasSaved }
	st.worn = LookCodec.copy(st.look)
	publish(st)
end

function AppearanceService._onPreview(player: Player, payload: any)
	local st = states[player]
	if not st or not st.creator then
		return
	end
	local look = LookCodec.validate(payload)
	if not look then
		return
	end
	if LookCodec.equal(look, st.worn) and st.pending == nil then
		return
	end
	st.worn = look
	player:SetAttribute("HC_Look", LookCodec.key(look))
	requestApply(st, look, false)
end

function AppearanceService._onSave(player: Player, payload: any)
	local st = states[player]
	if not st or not st.creator then
		return
	end
	local look = LookCodec.validate(payload)
	if not look then
		return
	end
	local changed = not st.hasSaved or st.own or not LookCodec.equal(look, st.look)
	st.look = look
	st.hasSaved = true
	st.own = false -- the creator edits the realistic look: saving one wears it
	st.changedAt = hooks.now()
	if not LookCodec.equal(look, st.worn) then
		requestApply(st, look, false)
	end
	st.worn = LookCodec.copy(look)
	if changed then
		queueSave(st)
	end
	closeCreator(st, true)
end

function AppearanceService._onSetOwn(player: Player, on: any)
	local st = states[player]
	if not st or typeof(on) ~= "boolean" or st.creator then
		return
	end
	if on == st.own then
		publish(st)
		return
	end
	if player:GetAttribute("InCombat") == true then
		publish(st)
		return
	end
	st.own = on
	st.hasSaved = true -- an explicit choice: the first-join creator does not open any more
	st.changedAt = hooks.now()
	queueSave(st)
	publish(st)
	requestApply(st, st.look, on)
end

-------------------------------------------------------------------------------------------------------------------------
-- Players / characters
-------------------------------------------------------------------------------------------------------------------------

local function waitLoaded(st: PState, timeout: number)
	local deadline = hooks.clock() + timeout
	while not st.loaded and hooks.clock() < deadline and states[st.player] == st do
		hooks.wait(0.1)
	end
end

local function onCharacter(player: Player, char: Model)
	local st = states[player]
	if not st then
		return
	end
	if st.creator then
		-- respawned while in the studio: the new body spawns at a normal spawn
		st.creator = nil
		freeSlot(player)
		st.worn = LookCodec.copy(st.look)
		publish(st)
	end
	st.hidden[char] = hideCharacter(char)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	end
	char.DescendantAdded:Connect(function(d: Instance)
		-- late default parts AND the look's own parts stay hidden until the whole look is on (no half-dressed frame)
		local list = st.hidden[char]
		if list then
			hideOne(list, d)
		end
	end)
	hooks.delay(AppearanceService.HIDE_MAX, function()
		if states[player] == st and st.hidden[char] then
			warn("[AppearanceService] " .. player.Name .. "'s look is still loading: showing the body")
			reveal(st, char)
		end
	end)
	task.spawn(function()
		if not char:IsDescendantOf(game) then
			local deadline = hooks.clock() + 5
			while not char:IsDescendantOf(game) and hooks.clock() < deadline do
				hooks.wait(0.05)
			end
		end
		waitLoaded(st, AppearanceService.LOAD_WAIT)
		if player.Character == char and states[player] == st then
			st.spawned = char
			requestApply(st, st.worn, st.own)
		end
	end)
end
AppearanceService._onCharacter = onCharacter

local function onPlayerAdded(player: Player)
	if states[player] then
		return
	end
	local seeded = LookCodec.seeded(player.UserId)
	local st: PState = {
		player = player,
		loaded = false,
		loadFailed = false,
		hasSaved = false,
		look = seeded,
		own = false,
		changedAt = 0,
		dirty = false,
		saveScheduled = false,
		lastSaveAt = -math.huge,
		creator = nil,
		worn = LookCodec.copy(seeded),
		applying = false,
		pending = nil,
		hidden = {},
		spawned = nil,
		ownDesc = nil,
		ownFetched = false,
	}
	states[player] = st
	publish(st)
	player.CharacterAdded:Connect(function(char: Model)
		onCharacter(player, char)
	end)
	task.spawn(function()
		local ok, raw = AppearanceService._load(keyOf(player))
		if states[player] ~= st then
			return
		end
		if ok then
			local rec, look = LookCodec.decodeRecord(raw)
			if rec and look then
				st.look = look
				st.own = rec.own
				st.changedAt = rec.changedAt
				st.hasSaved = true
			end
		else
			-- never prompt (or overwrite) a returning player because the store was down: wear the seeded look
			st.loadFailed = true
			st.hasSaved = true
		end
		local changed = not LookCodec.equal(st.worn, st.look)
		if not st.creator then
			st.worn = LookCodec.copy(st.look)
		end
		st.loaded = true
		publish(st)
		local char = player.Character
		-- a body whose spawn stopped waiting (slow store) already wears the seeded look: switch it to the saved one
		if char and st.spawned == char and (changed or st.own) and not st.creator then
			requestApply(st, st.worn, st.own)
		end
	end)
	if player.Character then
		onCharacter(player, player.Character)
	end
end
AppearanceService._onPlayerAdded = onPlayerAdded

local function onPlayerRemoving(player: Player)
	local st = states[player]
	if not st then
		return
	end
	freeSlot(player)
	states[player] = nil
	-- (after a failed load only explicit changes are dirty; UpdateAsync still keeps a newer stored look)
	if st.dirty then
		flush(st)
	end
end
AppearanceService._onPlayerRemoving = onPlayerRemoving

function AppearanceService.getLook(player: Player): Look
	local st = states[player]
	return if st then LookCodec.copy(st.look) else LookCodec.seeded(player.UserId)
end

function AppearanceService.isOwn(player: Player): boolean
	local st = states[player]
	return st ~= nil and st.own
end

-------------------------------------------------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------------------------------------------------

function AppearanceService.init()
	Net.on("AppearanceCreator", AppearanceService._onCreator, 1)
	Net.on("AppearancePreview", AppearanceService._onPreview, 8)
	Net.on("AppearanceSave", AppearanceService._onSave, 1)
	Net.on("AppearanceSetOwn", AppearanceService._onSetOwn, 0.5)
end

function AppearanceService.start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayerAdded, p)
	end
	game:BindToClose(function()
		local pending = 0
		for _, st in states do
			if st.dirty then
				pending += 1
				task.spawn(function()
					pcall(flush, st)
					pending -= 1
				end)
			end
		end
		local deadline = os.clock() + 20
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return AppearanceService
