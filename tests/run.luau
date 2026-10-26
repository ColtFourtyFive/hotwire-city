--!nocheck
-- Runs every tests/spec/*.spec.luau. Each spec returns function(t) using t.test(name, fn), t.eq, t.ok, t.near.
-- Usage: lune run tests/run.luau [filter]
local fs = require("@lune/fs")
local process = require("@lune/process")
local Harness = require("./harness")

local filter = process.args[1]
local passed, failed = 0, 0
local failures = {}

local function makeT(file)
	local t = {}
	function t.ok(cond, msg)
		if not cond then
			error(msg or "assertion failed", 2)
		end
	end
	function t.eq(a, b, msg)
		if a ~= b then
			error(("%s: expected %s, got %s"):format(msg or "eq", tostring(b), tostring(a)), 2)
		end
	end
	function t.near(a, b, eps, msg)
		if math.abs(a - b) > (eps or 1e-6) then
			error(("%s: expected ~%s, got %s"):format(msg or "near", tostring(b), tostring(a)), 2)
		end
	end
	function t.test(name, fn)
		local ok, err = pcall(fn)
		if ok then
			passed += 1
		else
			failed += 1
			table.insert(failures, ("%s > %s\n    %s"):format(file, name, tostring(err)))
		end
	end
	t.H = Harness
	return t
end

local files = fs.readDir("tests/spec")
table.sort(files)
for _, f in files do
	if f:match("%.spec%.luau$") and (not filter or f:find(filter, 1, true)) then
		local ok, specOrErr = pcall(require, "./spec/" .. f:gsub("%.luau$", ""))
		if not ok then
			failed += 1
			table.insert(failures, f .. " failed to load: " .. tostring(specOrErr))
		else
			local ok2, err = pcall(specOrErr, makeT(f))
			if not ok2 then
				failed += 1
				table.insert(failures, f .. " crashed: " .. tostring(err))
			end
		end
	end
end

for _, msg in failures do
	print("FAIL " .. msg)
end
print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	process.exit(1)
end
