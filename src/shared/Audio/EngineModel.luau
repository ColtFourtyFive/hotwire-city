--!strict
-- EngineModel (PLAN C3 · audio): the fake RPM / gear model and the layer mix behind every car engine sound.
--
-- The arcade chassis (Shared/Vehicle/VehicleController) has no gearbox: it only knows speed, throttle and whether
-- the wheels touch the ground. This module turns that into an engine you can hear:
--   * gears from the speed fraction (speed / top speed) with the same shift points as the backfire VFX
--     (Config/VFX GEAR_SHIFTS), so an upshift's pitch drop and volume dip land on the exhaust pop;
--   * rpm = idle + band * speedFraction / gearTop (a ratio per gear), rate-limited (rev up fast, fall slower), a
--     clutch-slip floor in first gear (launch), free revving with throttle at standstill / held / in the air;
--   * a limiter bounce at the redline (rpm saw-tooths below it, each bounce is a pop candidate);
--   * load: on-throttle vs coasting, smoothed; the mixer crossfades on-load / off-load layers with it;
--   * mix(): idle / on-load / off-load layer volumes (equal power) and per-layer PlaybackSpeed from rpm / the rpm the
--     recording was made at (profile.idleRef / onRef / offRef), plus the shift-dip master gain.
-- Other players' and traffic cars have no throttle input on this client: inferThrottle() guesses it from acceleration.
-- lod(distance) is the remote-engine budget rule: 3 layers close, 1 layer mid, none far.
--
-- Pure: no Instances, no services. step() and mix() mutate caller-owned tables and allocate nothing per frame.

local EngineModel = {}

-- Same speed-fraction shift points as Config/VFX.GEAR_SHIFTS (asserted in tests/spec/audio.spec.luau).
EngineModel.SHIFTS = { 0.22, 0.42, 0.62, 0.82 }
EngineModel.SHIFT_HYSTERESIS = 0.04
EngineModel.FULL_RANGE = 60 -- remote engines: all three layers within this many studs
EngineModel.MAX_RANGE = 250 -- ...a single layer up to here, nothing beyond

export type Profile = {
	idleRpm: number,
	redline: number,
	shiftRpm: number, -- rpm at the top of a gear (where the upshift happens)
	launch: number, -- 0..1 of the rpm band held by clutch slip in first gear at full throttle
	revRate: number, -- rpm / s rising
	fallRate: number, -- rpm / s falling
	shiftTime: number, -- s of the upshift dip
	shiftDip: number, -- master gain at the bottom of the dip (0..1)
	limiterHz: number, -- limiter bounces per second
	limiterDepth: number, -- rpm the limiter drops each bounce
	idleRef: number, -- rpm the idle recording runs at (PlaybackSpeed 1)
	onRef: number, -- rpm the on-load recording runs at
	offRef: number, -- rpm the off-load recording runs at
	pitchMin: number,
	pitchMax: number,
	pops: boolean, -- exhaust pops on upshifts / limiter / lift-off at high rpm
	turbo: boolean, -- blow-off hiss on upshifts under boost
	shifts: { number }?, -- speed-fraction shift points (default EngineModel.SHIFTS)
}

local function profile(p: { [string]: any }): Profile
	local base: { [string]: any } = {
		idleRpm = 800,
		redline = 6500,
		shiftRpm = 6000,
		launch = 0.35,
		revRate = 9000,
		fallRate = 4200,
		shiftTime = 0.16,
		shiftDip = 0.55,
		limiterHz = 11,
		limiterDepth = 380,
		idleRef = 800,
		onRef = 3200,
		offRef = 3200,
		pitchMin = 0.55,
		pitchMax = 2.1,
		pops = false,
		turbo = false,
	}
	for k, v in p do
		base[k] = v
	end
	return (base :: any) :: Profile
end

-- One profile per engine set (Config/Sounds Eng_<Set>_* keys; Audio/EngineClass maps car classes to sets).
EngineModel.PROFILES = {
	compact = profile({ idleRpm = 850, redline = 6800, shiftRpm = 6300, revRate = 10500, onRef = 3400 }),
	sedan = profile({ idleRpm = 700, redline = 6000, shiftRpm = 5400, onRef = 2800, offRef = 2800 }),
	muscle = profile({
		idleRpm = 650,
		redline = 6200,
		shiftRpm = 5700,
		revRate = 8000,
		shiftTime = 0.2,
		shiftDip = 0.5,
		onRef = 3000,
		offRef = 2400,
		pops = true,
	}),
	sports = profile({
		idleRpm = 900,
		redline = 7800,
		shiftRpm = 7300,
		revRate = 12000,
		shiftTime = 0.12,
		onRef = 4200,
		offRef = 4200,
		pops = true,
		turbo = true,
	}),
	super = profile({
		idleRpm = 1000,
		redline = 8800,
		shiftRpm = 8400,
		revRate = 14000,
		fallRate = 5200,
		shiftTime = 0.09,
		shiftDip = 0.62,
		idleRef = 1000,
		onRef = 6000,
		offRef = 6000,
		pitchMin = 0.45,
		pops = true,
		turbo = true,
	}),
	truck = profile({
		idleRpm = 600,
		redline = 4200,
		shiftRpm = 3800,
		launch = 0.45,
		revRate = 4500,
		fallRate = 2600,
		shiftTime = 0.3,
		shiftDip = 0.45,
		limiterHz = 7,
		idleRef = 650,
		onRef = 2000,
		offRef = 1800,
		pitchMax = 1.8,
	}),
	bike = profile({
		idleRpm = 1200,
		redline = 11000,
		shiftRpm = 10200,
		revRate = 16000,
		fallRate = 7000,
		shiftTime = 0.08,
		limiterHz = 14,
		idleRef = 1200,
		onRef = 6500,
		offRef = 6500,
		pops = true,
	}),
	police = profile({
		idleRpm = 700,
		redline = 6400,
		shiftRpm = 5900,
		revRate = 9000,
		shiftTime = 0.15,
		onRef = 2900,
		offRef = 2500,
	}),
}

export type State = {
	rpm: number,
	gear: number, -- 0-based: number of shift points passed (0 = first gear)
	load: number, -- 0 coasting .. 1 full throttle (smoothed)
	dipT: number, -- s left in the current shift dip
	limiter: boolean, -- bouncing off the redline this step
	limPhase: number,
	free: boolean, -- revving without load (standstill / held / airborne)
	shifted: number, -- +1 upshift / -1 downshift happened this step, else 0
	pop: boolean, -- an exhaust pop is due this step (profile.pops)
	blowoff: boolean, -- a turbo blow-off is due this step (profile.turbo)
	prevThrottle: number,
}

function EngineModel.newState(p: Profile): State
	return {
		rpm = p.idleRpm,
		gear = 0,
		load = 0,
		dipT = 0,
		limiter = false,
		limPhase = 0,
		free = true,
		shifted = 0,
		pop = false,
		blowoff = false,
		prevThrottle = 0,
	}
end

-- Reset a state in place for a new car (pooled remote-engine slots reuse their tables: no allocation).
function EngineModel.reset(st: State, p: Profile, rpm: number?)
	st.rpm = rpm or p.idleRpm
	st.gear = 0
	st.load = 0
	st.dipT = 0
	st.limiter = false
	st.limPhase = 0
	st.free = true
	st.shifted = 0
	st.pop = false
	st.blowoff = false
	st.prevThrottle = 0
end

-- 0..1 position of rpm between idle and redline.
function EngineModel.rpm01(st: State, p: Profile): number
	return math.clamp((st.rpm - p.idleRpm) / math.max(p.redline - p.idleRpm, 1), 0, 1)
end

-- Gear (0-based) for a speed fraction with hysteresis: up as soon as a shift point is passed, down only
-- SHIFT_HYSTERESIS below it, one gear at a time per call.
function EngineModel.gearFor(current: number, frac: number, shifts: { number }): number
	local target = 0
	for _, s in shifts do
		if frac >= s then
			target += 1
		end
	end
	if target > current then
		return target
	end
	if target < current and frac < (shifts[current] or 0) - EngineModel.SHIFT_HYSTERESIS then
		return current - 1
	end
	return current
end

-- Advance the model. speedFrac = |speed| / topSpeed (nitro can push it past 1), throttle -1..1 (negative = brake /
-- reverse), grounded = at least two wheels on the ground, held = the car is held in place (handbrake, or the
-- wheels are blocked: stuck against a wall).
function EngineModel.step(
	st: State,
	p: Profile,
	dt: number,
	speedFrac: number,
	throttle: number,
	grounded: boolean,
	held: boolean
)
	local shifts = p.shifts or EngineModel.SHIFTS
	local f = math.clamp(math.abs(speedFrac), 0, 1.5)
	local thr = math.clamp(throttle, 0, 1)
	st.shifted = 0
	st.pop = false
	st.blowoff = false

	local free = (not grounded) or (held and f < 0.06)
	st.free = free
	if not free then
		local g = EngineModel.gearFor(st.gear, f, shifts)
		if g > st.gear then
			st.shifted = 1
			st.dipT = p.shiftTime
			if p.pops and thr > 0.5 then
				st.pop = true
			end
			if p.turbo and thr > 0.6 then
				st.blowoff = true
			end
		elseif g < st.gear then
			st.shifted = -1
		end
		st.gear = g
	end

	-- rpm target
	local band = p.shiftRpm - p.idleRpm
	local target: number
	if free then
		-- full throttle reaches the redline (and bounces off the limiter), part throttle holds below it
		target = p.idleRpm + (p.redline - p.idleRpm) * math.min(1, thr * 1.03)
	else
		local top = shifts[st.gear + 1] or 1
		target = p.idleRpm + band * f / math.max(top, 0.05)
		if st.gear == 0 then
			target = math.max(target, p.idleRpm + band * p.launch * thr)
		end
		if thr < 0.05 and st.gear == 0 and f < 0.02 then
			target = p.idleRpm
		end
	end
	target = math.clamp(target, p.idleRpm * 0.92, p.redline)

	-- rate limits (a shift drops fast: the clutch, not the flywheel)
	local fall = if st.dipT > 0 then p.fallRate * 3 else p.fallRate
	if target > st.rpm then
		st.rpm = math.min(target, st.rpm + p.revRate * dt)
	else
		st.rpm = math.max(target, st.rpm - fall * dt)
	end

	-- limiter bounce
	local atLimit = st.rpm >= p.redline - 1 and thr > 0.6
	if atLimit then
		local before = st.limPhase
		st.limPhase = (st.limPhase + dt * p.limiterHz) % 1
		if st.limPhase < before then
			-- a bounce: cut and come back
			st.rpm = p.redline - p.limiterDepth
			if p.pops then
				st.pop = true
			end
		end
	else
		st.limPhase = 0
	end
	st.limiter = atLimit

	-- lift-off at high rpm: a crackle on the overrun
	if p.pops and st.prevThrottle > 0.7 and thr < 0.2 and EngineModel.rpm01(st, p) > 0.6 then
		st.pop = true
	end
	st.prevThrottle = thr

	-- load (on-throttle vs coasting), smoothed
	local loadTarget = if free then thr * 0.65 else thr
	st.load += (loadTarget - st.load) * math.min(1, dt * 8)
	if st.dipT > 0 then
		st.dipT = math.max(0, st.dipT - dt)
	end
end

export type Mix = {
	idle: number,
	on: number,
	off: number,
	idlePitch: number,
	onPitch: number,
	offPitch: number,
	gain: number, -- master gain (rpm loudness x shift dip)
}

function EngineModel.newMix(): Mix
	return { idle = 0, on = 0, off = 0, idlePitch = 1, onPitch = 1, offPitch = 1, gain = 1 }
end

-- Master gain multiplier of the shift dip (1 outside a dip, p.shiftDip at its middle).
function EngineModel.dipGain(st: State, p: Profile): number
	if st.dipT <= 0 or p.shiftTime <= 0 then
		return 1
	end
	local progress = 1 - st.dipT / p.shiftTime
	return 1 - (1 - p.shiftDip) * math.sin(math.pi * progress)
end

-- Layer volumes (equal-power crossfades) and playback speeds for the current state. Writes into `out`.
function EngineModel.mix(st: State, p: Profile, out: Mix): Mix
	local r = EngineModel.rpm01(st, p)
	local idleW = math.clamp(1 - r / 0.28, 0, 1)
	local driveW = math.clamp((r - 0.03) / 0.22, 0, 1)
	local load = math.clamp(st.load, 0, 1)
	out.idle = math.sin(idleW * math.pi / 2)
	out.on = math.sin(driveW * math.pi / 2) * math.sin(load * math.pi / 2)
	out.off = math.sin(driveW * math.pi / 2) * math.cos(load * math.pi / 2) * 0.8
	out.idlePitch = math.clamp(st.rpm / p.idleRef, 0.7, 1.6)
	out.onPitch = math.clamp(st.rpm / p.onRef, p.pitchMin, p.pitchMax)
	out.offPitch = math.clamp(st.rpm / p.offRef, p.pitchMin, p.pitchMax)
	out.gain = (0.62 + 0.38 * r + 0.12 * load) * EngineModel.dipGain(st, p)
	return out
end

-- Throttle guess for a car we only see move (other players, traffic): accelerating = on load, steady cruise = part
-- load, slowing = off load. speeds in studs/s.
function EngineModel.inferThrottle(prevSpeed: number, speed: number, dt: number): number
	if dt <= 0 or speed < 1.5 then
		return 0
	end
	local accel = (speed - prevSpeed) / dt
	return math.clamp(0.35 + accel / 22, 0, 1)
end

-- Remote engine level of detail: 3 = idle/on/off layers, 1 = a single layer, 0 = silent.
function EngineModel.lod(distance: number): number
	if distance <= EngineModel.FULL_RANGE then
		return 3
	elseif distance <= EngineModel.MAX_RANGE then
		return 1
	end
	return 0
end

-- The profile for an engine set name (unknown -> sedan).
function EngineModel.profileFor(set: string): Profile
	return EngineModel.PROFILES[set] or EngineModel.PROFILES.sedan
end

return EngineModel
