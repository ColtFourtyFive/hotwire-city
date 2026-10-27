--!nocheck
-- v1 hero shells (CarBuilder.applyShell / AssetLibrary Hero) only dress cars WITHOUT a v2 Model (Config/Vehicles):
-- every catalog car has one since wave A4, so the legacy hero-shell specs run with the catalog's `vehicle` fields
-- cleared. clear(Cars) returns the function that restores them (call it at the end of the spec).
local LegacyShells = {}

function LegacyShells.clear(Cars)
	local saved = {}
	local function strip(def)
		if def.vehicle ~= nil then
			saved[def] = def.vehicle
			def.vehicle = nil
		end
	end
	for _, def in Cars.List do
		strip(def)
	end
	for _, def in Cars.PoliceUnits or { Cars.Police } do
		strip(def)
	end
	return function()
		for def, v in saved do
			def.vehicle = v
		end
	end
end

return LegacyShells
