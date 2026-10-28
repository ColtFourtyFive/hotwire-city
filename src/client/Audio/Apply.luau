--!strict
-- Apply (PLAN C3 · audio): turns a Config/Sounds def into Sound properties. Shared by SoundController's pools and the
-- Audio/* runtime modules so every Sound treats start / stop (PlaybackRegion), loopStart / loopEnd (LoopRegion, the
-- steady part of a long take) and lowpass the same way. Assigning an unchanged SoundId is a no-op, so pooled Sounds
-- do not reload.

local Apply = {}

export type Def = {
	id: string,
	volume: number,
	pitch: number?,
	looped: boolean?,
	start: number?,
	stop: number?,
	loopStart: number?,
	loopEnd: number?,
	lowpass: boolean?,
	rollOff: number?,
}

local LOWPASS_NAME = "HC_LowPass"
local FAR = 60000 -- "to the end" for regions

-- The low-pass EQ on a Sound (made once, then toggled).
function Apply.lowpass(sound: Sound, on: boolean, highGain: number?, midGain: number?)
	local eq = sound:FindFirstChild(LOWPASS_NAME)
	if not on then
		if eq and eq:IsA("EqualizerSoundEffect") then
			eq.Enabled = false
		end
		return
	end
	local e: EqualizerSoundEffect
	if eq and eq:IsA("EqualizerSoundEffect") then
		e = eq
	else
		e = Instance.new("EqualizerSoundEffect")
		e.Name = LOWPASS_NAME
		e.Parent = sound
	end
	e.HighGain = highGain or -22
	e.MidGain = midGain or -7
	e.LowGain = 2
	e.Enabled = true
end

-- Configure `sound` for `def` in `group`. Regions: a looped def with loopStart / loopEnd plays inside that region only;
-- a one-shot with start / stop plays that slice.
function Apply.def(sound: Sound, def: Def, group: SoundGroup?)
	sound.SoundId = def.id
	sound.Volume = def.volume
	sound.PlaybackSpeed = def.pitch or 1
	sound.SoundGroup = group
	sound.Looped = def.looped == true
	local ls, le = def.loopStart, def.loopEnd
	local st, en = def.start, def.stop
	if ls ~= nil or le ~= nil then
		pcall(function()
			sound.PlaybackRegionsEnabled = true
			local range = NumberRange.new(ls or 0, le or FAR)
			sound.PlaybackRegion = range
			sound.LoopRegion = range
		end)
	elseif st ~= nil or en ~= nil then
		pcall(function()
			sound.PlaybackRegionsEnabled = true
			sound.PlaybackRegion = NumberRange.new(st or 0, en or FAR)
			sound.LoopRegion = NumberRange.new(0, FAR)
		end)
	elseif sound.PlaybackRegionsEnabled then
		sound.PlaybackRegionsEnabled = false
	end
	if def.rollOff then
		sound.RollOffMaxDistance = def.rollOff
	end
	Apply.lowpass(sound, def.lowpass == true)
end

-- Where playback of `def` starts (inside its region).
function Apply.startTime(def: Def): number
	return def.loopStart or def.start or 0
end

return Apply
