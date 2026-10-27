--!strict
-- AimAssist (gta_combat §11.2): pure target scoring + lock / friction / magnetism math. Touch and gamepad only.
--
--  * NPC cops and pedestrians: GTA "Assisted Aim - Partial" style lock. On aim press, lock the best target within
--    LOCK_ANGLE of the screen centre and LOCK_RANGE studs with line of sight; score = angle + distance + threat. The
--    lock follows the torso, breaks after LOCK_BREAK seconds (our value; Rockstar confirms a break timer, not its
--    length) and a flick (stick / swipe past FLICK_DEG) switches to the next target on that side.
--  * Players: friction (sensitivity x0.5 within 2 deg of the torso) + magnetism (15 % of the remaining angle per
--    second within 6 deg). No lock and no auto-fire against players, for every input type.
-- Settings "Aim Assist: Full / Light / Off" (Light = friction only).

local AimAssist = {}

AimAssist.LOCK_ANGLE = 22
AimAssist.LOCK_RANGE = 150
AimAssist.LOCK_BREAK = 2.5
AimAssist.FLICK_DEG = 8
AimAssist.FRICTION_ANGLE = 2
AimAssist.FRICTION_MULT = 0.5
AimAssist.MAGNET_ANGLE = 6
AimAssist.MAGNET_RATE = 0.15

export type Mode = "Full" | "Light" | "Off"
export type Candidate = {
	key: any,
	angle: number, -- degrees off the screen centre (camera look)
	distance: number,
	visible: boolean,
	threat: boolean, -- shooting at us right now
	isPlayer: boolean,
	side: number?, -- -1 left / +1 right of the current aim (for flick switching)
}

-- Lower is better.
function AimAssist.score(c: Candidate): number
	local s = c.angle / AimAssist.LOCK_ANGLE + c.distance / AimAssist.LOCK_RANGE * 0.6
	if c.threat then
		s -= 0.35
	end
	return s
end

-- Best lockable NPC target (players are never locked). Returns its key or nil.
function AimAssist.pickLock(candidates: { Candidate }, mode: Mode): any?
	if mode ~= "Full" then
		return nil
	end
	local best, bestScore = nil, math.huge
	for _, c in candidates do
		if not c.isPlayer and c.visible and c.angle <= AimAssist.LOCK_ANGLE and c.distance <= AimAssist.LOCK_RANGE then
			local s = AimAssist.score(c)
			if s < bestScore then
				best, bestScore = c.key, s
			end
		end
	end
	return best
end

-- Flick switching: the nearest-angle lockable target on `side` (-1 / +1) other than `current`.
function AimAssist.switchLock(candidates: { Candidate }, current: any, side: number): any?
	local best, bestAngle = nil, math.huge
	for _, c in candidates do
		if
			c.key ~= current
			and not c.isPlayer
			and c.visible
			and c.side == side
			and c.distance <= AimAssist.LOCK_RANGE
			and c.angle < bestAngle
		then
			best, bestAngle = c.key, c.angle
		end
	end
	return best
end

function AimAssist.lockExpired(lockedAt: number, now: number): boolean
	return now - lockedAt >= AimAssist.LOCK_BREAK
end

-- Sensitivity multiplier while the crosshair is near a target's torso (any target kind). Off = 1.
function AimAssist.friction(angleToTarget: number, mode: Mode): number
	if mode == "Off" then
		return 1
	end
	if angleToTarget <= AimAssist.FRICTION_ANGLE then
		return AimAssist.FRICTION_MULT
	end
	return 1
end

-- Fraction (0..1) of the remaining angle to pull toward the target this frame. Full mode only.
function AimAssist.magnetism(angleToTarget: number, dt: number, mode: Mode): number
	if mode ~= "Full" or angleToTarget > AimAssist.MAGNET_ANGLE or angleToTarget <= 0 then
		return 0
	end
	return math.clamp(AimAssist.MAGNET_RATE * dt, 0, 1)
end

-- Is the stick / swipe delta a flick? Returns -1 / +1 / 0.
function AimAssist.flick(deltaYawDeg: number): number
	if deltaYawDeg >= AimAssist.FLICK_DEG then
		return 1
	elseif deltaYawDeg <= -AimAssist.FLICK_DEG then
		return -1
	end
	return 0
end

return AimAssist
