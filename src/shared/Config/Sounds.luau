--!strict
-- Every sound in the game, by key. IDs are Roblox-owned / Roblox-licensed public assets (verified public
-- as of 2026-10). If one ever goes private, swap it here only.

-- station / title: car-radio tracks only (Radio_* keys; see SoundController's radio).
-- start / stop: PlaybackRegion seconds (one transient out of a multi-shot file); rollOff: RollOffMaxDistance for world
-- sounds (default SoundController's); pitchVar: random pitch spread (+-) per play.
export type SoundDef = {
	id: string,
	volume: number,
	pitch: number?,
	looped: boolean?,
	station: string?,
	title: string?,
	start: number?,
	stop: number?,
	rollOff: number?,
	pitchVar: number?,
}

local function a(id: number): string
	return "rbxassetid://" .. tostring(id)
end

-- Gun / impact layers (gta_combat §12.4): Pro Sound Effects (public, waveform-checked) first, Audioscape "AS_*"
-- (metadata only: audition in Studio). Each shot plays shot (close) + tail (distance) + mech (close) layers.
local function gun(id: number, volume: number, rollOff: number, extra: { [string]: any }?): SoundDef
	local def: SoundDef = { id = a(id), volume = volume, rollOff = rollOff, pitchVar = 0.04 }
	if extra then
		for k, v in extra do
			(def :: any)[k] = v
		end
	end
	return def
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
	-- combat: gadgets
	Bonk = { id = a(9117969584), volume = 0.7 },
	Zap = { id = "rbxasset://sounds/impact_explosion_03.mp3", volume = 0.35, pitch = 2.2 },
	Splash = { id = "rbxasset://sounds/impact_water.mp3", volume = 0.6 },
	Poof = { id = "rbxasset://sounds/impact_explosion_03.mp3", volume = 0.6 },
	-- guns: close shot layer (RollOffMaxDistance ~220)
	Shot_Pistol = gun(9117399029, 0.75, 220),
	Shot_HandCannon = gun(9114729252, 0.8, 260, { start = 0.04, pitch = 0.85 }),
	Shot_SMG = gun(9113180776, 0.6, 220, { pitch = 1.15 }),
	Shot_Rifle = gun(9113180776, 0.75, 260),
	Shot_Carbine1 = gun(128650101411844, 0.75, 260),
	Shot_Carbine2 = gun(127619198178554, 0.75, 260),
	Shot_Carbine3 = gun(86903016850225, 0.75, 260),
	Shot_Carbine4 = gun(72333449737130, 0.75, 260),
	Shot_Marksman = gun(9118173988, 0.85, 320),
	Shot_Shotgun1 = gun(99008924129683, 0.85, 240),
	Shot_Shotgun2 = gun(82409501948316, 0.85, 240),
	Shot_Shotgun3 = gun(106454770387605, 0.85, 240),
	Shot_Shotgun4 = gun(84039532799719, 0.85, 240),
	Shot_ShotgunFallback = gun(9112913564, 0.85, 240, { start = 0, stop = 0.17 }),
	-- guns: distant tail layer (played for listeners beyond ~120 studs, low-passed beyond 250)
	Tail_Gun1 = gun(90852446208160, 0.5, 900),
	Tail_Gun2 = gun(70527882874881, 0.5, 900),
	Tail_Gun3 = gun(79289354458541, 0.5, 900),
	Tail_Gun4 = gun(111187749925677, 0.5, 900),
	Tail_Rifle = gun(9113198012, 0.45, 900),
	Tail_Shotgun1 = gun(75302784250672, 0.5, 900),
	Tail_Shotgun2 = gun(116468550696572, 0.5, 900),
	Tail_Shotgun3 = gun(125311341637563, 0.5, 900),
	Tail_Shotgun4 = gun(99323994116525, 0.5, 900),
	Distant_Burst = gun(9116361236, 0.3, 1200),
	-- guns: mechanics / reload foley (close only)
	Mech_PumpRack = gun(9112910245, 0.6, 40, { start = 0.85, stop = 1.25 }),
	Reload_Mag = gun(9113104176, 0.55, 40),
	Reload_Shell = gun(9112910245, 0.45, 40, { start = 0.05, stop = 0.4 }),
	Gun_Empty = gun(9113104176, 0.4, 30, { start = 0.3, stop = 0.45, pitch = 1.4 }),
	-- bullets in the world
	Whiz1 = gun(9113634361, 0.55, 30),
	Whiz2 = gun(9113634444, 0.55, 30),
	Whiz3 = gun(9118168291, 0.55, 30),
	Ricochet1 = gun(9118168612, 0.5, 120),
	Ricochet2 = gun(9118169272, 0.5, 120),
	Impact1 = gun(9113632396, 0.45, 90),
	Impact2 = gun(9113632506, 0.45, 90),
	ImpactWood = gun(9120962232, 0.45, 90),
	HitTick = { id = a(109431560870225), volume = 0.3 },
	BodyFall = gun(9113480915, 0.6, 80),
	-- melee
	Melee_Punch1 = gun(9117969687, 0.7, 60),
	Melee_Punch2 = gun(9117969717, 0.7, 60),
	Melee_Bat = gun(9125380872, 0.75, 70),
	Melee_Metal = gun(9116546593, 0.6, 70),
	-- wasted / busted / police
	Wasted = { id = a(9120704346), volume = 0.7 },
	WastedImpact = { id = a(9125404320), volume = 0.6 },
	Busted = { id = a(9125404320), volume = 0.6 },
	Handcuffs = gun(9114764435, 0.6, 40),
	PoliceRadio = { id = a(9117798202), volume = 0.25 },
	PoliceRadioFeed = { id = a(9125774594), volume = 0.2 },
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
