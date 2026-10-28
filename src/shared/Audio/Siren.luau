--!strict
-- Siren (PLAN C3 · audio): police siren patterns and Doppler, pure.
--
-- An electronic siren is one tone swept by a pattern. Audio/PoliceAudio loops a short steady slice of a real siren
-- tone (Config/Sounds Siren_Tone) and drives its PlaybackSpeed with pitchAt(pattern, t):
--   wail  slow rise and fall (about 4 s per cycle)
--   yelp  fast sweep (about 3 per second)
--   hilo  two-tone, alternating hi / lo
-- choose() switches patterns during a chase the way GTA's units do: mostly wail cruising, yelp / hi-lo bursts when the
-- unit is close to the suspect or pushing through, a new pattern every few seconds. The caller passes its own random
-- source (a () -> number in [0, 1)), so the machine is deterministic under test.

local Siren = {}

Siren.PATTERNS = { "wail", "yelp", "hilo" }
Siren.WAIL_PERIOD = 4.2
Siren.YELP_PERIOD = 0.34
Siren.HILO_PERIOD = 1.1
Siren.LOW = 0.72 -- bottom of a sweep, relative to the tone's own pitch
Siren.HILO_LOW = 0.8
Siren.SPEED_OF_SOUND = 1225 -- studs/s (343 m/s at 0.28 m per stud)
Siren.DOPPLER_MIN = 0.86
Siren.DOPPLER_MAX = 1.16

-- PlaybackSpeed multiplier of a pattern at time t (s).
function Siren.pitchAt(pattern: string, t: number): number
	if pattern == "yelp" then
		local ph = (t / Siren.YELP_PERIOD) % 1
		-- triangle sweep, fast up / slower down
		local v = if ph < 0.4 then ph / 0.4 else 1 - (ph - 0.4) / 0.6
		return Siren.LOW + (1 - Siren.LOW) * v
	elseif pattern == "hilo" then
		local ph = (t / Siren.HILO_PERIOD) % 1
		return if ph < 0.5 then 1 else Siren.HILO_LOW
	end
	-- wail: slow rise, slow fall (raised cosine)
	local ph = (t / Siren.WAIL_PERIOD) % 1
	local v = 0.5 - 0.5 * math.cos(ph * 2 * math.pi)
	return Siren.LOW + (1 - Siren.LOW) * v
end

export type State = { pattern: string, timer: number, t: number }

function Siren.newState(rand: () -> number): State
	return { pattern = "wail", timer = 2 + rand() * 4, t = rand() * Siren.WAIL_PERIOD }
end

-- Pattern weights for an intensity 0..1 (0 cruising, 1 right on the suspect).
function Siren.weights(intensity: number): (number, number, number)
	local i = math.clamp(intensity, 0, 1)
	return 1 - 0.7 * i, 0.15 + 0.5 * i, 0.1 + 0.35 * i
end

-- Advance a unit's siren state. Returns the pattern to play now. intensity: 0..1.
function Siren.step(st: State, dt: number, intensity: number, rand: () -> number): string
	st.t += dt
	st.timer -= dt
	if st.timer <= 0 then
		local w, y, h = Siren.weights(intensity)
		local r = rand() * (w + y + h)
		local nextPattern = if r < w then "wail" elseif r < w + y then "yelp" else "hilo"
		st.pattern = nextPattern
		-- short bursts of yelp / hi-lo, longer wails
		st.timer = if nextPattern == "wail" then 4 + rand() * 6 else 1.5 + rand() * 3
	end
	return st.pattern
end

-- Chase intensity for a unit: closer to the listener's car and faster = more urgent.
function Siren.intensity(distance: number, unitSpeed: number): number
	local near = math.clamp(1 - (distance - 25) / 150, 0, 1)
	local fast = math.clamp(unitSpeed / 90, 0, 1)
	return math.clamp(0.65 * near + 0.35 * fast, 0, 1)
end

-- Doppler PlaybackSpeed factor. relSpeed = closing speed (studs/s, positive = source and listener approaching).
function Siren.doppler(relSpeed: number): number
	local c = Siren.SPEED_OF_SOUND
	local v = math.clamp(relSpeed, -c * 0.5, c * 0.5)
	return math.clamp(c / (c - v), Siren.DOPPLER_MIN, Siren.DOPPLER_MAX)
end

-- The pattern a unit's SirenMode attribute asks for (PoliceDriving, v2 traffic: "wail" | "yelp" | "hilo" | "lights").
-- Returns (known, pattern): "lights" = lights only, no sound (known, nil); a missing / unknown value = not known (the
-- client runs its own Siren.step machine).
function Siren.fromAttr(mode: any): (boolean, string?)
	if mode == "wail" or mode == "yelp" or mode == "hilo" then
		return true, mode
	elseif mode == "lights" or mode == "off" then
		return true, nil
	end
	return false, nil
end

-- Is a police unit's siren sounding? Siren == false (leaving / wrecked, v1 contract) or SirenOn == false (v2) silence
-- it; nil = on (older / unreplicated units).
function Siren.isOn(sirenAttr: any, sirenOnAttr: any): boolean
	return sirenAttr ~= false and sirenOnAttr ~= false
end

-- Distant siren bed while wanted: louder with stars, and it gets out of the way of real sirens close by
-- (nearestUnit = studs to the closest sounding unit, math.huge when none).
function Siren.distantLevel(stars: number, nearestUnit: number): number
	if stars <= 0 then
		return 0
	end
	local base = math.clamp(0.25 + 0.15 * stars, 0, 1)
	local near = math.clamp((nearestUnit - 60) / 180, 0, 1) -- 0 with a unit within 60 studs, 1 beyond 240
	return base * (0.25 + 0.75 * near)
end

-- Seconds until the next dispatch-radio blip (squelch / static / beeps, no words) while wanted: busier with stars.
function Siren.dispatchGap(stars: number, rand: () -> number): number
	local s = math.clamp(stars, 1, 5)
	local lo = 9 - s -- 8 .. 4
	local hi = 20 - 2 * s -- 18 .. 10
	return lo + rand() * (hi - lo)
end

-- Closing speed between a source and a listener (positive when approaching).
function Siren.closingSpeed(srcPos: Vector3, srcVel: Vector3, lisPos: Vector3, lisVel: Vector3): number
	local off = lisPos - srcPos
	local d = off.Magnitude
	if d < 1e-3 then
		return 0
	end
	local dir = off / d
	return srcVel:Dot(dir) - lisVel:Dot(dir)
end

return Siren
