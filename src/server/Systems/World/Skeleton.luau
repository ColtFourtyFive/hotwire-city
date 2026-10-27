--!strict
-- World/Skeleton: the persistent collision skeleton (tech critique 9).
--
-- With StreamingEnabled a client-owned car at 190 studs/s reaches an unloaded deck in about a second. Every elevated
-- edge, bridge span and the channel floor therefore gets invisible, collidable slabs in Map/Skeleton (a Persistent
-- Model: always replicated to every client), coarse (runs of <= 220 studs, 1.5 studs XZ / 0.4 Y tolerance) and
-- 0.06 under the visual road top, so cars ride the visual deck when it is streamed in and the skeleton when it is not.
--
-- Streaming.request(player) (World/Streaming) prefetches ahead of fast drivers; this is the floor that never leaves.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local WorldLayout = require(Shared.Config.WorldLayout)
local Kit = require(script.Parent.Kit)
local Roads = require(script.Parent.Roads)

type Ctx = Kit.Ctx

local Skeleton = {}

Skeleton.MAX_RUN = 220
Skeleton.SINK = 0.06

local Edges = WorldLayout.Edges

-- Coarse straight runs of edge ei between arc lengths s0 and s1.
local function coarse(ei: number, s0: number, s1: number): { Vector3 }
	local fine = Roads.runPoints(ei, s0, s1)
	local out: { Vector3 } = { fine[1] }
	local i = 1
	while i < #fine do
		local j = i + 1
		while j + 1 <= #fine do
			local a, b = fine[i], fine[j + 1]
			local ab = b - a
			local len = ab.Magnitude
			if len > Skeleton.MAX_RUN then
				break
			end
			local ok = true
			for k = i + 1, j do
				local p = fine[k]
				local t = math.clamp((p - a):Dot(ab) / math.max(len * len, 1e-9), 0, 1)
				local q = a + ab * t
				if math.sqrt((p.X - q.X) ^ 2 + (p.Z - q.Z) ^ 2) > 1.5 or math.abs(p.Y - q.Y) > 0.4 then
					ok = false
					break
				end
			end
			if not ok then
				break
			end
			j += 1
		end
		table.insert(out, fine[j])
		i = j
	end
	return out
end

local function emit(ctx: Ctx, parent: Model, ei: number, s0: number, s1: number)
	local e = Edges[ei]
	local pts = coarse(ei, s0, s1)
	local w = e.width + 2
	for k = 1, #pts - 1 do
		local a = pts[k] - Vector3.new(0, Skeleton.SINK, 0)
		local b = pts[k + 1] - Vector3.new(0, Skeleton.SINK, 0)
		local p = Roads.slab(ctx, "Skeleton", a, b, w, 2, 1, 1, Kit.style("invisible"), {
			parent = parent,
			transparency = 1,
			shadow = false,
			query = true,
		})
		if p then
			p.Locked = true
		end
	end
end

function Skeleton.build(ctx: Ctx): Model
	local m = Instance.new("Model")
	m.Name = "Skeleton"
	pcall(function()
		(m :: any).ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	end)
	m.Parent = ctx.root
	for ei, e in Edges do
		local L = Roads.cumOf(ei)[#e.points]
		if e.elevated or e.layer < 0 or e.class == "pier" then
			emit(ctx, m, ei, 0, L)
		else
			for _, sp in e.spans do
				emit(ctx, m, ei, math.max(0, sp[1] - 6), math.min(L, sp[2] + 6))
			end
		end
	end
	Kit.tick(ctx)
	return m
end

return Skeleton
