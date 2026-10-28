--!strict
-- LookClient (v2 look, owned by the look package with Config/Look + LightingService).
--
-- Preloads the faces of every SCHEDULED sky (Look.SkySchedule: day, blue, night, nightLate, dawn) in the background, a
-- few seconds after joining, so the first sky swap on this client (blue at 18:21, night at 19:30, nightLate at 00:00,
-- dawn at 05:00, day at 05:39 game time) does not stream 1024 px faces live (a face shared by several skies, like the
-- procedural skies' Dn, is loaded once): until a face arrives the engine shows it blank or stale (job 0009 shot half a
-- night sky black), a worse pop than the swap itself, worst on phones. The sky that comes up next is loaded first. The
-- server's sky
-- (Lighting attribute "Sky") is already on screen and goes last. Skies that are generated but not scheduled (golden,
-- dropped after lab round 2: its swap with the day sky could not be hidden) are not preloaded: six fewer 1024 px
-- textures in a phone's memory. A Studio edit-mode lab never sees the problem because Studio has the textures cached.
--
-- Nothing here touches the clock: Lighting.ClockTime is the server's ENGINE clock (held near the horizon at night,
-- Look.EngineClock); the game time of day is the Workspace attribute "TimeOfDay".
--
-- Base-material overrides (init): the place file's MaterialService.<Material>Name properties do not take effect in the
-- real engine (job 0009: GetBaseMaterialOverride read the stock names on the Client too), and the docs do not say
-- whether the server's SetBaseMaterialOverride replicates, so every client applies Look.Overrides itself
-- (Util/MaterialOverrides, idempotent, pcall'd). A variant that has not replicated yet is applied when it arrives
-- (MaterialService.ChildAdded); one warn after OVERRIDE_GRACE seconds lists any that never did.

local ContentProvider = game:GetService("ContentProvider")
local Lighting = game:GetService("Lighting")
local MaterialService = game:GetService("MaterialService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Look = require(ReplicatedStorage.Shared.Config.Look)
local MaterialOverrides = require(ReplicatedStorage.Shared.Util.MaterialOverrides)

local LookClient = {}

LookClient.PRELOAD_DELAY = 6 -- seconds after start (the loading screen and the first frames come first)
LookClient.OVERRIDE_GRACE = 15 -- seconds a missing MaterialVariant may take to replicate before the warn

local FACES = { "Bk", "Dn", "Ft", "Lf", "Rt", "Up" }

-- Scheduled sky names in the order they come up after `current` (Look.SkySchedule order, wrapping), `current` last
-- (when it is a known sky). Unscheduled skies are left out.
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
		if not seen[name] and name ~= current and Look.Skies[name] then
			seen[name] = true
			table.insert(out, name)
		end
	end
	if current ~= nil and Look.Skies[current] then
		table.insert(out, current)
	end
	return out
end

-- Content ids of every face, next sky first; an id shared by several skies is listed once (where it is first needed).
function LookClient.skyAssetList(current: string?): { string }
	local ids: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, name in LookClient.skyOrder(current) do
		local def = Look.Skies[name]
		if def then
			for _, f in FACES do
				local id = def.faces[f]
				if typeof(id) == "string" and id ~= "" and not seen[id] then
					seen[id] = true
					table.insert(ids, id)
				end
			end
		end
	end
	return ids
end

-- Base materials whose override is still waiting for its variant to replicate: variant name -> base material.
local pendingOverrides: { [string]: string } = {}
local lastResult: MaterialOverrides.Result? = nil

-- Applies every base-material override on this client; returns the result (tests, probes).
function LookClient.applyMaterialOverrides(): MaterialOverrides.Result
	local r = MaterialOverrides.apply("client", nil, true)
	table.clear(pendingOverrides)
	for variant, base in r.pending do
		pendingOverrides[variant] = base
	end
	lastResult = r
	if #r.missing == 0 then
		MaterialOverrides.report("client", r) -- prints, or warns about failures
	end
	return r
end

-- MaterialService.ChildAdded handler (a test hook too: the headless harness has no ChildAdded): a late variant gets
-- its override as soon as it replicates.
function LookClient._onMaterialAdded(child: Instance)
	local base = pendingOverrides[child.Name]
	if base == nil or not child:IsA("MaterialVariant") then
		return
	end
	local status, err = MaterialOverrides.applyOne(base, child.Name)
	if status == "set" or status == "already" then
		pendingOverrides[child.Name] = nil
		pcall(function()
			MaterialService:SetAttribute(MaterialOverrides.ATTRIBUTE, MaterialOverrides.countActive())
		end)
	elseif status == "failed" then
		pendingOverrides[child.Name] = nil
		warn(("[MaterialOverrides] client: %s -> %s failed: %s"):format(base, child.Name, err or "?"))
	end
end

-- Variants still missing (tests, the grace warn).
function LookClient.pendingOverrides(): { string }
	local out = {}
	for variant, base in pendingOverrides do
		table.insert(out, base .. " -> " .. variant)
	end
	table.sort(out)
	return out
end

function LookClient.init()
	local ok, err = pcall(LookClient.applyMaterialOverrides)
	if not ok then
		warn("[LookClient] material overrides: " .. tostring(err))
		return
	end
	if next(pendingOverrides) == nil then
		return
	end
	pcall(function()
		MaterialService.ChildAdded:Connect(LookClient._onMaterialAdded)
	end)
	task.delay(LookClient.OVERRIDE_GRACE, function()
		local r = lastResult
		local still = LookClient.pendingOverrides()
		if r and (#still > 0 or #r.failed > 0) then
			r.missing = still
			r.active = MaterialOverrides.countActive()
			MaterialOverrides.report("client", r)
		elseif r then
			print(
				("[MaterialOverrides] client: %d active (late variants applied)"):format(
					MaterialOverrides.countActive()
				)
			)
		end
	end)
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
