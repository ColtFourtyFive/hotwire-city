--!strict
-- Types that cross the client/server boundary or are shared between systems.

local Rarity = require(script.Parent.Config.Rarity)

export type MutationId = Rarity.MutationId
export type RarityId = Rarity.RarityId

-- One car parked in a garage slot (persisted).
export type SlotRecord = {
	carId: string,
	mutation: MutationId,
	uncollected: number, -- cash accumulated in this slot, collected at the Collect pad
}

-- Runtime-only slot state (never persisted; sent in snapshots).
export type SlotState = "Parked" | "BeingStolen" | "Driving"

export type UpgradeLevels = { lock: number, hotwire: number, nitro: number, armor: number }

-- Persisted player profile. Bump DataService schema version + add a migration when changing this.
export type PlayerData = {
	version: number,
	cash: number,
	totalEarned: number,
	rebirths: number,
	slotsUnlocked: number,
	garage: { [string]: SlotRecord }, -- key = tostring(slotIndex)
	discovered: { [string]: boolean }, -- carId -> true
	upgrades: UpgradeLevels,
	tools: { [string]: boolean }, -- toolId -> owned (v2: gadgets taser / spikes; "bat" kept for old saves)
	stats: Stats,
	-- schema v2 (combat, gta_combat §13.2): additive
	weapons: { [string]: WeaponRecord }, -- weaponId -> owned record (Config/Weapons); fists are implicit
	tintsOwned: { [string]: boolean }, -- weapon tints bought (once per account; any weapon can wear them)
	armor: number, -- 0..100, consumable (lost on WASTED / BUSTED)
	medkits: number, -- 0..MedKit.carry
	combat: CombatPrefs,
	daily: { streak: number, lastClaimDay: number },
	codes: { [string]: boolean },
	receipts: { string }, -- last N processed purchase ids (idempotency)
	lastOnline: number,
	tutorialDone: boolean,
	settings: Settings,
	exclusives: { [string]: boolean }, -- exclusive cars granted by Robux (re-grantable)
	contracts: ContractState,
	referralRewarded: boolean,
	referralsPaid: { day: number, count: number }?, -- inviter-side referral payouts per UTC day (anti-farm)
	playtime: { day: number, seconds: number, claimed: { [string]: boolean } }, -- per-UTC-day playtime gifts
	pendingCars: { { carId: string, mutation: MutationId } }?, -- reward cars owed while a heist blocked delivery (RewardsService validates on read)
}

export type Stats = {
	steals: number,
	playerSteals: number,
	busted: number,
	hotDrops: number,
	timesRobbed: number,
	wasted: number?, -- v2
	bountiesClaimed: number?, -- v2
}

-- v2 weapon ownership: total rounds (magazine + reserve) and the cosmetic tint.
export type WeaponRecord = { ammo: number, tint: string? }

-- v2 PvP preferences / protection that persist (rookie protection counts down over total playtime).
export type CombatPrefs = { rookieSeconds: number, passivePref: boolean }

-- Daily contracts: rolled once per UTC day.
export type ContractState = {
	day: number,
	list: { { id: string, progress: number, claimed: boolean } },
	rerolled: boolean?, -- used today's free swap
}

-- What the client receives (DataSnapshot remote). Superset of what UI needs; never trust it server-side.
export type SlotSnapshot = {
	carId: string,
	mutation: MutationId,
	uncollected: number,
	state: SlotState,
	income: number, -- effective $/s of this slot (after multipliers)
}

export type Snapshot = {
	cash: number,
	totalEarned: number,
	rebirths: number,
	slotsUnlocked: number,
	maxSlots: number, -- includes gamepass slots
	garage: { [string]: SlotSnapshot },
	discovered: { [string]: boolean },
	upgrades: UpgradeLevels,
	tools: { [string]: boolean },
	stats: Stats,
	weapons: { [string]: WeaponRecord }?, -- v2 (live magazine / reserve split comes from AmmoState / CombatState)
	tintsOwned: { [string]: boolean }?,
	armor: number?,
	medkits: number?,
	daily: { streak: number, canClaim: boolean, nextDay: number }, -- nextDay = 1..7 reward index to claim
	playtime: { claimed: { [string]: boolean }, sessionSeconds: number },
	incomePerSec: number,
	multiplier: number,
	passes: { [string]: boolean },
	plotIndex: number?,
	tutorialDone: boolean,
	settings: Settings,
	contracts: ContractState,
}

export type Settings = { music: boolean, sfx: boolean, hideHud: boolean, autoAccelerate: boolean, speedo: boolean }

-- CombatState remote payload (WeaponService -> owning client).
export type AmmoView = { id: string, mag: number, reserve: number, tint: string? }
export type CombatState = {
	weapons: { AmmoView }, -- owned weapons (fists first)
	gadgets: { string }, -- owned gadget tool ids (taser, spikes)
	equipped: string?,
	armor: number,
	medkits: number,
}

-- Notify remote payload kinds
export type NotifyKind = "info" | "success" | "error" | "money" | "warning"

-- Vehicle kinds tracked by VehicleService
export type VehicleKind =
	"Parked" -- street parked, stealable
	| "Traffic" -- AI traffic, carjackable
	| "Owned" -- a player's own car taken out of their garage for a drive
	| "Stolen" -- stolen from another player's garage, must be delivered
	| "Loot" -- any non-owned car a player is driving that can be delivered (street/traffic/dealer/hot drop)
	| "Dealership" -- on a showroom pad (anchored display, not drivable until stolen)
	| "HotDrop" -- server event car waiting to be claimed
	| "Police"

return {}
