--!nocheck
-- Boot smoke test: every server system and client controller must load headlessly (no syntax errors,
-- no bad require paths, no top-level crashes) and return a table. Uses magic stubs for engine services.
return function(t)
	local H = t.H
	local fs = require("@lune/fs")
	local function modules(dir)
		local out = {}
		if not fs.isDir(dir) then
			return out
		end
		for _, f in fs.readDir(dir) do
			local name = f:match("^(.-)%.luau$")
			if name then
				table.insert(out, name)
			end
		end
		table.sort(out)
		return out
	end

	H.setMode("server")
	for _, name in modules("src/server/Systems") do
		t.test("server loads " .. name, function()
			local m = H.require("src/server/Systems/" .. name)
			t.ok(type(m) == "table", name .. " must return a table")
		end)
	end

	H.setMode("client")
	for _, name in modules("src/client/Controllers") do
		t.test("client loads " .. name, function()
			local m = H.require("src/client/Controllers/" .. name)
			t.ok(type(m) == "table", name .. " must return a table")
		end)
	end
	H.setMode("server")
end
