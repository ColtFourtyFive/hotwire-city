--!strict
-- Redeemable codes. SERVER-ONLY (lives under ServerScriptService) so clients can't read unreleased codes.
-- kind "cash" = flat amount; "incomeMinutes" = minutes of the redeemer's income (never less than `min`).

export type CodeReward = { kind: string, amount: number, min: number? }

return {
	RELEASE = { kind = "incomeMinutes", amount = 5, min = 2500 },
	VROOM = { kind = "incomeMinutes", amount = 3, min = 1000 },
	HOTWIRE = { kind = "incomeMinutes", amount = 10, min = 5000 },
	QUACK = { kind = "incomeMinutes", amount = 8, min = 5000 },
} :: { [string]: CodeReward }
