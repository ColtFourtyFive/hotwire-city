--!strict
-- CrimeRules (gta_combat §8, §9.5): pure "what does this crime cost" decisions. Absorbs v1 CombatService's
-- shouldAddAssaultHeat / countsAsThiefBonk (CombatService re-exports them so v1 callers and tests keep working).
--
-- Heat model: a crime has an ADD (stars added) and an optional FLOOR (GTA's "puts you at least at N stars").
--   newStars = clamp(max(current + add, floor), 0, 5); pedestrian crimes alone never pass PED_HEAT_CAP.
-- Witnessed: a pedestrian within 60 studs or a cop within 120 studs with line of sight (NPCService.witnessesNear).
-- Unwitnessed crimes (and vigilante / defense hits) cost nothing.

local Police = require(script.Parent.Parent.Config.Police)
local Economy = require(script.Parent.Parent.Config.Economy)

local CrimeRules = {}

export type AssaultContext = {
	attackerInOwnGarage: boolean, -- defending your own garage is never a crime
	victimInAttackerGarage: boolean, -- a raider inside your garage
	victimStealingFromAttacker: boolean, -- the victim is driving off with your car
	victimWanted: number, -- stars; hitting wanted criminals is vigilante justice, not assault
}

export type Crime =
	"gunfire"
	| "brandish"
	| "pedHit"
	| "pedDown"
	| "copShot"
	| "copDown"
	| "heliHit"
	| "heliDown"
	| "assault"
	| "pvpDown"

-- v1 rule, now for every weapon: hitting a player outside your own garage is assault unless the victim is stealing
-- from you, raiding your garage, or wanted.
function CrimeRules.shouldAddAssaultHeat(ctx: AssaultContext): boolean
	if ctx.attackerInOwnGarage or ctx.victimInAttackerGarage then
		return false
	end
	if ctx.victimStealingFromAttacker then
		return false
	end
	return ctx.victimWanted <= 0
end

-- Daily contract "defend" (bonk3): a hit that ejects / downs the driver of a Stolen car, or of a Loot car while that
-- driver is wanted (>= 1 star), counts, whoever the attacker is.
function CrimeRules.countsAsThiefBonk(carKind: any, victimWanted: number): boolean
	if carKind == "Stolen" then
		return true
	end
	return carKind == "Loot" and victimWanted >= 1
end

-- New star count after a crime. copsDowned = officers this suspect has downed this chase (including this one) for
-- copDown escalation; pedOnly = the chase so far has only pedestrian crimes (cap at PED_HEAT_CAP).
function CrimeRules.starsAfter(current: number, crime: Crime, copsDowned: number?, pedOnly: boolean?): number
	local add = (Police.Heat :: any)[crime] or 0
	local floor = (Police.MIN_STARS :: any)[crime] or 0
	local stars: number
	if crime == "copDown" then
		-- min 3, +1 for every COPS_DOWNED_PER_EXTRA_STAR more officers downed
		local extra = math.floor(math.max(0, (copsDowned or 1) - 1) / Police.COPS_DOWNED_PER_EXTRA_STAR)
		stars = math.max(current, floor + extra)
	elseif crime == "gunfire" or crime == "brandish" then
		-- floors only: firing in public makes you wanted, it doesn't keep stacking stars per shot
		stars = math.max(current, floor)
		if crime == "brandish" and current >= 1 then
			stars = math.max(current, 2)
		end
	else
		stars = math.max(current + add, floor)
	end
	if (crime == "pedHit" or crime == "pedDown") and pedOnly then
		stars = math.min(stars, math.max(current, Police.PED_HEAT_CAP))
	end
	return math.clamp(stars, 0, Police.MAX_STARS)
end

-- MENACE (anti-grief, §8): downing MENACE_DOWNS non-wanted players within MENACE_WINDOW, or MENACE_ROOKIE_DOWNS
-- rookies / passive-adjacent targets.
CrimeRules.MENACE_DOWNS = 3
CrimeRules.MENACE_ROOKIE_DOWNS = 2
CrimeRules.MENACE_WINDOW = 300
CrimeRules.MENACE_TIME = 300
CrimeRules.MENACE_REPEAT_TIME = 600

export type DownRecord = { t: number, rookie: boolean }

-- Prunes `history` (in place) to the window and returns whether the attacker is now a Menace.
function CrimeRules.isMenace(history: { DownRecord }, now: number): boolean
	local i = 1
	while i <= #history do
		if now - history[i].t > CrimeRules.MENACE_WINDOW then
			table.remove(history, i)
		else
			i += 1
		end
	end
	local downs, rookies = 0, 0
	for _, r in history do
		downs += 1
		if r.rookie then
			rookies += 1
		end
	end
	return downs >= CrimeRules.MENACE_DOWNS or rookies >= CrimeRules.MENACE_ROOKIE_DOWNS
end

-- REVENGE IMMUNITY: the same attacker downing you twice within 3 min can't damage you for 5 min.
CrimeRules.REVENGE_DOWNS = 2
CrimeRules.REVENGE_WINDOW = 180
CrimeRules.REVENGE_TIME = 300

function CrimeRules.revengeTriggered(downTimes: { number }, now: number): boolean
	local n = 0
	for _, t in downTimes do
		if now - t <= CrimeRules.REVENGE_WINDOW then
			n += 1
		end
	end
	return n >= CrimeRules.REVENGE_DOWNS
end

-- BOUNTY (zero-sum, §8): 4+ stars carry min(10 % of cash, stars x 20 s of income), paid from the target's own cash.
function CrimeRules.bounty(stars: number, cash: number, incomePerSec: number): number
	if stars < 4 then
		return 0
	end
	local byCash = math.max(0, cash) * Economy.BOUNTY_CASH_FRACTION
	local byIncome = stars * Economy.BOUNTY_INCOME_SECONDS_PER_STAR * math.max(0, incomePerSec)
	return math.max(0, math.floor(math.min(byCash, byIncome)))
end

-- A (killer, target) pair pays at most once per BOUNTY_PAIR_COOLDOWN.
function CrimeRules.bountyPairReady(lastPaidAt: number?, now: number): boolean
	return lastPaidAt == nil or now - lastPaidAt >= Economy.BOUNTY_PAIR_COOLDOWN
end

-- WITNESSES ------------------------------------------------------------------------------------------------------------
-- Is a crime at `pos` witnessed? peds / cops = positions of pedestrians / officers (or cruisers) that have line of
-- sight (the caller filters LOS); `heardByCop` = a cop within GUNFIRE_HEAR_RADIUS (gunshots are loud).
function CrimeRules.witnessed(pos: Vector3, peds: { Vector3 }, cops: { Vector3 }, gunshot: boolean): boolean
	for _, p in peds do
		if (p - pos).Magnitude <= Police.WITNESS_PED_RADIUS then
			return true
		end
	end
	local copRadius = if gunshot
		then math.max(Police.WITNESS_COP_RADIUS, Police.GUNFIRE_HEAR_RADIUS)
		else Police.WITNESS_COP_RADIUS
	for _, p in cops do
		if (p - pos).Magnitude <= copRadius then
			return true
		end
	end
	return false
end

return CrimeRules
