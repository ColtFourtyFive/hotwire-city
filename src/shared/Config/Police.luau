--!strict
-- Wanted level + police pursuit tuning.

local Police = {
	MAX_STARS = 5,
	-- Seconds without new crimes (and without being seen) before a star decays, indexed by current stars.
	DECAY_DELAY = { 15, 20, 25, 32, 40 },
	DECAY_STEP = 10, -- seconds between each star lost once decay starts
	SIGHT_RANGE = 220, -- police within this range "see" you and reset the decay timer

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

	-- Crimes -> stars
	Heat = {
		carjack = 1,
		dealerSteal = 2,
		playerTheft = 1,
		hotDrop = 3,
		assault = 1,
		copHit = 1,
	},
}

return Police
