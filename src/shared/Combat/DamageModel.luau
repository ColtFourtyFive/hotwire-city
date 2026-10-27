--!strict
-- DamageModel (gta_combat §4.2-4.3, §6, §7.1): pure health / armor math. DamageService (server) owns the numbers at
-- runtime; this module only decides.
--
--   raw         = dmg * partMult * falloff(d) * (occupant and 0.7 or 1)
--   armorTaken  = min(armor, raw)            -- armor absorbs 100 % first (GTA)
--   healthTaken = raw - armorTaken
--   regen       : after 6 s without damage, +4 HP/s up to 50 (never above 50); own garage: +25 HP/s to 100 after 3 s
-- Results are floored to integers at the end so the HUD never shows fractions.

local Weapons = require(script.Parent.Parent.Config.Weapons)
local Ballistics = require(script.Parent.Ballistics)

type WeaponDef = Weapons.WeaponDef

local DamageModel = {}

DamageModel.MAX_HEALTH = 100
DamageModel.MAX_ARMOR = 100
DamageModel.REGEN_DELAY = 6
DamageModel.REGEN_RATE = 4
DamageModel.REGEN_CAP = 50
DamageModel.GARAGE_DELAY = 3
DamageModel.GARAGE_RATE = 25
DamageModel.WASTED_WINDOW = 10 -- a death within this long of taking damage is WASTED, whatever the wanted level
DamageModel.LIMB_MULT = 0.75

export type PartClass = "head" | "torso" | "limb"

local HEAD: { [string]: boolean } = { Head = true }
local TORSO: { [string]: boolean } = {
	HumanoidRootPart = true,
	UpperTorso = true,
	LowerTorso = true,
	Torso = true,
}

function DamageModel.partClass(partName: string): PartClass
	if HEAD[partName] then
		return "head"
	end
	if TORSO[partName] then
		return "torso"
	end
	return "limb" -- arms, legs, hands, feet (and anything unknown: accessories count as limbs)
end

-- Body-part multiplier for a weapon. Shotgun pellets never get a head bonus (headMult 1.0 in the config).
function DamageModel.partMultiplier(def: WeaponDef, partName: string): number
	local class = DamageModel.partClass(partName)
	if class == "head" then
		return def.headMult
	elseif class == "torso" then
		return 1
	end
	return def.limbMult
end

-- Raw damage of ONE bullet / pellet / swing before armor (not floored: pellets are summed first).
function DamageModel.raw(def: WeaponDef, partName: string, distance: number, occupant: boolean?): number
	local dmg = def.damage * DamageModel.partMultiplier(def, partName)
	if def.class ~= "Melee" then
		dmg *= Ballistics.falloff(def, distance)
	end
	if occupant then
		dmg *= Weapons.OCCUPANT_MULT
	end
	return math.max(0, dmg)
end

-- Armor split. Returns (armorTaken, healthTaken), both >= 0, unfloored.
function DamageModel.split(armor: number, raw: number): (number, number)
	raw = math.max(0, raw)
	local a = math.min(math.max(0, armor), raw)
	return a, raw - a
end

-- Applies raw damage to (health, armor). Returns newHealth, newArmor, healthTaken, armorTaken (all integers).
function DamageModel.apply(health: number, armor: number, raw: number): (number, number, number, number)
	local armorTaken, healthTaken = DamageModel.split(armor, raw)
	local newArmor = math.max(0, math.floor(armor - armorTaken + 1e-6))
	local newHealth = math.max(0, math.floor(health - healthTaken + 1e-6))
	-- whole numbers only: a hit that took 0.4 HP still costs nothing visible, a lethal hit always lands on 0
	if health - healthTaken <= 0 then
		newHealth = 0
	end
	return newHealth, newArmor, health - newHealth, armor - newArmor
end

-- Health regeneration step. sinceDamage = seconds since the last damage; inGarage = own garage heal rule active
-- (already gated by "not in combat" by the caller).
function DamageModel.regen(health: number, sinceDamage: number, dt: number, inGarage: boolean): number
	if health <= 0 then
		return health
	end
	if inGarage and sinceDamage >= DamageModel.GARAGE_DELAY then
		return math.min(DamageModel.MAX_HEALTH, health + DamageModel.GARAGE_RATE * dt)
	end
	if sinceDamage < DamageModel.REGEN_DELAY or health >= DamageModel.REGEN_CAP then
		return health
	end
	return math.min(DamageModel.REGEN_CAP, health + DamageModel.REGEN_RATE * dt)
end

export type DeathKind = "wasted" | "busted"

-- §7.1 death classification. lastDamageAt = server clock of the last damage taken (nil = never).
function DamageModel.classifyDeath(lastDamageAt: number?, now: number, wanted: number, inOwnGarage: boolean): DeathKind
	if lastDamageAt ~= nil and now - lastDamageAt <= DamageModel.WASTED_WINDOW then
		return "wasted"
	end
	if wanted > 0 and not inOwnGarage then
		return "busted"
	end
	return "wasted"
end

-- Hospital bill: min(5 % of cash, 120 s of income); free for rookies and for deaths nobody caused.
function DamageModel.hospitalBill(
	cash: number,
	incomePerSec: number,
	fraction: number,
	maxSeconds: number,
	free: boolean
): number
	if free then
		return 0
	end
	cash = math.max(0, cash)
	incomePerSec = math.max(0, incomePerSec)
	return math.max(0, math.floor(math.min(cash * fraction, incomePerSec * maxSeconds)))
end

return DamageModel
