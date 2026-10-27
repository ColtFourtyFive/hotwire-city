--!strict
-- DataService: session-locked, hand-rolled player profiles (no external libraries).
--
-- Persistence model
--   DataStore "HotwireCity_v1", one key per player ("p_<userId>"), value = Record:
--     { data = PlayerData, lock = { jobId, session, time }?, savedAt = unixSeconds }
--   * Load = ONE UpdateAsync that claims the lock and returns the migrated/reconciled/sanitized profile.
--     If another live session holds the lock (fresh < LOCK_STALE_SECONDS, different session) we back off and
--     retry LOCK_RETRIES times (the other server is usually mid-release), then steal it (servers can die).
--   * Every save is an UpdateAsync that verifies we still own the lock. If someone stole it, our session is
--     "lost": we never overwrite their data and we kick the player (they are already playing elsewhere).
--   * Autosave every AUTOSAVE_INTERVAL (staggered per player, also refreshes the lock), save + release on
--     leave, BindToClose flushes every profile in parallel and waits (bounded).
--   * If the load truly fails after retries the player is KICKED with a friendly message. We never let a
--     player play on default data, because saving it would overwrite their real progress.
--   * Studio without API access -> in-memory profiles + one warning (nothing is written).
--
-- Gameplay code never touches DataStores: it mutates the live table from DataService.get(player) and calls
-- DataService.markDirty(player) (debounced snapshot push + save flag).

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Cars = require(Shared.Config.Cars)
local Economy = require(Shared.Config.Economy)
local Monetization = require(Shared.Config.Monetization)
local Rarity = require(Shared.Config.Rarity)
local EconomyMath = require(Shared.Util.EconomyMath)
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local Types = require(Shared.Types)

type PlayerData = Types.PlayerData
type Snapshot = Types.Snapshot
type SlotSnapshot = Types.SlotSnapshot

-- Tunables -------------------------------------------------------------------------------------------------
local STORE_NAME = "HotwireCity_v1"
local KEY_PREFIX = "p_"
local SCHEMA_VERSION = 1
local AUTOSAVE_INTERVAL = 120
local LOCK_STALE_SECONDS = 300 -- a lock older than this belongs to a dead server
local LOCK_RETRY_DELAYS = { 2, 3, 4, 5, 6, 8 } -- waits between attempts while another session holds the lock
local LOAD_ERROR_RETRIES = 5 -- DataStore errors (not locks) before giving up and kicking
local SAVE_ERROR_RETRIES = 3
local RELEASE_ERROR_RETRIES = 4
-- time scales (tests shrink these; never change at runtime in a live game)
local TUNING = {
	keyWriteCooldown = 6.2, -- seconds between writes to the same key (engine limit ~6s)
	backoffScale = 1, -- multiplies every retry/backoff wait
}
local SNAPSHOT_DEBOUNCE = 0.1
local RECEIPT_CAP = 50
local RETIRED_CAP = 20
local SHUTDOWN_TIMEOUT = 26
local MAX_GARAGE_SLOT = Economy.MAX_SLOTS + Economy.PASS_EXTRA_SLOTS

local KICK_LOAD_FAILED = "Hotwire City couldn't load your garage (Roblox data servers are busy right now). "
	.. "Your progress is safe - please rejoin in a minute!"
local KICK_SESSION_LOST = "Your Hotwire City save was opened on another server. Please rejoin!"

-- reasons passed to addCash that must NOT count toward totalEarned (leaderboard): bought / refunded / dev cash
local NON_EARNING_REASONS: { [string]: boolean } = {
	purchase = true,
	refund = true,
	admin = true,
}

local SETTING_KEYS: { [string]: boolean } = {
	music = true,
	sfx = true,
	hideHud = true,
	autoAccelerate = true,
}

-- Module -----------------------------------------------------------------------------------------------------
local DataService = {}

DataService.SCHEMA_VERSION = SCHEMA_VERSION
DataService.RECEIPT_CAP = RECEIPT_CAP
DataService.Loaded = Signal.new() -- (player, data)
DataService.Releasing = Signal.new() -- (player, data) fired right before the final save on leave/shutdown

type Profile = {
	player: Player,
	userId: number,
	key: string,
	session: string,
	data: PlayerData,
	loaded: boolean,
	releasing: boolean,
	lost: boolean,
	saving: boolean,
	dirty: boolean,
	changeGen: number,
	nextAutosave: number,
	pushQueued: boolean,
	isNew: boolean,
	previousLastOnline: number,
	joinedAt: number,
}

type Mode = "pending" | "live" | "memory"

local profiles: { [Player]: Profile } = {}
local loadingPlayers: { [Player]: boolean } = {}
local loadingCount = 0
local pendingReleases = 0
local releasingUsers: { [number]: number } = {} -- userId -> in-flight releases (fast rejoin to same server)
local lastWriteByUser: { [number]: number } = {} -- userId -> os.clock() of the last write to that key
local activeSessions: { [string]: boolean } = {} -- sessions owned by THIS server (claiming or loaded)
local mode: Mode = "pending"
local store: any = nil
local shuttingDown = false
local warnedMemory = false

---------------------------------------------------------------------------------------------------------------
-- Pure helpers (exposed with a leading underscore for tests)
---------------------------------------------------------------------------------------------------------------

local function deepCopy<T>(value: T): T
	if typeof(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value :: any do
		out[k] = deepCopy(v)
	end
	return (out :: any) :: T
end

local function isFinite(v: any): boolean
	return typeof(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function finite(v: any, default: number): number
	if isFinite(v) then
		return v
	end
	return default
end

local function nonNegInt(v: any, default: number): number
	return math.max(0, math.floor(finite(v, default)))
end

local function boolMap(v: any): { [string]: boolean }
	local out = {}
	if typeof(v) == "table" then
		for k, flag in v do
			if typeof(k) == "string" and flag == true then
				out[k] = true
			end
		end
	end
	return out
end

local function validMutation(m: any): Rarity.MutationId
	if typeof(m) == "string" and Rarity.Mutations[m :: Rarity.MutationId] then
		return m :: Rarity.MutationId
	end
	return "None"
end

-- Fresh default profile for a new player (SPEC §5). Always a new table.
local function makeTemplate(): PlayerData
	return {
		version = SCHEMA_VERSION,
		cash = Economy.STARTING_CASH,
		totalEarned = 0,
		rebirths = 0,
		slotsUnlocked = Economy.START_SLOTS,
		garage = {
			["1"] = { carId = Economy.STARTER_CAR, mutation = "None", uncollected = 0 },
		},
		discovered = { [Economy.STARTER_CAR] = true },
		upgrades = { lock = 0, hotwire = 0, nitro = 0, armor = 0 },
		tools = { bat = true },
		stats = { steals = 0, playerSteals = 0, busted = 0, hotDrops = 0, timesRobbed = 0 },
		daily = { streak = 0, lastClaimDay = 0 },
		codes = {},
		receipts = {},
		lastOnline = 0,
		tutorialDone = false,
		settings = { music = true, sfx = true, hideHud = false, autoAccelerate = false },
		exclusives = {},
		contracts = { day = 0, list = {} },
		referralRewarded = false,
		playtime = { day = 0, seconds = 0, claimed = {} },
	}
end

-- Template sub-tables that are *content* for new players, not *shape*: never merged into existing data
-- (merging garage would hand every returning player a free Rustbucket in slot 1).
local NO_MERGE: { [string]: boolean } = { garage = true }

-- Fill missing keys (and keys of the wrong type) from the template, recursively. Never removes keys.
local function reconcile(target: { [any]: any }, template: { [any]: any }, depth: number): { [any]: any }
	for k, tv in template do
		local cur = target[k]
		if cur == nil or typeof(cur) ~= typeof(tv) then
			target[k] = deepCopy(tv)
		elseif typeof(tv) == "table" and not (depth == 0 and NO_MERGE[k]) then
			reconcile(cur, tv, depth + 1)
		end
	end
	return target
end

-- Schema migrations: MIGRATIONS[v] upgrades a profile from version v to v + 1.
-- When you change Types.PlayerData: bump SCHEMA_VERSION and add a step here. Never delete fields without one.
local MIGRATIONS: { [number]: (any) -> any } = {
	-- [1] = function(data) data.newField = data.oldField; data.oldField = nil; return data end,
}

local function migrate(data: { [string]: any }): { [string]: any }
	local v = data.version
	if not isFinite(v) or v < 1 then
		v = 1 -- profiles written before versioning (or corrupted) are treated as v1
	end
	v = math.floor(v)
	while v < SCHEMA_VERSION do
		local step = MIGRATIONS[v]
		if step then
			data = step(data) or data
		end
		v += 1
	end
	-- a profile written by a NEWER server (rolling update) keeps its version; reconcile never drops its fields
	data.version = v
	return data
end

-- Replace NaN/inf anywhere in the tree with 0 (unknown fields included). Depth-limited.
local function scrubNumbers(t: { [any]: any }, depth: number)
	if depth > 8 then
		return
	end
	for k, v in t do
		if typeof(v) == "number" then
			if not isFinite(v) then
				t[k] = 0
			end
		elseif typeof(v) == "table" then
			scrubNumbers(v, depth + 1)
		end
	end
end

-- Coerce every known field into a valid shape/range. Assumes reconcile() already ran (all keys present).
local function sanitize(data: { [string]: any }, now: number): { [string]: any }
	scrubNumbers(data, 0)

	data.cash = math.max(0, finite(data.cash, 0))
	data.totalEarned = math.max(0, finite(data.totalEarned, 0))
	data.rebirths = nonNegInt(data.rebirths, 0)
	data.slotsUnlocked =
		math.clamp(math.floor(finite(data.slotsUnlocked, Economy.START_SLOTS)), Economy.START_SLOTS, MAX_GARAGE_SLOT)

	-- garage: string keys "1".."12", known cars only (unknown ids are parked in retiredCars, never lost)
	local garage = {}
	local retired: { any } = if typeof(data.retiredCars) == "table" then data.retiredCars else {}
	for key, rec in data.garage do
		local slot = if typeof(key) == "number" then key elseif typeof(key) == "string" then tonumber(key) else nil
		if
			slot
			and slot % 1 == 0
			and slot >= 1
			and slot <= MAX_GARAGE_SLOT
			and typeof(rec) == "table"
			and typeof(rec.carId) == "string"
		then
			local skey = tostring(slot)
			if Cars.get(rec.carId) then
				if garage[skey] == nil then
					garage[skey] = {
						carId = rec.carId,
						mutation = validMutation(rec.mutation),
						uncollected = math.max(0, finite(rec.uncollected, 0)),
					}
				end
			elseif #retired < RETIRED_CAP then
				table.insert(retired, { carId = rec.carId, mutation = tostring(rec.mutation) })
			end
		end
	end
	data.garage = garage
	if #retired > 0 then
		data.retiredCars = retired
	end

	data.discovered = boolMap(data.discovered)
	data.discovered[Economy.STARTER_CAR] = true

	local upgrades = {}
	for id, def in Economy.Upgrades do
		upgrades[id] = math.clamp(nonNegInt(data.upgrades[id], 0), 0, def.maxLevel)
	end
	data.upgrades = upgrades

	local tools = {}
	for id, owned in boolMap(data.tools) do
		if Economy.Tools[id] and owned then
			tools[id] = true
		end
	end
	tools.bat = true -- the Bonk Bat is free and always owned
	data.tools = tools

	for k, v in data.stats do
		if typeof(k) ~= "string" or typeof(v) ~= "number" then
			data.stats[k] = nil
		else
			data.stats[k] = nonNegInt(v, 0)
		end
	end
	for _, k in { "steals", "playerSteals", "busted", "hotDrops", "timesRobbed" } do
		data.stats[k] = nonNegInt(data.stats[k], 0)
	end

	data.daily = {
		streak = nonNegInt(data.daily.streak, 0),
		lastClaimDay = nonNegInt(data.daily.lastClaimDay, 0),
	}

	data.codes = boolMap(data.codes)
	data.exclusives = boolMap(data.exclusives)

	-- receipts: dense array of strings, newest last, capped
	local receipts = {}
	if typeof(data.receipts) == "table" then
		for _, r in ipairs(data.receipts) do
			if typeof(r) == "string" or typeof(r) == "number" then
				table.insert(receipts, tostring(r))
			end
		end
	end
	while #receipts > RECEIPT_CAP do
		table.remove(receipts, 1)
	end
	data.receipts = receipts

	local lastOnline = nonNegInt(data.lastOnline, 0)
	if lastOnline > now + 60 then
		lastOnline = now -- clock skew / corruption: never grant "negative" offline time
	end
	data.lastOnline = lastOnline

	data.tutorialDone = data.tutorialDone == true
	data.referralRewarded = data.referralRewarded == true

	local defaults = makeTemplate().settings :: any
	local settings = {}
	for k in SETTING_KEYS do
		local v = data.settings[k]
		settings[k] = if typeof(v) == "boolean" then v else defaults[k]
	end
	data.settings = settings

	local list = {}
	if typeof(data.contracts.list) == "table" then
		for _, c in ipairs(data.contracts.list) do
			if typeof(c) == "table" and typeof(c.id) == "string" and #list < 10 then
				table.insert(list, {
					id = c.id,
					progress = math.max(0, finite(c.progress, 0)),
					claimed = c.claimed == true,
				})
			end
		end
	end
	data.contracts = { day = nonNegInt(data.contracts.day, 0), list = list }

	-- playtime gifts (per UTC day): claimed keys are reward indexes as strings ("1".."N")
	local claimed = {}
	for k in boolMap(data.playtime.claimed) do
		local i = tonumber(k)
		if i and i % 1 == 0 and i >= 1 and i <= #Economy.PLAYTIME_REWARDS then
			claimed[tostring(i)] = true
		end
	end
	data.playtime = {
		day = nonNegInt(data.playtime.day, 0),
		seconds = math.clamp(finite(data.playtime.seconds, 0), 0, 86400),
		claimed = claimed,
	}

	return data
end

-- Full load pipeline for a raw stored profile (nil = brand-new player). Returns (data, isNew).
local function prepare(raw: any, now: number): (PlayerData, boolean)
	local isNew = typeof(raw) ~= "table"
	local data: any = if isNew then makeTemplate() else raw
	if isNew then
		data.lastOnline = now -- new players have no offline earnings
	end
	data = migrate(data)
	reconcile(data, makeTemplate() :: any, 0)
	sanitize(data, now)
	return data :: PlayerData, isNew
end

-- Deep copy that keeps only JSON-safe values (string-keyed or array tables, finite numbers, strings, booleans).
local function jsonSafeCopy(value: any, depth: number): any
	local t = typeof(value)
	if t == "number" then
		return if isFinite(value) then value else 0
	elseif t == "string" or t == "boolean" then
		return value
	elseif t == "table" then
		if depth > 10 then
			return nil
		end
		local out = {}
		for k, v in value do
			local kt = typeof(k)
			if kt == "string" or kt == "number" then
				local c = jsonSafeCopy(v, depth + 1)
				if c ~= nil then
					out[k] = c
				end
			end
		end
		return out
	end
	return nil
end

-- Snapshot of the live profile that is written to the DataStore.
local function serialize(data: PlayerData, now: number): any
	local copy = jsonSafeCopy(data, 0)
	copy.lastOnline = now
	return copy
end

-- Split a stored value into (profileData, lock). Accepts legacy bare profiles.
local function unpackRecord(stored: any): (any, any)
	if typeof(stored) ~= "table" then
		return nil, nil
	end
	if typeof(stored.data) == "table" then
		return stored.data, stored.lock
	end
	if stored.cash ~= nil or stored.garage ~= nil then
		return stored, nil
	end
	return nil, stored.lock
end

export type LockState = "free" | "ours" | "held" | "stale"

-- Decide what a stored lock means for a session trying to claim the key.
local function lockState(
	lock: any,
	now: number,
	jobId: string,
	mySession: string,
	isLocalSessionActive: (string) -> boolean
): LockState
	if typeof(lock) ~= "table" then
		return "free"
	end
	if lock.session == mySession then
		return "ours"
	end
	local t = if isFinite(lock.time) then lock.time else 0
	if now - t >= LOCK_STALE_SECONDS then
		return "stale"
	end
	-- held by an earlier session on THIS server that is no longer alive (e.g. a release write that failed)
	if
		jobId ~= ""
		and lock.jobId == jobId
		and typeof(lock.session) == "string"
		and not isLocalSessionActive(lock.session)
	then
		return "stale"
	end
	return "held"
end

DataService._template = makeTemplate
DataService._deepCopy = deepCopy
DataService._reconcile = function(data: any): any
	return reconcile(data, makeTemplate() :: any, 0)
end
DataService._migrate = migrate
DataService._sanitize = sanitize
DataService._prepare = prepare
DataService._serialize = serialize
DataService._unpackRecord = unpackRecord
DataService._lockState = lockState
DataService._MIGRATIONS = MIGRATIONS

---------------------------------------------------------------------------------------------------------------
-- Lazy access to systems later in the boot order (never at module top: avoids require cycles)
---------------------------------------------------------------------------------------------------------------

local function trySystem(name: string): any
	local parent = script.Parent
	local mod = parent and parent:FindFirstChild(name)
	if not mod or not mod:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, mod)
	if ok and typeof(result) == "table" then
		return result
	end
	return nil
end

-- pcall a public function of another system. Returns (ok, ...results). ok=false if missing or errored.
local function callSystem(name: string, fnName: string, ...: any): (boolean, ...any)
	local mod = trySystem(name)
	if not mod then
		return false
	end
	local fn = mod[fnName]
	if typeof(fn) ~= "function" then
		return false
	end
	return pcall(fn, ...)
end

---------------------------------------------------------------------------------------------------------------
-- DataStore plumbing
---------------------------------------------------------------------------------------------------------------

local function jobId(): string
	local ok, id = pcall(function()
		return game.JobId
	end)
	return if ok and typeof(id) == "string" then id else ""
end

local function isApiAccessError(err: any): boolean
	local msg = tostring(err)
	return msg:find("403", 1, true) ~= nil
		or msg:find("StudioAccessToApisNotAllowed", 1, true) ~= nil
		or msg:find("API", 1, true) ~= nil
		or msg:find("publish", 1, true) ~= nil
end

local function useMemoryMode(reason: string)
	mode = "memory"
	if not warnedMemory then
		warnedMemory = true
		warn(
			"[DataService] DataStores unavailable in Studio ("
				.. reason
				.. "). Using in-memory profiles: nothing will be saved. Enable 'Studio Access to API Services' to test saving."
		)
	end
end

local function resolveMode()
	local isStudio = RunService:IsStudio()
	local attempt = 0
	while true do
		attempt += 1
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(STORE_NAME)
		end)
		if ok and result then
			store = result
			break
		end
		if isStudio then
			useMemoryMode(tostring(result))
			return
		end
		warn("[DataService] GetDataStore failed (attempt " .. attempt .. "): " .. tostring(result))
		task.wait(math.min(2 ^ attempt, 15))
	end
	if isStudio then
		local ok, err = pcall(function()
			return store:GetAsync("__studio_probe")
		end)
		if not ok and isApiAccessError(err) then
			useMemoryMode(tostring(err))
			return
		end
	end
	mode = "live"
end

local function waitForMode()
	while mode == "pending" do
		task.wait(0.05)
	end
end

-- Wait (bounded) until the per-server request budget allows one more request of this type.
local function waitForBudget(requestType: Enum.DataStoreRequestType, maxWait: number): boolean
	local deadline = os.clock() + maxWait
	while true do
		local ok, budget = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(requestType)
		end)
		if not ok or typeof(budget) ~= "number" or budget >= 1 then
			return true
		end
		if os.clock() >= deadline then
			return false
		end
		task.wait(0.5)
	end
end

-- Respect the per-key write rate (bounded wait).
local function waitForKeyCooldown(userId: number, maxWait: number)
	local last = lastWriteByUser[userId]
	if last then
		local remaining = math.min(TUNING.keyWriteCooldown - (os.clock() - last), maxWait)
		if remaining > 0 then
			task.wait(remaining)
		end
	end
end

local function newSessionId(): string
	local ok, guid = pcall(function()
		return HttpService:GenerateGUID(false)
	end)
	if ok and typeof(guid) == "string" and guid ~= "" then
		return guid
	end
	return ("%x-%x-%x"):format(math.random(0, 0x7fffffff), math.floor(os.clock() * 1e6), math.random(0, 0x7fffffff))
end

local function isLocalSessionActive(session: string): boolean
	return activeSessions[session] == true
end

-- Claims the player's key and loads their profile. Returns ("ok", data, isNew) | ("failed") | ("left").
local function claimAsync(player: Player, userId: number, key: string, session: string): (string, PlayerData?, boolean)
	local lockedAttempts = 0
	local errorAttempts = 0
	local myJob = jobId()
	while true do
		if player.Parent ~= Players then
			return "left", nil, false
		end
		local force = lockedAttempts >= #LOCK_RETRY_DELAYS
		local outcome = "error"
		local loadedData: PlayerData? = nil
		local loadedIsNew = false

		waitForBudget(Enum.DataStoreRequestType.UpdateAsync, 10)
		waitForKeyCooldown(userId, TUNING.keyWriteCooldown)
		local ok, err = pcall(function()
			store:UpdateAsync(key, function(stored: any)
				local now = os.time()
				local raw, lock = unpackRecord(stored)
				local state = lockState(lock, now, myJob, session, isLocalSessionActive)
				if state == "held" and not force then
					outcome = "locked"
					loadedData = nil
					return nil -- abort the write, someone else owns this profile right now
				end
				outcome = if state == "held" then "stolen" else "claimed"
				local data, fresh = prepare(raw, now)
				loadedData = data
				loadedIsNew = fresh
				local record = {
					data = jsonSafeCopy(data, 0),
					lock = { jobId = myJob, session = session, time = now },
					savedAt = now,
				}
				return record, { userId }
			end)
		end)
		lastWriteByUser[userId] = os.clock()

		if ok and outcome == "locked" then
			lockedAttempts += 1
			warn(
				("[DataService] %s's profile is locked by another server (attempt %d/%d)"):format(
					player.Name,
					lockedAttempts,
					#LOCK_RETRY_DELAYS
				)
			)
			task.wait((LOCK_RETRY_DELAYS[lockedAttempts] or 8) * TUNING.backoffScale)
		elseif ok and loadedData then
			if outcome == "stolen" then
				warn(("[DataService] stole a live-looking lock for %s after retries"):format(player.Name))
			end
			return "ok", loadedData, loadedIsNew
		else
			errorAttempts += 1
			warn(
				("[DataService] load failed for %s (attempt %d/%d): %s"):format(
					player.Name,
					errorAttempts,
					LOAD_ERROR_RETRIES,
					tostring(err)
				)
			)
			if errorAttempts >= LOAD_ERROR_RETRIES then
				return "failed", nil, false
			end
			task.wait(math.min(2 ^ errorAttempts, 16) * TUNING.backoffScale)
		end
	end
end

local function onSessionLost(profile: Profile)
	if profile.lost then
		return
	end
	profile.lost = true
	profile.loaded = false
	warn(("[DataService] session lost for %d (profile opened elsewhere); not overwriting"):format(profile.userId))
	local player = profile.player
	if player.Parent == Players and not profile.releasing then
		player:Kick(KICK_SESSION_LOST)
	end
end

-- Writes the profile (and keeps or releases the lock). Serialized per profile. Returns success.
local function writeAsync(profile: Profile, release: boolean): boolean
	if mode == "memory" then
		profile.dirty = false
		return true
	end
	if profile.lost or not store then
		return false
	end
	local waited = 0
	while profile.saving do
		task.wait(0.1)
		waited += 0.1
		if waited > 60 then
			return false
		end
	end
	if profile.lost then
		return false
	end
	profile.saving = true
	local gen = profile.changeGen
	local myJob = jobId()
	local attempts = if release then RELEASE_ERROR_RETRIES else SAVE_ERROR_RETRIES
	local success = false
	for attempt = 1, attempts do
		waitForBudget(Enum.DataStoreRequestType.UpdateAsync, if release or shuttingDown then 3 else 15)
		waitForKeyCooldown(profile.userId, TUNING.keyWriteCooldown)
		local payload = serialize(profile.data, os.time())
		local outcome = "error"
		local ok, err = pcall(function()
			store:UpdateAsync(profile.key, function(stored: any)
				local _, lock = unpackRecord(stored)
				if stored ~= nil and (typeof(lock) ~= "table" or lock.session ~= profile.session) then
					outcome = "lost"
					return nil
				end
				outcome = "saved"
				local now = os.time()
				local record = {
					data = payload,
					lock = if release then nil else { jobId = myJob, session = profile.session, time = now },
					savedAt = now,
				}
				return record, { profile.userId }
			end)
		end)
		lastWriteByUser[profile.userId] = os.clock()
		if ok and outcome == "saved" then
			success = true
			break
		elseif ok and outcome == "lost" then
			profile.saving = false
			onSessionLost(profile)
			return false
		end
		warn(
			("[DataService] save failed for %d (attempt %d/%d): %s"):format(
				profile.userId,
				attempt,
				attempts,
				tostring(err)
			)
		)
		if attempt < attempts then
			task.wait(2 ^ (attempt - 1) * TUNING.backoffScale)
		end
	end
	profile.saving = false
	if success and profile.changeGen == gen then
		profile.dirty = false
	end
	return success
end

---------------------------------------------------------------------------------------------------------------
-- Attributes / snapshots
---------------------------------------------------------------------------------------------------------------

local function syncAttributes(player: Player, data: PlayerData)
	if player:GetAttribute("Cash") ~= data.cash then
		player:SetAttribute("Cash", data.cash)
	end
	if player:GetAttribute("Rebirths") ~= data.rebirths then
		player:SetAttribute("Rebirths", data.rebirths)
	end
end

local function queuePush(profile: Profile)
	if profile.pushQueued then
		return
	end
	profile.pushQueued = true
	task.delay(SNAPSHOT_DEBOUNCE, function()
		profile.pushQueued = false
		local player = profile.player
		if profiles[player] ~= profile or not profile.loaded or player.Parent ~= Players then
			return
		end
		local ok, snapshot = pcall(DataService.buildSnapshot, player)
		if ok and snapshot then
			Net.fireClient("DataSnapshot", player, snapshot)
		elseif not ok then
			warn("[DataService] buildSnapshot failed: " .. tostring(snapshot))
		end
	end)
end

-- Test hooks (Lune harness): drive the claim/save paths against a fake DataStore. Not used by the game.
DataService._internals = {
	TUNING = TUNING,
	LOCK_RETRY_DELAYS = LOCK_RETRY_DELAYS,
	Players = Players,
	claimAsync = claimAsync,
	writeAsync = writeAsync,
	activeSessions = activeSessions,
	profiles = profiles,
	setStore = function(fakeStore: any, newMode: Mode)
		store = fakeStore
		mode = newMode
	end,
}

---------------------------------------------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------------------------------------------

-- Live profile table (mutate only on the server, then markDirty). Nil until loaded / after release.
function DataService.get(player: Player): PlayerData?
	local profile = profiles[player]
	if profile and not profile.lost then
		return profile.data
	end
	return nil
end

function DataService.isLoaded(player: Player): boolean
	local profile = profiles[player]
	return profile ~= nil and profile.loaded
end

-- Yields until the player's data is loaded (or they leave / timeout). Default timeout 30s.
function DataService.waitFor(player: Player, timeout: number?): PlayerData?
	local deadline = os.clock() + (timeout or 30)
	while true do
		local profile = profiles[player]
		if profile and profile.loaded then
			return profile.data
		end
		if (profile and (profile.releasing or profile.lost)) or player.Parent ~= Players then
			return nil
		end
		if os.clock() >= deadline then
			return nil
		end
		task.wait(0.1)
	end
end

-- Extra: info about this session's load (RewardsService offline earnings, tutorial, analytics).
function DataService.getSessionInfo(player: Player): { isNew: boolean, previousLastOnline: number, joinedAt: number }?
	local profile = profiles[player]
	if not profile then
		return nil
	end
	return {
		isNew = profile.isNew,
		previousLastOnline = profile.previousLastOnline,
		joinedAt = profile.joinedAt,
	}
end

-- Extra: true when running on in-memory profiles (Studio without API access).
function DataService.isMemoryMode(): boolean
	return mode == "memory"
end

-- Extra: "pending" until start() has probed DataStore access, then "live" or "memory".
function DataService.getMode(): string
	return mode
end

-- Debounced snapshot push to the owning client + marks the profile dirty.
function DataService.markDirty(player: Player)
	local profile = profiles[player]
	if not profile or not profile.loaded then
		return
	end
	profile.dirty = true
	profile.changeGen += 1
	syncAttributes(player, profile.data)
	queuePush(profile)
end

-- Adds (or with a negative amount removes) cash. Positive amounts also add to totalEarned unless the reason
-- is "purchase", "refund" or "admin". Returns the new balance, or nil if not loaded / invalid amount.
function DataService.addCash(player: Player, amount: number, reason: string?): number?
	if not isFinite(amount) or amount == 0 then
		return nil
	end
	local profile = profiles[player]
	if not profile or not profile.loaded then
		return nil
	end
	local data = profile.data
	data.cash = math.max(0, data.cash + amount)
	if amount > 0 and not NON_EARNING_REASONS[reason or ""] then
		data.totalEarned += amount
	end
	DataService.markDirty(player)
	return data.cash
end

-- Atomically checks and deducts. False if not loaded, invalid amount, or not enough cash.
function DataService.spendCash(player: Player, amount: number): boolean
	if not isFinite(amount) or amount < 0 then
		return false
	end
	local profile = profiles[player]
	if not profile or not profile.loaded then
		return false
	end
	local data = profile.data
	if data.cash < amount then
		return false
	end
	data.cash -= amount
	DataService.markDirty(player)
	return true
end

-- Builds the client snapshot. Works even when Garage/Monetization/Rewards services are missing or erroring.
function DataService.buildSnapshot(player: Player): Snapshot
	local profile = profiles[player]
	if not profile then
		return nil :: any
	end
	local data = profile.data

	-- passes
	local passes: { [string]: boolean } = {}
	for _, key in Monetization.PassOrder do
		local ok, owned = callSystem("MonetizationService", "hasPass", player, key)
		passes[key] = ok and owned == true
	end

	-- garage slots + income
	local garage: { [string]: SlotSnapshot } = {}
	local okSlots, slots = callSystem("GarageService", "slotSnapshots", player)
	if okSlots and typeof(slots) == "table" then
		garage = slots
	else
		for key, rec in data.garage do
			garage[key] = {
				carId = rec.carId,
				mutation = rec.mutation,
				uncollected = rec.uncollected,
				state = "Parked",
				income = EconomyMath.carIncome(rec.carId, rec.mutation),
			}
		end
	end

	local okMult, mult = callSystem("GarageService", "multiplier", player)
	local multiplier = if okMult and isFinite(mult) then mult else 1

	local okIncome, income = callSystem("GarageService", "incomePerSec", player)
	local incomePerSec = 0
	if okIncome and isFinite(income) then
		incomePerSec = income
	else
		for _, slot in garage do
			incomePerSec += slot.income or 0
		end
	end

	-- rewards views
	local today = EconomyMath.dayNumber(os.time())
	local okDaily, daily = callSystem("RewardsService", "getDailyView", player)
	if not okDaily or typeof(daily) ~= "table" then
		daily = {
			streak = data.daily.streak,
			canClaim = data.daily.lastClaimDay < today,
			nextDay = (data.daily.streak % 7) + 1,
		}
	end
	local okPlay, playtime = callSystem("RewardsService", "getPlaytimeView", player)
	if not okPlay or typeof(playtime) ~= "table" then
		-- fallback: today's stored playtime (seconds played today; RewardsService banks the live session)
		local pt = data.playtime
		local isToday = typeof(pt) == "table" and pt.day == today
		playtime = {
			claimed = if isToday then table.clone(pt.claimed) else {},
			sessionSeconds = if isToday then math.floor(pt.seconds) else 0,
		}
	end
	local okContracts, contracts = callSystem("RewardsService", "getContractsView", player)
	if not okContracts or typeof(contracts) ~= "table" then
		contracts = data.contracts
	end

	local plotIndex = player:GetAttribute("PlotIndex")

	return {
		cash = data.cash,
		totalEarned = data.totalEarned,
		rebirths = data.rebirths,
		slotsUnlocked = data.slotsUnlocked,
		maxSlots = Economy.MAX_SLOTS + (if passes.slots then Economy.PASS_EXTRA_SLOTS else 0),
		garage = garage,
		discovered = data.discovered,
		upgrades = data.upgrades,
		tools = data.tools,
		stats = data.stats,
		daily = daily,
		playtime = playtime,
		incomePerSec = incomePerSec,
		multiplier = multiplier,
		passes = passes,
		plotIndex = if typeof(plotIndex) == "number" then plotIndex else nil,
		tutorialDone = data.tutorialDone,
		settings = data.settings,
		contracts = contracts,
	}
end

-- Forces a save now (yields; respects the per-key write rate). Returns true if the write succeeded.
-- Use after high-value transfers (theft complete, purchases). Wrap in task.spawn if you don't need the result.
function DataService.saveNow(player: Player): boolean
	local profile = profiles[player]
	if not profile or not profile.loaded or profile.releasing then
		return false
	end
	return writeAsync(profile, false)
end

-- Extra (AdminService): wipe the profile back to defaults IN PLACE (same table identity), keeping receipt ids.
function DataService.resetData(player: Player): boolean
	local profile = profiles[player]
	if not profile or not profile.loaded then
		return false
	end
	local data = profile.data :: any
	local receipts = data.receipts
	for k in table.clone(data) do
		data[k] = nil
	end
	for k, v in makeTemplate() :: any do
		data[k] = v
	end
	data.receipts = receipts
	data.lastOnline = os.time()
	DataService.markDirty(player)
	return true
end

---------------------------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------------------------

local function release(player: Player)
	local profile = profiles[player]
	if not profile or profile.releasing then
		return
	end
	profile.releasing = true
	local wasLoaded = profile.loaded
	profile.loaded = false
	local userId = profile.userId
	releasingUsers[userId] = (releasingUsers[userId] or 0) + 1
	pendingReleases += 1

	if wasLoaded and not profile.lost then
		DataService.Releasing:Fire(player, profile.data)
	end
	if not profile.lost then
		local ok = writeAsync(profile, true)
		if not ok and mode == "live" then
			warn(("[DataService] FINAL SAVE FAILED for %s (%d)"):format(player.Name, userId))
		end
	end

	if profiles[player] == profile then
		profiles[player] = nil
	end
	activeSessions[profile.session] = nil
	releasingUsers[userId] = math.max(0, (releasingUsers[userId] or 1) - 1)
	if releasingUsers[userId] == 0 then
		releasingUsers[userId] = nil
	end
	pendingReleases -= 1
end

local function loadPlayer(player: Player)
	if profiles[player] or loadingPlayers[player] then
		return
	end
	loadingPlayers[player] = true
	loadingCount += 1

	local function finish()
		loadingPlayers[player] = nil
		loadingCount -= 1
	end

	waitForMode()
	local userId = player.UserId

	-- fast rejoin to the same server: wait for our own release write to land first
	local t0 = os.clock()
	while (releasingUsers[userId] or 0) > 0 and os.clock() - t0 < 30 do
		task.wait(0.2)
	end

	local session = newSessionId()
	activeSessions[session] = true
	local key = KEY_PREFIX .. tostring(userId)

	local status: string, data: PlayerData?, isNew: boolean
	if mode == "memory" then
		local d, fresh = prepare(nil, os.time())
		status, data, isNew = "ok", d, fresh
	else
		status, data, isNew = claimAsync(player, userId, key, session)
	end

	if status ~= "ok" or not data then
		activeSessions[session] = nil
		finish()
		if status == "failed" and player.Parent == Players then
			player:Kick(KICK_LOAD_FAILED)
		end
		return
	end

	local profile: Profile = {
		player = player,
		userId = userId,
		key = key,
		session = session,
		data = data,
		loaded = true,
		releasing = false,
		lost = false,
		saving = false,
		dirty = false,
		changeGen = 0,
		nextAutosave = os.clock() + AUTOSAVE_INTERVAL * 0.5 + (userId % 60),
		pushQueued = false,
		isNew = isNew,
		previousLastOnline = data.lastOnline,
		joinedAt = os.clock(),
	}
	profiles[player] = profile
	finish()

	if player.Parent ~= Players or shuttingDown then
		-- left (or server closing) while we were loading: give the lock back right away
		profile.loaded = false
		task.spawn(release, player)
		return
	end

	syncAttributes(player, data)
	player:SetAttribute("DataLoaded", true)
	DataService.Loaded:Fire(player, data)
	queuePush(profile)
end

local function onShutdown()
	shuttingDown = true
	if mode == "memory" then
		return
	end
	local deadline = os.clock() + SHUTDOWN_TIMEOUT
	for player in profiles do
		task.spawn(release, player)
	end
	while (pendingReleases > 0 or loadingCount > 0) and os.clock() < deadline do
		task.wait(0.1)
		for player, profile in profiles do
			if not profile.releasing then
				task.spawn(release, player) -- profiles that finished loading after shutdown began
			end
		end
	end
end

local function autosaveLoop()
	while true do
		task.wait(1)
		if shuttingDown then
			return
		end
		local now = os.clock()
		for _, profile in profiles do
			if profile.loaded and not profile.releasing and not profile.saving and now >= profile.nextAutosave then
				profile.nextAutosave = now + AUTOSAVE_INTERVAL
				task.spawn(writeAsync, profile, false)
			end
		end
	end
end

function DataService.init()
	Net.handle("GetSnapshot", function(player: Player)
		local data = DataService.waitFor(player, 20)
		if not data then
			return nil
		end
		return DataService.buildSnapshot(player)
	end, 2)

	Net.on("SetSetting", function(player: Player, key: any, value: any)
		if not Net.isString(key, 32) or not SETTING_KEYS[key] or typeof(value) ~= "boolean" then
			return
		end
		local data = DataService.get(player)
		if not data or not DataService.isLoaded(player) then
			return
		end
		local settings = data.settings :: any
		if settings[key] ~= value then
			settings[key] = value
			DataService.markDirty(player)
		end
	end, 6)

	Net.on("TutorialDone", function(player: Player)
		local data = DataService.get(player)
		if not data or not DataService.isLoaded(player) or data.tutorialDone then
			return
		end
		data.tutorialDone = true
		DataService.markDirty(player)
	end, 1)
end

function DataService.start()
	game:BindToClose(onShutdown)

	Players.PlayerRemoving:Connect(function(player: Player)
		task.spawn(release, player)
	end)
	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(loadPlayer, player)
	end)

	resolveMode()

	for _, player in Players:GetPlayers() do
		task.spawn(loadPlayer, player)
	end

	autosaveLoop()
end

return DataService
