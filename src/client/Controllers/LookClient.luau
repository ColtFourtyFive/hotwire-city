--!strict
-- LookClient (v2 look, owned by the look package with Config/Look + LightingService).
--
-- Preloads the faces of every HDRI sky (Look.Skies) in the background, a few seconds after joining, so the first sky
-- swap on this client (golden at 16:45, blue at 18:06, night at 19:30 ...) does not stream six 1024 px faces live:
-- until a face arrives the engine shows it blank or stale, a worse pop than the swap itself, worst on phones. The
-- sky that comes up next is loaded first. The server's sky (Lighting attribute "Sky") is already on screen and goes
-- last. A Studio edit-mode lab never sees the problem because Studio has the textures cached.

local ContentProvider = game:GetService("ContentProvider")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Look = require(ReplicatedStorage.Shared.Config.Look)

local LookClient = {}

LookClient.PRELOAD_DELAY = 6 -- seconds after start (the loading screen and the first frames come first)

local FACES = { "Bk", "Dn", "Ft", "Lf", "Rt", "Up" }

-- Sky names in the order they come up after `current` (Look.SkySchedule order, wrapping), `current` last.
function LookClient.skyOrder(current: string?): { string }
	local sched = Look.SkySchedule
	local start = 1
	for i, e in sched do
		if e.sky == current then
			start = i + 1
		end
	end
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	for k = 0, #sched - 1 do
		local name = sched[((start - 1 + k) % #sched) + 1].sky
		if not seen[name] and name ~= current then
			seen[name] = true
			table.insert(out, name)
		end
	end
	for name in Look.Skies do
		if not seen[name] and name ~= current then
			seen[name] = true
			table.insert(out, name)
		end
	end
	if current ~= nil and Look.Skies[current] then
		table.insert(out, current)
	end
	return out
end

-- Content ids of every face, next sky first.
function LookClient.skyAssetList(current: string?): { string }
	local ids: { string } = {}
	for _, name in LookClient.skyOrder(current) do
		local def = Look.Skies[name]
		if def then
			for _, f in FACES do
				local id = def.faces[f]
				if typeof(id) == "string" and id ~= "" then
					table.insert(ids, id)
				end
			end
		end
	end
	return ids
end

function LookClient.start()
	task.delay(LookClient.PRELOAD_DELAY, function()
		local current = Lighting:GetAttribute("Sky")
		local ids = LookClient.skyAssetList(if typeof(current) == "string" then current else nil)
		local ok, err = pcall(function()
			ContentProvider:PreloadAsync(ids :: { any })
		end)
		if not ok then
			warn("[LookClient] sky preload failed: " .. tostring(err))
		end
	end)
end

return LookClient
