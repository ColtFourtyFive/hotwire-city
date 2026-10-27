local Harness = require("../../tests/harness")
local W = Harness.require("src/shared/Config/WorldLayout")
local WG = Harness.require("src/shared/Util/WorldGen")
local comp, count, best, bestId = WG.scc(#W.Nodes, W._arcs)
print("SCC count", count, "largest", best, "of", #W.Nodes)
local byComp = {}
for i, c in comp do
	if c ~= bestId then
		byComp[c] = byComp[c] or {}
		table.insert(byComp[c], i)
	end
end
for c, list in byComp do
	local names = {}
	for _, n in list do
		for _, ei in W.Nodes[n].edges do
			names[W.Edges[ei].name .. "(" .. W.Edges[ei].class .. (W.Edges[ei].oneWay and ",1w" or "") .. ")"] = true
		end
	end
	local s = {}
	for k in names do table.insert(s, k) end
	local p = W.Nodes[list[1]].pos
	print(("comp %d size %d at (%d,%d,%d): %s"):format(c, #list, p.X, p.Y, p.Z, table.concat(s, ", ")))
end
-- one-way dead ends
for _, n in W.Nodes do
	local inb, outb = 0, 0
	for _, ei in n.edges do
		local e = W.Edges[ei]
		if not e.oneWay then inb += 1; outb += 1
		else
			if e.b == n.id then inb += 1 end
			if e.a == n.id then outb += 1 end
		end
	end
	if inb == 0 or outb == 0 then
		local names = {}
		for _, ei in n.edges do table.insert(names, W.Edges[ei].name) end
		print(("trap node %d (%d,%d,%d) in=%d out=%d: %s"):format(n.id, n.pos.X, n.pos.Y, n.pos.Z, inb, outb, table.concat(names, ", ")))
	end
end
for _, e in W.RouteErrors do print(e) end
print("dropped", #W.DroppedEdges)
for _, n in W.DroppedEdges do print("  drop", n) end
for k, v in W.Stats do print(k, v) end
for _, p in W.Plots do print(p.name, math.floor(p.nearestOnRamp)) end
