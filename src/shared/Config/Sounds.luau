--!strict
-- Every sound in the game, by key. IDs are Roblox-owned / Roblox-licensed public assets already on the platform (no
-- uploads): Pro Sound Effects (PSE), Audioscape, APM Music, Roblox and Roblox Resources. Every id is checked by
-- tools/audio/audit.py (public, approved, downloadable, decodes, not silent, regions inside the file) and the report
-- is docs/v2/evidence/audio_audit.md. If one ever goes private, swap it here only and re-run the audit.
--
-- Fields
--   volume / pitch            base Sound.Volume / PlaybackSpeed (loudness-normalised by the audit's RMS figures)
--   looped                    loops (beds, engines, sirens, foley loops)
--   start / stop              PlaybackRegion seconds: one event out of a longer file (one-shots)
--   loopStart / loopEnd       LoopRegion seconds: the steady part of a long PSE take (engines, sirens, foley loops;
--                             picked with `audit.py --loop`, seams snapped to zero crossings)
--   lowpass                   play through a low-pass EqualizerSoundEffect (off-load engine layers)
--   rollOff                   RollOffMaxDistance for world sounds; pitchVar: random pitch spread (+-) per play
--   station / title / length  car-radio tracks only (Radio_* keys; titles show in the HUD, keep them clean; length =
--                             measured seconds, the station's live clock needs it)
--
-- Content safety (docs/v2/CONTENT_SAFETY.md): no voices saying names / numbers / agencies. The police dispatch keys are
-- squelch, static and beeps only (no talk); ambience beds were picked from descriptions without speech.
export type SoundDef = {
	id: string,
	volume: number,
	pitch: number?,
	looped: boolean?,
	station: string?,
	title: string?,
	start: number?,
	stop: number?,
	loopStart: number?,
	loopEnd: number?,
	lowpass: boolean?,
	rollOff: number?,
	pitchVar: number?,
	length: number?,
}

local function a(id: number): string
	return "rbxassetid://" .. tostring(id)
end

-- Gun / impact layers (gta_combat §12.4): Pro Sound Effects (public, waveform-checked) first, Audioscape "AS_*".
-- Each shot plays shot (close) + tail (distance) + mech (close) layers.
local function gun(id: number, volume: number, rollOff: number, extra: { [string]: any }?): SoundDef
	local def: SoundDef = { id = a(id), volume = volume, rollOff = rollOff, pitchVar = 0.04 }
	if extra then
		for k, v in extra do
			(def :: any)[k] = v
		end
	end
	return def
end

-- A looping region of a long take.
local function loop(
	id: number,
	volume: number,
	loopStart: number?,
	loopEnd: number?,
	extra: { [string]: any }?
): SoundDef
	local def: SoundDef = { id = a(id), volume = volume, looped = true, loopStart = loopStart, loopEnd = loopEnd }
	if extra then
		for k, v in extra do
			(def :: any)[k] = v
		end
	end
	return def
end

-- A one-shot (optionally one event out of a longer file).
local function one(id: number, volume: number, extra: { [string]: any }?): SoundDef
	local def: SoundDef = { id = a(id), volume = volume }
	if extra then
		for k, v in extra do
			(def :: any)[k] = v
		end
	end
	return def
end

-- length = the track's measured duration (audio_audit.md): the station's live clock (Audio/RadioDial.trackAt) needs it.
local function radio(id: number, station: string, title: string, length: number, volume: number?): SoundDef
	return { id = a(id), volume = volume or 0.28, looped = false, station = station, title = title, length = length }
end

local Sounds = {
	-------------------------------------------------------------------------------------------------------------------
	-- Engines (Audio/EngineModel profiles; Audio/EngineClass maps car classes to these sets). Each set has an idle,
	-- an on-load (throttle) and an off-load (coasting) layer; PlaybackSpeed follows the simulated rpm.
	-------------------------------------------------------------------------------------------------------------------
	-- compact: the Roblox car-engine loop (a designed seamless loop), pitched per layer
	Eng_Compact_Idle = loop(80317022777602, 0.75, nil, nil, { pitch = 0.82 }),
	Eng_Compact_On = loop(80317022777602, 0.85),
	Eng_Compact_Off = loop(80317022777602, 0.6, nil, nil, { lowpass = true }),
	-- sedan: 1964 Cadillac convertible, constant drive (PSE)
	Eng_Sedan_Idle = loop(9112734195, 0.33, 25.602, 27.9),
	Eng_Sedan_On = loop(9112734195, 0.35, 0.596, 5.868),
	Eng_Sedan_Off = loop(9112734195, 0.3, 0.596, 5.868, { lowpass = true }),
	-- muscle: 1969 Chevelle on-board exterior idle / revs, interior cruise as the off-load burble (PSE)
	Eng_Muscle_Idle = loop(9112735119, 0.68, 6.498, 10.516),
	Eng_Muscle_On = loop(9112735119, 0.61, 28.004, 34.082),
	Eng_Muscle_Off = loop(9112734376, 0.32, 1.002, 5.345, { lowpass = true }),
	-- sports: Ferrari 308 idle / booming revs (PSE)
	Eng_Sports_Idle = loop(9125556863, 0.23, 26.002, 30.405),
	Eng_Sports_On = loop(9125556863, 0.18, 5.003, 8.635),
	Eng_Sports_Off = loop(9125556863, 0.16, 5.003, 8.635, { lowpass = true }),
	-- super: race-car engine idle / constant high rpm (PSE)
	Eng_Super_Idle = loop(9112782019, 0.55, 26.751, 28.452),
	Eng_Super_On = loop(9112782186, 0.53, 5.0, 9.711),
	Eng_Super_Off = loop(9112782186, 0.45, 5.0, 9.711, { lowpass = true }),
	-- truck: diesel pickup long idle, dump-truck constant drive (PSE)
	Eng_Truck_Idle = loop(9125349929, 1.5, 8.0, 11.209),
	Eng_Truck_On = loop(9112735582, 0.15, 15.0, 18.738),
	Eng_Truck_Off = loop(9112735582, 0.2, 6.749, 12.249, { lowpass = true }),
	-- bike: four-cylinder motorcycle idle / high revs (PSE)
	Eng_Bike_Idle = loop(9114895897, 1.0, 4.25, 5.892),
	Eng_Bike_On = loop(9114895897, 0.45, 10.749, 15.649),
	Eng_Bike_Off = loop(9114895897, 0.38, 10.749, 15.649, { lowpass = true }),
	-- police interceptor: big V8 (muscle idle, sedan cruise)
	Eng_Police_Idle = loop(9112735119, 0.6, 6.498, 10.516, { pitch = 0.94 }),
	Eng_Police_On = loop(9112734195, 0.38, 0.596, 5.868),
	Eng_Police_Off = loop(9112734376, 0.3, 1.002, 5.345, { lowpass = true }),

	-------------------------------------------------------------------------------------------------------------------
	-- Car foley
	-------------------------------------------------------------------------------------------------------------------
	EngineStart = { id = a(78270463799678), volume = 0.6 },
	EngineStop = { id = a(87646813759701), volume = 0.5 },
	Ignition = one(9116176570, 1.0, { start = 0, stop = 0.62 }), -- keys into the ignition
	CarDoor = { id = a(125094987563505), volume = 0.6 },
	DoorSlam = one(9120370628, 0.55, { rollOff = 90 }),
	HotwireCrackle = loop(9114238020, 3.0, 2.0, 15.379), -- soft electrical arcing (a -41 dB take: high Volume)
	TireScreech = loop(9120398722, 0.3, 25.5, 29.709), -- sustained tyre squeal (lateral slip)
	PeelOut = { id = a(9113661285), volume = 0.5 },
	SurfaceGravel = loop(9126156741, 1.2, 12.5, 17.139), -- tyres on dirt / gravel / sand
	ScrapeLoop = loop(9112832551, 0.42, 4.0, 10.87), -- metal dragging on asphalt (grinding a wall)
	WindInterior = loop(9118747525, 0.8), -- wind at speed, heard inside the car only
	Crash = { id = a(9118708982), volume = 0.7 },
	GlassBreak = one(9114590297, 0.5, { start = 0.7 }),
	Impact_Light1 = one(9113267435, 0.75, { rollOff = 140, pitchVar = 0.06 }),
	Impact_Light2 = one(9113267039, 0.6, { rollOff = 140, pitchVar = 0.06 }),
	Impact_Light3 = one(9113267751, 0.7, { rollOff = 140, pitchVar = 0.06 }),
	Impact_Heavy1 = one(9116546326, 0.55, { stop = 2.3, rollOff = 260, pitchVar = 0.05 }),
	Impact_Heavy2 = one(9116546358, 0.55, { stop = 2.2, rollOff = 260, pitchVar = 0.05 }),
	Impact_Heavy3 = one(9116547037, 0.55, { stop = 2.3, rollOff = 260, pitchVar = 0.05 }),
	Impact_Glass1 = one(9114592237, 0.8, { start = 0.45, stop = 1.4, rollOff = 160 }),
	Impact_Glass2 = one(9114590265, 0.7, { stop = 1.6, rollOff = 160 }),
	Pop_Backfire1 = one(9114580305, 0.5, { stop = 0.45, pitch = 0.7, rollOff = 160, pitchVar = 0.08 }),
	Pop_Backfire2 = one(9113263454, 0.35, { pitch = 0.5, rollOff = 160, pitchVar = 0.08 }),
	Turbo_Blowoff = one(9125348863, 0.3, { start = 0.8, stop = 1.4, pitch = 1.6, rollOff = 90 }),
	-- horns (one honk per press; per engine set: Audio/EngineClass.HORNS)
	Horn = { id = a(9114402206), volume = 0.7 },
	AirHorn = { id = a(9114402205), volume = 0.7 },
	Horn_Compact = one(9120447050, 1.2, { start = 0.2, stop = 1.0, rollOff = 260 }),
	Horn_Sedan = one(9120385543, 0.6, { stop = 0.4, rollOff = 260 }),
	Horn_Muscle = one(9113019260, 0.55, { start = 0.25, stop = 0.85, rollOff = 260 }),
	Horn_Sports = one(9114402340, 0.55, { start = 0.1, stop = 1.3, rollOff = 260 }),
	Horn_Truck = one(9114075665, 0.6, { start = 0.5, stop = 1.8, rollOff = 400 }),

	-------------------------------------------------------------------------------------------------------------------
	-- Police
	-------------------------------------------------------------------------------------------------------------------
	-- a steady slice at the top of a real siren's sweep: Audio/Siren drives its pitch (wail / yelp / hi-lo)
	Siren_Tone = loop(9119165131, 0.6, 4.35, 4.75),
	Siren_Yelp = loop(9119165419, 0.55, 14.999, 17.189), -- recorded yelp cycle
	Siren_Distant = loop(9112871822, 1.4), -- group of units wailing far away (wanted layer)
	Siren = { id = a(9119165131), volume = 0.5, looped = true }, -- v1 keys (stolen-car alarm)
	-- dispatch radio: squelch, static and beeps only (no talk)
	Dispatch_Squelch1 = one(9118019216, 0.25),
	Dispatch_Squelch2 = one(9118021734, 0.25),
	Dispatch_Squelch3 = one(9118026328, 0.25),
	Dispatch_Static1 = one(9118026602, 0.18),
	Dispatch_Static2 = one(9118027586, 0.18),
	PoliceRadio = one(9118019216, 0.25), -- v1 keys, now squelch / static (the old ids had dispatcher voices)
	PoliceRadioFeed = one(9118026602, 0.18),
	Heli_Rotor = loop(9113417360, 0.75, 7.5, 9.769, { rollOff = 700 }),

	-------------------------------------------------------------------------------------------------------------------
	-- Money / UI / gadgets
	-------------------------------------------------------------------------------------------------------------------
	Cash = { id = a(9113728042), volume = 0.6 },
	CashBig = { id = a(9113728049), volume = 0.7 },
	CashDrop = { id = a(9113726510), volume = 0.6 },
	CountingMoney = { id = a(9113948676), volume = 0.5 },
	Coin = { id = a(127645268874265), volume = 0.5 },
	Bonk = { id = a(9117969584), volume = 0.7 },
	Zap = { id = "rbxasset://sounds/impact_explosion_03.mp3", volume = 0.35, pitch = 2.2 },
	Splash = { id = "rbxasset://sounds/impact_water.mp3", volume = 0.6 },
	Poof = { id = "rbxasset://sounds/impact_explosion_03.mp3", volume = 0.6 },
	Click = { id = a(15675032796), volume = 0.5 },
	ClickBright = { id = a(15675059323), volume = 0.5 },
	Purchase = { id = a(10066947742), volume = 0.6 },
	Notify = { id = a(17208361335), volume = 0.5 },
	Pickup = { id = a(17208319162), volume = 0.5 },
	Whoosh = { id = a(15675028888), volume = 0.5 },

	-------------------------------------------------------------------------------------------------------------------
	-- Guns: close shot layer (RollOffMaxDistance ~220)
	-------------------------------------------------------------------------------------------------------------------
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
	-- distant tail layer (played for listeners beyond ~120 studs, low-passed beyond 250)
	Tail_Gun1 = gun(90852446208160, 0.5, 900),
	Tail_Gun2 = gun(70527882874881, 0.5, 900),
	Tail_Gun3 = gun(79289354458541, 0.5, 900),
	Tail_Gun4 = gun(111187749925677, 0.5, 900),
	Tail_Rifle = gun(9113198012, 0.45, 900),
	-- shotgun tails (the AS_shotgun_tail-01..04 uploads measured silent: replaced, audio_audit.md)
	Tail_Shotgun1 = gun(9114725473, 0.4, 900, { start = 0.74 }), -- PSE Gun Retort 3 (reverberant)
	Tail_Shotgun2 = gun(70527882874881, 0.55, 900, { pitch = 0.85 }),
	Tail_Shotgun3 = gun(79289354458541, 0.55, 900, { pitch = 0.82 }),
	Tail_Shotgun4 = gun(9113198012, 0.45, 900, { pitch = 0.8 }),
	Distant_Burst = gun(9116361236, 0.3, 1200),
	-- mechanics / reload foley (close only)
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
	Melee_Punch2 = gun(9117969717, 0.62, 60),
	Melee_Bat = gun(9125380872, 0.75, 70),
	Melee_Metal = gun(9116546593, 0.6, 70),
	-- wasted / busted
	Wasted = { id = a(9120704346), volume = 0.7 },
	WastedImpact = { id = a(9125404320), volume = 0.6 },
	Busted = { id = a(9125404320), volume = 0.6 },
	Handcuffs = gun(9114764435, 0.6, 40),

	-------------------------------------------------------------------------------------------------------------------
	-- Ambience (Audio/Ambience): district beds (day / night), the freeway layer, one-shots. Beds are PSE location
	-- recordings marked as loops; one-shots play at a distance in the listener's direction.
	-------------------------------------------------------------------------------------------------------------------
	Amb_City_Day = loop(9112891671, 0.55), -- urban traffic, overhead perspective, horns
	Amb_City_Night = loop(9112759731, 0.65), -- city night, distant traffic wash
	Amb_Beach_Day = loop(9126201834, 0.5), -- waves rolling in constantly
	Amb_Beach_Night = loop(9119676800, 0.45), -- surf, tide roll-up
	Amb_Wild_Day = loop(9112831284, 0.55), -- birds
	Amb_Wild_Night = loop(9112765304, 0.5), -- crickets, rural night
	Amb_Desert_Day = loop(9112865610, 0.7), -- desert air
	Amb_Desert_Night = loop(9125485532, 0.5), -- desert dusk crickets
	Amb_Suburb_Day = loop(9112904460, 0.6), -- California neighbourhood presence
	Amb_Suburb_Night = loop(9112764346, 0.55), -- crickets, distant city rumble
	Amb_Industrial_Day = loop(9114776167, 0.55), -- constant machine idle
	Amb_Industrial_Night = loop(9112791278, 0.55), -- feed mill by a river at night
	Amb_Port_Day = loop(9112868658, 0.55), -- harbour, terminal island
	Amb_Port_Night = loop(9112789988, 0.6), -- night docks
	Amb_Airport_Day = loop(9112772101, 0.55), -- distant freeway wash, freight trucks
	Amb_Airport_Night = loop(9112772108, 0.55), -- distant traffic, a few crickets
	Amb_Freeway = loop(9112784654, 0.6), -- Southern California freeway traffic (near freeways)
	-- one-shots
	Amb_SirenFar1 = one(9119163066, 0.35, { start = 4.6, stop = 24 }), -- 4.9 s lead silence trimmed (audit)
	Amb_SirenFar2 = one(9119163012, 0.35, { start = 0.4, stop = 22 }),
	Amb_Horn1 = one(9120385772, 0.35, { pitchVar = 0.08 }),
	Amb_Horn2 = one(9120386248, 0.35, { pitchVar = 0.08 }),
	Amb_Horn3 = one(9114661198, 0.3, { pitchVar = 0.05 }),
	Amb_Dog1 = one(9113955372, 0.3, { pitch = 0.92, pitchVar = 0.06 }),
	Amb_Dog2 = one(9113956178, 0.3, { pitch = 0.92, pitchVar = 0.06 }),
	Amb_Dog3 = one(9113955086, 0.3, { pitch = 0.92, pitchVar = 0.06 }),
	Amb_CarAlarm = one(9113719289, 0.25),
	Amb_Plane1 = one(9113864890, 0.7, { start = 2.0, stop = 34 }), -- quiet, distant take: louder
	Amb_Plane2 = one(9113864886, 0.5, { start = 2.1, stop = 26 }),
	Amb_Gull1 = one(9118858279, 0.35, { pitchVar = 0.06 }),
	Amb_Gull2 = one(9118858265, 0.35, { pitchVar = 0.06 }),
	Amb_Gull3 = one(9118858259, 0.35, { pitchVar = 0.06 }),
	Amb_Coyote = one(9113950627, 0.35, { start = 0.3 }),
	Amb_Clank1 = one(9125672726, 0.3, { pitchVar = 0.1 }),
	Amb_Clank2 = one(9116751108, 0.35, { pitchVar = 0.1 }),
	Amb_TrainHorn = one(9112772271, 0.4, { stop = 26 }),

	-------------------------------------------------------------------------------------------------------------------
	-- Car radio: 2D music on the music channel while the local player drives (muffled 3D for people outside the car).
	-- Public, free APM Music tracks (toolbox-service: creator APMOfficial, audioType Music, free; audio_audit.md).
	-- Station names are our own parodies; titles show on the HUD. looped = false: the station queues its next track.
	-------------------------------------------------------------------------------------------------------------------
	Radio_Hyperdrive = radio(72710061789341, "BASS DROP 101", "Hyperdrive", 155.29, 0.26),
	Radio_PartyTime = radio(1847692770, "BASS DROP 101", "EDM Party Time", 160.7, 0.26),
	Radio_Aura = radio(1837664025, "BASS DROP 101", "Aura", 183.52, 0.26),
	Radio_CityLights = radio(9046863579, "CHILL WAVES", "City Lights", 120.1, 0.32),
	Radio_Poolside = radio(9046863253, "CHILL WAVES", "Poolside", 165.24, 0.32),
	Radio_BeachCushions = radio(9047104411, "CHILL WAVES", "Beach Cushions", 156.68, 0.32),
	Radio_FatElectroFunk = radio(1836160527, "FUNKY DRIVE", "Fat Electro Funk", 154.07),
	Radio_TheStickup = radio(1841268296, "FUNKY DRIVE", "The Stickup", 153.91),
	Radio_DiscoSapiens = radio(1835725225, "FUNKY DRIVE", "Disco Sapiens", 155.14),
	Radio_AllGood = radio(9044508438, "HEIST HOP", "All Good", 127.99, 0.3),
	Radio_UrbanJungleDrive = radio(1836021107, "HEIST HOP", "Urban Jungle Drive", 177.1),
	Radio_WestCoastHop = radio(1835563783, "HEIST HOP", "West Coast Hop", 180.27),
	Radio_NeonLights = radio(1837115816, "NEON FM", "Neon Lights", 153.44),
	Radio_OutrunArcade = radio(1837301807, "NEON FM", "Outrun Arcade", 198.31),
	Radio_DeletedMemory = radio(1837115853, "NEON FM", "Deleted Memory", 109.8),
	Radio_SurfRock = radio(1847233991, "PALMERA ROCK 104", "Surf Rock", 175.73),
	Radio_TheRenegade = radio(1837413931, "PALMERA ROCK 104", "The Renegade", 139.98),
	Radio_SurfingRocking = radio(1837299865, "PALMERA ROCK 104", "Surfing 'n' Rocking", 122.54),
	-- the static burst between stations
	RadioStatic = one(9118026930, 0.3, { start = 0.1 }),
} :: { [string]: SoundDef }

return Sounds
