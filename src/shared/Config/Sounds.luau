--!strict
-- Every sound in the game, by key. IDs are Roblox-owned / Roblox-licensed public assets (verified public
-- as of 2026-10). If one ever goes private, swap it here only.

-- station / title: car-radio tracks only (Radio_* keys; see SoundController's radio).
export type SoundDef = {
	id: string,
	volume: number,
	pitch: number?,
	looped: boolean?,
	station: string?,
	title: string?,
}

local function a(id: number): string
	return "rbxassetid://" .. tostring(id)
end

local function radio(id: number, station: string, title: string, volume: number?): SoundDef
	return { id = a(id), volume = volume or 0.28, looped = false, station = station, title = title }
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
	-- car radio: 2D music (music channel) while the local player drives. Public, free APMOfficial music tracks
	-- (toolbox-service v2: creator APMOfficial, verified, audioType Music, purchasable at 0; checked 2026-10-27).
	-- looped = false: the station queues its next track. Stations sort by name, tracks within one by key.
	Radio_Hyperdrive = radio(72710061789341, "BASS DROP 101", "Hyperdrive", 0.26), -- Queens Road, 155 s
	Radio_PartyTime = radio(1847692770, "BASS DROP 101", "EDM Party Time", 0.26), -- Sonoton Vanguard, 161 s
	Radio_CityLights = radio(9046863579, "CHILL WAVES", "City Lights", 0.32), -- Inside Tracks, 120 s
	Radio_Poolside = radio(9046863253, "CHILL WAVES", "Poolside", 0.32), -- Max Cameron Concors, 165 s
	Radio_FatElectroFunk = radio(1836160527, "FUNKY DRIVE", "Fat Electro Funk"), -- AXS, 154 s
	Radio_TheStickup = radio(1841268296, "FUNKY DRIVE", "The Stickup"), -- Guy Buss, 154 s
	Radio_AllGood = radio(9044508438, "HEIST HOP", "All Good", 0.3), -- Bibliotheque, 128 s
	Radio_UrbanJungleDrive = radio(1836021107, "HEIST HOP", "Urban Jungle Drive"), -- Nicolas Baudino, 177 s
	Radio_NeonLights = radio(1837115816, "NEON FM", "Neon Lights"), -- Bibliotheque, 153 s
	Radio_OutrunArcade = radio(1837301807, "NEON FM", "Outrun Arcade"), -- Boris Popov, 198 s
} :: { [string]: SoundDef }

return Sounds
