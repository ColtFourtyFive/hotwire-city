--!strict
-- MaterialOverrides: applies Config/Look's global base-material overrides (Look.Overrides: Asphalt -> HC_Asphalt, ...)
-- at RUNTIME with MaterialService:SetBaseMaterialOverride.
--
-- Why (job 0009, real engine, v30): the uploaded place carries all 22 HC_ MaterialVariants, but
-- MaterialService:GetBaseMaterialOverride returned the STOCK names in Edit, on the Server and on the Client. The
-- file properties (MaterialService.AsphaltName = "HC_Asphalt" ..., written by tools/look/gen_project.py) do not take
-- effect, so the place file alone never activates our PBR materials. They stay in the file (harmless, and right if a
-- later engine honours them); this module makes the overrides real.
--
-- Where: the SERVER at boot (LightingService.init) and EVERY CLIENT (LookClient.init). The API docs do not say whether
-- the call replicates (the <Material>Name properties are not tagged NotReplicated, but the evidence above shows the
-- engine does not keep them as plain data either), so both sides apply it. Idempotent: an override that already
-- reads back as the wanted variant is not set again. Every call is pcall'd; one warn summarises anything missing or
-- failed. A variant that is not in MaterialService (yet: a client may run before the last one replicates) is
-- reported as missing and left alone: overriding to a non-existent variant does not error in the engine (probe
-- 2026-10-27) but would point the material at nothing. Clients retry those via applyOne when they arrive.
-- Published state: MaterialService attribute "HCOverridesActive" (how many overrides read back as wanted).

local MaterialService = game:GetService("MaterialService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Look = require(ReplicatedStorage.Shared.Config.Look)

local MaterialOverrides = {}

MaterialOverrides.ATTRIBUTE = "HCOverridesActive"

export type Result = {
	set: { string }, -- base materials whose override was (re)set and now reads back as wanted
	already: { string }, -- already active (nothing written)
	missing: { string }, -- "Asphalt -> HC_Asphalt": the variant is not under MaterialService
	pending: { [string]: string }, -- the missing ones as variant name -> base material (retry when they arrive)
	failed: { string }, -- "Asphalt -> HC_Asphalt: <error>" (bad enum, Set/Get error, or no read-back)
	active: number, -- overrides reading back as wanted after this call
}

-- Engine access (test hooks; the headless harness stubs the MaterialService methods).
function MaterialOverrides._get(material: Enum.Material): string
	return MaterialService:GetBaseMaterialOverride(material)
end
function MaterialOverrides._set(material: Enum.Material, name: string)
	MaterialService:SetBaseMaterialOverride(material, name)
end
function MaterialOverrides._hasVariant(name: string): boolean
	local v = MaterialService:FindFirstChild(name)
	return v ~= nil and v:IsA("MaterialVariant")
end

-- The wanted overrides as a sorted list of { base, variant } (deterministic order and summaries).
function MaterialOverrides.list(overrides: { [string]: string }?): { { base: string, variant: string } }
	local out = {}
	for base, variant in overrides or Look.Overrides do
		table.insert(out, { base = base, variant = variant })
	end
	table.sort(out, function(a, b)
		return a.base < b.base
	end)
	return out
end

local function materialOf(base: string): Enum.Material?
	local ok, mat = pcall(function()
		return (Enum.Material :: any)[base]
	end)
	if ok and typeof(mat) == "EnumItem" then
		return mat :: any
	end
	return nil
end

-- Applies one override. Returns "set" | "already" | "missing" | "failed" and an error text for "failed".
function MaterialOverrides.applyOne(base: string, variant: string): (string, string?)
	local mat = materialOf(base)
	if mat == nil then
		return "failed", "not an Enum.Material"
	end
	local okHas, has = pcall(MaterialOverrides._hasVariant, variant)
	if not okHas or not has then
		return "missing", nil
	end
	local okGet, current = pcall(MaterialOverrides._get, mat)
	if okGet and current == variant then
		return "already", nil
	end
	local okSet, err = pcall(MaterialOverrides._set, mat, variant)
	if not okSet then
		return "failed", tostring(err)
	end
	local okBack, back = pcall(MaterialOverrides._get, mat)
	if not okBack then
		return "failed", "read-back: " .. tostring(back)
	end
	if back ~= variant then
		return "failed", "read back " .. tostring(back)
	end
	return "set", nil
end

-- Applies every override (Look.Overrides by default). `label` names the side in the summary ("server" / "client").
-- `quiet` skips the warn (callers that retry later and summarise themselves).
function MaterialOverrides.apply(label: string, overrides: { [string]: string }?, quiet: boolean?): Result
	local r: Result = { set = {}, already = {}, missing = {}, pending = {}, failed = {}, active = 0 }
	for _, o in MaterialOverrides.list(overrides) do
		local status, err = MaterialOverrides.applyOne(o.base, o.variant)
		if status == "set" then
			table.insert(r.set, o.base)
		elseif status == "already" then
			table.insert(r.already, o.base)
		elseif status == "missing" then
			table.insert(r.missing, o.base .. " -> " .. o.variant)
			r.pending[o.variant] = o.base
		else
			table.insert(r.failed, ("%s -> %s: %s"):format(o.base, o.variant, err or "?"))
		end
	end
	r.active = #r.set + #r.already
	pcall(function()
		MaterialService:SetAttribute(MaterialOverrides.ATTRIBUTE, r.active)
	end)
	if not quiet then
		MaterialOverrides.report(label, r)
	end
	return r
end

-- One-line summary: a warn when anything is missing or failed, a plain print otherwise.
function MaterialOverrides.summary(label: string, r: Result): string
	local s = ("[MaterialOverrides] %s: %d active (%d set, %d already)"):format(label, r.active, #r.set, #r.already)
	if #r.missing > 0 then
		s ..= "; missing variant: " .. table.concat(r.missing, ", ")
	end
	if #r.failed > 0 then
		s ..= "; failed: " .. table.concat(r.failed, "; ")
	end
	return s
end

function MaterialOverrides.report(label: string, r: Result)
	if #r.missing > 0 or #r.failed > 0 then
		warn(MaterialOverrides.summary(label, r))
	else
		print(MaterialOverrides.summary(label, r))
	end
end

-- How many of the wanted overrides read back as wanted right now (probes, tests).
function MaterialOverrides.countActive(overrides: { [string]: string }?): number
	local n = 0
	for _, o in MaterialOverrides.list(overrides) do
		local mat = materialOf(o.base)
		if mat then
			local ok, cur = pcall(MaterialOverrides._get, mat)
			if ok and cur == o.variant then
				n += 1
			end
		end
	end
	return n
end

return MaterialOverrides
