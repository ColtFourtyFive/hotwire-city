--!nocheck
-- Loader for the v2 world generator (tools/world/gen/WorldLayout.luau) under Lune.
--
--   local generate = require("./gen")      -- from tools/world, or require("../../tools/world/gen") from tests/spec
--   local W = generate()                    -- a fresh, deterministic build (about 4-6 s)
--
-- The generator is authoring tooling: it never ships in the place. It runs against the same shared modules the game
-- uses (Util/WorldGen, Util/WorldTerrain), resolved through the test harness's virtual Rojo tree, so the baked data
-- (tools/world/bake.luau -> Config/WorldData + server Config/WorldServerData) is exactly what this code produces.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Harness = require("../../tests/harness")

-- Phase 1 builds the road network (returns WorldLayout with a private `_ctx`); phase 2 adds everything placed on it.
local PHASES = { "tools/world/gen/WorldLayout.luau", "tools/world/gen/Places.luau" }

local function requireNode(node)
	local path = rawget(node, "__path")
	path = path:gsub("^%./", ""):gsub("%.luau$", "")
	return Harness.require(path)
end

return function()
	local shared = Harness.shared
	local env = setmetatable({
		game = {
			GetService = function(_, name)
				if name == "ReplicatedStorage" then
					return { Shared = shared }
				end
				error("generator: no service " .. tostring(name))
			end,
		},
		require = requireNode,
		Vector3 = Harness.roblox.Vector3,
		CFrame = Harness.roblox.CFrame,
	}, { __index = _G })
	local function load(path)
		return luau.load(fs.readFile(path), { debugName = path, environment = env })
	end
	local W = load(PHASES[1])()
	load(PHASES[2])()(W)
	W._ctx = nil
	return W
end
