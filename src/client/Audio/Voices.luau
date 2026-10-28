--!strict
-- Voices (PLAN C3 · audio): every one-shot the client plays, from fixed pools (no Instance.new per shot / impact).
--
--  * play2D(key, def, group, priority)      a 2D one-shot (UI, dispatch blips, overhead planes): up to PER_KEY copies
--                                            of one key in SoundService.HC_Voices, the oldest copy is restarted.
--  * playAt(def, pos, group, priority, volumeMult?, lowpass?, force?, rollOff?)
--                                            a 3D one-shot: WORLD_POOL emitters (Attachments on one anchored,
--                                            invisible part in Workspace.HC_ClientSounds) moved to `pos`. Beyond CULL
--                                            studs from the camera it is skipped unless `force` (gun tails, far sirens).
--  * Global cap: at most Mix.MAX_VOICES one-shots at once. When full, a new sound plays only by stealing an older
--    one of strictly lower priority (Mix.admit / Mix.PRIORITY); otherwise it is dropped.
--  * Emitters (emitter() / releaseEmitter()): pooled Attachments for loops that follow a moving car or heli (the
--    loop Sounds live on our own anchor, never inside a car: a car that despawns or streams out cannot take them
--    with it, and nothing has to be re-created).
-- Defs go through Audio/Apply (regions, low-pass, roll-off) so every pooled Sound plays its def the same way.

local Workspace = game:GetService("Workspace")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Mix = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Audio"):WaitForChild("Mix"))
local Apply = require(script.Parent:WaitForChild("Apply"))

local Voices = {}

Voices.WORLD_POOL = 28
Voices.PER_KEY = 4
Voices.CULL = 450
Voices.DEFAULT_ROLLOFF = 320
Voices.MAX = Mix.MAX_VOICES

type Def = Apply.Def
type Entry = { sound: Sound, att: Attachment?, startedAt: number, priority: number }

local rng = Random.new()
local folder: Folder? = nil
local anchor: Part? = nil
local world: { Entry } = {}
local flat: { [string]: { Entry } } = {}
local freeEmitters: { Attachment } = {}
local dropped = 0

local function ensureFolder(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local existing = SoundService:FindFirstChild("HC_Voices")
	if existing and existing:IsA("Folder") then
		f = existing
	else
		local made = Instance.new("Folder")
		made.Name = "HC_Voices"
		made.Parent = SoundService
		f = made
	end
	folder = f
	table.clear(flat) -- pooled 2D Sounds died with an old folder
	return f :: Folder
end

-- The anchored part every 3D emitter hangs from.
function Voices.anchor(): Part
	local a = anchor
	if a and a.Parent then
		return a
	end
	local holder = Workspace:FindFirstChild("HC_ClientSounds")
	if not holder then
		holder = Instance.new("Folder")
		holder.Name = "HC_ClientSounds"
		holder.Parent = Workspace
	end
	local part = Instance.new("Part")
	part.Name = "SoundAnchor"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.CFrame = CFrame.new()
	part.Parent = holder
	anchor = part
	table.clear(world) -- pooled emitters died with the old anchor
	table.clear(freeEmitters)
	return part
end

-- A pooled emitter Attachment for a loop that follows something (position it with WorldPosition every frame).
function Voices.emitter(name: string): Attachment
	local a = Voices.anchor()
	local att = table.remove(freeEmitters)
	if att and att.Parent == a then
		att.Name = name
		return att
	end
	local made = Instance.new("Attachment")
	made.Name = name
	made.Parent = a
	return made
end

function Voices.releaseEmitter(att: Attachment)
	for _, child in att:GetChildren() do
		if child:IsA("Sound") then
			child:Stop()
		end
	end
	table.insert(freeEmitters, att)
end

-- A looping 3D Sound on its own emitter (callers keep both; nothing is destroyed afterwards).
function Voices.loopAt(name: string): (Attachment, Sound)
	local att = Voices.emitter(name)
	local s = att:FindFirstChildOfClass("Sound")
	if not s then
		local made = Instance.new("Sound")
		made.Name = name
		made.RollOffMode = Enum.RollOffMode.InverseTapered
		made.RollOffMinDistance = 14
		made.RollOffMaxDistance = 260
		made.Looped = true
		made.Parent = att
		s = made
	end
	return att, s :: Sound
end

-- A looping 2D Sound (wind, beds, the distant siren layer, radio decks).
function Voices.loop2D(name: string): Sound
	local f = ensureFolder()
	local s = Instance.new("Sound")
	s.Name = name
	s.Looped = true
	s.Volume = 0
	s.Parent = f
	return s
end

-------------------------------------------------------------------------------------------------------------------------
-- Voice budget
-------------------------------------------------------------------------------------------------------------------------

-- Is `e` a better steal victim than `victim` (lower priority, then older)?
local function worse(e: Entry, victim: Entry?): boolean
	if victim == nil then
		return true
	end
	return e.priority < victim.priority or (e.priority == victim.priority and e.startedAt < victim.startedAt)
end

-- (playing count, lowest playing priority, the oldest entry at that priority)
local function census(): (number, number?, Entry?)
	local count = 0
	local victim: Entry? = nil
	for _, e in world do
		if e.sound.IsPlaying then
			count += 1
			if worse(e, victim) then
				victim = e
			end
		end
	end
	for _, list in flat do
		for _, e in list do
			if e.sound.IsPlaying then
				count += 1
				if worse(e, victim) then
					victim = e
				end
			end
		end
	end
	return count, if victim then victim.priority else nil, victim
end

-- May a voice of `priority` start now? Stops the victim when it steals one.
local function admit(priority: number): boolean
	local count, lowest, victim = census()
	local ok, steal = Mix.admit(count, Voices.MAX, priority, lowest)
	if not ok then
		dropped += 1
		return false
	end
	if steal and victim then
		victim.sound:Stop()
	end
	return true
end

local function variedPitch(def: Def): number
	local spread = (def :: any).pitchVar
	local v = if typeof(spread) == "number" then spread else 0.04
	return (def.pitch or 1) * (1 + rng:NextNumber(-v, v))
end

-------------------------------------------------------------------------------------------------------------------------
-- Playback
-------------------------------------------------------------------------------------------------------------------------

function Voices.play2D(key: string, def: Def, group: SoundGroup?, priority: number?, volumeMult: number?): Sound?
	local pr = priority or Mix.PRIORITY.ui
	local f = ensureFolder()
	local list = flat[key]
	if not list then
		list = {}
		flat[key] = list
	end
	local pick: Entry? = nil
	for _, e in list do
		if e.sound.Parent == f and not e.sound.IsPlaying then
			pick = e
			break
		end
	end
	if not pick and #list < Voices.PER_KEY then
		local s = Instance.new("Sound")
		s.Name = key
		s.Parent = f
		pick = { sound = s, startedAt = 0, priority = pr }
		table.insert(list, pick :: Entry)
	end
	if not pick then
		local oldest = list[1]
		for _, e in list do
			if e.startedAt < oldest.startedAt then
				oldest = e
			end
		end
		pick = oldest
	elseif not admit(pr) then
		return nil
	end
	local e = pick :: Entry
	if e.sound.Parent ~= f then
		e.sound.Parent = f
	end
	Apply.def(e.sound, def, group)
	e.sound.Looped = false
	e.sound.Volume = def.volume * (volumeMult or 1)
	e.sound.PlaybackSpeed = variedPitch(def)
	e.sound.TimePosition = Apply.startTime(def)
	e.sound:Play()
	e.startedAt = os.clock()
	e.priority = pr
	return e.sound
end

function Voices.playAt(
	def: Def,
	position: Vector3,
	group: SoundGroup?,
	priority: number?,
	volumeMult: number?,
	lowpass: boolean?,
	force: boolean?,
	rollOff: number?
): Sound?
	local cam = Workspace.CurrentCamera
	if not force and cam and (cam.CFrame.Position - position).Magnitude > Voices.CULL then
		return nil
	end
	local pr = priority or Mix.PRIORITY.world
	local a = Voices.anchor()
	local pick: Entry? = nil
	for _, e in world do
		if e.att and e.att.Parent == a and not e.sound.IsPlaying then
			pick = e
			break
		end
	end
	if not pick then
		if #world < Voices.WORLD_POOL then
			local att = Instance.new("Attachment")
			att.Name = "Voice"
			att.Parent = a
			local s = Instance.new("Sound")
			s.RollOffMode = Enum.RollOffMode.InverseTapered
			s.RollOffMinDistance = 12
			s.Parent = att
			pick = { sound = s, att = att, startedAt = 0, priority = pr }
			table.insert(world, pick :: Entry)
		else
			-- pool full: the oldest of the lowest priority, if it is not above ours
			local victim: Entry? = nil
			for _, e in world do
				if e.priority <= pr and worse(e, victim) then
					victim = e
				end
			end
			if not victim then
				dropped += 1
				return nil
			end
			pick = victim
		end
	end
	local e = pick :: Entry
	if e.sound.IsPlaying then
		e.sound:Stop() -- the reused emitter's old voice ends here (it no longer counts against the cap)
	end
	if not admit(pr) then
		return nil
	end
	local att = e.att :: Attachment
	if att.Parent ~= a then
		att.Parent = a
	end
	att.WorldPosition = position
	Apply.def(e.sound, def, group)
	e.sound.RollOffMaxDistance = rollOff or def.rollOff or Voices.DEFAULT_ROLLOFF
	e.sound.Looped = false
	e.sound.Volume = def.volume * (volumeMult or 1)
	e.sound.PlaybackSpeed = variedPitch(def)
	e.sound.TimePosition = Apply.startTime(def)
	if lowpass then
		Apply.lowpass(e.sound, true, -18, -6)
	end
	e.sound:Play()
	e.startedAt = os.clock()
	e.priority = pr
	return e.sound
end

-- (playing one-shots, pool size, one-shots refused by the cap so far): debug / tests.
function Voices.stats(): (number, number, number)
	local count = census()
	local size = #world
	for _, list in flat do
		size += #list
	end
	return count, size, dropped
end

return Voices
