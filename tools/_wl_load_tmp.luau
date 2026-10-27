_G.WL_TIMING = true
local Harness = require("../tests/harness")
local t0 = os.clock()
local ok, W = pcall(Harness.require, "src/shared/Config/WorldLayout")
if not ok then print("ERR", W) return end
print("built in", os.clock() - t0)
for k, v in W.Stats do print(k, v) end
