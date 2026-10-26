--!strict
-- Every sound in the game, by key. IDs are Roblox-owned / Roblox-licensed public assets (verified public
-- as of 2026-10). If one ever goes private, swap it here only.

export type SoundDef = { id: string, volume: number, pitch: number?, looped: boolean? }

local function a(id: number): string
	return "rbxassetid://" .. tostring(id)
end

local Sounds = {
	-- engine / driving
	EngineLoop = { id = a(80317022777602), volume = 0.45, looped = true },
	EngineStart = { id = a(78270463799678), volume = 0.6 },
	EngineStop = { id = a(87646813759701), volume = 0.5 },
	CarDoor = { id = a(125094987563505), volume = 0.6 },
	TireScreech = { id = a(9119186024), volume = 0.35, looped = true },
	PeelOut = { id = a(9113661285), volume = 0.5 },
	Crash = { id = a(9118708982), volume = 0.7 },
	MetalHit = { id = a(9116546593), volume = 0.6 },
	GlassBreak = { id = a(9114590297), volume = 0.5 },
	Horn = { id = a(9114402206), volume = 0.7 },
	AirHorn = { id = a(9114402205), volume = 0.7 },
	-- police
	Siren = { id = a(9119165131), volume = 0.5, looped = true },
	SirenAlt = { id = a(9119165140), volume = 0.5, looped = true },
	-- money
	Cash = { id = a(9113728042), volume = 0.6 },
	CashBig = { id = a(9113728049), volume = 0.7 },
	CashDrop = { id = a(9113726510), volume = 0.6 },
	CountingMoney = { id = a(9113948676), volume = 0.5 },
	Coin = { id = a(127645268874265), volume = 0.5 },
	-- combat (cartoon)
	Bonk = { id = a(9117969584), volume = 0.7 },
	Zap = { id = "rbxasset://sounds/impact_explosion_03.mp3", volume = 0.35, pitch = 2.2 },
	Splash = { id = "rbxasset://sounds/impact_water.mp3", volume = 0.6 },
	Poof = { id = "rbxasset://sounds/impact_explosion_03.mp3", volume = 0.6 },
	-- UI
	Click = { id = a(15675032796), volume = 0.5 },
	ClickBright = { id = a(15675059323), volume = 0.5 },
	Purchase = { id = a(10066947742), volume = 0.6 },
	Notify = { id = a(17208361335), volume = 0.5 },
	Pickup = { id = a(17208319162), volume = 0.5 },
	Whoosh = { id = a(15675028888), volume = 0.5 },
	-- ambience
	CityAmbience = { id = a(9112758500), volume = 0.25, looped = true },
	Traffic = { id = a(9112891352), volume = 0.15, looped = true },
} :: { [string]: SoundDef }

return Sounds
