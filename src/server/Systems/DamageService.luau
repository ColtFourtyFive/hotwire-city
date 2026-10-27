--!strict
-- DamageService (gta_combat §6, §7, §8): THE authority for player health and armor, PvP protection rules, crimes from
-- violence, and the WASTED flow.
--
-- Health / armor
--   * The server keeps health + armor per player in its own table and writes Humanoid.Health from it. The default
--     character "Health" regen script is removed on spawn (it would heal 1 %/s); client-side Health changes are
--     ignored (anything that raises Health is put back; unexplained drops are adopted as world damage).
--   * Regen: 6 s after the last damage, +4 HP/s up to 50 (never above). Own garage: +25 HP/s to 100 after 3 s inside,
--     not while In Combat. Armor (0..100) absorbs 100 % of damage first; it is persisted (data.armor) and lost on
--     WASTED / BUSTED. Med kits: +40 over 1.5 s, carry 3, not within 1 s of taking damage.
-- Protection (canDamage)
--   * Spawn protection 6 s after any spawn / release, or until the player fires first.
--   * Safe zones (MapLayout.safeZones): no damage in or out; weapons holstered. Your own garage protects only you
--     and you may still hit a raider inside it. Entering while In Combat: protection starts after 5 s inside.
--   * Passive mode (SetPassive): immune and harmless to players; can't enable while wanted, In Combat, or carrying a
--     player-stolen car; 5 min re-enable cooldown; turning it off locks weapons for 10 s.
--   * Rookie protection: the first 30 min of total playtime work like passive (persisted countdown). Ends early on
--     dealing player damage, buying a rifle, or opting out.
--   * Revenge immunity: an attacker who downs you twice within 3 min can't damage you for 5 min (and you may enable
--     passive at once). Menace: downing 3 non-wanted players in 5 min (or 2 rookies / passive-adjacent targets)
--     = minimum 3 stars + bounty + red map marker for 5 min (10 min on a repeat).
--   * Bounties: 4+ stars carry min(10 % cash, stars x 20 s income), paid FROM the target to whoever downs them
--     (players only; once per pair per 30 min). No other reward for downing a player.
-- Death (Humanoid.Died): DamageModel.classifyDeath -> "wasted" (damage within 10 s, or a plain death) or "busted"
--   (reset while wanted). Busted -> WantedService.bust(player, "died"). Wasted -> stars cleared (theft fails like a
--   bust), armor 0, hospital bill min(5 % cash, 120 s income) (free for rookies / undamaged deaths), Wasted remote,
--   ragdoll (joints intact), respawn after Players.RespawnTime = 5 at the nearest hospital (PlotService asks
--   consumeHospitalRespawn), spawn protection.
--
-- Replicated player attributes: Armor, InCombat, Protected (server time until), Passive, Rookie, Bounty, Menace,
-- SafeZone (zone kind or ""), WeaponsLockedUntil (server time).
-- Remotes: DamageTaken, HitConfirm, Wasted (fire), SetPassive, UseMedKit, BuyArmor / BuyMedKit are ShopService's.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local MapLayout = require(Shared.Util.MapLayout)
local Economy = require(Shared.Config.Economy)
local Police = require(Shared.Config.Police)
local Weapons = require(Shared.Config.Weapons)
local DamageModel = require(Shared.Combat.DamageModel)
local CrimeRules = require(Shared.Combat.CrimeRules)
local Ragdoll = require(Shared.Combat.Ragdoll)

local DamageService = {}

DamageService.Damaged = Signal.new() -- (victim: Player, healthTaken: number, armorTaken: number, info)
DamageService.Downed = Signal.new() -- (victim: Player, info: DamageInfo, kind: "wasted" | "busted")
DamageService.PlayerHit = Signal.new() -- (attacker: Player, victim: Player, info) a player damaged another player

DamageService.SPAWN_PROTECTION = 6
DamageService.COMBAT_TIME = 15
DamageService.SAFE_ENTRY_DELAY = 5
DamageService.PASSIVE_COOLDOWN = 300
DamageService.PASSIVE_OFF_LOCK = 10
DamageService.TICK = 0.25
DamageService.RESPAWN_TIME = 5
DamageService.HOSPITAL_PENDING_WINDOW = 60
-- The same crime by the same player is evaluated at most this often (forced crimes, i.e. downs, skip it).
DamageService.CRIME_COOLDOWN = {
	assault = 5, -- v1's per-attacker assault cooldown
	gunfire = 2,
	brandish = 2,
	pedHit = 3,
	copShot = 3,
	heliHit = 3,
} :: { [string]: number }
DamageService.DEFAULT_CRIME_COOLDOWN = 1.5

export type DamageInfo = {
	amount: number, -- raw damage before armor (already multiplied by part / falloff / occupant)
	source: Player?, -- attacking player (nil for police / world)
	police: boolean?, -- police fire
	weapon: string?,
	part: string?, -- hit part name (head / torso / limb)
	position: Vector3?, -- hit point
	from: Vector3?, -- where the shot came from (damage arc)
	melee: boolean?,
}

export type HitResult = {
	applied: boolean,
	healthTaken: number,
	armorTaken: number,
	killed: boolean,
	reason: string?,
}

type PState = {
	player: Player,
	health: number,
	armor: number,
	lastDamageAt: number?,
	lastDamage: DamageInfo?,
	combatUntil: number,
	protectedUntil: number,
	spawnAt: number,
	firedSinceSpawn: boolean,
	passive: boolean,
	passiveReadyAt: number,
	weaponsLockedUntil: number,
	rookie: boolean,
	rookieSeconds: number,
	menaceUntil: number,
	menaceOffences: number,
	downHistory: { CrimeRules.DownRecord },
	downedBy: { [number]: { number } }, -- attacker userId -> down times (revenge)
	immuneFrom: { [number]: number }, -- attacker userId -> until (revenge immunity)
	bountyPaid: { [number]: number }, -- killer userId -> time a bounty was paid out
	safeKind: string?, -- current safe zone kind (or nil)
	safePlot: number?,
	safeSince: number,
	god: boolean,
	mercyUsed: boolean,
	mercyUntil: number,
	medkitUntil: number,
	medkitRate: number,
	hospital: CFrame?,
	hospitalAt: number,
	hospitalName: string?,
	humanoid: Humanoid?,
	writing: boolean,
	dead: boolean,
	conns: { RBXScriptConnection },
	copsDowned: number,
	pedOnly: boolean,
	lastCrime: { [string]: number },
}

local states: { [Player]: PState } = {}

-- HOOKS (tests swap these) ------------------------------------------------------------------------------------------
local systemCache: { [string]: any } = {}
local function loadSystem(name: string): any
	local cached = systemCache[name]
	if cached ~= nil then
		return cached
	end
	local inst = script.Parent and script.Parent:FindFirstChild(name)
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst :: any)
		if ok and typeof(mod) == "table" then
			systemCache[name] = mod
			return mod
		end
	end
	return nil
end

local hooks = {
	clock = os.clock,
	system = loadSystem,
	serverNow = function(): number
		local ok, t = pcall(function()
			return Workspace:GetServerTimeNow()
		end)
		return if ok and typeof(t) == "number" then t else os.clock()
	end,
	fireClient = function(name: string, player: Player, ...: any)
		Net.fireClient(name, player, ...)
	end,
}

function DamageService._setHooks(overrides: { [string]: any })
	for k, v in overrides do
		(hooks :: any)[k] = v
	end
	table.clear(systemCache)
end

local function sys(name: string): any
	return hooks.system(name)
end

local function call(name: string, fn: string, ...: any): (boolean, any)
	local mod = sys(name)
	local f = mod and mod[fn]
	if typeof(f) ~= "function" then
		return false, nil
	end
	local ok, res = pcall(f, ...)
	if not ok then
		warn(("[DamageService] %s.%s failed: %s"):format(name, fn, tostring(res)))
		return false, nil
	end
	return true, res
end

local function setAttr(player: Player, key: string, value: any)
	if player:GetAttribute(key) ~= value then
		pcall(function()
			player:SetAttribute(key, value)
		end)
	end
end

local function notify(player: Player, kind: string, text: string, duration: number?)
	pcall(hooks.fireClient, "Notify", player, kind, text, duration)
end

local function getData(player: Player): any
	local ok, data = call("DataService", "get", player)
	if ok and typeof(data) == "table" then
		return data
	end
	return nil
end

local function markDirty(player: Player)
	call("DataService", "markDirty", player)
end

local function rootOf(player: Player): BasePart?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function wantedOf(player: Player): number
	local w = player:GetAttribute("Wanted")
	return if typeof(w) == "number" then w else 0
end

local function incomeOf(player: Player): number
	local ok, v = call("GarageService", "incomePerSec", player)
	if ok and typeof(v) == "number" and v == v then
		return v
	end
	local a = player:GetAttribute("IncomePerSec")
	return if typeof(a) == "number" then a else 0
end

-- STATE ------------------------------------------------------------------------------------------------------------------

local function newState(player: Player): PState
	local now = hooks.clock()
	return {
		player = player,
		health = DamageModel.MAX_HEALTH,
		armor = 0,
		lastDamageAt = nil,
		lastDamage = nil,
		combatUntil = 0,
		protectedUntil = now + DamageService.SPAWN_PROTECTION,
		spawnAt = now,
		firedSinceSpawn = false,
		passive = false,
		passiveReadyAt = 0,
		weaponsLockedUntil = 0,
		rookie = false,
		rookieSeconds = 0,
		menaceUntil = 0,
		menaceOffences = 0,
		downHistory = {},
		downedBy = {},
		immuneFrom = {},
		bountyPaid = {},
		safeKind = nil,
		safePlot = nil,
		safeSince = 0,
		god = false,
		mercyUsed = false,
		mercyUntil = 0,
		medkitUntil = 0,
		medkitRate = 0,
		hospital = nil,
		hospitalAt = 0,
		hospitalName = nil,
		humanoid = nil,
		writing = false,
		dead = false,
		conns = {},
		copsDowned = 0,
		pedOnly = true,
		lastCrime = {},
	}
end

local function getState(player: Player): PState
	local st = states[player]
	if not st then
		st = newState(player)
		states[player] = st
	end
	return st
end
DamageService._getState = getState

local function writeHumanoid(st: PState)
	local hum = st.humanoid
	if not hum or hum.Parent == nil then
		return
	end
	st.writing = true
	pcall(function()
		if hum.MaxHealth ~= DamageModel.MAX_HEALTH then
			hum.MaxHealth = DamageModel.MAX_HEALTH
		end
		if hum.Health > 0 or st.health <= 0 then
			hum.Health = st.health
		end
	end)
	st.writing = false
end

local function publishArmor(st: PState)
	setAttr(st.player, "Armor", st.armor)
	local data = getData(st.player)
	if data and data.armor ~= st.armor then
		data.armor = st.armor
	end
end

-- PUBLIC QUERIES ------------------------------------------------------------------------------------------------------

function DamageService.getHealth(player: Player): number
	local st = states[player]
	return if st then st.health else DamageModel.MAX_HEALTH
end

function DamageService.getArmor(player: Player): number
	local st = states[player]
	return if st then st.armor else 0
end

function DamageService.isInCombat(player: Player): boolean
	local st = states[player]
	return st ~= nil and hooks.clock() < st.combatUntil
end

function DamageService.isPassive(player: Player): boolean
	local st = states[player]
	return st ~= nil and st.passive
end

function DamageService.isRookie(player: Player): boolean
	local st = states[player]
	return st ~= nil and st.rookie
end

function DamageService.isMenace(player: Player): boolean
	local st = states[player]
	return st ~= nil and hooks.clock() < st.menaceUntil
end

-- Spawn-protected (6 s / until firing first).
function DamageService.isSpawnProtected(player: Player): boolean
	local st = states[player]
	return st ~= nil and not st.firedSinceSpawn and hooks.clock() < st.protectedUntil
end

-- Inside a safe zone that currently protects this player (the 5 s entry delay while In Combat already served).
function DamageService.isSafe(player: Player): boolean
	local st = states[player]
	if not st or not st.safeKind then
		return false
	end
	if st.safeKind == "garage" then
		local plot = player:GetAttribute("PlotIndex")
		if not (typeof(plot) == "number" and st.safePlot == plot) then
			return false -- someone else's garage: a raider is fair game for the owner
		end
	end
	local now = hooks.clock()
	if now < st.combatUntil and now - st.safeSince < DamageService.SAFE_ENTRY_DELAY then
		return false
	end
	return true
end

-- The safe-zone kind the player is standing in ("garage" only for their OWN plot), or nil.
function DamageService.safeZoneKind(player: Player): string?
	local st = states[player]
	if not st then
		return nil
	end
	if st.safeKind == "garage" then
		local plot = player:GetAttribute("PlotIndex")
		return if typeof(plot) == "number" and st.safePlot == plot then "garage" else nil
	end
	return st.safeKind
end

-- Can this player draw `weaponId` right now? (server equip gate; WeaponService asks)
function DamageService.canDraw(player: Player, weaponId: string): (boolean, string?)
	local st = states[player]
	if not st then
		return true, nil
	end
	local def = Weapons.get(weaponId)
	local isGun = Weapons.isGun(def)
	local now = hooks.clock()
	if now < st.weaponsLockedUntil and isGun then
		return false, "locked"
	end
	if isGun and (st.passive or st.rookie) and weaponId ~= "taser" then
		return false, if st.passive then "passive" else "rookie"
	end
	local kind = DamageService.safeZoneKind(player)
	if kind and kind ~= "garage" then
		return false, "safezone"
	end
	return true, nil
end

-- Pure protection rule (tested): may `attacker` damage `victim`? All inputs are plain flags.
export type RuleCtx = {
	sameTeam: boolean?, -- reserved (no crews in v2: friendly fire is on)
	victimProtected: boolean, -- spawn protection / passive / rookie / god / dead
	attackerHarmless: boolean, -- attacker passive or rookie
	victimSafe: boolean,
	attackerSafe: boolean, -- attacker inside a safe zone that is NOT their own garage
	attackerInOwnGarage: boolean,
	victimInAttackerGarage: boolean,
	revengeImmune: boolean, -- victim is immune from this attacker
}

function DamageService._ruleCanDamage(ctx: RuleCtx): (boolean, string?)
	if ctx.victimProtected then
		return false, "protected"
	end
	if ctx.attackerHarmless then
		return false, "harmless"
	end
	if ctx.revengeImmune then
		return false, "revenge"
	end
	if ctx.victimSafe then
		return false, "victimSafe"
	end
	if ctx.attackerSafe then
		return false, "attackerSafe"
	end
	if ctx.attackerInOwnGarage and not ctx.victimInAttackerGarage then
		return false, "attackerSafe" -- your garage is a safe house: you can defend it, not snipe from it
	end
	return true, nil
end

-- Player vs player gate (§8, §10.2 step 11).
function DamageService.canDamage(attacker: Player?, victim: Player): (boolean, string?)
	local vs = states[victim]
	if not vs or vs.dead then
		return false, "dead"
	end
	local now = hooks.clock()
	if attacker == nil then
		return not vs.god, if vs.god then "god" else nil
	end
	if attacker == victim then
		return false, "self"
	end
	local as = getState(attacker)
	local plot = attacker:GetAttribute("PlotIndex")
	local victimRoot = rootOf(victim)
	local attackerInOwnGarage = DamageService.safeZoneKind(attacker) == "garage"
	local victimInAttackerGarage = typeof(plot) == "number"
		and victimRoot ~= nil
		and MapLayout.plotAt(victimRoot.Position) == plot
	local attackerKind = DamageService.safeZoneKind(attacker)
	return DamageService._ruleCanDamage({
		victimProtected = vs.god or vs.passive or vs.rookie or (not vs.firedSinceSpawn and now < vs.protectedUntil),
		attackerHarmless = as.passive or as.rookie,
		revengeImmune = now < (vs.immuneFrom[attacker.UserId] or 0),
		victimSafe = DamageService.isSafe(victim),
		attackerSafe = attackerKind ~= nil and attackerKind ~= "garage",
		attackerInOwnGarage = attackerInOwnGarage,
		victimInAttackerGarage = victimInAttackerGarage,
	})
end

-- Police hold-fire flags for a suspect (PoliceAim.mayFire).
function DamageService.policeHoldFire(player: Player): boolean
	local st = states[player]
	if not st or st.dead or st.god then
		return true
	end
	local now = hooks.clock()
	if now - st.spawnAt < Police.HOLD_FIRE_RESPAWN then
		return true
	end
	if not st.firedSinceSpawn and now < st.protectedUntil then
		return true
	end
	if st.passive or st.rookie then
		return true
	end
	if DamageService.isSafe(player) then
		return true
	end
	return player:GetAttribute("Surrendering") == true
end

-- Mercy window (§9.3): once per life, under MERCY_HEALTH, police accuracy halves for MERCY_TIME.
function DamageService.mercyActive(player: Player): boolean
	local st = states[player]
	return st ~= nil and hooks.clock() < st.mercyUntil
end

function DamageService.lastDamage(player: Player): (DamageInfo?, number?)
	local st = states[player]
	if not st then
		return nil, nil
	end
	return st.lastDamage, st.lastDamageAt
end

-- STATE CHANGES --------------------------------------------------------------------------------------------------------

local function markCombat(player: Player)
	local st = getState(player)
	st.combatUntil = hooks.clock() + DamageService.COMBAT_TIME
	setAttr(player, "InCombat", true)
end
DamageService.markCombat = markCombat

-- The player fired a weapon: spawn protection ends (and rookies who shoot players lose rookie status elsewhere).
function DamageService.onFired(player: Player)
	local st = getState(player)
	if not st.firedSinceSpawn then
		st.firedSinceSpawn = true
		setAttr(player, "Protected", 0)
	end
end

function DamageService.setArmor(player: Player, value: number)
	local st = getState(player)
	st.armor = math.clamp(math.floor(value), 0, DamageModel.MAX_ARMOR)
	publishArmor(st)
	markDirty(player)
end

-- Adds armor up to the max. Returns false when already full.
function DamageService.addArmor(player: Player, amount: number): boolean
	local st = getState(player)
	if st.armor >= DamageModel.MAX_ARMOR then
		return false
	end
	DamageService.setArmor(player, st.armor + amount)
	return true
end

function DamageService.heal(player: Player, amount: number)
	local st = getState(player)
	if st.dead then
		return
	end
	st.health = math.clamp(st.health + amount, 0, DamageModel.MAX_HEALTH)
	writeHumanoid(st)
end

function DamageService.setGod(player: Player, on: boolean)
	local st = getState(player)
	st.god = on
	if on then
		st.health = DamageModel.MAX_HEALTH
		writeHumanoid(st)
	end
end

function DamageService.isGod(player: Player): boolean
	local st = states[player]
	return st ~= nil and st.god
end

local function setRookie(st: PState, on: boolean)
	st.rookie = on
	setAttr(st.player, "Rookie", on)
	if not on then
		st.rookieSeconds = 0
		local data = getData(st.player)
		if data and typeof(data.combat) == "table" then
			data.combat.rookieSeconds = 0
		end
	end
end

-- Rookie protection ends early (dealt player damage / bought a rifle / opted out).
function DamageService.endRookie(player: Player, why: string?)
	local st = states[player]
	if st and st.rookie then
		setRookie(st, false)
		notify(player, "info", "Rookie protection ended" .. (if why then " (" .. why .. ")." else "."), 4)
	end
end

local function passiveBlocked(player: Player, st: PState): string?
	if wantedOf(player) > 0 then
		return "You can't go passive while wanted."
	end
	if hooks.clock() < st.combatUntil then
		return "You can't go passive in the middle of a fight."
	end
	local ok, theft = call("TheftService", "getActiveTheft", player)
	if ok and theft ~= nil then
		return "You can't go passive while driving a stolen car."
	end
	return nil
end

-- SetPassive remote / phone toggle. Returns (ok, reason?).
function DamageService.setPassive(player: Player, on: boolean): (boolean, string?)
	local st = getState(player)
	local now = hooks.clock()
	if on == st.passive then
		return true, nil
	end
	if on then
		local blocked = passiveBlocked(player, st)
		if blocked then
			return false, blocked
		end
		local revengeBypass = false
		for _, untilT in st.immuneFrom do
			if now < untilT then
				revengeBypass = true
			end
		end
		if now < st.passiveReadyAt and not revengeBypass then
			return false, ("Passive mode is available again in %ds."):format(math.ceil(st.passiveReadyAt - now))
		end
		st.passive = true
		setAttr(player, "Passive", true)
		call("WeaponService", "holster", player)
	else
		st.passive = false
		st.passiveReadyAt = now + DamageService.PASSIVE_COOLDOWN
		st.weaponsLockedUntil = now + DamageService.PASSIVE_OFF_LOCK
		setAttr(player, "Passive", false)
		setAttr(player, "WeaponsLockedUntil", hooks.serverNow() + DamageService.PASSIVE_OFF_LOCK)
		if st.rookie then
			DamageService.endRookie(player, "opted out")
		end
	end
	local data = getData(player)
	if data and typeof(data.combat) == "table" then
		data.combat.passivePref = on
	end
	return true, nil
end

-- CRIMES ---------------------------------------------------------------------------------------------------------------

-- Witness check for a crime at pos (pedestrians / officers with line of sight via NPCService; cruisers via
-- PoliceService). gunshot: cops hear shots within GUNFIRE_HEAR_RADIUS.
local function witnessed(pos: Vector3, gunshot: boolean): boolean
	local ok, res = call("NPCService", "witnessesNear", pos, Police.WITNESS_PED_RADIUS)
	if ok and res == true then
		return true
	end
	local okC, near = call(
		"PoliceService",
		"copsNear",
		pos,
		if gunshot then Police.GUNFIRE_HEAR_RADIUS else Police.WITNESS_COP_RADIUS
	)
	return okC and near == true
end

-- Reports a crime by `player` at `pos`. Returns the new star count (or nil when nothing happened).
function DamageService.reportCrime(player: Player, crime: CrimeRules.Crime, pos: Vector3?, force: boolean?): number?
	local st = getState(player)
	local now = hooks.clock()
	local cooldown = DamageService.CRIME_COOLDOWN[crime] or DamageService.DEFAULT_CRIME_COOLDOWN
	if not force and now - (st.lastCrime[crime] or -math.huge) < cooldown then
		return nil
	end
	st.lastCrime[crime] = now
	local where = pos
	if where == nil then
		local r = rootOf(player)
		where = if r then r.Position else nil
	end
	if not force and where and not witnessed(where, crime == "gunfire") then
		return nil
	end
	if crime ~= "pedHit" and crime ~= "pedDown" then
		st.pedOnly = false
	end
	local current = wantedOf(player)
	if current == 0 then
		st.pedOnly = crime == "pedHit" or crime == "pedDown"
		st.copsDowned = 0
	end
	if crime == "copDown" then
		st.copsDowned += 1
	end
	local target = CrimeRules.starsAfter(current, crime, st.copsDowned, st.pedOnly)
	local ok, res = call("WantedService", "raiseTo", player, target, crime, where)
	if ok and typeof(res) == "number" then
		return res
	end
	return target
end

-- PLAYER DAMAGE --------------------------------------------------------------------------------------------------------

local function victimContext(attacker: Player, victim: Player): (boolean, any)
	local ok, car = call("VehicleService", "getDriving", victim)
	local victimCar = if ok then car else nil
	local stealing = false
	if victimCar and victimCar.kind == "Stolen" then
		local theft = victimCar.data and victimCar.data.theft
		if typeof(theft) == "table" then
			local v = theft.victim
			stealing = v == attacker or v == attacker.UserId
		end
	end
	return stealing, victimCar
end

local function onPlayerHitPlayer(attacker: Player, victim: Player, info: DamageInfo, killed: boolean)
	markCombat(attacker)
	markCombat(victim)
	local as = getState(attacker)
	if as.rookie then
		DamageService.endRookie(attacker, "you attacked a player")
	end
	local stealing, victimCar = victimContext(attacker, victim)
	local victimWanted = wantedOf(victim)
	local attackerRoot, victimRoot = rootOf(attacker), rootOf(victim)
	local plot = attacker:GetAttribute("PlotIndex")
	local heat = CrimeRules.shouldAddAssaultHeat({
		attackerInOwnGarage = DamageService.safeZoneKind(attacker) == "garage",
		victimInAttackerGarage = typeof(plot) == "number" and victimRoot ~= nil and MapLayout.plotAt(
			victimRoot.Position
		) == plot,
		victimStealingFromAttacker = stealing,
		victimWanted = victimWanted,
	})
	-- TheftService records the hit (revenge bonus / knockout feed) before anything drops the car
	call("TheftService", "onThiefHit", attacker, victim)
	if heat then
		DamageService.reportCrime(
			attacker,
			if killed then "pvpDown" else "assault",
			if attackerRoot then attackerRoot.Position else nil,
			killed
		)
	end
	if killed and victimCar and CrimeRules.countsAsThiefBonk(victimCar.kind, victimWanted) then
		call("RewardsService", "progress", attacker, "defend", 1)
	end
	DamageService.PlayerHit:Fire(attacker, victim, info)
end

-- Applies damage to a player. The caller already validated the shot / swing (WeaponService) or police fire
-- (PoliceCombatService); this still enforces protection for player sources.
function DamageService.applyDamage(victim: Player, info: DamageInfo): HitResult
	local st = states[victim]
	if not st or st.dead then
		return { applied = false, healthTaken = 0, armorTaken = 0, killed = false, reason = "dead" }
	end
	local source = info.source
	if source then
		local ok, why = DamageService.canDamage(source, victim)
		if not ok then
			return { applied = false, healthTaken = 0, armorTaken = 0, killed = false, reason = why }
		end
	elseif st.god then
		return { applied = false, healthTaken = 0, armorTaken = 0, killed = false, reason = "god" }
	end
	local raw = math.max(0, info.amount)
	if raw <= 0 then
		return { applied = false, healthTaken = 0, armorTaken = 0, killed = false, reason = "zero" }
	end
	local now = hooks.clock()
	local newHealth, newArmor, healthTaken, armorTaken = DamageModel.apply(st.health, st.armor, raw)
	st.health = newHealth
	if newArmor ~= st.armor then
		st.armor = newArmor
		publishArmor(st)
	end
	st.lastDamageAt = now
	st.lastDamage = info
	st.medkitUntil = 0 -- taking damage interrupts a med kit
	if not st.mercyUsed and st.health > 0 and st.health < Police.MERCY_HEALTH then
		st.mercyUsed = true
		st.mercyUntil = now + Police.MERCY_TIME
	end
	local killed = st.health <= 0
	writeHumanoid(st)
	pcall(hooks.fireClient, "DamageTaken", victim, info.from, healthTaken + armorTaken)
	if source then
		local kind = if killed
			then "down"
			elseif armorTaken > 0 and healthTaken <= 0 then "armor"
			elseif info.part == "Head" then "head"
			else "body"
		pcall(hooks.fireClient, "HitConfirm", source, kind, info.position or Vector3.zero)
		onPlayerHitPlayer(source, victim, info, killed)
	end
	DamageService.Damaged:Fire(victim, healthTaken, armorTaken, info)
	if killed then
		local hum = st.humanoid
		if hum and hum.Parent then
			st.writing = true
			pcall(function()
				hum.Health = 0
			end)
			st.writing = false
		end
	end
	return { applied = true, healthTaken = healthTaken, armorTaken = armorTaken, killed = killed, reason = nil }
end

-- NPC damage (pedestrians / officers): NPCService owns their health; crimes and the shooter's hit marker live here.
function DamageService.applyNpcDamage(model: Model, info: DamageInfo): HitResult
	local ok, res = call("NPCService", "damage", model, info.amount, info.source, info)
	if not ok or typeof(res) ~= "table" or not res.applied then
		return { applied = false, healthTaken = 0, armorTaken = 0, killed = false, reason = "npc" }
	end
	local source = info.source
	if source then
		local killed = res.killed == true
		local kind = if killed then "down" elseif info.part == "Head" then "head" else "body"
		pcall(hooks.fireClient, "HitConfirm", source, kind, info.position or Vector3.zero)
		local crime: CrimeRules.Crime
		if res.kind == "officer" then
			crime = if killed then "copDown" else "copShot"
			markCombat(source)
		else
			crime = if killed then "pedDown" else "pedHit"
		end
		DamageService.reportCrime(source, crime, info.position, true)
		if killed and res.kind == "officer" then
			call("PoliceCombatService", "onOfficerDowned", model, source)
		end
	end
	return { applied = true, healthTaken = res.taken or 0, armorTaken = 0, killed = res.killed == true, reason = nil }
end

-- DEATH ----------------------------------------------------------------------------------------------------------------

-- §7.1 for this player right now.
function DamageService.classifyDeath(player: Player, pos: Vector3?): DamageModel.DeathKind
	local st = states[player]
	local plot = player:GetAttribute("PlotIndex")
	local inOwnGarage = pos ~= nil and typeof(plot) == "number" and MapLayout.plotAt(pos) == plot
	return DamageModel.classifyDeath(if st then st.lastDamageAt else nil, hooks.clock(), wantedOf(player), inOwnGarage)
end

local function downedText(info: DamageInfo?): (string?, boolean)
	if not info then
		return nil, false
	end
	if info.police then
		return "the police", true
	end
	local src = info.source
	if src then
		return src.DisplayName, false
	end
	return nil, false
end

local function payBounty(killer: Player, victim: Player, vs: PState)
	local now = hooks.clock()
	if not CrimeRules.bountyPairReady(vs.bountyPaid[killer.UserId], now) then
		return
	end
	local data = getData(victim)
	if not data then
		return
	end
	local amount = CrimeRules.bounty(wantedOf(victim), data.cash or 0, incomeOf(victim))
	if DamageService.isMenace(victim) then
		amount = math.max(amount, CrimeRules.bounty(4, data.cash or 0, incomeOf(victim)))
	end
	if amount <= 0 then
		return
	end
	local okSpend, spent = call("DataService", "spendCash", victim, amount)
	if not okSpend or spent ~= true then
		return
	end
	vs.bountyPaid[killer.UserId] = now
	call("DataService", "addCash", killer, amount, "bounty")
	local kd = getData(killer)
	if kd and typeof(kd.stats) == "table" then
		kd.stats.bountiesClaimed = (tonumber(kd.stats.bountiesClaimed) or 0) + 1
	end
	notify(killer, "money", ("Bounty claimed: $%d"):format(amount), 4)
	notify(victim, "warning", ("Your bounty was claimed: -$%d"):format(amount), 4)
end

local function onKilledBy(killer: Player, victim: Player)
	local ks = getState(killer)
	local vs = getState(victim)
	local now = hooks.clock()
	local victimWanted = wantedOf(victim)
	-- revenge immunity: two downs by the same attacker within 3 min
	local list = vs.downedBy[killer.UserId] or {}
	table.insert(list, now)
	vs.downedBy[killer.UserId] = list
	if CrimeRules.revengeTriggered(list, now) then
		vs.immuneFrom[killer.UserId] = now + CrimeRules.REVENGE_TIME
		table.clear(list)
		notify(
			victim,
			"info",
			("%s can't hurt you for 5 minutes. Passive mode is available now."):format(killer.DisplayName),
			5
		)
	end
	-- bounty (4+ stars or Menace), paid by the victim
	if victimWanted >= 4 or DamageService.isMenace(victim) then
		payBounty(killer, victim, vs)
	end
	-- menace: downing non-wanted players
	if victimWanted <= 0 then
		table.insert(ks.downHistory, { t = now, rookie = vs.rookie or vs.passive })
		if CrimeRules.isMenace(ks.downHistory, now) then
			ks.menaceOffences += 1
			local dur = if ks.menaceOffences > 1 then CrimeRules.MENACE_REPEAT_TIME else CrimeRules.MENACE_TIME
			ks.menaceUntil = now + dur
			setAttr(killer, "Menace", true)
			table.clear(ks.downHistory)
			call("WantedService", "raiseTo", killer, Police.MIN_STARS.menace, "menace", nil)
			notify(killer, "warning", "You are a MENACE: police and bounty hunters are after you.", 5)
		end
	end
end

local function chargeHospital(player: Player, st: PState, info: DamageInfo?): number
	local data = getData(player)
	if not data then
		return 0
	end
	local free = st.rookie or info == nil
	local bill = DamageModel.hospitalBill(
		data.cash or 0,
		incomeOf(player),
		Economy.HOSPITAL_BILL_FRACTION,
		Economy.HOSPITAL_BILL_MAX_SECONDS,
		free
	)
	if bill > 0 then
		local ok, paid = call("DataService", "spendCash", player, bill)
		if not ok or paid ~= true then
			bill = 0
		end
	end
	if typeof(data.stats) == "table" then
		data.stats.wasted = (tonumber(data.stats.wasted) or 0) + 1
	end
	markDirty(player)
	return bill
end

local function onDied(player: Player, character: Model)
	local st = getState(player)
	if st.dead then
		return
	end
	st.dead = true
	st.health = 0
	local root = character:FindFirstChild("HumanoidRootPart")
	local pos = if root and root:IsA("BasePart") then root.Position else nil
	local kind = DamageService.classifyDeath(player, pos)
	local info = if st.lastDamageAt and hooks.clock() - st.lastDamageAt <= DamageModel.WASTED_WINDOW
		then st.lastDamage
		else nil
	-- ragdoll the body (joints intact; the engine never breaks them: BreakJointsOnDeath = false)
	pcall(Ragdoll.enable, character)
	if kind == "busted" then
		call("WantedService", "bust", player, "died")
		DamageService.Downed:Fire(player, info, kind)
		return
	end
	-- WASTED
	call("WantedService", "clearOnWasted", player)
	st.armor = 0
	publishArmor(st)
	local by, police = downedText(info)
	local bill = chargeHospital(player, st, info)
	local hospitalCF, hospitalName = MapLayout.hospitalCFrame(pos)
	st.hospital = hospitalCF
	st.hospitalAt = hooks.clock()
	st.hospitalName = hospitalName
	pcall(hooks.fireClient, "Wasted", player, { by = by, police = police, bill = bill, hospital = hospitalName })
	local killer = info and info.source
	if killer and killer.Parent then
		onKilledBy(killer, player)
	end
	DamageService.Downed:Fire(player, info, kind)
end

-- True once after a WASTED death: PlotService spawns that character at the returned hospital CFrame.
function DamageService.consumeHospitalRespawn(player: Player): CFrame?
	local st = states[player]
	if not st or not st.hospital then
		return nil
	end
	local cf = st.hospital
	st.hospital = nil
	if hooks.clock() - st.hospitalAt > DamageService.HOSPITAL_PENDING_WINDOW then
		return nil
	end
	return cf
end

-- CHARACTER LIFECYCLE ----------------------------------------------------------------------------------------------------

local function disconnectAll(st: PState)
	for _, c in st.conns do
		c:Disconnect()
	end
	table.clear(st.conns)
end

local function onCharacter(player: Player, character: Model)
	local st = getState(player)
	disconnectAll(st)
	local now = hooks.clock()
	st.dead = false
	st.health = DamageModel.MAX_HEALTH
	st.lastDamageAt = nil
	st.lastDamage = nil
	st.spawnAt = now
	st.firedSinceSpawn = false
	st.protectedUntil = now + DamageService.SPAWN_PROTECTION
	st.mercyUsed = false
	st.mercyUntil = 0
	st.medkitUntil = 0
	setAttr(player, "Protected", hooks.serverNow() + DamageService.SPAWN_PROTECTION)
	-- the default Health script regenerates 1 %/s: the server owns health
	local healthScript = character:FindFirstChild("Health")
	if healthScript and healthScript:IsA("Script") then
		healthScript:Destroy()
	end
	table.insert(
		st.conns,
		character.ChildAdded:Connect(function(child)
			if child.Name == "Health" and child:IsA("Script") then
				child:Destroy()
			end
		end)
	)
	local hum = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
	if not hum or not hum:IsA("Humanoid") or player.Character ~= character then
		return
	end
	st.humanoid = hum
	pcall(function()
		hum.BreakJointsOnDeath = false
		hum.RequiresNeck = false
	end)
	writeHumanoid(st)
	table.insert(
		st.conns,
		hum.HealthChanged:Connect(function(h: number)
			if st.writing or st.dead or hum ~= st.humanoid then
				return
			end
			if h > st.health + 0.5 then
				writeHumanoid(st) -- nothing heals but us
			elseif h < st.health - 0.5 then
				-- an unexplained drop (fall, water, reset): adopt it as world damage
				st.health = math.max(0, math.floor(h))
				st.lastDamageAt = hooks.clock()
				st.lastDamage = { amount = 0 }
			end
		end)
	)
	table.insert(
		st.conns,
		hum.Died:Connect(function()
			local ok, err = pcall(onDied, player, character)
			if not ok then
				warn("[DamageService] death handling failed: " .. tostring(err))
			end
		end)
	)
end

local function loadFromData(player: Player)
	local st = getState(player)
	local data = getData(player)
	if not data then
		return
	end
	st.armor = math.clamp(tonumber(data.armor) or 0, 0, DamageModel.MAX_ARMOR)
	publishArmor(st)
	local combat = data.combat
	local rookieSeconds = if typeof(combat) == "table" then tonumber(combat.rookieSeconds) or 0 else 0
	st.rookieSeconds = rookieSeconds
	setRookie(st, rookieSeconds > 0)
end

-- PERIODIC -------------------------------------------------------------------------------------------------------------

local function tickPlayer(player: Player, st: PState, dt: number)
	local now = hooks.clock()
	-- In Combat flag
	if st.combatUntil > 0 and now >= st.combatUntil then
		st.combatUntil = 0
		setAttr(player, "InCombat", false)
	end
	-- safe zones
	local root = rootOf(player)
	if root then
		local zone = MapLayout.safeZoneAt(root.Position)
		local kind = if zone then zone.kind else nil
		local plot = if zone then zone.plotIndex else nil
		if kind ~= st.safeKind or plot ~= st.safePlot then
			st.safeKind = kind
			st.safePlot = plot
			st.safeSince = now
		end
		local shown = DamageService.safeZoneKind(player)
		setAttr(player, "SafeZone", shown or "")
		if shown and shown ~= "garage" then
			call("WeaponService", "holsterGuns", player)
		end
	end
	-- rookie countdown (persisted)
	if st.rookie then
		st.rookieSeconds -= dt
		local data = getData(player)
		if data and typeof(data.combat) == "table" then
			data.combat.rookieSeconds = math.max(0, st.rookieSeconds)
		end
		if st.rookieSeconds <= 0 then
			setRookie(st, false)
			notify(player, "info", "Rookie protection is over. Watch your back.", 4)
		end
	end
	-- menace expiry
	if st.menaceUntil > 0 and now >= st.menaceUntil then
		st.menaceUntil = 0
		setAttr(player, "Menace", false)
	end
	-- bounty display (4+ stars)
	local bounty = 0
	local w = wantedOf(player)
	if w >= 4 or now < st.menaceUntil then
		local data = getData(player)
		if data then
			bounty = CrimeRules.bounty(math.max(w, 4), data.cash or 0, incomeOf(player))
		end
	end
	setAttr(player, "Bounty", bounty)
	-- healing
	if st.dead or st.health <= 0 then
		return
	end
	local before = st.health
	if now < st.medkitUntil then
		st.health = math.min(DamageModel.MAX_HEALTH, st.health + st.medkitRate * dt)
	end
	local since = if st.lastDamageAt then now - st.lastDamageAt else math.huge
	local inGarage = DamageService.safeZoneKind(player) == "garage" and now >= st.combatUntil
	st.health = DamageModel.regen(st.health, since, dt, inGarage)
	if math.floor(st.health) ~= math.floor(before) then
		writeHumanoid(st)
	end
end

function DamageService._tick(dt: number)
	for player, st in states do
		local ok, err = pcall(tickPlayer, player, st, dt)
		if not ok then
			warn("[DamageService] tick failed: " .. tostring(err))
		end
	end
end

-- MED KITS -------------------------------------------------------------------------------------------------------------

function DamageService.useMedKit(player: Player): (boolean, string?)
	local st = states[player]
	if not st or st.dead then
		return false, "dead"
	end
	local now = hooks.clock()
	local def = Weapons.MedKit
	if st.lastDamageAt and now - st.lastDamageAt < def.damageLock then
		return false, "Can't patch up under fire."
	end
	if st.health >= DamageModel.MAX_HEALTH then
		return false, "You're already at full health."
	end
	local data = getData(player)
	if not data or (tonumber(data.medkits) or 0) <= 0 then
		return false, "No med kits. Buy them at a gun store."
	end
	data.medkits -= 1
	markDirty(player)
	st.medkitUntil = now + def.duration
	st.medkitRate = def.heal / def.duration
	call("WeaponService", "pushState", player)
	return true, nil
end

-- LIFECYCLE ------------------------------------------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	getState(player)
	setAttr(player, "Armor", 0)
	setAttr(player, "InCombat", false)
	setAttr(player, "Passive", false)
	setAttr(player, "Menace", false)
	setAttr(player, "Bounty", 0)
	setAttr(player, "SafeZone", "")
	player.CharacterAdded:Connect(function(character: Model)
		onCharacter(player, character)
	end)
	if player.Character then
		task.spawn(onCharacter, player, player.Character)
	end
	local ok, loaded = call("DataService", "isLoaded", player)
	if ok and loaded == true then
		loadFromData(player)
	end
end

local function onPlayerRemoving(player: Player)
	local st = states[player]
	if st then
		disconnectAll(st)
		local data = getData(player)
		if data then
			data.armor = st.armor
		end
	end
	states[player] = nil
end

function DamageService._addPlayer(player: Player)
	getState(player)
end

function DamageService._removePlayer(player: Player)
	states[player] = nil
end

function DamageService.init()
	pcall(function()
		Players.RespawnTime = DamageService.RESPAWN_TIME
	end)
	Net.on("SetPassive", function(player: Player, on: any)
		if typeof(on) ~= "boolean" then
			return
		end
		local ok, why = DamageService.setPassive(player, on)
		if not ok and why then
			notify(player, "error", why, 3)
		elseif ok then
			notify(player, "info", if on then "Passive mode on." else "Passive mode off. Weapons locked for 10 s.", 3)
		end
	end, 2)
	Net.on("UseMedKit", function(player: Player)
		local ok, why = DamageService.useMedKit(player)
		if not ok and why and why ~= "dead" then
			notify(player, "error", why, 2)
		end
	end, 3)
end

function DamageService.start()
	local DataService = sys("DataService")
	if DataService and DataService.Loaded then
		DataService.Loaded:Connect(function(player: Player)
			loadFromData(player)
		end)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayerAdded, p)
	end
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < DamageService.TICK then
			return
		end
		local step = acc
		acc = 0
		DamageService._tick(step)
	end)
end

return DamageService
