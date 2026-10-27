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
	tools: { [string]: boolean }, -- toolId -> owned
	stats: { steals: number, playerSteals: number, busted: number, hotDrops: number, timesRobbed: number },
	daily: { streak: number, lastClaimDay: number },
	codes: { [string]: boolean },
	receipts: { string }, -- last N processed purchase ids (idempotency)
	lastOnline: number,
	tutorialDone: boolean,
	settings: Settings,
	exclusives: { [string]: boolean }, -- exclusive cars granted by Robux (re-grantable)
	contracts: ContractState,
	referralRewarded: boolean,
	playtime: { day: number, seconds: number, claimed: { [string]: boolean } }, -- per-UTC-day playtime gifts
}

-- Daily contracts: rolled once per UTC day.
export type ContractState = {
	day: number,
	list: { { id: string, progress: number, claimed: boolean } },
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
	stats: { steals: number, playerSteals: number, busted: number, hotDrops: number, timesRobbed: number },
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

export type Settings = { music: boolean, sfx: boolean, hideHud: boolean, autoAccelerate: boolean }

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
