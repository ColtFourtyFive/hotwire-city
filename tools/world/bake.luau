--!nocheck
-- Bake the v2 world: run the generator (tools/world/gen) and write its output as two data modules the game loads
-- instantly (MIGRATION.md §5, tech critique 8): src/shared/Config/WorldData.luau (core: server + clients) and
-- src/server/Config/WorldDataLots.luau (lots, spawns, streetscape...: server only, loaded lazily).
-- The serializer and the core / lots split live in bakelib.luau.
--
--   lune run tools/world/bake.luau            (bake)
--   lune run tools/world/bake.luau --check    (exit 1 when the baked files are out of date)
local fs = require("@lune/fs")
local process = require("@lune/process")
local generate = require("./gen")
local Bake = require("./bakelib")

local t0 = os.clock()
local W = generate()
local coreText, coreHash, lotsText, lotsHash = Bake.bake(W)
if process.args[1] == "--check" then
	local okCore = fs.isFile(Bake.CORE_PATH) and fs.readFile(Bake.CORE_PATH) == coreText
	local okLots = fs.isFile(Bake.LOTS_PATH) and fs.readFile(Bake.LOTS_PATH) == lotsText
	print(
		("check: core %s (%s), lots %s (%s)"):format(
			if okCore then "OK" else "STALE",
			coreHash,
			if okLots then "OK" else "STALE",
			lotsHash
		)
	)
	process.exit(if okCore and okLots then 0 else 1)
end
fs.writeFile(Bake.CORE_PATH, coreText)
fs.writeFile(Bake.LOTS_PATH, lotsText)
print(
	("baked in %.1fs: %s %d KB (%s), %s %d KB (%s)"):format(
		os.clock() - t0,
		Bake.CORE_PATH,
		#coreText // 1024,
		coreHash,
		Bake.LOTS_PATH,
		#lotsText // 1024,
		lotsHash
	)
)
