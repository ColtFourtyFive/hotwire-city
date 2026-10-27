--!strict
-- RewardsService (SPEC §6): every "come back tomorrow / stay a bit longer" hook.
--
--   * Offline earnings - on DataService.Loaded: min(now - lastOnline, OFFLINE_CAP) x base income x rate, where base
--     income = sum of parked cars' carIncome x rebirth multiplier (no events / VIP cash). VIP gets VIP_OFFLINE_RATE.
--     Skipped under 60s. Paid 3s after load + OfflineEarnings remote ("While you were away...").
--   * Daily streak - 7-day cycle on UTC days (EconomyMath.dayNumber). Claiming the day after your last claim
--     continues the streak; missing a day resets it to 1. ClaimDaily remote.
--   * Playtime gifts - minutes played per UTC DAY, persisted in data.playtime = { day, seconds, claimed }
--     (rejoining does not reset them). Session seconds are banked into data.playtime every few seconds and on
--     leave (DataService.Releasing); ClaimPlaytime(index) is checked against stored + unbanked session seconds.
--   * Codes - RedeemCode(code): case/space-insensitive, once per account. The code table is SERVER-ONLY
--     (ServerScriptService.Server.Config.Codes) so clients can't datamine unreleased codes.
--   * Rewards - "cash" (flat), "incomeMinutes" (minutes of current income, never less than the entry's `min`,
--     default MIN_INCOME_REWARD) or "car" (random car of a rarity; cash fallback when the garage is full).
--   * Contracts - 3 per UTC day, deterministic per player+day (Random.new(userId * 7 + day)), no two share a stat.
--     progress(player, stat, amount) is called by every system (the single entry point); completed contracts
--     auto-claim with cash (max($500, reward seconds of income)) + Notify + Sound. "driftSeconds"/"topSpeedHit"
--     are derived here by sampling the player's car unless some system reports them explicitly.
--   * Group / friends - isInGroup(player) and friendsInServer(player) are cached (never yield) for the multiplier.
--   * Referral - GetJoinData().ReferredByPlayerId: the invitee gets a random REFERRAL_REWARD_RARITY car once per
--     account. The inviter (if in this server) gets one after the invitee has played REFERRAL_INVITER_MIN_SECONDS,
--     at most REFERRAL_INVITER_DAILY_CAP per UTC day (data.referralsPaid = { day, count }) so alts can't farm it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Cars = require(Shared.Config.Cars)
local Economy = require(Shared.Config.Economy)
local EconomyMath = require(Shared.Util.EconomyMath)
local Format = require(Shared.Util.Format)
local MapLayout = require(Shared.Util.MapLayout)
local Net = require(Shared.Net)
local Rarity = require(Shared.Config.Rarity)
local Rolls = require(Shared.Util.Rolls)
local VehicleConfig = require(Shared.Config.Vehicle)

-- server-only (ServerScriptService.Server.Config.Codes); never in ReplicatedStorage
local Codes = require(script.Parent.Parent.Config.Codes)

local RewardsService = {}

RewardsService.MIN_OFFLINE_SECONDS = 60
RewardsService.OFFLINE_DELAY = 3
RewardsService.MIN_INCOME_REWARD = 500
RewardsService.MIN_CONTRACT_REWARD = 500
RewardsService.CAR_FALLBACK_FRACTION = 0.5
RewardsService.CODE_MAX_LENGTH = 32
RewardsService.TOP_SPEED_FRACTION = 1 + (VehicleConfig.NITRO_SPEED_MULT - 1) * 0.6 -- needs nitro to reach
RewardsService.DRIFT_MIN_SPEED = 25
RewardsService.PLAYTIME_BANK_INTERVAL = 5 -- session seconds are banked into data.playtime at least this often
RewardsService.PLAYTIME_DAY_CAP = 86400
RewardsService.PASS_WAIT = 10 -- offline earnings wait up to this long for the VIP pass lookup to finish
RewardsService.REFERRAL_INVITER_MIN_SECONDS = 600 -- the invitee must play this long before the inviter is paid
RewardsService.REFERRAL_INVITER_DAILY_CAP = 3 -- inviter car rewards per UTC day

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
	warn(("[RewardsService] could not load %s: %s"):format(name, tostring(mod)))
	return nil
end

-- Test seam: replace a system module seen by sys(). Never used at runtime.
function RewardsService._inject(name: string, mod: any)
	systemCache[name] = mod
end

local function call(name: string, fnName: string, ...: any): (boolean, any)
	local mod = sys(name)
	local fn = mod and mod[fnName]
	if typeof(fn) ~= "function" then
		return false, nil
	end
	local ok, res = pcall(fn, ...)
	if not ok then
		warn(("[RewardsService] %s.%s failed: %s"):format(name, fnName, tostring(res)))
	end
	return ok, res
end

local function finite(v: any): boolean
	return typeof(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local rng = Random.new()

local contractById: { [string]: Economy.ContractDef } = {}
for _, def in Economy.Contracts do
	contractById[def.id] = def
end

---------------------------------------------------------------------------------------------------------------------
-- Pure helpers (exported for tests)
---------------------------------------------------------------------------------------------------------------------

export type DailyView = { streak: number, canClaim: boolean, nextDay: number }

-- Result of claiming the daily reward on `today`: (canClaim, newStreak, rewardIndex 1..7).
function RewardsService._dailyClaim(streak: number, lastClaimDay: number, today: number): (boolean, number, number)
	if lastClaimDay >= today then
		return false, streak, ((math.max(1, streak) - 1) % #Economy.DAILY_REWARDS) + 1
	end
	local newStreak = if lastClaimDay == today - 1 then streak + 1 else 1
	return true, newStreak, ((newStreak - 1) % #Economy.DAILY_REWARDS) + 1
end

-- What the Daily menu shows. streak = current live streak (0 if broken); nextDay = reward index you get on the
-- next claim (today if claimable, else tomorrow's).
function RewardsService._dailyView(streak: number, lastClaimDay: number, today: number): DailyView
	local canClaim, newStreak, index = RewardsService._dailyClaim(streak, lastClaimDay, today)
	if canClaim then
		local alive = lastClaimDay == today - 1
		return { streak = if alive then streak else 0, canClaim = true, nextDay = index }
	end
	return { streak = newStreak, canClaim = false, nextDay = (newStreak % #Economy.DAILY_REWARDS) + 1 }
end

-- Playtime gift validation: (ok, reason?). claimed is keyed by tostring(index).
function RewardsService._canClaimPlaytime(
	index: any,
	sessionSeconds: number,
	claimed: { [string]: boolean }
): (boolean, string?)
	if not Net.isInt(index, 1, #Economy.PLAYTIME_REWARDS) then
		return false, "invalid"
	end
	local def = Economy.PLAYTIME_REWARDS[index]
	if claimed[tostring(index)] then
		return false, "claimed"
	end
	if sessionSeconds + 1 < def.minutes * 60 then
		return false, "early"
	end
	return true, nil
end

export type PlaytimeState = { day: number, seconds: number, claimed: { [string]: boolean } }

-- data.playtime for `day`: the same table when it already belongs to that day (fields coerced), else a fresh
-- { day, seconds = 0, claimed = {} } (a new UTC day starts a new gift ladder).
function RewardsService._playtimeFor(pt: any, day: number): PlaytimeState
	if typeof(pt) ~= "table" or pt.day ~= day then
		return { day = day, seconds = 0, claimed = {} }
	end
	if not finite(pt.seconds) or pt.seconds < 0 then
		pt.seconds = 0
	end
	pt.seconds = math.min(pt.seconds, RewardsService.PLAYTIME_DAY_CAP)
	if typeof(pt.claimed) ~= "table" then
		pt.claimed = {}
	end
	return pt :: PlaytimeState
end

-- Codes are case-insensitive and ignore spaces. Returns nil for junk input.
function RewardsService._normalizeCode(code: any): string?
	if typeof(code) ~= "string" or #code == 0 or #code > RewardsService.CODE_MAX_LENGTH * 2 then
		return nil
	end
	local norm = string.upper((code:gsub("%s+", "")))
	if #norm == 0 or #norm > RewardsService.CODE_MAX_LENGTH or norm:find("[^%w_]") then
		return nil
	end
	return norm
end

-- Deterministic daily contracts: CONTRACTS_PER_DAY unique ids with distinct stats, seeded by userId + day.
function RewardsService._rollContracts(userId: number, day: number): { string }
	local r = Random.new(userId * 7 + day)
	local pool = table.clone(Economy.Contracts)
	local out: { string } = {}
	local usedStats: { [string]: boolean } = {}
	while #out < Economy.CONTRACTS_PER_DAY and #pool > 0 do
		local i = r:NextInteger(1, #pool)
		local def = table.remove(pool, i) :: Economy.ContractDef
		if not usedStats[def.stat] then
			usedStats[def.stat] = true
			table.insert(out, def.id)
		end
	end
	return out
end

function RewardsService._contractReward(rewardSeconds: number, incomePerSec: number): number
	local income = if finite(incomePerSec) then math.max(0, incomePerSec) else 0
	return math.max(RewardsService.MIN_CONTRACT_REWARD, math.floor(rewardSeconds * income))
end

-- `minimum` = the reward entry's `min` floor (default MIN_INCOME_REWARD).
function RewardsService._incomeMinutesReward(minutes: number, incomePerSec: number, minimum: number?): number
	local income = if finite(incomePerSec) then math.max(0, incomePerSec) else 0
	local floor = if finite(minimum) then math.max(0, minimum :: number) else RewardsService.MIN_INCOME_REWARD
	return math.max(floor, math.floor(minutes * 60 * income))
end

-- Inviter referral cap (pure): (canPay, newState). state = data.referralsPaid ({ day, count }) or nil.
function RewardsService._referralAllowance(state: any, day: number, cap: number): (boolean, { day: number, count: number })
	local count = 0
	if typeof(state) == "table" and state.day == day and finite(state.count) then
		count = math.max(0, math.floor(state.count))
	end
	if count >= cap then
		return false, { day = day, count = count }
	end
	return true, { day = day, count = count + 1 }
end

-- Cash given instead of a reward car when the garage is full.
function RewardsService._carFallbackCash(carId: string, mutation: Rarity.MutationId?): number
	local def = Cars.get(carId)
	if not def then
		return RewardsService.MIN_INCOME_REWARD
	end
	local base = if def.price > 0 then def.price else def.income * 120
	return math.max(
		RewardsService.MIN_INCOME_REWARD,
		math.floor(base * RewardsService.CAR_FALLBACK_FRACTION * Rarity.getMutation(mutation or "None").multiplier)
	)
end

-- Offline earnings: (amount, cappedSeconds). garage = data.garage (all slots are parked while offline).
function RewardsService._offlineAmount(
	elapsed: number,
	garage: { [string]: any },
	rebirths: number,
	vip: boolean
): (number, number)
	if not finite(elapsed) or elapsed < RewardsService.MIN_OFFLINE_SECONDS then
		return 0, 0
	end
	local seconds = math.min(elapsed, Economy.OFFLINE_CAP_HOURS * 3600)
	local base = 0
	for _, rec in garage do
		if typeof(rec) == "table" and typeof(rec.carId) == "string" then
			base += EconomyMath.carIncome(rec.carId, rec.mutation or "None")
		end
	end
	base *= 1 + math.max(0, rebirths or 0) * Economy.REBIRTH_INCOME_BONUS
	local rate = if vip then Economy.VIP_OFFLINE_RATE else Economy.OFFLINE_RATE
	return math.floor(seconds * base * rate), math.floor(seconds)
end

-- Applies progress to a contract list in place. Returns the defs that just completed (now claimed).
function RewardsService._applyProgress(
	list: { { id: string, progress: number, claimed: boolean } },
	stat: string,
	amount: number
): ({ Economy.ContractDef }, boolean)
	local completed: { Economy.ContractDef } = {}
	local changed = false
	for _, c in list do
		local def = contractById[c.id]
		if def and def.stat == stat and not c.claimed then
			c.progress = math.min(def.goal, (c.progress or 0) + amount)
			changed = true
			if c.progress >= def.goal then
				c.claimed = true
				table.insert(completed, def)
			end
		end
	end
	return completed, changed
end

---------------------------------------------------------------------------------------------------------------------
-- Per-player session state
---------------------------------------------------------------------------------------------------------------------

type PState = {
	bankedAt: number, -- os.clock() up to which session playtime is already in data.playtime.seconds
	loadedAt: number, -- os.clock() when this session's data finished loading
	playtimeDay: number, -- UTC day playtimeNotified belongs to
	playtimeNotified: { [number]: boolean },
	loadedHandled: boolean,
	day: number,
	pendingReferrer: number?, -- inviter userId, paid once this invitee has played long enough
	driftAcc: number,
	topSpeedAt: number,
	inGroup: boolean,
	friends: number,
}

local pstates: { [Player]: PState } = {}
local friendPairs: { [string]: boolean } = {} -- "minUserId:maxUserId" -> friends?
-- stats some other system reports via progress() for every player (switches off the local car-sampling fallback)
local explicitStats: { [string]: boolean } = {}
local friendsBusy = false
local friendsAgain = false

local function getPS(player: Player): PState
	local ps = pstates[player]
	if not ps then
		local t = os.clock()
		ps = {
			bankedAt = t,
			loadedAt = t,
			playtimeDay = -1,
			playtimeNotified = {},
			loadedHandled = false,
			day = -1,
			pendingReferrer = nil,
			driftAcc = 0,
			topSpeedAt = -math.huge,
			inGroup = false,
			friends = 0,
		}
		pstates[player] = ps
	end
	return ps
end

local function getData(player: Player): any
	local DataService = sys("DataService")
	if not DataService or not DataService.isLoaded(player) then
		return nil
	end
	return DataService.get(player)
end

local function markDirty(player: Player)
	call("DataService", "markDirty", player)
end

local function notify(player: Player, kind: string, text: string, duration: number?)
	Net.fireClient("Notify", player, kind, text, duration)
end

local function sound(player: Player, key: string)
	Net.fireClient("Sound", player, key)
end

local function today(): number
	return EconomyMath.dayNumber(os.time())
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

local function incomeOf(player: Player): number
	local ok, income = call("GarageService", "incomePerSec", player)
	return if ok and finite(income) then income else 0
end

local function hasPass(player: Player, key: string): boolean
	local ok, owned = call("MonetizationService", "hasPass", player, key)
	return ok and owned == true
end

local function slotPosition(player: Player, slot: number): Vector3?
	local okIdx, index = call("PlotService", "getPlotIndex", player)
	if okIdx and typeof(index) == "number" then
		return MapLayout.slotWorld(index, slot).Position + Vector3.new(0, 4, 0)
	end
	return nil
end

local function rootPosition(player: Player): Vector3?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

-- Moves this session's unbanked play seconds into data.playtime (rolling it over on a new UTC day) and returns it.
-- Mutates data without markDirty on purpose: autosave / the leave save persist it, no snapshot push needed.
local function bankPlaytime(ps: PState, data: any): PlaytimeState
	local t = os.clock()
	local add = math.max(0, t - ps.bankedAt)
	ps.bankedAt = t
	local pt = RewardsService._playtimeFor(data.playtime, today())
	data.playtime = pt
	if ps.playtimeDay ~= pt.day then
		ps.playtimeDay = pt.day
		table.clear(ps.playtimeNotified)
	end
	pt.seconds = math.min(RewardsService.PLAYTIME_DAY_CAP, pt.seconds + add)
	return pt
end

---------------------------------------------------------------------------------------------------------------------
-- Reward granting (shared by daily / playtime / codes / referral)
---------------------------------------------------------------------------------------------------------------------

type Reward = { kind: string, amount: number?, min: number?, rarity: string? }

local function giveCash(player: Player, amount: number, reason: string)
	call("DataService", "addCash", player, amount, reason)
	Net.fireClient("CashPopup", player, amount, nil)
end

-- Grants a random car of a rarity (storeCar) or its cash fallback. Returns a short label for messages.
local function grantCar(player: Player, rarity: string, reason: string): string
	local rid: Rarity.RarityId = if Rarity.Tiers[rarity :: any] then rarity :: any else "Rare"
	local def = Rolls.carOfRarity(rid, "any", rng)
	local mutation = Rolls.mutation(1, rng)
	local label = carLabel(def.id, mutation)
	local Garage = sys("GarageService")
	local stored, slot = false, nil
	if Garage and typeof(Garage.storeCar) == "function" then
		local okCall, a, b = pcall(Garage.storeCar, player, def.id, mutation)
		if okCall and a == true then
			stored, slot = true, b
		elseif not okCall then
			warn("[RewardsService] storeCar failed: " .. tostring(a))
		end
	end
	if stored then
		call("GarageService", "discover", player, def.id)
		local pos = if typeof(slot) == "number" then slotPosition(player, slot) else nil
		pos = pos or rootPosition(player)
		if pos then
			Net.fireNear("Effect", pos, 250, "Confetti", { position = pos, rarity = def.rarity })
		end
		local hex = Rarity.Tiers[def.rarity].color:ToHex()
		if (Rarity.Tiers[def.rarity].order or 0) >= 4 then
			Net.fireAll(
				"EventFeed",
				`🎁 <b>{richEscape(player.DisplayName)}</b> unwrapped a <font color="#{hex}"><b>{richEscape(label)}</b></font>!`
			)
		end
		return label
	end
	local cash = RewardsService._carFallbackCash(def.id, mutation)
	giveCash(player, cash, reason)
	notify(player, "warning", `Garage full! Your {label} was swapped for {Format.cash(cash)}.`, 5)
	return Format.cash(cash)
end

-- Grants one reward entry. Returns a label ("$1.5K", "Rare Hot Hatch") for the success toast.
function RewardsService.grant(player: Player, reward: Reward, reason: string): string
	local kind = reward.kind
	if kind == "cash" then
		local amount = math.max(0, math.floor(reward.amount or 0))
		giveCash(player, amount, reason)
		return Format.cash(amount)
	elseif kind == "incomeMinutes" then
		local amount = RewardsService._incomeMinutesReward(reward.amount or 1, incomeOf(player), reward.min)
		giveCash(player, amount, reason)
		return Format.cash(amount)
	elseif kind == "car" then
		return grantCar(player, reward.rarity or "Rare", reason)
	end
	warn("[RewardsService] unknown reward kind " .. tostring(kind))
	return "?"
end

---------------------------------------------------------------------------------------------------------------------
-- Contracts
---------------------------------------------------------------------------------------------------------------------

-- Makes sure data.contracts holds today's contracts. Returns true if it re-rolled.
local function ensureContracts(player: Player, data: any): boolean
	local day = today()
	local state = data.contracts
	if typeof(state) == "table" and state.day == day and typeof(state.list) == "table" and #state.list > 0 then
		return false
	end
	local list = {}
	for _, id in RewardsService._rollContracts(player.UserId, day) do
		table.insert(list, { id = id, progress = 0, claimed = false })
	end
	data.contracts = { day = day, list = list }
	return true
end

local function applyProgress(player: Player, stat: string, amount: number)
	local data = getData(player)
	if not data then
		return
	end
	local rolled = ensureContracts(player, data)
	local completed, changed = RewardsService._applyProgress(data.contracts.list, stat, amount)
	if #completed > 0 then
		local income = incomeOf(player)
		for _, def in completed do
			local cash = RewardsService._contractReward(def.reward, income)
			giveCash(player, cash, "contract")
			notify(player, "money", `✅ CONTRACT DONE: {def.text}  +{Format.cash(cash)}`, 5)
		end
		sound(player, "CashBig")
		local pos = rootPosition(player)
		if pos then
			Net.fireNear("Effect", pos, 150, "CashBurst", { position = pos })
		end
	end
	if changed or rolled then
		markDirty(player)
	end
end

-- Public: every system reports contract stats here ("steal", "deliverRare", "escape3", "collectCash", ...).
function RewardsService.progress(player: Player, stat: string, amount: number?)
	if player == nil or typeof(stat) ~= "string" then
		return
	end
	local amt = if amount == nil then 1 else amount
	if not finite(amt) or (amt :: number) <= 0 then
		return
	end
	explicitStats[stat] = true
	applyProgress(player, stat, amt :: number)
end

-- Extra: true if the player has an unclaimed contract today that tracks `stat`.
function RewardsService.hasOpenContract(player: Player, stat: string): boolean
	local data = getData(player)
	if not data or typeof(data.contracts) ~= "table" or data.contracts.day ~= today() then
		return false
	end
	for _, c in data.contracts.list do
		local def = contractById[c.id]
		if def and def.stat == stat and not c.claimed then
			return true
		end
	end
	return false
end

---------------------------------------------------------------------------------------------------------------------
-- Snapshot views
---------------------------------------------------------------------------------------------------------------------

function RewardsService.getDailyView(player: Player): DailyView
	local data = getData(player)
	if not data or typeof(data.daily) ~= "table" then
		return { streak = 0, canClaim = false, nextDay = 1 }
	end
	return RewardsService._dailyView(data.daily.streak or 0, data.daily.lastClaimDay or 0, today())
end

-- sessionSeconds = seconds played TODAY (UTC), stored + this session (field name kept for the client).
function RewardsService.getPlaytimeView(player: Player): { claimed: { [string]: boolean }, sessionSeconds: number }
	local data = getData(player)
	local ps = pstates[player]
	if not data or not ps or not ps.loadedHandled then
		local pt = if data then RewardsService._playtimeFor(data.playtime, today()) else nil
		return {
			claimed = if pt then table.clone(pt.claimed) else {},
			sessionSeconds = if pt then math.floor(pt.seconds) else 0,
		}
	end
	local pt = bankPlaytime(ps, data)
	return { claimed = table.clone(pt.claimed), sessionSeconds = math.floor(pt.seconds) }
end

function RewardsService.getContractsView(player: Player): { day: number, list: { any } }
	local data = getData(player)
	if not data then
		return { day = 0, list = {} }
	end
	ensureContracts(player, data) -- snapshot is being built right now; no markDirty needed
	local list = {}
	for _, c in data.contracts.list do
		if contractById[c.id] then
			table.insert(list, { id = c.id, progress = c.progress, claimed = c.claimed })
		end
	end
	return { day = data.contracts.day, list = list }
end

---------------------------------------------------------------------------------------------------------------------
-- Daily / playtime / codes
---------------------------------------------------------------------------------------------------------------------

function RewardsService.claimDaily(player: Player): (boolean, string?)
	local data = getData(player)
	if not data then
		return false, "loading"
	end
	local day = today()
	local canClaim, newStreak, index =
		RewardsService._dailyClaim(data.daily.streak or 0, data.daily.lastClaimDay or 0, day)
	if not canClaim then
		notify(player, "error", "Already claimed today! Come back tomorrow 📅")
		return false, "claimed"
	end
	data.daily.streak = newStreak
	data.daily.lastClaimDay = day
	local reward = Economy.DAILY_REWARDS[index]
	local label = RewardsService.grant(player, reward, "daily")
	local streakText = if newStreak > 1 then ` • {newStreak} day streak 🔥` else ""
	notify(player, "money", `📅 DAY {index} REWARD: {label}{streakText}`, 5)
	sound(player, "Purchase")
	local pos = rootPosition(player)
	if pos then
		Net.fireNear("Effect", pos, 150, "Confetti", { position = pos })
	end
	markDirty(player)
	return true, label
end

function RewardsService.claimPlaytime(player: Player, index: any): (boolean, string?)
	local data = getData(player)
	if not data then
		return false, "loading"
	end
	local ps = getPS(player)
	-- stored seconds for today + this session's unbanked seconds, all server-side
	local pt = bankPlaytime(ps, data)
	local ok, reason = RewardsService._canClaimPlaytime(index, pt.seconds, pt.claimed)
	if not ok then
		if reason == "early" then
			notify(player, "error", "Not yet! Keep playing to unlock this gift ⏳")
		end
		return false, reason
	end
	pt.claimed[tostring(index)] = true
	local label = RewardsService.grant(player, Economy.PLAYTIME_REWARDS[index], "playtime")
	notify(player, "money", `🎁 PLAYTIME GIFT: {label}`, 4)
	sound(player, "Purchase")
	markDirty(player)
	return true, label
end

function RewardsService.redeemCode(player: Player, code: any): (boolean, string?)
	local data = getData(player)
	if not data then
		return false, "loading"
	end
	local norm = RewardsService._normalizeCode(code)
	local def = if norm then Codes[norm] else nil
	if not norm or not def then
		notify(player, "error", "Invalid code ❌")
		return false, "invalid"
	end
	data.codes = data.codes or {}
	if data.codes[norm] then
		notify(player, "error", "You already used this code!")
		return false, "used"
	end
	data.codes[norm] = true
	local label = RewardsService.grant(player, def, "code")
	notify(player, "money", `🎟️ CODE {norm}: {label}`, 4)
	sound(player, "Purchase")
	markDirty(player)
	return true, label
end

---------------------------------------------------------------------------------------------------------------------
-- Social: group + friends
---------------------------------------------------------------------------------------------------------------------

function RewardsService.isInGroup(player: Player): boolean
	if Economy.GROUP_ID == 0 then
		return false
	end
	local ps = pstates[player]
	return ps ~= nil and ps.inGroup
end

function RewardsService.friendsInServer(player: Player): number
	local ps = pstates[player]
	return if ps then ps.friends else 0
end

local function pairKey(a: number, b: number): string
	return if a < b then `{a}:{b}` else `{b}:{a}`
end

local function recomputeFriends()
	if friendsBusy then
		friendsAgain = true
		return
	end
	friendsBusy = true
	repeat
		friendsAgain = false
		local list = Players:GetPlayers()
		local counts: { [Player]: number } = {}
		for i = 1, #list do
			for j = i + 1, #list do
				local a, b = list[i], list[j]
				local key = pairKey(a.UserId, b.UserId)
				local isFriend = friendPairs[key]
				if isFriend == nil then
					local ok, res = pcall(a.IsFriendsWith, a, b.UserId)
					isFriend = ok and res == true
					if ok then
						friendPairs[key] = isFriend -- only cache real answers; retry failures next time
					end
				end
				if isFriend then
					counts[a] = (counts[a] or 0) + 1
					counts[b] = (counts[b] or 0) + 1
				end
			end
		end
		for _, p in list do
			local ps = pstates[p]
			if ps and p.Parent == Players then
				local n = counts[p] or 0
				if n ~= ps.friends then
					local gained = n > ps.friends
					ps.friends = n
					markDirty(p)
					if gained and n > 0 then
						local pct = math.floor(math.min(n, Economy.FRIEND_BONUS_MAX) * Economy.FRIEND_BONUS_EACH * 100)
						notify(p, "success", `🤝 Playing with friends: +{pct}% income!`, 4)
					end
				end
			end
		end
	until not friendsAgain
	friendsBusy = false
end

local function checkGroup(player: Player)
	if Economy.GROUP_ID == 0 then
		return
	end
	local ok, res = pcall(player.IsInGroup, player, Economy.GROUP_ID)
	local ps = pstates[player]
	if ok and ps and player.Parent == Players then
		ps.inGroup = res == true
		if ps.inGroup then
			markDirty(player)
		end
	end
end

---------------------------------------------------------------------------------------------------------------------
-- Join: offline earnings, referral, reminders
---------------------------------------------------------------------------------------------------------------------

local function grantOffline(player: Player, data: any)
	local DataService = sys("DataService")
	local info = if DataService and typeof(DataService.getSessionInfo) == "function"
		then DataService.getSessionInfo(player)
		else nil
	if info and info.isNew then
		return
	end
	local last = if info and finite(info.previousLastOnline) then info.previousLastOnline else data.lastOnline
	if not finite(last) or last <= 0 then
		return
	end
	task.wait(RewardsService.OFFLINE_DELAY)
	-- VIP doubles offline earnings: give a slow/retrying gamepass lookup time to finish (bounded)
	local deadline = os.clock() + RewardsService.PASS_WAIT
	while os.clock() < deadline do
		local okReady, ready = call("MonetizationService", "passesReady", player)
		if not okReady or ready ~= false then
			break
		end
		task.wait(0.25)
		if player.Parent ~= Players then
			return
		end
	end
	if player.Parent ~= Players or getData(player) ~= data then
		return
	end
	local elapsed = os.time() - last
	local amount, seconds =
		RewardsService._offlineAmount(elapsed, data.garage or {}, data.rebirths or 0, hasPass(player, "vip"))
	if amount <= 0 then
		return
	end
	call("DataService", "addCash", player, amount, "offline")
	Net.fireClient("OfflineEarnings", player, amount, seconds)
	sound(player, "CountingMoney")
end

local function handleReferral(player: Player, data: any)
	if data.referralRewarded then
		return
	end
	local ok, joinData = pcall(player.GetJoinData, player)
	if not ok or typeof(joinData) ~= "table" then
		return
	end
	local referrer = joinData.ReferredByPlayerId
	if typeof(referrer) ~= "number" or referrer <= 0 or referrer == player.UserId then
		return
	end
	task.wait(4) -- let the garage + HUD come up first so the confetti is seen
	if player.Parent ~= Players or getData(player) ~= data or data.referralRewarded then
		return
	end
	data.referralRewarded = true
	markDirty(player)
	local rarity = Economy.REFERRAL_REWARD_RARITY
	local label = grantCar(player, rarity, "referral")
	notify(player, "success", `🎉 You joined from a friend's invite! FREE car: {label}`, 6)
	sound(player, "CashBig")
	-- the inviter is paid later (slowLoop -> payInviter) once this invitee has really played a while
	local ps = pstates[player]
	if ps then
		ps.pendingReferrer = referrer
	end
end

-- Inviter reward: only while both are in this server, after the invitee played REFERRAL_INVITER_MIN_SECONDS,
-- capped per inviter per UTC day.
local function payInviter(player: Player, ps: PState)
	local referrer = ps.pendingReferrer
	ps.pendingReferrer = nil
	if not referrer then
		return
	end
	local inviter = Players:GetPlayerByUserId(referrer)
	local idata = if inviter then getData(inviter) else nil
	if not inviter or not idata then
		return
	end
	local allowed, newState =
		RewardsService._referralAllowance(idata.referralsPaid, today(), RewardsService.REFERRAL_INVITER_DAILY_CAP)
	if not allowed then
		notify(inviter, "info", `🎉 Thanks for bringing {player.DisplayName}! (Daily invite gifts used up)`, 5)
		return
	end
	idata.referralsPaid = newState
	markDirty(inviter)
	local label = grantCar(inviter, Economy.REFERRAL_REWARD_RARITY, "referral")
	notify(inviter, "success", `🎉 {player.DisplayName} joined from your invite! FREE car: {label}`, 6)
	sound(inviter, "CashBig")
	Net.fireAll(
		"EventFeed",
		`🎉 <b>{richEscape(inviter.DisplayName)}</b> brought <b>{richEscape(player.DisplayName)}</b> to Hotwire City!`
	)
end

local function onLoaded(player: Player, data: any)
	local ps = getPS(player)
	if ps.loadedHandled or typeof(data) ~= "table" then
		return
	end
	ps.loadedHandled = true
	ps.day = today()
	-- playtime counts from the moment the data is in (not while loading)
	local t = os.clock()
	ps.loadedAt = t
	ps.bankedAt = t
	bankPlaytime(ps, data)
	if ensureContracts(player, data) then
		markDirty(player)
	end
	task.spawn(grantOffline, player, data)
	task.spawn(handleReferral, player, data)
	task.delay(8, function()
		if player.Parent ~= Players or getData(player) ~= data then
			return
		end
		-- new players are mid-tutorial (menu buttons hidden); the HUD's DAILY badge advertises it afterwards
		if data.tutorialDone ~= true then
			return
		end
		if RewardsService.getDailyView(player).canClaim then
			notify(player, "info", "🎁 Your DAILY REWARD is ready! Tap 🎁 DAILY to claim.", 6)
		end
	end)
end

---------------------------------------------------------------------------------------------------------------------
-- Background loops
---------------------------------------------------------------------------------------------------------------------

-- Samples the player's car for drift seconds + top speed (only while such a contract is open).
local function driveSample(player: Player, ps: PState, dt: number)
	if player:GetAttribute("Driving") ~= true then
		ps.driftAcc = 0
		return
	end
	local wantDrift = not explicitStats.driftSeconds and RewardsService.hasOpenContract(player, "driftSeconds")
	local wantSpeed = not explicitStats.topSpeedHit and RewardsService.hasOpenContract(player, "topSpeedHit")
	if not wantDrift and not wantSpeed then
		return
	end
	local ok, car = call("VehicleService", "getDriving", player)
	if not ok or typeof(car) ~= "table" then
		return
	end
	local chassis = car.chassis
	if typeof(chassis) ~= "Instance" or not chassis:IsA("BasePart") or chassis.Parent == nil then
		return
	end
	local vel = chassis.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z)
	local speed = flat.Magnitude
	if wantDrift then
		local lateral = math.abs(chassis.CFrame:VectorToObjectSpace(vel).X)
		if speed >= RewardsService.DRIFT_MIN_SPEED and lateral >= VehicleConfig.DRIFT_SLIP_SPEED then
			ps.driftAcc += dt
			if ps.driftAcc >= 1 then
				local whole = math.floor(ps.driftAcc)
				ps.driftAcc -= whole
				applyProgress(player, "driftSeconds", whole)
			end
		end
	end
	if wantSpeed then
		local def = Cars.get(car.carId)
		local clock = os.clock()
		if def and speed >= def.topSpeed * RewardsService.TOP_SPEED_FRACTION and clock - ps.topSpeedAt > 5 then
			ps.topSpeedAt = clock
			applyProgress(player, "topSpeedHit", 1)
		end
	end
end

local function slowTick(player: Player, ps: PState, day: number)
	local data = getData(player)
	if not data then
		return
	end
	if not ps.loadedHandled then
		onLoaded(player, data)
	end
	-- UTC day rollover while online: fresh contracts + daily reward (+ a new playtime gift ladder)
	if ps.day ~= day then
		ps.day = day
		ensureContracts(player, data)
		markDirty(player)
		notify(player, "info", "🌅 New day! Fresh contracts + your daily reward are ready.", 6)
	end
	-- bank today's playtime + gift ready reminders (the reminder also refreshes the snapshot)
	local pt = bankPlaytime(ps, data)
	for i, def in Economy.PLAYTIME_REWARDS do
		if not ps.playtimeNotified[i] and not pt.claimed[tostring(i)] and pt.seconds >= def.minutes * 60 then
			ps.playtimeNotified[i] = true
			notify(player, "info", "⏰ A playtime gift is ready! Tap ⏰ GIFTS to open it.", 5)
			markDirty(player)
			break
		end
	end
	if ps.pendingReferrer and os.clock() - ps.loadedAt >= RewardsService.REFERRAL_INVITER_MIN_SECONDS then
		payInviter(player, ps)
	end
end

local function slowLoop()
	while true do
		task.wait(RewardsService.PLAYTIME_BANK_INTERVAL)
		local day = today()
		for player, ps in table.clone(pstates) do
			if player.Parent == Players then
				local ok, err = pcall(slowTick, player, ps, day)
				if not ok then
					warn("[RewardsService] slow tick failed: " .. tostring(err))
				end
			end
		end
	end
end

local function fastLoop()
	local dt = 0.25
	while true do
		task.wait(dt)
		for player, ps in pstates do
			if player.Parent == Players then
				local ok, err = pcall(driveSample, player, ps, dt)
				if not ok then
					warn("[RewardsService] drive sample failed: " .. tostring(err))
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------------------------------

function RewardsService.init()
	Net.on("ClaimDaily", function(player: Player)
		RewardsService.claimDaily(player)
	end, 1)
	Net.on("ClaimPlaytime", function(player: Player, index: any)
		if not Net.isInt(index, 1, #Economy.PLAYTIME_REWARDS) then
			return
		end
		RewardsService.claimPlaytime(player, index)
	end, 2)
	Net.on("RedeemCode", function(player: Player, code: any)
		if not Net.isString(code, RewardsService.CODE_MAX_LENGTH * 2) then
			return
		end
		RewardsService.redeemCode(player, code)
	end, 1)

	local DataService = sys("DataService")
	if DataService and DataService.Loaded then
		DataService.Loaded:Connect(function(player: Player, data: any)
			if player.Parent == Players then
				onLoaded(player, data)
			end
		end)
	end
	if DataService and DataService.Releasing then
		-- fired right before the final save on leave / shutdown: bank the last seconds of playtime
		DataService.Releasing:Connect(function(player: Player, data: any)
			local ps = pstates[player]
			if ps and ps.loadedHandled and typeof(data) == "table" then
				bankPlaytime(ps, data)
			end
		end)
	end
end

function RewardsService.start()
	local function onJoin(player: Player)
		getPS(player)
		task.spawn(checkGroup, player)
		task.spawn(recomputeFriends)
		local data = getData(player)
		if data then
			onLoaded(player, data)
		end
	end
	Players.PlayerAdded:Connect(onJoin)
	Players.PlayerRemoving:Connect(function(player: Player)
		local ps = pstates[player]
		local DataService = sys("DataService")
		local data = if DataService and typeof(DataService.get) == "function" then DataService.get(player) else nil
		if ps and ps.loadedHandled and typeof(data) == "table" then
			bankPlaytime(ps, data) -- before the final save (DataService.Releasing also banks; idempotent)
		end
		pstates[player] = nil
		local uid = player.UserId
		for key in table.clone(friendPairs) do
			local a, b = key:match("^(%-?%d+):(%-?%d+)$")
			if tonumber(a) == uid or tonumber(b) == uid then
				friendPairs[key] = nil
			end
		end
		task.delay(1, recomputeFriends) -- the leaving player is still listed by GetPlayers() this frame
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(onJoin, player)
	end
	task.spawn(fastLoop)
	slowLoop()
end

return RewardsService
