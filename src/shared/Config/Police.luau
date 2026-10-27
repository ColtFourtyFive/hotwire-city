--!strict
-- Wanted level + police pursuit + police combat tuning (gta_combat §9).

export type StarCombat = {
	lethal: "never" | "armed" | "always", -- 1: arrest only, 2: only an armed suspect, 3+: always
	weapons: { string }, -- officer loadout (Config/Weapons ids; "taser" = the stun gun)
	accuracy: number, -- base hit chance (PoliceAim)
	dpsBudget: number, -- firing director: max damage per second against ONE target, all officers together
	reaction: { number }, -- min, max seconds after acquiring line of sight before the first shot
	officerArmor: number,
	roadblock: boolean,
	roadblockSpikes: boolean,
	passengerFire: boolean, -- cruisers fire pistols from the window within PASSENGER_RANGE
	maxOnFoot: number, -- on-foot officers per suspect
}

export type Cone = { fov: number, range: number, near: number? } -- degrees / studs; near = 360° awareness radius

local Police = {
	MAX_STARS = 5,
	-- Evade time (seconds unseen inside the search area) per star. Deliberately shorter than GTA V's 30-90 s for
	-- Roblox session pacing (gta_combat §9.4). Outside the search area the timer runs EVADE_OUTSIDE_MULT times faster.
	DECAY_DELAY = { 15, 20, 25, 32, 40 },
	DECAY_STEP = 10, -- legacy (v1 step decay); the v2 evade clears every star at once
	EVADE_OUTSIDE_MULT = 2,
	SEARCH_RADIUS = { 120, 160, 210, 260, 320 }, -- search-area circle around the last known position, per star
	SIGHT_RANGE = 220, -- legacy: max distance at which anything can see you (cones are tighter)

	UNITS_PER_STAR = { 1, 2, 3, 4, 6 }, -- cruisers chasing one suspect
	MAX_UNITS_GLOBAL = 14,
	HELI_AT_STARS = 4,

	BUST_RADIUS = 16,
	BUST_SPEED = 14, -- suspect counted as "stopped" below this speed
	BUST_TIME = 2.5, -- seconds stopped inside bust radius to get busted

	RESPAWN_IF_FARTHER = 450, -- police more than this away are teleported to a lane near the suspect
	STUCK_TIME = 2.2, -- seconds slow while throttle applied -> reverse to unstick
	AI_LOOKAHEAD = 0.6, -- seconds of suspect velocity used for intercept prediction
	AI_TICK = 0.1, -- seconds between AI decisions

	-- Vision cones (gta_combat §9.4). The client draws them on the minimap from unit CFrames: nothing extra replicates.
	CONES = {
		foot = { fov = 70, range = 90 },
		cruiser = { fov = 100, range = 150, near = 40 },
		heli = { fov = 360, range = 110 },
		swat = { fov = 80, range = 110 },
	} :: { [string]: Cone },
	CLOSE_SEE_RANGE = 40, -- a cruiser this close always notices you (sirens, engine noise)

	-- Crimes -> stars. Values are stars ADDED; MIN_STARS below are floors applied by CrimeRules.
	Heat = {
		carjack = 1,
		dealerSteal = 2,
		playerTheft = 1,
		hotDrop = 3,
		assault = 1,
		copHit = 1,
		gunfire = 1, -- firing a gun where someone can see / hear (min 1)
		brandish = 1, -- aiming at an officer for BRANDISH_TIME
		pedHit = 1,
		pedDown = 2,
		copShot = 2,
		copDown = 3,
		heliHit = 4,
		heliDown = 5,
		pvpDown = 2,
	},
	-- Floors: "this crime puts you at LEAST at N stars" (GTA's minimum-wanted rule).
	MIN_STARS = {
		gunfire = 1,
		brandish = 1,
		pedDown = 2,
		copShot = 2,
		copDown = 3,
		heliHit = 4,
		heliDown = 5,
		pvpDown = 2,
		menace = 3,
	},
	PED_HEAT_CAP = 2, -- pedestrians alone never push you past this
	COPS_DOWNED_PER_EXTRA_STAR = 3, -- +1 star for every 3 more officers downed after the first
	WITNESS_PED_RADIUS = 60,
	WITNESS_COP_RADIUS = 120,
	GUNFIRE_HEAR_RADIUS = 120, -- a cop within this hears a shot even without line of sight
	BRANDISH_TIME = 1.5,
	BRANDISH_RANGE = 40,
	ARMED_WINDOW = 10, -- "armed" for 2-star rules: fired within this many seconds or aiming at cops

	-- Police combat per star (gta_combat §9.1).
	Combat = {
		{
			lethal = "never",
			weapons = { "taser" },
			accuracy = 0,
			dpsBudget = 0,
			reaction = { 0.8, 1.2 },
			officerArmor = 0,
			roadblock = false,
			roadblockSpikes = false,
			passengerFire = false,
			maxOnFoot = 1,
		},
		{
			lethal = "armed",
			weapons = { "pistol" },
			accuracy = 0.25,
			dpsBudget = 8,
			reaction = { 0.8, 1.2 },
			officerArmor = 0,
			roadblock = false,
			roadblockSpikes = false,
			passengerFire = false,
			maxOnFoot = 2,
		},
		{
			lethal = "always",
			weapons = { "pistol", "pump" },
			accuracy = 0.32,
			dpsBudget = 14,
			reaction = { 0.8, 1.2 },
			officerArmor = 50,
			roadblock = true,
			roadblockSpikes = false,
			passengerFire = true,
			maxOnFoot = 3,
		},
		{
			lethal = "always",
			weapons = { "carbine", "pump" },
			accuracy = 0.38,
			dpsBudget = 20,
			reaction = { 0.6, 0.6 },
			officerArmor = 50,
			roadblock = true,
			roadblockSpikes = true,
			passengerFire = true,
			maxOnFoot = 4,
		},
		{
			lethal = "always",
			weapons = { "carbine" },
			accuracy = 0.45,
			dpsBudget = 28,
			reaction = { 0.6, 0.6 },
			officerArmor = 100,
			roadblock = true,
			roadblockSpikes = true,
			passengerFire = true,
			maxOnFoot = 5,
		},
	} :: { StarCombat },

	TASER_RANGE = 25,
	TASER_STUN = 1.5,
	TASER_COOLDOWN = 4,
	OFFICER_HEALTH = 100,
	OFFICER_FOOT_MAX = 8, -- on-foot officers per server
	OFFICER_EXIT_RANGE = 60, -- officers get out when the suspect is on foot / stopped within this of a stopped cruiser
	OFFICER_ARREST_RANGE = 6,
	OFFICER_COVER_RADIUS = 25,
	OFFICER_ADVANCE_AFTER = 4, -- seconds out of sight before moving up on the last known position
	OFFICER_THINK = 0.25, -- 4 Hz
	OFFICER_RETURN_AFTER = 20, -- no target for this long: walk back to the cruiser / despawn
	WARNING_SHOTS = 2, -- first shots at a newly acquired target always miss (2-4 studs away)
	MERCY_HEALTH = 30, -- once per life: below this, police accuracy halves for MERCY_TIME
	MERCY_TIME = 4,
	NO_FIRE_SPEED = 20, -- 2 stars: never shoot at a car going faster than this (ram instead)
	PASSENGER_RANGE = 60,
	PASSENGER_TIRE_CHANCE = 0.1,
	HOLD_FIRE_RESPAWN = 5, -- no police fire within this long of a respawn / release
	ROADBLOCK_AHEAD = { 220, 340 }, -- studs ahead on the predicted route
	ROADBLOCK_LIFETIME = 60,
	ROADBLOCK_COOLDOWN = 45,
	AMMO_PICKUP_LIFETIME = 20,
	DOWNED_FADE_AFTER = 6,
}

return Police
