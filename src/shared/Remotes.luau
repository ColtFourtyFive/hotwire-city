--!strict
-- The complete list of remotes. Server creates them at startup (Net.init); clients wait for them.
-- Adding a remote = add one line here. Payload shapes are documented next to each name.

local Remotes = {}

-- RemoteEvents: server -> client
Remotes.ServerToClient = {
	"DataSnapshot", -- (snapshot: Types.Snapshot)
	"Notify", -- (kind: Types.NotifyKind, text: string, duration: number?)
	"Announce", -- (title: string, subtitle: string?, color: Color3?, sound: string?) big center banner, all players
	"EventFeed", -- (richText: string) small kill-feed style line, all players
	"CarStolenAlert", -- (thiefName: string, carId: string, mutation: string, active: boolean) victim's alarm on/off
	"CashPopup", -- (amount: number, worldPosition: Vector3?) floating +$ text
	"Busted", -- (lostCash: number)
	"Knockback", -- (velocity: Vector3, stunSeconds: number) applied by the victim's client to its own character
	"Effect", -- (effectName: string, data: {[string]: any}) cosmetic effect for all nearby clients
	"HotDropState", -- (state: {active: boolean, position: Vector3?, carId: string?, mutation: string?, endsAt: number?, startsAt: number?})
	"EventState", -- (state: {[eventName]: endsAt number}) active timed events (rush hour, 2x cash, server luck, cash rain)
	"OfflineEarnings", -- (amount: number, seconds: number)
	"Waypoint", -- (id: string, position: Vector3?, color: Color3?, label: string?) nil position clears
	"TheftState", -- (state: {active: boolean, endsAt: number?, carId: string?, targetPlot: number?}) thief's delivery timer
	"OpenUI", -- (name: string) ask client to open a menu (e.g. "GearShop" from a ProximityPrompt)
	"Sound", -- (soundKey: string, worldPosition: Vector3?) play a Config.Sounds sound
}

-- RemoteEvents: client -> server (all rate-limited + validated server-side)
Remotes.ClientToServer = {
	"UnlockSlot", -- ()
	"SellCar", -- (slot: number)
	"DriveCar", -- (slot: number)
	"BuyUpgrade", -- (upgradeId: string)
	"BuyTool", -- (toolId: string)
	"Rebirth", -- ()
	"ClaimDaily", -- ()
	"ClaimPlaytime", -- (index: number)
	"RedeemCode", -- (code: string)
	"ToolAction", -- (toolId: string, aim: Vector3?) swing/fire/drop; server validates range + cooldown
	"GoHome", -- () teleport to own garage (on foot, not wanted)
	"SetSetting", -- (key: string, value: boolean)
	"TutorialDone", -- ()
	"LockGarage", -- () owner presses lock from UI (also a physical button)
	"AdminCommand", -- (text: string) only works for admins
}

-- RemoteFunctions: client -> server
Remotes.Functions = {
	"GetSnapshot", -- () -> Types.Snapshot?
	"GetLeaderboard", -- (stat: string) -> { {name: string, userId: number, value: number} }
}

return Remotes
