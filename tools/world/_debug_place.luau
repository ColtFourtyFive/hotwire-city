local process = require("@lune/process")
_G.WL_DEBUG_PLACE = process.args[1] or "Arena"
local Harness = require("../../tests/harness")
local W = Harness.require("src/shared/Config/WorldLayout")
for _, e in W.PlacementErrors do print("placement:", e) end
