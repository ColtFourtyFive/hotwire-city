--!strict
-- ShotValidation (gta_combat §10.1-10.2, §10.7): the server's shot checks on PLAIN DATA, so every rule is unit-tested
-- without a game. WeaponService gathers the world facts (rewound head / part positions, ping, raycasts) and asks here.
--
-- Packet (client -> server, `WeaponFire`, reliable, <= 4 shots per packet, <= 20 packets/s):
--   { { w = weaponId, t = serverTimeAtTrigger, o = muzzleOrigin, d = unit aim dir (pre-spread), s = int seed,
--       a = aiming (bool), h = { { p = BasePart?, x = hitPoint, k = pelletIndex } }? }, ... }
-- Nothing in it is trusted: shapes, rates, times, origins, angles and targets are all re-checked; damage, health,
-- armor, ammo and zones are never read from the client at all.

local Weapons = require(script.Parent.Parent.Config.Weapons)
local Ballistics = require(script.Parent.Ballistics)

type WeaponDef = Weapons.WeaponDef

local ShotValidation = {}

ShotValidation.MAX_SHOTS = Weapons.SHOTS_PER_PACKET
ShotValidation.MAX_ID_LEN = 16
ShotValidation.UNIT_MIN = 0.98
ShotValidation.UNIT_MAX = 1.02
ShotValidation.FUTURE_SLACK = 0.05 -- a shot may claim at most this far into the server's future
ShotValidation.MAX_REWIND = 0.35
ShotValidation.ORIGIN_BASE = 6 -- muzzle within this of the (rewound) head, plus speed x rewind
ShotValidation.ANGLE_SLACK = 1.0 -- degrees on top of the weapon's max spread
ShotValidation.PELLET_SLACK = 1.5 -- degrees between a claimed pellet and its regenerated direction
ShotValidation.FACING_MAX = 100 -- degrees between the aim and the shooter's rewound facing (no shooting backwards)
ShotValidation.TARGET_BASE = 3.5
ShotValidation.TARGET_SPEED = 0.05
ShotValidation.TARGET_REWIND = 0.1
ShotValidation.OCCUPANT_SLACK = 1.5
ShotValidation.INTERP_DELAY = 0.1 -- client interpolation buffer: victims are sampled at t - (ping / 2 + this)
ShotValidation.MAX_SEED = 2 ^ 31 - 1

export type ClaimedHit = { p: any, x: Vector3, k: number }
export type Shot = { w: string, t: number, o: Vector3, d: Vector3, s: number, a: boolean, h: { ClaimedHit } }

-- AUDIT (§10.7) -----------------------------------------------------------------------------------------------------
-- Only claims an honest client can't make score. Lag can: a stale timestamp (jitter, a server hitch) and a facing
-- that hasn't replicated yet (turning to shoot behind you) only drop that shot's hits, like "state".
ShotValidation.WEIGHTS = {
	future = 3,
	stale = 0,
	origin = 3,
	los = 2,
	angle = 2,
	facing = 0,
	pellet = 2,
	target = 1,
	range = 1,
	rate = 1,
	ammo = 1,
	shape = 2,
	state = 0, -- dead / unequipped / reloading: normal lag, never suspicious
} :: { [string]: number }
ShotValidation.AUDIT_DECAY_PER_MIN = 10
ShotValidation.AUDIT_DROP = 30 -- above this: silently drop the player's hits for AUDIT_DROP_TIME
ShotValidation.AUDIT_DROP_TIME = 60
ShotValidation.AUDIT_KICK = 80 -- above this within AUDIT_KICK_WINDOW: kick (no automatic bans)
ShotValidation.AUDIT_KICK_WINDOW = 120
-- One packet (<= 4 shots, several pellets each) adds at most the largest single weight, so one burst of lag or one
-- bad shotgun blast can never stack a pellet-by-pellet score.
ShotValidation.PACKET_CAP = 0
for _, w in ShotValidation.WEIGHTS do
	ShotValidation.PACKET_CAP = math.max(ShotValidation.PACKET_CAP, w)
end

local function finite(n: any): boolean
	return typeof(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function finiteVector(v: any): boolean
	if typeof(v) ~= "Vector3" then
		return false
	end
	return finite(v.X)
		and finite(v.Y)
		and finite(v.Z)
		and math.abs(v.X) < 1e5
		and math.abs(v.Y) < 1e5
		and math.abs(v.Z) < 1e5
end
ShotValidation.finiteVector = finiteVector

function ShotValidation.isUnit(v: any): boolean
	if not finiteVector(v) then
		return false
	end
	local m = (v :: Vector3).Magnitude
	return m >= ShotValidation.UNIT_MIN and m <= ShotValidation.UNIT_MAX
end

-- 1. SHAPE. Returns (shot?, reason?). `isPart(p)` decides whether a claimed `p` is an acceptable BasePart reference
-- (injected so the pure module never touches instances). The weapon must be a known gun.
function ShotValidation.parseShot(raw: any, isPart: (any) -> boolean): (Shot?, string?)
	if typeof(raw) ~= "table" then
		return nil, "shape"
	end
	local w = raw.w
	if typeof(w) ~= "string" or #w == 0 or #w > ShotValidation.MAX_ID_LEN then
		return nil, "shape"
	end
	local def = Weapons.get(w)
	if not def or not Weapons.isGun(def) then
		return nil, "shape"
	end
	if not finite(raw.t) then
		return nil, "shape"
	end
	if not finiteVector(raw.o) or not ShotValidation.isUnit(raw.d) then
		return nil, "shape"
	end
	local s = raw.s
	if not finite(s) or s % 1 ~= 0 or s < 0 or s > ShotValidation.MAX_SEED then
		return nil, "shape"
	end
	local pellets = Weapons.pelletCount(def)
	local hits: { ClaimedHit } = {}
	if raw.h ~= nil then
		if typeof(raw.h) ~= "table" then
			return nil, "shape"
		end
		local seen: { [number]: boolean } = {}
		local n = 0
		for _, h in raw.h do
			n += 1
			if n > pellets then
				return nil, "shape"
			end
			if typeof(h) ~= "table" or not finiteVector(h.x) then
				return nil, "shape"
			end
			local k = h.k
			if not finite(k) or k % 1 ~= 0 or k < 1 or k > pellets or seen[k] then
				return nil, "shape"
			end
			seen[k] = true
			if h.p ~= nil and not isPart(h.p) then
				return nil, "shape"
			end
			table.insert(hits, { p = h.p, x = h.x, k = k })
		end
	end
	return {
		w = w,
		t = raw.t,
		o = raw.o,
		d = (raw.d :: Vector3).Unit,
		s = s,
		a = raw.a == true,
		h = hits,
	},
		nil
end

-- A packet is an array of 1..MAX_SHOTS shots.
function ShotValidation.packetSize(raw: any): number?
	if typeof(raw) ~= "table" then
		return nil
	end
	local n = #raw
	if n < 1 or n > ShotValidation.MAX_SHOTS then
		return nil
	end
	return n
end

-- 5. TIME. rewind = serverNow - t. pingRtt = Player:GetNetworkPing() (round trip, seconds).
function ShotValidation.checkTime(rewind: number, pingRtt: number): (boolean, string?)
	if rewind < -ShotValidation.FUTURE_SLACK then
		return false, "future"
	end
	local maxRewind = math.min(ShotValidation.MAX_REWIND, 2 * math.max(0, pingRtt) + 0.1)
	if rewind > maxRewind then
		return false, "stale"
	end
	return true, nil
end

-- 6. ORIGIN. head = shooter's rewound head position; speed = shooter speed (studs/s).
function ShotValidation.checkOrigin(origin: Vector3, head: Vector3, speed: number, rewind: number): boolean
	local limit = ShotValidation.ORIGIN_BASE + math.max(0, speed) * math.max(0, rewind)
	return (origin - head).Magnitude <= limit
end

-- 7a. DIRECTION (single-pellet): the claimed hit must lie within the weapon's max spread (+ slack) of the aim line.
function ShotValidation.checkAngle(def: WeaponDef, origin: Vector3, dir: Vector3, hitPoint: Vector3): boolean
	local to = hitPoint - origin
	if to.Magnitude < 0.5 then
		return true -- point blank: the angle is meaningless
	end
	return Ballistics.angleBetween(to, dir) <= Weapons.maxSpread(def) + ShotValidation.ANGLE_SLACK
end

-- 7b. DIRECTION (pellets): regenerate from the seed and compare each claimed pellet with its own direction.
function ShotValidation.expectedPellets(def: WeaponDef, dir: Vector3, seed: number, aiming: boolean): { Vector3 }
	local spread = if aiming then def.spreadAim else def.spreadHip
	return Ballistics.pellets(dir, spread, seed, Weapons.pelletCount(def))
end

function ShotValidation.checkPellet(expected: { Vector3 }, k: number, origin: Vector3, hitPoint: Vector3): boolean
	local e = expected[k]
	if not e then
		return false
	end
	local to = hitPoint - origin
	if to.Magnitude < 0.5 then
		return true
	end
	return Ballistics.angleBetween(to, e) <= ShotValidation.PELLET_SLACK
end

-- 7c. FACING: no shooting behind your own back. WeaponService accepts the rewound OR the live root look vector:
-- the turn to face the camera replicates a moment after the shot that caused it.
function ShotValidation.checkFacing(dir: Vector3, facing: Vector3): boolean
	local f = Vector3.new(facing.X, 0, facing.Z)
	local d = Vector3.new(dir.X, 0, dir.Z)
	if f.Magnitude < 1e-3 or d.Magnitude < 1e-3 then
		return true -- straight up / down
	end
	return Ballistics.angleBetween(d, f) <= ShotValidation.FACING_MAX
end

-- 8. RANGE.
function ShotValidation.checkRange(def: WeaponDef, origin: Vector3, hitPoint: Vector3): boolean
	return (hitPoint - origin).Magnitude <= def.maxRange + 1
end

-- 9. TARGET: claimed point near the victim part's rewound position.
function ShotValidation.targetTolerance(victimSpeed: number, rewind: number, occupant: boolean): number
	local v = math.max(0, victimSpeed)
	local tol = ShotValidation.TARGET_BASE
		+ v * ShotValidation.TARGET_SPEED
		+ ShotValidation.TARGET_REWIND * v * math.max(0, rewind)
	if occupant then
		tol += ShotValidation.OCCUPANT_SLACK
	end
	return tol
end

function ShotValidation.checkTarget(
	hitPoint: Vector3,
	partPos: Vector3,
	partSize: number,
	victimSpeed: number,
	rewind: number,
	occupant: boolean
): boolean
	local tol = ShotValidation.targetTolerance(victimSpeed, rewind, occupant) + math.max(0, partSize) * 0.5
	return (hitPoint - partPos).Magnitude <= tol
end

-- Time at which to sample victims: the shooter saw them about half a round trip plus the interpolation buffer
-- before the trigger time (§10.2 step 9, verification fix B15).
function ShotValidation.victimSampleTime(t: number, pingRtt: number): number
	return t - (math.max(0, pingRtt) / 2 + ShotValidation.INTERP_DELAY)
end

-- RATE: token bucket per weapon (cap 3 semi / pump, 4 auto; refill rpm / 60 x 1.1).
export type Bucket = { tokens: number, last: number, cap: number, rate: number }

function ShotValidation.newBucket(def: WeaponDef, now: number): Bucket
	local cap = if def.fireMode == "Auto" then 4 else 3
	return { tokens = cap, last = now, cap = cap, rate = def.rpm / 60 * 1.1 }
end

function ShotValidation.take(b: Bucket, now: number): boolean
	b.tokens = math.min(b.cap, b.tokens + math.max(0, now - b.last) * b.rate)
	b.last = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end

-- AUDIT bookkeeping ---------------------------------------------------------------------------------------------------
export type Audit = {
	score: number,
	at: number, -- last decay time
	dropUntil: number,
	window: { { t: number, w: number } }, -- weights added within the kick window
	reasons: { [string]: number },
	packet: number, -- weight added since the current packet began (at most PACKET_CAP)
}

function ShotValidation.newAudit(now: number): Audit
	return { score = 0, at = now, dropUntil = -math.huge, window = {}, reasons = {}, packet = 0 }
end

-- A new WeaponFire packet starts: its rejections share one PACKET_CAP budget.
function ShotValidation.beginPacket(a: Audit)
	a.packet = 0
end

function ShotValidation.decayAudit(a: Audit, now: number)
	local dt = math.max(0, now - a.at)
	a.at = now
	a.score = math.max(0, a.score - ShotValidation.AUDIT_DECAY_PER_MIN * dt / 60)
	local i = 1
	while i <= #a.window do
		if now - a.window[i].t > ShotValidation.AUDIT_KICK_WINDOW then
			table.remove(a.window, i)
		else
			i += 1
		end
	end
end

-- Adds a rejection. Returns "ok" | "drop" (start dropping hits) | "kick".
function ShotValidation.addAudit(a: Audit, reason: string, now: number): string
	ShotValidation.decayAudit(a, now)
	a.reasons[reason] = (a.reasons[reason] or 0) + 1
	local w = math.min(ShotValidation.WEIGHTS[reason] or 1, ShotValidation.PACKET_CAP - a.packet)
	if w <= 0 then
		return "ok"
	end
	a.packet += w
	a.score += w
	table.insert(a.window, { t = now, w = w })
	local inWindow = 0
	for _, e in a.window do
		inWindow += e.w
	end
	if inWindow > ShotValidation.AUDIT_KICK then
		return "kick"
	end
	if a.score > ShotValidation.AUDIT_DROP then
		if now >= a.dropUntil then
			a.dropUntil = now + ShotValidation.AUDIT_DROP_TIME
			return "drop"
		end
	end
	return "ok"
end

function ShotValidation.isDropping(a: Audit, now: number): boolean
	return now < a.dropUntil
end

return ShotValidation
