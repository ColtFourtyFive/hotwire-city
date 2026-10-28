--!strict
-- CreatorModel (C4a characters): the pure half of the character creator (client CharacterCreator), unit-tested.
--
--   rows(look, mode)            the GTA list menu (UI/ListMenu items): Body / Face / Skin tone / Hair / Hair color /
--                               Outfit style / Outfit / Walk style as "< value >" option rows, then Randomize, Save
--                               and (first join only) Skip
--   focusFor(field)             which framing a row wants: "face" (face, hair, hair color) or "body"
--   framing(origin, headY, focus, touch, yaw) -> (CFrame, fov)
--                               the orbit camera: full body or a head close-up, the character pushed right of the
--                               desktop list (or up, above the touch bottom sheet); yaw orbits round the character
--   standCFrame(origin, hip)    where the body stands (facing +Z, toward the camera)
--   studio()                    the local studio set: a lineup room with a height chart (parts + lights, offsets from
--                               the floor centre = the HC_Creator position the server hands out)
--   chartMarks()                height-chart lines and labels (feet), in studs above the floor
-- Scale: 1 stud ~ 0.28 m (gta_realism_gap §1), so a foot is 1.089 studs.

local PlayerLooks = require(script.Parent.Parent.Config.PlayerLooks)
local LookCodec = require(script.Parent.LookCodec)

local CreatorModel = {}

CreatorModel.FOV = 40 -- portrait lens
CreatorModel.FACE_DIST = 3.6
CreatorModel.BODY_MARGIN = 1.3 -- visible height / character height
CreatorModel.PITCH = math.rad(4) -- looking slightly down
CreatorModel.LATERAL = 0.16 -- desktop: the character sits this fraction of the view width right of centre
CreatorModel.TOUCH_LIFT = 0.18 -- touch: the character sits this fraction of the view height above centre
CreatorModel.FOOT = 0.3048 / 0.28 -- studs per foot

export type Mode = "first" | "wardrobe"
export type Focus = "face" | "body"

export type Row = {
	id: string,
	label: string,
	field: string?,
	options: { string }?,
	optionIndex: number?,
	value: string?,
	desc: string?,
	separator: boolean?,
}

CreatorModel.LABELS = {
	body = "Build",
	face = "Face",
	skin = "Skin tone",
	hair = "Hair",
	hairColor = "Hair color",
	outfit = "Outfit style",
	variant = "Outfit",
	walk = "Walk style",
} :: { [string]: string }

CreatorModel.DESCS = {
	body = "Height and build. Every frame is a realistic body.",
	face = "The head and its features.",
	skin = "Skin tone.",
	hair = "Haircut.",
	hairColor = "Hair color.",
	outfit = "Street, business, biker, beach or workwear.",
	variant = "Clothes within the style.",
	walk = "How you idle, walk and run.",
} :: { [string]: string }

local SECTIONS: { { label: string, fields: { string } } } = {
	{ label = "Appearance", fields = { "body", "face", "skin" } },
	{ label = "Hair", fields = { "hair", "hairColor" } },
	{ label = "Apparel", fields = { "outfit", "variant" } },
	{ label = "Movement", fields = { "walk" } },
}

-- The list menu rows for a look. Option rows carry `field`; the action rows have ids randomize / save / skip.
function CreatorModel.rows(look: LookCodec.Look, mode: Mode): { Row }
	local l = LookCodec.sanitize(look)
	local out: { Row } = {}
	for _, sec in SECTIONS do
		table.insert(out, { id = "sep_" .. string.lower(sec.label), label = sec.label, separator = true })
		for _, field in sec.fields do
			local desc = CreatorModel.DESCS[field]
			if field == "outfit" then
				desc = PlayerLooks.Outfits[l.outfit].desc
			elseif field == "walk" then
				desc = PlayerLooks.WalkStyles[l.walk].desc
			end
			table.insert(out, {
				id = field,
				label = CreatorModel.LABELS[field],
				field = field,
				options = LookCodec.options(field, l),
				optionIndex = (l :: any)[field],
				desc = desc,
			})
		end
	end
	table.insert(out, { id = "sep_done", label = "", separator = true })
	table.insert(out, {
		id = "randomize",
		label = "Randomize",
		value = "",
		desc = "A random realistic look. Keep pressing until you like one.",
	})
	if mode == "first" then
		table.insert(out, {
			id = "save",
			label = "Save and continue",
			value = "",
			desc = "Wear this look in the city. You can change it any time: Pause > Settings > Wardrobe.",
		})
		table.insert(out, {
			id = "skip",
			label = "Skip",
			value = "",
			desc = "Keep the look you are wearing and head straight into the city.",
		})
	else
		table.insert(out, {
			id = "save",
			label = "Save look",
			value = "",
			desc = "Wear this look from now on.",
		})
	end
	return out
end

function CreatorModel.focusFor(field: string?): Focus
	if field == "face" or field == "hair" or field == "hairColor" then
		return "face"
	end
	return "body"
end

-- Distance that fits a character `height` studs tall at the vertical `fovDeg` with BODY_MARGIN.
function CreatorModel.bodyDistance(height: number, fovDeg: number): number
	local h = math.max(2, height) * CreatorModel.BODY_MARGIN
	return h / (2 * math.tan(math.rad(fovDeg) / 2))
end

-- The orbit camera. `origin` = floor centre under the character, `headY` = its head's world Y, `yaw` = orbit angle
-- (0 = straight in front; the character faces +Z). Returns (camera CFrame, vertical FOV).
function CreatorModel.framing(
	origin: Vector3,
	headY: number,
	focus: Focus,
	touch: boolean,
	yaw: number
): (CFrame, number)
	local fov = CreatorModel.FOV
	local height = math.max(2, headY - origin.Y + 0.7)
	local target: Vector3
	local dist: number
	if focus == "face" then
		target = Vector3.new(origin.X, headY + 0.1, origin.Z)
		dist = CreatorModel.FACE_DIST
	else
		target = Vector3.new(origin.X, origin.Y + height * 0.5, origin.Z)
		dist = CreatorModel.bodyDistance(height, fov)
	end
	local viewH = 2 * dist * math.tan(math.rad(fov) / 2)
	local viewW = viewH * 16 / 9
	local lateral = if touch then 0 else -CreatorModel.LATERAL * viewW
	local lift = if touch then -CreatorModel.TOUCH_LIFT * viewH else 0
	local cf = CFrame.new(target)
		* CFrame.Angles(0, yaw, 0)
		* CFrame.Angles(-CreatorModel.PITCH, 0, 0)
		* CFrame.new(lateral, lift, dist)
	return cf, fov
end

-- Where the body stands: feet on the floor at `origin`, facing +Z. `hip` = root height above the floor.
function CreatorModel.standCFrame(origin: Vector3, hip: number): CFrame
	local p = origin + Vector3.new(0, math.max(1, hip) + 0.05, 0)
	return CFrame.lookAt(p, p + Vector3.new(0, 0, 1))
end

-- Studio set ------------------------------------------------------------------------------------------------------------

export type PartSpec = {
	name: string,
	size: Vector3,
	offset: Vector3, -- centre, from the floor centre
	color: Color3,
	material: string, -- Enum.Material name
	transparency: number,
	collide: boolean,
}

export type LightSpec = {
	name: string,
	kind: "Spot" | "Point",
	offset: Vector3,
	aim: Vector3?, -- spot lights point here (offset from the floor centre)
	brightness: number,
	range: number,
	angle: number?,
	color: Color3,
}

CreatorModel.ROOM = { halfW = 14, back = -6, front = 18, height = 16 }
CreatorModel.CHART_WIDTH = 14 -- studs of height-chart lines on the back wall

function CreatorModel.studio(): ({ PartSpec }, { LightSpec })
	local R = CreatorModel.ROOM
	local depth = R.front - R.back
	local midZ = (R.front + R.back) / 2
	local wall = Color3.fromRGB(46, 47, 50)
	local parts: { PartSpec } = {
		{
			name = "Floor",
			size = Vector3.new(R.halfW * 2 + 2, 1, depth + 2),
			offset = Vector3.new(0, -0.5, midZ),
			color = Color3.fromRGB(34, 34, 36),
			material = "Concrete",
			transparency = 0,
			collide = true,
		},
		{
			name = "BackWall",
			size = Vector3.new(R.halfW * 2 + 2, R.height, 1),
			offset = Vector3.new(0, R.height / 2, R.back - 0.5),
			color = Color3.fromRGB(58, 60, 64),
			material = "Concrete",
			transparency = 0,
			collide = true,
		},
		{
			name = "FrontWall",
			size = Vector3.new(R.halfW * 2 + 2, R.height, 1),
			offset = Vector3.new(0, R.height / 2, R.front + 0.5),
			color = wall,
			material = "Concrete",
			transparency = 0,
			collide = true,
		},
		{
			name = "LeftWall",
			size = Vector3.new(1, R.height, depth + 2),
			offset = Vector3.new(-R.halfW - 0.5, R.height / 2, midZ),
			color = wall,
			material = "Concrete",
			transparency = 0,
			collide = true,
		},
		{
			name = "RightWall",
			size = Vector3.new(1, R.height, depth + 2),
			offset = Vector3.new(R.halfW + 0.5, R.height / 2, midZ),
			color = wall,
			material = "Concrete",
			transparency = 0,
			collide = true,
		},
		{
			name = "Ceiling",
			size = Vector3.new(R.halfW * 2 + 2, 1, depth + 2),
			offset = Vector3.new(0, R.height + 0.5, midZ),
			color = Color3.fromRGB(20, 20, 22),
			material = "Concrete",
			transparency = 0,
			collide = true,
		},
	}
	local warm = Color3.fromRGB(255, 236, 214)
	local cool = Color3.fromRGB(205, 220, 255)
	local lights: { LightSpec } = {
		{
			name = "Key",
			kind = "Spot",
			offset = Vector3.new(-5, 10, 9),
			aim = Vector3.new(0, 3.2, 0),
			brightness = 4,
			range = 28,
			angle = 55,
			color = warm,
		},
		{
			name = "Rim",
			kind = "Spot",
			offset = Vector3.new(5, 11, -4),
			aim = Vector3.new(0, 3.5, 0),
			brightness = 3,
			range = 20,
			angle = 50,
			color = cool,
		},
		{
			name = "Fill",
			kind = "Point",
			offset = Vector3.new(3, 6, 11),
			brightness = 0.7,
			range = 22,
			color = warm,
		},
		{
			name = "Wall",
			kind = "Spot",
			offset = Vector3.new(0, 14, 2),
			aim = Vector3.new(0, 4, CreatorModel.ROOM.back),
			brightness = 1.4,
			range = 22,
			angle = 80,
			color = Color3.fromRGB(235, 235, 240),
		},
	}
	return parts, lights
end

export type Mark = { y: number, major: boolean, label: string? }

-- Height-chart marks every half foot from 1 to 7 ft (labels on whole feet: 4', 5', ...).
function CreatorModel.chartMarks(): { Mark }
	local out: { Mark } = {}
	for half = 2, 14 do
		local feet = half / 2
		local major = half % 2 == 0
		table.insert(out, {
			y = feet * CreatorModel.FOOT,
			major = major,
			label = if major then string.format("%d'", feet) else nil,
		})
	end
	return out
end

return CreatorModel
