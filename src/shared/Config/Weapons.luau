--!strict
-- Weapons (docs/v2/research/gta_combat.md §4, §5): every gun, melee weapon, armor plate, med kit and tint in the game.
-- Pure data + tiny lookups; the numbers here ARE the balance (Shared/Combat/* reads them, tests pin the TTK rules).
--
-- Parody names only in anything the player can read (no Glock / Beretta / HK / Colt). The real-world basis lives in
-- `basis`, which is internal and must never be shown in UI.
--
-- Units: damage in HP (health 100, armor up to 100), distances in studs (an R15 character is ~5.2 studs tall, so
-- visually 1 stud ~ 0.35 m), angles in degrees, times in seconds, fire rate in rounds per minute.
--
-- Meshes: `asset.mesh` is the hook for the final gun meshes. While `mesh.id` is 0 the Tool uses the part-built
-- placeholder from Shared/Combat/WeaponModels (correct real-world proportions, dark metal / polymer / wood). When an
-- id is set, WeaponService loads the Model at boot (InsertService for "owned", AssetService for "store"), scales its
-- longest axis to `mesh.length`, applies `mesh.rotation` so the barrel faces -Z, welds it to the Handle at
-- `mesh.offset` and hides the placeholder parts. Candidate sources: gta_combat §12.1 and cc0_assets.md (Objaverse
-- CC-BY GLBs uploaded with tools/upload_hero.py); see docs/v2/combat/WEAPON_ASSETS.md.

export type WeaponClass = "Melee" | "Handgun" | "SMG" | "Shotgun" | "Rifle" | "Gadget"
export type FireMode = "Semi" | "Auto" | "Pump" | "Melee"

export type Recoil = { pitchMin: number, pitchMax: number, yaw: number }

export type MeshHook = {
	source: "owned" | "store",
	id: number, -- 0 = no mesh yet (placeholder parts are used)
	length: number, -- studs along the mesh's longest axis after scaling
	rotation: CFrame, -- applied to the normalized mesh so its barrel faces -Z and its top faces +Y
	offset: Vector3, -- mesh center relative to the Handle (the grip)
}

export type AssetSpec = {
	model: string, -- Shared/Combat/WeaponModels builder key
	grip: CFrame, -- Tool.Grip
	muzzle: Vector3, -- Handle-local muzzle point (tracers / flashes start here)
	scale: number, -- multiplier on the placeholder builder (its sizes already include GTA's ~1.2x in-hand upscale)
	mesh: MeshHook,
}

export type AnimSet = { idle: string, aim: string, fire: string, reload: string, equip: string }

export type SoundSet = { shot: { string }, tail: { string }, mech: { string }, reload: { string } }

export type WeaponDef = {
	id: string,
	name: string,
	brand: string?,
	basis: string, -- internal only: the real-world reference (never shown)
	class: WeaponClass,
	description: string,
	order: number, -- shop order inside its class
	price: number,
	ammoPrice: number?, -- price of one ammo purchase (`ammoPerPurchase` rounds)
	ammoPerPurchase: number?,
	reserveCap: number?, -- max rounds in reserve (not counting the magazine)
	fireMode: FireMode,
	rpm: number,
	mag: number?,
	reloadTime: number?, -- tactical reload; an empty magazine adds EMPTY_RELOAD_EXTRA
	perShellReload: number?, -- shotguns load shell by shell (interruptible by firing)
	damage: number, -- per bullet / pellet / swing
	pellets: number?,
	headMult: number,
	limbMult: number,
	fullDist: number?, -- full damage inside this range
	zeroDist: number?, -- minMult from this range on
	minMult: number?,
	maxRange: number,
	spreadHip: number, -- degrees (cone half-angle)
	spreadAim: number,
	bloomPerShot: number?,
	bloomMax: number?, -- the widest a shot can ever leave the aim line (the server checks against this)
	recoil: Recoil,
	aimFov: number,
	scoped: boolean?,
	drawTime: number, -- equip time; also the Weapons Kit "StartupTime" (no firing before it ends)
	meleeReach: number?,
	meleeArc: number?, -- horizontal dot threshold of the melee cone
	asset: AssetSpec,
	anims: AnimSet,
	sounds: SoundSet,
	wheelSlot: number, -- 1..8, clockwise from the top (gta_ui_language §5.10)
	policeOnly: boolean?,
	unlock: string?, -- "always" | "free" | nil (bought)
}

export type ArmorDef = { id: string, name: string, description: string, amount: number, price: number }
export type MedKitDef = {
	id: string,
	name: string,
	description: string,
	heal: number,
	duration: number,
	price: number,
	carry: number,
	damageLock: number,
}
export type TintDef = { id: string, name: string, color: Color3, material: Enum.Material, price: number, order: number }

local Weapons = {}

-- Global combat constants -----------------------------------------------------------------------------------------------
Weapons.HIP_FOV = 70
Weapons.SPRINT_FOV = 75
Weapons.EMPTY_RELOAD_EXTRA = 0.3
Weapons.MOVE_SPREAD = 1.5
Weapons.SPRINT_SPREAD = 1.8
Weapons.AIR_SPREAD = 2.5
Weapons.BLOOM_RECOVER_DELAY = 0.15
Weapons.BLOOM_RECOVER_RATE = 6 -- degrees per second
Weapons.RECOIL_DECAY = 0.82 -- per 1/60 s
Weapons.TOTAL_RECOIL_MULT = 3 -- accumulated kick caps at 3x the weapon's max pitch
Weapons.MOBILE_RECOIL = 0.6
Weapons.FREE_MAGS_ON_BUY = 2
Weapons.OCCUPANT_MULT = 0.7 -- occupant hit through glass
Weapons.CAR_DAMAGE_MULT = 0.6 -- a bullet that hits the car body damages the car with this fraction
Weapons.TIRE_POP_TIME = 6
Weapons.TIRE_HIT_RADIUS = 1.5
Weapons.SHOTS_PER_PACKET = 4
Weapons.PACKETS_PER_SECOND = 20
Weapons.FX_RADIUS = 400
Weapons.MAX_PELLETS = 11

local function noMesh(length: number, offset: Vector3?): MeshHook
	return { source = "owned", id = 0, length = length, rotation = CFrame.new(), offset = offset or Vector3.zero }
end

local HANDGUN_ANIMS: AnimSet = {
	idle = "pistol_idle",
	aim = "pistol_idle",
	fire = "pistol_fire",
	reload = "pistol_reload",
	equip = "",
}
local LONG_ANIMS: AnimSet = {
	idle = "rifle_idle",
	aim = "rifle_aim",
	fire = "rifle_fire",
	reload = "rifle_reload",
	equip = "",
}
local MELEE_ANIMS: AnimSet = { idle = "", aim = "", fire = "melee_swing", reload = "", equip = "" }

-- Wheel slots, clockwise from the top (gta_ui_language §5.10).
Weapons.WHEEL_SLOTS = {
	{ slot = 1, key = "Handgun", label = "PISTOLS" },
	{ slot = 2, key = "SMG", label = "SMGS" },
	{ slot = 3, key = "Rifle", label = "RIFLES" },
	{ slot = 4, key = "Shotgun", label = "SHOTGUNS" },
	{ slot = 5, key = "Melee", label = "UNARMED / MELEE" },
	{ slot = 6, key = "Gadget", label = "TOOLS" },
	{ slot = 7, key = "Items", label = "ITEMS" },
	{ slot = 8, key = "Special", label = "SPECIAL" },
}

Weapons.CLASS_SLOT = {
	Handgun = 1,
	SMG = 2,
	Rifle = 3,
	Shotgun = 4,
	Melee = 5,
	Gadget = 6,
} :: { [string]: number }

Weapons.CLASS_LABEL = {
	Melee = "MELEE",
	Handgun = "HANDGUNS",
	SMG = "SUBMACHINE GUNS",
	Shotgun = "SHOTGUNS",
	Rifle = "RIFLES",
	Gadget = "TOOLS",
} :: { [string]: string }

-- Shop category order (GunShopUI).
Weapons.SHOP_CLASSES = { "Handgun", "SMG", "Shotgun", "Rifle", "Melee" }

Weapons.List = {
	-- MELEE ---------------------------------------------------------------------------------------------------------
	{
		id = "fists",
		name = "Fists",
		basis = "unarmed",
		class = "Melee",
		description = "Always with you.",
		order = 0,
		price = 0,
		fireMode = "Melee",
		rpm = 130,
		damage = 10,
		headMult = 1,
		limbMult = 1,
		maxRange = 4.5,
		spreadHip = 0,
		spreadAim = 0,
		recoil = { pitchMin = 0, pitchMax = 0, yaw = 0 },
		aimFov = 70,
		drawTime = 0.15,
		meleeReach = 4.5,
		meleeArc = 0.35,
		asset = { model = "fists", grip = CFrame.new(), muzzle = Vector3.zero, scale = 1, mesh = noMesh(0) },
		anims = MELEE_ANIMS,
		sounds = { shot = { "Melee_Punch1", "Melee_Punch2" }, tail = {}, mech = {}, reload = {} },
		wheelSlot = 5,
		unlock = "always",
	},
	{
		id = "bat",
		name = "Slugger Bat",
		basis = "wooden baseball bat",
		class = "Melee",
		description = "Ash wood, taped grip. Knocks drivers out of their seats.",
		order = 1,
		price = 0,
		fireMode = "Melee",
		rpm = 75,
		damage = 30,
		headMult = 1,
		limbMult = 1,
		maxRange = 7,
		spreadHip = 0,
		spreadAim = 0,
		recoil = { pitchMin = 0, pitchMax = 0, yaw = 0 },
		aimFov = 70,
		drawTime = 0.3,
		meleeReach = 7,
		meleeArc = 0.3,
		asset = {
			model = "bat",
			grip = CFrame.Angles(math.rad(20), 0, 0) * CFrame.new(0, -0.35, 0),
			muzzle = Vector3.new(0, 2.25, 0),
			scale = 1,
			mesh = noMesh(2.8, Vector3.new(0, 1, 0)),
		},
		anims = MELEE_ANIMS,
		sounds = { shot = { "Melee_Bat" }, tail = {}, mech = {}, reload = {} },
		wheelSlot = 5,
		unlock = "free",
	},
	{
		id = "knuckles",
		name = "Knuckle Dusters",
		basis = "brass knuckles",
		class = "Melee",
		description = "Brass. Makes a fist count.",
		order = 2,
		price = 500,
		fireMode = "Melee",
		rpm = 133,
		damage = 18,
		headMult = 1,
		limbMult = 1,
		maxRange = 4.5,
		spreadHip = 0,
		spreadAim = 0,
		recoil = { pitchMin = 0, pitchMax = 0, yaw = 0 },
		aimFov = 70,
		drawTime = 0.25,
		meleeReach = 4.5,
		meleeArc = 0.35,
		asset = {
			model = "knuckles",
			grip = CFrame.new(0, 0, 0),
			muzzle = Vector3.zero,
			scale = 1,
			mesh = noMesh(0.45),
		},
		anims = MELEE_ANIMS,
		sounds = { shot = { "Melee_Punch1", "Melee_Punch2" }, tail = {}, mech = {}, reload = {} },
		wheelSlot = 5,
	},
	{
		id = "crowbar",
		name = "Pry Bar",
		basis = "crowbar",
		class = "Melee",
		description = "Forged steel. Opens doors, closes arguments.",
		order = 3,
		price = 750,
		fireMode = "Melee",
		rpm = 92,
		damage = 28,
		headMult = 1,
		limbMult = 1,
		maxRange = 6.5,
		spreadHip = 0,
		spreadAim = 0,
		recoil = { pitchMin = 0, pitchMax = 0, yaw = 0 },
		aimFov = 70,
		drawTime = 0.3,
		meleeReach = 6.5,
		meleeArc = 0.3,
		asset = {
			model = "crowbar",
			grip = CFrame.Angles(math.rad(15), 0, 0) * CFrame.new(0, -0.3, 0),
			muzzle = Vector3.new(0, 1.5, -0.3),
			scale = 1,
			mesh = noMesh(1.9, Vector3.new(0, 0.7, 0)),
		},
		anims = MELEE_ANIMS,
		sounds = { shot = { "Melee_Metal" }, tail = {}, mech = {}, reload = {} },
		wheelSlot = 5,
	},
	{
		id = "nightstick",
		name = "Nightstick",
		basis = "side-handle police baton",
		class = "Melee",
		description = "Police issue.",
		order = 9,
		price = 0,
		fireMode = "Melee",
		rpm = 90,
		damage = 20,
		headMult = 1,
		limbMult = 1,
		maxRange = 6,
		spreadHip = 0,
		spreadAim = 0,
		recoil = { pitchMin = 0, pitchMax = 0, yaw = 0 },
		aimFov = 70,
		drawTime = 0.3,
		meleeReach = 6,
		meleeArc = 0.3,
		asset = {
			model = "nightstick",
			grip = CFrame.Angles(math.rad(15), 0, 0) * CFrame.new(0, -0.3, 0),
			muzzle = Vector3.new(0, 1.8, 0),
			scale = 1,
			mesh = noMesh(2),
		},
		anims = MELEE_ANIMS,
		sounds = { shot = { "Melee_Bat" }, tail = {}, mech = {}, reload = {} },
		wheelSlot = 5,
		policeOnly = true,
	},

	-- HANDGUNS ------------------------------------------------------------------------------------------------------
	{
		id = "pistol",
		name = "Kessler P9",
		brand = "Kessler Arms",
		basis = "Beretta 92-type 9 mm",
		class = "Handgun",
		description = "Full-size 9 mm service pistol. Reliable, accurate, 12 in the magazine.",
		order = 1,
		price = 1200,
		ammoPrice = 36,
		ammoPerPurchase = 12,
		reserveCap = 240,
		fireMode = "Semi",
		rpm = 360,
		mag = 12,
		reloadTime = 1.4,
		damage = 25,
		headMult = 1.6,
		limbMult = 0.75,
		fullDist = 70,
		zeroDist = 180,
		minMult = 0.6,
		maxRange = 250,
		spreadHip = 1.2,
		spreadAim = 0.4,
		bloomPerShot = 0.6,
		bloomMax = 3.0,
		recoil = { pitchMin = 1.2, pitchMax = 1.6, yaw = 0.25 },
		aimFov = 52,
		drawTime = 0.35,
		asset = {
			model = "pistol",
			grip = CFrame.new(0, 0, 0),
			muzzle = Vector3.new(0, 0.29, -0.64),
			scale = 1,
			mesh = noMesh(0.78, Vector3.new(0, 0.18, -0.2)),
		},
		anims = HANDGUN_ANIMS,
		sounds = {
			shot = { "Shot_Pistol" },
			tail = { "Tail_Gun1", "Tail_Gun2", "Tail_Gun3", "Tail_Gun4" },
			mech = {},
			reload = { "Reload_Mag" },
		},
		wheelSlot = 1,
	},
	{
		id = "handcannon",
		name = 'Brandt .50 "Hand Cannon"',
		brand = "Brandt & Sons",
		basis = "Desert Eagle-type .50",
		class = "Handgun",
		description = "Gas-operated .50 magnum. Seven rounds you will feel in your shoulder.",
		order = 2,
		price = 9500,
		ammoPrice = 70,
		ammoPerPurchase = 7,
		reserveCap = 84,
		fireMode = "Semi",
		rpm = 140,
		mag = 7,
		reloadTime = 1.8,
		damage = 50,
		headMult = 1.5,
		limbMult = 0.75,
		fullDist = 80,
		zeroDist = 200,
		minMult = 0.6,
		maxRange = 260,
		spreadHip = 2.0,
		spreadAim = 0.5,
		bloomPerShot = 1.5,
		bloomMax = 4.5,
		recoil = { pitchMin = 3.0, pitchMax = 3.8, yaw = 0.5 },
		aimFov = 52,
		drawTime = 0.4,
		asset = {
			model = "handcannon",
			grip = CFrame.new(0, 0, 0),
			muzzle = Vector3.new(0, 0.34, -0.87),
			scale = 1,
			mesh = noMesh(1.0, Vector3.new(0, 0.2, -0.28)),
		},
		anims = HANDGUN_ANIMS,
		sounds = {
			shot = { "Shot_HandCannon" },
			tail = { "Tail_Gun1", "Tail_Gun2", "Tail_Gun3", "Tail_Gun4" },
			mech = {},
			reload = { "Reload_Mag" },
		},
		wheelSlot = 1,
	},

	-- SMGS ----------------------------------------------------------------------------------------------------------
	{
		id = "microsmg",
		name = "Volk Micro SMG",
		brand = "Volk",
		basis = "Micro Uzi-type",
		class = "SMG",
		description = "Compact open-bolt machine pistol. 900 rounds a minute, if you can hold it.",
		order = 1,
		price = 6000,
		ammoPrice = 64,
		ammoPerPurchase = 32,
		reserveCap = 320,
		fireMode = "Auto",
		rpm = 900,
		mag = 32,
		reloadTime = 1.6,
		damage = 11,
		headMult = 1.4,
		limbMult = 0.75,
		fullDist = 30,
		zeroDist = 90,
		minMult = 0.5,
		maxRange = 160,
		spreadHip = 3.0,
		spreadAim = 1.6,
		bloomPerShot = 0.35,
		bloomMax = 5.5,
		recoil = { pitchMin = 0.35, pitchMax = 0.5, yaw = 0.6 },
		aimFov = 52,
		drawTime = 0.35,
		asset = {
			model = "microsmg",
			grip = CFrame.new(0, 0, 0),
			muzzle = Vector3.new(0, 0.27, -0.79),
			scale = 1,
			mesh = noMesh(1.05, Vector3.new(0, 0.16, -0.2)),
		},
		anims = HANDGUN_ANIMS,
		sounds = {
			shot = { "Shot_SMG" },
			tail = { "Tail_Gun1", "Tail_Gun2", "Tail_Gun3", "Tail_Gun4" },
			mech = {},
			reload = { "Reload_Mag" },
		},
		wheelSlot = 2,
	},
	{
		id = "tacsmg",
		name = "Brandt Tactical SMG",
		brand = "Brandt & Sons",
		basis = "MP5-type 9 mm",
		class = "SMG",
		description = "Roller-delayed 9 mm carbine. Controllable, quick, quiet enough.",
		order = 2,
		price = 24000,
		ammoPrice = 75,
		ammoPerPurchase = 30,
		reserveCap = 300,
		fireMode = "Auto",
		rpm = 780,
		mag = 30,
		reloadTime = 1.9,
		damage = 14,
		headMult = 1.4,
		limbMult = 0.75,
		fullDist = 45,
		zeroDist = 130,
		minMult = 0.55,
		maxRange = 220,
		spreadHip = 2.2,
		spreadAim = 0.8,
		bloomPerShot = 0.3,
		bloomMax = 4.0,
		recoil = { pitchMin = 0.3, pitchMax = 0.45, yaw = 0.3 },
		aimFov = 52,
		drawTime = 0.4,
		asset = {
			model = "tacsmg",
			grip = CFrame.new(0, 0, 0),
			muzzle = Vector3.new(0, 0.32, -1.33),
			scale = 1,
			mesh = noMesh(2.2, Vector3.new(0, 0.22, -0.25)),
		},
		anims = LONG_ANIMS,
		sounds = {
			shot = { "Shot_SMG" },
			tail = { "Tail_Gun1", "Tail_Gun2", "Tail_Gun3", "Tail_Gun4" },
			mech = {},
			reload = { "Reload_Mag" },
		},
		wheelSlot = 2,
	},

	-- SHOTGUN -------------------------------------------------------------------------------------------------------
	{
		id = "pump",
		name = "Coastline Pump Shotgun",
		brand = "Coastline Tactical",
		basis = "Mossberg 590-type 12 gauge",
		class = "Shotgun",
		description = "Eight-shot 12 gauge pump. Two to make sure.",
		order = 1,
		price = 15000,
		ammoPrice = 80,
		ammoPerPurchase = 8,
		reserveCap = 64,
		fireMode = "Pump",
		rpm = 70,
		mag = 8,
		perShellReload = 0.45,
		reloadTime = 0.45,
		damage = 8,
		pellets = 11,
		headMult = 1.0, -- no pellet headshots (no one-blast kill: 11 x 8 = 88 max)
		limbMult = 0.75,
		fullDist = 12,
		zeroDist = 45,
		minMult = 0.15,
		maxRange = 70,
		spreadHip = 5.5,
		spreadAim = 4.0,
		bloomMax = 5.5,
		recoil = { pitchMin = 3.5, pitchMax = 4.5, yaw = 0.4 },
		aimFov = 52,
		drawTime = 0.5,
		asset = {
			model = "pump",
			grip = CFrame.new(0, 0, 0),
			muzzle = Vector3.new(0, 0.39, -2.34),
			scale = 1,
			mesh = noMesh(3.2, Vector3.new(0, 0.25, -0.65)),
		},
		anims = LONG_ANIMS,
		sounds = {
			shot = { "Shot_Shotgun1", "Shot_Shotgun2", "Shot_Shotgun3", "Shot_Shotgun4" },
			tail = { "Tail_Shotgun1", "Tail_Shotgun2", "Tail_Shotgun3", "Tail_Shotgun4" },
			mech = { "Mech_PumpRack" },
			reload = { "Reload_Shell" },
		},
		wheelSlot = 4,
	},

	-- RIFLES --------------------------------------------------------------------------------------------------------
	{
		id = "comrade",
		name = 'Volk "Comrade" Assault Rifle',
		brand = "Volk",
		basis = "AK-type 7.62",
		class = "Rifle",
		description = "Stamped receiver, wood furniture, 7.62. Hits hard, kicks harder.",
		order = 1,
		price = 55000,
		ammoPrice = 120,
		ammoPerPurchase = 30,
		reserveCap = 300,
		fireMode = "Auto",
		rpm = 600,
		mag = 30,
		reloadTime = 2.3,
		damage = 20,
		headMult = 1.5,
		limbMult = 0.75,
		fullDist = 100,
		zeroDist = 260,
		minMult = 0.6,
		maxRange = 400,
		spreadHip = 1.8,
		spreadAim = 0.6,
		bloomPerShot = 0.35,
		bloomMax = 4.0,
		recoil = { pitchMin = 0.6, pitchMax = 0.85, yaw = 0.35 },
		aimFov = 48,
		drawTime = 0.5,
		asset = {
			model = "comrade",
			grip = CFrame.new(0, 0, 0),
			muzzle = Vector3.new(0, 0.31, -2.06),
			scale = 1,
			mesh = noMesh(2.95, Vector3.new(0, 0.22, -0.45)),
		},
		anims = LONG_ANIMS,
		sounds = {
			shot = { "Shot_Rifle" },
			tail = { "Tail_Rifle", "Tail_Gun1", "Tail_Gun2" },
			mech = {},
			reload = { "Reload_Mag" },
		},
		wheelSlot = 3,
	},
	{
		id = "carbine",
		name = "Coastline Carbine Rifle",
		brand = "Coastline Tactical",
		basis = "M4-type 5.56",
		class = "Rifle",
		description = "Direct-impingement 5.56 carbine with a red-dot optic. Flat, fast, accurate.",
		order = 2,
		price = 85000,
		ammoPrice = 120,
		ammoPerPurchase = 30,
		reserveCap = 300,
		fireMode = "Auto",
		rpm = 700,
		mag = 30,
		reloadTime = 2.1,
		damage = 18,
		headMult = 1.5,
		limbMult = 0.75,
		fullDist = 110,
		zeroDist = 280,
		minMult = 0.6,
		maxRange = 420,
		spreadHip = 1.4,
		spreadAim = 0.4,
		bloomPerShot = 0.3,
		bloomMax = 3.0,
		recoil = { pitchMin = 0.4, pitchMax = 0.6, yaw = 0.25 },
		aimFov = 48,
		drawTime = 0.5,
		asset = {
			model = "carbine",
			grip = CFrame.new(0, 0, 0),
			muzzle = Vector3.new(0, 0.33, -1.98),
			scale = 1,
			mesh = noMesh(2.85, Vector3.new(0, 0.25, -0.4)),
		},
		anims = LONG_ANIMS,
		sounds = {
			shot = { "Shot_Carbine1", "Shot_Carbine2", "Shot_Carbine3", "Shot_Carbine4" },
			tail = { "Tail_Rifle", "Tail_Gun1", "Tail_Gun2" },
			mech = {},
			reload = { "Reload_Mag" },
		},
		wheelSlot = 3,
	},
	{
		id = "marksman",
		name = "Volk Marksman Rifle",
		brand = "Volk",
		basis = "SVD-type 7.62x54R",
		class = "Rifle",
		description = "Semi-automatic designated marksman rifle with a 4x scope. Hold Shift to steady.",
		order = 3,
		price = 250000,
		ammoPrice = 250,
		ammoPerPurchase = 10,
		reserveCap = 60,
		fireMode = "Semi",
		rpm = 75,
		mag = 10,
		reloadTime = 2.6,
		damage = 60,
		headMult = 2.0,
		limbMult = 0.75,
		minMult = 1,
		maxRange = 900,
		spreadHip = 3.0,
		spreadAim = 0.0,
		bloomPerShot = 0,
		bloomMax = 3.0,
		recoil = { pitchMin = 4, pitchMax = 5, yaw = 0.5 },
		aimFov = 15,
		scoped = true,
		drawTime = 0.6,
		asset = {
			model = "marksman",
			grip = CFrame.new(0, 0, 0),
			muzzle = Vector3.new(0, 0.32, -2.72),
			scale = 1,
			mesh = noMesh(3.9, Vector3.new(0, 0.25, -0.7)),
		},
		anims = LONG_ANIMS,
		sounds = { shot = { "Shot_Marksman" }, tail = { "Tail_Rifle" }, mech = {}, reload = { "Reload_Mag" } },
		wheelSlot = 3,
	},
} :: { WeaponDef }

Weapons.ById = {} :: { [string]: WeaponDef }
Weapons.Index = {} :: { [string]: number } -- id -> u8 index for compact FX payloads
for i, def in Weapons.List do
	Weapons.ById[def.id] = def
	Weapons.Index[def.id] = i
end

-- Gadgets live in Config/Economy.Tools (taser, spikes); the wheel shows them in the TOOLS slot.
Weapons.GADGETS = { "taser", "spikes" }

-- Armor plates (consumable; lost on WASTED / BUSTED). gta_combat §5.2.
Weapons.Armor = {
	light = { id = "light", name = "Light Armor", description = "+50 armor.", amount = 50, price = 750 },
	heavy = { id = "heavy", name = "Heavy Armor", description = "+100 armor.", amount = 100, price = 1800 },
} :: { [string]: ArmorDef }
Weapons.ArmorOrder = { "light", "heavy" }

Weapons.MedKit = {
	id = "medkit",
	name = "Med Kit",
	description = "+40 health over 1.5 s. Carry up to 3. Not within 1 s of taking damage.",
	heal = 40,
	duration = 1.5,
	price = 400,
	carry = 3,
	damageLock = 1,
} :: MedKitDef

-- Tints (cosmetic only; never stats). Pink / neon tints are on the kill list.
Weapons.Tints = {
	black = {
		id = "black",
		name = "Black",
		color = Color3.fromRGB(32, 33, 36),
		material = Enum.Material.Metal,
		price = 0,
		order = 1,
	},
	army = {
		id = "army",
		name = "Army Green",
		color = Color3.fromRGB(74, 83, 58),
		material = Enum.Material.SmoothPlastic,
		price = 25000,
		order = 2,
	},
	tan = {
		id = "tan",
		name = "Desert Tan",
		color = Color3.fromRGB(176, 152, 112),
		material = Enum.Material.SmoothPlastic,
		price = 25000,
		order = 3,
	},
	gunmetal = {
		id = "gunmetal",
		name = "Gunmetal",
		color = Color3.fromRGB(78, 82, 88),
		material = Enum.Material.Metal,
		price = 25000,
		order = 4,
	},
	carbon = {
		id = "carbon",
		name = "Carbon",
		color = Color3.fromRGB(24, 24, 26),
		material = Enum.Material.Fabric,
		price = 25000,
		order = 5,
	},
	gold = {
		id = "gold",
		name = "Gold",
		color = Color3.fromRGB(196, 160, 76),
		material = Enum.Material.Metal,
		price = 2000000,
		order = 6,
	},
	platinum = {
		id = "platinum",
		name = "Platinum",
		color = Color3.fromRGB(196, 199, 204),
		material = Enum.Material.Metal,
		price = 2000000,
		order = 7,
	},
} :: { [string]: TintDef }

-- Lookups --------------------------------------------------------------------------------------------------------------

function Weapons.get(id: any): WeaponDef?
	if typeof(id) ~= "string" then
		return nil
	end
	return Weapons.ById[id]
end

function Weapons.isGun(def: WeaponDef?): boolean
	return def ~= nil and def.class ~= "Melee" and def.class ~= "Gadget"
end

function Weapons.isMelee(def: WeaponDef?): boolean
	return def ~= nil and def.class == "Melee"
end

-- Seconds between two shots / swings.
function Weapons.interval(def: WeaponDef): number
	return 60 / math.max(1, def.rpm)
end

-- Widest angle a shot can leave the aim line (degrees). Shots are always clamped to this, so the server can check it.
function Weapons.maxSpread(def: WeaponDef): number
	return def.bloomMax or def.spreadHip
end

function Weapons.pelletCount(def: WeaponDef): number
	return math.clamp(def.pellets or 1, 1, Weapons.MAX_PELLETS)
end

-- Weapons the shop sells (not police-only, not free starter gear), sorted by class then order.
function Weapons.shopList(): { WeaponDef }
	local out = {}
	for _, class in Weapons.SHOP_CLASSES do
		local inClass = {}
		for _, def in Weapons.List do
			if def.class == class and not def.policeOnly and def.unlock == nil then
				table.insert(inClass, def)
			end
		end
		table.sort(inClass, function(a, b)
			return a.order < b.order
		end)
		for _, def in inClass do
			table.insert(out, def)
		end
	end
	return out
end

-- Every weapon a player can hold in a wheel slot (owned map -> ids in that slot, sorted).
function Weapons.inSlot(slot: number, owned: { [string]: boolean }): { string }
	local out = {}
	for _, def in Weapons.List do
		if def.wheelSlot == slot and owned[def.id] then
			table.insert(out, def)
		end
	end
	table.sort(out, function(a, b)
		return a.order < b.order
	end)
	local ids = {}
	for _, def in out do
		table.insert(ids, def.id)
	end
	return ids
end

-- Shop stat bars, 0..1 each (GunShopUI): damage, fire rate, accuracy, range, clip.
function Weapons.statBars(
	def: WeaponDef
): { damage: number, rate: number, accuracy: number, range: number, clip: number }
	local perShot = def.damage * (def.pellets or 1)
	return {
		damage = math.clamp(perShot / 90, 0.05, 1),
		rate = math.clamp(def.rpm / 900, 0.05, 1),
		accuracy = math.clamp(1 - (def.spreadAim + (def.bloomMax or def.spreadHip) * 0.25) / 5, 0.05, 1),
		range = math.clamp((def.zeroDist or def.maxRange) / 500, 0.05, 1),
		clip = math.clamp((def.mag or 0) / 32, 0, 1),
	}
end

return Weapons
