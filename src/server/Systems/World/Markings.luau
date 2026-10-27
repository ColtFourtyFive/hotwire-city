--!strict
-- World/Markings: lane markings as ONE texture per road cross-section, laid on the asphalt top face (U = across the
-- road, StudsPerTileU = the curb-to-curb width; V = along the road, StudsPerTileV = PERIOD). A texture costs no part,
-- where painted strips would cost one part per line per segment (gta_realism_gap 2.5: markings are paint, not parts).
--
-- signature(edge) -> key, spec: the line layout of a cross-section (the single source of truth: tools/world/
-- markings_export.luau exports these specs, tools/world/markings.py paints them, uploads them as Image assets and
-- rewrites the GENERATED block below). Offsets x are studs from the centerline, + = right of the a -> b direction.
--
-- PERIOD = 120 studs: three 10-ft dash + 30-ft gap cycles (40) and five 24-stud parking stalls per tile, so dashes and
-- stall ticks stay continuous from segment to segment (OffsetStudsV carries the arc length).

local Markings = {}

Markings.PERIOD = 120
Markings.LINE = 0.45 -- 4-inch line (12 cm)

export type Line = { x: number, kind: string, x1: number? }
export type Spec = {
	key: string?,
	class: string,
	width: number,
	lines: { Line },
}

local MARKED: { [string]: boolean } = {
	freeway = true,
	ramp = true,
	highway = true,
	boulevard = true,
	avenue = true,
	street = true,
	rural = true,
	runway = true,
}

local function fmt(x: number): string
	return string.format("%g", math.floor(x * 100 + 0.5) / 100)
end

-- Lines of a cross-section (edge fields: class, oneWay, lanesF, lanesB, median, parking, width, shoulderOut,
-- shoulderIn, shoulder, laneWidth). nil for unmarked classes.
function Markings.signature(e: any): (string?, Spec)
	local spec: Spec = { class = e.class, width = e.width, lines = {} }
	if not MARKED[e.class] then
		return nil, spec
	end
	local L = e.laneWidth or 12.5
	local W = e.width
	local lines = spec.lines
	local function add(x: number, kind: string, x1: number?)
		table.insert(lines, { x = x, kind = kind, x1 = x1 })
	end
	local key = table.concat({
		e.class,
		if e.oneWay then "1w" else "2w",
		tostring(e.lanesF),
		tostring(e.lanesB),
		fmt(e.median),
		if e.parking then "p" else "n",
		fmt(W),
		fmt(e.shoulderOut),
		fmt(e.shoulderIn),
	}, "_")
	if e.class == "runway" then
		add(0, "runway_center")
		add(-W / 2 + 3, "white_solid")
		add(W / 2 - 3, "white_solid")
		return key, spec
	end
	if e.oneWay then
		local n = e.lanesF
		local margin = W - n * L
		local left = if e.class == "freeway" then e.shoulderIn else margin / 2
		local x0 = -W / 2 + left
		local x1 = x0 + n * L
		-- edge lines: yellow on the left of a divided carriageway, white on the right
		if e.class == "freeway" or e.class == "ramp" then
			add(x0, "yellow_solid")
			add(x1, "white_solid")
		elseif e.parking then
			add(x0, "white_solid")
			add(x1, "white_solid")
			add(-W / 2, "ticks", x0)
			add(x1, "ticks", W / 2)
		elseif margin > 1 then
			add(x0, "white_solid")
			add(x1, "white_solid")
		end
		for k = 1, n - 1 do
			add(x0 + k * L, "white_dash")
		end
		return key, spec
	end
	-- two-way
	local m = e.median
	local nF, nB = e.lanesF, e.lanesB
	if m > 0.5 then
		add(m / 2, "yellow_solid")
		add(-m / 2, "yellow_solid")
	elseif nF == 1 and nB == 1 and not e.parking and (e.class == "rural" or e.class == "street") then
		add(0, "yellow_dash")
	else
		add(0, "yellow_double")
	end
	for side = -1, 1, 2 do
		local n = if side > 0 then nF else nB
		local inner = m / 2
		for k = 1, n - 1 do
			add(side * (inner + k * L), "white_dash")
		end
		local outer = inner + n * L
		if e.parking then
			add(side * outer, "white_solid")
			if side > 0 then
				add(outer, "ticks", W / 2)
			else
				add(-W / 2, "ticks", -outer)
			end
		elseif W / 2 - outer > 1 then
			add(side * outer, "white_solid")
		end
	end
	return key, spec
end

-- BEGIN GENERATED (tools/world/markings.py) - do not edit by hand
Markings.Images = {
	["avenue_1w_2_0_0_n_25_0_0"] = "rbxassetid://114384167502209",
	["avenue_1w_2_0_0_n_31_3_3"] = "rbxassetid://131887872037335",
	["avenue_2w_2_2_0_n_50_0_0"] = "rbxassetid://134180500558331",
	["avenue_2w_2_2_0_p_68_0_0"] = "rbxassetid://90857744816586",
	["avenue_2w_2_2_10_p_78_0_0"] = "rbxassetid://84673443317621",
	["avenue_2w_2_2_18_p_86_0_0"] = "rbxassetid://121805229292130",
	["avenue_2w_2_2_6_n_56_0_0"] = "rbxassetid://126315578077978",
	["avenue_2w_2_2_8_p_76_0_0"] = "rbxassetid://122955146884443",
	["boulevard_2w_2_2_12_n_62_0_0"] = "rbxassetid://90601648269060",
	["boulevard_2w_2_2_16_p_84_0_0"] = "rbxassetid://136230618876917",
	["boulevard_2w_3_3_12_n_87_0_0"] = "rbxassetid://93573222353678",
	["freeway_1w_2_0_0_n_37_8_4"] = "rbxassetid://71985860450613",
	["freeway_1w_3_0_0_n_49.5_8_4"] = "rbxassetid://102972439694105",
	["freeway_1w_4_0_0_n_62_8_4"] = "rbxassetid://125911887042528",
	["highway_2w_2_2_16_n_80_7_7"] = "rbxassetid://140096196834494",
	["highway_2w_2_2_6_n_70_7_7"] = "rbxassetid://93550271768195",
	["ramp_1w_1_0_0_n_18.5_3_3"] = "rbxassetid://87520368257346",
	["ramp_2w_1_1_0_n_31_3_3"] = "rbxassetid://124896165960619",
	["runway_2w_2_2_0_n_100_25_25"] = "rbxassetid://124053425604102",
	["rural_2w_1_1_0_n_35_5_5"] = "rbxassetid://135673766816590",
	["street_1w_2_0_0_p_43_0_0"] = "rbxassetid://113236930645012",
	["street_2w_1_1_0_n_25_0_0"] = "rbxassetid://95183015830234",
	["street_2w_1_1_0_p_43_0_0"] = "rbxassetid://127560490432979",
} :: { [string]: string }
-- END GENERATED

-- Image for an edge's cross-section, or nil (unmarked class, or the texture is not uploaded yet).
function Markings.imageFor(e: any): string?
	local key = Markings.signature(e)
	if key == nil then
		return nil
	end
	return Markings.Images[key]
end

return Markings
