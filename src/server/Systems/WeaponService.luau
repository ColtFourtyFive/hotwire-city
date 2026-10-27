--!strict
-- WeaponService (gta_combat §4, §10): weapon inventory, Tools, equip / holster, server-authoritative ammo and reloads,
-- the hitscan shot validation pipeline, melee, ShotAudit, and the cosmetic ShotFx relay.
--
-- Inventory: data.weapons[id] = { ammo = magazine + reserve, tint } (schema v2). Fists are implicit (no Tool: an
-- empty hand punches). Each owned weapon is ONE Tool in the Backpack, built from Shared/Combat/WeaponModels (or the
-- uploaded mesh, Config/Weapons asset.mesh) with attribute WeaponId. The Backpack CoreGui is off (weapon wheel):
-- clients ask with WeaponEquip; the server equips (Humanoid:EquipTool) after DamageService.canDraw (safe zones,
-- passive, rookie, weapons lock), and puts back any Tool a client equips on its own where it may not.
--
-- Shots (WeaponFire, <= 4 per packet, <= 20 packets/s) run §10.2 in order; a failed check drops that shot's hits
-- (or the packet) and scores the ShotAudit:
--   1 shape  2 state (alive, owned + equipped, draw time done, not reloading / seated / stunned / safe)  3 rate (token
--   bucket per weapon)  4 ammo (server magazine), then the muzzle must be near the LIVE head (else nothing is relayed)
--   -> gunfire crime at our position, ShotFx to nearby clients (misses visible too), DistantShot to far ones
--   5 time (-0.05 <= rewind <= min(0.35, 2 ping + 0.1))  6 origin (near the REWOUND head, clear path)
--   7 direction (max spread + 1 deg; shotguns: regenerated pellets within 1.5 deg; no shooting behind your back:
--   rewound or live facing)  8 range  9 target (claimed point near the victim part's rewound position, sampled at
--   t - (ping / 2 + 0.1))  10 line of sight  11 DamageService.canDamage  12 apply (+ crimes, theft drop)
--   13 HitConfirm / DamageTaken.
-- Audit: score decays 10 / min; > 30 silently drops the player's hits for 60 s (logged via AdminService);
-- > 80 within 2 min kicks with a generic message. Lag never scores (stale / facing / state weigh 0) and one packet
-- adds at most ShotValidation.PACKET_CAP. Damage, health, armor, ammo, zones are never read from a client.
-- Melee (WeaponMelee) passes the same draw gate (safe zones) and only swings where the body faces.
--
-- Public API: owns(player, id), giveWeapon(player, id, freeMags?), addAmmo(player, id, rounds): number,
--   reserveSpace(player, id): number, setTint(player, id, tintId), equipped(player): string?, holster(player),
--   holsterGuns(player), pushState(player), ammoOf(player, id): (mag, reserve), addMagazineForClass(player): boolean,
--   onBusted(player), getAudit(player), isAiming(player)
-- Signals: Fired(player, weaponId, origin: Vector3, dir: Vector3), Equipped(player, weaponId?)
-- Player attributes: EquippedWeapon (id or ""), Aiming (bool, cleared whenever no gun is in hand), Reloading (bool).
-- Character attribute: AimPitch (degrees, while aiming; other clients pose the upper body with it).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local Weapons = require(Shared.Config.Weapons)
local Economy = require(Shared.Config.Economy)
local Ballistics = require(Shared.Combat.Ballistics)
local CrimeRules = require(Shared.Combat.CrimeRules)
local DamageModel = require(Shared.Combat.DamageModel)
local ShotValidation = require(Shared.Combat.ShotValidation)
local WeaponModels = require(Shared.Combat.WeaponModels)

type WeaponDef = Weapons.WeaponDef

local WeaponService = {}

WeaponService.Fired = Signal.new() -- (player, weaponId, origin, dir)
WeaponService.Equipped = Signal.new() -- (player, weaponId?)

WeaponService.MELEE_SLACK = 2
WeaponService.MELEE_POINT_BLANK = 3
WeaponService.MELEE_STUN = { bat = 0.9, crowbar = 0.9, nightstick = 0.9 } :: { [string]: number }
WeaponService.MELEE_KNOCK = 28
WeaponService.SOUND_RADIUS = 160
WeaponService.DISTANT_RADIUS = 1200 -- distant-gunfire tails reach this far (beyond the ShotFx radius)
WeaponService.DISTANT_INTERVAL = 0.5 -- at most 2 distant tails per second per shooter
WeaponService.AIM_PITCH_LIMIT = 70 -- degrees; the replicated upper-body aim pitch (character attribute AimPitch)
WeaponService.AIM_PITCH_STEP = 3 -- degrees; smaller changes are not re-replicated

type Ammo = { mag: number, reserve: number }
type Reload = { id: string, endsAt: number, perShell: boolean, token: number }
type Inv = {
	player: Player,
	ammo: { [string]: Ammo },
	tint: { [string]: string? },
	tools: { [string]: Tool },
	equipped: string?,
	equippedAt: number,
	reload: Reload?,
	reloadToken: number,
	buckets: { [string]: ShotValidation.Bucket },
	meleeReadyAt: number,
	audit: ShotValidation.Audit,
	aiming: boolean,
	conns: { RBXScriptConnection },
	loaded: boolean,
	distantReadyAt: number,
}

local invs: { [Player]: Inv } = {}
local templates: { [string]: Tool } = {}
local meshTemplates: { [string]: Model } = {}
local losParams: RaycastParams? = nil

-- HOOKS --------------------------------------------------------------------------------------------------------------
local systemCache: { [string]: any } = {}
-- Tests swap these (tests/spec/weaponservice.spec.luau): system(name) -> fake module; fire(how, name, ...) records
-- remotes instead of sending them (how = "client" | "near" | "nearUnreliable" | "clientUnreliable").
local hooks: { system: ((string) -> any)?, fire: ((string, string, ...any) -> ())? } = { system = nil, fire = nil }

function WeaponService._setHooks(overrides: { [string]: any }?)
	hooks.system = if overrides then overrides.system else nil
	hooks.fire = if overrides then overrides.fire else nil
	table.clear(systemCache)
end

local function sys(name: string): any
	if hooks.system then
		return hooks.system(name)
	end
	local cached = systemCache[name]
	if cached ~= nil then
		return cached
	end
	local inst = script.Parent and script.Parent:FindFirstChild(name)
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst :: any)
		if ok and typeof(mod) == "table" then
			systemCache[name] = mod
			return mod
		end
	end
	return nil
end

local function call(name: string, fn: string, ...: any): (boolean, any)
	local mod = sys(name)
	local f = mod and mod[fn]
	if typeof(f) ~= "function" then
		return false, nil
	end
	local ok, res = pcall(f, ...)
	if not ok then
		warn(("[WeaponService] %s.%s failed: %s"):format(name, fn, tostring(res)))
		return false, nil
	end
	return true, res
end

local function serverNow(): number
	local ok, t = pcall(function()
		return Workspace:GetServerTimeNow()
	end)
	return if ok and typeof(t) == "number" then t else os.clock()
end

local function fireClient(name: string, player: Player, ...: any)
	if hooks.fire then
		hooks.fire("client", name, player, ...)
	elseif player.Parent then
		Net.fireClient(name, player, ...)
	end
end

local function fireNear(name: string, position: Vector3, radius: number, ...: any)
	if hooks.fire then
		hooks.fire("near", name, position, radius, ...)
	else
		Net.fireNear(name, position, radius, ...)
	end
end

local function fireNearUnreliable(name: string, points: { Vector3 }, radius: number, except: Player?, ...: any)
	if hooks.fire then
		hooks.fire("nearUnreliable", name, points, radius, except, ...)
	else
		pcall(Net.fireNearUnreliable, name, points, radius, except, ...)
	end
end

local function fireClientUnreliable(name: string, player: Player, ...: any)
	if hooks.fire then
		hooks.fire("clientUnreliable", name, player, ...)
	else
		pcall(Net.fireClientUnreliable, name, player, ...)
	end
end

local function notify(player: Player, kind: string, text: string, duration: number?)
	fireClient("Notify", player, kind, text, duration)
end

local function getData(player: Player): any
	local ok, data = call("DataService", "get", player)
	if ok and typeof(data) == "table" then
		return data
	end
	return nil
end

local function character(player: Player): (Model?, Humanoid?, BasePart?)
	local char = player.Character
	if not char or not char.Parent then
		return nil, nil, nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not hum or hum.Health <= 0 or not root or not root:IsA("BasePart") then
		return char, nil, nil
	end
	return char, hum, root
end

-- TOOL TEMPLATES ------------------------------------------------------------------------------------------------------

-- Builds the Tool for a weapon (pure instance construction; harness-compatible).
function WeaponService.buildTool(id: string): Tool?
	local def = Weapons.get(id)
	if not def or def.id == "fists" then
		return nil
	end
	local tool = Instance.new("Tool")
	tool.Name = def.name
	tool.ToolTip = def.name
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool.ManualActivationOnly = true
	tool.Grip = def.asset.grip
	tool:SetAttribute("WeaponId", def.id)
	tool:SetAttribute("WeaponClass", def.class)
	local handle = WeaponModels.assemble(tool, def.asset.model, def.asset.scale)
	WeaponModels.weld(tool, handle)
	return tool
end

local function getTemplate(id: string): Tool?
	local t = templates[id]
	if t then
		return t
	end
	local built = WeaponService.buildTool(id)
	if built then
		templates[id] = built
	end
	return built
end

-- Mesh hook (Config/Weapons asset.mesh): loads the uploaded / store model, normalizes it (longest axis = length,
-- `rotation` so the barrel faces -Z, centred at `offset` from the Handle), welds it and hides the placeholder parts.
local STRIP = { "LuaSourceContainer", "Sound", "ProximityPrompt", "ClickDetector", "Humanoid", "Tool", "Attachment" }

local function loadMesh(def: WeaponDef): Model?
	local mesh = def.asset.mesh
	if mesh.id <= 0 then
		return nil
	end
	local ok, container = pcall(function(): Instance
		if mesh.source == "store" then
			local AssetService = game:GetService("AssetService")
			local okA, res = pcall(function()
				return (AssetService :: any):LoadAssetAsync(mesh.id)
			end)
			if okA and res then
				return res
			end
		end
		return game:GetService("InsertService"):LoadAsset(mesh.id)
	end)
	if not ok or typeof(container) ~= "Instance" then
		warn(("[WeaponService] mesh %d for %s failed to load: %s"):format(mesh.id, def.id, tostring(container)))
		return nil
	end
	local model = Instance.new("Model")
	model.Name = def.id .. "_Mesh"
	for _, d in container:GetDescendants() do
		for _, cls in STRIP do
			if d:IsA(cls) then
				d:Destroy()
				break
			end
		end
	end
	for _, d in container:GetDescendants() do
		if d:IsA("BasePart") then
			d.Parent = model
		end
	end
	container:Destroy()
	local parts = model:GetChildren()
	if #parts == 0 then
		model:Destroy()
		return nil
	end
	local cf, size = model:GetBoundingBox()
	local longest = math.max(size.X, size.Y, size.Z)
	if longest > 1e-3 then
		pcall(function()
			model:ScaleTo(mesh.length / longest)
		end)
	end
	cf = model:GetBoundingBox()
	local root = Instance.new("Part")
	root.Name = "MeshRoot"
	root.Size = Vector3.new(0.1, 0.1, 0.1)
	root.Transparency = 1
	root.CFrame = CFrame.new(cf.Position)
	root.Parent = model
	model.PrimaryPart = root
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.Massless = true
			d.Anchored = true
			d.CastShadow = false
		end
	end
	return model
end

local function applyMesh(tool: Tool, id: string)
	local def = Weapons.get(id)
	local meshModel = meshTemplates[id]
	if not def or not meshModel then
		return
	end
	local handle = tool:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		return
	end
	local mesh = def.asset.mesh
	local clone = meshModel:Clone()
	clone:PivotTo(handle.CFrame * CFrame.new(mesh.offset) * mesh.rotation)
	for _, d in tool:GetDescendants() do
		if d:IsA("BasePart") and d ~= handle and d:GetAttribute("Tint") ~= nil then
			d.Transparency = 1
		end
	end
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.Parent = tool
			local w = Instance.new("WeldConstraint")
			w.Part0 = handle
			w.Part1 = d
			w.Parent = d
		end
	end
	clone:Destroy()
end

-- INVENTORY ------------------------------------------------------------------------------------------------------------

local function newInv(player: Player): Inv
	return {
		player = player,
		ammo = {},
		tint = {},
		tools = {},
		equipped = nil,
		equippedAt = 0,
		reload = nil,
		reloadToken = 0,
		buckets = {},
		meleeReadyAt = 0,
		audit = ShotValidation.newAudit(os.clock()),
		aiming = false,
		conns = {},
		loaded = false,
		distantReadyAt = 0,
	}
end

local function getInv(player: Player): Inv
	local inv = invs[player]
	if not inv then
		inv = newInv(player)
		invs[player] = inv
	end
	return inv
end

function WeaponService.owns(player: Player, id: string): boolean
	if id == "fists" then
		return true
	end
	local inv = invs[player]
	return inv ~= nil and inv.ammo[id] ~= nil
end

function WeaponService.ammoOf(player: Player, id: string): (number, number)
	local inv = invs[player]
	local a = inv and inv.ammo[id]
	if not a then
		return 0, 0
	end
	return a.mag, a.reserve
end

function WeaponService.equipped(player: Player): string?
	local inv = invs[player]
	return inv and inv.equipped
end

function WeaponService.getAudit(player: Player): ShotValidation.Audit?
	local inv = invs[player]
	return inv and inv.audit
end

local function writeAmmo(inv: Inv, id: string)
	local data = getData(inv.player)
	if not data or typeof(data.weapons) ~= "table" then
		return
	end
	local a = inv.ammo[id]
	if not a then
		data.weapons[id] = nil
		return
	end
	local rec = data.weapons[id]
	if typeof(rec) ~= "table" then
		rec = {}
		data.weapons[id] = rec
	end
	rec.ammo = a.mag + a.reserve
	rec.tint = inv.tint[id]
end

local function sendAmmo(inv: Inv, id: string)
	local a = inv.ammo[id]
	if a then
		fireClient("AmmoState", inv.player, id, a.mag, a.reserve)
	end
end

function WeaponService.pushState(player: Player)
	local inv = invs[player]
	if not inv or not player.Parent then
		return
	end
	local list = {}
	table.insert(list, { id = "fists", mag = 0, reserve = 0 })
	for _, def in Weapons.List do
		local a = inv.ammo[def.id]
		if a then
			table.insert(list, { id = def.id, mag = a.mag, reserve = a.reserve, tint = inv.tint[def.id] })
		end
	end
	local gadgets = {}
	local data = getData(player)
	if data and typeof(data.tools) == "table" then
		for _, gid in Weapons.GADGETS do
			if data.tools[gid] == true then
				table.insert(gadgets, gid)
			end
		end
	end
	local okPass, hasTaser = call("MonetizationService", "hasPass", player, "taser")
	if okPass and hasTaser == true and not table.find(gadgets, "taser") then
		table.insert(gadgets, 1, "taser")
	end
	fireClient("CombatState", player, {
		weapons = list,
		gadgets = gadgets,
		equipped = inv.equipped,
		armor = player:GetAttribute("Armor") or 0,
		medkits = if data then data.medkits or 0 else 0,
	})
end

local function tintTool(tool: Tool, tintId: string?)
	local tint = tintId and Weapons.Tints[tintId]
	if tint and tint.id ~= "black" then
		WeaponModels.applyTint(tool, tint.color, tint.material)
	end
end

local function makeTool(inv: Inv, id: string): Tool?
	local template = getTemplate(id)
	if not template then
		return nil
	end
	local tool = template:Clone()
	if meshTemplates[id] then
		applyMesh(tool, id)
	end
	tintTool(tool, inv.tint[id])
	return tool
end

-- Keeps exactly one Tool per owned weapon in the Backpack / character; drops unknown ones.
local function syncTools(inv: Inv)
	local player = inv.player
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return
	end
	local char = player.Character
	local seen: { [string]: Tool } = {}
	for _, container in { char, backpack } :: { Instance? } do
		if container then
			for _, child in container:GetChildren() do
				if child:IsA("Tool") then
					local id = child:GetAttribute("WeaponId")
					if typeof(id) == "string" then
						if inv.ammo[id] == nil or seen[id] then
							child:Destroy()
						else
							seen[id] = child
						end
					end
				end
			end
		end
	end
	for id in inv.ammo do
		local tool = seen[id]
		if not tool then
			tool = makeTool(inv, id)
			if tool then
				tool.Parent = backpack
			end
		end
		if tool then
			inv.tools[id] = tool
		end
	end
	for id in inv.tools do
		if inv.ammo[id] == nil then
			inv.tools[id] = nil
		end
	end
end

local function loadInventory(player: Player)
	local inv = getInv(player)
	local data = getData(player)
	if not data then
		return
	end
	table.clear(inv.ammo)
	table.clear(inv.tint)
	local weapons = if typeof(data.weapons) == "table" then data.weapons else {}
	for id, rec in weapons do
		local def = Weapons.get(id)
		if def and typeof(rec) == "table" then
			local total = math.max(0, math.floor(tonumber(rec.ammo) or 0))
			local mag = math.min(def.mag or 0, total)
			inv.ammo[id] = { mag = mag, reserve = total - mag }
			inv.tint[id] = if typeof(rec.tint) == "string" then rec.tint else nil
		end
	end
	if not inv.ammo.bat then
		inv.ammo.bat = { mag = 0, reserve = 0 }
	end
	inv.loaded = true
	syncTools(inv)
	WeaponService.pushState(player)
end

-- EQUIP --------------------------------------------------------------------------------------------------------------

local function cancelReload(inv: Inv)
	if inv.reload then
		inv.reload = nil
		inv.reloadToken += 1
		pcall(function()
			inv.player:SetAttribute("Reloading", false)
		end)
	end
end

-- Aiming ends (holster, gun swapped for melee, respawn): the brandish / "armed" checks read this, so it must never
-- outlive the gun. Also drops the replicated aim pitch other clients pose the upper body with.
local function clearAim(inv: Inv)
	inv.aiming = false
	pcall(function()
		inv.player:SetAttribute("Aiming", false)
		local char = inv.player.Character
		if char and char:GetAttribute("AimPitch") ~= nil then
			char:SetAttribute("AimPitch", nil)
		end
	end)
end

local function setEquipped(inv: Inv, id: string?)
	if inv.equipped == id then
		return
	end
	cancelReload(inv)
	inv.equipped = id
	inv.equippedAt = os.clock()
	if id == nil or not Weapons.isGun(Weapons.get(id)) then
		clearAim(inv)
	end
	pcall(function()
		inv.player:SetAttribute("EquippedWeapon", id or "")
	end)
	WeaponService.Equipped:Fire(inv.player, id)
end

function WeaponService.holster(player: Player)
	local _, hum = character(player)
	if hum then
		pcall(hum.UnequipTools, hum)
	end
	local inv = invs[player]
	if inv then
		setEquipped(inv, nil)
	end
end

-- Holsters only guns (safe zones keep melee... no: safe zones holster everything except in your own garage, which
-- DamageService already excludes before calling this).
function WeaponService.holsterGuns(player: Player)
	local inv = invs[player]
	if inv and inv.equipped then
		WeaponService.holster(player)
	end
end

local function requestEquip(player: Player, id: any)
	if id == "none" or id == "fists" then
		WeaponService.holster(player)
		return
	end
	if typeof(id) ~= "string" or #id > 16 then
		return
	end
	local inv = invs[player]
	if not inv then
		return
	end
	local _, hum = character(player)
	if not hum then
		return
	end
	if hum.SeatPart ~= nil then
		return -- drive-by is phase 2
	end
	if player:GetAttribute("Stunned") == true then
		return
	end
	local tool: Tool? = inv.tools[id]
	if not tool then
		-- gadgets (CombatService Tools): equip by ToolId
		local backpack = player:FindFirstChildOfClass("Backpack")
		if backpack then
			for _, child in backpack:GetChildren() do
				if child:IsA("Tool") and child:GetAttribute("ToolId") == id then
					tool = child
					break
				end
			end
		end
	end
	if not tool then
		return
	end
	local okDraw, why = true, nil
	local okCall, res, reason = pcall(function()
		local Damage = sys("DamageService")
		if Damage and Damage.canDraw then
			return Damage.canDraw(player, id)
		end
		return true, nil
	end)
	if okCall then
		okDraw, why = res, reason
	end
	if not okDraw then
		local msg = if why == "safezone"
			then "Weapons stay holstered here."
			elseif why == "passive" then "Passive mode: guns are locked."
			elseif why == "rookie" then "Rookie protection: guns unlock when it ends (or opt out in Settings)."
			elseif why == "locked" then "Weapons are locked for a moment."
			else nil
		if msg then
			notify(player, "error", msg, 2)
		end
		return
	end
	pcall(hum.EquipTool, hum, tool)
end

-- A Tool appeared in / left the character (server equips, client equips, respawns).
local function onCharacterChild(inv: Inv, child: Instance, added: boolean)
	if not child:IsA("Tool") then
		return
	end
	local id = child:GetAttribute("WeaponId")
	if typeof(id) ~= "string" then
		if added then
			setEquipped(inv, nil) -- a gadget: no weapon in hand
		end
		return
	end
	if added then
		local okDraw = true
		local Damage = sys("DamageService")
		if Damage and typeof(Damage.canDraw) == "function" then
			local ok, res = pcall(Damage.canDraw, inv.player, id)
			okDraw = not ok or res == true
		end
		local _, hum = character(inv.player)
		if not okDraw or (hum and hum.SeatPart ~= nil) or inv.ammo[id] == nil then
			-- not allowed here: back to the Backpack (server parenting wins)
			task.defer(function()
				local backpack = inv.player:FindFirstChildOfClass("Backpack")
				if child.Parent and backpack then
					child.Parent = backpack
				end
			end)
			return
		end
		setEquipped(inv, id)
	elseif inv.equipped == id then
		setEquipped(inv, nil)
	end
end

-- RELOAD ---------------------------------------------------------------------------------------------------------------

local function finishReload(inv: Inv, token: number)
	local r = inv.reload
	if not r or r.token ~= token then
		return
	end
	local def = Weapons.get(r.id)
	local a = inv.ammo[r.id]
	if not def or not a or inv.equipped ~= r.id then
		cancelReload(inv)
		return
	end
	local n = Ballistics.reloadAmount(def, a.mag, a.reserve)
	a.mag += n
	a.reserve -= n
	writeAmmo(inv, r.id)
	if r.perShell and a.mag < (def.mag or 0) and a.reserve > 0 then
		-- next shell
		inv.reloadToken += 1
		local nextToken = inv.reloadToken
		r.token = nextToken
		r.endsAt = os.clock() + (def.perShellReload or 0.45)
		sendAmmo(inv, r.id)
		task.delay(def.perShellReload or 0.45, finishReload, inv, nextToken)
		return
	end
	inv.reload = nil
	pcall(function()
		inv.player:SetAttribute("Reloading", false)
	end)
	sendAmmo(inv, r.id)
end

function WeaponService.reload(player: Player, id: any): boolean
	local inv = invs[player]
	if not inv or typeof(id) ~= "string" or inv.equipped ~= id or inv.reload then
		return false
	end
	local def = Weapons.get(id)
	local a = inv.ammo[id]
	if not def or not a or not Weapons.isGun(def) then
		return false
	end
	if a.mag >= (def.mag or 0) or a.reserve <= 0 then
		return false
	end
	local _, hum = character(player)
	if not hum then
		return false
	end
	inv.reloadToken += 1
	local token = inv.reloadToken
	local dur = Ballistics.reloadTime(def, a.mag)
	inv.reload = { id = id, endsAt = os.clock() + dur, perShell = def.perShellReload ~= nil, token = token }
	pcall(function()
		player:SetAttribute("Reloading", true)
	end)
	task.delay(dur, finishReload, inv, token)
	return true
end

-- AMMO / OWNERSHIP (ShopService, PoliceCombatService, AdminService) -----------------------------------------------------

function WeaponService.reserveSpace(player: Player, id: string): number
	local def = Weapons.get(id)
	local inv = invs[player]
	local a = inv and inv.ammo[id]
	if not def or not a or not Weapons.isGun(def) then
		return 0
	end
	return math.max(0, (def.reserveCap or 0) - a.reserve)
end

-- Adds rounds to the reserve (capped). Returns how many were added.
function WeaponService.addAmmo(player: Player, id: string, rounds: number): number
	local inv = invs[player]
	local a = inv and inv.ammo[id]
	if not inv or not a then
		return 0
	end
	local add = math.min(math.max(0, math.floor(rounds)), WeaponService.reserveSpace(player, id))
	if add <= 0 then
		return 0
	end
	a.reserve += add
	writeAmmo(inv, id)
	sendAmmo(inv, id)
	return add
end

-- Grants a weapon (purchase / admin / welcome gift) with a full magazine + `freeMags` spare magazines.
function WeaponService.giveWeapon(player: Player, id: string, freeMags: number?): boolean
	local def = Weapons.get(id)
	if not def or def.id == "fists" then
		return false
	end
	local inv = getInv(player)
	if inv.ammo[id] then
		return false
	end
	local mag = def.mag or 0
	local spare = math.min(mag * (freeMags or Weapons.FREE_MAGS_ON_BUY), def.reserveCap or 0)
	inv.ammo[id] = { mag = mag, reserve = spare }
	writeAmmo(inv, id)
	call("DataService", "markDirty", player)
	syncTools(inv)
	WeaponService.pushState(player)
	return true
end

function WeaponService.removeWeapon(player: Player, id: string)
	local inv = invs[player]
	if not inv or not inv.ammo[id] or id == "bat" then
		return
	end
	if inv.equipped == id then
		WeaponService.holster(player)
	end
	inv.ammo[id] = nil
	writeAmmo(inv, id)
	syncTools(inv)
	WeaponService.pushState(player)
end

function WeaponService.setTint(player: Player, id: string, tintId: string): boolean
	local inv = invs[player]
	if not inv or not inv.ammo[id] or not Weapons.Tints[tintId] then
		return false
	end
	inv.tint[id] = if tintId == "black" then nil else tintId
	writeAmmo(inv, id)
	local tool = inv.tools[id]
	if tool then
		local wasEquipped = inv.equipped == id
		tool:Destroy()
		inv.tools[id] = nil
		syncTools(inv)
		if wasEquipped then
			requestEquip(player, id)
		end
	end
	WeaponService.pushState(player)
	return true
end

-- Ammo pickup from a downed officer: one magazine for the CURRENT weapon (or the best gun owned).
function WeaponService.addMagazineForClass(player: Player): boolean
	local inv = invs[player]
	if not inv then
		return false
	end
	local id = inv.equipped
	local def = id and Weapons.get(id)
	if not def or not Weapons.isGun(def) then
		id = nil
		for _, d in Weapons.List do
			if inv.ammo[d.id] and Weapons.isGun(d) and WeaponService.reserveSpace(player, d.id) > 0 then
				id = d.id
				def = d
			end
		end
	end
	if not id or not def then
		return false
	end
	return WeaponService.addAmmo(player, id, def.mag or 0) > 0
end

-- BUSTED: armor is gone (DamageService) and the police confiscate half of every reserve (GTA takes all of it).
function WeaponService.onBusted(player: Player)
	local inv = invs[player]
	if not inv then
		return
	end
	WeaponService.holster(player)
	for id, a in inv.ammo do
		if a.reserve > 0 then
			a.reserve = math.floor(a.reserve * (1 - Economy.BUSTED_AMMO_LOSS))
			writeAmmo(inv, id)
		end
	end
	WeaponService.pushState(player)
end

-- SHOT PIPELINE ----------------------------------------------------------------------------------------------------------

local function getLosParams(exclude: { Instance }): RaycastParams
	local p = losParams
	if not p then
		p = RaycastParams.new()
		p.FilterType = Enum.RaycastFilterType.Exclude
		p.IgnoreWater = true
		p.RespectCanCollide = true
		losParams = p
	end
	p.FilterDescendantsInstances = exclude
	return p
end

local function baseExclude(): { Instance }
	local list: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	for _, name in { "Effects", "NPCs" } do
		local f = Workspace:FindFirstChild(name)
		if f then
			table.insert(list, f)
		end
	end
	return list
end

local function clearPath(a: Vector3, b: Vector3, exclude: { Instance }): boolean
	local dir = b - a
	local len = dir.Magnitude
	if len < 1.05 then
		return true
	end
	local hit = Workspace:Raycast(a, dir.Unit * (len - 1), getLosParams(exclude))
	return hit == nil
end

export type Target = {
	kind: string, -- "player" | "npc" | "vehicle" | "world"
	player: Player?,
	model: Model?,
	car: any,
}

-- What does a claimed hit part belong to?
local function resolveTarget(part: Instance?): Target
	if part == nil or not part:IsDescendantOf(Workspace) then
		return { kind = "world" }
	end
	local node: Instance? = part
	while node and node ~= Workspace do
		if node:IsA("Model") then
			local p = Players:GetPlayerFromCharacter(node)
			if p then
				return { kind = "player", player = p, model = node }
			end
			local parent = node.Parent
			if parent and parent.Name == "NPCs" and node:FindFirstChildOfClass("Humanoid") then
				return { kind = "npc", model = node }
			end
			if CollectionService:HasTag(node, "Vehicle") then
				local ok, car = call("VehicleService", "fromModel", node)
				if ok and car then
					return { kind = "vehicle", model = node, car = car }
				end
				return { kind = "world" }
			end
		end
		node = node.Parent
	end
	return { kind = "world" }
end

local function rejectShot(inv: Inv, reason: string, detail: string?)
	local now = os.clock()
	local verdict = ShotValidation.addAudit(inv.audit, reason, now)
	if verdict == "drop" then
		warn(
			("[ShotAudit] dropping hits from %s for 60s (score %.0f, last %s %s)"):format(
				inv.player.Name,
				inv.audit.score,
				reason,
				detail or ""
			)
		)
		call("AdminService", "logAudit", inv.player, reason, inv.audit)
	elseif verdict == "kick" then
		warn(("[ShotAudit] kicking %s (score %.0f)"):format(inv.player.Name, inv.audit.score))
		call("AdminService", "logAudit", inv.player, "kick", inv.audit)
		pcall(function()
			inv.player:Kick("Connection problem detected. Please rejoin.")
		end)
	end
end

local KIND_MISS, KIND_WORLD, KIND_BODY, KIND_METAL = 0, 1, 2, 3

type PendingHit = { target: Target, part: BasePart, x: Vector3, raw: number }

-- Who hears a shot only as a distant tail (pure, tested): beyond the ShotFx radius of every relayed point (those
-- listeners got ShotFx) and within DISTANT_RADIUS of the muzzle.
function WeaponService._isDistantListener(pos: Vector3, origin: Vector3, fxPoints: { Vector3 }): boolean
	local near2 = Weapons.FX_RADIUS * Weapons.FX_RADIUS
	for _, pt in fxPoints do
		local d = pos - pt
		if d.X * d.X + d.Y * d.Y + d.Z * d.Z <= near2 then
			return false
		end
	end
	local o = pos - origin
	return o.X * o.X + o.Y * o.Y + o.Z * o.Z <= WeaponService.DISTANT_RADIUS * WeaponService.DISTANT_RADIUS
end

-- Distant gunfire (gta_combat §11.6): players beyond the ShotFx radius (up to DISTANT_RADIUS) hear a quiet,
-- low-passed tail, at most once per DISTANT_INTERVAL per shooter (`DistantShot(origin, weaponIndex)`, unreliable).
local function relayDistant(inv: Inv, origin: Vector3, fxPoints: { Vector3 }, weaponId: string, now: number)
	if now < inv.distantReadyAt then
		return
	end
	inv.distantReadyAt = now + WeaponService.DISTANT_INTERVAL
	local index = Weapons.Index[weaponId] or 0
	for _, p in Players:GetPlayers() do
		if p ~= inv.player then
			local char = p.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") and WeaponService._isDistantListener(root.Position, origin, fxPoints) then
				fireClientUnreliable("DistantShot", p, origin, index)
			end
		end
	end
end

local function processShot(inv: Inv, raw: any, now: number, tNow: number, ping: number)
	local player = inv.player
	-- 1. shape
	local shot, why = ShotValidation.parseShot(raw, function(p: any): boolean
		return typeof(p) == "Instance" and p:IsA("BasePart")
	end)
	if not shot then
		rejectShot(inv, why or "shape")
		return
	end
	local def = Weapons.get(shot.w) :: WeaponDef
	-- 2. state
	local char, hum, root = character(player)
	if not char or not hum or not root then
		return
	end
	if inv.equipped ~= shot.w or inv.ammo[shot.w] == nil then
		rejectShot(inv, "state")
		return
	end
	if now - inv.equippedAt < def.drawTime * 0.85 then
		rejectShot(inv, "state")
		return
	end
	if hum.SeatPart ~= nil or player:GetAttribute("Stunned") == true then
		rejectShot(inv, "state")
		return
	end
	if inv.reload then
		if inv.reload.perShell then
			cancelReload(inv) -- firing interrupts a shell-by-shell reload
		else
			rejectShot(inv, "state")
			return
		end
	end
	local Damage = sys("DamageService")
	if Damage and typeof(Damage.canDraw) == "function" then
		local ok, allowed = pcall(Damage.canDraw, player, shot.w)
		if ok and allowed ~= true then
			rejectShot(inv, "state")
			return
		end
	end
	-- 3. rate
	local bucket = inv.buckets[shot.w]
	if not bucket then
		bucket = ShotValidation.newBucket(def, now)
		inv.buckets[shot.w] = bucket
	end
	if not ShotValidation.take(bucket, now) then
		rejectShot(inv, "rate")
		return
	end
	-- 4. ammo
	local a = inv.ammo[shot.w]
	if a.mag <= 0 then
		rejectShot(inv, "ammo")
		sendAmmo(inv, shot.w)
		return
	end
	a.mag -= 1
	writeAmmo(inv, shot.w)
	-- the muzzle must be near our LIVE head before the server acts on the shot at all (relay, crime, signals): a
	-- claim of a muzzle across the map would put tracers, flashes and the gunfire crime somewhere else. Generous:
	-- the full MAX_REWIND of movement on top of ORIGIN_BASE; the hit checks below use the tight rewound test.
	local liveHead = char:FindFirstChild("Head")
	local liveHeadPos = if liveHead and liveHead:IsA("BasePart")
		then liveHead.Position
		else root.Position + Vector3.new(0, 1.5, 0)
	local liveSpeed = root.AssemblyLinearVelocity.Magnitude
	if not ShotValidation.checkOrigin(shot.o, liveHeadPos, liveSpeed, ShotValidation.MAX_REWIND) then
		rejectShot(inv, "origin", ("live %.1f studs"):format((shot.o - liveHeadPos).Magnitude))
		return
	end
	if Damage then
		pcall(Damage.onFired, player)
	end
	WeaponService.Fired:Fire(player, shot.w, shot.o, shot.d)
	if Damage and typeof(Damage.reportCrime) == "function" then
		pcall(Damage.reportCrime, player, "gunfire", root.Position)
	end

	-- cosmetic relay (misses included): endpoints per pellet
	local pellets = Weapons.pelletCount(def)
	local spread = if shot.a then def.spreadAim else def.spreadHip
	local dirs = Ballistics.pellets(shot.d, if pellets > 1 then spread else 0, shot.s, pellets)
	local claimed: { [number]: ShotValidation.ClaimedHit } = {}
	for _, h in shot.h do
		claimed[h.k] = h
	end
	local endpoints: { Vector3 } = table.create(pellets)
	local kinds: { number } = table.create(pellets)
	local fxPoints: { Vector3 } = { shot.o }
	for k = 1, pellets do
		local h = claimed[k]
		local x: Vector3
		local kind = KIND_MISS
		if h then
			local off = h.x - shot.o
			x = if off.Magnitude > def.maxRange then shot.o + off.Unit * def.maxRange else h.x
			local tk = resolveTarget(h.p)
			kind = if tk.kind == "player" or tk.kind == "npc"
				then KIND_BODY
				elseif tk.kind == "vehicle" then KIND_METAL
				else KIND_WORLD
		else
			x = shot.o + dirs[k] * def.maxRange
		end
		endpoints[k] = x
		kinds[k] = kind
		if k <= 2 then
			table.insert(fxPoints, x)
		end
	end
	fireNearUnreliable(
		"ShotFx",
		fxPoints,
		Weapons.FX_RADIUS,
		player,
		player.UserId,
		Weapons.Index[shot.w] or 0,
		shot.o,
		endpoints,
		kinds
	)
	relayDistant(inv, shot.o, fxPoints, shot.w, now)
	if #shot.h == 0 then
		return
	end
	if ShotValidation.isDropping(inv.audit, now) then
		return -- flagged shooter: hits silently ignored
	end

	-- 5. time
	local rewind = tNow - shot.t
	local okTime, timeWhy = ShotValidation.checkTime(rewind, ping)
	if not okTime then
		rejectShot(inv, timeWhy or "stale", ("rewind %.3f ping %.3f"):format(rewind, ping))
		return
	end
	-- 6. origin (rewound head)
	local HitboxHistory = sys("HitboxHistory")
	local head = char:FindFirstChild("Head")
	local headPos = if head and head:IsA("BasePart") then head.Position else root.Position + Vector3.new(0, 1.5, 0)
	local rootCF = root.CFrame
	if HitboxHistory then
		local okH, rewHead =
			pcall(HitboxHistory.samplePart, char, if head and head:IsA("BasePart") then head else root, shot.t)
		if okH and typeof(rewHead) == "Vector3" then
			headPos = rewHead
		end
		local okR, rewRoot = pcall(HitboxHistory.sample, char, shot.t)
		if okR and typeof(rewRoot) == "CFrame" then
			rootCF = rewRoot
		end
	end
	local speed = root.AssemblyLinearVelocity.Magnitude
	if not ShotValidation.checkOrigin(shot.o, headPos, speed, rewind) then
		rejectShot(inv, "origin", ("%.1f studs"):format((shot.o - headPos).Magnitude))
		return
	end
	local exclude = baseExclude()
	local okCar, myCar = call("VehicleService", "getDriving", player)
	if okCar and myCar and myCar.model then
		table.insert(exclude, myCar.model)
	end
	if (shot.o - headPos).Magnitude > 3 and not clearPath(headPos, shot.o, exclude) then
		rejectShot(inv, "los", "head -> muzzle")
		return
	end
	-- 7c. facing: the rewound OR the live facing (the turn toward the camera replicates just after the first shot)
	if
		not ShotValidation.checkFacing(shot.d, rootCF.LookVector)
		and not ShotValidation.checkFacing(shot.d, root.CFrame.LookVector)
	then
		rejectShot(inv, "facing")
		return
	end
	local expected = if pellets > 1 then ShotValidation.expectedPellets(def, shot.d, shot.s, shot.a) else nil
	local victimT = ShotValidation.victimSampleTime(shot.t, ping)

	-- per-hit checks; damage summed per victim
	local byVictim: { [any]: PendingHit } = {}
	local order: { any } = {}
	for _, h in shot.h do
		-- 7a / 7b. direction
		if expected then
			if not ShotValidation.checkPellet(expected, h.k, shot.o, h.x) then
				rejectShot(inv, "pellet")
				continue
			end
		elseif not ShotValidation.checkAngle(def, shot.o, shot.d, h.x) then
			rejectShot(inv, "angle")
			continue
		end
		-- 8. range
		if not ShotValidation.checkRange(def, shot.o, h.x) then
			rejectShot(inv, "range")
			continue
		end
		local part = h.p
		if part == nil then
			continue -- world hit: cosmetic only (already relayed)
		end
		local target = resolveTarget(part)
		if target.kind == "world" then
			continue
		end
		-- 9. target (rewound)
		local model = target.model :: Model
		local victimSpeed = 0
		local occupant = false
		local partPos = (part :: BasePart).Position
		if HitboxHistory then
			local okP, rewPos = pcall(HitboxHistory.samplePart, model, part, victimT)
			if okP and typeof(rewPos) == "Vector3" then
				partPos = rewPos
			end
		end
		local vroot = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
		if vroot and vroot:IsA("BasePart") then
			victimSpeed = vroot.AssemblyLinearVelocity.Magnitude
		end
		if target.kind == "player" then
			local vh = model:FindFirstChildOfClass("Humanoid")
			occupant = vh ~= nil and vh.SeatPart ~= nil
		end
		local size = (part :: BasePart).Size
		local partExtent = if target.kind == "vehicle"
			then math.max(size.X, size.Y, size.Z)
			else math.max(size.X, size.Y, size.Z) * 0.5
		if not ShotValidation.checkTarget(h.x, partPos, partExtent, victimSpeed, rewind, occupant) then
			rejectShot(inv, "target", ("%.1f studs"):format((h.x - partPos).Magnitude))
			continue
		end
		-- 10. line of sight (the target itself, and the car the victim sits in, are not obstacles)
		local losExclude = table.clone(exclude)
		table.insert(losExclude, model)
		if target.kind == "player" and target.player then
			local okV, vcar = call("VehicleService", "getDriving", target.player)
			if okV and vcar and vcar.model then
				table.insert(losExclude, vcar.model)
			end
		end
		if not clearPath(shot.o, h.x, losExclude) then
			rejectShot(inv, "los")
			continue
		end
		local dist = (h.x - shot.o).Magnitude
		local dmg = DamageModel.raw(def, (part :: BasePart).Name, dist, occupant)
		local key: any = target.player or model
		local pending = byVictim[key]
		if pending then
			pending.raw += dmg
			if DamageModel.partClass((part :: BasePart).Name) == "head" then
				pending.part = part :: BasePart
			end
		else
			byVictim[key] = { target = target, part = part :: BasePart, x = h.x, raw = dmg }
			table.insert(order, key)
		end
	end

	-- 11-13. apply
	for _, key in order do
		local hit = byVictim[key]
		local target = hit.target
		local info = {
			amount = hit.raw,
			source = player,
			weapon = shot.w,
			part = hit.part.Name,
			position = hit.x,
			from = shot.o,
		}
		if target.kind == "player" and target.player then
			call("DamageService", "applyDamage", target.player, info)
		elseif target.kind == "npc" and target.model then
			call("DamageService", "applyNpcDamage", target.model, info)
		elseif target.kind == "vehicle" and target.car then
			local ok, res = call(
				"VehicleService",
				"bulletHit",
				target.car,
				hit.part,
				hit.x,
				hit.raw * Weapons.CAR_DAMAGE_MULT,
				player
			)
			if ok and res == true then
				fireClient("HitConfirm", player, "armor", hit.x)
				if target.car.kind == "Police" then
					call("DamageService", "reportCrime", player, "copShot", hit.x, true)
				end
			end
		end
	end
end

local function onFire(player: Player, packet: any)
	local inv = invs[player]
	if not inv or not inv.loaded then
		return
	end
	ShotValidation.beginPacket(inv.audit) -- one packet scores at most PACKET_CAP
	local n = ShotValidation.packetSize(packet)
	if not n then
		rejectShot(inv, "shape")
		return
	end
	local now = os.clock()
	local tNow = serverNow()
	local okPing, ping = pcall(function()
		return player:GetNetworkPing()
	end)
	local rtt = if okPing and typeof(ping) == "number" then ping else 0.1
	for i = 1, n do
		local ok, err = pcall(processShot, inv, packet[i], now, tNow, rtt)
		if not ok then
			warn("[WeaponService] shot failed: " .. tostring(err))
		end
	end
end

-- MELEE ------------------------------------------------------------------------------------------------------------------

local function meleeTargets(player: Player, origin: Vector3, reach: number): { { key: any, position: Vector3 } }
	local list = {}
	for _, other in Players:GetPlayers() do
		if other ~= player then
			local _, hum, root = character(other)
			if hum and root and (root.Position - origin).Magnitude <= reach + 4 then
				table.insert(list, { key = other, position = root.Position })
			end
		end
	end
	local npcs = Workspace:FindFirstChild("NPCs")
	if npcs then
		for _, m in npcs:GetChildren() do
			if m:IsA("Model") then
				local root = m:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") and (root.Position - origin).Magnitude <= reach + 4 then
					table.insert(list, { key = m, position = root.Position })
				end
			end
		end
	end
	return list
end

local function onMelee(player: Player, id: any, aimDir: any)
	local inv = invs[player]
	if not inv or typeof(id) ~= "string" or not Net.isUnit(aimDir) then
		return
	end
	local def = Weapons.get(id)
	if not def or not Weapons.isMelee(def) then
		return
	end
	local equippedId = inv.equipped or "fists"
	if equippedId ~= id or not WeaponService.owns(player, id) then
		return
	end
	local char, hum, root = character(player)
	if not char or not hum or not root then
		return
	end
	if hum.SeatPart ~= nil or player:GetAttribute("Stunned") == true then
		return
	end
	-- the same draw gate as guns: fists have no Tool, so the safe-zone holster never touches them (no punching out
	-- of a gun store / hospital / spray shop)
	local Damage = sys("DamageService")
	if Damage and typeof(Damage.canDraw) == "function" then
		local okD, allowed = pcall(Damage.canDraw, player, id)
		if not okD or allowed ~= true then
			return
		end
	end
	local now = os.clock()
	if now < inv.meleeReadyAt - 0.08 then
		return
	end
	inv.meleeReadyAt = now + Weapons.interval(def)
	if id ~= "fists" and now - inv.equippedAt < def.drawTime * 0.85 then
		return
	end
	local reach = (def.meleeReach or 4.5) + WeaponService.MELEE_SLACK
	-- the client's swing direction only widens the cone when it is roughly where our (server-side) body faces:
	-- no hitting someone standing behind us
	local look = root.CFrame.LookVector
	local forwards = { look }
	if ShotValidation.checkFacing(aimDir :: Vector3, look) then
		table.insert(forwards, aimDir :: Vector3)
	end
	local candidates = meleeTargets(player, root.Position, reach)
	local Combat = sys("CombatService")
	if not Combat or typeof(Combat.selectTarget) ~= "function" then
		return
	end
	local exclude = baseExclude()
	local head = char:FindFirstChild("Head")
	local eye = if head and head:IsA("BasePart") then head.Position else root.Position + Vector3.new(0, 1.5, 0)
	while #candidates > 0 do
		local key = Combat.selectTarget(
			root.Position,
			forwards,
			candidates,
			reach,
			def.meleeArc or 0.3,
			WeaponService.MELEE_POINT_BLANK
		)
		if key == nil then
			return
		end
		local target: any = key
		local tpos: Vector3? = nil
		for i, c in candidates do
			if c.key == key then
				tpos = c.position
				table.remove(candidates, i)
				break
			end
		end
		if tpos and clearPath(eye, tpos, exclude) then
			local info = {
				amount = def.damage,
				source = player,
				weapon = id,
				part = "UpperTorso",
				position = tpos,
				from = root.Position,
				melee = true,
			}
			local result: any = nil
			if typeof(target) == "Instance" and target:IsA("Player") then
				local victim = target :: Player
				local okCar, car = call("VehicleService", "getDriving", victim)
				local ok, res = call("DamageService", "applyDamage", victim, info)
				result = if ok then res else nil
				if result and result.applied then
					local stun = WeaponService.MELEE_STUN[id]
					local flat = Vector3.new(tpos.X - root.Position.X, 0, tpos.Z - root.Position.Z)
					local dir = if flat.Magnitude > 0.1
						then flat.Unit
						else Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
					if stun and not result.killed then
						-- no stun-lock: inside the victim's stun immunity the hit still hurts but neither stuns
						-- nor knocks down
						local okS, landed = call("CombatService", "stun", victim, stun)
						if okS and landed == true then
							fireClient(
								"Knockback",
								victim,
								dir * WeaponService.MELEE_KNOCK + Vector3.new(0, 18, 0),
								stun
							)
						end
					end
					-- a swing at a driver knocks them out of the seat (v1's "bonk the thief out of your car")
					if okCar and car and not result.killed then
						local wanted = victim:GetAttribute("Wanted")
						local thiefBonk =
							CrimeRules.countsAsThiefBonk(car.kind, if typeof(wanted) == "number" then wanted else 0)
						local okE, ejected = call("VehicleService", "eject", car)
						if thiefBonk and okE and ejected ~= false then
							call("RewardsService", "progress", player, "defend", 1)
						end
					end
				end
			elseif typeof(target) == "Instance" and target:IsA("Model") then
				local ok, res = call("DamageService", "applyNpcDamage", target, info)
				result = if ok then res else nil
			end
			if result and result.applied then
				local sound = def.sounds.shot[1]
				if sound then
					fireNear("Sound", tpos, WeaponService.SOUND_RADIUS, sound, tpos)
				end
				fireNear("Effect", tpos, 200, "MeleeHit", { position = tpos + Vector3.new(0, 1, 0) })
			end
			return
		end
	end
end

-- AIM (brandish / armed) ---------------------------------------------------------------------------------------------------

-- Aim pitch in degrees for the replicated upper-body pose (character attribute AimPitch; nil when not aiming):
-- validated, clamped, and only re-written when it moved by AIM_PITCH_STEP or more. Returns the value written.
function WeaponService._aimPitch(current: number?, claimed: any): number?
	if typeof(claimed) ~= "number" or claimed ~= claimed or math.abs(claimed) == math.huge then
		return current
	end
	local limit = WeaponService.AIM_PITCH_LIMIT
	local step = WeaponService.AIM_PITCH_STEP
	local p = math.clamp(math.floor(claimed / step + 0.5) * step, -limit, limit)
	if current ~= nil and math.abs(p - current) < step then
		return current
	end
	return p
end

-- WeaponAim(aiming: boolean, pitchDeg: number?)
local function onAim(player: Player, aiming: any, pitch: any)
	local inv = invs[player]
	if not inv or typeof(aiming) ~= "boolean" then
		return
	end
	local allowed = aiming and inv.equipped ~= nil and Weapons.isGun(Weapons.get(inv.equipped))
	if not allowed then
		clearAim(inv)
		return
	end
	inv.aiming = true
	pcall(function()
		player:SetAttribute("Aiming", true)
		local char = player.Character
		if char then
			local cur = char:GetAttribute("AimPitch")
			local nextPitch = WeaponService._aimPitch(if typeof(cur) == "number" then cur else nil, pitch)
			if nextPitch ~= cur then
				char:SetAttribute("AimPitch", nextPitch)
			end
		end
	end)
end
WeaponService._onAim = onAim

function WeaponService.isAiming(player: Player): boolean
	local inv = invs[player]
	return inv ~= nil and inv.aiming
end

-- LIFECYCLE -----------------------------------------------------------------------------------------------------------------

local function disconnect(inv: Inv)
	for _, c in inv.conns do
		c:Disconnect()
	end
	table.clear(inv.conns)
end

local function onCharacter(player: Player, char: Model)
	local inv = getInv(player)
	disconnect(inv)
	setEquipped(inv, nil)
	clearAim(inv)
	table.insert(
		inv.conns,
		char.ChildAdded:Connect(function(child)
			onCharacterChild(inv, child, true)
		end)
	)
	table.insert(
		inv.conns,
		char.ChildRemoved:Connect(function(child)
			onCharacterChild(inv, child, false)
		end)
	)
	task.defer(function()
		if player.Character ~= char then
			return
		end
		local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 10)
		if hum and hum:IsA("Humanoid") then
			table.insert(
				inv.conns,
				hum.Seated:Connect(function(active: boolean)
					if active then
						WeaponService.holster(player) -- holster on entering a car (drive-by is phase 2)
					end
				end)
			)
		end
		if inv.loaded then
			syncTools(inv)
			WeaponService.pushState(player)
		end
	end)
end

local function onPlayerAdded(player: Player)
	getInv(player)
	pcall(function()
		player:SetAttribute("EquippedWeapon", "")
	end)
	player.CharacterAdded:Connect(function(char)
		onCharacter(player, char)
	end)
	if player.Character then
		task.spawn(onCharacter, player, player.Character)
	end
	local ok, loaded = call("DataService", "isLoaded", player)
	if ok and loaded == true then
		loadInventory(player)
	end
end

local function onPlayerRemoving(player: Player)
	local inv = invs[player]
	if inv then
		for id in inv.ammo do
			writeAmmo(inv, id)
		end
		disconnect(inv)
	end
	invs[player] = nil
end

-- Test seams (tests/spec/weaponservice.spec.luau).
WeaponService._getInv = getInv
WeaponService._processShot = processShot
WeaponService._onFire = onFire
WeaponService._onMelee = onMelee
WeaponService._setEquipped = setEquipped
function WeaponService._removeInv(player: Player)
	invs[player] = nil
end

function WeaponService.init()
	for _, def in Weapons.List do
		getTemplate(def.id)
	end
	Net.on("WeaponFire", onFire, Weapons.PACKETS_PER_SECOND + 5)
	Net.on("WeaponReload", function(player: Player, id: any)
		WeaponService.reload(player, id)
	end, 4)
	Net.on("WeaponEquip", requestEquip, 8)
	Net.on("WeaponMelee", onMelee, 8)
	Net.on("WeaponAim", onAim, 10) -- aim on / off plus the aim pitch while aiming (<= 4 / s)
end

function WeaponService.start()
	-- uploaded meshes (Config/Weapons asset.mesh) replace the placeholder parts as they arrive
	for _, def in Weapons.List do
		if def.asset.mesh.id > 0 then
			task.spawn(function()
				local model = loadMesh(def)
				if model then
					meshTemplates[def.id] = model
					for _, inv in invs do
						local tool = inv.tools[def.id]
						if tool and inv.equipped ~= def.id then
							tool:Destroy()
							inv.tools[def.id] = nil
							syncTools(inv)
						end
					end
				end
			end)
		end
	end
	local DataService = sys("DataService")
	if DataService and DataService.Loaded then
		DataService.Loaded:Connect(function(player: Player)
			loadInventory(player)
		end)
	end
	if DataService and DataService.Releasing then
		DataService.Releasing:Connect(function(player: Player)
			local inv = invs[player]
			if inv then
				for id in inv.ammo do
					writeAmmo(inv, id)
				end
			end
		end)
	end
	local Wanted = sys("WantedService")
	if Wanted and Wanted.Busted then
		Wanted.Busted:Connect(function(player: Player)
			WeaponService.onBusted(player)
		end)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, pl in Players:GetPlayers() do
		task.spawn(onPlayerAdded, pl)
	end
	-- reload timers that outlive a holster / death are cancelled by tokens; nothing else ticks here
end

return WeaponService
